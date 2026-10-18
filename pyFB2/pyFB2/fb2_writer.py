"""Сериализация структур FB2 (FictionBook) в XML FictionBook 2.0.

Модуль предоставляет класс :class:`Fb2Writer`, который принимает готовую
структуру :class:`~fb2_structures.FictionBook` и превращает её в
XML-документ FB2. Используется конвертерами (например,
``epub_to_fb2`` / ``docx_to_fb2``) как общий writer.

Пример::

    >>> from fb2_writer import Fb2Writer
    >>> xml = Fb2Writer().to_xml(book)      # строка XML
    >>> Fb2Writer().write(book, "book.fb2")  # запись в файл
    WindowsPath('book.fb2')
"""

from __future__ import annotations

import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import List, Optional, Union

from .fb2_structures import (
    NS_FB,
    NS_XLINK,
    NS_XML,
    Annotation,
    Author,
    Binary,
    Body,
    Cite,
    Description,
    DocumentInfo,
    EmptyLine,
    Epigraph,
    FictionBook,
    Image,
    Paragraph,
    Poem,
    Section,
    Stanza,
    StyleNode,
    Subtitle,
    Table,
    Title,
    TitleInfo,
)

#: Тег-заглушка для текстовых фрагментов внутри mixed-контента.
TEXT_NODE = "#text"

#: Регистрация пространств имён для корректной сериализации.
ET.register_namespace("", NS_FB)
ET.register_namespace("l", NS_XLINK)
ET.register_namespace("xml", NS_XML)

#: Теги с mixed/inline-контентом: их содержимое НЕ разбивается
#: переводами строк. Иначе закрывающий тег ``</a>`` (и вложенный ``<sup>``)
#: «повисает» на отдельной строке, а внутрь абзаца попадает лишний пробел.
_INLINE_TAGS = frozenset({
    "a",
    "code",
    "emphasis",
    "image",
    "p",
    "strikethrough",
    "strong",
    "style",
    "sub",
    "sup",
    "subtitle",
    "text-author",
    "v",
})


def _local_name(tag: object) -> str:
    """Вернуть локальное имя тега без пространства имён."""
    if not isinstance(tag, str):
        return ""
    return tag.rsplit("}", 1)[-1]


def _indent_element(elem: ET.Element, space: str = "  ", level: int = 0) -> None:
    """Отформатировать *elem* отступами, не трогая inline/mixed-контент.

    В отличие от :func:`xml.etree.ElementTree.indent`, переводы строк НЕ
    вставляются внутрь inline-элементов (``<a>``, ``<sup>``, ``<strong>`` …)
    и элементов, содержащих текст (mixed content). Поэтому ссылка вида
    ``<a l:href="#n_1"><sup>1</sup></a>`` остаётся одной строкой, а не
    «развешивает» закрывающий тег ``</a>`` на отдельной строке.
    """
    if len(elem) == 0:
        return

    if _local_name(elem.tag) in _INLINE_TAGS or (
        elem.text is not None and elem.text.strip()
    ):
        # Inline- или mixed-контент: рекурсия без добавления пробелов.
        for child in elem:
            _indent_element(child, space, level + 1)
        return

    child_indent = "\n" + space * (level + 1)
    for child in elem:
        _indent_element(child, space, level + 1)
        if child.tail is None or not child.tail.strip():
            child.tail = child_indent

    if elem.text is None or not elem.text.strip():
        elem.text = child_indent

    last = elem[-1]
    if last.tail is None or not last.tail.strip():
        last.tail = "\n" + space * level


class Fb2Writer:
    """Сериализация :class:`FictionBook` в XML FB2.

    :param indent: форматировать ли XML отступами (по умолчанию да).
    """

    def __init__(self, indent: bool = True) -> None:
        self.indent = indent

    # --- Публичный API -----------------------------------------------------
    def to_element(self, book: FictionBook) -> ET.Element:
        """Вернуть корневой элемент <FictionBook>."""
        return self._build_root(book)

    def to_xml(self, book: FictionBook) -> str:
        """Сериализовать книгу в строку XML (с декларацией)."""
        root = self._build_root(book)
        if self.indent:
            _indent_element(root, space="  ", level=0)
        xml = ET.tostring(root, encoding="unicode")
        return '<?xml version="1.0" encoding="utf-8"?>\n' + xml

    def write(self, book: FictionBook, path: Union[str, Path]) -> Path:
        """Записать книгу в FB2-файл и вернуть путь."""
        target = Path(path)
        target.write_text(self.to_xml(book), encoding="utf-8")
        return target

    # --- Сериализация в XML ------------------------------------------------
    def _build_root(self, book: FictionBook) -> ET.Element:
        """Собрать корневой элемент <FictionBook>."""
        root = ET.Element(f"{{{NS_FB}}}FictionBook")
        if book.description is not None:
            root.append(self._build_description(book.description))
        for body in book.bodies:
            root.append(self._build_body(body))
        for binary in book.binaries:
            root.append(self._build_binary(binary))
        return root

    def _build_description(self, desc: Description) -> ET.Element:
        """<description> -> <title-info> + <document-info>."""
        elem = ET.Element(f"{{{NS_FB}}}description")
        if desc.title_info is not None:
            elem.append(self._build_title_info(desc.title_info))
        if desc.document_info is not None:
            elem.append(self._build_document_info(desc.document_info))
        return elem

    def _build_title_info(self, ti: TitleInfo) -> ET.Element:
        """<title-info>."""
        elem = ET.Element(f"{{{NS_FB}}}title-info")
        for genre in ti.genres:
            g = ET.SubElement(elem, f"{{{NS_FB}}}genre")
            g.text = genre.value
            if genre.match != 100:
                g.set("match", str(genre.match))
        for author in ti.authors:
            elem.append(self._build_author(author))
        bt = ET.SubElement(elem, f"{{{NS_FB}}}book-title")
        bt.text = ti.book_title.value if ti.book_title else ""
        if ti.annotation is not None:
            elem.append(self._build_annotation(ti.annotation))
        if ti.date is not None:
            d = ET.SubElement(elem, f"{{{NS_FB}}}date")
            d.text = ti.date.value
            if ti.date.date_value:
                d.set("value", ti.date.date_value)
        if ti.coverpage is not None:
            cp = ET.SubElement(elem, f"{{{NS_FB}}}coverpage")
            for image in ti.coverpage.images:
                img = ET.SubElement(cp, f"{{{NS_FB}}}image")
                if image.href:
                    img.set(f"{{{NS_XLINK}}}href", image.href)
                if image.alt:
                    img.set("alt", image.alt)
        lang = ET.SubElement(elem, f"{{{NS_FB}}}lang")
        lang.text = ti.lang or "ru"
        for seq in ti.sequences:
            s = ET.SubElement(elem, f"{{{NS_FB}}}sequence")
            s.set("name", seq.name)
            if seq.number is not None:
                s.set("number", str(seq.number))
        return elem

    def _build_author(self, author: Author) -> ET.Element:
        """<author>."""
        elem = ET.Element(f"{{{NS_FB}}}author")
        if author.first_name:
            fn = ET.SubElement(elem, f"{{{NS_FB}}}first-name")
            fn.text = author.first_name
        if author.middle_name:
            mn = ET.SubElement(elem, f"{{{NS_FB}}}middle-name")
            mn.text = author.middle_name
        if author.last_name:
            ln = ET.SubElement(elem, f"{{{NS_FB}}}last-name")
            ln.text = author.last_name
        if author.nickname:
            nn = ET.SubElement(elem, f"{{{NS_FB}}}nickname")
            nn.text = author.nickname
        if author.id:
            elem.set("id", author.id)
        return elem

    def _build_document_info(self, di: DocumentInfo) -> ET.Element:
        """<document-info>."""
        elem = ET.Element(f"{{{NS_FB}}}document-info")
        for author in di.authors:
            elem.append(self._build_author(author))
        if di.program_used is not None:
            pu = ET.SubElement(elem, f"{{{NS_FB}}}program-used")
            pu.text = di.program_used.value
        if di.date is not None:
            d = ET.SubElement(elem, f"{{{NS_FB}}}date")
            d.text = di.date.value
            if di.date.date_value:
                d.set("value", di.date.date_value)
        if di.id:
            id_elem = ET.SubElement(elem, f"{{{NS_FB}}}id")
            id_elem.text = di.id
        version = ET.SubElement(elem, f"{{{NS_FB}}}version")
        version.text = str(di.version if di.version is not None else 1.0)
        return elem

    def _build_annotation(self, annotation: Annotation) -> ET.Element:
        """<annotation>."""
        elem = ET.Element(f"{{{NS_FB}}}annotation")
        if annotation.id:
            elem.set("id", annotation.id)
        for block in annotation.items:
            built = self._build_block(block)
            if built is not None:
                elem.append(built)
        return elem

    # --- Содержимое книги ---------------------------------------------------
    def _build_body(self, body: Body) -> ET.Element:
        """<body>."""
        elem = ET.Element(f"{{{NS_FB}}}body")
        if body.name:
            elem.set("name", body.name)
        if body.image is not None:
            elem.append(self._build_image(body.image))
        if body.title is not None:
            elem.append(self._build_title(body.title))
        for epigraph in body.epigraphs:
            elem.append(self._build_epigraph(epigraph))
        for section in body.sections:
            elem.append(self._build_section(section))
        return elem

    def _build_section(self, section: Section) -> ET.Element:
        """<section> (рекурсивно).

        По XSD секция содержит либо вложенные ``<section>``, либо контент
        (``p``/``image``/...), но не то и другое одновременно. Поэтому при
        наличии и контента, и подсекций контент оборачивается в анонимную
        вложенную секцию, что сохраняет порядок и валидность схемы.
        """
        elem = ET.Element(f"{{{NS_FB}}}section")
        if section.id:
            elem.set("id", section.id)
        if section.title is not None:
            elem.append(self._build_title(section.title))
        for epigraph in section.epigraphs:
            elem.append(self._build_epigraph(epigraph))
        if section.image is not None:
            elem.append(self._build_image(section.image))
        if section.annotation is not None:
            elem.append(self._build_annotation(section.annotation))

        has_content = bool(section.content)
        has_sections = bool(section.sections)

        if has_content and has_sections:
            wrapper = ET.SubElement(elem, f"{{{NS_FB}}}section")
            for block in section.content:
                built = self._build_block(block)
                if built is not None:
                    wrapper.append(built)
            for child in section.sections:
                elem.append(self._build_section(child))
        else:
            for block in section.content:
                built = self._build_block(block)
                if built is not None:
                    elem.append(built)
            for child in section.sections:
                elem.append(self._build_section(child))
        return elem

    def _build_block(self, block) -> Optional[ET.Element]:
        """Блочный элемент FB2 -> XML (или None)."""
        if isinstance(block, Paragraph):
            return self._build_paragraph(block)
        if isinstance(block, Subtitle):
            return self._build_subtitle(block)
        if isinstance(block, EmptyLine):
            return ET.Element(f"{{{NS_FB}}}empty-line")
        if isinstance(block, Image):
            return self._build_image(block)
        if isinstance(block, Cite):
            return self._build_cite(block)
        if isinstance(block, Table):
            return self._build_table(block)
        if isinstance(block, Poem):
            return self._build_poem(block)
        if isinstance(block, Epigraph):
            return self._build_epigraph(block)
        return None

    def _build_paragraph(self, p: Paragraph) -> ET.Element:
        """<p>."""
        elem = ET.Element(f"{{{NS_FB}}}p")
        if p.id:
            elem.set("id", p.id)
        self._append_style(elem, p.content)
        return elem

    def _build_subtitle(self, s: Subtitle) -> ET.Element:
        """<subtitle>."""
        elem = ET.Element(f"{{{NS_FB}}}subtitle")
        self._append_style(elem, s.content)
        return elem

    def _build_title(self, title: Title) -> ET.Element:
        """<title>."""
        elem = ET.Element(f"{{{NS_FB}}}title")
        for item in title.items:
            if isinstance(item, Paragraph):
                p = ET.SubElement(elem, f"{{{NS_FB}}}p")
                self._append_style(p, item.content)
            elif isinstance(item, EmptyLine):
                ET.SubElement(elem, f"{{{NS_FB}}}empty-line")
        return elem

    def _build_image(self, image: Image) -> ET.Element:
        """<image>."""
        elem = ET.Element(f"{{{NS_FB}}}image")
        if image.href:
            elem.set(f"{{{NS_XLINK}}}href", image.href)
        if image.alt:
            elem.set("alt", image.alt)
        if image.title:
            elem.set("title", image.title)
        return elem

    def _build_cite(self, cite: Cite) -> ET.Element:
        """<cite>."""
        elem = ET.Element(f"{{{NS_FB}}}cite")
        for block in cite.items:
            built = self._build_block(block)
            if built is not None:
                elem.append(built)
        return elem

    def _build_table(self, table: Table) -> ET.Element:
        """<table>."""
        elem = ET.Element(f"{{{NS_FB}}}table")
        for row in table.rows:
            tr = ET.SubElement(elem, f"{{{NS_FB}}}tr")
            for cell in row.cells:
                tag = "th" if cell.is_header else "td"
                td = ET.SubElement(tr, f"{{{NS_FB}}}{tag}")
                if cell.colspan is not None:
                    td.set("colspan", str(cell.colspan))
                if cell.rowspan is not None:
                    td.set("rowspan", str(cell.rowspan))
                self._append_style(td, cell.children)
        return elem

    def _build_poem(self, poem: Poem) -> ET.Element:
        """<poem>."""
        elem = ET.Element(f"{{{NS_FB}}}poem")
        if poem.id:
            elem.set("id", poem.id)
        if poem.lang:
            elem.set(f"{{{NS_XML}}}lang", poem.lang)
        if poem.title is not None:
            elem.append(self._build_title(poem.title))
        for epigraph in poem.epigraphs:
            elem.append(self._build_epigraph(epigraph))
        for item in poem.items:
            if isinstance(item, Subtitle):
                elem.append(self._build_subtitle(item))
            elif isinstance(item, Stanza):
                elem.append(self._build_stanza(item))
        for author in poem.text_author:
            elem.append(self._build_text_author(author))
        if poem.date is not None:
            d = ET.SubElement(elem, f"{{{NS_FB}}}date")
            d.text = poem.date.value
            if poem.date.date_value:
                d.set("value", poem.date.date_value)
        return elem

    def _build_stanza(self, stanza: Stanza) -> ET.Element:
        """<stanza>."""
        elem = ET.Element(f"{{{NS_FB}}}stanza")
        if stanza.lang:
            elem.set(f"{{{NS_XML}}}lang", stanza.lang)
        if stanza.title is not None:
            elem.append(self._build_title(stanza.title))
        if stanza.subtitle is not None:
            elem.append(self._build_subtitle(stanza.subtitle))
        for verse in stanza.verses:
            v = ET.SubElement(elem, f"{{{NS_FB}}}v")
            self._append_style(v, verse.content)
        return elem

    def _build_epigraph(self, epigraph: Epigraph) -> ET.Element:
        """<epigraph>."""
        elem = ET.Element(f"{{{NS_FB}}}epigraph")
        if epigraph.id:
            elem.set("id", epigraph.id)
        for item in epigraph.items:
            built = self._build_block(item)
            if built is not None:
                elem.append(built)
        for author in epigraph.text_author:
            elem.append(self._build_text_author(author))
        return elem

    def _build_text_author(self, author: Paragraph) -> ET.Element:
        """<text-author>."""
        elem = ET.Element(f"{{{NS_FB}}}text-author")
        self._append_style(elem, author.content)
        return elem

    def _build_binary(self, binary: Binary) -> ET.Element:
        """<binary>."""
        elem = ET.Element(f"{{{NS_FB}}}binary")
        elem.set("content-type", binary.content_type)
        elem.set("id", binary.id)
        elem.text = binary.data
        return elem

    def _append_style(self, parent: ET.Element, nodes: List[StyleNode]) -> None:
        """Добавить mixed-содержимое (текст + разметку) в элемент.

        Текст до первого вложенного элемента идёт в ``parent.text``,
        текст между элементами — в ``tail`` предыдущего, сохраняя порядок.
        """
        for node in nodes:
            if node.tag == TEXT_NODE:
                text = node.text or ""
                if not text:
                    continue
                if len(parent):
                    last = parent[-1]
                    last.tail = (last.tail or "") + text
                else:
                    parent.text = (parent.text or "") + text
                continue
            child = self._build_style_node(node)
            if child is not None:
                parent.append(child)

    def _build_style_node(self, node: StyleNode) -> Optional[ET.Element]:
        """Один узел разметки -> XML (или None)."""
        if node.tag == "image":
            elem = ET.Element(f"{{{NS_FB}}}image")
            if node.image_href:
                elem.set(f"{{{NS_XLINK}}}href", node.image_href)
            if node.image_alt:
                elem.set("alt", node.image_alt)
            return elem
        if node.tag == "a":
            elem = ET.Element(f"{{{NS_FB}}}a")
            if node.link_type:
                elem.set("type", node.link_type)
            if node.href:
                elem.set(f"{{{NS_XLINK}}}href", node.href)
            self._append_style(elem, node.children)
            return elem
        if node.tag in ("strong", "emphasis", "style", "strikethrough", "sub", "sup", "code"):
            elem = ET.Element(f"{{{NS_FB}}}{node.tag}")
            if node.tag == "style" and node.name:
                elem.set("name", node.name)
            self._append_style(elem, node.children)
            return elem
        return None


__all__ = ["Fb2Writer", "TEXT_NODE"]


def main(argv: List[str] | None = None) -> int:
    if argv is None:
        argv = sys.argv
    if len(argv) < 2:
        print("Использование: python fb2_writer.py <файл.fb2>", file=sys.stderr)
        return 2
    from .fb2_parser import Fb2Parser

    parser = Fb2Parser(argv[1])
    book = FictionBook(
        description=parser.parse(),
        bodies=parser.parse_bodies(),
        binaries=parser.parse_binaries(),
    )
    print(Fb2Writer().to_xml(book))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))



