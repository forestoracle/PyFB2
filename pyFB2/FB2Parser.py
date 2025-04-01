import importlib.resources
import json
import os
from xml.etree import ElementTree
from xml.etree.ElementTree import Element

import xmlschema


class FB2Parser:
    """Класс для разбора файла FB2"""
    def __init__(self, filename: str, check_schema=False):
        """
        Конструктор класса.
        :rtype: object
        :param filename: Имя файла FB2
        :param check_schema: Проверять файл FB2 на соответствие схеме
        :type check_schema: bool
        """

        if not os.path.isfile(filename):
            raise FileNotFoundError(f"Файл {filename} не найден.")

        self._filename = filename

        if check_schema:
            self.check_schema()

        self.root = ElementTree.parse(filename).getroot()

        self.cleanup()
        self.bodies = self.root.findall('./body')
        self._description = self.root.find('./description')
        self._title_info = self._description.find('./title-info')
        self._document_info = self._description.find('./document-info')
        self._publish_info = self._description.find('./publish-info')

    def cleanup(self):
        for element in self.root.iter():
            element.tag = element.tag.partition('}')[-1]

    def check_schema(self):
        """
        Проверка файла на соответствие схеме XSD
        """
        xsd = xmlschema.XMLSchema(
            os.path.join(str(importlib.resources.files(__package__).joinpath("resources")), "FictionBook.xsd"))
        xsd.validate(source=self.filename)

    @property
    def filename(self) -> str:
        """
        Возвращает имя открытого файла.
        :return: Имя открытого файла
        """
        return self._filename

    @property
    def description(self) -> Element:
        """
        Возвращает элемент description.
        От него отталкиваемся для получения разной информации о книге.
        :return: Элемент description
        """
        return self._description

    @property
    def title_info(self) -> Element:
        """
        Возвращает элемент title_info
        :return: Элемент title-info
        """
        return self._title_info

    @property
    def document_info(self) -> Element:
        return self._document_info

    @property
    def publish_info(self) -> Element:
        return self._publish_info

    @property
    def authors(self) -> list[Element]:
        """
        Возвращает список авторов книги.
        Элементы списка имеют тип Element
        :return: Список авторов книги
        """
        return self._title_info.findall("./author")

    def _get_el_by_xpath(self, root_element: Element, xpath: str) -> str:
        """
        Возвращает строковое значение элемента.
        :param root_element: Корневой элемент, от которого начинается поиск.
        :param xpath: XPath от коневого к искомому элементу.
        :return: Строковое значение элемента.
        """
        if root_element is None:
            raise ValueError("Passed into _get_el_by_xpath parameter rootElement is None.")
        return root_element.find(xpath).text

    def author_first_name(self, author=None) -> str:
        """
        Имя автора. Если параметр author не указан, то возвращается имя первого автора.
        :param author: Элемент author
        :return: Имя автора
        """
        first_name_element = self._title_info.find("./author/first-name") if author is None else author.find(
            "./first-name")
        return first_name_element.text if not first_name_element is None else ""

    def author_last_name(self, author=None) -> str:
        """
        Фамилия автора. Если параметр author не указан, то возвращается фамилия первого автора.
        :param author: Элемент author
        :return: Фамилия автора
        """
        last_name_element = self._title_info.find("./author/last-name") if author is None else author.find("./last-name")
        return last_name_element.text if not last_name_element is None else ""

    def author_middle_name(self, author=None) -> str:
        """
        Отчество автора. Если параметр author не указан, то возвращается отчество первого автора.
        :param author: Элемент author
        :return: Фамилия автора
        """
        middle_name_element = self._title_info.find("./author/middle-name") if author is None else author.find(
            "./middle-name")
        return middle_name_element.text if not middle_name_element is None else ""

    def author_home_page(self, author=None):
        """
        Домашняя страница автора. Если параметр author не указан, то возвращается домашняя страница первого автора.
        :param author: Элемент author
        :return: Домашняя страница автора.
        """
        if author is None:
            home_page_element = self._title_info.find("./author/home-page")
        else:
            home_page_element = author.find("./home-page")

        return home_page_element.text if not home_page_element is None else ""

    def author_nickname(self, author=None):
        """
        Никнейм автора. Если параметр author не указан, то возвращается никнейм первого автора.
        :param author: Элемент author
        :return: Никнейм автора.
        """
        if author is None:
            nickname_element = self._title_info.find("./author/nickname")
        else:
            nickname_element = author.find("./nickname")

        return nickname_element.text if not nickname_element is None else ""

    def author_id(self, author=None):
        """
        Идентификатор автора. Если параметр author не указан, то возвращается идентификатор первого автора.
        :param author: Элемент author
        :return: Идентификатор автора.
        """
        if author is None:
            id_element = self._title_info.find("./author/id")
        else:
            id_element = author.find("./id")

        return id_element.text if not id_element is None else ""

    @property
    def title(self):
        """
        Заголовок книги.
        """
        return self._get_el_by_xpath(root_element=self._title_info, xpath="./book-title")

    @property
    def lang(self):
        """
        Получение списка языков книги.
        :return: Список языков книги, например ['ru', 'en']
        """
        result = []
        counter = 1
        lang_element = self._title_info.find(f'./lang[{counter}]')
        while not lang_element is None:
            result += [lang_element.text]
            counter += 1
            lang_element = self._title_info.find(f'./lang[{counter}]')
        return result

    @property
    def src_lang(self):
        """
        Список исходных языков книги
        :return: Список исходных языков книги, например ['en', 'ru']
        """
        result = []
        counter = 1
        src_lang_element = self._title_info.find(f'./src-lang[{counter}]')
        while not src_lang_element is None:
            result += [src_lang_element.text]
            counter += 1
            src_lang_element = self._title_info.find(f'./src-lang[{counter}]')
        return result

    @property
    def genres(self) -> list:
        """
        Получение списка жанров книги
        :return: Список жанров книги, например ['sci_philosophy', 'sci_politics', 'sci_history']
        """
        result = []
        counter = 1
        genre_element = self._title_info.find(f'./genre[{counter}]')

        while not genre_element is None:
            result += [genre_element.text]
            counter += 1
            genre_element = self._title_info.find(f'./genre[{counter}]')

        return result

    @property
    def genres_names(self) -> list:
        """
        Получение списка наименований жанров по спецификации FB 2.1
        :returns: Список наименований жанров
        """
        _genres_file_name = os.path.join(str(importlib.resources.files(__package__).joinpath("resources")),
                                         "genres.json")
        with open(_genres_file_name, "rb") as f:
            genres_names = json.load(f)
        return [f["name"] for f in genres_names if f["code"] in self.genres]

    @property
    def annotation(self):
        """
        Аннотация к книге.
        :TODO: В каком еще формате можно представить аннотацию. Придумать специальный параметр со значением по умолчанию?
        """
        result = ""
        counter = 1
        annotation_element = self._title_info.find(f'./annotation/p[{counter}]')
        while not annotation_element is None:
            result += f'<p>{annotation_element.text}</p>'
            counter += 1
            annotation_element = self._title_info.find(f'./annotation/p[{counter}]')
        return result

    @property
    def keywords(self):
        """
        Возвращает ключевые слова книги.
        :return: Строку, состоящую из ключевых слов. Нарпимер: "политика, Россия, Ленин"
        """
        return self._get_el_by_xpath(root_element=self._title_info, xpath='./keywords')

    @property
    def sequence_name(self):
        """
        Возвращает серию, в рамках которой была выпущене книга
        :return: Строка с названием серии
        """
        sequence_element = self._title_info.find('./sequence')
        return "" if sequence_element is None else sequence_element.attrib.get('name').strip()

    @property
    def sequence_number(self):
        """
        Возвращает номер книги в серии, в рамках которой была выпущене книга.
        :return: Номер тома в серии.
        """
        sequence_element = self._title_info.find('./sequence')
        return "" if sequence_element is None else "" if sequence_element.attrib.get(
            "number") is None else sequence_element.attrib.get("number")

    @property
    def title_info_date(self):
        """ Возвращает дату из элемента ./description/title-info/date """
        return self._get_el_by_xpath(root_element=self._title_info, xpath='./date')

    @property
    def cover_page(self):
        """

        :return:
        :TODO: Как получить xmlns при разборе xml? И получить вот эту конструкцию image_el.attrib['{http://www.w3.org/1999/xlink}href']
        """
        image_element = self._title_info.find('./coverpage/image')
        if not image_element is None:
            try:
                return image_element.attrib['{http://www.w3.org/1999/xlink}href'].replace('#', '')
            except KeyError:
                return ""

    @property
    def doc_info_author_nickname(self):
        """
        Возвращает никнейм автора документа.
        :return: Никнейм автора документа.
        """
        return self._get_el_by_xpath(root_element=self._document_info, xpath='./author/nickname')

    @property
    def doc_info_program_used(self) -> str:
        """
        Возвращает Имя программы, использованной для создания документа.
        :return: Имя программы, использованной для создания документа.
        """
        return self._get_el_by_xpath(root_element=self._document_info, xpath='./program-used')

    @property
    def doc_info_date_str(self):
        """
        /FictionBook/description/document-info/date
        :return:
        """
        return self._get_el_by_xpath(root_element=self._document_info, xpath='./date')

    @property
    def doc_info_date_value(self):
        """
        /FictionBook/description/document-info/date
        :return:
        """
        date_element = self._document_info.find('./date')
        if date_element is None:
            return ""
        else:
            try:
                return date_element.attrib['value']
            except KeyError:
                return ""

    @property
    def doc_info_src_url(self):
        """
        :return:
        """
        return self._get_el_by_xpath(root_element=self._document_info, xpath='./src-url')

    @property
    def doc_info_src_ocr(self):
        """
        :return:
        """
        return self._get_el_by_xpath(root_element=self._document_info, xpath='./src-ocr')

    @property
    def doc_info_id(self) -> str:
        return self._get_el_by_xpath(root_element=self._document_info, xpath='./id')

    @property
    def doc_info_version(self) -> str:
        return self._get_el_by_xpath(root_element=self._document_info, xpath='./version')

    @property
    def doc_info_history(self) -> str:
        p = '<p>{0}</p>'
        result = ""
        history_element = self._document_info.find('./history')
        if not history_element is None:
            for history in history_element:
                result += p.format(history.text)
        return result

    @property
    def doc_info_pulisher_id(self) -> str:
        return self._get_el_by_xpath(root_element=self._document_info, xpath='./publisher/id')

    @property
    def doc_info_pulisher_first_name(self) -> str:
        return self._get_el_by_xpath(root_element=self._document_info, xpath='./publisher/first-name')

    @property
    def doc_info_pulisher_last_name(self) -> str:
        return self._get_el_by_xpath(root_element=self._document_info, xpath='./publisher/last-name')

    @property
    def publish_info_bookname(self) -> str:
        return self._get_el_by_xpath(root_element=self._publish_info, xpath='./bookname')

    @property
    def publish_info_publisher(self) -> str:
        return self._get_el_by_xpath(root_element=self._publish_info, xpath='./publisher')

    @property
    def publish_info_city(self) -> str:
        return self._get_el_by_xpath(root_element=self._publish_info, xpath='./city')

    @property
    def publish_info_year(self) -> str:
        return self._get_el_by_xpath(root_element=self._publish_info, xpath='./year')

    @property
    def publish_info_isbn(self) -> str:
        return self._get_el_by_xpath(root_element=self._publish_info, xpath='./isbn')

    @property
    def publish_info_sequence(self) -> str:
        return self._get_el_by_xpath(root_element=self._publish_info, xpath='./sequence')

    def get_binaries(self):
        """
        Возвращяет список бинарников в формате BASE64.
        :return: Список бинарников.
        """
        return self.root.findall('binary')

    def get_sections(self, root_section: Element):
        """
        Возвращает список всех секций, входящих в корневую секцию.

        :param root_section:  Корневая секция
        :return: Список секций.
        """
        return root_section.findall('./section')

    def get_titles(self, section: Element):
        """
        Возвращает список всех заголовков секции.

        :param section:  Секция, для которой ищутся заголовки
        :return: Список заголовков.
        """
        titles = []
        titles.extend(section.findall('./title//'))
        return titles

    def is_flat_section(self, section: Element) -> bool:
        """
        Возвращает True, если секция section не имеет подсекций.

        :param section: Секция, в которой ищем подсекции.
        :return: True, если секция section не имеет подсекций.
        """
        return section.find('./section') is None

    def is_section_wo_title(self, section: Element) -> bool:
        """
        Возвращает True, если секция section не имеет заголовка.

        :param section: Секция, в которой ищем подсекции.
        :return: True, если секция section не имеет заголовка.
        """
        return section.find('./title') is None

    def is_body_notes(self, body: Element) -> bool:
        try:
            return body.attrib['name'] == 'notes'
        except KeyError as err:
            return False
