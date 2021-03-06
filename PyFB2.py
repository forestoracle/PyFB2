"""
 Версия: 2022-03-10

"""
import argparse
import base64
import hashlib
import os
import re
import shutil
import sqlite3
import xml.etree.ElementTree as ET
from abc import abstractmethod
from pathlib import Path
from xml.etree import ElementTree
from xml.etree.ElementTree import Element


class FB2Parser:
    """
    Класс для разбора FB2
    """
    root: Element  # root element
    _description: Element  # /FictionBook/description
    _title_info: Element  # /FictionBook/description/title-info
    _document_info: Element  # /FictionBook/description/document-info
    _publish_info: Element  # /FictionBook/description/publish-info
    bodies: []  #
    lastError: int  # last error code
    level: int
    _filename: str
    debug: bool

    def __init__(self, filename: str, debug = False) -> object:
        """
        Конструктор класса.
        :rtype: object
        :param filename: Имя файла FB2
        """
        self.debug = debug
        self.level = 1
        self.lastError = 0
        if os.path.isfile(filename):  #
            self.lastError = 0
            self._filename = filename
        else:
            self.debugmsg('Файл {0} не найден.'.format(filename))
            self.lastError = 1  # файл не найден
            exit(self.lastError)
        try:
            self.root = ET.parse(filename).getroot()
        except:
            self.debugmsg('Ошибка формата файла. Не найден корневой жлемент. Файл: {0}'.format(self._filename))
            return None

        self.cleanup()
        self.bodies = self.root.findall("./body")
        try:
            self._description = self.root.find('./description')
        except:
            print('Error: No description. File: '.format(self._filename))

        try:
            self._title_info = self.description.find('./title-info')
        except:
            print('Error: No title-info. File: '.format(self._filename))

        self._document_info = self.description.find('./document-info')

        self._publish_info = self.description.find('./publish-info')

    def debugmsg(self, msg: str):
        """ Вывод отладочных сообщений """
        if self.debug:
            print(msg)

    def cleanup(self):
        for element in self.root.iter():
            element.tag = element.tag.partition('}')[-1]

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
    def authors(self):
        """
        Возвращает список авторов книги.
        Элементы списка имеют тип Element
        :return: Список авторов книги
        """
        return self._title_info.findall("./author")

    def _get_el_by_xpath(self, rootElement: Element, xpath: str) -> str:
        """
        Возвращает строковое значение элемента.
        :param rootElement: Корневой элемент, от которого начинается поиск.
        :param xpath: XPath от коневого к искомому элементу.
        :return: Строковое значение элемента.
        """
        if rootElement is None:
            self.debugmsg('Ошибка при вызове _get_el_by_xpath. Передан None')
            return ''

        element = rootElement.find(xpath)
        if element is None:
            return ""
        else:
            return element.text

    def author_first_name(self, author = None) -> str:
        """
        Имя автора. Если параметр author не указан, то возвращается имя первого автора.
        :param author: Элемент author
        :return: Имя автора
        """
        if author is None:
            firstNameElement = self._title_info.find("./author/first-name")
        else:
            firstNameElement = author.find("./first-name")

        if firstNameElement is None:
            return ""
        else:
            return firstNameElement.text

    def author_last_name(self, author = None) -> str:
        """
        Фамилия автора. Если параметр author не указан, то возвращается фамилия первого автора.
        :param author: Элемент author
        :return: Фамилия автора
        """
        if author is None:
            lastNameElement = self._title_info.find("./author/last-name")
        else:
            lastNameElement = author.find("./last-name")

        if lastNameElement is None:
            return ""
        else:
            return lastNameElement.text

    def author_middle_name(self, author = None) -> str:
        """
        Отчество автора. Если параметр author не указан, то возвращается отчество первого автора.
        :param author: Элемент author
        :return: Фамилия автора
        """
        if author is None:
            middleNameElement = self._title_info.find("./author/middle-name")
        else:
            middleNameElement = author.find("./middle-name")

        if middleNameElement is None:
            return ""
        else:
            return middleNameElement.text

    def author_home_page(self, author = None):
        """
        Домашняя страница автора. Если параметр author не указан, то возвращается домашняя страница первого автора.
        :param author: Элемент author
        :return: Домашняя страница автора.
        """
        if author is None:
            homePageElement = self._title_info.find("./author/home-page")
        else:
            homePageElement = author.find("./home-page")

        if homePageElement is None:
            return ""
        else:
            return homePageElement.text.strip()

    def author_nickname(self, author = None):
        """
        Никнейм автора. Если параметр author не указан, то возвращается никнейм первого автора.
        :param author: Элемент author
        :return: Никнейм автора.
        """
        if author is None:
            nicknameElement = self._title_info.find("./author/nickname")
        else:
            nicknameElement = author.find("./nickname")

        if nicknameElement is None:
            return ""
        else:
            return nicknameElement.text.strip()

    def author_id(self, author = None):
        """
        Идентификатор автора. Если параметр author не указан, то возвращается идентификатор первого автора.
        :param author: Элемент author
        :return: Идентификатор автора.
        """
        if author is None:
            idElement = self._title_info.find("./author/id")
        else:
            idElement = author.find("./id")

        if idElement is None:
            return ""
        else:
            return idElement.text.strip()

    @property
    def title(self):
        """
        Заголовок книги.
        """
        return self._get_el_by_xpath(self._title_info, "./book-title").strip('')

    @property
    def lang(self):
        """
        Получение списка языков книги.
        :return: Список языков книги, например ['ru', 'en']
        """
        result = []
        counter = 1
        langElement = self._title_info.find("./lang[{}]".format(counter))
        while langElement is not None:
            result += [langElement.text]
            counter += 1
            langElement = self._title_info.find("./lang[{}]".format(counter))
        return result

    @property
    def src_lang(self):
        """
        Список исходных языков книги
        :return: Список исходных языков книги, например ['en', 'ru']
        """
        result = []
        counter = 1
        srcLangElement = self._title_info.find("./src-lang[{}]".format(counter))
        while srcLangElement is not None:
            result += [srcLangElement.text]
            counter += 1
            srcLangElement = self._title_info.find("./src-lang[{}]".format(counter))
        return result

    @property
    def genre(self):
        """
        Получение списка жанров книги
        :return: Список жанров книги, например ['sci_philosophy', 'sci_politics', 'sci_history']
        """
        result = []
        counter = 1
        genreElement = self._title_info.find("./genre[{}]".format(counter))
        while genreElement is not None:
            result += [genreElement.text]
            counter += 1
            genreElement = self._title_info.find("./genre[{}]".format(counter))
        return result

    @property
    def annotation(self):
        """
        Аннотация к книге.
        :TODO: В каком еще формате можно представить аннотацию. Придумать специальный параметр со значением по умолчанию?
        """
        result = ""
        counter = 1
        annotationElement = self._title_info.find("./annotation/p[{0}]".format(counter))
        while annotationElement is not None:
            result += '<p>{0}</p>'.format(annotationElement.text)
            counter += 1
            annotationElement = self._title_info.find("./annotation/p[{}]".format(counter))
        return result

    @property
    def keywords(self):
        """
        Возвращает ключевые слова книги.
        :return: Строку, состоящую из ключевых слов. Нарпимер: "политика, Россия, Ленин"
        """
        return self._get_el_by_xpath(self._title_info, './keywords')

    @property
    def sequence_name(self):
        """
        Возвращает серию, в рамках которой была выпущене книга
        :return: Строка с названием серии
        """
        try:
            sequenceElement = self._title_info.find('./sequence')
        except:
            sequenceElement = None
        if sequenceElement is None:
            return ""
        else:
            return sequenceElement.attrib["name"].strip()

    @property
    def sequence_number(self):
        """
        Возвращает номер книги в серии, в рамках которой была выпущене книга.
        :return: Номер тома в серии.
        """
        try:
            sequenceElement = self._title_info.find("./sequence")
        except:
            sequenceElement = None
        if sequenceElement is None:
            return ""
        else:
            try:
                return sequenceElement.attrib["number"].strip()
            except KeyError:
                return ""

    @property
    def title_info_date(self):
        """ Возвращает дату из элемента ./description/title-info/date """
        return self._get_el_by_xpath(self._title_info, './date')

    @property
    def cover_page(self):
        """

        :return:
        :TODO: Как получить xmlns при разборе xml? И получить вот эту конструкцию image_el.attrib['{http://www.w3.org/1999/xlink}href']
        """
        imageElement = self._title_info.find('./coverpage/image')
        if not imageElement is None:
            try:
                # print(imageElement.attrib)
                return imageElement.attrib['{http://www.w3.org/1999/xlink}href'].replace('#', '')
            except KeyError:
                return ""

    @property
    def doc_info_author_nickname(self):
        """
        Возвращает никнейм автора документа.
        :return: Никнейм автора документа.
        """
        return self._get_el_by_xpath(self._document_info, './author/nickname')

    @property
    def doc_info_program_used(self) -> str:
        """
        Возвращает Имя программы, использованной для создания документа.
        :return: Имя программы, использованной для создания документа.
        """
        return self._get_el_by_xpath(self._document_info, './program-used')

    @property
    def doc_info_date_str(self):
        """
        /FictionBook/description/document-info/date
        :return:
        """
        return self._get_el_by_xpath(self._document_info, './date')

    @property
    def doc_info_date_value(self):
        """
        /FictionBook/description/document-info/date
        :return:
        """
        dateElement = self._document_info.find('./date')
        if dateElement is None:
            return ""
        else:
            try:
                return dateElement.attrib['value']
            except KeyError:
                return ""

    @property
    def doc_info_src_url(self):
        """
        :return:
        """
        return self._get_el_by_xpath(self._document_info, './src-url')

    @property
    def doc_info_src_ocr(self):
        """
        :return:
        """
        return self._get_el_by_xpath(self._document_info, './src-ocr')

    @property
    def doc_info_id(self) -> str:
        return self._get_el_by_xpath(self._document_info, './id')

    @property
    def doc_info_version(self) -> str:
        return self._get_el_by_xpath(self._document_info, './version')

    @property
    def doc_info_history(self) -> str:
        p = '<p>{0}</p>'
        result = ""
        historyElement = self._document_info.find('./history')
        if not historyElement is None:
            for history in historyElement:
                result += p.format(history.text)
        return result

    @property
    def doc_info_pulisher_id(self) -> str:
        return self._get_el_by_xpath(self._document_info, './publisher/id')

    @property
    def doc_info_pulisher_first_name(self) -> str:
        return self._get_el_by_xpath(self._document_info, './publisher/first-name')

    @property
    def doc_info_pulisher_last_name(self) -> str:
        return self._get_el_by_xpath(self._document_info, './publisher/last-name')

    @property
    def publish_info_bookname(self) -> str:
        return self._get_el_by_xpath(self._publish_info, './bookname')

    @property
    def publish_info_publisher(self) -> str:
        return self._get_el_by_xpath(self._publish_info, './publisher')

    @property
    def publish_info_city(self) -> str:
        return self._get_el_by_xpath(self._publish_info, './city')

    @property
    def publish_info_year(self) -> str:
        return self._get_el_by_xpath(self._publish_info, './year')

    @property
    def publish_info_isbn(self) -> str:
        return self._get_el_by_xpath(self._publish_info, './isbn')

    @property
    def publish_info_sequence(self) -> str:
        return self._get_el_by_xpath(self._publish_info, './sequence')

    def get_binaries(self):
        """
        Возвращяет список бинарников в формате BASE64.
        :return: Список бинарников.
        """
        return self.root.findall('binary')

    def get_sections(self, rootSection: Element):
        """
        Возвращает список всех секций, входящих в корневую секцию.

        :param rootSection:  Корневая секция
        :return: Список секций.
        """
        return rootSection.findall("./section")

    def get_titles(self, section: Element):
        """
        Возвращает список всех заголовков секции.

        :param root_section:  Секция, для которой ищутся заголовки
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
        return section.find("./section") is None

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


class FB2ConvertBase:
    dbconn: object
    debug: bool
    parser: FB2Parser
    level: int  # уровень вложенности глав
    counter: int  # счетчик записей, служит для заполнения SeqNo
    root_id: int  # идентификатор корневого узла
    html_header: bytes = b'<html xml:lang = "ru-ru" lang = "ru-ru">\n' \
                         b'  <head>\n' \
                         b'     <link rel="stylesheet" href="$CSS$" type="text/css">\n' \
                         b'     <meta http-equiv = "content-type" content = "text/html; charset=utf-8" />\n' \
                         b'     <title>$title$</title >\n' \
                         b'  </head>\n'

    def __init__(self, filename: str, css: str = None, debug = False) -> object:
        self.debug = debug
        self.css = css
        self.parser = FB2Parser(filename, self.debug)
        if self.parser is None:
            return None
        self.level = 0
        self.counter = 0
        self.root_id = 0

        self.create_memory_db()

    def debugmsg(self, msg: str):
        """ Вывод отладочных сообщений """
        if self.debug:
            print(msg)

    def remove_restricted_chars(self, value) -> str:
        """
        Удаляет из строки символы, запрещенные для использования в именах файлов
        :param value: Строка, из которой нужно удалить запрещенные символы
        :return: Строка, из которой удалены запрещенные символы
        """
        for c in '\/:*?"<>|':
            value = value.replace(c, "")
        return value

    def get_titles_str(self, section: ElementTree):
        """ Сшивает заголовки секции в одну строку """
        result = ''
        titles = self.parser.get_titles(section)
        for title in titles:
            if not title.text is None:
                result = result + ' ' + title.text.strip(' ')
        result = result.strip(' ')
        return result

    def write_binaries_on_disk(self, path):
        """
        Записывает бинарные файлы на диск. Бинарные файлы ожидаются в формате BASE64 и перекодируются в бинарный формат.
        :param path: Путь, по которому будут сохраняться бинарные файлы.
        :return: Список сохраненных файлов.
        """
        self.debugmsg('-> write_binaries_from_fb2')
        self.debugmsg('  Запись картинок на диск:')
        result = []
        images = self.parser.get_binaries()
        for image in images:
            image_id = image.attrib["id"]  # это имя файла, например cover.jpg
            content_type = image.attrib["content-type"]  # сейчас не используется
            bin_data = base64.b64decode(image.text)  # перекодируем из BASE64 в бинарный формат
            file_name = os.path.join(path, image_id)  # формируем имя файла
            with open(file_name, 'wb') as file:  # открываем бинарный (b) файл для записи (w)
                file.write(bin_data)
                file.close()
                result += [file_name]
                self.debugmsg('  {0}'.format(file_name))
        return result

    def write_binaries(self, outdir: str):
        self.debugmsg('-> write_binaries')
        self.debugmsg('  Запись изображений из БД на диск')
        cursor = self.dbconn.cursor()
        sql = 'select ShortDescr, image from note_image'
        for row in cursor.execute(sql):
            filename = os.path.join(outdir, row[0])
            bindata = sqlite3.Binary(row[1])
            self.debugmsg('  {0}'.format(filename))
            file = open(filename, 'wb')
            file.write(bindata)
            file.close()
        cursor.close()

    def write_html(self, outdir: str):
        """ Запись HTML на диск """
        self.debugmsg('-> write_html')
        self.debugmsg('  Запись HTML на диск')
        cursor = self.dbconn.cursor()
        sql = 'select id, text, length(text) from note'
        for row in cursor.execute(sql):
            if int(row[2]) > 0:
                strid = str(row[0]).zfill(4)  # число, выровненное нулями слева до 4
                filename = os.path.join(outdir, 'ch_{0}.html'.format(strid))
                bindata = sqlite3.Binary(row[1])
                self.debugmsg('    {0}'.format(filename))
                file = open(filename, 'wb')
                file.write(bindata)
                file.close()
        cursor.close()

    def insert_images(self, book_id = 0):
        """
        Запись картинок в БД
        """
        self.debugmsg('Запись картинок в БД:')
        images = self.parser.get_binaries()
        for image in images:
            image_id = image.attrib["id"]  # это имя файла, например cover.jpg
            content_type = image.attrib["content-type"]  # сейчас не используется
            bin_data = base64.b64decode(image.text)  # перекодируем из BASE64 в бинарный формат
            # имя файла ПОКА помещаем в поле short_descr
            last_id = self.insert_image(shortdescr = image_id, image = bin_data, calc_md5 = True, book_id = book_id)
            self.debugmsg('  id={0} filename={1}'.format(last_id, image_id))

    def create_memory_db(self):
        """ Создает в пямяти БД. Создает необходимые таблицы """
        self.dbconn = sqlite3.connect(':memory:')
        self.create_tables()

    def create_tables(self):
        # NB_PROFILE
        self.debugmsg('Создание таблицы NB_PROFILE')
        self.dbconn.execute("""CREATE TABLE IF NOT EXISTS nb_profile (
                name        VARCHAR (255) NOT NULL,
                ProfileType VARCHAR (255) NOT NULL DEFAULT NOTEBOOK       
        );""")

        # NOTEBOOK
        self.debugmsg('Создание таблицы NOTEBOOK')
        self.dbconn.execute("""CREATE TABLE IF NOT EXISTS notebook (
                id         INTEGER       CONSTRAINT pk_notebook PRIMARY KEY AUTOINCREMENT
                                         UNIQUE NOT NULL,
                name       VARCHAR (255) NOT NULL,
                SeqNo      INTEGER,
                Rating     INTEGER       DEFAULT (0),
                TabColor   INTEGER,
                ShortDescr VARCHAR (255),
                state      VARCHAR (1)   DEFAULT A);""")
        # NOTE
        self.debugmsg('Создание таблицы NOTE')
        self.dbconn.execute("""CREATE TABLE IF NOT EXISTS note (
                id         INTEGER      CONSTRAINT pk_note PRIMARY KEY AUTOINCREMENT
                                        CONSTRAINT uniq_note UNIQUE
                                        NOT NULL,
                ParentID   INTEGER,
                NotebookID INTEGER,
                SeqNo      INTEGER       DEFAULT (1000000),
                name       VARCHAR (255) NOT NULL,
                ShortDescr TEXT,
                text       TEXT,
                state      CHAR (1)      NOT NULL DEFAULT A,
                TextType   VARCHAR (10)  DEFAULT HTML);""")
        self.dbconn.execute("""CREATE INDEX IF NOT EXISTS idx_note_parentid ON note(ParentID, state)""")

        # NOTE_IMAGE
        self.debugmsg('Создание таблицы NOTE_IMAGE')
        self.dbconn.execute("""CREATE TABLE IF NOT EXISTS note_image (
                id         INTEGER       CONSTRAINT pk_note_image PRIMARY KEY AUTOINCREMENT
                                         CONSTRAINT uniq_note_image UNIQUE
                                         NOT NULL,
                image      BLOB,
                book_id    INTEGER,
                ShortDescr VARCHAR (1024), 
                LongDescr  TEXT,
                MD5        VARCHAR (40),
                thumbnail  BLOB);""")

        self.dbconn.execute("""CREATE INDEX IF NOT EXISTS idx_note_image_md5 ON note_image(MD5)""")

        # LINKS
        self.debugmsg('Создание таблицы LINKS')
        self.dbconn.execute("""CREATE TABLE IF NOT EXISTS links (
                id INTEGER CONSTRAINT pk_links PRIMARY KEY AUTOINCREMENT CONSTRAINT uniq_links UNIQUE NOT NULL,
                link_id varchar (32),
                filename varchar (32)) 
                """)

        # CSS
        self.debugmsg('Создание таблицы CSS')
        self.dbconn.execute("""CREATE TABLE IF NOT EXISTS css (
                id       INTEGER       CONSTRAINT pk_css PRIMARY KEY AUTOINCREMENT
                                       UNIQUE NOT NULL,
                name     VARCHAR (255) NOT NULL,
                code     VARCHAR (255) UNIQUE NOT NULL,
                filename VARCHAR (255) UNIQUE NOT NULL,
                css      TEXT
            );""")

    def backup_memory_db(self, filename: str):
        """
        Создает на диске БД SQLite3 - бэкап in-memory БД

        :param filename: Имя файла БД, вновь созданного на диске
        """
        self.debugmsg('Запись БД :memory: на диск')

        self.debugmsg('  Соединение с БД {0}'.format(filename))
        diskconn = sqlite3.connect(filename)

        self.debugmsg('  Создание бэкапа из памяти в БД {0}'.format(filename))
        self.dbconn.backup(diskconn)

        self.debugmsg('  Закрытие БД {0}'.format(filename))
        diskconn.close()

    def insert_notebook(self, name: str, short_descr = '') -> int:
        """
        Вставка новой записной книжки

        :param name:  Имя записной книжки
        :param short_descr: Короткое описание

        :return: Идентификатор записной книжки
        """
        cursor = self.dbconn.cursor()
        sql = 'insert into notebook (name, ShortDescr) values (?, ?)'
        cursor.execute(sql, [name, short_descr])
        self.dbconn.commit()
        lastrowid = cursor.lastrowid
        return lastrowid

    def insert_note(self, title: str, parent_id: int, text: str, notebook_id: int) -> int:
        """ Вставляет в таблицу NOTE запись """
        cursor = self.dbconn.cursor()
        sql = 'insert into note (ParentID, NotebookID, SeqNo, name, text) values (?, ?, ?, ?, ?)'
        cursor.execute(sql, [parent_id, notebook_id, self.counter, title, sqlite3.Binary(text)])
        self.dbconn.commit()
        lastrowid = cursor.lastrowid
        cursor.close()
        return lastrowid

    def insert_image(self, shortdescr: str, image: bytes, calc_md5 = True, book_id = 0) -> int:
        """
        Вставляет в таблицу NOTE_IMAGE изображение
        Возвращает идентификатор записи.

        """
        md5 = ''
        if calc_md5:
            md5 = hashlib.md5(image).hexdigest()
        cursor = self.dbconn.cursor()
        sql = 'insert into note_image (ShortDescr, image, md5, book_id) values (?, ?, ?, ?)'
        cursor.execute(sql, [shortdescr, sqlite3.Binary(image), md5, book_id])
        self.dbconn.commit()
        lastrowid = cursor.lastrowid
        return lastrowid

    def replace_img_links(self, section: Element):
        """
        Заменяет в указанной секции ссылки на бинарные данные на ссылки на файлы на диске
        :TODO: Надо литерал {http://www.w3.org/1999/xlink} заменить на значение из заголовка
        """
        self.debugmsg('-> replace_img_links')
        src = ''
        images = section.findall('./image') + section.findall('./*/image') + section.findall('./**/image')
        for image in images:
            image.tag = 'img'
            image_name = image.attrib['{http://www.w3.org/1999/xlink}href']
            src = '../img/{0}'.format(image.attrib['{http://www.w3.org/1999/xlink}href'].replace('#', ''))
            cursor = self.dbconn.cursor()
            sql = 'select id from note_image where book_id=? and ShortDescr=?'
            self.debugmsg('root: {0} image {1}'.format(self.root_id, image_name.replace('#', '')))
            for row in cursor.execute(sql, [self.root_id, image_name.replace('#', '')]):
                src = 'db://thisdb.note_image.image.{0}'.format(row[0])
            cursor.close()
            del image.attrib['{http://www.w3.org/1999/xlink}href']
            if src > '':
                image.set('src', src)

    def insert_child_sections(self, section, parent: int, notebook_id: int):
        """ Вставляет заголовки и главы в in-memory БД """
        sections = self.parser.get_sections(section)
        for section in sections:
            self.replace_img_links(section = section)
            self.level += 1
            title = self.get_titles_str(section)
            xmlstr = ElementTree.tostring(section, 'utf-8')
            xmlstr = self.replace_fb2_html(xmlstr, self.level, title.encode('utf-8'))
            if self.parser.is_flat_section(section):
                self.counter += 1
                if self.parser.is_section_wo_title(section):
                    self.update_parent_note(parent, xmlstr)
                else:
                    parent_id = self.insert_note(title, parent, xmlstr, notebook_id)
            else:

                parent_id = self.insert_note(title, parent, b'', notebook_id)
                self.insert_child_sections(section, parent_id, notebook_id)  # рекурсивный вызов самой себя
            self.level -= 1

    def update_parent_note(self, parent: int, text: str):
        """

        :TODO: Вот здесь надо не просто обновлять, а сливать секции
        :param parent:
        :param text:
        :return:
        """
        text0 = ''
        cursor0 = self.dbconn.cursor()
        sql0 = 'select text from note where id=?'
        for row0 in cursor0.execute(sql0, [parent]):
            text0 = row0[0] + text

        cursor = self.dbconn.cursor()
        sql = 'update note set text=? where id=?'
        cursor.execute(sql, [sqlite3.Binary(text0), parent])
        self.dbconn.commit()
        cursor0.close()
        cursor.close()

    def insert_root_section(self, notebook_id: int) -> int:
        """ Вставляет в in-memory БД корневой узел """
        self.debugmsg('-= insert_root_section - Запись корневого узла =-')
        self.debugmsg('    root_id: {0}'.format(self.root_id))
        self.debugmsg('  Заголовок: {0}'.format(self.parser.title))
        self.debugmsg('  Аннотация: {0}'.format(self.parser.annotation))
        # применение encode позволяет передать в INSERT тип bytes (как он и ожидает), а не str
        self.root_id = self.insert_note(self.parser.title, 0, self.parser.annotation.encode('utf-8'),
                                        notebook_id)
        return self.root_id

    def replace_fb2_html(self, fb2str: bytes, level: int, title: bytes) -> bytes:
        """ Заменяет тэги FB2 на тэги HTML """

        result = fb2str
        result = result.replace(b'<section>', b'<body>')
        result = result.replace(b'<section', b'<body')
        result = result.replace(b'</section>', b'</body>')
        result = result.replace(b'<title>', str('<h{0}>'.format(level)).encode('utf-8'))
        result = result.replace(b'</title>', str('</h{0}>'.format(level)).encode('utf-8'))
        result = result.replace(b'<empty-line />', b'<br>')
        result = result.replace(b'<subtitle>', b'<p class="subtitle"><b>')
        result = result.replace(b'</subtitle>', b'</b></p>')
        result = result.replace(b'<strong>', b'<b>')
        result = result.replace(b'</strong>', b'</b>')
        result = result.replace(b'<poem>', b'<pre class="poem">')
        result = result.replace(b'</poem>', b'</pre>')
        result = result.replace(b'<stanza>', b'<div class="stanza">')
        result = result.replace(b'</stanza>', b'</div>')
        result = result.replace(b'<v>', b'')
        result = result.replace(b'</v>', b'<br>')
        result = result.replace(b'<epigraph>', b'<div class="epigraph" align="left">')
        result = result.replace(b'</epigraph>', b'</div>')
        result = result.replace(b'<emphasis>', b'<div class="emphasis" align="left">')
        result = result.replace(b'</emphasis>', b'</div>')
        result = result.replace(b'<text-author>', b'<p class="text-author" align="left">"')
        result = result.replace(b'</text-author>', b'</p>')
        # <cite> </cite>

        result = self.html_header + result + b'</html>'
        result = result.replace(b'$title$', title)

        # result = result.replace(b'$CSS$', bytes('./../css/{0}'.format(self.css_filename).encode('utf-8')))
        result = self.replace_css(result, bytes('./../css/{0}'.format(self.css_filename).encode('utf-8')))
        return result

    def merge_bodies(self, body1: Element, body2: Element) -> Element:
        """ Выполняет слияние двух элементов body """
        pass

    def merge_sections(self, section1, section2):
        """ Выпоняет слияние двух элементов section """
        pass

    @property
    def css_filename(self):
        if not self.css is None:
            return os.path.split(self.css)[1]
        else:
            return None

    @abstractmethod
    def copy_css(self) -> bool:
        pass

    @abstractmethod
    def replace_css(self, text: bytes, css: bytes) -> bytes:
        pass


class FB2HTML(FB2ConvertBase):
    """
    Класс для преобразования файла FB2 в файлы HTML
    """
    new_outdir: str
    img_outdir: str
    htm_outdir: str
    css_outdir: str

    def __init__(self, filename: str, css: str = None, debug: bool = False) -> object:
        """
        Конструктор класса FB2HTML
        :param filename: Имя файла FB2
        """
        super().__init__(filename = filename, css = css, debug = debug)

    def count_children(self, parent_id) -> int:
        cursor = self.dbconn.cursor()
        sql = 'select count(1) as cnt from note where ParentID = ?'
        for row in cursor.execute(sql, [parent_id]):
            return int(row[0])

    def create_contents_list(self, parent_id: int) -> str:

        if self.count_children(parent_id) == 0:
            return

        cursor = self.dbconn.cursor()
        sql = 'select id, name, length(text) from note where ParentID = ? order by id asc'
        self.contents.write(b'\n<ul>')
        for row in cursor.execute(sql, [parent_id]):
            note_size = int(row[2])
            strid = str(row[0]).zfill(4)
            if note_size > 0:
                result = bytes(
                    '\n<li><a href=html/{0}>{1}</a></li>'.format('ch_{0}.html'.format(strid), row[1]).encode('utf-8'))
            else:
                result = bytes(
                    '\n<li>{0}</li>'.format(row[1]).encode('utf-8'))

            self.contents.write(result)
            self.create_contents_list(row[0])

        cursor.close()
        self.contents.write(b'\n</ul>')

    def write_contents_header(self):
        contents_header = self.html_header
        contents_header = self.replace_css(contents_header,
                                           bytes('./css/{0}'.format(self.css_filename).encode('utf-8')))
        # contents_header = contents_header.replace(b'$CSS$',
        #                                          bytes('./css/{0}'.format(self.css_filename).encode('utf-8')))
        contents_header = contents_header.replace(b'$title$', bytes(self.parser.title.encode('utf-8')))
        self.contents.write(contents_header)
        self.contents.write(bytes('\n<p><img src="./img/{0}"></p>'.format(self.parser.cover_page).encode('utf-8')))
        for author in self.parser.authors:
            self.contents.write(
                bytes('<h1 class="author">{0} {1} {2}</h1>\n'.format(self.parser.author_last_name(author),
                                                                     self.parser.author_first_name(author),
                                                                     self.parser.author_middle_name()).encode('utf-8')))

    def create_dirs(self, outdir: str, html_dir = 'html', image_dir = 'img', css_dir = 'css') -> bool:
        # имя автора
        author_name = self.remove_restricted_chars(
            '{0} {1} {2}'.format(self.parser.author_last_name(), self.parser.author_first_name(),
                                 self.parser.author_middle_name())).strip(' ')
        # повторяющиеся пробелы заменяем на единственный пробел
        author_name = re.sub("\s\s+", ' ', author_name).strip()

        book_title = self.remove_restricted_chars('{0}'.format(self.parser.title)).strip(' ')
        self.new_outdir = os.path.join(outdir, author_name, book_title)
        try:
            os.makedirs(self.new_outdir, exist_ok = True)
        except:
            print('Error: Cant create catalog {0}'.format(self.new_outdir))
            return False

        self.img_outdir = os.path.join(self.new_outdir, image_dir)
        self.htm_outdir = os.path.join(self.new_outdir, html_dir)
        self.css_outdir = os.path.join(self.new_outdir, css_dir)
        try:
            os.makedirs(self.img_outdir, exist_ok = True)
            os.makedirs(self.htm_outdir, exist_ok = True)
            os.makedirs(self.css_outdir, exist_ok = True)
            return True
        except:
            return False

    def copy_css(self) -> bool:
        """
        Копирует файл CSS d его каталог
        :return:  True - если файл скопирован
        """
        if self.css is None:
            return True

        try:
            self.debugmsg('Копирование CSS {0} -> {1}'.format(self.css, self.css_outdir))
            shutil.copy2(src = self.css, dst = self.css_outdir)
            return True
        except:
            return False

    def replace_css(self, text: bytes, css: bytes) -> bytes:
        return text.replace(b'$CSS$', css)

    def create_html(self, outdir: str = None) -> str:

        """
        Запись файлов html и изображений в указанный каталог.
        :param path: Путь, по которому будут сохранены файлы (html и картинки).
                     Если не указан, то в текущем каталоге будет создан каталог с названием книги
                     (с исключенными символами, запрещенными для названий каталогов).
        :param create_index: Если True, то создается файл index.html с содержание книги.
        :param write_binaries: Если True, то записываются на диск бинарные файлы.
        :return: Список созданных файлов.

        """
        # подготовка каталогов
        if not self.create_dirs(outdir = outdir):
            print('Error: Cant creating catalog {0}.'.format(outdir))
            return None
        if not self.copy_css():
            print('Error: Cant copy CSS {0}'.format(self.css))
            return None

        # вставляем записную книжку, пока это только заглушка
        # для HTML она вообще не нужна
        notebook_id = self.insert_notebook(self.parser.title)

        # вставляем корневой узел, все остальные будут его потомками
        self.root_id = self.insert_root_section(notebook_id)

        # Проходим по всем секция типа body.
        # Их может быть много и у них могут быть заголовки, эпиграфы и т.д. как и у обычных секций
        # записываем в
        for body in self.parser.bodies:
            self.debugmsg('Тело-заметки: {0}'.format(self.parser.is_body_notes(body)))
            if self.parser.is_body_notes(body):
                if self.get_titles_str(body) == '':
                    sections = body.findall('./section')
                    sections_count = len(sections)
                    self.debugmsg('  Количество секций: {0}'.format(sections_count))
                    if sections_count > 3:
                        #
                        # Анализ примечаний
                        # Здесь это временно, нужно вынести в отдельную функцию
                        #
                        for section in sections:
                            try:
                                id = section.attrib['id']
                                cursor = self.dbconn.cursor()
                                cursor.execute('insert into links (link_id) values (?)', [id])
                                self.dbconn.commit()
                            except:
                                print('Ошибка при вставке в таблицу LINKS')

                        self.insert_note(title = 'Примечания', parent_id = self.root_id,
                                         text = ElementTree.tostring(body, 'utf-8'), notebook_id = notebook_id)

                    else:
                        for section in sections:
                            self.insert_note(title = self.get_titles_str(section), parent_id = self.root_id,
                                             text = ElementTree.tostring(section, 'utf-8'),
                                             notebook_id = notebook_id)

                else:
                    self.insert_note(title = self.get_titles_str(body), parent_id = self.root_id,
                                     text = ElementTree.tostring(body, 'utf-8'),
                                     notebook_id = notebook_id)
            else:
                self.insert_child_sections(body, self.root_id,
                                           notebook_id)  # перебор всех секций, 0 - идентификатор тела как корневого узла

        # Записываем в БД изображения
        # возможно, для HTML этот шаг лишний и пригодится только для Hyst
        # но пока так
        self.insert_images()

        # записываем изображения на диск
        self.write_binaries(self.img_outdir)

        self.write_html(self.htm_outdir)

        filename = os.path.join(self.new_outdir, 'index.html')
        self.contents = open(filename, 'wb')
        self.write_contents_header()
        self.create_contents_list(0)
        self.contents.close()


class FB2Hyst(FB2ConvertBase):
    """ Класс для преобразования файла FB2 в БД Hyst """

    database: str

    def __init__(self, database: str, name: str = None, css: str = None, debug = True) -> object:
        self.database = database
        self.css = css
        self.parser = None
        self.debug = debug

        self.root_id = 0
        self.counter = 0
        self.level = 0
        if self.create_db(name = name) is None:
            return None

    def merge_databases(self, src_db: str, dst_db: str, parent_id: int, notebook_id: int) -> int:
        """
        Сливает две БД в одну. Записи из src_db добавляются в dst_db
        Возвращает количество перенесенных записей.

        :param src_db      - БД - источник записей
        :param dst_db      - БД - приемник записей
        :param root_id     - идентификатор корневой записи, под кторотой будут размещены перенесенные записи
        :param notebook_id - идентификатор записной книжки

        """
        self.debugmsg('-> {0}'.format(__name__))
        try:
            src_conn = sqlite3.connect(src_db)
        except:
            print('Error: Cant connect to source DB {0}'.format(src_db))
            return 0

        try:
            src_conn = sqlite3.connect(dst_db)
        except:
            src_conn.close()
            print('Error: Cant connect to target DB {0}'.format(dst_db))
            return 0

    def create_db(self, name: str = None) -> object:
        """
        Создание БД
        :return:
        """
        self.debugmsg('-> create_db')
        self.debugmsg('  Имя БД: {0}'.format(name))

        self.dbconn = sqlite3.connect(self.database)
        self.create_tables()
        self.copy_css()
        if not name is None:
            self.debugmsg(' Установка имени БД: {0}'.format(name))
            cursor = self.dbconn.cursor()
            sql = 'delete from nb_profile'
            cursor.execute(sql, [])
            self.dbconn.commit()
            sql = 'insert into nb_profile (name, ProfileType) values (?, ?)'
            cursor.execute(sql, [name, 'NOTEBOOK'])
            self.dbconn.commit()

    def get_notebook_id(self, notebook_name: str) -> int:
        """
        Проверяет наличие записной книжки в БД.
        :param notebook_name: Название ЗК
        :return: Идентификатор ЗК. None - если ЗК не найдена
        """
        self.debugmsg('-> get_notebook_id')
        cursor = self.dbconn.cursor()
        sql = 'select min(id) AS ID from notebook where name = ?'
        for row in cursor.execute(sql, [notebook_name]):
            return row[0]

    def add_notebook(self, notebook_name: str, short_descr: str) -> int:
        """
        Добавляет записную книжку. Если записная книжка с таким именем существует,
        то возвращает ее идентификатор. Если не существует, то добавляет новую запись и возвращает
        идентификатор новой записи.

        :param notebook_name: Имя записной книжки
        :param short_descr: Короткое описание
        :return: Идентификатор новой записной книжки
        """
        self.debugmsg('-> add_notebook')
        notebook_id = self.get_notebook_id(notebook_name = notebook_name)
        if notebook_id is None:
            notebook_id = self.insert_notebook(notebook_name, short_descr)
            self.debugmsg('Добавляем записную книжку: {0} - {1}'.format(notebook_id, notebook_name))
            return notebook_id
        else:
            self.debugmsg('Записная книжка уже существует: {0} - {1}'.format(notebook_id, notebook_name))
            return notebook_id

    def get_author_id(self, author_name: str, notebook_id: int) -> int:
        """
        Возращает имя идентификатор автора по его имени и ид ЗК
        Имя автора формируется как LastName+FirstName+MiddleName
        :param author_name: Имя автора
        :param notebook_id: Идентификатор записной книжки
        :return:
        """
        self.debugmsg('-> get_author_id')
        ParentID = 0
        cursor = self.dbconn.cursor()
        sql = 'select min(id) as id from note where name = ? and NotebookID = ? and ParentID = ?'
        for row in cursor.execute(sql, [author_name, notebook_id, ParentID]):
            return row[0]

    def add_author(self, author_name: str, notebook_id: int) -> int:
        """
        Добавляет автора. Имя автора формируется как LastName+FirstName+MiddleName
        :param author_name: Имя автора
        :param notebook_id: Записная книжка
        :return:
        """
        self.debugmsg('-> add_author')
        author_id = self.get_author_id(author_name = author_name, notebook_id = notebook_id)
        if author_id is None:
            self.debugmsg('Добавляем автора: {0} - {1} - {2}'.format(author_id, author_name, notebook_id))
            author_id = author_id = self.insert_note(title = author_name, parent_id = 0, text = ''.encode('utf-8'),
                                                     notebook_id = notebook_id)
            return author_id
        else:
            self.debugmsg('Автор уже существует: {0} - {1}'.format(author_id, author_name))
            return author_id

    def get_book_id(self, title: str, author_id: int):
        self.debugmsg('-> get_book_id')
        cursor = self.dbconn.cursor()
        sql = 'select min(id) from note where ParentID = ? and name = ?'
        for row in cursor.execute(sql, [author_id, title]):
            return row[0]

    def add_book_ext(self, filename: str, notebook_id: int) -> int:
        self.debugmsg('-> add_book_ext')
        self.parser = FB2Parser(filename = filename, debug = self.debug)
        author = '{0} {1} {2}'.format(self.parser.author_last_name(), self.parser.author_first_name(),
                                      self.parser.author_middle_name())
        author = author.strip(' ')
        author_id = self.add_author(author, notebook_id)
        # del self.parser
        return self.add_book(filename = filename, author_id = author_id, notebook_id = notebook_id)

    def get_book_cover(self) -> bytes:
        """

        :return:
        :TODO: 1. Иногда изображения обложки выглядят так <img src=db://thisdb.note_image.image.None>
               2. Это надо обрабатывать. И не применяется CSS - тоже доработать.
               3. ОШИБКА!!! cover_image НАСЛЕДУЕТСЯ ОТ ПРЕДЫДУЩЕЙ КНИГИ.
        """
        self.debugmsg('-> get_book_cover')
        cursor = self.dbconn.cursor()
        sql = 'select min(id) from note_image where book_id=? and ShortDescr=?'
        for row in cursor.execute(sql, [self.root_id, self.parser.cover_page]):
            cover_image = '<img src=db://thisdb.note_image.image.{0}>'.format(row[0])

        result = """<html xml:lang = "ru-ru" lang = "ru-ru">
                     <head>
                       <meta http-equiv = "content-type" content = "text/html; charset=utf-8" /> 
                       <title>{0}</title > 
                     </head>
                     <body>
                     {1}
                     {2}
                     </body>
                     </html>
                     """.format(self.parser.title, cover_image, self.parser.annotation)
        return bytes(result.encode('utf-8'))

    def update_note(self, note_id: int, text: str):
        self.debugmsg('-> update_note')
        cursor = self.dbconn.cursor()
        sql = 'update note set text = ? where id = ?'
        cursor.execute(sql, [text.encode('utf-8'), note_id])
        self.dbconn.commit()

    def add_book(self, filename: str, author_id: int, notebook_id: int) -> int:
        """
        Добавляет книгу

        :param filename: Имя файла FB2
        :param author_id: Идентификатор автора
        :param notebook_id: Идентификатор записной книжки
        :return:
        :TODO:  Аннотация добавляется как простой текст. Нужно заключить ее в HTML
        """
        if self.parser is None:
            self.parser = FB2Parser(filename = filename, debug = self.debug)
        self.debugmsg('-> add_book')
        book_id = self.get_book_id(title = self.parser.title, author_id = author_id)
        if not book_id is None:
            self.debugmsg('= W = Книга уже в БД: {0} - {1}'.format(book_id, self.parser.title))
            return book_id
        self.debugmsg('= I = Добавляем книгу {0}'.format(self.parser.title))
        self.root_id = self.insert_note(self.parser.title, author_id, self.get_book_cover(),
                                        notebook_id)

        book_id = self.root_id
        self.insert_images(book_id = book_id)

        # self.update_note(self.root_id, self.get_book_cover())

        for body in self.parser.bodies:
            self.debugmsg('Тело-заметки: {0}'.format(self.parser.is_body_notes(body)))
            if self.parser.is_body_notes(body):
                if self.get_titles_str(body) == '':
                    sections = body.findall('./section')
                    sections_count = len(sections)
                    self.debugmsg('  Количество секций: {0}'.format(sections_count))
                    if sections_count > 3:
                        #
                        # Анализ примечаний
                        # Здесь это временно, нужно вынести в отдельную функцию
                        #
                        for section in sections:
                            try:
                                id = section.attrib['id']
                                cursor = self.dbconn.cursor()
                                cursor.execute('insert into links (link_id) values (?)', [id])
                                self.dbconn.commit()
                            except:
                                pass

                        self.insert_note(title = 'Примечания', parent_id = self.root_id,
                                         text = ElementTree.tostring(body, 'utf-8'), notebook_id = notebook_id)

                    else:
                        for section in sections:
                            self.insert_note(title = self.get_titles_str(section), parent_id = self.root_id,
                                             text = ElementTree.tostring(section, 'utf-8'),
                                             notebook_id = notebook_id)

                else:
                    self.insert_note(title = self.get_titles_str(body), parent_id = self.root_id,
                                     text = ElementTree.tostring(body, 'utf-8'),
                                     notebook_id = notebook_id)
            else:
                self.insert_child_sections(body, self.root_id,
                                           notebook_id)  # перебор всех секций, 0 - идентификатор тела как корневого узла

    def copy_css(self) -> bool:
        if self.css is None:
            return True
        if not os.path.isfile(self.css):
            return False
        with open(self.css, 'rb') as f:
            css_text = f.read()
            f.close()

        cursor = self.dbconn.cursor()
        sql = 'insert into CSS (name, code, filename, css) values (?, ?, ?, ?)'
        cursor.execute(sql, [self.css_filename, self.css_filename, self.css_filename, sqlite3.Binary(css_text)])
        self.dbconn.commit()
        cursor.close()

    def replace_css(self, text: bytes, css: bytes) -> bytes:
        return text.replace(b'$CSS$', b'db://thisdb.css.css.1')


class FB2DirScaner:
    start_dir: Path
    dbconn: object

    def __init__(self, start_dir: str) -> object:
        self.start_dir = Path(start_dir)
        if not self.start_dir.is_dir():
            print('Error: Directory not exists: {0}'.format(self.start_dir))
            return None
        self.create_memory_db()

    def create_memory_db(self):
        try:
            self.dbconn = sqlite3.connect("authors.db")
        except IOError as err:
            print("Error: I/O error: {0}".format(err))
            return None
        self.dbconn.execute("""CREATE TABLE IF NOT EXISTS authors 
                       (ID integer CONSTRAINT pk_notebook PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,
                        first_name varchar2(255), last_name varchar2(255), middle_name varchar2)""")
        self.dbconn.execute("""CREATE TABLE IF NOT EXISTS works (author_id integer, title varchar(1024))""")

    def scan_dir(self):
        for item in list(self.start_dir.glob('**/*.fb2')):
            try:
                parser = FB2Parser(item)
                fn = str(parser.author_first_name()).strip()
                ln = str(parser.author_last_name()).strip()
                mn = str(parser.author_middle_name()).strip()
                self.dbconn.execute(
                    """insert into authors (last_name, first_name, middle_name) 
                    values ('{0}', '{1}', '{2}')""".format(ln, fn, mn))
                self.dbconn.commit()
            except:
                pass;
        # diskconn = sqlite3.connect('authors.db')
        # self.dbconn.backup(diskconn)
        # diskconn.close()


class FB2Renamer:
    """
    Класс для переименования ОДНОГО файла FB2 на основе шаблона.

    В состав шаблона могут входить:

    {AL} - Фамилия автора  - верхний регистр
    {AF} - Имя автора      - верхний регистр
    {AM} - Отчество автора - верхний регистр
    {Al} - Фамилия автора  - капитализация
    {Af} - Имя автора      - капитализация
    {Am} - Отчество автора - капитализация
    {al} - Фамилия автора  - нижний регистр
    {af} - Имя автора      - нижний регистр
    {am} - Отчество автора - нижний регистр
    {F}  - Первая буква имени + .
    {M}  - Первая буква отчества + .
    {T}  - заголовок - верхний регистр
    {t}  - заголовок - нижний регистр
    {Tt} - заголовок - как в файле
    {S}  - серия (sequence)
    {SN} - номер в серии (sequence number)

    :param filename: Имя файла, который будет переименован
    :param template: Шаблон переименования
    :param outdir: дополнительный каталог в форме шаблона
    :param debug: выводить отладочные сообщения
    """

    def __init__(self, filename: str, template: str, outdir: str = '', debug: bool = False) -> object:
        """
        Конструктор класса для переименования файла FB2 по шаблону

        :param filename: Имя файла FB2
        :param template: Шаблон переименования
        :param outdir
        """
        self.debug = debug
        self.filename = filename
        self._get_fb2_properties()  # получить свойства FB2-файла
        self.outdir = self._process_template(outdir)  #
        self.newPath = os.path.join(os.path.split(os.path.abspath(filename))[0], self.outdir)
        self.newFileName = '{0}.fb2'.format(self._process_template(template))

    def rename(self, dest_dir: str = '') -> str:
        """
        Выполняет переименование файла
        """
        try:
            os.makedirs(self.newPath, exist_ok = True)
        except:
            print('Error: Cant create dirs {0}'.format(self.newPath))
            exit(1)
        try:
            os.rename(self.filename, os.path.join(self.newPath, self.newFileName))
        except:
            print('Error: Cant rename {0} to {1}'.format(self.filename, self.newFileName))
            exit(1)

        return self.newFileName

    def _get_fb2_properties(self):
        """
        Выполняет извлечение свойств FB2 файла
        :TODO: Что делать, если авторов несколько?
        """
        parser = FB2Parser(self.filename, self.debug)
        if parser is None:
            print('Error: FB2Renamer error: bad file. File: {0}'.format(self.old_filename))
            return
        self.S = parser.sequence_name.strip()
        self.SN = parser.sequence_number.strip()
        self.Tt = parser.title.strip()
        self.T = self.Tt.upper().strip()
        self.t = self.Tt.lower().strip()
        authors = parser.authors
        for author in authors:
            self.AL = parser.author_last_name(author)
            self.AF = parser.author_first_name(author)
            self.AM = parser.author_middle_name(author)
            # Authors Last name
            if self.AL is None:
                self.AL = ''
            else:
                self.AL = self.AL.strip()
            # Authors First name
            if self.AF is None:
                self.AF = ''
            else:
                self.AF = self.AF.strip()
            # Authors Middle name
            if self.AM is None:
                self.AM = ''
            else:
                self.AM = self.AM.strip()

            if self.AF > '':
                self.F = '{0}.'.format(self.AF[0])
            else:
                self.F = ''

            if self.AM > '':
                self.M = '{0}.'.format(self.AM[0])
            else:
                self.M = ''

            self.al = self.AL.lower()
            self.af = self.AF.lower()
            self.am = self.AM.lower()

            self.Al = self.AL.capitalize()
            self.Af = self.AF.capitalize()
            self.Am = self.AM.capitalize()
            break
        del parser

    def _remove_restricted_chars(self, value: str) -> str:
        """
        Удаляет из строки символы, запрещенные для использования в именах файлов
        :param value: Строка, из которой нужно удалить запрещенные символы
        :return: Строка, из которой удалены запрещенные символы
        """
        for c in '\/:*?"<>|':
            value = value.replace(c, '')
        return value

    def _process_template(self, template: str) -> str:
        nn = template
        nn = nn.replace('{S}', self.S)
        nn = nn.replace('{SN}', self.SN)
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
        # Заменяем цепочку пробелов на один пробел
        nn = re.sub('\s\s+', ' ', nn).strip()
        # Убираем символы, запрещенные в именах файлов
        nn = self._remove_restricted_chars(nn)
        return nn


class FB2GroupRenamer:
    """
    Групповое переименование FB2 файлов
    """

    def __init__(self, startdir: str, outdir: str, template: str, debug: bool = False):
        """
        Конструктор
        :param startdir: Каталог, в котором нужно искать файлы FB2
        :param outdir: Дополнительный каталог в форме шаблона
        :param template: Шаблон переименования
        """
        self.startDir = Path(startdir)
        self.template = template
        self.debug = debug
        self.outDir = outdir
        if not self.startDir.is_dir():
            print('Error: Directory not exists: {0}'.format(self.startDir))
            return None

    def rename_all(self) -> int:
        counter = 0
        for item in list(self.startDir.glob('**/*.fb2')):
            renamer = FB2Renamer(item, self.template, self.outDir, self.debug)
            try:
                newName = renamer.rename()
                counter += 1
            except:
                print('Error: Cant rename to {0}'.format(newName))
        return counter


#
#  Если программа выполняется как главная
#
if __name__ == '__main__':
    _prog = 'PyFB2'
    _version = '1.0'
    _epilog = """
    Программа для разбора FB2
    """
    argparser = argparse.ArgumentParser(prog = _prog, description = 'Tools for FB2', epilog = _epilog)

    argparser.add_argument('--action', help = "Действие, которое необходимо выполнить." \
                                              "html - преобразовать файл FB2 в HTML\n" \
                                              "hyst - преобразовать файл FB2 в Hyst ",
                           choices = ['html', 'hyst', 'epub', 'rename', 'grouprename'], required = True)

    argparser.add_argument('-v', '--version', help = 'show version and exit', action = 'version',
                           version = '{0} {1}'.format(_prog, _version))
    argparser.add_argument('--verbose', help = 'verbose output', action = "store_true")
    argparser.add_argument("--file", type = str, default = "", help = "FB2 file name", action = 'store',
                           dest = 'file_name')
    argparser.add_argument("--dir", type = str, default = "", help = "Directory with FB2 files", action = 'store',
                           dest = 'indir')
    argparser.add_argument('--debug', help = 'show debug messages', action = 'store_true', dest = 'debug')

    argparser.add_argument("-c", help = "show contents tree", action = "append_const", const = 'c', dest = 'flags')
    argparser.add_argument("-a", help = "show Author(s) info", action = "append_const", const = 'a', dest = 'flags')
    argparser.add_argument("-t", help = "show title info", action = "append_const", const = 't', dest = 'flags')
    argparser.add_argument("-d", help = "show document info", action = "append_const", const = 'd', dest = 'flags')
    argparser.add_argument("-p", help = "show publisher info", action = "append_const", const = 'p', dest = 'flags')
    args = argparser.parse_args()

    if not args.file_name is None:
        fb2 = FB2Parser(args.file_name, argparser.debug)
        if fb2 is None:
            print('Error: Cant open file {0}'.format(args.file_name))
            exit(1)

    if (not args.flags is None) and (not fb2 is None):
        for flag in args.flags:
            if flag == 'a':
                print('----------- Author(s) -------------')
                authors = fb2.authors
                for author in authors:
                    print("  First name: ", fb2.author_first_name(author))
                    print(" Middle name: ", fb2.author_middle_name(author))
                    print("   Last name: ", fb2.author_last_name(author))
                    print("   Home page: ", fb2.author_home_page(author))
                    print("    Nickname: ", fb2.author_nickname(author))
                    print("          ID: ", fb2.author_id(author))
            if flag == 'c':
                print('-------- Contents ---------------')
            if flag == 't':
                print('------- Title Info --------------')
                print("      Title: ", fb2.title)
                print("       Lang: ", fb2.lang)
                print("Source Lang: ", fb2.src_lang)
                print("      Genre: ", fb2.genre)
                print(" Annotation: ", fb2.annotation)
                print("   Keywords: ", fb2.keywords)
                print("   Sequence: ", fb2.sequence_name)
                print(" Sequence #: ", fb2.sequence_number)
                print("       Date: ", fb2.title_info_date)
                print("      Cover: ", fb2.cover_page)
            if flag == 'd':
                print('------- Document info -----------')
                print('Author nickname: {0}'.format(fb2.doc_info_author_nickname))
                print('   Program used: {0}'.format(fb2.doc_info_program_used))
                print('       Date str: {0}'.format(fb2.doc_info_date_str))
                print('       Date val: {0}'.format(fb2.doc_info_date_str))
                print('     Source URL: {0}'.format(fb2.doc_info_src_url))
                print('     Source OCR: {0}'.format(fb2.doc_info_src_ocr))
                print('             ID: {0}'.format(fb2.doc_info_id))
                print('        Version: {0}'.format(fb2.doc_info_version))
                print('        History: {0}'.format(fb2.doc_info_history))
                print('       Publisher ID: {0}'.format(fb2.doc_info_pulisher_id))
                print('Publisher firstName: {0}'.format(fb2.doc_info_pulisher_first_name))
                print(' Publisher lastName: {0}'.format(fb2.doc_info_pulisher_last_name))
            if flag == 'p':
                print('------- Publisher info -----------')
                print('             City: {0}'.format(fb2.publish_info_city))
                print('             Year: {0}'.format(fb2.publish_info_year))
                print('             ISBN: {0}'.format(fb2.publish_info_isbn))
                print('         Bookname: {0}'.format(fb2.publish_info_bookname))
                print('        Publisher: {0}'.format(fb2.publish_info_publisher))
                print('         Sequence: {0}'.format(fb2.publish_info_sequence))
