"""Преобразование FictionBook (FB2) в документ Word (DOCX).

Модуль предоставляет класс :class:`Fb2ToDocxConverter`, который читает
FB2-файл (через :class:`~fb2_parser.Fb2Parser`) и собирает из него DOCX —
архив Office Open XML (ZIP) без внешних зависимостей:

    * метаданные <description> -> заголовок, авторы, аннотация документа;
    * каждая секция верхнего уровня -> заголовок стиля ``HeadingN``;
    * <p>, <strong>, <emphasis>, <a>, <image>, <sub>/<sup>/<code>,
      <strikethrough>, <style>;
    * <cite>/<epigraph> -> стиль ``Quote``, стихи -> отступ строк;
    * <table> -> настоящая таблица Word;
    * <binary> -> изображения (media/*) со встроенными ссылками.

Промежуточное представление — :class:`DocxBook` (метаданные + XML
документа + изображения). Его можно сериализовать в байты
(:meth:`Fb2ToDocxConverter.to_bytes`) или записать в файл
(:meth:`Fb2ToDocxConverter.write`).

Пример::

    >>> from fb2_to_docx import Fb2ToDocxConverter
    >>> converter = Fb2ToDocxConverter()
    >>> path = converter.write("book.fb2", "book.docx")
    WindowsPath('book.docx')
    >>> book = converter.convert("book.fb2")   # структура DocxBook
    >>> data = converter.to_bytes(book)        # bytes ZIP-архива DOCX
"""

from __future__ import annotations

import io
import struct
import sys
import uuid
import zipfile
from dataclasses import dataclass, field
from html import escape as xml_escape
from pathlib import Path
from typing import Dict, List, Optional, Tuple, Union

from .fb2_errors import Fb2ConversionError
from .fb2_parser import TEXT_NODE, Fb2Parser
from .fb2_structures import (
    Annotation,
    Body,
    Cite,
    EmptyLine,
    Epigraph,
    Image,
    Paragraph,
    Poem,
    Section,
    Stanza,
    StyleNode,
    Subtitle,
    Table,
    Title,
)

# --- Пространства имён OOXML ------------------------------------------------
NS_W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
NS_R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
NS_WP = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
NS_A = "http://schemas.openxmlformats.org/drawingml/2006/main"
NS_PIC = "http://schemas.openxmlformats.org/drawingml/2006/picture"
NS_CT = "http://schemas.openxmlformats.org/package/2006/content-types"
NS_REL = "http://schemas.openxmlformats.org/package/2006/relationships"

#: Типы связей (relationships).
REL_STYLES = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles"
REL_IMAGE = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"
REL_HYPERLINK = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink"
REL_CORE = "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties"
REL_APP = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties"
REL_OFFICE = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"

#: Английские единицы измерения Office (EMU).
EMU_PER_INCH = 914400
EMU_PER_PIXEL = 9525  # 96 DPI

#: Размер изображения по умолчанию, если не удалось определить (пиксели).
DEFAULT_IMAGE_WIDTH = 400
DEFAULT_IMAGE_HEIGHT = 300

#: Расширение файла в media/ по MIME-типу.
_EXT_BY_MEDIA_TYPE = {
    "image/jpeg": "jpeg",
    "image/jpg": "jpeg",
    "image/png": "png",
    "image/gif": "gif",
    "image/bmp": "bmp",
    "image/tiff": "tiff",
    "image/webp": "webp",
}

#: MIME-тип по расширению (для [Content_Types].xml).
_MEDIA_TYPE_BY_EXT = {
    "jpeg": "image/jpeg",
    "png": "image/png",
    "gif": "image/gif",
    "bmp": "image/bmp",
    "tiff": "image/tiff",
    "webp": "image/webp",
}


@dataclass
class DocxImage:
    """Изображение, встраиваемое в документ Word."""

    rel_id: str
    filename: str
    extension: str
    media_type: str
    data: bytes
    width_emu: int
    height_emu: int


@dataclass
class DocxBook:
    """Промежуточное представление документа DOCX."""

    title: str = "Untitled"
    creators: List[str] = field(default_factory=list)
    language: str = "ru"
    identifier: str = ""
    date: str = ""
    description: str = ""
    document_xml: str = ""
    images: List[DocxImage] = field(default_factory=list)
    hyperlinks: List[Tuple[str, str]] = field(default_factory=list)


class Fb2ToDocxConverter:
    """Преобразование книги FB2 в документ Word (DOCX).

    :param parser: готовый :class:`~fb2_parser.Fb2Parser` (иначе создаётся новый).
    :param max_image_width_inches: максимальная ширина изображения в дюймах
        (более широкие масштабируются с сохранением пропорций).
    """

    def __init__(
        self,
        parser: Optional[Fb2Parser] = None,
        max_image_width_inches: float = 6.0,
    ) -> None:
        self.parser = parser if parser is not None else Fb2Parser()
        self.max_image_width_emu = int(max_image_width_inches * EMU_PER_INCH)
        self.source: Optional[Union[str, Path]] = None
        self._book: Optional[DocxBook] = None
        self._reset()

    def _reset(self) -> None:
        """Очистить состояние для нового преобразования."""
        self._images: List[DocxImage] = []
        self._image_map: Dict[str, DocxImage] = {}
        self._hyperlinks: List[Tuple[str, str]] = []
        self._rid_counter = 1  # rId1 занят styles.xml
        self._drawing_counter = 0

    # --- Публичный API -----------------------------------------------------
    @property
    def book(self) -> Optional[DocxBook]:
        """Последняя собранная структура :class:`DocxBook` (или None)."""
        return self._book

    def convert(self, source: Optional[Union[str, Path]] = None) -> DocxBook:
        """Прочитать FB2 и вернуть структуру :class:`DocxBook`.

        :param source: путь к FB2 (иначе берётся ``self.source``).
        """
        if source is not None:
            self.source = source
        self._reset()

        parser = self.parser
        description = parser.parse(self.source)
        bodies = parser.parse_bodies(self.source)
        binaries = parser.parse_binaries(self.source)

        title_info = description.title_info
        document_info = description.document_info

        title = self._book_title(title_info)
        creators = self._creators(title_info)
        description_text = self._annotation_text(title_info)

        self._collect_images(binaries)
        cover_image = self._cover_image(title_info)
        document_xml = self._render_document_body(
            title, creators, description_text, cover_image, bodies
        )

        self._book = DocxBook(
            title=title,
            creators=creators,
            language=self._language(title_info),
            identifier=self._identifier(document_info),
            date=self._date(title_info, document_info),
            description=description_text,
            document_xml=document_xml,
            images=self._images,
            hyperlinks=self._hyperlinks,
        )
        return self._book

    def to_bytes(self, book: Optional[DocxBook] = None) -> bytes:
        """Сериализовать книгу (или результат :meth:`convert`) в DOCX (ZIP).

        :param book: готовая структура; если не задана, используется
            результат последнего вызова :meth:`convert`.
        """
        if book is None:
            book = self._book
        if book is None:
            raise Fb2ConversionError("Нет книги для сериализации: вызовите convert()")

        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("[Content_Types].xml", self._content_types(book))
            archive.writestr("_rels/.rels", self._root_rels())
            archive.writestr("word/document.xml", self._document_xml(book))
            archive.writestr("word/_rels/document.xml.rels", self._document_rels(book))
            archive.writestr("word/styles.xml", self._styles_xml())
            archive.writestr("docProps/core.xml", self._core_xml(book))
            archive.writestr("docProps/app.xml", self._app_xml())
            for image in book.images:
                archive.writestr(f"word/media/{image.filename}", image.data)
        return buf.getvalue()

    def write(
        self,
        source: Optional[Union[str, Path]] = None,
        output: Optional[Union[str, Path]] = None,
    ) -> Path:
        """Преобразовать FB2 в файл DOCX и вернуть путь к результату.

        :param source: путь к FB2 (иначе ``self.source``).
        :param output: путь к выходному ``.docx``; по умолчанию — рядом с
            исходным ``.fb2``.
        """
        book = self.convert(source)
        data = self.to_bytes(book)

        if output is None:
            src = source if source is not None else self.source
            output = Path(src).with_suffix(".docx") if isinstance(src, (str, Path)) else Path("book.docx")
        output = Path(output)
        output.write_bytes(data)
        return output

    # --- Метаданные FB2 -> DOCX -------------------------------------------
    @staticmethod
    def _markup_text(nodes: List[StyleNode]) -> str:
        """Собрать простой текст из списка узлов разметки."""
        parts: List[str] = []
        for node in nodes:
            if node.tag == TEXT_NODE:
                parts.append(node.text or "")
            else:
                parts.append(Fb2ToDocxConverter._markup_text(node.children))
        return "".join(parts)

    @staticmethod
    def _book_title(title_info) -> str:
        """Название книги из <book-title>."""
        if title_info is not None and title_info.book_title is not None:
            return title_info.book_title.value or "Untitled"
        return "Untitled"

    @staticmethod
    def _author_text(author) -> str:
        """Человекочитаемое имя автора."""
        parts = [author.first_name, author.middle_name, author.last_name]
        return " ".join(p for p in parts if p) or (author.nickname or "")

    def _creators(self, title_info) -> List[str]:
        """Список авторов из <title-info>."""
        if title_info is None:
            return []
        result: List[str] = []
        for author in title_info.authors:
            text = self._author_text(author)
            if text:
                result.append(text)
        return result

    @staticmethod
    def _language(title_info) -> str:
        """Язык книги из <lang>."""
        if title_info is not None and title_info.lang:
            return title_info.lang
        return "ru"

    @staticmethod
    def _identifier(document_info) -> str:
        """Уникальный идентификатор книги."""
        if document_info is not None and document_info.id:
            return document_info.id
        return uuid.uuid4().hex

    @staticmethod
    def _date(title_info, document_info) -> str:
        """Дата публикации (из title-info или document-info)."""
        for info in (title_info, document_info):
            if info is not None and info.date is not None and info.date.value:
                return info.date.value
        return ""

    @staticmethod
    def _annotation_text(title_info) -> str:
        """Аннотация книги как простой текст."""
        if title_info is None or title_info.annotation is None:
            return ""
        parts: List[str] = []
        for item in title_info.annotation.items:
            if isinstance(item, (Paragraph, Subtitle)):
                parts.append(Fb2ToDocxConverter._markup_text(item.content))
        return " ".join(p for p in parts if p)

    def _new_rid(self) -> str:
        """Выделить следующий идентификатор связи."""
        self._rid_counter += 1
        return f"rId{self._rid_counter}"

    def _next_drawing_id(self) -> int:
        """Выделить идентификатор для <wp:docPr>."""
        self._drawing_counter += 1
        return self._drawing_counter

    # --- Изображения ------------------------------------------------------
    def _collect_images(self, binaries) -> None:
        """Собрать <binary> в DocxImage с вычисленными размерами."""
        for binary in binaries:
            try:
                data = Fb2Parser.binary_data(binary)
            except (ValueError, TypeError):
                continue
            media_type = (binary.content_type or "").lower()
            extension = _EXT_BY_MEDIA_TYPE.get(media_type, "bin")
            width_px, height_px = self._image_size(data, media_type)
            width_emu, height_emu = self._scale_dimensions(width_px, height_px)

            rel_id = self._new_rid()
            image = DocxImage(
                rel_id=rel_id,
                filename=f"image{len(self._images) + 1}.{extension}",
                extension=extension,
                media_type=media_type,
                data=data,
                width_emu=width_emu,
                height_emu=height_emu,
            )
            self._images.append(image)
            for key in (binary.id, f"#{binary.id}"):
                if key:
                    self._image_map[key] = image

    def _image_by_href(self, href: Optional[str]) -> Optional[DocxImage]:
        """Найти изображение по ссылке FB2 (#id)."""
        if not href:
            return None
        return self._image_map.get(href) or self._image_map.get(href.lstrip("#"))

    @classmethod
    def _image_size(cls, data: bytes, media_type: str) -> Tuple[int, int]:
        """Определить размер изображения в пикселях (PNG/JPEG/GIF)."""
        try:
            if media_type == "image/png" or data[:8] == b"\x89PNG\r\n\x1a\n":
                return cls._png_size(data)
            if media_type in ("image/jpeg", "image/jpg") or data[:2] == b"\xff\xd8":
                return cls._jpeg_size(data)
            if media_type == "image/gif" or data[:3] == b"GIF":
                return cls._gif_size(data)
        except (struct.error, IndexError, ValueError):
            pass
        return DEFAULT_IMAGE_WIDTH, DEFAULT_IMAGE_HEIGHT

    @staticmethod
    def _png_size(data: bytes) -> Tuple[int, int]:
        """Ширина/высота PNG из чанка IHDR."""
        if len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n":
            return DEFAULT_IMAGE_WIDTH, DEFAULT_IMAGE_HEIGHT
        width, height = struct.unpack(">II", data[16:24])
        return width, height

    @staticmethod
    def _jpeg_size(data: bytes) -> Tuple[int, int]:
        """Ширина/высота JPEG из маркера SOFn."""
        index = 2
        length = len(data)
        while index + 9 < length:
            if data[index] != 0xFF:
                index += 1
                continue
            marker = data[index + 1]
            if marker in (0xD8, 0xD9) or 0xD0 <= marker <= 0xD7:
                index += 2
                continue
            segment_length = struct.unpack(">H", data[index + 2:index + 4])[0]
            if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
                height, width = struct.unpack(">HH", data[index + 5:index + 9])
                return width, height
            index += 2 + segment_length
        return DEFAULT_IMAGE_WIDTH, DEFAULT_IMAGE_HEIGHT

    @staticmethod
    def _gif_size(data: bytes) -> Tuple[int, int]:
        """Ширина/высота GIF из логического дескриптора экрана."""
        if len(data) < 10 or data[:3] != b"GIF":
            return DEFAULT_IMAGE_WIDTH, DEFAULT_IMAGE_HEIGHT
        width, height = struct.unpack("<HH", data[6:10])
        return width, height

    def _scale_dimensions(self, width_px: int, height_px: int) -> Tuple[int, int]:
        """Перевести пиксели в EMU и ограничить максимальной шириной."""
        if width_px <= 0 or height_px <= 0:
            width_px, height_px = DEFAULT_IMAGE_WIDTH, DEFAULT_IMAGE_HEIGHT
        width_emu = width_px * EMU_PER_PIXEL
        height_emu = height_px * EMU_PER_PIXEL
        if width_emu > self.max_image_width_emu:
            ratio = self.max_image_width_emu / width_emu
            width_emu = self.max_image_width_emu
            height_emu = int(height_emu * ratio)
        return width_emu, height_emu

    # --- Построение документа ---------------------------------------------
    def _cover_image(self, title_info) -> Optional[DocxImage]:
        """Найти изображение обложки из <coverpage>."""
        if title_info is None or title_info.coverpage is None:
            return None
        for image in title_info.coverpage.images:
            docx_image = self._image_by_href(image.href)
            if docx_image is not None:
                return docx_image
        return None

    def _render_document_body(
        self,
        title: str,
        creators: List[str],
        description: str,
        cover_image: Optional[DocxImage],
        bodies: List[Body],
    ) -> str:
        """Собрать внутреннее содержимое <w:body>."""
        parts: List[str] = []
        if title:
            parts.append(self._paragraph(self._run(title, {}), style="Title"))
        for creator in creators:
            parts.append(self._paragraph(self._run(creator, {"sz": 28}), jc="center"))
        if description:
            parts.append(self._paragraph(self._run(description, {"i": True}), style="Quote"))
        if cover_image is not None:
            parts.append(
                self._paragraph(self._drawing(cover_image, self._next_drawing_id()), jc="center")
            )
        if title or creators or description or cover_image is not None:
            parts.append("<w:p/>")
        for body in bodies:
            parts.append(self._render_body(body))
        return "".join(p for p in parts if p)

    def _render_body(self, body: Body) -> str:
        """Отрисовать <body>."""
        parts: List[str] = []
        if body.title is not None:
            parts.append(self._render_title(body.title, 1))
        for epigraph in body.epigraphs:
            parts.append(self._render_epigraph(epigraph))
        if body.image is not None:
            parts.append(self._render_block_image(body.image))
        for section in body.sections:
            parts.append(self._render_section(section, 1))
        return "".join(p for p in parts if p)

    def _render_section(self, section: Section, level: int) -> str:
        """Отрисовать секцию (рекурсивно)."""
        parts: List[str] = []
        if section.title is not None:
            parts.append(self._render_title(section.title, level))
        for epigraph in section.epigraphs:
            parts.append(self._render_epigraph(epigraph))
        if section.image is not None:
            parts.append(self._render_block_image(section.image))
        if section.annotation is not None:
            parts.append(self._render_annotation(section.annotation))
        for block in section.content:
            parts.append(self._render_block(block))
        for child in section.sections:
            parts.append(self._render_section(child, level + 1))
        return "".join(p for p in parts if p)

    def _render_title(self, title: Optional[Title], level: int) -> str:
        """Отрисовать заголовок стилем HeadingN."""
        if title is None:
            return ""
        style = f"Heading{min(max(level, 1), 6)}"
        runs = ""
        for item in title.items:
            if isinstance(item, Paragraph):
                text = self._render_markup(item.content, {})
                if text:
                    if runs:
                        runs += self._run(" ", {})
                    runs += text
        return self._paragraph(runs, style=style)

    def _render_epigraph(self, epigraph: Epigraph) -> str:
        """Отрисовать эпиграф стилем Quote."""
        parts: List[str] = []
        for item in epigraph.items:
            if isinstance(item, Paragraph):
                parts.append(self._paragraph(self._render_markup(item.content, {}), style="Quote"))
            else:
                parts.append(self._render_block(item))
        for author in epigraph.text_author:
            parts.append(self._paragraph(self._render_markup(author.content, {}), style="Quote"))
        return "".join(p for p in parts if p)

    def _render_annotation(self, annotation: Annotation) -> str:
        """Отрисовать аннотацию."""
        parts: List[str] = []
        for item in annotation.items:
            parts.append(self._render_block(item))
        return "".join(p for p in parts if p)

    def _render_block(self, block) -> str:
        """Отрисовать блочный элемент FB2."""
        if isinstance(block, Paragraph):
            return self._paragraph(self._render_markup(block.content, {}))
        if isinstance(block, Subtitle):
            return self._paragraph(self._render_markup(block.content, {}), style="Subtitle")
        if isinstance(block, EmptyLine):
            return "<w:p/>"
        if isinstance(block, Cite):
            return self._render_cite(block)
        if isinstance(block, Poem):
            return self._render_poem(block)
        if isinstance(block, Table):
            return self._render_table(block)
        if isinstance(block, Image):
            return self._render_block_image(block)
        return ""

    @staticmethod
    def _paragraph(runs: str, style: Optional[str] = None, jc: Optional[str] = None) -> str:
        """Собрать параграф <w:p>."""
        props: List[str] = []
        if style:
            props.append(f'<w:pStyle w:val="{style}"/>')
        if jc:
            props.append(f'<w:jc w:val="{jc}"/>')
        ppr = f"<w:pPr>{''.join(props)}</w:pPr>" if props else ""
        return f"<w:p>{ppr}{runs}</w:p>"

    def _render_cite(self, cite: Cite) -> str:
        """Отрисовать цитату стилем Quote."""
        parts: List[str] = []
        for item in cite.items:
            if isinstance(item, Paragraph):
                parts.append(self._paragraph(self._render_markup(item.content, {}), style="Quote"))
            else:
                parts.append(self._render_block(item))
        for author in cite.text_author:
            parts.append(self._paragraph(self._render_markup(author.content, {}), style="Quote"))
        return "".join(p for p in parts if p)

    def _render_poem(self, poem: Poem) -> str:
        """Отрисовать стихотворение."""
        parts: List[str] = []
        if poem.title is not None:
            parts.append(self._render_title(poem.title, 3))
        for epigraph in poem.epigraphs:
            parts.append(self._render_epigraph(epigraph))
        for item in poem.items:
            if isinstance(item, Stanza):
                parts.append(self._render_stanza(item))
            elif isinstance(item, Subtitle):
                parts.append(self._paragraph(self._render_markup(item.content, {}), style="Subtitle"))
        for author in poem.text_author:
            parts.append(self._paragraph(self._render_markup(author.content, {}), style="Quote"))
        return "".join(p for p in parts if p)

    def _render_stanza(self, stanza: Stanza) -> str:
        """Отрисовать строфу (строки стихотворения)."""
        parts: List[str] = []
        if stanza.subtitle is not None:
            parts.append(self._paragraph(self._render_markup(stanza.subtitle.content, {}), style="Subtitle"))
        for verse in stanza.verses:
            parts.append(self._paragraph(self._render_markup(verse.content, {}), style="PoemLine"))
        return "".join(p for p in parts if p)

    def _render_table(self, table: Table) -> str:
        """Отрисовать таблицу как <w:tbl>."""
        rows: List[str] = []
        for row in table.rows:
            cells: List[str] = []
            for cell in row.cells:
                props = {"b": True} if cell.is_header else {}
                runs = self._render_markup(cell.children, props)
                cells.append(
                    '<w:tc><w:tcPr><w:tcW w:w="0" w:type="auto"/></w:tcPr>'
                    + self._paragraph(runs)
                    + "</w:tc>"
                )
            rows.append("<w:tr>" + "".join(cells) + "</w:tr>")
        borders = (
            "<w:tblBorders>"
            '<w:top w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
            '<w:left w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
            '<w:bottom w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
            '<w:right w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
            '<w:insideH w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
            '<w:insideV w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
            "</w:tblBorders>"
        )
        return (
            f'<w:tbl><w:tblPr><w:tblW w:w="0" w:type="auto"/>{borders}</w:tblPr>'
            + "".join(rows)
            + "</w:tbl><w:p/>"
        )

    def _render_block_image(self, image: Image) -> str:
        """Отрисовать блочное изображение по центру."""
        docx_image = self._image_by_href(image.href)
        if docx_image is None:
            return ""
        drawing_id = self._next_drawing_id()
        return self._paragraph(self._drawing(docx_image, drawing_id), jc="center")

    # --- Inline-разметка --------------------------------------------------
    def _render_markup(self, nodes: List[StyleNode], props: Dict) -> str:
        """Отрисовать mixed-разметку в последовательность <w:r>."""
        parts: List[str] = []
        for node in nodes:
            tag = node.tag
            if tag == TEXT_NODE:
                parts.append(self._run(node.text or "", props))
            elif tag == "strong":
                parts.append(self._render_markup(node.children, {**props, "b": True}))
            elif tag == "emphasis":
                parts.append(self._render_markup(node.children, {**props, "i": True}))
            elif tag == "strikethrough":
                parts.append(self._render_markup(node.children, {**props, "strike": True}))
            elif tag == "sub":
                parts.append(self._render_markup(node.children, {**props, "vert": "subscript"}))
            elif tag == "sup":
                parts.append(self._render_markup(node.children, {**props, "vert": "superscript"}))
            elif tag == "code":
                parts.append(self._render_markup(node.children, {**props, "code": True}))
            elif tag == "style":
                parts.append(self._render_markup(node.children, props))
            elif tag == "a":
                parts.append(self._render_hyperlink(node, props))
            elif tag == "image":
                parts.append(self._image_run(node))
        return "".join(parts)

    def _run(self, text: str, props: Dict) -> str:
        """Один текстовый run <w:r>."""
        if not text:
            return ""
        return (
            f"<w:r>{self._run_props(props)}"
            f'<w:t xml:space="preserve">{xml_escape(text)}</w:t></w:r>'
        )

    @staticmethod
    def _run_props(props: Dict) -> str:
        """Свойства run <w:rPr>."""
        parts: List[str] = []
        if props.get("link"):
            parts.append('<w:rStyle w:val="Hyperlink"/>')
        elif props.get("code"):
            parts.append('<w:rStyle w:val="Code"/>')
        if props.get("b"):
            parts.append("<w:b/>")
        if props.get("i"):
            parts.append("<w:i/>")
        if props.get("strike"):
            parts.append("<w:strike/>")
        if props.get("vert"):
            parts.append(f'<w:vertAlign w:val="{props["vert"]}"/>')
        if props.get("sz"):
            parts.append(f'<w:sz w:val="{props["sz"]}"/>')
        if not parts:
            return ""
        return "<w:rPr>" + "".join(parts) + "</w:rPr>"

    def _render_hyperlink(self, node: StyleNode, props: Dict) -> str:
        """Отрисовать <a> как <w:hyperlink> (внешняя связь)."""
        inner = self._render_markup(node.children, {**props, "link": True})
        href = node.href or ""
        if not href:
            return inner
        rel_id = self._new_rid()
        self._hyperlinks.append((rel_id, href))
        return f'<w:hyperlink r:id="{rel_id}">{inner}</w:hyperlink>'

    def _image_run(self, node: StyleNode) -> str:
        """Отрисовать inline-изображение."""
        docx_image = self._image_by_href(node.image_href)
        if docx_image is None:
            return ""
        drawing_id = self._next_drawing_id()
        return self._drawing(docx_image, drawing_id)

    @staticmethod
    def _drawing(image: DocxImage, drawing_id: int) -> str:
        """Собрать XML встроенного изображения <w:drawing>."""
        cx = image.width_emu
        cy = image.height_emu
        return (
            "<w:r><w:drawing>"
            '<wp:inline distT="0" distB="0" distL="0" distR="0">'
            f'<wp:extent cx="{cx}" cy="{cy}"/>'
            '<wp:effectExtent l="0" t="0" r="0" b="0"/>'
            f'<wp:docPr id="{drawing_id}" name="Picture {drawing_id}"/>'
            '<wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>'
            "<a:graphic>"
            '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">'
            "<pic:pic>"
            f'<pic:nvPicPr><pic:cNvPr id="{drawing_id}" name="{image.filename}"/><pic:cNvPicPr/></pic:nvPicPr>'
            f'<pic:blipFill><a:blip r:embed="{image.rel_id}"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>'
            f'<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="{cx}" cy="{cy}"/></a:xfrm>'
            '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>'
            "</pic:pic></a:graphicData></a:graphic></wp:inline>"
            "</w:drawing></w:r>"
        )

    # --- Метафайлы DOCX ---------------------------------------------------
    @staticmethod
    def _content_types(book: DocxBook) -> str:
        """Собрать [Content_Types].xml."""
        parts: List[str] = ['<?xml version="1.0" encoding="UTF-8" standalone="yes"?>']
        parts.append(f'<Types xmlns="{NS_CT}">')
        parts.append('<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>')
        parts.append('<Default Extension="xml" ContentType="application/xml"/>')
        for extension in sorted({image.extension for image in book.images}):
            media_type = _MEDIA_TYPE_BY_EXT.get(extension)
            if media_type:
                parts.append(f'<Default Extension="{extension}" ContentType="{media_type}"/>')
        parts.append(
            '<Override PartName="/word/document.xml" '
            'ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
        )
        parts.append(
            '<Override PartName="/word/styles.xml" '
            'ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>'
        )
        parts.append(
            '<Override PartName="/docProps/core.xml" '
            'ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>'
        )
        parts.append(
            '<Override PartName="/docProps/app.xml" '
            'ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>'
        )
        parts.append("</Types>")
        return "".join(parts)

    @staticmethod
    def _root_rels() -> str:
        """Собрать _rels/.rels."""
        return (
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            f'<Relationships xmlns="{NS_REL}">'
            f'<Relationship Id="rId1" Type="{REL_OFFICE}" Target="word/document.xml"/>'
            f'<Relationship Id="rId2" Type="{REL_CORE}" Target="docProps/core.xml"/>'
            f'<Relationship Id="rId3" Type="{REL_APP}" Target="docProps/app.xml"/>'
            "</Relationships>"
        )

    @staticmethod
    def _document_rels(book: DocxBook) -> str:
        """Собрать word/_rels/document.xml.rels."""
        parts: List[str] = ['<?xml version="1.0" encoding="UTF-8" standalone="yes"?>']
        parts.append(f'<Relationships xmlns="{NS_REL}">')
        parts.append(f'<Relationship Id="rId1" Type="{REL_STYLES}" Target="styles.xml"/>')
        for image in book.images:
            parts.append(
                f'<Relationship Id="{image.rel_id}" Type="{REL_IMAGE}" '
                f'Target="media/{image.filename}"/>'
            )
        for rel_id, url in book.hyperlinks:
            parts.append(
                f'<Relationship Id="{rel_id}" Type="{REL_HYPERLINK}" '
                f'Target="{xml_escape(url)}" TargetMode="External"/>'
            )
        parts.append("</Relationships>")
        return "".join(parts)

    @staticmethod
    def _document_xml(book: DocxBook) -> str:
        """Собрать word/document.xml."""
        return (
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            f'<w:document xmlns:w="{NS_W}" xmlns:r="{NS_R}" '
            f'xmlns:wp="{NS_WP}" xmlns:a="{NS_A}" xmlns:pic="{NS_PIC}">'
            "<w:body>"
            f"{book.document_xml}"
            '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>'
            '<w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1134" '
            'w:header="709" w:footer="709" w:gutter="0"/>'
            "</w:sectPr>"
            "</w:body></w:document>"
        )

    @staticmethod
    def _styles_xml() -> str:
        """Собрать word/styles.xml (базовые стили документа)."""
        headings = ""
        for level in range(1, 7):
            size = max(28 - (level - 1) * 2, 22)
            headings += (
                f'<w:style w:type="paragraph" w:styleId="Heading{level}">'
                f'<w:name w:val="heading {level}"/><w:basedOn w:val="Normal"/>'
                f'<w:next w:val="Normal"/>'
                f'<w:pPr><w:keepNext/><w:spacing w:before="240" w:after="120"/>'
                f'<w:outlineLvl w:val="{level - 1}"/></w:pPr>'
                f'<w:rPr><w:b/><w:sz w:val="{size}"/></w:rPr></w:style>'
            )
        return (
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            f'<w:styles xmlns:w="{NS_W}">'
            "<w:docDefaults><w:rPrDefault><w:rPr>"
            '<w:rFonts w:ascii="Times New Roman" w:hAnsi="Times New Roman" w:cs="Times New Roman"/>'
            '<w:sz w:val="24"/><w:szCs w:val="24"/>'
            "</w:rPr></w:rPrDefault>"
            '<w:pPrDefault><w:pPr><w:spacing w:after="120" w:line="240" w:lineRule="auto"/></w:pPr></w:pPrDefault>'
            "</w:docDefaults>"
            '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>'
            + headings
            + '<w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/>'
            '<w:basedOn w:val="Normal"/><w:pPr><w:jc w:val="center"/>'
            '<w:spacing w:before="240" w:after="240"/></w:pPr>'
            '<w:rPr><w:b/><w:sz w:val="36"/></w:rPr></w:style>'
            '<w:style w:type="paragraph" w:styleId="Subtitle"><w:name w:val="Subtitle"/>'
            '<w:basedOn w:val="Normal"/><w:pPr><w:jc w:val="center"/></w:pPr>'
            "<w:rPr><w:b/></w:rPr></w:style>"
            '<w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/>'
            '<w:basedOn w:val="Normal"/><w:pPr><w:ind w:left="720" w:right="720"/></w:pPr>'
            "<w:rPr><w:i/></w:rPr></w:style>"
            '<w:style w:type="paragraph" w:styleId="PoemLine"><w:name w:val="Poem Line"/>'
            '<w:basedOn w:val="Normal"/><w:pPr><w:ind w:left="720"/>'
            '<w:spacing w:after="0"/></w:pPr></w:style>'
            '<w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/>'
            '<w:rPr><w:color w:val="0563C1"/><w:u w:val="single"/></w:rPr></w:style>'
            '<w:style w:type="character" w:styleId="Code"><w:name w:val="Code"/>'
            '<w:rPr><w:rFonts w:ascii="Courier New" w:hAnsi="Courier New"/></w:rPr></w:style>'
            "</w:styles>"
        )

    @staticmethod
    def _core_xml(book: DocxBook) -> str:
        """Собрать docProps/core.xml (метаданные документа)."""
        creators = "".join(f"<dc:creator>{xml_escape(c)}</dc:creator>" for c in book.creators)
        last_modified = xml_escape(book.creators[0]) if book.creators else ""
        return (
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<cp:coreProperties '
            'xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
            'xmlns:dc="http://purl.org/dc/elements/1.1/" '
            'xmlns:dcterms="http://purl.org/dc/terms/" '
            'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'
            f"<dc:title>{xml_escape(book.title)}</dc:title>"
            f"{creators}"
            f"<cp:lastModifiedBy>{last_modified}</cp:lastModifiedBy>"
            f"<dc:language>{xml_escape(book.language)}</dc:language>"
            f"<dc:identifier>{xml_escape(book.identifier)}</dc:identifier>"
            f"<dc:description>{xml_escape(book.description)}</dc:description>"
            "</cp:coreProperties>"
        )

    @staticmethod
    def _app_xml() -> str:
        """Собрать docProps/app.xml."""
        return (
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<Properties '
            'xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" '
            'xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">'
            "<Application>pyFB2</Application>"
            "</Properties>"
        )


__all__ = ["Fb2ToDocxConverter", "DocxBook", "DocxImage"]


def main(argv: List[str] | None = None) -> int:
    if argv is None:
        argv = sys.argv
    if len(argv) < 2:
        print(
            "Использование: python fb2_to_docx.py <файл.fb2> [выход.docx]",
            file=sys.stderr,
        )
        return 2
    source = argv[1]
    output = argv[2] if len(argv) > 2 else str(Path(source).with_suffix(".docx"))
    converter = Fb2ToDocxConverter()
    path = converter.write(source, output)
    print("DOCX:", path)
    if converter.book is not None:
        print("Изображений:", len(converter.book.images))
        print("Гиперссылок:", len(converter.book.hyperlinks))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))









