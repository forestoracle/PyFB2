Готово. Я переименовал модуль и написал обратное преобразование.

## Что сделано

### 1. Переименование `fb2_markdown.py` → `fb2_to_markdown.py`
- Файл переименован (старый `fb2_markdown.py` удалён).
- Класс приведён к общей конвенции: `Fb2MarkdownWriter` → `Fb2ToMarkdownConverter` (с алиасом `Fb2MarkdownWriter` для обратной совместимости).
- Импорты приведены к относительным (`.fb2_parser`, `.fb2_structures`) — как в остальных модулях.
- Обновлены docstring и CLI.
- Попутно исправлен баг в `_finalize`: раньше `rstrip()` «съедал» два пробела переноса строки в стихах — теперь hard-break (`  `) сохраняется.

### 2. Новый модуль `markdown_to_fb2.py` — обратное преобразование
Класс `MarkdownToFb2Converter` (парсер Markdown написан вручную, без внешних зависимостей):
```python
from pyFB2.markdown_to_fb2 import MarkdownToFb2Converter

converter = MarkdownToFb2Converter()
path = converter.write("book.md", "book.fb2")   # файл → файл
book = converter.convert("book.md")             # → структура FictionBook
xml  = converter.to_xml(book)                   # → XML-строка FB2
```

### 3. Расширение `fb2_writer.py`
Добавлена сериализация `poem`/`stanza`/`v`/`epigraph`/`text-author`, а также эпиграфы у `body` и `section` (нужно, чтобы `Fb2Writer` умел выводить стихи, генерируемые обратным конвертером).

### Что поддерживает `MarkdownToFb2Converter`
- `#` (уровень 1) → `<book-title>`, `##` и глубже → иерархия `<section>`.
- `**Автор:**`, `**Жанры:**`, `**Дата:**`, `**Язык:**` → метаданные.
- `> цитата` → аннотация/`<cite>`, `![alt](src)` → обложка/изображение (файлы подхватываются с диска → `<binary>` base64).
- Inline: `**жирный**`, `*курсив*`, `~~зачёркнутый~~`, `` `код` ``, `<sub>/<sup>`, `[текст](url)`.
- `| … |` → `<table>`, строки с двумя пробелами в конце → `<poem>/<stanza>/<v>`.

### Проверка
- Все затронутые модули компилируются.
- Полный цикл **FB2 → Markdown → FB2**: название, автор, жанр, язык, изображение, секции и стихи восстановились.
- Итоговый FB2 валиден по `FictionBook.xsd` (`Fb2Validator`) — **0 ошибок, well-formed**.

### Замечание
Пакет установлен **не-editable** — новые/переименованные модули появятся в импорте после `pip install .` из `pyFB2/` (или добавьте исходный каталог в `PYTHONPATH`). Теперь пара конвертеров симметрична: `Fb2ToMarkdownConverter` ↔ `MarkdownToFb2Converter`.