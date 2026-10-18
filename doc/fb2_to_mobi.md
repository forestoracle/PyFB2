# FB2 → MOBI (`fb2_to_mobi`)

Модуль `pyFB2/fb2_to_mobi.py` собирает файл Mobipocket/Kindle (KF7):
база данных Palm (PDB) с заголовками PalmDOC, MOBI и EXTH — **только
стандартная библиотека**.

```text
book.fb2 -> FictionBook (структуры) -> HTML (Mobi7) -> PalmDOC -> book.mobi
```

## Структура файла

| Запись | Содержимое |
|---|---|
| 0 | PalmDOC-заголовок (16 байт) + MOBI-заголовок (232 байта) + EXTH + полное название |
| 1..N | текст, разбитый на блоки по 4096 байт (сжатые PalmDOC LZ77) |
| N+1.. | изображения (по одной записи на картинку) |

Заголовок PDB: name (первые 31 байт названия), `type=BOOK`, `creator=MOBI`.

## Метаданные (EXTH)

| Тип | Значение |
|---|---|
| 100 | автор (по одной записи на автора) |
| 103 | аннотация |
| 105 | жанр |
| 201 / 202 | `coveroffset` / `thumboffset` — индекс обложки среди записей изображений |
| 503 | `cdetype` = `EBOK` |
| 524 | язык (`ru`, `en`, …) |

## Текст

HTML профиля Mobi7: `<h1>`…`<h6>` (заголовки секций), `<p>`, `<b>`, `<i>`,
`<s>`, `<sub>`, `<sup>`, `<tt>`, `<blockquote>` (эпиграфы, цитаты, стихи),
`<table>`, `<a href>`, `<img recindex="00001"/>`.

Сжатие: PalmDOC (LZ77 + byte-pair, кодирование «пробел + символ» байтами
`0xC0..0xFF`). Если хотя бы один блок не помещается в 4096 байт после
сжатия, весь текст пишется без сжатия (`compression=1`).

## Публичный API

```python
from pyFB2 import Fb2ToMobiConverter
from pyFB2.fb2_to_mobi import palmdoc_compress

converter = Fb2ToMobiConverter(compress=True)

book = converter.convert("book.fb2")        # -> MobiBook (html, images, cover_index)
data = converter.to_bytes(book)             # -> bytes PDB
path = converter.write("book.fb2", "book.mobi")

packed = palmdoc_compress(b"...")           # сжатие одного блока (≤ 4096 байт)
```

| Структура | Поля |
|---|---|
| `MobiBook` | `title`, `authors`, `language`, `description`, `genres`, `html`, `images`, `cover_index` |
| `MobiImage` | `filename`, `media_type`, `data` |

## CLI

```bash
pyfb2 convert book.fb2 book.mobi
pyfb2-to-mobi book.fb2 [book.mobi]
python -m pyFB2.fb2_to_mobi book.fb2
```

Обратное направление — [mobi_to_fb2.md](mobi_to_fb2.md).

## Ограничения

- HUFF/CDIC-компрессия (`17480`) не используется — только PalmDOC.
- Изображения крупнее 64 КБ (запись PDB) пропускаются: одна картинка —
  одна запись.
- Формат — KF7 (Mobi7). KF8/AZW3 (внутренний EPUB) не генерируется.
- Проверка сторонними ридерами не выполнялась; тесты контролируют структуру
  PDB/MOBI/EXTH и корректность round-trip через `mobi_to_fb2`.
