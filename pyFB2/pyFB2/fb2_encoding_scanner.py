# -*- coding: utf-8 -*-
"""Поиск каталогов, в которых FB2-файлы имеют РАЗНЫЕ кодировки.

Скрипт рекурсивно обходит дерево каталогов от указанного корня, определяет
кодировку каждого FB2-файла и выводит каталоги, где встречаются файлы с
различающимися кодировками.

Кодировка определяется в таком порядке:
    1. BOM в начале файла (UTF-8 / UTF-16 / UTF-32);
    2. атрибут ``encoding`` в XML-декларации (``<?xml ... encoding="..."?>``);
    3. значение по умолчанию XML — ``utf-8``.

Использование:
    python fb2_encoding_scanner.py <каталог> [-v|--verbose]

    <каталог>       Корневой каталог для рекурсивного обхода.
    -v, --verbose   Показать различающиеся кодировки для каждого каталога.

Сравнение кодировок выполняется без учёта регистра.
"""

from __future__ import annotations

import logging
import os
import re
import sys
from pathlib import Path
from typing import Dict, List, Tuple

#: Расширение FB2-файлов.
FB2_MASK = "*.fb2"

logger = logging.getLogger(__name__)

#: Атрибут encoding в XML-декларации (ищем в первых байтах файла).
ENCODING_RE = re.compile(rb"""encoding\s*=\s*["']([^"']+)["']""", re.IGNORECASE)

#: BOM-последовательности -> имя кодировки.
#: ВАЖНО: более длинные последовательности проверяются раньше коротких
#: (UTF-32-LE начинается с FF FE, как UTF-16-LE).
BOMS = (
    (b"\xef\xbb\xbf", "utf-8"),
    (b"\xff\xfe\x00\x00", "utf-32-le"),
    (b"\x00\x00\xfe\xff", "utf-32-be"),
    (b"\xff\xfe", "utf-16-le"),
    (b"\xfe\xff", "utf-16-be"),
)

#: Кодировка по умолчанию для XML без декларации и без BOM.
DEFAULT_ENCODING = "utf-8"

#: Сколько байт читать для анализа (декларация всегда в начале файла).
HEAD_SIZE = 4096


def detect_encoding(path: Path) -> str:
    """Определить кодировку FB2-файла.

    :param path: путь к FB2-файлу.
    :return: имя кодировки ("" при ошибке чтения файла).
    """
    try:
        with open(path, "rb") as handle:
            head = handle.read(HEAD_SIZE)
    except OSError:
        return ""

    for bom, name in BOMS:
        if head.startswith(bom):
            return name

    match = ENCODING_RE.search(head)
    if match:
        return match.group(1).decode("ascii", "replace").strip()

    return DEFAULT_ENCODING


def _normalize(encoding: str) -> str:
    """Нормализовать имя кодировки для сравнения (регистр, пробелы)."""
    return encoding.strip().casefold()


class Fb2EncodingScanner:
    """Рекурсивный поиск каталогов с различающимися кодировками FB2-файлов.

    :param start_dir: корневой каталог для обхода.
    :param debug: выводить сообщения об ошибках чтения файлов.
    """

    def __init__(self, start_dir: str, debug: bool = False) -> None:
        self.start_dir = Path(start_dir)
        self.debug = debug

    def file_encodings(self, path: Path) -> List[str]:
        """Кодировка одного FB2-файла в виде списка ("" -> пустой список).

        :param path: путь к FB2-файлу.
        :return: список из одной кодировки либо пустой список при ошибке.
        """
        encoding = detect_encoding(path)
        if not encoding:
            logger.warning("не удалось определить кодировку (файл недоступен): %s", path)
            return []
        return [encoding]

    def dir_encodings(self, directory: Path) -> Dict[str, str]:
        """Собрать кодировки FB2-файлов, лежащих непосредственно в каталоге.

        :param directory: каталог для анализа.
        :return: словарь {нормализованная кодировка: кодировка для вывода}.
        """
        encodings: Dict[str, str] = {}
        for fb2 in sorted(directory.glob(FB2_MASK)):
            for encoding in self.file_encodings(fb2):
                encodings.setdefault(_normalize(encoding), encoding)
        return encodings

    def scan(self) -> List[Tuple[Path, List[str]]]:
        """Рекурсивно обойти дерево и вернуть каталоги с разными кодировками.

        :return: список пар (каталог, отсортированные кодировки) для каталогов,
            в которых найдено более одной РАЗЛИЧАЮЩЕЙСЯ кодировки.
        """
        results: List[Tuple[Path, List[str]]] = []
        for root, dirs, _files in os.walk(self.start_dir):
            dirs.sort()  # стабильный порядок обхода
            directory = Path(root)
            encodings = self.dir_encodings(directory)
            if len(encodings) > 1:
                results.append((directory, sorted(encodings.values())))
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
            "Использование: python fb2_encoding_scanner.py <каталог> [-v|--verbose]",
            file=sys.stderr,
        )
        return 2

    scanner = Fb2EncodingScanner(start_dir=positional[0])
    if not scanner.start_dir.is_dir():
        print(f"Ошибка: каталог не существует: {positional[0]}", file=sys.stderr)
        return 1

    found = scanner.scan()
    for directory, encodings in found:
        rel = os.path.relpath(directory, scanner.start_dir)
        if verbose:
            print(f"{rel}: " + "; ".join(encodings))
        else:
            print(rel)

    if not found:
        print("Каталогов с различающимися кодировками не найдено.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))