# -*- coding: utf-8 -*-
import sqlite3
import importlib.resources
import os


class HystDB:
    """ Класс для работы с БД Hyst """
    def __init__(self, filename: str = None):
        """
        Создает новую БД в памяти или на диске.
        :param filename: Если не передано имя файла, то создается только in-memory БД
        """
        self._filename = filename if filename else ":memory:"
        self._connection = sqlite3.connect(self.filename)
        self._create_tables()

    @property
    def filename(self):
        return self._filename

    @property
    def connection(self):
        return self._connection

    def close(self):
        self._connection.close()

    def _create_tables(self):
        _sql_script_file = os.path.join(str(importlib.resources.files(__package__).joinpath("resources")),
                                        "create_tables.sql")
        with open(_sql_script_file) as f:
            self._connection.executescript(f.read())

    def set_database_name(self, name: str):
        self._connection.execute(f"insert into nb_profile (name) values ('{name}')")
        self._connection.commit()

    def is_memory_db(self) -> bool:
        return self.filename == ':memory:'

    def write_to_disk(self, filename: str):
        if self.is_memory_db():
            _new_connection = sqlite3.connect(filename)
            self._connection.backup(_new_connection)
            self._connection.close()
            self._connection = _new_connection
            self._filename = filename