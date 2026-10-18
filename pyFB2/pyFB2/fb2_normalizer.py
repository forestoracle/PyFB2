# -*- coding: utf-8 -*-
"""Нормализация и авто-исправление FB2-файлов.

Модуль предоставляет класс :class:`Fb2Normalizer`, который приводит
произвольный (в т. ч. «грязный») FB2 к виду, максимально близкому к
XSD-схеме FictionBook 2.0. Исправления выполняются «мягко» — данные не
теряются, добавляется только необходимое.

Что исправляется:

    * **кодировка** — приведение к UTF-8 (BOM, XML-декларация, переводы
      строк, недопустимые управляющие символы);
    * **структура** — порядок дочерних элементов в контейнерах
      (``description``/``title-info``/``document-info``/``body``/``section``
      и т. п.) согласно ``FictionBook.xsd``;
    * **обязательные поля** — ``<description>``, ``<title-info>``,
      ``<document-info>``, ``<body>/<section>``, ``<genre>``, ``<author>``,
      ``<book-title>``, ``<lang>``, ``<id>``, ``<version>``, ``<date>``;
    * **дубликаты** — повторяющиеся ``<binary>`` с одинаковым ``id``;
    * **пробелы** — схлопывание пробелов в простых текстовых полях;
    * **битые ссылки** на изображения (опционально).

Пример::

    >>> from fb2_normalizer import Fb2Normalizer
    >>> normalizer = Fb2Normalizer()
    >>> xml = normalizer.normalize("book.fb2")           # строка XML (UTF-8)
    >>> normalizer.write("book.fb2", "book.fixed.fb2")   # запись в файл
    WindowsPath('book.fixed.fb2')
    >>> result = normalizer.report("book.fb2")
    >>> for fix in result.fixes:
    ...     print(fix)

CLI::

    python fb2_normalizer.py <файл.fb2 | каталог> [-r] [--out-dir DIR]
        [--suffix S] [--dry-run] [--no-pretty] [--validate] [-q]
"""

from __future__ import annotations

import argparse
import os
import re
import sys
import uuid
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path
from typing import TYPE_CHECKING, Dict, List, Optional, Tuple, Union

from lxml import etree

from .fb2_errors import Fb2ConversionError
from .fb2_transcoder import detect_encoding

if TYPE_CHECKING:  # pragma: no cover
    from .fb2_validator import Fb2Validator

#: Пространство имён FB2.
FB2_NS = "http://www.gribuser.ru/xml/fictionbook/2.0"

#: Пространство имён xlink (атрибут ``href`` у ссылок и изображений).
XLINK_NS = "http://www.w3.org/1999/xlink"

#: Атрибут ``href`` в пространстве имён xlink.
XLINK_HREF = f"{{{XLINK_NS}}}href"

#: Расширение FB2-файлов.
FB2_MASK = "*.fb2"

#: BOM UTF-8.
BOM_UTF8 = b"\xef\xbb\xbf"

#: Недопустимые в XML 1.0 управляющие символы (кроме \t, \n, \r).
CONTROL_CHARS_RE = re.compile("[\x00-\x08\x0b\x0c\x0e-\x1f]")

#: XML-декларация в самом начале документа.
DECLARATION_RE = re.compile(r"^\s*<\?xml[^>]*\?>")

#: Атрибут encoding внутри XML-декларации.
ENCODING_ATTR_RE = re.compile(r"""encoding\s*=\s*["'][^"']*["']""", re.IGNORECASE)

#: Символ BOM в виде текста.
BOM_CHAR = "\ufeff"

#: Порядок дочерних элементов по XSD (для пересортировки).
#: Неизвестные элементы сохраняют относительный порядок и идут в конец.
ELEMENT_ORDER: Dict[str, Tuple[str, ...]] = {
    "FictionBook": ("stylesheet", "description", "body", "binary"),
    "description": (
        "title-info", "src-title-info", "document-info",
        "publish-info", "custom-info", "output",
    ),
    "title-info": (
        "genre", "author", "book-title", "annotation", "keywords", "date",
        "coverpage", "lang", "src-lang", "translator", "sequence",
    ),
    "src-title-info": (
        "genre", "author", "book-title", "annotation", "keywords", "date",
        "coverpage", "lang", "src-lang", "translator", "sequence",
    ),
    "document-info": (
        "author", "program-used", "date", "src-url", "src-ocr",
        "id", "version", "history",
    ),
    "publish-info": (
        "book-name", "publisher", "city", "year", "isbn", "sequence",
    ),
    "body": ("image", "title", "epigraph", "section"),
    # В секции ``image`` — это НЕ только шапочная картинка (слот ``image?``),
    # но и блочный контент (иллюстрации между абзацами). Поэтому в порядок
    # его не включаем: иначе сортировка сдвинула бы ВСЕ картинки в начало
    # секции. Шапочная картинка и так стоит сразу после epigraph*.
    "section": ("title", "epigraph", "annotation"),
    "poem": ("title", "epigraph", "subtitle", "stanza", "text-author", "date"),
    "stanza": ("title", "subtitle", "v"),
    "epigraph": ("p", "poem", "cite", "empty-line", "text-author"),
    "cite": ("p", "poem", "empty-line", "subtitle", "table", "text-author"),
    "annotation": ("p", "poem", "cite", "subtitle", "table", "empty-line"),
    "title": ("p", "empty-line"),
    "author": (
        "first-name", "middle-name", "last-name", "nickname",
        "home-page", "email", "id",
    ),
    "coverpage": ("image",),
    "table": ("tr",),
    "tr": ("th", "td"),
}

#: Простые текстовые поля (``textFieldType`` и аналоги), в которых
#: схлопываются пробелы.
TEXT_FIELD_TAGS = frozenset(
    {
        "book-title", "first-name", "middle-name", "last-name", "nickname",
        "program-used", "src-ocr", "book-name", "publisher", "city", "isbn",
        "genre", "lang", "src-lang", "keywords", "src-url",
    }
)

#: Коды возврата CLI.
EXIT_OK = 0
EXIT_ERRORS = 1
EXIT_USAGE = 2


@dataclass
class NormalizationFix:
    """Одно выполненное исправление.

    :param code: машинный код правки (например, ``added-genre``).
    :param message: человекочитаемое описание.
    """

    code: str
    message: str

    def __str__(self) -> str:
        return f"[{self.code}] {self.message}"


@dataclass
class NormalizationResult:
    """Результат нормализации одного файла.

    :param source: исходный путь (или ``<memory>`` для строки/байтов).
    :param target: путь результата (None, если запись не выполнялась).
    :param fixes: список выполненных исправлений.
    :param source_encoding: определённая кодировка исходника.
    :param xml: нормализованный XML (None при ошибке).
    :param valid_after: результат проверки по XSD (None — не проверялось).
    :param error: текст ошибки (None при успехе).
    """

    source: Path
    target: Optional[Path] = None
    fixes: List[NormalizationFix] = field(default_factory=list)
    source_encoding: str = ""
    xml: Optional[str] = None
    valid_after: Optional[bool] = None
    error: Optional[str] = None

    @property
    def changed(self) -> bool:
        """Были ли внесены изменения."""
        return bool(self.fixes)

    @property
    def ok(self) -> bool:
        """Успешно ли завершилась нормализация (включая отсутствие правок)."""
        return self.error is None


class Fb2Normalizer:
    """Нормализация и авто-исправление FB2.

    :param normalize_encoding: приводить ли документ к UTF-8.
    :param fix_order: исправлять ли порядок дочерних элементов по XSD.
    :param fill_required: добавлять ли отсутствующие обязательные поля.
    :param drop_duplicate_binaries: удалять ли ``<binary>`` с повторяющимся ``id``.
    :param drop_broken_images: удалять ли ``<image>``, ссылающиеся на
        отсутствующий ``<binary>``.
    :param collapse_whitespace: схлопывать ли пробелы в текстовых полях.
    :param strip_control_chars: удалять ли недопустимые управляющие символы.
    :param recover: пытаться ли восстановить некорректный XML.
    :param pretty: форматировать ли результат отступами.
    :param default_genre: жанр, добавляемый при отсутствии ``<genre>``.
    :param default_lang: язык, добавляемый при отсутствии ``<lang>``.
    :param default_title: название, добавляемое при отсутствии ``<book-title>``.
    :param default_author: автор (``<nickname>``) для добавляемых ``<author>``.
    :param program_used: значение ``<program-used>`` (None — не добавлять).
    :param schema_path: путь к ``FictionBook.xsd`` (для ``validate=True``).
    :param validate: проверять ли результат по XSD.
    """

    def __init__(
        self,
        normalize_encoding: bool = True,
        fix_order: bool = True,
        fill_required: bool = True,
        drop_duplicate_binaries: bool = True,
        drop_broken_images: bool = False,
        collapse_whitespace: bool = True,
        strip_control_chars: bool = True,
        recover: bool = True,
        pretty: bool = True,
        default_genre: str = "prose",
        default_lang: str = "ru",
        default_title: str = "Без названия",
        default_author: str = "Неизвестный автор",
        program_used: Optional[str] = None,
        schema_path: Union[str, Path, None] = None,
        validate: bool = False,
    ) -> None:
        self.normalize_encoding = normalize_encoding
        self.fix_order = fix_order
        self.fill_required = fill_required
        self.drop_duplicate_binaries = drop_duplicate_binaries
        self.drop_broken_images = drop_broken_images
        self.collapse_whitespace = collapse_whitespace
        self.strip_control_chars = strip_control_chars
        self.recover = recover
        self.pretty = pretty
        self.default_genre = default_genre
        self.default_lang = default_lang
        self.default_title = default_title
        self.default_author = default_author
        self.program_used = program_used
        self.schema_path = schema_path
        self.validate = validate
        self._validator: Optional["Fb2Validator"] = None

    # --- Публичный API -----------------------------------------------------
    def normalize(self, source) -> str:
        """Вернуть нормализованный XML (строка UTF-8).

        :param source: путь к файлу, ``bytes`` или XML-строка.
        :raises ValueError: если XML невозможно разобрать.
        """
        result = self.report(source)
        if result.error is not None:
            raise Fb2ConversionError(result.error)
        return result.xml or ""

    def report(self, source) -> NormalizationResult:
        """Нормализовать без записи и вернуть подробный отчёт."""
        path = self._source_path(source)
        try:
            root, fixes, encoding = self._normalize_tree(source)
            xml = self._serialize(root)
        except (etree.XMLSyntaxError, ValueError, OSError, LookupError) as exc:
            return NormalizationResult(source=path, error=str(exc))

        result = NormalizationResult(
            source=path,
            fixes=fixes,
            source_encoding=encoding,
            xml=xml,
        )
        if self.validate:
            result.valid_after = self._validate_xml(xml)
        return result

    def write(
        self,
        source,
        output: Optional[Union[str, Path]] = None,
        encoding: str = "utf-8",
    ) -> Path:
        """Нормализовать источник и записать результат в файл."""
        result = self.report(source)
        if result.error is not None:
            raise Fb2ConversionError(result.error)

        if output is None:
            src = source if isinstance(source, (str, Path)) else None
            output = Path(src).with_suffix(".fb2") if src else Path("book.fb2")
        target = Path(output)
        target.write_text(result.xml or "", encoding=encoding)
        return target

    def normalize_file(
        self,
        path: Union[str, Path],
        dest: Optional[Union[str, Path]] = None,
        dry_run: bool = False,
    ) -> NormalizationResult:
        """Нормализовать один файл (с записью или без).

        :param path: исходный файл.
        :param dest: файл назначения (None — перезапись исходного).
        :param dry_run: не записывать результат.
        """
        source_path = Path(path)
        try:
            data = source_path.read_bytes()
        except OSError as exc:
            return NormalizationResult(
                source=source_path, error=f"Не удалось прочитать: {exc}"
            )

        result = self.report(data)
        result.source = source_path
        if result.error is not None:
            return result

        target_path = Path(dest) if dest else source_path
        result.target = target_path
        if dry_run:
            return result

        try:
            self._write_atomic(target_path, (result.xml or "").encode("utf-8"))
        except OSError as exc:
            result.error = f"Не удалось записать: {exc}"
        return result

    def normalize_dir(
        self,
        directory: Union[str, Path],
        out_dir: Optional[Union[str, Path]] = None,
        suffix: str = "",
        dry_run: bool = False,
    ) -> List[NormalizationResult]:
        """Нормализовать все FB2-файлы каталога (рекурсивно).

        :param directory: корневой каталог.
        :param out_dir: каталог результатов (None — рядом с исходными).
        :param suffix: суффикс, добавляемый к имени файла.
        :param dry_run: не записывать результат.
        """
        root = Path(directory)
        out_root = Path(out_dir) if out_dir else None
        results: List[NormalizationResult] = []
        for fb2 in sorted(root.rglob(FB2_MASK)):
            dest: Optional[Path] = None
            if out_root is not None or suffix:
                relative = fb2.relative_to(root)
                if suffix:
                    relative = relative.with_name(
                        relative.stem + suffix + relative.suffix
                    )
                dest = (out_root / relative) if out_root else fb2.with_name(relative.name)
            results.append(self.normalize_file(fb2, dest=dest, dry_run=dry_run))
        return results

    # --- Чтение и подготовка документа ------------------------------------
    @staticmethod
    def _source_path(source) -> Path:
        """Путь источника (или ``<memory>`` для строки/байтов)."""
        if isinstance(source, (str, Path)):
            path = Path(source)
            if path.is_file():
                return path
        return Path("<memory>")

    @staticmethod
    def _read_bytes(source) -> bytes:
        """Прочитать источник в виде байтов."""
        if isinstance(source, (bytes, bytearray)):
            return bytes(source)
        if isinstance(source, (str, Path)):
            path = Path(source)
            if path.is_file():
                return path.read_bytes()
            return str(source).encode("utf-8")
        if hasattr(source, "read"):
            data = source.read()
            return data.encode("utf-8") if isinstance(data, str) else bytes(data)
        raise Fb2ConversionError(f"Неподдерживаемый источник: {type(source)!r}")

    def _decode(
        self, data: bytes, encoding: str, fixes: List[NormalizationFix]
    ) -> str:
        """Декодировать байты в текст, убрав BOM."""
        payload = data
        if payload.startswith(BOM_UTF8):
            payload = payload[len(BOM_UTF8):]
            fixes.append(NormalizationFix("bom-removed", "удалён BOM UTF-8"))

        try:
            text = payload.decode(encoding, errors="strict")
        except (UnicodeDecodeError, LookupError):
            text = payload.decode(encoding, errors="replace")
            fixes.append(
                NormalizationFix(
                    "decode-replaced",
                    f"часть байтов заменена при декодировании {encoding}",
                )
            )

        if self.normalize_encoding and encoding.strip().casefold() not in (
            "utf-8",
            "utf8",
        ):
            fixes.append(
                NormalizationFix("encoding-fixed", f"кодировка {encoding} -> utf-8")
            )
        return text

    def _clean_text(self, text: str, fixes: List[NormalizationFix]) -> str:
        """Нормализовать переводы строк, BOM и управляющие символы."""
        if text.startswith(BOM_CHAR):
            text = text[1:]
            fixes.append(NormalizationFix("bom-removed", "удалён BOM в начале текста"))
        if "\r" in text:
            text = text.replace("\r\n", "\n").replace("\r", "\n")
            fixes.append(
                NormalizationFix("newlines-normalized", "переводы строк приведены к LF")
            )
        if self.strip_control_chars:
            cleaned = CONTROL_CHARS_RE.sub("", text)
            if cleaned != text:
                text = cleaned
                fixes.append(
                    NormalizationFix(
                        "control-chars-removed",
                        "удалены недопустимые управляющие символы",
                    )
                )
        return self._fix_declaration(text)

    @staticmethod
    def _fix_declaration(text: str) -> str:
        """Привести XML-декларацию к ``encoding="utf-8"``.

        Декларация должна соответствовать фактической кодировке результата,
        иначе XML-парсер (и читатели) декодируют UTF-8-байты неверно.
        """
        match = DECLARATION_RE.match(text)
        if not match:
            return text

        declaration = match.group(0)
        if ENCODING_ATTR_RE.search(declaration):
            fixed = ENCODING_ATTR_RE.sub('encoding="utf-8"', declaration)
        else:
            fixed = declaration.replace("?>", ' encoding="utf-8"?>', 1)
        if fixed == declaration:
            return text
        return fixed + text[match.end():]

    def _parse(self, text: str, fixes: List[NormalizationFix]) -> etree._Element:
        """Разобрать XML (при необходимости — в режиме восстановления)."""
        payload = text.encode("utf-8")
        try:
            return etree.fromstring(payload, self._parser(recover=False))
        except etree.XMLSyntaxError as exc:
            if not self.recover:
                raise
            root = etree.fromstring(payload, self._parser(recover=True))
            if root is None:
                raise exc
            fixes.append(
                NormalizationFix(
                    "recovered", f"XML восстановлен после ошибки: {exc.msg}"
                )
            )
            return root

    @staticmethod
    def _parser(recover: bool) -> etree.XMLParser:
        """Создать XML-парсер (без загрузки внешних сущностей)."""
        return etree.XMLParser(
            recover=recover,
            resolve_entities=False,
            huge_tree=True,
            remove_blank_text=False,
        )

    def _serialize(self, root: etree._Element) -> str:
        """Сериализовать дерево в строку XML с декларацией UTF-8."""
        if self.pretty:
            # Убираем «служебные» пробелы между элементами, чтобы
            # pretty_print дал ровные отступы (mixed-контент сохраняется).
            raw = etree.tostring(root, encoding="utf-8")
            reparsed = etree.fromstring(
                raw,
                etree.XMLParser(remove_blank_text=True, resolve_entities=False),
            )
            if reparsed is not None:
                root = reparsed

        xml = etree.tostring(
            root,
            encoding="utf-8",
            xml_declaration=True,
            pretty_print=self.pretty,
        ).decode("utf-8")
        xml = xml.replace(
            "<?xml version='1.0' encoding='utf-8'?>",
            '<?xml version="1.0" encoding="utf-8"?>',
            1,
        )
        if not xml.endswith("\n"):
            xml += "\n"
        return xml

    def _normalize_tree(self, source) -> Tuple[etree._Element, List[NormalizationFix], str]:
        """Полный цикл: источник -> нормализованное дерево."""
        fixes: List[NormalizationFix] = []
        data = self._read_bytes(source)
        encoding = detect_encoding(data)
        text = self._decode(data, encoding, fixes)
        text = self._clean_text(text, fixes)
        root = self._parse(text, fixes)
        self._apply_fixes(root, fixes)
        return root, fixes, encoding

    # --- Исправления структуры --------------------------------------------
    def _apply_fixes(self, root: etree._Element, fixes: List[NormalizationFix]) -> None:
        """Применить все включённые исправления к дереву."""
        if self.fill_required:
            self._ensure_structure(root, fixes)
        if self.drop_duplicate_binaries:
            self._drop_duplicate_binaries(root, fixes)
        if self.drop_broken_images:
            self._drop_broken_images(root, fixes)
        if self.collapse_whitespace:
            self._collapse_whitespace(root, fixes)
        if self.fix_order:
            self._reorder_all(root, fixes)

    @staticmethod
    def _localname(element) -> str:
        """Локальное имя тега (без пространства имён)."""
        tag = element.tag
        if not isinstance(tag, str):
            return ""
        return etree.QName(tag).localname

    @staticmethod
    def _namespace(root: etree._Element) -> str:
        """URI пространства имён корневого элемента ("" — нет)."""
        tag = root.tag
        if isinstance(tag, str) and tag.startswith("{"):
            return tag[1:].split("}", 1)[0]
        return ""

    def _ensure_structure(
        self, root: etree._Element, fixes: List[NormalizationFix]
    ) -> None:
        """Добавить отсутствующие обязательные элементы."""
        ns = self._namespace(root)

        def q(name: str) -> str:
            return f"{{{ns}}}{name}" if ns else name

        description = root.find(q("description"))
        if description is None:
            description = etree.Element(q("description"))
            root.insert(0, description)
            fixes.append(NormalizationFix("added-description", "добавлен <description>"))

        title_info = description.find(q("title-info"))
        if title_info is None:
            title_info = etree.SubElement(description, q("title-info"))
            fixes.append(NormalizationFix("added-title-info", "добавлен <title-info>"))
        self._ensure_title_info(title_info, q, fixes)

        document_info = description.find(q("document-info"))
        if document_info is None:
            document_info = etree.SubElement(description, q("document-info"))
            fixes.append(
                NormalizationFix("added-document-info", "добавлен <document-info>")
            )
        self._ensure_document_info(document_info, q, fixes)

        bodies = root.findall(q("body"))
        if not bodies:
            body = etree.SubElement(root, q("body"))
            etree.SubElement(body, q("section"))
            fixes.append(
                NormalizationFix("added-body", "добавлены <body> и <section>")
            )
            bodies = [body]
        for body in bodies:
            if body.find(q("section")) is None:
                etree.SubElement(body, q("section"))
                fixes.append(
                    NormalizationFix("added-section", "добавлена пустая <section>")
                )

    def _ensure_title_info(self, title_info, q, fixes: List[NormalizationFix]) -> None:
        """Обязательные поля ``<title-info>``."""
        if title_info.find(q("genre")) is None:
            genre = etree.SubElement(title_info, q("genre"))
            genre.text = self.default_genre
            fixes.append(
                NormalizationFix(
                    "added-genre", f"добавлен <genre>{self.default_genre}</genre>"
                )
            )
        if title_info.find(q("author")) is None:
            self._append_author(title_info, q)
            fixes.append(
                NormalizationFix(
                    "added-author",
                    f"добавлен <author><nickname>{self.default_author}</nickname></author>",
                )
            )
        if title_info.find(q("book-title")) is None:
            element = etree.SubElement(title_info, q("book-title"))
            element.text = self.default_title
            fixes.append(
                NormalizationFix(
                    "added-book-title",
                    f"добавлен <book-title>{self.default_title}</book-title>",
                )
            )
        if title_info.find(q("lang")) is None:
            element = etree.SubElement(title_info, q("lang"))
            element.text = self.default_lang
            fixes.append(
                NormalizationFix("added-lang", f"добавлен <lang>{self.default_lang}</lang>")
            )

    def _ensure_document_info(
        self, document_info, q, fixes: List[NormalizationFix]
    ) -> None:
        """Обязательные поля ``<document-info>``."""
        if document_info.find(q("author")) is None:
            self._append_author(document_info, q)
            fixes.append(
                NormalizationFix(
                    "added-document-author", "добавлен <author> в <document-info>"
                )
            )
        if self.program_used and document_info.find(q("program-used")) is None:
            element = etree.SubElement(document_info, q("program-used"))
            element.text = self.program_used
            fixes.append(
                NormalizationFix(
                    "added-program-used",
                    f"добавлен <program-used>{self.program_used}</program-used>",
                )
            )
        if document_info.find(q("date")) is None:
            element = etree.SubElement(document_info, q("date"))
            element.text = date.today().isoformat()
            fixes.append(
                NormalizationFix("added-document-date", "добавлен <date> в <document-info>")
            )
        if document_info.find(q("id")) is None:
            element = etree.SubElement(document_info, q("id"))
            element.text = f"urn:uuid:{uuid.uuid4()}"
            fixes.append(
                NormalizationFix("added-document-id", "добавлен <id> (urn:uuid)")
            )
        if document_info.find(q("version")) is None:
            element = etree.SubElement(document_info, q("version"))
            element.text = "1.0"
            fixes.append(
                NormalizationFix("added-document-version", "добавлен <version>1.0</version>")
            )

    def _append_author(self, parent, q):
        """Добавить ``<author><nickname>…</nickname></author>``."""
        author = etree.SubElement(parent, q("author"))
        nickname = etree.SubElement(author, q("nickname"))
        nickname.text = self.default_author
        return author

    def _reorder_all(self, root: etree._Element, fixes: List[NormalizationFix]) -> None:
        """Привести порядок дочерних элементов к порядку по XSD."""
        changed: List[str] = []
        for parent in list(root.iter()):
            if not isinstance(parent.tag, str):
                continue
            name = self._localname(parent)
            order = ELEMENT_ORDER.get(name)
            if not order:
                continue
            children = [child for child in parent if isinstance(child.tag, str)]
            if len(children) < 2:
                continue
            index = {item: position for position, item in enumerate(order)}
            keys = [index.get(self._localname(child), len(order)) for child in children]
            if keys == sorted(keys):
                continue
            positions = sorted(range(len(children)), key=lambda i: (keys[i], i))
            reordered = [children[i] for i in positions]
            for child in children:
                parent.remove(child)
            for child in reordered:
                parent.append(child)
            changed.append(name)

        if changed:
            fixes.append(
                NormalizationFix(
                    "reordered",
                    "исправлен порядок элементов: " + ", ".join(sorted(set(changed))),
                )
            )

    def _drop_duplicate_binaries(
        self, root: etree._Element, fixes: List[NormalizationFix]
    ) -> None:
        """Удалить ``<binary>`` с повторяющимся ``id``."""
        ns = self._namespace(root)

        def q(name: str) -> str:
            return f"{{{ns}}}{name}" if ns else name

        seen = set()
        removed = 0
        for binary in list(root.findall(q("binary"))):
            binary_id = binary.get("id")
            if binary_id is None:
                continue
            if binary_id in seen:
                root.remove(binary)
                removed += 1
            else:
                seen.add(binary_id)
        if removed:
            fixes.append(
                NormalizationFix(
                    "duplicate-binary-removed", f"удалено дубликатов <binary>: {removed}"
                )
            )

    def _drop_broken_images(
        self, root: etree._Element, fixes: List[NormalizationFix]
    ) -> None:
        """Удалить ``<image>``, ссылающиеся на отсутствующий ``<binary>``."""
        ns = self._namespace(root)

        def q(name: str) -> str:
            return f"{{{ns}}}{name}" if ns else name

        available = {
            binary.get("id") for binary in root.iter(q("binary")) if binary.get("id")
        }
        removed = 0
        for image in list(root.iter(q("image"))):
            href = image.get(XLINK_HREF)
            if not href or not href.startswith("#") or href[1:] in available:
                continue
            if image.getparent() is None:
                continue
            self._remove_keep_tail(image)
            removed += 1
        if removed:
            fixes.append(
                NormalizationFix(
                    "broken-image-removed",
                    f"удалено <image> без <binary>: {removed}",
                )
            )

    @staticmethod
    def _remove_keep_tail(element) -> None:
        """Удалить элемент, сохранив его ``tail`` (текст после него)."""
        parent = element.getparent()
        if parent is None:
            return
        tail = element.tail
        if tail:
            previous = element.getprevious()
            if previous is not None:
                previous.tail = (previous.tail or "") + tail
            else:
                parent.text = (parent.text or "") + tail
        parent.remove(element)

    def _collapse_whitespace(
        self, root: etree._Element, fixes: List[NormalizationFix]
    ) -> None:
        """Схлопнуть пробелы в простых текстовых полях."""
        changed = 0
        for element in root.iter():
            if not isinstance(element.tag, str):
                continue
            if self._localname(element) not in TEXT_FIELD_TAGS:
                continue
            text = element.text
            if not text:
                continue
            collapsed = re.sub(r"\s+", " ", text).strip()
            if collapsed != text:
                element.text = collapsed
                changed += 1
        if changed:
            fixes.append(
                NormalizationFix(
                    "whitespace-collapsed",
                    f"нормализованы пробелы в полях: {changed}",
                )
            )

    def _validate_xml(self, xml: str) -> Optional[bool]:
        """Проверить XML по XSD (None — валидатор недоступен)."""
        validator = self._get_validator()
        if validator is None:
            return None
        try:
            document = etree.fromstring(
                xml.encode("utf-8"),
                etree.XMLParser(resolve_entities=False, no_network=True),
            )
        except etree.XMLSyntaxError:
            return False
        return bool(validator.schema.validate(document))

    def _get_validator(self):
        """Ленивый доступ к :class:`Fb2Validator` (None при недоступности)."""
        if self._validator is None:
            try:
                from .fb2_validator import Fb2Validator

                self._validator = Fb2Validator(schema_path=self.schema_path)
            except (ImportError, FileNotFoundError, RuntimeError):
                return None
        return self._validator

    @staticmethod
    def _write_atomic(path: Path, data: bytes) -> None:
        """Записать данные атомарно (через временный файл)."""
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_name(path.name + ".tmp")
        with open(tmp, "wb") as handle:
            handle.write(data)
        os.replace(tmp, path)


__all__ = ["Fb2Normalizer", "NormalizationFix", "NormalizationResult"]


def _collect_targets(source: Union[str, Path], recursive: bool) -> List[Path]:
    """Собрать список FB2-файлов для обработки.

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
    :return: код возврата: 0 — успех, 1 — ошибки обработки, 2 — ошибка запуска.
    """
    parser = argparse.ArgumentParser(
        description="Нормализация и авто-исправление FB2-файлов.",
    )
    parser.add_argument("source", help="FB2-файл или каталог с файлами")
    parser.add_argument(
        "-r", "--recursive", action="store_true", help="рекурсивный обход каталога"
    )
    parser.add_argument("--out-dir", default=None, help="каталог для результатов")
    parser.add_argument("--suffix", default="", help="суффикс имени результата")
    parser.add_argument("--dry-run", action="store_true", help="не записывать результат")
    parser.add_argument(
        "--no-pretty", action="store_true", help="не форматировать результат отступами"
    )
    parser.add_argument(
        "--validate", action="store_true", help="проверить результат по XSD-схеме"
    )
    parser.add_argument(
        "-q", "--quiet", action="store_true", help="выводить только итог и ошибки"
    )
    args = parser.parse_args(argv)

    normalizer = Fb2Normalizer(pretty=not args.no_pretty, validate=args.validate)

    source = Path(args.source)
    if source.is_dir():
        results = normalizer.normalize_dir(
            source, out_dir=args.out_dir, suffix=args.suffix, dry_run=args.dry_run
        )
    else:
        targets = _collect_targets(source, args.recursive)
        if not targets:
            print(f"Ошибка: не найдено FB2-файлов: {args.source}", file=sys.stderr)
            return EXIT_USAGE
        results = []
        for target in targets:
            dest: Optional[Path] = None
            if args.out_dir:
                dest = Path(args.out_dir) / target.name
            elif args.suffix:
                dest = target.with_name(target.stem + args.suffix + target.suffix)
            results.append(
                normalizer.normalize_file(target, dest=dest, dry_run=args.dry_run)
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


if __name__ == "__main__":
    raise SystemExit(main())

