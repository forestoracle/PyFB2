Готово. Я реализовал класс `Fb2ToDocxConverter` для преобразования FB2 в DOCX (Word).

## Что сделано

Создан файл `pyFB2/pyFB2/fb2_to_docx.py` (~880 строк). Он генерирует DOCX (формат Office Open XML) **без внешних зависимостей** — через `zipfile` + XML стандартной библиотеки, переиспользуя существующий `Fb2Parser` и структуры `fb2_structures.py`. Это полностью в духе проекта (как `epub_to_fb2` и `fb2_to_epub`).

### Публичный API (симметричен остальным конвертерам)
```python
from pyFB2.fb2_to_docx import Fb2ToDocxConverter

converter = Fb2ToDocxConverter()
path = converter.write("book.fb2", "book.docx")   # файл → файл
book = converter.convert("book.fb2")              # → структура DocxBook
data = converter.to_bytes(book)                   # → bytes ZIP-архива DOCX
```

### Промежуточные структуры
- `DocxBook` — метаданные + XML документа + изображения + гиперссылки;
- `DocxImage` — изображение (relId, файл, MIME, байты, размеры в EMU).

### Что реализовано
- **Метаданные** → `docProps/core.xml` + титул в начале документа (название, авторы, аннотация, обложка).
- **Заголовки** секций → стили `Heading1`–`Heading6` (заданы в `word/styles.xml` с `outlineLvl`).
- **Разметка**: `<strong>`→bold, `<emphasis>`→italic, `<strikethrough>`→зачёркивание, `<sub>/<sup>`→подстрочный/надстрочный, `<code>`→моноширинный, `<a>`→настоящая гиперссылка (внешний relationship), `<style name>`→проход.
- **Блоки**: `<cite>`/`<epigraph>` → стиль `Quote`, стихи (`poem/stanza/v`) → строки с отступом, `<table>` → настоящая таблица Word, `<empty-line>` → пустой абзац.
- **Изображения** `<binary>` → `word/media/*` со встроенными `w:drawing` (размеры PNG/JPEG/GIF определяются из заголовков, масштабируются до `max_image_width_inches=6.0`).
- **Метафайлы**: `[Content_Types].xml`, `_rels/.rels`, `word/_rels/document.xml.rels`, `word/styles.xml`, `word/document.xml`, `docProps/core.xml`, `docProps/app.xml`.

### Проверка
Модуль компилируется. Сгенерированный DOCX проверен:
- все XML-части **well-formed**;
- целостность relationships (`r:embed`/`r:id` из `document.xml` соответствуют `document.xml.rels`) — **все ссылки разрешены**;
- структура ZIP корректна (все обязательные части на месте).

### Замечания
- Пакет установлен **не-editable** — новый модуль появится в `import pyFB2.fb2_to_docx` после `pip install .` из `pyFB2/` (или добавьте исходный каталог в `PYTHONPATH`).
- `python-docx` не используется (и не требуется) — генерация идёт напрямую в OOXML; установить его для проверки не удалось (нет доступа к сети в окружении), поэтому валидация выполнена структурно (well-formed + relationships).
- Формат — DOCX (OOXML, `.docx`), не старый бинарный `.doc`.