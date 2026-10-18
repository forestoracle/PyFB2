# -*- coding: utf-8 -*-
"""fb2tools — единая командная строка для всех возможностей pyFB2.

Модуль объединяет в одну точку входа (подкоманды) все инструменты пакета:
разбор и вывод метаданных, валидацию по XSD, нормализацию и пересборку формы
(rewrite), конвертацию
(EPUB 2/3, DOCX, Markdown, HTML, TXT, PDF и обратно), разбиение и слияние,
индекс библиотеки, перекодировку, переименование, сканеры, извлечение
обложки, упаковку/распаковку ZIP-архивов и сетевые функции
(обложки/аннотации, статья об авторе).

Примеры::

    python -m pyFB2.fb2tools info book.fb2
    python -m pyFB2.fb2tools validate library/ -r
    python -m pyFB2.fb2tools normalize book.fb2 --dry-run --validate
    python -m pyFB2.fb2tools rewrite library/ --out-dir clean --validate
    python -m pyFB2.fb2tools convert book.fb2 book.epub --epub3
    python -m pyFB2.fb2tools convert book.epub book.fb2
    python -m pyFB2.fb2tools split book.fb2 -o parts --by parts --parts 3
    python -m pyFB2.fb2tools merge out.fb2 a.fb2 b.fb2 --title "Сборник"
    python -m pyFB2.fb2tools fetch book.fb2 --cover-out covers/
    python -m pyFB2.fb2tools wiki book.fb2 --out author.md
    python -m pyFB2.fb2tools index build library/ --db lib.db
    python -m pyFB2.fb2tools index search "Толстой"
    python -m pyFB2.fb2tools transcode library/ -r --from windows-1251
    python -m pyFB2.fb2tools rename book.fb2 --template "${Al} - ${Tt}"
    python -m pyFB2.fb2tools scan authors library/
    python -m pyFB2.fb2tools cover book.fb2 -o cover.jpg
    python -m pyFB2.fb2tools zip library/ --remove
    python -m pyFB2.fb2tools unzip library/ --remove

Полный список команд и опций: ``python -m pyFB2.fb2tools --help``.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import List, Optional

#: Коды возврата CLI.
EXIT_OK = 0
EXIT_ERRORS = 1
EXIT_USAGE = 2

#: Форматы, в которые умеет конвертировать pyFB2 (FB2 -> формат).
EXPORT_FORMATS = {
    "epub": "epub",
    "docx": "docx",
    "md": "markdown",
    "markdown": "markdown",
    "html": "html",
    "htm": "html",
    "txt": "txt",
    "text": "txt",
    "pdf": "pdf",
    "odt": "odt",
    "mobi": "mobi",
    "prc": "mobi",
    "fb3": "fb3",
}

#: Форматы, из которых pyFB2 умеет конвертировать в FB2 (формат -> FB2).
IMPORT_FORMATS = {
    "epub": "epub",
    "docx": "docx",
    "md": "markdown",
    "markdown": "markdown",
    "html": "html",
    "htm": "html",
    "odt": "odt",
    "mobi": "mobi",
    "prc": "mobi",
    "fb3": "fb3",
    "pdf": "pdf",
}


def _error(message: str) -> None:
    """Вывести сообщение об ошибке в stderr."""
    print(f"Ошибка: {message}", file=sys.stderr)


def _collect_fb2(path, recursive: bool = True) -> List[Path]:
    """Собрать FB2-файлы по пути (один файл или каталог)."""
    target = Path(path)
    if target.is_file():
        return [target]
    if not target.is_dir():
        return []
    pattern = "**/*.fb2" if recursive else "*.fb2"
    return sorted(target.glob(pattern))


def _require_module(module: str, extra: str):
    """Импортировать опциональный модуль пакета с понятной ошибкой.

    :param module: имя подмодуля (например, ``fb2_to_pdf``).
    :param extra: имя extras-группы (например, ``pdf``).
    :raises RuntimeError: если модуль недоступен из-за отсутствия зависимостей.
    """
    import importlib

    try:
        return importlib.import_module(f"{__package__}.{module}")
    except ImportError as exc:  # pragma: no cover - зависит от окружения
        raise RuntimeError(
            f"модуль {module} недоступен ({exc}); установите: pip install \"pyFB2[{extra}]\""
        ) from exc


def build_parser() -> argparse.ArgumentParser:
    """Собрать парсер аргументов со всеми подкомандами."""
    parser = argparse.ArgumentParser(
        prog="fb2tools",
        description=(
            "pyFB2: единая командная строка — разбор, валидация, нормализация, "
            "конвертация, индекс, разбиение/слияние, обложки/аннотации и другое."
        ),
    )
    subparsers = parser.add_subparsers(dest="command", metavar="КОМАНДА")

    # --- info -------------------------------------------------------------
    p = subparsers.add_parser("info", help="метаданные и дерево заголовков")
    p.add_argument("source", help="FB2-файл")
    p.add_argument("--images", default=None, help="каталог для выгрузки <binary>")
    p.add_argument("--ids", action="store_true", help="показывать id заголовков")
    p.set_defaults(handler=cmd_info)

    # --- validate ---------------------------------------------------------
    p = subparsers.add_parser("validate", help="валидация по XSD-схеме")
    p.add_argument("source", help="FB2-файл или каталог")
    p.add_argument("-r", "--recursive", action="store_true", help="рекурсивный обход")
    p.add_argument("--schema", default=None, help="путь к FictionBook.xsd")
    p.add_argument("-q", "--quiet", action="store_true", help="только итог")
    p.set_defaults(handler=cmd_validate)

    # --- normalize --------------------------------------------------------
    p = subparsers.add_parser("normalize", help="нормализация/авто-исправление FB2")
    p.add_argument("source", help="FB2-файл или каталог")
    p.add_argument("-r", "--recursive", action="store_true", help="рекурсивный обход")
    p.add_argument("--out-dir", default=None, help="каталог для результатов")
    p.add_argument("--suffix", default="", help="суффикс имени результата")
    p.add_argument("--dry-run", action="store_true", help="не записывать результат")
    p.add_argument("--validate", action="store_true", help="проверить результат по XSD")
    p.add_argument("-q", "--quiet", action="store_true", help="только итог и ошибки")
    p.set_defaults(handler=cmd_normalize)

    # --- rewrite ----------------------------------------------------------
    p = subparsers.add_parser(
        "rewrite", help="пересборка FB2 (структуры -> XML, канонизация формы)"
    )
    p.add_argument("source", help="FB2-файл или каталог")
    p.add_argument("--out", default=None, help="файл результата (для одного FB2)")
    p.add_argument("--out-dir", default=None, help="каталог для результатов")
    p.add_argument("--suffix", default="", help="суффикс имени результата")
    p.add_argument("--no-indent", action="store_true", help="не форматировать отступами")
    p.add_argument("--dry-run", action="store_true", help="не записывать результат")
    p.add_argument("--validate", action="store_true", help="проверить результат по XSD")
    p.add_argument("--schema", default=None, help="путь к FictionBook.xsd")
    p.add_argument("--force", action="store_true", help="писать даже неизменённые файлы")
    p.add_argument("-q", "--quiet", action="store_true", help="только итог и ошибки")
    p.set_defaults(handler=cmd_rewrite)

    # --- convert ----------------------------------------------------------
    p = subparsers.add_parser(
        "convert",
        help="конвертация FB2 <-> EPUB/DOCX/Markdown/HTML/ODT/MOBI/FB3/TXT/PDF",
    )
    p.add_argument("source", help="исходный файл")
    p.add_argument("target", nargs="?", default=None, help="файл результата")
    p.add_argument(
        "--to",
        default=None,
        help=(
            "формат результата, если не задан target "
            "(epub/docx/md/html/odt/mobi/fb3/txt/pdf)"
        ),
    )
    p.add_argument("--epub3", action="store_true", help="собирать EPUB 3.0")
    p.add_argument(
        "--toc", action="store_true", help="вставлять оглавление (html/txt/pdf)"
    )
    p.add_argument(
        "--image-dir", default="images", help="каталог картинок (html/md)"
    )
    p.set_defaults(handler=cmd_convert)

    # --- split ------------------------------------------------------------
    p = subparsers.add_parser("split", help="разбиение FB2 на части")
    p.add_argument("source", help="исходный FB2")
    p.add_argument("-o", "--out-dir", default=None, help="каталог для частей")
    p.add_argument("--stem", default=None, help="основа имени файла части")
    p.add_argument(
        "--by", choices=("sections", "size", "parts"), default="sections",
        help="режим разбиения",
    )
    p.add_argument("--level", type=int, default=1, help="глубина секций для нарезки")
    p.add_argument("--max-size", type=int, default=0, help="предельный размер (байты)")
    p.add_argument("--parts", type=int, default=0, help="число частей")
    p.add_argument("--title-suffix", default="", help="суффикс названия части")
    p.set_defaults(handler=cmd_split)

    # --- merge ------------------------------------------------------------
    p = subparsers.add_parser("merge", help="слияние нескольких FB2 в один")
    p.add_argument("output", help="выходной FB2")
    p.add_argument("sources", nargs="+", help="исходные FB2")
    p.add_argument("--title", default=None, help="название итоговой книги")
    p.add_argument(
        "--no-source-titles", action="store_true",
        help="не добавлять заголовки исходных книг",
    )
    p.set_defaults(handler=cmd_merge)

    # --- fetch ------------------------------------------------------------
    p = subparsers.add_parser("fetch", help="обложка/аннотация книги из сети")
    p.add_argument("source", help="FB2-файл")
    p.add_argument(
        "--out", default=None, help="файл результата (по умолчанию — перезапись)"
    )
    p.add_argument(
        "--provider",
        action="append",
        choices=("openlibrary", "google", "fantlab"),
        default=None,
        help="источник (можно указать несколько раз)",
    )
    p.add_argument("--lang", default="ru", help="предпочитаемый язык книги")
    p.add_argument("--limit", type=int, default=5, help="сколько результатов запрашивать")
    p.add_argument("--no-cover", action="store_true", help="не записывать обложку")
    p.add_argument("--no-annotation", action="store_true", help="не записывать аннотацию")
    p.add_argument("--list", action="store_true", help="только показать найденные варианты")
    p.add_argument("--cover-out", default=None, help="сохранить обложку отдельным файлом")
    p.add_argument("--dry-run", action="store_true", help="не записывать результат")
    p.set_defaults(handler=cmd_fetch)

    # --- wiki -------------------------------------------------------------
    p = subparsers.add_parser("wiki", help="статья об авторе в Википедии (Markdown)")
    p.add_argument("source", help="имя автора или путь к FB2")
    p.add_argument("--lang", default="ru", help="код языка Википедии")
    p.add_argument("--out", default=None, help="файл для сохранения Markdown")
    p.add_argument("--title", default=None, help="точное название статьи")
    p.add_argument("--list", action="store_true", help="только показать найденные статьи")
    p.set_defaults(handler=cmd_wiki)

    # --- index ------------------------------------------------------------
    p = subparsers.add_parser("index", help="SQLite-индекс библиотеки")
    p.add_argument(
        "action",
        choices=(
            "build", "stats", "authors", "genres", "duplicates", "search", "find",
        ),
        help="действие",
    )
    p.add_argument(
        "value", nargs="?", default=None,
        help="каталог (для build) или запрос (для search/find)",
    )
    p.add_argument("--db", default=None, help="путь к базе (по умолчанию fb2_index.db)")
    p.add_argument("-r", "--recursive", action="store_true", help="обход каталога рекурсивно")
    p.add_argument("--force", action="store_true", help="переиндексировать файлы")
    p.add_argument("--limit", type=int, default=50, help="ограничение вывода")
    p.add_argument(
        "--by", default="any",
        choices=("any", "author", "title", "series", "genre", "year"),
        help="поле поиска для search (any — все поля)",
    )
    p.add_argument(
        "--no-text", action="store_true",
        help="не индексировать текст книг (build)",
    )
    p.add_argument(
        "--text-limit", type=int, default=None,
        help="сколько символов текста хранить на книгу (build)",
    )
    p.add_argument(
        "--snippet-length", type=int, default=200,
        help="длина фрагмента текста для find",
    )
    p.set_defaults(handler=cmd_index)

    # --- transcode --------------------------------------------------------
    p = subparsers.add_parser("transcode", help="перекодировка FB2 (например, в UTF-8)")
    p.add_argument("source", help="FB2-файл или каталог")
    p.add_argument(
        "--from", dest="from_encoding", default="windows-1251",
        help="исходная кодировка (по умолчанию windows-1251)",
    )
    p.add_argument(
        "--to", dest="to_encoding", default="utf-8", help="целевая кодировка"
    )
    p.add_argument("--out-dir", default=None, help="каталог для результатов")
    p.add_argument("--suffix", default="", help="суффикс имени результата")
    p.add_argument("-r", "--recursive", action="store_true", help="рекурсивный обход")
    p.add_argument("--force", action="store_true", help="обрабатывать и уже перекодированные")
    p.add_argument("--dry-run", action="store_true", help="не записывать результат")
    p.set_defaults(handler=cmd_transcode)

    # --- rename -----------------------------------------------------------
    p = subparsers.add_parser("rename", help="переименование FB2 по шаблону")
    p.add_argument("source", help="FB2-файл или каталог")
    p.add_argument(
        "--template", required=True,
        help="шаблон имени, например \"${Al} - ${Tt}\" (см. fb2_renamer)",
    )
    p.add_argument("--out-dir", default="", help="подкаталог для результата")
    p.add_argument("-r", "--recursive", action="store_true", help="обход каталога рекурсивно")
    p.set_defaults(handler=cmd_rename)

    # --- scan -------------------------------------------------------------
    p = subparsers.add_parser("scan", help="сканеры авторов и кодировок")
    p.add_argument("what", choices=("authors", "encoding"), help="что искать")
    p.add_argument("directory", help="каталог для обхода")
    p.add_argument("-v", "--verbose", action="store_true", help="подробный вывод")
    p.set_defaults(handler=cmd_scan)

    # --- cover ------------------------------------------------------------
    p = subparsers.add_parser("cover", help="извлечь обложку из FB2")
    p.add_argument("source", help="FB2-файл")
    p.add_argument("-o", "--out", default=None, help="файл или каталог для обложки")
    p.set_defaults(handler=cmd_cover)

    # --- zip --------------------------------------------------------------
    p = subparsers.add_parser("zip", help="упаковать FB2 в ZIP-архивы (.fb2.zip)")
    p.add_argument("source", help="FB2-файл или каталог")
    p.add_argument("--out-dir", default=None, help="каталог для архивов")
    p.add_argument("--remove", action="store_true", help="удалять исходные FB2 после упаковки")
    p.add_argument(
        "--skip-existing", action="store_true", help="не пересобирать существующие архивы"
    )
    p.add_argument("--dry-run", action="store_true", help="не записывать архивы")
    p.add_argument("-q", "--quiet", action="store_true", help="только итог и ошибки")
    p.set_defaults(handler=cmd_zip)

    # --- unzip ------------------------------------------------------------
    p = subparsers.add_parser("unzip", help="распаковать архивы FB2 (.fb2.zip)")
    p.add_argument("source", help="ZIP-архив или каталог с архивами")
    p.add_argument("--out-dir", default=None, help="каталог для распакованных FB2")
    p.add_argument("--remove", action="store_true", help="удалять архивы после распаковки")
    p.add_argument("--dry-run", action="store_true", help="не распаковывать (только список)")
    p.add_argument("-q", "--quiet", action="store_true", help="только итог и ошибки")
    p.set_defaults(handler=cmd_unzip)

    return parser


# ---------------------------------------------------------------------------
# Обработчики подкоманд
# ---------------------------------------------------------------------------
def cmd_info(args) -> int:
    """Показать метаданные книги и дерево заголовков."""
    from .fb2_parser import Fb2Parser

    source = Path(args.source)
    if not source.is_file():
        _error(f"файл не найден: {source}")
        return EXIT_ERRORS

    parser = Fb2Parser(source)
    try:
        description = parser.parse()
    except (ValueError, OSError) as exc:
        _error(str(exc))
        return EXIT_ERRORS

    stylesheets = parser.parse_stylesheets()
    if stylesheets:
        print("== stylesheets ==")
        for sheet in stylesheets:
            print(f"[{sheet.type}]")
            print(sheet.value)

    binaries = parser.parse_binaries()
    if binaries:
        print("== binaries ==")
        for binary in binaries:
            size = len(parser.binary_data(binary))
            print(f"{binary.id} [{binary.content_type}] ({size} байт)")

    if args.images:
        for path in parser.save_binaries(args.images):
            print(f"сохранено: {path}")

    print(parser.describe(description))

    bodies = parser.parse_bodies()
    if bodies:
        print(parser.describe_bodies(bodies, with_ids=args.ids))
    return EXIT_OK


def cmd_validate(args) -> int:
    """Проверить FB2 по XSD-схеме."""
    from .fb2_validator import Fb2Validator

    try:
        validator = Fb2Validator(schema_path=args.schema)
    except (FileNotFoundError, RuntimeError) as exc:
        _error(str(exc))
        return EXIT_ERRORS

    target = Path(args.source)
    if target.is_dir():
        results = validator.validate_dir(target)
    else:
        files = _collect_fb2(target, recursive=args.recursive)
        if not files:
            _error(f"не найдено FB2-файлов: {args.source}")
            return EXIT_ERRORS
        results = [validator.validate_file(path) for path in files]

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
    return EXIT_ERRORS if invalid else EXIT_OK


def cmd_normalize(args) -> int:
    """Нормализовать FB2 (авто-исправление)."""
    from .fb2_normalizer import Fb2Normalizer

    normalizer = Fb2Normalizer(validate=args.validate)
    target = Path(args.source)

    if target.is_dir():
        results = normalizer.normalize_dir(
            target, out_dir=args.out_dir, suffix=args.suffix, dry_run=args.dry_run
        )
    else:
        files = _collect_fb2(target, recursive=args.recursive)
        if not files:
            _error(f"не найдено FB2-файлов: {args.source}")
            return EXIT_ERRORS
        results = []
        for path in files:
            dest = None
            if args.out_dir:
                dest = Path(args.out_dir) / path.name
            elif args.suffix:
                dest = path.with_name(path.stem + args.suffix + path.suffix)
            results.append(
                normalizer.normalize_file(path, dest=dest, dry_run=args.dry_run)
            )

    errors = 0
    for result in results:
        if not result.ok:
            errors += 1
            print(f"ОШИБКА: {result.source}", file=sys.stderr)
            print(f"  - {result.error}", file=sys.stderr)
            continue
        if args.quiet:
            continue
        status = "изменён" if result.changed else "без изменений"
        xsd = ""
        if result.valid_after is not None:
            xsd = " [XSD: OK]" if result.valid_after else " [XSD: ОШИБКИ]"
        print(f"{result.source}: {status} (правок: {len(result.fixes)}){xsd}")
        for fix in result.fixes:
            print(f"  - {fix}")

    print(f"Обработано файлов: {len(results)}, ошибок: {errors}", file=sys.stderr)
    return EXIT_ERRORS if errors else EXIT_OK


def cmd_rewrite(args) -> int:
    """Пересобрать FB2: файл -> структуры -> файл (канонизация формы)."""
    from .fb2_rewrite import Fb2Rewriter

    rewriter = Fb2Rewriter(
        indent=not args.no_indent,
        validate=args.validate,
        schema_path=args.schema,
        force=args.force,
    )
    target = Path(args.source)

    if target.is_dir():
        results = rewriter.rewrite_dir(
            target, out_dir=args.out_dir, suffix=args.suffix, dry_run=args.dry_run
        )
    else:
        if not target.is_file():
            _error(f"файл не найден: {target}")
            return EXIT_ERRORS
        dest = Path(args.out) if args.out else _sibling_destination(
            target, args.out_dir, args.suffix
        )
        results = [rewriter.rewrite_file(target, dest=dest, dry_run=args.dry_run)]

    errors = 0
    for result in results:
        if not result.ok:
            errors += 1
            print(f"ОШИБКА: {result.source}: {result.error}", file=sys.stderr)
            continue
        if result.skipped:
            if not args.quiet:
                print(f"без изменений: {result.source}")
            continue
        if args.quiet:
            continue
        xsd = ""
        if result.valid is not None:
            xsd = " [XSD: OK]" if result.valid else " [XSD: ОШИБКИ]"
        mark = "(проверка)" if args.dry_run else "->"
        print(f"{result.source} {mark} {result.target}{xsd}")

    print(f"Обработано файлов: {len(results)}, ошибок: {errors}", file=sys.stderr)
    return EXIT_ERRORS if errors else EXIT_OK


def _resolve_conversion(source: Path, target_arg, to_format):
    """Определить файл результата, направление и формат конвертации.

    :return: ``(target, direction, kind)``, где ``direction`` — ``export``
        (FB2 -> формат) или ``import`` (формат -> FB2); ``(None, None, None)``,
        если направление определить не удалось.
    """
    source_format = source.suffix.lower().lstrip(".")
    if target_arg:
        target = Path(target_arg)
        target_format = target.suffix.lower().lstrip(".")
    elif to_format:
        target_format = to_format.lower().lstrip(".")
        target = source.with_suffix(f".{target_format}")
    else:
        return None, None, None

    if source_format == "fb2" and target_format in EXPORT_FORMATS:
        return target, "export", EXPORT_FORMATS[target_format]
    if source_format in IMPORT_FORMATS and target_format == "fb2":
        return target, "import", IMPORT_FORMATS[source_format]
    return target, None, None


def _make_converter(kind: str, direction: str, args):
    """Создать конвертер нужного типа (None, если тип неизвестен)."""
    if direction == "export":
        if kind == "epub":
            from .fb2_to_epub import Fb2ToEpubConverter

            return Fb2ToEpubConverter(epub_version=3 if args.epub3 else 2)
        if kind == "docx":
            from .fb2_to_docx import Fb2ToDocxConverter

            return Fb2ToDocxConverter()
        if kind == "markdown":
            from .fb2_to_markdown import Fb2ToMarkdownConverter

            return Fb2ToMarkdownConverter(image_dir=args.image_dir)
        if kind == "html":
            from .fb2_to_html import Fb2ToHtmlConverter

            return Fb2ToHtmlConverter(image_dir=args.image_dir, include_toc=args.toc)
        if kind == "txt":
            from .fb2_to_txt import Fb2ToTxtConverter

            return Fb2ToTxtConverter(include_toc=args.toc)
        if kind == "pdf":
            module = _require_module("fb2_to_pdf", "pdf")
            return module.Fb2ToPdfConverter(include_toc=args.toc)
        if kind == "odt":
            from .fb2_to_odt import Fb2ToOdtConverter

            return Fb2ToOdtConverter()
        if kind == "mobi":
            from .fb2_to_mobi import Fb2ToMobiConverter

            return Fb2ToMobiConverter()
        if kind == "fb3":
            from .fb2_to_fb3 import Fb2ToFb3Converter

            return Fb2ToFb3Converter()
    else:
        if kind == "epub":
            from .epub_to_fb2 import EpubToFb2Converter

            return EpubToFb2Converter()
        if kind == "docx":
            from .docx_to_fb2 import DocxToFb2Converter

            return DocxToFb2Converter()
        if kind == "markdown":
            from .markdown_to_fb2 import MarkdownToFb2Converter

            return MarkdownToFb2Converter()
        if kind == "html":
            from .html_to_fb2 import HtmlToFb2Converter

            return HtmlToFb2Converter()
        if kind == "odt":
            from .odt_to_fb2 import OdtToFb2Converter

            return OdtToFb2Converter()
        if kind == "mobi":
            from .mobi_to_fb2 import MobiToFb2Converter

            return MobiToFb2Converter()
        if kind == "fb3":
            from .fb3_to_fb2 import Fb3ToFb2Converter

            return Fb3ToFb2Converter()
        if kind == "pdf":
            module = _require_module("pdf_to_fb2", "pdf")
            return module.PdfToFb2Converter()
    return None


def cmd_convert(args) -> int:
    """Конвертировать между FB2 и другими форматами."""
    source = Path(args.source)
    if not source.is_file():
        _error(f"файл не найден: {source}")
        return EXIT_ERRORS

    target, direction, kind = _resolve_conversion(source, args.target, args.to)
    if direction is None:
        _error(
            f"не удалось определить направление конвертации для {args.source!r}; "
            "поддержано: FB2 <-> EPUB/DOCX/Markdown/HTML/ODT/MOBI/FB3/PDF, "
            "FB2 -> TXT (укажите файл результата или --to ФОРМАТ)"
        )
        return EXIT_USAGE

    try:
        converter = _make_converter(kind, direction, args)
    except RuntimeError as exc:
        _error(str(exc))
        return EXIT_ERRORS
    if converter is None:
        _error(f"конвертер не найден: {kind} ({direction})")
        return EXIT_ERRORS

    path = converter.write(source, target)
    print(f"Создано: {path}")
    return EXIT_OK


def cmd_split(args) -> int:
    """Разбить FB2 на части."""
    from .fb2_split_merge import Fb2Splitter

    try:
        splitter = Fb2Splitter(
            level=args.level,
            by=args.by,
            max_size=args.max_size,
            parts=args.parts,
            title_suffix=args.title_suffix,
        )
    except ValueError as exc:
        _error(str(exc))
        return EXIT_USAGE

    try:
        paths = splitter.split(args.source, out_dir=args.out_dir, stem=args.stem)
    except (OSError, ValueError) as exc:
        _error(str(exc))
        return EXIT_ERRORS

    if not paths:
        _error("не найдено секций для разбиения")
        return EXIT_ERRORS
    for path in paths:
        print(path)
    print(f"Частей: {len(paths)}", file=sys.stderr)
    return EXIT_OK


def cmd_merge(args) -> int:
    """Слить несколько FB2 в один."""
    from .fb2_split_merge import Fb2Merger

    merger = Fb2Merger(
        title=args.title,
        add_source_titles=not args.no_source_titles,
    )
    try:
        path = merger.merge_to_file(args.sources, args.output)
    except (OSError, ValueError) as exc:
        _error(str(exc))
        return EXIT_ERRORS
    print(path)
    return EXIT_OK


def cmd_fetch(args) -> int:
    """Скачать обложку/аннотацию книги и встроить их в FB2."""
    from .fb2_web_metadata import DEFAULT_PROVIDERS, Fb2MetadataFetcher

    fetcher = Fb2MetadataFetcher(
        providers=tuple(args.provider) if args.provider else DEFAULT_PROVIDERS,
        language=args.lang,
    )

    try:
        title, author = fetcher.book_query(args.source)
    except (OSError, ValueError) as exc:
        _error(f"не удалось прочитать FB2: {exc}")
        return EXIT_ERRORS

    if not title:
        _error("в файле не найдено название книги")
        return EXIT_ERRORS
    print(f"Книга: {title}" + (f" — {author}" if author else ""))

    matches = fetcher.search(title, author, limit=args.limit)
    if not matches:
        _error("ничего не найдено в каталогах")
        return EXIT_ERRORS

    if args.list:
        for index, match in enumerate(matches, 1):
            print(f"{index}. {match}")
        return EXIT_OK

    # Предпочитаем запись с обложкой.
    best = next((match for match in matches if match.cover_url), matches[0])
    meta = fetcher.enrich(best)
    print(f"Источник: {meta}")
    if meta.cover_data:
        print(f"Обложка: {len(meta.cover_data)} байт")
    if meta.annotation:
        print(f"Аннотация: {meta.annotation[:80]}…")

    if args.cover_out:
        print(f"Обложка сохранена: {fetcher.save_cover(meta, args.cover_out)}")

    try:
        target = fetcher.apply(
            args.source,
            meta=meta,
            output=args.out,
            set_cover=not args.no_cover,
            set_annotation=not args.no_annotation,
            dry_run=args.dry_run,
        )
    except RuntimeError as exc:
        _error(str(exc))
        return EXIT_ERRORS

    if args.dry_run:
        print("(dry-run: файл не изменён)")
    else:
        print(f"Записано: {target}")
    return EXIT_OK


def cmd_wiki(args) -> int:
    """Скачать статью об авторе книги в Markdown."""
    module = _require_module("fb2_wiki", "wiki")
    wiki = module.WikipediaAuthor(lang=args.lang)

    source = Path(args.source)
    if source.is_file() and source.suffix.lower() == ".fb2":
        try:
            author_name = wiki.author_from_fb2(source)
        except (RuntimeError, ValueError) as exc:
            _error(str(exc))
            return EXIT_ERRORS
        print(f"Автор книги: {author_name}")
    else:
        author_name = args.source

    if args.list:
        candidates = wiki.search(author_name)
        if not candidates:
            _error("ничего не найдено")
            return EXIT_ERRORS
        for candidate in candidates:
            print(candidate)
        return EXIT_OK

    try:
        if args.title:
            used_title = args.title
            markdown = wiki.article_markdown(used_title)
        else:
            candidates = wiki.search(author_name)
            if not candidates:
                _error(f"ничего не найдено: {author_name}")
                return EXIT_ERRORS
            used_title = candidates[0]
            markdown = wiki.article_markdown(used_title)
    except RuntimeError as exc:
        _error(str(exc))
        return EXIT_ERRORS

    if args.out:
        print(f"Статья: {used_title}")
        print(f"Сохранено: {wiki.save(markdown, args.out)}")
    else:
        print(markdown)
    return EXIT_OK


def cmd_index(args) -> int:
    """Работа с SQLite-индексом библиотеки."""
    from .fb2_errors import Fb2OperationError
    from .fb2_index import DEFAULT_DB, DEFAULT_TEXT_LIMIT, Fb2Index

    db_path = args.db or DEFAULT_DB
    try:
        index = Fb2Index(
            db_path=db_path,
            index_text=not args.no_text,
            text_limit=args.text_limit or DEFAULT_TEXT_LIMIT,
        )
    except (OSError, RuntimeError) as exc:
        _error(str(exc))
        return EXIT_ERRORS

    try:
        if args.action == "build":
            if not args.value:
                _error("для действия build укажите каталог с FB2")
                return EXIT_USAGE
            counters = index.build(
                args.value, recursive=args.recursive, force=args.force,
                index_text=not args.no_text,
            )
            print(
                "Индекс обновлён (база: {db}): добавлено {added}, "
                "обновлено {updated}, пропущено {skipped}, ошибок {error}".format(
                    db=db_path, **counters
                )
            )
            return EXIT_OK

        if args.action == "stats":
            stats = index.stats()
            print(
                f"книг: {stats['books']} (валидных: {stats['valid']}, "
                f"с ошибками: {stats['broken']})"
            )
            print(f"авторов: {stats['authors']} | жанров: {stats['genres']}")
            print(f"с текстом в индексе: {stats['text']}")
            print("кодировки:")
            for encoding, count in stats["encodings"].items():
                print(f"  {encoding}: {count}")
            print("языки:")
            for lang, count in stats["langs"].items():
                print(f"  {lang}: {count}")
            return EXIT_OK

        if args.action == "authors":
            for name, count in index.top_authors(limit=args.limit):
                print(f"{count:6d}  {name}")
            return EXIT_OK

        if args.action == "genres":
            for genre, count in index.genre_counts():
                print(f"{count:6d}  {genre}")
            return EXIT_OK

        if args.action == "duplicates":
            for digest, count in index.duplicate_hashes(limit=args.limit):
                print(f"{count:6d}  {digest}")
            return EXIT_OK

        if args.action == "search":
            if not args.value:
                _error("для действия search укажите запрос")
                return EXIT_USAGE
            hits = index.search_books(args.value, by=args.by, limit=args.limit)
            if not hits:
                print("Ничего не найдено.", file=sys.stderr)
                return EXIT_ERRORS
            for hit in hits:
                extra = ", ".join(
                    part for part in (hit.authors, hit.series, hit.year) if part
                )
                if extra:
                    print(f"{hit.title} — {extra} | {hit.path}")
                else:
                    print(f"{hit.title} | {hit.path}")
            return EXIT_OK

        if args.action == "find":
            if not args.value:
                _error("для действия find укажите запрос")
                return EXIT_USAGE
            try:
                text_hits = index.search_text(
                    args.value, limit=args.limit,
                    snippet_length=args.snippet_length,
                )
            except Fb2OperationError as exc:
                _error(str(exc))
                return EXIT_ERRORS
            if not text_hits:
                print("Ничего не найдено.", file=sys.stderr)
                return EXIT_ERRORS
            for text_hit in text_hits:
                print(f"{text_hit.title} | {text_hit.path}")
                print(f"  {text_hit.snippet}")
            return EXIT_OK
    finally:
        index.close()

    _error(f"неизвестное действие: {args.action}")
    return EXIT_USAGE


def _sibling_destination(path: Path, out_dir, suffix: str):
    """Путь результата для одного файла (None — перезапись исходного)."""
    if out_dir:
        return Path(out_dir) / path.name
    if suffix:
        return path.with_name(path.stem + suffix + path.suffix)
    return None


def cmd_transcode(args) -> int:
    """Перекодировать FB2 (по умолчанию windows-1251 -> utf-8)."""
    from .fb2_transcoder import Fb2Transcoder

    transcoder = Fb2Transcoder(
        source_encoding=args.from_encoding,
        target_encoding=args.to_encoding,
        force=args.force,
    )
    target = Path(args.source)

    if target.is_dir():
        results = transcoder.transcode_dir(
            target, out_dir=args.out_dir, suffix=args.suffix, dry_run=args.dry_run
        )
    else:
        if not target.is_file():
            _error(f"файл не найден: {target}")
            return EXIT_ERRORS
        results = [
            transcoder.transcode_file(
                target,
                dest=_sibling_destination(target, args.out_dir, args.suffix),
                dry_run=args.dry_run,
            )
        ]

    errors = 0
    for result in results:
        if not result.ok:
            errors += 1
            print(f"ОШИБКА: {result.source}: {result.error}", file=sys.stderr)
            continue
        if result.skipped:
            print(f"пропущен (уже в целевой кодировке): {result.source}")
        elif args.dry_run:
            print(f"{result.source}: {result.source_encoding} -> {args.to_encoding}")
        else:
            print(f"{result.target} ({result.source_encoding} -> {args.to_encoding})")

    print(f"Обработано файлов: {len(results)}, ошибок: {errors}", file=sys.stderr)
    return EXIT_ERRORS if errors else EXIT_OK


def cmd_rename(args) -> int:
    """Переименовать FB2 по шаблону (файл или каталог)."""
    from .fb2_group_renamer import FB2GroupRenamer
    from .fb2_renamer import FB2Renamer

    target = Path(args.source)
    if target.is_dir():
        try:
            group_renamer = FB2GroupRenamer(
                start_dir=str(target), out_dir=args.out_dir, template=args.template
            )
            count = group_renamer.rename_all(recursive=args.recursive)
        except (RuntimeError, ValueError, OSError) as exc:
            _error(str(exc))
            return EXIT_ERRORS
        print(f"Переименовано файлов: {count}")
        return EXIT_OK if count else EXIT_ERRORS

    if not target.is_file():
        _error(f"файл не найден: {target}")
        return EXIT_ERRORS

    try:
        renamer = FB2Renamer(str(target), args.template, args.out_dir)
        new_name = renamer.rename()
    except (RuntimeError, ValueError, OSError) as exc:
        _error(str(exc))
        return EXIT_ERRORS
    print(f"Переименовано: {new_name}")
    return EXIT_OK


def cmd_scan(args) -> int:
    """Сканеры: различающиеся авторы или кодировки в дереве каталогов."""
    from .fb2_author_scanner import Fb2AuthorScanner
    from .fb2_encoding_scanner import Fb2EncodingScanner

    directory = Path(args.directory)
    if not directory.is_dir():
        _error(f"каталог не найден: {directory}")
        return EXIT_ERRORS

    if args.what == "authors":
        found = Fb2AuthorScanner(str(directory)).scan()
        empty_message = "Каталогов с различающимися авторами не найдено."
    else:
        found = Fb2EncodingScanner(str(directory)).scan()
        empty_message = "Каталогов с различающимися кодировками не найдено."

    for path, values in found:
        try:
            label = path.relative_to(directory)
        except ValueError:  # pragma: no cover - путь вне дерева
            label = path
        print(f"{label}: {'; '.join(values)}" if args.verbose else str(label))

    if not found:
        print(empty_message, file=sys.stderr)
    return EXIT_OK


def cmd_cover(args) -> int:
    """Извлечь обложку книги из FB2."""
    from .fb2_parser import Fb2Parser

    source = Path(args.source)
    if not source.is_file():
        _error(f"файл не найден: {source}")
        return EXIT_ERRORS

    parser = Fb2Parser(source)
    try:
        description = parser.parse()
    except (ValueError, OSError) as exc:
        _error(str(exc))
        return EXIT_ERRORS

    title_info = description.title_info
    coverpage = title_info.coverpage if title_info is not None else None
    if coverpage is None or not coverpage.images:
        _error("в книге нет обложки (<coverpage>)")
        return EXIT_ERRORS

    href = (coverpage.images[0].href or "").lstrip("#")
    if not href:
        _error("ссылка на обложку пуста")
        return EXIT_ERRORS

    binary = next((item for item in parser.parse_binaries() if item.id == href), None)
    if binary is None:
        _error(f"не найден <binary> обложки: {href}")
        return EXIT_ERRORS

    target = Path(args.out) if args.out else Path(".")
    if target.is_dir() or not target.suffix:
        target = target / parser.binary_filename(binary)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(parser.binary_data(binary))
    print(f"Обложка: {target}")
    return EXIT_OK


def cmd_zip(args) -> int:
    """Упаковать FB2 в ZIP-архивы (.fb2.zip)."""
    from .fb2_zip import FB2Zip

    zipper = FB2Zip(remove_source=args.remove, overwrite=not args.skip_existing)
    target = Path(args.source)

    if target.is_dir():
        results = zipper.zip_dir(target, out_dir=args.out_dir, dry_run=args.dry_run)
    elif target.is_file():
        dest = Path(args.out_dir) / (target.name + ".zip") if args.out_dir else None
        results = [zipper.zip_file(target, dest=dest, dry_run=args.dry_run)]
    else:
        _error(f"файл или каталог не найден: {target}")
        return EXIT_ERRORS

    errors = 0
    packed = 0
    skipped = 0
    for result in results:
        if not result.ok:
            errors += 1
            print(f"ОШИБКА: {result.source}: {result.error}", file=sys.stderr)
            continue
        if result.skipped:
            skipped += 1
            if not args.quiet:
                print(f"пропущен (архив уже существует): {result.source}")
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


def cmd_unzip(args) -> int:
    """Распаковать архивы FB2 (.fb2.zip)."""
    from .fb2_unzip import FB2Unzip

    unzipper = FB2Unzip(remove_source=args.remove)
    target = Path(args.source)

    if target.is_dir():
        results = unzipper.unzip_dir(target, out_dir=args.out_dir, dry_run=args.dry_run)
    elif target.is_file():
        dest = Path(args.out_dir) if args.out_dir else None
        results = [unzipper.unzip_file(target, dest=dest, dry_run=args.dry_run)]
    else:
        _error(f"архив или каталог не найден: {target}")
        return EXIT_ERRORS

    errors = 0
    unpacked = 0
    skipped = 0
    for result in results:
        if not result.ok:
            errors += 1
            print(f"ОШИБКА: {result.source}: {result.error}", file=sys.stderr)
            continue
        if result.skipped:
            skipped += 1
            if not args.quiet:
                print(f"пропущен (нет FB2): {result.source}")
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


def main(argv: Optional[List[str]] = None) -> int:
    """Точка входа CLI.

    :param argv: аргументы командной строки (по умолчанию ``sys.argv[1:]``).
    :return: код возврата: 0 — успех, 1 — ошибка выполнения, 2 — ошибка запуска.
    """
    parser = build_parser()
    args = parser.parse_args(argv)
    if not getattr(args, "handler", None):
        parser.print_help()
        return EXIT_USAGE

    try:
        return args.handler(args)
    except KeyboardInterrupt:  # pragma: no cover - интерактив
        print("Прервано пользователем.", file=sys.stderr)
        return EXIT_ERRORS
    except (OSError, ValueError, RuntimeError) as exc:
        _error(str(exc))
        return EXIT_ERRORS


__all__ = ["build_parser", "main"]


if __name__ == "__main__":
    raise SystemExit(main())

