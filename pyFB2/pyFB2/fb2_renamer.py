# -*- coding: utf-8 -*-
import os
import re
import sys
import string
from typing import List

from .fb2_errors import Fb2OperationError
from .fb2_parser import Fb2Parser


class FB2Renamer:
    """
    Класс для переименования ОДНОГО файла FB2 на основе шаблона.

    \nВ состав шаблона могут входить:
    \n**${AL}** - Фамилия автора  - верхний регистр
    \n**${AF}** - Имя автора      - верхний регистр
    \n**${AM}** - Отчество автора - верхний регистр
    \n**${Al}** - Фамилия автора  - капитализация
    \n**${Af}** - Имя автора      - капитализация
    \n**${Am}** - Отчество автора - капитализация
    \n**${al}** - Фамилия автора  - нижний регистр
    \n**${af}** - Имя автора      - нижний регистр
    \n**${am}** - Отчество автора - нижний регистр
    \n**${F}**  - Первая буква имени + .
    \n**${M}**  - Первая буква отчества + .
    \n**${T}**  - заголовок - верхний регистр
    \n**${t}**  - заголовок - нижний регистр
    \n**${Tt}** - заголовок - как в файле
    \n**${S}**  - серия (sequence)
    \n**${SN}** - номер в серии (sequence number)

    :param filename: Имя файла, который будет переименован
    :param template: Шаблон переименования
    :param outdir: дополнительный каталог в форме шаблона
    :param debug: выводить отладочные сообщения
    """

    def __init__(self, filename: str, template: str, outdir: str = '', debug: bool = False):
        """
        Конструктор класса для переименования файла FB2 по шаблону

        :param filename: Имя файла FB2
        :param template: Шаблон переименования
        :param outdir
        """
        self.Tt = ""
        self.S = ""
        self.SN = ""
        self.AL = ""
        self.AF = ""
        self.AM = ""
        self.debug = debug
        self.filename = filename
        self._get_fb2_properties()  # получить свойства FB2-файла
        self.outdir = self._process_template(outdir, keep_separators=True)  #
        self.new_path = os.path.join(os.path.split(os.path.abspath(filename))[0], self.outdir)
        self.new_filename = '{0}.fb2'.format(self._process_template(template))

    def rename(self) -> str:
        """
        Выполняет переименование файла
        """
        os.makedirs(self.new_path, exist_ok=True)
        _new_name = os.path.join(self.new_path, self.new_filename)
        try:
            os.rename(self.filename, _new_name)
        except OSError:
            raise Fb2OperationError(f'Ошибка: Не удалось переименовать [{self.filename}] в [{self.new_filename}]')

        return self.new_filename

    def _get_fb2_properties(self):
        """
        Выполняет извлечение свойств FB2 файла
        :TODO: Что делать, если авторов несколько?
        """
        parser = Fb2Parser(source=self.filename)
        try:
            description = parser.parse()
        except Exception as exc:  # noqa: BLE001 — файл может быть повреждён
            raise Fb2OperationError(
                f"Не удалось прочитать FB2-файл [{self.filename}]: {exc}"
            ) from exc

        ti = description.title_info
        if ti is None or ti.book_title is None:
            raise Fb2OperationError(f"В файле не найдено название книги: {self.filename}")

        # === Название ===
        self.Tt = ti.book_title.value
        self.T = self.Tt.upper()
        self.t = self.Tt.lower()

        # === Серия ===
        for seq in ti.sequences:
            self.S = seq.name
            self.SN = str(seq.number) if seq.number is not None else ""

        # === Автор(ы) ===

        authors = ti.authors
        for author in authors:
            self.AL = author.last_name.upper().strip() if author.last_name else ""
            self.AF = author.first_name.upper().strip() if author.first_name else ""
            self.AM = author.middle_name.upper().strip() if author.middle_name else ""

        self.al = self.AL.lower()
        self.af = self.AF.lower()
        self.am = self.AM.lower()

        self.Al = self.AL.capitalize()
        self.Af = self.AF.capitalize()
        self.Am = self.AM.capitalize()

        self.F = f'{self.AF[0]}.' if self.AF > '' else ''
        self.M = f'{self.AM[0]}.' if self.AM > '' else ''

    @staticmethod
    def _remove_restricted_chars(value: str, keep: str = '') -> str:
        """
        Удаляет из строки символы, запрещенные для использования в именах файлов
        :param value: Строка, из которой нужно удалить запрещенные символы
        :param keep: Символы, которые нужно сохранить (например, разделители каталогов)
        :return: Строка, из которой удалены запрещенные символы
        """
        for c in '/\\:*?"<>|':
            if c in keep:
                continue
            value = value.replace(c, '')
        return value

    def _process_template(self, template: str, keep_separators: bool = False) -> str:
        """
        Подставляет значения полей книги в шаблон имени.

        :param template: Шаблон переименования
        :param keep_separators: Сохранять ли разделители каталогов (для outdir)
        :return: Готовое имя файла (или относительный путь для outdir)
        """
        _substitution = {'S': self.S, 'SN': self.SN, 'AM': self.AM, 'AF': self.AF,
                         'AL': self.AL, 'Al': self.Al, 'Am': self.Am, 'Af': self.Af,
                         'al': self.al, 'am': self.am, 'af': self.af, 'F': self.F,
                         'M': self.M, 'T': self.T, 't': self.t, 'Tt': self.Tt
                         }
        _new_name = string.Template(template).substitute(_substitution)
        # Заменяем цепочку пробелов на один пробел
        _new_name = re.sub(' +', ' ', _new_name).strip()
        if keep_separators:
            # В outdir разделители каталогов значимы: сохраняем их и убираем
            # пробелы вокруг, чтобы получить корректный относительный путь.
            _new_name = re.sub(r'\s*([/\\])\s*', r'\1', _new_name)
            _new_name = _new_name.strip('/\\')
        # Убираем символы, запрещенные в именах файлов
        _new_name = self._remove_restricted_chars(
            value=_new_name, keep='/\\' if keep_separators else '')
        return _new_name

def main(argv: List[str] | None = None) -> int:
    if argv is None:
        argv = sys.argv
    if len(argv) < 4:
        print(
            "Использование: python fb2_renamer.py <файл.fb2> <шаблон> <папка>",
            file=sys.stderr,
        )
        return 2
    renamer = FB2Renamer(filename=argv[1], template=argv[2], outdir=argv[3])
    renamer.rename()
    return 0

if __name__ == "__main__":
    raise SystemExit(main(sys.argv))