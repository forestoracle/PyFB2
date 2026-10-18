# MOBI → FB2 (`mobi_to_fb2`)

Модуль `pyFB2/mobi_to_fb2.py` разбирает базу данных Palm (PDB), распаковывает
текст PalmDOC LZ77 и преобразует HTML-разметку Mobi7 в структуры FB2 через
`HtmlToFb2Converter`.

```text
book.mobi (PDB) -> HTML (Mobi7) -> FictionBook (структуры) -> book.fb2
```

## Что разбирается

| Часть MOBI | Результат |
|---|---|
| PalmDOC-заголовок | компрессия, длина текста, число текстовых записей |
| MOBI-заголовок | `first_image_index`, смещение/длина полного названия |
| EXTH 100/103/105/524 | авторы, аннотация, жанры (коды без пробелов), язык |
| EXTH 201 | обложка → `<coverpage>` + `<binary>` |
| текстовые записи | распаковка (PalmDOC) и склейка в HTML |
| записи изображений | `<img recindex="N">` → data URI → `<binary>` в FB2 |

Служебные записи (`FLIS`, `FCIS`, `INDX`, `SRCS`, `CMET`, `FDST`) при разборе
изображений пропускаются.

## Публичный API

```python
from pyFB2 import MobiToFb2Converter, MobiHeader
from pyFB2.mobi_to_fb2 import palmdoc_decompress

converter = MobiToFb2Converter(default_genre="sf", program_used="pyFB2")

book = converter.convert("book.mobi")       # путь или bytes
xml = converter.to_xml(book)
path = converter.write("book.mobi", "book.fb2")

palmdoc_decompress(b"...")                  # распаковка одного блока
```

`MobiHeader` (dataclass) описывает разобранную запись 0: `compression`,
`text_length`, `text_records`, `first_image_index`, `full_name_offset`,
`full_name_length`, `title`, `exth` (словарь «тип → список значений») и
помощники `first(kind)` / `texts(kind)` — им пользуются тесты и диагностика.

## CLI

```bash
pyfb2 convert book.mobi book.fb2
pyfb2-mobi2fb2 book.mobi [book.fb2]
python -m pyFB2.mobi_to_fb2 book.mobi
```

## Ограничения

- HUFF/CDIC-компрессия (`17480`) не поддерживается — возбуждается
  `Fb2ConversionError`.
- DRM-защищённые файлы (AZW с ключом) не читаются.
- Одна картинка = одна запись: если изображение разбито на несколько записей,
  восстанавливается только первая часть.
- Структура секций восстанавливается по уровням заголовков (`h1`–`h6`);
  стихи и цитаты становятся абзацами (`blockquote` → обычные абзацы).
