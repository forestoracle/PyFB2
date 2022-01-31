﻿PyFB2
=====
Модуль для работы с файлами FB2 (_FictionBook 2_)

2022-01-31

___

# Классы модуля

* __FB2Parser__ - класс для разбора файлов FB2
* __FB2Renamer__ - класс для переименования файла FB2 по заданному шаблону
* __FB2GroupRenamer__ - класс для переименования файла FB2 по заданному шаблону
* __FB2HTML__ - класс для преобразования FB2 в HTML
* __FB2Hyst__ - класс для преобразования FB2 в базу данных Hyst

# Использование в качастве самостоятельной программы

Модуль может быть использован в качестве самостоятельной программы. Далее следует описание аргументов командной строки и
способы использования модуля.

## Аргументы командной строки

| **Аргумент** | **Назначение** |
|-----------------|---------------------------|
| --file filename | Открыть и обработать файл |
| --dir dir       | Обработать каталог        |

# Использование модуля в python

## Генерация HTML

Генерация HTML выполняется с помощью класса **FB2HTML**.

## Переименование отдельных файлов FB2

Переименование отдельных файлов FB2 выполняется с помощью класса **FB2Renamer**
Следующий фрагмент кода показывает, как переименовать отдельный файл.

```python
from PyFB2 import FB2Renamer

renamer = FB2Renamer('C:/Downloads/Книги/book.fb2', '{Al} {Af} {Am} - {Tt}')
if renamer is None:
    exit(2)
renamer.rename()
```

## Групповое переименование файлов FB2

Групповое переименование файлов выполняется с помощью класса **FB2GroupRenamer**
Следующий фрагмент кода показывает, как переименовать все файлы в каталоге включая подкаталоги.

```python
from PyFB2 import FB2GroupRenamer

renamer = FB2GroupRenamer('C:/Downloads/Книги', '{Al} {Af} {Am} - {Tt}')
if renamer is None:
    exit(2)
renamer.rename_all()
```

# Известные проблемы

## Ошибки

- [ ] При работе с неправильно форматированным файлом выдается стек ошибок. Нужно обрабатывать такое исключение.
  Особенно это актуально при пакетной обработке файлов - в этом случае вообще не понятно, с каким файлом случилась беда.

- [x] FB2GroupRenamer не выдает ошибок, если указанный каталог не существует.
- [x] При переименовании нужно убирать пробелы в начале и конце атрибутов.
- [x] При переименовании предыдущий атрибут пустой, то нужно убирать пробел или знак, которым он отделяется от
  следующего. Решено удалением задвоенных пробелов.
- [ ] Не понимает заголовков, если они помещены в дополнительные тэги, например <title><p><strong>. При чтении заголовков это нужно учитывать. Пример: "Z:\Книги\О\О Сталине\Ушаков Александр. Сталин. По ту сторону добра и зла.fb2"


## Разобраться с пространствами имен

Процедура FB2Parser.cleanup удаляет из тэгов пространство имен.

Например:

> В документе тэг description имеет вид
>> _{http://www.gribuser.ru/xml/fictionbook/2.0}description_

> После FB2Parser.cleanup тэг имеет вид
>> _description_

То же самое нужно сделать с атрибутами. После обработки тэга нужно обработать его атрибуты.

## Разообраться с модулем argparse

1. Как сделать так, чтобы нельзя было указать одновременно и пакетный (--dir) и одиночный (--file) режимы работы.
2. Как в каждом из режимов исключить появление не обрабатываемых в этом режиме ключей.

## Не выдает следующую информацию о файле:

- [ ] /FictionBook/description/title-info/coverpage - не сделал
- [x] /FictionBook/description/document-info
    - [x] /FictionBook/description/document-info/author
    - [x] /FictionBook/description/document-info/program-used
    - [x] /FictionBook/description/document-info/date
    - [x] /FictionBook/description/document-info/src-url
    - [x] /FictionBook/description/document-info/src-ocr
    - [x] /FictionBook/description/document-info/id
    - [x] /FictionBook/description/document-info/version
    - [x] /FictionBook/description/document-info/history
    - [x] /FictionBook/description/document-info/publisher
- [x] /FictionBook/description/publish-info
    - [x] /FictionBook/description/publish-info/book-name
    - [x] /FictionBook/description/publish-info/publisher
    - [x] /FictionBook/description/publish-info/city
    - [x] /FictionBook/description/publish-info/year
    - [x] /FictionBook/description/publish-info/isbn
    - [x] /FictionBook/description/publish-info/sequence

# Задачи

- [x] Оптимизация. Сразу получать _description_, _title-info_, _document-info_, _publish-info_. Для получения каждого
  дочернего узла использовать ранее полученный родительский узел, а не читать его заново. Рассмотреть процедуру __
  cleanup__ - возможно, раз уж мы все равно сканируем документ в ней, надо там и назначать основные переменные (
  title-info b т.д.).
- [x] Оптимизация. Получать элементы с помощью одной функции, передавая в нее _root_el_ и _xpath_. Сейчас для каждого
  элемента проводятся проверки if el is None. Это можно выполнять в одной функции. То же самое для _атрибутов_.
- [x] Переименование всех файлов папке по шаблону (с включением рекурсии по подпапкам)
- [ ] Вывод списка всех авторов в папке.
- [ ] Преобразование FB2 в HTML
- [ ] Преобразование FB2 в Hyst
- [ ] Создавать папки с именами авторов и перемещать/копировать туда книги этих авторов

 ## Обработка HTML
 
- [ ] Возможность вставлять в HTML-файлы CSS. Например, с фиксированным именем book.css
  Или указывать CSS-файл в командной строке. 
- [ ] Возможность создавать заголовок и концевик HTML-файла. Функции add_html_header и add_html_footer.
  Выбрать для них правильное место вызова.
- [x] Для тела с _name="notes"_, содержащего сноски, нужно создавать только 
  один файл для каждой секции первого уровня, а не массу файлов для каждой сноски. 