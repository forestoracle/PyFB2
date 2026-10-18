# -*- coding: utf-8 -*-
"""Преобразование FictionBook 3 (FB3) в книгу FB2.

Модуль читает OPC-контейнер FB3 (ZIP): ``fb3/description.xml`` (метаданные),
``fb3/body.xml`` (текст), связи ``*_rels/*.rels`` (тело и изображения) и
собирает структуру :class:`~fb2_structures.FictionBook`.

Обратное преобразование к :mod:`fb2_to_fb3`. Внешних зависимостей нет.

Пример:
    >>> from fb3_to_fb2 import Fb3ToFb2Converter
    >>> Fb3ToFb2Converter().write("book.fb3", "book.fb2")
    WindowsPath('book.fb2')

CLI:
    python fb3_to_fb2.py book.fb3 [book.fb2]
"""

from __future__ import annotations

import base64
import io
import sys
import uuid
import zipfile
from datetime import date
from pathlib import Path
from typing import Dict, FrozenSet, List, Optional, Union

import xml.etree.ElementTree as ET

from .fb2_errors import Fb2ConversionError
from .fb2_images import detect_image_type
from .fb2_parser import TEXT_NODE
from .fb2_structures import (
    Annotation,
    Author,
    Binary,
    Body,
    Cite,
    CoverPage,
    DateField,
    Description,
    DocumentInfo,
    EmptyLine,
    Epigraph,
    FictionBook,
    Genre,
    Image,
    InlineImage,
    Paragraph,
    Poem,
    Section,
    Stanza,
    StyleNode,
    Subtitle,
    Table,
    TableCell,
    TableRow,
    TextField,
    Title,
    TitleInfo,
)
from .fb2_writer import Fb2Writer
from .fb2_xml import parse_xml

#: Пространства имён FB3.
NS_DESCR = "http://www.fictionbook.org/FictionBook3/description"
NS_BODY = "http://www.fictionbook.org/FictionBook3/body"
NS_XLINK = "http://www.w3.org/1999/xlink"
NS_RELS = "http://schemas.openxmlformats.org/package/2006/relationships"

#: Типы связей FB3.
REL_BOOK = "http://www.fictionbook.org/FictionBook3/relationships/Book"
REL_BODY = "http://www.fictionbook.org/FictionBook3/relationships/body"
REL_IMAGE = "http://www.fictionbook.org/FictionBook3/relationships/image"
REL_THUMBNAIL = (
    "http://schemas.openxmlformats.org/package/2006/relationships/metadata/thumbnail"
)

#: Inline-теги FB3 -> теги разметки FB2.
MARKUP_TAGS = {
    "strong": "strong",
    "em": "emphasis",
    "code": "code",
    "strikethrough": "strikethrough",
    "sub": "sub",
    "sup": "sup",
}

#: Пути частей по умолчанию (если связи не указаны).
DEFAULT_DESCRIPTION = "fb3/description.xml"
DEFAULT_BODY = "fb3/body.xml"

#: Блоки, допустимые внутри ``<annotation>`` FB2.
AnnotationBlock = Union[Paragraph, Poem, Cite, Subtitle, Table, EmptyLine]

#: Блоки содержимого секции FB2.
BodyBlock = Union[Paragraph, Poem, Subtitle, Cite, EmptyLine, Table, Image]

#: Заголовок FB2 состоит из абзацев и пустых строк.
TitleItem = Union[Paragraph, EmptyLine]


class Fb3ToFb2Converter:
    """Преобразование FB3 в FB2.

    :param writer: готовый :class:`~fb2_writer.Fb2Writer`.
    :param default_genre: жанр, если в описании он не указан.
    :param program_used: значение ``<program-used>`` в ``<document-info>``.
    """

    def __init__(
        self,
        writer: Optional[Fb2Writer] = None,
        default_genre: str = "sf",
        program_used: str = "pyFB2",
    ) -> None:
        self.writer = writer if writer is not None else Fb2Writer()
        self.default_genre = default_genre
        self.program_used = program_used
        self.source: Optional[Union[str, Path, bytes]] = None
        self._book: Optional[FictionBook] = None
        self._reset()

    def _reset(self) -> None:
        """Очистить состояние для нового преобразования."""
        self._zip: Optional[zipfile.ZipFile] = None
        self._images: Dict[str, str] = {}       # rel_id -> путь в архиве
        self._binaries: List[Binary] = []
        self._binary_ids: Dict[str, str] = {}   # путь -> id в FB2
        self._cover_id: Optional[str] = None

    # --- Публичный API -----------------------------------------------------
    @property
    def book(self) -> Optional[FictionBook]:
        """Последняя собранная структура :class:`FictionBook` (или None)."""
        return self._book

    def convert(
        self, source: Optional[Union[str, Path, bytes]] = None
    ) -> FictionBook:
        """Прочитать FB3 и вернуть структуру :class:`FictionBook`.

        :param source: путь или байты FB3 (иначе берётся ``self.source``).
        """
        if source is not None:
            self.source = source
        if self.source is None:
            raise Fb2ConversionError("Не задан источник FB3 (source)")

        self._reset()
        self._zip = self._open_zip(self.source)
        try:
            description_path = self._find_part("_rels/.rels", REL_BOOK, DEFAULT_DESCRIPTION)
            body_path = self._find_part(
                "fb3/_rels/description.xml.rels", REL_BODY, DEFAULT_BODY
            )
            self._load_images(body_path)
            self._load_cover()
            meta = self._read_description(description_path)
            body = self._convert_body(self._read_part(body_path))
            self._book = self._assemble(meta, body)
            return self._book
        finally:
            self._zip.close()
            self._zip = None

    def to_xml(self, book: Optional[FictionBook] = None) -> str:
        """Сериализовать книгу (или результат :meth:`convert`) в XML FB2."""
        if book is None:
            book = self._book
        if book is None:
            book = self.convert()
        return self.writer.to_xml(book)

    def write(
        self,
        source: Optional[Union[str, Path, bytes]] = None,
        output: Optional[Union[str, Path]] = None,
    ) -> Path:
        """Преобразовать FB3 в файл FB2 и вернуть путь к результату.

        :param source: путь/байты FB3 (иначе ``self.source``).
        :param output: путь к ``.fb2``; по умолчанию — рядом с исходным ``.fb3``.
        """
        book = self.convert(source)
        xml = self.to_xml(book)

        if output is None:
            src = source if source is not None else self.source
            output = (
                Path(src).with_suffix(".fb2")
                if isinstance(src, (str, Path))
                else Path("book.fb2")
            )
        output = Path(output)
        output.write_text(xml, encoding="utf-8")
        return output

    # --- Чтение контейнера -------------------------------------------------
    @staticmethod
    def _open_zip(source: Union[str, Path, bytes]) -> zipfile.ZipFile:
        """Открыть FB3 как ZIP (из пути или байтов)."""
        if isinstance(source, bytes):
            return zipfile.ZipFile(io.BytesIO(source))
        return zipfile.ZipFile(source)

    def _read_zip(self, name: str) -> Optional[bytes]:
        """Прочитать часть архива (None, если её нет)."""
        if self._zip is None:
            return None
        try:
            return self._zip.read(name)
        except KeyError:
            return None

    def _read_part(self, name: str) -> ET.Element:
        """Разобрать XML-часть контейнера."""
        data = self._read_zip(name)
        if data is None:
            raise Fb2ConversionError(f"В FB3 не найдена часть: {name}")
        try:
            return parse_xml(data)
        except ET.ParseError as exc:
            raise Fb2ConversionError(f"Не удалось разобрать {name}") from exc

    @staticmethod
    def _local(tag: str) -> str:
        """Локальное имя тега: '{ns}p' -> 'p'."""
        return tag.rsplit("}", 1)[-1] if "}" in tag else tag

    @staticmethod
    def _resolve_target(rels_path: str, target: str) -> str:
        """Привести ``Target`` из ``.rels`` к пути внутри архива."""
        if rels_path == "_rels/.rels":
            return target.lstrip("/")
        base = rels_path.rsplit("/_rels/", 1)[0]
        return f"{base}/{target}".lstrip("/")

    def _find_part(self, rels_path: str, rel_type: str, default: str) -> str:
        """Найти часть контейнера по типу связи в ``*.rels``."""
        data = self._read_zip(rels_path)
        if data is None:
            return default
        try:
            root = parse_xml(data)
        except ET.ParseError:
            return default
        for relationship in root:
            if self._local(relationship.tag) != "Relationship":
                continue
            if relationship.get("Type") != rel_type:
                continue
            target = relationship.get("Target") or ""
            if target:
                return self._resolve_target(rels_path, target)
        return default

    def _load_images(self, body_path: str) -> None:
        """Прочитать связи изображений тела (``Id`` -> путь в архиве)."""
        if "/" in body_path:
            folder, name = body_path.rsplit("/", 1)
            rels_path = f"{folder}/_rels/{name}.rels"
            base = folder
        else:
            rels_path = f"_rels/{body_path}.rels"
            base = ""
        data = self._read_zip(rels_path)
        if data is None:
            return
        try:
            root = parse_xml(data)
        except ET.ParseError:
            return
        for relationship in root:
            if self._local(relationship.tag) != "Relationship":
                continue
            rel_id = relationship.get("Id")
            target = relationship.get("Target") or ""
            if not rel_id or not target:
                continue
            rel_type = relationship.get("Type") or ""
            if rel_type and rel_type != REL_IMAGE:
                continue
            if not target.lower().endswith((".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp")):
                continue
            self._images[rel_id] = f"{base}/{target}".lstrip("/") if base else target

    def _load_cover(self) -> None:
        """Зарегистрировать обложку из связи-thumbnail пакета."""
        cover_path = self._find_part("_rels/.rels", REL_THUMBNAIL, "")
        if not cover_path:
            return
        self._images["__cover__"] = cover_path
        self._cover_id = self._register_binary("__cover__")

    # --- Метаданные --------------------------------------------------------
    def _read_description(self, path: str) -> Dict[str, object]:
        """Прочитать метаданные из ``fb3-description``."""
        root = self._read_part(path)
        meta: Dict[str, object] = {}
        authors: List[Dict[str, str]] = []
        genres: List[str] = []
        annotation: List[str] = []

        for child in root:
            local = self._local(child.tag)
            if local == "title":
                text = self._child_text(child, "main")
                if text:
                    meta["title"] = text
            elif local == "fb3-relations":
                for subject in child:
                    if self._local(subject.tag) != "subject":
                        continue
                    if (subject.get("link") or "") != "author":
                        continue
                    authors.append(self._subject_parts(subject))
            elif local == "fb3-classification":
                for item in child:
                    if self._local(item.tag) != "subject":
                        continue
                    text = (item.text or "").strip()
                    if text:
                        genres.append(text)
            elif local == "lang":
                text = (child.text or "").strip()
                if text:
                    meta["language"] = text
            elif local == "annotation":
                for item in child:
                    if self._local(item.tag) != "p":
                        continue
                    text = self._nodes_text(self._inline_nodes(item, frozenset()))
                    if text:
                        annotation.append(text)

        if authors:
            meta["authors"] = authors
        if genres:
            meta["genres"] = genres
        if annotation:
            meta["annotation"] = annotation
        return meta

    @staticmethod
    def _child_text(parent: ET.Element, name: str) -> str:
        """Текст дочернего элемента по локальному имени."""
        for child in parent:
            if Fb3ToFb2Converter._local(child.tag) == name:
                return (child.text or "").strip()
        return ""

    @staticmethod
    def _subject_parts(subject: ET.Element) -> Dict[str, str]:
        """Поля субъекта-автора (first/middle/last/main)."""
        parts = {"first": "", "middle": "", "last": "", "main": ""}
        for child in subject:
            local = Fb3ToFb2Converter._local(child.tag)
            text = (child.text or "").strip()
            if local == "first-name":
                parts["first"] = text
            elif local == "middle-name":
                parts["middle"] = text
            elif local == "last-name":
                parts["last"] = text
            elif local == "title":
                parts["main"] = Fb3ToFb2Converter._child_text(child, "main")
        return parts

    # --- Изображения -------------------------------------------------------
    def _register_binary(self, rel_id: str) -> Optional[str]:
        """Прочитать изображение по связи и зарегистрировать ``<binary>``."""
        path = self._images.get(rel_id)
        if path is None:
            return None
        if path in self._binary_ids:
            return self._binary_ids[path]
        data = self._read_zip(path)
        if data is None:
            return None
        media_type, extension = detect_image_type(data)
        binary_id = f"{Path(path).stem or 'image'}{extension}"
        self._binary_ids[path] = binary_id
        self._binaries.append(
            Binary(
                id=binary_id,
                content_type=media_type,
                data=base64.b64encode(data).decode("ascii"),
            )
        )
        return binary_id

    # --- Тело --------------------------------------------------------------
    def _convert_body(self, root: ET.Element) -> Body:
        """Преобразовать ``<fb3-body>`` в структуру Body."""
        body = Body()
        loose: List[BodyBlock] = []
        for child in root:
            local = self._local(child.tag)
            if local == "title":
                body.title = self._title_node(child)
            elif local == "epigraph":
                body.epigraphs.append(self._epigraph_node(child))
            elif local == "section":
                body.sections.append(self._convert_section(child))
            else:
                block = self._convert_block(child)
                if block is not None:
                    loose.append(block)
        if loose:
            body.sections.insert(0, Section(content=loose))
        if not body.sections:
            body.sections = [Section()]
        return body

    def _convert_section(self, elem: ET.Element) -> Section:
        """Преобразовать ``<section>`` (рекурсивно)."""
        section = Section()
        for child in elem:
            local = self._local(child.tag)
            if local == "title":
                section.title = self._title_node(child)
            elif local == "epigraph":
                section.epigraphs.append(self._epigraph_node(child))
            elif local == "annotation":
                section.annotation = self._annotation_node(child)
            elif local == "section":
                section.sections.append(self._convert_section(child))
            else:
                block = self._convert_block(child)
                if block is not None:
                    section.content.append(block)
        return section

    def _title_node(self, elem: ET.Element) -> Optional[Title]:
        """``<title><p>...</p></title>`` -> :class:`Title`."""
        items: List[TitleItem] = [
            Paragraph(content=self._inline_nodes(child, frozenset()))
            for child in elem
            if self._local(child.tag) == "p"
        ]
        items = [
            item for item in items if not isinstance(item, Paragraph) or item.content
        ]
        return Title(items=items) if items else None

    def _epigraph_node(self, elem: ET.Element) -> Epigraph:
        """``<epigraph>`` -> :class:`Epigraph` с подписью."""
        epigraph = Epigraph()
        for child in elem:
            if self._local(child.tag) == "subscription":
                for paragraph in child:
                    if self._local(paragraph.tag) == "p":
                        nodes = self._inline_nodes(paragraph, frozenset())
                        if nodes:
                            epigraph.text_author.append(Paragraph(content=nodes))
                continue
            block = self._convert_block(child)
            if isinstance(block, (Paragraph, Poem, Cite, EmptyLine)):
                epigraph.items.append(block)
        return epigraph

    def _annotation_node(self, elem: ET.Element) -> Annotation:
        """``<annotation>`` -> :class:`Annotation`."""
        annotation = Annotation()
        for child in elem:
            block = self._convert_block(child)
            if isinstance(block, (Paragraph, Poem, Cite, Subtitle, Table, EmptyLine)):
                annotation.items.append(block)
        return annotation

    def _convert_block(self, elem: ET.Element):
        """Преобразовать блочный элемент FB3 в блок FB2."""
        local = self._local(elem.tag)
        if local == "p":
            images = self._block_images(elem)
            nodes = self._inline_nodes(elem, frozenset())
            if images and not self._nodes_text(nodes):
                return images[0]
            return Paragraph(content=nodes) if nodes else None
        if local == "br":
            return EmptyLine()
        if local == "poem":
            return self._poem_node(elem)
        if local == "blockquote":
            return self._cite_node(elem)
        if local == "table":
            return self._table_node(elem)
        if local == "img":
            binary_id = self._register_binary(elem.get("src") or "")
            return Image(href=f"#{binary_id}") if binary_id else None
        return None

    def _poem_node(self, elem: ET.Element) -> Poem:
        """``<poem>`` -> :class:`Poem` со строфами."""
        poem = Poem()
        for child in elem:
            local = self._local(child.tag)
            if local == "title":
                poem.title = self._title_node(child)
            elif local == "epigraph":
                poem.epigraphs.append(self._epigraph_node(child))
            elif local == "stanza":
                poem.items.append(self._stanza_node(child))
            elif local == "subscription":
                self._collect_subscription(child, poem.text_author)
            elif local == "p":
                nodes = self._inline_nodes(child, frozenset())
                if nodes:
                    poem.items.append(Subtitle(content=nodes))
        return poem

    def _stanza_node(self, elem: ET.Element) -> Stanza:
        """``<stanza>`` -> :class:`Stanza` (строки стихотворения)."""
        stanza = Stanza()
        for child in elem:
            local = self._local(child.tag)
            if local == "title":
                title = self._title_node(child)
                if title is not None and title.items:
                    first = title.items[0]
                    if isinstance(first, Paragraph):
                        stanza.subtitle = Subtitle(content=first.content)
            elif local == "p":
                nodes = self._inline_nodes(child, frozenset())
                if nodes:
                    stanza.verses.append(Paragraph(content=nodes))
        return stanza

    def _cite_node(self, elem: ET.Element) -> Cite:
        """``<blockquote>`` -> :class:`Cite`."""
        cite = Cite()
        for child in elem:
            if self._local(child.tag) == "subscription":
                self._collect_subscription(child, cite.text_author)
                continue
            block = self._convert_block(child)
            if block is not None:
                cite.items.append(block)
        return cite

    @staticmethod
    def _collect_subscription(elem: ET.Element, target: List[Paragraph]) -> None:
        """Собрать подписи (``<subscription>``) в ``text-author``."""
        for paragraph in elem:
            if Fb3ToFb2Converter._local(paragraph.tag) != "p":
                continue
            text = "".join(
                node.text or "" for node in paragraph.iter() if node.text
            ).strip()
            if text:
                target.append(
                    Paragraph(content=[StyleNode(tag=TEXT_NODE, text=text)])
                )

    def _table_node(self, elem: ET.Element) -> Optional[Table]:
        """``<table>`` -> :class:`Table`."""
        table = Table()
        for row_elem in elem:
            if self._local(row_elem.tag) != "tr":
                continue
            row = TableRow()
            for cell_elem in row_elem:
                local = self._local(cell_elem.tag)
                if local not in ("th", "td"):
                    continue
                nodes: List[StyleNode] = []
                for paragraph in cell_elem:
                    if self._local(paragraph.tag) == "p":
                        nodes.extend(self._inline_nodes(paragraph, frozenset()))
                row.cells.append(
                    TableCell(tag=local, children=nodes, is_header=local == "th")
                )
            table.rows.append(row)
        return table if table.rows else None

    # --- Разметка ----------------------------------------------------------
    def _inline_nodes(
        self, elem: ET.Element, flags: FrozenSet[str]
    ) -> List[StyleNode]:
        """Собрать узлы разметки FB3 в узлы разметки FB2."""
        nodes: List[StyleNode] = []
        if elem.text and elem.text.strip():
            nodes.append(StyleNode(tag=TEXT_NODE, text=elem.text))

        for child in elem:
            local = self._local(child.tag)
            if local == "img":
                binary_id = self._register_binary(child.get("src") or "")
                if binary_id:
                    nodes.append(
                        StyleNode(tag="image", image_href=f"#{binary_id}")
                    )
            elif local == "a":
                nodes.append(
                    StyleNode(
                        tag="a",
                        children=self._inline_nodes(child, flags),
                        href=child.get(f"{{{NS_XLINK}}}href"),
                    )
                )
            elif local in MARKUP_TAGS:
                nodes.append(
                    StyleNode(
                        tag=MARKUP_TAGS[local],
                        children=self._inline_nodes(child, flags),
                    )
                )
            elif local == "span":
                nodes.append(
                    StyleNode(
                        tag="style",
                        name=child.get("class"),
                        children=self._inline_nodes(child, flags),
                    )
                )
            elif local == "subscription":
                continue
            else:
                nodes.extend(self._inline_nodes(child, flags))

            if child.tail and child.tail.strip():
                nodes.append(StyleNode(tag=TEXT_NODE, text=child.tail))
        return nodes

    def _block_images(self, elem: ET.Element) -> List[Image]:
        """Прямые ``<img>`` внутри абзаца (блочные картинки)."""
        images: List[Image] = []
        for child in elem:
            if self._local(child.tag) != "img":
                continue
            binary_id = self._register_binary(child.get("src") or "")
            if binary_id:
                images.append(Image(href=f"#{binary_id}"))
        return images

    @staticmethod
    def _nodes_text(nodes: List[StyleNode]) -> str:
        """Простой текст из узлов разметки."""
        parts: List[str] = []
        for node in nodes:
            if node.tag == TEXT_NODE:
                parts.append(node.text or "")
            else:
                parts.append(Fb3ToFb2Converter._nodes_text(node.children))
        return "".join(parts).strip()

    # --- Сборка FictionBook ------------------------------------------------
    def _author_entries(self, meta: Dict[str, object]) -> List[Dict[str, str]]:
        """Записи авторов из метаданных."""
        entries = meta.get("authors")
        if not isinstance(entries, list):
            return []
        return [entry for entry in entries if isinstance(entry, dict)]

    def _genres(self, meta: Dict[str, object]) -> List[str]:
        """Жанры FB2: только коды без пробелов (иначе ``default_genre``)."""
        genres = meta.get("genres")
        codes: List[str] = []
        if isinstance(genres, list):
            codes = [
                str(genre).strip()
                for genre in genres
                if str(genre).strip() and " " not in str(genre).strip()
            ]
        return codes or [self.default_genre]

    @staticmethod
    def _author(entry: Dict[str, str]) -> Author:
        """Автор из полей субъекта FB3."""
        if entry.get("last") or entry.get("first"):
            return Author(
                first_name=entry.get("first") or None,
                middle_name=entry.get("middle") or None,
                last_name=entry.get("last") or None,
            )
        main = (entry.get("main") or "").strip()
        if not main:
            return Author(nickname="Неизвестный автор")
        parts = main.split()
        if len(parts) == 1:
            return Author(last_name=parts[0])
        if len(parts) == 2:
            return Author(first_name=parts[0], last_name=parts[1])
        return Author(
            first_name=parts[0],
            middle_name=" ".join(parts[1:-1]),
            last_name=parts[-1],
        )

    @staticmethod
    def _annotation(meta: Dict[str, object]) -> Optional[Annotation]:
        """Аннотация из ``<annotation>`` описания."""
        texts = meta.get("annotation")
        if not isinstance(texts, list) or not texts:
            return None
        items: List[AnnotationBlock] = [
            Paragraph(content=[StyleNode(tag=TEXT_NODE, text=str(text))])
            for text in texts
            if str(text).strip()
        ]
        return Annotation(items=items) if items else None

    def _assemble(self, meta: Dict[str, object], body: Body) -> FictionBook:
        """Собрать корневую структуру FictionBook."""
        title = str(meta.get("title") or "Untitled")
        authors = [self._author(entry) for entry in self._author_entries(meta)]
        coverpage = (
            CoverPage(images=[InlineImage(href=f"#{self._cover_id}")])
            if self._cover_id
            else None
        )

        title_info = TitleInfo(
            genres=[Genre(value=genre) for genre in self._genres(meta)],
            authors=authors,
            book_title=TextField(value=title),
            annotation=self._annotation(meta),
            coverpage=coverpage,
            lang=str(meta.get("language") or "ru"),
        )
        document_info = DocumentInfo(
            authors=[Author(nickname="pyFB2")],
            program_used=TextField(value=self.program_used),
            date=DateField(value=date.today().isoformat()),
            id=uuid.uuid4().hex,
            version=1.0,
        )
        return FictionBook(
            description=Description(
                title_info=title_info,
                document_info=document_info,
            ),
            bodies=[body],
            binaries=self._binaries,
        )


__all__ = ["Fb3ToFb2Converter"]


def main(argv: List[str] | None = None) -> int:
    if argv is None:
        argv = sys.argv
    if len(argv) < 2:
        print(
            "Использование: python fb3_to_fb2.py <файл.fb3> [выход.fb2]",
            file=sys.stderr,
        )
        return 2
    source = argv[1]
    output = argv[2] if len(argv) > 2 else str(Path(source).with_suffix(".fb2"))
    converter = Fb3ToFb2Converter()
    path = converter.write(source, output)
    print("FB2:", path)
    if converter.book is not None:
        print("Изображений:", len(converter.book.binaries))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
