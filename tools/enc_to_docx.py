"""Конвертация энциклопедии ``enc.pdf`` в DOCX с одной колонкой.

Исходный PDF — «Русские святые и подвижники Православия. Историческая
энциклопедия» — свёрстан в две колонки. Каждая статья начинается с названия,
набранного полужирным шрифтом, а некоторые статьи заканчиваются именем автора,
набранным полужирным курсивом и выровненным по правому краю.

Конвертер:

* извлекает текст через PyMuPDF (``pymupdf``), получая координаты и признаки
  полужирного/курсивного начертания;
* разворачивает двухколоночную вёрстку в один линейный поток
  (левая колонка сверху вниз, затем правая);
* удаляет верхние колонтитулы (номер страницы + название статьи) и
  декоративные буквицы;
* название статьи -> абзац стиля ``Heading 2`` (заголовок второго уровня);
  текст названия сохраняется и в начале первого абзаца статьи;
* иллюстрации статьи вставляются сразу после её заголовка, с подписью под ними;
* имя автора -> абзац, выровненный по правому краю, полужирным курсивом;
* содержимое статьи -> обычные абзацы; переносы слов склеиваются,
  абзацы разделяются по отступу первой строки.

DOCX собирается напрямую в формате Office Open XML (ZIP), без внешних
генераторов (по аналогии с :mod:`pyFB2.fb2_to_docx`).

Запуск::

    python enc_to_docx.py enc.pdf enc.docx
"""

from __future__ import annotations

import sys
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Tuple, cast
from xml.sax.saxutils import escape as xml_escape

import pymupdf

# --- Параметры разбора ------------------------------------------------------

#: Флаги начертания PyMuPDF (span["flags"]).
BOLD_FLAG = 1 << 4
ITALIC_FLAG = 1 << 1

#: Страницы со статьями энциклопедии (0-индексация, ``end`` не включительно).
ARTICLE_START = 10
ARTICLE_END = 867

#: Верхняя зона страницы (pt): колонтитул с номером и названием статьи.
HEADER_Y = 55.0

#: Допуск (pt) попадания в левый край колонки (для заголовков).
MARGIN_TOLERANCE = 4.0

#: Минимальный отступ первой строки (pt), считающийся новым абзацем.
INDENT_THRESHOLD = 4.0

#: Максимальный отступ (pt): больше — это текст, обтекающий рисунок, а не абзац.
INDENT_MAX = 40.0

#: Минимальный размер (pt), выше которого span считается декоративной буквицей.
DECORATIVE_SIZE = 30.0

#: Максимальная высота (pt) блока, который может быть подписью к иллюстрации.
CAPTION_MAX_HEIGHT = 40.0

#: Зазор (pt) под изображением, в пределах которого блок считается подписью.
CAPTION_IMAGE_GAP = 6.0

#: Зазор (pt) под другой подписью (продолжение подписи).
CAPTION_CHAIN_GAP = 4.0

#: Зазор (pt) под иллюстрацией для построчного распознавания подписи.
CAPTION_LINE_GAP = 14.0

# --- Пространства имён OOXML ------------------------------------------------

NS_W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
NS_CT = "http://schemas.openxmlformats.org/package/2006/content-types"
NS_REL = "http://schemas.openxmlformats.org/package/2006/relationships"
NS_R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
NS_WP = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
NS_A = "http://schemas.openxmlformats.org/drawingml/2006/main"
NS_PIC = "http://schemas.openxmlformats.org/drawingml/2006/picture"

REL_OFFICE = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"
REL_STYLES = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles"
REL_IMAGE = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"
REL_CORE = "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties"
REL_APP = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties"

#: Английские единицы измерения Office (EMU): 1 pt = 1/72 дюйма.
EMU_PER_POINT = 12700

#: Ширина текста A4 при полях 1134 тв (в EMU).
TEXT_WIDTH_EMU = 9638 * 635

#: MIME-типы изображений по расширению.
_MEDIA_TYPE = {
    "jpeg": "image/jpeg",
    "jpg": "image/jpeg",
    "png": "image/png",
    "gif": "image/gif",
    "bmp": "image/bmp",
    "tiff": "image/tiff",
}


@dataclass
class Span:
    """Фрагмент строки с одним начертанием."""

    text: str
    x0: float
    x1: float
    bold: bool
    italic: bool


@dataclass
class Line:
    """Визуальная строка PDF с координатами и колонкой."""

    spans: List[Span]
    x0: float
    y0: float
    col_margin: float = 0.0
    col_base: float = 0.0
    caption: bool = False

    @property
    def text(self) -> str:
        return "".join(span.text for span in self.spans)

    @property
    def x1(self) -> float:
        return max((span.x1 for span in self.spans), default=self.x0)

    @property
    def first(self) -> Span:
        return self.spans[0]

    @property
    def is_author(self) -> bool:
        """Строка целиком — подпись автора (полужирный курсив)."""
        return bool(self.spans) and self.first.bold and self.first.italic


@dataclass
class ImageRef:
    """Иллюстрация: её размещение на странице и данные."""

    xref: int
    x0: float
    y0: float
    x1: float
    y1: float
    width: int
    height: int
    data: bytes
    ext: str


@dataclass
class ArticleImage:
    """Иллюстрация статьи вместе с подписью под ней."""

    image: ImageRef
    caption: str = ""


#: Знаки, перед которыми пробел не ставится при склейке с заголовком.
_NO_SPACE_BEFORE = set(".,;:!?»)]}…")


def _is_control(ch: str) -> bool:
    """Управляющий символ, которым в PDF закодирован дефис/перенос."""
    return ord(ch) < 0x20 and ch not in "\t\n\r"


#: Знаки, которыми строка может закончиться «по-настоящему» (не перенос).
#: ``-``, ``!`` и ``?`` сюда не входят — в этих PDF они же служат знаком переноса.
SAFE_END = set(".,;:»«\"'()[]{}—–…№%*/\\|")


#: Символы, которые можно безопасно отсекать по краям (не путать с \x0b–\x1f!).
_STRIP = " \t\n\r"


def _hyphen_end(text: str, next_text: str = "") -> bool:
    """Оканчивается ли строка удаляемым знаком переноса (дефисом вёрстки)."""
    text = text.rstrip(_STRIP)
    if len(text) < 2:
        return False
    ch = text[-1]
    if _is_control(ch):
        return True
    if ch.isalpha() or ch.isspace() or ch in SAFE_END:
        return False
    if not text[-2].isalpha():
        return False
    if ch in "-!?":  # могут быть и знаком препинания / реальным дефисом
        return next_text[:1].islower()
    # Цифры и прочие символы (8, 5, $…) в этих PDF — почти всегда знак переноса.
    return True


def _word_continues(text: str, next_text: str = "") -> bool:
    """Строка обрывается внутри слова: следующая строка продолжает его."""
    if _hyphen_end(text, next_text):
        return True
    # Реальный дефис на разрыве строки (Санкт- / Петербургского).
    return text.rstrip(_STRIP).endswith("-") and next_text[:1].isupper()


def _clean(text: str, next_text: str = "") -> Tuple[str, bool]:
    """Убрать знак переноса; вернуть текст и признак продолжения слова."""
    text = text.strip(_STRIP)
    hyphenated = _hyphen_end(text, next_text)
    if hyphenated:
        text = text[:-1]
    elif text.endswith("-") and next_text[:1].isupper():
        hyphenated = True  # дефис оставляем, но склеиваем без пробела
    text = "".join("-" if _is_control(ch) else ch for ch in text)
    return text, hyphenated


def _caption_blocks(blocks: list) -> set:
    """Индексы текстовых блоков-подписей к иллюстрациям."""
    images = [block["bbox"] for block in blocks if block.get("type") != 0]
    text_blocks = [(index, block) for index, block in enumerate(blocks) if block.get("type") == 0]
    captions: dict = {}
    changed = True
    while changed:
        changed = False
        for index, block in text_blocks:
            if index in captions:
                continue
            bbox = block["bbox"]
            if bbox[3] - bbox[1] > CAPTION_MAX_HEIGHT:  # длинный блок — не подпись
                continue
            below_image = any(0.0 <= bbox[1] - image[3] <= CAPTION_IMAGE_GAP for image in images)
            below_caption = any(
                0.0 <= bbox[1] - blocks[other]["bbox"][3] <= CAPTION_CHAIN_GAP for other in captions
            )
            if below_image or below_caption:
                captions[index] = bbox
                changed = True
    return set(captions)


def _page_lines(page: pymupdf.Page) -> List[Line]:
    """Извлечь строки страницы (без колонтитулов и буквиц)."""
    data = page.get_text("dict")
    blocks = data["blocks"]
    caption_blocks = _caption_blocks(blocks)
    images = [block["bbox"] for block in blocks if block.get("type") != 0]
    body_size = _body_size(blocks)
    lines: List[Line] = []
    for block_index, block in enumerate(blocks):
        if block.get("type") != 0:
            continue
        block_is_caption = block_index in caption_blocks
        for raw_line in block["lines"]:
            spans: List[Span] = []
            for span in raw_line["spans"]:
                if not span["text"]:
                    continue
                # Декоративные буквицы (крупный шрифт, гарнитура CyrillicOld).
                if span["size"] >= DECORATIVE_SIZE or "CyrillicOld" in span["font"]:
                    continue
                spans.append(
                    Span(
                        text=span["text"],
                        x0=span["bbox"][0],
                        x1=span["bbox"][2],
                        bold=bool(span["flags"] & BOLD_FLAG),
                        italic=bool(span["flags"] & ITALIC_FLAG),
                    )
                )
            if not spans or not "".join(s.text for s in spans).strip():
                continue
            y0 = raw_line["bbox"][1]
            if y0 < HEADER_Y:  # колонтитул
                continue
            caption = block_is_caption or _is_caption_line(
                raw_line, images, body_size
            )
            lines.append(
                Line(
                    spans=spans,
                    x0=min(s.x0 for s in spans),
                    y0=y0,
                    caption=caption,
                )
            )
    return _merge_lines(lines)


def _body_size(blocks: list) -> float:
    """Доминирующий кегль основного текста страницы."""
    sizes: Dict[float, int] = {}
    for block in blocks:
        if block.get("type") != 0:
            continue
        for line in block["lines"]:
            for span in line["spans"]:
                text = span["text"].strip()
                if text:
                    key = round(span["size"], 1)
                    sizes[key] = sizes.get(key, 0) + len(text)
    return max(sizes, key=lambda key: sizes[key]) if sizes else 0.0


def _is_caption_line(raw_line: dict, images: List[list], body_size: float) -> bool:
    """Строка-подпись: мелкий/курсивный текст непосредственно под иллюстрацией."""
    if not images:
        return False
    top = raw_line["bbox"][1]
    if not any(-2.0 <= top - image[3] <= CAPTION_LINE_GAP for image in images):
        return False
    spans = [span for span in raw_line["spans"] if span["text"].strip()]
    if not spans:
        return False
    small = body_size > 0 and max(span["size"] for span in spans) < body_size - 0.3
    italic = all(bool(span["flags"] & ITALIC_FLAG) for span in spans)
    return small or italic


def _merge_lines(lines: List[Line]) -> List[Line]:
    """Склеить фрагменты одной визуальной строки (PyMuPDF иногда их дробит)."""
    ordered = sorted(lines, key=lambda line: (round(line.y0, 1), line.x0))
    merged: List[Line] = []
    for line in ordered:
        if merged:
            previous = merged[-1]
            gap = line.x0 - previous.x1
            if abs(line.y0 - previous.y0) <= 2.0 and -5.0 <= gap <= 10.0:
                previous.spans.extend(line.spans)
                previous.x0 = min(previous.x0, line.x0)
                continue
        merged.append(line)
    return merged


def _column_base(lines: List[Line]) -> float:
    """Доминирующий левый отступ колонки (учитывает текст, обтекающий рисунок)."""
    counts: Dict[int, int] = {}
    for line in lines:
        key = round(line.x0)
        counts[key] = counts.get(key, 0) + 1
    if not counts:
        return 0.0
    return float(max(counts, key=lambda key: counts[key]))


#: Форматы изображений, которые Word понимает «как есть».
SUPPORTED_IMAGE_EXT = {"jpeg", "jpg", "png", "gif", "bmp", "tiff"}


def _normalize_image(
    doc: pymupdf.Document, xref: int, data: bytes, ext: str
) -> Tuple[bytes, str]:
    """Привести картинку к формату, поддерживаемому Word (JPEG 2000 и др. — конвертируем)."""
    if ext in SUPPORTED_IMAGE_EXT:
        return data, ext
    try:
        pixmap = pymupdf.Pixmap(doc, xref)
    except Exception:  # noqa: BLE001 - не удалось декодировать
        return data, ext
    candidates = [pixmap]
    try:  # индексированные/CMYK и прочие приводим к RGB
        candidates.append(pymupdf.Pixmap(pymupdf.csRGB, pixmap))
    except Exception:  # noqa: BLE001
        pass
    for candidate in candidates:
        if candidate.alpha:
            try:
                return candidate.tobytes("png"), "png"
            except Exception:  # noqa: BLE001
                continue
        for output in ("jpeg", "png"):
            try:
                return candidate.tobytes(output), output
            except Exception:  # noqa: BLE001
                continue
    return data, ext


def _page_images(page: pymupdf.Page, doc: pymupdf.Document) -> List[ImageRef]:
    """Извлечь иллюстрации страницы с их размещением."""
    images: List[ImageRef] = []
    for info in page.get_image_info(xrefs=True):
        xref = info.get("xref", 0)
        if not xref:
            continue
        try:
            raw = doc.extract_image(xref)
        except Exception:  # noqa: BLE001 - повреждённое изображение пропускаем
            continue
        data, ext = _normalize_image(doc, xref, raw["image"], raw["ext"])
        bbox = info["bbox"]
        images.append(
            ImageRef(
                xref=xref,
                x0=bbox[0],
                y0=bbox[1],
                x1=bbox[2],
                y1=bbox[3],
                width=int(info.get("width", 0)),
                height=int(info.get("height", 0)),
                data=data,
                ext=ext,
            )
        )
    return images


def _page_flow(page: pymupdf.Page, doc: pymupdf.Document) -> List[object]:
    """Упорядочить содержимое страницы: левая колонка, затем правая.

    Возвращает список элементов — :class:`Line` и :class:`ImageRef`.
    """
    lines = _page_lines(page)
    images = _page_images(page, doc)
    body = [line for line in lines if not line.caption]
    split = page.rect.width / 2  # граница колонок — середина страницы
    left = [e for e in body if e.x0 < split]
    right = [e for e in body if e.x0 >= split]
    left_images = [e for e in images if e.x0 < split]
    right_images = [e for e in images if e.x0 >= split]

    def sort_key(element: object) -> Tuple[float, float]:
        return (round(getattr(element, "y0"), 1), getattr(element, "x0"))

    if len(left) >= 3 and len(right) >= 3:  # две колонки
        left_margin = min(line.x0 for line in left)
        right_margin = min(line.x0 for line in right)
        left_base = _column_base(left)
        right_base = _column_base(right)
        for line in lines:
            if line.x0 < split:
                line.col_margin = left_margin
                line.col_base = left_base
            else:
                line.col_margin = right_margin
                line.col_base = right_base
        left_all: List[object] = [*(line for line in lines if line.x0 < split), *left_images]
        right_all: List[object] = [
            *(line for line in lines if line.x0 >= split),
            *right_images,
        ]
        return sorted(left_all, key=sort_key) + sorted(right_all, key=sort_key)

    reference = body or lines
    margin = min((line.x0 for line in reference), default=0.0)
    base = _column_base(reference)
    for line in lines:
        line.col_margin = margin
        line.col_base = base
    everything: List[object] = [*lines, *images]
    return sorted(everything, key=sort_key)


class Flow:
    """Сборка линейного потока блоков (заголовки, абзацы, авторы)."""

    def __init__(self) -> None:
        self.items: List[Tuple[str, str]] = []
        self.item_images: List[List[ArticleImage]] = []
        self._para: str | None = None
        self._prev_hyph = False
        self._title: str | None = None
        self._title_hyph = False
        self._article_item = -1
        self._title_images: List[ImageRef] = []
        self._title_prefix: str | None = None

    def _append(
        self, kind: str, text: str, images: List[ImageRef] | None = None
    ) -> int:
        self.items.append((kind, text))
        self.item_images.append(
            [ArticleImage(image=image) for image in images] if images else []
        )
        return len(self.items) - 1

    def _current_images(self) -> List[ArticleImage] | None:
        """Список иллюстраций текущей статьи (или None)."""
        if self._article_item >= 0:
            return self.item_images[self._article_item]
        return None

    # --- Абзацы ------------------------------------------------------------
    def flush_para(self) -> None:
        if self._para is not None and self._para.strip():
            self._append("p", self._para.strip())
        self._para = None
        self._prev_hyph = False

    def _with_title_prefix(self, text: str) -> str:
        """Дописать название статьи в начало её первого абзаца."""
        if self._title_prefix is None:
            return text
        prefix = self._title_prefix
        self._title_prefix = None
        separator = "" if text[:1] in _NO_SPACE_BEFORE else " "
        return prefix + separator + text

    def add_body(self, text: str, new_para: bool, next_text: str = "") -> None:
        text, hyph = _clean(text, next_text)
        if not text:
            return
        if self._para is None or new_para:
            self.flush_para()
            self._para = self._with_title_prefix(text)
        elif self._prev_hyph:
            # Слово разорвано переносом; дефис сохраняем только в сложных словах.
            keep = text[:1].isupper() and self._para[-1:].islower()
            self._para += ("-" if keep else "") + text
        else:
            self._para += " " + text
        self._prev_hyph = hyph

    # --- Заголовки ---------------------------------------------------------
    def flush_title(self) -> None:
        if self._title is not None and self._title.strip():
            title = self._title.strip()
            self._article_item = self._append("h2", title, self._title_images)
            self._title_prefix = title
        self._title = None
        self._title_hyph = False
        self._title_images = []

    def add_title(self, text: str, next_text: str = "") -> None:
        text, hyph = _clean(text, next_text)
        if not text:
            return
        if self._title is None:
            self.flush_para()
            self._title = text
            self._title_images = []
            self._title_prefix = None
        elif self._title_hyph:
            keep = text[:1].isupper() and self._title[-1:].islower()
            self._title += ("-" if keep else "") + text
        else:
            self._title += " " + text
        self._title_hyph = hyph

    def add_image(self, image: ImageRef) -> None:
        """Привязать иллюстрацию к текущей статье (встанет после её заголовка)."""
        if self._title is not None:
            self._title_images.append(image)
            return
        images = self._current_images()
        if images is not None:
            images.append(ArticleImage(image=image))

    def add_caption(self, text: str) -> None:
        """Дописать подпись к последней иллюстрации текущей статьи."""
        text, _ = _clean(text)
        if not text:
            return
        images = self._current_images()
        if images:
            images[-1].caption = (images[-1].caption + " " + text).strip()

    def add_author(self, text: str) -> None:
        self.flush_title()
        self.flush_para()
        self._title_prefix = None
        text, _ = _clean(text)
        if text:
            self._append("author", text)

    def finish(self) -> None:
        self.flush_title()
        self.flush_para()


def _split_title(line: Line) -> Tuple[str, str]:
    """Отделить полужирный заголовок строки от последующего обычного текста."""
    bold: List[str] = []
    rest = ""
    for index, span in enumerate(line.spans):
        if span.bold and not span.italic:
            bold.append(span.text)
        else:
            rest = "".join(s.text for s in line.spans[index:])
            break
    return "".join(bold), rest


def _demote_fragments(flow: Flow) -> None:
    """Заголовки со строчной буквы — это продолжение текста, а не названия статей."""
    items: List[Tuple[str, str]] = []
    images: List[List[ArticleImage]] = []
    last_heading = -1
    for (kind, text), item_images in zip(flow.items, flow.item_images):
        if kind == "h2" and text[:1].islower() and items:
            prev_kind, prev_text = items[-1]
            items[-1] = (prev_kind, (prev_text + " " + text).strip())
            # Иллюстрации оставляем у ближайшего настоящего заголовка статьи.
            target = last_heading if last_heading >= 0 else len(items) - 1
            images[target] = images[target] + item_images
            continue
        items.append((kind, text))
        images.append(list(item_images))
        if kind == "h2":
            last_heading = len(items) - 1
    flow.items = items
    flow.item_images = images


def _next_line_text(elements: List[object], index: int) -> str:
    """Текст ближайшей следующей текстовой строки (картинки и подписи пропускаем)."""
    for element in elements[index + 1:]:
        if isinstance(element, Line) and not element.caption:
            return element.text
    return ""


def _column_count(page: pymupdf.Page) -> int:
    """Число колонок на странице (по разрывам между x-диапазонами строк)."""
    spans: List[Tuple[float, float]] = []
    for block in page.get_text("dict")["blocks"]:
        if block.get("type") != 0:
            continue
        for line in block["lines"]:
            if "".join(s["text"] for s in line["spans"]).strip():
                spans.append((line["bbox"][0], line["bbox"][2]))
    if not spans:
        return 0
    spans.sort()
    columns = 0
    current_end = None
    for x0, x1 in spans:
        if current_end is None or x0 - current_end > 6.0:
            columns += 1
            current_end = x1
        else:
            current_end = max(current_end, x1)
    return columns


def _detect_articles(doc: pymupdf.Document) -> Tuple[int, int]:
    """Определить диапазон страниц со статьями по доминирующему кеглю текста."""
    page_sizes: List[Dict[float, int]] = []
    weight: Dict[float, int] = {}
    for page_no in range(len(doc)):
        sizes: Dict[float, int] = {}
        for block in doc[page_no].get_text("dict")["blocks"]:
            if block.get("type") != 0:
                continue
            for line in block["lines"]:
                for span in line["spans"]:
                    text = span["text"].strip()
                    if text:
                        key = round(span["size"], 1)
                        sizes[key] = sizes.get(key, 0) + len(text)
        page_sizes.append(sizes)
        if sizes:
            top = max(sizes, key=lambda key: sizes[key])
            weight[top] = weight.get(top, 0) + sum(sizes.values())
    if not weight:
        return 0, len(doc)
    body_size = max(weight, key=lambda key: weight[key])
    inside = [
        page_no
        for page_no, sizes in enumerate(page_sizes)
        if sizes and sizes.get(body_size, 0) >= 0.3 * sum(sizes.values())
    ]
    if not inside:
        return 0, len(doc)
    start, end = inside[0], inside[-1] + 1
    # Отбрасываем замыкающие справочные страницы (списки в 3 и более колонок).
    while end - 1 > start and _column_count(doc[end - 1]) >= 3:
        end -= 1
    return start, end


def build_flow(doc: pymupdf.Document, start: int, end: int) -> Flow:
    """Построить линейный поток блоков по страницам [start, end)."""
    elements: List[object] = []
    for page_no in range(start, min(end, len(doc))):
        elements.extend(_page_flow(doc[page_no], doc))

    flow = Flow()
    in_title = False
    prev_hyph = False
    for index, element in enumerate(elements):
        if isinstance(element, ImageRef):
            flow.add_image(element)
            continue
        line = cast(Line, element)
        if line.caption:
            flow.add_caption(line.text)
            continue
        next_text = _next_line_text(elements, index)
        if line.is_author:
            flow.add_author(line.text)
            in_title = False
            prev_hyph = False
            continue
        at_margin = line.x0 <= line.col_margin + MARGIN_TOLERANCE
        bold_start = line.first.bold and not line.first.italic and at_margin
        # Строка начинает заголовок, если она полужирная у левого края и не
        # является продолжением слова, разорванного переносом.
        if bold_start and (in_title or not prev_hyph):
            bold, rest = _split_title(line)
            flow.add_title(bold, next_text)
            if rest.strip():
                flow.flush_title()
                in_title = False
                flow.add_body(rest, new_para=True, next_text=next_text)
                prev_hyph = _word_continues(rest, next_text)
            else:
                in_title = True
                prev_hyph = _word_continues(bold, next_text)
            continue
        flow.flush_title()
        in_title = False
        offset = line.x0 - line.col_base
        indent = (INDENT_THRESHOLD <= offset <= INDENT_MAX) and not prev_hyph
        flow.add_body(line.text, new_para=indent, next_text=next_text)
        prev_hyph = _word_continues(line.text, next_text)
    flow.finish()
    _demote_fragments(flow)
    return flow


# --- Сборка DOCX ------------------------------------------------------------

def _paragraph(style: str, text: str, bold: bool = False, italic: bool = False) -> str:
    """Собрать абзац <w:p>."""
    props = f'<w:pPr><w:pStyle w:val="{style}"/></w:pPr>' if style else ""
    run_props = ""
    if bold or italic:
        run_props = "<w:rPr>" + ("<w:b/>" if bold else "") + ("<w:i/>" if italic else "") + "</w:rPr>"
    return (
        f"<w:p>{props}<w:r>{run_props}"
        f'<w:t xml:space="preserve">{xml_escape(text)}</w:t></w:r></w:p>'
    )


class DocxMedia:
    """Реестр иллюстраций DOCX: части ``media/*``, связи и DrawingML."""

    def __init__(self) -> None:
        self.parts: Dict[str, bytes] = {}
        self.rels: List[Tuple[str, str]] = []
        self.extensions: set = set()
        self._rel_by_xref: Dict[int, str] = {}
        self._count = 0
        self._drawing_id = 0

    def _rel_id(self, image: ImageRef) -> str:
        rel_id = self._rel_by_xref.get(image.xref)
        if rel_id is not None:
            return rel_id
        self._count += 1
        rel_id = f"rId{self._count}"
        filename = f"image{self._count}.{image.ext}"
        self.parts[f"word/media/{filename}"] = image.data
        self.rels.append((rel_id, f"media/{filename}"))
        self.extensions.add(image.ext)
        self._rel_by_xref[image.xref] = rel_id
        return rel_id

    def drawing(self, image: ImageRef) -> str:
        """Собрать абзац с иллюстрацией (по центру, в исходном размере)."""
        rel_id = self._rel_id(image)
        cx = int(round((image.x1 - image.x0) * EMU_PER_POINT))
        cy = int(round((image.y1 - image.y0) * EMU_PER_POINT))
        if cx > TEXT_WIDTH_EMU:  # не выходить за поля страницы
            cy = int(round(cy * TEXT_WIDTH_EMU / cx))
            cx = TEXT_WIDTH_EMU
        self._drawing_id += 1
        drawing_id = self._drawing_id
        return (
            '<w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r><w:drawing>'
            '<wp:inline distT="0" distB="0" distL="0" distR="0">'
            f'<wp:extent cx="{cx}" cy="{cy}"/>'
            '<wp:effectExtent l="0" t="0" r="0" b="0"/>'
            f'<wp:docPr id="{drawing_id}" name="Picture {drawing_id}"/>'
            '<wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>'
            "<a:graphic>"
            '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">'
            "<pic:pic>"
            f'<pic:nvPicPr><pic:cNvPr id="{drawing_id}" name="image{drawing_id}"/>'
            "<pic:cNvPicPr/></pic:nvPicPr>"
            f'<pic:blipFill><a:blip r:embed="{rel_id}"/>'
            "<a:stretch><a:fillRect/></a:stretch></pic:blipFill>"
            f'<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="{cx}" cy="{cy}"/></a:xfrm>'
            '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>'
            "</pic:pic></a:graphicData></a:graphic></wp:inline>"
            "</w:drawing></w:r></w:p>"
        )


def _document_xml(flow: Flow, media: DocxMedia) -> str:
    """Собрать word/document.xml (одна колонка)."""
    body: List[str] = []
    for (kind, text), images in zip(flow.items, flow.item_images):
        if kind == "h2":
            body.append(_paragraph("Heading2", text))
        elif kind == "author":
            body.append(_paragraph("AuthorRight", text, bold=True, italic=True))
        else:
            body.append(_paragraph("", text))
        for item in images:  # иллюстрации и подписи — сразу после заголовка статьи
            body.append(media.drawing(item.image))
            if item.caption:
                body.append(_paragraph("Caption", item.caption))
    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        f'<w:document xmlns:w="{NS_W}" xmlns:r="{NS_R}" xmlns:wp="{NS_WP}" '
        f'xmlns:a="{NS_A}" xmlns:pic="{NS_PIC}"><w:body>'
        + "".join(body)
        + '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>'
        '<w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1134" '
        'w:header="709" w:footer="709" w:gutter="0"/>'
        "</w:sectPr></w:body></w:document>"
    )


def _styles_xml() -> str:
    """Собрать word/styles.xml (Normal, Heading2, AuthorRight)."""
    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        f'<w:styles xmlns:w="{NS_W}">'
        "<w:docDefaults><w:rPrDefault><w:rPr>"
        '<w:rFonts w:ascii="Times New Roman" w:hAnsi="Times New Roman" w:cs="Times New Roman"/>'
        '<w:sz w:val="24"/><w:szCs w:val="24"/>'
        "</w:rPr></w:rPrDefault>"
        '<w:pPrDefault><w:pPr><w:spacing w:after="120" w:line="240" w:lineRule="auto"/>'
        '<w:jc w:val="both"/></w:pPr></w:pPrDefault>'
        "</w:docDefaults>"
        '<w:style w:type="paragraph" w:default="1" w:styleId="Normal">'
        '<w:name w:val="Normal"/></w:style>'
        '<w:style w:type="paragraph" w:styleId="Heading2">'
        '<w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/>'
        '<w:pPr><w:keepNext/><w:spacing w:before="240" w:after="120"/>'
        '<w:outlineLvl w:val="1"/><w:jc w:val="left"/></w:pPr>'
        '<w:rPr><w:b/><w:sz w:val="28"/><w:szCs w:val="28"/></w:rPr></w:style>'
        '<w:style w:type="paragraph" w:styleId="AuthorRight">'
        '<w:name w:val="Author Right"/><w:basedOn w:val="Normal"/>'
        '<w:pPr><w:jc w:val="right"/><w:spacing w:before="60" w:after="120"/></w:pPr>'
        "<w:rPr><w:b/><w:i/></w:rPr></w:style>"
        '<w:style w:type="paragraph" w:styleId="Caption">'
        '<w:name w:val="Caption"/><w:basedOn w:val="Normal"/>'
        '<w:pPr><w:jc w:val="center"/><w:spacing w:before="60" w:after="180"/></w:pPr>'
        '<w:rPr><w:i/><w:sz w:val="20"/><w:szCs w:val="20"/></w:rPr></w:style>'
        "</w:styles>"
    )


def _content_types_xml(extensions: set) -> str:
    parts = [
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
        f'<Types xmlns="{NS_CT}">',
        '<Default Extension="rels" '
        'ContentType="application/vnd.openxmlformats-package.relationships+xml"/>',
        '<Default Extension="xml" ContentType="application/xml"/>',
    ]
    for extension in sorted(extensions):
        media_type = _MEDIA_TYPE.get(extension, "application/octet-stream")
        parts.append(f'<Default Extension="{extension}" ContentType="{media_type}"/>')
    parts += [
        '<Override PartName="/word/document.xml" '
        'ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>',
        '<Override PartName="/word/styles.xml" '
        'ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>',
        '<Override PartName="/docProps/core.xml" '
        'ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>',
        '<Override PartName="/docProps/app.xml" '
        'ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>',
        "</Types>",
    ]
    return "".join(parts)


def _root_rels_xml() -> str:
    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        f'<Relationships xmlns="{NS_REL}">'
        f'<Relationship Id="rId1" Type="{REL_OFFICE}" Target="word/document.xml"/>'
        f'<Relationship Id="rId2" Type="{REL_CORE}" Target="docProps/core.xml"/>'
        f'<Relationship Id="rId3" Type="{REL_APP}" Target="docProps/app.xml"/>'
        "</Relationships>"
    )


def _document_rels_xml(image_rels: List[Tuple[str, str]]) -> str:
    parts = [
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
        f'<Relationships xmlns="{NS_REL}">',
        f'<Relationship Id="rId0" Type="{REL_STYLES}" Target="styles.xml"/>',
    ]
    for rel_id, target in image_rels:
        parts.append(f'<Relationship Id="{rel_id}" Type="{REL_IMAGE}" Target="{target}"/>')
    parts.append("</Relationships>")
    return "".join(parts)


def _core_xml(title: str, author: str) -> str:
    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<cp:coreProperties '
        'xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:dcterms="http://purl.org/dc/terms/" '
        'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'
        f"<dc:title>{xml_escape(title)}</dc:title>"
        f"<dc:creator>{xml_escape(author)}</dc:creator>"
        "<dc:language>ru</dc:language>"
        "</cp:coreProperties>"
    )


def _app_xml() -> str:
    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" '
        'xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">'
        "<Application>pyFB2</Application></Properties>"
    )


def write_docx(
    flow: Flow,
    out_path: Path,
    title: str = "Русские святые и подвижники Православия",
    author: str = "Институт русской цивилизации",
) -> Path:
    """Записать DOCX-архив (текст + иллюстрации)."""
    media = DocxMedia()
    document = _document_xml(flow, media)
    parts: Dict[str, str | bytes] = {
        "[Content_Types].xml": _content_types_xml(media.extensions),
        "_rels/.rels": _root_rels_xml(),
        "word/document.xml": document,
        "word/_rels/document.xml.rels": _document_rels_xml(media.rels),
        "word/styles.xml": _styles_xml(),
        "docProps/core.xml": _core_xml(title, author),
        "docProps/app.xml": _app_xml(),
    }
    parts.update(media.parts)
    with zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, data in parts.items():
            archive.writestr(name, data)
    return out_path


def convert(
    pdf_path: Path | str,
    out_path: Path | str,
    start: int | None = None,
    end: int | None = None,
) -> Path:
    """Сконвертировать статьи энциклопедии в DOCX.

    Диапазон страниц со статьями определяется автоматически; его можно
    задать явно через ``start``/``end`` (0-индексация, ``end`` не включительно).
    """
    doc = pymupdf.open(str(pdf_path))
    try:
        if start is None or end is None:
            auto_start, auto_end = _detect_articles(doc)
            start = auto_start if start is None else start
            end = auto_end if end is None else end
        flow = build_flow(doc, start, end)
    finally:
        doc.close()
    return write_docx(flow, Path(out_path))


def main(argv: List[str] | None = None) -> int:
    if argv is None:
        argv = sys.argv
    source = None
    output = None
    start = None
    end = None
    rest = argv[1:]
    index = 0
    while index < len(rest):
        arg = rest[index]
        if arg == "--start" and index + 1 < len(rest):
            start = int(rest[index + 1])
            index += 2
            continue
        if arg == "--end" and index + 1 < len(rest):
            end = int(rest[index + 1])
            index += 2
            continue
        if arg.startswith("--"):
            print(f"Неизвестный параметр: {arg}", file=sys.stderr)
            return 2
        if source is None:
            source = arg
        elif output is None:
            output = arg
        index += 1
    if source is None:
        print(
            "Использование: python enc_to_docx.py <файл.pdf> [выход.docx] "
            "[--start N] [--end N]",
            file=sys.stderr,
        )
        return 2
    if output is None:
        output = str(Path(source).with_suffix(".docx"))
    path = convert(source, output, start, end)
    print("DOCX:", path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
