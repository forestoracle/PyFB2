# -*- coding: utf-8 -*-
from pathlib import Path
import sqlite3
from pyFB2.FB2Parser import FB2Parser

class FB2DirScaner:
    """
    :TODO: Выделить класс в отдельный файл когда буду собирать пакет
    """
    start_dir: Path
    dbconn: object

    def __init__(self, start_dir: str):
        self.start_dir = Path(start_dir)
        if not self.start_dir.is_dir():
            print(f'Каталог не существует: {self.start_dir}')
            return
        self.create_db()

    def create_db(self):
        try:
            self.dbconn = sqlite3.connect("authors.db")
        except IOError as err:
            raise RuntimeError(f'Ошибка ввода-вывода: {err}')

        self.dbconn.execute("""CREATE TABLE IF NOT EXISTS authors (
                        ID integer CONSTRAINT pk_notebook PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,
                        last_name varchar2(255), 
                        first_name varchar2(255), 
                        middle_name varchar2)
                        """)
        self.dbconn.execute("""CREATE UNIQUE INDEX idx_authors_names ON authors (
                            first_name,
                            last_name,
                            middle_name);
                            """)
        self.dbconn.execute("""CREATE TABLE IF NOT EXISTS works (
                            author_id integer, 
                            title varchar(1024),
                            file_name varchar(4096))
                            """)

    def get_author_id(self, ln, fn, mn) -> int:
        cursor = self.dbconn.cursor()
        sql = 'select id from authors where last_name=? and first_name=? and middle_name=?'
        id = 0
        for row in cursor.execute(sql, [ln, fn, mn]):
            id = row[0]
        cursor.close()
        return id

    def scan_dir(self):
        acursor = self.dbconn.cursor()
        asql = 'insert into authors (last_name, first_name, middle_name) values (?, ?, ?)'
        wcursor = self.dbconn.cursor()
        wsql = 'insert into works(author_id, title, file_name) values(?, ?, ?)'
        for item in list(self.start_dir.glob('**/*.fb2')):
            try:
                parser = FB2Parser(item)
                fn = str(parser.author_first_name()).strip()
                ln = str(parser.author_last_name()).strip()
                mn = str(parser.author_middle_name()).strip()
                try:
                    title = str(parser.title).strip()
                except:
                    title = ''
                acursor.execute(asql, [ln, fn, mn])
                lastrowid = acursor.lastrowid
            except Exception:
                # Если не удалось вставить запись из-за ограничения на уникальность
                # то нужно узнать идентификатор записи, которая не дала вставить нового автора
                lastrowid = self.get_author_id(ln, fn, mn)

            wcursor.execute(wsql, [lastrowid, title, str(item)])
            self.dbconn.commit()
