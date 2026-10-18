"""Экспорт FB2 в HTML с оглавлением и изображениями.

Модуль предоставляет класс :class:`Fb2ToHtmlConverter`, который берёт
структуры из :mod:`fb2_parser` (см. :class:`~fb2_parser.Fb2Parser`) и
превращает книгу в HTML-документ:

    * метаданные (<description>)        -> заголовок, автор, жанры, аннотация;
    * вложенные <section>               -> <h1>…<h6> с якорями + <section>;
    * автоматическое оглавление (TOC)   -> вложенный список ссылок на главы;
    * <p>, <strong>, <emphasis>, <a>    -> абзацы и inline-разметка;
    * <epigraph>, <cite>                -> <blockquote>;
    * <poem>/<stanza>/<v>               -> блоки со строфами;
    * <table>                           -> HTML-таблица;
    * <binary>                          -> файлы изображений (или data-URI);
    * сноски (<a type="note">)          -> двусторонние ссылки: из текста в
      сноску (``<a class="note-ref">``) и обратно
      (``<a class="footnote-back">↩</a>``), секции-сноски получают ``id`` из FB2.

Пример:
    >>> from fb2_to_html import Fb2ToHtmlConverter
    >>> converter = Fb2ToHtmlConverter(image_dir="images", include_toc=True)
    >>> converter.write("book.fb2", "book.html")
    WindowsPath('book.html')
    >>> # только HTML-строка, без записи файлов:
    >>> html = converter.convert("book.fb2")
"""

from __future__ import annotations

import base64
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from html import escape as html_escape
from pathlib import Path
from typing import Dict, List, Optional, Union

from .fb2_parser import TEXT_NODE, XLINK_HREF, Fb2Parser
from .fb2_structures import (
    Annotation,
    Author,
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
from .fb2_xml import parse_xml

#: Имена тел FB2, в которых лежат примечания/сноски.
NOTE_BODY_NAMES = (
    "notes",
    "footnotes",
    "endnotes",
    "comments",
    "commentaries",
)

#: Значения атрибута ``type`` у ссылок-сносок.
NOTE_LINK_TYPES = ("note", "endnote")

#: Встроенный CSS для HTML-документа.
DEFAULT_CSS = """\
body { font-family: Georgia, 'Times New Roman', serif; line-height: 1.5;
       max-width: 42em; margin: 0 auto; padding: 1em; }
h1, h2, h3, h4, h5, h6 { line-height: 1.25; }
.book-header { text-align: center; margin-bottom: 2em; }
.book-title { font-size: 1.8em; margin-bottom: 0.2em; }
.book-author { font-style: italic; margin: 0; }
.book-genres { color: #666; font-size: 0.9em; }
.toc { border: 1px solid #ccc; border-radius: 4px; padding: 1em 1.5em;
       margin: 1em 0 2em; background: #f9f9f9; }
.toc h2 { margin-top: 0; font-size: 1.2em; }
.toc ul { list-style: none; padding-left: 1.2em; margin: 0.3em 0; }
.toc a { text-decoration: none; color: #0645ad; }
.toc a:hover { text-decoration: underline; }
p { margin: 0; text-indent: 1.2em; }
p.subtitle { text-align: center; font-weight: bold; text-indent: 0; margin: 1em 0; }
p.empty-line { text-indent: 0; height: 1em; }
blockquote { margin: 1em 2em; }
blockquote.epigraph { font-style: italic; }
.poem { margin: 1em 2em; }
.poem .verse { text-indent: 0; }
.poem .poem-title { text-align: center; font-weight: bold; text-indent: 0; }
.text-author { text-align: right; font-style: italic; text-indent: 0; }
.annotation { border-left: 3px solid #ccc; padding-left: 1em;
              margin: 1em 0; font-style: italic; }
table { border-collapse: collapse; margin: 1em auto; }
td, th { border: 1px solid #888; padding: 0.2em 0.5em; }
th { background: #eee; }
img { max-width: 100%; height: auto; }
.cover { text-align: center; margin: 1em 0; }
.image { text-align: center; margin: 1em 0; }
a.note-ref { text-decoration: none; }
section.footnote { font-size: 0.92em; margin: 0.4em 0 0.4em 1.5em; }
section.footnote p { text-indent: 0; }
p.footnote-title { font-weight: bold; text-indent: 0; margin: 0.2em 0; }
p.footnote-back { text-indent: 0; margin-top: 0.2em; }
p.footnote-back a { text-decoration: none; }
"""


@dataclass
class _TocNode:
    """Узел дерева оглавления."""

    anchor: Optional[str]
    title: Optional[str]
    children: List["_TocNode"] = field(default_factory=list)


class Fb2ToHtmlConverter:
    """Преобразование разобранного FB2 в HTML + выгрузка картинок.

    :param parser: готовый :class:`Fb2Parser` (иначе создаётся новый).
    :param image_dir: подкаталог для изображений относительно .html-файла.
        Пустая строка — складывать изображения рядом с .html.
    :param heading_offset: уровень заголовка для секций верхнего уровня
        (1 -> ``<h1>``, 2 -> ``<h2>``).
    :param max_heading_level: максимальная глубина заголовков (1..6).
    :param include_toc: вставлять ли оглавление.
    :param toc_title: заголовок блока оглавления.
    :param include_annotation: выводить ли аннотацию книги.
    :param include_epigraphs: выводить ли эпиграфы.
    :param include_cover: выводить ли обложку из <coverpage>.
    :param inline_images: встраивать изображения как data-URI (единый файл).
    :param note_links: делать сноски двусторонними — ссылка из текста
        (``<a class="note-ref">``) и обратная ссылка из сноски
        (``<a class="footnote-back">``), а секции-сноски получают ``id``
        из FB2 (см. :meth:`note_targets`). Сносками считаются ссылки с
        ``type="note"``/``"endnote"`` и любые ссылки на секции тел
        примечаний (``<body name="notes">`` и подобные).
    :param css: содержимое ``<style>`` (по умолчанию :data:`DEFAULT_CSS`).
    """

    def __init__(
        self,
        parser: Optional[Fb2Parser] = None,
        image_dir: str = "images",
        heading_offset: int = 1,
        max_heading_level: int = 6,
        include_toc: bool = True,
        toc_title: str = "Оглавление",
        include_annotation: bool = True,
        include_epigraphs: bool = True,
        include_cover: bool = True,
        inline_images: bool = False,
        note_links: bool = True,
        css: str = DEFAULT_CSS,
    ) -> None:
        self.parser = parser if parser is not None else Fb2Parser()
        self.image_dir = image_dir
        self.heading_offset = heading_offset
        self.max_heading_level = max_heading_level
        self.include_toc = include_toc
        self.toc_title = toc_title
        self.include_annotation = include_annotation
        self.include_epigraphs = include_epigraphs
        self.include_cover = include_cover
        self.inline_images = inline_images
        self.note_links = note_links
        self.css = css

        # Заполняется в _prepare().
        self.description: Optional[Description] = None
        self.bodies: List[Body] = []
        self.binaries: List[Binary] = []
        self._image_files: Dict[str, str] = {}  # id <binary> -> имя файла
        self._binary_by_id: Dict[str, Binary] = {}
        self._toc_entries: List = []  # (level, anchor, title)
        self._anchor_counter: int = 0
        self._note_targets: set = set()  # id секций-сносок, на которые ссылаются
        self._note_ref_counters: Dict[str, int] = {}

    # --- Публичный API -----------------------------------------------------
    def convert(self, source) -> str:
        """Вернуть HTML-документ для FB2-источника (файлы не создаются).

        :param source: путь к файлу, file-like объект или ``ET.Element``.
        """
        self._prepare(source)
        return self._build_html()

    def write(
        self, source, html_path: Union[str, Path], encoding: str = "utf-8"
    ) -> Path:
        """Сохранить книгу как HTML и выгрузить все <binary>.

        Изображения записываются в ``<каталог .html>/<image_dir>`` (если
        ``image_dir`` не пуст) или рядом с .html-файлом.

        :param source: путь к файлу, file-like объект или ``ET.Element``.
        :param html_path: путь к создаваемому .html-файлу.
        :param encoding: кодировка выходного файла.
        :return: путь к записанному .html-файлу.
        """
        self._prepare(source)
        html = self._build_html()

        html_path = Path(html_path)
        html_path.parent.mkdir(parents=True, exist_ok=True)
        self.save_images(html_path.parent)
        html_path.write_text(html, encoding=encoding)
        return html_path

    def save_images(self, base_dir: Union[str, Path]) -> List[Path]:
        """Выгрузить все <binary> в каталог изображений.

        :param base_dir: каталог, относительно которого берётся ``image_dir``.
        :return: список путей к записанным файлам.
        """
        if not self.binaries:
            return []

        base_dir = Path(base_dir)
        target_dir = base_dir / self.image_dir if self.image_dir else base_dir
        target_dir.mkdir(parents=True, exist_ok=True)

        written: List[Path] = []
        for binary in self.binaries:
            filename = self._image_files.get(binary.id)
            if not filename:
                continue
            path = target_dir / filename
            path.write_bytes(self.parser.binary_data(binary))
            written.append(path)
        return written

    # --- Подготовка --------------------------------------------------------
    def _prepare(self, source) -> None:
        """Разобрать источник и построить карту изображений."""
        root = self._root(source)
        try:
            self.description = self.parser.parse(root)
        except ValueError:
            self.description = None
        self.bodies = self.parser.parse_bodies(root)
        self.binaries = self.parser.parse_binaries(root)
        self._register_images(self.binaries)
        self._note_targets = self._collect_note_targets(root)

    def _collect_note_targets(self, root: ET.Element) -> set:
        """Собрать id сносок, на которые ссылается текст.

        Сноска в FB2 — это ``<a type="note" l:href="#note1">`` в тексте и
        ``<section id="note1">`` в теле примечаний (``<body name="notes">``).
        На практике ``type="note"`` часто опускают, поэтому целью считается
        также любая ссылка, ведущая на секцию тела примечаний.
        """
        if not self.note_links:
            return set()

        note_ids = self._note_section_ids(root)
        targets: set = set()
        for element in root.iter():
            if self._local_name(element.tag) != "a":
                continue
            href = element.get(XLINK_HREF) or element.get("href") or ""
            if not href.startswith("#") or len(href) < 2:
                continue
            target = href[1:]
            link_type = (element.get("type") or "").lower()
            if link_type in NOTE_LINK_TYPES or target in note_ids:
                targets.add(target)
        return targets

    def _note_section_ids(self, root: ET.Element) -> set:
        """id секций из тел примечаний (``<body name="notes">`` и подобных)."""
        ids: set = set()
        for body in root.iter():
            if self._local_name(body.tag) != "body":
                continue
            if (body.get("name") or "").lower() not in NOTE_BODY_NAMES:
                continue
            for element in body.iter():
                if self._local_name(element.tag) != "section":
                    continue
                section_id = element.get("id")
                if section_id:
                    ids.add(section_id)
        return ids

    @staticmethod
    def _local_name(tag: str) -> str:
        """Локальное имя тега: '{ns}a' -> 'a'."""
        return tag.rsplit("}", 1)[-1] if "}" in tag else tag

    def note_targets(self) -> List[str]:
        """id сносок, на которые ссылается текст (после :meth:`convert`)."""
        return sorted(self._note_targets)

    @staticmethod
    def _root(source) -> ET.Element:
        """Получить корневой элемент (один раз читая поток/файл)."""
        if isinstance(source, ET.Element):
            return source
        return parse_xml(source)

    def _register_images(self, binaries: List[Binary]) -> None:
        """Сопоставить id <binary> уникальным именам файлов."""
        self._image_files = {}
        self._binary_by_id = {}
        used = set()
        for binary in binaries:
            filename = self.parser.binary_filename(binary)
            stem, suffix = Path(filename).stem, Path(filename).suffix
            candidate, counter = filename, 1
            while candidate in used:
                candidate = f"{stem}_{counter}{suffix}"
                counter += 1
            used.add(candidate)
            self._image_files[binary.id] = candidate
            self._binary_by_id[binary.id] = binary

    # --- Сборка документа --------------------------------------------------
    def _build_html(self) -> str:
        """Собрать полный HTML-документ."""
        self._anchor_counter = 0
        self._toc_entries = []
        self._note_ref_counters = {}
        content = self._render_bodies()

        toc_html = ""
        if self.include_toc:
            tree = self._build_toc_tree(self._toc_entries)
            toc_html = self._render_toc(tree)

        parts = [
            self._html_head(),
            "<body>",
            self._render_description(),
            toc_html,
            content,
            "</body>",
            "</html>",
        ]
        return "\n".join(p for p in parts if p)

    def _html_head(self) -> str:
        """Собрать <head> с заголовком и встроенным CSS."""
        info = self.description.title_info if self.description else None
        title = info.book_title.value if info and info.book_title else "FB2"
        return (
            "<!DOCTYPE html>\n"
            '<html lang="ru">\n'
            "<head>\n"
            '<meta charset="utf-8"/>\n'
            f"<title>{html_escape(title)}</title>\n"
            f"<style>\n{self.css}</style>\n"
            "</head>"
        )

    def _render_description(self) -> str:
        """Заголовок книги, автор, жанры, обложка, аннотация."""
        info = self.description.title_info if self.description else None
        if info is None:
            return ""

        parts: List[str] = ['<header class="book-header">']
        if info.book_title is not None and info.book_title.value:
            parts.append(f'<h1 class="book-title">{html_escape(info.book_title.value)}</h1>')

        authors = "; ".join(self._format_author(a) for a in info.authors)
        if authors:
            parts.append(f'<p class="book-author">{html_escape(authors)}</p>')

        if info.genres:
            genres = ", ".join(g.value for g in info.genres)
            parts.append(f'<p class="book-genres">{html_escape(genres)}</p>')

        if self.include_cover and info.coverpage is not None:
            for image in info.coverpage.images:
                src = self._image_src(image.href)
                if src:
                    alt = html_escape(image.alt or "Обложка", quote=True)
                    parts.append(f'<div class="cover"><img src="{src}" alt="{alt}"/></div>')

        if self.include_annotation and info.annotation is not None:
            parts.append(self._render_annotation(info.annotation))

        parts.append("</header>")
        return "\n".join(parts)

    # --- Оглавление --------------------------------------------------------
    def _new_anchor(self) -> str:
        """Выделить якорь для заголовка."""
        self._anchor_counter += 1
        return f"sec-{self._anchor_counter}"

    @staticmethod
    def _build_toc_tree(entries: List) -> _TocNode:
        """Построить дерево оглавления из плоского списка (level, anchor, title)."""
        root = _TocNode(None, None)
        stack: List = [(0, root)]
        for level, anchor, title in entries:
            while len(stack) > 1 and stack[-1][0] >= level:
                stack.pop()
            node = _TocNode(anchor, title)
            stack[-1][1].children.append(node)
            stack.append((level, node))
        return root

    def _render_toc(self, root: _TocNode) -> str:
        """Отрисовать блок оглавления (или пустую строку)."""
        if not root.children:
            return ""
        inner = self._render_toc_tree(root)
        return (
            '<nav class="toc">\n'
            f"<h2>{html_escape(self.toc_title)}</h2>\n"
            f"{inner}\n"
            "</nav>"
        )

    def _render_toc_tree(self, node: _TocNode) -> str:
        """Рекурсивно отрисовать вложенный список оглавления."""
        if not node.children:
            return ""
        items: List[str] = []
        for child in node.children:
            sub = self._render_toc_tree(child)
            link = f'<a href="#{child.anchor}">{html_escape(child.title or "")}</a>'
            items.append(f"<li>{link}{sub}</li>")
        return "<ul>" + "".join(items) + "</ul>"

    # --- Тело книги --------------------------------------------------------
    def _render_bodies(self) -> str:
        """Отрисовать все <body>."""
        parts: List[str] = []
        for body in self.bodies:
            parts.append(self._render_body(body))
        return "\n".join(p for p in parts if p)

    def _render_body(self, body: Body) -> str:
        """Отрисовать один <body>."""
        classes = "body"
        in_notes = (body.name or "").lower() in NOTE_BODY_NAMES
        if in_notes:
            classes += " notes"
        parts: List[str] = [f'<div class="{classes}">']

        if body.title is not None:
            anchor = self._new_anchor()
            self._toc_entries.append((0, anchor, self._title_text(body.title)))
            level = min(max(self.heading_offset, 1), self.max_heading_level)
            parts.append(
                f'<h{level} id="{anchor}">{self._render_title_html(body.title)}</h{level}>'
            )

        if self.include_epigraphs:
            for epigraph in body.epigraphs:
                parts.append(self._render_epigraph(epigraph))

        if body.image is not None:
            src = self._image_src(body.image.href)
            if src:
                parts.append(self._render_image_tag(src, body.image.alt))

        for section in body.sections:
            parts.append(
                self._render_section(
                    section, self.heading_offset, in_notes=in_notes
                )
            )

        parts.append("</div>")
        return "\n".join(p for p in parts if p)

    def _render_section(
        self, section: Section, level: int, in_notes: bool = False
    ) -> str:
        """Отрисовать секцию с рекурсивным обходом вложенных.

        :param in_notes: секция лежит в теле примечаний — её заголовки не
            попадают в оглавление и рендерятся как подписи сносок.
        """
        is_note = (
            self.note_links
            and bool(section.id)
            and section.id in self._note_targets
        )
        attrs = ""
        if section.id:
            attrs += f' id="{html_escape(section.id, quote=True)}"'
        if is_note:
            attrs += ' class="footnote"'
        parts: List[str] = [f"<section{attrs}>"]

        if section.title is not None:
            title_html = self._render_title_html(section.title)
            if is_note or in_notes:
                parts.append(f'<p class="footnote-title">{title_html}</p>')
            else:
                anchor = self._new_anchor()
                self._toc_entries.append(
                    (level, anchor, self._title_text(section.title))
                )
                tag = f"h{min(max(level, 1), self.max_heading_level)}"
                parts.append(f'<{tag} id="{anchor}">{title_html}</{tag}>')

        if self.include_epigraphs:
            for epigraph in section.epigraphs:
                parts.append(self._render_epigraph(epigraph))

        if section.image is not None:
            src = self._image_src(section.image.href)
            if src:
                parts.append(self._render_image_tag(src, section.image.alt))

        if self.include_annotation and section.annotation is not None:
            parts.append(self._render_annotation(section.annotation))

        for block in section.content:
            parts.append(self._render_block(block))

        for child in section.sections:
            parts.append(
                self._render_section(child, level + 1, in_notes=in_notes)
            )

        if is_note:
            back = html_escape(f"noteref-{section.id}", quote=True)
            parts.append(
                f'<p class="footnote-back"><a href="#{back}">↩</a></p>'
            )

        parts.append("</section>")
        return "\n".join(p for p in parts if p)

    def _render_image_tag(self, src: str, alt: Optional[str]) -> str:
        """Блочное изображение по центру."""
        alt_attr = html_escape(alt or "", quote=True)
        return f'<div class="image"><img src="{src}" alt="{alt_attr}"/></div>'

    # --- Блочные элементы --------------------------------------------------
    def _render_block(self, block) -> str:
        """Отрисовать блочный элемент FB2 в HTML."""
        if isinstance(block, Paragraph):
            return f"<p>{self._render_inline(block.content)}</p>"
        if isinstance(block, Subtitle):
            return f'<p class="subtitle">{self._render_inline(block.content)}</p>'
        if isinstance(block, EmptyLine):
            return '<p class="empty-line">&#160;</p>'
        if isinstance(block, Cite):
            return self._render_cite(block)
        if isinstance(block, Epigraph):
            return self._render_epigraph(block)
        if isinstance(block, Poem):
            return self._render_poem(block)
        if isinstance(block, Table):
            return self._render_table(block)
        if isinstance(block, Image):
            src = self._image_src(block.href)
            return self._render_image_tag(src, block.alt) if src else ""
        return ""

    def _render_cite(self, cite: Cite) -> str:
        """Цитата <cite> -> <blockquote>."""
        parts: List[str] = ["<blockquote>"]
        for item in cite.items:
            parts.append(self._render_block(item))
        for author in cite.text_author:
            parts.append(f'<p class="text-author">{self._render_inline(author.content)}</p>')
        parts.append("</blockquote>")
        return "\n".join(p for p in parts if p)

    def _render_epigraph(self, epigraph: Epigraph) -> str:
        """Эпиграф -> <blockquote class="epigraph">."""
        parts: List[str] = ['<blockquote class="epigraph">']
        for item in epigraph.items:
            parts.append(self._render_block(item))
        for author in epigraph.text_author:
            parts.append(f'<p class="text-author">{self._render_inline(author.content)}</p>')
        parts.append("</blockquote>")
        return "\n".join(p for p in parts if p)

    def _render_annotation(self, annotation: Annotation) -> str:
        """Аннотация -> <div class="annotation">."""
        parts: List[str] = ['<div class="annotation">']
        for item in annotation.items:
            parts.append(self._render_block(item))
        parts.append("</div>")
        return "\n".join(p for p in parts if p)

    def _render_poem(self, poem: Poem) -> str:
        """Стихотворение -> <div class="poem">."""
        parts: List[str] = ['<div class="poem">']
        if poem.title is not None:
            parts.append(f'<p class="poem-title">{self._render_title_html(poem.title)}</p>')
        for epigraph in poem.epigraphs:
            parts.append(self._render_epigraph(epigraph))
        for item in poem.items:
            if isinstance(item, Stanza):
                parts.append(self._render_stanza(item))
            elif isinstance(item, Subtitle):
                parts.append(f'<p class="subtitle">{self._render_inline(item.content)}</p>')
        for author in poem.text_author:
            parts.append(f'<p class="text-author">{self._render_inline(author.content)}</p>')
        if poem.date is not None and poem.date.value:
            parts.append(f'<p class="text-author">{html_escape(poem.date.value)}</p>')
        parts.append("</div>")
        return "\n".join(p for p in parts if p)

    def _render_stanza(self, stanza: Stanza) -> str:
        """Строфа -> <div class="stanza"> со строками."""
        parts: List[str] = ['<div class="stanza">']
        if stanza.title is not None:
            parts.append(f'<p class="poem-title">{self._render_title_html(stanza.title)}</p>')
        if stanza.subtitle is not None:
            parts.append(f'<p class="subtitle">{self._render_inline(stanza.subtitle.content)}</p>')
        for verse in stanza.verses:
            parts.append(f'<p class="verse">{self._render_inline(verse.content)}</p>')
        parts.append("</div>")
        return "\n".join(p for p in parts if p)

    def _render_table(self, table: Table) -> str:
        """Таблица -> <table>."""
        rows: List[str] = []
        for row in table.rows:
            cells: List[str] = []
            for cell in row.cells:
                tag = "th" if cell.is_header else "td"
                attrs = ""
                if cell.colspan is not None:
                    attrs += f' colspan="{cell.colspan}"'
                if cell.rowspan is not None:
                    attrs += f' rowspan="{cell.rowspan}"'
                cells.append(f"<{tag}{attrs}>{self._render_inline(cell.children)}</{tag}>")
            rows.append("<tr>" + "".join(cells) + "</tr>")
        return "<table>" + "".join(rows) + "</table>"

    # --- Inline-разметка ---------------------------------------------------
    def _render_inline(self, nodes: List[StyleNode]) -> str:
        """Собрать inline-разметку HTML из списка StyleNode."""
        parts: List[str] = []
        for node in nodes:
            tag = node.tag
            if tag == TEXT_NODE:
                parts.append(html_escape(node.text or "", quote=False))
            elif tag == "strong":
                parts.append(f"<strong>{self._render_inline(node.children)}</strong>")
            elif tag == "emphasis":
                parts.append(f"<em>{self._render_inline(node.children)}</em>")
            elif tag == "strikethrough":
                parts.append(f"<del>{self._render_inline(node.children)}</del>")
            elif tag in ("sub", "sup", "code"):
                parts.append(f"<{tag}>{self._render_inline(node.children)}</{tag}>")
            elif tag == "style":
                css_class = html_escape(node.name or "", quote=True)
                parts.append(
                    f'<span class="{css_class}">{self._render_inline(node.children)}</span>'
                )
            elif tag == "a":
                href = node.href or ""
                if (
                    self.note_links
                    and href.startswith("#")
                    and len(href) > 1
                    and href[1:] in self._note_targets
                ):
                    parts.append(self._render_note_ref(node, href))
                else:
                    escaped = html_escape(href, quote=True)
                    parts.append(
                        f'<a href="{escaped}">{self._render_inline(node.children)}</a>'
                    )
            elif tag == "image":
                src = self._image_src(node.image_href)
                if src:
                    alt = html_escape(node.image_alt or "", quote=True)
                    parts.append(f'<img src="{src}" alt="{alt}"/>')
        return "".join(parts)

    def _render_note_ref(self, node: StyleNode, href: str) -> str:
        """Ссылка на сноску с якорем для обратного перехода.

        Первая ссылка на сноску получает ``id="noteref-<id>"``, повторные —
        ``noteref-<id>-2``, ``-3`` и т. д. (id должны быть уникальны).
        """
        target = href[1:]
        count = self._note_ref_counters.get(target, 0) + 1
        self._note_ref_counters[target] = count
        ref_id = f"noteref-{target}" if count == 1 else f"noteref-{target}-{count}"
        inner = self._render_inline(node.children)
        return (
            f'<a class="note-ref" id="{html_escape(ref_id, quote=True)}"'
            f' href="{html_escape(href, quote=True)}">{inner}</a>'
        )

    def _render_title_html(self, title: Optional[Title]) -> str:
        """Заголовок с inline-разметкой."""
        if title is None:
            return ""
        parts: List[str] = []
        for item in title.items:
            if isinstance(item, Paragraph):
                parts.append(self._render_inline(item.content))
            elif isinstance(item, EmptyLine):
                parts.append(" ")
        return " ".join(p for p in parts if p.strip())

    # --- Изображения -------------------------------------------------------
    def _image_src(self, href: Optional[str]) -> str:
        """Получить src изображения (файл или data-URI)."""
        if not href:
            return ""
        image_id = href[1:] if href.startswith("#") else href
        if self.inline_images:
            return self._image_data_uri(image_id)
        filename = self._image_files.get(image_id, Path(image_id).name)
        src = f"{self.image_dir}/{filename}" if self.image_dir else filename
        return html_escape(src, quote=True)

    def _image_data_uri(self, image_id: str) -> str:
        """Встроить изображение как data-URI (base64)."""
        binary = self._binary_by_id.get(image_id)
        if binary is None:
            return ""
        try:
            data = self.parser.binary_data(binary)
        except (ValueError, TypeError):
            return ""
        encoded = base64.b64encode(data).decode("ascii")
        content_type = binary.content_type or "application/octet-stream"
        return f"data:{content_type};base64,{encoded}"

    # --- Утилиты -----------------------------------------------------------
    def _title_text(self, title: Optional[Title]) -> str:
        """Текст заголовка в одну строку (для оглавления)."""
        if title is None:
            return ""
        parts: List[str] = []
        for item in title.items:
            if isinstance(item, Paragraph):
                parts.append(self._nodes_text(item.content))
        return " ".join(p for p in parts if p)

    @staticmethod
    def _nodes_text(nodes: List[StyleNode]) -> str:
        """Собрать простой текст из списка StyleNode."""
        parts: List[str] = []
        for node in nodes:
            if node.tag == TEXT_NODE:
                parts.append(node.text or "")
            else:
                parts.append(Fb2ToHtmlConverter._nodes_text(node.children))
        return "".join(parts)

    @staticmethod
    def _format_author(author: Author) -> str:
        parts = [author.first_name, author.middle_name, author.last_name]
        return " ".join(p for p in parts if p) or (author.nickname or "—")


__all__ = ["Fb2ToHtmlConverter"]


def main(argv: List[str] | None = None) -> int:
    if argv is None:
        argv = sys.argv
    if len(argv) < 2:
        print(
            "Использование: python fb2_to_html.py <файл.fb2> "
            "[выход.html] [каталог_изображений]",
            file=sys.stderr,
        )
        return 2

    source = argv[1]
    output = argv[2] if len(argv) > 2 else str(Path(source).with_suffix(".html"))
    image_dir = argv[3] if len(argv) > 3 else "images"

    converter = Fb2ToHtmlConverter(image_dir=image_dir, include_toc=True)
    path = converter.write(source, output)

    print("HTML:", path)
    print("Изображений:", len(converter.binaries))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))





