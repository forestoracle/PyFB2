"""Чтение FB2 через xml.etree.ElementTree: <description>, <stylesheet>, <binary>.

Модуль предоставляет класс :class:`Fb2Parser`, который заполняет
dataclass-структуры из fb2_structures.py значениями из XML-документа.

С ЧЕГО НАЧИНАТЬ РАЗБОР FB2:
    1. Корень документа  -> <FictionBook>   (ET.parse(...).getroot())
    2. Дочерние элементы -> <stylesheet>*   (root.findall(fb("stylesheet")))
                            идут ПЕРЕД <description> и читаются отдельно
                            (см. Fb2Parser.parse_stylesheets).
    3. Метаданные книги  -> <description>   (root.find(fb("description")))
    4. Внутри описания   -> <title-info>    (обязательный, идёт первым)
                            затем <document-info>, <publish-info>,
                            <custom-info>, <output>.
    5. Основной текст    -> <body>+         (root.findall(fb("body")))
                            внутри — рекурсивные <section>
                            (см. Fb2Parser.parse_bodies / parse_section).

Ключевые моменты ElementTree в FB2:
    * Элементы лежат в пространстве имён NS_FB, поэтому имя для поиска —
      "{http://www.gribuser.ru/xml/fictionbook/2.0}description".
    * Атрибут xml:lang -> "{http://www.w3.org/XML/1998/namespace}lang",
      xlink:href       -> "{http://www.w3.org/1999/xlink}href".
    * Часть FB2-файлов идёт БЕЗ xmlns, поэтому поиск делается с фолбэком
      на имя без пространства имён (см. _find / _findall).
    * Кодировка берётся из XML-декларации автоматически.

Пример:
    >>> from fb2_parser import Fb2Parser
    >>> parser = Fb2Parser("book.fb2")
    >>> desc = parser.parse()
    >>> desc.title_info.book_title.value
    'Преступление и наказание'
    >>> [s.type for s in parser.parse_stylesheets()]
    ['text/css']
    >>> parser.save_binaries("images")   # все <binary> -> файлы в каталоге
    [WindowsPath('images/cover.jpg'), ...]
"""

from __future__ import annotations

import base64
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import List, Optional, Union

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
    DocumentInfo,
    EmptyLine,
    Epigraph,
    Genre,
    Image,
    InlineImage,
    Paragraph,
    Poem,
    PublishInfo,
    Section,
    Sequence,
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
from .fb2_errors import Fb2ParseError
from .fb2_xml import parse_xml

# --- Служебные константы ---------------------------------------------------
XML_LANG = f"{{{NS_XML}}}lang"
XLINK_HREF = f"{{{NS_XLINK}}}href"
XLINK_TYPE = f"{{{NS_XLINK}}}type"

#: Тег-заглушка для текстовых фрагментов внутри mixed-контента.
TEXT_NODE = "#text"

#: Элементы разметки styleType (внутри <p>, <th>, <td>, <v> и т. п.).
STYLE_TAGS = frozenset(
    {
        "strong", "emphasis", "style", "a",
        "strikethrough", "sub", "sup", "code", "image",
    }
)

#: Соответствие MIME-типа (content-type) и расширения файла для <binary>.
CONTENT_TYPE_EXTENSIONS = {
    "image/jpeg": ".jpg",
    "image/jpg": ".jpg",
    "image/png": ".png",
    "image/gif": ".gif",
    "image/bmp": ".bmp",
    "image/webp": ".webp",
    "image/svg+xml": ".svg",
    "image/tiff": ".tiff",
    "application/octet-stream": ".bin",
}

#: content-type по умолчанию, если атрибут не задан.
DEFAULT_CONTENT_TYPE = "application/octet-stream"


class Fb2Parser:
    """Парсер FB2: преобразует XML-элементы в dataclass-структуры.

    Класс не хранит состояние разбора между вызовами, поэтому один
    экземпляр можно переиспользовать для нескольких документов.

    :param source: необязательный источник по умолчанию — путь к файлу,
        file-like объект или готовый ``ET.Element`` (корень документа).
        Если задан, ``parse()`` можно вызывать без аргументов.

    Пример:
        >>> parser = Fb2Parser()
        >>> description = parser.parse("book.fb2")
        >>> description.title_info.lang
        'ru'
    """

    def __init__(self, source=None) -> None:
        self.source = source

    # --- Публичный API -----------------------------------------------------
    def parse(self, source=None) -> Description:
        """Прочитать <description> из FB2 и вернуть :class:`Description`.

        :param source: путь к файлу, file-like объект или готовый
            ``ET.Element`` (корень). Если не задан — берётся ``self.source``.
        :raises ValueError: если в документе нет элемента <description>.
        """
        root = self._get_root(source)
        elem = self._find(root, "description")
        if elem is None:
            raise Fb2ParseError("В документе отсутствует элемент <description>")
        return self.parse_description(elem)

    def parse_stylesheets(self, source=None) -> List[Stylesheet]:
        """Прочитать все элементы <stylesheet> корневого уровня.

        В схеме они идут ПЕРЕД <description> и могут повторяться. Тип
        (например, ``text/css``) задаётся обязательным атрибутом ``type``.

        :param source: путь к файлу, file-like объект или готовый
            ``ET.Element`` (корень). Если не задан — берётся ``self.source``.
        :return: список :class:`Stylesheet` (может быть пустым).
        """
        root = self._get_root(source)
        return [self._parse_stylesheet(e) for e in self._findall(root, "stylesheet")]

    def parse_binaries(self, source=None) -> List[Binary]:
        """Прочитать все элементы <binary> корневого уровня.

        Каждый <binary> содержит base64-данные (обложки, иллюстрации и т. п.).
        В возвращаемых объектах данные хранятся в виде base64-строки (``data``);
        для получения байтов используйте :meth:`binary_data`, для записи на
        диск — :meth:`save_binary` / :meth:`save_binaries`.

        :param source: путь к файлу, file-like объект или готовый
            ``ET.Element`` (корень). Если не задан — берётся ``self.source``.
        :return: список :class:`Binary` (может быть пустым).
        """
        root = self._get_root(source)
        return [self._parse_binary(e) for e in self._findall(root, "binary")]

    @staticmethod
    def binary_data(binary: Binary) -> bytes:
        """Декодировать base64-содержимое <binary> в байты.

        Пробельные символы (переносы строк, отступы) игнорируются, поэтому
        данные, записанные с форматированием, декодируются корректно.
        """
        return base64.b64decode("".join(binary.data.split()))

    @staticmethod
    def binary_filename(binary: Binary) -> str:
        """Подобрать имя файла для <binary>.

        Приоритет: имя из атрибута ``id`` (если у него уже есть расширение),
        иначе ``id`` + расширение по ``content-type``, иначе ``binary`` +
        расширение по ``content-type``.
        """
        content_type = (binary.content_type or "").lower()
        ext = CONTENT_TYPE_EXTENSIONS.get(content_type, "")
        base = (binary.id or "").strip() or "binary"
        base = base.replace("/", "_").replace("\\", "_")
        if Path(base).suffix:
            return base
        return f"{base}{ext or '.bin'}"

    def save_binary(
        self, binary: Binary, directory: Union[str, Path] = "."
    ) -> Path:
        """Сохранить одно <binary> в файл.

        :param binary: объект :class:`Binary`.
        :param directory: каталог для сохранения (создаётся при отсутствии).
        :return: путь к записанному файлу.
        """
        target_dir = Path(directory)
        target_dir.mkdir(parents=True, exist_ok=True)
        path = target_dir / self.binary_filename(binary)
        path.write_bytes(self.binary_data(binary))
        return path

    def save_binaries(
        self, directory: Union[str, Path] = ".", source=None
    ) -> List[Path]:
        """Сохранить все <binary> документа в каталог.

        :param directory: каталог для сохранения (создаётся при отсутствии).
        :param source: путь к файлу, file-like объект или готовый ET.Element.
        :return: список путей к записанным файлам.
        """
        return [self.save_binary(b, directory) for b in self.parse_binaries(source)]

    def parse_bodies(self, source=None) -> List[Body]:
        """Прочитать все элементы <body> корневого уровня.

        Первый <body> — основной текст книги, остальные (обычно с атрибутом
        ``name``) — дополнительные, например сноски.

        После разбора всем заголовкам присваиваются целочисленные
        идентификаторы (``heading_id``/``parent_id``, см.
        :meth:`assign_heading_ids`).

        :param source: путь к файлу, file-like объект или готовый
            ``ET.Element`` (корень). Если не задан — берётся ``self.source``.
        :return: список :class:`Body` (может быть пустым).
        """
        root = self._get_root(source)
        bodies = [self.parse_body(e) for e in self._findall(root, "body")]
        self.assign_heading_ids(bodies)
        return bodies

    def parse_body(self, elem: ET.Element) -> Body:
        """Разобрать один элемент <body>.

        body: image?, title?, epigraph*, section+; атрибуты name?, xml:lang?.
        """
        body = Body(name=elem.get("name"), lang=elem.get(XML_LANG))
        for child in elem:
            name = self._local(child.tag)
            if name == "image":
                body.image = self._parse_image(child)
            elif name == "title":
                body.title = self._parse_title(child)
            elif name == "epigraph":
                body.epigraphs.append(self._parse_epigraph(child))
            elif name == "section":
                body.sections.append(self.parse_section(child))
        return body

    def parse_section(self, elem: ET.Element) -> Section:
        """Разобрать один <section> (рекурсивно по вложенным секциям).

        sectionType: title?, epigraph*, image?, annotation?, затем либо
        вложенные section+, либо блочный контент
        (p|poem|subtitle|cite|empty-line|table|image)+.

        По XSD в шапке секции может быть только ОДНА картинка (слот ``image?``).
        Поэтому первое ``<image>``, встреченное до ``<annotation>``, блочного
        контента и подсекций, читается в :attr:`Section.image` (главная картинка
        секции), а все последующие — обычные блочные ``<image>`` в
        :attr:`Section.content`. Иначе несколько иллюстраций в одной секции
        затирали бы друг друга в единственном поле ``image``.
        """
        section = Section(id=elem.get("id"), lang=elem.get(XML_LANG))
        header_open = True
        for child in elem:
            name = self._local(child.tag)
            if name == "title":
                section.title = self._parse_title(child)
            elif name == "epigraph":
                section.epigraphs.append(self._parse_epigraph(child))
            elif name == "image":
                image = self._parse_image(child)
                if header_open and section.image is None:
                    section.image = image
                else:
                    section.content.append(image)
            elif name == "annotation":
                section.annotation = self._parse_annotation(child)
                header_open = False
            elif name == "section":
                section.sections.append(self.parse_section(child))
                header_open = False
            else:
                block = self._parse_block(child)
                if block is not None:
                    section.content.append(block)
                header_open = False
        return section

    # --- Идентификаторы заголовков ----------------------------------------
    def assign_heading_ids(self, bodies: List[Body]) -> int:
        """Присвоить заголовкам целочисленные идентификаторы.

        Заголовком считается любой ``<body>`` или ``<section>`` с элементом
        ``<title>``. Каждому заголовку выдаётся уникальный последовательный
        номер (``heading_id``), начиная с 1, в порядке обхода документа.

        Каждому узлу дерева записывается также ``parent_id`` — номер
        ближайшего заголовка-предка (``None``, если предка с заголовком нет).
        Для ``<body>`` ``parent_id`` всегда ``None`` (верхний уровень).
        Секции без ``<title>`` собственного номера не получают
        (``heading_id is None``), но наследуют ``parent_id`` предка.

        Нумерация сквозная по всем телам документа, поэтому идентификаторы
        уникальны в пределах книги.

        :param bodies: список тел документа; объекты изменяются на месте.
        :return: последний использованный номер (0, если заголовков нет).
        """
        counter = [0]

        def visit_section(section: Section, parent_id: Optional[int]) -> None:
            current: Optional[int] = parent_id
            if section.title is not None:
                counter[0] += 1
                section.heading_id = counter[0]
                current = section.heading_id
            section.parent_id = parent_id
            for child in section.sections:
                visit_section(child, current)

        for body in bodies:
            body.parent_id = None
            if body.title is not None:
                counter[0] += 1
                body.heading_id = counter[0]
                current = body.heading_id
            else:
                current = None
            for section in body.sections:
                visit_section(section, current)

        return counter[0]

    # --- Дерево заголовков и текста ---------------------------------------
    def section_title(self, section: Section) -> str:
        """Собрать текст заголовка секции в одну строку ("" если заголовка нет)."""
        if section.title is None:
            return ""
        return " / ".join(
            self._markup_text(item.content)
            for item in section.title.items
            if isinstance(item, Paragraph)
        )

    def block_text(self, block) -> str:
        """Извлечь простой текст из блочного элемента контента."""
        if isinstance(block, (Paragraph, Subtitle)):
            return self._markup_text(block.content)
        if isinstance(block, EmptyLine):
            return ""
        if isinstance(block, Poem):
            parts = [self.block_text(item) for item in block.items]
            return " / ".join(p for p in parts if p)
        if isinstance(block, Cite):
            parts = [self.block_text(item) for item in block.items]
            return " / ".join(p for p in parts if p)
        if isinstance(block, Table):
            return " | ".join(
                " ".join(self._markup_text(cell.children) for cell in row.cells)
                for row in block.rows
            )
        return ""

    def describe_section_tree(
        self,
        section: Section,
        depth: int = 0,
        with_text: bool = True,
        indent: str = "  ",
        with_ids: bool = False,
    ) -> str:
        """Представить секцию и её подсекции как дерево (заголовок + текст).

        Секции в FB2 вложены друг в друга, что образует иерархию заголовков.
        Каждый уровень сдвигается на ``indent``. Текст, относящийся к секции
        (``section.content``), выводится сразу под её заголовком, а вложенные
        секции — глубже.

        :param section: секция для вывода.
        :param depth: текущий уровень вложенности (для отступа).
        :param with_text: включать ли текст под заголовками.
        :param indent: строка отступа на один уровень.
        :param with_ids: показывать ли номера заголовков (heading_id/parent_id).
        :return: многострочное представление.
        """
        prefix = indent * depth
        label = self.section_title(section) or "(без заголовка)"
        if with_ids:
            label = (
                f"[id={section.heading_id} parent={section.parent_id}] {label}"
            )
        lines = [f"{prefix}- {label}"]

        if with_text:
            for block in section.content:
                text = self.block_text(block)
                if text:
                    lines.append(f"{prefix}{indent}{text}")

        for child in section.sections:
            lines.append(
                self.describe_section_tree(
                    child, depth + 1, with_text, indent, with_ids
                )
            )
        return "\n".join(lines)

    def describe_bodies(
        self,
        bodies: Optional[List[Body]] = None,
        with_text: bool = True,
        indent: str = "  ",
        source=None,
        with_ids: bool = False,
    ) -> str:
        """Вывести дерево заголовков с текстом для всех <body> документа.

        :param bodies: готовый список :class:`Body` (иначе читается из source).
        :param with_text: включать ли текст под заголовками.
        :param indent: строка отступа на один уровень.
        :param source: путь/поток/Element, если ``bodies`` не передан.
        :param with_ids: показывать ли номера заголовков (heading_id/parent_id).
        :return: многострочное представление.
        """
        if bodies is None:
            bodies = self.parse_bodies(source)

        lines: List[str] = []
        for index, body in enumerate(bodies):
            name = f" name={body.name!r}" if body.name else ""
            lines.append(f"== body[{index}]{name} ==")
            if body.title is not None:
                body_title = " / ".join(
                    self._markup_text(item.content)
                    for item in body.title.items
                    if isinstance(item, Paragraph)
                )
                if body_title:
                    if with_ids:
                        body_title = (
                            f"[id={body.heading_id} parent={body.parent_id}] "
                            f"{body_title}"
                        )
                    lines.append(f"# {body_title}")
            for section in body.sections:
                lines.append(
                    self.describe_section_tree(
                        section, 0, with_text, indent, with_ids
                    )
                )
        return "\n".join(lines)

    def _parse_block(self, elem: ET.Element):
        """Разобрать блочный элемент контента (None, если тег не распознан)."""
        name = self._local(elem.tag)
        if name == "p":
            return self._parse_paragraph(elem)
        if name == "subtitle":
            return self._parse_subtitle(elem)
        if name == "empty-line":
            return EmptyLine()
        if name == "poem":
            return self._parse_poem(elem)
        if name == "cite":
            return self._parse_cite(elem)
        if name == "table":
            return self._parse_table(elem)
        if name == "image":
            return self._parse_image(elem)
        return None

    def _get_root(self, source=None) -> ET.Element:
        """Вернуть корневой элемент, разобрав источник при необходимости."""
        if source is None:
            source = self.source
        if source is None:
            raise Fb2ParseError("Не задан источник FB2 (source)")
        return source if isinstance(source, ET.Element) else parse_xml(source)

    def parse_description(self, elem: ET.Element) -> Description:
        """Разобрать уже найденный элемент <description>."""
        description = Description()
        for child in elem:
            name = self._local(child.tag)
            if name == "title-info":
                description.title_info = self._parse_title_info(child)
            elif name == "src-title-info":
                description.src_title_info = self._parse_title_info(child)
            elif name == "document-info":
                description.document_info = self._parse_document_info(child)
            elif name == "publish-info":
                description.publish_info = self._parse_publish_info(child)
            elif name == "custom-info":
                description.custom_infos.append(self._parse_custom_info(child))
        return description

    # --- Низкоуровневые помощники -----------------------------------------
    @staticmethod
    def _local(tag: str) -> str:
        """Локальное имя тега: '{ns}section' -> 'section'."""
        return tag.rsplit("}", 1)[-1] if "}" in tag else tag

    @staticmethod
    def _tag(name: str) -> str:
        """Квалифицированное имя тега в пространстве имён FB2."""
        return f"{{{NS_FB}}}{name}"

    def _find(self, elem: ET.Element, name: str) -> Optional[ET.Element]:
        """Первый потомок по имени, с фолбэком на документы без xmlns.

        ВАЖНО: нельзя писать ``elem.find(...) or elem.find(...)`` — у элемента
        без детей булево значение равно False, и валидный результат потеряется.
        Проверяем именно на None.
        """
        found = elem.find(self._tag(name))
        if found is None:
            found = elem.find(name)
        return found

    def _findall(self, elem: ET.Element, name: str) -> List[ET.Element]:
        """Все потомки по имени, с фолбэком на документы без xmlns."""
        found = elem.findall(self._tag(name))
        if not found:
            found = elem.findall(name)
        return found

    @staticmethod
    def _text(elem: ET.Element) -> str:
        """Текст элемента без вложенных тегов (для simpleContent)."""
        return (elem.text or "").strip()

    @staticmethod
    def _to_int(value: Optional[str]) -> Optional[int]:
        try:
            return int(value.strip()) if value and value.strip() else None
        except ValueError:
            return None

    @staticmethod
    def _to_float(value: Optional[str]) -> Optional[float]:
        try:
            return float(value.strip()) if value and value.strip() else None
        except ValueError:
            return None

    # --- Разметка (styleType / mixed-контент) -----------------------------
    def _parse_markup(self, elem: ET.Element) -> List[StyleNode]:
        """Разобрать mixed-содержимое в список StyleNode.

        Текстовые фрагменты -> узлы с tag == TEXT_NODE, вложенные элементы
        разметки (<strong>, <emphasis>, <a>, <image> ...) -> узлы с children.
        """
        nodes: List[StyleNode] = []
        if elem.text and elem.text.strip():
            nodes.append(StyleNode(tag=TEXT_NODE, text=elem.text))
        for child in elem:
            if self._local(child.tag) in STYLE_TAGS:
                nodes.append(self._parse_style_node(child))
            if child.tail and child.tail.strip():
                nodes.append(StyleNode(tag=TEXT_NODE, text=child.tail))
        return nodes

    def _parse_style_node(self, elem: ET.Element) -> StyleNode:
        """Один элемент разметки styleType."""
        name = self._local(elem.tag)
        node = StyleNode(tag=name)
        node.children = self._parse_markup(elem)
        if name == "style":
            node.name = elem.get("name")
        elif name == "a":
            node.href = elem.get(XLINK_HREF) or elem.get("href")
            node.link_type = elem.get("type")
        elif name == "image":
            node.image_href = elem.get(XLINK_HREF)
            node.image_alt = elem.get("alt")
        return node

    # --- Блочные элементы, встречающиеся в title-info ---------------------
    def _parse_paragraph(self, elem: ET.Element) -> Paragraph:
        """pType (используется для <p>, <v>, <subtitle>, <text-author>)."""
        return Paragraph(
            content=self._parse_markup(elem),
            id=elem.get("id"),
            style=elem.get("style"),
            lang=elem.get(XML_LANG),
        )

    def _parse_annotation(self, elem: ET.Element) -> Annotation:
        """annotationType — choice(p|poem|cite|subtitle|table|empty-line)*."""
        items = []
        for child in elem:
            block = self._parse_block(child)
            if block is not None:
                items.append(block)
        return Annotation(items=items, id=elem.get("id"), lang=elem.get(XML_LANG))

    def _parse_subtitle(self, elem: ET.Element) -> Subtitle:
        """<subtitle> — использует pType."""
        return Subtitle(
            content=self._parse_markup(elem),
            id=elem.get("id"),
            style=elem.get("style"),
            lang=elem.get(XML_LANG),
        )

    def _parse_title(self, elem: ET.Element) -> Title:
        """titleType — choice (p | empty-line)* + xml:lang?."""
        items: List[Union[Paragraph, EmptyLine]] = []
        for child in elem:
            name = self._local(child.tag)
            if name == "p":
                items.append(self._parse_paragraph(child))
            elif name == "empty-line":
                items.append(EmptyLine())
        return Title(items=items, lang=elem.get(XML_LANG))

    def _parse_epigraph(self, elem: ET.Element) -> Epigraph:
        """epigraphType — choice(p|poem|cite|empty-line)*, затем text-author*."""
        items, text_author = [], []
        for child in elem:
            if self._local(child.tag) == "text-author":
                text_author.append(self._parse_paragraph(child))
                continue
            block = self._parse_block(child)
            if block is not None:
                items.append(block)
        return Epigraph(items=items, text_author=text_author, id=elem.get("id"))

    def _parse_stanza(self, elem: ET.Element) -> Stanza:
        """stanza — title?, subtitle?, v+."""
        title = subtitle = None
        verses = []
        for child in elem:
            name = self._local(child.tag)
            if name == "title":
                title = self._parse_title(child)
            elif name == "subtitle":
                subtitle = self._parse_subtitle(child)
            elif name == "v":
                verses.append(self._parse_paragraph(child))
        return Stanza(
            title=title,
            subtitle=subtitle,
            verses=verses,
            lang=elem.get(XML_LANG),
        )

    def _parse_poem(self, elem: ET.Element) -> Poem:
        """poemType — title?, epigraph*, (subtitle|stanza)+, text-author*, date?, id?, lang?."""
        title = date = None
        epigraphs: List[Epigraph] = []
        items: List[Union[Subtitle, Stanza]] = []
        text_author: List[Paragraph] = []
        for child in elem:
            name = self._local(child.tag)
            if name == "title":
                title = self._parse_title(child)
            elif name == "epigraph":
                epigraphs.append(self._parse_epigraph(child))
            elif name == "subtitle":
                items.append(self._parse_subtitle(child))
            elif name == "stanza":
                items.append(self._parse_stanza(child))
            elif name == "text-author":
                text_author.append(self._parse_paragraph(child))
            elif name == "date":
                date = self._parse_date(child)
        return Poem(
            title=title,
            epigraphs=epigraphs,
            items=items,
            text_author=text_author,
            date=date,
            id=elem.get("id"),
            lang=elem.get(XML_LANG),
        )

    def _parse_cite(self, elem: ET.Element) -> Cite:
        """citeType — choice(p|poem|empty-line|subtitle|table)*, text-author*, id?, lang?."""
        items, text_author = [], []
        for child in elem:
            if self._local(child.tag) == "text-author":
                text_author.append(self._parse_paragraph(child))
                continue
            block = self._parse_block(child)
            if block is not None:
                items.append(block)
        return Cite(
            items=items,
            text_author=text_author,
            id=elem.get("id"),
            lang=elem.get(XML_LANG),
        )

    def _parse_table(self, elem: ET.Element) -> Table:
        """tableType — tr+; в строке — th/td*."""
        rows = []
        for tr in self._findall(elem, "tr"):
            cells = []
            for cell in tr:
                name = self._local(cell.tag)
                if name not in ("td", "th"):
                    continue
                cells.append(
                    TableCell(
                        tag=name,
                        children=self._parse_cell_markup(cell),
                        colspan=self._to_int(cell.get("colspan")),
                        rowspan=self._to_int(cell.get("rowspan")),
                        align=self._to_enum(Align, cell.get("align")),
                        valign=self._to_enum(VAlign, cell.get("valign")),
                        style=cell.get("style"),
                        id=cell.get("id"),
                        is_header=(name == "th"),
                    )
                )
            rows.append(
                TableRow(align=self._to_enum(Align, tr.get("align")), cells=cells)
            )
        return Table(rows=rows, style=elem.get("style"), id=elem.get("id"))

    def _parse_cell_markup(self, cell: ET.Element) -> List[StyleNode]:
        """Содержимое ячейки таблицы (``<td>``/``<th>``).

        По схеме ячейка содержит inline-разметку, но в реальных файлах
        внутри неё часто стоит ``<p>`` — текст таких блоков тоже переносится.
        """
        nodes: List[StyleNode] = []
        if cell.text and cell.text.strip():
            nodes.append(StyleNode(tag=TEXT_NODE, text=cell.text))
        for child in cell:
            name = self._local(child.tag)
            if name in ("p", "subtitle", "empty-line"):
                nodes.extend(self._parse_markup(child))
            elif name in STYLE_TAGS:
                nodes.append(self._parse_style_node(child))
            if child.tail and child.tail.strip():
                nodes.append(StyleNode(tag=TEXT_NODE, text=child.tail))
        return nodes

    def _parse_image(self, elem: ET.Element) -> Image:
        """imageType — xlink:type?, xlink:href?, alt?, title?, id?."""
        return Image(
            href=elem.get(XLINK_HREF),
            alt=elem.get("alt"),
            title=elem.get("title"),
            id=elem.get("id"),
            type=elem.get(XLINK_TYPE),
        )

    @staticmethod
    def _to_enum(enum_cls, value: Optional[str]):
        """Мягкое приведение строки к значению Enum (None при ошибке)."""
        if value is None:
            return None
        try:
            return enum_cls(value.strip())
        except ValueError:
            return None

    @staticmethod
    def _markup_text(nodes: List[StyleNode]) -> str:
        """Собрать простой текст из списка узлов разметки (без тегов)."""
        parts = []
        for node in nodes:
            if node.tag == TEXT_NODE:
                parts.append(node.text)
            else:
                parts.append(Fb2Parser._markup_text(node.children))
        return "".join(parts)

    # --- Простые (simpleContent) элементы ---------------------------------
    def _parse_text_field(self, elem: ET.Element) -> TextField:
        """textFieldType — xs:string + xml:lang."""
        return TextField(value=self._text(elem), lang=elem.get(XML_LANG))

    def _parse_date(self, elem: ET.Element) -> DateField:
        """dateType — xs:string + value(xs:date) + xml:lang."""
        return DateField(
            value=self._text(elem),
            date_value=elem.get("value"),
            lang=elem.get(XML_LANG),
        )

    # --- Автор, жанр, серия, обложка --------------------------------------
    def _parse_author(self, elem: ET.Element) -> Author:
        """authorType: (first-name, middle-name?, last-name, ...) | (nickname, ...)."""

        def child_text(name: str) -> Optional[str]:
            child = self._find(elem, name)
            return self._text(child) if child is not None else None

        return Author(
            first_name=child_text("first-name"),
            middle_name=child_text("middle-name"),
            last_name=child_text("last-name"),
            nickname=child_text("nickname"),
            home_pages=[self._text(e) for e in self._findall(elem, "home-page")],
            emails=[self._text(e) for e in self._findall(elem, "email")],
            id=child_text("id"),
        )

    def _parse_genre(self, elem: ET.Element) -> Genre:
        """genre — genreType + атрибут match (по умолчанию 100)."""
        match = self._to_int(elem.get("match"))
        return Genre(
            value=self._text(elem),
            match=match if match is not None else 100,
        )

    def _parse_sequence(self, elem: ET.Element) -> Sequence:
        """sequenceType — name (обязателен), number?, xml:lang?, вложенные sequence*."""
        return Sequence(
            name=elem.get("name") or "",
            number=self._to_int(elem.get("number")),
            lang=elem.get(XML_LANG),
            sequences=[self._parse_sequence(s) for s in self._findall(elem, "sequence")],
        )

    def _parse_inline_image(self, elem: ET.Element) -> InlineImage:
        """inlineImageType — xlink:href?, alt?, xlink:type?."""
        return InlineImage(
            href=elem.get(XLINK_HREF),
            alt=elem.get("alt"),
            type=elem.get(XLINK_TYPE),
        )

    def _parse_coverpage(self, elem: ET.Element) -> CoverPage:
        """coverpage — sequence: image+."""
        return CoverPage(
            images=[self._parse_inline_image(img) for img in self._findall(elem, "image")]
        )

    # --- title-info / document-info / publish-info / custom-info ----------
    def _parse_title_info(self, elem: ET.Element) -> TitleInfo:
        """title-infoType (используется и для <src-title-info>)."""
        info = TitleInfo()
        for child in elem:
            name = self._local(child.tag)
            if name == "genre":
                info.genres.append(self._parse_genre(child))
            elif name == "author":
                info.authors.append(self._parse_author(child))
            elif name == "book-title":
                info.book_title = self._parse_text_field(child)
            elif name == "annotation":
                info.annotation = self._parse_annotation(child)
            elif name == "keywords":
                info.keywords = self._parse_text_field(child)
            elif name == "date":
                info.date = self._parse_date(child)
            elif name == "coverpage":
                info.coverpage = self._parse_coverpage(child)
            elif name == "lang":
                info.lang = self._text(child)
            elif name == "src-lang":
                info.src_lang = self._text(child)
            elif name == "translator":
                info.translators.append(self._parse_author(child))
            elif name == "sequence":
                info.sequences.append(self._parse_sequence(child))
        return info

    def _parse_document_info(self, elem: ET.Element) -> DocumentInfo:
        """document-info: author+, program-used?, date, src-url*, src-ocr?, id, version, ..."""
        info = DocumentInfo()
        for child in elem:
            name = self._local(child.tag)
            if name == "author":
                info.authors.append(self._parse_author(child))
            elif name == "program-used":
                info.program_used = self._parse_text_field(child)
            elif name == "date":
                info.date = self._parse_date(child)
            elif name == "src-url":
                info.src_urls.append(self._text(child))
            elif name == "src-ocr":
                info.src_ocr = self._parse_text_field(child)
            elif name == "id":
                info.id = self._text(child)
            elif name == "version":
                info.version = self._to_float(self._text(child))
            elif name == "history":
                info.history = self._parse_annotation(child)
            elif name == "publisher":
                info.publishers.append(self._parse_author(child))
        return info

    def _parse_publish_info(self, elem: ET.Element) -> PublishInfo:
        """publish-info: book-name?, publisher?, city?, year?, isbn?, sequence*."""
        info = PublishInfo()
        for child in elem:
            name = self._local(child.tag)
            if name == "book-name":
                info.book_name = self._parse_text_field(child)
            elif name == "publisher":
                info.publisher = self._parse_text_field(child)
            elif name == "city":
                info.city = self._parse_text_field(child)
            elif name == "year":
                info.year = self._text(child)
            elif name == "isbn":
                info.isbn = self._parse_text_field(child)
            elif name == "sequence":
                info.sequences.append(self._parse_sequence(child))
        return info

    def _parse_custom_info(self, elem: ET.Element) -> CustomInfo:
        """custom-info — textFieldType + обязательный info-type."""
        return CustomInfo(value=self._text(elem), info_type=elem.get("info-type") or "")

    def _parse_stylesheet(self, elem: ET.Element) -> Stylesheet:
        """stylesheet — xs:string + обязательный атрибут type (например, text/css)."""
        return Stylesheet(
            type=elem.get("type") or "",
            value=(elem.text or "").strip(),
        )

    def _parse_binary(self, elem: ET.Element) -> Binary:
        """binary — base64-содержимое + обязательные атрибуты id и content-type."""
        return Binary(
            id=elem.get("id") or "",
            content_type=elem.get("content-type") or DEFAULT_CONTENT_TYPE,
            data=(elem.text or "").strip(),
        )

    # --- Вывод (для CLI) ---------------------------------------------------
    @staticmethod
    def _format_author(author: Author) -> str:
        parts = [author.first_name, author.middle_name, author.last_name]
        return " ".join(p for p in parts if p) or (author.nickname or "—")

    def describe(self, description: Description) -> str:
        """Собрать человекочитаемое представление <description>."""
        lines: List[str] = []

        ti = description.title_info
        if ti is not None:
            lines.append("== title-info ==")
            lines.append("жанры: " + ", ".join(f"{g.value} ({g.match}%)" for g in ti.genres))
            lines.append("авторы: " + "; ".join(self._format_author(a) for a in ti.authors))
            if ti.book_title is not None:
                lines.append("название: " + ti.book_title.value)
            lines.append(f"язык: {ti.lang} | src-lang: {ti.src_lang}")
            if ti.date is not None:
                lines.append(f"дата: {ti.date.value} | value: {ti.date.date_value}")
            if ti.keywords is not None:
                lines.append("ключевые слова: " + ti.keywords.value)
            if ti.coverpage is not None:
                lines.append("обложка: " + str([img.href for img in ti.coverpage.images]))
            for seq in ti.sequences:
                lines.append(f"серия: {seq.name} {seq.number}")

        di = description.document_info
        if di is not None:
            lines.append("== document-info ==")
            lines.append(f"id: {di.id} | version: {di.version}")
            if di.date is not None:
                lines.append("дата: " + di.date.value)
            lines.append("авторы документа: " + "; ".join(self._format_author(a) for a in di.authors))
            if di.program_used is not None:
                lines.append("программа: " + di.program_used.value)

        pi = description.publish_info
        if pi is not None:
            lines.append("== publish-info ==")
            for label, field in (
                ("книга", pi.book_name),
                ("издательство", pi.publisher),
                ("город", pi.city),
                ("ISBN", pi.isbn),
            ):
                if field is not None:
                    lines.append(f"{label}: {field.value}")
            lines.append(f"год: {pi.year}")

        for custom in description.custom_infos:
            lines.append(f"custom-info[{custom.info_type}]: {custom.value}")

        return "\n".join(lines)


def main(argv: List[str] | None = None) -> int:
    if argv is None:
        argv = sys.argv
    if len(argv) < 2:
        print(
            "Использование: python fb2_parser.py <файл.fb2> [каталог_для_binary]",
            file=sys.stderr,
        )
        return 2

    parser = Fb2Parser(argv[1])

    stylesheets = parser.parse_stylesheets()
    if stylesheets:
        print("== stylesheets ==")
        for sheet in stylesheets:
            print(f"[{sheet.type}]")
            print(sheet.value)

    binaries = parser.parse_binaries()
    if binaries:
        print("== binaries ==")
        for binary in binaries:
            size = len(parser.binary_data(binary))
            print(f"{binary.id} [{binary.content_type}] ({size} байт)")

    if len(argv) > 2:
        for path in parser.save_binaries(argv[2]):
            print("сохранено:", path)

    description = parser.parse()
    print(parser.describe(description))

    bodies = parser.parse_bodies()
    if bodies:
        print(parser.describe_bodies(bodies))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))