import argparse
import sqlite3
from pathlib import Path

from colored import fg, attr

from PyFB2 import FB2Hyst, FB2GroupRenamer, FB2HTML, FB2Parser

_prog = "Hyst FB2 tools"
_version = "0.9"
_epilog = """
          Программа для разбора FB2
          """

argparser = argparse.ArgumentParser(prog=_prog, description='Tools for FB2', epilog=_epilog)

argparser.add_argument('--action', help="Действие, которое необходимо выполнить." \
                                        "html - преобразовать файл FB2 в HTML\n" \
                                        "hyst - преобразовать файл FB2 в Hyst ",
                       choices=['edit', 'html', 'grouphtml', 'hyst', 'epub', 'rename', 'grouprename'], required=True,
                       dest='action')

argparser.add_argument('-v', '--version', help='показать версию и выйти', action='version',
                       version='{0} {1}'.format(_prog, _version))
group_src = argparser.add_mutually_exclusive_group()
group_dst = argparser.add_mutually_exclusive_group()

group_src.add_argument('--file', type=str, default=None, help="FB2 файл", action='store', dest='filename')

group_src.add_argument('--indir', type=str, default=None, help="Входной каталог с файлами FB2", action='store',
                       dest='indir')

group_dst.add_argument('--outdir', type=str, default=None, help="Каталог для записи результатов работы", action='store',
                       dest='outdir')

group_dst.add_argument('--hystdb', type=str, default=None, help='База данных Hyst', action='store', dest='hystdb')

argparser.add_argument('--debug', help='показывать отладочные сообщения', default=False, action='store_true',
                       dest='debug')


argparser.add_argument('--template', help='Шаблон для переименования', default=None, action='store',
                       dest='rename_template')

argparser.add_argument('--subaction', choices=['createdb', 'addbook', 'addnotebook', 'addnode', 'shownodes'],
                       help='Subaction', required=False, dest='subaction')

args = argparser.parse_args()


#
# --== CHECKS ==--
#
def check_file():
    if (args.filename) is None:
        print('{0}Не указано имя файла FB2. Используйте аргумент --file{1}'.format(fg(1), attr(0)))
        exit(101)


def check_file_exists():
    if not os.path.isfile(args.filename):
        print('{0}Указан несуществующий входной файл {1}{2} '.format(fg(1), args.filename, attr(0)))
        exit(105)




def check_outdir():
    if args.outdir is None:
        print('{0}Не указан выходной каталог. Используйте аргумент --outdir{1}'.format(fg(1), attr(0)))
        exit(106)


def check_tmpl():
    if args.rename_template is None:
        print('{0}Не указан шаблон для переименования {1}'.format(fg(1), attr(0)))
        exit(104)


def check_hystdb():
    if args.hystdb is None:
        print('{0}Не указана база Hyst {1}'.format(fg(1), attr(0)))
        exit(110)


#
#  --== ACTIONS ==--
#
#
# -=  Edit =-
#
if args.action == 'edit':
    print('{0}Действие:{1} EDIT{2}'.format(fg(4), fg(2), attr(0)))
    check_file()
    exit(0)

#
# -= HTML =-
#
if args.action == 'html':
    print('{0}Действие:{1} HTML{2}'.format(fg(4), fg(2), attr(0)))
    check_file()
    check_file_exists()
    check_outdir()
    html = FB2HTML(filename=args.filename, debug=args.debug)
    html.create_html(outdir=args.outdir)
    exit(0)

#
# -= Group HTML =-
#
if args.action == 'grouphtml':
    check_outdir()
    check_indir_exists()
    for item in list(Path(args.indir).glob('**/*.fb2')):
        try:
            html = FB2HTML(filename=item, debug=False)
            html.create_html(outdir=args.outdir)
        except:
            print('Ошибка: {0}'.format(item))
    exit(0)

#
# -=  Group Rename =-
#
if args.action == 'grouprename':
    print('{0}Действие:{1} GROUPRENAME{2}'.format(fg(4), fg(2), attr(0)))
    check_indir_exists()
    check_tmpl()
    print('          Входной каталог: {0}'.format(args.indir))
    print('Шаблон для переименования: {0}\n'.format(args.rename_template))
    ren = FB2GroupRenamer(start_dir=args.indir, outdir=args.outdir, template=args.rename_template, debug=args.debug)
    # Проверим, что объект создался и готов к работе
    if ren is None:
        exit(201)
    counter = ren.rename_all()
    print('\n     Переименовано файлов: {0}'.format(counter))
    exit(0)

#
# -=  Hyst =-
#
if args.action == 'hyst':
    print('{0}Действие:{1} HYST{2}'.format(fg(4), fg(2), attr(0)))
    check_file()
    check_file_exists()
    check_hystdb()
    hyst = FB2Hyst(database=args.hystdb, debug=args.debug)
    if hyst is None:
        print('{0}Ошибка создания/открытия БД {0}'.format(fg(4), args.hystdb, attr(0)))
        exit(202)
    if args.subaction == 'createdb':
        print('{0}  Создана БД: {1}{2}{3}'.format(fg(4), fg(2), args.hystdb, attr(0)))
        exit(0)
    if args.subaction == 'addnotebook':
        """
        :TODO: В add_notebook нужно заменить литералы на параметры
        """
        notebook_id = hyst.add_notebook(notebook_name='Notebook', short_descr='New notebook')
        memconn = sqlite3.connect(':memory:')
        memconn.execute('create table books (ln varchar2(100), fn varchar2(100), mn varchar2(100), book varchar2(1024), filename varchar2(4096))')
        cursor = memconn.cursor()
        sql = 'insert into books (ln, fn, mn, book, filename) values (?, ?, ?, ?, ?)'
        for item in list(Path('./sample/vm').glob('**/*.fb2')):
            p = FB2Parser(filename=item)
            cursor.execute(sql, [p.author_last_name(), p.author_first_name(), p.author_middle_name(), p.title, str(item)])
            memconn.commit()

        sql = 'select filename from books order by ln, fn, mn, book'
        for row in cursor.execute(sql):
            try:
                print('Файл: {0}'.format(row[0]))
                hyst.add_book_ext(filename=row[0], notebook_id=notebook_id)
            except:
                print('{0}Ошибка:{1} {2}'.format(fg(1), attr(0), row[0]))

        cursor.close()
        memconn.close()
        exit(0)
    exit(0)

