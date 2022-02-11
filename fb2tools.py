"""
Версия: 2022-02-02

"""
import argparse
import os
import sqlite3

from PyFB2 import FB2GroupRenamer, FB2HTML, FB2Hyst, FB2Renamer
from PyZip import UnzipFB2


#
#  Разного рода проверки
#
def check_hystdb(args: argparse.Namespace):
    dbconn: sqlite3.Connection
    if args.hystdb is None:
        print('Не указана база Hyst')
        exit(110)
    try:
        dbconn = sqlite3.connect(args.hystdb)
    except:
        print('Не удалось подключиться к БД {0}'.format(args.hystdb))
        exit(111)
    dbconn.close()


def check_indir_exists(args: argparse.Namespace):
    if args.indir is None:
        print('Не указан входной каталог FB2. Используйте аргумент --indir{1}')
        exit(102)
    if not os.path.isdir(args.indir):
        print('Указан несуществующий входной каталог')
        exit(103)


def check_tmpl(args: argparse.Namespace):
    if args.rename_template is None:
        print('Не указан шаблон для переименования')
        exit(104)


def check_file_exists(args: argparse.Namespace):
    if not os.path.isfile(args.filename):
        print('Указан несуществующий входной файл {0}'.format(args.filename))
        exit(105)


#
#  Выполнение действий, указанных в командной строке как главное
#
def do_hyst(args: argparse.Namespace):
    print('\nПреобразование в формат Hyst.')
    print('  HystDB: {0}'.format(args.hystdb))
    # Эту проверку нужно выполнять тогда, когда БД уже существует
    # :TODO: Если команда подразумевает создание новой БД - эту проверку выполнять не надо.
    if args.subaction == 'createdb':
        hyst = FB2Hyst(args.hystdb)
        hyst.create_db()
        exit(0)
    else:
        check_hystdb(args)

    hyst = FB2Hyst(args.hystdb)
    #
    # Addbook
    #
    if args.subaction == 'addnotebook':
        notebook_id = hyst.get_notebook_id(notebook_name = args.notebook)
        if notebook_id is None:
            notebook_id = hyst.insert_notebook(name = args.notebook)
            print('Добавлена записная книжка {0}:{1}'.format(notebook_id, args.notebook))
        else:
            print('Записная книжка уже есть {0}:{1}'.format(notebook_id, args.notebook))

    if args.subaction == 'shownodes':
        cursor = hyst.dbconn.cursor()
        sql = 'select id, name from notebook order by id'
        for row in cursor.execute(sql):
            print('{0}:{1}'.format(row[0], row[1]))
        cursor.close()

    if args.subaction == 'addbook':
        notebook_id = hyst.get_notebook_id(args.notebook)
        if notebook_id is None:
            print('Не найдена записная книжка: {0}'.format(args.notebook))
            exit(200)
        book_id = hyst.add_book_ext(filename = args.filename, notebook_id = notebook_id)
        print('Добавлена книга {0}:{1}'.format(book_id, args.filename))


def do_rename(args: argparse.Namespace):
    print('\nПереименование файла.')
    print('    Файл: {0}\n  Шаблон: {1}'.format(args.filename, args.rename_template))
    check_file_exists(args)
    check_tmpl(args)
    renamer = FB2Renamer(filename = args.filename, template = args.rename_template, outdir = args.outdir)
    # Проверим, что объект создался и готов к работе
    if renamer is None:
        print('Ошибка открытия файла {0}'.format(args.filename))
        exit(201)
    new_name = renamer.rename()
    print('\n     Новое имя файла: {0}'.format(new_name))


def do_grouprename(args: argparse.Namespace):
    print('\nГрупповое переименование файлов.')
    print('  Каталог: {0}\n   Шаблон: {1}'.format(args.indir, args.rename_template))
    check_indir_exists(args)
    check_tmpl(args)
    renamer = FB2GroupRenamer(startdir = args.indir, outdir = args.outdir, template = args.rename_template,
                              debug = args.debug)
    # Проверим, что объект создался и готов к работе
    if renamer is None:
        print('Ошибка доступа к каталогу {0}'.format(args.indir))
        exit(202)
    counter = renamer.rename_all()
    print('\n     Переименовано файлов: {0}'.format(counter))
    exit(0)


def do_html(args: argparse.Namespace):
    print('Конвертация FB2 -> HTML')
    print('    Файл: {0}'.format(args.filename))
    print(' Каталог: {0}'.format(args.outdir))
    html = FB2HTML(filename = args.filename, debug = args.debug)
    if html is None:
        print('Ошибка открытия файла {0}'.format(args.filename))
        exit(201)
    html.create_html(args.outdir)


def do_zip(args: argparse.Namespace):
    pass


def do_unzip(args: argparse.Namespace):
    unzip = UnzipFB2(args.indir, args.removezip)
    unzip.unzipAll()


#
#  Создание парсеров аргументов командной строки
#
description = 'Программа используется для следующих целей:\n' \
              ' - переименование FB2 файлов;\n' \
              ' - групповое переименование FB2 файлов;\n' \
              ' - конвертация FB2 -> HTML'

progname = 'fb2tools.py'
version = '0.9'
epilog = """
          Программа для разбора FB2
          """

parser = argparse.ArgumentParser(prog = progname, description = description, epilog = epilog)
parser.add_argument('--debug', help = 'Показывать отладочные сообщения', default = False, action = 'store_true',
                    dest = 'debug')

subparsers = parser.add_subparsers(help = 'Действие, которое необходимо выполнить.', dest = 'subparser_name')

#
#  Rename parser
#
parser_rename = subparsers.add_parser('rename', help = 'Переименование файла FB2')
parser_rename.set_defaults(func = do_rename)  # обработчик этого парсера - функция do_rename
parser_rename.add_argument('--file', type = str, default = None, help = 'FB2 файл', action = 'store', dest = 'filename')
parser_rename.add_argument('--template', help = 'Шаблон для переименования', default = None, action = 'store',
                           dest = 'rename_template')
parser_rename.add_argument('--outdir', type = str, default = None,
                           help = 'Каталог, в который будет помещен переименованный файл', action = 'store',
                           dest = 'outdir')

#
# Group rename parser
#
parser_grouprename = subparsers.add_parser('grouprename', help = 'Переименование группы файлов FB2')
parser_grouprename.set_defaults(func = do_grouprename)  # обработчик этого парсера - функция do_grouprename
parser_grouprename.add_argument('--template', help = 'Шаблон для переименования', default = None, action = 'store',
                                dest = 'rename_template')
parser_grouprename.add_argument('--indir', type = str, default = None, help = 'Входной каталог с файлами FB2',
                                action = 'store',
                                dest = 'indir')
parser_grouprename.add_argument('--outdir', type = str, default = None, help = 'Каталог для записи результатов работы',
                                action = 'store',
                                dest = 'outdir')
#
# Hyst parser
#
parser_hyst = subparsers.add_parser('hyst', help = 'Преобразование файлов в БД Hyst')

parser_hyst.set_defaults(func = do_hyst)  # обработчик этого парсера - функция do_hyst

parser_hyst.add_argument('--hystdb', type = str, default = None, help = 'База данных Hyst', action = 'store',
                         dest = 'hystdb')

parser_hyst.add_argument('--notebook', type = str, default = None, help = 'Название записной книжки', action = 'store',
                         dest = 'notebook')

parser_hyst.add_argument('--subaction', choices = ['createdb', 'addbook', 'addnotebook', 'addnode', 'shownodes'],
                         help = 'Subaction', required = False, dest = 'subaction')

group_src = parser_hyst.add_mutually_exclusive_group()

group_src.add_argument('--indir', type = str, default = None, help = 'Входной каталог с файлами FB2',
                       action = 'store',
                       dest = 'indir')
group_src.add_argument('--file', type = str, default = None, help = 'FB2 файл', action = 'store', dest = 'filename')

#
#  HTML parser
#
parser_html = subparsers.add_parser('html', help = 'Конвертация FB2 -> HTML')
parser_html.set_defaults(func = do_html)
parser_html.add_argument('--file', type = str, default = None, help = 'FB2 файл', action = 'store', dest = 'filename')
parser_html.add_argument('--outdir', type = str, default = None, help = 'Каталог для записи результатов работы',
                         action = 'store',
                         dest = 'outdir')

#
#  Zip parser
#
parser_zip = subparsers.add_parser('zip', help = 'Сжатие FB2 файлов')
parser_zip.set_defaults(func = do_zip)

#
#  UnZip parser
#
parser_unzip = subparsers.add_parser('unzip', help = 'Сжатие FB2 файлов')
parser_unzip.set_defaults(func = do_unzip)
parser_unzip.add_argument('--indir', type = str, default = None, help = 'Входной каталог с файлами FB2',
                          action = 'store',
                          dest = 'indir')
parser_unzip.add_argument('--removezip', default = False, help = 'Удалять архив после распаковки',
                          action = 'store_true',
                          dest = 'removezip')

#
#  Разбор командной строки и вызов обработчика
#
args = parser.parse_args()
if args.debug:
    print(args)
args.func(args)
