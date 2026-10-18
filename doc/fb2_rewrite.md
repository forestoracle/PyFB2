# Пересборка FB2 (`rewrite`)

Модуль `pyFB2/fb2_rewrite.py` — «нормализация формы»: файл читается в
структуры (`Fb2Parser`) и собирается заново (`Fb2Writer`).

```text
book.fb2 -> <FictionBook> (структуры) -> book.fb2
```

## Что это даёт

| Эффект | Как получается |
|---|---|
| единая XML-декларация и кодировка UTF-8 | сборка идёт через `Fb2Writer.to_xml` |
| ровные отступы (`  `) | `ET.indent`; `--no-indent` — компактная запись в одну строку |
| порядок элементов по XSD | структуры хранят поля, а не порядок исходного файла |
| исчезают комментарии, неизвестные элементы, «мусорные» пробельные узлы | их нет в структурах |
| проверка результата по XSD **до записи** | `--validate` (`Fb2Validator` + `lxml`, `resolve_entities=False`) |
| нет лишних записей на диск | если содержимое не изменилось — файл не перезаписывается (`--force` отключает) |

В отличие от `normalize` (который исправляет **содержимое**: кодировку,
порядок, обязательные поля, битые ссылки), `rewrite` меняет только форму
представления XML и не добавляет данных.

## Публичный API

```python
from pyFB2 import Fb2Rewriter

rewriter = Fb2Rewriter(indent=True, validate=False, force=False)

xml = rewriter.to_xml("book.fb2")            # структуры -> XML (строка)
rewriter.validate_xml(xml)                   # True/False/None (нет схемы)

result = rewriter.rewrite_file("book.fb2")            # перезапись на месте
result = rewriter.rewrite_file("book.fb2", dest="clean.fb2")
result = rewriter.rewrite_file("book.fb2", dry_run=True)

results = rewriter.rewrite_dir("library", out_dir="clean", suffix="_clean")
```

`RewriteResult` описывает один файл:

| Поле | Смысл |
|---|---|
| `source` | исходный путь |
| `target` | путь результата (`None`, если запись не выполнялась) |
| `skipped` | содержимое не изменилось, файл не перезаписан |
| `changed` | собранный XML отличается от исходного |
| `valid` | результат XSD-проверки (`None` — не проверялось) |
| `error` | текст ошибки (`None` при успехе) |
| `ok` | `error is None` |

Запись выполняется атомарно (временный файл + `os.replace`), переводы строк
сравниваются нормализованно, поэтому файл с CRLF не переписывается только
из-за переводов строк.

## CLI

```sh
pyfb2-rewrite book.fb2                       # перезапись (канонизация)
pyfb2-rewrite book.fb2 --validate            # + проверка результата по XSD
pyfb2-rewrite book.fb2 --out clean.fb2       # в отдельный файл
pyfb2-rewrite book.fb2 --suffix _clean       # рядом, с суффиксом
pyfb2-rewrite library/ --out-dir clean       # дерево каталогов (рекурсивно)
pyfb2-rewrite library/ -q --force            # тихо, перезаписать всё
python -m pyFB2.fb2tools rewrite library/ --out-dir clean --validate
```

Коды возврата: `0` — успех, `1` — были ошибки (файл не разобран/не записан),
`2` — ошибка запуска (файл не найден).

## Связь с другими модулями

- `fb2_parser` — чтение; `fb2_writer` — запись (round-trip);
- `fb2_normalizer` — исправление содержимого (применяйте до/после `rewrite`);
- `fb2_validator` — XSD-проверка (`--validate`);
- `fb2_transcoder` — смена кодировки (если нужен не UTF-8 на выходе);
- `fb2tools` — единая команда `pyfb2 rewrite`.
