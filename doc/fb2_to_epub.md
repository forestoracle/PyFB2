Готово. Я реализовал обратное преобразование — класс `Fb2ToEpubConverter` в файле `pyFB2/pyFB2/fb2_to_epub.py`, симметричный уже существующему `EpubToFb2Converter`.

## Что сделано

Новый модуль `fb2_to_epub.py` (~750 строк), переиспользующий существующий `Fb2Parser` (парсинг FB2 в структуры) и структуры из `fb2_structures.py`.

### Публичный API (симметричен `EpubToFb2Converter`)
```python
from pyFB2.fb2_to_epub import Fb2ToEpubConverter

converter = Fb2ToEpubConverter()
path = converter.write("book.fb2", "book.epub")   # файл → файл
book = converter.convert("book.fb2")              # → структура EpubBook
data = converter.to_bytes(book)                   # → bytes ZIP-архива
```

### Промежуточные структуры (dataclass в том же модуле)
- `EpubBook` — метаданные + документы + ресурсы;
- `EpubDocument` — XHTML-документ (id, href, title, content);
- `EpubResource` — файл-ресурс (изображение/CSS).

### Что реализовано
- **Чтение FB2** через `Fb2Parser` (`parse`/`parse_bodies`/`parse_binaries`/`binary_data`).
- **Метаданные** → OPF: `<dc:title>`, `<dc:creator opf:role="aut">`, `<dc:language>`, `<dc:identifier>`, `<dc:date>`, `<dc:description>` (из аннотации), `<dc:subject>` (из жанров).
- **Обложка** `<coverpage>` → `cover-image` + отдельный `cover.xhtml` + `<guide>`.
- **Изображения** `<binary>` → файлы `images/*` (base64 декодируется) + карта ссылок `#id` → `images/…`.
- **Контент**: каждая секция верхнего уровня → отдельный XHTML-документ; заголовки → `<h1>`–`<h6>`, `<p>`, `<strong>`, `<em>`, `<a>`, `<img>`, `<del>` (strikethrough), `<sub>/<sup>/<code>`, `<span class>` (style), `<blockquote>` (cite/epigraph), стихи → `<div class="poem">`, таблицы → `<table>`.
- **Метафайлы EPUB**: `mimetype` (первым, без сжатия), `META-INF/container.xml`, `OEBPS/content.opf` (EPUB 2.0), `OEBPS/toc.ncx`, `OEBPS/style.css`.
- Корректное экранирование через `html.escape`.

### Проверка
Модуль компилируется. Прогнал полный цикл: FB2 → EPUB (ZIP) → round-trip обратно в FB2 через `EpubToFb2Converter` — метаданные (название, автор, жанр, обложка, изображения) восстановились корректно. XHTML и OPF валидны.

### Замечания
- Как и раньше, пакет установлен **не-editable** — новый модуль появится в `import pyFB2.fb2_to_epub` после `pip install .` из каталога `pyFB2/` (или добавьте исходный каталог в `PYTHONPATH`).
- Обложка добавляется первым элементом `spine` (распространённая практика).
- При round-trip семантика стихов (`poem`) упрощается до абзацев — это ожидаемо, т.к. EPUB→FB2 не восстанавливает `poem` из `div.poem`.

## EPUB 3.0 (добавлено)

Пункт «EPUB3» из плана: `Fb2ToEpubConverter` теперь умеет собирать **EPUB 3.0**.

```python
from pyFB2.fb2_to_epub import Fb2ToEpubConverter

Fb2ToEpubConverter(epub_version=3).write("book.fb2", "book3.epub")
```

### Что отличается от EPUB 2.0
| Аспект | EPUB 2.0 (по умолчанию) | EPUB 3.0 (`epub_version=3`) |
|---|---|---|
| OPF | `<package version="2.0">` | `<package version="3.0" xml:lang="ru">` |
| Оглавление | `toc.ncx` | `nav.xhtml` (**XHTML Navigation Document**) с `properties="nav"` |
| Роли авторов | `<dc:creator opf:role="aut">` | `<dc:creator id="creatorN">` + `<meta refines="#creatorN" property="role" scheme="marc:relators">aut</meta>` |
| Обязательное поле | — | `<meta property="dcterms:modified">` (UTC, генерируется автоматически) |
| Обложка | `<meta name="cover">` + `<guide>` | `<meta name="cover">` + `properties="cover-image"` (без `<guide>`) |
| XHTML-документы | XHTML 1.1 + `<meta http-equiv>` | HTML5 doctype + `<meta charset="utf-8"/>` |
| NCX | есть | остаётся дополнительно (совместимость со старыми читалками) |

### `nav.xhtml`
Генерируется методом `_nav_xhtml`: `xmlns:epub`, `<nav epub:type="toc" id="toc">` со ссылками на все документы (кроме обложки) и `<nav epub:type="landmarks" hidden="hidden">` с ориентирами `cover`/`bodymatter`.

```xml
<nav epub:type="toc" id="toc">
  <h1>Оглавление</h1>
  <ol>
    <li><a href="chap1.xhtml">Часть первая</a></li>
  </ol>
</nav>
```

### CLI
```sh
python fb2_to_epub.py book.fb2 book3.epub --epub3
```

### Проверка
- 12 тестов (`tests/test_epub3.py`): версия OPF, `dcterms:modified` (по формату), `nav.xhtml` + `properties="nav"`, landmarks, `cover-image`, HTML5-doctype, отсутствие `<guide>`, сохранение NCX, `mimetype` первым без сжатия, неизменность EPUB 2.0, флаг `book.version`, round-trip EPUB3→FB2, CLI `--epub3`.
- Round-trip EPUB 3.0 → FB2 работает: название, автор, обложка и секции восстанавливаются.
- Итог по пакету: **68 passed**, `ruff` — чисто.
