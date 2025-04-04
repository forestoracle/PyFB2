# -*- coding: utf-8 -*-
import sqlite3
import importlib.resources
import os
import hashlib


class HystDB:
    """
    Класс для работы с БД Hyst
    """

    def __init__(self, filename: str = None):
        """
        Создает новую БД в памяти или на диске.
        :param filename: Если не передано имя файла, то создается только in-memory БД
        """
        self._filename = filename if filename else ":memory:"
        self._connection = sqlite3.connect(self.filename)
        # Используем вот это https://docs.python.org/3.13/library/sqlite3.html#sqlite3-howto-row-factory
        self._connection.row_factory = sqlite3.Row
        self._create_tables()

    def integrity_check(self):
        ok = self._connection.execute("pragma integrity_check").fetchone()
        return ok == ("ok",)

    @property
    def filename(self):
        return self._filename

    @property
    def connection(self):
        return self._connection

    def close(self):
        self._connection.close()

    def _create_tables(self):
        """
        Создает таблицы БД Hyst.
        :return:
        """
        _sql_script_file = os.path.join(str(importlib.resources.files(__package__).joinpath("resources")),
                                        "create_tables.sql")
        with open(_sql_script_file) as f:
            self._connection.executescript(f.read())

    def set_database_name(self, name: str):
        """
        Записывает в БД Hyst ее название
        :param name: Название БД
        :return:
        """
        with self._connection as conn:
            conn.execute(f"insert into nb_profile (name) values ('{name}')")

    def is_memory_db(self) -> bool:
        return self.filename == ':memory:'

    def write_to_disk(self, filename: str):
        if self.is_memory_db():
            _new_connection = sqlite3.connect(filename)
            self._connection.backup(_new_connection)
            self._connection.close()
            self._connection = _new_connection
            self._filename = filename

    def insert_notebook(self, name: str, short_descr: str = '') -> int:
        """
        Вставка новой записной книжки
        :param name:  Имя записной книжки
        :param short_descr: Короткое описание
        :return: Идентификатор записной книжки
        """
        with self._connection as conn:
            return conn.execute('insert into notebook (name, ShortDescr) values (?, ?)',
                                [name, short_descr]).lastrowid

    def insert_note(self, title: str, parent_id: int, text: str, seq_no: int, notebook_id: int) -> int:
        """
        Вставляет в таблицу NOTE запись
        :param title: Заголовок статьи
        :param parent_id: Идентификатор родительской статьи
        :param text: Текст статьи
        :param seq_no: Порядковый номер статьи для упорядочивания в дереве
        :param notebook_id: Идентификатор записной книжки, к которой принадлежит статья
        :returns: Идентификатор статьи
        """
        _cursor = self._connection.cursor()
        _sql = 'insert into note (ParentID, NotebookID, SeqNo, name, text) values (?, ?, ?, ?, ?)'
        _cursor.execute(_sql, [parent_id, notebook_id, seq_no, title, text])
        self._connection.commit()
        _last_rowid = _cursor.lastrowid
        _cursor.close()
        return _last_rowid

    def insert_image(self, short_descr: str, image: bytes) -> int:
        """
        Вставляет в таблицу NOTE_IMAGE изображение
        :param short_descr: Короткое описание
        :param image: Изображение
        :return: Идентификатор изображения
        """
        _md5 = hashlib.md5(image).hexdigest()
        # Проверяем, есть ли такое изображение в БД
        _id = self._connection.execute(f'select id from note_image where md5 = {_md5}').fetchone()["id"]
        # Если есть, то возвращаем его ID
        if _id: return _id
        # Если нет такого изображения, то вставляем его
        with self._connection as conn:
            return conn.execute('insert into note_image (ShortDescr, image, md5) values (?, ?, ?)',
                                [short_descr, sqlite3.Binary(image), _md5]).lastrowid

    def update_image(self, image_id: int, short_desc: str, image: bytes):
        """
        Обновляет изображение в таблице **NOTE_IMAGE**
        :param image_id: Идентификатор изображения
        :param short_desc: Короткое описание
        :param image: Новое изображение
        :return:
        """
        # Здесь мы применяем self._connection как менеджер контекста.
        # https://docs.python.org/3.13/library/sqlite3.html#how-to-use-the-connection-context-manager
        with self._connection as conn:
            conn.execute('update note_image set ShortDescr=?, image=?, md5=? where id=?',
                         [short_desc, sqlite3.Binary(image), hashlib.md5(image).hexdigest(), image_id])

    def get_notes(self, parent_id: int = None) -> []:
        """
        Возвращает записи из таблицы **NOTE**. Если указан непустой **parent_id**, то возвращаются
        только записи, являющиеся дочерними по отношению к **parent_id**.
        **Не возвращает поле TEXT**
        :param parent_id: Идентификатор родительского узла
        :return: Идентификатор записи в таблице NOTE
        """
        _result = []
        _sql = "select id, name, length(text) as size from note"
        if parent_id:
            _sql = _sql + f" where parentID = {parent_id} order by id asc"

        for row in self._connection.execute(_sql):
            _result.append({"id": row["id"], "name": row["name"], "length": row["size"]})
        print("parent id: ", parent_id)
        return _result

    def get_children_count(self, parent_id: int) -> int:
        """
        Подсчитывает количество прямых потомков у указанного узла
        :param parent_id: Идентификатор родительского узла
        :returns: Количество прямых потомков у узла
        """
        return \
        self._connection.execute(f'select count(1) as counter from note where ParentID = {parent_id}').fetchone()[
            "counter"]

    def get_note_text(self, note_id: int) -> str:
        """
        Возвращает текст статьи по её идентификатору.
        :param note_id: Идентификатор статьи
        :return: Текст статьи
        """
        with self._connection.blobopen("NOTE", "TEXT", note_id) as blob:
            return blob.read().decode()

    def update_note_text(self, note_id:int, text: str):
        """
        Обновляет текст статьи.
        :param note_id: Идентификатор статьи
        :param text: Новый текст
        :return:
        """
        self._connection.execute(f"update note set text = '{text}' where id={note_id}")
        self._connection.commit()
