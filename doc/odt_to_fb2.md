# ODT → FB2 (`odt_to_fb2`)

Модуль `pyFB2/odt_to_fb2.py` читает документ OpenDocument Text и собирает
структуры `FictionBook`, сериализуемые `Fb2Writer` (round-trip с
[fb2_to_odt.md](fb2_to_odt.md)).

```text
book.odt (ZIP/ODF) -> FictionBook (структуры) -> book.fb2
```

## Что переносится

| ODT | FB2 |
|---|---|
| `dc:title` (`meta.xml`) или абзац `Title` | `<book-title>` |
| `dc:creator` (или абзац `Subtitle` шапки) | `<author>` (first/last/middle) |
| `dc:language`, `dc:date`, `dc:subject` | `<lang>`, `<date>`, `<genre>` (коды без пробелов) |
| `dc:description` или абзацы `Annotation` | `<annotation>` |
| картинка шапки | `<coverpage>` + `<binary>` |
| `text:h` | заголовки секций (вложенность по `outline-level`) |
| `text:p` | `<p>`; стиль `Subtitle2` → `<subtitle>`; `&#160;` → `<empty-line>` |
| `text:span` с bold/italic/strike/sub/sup/моноширинный | `<strong>`, `<emphasis>`, `<strikethrough>`, `<sub>`, `<sup>`, `<code>` |
| `text:a` | `<a xlink:href="…">` |
| `draw:frame`/`draw:image` | `<image>` (блочная или inline) + `<binary>` |
| `table:table` | `<table>` (ячейки → `<p>` внутри `<td>`) |

Стили span разбираются из `office:automatic-styles`: `fo:font-weight="bold"`,
`fo:font-style="italic"`, `style:text-line-through-style`,
`style:text-position` (sub/super), `style:font-name` (моноширинный).

## Публичный API

```python
from pyFB2 import OdtToFb2Converter

converter = OdtToFb2Converter(default_genre="sf", program_used="pyFB2")

book = converter.convert("book.odt")        # путь или bytes
xml = converter.to_xml(book)                # строка FB2
path = converter.write("book.odt", "book.fb2")
```

## CLI

```bash
pyfb2 convert book.odt book.fb2
pyfb2-odt2fb2 book.odt [book.fb2]
python -m pyFB2.odt_to_fb2 book.odt
```

## Ограничения

- Списки (`text:list`) разворачиваются в обычные абзацы (в FB2 списков нет).
- Стихи и цитаты после round-trip становятся абзацами (структура `<poem>` /
  `<cite>` не восстанавливается однозначно).
- Если `meta.xml` отсутствует, метаданные берутся из шапки документа
  (стили `Title` и `Subtitle`), иначе подставляются значения по умолчанию.
- Результат записывается как XML FB2 и проверяется тестами через
  `Fb2Validator` (XSD).
