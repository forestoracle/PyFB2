# -*- coding: utf-8 -*-
"""Преобразование книги FB2 в MOBI (Mobipocket/Kindle KF7).

Модуль собирает файл MOBI из структур :class:`~fb2_structures.FictionBook`:

* текст размечается простым HTML (Mobi7) и сжимается алгоритмом PalmDOC;
* файл упаковывается в базу данных Palm (PDB): запись 0 — заголовки PalmDOC,
  MOBI и EXTH (метаданные), далее текстовые записи, затем изображения;
* обложка помечается через EXTH-записи ``coveroffset``/``thumboffset``.

Внешних зависимостей нет. Обратное преобразование — :mod:`mobi_to_fb2`.

Пример:
    >>> from fb2_to_mobi import Fb2ToMobiConverter
    >>> Fb2ToMobiConverter().write("book.fb2", "book.mobi")
    WindowsPath('book.mobi')

CLI:
    python fb2_to_mobi.py book.fb2 [book.mobi]
"""

from __future__ import annotations

import base64
import random
import struct
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Tuple, Union
from html import escape as html_escape

from .fb2_errors import Fb2ConversionError
from .fb2_images import detect_image_type
from .fb2_parser import TEXT_NODE, Fb2Parser
from .fb2_structures import (
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

#: Размер текстового блока PalmDOC/MOBI.
TEXT_RECORD_SIZE = 4096

#: Максимальный размер записи PDB (картинки больше не помещаются).
MAX_RECORD_SIZE = 65536

#: Компрессия: 1 — без сжатия, 2 — PalmDOC.
COMPRESSION_NONE = 1
COMPRESSION_PALMDOC = 2

#: Длина MOBI-заголовка (версия 6).
MOBI_HEADER_LENGTH = 232

#: Кодировка текста MOBI (UTF-8).
ENCODING_UTF8 = 65001

#: Значения EXTH-записей.
EXTH_AUTHOR = 100
EXTH_PUBLISHER = 101
EXTH_DESCRIPTION = 103
EXTH_SUBJECT = 105
EXTH_PUBLISHING_DATE = 106
EXTH_COVER_OFFSET = 201
EXTH_THUMB_OFFSET = 202
EXTH_CDE_TYPE = 503
EXTH_LANGUAGE = 524

#: LCID (Microsoft) для распространённых языков.
LOCALE_BY_LANGUAGE = {
    "ru": 1049,
    "en": 1033,
    "uk": 1058,
    "de": 1031,
    "fr": 1036,
    "es": 1034,
}

#: Inline-теги разметки FB2 -> HTML.
MARKUP_TAGS = {
    "strong": "b",
    "emphasis": "i",
    "code": "tt",
    "strikethrough": "s",
    "sub": "sub",
    "sup": "sup",
}


def palmdoc_compress(data: bytes) -> bytes:
    """Сжать блок данных (до 4096 байт) алгоритмом PalmDOC (LZ77).

    :param data: несжатые байты блока.
    :return: сжатые байты (могут быть длиннее исходных — тогда вызывающий
        код должен записать блок без сжатия).
    """
    out = bytearray()
    literals = bytearray()
    size = len(data)
    index = 0

    def flush() -> None:
        """Записать накопленные литералы."""
        while literals:
            chunk = bytes(literals[:8])
            del literals[:8]
            if len(chunk) == 1 and (chunk[0] == 0 or 0x09 <= chunk[0] <= 0x7F):
                out.append(chunk[0])
            else:
                out.append(len(chunk))
                out.extend(chunk)

    while index < size:
        # Пробел + символ 0x40..0x7F кодируются одним байтом.
        if (
            data[index] == 0x20
            and index + 1 < size
            and 0x40 <= data[index + 1] <= 0x7F
        ):
            flush()
            out.append(data[index + 1] ^ 0x80)
            index += 2
            continue

        best_length = 0
        best_distance = 0
        start = max(0, index - 2047)
        for candidate in range(start, index):
            length = 0
            while (
                length < 10
                and index + length < size
                and data[candidate + length] == data[index + length]
            ):
                length += 1
            if length > best_length:
                best_length = length
                best_distance = index - candidate
                if best_length == 10:
                    break

        if best_length >= 3:
            flush()
            value = ((best_distance << 3) | (best_length - 3)) & 0x3FFF
            out.append(0x80 | (value >> 8))
            out.append(value & 0xFF)
            index += best_length
            continue

        literals.append(data[index])
        index += 1
        if len(literals) == 8:
            flush()

    flush()
    return bytes(out)


@dataclass
class MobiImage:
    """Изображение, встраиваемое в MOBI."""

    filename: str
    media_type: str
    data: bytes


@dataclass
class MobiBook:
    """Промежуточное представление документа MOBI."""

    title: str = "Untitled"
    authors: List[str] = field(default_factory=list)
    language: str = "ru"
    description: str = ""
    genres: List[str] = field(default_factory=list)
    html: str = ""
    images: List[MobiImage] = field(default_factory=list)
    cover_index: Optional[int] = None


class Fb2ToMobiConverter:
    """Преобразование книги FB2 в MOBI.

    :param parser: готовый :class:`~fb2_parser.Fb2Parser` (иначе создаётся новый).
    :param compress: использовать PalmDOC-сжатие (по умолчанию — да).
    """

    def __init__(
        self,
        parser: Optional[Fb2Parser] = None,
        compress: bool = True,
    ) -> None:
        self.parser = parser if parser is not None else Fb2Parser()
        self.compress = compress
        self.source: Optional[Union[str, Path]] = None
        self._book: Optional[MobiBook] = None
        self._reset()

    def _reset(self) -> None:
        """Очистить состояние для нового преобразования."""
        self._images: List[MobiImage] = []
        self._image_index: Dict[str, int] = {}

    # --- Публичный API -----------------------------------------------------
    @property
    def book(self) -> Optional[MobiBook]:
        """Последняя собранная структура :class:`MobiBook` (или None)."""
        return self._book

    def convert(self, source: Optional[Union[str, Path]] = None) -> MobiBook:
        """Прочитать FB2 и вернуть структуру :class:`MobiBook`.

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
        self._collect_images(binaries)

        title = self._book_title(title_info)
        authors = self._creators(title_info)
        description_text = self._annotation_text(title_info)
        html = self._render_html(bodies)

        self._book = MobiBook(
            title=title,
            authors=authors,
            language=self._language(title_info),
            description=description_text,
            genres=self._genres(title_info),
            html=html,
            images=self._images,
            cover_index=self._cover_index(title_info),
        )
        return self._book

    def to_bytes(self, book: Optional[MobiBook] = None) -> bytes:
        """Сериализовать книгу (или результат :meth:`convert`) в MOBI.

        :param book: готовая структура; если не задана, используется результат
            последнего вызова :meth:`convert`.
        """
        if book is None:
            book = self._book
        if book is None:
            raise Fb2ConversionError("Нет книги для сериализации: вызовите convert()")

        text = book.html.encode("utf-8")
        text_records, compression = self._text_records(text)
        image_records = [image.data for image in book.images]

        first_image_index = 1 + len(text_records)
        record_zero = self._record_zero(
            book=book,
            compression=compression,
            text_length=len(text),
            text_records=len(text_records),
            first_image_index=first_image_index,
        )
        records = [record_zero, *text_records, *image_records]
        return self._palm_database(book.title, records)

    def write(
        self,
        source: Optional[Union[str, Path]] = None,
        output: Optional[Union[str, Path]] = None,
    ) -> Path:
        """Преобразовать FB2 в файл MOBI и вернуть путь к результату.

        :param source: путь к FB2 (иначе ``self.source``).
        :param output: путь к ``.mobi``; по умолчанию — рядом с исходным ``.fb2``.
        """
        book = self.convert(source)
        data = self.to_bytes(book)

        if output is None:
            src = source if source is not None else self.source
            output = (
                Path(src).with_suffix(".mobi")
                if isinstance(src, (str, Path))
                else Path("book.mobi")
            )
        output = Path(output)
        output.write_bytes(data)
        return output

    # --- Метаданные --------------------------------------------------------
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
    def _genres(title_info) -> List[str]:
        """Жанры книги."""
        if title_info is None:
            return []
        return [genre.value for genre in title_info.genres if genre.value]

    @staticmethod
    def _markup_text(nodes: List[StyleNode]) -> str:
        """Собрать простой текст из узлов разметки."""
        parts: List[str] = []
        for node in nodes:
            if node.tag == TEXT_NODE:
                parts.append(node.text or "")
            else:
                parts.append(Fb2ToMobiConverter._markup_text(node.children))
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
        """Отобрать изображения, помещающиеся в одну запись PDB."""
        for binary in binaries:
            if binary.content_type and binary.content_type.startswith("image/svg"):
                continue
            try:
                data = base64.b64decode(binary.data or "")
            except (ValueError, TypeError):  # pragma: no cover - битые данные
                continue
            if not data or len(data) > MAX_RECORD_SIZE:
                continue
            media_type, _extension = detect_image_type(data)
            identifier = (binary.id or "image").lstrip("#")
            self._image_index[identifier] = len(self._images)
            self._images.append(
                MobiImage(
                    filename=identifier,
                    media_type=media_type,
                    data=data,
                )
            )

    def _image_number(self, href: Optional[str]) -> Optional[int]:
        """Номер картинки (1-based) для атрибута ``recindex``."""
        if not href:
            return None
        index = self._image_index.get(href.lstrip("#"))
        return None if index is None else index + 1

    def _cover_index(self, title_info) -> Optional[int]:
        """Индекс обложки среди записей изображений (0-based)."""
        if title_info is None or title_info.coverpage is None:
            return None
        for image in title_info.coverpage.images:
            number = self._image_number(image.href)
            if number is not None:
                return number - 1
        return None

    # --- HTML (Mobi7) ------------------------------------------------------
    def _render_html(self, bodies: List[Body]) -> str:
        """Собрать HTML-текст книги (профиль Mobi7).

        Название, авторы и аннотация попадают в метаданные MOBI (EXTH), а не
        в текст — так структура секций не искажается при обратной конвертации.
        """
        parts = [
            "<html><head><guide>",
            '<reference type="toc" title="Оглавление" filepos="0000000000"/>',
            "</guide></head><body>",
        ]
        for body in bodies:
            parts.append(self._render_body(body))
        parts.append("</body></html>")
        return "\n".join(part for part in parts if part)

    def _render_body(self, body: Body) -> str:
        """Отрендерить тело книги."""
        parts: List[str] = []
        if body.image is not None:
            parts.append(self._image_tag(body.image))
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
            parts.append(self._image_tag(section.image))
        for block in section.content:
            parts.append(self._render_block(block))
        for child in section.sections:
            parts.append(self._render_section(child, level + 1))
        return "\n".join(part for part in parts if part)

    def _render_title(self, title: Title, level: int) -> str:
        """Заголовок секции (``h1``..``h6``)."""
        tag = f"h{max(1, min(level, 6))}"
        parts: List[str] = []
        for item in title.items:
            if isinstance(item, Paragraph):
                text = self._render_markup(item.content)
                if text:
                    parts.append(text)
        if not parts:
            return ""
        return f"<{tag}>{' '.join(parts)}</{tag}>"

    def _render_epigraph(self, epigraph: Epigraph) -> str:
        """Эпиграф: абзацы в ``blockquote``."""
        parts: List[str] = []
        for item in epigraph.items:
            rendered = self._render_block(item)
            if rendered:
                parts.append(rendered)
        for author in epigraph.text_author:
            parts.append(f"<p><i>{self._render_markup(author.content)}</i></p>")
        inner = "\n".join(part for part in parts if part)
        return f"<blockquote>{inner}</blockquote>" if inner else ""

    def _render_block(self, block) -> str:
        """Отрендерить блочный элемент контента."""
        if isinstance(block, Paragraph):
            return self._paragraph(block.content)
        if isinstance(block, Subtitle):
            return f"<p><b>{self._render_markup(block.content)}</b></p>"
        if isinstance(block, EmptyLine):
            return "<p>&#160;</p>"
        if isinstance(block, Poem):
            return self._render_poem(block)
        if isinstance(block, Cite):
            return self._render_cite(block)
        if isinstance(block, Table):
            return self._render_table(block)
        if isinstance(block, Image):
            return self._image_tag(block)
        if isinstance(block, Epigraph):
            return self._render_epigraph(block)
        return ""

    def _paragraph(self, nodes: List[StyleNode]) -> str:
        """Абзац ``<p>`` с inline-разметкой."""
        content = self._render_markup(nodes)
        return f"<p>{content}</p>" if content else ""

    def _render_poem(self, poem: Poem) -> str:
        """Стихотворение: строки абзацами."""
        parts: List[str] = []
        if poem.title is not None:
            parts.append(self._render_title(poem.title, 3))
        for item in poem.items:
            if isinstance(item, Stanza):
                parts.append(self._render_stanza(item))
            elif isinstance(item, Subtitle):
                parts.append(f"<p><b>{self._render_markup(item.content)}</b></p>")
        for author in poem.text_author:
            parts.append(f"<p><i>{self._render_markup(author.content)}</i></p>")
        inner = "\n".join(part for part in parts if part)
        return f"<blockquote>{inner}</blockquote>" if inner else ""

    def _render_stanza(self, stanza: Stanza) -> str:
        """Строфа: строки абзацами."""
        parts: List[str] = []
        if stanza.subtitle is not None:
            parts.append(f"<p><b>{self._render_markup(stanza.subtitle.content)}</b></p>")
        for verse in stanza.verses:
            parts.append(self._paragraph(verse.content))
        return "\n".join(part for part in parts if part)

    def _render_cite(self, cite: Cite) -> str:
        """Цитата: ``blockquote``."""
        parts: List[str] = []
        for item in cite.items:
            rendered = self._render_block(item)
            if rendered:
                parts.append(rendered)
        for author in cite.text_author:
            parts.append(f"<p><i>{self._render_markup(author.content)}</i></p>")
        inner = "\n".join(part for part in parts if part)
        return f"<blockquote>{inner}</blockquote>" if inner else ""

    def _render_table(self, table: Table) -> str:
        """Таблица: ``table/tr/th|td``."""
        rows: List[str] = []
        for row in table.rows:
            cells: List[str] = []
            for cell in row.cells:
                tag = "th" if cell.is_header else "td"
                content = self._render_markup(cell.children)
                cells.append(f"<{tag}>{content}</{tag}>")
            rows.append(f"<tr>{''.join(cells)}</tr>")
        return f"<table>{''.join(rows)}</table>" if rows else ""

    # --- Разметка ----------------------------------------------------------
    def _render_markup(self, nodes: List[StyleNode]) -> str:
        """Отрендерить inline-разметку в HTML."""
        parts: List[str] = []
        for node in nodes:
            if node.tag == TEXT_NODE:
                parts.append(html_escape(node.text or ""))
            elif node.tag == "a":
                parts.append(self._link(node))
            elif node.tag == "image":
                parts.append(self._image_tag_inline(node))
            elif node.tag in MARKUP_TAGS:
                tag = MARKUP_TAGS[node.tag]
                parts.append(f"<{tag}>{self._render_markup(node.children)}</{tag}>")
            else:
                parts.append(self._render_markup(node.children))
        return "".join(parts)

    def _link(self, node: StyleNode) -> str:
        """Ссылка ``<a href="...">``."""
        inner = self._render_markup(node.children)
        href = node.href or ""
        if not href:
            return inner
        return f'<a href="{html_escape(href, quote=True)}">{inner}</a>'

    def _image_tag_inline(self, node: StyleNode) -> str:
        """Inline-картинка: ``<img recindex="..."/>``."""
        number = self._image_number(node.image_href or node.href)
        if number is None:
            return ""
        return f'<img recindex="{number:05d}"/>'

    def _image_tag(self, image: Image) -> str:
        """Блочная картинка: ``<p><img recindex="..."/></p>``."""
        number = self._image_number(image.href)
        if number is None:
            return ""
        return f'<p><img recindex="{number:05d}"/></p>'

    # --- Контейнер PDB/MOBI ------------------------------------------------
    def _text_records(self, text: bytes) -> Tuple[List[bytes], int]:
        """Разбить текст на записи; вернуть записи и тип сжатия."""
        plain = [
            text[start:start + TEXT_RECORD_SIZE]
            for start in range(0, len(text), TEXT_RECORD_SIZE)
        ] or [b""]
        if not self.compress:
            return plain, COMPRESSION_NONE

        compressed: List[bytes] = []
        for block in plain:
            packed = palmdoc_compress(block)
            if len(packed) > TEXT_RECORD_SIZE:
                return plain, COMPRESSION_NONE
            compressed.append(packed)
        return compressed, COMPRESSION_PALMDOC

    def _record_zero(
        self,
        book: MobiBook,
        compression: int,
        text_length: int,
        text_records: int,
        first_image_index: int,
    ) -> bytes:
        """Собрать запись 0: заголовки PalmDOC, MOBI, EXTH и название."""
        exth = self._exth(book)
        title = book.title.encode("utf-8")

        mobi = bytearray(MOBI_HEADER_LENGTH)
        struct.pack_into(
            ">4sIIII",
            mobi,
            0x00,
            b"MOBI",
            MOBI_HEADER_LENGTH,
            2,                     # тип: книга
            ENCODING_UTF8,
            random.randint(1, 0xFFFFFFFE),
        )
        struct.pack_into(">I", mobi, 0x14, 6)  # версия файла
        for offset in (0x18, 0x1C, 0x20, 0x24, 0x28, 0x2C, 0x30, 0x34, 0x38, 0x3C):
            struct.pack_into(">I", mobi, offset, 0xFFFFFFFF)  # индексы отсутствуют
        struct.pack_into(">I", mobi, 0x40, first_image_index)
        struct.pack_into(">I", mobi, 0x44, 16 + MOBI_HEADER_LENGTH + len(exth))
        struct.pack_into(">I", mobi, 0x48, len(title))
        struct.pack_into(
            ">I", mobi, 0x4C, LOCALE_BY_LANGUAGE.get(book.language, 1033)
        )
        struct.pack_into(">I", mobi, 0x58, 6)  # минимальная версия
        struct.pack_into(">I", mobi, 0x5C, first_image_index)
        struct.pack_into(">I", mobi, 0x60, 0xFFFFFFFF)  # Huff/CDIC отсутствует
        struct.pack_into(">I", mobi, 0x70, 0x40)        # есть EXTH
        struct.pack_into(">I", mobi, 0x94, 0xFFFFFFFF)  # DRM отсутствует
        struct.pack_into(">H", mobi, 0xAC, 1)           # первая текстовая запись
        struct.pack_into(">H", mobi, 0xAE, text_records)
        struct.pack_into(">I", mobi, 0xB4, 0xFFFFFFFF)  # FCIS отсутствует
        struct.pack_into(">I", mobi, 0xBC, 0xFFFFFFFF)  # FLIS отсутствует
        struct.pack_into(">I", mobi, 0xD4, 0xFFFFFFFF)  # INDX отсутствует

        palmdoc = struct.pack(
            ">HHIHHHH",
            compression,
            0,
            text_length,
            text_records,
            TEXT_RECORD_SIZE,
            0,                  # шифрование отсутствует
            0,
        )
        record = palmdoc + bytes(mobi) + exth + title
        return record + b"\x00" * ((4 - len(record) % 4) % 4)

    @staticmethod
    def _exth(book: MobiBook) -> bytes:
        """Собрать EXTH-заголовок с метаданными."""
        records: List[bytes] = []

        def add(kind: int, data: bytes) -> None:
            records.append(struct.pack(">II", kind, len(data) + 8) + data)

        for author in book.authors:
            add(EXTH_AUTHOR, author.encode("utf-8"))
        if book.description:
            add(EXTH_DESCRIPTION, book.description.encode("utf-8"))
        for genre in book.genres:
            add(EXTH_SUBJECT, genre.encode("utf-8"))
        add(EXTH_LANGUAGE, book.language.encode("utf-8"))
        add(EXTH_CDE_TYPE, b"EBOK")
        if book.cover_index is not None:
            offset = struct.pack(">I", book.cover_index)
            add(EXTH_COVER_OFFSET, offset)
            add(EXTH_THUMB_OFFSET, offset)

        body = b"".join(records)
        length = len(body) + 12
        header = struct.pack(">4sII", b"EXTH", length, len(records))
        return header + body + b"\x00" * ((4 - length % 4) % 4)

    @staticmethod
    def _palm_database(name: str, records: List[bytes]) -> bytes:
        """Собрать базу данных Palm (PDB) из записей."""
        header = bytearray(78)
        raw_name = name.encode("utf-8", "replace")[:31]
        header[0:len(raw_name)] = raw_name
        stamp = int(time.time()) + 2082844800  # эпоха Palm (1904)
        struct.pack_into(">III", header, 36, stamp, stamp, 0)
        header[60:64] = b"BOOK"
        header[64:68] = b"MOBI"
        struct.pack_into(">H", header, 76, len(records))

        offset = 78 + 8 * len(records) + 2
        entries = bytearray()
        payload = bytearray()
        for index, record in enumerate(records):
            entries += struct.pack(">IBBH", offset, 0, 0, index)
            payload += record
            offset += len(record)
            padding = (4 - len(record) % 4) % 4
            payload += b"\x00" * padding
            offset += padding
        return bytes(header) + bytes(entries) + b"\x00\x00" + bytes(payload)


__all__ = ["Fb2ToMobiConverter", "MobiBook", "MobiImage", "palmdoc_compress"]


def main(argv: List[str] | None = None) -> int:
    if argv is None:
        argv = sys.argv
    if len(argv) < 2:
        print(
            "Использование: python fb2_to_mobi.py <файл.fb2> [выход.mobi]",
            file=sys.stderr,
        )
        return 2
    source = argv[1]
    output = argv[2] if len(argv) > 2 else str(Path(source).with_suffix(".mobi"))
    converter = Fb2ToMobiConverter()
    path = converter.write(source, output)
    print("MOBI:", path)
    if converter.book is not None:
        print("Изображений:", len(converter.book.images))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
