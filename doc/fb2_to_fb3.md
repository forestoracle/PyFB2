# FB2 → FB3 (`fb2_to_fb3`)

Модуль `pyFB2/fb2_to_fb3.py` собирает контейнер FictionBook 3 — OPC-пакет
(ZIP) в стиле Open XML. Спецификация: схемы и примеры
[gribuser/FB3](https://github.com/gribuser/FB3).

```text
book.fb2 -> FictionBook (структуры) -> book.fb3 (OPC/ZIP)
```

## Состав контейнера

| Часть | Содержимое |
|---|---|
| `[Content_Types].xml` | типы частей (`application/fb3-description+xml`, `application/fb3-body+xml`, core-properties, картинки) |
| `_rels/.rels` | связи пакета: thumbnail (обложка), core-properties, `…/relationships/Book` → описание |
| `fb3/description.xml` | `<fb3-description>`: название, связи, классификация, язык, аннотация |
| `fb3/body.xml` | `<fb3-body>`: секции, абзацы, стихи, таблицы, картинки |
| `fb3/meta/core.xml` | Dublin Core (`dc:title`, `dc:creator`, `dc:description`) |
| `fb3/_rels/description.xml.rels` | связь описания с телом (`…/relationships/body`) |
| `fb3/_rels/body.xml.rels` | связи тела с картинками (`…/relationships/image`) |
| `fb3/img/*` | изображения из `<binary>` |

Пространства имён: `http://www.fictionbook.org/FictionBook3/description`
и `…/body`. Все идентификаторы (`<fb3-description id>`, `<fb3-body id>`,
`<section id>`, `<subject id>`) — UUID (генерируются `uuid4`).

## Соответствие элементов

| FB2 | FB3 |
|---|---|
| `<book-title>` | `<title><main>…</main></title>` |
| `<author>` | `<fb3-relations><subject link="author" id="…">` + `first-name`/`middle-name`/`last-name` |
| `<genre>` | `<fb3-classification><subject>…</subject>` |
| `<annotation>` | `<annotation><p>…</p></annotation>` |
| `<lang>`, `<document-info date>` | `<lang>`, `<document-info created/updated>` |
| секции | `<section id="UUID">` с `<title>`, `<epigraph>`, `<annotation>` и вложенными `<section>` |
| `<p>`, `<subtitle>`, `<empty-line>` | `<p>`, `<p>`, `<br/>` |
| `<strong>/<emphasis>/<code>/<strikethrough>/<sub>/<sup>` | `<strong>`, `<em>`, `<code>`, `<strikethrough>`, `<sub>`, `<sup>` |
| `<style name="x">` | `<span class="x">` |
| `<a href>` | `<a xlink:href="…">` |
| `<image>`, `<binary>` | `<img src="imgN"/>` + `fb3/img/*` + связь `imgN` |
| `<poem>/<stanza>/<v>` | `<poem><stanza><p>…</p></stanza></poem>` |
| `<cite>`, `<epigraph>` | `<blockquote>`, `<epigraph>` (+ `<subscription>`) |
| `<table>` | `<table><tr><th|td><p>…</p></…>` |

## Публичный API

```python
from pyFB2 import Fb2ToFb3Converter

converter = Fb2ToFb3Converter()

document = converter.convert("book.fb2")    # -> Fb3Document
data = converter.to_bytes(document)         # -> bytes ZIP
path = converter.write("book.fb2", "book.fb3")
```

| Структура | Поля |
|---|---|
| `Fb3Document` | `identifier`, `description_xml`, `body_xml`, `core_xml`, `images`, `cover` |
| `Fb3Image` | `rel_id`, `filename`, `media_type`, `data` |

## CLI

```bash
pyfb2 convert book.fb2 book.fb3
pyfb2-to-fb3 book.fb2 [book.fb3]
python -m pyFB2.fb2_to_fb3 book.fb2
```

Обратное направление — [fb3_to_fb2.md](fb3_to_fb2.md).

## Ограничения

- FB3 — развивающийся формат (LitRes FB3Reader/Editor); модуль реализует
  подмножество схемы: описание, тело, изображения, метаданные.
- Не поддерживаются: `periodical`, `sequence` (серии), `copyrights`,
  списки (`ol`/`ul`/`li`), сноски (`note`), `target-audience`.
- SVG-картинки пропускаются.
- Готовый контейнер проверяется тестами структурно (части, связи,
  well-formed XML, UUID) — внешним валидатором FB3 не проверялся.
