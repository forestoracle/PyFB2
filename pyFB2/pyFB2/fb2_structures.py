"""Структуры данных Python для FB2 (FictionBook 2.0).

Файл содержит ТОЛЬКО описания структур (dataclasses / Enum), соответствующие
типам из XSD-схемы FictionBook.xsd. Алгоритмов разбора здесь нет.

Соответствие типам схемы:
    FictionBook                  -> FictionBook
    authorType                   -> Author
    textFieldType                -> TextField
    dateType                     -> DateField
    titleType                    -> Title
    imageType                    -> Image
    inlineImageType              -> InlineImage
    pType                        -> Paragraph
    citeType                     -> Cite
    poemType                     -> Poem
    epigraphType                 -> Epigraph
    annotationType               -> Annotation
    sectionType                  -> Section
    styleType                    -> StyleNode
    namedStyleType               -> NamedStyle
    linkType                     -> Link
    styleLinkType                -> StyleLink
    sequenceType                 -> Sequence
    tableType                    -> Table (+ TableRow, TableCell=tdType)
    title-infoType               -> TitleInfo
    shareInstructionType         -> ShareInstruction
    partShareInstructionType     -> PartShareInstruction
    outPutDocumentType           -> OutputDocument
    alignType / vAlignType       -> Align / VAlign
    shareModesType               -> ShareMode
    docGenerationInstructionType -> DocGenerationInstruction
    genre:genreType              -> GenreType (см. FictionBookGenres.xsd)

Анонимные (встроенные) типы элементов схемы:
    stylesheet, description, document-info, publish-info, custom-info,
    body, binary, genre (с match), coverpage, stanza, tr
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import List, Optional, Union

# ---------------------------------------------------------------------------
# Пространства имён (константы схемы)
# ---------------------------------------------------------------------------
NS_FB = "http://www.gribuser.ru/xml/fictionbook/2.0"
NS_XLINK = "http://www.w3.org/1999/xlink"
NS_XML = "http://www.w3.org/XML/1998/namespace"


# ---------------------------------------------------------------------------
# simpleType-перечисления
# ---------------------------------------------------------------------------
class Align(str, Enum):
    """alignType — выравнивание по горизонтали."""

    LEFT = "left"
    RIGHT = "right"
    CENTER = "center"


class VAlign(str, Enum):
    """vAlignType — выравнивание по вертикали."""

    TOP = "top"
    MIDDLE = "middle"
    BOTTOM = "bottom"


class ShareMode(str, Enum):
    """shareModesType — режим распространения документа."""

    FREE = "free"
    PAID = "paid"


class DocGenerationInstruction(str, Enum):
    """docGenerationInstructionType — инструкция обработки секции."""

    REQUIRE = "require"
    ALLOW = "allow"
    DENY = "deny"


# ---------------------------------------------------------------------------
# Базовые (simpleContent) типы
# ---------------------------------------------------------------------------
@dataclass
class HasLang:
    """Примесь: необязательный атрибут xml:lang (ref="xml:lang")."""

    lang: Optional[str] = None


@dataclass
class TextField(HasLang):
    """textFieldType — xs:string + xml:lang."""

    value: str = ""


@dataclass
class DateField(HasLang):
    """dateType — xs:string + необязательный атрибут value (xs:date) + xml:lang."""

    value: str = ""
    date_value: Optional[str] = None  # атрибут value


# ---------------------------------------------------------------------------
# Автор и серия
# ---------------------------------------------------------------------------
@dataclass
class Author:
    """authorType.

    choice:
      (first-name, middle-name?, last-name, nickname?, home-page*, email*, id?)
      | (nickname, home-page*, email*, id?)
    """

    first_name: Optional[str] = None
    middle_name: Optional[str] = None
    last_name: Optional[str] = None
    nickname: Optional[str] = None
    home_pages: List[str] = field(default_factory=list)  # home-page*
    emails: List[str] = field(default_factory=list)       # email*
    id: Optional[str] = None                              # xs:token


@dataclass
class Sequence:
    """sequenceType — name (обязателен), number?, xml:lang?, вложенные sequence*."""

    name: str = ""
    number: Optional[int] = None
    lang: Optional[str] = None
    sequences: List["Sequence"] = field(default_factory=list)


# ---------------------------------------------------------------------------
# Разметка (styleType и его варианты)
# ---------------------------------------------------------------------------
@dataclass
class StyleNode:
    """styleType (mixed) — узел разметки: strong/emphasis/style/a/... + текст."""

    tag: str                       # локальное имя элемента
    text: str = ""                 # текстовое содержимое узла
    children: List["StyleNode"] = field(default_factory=list)
    href: Optional[str] = None     # для <a> (xlink:href)
    name: Optional[str] = None     # для <style> (name)
    link_type: Optional[str] = None  # для <a type="...">
    image_href: Optional[str] = None  # для inline <image>
    image_alt: Optional[str] = None


@dataclass
class NamedStyle(StyleNode):
    """namedStyleType (mixed) — style с обязательным атрибутом name."""


@dataclass
class Link(StyleNode):
    """linkType (mixed) — <a> с обязательным xlink:href, опциональным type."""


@dataclass
class StyleLink(StyleNode):
    """styleLinkType (mixed) — разметка внутри ссылки."""


# ---------------------------------------------------------------------------
# Таблицы
# ---------------------------------------------------------------------------
@dataclass
class TableCell(StyleNode):
    """tdType (mixed) — ячейка таблицы (td или th)."""

    colspan: Optional[int] = None
    rowspan: Optional[int] = None
    align: Optional[Align] = None
    valign: Optional[VAlign] = None
    style: Optional[str] = None
    id: Optional[str] = None
    is_header: bool = False  # True для <th>, False для <td>


@dataclass
class TableRow:
    """tr — строка таблицы: choice из th/td*, атрибут align."""

    align: Optional[Align] = None
    cells: List[TableCell] = field(default_factory=list)


@dataclass
class Table:
    """tableType — tr+, атрибуты style, id."""

    rows: List[TableRow] = field(default_factory=list)
    style: Optional[str] = None
    id: Optional[str] = None


# ---------------------------------------------------------------------------
# Изображения и бинарные данные
# ---------------------------------------------------------------------------
@dataclass
class InlineImage:
    """inlineImageType — xlink:type?, xlink:href?, alt?."""

    href: Optional[str] = None
    alt: Optional[str] = None
    type: Optional[str] = None


@dataclass
class Image:
    """imageType — xlink:type?, xlink:href?, alt?, title?, id?."""

    href: Optional[str] = None
    alt: Optional[str] = None
    title: Optional[str] = None
    id: Optional[str] = None
    type: Optional[str] = None


@dataclass
class Binary:
    """binary (xs:base64Binary) — content-type (обязателен), id (xs:ID, обязателен)."""

    id: str = ""
    content_type: str = ""
    data: str = ""  # base64-строка


# ---------------------------------------------------------------------------
# Блочные элементы контента
# ---------------------------------------------------------------------------
@dataclass
class Paragraph:
    """pType (mixed) — абзац; id?, style?, xml:lang? + разметка styleType."""

    content: List[StyleNode] = field(default_factory=list)
    id: Optional[str] = None
    style: Optional[str] = None
    lang: Optional[str] = None


@dataclass
class Subtitle:
    """subtitle — использует pType."""

    content: List[StyleNode] = field(default_factory=list)
    id: Optional[str] = None
    style: Optional[str] = None
    lang: Optional[str] = None


@dataclass
class EmptyLine:
    """empty-line — пустой элемент."""


@dataclass
class Title:
    """titleType — choice (p | empty-line)* + xml:lang?."""

    items: List[Union[Paragraph, EmptyLine]] = field(default_factory=list)
    lang: Optional[str] = None


@dataclass
class Epigraph:
    """epigraphType — choice(p|poem|cite|empty-line)*, затем text-author*, id?."""

    items: List[Union[Paragraph, "Poem", "Cite", EmptyLine]] = field(
        default_factory=list
    )
    text_author: List[Paragraph] = field(default_factory=list)
    id: Optional[str] = None


@dataclass
class Stanza:
    """stanza — title?, subtitle?, v+, xml:lang?."""

    title: Optional[Title] = None
    subtitle: Optional[Subtitle] = None
    verses: List[Paragraph] = field(default_factory=list)  # v+
    lang: Optional[str] = None


@dataclass
class Poem:
    """poemType — title?, epigraph*, choice(subtitle|stanza)+, text-author*, date?, id?, lang?."""

    title: Optional[Title] = None
    epigraphs: List[Epigraph] = field(default_factory=list)
    items: List[Union[Subtitle, Stanza]] = field(default_factory=list)
    text_author: List[Paragraph] = field(default_factory=list)
    date: Optional[DateField] = None
    id: Optional[str] = None
    lang: Optional[str] = None


@dataclass
class Cite:
    """citeType — choice(p|poem|empty-line|subtitle|table)*, text-author*, id?, lang?."""

    items: List[Union[Paragraph, Poem, EmptyLine, Subtitle, Table]] = field(
        default_factory=list
    )
    text_author: List[Paragraph] = field(default_factory=list)
    id: Optional[str] = None
    lang: Optional[str] = None


@dataclass
class Annotation:
    """annotationType — choice(p|poem|cite|subtitle|table|empty-line)*, id?, lang?."""

    items: List[Union[Paragraph, Poem, Cite, Subtitle, Table, EmptyLine]] = field(
        default_factory=list
    )
    id: Optional[str] = None
    lang: Optional[str] = None


# ---------------------------------------------------------------------------
# Секции и body
# ---------------------------------------------------------------------------
@dataclass
class Section:
    """sectionType.

    sequence:
      title?, epigraph*, image?, annotation?,
      choice(
        section+ | (choice(p|poem|subtitle|cite|empty-line|table),
                    choice(p|image|poem|subtitle|cite|empty-line|table)*)
      )
    атрибуты: id?, xml:lang?
    """

    title: Optional[Title] = None
    epigraphs: List[Epigraph] = field(default_factory=list)
    image: Optional[Image] = None
    annotation: Optional[Annotation] = None
    sections: List["Section"] = field(default_factory=list)
    content: List[
        Union[Paragraph, Poem, Subtitle, Cite, EmptyLine, Table, Image]
    ] = field(default_factory=list)
    id: Optional[str] = None
    lang: Optional[str] = None
    # Целочисленные идентификаторы заголовков (заполняет Fb2Parser).
    heading_id: Optional[int] = None  # номер этого заголовка (None, если нет <title>)
    parent_id: Optional[int] = None   # номер ближайшего заголовка-предка


@dataclass
class Body:
    """body — image?, title?, epigraph*, section+; атрибуты name?, xml:lang?."""

    image: Optional[Image] = None
    title: Optional[Title] = None
    epigraphs: List[Epigraph] = field(default_factory=list)
    sections: List[Section] = field(default_factory=list)
    name: Optional[str] = None
    lang: Optional[str] = None
    # Целочисленные идентификаторы заголовков (заполняет Fb2Parser).
    heading_id: Optional[int] = None  # номер заголовка body (None, если нет <title>)
    parent_id: Optional[int] = None   # у body всегда None (верхний уровень)


# ---------------------------------------------------------------------------
# Описание книги
# ---------------------------------------------------------------------------
@dataclass
class Genre:
    """genre — genre:genreType + атрибут match (default=100)."""

    value: str = ""       # значение genreType
    match: int = 100


@dataclass
class CoverPage:
    """coverpage — sequence: image+ (inlineImageType)."""

    images: List[InlineImage] = field(default_factory=list)


@dataclass
class TitleInfo:
    """title-infoType.

    sequence: genre+, author+, book-title, annotation?, keywords?, date?,
    coverpage?, lang, src-lang?, translator*, sequence*.
    """

    genres: List[Genre] = field(default_factory=list)
    authors: List[Author] = field(default_factory=list)
    book_title: Optional[TextField] = None
    annotation: Optional[Annotation] = None
    keywords: Optional[TextField] = None
    date: Optional[DateField] = None
    coverpage: Optional[CoverPage] = None
    lang: Optional[str] = None
    src_lang: Optional[str] = None
    translators: List[Author] = field(default_factory=list)
    sequences: List[Sequence] = field(default_factory=list)


@dataclass
class DocumentInfo:
    """document-info.

    sequence: author+, program-used?, date, src-url*, src-ocr?, id,
    version (xs:float), history?, publisher*.
    """

    authors: List[Author] = field(default_factory=list)
    program_used: Optional[TextField] = None
    date: Optional[DateField] = None
    src_urls: List[str] = field(default_factory=list)
    src_ocr: Optional[TextField] = None
    id: Optional[str] = None
    version: Optional[float] = None
    history: Optional[Annotation] = None
    publishers: List[Author] = field(default_factory=list)


@dataclass
class PublishInfo:
    """publish-info.

    sequence: book-name?, publisher?, city?, year?, isbn?, sequence*.
    """

    book_name: Optional[TextField] = None
    publisher: Optional[TextField] = None
    city: Optional[TextField] = None
    year: Optional[str] = None  # xs:gYear
    isbn: Optional[TextField] = None
    sequences: List[Sequence] = field(default_factory=list)


@dataclass
class CustomInfo:
    """custom-info — textFieldType + обязательный атрибут info-type."""

    value: str = ""
    info_type: str = ""


@dataclass
class PartShareInstruction:
    """partShareInstructionType — xlink:type?, xlink:href (обязателен), include (обязателен)."""

    href: Optional[str] = None
    include: Optional[DocGenerationInstruction] = None
    type: Optional[str] = None


@dataclass
class OutputDocument:
    """outPutDocumentType — part*, name (обязателен), create?, price?."""

    name: str = ""
    create: Optional[DocGenerationInstruction] = None
    price: Optional[float] = None
    parts: List[PartShareInstruction] = field(default_factory=list)


@dataclass
class ShareInstruction:
    """shareInstructionType.

    choice(part | output-document-class)*;
    атрибуты: mode (обязателен), include-all (обязателен), price?, currency?.
    """

    mode: ShareMode = ShareMode.FREE
    include_all: DocGenerationInstruction = DocGenerationInstruction.ALLOW
    price: Optional[float] = None
    currency: Optional[str] = None
    parts: List[PartShareInstruction] = field(default_factory=list)
    output_documents: List[OutputDocument] = field(default_factory=list)


@dataclass
class Description:
    """description.

    sequence: title-info, src-title-info?, document-info, publish-info?,
    custom-info*, output* (maxOccurs=2).
    """

    title_info: Optional[TitleInfo] = None
    src_title_info: Optional[TitleInfo] = None
    document_info: Optional[DocumentInfo] = None
    publish_info: Optional[PublishInfo] = None
    custom_infos: List[CustomInfo] = field(default_factory=list)
    outputs: List[ShareInstruction] = field(default_factory=list)


@dataclass
class Stylesheet:
    """stylesheet — xs:string + обязательный атрибут type."""

    type: str = ""
    value: str = ""


@dataclass
class FictionBook:
    """FictionBook — корневой элемент.

    sequence: stylesheet*, description, body+, binary*.
    """

    stylesheets: List[Stylesheet] = field(default_factory=list)
    description: Optional[Description] = None
    bodies: List[Body] = field(default_factory=list)
    binaries: List[Binary] = field(default_factory=list)


__all__ = [
    # Перечисления
    "Align",
    "VAlign",
    "ShareMode",
    "DocGenerationInstruction",
    # Базовые
    "HasLang",
    "TextField",
    "DateField",
    # Автор/серия
    "Author",
    "Sequence",
    # Разметка
    "StyleNode",
    "NamedStyle",
    "Link",
    "StyleLink",
    # Таблицы
    "TableCell",
    "TableRow",
    "Table",
    # Изображения
    "InlineImage",
    "Image",
    "Binary",
    # Блоки контента
    "Paragraph",
    "Subtitle",
    "EmptyLine",
    "Title",
    "Epigraph",
    "Stanza",
    "Poem",
    "Cite",
    "Annotation",
    # Секции/body
    "Section",
    "Body",
    # Описание
    "Genre",
    "CoverPage",
    "TitleInfo",
    "DocumentInfo",
    "PublishInfo",
    "CustomInfo",
    "PartShareInstruction",
    "OutputDocument",
    "ShareInstruction",
    "Description",
    "Stylesheet",
    "FictionBook",
    # Пространства имён
    "NS_FB",
    "NS_XLINK",
    "NS_XML",
]