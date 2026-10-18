"""Преобразование PDF в FictionBook (FB2).

Модуль предоставляет класс :class:`PdfToFb2Converter`, который извлекает из
PDF текст (через ``pypdf``), восстанавливает структуру глав по закладкам
(PDF outline), читает метаданные ``/Info`` и собирает структуры FB2,
сериализуемые общим :class:`~fb2_writer.Fb2Writer`.

Поддерживается:

    * метаданные ``/Title``, ``/Author`` -> ``<title-info>``;
    * закладки PDF (outline) -> иерархия ``<section>``/``<title>``;
    * текст страниц -> абзацы ``<p>``: разрыв абзаца определяется по отступу
      первой строки и вертикальному интервалу, переносы слов склеиваются;
    * большие вертикальные промежутки -> ``<empty-line>``;
    * при отсутствии закладок структура строится по размеру шрифта заголовков.

Ограничения (обусловлены природой PDF — формата фиксированной вёрстки):

    * семантики в PDF нет, поэтому структура и абзацы восстанавливаются
      эвристически и обычно требуют ручной вычитки;
    * колонтитулы, номера страниц и таблицы распознаются плохо;
    * изображения не переносятся.

Требует пакет ``pypdf`` (extra ``pyFB2[pdf]``).

Пример::

    >>> from pdf_to_fb2 import PdfToFb2Converter
    >>> converter = PdfToFb2Converter()
    >>> path = converter.write("book.pdf", "book.fb2")
    WindowsPath('book.fb2')
    >>> book = converter.convert("book.pdf")   # структура FictionBook
"""

from __future__ import annotations

import bisect
import io
import json
import math
import sys
import uuid
from dataclasses import dataclass
from datetime import date
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple, Union

from pypdf import PdfReader

from .fb2_errors import Fb2ConversionError
from .fb2_structures import (
    Author,
    Body,
    DateField,
    Description,
    DocumentInfo,
    EmptyLine,
    FictionBook,
    Genre,
    Paragraph,
    Section,
    StyleNode,
    TextField,
    Title,
    TitleInfo,
)
from .fb2_writer import TEXT_NODE, Fb2Writer

#: Жанр по умолчанию (в PDF нет жанров).
DEFAULT_GENRE = "prose"

#: Язык по умолчанию.
DEFAULT_LANG = "ru"

#: Отступ первой строки (pt), считающийся началом нового абзаца.
_INDENT_THRESHOLD = 4.0

#: Во сколько раз интервал больше межстрочного, чтобы считать это новым абзацем.
_PARAGRAPH_GAP_RATIO = 1.15

#: Во сколько раз интервал больше межстрочного, чтобы вставить <empty-line/>.
_EMPTY_LINE_GAP_RATIO = 1.8

#: Во сколько раз размер шрифта больше базового, чтобы считать строку заголовком.
_HEADING_SIZE_RATIO = 1.15

#: Текст длиннее этого (символов) не считается заголовком в режиме без закладок.
_MAX_HEADING_CHARS = 120

#: Допуск (pt) по Y, в пределах которого фрагменты считаются одной строкой.
_LINE_Y_TOLERANCE = 1.5


@dataclass
class _Line:
    """Одна визуальная строка PDF с координатами и размером шрифта."""

    text: str
    x: float
    y: float
    size: float
    is_heading: bool = False


@dataclass
class _Anchor:
    """Начало секции из закладки: страница и координата заголовка."""

    page: int
    y: float
    section: Section


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


class PdfToFb2Converter:
    """Преобразование PDF в структуры FB2 и XML.

    :param source: путь к ``.pdf`` (``str``/``Path``) либо байты PDF. Может
        передаваться в конструктор или в методы :meth:`convert` / :meth:`write`.
    :param default_genre: жанр FB2 (в PDF жанров нет).
    :param lang: язык книги (``<lang>``).
    :param program_used: значение ``<program-used>`` в ``document-info``.
    :param use_outline: восстанавливать структуру глав по закладкам PDF;
        при их отсутствии структура строится по размеру шрифта заголовков.
    :param detect_headings: в режиме без закладок определять заголовки по
        размеру шрифта.
    """

    def __init__(
        self,
        source: Optional[Union[str, Path, bytes]] = None,
        default_genre: str = DEFAULT_GENRE,
        lang: str = DEFAULT_LANG,
        program_used: str = "pyFB2",
        use_outline: bool = True,
        detect_headings: bool = True,
    ) -> None:
        self.source = source
        self.default_genre = default_genre
        self.lang = lang
        self.program_used = program_used
        self.use_outline = use_outline
        self.detect_headings = detect_headings
        self.writer = Fb2Writer()
        self._book: Optional[FictionBook] = None
        self._reset()

    def _reset(self) -> None:
        """Очистить состояние для нового преобразования."""
        self._body_size: float = 11.0
        self._leading: float = 0.0

    # --- Публичный API -----------------------------------------------------
    @property
    def book(self) -> Optional[FictionBook]:
        """Последняя собранная структура :class:`FictionBook` (или None)."""
        return self._book

    def convert(
        self, source: Optional[Union[str, Path, bytes]] = None
    ) -> FictionBook:
        """Прочитать PDF и вернуть структуру :class:`FictionBook`.

        :param source: путь к .pdf или байты (иначе ``self.source``).
        """
        if source is not None:
            self.source = source
        if self.source is None:
            raise Fb2ConversionError("Не задан источник PDF (source)")

        self._reset()
        reader = self._open_reader(self.source)
        pages_lines = [self._page_lines(page) for page in reader.pages]
        self._body_size = self._detect_body_size(pages_lines)
        self._leading = self._detect_leading(pages_lines)
        for lines in pages_lines:
            for line in lines:
                line.is_heading = line.size > self._body_size * _HEADING_SIZE_RATIO

        meta = self._read_metadata(reader)
        entries = self._outline_entries(reader) if self.use_outline else []

        if entries:
            body = self._build_from_outline(entries, pages_lines)
        else:
            body = self._build_from_headings(pages_lines)
        self._book = self._assemble(meta, body)
        return self._book

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
        """Преобразовать PDF в файл FB2 и вернуть путь к результату.

        :param source: путь к .pdf или байты (иначе ``self.source``).
        :param output: путь к выходному ``.fb2``; по умолчанию — рядом с
            исходным ``.pdf`` (или ``book.fb2``, если источник — байты).
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

    # --- Открытие PDF ------------------------------------------------------
    @staticmethod
    def _open_reader(source: Union[str, Path, bytes]) -> PdfReader:
        """Открыть PDF-документ (путь или байты)."""
        if isinstance(source, bytes):
            stream: Union[str, io.BytesIO] = io.BytesIO(source)
        elif isinstance(source, (str, Path)):
            path = Path(source)
            if not path.is_file():
                raise Fb2ConversionError(f"PDF-файл не найден: {path}")
            stream = str(path)
        else:
            raise Fb2ConversionError(
                f"Неподдерживаемый тип источника: {type(source).__name__}"
            )
        try:
            return PdfReader(stream)
        except Exception as exc:  # noqa: BLE001 - pypdf поднимает разные ошибки
            raise Fb2ConversionError(f"Не удалось открыть PDF: {exc}") from exc

    # --- Извлечение текста -------------------------------------------------
    @staticmethod
    def _page_lines(page) -> List[_Line]:
        """Собрать строки страницы (текст + координаты + размер шрифта)."""
        fragments: List[Tuple[float, float, str, float]] = []

        def visitor(text, cm, tm, font_dict, font_size) -> None:
            if not text or not text.strip():
                return
            if cm is None:
                cm = (1.0, 0.0, 0.0, 1.0, 0.0, 0.0)
            x = tm[4] * cm[0] + tm[5] * cm[2] + cm[4]
            y = tm[4] * cm[1] + tm[5] * cm[3] + cm[5]
            fragments.append((y, x, text, float(font_size or 0.0)))

        try:
            page.extract_text(visitor_text=visitor)
        except Exception:  # noqa: BLE001 - повреждённые страницы не должны ронять конвертацию
            return []

        # Фрагменты одной визуальной строки объединяем (важно для OCR/сканов,
        # где текст приходит по словам/символам).
        fragments.sort(key=lambda frag: (-round(frag[0], 1), frag[1]))
        lines: List[_Line] = []
        current: List[str] = []
        cur_y: Optional[float] = None
        cur_x = 0.0
        cur_size = 0.0
        last_x = 0.0
        last_text = ""
        last_size = 0.0

        def flush() -> None:
            nonlocal current
            if current:
                text = " ".join(current).strip()
                if text:
                    lines.append(
                        _Line(text=text, x=cur_x, y=cur_y if cur_y is not None else 0.0, size=cur_size)
                    )
            current = []

        for y, x, text, size in fragments:
            cleaned = " ".join(text.split())
            if not cleaned:
                continue
            if cur_y is None or abs(y - cur_y) > _LINE_Y_TOLERANCE:
                flush()
                cur_y = y
                cur_x = x
                cur_size = size
            else:
                cur_size = max(cur_size, size)
            if current:
                approx_end = last_x + len(last_text) * last_size * 0.5
                if x - approx_end > max(1.0, size * 0.15):
                    current.append(cleaned)
                else:
                    current[-1] += cleaned
            else:
                current.append(cleaned)
            last_x = x
            last_text = cleaned
            last_size = size
        flush()
        return lines

    @staticmethod
    def _detect_body_size(pages_lines: Sequence[List[_Line]]) -> float:
        """Определить базовый (наиболее частый) размер шрифта."""
        counts: Dict[float, int] = {}
        for lines in pages_lines:
            for line in lines:
                key = round(line.size, 1)
                counts[key] = counts.get(key, 0) + 1
        if not counts:
            return 11.0
        return max(counts, key=lambda size: counts[size])

    def _detect_leading(self, pages_lines: Sequence[List[_Line]]) -> float:
        """Определить межстрочный интервал (наиболее частый вертикальный шаг)."""
        gaps: Dict[float, int] = {}
        for lines in pages_lines:
            for prev, cur in zip(lines, lines[1:]):
                gap = round(prev.y - cur.y, 1)
                if gap > 0:
                    gaps[gap] = gaps.get(gap, 0) + 1
        if not gaps:
            return self._body_size * 1.45
        return max(gaps, key=lambda gap: gaps[gap])

    @staticmethod
    def _read_metadata(reader: PdfReader) -> Dict[str, Any]:
        """Прочитать метаданные ``/Info`` (название и авторы)."""
        meta: Dict[str, Any] = {"title": None, "authors": []}
        try:
            info = reader.metadata
        except Exception:  # noqa: BLE001
            info = None
        if info is None:
            return meta
        title = (info.get("/Title") or "").strip()
        if title:
            meta["title"] = title
        author = (info.get("/Author") or "").strip()
        if author:
            meta["authors"] = [part.strip() for part in author.split(";") if part.strip()]
        return meta

    @staticmethod
    def _outline_entries(reader: PdfReader) -> List[Tuple[int, str, int]]:
        """Плоский список закладок: ``(уровень, заголовок, индекс страницы)``."""
        result: List[Tuple[int, str, int]] = []

        def walk(items, level: int) -> None:
            for item in items:
                if isinstance(item, list):
                    walk(item, level + 1)
                    continue
                title = (getattr(item, "title", None) or "").strip()
                if not title:
                    continue
                try:
                    page = reader.get_destination_page_number(item)
                except Exception:  # noqa: BLE001
                    page = 0
                result.append((level, title, int(page) if page is not None else 0))

        try:
            outline = reader.outline
        except Exception:  # noqa: BLE001
            return []
        walk(outline, 1)
        return result

    @staticmethod
    def _find_heading_y(lines: Sequence[_Line], title: str) -> Optional[float]:
        """Найти Y-координату строки заголовка на странице (или None)."""
        target = " ".join(title.split()).lower()
        if not target:
            return None
        best: Optional[float] = None
        for line in lines:
            norm = " ".join(line.text.split()).lower()
            if not norm:
                continue
            if norm == target or (len(norm) >= 4 and norm in target):
                if best is None or line.y > best:
                    best = line.y
        return best

    # --- Построение структуры ---------------------------------------------
    @staticmethod
    def _make_title_section(title: str) -> Section:
        """Секция с заголовком (без содержимого)."""
        return Section(
            title=Title(items=[Paragraph(content=[StyleNode(tag=TEXT_NODE, text=title)])])
        )

    def _finalize_body(self, root: Section) -> List[Section]:
        """Преобразовать корневую секцию в корректный список секций тела.

        FB2 не допускает одновременного наличия ``<section>`` и текста внутри
        одной секции, а также пустых секций, поэтому:

        * «висячий» текст (до первого заголовка) выносится в отдельную секцию;
        * у секций с подсекциями текст оборачивается в подсекцию;
        * пустые секции удаляются.
        """
        sections = list(root.sections)
        if root.content:
            sections.insert(0, Section(content=root.content))
        sections = self._normalize_sections(sections)
        if not sections:
            sections = [Section(content=[EmptyLine()])]
        return sections

    def _normalize_sections(self, sections: Sequence[Section]) -> List[Section]:
        """Рекурсивно привести секции к требованиям XSD FB2."""
        result: List[Section] = []
        for section in sections:
            section.sections = self._normalize_sections(section.sections)
            if section.content and section.sections:
                wrapper = Section(content=section.content)
                section.content = []
                section.sections.insert(0, wrapper)
            if not section.content and not section.sections:
                continue
            result.append(section)
        return result

    def _build_from_outline(
        self, entries: Sequence[Tuple[int, str, int]], pages_lines: Sequence[List[_Line]]
    ) -> Body:
        """Собрать тело по закладкам PDF (иерархия секций)."""
        body = Body()
        root = Section()
        stack: List[Tuple[int, Section]] = [(0, root)]
        anchors: List[_Anchor] = []

        for level, title, page in entries:
            while len(stack) > 1 and stack[-1][0] >= level:
                stack.pop()
            section = self._make_title_section(title)
            stack[-1][1].sections.append(section)
            stack.append((level, section))
            lines = pages_lines[page] if 0 <= page < len(pages_lines) else []
            y = self._find_heading_y(lines, title)
            anchors.append(
                _Anchor(page=page, y=(y if y is not None else math.inf), section=section)
            )

        self._fill_by_anchors(pages_lines, anchors)
        body.sections = self._finalize_body(root)
        return body

    def _fill_by_anchors(
        self, pages_lines: Sequence[List[_Line]], anchors: Sequence[_Anchor]
    ) -> None:
        """Разложить абзацы по секциям согласно началам закладок."""
        order = sorted(range(len(anchors)), key=lambda i: (anchors[i].page, -anchors[i].y))
        keys = [(anchors[i].page, -anchors[i].y) for i in order]
        sections = [anchors[i].section for i in order]

        target: Optional[Section] = None
        pending: List[_Line] = []

        def flush() -> None:
            if pending and target is not None:
                text = self._join_lines(pending)
                if text:
                    target.content.append(
                        Paragraph(content=[StyleNode(tag=TEXT_NODE, text=text)])
                    )
            pending.clear()

        for page_index, lines in enumerate(pages_lines):
            if not lines:
                continue
            base_x = min(line.x for line in lines)
            prev: Optional[_Line] = None
            for line in lines:
                if line.is_heading:
                    flush()
                    prev = None
                    continue
                section = self._active_section(keys, sections, page_index, line.y)
                if section is not None and section is not target:
                    flush()
                    target = section
                if target is None:
                    prev = line
                    continue
                if prev is not None:
                    self._emit_break(target, pending, prev, line, base_x, flush)
                pending.append(line)
                prev = line
            flush()
        flush()

    def _emit_break(
        self,
        target: Section,
        pending: List[_Line],
        prev: _Line,
        line: _Line,
        base_x: float,
        flush,
    ) -> None:
        """При необходимости завершить абзац и/или вставить ``<empty-line>``."""
        leading = self._leading or self._body_size * 1.45
        gap = prev.y - line.y
        if gap > leading * _EMPTY_LINE_GAP_RATIO:
            flush()
            target.content.append(EmptyLine())
        elif gap > leading * _PARAGRAPH_GAP_RATIO or line.x > base_x + _INDENT_THRESHOLD:
            flush()

    @staticmethod
    def _active_section(
        keys: Sequence[Tuple[int, float]],
        sections: Sequence[Section],
        page: int,
        y: float,
    ) -> Optional[Section]:
        """Секция, которой принадлежит строка ``(page, y)`` (или None)."""
        index = bisect.bisect_right(keys, (page, -y)) - 1
        if index < 0:
            return None
        return sections[index]

    def _build_from_headings(self, pages_lines: Sequence[List[_Line]]) -> Body:
        """Собрать тело без закладок: заголовки определяются по размеру шрифта."""
        body = Body()
        root = Section()
        sizes = sorted(
            {
                round(line.size, 1)
                for lines in pages_lines
                for line in lines
                if line.is_heading
            },
            reverse=True,
        )
        level_of = {size: index + 1 for index, size in enumerate(sizes)}

        stack: List[Tuple[int, Section]] = [(0, root)]
        target: Section = root
        pending: List[_Line] = []

        def flush() -> None:
            if pending:
                text = self._join_lines(pending)
                if text:
                    target.content.append(
                        Paragraph(content=[StyleNode(tag=TEXT_NODE, text=text)])
                    )
            pending.clear()

        for lines in pages_lines:
            if not lines:
                continue
            base_x = min(line.x for line in lines)
            prev: Optional[_Line] = None
            for line in lines:
                heading = (
                    line.is_heading
                    and self.detect_headings
                    and len(line.text) <= _MAX_HEADING_CHARS
                )
                if heading:
                    flush()
                    level = level_of.get(round(line.size, 1), 1)
                    while len(stack) > 1 and stack[-1][0] >= level:
                        stack.pop()
                    section = self._make_title_section(line.text)
                    stack[-1][1].sections.append(section)
                    stack.append((level, section))
                    target = section
                    prev = None
                    continue
                if prev is not None:
                    self._emit_break(target, pending, prev, line, base_x, flush)
                pending.append(line)
                prev = line
            flush()

        body.sections = self._finalize_body(root)
        return body

    @staticmethod
    def _join_lines(lines: Sequence[_Line]) -> str:
        """Склеить строки абзаца, убрав переносы слов."""
        result = ""
        for line in lines:
            text = line.text.strip()
            if not text:
                continue
            if not result:
                result = text
                continue
            if (
                result.endswith("-")
                and len(result) >= 2
                and result[-2].isalpha()
                and text[:1].islower()
            ):
                result = result[:-1] + text
            else:
                result = result + " " + text
        return result.strip()

    # --- Сборка FictionBook -----------------------------------------------
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

    def _assemble(self, meta: Dict[str, Any], body: Body) -> FictionBook:
        """Собрать корневую структуру FictionBook."""
        title = str(meta.get("title") or "Без названия")
        raw_authors = meta.get("authors") or []
        authors = [self._split_author(str(name)) for name in raw_authors]
        if not authors:
            # FB2 требует хотя бы одного <author> в <title-info>
            # (с обязательным first-name/nickname).
            authors = [Author(nickname="unknown")]

        title_info = TitleInfo(
            genres=[Genre(value=self.default_genre)],
            authors=authors,
            book_title=TextField(value=title),
            lang=self.lang,
        )
        document_info = DocumentInfo(
            authors=[Author(nickname=self.program_used)],
            program_used=TextField(value=self.program_used),
            date=DateField(value=date.today().isoformat()),
            id=uuid.uuid4().hex,
            version=1.0,
        )
        return FictionBook(
            description=Description(
                title_info=title_info,
                document_info=document_info,
            ),
            bodies=[body],
        )


__all__ = ["PdfToFb2Converter"]


def main(argv: List[str] | None = None) -> int:
    if argv is None:
        argv = sys.argv
    if len(argv) < 2:
        print(
            "Использование: python pdf_to_fb2.py <файл.pdf> [выход.fb2]",
            file=sys.stderr,
        )
        return 2
    source = argv[1]
    output = argv[2] if len(argv) > 2 else str(Path(source).with_suffix(".fb2"))
    converter = PdfToFb2Converter()
    path = converter.write(source, output)
    print("FB2:", path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))




