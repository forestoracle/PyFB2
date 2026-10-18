# -*- coding: utf-8 -*-
"""Преобразование MOBI (Mobipocket/Kindle KF7) в книгу FB2.

Модуль разбирает базу данных Palm (PDB): заголовки PalmDOC/MOBI/EXTH,
распаковывает текст (PalmDOC LZ77) и изображения, преобразует HTML-разметку
в структуры FB2 (через :class:`~html_to_fb2.HtmlToFb2Converter`).

Поддерживаются файлы без DRM с компрессией ``1`` (без сжатия) и ``2``
(PalmDOC). HUFF/CDIC-компрессия не поддерживается.

Обратное преобразование к :mod:`fb2_to_mobi`. Внешних зависимостей нет.

Пример:
    >>> from mobi_to_fb2 import MobiToFb2Converter
    >>> MobiToFb2Converter().write("book.mobi", "book.fb2")
    WindowsPath('book.fb2')

CLI:
    python mobi_to_fb2.py book.mobi [book.fb2]
"""

from __future__ import annotations

import base64
import re
import struct
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Union

from .fb2_errors import Fb2ConversionError
from .fb2_images import detect_image_type
from .fb2_structures import (
    Author,
    Binary,
    CoverPage,
    FictionBook,
    Genre,
    InlineImage,
    TextField,
)
from .fb2_writer import Fb2Writer
from .html_to_fb2 import HtmlToFb2Converter

#: Компрессия текста.
COMPRESSION_NONE = 1
COMPRESSION_PALMDOC = 2
COMPRESSION_HUFFCDIC = 17480

#: Смещения в MOBI-заголовке (от начала блока «MOBI»).
MOBI_FIRST_IMAGE = 0x5C
MOBI_FULL_NAME_OFFSET = 0x44
MOBI_FULL_NAME_LENGTH = 0x48
MOBI_EXTH_FLAGS = 0x70
MOBI_HEADER_LENGTH_FIELD = 0x04

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

#: Шаблон ссылки на изображение в HTML MOBI.
RECINDEX_RE = re.compile(r'(<img[^>]*\brecindex="0*(\d+)"[^>]*/?>)', re.IGNORECASE)
RECINDEX_ATTR_RE = re.compile(r'\brecindex="0*\d+"', re.IGNORECASE)


def palmdoc_decompress(data: bytes) -> bytes:
    """Распаковать блок данных, сжатый алгоритмом PalmDOC (LZ77).

    :param data: сжатые байты.
    :return: распакованные байты.
    """
    out = bytearray()
    index = 0
    size = len(data)
    while index < size:
        value = data[index]
        index += 1
        if value == 0 or 0x09 <= value <= 0x7F:
            out.append(value)
        elif 0x01 <= value <= 0x08:
            out.extend(data[index:index + value])
            index += value
        elif 0x80 <= value <= 0xBF:
            if index >= size:
                break
            pair = ((value & 0x3F) << 8) | data[index]
            index += 1
            length = (pair & 0x07) + 3
            distance = (pair >> 3) & 0x7FF
            if distance == 0:
                break
            start = len(out) - distance
            if start < 0:
                break
            for offset in range(length):
                out.append(out[start + offset])
        else:
            out.append(0x20)
            out.append(value ^ 0x80)
    return bytes(out)


@dataclass
class MobiHeader:
    """Разобранные заголовки записи 0."""

    compression: int = COMPRESSION_NONE
    text_length: int = 0
    text_records: int = 0
    first_image_index: int = 0
    full_name_offset: int = 0
    full_name_length: int = 0
    title: str = ""
    exth: Dict[int, List[bytes]] = field(default_factory=dict)

    def first(self, kind: int) -> Optional[bytes]:
        """Первое значение EXTH-записи указанного типа."""
        values = self.exth.get(kind)
        return values[0] if values else None

    def texts(self, kind: int) -> List[str]:
        """Все значения EXTH-записи как строки UTF-8."""
        return [
            value.decode("utf-8", "replace")
            for value in self.exth.get(kind, [])
        ]


class MobiToFb2Converter:
    """Преобразование MOBI в FB2.

    :param writer: готовый :class:`~fb2_writer.Fb2Writer`.
    :param default_genre: жанр, если в MOBI он не указан.
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

    # --- Публичный API -----------------------------------------------------
    @property
    def book(self) -> Optional[FictionBook]:
        """Последняя собранная структура :class:`FictionBook` (или None)."""
        return self._book

    def convert(
        self, source: Optional[Union[str, Path, bytes]] = None
    ) -> FictionBook:
        """Прочитать MOBI и вернуть структуру :class:`FictionBook`.

        :param source: путь или байты MOBI (иначе берётся ``self.source``).
        """
        if source is not None:
            self.source = source
        if self.source is None:
            raise Fb2ConversionError("Не задан источник MOBI (source)")

        data = self._read_source(self.source)
        records = self._split_records(data)
        if not records:
            raise Fb2ConversionError("Файл MOBI не содержит записей")
        header = self._parse_record_zero(records[0])
        html = self._read_text(records, header)
        images = self._read_images(records, header)
        html = self._inline_images(html, images)

        converter = HtmlToFb2Converter(
            default_genre=self.default_genre,
            program_used=self.program_used,
        )
        book = converter.convert(html)
        self._apply_metadata(book, header, images)
        self._book = book
        return book

    def to_xml(self, book=None) -> str:
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
        """Преобразовать MOBI в файл FB2 и вернуть путь к результату.

        :param source: путь/байты MOBI (иначе ``self.source``).
        :param output: путь к ``.fb2``; по умолчанию — рядом с исходным ``.mobi``.
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

    # --- Чтение PDB --------------------------------------------------------
    @staticmethod
    def _read_source(source: Union[str, Path, bytes]) -> bytes:
        """Прочитать файл MOBI (путь или байты)."""
        if isinstance(source, bytes):
            return source
        return Path(source).read_bytes()

    @staticmethod
    def _split_records(data: bytes) -> List[bytes]:
        """Разбить базу данных Palm на записи по списку смещений."""
        if len(data) < 78:
            raise Fb2ConversionError("Файл слишком короткий для базы данных Palm")
        count = struct.unpack_from(">H", data, 76)[0]
        if count == 0:
            return []
        offsets = [
            struct.unpack_from(">I", data, 78 + 8 * index)[0]
            for index in range(count)
        ]
        offsets.append(len(data))
        records: List[bytes] = []
        for index in range(count):
            start, end = offsets[index], offsets[index + 1]
            if start > len(data) or end > len(data) or start > end:
                raise Fb2ConversionError("Повреждён список записей PDB")
            records.append(data[start:end])
        return records

    def _parse_record_zero(self, record: bytes) -> MobiHeader:
        """Разобрать запись 0: заголовки PalmDOC, MOBI и EXTH."""
        if len(record) < 24:
            raise Fb2ConversionError("Запись 0 слишком короткая")
        compression, _unused, text_length, text_records = struct.unpack_from(
            ">HHIH", record, 0
        )
        header = MobiHeader(
            compression=compression,
            text_length=text_length,
            text_records=text_records,
        )
        if record[16:20] != b"MOBI":
            return header  # чистый PalmDOC без MOBI-заголовка

        mobi_length = struct.unpack_from(
            ">I", record, 16 + MOBI_HEADER_LENGTH_FIELD
        )[0]
        mobi_end = 16 + mobi_length
        header.first_image_index = struct.unpack_from(
            ">I", record, 16 + MOBI_FIRST_IMAGE
        )[0]
        header.full_name_offset = struct.unpack_from(
            ">I", record, 16 + MOBI_FULL_NAME_OFFSET
        )[0]
        header.full_name_length = struct.unpack_from(
            ">I", record, 16 + MOBI_FULL_NAME_LENGTH
        )[0]
        exth_flags = struct.unpack_from(">I", record, 16 + MOBI_EXTH_FLAGS)[0]
        if exth_flags & 0x40 and record[mobi_end:mobi_end + 4] == b"EXTH":
            self._parse_exth(record, mobi_end, header)

        if header.full_name_offset and header.full_name_length:
            start = header.full_name_offset
            raw_title = record[start:start + header.full_name_length]
            header.title = raw_title.decode("utf-8", "replace")
        return header

    @staticmethod
    def _parse_exth(record: bytes, start: int, header: MobiHeader) -> None:
        """Разобрать EXTH-записи (метаданные MOBI)."""
        length, count = struct.unpack_from(">II", record, start + 4)
        position = start + 12
        end = min(start + length, len(record))
        for _ in range(count):
            if position + 8 > end:
                break
            kind, size = struct.unpack_from(">II", record, position)
            if size < 8:
                break
            header.exth.setdefault(kind, []).append(
                record[position + 8:position + size]
            )
            position += size

    def _read_text(self, records: List[bytes], header: MobiHeader) -> str:
        """Склеить текстовые записи и распаковать их."""
        if header.compression == COMPRESSION_HUFFCDIC:
            raise Fb2ConversionError("HUFF/CDIC-компрессия не поддерживается")
        count = header.text_records or max(0, len(records) - 1)
        parts: List[bytes] = []
        for record in records[1:1 + count]:
            if header.compression == COMPRESSION_PALMDOC:
                parts.append(palmdoc_decompress(record))
            else:
                parts.append(record)
        text = b"".join(parts)
        if header.text_length:
            text = text[:header.text_length]
        return text.decode("utf-8", "replace")

    @staticmethod
    def _read_images(records: List[bytes], header: MobiHeader) -> List[bytes]:
        """Записи изображений (от ``first_image_index`` до конца)."""
        start = header.first_image_index
        if not start or start >= len(records):
            return []
        service = (b"FLIS", b"FCIS", b"INDX", b"SRCS", b"CMET", b"FDST", b"EOF ")
        return [
            record
            for record in records[start:]
            if record and not record.startswith(service)
        ]

    def _inline_images(self, html: str, images: List[bytes]) -> str:
        """Заменить ``recindex`` на data URI с изображением."""

        def replace(match: "re.Match[str]") -> str:
            tag = match.group(1)
            number = int(match.group(2))
            if not 1 <= number <= len(images):
                return tag
            data = images[number - 1]
            media_type, _extension = detect_image_type(data)
            encoded = base64.b64encode(data).decode("ascii")
            cleaned = RECINDEX_ATTR_RE.sub("", tag)
            return cleaned.replace(
                "<img", f'<img src="data:{media_type};base64,{encoded}"', 1
            )

        return RECINDEX_RE.sub(replace, html)

    # --- Метаданные --------------------------------------------------------
    def _apply_metadata(
        self, book, header: MobiHeader, images: List[bytes]
    ) -> None:
        """Дополнить метаданные FB2 данными из EXTH."""
        title_info = book.description.title_info
        if header.title:
            title_info.book_title = TextField(value=header.title)

        authors = [
            self._split_author(name) for name in header.texts(EXTH_AUTHOR)
        ]
        if authors:
            title_info.authors = authors

        genres = [
            genre.strip()
            for genre in header.texts(EXTH_SUBJECT)
            if genre.strip() and " " not in genre.strip()
        ]
        if genres:
            title_info.genres = [Genre(value=genre) for genre in genres]

        language = header.first(EXTH_LANGUAGE)
        if language:
            code = language.decode("utf-8", "replace").strip()
            if code:
                title_info.lang = code.split("-")[0].lower()

        self._apply_cover(book, header, images)

    @staticmethod
    def _apply_cover(book, header: MobiHeader, images: List[bytes]) -> None:
        """Добавить обложку по EXTH-записи ``coveroffset``."""
        raw = header.first(EXTH_COVER_OFFSET)
        if raw is None or len(raw) < 4:
            return
        index = struct.unpack(">I", raw[:4])[0]
        if not 0 <= index < len(images):
            return
        data = images[index]
        media_type, extension = detect_image_type(data)
        binary_id = f"cover{extension}"
        if not any(binary.id == binary_id for binary in book.binaries):
            book.binaries.append(
                Binary(
                    id=binary_id,
                    content_type=media_type,
                    data=base64.b64encode(data).decode("ascii"),
                )
            )
        book.description.title_info.coverpage = CoverPage(
            images=[InlineImage(href=f"#{binary_id}")]
        )

    @staticmethod
    def _split_author(name: str) -> Author:
        """Разбить строку автора на first/middle/last."""
        name = name.strip()
        if "," in name:
            last, _, first = name.partition(",")
            return Author(last_name=last.strip(), first_name=first.strip() or None)
        parts = name.split()
        if not parts:
            return Author(nickname="Неизвестный автор")
        if len(parts) == 1:
            return Author(last_name=parts[0])
        if len(parts) == 2:
            return Author(first_name=parts[0], last_name=parts[1])
        return Author(
            first_name=parts[0],
            middle_name=" ".join(parts[1:-1]),
            last_name=parts[-1],
        )


__all__ = ["MobiToFb2Converter", "MobiHeader", "palmdoc_decompress"]


def main(argv: List[str] | None = None) -> int:
    if argv is None:
        argv = sys.argv
    if len(argv) < 2:
        print(
            "Использование: python mobi_to_fb2.py <файл.mobi> [выход.fb2]",
            file=sys.stderr,
        )
        return 2
    source = argv[1]
    output = argv[2] if len(argv) > 2 else str(Path(source).with_suffix(".fb2"))
    converter = MobiToFb2Converter()
    path = converter.write(source, output)
    print("FB2:", path)
    if converter.book is not None:
        print("Изображений:", len(converter.book.binaries))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
