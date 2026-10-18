# FB3 → FB2 (`fb3_to_fb2`)

Модуль `pyFB2/fb3_to_fb2.py` читает OPC-контейнер FictionBook 3 и собирает
структуры `FictionBook`, сериализуемые `Fb2Writer` (round-trip с
[fb2_to_fb3.md](fb2_to_fb3.md)).

```text
book.fb3 (OPC/ZIP) -> FictionBook (структуры) -> book.fb2
```

## Как находится содержимое

1. `_rels/.rels` — часть с типом связи `…/relationships/Book` (описание);
   если связей нет, берётся `fb3/description.xml`.
2. `fb3/_rels/description.xml.rels` — часть с типом `…/relationships/body`
   (тело); иначе `fb3/body.xml`.
3. `fb3/_rels/body.xml.rels` — картинки: `Id` (`imgN`) → `Target` (`img/…`).
4. `_rels/.rels` — thumbnail → обложка (`<coverpage>`).

## Что переносится

| FB3 | FB2 |
|---|---|
| `<title><main>` | `<book-title>` |
| `<subject link="author">` (`title/main`, `first-name`, `middle-name`, `last-name`) | `<author>` |
| `<fb3-classification><subject>` (коды без пробелов) | `<genre>` |
| `<lang>` | `<lang>` |
| `<annotation><p>` | `<annotation>` |
| thumbnail | `<coverpage>` + `<binary>` |
| `<section>` | секции (вложенность по структуре XML) |
| `<title><p>`, `<p>`, `<br/>` | `<title>`, `<p>`, `<empty-line>` |
| `<epigraph>`, `<annotation>` внутри секции | `<epigraph>`, `<annotation>` |
| `<poem>/<stanza>/<p>` | `<poem>`/`<stanza>`/`<v>` |
| `<blockquote>` | `<cite>` |
| `<table><tr><th|td><p>` | `<table>` (`th` → заголовочная ячейка) |
| `<strong>/<em>/<code>/<strikethrough>/<sub>/<sup>` | соответствующие теги FB2 |
| `<span class="x">` | `<style name="x">` |
| `<a xlink:href>` | `<a href>` |
| `<img src="imgN">` | `<image>` (inline или блочная) + `<binary>` |
| `<subscription>` | `<text-author>` |

## Публичный API

```python
from pyFB2 import Fb3ToFb2Converter

converter = Fb3ToFb2Converter(default_genre="sf", program_used="pyFB2")

book = converter.convert("book.fb3")        # путь или bytes
xml = converter.to_xml(book)
path = converter.write("book.fb3", "book.fb2")
```

## CLI

```bash
pyfb2 convert book.fb3 book.fb2
pyfb2-fb32fb2 book.fb3 [book.fb2]
python -m pyFB2.fb3_to_fb2 book.fb3
```

## Ограничения

- Читается подмножество схемы FB3: описание, тело, картинки.
- Названия жанров FB3 (например, «Прочая образовательная литература») не
  являются кодами FB2 — такие значения заменяются `default_genre`; коды без
  пробелов переносятся как есть.
- Сноски (`<note>`), списки (`ol`/`ul`/`li`), серии и `copyrights`
  игнорируются.
- UUID-идентификаторы FB3 при обратной записи не сохраняются (генерируются
  новые) — FB2 их не хранит.
