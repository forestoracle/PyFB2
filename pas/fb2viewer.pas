unit fb2viewer;
{ Визуальный компонент просмотра FB2 — обёртка над fb2_html + THtmlViewer.

  Схема:  book.fb2 -> TFb2ToHtmlConverter (fb2_html.pas) -> book.html (+ images)
          -> THtmlViewer.LoadFromFile(...)

  Требуется пакет HtmlViewer 11 (unit HtmlView, компонент THtmlViewer):
      https://github.com/BerndGabriel/HtmlViewer   (package/FrameViewer09.lpk)
  Пакет зависит от LCL, FCL и printer4lazarus (идёт с Lazarus).

  ВАЖНО: это GUI-модуль. Он НЕ входит в состав библиотечных .pas и не
  собирается одним fpc — его подключают в проект Lazarus с установленным
  пакетом FrameViewer09.

  Два режима загрузки:
    * LoadFromFile — HTML и картинки пишутся во временный каталог; HtmlViewer
      сам определяет кодировку по meta charset и разрешает относительные
      img src="images/..." относительно каталога HTML-файла;
    * LoadFromStream — временный каталог НЕ используется: HTML держится в
      памяти, а картинки отдаются из binary через OnImageRequest.

  Архивы .fb2.zip: LoadFromFile (и свойство FileName) распознаёт ZIP по
  расширению и открывает книгу БЕЗ временного каталога — распаковывается
  только запись с FB2 (в память), режим загрузки при этом потоковый.
  FileName при этом остаётся путём к архиву: по нему работают JSON-сессия
  чтения и слежение дерева файлов (TFb2FileTreeView). Запись внутри архива
  выбирается автоматически, а свойством ZipEntry её можно задать явно
  (нужно для многокнижных архивов).

  Другие форматы: LoadFromFile (и FileName) открывает также EPUB (.epub),
  Markdown (.md/.markdown) и DOCX (.docx). Книга конвертируется в FB2 в памяти
  (epub_to_fb2 / markdown_to_fb2 / docx_to_fb2) и показывается обычным
  потоковым путём — с оглавлением, сносками и картинками из <binary>;
  временный каталог не создаётся, FileName остаётся путём к исходному файлу.

  Навигация: GoToAnchor('sec-3') прокручивает к заголовку — прямая установка
  VScrollBarPosition по AnchorPosition (без перезагрузки документа); если якоря
  нет в разобранном документе, используется перезагрузка строки с '#anchor'.
  Дерево заголовков с навигацией — в fb2outline.pas (TFb2Outline), панель
  читалки — в fb2viewertoolbar.pas (TFb2ViewerToolbar).

  Оформление — CSS: THtmlViewer разбирает <style> документа и применяет
  свойства (шрифты, отступы, цвета, рамки; не всё — например, max-width и
  text-indent движок игнорирует). Компонент отдаёт движку CSS из свойства
  Css (по умолчанию — встроенный DEFAULT_CSS из fb2_html) либо из внешнего
  файла CssFile; смена CSS пересобирает HTML из уже разобранного FB2 и
  перерисовывает документ без повторного чтения книги. }

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Classes, SysUtils, Forms, Controls, ExtCtrls, LCLIntf, FileUtil, LazUTF8,
  fpjson,                                  { JSON-сессия чтения }
  fb2_structures, fb2_parser, fb2_html,   { наш порт — без GUI }
  fb2_archive,                             { чтение .fb2.zip (paszlib) }
  epub_to_fb2, markdown_to_fb2,            { EPUB/Markdown -> FB2 в памяти }
  docx_to_fb2,                             { DOCX -> FB2 в памяти }
  HtmlGlobals, HtmlView, HTMLUn2;          { HtmlViewer 11: движок + TIDObject }

type
  { Этапы загрузки книги — для индикатора прогресса в статус-баре и т. п. }
  TFb2LoadStage = (lsStarting, lsReading, lsParsing, lsRendering, lsImages,
    lsLayout, lsDone, lsFailed);
  { Уведомление о ходе загрузки: Stage — этап, Percent — 0..100. }
  TFb2LoadProgressEvent = procedure(Sender: TObject; Stage: TFb2LoadStage;
    Percent: Integer) of object;

  { Просмотр FB2: FB2 -> HTML (fb2_html) -> THtmlViewer. }
  TFb2Viewer = class(TCustomPanel)
  private
    FViewer: THtmlViewer;
    FFileName: TFileName;
    FImageDir: UnicodeString;
    FHeadingOffset: Integer;
    FMaxHeadingLevel: Integer;
    FIncludeToc: Boolean;
    FTocTitle: UnicodeString;
    FIncludeAnnotation: Boolean;
    FIncludeEpigraphs: Boolean;
    FIncludeCover: Boolean;
    FNoteLinks: Boolean;
    FInlineImages: Boolean;
    FCss: UnicodeString;             { свой CSS в <style> ('' — DEFAULT_CSS) }
    FCssFile: TFileName;             { внешний .css; если задан — вместо FCss }
    FTempDir: UnicodeString;
    FConverter: TFb2ToHtmlConverter;
    FDocumentSerial: Integer;      { номер документа: растёт при каждой загрузке }
    FHtml: UnicodeString;
    FHtmlPath: UnicodeString;
    FStreamSource: Boolean;        { HTML/картинки в памяти (поток или .fb2.zip) }
    FZipEntry: UnicodeString;      { запись внутри архива ('' — авто) }
    FLoadedZipEntry: UnicodeString; { запись, из которой загружена книга }
    FOnDocumentLoad: TNotifyEvent;
    FOnLoadProgress: TFb2LoadProgressEvent;
    FProcessMessagesOnLoad: Boolean;
    FLoading: Boolean;             { идёт загрузка — защита от реентерабельности }
    FLastProgressPercent: Integer;
    FLastPumpedPercent: Integer;
    FImgStream: TMemoryStream;
    FDocLoadListeners: TList;      { PNotifyEvent — подписчики OnDocumentLoad }
    FLoadProgressListeners: TList; { PFb2LoadProgressEvent — подписчики прогресса }
    FScrollListeners: TList;       { PNotifyEvent — подписчики изменения прокрутки }
    FTrackTimer: TTimer;           { опрос позиции прокрутки (см. UpdateTracking) }
    FLastScrollPos: Integer;
    FTocY: array of Integer;       { кэш Y-позиций якорей TocEntries }
    FTocSerial: Integer;           { для какого документа посчитан кэш }
    FTocRange: Integer;            { высота документа, при которой посчитан кэш }
    FNoteBackPos: TStringList;     { 'noteref-<id>' -> позиция возврата в тексте }
    FPendingScroll: Boolean;       { ждём готовности раскладки, чтобы восстановить позицию }
    FPendingScrollPos: Integer;
    FPendingScrollRange: Integer;
    FPendingScrollPercent: Integer;
    FPendingAnchor: UnicodeString;
    FPendingAnchorOffset: Integer;
    FPendingScrollTries: Integer;

    function NewTempDir: UnicodeString;
    procedure ClearTempDir;
    { Ядро потоковой загрузки. AFileName — путь-источник для свойства FileName:
      '' (публичный LoadFromStream) или путь к .fb2.zip (LoadFromZip); книга
      при этом читается из AStream, временный каталог не создаётся. }
    procedure LoadStream(AStream: TStream; const AFileName: TFileName);
    { Поток с байтами книги из архива .fb2.zip (распаковывается только запись
      с FB2; остальные книги многокнижного архива не читаются). }
    function LoadZipBook(const AZipFile: TFileName): TMemoryStream;
    { Показать FB2-XML, полученный конвертером (EPUB/Markdown): грузится
      потоковым путём, FileName — исходный файл (.epub/.md). }
    procedure LoadFb2Xml(const AFileName: TFileName; const AXml: UnicodeString);
    procedure SetFileName(const Value: TFileName);
    procedure SetCss(const Value: UnicodeString);
    procedure SetCssFile(const Value: TFileName);
    { CSS изменился: пересобрать HTML из уже разобранного FB2 и перерисовать
      документ, сохранив позицию чтения. Без загруженной книги — только
      запомнить значение. }
    procedure CssChanged;
    procedure ViewerHotSpotClick(Sender: TObject; const Src: ThtString;
      var Handled: Boolean);
    procedure ViewerImageRequest(Sender: TObject; const Src: ThtString;
      var Stream: TStream);
    procedure NotifyDocumentLoad;
    procedure NotifyScroll;
    procedure DoLoadProgress(Stage: TFb2LoadStage; Percent: Integer);
    procedure ConverterProgress(Sender: TObject; Percent: Integer);
    procedure RestoreScrollState(Position, SavedRange, Percent: Integer;
      const Anchor: UnicodeString; AnchorOffset: Integer);
    function TryApplyPendingScroll: Boolean;
    procedure UpdateTracking;
    procedure DoTrackTimer(Sender: TObject);
    procedure RefreshTocPositions;
    { Кэш позиций якорей ещё актуален (тот же документ и та же раскладка). }
    function TocPositionsValid: Boolean;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    { Построить HTML из FB2 и показать в просмотрщике. }
    procedure LoadFromFile(const AFileName: TFileName);
    { То же, но источник — поток: временный каталог не используется, картинки
      отдаются из памяти через OnImageRequest. }
    procedure LoadFromStream(AStream: TStream);
    { Открыть «однокнижный» архив (.fb2.zip): запись с FB2 распаковывается в
      память и грузится как поток (временный каталог не нужен), FileName
      остаётся путём к архиву. Какая запись выбрана — ZipEntryName. }
    procedure LoadFromZip(const AZipFile: TFileName);
    { Открыть EPUB: книга конвертируется в FB2 в памяти (epub_to_fb2) и
      показывается потоковым путём; FileName остаётся путём к .epub. }
    procedure LoadFromEpub(const AFileName: TFileName);
    { Открыть Markdown (.md/.markdown): конвертируется в FB2 в памяти
      (markdown_to_fb2) и показывается потоковым путём. }
    procedure LoadFromMarkdown(const AFileName: TFileName);
    { Открыть DOCX: конвертируется в FB2 в памяти (docx_to_fb2) и показывается
      потоковым путём; FileName остаётся путём к .docx. }
    procedure LoadFromDocx(const AFileName: TFileName);
    procedure Reload;
    { Перерисовать текущий документ без повторного разбора FB2: нужно после
      смены настроек рендеринга (например, размера шрифта). Сохраняет режим
      загрузки (файловый/потоковый) и повторяет OnDocumentLoad. }
    procedure ReRender;

    { Итоговый CSS документа: содержимое CssFile (если файл задан и читается),
      иначе Css, иначе DEFAULT_CSS (из fb2_html). }
    function EffectiveCss: UnicodeString;
    { Задать CSS-текст и сразу перерисовать документ (CssFile при этом
      отключается — используется именно текст). }
    procedure LoadCssFromString(const ACss: UnicodeString);
    { Подключить внешний .css-файл (UTF-8/UTF-16 с BOM или без) и перерисовать
      документ. Если файла нет — исключение. }
    procedure LoadCssFromFile(const AFileName: TFileName);
    { Вернуться к встроенному DEFAULT_CSS. }
    procedure ResetCss;

    { Подписка на загрузку документа. В отличие от свойства OnDocumentLoad,
      подписчиков может быть несколько (панель читалки, дерево заголовков и
      т. п.) — они не перекрывают друг друга. }
    procedure AddDocumentLoadListener(const Handler: TNotifyEvent);
    procedure RemoveDocumentLoadListener(const Handler: TNotifyEvent);

    { Подписка на прогресс загрузки (начало, этапы, 0..100). Подписчиков может
      быть несколько; статус-бар использует это для полосы загрузки. }
    procedure AddLoadProgressListener(const Handler: TFb2LoadProgressEvent);
    procedure RemoveLoadProgressListener(const Handler: TFb2LoadProgressEvent);

    { Состояние чтения в JSON (UTF-8): имя файла, позиция прокрутки, диапазон,
      процент, якорь текущей главы и смещение от него. }
    function SessionToJson: UnicodeString;
    { Применить состояние из JSON: если файл отличается — загрузить его, затем
      восстановить позицию. Ошибки разбора JSON и загрузки книги — исключением. }
    procedure ApplySession(const AJson: UnicodeString);
    { Сохранить/прочитать состояние чтения в JSON-файле (UTF-8 без BOM). }
    procedure SaveSessionToFile(const AFileName: TFileName);
    procedure LoadSessionFromFile(const AFileName: TFileName);

    { Текущее смещение вертикальной прокрутки (в пикселях документа). }
    function ScrollPosition: Integer;
    { Y-позиция элемента с указанным якорем в документе; -1 — якоря нет.
      Величина сравнима со ScrollPosition (движок сам прыгает к якорю через
      ScrollTo(YPosition)). }
    function AnchorPosition(const Anchor: UnicodeString): Integer;
    { Подписка на изменение прокрутки — обратный канал для синхронизации
      внешних компонентов (например, дерева заголовков TFb2Outline при ручной
      прокрутке или переходе по внутренней ссылке). }
    procedure AddScrollListener(const Handler: TNotifyEvent);
    procedure RemoveScrollListener(const Handler: TNotifyEvent);

    { Y-позиция записи TocEntries по индексу (-1 — нет). }
    function TocEntryPosition(Index: Integer): Integer;
    { Индекс записи TocEntries, соответствующей текущей позиции чтения:
      глава, в начале которой находится читатель (с отступом Margin от верхней
      границы области чтения). -1 — нет документа или заголовков. }
    function TocIndexOfCurrent(Margin: Integer = 16): Integer;

    { Перейти к якорю в текущем документе (например, 'sec-3' или 'n_1'). }
    procedure GoToAnchor(const Anchor: UnicodeString);

    { Обработать клик по внутренней ссылке ('#n43', 'book.html#n43').
      Возвращает True, если переход выполнили сами (обратная ссылка из сноски —
      возврат на запомненную позицию), иначе False — переход выполняет движок.

      Нужно потому, что HtmlViewer неверно определяет Y у ИНЛАЙНОВЫХ якорей
      (id на <a>/<span> внутри абзаца): он отдаёт конец документа, из-за чего
      возврат «из сноски в текст» уезжал в конец книги. }
    function HandleInternalLink(const Src: UnicodeString): Boolean;

    { Доступ к вложенному просмотрщику (шрифты, печать, поиск и т. п.). }
    property Viewer: THtmlViewer read FViewer;
    { Конвертер последнего документа (Bodies, TocEntries, Binaries, NoteTargets). }
    property Converter: TFb2ToHtmlConverter read FConverter;
    { Запись .fb2.zip, из которой загружена текущая книга ('' — книга не из
      архива). }
    property ZipEntryName: UnicodeString read FLoadedZipEntry;
    { Номер текущего документа: увеличивается при каждой загрузке (в том числе
      при Reload). Подписчики (TFb2Outline и т. п.) по нему отличают новый
      документ от повторного события о том же. Сравнивать указатель Converter
      нельзя: конвертер пересоздаётся на каждую загрузку, и аллокатор может
      вернуть тот же адрес — тогда новый документ выглядел бы как прежний. }
    property DocumentSerial: Integer read FDocumentSerial;
  published
    { Размещение на форме: у «Custom»-предков (TCustomPanel) свойства Align и
      Anchors объявлены public, поэтому переопубликовываем их, чтобы они были
      видны в инспекторе объектов и сохранялись в .lfm. }
    property Align;
    property Anchors;
    property FileName: TFileName read FFileName write SetFileName;
    { Запись внутри архива .fb2.zip: полное имя или только базовое. Пусто
      (по умолчанию) — выбрать автоматически: запись, совпадающую с именем
      архива без '.zip', иначе первую '.fb2', иначе единственную запись.
      Нужно для многокнижных архивов; на обычные файлы .fb2 не влияет. }
    property ZipEntry: UnicodeString read FZipEntry write FZipEntry;
    property ImageDir: UnicodeString read FImageDir write FImageDir;
    property HeadingOffset: Integer read FHeadingOffset write FHeadingOffset default 1;
    property MaxHeadingLevel: Integer read FMaxHeadingLevel write FMaxHeadingLevel default 6;
    property IncludeToc: Boolean read FIncludeToc write FIncludeToc default True;
    property TocTitle: UnicodeString read FTocTitle write FTocTitle;
    property IncludeAnnotation: Boolean read FIncludeAnnotation write FIncludeAnnotation default True;
    property IncludeEpigraphs: Boolean read FIncludeEpigraphs write FIncludeEpigraphs default True;
    property IncludeCover: Boolean read FIncludeCover write FIncludeCover default True;
    property NoteLinks: Boolean read FNoteLinks write FNoteLinks default True;
    property InlineImages: Boolean read FInlineImages write FInlineImages default False;
    { Свой CSS документа (содержимое <style> в <head>). Пусто (по умолчанию) —
      используется встроенный DEFAULT_CSS. При изменении документ
      перерисовывается без повторного чтения FB2. }
    property Css: UnicodeString read FCss write SetCss;
    { Внешний .css-файл (например, пользовательская тема оформления). Если
      задан и файл читается — используется ВМЕСТО Css. При изменении документ
      перерисовывается. }
    property CssFile: TFileName read FCssFile write SetCssFile;
    { Событие после успешной загрузки документа (для связанных компонентов). }
    property OnDocumentLoad: TNotifyEvent read FOnDocumentLoad write FOnDocumentLoad;
    { Ход загрузки книги: этап и процент 0..100. Событие вызывается в
      вызывающем потоке; lsDone — успешно, lsFailed — ошибка. }
    property OnLoadProgress: TFb2LoadProgressEvent read FOnLoadProgress
      write FOnLoadProgress;
    { Обрабатывать сообщения между этапами загрузки (Application.ProcessMessages).
      По умолчанию False: статус-бар перерисовывает индикатор сам через Update,
      поэтому окно не обязано становиться реентерабельным. Включайте, если
      нужна полная отзывчивость UI во время загрузки. }
    property ProcessMessagesOnLoad: Boolean read FProcessMessagesOnLoad
      write FProcessMessagesOnLoad default False;
  end;

{ ===================== Поддерживаемые форматы ===================== }

{ Расширение файла в нижнем регистре ('' — расширения нет). }
function FileExtOf(const FileName: TFileName): string;

{ Файл — EPUB (по расширению): конвертируется в FB2 в памяти. }
function IsEpubFile(const FileName: TFileName): Boolean;

{ Файл — Markdown (по расширению .md/.markdown). }
function IsMarkdownFile(const FileName: TFileName): Boolean;

{ Файл — DOCX (по расширению): конвертируется в FB2 в памяти. }
function IsDocxFile(const FileName: TFileName): Boolean;

{ Файл открывается читалкой: .fb2, ZIP-архив (.fb2.zip/.zip), .epub,
  .md/.markdown или .docx. Удобно для фильтров в диалогах открытия. }
function IsViewableBookFile(const FileName: TFileName): Boolean;

implementation

{ ===================== Поддерживаемые форматы ===================== }

function FileExtOf(const FileName: TFileName): string;
begin
  { TFileName — строка LCL (UTF-8), но расширение всегда ASCII, поэтому
    ExtractFileExt по байтам безопасен и для кириллических путей. }
  Result := LowerCase(ExtractFileExt(FileName));
end;

function IsEpubFile(const FileName: TFileName): Boolean;
begin
  Result := FileExtOf(FileName) = '.epub';
end;

function IsMarkdownFile(const FileName: TFileName): Boolean;
var
  Ext: string;
begin
  Ext := FileExtOf(FileName);
  Result := (Ext = '.md') or (Ext = '.markdown');
end;

function IsDocxFile(const FileName: TFileName): Boolean;
begin
  Result := FileExtOf(FileName) = '.docx';
end;

function IsViewableBookFile(const FileName: TFileName): Boolean;
var
  Ext: string;
begin
  Ext := FileExtOf(FileName);
  Result := (Ext = '.fb2') or (Ext = '.zip') or (Ext = '.epub') or
    (Ext = '.md') or (Ext = '.markdown') or (Ext = '.docx');
end;

type
  { Указатель на подписчика (для списков FDocLoadListeners/FScrollListeners). }
  PNotifyEvent = ^TNotifyEvent;
  { Указатель на подписчика прогресса загрузки. }
  PFb2LoadProgressEvent = ^TFb2LoadProgressEvent;

{ ===================== Списки подписчиков ===================== }

procedure ListAddListener(List: TList; const Handler: TNotifyEvent);
var
  P: PNotifyEvent;
begin
  if not Assigned(Handler) or (List = nil) then
    Exit;
  New(P);
  P^ := Handler;
  List.Add(P);
end;

procedure ListRemoveListener(List: TList; const Handler: TNotifyEvent);
var
  I: Integer;
  P: PNotifyEvent;
  H: TMethod;
begin
  if not Assigned(Handler) or (List = nil) then
    Exit;
  H := TMethod(Handler);
  for I := List.Count - 1 downto 0 do
  begin
    P := PNotifyEvent(List[I]);
    if (TMethod(P^).Code = H.Code) and (TMethod(P^).Data = H.Data) then
    begin
      Dispose(P);
      List.Delete(I);
    end;
  end;
end;

procedure ListFire(List: TList; Sender: TObject);
var
  I: Integer;
begin
  if List = nil then
    Exit;
  for I := 0 to List.Count - 1 do
    PNotifyEvent(List[I])^(Sender);
end;

procedure ListFree(List: TList);
var
  I: Integer;
begin
  if List = nil then
    Exit;
  for I := 0 to List.Count - 1 do
    Dispose(PNotifyEvent(List[I]));
  List.Clear;
end;

procedure LoadProgressListAddListener(List: TList;
  const Handler: TFb2LoadProgressEvent);
var
  P: PFb2LoadProgressEvent;
begin
  if not Assigned(Handler) or (List = nil) then
    Exit;
  New(P);
  P^ := Handler;
  List.Add(P);
end;

procedure LoadProgressListRemoveListener(List: TList;
  const Handler: TFb2LoadProgressEvent);
var
  I: Integer;
  P: PFb2LoadProgressEvent;
  H: TMethod;
begin
  if not Assigned(Handler) or (List = nil) then
    Exit;
  H := TMethod(Handler);
  for I := List.Count - 1 downto 0 do
  begin
    P := PFb2LoadProgressEvent(List[I]);
    if (TMethod(P^).Code = H.Code) and (TMethod(P^).Data = H.Data) then
    begin
      Dispose(P);
      List.Delete(I);
    end;
  end;
end;

procedure LoadProgressListFire(List: TList; Sender: TObject;
  Stage: TFb2LoadStage; Percent: Integer);
var
  I: Integer;
begin
  if List = nil then
    Exit;
  for I := 0 to List.Count - 1 do
    PFb2LoadProgressEvent(List[I])^(Sender, Stage, Percent);
end;

procedure LoadProgressListFree(List: TList);
var
  I: Integer;
begin
  if List = nil then
    Exit;
  for I := 0 to List.Count - 1 do
    Dispose(PFb2LoadProgressEvent(List[I]));
  List.Clear;
end;

{ Запись текста в файл в UTF-8 без BOM (в fb2_html она в implementation). }
procedure WriteUtf8File(const FileName: UnicodeString; const Text: UnicodeString);
var
  FS: TFileStream;
  Bytes: TBytes;
begin
  Bytes := TEncoding.UTF8.GetBytes(Text);
  if (Length(Bytes) >= 3) and (Bytes[0] = $EF) and (Bytes[1] = $BB) and
    (Bytes[2] = $BF) then
    Delete(Bytes, 0, 3);
  FS := TFileStream.Create(FileName, fmCreate);
  try
    if Length(Bytes) > 0 then
      FS.WriteBuffer(Bytes[0], Length(Bytes));
  finally
    FS.Free;
  end;
end;

{ Прочитать текстовый файл: BOM UTF-8/UTF-16 учитывается, без BOM текст
  считается UTF-8 (стандарт библиотеки). False — файл недоступен. }
function ReadTextFile(const FileName: TFileName; out Text: UnicodeString): Boolean;
var
  FS: TFileStream;
  Bytes: TBytes;
  N: Int64;
begin
  Result := False;
  Text := '';
  try
    FS := TFileStream.Create(UTF8ToSys(FileName), fmOpenRead or fmShareDenyWrite);
  except
    Exit;
  end;
  try
    N := FS.Size;
    if N < 0 then
      N := 0;
    SetLength(Bytes, N);
    if N > 0 then
      FS.ReadBuffer(Bytes[0], N);
  finally
    FS.Free;
  end;
  if (Length(Bytes) >= 2) and (Bytes[0] = $FF) and (Bytes[1] = $FE) then
    Text := TEncoding.Unicode.GetString(Bytes, 2, Length(Bytes) - 2)
  else if (Length(Bytes) >= 2) and (Bytes[0] = $FE) and (Bytes[1] = $FF) then
    Text := TEncoding.BigEndianUnicode.GetString(Bytes, 2, Length(Bytes) - 2)
  else
  begin
    if (Length(Bytes) >= 3) and (Bytes[0] = $EF) and (Bytes[1] = $BB) and
      (Bytes[2] = $BF) then
      Text := TEncoding.UTF8.GetString(Bytes, 3, Length(Bytes) - 3)
    else
      Text := TEncoding.UTF8.GetString(Bytes);
  end;
  Result := True;
end;

{ Прочитать текстовый файл (CSS). Оставлено отдельным именем для читаемости
  вызовов; реализация общая с JSON-сессией. }
function ReadCssText(const FileName: TFileName; out Css: UnicodeString): Boolean;
begin
  Result := ReadTextFile(FileName, Css);
end;

const
  { Версия формата JSON-сессии. }
  SESSION_JSON_VERSION = 1;

{ Строковое поле JSON; '' — поля нет или это не строка. }
function JsonStr(Obj: TJSONObject; const Name: String): UnicodeString;
var
  D: TJSONData;
begin
  Result := '';
  if Obj = nil then
    Exit;
  D := Obj.Find(Name);
  if (D <> nil) and (D.JSONType = jtString) then
    Result := D.AsUnicodeString;
end;

{ Числовое поле JSON; Default — поля нет или оно не число. }
function JsonInt(Obj: TJSONObject; const Name: String; Default: Int64): Int64;
var
  D: TJSONData;
begin
  Result := Default;
  if Obj = nil then
    Exit;
  D := Obj.Find(Name);
  if D = nil then
    Exit;
  case D.JSONType of
    jtNumber: Result := D.AsInt64;
    jtString: Result := StrToInt64Def(D.AsString, Default);
  end;
end;

function ClampToInt(Value: Int64): Integer;
begin
  if Value < 0 then
    Result := 0
  else if Value > MaxInt then
    Result := MaxInt
  else
    Result := Value;
end;

constructor TFb2Viewer.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FHeadingOffset := 1;
  FMaxHeadingLevel := 6;
  FIncludeToc := True;
  FTocTitle := 'Оглавление';
  FIncludeAnnotation := True;
  FIncludeEpigraphs := True;
  FIncludeCover := True;
  FNoteLinks := True;
  FImageDir := 'images';
  FStreamSource := False;       { по умолчанию — файловый режим (temp-каталог) }
  FZipEntry := '';
  FLoadedZipEntry := '';

  FViewer := THtmlViewer.Create(Self);
  FViewer.Parent := Self;
  FViewer.Align := alClient;
  FViewer.DefFontName := 'Georgia';
  FViewer.DefPreFontName := 'Courier New';
  FViewer.OnHotSpotClick := @ViewerHotSpotClick;
  FImgStream := TMemoryStream.Create;
  FDocLoadListeners := TList.Create;
  FLoadProgressListeners := TList.Create;
  FScrollListeners := TList.Create;
  FProcessMessagesOnLoad := False;
  FLastProgressPercent := -1;
  FLastPumpedPercent := -1;
  FPendingScroll := False;
  FPendingAnchor := '';
  FLastScrollPos := -1;
  FNoteBackPos := TStringList.Create;

  { HtmlViewer не сообщает о прокрутке колесом/клавишами/программно — следим
    за позицией опросом, и только пока есть документ и подписчики. }
  FTrackTimer := TTimer.Create(Self);
  FTrackTimer.Interval := 250;
  FTrackTimer.OnTimer := @DoTrackTimer;
  FTrackTimer.Enabled := False;
end;

destructor TFb2Viewer.Destroy;
begin
  if FTrackTimer <> nil then
    FTrackTimer.Enabled := False;
  ListFree(FDocLoadListeners);
  LoadProgressListFree(FLoadProgressListeners);
  ListFree(FScrollListeners);
  FreeAndNil(FDocLoadListeners);
  FreeAndNil(FLoadProgressListeners);
  FreeAndNil(FScrollListeners);
  FreeAndNil(FConverter);
  FreeAndNil(FImgStream);
  FreeAndNil(FNoteBackPos);
  ClearTempDir;
  inherited Destroy;
end;

{ Оповестить OnDocumentLoad и всех подписчиков о новой загрузке. }
procedure TFb2Viewer.NotifyDocumentLoad;
begin
  { Документ отрисован: обновляем кэш позиций заголовков, чтобы подписчики
    (дерево, статус-бар) сразу видели актуальные величины. }
  RefreshTocPositions;
  if Assigned(FOnDocumentLoad) then
    FOnDocumentLoad(Self);
  ListFire(FDocLoadListeners, Self);
  { Позиции якорей считаны новым документом — слежение можно включать. }
  FLastScrollPos := -1;
  UpdateTracking;
  NotifyScroll;
end;

procedure TFb2Viewer.AddDocumentLoadListener(const Handler: TNotifyEvent);
begin
  ListAddListener(FDocLoadListeners, Handler);
end;

procedure TFb2Viewer.RemoveDocumentLoadListener(const Handler: TNotifyEvent);
begin
  ListRemoveListener(FDocLoadListeners, Handler);
end;

procedure TFb2Viewer.AddLoadProgressListener(
  const Handler: TFb2LoadProgressEvent);
begin
  LoadProgressListAddListener(FLoadProgressListeners, Handler);
end;

procedure TFb2Viewer.RemoveLoadProgressListener(
  const Handler: TFb2LoadProgressEvent);
begin
  LoadProgressListRemoveListener(FLoadProgressListeners, Handler);
end;

{ ===================== Прогресс загрузки ===================== }

{ Разослать прогресс подписчикам. При включённом ProcessMessagesOnLoad между
  этапами прокачиваются сообщения (по умолчанию выключено — статус-бар
  перерисовывается сам через Update). }
procedure TFb2Viewer.DoLoadProgress(Stage: TFb2LoadStage; Percent: Integer);
var
  HasSink: Boolean;
begin
  if Percent < 0 then
    Percent := 0;
  if Percent > 100 then
    Percent := 100;
  { Проценты внутри загрузки монотонны; lsDone/lsFailed важнее значения. }
  if (Stage <> lsDone) and (Stage <> lsFailed) and
     (Percent <= FLastProgressPercent) then
    Exit;
  FLastProgressPercent := Percent;

  HasSink := Assigned(FOnLoadProgress) or
    ((FLoadProgressListeners <> nil) and (FLoadProgressListeners.Count > 0));
  if Assigned(FOnLoadProgress) then
    FOnLoadProgress(Self, Stage, Percent);
  LoadProgressListFire(FLoadProgressListeners, Self, Stage, Percent);

  { Прокачиваем сообщения не на каждом проценте (иначе на большой книге
    отрисовка секций замедлится), а с шагом ~2% и обязательно на границах. }
  if FProcessMessagesOnLoad and HasSink and
     ((Stage = lsStarting) or (Stage = lsDone) or (Stage = lsFailed) or
      (Percent = 100) or (Percent >= FLastPumpedPercent + 2)) then
  begin
    FLastPumpedPercent := Percent;
    Application.ProcessMessages;
  end;
end;

{ Прогресс конвертера (0..100) занимает первые 90% загрузки: оставшиеся 10%
  приходятся на запись HTML и раскладку в THtmlViewer. }
procedure TFb2Viewer.ConverterProgress(Sender: TObject; Percent: Integer);
var
  Stage: TFb2LoadStage;
begin
  if not FLoading then
    Exit;
  if Percent < 45 then
    Stage := lsParsing
  else if Percent < 80 then
    Stage := lsRendering
  else
    Stage := lsImages;
  DoLoadProgress(Stage, Percent * 90 div 100);
end;

{ ===================== Прокрутка ===================== }

function TFb2Viewer.ScrollPosition: Integer;
begin
  if FViewer = nil then
    Result := 0
  else
    Result := FViewer.VScrollBarPosition;
end;

{ ===================== Сессия чтения (JSON) ===================== }

function TFb2Viewer.SessionToJson: UnicodeString;
var
  Obj: TJSONObject;
  Pos, Range, Idx, AnchorY, Offset, Percent: Integer;
  Anchor: UnicodeString;
begin
  Pos := ScrollPosition;
  Range := 0;
  if FViewer <> nil then
    Range := FViewer.VScrollBarRange;
  if Pos < 0 then
    Pos := 0;
  if Range < 0 then
    Range := 0;
  if (Range > 0) and (Pos > Range) then
    Pos := Range;
  if (Range > 0) and (Pos >= 0) then
    { Int64 обязателен: у очень длинных книг (большой шрифт + тысячи глав)
      высота документа превышает 21 млн px, и Pos * 100 в 32 битах
      переполняется — при -Cr/-Co это ERangeError, без проверок — тихо
      неверный процент. }
    Percent := Integer(Int64(Pos) * 100 div Range)
  else
    Percent := 0;

  { Якорь текущей главы + смещение: позиция восстанавливается точнее, если
    раскладка изменилась (другой размер окна, шрифт, догрузка картинок). }
  Anchor := '';
  Offset := 0;
  if (FConverter <> nil) and (FConverter.TocEntries <> nil) then
  begin
    Idx := TocIndexOfCurrent(16);
    if (Idx >= 0) and (Idx < FConverter.TocEntries.Count) then
    begin
      Anchor := FConverter.TocEntries[Idx].Anchor;
      AnchorY := TocEntryPosition(Idx);
      if AnchorY >= 0 then
      begin
        Offset := Pos - AnchorY;
        if Offset < 0 then
          Offset := 0;
      end
      else
        Anchor := '';
    end;
  end;

  Obj := TJSONObject.Create;
  try
    Obj.Add('version', SESSION_JSON_VERSION);
    Obj.Add('file', TJSONStringType(FFileName));
    Obj.Add('position', Int64(Pos));
    Obj.Add('scroll_range', Int64(Range));
    Obj.Add('percent', Percent);
    Obj.Add('anchor', UTF8Encode(Anchor));
    Obj.Add('anchor_offset', Int64(Offset));
    Result := UTF8Decode(Obj.FormatJSON(DefaultFormat, 2));
  finally
    Obj.Free;
  end;
end;

procedure TFb2Viewer.ApplySession(const AJson: UnicodeString);
var
  Data: TJSONData;
  Obj: TJSONObject;
  SessionFileName: TFileName;
  Anchor: UnicodeString;
  Position, Range, Percent, Offset: Integer;
begin
  if FLoading then
    Exit;
  Data := GetJSON(UTF8Encode(AJson), True);
  try
    if (Data = nil) or (Data.JSONType <> jtObject) then
      raise Exception.Create('Некорректный JSON сессии: ожидается объект');
    Obj := TJSONObject(Data);

    SessionFileName := TFileName(UTF8Encode(JsonStr(Obj, 'file')));
    if (SessionFileName <> '') and
       ((FFileName <> SessionFileName) or (FHtml = '')) then
      LoadFromFile(SessionFileName);

    Position := ClampToInt(JsonInt(Obj, 'position', 0));
    Range := ClampToInt(JsonInt(Obj, 'scroll_range', 0));
    Percent := ClampToInt(JsonInt(Obj, 'percent', 0));
    Offset := ClampToInt(JsonInt(Obj, 'anchor_offset', 0));
    Anchor := JsonStr(Obj, 'anchor');
    RestoreScrollState(Position, Range, Percent, Anchor, Offset);
  finally
    Data.Free;
  end;
end;

procedure TFb2Viewer.SaveSessionToFile(const AFileName: TFileName);
var
  Path, Dir: UnicodeString;
begin
  Path := UTF8ToString(AFileName);
  Dir := ExtractFileDir(Path);
  if Dir <> '' then
    ForceDirectories(Dir);
  WriteUtf8File(Path, SessionToJson);
end;

procedure TFb2Viewer.LoadSessionFromFile(const AFileName: TFileName);
var
  JsonText: UnicodeString;
begin
  if not ReadTextFile(AFileName, JsonText) then
    raise Exception.CreateFmt('Файл сессии не найден: %s', [AFileName]);
  ApplySession(JsonText);
end;

{ Запомнить параметры восстановления и применить их сразу, если раскладка уже
  готова; иначе таймер опроса будет повторять попытки. }
procedure TFb2Viewer.RestoreScrollState(Position, SavedRange, Percent: Integer;
  const Anchor: UnicodeString; AnchorOffset: Integer);
begin
  if FHtml = '' then
    Exit;
  if Position < 0 then
    Position := 0;
  if SavedRange < 0 then
    SavedRange := 0;
  if Percent < 0 then
    Percent := 0;
  if Percent > 100 then
    Percent := 100;
  if AnchorOffset < 0 then
    AnchorOffset := 0;

  FPendingScrollPos := Position;
  FPendingScrollRange := SavedRange;
  FPendingScrollPercent := Percent;
  FPendingAnchor := Anchor;
  FPendingAnchorOffset := AnchorOffset;
  FPendingScrollTries := 40;   { ~10 секунд при интервале таймера 250 мс }
  FPendingScroll := True;
  TryApplyPendingScroll;
  UpdateTracking;
end;

{ True — попытка обработана (позиция применена или ожидаем раскладку);
  False — восстанавливать нечего. }
function TFb2Viewer.TryApplyPendingScroll: Boolean;
var
  CurRange, Target, Y: Integer;
begin
  Result := False;
  if not FPendingScroll then
    Exit;
  Result := True;
  if (FViewer = nil) or (FHtml = '') then
    Exit;

  CurRange := FViewer.VScrollBarRange;
  if CurRange <= 0 then
  begin
    Dec(FPendingScrollTries);
    if FPendingScrollTries <= 0 then
    begin
      FPendingScroll := False;
      UpdateTracking;
    end;
    Exit;
  end;

  Target := -1;
  if FPendingAnchor <> '' then
  begin
    Y := AnchorPosition(FPendingAnchor);
    if Y >= 0 then
      Target := Y + FPendingAnchorOffset;
  end;
  if Target < 0 then
  begin
    if (FPendingScrollRange > 0) and
       (Abs(Int64(CurRange) - FPendingScrollRange) <= FPendingScrollRange div 5) then
      Target := FPendingScrollPos
    else if FPendingScrollPercent > 0 then
      Target := Integer(Int64(CurRange) * FPendingScrollPercent div 100)
    else
      Target := FPendingScrollPos;
  end;
  if Target < 0 then
    Target := 0;
  if Target > CurRange then
    Target := CurRange;

  if FViewer.VScrollBarPosition <> Target then
  begin
    FViewer.VScrollBarPosition := Target;
    FLastScrollPos := FViewer.VScrollBarPosition;
    NotifyScroll;
  end
  else
    FLastScrollPos := Target;

  FPendingScroll := False;
  UpdateTracking;
end;

function TFb2Viewer.AnchorPosition(const Anchor: UnicodeString): Integer;
var
  Obj: TObject;
  I: Integer;
begin
  Result := -1;
  if (FViewer = nil) or (Anchor = '') then
    Exit;
  { ВНИМАНИЕ: IDControl[] (GetIDControl) отдаёт объект только если это
    TFormControlObj или TImageObj — для текстовых якорей (наши 'sec-N' у
    заголовков) он всегда nil. Поэтому берём объект из NameList (это IDNameList
    движка) и читаем YPosition — ровно так же, как сам HtmlViewer делает в
    PositionTo. YPosition в той же системе координат, что VScrollBarPosition
    (движок прыгает к якорю через ScrollTo(YPosition)). }
  I := FViewer.NameList.IndexOf(UpperCase(Anchor));
  if I < 0 then
    Exit;
  Obj := FViewer.NameList.Objects[I];
  if Obj is TIDObject then
    Result := TIDObject(Obj).YPosition;
end;

procedure TFb2Viewer.AddScrollListener(const Handler: TNotifyEvent);
begin
  ListAddListener(FScrollListeners, Handler);
  UpdateTracking;
  NotifyScroll;
end;

procedure TFb2Viewer.RemoveScrollListener(const Handler: TNotifyEvent);
begin
  ListRemoveListener(FScrollListeners, Handler);
  UpdateTracking;
end;

{ Включить опрос позиции, если есть документ и (есть подписчики или ждём
  восстановления позиции из сессии). }
procedure TFb2Viewer.UpdateTracking;
begin
  if FTrackTimer = nil then
    Exit;
  FTrackTimer.Enabled := (FHtml <> '') and
    (FPendingScroll or ((FScrollListeners <> nil) and
      (FScrollListeners.Count > 0)));
end;

procedure TFb2Viewer.NotifyScroll;
begin
  ListFire(FScrollListeners, Self);
end;

{ Опрос позиции прокрутки: HtmlViewer не даёт события на колесо, клавиши и
  программную прокрутку (OnScroll есть только у полосы прокрутки), поэтому
  дешевле опрашивать Position несколько раз в секунду. }
procedure TFb2Viewer.DoTrackTimer(Sender: TObject);
var
  Pos: Integer;
begin
  if (FViewer = nil) or (FHtml = '') then
    Exit;
  { Сначала пытаемся восстановить сохранённую позицию: раскладка может быть
    готова не сразу (картинки подгружаются асинхронно). }
  if TryApplyPendingScroll then
    Exit;
  Pos := FViewer.VScrollBarPosition;
  if Pos = FLastScrollPos then
    Exit;
  FLastScrollPos := Pos;
  NotifyScroll;
end;

{ ===================== Текущая глава (для дерева и статус-бара) ===================== }

{ Пересчитать Y-позиции якорей TocEntries (один раз на документ/раскладку). }
procedure TFb2Viewer.RefreshTocPositions;
var
  Entries: TTocEntryList;
  I: Integer;
begin
  SetLength(FTocY, 0);
  FTocSerial := -1;
  if FViewer <> nil then
    FTocRange := FViewer.VScrollBarRange
  else
    FTocRange := -1;
  if (FConverter = nil) or (FViewer = nil) then
    Exit;
  Entries := FConverter.TocEntries;
  if Entries = nil then
    Exit;
  SetLength(FTocY, Entries.Count);
  for I := 0 to Entries.Count - 1 do
    FTocY[I] := AnchorPosition(Entries[I].Anchor);
  FTocSerial := FDocumentSerial;
end;

{ Кэш недействителен при смене документа, а также когда меняется высота
  документа: картинки подгружаются асинхронно и после первичной раскладки
  сдвигают заголовки вниз; смена размера окна тоже переразмечает текст. }
function TFb2Viewer.TocPositionsValid: Boolean;
begin
  Result := (FTocSerial = FDocumentSerial) and (FViewer <> nil) and
    (FTocRange = FViewer.VScrollBarRange);
end;

function TFb2Viewer.TocEntryPosition(Index: Integer): Integer;
begin
  if not TocPositionsValid then
    RefreshTocPositions;
  if (Index < 0) or (Index >= Length(FTocY)) then
    Result := -1
  else
    Result := FTocY[Index];
end;

function TFb2Viewer.TocIndexOfCurrent(Margin: Integer): Integer;
var
  Pos, I, Best, BestY: Integer;
begin
  Result := -1;
  if (FViewer = nil) or (FConverter = nil) then
    Exit;
  if not TocPositionsValid then
    RefreshTocPositions;
  if Length(FTocY) = 0 then
    Exit;

  Pos := FViewer.VScrollBarPosition + Margin;
  Best := -1;
  BestY := -1;
  for I := 0 to High(FTocY) do
    if (FTocY[I] >= 0) and (FTocY[I] <= Pos) and (FTocY[I] >= BestY) then
    begin
      BestY := FTocY[I];
      Best := I;
    end;
  { Выше первого заголовка — считаем первую главу. }
  if (Best < 0) and (FTocY[0] >= 0) then
    Best := 0;
  Result := Best;
end;

function TFb2Viewer.NewTempDir: UnicodeString;
begin
  Result := IncludeTrailingPathDelimiter(GetTempDir) +
    'fb2viewer_' + IntToHex(Random(MaxInt), 8) + PathDelim;
  ForceDirectories(Result);
end;

procedure TFb2Viewer.ClearTempDir;
begin
  if (FTempDir <> '') and DirectoryExists(FTempDir) then
    DeleteDirectory(FTempDir, False);
  FTempDir := '';
end;

procedure TFb2Viewer.LoadFromFile(const AFileName: TFileName);
begin
  { EPUB и Markdown: конвертируем в FB2 в памяти и показываем как книгу.
    FileName останется путём к исходному файлу. }
  if IsEpubFile(AFileName) then
  begin
    LoadFromEpub(AFileName);
    Exit;
  end;
  if IsMarkdownFile(AFileName) then
  begin
    LoadFromMarkdown(AFileName);
    Exit;
  end;
  if IsDocxFile(AFileName) then
  begin
    LoadFromDocx(AFileName);
    Exit;
  end;

  { Архив .fb2.zip: книгу читаем из памяти, временный каталог не нужен.
    FileName остаётся путём к архиву — сессия чтения и дерево файлов
    работают с ним так же, как с обычным .fb2. }
  if IsZipArchive(UnicodeString(AFileName)) then
  begin
    LoadFromZip(AFileName);
    Exit;
  end;

  { Имя файла приходит в кодировке LCL (UTF-8), а RTL/конвертер работают с
    системной кодировкой — конвертируем явно, иначе кириллические пути
    («книга.fb2») не откроются. }
  { Application.ProcessMessages между этапами может привести сюда повторно
    (пользователь успел выбрать другую книгу) — текущая загрузка главнее. }
  if FLoading then
    Exit;
  if not FileExists(UTF8ToSys(AFileName)) then
    raise Exception.CreateFmt('FB2 не найден: %s', [AFileName]);

  { Новая загрузка отменяет незавершённое восстановление позиции. }
  FPendingScroll := False;
  FPendingAnchor := '';

  ClearTempDir;
  FTempDir := NewTempDir;
  FFileName := AFileName;
  FStreamSource := False;        { HTML и картинки — на диске (temp-каталог) }
  FLoadedZipEntry := '';
  FNoteBackPos.Clear;

  FLoading := True;
  FLastProgressPercent := -1;
  FLastPumpedPercent := -1;
  try
    try
      DoLoadProgress(lsStarting, 0);

      FreeAndNil(FConverter);
      FConverter := TFb2ToHtmlConverter.Create(nil, FImageDir, FHeadingOffset,
        FMaxHeadingLevel, FIncludeToc, FTocTitle, FIncludeAnnotation,
        FIncludeEpigraphs, FIncludeCover, FInlineImages, FNoteLinks, EffectiveCss);
      Inc(FDocumentSerial);
      { Выгружаем на диск только те картинки, что реально попали в HTML: иначе
        книги с большим числом неиспользуемых <binary> (например, «Дон Кихот» —
        525 штук) заваливают временный каталог на десятки мегабайт. }
      FConverter.OnlyUsedImages := True;
      FConverter.OnProgress := @ConverterProgress;

      DoLoadProgress(lsReading, 5);
      FHtml := FConverter.Convert(UTF8ToString(AFileName));  { HTML + TocEntries }
      FHtmlPath := IncludeTrailingPathDelimiter(FTempDir) + 'book.html';
      WriteUtf8File(FHtmlPath, FHtml);               { HTML на диск (база картинок) }
      FConverter.SaveImages(FTempDir);               { картинки в FTempDir\ImageDir }

      { Reference = путь к book.html: HtmlViewer возьмёт кодировку из
        meta charset и разрешит относительные img src="images/…". }
      DoLoadProgress(lsLayout, 95);
      FViewer.OnImageRequest := nil;
      FViewer.LoadFromString(FHtml, FHtmlPath);

      DoLoadProgress(lsDone, 100);
    except
      DoLoadProgress(lsFailed, 0);
      raise;
    end;
  finally
    if FConverter <> nil then
      FConverter.OnProgress := nil;
    FLoading := False;
  end;

  NotifyDocumentLoad;
end;

procedure TFb2Viewer.LoadFromStream(AStream: TStream);
begin
  { Публичный вход: источник — поток, пути у документа нет. }
  FLoadedZipEntry := '';
  LoadStream(AStream, '');
end;

procedure TFb2Viewer.LoadStream(AStream: TStream;
  const AFileName: TFileName);
begin
  { Без временного каталога: HTML держим в памяти, картинки — из binary.
    AFileName — путь-источник для свойства FileName: '' (LoadFromStream) или
    путь к .fb2.zip (LoadFromZip); по нему работают сессия чтения и дерево
    файлов. }
  if FLoading then
    Exit;

  { Новая загрузка отменяет незавершённое восстановление позиции. }
  FPendingScroll := False;
  FPendingAnchor := '';

  ClearTempDir;
  FTempDir := '';
  FFileName := AFileName;
  FStreamSource := True;          { HTML и картинки — в памяти }
  FHtmlPath := '';
  FNoteBackPos.Clear;

  FLoading := True;
  FLastProgressPercent := -1;
  FLastPumpedPercent := -1;
  try
    try
      DoLoadProgress(lsStarting, 0);

      FreeAndNil(FConverter);
      FConverter := TFb2ToHtmlConverter.Create(nil, FImageDir, FHeadingOffset,
        FMaxHeadingLevel, FIncludeToc, FTocTitle, FIncludeAnnotation,
        FIncludeEpigraphs, FIncludeCover, FInlineImages, FNoteLinks, EffectiveCss);
      Inc(FDocumentSerial);
      FConverter.OnProgress := @ConverterProgress;

      DoLoadProgress(lsReading, 5);
      FHtml := FConverter.ConvertStream(AStream);    { HTML-строка + TocEntries }

      DoLoadProgress(lsLayout, 95);
      FViewer.OnImageRequest := @ViewerImageRequest; { картинки отдаём из памяти }
      FViewer.LoadFromString(FHtml, '');

      DoLoadProgress(lsDone, 100);
    except
      DoLoadProgress(lsFailed, 0);
      raise;
    end;
  finally
    if FConverter <> nil then
      FConverter.OnProgress := nil;
    FLoading := False;
  end;

  NotifyDocumentLoad;
end;

function TFb2Viewer.LoadZipBook(const AZipFile: TFileName): TMemoryStream;
var
  Data: TBytes;
  EntryName: UnicodeString;
begin
  { Читается только запись с книгой: многокнижный архив не распаковывается
    целиком. Запись — ZipEntry, если задана, иначе выбор автоматический. }
  Data := ReadFb2FromZip(UnicodeString(AZipFile), FZipEntry, EntryName);
  FLoadedZipEntry := EntryName;
  Result := TMemoryStream.Create;
  try
    if Length(Data) > 0 then
      Result.WriteBuffer(Data[0], Length(Data));
    Result.Position := 0;
  except
    Result.Free;
    raise;
  end;
end;

procedure TFb2Viewer.LoadFromZip(const AZipFile: TFileName);
var
  Book: TMemoryStream;
begin
  if FLoading then
    Exit;
  if not FileExists(UTF8ToSys(AZipFile)) then
    raise Exception.CreateFmt('Архив не найден: %s', [AZipFile]);

  { Книга распаковывается в память, режим загрузки — потоковый (временного
    каталога нет), а FileName указывает на архив. }
  Book := LoadZipBook(AZipFile);
  try
    LoadStream(Book, AZipFile);
  finally
    Book.Free;
  end;
end;

procedure TFb2Viewer.LoadFb2Xml(const AFileName: TFileName;
  const AXml: UnicodeString);
var
  Book: TMemoryStream;
  XmlText: UTF8String;
begin
  { XML от конвертера грузим сразу из памяти: временный каталог не нужен,
    картинки лежат в <binary> и отдаются через OnImageRequest. }
  XmlText := UTF8Encode(AXml);
  Book := TMemoryStream.Create;
  try
    if Length(XmlText) > 0 then
      Book.WriteBuffer(XmlText[1], Length(XmlText));
    Book.Position := 0;
    FLoadedZipEntry := '';         { книга не из архива }
    LoadStream(Book, AFileName);
  finally
    Book.Free;
  end;
end;

procedure TFb2Viewer.LoadFromEpub(const AFileName: TFileName);
var
  EpubConv: TEpubToFb2Converter;
  Xml: UnicodeString;
begin
  if FLoading then
    Exit;
  if not FileExists(UTF8ToSys(AFileName)) then
    raise Exception.CreateFmt('EPUB не найден: %s', [AFileName]);

  { EPUB -> структуры FB2 -> XML в памяти; дальше работает обычный конвейер
    (оглавление, сноски, картинки из <binary>), см. LoadFb2Xml. }
  EpubConv := TEpubToFb2Converter.Create;
  try
    EpubConv.Convert(UnicodeString(AFileName));
    Xml := EpubConv.ToXml;
  finally
    EpubConv.Free;
  end;
  LoadFb2Xml(AFileName, Xml);
end;

procedure TFb2Viewer.LoadFromMarkdown(const AFileName: TFileName);
var
  MdConv: TMarkdownToFb2Converter;
  Xml: UnicodeString;
begin
  if FLoading then
    Exit;
  if not FileExists(UTF8ToSys(AFileName)) then
    raise Exception.CreateFmt('Markdown не найден: %s', [AFileName]);

  { Markdown -> структуры FB2 -> XML в памяти (заголовки, списки, таблицы,
    картинки рядом с файлом) — дальше LoadFb2Xml. }
  MdConv := TMarkdownToFb2Converter.Create(UnicodeString(AFileName));
  try
    MdConv.Convert;
    Xml := MdConv.ToXml;
  finally
    MdConv.Free;
  end;
  LoadFb2Xml(AFileName, Xml);
end;

procedure TFb2Viewer.LoadFromDocx(const AFileName: TFileName);
var
  DocxConv: TDocxToFb2Converter;
  Xml: UnicodeString;
begin
  if FLoading then
    Exit;
  if not FileExists(UTF8ToSys(AFileName)) then
    raise Exception.CreateFmt('DOCX не найден: %s', [AFileName]);

  { DOCX -> структуры FB2 -> XML в памяти (заголовки стилями HeadingN,
    таблицы, картинки из word/media) — дальше LoadFb2Xml. }
  DocxConv := TDocxToFb2Converter.Create;
  try
    DocxConv.Convert(UnicodeString(AFileName));
    Xml := DocxConv.ToXml;
  finally
    DocxConv.Free;
  end;
  LoadFb2Xml(AFileName, Xml);
end;

procedure TFb2Viewer.ViewerImageRequest(Sender: TObject; const SRC: ThtString;
  var Stream: TStream);
var
  Binary: TBinary;
  Data: TBytes;
begin
  Stream := nil;
  if (FConverter = nil) or (FImgStream = nil) then
    Exit;
  Binary := FConverter.BinaryByFilename(UnicodeString(SRC));
  if Binary = nil then
    Exit;
  Data := FConverter.Parser.BinaryData(Binary);
  FImgStream.Clear;
  if Length(Data) > 0 then
    FImgStream.WriteBuffer(Data[0], Length(Data));
  FImgStream.Position := 0;
  Stream := FImgStream;   { поток принадлежит компоненту, HtmlViewer его не освобождает }
end;

procedure TFb2Viewer.GoToAnchor(const Anchor: UnicodeString);
var
  Y: Integer;
begin
  if FHtml = '' then
    Exit;
  { Пользователь выбрал переход — незавершённое восстановление позиции из
    сессии больше не нужно. }
  FPendingScroll := False;
  { Быстрый путь: якорь есть в текущем документе — просто прокручиваем к нему.
    AnchorPosition возвращает Y в той же системе координат, что и
    VScrollBarPosition (движок сам прыгает к якорю через ScrollTo(YPosition)),
    поэтому VScrollBarPosition := Y даёт тот же результат, что и перезагрузка
    строки с '#anchor', но без повторного разбора и раскладки документа. }
  Y := AnchorPosition(Anchor);
  if Y >= 0 then
  begin
    FViewer.VScrollBarPosition := Y;
    FLastScrollPos := FViewer.VScrollBarPosition; { чтобы таймер не сработал зря }
    NotifyScroll;                                 { сразу обновить дерево/статус }
    Exit;
  end;
  { Якоря нет в разобранном документе — прежний путь: перезагрузка строки с
    '#anchor' (HtmlViewer разберёт его через SplitDest). База — путь к book.html
    (файловый режим) или '' (потоковый режим, картинки идут через OnImageRequest). }
  FViewer.LoadFromString(FHtml, FHtmlPath + '#' + Anchor);
end;

function TFb2Viewer.HandleInternalLink(const Src: UnicodeString): Boolean;
var
  Hash, Idx: Integer;
  Target, Key, P: UnicodeString;
begin
  Result := False;
  if FNoteBackPos = nil then
    Exit;
  { Переход по ссылке отменяет отложенное восстановление позиции. }
  FPendingScroll := False;
  Hash := LastDelimiter('#', Src);
  if Hash = 0 then
    Exit;
  Target := Copy(Src, Hash + 1, MaxInt);
  if Target = '' then
    Exit;

  if Copy(Target, 1, 8) = 'noteref-' then
  begin
    { Обратная ссылка из сноски: возвращаемся туда, откуда пришли (движок сам
      сюда попасть не может — инлайновые якоря он позиционирует неверно). }
    Idx := FNoteBackPos.IndexOfName(Target);
    if Idx >= 0 then
    begin
      P := FNoteBackPos.ValueFromIndex[Idx];
      FViewer.VScrollBarPosition := StrToIntDef(P, 0);
      FLastScrollPos := FViewer.VScrollBarPosition;
      NotifyScroll;
      Result := True;
    end;
  end
  else
  begin
    { Ссылка на сноску (или иной якорь): запоминаем текущую позицию, чтобы
      вернуться по обратной ссылке. Сам переход выполняет движок. }
    Key := 'noteref-' + Target;
    P := IntToStr(FViewer.VScrollBarPosition);
    Idx := FNoteBackPos.IndexOfName(Key);
    if Idx >= 0 then
      FNoteBackPos[Idx] := Key + '=' + P
    else
      FNoteBackPos.Add(Key + '=' + P);
  end;
end;

procedure TFb2Viewer.Reload;
begin
  if FFileName <> '' then
    LoadFromFile(FFileName);
end;

procedure TFb2Viewer.ReRender;
begin
  { Во время загрузки документ ещё не готов — перерисовывать нечего. }
  if FLoading then
    Exit;
  if FHtml = '' then
    Exit;
  if not FStreamSource then
  begin
    { Файловый режим: картинки лежат на диске, база — путь к book.html. }
    FViewer.OnImageRequest := nil;
    FViewer.LoadFromString(FHtml, FHtmlPath);
  end
  else
  begin
    { Потоковый режим (в том числе книга из .fb2.zip): картинки отдаются из
      памяти через OnImageRequest. }
    FViewer.OnImageRequest := @ViewerImageRequest;
    FViewer.LoadFromString(FHtml, '');
  end;
  NotifyDocumentLoad;
end;

procedure TFb2Viewer.SetFileName(const Value: TFileName);
begin
  if Value = FFileName then
    Exit;
  { Идёт загрузка (внутри могли прокачать сообщения) — не меняем FileName,
    иначе он разойдётся с фактически загруженным документом. }
  if FLoading then
    Exit;
  FFileName := Value;
  if (Value <> '') and FileExists(UTF8ToSys(Value)) then
    LoadFromFile(Value);
end;

{ ===================== CSS ===================== }

function TFb2Viewer.EffectiveCss: UnicodeString;
begin
  { Приоритет: внешний файл -> свой текст -> встроенный DEFAULT_CSS. Если файл
    задан, но недоступен (удалён, нет прав), молча откатываемся к Css, чтобы
    компонент не падал из-за оформления. }
  if (FCssFile <> '') and ReadCssText(FCssFile, Result) then
    Exit;
  if FCss <> '' then
    Result := FCss
  else
    Result := DEFAULT_CSS;
end;

procedure TFb2Viewer.CssChanged;
var
  SavePos: Integer;
begin
  { Идёт загрузка: конвертер может быть заполнен наполовину. Новое значение
    Css уже сохранено в FCss и применится при следующей пересборке. }
  if FLoading then
    Exit;
  if (FConverter = nil) or (FHtml = '') then
    Exit;   { книги ещё нет — значение применится при загрузке }
  SavePos := FViewer.VScrollBarPosition;
  FConverter.Css := EffectiveCss;
  { Пересборка HTML из уже разобранного FB2: текст, якоря и сноски те же,
    меняется только <style> — повторный разбор книги не нужен. }
  FHtml := FConverter.RenderHtml;
  if FHtmlPath <> '' then
    WriteUtf8File(FHtmlPath, FHtml);
  ReRender;                                { перезагрузка строки в движок }
  FViewer.VScrollBarPosition := SavePos;   { сохранить позицию чтения }
  FLastScrollPos := FViewer.VScrollBarPosition;
  NotifyScroll;                            { сразу обновить дерево/статус }
end;

procedure TFb2Viewer.SetCss(const Value: UnicodeString);
begin
  if Value = FCss then
    Exit;
  FCss := Value;
  CssChanged;
end;

procedure TFb2Viewer.SetCssFile(const Value: TFileName);
begin
  if Value = FCssFile then
    Exit;
  FCssFile := Value;
  CssChanged;
end;

procedure TFb2Viewer.LoadCssFromString(const ACss: UnicodeString);
begin
  FCss := ACss;
  FCssFile := '';     { задан текст — внешний файл больше не используется }
  CssChanged;
end;

procedure TFb2Viewer.LoadCssFromFile(const AFileName: TFileName);
var
  Content: UnicodeString;
begin
  if not ReadCssText(AFileName, Content) then
    raise Exception.CreateFmt('CSS-файл не найден: %s', [AFileName]);
  FCssFile := AFileName;
  FCss := Content;    { кэш содержимого: если файл потом исчезнет, останется он }
  CssChanged;
end;

procedure TFb2Viewer.ResetCss;
begin
  if (FCss = '') and (FCssFile = '') then
    Exit;
  FCss := '';
  FCssFile := '';
  CssChanged;
end;

procedure TFb2Viewer.ViewerHotSpotClick(Sender: TObject;
  const SRC: ThtString; var Handled: Boolean);
begin
  { Внешние ссылки — в системный браузер; внутренние якоря отдаём движку, кроме
    обратных ссылок сносок (их обрабатываем сами — см. HandleInternalLink). }
  if Pos('://', SRC) > 0 then
  begin
    OpenURL(SRC);
    Handled := True;
    Exit;
  end;
  Handled := HandleInternalLink(UnicodeString(SRC));
end;

end.

