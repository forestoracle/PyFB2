# -*- coding: utf-8 -*-
import os
import re
import string

from pyFB2.FB2Parser import FB2Parser


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
        self.debug = debug
        self.filename = filename
        self._get_fb2_properties()  # получить свойства FB2-файла
        self.outdir = self._process_template(outdir)  #
        self.new_path = os.path.join(os.path.split(os.path.abspath(filename))[0], self.outdir)
        self.new_filename = '{0}.fb2'.format(self._process_template(template))

    def rename(self) -> str:
        """
        Выполняет переименование файла
        """
        os.makedirs(self.new_path, exist_ok=True)
        try:
            os.rename(self.filename, os.path.join(self.new_path, self.new_filename))
        except:
            raise RuntimeError(f'Ошибка: Не удалось переименовать [{self.filename}] в [{self.new_filename}]')

        return self.new_filename

    def _get_fb2_properties(self):
        """
        Выполняет извлечение свойств FB2 файла
        :TODO: Что делать, если авторов несколько?
        """
        parser = FB2Parser(filename=self.filename, check_schema=False)

        self.S = parser.sequence_name
        self.SN = parser.sequence_number
        self.Tt = parser.title
        self.T = self.Tt.upper()
        self.t = self.Tt.lower()
        authors = parser.authors
        # :TODO: Надо оптимизировать, слишком длинно
        for author in authors:
            self.AL = parser.author_last_name(author)
            if not self.AL is None: self.AL = self.AL.upper()

            self.AF = parser.author_first_name(author)
            if not self.AF is None: self.AF = self.AF.upper()

            self.AM = parser.author_middle_name(author)
            if not self.AM is None: self.AM = self.AM.upper()
            # Authors Last name
            self.AL = self.AL.strip() if not self.AL is None else ''
            # Authors First name
            self.AF = self.AF.strip() if not self.AF is None else ''
            # Authors Middle name
            self.AM = self.AM.strip() if not self.AM is None else ''
            self.F = f'{self.AF[0]}.' if self.AF > '' else ''
            self.M = f'{self.AM[0]}.' if self.AM > '' else ''
            self.al = self.AL.lower()
            self.af = self.AF.lower()
            self.am = self.AM.lower()
            self.Al = self.AL.capitalize()
            self.Af = self.AF.capitalize()
            self.Am = self.AM.capitalize()
            break
        del parser

    @staticmethod
    def _remove_restricted_chars(value: str) -> str:
        """
        Удаляет из строки символы, запрещенные для использования в именах файлов
        :param value: Строка, из которой нужно удалить запрещенные символы
        :return: Строка, из которой удалены запрещенные символы
        """
        for c in '\/:*?"<>|': value = value.replace(c, '')
        return value

    def _process_template(self, template: str) -> str:
        _substitution = {'S': self.S, 'SN': self.SN, 'AM': self.AM, 'AF': self.AF,
                         'AL': self.AL, 'Al': self.Al, 'Am': self.Am, 'Af': self.Af,
                         'al': self.al, 'am': self.am, 'af': self.af, 'F': self.F,
                         'M': self.M, 'T': self.T, 't': self.t, 'Tt': self.Tt
                         }
        _new_name = string.Template(template).substitute(_substitution)
        # Заменяем цепочку пробелов на один пробел
        _new_name = re.sub('\s\s+', ' ', _new_name).strip()
        # Убираем символы, запрещенные в именах файлов
        _new_name = self._remove_restricted_chars(value=_new_name)
        return _new_name
