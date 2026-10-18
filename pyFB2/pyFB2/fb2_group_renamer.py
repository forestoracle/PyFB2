# -*- coding: utf-8 -*-
import logging
import sys
from pathlib import Path
from typing import List
from .fb2_renamer import FB2Renamer

logger = logging.getLogger(__name__)


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
            logger.error('Каталог не существует: %s', self.startDir)
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
            _new_name = ''
            try:
                _renamer = FB2Renamer(str(_item), self.template, self.outDir, self.debug)
                _new_name = _renamer.rename()
                _counter += 1
            except (OSError, RuntimeError):
                logger.error('не удалось переименовать %s в %s', _item, _new_name)
        return _counter


def main(argv: List[str] | None = None) -> int:
    if argv is None:
        argv = sys.argv
    if len(argv) < 4:
        print(
            "Использование: python fb2_group_renamer.py <входной каталог> <выходной каталог> <шаблон>",
            file=sys.stderr,
        )
        return 2

    # Ошибки переименования библиотека отдаёт через logging (в stderr);
    # basicConfig не переопределяет уже настроенное логирование.
    logging.basicConfig(level=logging.INFO, format="%(message)s")

    renamer = FB2GroupRenamer(start_dir=argv[1], out_dir=argv[2], template=argv[3])
    renamer.rename_all()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
