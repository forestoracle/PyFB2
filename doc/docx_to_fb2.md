Готово. Я реализовал обратное преобразование — класс `DocxToFb2Converter` (DOCX → FB2), а заодно вынес общий сериализатор FB2 в отдельный переиспользуемый модуль.

## Что сделано

### 1. Новый модуль `fb2_writer.py` (общий сериализатор)
Класс `Fb2Writer` — сериализация структуры `FictionBook` в XML FB2. Раньше эта логика была «зашита» приватными методами внутри `EpubToFb2Converter`; теперь она переиспользуется всеми конвертерами:
```python
from pyFB2.fb2_writer import Fb2Writer
xml = Fb2Writer().to_xml(book)
Fb2Writer().write(book, "book.fb2")
```

### 2. Рефакторинг `epub_to_fb2.py`
Убраны дублирующие `_build_*` методы (~280 строк); `to_xml` теперь делегирует в `Fb2Writer`. Поведение сохранено (проверено round-trip + валидация по XSD).

### 3. Новый модуль `docx_to_fb2.py`
Класс `DocxToFb2Converter` — обратное преобразование (DOCX → FB2), без внешних зависимостей:
```python
from pyFB2.docx_to_fb2 import DocxToFb2Converter

converter = DocxToFb2Converter()
path = converter.write("book.docx", "book.fb2")   # файл → файл
book = converter.convert("book.docx")             # → структура FictionBook
xml  = converter.to_xml(book)                     # → XML-строка FB2
```

### Что поддерживает `DocxToFb2Converter`
- **Метаданные** `docProps/core.xml` → `<title-info>`/`<document-info>` (название, авторы, язык, аннотация, идентификатор, дата).
- **Заголовки** стилей `Heading1`–`Heading6` → иерархия `<section>/<title>` (через стек уровней).
- **Разметка runs**: `w:b`→strong, `w:i`→emphasis, `w:strike`→strikethrough, `w:vertAlign`→sub/sup, `w:rStyle Code`→code; гиперссылки `w:hyperlink`→`<a>`.
- **Таблицы** `w:tbl` → `<table>` (первая строка считается заголовочной).
- **Изображения** `w:drawing` → `<binary>` (base64) со ссылками `#id`.
- Стиль `Title` → название книги, `Subtitle` → `<subtitle>`, `Quote` → `<cite>`.

### Проверка
- Все 5 модулей компилируются.
- Полный цикл **FB2 → DOCX → FB2** прошёл: название, автор, жанр, язык, изображения восстановились корректно.
- Итоговый FB2 валиден по `FictionBook.xsd` (`Fb2Validator`) — **0 ошибок, well-formed**.
- Рефакторинг `epub_to_fb2` не сломал существующее преобразование.

### Замечание
Пакет установлен **не-editable** — новые/изменённые модули появятся в импорте после `pip install .` из `pyFB2/` (или добавьте исходный каталог в `PYTHONPATH`). Итоговая пара конвертеров теперь симметрична: `Fb2ToDocxConverter` ↔ `DocxToFb2Converter` (аналогично `Fb2ToEpubConverter` ↔ `EpubToFb2Converter`).