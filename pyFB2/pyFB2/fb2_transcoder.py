# -*- coding: utf-8 -*-
"""Перекодирование FB2-файлов из windows-1251 (cp1251) в UTF-8.

Модуль читает FB2-файл в исходной кодировке, декодирует текст, приводит
XML-декларацию к целевой кодировке и записывает файл в UTF-8. Байты
переносов строк не изменяются (запись ведётся в бинарном режиме).

Возможности:
    * автоопределение исходной кодировки (BOM, затем ``encoding`` в
      XML-декларации) либо явное указание через ``--from``;
    * пропуск файлов, уже находящихся в целевой кодировке (кроме ``--force``);
    * режимы вывода: перезапись (по умолчанию, атомарная), отдельный каталог
      (``--out-dir``) или суффикс имени (``--suffix``);
    * предпросмотр без записи (``--dry-run``);
    * рекурсивная обработка каталога.

Пример:
    >>> from fb2_transcoder import Fb2Transcoder
    >>> transcoder = Fb2Transcoder()
    >>> transcoder.transcode_file("book.fb2")   # перезапись в UTF-8
    PosixPath('book.fb2')

CLI:
    python fb2_transcoder.py <файл.fb2 | каталог> [--from windows-1251]
        [--to utf-8] [--out-dir DIR] [--suffix S] [-r] [--force]
        [--dry-run] [--bom] [-q]
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional, Tuple, Union

#: Расширение FB2-файлов.
FB2_MASK = "*.fb2"

#: Кодировка-источник по умолчанию.
DEFAULT_SOURCE = "windows-1251"

#: Кодировка-назначение по умолчанию.
DEFAULT_TARGET = "utf-8"

#: BOM-последовательности -> имя кодировки (длинные проверяются первыми).
BOMS = (
    (b"\xef\xbb\xbf", "utf-8"),
    (b"\xff\xfe\x00\x00", "utf-32-le"),
    (b"\x00\x00\xfe\xff", "utf-32-be"),
    (b"\xff\xfe", "utf-16-le"),
    (b"\xfe\xff", "utf-16-be"),
)

#: XML-декларация в начале документа.
DECLARATION_RE = re.compile(r"^\ufeff?\s*<\?xml[^>]*\?>", re.IGNORECASE)

#: Атрибут encoding внутри XML-декларации.
ENCODING_ATTR_RE = re.compile(r"""encoding\s*=\s*["'][^"']*["']""", re.IGNORECASE)

#: Сколько байт читать для анализа декларации.
HEAD_SIZE = 4096

#: Коды возврата CLI.
EXIT_OK = 0
EXIT_ERRORS = 1
EXIT_USAGE = 2


def _normalize(encoding: str) -> str:
    """Нормализовать имя кодировки для сравнения."""
    return encoding.strip().casefold()


def detect_encoding(data: bytes) -> str:
    """Определить кодировку по BOM и XML-декларации.

    :param data: первые байты файла (или файл целиком).
    :return: имя кодировки (по умолчанию ``utf-8``, как в XML).
    """
    for bom, name in BOMS:
        if data.startswith(bom):
            return name

    match = re.search(rb"""encoding\s*=\s*["']([^"']+)["']""", data[:HEAD_SIZE], re.IGNORECASE)
    if match:
        return match.group(1).decode("ascii", "replace").strip()

    return DEFAULT_TARGET


@dataclass
class TranscodeResult:
    """Результат перекодирования одного файла.

    :param source: исходный путь.
    :param target: путь результата (None, если запись не выполнялась).
    :param source_encoding: фактически использованная кодировка-источник.
    :param skipped: True, если файл пропущен (уже в целевой кодировке).
    :param error: текст ошибки (None при успехе).
    """

    source: Path
    target: Optional[Path] = None
    source_encoding: str = ""
    skipped: bool = False
    error: Optional[str] = None

    @property
    def ok(self) -> bool:
        """Успешно ли выполнено перекодирование (включая пропуск)."""
        return self.error is None


class Fb2Transcoder:
    """Перекодировщик FB2-файлов.

    :param source_encoding: исходная кодировка; None — автоопределение.
    :param target_encoding: целевая кодировка.
    :param bom: добавлять ли BOM целевой кодировки при записи.
    :param force: перекодировать даже файлы, уже находящиеся в целевой
        кодировке.
    :param errors: политика обработки ошибок декодирования
        (``strict`` / ``replace`` / ``ignore``).
    """

    def __init__(
        self,
        source_encoding: Optional[str] = DEFAULT_SOURCE,
        target_encoding: str = DEFAULT_TARGET,
        bom: bool = False,
        force: bool = False,
        errors: str = "strict",
    ) -> None:
        self.source_encoding = source_encoding
        self.target_encoding = target_encoding
        self.bom = bom
        self.force = force
        self.errors = errors

    # --- Преобразование байтов --------------------------------------------
    def convert_bytes(self, data: bytes) -> Tuple[Optional[bytes], str, bool]:
        """Перекодировать содержимое FB2 из исходной кодировки в целевую.

        :param data: исходные байты файла.
        :return: кортеж (новые байты или None, использованная кодировка,
            был ли файл пропущен).
        :raises UnicodeDecodeError: если декодирование невозможно.
        """
        actual = detect_encoding(data)
        source = self.source_encoding or actual

        # Файл уже в целевой кодировке — пропускаем (кроме режима --force).
        # Проверка по фактической кодировке защищает от порчи файлов,
        # которые уже перекодированы, даже если --from задан явно.
        if not self.force and _normalize(actual) == _normalize(self.target_encoding):
            return None, actual, True

        payload = self._strip_bom(data)
        text = payload.decode(source, errors=self.errors)
        text = self._fix_declaration(text)
        result = text.encode(self.target_encoding)

        if self.bom:
            result = self._bom_bytes() + result
        return result, source, False

    def _strip_bom(self, data: bytes) -> bytes:
        """Убрать BOM из начала данных, если он есть."""
        for bom, _name in BOMS:
            if data.startswith(bom):
                return data[len(bom):]
        return data

    def _bom_bytes(self) -> bytes:
        """BOM для целевой кодировки (пустой, если не предусмотрен)."""
        target = _normalize(self.target_encoding)
        if target in ("utf-8", "utf8"):
            return b"\xef\xbb\xbf"
        if target in ("utf-16", "utf-16-le", "utf16"):
            return b"\xff\xfe"
        if target == "utf-16-be":
            return b"\xfe\xff"
        if target in ("utf-32", "utf-32-le"):
            return b"\xff\xfe\x00\x00"
        if target == "utf-32-be":
            return b"\x00\x00\xfe\xff"
        return b""

    def _fix_declaration(self, text: str) -> str:
        """Привести XML-декларацию к целевой кодировке.

        :param text: декодированный текст FB2.
        :return: текст с корректной декларацией.
        """
        declaration = f'<?xml version="1.0" encoding="{self.target_encoding}"?>'

        match = DECLARATION_RE.match(text)
        if match:
            old = match.group(0)
            if ENCODING_ATTR_RE.search(old):
                new = ENCODING_ATTR_RE.sub(f'encoding="{self.target_encoding}"', old)
            else:
                new = old.replace("?>", f' encoding="{self.target_encoding}"?>', 1)
            return new + text[match.end():]

        # Декларации нет — добавляем её в начало.
        return declaration + "\n" + text

    # --- Работа с файлами --------------------------------------------------
    def transcode_file(
        self,
        path: Union[str, Path],
        dest: Optional[Union[str, Path]] = None,
        dry_run: bool = False,
    ) -> TranscodeResult:
        """Перекодировать один файл.

        :param path: исходный файл.
        :param dest: файл назначения (None — перезапись исходного).
        :param dry_run: не записывать результат, только проверить.
        :return: :class:`TranscodeResult`.
        """
        source_path = Path(path)
        try:
            data = source_path.read_bytes()
        except OSError as exc:
            return TranscodeResult(source=source_path, error=f"Не удалось прочитать: {exc}")

        try:
            converted, used_encoding, skipped = self.convert_bytes(data)
        except UnicodeDecodeError as exc:
            return TranscodeResult(
                source=source_path,
                source_encoding=self.source_encoding or "",
                error=f"Ошибка декодирования ({exc.encoding}): {exc.reason}",
            )
        except LookupError as exc:
            return TranscodeResult(source=source_path, error=f"Неизвестная кодировка: {exc}")

        if skipped:
            return TranscodeResult(source=source_path, source_encoding=used_encoding, skipped=True)

        target_path = Path(dest) if dest else source_path
        if dry_run:
            return TranscodeResult(
                source=source_path,
                target=target_path,
                source_encoding=used_encoding,
            )

        try:
            self._write_atomic(target_path, converted or b"")
        except OSError as exc:
            return TranscodeResult(
                source=source_path,
                target=target_path,
                source_encoding=used_encoding,
                error=f"Не удалось записать: {exc}",
            )

        return TranscodeResult(
            source=source_path,
            target=target_path,
            source_encoding=used_encoding,
        )

    @staticmethod
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

    def transcode_dir(
        self,
        directory: Union[str, Path],
        out_dir: Optional[Union[str, Path]] = None,
        suffix: str = "",
        dry_run: bool = False,
    ) -> List[TranscodeResult]:
        """Перекодировать все FB2-файлы каталога (рекурсивно).

        :param directory: корневой каталог.
        :param out_dir: каталог для результатов (None — рядом с исходными).
        :param suffix: суффикс, добавляемый к имени файла.
        :param dry_run: не записывать результат.
        :return: список результатов.
        """
        root = Path(directory)
        out_root = Path(out_dir) if out_dir else None
        results: List[TranscodeResult] = []

        for fb2 in sorted(root.rglob(FB2_MASK)):
            dest = self._dest_path(fb2, root, out_root, suffix)
            results.append(self.transcode_file(fb2, dest=dest, dry_run=dry_run))
        return results

    @staticmethod
    def _dest_path(
        fb2: Path,
        root: Path,
        out_root: Optional[Path],
        suffix: str,
    ) -> Path:
        """Вычислить путь назначения для файла.

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


def _single_dest(
    target: Path,
    out_dir: Optional[str],
    suffix: str,
) -> Optional[Path]:
    """Вычислить путь назначения для одного файла.

    :param target: исходный файл.
    :param out_dir: каталог вывода (None — рядом с исходным).
    :param suffix: суффикс имени файла.
    :return: путь назначения или None (перезапись исходного).
    """
    if not out_dir and not suffix:
        return None
    name = target.stem + suffix + target.suffix
    base = Path(out_dir) if out_dir else target.parent
    return base / name


def _collect_targets(source: Union[str, Path], recursive: bool) -> List[Path]:
    """Собрать FB2-файлы для обработки.

    :param source: файл или каталог.
    :param recursive: обходить каталог рекурсивно.
    :return: список путей.
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
    :return: код возврата: 0 — успех, 1 — были ошибки, 2 — ошибка запуска.
    """
    parser = argparse.ArgumentParser(
        description="Перекодирование FB2 из windows-1251 в UTF-8.",
    )
    parser.add_argument("source", help="FB2-файл или каталог")
    parser.add_argument(
        "--from",
        dest="source_encoding",
        default=DEFAULT_SOURCE,
        help=f"исходная кодировка (по умолчанию {DEFAULT_SOURCE})",
    )
    parser.add_argument(
        "--to",
        dest="target_encoding",
        default=DEFAULT_TARGET,
        help=f"целевая кодировка (по умолчанию {DEFAULT_TARGET})",
    )
    parser.add_argument(
        "--auto",
        action="store_true",
        help="определять исходную кодировку автоматически (игнорирует --from)",
    )
    parser.add_argument("--out-dir", default=None, help="каталог для результатов")
    parser.add_argument("--suffix", default="", help="суффикс имени файла результата")
    parser.add_argument("-r", "--recursive", action="store_true", help="рекурсивный обход")
    parser.add_argument("--force", action="store_true", help="перекодировать и файлы в целевой кодировке")
    parser.add_argument("--bom", action="store_true", help="добавить BOM в результат")
    parser.add_argument("--dry-run", action="store_true", help="не записывать файлы")
    parser.add_argument("-q", "--quiet", action="store_true", help="выводить только ошибки и итог")
    args = parser.parse_args(argv)

    transcoder = Fb2Transcoder(
        source_encoding=None if args.auto else args.source_encoding,
        target_encoding=args.target_encoding,
        bom=args.bom,
        force=args.force,
    )

    source_path = Path(args.source)
    if source_path.is_dir():
        results = transcoder.transcode_dir(
            source_path,
            out_dir=args.out_dir,
            suffix=args.suffix,
            dry_run=args.dry_run,
        )
    else:
        targets = _collect_targets(args.source, args.recursive)
        if not targets:
            print(f"Ошибка: не найдено FB2-файлов: {args.source}", file=sys.stderr)
            return EXIT_USAGE
        results = [
            transcoder.transcode_file(
                target,
                dest=_single_dest(target, args.out_dir, args.suffix),
                dry_run=args.dry_run,
            )
            for target in targets
        ]

    errors = 0
    skipped = 0
    converted = 0
    for result in results:
        if not result.ok:
            errors += 1
            print(f"ОШИБКА: {result.source}: {result.error}", file=sys.stderr)
            continue
        if result.skipped:
            skipped += 1
            if not args.quiet:
                print(f"ПРОПУЩЕН (уже {args.target_encoding}): {result.source}")
            continue
        converted += 1
        if not args.quiet:
            mark = "(проверка)" if args.dry_run else "->"
            print(f"{result.source_encoding}: {result.source} {mark} {result.target}")

    print(
        f"Обработано: {len(results)}, перекодировано: {converted}, "
        f"пропущено: {skipped}, ошибок: {errors}",
        file=sys.stderr,
    )
    return EXIT_ERRORS if errors else EXIT_OK


if __name__ == "__main__":
    raise SystemExit(main())