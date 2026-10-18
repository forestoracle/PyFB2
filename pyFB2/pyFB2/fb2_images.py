# -*- coding: utf-8 -*-
"""Определение типа и размеров изображений (только стандартная библиотека).

Модуль нужен конвертерам в контейнерные форматы (ODT, MOBI, FB3, DOCX):
там изображения встраиваются с указанием типа и размеров, а исходные данные
лежат в ``<binary>`` FB2 без этой информации.

Пример:
    >>> from fb2_images import detect_image_type, image_size
    >>> detect_image_type(b"\\x89PNG\\r\\n\\x1a\\n...")
    ('image/png', '.png')
    >>> image_size(png_bytes, "image/png")
    (600, 800)
"""

from __future__ import annotations

import struct
from typing import Optional, Tuple

#: Сигнатуры изображений: (магия, MIME-тип, расширение).
IMAGE_SIGNATURES = (
    (b"\x89PNG\r\n\x1a\n", "image/png", ".png"),
    (b"\xff\xd8\xff", "image/jpeg", ".jpg"),
    (b"GIF87a", "image/gif", ".gif"),
    (b"GIF89a", "image/gif", ".gif"),
    (b"BM", "image/bmp", ".bmp"),
    (b"II*\x00", "image/tiff", ".tiff"),
    (b"MM\x00*", "image/tiff", ".tiff"),
)

#: MIME-тип по умолчанию, если сигнатура не распознана.
DEFAULT_MEDIA_TYPE = "image/jpeg"

#: Расширение по MIME-типу (для ``<binary content-type="...">``).
EXTENSION_BY_MEDIA_TYPE = {
    media_type: extension for _signature, media_type, extension in IMAGE_SIGNATURES
}
EXTENSION_BY_MEDIA_TYPE["image/jpg"] = ".jpg"
EXTENSION_BY_MEDIA_TYPE["image/svg+xml"] = ".svg"
EXTENSION_BY_MEDIA_TYPE["image/webp"] = ".webp"
EXTENSION_BY_MEDIA_TYPE["application/octet-stream"] = ".bin"


def detect_image_type(data: bytes) -> Tuple[str, str]:
    """Определить тип изображения по сигнатуре.

    :param data: байты изображения.
    :return: пара ``(media_type, extension)``; для неизвестных данных —
        ``("image/jpeg", ".jpg")``.
    """
    for signature, media_type, extension in IMAGE_SIGNATURES:
        if data.startswith(signature):
            return media_type, extension
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp", ".webp"
    return DEFAULT_MEDIA_TYPE, ".jpg"


def extension_for(media_type: str) -> str:
    """Расширение файла для MIME-типа (``.bin``, если тип неизвестен)."""
    return EXTENSION_BY_MEDIA_TYPE.get((media_type or "").lower(), ".bin")


def _png_size(data: bytes) -> Optional[Tuple[int, int]]:
    """Размер PNG из заголовка IHDR."""
    if len(data) < 24:
        return None
    width, height = struct.unpack(">II", data[16:24])
    return int(width), int(height)


def _jpeg_size(data: bytes) -> Optional[Tuple[int, int]]:
    """Размер JPEG (поиск маркера SOF)."""
    index = 2
    size = len(data)
    while index + 9 < size:
        if data[index] != 0xFF:
            index += 1
            continue
        marker = data[index + 1]
        if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
            index += 2
            continue
        length = struct.unpack(">H", data[index + 2:index + 4])[0]
        if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB):
            height, width = struct.unpack(">HH", data[index + 5:index + 9])
            return int(width), int(height)
        index += 2 + length
    return None


def _gif_size(data: bytes) -> Optional[Tuple[int, int]]:
    """Размер GIF из логического дескриптора экрана."""
    if len(data) < 10:
        return None
    width, height = struct.unpack("<HH", data[6:10])
    return int(width), int(height)


def _bmp_size(data: bytes) -> Optional[Tuple[int, int]]:
    """Размер BMP из DIB-заголовка."""
    if len(data) < 26:
        return None
    width, height = struct.unpack("<ii", data[18:26])
    return abs(int(width)), abs(int(height))


#: Функции чтения размеров по MIME-типу.
_SIZE_READERS = {
    "image/png": _png_size,
    "image/jpeg": _jpeg_size,
    "image/jpg": _jpeg_size,
    "image/gif": _gif_size,
    "image/bmp": _bmp_size,
}


def image_size(data: bytes, media_type: str = "") -> Optional[Tuple[int, int]]:
    """Определить размеры изображения в пикселях.

    :param data: байты изображения.
    :param media_type: MIME-тип (если не задан — определяется по сигнатуре).
    :return: пара ``(width, height)`` или None, если размер неизвестен.
    """
    kind = (media_type or "").lower()
    if kind not in _SIZE_READERS:
        kind, _extension = detect_image_type(data)
    reader = _SIZE_READERS.get(kind)
    if reader is None:
        return None
    try:
        return reader(data)
    except (struct.error, IndexError):  # pragma: no cover - битые данные
        return None


def scale_to_width(
    width: float, height: float, max_width: float
) -> Tuple[float, float]:
    """Масштабировать размер так, чтобы ширина не превышала ``max_width``.

    :param width: исходная ширина (в любых единицах).
    :param height: исходная высота (те же единицы).
    :param max_width: предельная ширина (те же единицы, что и результат).
    :return: пара ``(width, height)`` (пропорции сохраняются).
    """
    if width <= 0 or height <= 0:
        return max_width, max_width
    if width <= max_width:
        return float(width), float(height)
    ratio = max_width / float(width)
    return float(max_width), round(height * ratio, 2)
