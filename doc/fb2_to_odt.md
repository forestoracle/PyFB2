# FB2 → ODT (`fb2_to_odt`)

Модуль `pyFB2/fb2_to_odt.py` собирает документ OpenDocument Text (ODF 1.2)
из структур `Fb2Parser` — **без внешних зависимостей** (`zipfile` + `xml`
стандартной библиотеки).

```text
book.fb2 -> FictionBook (структуры) -> book.odt (ZIP/ODF)
```

## Состав контейнера

| Часть | Содержимое |
|---|---|
| `mimetype` | `application/vnd.oasis.opendocument.text` (первой записью, без сжатия) |
| `META-INF/manifest.xml` | перечень частей с MIME-типами |
| `content.xml` | текст + автоматические стили (`office:automatic-styles`) |
| `styles.xml` | базовые стили абзацев и параметры страницы (A4, поля 2 см) |
| `meta.xml` | Dublin Core: `dc:title`, `dc:creator`, `dc:language`, `dc:date` |
| `Pictures/*` | изображения из `<binary>` |

## Что переносится

| FB2 | ODT |
|---|---|
| `<book-title>`, авторы, аннотация | абзацы со стилями `Title`, `Subtitle`, `Annotation` |
| заголовки секций | `text:h` с `text:outline-level` (1–10) |
| `<p>`, `<subtitle>`, `<empty-line>` | `text:p` (`Subtitle2`, `&#160;`) |
| `<strong>`, `<emphasis>`, `<code>`, `<strikethrough>`, `<sub>/<sup>` | `text:span` + автоматический стиль (`fo:font-weight` и т. п.) |
| `<style name="…">` | `text:span` (стиль по флагам) |
| `<a href="…">` | `text:a` с `xlink:href` |
| `<image>` (блочная и inline) | `draw:frame` + `draw:image` (`Pictures/...`, ширина ≤ 16 см) |
| `<coverpage>` | картинка в начале документа |
| `<epigraph>`, `<cite>` | абзацы со стилями `Epigraph`, `Quotation` |
| стихи (`poem/stanza/v`) | абзацы `PoemLine`/`PoemAuthor` |
| `<table>` | `table:table` (`th` → `HeaderCell`) |

## Публичный API

```python
from pyFB2 import Fb2ToOdtConverter

converter = Fb2ToOdtConverter(max_image_width_cm=16.0)

book = converter.convert("book.fb2")        # -> OdtBook
data = converter.to_bytes(book)             # -> bytes ZIP
path = converter.write("book.fb2", "book.odt")
```

| Структура | Поля |
|---|---|
| `OdtBook` | `title`, `creators`, `language`, `identifier`, `date`, `description`, `content_xml`, `automatic_styles`, `images` |
| `OdtImage` | `filename`, `media_type`, `data`, `width_cm`, `height_cm` |

## CLI

```bash
pyfb2 convert book.fb2 book.odt      # единая команда
pyfb2-to-odt book.fb2 [book.odt]     # узкий скрипт
python -m pyFB2.fb2_to_odt book.fb2  # из исходников
```

Обратное направление — [odt_to_fb2.md](odt_to_fb2.md).

## Ограничения

- SVG-изображения пропускаются (в ODT это отдельный объект, не `draw:image`).
- Сноски (`<a type="note">`) и стилевые `NamedStyle` из `<stylesheet>`
  переносятся как обычный текст.
- Итоговый файл не проверяется внешним валидатором ODF (тесты проверяют
  корректность ZIP-структуры, XML и наличие обязательных частей).
