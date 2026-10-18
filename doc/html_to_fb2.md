Готово. Создан класс `HtmlToFb2Converter` — обратное преобразование HTML → FB2, завершающее пару с `Fb2ToHtmlConverter`.

## Что сделано

Новый модуль `pyFB2/pyFB2/html_to_fb2.py` (~760 строк). Для разбора HTML используется `html.parser` из **стандартной библиотеки** (толерантный к «грязному» HTML) — внешних зависимостей нет.

### Публичный API (симметрично остальным конвертерам)
```python
from pyFB2.html_to_fb2 import HtmlToFb2Converter

converter = HtmlToFb2Converter()
path = converter.write("book.html", "book.fb2")   # файл → файл
book = converter.convert("book.html")             # → структура FictionBook
xml  = converter.to_xml(book)                     # → XML-строка FB2
```

### Что поддерживает
- **Метаданные** из `<header class="book-header">`: `book-title`, `book-author`, `book-genres`, `cover`, `annotation`.
- **Заголовки** `<h1>`–`<h6>` (в т.ч. с id-якорями) → иерархия `<section>/<title>` (через стек уровней).
- **Разметка**: `<strong>/<b>`, `<em>/<i>`, `<del>/<s>/<strike>`, `<sub>/<sup>/<code>`, `<span class>` → `style`, `<a href>` → ссылка, `<img>` → изображение, `<br>`.
- **Блоки**: `<p>` (в т.ч. `class="subtitle"`/`"empty-line"`), `<blockquote>` (и `class="epigraph"` → `<epigraph>`), `<div class="poem">` → `<poem>/<stanza>/<v>`, `<table>` → `<table>` (th→header), `<hr>` → `<empty-line>`.
- **Оглавление** (`<nav class="toc">`) и служебные теги корректно **пропускаются** (в FB2 оглавление не нужно — секции и так есть).
- **Изображения**: файлы рядом с `.html` **или** `data:`-URI → `<binary>` (base64).
- Написан толерантный HTML-парсер (`_HtmlParser` на `HTMLParser`) с восстановлением вложенности, обработкой void-тегов и авто-разбором character references.

### Проверка
- Модуль компилируется.
- Полный цикл **FB2 → HTML → FB2**: название, автор, жанр, обложка, аннотация, изображения (2), секции — восстановились.
- Сохранились `strong`, `emphasis`, `a`, `table`, `cite`, `poem`/`stanza`/`v`, изображения, вложенные секции.
- Итоговый FB2 валиден по `FictionBook.xsd` (`Fb2Validator`) — **0 ошибок, well-formed**.

### Замечание
Пакет установлен **не-editable** — модуль появится в `import pyFB2.html_to_fb2` после `pip install .` из `pyFB2/` (или добавьте исходный каталог в `PYTHONPATH`).

Теперь набор конвертеров проекта образует полный двунаправленный граф вокруг FB2:

| Из → В | FB2 | EPUB | DOCX | Markdown | HTML |
|---|---|---|---|---|---|
| **FB2** | — | `fb2_to_epub` | `fb2_to_docx` | `fb2_to_markdown` | `fb2_to_html` |
| **→ FB2** | — | `epub_to_fb2` | `docx_to_fb2` | `markdown_to_fb2` | `html_to_fb2` |

Все пары используют общий сериализатор `fb2_writer.Fb2Writer`.