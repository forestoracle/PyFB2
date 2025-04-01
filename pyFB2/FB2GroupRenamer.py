# -*- coding: utf-8 -*-
from pathlib import Path
from pyFB2.FB2Renamer import FB2Renamer


class FB2GroupRenamer:
    """
    Групповое переименование FB2 файлов
    """

    def __init__(self, start_dir: str, out_dir: str, template: str, debug: bool = False):
        """
        Конструктор

        :param start_dir: Каталог, в котором нужно искать файлы FB2
        :param out_dir: Дополнительный каталог в форме шаблона
        :param template: Шаблон переименования
        """
        self.startDir = Path(start_dir)
        self.template = template
        self.debug = debug
        self.outDir = out_dir
        if not self.startDir.is_dir():
            print(f'Ошибка: Каталог не существует: {self.startDir}')
            return

    def rename_all(self, recursive: bool = False) -> int:
        """
        Выполнить переименование файлов.

        :param recursive: Выполнить переименование рекурсивно. По умолчанию False.
        :returns: Количество переименованных файлов.
        """
        _counter = 0
        _mask = '*.fb2'
        if recursive:
            _mask = '**/*.fb2'
        for _item in list(self.startDir.glob(_mask)):
            _renamer = FB2Renamer(_item.name, self.template, self.outDir, self.debug)
            _new_name = ''
            try:
                _new_name = _renamer.rename()
                _counter += 1
            except:
                print(f'Ошибка: Не удалось переименовать в {_new_name}')
        return _counter
