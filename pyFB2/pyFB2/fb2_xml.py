# -*- coding: utf-8 -*-
"""Безопасный разбор XML для FB2: защита от DTD-бомб («billion laughs»).

``xml.etree.ElementTree`` раскрывает сущности, объявленные во внутреннем
подмножестве DTD, поэтому «XML-бомба» вида::

    <!DOCTYPE lolz [
      <!ENTITY lol "lol">
      <!ENTITY lol2 "&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;">
      ...
    ]>

может исчерпать память при разборе небольшого файла. Публичного API для
запрета DTD у ElementTree нет (C-парсер не даёт доступа к expat), поэтому
перед разбором объявление ``<!DOCTYPE ...>`` вместе с внутренним поднабором
``[...]`` вырезается: без DTD объявить сущности невозможно.

Внешние сущности ElementTree и так не загружает (XXE-чтение локальных файлов
через ``SYSTEM`` не работает — они остаются неопределёнными), так что после
удаления DTD документ безопасен.

Обычные FB2 с ``<!DOCTYPE FictionBook SYSTEM "FictionBook.dtd">``
разбираются как раньше: определения сущностей им не нужны, а сам DTD
игнорируется.

Пример:
    >>> from fb2_xml import parse_xml
    >>> root = parse_xml("book.fb2")          # путь к файлу
    >>> root.tag
    '{http://www.gribuser.ru/xml/fictionbook/2.0}FictionBook'
    >>> parse_xml(b"<FictionBook/>").tag
    'FictionBook'
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import IO, Any, Union

import xml.etree.ElementTree as ET

from .fb2_errors import Fb2ParseError

#: Источники, которые принимает :func:`parse_xml`.
Source = Union[str, Path, bytes, bytearray, IO[Any]]

#: Объявление DOCTYPE вместе с необязательным внутренним поднабором ``[...]``.
_DOCTYPE_BYTES_RE = re.compile(
    rb"<!DOCTYPE[^>\[]*(?:\[[^\]]*\])?[^>]*>", re.IGNORECASE | re.DOTALL
)
_DOCTYPE_STR_RE = re.compile(
    r"<!DOCTYPE[^>\[]*(?:\[[^\]]*\])?[^>]*>", re.IGNORECASE | re.DOTALL
)

#: Быстрая проверка наличия DTD (без регулярного выражения).
_DOCTYPE_BYTES_MARKER = re.compile(rb"<!DOCTYPE", re.IGNORECASE)
_DOCTYPE_STR_MARKER = re.compile(r"<!DOCTYPE", re.IGNORECASE)


class Fb2XmlError(ET.ParseError, Fb2ParseError):
    """Ошибка разбора XML (некорректный документ).

    Наследует :class:`pyFB2.fb2_errors.Fb2ParseError` (а значит и
    ``ValueError``) и :class:`xml.etree.ElementTree.ParseError`, поэтому
    существующие обработчики обоих типов продолжают работать.
    """


def strip_doctype(data: bytes) -> bytes:
    """Удалить объявление DOCTYPE из XML-документа (байты).

    :param data: байты XML-документа.
    :return: те же байты без ``<!DOCTYPE ...>`` (если он был).
    """
    if not _DOCTYPE_BYTES_MARKER.search(data):
        return data
    return _DOCTYPE_BYTES_RE.sub(b"", data, count=1)


def strip_doctype_text(text: str) -> str:
    """Удалить объявление DOCTYPE из XML-документа (строка).

    :param text: XML-текст.
    :return: тот же текст без ``<!DOCTYPE ...>`` (если он был).
    """
    if not _DOCTYPE_STR_MARKER.search(text):
        return text
    return _DOCTYPE_STR_RE.sub("", text, count=1)


def _read(source: Source) -> Union[bytes, str]:
    """Прочитать источник в байты или строку.

    :param source: путь, байты или файловый объект.
    :return: содержимое источника.
    :raises OSError: если файл не удалось прочитать.
    """
    if isinstance(source, (bytes, bytearray)):
        return bytes(source)
    if isinstance(source, (str, Path)):
        return Path(source).read_bytes()
    data = source.read()
    if isinstance(data, (bytes, bytearray)):
        return bytes(data)
    return data


def _explain(exc: ET.ParseError) -> str:
    """Дополнить сообщение об ошибке разбора подсказкой про сущности."""
    message = f"Некорректный XML: {exc}"
    if "undefined entity" in str(exc):
        message += (
            " (в документе используются сущности, объявленные в DTD;"
            " их раскрытие отключено из соображений безопасности)"
        )
    return message


def parse_xml(source: Source) -> ET.Element:
    """Разобрать XML в корневой элемент, безопасно вырезав DTD.

    :param source: путь к файлу, байты XML или файловый объект.
    :return: корневой элемент документа.
    :raises Fb2XmlError: если документ некорректен (наследник
        ``ET.ParseError`` и ``ValueError``).
    :raises OSError: если файл-источник недоступен.
    """
    data = _read(source)
    if isinstance(data, str):
        return parse_xml_text(data)

    payload = strip_doctype(data)
    try:
        return ET.fromstring(payload)
    except ET.ParseError as exc:
        raise Fb2XmlError(_explain(exc)) from exc


def parse_xml_text(text: str) -> ET.Element:
    """Разобрать XML-текст (строка) в корневой элемент, вырезав DTD.

    :param text: XML-текст (без декларации кодировки — как у
        ``ElementTree.fromstring``).
    :return: корневой элемент документа.
    :raises Fb2XmlError: если документ некорректен.
    """
    try:
        return ET.fromstring(strip_doctype_text(text))
    except ET.ParseError as exc:
        raise Fb2XmlError(_explain(exc)) from exc
