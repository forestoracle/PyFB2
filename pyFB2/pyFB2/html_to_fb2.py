"""Преобразование HTML в FictionBook (FB2).

Модуль предоставляет класс :class:`HtmlToFb2Converter`, который читает
HTML-документ (в формате, генерируемом :mod:`fb2_to_html`, либо произвольный)
и собирает из него структуры FB2, после чего сериализует их в XML
FictionBook 2.0 (через общий :class:`~fb2_writer.Fb2Writer`).

Что поддерживается:

    * ``<header class="book-header">`` -> заголовок, автор, жанры, обложка,
      аннотация;
    * ``<h1>``-``<h6>`` (с id-якорями) -> иерархия <section>/<title>;
    * ``<p>``, ``<strong>``, ``<em>``, ``<del>``, ``<sub>``/``<sup>``/``<code>``,
      ``<span class>``, ``<a>``, ``<img>``;
    * ``<blockquote>``/``class="epigraph"`` -> <cite>/<epigraph>;
    * ``<div class="poem">`` -> <poem>/<stanza>/<v>;
    * ``<table>`` -> <table>, ``<hr>`` -> <empty-line>;
    * изображения (файлы рядом с .html или data-URI) -> <binary> (base64).

Пример::

    >>> from html_to_fb2 import HtmlToFb2Converter
    >>> converter = HtmlToFb2Converter()
    >>> path = converter.write("book.html", "book.fb2")
    WindowsPath('book.fb2')
    >>> book = converter.convert("book.html")   # структура FictionBook
    >>> xml = converter.to_xml(book)            # XML-строка FB2
"""

from __future__ import annotations

import base64
import json
import re
import sys
import uuid
from datetime import date
from html.parser import HTMLParser
from pathlib import Path
from typing import Any, Dict, Iterator, List, Optional, Tuple, Union

from .fb2_errors import Fb2ConversionError
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
    Epigraph,
    FictionBook,
    Genre,
    Image,
    InlineImage,
    Paragraph,
    Poem,
    Section,
    Stanza,
    StyleNode,
    Subtitle,
    Table,
    TableCell,
    TableRow,
    TextField,
    Title,
    TitleInfo,
)
from .fb2_writer import TEXT_NODE, Fb2Writer

#: Теги заголовков HTML.
HEADING_TAGS = frozenset({"h1", "h2", "h3", "h4", "h5", "h6"})

#: Пустые (void) теги HTML, не имеющие закрывающего.
VOID_TAGS = frozenset(
    {
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr",
    }
)

#: Жанр по умолчанию (если в HTML нет подходящих жанров).
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

#: Проверка корректности XML-ID.
_ID_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_.-]*$")


class _Node:
    """Узел разобранного HTML-дерева."""

    __slots__ = ("tag", "attrs", "children")

    def __init__(self, tag: str, attrs: Optional[Dict[str, str]] = None) -> None:
        self.tag = tag
        self.attrs = attrs or {}
        self.children: List[Union["_Node", str]] = []


class _HtmlParser(HTMLParser):
    """Толерантный HTML-парсер, строящий дерево узлов."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.root = _Node("#document")
        self._stack: List[_Node] = [self.root]

    def handle_starttag(self, tag: str, attrs) -> None:
        node = _Node(tag, {name: value for name, value in attrs if value is not None})
        self._stack[-1].children.append(node)
        if tag not in VOID_TAGS:
            self._stack.append(node)

    def handle_startendtag(self, tag: str, attrs) -> None:
        node = _Node(tag, {name: value for name, value in attrs if value is not None})
        self._stack[-1].children.append(node)

    def handle_endtag(self, tag: str) -> None:
        if tag in VOID_TAGS:
            return
        for index in range(len(self._stack) - 1, 0, -1):
            if self._stack[index].tag == tag:
                del self._stack[index:]
                break

    def handle_data(self, data: str) -> None:
        self._stack[-1].children.append(data)


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


class HtmlToFb2Converter:
    """Преобразование HTML в структуры FB2 и обратно в XML.

    :param source: путь к ``.html``/``.htm`` (``str``/``Path``) либо сам
        HTML-текст. Может передаваться в конструктор или в методы
        :meth:`convert` / :meth:`write`.
    :param default_genre: жанр FB2 по умолчанию, если в HTML нет жанров.
    :param program_used: значение ``<program-used>`` в ``document-info``.
    """

    def __init__(
        self,
        source: Optional[Union[str, Path]] = None,
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
        self._base_dir: Optional[Path] = None
        self._binaries: List[Binary] = []
        self._used_ids: set = set()

    # --- Публичный API -----------------------------------------------------
    @property
    def book(self) -> Optional[FictionBook]:
        """Последняя собранная структура :class:`FictionBook` (или None)."""
        return self._book

    def convert(self, source: Optional[Union[str, Path]] = None) -> FictionBook:
        """Прочитать HTML и вернуть структуру :class:`FictionBook`.

        :param source: путь к .html или HTML-текст (иначе ``self.source``).
        """
        if source is not None:
            self.source = source
        if self.source is None:
            raise Fb2ConversionError("Не задан источник HTML (source)")

        self._reset()
        text, base_dir = self._read_source(self.source)
        self._base_dir = base_dir
        self._book = self._parse(text)
        return self._book

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
        source: Optional[Union[str, Path]] = None,
        output: Optional[Union[str, Path]] = None,
    ) -> Path:
        """Преобразовать HTML в файл FB2 и вернуть путь к результату.

        :param source: путь к .html или HTML-текст (иначе ``self.source``).
        :param output: путь к выходному ``.fb2``; по умолчанию — рядом с
            исходным ``.html`` (или ``book.fb2``, если источник — текст).
        """
        book = self.convert(source)
        xml = self.to_xml(book)

        if output is None:
            src = source if source is not None else self.source
            output = Path(src).with_suffix(".fb2") if isinstance(src, (str, Path)) else Path("book.fb2")
        output = Path(output)
        output.write_text(xml, encoding="utf-8")
        return output

    def _read_source(self, source: Union[str, Path]) -> Tuple[str, Optional[Path]]:
        """Прочитать источник: вернуть HTML-текст и каталог (для изображений)."""
        if isinstance(source, Path):
            return source.read_text(encoding="utf-8"), source.parent
        if isinstance(source, str):
            path = Path(source)
            if path.is_file():
                return path.read_text(encoding="utf-8"), path.parent
            return source, None
        raise Fb2ConversionError(f"Неподдерживаемый тип источника: {type(source).__name__}")

    # --- Разбор HTML -------------------------------------------------------
    def _parse(self, text: str) -> FictionBook:
        """Разобрать HTML-текст в структуру FictionBook."""
        parser = _HtmlParser()
        parser.feed(text)
        parser.close()

        body = self._find_body(parser.root)
        if body is None:
            body = parser.root

        meta = self._collect_metadata(body)
        fb2_body = self._convert_content(body)
        return self._assemble(meta, fb2_body)

    def _find_body(self, node: _Node) -> Optional[_Node]:
        """Найти первый <body> в дереве."""
        for child in node.children:
            if isinstance(child, _Node):
                if child.tag == "body":
                    return child
                found = self._find_body(child)
                if found is not None:
                    return found
        return None

    def _convert_content(self, body: _Node) -> Body:
        """Преобразовать содержимое <body> в структуру Body."""
        fb2_body = Body()
        root = Section()
        stack: List[Tuple[int, Section]] = [(0, root)]

        for child in body.children:
            if isinstance(child, _Node) and not self._is_skip(child):
                self._walk(child, stack)

        fb2_body.sections = root.sections
        if root.content:
            fb2_body.sections.insert(0, Section(content=root.content))
        if not fb2_body.sections:
            fb2_body.sections = [Section()]
        return fb2_body

    @staticmethod
    def _is_skip(node: _Node) -> bool:
        """Пропускать ли узел (метаданные, оглавление, служебные теги)."""
        classes = node.attrs.get("class", "").split()
        if node.tag in ("header", "nav", "head", "script", "style"):
            return True
        return "book-header" in classes or "toc" in classes

    def _walk(self, node: _Node, stack: List[Tuple[int, Section]]) -> None:
        """Обойти узел, строя иерархию секций по заголовкам."""
        tag = node.tag

        if tag in HEADING_TAGS:
            level = int(tag[1])
            while len(stack) > 1 and stack[-1][0] >= level:
                stack.pop()
            nodes = self._convert_inline(node.children)
            section = Section(title=Title(items=[Paragraph(content=nodes)]))
            stack[-1][1].sections.append(section)
            stack.append((level, section))
            return

        if tag == "div":
            classes = node.attrs.get("class", "").split()
            if any(c in classes for c in ("poem", "image", "annotation")):
                block = self._convert_block(node)
                if block is not None:
                    stack[-1][1].content.append(block)
                return
            self._walk_children(node, stack)
            return

        if tag in ("section", "article", "main"):
            section_id = node.attrs.get("id")
            classes = (node.attrs.get("class") or "").split()
            if section_id and "footnote" in classes:
                # сноска: сохраняем id, иначе ссылки из текста станут битыми
                container = Section(id=section_id)
                stack[-1][1].sections.append(container)
                self._walk_children(node, [(stack[-1][0], container)])
                return
            self._walk_children(node, stack)
            return

        block = self._convert_block(node)
        if block is not None:
            stack[-1][1].content.append(block)

    def _walk_children(self, node: _Node, stack: List[Tuple[int, Section]]) -> None:
        """Обойти дочерние узлы-контейнеры."""
        for child in node.children:
            if isinstance(child, _Node):
                self._walk(child, stack)

    # --- Метаданные --------------------------------------------------------
    def _collect_metadata(self, body: _Node) -> Dict[str, Any]:
        """Собрать метаданные из <header class="book-header">."""
        meta: Dict[str, Any] = {
            "title": "",
            "creators": [],
            "genres": [],
            "annotation": None,
            "cover": None,
        }
        for child in body.children:
            if isinstance(child, _Node):
                classes = child.attrs.get("class", "").split()
                if child.tag == "header" or "book-header" in classes:
                    self._parse_header(child, meta)
        return meta

    def _parse_header(self, header: _Node, meta: Dict[str, Any]) -> None:
        """Разобрать элементы заголовка книги."""
        for child in header.children:
            if not isinstance(child, _Node):
                continue
            classes = child.attrs.get("class", "").split()
            if "book-title" in classes:
                meta["title"] = self._nodes_text(child.children)
            elif "book-author" in classes:
                text = self._nodes_text(child.children)
                meta["creators"] = [a.strip() for a in text.split(";") if a.strip()]
            elif "book-genres" in classes:
                text = self._nodes_text(child.children)
                meta["genres"] = [g.strip() for g in text.split(",") if g.strip()]
            elif "annotation" in classes:
                meta["annotation"] = self._convert_annotation(child)
            elif "cover" in classes:
                img = self._find_img(child)
                if img is not None:
                    meta["cover"] = self._register_image(img.attrs.get("src"))

    def _convert_annotation(self, node: _Node) -> Optional[Annotation]:
        """Аннотация -> Annotation."""
        items: List = []
        for child in node.children:
            if isinstance(child, _Node):
                block = self._convert_block(child)
                if block is not None:
                    items.append(block)
        return Annotation(items=items) if items else None

    @staticmethod
    def _nodes_text(children: List[Union[_Node, str]]) -> str:
        """Собрать простой текст из дочерних узлов."""
        parts: List[str] = []
        for child in children:
            if isinstance(child, str):
                parts.append(child)
            else:
                parts.append(HtmlToFb2Converter._nodes_text(child.children))
        return "".join(parts).strip()

    # --- Блочные элементы --------------------------------------------------
    def _convert_block(self, node: _Node):
        """Один блочный элемент HTML -> структура FB2 (или None)."""
        tag = node.tag
        classes = node.attrs.get("class", "").split()

        if tag == "p":
            if "footnote-back" in classes:
                # обратная ссылка из сноски — служебный элемент вывода
                return None
            if "subtitle" in classes:
                return Subtitle(content=self._convert_inline(node.children))
            if "empty-line" in classes:
                return EmptyLine()
            return Paragraph(content=self._convert_inline(node.children))
        if tag == "blockquote":
            return self._convert_epigraph(node) if "epigraph" in classes else self._convert_cite(node)
        if tag == "table":
            return self._convert_table(node)
        if tag == "hr":
            return EmptyLine()
        if tag == "img":
            return self._convert_image_block(node)
        if tag in HEADING_TAGS:
            return Subtitle(content=self._convert_inline(node.children))
        if tag == "div":
            if "poem" in classes:
                return self._convert_poem(node)
            if "image" in classes:
                img = self._find_img(node)
                if img is not None:
                    return self._convert_image_block(img)
            return None
        return None

    def _convert_cite(self, node: _Node) -> Cite:
        """<blockquote> -> <cite>."""
        cite = Cite()
        for child in node.children:
            if not isinstance(child, _Node):
                continue
            if child.tag == "p" and "text-author" in child.attrs.get("class", "").split():
                cite.text_author.append(Paragraph(content=self._convert_inline(child.children)))
            else:
                block = self._convert_block(child)
                if block is not None:
                    cite.items.append(block)
        return cite

    def _convert_epigraph(self, node: _Node) -> Epigraph:
        """<blockquote class="epigraph"> -> <epigraph>."""
        epigraph = Epigraph()
        for child in node.children:
            if not isinstance(child, _Node):
                continue
            if child.tag == "p" and "text-author" in child.attrs.get("class", "").split():
                epigraph.text_author.append(Paragraph(content=self._convert_inline(child.children)))
            else:
                block = self._convert_block(child)
                if block is not None:
                    epigraph.items.append(block)
        return epigraph

    def _convert_poem(self, node: _Node) -> Poem:
        """<div class="poem"> -> <poem>."""
        poem = Poem()
        for child in node.children:
            if not isinstance(child, _Node):
                continue
            classes = child.attrs.get("class", "").split()
            if child.tag == "p" and "poem-title" in classes:
                poem.title = Title(items=[Paragraph(content=self._convert_inline(child.children))])
            elif child.tag == "div" and "stanza" in classes:
                poem.items.append(self._convert_stanza(child))
            elif child.tag == "p" and "text-author" in classes:
                poem.text_author.append(Paragraph(content=self._convert_inline(child.children)))
            elif child.tag == "p" and "subtitle" in classes:
                poem.items.append(Subtitle(content=self._convert_inline(child.children)))
            elif child.tag == "blockquote":
                poem.epigraphs.append(self._convert_epigraph(child))
        return poem

    def _convert_stanza(self, node: _Node) -> Stanza:
        """<div class="stanza"> -> <stanza>."""
        stanza = Stanza()
        for child in node.children:
            if not isinstance(child, _Node):
                continue
            classes = child.attrs.get("class", "").split()
            if child.tag == "p" and "verse" in classes:
                stanza.verses.append(Paragraph(content=self._convert_inline(child.children)))
            elif child.tag == "p" and "subtitle" in classes:
                stanza.subtitle = Subtitle(content=self._convert_inline(child.children))
            elif child.tag == "p" and "poem-title" in classes:
                stanza.title = Title(items=[Paragraph(content=self._convert_inline(child.children))])
        return stanza

    def _convert_table(self, node: _Node) -> Optional[Table]:
        """<table> -> <table>."""
        table = Table()
        for tr in self._iter(node, "tr"):
            cells: List[TableCell] = []
            for td in tr.children:
                if isinstance(td, _Node) and td.tag in ("td", "th"):
                    cells.append(
                        TableCell(
                            tag=td.tag,
                            children=self._convert_inline(td.children),
                            colspan=self._to_int(td.attrs.get("colspan")),
                            rowspan=self._to_int(td.attrs.get("rowspan")),
                            is_header=(td.tag == "th"),
                        )
                    )
            if cells:
                table.rows.append(TableRow(cells=cells))
        return table if table.rows else None

    def _iter(self, node: _Node, tag: str) -> Iterator[_Node]:
        """Рекурсивно найти все вложенные узлы с данным тегом."""
        for child in node.children:
            if isinstance(child, _Node):
                if child.tag == tag:
                    yield child
                yield from self._iter(child, tag)

    @staticmethod
    def _find_img(node: _Node) -> Optional[_Node]:
        """Первый вложенный <img>."""
        for child in node.children:
            if isinstance(child, _Node):
                if child.tag == "img":
                    return child
                found = HtmlToFb2Converter._find_img(child)
                if found is not None:
                    return found
        return None

    @staticmethod
    def _to_int(value: Optional[str]) -> Optional[int]:
        """Мягкое приведение строки к int."""
        try:
            return int(value) if value else None
        except (ValueError, TypeError):
            return None

    # --- Inline-разметка ---------------------------------------------------
    def _convert_inline(self, children: List[Union[_Node, str]]) -> List[StyleNode]:
        """Разобрать inline-разметку HTML в список StyleNode."""
        result: List[StyleNode] = []
        for child in children:
            if isinstance(child, str):
                if child:
                    result.append(StyleNode(tag=TEXT_NODE, text=child))
                continue

            tag = child.tag
            if tag in ("strong", "b"):
                result.append(StyleNode(tag="strong", children=self._convert_inline(child.children)))
            elif tag in ("em", "i"):
                result.append(StyleNode(tag="emphasis", children=self._convert_inline(child.children)))
            elif tag in ("del", "s", "strike"):
                result.append(StyleNode(tag="strikethrough", children=self._convert_inline(child.children)))
            elif tag in ("sub", "sup", "code"):
                result.append(StyleNode(tag=tag, children=self._convert_inline(child.children)))
            elif tag == "span":
                result.append(
                    StyleNode(
                        tag="style",
                        name=child.attrs.get("class"),
                        children=self._convert_inline(child.children),
                    )
                )
            elif tag == "a":
                classes = (child.attrs.get("class") or "").split()
                if "footnote-back" in classes:
                    # обратная ссылка из сноски — служебная, в FB2 не нужна
                    continue
                result.append(
                    StyleNode(
                        tag="a",
                        href=child.attrs.get("href"),
                        link_type="note" if "note-ref" in classes else None,
                        children=self._convert_inline(child.children),
                    )
                )
            elif tag == "img":
                href = self._register_image(child.attrs.get("src"))
                if href:
                    result.append(
                        StyleNode(tag="image", image_href=href, image_alt=child.attrs.get("alt"))
                    )
            elif tag == "br":
                result.append(StyleNode(tag=TEXT_NODE, text="\n"))
            else:
                # прочие (span без класса, font, u, ...) — разворачиваем
                result.extend(self._convert_inline(child.children))
        return result

    # --- Изображения -------------------------------------------------------
    def _convert_image_block(self, node: _Node) -> Optional[Image]:
        """<img> -> блочное <image>."""
        href = self._register_image(node.attrs.get("src"))
        if not href:
            return None
        return Image(href=href, alt=node.attrs.get("alt"))

    def _register_image(self, src: Optional[str]) -> Optional[str]:
        """Зарегистрировать изображение (файл или data-URI) -> href FB2 (#id)."""
        if not src:
            return None
        src = src.strip()
        if src.startswith("data:"):
            return self._register_data_uri(src)
        if self._base_dir is None:
            return None

        path = Path(self._base_dir) / src
        if not path.is_file():
            return None
        data = path.read_bytes()
        content_type = _CONTENT_TYPE_BY_EXT.get(path.suffix.lower(), "application/octet-stream")
        fb2_id = self._unique_id(path.name)
        self._binaries.append(
            Binary(id=fb2_id, content_type=content_type, data=base64.b64encode(data).decode("ascii"))
        )
        return "#" + fb2_id

    def _register_data_uri(self, src: str) -> Optional[str]:
        """Зарегистрировать изображение из data-URI -> href FB2 (#id)."""
        header, sep, payload = src.partition(",")
        if not sep:
            return None
        meta = header[len("data:"):]
        parts = meta.split(";")
        content_type = parts[0] or "image/png"
        is_base64 = "base64" in parts[1:]
        try:
            data = base64.b64decode(payload) if is_base64 else payload.encode("utf-8")
        except (ValueError, TypeError):
            return None
        if not content_type.startswith("image/"):
            return None

        fb2_id = self._unique_id("image")
        self._binaries.append(
            Binary(id=fb2_id, content_type=content_type, data=base64.b64encode(data).decode("ascii"))
        )
        return "#" + fb2_id

    def _unique_id(self, name: str) -> str:
        """Сгенерировать уникальный валидный XML-ID для <binary>."""
        candidate = name if _ID_RE.match(name) else self._sanitize_id(name)
        if candidate not in self._used_ids:
            self._used_ids.add(candidate)
            return candidate
        stem = Path(name).stem
        suffix = Path(name).suffix
        counter = 1
        while f"{stem}_{counter}{suffix}" in self._used_ids:
            counter += 1
        result = f"{stem}_{counter}{suffix}"
        self._used_ids.add(result)
        return result

    @staticmethod
    def _sanitize_id(name: str) -> str:
        """Привести имя файла к валидному XML-ID."""
        base = re.sub(r"[^A-Za-z0-9_.-]", "_", name)
        if not _ID_RE.match(base):
            base = "image_" + base
        return base

    # --- Сборка FictionBook ----------------------------------------------
    def _match_genres(self, subjects: List[str]) -> List[str]:
        """Сопоставить названия жанров с кодами FictionBookGenres."""
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

    def _assemble(self, meta: Dict[str, Any], body: Body) -> FictionBook:
        """Собрать корневую структуру FictionBook."""
        title = str(meta.get("title") or "Untitled")
        creators = [self._split_author(str(c)) for c in meta.get("creators", [])]
        genres = [str(g) for g in meta.get("genres", [])]
        cover = meta.get("cover")
        annotation = meta.get("annotation")

        title_info = TitleInfo(
            genres=[Genre(value=g) for g in self._match_genres(genres)],
            authors=creators,
            book_title=TextField(value=title),
            annotation=annotation if isinstance(annotation, Annotation) else None,
            coverpage=CoverPage(images=[InlineImage(href=str(cover))]) if cover else None,
            lang="ru",
        )
        document_info = DocumentInfo(
            authors=[Author(nickname="pyFB2")],
            program_used=TextField(value=self.program_used),
            date=DateField(value=date.today().isoformat()),
            id=uuid.uuid4().hex,
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


__all__ = ["HtmlToFb2Converter"]


def main(argv: List[str] | None = None) -> int:
    if argv is None:
        argv = sys.argv
    if len(argv) < 2:
        print(
            "Использование: python html_to_fb2.py <файл.html> [выход.fb2]",
            file=sys.stderr,
        )
        return 2
    source = argv[1]
    output = argv[2] if len(argv) > 2 else str(Path(source).with_suffix(".fb2"))
    converter = HtmlToFb2Converter()
    path = converter.write(source, output)
    print("FB2:", path)
    if converter.book is not None:
        print("Изображений:", len(converter.book.binaries))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))








