# -*- coding: utf-8 -*-
import sqlite3
from pyFB2.FB2ConvertBase import FB2ConvertBase
from pyFB2.FB2Parser import FB2Parser
import os

class FB2Hyst(FB2ConvertBase):
    """
    Класс для преобразования файла FB2 в БД Hyst
    """

    def __init__(self, database: str, name: str = None, css: str = None):
        """
        Конструктор класса FB2Hyst
        :param database: Имя файла БД
        :param name: Название БД
        :param css: Имя файла CSS
        :param debug: Включать отладку (True|False)
        """
        super().__init__()
        self.database = database
        self.css = css

    def merge_databases(self, src_db: str, dst_db: str, parent_id: int, notebook_id: int) -> int:
        """
        Сливает две БД в одну. Записи из src_db добавляются в dst_db
        Возвращает количество перенесенных записей.

        :param src_db      - БД - источник записей
        :param dst_db      - БД - приемник записей
        :param root_id     - идентификатор корневой записи, под кторотой будут размещены перенесенные записи
        :param notebook_id - идентификатор записной книжки

        """
        try:
            src_conn = sqlite3.connect(src_db)
        except:
            print('Ошибка: Не удалось соединиться с БД-источником {0}'.format(src_db))
            return 0

        try:
            src_conn = sqlite3.connect(dst_db)
        except:
            src_conn.close()
            print('Ошибка: Не удалось соединиться с БД-получателем {0}'.format(dst_db))
            return 0

    def create_db(self, name: str = None) -> object:
        """
        Создание БД
        :return:
        """

        self.dbconn = sqlite3.connect(self.database)
        self.create_tables()
        self.copy_css()
        if not name is None:
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
        :return: Идентификатор ЗК. None - если ЗК не найденне найдена
        """
        cursor = self.dbconn.cursor()
        sql = 'select min(id) as id from notebook where name = ?'
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
        notebook_id = self.get_notebook_id(notebook_name=notebook_name)
        if notebook_id is None:
            notebook_id = self.insert_notebook(notebook_name, short_descr)
            return notebook_id
        else:
            return notebook_id

    def get_author_id(self, author_name: str, notebook_id: int) -> int:
        """
        Возращает имя идентификатор автора по его имени и ид ЗК
        Имя автора формируется как LastName+FirstName+MiddleName
        :param author_name: Имя автора
        :param notebook_id: Идентификатор записной книжки
        :return:
        """
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
        author_id = self.get_author_id(author_name=author_name, notebook_id=notebook_id)
        if author_id is None:
            author_id = author_id = self.insert_note(title=author_name, parent_id=0, text=''.encode('utf-8'),
                                                     notebook_id=notebook_id)
            return author_id
        else:
            return author_id

    def get_book_id(self, title: str, author_id: int):
        cursor = self.dbconn.cursor()
        sql = 'select min(id) from note where ParentID = ? and name = ?'
        for row in cursor.execute(sql, [author_id, title]):
            return row[0]

    def get_book_cover(self) -> str:
        """
         Формирует обложку книги.
        :return: Тело обложки книги
        :TODO: 1. Иногда изображения обложки выглядят так <img src=db://thisdb.note_image.image.None>
               2. Некрасиво сделано сцепление строк - переписать
        """
        cursor = self.dbconn.cursor()
        sql = 'select min(id) from note_image where book_id=? and ShortDescr=?'
        for row in cursor.execute(sql, [self.root_id, self.parser.cover_page]):
            cover_image = '<img src="db://thisdb.note_image.image.{0}">'.format(row[0])
        result = self.replace_css(self.html_header, self.css)
        result = result.replace('$title$', self.parser.title)
        result = result + cover_image
        result = result + self.parser.annotation
        result = result + '</body></html>'
        return result

    def update_note(self, note_id: int, text: bytes):
        """

        :param note_id:
        :param text:
        :return:
        """
        cursor = self.dbconn.cursor()
        sql = 'update note set text = ? where id = ?'
        cursor.execute(sql, [text, note_id])
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
            self.parser = FB2Parser(filename=filename, check_schema=False)

        book_id = self.get_book_id(title=self.parser.title, author_id=author_id)
        if not book_id is None:
            return book_id


        self.root_id = self.insert_note(self.parser.title, author_id, '', notebook_id)
        book_id = self.root_id
        self.insert_images(book_id=book_id)

        self.update_note(note_id=self.root_id, text=self.get_book_cover())

        for body in self.parser.bodies:
            if self.parser.is_body_notes(body):
                if self.get_titles_str(body) == '':
                    sections = body.findall('./section')
                    sections_count = len(sections)
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

                        self.insert_note(title='Примечания', parent_id=self.root_id,
                                         #text=ElementTree.tostring(body, 'utf-8'), notebook_id=notebook_id)
                                         text=body, notebook_id=notebook_id)
                    else:
                        for section in sections:
                            self.insert_note(title=self.get_titles_str(section), parent_id=self.root_id,
                                             #text=ElementTree.tostring(section, 'utf-8'),
                                             text=section,
                                             notebook_id=notebook_id)

                else:
                    self.insert_note(title=self.get_titles_str(body), parent_id=self.root_id,
                                     text=body,
                                     notebook_id=notebook_id)
            else:
                self.insert_child_sections(body, self.root_id,
                                           notebook_id)  # перебор всех секций, 0 - идентификатор тела как корневого узла
        return book_id

    def add_book_ext(self, filename: str, notebook_id: int) -> int:
        """

        :param filename:  Добавляемый файл FB2
        :param notebook_id: К какой ЗК добавить
        :return:  Идентификатор добавленного узла
        """
        self.parser = FB2Parser(filename=filename, check_schema=False)
        author = '{0} {1} {2}'.format(self.parser.author_last_name(), self.parser.author_first_name(),
                                      self.parser.author_middle_name()).strip(' ')
        author_id = self.add_author(author, notebook_id)
        return self.add_book(filename=filename, author_id=author_id, notebook_id=notebook_id)

    def copy_css(self) -> bool:
        """
        Копирование файла CSS в БД
        :return: True если все прошло удачно
        :TODO: Более информативные сообщения
        """
        print(' -> copy_css')
        if self.css is None:
            print('     css is None')
            return True
        if not os.path.isfile(self.css):
            print('     not is file')
            return False
        print('     open file')
        with open(self.css, 'rb') as f:
            css_text = f.read()
            f.close()
        print('     cursor')
        cursor = self.dbconn.cursor()
        sql = 'insert into CSS (name, code, filename, css) values (?, ?, ?, ?)'
        cursor.execute(sql, [self.css_filename, self.css_filename, self.css_filename, sqlite3.Binary(css_text)])
        print('     insert')
        self.dbconn.commit()
        cursor.close()

    def replace_css(self, text: bytes, css: bytes) -> bytes:
        return text.replace('$CSS$', 'db://thisdb.css.css.1')

