# -*- coding: utf-8 -*-
"""Преобразование книги FB2 в FictionBook 3 (FB3).

FB3 — это OPC-контейнер (ZIP) с частями Open XML::

    [Content_Types].xml                     типы частей
    _rels/.rels                             связи пакета (описание, метаданные)
    fb3/description.xml                     <fb3-description> (метаданные)
    fb3/body.xml                            <fb3-body> (текст)
    fb3/meta/core.xml                       Dublin Core свойства
    fb3/_rels/description.xml.rels          связь описания с телом
    fb3/_rels/body.xml.rels                 связи тела с изображениями
    fb3/img/*                               изображения

Пространства имён: ``http://www.fictionbook.org/FictionBook3/description``
(описание) и ``.../body`` (текст). Идентификаторы секций и субъектов — UUID.

Внешних зависимостей нет. Обратное преобразование — :mod:`fb3_to_fb2`.

Пример:
    >>> from fb2_to_fb3 import Fb2ToFb3Converter
    >>> Fb2ToFb3Converter().write("book.fb2", "book.fb3")
    WindowsPath('book.fb3')

CLI:
    python fb2_to_fb3.py book.fb2 [book.fb3]
"""

from __future__ import annotations

import base64
import io
import sys
import uuid
import zipfile
from dataclasses import dataclass, field
from datetime import date
from html import escape as xml_escape
from pathlib import Path
from typing import Dict, List, Optional, Union

from .fb2_errors import Fb2ConversionError
from .fb2_images import detect_image_type
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

#: Пространства имён FB3.
NS_DESCR = "http://www.fictionbook.org/FictionBook3/description"
NS_BODY = "http://www.fictionbook.org/FictionBook3/body"
NS_XLINK = "http://www.w3.org/1999/xlink"
NS_CONTENT_TYPES = "http://schemas.openxmlformats.org/package/2006/content-types"
NS_RELS = "http://schemas.openxmlformats.org/package/2006/relationships"
NS_CORE = (
    "http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
)
NS_DC = "http://purl.org/dc/elements/1.1/"
NS_DCTERMS = "http://purl.org/dc/terms/"

#: Типы связей FB3.
REL_BOOK = "http://www.fictionbook.org/FictionBook3/relationships/Book"
REL_BODY = "http://www.fictionbook.org/FictionBook3/relationships/body"
REL_IMAGE = "http://www.fictionbook.org/FictionBook3/relationships/image"
REL_THUMBNAIL = (
    "http://schemas.openxmlformats.org/package/2006/relationships/metadata/thumbnail"
)
REL_CORE = (
    "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties"
)

#: Типы частей FB3.
CT_DESCRIPTION = "application/fb3-description+xml"
CT_BODY = "application/fb3-body+xml"
CT_CORE = "application/vnd.openxmlformats-package.core-properties+xml"
CT_RELS = "application/vnd.openxmlformats-package.relationships+xml"

#: Inline-теги разметки FB3: тег FB2 -> тег FB3.
MARKUP_TAGS = {
    "strong": "strong",
    "emphasis": "em",
    "code": "code",
    "strikethrough": "strikethrough",
    "sub": "sub",
    "sup": "sup",
}


@dataclass
class Fb3Image:
    """Изображение контейнера FB3 (``fb3/img/...``)."""

    rel_id: str
    filename: str
    media_type: str
    data: bytes


@dataclass
class Fb3Document:
    """Промежуточное представление документа FB3."""

    identifier: str = ""
    description_xml: str = ""
    body_xml: str = ""
    core_xml: str = ""
    images: List[Fb3Image] = field(default_factory=list)
    cover: Optional[str] = None


class Fb2ToFb3Converter:
    """Преобразование книги FB2 в контейнер FB3.

    :param parser: готовый :class:`~fb2_parser.Fb2Parser` (иначе создаётся новый).
    """

    def __init__(self, parser: Optional[Fb2Parser] = None) -> None:
        self.parser = parser if parser is not None else Fb2Parser()
        self.source: Optional[Union[str, Path]] = None
        self._doc: Optional[Fb3Document] = None
        self._reset()

    def _reset(self) -> None:
        """Очистить состояние для нового преобразования."""
        self._images: List[Fb3Image] = []
        self._image_ids: Dict[str, str] = {}
        self._rel_counter = 0
        self._title = "Untitled"
        self._creators: List[str] = []
        self._genres: List[str] = []
        self._language = "ru"
        self._annotation: List[str] = []

    # --- Публичный API -----------------------------------------------------
    @property
    def document(self) -> Optional[Fb3Document]:
        """Последний собранный документ :class:`Fb3Document` (или None)."""
        return self._doc

    def convert(self, source: Optional[Union[str, Path]] = None) -> Fb3Document:
        """Прочитать FB2 и вернуть структуру :class:`Fb3Document`.

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
        self._read_metadata(title_info)
        self._collect_images(binaries)

        identifier = str(uuid.uuid4())
        cover = self._cover_name(title_info)
        body_xml = self._render_body(bodies)

        self._doc = Fb3Document(
            identifier=identifier,
            description_xml=self._description_xml(identifier, document_info),
            body_xml=body_xml,
            core_xml=self._core_xml(),
            images=self._images,
            cover=cover,
        )
        return self._doc

    def to_bytes(self, document: Optional[Fb3Document] = None) -> bytes:
        """Сериализовать документ (или результат :meth:`convert`) в FB3 (ZIP).

        :param document: готовая структура; если не задана, используется
            результат последнего вызова :meth:`convert`.
        """
        if document is None:
            document = self._doc
        if document is None:
            raise Fb2ConversionError("Нет книги для сериализации: вызовите convert()")

        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("[Content_Types].xml", self._content_types())
            archive.writestr("_rels/.rels", self._package_rels(document))
            archive.writestr("fb3/description.xml", document.description_xml)
            archive.writestr("fb3/body.xml", document.body_xml)
            archive.writestr("fb3/meta/core.xml", document.core_xml)
            archive.writestr(
                "fb3/_rels/description.xml.rels", self._description_rels()
            )
            archive.writestr("fb3/_rels/body.xml.rels", self._body_rels(document))
            for image in document.images:
                archive.writestr(f"fb3/img/{image.filename}", image.data)
        return buf.getvalue()

    def write(
        self,
        source: Optional[Union[str, Path]] = None,
        output: Optional[Union[str, Path]] = None,
    ) -> Path:
        """Преобразовать FB2 в файл FB3 и вернуть путь к результату.

        :param source: путь к FB2 (иначе ``self.source``).
        :param output: путь к ``.fb3``; по умолчанию — рядом с исходным ``.fb2``.
        """
        document = self.convert(source)
        data = self.to_bytes(document)

        if output is None:
            src = source if source is not None else self.source
            output = (
                Path(src).with_suffix(".fb3")
                if isinstance(src, (str, Path))
                else Path("book.fb3")
            )
        output = Path(output)
        output.write_bytes(data)
        return output

    # --- Метаданные --------------------------------------------------------
    def _read_metadata(self, title_info) -> None:
        """Собрать метаданные книги (название, авторы, жанры, язык)."""
        if title_info is None:
            return
        if title_info.book_title and title_info.book_title.value:
            self._title = title_info.book_title.value
        self._creators = [
            name
            for name in (self._author_text(author) for author in title_info.authors)
            if name
        ]
        self._genres = [genre.value for genre in title_info.genres if genre.value]
        if title_info.lang:
            self._language = title_info.lang
        if title_info.annotation is not None:
            texts = [
                self._markup_text(getattr(item, "content", []))
                for item in title_info.annotation.items
            ]
            self._annotation = [text for text in texts if text]

    @staticmethod
    def _author_text(author) -> str:
        """Имя автора: «Имя Отчество Фамилия» либо никнейм."""
        parts = [author.first_name, author.middle_name, author.last_name]
        name = " ".join(part.strip() for part in parts if part and part.strip())
        return name or (author.nickname or "").strip()

    @staticmethod
    def _markup_text(nodes: List[StyleNode]) -> str:
        """Собрать простой текст из узлов разметки."""
        parts: List[str] = []
        for node in nodes:
            if node.tag == TEXT_NODE:
                parts.append(node.text or "")
            else:
                parts.append(Fb2ToFb3Converter._markup_text(node.children))
        return "".join(parts)

    # --- Изображения -------------------------------------------------------
    def _collect_images(self, binaries: List[Binary]) -> None:
        """Разложить ``<binary>`` по ``fb3/img/`` и связи тела."""
        for binary in binaries:
            if binary.content_type and binary.content_type.startswith("image/svg"):
                continue
            try:
                data = base64.b64decode(binary.data or "")
            except (ValueError, TypeError):  # pragma: no cover - битые данные
                continue
            if not data:
                continue
            media_type, extension = detect_image_type(data)
            raw_id = binary.id or "image"
            base = Path(raw_id).stem if "." in raw_id else raw_id
            filename = f"{base or 'image'}{extension}"

            self._rel_counter += 1
            rel_id = f"img{self._rel_counter}"
            self._images.append(
                Fb3Image(
                    rel_id=rel_id,
                    filename=filename,
                    media_type=media_type,
                    data=data,
                )
            )
            self._image_ids[raw_id.lstrip("#")] = rel_id

    def _image_rel(self, href: Optional[str]) -> Optional[str]:
        """Идентификатор связи изображения по ссылке ``#id``."""
        if not href:
            return None
        return self._image_ids.get(href.lstrip("#"))

    def _cover_name(self, title_info) -> Optional[str]:
        """Имя файла обложки в контейнере (для thumbnail-связи)."""
        if title_info is None or title_info.coverpage is None:
            return None
        for image in title_info.coverpage.images:
            rel_id = self._image_rel(image.href)
            if rel_id:
                for stored in self._images:
                    if stored.rel_id == rel_id:
                        return stored.filename
        return None

    # --- Рендер тела -------------------------------------------------------
    def _render_body(self, bodies: List[Body]) -> str:
        """Собрать ``fb3/body.xml``."""
        parts: List[str] = []
        for body in bodies:
            if body.title is not None:
                parts.append(self._render_title(body.title))
            for epigraph in body.epigraphs:
                parts.append(self._render_epigraph(epigraph))
            if body.image is not None:
                parts.append(self._render_image_paragraph(body.image))
            for section in body.sections:
                parts.append(self._render_section(section))
        inner = "\n".join(part for part in parts if part)
        return (
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            f'<fb3-body xmlns="{NS_BODY}" xmlns:xlink="{NS_XLINK}"'
            f' id="{uuid.uuid4()}">\n{inner}\n</fb3-body>\n'
        )

    def _render_section(self, section: Section) -> str:
        """Отрендерить секцию (рекурсивно) с UUID-идентификатором."""
        parts: List[str] = [f'<section id="{uuid.uuid4()}">']
        if section.title is not None:
            parts.append(self._render_title(section.title))
        for epigraph in section.epigraphs:
            parts.append(self._render_epigraph(epigraph))
        if section.annotation is not None:
            parts.append(self._render_annotation(section.annotation))
        if section.image is not None:
            parts.append(self._render_image_paragraph(section.image))
        for block in section.content:
            parts.append(self._render_block(block))
        for child in section.sections:
            parts.append(self._render_section(child))
        parts.append("</section>")
        return "\n".join(part for part in parts if part)

    def _render_title(self, title: Title) -> str:
        """Заголовок: ``<title><p>...</p></title>``."""
        parts = [
            self._paragraph(item.content)
            for item in title.items
            if isinstance(item, Paragraph)
        ]
        return f"<title>{''.join(parts)}</title>" if parts else ""

    def _render_epigraph(self, epigraph: Epigraph) -> str:
        """Эпиграф с подписью (``<subscription>``)."""
        parts = [self._render_block(item) for item in epigraph.items]
        for author in epigraph.text_author:
            parts.append(f"<subscription>{self._paragraph(author.content)}</subscription>")
        inner = "".join(part for part in parts if part)
        return f"<epigraph>{inner}</epigraph>" if inner else ""

    def _render_annotation(self, annotation: Annotation) -> str:
        """Аннотация секции."""
        parts = [self._render_block(item) for item in annotation.items]
        inner = "".join(part for part in parts if part)
        return f"<annotation>{inner}</annotation>" if inner else ""

    def _render_block(self, block) -> str:
        """Отрендерить блочный элемент FB2 в элемент FB3."""
        if isinstance(block, Paragraph):
            return self._paragraph(block.content)
        if isinstance(block, Subtitle):
            return self._paragraph(block.content)
        if isinstance(block, EmptyLine):
            return "<br/>"
        if isinstance(block, Poem):
            return self._render_poem(block)
        if isinstance(block, Cite):
            return self._render_cite(block)
        if isinstance(block, Table):
            return self._render_table(block)
        if isinstance(block, Image):
            return self._render_image_paragraph(block)
        if isinstance(block, Epigraph):
            return self._render_epigraph(block)
        return ""

    def _paragraph(self, nodes: List[StyleNode]) -> str:
        """Абзац ``<p>`` с inline-разметкой."""
        return f"<p>{self._render_markup(nodes)}</p>"

    def _render_image_paragraph(self, image: Image) -> str:
        """Блочная картинка: ``<p><img src="imgN"/></p>``."""
        rel_id = self._image_rel(image.href)
        if not rel_id:
            return ""
        return f'<p><img src="{rel_id}"/></p>'

    def _render_poem(self, poem: Poem) -> str:
        """Стихотворение: ``<poem>`` со строфами (``<stanza>``)."""
        parts: List[str] = []
        if poem.title is not None:
            parts.append(self._render_title(poem.title))
        for epigraph in poem.epigraphs:
            parts.append(self._render_epigraph(epigraph))
        for item in poem.items:
            if isinstance(item, Stanza):
                parts.append(self._render_stanza(item))
            elif isinstance(item, Subtitle):
                parts.append(self._paragraph(item.content))
        for author in poem.text_author:
            parts.append(f"<subscription>{self._paragraph(author.content)}</subscription>")
        inner = "".join(part for part in parts if part)
        return f"<poem>{inner}</poem>" if inner else ""

    def _render_stanza(self, stanza: Stanza) -> str:
        """Строфа: подзаголовок и строки (``<p>``)."""
        parts: List[str] = []
        if stanza.subtitle is not None:
            parts.append(self._paragraph(stanza.subtitle.content))
        for verse in stanza.verses:
            parts.append(self._paragraph(verse.content))
        return f"<stanza>{''.join(parts)}</stanza>" if parts else ""

    def _render_cite(self, cite: Cite) -> str:
        """Цитата: ``<blockquote>``."""
        parts = [self._render_block(item) for item in cite.items]
        for author in cite.text_author:
            parts.append(f"<subscription>{self._paragraph(author.content)}</subscription>")
        inner = "".join(part for part in parts if part)
        return f"<blockquote>{inner}</blockquote>" if inner else ""

    def _render_table(self, table: Table) -> str:
        """Таблица: ``<table><tr><th|td>...</tr></table>``."""
        rows: List[str] = []
        for row in table.rows:
            cells: List[str] = []
            for cell in row.cells:
                tag = "th" if cell.is_header else "td"
                content = self._render_markup(cell.children)
                cells.append(f"<{tag}><p>{content}</p></{tag}>")
            rows.append(f"<tr>{''.join(cells)}</tr>")
        return f"<table>{''.join(rows)}</table>" if rows else ""

    # --- Разметка ----------------------------------------------------------
    def _render_markup(self, nodes: List[StyleNode]) -> str:
        """Отрендерить inline-разметку FB3."""
        parts: List[str] = []
        for node in nodes:
            if node.tag == TEXT_NODE:
                parts.append(xml_escape(node.text or ""))
            elif node.tag == "a":
                parts.append(self._link(node))
            elif node.tag == "image":
                rel_id = self._image_rel(node.image_href or node.href)
                if rel_id:
                    parts.append(f'<img src="{rel_id}"/>')
            elif node.tag in MARKUP_TAGS:
                tag = MARKUP_TAGS[node.tag]
                inner = self._render_markup(node.children)
                parts.append(f"<{tag}>{inner}</{tag}>")
            elif node.tag == "style":
                class_attr = f' class="{xml_escape(node.name or "", quote=True)}"' if node.name else ""
                parts.append(f"<span{class_attr}>{self._render_markup(node.children)}</span>")
            else:
                parts.append(self._render_markup(node.children))
        return "".join(parts)

    def _link(self, node: StyleNode) -> str:
        """Ссылка ``<a xlink:href="...">``."""
        inner = self._render_markup(node.children)
        href = node.href or ""
        if not href:
            return inner
        return f'<a xlink:href="{xml_escape(href, quote=True)}">{inner}</a>'

    # --- Файлы контейнера --------------------------------------------------
    def _description_xml(self, identifier: str, document_info) -> str:
        """Собрать ``fb3/description.xml`` (метаданные FB3)."""
        lines = [
            '<?xml version="1.0" encoding="UTF-8"?>',
            f'<fb3-description xmlns="{NS_DESCR}" xmlns:xlink="{NS_XLINK}"'
            f' id="{identifier}" version="1.0">',
            f"<title><main>{xml_escape(self._title)}</main></title>",
        ]
        if self._creators:
            lines.append("<fb3-relations>")
            lines.extend(self._subject_xml(name) for name in self._creators)
            lines.append("</fb3-relations>")
        if self._genres:
            lines.append("<fb3-classification>")
            lines.extend(
                f"<subject>{xml_escape(genre)}</subject>" for genre in self._genres
            )
            lines.append("</fb3-classification>")
        lines.append(f"<lang>{xml_escape(self._language)}</lang>")
        created = self._document_date(document_info)
        lines.append(f'<document-info created="{created}" updated="{created}"/>')
        if self._annotation:
            lines.append("<annotation>")
            lines.extend(f"<p>{xml_escape(text)}</p>" for text in self._annotation)
            lines.append("</annotation>")
        lines.append("</fb3-description>")
        return "\n".join(lines) + "\n"

    @staticmethod
    def _subject_xml(name: str) -> str:
        """Субъект-автор для ``<fb3-relations>``."""
        parts = name.split()
        if len(parts) == 1:
            first, middle, last = "", "", parts[0]
        else:
            first, last = parts[0], parts[-1]
            middle = " ".join(parts[1:-1])
        body = [f"<title><main>{xml_escape(name)}</main></title>"]
        if first:
            body.append(f"<first-name>{xml_escape(first)}</first-name>")
        if middle:
            body.append(f"<middle-name>{xml_escape(middle)}</middle-name>")
        if last:
            body.append(f"<last-name>{xml_escape(last)}</last-name>")
        return (
            f'<subject link="author" id="{uuid.uuid4()}">'
            + "".join(body)
            + "</subject>"
        )

    @staticmethod
    def _document_date(document_info) -> str:
        """Дата документа (``<document-info><date>`` или сегодня)."""
        if document_info is not None and document_info.date is not None:
            value = (
                getattr(document_info.date, "date_value", None)
                or document_info.date.value
            )
            if value:
                return value
        return date.today().isoformat()

    def _core_xml(self) -> str:
        """Собрать ``fb3/meta/core.xml`` (Dublin Core)."""
        lines = [
            '<?xml version="1.0" encoding="UTF-8"?>',
            f'<cp:coreProperties xmlns:cp="{NS_CORE}" xmlns:dc="{NS_DC}"'
            f' xmlns:dcterms="{NS_DCTERMS}">',
            f"<dc:title>{xml_escape(self._title)}</dc:title>",
        ]
        lines.extend(
            f"<dc:creator>{xml_escape(creator)}</dc:creator>"
            for creator in self._creators
        )
        if self._annotation:
            lines.append(
                f"<dc:description>{xml_escape(chr(10).join(self._annotation))}"
                "</dc:description>"
            )
        lines.append(f"<dc:language>{xml_escape(self._language)}</dc:language>")
        lines.append(
            f"<dcterms:created>{date.today().isoformat()}</dcterms:created>"
        )
        lines.append("</cp:coreProperties>")
        return "\n".join(lines) + "\n"

    @staticmethod
    def _content_types() -> str:
        """Собрать ``[Content_Types].xml``."""
        defaults = (
            ("rels", CT_RELS),
            ("png", "image/png"),
            ("jpg", "image/jpeg"),
            ("jpeg", "image/jpeg"),
            ("gif", "image/gif"),
            ("svg", "image/svg+xml"),
            ("xml", "application/xml"),
            ("css", "text/css"),
        )
        lines = [
            '<?xml version="1.0" encoding="UTF-8"?>',
            f'<Types xmlns="{NS_CONTENT_TYPES}">',
        ]
        lines.extend(
            f'<Default Extension="{extension}" ContentType="{content_type}"/>'
            for extension, content_type in defaults
        )
        lines.extend(
            f'<Override PartName="{part}" ContentType="{content_type}"/>'
            for part, content_type in (
                ("/fb3/meta/core.xml", CT_CORE),
                ("/fb3/description.xml", CT_DESCRIPTION),
                ("/fb3/body.xml", CT_BODY),
            )
        )
        lines.append("</Types>")
        return "\n".join(lines) + "\n"

    @staticmethod
    def _package_rels(document: Fb3Document) -> str:
        """Собрать ``_rels/.rels`` (связи пакета)."""
        lines = [
            '<?xml version="1.0" encoding="UTF-8"?>',
            f'<Relationships xmlns="{NS_RELS}">',
        ]
        counter = 0
        if document.cover:
            lines.append(
                f'<Relationship Id="rId{counter}" Type="{REL_THUMBNAIL}"'
                f' Target="fb3/img/{document.cover}"/>'
            )
            counter += 1
        lines.append(
            f'<Relationship Id="rId{counter}" Type="{REL_CORE}"'
            ' Target="fb3/meta/core.xml"/>'
        )
        counter += 1
        lines.append(
            f'<Relationship Id="rId{counter}" Type="{REL_BOOK}"'
            ' Target="fb3/description.xml"/>'
        )
        lines.append("</Relationships>")
        return "\n".join(lines) + "\n"

    @staticmethod
    def _description_rels() -> str:
        """Собрать ``fb3/_rels/description.xml.rels`` (связь с телом)."""
        return (
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            f'<Relationships xmlns="{NS_RELS}">\n'
            f'<Relationship Id="rId0" Type="{REL_BODY}" Target="body.xml"/>\n'
            "</Relationships>\n"
        )

    @staticmethod
    def _body_rels(document: Fb3Document) -> str:
        """Собрать ``fb3/_rels/body.xml.rels`` (изображения)."""
        lines = [
            '<?xml version="1.0" encoding="UTF-8"?>',
            f'<Relationships xmlns="{NS_RELS}" xmlns:xlink="{NS_XLINK}">',
        ]
        lines.extend(
            f'<Relationship Id="{image.rel_id}" Type="{REL_IMAGE}"'
            f' Target="img/{image.filename}"/>'
            for image in document.images
        )
        lines.append("</Relationships>")
        return "\n".join(lines) + "\n"


__all__ = ["Fb2ToFb3Converter", "Fb3Document", "Fb3Image"]


def main(argv: List[str] | None = None) -> int:
    if argv is None:
        argv = sys.argv
    if len(argv) < 2:
        print(
            "Использование: python fb2_to_fb3.py <файл.fb2> [выход.fb3]",
            file=sys.stderr,
        )
        return 2
    source = argv[1]
    output = argv[2] if len(argv) > 2 else str(Path(source).with_suffix(".fb3"))
    converter = Fb2ToFb3Converter()
    path = converter.write(source, output)
    print("FB3:", path)
    if converter.document is not None:
        print("Изображений:", len(converter.document.images))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
