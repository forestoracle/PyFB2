# -*- coding: utf-8 -*-
"""Распаковка архивов FB2 (``book.fb2.zip``).

Модуль извлекает книги из ZIP-архивов — как собранных :mod:`pyFB2.fb2_zip`,
так и созданных любым другим архиватором. Из архива берутся только записи
``*.fb2``; служебные файлы, картинки и вложенные каталоги игнорируются.
Пути записей проверяются на выход за пределы каталога распаковки (защита от
«Zip Slip»), поэтому архив из недоверенного источника безопасен.

Возможности:
    * распаковка одного архива (:meth:`FB2Unzip.unzip_file`) или всех архивов
      каталога (:meth:`FB2Unzip.unzip_dir`, по умолчанию рекурсивно);
    * извлечение рядом с архивом или в отдельный каталог (``out_dir``)
      с сохранением структуры подкаталогов;
    * удаление архивов после успешной распаковки (``remove_source``);
    * предпросмотр без записи (``dry_run``).

Пример:
    >>> from pyFB2 import FB2Unzip
    >>> FB2Unzip().unzip_file("book.fb2.zip").extracted
    ['book.fb2']

CLI:
    python -m pyFB2.fb2_unzip <архив.fb2.zip | каталог> [--out-dir DIR]
        [--remove] [--dry-run] [-q]
"""

from __future__ import annotations

import argparse
import logging
import os
import shutil
import sys
import zipfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import List, Optional, Union

#: Маска ZIP-архивов.
ARCHIVE_MASK = "*.zip"

#: Расширение FB2-файлов.
FB2_SUFFIX = ".fb2"

#: Коды возврата CLI.
EXIT_OK = 0
EXIT_ERRORS = 1
EXIT_USAGE = 2

logger = logging.getLogger(__name__)


@dataclass
class Fb2UnzipResult:
    """Результат распаковки одного архива.

    :param source: путь к ZIP-архиву.
    :param target: каталог распаковки (None, если запись не выполнялась).
    :param extracted: имена извлечённых файлов (как в архиве).
    :param skipped: True, если в архиве нет FB2-файлов.
    :param removed: True, если архив удалён после распаковки.
    :param error: текст ошибки (None при успехе).
    """

    source: Path
    target: Optional[Path] = None
    extracted: List[str] = field(default_factory=list)
    skipped: bool = False
    removed: bool = False
    error: Optional[str] = None

    @property
    def ok(self) -> bool:
        """Успешно ли выполнена распаковка (включая пропуск)."""
        return self.error is None


class FB2Unzip:
    """Распаковщик архивов FB2 (``.fb2.zip``).

    :param remove_source: удалять архив после успешной распаковки.
    """

    def __init__(self, remove_source: bool = False) -> None:
        self.remove_source = remove_source

    # --- Один архив --------------------------------------------------------
    def unzip_file(
        self,
        source: Union[str, Path],
        dest: Optional[Union[str, Path]] = None,
        dry_run: bool = False,
    ) -> Fb2UnzipResult:
        """Извлечь FB2-файлы из одного ZIP-архива.

        :param source: путь к ZIP-архиву.
        :param dest: каталог распаковки (None — каталог архива).
        :param dry_run: не распаковывать (только определить список файлов).
        :return: результат распаковки.
        """
        source_path = Path(source)
        if not source_path.is_file():
            logger.error("архив не найден: %s", source_path)
            return Fb2UnzipResult(source=source_path, error=f"архив не найден: {source_path}")

        dest_dir = Path(dest) if dest else source_path.parent

        try:
            with zipfile.ZipFile(source_path) as archive:
                members = [
                    info.filename
                    for info in archive.infolist()
                    if not info.is_dir() and is_fb2(info.filename)
                ]
                if not members:
                    logger.info("в архиве нет FB2-файлов: %s", source_path)
                    return Fb2UnzipResult(source=source_path, target=dest_dir, skipped=True)

                if dry_run:
                    return Fb2UnzipResult(
                        source=source_path, target=dest_dir, extracted=list(members)
                    )

                extracted = self._extract(archive, members, dest_dir)
        except zipfile.BadZipFile:
            logger.error("повреждённый архив: %s", source_path)
            return Fb2UnzipResult(
                source=source_path, target=dest_dir, error=f"повреждённый архив: {source_path}"
            )
        except OSError as exc:
            logger.error("не удалось распаковать %s: %s", source_path, exc)
            return Fb2UnzipResult(
                source=source_path, target=dest_dir, error=f"не удалось распаковать: {exc}"
            )

        if not extracted:
            logger.info("все записи архива пропущены как небезопасные: %s", source_path)
            return Fb2UnzipResult(source=source_path, target=dest_dir, skipped=True)

        removed = self._remove_source(source_path) if self.remove_source else False
        return Fb2UnzipResult(
            source=source_path, target=dest_dir, extracted=extracted, removed=removed
        )

    def _extract(
        self,
        archive: zipfile.ZipFile,
        members: List[str],
        dest_dir: Path,
    ) -> List[str]:
        """Извлечь перечисленные записи архива в каталог.

        :param archive: открытый архив.
        :param members: имена записей (все с расширением ``.fb2``).
        :param dest_dir: каталог распаковки.
        :return: имена успешно извлечённых файлов.
        """
        dest_dir.mkdir(parents=True, exist_ok=True)
        extracted: List[str] = []
        for member in members:
            target = safe_target(dest_dir, member)
            if target is None:
                logger.warning("пропущен небезопасный путь в архиве: %s", member)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(member) as src, open(target, "wb") as dst:
                shutil.copyfileobj(src, dst)
            extracted.append(member)
        return extracted

    def _remove_source(self, source: Path) -> bool:
        """Удалить архив после распаковки.

        :param source: путь архива.
        :return: True, если архив удалён.
        """
        try:
            source.unlink()
        except OSError as exc:
            logger.warning("не удалось удалить архив %s: %s", source, exc)
            return False
        return True

    # --- Каталог -----------------------------------------------------------
    def unzip_dir(
        self,
        directory: Union[str, Path],
        out_dir: Optional[Union[str, Path]] = None,
        recursive: bool = True,
        dry_run: bool = False,
    ) -> List[Fb2UnzipResult]:
        """Распаковать все ZIP-архивы каталога.

        :param directory: корневой каталог.
        :param out_dir: каталог для распакованных FB2 (None — рядом с архивами).
        :param recursive: обходить подкаталоги.
        :param dry_run: не распаковывать (только определить список файлов).
        :return: список результатов (пустой, если архивов нет).
        """
        root = Path(directory)
        out_root = Path(out_dir) if out_dir else None

        results: List[Fb2UnzipResult] = []
        for archive in collect_archives(root, recursive):
            dest = unpack_dir(archive, root, out_root)
            results.append(self.unzip_file(archive, dest=dest, dry_run=dry_run))
        return results


def is_fb2(name: str) -> bool:
    """Проверить, что имя записи архива — FB2-файл.

    :param name: имя записи внутри ZIP-архива.
    :return: True, если имя оканчивается на ``.fb2`` (регистр не важен).
    """
    return name.lower().endswith(FB2_SUFFIX)


def safe_target(root: Path, name: str) -> Optional[Path]:
    """Путь распаковки записи архива внутри ``root``.

    :param root: каталог распаковки.
    :param name: имя записи внутри ZIP-архива.
    :return: абсолютный путь файла или None, если путь ведёт за пределы
        каталога распаковки (защита от «Zip Slip»).
    """
    root = root.resolve()
    candidate = (root / name).resolve()
    try:
        common = os.path.commonpath([str(root), str(candidate)])
    except ValueError:  # другой диск — запись вне каталога распаковки
        return None
    if os.path.normcase(common) != os.path.normcase(str(root)):
        return None
    return candidate


def collect_archives(root: Path, recursive: bool = True) -> List[Path]:
    """Собрать ZIP-архивы каталога.

    :param root: корневой каталог.
    :param recursive: обходить подкаталоги.
    :return: отсортированный список путей к архивам.
    """
    pattern = f"**/{ARCHIVE_MASK}" if recursive else ARCHIVE_MASK
    return sorted(
        path for path in root.glob(pattern) if path.is_file() and path.suffix.lower() == ".zip"
    )


def unpack_dir(source: Path, root: Path, out_root: Optional[Path]) -> Optional[Path]:
    """Каталог распаковки для архива из каталога.

    :param source: путь архива.
    :param root: корень обхода.
    :param out_root: каталог вывода (None — рядом с архивом).
    :return: каталог распаковки (None — каталог архива).
    """
    if out_root is None:
        return None
    return out_root / source.relative_to(root).parent


def main(argv: Optional[List[str]] = None) -> int:
    """Точка входа CLI.

    :param argv: аргументы командной строки (по умолчанию ``sys.argv[1:]``).
    :return: код возврата: 0 — успех, 1 — были ошибки, 2 — ошибка запуска.
    """
    parser = argparse.ArgumentParser(
        description="Распаковка архивов FB2 (.fb2.zip).",
    )
    parser.add_argument("source", help="ZIP-архив или каталог с архивами")
    parser.add_argument("--out-dir", default=None, help="каталог для распакованных FB2")
    parser.add_argument(
        "--remove", action="store_true", help="удалять архивы после распаковки"
    )
    parser.add_argument("--dry-run", action="store_true", help="не распаковывать (только список)")
    parser.add_argument(
        "-q", "--quiet", action="store_true", help="выводить только ошибки и итог"
    )
    args = parser.parse_args(argv)

    unzipper = FB2Unzip(remove_source=args.remove)
    source_path = Path(args.source)

    if source_path.is_dir():
        results = unzipper.unzip_dir(source_path, out_dir=args.out_dir, dry_run=args.dry_run)
    elif source_path.is_file():
        dest = Path(args.out_dir) if args.out_dir else None
        results = [unzipper.unzip_file(source_path, dest=dest, dry_run=args.dry_run)]
    else:
        print(f"Ошибка: архив или каталог не найден: {args.source}", file=sys.stderr)
        return EXIT_USAGE

    errors = 0
    skipped = 0
    unpacked = 0
    for result in results:
        if not result.ok:
            errors += 1
            print(f"ОШИБКА: {result.source}: {result.error}", file=sys.stderr)
            continue
        if result.skipped:
            skipped += 1
            if not args.quiet:
                print(f"ПРОПУЩЕН (нет FB2): {result.source}")
            continue
        unpacked += len(result.extracted)
        if not args.quiet:
            mark = "(проверка)" if args.dry_run else "->"
            files = ", ".join(result.extracted)
            print(f"{result.source} {mark} {result.target} [{files}]")

    print(
        f"Обработано архивов: {len(results)}, распаковано файлов: {unpacked}, "
        f"пропущено: {skipped}, ошибок: {errors}",
        file=sys.stderr,
    )
    return EXIT_ERRORS if errors else EXIT_OK


__all__ = [
    "FB2Unzip",
    "Fb2UnzipResult",
    "ARCHIVE_MASK",
    "collect_archives",
    "is_fb2",
    "safe_target",
    "main",
]


if __name__ == "__main__":
    raise SystemExit(main())
