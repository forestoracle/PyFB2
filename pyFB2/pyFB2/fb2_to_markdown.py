"""Экспорт FB2 в Markdown с сохранением изображений.

Модуль предоставляет класс :class:`Fb2ToMarkdownConverter`, который берёт
структуры из fb2_parser.py (см. :class:`Fb2Parser`) и превращает книгу в
Markdown-документ:

    * метаданные (<description>)        -> заголовок, автор, жанры, аннотация;
    * вложенные <section>               -> заголовки ``#``/``##``/``###``;
    * <p>, <strong>, <emphasis>, <a>    -> абзацы и inline-разметка;
    * <epigraph>, <cite>                -> цитаты (``>``);
    * <poem>/<stanza>/<v>               -> стихи с переносами строк;
    * <table>/<tr>/<td>                 -> Markdown-таблица;
    * <binary>                          -> файлы изображений + ссылки ``![](…)``.

Пример:
    >>> from fb2_to_markdown import Fb2ToMarkdownConverter
    >>> writer = Fb2ToMarkdownConverter(image_dir="images")
    >>> writer.write("book.fb2", "book.md")
    WindowsPath('book.md')
    >>> # только текст, без записи файлов:
    >>> markdown = writer.convert("book.fb2")
"""

from __future__ import annotations

import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Dict, List, Optional, Union

from .fb2_parser import TEXT_NODE, Fb2Parser
from .fb2_structures import (
    Annotation,
    Author,
    Binary,
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
    StyleNode,
    Subtitle,
    Table,
    TableCell,
    Title,
)
from .fb2_xml import parse_xml

#: Символы Markdown, которые экранируются в обычном тексте.
MD_SPECIAL_RE = re.compile(r"([\\`*_\[\]])")


class Fb2ToMarkdownConverter:
    """Преобразование разобранного FB2 в Markdown + выгрузка картинок.

    :param parser: готовый :class:`Fb2Parser` (иначе создаётся новый).
    :param image_dir: подкаталог для изображений относительно .md-файла.
        Пустая строка — складывать изображения рядом с .md.
    :param heading_offset: уровень заголовка для секций верхнего уровня
        (2 -> ``##``, как в обычном оглавлении).
    :param max_heading_level: максимальная глубина ``#`` (в Markdown — 6).
    :param include_annotation: выводить ли аннотацию книги.
    :param include_epigraphs: выводить ли эпиграфы.
    :param include_cover: выводить ли обложку из <coverpage>.
    :param escape_text: экранировать ли спецсимволы Markdown в тексте.
    """

    def __init__(
        self,
        parser: Optional[Fb2Parser] = None,
        image_dir: str = "images",
        heading_offset: int = 2,
        max_heading_level: int = 6,
        include_annotation: bool = True,
        include_epigraphs: bool = True,
        include_cover: bool = True,
        escape_text: bool = True,
    ) -> None:
        self.parser = parser if parser is not None else Fb2Parser()
        self.image_dir = image_dir
        self.heading_offset = heading_offset
        self.max_heading_level = max_heading_level
        self.include_annotation = include_annotation
        self.include_epigraphs = include_epigraphs
        self.include_cover = include_cover
        self.escape_text = escape_text

        # Заполняется в _prepare().
        self.description: Optional[Description] = None
        self.bodies: List[Body] = []
        self.binaries: List[Binary] = []
        self._image_files: Dict[str, str] = {}  # id <binary> -> имя файла

    # --- Публичный API -----------------------------------------------------
    def convert(self, source) -> str:
        """Вернуть Markdown-текст для FB2-источника (файлы не создаются).

        :param source: путь к файлу, file-like объект или ``ET.Element``.
        """
        self._prepare(source)
        return self._build_markdown()

    def write(
        self, source, md_path: Union[str, Path], encoding: str = "utf-8"
    ) -> Path:
        """Сохранить книгу как Markdown и выгрузить все <binary>.

        Изображения записываются в ``<каталог .md>/<image_dir>`` (если
        ``image_dir`` не пуст) или рядом с .md-файлом.

        :param source: путь к файлу, file-like объект или ``ET.Element``.
        :param md_path: путь к создаваемому .md-файлу.
        :param encoding: кодировка выходного файла.
        :return: путь к записанному .md-файлу.
        """
        self._prepare(source)
        markdown = self._build_markdown()

        md_path = Path(md_path)
        md_path.parent.mkdir(parents=True, exist_ok=True)
        self.save_images(md_path.parent)
        md_path.write_text(markdown, encoding=encoding)
        return md_path

    def save_images(self, base_dir: Union[str, Path]) -> List[Path]:
        """Выгрузить все <binary> в каталог изображений.

        :param base_dir: каталог, относительно которого берётся ``image_dir``.
        :return: список путей к записанным файлам.
        """
        if not self.binaries:
            return []

        base_dir = Path(base_dir)
        target_dir = base_dir / self.image_dir if self.image_dir else base_dir
        target_dir.mkdir(parents=True, exist_ok=True)

        written: List[Path] = []
        for binary in self.binaries:
            filename = self._image_files.get(binary.id)
            if not filename:
                continue
            path = target_dir / filename
            path.write_bytes(self.parser.binary_data(binary))
            written.append(path)
        return written

    # --- Подготовка --------------------------------------------------------
    def _prepare(self, source) -> None:
        """Разобрать источник и построить карту изображений."""
        root = self._root(source)
        try:
            self.description = self.parser.parse(root)
        except ValueError:
            self.description = None
        self.bodies = self.parser.parse_bodies(root)
        self.binaries = self.parser.parse_binaries(root)
        self._register_images(self.binaries)

    @staticmethod
    def _root(source) -> ET.Element:
        """Получить корневой элемент (один раз читая поток/файл)."""
        if isinstance(source, ET.Element):
            return source
        return parse_xml(source)

    def _register_images(self, binaries: List[Binary]) -> None:
        """Сопоставить id <binary> уникальным именам файлов."""
        self._image_files = {}
        used = set()
        for binary in binaries:
            filename = self.parser.binary_filename(binary)
            stem, suffix = Path(filename).stem, Path(filename).suffix
            candidate, counter = filename, 1
            while candidate in used:
                candidate = f"{stem}_{counter}{suffix}"
                counter += 1
            used.add(candidate)
            self._image_files[binary.id] = candidate

    # --- Сборка документа --------------------------------------------------
    def _build_markdown(self) -> str:
        lines: List[str] = []
        lines += self._render_description()

        for index, body in enumerate(self.bodies):
            if index > 0:
                lines += ["", "---", ""]
            lines += self._render_body(body)

        return self._finalize(lines)

    def _render_description(self) -> List[str]:
        """Заголовок, автор, жанры, аннотация, обложка."""
        lines: List[str] = []
        info = self.description.title_info if self.description else None
        if info is None:
            return lines

        if info.book_title is not None and info.book_title.value:
            lines += [f"# {self._escape(info.book_title.value)}", ""]

        authors = "; ".join(self._format_author(a) for a in info.authors)
        if authors:
            lines += [f"**Автор:** {authors}", ""]

        if info.genres:
            genres = ", ".join(g.value for g in info.genres)
            lines += [f"**Жанры:** {genres}", ""]

        if info.sequences:
            seq = "; ".join(
                f"{s.name} #{s.number}" if s.number else s.name
                for s in info.sequences
            )
            lines += [f"**Серия:** {seq}", ""]

        if info.date is not None and info.date.value:
            lines += [f"**Дата:** {info.date.value}", ""]

        if info.lang:
            lines += [f"**Язык:** {info.lang}", ""]

        if self.include_cover and info.coverpage is not None:
            for image in info.coverpage.images:
                rendered = self._render_image(image.href, image.alt or "Обложка")
                if rendered:
                    lines += [rendered, ""]

        if self.include_annotation and info.annotation is not None:
            inner = self._render_annotation(info.annotation)
            if inner:
                lines += self._quote(inner)
                lines.append("")

        return lines

    def _render_body(self, body: Body) -> List[str]:
        """Один <body>: заголовок, эпиграфы и секции."""
        lines: List[str] = []

        if body.title is not None:
            title = self._title_text(body.title)
            if title:
                level = max(self.heading_offset - 1, 1)
                lines += ["#" * level + " " + title, ""]

        if self.include_epigraphs:
            for epigraph in body.epigraphs:
                lines += self._render_epigraph(epigraph)

        if body.image is not None:
            rendered = self._render_image(body.image.href, body.image.alt)
            if rendered:
                lines += [rendered, ""]

        for section in body.sections:
            lines += self._render_section(section, 0)

        return lines

    def _render_section(self, section: Section, depth: int) -> List[str]:
        """Секция с рекурсивным обходом вложенных <section>."""
        lines: List[str] = []

        title = self._title_text(section.title)
        if title:
            level = min(self.heading_offset + depth, self.max_heading_level)
            lines += ["#" * level + " " + title, ""]

        if self.include_epigraphs:
            for epigraph in section.epigraphs:
                lines += self._render_epigraph(epigraph)

        if section.image is not None:
            rendered = self._render_image(section.image.href, section.image.alt)
            if rendered:
                lines += [rendered, ""]

        if self.include_annotation and section.annotation is not None:
            inner = self._render_annotation(section.annotation)
            if inner:
                lines += self._quote(inner)
                lines.append("")

        for block in section.content:
            lines += self._render_block(block)

        for child in section.sections:
            lines += self._render_section(child, depth + 1)

        return lines

    # --- Блочные элементы --------------------------------------------------
    def _render_block(self, block) -> List[str]:
        """Отрисовать блочный элемент контента (с завершающей пустой строкой)."""
        if isinstance(block, Paragraph):
            return [self._render_inline(block.content), ""]
        if isinstance(block, Subtitle):
            return [f"**{self._render_inline(block.content)}**", ""]
        if isinstance(block, EmptyLine):
            return [""]
        if isinstance(block, Poem):
            return self._render_poem(block) + [""]
        if isinstance(block, Cite):
            return self._render_cite(block)
        if isinstance(block, Table):
            return self._render_table(block) + [""]
        if isinstance(block, Image):
            rendered = self._render_image(block.href, block.alt)
            return [rendered, ""] if rendered else []
        return []

    def _render_annotation(self, annotation: Annotation) -> List[str]:
        """Содержимое <annotation> (без обрамления цитаты)."""
        lines: List[str] = []
        for item in annotation.items:
            lines += self._render_block(item)
        return [line for line in lines if line != ""] or lines

    def _render_epigraph(self, epigraph: Epigraph) -> List[str]:
        """Эпиграф как цитата с подписью автора."""
        inner: List[str] = []
        for item in epigraph.items:
            inner += self._render_block(item)
        for author in epigraph.text_author:
            inner.append(f"— *{self._render_inline(author.content)}*")
        if not inner:
            return []
        return self._quote(inner) + [""]

    def _render_cite(self, cite: Cite) -> List[str]:
        """Цитата <cite> с подписью автора."""
        inner: List[str] = []
        for item in cite.items:
            inner += self._render_block(item)
        for author in cite.text_author:
            inner.append(f"— *{self._render_inline(author.content)}*")
        if not inner:
            return []
        return self._quote(inner) + [""]

    def _render_poem(self, poem: Poem) -> List[str]:
        """Стихотворение: заголовок, эпиграфы, строфы, автор, дата."""
        lines: List[str] = []
        if poem.title is not None:
            title = self._title_text(poem.title)
            if title:
                lines += [f"**{title}**", ""]

        if self.include_epigraphs:
            for epigraph in poem.epigraphs:
                lines += self._render_epigraph(epigraph)

        for item in poem.items:
            if isinstance(item, Subtitle):
                lines += [f"**{self._render_inline(item.content)}**", ""]
            elif isinstance(item, Stanza):
                lines += self._render_stanza(item)

        for author in poem.text_author:
            lines += [f"*{self._render_inline(author.content)}*", ""]

        if poem.date is not None and poem.date.value:
            lines += [f"*{poem.date.value}*", ""]

        return lines

    def _render_stanza(self, stanza: Stanza) -> List[str]:
        """Строфа: каждая строка <v> завершается двумя пробелами (перенос)."""
        lines: List[str] = []
        if stanza.title is not None:
            title = self._title_text(stanza.title)
            if title:
                lines += [f"**{title}**", ""]
        if stanza.subtitle is not None:
            lines += [f"**{self._render_inline(stanza.subtitle.content)}**", ""]

        for verse in stanza.verses:
            lines.append(self._render_inline(verse.content) + "  ")
        lines.append("")
        return lines

    def _render_table(self, table: Table) -> List[str]:
        """Markdown-таблица; первая строка считается заголовочной."""
        rows: List[List[str]] = []
        for table_row in table.rows:
            rows.append([self._render_table_cell(c) for c in table_row.cells])
        if not rows:
            return []

        width = max(len(row) for row in rows)
        rows = [row + [""] * (width - len(row)) for row in rows]

        lines = [
            "| " + " | ".join(rows[0]) + " |",
            "| " + " | ".join(["---"] * width) + " |",
        ]
        for row in rows[1:]:
            lines.append("| " + " | ".join(row) + " |")
        return lines

    def _render_table_cell(self, cell: TableCell) -> str:
        text = self._render_inline(cell.children)
        return text.replace("|", "\\|").replace("\n", " ")

    # --- Inline-разметка ---------------------------------------------------
    def _render_inline(self, nodes: List[StyleNode]) -> str:
        """Собрать inline-разметку Markdown из списка StyleNode."""
        parts: List[str] = []
        for node in nodes:
            tag = node.tag
            if tag == TEXT_NODE:
                parts.append(self._escape(node.text))
            elif tag == "strong":
                parts.append(f"**{self._render_inline(node.children)}**")
            elif tag == "emphasis":
                parts.append(f"*{self._render_inline(node.children)}*")
            elif tag == "strikethrough":
                parts.append(f"~~{self._render_inline(node.children)}~~")
            elif tag == "code":
                parts.append(f"`{self._render_inline(node.children)}`")
            elif tag == "sub":
                parts.append(f"<sub>{self._render_inline(node.children)}</sub>")
            elif tag == "sup":
                parts.append(f"<sup>{self._render_inline(node.children)}</sup>")
            elif tag == "a":
                parts.append(self._render_link(node))
            elif tag == "image":
                parts.append(self._render_image(node.image_href, node.image_alt))
            else:
                # style, styleLink и прочие — сохраняем только текст.
                parts.append(self._render_inline(node.children))
        return "".join(parts)

    def _render_link(self, node: StyleNode) -> str:
        """Ссылка <a> как [текст](href)."""
        text = self._render_inline(node.children) or self._escape(node.href or "")
        href = node.href or ""
        return f"[{text}]({href})" if href else text

    def _render_image(self, href: Optional[str], alt: Optional[str]) -> str:
        """Ссылка на изображение по xlink:href вида '#id'."""
        link = self._image_link(href)
        if not link:
            return ""
        return f"![{self._escape(alt or '')}]({link})"

    def _image_link(self, href: Optional[str]) -> str:
        """Путь к изображению относительно .md-файла."""
        if not href:
            return ""
        image_id = href[1:] if href.startswith("#") else href
        filename = self._image_files.get(image_id, Path(image_id).name)
        if self.image_dir:
            return f"{self.image_dir}/{filename}"
        return filename

    # --- Утилиты -----------------------------------------------------------
    def _title_text(self, title: Optional[Title]) -> str:
        """Текст заголовка в одну строку."""
        if title is None:
            return ""
        parts: List[str] = []
        for item in title.items:
            if isinstance(item, Paragraph):
                parts.append(self._render_inline(item.content))
        return " ".join(p for p in parts if p)

    def _escape(self, text: str) -> str:
        """Экранировать спецсимволы Markdown в обычном тексте."""
        if not text or not self.escape_text:
            return text or ""
        return MD_SPECIAL_RE.sub(r"\\\1", text)

    @staticmethod
    def _quote(lines: List[str]) -> List[str]:
        """Оформить строки как цитату (blockquote)."""
        return [("> " + line).rstrip() if line.strip() else ">" for line in lines]

    @staticmethod
    def _format_author(author: Author) -> str:
        parts = [author.first_name, author.middle_name, author.last_name]
        return " ".join(p for p in parts if p) or (author.nickname or "—")

    @staticmethod
    def _finalize(lines: List[str]) -> str:
        """Убрать лишние пустые строки и завершить документ переводом строки."""
        out: List[str] = []
        blank = 0
        for line in lines:
            hard_break = line.endswith("  ")
            line = line.rstrip()
            if hard_break:
                line += "  "
            if not line:
                blank += 1
                if blank > 1:
                    continue
            else:
                blank = 0
            out.append(line)

        while out and not out[0].strip():
            out.pop(0)
        while out and not out[-1].strip():
            out.pop()

        return "\n".join(out) + "\n"


__all__ = ["Fb2ToMarkdownConverter", "Fb2MarkdownWriter"]

#: Обратная совместимость: прежнее имя класса.
Fb2MarkdownWriter = Fb2ToMarkdownConverter


def main(argv: List[str] | None = None) -> int:
    if argv is None:
        argv = sys.argv
    if len(argv) < 2:
        print(
            "Использование: python fb2_to_markdown.py <файл.fb2> "
            "[выход.md] [каталог_изображений]",
            file=sys.stderr,
        )
        return 2

    source = argv[1]
    output = argv[2] if len(argv) > 2 else str(Path(source).with_suffix(".md"))
    image_dir = argv[3] if len(argv) > 3 else "images"

    writer = Fb2ToMarkdownConverter(image_dir=image_dir)
    path = writer.write(source, output)

    print("Markdown:", path)
    print("Изображений:", len(writer.binaries))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))