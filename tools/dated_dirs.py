# -*- coding: utf-8 -*-
"""Раскладка файлов по каталогам с датой создания (YYYY-MM-DD).

Читает все файлы в каталоге (независимо от расширения) и перемещает
каждый в подкаталог, имя которого — дата создания файла в формате
``YYYY-MM-DD``. Например, файл, созданный 2013-05-07, попадёт в
подкаталог ``2013-05-07/``.

Дата берётся из метки времени создания файла: на Windows это
``st_ctime`` (реальная дата создания). Ключ ``--use-mtime`` позволяет
использовать дату последнего изменения (``st_mtime``) — например, для
файлов, скопированных на другой носитель.

Возможности:
    * рекурсивный обход (``-r``);
    * предпросмотр без изменений (``--dry-run``);
    * копирование вместо перемещения (``--copy``);
    * отбор по диапазону дат (``--from`` / ``--to``);
    * журнал операций (``--log FILE``) для последующего отката;
    * разрешение конфликтов имён суффиксом ``_1``, ``_2``, ...;
    * пропуск файлов, уже лежащих в каталоге со своей датой.

CLI::

    python dated_dirs.py <каталог> [-r] [--dry-run] [--copy]
        [--use-mtime] [--from YYYY-MM-DD] [--to YYYY-MM-DD] [--log FILE]
"""

from __future__ import annotations

import argparse
import datetime as dt
import re
import shutil
import sys
from pathlib import Path
from typing import Iterator, List, Optional, Tuple

DATE_DIR_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def file_date(path: Path, use_mtime: bool = False) -> dt.date:
    """Дата файла: создания (по умолчанию) или изменения (``use_mtime``)."""
    st = path.stat()
    ts = st.st_mtime if use_mtime else st.st_ctime
    return dt.datetime.fromtimestamp(ts).date()


def parse_date(value: Optional[str]) -> Optional[dt.date]:
    """Разбирает строку ``YYYY-MM-DD``; пустое значение -> None."""
    if not value:
        return None
    return dt.datetime.strptime(value, "%Y-%m-%d").date()


def unique_path(dst: Path) -> Path:
    """Свободный путь: при конфликте добавляет ``_1``, ``_2``, ..."""
    if not dst.exists():
        return dst
    stem, suffix, parent = dst.stem, dst.suffix, dst.parent
    i = 1
    while True:
        candidate = parent / f"{stem}_{i}{suffix}"
        if not candidate.exists():
            return candidate
        i += 1


class DatedDirs:
    """Раскладывает файлы каталога по подкаталогам с датой создания.

    :param root: исходный каталог;
    :param recursive: обходить подкаталоги;
    :param dry_run: только показать, что было бы сделано;
    :param copy: копировать вместо перемещения;
    :param use_mtime: брать дату изменения вместо даты создания;
    :param date_from: нижняя граница даты (включительно);
    :param date_to: верхняя граница даты (включительно);
    :param log_path: файл журнала операций (TSV) для отката;
    :param debug: печатать каждую операцию.
    """

    def __init__(self, root: str, recursive: bool = False,
                 dry_run: bool = False, copy: bool = False,
                 use_mtime: bool = False,
                 date_from: Optional[dt.date] = None,
                 date_to: Optional[dt.date] = None,
                 log_path: Optional[str] = None, debug: bool = False) -> None:
        self.root = Path(root)
        self.recursive = recursive
        self.dry_run = dry_run
        self.copy = copy
        self.use_mtime = use_mtime
        self.date_from = date_from
        self.date_to = date_to
        self.logPath = Path(log_path) if log_path else None
        self.debug = debug
        if not self.root.is_dir():
            raise NotADirectoryError(f"Каталог не существует: {self.root}")

    # --- обход ---------------------------------------------------------------
    def iter_files(self) -> Iterator[Path]:
        """Все файлы каталога, кроме уже разложенных по датам и журнала."""
        mask = "**/*" if self.recursive else "*"
        for item in sorted(self.root.glob(mask)):
            if not item.is_file():
                continue
            if self.logPath and item.resolve() == self.logPath.resolve():
                continue
            # файл уже лежит в каталоге со своей датой — пропускаем
            if DATE_DIR_RE.match(item.parent.name):
                continue
            yield item

    def in_range(self, date: dt.date) -> bool:
        """Попадает ли дата в заданный диапазон."""
        if self.date_from and date < self.date_from:
            return False
        if self.date_to and date > self.date_to:
            return False
        return True

    # --- журнал --------------------------------------------------------------
    def _log_open(self):
        if not self.logPath:
            return None
        if self.dry_run:
            return None
        is_new = not self.logPath.exists()
        fh = open(self.logPath, "a", encoding="utf-8")
        if is_new:
            fh.write("# src\tdst\taction\ttimestamp\n")
        return fh

    def _log_write(self, fh, src: Path, dst: Path, action: str) -> None:
        if fh is None:
            return
        ts = dt.datetime.now().isoformat(timespec="seconds")
        fh.write(f"{src}\t{dst}\t{action}\t{ts}\n")

    # --- основная операция ---------------------------------------------------
    def run(self) -> dict:
        """Раскладывает файлы. Возвращает счётчики moved/copied/skipped/error."""
        stats = {"moved": 0, "copied": 0, "skipped": 0, "error": 0}
        log = self._log_open()
        try:
            for src in self.iter_files():
                try:
                    date = file_date(src, self.use_mtime)
                except OSError as exc:
                    stats["error"] += 1
                    if self.debug:
                        print(f"[error] {src}: {exc}")
                    continue
                if not self.in_range(date):
                    stats["skipped"] += 1
                    continue

                target_dir = self.root / date.isoformat()
                dst = unique_path(target_dir / src.name)

                if self.debug or self.dry_run:
                    verb = "copy" if self.copy else "move"
                    print(f"[{verb}] {src} -> {dst}")

                if self.dry_run:
                    stats["moved" if not self.copy else "copied"] += 1
                    continue

                try:
                    target_dir.mkdir(parents=True, exist_ok=True)
                    if self.copy:
                        shutil.copy2(src, dst)
                        stats["copied"] += 1
                        self._log_write(log, src, dst, "copy")
                    else:
                        shutil.move(str(src), str(dst))
                        stats["moved"] += 1
                        self._log_write(log, src, dst, "move")
                except OSError as exc:
                    stats["error"] += 1
                    if self.debug:
                        print(f"[error] {src}: {exc}")
        finally:
            if log is not None:
                log.close()
        return stats


def main(argv: List[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Раскладка файлов по каталогам с датой создания "
                    "(YYYY-MM-DD)")
    parser.add_argument("root", help="каталог с файлами")
    parser.add_argument("-r", "--recursive", action="store_true",
                        help="обходить подкаталоги")
    parser.add_argument("--dry-run", action="store_true",
                        help="только показать план, ничего не менять")
    parser.add_argument("--copy", action="store_true",
                        help="копировать вместо перемещения")
    parser.add_argument("--use-mtime", action="store_true",
                        help="использовать дату изменения, а не создания")
    parser.add_argument("--from", dest="date_from", metavar="YYYY-MM-DD",
                        help="нижняя граница даты (включительно)")
    parser.add_argument("--to", dest="date_to", metavar="YYYY-MM-DD",
                        help="верхняя граница даты (включительно)")
    parser.add_argument("--log", metavar="FILE",
                        help="журнал операций (TSV) для отката")
    parser.add_argument("-v", "--verbose", action="store_true",
                        help="печатать каждую операцию")

    args = parser.parse_args(argv[1:])
    try:
        task = DatedDirs(
            args.root,
            recursive=args.recursive,
            dry_run=args.dry_run,
            copy=args.copy,
            use_mtime=args.use_mtime,
            date_from=parse_date(args.date_from),
            date_to=parse_date(args.date_to),
            log_path=args.log,
            debug=args.verbose,
        )
    except (NotADirectoryError, ValueError) as exc:
        print(f"Ошибка: {exc}", file=sys.stderr)
        return 2

    stats = task.run()
    prefix = "(предпросмотр) " if args.dry_run else ""
    print(f"{prefix}перемещено: {stats['moved']}, скопировано: "
          f"{stats['copied']}, пропущено: {stats['skipped']}, "
          f"ошибок: {stats['error']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))