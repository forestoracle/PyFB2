"""Слияние и разбиение FB2-файлов.

Модуль предоставляет два класса:

    * :class:`Fb2Splitter` — разбиение одной книги на части:
      по главам (секциям), по размеру (байтам) или на N частей.
      Метаданные копируются, ``<document-info>/<id>`` обновляется,
      в ``<title-info>`` добавляется ``<sequence>`` с номером части,
      а ``<binary>`` — только фактически используемые в части.
    * :class:`Fb2Merger` — слияние нескольких книг в одну:
      объединение авторов/жанров, единый ``<body>`` (при желании
      с заголовком-обёрткой на каждую исходную книгу) и объединение
      ``<binary>`` с разрешением конфликтов ``id`` и перепривязкой ссылок.

Пример разбиения::

    >>> from fb2_split_merge import Fb2Splitter
    >>> splitter = Fb2Splitter(level=1)
    >>> splitter.split("book.fb2", out_dir="parts")
    [WindowsPath('parts/book_part01.fb2'), WindowsPath('parts/book_part02.fb2')]

Пример слияния::

    >>> from fb2_split_merge import Fb2Merger
    >>> merger = Fb2Merger(title="Сборник")
    >>> merger.merge_to_file(["a.fb2", "b.fb2"], "collection.fb2")
    WindowsPath('collection.fb2')

CLI::

    python fb2_split_merge.py split book.fb2 --out-dir parts --by sections
    python fb2_split_merge.py split book.fb2 --by size --max-size 300000
    python fb2_split_merge.py merge out.fb2 a.fb2 b.fb2 --title "Сборник"
"""

from __future__ import annotations

import argparse
import copy
import sys
import uuid
import xml.etree.ElementTree as ET
from datetime import date
from pathlib import Path
from typing import Callable, Dict, List, Optional, Sequence, Set, Tuple, Union

from .fb2_errors import Fb2ConversionError
from .fb2_parser import TEXT_NODE, Fb2Parser
from .fb2_structures import (
    NS_XLINK,
    Annotation,
    Author,
    Binary,
    Body,
    Cite,
    DateField,
    Description,
    DocumentInfo,
    Epigraph,
    FictionBook,
    Genre,
    Image,
    Paragraph,
    Poem,
    Section,
    Sequence as BookSequence,
    Stanza,
    StyleNode,
    Subtitle,
    Table,
    TextField,
    Title,
    TitleInfo,
)
from .fb2_xml import parse_xml
from .fb2_writer import Fb2Writer

#: Атрибут ``href`` в пространстве имён xlink.
XLINK_HREF = f"{{{NS_XLINK}}}href"

#: Шаблон имени файла части по умолчанию (доступны ``stem``, ``n``, ``total``).
DEFAULT_FILENAME_TEMPLATE = "{stem}_part{n:02d}.fb2"

#: Допустимые режимы разбиения.
SPLIT_MODES = ("sections", "size", "parts")

#: Коды возврата CLI.
EXIT_OK = 0
EXIT_ERRORS = 1
EXIT_USAGE = 2

#: Функция перепривязки ссылки (href -> href).
HrefMapper = Callable[[str], str]

#: Единица разбиения: (цепочка предков, секция).
SplitUnit = Tuple[List[Section], Section]

#: Группа единиц, попадающая в одну часть.
SplitGroup = List[SplitUnit]


# ---------------------------------------------------------------------------
# Обход ссылок на изображения (сбор и перепривязка <binary>)
# ---------------------------------------------------------------------------
def _map_markup(nodes: Sequence[StyleNode], mapper: HrefMapper) -> None:
    """Перепривязать inline-изображения в mixed-разметке."""
    for node in nodes:
        if node.tag == "image" and node.image_href:
            node.image_href = mapper(node.image_href)
        if node.children:
            _map_markup(node.children, mapper)


def _map_title(title: Optional[Title], mapper: HrefMapper) -> None:
    """Перепривязать изображения в заголовке."""
    if title is None:
        return
    for item in title.items:
        if isinstance(item, Paragraph):
            _map_markup(item.content, mapper)


def _map_stanza(stanza: Stanza, mapper: HrefMapper) -> None:
    """Перепривязать изображения в строфе."""
    _map_title(stanza.title, mapper)
    if stanza.subtitle is not None:
        _map_markup(stanza.subtitle.content, mapper)
    for verse in stanza.verses:
        _map_markup(verse.content, mapper)


def _map_poem(poem: Poem, mapper: HrefMapper) -> None:
    """Перепривязать изображения в стихотворении."""
    _map_title(poem.title, mapper)
    for epigraph in poem.epigraphs:
        _map_epigraph(epigraph, mapper)
    for item in poem.items:
        if isinstance(item, Stanza):
            _map_stanza(item, mapper)
        elif isinstance(item, Subtitle):
            _map_markup(item.content, mapper)
    for author in poem.text_author:
        _map_markup(author.content, mapper)


def _map_epigraph(epigraph: Epigraph, mapper: HrefMapper) -> None:
    """Перепривязать изображения в эпиграфе."""
    for item in epigraph.items:
        _map_block(item, mapper)
    for author in epigraph.text_author:
        _map_markup(author.content, mapper)


def _map_cite(cite: Cite, mapper: HrefMapper) -> None:
    """Перепривязать изображения в цитате."""
    for item in cite.items:
        _map_block(item, mapper)
    for author in cite.text_author:
        _map_markup(author.content, mapper)


def _map_table(table: Table, mapper: HrefMapper) -> None:
    """Перепривязать изображения в таблице."""
    for row in table.rows:
        for cell in row.cells:
            _map_markup(cell.children, mapper)


def _map_annotation(annotation: Optional[Annotation], mapper: HrefMapper) -> None:
    """Перепривязать изображения в аннотации."""
    if annotation is None:
        return
    for item in annotation.items:
        _map_block(item, mapper)


def _map_block(block, mapper: HrefMapper) -> None:
    """Перепривязать изображения в блочном элементе FB2."""
    if isinstance(block, (Paragraph, Subtitle)):
        _map_markup(block.content, mapper)
    elif isinstance(block, Image):
        if block.href:
            block.href = mapper(block.href)
    elif isinstance(block, Poem):
        _map_poem(block, mapper)
    elif isinstance(block, Cite):
        _map_cite(block, mapper)
    elif isinstance(block, Epigraph):
        _map_epigraph(block, mapper)
    elif isinstance(block, Table):
        _map_table(block, mapper)
    elif isinstance(block, Section):
        _map_section(block, mapper)


def _map_section(section: Section, mapper: HrefMapper) -> None:
    """Перепривязать изображения в секции (рекурсивно)."""
    _map_title(section.title, mapper)
    for epigraph in section.epigraphs:
        _map_epigraph(epigraph, mapper)
    if section.image is not None and section.image.href:
        section.image.href = mapper(section.image.href)
    _map_annotation(section.annotation, mapper)
    for block in section.content:
        _map_block(block, mapper)
    for child in section.sections:
        _map_section(child, mapper)


def _map_body(body: Body, mapper: HrefMapper) -> None:
    """Перепривязать изображения в теле книги (рекурсивно)."""
    if body.image is not None and body.image.href:
        body.image.href = mapper(body.image.href)
    _map_title(body.title, mapper)
    for epigraph in body.epigraphs:
        _map_epigraph(epigraph, mapper)
    for section in body.sections:
        _map_section(section, mapper)


def _map_title_info(title_info: Optional[TitleInfo], mapper: HrefMapper) -> None:
    """Перепривязать изображения обложки в ``<title-info>``."""
    if title_info is None or title_info.coverpage is None:
        return
    for image in title_info.coverpage.images:
        if image.href:
            image.href = mapper(image.href)


def _map_book_images(book: FictionBook, mapper: HrefMapper) -> None:
    """Перепривязать все ссылки на изображения в книге."""
    if book.description is not None:
        _map_title_info(book.description.title_info, mapper)
    for body in book.bodies:
        _map_body(body, mapper)


def _collector(target: Set[str]) -> HrefMapper:
    """Собрать id ссылок (``#id`` -> ``id``), не меняя значения."""

    def collect(href: str) -> str:
        if href.startswith("#"):
            target.add(href[1:])
        return href

    return collect


def _remapper(mapping: Dict[str, str]) -> HrefMapper:
    """Заменить ``#old`` на ``#new`` по словарю (остальное без изменений)."""

    def remap(href: str) -> str:
        if href.startswith("#"):
            new_id = mapping.get(href[1:])
            if new_id is not None:
                return f"#{new_id}"
        return href

    return remap


def _new_urn_uuid() -> str:
    """Новый идентификатор книги (``urn:uuid``)."""
    return f"urn:uuid:{uuid.uuid4()}"


def _today_field() -> DateField:
    """Поле даты с текущей датой."""
    today = date.today().isoformat()
    return DateField(value=today, date_value=today)


class Fb2Splitter:
    """Разбиение FB2-книги на части.

    :param parser: готовый :class:`~fb2_parser.Fb2Parser`.
    :param writer: готовый :class:`~fb2_writer.Fb2Writer`.
    :param level: глубина секций для нарезки (1 — секции верхнего уровня).
    :param by: режим: ``sections`` (по одной секции), ``size`` (по размеру
        в байтах), ``parts`` (на N примерно равных частей).
    :param max_size: предельный размер части в байтах (для ``by="size"``).
    :param parts: количество частей (для ``by="parts"``).
    :param title_suffix: суффикс названия части (``{n}``, ``{total}``),
        например ``" (часть {n})"``; пусто — название не меняется.
    :param add_sequence: добавлять ``<sequence>`` с номером части.
    :param update_id: обновлять ``<document-info>`` (id, версия, дата).
    :param copy_binaries: копировать в часть только используемые ``<binary>``.
    :param keep_extra_bodies: копировать дополнительные ``<body>`` (сноски).
    :param filename_template: шаблон имени файла (``stem``, ``n``, ``total``).
    """

    def __init__(
        self,
        parser: Optional[Fb2Parser] = None,
        writer: Optional[Fb2Writer] = None,
        level: int = 1,
        by: str = "sections",
        max_size: int = 0,
        parts: int = 0,
        title_suffix: str = "",
        add_sequence: bool = True,
        update_id: bool = True,
        copy_binaries: bool = True,
        keep_extra_bodies: bool = True,
        filename_template: str = DEFAULT_FILENAME_TEMPLATE,
    ) -> None:
        if by not in SPLIT_MODES:
            raise Fb2ConversionError(
                f"Неизвестный режим разбиения: {by!r} (ожидается {SPLIT_MODES})"
            )
        if by == "size" and max_size <= 0:
            raise Fb2ConversionError("Для by='size' требуется max_size > 0")
        if by == "parts" and parts <= 0:
            raise Fb2ConversionError("Для by='parts' требуется parts > 0")

        self.parser = parser if parser is not None else Fb2Parser()
        self.writer = writer if writer is not None else Fb2Writer()
        self.level = max(int(level), 1)
        self.by = by
        self.max_size = max_size
        self.parts = parts
        self.title_suffix = title_suffix
        self.add_sequence = add_sequence
        self.update_id = update_id
        self.copy_binaries = copy_binaries
        self.keep_extra_bodies = keep_extra_bodies
        self.filename_template = filename_template

    # --- Публичный API -----------------------------------------------------
    def split(
        self,
        source,
        out_dir: Optional[Union[str, Path]] = None,
        stem: Optional[str] = None,
    ) -> List[Path]:
        """Разбить FB2 и записать части в каталог.

        :param source: путь к FB2 (или file-like объект / ``ET.Element``).
        :param out_dir: каталог для частей (по умолчанию рядом с исходником).
        :param stem: основа имени файла (по умолчанию имя исходника).
        :return: список путей к записанным частям.
        """
        if stem is None:
            stem = Path(source).stem if isinstance(source, (str, Path)) else "book"
        if out_dir is None:
            out_dir = (
                Path(source).parent if isinstance(source, (str, Path)) else Path(".")
            )
        target_dir = Path(out_dir)
        target_dir.mkdir(parents=True, exist_ok=True)

        paths: List[Path] = []
        for name, book in self.split_book(source, stem=stem):
            path = target_dir / name
            self.writer.write(book, path)
            paths.append(path)
        return paths

    def split_book(
        self, source, stem: str = "book"
    ) -> List[Tuple[str, FictionBook]]:
        """Разбить книгу и вернуть список пар (имя файла, книга)."""
        book = self._read_book(source)
        units = self._collect_units(book)
        if not units:
            return []

        groups = self._group_units(units)
        total = len(groups)
        result: List[Tuple[str, FictionBook]] = []
        for number, group in enumerate(groups, 1):
            part = self._build_part(book, group, number, total)
            name = self.filename_template.format(stem=stem, n=number, total=total)
            result.append((name, part))
        return result

    # --- Чтение ------------------------------------------------------------
    def _read_book(self, source) -> FictionBook:
        """Разобрать источник в структуру :class:`FictionBook`."""
        root = self._root(source)
        parser = self.parser
        return FictionBook(
            stylesheets=parser.parse_stylesheets(root),
            description=parser.parse(root),
            bodies=parser.parse_bodies(root),
            binaries=parser.parse_binaries(root),
        )

    @staticmethod
    def _root(source) -> ET.Element:
        """Вернуть корневой элемент документа."""
        if isinstance(source, ET.Element):
            return source
        return parse_xml(source)

    # --- Нарезка на единицы ------------------------------------------------
    def _collect_units(self, book: FictionBook) -> List[SplitUnit]:
        """Собрать единицы разбиения из основного ``<body>``."""
        if not book.bodies:
            return []
        return self._walk_sections(book.bodies[0].sections, self.level, [])

    def _walk_sections(
        self, sections: Sequence[Section], level: int, ancestors: List[Section]
    ) -> List[SplitUnit]:
        """Рекурсивно собрать секции заданного уровня.

        Если у секции нет вложенных (уровень не достигнут), берётся она сама,
        поэтому данные никогда не теряются.
        """
        units: List[SplitUnit] = []
        for section in sections:
            if level <= 1 or not section.sections:
                units.append((list(ancestors), section))
            else:
                units.extend(
                    self._walk_sections(
                        section.sections, level - 1, ancestors + [section]
                    )
                )
        return units

    def _group_units(self, units: Sequence[SplitUnit]) -> List[SplitGroup]:
        """Сгруппировать единицы в части согласно выбранному режиму."""
        if self.by == "sections":
            return [[unit] for unit in units]
        if self.by == "size":
            return self._group_by_size(units)
        return self._group_by_parts(units)

    def _group_by_size(self, units: Sequence[SplitUnit]) -> List[SplitGroup]:
        """Собирать части, пока их размер не превышает ``max_size``."""
        groups: List[SplitGroup] = []
        current: SplitGroup = []
        current_size = 0
        for unit in units:
            size = self._unit_size(unit)
            if current and current_size + size > self.max_size:
                groups.append(current)
                current = []
                current_size = 0
            current.append(unit)
            current_size += size
        if current:
            groups.append(current)
        return groups

    def _group_by_parts(self, units: Sequence[SplitUnit]) -> List[SplitGroup]:
        """Разбить единицы на ``self.parts`` примерно равных частей."""
        sizes = [self._unit_size(unit) for unit in units]
        total_size = sum(sizes) or 1
        target = total_size / self.parts

        groups: List[SplitGroup] = []
        current: SplitGroup = []
        current_size = 0
        for unit, size in zip(units, sizes):
            current.append(unit)
            current_size += size
            if len(groups) < self.parts - 1 and current_size >= target:
                groups.append(current)
                current = []
                current_size = 0
        if current:
            groups.append(current)
        return groups

    def _unit_size(self, unit: SplitUnit) -> int:
        """Оценка размера единицы в байтах (по XML-представлению)."""
        ancestors, section = unit
        book = FictionBook(bodies=[Body(sections=[self._skeleton(ancestors, section)])])
        element = self.writer.to_element(book)
        return len(ET.tostring(element, encoding="utf-8"))

    @staticmethod
    def _skeleton(ancestors: Sequence[Section], section: Section) -> Section:
        """Копия секции вместе с цепочкой предков (только ветка к ней)."""
        node = copy.deepcopy(section)
        for ancestor in reversed(ancestors):
            shell = copy.deepcopy(ancestor)
            shell.sections = [node]
            node = shell
        return node

    # --- Сборка части ------------------------------------------------------
    def _build_part(
        self, book: FictionBook, group: SplitGroup, number: int, total: int
    ) -> FictionBook:
        """Собрать одну часть из группы единиц."""
        description = copy.deepcopy(book.description)
        self._update_title_info(description, number, total)
        self._update_document_info(description)

        bodies: List[Body] = []
        if book.bodies:
            bodies.append(self._part_body(book.bodies[0], group))
        if self.keep_extra_bodies:
            bodies.extend(copy.deepcopy(body) for body in book.bodies[1:])

        binaries = self._part_binaries(book, description, bodies)
        return FictionBook(
            stylesheets=copy.deepcopy(book.stylesheets),
            description=description,
            bodies=bodies,
            binaries=binaries,
        )

    def _part_body(self, source_body: Body, group: SplitGroup) -> Body:
        """Тело части: заголовок/эпиграфы книги + выбранные секции."""
        body = Body(
            image=copy.deepcopy(source_body.image),
            title=copy.deepcopy(source_body.title),
            epigraphs=copy.deepcopy(source_body.epigraphs),
            name=source_body.name,
            lang=source_body.lang,
        )
        body.sections = [
            self._skeleton(ancestors, section) for ancestors, section in group
        ]
        return body

    def _update_title_info(
        self, description, number: int, total: int
    ) -> None:
        """Обновить название и серию части."""
        if description is None or description.title_info is None:
            return
        title_info = description.title_info
        base = title_info.book_title.value if title_info.book_title else ""

        if self.title_suffix:
            suffix = self.title_suffix.format(n=number, total=total)
            title_info.book_title = TextField(value=f"{base}{suffix}")

        if self.add_sequence and base:
            title_info.sequences.append(BookSequence(name=base, number=number))

    def _update_document_info(self, description) -> None:
        """Обновить ``<document-info>`` части."""
        if description is None:
            return
        if description.document_info is None:
            description.document_info = DocumentInfo()
        info = description.document_info
        if self.update_id:
            info.id = _new_urn_uuid()
            info.version = 1.0
            info.date = _today_field()
        if info.program_used is None:
            info.program_used = TextField(value="pyFB2 Fb2Splitter")

    def _part_binaries(
        self, book: FictionBook, description, bodies: Sequence[Body]
    ) -> List[Binary]:
        """Оставить только те ``<binary>``, на которые есть ссылки."""
        if not self.copy_binaries:
            return []

        used: Set[str] = set()
        collect = _collector(used)
        if description is not None:
            _map_title_info(description.title_info, collect)
        for body in bodies:
            _map_body(body, collect)

        return [
            copy.deepcopy(binary) for binary in book.binaries if binary.id in used
        ]


class Fb2Merger:
    """Слияние нескольких FB2-книг в одну.

    :param parser: готовый :class:`~fb2_parser.Fb2Parser`.
    :param writer: готовый :class:`~fb2_writer.Fb2Writer`.
    :param title: название итоговой книги (по умолчанию — из первой книги).
    :param combine_metadata: объединять авторов и жанры всех книг.
    :param add_source_titles: оборачивать секции каждой книги в секцию
        с заголовком (названием исходной книги).
    :param merge_binaries: объединять ``<binary>`` с перепривязкой ссылок
        при конфликтах ``id``.
    :param update_id: формировать новый ``<document-info>`` (id, версия, дата).
    """

    def __init__(
        self,
        parser: Optional[Fb2Parser] = None,
        writer: Optional[Fb2Writer] = None,
        title: Optional[str] = None,
        combine_metadata: bool = True,
        add_source_titles: bool = True,
        merge_binaries: bool = True,
        update_id: bool = True,
    ) -> None:
        self.parser = parser if parser is not None else Fb2Parser()
        self.writer = writer if writer is not None else Fb2Writer()
        self.title = title
        self.combine_metadata = combine_metadata
        self.add_source_titles = add_source_titles
        self.merge_binaries = merge_binaries
        self.update_id = update_id

    # --- Публичный API -----------------------------------------------------
    def merge(self, sources: Sequence) -> FictionBook:
        """Слить книги в одну структуру :class:`FictionBook`.

        :param sources: последовательность путей/file-like/``ET.Element``.
        :raises ValueError: если список источников пуст.
        """
        books = [self._read_book(source) for source in sources]
        if not books:
            raise Fb2ConversionError("Не задано ни одной книги для слияния")

        # Порядок важен: сначала перепривязка <binary> (мутирует книги),
        # затем копирование секций и метаданных в итоговую книгу.
        binaries = self._merge_binaries(books) if self.merge_binaries else []
        bodies = [self._merge_bodies(books)]
        description = self._merge_description(books)
        return FictionBook(description=description, bodies=bodies, binaries=binaries)

    def merge_to_file(self, sources: Sequence, output: Union[str, Path]) -> Path:
        """Слить книги и записать результат в файл."""
        return self.writer.write(self.merge(sources), Path(output))

    def write(self, sources: Sequence, output: Union[str, Path]) -> Path:
        """Синоним :meth:`merge_to_file`."""
        return self.merge_to_file(sources, output)

    # --- Чтение ------------------------------------------------------------
    def _read_book(self, source) -> FictionBook:
        """Разобрать источник в структуру :class:`FictionBook`."""
        root = Fb2Splitter._root(source)
        parser = self.parser
        return FictionBook(
            stylesheets=parser.parse_stylesheets(root),
            description=parser.parse(root),
            bodies=parser.parse_bodies(root),
            binaries=parser.parse_binaries(root),
        )

    # --- Метаданные --------------------------------------------------------
    def _merge_description(self, books: Sequence[FictionBook]) -> Description:
        """Собрать описание итоговой книги."""
        description = Description()
        description.title_info = self._merge_title_info(books)
        description.document_info = self._new_document_info(books)
        return description

    def _merge_title_info(self, books: Sequence[FictionBook]) -> TitleInfo:
        """Объединить ``<title-info>`` всех книг."""
        infos = [
            book.description.title_info
            for book in books
            if book.description is not None and book.description.title_info is not None
        ]
        title_info = TitleInfo()
        if not infos:
            title_info.book_title = TextField(value=self.title or "Untitled")
            title_info.lang = "ru"
            return title_info

        first = infos[0]
        base_title = first.book_title.value if first.book_title else "Untitled"
        title_info.book_title = TextField(value=self.title or base_title)
        title_info.lang = first.lang or "ru"
        if first.coverpage is not None:
            title_info.coverpage = copy.deepcopy(first.coverpage)
        if first.annotation is not None:
            title_info.annotation = copy.deepcopy(first.annotation)

        if self.combine_metadata:
            title_info.authors = self._merge_authors(infos)
            title_info.genres = self._merge_genres(infos)
        else:
            title_info.authors = copy.deepcopy(first.authors)
            title_info.genres = copy.deepcopy(first.genres)

        # Схема требует минимум одного автора и один жанр.
        if not title_info.authors:
            title_info.authors = [Author(nickname="Неизвестный автор")]
        if not title_info.genres:
            title_info.genres = [Genre(value="prose")]
        return title_info

    def _merge_authors(self, infos: Sequence[TitleInfo]) -> List[Author]:
        """Объединить авторов без повторов (порядок сохраняется)."""
        result: List[Author] = []
        seen: Set[str] = set()
        for info in infos:
            for author in info.authors:
                key = self._author_key(author)
                if key and key not in seen:
                    seen.add(key)
                    result.append(copy.deepcopy(author))
        return result

    @staticmethod
    def _author_key(author: Author) -> str:
        """Ключ автора для дедупликации."""
        parts = [
            author.first_name,
            author.middle_name,
            author.last_name,
            author.nickname,
        ]
        return "|".join(part or "" for part in parts).strip("|")

    @staticmethod
    def _merge_genres(infos: Sequence[TitleInfo]) -> List[Genre]:
        """Объединить жанры без повторов."""
        result: List[Genre] = []
        seen: Set[str] = set()
        for info in infos:
            for genre in info.genres:
                if genre.value and genre.value not in seen:
                    seen.add(genre.value)
                    result.append(copy.deepcopy(genre))
        return result

    def _new_document_info(self, books: Sequence[FictionBook]) -> DocumentInfo:
        """Сформировать ``<document-info>`` итоговой книги."""
        source_info = None
        for book in books:
            if (
                book.description is not None
                and book.description.document_info is not None
            ):
                source_info = book.description.document_info
                break

        info = DocumentInfo()
        if self.update_id or source_info is None:
            info.id = _new_urn_uuid()
            info.version = 1.0
            info.date = _today_field()
        else:
            info.id = source_info.id or _new_urn_uuid()
            info.version = source_info.version
            info.date = copy.deepcopy(source_info.date)

        info.program_used = TextField(value="pyFB2 Fb2Merger")
        if source_info is not None and source_info.authors:
            info.authors = copy.deepcopy(source_info.authors)
        else:
            info.authors = [Author(nickname="pyFB2")]
        return info

    # --- Тело книги --------------------------------------------------------
    def _merge_bodies(self, books: Sequence[FictionBook]) -> Body:
        """Собрать единое ``<body>`` из секций всех книг."""
        body = Body()
        for book in books:
            if not book.bodies:
                continue
            sections = [
                copy.deepcopy(section) for section in book.bodies[0].sections
            ]
            if not sections:
                continue
            if self.add_source_titles:
                body.sections.append(
                    self._wrap_sections(self._book_title(book), sections)
                )
            else:
                body.sections.extend(sections)
        return body

    @staticmethod
    def _book_title(book: FictionBook) -> str:
        """Название книги (или запасной вариант)."""
        info = book.description.title_info if book.description else None
        if info is not None and info.book_title is not None and info.book_title.value:
            return info.book_title.value
        return "Без названия"

    @staticmethod
    def _wrap_sections(title_text: str, sections: List[Section]) -> Section:
        """Обернуть секции книги в секцию с заголовком."""
        title = Title(
            items=[Paragraph(content=[StyleNode(tag=TEXT_NODE, text=title_text)])]
        )
        return Section(title=title, sections=sections)

    # --- Изображения -------------------------------------------------------
    def _merge_binaries(self, books: Sequence[FictionBook]) -> List[Binary]:
        """Объединить ``<binary>``, разрешив конфликты ``id``.

        При совпадении ``id`` новому ресурсу присваивается ``id_N``, а ссылки
        на него в тексте перепривязываются.
        """
        binaries: List[Binary] = []
        used_ids: Set[str] = set()

        for book in books:
            mapping: Dict[str, str] = {}
            for binary in book.binaries:
                original = binary.id or ""
                new_id = original or f"binary{len(binaries) + 1}"
                counter = 2
                while new_id in used_ids:
                    new_id = f"{original}_{counter}"
                    counter += 1
                used_ids.add(new_id)
                if original and new_id != original:
                    mapping[original] = new_id
                clone = copy.deepcopy(binary)
                clone.id = new_id
                binaries.append(clone)

            if mapping:
                remap = _remapper(mapping)
                if book.description is not None:
                    _map_title_info(book.description.title_info, remap)
                for body in book.bodies:
                    _map_body(body, remap)

        return binaries


__all__ = ["Fb2Splitter", "Fb2Merger"]


def split_main(argv: Optional[List[str]] = None) -> int:
    """Точка входа CLI разбиения (``pyfb2-split``)."""
    parser = argparse.ArgumentParser(
        prog="pyfb2-split",
        description="Разбиение FB2 на части (по главам, размеру или на N частей).",
    )
    parser.add_argument("source", help="исходный FB2-файл")
    parser.add_argument("-o", "--out-dir", default=None, help="каталог для частей")
    parser.add_argument("--stem", default=None, help="основа имени файла части")
    parser.add_argument(
        "--by", choices=SPLIT_MODES, default="sections", help="режим разбиения"
    )
    parser.add_argument(
        "--level", type=int, default=1, help="глубина секций для нарезки"
    )
    parser.add_argument(
        "--max-size", type=int, default=0, help="предельный размер части (байты)"
    )
    parser.add_argument("--parts", type=int, default=0, help="число частей")
    parser.add_argument(
        "--title-suffix",
        default="",
        help="суффикс названия части, например ' (часть {n})'",
    )
    parser.add_argument(
        "--no-sequence", action="store_true", help="не добавлять <sequence>"
    )
    parser.add_argument(
        "--keep-ids", action="store_true", help="не обновлять <document-info>"
    )
    args = parser.parse_args(argv)

    try:
        splitter = Fb2Splitter(
            level=args.level,
            by=args.by,
            max_size=args.max_size,
            parts=args.parts,
            title_suffix=args.title_suffix,
            add_sequence=not args.no_sequence,
            update_id=not args.keep_ids,
        )
    except ValueError as exc:
        print(f"Ошибка: {exc}", file=sys.stderr)
        return EXIT_USAGE

    try:
        paths = splitter.split(args.source, out_dir=args.out_dir, stem=args.stem)
    except (OSError, ET.ParseError, ValueError) as exc:
        print(f"Ошибка: {exc}", file=sys.stderr)
        return EXIT_ERRORS

    if not paths:
        print("Не найдено секций для разбиения.", file=sys.stderr)
        return EXIT_ERRORS
    for path in paths:
        print(path)
    print(f"Частей: {len(paths)}", file=sys.stderr)
    return EXIT_OK


def merge_main(argv: Optional[List[str]] = None) -> int:
    """Точка входа CLI слияния (``pyfb2-merge``)."""
    parser = argparse.ArgumentParser(
        prog="pyfb2-merge",
        description="Слияние нескольких FB2 в одну книгу.",
    )
    parser.add_argument("output", help="выходной FB2-файл")
    parser.add_argument("sources", nargs="+", help="исходные FB2-файлы")
    parser.add_argument("--title", default=None, help="название итоговой книги")
    parser.add_argument(
        "--no-source-titles",
        action="store_true",
        help="не добавлять заголовки исходных книг",
    )
    parser.add_argument(
        "--keep-metadata",
        action="store_true",
        help="не объединять авторов/жанры (взять из первой книги)",
    )
    parser.add_argument(
        "--no-binaries", action="store_true", help="не объединять <binary>"
    )
    args = parser.parse_args(argv)

    merger = Fb2Merger(
        title=args.title,
        combine_metadata=not args.keep_metadata,
        add_source_titles=not args.no_source_titles,
        merge_binaries=not args.no_binaries,
    )
    try:
        path = merger.merge_to_file(args.sources, args.output)
    except (OSError, ET.ParseError, ValueError) as exc:
        print(f"Ошибка: {exc}", file=sys.stderr)
        return EXIT_ERRORS
    print(path)
    return EXIT_OK


def main(argv: Optional[List[str]] = None) -> int:
    """Общая точка входа: подкоманда ``split`` или ``merge``."""
    if argv is None:
        argv = sys.argv[1:]
    if not argv or argv[0] not in ("split", "merge"):
        print(
            "Использование: python fb2_split_merge.py {split|merge} ...",
            file=sys.stderr,
        )
        return EXIT_USAGE
    command, rest = argv[0], argv[1:]
    if command == "split":
        return split_main(rest)
    return merge_main(rest)


if __name__ == "__main__":
    raise SystemExit(main())

