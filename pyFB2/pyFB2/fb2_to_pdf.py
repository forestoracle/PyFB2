"""Экспорт FB2 в PDF (через reportlab).

Модуль предоставляет класс :class:`Fb2ToPdfConverter`, который берёт
структуры из :mod:`fb2_parser` и собирает PDF-документ:

    * метаданные (<description>)   -> заголовок, автор, аннотация;
    * вложенные <section>          -> заголовки разного размера;
    * <p>, <strong>, <emphasis>    -> абзацы и inline-разметка;
    * <epigraph>, <cite>           -> отступы/курсив;
    * <poem>/<stanza>/<v>          -> стихи;
    * <table>                      -> таблица;
    * <binary>                     -> встроенные изображения;
    * оглавление (опционально);
    * закладки PDF (outline) для быстрой навигации по главам.

Требует пакет ``reportlab`` (extra ``pyFB2[pdf]``). Для кириллицы
автоматически подбирается системный TTF-шрифт с поддержкой Unicode
(Arial / DejaVu / Liberation); при его отсутствии используется встроенный
шрифт (латиница).

Пример::

    >>> from fb2_to_pdf import Fb2ToPdfConverter
    >>> converter = Fb2ToPdfConverter()
    >>> converter.write("book.fb2", "book.pdf")
    WindowsPath('book.pdf')
    >>> data = converter.convert("book.fb2")   # bytes PDF
"""

from __future__ import annotations

import io
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Dict, List, Optional, Tuple, Union

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER, TA_JUSTIFY, TA_RIGHT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (
    Image as RLImage,
    Paragraph as RLParagraph,
    SimpleDocTemplate,
    Spacer,
    Table as RLTable,
    TableStyle,
)
from .fb2_xml import parse_xml

from .fb2_parser import TEXT_NODE, Fb2Parser
from .fb2_structures import (
    Binary,
    Body,
    Cite,
    Description,
    EmptyLine,
    Epigraph,
    Image,
    Paragraph,
    Poem,
    Section,
    Stanza,
    StyleNode,
    Subtitle,
    Table,
    Title,
)

#: Кандидаты TTF-шрифтов (normal/bold/italic/boldItalic) по платформам.
_FONT_CANDIDATES: Dict[str, List[str]] = {
    "normal": [
        "C:/Windows/Fonts/arial.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
    ],
    "bold": [
        "C:/Windows/Fonts/arialbd.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
    ],
    "italic": [
        "C:/Windows/Fonts/ariali.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Oblique.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Italic.ttf",
        "/System/Library/Fonts/Supplemental/Arial Italic.ttf",
    ],
    "boldItalic": [
        "C:/Windows/Fonts/arialbi.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-BoldOblique.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-BoldItalic.ttf",
        "/System/Library/Fonts/Supplemental/Arial Bold Italic.ttf",
    ],
    "mono": [
        "C:/Windows/Fonts/consola.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
        "/System/Library/Fonts/Menlo.ttc",
    ],
}

#: Встроенный (base-14) шрифт reportlab для фолбэка (без кириллицы).
_FALLBACK_FONT = "Helvetica"

#: Имена тел FB2, в которых лежат примечания/сноски (их заголовки не попадают
#: в закладки, чтобы не засорять оглавление просмотрщика).
_NOTE_BODY_NAMES = (
    "notes",
    "footnotes",
    "endnotes",
    "comments",
    "commentaries",
)


class _Fb2DocTemplate(SimpleDocTemplate):
    """``SimpleDocTemplate`` с поддержкой закладок (PDF outline).

    Заголовки, у которых заданы атрибуты ``_bookmark_title`` /
    ``_bookmark_key`` / ``_bookmark_level`` (см.
    :meth:`Fb2ToPdfConverter._add_bookmark`), превращаются в иерархические
    закладки боковой панели просмотрщика PDF.
    """

    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self._outline_base: Optional[int] = None
        self._outline_last: int = -1
        self._outline_keys: set = set()

    def afterFlowable(self, flowable) -> None:
        """Добавить закладку для flowable, помеченного как заголовок."""
        title = getattr(flowable, "_bookmark_title", None)
        key = getattr(flowable, "_bookmark_key", None)
        if not title or not key or key in self._outline_keys:
            return
        self._outline_keys.add(key)
        level = self._normalize_outline_level(
            getattr(flowable, "_bookmark_level", 0)
        )
        self.canv.bookmarkPage(key)
        self.canv.addOutlineEntry(title, key, level=level, closed=False)

    def _normalize_outline_level(self, level: int) -> int:
        """Привести уровень к допустимому (не более +1 к предыдущему).

        reportlab запрещает «прыжки» уровней вниз более чем на один шаг,
        поэтому уровни нормируются относительно первого заголовка.
        """
        if self._outline_base is None:
            self._outline_base = level
            self._outline_last = 0
            return 0
        relative = max(level - self._outline_base, 0)
        if relative > self._outline_last + 1:
            relative = self._outline_last + 1
        self._outline_last = relative
        return relative


class Fb2ToPdfConverter:
    """Преобразование разобранного FB2 в PDF (через reportlab).

    :param parser: готовый :class:`Fb2Parser` (иначе создаётся новый).
    :param font_path: путь к TTF-шрифту с кириллицей. Если не задан,
        выполняется поиск системного шрифта (Arial / DejaVu / Liberation).
    :param font_name: имя регистрируемого шрифта.
    :param font_size: базовый размер шрифта (pt).
    :param page_size: размер страницы (по умолчанию A4).
    :param margin_mm: поля страницы в мм.
    :param heading_offset: уровень заголовка для секций верхнего уровня.
    :param max_heading_level: максимальный уровень заголовка (1..6).
    :param include_toc: вставлять ли оглавление.
    :param toc_title: заголовок оглавления.
    :param include_bookmarks: добавлять ли закладки PDF (outline) по главам.
    :param include_annotation: выводить ли аннотацию книги.
    :param include_epigraphs: выводить ли эпиграфы.
    :param include_cover: выводить ли обложку из <coverpage>.
    :param image_max_width_mm: максимальная ширина изображения (мм).
    """

    def __init__(
        self,
        parser: Optional[Fb2Parser] = None,
        font_path: Optional[Union[str, Path]] = None,
        font_name: str = "pyFB2",
        font_size: int = 11,
        page_size: Tuple[float, float] = A4,
        margin_mm: float = 20,
        heading_offset: int = 1,
        max_heading_level: int = 6,
        include_toc: bool = False,
        toc_title: str = "Оглавление",
        include_bookmarks: bool = True,
        include_annotation: bool = True,
        include_epigraphs: bool = True,
        include_cover: bool = False,
        image_max_width_mm: float = 150,
    ) -> None:
        self.parser = parser if parser is not None else Fb2Parser()
        self.font_path = font_path
        self.font_name = font_name
        self.font_size = font_size
        self.page_size = page_size
        self.margin = margin_mm * mm
        self.heading_offset = heading_offset
        self.max_heading_level = max_heading_level
        self.include_toc = include_toc
        self.toc_title = toc_title
        self.include_bookmarks = include_bookmarks
        self.include_annotation = include_annotation
        self.include_epigraphs = include_epigraphs
        self.include_cover = include_cover
        self.image_max_width = image_max_width_mm * mm

        # Состояние (заполняется в _prepare).
        self.description: Optional[Description] = None
        self.bodies: List[Body] = []
        self.binaries: List[Binary] = []
        self._binary_by_id: Dict[str, Binary] = {}
        #: Имена назначений (id секций) для разрешения внутренних ссылок.
        self._anchors: set = set()
        #: Счётчик закладок PDF (уникальные ключи outline).
        self._bookmark_counter: int = 0

        self._base_font = _FALLBACK_FONT
        self._code_font = _FALLBACK_FONT
        self._register_fonts()
        self._styles: Dict[str, ParagraphStyle] = {}
        self._build_styles()

    # --- Публичный API -----------------------------------------------------
    def convert(self, source) -> bytes:
        """Вернуть PDF-документ (bytes) для FB2-источника.

        :param source: путь к файлу, file-like объект или ``ET.Element``.
        """
        self._prepare(source)
        story = self._build_story()
        buf = io.BytesIO()
        doc = _Fb2DocTemplate(
            buf,
            pagesize=self.page_size,
            leftMargin=self.margin,
            rightMargin=self.margin,
            topMargin=self.margin,
            bottomMargin=self.margin,
            title=self._book_title(),
            author=self._author_text(),
        )
        doc.build(story)
        return buf.getvalue()

    def write(self, source, output: Optional[Union[str, Path]] = None) -> Path:
        """Сохранить книгу как PDF и вернуть путь к файлу."""
        data = self.convert(source)
        if output is None:
            src = source if isinstance(source, (str, Path)) else None
            output = Path(src).with_suffix(".pdf") if src else Path("book.pdf")
        output = Path(output)
        output.write_bytes(data)
        return output

    # --- Подготовка --------------------------------------------------------
    def _prepare(self, source) -> None:
        """Разобрать источник в структуры."""
        root = self._root(source)
        try:
            self.description = self.parser.parse(root)
        except ValueError:
            self.description = None
        self.bodies = self.parser.parse_bodies(root)
        self.binaries = self.parser.parse_binaries(root)
        self._binary_by_id = {b.id: b for b in self.binaries}
        self._anchors = set()
        for body in self.bodies:
            self._collect_anchors(body.sections, self._anchors)

    @staticmethod
    def _root(source) -> ET.Element:
        """Получить корневой элемент документа."""
        if isinstance(source, ET.Element):
            return source
        return parse_xml(source)

    # --- Шрифты и стили ----------------------------------------------------
    def _resolve_fonts(self) -> Dict[str, str]:
        """Найти TTF-файлы (normal/bold/italic/boldItalic) для кириллицы."""
        if self.font_path:
            path = Path(self.font_path)
            if path.is_file():
                return {
                    "normal": str(path),
                    "bold": str(path),
                    "italic": str(path),
                    "boldItalic": str(path),
                }

        found: Dict[str, str] = {}
        for variant, candidates in _FONT_CANDIDATES.items():
            for candidate in candidates:
                if Path(candidate).is_file():
                    found[variant] = candidate
                    break
        if "normal" not in found:
            return {}
        for variant in ("bold", "italic", "boldItalic"):
            found.setdefault(variant, found["normal"])
        return found

    def _register_fonts(self) -> None:
        """Зарегистрировать TTF в reportlab (или откатиться на base-14)."""
        fonts = self._resolve_fonts()
        if not fonts:
            self._base_font = _FALLBACK_FONT
            self._code_font = _FALLBACK_FONT
            return
        try:
            for variant, path in fonts.items():
                pdfmetrics.registerFont(TTFont(f"{self.font_name}-{variant}", path))
            pdfmetrics.registerFontFamily(
                self.font_name,
                normal=f"{self.font_name}-normal",
                bold=f"{self.font_name}-bold",
                italic=f"{self.font_name}-italic",
                boldItalic=f"{self.font_name}-boldItalic",
            )
            self._base_font = f"{self.font_name}-normal"
            self._code_font = (
                f"{self.font_name}-mono" if "mono" in fonts else self._base_font
            )
        except Exception:
            self._base_font = _FALLBACK_FONT
            self._code_font = _FALLBACK_FONT

    def _build_styles(self) -> None:
        """Создать набор стилей абзацев."""
        base = self._base_font
        size = self.font_size
        styles: Dict[str, ParagraphStyle] = {
            "title": ParagraphStyle(
                "title", fontName=base, fontSize=size * 2, leading=size * 2.4,
                alignment=TA_CENTER, spaceAfter=8,
            ),
            "author": ParagraphStyle(
                "author", fontName=base, fontSize=size * 1.2, leading=size * 1.6,
                alignment=TA_CENTER, spaceAfter=12,
            ),
            "annotation": ParagraphStyle(
                "annotation", fontName=base, fontSize=size * 0.95, leading=size * 1.4,
                leftIndent=10 * mm, rightIndent=10 * mm, textColor=colors.grey,
                spaceAfter=8,
            ),
            "body": ParagraphStyle(
                "body", fontName=base, fontSize=size, leading=size * 1.45,
                firstLineIndent=size * 1.2, alignment=TA_JUSTIFY, spaceAfter=4,
            ),
            "subtitle": ParagraphStyle(
                "subtitle", fontName=base, fontSize=size * 1.1, leading=size * 1.5,
                alignment=TA_CENTER, spaceBefore=8, spaceAfter=8,
            ),
            "quote": ParagraphStyle(
                "quote", fontName=base, fontSize=size, leading=size * 1.4,
                leftIndent=10 * mm, rightIndent=8 * mm, spaceAfter=4,
            ),
            "epigraph": ParagraphStyle(
                "epigraph", fontName=base, fontSize=size * 0.95, leading=size * 1.4,
                leftIndent=12 * mm, rightIndent=8 * mm,
                textColor=colors.HexColor("#444444"), spaceAfter=6,
            ),
            "poem": ParagraphStyle(
                "poem", fontName=base, fontSize=size, leading=size * 1.45,
                leftIndent=15 * mm, spaceAfter=0,
            ),
            "text_author": ParagraphStyle(
                "text_author", fontName=base, fontSize=size, leading=size * 1.4,
                alignment=TA_RIGHT, spaceAfter=6,
            ),
            "toc_title": ParagraphStyle(
                "toc_title", fontName=base, fontSize=size * 1.3, leading=size * 1.6,
                alignment=TA_CENTER, spaceAfter=8,
            ),
            "anchor": ParagraphStyle(
                "anchor", fontName=base, fontSize=1, leading=1,
                spaceBefore=0, spaceAfter=0,
            ),
        }
        for level in range(1, 7):
            font_size = max(size * (1.7 - 0.12 * (level - 1)), size * 1.05)
            styles[f"h{level}"] = ParagraphStyle(
                f"h{level}", fontName=base, fontSize=font_size, leading=font_size * 1.3,
                alignment=TA_CENTER if level == 1 else 0,
                spaceBefore=12, spaceAfter=6,
            )
        self._styles = styles

    # --- Сборка документа --------------------------------------------------
    def _build_story(self) -> List:
        """Собрать список Flowable для reportlab."""
        story: List = []
        self._bookmark_counter = 0
        story += self._render_metadata()
        if self.include_toc:
            story += self._render_toc()
        for body in self.bodies:
            story += self._render_body(body)
        if not story:
            story.append(RLParagraph("(пустой документ)", self._styles["body"]))
        return story

    def _render_metadata(self) -> List:
        """Заголовок книги, автор, обложка, аннотация."""
        info = self.description.title_info if self.description else None
        if info is None:
            return []

        story: List = []
        if info.book_title is not None and info.book_title.value:
            title_para = RLParagraph(
                self._escape(info.book_title.value), self._styles["title"]
            )
            if self.include_bookmarks:
                self._add_bookmark(title_para, info.book_title.value, 0)
            story.append(title_para)
        authors = self._author_text()
        if authors:
            story.append(RLParagraph(self._escape(authors), self._styles["author"]))

        if self.include_cover and info.coverpage is not None:
            for image in info.coverpage.images:
                flow = self._make_image(image.href, image.alt)
                if flow is not None:
                    story.append(flow)
                    story.append(Spacer(1, 6))

        if self.include_annotation and info.annotation is not None:
            for item in info.annotation.items:
                story += self._render_block(item, style="annotation")

        story.append(Spacer(1, 8))
        return story

    def _render_toc(self) -> List:
        """Оглавление (плоский список заголовков)."""
        headings = self._collect_headings()
        if not headings:
            return []

        story: List = [RLParagraph(self._escape(self.toc_title), self._styles["toc_title"])]
        for level, text in headings:
            style = ParagraphStyle(
                f"toc-{level}",
                parent=self._styles["body"],
                leftIndent=(level - 1) * 8,
                firstLineIndent=0,
                fontSize=self.font_size * 0.95,
            )
            story.append(RLParagraph(self._escape(text), style))
        story.append(Spacer(1, 10))
        return story

    def _collect_headings(self) -> List[Tuple[int, str]]:
        """Собрать (уровень, текст) заголовков для оглавления."""
        result: List[Tuple[int, str]] = []

        def walk(section: Section, level: int) -> None:
            if section.title is not None:
                text = self._title_text(section.title)
                if text:
                    result.append((level, text))
            for child in section.sections:
                walk(child, level + 1)

        for body in self.bodies:
            if body.title is not None:
                text = self._title_text(body.title)
                if text:
                    result.append((0, text))
            for section in body.sections:
                walk(section, self.heading_offset)
        return result

    @staticmethod
    def _collect_anchors(sections: List[Section], acc: set) -> None:
        """Собрать id всех секций — цели внутренних ссылок.

        :param sections: список секций для обхода.
        :param acc: множество, куда складываются найденные id.
        """
        for section in sections:
            if section.id:
                acc.add(section.id)
            Fb2ToPdfConverter._collect_anchors(section.sections, acc)

    # --- Тело книги --------------------------------------------------------
    def _render_body(self, body: Body) -> List:
        """Отрисовать <body>."""
        story: List = []
        in_notes = (body.name or "").lower() in _NOTE_BODY_NAMES
        if body.title is not None:
            para = self._title_paragraph(body.title, 1)
            if self.include_bookmarks:
                self._add_bookmark(para, self._title_text(body.title), 0)
            story.append(para)
        if self.include_epigraphs:
            for epigraph in body.epigraphs:
                story += self._render_epigraph(epigraph)
        if body.image is not None:
            flow = self._make_image(body.image.href, body.image.alt)
            if flow is not None:
                story.append(flow)
        for section in body.sections:
            story += self._render_section(section, self.heading_offset, in_notes)
        return story

    def _render_section(
        self, section: Section, level: int, in_notes: bool = False
    ) -> List:
        """Отрисовать секцию (рекурсивно).

        :param in_notes: секция лежит в теле примечаний — её заголовки не
            добавляются в закладки PDF.
        """
        story: List = []
        anchor = self._anchor_markup(section.id)
        if section.title is not None:
            para = self._title_paragraph(section.title, level, prefix=anchor)
            if self.include_bookmarks and not in_notes:
                self._add_bookmark(para, self._title_text(section.title), level)
            story.append(para)
        elif anchor:
            # Секция без заголовка, но с id — размещаем назначение отдельно,
            # чтобы внутренние ссылки на неё разрешались.
            story.append(RLParagraph(anchor, self._styles["anchor"]))
        if self.include_epigraphs:
            for epigraph in section.epigraphs:
                story += self._render_epigraph(epigraph)
        if section.image is not None:
            flow = self._make_image(section.image.href, section.image.alt)
            if flow is not None:
                story.append(flow)
        if self.include_annotation and section.annotation is not None:
            for item in section.annotation.items:
                story += self._render_block(item, style="annotation")
        for block in section.content:
            story += self._render_block(block)
        for child in section.sections:
            story += self._render_section(child, level + 1, in_notes)
        return story

    def _add_bookmark(self, flowable, title: str, level: int) -> None:
        """Пометить заголовок как закладку PDF (outline).

        Значения сохраняются в атрибутах flowable и читаются
        :class:`_Fb2DocTemplate` в момент отрисовки.
        """
        title = (title or "").strip()
        if not title:
            return
        self._bookmark_counter += 1
        flowable._bookmark_title = title
        flowable._bookmark_key = f"toc-{self._bookmark_counter}"
        flowable._bookmark_level = level

    def _title_paragraph(
        self, title: Optional[Title], level: int, prefix: str = ""
    ) -> RLParagraph:
        """Заголовок как полужирный абзац соответствующего размера.

        :param prefix: разметка, добавляемая перед заголовком (например,
            именованное назначение ``<a name="…"/>`` для внутренних ссылок).
        """
        text = self._render_title_text(title)
        style = self._styles.get(f"h{min(max(level, 1), 6)}", self._styles["h1"])
        return RLParagraph(f"{prefix}<b>{text}</b>", style)

    def _anchor_markup(self, anchor_id: Optional[str]) -> str:
        """Разметка именованного назначения reportlab для внутренних ссылок."""
        if not anchor_id:
            return ""
        return f'<a name="{self._escape_attr(anchor_id)}"/>'

    # --- Блочные элементы --------------------------------------------------
    def _render_block(self, block, style: Optional[str] = None) -> List:
        """Отрисовать блочный элемент FB2."""
        if isinstance(block, Paragraph):
            return [RLParagraph(self._render_inline(block.content), self._styles[style or "body"])]
        if isinstance(block, Subtitle):
            return [
                RLParagraph(f"<b>{self._render_inline(block.content)}</b>", self._styles["subtitle"])
            ]
        if isinstance(block, EmptyLine):
            return [Spacer(1, self.font_size)]
        if isinstance(block, Cite):
            return self._render_cite(block)
        if isinstance(block, Epigraph):
            return self._render_epigraph(block)
        if isinstance(block, Poem):
            return self._render_poem(block)
        if isinstance(block, Table):
            return self._render_table(block)
        if isinstance(block, Image):
            flow = self._make_image(block.href, block.alt)
            return [flow] if flow is not None else []
        return []

    def _render_cite(self, cite: Cite) -> List:
        """Цитата <cite>."""
        story: List = []
        for item in cite.items:
            story += self._render_block(item, style="quote")
        for author in cite.text_author:
            story.append(
                RLParagraph(self._render_inline(author.content), self._styles["text_author"])
            )
        return story

    def _render_epigraph(self, epigraph: Epigraph) -> List:
        """Эпиграф <epigraph>."""
        story: List = []
        for item in epigraph.items:
            story += self._render_block(item, style="epigraph")
        for author in epigraph.text_author:
            story.append(
                RLParagraph(
                    f"<i>{self._render_inline(author.content)}</i>",
                    self._styles["text_author"],
                )
            )
        return story

    def _render_poem(self, poem: Poem) -> List:
        """Стихотворение <poem>."""
        story: List = []
        if poem.title is not None:
            story.append(
                RLParagraph(f"<b>{self._render_title_text(poem.title)}</b>", self._styles["subtitle"])
            )
        for epigraph in poem.epigraphs:
            story += self._render_epigraph(epigraph)
        for item in poem.items:
            if isinstance(item, Stanza):
                story += self._render_stanza(item)
            elif isinstance(item, Subtitle):
                story.append(
                    RLParagraph(f"<b>{self._render_inline(item.content)}</b>", self._styles["subtitle"])
                )
        for author in poem.text_author:
            story.append(
                RLParagraph(
                    f"<i>{self._render_inline(author.content)}</i>",
                    self._styles["text_author"],
                )
            )
        return story

    def _render_stanza(self, stanza: Stanza) -> List:
        """Строфа <stanza>."""
        story: List = []
        if stanza.subtitle is not None:
            story.append(
                RLParagraph(
                    f"<b>{self._render_inline(stanza.subtitle.content)}</b>",
                    self._styles["subtitle"],
                )
            )
        for verse in stanza.verses:
            story.append(RLParagraph(self._render_inline(verse.content), self._styles["poem"]))
        story.append(Spacer(1, 6))
        return story

    def _render_table(self, table: Table) -> List:
        """Таблица <table>."""
        cell_style = ParagraphStyle(
            "cell", parent=self._styles["body"], firstLineIndent=0, fontSize=self.font_size * 0.9
        )
        data: List[List] = []
        has_header = False
        for row in table.rows:
            cells = []
            for cell in row.cells:
                cells.append(RLParagraph(self._render_inline(cell.children), cell_style))
                if cell.is_header:
                    has_header = True
            data.append(cells)
        if not data:
            return []

        tbl = RLTable(data, hAlign="CENTER")
        style = [
            ("GRID", (0, 0), (-1, -1), 0.5, colors.grey),
            ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
            ("LEFTPADDING", (0, 0), (-1, -1), 4),
            ("RIGHTPADDING", (0, 0), (-1, -1), 4),
        ]
        if has_header:
            style.append(("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#eeeeee")))
        tbl.setStyle(TableStyle(style))
        return [tbl, Spacer(1, 6)]

    # --- Inline-разметка ---------------------------------------------------
    def _render_inline(self, nodes: List[StyleNode]) -> str:
        """Собрать inline-разметку reportlab из списка StyleNode."""
        parts: List[str] = []
        for node in nodes:
            tag = node.tag
            if tag == TEXT_NODE:
                parts.append(self._escape(node.text))
            elif tag == "strong":
                parts.append(f"<b>{self._render_inline(node.children)}</b>")
            elif tag == "emphasis":
                parts.append(f"<i>{self._render_inline(node.children)}</i>")
            elif tag == "strikethrough":
                parts.append(f"<strike>{self._render_inline(node.children)}</strike>")
            elif tag == "sub":
                parts.append(f"<sub>{self._render_inline(node.children)}</sub>")
            elif tag == "sup":
                parts.append(f"<super>{self._render_inline(node.children)}</super>")
            elif tag == "code":
                parts.append(
                    f'<font face="{self._code_font}">{self._render_inline(node.children)}</font>'
                )
            elif tag == "style":
                parts.append(self._render_inline(node.children))
            elif tag == "a":
                inner = self._render_inline(node.children)
                href = node.href or ""
                if href.startswith("#"):
                    # Внутренняя ссылка (например, сноска #n_1). reportlab падает
                    # при сборке, если назначение не определено, поэтому ссылку
                    # оставляем только при наличии реального анкора.
                    target = href[1:]
                    if target and target in self._anchors:
                        parts.append(
                            f'<link href="#{self._escape_attr(target)}">{inner}</link>'
                        )
                    else:
                        parts.append(inner)
                elif href:
                    parts.append(f'<link href="{self._escape_attr(href)}">{inner}</link>')
                else:
                    parts.append(inner)
            elif tag == "image":
                # inline-изображения в PDF пропускаем (поддерживаются блочные)
                continue
        return "".join(parts)

    # --- Изображения -------------------------------------------------------
    def _make_image(self, href: Optional[str], alt: Optional[str]):
        """Создать Flowable-изображение из <binary> (или None)."""
        if not href:
            return None
        image_id = href[1:] if href.startswith("#") else href
        binary = self._binary_by_id.get(image_id)
        if binary is None:
            return None
        try:
            data = self.parser.binary_data(binary)
        except (ValueError, TypeError):
            return None
        try:
            image = RLImage(io.BytesIO(data))
        except Exception:
            return None

        if image.drawWidth > self.image_max_width:
            ratio = self.image_max_width / image.drawWidth
            image.drawWidth *= ratio
            image.drawHeight *= ratio
        image.hAlign = "CENTER"
        return image

    # --- Утилиты -----------------------------------------------------------
    def _book_title(self) -> str:
        """Название книги (для метаданных PDF)."""
        info = self.description.title_info if self.description else None
        if info is not None and info.book_title is not None:
            return info.book_title.value or "FB2"
        return "FB2"

    def _author_text(self) -> str:
        """Строка авторов (для метаданных PDF)."""
        info = self.description.title_info if self.description else None
        if info is None:
            return ""
        return "; ".join(self._format_author(a) for a in info.authors)

    @staticmethod
    def _format_author(author) -> str:
        parts = [author.first_name, author.middle_name, author.last_name]
        return " ".join(p for p in parts if p) or (author.nickname or "")

    def _title_text(self, title: Optional[Title]) -> str:
        """Простой текст заголовка."""
        if title is None:
            return ""
        parts: List[str] = []
        for item in title.items:
            if isinstance(item, Paragraph):
                parts.append(self._nodes_text(item.content))
        return " ".join(p for p in parts if p)

    def _render_title_text(self, title: Optional[Title]) -> str:
        """Заголовок с inline-разметкой."""
        if title is None:
            return ""
        parts: List[str] = []
        for item in title.items:
            if isinstance(item, Paragraph):
                parts.append(self._render_inline(item.content))
        return " ".join(p for p in parts if p)

    @staticmethod
    def _nodes_text(nodes: List[StyleNode]) -> str:
        """Собрать простой текст из списка StyleNode."""
        parts: List[str] = []
        for node in nodes:
            if node.tag == TEXT_NODE:
                parts.append(node.text or "")
            else:
                parts.append(Fb2ToPdfConverter._nodes_text(node.children))
        return "".join(parts)

    @staticmethod
    def _escape(text: Optional[str]) -> str:
        """Экранировать текст для разметки reportlab."""
        return (text or "").replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

    @staticmethod
    def _escape_attr(text: Optional[str]) -> str:
        """Экранировать значение атрибута."""
        return (
            (text or "")
            .replace("&", "&amp;")
            .replace('"', "&quot;")
            .replace("<", "&lt;")
            .replace(">", "&gt;")
        )



__all__ = ["Fb2ToPdfConverter"]


def main(argv: List[str] | None = None) -> int:
    if argv is None:
        argv = sys.argv
    if len(argv) < 2:
        print(
            "Использование: python fb2_to_pdf.py <файл.fb2> "
            "[выход.pdf] [шрифт.ttf]",
            file=sys.stderr,
        )
        return 2

    source = argv[1]
    output = argv[2] if len(argv) > 2 else str(Path(source).with_suffix(".pdf"))
    font_path = argv[3] if len(argv) > 3 else None

    converter = Fb2ToPdfConverter(font_path=font_path, include_toc=True)
    path = converter.write(source, output)
    print("PDF:", path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))








