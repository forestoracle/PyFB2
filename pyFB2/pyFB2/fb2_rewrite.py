# -*- coding: utf-8 -*-
"""Пересборка FB2: файл -> структуры -> файл (канонизация формы).

Модуль читает FB2 через :class:`Fb2Parser`, собирает книгу заново
:class:`Fb2Writer` и записывает результат. Это нормализация именно
**формы**, а не содержимого: единая XML-декларация UTF-8, отступы,
порядок элементов, а также исчезают узлы, которых нет в структурах
(комментарии, неизвестные элементы, лишние пробельные узлы).

Возможности:
    * перезапись на месте (по умолчанию) либо вывод в другой файл/каталог;
    * суффикс имени результата (``--suffix``);
    * предпросмотр без записи (``--dry-run``);
    * проверка результата по XSD **до** записи (``--validate``);
    * пропуск файлов, содержимое которых не изменилось (``--force``
      заставляет писать всегда);
    * рекурсивная обработка каталога.

Пример:
    >>> from fb2_rewrite import Fb2Rewriter
    >>> result = Fb2Rewriter().rewrite_file("book.fb2")
    >>> result.changed
    True

    # Пересобрать каталог в отдельное дерево с суффиксом:
    >>> Fb2Rewriter().rewrite_dir("library", out_dir="clean", suffix="_out")
    [RewriteResult(...), ...]

CLI:
    python fb2_rewrite.py <файл.fb2 | каталог> [--out FILE] [--out-dir DIR]
        [--suffix S] [--no-indent] [--dry-run] [--validate] [--schema XSD]
        [--force] [-q]
"""

from __future__ import annotations

import argparse
import logging
import os
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING, List, Optional, Union

from lxml import etree

from .fb2_errors import Fb2Error, Fb2ValidationError
from .fb2_parser import Fb2Parser
from .fb2_structures import FictionBook
from .fb2_writer import Fb2Writer

if TYPE_CHECKING:  # pragma: no cover - только для аннотаций
    from .fb2_validator import Fb2Validator

#: Расширение FB2-файлов.
FB2_MASK = "*.fb2"

#: Кодировка результата (декларацию ставит :class:`Fb2Writer`).
DEFAULT_ENCODING = "utf-8"

#: Коды возврата CLI.
EXIT_OK = 0
EXIT_ERRORS = 1
EXIT_USAGE = 2

logger = logging.getLogger(__name__)


@dataclass
class RewriteResult:
    """Результат пересборки одного файла.

    :param source: исходный путь.
    :param target: путь результата (None, если запись не выполнялась).
    :param skipped: True, если содержимое не изменилось и файл не перезаписан.
    :param changed: True, если собранный XML отличается от исходного.
    :param valid: результат проверки по XSD (None — не проверялось).
    :param error: текст ошибки (None при успехе).
    """

    source: Path
    target: Optional[Path] = None
    skipped: bool = False
    changed: bool = False
    valid: Optional[bool] = None
    error: Optional[str] = None

    @property
    def ok(self) -> bool:
        """Успешно ли выполнена пересборка (включая пропуск)."""
        return self.error is None


def _normalized(data: bytes) -> bytes:
    """Привести переводы строк к ``\\n`` (чтобы CRLF не считался правкой)."""
    return data.replace(b"\r\n", b"\n")


def _write_atomic(path: Path, data: bytes) -> None:
    """Записать данные атомарно (через временный файл).

    :param path: файл назначения.
    :param data: байты для записи.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    with open(tmp, "wb") as handle:
        handle.write(data)
    os.replace(tmp, path)


def _dest_path(
    fb2: Path,
    root: Path,
    out_root: Optional[Path],
    suffix: str,
) -> Path:
    """Вычислить путь назначения для файла каталога.

    :param fb2: исходный файл.
    :param root: корень обхода.
    :param out_root: каталог вывода (None — рядом с исходным).
    :param suffix: суффикс имени файла.
    :return: путь назначения.
    """
    name = fb2.stem + suffix + fb2.suffix
    if out_root is not None:
        return out_root / fb2.relative_to(root).parent / name
    if suffix:
        return fb2.with_name(name)
    return fb2


class Fb2Rewriter:
    """Пересборщик FB2: файл -> структуры -> файл.

    :param indent: форматировать XML отступами.
    :param validate: проверять результат по XSD до записи.
    :param schema_path: путь к XSD-схеме (None — схема по умолчанию).
    :param force: перезаписывать файлы, содержимое которых не изменилось.
    """

    def __init__(
        self,
        indent: bool = True,
        validate: bool = False,
        schema_path: Union[str, Path, None] = None,
        force: bool = False,
    ) -> None:
        self.indent = indent
        self.validate = validate
        self.schema_path = schema_path
        self.force = force
        self._validator: Optional[Fb2Validator] = None

    # --- Разбор и сборка ---------------------------------------------------
    def to_xml(self, source) -> str:
        """Разобрать FB2 и собрать его заново в строку XML.

        :param source: путь к FB2, файловый объект или ``ET.Element``.
        :return: XML-текст с декларацией UTF-8.
        :raises Fb2ParseError: если документ не читается или не разбирается.
        """
        parser = Fb2Parser(source=source)
        book = FictionBook(
            stylesheets=parser.parse_stylesheets(),
            description=parser.parse(),
            bodies=parser.parse_bodies(),
            binaries=parser.parse_binaries(),
        )
        return Fb2Writer(indent=self.indent).to_xml(book)

    # --- Проверка по XSD ---------------------------------------------------
    def _get_validator(self) -> Optional[Fb2Validator]:
        """Ленивый доступ к :class:`Fb2Validator` (None при недоступности)."""
        if self._validator is None:
            try:
                from .fb2_validator import Fb2Validator

                self._validator = Fb2Validator(schema_path=self.schema_path)
            except (Fb2ValidationError, OSError) as exc:
                logger.warning("XSD-схема недоступна, проверка пропущена: %s", exc)
                return None
        return self._validator

    def validate_xml(self, xml: str) -> Optional[bool]:
        """Проверить XML-текст по XSD-схеме.

        :param xml: XML-текст FB2.
        :return: True/False либо None, если валидатор недоступен.
        """
        validator = self._get_validator()
        if validator is None:
            return None
        try:
            document = etree.fromstring(
                xml.encode(DEFAULT_ENCODING),
                etree.XMLParser(resolve_entities=False, no_network=True),
            )
        except etree.XMLSyntaxError:
            return False
        return bool(validator.schema.validate(document))

    # --- Работа с файлами --------------------------------------------------
    def rewrite_file(
        self,
        path: Union[str, Path],
        dest: Optional[Union[str, Path]] = None,
        dry_run: bool = False,
    ) -> RewriteResult:
        """Пересобрать один FB2-файл.

        :param path: исходный файл.
        :param dest: файл результата (None — перезапись исходного).
        :param dry_run: не записывать результат, только проверить.
        :return: :class:`RewriteResult`.
        """
        source = Path(path)
        try:
            data = source.read_bytes()
        except OSError as exc:
            return RewriteResult(source=source, error=f"Не удалось прочитать: {exc}")

        try:
            xml = self.to_xml(source)
        except (Fb2Error, OSError) as exc:
            return RewriteResult(source=source, error=str(exc))

        payload = xml.encode(DEFAULT_ENCODING)
        target = Path(dest) if dest else source
        changed = _normalized(data) != _normalized(payload)

        valid: Optional[bool] = None
        if self.validate:
            valid = self.validate_xml(xml)
            if valid is False:
                return RewriteResult(
                    source=source,
                    target=target,
                    changed=changed,
                    valid=False,
                    error="результат не проходит валидацию по XSD",
                )

        if dest is None and not changed and not self.force:
            return RewriteResult(source=source, target=None, skipped=True, valid=valid)

        if dry_run:
            return RewriteResult(
                source=source, target=target, changed=changed, valid=valid
            )

        try:
            _write_atomic(target, payload)
        except OSError as exc:
            return RewriteResult(
                source=source,
                target=target,
                changed=changed,
                valid=valid,
                error=f"Не удалось записать: {exc}",
            )
        return RewriteResult(
            source=source, target=target, changed=changed, valid=valid
        )

    def rewrite_dir(
        self,
        directory: Union[str, Path],
        out_dir: Optional[Union[str, Path]] = None,
        suffix: str = "",
        dry_run: bool = False,
        recursive: bool = True,
    ) -> List[RewriteResult]:
        """Пересобрать все FB2-файлы каталога.

        :param directory: корневой каталог.
        :param out_dir: каталог для результатов (None — рядом с исходными).
        :param suffix: суффикс, добавляемый к имени файла.
        :param dry_run: не записывать результат.
        :param recursive: обходить подкаталоги.
        :return: список результатов.
        """
        root = Path(directory)
        out_root = Path(out_dir) if out_dir else None
        pattern = f"**/{FB2_MASK}" if recursive else FB2_MASK

        results: List[RewriteResult] = []
        for fb2 in sorted(root.glob(pattern)):
            dest = _dest_path(fb2, root, out_root, suffix)
            results.append(self.rewrite_file(fb2, dest=dest, dry_run=dry_run))
        return results


__all__ = ["Fb2Rewriter", "RewriteResult"]


def _single_dest(
    target: Path,
    out: Optional[str],
    out_dir: Optional[str],
    suffix: str,
) -> Optional[Path]:
    """Путь результата для одного файла (None — перезапись исходного)."""
    if out:
        return Path(out)
    if out_dir:
        return Path(out_dir) / target.name
    if suffix:
        return target.with_name(target.stem + suffix + target.suffix)
    return None


def main(argv: Optional[List[str]] = None) -> int:
    """Точка входа CLI.

    :param argv: аргументы командной строки (по умолчанию ``sys.argv[1:]``).
    :return: код возврата: 0 — успех, 1 — были ошибки, 2 — ошибка запуска.
    """
    parser = argparse.ArgumentParser(
        description="Пересборка FB2 (структуры -> XML): канонизация формы файла.",
    )
    parser.add_argument("source", help="FB2-файл или каталог")
    parser.add_argument("--out", default=None, help="файл результата (для одного FB2)")
    parser.add_argument("--out-dir", default=None, help="каталог для результатов")
    parser.add_argument("--suffix", default="", help="суффикс имени результата")
    parser.add_argument(
        "--no-indent", action="store_true", help="не форматировать XML отступами"
    )
    parser.add_argument("--dry-run", action="store_true", help="не записывать результат")
    parser.add_argument(
        "--validate", action="store_true", help="проверить результат по XSD до записи"
    )
    parser.add_argument("--schema", default=None, help="путь к FictionBook.xsd")
    parser.add_argument(
        "--force", action="store_true", help="писать даже неизменённые файлы"
    )
    parser.add_argument(
        "-q", "--quiet", action="store_true", help="выводить только итог и ошибки"
    )
    args = parser.parse_args(argv)

    rewriter = Fb2Rewriter(
        indent=not args.no_indent,
        validate=args.validate,
        schema_path=args.schema,
        force=args.force,
    )

    source_path = Path(args.source)
    if source_path.is_dir():
        results = rewriter.rewrite_dir(
            source_path,
            out_dir=args.out_dir,
            suffix=args.suffix,
            dry_run=args.dry_run,
        )
    else:
        if not source_path.is_file():
            print(f"Ошибка: файл не найден: {args.source}", file=sys.stderr)
            return EXIT_USAGE
        dest = _single_dest(source_path, args.out, args.out_dir, args.suffix)
        results = [
            rewriter.rewrite_file(source_path, dest=dest, dry_run=args.dry_run)
        ]

    errors = 0
    skipped = 0
    changed = 0
    for result in results:
        if not result.ok:
            errors += 1
            print(f"ОШИБКА: {result.source}: {result.error}", file=sys.stderr)
            continue
        if result.skipped:
            skipped += 1
            if not args.quiet:
                print(f"без изменений: {result.source}")
            continue
        changed += 1
        if args.quiet:
            continue
        xsd = ""
        if result.valid is not None:
            xsd = " [XSD: OK]" if result.valid else " [XSD: ОШИБКИ]"
        mark = "(проверка)" if args.dry_run else "->"
        print(f"{result.source} {mark} {result.target}{xsd}")

    print(
        f"Обработано: {len(results)}, изменено: {changed}, "
        f"без изменений: {skipped}, ошибок: {errors}",
        file=sys.stderr,
    )
    return EXIT_ERRORS if errors else EXIT_OK


if __name__ == "__main__":
    raise SystemExit(main())
