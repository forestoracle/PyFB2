# -*- coding: utf-8 -*-
"""Простановка автора FB2 по имени каталога.

Скрипт читает все подкаталоги первого уровня указанного каталога (по
умолчанию — текущего). Каждый такой подкаталог считается именем автора;
имя разбирается по пробелам:

* два компонента — ``Фамилия Имя``;
* три компонента — ``Фамилия Имя Отчество``.

Всем FB2-файлам, лежащим в подкаталоге (и ниже по иерархии), в
``<description>/<title-info>/<author>`` записываются ``<last-name>``,
``<first-name>`` и (если в имени каталога есть третье слово)
``<middle-name>``. Прочие поля автора (``nickname``, ``home-page``,
``email``, ``id``) и всё остальное содержимое файла не меняются.

Файлы, где авторов несколько (в ``<title-info>`` больше одного
``<author>``), не трогаются: у них уже своё, осмысленное авторство.
Если автора в файле нет вовсе — элемент ``<author>`` добавляется.

Особенности:

* файл переписывается средствами lxml, но с сохранением исходной кодировки
  (в том числе ``windows-1251``), DOCTYPE, комментариев и секций CDATA;
  если объявления ``<?xml encoding=...?>`` в файле не было, а содержимое
  прочитано как ``windows-1251``, объявление добавляется (файл становится
  самодокументированным);
* ``<middle-name>`` при двухкомпонентном имени каталога по умолчанию
  сохраняется (вдруг в книге отчество указано верно) — удалить его можно
  ключом ``--clear-middle-name``;
* порядок полей внутри ``<author>`` приводится к порядку из XSD
  (``first-name``, ``middle-name``, ``last-name``, ``nickname``, ...);
* запись атомарная (через временный файл), при желании с резервной копией
  ``*.bak`` (``--backup``).

CLI::

    python fb2_author_from_dir.py [каталог] [--dry-run] [--backup]
        [--clear-middle-name] [-v|--verbose]

Пример: библиотека лежит в ``D:\\Books``, подкаталоги — имена авторов::

    python fb2_author_from_dir.py D:\\Books --dry-run -v   # посмотреть план
    python fb2_author_from_dir.py D:\\Books --backup       # применить
"""

from __future__ import annotations

import argparse
import logging
import os
import shutil
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterator, List, Optional, Tuple

from lxml import etree

#: Расширение FB2-файлов (сравнивается без учёта регистра).
FB2_SUFFIX = ".fb2"

#: Кодировка, в которой пробуем прочитать файл без объявления ``<?xml?>``.
ENCODING_FALLBACK = "windows-1251"

#: Порядок полей authorType по XSD (нужен для вставки в правильное место).
AUTHOR_FIELDS = (
    "first-name",
    "middle-name",
    "last-name",
    "nickname",
    "home-page",
    "email",
    "id",
)
AUTHOR_FIELD_ORDER = {name: index for index, name in enumerate(AUTHOR_FIELDS)}

#: Исходы обработки одного файла.
STATUS_UPDATED = "updated"
STATUS_UNCHANGED = "unchanged"
STATUS_MULTIPLE = "multiple"

logger = logging.getLogger(__name__)


class Fb2MetadataError(ValueError):
    """В FB2 нет ожидаемых метаданных (``<description>``/``<title-info>``)."""


@dataclass(frozen=True)
class AuthorName:
    """Имя автора, разобранное из имени каталога.

    :param last_name: фамилия (первое слово);
    :param first_name: имя (второе слово);
    :param middle_name: отчество (третье слово; может отсутствовать).
    """

    last_name: str
    first_name: str
    middle_name: str = ""

    @classmethod
    def parse(cls, value: str) -> "AuthorName":
        """Разобрать имя автора из строки ``Фамилия Имя [Отчество]``.

        :param value: имя каталога (лишние пробелы допускаются).
        :return: разобранное имя автора.
        :raises ValueError: если слов не два и не три.
        """
        parts = value.split()
        if len(parts) not in (2, 3):
            raise ValueError(
                "ожидается 2 или 3 слова (Фамилия Имя [Отчество]), "
                f"а получено {len(parts)}: {value!r}"
            )
        return cls(
            last_name=parts[0],
            first_name=parts[1],
            middle_name=parts[2] if len(parts) == 3 else "",
        )

    def __str__(self) -> str:
        """Имя для вывода: непустые компоненты через пробел."""
        parts = (self.last_name, self.first_name, self.middle_name)
        return " ".join(part for part in parts if part)


# ---------------------------------------------------------------------------
# Работа с XML (пространство имён FB2 может отсутствовать или быть любым)
# ---------------------------------------------------------------------------
def _local_name(tag: object) -> str:
    """Локальное имя тега без префикса пространства имён."""
    if not isinstance(tag, str):
        return ""
    return tag.rsplit("}", 1)[-1]


def _namespace(element: etree._Element) -> str:
    """URI пространства имён элемента ("" — если его нет)."""
    tag = element.tag
    if isinstance(tag, str) and tag.startswith("{"):
        return tag[1:].split("}", 1)[0]
    return ""


def _qualified_name(namespace: str, local: str) -> str:
    """Полное имя тега в заданном пространстве имён."""
    return f"{{{namespace}}}{local}" if namespace else local


def _find_child(element: etree._Element, name: str) -> Optional[etree._Element]:
    """Первый дочерний элемент с локальным именем ``name``."""
    for child in element:
        if _local_name(child.tag) == name:
            return child
    return None


def _find_children(element: etree._Element, name: str) -> List[etree._Element]:
    """Все дочерние элементы с локальным именем ``name``."""
    return [child for child in element if _local_name(child.tag) == name]


def _xml_parser(encoding: Optional[str] = None) -> etree.XMLParser:
    """Парсер XML, безопасный для недоверенных FB2-файлов.

    :param encoding: принудительная кодировка (для файлов без объявления).
    """
    return etree.XMLParser(
        resolve_entities=False,  # не раскрывать сущности (защита от DTD-бомб)
        load_dtd=False,
        no_network=True,
        strip_cdata=False,       # сохранить секции CDATA как есть
        huge_tree=True,          # книги с крупными <binary>
        encoding=encoding,
    )


def _load(path: Path) -> Tuple[etree._ElementTree, Optional[str]]:
    """Прочитать FB2-файл в дерево lxml.

    :param path: путь к файлу.
    :return: пара (дерево, кодировка-подстановка). Кодировка-подстановка
        заполнена, только если файл пришлось читать как ``windows-1251``
        (нет объявления ``<?xml encoding=...?>``).
    :raises lxml.etree.XMLSyntaxError: если файл не является корректным XML.
    :raises OSError: если файл не удалось прочитать.
    """
    data = path.read_bytes()
    try:
        return etree.ElementTree(etree.fromstring(data, _xml_parser())), None
    except etree.XMLSyntaxError as exc:
        # Вероятно, файл в windows-1251 и без объявления кодировки.
        try:
            tree = etree.ElementTree(etree.fromstring(data, _xml_parser(ENCODING_FALLBACK)))
        except etree.XMLSyntaxError:
            raise exc from None
        return tree, ENCODING_FALLBACK


def _dump(tree: etree._ElementTree, fallback_encoding: Optional[str]) -> bytes:
    """Сериализовать дерево в байты, сохранив кодировку и DOCTYPE.

    DOCTYPE (вместе с внутренним поднабором) lxml выводит сам; параметр
    ``doctype`` передавать нельзя — иначе поднабор с объявлениями сущностей
    теряется и файл перестаёт разбираться.

    :param tree: дерево документа.
    :param fallback_encoding: кодировка для файлов без объявления
        ``<?xml encoding=...?>``.
    """
    encoding = fallback_encoding or tree.docinfo.encoding
    return etree.tostring(
        tree,
        encoding=encoding or "utf-8",
        xml_declaration=bool(encoding),
        pretty_print=False,
    )


def _field_position(author: etree._Element, name: str) -> int:
    """Позиция для вставки поля ``name`` с учётом порядка authorType.

    :param author: элемент ``<author>``.
    :param name: локальное имя вставляемого поля.
    :return: индекс, по которому поле нужно вставить.
    """
    order = AUTHOR_FIELD_ORDER[name]
    for index, child in enumerate(author):
        child_order = AUTHOR_FIELD_ORDER.get(_local_name(child.tag), len(AUTHOR_FIELDS))
        if child_order > order:
            return index
    return len(author)


def _remove_field(author: etree._Element, name: str) -> bool:
    """Удалить поле ``name`` из ``<author>``, сохранив отступы.

    :return: True, если поле было и удалено.
    """
    existing = _find_child(author, name)
    if existing is None:
        return False
    previous = existing.getprevious()
    if previous is None:
        author.text = existing.tail
    else:
        previous.tail = existing.tail
    author.remove(existing)
    return True


def _set_field(author: etree._Element, name: str, value: str) -> bool:
    """Записать текстовое поле в ``<author>``.

    :param author: элемент ``<author>``.
    :param name: локальное имя поля (``first-name`` и т. п.).
    :param value: значение; пустое значение удаляет поле.
    :return: True, если документ изменился.
    """
    value = value.strip()
    if not value:
        return _remove_field(author, name)
    existing = _find_child(author, name)
    if existing is not None:
        if (existing.text or "").strip() == value:
            return False
        existing.text = value
        return True
    element = etree.Element(_qualified_name(_namespace(author), name))
    element.text = value
    author.insert(_field_position(author, name), element)
    return True


def _insert_author(title_info: etree._Element) -> etree._Element:
    """Добавить пустой ``<author>`` в ``<title-info>``.

    По XSD в ``<title-info>`` сначала идут ``<genre>``, затем ``<author>``,
    поэтому новый автор ставится после последнего жанра.

    :param title_info: элемент ``<title-info>``.
    :return: созданный элемент ``<author>``.
    """
    author = etree.Element(_qualified_name(_namespace(title_info), "author"))
    position = 0
    for index, child in enumerate(title_info):
        if _local_name(child.tag) == "genre":
            position = index + 1
    if position:
        # «Хвост» (отступ) — как у элемента, после которого вставляем.
        author.tail = title_info[position - 1].tail
    else:
        author.tail = title_info.text
    title_info.insert(position, author)
    return author


def _reorder_fields(author: etree._Element) -> bool:
    """Привести порядок полей ``<author>`` к порядку из XSD.

    Поля ``first-name``, ``middle-name``, ``last-name``, ``nickname``,
    ``home-page``, ``email``, ``id`` переставляются в предписанном схемой
    порядке; посторонние элементы остаются на своих местах.

    :param author: элемент ``<author>``.
    :return: True, если порядок пришлось изменить.
    """
    children = list(author)
    known = [child for child in children if _local_name(child.tag) in AUTHOR_FIELD_ORDER]
    ordered = sorted(known, key=lambda child: AUTHOR_FIELD_ORDER[_local_name(child.tag)])
    if known == ordered:
        return False
    replacement = iter(ordered)
    new_children = [
        next(replacement) if _local_name(child.tag) in AUTHOR_FIELD_ORDER else child
        for child in children
    ]
    for child in children:
        author.remove(child)
    for child in new_children:
        author.append(child)
    return True


def apply_author(
    tree: etree._ElementTree,
    name: AuthorName,
    clear_middle_name: bool = False,
) -> str:
    """Записать имя автора в ``<title-info>`` документа.

    :param tree: дерево FB2-документа (изменяется на месте).
    :param name: имя автора, полученное из имени каталога.
    :param clear_middle_name: удалять ``<middle-name>``, если отчества
        в имени каталога нет.
    :return: один из статусов ``STATUS_UPDATED``, ``STATUS_UNCHANGED``,
        ``STATUS_MULTIPLE``.
    :raises Fb2MetadataError: если в файле нет ``<description>`` или
        ``<title-info>`` (править нечего).
    """
    description = _find_child(tree.getroot(), "description")
    if description is None:
        raise Fb2MetadataError("нет <description>")
    title_info = _find_child(description, "title-info")
    if title_info is None:
        raise Fb2MetadataError("нет <description>/<title-info>")

    authors = _find_children(title_info, "author")
    if len(authors) > 1:
        return STATUS_MULTIPLE

    author = authors[0] if authors else _insert_author(title_info)
    changed = False
    if _set_field(author, "last-name", name.last_name):
        changed = True
    if _set_field(author, "first-name", name.first_name):
        changed = True
    if name.middle_name:
        if _set_field(author, "middle-name", name.middle_name):
            changed = True
    elif clear_middle_name and _remove_field(author, "middle-name"):
        changed = True
    if _reorder_fields(author):
        changed = True
    return STATUS_UPDATED if changed else STATUS_UNCHANGED


# ---------------------------------------------------------------------------
# Файловые операции
# ---------------------------------------------------------------------------
def _backup_path(path: Path) -> Path:
    """Путь резервной копии рядом с файлом: ``book.fb2`` -> ``book.fb2.bak``."""
    return path.with_name(path.name + ".bak")


def _write_atomic(path: Path, data: bytes) -> None:
    """Записать файл через временный, чтобы не оставить его обрезанным.

    :param path: целевой файл.
    :param data: новые байты файла.
    """
    tmp = path.with_name(path.name + ".tmp")
    try:
        tmp.write_bytes(data)
        os.replace(tmp, path)
    finally:
        if tmp.exists():
            try:
                tmp.unlink()
            except OSError:  # pragma: no cover — временный файл уже не нужен
                pass


# ---------------------------------------------------------------------------
# Обход библиотеки
# ---------------------------------------------------------------------------
class Fb2AuthorFromDir:
    """Проставить автора из имени каталога всем FB2-файлам библиотеки.

    :param root: каталог, подкаталоги первого уровня которого — имена авторов;
    :param dry_run: только показать, что было бы изменено;
    :param backup: сохранять резервную копию ``*.bak`` перед записью;
    :param clear_middle_name: удалять ``<middle-name>``, если отчества
        в имени каталога нет;
    :param debug: печатать каждый обработанный файл.
    """

    def __init__(
        self,
        root: str = ".",
        *,
        dry_run: bool = False,
        backup: bool = False,
        clear_middle_name: bool = False,
        debug: bool = False,
    ) -> None:
        self.root = Path(root)
        self.dry_run = dry_run
        self.backup = backup
        self.clear_middle_name = clear_middle_name
        self.debug = debug

    def author_dirs(self) -> List[Tuple[Path, AuthorName]]:
        """Подкаталоги первого уровня как имена авторов.

        Каталоги, имя которых не разбирается на 2 или 3 слова, и скрытые
        каталоги (начинаются с точки) пропускаются с предупреждением.

        :return: список пар (каталог, имя автора).
        """
        found: List[Tuple[Path, AuthorName]] = []
        for entry in sorted(self.root.iterdir(), key=lambda item: item.name.casefold()):
            if not entry.is_dir() or entry.name.startswith("."):
                continue
            try:
                found.append((entry, AuthorName.parse(entry.name)))
            except ValueError as exc:
                logger.warning("каталог пропущен (%s): %s", entry, exc)
        return found

    @staticmethod
    def fb2_files(directory: Path) -> Iterator[Path]:
        """FB2-файлы каталога и всех вложенных каталогов.

        :param directory: каталог автора.
        :return: пути к файлам с расширением ``.fb2`` (без учёта регистра).
        """
        for path in sorted(directory.rglob("*")):
            if path.is_file() and path.suffix.lower() == FB2_SUFFIX:
                yield path

    def process_file(self, path: Path, name: AuthorName) -> str:
        """Обработать один FB2-файл.

        :param path: путь к файлу.
        :param name: имя автора из имени каталога.
        :return: статус обработки.
        :raises Fb2MetadataError: нет ``<description>``/``<title-info>``.
        :raises lxml.etree.XMLSyntaxError: файл не является корректным XML.
        :raises OSError: ошибка чтения/записи.
        """
        tree, fallback_encoding = _load(path)
        status = apply_author(tree, name, self.clear_middle_name)
        if status != STATUS_UPDATED or self.dry_run:
            return status
        data = _dump(tree, fallback_encoding)
        if self.backup:
            shutil.copy2(path, _backup_path(path))
        _write_atomic(path, data)
        return status

    def run(self) -> Dict[str, int]:
        """Обойти библиотеку и обновить авторов во всех FB2-файлах.

        :return: счётчики по статусам плюс ``errors``.
        :raises NotADirectoryError: если ``root`` не каталог.
        """
        if not self.root.is_dir():
            raise NotADirectoryError(f"каталог не существует: {self.root}")
        stats: Dict[str, int] = {
            STATUS_UPDATED: 0,
            STATUS_UNCHANGED: 0,
            STATUS_MULTIPLE: 0,
            "errors": 0,
        }
        for directory, name in self.author_dirs():
            for path in self.fb2_files(directory):
                try:
                    status = self.process_file(path, name)
                except (OSError, etree.XMLSyntaxError, Fb2MetadataError) as exc:
                    stats["errors"] += 1
                    logger.error("%s: %s", path, exc)
                    continue
                stats[status] += 1
                if self.debug or (self.dry_run and status == STATUS_UPDATED):
                    logger.info("[%s] %s", status, path)
        return stats


def main(argv: Optional[List[str]] = None) -> int:
    """Точка входа CLI.

    :param argv: аргументы командной строки (``argv[0]`` — имя скрипта).
    :return: 0 — успех, 1 — ошибки обработки или неверный каталог.
    """
    if argv is None:
        argv = sys.argv
    parser = argparse.ArgumentParser(
        description="Простановка автора из имени подкаталога во все FB2-файлы.",
    )
    parser.add_argument(
        "root",
        nargs="?",
        default=".",
        help="каталог, подкаталоги которого — имена авторов (по умолчанию текущий)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="только показать, что было бы изменено, ничего не записывать",
    )
    parser.add_argument(
        "--backup",
        action="store_true",
        help="сохранять резервную копию файла рядом (book.fb2.bak)",
    )
    parser.add_argument(
        "--clear-middle-name",
        action="store_true",
        help="удалять <middle-name>, если в имени каталога нет отчества",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="печатать каждый обработанный файл",
    )
    args = parser.parse_args(argv[1:])

    # basicConfig не переопределяет уже настроенное логирование.
    logging.basicConfig(level=logging.INFO, format="%(message)s")

    task = Fb2AuthorFromDir(
        args.root,
        dry_run=args.dry_run,
        backup=args.backup,
        clear_middle_name=args.clear_middle_name,
        debug=args.verbose,
    )
    try:
        stats = task.run()
    except NotADirectoryError as exc:
        print(f"Ошибка: {exc}", file=sys.stderr)
        return 1

    prefix = "(предпросмотр) " if args.dry_run else ""
    print(
        f"{prefix}обновлено: {stats[STATUS_UPDATED]}, "
        f"без изменений: {stats[STATUS_UNCHANGED]}, "
        f"несколько авторов: {stats[STATUS_MULTIPLE]}, "
        f"ошибок: {stats['errors']}"
    )
    return 0 if stats["errors"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
