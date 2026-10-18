# -*- coding: utf-8 -*-
"""Поиск каталогов, в которых FB2-файлы имеют РАЗНЫХ авторов.

Скрипт рекурсивно обходит дерево каталогов от указанного корня, читает
метаданные <title-info> каждого FB2-файла и определяет каталоги, где
встречаются файлы с различающимися именами авторов.

Использование:
    python fb2_author_scanner.py <каталог> [-v|--verbose]

    <каталог>       Корневой каталог для рекурсивного обхода.
    -v, --verbose   Показать различающиеся имена авторов для каждого каталога.

Имена авторов формируются из полей authorType
(last-name, first-name, middle-name), при их отсутствии — nickname.
Сравнение выполняется без учёта регистра и лишних пробелов.
"""

from __future__ import annotations

import logging
import os
import sys
from pathlib import Path
from typing import Dict, List, Tuple

from .fb2_parser import Fb2Parser
from .fb2_structures import Author

#: Расширение FB2-файлов.
FB2_MASK = "*.fb2"

logger = logging.getLogger(__name__)


def format_author(author: Author) -> str:
    """Собрать человекочитаемое имя автора из полей authorType.

    Приоритет: ``last-name first-name middle-name``; если эти поля пусты —
    ``nickname``.

    :param author: структура :class:`Author` из fb2_structures.
    :return: имя автора ("" если данных нет).
    """
    parts = [author.last_name, author.first_name, author.middle_name]
    name = " ".join(p.strip() for p in parts if p and p.strip())
    if name:
        return name
    return (author.nickname or "").strip()


def _normalize(name: str) -> str:
    """Нормализовать имя для сравнения: регистр + пробелы."""
    return " ".join(name.split()).casefold()


class Fb2AuthorScanner:
    """Рекурсивный поиск каталогов с различающимися авторами FB2-файлов.

    :param start_dir: корневой каталог для обхода.
    :param debug: выводить сообщения об ошибках разбора файлов.
    """

    def __init__(self, start_dir: str, debug: bool = False) -> None:
        self.start_dir = Path(start_dir)
        self.debug = debug
        self.parser = Fb2Parser()

    def file_authors(self, path: Path) -> List[str]:
        """Список имён авторов одного FB2-файла.

        :param path: путь к FB2-файлу.
        :return: список имён авторов (пустой при ошибке разбора).
        """
        try:
            description = self.parser.parse(str(path))
        except Exception as exc:  # noqa: BLE001 — файл может быть повреждён
            logger.warning("не удалось разобрать %s: %s", path, exc)
            return []

        title_info = description.title_info
        if title_info is None:
            return []

        names = []
        for author in title_info.authors:
            name = format_author(author)
            if name:
                names.append(name)
        return names

    def dir_authors(self, directory: Path) -> Dict[str, str]:
        """Собрать авторов FB2-файлов, лежащих непосредственно в каталоге.

        :param directory: каталог для анализа.
        :return: словарь {нормализованное имя: имя для вывода}.
        """
        authors: Dict[str, str] = {}
        for fb2 in sorted(directory.glob(FB2_MASK)):
            for name in self.file_authors(fb2):
                authors.setdefault(_normalize(name), name)
        return authors

    def scan(self) -> List[Tuple[Path, List[str]]]:
        """Рекурсивно обойти дерево и вернуть каталоги с разными авторами.

        :return: список пар (каталог, отсортированные имена авторов) для
            каталогов, в которых найдено более одного РАЗЛИЧАЮЩЕГОСЯ автора.
        """
        results: List[Tuple[Path, List[str]]] = []
        for root, dirs, _files in os.walk(self.start_dir):
            dirs.sort()  # стабильный порядок обхода
            directory = Path(root)
            authors = self.dir_authors(directory)
            if len(authors) > 1:
                results.append((directory, sorted(authors.values())))
        return results


def main(argv: List[str] | None = None) -> int:
    if argv is None:
        argv = sys.argv
    """Точка входа CLI.

    :param argv: аргументы командной строки (argv[0] — имя скрипта).
    :return: код возврата (0 — успех, 1 — ошибка каталога, 2 — нет аргументов).
    """
    positional = [a for a in argv[1:] if not a.startswith("-")]
    verbose = any(a in ("-v", "--verbose") for a in argv[1:])

    if not positional:
        print(
            "Использование: python fb2_author_scanner.py <каталог> [-v|--verbose]",
            file=sys.stderr,
        )
        return 2

    scanner = Fb2AuthorScanner(start_dir=positional[0])
    if not scanner.start_dir.is_dir():
        print(f"Ошибка: каталог не существует: {positional[0]}", file=sys.stderr)
        return 1

    found = scanner.scan()
    for directory, authors in found:
        rel = os.path.relpath(directory, scanner.start_dir)
        if verbose:
            print(f"{rel}: " + "; ".join(authors))
        else:
            print(rel)

    if not found:
        print("Каталогов с различающимися авторами не найдено.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
