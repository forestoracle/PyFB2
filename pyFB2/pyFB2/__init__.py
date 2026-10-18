"""pyFB2 — обработка книг FB2 (FictionBook 2.0).

Пакет предоставляет разбор, сериализацию, валидацию по XSD, нормализацию
(авто-исправление), разбиение/слияние книг, скачивание обложек и аннотаций,
индекс библиотеки, упаковку книг в ZIP-архивы (``.fb2.zip``) и обратную
распаковку, а также двустороннюю конвертацию FB2 с форматами EPUB, DOCX, ODT,
MOBI, FB3, Markdown и HTML и экспорт в TXT и PDF.

Пример::

    from pyFB2 import Fb2Parser, Fb2Writer, Fb2ToEpubConverter

    parser = Fb2Parser("book.fb2")
    book = parser.parse()
    print(book.title_info.book_title.value)

    Fb2ToEpubConverter().write("book.fb2", "book.epub")
"""

from __future__ import annotations

import logging
from typing import TYPE_CHECKING

__version__ = "0.1.2"

# --- Исключения -------------------------------------------------------------
from .fb2_errors import (
    Fb2ConversionError,
    Fb2Error,
    Fb2NetworkError,
    Fb2NotFoundError,
    Fb2OperationError,
    Fb2ParseError,
    Fb2ValidationError,
)

# --- Структуры данных FB2 ---------------------------------------------------
from .fb2_structures import (
    NS_FB,
    NS_XLINK,
    NS_XML,
    Align,
    Annotation,
    Author,
    Binary,
    Body,
    Cite,
    CoverPage,
    CustomInfo,
    DateField,
    Description,
    DocGenerationInstruction,
    DocumentInfo,
    EmptyLine,
    Epigraph,
    FictionBook,
    Genre,
    Image,
    InlineImage,
    Link,
    NamedStyle,
    Paragraph,
    Poem,
    PublishInfo,
    Section,
    Sequence,
    ShareMode,
    Stanza,
    StyleNode,
    Stylesheet,
    Subtitle,
    Table,
    TableCell,
    TableRow,
    TextField,
    Title,
    TitleInfo,
    VAlign,
)

# --- Ядро: разбор и запись --------------------------------------------------
from .fb2_parser import Fb2Parser
from .fb2_writer import TEXT_NODE, Fb2Writer
from .fb2_xml import Fb2XmlError, parse_xml, parse_xml_text

# --- Валидация (требует lxml) ----------------------------------------------
from .fb2_validator import Fb2Validator, ValidationError, ValidationResult

# --- Утилиты и индекс -------------------------------------------------------
from .fb2_index import Fb2Index
from .fb2_transcoder import Fb2Transcoder, TranscodeResult
from .fb2_unzip import FB2Unzip, Fb2UnzipResult
from .fb2_zip import FB2Zip, Fb2ZipResult
from .fb2_renamer import FB2Renamer
from .fb2_group_renamer import FB2GroupRenamer
from .fb2_normalizer import Fb2Normalizer, NormalizationFix, NormalizationResult
from .fb2_rewrite import Fb2Rewriter, RewriteResult
from .fb2_split_merge import Fb2Merger, Fb2Splitter
from .fb2_web_metadata import BookMetadata, Fb2MetadataFetcher
from .fb2_author_scanner import Fb2AuthorScanner
from .fb2_encoding_scanner import Fb2EncodingScanner, detect_encoding

# --- Конвертеры -------------------------------------------------------------
from .epub_to_fb2 import EpubToFb2Converter
from .fb2_to_epub import EpubBook, EpubDocument, EpubResource, Fb2ToEpubConverter
from .fb2_to_docx import DocxBook, DocxImage, Fb2ToDocxConverter
from .docx_to_fb2 import DocxToFb2Converter
from .fb2_to_markdown import Fb2MarkdownWriter, Fb2ToMarkdownConverter
from .markdown_to_fb2 import MarkdownToFb2Converter
from .fb2_to_html import Fb2ToHtmlConverter
from .html_to_fb2 import HtmlToFb2Converter
from .fb2_to_txt import Fb2ToTxtConverter
from .fb2_to_odt import OdtBook, OdtImage, Fb2ToOdtConverter
from .odt_to_fb2 import OdtToFb2Converter
from .fb2_to_mobi import MobiBook, MobiImage, Fb2ToMobiConverter
from .mobi_to_fb2 import MobiHeader, MobiToFb2Converter
from .fb2_to_fb3 import Fb3Document, Fb3Image, Fb2ToFb3Converter
from .fb3_to_fb2 import Fb3ToFb2Converter


__all__ = [
    # --- метаданные пакета ---
    "__version__",
    # --- исключения ---
    "Fb2Error", "Fb2ParseError", "Fb2ValidationError", "Fb2ConversionError",
    "Fb2OperationError", "Fb2NotFoundError", "Fb2NetworkError", "Fb2XmlError",
    # --- структуры FB2 ---
    "NS_FB", "NS_XLINK", "NS_XML",
    "Align", "VAlign", "ShareMode", "DocGenerationInstruction",
    "TextField", "DateField", "Author", "Sequence",
    "StyleNode", "NamedStyle", "Link",
    "TableCell", "TableRow", "Table",
    "InlineImage", "Image", "Binary",
    "Paragraph", "Subtitle", "EmptyLine", "Title", "Epigraph", "Stanza", "Poem",
    "Cite", "Annotation", "Section", "Body",
    "Genre", "CoverPage", "TitleInfo", "DocumentInfo", "PublishInfo", "CustomInfo",
    "Description", "Stylesheet", "FictionBook",
    # --- ядро ---
    "Fb2Parser", "Fb2Writer", "TEXT_NODE",
    "parse_xml", "parse_xml_text", "Fb2XmlError",
    # --- валидация ---
    "Fb2Validator", "ValidationResult", "ValidationError",
    # --- утилиты и индекс ---
    "Fb2Index", "Fb2Transcoder", "TranscodeResult",
    "FB2Zip", "Fb2ZipResult", "FB2Unzip", "Fb2UnzipResult",
    "FB2Renamer", "FB2GroupRenamer",
    "Fb2Normalizer", "NormalizationResult", "NormalizationFix",
    "Fb2Rewriter", "RewriteResult",
    "Fb2Splitter", "Fb2Merger",
    "Fb2MetadataFetcher", "BookMetadata",
    "Fb2AuthorScanner", "Fb2EncodingScanner", "detect_encoding",
    # --- конвертеры ---
    "EpubToFb2Converter",
    "Fb2ToEpubConverter", "EpubBook", "EpubDocument", "EpubResource",
    "Fb2ToDocxConverter", "DocxBook", "DocxImage",
    "DocxToFb2Converter",
    "Fb2ToMarkdownConverter", "Fb2MarkdownWriter",
    "MarkdownToFb2Converter",
    "Fb2ToHtmlConverter",
    "HtmlToFb2Converter",
    "Fb2ToTxtConverter",
    "Fb2ToOdtConverter", "OdtBook", "OdtImage",
    "OdtToFb2Converter",
    "Fb2ToMobiConverter", "MobiBook", "MobiImage",
    "MobiToFb2Converter", "MobiHeader",
    "Fb2ToFb3Converter", "Fb3Document", "Fb3Image",
    "Fb3ToFb2Converter",
    "Fb2ToPdfConverter",
    "PdfToFb2Converter",
    # --- опциональное (требует extras [wiki]) ---
    "WikipediaAuthor",
]


def __getattr__(name: str):
    """Ленивый доступ к опциональным (extras) сущностям.

    ``WikipediaAuthor`` требует пакетов ``requests``/``beautifulsoup4``/
    ``markdownify`` (extra ``pyFB2[wiki]``), а ``Fb2ToPdfConverter`` и
    ``PdfToFb2Converter`` — ``reportlab``/``pypdf`` (extra ``pyFB2[pdf]``).
    Поэтому они импортируются только при обращении.
    """
    if name == "WikipediaAuthor":
        from .fb2_wiki import WikipediaAuthor

        return WikipediaAuthor
    if name == "Fb2ToPdfConverter":
        from .fb2_to_pdf import Fb2ToPdfConverter

        return Fb2ToPdfConverter
    if name == "PdfToFb2Converter":
        from .pdf_to_fb2 import PdfToFb2Converter

        return PdfToFb2Converter
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")


if TYPE_CHECKING:  # pragma: no cover
    from .fb2_to_pdf import Fb2ToPdfConverter  # noqa: F401
    from .pdf_to_fb2 import PdfToFb2Converter  # noqa: F401
    from .fb2_wiki import WikipediaAuthor  # noqa: F401



# Библиотека ничего не печатает сама: диагностика идёт через logging
# (логгеры вида ``pyFB2.<модуль>``). NullHandler подавляет вывод последнего
# средства (lastResort) до тех пор, пока приложение не настроит логирование.
logging.getLogger(__name__).addHandler(logging.NullHandler())

