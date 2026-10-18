# Можно ли на FreePascal собрать просмотрщик FB2 из `fb2_html.pas` и `THtmlViewer`?

Да — и это даже проще, чем случай с Markdown: `fb2_html.pas` уже отдаёт готовый
HTML, а `THtmlViewer` из [BerndGabriel/HtmlViewer](https://github.com/BerndGabriel/HtmlViewer)
его показывает. То есть отдельный конвертер писать не нужно, достаточно тонкой
GUI-обёртки.

## Ключевая схема

```
book.fb2 → TFb2ToHtmlConverter (fb2_html.pas) → book.html + images/
         → THtmlViewer.LoadFromFile('book.html')
```

`fb2_html.pas` — «чистый» модуль без GUI-зависимостей, поэтому библиотека
остаётся нейтральной к GUI, а визуальный компонент — просто надстройка.

## Почему именно этот HtmlViewer

- **Unicode/UTF-8** (в отличие от старых ANSI-сборок) — кириллица не «поедет».
- Работает в **Lazarus 1.2+** (Windows/Linux, 32 и 64 бита) и Delphi 2009+.
- Поддерживает **HTML 4.01** и многие свойства **CSS**.
- Бонусом для читалки FB2: печать и предпросмотр, поиск по тексту, копирование
  в буфер, масштабирование.

## Установка в Lazarus

1. Клонировать репозиторий; брать ветку релиза **`HtmlViewer-11.10`**
   (в `master` — версия 11.11-dev).
2. `Package → Open Package File` → `package/FrameViewer09.lpk` → **Compile**,
   затем **Install**. Пакет требует `LCL`, `FCL`, `printer4lazarus`
   (последний идёт вместе с Lazarus). На палитре появятся `THtmlViewer`,
   `TFrameViewer`, `TFrameBrowser`.
3. В `uses` подключается unit **`HtmlView`** (и `HtmlGlobals` для типа
   `ThtString`).
4. `Package → Open Package File` → **`pas/pyfb2viewer.lpk`** → **Compile**,
   затем **Install**. Пакет зависит от `LCL`, `FrameViewer09` и
   `printer4lazarus`; после установки на палитре появится вкладка **FB2** с
   компонентами `TFb2Viewer`, `TFb2Outline`, `TFb2ViewerToolbar`,
   `TFb2StatusBar`, `TFb2MetadataPanel`, `TFb2RenameList`,
   `TFb2FileTreeView` и `TFb2FileListView`.
   (Если HtmlViewer не установлен — сначала пункты 1–2.)

   > Имя пакета — `pyfb2viewer`, а не `fb2viewer`: Lazarus для каждого пакета
   > генерирует «unit пакета» с именем самого пакета (`<pkg>.pas`), и при
   > совпадении с именем юнита он бы **перезаписал** компонент
   > `fb2viewer.pas`. Файл `pyfb2viewer.pas` — служебный, генерируется Lazarus.

## API, на который опирается компонент

```pascal
// unit HtmlView
procedure LoadFromFile(const FileName: ThtString; DocType: THtmlFileType = HTMLType);
procedure LoadFromString(const S: ThtString; const Reference: ThtString;
  DocType: THtmlFileType);
procedure Load(const Url: ThtString);
property Text: ThtString;                        // загрузка HTML-строки

property OnHotSpotClick: THotSpotClickEvent;     // (Sender; const SRC: ThtString; var Handled: Boolean)
property OnImageRequest;                         // (Sender; const SRC: String; var Stream: TMemoryStream)
property OnStreamRequest;                        // (Sender; const SRC: String; var Stream: TStream)

property DefFontName, DefPreFontName: ThtString;
property CharSet: TFontCharSet;
```

`Reference` у `LoadFromString` — базовый URL для относительных ссылок; у
`LoadFromFile` база — сам файл. Поэтому проще всего писать HTML и картинки на
диск (это уже умеет `TFb2ToHtmlConverter.Write`) и звать `LoadFromFile`.

## Готовый компонент

`pas/fb2viewer.pas` — класс `TFb2Viewer` (наследник `TCustomPanel`), который
держит внутри `THtmlViewer` и умеет:

- `FileName: TFileName` — загрузка FB2 (установка пути сразу конвертирует и
  показывает книгу);
- `Reload` — перечитать текущий файл;
- `ImageDir`, `HeadingOffset`, `MaxHeadingLevel`, `IncludeToc`, `TocTitle`,
  `IncludeAnnotation`, `IncludeEpigraphs`, `IncludeCover`, `NoteLinks`,
  `InlineImages` — проброс параметров в `TFb2ToHtmlConverter`;
- `Viewer: THtmlViewer` — доступ к движку (шрифты, печать, поиск);
- `Css` / `CssFile` — оформление документа (см. раздел «CSS» ниже);
- `GoToAnchor(Anchor)` — переход к заголовку/сноске по якорю;
- `HandleInternalLink(Src)` — обработка клика по внутренней ссылке; обратные
  ссылки сносок (`#noteref-…`) компонент обрабатывает сам, возвращая читателя
  туда, откуда он пришёл (см. про якоря сносок ниже);
- `Converter` — конвертер последнего документа (`TocEntries`, `Binaries`, …);
- `OnDocumentLoad` — событие после загрузки (его использует дерево заголовков);
- `OnLoadProgress` / `AddLoadProgressListener` — ход загрузки: этап и процент
  0..100 (см. «Прогресс загрузки» ниже); `ProcessMessagesOnLoad` — опционально
  прокачивать сообщения между этапами (по умолчанию выключено).

> **Сноски и якоря.** HtmlViewer неверно определяет Y у **инлайновых** якорей
> (`id` на `<a>`/`<span>` внутри абзаца) — он отдаёт конец документа. Поэтому
> `fb2_html.pas` вешает якорь обратной ссылки на **блок** — абзац с первой
> ссылкой на сноску (`<p id="noteref-nN">`), и обратные ссылки ведут на него:
> блочные якоря движок позиционирует корректно. Дополнительно `TFb2Viewer`
> запоминает точную позицию чтения при клике по ссылке-сноске и возвращает к ней
> при клике по обратной ссылке (`HandleInternalLink`; состояние — `FNoteBackPos`,
> сбрасывается при загрузке книги). Если позиция не запоминалась (читатель ушёл
> в сноски напрямую), возврат выполняет движок по блочному якорю — то есть в
> абзац со ссылкой.

Ключевой метод (запись во временный каталог + `LoadFromFile`):

```pascal
Conv := TFb2ToHtmlConverter.Create(nil, FImageDir, FHeadingOffset,
  FMaxHeadingLevel, FIncludeToc, FTocTitle, FIncludeAnnotation,
  FIncludeEpigraphs, FIncludeCover, FInlineImages, FNoteLinks,
  EffectiveCss);   { последний параметр — CSS (<style> в <head>) }
try
  HtmlPath := Conv.Write(AFileName,
    IncludeTrailingPathDelimiter(FTempDir) + 'book.html');   { HTML + картинки }
finally
  Conv.Free;
end;
FViewer.LoadFromFile(HtmlPath);
```

Внешние ссылки перехватываются через `OnHotSpotClick` и уходят в системный
браузер (`LCLIntf.OpenURL`), а внутренние якоря (`#sec-N`, `#n_1`,
`#noteref-n_1`) отдаются движку — оглавление и двусторонние переходы к сноскам
работают сами.

## CSS

Оформление книги задаётся CSS: `fb2_html.pas` кладёт его в `<style>` внутри
`<head>`, а `THtmlViewer` разбирает этот блок и применяет свойства при
отрисовке (проверено на реальном `test.fb2`: документ с `DEFAULT_CSS` имеет
длину 394 886, без CSS — 408 279).

`TFb2Viewer` даёт два способа подменить оформление:

```pascal
V.Css := 'p { text-indent: 1.2em; } body { font-family: Georgia, serif; }';
V.LoadCssFromFile('C:\themes\sepia.css');   { внешняя тема }
V.LoadCssFromString('p { margin: 0; }');    { то же, что V.Css := ... }
V.ResetCss;                                 { вернуться к DEFAULT_CSS }
```

| Свойство / метод | Что делает |
|---|---|
| `Css: UnicodeString` | CSS-текст (содержимое `<style>`). Пусто (по умолчанию) — используется встроенный `DEFAULT_CSS` из `fb2_html.pas` |
| `CssFile: TFileName` | внешний `.css`-файл (UTF-8/UTF-16 с BOM или без). Если задан и читается — используется **вместо** `Css` |
| `EffectiveCss: UnicodeString` | итоговый CSS: файл → `Css` → `DEFAULT_CSS` |
| `LoadCssFromString(ACss)` | задать текст и перерисовать (отключает `CssFile`) |
| `LoadCssFromFile(AFileName)` | подключить файл и перерисовать (нет файла — исключение; содержимое кэшируется) |
| `ResetCss` | вернуться к `DEFAULT_CSS` |

При смене CSS документ **перерисовывается без повторного чтения и разбора
FB2**: `TFb2ToHtmlConverter.RenderHtml` пересобирает HTML из уже разобранного
дерева (текст, якоря `sec-N`, ссылки сносок и оглавление остаются теми же,
меняется только `<style>`), поэтому `DocumentSerial` не растёт и
`TFb2Outline` не перестраивает дерево, а позиция чтения сохраняется. В
файловом режиме заново пишется и `book.html` во временном каталоге. CSS можно
задать и до открытия книги — он применится при загрузке (`Css` учитывается в
момент создания конвертера).

### Что движок реально применяет

Проверено на `THtmlViewer` 11 (загрузка `LoadFromString`, как это делает
`TFb2Viewer`):

| Работает | Игнорируется |
|---|---|
| селекторы по тегу, классу (`.toc`), id, `p.subtitle`, потомки (`.toc a`, `section.footnote p`), групповые (`h1, h2`) | `max-width` |
| `font-family`, `font-size`, `font-style`, `font-weight`, `line-height` | `text-indent` |
| `margin`, `padding`, `border`, `background`, `color` | `border-radius` |
| `text-align`, `:hover` (в подсказках ссылок), таблицы (`border-collapse`) | `@media`/`@import` — частично |

Поэтому `DEFAULT_CSS` (вёрстка «как в Python-версии») в движке работает не
целиком: `max-width: 42em` и `text-indent` он игнорирует, зато шрифты,
интерлиньяж, отступы блоков и рамки применяются. Если нужен предсказуемый
результат — задайте свой `Css`, опираясь на левую колонку таблицы.

## Загрузка из потока (без временных файлов)

`TFb2Viewer.LoadFromStream(AStream: TStream)` — временный каталог **не
используется**: HTML держится в памяти, а картинки отдаются из `<binary>` через
`OnImageRequest` (потоком, без записи файлов на диск).

```pascal
FS := TFileStream.Create('book.fb2', fmOpenRead or fmShareDenyWrite);
try
  V.LoadFromStream(FS);          { результат тот же, что и у LoadFromFile }
finally
  FS.Free;
end;
```

Под капотом:

- конвертер получил `ConvertStream(AStream)` / `WriteStream(AStream, HtmlPath)`;
- `TFb2ToHtmlConverter.BinaryByFilename('images/cover.jpg')` находит `<binary>`
  по имени файла из `<img src>` (нужно для отдачи картинок из памяти);
- `TFb2Viewer` подписывает `OnImageRequest` и возвращает `TMemoryStream` с
  байтами картинки (поток принадлежит компоненту, HtmlViewer его не
  освобождает — как в официальном демо `Demos/Other Demos/OnStreamRequest`).

Файловый режим (`LoadFromFile`) пишет во временный каталог HTML и **только те
картинки, что реально попали в HTML** (`TFb2ToHtmlConverter.OnlyUsedImages`):
книги с большим числом неиспользуемых `<binary>` не заваливают temp-каталог
(пример — `test.fb2`: 525 бинарников, а ссылка в тексте только на обложку).
`OnImageRequest` в этом режиме снимается.

## Дерево заголовков (`TFb2Outline`)

`pas/fb2outline.pas` — компонент на `TTreeView`, связанный с `TFb2Viewer`:

```pascal
O := TFb2Outline.Create(Self);
O.Parent := LeftPanel;  O.Align := alClient;
O.Viewer := V;                 { связать с просмотрщиком }
V.FileName := 'book.fb2';      { дерево построится само; выбор узла -> переход }
```

- источник данных — `TFb2ToHtmlConverter.TocEntries` (тот же список
  `level`/`anchor`/`title`, из которого строится `<nav class="toc">`), поэтому
  дерево всегда совпадает с оглавлением в самом документе;
- связь — через `TFb2Viewer.AddDocumentLoadListener` (подписчиков может быть
  несколько, см. ниже): после загрузки книги дерево перестраивается
  автоматически. «Новый документ или тот же» подписчик определяет по
  `TFb2Viewer.DocumentSerial` — счётчику, который растёт при каждой загрузке
  (сравнивать указатель `Converter` нельзя: конвертер пересоздаётся, и
  аллокатор может вернуть тот же адрес — тогда новый документ выглядел бы как
  прежний, и дерево не обновилось бы);
- выбор узла вызывает `TFb2Viewer.GoToAnchor('sec-N')`;
- **обратная связь**: при ручной прокрутке текста (колесо, клавиши, полоса
  прокрутки) или переходе по внутренней ссылке дерево подсвечивает текущую
  главу — узел с наибольшей позицией, не выходящей за верхнюю границу области
  чтения (`TrackMargin`, по умолчанию 16 px). Свойства `AutoTrackScroll`
  (по умолчанию `True`) и `TrackMargin`, метод `CurrentIndex`, метод
  `UpdateCurrent` (пересчитать вручную);
- свойство `Visible` переопубликовано (у `TCustomTreeView` оно объявлено
  `public`) — дерево можно скрывать/показывать из инспектора объектов или в
  коде; так же переопубликованы `Align` и `Anchors`.

### Картинки узлов (`TImageList`)

`TImageList` подключается свойством **`Images`** (переопубликовано: у
`TCustomTreeView` `Images`/`StateImages` объявлены только `public`, поэтому в
инспекторе объектов и в `.lfm` их не было). Компонент сам раздаёт картинки
узлам по уровню заголовка:

| Свойство | Что задаёт |
|---|---|
| `Images` | список картинок — «поставщик» для узлов |
| `StateImages` | второй список: маркер текущей главы |
| `AutoImages` (по умолчанию `True`) | раздавать картинки автоматически |
| `BodyImageIndex` | картинка тела книги (level 0), по умолчанию `-1` |
| `ChapterImageIndex` | картинка глав (level 1) |
| `SubchapterImageIndex` | картинка подглав (level ≥ 2) |
| `CurrentImageIndex` | картинка текущей (подсвеченной) главы; `-1` — как у уровня |
| `CurrentStateIndex` | номер картинки-маркера текущей главы в `StateImages` |

```pascal
O.Images := ImageList1;          { TImageList с картинками }
O.BodyImageIndex := 0;           { тело книги }
O.ChapterImageIndex := 1;        { главы }
O.SubchapterImageIndex := 2;     { подглавы }
O.CurrentImageIndex := 3;        { текущая глава }
O.StateImages := ImageList2;     { второй список — маркер }
O.CurrentStateIndex := 1;
```

Детали:

- картинка назначается и в `ImageIndex`, и в `SelectedIndex`: LCL рисует у
  **выделенного** узла именно `SelectedIndex`, а текущая глава выделяется
  программно — иначе её картинка просто исчезала бы;
- при смене текущей главы (прокрутка текста, переход по ссылке, клик по узлу)
  картинки переставляются: прежняя глава получает картинку своего уровня,
  новая — `CurrentImageIndex` (и маркер в `StateImages`);
- индексы по умолчанию `-1` — пока не назначен `Images`, вид дерева не
  меняется (обратная совместимость);
- `AutoImages = False` — индексы не трогаются вовсе: картинки можно задавать
  самому в событиях LCL `OnGetImageIndex` / `OnGetSelectedIndex` (тоже
  переопубликованы; LCL вызывает их при отрисовке каждого узла, и обработчик
  может менять `Node.ImageIndex`/`Node.SelectedIndex`);
- если `Images`/`StateImages` назначаются **после** построения дерева, индексы
  узлов уже проставлены — достаточно вызвать `ApplyImages` (публичный метод),
  чтобы пересобрать картинки и маркеры под новый список.

### Как работает обратная связь

`THtmlViewer` не сообщает о прокрутке колесом, клавишами и программной
прокрутке — событие `OnScroll` есть только у полосы прокрутки. Поэтому
`TFb2Viewer`:

1. отдаёт позицию чтения (`ScrollPosition` — это `VScrollBarPosition`) и
   Y-позицию якоря (`AnchorPosition` — `NameList.Objects[IndexOf(anchor)].YPosition`):
   объект берётся из `NameList` (это `IDNameList` движка) и читается `YPosition`
   — ровно так же, как сам HtmlViewer делает в `PositionTo` при переходе к
   якорю. Важно: публичное `IDControl[]` тут **не подходит** — оно возвращает
   объект только для элементов форм (`TFormControlObj`) и картинок
   (`TImageObj`), а для текстовых якорей (наши `sec-N` у заголовков) всегда
   `nil`;
2. опрашивает позицию таймером (250 мс) и, если она изменилась, уведомляет
   подписчиков `AddScrollListener`; таймер работает **только** когда есть
   загруженный документ и хотя бы один подписчик.

`TFb2Outline` подписывается на это уведомление, кэширует `Y` всех якорей на
документ/раскладку (чтобы не искать их на каждом тике; кэш сбрасывается, когда
меняется высота документа — асинхронная подгрузка картинок или изменение
размера окна), и при изменении позиции выделяет нужный узел. Если документ тот
же (переход по якорю, смена размера шрифта), дерево не перестраивается — только
пересчитываются позиции.

Тонкость с программной подсветкой: LCL `TTreeView` шлёт `OnChange` **отложенно**
— `InternalSelectionChanged` включает таймер (интервал 1 мс), и только потом
`ChangeTimer` вызывает `Change(Node)` → `OnChange`. Поэтому недостаточно
заглушить `OnChange` флагом на время присваивания `Node.Selected` (к моменту
события флаг уже сброшен) — дерево запоминает узел, выделенный программно
(`FIgnoreChange`), и игнорирует ровно его `OnChange`. Без этого после перехода к
сноске (или обратно в текст) вид «прыгал» бы к началу текущей главы.

Навигация выполняется **без перезагрузки документа**: `TFb2Viewer.GoToAnchor`
берёт Y якоря (`AnchorPosition`) и присваивает его `VScrollBarPosition` — это
ровно то, что делает сам HtmlViewer в `PositionTo` (`ScrollTo(YPosition)`),
поэтому позиция совпадает с прежним поведением, но нет повторного разбора и
раскладки (на больших книгах это заметная экономия, а ещё исчезает «мигание»).
Если якоря в разобранном документе нет, остаётся прежний путь — перезагрузка
строки с `'#anchor'` (`LoadFromString(HTML, Path + '#' + Anchor)` → внутренний
`SplitDest`).

## Панель читалки (`TFb2ViewerToolbar`)

`pas/fb2viewertoolbar.pas` — компонент на `TToolBar`, который подключает к
`TFb2Viewer` то, что уже умеет движок, но раньше не было задействовано:
историю переходов, размер шрифта, поиск, буфер обмена и печать. Никаких
дополнительных портов библиотеки для него не нужно.

```pascal
V := TFb2Viewer.Create(Self);
V.Parent := MainPanel;   V.Align := alClient;
T := TFb2ViewerToolbar.Create(Self);
T.Parent := Self;        T.Align := alTop;
T.Viewer := V;                 { кнопки включатся сами после загрузки книги }
V.FileName := 'book.fb2';
```

Что внутри:

| Кнопка / метод | Через что | Примечание |
|---|---|---|
| `◀` `GoBack` / `▶` `GoForward` | `THtmlViewer.HistoryIndex` + `History.Count` | доступность обновляется по `OnHistoryChange` движка |
| `⌂` `GoToTop` | `Position := 0` | прокрутка к началу документа |
| `A−` / `A+` / `A` `ZoomOut/ZoomIn/ZoomReset` | `DefFontSize` + `Font.Size` | после смены размера вызывается `TFb2Viewer.ReRender` (перерисовка без повторного разбора FB2), позиция чтения сохраняется |
| `Найти` `ShowFindDialog` | `TFindDialog` → `FindEx` | встроенный диалог; `frMatchCase`/`frDown` учитываются |
| `Далее` `FindNext` | `FindEx(S, ..., False)` | при новом запросе поиск начинается с начала документа (`CaretPos := 0`) |
| `Копировать` `CopySelection` | `THtmlViewer.CopyToClipboard` | `SelectAllText` — выделить всё |
| `Печать` `PrintDocument` | `TPrintDialog` + `TvwPrinter` | диапазон страниц из диалога, `ppSinglePrint` |
| — `PrintPreview(Prn)` | `THtmlViewer.PrintPreview` + `TMetaFilePrinter` | рендерит страницы в переданный принтер и возвращает их число; **окно** предпросмотра — задача приложения (в HtmlViewer оно реализовано отдельной формой) |

Настройки: `Commands` (набор кнопок `[tcBack, tcForward, …]`), `FontSize`,
`MinFontSize`/`MaxFontSize`/`FontStep`, `SearchText`, `FindDialog`,
`PrintDialog`, событие `OnStateChange` (для статус-бара).

### Подписка на загрузку документа

`TFb2Viewer.OnDocumentLoad` — обычное свойство, и два компонента (дерево и
панель) перекрывали бы его друг другу. Поэтому добавлены
`AddDocumentLoadListener` / `RemoveDocumentLoadListener` — подписчиков может
быть сколько угодно; `TFb2Outline`, `TFb2ViewerToolbar` и `TFb2StatusBar`
используют именно их, так что дерево, панель и статус-бар спокойно работают
вместе.

## Статус-бар (`TFb2StatusBar`)

`pas/fb2statusbar.pas` — компонент на `TStatusBar`; подписывается на те же
события просмотрщика, что и дерево, поэтому значения обновляются и при
ручном чтении, и при переходе по ссылкам.

```pascal
S := TFb2StatusBar.Create(Self);
S.Parent := Self;   S.Align := alBottom;
S.Viewer := V;
```

| Панель | Содержимое | Свойство |
|---|---|---|
| 1 | «Название — Автор» (из `<description>`) | `ShowBook` |
| 2 | текущая глава | `ShowChapter` |
| 3 | «N из M» (номер главы / всего заголовков) | `ShowCounter` |
| 4 | полоса прогресса: при загрузке книги — 0..100 %, после — прогресс чтения | `ShowProgress` |

Четвёртая панель рисуется самим компонентом (`psOwnerDraw`): дорожка, заливка
и процент справа. Во время `TFb2Viewer.LoadFromFile` / `LoadFromStream` она
показывает прогресс загрузки (см. ниже), после `lsDone` — прогресс чтения.
Панель перерисовывается через `Invalidate` + `Update`, поэтому полоса видна
даже при синхронной загрузке в главном потоке. `Loading` (только чтение) —
признак того, что сейчас показывается загрузка.

Ширины панелей пересчитываются при изменении размера; `TrackMargin` — тот же
смысл, что у `TFb2Outline.TrackMargin`; `Refresh` — принудительное обновление.

### Прогресс загрузки

`TFb2Viewer` сообщает о начале и этапах загрузки. Подписчиков может быть
несколько (как и у `AddDocumentLoadListener`):

```pascal
procedure TForm1.ViewerProgress(Sender: TObject; Stage: TFb2LoadStage;
  Percent: Integer);
begin
  case Stage of
    lsDone:   Caption := 'Готово';
    lsFailed: Caption := 'Ошибка загрузки';
  else
    Caption := Format('Загрузка: %d %%', [Percent]);
  end;
end;

V.AddLoadProgressListener(@ViewerProgress);
```

Этапы: `lsStarting` (0 %), `lsReading`, `lsParsing`, `lsRendering`,
`lsImages`, `lsLayout` (перед раскладкой в `THtmlViewer`), `lsDone` (100 %) и
`lsFailed`. Проценты монотонны. Событие `OnLoadProgress` — то же самое для
одного обработчика.

Источник процентов — `TFb2ToHtmlConverter.OnProgress` (`0..100`, без GUI):
0 — старт, 40 — XML прочитан и разобран DOM, 50 — структуры FB2 готовы,
50..75 — отрисовка секций (шаг зависит от их числа), 80 — HTML собран,
80..100 — выгрузка `<binary>` в `SaveImages`. `TFb2Viewer` отображает этот
диапазон в первые 90 % загрузки, оставляя 10 % на запись HTML и раскладку.

`ProcessMessagesOnLoad` (по умолчанию `False`) позволяет вызывать
`Application.ProcessMessages` между этапами — окно остаётся отзывчивым, но
появляется риск реентерабельности (повторный `LoadFromFile` игнорируется,
пока идёт текущая загрузка). Статус-бару это не нужно: он перерисовывается
сам через `Update`.

## Карточка книги (`TFb2MetadataPanel`)

`pas/fb2metadatapanel.pas` — панель-редактор `<description>`: показывает
метаданные книги и записывает правки обратно в FB2 через `fb2_writer`
(порты модулей не нужны — `fb2_parser`/`fb2_writer`/`fb2_genres` уже есть).

```pascal
M := TFb2MetadataPanel.Create(Self);
M.Parent := LeftPanel;   M.Align := alClient;
M.FileName := 'book.fb2';       { загрузка и заполнение полей }
... правки в полях ...
M.SaveToFile;                   { запись (по умолчанию — в исходный файл) }
if M.Modified then ...;         { есть несохранённые правки }
```

Что редактируется:

- **название** (`<book-title>`), **дата** (`<date>`), **язык** (`<lang>`),
  **ключевые слова** (`<keywords>`);
- **авторы**: список + поля «Имя / Отчество / Фамилия / Псевдоним» и кнопки
  «Добавить / Заменить / Удалить»;
- **жанры**: список текущих + выпадающий список всех 110 жанров из
  `fb2_genres.pas` (можно и ввести код или название вручную);
- **аннотация**: многострочное поле, один абзац на строку (при записи каждой
  непустой строке соответствует `<p>` внутри `<annotation>`);
- **идентификатор и версия** из `document-info`;
- **обложка**: превью из `<binary>` + кнопка «Убрать обложку».

Кнопки панели: «Открыть…», «Сохранить», «Сохранить как…», «Отменить»
(перечитать файл). Свойства: `FileName`, `ShowButtons`, `OnModifiedChange`,
`Book`, `Modified`; методы: `LoadFromFile`, `SaveToFile`, `Revert`,
`ApplyToBook`, `Refresh`.

Два важных момента:

1. **Правки применяются к структуре сразу** — при каждом изменении поля
   (метод `Changed` → `ApplyToBook`), а `SaveToFile` только пишет файл.
   Поэтому изменения, сделанные приложением напрямую в `Book`, не затираются
   при сохранении.
2. **Текст и `<binary>` сохраняются как есть**, правится только описательная
   часть; но файл перезаписывается целиком средствами `fb2_writer`, поэтому
   форматирование исходного файла может измениться (отступы, порядок
   атрибутов) — это ожидаемо.

## Переименование книг (`TFb2RenameList`)

`pas/fb2renamelist.pas` — предпросмотр переименования «было → станет» поверх
`fb2_renamer`/`fb2_group_renamer` (порты не нужны — модули уже есть). На диске
ничего не меняется, пока не нажата кнопка «Переименовать».

```pascal
R := TFb2RenameList.Create(Self);
R.Parent := Self;   R.Align := alClient;
R.StartDir := 'C:\Books';
R.Template := '$Al - $Tt';      { шаблон имени, см. fb2_renamer }
R.OutDir := '$Al';              { необязательный подкаталог }
R.Recursive := True;
R.BuildPreview;                 { таблица «Было» → «Станет» + «Примечание» }
R.RenameAll;                    { выполнить; результат — в строке состояния }
```

Как это работает:

- предпросмотр обходит **тот же набор файлов**, что и
  `TFB2GroupRenamer.RenameAll` (`ListFiles`/`ListFilesRecursive`, маска
  `*.fb2`), и для каждого создаёт `TFB2Renamer` — то есть в таблице показано
  ровно то имя, которое получится на диске;
- файлы, которые прочитать нельзя (нет `<title-info>` и т. п.), попадают в
  таблицу с причиной в колонке «Примечание» и пропускаются при переименовании;
- «Переименовать» вызывает `TFB2Renamer.Rename` по каждому файлу; ошибка
  отдельного файла не прерывает обработку (как в групповом переименователе).

Свойства: `StartDir`, `Template`, `OutDir`, `Recursive`, `OnRenamed`. Методы:
`BuildPreview` (возвращает число готовых к переименованию), `RenameAll`
(возвращает число переименованных), `PreviewCount`, `PreviewErrors`,
`EntryAt` (запись `TFb2RenameEntry`: `OldPath`/`NewName`/`NewPath`/`Error`).

Доступные в шаблоне параметры — `$AL $AF $AM`, `$Al $Af $Am`, `$al $af $am`,
`$F $M`, `$T $t $Tt`, `$S $SN` (подробно — в `fb2_renamer.pas`).

## Дерево файлов FB2 (`TFb2FileTreeView`)

`pas/fb2filetreeview.pas` — наследник `TShellTreeView` (unit `ShellCtrls`,
входит в LCL), который показывает **только FB2-файлы** (и каталоги, чтобы по
ним перемещаться):

```pascal
T := TFb2FileTreeView.Create(Self);
T.Parent := LeftPanel;   T.Align := alClient;
T.Root := 'C:\Books';              { '' — вся файловая система }
T.FileMask := '*.fb2';             { по умолчанию уже '*.fb2' }
T.HideEmptyDirs := True;           { каталоги без FB2 не показывать }
T.Viewer := Viewer;                { книга откроется по двойному щелчку / Enter }
T.OnChange := @FileTreeChanged;
...
if T.SelectedFilePath <> '' then   { полный путь выбранного файла }
  StatusBar.Caption := T.SelectedFilePath;
...
T.SelectFile('C:\Books\Лем\Солярис.fb2');   { раскрыть и выделить книгу }
```

- `FileMask` — маска файлов; несколько шаблонов через `;`
  (`'*.fb2;*.fb2.zip'`), регистр не важен (`*.FB2` тоже подойдёт);
- `Viewer` — связанная читалка `TFb2Viewer`: при `AutoOpen = True` (по
  умолчанию) выбранная книга открывается **по двойному щелчку мышью или по
  Enter** (одиночное выделение книгу не открывает). События `OnDblClick` и
  `OnKeyDown` при этом работают как обычно: ваш `OnKeyDown` вызывается первым
  и может «съесть» клавишу (`Key := 0`) — тогда открытия не будет;
- `OpenSelectedFile` — открыть выделенный файл в `Viewer` вручную (например,
  по кнопке или пункту меню); `False` — читалка не задана, ничего не выделено
  или выделен каталог;
- `SelectedFilePath` — полный путь выбранного файла (`''`, если выбран
  каталог или ничего не выбрано);
- `HideEmptyDirs` (по умолчанию `False`) — не показывать каталоги, в которых
  нет ни одного подходящего файла ни прямо, ни в подкаталогах. Результаты
  сканирования кэшируются: после изменения содержимого каталогов на диске
  вызывайте `ClearDirCache` (смена `FileMask`/`HideEmptyDirs` сбрасывает кэш
  сама);
- `HideEmptyDirsScanLimit` (по умолчанию `100000`, `0` — без ограничения) —
  сколько элементов разрешено просмотреть при такой проверке. Когда бюджет
  исчерпан, каталоги считаются непустыми (дерево ведёт себя как при
  `HideEmptyDirs = False`) — так приложение не «зависает» на гигантских
  деревьях. По символическим ссылкам/junction'ам обход не идёт (на Windows их
  циклы вида `Application Data` раздувают его в разы) — такой каталог тоже
  считается непустым. **Если `Root` указывает на огромное дерево (например,
  `C:\` или диск целиком), `HideEmptyDirs` лучше выключить** либо задать
  `Root` по библиотеке: иначе первый же обход может надолго занять UI;
- `SelectFile(путь)` — раскрыть дерево до файла и выделить его (для каталога —
  просто перейти в него); `False` — пути нет или файл отсеян маской. Удобно,
  чтобы открыть текущую книгу при старте приложения;
- каталоги показываются всегда (иначе до файлов не добраться); скрытые
  элементы — по унаследованному `ObjectTypes`; `Root`, `Path`, `OnChange`,
  `Visible` (переопубликовано явно) и прочее наследуются от `TShellTreeView`;
- `OnAddItem` работает как обычно: пользовательский обработчик вызывается
  **после** фильтра по маске и может дополнительно запретить элемент
  (`CanAdd := False`).

Как это устроено: у `TShellTreeView` единственная точка фильтрации — событие
`OnAddItem` (`DoAddItem`/`PopulateTreeNodeWithFiles` не виртуальны), поэтому
компонент сам подписывается на него, хранит пользовательский обработчик
отдельно и вызывает его из своего фильтра. Заодно конструктор включает
`ObjectTypes := [otFolders, otNonFolders]` — по умолчанию `TShellTreeView`
показывает только каталоги. Для `HideEmptyDirs` каталог проверяется
рекурсивным обходом; вердикт «пусто / не пусто» запоминается, поэтому каждый
каталог сканируется один раз за проход, а объём обхода ограничен бюджетом
`HideEmptyDirsScanLimit`. При исчерпании бюджета (или на глубине больше 64,
или при встрече junction'а) каталог считается непустым — лучше показать
лишний каталог, чем подвесить приложение.

## Список файлов FB2 (`TFb2FileListView`)

`pas/fb2filelistview.pas` — парный компонент на `TShellListView`: показывает
файлы каталога, отсеивая всё, что не подходит под маску (по умолчанию — только
FB2):

```pascal
L := TFb2FileListView.Create(Self);
L.Parent := RightPanel;   L.Align := alClient;
L.Path := 'C:\Books';              { синоним унаследованного Root }
L.ShellTreeView := FileTree;       { необязательно: следовать за деревом }
L.MultiSelect := True;
L.OnSelectItem := @FileSelected;
...
if L.SelectedFilePath <> '' then   { первый выделенный файл }
  Viewer.FileName := L.SelectedFilePath;
```

- `Mask` (унаследовано) — маска файлов, по умолчанию `'*.fb2'`; несколько
  шаблонов через `;`;
- `Path` — каталог, содержимое которого показывается (синоним `Root` — для
  единообразия с `TFb2FileTreeView`);
- `SelectedFilePath` — полный путь выделенного файла; `SelectedFilePaths(список)`
  — все выделенные файлы (нужен `MultiSelect := True`);
- `ShellTreeView` — связь с деревом: список следует за выделением в дереве
  (при выборе файла показывается его каталог). Механизм штатный, из
  `TShellListView`.

Каталоги список не показывает (`ObjectTypes` по умолчанию `[otNonFolders]`).

## Подводные камни

| Тема | Что учесть |
|---|---|
| **Кодировка** | Движок Unicode/UTF-8, наш HTML — UTF-8 с `<meta charset="utf-8">`, так что при `LoadFromFile` вопросов нет. При `LoadFromString` строка должна быть в ожидаемом типе (`ThtString`) |
| **Кодировка строк LCL** | На русской Windows `DefaultSystemCodePage = 1251`, а строки LCL (`Caption`, `Text`, `Items`) — UTF-8. Неявная конверсия `UnicodeString → AnsiString` испортила бы кириллицу, поэтому в компонентах везде явные `UTF8Encode`/`UTF8ToString` (и `UTF8ToSys` для путей, которые уходят в RTL/конвертер) |
| **CSS** | Движок применяет лишь часть CSS: селекторы (тег/класс/id/потомки/группы), шрифты, интерлиньяж, отступы, рамки — работают; `max-width`, `text-indent`, `border-radius` — игнорируются (таблица — в разделе «CSS»). `TFb2Viewer` отдаёт движку `Css`/`CssFile` и при их смене пересобирает HTML из уже разобранного FB2 (`RenderHtml`) — без повторного чтения книги |
| **Картинки** | `InlineImages = True` (data-URI) движок **поддерживает** — `data:image/…;base64,` декодируется в `THtmlDocument.GetTheBase64` (HTMLSubs.pas), режим рабочий; минус — HTML раздувается base64. По умолчанию (False) картинки выгружаются на диск в `ImageDir`, пути относительные от каталога HTML-файла |
| **Неиспользуемые `<binary>`** | Бывает, что `<binary>` в файле есть, а ссылок на них в тексте нет (пример — `test.fb2`: 525 бинарников, `<image>` только для обложки). `TFb2Viewer` пишет на диск лишь фактически используемые картинки (`OnlyUsedImages := True`); сам конвертер по умолчанию выгружает все `<binary>` (как `save_binaries` в Python) |
| **Якоря / TOC / сноски** | Внутренние ссылки работают штатно; `OnHotSpotClick` нужен только для перехвата (например, внешних ссылок) |
| **Временные файлы** | Нужен жизненный цикл temp-каталога (в компоненте — `ClearTempDir`) |
| **Поток** | `Convert/Write` синхронны и CPU-bound; для толстых книг — в отдельном потоке, `LoadFromFile` — в главном |
| **Свойства на этапе дизайна** | `TFb2Viewer`/`TFb2Outline` унаследованы от «Custom»-базовых классов (`TCustomPanel`/`TCustomTreeView`), у которых `Align`/`Anchors`/`Visible` — только `public`. В компонентах они переопубликованы (`published`), поэтому видны в инспекторе объектов (у `TFb2Outline` — в т. ч. `Visible`, чтобы скрывать/показывать дерево, и `Images`/`StateImages`/`OnGetImageIndex`/`OnGetSelectedIndex` — поставщики картинок для узлов, см. «Картинки узлов»; у `TFb2FileTreeView` `Visible` и так наследуется `published` от `TShellTreeView`); остальные унаследованные свойства (например, `Caption`, `Color`, `PopupMenu`) остаются `public` и задаются только в коде |

## Итог

**Технически и архитектурно — да.** `fb2_html.pas` закрывает всю работу с FB2,
а `THtmlViewer` даёт готовый рендеринг, навигацию по якорям и печать. Главные
грабли — урезанный CSS (что именно поддерживается — в разделе «CSS» выше) и
(при загрузке «в память») тип строки; при подходе
через временный файл (`LoadFromFile`) оба обходятся.

> Замечание: `pas/fb2viewer.pas`, `pas/fb2outline.pas`,
> `pas/fb2viewertoolbar.pas`, `pas/fb2statusbar.pas`,
> `pas/fb2metadatapanel.pas`, `pas/fb2renamelist.pas`,
> `pas/fb2filetreeview.pas`, `pas/fb2filelistview.pas` и `pas/fb2viewer_reg.pas`
> собраны в **пакет `pas/pyfb2viewer.lpk`** (тип RunAndDesignTime; вкладка
> «FB2»; файл `pyfb2viewer.pas` — служебный, его генерирует Lazarus). Это
> GUI-модули: они не входят в состав библиотечных `.pas` и не собираются одним
> `fpc`/`make` — их подключают в Lazarus, установив пакет (который, в свою
> очередь, требует пакеты HtmlViewer `FrameViewer09` и `printer4lazarus`).
>
> Пакет проверен сборкой: `lazbuild pas/pyfb2viewer.lpk` компилирует все
> юниты без ошибок (`fb2_structures`, `fb2_parser`, `fb2_html`, `fb2viewer`,
> `fb2outline`, `fb2viewertoolbar`, `fb2statusbar`, `fb2metadatapanel`,
> `fb2renamelist`, `fb2filetreeview`, `fb2filelistview`, `fb2viewer_reg`).
