"""Преобразование FictionBook (FB2) в книгу EPUB.

Модуль предоставляет класс :class:`Fb2ToEpubConverter`, который читает
FB2-файл (через :class:`~fb2_parser.Fb2Parser`), извлекает метаданные,
текст и встроенные изображения и собирает из них EPUB-архив (ZIP):
``mimetype``, ``META-INF/container.xml``, OPF-манифест, оглавление
(NCX и/или XHTML Navigation Document), XHTML-документы и изображения.

Поддерживаются обе версии формата:

    * **EPUB 2.0** (по умолчанию) — OPF 2.0, ``toc.ncx``, XHTML 1.1;
    * **EPUB 3.0** (``epub_version=3``) — OPF 3.0, ``nav.xhtml``
      (XHTML Navigation Document), ``properties="nav"``/``"cover-image"``,
      обязательный ``<meta property="dcterms:modified">``, HTML5-doctype.
      Для обратной совместимости со старыми читалками дополнительно
      записывается ``toc.ncx``.

Промежуточное представление — :class:`EpubBook` (метаданные + документы +
ресурсы). Его можно сериализовать в байты
(:meth:`Fb2ToEpubConverter.to_bytes`) или записать в файл
(:meth:`Fb2ToEpubConverter.write`).

Что поддерживается:

    * метаданные <description> -> OPF (<dc:title>, <dc:creator>,
      <dc:language>, <dc:identifier>, <dc:date>, <dc:description>,
      <dc:subject>);
    * обложка (<coverpage>) -> cover-image + cover-документ;
    * <binary> -> файлы изображений в архиве;
    * каждая секция верхнего уровня -> отдельный XHTML-документ;
    * заголовки -> <h1>-<h6>, <p>, <strong>, <emphasis>, <a>, <img>,
      <blockquote> (cite/epigraph), стихи, таблицы, <sub>/<sup>/<code>,
      <del> (strikethrough), <span class="..."> (style).

Пример::

    >>> from fb2_to_epub import Fb2ToEpubConverter
    >>> converter = Fb2ToEpubConverter()                 # EPUB 2.0
    >>> path = converter.write("book.fb2", "book.epub")
    WindowsPath('book.epub')
    >>> epub3 = Fb2ToEpubConverter(epub_version=3)       # EPUB 3.0
    >>> epub3.write("book.fb2", "book3.epub")
    >>> book = converter.convert("book.fb2")   # структура EpubBook
    >>> data = converter.to_bytes(book)        # bytes ZIP-архива
"""

from __future__ import annotations

import io
import sys
import uuid
import zipfile
from dataclasses import dataclass, field
from datetime import datetime, timezone
from html import escape as html_escape
from pathlib import Path
from typing import Dict, List, Optional, Union

from .fb2_errors import Fb2ConversionError
from .fb2_parser import TEXT_NODE, Fb2Parser
from .fb2_structures import (
    Annotation,
    Author,
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

# --- Пространства имён EPUB -------------------------------------------------
NS_CONTAINER = "urn:oasis:names:tc:opendocument:xmlns:container"
NS_OPF = "http://www.idpf.org/2007/opf"
NS_DC = "http://purl.org/dc/elements/1.1/"
NS_NCX = "http://www.daisy.org/z3986/2005/ncx/"
NS_XHTML = "http://www.w3.org/1999/xhtml"
NS_EPUB = "http://www.idpf.org/2007/ops"

#: Версия EPUB по умолчанию (2 — EPUB 2.0, 3 — EPUB 3.0).
DEFAULT_EPUB_VERSION = 2

#: Заголовок оглавления в ``nav.xhtml`` (EPUB 3).
TOC_TITLE = "Оглавление"

#: Максимальный уровень заголовка XHTML.
_MAX_HEADING = 6

#: Простой CSS для EPUB (подзаголовки, эпиграфы, стихи, таблицы).
DEFAULT_CSS = """\
body { font-family: serif; line-height: 1.4; }
h1, h2, h3, h4, h5, h6 { text-align: center; }
p { margin: 0; text-indent: 1.2em; }
p.subtitle { text-align: center; font-weight: bold; text-indent: 0; margin: 1em 0; }
p.empty-line { text-indent: 0; height: 1em; }
blockquote { margin: 1em 2em; }
blockquote.epigraph { font-style: italic; }
div.poem { margin: 1em 2em; }
div.poem p { text-indent: 0; }
div.image, div.cover { text-align: center; margin: 1em 0; }
table { border-collapse: collapse; margin: 1em auto; }
td, th { border: 1px solid #888; padding: 0.2em 0.5em; }
"""


@dataclass
class EpubResource:
    """Файл-ресурс EPUB (изображение, CSS и т. п.)."""

    id: str
    href: str
    media_type: str
    data: bytes


@dataclass
class EpubDocument:
    """XHTML-документ EPUB."""

    id: str
    href: str
    title: str
    content: str


@dataclass
class EpubBook:
    """Промежуточное представление EPUB-книги."""

    title: str = "Untitled"
    creators: List[str] = field(default_factory=list)
    language: str = "ru"
    identifier: str = ""
    date: str = ""
    description: str = ""
    subjects: List[str] = field(default_factory=list)
    cover_id: Optional[str] = None
    resources: List[EpubResource] = field(default_factory=list)
    documents: List[EpubDocument] = field(default_factory=list)
    version: int = DEFAULT_EPUB_VERSION


class Fb2ToEpubConverter:
    """Преобразование книги FB2 в EPUB (промежуточная структура + ZIP).

    :param parser: готовый :class:`~fb2_parser.Fb2Parser` (иначе создаётся новый).
    :param css: содержимое ``style.css`` для EPUB (по умолчанию :data:`DEFAULT_CSS`).
    :param epub_version: версия формата: ``2`` — EPUB 2.0 (по умолчанию),
        ``3`` — EPUB 3.0 (OPF 3.0 + ``nav.xhtml``).
    :param toc_title: заголовок оглавления в ``nav.xhtml`` (EPUB 3).
    """

    def __init__(
        self,
        parser: Optional[Fb2Parser] = None,
        css: str = DEFAULT_CSS,
        epub_version: int = DEFAULT_EPUB_VERSION,
        toc_title: str = TOC_TITLE,
    ) -> None:
        self.parser = parser if parser is not None else Fb2Parser()
        self.css = css
        self.epub_version = 3 if int(epub_version) >= 3 else 2
        self.toc_title = toc_title
        self.source: Optional[Union[str, Path]] = None
        self._book: Optional[EpubBook] = None

    # --- Публичный API -----------------------------------------------------
    @property
    def book(self) -> Optional[EpubBook]:
        """Последняя собранная структура :class:`EpubBook` (или None)."""
        return self._book

    def convert(self, source: Optional[Union[str, Path]] = None) -> EpubBook:
        """Прочитать FB2 и вернуть структуру :class:`EpubBook`.

        :param source: путь к FB2 (иначе берётся ``self.source``).
        """
        if source is not None:
            self.source = source

        parser = self.parser
        description = parser.parse(self.source)
        bodies = parser.parse_bodies(self.source)
        binaries = parser.parse_binaries(self.source)

        title_info = description.title_info
        document_info = description.document_info

        image_map, resources = self._collect_resources(binaries)
        documents = self._build_documents(bodies, image_map)

        cover_href = self._cover_href(title_info, image_map)
        cover_id = self._resource_id(resources, cover_href)
        if cover_href:
            documents.insert(0, self._cover_document(cover_href))

        self._book = EpubBook(
            title=self._book_title(title_info),
            creators=self._creators(title_info),
            language=self._language(title_info),
            identifier=self._identifier(document_info),
            date=self._date(title_info, document_info),
            description=self._annotation_text(title_info),
            subjects=self._subjects(title_info),
            cover_id=cover_id,
            resources=resources,
            documents=documents,
            version=self.epub_version,
        )
        return self._book

    def to_bytes(self, book: Optional[EpubBook] = None) -> bytes:
        """Сериализовать книгу (или результат :meth:`convert`) в EPUB (ZIP).

        :param book: готовая структура; если не задана, используется
            результат последнего вызова :meth:`convert`.
        """
        if book is None:
            book = self._book
        if book is None:
            raise Fb2ConversionError("Нет книги для сериализации: вызовите convert()")

        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as archive:
            # mimetype должен идти первым и без сжатия (требование EPUB).
            archive.writestr(
                "mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED
            )
            archive.writestr("META-INF/container.xml", self._container_xml())
            archive.writestr("OEBPS/content.opf", self._opf(book))
            archive.writestr("OEBPS/toc.ncx", self._ncx(book))
            if book.version >= 3:
                archive.writestr("OEBPS/nav.xhtml", self._nav_xhtml(book))
            archive.writestr("OEBPS/style.css", self.css)
            for doc in book.documents:
                archive.writestr(f"OEBPS/{doc.href}", doc.content)
            for resource in book.resources:
                archive.writestr(f"OEBPS/{resource.href}", resource.data)
        return buf.getvalue()

    def write(
        self,
        source: Optional[Union[str, Path]] = None,
        output: Optional[Union[str, Path]] = None,
    ) -> Path:
        """Преобразовать FB2 в файл EPUB и вернуть путь к результату.

        :param source: путь к FB2 (иначе ``self.source``).
        :param output: путь к выходному ``.epub``; по умолчанию — рядом с
            исходным ``.fb2``.
        """
        book = self.convert(source)
        data = self.to_bytes(book)

        if output is None:
            src = source if source is not None else self.source
            output = Path(src).with_suffix(".epub") if isinstance(src, (str, Path)) else Path("book.epub")
        output = Path(output)
        output.write_bytes(data)
        return output

    # --- Метаданные FB2 -> EPUB -------------------------------------------
    @staticmethod
    def _markup_text(nodes: List[StyleNode]) -> str:
        """Собрать простой текст из списка узлов разметки."""
        parts: List[str] = []
        for node in nodes:
            if node.tag == TEXT_NODE:
                parts.append(node.text or "")
            else:
                parts.append(Fb2ToEpubConverter._markup_text(node.children))
        return "".join(parts)

    @staticmethod
    def _book_title(title_info) -> str:
        """Название книги из <book-title>."""
        if title_info is not None and title_info.book_title is not None:
            return title_info.book_title.value or "Untitled"
        return "Untitled"

    @staticmethod
    def _author_text(author: Author) -> str:
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
                parts.append(Fb2ToEpubConverter._markup_text(item.content))
        return " ".join(p for p in parts if p)

    @staticmethod
    def _subjects(title_info) -> List[str]:
        """Жанры книги из <genre>."""
        if title_info is None:
            return []
        return [genre.value for genre in title_info.genres]

    # --- Ресурсы (изображения) --------------------------------------------
    def _collect_resources(self, binaries: List[Binary]):
        """Собрать изображения в ресурсы EPUB и карту ссылок FB2 -> EPUB."""
        image_map: Dict[str, str] = {}
        resources: List[EpubResource] = []
        for index, binary in enumerate(binaries, 1):
            try:
                data = Fb2Parser.binary_data(binary)
            except (ValueError, TypeError):
                continue
            filename = Fb2Parser.binary_filename(binary)
            href = f"images/{filename}"
            resource = EpubResource(
                id=f"img{index}",
                href=href,
                media_type=binary.content_type or "application/octet-stream",
                data=data,
            )
            resources.append(resource)
            for key in (binary.id, f"#{binary.id}", filename, f"#{filename}"):
                if key:
                    image_map[key] = href
        return image_map, resources

    @staticmethod
    def _cover_href(title_info, image_map: Dict[str, str]) -> Optional[str]:
        """Определить href обложки в EPUB (или None)."""
        if title_info is None or title_info.coverpage is None:
            return None
        for image in title_info.coverpage.images:
            if not image.href:
                continue
            href = image_map.get(image.href) or image_map.get(image.href.lstrip("#"))
            if href:
                return href
        return None

    @staticmethod
    def _resource_id(resources: List[EpubResource], href: Optional[str]) -> Optional[str]:
        """Найти id ресурса по его href."""
        if not href:
            return None
        for resource in resources:
            if resource.href == href:
                return resource.id
        return None

    # --- Построение XHTML-документов --------------------------------------
    def _build_documents(self, bodies: List[Body], image_map: Dict[str, str]) -> List[EpubDocument]:
        """Собрать список XHTML-документов EPUB из тел FB2."""
        documents: List[EpubDocument] = []
        counter = 0

        for body in bodies:
            if body.title is not None and body.sections:
                counter += 1
                documents.append(self._body_title_document(body, counter, image_map))
            if body.sections:
                for section in body.sections:
                    counter += 1
                    documents.append(self._section_document(section, counter, image_map))
            else:
                counter += 1
                documents.append(self._body_document(body, counter, image_map))

        if not documents:
            counter += 1
            documents.append(
                EpubDocument(
                    id="doc1",
                    href="chap1.xhtml",
                    title="Book",
                    content=self._xhtml("Book", ""),
                )
            )
        return documents

    def _cover_document(self, cover_href: str) -> EpubDocument:
        """Документ с изображением обложки."""
        body = (
            '<div class="cover">'
            f'<img src="{html_escape(cover_href)}" alt="cover"/>'
            "</div>"
        )
        return EpubDocument(id="cover", href="cover.xhtml", title="Cover", content=self._xhtml("Cover", body))

    def _body_title_document(self, body: Body, number: int, image_map: Dict[str, str]) -> EpubDocument:
        """Документ с заголовком <body> (титульный)."""
        title = self._title_text(body.title) or f"Part {number}"
        parts = [self._render_title(body.title, 1)]
        for epigraph in body.epigraphs:
            parts.append(self._render_epigraph(epigraph, image_map))
        if body.image is not None:
            parts.append(self._render_block_image(body.image, image_map))
        content = self._xhtml(title, "\n".join(p for p in parts if p))
        return EpubDocument(id=f"doc{number}", href=f"chap{number}.xhtml", title=title, content=content)

    def _body_document(self, body: Body, number: int, image_map: Dict[str, str]) -> EpubDocument:
        """Документ для <body> без секций."""
        title = self._title_text(body.title) or f"Book {number}"
        parts: List[str] = []
        if body.title is not None:
            parts.append(self._render_title(body.title, 1))
        for epigraph in body.epigraphs:
            parts.append(self._render_epigraph(epigraph, image_map))
        if body.image is not None:
            parts.append(self._render_block_image(body.image, image_map))
        content = self._xhtml(title, "\n".join(p for p in parts if p))
        return EpubDocument(id=f"doc{number}", href=f"chap{number}.xhtml", title=title, content=content)

    def _section_document(self, section: Section, number: int, image_map: Dict[str, str]) -> EpubDocument:
        """Документ для секции верхнего уровня."""
        title = self._title_text(section.title) or f"Section {number}"
        content = self._xhtml(title, self._render_section(section, 1, image_map))
        return EpubDocument(id=f"doc{number}", href=f"chap{number}.xhtml", title=title, content=content)

    @staticmethod
    def _title_text(title: Optional[Title]) -> str:
        """Текст заголовка в одну строку."""
        if title is None:
            return ""
        parts: List[str] = []
        for item in title.items:
            if isinstance(item, Paragraph):
                parts.append(Fb2ToEpubConverter._markup_text(item.content))
        return " ".join(p for p in parts if p)

    def _xhtml(self, title: str, body_html: str) -> str:
        """Обернуть фрагмент в полноценный XHTML-документ.

        Для EPUB 3 используется HTML5-doctype и ``<meta charset>``,
        для EPUB 2 — XHTML 1.1 и ``<meta http-equiv>``.
        """
        if self.epub_version >= 3:
            header = (
                '<?xml version="1.0" encoding="utf-8"?>\n'
                "<!DOCTYPE html>\n"
                f'<html xmlns="{NS_XHTML}" xmlns:epub="{NS_EPUB}">\n'
            )
            meta = '  <meta charset="utf-8"/>\n'
        else:
            header = (
                '<?xml version="1.0" encoding="utf-8"?>\n'
                '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" '
                '"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">\n'
                f'<html xmlns="{NS_XHTML}">\n'
            )
            meta = '  <meta http-equiv="Content-Type" content="text/html; charset=utf-8"/>\n'

        return (
            header
            + "<head>\n"
            + f"  <title>{html_escape(title)}</title>\n"
            + meta
            + '  <link rel="stylesheet" type="text/css" href="style.css"/>\n'
            + "</head>\n"
            + "<body>\n"
            + f"{body_html}\n"
            + "</body>\n"
            + "</html>\n"
        )

    # --- Рендеринг XHTML ---------------------------------------------------
    def _render_section(self, section: Section, level: int, image_map: Dict[str, str]) -> str:
        """Отрисовать секцию (рекурсивно) в XHTML-фрагмент."""
        parts: List[str] = []
        if section.title is not None:
            parts.append(self._render_title(section.title, level, image_map))
        for epigraph in section.epigraphs:
            parts.append(self._render_epigraph(epigraph, image_map))
        if section.image is not None:
            parts.append(self._render_block_image(section.image, image_map))
        if section.annotation is not None:
            parts.append(self._render_annotation(section.annotation, image_map))
        for block in section.content:
            parts.append(self._render_block(block, image_map))
        for child in section.sections:
            parts.append(self._render_section(child, level + 1, image_map))
        return "\n".join(p for p in parts if p)

    @staticmethod
    def _heading_tag(level: int) -> str:
        """Тег заголовка по уровню (h1..h6)."""
        return f"h{min(max(level, 1), _MAX_HEADING)}"

    def _render_title(self, title: Optional[Title], level: int, image_map: Optional[Dict[str, str]] = None) -> str:
        """Отрисовать заголовок как <h1>..<h6>."""
        if title is None:
            return ""
        image_map = image_map or {}
        parts: List[str] = []
        for item in title.items:
            if isinstance(item, Paragraph):
                parts.append(self._render_markup(item.content, image_map))
        text = " ".join(p for p in parts if p)
        if not text:
            return ""
        tag = self._heading_tag(level)
        return f"<{tag}>{text}</{tag}>"

    def _render_epigraph(self, epigraph: Epigraph, image_map: Dict[str, str]) -> str:
        """Отрисовать эпиграф как <blockquote class="epigraph">."""
        parts: List[str] = []
        for item in epigraph.items:
            parts.append(self._render_block(item, image_map))
        for author in epigraph.text_author:
            parts.append(self._render_paragraph(author, image_map, css_class="text-author"))
        inner = "\n".join(p for p in parts if p)
        return f'<blockquote class="epigraph">\n{inner}\n</blockquote>' if inner else ""

    def _render_annotation(self, annotation: Annotation, image_map: Dict[str, str]) -> str:
        """Отрисовать аннотацию как <div class="annotation">."""
        parts: List[str] = []
        for item in annotation.items:
            parts.append(self._render_block(item, image_map))
        inner = "\n".join(p for p in parts if p)
        return f'<div class="annotation">\n{inner}\n</div>' if inner else ""

    def _render_block(self, block, image_map: Dict[str, str]) -> str:
        """Отрисовать блочный элемент FB2 в XHTML."""
        if isinstance(block, Paragraph):
            return self._render_paragraph(block, image_map)
        if isinstance(block, Subtitle):
            return self._render_subtitle(block, image_map)
        if isinstance(block, EmptyLine):
            return '<p class="empty-line">&#160;</p>'
        if isinstance(block, Cite):
            return self._render_cite(block, image_map)
        if isinstance(block, Poem):
            return self._render_poem(block, image_map)
        if isinstance(block, Table):
            return self._render_table(block, image_map)
        if isinstance(block, Image):
            return self._render_block_image(block, image_map)
        return ""

    def _render_paragraph(self, paragraph: Paragraph, image_map: Dict[str, str], css_class: Optional[str] = None) -> str:
        """Отрисовать абзац как <p>."""
        inner = self._render_markup(paragraph.content, image_map)
        attr = f' class="{css_class}"' if css_class else ""
        return f"<p{attr}>{inner}</p>"

    def _render_subtitle(self, subtitle: Subtitle, image_map: Dict[str, str]) -> str:
        """Отрисовать подзаголовок как <p class="subtitle">."""
        inner = self._render_markup(subtitle.content, image_map)
        return f'<p class="subtitle">{inner}</p>'

    def _render_cite(self, cite: Cite, image_map: Dict[str, str]) -> str:
        """Отрисовать цитату как <blockquote>."""
        parts: List[str] = []
        for item in cite.items:
            parts.append(self._render_block(item, image_map))
        for author in cite.text_author:
            parts.append(self._render_paragraph(author, image_map, css_class="text-author"))
        inner = "\n".join(p for p in parts if p)
        return f"<blockquote>\n{inner}\n</blockquote>" if inner else ""

    def _render_poem(self, poem: Poem, image_map: Dict[str, str]) -> str:
        """Отрисовать стихотворение как <div class="poem">."""
        parts: List[str] = []
        if poem.title is not None:
            parts.append(self._render_title(poem.title, 4, image_map))
        for epigraph in poem.epigraphs:
            parts.append(self._render_epigraph(epigraph, image_map))
        for item in poem.items:
            if isinstance(item, Stanza):
                parts.append(self._render_stanza(item, image_map))
            elif isinstance(item, Subtitle):
                parts.append(self._render_subtitle(item, image_map))
        for author in poem.text_author:
            parts.append(self._render_paragraph(author, image_map, css_class="text-author"))
        inner = "\n".join(p for p in parts if p)
        return f'<div class="poem">\n{inner}\n</div>' if inner else ""

    def _render_stanza(self, stanza: Stanza, image_map: Dict[str, str]) -> str:
        """Отрисовать строфу."""
        parts: List[str] = []
        if stanza.title is not None:
            parts.append(self._render_title(stanza.title, 5, image_map))
        if stanza.subtitle is not None:
            parts.append(self._render_subtitle(stanza.subtitle, image_map))
        for verse in stanza.verses:
            parts.append(f"<p>{self._render_markup(verse.content, image_map)}</p>")
        return "\n".join(p for p in parts if p)

    def _render_table(self, table: Table, image_map: Dict[str, str]) -> str:
        """Отрисовать таблицу как <table>."""
        rows: List[str] = []
        for row in table.rows:
            cells: List[str] = []
            for cell in row.cells:
                tag = "th" if cell.is_header else "td"
                attrs = ""
                if cell.colspan is not None:
                    attrs += f' colspan="{cell.colspan}"'
                if cell.rowspan is not None:
                    attrs += f' rowspan="{cell.rowspan}"'
                inner = self._render_markup(cell.children, image_map)
                cells.append(f"<{tag}{attrs}>{inner}</{tag}>")
            rows.append("<tr>" + "".join(cells) + "</tr>")
        return "<table>" + "".join(rows) + "</table>"

    def _render_markup(self, nodes: List[StyleNode], image_map: Dict[str, str]) -> str:
        """Отрисовать mixed-разметку (текст + inline-элементы)."""
        parts: List[str] = []
        for node in nodes:
            tag = node.tag
            if tag == TEXT_NODE:
                parts.append(html_escape(node.text or "", quote=False))
            elif tag == "strong":
                parts.append(f"<strong>{self._render_markup(node.children, image_map)}</strong>")
            elif tag == "emphasis":
                parts.append(f"<em>{self._render_markup(node.children, image_map)}</em>")
            elif tag == "strikethrough":
                parts.append(f"<del>{self._render_markup(node.children, image_map)}</del>")
            elif tag in ("sub", "sup", "code"):
                parts.append(f"<{tag}>{self._render_markup(node.children, image_map)}</{tag}>")
            elif tag == "style":
                css_class = html_escape(node.name or "", quote=True)
                parts.append(f'<span class="{css_class}">{self._render_markup(node.children, image_map)}</span>')
            elif tag == "a":
                href = html_escape(node.href or "", quote=True)
                parts.append(f'<a href="{href}">{self._render_markup(node.children, image_map)}</a>')
            elif tag == "image":
                parts.append(self._render_inline_image(node, image_map))
        return "".join(parts)

    def _render_block_image(self, image: Image, image_map: Dict[str, str]) -> str:
        """Отрисовать блочное изображение."""
        src = self._image_src(image.href, image_map)
        if not src:
            return ""
        alt = html_escape(image.alt or "", quote=True)
        return f'<div class="image"><img src="{src}" alt="{alt}"/></div>'

    def _render_inline_image(self, node: StyleNode, image_map: Dict[str, str]) -> str:
        """Отрисовать inline-изображение."""
        src = self._image_src(node.image_href, image_map)
        if not src:
            return ""
        alt = html_escape(node.image_alt or "", quote=True)
        return f'<img src="{src}" alt="{alt}"/>'

    @staticmethod
    def _image_src(href: Optional[str], image_map: Dict[str, str]) -> str:
        """Получить href изображения в EPUB по ссылке FB2 (#id)."""
        if not href:
            return ""
        src = image_map.get(href) or image_map.get(href.lstrip("#"))
        return html_escape(src, quote=True) if src else ""

    # --- Метафайлы EPUB ----------------------------------------------------
    @staticmethod
    def _container_xml() -> str:
        """Содержимое META-INF/container.xml."""
        return (
            '<?xml version="1.0" encoding="utf-8"?>\n'
            f'<container version="1.0" xmlns="{NS_CONTAINER}">\n'
            "  <rootfiles>\n"
            '    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>\n'
            "  </rootfiles>\n"
            "</container>\n"
        )

    def _opf(self, book: EpubBook) -> str:
        """Собрать OPF-манифест (content.opf): версия 2.0 или 3.0."""
        if book.version >= 3:
            return self._opf3(book)
        return self._opf2(book)

    def _opf2(self, book: EpubBook) -> str:
        """Собрать OPF 2.0 (content.opf)."""
        parts: List[str] = ['<?xml version="1.0" encoding="utf-8"?>']
        parts.append(f'<package xmlns="{NS_OPF}" version="2.0" unique-identifier="BookId">')

        parts.append(f'  <metadata xmlns:dc="{NS_DC}" xmlns:opf="{NS_OPF}">')
        parts.append(f"    <dc:title>{html_escape(book.title)}</dc:title>")
        for creator in book.creators:
            parts.append(f'    <dc:creator opf:role="aut">{html_escape(creator)}</dc:creator>')
        parts.append(f"    <dc:language>{html_escape(book.language)}</dc:language>")
        parts.append(f'    <dc:identifier id="BookId">{html_escape(book.identifier)}</dc:identifier>')
        if book.date:
            parts.append(f"    <dc:date>{html_escape(book.date)}</dc:date>")
        if book.description:
            parts.append(f"    <dc:description>{html_escape(book.description)}</dc:description>")
        for subject in book.subjects:
            parts.append(f"    <dc:subject>{html_escape(subject)}</dc:subject>")
        if book.cover_id:
            parts.append(f'    <meta name="cover" content="{book.cover_id}"/>')
        parts.append("  </metadata>")

        parts.append("  <manifest>")
        parts.append('    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>')
        parts.append('    <item id="css" href="style.css" media-type="text/css"/>')
        for doc in book.documents:
            parts.append(f'    <item id="{doc.id}" href="{doc.href}" media-type="application/xhtml+xml"/>')
        for resource in book.resources:
            parts.append(f'    <item id="{resource.id}" href="{resource.href}" media-type="{resource.media_type}"/>')
        parts.append("  </manifest>")

        parts.append('  <spine toc="ncx">')
        for doc in book.documents:
            parts.append(f'    <itemref idref="{doc.id}"/>')
        parts.append("  </spine>")

        if book.cover_id:
            parts.append("  <guide>")
            parts.append('    <reference type="cover" title="Cover" href="cover.xhtml"/>')
            parts.append("  </guide>")

        parts.append("</package>")
        return "\n".join(parts) + "\n"

    def _ncx(self, book: EpubBook) -> str:
        """Собрать NCX-оглавление (toc.ncx)."""
        parts: List[str] = ['<?xml version="1.0" encoding="utf-8"?>']
        parts.append(f'<ncx xmlns="{NS_NCX}" version="2005-1">')
        parts.append("  <head>")
        parts.append(f'    <meta name="dtb:uid" content="{html_escape(book.identifier)}"/>')
        parts.append('    <meta name="dtb:depth" content="1"/>')
        parts.append('    <meta name="dtb:totalPageCount" content="0"/>')
        parts.append('    <meta name="dtb:maxPageNumber" content="0"/>')
        parts.append("  </head>")
        parts.append(f"  <docTitle><text>{html_escape(book.title)}</text></docTitle>")
        parts.append("  <navMap>")
        for index, doc in enumerate(book.documents, 1):
            parts.append(f'    <navPoint id="navPoint-{index}" playOrder="{index}">')
            parts.append(f"      <navLabel><text>{html_escape(doc.title)}</text></navLabel>")
            parts.append(f'      <content src="{doc.href}"/>')
            parts.append("    </navPoint>")
        parts.append("  </navMap>")
        parts.append("</ncx>")
        return "\n".join(parts) + "\n"

    def _opf3(self, book: EpubBook) -> str:
        """Собрать OPF 3.0 (content.opf).

        Отличия от EPUB 2: версия пакета ``3.0``, обязательный
        ``<meta property="dcterms:modified">``, ``properties="nav"`` у
        навигационного документа и ``properties="cover-image"`` у обложки,
        роли авторов — через ``refines``.
        """
        parts: List[str] = ['<?xml version="1.0" encoding="utf-8"?>']
        parts.append(
            f'<package xmlns="{NS_OPF}" version="3.0" unique-identifier="BookId"'
            f' xml:lang="{html_escape(book.language)}">'
        )

        parts.append(f'  <metadata xmlns:dc="{NS_DC}">')
        parts.append(f"    <dc:title>{html_escape(book.title)}</dc:title>")
        for index, creator in enumerate(book.creators, 1):
            parts.append(
                f'    <dc:creator id="creator{index}">{html_escape(creator)}</dc:creator>'
            )
            parts.append(
                f'    <meta refines="#creator{index}" property="role"'
                ' scheme="marc:relators">aut</meta>'
            )
        parts.append(f"    <dc:language>{html_escape(book.language)}</dc:language>")
        parts.append(
            f'    <dc:identifier id="BookId">{html_escape(book.identifier)}</dc:identifier>'
        )
        if book.date:
            parts.append(f"    <dc:date>{html_escape(book.date)}</dc:date>")
        if book.description:
            parts.append(
                f"    <dc:description>{html_escape(book.description)}</dc:description>"
            )
        for subject in book.subjects:
            parts.append(f"    <dc:subject>{html_escape(subject)}</dc:subject>")
        parts.append(
            f'    <meta property="dcterms:modified">{self._modified_timestamp()}</meta>'
        )
        if book.cover_id:
            # Устаревшая, но совместимая подсказка об обложке.
            parts.append(f'    <meta name="cover" content="{book.cover_id}"/>')
        parts.append("  </metadata>")

        parts.append("  <manifest>")
        parts.append(
            '    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml"'
            ' properties="nav"/>'
        )
        parts.append(
            '    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>'
        )
        parts.append('    <item id="css" href="style.css" media-type="text/css"/>')
        for doc in book.documents:
            parts.append(
                f'    <item id="{doc.id}" href="{doc.href}"'
                ' media-type="application/xhtml+xml"/>'
            )
        for resource in book.resources:
            properties = (
                ' properties="cover-image"' if resource.id == book.cover_id else ""
            )
            parts.append(
                f'    <item id="{resource.id}" href="{resource.href}"'
                f' media-type="{resource.media_type}"{properties}/>'
            )
        parts.append("  </manifest>")

        parts.append('  <spine toc="ncx">')
        for doc in book.documents:
            parts.append(f'    <itemref idref="{doc.id}"/>')
        parts.append("  </spine>")

        parts.append("</package>")
        return "\n".join(parts) + "\n"

    def _nav_xhtml(self, book: EpubBook) -> str:
        """Собрать XHTML Navigation Document (``nav.xhtml``) для EPUB 3.

        Содержит ``<nav epub:type="toc">`` со ссылками на все документы
        (кроме обложки) и ``<nav epub:type="landmarks">`` с ориентирами.
        """
        toc_docs = [doc for doc in book.documents if doc.id != "cover"]
        toc_items = "\n".join(
            f'      <li><a href="{html_escape(doc.href, quote=True)}">'
            f"{html_escape(doc.title)}</a></li>"
            for doc in toc_docs
        )

        landmarks: List[str] = []
        for doc in book.documents:
            if doc.id == "cover":
                landmarks.append(
                    '      <li><a epub:type="cover"'
                    f' href="{html_escape(doc.href, quote=True)}">Обложка</a></li>'
                )
        body_doc = next((doc for doc in toc_docs), None)
        if body_doc is not None:
            landmarks.append(
                '      <li><a epub:type="bodymatter"'
                f' href="{html_escape(body_doc.href, quote=True)}">Начало</a></li>'
            )

        landmarks_block = ""
        if landmarks:
            inner = "\n".join(landmarks)
            landmarks_block = (
                '\n  <nav epub:type="landmarks" hidden="hidden">\n'
                "    <h2>Ориентиры</h2>\n"
                "    <ol>\n"
                f"{inner}\n"
                "    </ol>\n"
                "  </nav>"
            )

        language = html_escape(book.language)
        return (
            '<?xml version="1.0" encoding="utf-8"?>\n'
            "<!DOCTYPE html>\n"
            f'<html xmlns="{NS_XHTML}" xmlns:epub="{NS_EPUB}"'
            f' xml:lang="{language}" lang="{language}">\n'
            "<head>\n"
            f"  <title>{html_escape(self.toc_title)}</title>\n"
            '  <meta charset="utf-8"/>\n'
            '  <link rel="stylesheet" type="text/css" href="style.css"/>\n'
            "</head>\n"
            "<body>\n"
            '  <nav epub:type="toc" id="toc">\n'
            f"    <h1>{html_escape(self.toc_title)}</h1>\n"
            "    <ol>\n"
            f"{toc_items}\n"
            "    </ol>\n"
            "  </nav>"
            f"{landmarks_block}\n"
            "</body>\n"
            "</html>\n"
        )

    @staticmethod
    def _modified_timestamp() -> str:
        """Текущая метка времени UTC в формате, требуемом EPUB 3."""
        return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


__all__ = ["Fb2ToEpubConverter", "EpubBook", "EpubDocument", "EpubResource"]


def main(argv: List[str] | None = None) -> int:
    if argv is None:
        argv = sys.argv
    args = argv[1:]
    epub3 = "--epub3" in args
    positional = [a for a in args if not a.startswith("-")]
    if not positional:
        print(
            "Использование: python fb2_to_epub.py <файл.fb2> [выход.epub] [--epub3]",
            file=sys.stderr,
        )
        return 2
    source = positional[0]
    output = (
        positional[1]
        if len(positional) > 1
        else str(Path(source).with_suffix(".epub"))
    )
    converter = Fb2ToEpubConverter(epub_version=3 if epub3 else 2)
    path = converter.write(source, output)
    print("EPUB:", path, "(3.0)" if epub3 else "(2.0)")
    if converter.book is not None:
        print("Документов:", len(converter.book.documents))
        print("Изображений:", len(converter.book.resources))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))







