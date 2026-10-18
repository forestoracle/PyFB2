Готово. Реализован пункт «Скачивание обложек/аннотаций» из плана — модуль `pyFB2/pyFB2/fb2_web_metadata.py` (сетевой «сосед» `fb2_wiki`).

## Что сделано

Класс `Fb2MetadataFetcher`: ищет книгу в открытых каталогах, скачивает обложку и аннотацию и **встраивает их прямо в FB2** (`<coverpage>` + `<binary>` и `<annotation>`).

**Внешних зависимостей нет** — используется только стандартная библиотека (`urllib`), поэтому модуль доступен сразу после установки пакета (в отличие от `fb2_wiki`, требующего extra `[wiki]`).

### Источники (без API-ключей)
| Провайдер | Поиск | Обложка | Аннотация |
|---|---|---|---|
| **Open Library** | `openlibrary.org/search.json` | `covers.openlibrary.org/b/id/{id}-L.jpg` | описание work (`/works/OL…W.json`) |
| **Google Books** | `books/v1/volumes` | `imageLinks.thumbnail` (http→https) | `volumeInfo.description` |
| **FantLab** | `api.fantlab.ru/search-works` | `image` из `/work/{id}` (относительные ссылки абсолютизируются) | `work_description` |

### Публичный API
```python
from pyFB2 import Fb2MetadataFetcher

fetcher = Fb2MetadataFetcher(providers=("openlibrary", "google", "fantlab"), language="ru")

matches = fetcher.search("Война и мир", author="Лев Толстой", limit=5)
meta = fetcher.enrich(matches[0])          # скачать обложку + аннотацию
fetcher.apply("book.fb2", meta=meta, output="book.fixed.fb2")

fetcher.save_cover(meta, "covers/")        # обложка отдельным файлом
title, author = fetcher.book_query("book.fb2")

# Одной командой: взять метаданные из FB2, найти в сети и встроить
fetcher.apply("book.fb2")
```

| Метод | Назначение |
|---|---|
| `search(title, author, limit)` | поиск во всех провайдерах → `List[BookMetadata]` |
| `enrich(meta)` | докачать обложку и аннотацию |
| `fetch(title, author)` | поиск + enrich первого результата |
| `fetch_from_fb2(path)` | взять название/автора из FB2 и найти |
| `apply(path, meta=None, …)` | записать обложку/аннотацию в FB2 |
| `save_cover(meta, path)` | сохранить обложку файлом |
| `book_query(path)` | название и автор из FB2 |

### Запись в FB2 (`apply`)
- **Обложка** → `<binary id="cover.png" content-type="…">` (base64) + `<coverpage><image l:href="#cover.png"/></coverpage>`. Тип определяется **по сигнатуре** (PNG/JPEG/GIF/WEBP/BMP), id уникален (`cover.png`, `cover2.png`, …).
- **Аннотация** → `<annotation>` с `<p>` по абзацам (HTML из веба вычищается).
- **Порядок по XSD сохраняется**: элементы вставляются в правильную позицию (`annotation` → `coverpage` → `lang`), для этого переиспользуется `ELEMENT_ORDER` из `fb2_normalizer`.
- **Повторное применение не дублирует** обложку: старая `<coverpage>` заменяется, а осиротевший `<binary>` удаляется.
- `<version>` увеличивается (`1.0` → `1.1`), `<date>` обновляется.
- Текст книги (mixed-контент: `<strong>`, `<code>`, inline-`<image>`) **не затрагивается**.
- Опции: `set_cover`, `set_annotation`, `update_version`, `dry_run`.

### CLI
```sh
pyfb2-fetch book.fb2                       # найти и встроить (перезапись)
pyfb2-fetch book.fb2 --out book.new.fb2    # в отдельный файл
pyfb2-fetch book.fb2 --list                # только показать варианты
pyfb2-fetch book.fb2 --cover-out covers/   # обложка отдельным файлом
pyfb2-fetch book.fb2 --no-cover --dry-run  # только аннотация, без записи
pyfb2-fetch book.fb2 --provider google     # один источник
```

### Проверка
- 25 тестов (`tests/test_web_metadata.py`) — **полностью без сети** (HTTP-слой подменяется): детект типа изображения, очистка HTML, разбиение на абзацы, `apply` (обложка+аннотация, замена обложки без дублей, порядок по XSD, сохранность текста, опции, dry-run), парсинг ответов Open Library и Google Books, `enrich`, `fetch`, `save_cover`, `book_query`, CLI.
- Результат `apply` проходит **валидацию по XSD** (`Fb2Validator`).
- Итог по пакету: **118 passed**, `ruff` — чисто.

### Замечания
- Найден и исправлен баг: `strip_html` нормализовал пробелы до `html.unescape`, из-за чего `&nbsp;` оставался как `\xa0` — теперь порядок операций правильный.
- Сеть не используется в тестах (важно для CI); реальные запросы проверялись вручную на структуре ответов провайдеров.
