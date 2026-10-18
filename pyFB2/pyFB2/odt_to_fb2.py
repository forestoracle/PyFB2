# -*- coding: utf-8 -*-
"""Преобразование OpenDocument Text (ODT) в книгу FB2.

Модуль читает ODT-файл (ZIP-контейнер OpenDocument), переносит текст
(заголовки, абзацы, разметку, таблицы, изображения) и метаданные
(``meta.xml``) в структуры :class:`~fb2_structures.FictionBook`.

Обратное преобразование к :mod:`fb2_to_odt`. Внешних зависимостей нет.

Пример:
    >>> from odt_to_fb2 import OdtToFb2Converter
    >>> OdtToFb2Converter().write("book.odt", "book.fb2")
    WindowsPath('book.fb2')

CLI:
    python odt_to_fb2.py book.odt [book.fb2]
"""

from __future__ import annotations

import base64
import io
import sys
import uuid
import zipfile
from datetime import date
from pathlib import Path
from typing import Dict, FrozenSet, List, Optional, Tuple, Union

import xml.etree.ElementTree as ET

from .fb2_errors import Fb2ConversionError
from .fb2_images import detect_image_type, extension_for
from .fb2_parser import TEXT_NODE
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
    Poem,
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
from .fb2_writer import Fb2Writer
from .fb2_xml import parse_xml

#: Пространства имён ODF.
NS_OFFICE = "urn:oasis:names:tc:opendocument:xmlns:office:1.0"
NS_TEXT = "urn:oasis:names:tc:opendocument:xmlns:text:1.0"
NS_STYLE = "urn:oasis:names:tc:opendocument:xmlns:style:1.0"
NS_FO = "urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0"
NS_DRAW = "urn:oasis:names:tc:opendocument:xmlns:drawing:1.0"
NS_TABLE = "urn:oasis:names:tc:opendocument:xmlns:table:1.0"
NS_XLINK = "http://www.w3.org/1999/xlink"
NS_DC = "http://purl.org/dc/elements/1.1/"

#: Атрибуты (в формате ``{ns}имя``), которые нужно читать.
ATTR_STYLE_NAME = f"{{{NS_TEXT}}}style-name"
ATTR_OUTLINE = f"{{{NS_TEXT}}}outline-level"
ATTR_HREF = f"{{{NS_XLINK}}}href"
ATTR_FONT_WEIGHT = f"{{{NS_FO}}}font-weight"
ATTR_FONT_STYLE = f"{{{NS_FO}}}font-style"
ATTR_LINE_THROUGH = f"{{{NS_STYLE}}}text-line-through-style"
ATTR_TEXT_POSITION = f"{{{NS_STYLE}}}text-position"

#: Стили абзацев ODT, распознаваемые при импорте.
HEADER_TITLE_STYLE = "Title"
HEADER_AUTHOR_STYLE = "Subtitle"
HEADER_ANNOTATION_STYLE = "Annotation"
SUBTITLE_STYLES = {"Subtitle2"}

#: Флаги разметки -> теги FB2.
FLAG_TO_TAG = {
    "strong": "strong",
    "emphasis": "emphasis",
    "strikethrough": "strikethrough",
    "sub": "sub",
    "sup": "sup",
    "code": "code",
}

#: Блоки, допустимые внутри ``<annotation>`` FB2.
AnnotationBlock = Union[Paragraph, Poem, Cite, Subtitle, Table, EmptyLine]


class OdtToFb2Converter:
    """Преобразование ODT в FB2.

    :param writer: готовый :class:`~fb2_writer.Fb2Writer`.
    :param default_genre: жанр, если в документе он не указан.
    :param program_used: значение ``<program-used>`` в ``<document-info>``.
    """

    def __init__(
        self,
        writer: Optional[Fb2Writer] = None,
        default_genre: str = "sf",
        program_used: str = "pyFB2",
    ) -> None:
        self.writer = writer if writer is not None else Fb2Writer()
        self.default_genre = default_genre
        self.program_used = program_used
        self.source: Optional[Union[str, Path, bytes]] = None
        self._book: Optional[FictionBook] = None
        self._reset()

    def _reset(self) -> None:
        """Очистить состояние для нового преобразования."""
        self._zip: Optional[zipfile.ZipFile] = None
        self._text_styles: Dict[str, FrozenSet[str]] = {}
        self._binaries: List[Binary] = []
        self._binary_ids: Dict[str, str] = {}
        self._title_override = ""
        self._creators_override: List[str] = []
        self._annotation_override: List[str] = []
        self._cover_href: Optional[str] = None
        self._in_header = True

    # --- Публичный API -----------------------------------------------------
    @property
    def book(self) -> Optional[FictionBook]:
        """Последняя собранная структура :class:`FictionBook` (или None)."""
        return self._book

    def convert(
        self, source: Optional[Union[str, Path, bytes]] = None
    ) -> FictionBook:
        """Прочитать ODT и вернуть структуру :class:`FictionBook`.

        :param source: путь или байты ODT (иначе берётся ``self.source``).
        """
        if source is not None:
            self.source = source
        if self.source is None:
            raise Fb2ConversionError("Не задан источник ODT (source)")

        self._reset()
        self._zip = self._open_zip(self.source)
        try:
            meta = self._read_meta()
            content = self._read_content()
            text_root = self._find_text(content)
            if text_root is None:
                raise Fb2ConversionError("В ODT не найден элемент <office:text>")
            self._text_styles = self._load_text_styles(content)
            body = self._convert_body(text_root)
            self._book = self._assemble(meta, body)
            return self._book
        finally:
            self._zip.close()
            self._zip = None

    def to_xml(self, book: Optional[FictionBook] = None) -> str:
        """Сериализовать книгу (или результат :meth:`convert`) в XML FB2."""
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
        """Преобразовать ODT в файл FB2 и вернуть путь к результату.

        :param source: путь/байты ODT (иначе ``self.source``).
        :param output: путь к ``.fb2``; по умолчанию — рядом с исходным ``.odt``.
        """
        book = self.convert(source)
        xml = self.to_xml(book)

        if output is None:
            src = source if source is not None else self.source
            output = (
                Path(src).with_suffix(".fb2")
                if isinstance(src, (str, Path))
                else Path("book.fb2")
            )
        output = Path(output)
        output.write_text(xml, encoding="utf-8")
        return output

    # --- Чтение архива -----------------------------------------------------
    @staticmethod
    def _open_zip(source: Union[str, Path, bytes]) -> zipfile.ZipFile:
        """Открыть ODT как ZIP (из пути или байтов)."""
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

    # --- Чтение content.xml / meta.xml -------------------------------------
    def _read_content(self) -> ET.Element:
        """Разобрать ``content.xml``."""
        data = self._read_zip("content.xml")
        if data is None:
            raise Fb2ConversionError("ODT не содержит content.xml")
        try:
            return parse_xml(data)
        except ET.ParseError as exc:
            raise Fb2ConversionError("Не удалось разобрать content.xml") from exc

    @staticmethod
    def _find_text(root: ET.Element) -> Optional[ET.Element]:
        """Найти ``<office:text>`` в документе."""
        for element in root.iter():
            if OdtToFb2Converter._local(element.tag) == "text":
                return element
        return None

    def _read_meta(self) -> Dict[str, object]:
        """Прочитать метаданные из ``meta.xml`` (если он есть)."""
        meta: Dict[str, object] = {}
        data = self._read_zip("meta.xml")
        if data is None:
            return meta
        try:
            root = parse_xml(data)
        except ET.ParseError:
            return meta

        creators: List[str] = []
        subjects: List[str] = []
        for element in root.iter():
            local = self._local(element.tag)
            text = (element.text or "").strip()
            if not text:
                continue
            if local == "title":
                meta["title"] = text
            elif local == "creator":
                creators.append(text)
            elif local == "language":
                meta["language"] = text
            elif local == "date":
                meta.setdefault("date", text)
            elif local == "description":
                meta["description"] = text
            elif local == "subject":
                subjects.append(text)
        if creators:
            meta["creators"] = creators
        if subjects:
            meta["subjects"] = subjects
        return meta

    def _load_text_styles(self, root: ET.Element) -> Dict[str, FrozenSet[str]]:
        """Собрать оформление текстовых стилей (для ``text:span``)."""
        styles: Dict[str, FrozenSet[str]] = {}
        for style in root.iter():
            if self._local(style.tag) != "style":
                continue
            name = style.get(f"{{{NS_STYLE}}}name")
            if not name:
                continue
            flags: set = set()
            for element in style.iter():
                if self._local(element.tag) != "text-properties":
                    continue
                if (element.get(ATTR_FONT_WEIGHT) or "").lower() == "bold":
                    flags.add("strong")
                if (element.get(ATTR_FONT_STYLE) or "").lower() == "italic":
                    flags.add("emphasis")
                if element.get(ATTR_LINE_THROUGH):
                    flags.add("strikethrough")
                position = (element.get(ATTR_TEXT_POSITION) or "").lower()
                if position.startswith("sub"):
                    flags.add("sub")
                elif position.startswith(("super", "sup")):
                    flags.add("sup")
                font = (element.get(f"{{{NS_STYLE}}}font-name") or "").lower()
                if "courier" in font or "mono" in font:
                    flags.add("code")
            if flags:
                styles[name] = frozenset(flags)
        return styles

    # --- Преобразование текста ---------------------------------------------
    def _convert_body(self, text_elem: ET.Element) -> Body:
        """Преобразовать ``<office:text>`` в структуру Body."""
        body = Body()
        root_section = Section()
        stack: List[Tuple[int, Section]] = [(0, root_section)]

        for child in text_elem:
            self._handle_element(child, stack)

        body.sections = root_section.sections
        if root_section.content:
            body.sections.insert(0, Section(content=root_section.content))
        if not body.sections:
            body.sections = [Section()]
        return body

    def _handle_element(self, element: ET.Element, stack: List[Tuple[int, Section]]) -> None:
        """Обработать элемент верхнего уровня ``office:text``."""
        local = self._local(element.tag)
        if local == "h":
            self._handle_heading(element, stack)
        elif local == "p":
            self._handle_paragraph(element, stack)
        elif local == "table":
            table = self._convert_table(element)
            if table is not None:
                stack[-1][1].content.append(table)
        elif local == "list":
            for item in element.iter():
                if self._local(item.tag) == "p":
                    self._handle_paragraph(item, stack)
        elif local == "section":
            for child in element:
                self._handle_element(child, stack)

    def _handle_heading(self, element: ET.Element, stack: List[Tuple[int, Section]]) -> None:
        """Заголовок ``text:h`` -> новая секция (вложенность по уровню)."""
        self._in_header = False
        level = self._outline_level(element)
        nodes = self._inline_nodes(element, frozenset())
        if not nodes:
            return
        while len(stack) > 1 and stack[-1][0] >= level:
            stack.pop()
        section = Section(title=Title(items=[Paragraph(content=nodes)]))
        stack[-1][1].sections.append(section)
        stack.append((level, section))

    @staticmethod
    def _outline_level(element: ET.Element) -> int:
        """Уровень заголовка (1..10)."""
        try:
            level = int(element.get(ATTR_OUTLINE) or "1")
        except ValueError:
            level = 1
        return max(1, min(level, 10))

    def _handle_paragraph(self, element: ET.Element, stack: List[Tuple[int, Section]]) -> None:
        """Абзац ``text:p`` -> параграф, подзаголовок или картинка."""
        style = element.get(ATTR_STYLE_NAME) or ""
        nodes = self._inline_nodes(element, frozenset())
        text = self._nodes_text(nodes)

        if style == HEADER_TITLE_STYLE and self._in_header:
            if text:
                self._title_override = text
            return
        if style == HEADER_AUTHOR_STYLE and self._in_header:
            if text:
                self._creators_override = [
                    part.strip() for part in text.split(",") if part.strip()
                ]
            return
        if style == HEADER_ANNOTATION_STYLE and self._in_header:
            if text:
                self._annotation_override.append(text)
            return

        images = self._block_images(element)
        if images and not text:
            # Абзац состоит только из картинки.
            if self._in_header:
                if self._cover_href is None:
                    self._cover_href = images[0].href
            else:
                stack[-1][1].content.extend(images)
            return

        self._in_header = False
        if not nodes:
            return

        if style in SUBTITLE_STYLES:
            stack[-1][1].content.append(Subtitle(content=nodes))
        else:
            stack[-1][1].content.append(Paragraph(content=nodes))

    def _inline_nodes(
        self, element: ET.Element, flags: FrozenSet[str]
    ) -> List[StyleNode]:
        """Собрать узлы разметки (текст, span, ссылки, картинки)."""
        nodes: List[StyleNode] = []
        if element.text and element.text.strip():
            nodes.append(StyleNode(tag=TEXT_NODE, text=element.text))

        for child in element:
            local = self._local(child.tag)
            if local == "span":
                style = child.get(ATTR_STYLE_NAME) or ""
                child_flags = flags | self._text_styles.get(style, frozenset())
                inner = self._inline_nodes(child, child_flags)
                nodes.extend(self._wrap_flags(inner, child_flags - flags))
            elif local == "a":
                inner = self._inline_nodes(child, flags)
                nodes.append(
                    StyleNode(tag="a", children=inner, href=child.get(ATTR_HREF))
                )
            elif local == "frame":
                image = self._frame_node(child)
                if image is not None:
                    nodes.append(image)
            elif local in ("line-break", "tab", "s"):
                nodes.append(StyleNode(tag=TEXT_NODE, text=" "))
            else:
                nodes.extend(self._inline_nodes(child, flags))

            if child.tail and child.tail.strip():
                nodes.append(StyleNode(tag=TEXT_NODE, text=child.tail))
        return nodes

    @staticmethod
    def _wrap_flags(nodes: List[StyleNode], flags: FrozenSet[str]) -> List[StyleNode]:
        """Обернуть узлы в теги разметки FB2 по флагам."""
        for flag in sorted(flags):
            tag = FLAG_TO_TAG.get(flag)
            if tag:
                nodes = [StyleNode(tag=tag, children=nodes)]
        return nodes

    @staticmethod
    def _nodes_text(nodes: List[StyleNode]) -> str:
        """Простой текст из узлов разметки."""
        parts: List[str] = []
        for node in nodes:
            if node.tag == TEXT_NODE:
                parts.append(node.text or "")
            else:
                parts.append(OdtToFb2Converter._nodes_text(node.children))
        return "".join(parts).strip()

    # --- Изображения -------------------------------------------------------
    def _image_href(self, frame: ET.Element) -> Optional[str]:
        """Ссылка на изображение внутри ``draw:frame``."""
        for element in frame.iter():
            if self._local(element.tag) == "image":
                href = element.get(ATTR_HREF)
                if href:
                    return href
        return None

    def _register_binary(self, href: str) -> Optional[str]:
        """Прочитать изображение из архива и зарегистрировать ``<binary>``."""
        name = href.lstrip("/")
        if name in self._binary_ids:
            return self._binary_ids[name]
        data = self._read_zip(name)
        if data is None:
            return None
        media_type, _extension = detect_image_type(data)
        binary_id = Path(name).name or f"image{extension_for(media_type)}"
        self._binary_ids[name] = binary_id
        self._binaries.append(
            Binary(
                id=binary_id,
                content_type=media_type,
                data=base64.b64encode(data).decode("ascii"),
            )
        )
        return binary_id

    def _frame_node(self, frame: ET.Element) -> Optional[StyleNode]:
        """``draw:frame`` внутри абзаца -> inline ``<image>``."""
        href = self._image_href(frame)
        if href is None:
            return None
        binary_id = self._register_binary(href)
        if binary_id is None:
            return None
        return StyleNode(tag="image", image_href=f"#{binary_id}")

    def _block_images(self, element: ET.Element) -> List[Image]:
        """Блочные картинки абзаца (``draw:frame`` верхнего уровня)."""
        images: List[Image] = []
        for child in element:
            if self._local(child.tag) != "frame":
                continue
            href = self._image_href(child)
            if href is None:
                continue
            binary_id = self._register_binary(href)
            if binary_id:
                images.append(Image(href=f"#{binary_id}"))
        return images

    # --- Таблицы -----------------------------------------------------------
    def _convert_table(self, table: ET.Element) -> Optional[Table]:
        """``table:table`` -> структура Table."""
        rows: List[TableRow] = []
        for row_elem in table:
            if self._local(row_elem.tag) != "table-row":
                continue
            cells: List[TableCell] = []
            for cell_elem in row_elem:
                if self._local(cell_elem.tag) != "table-cell":
                    continue
                nodes: List[StyleNode] = []
                for child in cell_elem:
                    if self._local(child.tag) == "p":
                        nodes.extend(self._inline_nodes(child, frozenset()))
                cells.append(TableCell(tag="td", children=nodes))
            rows.append(TableRow(cells=cells))
        return Table(rows=rows) if rows else None

    # --- Сборка FictionBook ------------------------------------------------
    def _creators(self, meta: Dict[str, object]) -> List[str]:
        """Авторы: из ``meta.xml``, иначе из шапки документа."""
        creators = meta.get("creators")
        if isinstance(creators, list) and creators:
            return [str(item) for item in creators]
        return list(self._creators_override)

    @staticmethod
    def _split_author(name: str) -> Author:
        """Разбить строку автора на first/middle/last."""
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

    def _genres(self, meta: Dict[str, object]) -> List[str]:
        """Жанры: ``dc:subject`` (коды без пробелов) или ``default_genre``."""
        subjects = meta.get("subjects")
        codes: List[str] = []
        if isinstance(subjects, list):
            codes = [
                str(item).strip()
                for item in subjects
                if str(item).strip() and " " not in str(item).strip()
            ]
        return codes or [self.default_genre]

    @staticmethod
    def _annotation(meta: Dict[str, object]) -> Optional[Annotation]:
        """Аннотация из ``dc:description``."""
        text = str(meta.get("description") or "")
        if not text:
            return None
        return Annotation(
            items=[Paragraph(content=[StyleNode(tag=TEXT_NODE, text=text)])]
        )

    def _annotation_items(self, meta: Dict[str, object]) -> List[AnnotationBlock]:
        """Абзацы аннотации: ``dc:description`` либо текст из шапки."""
        text = str(meta.get("description") or "")
        paragraphs = [text] if text else list(self._annotation_override)
        return [
            Paragraph(content=[StyleNode(tag=TEXT_NODE, text=paragraph)])
            for paragraph in paragraphs
            if paragraph
        ]

    def _assemble(self, meta: Dict[str, object], body: Body) -> FictionBook:
        """Собрать корневую структуру FictionBook."""
        title = str(meta.get("title") or self._title_override or "Untitled")
        authors = [self._split_author(name) for name in self._creators(meta)]
        annotation_items = self._annotation_items(meta)
        coverpage = (
            CoverPage(images=[InlineImage(href=self._cover_href)])
            if self._cover_href
            else None
        )

        title_info = TitleInfo(
            genres=[Genre(value=genre) for genre in self._genres(meta)],
            authors=authors,
            book_title=TextField(value=title),
            annotation=Annotation(items=annotation_items) if annotation_items else None,
            coverpage=coverpage,
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


__all__ = ["OdtToFb2Converter"]


def main(argv: List[str] | None = None) -> int:
    if argv is None:
        argv = sys.argv
    if len(argv) < 2:
        print(
            "Использование: python odt_to_fb2.py <файл.odt> [выход.fb2]",
            file=sys.stderr,
        )
        return 2
    source = argv[1]
    output = argv[2] if len(argv) > 2 else str(Path(source).with_suffix(".fb2"))
    converter = OdtToFb2Converter()
    path = converter.write(source, output)
    print("FB2:", path)
    if converter.book is not None:
        print("Изображений:", len(converter.book.binaries))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
