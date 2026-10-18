Готово. Реализован пункт «Слияние/разбиение FB2» из плана — модуль `pyFB2/pyFB2/fb2_split_merge.py` с классами `Fb2Splitter` и `Fb2Merger`.

## Что сделано

Модуль работает на существующих `Fb2Parser` + `Fb2Writer` (структуры `fb2_structures.py`), внешних зависимостей нет.

### Разбиение — `Fb2Splitter`
```python
from pyFB2 import Fb2Splitter

# по главам (секции верхнего уровня)
Fb2Splitter().split("book.fb2", out_dir="parts")        # -> [Path, ...]

# на 3 примерно равных части
Fb2Splitter(by="parts", parts=3).split("book.fb2", out_dir="parts")

# по размеру: не больше ~300 КБ на часть
Fb2Splitter(by="size", max_size=300_000).split("book.fb2", out_dir="parts")

# получить структуры, не записывая файлы
for name, book in Fb2Splitter().split_book("book.fb2", stem="book"):
    ...
```

| Параметр | Назначение |
|---|---|
| `by` | `sections` (по одной секции), `size` (по размеру), `parts` (на N частей) |
| `level` | глубина нарезки (1 — верхний уровень; предки сохраняются как обёртки) |
| `max_size` / `parts` | лимит размера / число частей |
| `title_suffix` | суффикс названия, например `" (часть {n} из {total})"` |
| `add_sequence` | добавлять `<sequence name="…" number="N"/>` с номером части |
| `update_id` | новый `<document-info>` (id `urn:uuid`, версия, дата, `program-used`) |
| `copy_binaries` | копировать только фактически используемые `<binary>` |
| `keep_extra_bodies` | копировать дополнительные `<body>` (сноски) |
| `filename_template` | шаблон имени (`{stem}`, `{n}`, `{total}`) |

Что важно:
- **`level > 1`** — нарезка по вложенным секциям с сохранением «скелета» предков: часть = цепочка секций-обёрток с одной ветвью (заголовки частей/глав не теряются).
- **`copy_binaries`** — обложка попадает во все части, иллюстрация — только в ту часть, где на неё есть ссылка (обход всех `<image>`: блочных, inline, в стихах/цитатах/таблицах/аннотациях/обложке).
- `max_size` считается по XML-содержимому секций (без общих метаданных и `<binary>`).

### Слияние — `Fb2Merger`
```python
from pyFB2 import Fb2Merger

Fb2Merger(title="Сборник").merge_to_file(["a.fb2", "b.fb2"], "collection.fb2")
book = Fb2Merger().merge(["a.fb2", "b.fb2"])     # -> FictionBook
```

| Параметр | Назначение |
|---|---|
| `title` | название итоговой книги (по умолчанию — из первой) |
| `combine_metadata` | объединять авторов и жанры (дедупликация, порядок сохраняется) |
| `add_source_titles` | оборачивать секции каждой книги в секцию с её названием |
| `merge_binaries` | объединять `<binary>` с разрешением конфликтов `id` |
| `update_id` | новый `<document-info>` (id/версия/дата) |

Что важно:
- **Конфликты `<binary>`**: при совпадении `id` (например, `cover.png` в обеих книгах) новый ресурс получает `id_N`, а **все ссылки в тексте перепривязываются** (`#cover.png` → `#cover.png_2`) — включая обложку и inline-изображения.
- **Обязательные поля**: если у источников нет авторов/жанров, подставляются безопасные значения (схема требует `author+`, `genre+`).
- Результат проходит **валидацию по XSD**.

### CLI
```sh
pyfb2-split book.fb2 -o parts                      # по главам
pyfb2-split book.fb2 --by parts --parts 3          # на 3 части
pyfb2-split book.fb2 --by size --max-size 300000   # по размеру
pyfb2-split book.fb2 --title-suffix " (часть {n})" # с суффиксом названия
pyfb2-merge out.fb2 a.fb2 b.fb2 --title "Сборник"  # слияние
python -m pyFB2.fb2_split_merge split|merge ...    # подкоманды
```

### Проверка
- 25 тестов (`tests/test_split_merge.py`): режимы `sections`/`parts`/`size`, распределение глав, копирование только нужных `<binary>`, обновление `<document-info>`, `<sequence>`, суффикс названия, `level=2` с предками, кастомный шаблон имени, объединение метаданных, обёртки с названиями, разрешение конфликтов `binary` с перепривязкой ссылок, `combine_metadata=False`, отсутствие бинарников, round-trip «разбить → слить», CLI.
- **Каждый результат проверяется `Fb2Validator` по XSD** — все части и слитая книга валидны.
- Итог по пакету: **93 passed**, `ruff` — чисто.
