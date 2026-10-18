"""Преобразование документа Word (DOCX) в FictionBook (FB2).

Модуль предоставляет класс :class:`DocxToFb2Converter`, который читает
DOCX (архив Office Open XML) без внешних зависимостей и собирает из него
структуры FB2, после чего сериализует их в XML FictionBook 2.0 (через
общий :class:`~fb2_writer.Fb2Writer`).

Что поддерживается:

    * метаданные docProps/core.xml -> <title-info>/<document-info>;
    * стили Heading1-Heading6 -> иерархия <section>/<title>;
    * абзацы с разметкой (bold/italic/strike/sub/sup/code),
      гиперссылки <w:hyperlink>, встроенные изображения <w:drawing>;
    * таблицы <w:tbl> -> <table>;
    * изображения word/media/* -> <binary> (base64).

Пример::

    >>> from docx_to_fb2 import DocxToFb2Converter
    >>> converter = DocxToFb2Converter()
    >>> path = converter.write("book.docx", "book.fb2")
    WindowsPath('book.fb2')
    >>> book = converter.convert("book.docx")   # структура FictionBook
    >>> xml = converter.to_xml(book)            # XML-строка FB2
"""

from __future__ import annotations

import base64
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
from typing import Any, Dict, List, Optional, Tuple, Union

from .fb2_structures import (
    Annotation,
    Author,
    Binary,
    Body,
    Cite,
    DateField,
    Description,
    DocumentInfo,
    FictionBook,
    Genre,
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
from .fb2_xml import parse_xml
from .fb2_writer import TEXT_NODE, Fb2Writer

# --- Пространства имён OOXML ------------------------------------------------
NS_W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
NS_R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

#: Жанр по умолчанию (если в DOCX нет подходящих метаданных).
DEFAULT_GENRE = "prose"

#: MIME-тип по расширению файла (для <binary content-type>).
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

#: Проверка корректности XML-ID (для атрибутов id в FB2).
_ID_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_.-]*$")


def _w(name: str) -> str:
    """Квалифицированное имя в пространстве имён WordprocessingML."""
    return f"{{{NS_W}}}{name}"


def _r(name: str) -> str:
    """Квалифицированное имя в пространстве имён relationships."""
    return f"{{{NS_R}}}{name}"


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


class DocxToFb2Converter:
    """Преобразование документа DOCX в структуры FB2 и обратно в XML.

    :param source: путь к файлу ``.docx`` (``str``/``Path``) либо его
        содержимое в виде ``bytes``. Может передаваться в конструктор или
        в методы :meth:`convert` / :meth:`write`.
    :param default_genre: жанр FB2 по умолчанию, если в DOCX нет
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
        self.writer = Fb2Writer()
        self._book: Optional[FictionBook] = None
        self._reset()

    def _reset(self) -> None:
        """Очистить состояние для нового преобразования."""
        self._zip: Optional[zipfile.ZipFile] = None
        self._rels: Dict[str, str] = {}  # rId -> target
        self._default_content_types: Dict[str, str] = {}  # extension -> content-type
        self._binaries: List[Binary] = []
        self._used_ids: set = set()
        self._rid_to_fb2id: Dict[str, str] = {}
        self._title_override: Optional[str] = None

    # --- Публичный API -----------------------------------------------------
    @property
    def book(self) -> Optional[FictionBook]:
        """Последняя собранная структура :class:`FictionBook` (или None)."""
        return self._book

    def convert(self, source: Optional[Union[str, Path, bytes]] = None) -> FictionBook:
        """Прочитать DOCX и вернуть структуру :class:`FictionBook`.

        :param source: путь/байты DOCX (иначе берётся ``self.source``).
        """
        if source is not None:
            self.source = source
        if self.source is None:
            raise Fb2ConversionError("Не задан источник DOCX (source)")

        self._reset()
        self._zip = self._open_zip(self.source)
        try:
            self._load_rels()
            self._load_content_types()
            meta = self._read_core_metadata()
            doc_root = self._read_document()
            body_elem = self._find_body(doc_root)
            if body_elem is None:
                raise Fb2ConversionError("В DOCX не найден элемент <w:body>")
            body = self._convert_body(body_elem)
            self._book = self._assemble(meta, body)
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
        return self.writer.to_xml(book)

    def write(
        self,
        source: Optional[Union[str, Path, bytes]] = None,
        output: Optional[Union[str, Path]] = None,
    ) -> Path:
        """Преобразовать DOCX в файл FB2 и вернуть путь к результату.

        :param source: путь/байты DOCX (иначе ``self.source``).
        :param output: путь к выходному ``.fb2``; по умолчанию — рядом с
            исходным ``.docx`` (или ``book.fb2``, если источник — байты).
        """
        book = self.convert(source)
        xml = self.to_xml(book)

        if output is None:
            src = source if source is not None else self.source
            output = Path(src).with_suffix(".fb2") if isinstance(src, (str, Path)) else Path("book.fb2")
        output = Path(output)
        output.write_text(xml, encoding="utf-8")
        return output

    # --- Чтение DOCX-архива ----------------------------------------------
    @staticmethod
    def _open_zip(source: Union[str, Path, bytes]) -> zipfile.ZipFile:
        """Открыть DOCX как ZIP (из пути или байтов)."""
        if isinstance(source, bytes):
            return zipfile.ZipFile(io.BytesIO(source))
        return zipfile.ZipFile(source)

    def _read_zip(self, name: str) -> Optional[bytes]:
        """Прочитать файл из архива (None, если отсутствует)."""
        if self._zip is None:
            return None
        try:
            return self._zip.read(name)
        except KeyError:
            return None

    @staticmethod
    def _local(tag: str) -> str:
        """Локальное имя тега: '{ns}p' -> 'p'."""
        return tag.rsplit("}", 1)[-1] if "}" in tag else tag

    def _read_document(self) -> ET.Element:
        """Разобрать word/document.xml."""
        data = self._read_zip("word/document.xml")
        if data is None:
            raise Fb2ConversionError("DOCX не содержит word/document.xml")
        try:
            return parse_xml(data)
        except ET.ParseError as exc:
            raise Fb2ConversionError("Не удалось разобрать word/document.xml") from exc

    def _find_body(self, root: ET.Element) -> Optional[ET.Element]:
        """Найти <w:body> в документе."""
        for elem in root.iter():
            if self._local(elem.tag) == "body":
                return elem
        return None

    def _load_rels(self) -> None:
        """Прочитать word/_rels/document.xml.rels -> {rId: target}."""
        data = self._read_zip("word/_rels/document.xml.rels")
        if data is None:
            self._rels = {}
            return
        root = parse_xml(data)
        rels: Dict[str, str] = {}
        for rel in root:
            if self._local(rel.tag) != "Relationship":
                continue
            rel_id = rel.get("Id")
            target = rel.get("Target")
            if rel_id and target:
                rels[rel_id] = target
        self._rels = rels

    def _load_content_types(self) -> None:
        """Прочитать [Content_Types].xml -> {extension: content-type}."""
        data = self._read_zip("[Content_Types].xml")
        if data is None:
            self._default_content_types = {}
            return
        root = parse_xml(data)
        mapping: Dict[str, str] = {}
        for elem in root:
            if self._local(elem.tag) != "Default":
                continue
            extension = (elem.get("Extension") or "").lower()
            content_type = elem.get("ContentType")
            if extension and content_type:
                mapping[extension] = content_type
        self._default_content_types = mapping

    def _read_core_metadata(self) -> Dict[str, Any]:
        """Прочитать docProps/core.xml в словарь метаданных."""
        data = self._read_zip("docProps/core.xml")
        if data is None:
            return {}
        root = parse_xml(data)
        meta: Dict[str, Any] = {}
        for elem in root.iter():
            local = self._local(elem.tag)
            text = (elem.text or "").strip()
            if not text:
                continue
            if local == "title":
                meta["title"] = text
            elif local == "creator":
                meta.setdefault("creators", []).append(text)
            elif local == "language":
                meta["language"] = text
            elif local == "description":
                meta["description"] = text
            elif local == "subject":
                meta.setdefault("subjects", []).append(text)
            elif local == "identifier":
                meta["identifier"] = text
            elif local == "date":
                meta["date"] = text
        return meta

    # --- Парсинг содержимого ----------------------------------------------
    def _convert_body(self, body_elem: ET.Element) -> Body:
        """Преобразовать <w:body> в структуру Body."""
        body = Body()
        root = Section()
        stack: List[Tuple[int, Section]] = [(0, root)]

        for child in body_elem:
            local = self._local(child.tag)
            if local == "p":
                self._handle_paragraph(child, stack)
            elif local == "tbl":
                table = self._convert_table(child)
                if table is not None:
                    stack[-1][1].content.append(table)

        body.sections = root.sections
        if root.content:
            body.sections.insert(0, Section(content=root.content))
        if not body.sections:
            body.sections = [Section()]
        return body

    def _handle_paragraph(self, p: ET.Element, stack: List[Tuple[int, Section]]) -> None:
        """Обработать один абзац в зависимости от его стиля."""
        style = self._paragraph_style(p)
        nodes = self._paragraph_nodes(p)

        if style.startswith("Heading"):
            level = self._heading_level(style)
            while len(stack) > 1 and stack[-1][0] >= level:
                stack.pop()
            new_section = Section(title=Title(items=[Paragraph(content=nodes)]))
            stack[-1][1].sections.append(new_section)
            stack.append((level, new_section))
            return

        if style == "Title":
            text = self._nodes_text(nodes)
            if text:
                self._title_override = text
            return

        if not nodes and not self._has_drawing(p):
            return  # пустой абзац

        if style == "Subtitle":
            stack[-1][1].content.append(Subtitle(content=nodes))
        elif style == "Quote":
            stack[-1][1].content.append(Cite(items=[Paragraph(content=nodes)]))
        else:
            stack[-1][1].content.append(Paragraph(content=nodes))

    def _convert_table(self, tbl: ET.Element) -> Optional[Table]:
        """Преобразовать <w:tbl> в Table."""
        table = Table()
        row_index = 0
        for child in tbl:
            if self._local(child.tag) != "tr":
                continue
            cells: List[TableCell] = []
            for tc in child:
                if self._local(tc.tag) != "tc":
                    continue
                cells.append(
                    TableCell(
                        tag="td",
                        children=self._cell_nodes(tc),
                        is_header=(row_index == 0),
                    )
                )
            if cells:
                table.rows.append(TableRow(cells=cells))
            row_index += 1
        return table if table.rows else None

    def _cell_nodes(self, tc: ET.Element) -> List[StyleNode]:
        """Собрать StyleNode из всех абзацев ячейки таблицы."""
        nodes: List[StyleNode] = []
        for child in tc:
            if self._local(child.tag) == "p":
                if nodes:
                    nodes.append(StyleNode(tag=TEXT_NODE, text="\n"))
                nodes.extend(self._paragraph_nodes(child))
        return nodes

    def _paragraph_style(self, p: ET.Element) -> str:
        """Определить стиль абзаца (по w:pStyle)."""
        ppr = p.find(_w("pPr"))
        if ppr is None:
            return "Normal"
        pstyle = ppr.find(_w("pStyle"))
        if pstyle is None:
            return "Normal"
        return pstyle.get(_w("val"), "Normal")

    @staticmethod
    def _heading_level(style: str) -> int:
        """Извлечь уровень из имени стиля HeadingN."""
        digits = "".join(ch for ch in style if ch.isdigit())
        try:
            level = int(digits)
        except ValueError:
            return 1
        return max(1, min(level, 6))

    def _paragraph_nodes(self, p: ET.Element) -> List[StyleNode]:
        """Собрать StyleNode из runs и hyperlinks абзаца."""
        nodes: List[StyleNode] = []
        for child in p:
            local = self._local(child.tag)
            if local == "r":
                node = self._run_node(child)
                if node is not None:
                    nodes.append(node)
            elif local == "hyperlink":
                href = self._hyperlink_target(child)
                children: List[StyleNode] = []
                for r in child:
                    if self._local(r.tag) == "r":
                        node = self._run_node(r)
                        if node is not None:
                            children.append(node)
                if href:
                    nodes.append(StyleNode(tag="a", href=href, children=children))
                else:
                    nodes.extend(children)
        return nodes

    def _run_node(self, r: ET.Element) -> Optional[StyleNode]:
        """Преобразовать <w:r> в StyleNode (текст/изображение)."""
        props = self._run_props(r)
        text_parts: List[str] = []
        for child in r:
            local = self._local(child.tag)
            if local == "t":
                text_parts.append(child.text or "")
            elif local == "drawing":
                image_href = self._drawing_image(child)
                if image_href:
                    return StyleNode(tag="image", image_href=image_href)

        text = "".join(text_parts)
        if not text:
            return None

        node: StyleNode = StyleNode(tag=TEXT_NODE, text=text)
        for tag in props:
            node = StyleNode(tag=tag, children=[node])
        return node

    def _run_props(self, r: ET.Element) -> List[str]:
        """Определить inline-разметку run (strong/emphasis/...)."""
        props: List[str] = []
        rpr = r.find(_w("rPr"))
        if rpr is None:
            return props
        if rpr.find(_w("b")) is not None:
            props.append("strong")
        if rpr.find(_w("i")) is not None:
            props.append("emphasis")
        if rpr.find(_w("strike")) is not None:
            props.append("strikethrough")
        vert = rpr.find(_w("vertAlign"))
        if vert is not None:
            value = vert.get(_w("val"))
            if value == "subscript":
                props.append("sub")
            elif value == "superscript":
                props.append("sup")
        rstyle = rpr.find(_w("rStyle"))
        if rstyle is not None and rstyle.get(_w("val")) == "Code":
            props.append("code")
        return props

    def _hyperlink_target(self, hyperlink: ET.Element) -> Optional[str]:
        """Вернуть URL гиперссылки по r:id."""
        rel_id = hyperlink.get(_r("id"))
        if not rel_id:
            return None
        return self._rels.get(rel_id)

    def _drawing_image(self, drawing: ET.Element) -> Optional[str]:
        """Вернуть href FB2 (#id) для встроенного изображения."""
        for elem in drawing.iter():
            if self._local(elem.tag) == "blip":
                embed = elem.get(_r("embed"))
                if embed:
                    return self._image_href_for_rid(embed)
        return None

    def _has_drawing(self, p: ET.Element) -> bool:
        """Проверить, есть ли в абзаце встроенное изображение."""
        for elem in p.iter():
            if self._local(elem.tag) == "drawing":
                return True
        return False

    @staticmethod
    def _nodes_text(nodes: List[StyleNode]) -> str:
        """Собрать текст из списка StyleNode."""
        parts: List[str] = []
        for node in nodes:
            if node.tag == TEXT_NODE:
                parts.append(node.text or "")
            else:
                parts.append(DocxToFb2Converter._nodes_text(node.children))
        return "".join(parts)

    # --- Изображения ------------------------------------------------------
    def _image_href_for_rid(self, rel_id: str) -> Optional[str]:
        """Загрузить media-файл и вернуть href FB2 (#id)."""
        if rel_id in self._rid_to_fb2id:
            return "#" + self._rid_to_fb2id[rel_id]

        target = self._rels.get(rel_id)
        if not target:
            return None
        data = self._read_zip("word/" + target.lstrip("/"))
        if data is None:
            return None

        content_type = self._content_type_for(target)
        fb2_id = self._allocate_image_id(target)
        self._binaries.append(
            Binary(id=fb2_id, content_type=content_type, data=base64.b64encode(data).decode("ascii"))
        )
        self._rid_to_fb2id[rel_id] = fb2_id
        return "#" + fb2_id

    def _content_type_for(self, target: str) -> str:
        """Определить content-type media-файла по расширению и [Content_Types]."""
        extension = posixpath.splitext(target)[1].lstrip(".").lower()
        if extension in self._default_content_types:
            return self._default_content_types[extension]
        return _CONTENT_TYPE_BY_EXT.get("." + extension, "application/octet-stream")

    def _allocate_image_id(self, target: str) -> str:
        """Сгенерировать валидный уникальный XML-ID для <binary>."""
        base = Path(target).stem
        base = re.sub(r"[^A-Za-z0-9_.-]", "_", base) or "image"
        if not re.match(r"^[A-Za-z_]", base):
            base = "image_" + base
        candidate = base
        counter = 1
        while candidate in self._used_ids:
            counter += 1
            candidate = f"{base}_{counter}"
        self._used_ids.add(candidate)
        return candidate

    # --- Сборка FictionBook ----------------------------------------------
    @staticmethod
    def _creators(meta: Dict[str, Any]) -> List[str]:
        """Список авторов из метаданных."""
        return [str(c) for c in meta.get("creators", [])]

    def _genres(self, meta: Dict[str, Any]) -> List[str]:
        """Жанры из <dc:subject> (фолбэк — default_genre)."""
        subjects = [str(s) for s in meta.get("subjects", [])]
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

    @staticmethod
    def _annotation(meta: Dict[str, Any]) -> Optional[Annotation]:
        """Аннотация из <dc:description>."""
        desc = str(meta.get("description") or "")
        if not desc:
            return None
        return Annotation(items=[Paragraph(content=[StyleNode(tag=TEXT_NODE, text=desc)])])

    def _assemble(self, meta: Dict[str, Any], body: Body) -> FictionBook:
        """Собрать корневую структуру FictionBook."""
        title = str(meta.get("title") or self._title_override or "Untitled")
        creators = [self._split_author(c) for c in self._creators(meta)]

        title_info = TitleInfo(
            genres=[Genre(value=g) for g in self._genres(meta)],
            authors=creators,
            book_title=TextField(value=title),
            annotation=self._annotation(meta),
            lang=str(meta.get("language") or "ru"),
        )
        document_info = DocumentInfo(
            authors=[Author(nickname="pyFB2")],
            program_used=TextField(value=self.program_used),
            date=DateField(value=str(meta.get("date") or date.today().isoformat())),
            id=str(meta.get("identifier") or uuid.uuid4().hex),
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


__all__ = ["DocxToFb2Converter"]


def main(argv: List[str] | None = None) -> int:
    if argv is None:
        argv = sys.argv
    if len(argv) < 2:
        print(
            "Использование: python docx_to_fb2.py <файл.docx> [выход.fb2]",
            file=sys.stderr,
        )
        return 2
    source = argv[1]
    output = argv[2] if len(argv) > 2 else str(Path(source).with_suffix(".fb2"))
    converter = DocxToFb2Converter()
    path = converter.write(source, output)
    print("FB2:", path)
    if converter.book is not None:
        print("Изображений:", len(converter.book.binaries))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))





