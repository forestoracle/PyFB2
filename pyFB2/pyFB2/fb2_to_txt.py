"""Экспорт FB2 в обычный текст (TXT).

Модуль предоставляет класс :class:`Fb2ToTxtConverter`, который берёт
структуры из :mod:`fb2_parser` и собирает простой текстовый документ:

    * метаданные (<description>)   -> заголовок, автор, аннотация;
    * вложенные <section>          -> заголовки (с подчёркиванием/отступом);
    * <p>                          -> абзацы (с опциональным отступом и переносом);
    * <epigraph>, <cite>           -> отступы;
    * <poem>/<stanza>/<v>          -> стихи;
    * <table>                      -> колонки через `` | ``;
    * <binary>                     -> placeholder-строка;
    * оглавление (опционально).

Пример::

    >>> from fb2_to_txt import Fb2ToTxtConverter
    >>> converter = Fb2ToTxtConverter()
    >>> converter.write("book.fb2", "book.txt")
    WindowsPath('book.txt')
    >>> text = converter.convert("book.fb2")   # строка
"""

from __future__ import annotations

import sys
import textwrap
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import List, Optional, Tuple, Union

from .fb2_parser import TEXT_NODE, Fb2Parser
from .fb2_structures import (
    Body,
    Cite,
    Description,
    EmptyLine,
    Epigraph,
    Image,
    Paragraph,
    Poem,
    Section,
    Stanza,
    Subtitle,
    Table,
    Title,
)
from .fb2_xml import parse_xml


class Fb2ToTxtConverter:
    """Преобразование разобранного FB2 в обычный текст.

    :param parser: готовый :class:`Fb2Parser` (иначе создаётся новый).
    :param heading_offset: уровень заголовка для секций верхнего уровня.
    :param max_heading_level: максимальный уровень заголовка (1..6).
    :param include_metadata: выводить ли заголовок, автора, аннотацию.
    :param include_toc: вставлять ли оглавление.
    :param toc_title: заголовок оглавления.
    :param include_annotation: выводить ли аннотацию книги.
    :param include_epigraphs: выводить ли эпиграфы.
    :param paragraph_indent: отступ абзацев (первая строка).
    :param blank_line_between_paragraphs: пустая строка между абзацами.
    :param heading_underline: подчёркивать ли заголовки (``=``/``-``).
    :param image_placeholder: текст-заглушка вместо изображения (или None).
    :param line_width: ширина переноса текста в символах (None — без переноса).
    """

    def __init__(
        self,
        parser: Optional[Fb2Parser] = None,
        heading_offset: int = 1,
        max_heading_level: int = 6,
        include_metadata: bool = True,
        include_toc: bool = False,
        toc_title: str = "Оглавление",
        include_annotation: bool = True,
        include_epigraphs: bool = True,
        paragraph_indent: str = "    ",
        blank_line_between_paragraphs: bool = True,
        heading_underline: bool = True,
        image_placeholder: Optional[str] = "[изображение]",
        line_width: Optional[int] = None,
    ) -> None:
        self.parser = parser if parser is not None else Fb2Parser()
        self.heading_offset = heading_offset
        self.max_heading_level = max_heading_level
        self.include_metadata = include_metadata
        self.include_toc = include_toc
        self.toc_title = toc_title
        self.include_annotation = include_annotation
        self.include_epigraphs = include_epigraphs
        self.paragraph_indent = paragraph_indent
        self.blank_line_between_paragraphs = blank_line_between_paragraphs
        self.heading_underline = heading_underline
        self.image_placeholder = image_placeholder
        self.line_width = line_width

        # Состояние (заполняется в _prepare).
        self.description: Optional[Description] = None
        self.bodies: List[Body] = []

    # --- Публичный API -----------------------------------------------------
    def convert(self, source) -> str:
        """Вернуть текстовое представление FB2-источника.

        :param source: путь к файлу, file-like объект или ``ET.Element``.
        """
        self._prepare(source)
        return self._build_text()

    def write(
        self, source, output: Optional[Union[str, Path]] = None, encoding: str = "utf-8"
    ) -> Path:
        """Сохранить книгу как TXT и вернуть путь к файлу."""
        text = self.convert(source)
        if output is None:
            src = source if isinstance(source, (str, Path)) else None
            output = Path(src).with_suffix(".txt") if src else Path("book.txt")
        output = Path(output)
        output.write_text(text, encoding=encoding)
        return output

    # --- Подготовка --------------------------------------------------------
    def _prepare(self, source) -> None:
        """Разобрать источник в структуры."""
        root = self._root(source)
        try:
            self.description = self.parser.parse(root)
        except ValueError:
            self.description = None
        self.bodies = self.parser.parse_bodies(root)

    @staticmethod
    def _root(source) -> ET.Element:
        """Получить корневой элемент документа."""
        if isinstance(source, ET.Element):
            return source
        return parse_xml(source)

    # __SENTINEL__

    # --- Сборка текста -----------------------------------------------------
    def _build_text(self) -> str:
        """Собрать весь текст документа."""
        lines: List[str] = []
        if self.include_metadata:
            lines += self._render_metadata()
        if self.include_toc:
            lines += self._render_toc()
        for body in self.bodies:
            lines += self._render_body(body)
        return self._finalize(lines)

    def _render_metadata(self) -> List[str]:
        """Заголовок книги, автор, аннотация."""
        info = self.description.title_info if self.description else None
        if info is None:
            return []

        lines: List[str] = []
        if info.book_title is not None and info.book_title.value:
            title = info.book_title.value
            lines.append(title)
            if self.heading_underline:
                lines.append("=" * len(title))
            lines.append("")

        authors = self._author_text()
        if authors:
            lines += [authors, ""]

        if self.include_annotation and info.annotation is not None:
            for item in info.annotation.items:
                lines += self._render_block(item, indent=self.paragraph_indent)
            lines.append("")
        return lines

    def _render_toc(self) -> List[str]:
        """Оглавление (список заголовков с отступами по уровню)."""
        headings = self._collect_headings()
        if not headings:
            return []
        lines: List[str] = [self.toc_title, ""]
        for level, text in headings:
            lines.append("  " * max(level - 1, 0) + text)
        lines.append("")
        return lines

    def _collect_headings(self) -> List[Tuple[int, str]]:
        """Собрать (уровень, текст) заголовков для оглавления."""
        result: List[Tuple[int, str]] = []

        def walk(section: Section, level: int) -> None:
            if section.title is not None:
                text = self._title_text(section.title)
                if text:
                    result.append((level, text))
            for child in section.sections:
                walk(child, level + 1)

        for body in self.bodies:
            if body.title is not None:
                text = self._title_text(body.title)
                if text:
                    result.append((0, text))
            for section in body.sections:
                walk(section, self.heading_offset)
        return result

    # --- Тело книги --------------------------------------------------------
    def _render_body(self, body: Body) -> List[str]:
        """Отрисовать <body>."""
        lines: List[str] = []
        if body.title is not None:
            lines += self._heading_lines(body.title, 1)
        if self.include_epigraphs:
            for epigraph in body.epigraphs:
                lines += self._render_epigraph(epigraph)
        if body.image is not None:
            placeholder = self._image_placeholder(body.image.alt)
            if placeholder:
                lines += [placeholder, ""]
        for section in body.sections:
            lines += self._render_section(section, self.heading_offset)
        return lines

    def _render_section(self, section: Section, level: int) -> List[str]:
        """Отрисовать секцию (рекурсивно)."""
        lines: List[str] = []
        if section.title is not None:
            lines += self._heading_lines(section.title, level)
        if self.include_epigraphs:
            for epigraph in section.epigraphs:
                lines += self._render_epigraph(epigraph)
        if section.image is not None:
            placeholder = self._image_placeholder(section.image.alt)
            if placeholder:
                lines += [placeholder, ""]
        if self.include_annotation and section.annotation is not None:
            for item in section.annotation.items:
                lines += self._render_block(item, indent=self.paragraph_indent)
        for block in section.content:
            lines += self._render_block(block)
        for child in section.sections:
            lines += self._render_section(child, level + 1)
        return lines

    def _heading_lines(self, title: Optional[Title], level: int) -> List[str]:
        """Строки заголовка (подчёркивание/отступ)."""
        text = self._title_text(title)
        if not text:
            return []
        level = min(max(level, 1), self.max_heading_level)
        lines: List[str] = []
        if self.heading_underline and level == 1:
            lines += [text, "=" * len(text)]
        elif self.heading_underline and level == 2:
            lines += [text, "-" * len(text)]
        else:
            lines.append("  " * (level - 1) + text)
        lines.append("")
        return lines

    # --- Блочные элементы --------------------------------------------------
    def _render_block(self, block, indent: str = "") -> List[str]:
        """Отрисовать блочный элемент FB2."""
        if isinstance(block, Paragraph):
            return self._paragraph_lines(
                self._inline_text(block.content), indent or self.paragraph_indent
            )
        if isinstance(block, Subtitle):
            return [indent + self._inline_text(block.content), ""]
        if isinstance(block, EmptyLine):
            return [""]
        if isinstance(block, Cite):
            return self._render_cite(block)
        if isinstance(block, Epigraph):
            return self._render_epigraph(block)
        if isinstance(block, Poem):
            return self._render_poem(block)
        if isinstance(block, Table):
            return self._render_table(block)
        if isinstance(block, Image):
            placeholder = self._image_placeholder(block.alt)
            return [placeholder, ""] if placeholder else []
        return []

    def _render_cite(self, cite: Cite) -> List[str]:
        """Цитата <cite> (с отступом)."""
        indent = self.paragraph_indent + "    "
        lines: List[str] = []
        for item in cite.items:
            lines += self._render_block(item, indent=indent)
        for author in cite.text_author:
            lines += [indent + "— " + self._inline_text(author.content), ""]
        return lines

    def _render_epigraph(self, epigraph: Epigraph) -> List[str]:
        """Эпиграф <epigraph> (с отступом)."""
        indent = self.paragraph_indent + "    "
        lines: List[str] = []
        for item in epigraph.items:
            lines += self._render_block(item, indent=indent)
        for author in epigraph.text_author:
            lines += [indent + "— " + self._inline_text(author.content), ""]
        return lines

    def _render_poem(self, poem: Poem) -> List[str]:
        """Стихотворение <poem>."""
        lines: List[str] = []
        if poem.title is not None:
            lines += self._heading_lines(poem.title, 3)
        for epigraph in poem.epigraphs:
            lines += self._render_epigraph(epigraph)
        for item in poem.items:
            if isinstance(item, Stanza):
                lines += self._render_stanza(item)
            elif isinstance(item, Subtitle):
                lines += [self.paragraph_indent + self._inline_text(item.content), ""]
        for author in poem.text_author:
            lines += [self.paragraph_indent + "— " + self._inline_text(author.content), ""]
        return lines

    def _render_stanza(self, stanza: Stanza) -> List[str]:
        """Строфа <stanza> (строки с отступом)."""
        lines: List[str] = []
        if stanza.subtitle is not None:
            lines += [self.paragraph_indent + self._inline_text(stanza.subtitle.content), ""]
        for verse in stanza.verses:
            lines.append(self.paragraph_indent + self._inline_text(verse.content))
        lines.append("")
        return lines

    def _render_table(self, table: Table) -> List[str]:
        """Таблица <table> (колонки через `` | ``)."""
        rows: List[List[str]] = []
        for table_row in table.rows:
            rows.append(
                [self._inline_text(cell.children).strip() for cell in table_row.cells]
            )
        if not rows:
            return []

        width = max(len(row) for row in rows)
        rows = [row + [""] * (width - len(row)) for row in rows]
        col_widths = [max(len(row[i]) for row in rows) for i in range(width)]

        lines: List[str] = []
        for row in rows:
            cells = [row[i].ljust(col_widths[i]) for i in range(width)]
            lines.append("  ".join(cells).rstrip())
        lines.append("")
        return lines

    # --- Вспомогательные методы -------------------------------------------
    def _paragraph_lines(self, text: str, indent: str) -> List[str]:
        """Строки абзаца (отступ первой строки + опциональный перенос)."""
        text = text.strip()
        if not text:
            return []
        if self.line_width:
            wrapped = textwrap.fill(
                text,
                width=self.line_width,
                initial_indent=indent,
                subsequent_indent="",
            )
            lines = wrapped.split("\n")
        else:
            lines = [indent + text]
        if self.blank_line_between_paragraphs:
            lines.append("")
        return lines

    def _image_placeholder(self, alt: Optional[str]) -> str:
        """Строка-заглушка для изображения."""
        if not self.image_placeholder:
            return ""
        return f"{self.image_placeholder} {alt}" if alt else self.image_placeholder

    def _inline_text(self, nodes) -> str:
        """Плоский текст inline-узлов (без разметки)."""
        parts: List[str] = []
        for node in nodes:
            if node.tag == TEXT_NODE:
                parts.append(node.text or "")
            elif node.tag == "image":
                parts.append(self._image_placeholder(node.image_alt))
            else:
                parts.append(self._inline_text(node.children))
        return "".join(parts)

    def _title_text(self, title: Optional[Title]) -> str:
        """Плоский текст заголовка."""
        if title is None:
            return ""
        parts = [
            self._inline_text(item.content)
            for item in title.items
            if isinstance(item, Paragraph)
        ]
        return " ".join(part.strip() for part in parts if part.strip())

    def _author_text(self) -> str:
        """Строка со всеми авторами книги."""
        info = self.description.title_info if self.description else None
        if info is None:
            return ""
        return "; ".join(self._format_author(author) for author in info.authors)

    @staticmethod
    def _format_author(author) -> str:
        """Имя автора из структуры Author."""
        parts = [author.first_name, author.middle_name, author.last_name]
        return " ".join(part for part in parts if part) or (author.nickname or "")

    @staticmethod
    def _finalize(lines: List[str]) -> str:
        """Склеить строки, схлопнув повторные пустые строки."""
        result: List[str] = []
        blanks = 0
        for line in lines:
            line = line.rstrip()
            if line:
                blanks = 0
            else:
                blanks += 1
                if blanks > 1:
                    continue
            result.append(line)
        while result and not result[0].strip():
            result.pop(0)
        while result and not result[-1].strip():
            result.pop()
        return "\n".join(result) + "\n"


__all__ = ["Fb2ToTxtConverter"]


def main(argv: List[str] | None = None) -> int:
    if argv is None:
        argv = sys.argv
    if len(argv) < 2:
        print(
            "Использование: python fb2_to_txt.py <файл.fb2> [выход.txt]",
            file=sys.stderr,
        )
        return 2
    source = argv[1]
    output = argv[2] if len(argv) > 2 else str(Path(source).with_suffix(".txt"))
    converter = Fb2ToTxtConverter(include_toc=True)
    path = converter.write(source, output)
    print("TXT:", path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
