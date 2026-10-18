# -*- coding: utf-8 -*-
"""Преобразование книги FB2 в OpenDocument Text (ODT).

Модуль собирает ODT-файл (ZIP-контейнер OpenDocument 1.2) из структур
:class:`~fb2_structures.FictionBook`: текст с заголовками, разметкой
(жирный/курсив/код/ссылки), цитатами, стихами, эпиграфами, таблицами и
изображениями, а также метаданные (``meta.xml``).

Состав контейнера::

    mimetype                     (без сжатия, как требует ODF)
    META-INF/manifest.xml
    content.xml                  (текст + автоматические стили)
    styles.xml                   (базовые стили)
    meta.xml                     (название, автор, язык, дата)
    Pictures/*                   (изображения)

Внешних зависимостей нет — только стандартная библиотека.

Пример:
    >>> from fb2_to_odt import Fb2ToOdtConverter
    >>> Fb2ToOdtConverter().write("book.fb2", "book.odt")
    WindowsPath('book.odt')

CLI:
    python fb2_to_odt.py book.fb2 [book.odt]
"""

from __future__ import annotations

import base64
import io
import sys
import zipfile
from dataclasses import dataclass, field
from html import escape as xml_escape
from pathlib import Path
from typing import Dict, FrozenSet, List, Optional, Tuple, Union

from .fb2_errors import Fb2ConversionError
from .fb2_images import detect_image_type, image_size, scale_to_width
from .fb2_parser import TEXT_NODE, Fb2Parser
from .fb2_structures import (
    Annotation,
    Binary,
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

#: MIME-тип ODT (первая запись архива, без сжатия).
ODT_MIMETYPE = "application/vnd.oasis.opendocument.text"

#: Служебные пространства имён ODF.
NS_OFFICE = "urn:oasis:names:tc:opendocument:xmlns:office:1.0"
NS_TEXT = "urn:oasis:names:tc:opendocument:xmlns:text:1.0"
NS_STYLE = "urn:oasis:names:tc:opendocument:xmlns:style:1.0"
NS_FO = "urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0"
NS_DRAW = "urn:oasis:names:tc:opendocument:xmlns:drawing:1.0"
NS_SVG = "urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0"
NS_TABLE = "urn:oasis:names:tc:opendocument:xmlns:table:1.0"
NS_XLINK = "http://www.w3.org/1999/xlink"
NS_META = "urn:oasis:names:tc:opendocument:xmlns:meta:1.0"
NS_DC = "http://purl.org/dc/elements/1.1/"
NS_MANIFEST = "urn:oasis:names:tc:opendocument:xmlns:manifest:1.0"

#: Расширение файла изображения по MIME-типу ``<binary>``.
CONTENT_TYPE_EXTENSIONS = {
    "image/jpeg": ".jpg",
    "image/jpg": ".jpg",
    "image/png": ".png",
    "image/gif": ".gif",
    "image/bmp": ".bmp",
    "image/tiff": ".tiff",
    "image/webp": ".webp",
    "image/svg+xml": ".svg",
}

#: Ширина страницы A4 за вычетом полей (в сантиметрах) — для масштаба картинок.
MAX_IMAGE_WIDTH_CM = 16.0

#: Перевод пикселей в сантиметры (96 dpi).
PX_TO_CM = 2.54 / 96.0

#: Inline-элементы разметки FB2, влияющие на оформление текста.
MARKUP_TAGS = frozenset(
    {"strong", "emphasis", "code", "strikethrough", "sub", "sup", "style"}
)

#: Базовые стили абзацев ODT: имя -> (свойства абзаца, свойства текста).
PARAGRAPH_STYLES: Tuple[Tuple[str, str, str], ...] = (
    ("Title", 'fo:text-align="center" fo:margin-bottom="0.5cm"',
     'fo:font-size="20pt" fo:font-weight="bold"'),
    ("Subtitle", 'fo:text-align="center" fo:margin-bottom="0.5cm"',
     'fo:font-size="14pt" fo:font-style="italic"'),
    ("Subtitle2", 'fo:margin-top="0.3cm" fo:margin-bottom="0.2cm"',
     'fo:font-weight="bold"'),
    ("Annotation",
     'fo:margin-left="1cm" fo:margin-right="1cm" fo:margin-bottom="0.3cm"',
     'fo:font-size="11pt"'),
    ("Epigraph", 'fo:margin-left="2cm" fo:margin-right="1cm"',
     'fo:font-style="italic"'),
    ("EpigraphAuthor", 'fo:margin-left="3cm" fo:text-align="end"', ""),
    ("Quotation", 'fo:margin-left="1cm" fo:margin-right="1cm"', ""),
    ("QuotationAuthor", 'fo:margin-left="2cm" fo:text-align="end"', ""),
    ("PoemLine", 'fo:margin-left="2cm"', ""),
    ("PoemAuthor", 'fo:margin-left="2cm" fo:text-align="end"', ""),
    ("Centered", 'fo:text-align="center"', ""),
    ("HeaderCell", 'fo:text-align="center"', 'fo:font-weight="bold"'),
)


@dataclass
class OdtImage:
    """Изображение, встраиваемое в ODT (``Pictures/...``)."""

    filename: str
    media_type: str
    data: bytes
    width_cm: float
    height_cm: float


@dataclass
class OdtBook:
    """Промежуточное представление документа ODT."""

    title: str = "Untitled"
    creators: List[str] = field(default_factory=list)
    language: str = "ru"
    identifier: str = ""
    date: str = ""
    description: str = ""
    content_xml: str = ""
    automatic_styles: str = ""
    images: List[OdtImage] = field(default_factory=list)


class Fb2ToOdtConverter:
    """Преобразование книги FB2 в OpenDocument Text (ODT).

    :param parser: готовый :class:`~fb2_parser.Fb2Parser` (иначе создаётся новый).
    :param max_image_width_cm: предельная ширина изображения в сантиметрах
        (более широкие масштабируются с сохранением пропорций).
    """

    def __init__(
        self,
        parser: Optional[Fb2Parser] = None,
        max_image_width_cm: float = MAX_IMAGE_WIDTH_CM,
    ) -> None:
        self.parser = parser if parser is not None else Fb2Parser()
        self.max_image_width_cm = max_image_width_cm
        self.source: Optional[Union[str, Path]] = None
        self._book: Optional[OdtBook] = None
        self._reset()

    def _reset(self) -> None:
        """Очистить состояние для нового преобразования."""
        self._images: List[OdtImage] = []
        self._image_map: Dict[str, OdtImage] = {}
        self._auto_styles: List[str] = []
        self._style_names: Dict[Tuple[str, ...], str] = {}
        self._frame_counter = 0

    # --- Публичный API -----------------------------------------------------
    @property
    def book(self) -> Optional[OdtBook]:
        """Последняя собранная структура :class:`OdtBook` (или None)."""
        return self._book

    def convert(self, source: Optional[Union[str, Path]] = None) -> OdtBook:
        """Прочитать FB2 и вернуть структуру :class:`OdtBook`.

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
        annotation = self._annotation_text(title_info)

        self._collect_images(binaries)
        cover = self._cover_image(title_info)

        content = self._render_body(bodies, title, creators, annotation, cover)
        self._book = OdtBook(
            title=title,
            creators=creators,
            language=self._language(title_info),
            identifier=self._identifier(document_info),
            date=self._date(title_info, document_info),
            description=annotation,
            content_xml=content,
            automatic_styles="\n".join(self._auto_styles),
            images=self._images,
        )
        return self._book

    def to_bytes(self, book: Optional[OdtBook] = None) -> bytes:
        """Сериализовать книгу (или результат :meth:`convert`) в ODT (ZIP).

        :param book: готовая структура; если не задана, используется результат
            последнего вызова :meth:`convert`.
        """
        if book is None:
            book = self._book
        if book is None:
            raise Fb2ConversionError("Нет книги для сериализации: вызовите convert()")

        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as archive:
            # ODF требует, чтобы mimetype лежал первым и без сжатия.
            info = zipfile.ZipInfo("mimetype")
            info.compress_type = zipfile.ZIP_STORED
            archive.writestr(info, ODT_MIMETYPE)
            archive.writestr("META-INF/manifest.xml", self._manifest_xml(book))
            archive.writestr("content.xml", self._content_xml(book))
            archive.writestr("styles.xml", self._styles_xml())
            archive.writestr("meta.xml", self._meta_xml(book))
            for image in book.images:
                archive.writestr(f"Pictures/{image.filename}", image.data)
        return buf.getvalue()

    def write(
        self,
        source: Optional[Union[str, Path]] = None,
        output: Optional[Union[str, Path]] = None,
    ) -> Path:
        """Преобразовать FB2 в файл ODT и вернуть путь к результату.

        :param source: путь к FB2 (иначе ``self.source``).
        :param output: путь к ``.odt``; по умолчанию — рядом с исходным ``.fb2``.
        """
        book = self.convert(source)
        data = self.to_bytes(book)

        if output is None:
            src = source if source is not None else self.source
            output = (
                Path(src).with_suffix(".odt")
                if isinstance(src, (str, Path))
                else Path("book.odt")
            )
        output = Path(output)
        output.write_bytes(data)
        return output

    # --- Метаданные FB2 ----------------------------------------------------
    @staticmethod
    def _book_title(title_info) -> str:
        """Название книги (или ``Untitled``)."""
        if title_info is not None and title_info.book_title:
            return title_info.book_title.value or "Untitled"
        return "Untitled"

    @staticmethod
    def _author_text(author) -> str:
        """Имя автора: «Имя Отчество Фамилия» либо никнейм."""
        parts = [author.first_name, author.middle_name, author.last_name]
        name = " ".join(part.strip() for part in parts if part and part.strip())
        return name or (author.nickname or "").strip()

    def _creators(self, title_info) -> List[str]:
        """Список авторов книги."""
        if title_info is None:
            return []
        authors = (self._author_text(author) for author in title_info.authors)
        return [name for name in authors if name]

    @staticmethod
    def _language(title_info) -> str:
        """Язык книги (по умолчанию ``ru``)."""
        if title_info is not None and title_info.lang:
            return title_info.lang
        return "ru"

    @staticmethod
    def _identifier(document_info) -> str:
        """Идентификатор документа (``<document-info><id>``)."""
        return document_info.id if document_info is not None else ""

    @staticmethod
    def _date(title_info, document_info) -> str:
        """Дата: сначала ``<document-info><date>``, затем ``<title-info><date>``."""
        fields = [
            document_info.date if document_info is not None else None,
            title_info.date if title_info is not None else None,
        ]
        for date_field in fields:
            if date_field is None:
                continue
            value = getattr(date_field, "date_value", None) or date_field.value
            if value:
                return value
        return ""

    @staticmethod
    def _markup_text(nodes: List[StyleNode]) -> str:
        """Собрать простой текст из списка узлов разметки."""
        parts: List[str] = []
        for node in nodes:
            if node.tag == TEXT_NODE:
                parts.append(node.text or "")
            else:
                parts.append(Fb2ToOdtConverter._markup_text(node.children))
        return "".join(parts)

    def _annotation_text(self, title_info) -> str:
        """Текст аннотации (абзацы через перевод строки)."""
        if title_info is None or title_info.annotation is None:
            return ""
        paragraphs: List[str] = []
        for item in title_info.annotation.items:
            text = self._markup_text(getattr(item, "content", []))
            if text:
                paragraphs.append(text)
        return "\n".join(paragraphs)

    # --- Изображения -------------------------------------------------------
    def _collect_images(self, binaries: List[Binary]) -> None:
        """Разобрать ``<binary>`` и подготовить изображения для ODT."""
        for binary in binaries:
            if binary.content_type and binary.content_type.startswith("image/svg"):
                continue  # SVG в ODT встраивается как объект — пропускаем
            try:
                data = base64.b64decode(binary.data or "")
            except (ValueError, TypeError):  # pragma: no cover - битые данные
                continue
            if not data:
                continue
            media_type, extension = detect_image_type(data)
            size = image_size(data, media_type)
            if size is None:
                width_cm = height_cm = self.max_image_width_cm
            else:
                width_cm, height_cm = scale_to_width(
                    size[0] * PX_TO_CM, size[1] * PX_TO_CM, self.max_image_width_cm
                )
            raw_id = binary.id or "image"
            # id в FB2 может уже содержать расширение (``cover.png``).
            base = Path(raw_id).stem if "." in raw_id else raw_id
            name = f"{base or 'image'}{extension}"
            image = OdtImage(
                filename=name,
                media_type=media_type,
                data=data,
                width_cm=round(float(width_cm), 2),
                height_cm=round(float(height_cm), 2),
            )
            self._images.append(image)
            self._image_map[(binary.id or "").lstrip("#")] = image

    def _image_by_href(self, href: Optional[str]) -> Optional[OdtImage]:
        """Найти изображение по ссылке ``#id``."""
        if not href:
            return None
        return self._image_map.get(href.lstrip("#"))

    def _cover_image(self, title_info) -> Optional[OdtImage]:
        """Изображение обложки (``<coverpage>``)."""
        if title_info is None or title_info.coverpage is None:
            return None
        for image in title_info.coverpage.images:
            found = self._image_by_href(image.href)
            if found is not None:
                return found
        return None

    # --- Рендеринг текста --------------------------------------------------
    def _render_body(
        self,
        bodies: List[Body],
        title: str,
        creators: List[str],
        annotation: str,
        cover: Optional[OdtImage],
    ) -> str:
        """Собрать содержимое ``<office:text>``."""
        parts: List[str] = []
        parts.append(self._paragraph(title, "Title"))
        if creators:
            parts.append(self._paragraph(", ".join(creators), "Subtitle"))
        if annotation:
            for line in annotation.splitlines():
                parts.append(self._paragraph(line, "Annotation"))
        if cover is not None:
            parts.append(self._image_frame(cover, centered=True))
        for body in bodies:
            parts.append(self._render_body_content(body))
        return "\n".join(part for part in parts if part)

    def _render_body_content(self, body: Body) -> str:
        """Отрендерить тело книги (заголовок, эпиграфы, секции)."""
        parts: List[str] = []
        if body.image is not None:
            image = self._image_by_href(body.image.href)
            if image is not None:
                parts.append(self._image_frame(image, centered=True))
        if body.title is not None:
            parts.append(self._render_title(body.title, 1))
        for epigraph in body.epigraphs:
            parts.append(self._render_epigraph(epigraph))
        for section in body.sections:
            parts.append(self._render_section(section, 1))
        return "\n".join(part for part in parts if part)

    def _render_section(self, section: Section, level: int) -> str:
        """Отрендерить секцию (рекурсивно)."""
        parts: List[str] = []
        if section.title is not None:
            parts.append(self._render_title(section.title, level))
        for epigraph in section.epigraphs:
            parts.append(self._render_epigraph(epigraph))
        if section.image is not None:
            image = self._image_by_href(section.image.href)
            if image is not None:
                parts.append(self._image_frame(image, centered=True))
        if section.annotation is not None:
            parts.append(self._render_annotation(section.annotation))
        for block in section.content:
            parts.append(self._render_block(block))
        for child in section.sections:
            parts.append(self._render_section(child, level + 1))
        return "\n".join(part for part in parts if part)

    def _render_title(self, title: Title, level: int) -> str:
        """Заголовок секции/книги (``text:h``)."""
        outline = max(1, min(level, 10))
        parts: List[str] = []
        for item in title.items:
            if isinstance(item, Paragraph):
                text = self._render_markup(item.content)
                if text:
                    parts.append(text)
        if not parts:
            return ""
        return f'<text:h text:outline-level="{outline}">{" ".join(parts)}</text:h>'

    def _render_epigraph(self, epigraph: Epigraph) -> str:
        """Эпиграф: абзацы с отступом + подпись."""
        parts: List[str] = []
        for item in epigraph.items:
            rendered = self._render_block(item, style="Epigraph")
            if rendered:
                parts.append(rendered)
        for author in epigraph.text_author:
            parts.append(
                self._paragraph(self._render_markup(author.content), "EpigraphAuthor")
            )
        return "\n".join(parts)

    def _render_annotation(self, annotation: Annotation) -> str:
        """Аннотация (абзацы с отступом)."""
        parts: List[str] = []
        for item in annotation.items:
            rendered = self._render_block(item, style="Annotation")
            if rendered:
                parts.append(rendered)
        return "\n".join(parts)

    def _paragraph(self, text: str, style: Optional[str] = None) -> str:
        """Абзац (``text:p``) с готовым содержимым."""
        if not text:
            return ""
        name = f' text:style-name="{style}"' if style else ""
        return f"<text:p{name}>{text}</text:p>"

    def _render_block(self, block, style: Optional[str] = None) -> str:
        """Отрендерить блочный элемент контента."""
        if isinstance(block, Paragraph):
            return self._paragraph(self._render_markup(block.content), style)
        if isinstance(block, Subtitle):
            return self._paragraph(
                self._render_markup(block.content), style or "Subtitle2"
            )
        if isinstance(block, EmptyLine):
            return self._paragraph("&#160;", style)
        if isinstance(block, Poem):
            return self._render_poem(block)
        if isinstance(block, Cite):
            return self._render_cite(block)
        if isinstance(block, Table):
            return self._render_table(block)
        if isinstance(block, Image):
            image = self._image_by_href(block.href)
            return self._image_frame(image, centered=True) if image else ""
        if isinstance(block, Epigraph):
            return self._render_epigraph(block)
        if isinstance(block, Title):
            return self._render_title(block, 2)
        if isinstance(block, Annotation):
            return self._render_annotation(block)
        return ""

    def _render_cite(self, cite: Cite) -> str:
        """Цитата: абзацы с отступом."""
        parts: List[str] = []
        for item in cite.items:
            rendered = self._render_block(item, style="Quotation")
            if rendered:
                parts.append(rendered)
        for author in cite.text_author:
            parts.append(
                self._paragraph(self._render_markup(author.content), "QuotationAuthor")
            )
        return "\n".join(parts)

    def _render_poem(self, poem: Poem) -> str:
        """Стихотворение: строки абзацами со стилем ``PoemLine``."""
        parts: List[str] = []
        if poem.title is not None:
            parts.append(self._render_title(poem.title, 3))
        for epigraph in poem.epigraphs:
            parts.append(self._render_epigraph(epigraph))
        for item in poem.items:
            if isinstance(item, Stanza):
                parts.append(self._render_stanza(item))
            elif isinstance(item, Subtitle):
                parts.append(
                    self._paragraph(self._render_markup(item.content), "Subtitle2")
                )
        for author in poem.text_author:
            parts.append(
                self._paragraph(self._render_markup(author.content), "PoemAuthor")
            )
        return "\n".join(part for part in parts if part)

    def _render_stanza(self, stanza: Stanza) -> str:
        """Строфа: подзаголовок и строки."""
        parts: List[str] = []
        if stanza.subtitle is not None:
            parts.append(
                self._paragraph(self._render_markup(stanza.subtitle.content), "Subtitle2")
            )
        for verse in stanza.verses:
            parts.append(self._paragraph(self._render_markup(verse.content), "PoemLine"))
        return "\n".join(part for part in parts if part)

    def _render_table(self, table: Table) -> str:
        """Таблица ODF (``table:table``)."""
        rows: List[str] = []
        for row in table.rows:
            cells: List[str] = []
            for cell in row.cells:
                style = "HeaderCell" if cell.is_header else None
                content = self._paragraph(self._render_markup(cell.children), style)
                cells.append(f"<table:table-cell>{content}</table:table-cell>")
            rows.append(f"<table:table-row>{''.join(cells)}</table:table-row>")
        return f"<table:table>{''.join(rows)}</table:table>"

    # --- Разметка внутри абзацев -------------------------------------------
    def _render_markup(
        self, nodes: List[StyleNode], flags: FrozenSet[str] = frozenset()
    ) -> str:
        """Отрендерить inline-разметку (``text:span``, ``text:a``, картинки)."""
        parts: List[str] = []
        for node in nodes:
            if node.tag == TEXT_NODE:
                parts.append(self._text(node.text or "", flags))
            elif node.tag == "a":
                parts.append(self._link(node, flags))
            elif node.tag == "image":
                parts.append(self._inline_frame(node))
            elif node.tag in MARKUP_TAGS:
                parts.append(self._render_markup(node.children, flags | {node.tag}))
            else:
                parts.append(self._render_markup(node.children, flags))
        return "".join(parts)

    def _text(self, text: str, flags: FrozenSet[str]) -> str:
        """Текст с оформлением (``text:span``) или без него."""
        if not text:
            return ""
        escaped = xml_escape(text)
        if not flags:
            return escaped
        name = self._style_name(flags)
        return f'<text:span text:style-name="{name}">{escaped}</text:span>'

    def _style_name(self, flags: FrozenSet[str]) -> str:
        """Имя автоматического текстового стиля для набора флагов."""
        key = tuple(sorted(flags))
        cached = self._style_names.get(key)
        if cached is not None:
            return cached

        name = f"T{len(self._style_names) + 1}"
        props: List[str] = []
        if "strong" in flags:
            props.append('fo:font-weight="bold"')
        if "emphasis" in flags:
            props.append('fo:font-style="italic"')
        if "code" in flags:
            props.append('style:font-name="Courier New"')
        if "strikethrough" in flags:
            props.append('style:text-line-through-style="solid"')
        if "sub" in flags:
            props.append('style:text-position="sub 58%"')
        if "sup" in flags:
            props.append('style:text-position="super 58%"')
        self._auto_styles.append(
            f'<style:style style:name="{name}" style:family="text">'
            f"<style:text-properties {' '.join(props)}/></style:style>"
        )
        self._style_names[key] = name
        return name

    def _link(self, node: StyleNode, flags: FrozenSet[str]) -> str:
        """Ссылка ``<a>`` -> ``text:a`` (внешняя — с ``xlink:href``)."""
        inner = self._render_markup(node.children, flags)
        href = node.href or ""
        if not href:
            return inner
        escaped = xml_escape(href, quote=True)
        return (
            f'<text:a xlink:type="simple" xlink:href="{escaped}">{inner}</text:a>'
        )

    def _inline_frame(self, node: StyleNode) -> str:
        """Inline-картинка внутри абзаца."""
        image = self._image_by_href(node.image_href or node.href)
        return self._frame(image) if image is not None else ""

    def _frame(self, image: OdtImage, anchor: str = "as-char") -> str:
        """Собрать ``draw:frame`` с изображением и зарегистрировать стиль."""
        self._frame_counter += 1
        style_name = f"fr{self._frame_counter}"
        self._auto_styles.append(
            f'<style:style style:name="{style_name}" style:family="graphic">'
            '<style:graphic-properties style:vertical-pos="top" '
            'style:vertical-rel="baseline" style:horizontal-pos="center" '
            'style:horizontal-rel="paragraph" style:wrap="none"/></style:style>'
        )
        return (
            f'<draw:frame draw:style-name="{style_name}" text:anchor-type="{anchor}" '
            f'svg:width="{image.width_cm}cm" svg:height="{image.height_cm}cm">'
            f'<draw:image xlink:href="Pictures/{image.filename}" xlink:type="simple" '
            'xlink:show="embed" xlink:actuate="onLoad"/>'
            "</draw:frame>"
        )

    def _image_frame(self, image: Optional[OdtImage], centered: bool = True) -> str:
        """Блочная картинка отдельным абзацем."""
        if image is None:
            return ""
        style = "Centered" if centered else "Standard"
        return f'<text:p text:style-name="{style}">{self._frame(image)}</text:p>'

    # --- Файлы контейнера --------------------------------------------------
    @staticmethod
    def _namespace_attrs() -> str:
        """Объявления пространств имён ODF."""
        return (
            f'xmlns:office="{NS_OFFICE}" xmlns:text="{NS_TEXT}" '
            f'xmlns:style="{NS_STYLE}" xmlns:fo="{NS_FO}" '
            f'xmlns:draw="{NS_DRAW}" xmlns:svg="{NS_SVG}" '
            f'xmlns:table="{NS_TABLE}" xmlns:xlink="{NS_XLINK}"'
        )

    def _content_xml(self, book: OdtBook) -> str:
        """Собрать ``content.xml`` (текст + автоматические стили)."""
        return (
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            f"<office:document-content {self._namespace_attrs()} "
            'office:version="1.2">\n'
            "<office:automatic-styles>\n"
            f"{book.automatic_styles}\n"
            "</office:automatic-styles>\n"
            "<office:body><office:text>\n"
            f"{book.content_xml}\n"
            "</office:text></office:body>\n"
            "</office:document-content>\n"
        )

    def _styles_xml(self) -> str:
        """Собрать ``styles.xml`` (базовые стили абзацев и страница)."""
        rendered: List[str] = []
        for name, paragraph, text in PARAGRAPH_STYLES:
            parts = [f'<style:style style:name="{name}" style:family="paragraph">']
            if paragraph:
                parts.append(f"<style:paragraph-properties {paragraph}/>")
            if text:
                parts.append(f"<style:text-properties {text}/>")
            parts.append("</style:style>")
            rendered.append("".join(parts))
        return (
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            f"<office:document-styles {self._namespace_attrs()} "
            'office:version="1.2">\n'
            "<office:styles>\n"
            '<style:style style:name="Standard" style:family="paragraph" '
            'style:class="text"/>\n'
            + "\n".join(rendered)
            + "\n</office:styles>\n"
            "<office:automatic-styles>\n"
            '<style:page-layout style:name="pm1">'
            '<style:page-layout-properties fo:page-width="21cm" '
            'fo:page-height="29.7cm" style:print-orientation="portrait" '
            'fo:margin="2cm"/></style:page-layout>\n'
            "</office:automatic-styles>\n"
            "<office:master-styles>"
            '<style:master-page style:name="Standard" style:page-layout-name="pm1"/>'
            "</office:master-styles>\n"
            "</office:document-styles>\n"
        )

    @staticmethod
    def _meta_xml(book: OdtBook) -> str:
        """Собрать ``meta.xml`` (метаданные документа)."""
        lines = [
            '<?xml version="1.0" encoding="UTF-8"?>',
            f'<office:document-meta xmlns:office="{NS_OFFICE}" '
            f'xmlns:meta="{NS_META}" xmlns:dc="{NS_DC}" office:version="1.2">',
            "<office:meta>",
            f"<dc:title>{xml_escape(book.title)}</dc:title>",
        ]
        for creator in book.creators:
            lines.append(f"<dc:creator>{xml_escape(creator)}</dc:creator>")
        lines.append(f"<dc:language>{xml_escape(book.language)}</dc:language>")
        if book.date:
            lines.append(f"<dc:date>{xml_escape(book.date)}</dc:date>")
        if book.description:
            lines.append(
                f"<dc:description>{xml_escape(book.description)}</dc:description>"
            )
        lines.append("<meta:generator>pyFB2</meta:generator>")
        lines.append("</office:meta>")
        lines.append("</office:document-meta>")
        return "\n".join(lines) + "\n"

    @staticmethod
    def _manifest_xml(book: OdtBook) -> str:
        """Собрать ``META-INF/manifest.xml``."""
        lines = [
            '<?xml version="1.0" encoding="UTF-8"?>',
            f'<manifest:manifest xmlns:manifest="{NS_MANIFEST}" '
            'manifest:version="1.2">',
            '<manifest:file-entry manifest:full-path="/" '
            f'manifest:media-type="{ODT_MIMETYPE}"/>',
        ]
        for name, media_type in (
            ("content.xml", "text/xml"),
            ("styles.xml", "text/xml"),
            ("meta.xml", "text/xml"),
        ):
            lines.append(
                f'<manifest:file-entry manifest:full-path="{name}" '
                f'manifest:media-type="{media_type}"/>'
            )
        for image in book.images:
            lines.append(
                '<manifest:file-entry manifest:full-path='
                f'"Pictures/{image.filename}" '
                f'manifest:media-type="{image.media_type}"/>'
            )
        lines.append("</manifest:manifest>")
        return "\n".join(lines) + "\n"


__all__ = ["Fb2ToOdtConverter", "OdtBook", "OdtImage"]


def main(argv: List[str] | None = None) -> int:
    if argv is None:
        argv = sys.argv
    if len(argv) < 2:
        print(
            "Использование: python fb2_to_odt.py <файл.fb2> [выход.odt]",
            file=sys.stderr,
        )
        return 2
    source = argv[1]
    output = argv[2] if len(argv) > 2 else str(Path(source).with_suffix(".odt"))
    converter = Fb2ToOdtConverter()
    path = converter.write(source, output)
    print("ODT:", path)
    if converter.book is not None:
        print("Изображений:", len(converter.book.images))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
