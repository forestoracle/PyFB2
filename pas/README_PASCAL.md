# FB2 — версия на FreePascal

Порт Python-модулей библиотеки **pyFB2** на FreePascal. Разбор и сборка XML
выполняются через **fcl-xml** (DOM), входящую в стандартную поставку
FreePascal, — внешних зависимостей нет.

> **Статус: частичный порт.** Портированы базовые модули (структуры, парсер,
> writer, markdown), конвертер HTML, а также библиотечные утилиты (иерархия
> исключений, сканеры кодировок и авторов, перекодировка, переименование).
> Валидатор, нормализатор, индекс и конвертеры Python-версии пока не
> портированы — см. матрицу ниже.

## Состав

| Файл                  | Соответствие в Python  | Статус | Назначение |
|-----------------------|------------------------|--------|----------------------------------------------|
| `fb2_structures.pas`  | `fb2_structures.py`    | готов  | структуры данных (классы/перечисления)       |
| `fb2_parser.pas`      | `fb2_parser.py`        | готов  | разбор FB2 в структуры, идентификаторы глав  |
| `fb2_writer.pas`      | `fb2_writer.py`        | готов  | **сборка FB2 из структур (round-trip)**      |
| `fb2_markdown.pas`    | `fb2_to_markdown.py`   | готов  | экспорт в Markdown + выгрузка изображений    |
| `fb2_images.pas`      | `fb2_images.py`        | готов  | тип/размеры изображений (для конвертеров)    |
| `fb2_to_txt.pas`      | `fb2_to_txt.py`        | готов  | экспорт в обычный текст (TXT)                |
| `fb2_to_epub.pas`     | `fb2_to_epub.py`       | готов  | EPUB 2.0/3.0 (ZIP: OPF, NCX, nav, XHTML)     |
| `epub_to_fb2.pas`     | `epub_to_fb2.py`       | готов  | EPUB → FB2 (OPF, spine, XHTML → структуры)   |
| `fb2_archive.pas`     | — (`zipfile`)          | готов  | чтение ZIP-архива в память (TUnZipper)       |
| `fb2_genres.pas`      | `resources/genres.json` | готов | справочник жанров FictionBook (110)         |
| `fb2_html.pas`        | `fb2_to_html.py`       | готов  | экспорт в HTML (TOC, сноски) + изображения   |
| `fb2_errors.pas`      | `fb2_errors.py`        | готов  | единая иерархия исключений (`EFb2Error`)     |
| `fb2_files.pas`       | — (инфраструктура)     | готов  | обход каталогов, чтение/запись файлов        |
| `fb2_encoding_scanner.pas` | `fb2_encoding_scanner.py` | готов | поиск каталогов с разными кодировками   |
| `fb2_author_scanner.pas`   | `fb2_author_scanner.py`   | готов | поиск каталогов с разными авторами      |
| `fb2_transcoder.pas`  | `fb2_transcoder.py`    | готов  | перекодировка FB2 в UTF-8                    |
| `fb2_renamer.pas`     | `fb2_renamer.py`       | готов  | переименование файла по шаблону              |
| `fb2_group_renamer.pas` | `fb2_group_renamer.py` | готов | групповое переименование                     |
| `fb2_index.pas`       | `fb2_index.py`         | готов  | SQLite-индекс библиотеки, поиск (FTS5, BM25) |
| `fb2_split_merge.pas` | `fb2_split_merge.py`   | готов  | разбиение книги на части и слияние книг      |
| `fb2_normalizer.pas`  | `fb2_normalizer.py`    | готов  | нормализация и авто-исправление FB2          |
| `fb2parser_cli.pas`   | `main()` в парсере     | готов  | CLI: метаданные и дерево заголовков          |
| `fb2markdown_cli.pas` | `main()` в markdown    | готов  | CLI: конвертация в `.md`                     |
| `fb2writer_cli.pas`   | `main()` в writer      | готов  | CLI: round-trip FB2 → структуры → FB2        |
| `fb2html_cli.pas`     | `main()` в `fb2_to_html` | готов | CLI: конвертация в `.html`                   |
| `fb2index_cli.pas`    | `main()` в `fb2_index` | готов  | CLI: build/stats/authors/search/find/dups    |
| `fb2splitmerge_cli.pas` | `main()` в `fb2_split_merge` | готов | CLI: split/merge                     |
| `fb2normalizer_cli.pas` | `main()` в `fb2_normalizer` | готов | CLI: нормализация файла/каталога     |
| `fb2txt_cli.pas`      | `main()` в `fb2_to_txt` | готов | CLI: экспорт в TXT                  |
| `fb2epub_cli.pas`     | `main()` в `fb2_to_epub` | готов | CLI: конвертация в `.epub`          |
| `fb2fromepub_cli.pas` | `main()` в `epub_to_fb2` | готов | CLI: конвертация из `.epub`         |
| `fb2_to_fb3.pas`      | `fb2_to_fb3.py`        | готов  | FB3-контейнер (ZIP: OPC, description, body)  |
| `fb3_to_fb2.pas`      | `fb3_to_fb2.py`        | готов  | FB3 → FB2 (OPC, description, body)           |
| `fb2tofb3_cli.pas`    | `main()` в `fb2_to_fb3` | готов | CLI: конвертация в `.fb3`           |
| `fb3tofb2_cli.pas`    | `main()` в `fb3_to_fb2` | готов | CLI: конвертация из `.fb3`          |
| `fb2_to_docx.pas`     | `fb2_to_docx.py`       | готов  | DOCX (OOXML: document.xml, styles.xml)       |
| `docx_to_fb2.pas`     | `docx_to_fb2.py`       | готов  | DOCX → FB2 (OOXML, HeadingN, таблицы)        |
| `fb2todocx_cli.pas`   | `main()` в `fb2_to_docx` | готов | CLI: конвертация в `.docx`          |
| `docxtofb2_cli.pas`   | `main()` в `docx_to_fb2` | готов | CLI: конвертация из `.docx`         |
| `fb2_to_odt.pas`      | `fb2_to_odt.py`        | готов  | ODT (OpenDocument 1.2: content/styles/meta)  |
| `odt_to_fb2.pas`      | `odt_to_fb2.py`        | готов  | ODT → FB2 (content.xml, стили, таблицы)      |
| `fb2toodt_cli.pas`    | `main()` в `fb2_to_odt` | готов | CLI: конвертация в `.odt`           |
| `odttofb2_cli.pas`    | `main()` в `odt_to_fb2` | готов | CLI: конвертация из `.odt`          |
| `html_to_fb2.pas`     | `html_to_fb2.py`       | готов  | HTML → FB2 (парсер HTML, стили, картинки)    |
| `htmltofb2_cli.pas`   | `main()` в `html_to_fb2` | готов | CLI: конвертация из `.html`         |
| `fb2_to_mobi.pas`     | `fb2_to_mobi.py`       | готов  | MOBI (PalmDB, PalmDOC, MOBI/EXTH)            |
| `mobi_to_fb2.pas`     | `mobi_to_fb2.py`       | готов  | MOBI → FB2 (PalmDB, PalmDOC, EXTH, HTML)     |
| `fb2tomobi_cli.pas`   | `main()` в `fb2_to_mobi` | готов | CLI: конвертация в `.mobi`          |
| `mobitofb2_cli.pas`   | `main()` в `mobi_to_fb2` | готов | CLI: конвертация из `.mobi`         |
| `markdown_to_fb2.pas` | `markdown_to_fb2.py`   | готов  | Markdown → FB2 (заголовки, метаданные, разметка) |
| `markdowntofb2_cli.pas` | `main()` в `markdown_to_fb2` | готов | CLI: конвертация из `.md`      |
| `Makefile`, `build_pascal.bat` | —             | готов  | сборка                                       |

## Чего в порте пока нет

| Модуль Python | Что делает |
|---|---|
| `fb2_validator.py` | валидация по XSD |
| `fb2_to_pdf.py`, `pdf_to_fb2.py` | PDF (нужны reportlab/pypdf) |
| `fb2_web_metadata.py` | обложки/аннотации из Open Library, Google Books, FantLab |
| `fb2_wiki.py` | статья об авторе |

Предлагаемый порядок дальнейшей синхронизации: `fb2_web_metadata`,
`fb2_wiki`. PDF-конвертеры (`fb2_to_pdf`, `pdf_to_fb2`)
зависят от сторонних библиотек (reportlab/pypdf) и в FPC нереализуемы без
внешнего движка.

`fb2_validator.py` (валидация по XSD) — отдельный случай: в fcl-xml нет
XSD-валидатора, поэтому порт потребует внешней библиотеки либо собственной
проверки схемы.

## Сборка

```sh
# Linux/macOS
make

# Windows
build_pascal.bat
```

Либо вручную:

```sh
fpc -Mobjfpc -Sh -O2 fb2parser_cli.pas
fpc -Mobjfpc -Sh -O2 fb2markdown_cli.pas
fpc -Mobjfpc -Sh -O2 fb2writer_cli.pas
fpc -Mobjfpc -Sh -O2 fb2html_cli.pas
```

## Запуск

```sh
# метаданные + дерево заголовков (+ сохранение картинок в каталог)
fb2parser_cli test_book.fb2 images

# конвертация в Markdown
fb2markdown_cli test_book.fb2 book.md images

# round-trip: FB2 -> структуры -> FB2 (проверка парсера и writer)
fb2writer_cli test_book.fb2 out.fb2
fb2writer_cli test_book.fb2            # XML в stdout

# конвертация в HTML (с оглавлением и сносками) + выгрузка картинок
fb2html_cli test_book.fb2 book.html images
```

## Опциональные GUI-компоненты (читалка, карточка, переименование)

`fb2viewer.pas` (`TFb2Viewer`) — тонкая обёртка «FB2 → HTML → просмотрщик»
поверх [BerndGabriel/HtmlViewer](https://github.com/BerndGabriel/HtmlViewer)
(unit `HtmlView`, компонент `THtmlViewer`).

- **Это GUI-модули**, они не входят в состав библиотечных `.pas` и **не
  собираются** одной командой `fpc`/`make`. Они собраны в пакет Lazarus
  **`pyfb2viewer.lpk`** (тип RunAndDesignTime, вкладка «FB2»). Пакет зависит от
  `LCL`, `FrameViewer09` (HtmlViewer) и `printer4lazarus`.
  > Имя пакета — `pyfb2viewer`, а не `fb2viewer`: Lazarus для каждого пакета
  > генерирует служебный юнит `<имя пакета>.pas` и при совпадении перезаписал бы
  > компонент `fb2viewer.pas`.
- Установка: `Package → Open Package File → pas/pyfb2viewer.lpk → Compile →
  Install`; после этого на палитре (вкладка «FB2») появятся `TFb2Viewer`,
  `TFb2Outline`, `TFb2ViewerToolbar`, `TFb2StatusBar`, `TFb2MetadataPanel`,
  `TFb2RenameList`, `TFb2FileTreeView`, `TFb2FileListView`.
- Использование: положить на форму `TFb2Viewer` и `TFb2Outline`, связать
  (`Outline.Viewer := Viewer`) и задать `Viewer.FileName` — компонент
  сконвертирует книгу во временный каталог и откроет её в `THtmlViewer`
  (оглавление, сноски и картинки — как в HTML-выводе), а дерево построится само
  (клик по узлу — переход к главе).
- `TFb2Viewer` поддерживает **CSS**: свойства `Css` (свой CSS-текст; пусто —
  встроенный `DEFAULT_CSS` из `fb2_html`) и `CssFile` (внешний `.css`, UTF-8/
  UTF-16 с BOM или без; приоритет над `Css`), методы `LoadCssFromString`,
  `LoadCssFromFile`, `ResetCss` и функция `EffectiveCss`. Смена CSS
  перерисовывает документ **без повторного разбора книги**:
  `TFb2ToHtmlConverter.RenderHtml` пересобирает HTML из уже разобранного дерева
  (якоря, сноски и оглавление те же), позиция чтения сохраняется. Что именно
  из CSS понимает движок — в таблице `doc/fb2_viewer.md`.
- `fb2outline.pas` (`TFb2Outline`) — дерево заголовков на `TTreeView`, связанное
  с `TFb2Viewer`: показывает оглавление книги и выполняет навигацию по выбору
  узла (`TFb2Viewer.GoToAnchor`). Источник — `TFb2ToHtmlConverter.TocEntries`.
  Картинки узлов — из `TImageList`: свойства `Images`/`StateImages` и события
  `OnGetImageIndex`/`OnGetSelectedIndex` переопубликованы (у `TCustomTreeView`
  они только `public`), компонент сам раздаёт картинки по уровню заголовка
  (`BodyImageIndex`, `ChapterImageIndex`, `SubchapterImageIndex`), а текущей
  главе — `CurrentImageIndex` и маркер `CurrentStateIndex` в `StateImages`
  (отключается `AutoImages`; пересобрать — `ApplyImages`).
- `fb2viewertoolbar.pas` (`TFb2ViewerToolbar`) — панель читалки: история
  (назад/вперёд), размер шрифта, поиск, копирование, печать и предпросмотр.
- `fb2statusbar.pas` (`TFb2StatusBar`) — статус-бар: книга, текущая глава,
  «N из M», прогресс чтения.
- `fb2metadatapanel.pas` (`TFb2MetadataPanel`) — карточка книги: просмотр и
  правка `<description>` с записью обратно в FB2 через `fb2_writer`.
- `fb2renamelist.pas` (`TFb2RenameList`) — предпросмотр переименования «было →
  станет» по шаблону (`fb2_renamer`/`fb2_group_renamer`) с выполнением по кнопке.
- `fb2filetreeview.pas` (`TFb2FileTreeView`) — дерево файловой системы
  (`TShellTreeView`), в котором видны только FB2-файлы: маска `FileMask`
  (по умолчанию `*.fb2`), `HideEmptyDirs` (не показывать каталоги без FB2;
  объём проверки ограничен `HideEmptyDirsScanLimit`), `SelectedFilePath`
  и `SelectFile` (раскрыть дерево до книги и выделить её).
  Связывается с читалкой свойством `Viewer`: книга открывается по двойному
  щелчку или Enter (`AutoOpen`, по умолчанию включено), вручную —
  `OpenSelectedFile`.
- `fb2filelistview.pas` (`TFb2FileListView`) — парный список файлов каталога
  (`TShellListView`) с той же маской; связывается с деревом через
  `ShellTreeView`, есть `Path`, `SelectedFilePath`, `SelectedFilePaths`.
- Загрузка из потока: `Viewer.LoadFromStream(Stream)` — временный каталог не
  используется, картинки отдаются из памяти через `OnImageRequest` (в конвертере
  для этого есть `ConvertStream`/`WriteStream` и `BinaryByFilename`).
- Подробности и подводные камни — в [`doc/fb2_viewer.md`](../doc/fb2_viewer.md).

## Использование как библиотеки

```pascal
uses fb2_structures, fb2_parser, fb2_writer, fb2_markdown, fb2_html;

var
  P: TFb2Parser;
  W: TFb2Writer;
  H: TFb2ToHtmlConverter;
  Book: TFictionBook;
begin
  P := TFb2Parser.Create;
  Book := TFictionBook.Create;
  W := TFb2Writer.Create;
  try
    P.LoadFile('book.fb2');
    Book.Description := P.Parse;
    Book.Bodies.Free;   Book.Bodies := P.ParseBodies;
    Book.Binaries.Free; Book.Binaries := P.ParseBinaries;

    WriteLn(P.Describe(Book.Description));   { метаданные }
    W.Write(Book, 'out.fb2');                { запись FB2 }
    WriteLn(W.ToXML(Book));                  { или строка XML }
  finally
    W.Free;
    Book.Free;
    P.Free;
  end;

  { FB2 -> HTML (оглавление, сноски) + выгрузка картинок }
  H := TFb2ToHtmlConverter.Create(nil, 'images', 1, 6, True, 'Оглавление');
  try
    H.Write('book.fb2', 'book.html');        { файл + изображения }
    WriteLn(H.Convert('book.fb2'));          { или только строка HTML }
  finally
    H.Free;
  end;
end;
```

## Ключевые отличия от Python-версии

- **Владение памятью.** Все структуры — классы, наследники `TFb2Object`.
  Коллекции `TFb2ObjectList` (`TFPGObjectList`) владеют объектами и
  освобождают их автоматически. `TTextList` — список строк `UnicodeString`.
- **Optional-значения.** Вместо `None` для ссылок используется `nil`, для
  чисел — константа `NO_VALUE` (-1), для перечислений — варианты `alNone` /
  `vaNone`; для необязательных `float` (`version`, `price`) — пара «значение +
  флаг `Has…`».
- **Пространства имён.** Парсер сопоставляет имена по локальному имени
  (`LocalName`), что одинаково работает и для документов с `xmlns`, и без
  него. Writer, наоборот, **строит** документ с пространствами имён через
  `CreateElementNS`, а `xmlns:xlink` объявляется один раз на корне.
- **base64.** Декодер реализован вручную (`Base64DecodeString`), чтобы не
  зависеть от дополнительных модулей.
- **Целочисленные идентификаторы заголовков** (`HeadingId`/`ParentId`)
  проставляются методом `AssignHeadingIds`, который вызывается из
  `ParseBodies` — поведение полностью совпадает с Python-версией.
- **Кодировка вывода.** Markdown, HTML и FB2 записываются в UTF-8 без BOM
  (`WriteUtf8File`).
- **Секции с контентом и подсекциями.** Как и в Python, при наличии И
  контента, И подсекций контент оборачивается в анонимную вложенную
  `<section>` (требование XSD: `choice(section+ | контент)`).
- **Конвертер HTML** (`fb2_html.pas`). Повторяет `Fb2ToHtmlConverter`:
  оглавление (вложенный `<ul>`), якоря `sec-N`, двусторонние ссылки сносок
  (`note-ref` ↔ `footnote-back`), режим `InlineImages` (data-URI через
  `Base64EncodeBytes`), встроенный CSS (`DEFAULT_CSS`). Секции-сноски
  определяются как по `type="note"`, так и по принадлежности к телам
  примечаний (`<body name="notes|footnotes|...">`) — как в Python.
- **Индекс библиотеки** (`fb2_index.pas`). Повторяет `Fb2Index`: схема SQLite
  (`books`/`authors`/`titles`/`genres`/`author_facts`/`book_text`),
  инкрементальный обход, поиск по метаданным (SQL-функция `fb2_norm` —
  регистро- и ё-независимо) и полнотекстовый поиск FTS5 с BM25 и сниппетами.
  Использует FPC-юнит `sqlite3` (статическая линковка) — для работы нужен
  **`sqlite3.dll`** в PATH. Если сборка SQLite без FTS5, полнотекстовый поиск
  отключается (`TFb2Index.TextSearch = False`). `fb2index_cli` — CLI
  (build/stats/authors/books/search/find/dups).
- **Разбиение и слияние** (`fb2_split_merge.pas`). Повторяет `Fb2Splitter`
  (режимы `sections`/`size`/`parts`, обновление `<title-info>`/`<document-info>`,
  копирование только используемых `<binary>`) и `Fb2Merger` (объединение
  авторов/жанров, единый `<body>` с заголовками-обёртками, разрешение
  конфликтов `id` у `<binary>` с перепривязкой ссылок). `copy.deepcopy` заменён
  явным клонированием структур. CLI `fb2splitmerge_cli` — подкоманды
  `split`/`merge`.
- **Нормализация** (`fb2_normalizer.pas`). Повторяет `Fb2Normalizer`:
  приведение к UTF-8 (BOM, XML-декларация, переводы строк, управляющие
  символы), порядок дочерних элементов по XSD, добавление обязательных полей
  (`description`/`title-info`/`document-info`/`body`/`section`, `genre`,
  `author`, `book-title`, `lang`, `id`, `version`, `date`), удаление
  дубликатов `<binary>` и (опционально) битых `<image>`, схлопывание пробелов
  в текстовых полях; отчёт о правках (`TNormalizationResult.Fixes`).
  Вместо lxml используется fcl-xml: восстановление ограничено экранированием
  «голых» `&`, а проверка по XSD недоступна (нет валидатора) — как в Python
  при отсутствующем `Fb2Validator`. CLI `fb2normalizer_cli`.
- **Экспорт в TXT** (`fb2_to_txt.pas`, класс `TFb2ToTxtConverter`) и помощник
  для конвертеров `fb2_images.pas` (`DetectImageType`/`ExtensionForMediaType`/
  `ImageSize`/`ScaleToWidth`). Вывод `fb2_to_txt` **побайтово совпадает** с
  Python-версией (после нормализации переводов строк: Python `write_text`
  в текстовом режиме превращает `\n` в CRLF). Важная деталь: для снятия
  пробелов используется собственный `PyStrip` — Pascal-овский `Trim`
  не убирает NBSP (`U+00A0`), который `str.strip()` в Python убирает.
  CLI `fb2txt_cli`.
- **EPUB** (`fb2_to_epub.pas`, класс `TFb2ToEpubConverter`). Повторяет
  `Fb2ToEpubConverter`: промежуточное представление `TEpubBook`
  (метаданные + `TEpubDocument` + `TEpubResource`), обложка, `mimetype` +
  `META-INF/container.xml` + OPF (2.0 или 3.0) + `toc.ncx` + `nav.xhtml`
  (EPUB 3) + `style.css` + XHTML-документы (по секции верхнего уровня) +
  изображения. ZIP пишется через `TZipper` (paszlib); `mimetype` — первым и
  без сжатия. Проверено на реальной книге: **35 из 36 записей архива
  побайтово совпали** с Python-версией (имена и порядок — полностью).
  Отличие — 2 байта в `content.opf`: fcl-xml отбрасывает текстовые узлы из
  одних пробелов (в т.ч. в начале `<p>`), а `lxml` их сохраняет, поэтому
  ведущие `\n\t` в `<dc:description>` теряются. CLI `fb2epub_cli`
  (флаг `--epub3`).
- **EPUB → FB2** (`epub_to_fb2.pas`, класс `TEpubToFb2Converter`). Повторяет
  `EpubToFb2Converter`: чтение ZIP в память (`fb2_archive.pas` на `TUnZipper`
  с `OnCreateStream`/`OnDoneStream`), поиск OPF по `META-INF/container.xml`
  (с фолбэком на первый `*.opf`), чтение `dc:*` метаданных, манифест,
  изображения → `<binary>` (base64), обложка (EPUB3 `meta name="cover"` /
  EPUB2 `guide/reference`), обход `spine` с построением иерархии
  `<section>`/`<title>` по `h1`–`h6`, `p`/`blockquote`/`table`/`ul`/`ol`/
  `pre`/`hr`/`figure`/`img` и инлайн-разметка (`strong`, `em`, `sub`, `sup`,
  `code`, `strike`, `a`, `img`, `br`, `span`…). Жанры сопоставляются по
  справочнику `fb2_genres.pas` (110 записей из `resources/genres.json`),
  фолбэк — `prose`. CLI `fb2fromepub_cli`.
  Проверено на реальной книге (EPUB 2.0 и 3.0): число строк совпадает с
  Python (3434), метаданные (title, авторы, жанры, аннотация, дата, язык, id,
  обложка), структура тела и **все 7 `<binary>` побайтово совпадают**.
  Остаточные отличия — только сериализация `fb2_writer.pas` (см. ниже).
- **Сериализация XML.** `fb2_writer.pas` пишет `xmlns:xlink`/`xlink:href`,
  а Python (`xmlns:l`/`l:href`), иначе упорядочивает атрибуты
  (`<binary id=... content-type=...>` вместо `<binary content-type=... id=...>`)
  и не ставит пробел перед `/>`. Это **общее** расхождение для всего вывода
  писателя (round-trip, нормализатор, split/merge), а не особенность
  EPUB-конвертера; XML при этом эквивалентен (префикс и порядок атрибутов
  не значимы). Приведение к Python требует правки `fb2_writer.pas`.

## Проверка

- Все модули компилируются FPC 3.2.2 (`-Mobjfpc -Sh -O2 -vw`) без ошибок.
- Round-trip проверен на книге с кириллицей, разметкой (`strong`/`emphasis`/
  `code`/`strikethrough`/`a`), вложенными секциями, эпиграфом, цитатой,
  стихами, таблицей (`colspan`), обложкой и двумя `<binary>`.
- **Результат совпадает с Python-версией**: текстовое содержимое и набор
  тегов идентичны (`fb2writer_cli` vs `Fb2Writer` на одном и том же файле).
- **HTML-конвертер сверен с Python** на книге с оглавлением, 16 сносками
  (`<body name="notes">`) и 7 `<binary>`: набор тегов, атрибутов, якорей,
  ссылок оглавления и сносок совпадает символ-в-символ (совпадение при
  игнорировании пробелов — 100 %). Отличия носят чисто оформительский
  характер и объясняются базовым модулем/средой, а не логикой конвертера:
  * **Перевод строки.** Python (`Path.write_text` в Windows) пишет `CRLF`,
    Pascal — `LF` (как и Markdown-модуль).
  * **Пробелы в текстовых узлах.** `fcl-xml` (DOM) отбрасывает ведущий
    пробельно-переводной фрагмент текстового узла (например, `"\n\t "` →
    `" "`), тогда как `xml.etree` сохраняет его целиком. Это поведение
    `fb2_parser.pas`; на структуру HTML оно не влияет.
- Известное ограничение (одинаковое для Python- и Pascal-версии): writer
  сериализует основное подмножество полей — `publish-info`, `custom-info`,
  `keywords`, `translators`, `src-*`, `history`, `output` не сохраняются.
  Это подлежит синхронному расширению обеих версий.
