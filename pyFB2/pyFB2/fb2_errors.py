# -*- coding: utf-8 -*-
"""Единая иерархия исключений pyFB2.

Все ошибки библиотеки наследуют :class:`Fb2Error`, поэтому приложению
достаточно одного обработчика::

    from pyFB2 import Fb2Error

    try:
        book = Fb2Parser("book.fb2").parse()
    except Fb2Error as exc:
        ...

Каждый класс дополнительно наследует «классический» тип исключения
(:class:`ValueError`, :class:`RuntimeError`, :class:`LookupError`), поэтому
существующий код, который ловил их напрямую, продолжает работать::

    class Fb2ParseError(Fb2Error, ValueError): ...
    class Fb2NotFoundError(Fb2Error, RuntimeError, LookupError): ...

Классы:

    * :class:`Fb2ParseError` — FB2/XML не удалось прочитать или разобрать;
    * :class:`Fb2ValidationError` — документ или XSD-схема не подходят;
    * :class:`Fb2ConversionError` — не удалось преобразовать книгу;
    * :class:`Fb2OperationError` — ошибка файловой операции (переименование);
    * :class:`Fb2NotFoundError` — запрошенные данные не найдены;
    * :class:`Fb2NetworkError` — сетевой запрос не удался.

Пример:
    >>> from fb2_errors import Fb2Error, Fb2ParseError
    >>> issubclass(Fb2ParseError, (Fb2Error, ValueError))
    True
"""

from __future__ import annotations


class Fb2Error(Exception):
    """Базовое исключение pyFB2: ловит любую ошибку библиотеки."""


class Fb2ParseError(Fb2Error, ValueError):
    """FB2/XML не удалось прочитать или разобрать.

    Совместим с :class:`ValueError`.
    """


class Fb2ValidationError(Fb2Error, ValueError):
    """Документ не соответствует XSD-схеме (или сама схема непригодна).

    Совместим с :class:`ValueError`.
    """


class Fb2ConversionError(Fb2Error, ValueError):
    """Не удалось преобразовать книгу: входные данные, формат или состояние.

    Совместим с :class:`ValueError`.
    """


class Fb2OperationError(Fb2Error, RuntimeError):
    """Ошибка операции с файлами (например, переименование).

    Совместим с :class:`RuntimeError`.
    """


class Fb2NotFoundError(Fb2Error, RuntimeError, LookupError):
    """Запрошенные данные не найдены (книга, статья, автор, обложка).

    Совместим и с :class:`LookupError` (семантика «не найдено»), и с
    :class:`RuntimeError` (как было в ранних версиях pyFB2).
    """


class Fb2NetworkError(Fb2Error, RuntimeError):
    """Сетевая ошибка или некорректный ответ сервиса.

    Совместим с :class:`RuntimeError`.
    """
