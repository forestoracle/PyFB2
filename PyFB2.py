import base64
import os
from pathlib import Path
import xml.etree.ElementTree as ET
from xml.etree.ElementTree import Element



class FB2Parser:
    """
    Класс для разбора FB2
    """
    root: Element  # root element
    bodies: []  #
    LastError: int  # last error code
    level: int

    def __init__(self, filename) -> object:
        """
        Конструктор класса.
        :rtype: object
        :param filename: Имя файла FB2
        """
        self.level = 1
        self.LastError = 0
        if os.path.isfile(filename):  #
            self.LastError = 0  #
        else:
            self.LastError = 1  # файл не найден
            exit(self.LastError)
        self.root = ET.parse(filename).getroot()
        self.cleanup()
        self.bodies = self.root.findall("./body")

    def cleanup(self):
        for element in self.root.iter():
            element.tag = element.tag.partition('}')[-1]

    @property
    def description(self):
        """
        Возвращает элемент description.
        От него отталкиваемся для получения разной информации о книге.
        :return: Элемент description
        """
        return self.root.find("./description")

    @property
    def authors(self):
        """
        Возвращает список авторов книги.
        Элементы списка имеют тип Element
        :return: Список авторов книги
        """
        return self.root.findall("./description/title-info/author")

    def author_first_name(self, author=None):
        """
        Имя автора. Если параметр author не указан, то возвращается имя первого автора.
        :param author: Элемент author
        :return: Имя автора
        """
        if author is None:
            first_name_el = self.description.find("./title-info/author/first-name")
        else:
            first_name_el = author.find("./first-name")

        if first_name_el is None:
            return ""
        else:
            return first_name_el.text

    def author_last_name(self, author=None):
        """
        Фамилия автора. Если параметр author не указан, то возвращается фамилия первого автора.
        :param author: Элемент author
        :return: Фамилия автора
        """
        if author is None:
            last_name_el = self.description.find("./title-info/author/last-name")
        else:
            last_name_el = author.find("./last-name")

        if last_name_el is None:
            return ""
        else:
            return last_name_el.text

    def author_middle_name(self, author=None):
        """
        Отчество автора. Если параметр author не указан, то возвращается отчество первого автора.
        :param author: Элемент author
        :return: Фамилия автора
        """
        if author is None:
            middle_name_el = self.description.find("./title-info/author/middle-name")
        else:
            middle_name_el = author.find("./middle-name")

        if middle_name_el is None:
            return ""
        else:
            return middle_name_el.text

    def author_home_page(self, author=None):
        """
        Домашняя страница автора. Если параметр author не указан, то возвращается домашняя страница первого автора.
        :param author: Элемент author
        :return: Домашняя страница автора.
        """
        if author is None:
            home_page_el = self.description.find("./title-info/author/home-page")
        else:
            home_page_el = author.find("./home-page")

        if home_page_el is None:
            return ""
        else:
            return home_page_el.text

    def author_nickname(self, author=None):
        """
        Никнейм автора. Если параметр author не указан, то возвращается никнейм первого автора.
        :param author: Элемент author
        :return: Никнейм автора.
        """
        if author is None:
            nickname_el = self.description.find("./title-info/author/nickname")
        else:
            nickname_el = author.find("./nickname")

        if nickname_el is None:
            return ""
        else:
            return nickname_el.text

    def author_id(self, author=None):
        """
        Идентификатор автора. Если параметр author не указан, то возвращается идентификатор первого автора.
        :param author: Элемент author
        :return: Идентификатор автора.
        """
        if author is None:
            id_el = self.description.find("./title-info/author/id")
        else:
            id_el = author.find("./id")

        if id_el is None:
            return ""
        else:
            return id_el.text

    @property
    def title(self):
        """
        Заголовок книги.
        """
        title_el = self.root.find("./description/title-info/book-title")
        if title_el is None:
            return ""
        else:
            return title_el.text

    @property
    def lang(self):
        """
        Получение списка языков книги.
        :return: Список языков книги, например ['ru', 'en']
        """
        result = []
        counter = 1
        lang_el = self.root.find("./description/title-info/lang[{}]".format(counter))
        while lang_el is not None:
            result += [lang_el.text]
            counter += 1
            lang_el = self.root.find("./description/title-info/lang[{}]".format(counter))
        return result

    @property
    def src_lang(self):
        """
        Список исходных языков книги
        :return: Список исходных языков книги, например ['en', 'ru']
        """
        result = []
        counter = 1
        src_lang_el = self.root.find("./description/title-info/src-lang[{}]".format(counter))
        while src_lang_el is not None:
            result += [src_lang_el.text]
            counter += 1
            src_lang_el = self.root.find("./description/title-info/src-lang[{}]".format(counter))
        return result

    @property
    def genre(self):
        """
        Получение списка жанров книги
        :return: Список жанров книги, например ['sci_philosophy', 'sci_politics', 'sci_history']
        """
        result = []
        counter = 1
        genre_el = self.root.find("./description/title-info/genre[{}]".format(counter))
        while genre_el is not None:
            result += [genre_el.text]
            counter += 1
            genre_el = self.root.find("./description/title-info/genre[{}]".format(counter))
        return result

    @property
    def annotation(self):
        """
        Аннотация к книге.
        """
        result = ""
        counter = 1
        annotation_el = self.root.find("./description/title-info/annotation/p[{}]".format(counter))
        while annotation_el is not None:
            result += "<p>" + annotation_el.text + "</p>"
            counter += 1
            annotation_el = self.root.find("./description/title-info/annotation/p[{}]".format(counter))
        return result

    @property
    def keywords(self):
        """
        Возвращает ключевые слова книги.
        :return: Строку, состоящую из ключевых слов. Нарпимер: "политика, Россия, Ленин"
        """
        keywords_el = self.root.find("./description/title-info/keywords")
        if keywords_el is None:
            return ""
        else:
            return keywords_el.text

    @property
    def sequence_name(self):
        """
        Возвращает серию, в рамках которой была выпущене книга
        :return: Строка с названием серии
        """
        sequence_el = self.root.find("./description/title-info/sequence")
        if sequence_el is None:
            return ""
        else:
            return sequence_el.attrib["name"]

    @property
    def sequence_number(self):
        """
        Возвращает номер книги в серии, в рамках которой была выпущене книга.
        :return: Номер тома в серии.
        """
        sequence_el = self.root.find("./description/title-info/sequence")
        if sequence_el is None:
            return ""
        else:
            try:
                return sequence_el.attrib["number"]
            except KeyError:
                return ""

    @property
    def title_info_date(self):
        date_el = self.root.find("./description/title-info/date")
        if date_el is None:
            return ""
        else:
            return date_el.text

    def get_binaries(self):
        """
        Возвращяет список бинарников в формате BASE64.
        :return: Список бинарников.
        """
        return self.root.findall('binary')

    def get_sections(self, root_section):
        """
        Возвращает список всех секций, входящих в корневую секцию.

        :param root_section:  Корневая секция
        :return: Список секций.
        """
        return root_section.findall("./section")

    def get_titles(self, section):
        """
        Возвращает список всех заголовков секции.

        :param root_section:  Секция, для которой ищутся заголовки
        :return: Список заголовков.
        """
        return section.findall("./title/p")

    def is_flat_section(self, section: Element) -> bool:
        return section.find("./section") is None


class FB2HTML:
    """
    Класс для преобразования файла FB2 в файлы HTML
    """
    _parser: FB2Parser
    LastError: int
    _bodies: []
    _counter: int

    def __init__(self, filename) -> object:
        """
        Конструктор класса FB2HTML
        :param filename: Имя файла FB2
        """
        self._parser = FB2Parser(filename)
        self.LastError = self._parser.LastError
        self._counter = 0
        if self.LastError == 0:
            self._bodies = self._parser.bodies

    def _remove_restricted_chars(self, value) -> str:
        """
        Удаляет из строки символы, запрещенные для использования в именах файлов
        :param value: Строка, из которой нужно удалить запрещенные символы
        :return: Строка, из которой удалены запрещенные символы
        """
        for c in '\/:*?"<>|':
            value = value.replace(c, '')
        return value

    def _create_path(self, path) -> str:
        """
        Создает полный путь, по которому будут выгружаться html-файлы
        и изображения.
        :param path: Путь, который нужно создать
        :return: Созданный путь
        """

        if path is None:
            path = "./"
            dir = self._remove_resricted_chars(self._parser.title)
            path = os.path.join(path, dir)
        os.makedirs(path, exist_ok=True)
        return path

    def write_binaries(self, path):
        """
        Записывает бинарные файлы на диск. Бинарные файлы ожидаются в формате BASE64 и перекодируются в бинарный формат.
        :param path: Путь, по которому будут сохраняться бинарные файлы.
        :return: Список сохраненных файлов.
        """
        result = []
        images = self._parser.get_binaries()
        for image in images:
            image_id = image.attrib["id"]  # это имя файла, например cover.jpg
            content_type = image.attrib["content-type"]  # сейчас не используется
            bin_data = base64.b64decode(image.text)  # перекодируем из BASE64 в бинарный формат
            file_name = os.path.join(path, image_id)  # формируем имя файла
            with open(file_name, 'wb') as file:  # открываем бинарный (b) файл для записи (w)
                file.write(bin_data)
                file.close()
                result += [file_name]
        return result

    def _get_titles_p(self, element, titles) -> str:
        """
        Записывает параграфы, содержимым которых будут заголовки.
        :param element: Элемент, субэлементами которого будут параграфы заголовков
        :param titles: Список заголовков
        :return:
        """
        for title in titles:
            ET.SubElement(element, 'p').text = title.text

    def _get_titles_l(self, titles):
        if not titles:
            return ""
        result = " "
        for title in titles:
            if title.text:
                result += title.text
        return result

    def _enum_sections(self, root_element: Element, list_el: Element):
        """
        Выполняет поиск всех
        :param root_section: Корневой элемент
        :return:
        """
        sections = self._parser.get_sections(root_element)
        if not self._parser.is_flat_section(root_element):
            if list_el != None:
                sublist_el = ET.SubElement(list_el, "ul")
                list_el.text = self._get_titles_l(self._parser.get_titles(root_element))
        for section in sections:
            if self._parser.is_flat_section(section):
                item_el = ET.SubElement(sublist_el, "li")
                # filename = "section_"+str(_counter)+".html"
                link_el = ET.SubElement(item_el, "a", attrib={"href": "link"})
                link_el.text = self._get_titles_l(self._parser.get_titles(section))
            # else:

            self._enum_sections(section, sublist_el)

    def write_html(self, path: str = None, create_index: bool = True, write_binaries: bool = True):
        """
        Запись файлов html и изображений в указанный каталог.
        :param path: Путь, по которому будут сохранены файлы (html и картинки).
                     Если не указан, то в текущем каталоге будет создан каталог с названием книги
                     (с исключенными символами, запрещенными для названий каталогов).
        :param create_index: Если True, то создается файл index.html с содержание книги.
        :param write_binaries: Если True, то записываются на диск бинарные файлы.
        :return: Список созданных файлов.
        """
        """
            index
            body[1] Может иметь заголовки. Пишем их в тело.
                section[1] Секциия не имеют заголовков. Тогда пишем ее в body.
                section[2] Имеет заголовки, не имеет вложенных секций. Тогда пишем ее в отдельный файл. 
                           А в body пишем ссылку на нее.
                section[3] Имеет заголовок, имеет вложенные секции. НЕ пишем ее в отдельный файл.
                           Ищем в ней секции с заголовками, а в body пишем ссылку на них.              
            body[2]
        """
        new_path = self._create_path(path)
        index_file = ""
        result = []
        if write_binaries:
            result += self.write_binaries(new_path)  #

        # Проходим по всем секция типа body.
        #  Их может быть много и у них могут быть заголовки, эпиграфы и т.д. как и у обычных секций
        body_counter = 0
        for body in self._bodies:
            body_counter += 1
            html_el = ET.Element('html', attrib={"xml:lang": "ru-ru", "lang": "ru-ru"})
            body_head = ET.Element('head')
            ET.SubElement(body_head, 'meta',
                          attrib={"http-equiv": "content-type", "content": "text/html; charset=utf-8"})
            ET.SubElement(body_head, 'title').text = "Body " + str(body_counter)
            html_el.append(body_head)
            #
            #  Формируем тело
            #
            body_el = ET.Element('body')
            self._get_titles_p(ET.SubElement(body_el, 'h1'), self._parser.get_titles(body))

            # body_body.append(sec)

            sections = self._parser.get_sections(body)

            # Вот здесь нужно рекурсивно читать секции тела

            self._enum_sections(body, ET.SubElement(body_el, "ul"))

            """
            for section in sections:
                if self._parser.is_flat_section(section):
                    print("Flat section:")
                titles = self._parser.get_titles(section)
                ET.SubElement(body_el, 'a', attrib={"href":"source"}).text = "Link"
                if not titles:
                    print("section wo titles")
            """
            html_el.append(body_el)
            #  Записываем на диск
            ET.ElementTree(html_el).write("./out/index_" + str(body_counter) + ".html", encoding='utf-8')


class FB2Hyst:
    """
    Класс для преобразования файла FB2 в БД Hyst
    """
    parser: FB2Parser
    LastError: int

    def __init__(self, filename) -> object:
        self.parser = FB2Parser(filename)
        self.LastError = self.parser.LastError


class FB2Renamer:
    """
    Класс для переименования ОДНОГО файла FB2 на основе шаблона.
    В состав шаблона могут входить:\n
    {AL} - Фамилия автора  - верхний регистр\n
    {AF} - Имя автора      - верхний регистр\n
    {AM} - Отчество автора - верхний регистhр\n
    {Al} - Фамилия автора  - капитализация\n
    {Af} - Имя автора      - капитализация\n
    {Am} - Отчество автора - капитализация\n
    {al} - Фамилия автора  - нижний регистр\n
    {af} - Имя автора      - нижний регистр\n
    {am} - Отчество автора - нижний регистр\n
    {F}  - Первая буква имени + .\n
    {M}  - Первая буква отчества + .\n
    {T}  - заголовок - верхний регистр\n
    {t}  - заголовок - нижний регистр\n
    {Tt} - заголовок - как в файле\n
    """
    template: str
    LastError: int
    old_filename: str

    def __init__(self, filename: str, template: str) -> object:
        """
        Конструктор класса для переименования файла FB2.
        Шаблон переименования:

        :param filename: Имя файла FB2
        :param template: Шаблон переименования
        """
        self.LastError = 0
        self.template = template
        self.old_filename = filename
        self._get_fb2_properties()

    def _get_fb2_properties(self):
        """
        Выполняет извлечение свойств FB2 файла
        :TODO: Что делать, если авторов несколько?
        """
        parser = FB2Parser(self.old_filename)
        self.Tt = parser.title
        self.T = self.Tt.upper()
        self.t = self.Tt.lower()
        authors = parser.authors
        for author in authors:
            self.AL = parser.author_last_name(author)
            self.AF = parser.author_first_name(author)
            self.AM = parser.author_middle_name(author)
            if self.AF > '':
                self.F = '{0}.'.format(self.AF[0])
            else:
                self.F = ''

            if self.AM > '':
                self.M = '{0}.'.format(self.AM[0])
            else:
                self.M = ''

            self.al = self.AL.lower()
            self.af = self.AL.lower()
            self.am = self.AM.lower()

            self.Al = self.AL.capitalize()
            self.Af = self.AF.capitalize()
            self.Am = self.AM.capitalize()
            break
        del parser

    def _remove_restricted_chars(self, value) -> str:
        """
        Удаляет из строки символы, запрещенные для использования в именах файлов
        :param value: Строка, из которой нужно удалить запрещенные символы
        :return: Строка, из которой удалены запрещенные символы
        """
        for c in '\/:*?"<>|':
            value = value.replace(c, '')
        return value

    def _template_is_valid(self) -> bool:
        """
        Проверяет, что шаблон переименования правильный
        :return:
        """
        return True

    @property
    def new_filename(self) -> str:
        """
        Возвращает новое имя файла, сформированное в соответствие с шаблоном
        :return:
        """
        nn = self.template
        nn = nn.replace('{AM}', self.AM)
        nn = nn.replace('{AF}', self.AF)
        nn = nn.replace('{AL}', self.AL)

        nn = nn.replace('{Al}', self.Al)
        nn = nn.replace('{Am}', self.Am)
        nn = nn.replace('{Af}', self.Af)

        nn = nn.replace('{al}', self.al)
        nn = nn.replace('{am}', self.am)
        nn = nn.replace('{af}', self.af)
        nn = nn.replace('{F}', self.F)
        nn = nn.replace('{M}', self.M)

        nn = nn.replace('{T}', self.T)
        nn = nn.replace('{t}', self.t)
        nn = nn.replace('{Tt}', self.Tt)
        nn = self._remove_restricted_chars(nn)
        path = os.path.split(os.path.abspath(self.old_filename))
        nn = os.path.join(path[0], '{0}.fb2'.format(nn))
        return nn

    def rename(self) -> str:
        """
        Выполняет переименование файла
        """
        os.rename(self.old_filename, self.new_filename)
        return self.new_filename

class FB2GroupRenamer:
    """
    Групповое переименование FB2 файлов
    """
    start_dir: Path

    def __init__(self, start_dir: str, template: str):
        """
        Конструктор
        :param start_dir: Каталог, в котором нужно искать файлы FB2
        :param template: Шаблон переименования
        """
        self.start_dir = Path(start_dir)
        self.template  = template

    def get_names(self):
        pass

    def rename_all(self):
        for item in list(self.start_dir.glob('**/*.fb2')):
            print(item)
            r = FB2Renamer(item, self.template)
            r.rename()
