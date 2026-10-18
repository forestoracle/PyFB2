# -*- coding: utf-8 -*-
"""Упаковка FB2 в ZIP-архивы (``book.fb2.zip``).

Модуль собирает файлы ``*.fb2`` в «однокнижные» ZIP-архивы — контейнер,
который понимают большинство читалок, библиотек (Calibre, MyHomeLib,
OPDS-каталоги) и веб-серверов. Внутри архива FB2 хранится под своим базовым
именем (без каталогов), поэтому распаковка (:mod:`pyFB2.fb2_unzip`) даёт
исходный файл.

Возможности:
    * упаковка одного файла (:meth:`FB2Zip.zip_file`) или всего каталога
      (:meth:`FB2Zip.zip_dir`, по умолчанию рекурсивно);
    * запись архивов рядом с исходниками или в отдельный каталог
      (``out_dir``) с сохранением структуры подкаталогов;
    * удаление исходных FB2 после успешной упаковки (``remove_source``);
    * пропуск уже существующих архивов (``overwrite=False``);
    * предпросмотр без записи (``dry_run``);
    * атомарная запись архива (через временный файл, ``os.replace``).

Пример:
    >>> from pyFB2 import FB2Zip
    >>> FB2Zip().zip_file("book.fb2").target
    PosixPath('book.fb2.zip')

CLI:
    python -m pyFB2.fb2_zip <файл.fb2 | каталог> [--out-dir DIR]
        [--remove] [--skip-existing] [--dry-run] [-q]
"""

from __future__ import annotations

import argparse
import logging
import os
import sys
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional, Union

#: Маска FB2-файлов.
FB2_MASK = "*.fb2"

#: Суффикс архива FB2.
FB2_ZIP_SUFFIX = ".fb2.zip"

#: Коды возврата CLI.
EXIT_OK = 0
EXIT_ERRORS = 1
EXIT_USAGE = 2

logger = logging.getLogger(__name__)


@dataclass
class Fb2ZipResult:
    """Результат упаковки одного файла.

    :param source: исходный FB2.
    :param target: путь архива (None, если запись не выполнялась).
    :param skipped: True, если архив уже существует и пересборка отключена.
    :param removed: True, если исходный файл удалён после упаковки.
    :param error: текст ошибки (None при успехе).
    """

    source: Path
    target: Optional[Path] = None
    skipped: bool = False
    removed: bool = False
    error: Optional[str] = None

    @property
    def ok(self) -> bool:
        """Успешно ли выполнена упаковка (включая пропуск)."""
        return self.error is None


class FB2Zip:
    """Упаковщик FB2-файлов в ZIP-архивы (``.fb2.zip``).

    :param remove_source: удалять исходный FB2 после успешной упаковки.
    :param overwrite: пересобирать существующий архив; False — пропускать
        такие файлы (``Fb2ZipResult.skipped``).
    :param compress_level: уровень сжатия deflate (0..9); None — значение
        :mod:`zipfile` по умолчанию.
    """

    def __init__(
        self,
        remove_source: bool = False,
        overwrite: bool = True,
        compress_level: Optional[int] = None,
    ) -> None:
        self.remove_source = remove_source
        self.overwrite = overwrite
        self.compress_level = compress_level

    # --- Один файл ---------------------------------------------------------
    def zip_file(
        self,
        source: Union[str, Path],
        dest: Optional[Union[str, Path]] = None,
        dry_run: bool = False,
    ) -> Fb2ZipResult:
        """Упаковать один файл в ZIP-архив.

        :param source: путь к FB2 (допустим любой существующий файл).
        :param dest: путь архива (None — ``<source>.zip`` рядом с исходником).
        :param dry_run: не записывать архив.
        :return: результат упаковки.
        """
        source_path = Path(source)
        if not source_path.is_file():
            logger.error("файл не найден: %s", source_path)
            return Fb2ZipResult(source=source_path, error=f"файл не найден: {source_path}")

        target_path = Path(dest) if dest else archive_path(source_path)

        if target_path.exists() and not self.overwrite:
            logger.info("архив уже существует, пропущен: %s", target_path)
            return Fb2ZipResult(source=source_path, target=target_path, skipped=True)

        if dry_run:
            return Fb2ZipResult(source=source_path, target=target_path)

        try:
            self._write_archive(target_path, source_path)
        except OSError as exc:
            logger.error("не удалось создать архив %s: %s", target_path, exc)
            return Fb2ZipResult(
                source=source_path,
                target=target_path,
                error=f"не удалось создать архив: {exc}",
            )

        removed = self._remove_source(source_path) if self.remove_source else False
        return Fb2ZipResult(source=source_path, target=target_path, removed=removed)

    def _write_archive(self, target: Path, source: Path) -> None:
        """Записать архив атомарно (FB2 лежит под своим базовым именем).

        :param target: путь архива.
        :param source: упаковываемый файл.
        """
        target.parent.mkdir(parents=True, exist_ok=True)
        tmp = target.with_name(target.name + ".tmp")
        try:
            with zipfile.ZipFile(
                tmp, "w", zipfile.ZIP_DEFLATED, compresslevel=self.compress_level
            ) as archive:
                archive.write(source, source.name)
            os.replace(tmp, target)
        except BaseException:
            # Не оставляем мусор от неудачной записи.
            try:
                tmp.unlink()
            except OSError:  # pragma: no cover - временный файл уже удалён
                pass
            raise

    def _remove_source(self, source: Path) -> bool:
        """Удалить исходный файл после упаковки.

        :param source: путь исходного FB2.
        :return: True, если файл удалён.
        """
        try:
            source.unlink()
        except OSError as exc:
            logger.warning("не удалось удалить исходный файл %s: %s", source, exc)
            return False
        return True

    # --- Каталог -----------------------------------------------------------
    def zip_dir(
        self,
        directory: Union[str, Path],
        out_dir: Optional[Union[str, Path]] = None,
        recursive: bool = True,
        dry_run: bool = False,
    ) -> List[Fb2ZipResult]:
        """Упаковать все FB2-файлы каталога.

        :param directory: корневой каталог.
        :param out_dir: каталог для архивов (None — рядом с исходниками).
        :param recursive: обходить подкаталоги.
        :param dry_run: не записывать архивы.
        :return: список результатов (пустой, если FB2 не найдены).
        """
        root = Path(directory)
        out_root = Path(out_dir) if out_dir else None
        pattern = f"**/{FB2_MASK}" if recursive else FB2_MASK

        results: List[Fb2ZipResult] = []
        for fb2 in sorted(root.glob(pattern)):
            dest = dest_path(fb2, root, out_root)
            results.append(self.zip_file(fb2, dest=dest, dry_run=dry_run))
        return results


def archive_path(source: Union[str, Path]) -> Path:
    """Путь архива для FB2 (``book.fb2`` -> ``book.fb2.zip``).

    :param source: путь исходного файла.
    :return: путь архива рядом с исходником.
    """
    path = Path(source)
    return path.with_name(path.name + ".zip")


def dest_path(source: Path, root: Path, out_root: Optional[Path]) -> Optional[Path]:
    """Путь архива для файла из каталога.

    :param source: исходный FB2.
    :param root: корень обхода.
    :param out_root: каталог вывода (None — рядом с исходником).
    :return: путь архива (None — рядом с исходником).
    """
    if out_root is None:
        return None
    return out_root / source.relative_to(root).parent / (source.name + ".zip")


def main(argv: Optional[List[str]] = None) -> int:
    """Точка входа CLI.

    :param argv: аргументы командной строки (по умолчанию ``sys.argv[1:]``).
    :return: код возврата: 0 — успех, 1 — были ошибки, 2 — ошибка запуска.
    """
    parser = argparse.ArgumentParser(
        description="Упаковка FB2 в ZIP-архивы (.fb2.zip).",
    )
    parser.add_argument("source", help="FB2-файл или каталог")
    parser.add_argument("--out-dir", default=None, help="каталог для архивов")
    parser.add_argument(
        "--remove", action="store_true", help="удалять исходные FB2 после упаковки"
    )
    parser.add_argument(
        "--skip-existing", action="store_true", help="не пересобирать существующие архивы"
    )
    parser.add_argument("--dry-run", action="store_true", help="не записывать архивы")
    parser.add_argument(
        "-q", "--quiet", action="store_true", help="выводить только ошибки и итог"
    )
    args = parser.parse_args(argv)

    zipper = FB2Zip(remove_source=args.remove, overwrite=not args.skip_existing)
    source_path = Path(args.source)

    if source_path.is_dir():
        results = zipper.zip_dir(source_path, out_dir=args.out_dir, dry_run=args.dry_run)
    elif source_path.is_file():
        dest = Path(args.out_dir) / (source_path.name + ".zip") if args.out_dir else None
        results = [zipper.zip_file(source_path, dest=dest, dry_run=args.dry_run)]
    else:
        print(f"Ошибка: файл или каталог не найден: {args.source}", file=sys.stderr)
        return EXIT_USAGE

    errors = 0
    skipped = 0
    packed = 0
    for result in results:
        if not result.ok:
            errors += 1
            print(f"ОШИБКА: {result.source}: {result.error}", file=sys.stderr)
            continue
        if result.skipped:
            skipped += 1
            if not args.quiet:
                print(f"ПРОПУЩЕН (архив уже существует): {result.source}")
            continue
        packed += 1
        if not args.quiet:
            mark = "(проверка)" if args.dry_run else "->"
            print(f"{result.source} {mark} {result.target}")

    print(
        f"Обработано: {len(results)}, упаковано: {packed}, "
        f"пропущено: {skipped}, ошибок: {errors}",
        file=sys.stderr,
    )
    return EXIT_ERRORS if errors else EXIT_OK


__all__ = ["FB2Zip", "Fb2ZipResult", "archive_path", "main"]


if __name__ == "__main__":
    raise SystemExit(main())
