Готово. Создан модуль `pyFB2/pyFB2/fb2tools.py` — **единая команда `pyfb2`**, покрывающая все возможности пакета.

## Что сделано

Один argparse-CLI с 16 подкомандами (все инструменты pyFB2 в одной точке входа). Плюс зарегистрирован console-script `pyfb2`; без установки доступно `python -m pyFB2.fb2tools`.

### Подкоманды

| Команда | Что делает | Модуль пакета |
|---|---|---|
| `info` | метаданные, stylesheets, `<binary>`, дерево заголовков (+ `--images`) | `fb2_parser` |
| `validate` | валидация по XSD (файл/каталог, `-r`, `--schema`) | `fb2_validator` |
| `normalize` | нормализация/авто-исправление (`--dry-run`, `--validate`) | `fb2_normalizer` |
| `rewrite` | пересборка формы FB2: структуры → XML (`--validate`, `--force`) | `fb2_rewrite` |
| `convert` | FB2 ↔ EPUB/DOCX/ODT/MOBI/FB3/Markdown/HTML/PDF, FB2 → TXT (`--epub3`, `--toc`) | 17 конвертеров |
| `split` | разбиение по главам/размеру/на N частей | `fb2_split_merge` |
| `merge` | слияние книг (`--title`) | `fb2_split_merge` |
| `fetch` | обложка/аннотация из Open Library, Google Books и FantLab | `fb2_web_metadata` |
| `wiki` | статья об авторе в Википедии (Markdown) | `fb2_wiki` (extra `[wiki]`) |
| `index` | `build` / `stats` / `authors` / `genres` / `duplicates` / `search` (метаданные) / `find` (полнотекст) | `fb2_index` |
| `transcode` | перекодировка (например, windows-1251 → UTF-8) | `fb2_transcoder` |
| `rename` | переименование по шаблону (файл или каталог) | `fb2_renamer`, `fb2_group_renamer` |
| `scan` | `authors` / `encoding` — различающиеся значения в дереве | `fb2_author_scanner`, `fb2_encoding_scanner` |
| `cover` | извлечение обложки в файл | `fb2_parser` |
| `zip` | упаковка FB2 в ZIP-архивы `.fb2.zip` (`--out-dir`, `--remove`, `--skip-existing`, `--dry-run`) | `fb2_zip` |
| `unzip` | распаковка архивов: берутся только `.fb2`, защита от «Zip Slip» (`--out-dir`, `--remove`, `--dry-run`) | `fb2_unzip` |

### Ключевые решения
- **Ленивые импорты** внутри обработчиков: быстрый старт, а опциональные модули (`fb2_to_pdf` — reportlab, `pdf_to_fb2` — pypdf, `wiki` — requests) подключаются через `_require_module()` с понятным сообщением `pip install "pyFB2[pdf]"`.
- **Автоопределение направления конвертации** по расширениям (`_resolve_conversion`): `book.fb2 → book.epub` = экспорт, `book.md → book.fb2` = импорт; иначе `--to ФОРМАТ`.
- **Единые коды возврата**: `0` — успех, `1` — ошибка выполнения, `2` — ошибка запуска (нет команды, неверные параметры).
- Разделяемая логика: `_collect_fb2` (файл/каталог), `_sibling_destination` (out-dir/suffix), `_error` (stderr).

### Примеры
```sh
pyfb2 info book.fb2
pyfb2 validate library/ -r
pyfb2 normalize book.fb2 --dry-run --validate
pyfb2 rewrite library/ --out-dir clean --validate
pyfb2 convert book.fb2 book.epub --epub3
pyfb2 convert book.md back.fb2
pyfb2 convert book.fb2 book.odt
pyfb2 convert book.fb2 book.mobi
pyfb2 convert book.fb2 book.fb3
pyfb2 split book.fb2 -o parts --by parts --parts 3
pyfb2 merge out.fb2 a.fb2 b.fb2 --title "Сборник"
pyfb2 fetch book.fb2 --cover-out covers/
pyfb2 index build library/ --db lib.db && pyfb2 index search "Толстой"
pyfb2 index search "Детство" --by title --db lib.db
pyfb2 index find "ёжик" --db lib.db
pyfb2 transcode library/ -r --from windows-1251
pyfb2 rename book.fb2 --template "${Al} - ${Tt}"
pyfb2 scan authors library/ -v
pyfb2 cover book.fb2 -o cover.jpg
pyfb2 zip library/ --remove             # FB2 -> .fb2.zip (с удалением исходников)
pyfb2 unzip library/ --out-dir fb2      # .fb2.zip -> FB2 в отдельный каталог
```

## Найдено и исправлено попутно
- **Баг в `fb2_group_renamer.py`**: файлы искались как `_item.name` (только имя), из-за чего групповое переименование работало лишь при совпадении CWD с каталогом; теперь передаётся полный путь `str(_item)`, а ошибки пишутся в stderr.
- **`Fb2MetadataFetcher.save_cover`**: путь без расширения (`covers`) теперь трактуется как каталог — раньше создавался файл с именем `covers`.

## Проверка
- 33 новых теста (`tests/test_fb2tools.py`) — все подкоманды, включая коды возврата, отсутствующие файлы, неверные режимы, round-trip Markdown→FB2, `--epub3`, `index build/stats/search`, `cover` без обложки, `fetch` без сети (мок HTTP-слоя).
- Полный прогон: **151 passed** (было 118), `ruff` — чисто.
- Все команды прогнаны вручную на временной библиотеке: `info/validate/normalize/convert/split/merge/cover/index/transcode/scan/rename` — коды возврата корректны, созданные FB2 проходят XSD-валидацию (4/4).

## Подкоманды `zip` / `unzip` (архивы)

Добавлены позже: упаковка FB2 в «однокнижные» ZIP-архивы и распаковка.

- Модули `fb2_zip.py` (`FB2Zip`) и `fb2_unzip.py` (`FB2Unzip`), экспорт из
  `pyFB2`, console-scripts `pyfb2-zip` / `pyfb2-unzip`.
- Атомарная запись архива, `--remove` (удаление исходников), `--skip-existing`
  (не пересобирать существующие), `--out-dir` (с сохранением структуры
  каталогов), `--dry-run`; при распаковке берутся только записи `.fb2`,
  небезопасные пути («Zip Slip») пропускаются.
- Проверка: 55 тестов в `tests/test_zip_unzip.py` и 6 в `tests/test_fb2tools.py`;
  round-trip `desy.fb2` → `.fb2.zip` → `.fb2` даёт байт-в-байт совпадение,
  `ruff` и `mypy` — чисто.
