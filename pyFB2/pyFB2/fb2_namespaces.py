# -*- coding: utf-8 -*-
"""Пространства имён FictionBook: приведение версий к официальной 2.0.

Официальная схема FB2 объявляет
``targetNamespace="http://www.gribuser.ru/xml/fictionbook/2.0"``, однако
часть файлов приходит с «чужой» версией в URI — например,
``http://www.gribuser.ru/xml/fictionbook/2.1`` (и таким же ``/genres``).
Для XSD это другой документ: валидатор сообщает «No matching global
declaration available for the validation root», а :class:`Fb2Parser`
не находит ``<description>``, потому что ищет элементы в пространстве 2.0.

Модуль приводит URI к 2.0. Состав документа при этом не меняется: в таких
файлах, как правило, нет элементов, специфичных для других версий.

Пример:
    >>> from fb2_namespaces import normalize_namespace_uri
    >>> normalize_namespace_uri("http://www.gribuser.ru/xml/fictionbook/2.1")
    'http://www.gribuser.ru/xml/fictionbook/2.0'
    >>> normalize_namespace_declarations(
    ...     '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.1"/>'
    ... )
    ('<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"/>', 1)
"""

from __future__ import annotations

import re
import xml.etree.ElementTree as ET
from typing import Tuple

#: Официальное пространство имён FB2.
FB2_NS = "http://www.gribuser.ru/xml/fictionbook/2.0"

#: Пространство имён жанров FB2 (используется в объявлении ``xmlns:genre``).
FB2_GENRES_NS = f"{FB2_NS}/genres"

#: URI пространства имён FictionBook, версия в котором отличается от 2.0.
FB2_NS_RE = re.compile(
    r"^https?://(?:www\.)?gribuser\.ru/xml/fictionbook/2\.\d+(?P<genres>/genres)?$"
)

#: Объявление ``xmlns`` / ``xmlns:prefix`` со значением-URI FictionBook.
XMLNS_RE = re.compile(
    r"""(?P<prefix>xmlns(?::[A-Za-z_][\w.-]*)?\s*=\s*)(?P<quote>["'])"""
    r"""(?P<uri>https?://(?:www\.)?gribuser\.ru/xml/fictionbook/2\.\d+(?:/genres)?)"""
    r"""(?P=quote)"""
)


def normalize_namespace_uri(uri: str) -> str:
    """Привести URI пространства имён FB2 к версии 2.0.

    Посторонние URI (``xlink``, ``xml``, пользовательские) возвращаются
    без изменений, поэтому функцию можно применять к любому тегу.

    :param uri: URI пространства имён (без фигурных скобок).
    :return: ``.../fictionbook/2.0`` либо ``.../fictionbook/2.0/genres``
        для известных версий FB2; исходный ``uri`` — для остальных.
    """
    match = FB2_NS_RE.match(uri)
    if match is None:
        return uri
    return FB2_GENRES_NS if match.group("genres") else FB2_NS


def normalize_namespace_declarations(text: str) -> Tuple[str, int]:
    """Заменить в XML-тексте объявления ``xmlns`` версий FB2 не 2.0.

    Заменяются только строки-объявления ``xmlns``/``xmlns:prefix``; остальное
    содержимое документа не переписывается.

    :param text: XML-текст документа.
    :return: пара «исправленный текст, число заменённых объявлений».
    """
    replaced = 0

    def _replace(match: re.Match[str]) -> str:
        nonlocal replaced
        uri = normalize_namespace_uri(match.group("uri"))
        if uri == match.group("uri"):
            return match.group(0)
        replaced += 1
        quote = match.group("quote")
        return f"{match.group('prefix')}{quote}{uri}{quote}"

    return XMLNS_RE.sub(_replace, text), replaced


def normalize_tree_namespaces(root: ET.Element) -> int:
    """Заменить в дереве ElementTree пространства имён тегов на FB2 2.0.

    В ElementTree объявления ``xmlns`` отдельно не хранятся — пространство
    имён является частью имени тега (``{uri}local``), поэтому меняются
    только имена элементов. Комментарии и инструкции обработки
    пропускаются (их ``tag`` — не строка).

    :param root: корневой элемент документа (изменяется на месте).
    :return: число элементов с исправленным пространством имён.
    """
    replaced = 0
    for element in root.iter():
        tag = element.tag
        if not isinstance(tag, str) or not tag.startswith("{"):
            continue
        uri, _, local = tag[1:].partition("}")
        fixed = normalize_namespace_uri(uri)
        if fixed != uri:
            element.tag = f"{{{fixed}}}{local}"
            replaced += 1
    return replaced


__all__ = [
    "FB2_NS",
    "FB2_GENRES_NS",
    "FB2_NS_RE",
    "XMLNS_RE",
    "normalize_namespace_uri",
    "normalize_namespace_declarations",
    "normalize_tree_namespaces",
]
