"""Преобразование книги EPUB в FictionBook (FB2).

Модуль предоставляет класс :class:`EpubToFb2Converter`, который читает
EPUB-архив (ZIP), разбирает ``META-INF/container.xml`` и OPF-манифест,
извлекает метаданные и содержимое из XHTML-файлов ``spine`` и собирает
структуры FB2 (см. :mod:`fb2_structures`), после чего сериализует их в
XML FictionBook 2.0.

Что поддерживается:

    * метаданные (<dc:title>, <dc:creator>, <dc:language>, <dc:identifier>,
      <dc:date>, <dc:description>, <dc:subject>) -> <description>;
    * обложка (EPUB2 <guide> / EPUB3 <meta name="cover">, cover-image);
    * изображения из <manifest> (media-type image/*) -> <binary> (base64);
    * порядок чтения <spine> -> <body>/<section>;
    * заголовки <h1>-<h6> -> иерархия <section>/<title>;
    * <p>, <strong>/<b>, <em>/<i>, <a>, <img>, <sub>, <sup>, <code>,
      <strike>, <blockquote>, <ul>/<ol>, <table>, <pre>, <hr>;
    * разделы строятся по оглавлению EPUB (nav.xhtml для EPUB3 либо
      toc.ncx для EPUB2), а если его нет — по заголовкам h1-h6 в XHTML.

Пример::

    >>> from epub_to_fb2 import EpubToFb2Converter
    >>> converter = EpubToFb2Converter()
    >>> path = converter.write("book.epub", "book.fb2")
    WindowsPath('book.fb2')
    >>> # только XML-строка, без записи файла:
    >>> xml = converter.to_xml(converter.convert("book.epub"))
"""

from __future__ import annotations

import base64
import html.entities
import io
import json
import posixpath
import re
import sys
import uuid
import zipfile
import xml.etree.ElementTree as ET
from datetime import date
from pathlib import Path
from typing import Dict, List, Optional, Tuple, Union
from urllib.parse import unquote

from .fb2_writer import Fb2Writer
from .fb2_structures import (
    Annotation,
    Author,
    Binary,
    Body,
    Cite,
    CoverPage,
    DateField,
    Description,
    DocumentInfo,
    EmptyLine,
    FictionBook,
    Genre,
    Image,
    InlineImage,
    Paragraph,
    Section,
    StyleNode,
    Subtitle,
    Table,
    TableCell,
    TableRow,
    TextField,
    Title,
    TitleInfo,
)
from .fb2_errors import Fb2ConversionError
from .fb2_xml import parse_xml, parse_xml_text

# --- Константы EPUB ----------------------------------------------------------
#: Тег-заглушка для текстовых фрагментов внутри mixed-контента (как в парсере).
TEXT_NODE = "#text"

#: Уровни заголовков XHTML для построения иерархии секций.
HEADING_LEVELS = {"h1": 1, "h2": 2, "h3": 3, "h4": 4, "h5": 5, "h6": 6}

#: Инлайн-элементы XHTML, преобразуемые в styleType.
INLINE_TAGS = frozenset(
    {
        "strong", "b", "em", "i", "sub", "sup", "code", "tt", "kbd",
        "samp", "var", "strike", "s", "del", "a", "img", "br",
        "span", "font", "small", "big", "q", "mark", "u", "abbr",
        "bdi", "bdo", "label", "cite", "dfn",
    }
)

#: Контейнерные элементы XHTML, которые разворачиваются на месте.
BLOCK_CONTAINERS = frozenset(
    {"div", "section", "article", "header", "footer", "main", "aside", "nav", "center"}
)

#: Блочные элементы XHTML. Нужны, чтобы распознавать «обёртки» — например
#: ``<span>`` вокруг ``<p>``/``<div>`` (типично для EPUB, собранных из FB2):
#: такие элементы нельзя разбирать как инлайн, их содержимое надо обойти
#: как контейнер, иначе текст книги теряется.
BLOCK_TAGS = (
    BLOCK_CONTAINERS
    | frozenset(HEADING_LEVELS)
    | frozenset(
        {
            "p", "blockquote", "table", "ul", "ol", "li", "pre", "address",
            "figure", "img", "hr", "dl", "dt", "dd", "form", "fieldset",
        }
    )
)

#: Жанр по умолчанию (если в EPUB нет подходящих <dc:subject>).
DEFAULT_GENRE = "prose"

#: Регулярное выражение для именованных HTML-сущностей.
_ENTITY_RE = re.compile(r"&([A-Za-z][A-Za-z0-9]*);")

#: Проверка корректности XML-ID (для атрибутов id в FB2).
_ID_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_.-]*$")

#: Соответствие расширения файла и MIME-типа для изображений.
_CONTENT_TYPE_BY_EXT = {
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".png": "image/png",
    ".gif": "image/gif",
    ".svg": "image/svg+xml",
    ".webp": "image/webp",
    ".bmp": "image/bmp",
    ".tif": "image/tiff",
    ".tiff": "image/tiff",
}


def _fix_entities(text: str) -> str:
    """Заменить именованные HTML-сущности на числовые ссылки для XML.

    ``&amp;``/``&lt;``/``&gt;``/``&quot;``/``&apos;`` не трогаем — они
    предопределены в XML. Остальные (``&nbsp;``, ``&mdash;`` и т. п.)
    превращаем в ``&#...;``, чтобы ``ET.fromstring`` не падал на EPUB
    с «грязным» XHTML.
    """

    def repl(match: "re.Match[str]") -> str:
        name = match.group(1)
        if name in ("amp", "lt", "gt", "quot", "apos"):
            return match.group(0)
        chars = html.entities.html5.get(name + ";")
        if chars is not None:
            return "".join(f"&#{ord(ch)};" for ch in chars)
        return match.group(0)

    return _ENTITY_RE.sub(repl, text)


_GENRES_CACHE: Optional[Dict[str, str]] = None


def _load_genres() -> Dict[str, str]:
    """Загрузить список жанров из resources/genres.json (код -> название)."""
    global _GENRES_CACHE
    if _GENRES_CACHE is None:
        path = Path(__file__).parent / "resources" / "genres.json"
        try:
            entries = json.loads(path.read_text(encoding="utf-8"))
            _GENRES_CACHE = {entry["code"]: entry["name"] for entry in entries}
        except (OSError, ValueError, KeyError):
            _GENRES_CACHE = {}
    return _GENRES_CACHE


class EpubToFb2Converter:
    """Преобразование книги EPUB в структуры FB2 и обратно в XML.

    :param source: путь к файлу ``.epub`` (``str``/``Path``) либо его
        содержимое в виде ``bytes``. Может передаваться в конструктор или
        в методы :meth:`convert` / :meth:`write`.
    :param default_genre: жанр FB2 по умолчанию, если в EPUB нет
        подходящих ``<dc:subject>`` (по умолчанию ``"prose"``).
    :param program_used: значение ``<program-used>`` в ``document-info``.
    """

    def __init__(
        self,
        source: Optional[Union[str, Path, bytes]] = None,
        default_genre: str = DEFAULT_GENRE,
        program_used: str = "pyFB2",
    ) -> None:
        self.source = source
        self.default_genre = default_genre
        self.program_used = program_used
        self._book: Optional[FictionBook] = None
        self._reset()

    def _reset(self) -> None:
        """Очистить состояние для нового преобразования."""
        self._zip: Optional[zipfile.ZipFile] = None
        self._opf_dir: str = ""
        self._meta: Dict[str, List[str]] = {}
        self._manifest: Dict[str, Tuple[str, str, str]] = {}  # id -> (href, media-type, properties)
        self._path_to_id: Dict[str, str] = {}  # абсолютный путь в архиве -> fb2 id
        self._manifest_id_map: Dict[str, str] = {}  # id манифеста -> fb2 id
        self._binaries: List[Binary] = []
        self._used_ids: set = set()
        self._image_counter: int = 0
        self._cover_href: Optional[str] = None

    # --- Публичный API -----------------------------------------------------
    @property
    def book(self) -> Optional[FictionBook]:
        """Последняя собранная структура :class:`FictionBook` (или None)."""
        return self._book

    def convert(self, source: Optional[Union[str, Path, bytes]] = None) -> FictionBook:
        """Прочитать EPUB и вернуть структуру :class:`FictionBook`.

        :param source: путь/байты EPUB (иначе берётся ``self.source``).
        """
        if source is not None:
            self.source = source
        if self.source is None:
            raise Fb2ConversionError("Не задан источник EPUB (source)")

        self._reset()
        self._zip = self._open_zip(self.source)
        try:
            opf_root = self._parse_opf()
            self._read_metadata(opf_root)
            self._load_manifest(opf_root)
            self._load_binaries()
            self._detect_cover(opf_root)
            body = self._convert_spine(opf_root)
            self._book = self._assemble(body)
            return self._book
        finally:
            self._zip.close()
            self._zip = None

    def to_xml(self, book: Optional[FictionBook] = None) -> str:
        """Сериализовать книгу (или результат :meth:`convert`) в XML FB2.

        :param book: готовая структура; если не задана, используется
            результат последнего вызова :meth:`convert` (или вызывается он сам).
        """
        if book is None:
            book = self._book
        if book is None:
            book = self.convert()
        return Fb2Writer().to_xml(book)

    def write(
        self,
        source: Optional[Union[str, Path, bytes]] = None,
        output: Optional[Union[str, Path]] = None,
    ) -> Path:
        """Преобразовать EPUB в файл FB2 и вернуть путь к результату.

        :param source: путь/байты EPUB (иначе ``self.source``).
        :param output: путь к выходному ``.fb2``; по умолчанию — рядом с
            исходным ``.epub`` (или ``book.fb2``, если источник — байты).
        """
        book = self.convert(source)
        xml = self.to_xml(book)

        if output is None:
            src = source if source is not None else self.source
            output = Path(src).with_suffix(".fb2") if isinstance(src, (str, Path)) else Path("book.fb2")
        output = Path(output)
        output.write_text(xml, encoding="utf-8")
        return output

    # --- Чтение EPUB-архива ------------------------------------------------
    @staticmethod
    def _open_zip(source: Union[str, Path, bytes]) -> zipfile.ZipFile:
        """Открыть EPUB как ZIP (из пути или байтов)."""
        if isinstance(source, bytes):
            return zipfile.ZipFile(io.BytesIO(source))
        return zipfile.ZipFile(source)

    def _read_bytes(self, name: str) -> Optional[bytes]:
        """Прочитать файл из архива по имени (None, если отсутствует)."""
        if self._zip is None:
            return None
        try:
            return self._zip.read(name)
        except KeyError:
            return None

    def _parse_opf(self) -> ET.Element:
        """Найти и разобрать OPF-файл по META-INF/container.xml."""
        if self._zip is None:
            raise Fb2ConversionError("EPUB-архив не открыт")

        container_data = self._read_bytes("META-INF/container.xml")
        opf_path: Optional[str] = None
        if container_data is not None:
            try:
                container = parse_xml(container_data)
            except ET.ParseError:
                container = None
            if container is not None:
                for rootfile in container.iter():
                    if rootfile.tag.rsplit("}", 1)[-1] == "rootfile":
                        opf_path = rootfile.get("full-path")
                        if opf_path:
                            break
        if not opf_path:
            # Фолбэк: первый файл с расширением .opf в архиве.
            for name in self._zip.namelist():
                if name.lower().endswith(".opf"):
                    opf_path = name
                    break
        if not opf_path:
            raise Fb2ConversionError("Не найден OPF-файл в EPUB (container.xml)")

        self._opf_dir = posixpath.dirname(opf_path)
        opf_data = self._read_bytes(opf_path)
        if opf_data is None:
            raise Fb2ConversionError(f"OPF-файл отсутствует в архиве: {opf_path}")
        try:
            return parse_xml_text(_fix_entities(opf_data.decode("utf-8", "replace")))
        except ET.ParseError as exc:
            raise Fb2ConversionError(f"Не удалось разобрать OPF: {opf_path}") from exc

    def _read_metadata(self, opf_root: ET.Element) -> None:
        """Собрать dc:* метаданные в словарь self._meta."""
        meta: Dict[str, List[str]] = {}
        for elem in opf_root.iter():
            tag = elem.tag
            if "}" in tag:
                ns, _, local = tag[1:].partition("}")
            else:
                ns, local = "", tag
            if ns != "http://purl.org/dc/elements/1.1/":
                continue
            value = "".join(elem.itertext()).strip()
            if value:
                meta.setdefault(local, []).append(value)
        self._meta = meta

    def _load_manifest(self, opf_root: ET.Element) -> None:
        """Прочитать <manifest>: id -> (href, media-type, properties)."""
        manifest: Dict[str, Tuple[str, str, str]] = {}
        for elem in opf_root.iter():
            if elem.tag.rsplit("}", 1)[-1] == "item":
                item_id = elem.get("id")
                href = elem.get("href")
                if item_id and href:
                    manifest[item_id] = (
                        unquote(href),
                        elem.get("media-type", ""),
                        elem.get("properties", ""),
                    )
        self._manifest = manifest

    def _resolve_href(self, href: str) -> str:
        """Привести относительный href к абсолютному пути в архиве."""
        href = unquote(href)
        if href.startswith("#"):
            return href
        if posixpath.isabs(href):
            return href.lstrip("/")
        return posixpath.normpath(posixpath.join(self._opf_dir, href))

    def _load_binaries(self) -> None:
        """Загрузить изображения из манифеста в <binary> (base64)."""
        for item_id, (href, media_type, _properties) in self._manifest.items():
            if not media_type.startswith("image/"):
                continue
            path = self._resolve_href(href)
            data = self._read_bytes(path)
            if data is None:
                continue
            fb2_id = self._allocate_id("image")
            self._manifest_id_map[item_id] = fb2_id
            self._path_to_id[path] = fb2_id
            self._binaries.append(
                Binary(
                    id=fb2_id,
                    content_type=media_type,
                    data=base64.b64encode(data).decode("ascii"),
                )
            )

    def _detect_cover(self, opf_root: ET.Element) -> None:
        """Определить обложку: EPUB2 <guide> / EPUB3 <meta name="cover">.

        Итоговый href сохраняется как ``#id`` (ссылка на <binary>).
        """
        cover_href: Optional[str] = None

        # EPUB3: <meta name="cover" content="..."/> -> id элемента manifest.
        for elem in opf_root.iter():
            if elem.tag.rsplit("}", 1)[-1] != "meta":
                continue
            if elem.get("name") == "cover":
                cover_id = elem.get("content")
                if cover_id and cover_id in self._manifest:
                    cover_href = self._manifest[cover_id][0]
                    break

        # EPUB2: <guide><reference type="cover" href="..."/>.
        if not cover_href:
            for elem in opf_root.iter():
                if elem.tag.rsplit("}", 1)[-1] != "reference":
                    continue
                if elem.get("type") == "cover":
                    cover_href = elem.get("href")
                    break

        if cover_href:
            path = self._resolve_href(cover_href)
            fb2_id = self._path_to_id.get(path)
            self._cover_href = ("#" + fb2_id) if fb2_id else None
        else:
            self._cover_href = None

    # --- Вспомогательные методы для изображений ---------------------------
    def _allocate_id(self, prefix: str = "image") -> str:
        """Выделить уникальный XML-ID для бинарника."""
        self._image_counter += 1
        return f"{prefix}_{self._image_counter}"

    @staticmethod
    def _valid_id(value: str) -> bool:
        """Проверить, что строка является корректным XML-ID."""
        return bool(value) and bool(_ID_RE.match(value))

    @staticmethod
    def _guess_content_type(path: str) -> str:
        """Определить MIME-тип изображения по расширению файла."""
        ext = posixpath.splitext(path)[1].lower()
        return _CONTENT_TYPE_BY_EXT.get(ext, "")

    def _resolve_image(self, src: Optional[str], current_path: str) -> Optional[str]:
        """Разрешить ссылку на изображение в href вида ``#id`` (или None).

        Поддерживаются обычные файлы (относительно текущего XHTML) и
        inline-данные вида ``data:image/...;base64,...``.
        """
        if not src:
            return None
        src = src.strip()
        if src.startswith("data:"):
            return self._register_data_uri(src)
        if src.startswith("#"):
            return None

        path = posixpath.normpath(
            posixpath.join(posixpath.dirname(current_path), unquote(src))
        )
        if path in self._path_to_id:
            return "#" + self._path_to_id[path]

        data = self._read_bytes(path)
        if data is not None:
            content_type = self._guess_content_type(path)
            if content_type.startswith("image/"):
                fb2_id = self._allocate_id("image")
                self._path_to_id[path] = fb2_id
                self._binaries.append(
                    Binary(
                        id=fb2_id,
                        content_type=content_type,
                        data=base64.b64encode(data).decode("ascii"),
                    )
                )
                return "#" + fb2_id
        return None

    def _register_data_uri(self, src: str) -> Optional[str]:
        """Зарегистрировать изображение из data-URI как <binary>."""
        header, sep, payload = src.partition(",")
        if not sep:
            return None
        meta = header[len("data:"):]
        parts = meta.split(";")
        content_type = parts[0] or "image/png"
        is_base64 = "base64" in parts[1:]
        try:
            data = base64.b64decode(payload) if is_base64 else unquote(payload).encode("utf-8")
        except (ValueError, TypeError):
            return None
        if not content_type.startswith("image/"):
            return None

        fb2_id = self._allocate_id("image")
        self._binaries.append(
            Binary(
                id=fb2_id,
                content_type=content_type,
                data=base64.b64encode(data).decode("ascii"),
            )
        )
        return "#" + fb2_id

    # --- Метаданные EPUB -> FB2 -------------------------------------------
    @staticmethod
    def _first(values: Optional[List[str]]) -> Optional[str]:
        """Первый элемент списка или None."""
        if not values:
            return None
        return values[0]

    def _genres(self) -> List[Genre]:
        """Жанры из <dc:subject>, сопоставленные с FictionBookGenres."""
        subjects = self._meta.get("subject", [])
        return [Genre(value=g) for g in self._match_genres(subjects)]

    def _match_genres(self, subjects: List[str]) -> List[str]:
        """Сопоставить темы с кодами жанров; фолбэк — default_genre."""
        genres = _load_genres()
        name_to_code = {name.lower(): code for code, name in genres.items()}
        codes = set(genres)
        result: List[str] = []
        for subject in subjects:
            subject = subject.strip()
            if not subject:
                continue
            if subject in codes:
                result.append(subject)
            elif subject.lower() in name_to_code:
                result.append(name_to_code[subject.lower()])
        return result or [self.default_genre]

    def _authors(self) -> List[Author]:
        """Авторы из <dc:creator>."""
        return [self._split_author(c) for c in self._meta.get("creator", [])]

    @staticmethod
    def _split_author(name: str) -> Author:
        """Разбить строку автора на first/last/middle."""
        name = name.strip()
        if "," in name:
            last, _, first = name.partition(",")
            return Author(last_name=last.strip(), first_name=first.strip() or None)
        parts = name.split()
        if len(parts) == 1:
            return Author(last_name=parts[0])
        if len(parts) == 2:
            return Author(first_name=parts[0], last_name=parts[1])
        return Author(
            first_name=parts[0],
            middle_name=" ".join(parts[1:-1]),
            last_name=parts[-1],
        )

    def _annotation(self) -> Optional[Annotation]:
        """Аннотация из <dc:description>."""
        desc = self._first(self._meta.get("description"))
        if not desc:
            return None
        return Annotation(items=[Paragraph(content=[StyleNode(tag=TEXT_NODE, text=desc)])])

    def _date_field(self) -> Optional[DateField]:
        """Дата публикации из <dc:date>."""
        value = self._first(self._meta.get("date"))
        if not value:
            return None
        date_value: Optional[str] = None
        match = re.match(r"^(\d{4}-\d{2}-\d{2})", value)
        if match:
            date_value = match.group(1)
        return DateField(value=value, date_value=date_value)

    def _coverpage(self) -> Optional[CoverPage]:
        """Обложка <coverpage>, если найдена."""
        if self._cover_href:
            return CoverPage(images=[InlineImage(href=self._cover_href)])
        return None

    def _assemble(self, body: Body) -> FictionBook:
        """Собрать корневую структуру FictionBook."""
        title_info = TitleInfo(
            genres=self._genres(),
            authors=self._authors(),
            book_title=TextField(value=self._first(self._meta.get("title")) or "Untitled"),
            annotation=self._annotation(),
            keywords=None,
            date=self._date_field(),
            coverpage=self._coverpage(),
            lang=self._first(self._meta.get("language")),
            src_lang=None,
            translators=[],
            sequences=[],
        )
        document_info = DocumentInfo(
            authors=[Author(nickname="pyFB2")],
            program_used=TextField(value=self.program_used),
            date=DateField(value=date.today().isoformat()),
            id=self._first(self._meta.get("identifier")) or uuid.uuid4().hex,
            version=1.0,
        )
        return FictionBook(
            description=Description(
                title_info=title_info,
                document_info=document_info,
            ),
            bodies=[body],
            binaries=self._binaries,
        )

    # --- Вспомогательные для обхода HTML ---------------------------------
    @staticmethod
    def _local(tag: str) -> str:
        """Локальное имя тега: '{ns}body' -> 'body'."""
        return tag.rsplit("}", 1)[-1] if "}" in tag else tag

    @staticmethod
    def _find_child(elem: ET.Element, name: str) -> Optional[ET.Element]:
        """Первый прямой потомок с указанным локальным именем."""
        for child in elem:
            if EpubToFb2Converter._local(child.tag) == name:
                return child
        return None

    @staticmethod
    def _to_int(value: Optional[str]) -> Optional[int]:
        """Мягкое приведение строки к int."""
        try:
            return int(value) if value else None
        except (ValueError, TypeError):
            return None

    @staticmethod
    def _find_img(elem: ET.Element) -> Optional[ET.Element]:
        """Первый вложенный <img> (для <figure>)."""
        for child in elem.iter():
            if EpubToFb2Converter._local(child.tag) == "img":
                return child
        return None

    @staticmethod
    def _text_content(elem: ET.Element) -> str:
        """Весь текст элемента (включая потомков и хвосты)."""
        parts = []
        if elem.text:
            parts.append(elem.text)
        for child in elem:
            parts.append(EpubToFb2Converter._text_content(child))
            if child.tail:
                parts.append(child.tail)
        return "".join(parts)

    def _has_block_content(self, elem: ET.Element) -> bool:
        """Есть ли внутри элемента блочные элементы (``<p>``, ``<div>``, …).

        Так распознаются «обёртки» — например ``<span>``, в который
        конвертер FB2 → EPUB заворачивает блочное содержимое главы.
        """
        return any(
            self._local(node.tag) in BLOCK_TAGS
            for node in elem.iter()
            if node is not elem
        )

    def _convert_container(self, elem: ET.Element, current_path: str) -> Optional[Paragraph]:
        """Контейнер без блочных потомков (``<div class="paragraph">``) -> абзац.

        Calibre и другие конвертеры часто кладут обычный текст в ``<div>``
        без вложенных ``<p>``. Такой контейнер нельзя просто обходить
        рекурсивно (текст ``elem.text`` при обходе потомков теряется) —
        его надо превратить в абзац.
        """
        if not self._text_content(elem).strip() and not any(
            self._local(node.tag) == "img" for node in elem.iter()
        ):
            return None
        return Paragraph(content=self._convert_inline(elem, current_path))

    # --- Spine -> Body -----------------------------------------------------
    def _convert_spine(self, opf_root: ET.Element) -> Body:
        """Преобразовать документы <spine> в структуру Body."""
        docs = self._read_spine_docs(opf_root)

        toc = self._parse_toc(opf_root)
        if toc:
            return self._body_from_toc(docs, toc)

        body = Body()
        root_section = Section()
        stack: List[Tuple[int, Section]] = [(0, root_section)]
        for path, html_body in docs:
            self._walk(html_body, path, stack)

        body.sections = root_section.sections
        if root_section.content:
            body.sections.insert(0, Section(content=root_section.content))
        if not body.sections:
            body.sections = [Section()]
        self._fix_empty_sections(body.sections)
        return body

    def _read_spine_docs(self, opf_root: ET.Element) -> List[Tuple[str, ET.Element]]:
        """Read <spine> documents as a list of (archive path, <body> element)."""
        docs: List[Tuple[str, ET.Element]] = []
        spine = self._find_child(opf_root, "spine")
        if spine is None:
            return docs
        for itemref in spine:
            if self._local(itemref.tag) != "itemref":
                continue
            idref = itemref.get("idref")
            if not idref or idref not in self._manifest:
                continue
            href, _media_type, _props = self._manifest[idref]
            path = self._resolve_href(href)
            data = self._read_bytes(path)
            if data is None:
                continue
            try:
                doc = parse_xml_text(_fix_entities(data.decode("utf-8", "replace")))
            except ET.ParseError:
                continue
            html_body = self._find_body(doc)
            if html_body is None:
                continue
            docs.append((path, html_body))
        return docs

    def _has_heading(self, elem: ET.Element) -> bool:
        """Whether the subtree contains an h1-h6 heading."""
        return any(self._local(e.tag) in HEADING_LEVELS for e in elem.iter())

    @staticmethod
    def _find_body(doc: ET.Element) -> Optional[ET.Element]:
        """Найти элемент <body> в XHTML-документе."""
        for elem in doc.iter():
            if EpubToFb2Converter._local(elem.tag) == "body":
                return elem
        return None

    # --- Оглавление EPUB (nav.xhtml / toc.ncx) -----------------------------
    def _parse_toc(self, opf_root: ET.Element) -> List[Tuple[str, str, Optional[str], list]]:
        """Read the EPUB table of contents.

        Returns a list of (label, archive path, fragment, children). EPUB3
        navigation documents (``properties="nav"``) are preferred; otherwise
        ``toc.ncx`` (EPUB2) is used. An empty list means there is no TOC.
        """
        for _item_id, (href, _media_type, props) in self._manifest.items():
            if "nav" in props.split():
                entries = self._parse_toc_nav(self._resolve_href(href))
                if entries:
                    return entries
        ncx_path = self._find_ncx_path(opf_root)
        if ncx_path:
            return self._parse_toc_ncx(ncx_path)
        return []

    def _find_ncx_path(self, opf_root: ET.Element) -> Optional[str]:
        """Path to toc.ncx in the archive (by spine@toc or media-type)."""
        spine = self._find_child(opf_root, "spine")
        toc_id = spine.get("toc") if spine is not None else None
        if toc_id and toc_id in self._manifest:
            return self._resolve_href(self._manifest[toc_id][0])
        for _item_id, (href, media_type, _props) in self._manifest.items():
            if media_type == "application/x-dtbncx+xml":
                return self._resolve_href(href)
        return None

    def _split_href(self, base_dir: str, href: str) -> Tuple[str, Optional[str]]:
        """Split a TOC href into an archive path and a fragment (#id)."""
        href = unquote(href or "")
        fragment: Optional[str] = None
        if "#" in href:
            href, _, fragment = href.partition("#")
        if not href:
            path = ""
        elif posixpath.isabs(href):
            path = href.lstrip("/")
        else:
            path = posixpath.normpath(posixpath.join(base_dir, href))
        return path, fragment

    def _parse_toc_nav(self, nav_path: str) -> List[Tuple[str, str, Optional[str], list]]:
        """Parse an EPUB3 navigation document (nav.xhtml)."""
        data = self._read_bytes(nav_path)
        if data is None:
            return []
        try:
            doc = parse_xml_text(_fix_entities(data.decode("utf-8", "replace")))
        except ET.ParseError:
            return []
        nav = None
        fallback = None
        for elem in doc.iter():
            if self._local(elem.tag) != "nav":
                continue
            etype = ""
            for key, value in elem.attrib.items():
                if key.rsplit("}", 1)[-1] == "type":
                    etype = value
            if etype == "toc":
                nav = elem
                break
            if fallback is None:
                fallback = elem
        if nav is None:
            nav = fallback
        if nav is None:
            return []
        ol = self._find_child(nav, "ol")
        if ol is None:
            return []
        return self._parse_nav_ol(ol, posixpath.dirname(nav_path))

    def _parse_nav_ol(self, ol: ET.Element, base_dir: str) -> List[Tuple[str, str, Optional[str], list]]:
        """Parse an <ol> of a navigation document."""
        entries: List[Tuple[str, str, Optional[str], list]] = []
        for li in ol:
            if self._local(li.tag) != "li":
                continue
            label = ""
            href = ""
            for child in li:
                name = self._local(child.tag)
                if name == "a":
                    label = "".join(child.itertext()).strip()
                    href = child.get("href", "")
                    break
                if name == "span":
                    label = "".join(child.itertext()).strip()
                    break
            sub_ol = self._find_child(li, "ol")
            children = self._parse_nav_ol(sub_ol, base_dir) if sub_ol is not None else []
            path, fragment = self._split_href(base_dir, href)
            if label or path or children:
                entries.append((label, path, fragment, children))
        return entries

    def _parse_toc_ncx(self, ncx_path: str) -> List[Tuple[str, str, Optional[str], list]]:
        """Parse a toc.ncx (EPUB2)."""
        data = self._read_bytes(ncx_path)
        if data is None:
            return []
        try:
            doc = parse_xml_text(_fix_entities(data.decode("utf-8", "replace")))
        except ET.ParseError:
            return []
        nav_map = None
        for elem in doc.iter():
            if self._local(elem.tag) == "navMap":
                nav_map = elem
                break
        if nav_map is None:
            return []
        return self._parse_navpoints(nav_map, posixpath.dirname(ncx_path))

    def _parse_navpoints(self, parent: ET.Element, base_dir: str) -> List[Tuple[str, str, Optional[str], list]]:
        """Parse <navPoint> children of navMap/navPoint."""
        entries: List[Tuple[str, str, Optional[str], list]] = []
        for child in parent:
            if self._local(child.tag) != "navPoint":
                continue
            label = ""
            href = ""
            for sub in child:
                name = self._local(sub.tag)
                if name == "navLabel":
                    label = "".join(sub.itertext()).strip()
                elif name == "content":
                    href = sub.get("src", "")
            path, fragment = self._split_href(base_dir, href)
            children = self._parse_navpoints(child, base_dir)
            entries.append((label, path, fragment, children))
        return entries

    def _body_from_toc(self, docs: List[Tuple[str, ET.Element]],
                       toc: List[Tuple[str, str, Optional[str], list]]) -> Body:
        """Build Body from the EPUB table of contents (no h1-h6 in XHTML).

        Документы ``spine``, которых нет в оглавлении, распределяются по
        порядку чтения:

        * до первого раздела из оглавления — в начальную секцию (титул);
        * между разделами — в текущую секцию (продолжение главы, разбитой
          конвертером на несколько XHTML-файлов);
        * после последнего раздела — в завершающую секцию (сноски,
          приложения), внутри неё заголовки снова дают подсекции.
        """
        body = Body()
        root_section = Section()
        doc_entries: Dict[str, List[Tuple[Optional[str], Section]]] = {}
        self._build_toc_sections(toc, root_section, doc_entries)

        anchors = [
            index for index, (path, _html) in enumerate(docs) if doc_entries.get(path)
        ]
        last_anchor = anchors[-1] if anchors else -1
        trailing_section = Section()
        current_section = root_section

        for index, (path, html_body) in enumerate(docs):
            entries = doc_entries.get(path, [])
            if entries:
                current_section = entries[0][1]
                stack: List[Tuple[int, Section]] = [(0, current_section)]
                state = {
                    "stack": stack,
                    "remaining": entries[1:],
                    "idx": 0,
                    "structured": True,
                }
                self._walk_toc(html_body, path, state)
                # Продолжение главы дописывается в последнюю её подсекцию.
                current_section = stack[-1][1]
                continue
            if last_anchor < 0:
                # Оглавление не ссылается ни на один документ spine.
                target, structured = root_section, False
            elif index > last_anchor:
                target, structured = trailing_section, True
            else:
                target, structured = current_section, False
            state = {
                "stack": [(0, target)],
                "remaining": [],
                "idx": 0,
                "structured": structured,
            }
            self._walk_toc(html_body, path, state)

        body.sections = root_section.sections
        if root_section.content:
            body.sections.insert(0, Section(content=root_section.content))
        if trailing_section.content or trailing_section.sections:
            body.sections.append(trailing_section)
        if not body.sections:
            body.sections = [Section()]
        self._fix_empty_sections(body.sections)
        return body

    def _build_toc_sections(self, entries: list, parent_section: Section,
                            doc_entries: Dict[str, List[Tuple[Optional[str], Section]]]) -> None:
        """Create sections from the TOC tree and index them by document."""
        for label, path, fragment, children in entries:
            section = Section()
            label = self._norm_title(label)
            if label:
                section.title = Title(
                    items=[Paragraph(content=[StyleNode(tag=TEXT_NODE, text=label)])]
                )
            parent_section.sections.append(section)
            if path:
                doc_entries.setdefault(path, []).append((fragment, section))
            self._build_toc_sections(children, section, doc_entries)

    def _walk_toc(self, elem: ET.Element, current_path: str, state: dict) -> None:
        """Walk a document, distributing blocks across TOC sections by anchors.

        A heading that merely repeats the surrounding section title is skipped;
        any other heading starts a nested section (so books whose TOC is flat
        keep their internal heading structure).
        """
        for child in elem:
            name = self._local(child.tag)
            anchor = child.get("id")
            if (
                anchor
                and state["idx"] < len(state["remaining"])
                and state["remaining"][state["idx"]][0] == anchor
            ):
                state["stack"] = [(0, state["remaining"][state["idx"]][1])]
                state["idx"] += 1
            if name in HEADING_LEVELS:
                if not state["structured"]:
                    state["stack"][-1][1].content.append(
                        Subtitle(content=self._convert_inline(child, current_path))
                    )
                    continue
                text = self._norm_title("".join(child.itertext()))
                titles = {self._section_title_text(sec) for _lvl, sec in state["stack"]}
                if text and text in titles:
                    continue
                level = HEADING_LEVELS[name]
                while len(state["stack"]) > 1 and state["stack"][-1][0] >= level:
                    state["stack"].pop()
                new_section = Section(title=self._make_title(child, current_path))
                state["stack"][-1][1].sections.append(new_section)
                state["stack"].append((level, new_section))
            elif name in BLOCK_CONTAINERS:
                if self._is_title_duplicate(child, state["stack"][-1][1]):
                    continue
                if self._has_block_content(child):
                    self._walk_toc(child, current_path, state)
                else:
                    block = self._convert_container(child, current_path)
                    if block is not None:
                        state["stack"][-1][1].content.append(block)
            elif name in ("ul", "ol"):
                state["stack"][-1][1].content.extend(self._convert_list(child, current_path))
            elif name in ("pre", "address"):
                state["stack"][-1][1].content.extend(self._convert_pre(child, current_path))
            else:
                block = self._convert_block(child, current_path)
                if block is None:
                    # Обёртка (например <span>) вокруг блочных элементов.
                    if self._has_block_content(child) and not self._is_title_duplicate(
                        child, state["stack"][-1][1]
                    ):
                        self._walk_toc(child, current_path, state)
                    continue
                section = state["stack"][-1][1]
                if not self._is_title_repeat(block, section):
                    section.content.append(block)

    def _walk(self, elem: ET.Element, current_path: str, stack: List[Tuple[int, Section]]) -> None:
        """Рекурсивно обойти контейнер, строя иерархию секций по заголовкам."""
        for child in elem:
            name = self._local(child.tag)
            if name in HEADING_LEVELS:
                level = HEADING_LEVELS[name]
                while len(stack) > 1 and stack[-1][0] >= level:
                    stack.pop()
                new_section = Section(title=self._make_title(child, current_path))
                stack[-1][1].sections.append(new_section)
                stack.append((level, new_section))
            elif name in BLOCK_CONTAINERS:
                if self._is_title_duplicate(child, stack[-1][1]):
                    continue
                if self._has_block_content(child):
                    self._walk(child, current_path, stack)
                else:
                    block = self._convert_container(child, current_path)
                    if block is not None:
                        stack[-1][1].content.append(block)
            elif name in ("ul", "ol"):
                stack[-1][1].content.extend(self._convert_list(child, current_path))
            elif name in ("pre", "address"):
                stack[-1][1].content.extend(self._convert_pre(child, current_path))
            else:
                block = self._convert_block(child, current_path)
                if block is None:
                    # Обёртка (например <span>) вокруг блочных элементов.
                    if self._has_block_content(child) and not self._is_title_duplicate(
                        child, stack[-1][1]
                    ):
                        self._walk(child, current_path, stack)
                    continue
                stack[-1][1].content.append(block)

    def _make_title(self, heading: ET.Element, current_path: str) -> Title:
        """Заголовок h1-h6 -> <title>."""
        return Title(items=[Paragraph(content=self._convert_inline(heading, current_path))])

    @staticmethod
    def _nodes_text(nodes: list) -> str:
        """Plain text of a list of style nodes."""
        parts = []
        for node in nodes:
            if node.tag == TEXT_NODE:
                parts.append(node.text or "")
            else:
                parts.append(EpubToFb2Converter._nodes_text(node.children))
        return "".join(parts)

    @staticmethod
    def _norm_title(text: str) -> str:
        """Normalize a title for comparison (collapse spaces, drop '*')."""
        text = re.sub(r"\s+", " ", text or "").strip()
        return text.strip("*").strip()

    @staticmethod
    def _squash(text: str) -> str:
        """Убрать все пробельные символы (сравнение «склеенных» строк)."""
        return re.sub(r"\s+", "", text or "")

    def _section_title_text(self, section: Section) -> str:
        """Normalized plain text of a section title."""
        if section.title is None:
            return ""
        parts = []
        for item in section.title.items:
            if isinstance(item, Paragraph):
                parts.append(self._nodes_text(item.content))
        return self._norm_title(" ".join(p for p in parts if p))

    def _is_title_repeat(self, block, section: Section) -> bool:
        """Повторяет ли блок заголовок секции.

        Конвертеры FB2 → EPUB оставляют заголовок секции ещё и в тексте
        (``<div class="title2"><p>…</p></div>``). Такой абзац не нужен:
        текст заголовка уже попал в ``<title>`` из оглавления.
        """
        if not isinstance(block, Paragraph) or section.content:
            return False
        title = self._section_title_text(section)
        if not title:
            return False
        return self._norm_title(self._nodes_text(block.content)) == title

    def _is_title_duplicate(self, elem: ET.Element, section: Section) -> bool:
        """Дублирует ли контейнер (``<div class="title">``) заголовок секции.

        Заголовок секции из оглавления может собираться из нескольких строк
        (``<div class="title1"><p>Глава 1</p><p>КТО СУДЬИ…</p></div>``) —
        тогда сравнение идёт по всему тексту контейнера без пробелов.
        """
        if section.content:
            return False
        title = self._section_title_text(section)
        if not title:
            return False
        return self._squash(self._text_content(elem)) == self._squash(title)

    def _fix_empty_sections(self, sections: list) -> None:
        """A section must have text content: fix empty/image-only sections."""
        for section in sections:
            self._fix_empty_sections(section.sections)
            if not section.content:
                if not section.sections:
                    section.content.append(EmptyLine())
            elif all(isinstance(x, Image) for x in section.content):
                section.content.append(EmptyLine())

    # --- Преобразование блочных элементов HTML -----------------------------
    def _convert_block(self, elem: ET.Element, current_path: str):
        """Один блочный элемент HTML -> структура FB2 (или None)."""
        name = self._local(elem.tag)
        if name == "p":
            if not len(elem) and not self._text_content(elem).strip():
                # <p/> / <p class="empty-line"/> -> <empty-line/>
                return EmptyLine()
            return Paragraph(content=self._convert_inline(elem, current_path))
        if name == "blockquote":
            return self._convert_cite(elem, current_path)
        if name == "table":
            return self._convert_table(elem, current_path)
        if name == "img":
            href = self._resolve_image(elem.get("src"), current_path)
            if href:
                return Image(href=href, alt=elem.get("alt"), title=elem.get("title"))
            return None
        if name == "figure":
            img = self._find_img(elem)
            if img is not None:
                href = self._resolve_image(img.get("src"), current_path)
                if href:
                    return Image(href=href, alt=img.get("alt"), title=img.get("title"))
            return None
        if name == "hr":
            return EmptyLine()
        if name in HEADING_LEVELS:
            return Subtitle(content=self._convert_inline(elem, current_path))
        return None

    def _convert_cite(self, elem: ET.Element, current_path: str) -> Cite:
        """<blockquote> -> <cite>."""
        cite = Cite()
        for child in elem:
            name = self._local(child.tag)
            if name in HEADING_LEVELS:
                cite.items.append(Subtitle(content=self._convert_inline(child, current_path)))
                continue
            block = self._convert_block(child, current_path)
            if block is not None:
                cite.items.append(block)
            elif name in BLOCK_CONTAINERS and not self._has_block_content(child):
                # <div class="paragraph"> с обычным текстом -> абзац.
                para = self._convert_container(child, current_path)
                if para is not None:
                    cite.items.append(para)
            elif name in BLOCK_CONTAINERS or self._has_block_content(child):
                # Обёртка (например <span>) вокруг блочных элементов.
                cite.items.extend(self._convert_cite(child, current_path).items)
        return cite

    def _convert_list(self, elem: ET.Element, current_path: str) -> List[Paragraph]:
        """<ul>/<ol> -> список абзацев (FB2 не имеет списков)."""
        result: List[Paragraph] = []
        for child in elem:
            if self._local(child.tag) == "li":
                result.append(Paragraph(content=self._convert_inline(child, current_path)))
        return result

    def _convert_table(self, elem: ET.Element, current_path: str) -> Table:
        """<table> -> <table> (tr/td/th)."""
        table = Table()
        for row_el in elem:
            if self._local(row_el.tag) != "tr":
                continue
            cells: List[TableCell] = []
            for cell_el in row_el:
                name = self._local(cell_el.tag)
                if name not in ("td", "th"):
                    continue
                cells.append(
                    TableCell(
                        tag=name,
                        children=self._convert_inline(cell_el, current_path),
                        colspan=self._to_int(cell_el.get("colspan")),
                        rowspan=self._to_int(cell_el.get("rowspan")),
                        is_header=(name == "th"),
                    )
                )
            table.rows.append(TableRow(cells=cells))
        return table

    def _convert_pre(self, elem: ET.Element, current_path: str) -> List:
        """<pre>/<address> -> абзацы по строкам (пустые строки -> <empty-line>)."""
        text = self._text_content(elem)
        result: List = []
        for line in text.splitlines():
            if line.strip():
                result.append(Paragraph(content=[StyleNode(tag=TEXT_NODE, text=line)]))
            else:
                result.append(EmptyLine())
        return result

    # --- Inline-разметка ---------------------------------------------------
    def _convert_inline(self, elem: ET.Element, current_path: str) -> List[StyleNode]:
        """Mixed-содержимое HTML -> список StyleNode."""
        nodes: List[StyleNode] = []
        if elem.text:
            nodes.append(StyleNode(tag=TEXT_NODE, text=elem.text))
        for child in elem:
            name = self._local(child.tag)
            if name in INLINE_TAGS:
                node = self._convert_inline_node(child, name, current_path)
                if node is not None:
                    nodes.append(node)
                else:
                    # прозрачный элемент — разворачиваем его содержимое
                    nodes.extend(self._convert_inline(child, current_path))
            else:
                nodes.extend(self._convert_inline(child, current_path))
            if child.tail:
                nodes.append(StyleNode(tag=TEXT_NODE, text=child.tail))
        return nodes

    def _convert_inline_node(self, elem: ET.Element, name: str, current_path: str) -> Optional[StyleNode]:
        """Один инлайн-элемент -> StyleNode (или None для прозрачных)."""
        if name in ("strong", "b"):
            return StyleNode(tag="strong", children=self._convert_inline(elem, current_path))
        if name in ("em", "i"):
            return StyleNode(tag="emphasis", children=self._convert_inline(elem, current_path))
        if name == "sub":
            return StyleNode(tag="sub", children=self._convert_inline(elem, current_path))
        if name == "sup":
            return StyleNode(tag="sup", children=self._convert_inline(elem, current_path))
        if name in ("code", "tt", "kbd", "samp", "var"):
            return StyleNode(tag="code", children=self._convert_inline(elem, current_path))
        if name in ("strike", "s", "del"):
            return StyleNode(tag="strikethrough", children=self._convert_inline(elem, current_path))
        if name == "a":
            node = StyleNode(tag="a", children=self._convert_inline(elem, current_path))
            href = elem.get("href")
            if href:
                node.href = href
            return node
        if name == "img":
            href = self._resolve_image(elem.get("src"), current_path)
            if href:
                return StyleNode(tag="image", image_href=href, image_alt=elem.get("alt"))
            return None
        if name == "br":
            return StyleNode(tag=TEXT_NODE, text="\n")
        return None


__all__ = ["EpubToFb2Converter"]


def main(argv: List[str] | None = None) -> int:
    if argv is None:
        argv = sys.argv
    if len(argv) < 2:
        print(
            "Использование: python epub_to_fb2.py <файл.epub> [выход.fb2]",
            file=sys.stderr,
        )
        return 2
    source = argv[1]
    output = argv[2] if len(argv) > 2 else str(Path(source).with_suffix(".fb2"))
    converter = EpubToFb2Converter()
    path = converter.write(source, output)
    print("FB2:", path)
    print("Изображений:", len(converter.book.binaries) if converter.book else 0)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

