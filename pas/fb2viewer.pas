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
  fb2_structures, fb2_parser, fb2_html,   { наш порт — без GUI }
  HtmlGlobals, HtmlView, HTMLUn2;          { HtmlViewer 11: движок + TIDObject }

type
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
    FOnDocumentLoad: TNotifyEvent;
    FImgStream: TMemoryStream;
    FDocLoadListeners: TList;      { PNotifyEvent — подписчики OnDocumentLoad }
    FScrollListeners: TList;       { PNotifyEvent — подписчики изменения прокрутки }
    FTrackTimer: TTimer;           { опрос позиции прокрутки (см. UpdateTracking) }
    FLastScrollPos: Integer;
    FTocY: array of Integer;       { кэш Y-позиций якорей TocEntries }
    FTocSerial: Integer;           { для какого документа посчитан кэш }
    FTocRange: Integer;            { высота документа, при которой посчитан кэш }
    FNoteBackPos: TStringList;     { 'noteref-<id>' -> позиция возврата в тексте }

    function NewTempDir: UnicodeString;
    procedure ClearTempDir;
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
  end;

implementation

type
  { Указатель на подписчика (для списков FDocLoadListeners/FScrollListeners). }
  PNotifyEvent = ^TNotifyEvent;

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

{ Прочитать текстовый файл (CSS): BOM UTF-8/UTF-16 учитывается, без BOM текст
  считается UTF-8 (наш стандарт — как в fb2_html и остальных модулях).
  False — файл недоступен. }
function ReadCssText(const FileName: TFileName; out Css: UnicodeString): Boolean;
var
  FS: TFileStream;
  Bytes: TBytes;
  N: Int64;
begin
  Result := False;
  Css := '';
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
    Css := TEncoding.Unicode.GetString(Bytes, 2, Length(Bytes) - 2)
  else if (Length(Bytes) >= 2) and (Bytes[0] = $FE) and (Bytes[1] = $FF) then
    Css := TEncoding.BigEndianUnicode.GetString(Bytes, 2, Length(Bytes) - 2)
  else
  begin
    if (Length(Bytes) >= 3) and (Bytes[0] = $EF) and (Bytes[1] = $BB) and
      (Bytes[2] = $BF) then
      Css := TEncoding.UTF8.GetString(Bytes, 3, Length(Bytes) - 3)
    else
      Css := TEncoding.UTF8.GetString(Bytes);
  end;
  Result := True;
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

  FViewer := THtmlViewer.Create(Self);
  FViewer.Parent := Self;
  FViewer.Align := alClient;
  FViewer.DefFontName := 'Georgia';
  FViewer.DefPreFontName := 'Courier New';
  FViewer.OnHotSpotClick := @ViewerHotSpotClick;
  FImgStream := TMemoryStream.Create;
  FDocLoadListeners := TList.Create;
  FScrollListeners := TList.Create;
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
  ListFree(FScrollListeners);
  FreeAndNil(FDocLoadListeners);
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

{ ===================== Прокрутка ===================== }

function TFb2Viewer.ScrollPosition: Integer;
begin
  if FViewer = nil then
    Result := 0
  else
    Result := FViewer.VScrollBarPosition;
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

{ Включить опрос позиции, только если есть документ и подписчики. }
procedure TFb2Viewer.UpdateTracking;
begin
  if FTrackTimer = nil then
    Exit;
  FTrackTimer.Enabled := (FHtml <> '') and (FScrollListeners <> nil) and
    (FScrollListeners.Count > 0);
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
  { Имя файла приходит в кодировке LCL (UTF-8), а RTL/конвертер работают с
    системной кодировкой — конвертируем явно, иначе кириллические пути
    («книга.fb2») не откроются. }
  if not FileExists(UTF8ToSys(AFileName)) then
    raise Exception.CreateFmt('FB2 не найден: %s', [AFileName]);

  ClearTempDir;
  FTempDir := NewTempDir;
  FFileName := AFileName;
  FNoteBackPos.Clear;

  FreeAndNil(FConverter);
  FConverter := TFb2ToHtmlConverter.Create(nil, FImageDir, FHeadingOffset,
    FMaxHeadingLevel, FIncludeToc, FTocTitle, FIncludeAnnotation,
    FIncludeEpigraphs, FIncludeCover, FInlineImages, FNoteLinks, EffectiveCss);
  Inc(FDocumentSerial);
  { Выгружаем на диск только те картинки, что реально попали в HTML: иначе
    книги с большим числом неиспользуемых <binary> (например, «Дон Кихот» —
    525 штук) заваливают временный каталог на десятки мегабайт. }
  FConverter.OnlyUsedImages := True;

  FHtml := FConverter.Convert(UTF8ToString(AFileName));  { HTML + TocEntries }
  FHtmlPath := IncludeTrailingPathDelimiter(FTempDir) + 'book.html';
  WriteUtf8File(FHtmlPath, FHtml);                 { HTML на диск (база картинок) }
  FConverter.SaveImages(FTempDir);                 { картинки в FTempDir\ImageDir }

  { Reference = путь к book.html: HtmlViewer возьмёт кодировку из
    meta charset и разрешит относительные img src="images/…". }
  FViewer.OnImageRequest := nil;
  FViewer.LoadFromString(FHtml, FHtmlPath);

  NotifyDocumentLoad;
end;

procedure TFb2Viewer.LoadFromStream(AStream: TStream);
begin
  { Без временного каталога: HTML держим в памяти, картинки — из binary. }
  ClearTempDir;
  FTempDir := '';
  FFileName := '';
  FHtmlPath := '';
  FNoteBackPos.Clear;

  FreeAndNil(FConverter);
  FConverter := TFb2ToHtmlConverter.Create(nil, FImageDir, FHeadingOffset,
    FMaxHeadingLevel, FIncludeToc, FTocTitle, FIncludeAnnotation,
    FIncludeEpigraphs, FIncludeCover, FInlineImages, FNoteLinks, EffectiveCss);
  Inc(FDocumentSerial);

  FHtml := FConverter.ConvertStream(AStream);     { HTML-строка + TocEntries }

  FViewer.OnImageRequest := @ViewerImageRequest;  { картинки отдаём из памяти }
  FViewer.LoadFromString(FHtml, '');

  NotifyDocumentLoad;
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
  if FHtml = '' then
    Exit;
  if FFileName <> '' then
  begin
    { Файловый режим: картинки лежат на диске, база — путь к book.html. }
    FViewer.OnImageRequest := nil;
    FViewer.LoadFromString(FHtml, FHtmlPath);
  end
  else
  begin
    { Потоковый режим: картинки отдаются из памяти через OnImageRequest. }
    FViewer.OnImageRequest := @ViewerImageRequest;
    FViewer.LoadFromString(FHtml, '');
  end;
  NotifyDocumentLoad;
end;

procedure TFb2Viewer.SetFileName(const Value: TFileName);
begin
  if Value = FFileName then
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

