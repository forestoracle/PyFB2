Готово. Создан класс `Fb2Normalizer` — нормализация и авто-исправление FB2 (пункт «Нормализация/авто-исправление FB2» из плана, на базе `Fb2Validator`).

## Что сделано

Новый модуль `pyFB2/pyFB2/fb2_normalizer.py` (~890 строк). Работает через `lxml` (базовая зависимость, как `fb2_validator`), поэтому сохраняет комментарии и позволяет проверять результат по XSD. Определение кодировки переиспользует `fb2_transcoder.detect_encoding`.

### Публичный API
```python
from pyFB2.fb2_normalizer import Fb2Normalizer

normalizer = Fb2Normalizer(validate=True)

xml = normalizer.normalize("book.fb2")                  # строка XML (UTF-8)
normalizer.write("book.fb2", "book.fixed.fb2")          # запись файла -> Path

result = normalizer.report("book.fb2")                  # отчёт без записи
result = normalizer.normalize_file("book.fb2", dest=..., dry_run=True)
results = normalizer.normalize_dir("lib/", out_dir="lib_clean/", suffix=".norm")

result.fixes        # [NormalizationFix(code, message), ...]
result.changed      # bool — были ли правки
result.valid_after  # bool | None — результат проверки по XSD
result.source_encoding
```

### Что исправляется
| Категория | Правки |
|---|---|
| **Кодировка** | BOM (`bom-removed`), перекодировка в UTF-8 (`encoding-fixed`), XML-декларация → `utf-8`, CRLF→LF (`newlines-normalized`), недопустимые управляющие символы (`control-chars-removed`) |
| **Структура** | порядок дочерних элементов по XSD (`reordered`) для `FictionBook`, `description`, `title-info`, `document-info`, `publish-info`, `body`, `section`, `poem`, `stanza`, `epigraph`, `cite`, `annotation`, `title`, `author`, `coverpage`, `table`, `tr` |
| **Обязательные поля** | `<description>`, `<title-info>`, `<document-info>`, `<body>/<section>`, `<genre>`, `<author>`, `<book-title>`, `<lang>`, `<id>` (urn:uuid), `<version>`, `<date>`, `<program-used>` |
| **Дубликаты** | повторяющиеся `<binary>` по `id` (`duplicate-binary-removed`) |
| **Пробелы** | схлопывание в текстовых полях (`whitespace-collapsed`) |
| **Битые ссылки** | `<image>` на отсутствующий `<binary>` (`broken-image-removed`, опция `drop_broken_images`) |
| **Битый XML** | восстановление парсером lxml (`recovered`, опция `recover`) |

### Опции
`normalize_encoding`, `fix_order`, `fill_required`, `drop_duplicate_binaries`,
`drop_broken_images`, `collapse_whitespace`, `strip_control_chars`, `recover`,
`pretty`, `default_genre` (`prose`), `default_lang` (`ru`),
`default_title` (`Без названия`), `default_author` (`Неизвестный автор`),
`program_used`, `schema_path`, `validate`.

### Ключевое техническое решение
При перекодировке XML-декларацию **обязательно** приводим к `utf-8` (метод `_fix_declaration`): иначе lxml читает UTF-8-байты как `windows-1251` и текст превращается в мусор (проверено — это был реальный баг на первом прогоне).

Для ровных отступов при `pretty=True` дерево перед сериализацией перепарсивается с `remove_blank_text=True` — «служебные» пробелы между элементами уходят, а mixed-контент (`<p>Текст <strong>…</strong></p>`) сохраняется.

### CLI
```sh
pyfb2-normalize book.fb2                      # перезапись на месте
pyfb2-normalize lib/ -r --out-dir lib_clean   # каталог рекурсивно
pyfb2-normalize book.fb2 --dry-run --validate # без записи + проверка XSD
```

### Пример
```
$ pyfb2-normalize dirty.fb2 --dry-run --validate
dirty.fb2: изменён (правок: 10) [XSD: OK]
  - [added-document-info] добавлен <document-info>
  - [added-author] добавлен <author><nickname>Неизвестный автор</nickname></author>
  - [duplicate-binary-removed] удалено дубликатов <binary>: 1
  - [whitespace-collapsed] нормализованы пробелы в полях: 1
  - [reordered] исправлен порядок элементов: FictionBook, title-info
```

### Проверка
- 19 тестов (`tests/test_normalizer.py`): порядок, обязательные поля, дубликаты, битые ссылки, пробелы, cp1251→UTF-8, BOM/CRLF, восстановление битого XML, XSD-валидация результата, идемпотентность, запись файла/каталога, отсутствие namespace.
- Нормализация идемпотентна: повторный прогон не даёт правок.
- Итог по пакету: **56 passed**, `ruff` — чисто.
