# -*- coding: utf-8 -*-
"""Валидация FB2-файлов на соответствие XSD-схеме FictionBook 2.0.

Модуль проверяет, что XML-документ соответствует официальной схеме
``FictionBook.xsd`` (и импортируемым ею ``FictionBookGenres.xsd``,
``FictionBookLang.xsd``, ``FictionBookLinks.xsd``).

Возможности:
    * валидация одного файла или целого дерева каталогов (рекурсивно);
    * подробный отчёт об ошибках: код, строка, столбец, сообщение;
    * проверка корректности XML как отдельного шага (well-formedness);
    * ненулевой код возврата при наличии невалидных файлов.

Пример:
    >>> from fb2_validator import Fb2Validator
    >>> validator = Fb2Validator()          # схема рядом с модулем
    >>> result = validator.validate_file("book.fb2")
    >>> result.is_valid
    True
    >>> for error in result.errors:
    ...     print(error)

CLI:
    python fb2_validator.py <файл.fb2 | каталог> [-r] [--schema FILE] [-q]
"""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import List, Optional, Union

from lxml import etree

from .fb2_errors import Fb2ValidationError

#: Имя файла XSD-схемы по умолчанию (ищется рядом с модулем).
DEFAULT_SCHEMA = "FictionBook.xsd"

#: Расширение FB2-файлов.
FB2_MASK = "*.fb2"

#: Код возврата CLI: все файлы валидны.
EXIT_OK = 0

#: Код возврата CLI: есть невалидные файлы.
EXIT_INVALID = 1

#: Код возврата CLI: ошибка запуска (нет аргументов, нет схемы и т. п.).
EXIT_ERROR = 2


@dataclass
class ValidationError:
    """Одна ошибка валидации.

    :param message: текст сообщения от валидатора схемы.
    :param line: номер строки (None, если неизвестен).
    :param column: номер столбца (None, если неизвестен).
    :param code: код ошибки libxml2.
    :param path: путь к проверяемому файлу.
    """

    message: str
    line: Optional[int] = None
    column: Optional[int] = None
    code: Optional[int] = None
    path: Optional[Path] = None

    def __str__(self) -> str:
        location = ""
        if self.line is not None:
            location = f" (строка {self.line}"
            if self.column is not None:
                location += f", столбец {self.column}"
            location += ")"
        prefix = f"{self.path}: " if self.path else ""
        return f"{prefix}{self.message}{location}"


@dataclass
class ValidationResult:
    """Результат валидации одного файла.

    :param path: путь к проверенному файлу.
    :param errors: список ошибок (пустой, если файл валиден).
    :param is_well_formed: корректен ли XML синтаксически.
    """

    path: Path
    errors: List[ValidationError] = field(default_factory=list)
    is_well_formed: bool = True

    @property
    def is_valid(self) -> bool:
        """Валиден ли файл по схеме."""
        return self.is_well_formed and not self.errors


class Fb2Validator:
    """Валидатор FB2 по XSD-схеме.

    :param schema_path: путь к ``FictionBook.xsd``. По умолчанию берётся файл
        рядом с этим модулем.
    :raises FileNotFoundError: если файл схемы не найден.
    :raises RuntimeError: если схема не компилируется.
    """

    def __init__(self, schema_path: Union[str, Path, None] = None) -> None:
        if schema_path is None:
            schema_path = Path(__file__).parent / "resources" / DEFAULT_SCHEMA
        self.schema_path = Path(schema_path).resolve()
        if not self.schema_path.is_file():
            raise FileNotFoundError(f"Не найдена XSD-схема: {self.schema_path}")

        try:
            # resolve_entities=False — защита от внешних сущностей (XXE).
            self.schema_doc = etree.parse(str(self.schema_path))
            self.schema = etree.XMLSchema(self.schema_doc)
        except (etree.XMLSyntaxError, etree.XMLSchemaParseError) as exc:
            raise Fb2ValidationError(
                f"Ошибка компиляции схемы {self.schema_path}: {exc}") from exc

    # --- Валидация одного файла -------------------------------------------
    def validate_file(self, path: Union[str, Path]) -> ValidationResult:
        """Проверить один FB2-файл.

        :param path: путь к FB2-файлу.
        :return: :class:`ValidationResult` с найденными ошибками.
        """
        target = Path(path)
        result = ValidationResult(path=target)

        try:
            document = self._parse(target)
        except etree.XMLSyntaxError as exc:
            result.is_well_formed = False
            line, column = getattr(exc, "lineno", None), getattr(exc, "offset", None)
            result.errors.append(
                ValidationError(
                    message=f"XML не корректен: {exc.msg}",
                    line=line,
                    column=column,
                    path=target,
                )
            )
            return result
        except OSError as exc:
            result.is_well_formed = False
            result.errors.append(
                ValidationError(message=f"Не удалось прочитать файл: {exc}", path=target)
            )
            return result

        if not self.schema.validate(document):
            for error in self.schema.error_log:
                result.errors.append(
                    ValidationError(
                        message=error.message,
                        line=error.line,
                        column=error.column,
                        code=error.type,
                        path=target,
                    )
                )
        return result

    @staticmethod
    def _parse(path: Path) -> etree._ElementTree:
        """Разобрать XML-файл без загрузки внешних сущностей."""
        parser = etree.XMLParser(
            resolve_entities=False,
            no_network=True,
            huge_tree=False,
        )
        return etree.parse(str(path), parser)

    # --- Валидация каталога -----------------------------------------------
    def validate_dir(self, directory: Union[str, Path]) -> List[ValidationResult]:
        """Рекурсивно проверить все FB2-файлы в каталоге.

        :param directory: корневой каталог.
        :return: список результатов (по одному на файл).
        """
        root = Path(directory)
        results: List[ValidationResult] = []
        for fb2 in sorted(root.rglob(FB2_MASK)):
            results.append(self.validate_file(fb2))
        return results

    def validate(self, source: Union[str, Path]) -> List[ValidationResult]:
        """Проверить файл или каталог (автоопределение).

        :param source: путь к FB2-файлу или каталогу.
        :return: список результатов.
        """
        path = Path(source)
        if path.is_dir():
            return self.validate_dir(path)
        return [self.validate_file(path)]


def _collect_targets(source: Union[str, Path], recursive: bool) -> List[Path]:
    """Собрать список FB2-файлов для проверки.

    :param source: файл или каталог.
    :param recursive: обходить ли каталог рекурсивно.
    :return: список путей к файлам.
    """
    path = Path(source)
    if path.is_file():
        return [path]
    if not path.is_dir():
        return []
    pattern = "**/*.fb2" if recursive else FB2_MASK
    return sorted(path.glob(pattern))


def main(argv: Optional[List[str]] = None) -> int:
    """Точка входа CLI.

    :param argv: аргументы командной строки (по умолчанию ``sys.argv[1:]``).
    :return: код возврата: 0 — всё валидно, 1 — есть ошибки, 2 — ошибка запуска.
    """
    parser = argparse.ArgumentParser(
        description="Валидация FB2-файлов по XSD-схеме FictionBook 2.0.",
    )
    parser.add_argument("source", help="FB2-файл или каталог с файлами")
    parser.add_argument(
        "-r",
        "--recursive",
        action="store_true",
        help="рекурсивный обход каталога",
    )
    parser.add_argument(
        "--schema",
        default=None,
        help=f"путь к XSD-схеме (по умолчанию {DEFAULT_SCHEMA} рядом с модулем)",
    )
    parser.add_argument(
        "-q",
        "--quiet",
        action="store_true",
        help="выводить только итог и ошибки",
    )
    args = parser.parse_args(argv)

    try:
        validator = Fb2Validator(schema_path=args.schema)
    except (FileNotFoundError, RuntimeError) as exc:
        print(f"Ошибка: {exc}", file=sys.stderr)
        return EXIT_ERROR

    if args.recursive and Path(args.source).is_dir():
        results = validator.validate_dir(args.source)
    else:
        targets = _collect_targets(args.source, args.recursive)
        if not targets:
            print(f"Ошибка: не найдено FB2-файлов: {args.source}", file=sys.stderr)
            return EXIT_ERROR
        results = [validator.validate_file(target) for target in targets]

    invalid = 0
    for result in results:
        if result.is_valid:
            if not args.quiet:
                print(f"OK: {result.path}")
            continue
        invalid += 1
        print(f"НЕВАЛИДНО: {result.path}", file=sys.stderr)
        for error in result.errors:
            print(f"  - {error}", file=sys.stderr)

    print(
        f"Проверено файлов: {len(results)}, валидных: {len(results) - invalid}, "
        f"невалидных: {invalid}",
        file=sys.stderr,
    )
    return EXIT_INVALID if invalid else EXIT_OK


if __name__ == "__main__":
    raise SystemExit(main())