# -*- coding: utf-8 -*-
import base64
import posixpath
import re
import sqlite3
import string
from abc import abstractmethod
from xml.etree import ElementTree
from xml.etree.ElementTree import Element

from pyFB2.FB2Parser import FB2Parser


class FB2ConvertBase:
    dbconn: object
    debug: bool
    parser: FB2Parser
    level: int  # уровень вложенности глав
    counter: int  # счетчик записей, служит для заполнения SeqNo
    root_id: int  # идентификатор корневого узла
    html_header: str = '<html xml:lang = "ru-ru" lang = "ru-ru">\n' \
                       '  <head>\n' \
                       '     <link rel="stylesheet" href="$CSS$" type="text/css" />\n' \
                       '     <meta http-equiv = "content-type" content = "text/html; charset=utf-8" />\n' \
                       '     <title>$title$</title >\n' \
                       '  </head>\n'

    def __init__(self, filename: str, css: str = None, debug=False):
        if filename is None:
            raise RuntimeError('Не указан входной файл.')
        self.debug = debug
        self.css = css
        self.parser = FB2Parser(filename, self.debug)
        if self.parser is None:
            return
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
        self.debugmsg('\tЗапись картинок на диск:')
        result = []
        images = self.parser.get_binaries()
        for image in images:
            image_id = image.attrib["id"]  # это имя файла, например cover.jpg
            content_type = image.attrib["content-type"]  # сейчас не используется
            bin_data = base64.b64decode(image.text)  # перекодируем из BASE64 в бинарный формат
            file_name = posixpath.join(path, image_id)  # формируем имя файла
            with open(file_name, 'w+') as file:  # открываем бинарный (b) файл для записи (w)
                file.write(bin_data)
                file.close()
                result += [file_name]
                self.debugmsg(f'\t{file_name}')
        return result

    def write_binaries(self, outdir: str):
        self.debugmsg('-> write_binaries')
        self.debugmsg('\tЗапись изображений из БД на диск')
        _cursor = self.dbconn.cursor()
        for row in _cursor.execute('select ShortDescr, image from note_image'):
            _filename = posixpath.join(outdir, row[0])
            _bindata = sqlite3.Binary(row[1])
            self.debugmsg(f'\t{_filename}')
            with open(_filename, 'w') as _file:
                _file.write(_bindata)
                _file.close()
        _cursor.close()

    def write_html(self, outdir: str):
        """
        Запись HTML на диск

        """
        self.debugmsg('-> write_html')
        self.debugmsg('\tЗапись HTML на диск')
        cursor = self.dbconn.cursor()
        sql = 'select id, text, length(text) from note'
        for row in cursor.execute(sql):
            if int(row[2]) > 0:
                _strid = str(row[0]).zfill(4)  # число, выровненное нулями слева до 4
                _filename = posixpath.join(outdir, f'ch_{_strid}.html')
                _bin_data = sqlite3.Binary(row[1])
                self.debugmsg(f'\t{_filename}')
                with open(_filename, 'w+') as _file:
                    _file.write(_bin_data)
                    _file.close()
        cursor.close()

    def insert_images(self, book_id=0):
        """
        Запись картинок в БД
        """
        self.debugmsg('Запись картинок в БД:')
        images = self.parser.get_binaries()
        for image in images:
            image_id = image.attrib["id"]  # это имя файла, например cover.jpg
            content_type = image.attrib["content-type"]  # сейчас не используется
            _bin_data = base64.b64decode(image.text)  # перекодируем из BASE64 в бинарный формат
            # имя файла ПОКА помещаем в поле short_descr
            last_id = self.insert_image(shortdescr=image_id, image=_bin_data, calc_md5=True, book_id=book_id)
            self.debugmsg(f'\tid={last_id} filename={image_id}')

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
                NotebookID INTEGER       REFERENCES notebook (id),
                SeqNo      INTEGER       DEFAULT (1000000),
                Name       VARCHAR (255) NOT NULL,
                Link       VARCHAR (255),
                ShortDescr TEXT,
                Text       TEXT,
                State      CHAR (1)      NOT NULL DEFAULT A,
                TextType   VARCHAR (10)  DEFAULT HTML,
                Tags       TEXT);""")
        self.dbconn.execute("""CREATE INDEX IF NOT EXISTS idx_note_parentid ON note (NotebookID, ParentID, state)""")

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

        self.dbconn.execute("""CREATE TRIGGER IF NOT EXISTS image_update_md5
                                 AFTER UPDATE OF image
                                 ON note_image
                                 FOR EACH ROW
                               BEGIN
                                 UPDATE note_image
                                    SET md5 = md5(image) 
                                  WHERE id = new.id;
                               END;""")

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
        self.debugmsg('Создание представления V_SIZES')
        self.dbconn.execute("""CREATE VIEW IF NOT EXISTS v_sizes AS
              SELECT 'Текст' AS Object,
                     sum(length(text) ) / 1024 AS Size
                FROM note
              UNION ALL
              SELECT 'Изображения' AS Object,
                     sum(length(image) ) / 1024 AS Size
                FROM note_image
              UNION ALL
              SELECT 'CSS' AS Object,
                     sum(length(css) ) / 1024 AS Size
                FROM css;""")

    def backup_memory_db(self, filename: str):
        """
        Создает на диске БД SQLite3 - бэкап для in-memory БД
        :param filename: Имя файла БД, вновь созданного на диске
        """
        self.debugmsg('Запись БД :memory: на диск')
        self.debugmsg(f'\tСоединение с БД {filename}')
        _disk_conn = sqlite3.connect(filename)

        self.debugmsg(f'\tСоздание бэкапа из памяти в БД {filename}')
        self.dbconn.backup(_disk_conn)

        self.debugmsg(f'\tЗакрытие БД {filename}')
        _disk_conn.close()

    def insert_notebook(self, name: str, short_descr: str = '') -> int:
        """
        Вставка новой записной книжки

        :param name:  Имя записной книжки
        :param short_descr: Короткое описание

        :return: Идентификатор записной книжки
        """
        _sql = 'insert into notebook (name, ShortDescr) values (?, ?)'
        _cursor = self.dbconn.cursor()
        _cursor.execute(_sql, [name, short_descr])
        self.dbconn.commit()
        return _cursor.lastrowid

    def insert_note(self, title: str, parent_id: int, text: str, notebook_id: int) -> int:
        """ Вставляет в таблицу NOTE запись """
        _new_title = title.strip('\n\t ')
        _new_title = re.sub("\s\s+", " ", _new_title)
        _new_title = _new_title.replace('\n', '')
        _cursor = self.dbconn.cursor()
        _sql = 'insert into note (ParentID, NotebookID, SeqNo, name, text) values (?, ?, ?, ?, ?)'
        _cursor.execute(_sql, [parent_id, notebook_id, self.counter, _new_title.encode('utf-8'), str(text)])
        self.dbconn.commit()
        _lastrowid = _cursor.lastrowid
        _cursor.close()
        return _lastrowid

    def insert_image(self, shortdescr: str, image: bytes, calc_md5=True, book_id=0) -> int:
        """
        Вставляет в таблицу NOTE_IMAGE изображение
        Возвращает идентификатор записи.
        :TODO: Надо по вычисленной контрольной сумме MD5 провести поиск уже существующих изображений и вернуть ID найденного. Это позволит сэкономить место за счет изображений-дубликатов
        :TODO: thumbnail пока не заполняется. Надо помещать туда уменьшенную копию изображения если оно больше некоторого предела. Какого? Это можно параметризовать.

        """
        md5 = ''
        _cursor = self.dbconn.cursor()
        """  Вот это не работает. Лобовое решение. Надо разбираться.
        if calc_md5:
            md5 = hashlib.md5(image).hexdigest()
            sql = 'select id from note_image where md5 = ?'
            for row in cursor.execute(sql, [md5]):
                if not row[0] is None:
                    print('', int(row[0]))
                    return int(row[0])
        """
        _cursor.execute('insert into note_image (ShortDescr, image, md5, book_id) values (?, ?, ?, ?)',
                       [shortdescr, sqlite3.Binary(image), md5, book_id])
        self.dbconn.commit()
        _lastrowid = _cursor.lastrowid
        _cursor.close()
        return _lastrowid

    def replace_img_links(self, section: Element):
        """
        Заменяет в указанной секции ссылки на бинарные данные на ссылки на файлы на диске
        :TODO: Надо литерал {http://www.w3.org/1999/xlink} заменить на значение из заголовка
        """
        self.debugmsg('-> replace_img_links')
        src = ''
        _images = section.findall('./image') + section.findall('./*/image') + section.findall('./**/image')
        for image in _images:
            image.tag = 'img'
            image_name = image.attrib['{http://www.w3.org/1999/xlink}href'].replace('#', '')
            src = '../img/{0}'.format(image.attrib['{http://www.w3.org/1999/xlink}href'].replace('#', ''))
            _cursor = self.dbconn.cursor()
            sql = 'select id from note_image where book_id=? and ShortDescr=?'
            self.debugmsg(f'root: {self.root_id} image {image_name}')
            for row in _cursor.execute(sql, [self.root_id, image_name]):
                src = f'db://thisdb.note_image.image.{row[0]}'
            _cursor.close()
            del image.attrib['{http://www.w3.org/1999/xlink}href']
            if src > '':
                image.set('src', src)

    def insert_child_sections(self, section, parent: int, notebook_id: int):
        """ Вставляет заголовки и главы в in-memory БД """
        sections = self.parser.get_sections(section)
        for section in sections:
            self.replace_img_links(section=section)
            self.level += 1
            title = self.get_titles_str(section)
            xmlstr = ElementTree.tostring(section, 'utf-8')
            xmlstr = self.replace_fb2_html(str(xmlstr.decode('utf-8')), self.level, title)
            if self.parser.is_flat_section(section):
                self.counter += 1
                if self.parser.is_section_wo_title(section):
                    self.update_parent_note(parent, xmlstr)
                else:
                    parent_id = self.insert_note(title, parent, xmlstr, notebook_id)
            else:
                parent_id = self.insert_note(title, parent, '', notebook_id)
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
            text0 = str(row0[0]) + text

        cursor = self.dbconn.cursor()
        sql = 'update note set text=? where id=?'
        cursor.execute(sql, [sqlite3.Binary(text0.encode('utf-8')), parent])
        self.dbconn.commit()
        cursor0.close()
        cursor.close()

    def insert_root_section(self, notebook_id: int) -> int:
        """ Вставляет в in-memory БД корневой узел """
        self.debugmsg('-= insert_root_section - Запись корневого узла =-')
        self.debugmsg(f'\troot_id: {self.root_id}')
        self.debugmsg(f'\tЗаголовок: {self.parser.title}')
        self.debugmsg(f'\tАннотация: {self.parser.annotation}')
        # применение encode позволяет передать в INSERT тип bytes (как он и ожидает), а не str
        self.root_id = self.insert_note(self.parser.title, 0, self.parser.annotation,
                                        notebook_id)
        return self.root_id

    def replace_fb2_html(self, fb2str: bytes, level: int, title: bytes) -> bytes:
        """ Заменяет тэги FB2 на тэги HTML """

        result = fb2str
        result = result.replace('<section>', '<body>')
        result = result.replace('<section', '<body')
        result = result.replace('</section>', '</body>')
        result = result.replace('<title>', str('<h{0}>'.format(level)))
        result = result.replace('</title>', str('</h{0}>'.format(level)))
        result = result.replace('<empty-line />', '<br>')
        result = result.replace('<subtitle>', '<p class="subtitle"><b>')
        result = result.replace('</subtitle>', '</b></p>')
        result = result.replace('<strong>', '<b>')
        result = result.replace('</strong>', '</b>')
        result = result.replace('<poem>', '<pre class="poem">')
        result = result.replace('</poem>', '</pre>')
        result = result.replace('<stanza>', '<div class="stanza">')
        result = result.replace('</stanza>', '</div>')
        result = result.replace('<v>', '')
        result = result.replace('</v>', '<br>')
        result = result.replace('<epigraph>', '<div class="epigraph" align="left">')
        result = result.replace('</epigraph>', '</div>')
        result = result.replace('<emphasis>', '<div class="emphasis" align="left">')
        result = result.replace('</emphasis>', '</div>')
        result = result.replace('<text-author>', '<p class="text-author" align="left">"')
        result = result.replace('</text-author>', '</p>')
        # <cite> </cite>

        result = self.html_header + result + '</html>'
        result = result.replace('$title$', title)

        # result = result.replace('$CSS$', bytes('./../css/{0}'.format(self.css_filename).encode('utf-8')))
        result = self.replace_css(result, bytes('./../css/{0}'.format(self.css_filename).encode('utf-8')))
        return result

    def merge_bodies(self, body1: Element, body2: Element) -> Element:
        """
        Выполняет слияние двух элементов body
        """
        pass

    def merge_sections(self, section1, section2):
        """
        Выполняет слияние двух элементов section
        """
        pass

    @property
    def css_filename(self):
        return posixpath.split(self.css)[1] if not self.css is None else None

    @abstractmethod
    def copy_css(self) -> bool:
        pass

    @abstractmethod
    def replace_css(self, text: str, css: str) -> str:
        pass
