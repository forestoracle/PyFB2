# pyFB2

Пакет для обработки книг **FB2** (FictionBook 2.0) на Python: разбор,
сериализация, валидация по XSD и конвертация в другие форматы (и обратно) —
EPUB, DOCX, ODT, MOBI, FB3, Markdown, HTML, TXT, PDF.

## Возможности

- **Разбор FB2** — `Fb2Parser`: метаданные (`<description>`), тела и секции,
  встроенные изображения (`<binary>`), идентификаторы глав.
- **Сериализация** — `Fb2Writer`: сборка XML FictionBook 2.0 из структур
  (валидная по XSD схема).
- **Валидация** — `Fb2Validator`: проверка по `FictionBook.xsd`
  (well-formedness + соответствие схеме, подробный отчёт об ошибках).
- **Нормализация** — `Fb2Normalizer`: авто-исправление FB2 (кодировка → UTF-8,
  порядок элементов по XSD, добавление обязательных полей, дубликаты `<binary>`,
  пробелы, битые ссылки на изображения).
- **Разбиение/слияние** — `Fb2Splitter` (по главам, по размеру или на N частей)
  и `Fb2Merger` (объединение книг с метаданными и разрешением конфликтов `<binary>`).
- **Обложки и аннотации из сети** — `Fb2MetadataFetcher`: поиск книги в
  Open Library / Google Books / FantLab, скачивание обложки и аннотации и запись их в FB2
  (только стандартная библиотека, без внешних зависимостей).
- **Индекс библиотеки** — `Fb2Index`: SQLite-индекс книг (метаданные + текст),
  поиск по автору/названию/серии/жанру/году и полнотекстовый поиск по
  содержимому книг (FTS5, сниппеты, ранжирование BM25).
- **Конвертеры** (в обе стороны): EPUB, DOCX, ODT, MOBI, FB3, Markdown, HTML;
  импорт PDF (эвристический) и экспорт в TXT/PDF.
- **Утилиты**: перекодировка (`Fb2Transcoder`), переименование
  (`FB2Renamer`), сканеры авторов/кодировок, поиск статьи об авторе в
  Википедии (`fb2_wiki`).
- **Архивы** — `FB2Zip` / `FB2Unzip`: упаковка книг в «однокнижные»
  ZIP-архивы (`book.fb2.zip`) и распаковка архивов (берутся только `.fb2`,
  защита от «Zip Slip», удаление исходников, предпросмотр `dry_run`).

## Установка

```sh
pip install .                 # базовые возможности (lxml)
pip install ".[pdf]"          # + PDF: экспорт (reportlab) и импорт (pypdf)
pip install ".[wiki]"         # + работа с Википедией (requests, bs4, markdownify)
pip install ".[all]"          # всё сразу
```

Требуется Python 3.11+.

## Быстрый старт

Все ключевые классы доступны напрямую из пакета:

```python
from pyFB2 import Fb2Parser, Fb2Writer, Fb2Validator
from pyFB2 import Fb2ToEpubConverter, Fb2ToHtmlConverter, Fb2ToDocxConverter
from pyFB2 import Fb2ToTxtConverter
```

Разбор метаданных и текста:

```python
from pyFB2.fb2_parser import Fb2Parser

parser = Fb2Parser("book.fb2")
description = parser.parse()
print(description.title_info.book_title.value)

bodies = parser.parse_bodies()          # секции с идентификаторами глав
binaries = parser.parse_binaries()      # встроенные изображения
```

Сборка FB2 из структур:

```python
from pyFB2.fb2_writer import Fb2Writer

Fb2Writer().write(book, "out.fb2")      # book — FictionBook
```

Валидация:

```python
from pyFB2.fb2_validator import Fb2Validator

result = Fb2Validator().validate_file("book.fb2")
print(result.is_valid, result.errors)
```

Нормализация (авто-исправление):

```python
from pyFB2.fb2_normalizer import Fb2Normalizer

normalizer = Fb2Normalizer(validate=True)
result = normalizer.normalize_file("book.fb2", dest="book.fixed.fb2")
for fix in result.fixes:
    print(fix)              # [added-genre] добавлен <genre>prose</genre>
print(result.valid_after)   # True
```

Разбиение и слияние:

```python
from pyFB2 import Fb2Splitter, Fb2Merger

# Разбить на 3 части (или: by="sections", by="size", max_size=300_000)
Fb2Splitter(by="parts", parts=3).split("book.fb2", out_dir="parts")

# Слить книги в одну
Fb2Merger(title="Сборник").merge_to_file(["a.fb2", "b.fb2"], "collection.fb2")
```

Обложка и аннотация из сети:

```python
from pyFB2 import Fb2MetadataFetcher

fetcher = Fb2MetadataFetcher()                  # Open Library + Google Books + FantLab
matches = fetcher.search("Война и мир", author="Лев Толстой")
meta = fetcher.enrich(matches[0])               # скачать обложку и аннотацию

fetcher.apply("book.fb2", meta=meta, output="book.fixed.fb2")
fetcher.save_cover(meta, "covers/")             # обложка отдельным файлом
```

## Конвертеры

Все конвертеры используют общий сериализатор `Fb2Writer` и не требуют
внешних библиотек — кроме PDF (`reportlab`/`pypdf`, extra `[pdf]`).

| Из → В      | В FB2              | Из FB2              |
|-------------|--------------------|---------------------|
| **EPUB**    | `EpubToFb2Converter` | `Fb2ToEpubConverter` (EPUB 2.0/3.0) |
| **DOCX**    | `DocxToFb2Converter` | `Fb2ToDocxConverter` |
| **Markdown**| `MarkdownToFb2Converter` | `Fb2ToMarkdownConverter` |
| **HTML**    | `HtmlToFb2Converter` | `Fb2ToHtmlConverter` |
| **ODT**     | `OdtToFb2Converter`  | `Fb2ToOdtConverter` |
| **MOBI**    | `MobiToFb2Converter` | `Fb2ToMobiConverter` (Kindle KF7) |
| **FB3**     | `Fb3ToFb2Converter`  | `Fb2ToFb3Converter` |
| **TXT**     | —                  | `Fb2ToTxtConverter` |
| **PDF**     | `PdfToFb2Converter` (эвристически) | `Fb2ToPdfConverter` (extra `[pdf]`) |

Пример:

```python
from pyFB2.fb2_to_epub import Fb2ToEpubConverter
from pyFB2.epub_to_fb2 import EpubToFb2Converter

Fb2ToEpubConverter().write("book.fb2", "book.epub")
EpubToFb2Converter().write("book.epub", "book.fb2")

# EPUB 3.0 (OPF 3.0 + nav.xhtml)
from pyFB2.fb2_to_epub import Fb2ToEpubConverter as Epub3
Epub3(epub_version=3).write("book.fb2", "book3.epub")

# FB2 -> HTML с оглавлением и двусторонними ссылками сносок
from pyFB2.fb2_to_html import Fb2ToHtmlConverter
Fb2ToHtmlConverter(image_dir="images", include_toc=True).write("book.fb2", "book.html")
# note_links=True (по умолчанию): <a class="note-ref" href="#note1">1</a>
# в тексте и <a class="footnote-back" href="#noteref-note1">↩</a> в сноске

# FB2 -> TXT (обычный текст)
from pyFB2.fb2_to_txt import Fb2ToTxtConverter
Fb2ToTxtConverter(include_toc=True, line_width=80).write("book.fb2", "book.txt")
```

У каждого конвертера единый интерфейс:

```python
converter.convert(source)          # -> структура / строка
converter.write(source, output)    # -> Path (запись файла)
```

## Командная строка

Все возможности собраны в **одну команду** `pyfb2` (модуль `fb2tools`):

```sh
pyfb2 info book.fb2                     # метаданные и дерево заголовков
pyfb2 validate library/ -r              # валидация по XSD
pyfb2 normalize book.fb2 --dry-run      # нормализация/авто-исправление
pyfb2 convert book.fb2 book.epub        # конвертация (и обратно)
pyfb2 convert book.fb2 --to pdf         # формат через --to
pyfb2 convert book.pdf book.fb2         # PDF -> FB2 (структура по закладкам)
pyfb2 split book.fb2 -o parts/          # разбиение на части
pyfb2 merge out.fb2 a.fb2 b.fb2         # слияние книг
pyfb2 fetch book.fb2 --cover-out covers # обложка/аннотация из сети
pyfb2 wiki book.fb2 -o author.md        # статья об авторе (Markdown)
pyfb2 index build library/              # SQLite-индекс библиотеки (+текст книг)
pyfb2 index search "Толстой"            # поиск по метаданным (все поля)
pyfb2 index search "Детство" --by title # …только по названию
pyfb2 index find "красная шапка"        # полнотекстовый поиск по тексту книг
pyfb2 index find "волк NEAR лиса"       # синтаксис FTS5: AND/OR/NOT/NEAR, "фраза", слово*
pyfb2 transcode library/ -r             # перекодировка в UTF-8
pyfb2 rename book.fb2 --template "${Al} - ${Tt}"
pyfb2 scan authors library/             # сканеры авторов/кодировок
pyfb2 cover book.fb2 -o cover.jpg       # извлечение обложки
pyfb2 zip library/                      # упаковка FB2 в .fb2.zip
pyfb2 unzip library/ --remove           # распаковка архивов (с удалением)

python -m pyFB2.fb2tools --help         # то же без установки скрипта
```

Отдельные узкие команды (`pyfb2-parse`, `pyfb2-validate`, `pyfb2-to-epub`, ...)
тоже доступны:

```sh
pyfb2-parse    book.fb2                  # метаданные и дерево заголовков
pyfb2-validate book.fb2                  # валидация по XSD
pyfb2-normalize book.fb2                 # нормализация/авто-исправление
pyfb2-rewrite  book.fb2                  # пересборка формы (структуры -> XML)
pyfb2-split    book.fb2 -o parts/        # разбиение на части
pyfb2-merge    out.fb2 a.fb2 b.fb2       # слияние книг в одну
pyfb2-fetch    book.fb2                  # обложка/аннотация из сети в FB2
pyfb2-to-epub  book.fb2                  # FB2 -> EPUB (--epub3 для EPUB 3.0)
pyfb2-to-docx  book.fb2                  # FB2 -> DOCX
pyfb2-to-md    book.fb2                  # FB2 -> Markdown
pyfb2-to-html  book.fb2                  # FB2 -> HTML (с оглавлением)
pyfb2-to-odt   book.fb2                  # FB2 -> ODT (LibreOffice/OpenDocument)
pyfb2-to-mobi  book.fb2                  # FB2 -> MOBI (Kindle KF7, PalmDOC)
pyfb2-to-fb3   book.fb2                  # FB2 -> FB3 (FictionBook 3, OPC/ZIP)
pyfb2-to-txt   book.fb2                  # FB2 -> TXT
pyfb2-to-pdf   book.fb2                  # FB2 -> PDF
pyfb2-pdf2fb2  book.pdf                  # PDF -> FB2 (эвристически)
pyfb2-md2fb2   book.md                   # Markdown -> FB2
pyfb2-html2fb2 book.html                 # HTML -> FB2
pyfb2-odt2fb2  book.odt                  # ODT -> FB2
pyfb2-mobi2fb2 book.mobi                 # MOBI -> FB2
pyfb2-fb32fb2  book.fb3                  # FB3 -> FB2
pyfb2-zip      book.fb2                  # FB2 -> .fb2.zip
pyfb2-unzip    book.fb2.zip              # .fb2.zip -> FB2
```

## Логирование

Библиотека ничего не печатает сама: диагностика идёт через стандартный
`logging` (логгеры вида `pyFB2.<модуль>`). В `pyFB2/__init__.py` установлен
`NullHandler`, поэтому без настройки вывод молчит и приложение само решает,
что показывать.

```python
import logging

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
# или только для библиотеки:
logging.getLogger("pyFB2").setLevel(logging.DEBUG)
```

| Уровень | Событие |
|---|---|
| `WARNING` | файл не разобрался (`Fb2AuthorScanner`, `Fb2Index`), кодировка не определена, провайдер метаданных недоступен |
| `ERROR` | не удалось переименовать файл, каталог не существует (`FB2GroupRenamer`) |
| `DEBUG` | подробности индексации (`pyfb2 index -v`) |

CLI-команды настраивают логирование сами, поэтому в командной строке
сообщения видны без дополнительной подготовки.

## Ошибки

Все ошибки библиотеки наследуют `Fb2Error`, поэтому достаточно одного
обработчика; при этом каждый класс остаётся совместим с «классическим»
типом исключения, так что старый код продолжает работать:

```python
from pyFB2 import Fb2Error, Fb2ParseError, Fb2Parser

try:
    book = Fb2Parser("book.fb2").parse()
except FileNotFoundError:     # файла нет
    ...
except Fb2ParseError as exc:  # битый FB2/XML
    print("Не разобрать книгу:", exc)
except Fb2Error as exc:       # любая другая ошибка pyFB2
    print("Ошибка:", exc)
```

| Класс | Смысл | Совместим с |
|---|---|---|
| `Fb2ParseError` | FB2/XML не удалось прочитать или разобрать | `ValueError` |
| `Fb2XmlError` | некорректный XML (в т.ч. отсечённые DTD-сущности) | `ValueError`, `ET.ParseError` |
| `Fb2ValidationError` | документ/схема не подходят | `ValueError` |
| `Fb2ConversionError` | не удалось преобразовать книгу | `ValueError` |
| `Fb2OperationError` | ошибка файловой операции (переименование) | `RuntimeError` |
| `Fb2NotFoundError` | данные не найдены (книга, статья, автор) | `RuntimeError`, `LookupError` |
| `Fb2NetworkError` | сетевая ошибка или некорректный ответ | `RuntimeError` |

## Структура пакета

```
pyFB2/
  pyFB2/                 # сам пакет
    fb2_structures.py    # dataclass-структуры FB2 (по XSD)
    fb2_parser.py        # FB2 -> структуры
    fb2_xml.py           # безопасный разбор XML (защита от DTD-бомб)
    fb2_writer.py        # структуры -> FB2 XML
    fb2_validator.py     # валидация по XSD (lxml)
    fb2_normalizer.py    # нормализация/авто-исправление FB2
    fb2_rewrite.py       # пересборка формы FB2 (структуры -> XML)
    fb2_split_merge.py   # разбиение и слияние FB2
    fb2_web_metadata.py  # обложки/аннотации из Open Library, Google Books и FantLab
    fb2tools.py          # единая команда pyfb2 (все возможности)
    fb2_index.py         # SQLite-индекс библиотеки
    fb2_zip.py           # упаковка FB2 в ZIP-архивы (.fb2.zip)
    fb2_unzip.py         # распаковка архивов FB2
    *_to_*.py            # конвертеры (epub/docx/markdown/html/txt/pdf)
    fb2_wiki.py          # статья об авторе в Википедии
    resources/           # XSD-схемы, genres.json
  tests/                 # pytest-тесты (в т.ч. round-trip)
  setup.py / pyproject.toml
doc/                     # документация по модулям
pas/                     # частичный порт на FreePascal (структуры, парсер, writer, markdown)
tools/                   # вспомогательные утилиты (dated_dirs.py — раскладка файлов по датам)
```

## Разработка

```sh
cd pyFB2
pip install -e ".[dev]"           # editable-установка + pytest, ruff, mypy
pytest                            # тесты
ruff check pyFB2 tests            # линтер
mypy                              # проверка типов (конфиг в pyproject.toml)
python -m build                   # sdist + wheel в dist/
```

CI (GitHub Actions, `.github/workflows/ci.yml`) выполняет `ruff`, `mypy` и
`pytest` на Python 3.11–3.13, а также сборку пакета (`python -m build` +
`twine check`).

Документация: [doc/index.md](doc/index.md) — точка входа по модулям;
[CHANGELOG.md](CHANGELOG.md) — история версий.

Версия пакета — единый источник: `pyFB2.__version__` (в `pyproject.toml`
задан `dynamic = ["version"]`).

## Лицензия

Apache License 2.0 — см. [LICENSE](LICENSE).
