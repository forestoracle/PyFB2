# -*- coding: utf-8 -*-
import os
import re
import shutil
from xml.etree import ElementTree

from pyFB2.FB2ConvertBase import FB2ConvertBase


class FB2HTML(FB2ConvertBase):
    """
    Класс для преобразования файла **FB2** в файлы **HTML**
    """

    def __init__(self, filename: str, css: str = None, debug: bool = False):
        """
        Конструктор класса **FB2HTML**

        :param filename: Имя файла FB2
        :param css: Имя файла CSS
        :param debug: Включить отладку. По умолчанию False - отладка отключена
        """
        super().__init__(filename=filename, css=css, debug=debug)
        self._new_outdir: str = ''
        self._img_outdir: str = ''
        self._htm_outdir: str = ''
        self._css_outdir: str = ''

    def count_children(self, parent_id) -> int:
        """
        Подсчитывает количество прямых потомков у указанного узла

        :param parent_id: Идентификатор родительского узла
        :returns: Количество прямых потомков у узла
        """
        _cursor = self.dbconn.cursor()
        _retval = 0
        for row in _cursor.execute('select count(1) as cnt from note where ParentID = ?', [parent_id]):
            _retval = int(row[0])
        _cursor.close()
        return _retval

    def create_contents_list(self, parent_id: int) -> str:
        """
        Создает содержание книги

        :param parent_id: Идентификатор корневого узла, с которого нужно начать
        :returns: Строку с содержание книги в формате HTML
        """
        if self.count_children(parent_id) == 0:
            return ''

        _cursor = self.dbconn.cursor()
        _sql = 'select id, name, length(text) from note where ParentID = ? order by id asc'
        self.contents.write(b'\n<ul>')
        for _row in _cursor.execute(_sql, [parent_id]):
            _note_size = int(_row[2])
            _strid = str(_row[0]).zfill(4)
            if _note_size > 0:
                _result = bytes(
                    '\n<li><a href=html/{0}>{1}</a></li>'.format('ch_{0}.html'.format(_strid), _row[1]).encode('utf-8'))
            else:
                _result = bytes(
                    '\n<li>{0}</li>'.format(_row[1]).encode('utf-8'))

            self.contents.write(_result)
            self.create_contents_list(_row[0])

        _cursor.close()
        self.contents.write(b'\n</ul>')

    def write_contents_header(self):
        """

        :returns:
        """
        _contents_header = self.html_header
        _contents_header = self.replace_css(_contents_header, f'./css/{self.css_filename}')
        _contents_header = _contents_header.replace('$title$', self.parser.title)
        self.contents.write(_contents_header.encode('utf-8'))
        self.contents.write('\n<p><img src="./img/{0}"></p>'.format(self.parser.cover_page).encode('utf-8'))
        for author in self.parser.authors:
            self.contents.write(
                # :TODO: Проверить, почему только для отчества вызывается decode()?
                bytes('<h1 class="author">{0} {1} {2}</h1>\n'.format(self.parser.author_last_name(author),
                                                                     self.parser.author_first_name(author),
                                                                     self.parser.author_middle_name()).encode('utf-8')))

    def create_dirs(self, outdir: str, html_dir='html', image_dir='img', css_dir='css') -> bool:
        """
        Создает каталоги для файлов **HTML**, **CSS** и изображений.

        :param outdir: Каталог для размещения книги.
        :param html_dir: Каталог для файлов HTML
        :param image_dir: Каталог для файлов изображений
        :param css_dir: Каталог для файлов CSS
        :returns: True если каталоги созданы. False в противном случае.
        """
        # имя автора
        _author_name = self.remove_restricted_chars(
            '{0} {1} {2}'.format(self.parser.author_last_name(), self.parser.author_first_name(),
                                 self.parser.author_middle_name())).strip(' ')
        # повторяющиеся пробелы заменяем на единственный пробел
        _author_name = re.sub("\s\s+", ' ', _author_name).strip()

        book_title = self.remove_restricted_chars('{0}'.format(self.parser.title)).strip(' ')
        self._new_outdir = os.path.join(outdir, _author_name, book_title)
        try:
            os.makedirs(self._new_outdir, exist_ok=True)
        except:
            print(f'Не удалось создать каталог {self._new_outdir}')
            return False

        self._img_outdir = os.path.join(self._new_outdir, image_dir)
        self._htm_outdir = os.path.join(self._new_outdir, html_dir)
        self._css_outdir = os.path.join(self._new_outdir, css_dir)
        try:
            os.makedirs(self._img_outdir, exist_ok=True)
            os.makedirs(self._htm_outdir, exist_ok=True)
            os.makedirs(self._css_outdir, exist_ok=True)
            return True
        except:
            return False

    def copy_css(self) -> bool:
        """
        Копирует файл CSS в его каталог

        :returns:  True - если файл скопирован
        """
        if self.css is None:
            return True
        try:
            self.debugmsg(f'Копирование CSS {self.css} -> {self._css_outdir}')
            shutil.copy2(src=self.css, dst=self._css_outdir)
            return True
        except:
            return False

    def replace_css(self, text: str, css: str) -> str:
        """
        Заменяет $CSS$ на ссылку на файл CSS

        :param text: Строка, в которой надо выполнить замену.
        :param css: Ссылка на CSS
        :returns: Строка с подстановкой
        """
        return text.replace('$CSS$', css)

    def create_html(self, outdir: str) -> int:
        """
        Запись файлов html и изображений в указанный каталог.

        :param outdir: Путь, по которому будут сохранены файлы (html и картинки).
                     Если не указан, то в текущем каталоге будет создан каталог с названием книги
                     (с исключенными символами, запрещенными для названий каталогов).
        :returns: Код ошибки. 0 если все прошло удачно

        """
        # подготовка каталогов
        if not self.create_dirs(outdir=outdir):
            print(f'Ошибка: Не удалось создать каталог {outdir}.')
            return 1
        if not self.copy_css():
            print(f'Ошибка: Не удалось скопировать CSS {self.css}')
            return 2

        # вставляем записную книжку, пока это только заглушка
        # для HTML она вообще не нужна
        _notebook_id = self.insert_notebook(self.parser.title)

        # вставляем корневой узел, все остальные будут его потомками
        self.root_id = self.insert_root_section(_notebook_id)

        # Проходим по всем секция типа body.
        # Их может быть много и у них могут быть заголовки, эпиграфы и т.д. как и у обычных секций
        # записываем в
        for body in self.parser.bodies:
            self.debugmsg('Тело-заметки: {0}'.format(self.parser.is_body_notes(body)))
            if self.parser.is_body_notes(body):
                if self.get_titles_str(body) == '':
                    _sections = body.findall('./section')
                    _sections_count = len(_sections)
                    self.debugmsg(f'\tКоличество секций: {_sections_count}')
                    if _sections_count > 3:
                        #
                        # Анализ примечаний
                        # Здесь это временно, нужно вынести в отдельную функцию
                        #
                        for section in _sections:
                            try:
                                id = section.attrib['id']
                                _cursor = self.dbconn.cursor()
                                _cursor.execute('insert into links (link_id) values (?)', [id])
                                self.dbconn.commit()
                            except:
                                print('Ошибка при вставке в таблицу LINKS')

                        self.insert_note(title='Примечания', parent_id=self.root_id,
                                         text=ElementTree.tostring(body, 'utf-8'), notebook_id=_notebook_id)

                    else:
                        for section in _sections:
                            self.insert_note(title=self.get_titles_str(section), parent_id=self.root_id,
                                             text=ElementTree.tostring(section, 'utf-8'),
                                             notebook_id=_notebook_id)

                else:
                    self.insert_note(title=self.get_titles_str(body), parent_id=self.root_id,
                                     text=ElementTree.tostring(body, 'utf-8'),
                                     notebook_id=_notebook_id)
            else:
                self.insert_child_sections(body, self.root_id,
                                           _notebook_id)  # перебор всех секций, 0 - идентификатор тела как корневого узла

        # Записываем в БД изображения
        # возможно, для HTML этот шаг лишний и пригодится только для Hyst
        # но пока так
        self.insert_images()

        # записываем изображения на диск
        self.write_binaries(self._img_outdir)

        self.write_html(self._htm_outdir)

        filename = os.path.join(self._new_outdir, 'index.html')
        self.contents = open(filename, 'wb')
        self.write_contents_header()
        self.create_contents_list(0)
        self.contents.close()
        return 0
