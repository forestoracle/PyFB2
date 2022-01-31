"""
Версия: 2022-01-31

"""
import argparse
import os
import sqlite3

from PyFB2 import FB2GroupRenamer, FB2Renamer


#
#  Разного рода проверки
#
def check_hystdb(args: argparse.Namespace):
    dbconn: sqlite3.Connection
    if args.hystdb is None:
        print("Не указана база Hyst")
        exit(110)
    try:
        dbconn = sqlite3.connect(args.hystdb)
    except:
        print("Не удалось подключиться к БД {0}".format(args.hystdb))
        exit(111)
    dbconn.close()


def check_indir_exists(args: argparse.Namespace):
    if args.indir is None:
        print("Не указан входной каталог FB2. Используйте аргумент --indir{1}")
        exit(102)
    if not os.path.isdir(args.indir):
        print("Указан несуществующий входной каталог")
        exit(103)


def check_tmpl(args: argparse.Namespace):
    if args.rename_template is None:
        print("Не указан шаблон для переименования")
        exit(104)


def check_file_exists(args: argparse.Namespace):
    if not os.path.isfile(args.filename):
        print("Указан несуществующий входной файл {0}".format(args.filename))
        exit(105)


#
#  Выполнение действий, указанных в командной строке как главное
#
def do_hyst(args: argparse.Namespace):
    print("\nПреобразование в формат Hyst.")
    print("  HystDB: {0}".format(args.hystdb))
    # Эту проверку нужно выполнять тогда, когда БД уже существует
    # :TODO: Если команда подразумевает создание новой БД - эту проверку выполнять не надо.
    check_hystdb(args)


def do_rename(args: argparse.Namespace):
    print("\nПереименование файла.")
    print("    Файл: {0}\n  Шаблон: {1}".format(args.filename, args.rename_template))
    check_file_exists(args)
    check_tmpl(args)
    renamer = FB2Renamer(filename = args.filename, template = args.rename_template, outdir = args.outdir)
    # Проверим, что объект создался и готов к работе
    if renamer is None:
        print("Ошибка открытия файла {0}".format(args.filename))
        exit(201)
    new_name = renamer.rename()
    print('\n     Новое имя файла: {0}'.format(new_name))


def do_grouprename(args: argparse.Namespace):
    print("\nГрупповое переименование файлов.")
    print("  Каталог: {0}\n   Шаблон: {1}".format(args.indir, args.rename_template))
    check_indir_exists(args)
    check_tmpl(args)
    renamer = FB2GroupRenamer(startdir = args.indir, outdir = args.outdir, template = args.rename_template,
                              debug = args.debug)
    # Проверим, что объект создался и готов к работе
    if renamer is None:
        print("Ошибка доступа к каталогу {0}".format(args.indir))
        exit(201)
    counter = renamer.rename_all()
    print('\n     Переименовано файлов: {0}'.format(counter))
    exit(0)


#
#  Создание парсеров аргументов командной строки
#
description = 'Программа используется для следующих целей:\n' \
              ' - переименование FB2 файлов;\n' \
              ' - групповое переименование FB2 файлов;'

prog_name = "fb2tools.py"
version = "0.9"
epilog = """
          Программа для разбора FB2
          """

parser = argparse.ArgumentParser(prog = prog_name, description = description, epilog = epilog)
parser.add_argument('--debug', help = 'Показывать отладочные сообщения', default = False, action = 'store_true',
                    dest = 'debug')

subparsers = parser.add_subparsers(help = "Действие, которое необходимо выполнить.", dest = "subparser_name")

#
#  Rename parser
#
parser_rename = subparsers.add_parser("rename", help = "Переименование файла FB2")
parser_rename.set_defaults(func = do_rename)  # обработчик этого парсера - функция do_rename
parser_rename.add_argument('--file', type = str, default = None, help = "FB2 файл", action = 'store', dest = 'filename')
parser_rename.add_argument('--template', help = 'Шаблон для переименования', default = None, action = 'store',
                           dest = 'rename_template')
parser_rename.add_argument('--outdir', type = str, default = None,
                           help = 'Каталог, в который будет помещен переименованный файл', action = 'store',
                           dest = 'outdir')

#
# Group rename parser
#
parser_grouprename = subparsers.add_parser("grouprename", help = "Переименование группы файлов FB2")
parser_grouprename.set_defaults(func = do_grouprename)  # обработчик этого парсера - функция do_grouprename
parser_grouprename.add_argument('--template', help = 'Шаблон для переименования', default = None, action = 'store',
                                dest = 'rename_template')
parser_grouprename.add_argument('--indir', type = str, default = None, help = "Входной каталог с файлами FB2",
                                action = 'store',
                                dest = 'indir')
parser_grouprename.add_argument('--outdir', type = str, default = None, help = "Каталог для записи результатов работы",
                                action = 'store',
                                dest = 'outdir')
#
# Hyst parser
#
parser_hyst = subparsers.add_parser("hyst", help = "Преобразование файлов в БД Hyst")

parser_hyst.set_defaults(func = do_hyst)  # обработчик этого парсера - функция do_hyst

parser_hyst.add_argument('--hystdb', type = str, default = None, help = 'База данных Hyst', action = 'store',
                         dest = 'hystdb')
parser_hyst.add_argument('--subaction', choices = ['createdb', 'addbook', 'addnotebook', 'addnode', 'shownodes'],
                         help = 'Subaction', required = False, dest = 'subaction')

group_src = parser_hyst.add_mutually_exclusive_group()

group_src.add_argument('--indir', type = str, default = None, help = "Входной каталог с файлами FB2",
                       action = 'store',
                       dest = 'indir')
group_src.add_argument('--file', type = str, default = None, help = "FB2 файл", action = 'store', dest = 'filename')

#
#  Разбор командной строки и вызов обработчика
#
args = parser.parse_args()
if args.debug:
    print(args)
args.func(args)
