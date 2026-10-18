"""Преобразование Markdown в FictionBook (FB2).

Модуль предоставляет класс :class:`MarkdownToFb2Converter`, который читает
Markdown-текст (в формате, генерируемом :mod:`fb2_to_markdown`) и собирает
из него структуры FB2, после чего сериализует их в XML FictionBook 2.0
(через общий :class:`~fb2_writer.Fb2Writer`).

Что поддерживается:

    * ``#`` (уровень 1) -> <book-title>, ``##`` и глубже -> <section>;
    * ``**Автор:**``, ``**Жанры:**``, ``**Дата:**``, ``**Язык:**`` -> метаданные;
    * ``> `` (цитата) -> аннотация/<cite>, ``![…](…)`` -> обложка/изображение;
    * ``**жирный**``, ``*курсив*``, ``~~зачёркнутый~~``, `` `код` ``,
      ``<sub>``/``<sup>``, ``[текст](url)`` -> inline-разметка;
    * ``| … |`` -> <table>, строки с двумя пробелами в конце -> стихи;
    * изображения из файлов -> <binary> (base64).

Пример::

    >>> from markdown_to_fb2 import MarkdownToFb2Converter
    >>> converter = MarkdownToFb2Converter()
    >>> path = converter.write("book.md", "book.fb2")
    WindowsPath('book.fb2')
    >>> book = converter.convert("book.md")   # структура FictionBook
    >>> xml = converter.to_xml(book)          # XML-строка FB2
"""

from __future__ import annotations

import base64
import json
import re
import sys
import uuid
from datetime import date
from pathlib import Path
from typing import Dict, List, Optional, Tuple, Union

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
    FictionBook,
    Genre,
    Image,
    InlineImage,
    Paragraph,
    Poem,
    Section,
    Stanza,
    StyleNode,
    Table,
    TableCell,
    TableRow,
    TextField,
    Title,
    TitleInfo,
)
from .fb2_writer import TEXT_NODE, Fb2Writer

#: Жанр по умолчанию (если в Markdown нет подходящих <**Жанры:**>).
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

#: Метаданные вида ``**Ключ:** значение``.
_META_RE = re.compile(r"^\*\*(.+?):\*\*\s*(.*)$")

#: Изображение вида ``![alt](src)``.
_IMAGE_RE = re.compile(r"^!\[(.*?)\]\((.*?)\)$")

#: Проверка корректности XML-ID.
_ID_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_.-]*$")


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


class MarkdownToFb2Converter:
    """Преобразование Markdown в структуры FB2 и обратно в XML.

    :param source: путь к ``.md`` (``str``/``Path``) либо сам Markdown-текст.
        Может передаваться в конструктор или в методы :meth:`convert` /
        :meth:`write`.
    :param default_genre: жанр FB2 по умолчанию, если в Markdown нет
        подходящего ``**Жанры:**`` (по умолчанию ``"prose"``).
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
        """Прочитать Markdown и вернуть структуру :class:`FictionBook`.

        :param source: путь к .md или Markdown-текст (иначе ``self.source``).
        """
        if source is not None:
            self.source = source
        if self.source is None:
            raise Fb2ConversionError("Не задан источник Markdown (source)")

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
        """Преобразовать Markdown в файл FB2 и вернуть путь к результату.

        :param source: путь к .md или Markdown-текст (иначе ``self.source``).
        :param output: путь к выходному ``.fb2``; по умолчанию — рядом с
            исходным ``.md`` (или ``book.fb2``, если источник — текст).
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
        """Прочитать источник: вернуть текст и каталог (для изображений)."""
        if isinstance(source, Path):
            return source.read_text(encoding="utf-8"), source.parent
        if isinstance(source, str):
            path = Path(source)
            if path.is_file():
                return path.read_text(encoding="utf-8"), path.parent
            return source, None
        raise Fb2ConversionError(f"Неподдерживаемый тип источника: {type(source).__name__}")

    # --- Парсинг Markdown --------------------------------------------------
    def _parse(self, text: str) -> FictionBook:
        """Разобрать Markdown в структуру FictionBook."""
        lines = text.splitlines()

        title = "Untitled"
        creators: List[str] = []
        genres: List[str] = []
        annotation_items: List = []
        cover_href: Optional[str] = None
        date_value: Optional[str] = None
        lang: Optional[str] = None

        body = Body()
        root = Section()
        stack: List[Tuple[int, Section]] = [(0, root)]

        i = 0
        while i < len(lines):
            line = lines[i]
            stripped = line.strip()

            # Горизонтальный разделитель (между <body>).
            if stripped == "---":
                i += 1
                continue

            # Заголовок.
            heading = re.match(r"^(#{1,6})\s+(.*)$", line)
            if heading:
                level = len(heading.group(1))
                heading_text = self._parse_inline(heading.group(2))
                if level == 1 and title == "Untitled":
                    title = self._nodes_text(heading_text)
                else:
                    while len(stack) > 1 and stack[-1][0] >= level:
                        stack.pop()
                    section = Section(title=Title(items=[Paragraph(content=heading_text)]))
                    stack[-1][1].sections.append(section)
                    stack.append((level, section))
                i += 1
                continue

            # Метаданные вида **Ключ:** значение.
            meta = _META_RE.match(stripped)
            if meta:
                key = meta.group(1).strip().lower()
                value = meta.group(2).strip()
                if key == "автор":
                    creators = [a.strip() for a in value.split(";") if a.strip()]
                elif key == "жанры":
                    genres = [g.strip() for g in value.split(",") if g.strip()]
                elif key == "дата":
                    date_value = value
                elif key == "язык":
                    lang = value
                i += 1
                continue

            # Изображение (обложка или блочное).
            image = _IMAGE_RE.match(stripped)
            if image:
                alt = image.group(1)
                src = image.group(2)
                href = self._register_image(src)
                if href:
                    if cover_href is None and alt and alt.lower() in ("обложка", "cover"):
                        cover_href = href
                    else:
                        stack[-1][1].content.append(Image(href=href, alt=alt or None))
                i += 1
                continue

            # Цитата (blockquote).
            if stripped.startswith(">"):
                block_lines = self._collect_quote(lines, i)
                inner = self._parse_blocks(block_lines)
                if not root.sections and not annotation_items:
                    annotation_items.extend(inner)
                else:
                    stack[-1][1].content.append(Cite(items=inner))
                i += len(block_lines)
                continue

            # Таблица.
            if stripped.startswith("|"):
                table_lines = self._collect_table(lines, i)
                table = self._parse_table(table_lines)
                if table is not None:
                    stack[-1][1].content.append(table)
                i += len(table_lines)
                continue

            # Стихотворная строка (два пробела в конце).
            if line.endswith("  ") and stripped:
                poem_lines = self._collect_poem(lines, i)
                stack[-1][1].content.append(self._parse_poem(poem_lines))
                i += len(poem_lines)
                continue

            # Обычный абзац.
            if stripped:
                nodes = self._parse_inline(stripped)
                stack[-1][1].content.append(Paragraph(content=nodes))
            i += 1

        # Собираем body.
        body.sections = root.sections
        if root.content:
            body.sections.insert(0, Section(content=root.content))
        if not body.sections:
            body.sections = [Section()]

        return self._assemble(
            title=title,
            creators=creators,
            genres=genres,
            annotation_items=annotation_items,
            cover_href=cover_href,
            date_value=date_value,
            lang=lang,
            body=body,
        )

    # --- Inline-разметка --------------------------------------------------
    def _parse_inline(self, text: str) -> List[StyleNode]:
        """Разобрать inline-разметку Markdown в список StyleNode."""
        nodes: List[StyleNode] = []
        buf: List[str] = []

        def flush() -> None:
            if buf:
                nodes.append(StyleNode(tag=TEXT_NODE, text="".join(buf)))
                buf.clear()

        i = 0
        n = len(text)
        while i < n:
            if text.startswith("**", i):
                end = self._find_closing(text, "**", i + 2)
                if end != -1:
                    flush()
                    nodes.append(StyleNode(tag="strong", children=self._parse_inline(text[i + 2:end])))
                    i = end + 2
                    continue
            if text.startswith("~~", i):
                end = self._find_closing(text, "~~", i + 2)
                if end != -1:
                    flush()
                    nodes.append(StyleNode(tag="strikethrough", children=self._parse_inline(text[i + 2:end])))
                    i = end + 2
                    continue
            if text.startswith("![", i):
                end = text.find(")", i)
                if end != -1:
                    alt, src = self._split_image(text[i + 2:end])
                    href = self._register_image(src)
                    flush()
                    if href:
                        nodes.append(StyleNode(tag="image", image_href=href, image_alt=alt))
                    else:
                        nodes.append(StyleNode(tag=TEXT_NODE, text=alt))
                    i = end + 1
                    continue
            if text[i] == "[":
                end = text.find("]", i)
                if end != -1 and end + 1 < n and text[end + 1] == "(":
                    close = text.find(")", end + 2)
                    if close != -1:
                        label = text[i + 1:end]
                        href = text[end + 2:close]
                        flush()
                        nodes.append(StyleNode(tag="a", href=href, children=self._parse_inline(label)))
                        i = close + 1
                        continue
            if text[i] == "`":
                end = text.find("`", i + 1)
                if end != -1:
                    flush()
                    nodes.append(
                        StyleNode(tag="code", children=[StyleNode(tag=TEXT_NODE, text=text[i + 1:end])])
                    )
                    i = end + 1
                    continue
            if text.startswith("<sub>", i):
                end = text.find("</sub>", i)
                if end != -1:
                    flush()
                    nodes.append(StyleNode(tag="sub", children=self._parse_inline(text[i + 5:end])))
                    i = end + 6
                    continue
            if text.startswith("<sup>", i):
                end = text.find("</sup>", i)
                if end != -1:
                    flush()
                    nodes.append(StyleNode(tag="sup", children=self._parse_inline(text[i + 5:end])))
                    i = end + 6
                    continue
            if text[i] == "*":
                end = self._find_closing(text, "*", i + 1)
                if end != -1:
                    flush()
                    nodes.append(StyleNode(tag="emphasis", children=self._parse_inline(text[i + 1:end])))
                    i = end + 1
                    continue
            if text[i] == "\\" and i + 1 < n and text[i + 1] in "\\`*_[]()":
                buf.append(text[i + 1])
                i += 2
                continue
            buf.append(text[i])
            i += 1

        flush()
        return nodes

    @staticmethod
    def _find_closing(text: str, token: str, start: int) -> int:
        """Найти закрывающий токен (не экранированный)."""
        i = start
        while True:
            idx = text.find(token, i)
            if idx == -1:
                return -1
            backslashes = 0
            j = idx - 1
            while j >= 0 and text[j] == "\\":
                backslashes += 1
                j -= 1
            if backslashes % 2 == 0:
                return idx
            i = idx + len(token)

    @staticmethod
    def _split_image(s: str) -> Tuple[str, str]:
        """Разобрать ``alt](src`` на alt и src."""
        idx = s.find("](")
        if idx == -1:
            return s, ""
        return s[:idx], s[idx + 2:]

    @staticmethod
    def _nodes_text(nodes: List[StyleNode]) -> str:
        """Собрать текст из списка StyleNode."""
        parts: List[str] = []
        for node in nodes:
            if node.tag == TEXT_NODE:
                parts.append(node.text or "")
            else:
                parts.append(MarkdownToFb2Converter._nodes_text(node.children))
        return "".join(parts)

    # --- Блочные элементы -------------------------------------------------
    def _collect_quote(self, lines: List[str], start: int) -> List[str]:
        """Собрать строки цитаты (с ``>``)."""
        result: List[str] = []
        j = start
        while j < len(lines) and lines[j].strip().startswith(">"):
            result.append(lines[j].strip()[1:].strip())
            j += 1
        return result

    def _parse_blocks(self, lines: List[str]) -> List:
        """Разобрать строки (без ``>``) в блочные элементы FB2."""
        blocks: List = []
        i = 0
        while i < len(lines):
            stripped = lines[i].strip()
            if not stripped:
                i += 1
                continue
            if stripped.startswith("|"):
                table_lines = self._collect_table(lines, i)
                table = self._parse_table(table_lines)
                if table is not None:
                    blocks.append(table)
                i += len(table_lines)
                continue
            if lines[i].endswith("  ") and stripped:
                poem_lines = self._collect_poem(lines, i)
                blocks.append(self._parse_poem(poem_lines))
                i += len(poem_lines)
                continue
            blocks.append(Paragraph(content=self._parse_inline(stripped)))
            i += 1
        return blocks

    def _collect_table(self, lines: List[str], start: int) -> List[str]:
        """Собрать строки Markdown-таблицы."""
        result: List[str] = []
        j = start
        while j < len(lines) and lines[j].strip().startswith("|"):
            result.append(lines[j].strip())
            j += 1
        return result

    def _parse_table(self, lines: List[str]) -> Optional[Table]:
        """Разобрать Markdown-таблицу в Table."""
        rows: List[List[str]] = []
        for line in lines:
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if self._is_separator(cells):
                continue
            rows.append(cells)
        if not rows:
            return None

        table = Table()
        for idx, cells in enumerate(rows):
            table.rows.append(
                TableRow(
                    cells=[
                        TableCell(tag="td", children=self._parse_inline(c), is_header=(idx == 0))
                        for c in cells
                    ]
                )
            )
        return table

    @staticmethod
    def _is_separator(cells: List[str]) -> bool:
        """Проверить, является ли строка разделителем таблицы (``---``)."""
        if not cells:
            return False
        return all(set(c) <= set("-: ") and "-" in c for c in cells)

    def _collect_poem(self, lines: List[str], start: int) -> List[str]:
        """Собрать строки стихотворения (с двумя пробелами в конце)."""
        result: List[str] = []
        j = start
        while j < len(lines) and lines[j].endswith("  ") and lines[j].strip():
            result.append(lines[j].rstrip())
            j += 1
        return result

    def _parse_poem(self, lines: List[str]) -> Poem:
        """Разобрать строки стихотворения в Poem/Stanza."""
        verses = [Paragraph(content=self._parse_inline(line.strip())) for line in lines if line.strip()]
        return Poem(items=[Stanza(verses=verses)])

    # --- Изображения ------------------------------------------------------
    def _register_image(self, src: str) -> Optional[str]:
        """Загрузить изображение с диска и вернуть href FB2 (#id)."""
        if not src or self._base_dir is None:
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

    @staticmethod
    def _annotation(items: List) -> Optional[Annotation]:
        """Аннотация из собранных блоков (или None)."""
        if not items:
            return None
        return Annotation(items=items)

    @staticmethod
    def _date_field(value: Optional[str]) -> Optional[DateField]:
        """Дата из строки ``**Дата:**``."""
        if not value:
            return None
        match = re.match(r"^(\d{4}(?:-\d{2}-\d{2})?)", value)
        return DateField(value=value, date_value=match.group(1) if match else None)

    def _assemble(
        self,
        title: str,
        creators: List[str],
        genres: List[str],
        annotation_items: List,
        cover_href: Optional[str],
        date_value: Optional[str],
        lang: Optional[str],
        body: Body,
    ) -> FictionBook:
        """Собрать корневую структуру FictionBook."""
        title_info = TitleInfo(
            genres=[Genre(value=g) for g in self._match_genres(genres)],
            authors=[self._split_author(a) for a in creators],
            book_title=TextField(value=title),
            annotation=self._annotation(annotation_items),
            date=self._date_field(date_value),
            coverpage=CoverPage(images=[InlineImage(href=cover_href)]) if cover_href else None,
            lang=lang or "ru",
        )
        document_info = DocumentInfo(
            authors=[Author(nickname="pyFB2")],
            program_used=TextField(value=self.program_used),
            date=DateField(value=date_value or date.today().isoformat()),
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


__all__ = ["MarkdownToFb2Converter"]


def main(argv: List[str] | None = None) -> int:
    if argv is None:
        argv = sys.argv
    if len(argv) < 2:
        print(
            "Использование: python markdown_to_fb2.py <файл.md> [выход.fb2]",
            file=sys.stderr,
        )
        return 2
    source = argv[1]
    output = argv[2] if len(argv) > 2 else str(Path(source).with_suffix(".fb2"))
    converter = MarkdownToFb2Converter()
    path = converter.write(source, output)
    print("FB2:", path)
    if converter.book is not None:
        print("Изображений:", len(converter.book.binaries))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))




