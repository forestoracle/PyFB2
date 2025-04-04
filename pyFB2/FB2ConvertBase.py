# -*- coding: utf-8 -*-
import base64
import posixpath
import sqlite3
from abc import abstractmethod
from xml.etree import ElementTree
from xml.etree.ElementTree import Element

from pyFB2.FB2Parser import FB2Parser
from pyFB2.HystDB import HystDB


class FB2ConvertBase:
    html_header: str = '<html xml:lang = "ru-ru" lang = "ru-ru">\n' \
                       '  <head>\n' \
                       '     <link rel="stylesheet" href="$CSS$" type="text/css" />\n' \
                       '     <meta http-equiv = "content-type" content = "text/html; charset=utf-8" />\n' \
                       '     <title>$title$</title >\n' \
                       '  </head>\n'

    def __init__(self, filename: str, css: str = None):
        """
        Конструктор класса
        :param filename: Файл Fb2
        :param css: Файл CSS
        """
        self.parser = FB2Parser(filename=filename, check_schema=True)  # наличие файла не проверяем, это сделает парсер
        self.hyst_db = HystDB()  # имя БД не передаем, все делаем в памяти
        self.css = css
        self.level = 0
        self.counter = 0
        self.root_id = 0

    @staticmethod
    def remove_restricted_chars(value: str) -> str:
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

    def write_binaries_on_disk(self, path: str) -> []:
        """
        Записывает бинарные файлы на диск. Файлы ожидаются в формате BASE64
        и перекодируются в бинарный формат.
        :param path: Путь, по которому будут сохраняться бинарные файлы.
        :return: Список сохраненных файлов.
        """
        result = []
        images = self.parser.get_binaries()
        for image in images:
            image_id = image.attrib["id"]  # это имя файла, например cover.jpg
            content_type = image.attrib["content-type"]  # сейчас не используется, содержит типа такого image/jpeg
            bin_data = base64.b64decode(image.text)  # перекодируем из BASE64 в бинарный формат
            file_name = posixpath.join(path, image_id)  # формируем имя файла
            with open(file_name, 'w+b') as file:  # открываем бинарный (b) файл для записи (w)
                file.write(bin_data)
                result += [file_name]
        return result

    def write_html(self, path: str):
        """
        Записывает все заметки из БД Hyst как HTML файлы.
        :param path: Путь, по которому будут записываться файлы HTML
        """
        for _note in self.hyst_db.get_notes():
            with open(posixpath.join(path, f'ch_{str(_note["id"]).zfill(4)}.html'), 'wb') as _file:
                _file.write(self.hyst_db.get_note(_note.get("id")))

    def insert_images(self, book_id=0):
        """
        Запись картинок в БД
        """
        images = self.parser.get_binaries()
        for image in images:
            image_id = image.attrib["id"]  # это имя файла, например cover.jpg
            content_type = image.attrib["content-type"]  # сейчас не используется
            _bin_data = base64.b64decode(image.text)  # перекодируем из BASE64 в бинарный формат
            # имя файла ПОКА помещаем в поле short_descr
            last_id = self.insert_image(short_descr=image_id, image=_bin_data)

    def insert_notebook(self, name: str, short_descr: str = '') -> int:
        """
        Вставка новой записной книжки
        :param name:  Имя записной книжки
        :param short_descr: Короткое описание
        :return: Идентификатор записной книжки
        """
        return self.hyst_db.insert_notebook(name=name, short_descr=short_descr)

    def insert_note(self, title: str, parent_id: int, text: str, notebook_id: int) -> int:
        return self.hyst_db.insert_note(title=title,
                                        parent_id=parent_id,
                                        text=text,
                                        seq_no=self.counter,
                                        notebook_id=notebook_id)

    def insert_image(self, short_descr: str, image: bytes) -> int:
        """
        Вставляет в таблицу NOTE_IMAGE изображение
        Возвращает идентификатор записи.

        :param short_descr: Короткое описание
        :param image: Изображение
        :return: Идентификатор изображения
        """
        return self.hyst_db.insert_image(short_descr=short_descr, image=image)

    def replace_img_links(self, section: Element):
        """
        Заменяет в указанной секции ссылки на бинарные данные на ссылки на файлы на диске
        :TODO: Надо литерал {http://www.w3.org/1999/xlink} заменить на значение из заголовка
        """
        src = ''
        _images = section.findall('./image') + section.findall('./*/image') + section.findall('./**/image')
        for image in _images:
            image.tag = 'img'
            image_name = image.attrib['{http://www.w3.org/1999/xlink}href'].replace('#', '')
            src = '../img/{0}'.format(image.attrib['{http://www.w3.org/1999/xlink}href'].replace('#', ''))

            _cursor = self.hyst_db.connection.cursor()

            sql = 'select id from note_image where book_id=? and ShortDescr=?'
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
            xml_str = ElementTree.tostring(section)
            xml_str = self.replace_fb2_html(str(xml_str.decode('utf-8')), self.level, title)
            if self.parser.is_flat_section(section):
                self.counter += 1
                if self.parser.is_section_wo_title(section):
                    self.update_parent_note(parent, xml_str)
                else:
                    parent_id = self.insert_note(title, parent, xml_str, notebook_id)
            else:
                parent_id = self.insert_note(title, parent, '', notebook_id)
                self.insert_child_sections(section, parent_id, notebook_id)  # рекурсивный вызов самой себя
            self.level -= 1

    def update_parent_note(self, parent_id: int, text: str):
        """

        :TODO: Вот здесь надо не просто обновлять, а сливать секции
        :param parent_id:
        :param text:
        :return:
        """
        text0 = self.hyst_db.get_note_text(note_id=parent_id)
        self.hyst_db.update_note_text(note_id=parent_id, text=text0.join(text))

    def insert_root_section(self, notebook_id: int) -> int:
        """ Вставляет в in-memory БД корневой узел """
        # применение encode позволяет передать в INSERT тип bytes (как он и ожидает), а не str
        self.root_id = self.insert_note(self.parser.title, 0, self.parser.annotation,
                                        notebook_id)
        return self.root_id

    def replace_fb2_html(self, fb2str: str, level: int, title: str) -> str:
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
        # result = self.replace_css(result, bytes('./../css/{0}'.format(self.css_filename).encode('utf-8')))
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
