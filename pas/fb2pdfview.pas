unit fb2pdfview;
{ Визуальный компонент просмотра PDF — обёртка над PdfiumPascal (LCL-контрол
  TPdfPageViewControl) и PdfiumLib (привязки к движку pdfium — тому же, что в
  Chrome/Edge: страницу рисует он, а не наш код).

  Схема:  book.pdf -> TPdfPageViewControl (PdfiumPascalViewPageCtrl)
                     -> PdfiumLib -> pdfium.dll -> TBitmap -> TCanvas

  Чем отличается от TFb2Viewer (fb2viewer.pas): документ не конвертируется в
  HTML, а рисуется движком pdfium; навигация постраничная (а не прокрутка
  сплошного полотна); доступен TPdfDocument — оглавление, вложения, текст,
  печать (TPdfDocumentPrinter, только Windows).

  Встроенный сайдбар: ShowOutline (вкладка «Содержание» — дерево закладок PDF,
  обход FPDFBookmark_* в fb2pdfbookmarks.pas) и ShowThumbnails (вкладка
  «Миниатюры» — TPdfThumbnailsControl из PdfiumPascal); ширина колонки —
  SidebarWidth. Клик по закладке или миниатюре переходит на страницу, а смена
  страницы подсвечивает текущий раздел и прокручивает ленту.
  Для собственной раскладки есть отдельные компоненты: TFb2PdfOutline
  (fb2pdfoutline.pas) и TFb2PdfThumbnails (fb2pdfthumbnails.pas).

  Требуются сторонние исходники (в репозиторий pyFB2 не входят, MPL-2.0):
    * PdfiumLib    — https://github.com/ahausladen/PdfiumLib
                     (Source/PdfiumLib.pas, Source/PdfiumCore.pas);
    * PdfiumPascal — https://github.com/DomenicoMammola/PdfiumPascal
                     (source/PdfiumLaz.pas, source/PdfiumPascalEvents.pas,
                      source/PdfiumPascalViewPageCtrl.pas);
  и сам движок: pdfium.dll (Windows) / libpdfium.so (Linux), BSD-3-Clause.

  Путь к движку — свойство PdfiumDllFile; пусто — стандартный поиск pdfium.dll
  (каталог .exe, затем PATH; см. InitPDFium в PdfiumLib). Библиотека грузится
  один раз на процесс при первом открытии документа, поэтому PdfiumDllFile
  имеет смысл задавать до первой загрузки.

  ВАЖНО: это GUI-модуль. Он не входит в состав библиотечных .pas и не
  собирается одним fpc — его подключают в проект Lazarus с установленным
  пакетом pyfb2pdfview.lpk и путями к исходникам PdfiumLib/PdfiumPascal
  (см. README_PASCAL.md).

  Лицензии: этот файл — MIT (как и весь pyFB2); PdfiumLib и PdfiumPascal —
  MPL-2.0 (файловый копилефт: их файлы остаются под MPL, наши — под MIT);
  pdfium.dll — BSD-3-Clause, поставка вместе с программой разрешена.

  Сбой открытия (нет файла, нет движка, битый или защищённый PDF) наружу
  исключением не выбрасывается: причина попадает в LastError и OnLoadError —
  иначе установка FileName в инспекторе объектов роняла бы IDE. }

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Classes, SysUtils, Controls, ExtCtrls, Graphics, LCLIntf, LCLType,
  LazUTF8,                                 { UTF8ToSys }
  fpjson,                                  { JSON-сессия чтения }
  ComCtrls,                                { TPageControl/TTreeView сайдбара }
  fb2pdfbookmarks,                         { оглавление PDF: обход закладок }
  PdfiumCore,                              { PdfiumLib: документ, страницы }
  PdfiumLaz,                               { PdfiumPascal: отрисовка страницы }
  PdfiumPascalEvents,                      { подписка на смену страницы }
  PdfiumPascalViewPageCtrl,                { PdfiumPascal: LCL-контрол }
  PdfiumPascalThumbnailsPanelCtrl;         { PdfiumPascal: лента миниатюр }

const
  {$IFDEF MSWINDOWS}
  { Имя файла движка — для подсказок в сообщениях об ошибках. }
  FB2_PDF_LIB_NAME = 'pdfium.dll';
  {$ELSE}
  FB2_PDF_LIB_NAME = 'libpdfium.so';
  {$ENDIF}
  { Версия формата JSON-сессии (как SESSION_JSON_VERSION в fb2viewer). }
  PDF_SESSION_JSON_VERSION = 1;

type
  TFb2PdfView = class;

  { Типы движка вынесены в псевдонимы: палитра компонентов и код приложения не
    зависят от того, что сами типы объявлены в сторонних юнитах. }
  TFb2PdfScaleMode = TPdfControlScaleMode;   { smFitAuto/smFitWidth/smFitHeight/smZoom }
  TFb2PdfRotation = TPdfPageRotation;        { prNormal/pr90Clockwise/pr180/pr90CounterClockwide }
  TFb2PdfRenderOptions = TPdfPageRenderOptions;
  TFb2PdfLoadOption = TPdfDocumentLoadOption;

  { Сбой открытия документа: имени файла и текста причины достаточно, чтобы
    показать диалог или сделать запись в журнале. }
  TFb2PdfLoadErrorEvent = procedure(Sender: TObject; const AFileName: TFileName;
    const AMessage: string) of object;
  { Смена текущей страницы: PageNumber — 1-based, 0 — документа нет. }
  TFb2PdfPageChangeEvent = procedure(Sender: TObject; PageNumber,
    PageCount: Integer) of object;
  { Клик по внешней ссылке в документе (http/https/mailto). }
  TFb2PdfLinkClickEvent = procedure(Sender: TObject;
    const Url: UnicodeString) of object;

  { Сторона, с которой показывается колонка «Содержание / Миниатюры». }
  TFb2PdfSidebarPosition = (spLeft, spRight);

  { Подписчик TPdfPageViewControl: контрол уведомляет подписчиков о смене
    страницы (NotifySubscribers/pcePageChanged), но собственного события не
    публикует — поэтому нужен этот адаптер. }
  TFb2PdfPageNotify = class(TPdfPageViewControlEventsSubscription)
  private
    FView: TFb2PdfView;
  public
    property View: TFb2PdfView read FView write FView;
    procedure ChangePage(const aPageIndex: Integer); override;
  end;

  { Просмотр PDF: PdfiumPascal (TPdfPageViewControl) + pdfium (PdfiumLib). }
  TFb2PdfView = class(TCustomPanel)
  private
    FViewer: TPdfPageViewControl;
    FNotifier: TFb2PdfPageNotify;
    FFileName: TFileName;
    FPassword: UnicodeString;
    FPdfiumDllFile: TFileName;
    FLoadOption: TFb2PdfLoadOption;
    FScaleMode: TFb2PdfScaleMode;
    FZoomPercentage: Integer;
    FZoomStep: Integer;
    FRotation: TFb2PdfRotation;
    FPageBackgroundColor: TColor;
    FDrawOptions: TFb2PdfRenderOptions;
    FHighlightTextColor: TColor;
    FAllowFormEvents: Boolean;
    FOpenLinks: Boolean;
    FPageIndex: Integer;            { 0-based: движок свой индекс не публикует }
    FDocumentSerial: Integer;       { номер документа: растёт при каждой загрузке }
    FLastError: string;
    FOnDocumentLoad: TNotifyEvent;
    FOnPageChange: TFb2PdfPageChangeEvent;
    FOnLoadError: TFb2PdfLoadErrorEvent;
    FOnLinkClick: TFb2PdfLinkClickEvent;
    FDocLoadListeners: TList;       { PNotifyEvent — подписчики OnDocumentLoad }
    FPageChangeListeners: TList;    { PFb2PdfPageChangeEvent — подписчики страниц }

    { --- встроенный сайдбар: оглавление и миниатюры --- }
    FSidebar: TPanel;               { колонка слева }
    FSplitter: TSplitter;           { граница колонки }
    FSidebarPages: TPageControl;    { вкладки «Содержание» / «Миниатюры» }
    FTabOutline: TTabSheet;
    FTabThumbs: TTabSheet;
    FOutlineTree: TTreeView;        { дерево закладок }
    FThumbnailsCtrl: TPdfThumbnailsControl;
    FShowOutline: Boolean;
    FShowThumbnails: Boolean;
    FSidebarWidth: Integer;
    FSidebarPosition: TFb2PdfSidebarPosition;
    FBookmarks: TFb2PdfBookmarks;   { закладки текущего документа }
    FUpdatingOutline: Boolean;
    FIgnoreOutlineChange: TTreeNode; { узел, выделенный программно }

    { Создать колонку-сайдбар (вкладки «Содержание» и «Миниатюры»). }
    procedure CreateSidebar;
    procedure SetShowOutline(const Value: Boolean);
    procedure SetShowThumbnails(const Value: Boolean);
    procedure SetSidebarWidth(const Value: Integer);
    procedure SetSidebarPosition(const Value: TFb2PdfSidebarPosition);
    { Разместить колонку и сплиттер слева или справа (см. комментарий в
      реализации: LCL сортирует выравниваемые контролы по текущим координатам). }
    procedure ApplySidebarPosition;
    { Показать/спрятать колонку и её вкладки по ShowOutline/ShowThumbnails. }
    procedure UpdateSidebar;
    { Перестроить дерево закладок по текущему документу. }
    procedure RefreshOutline;
    { Выделить в дереве раздел, соответствующий текущей странице. }
    procedure SyncOutlineSelection;
    { Пересобрать миниатюры (сбросить кэш) под текущий документ. }
    procedure SyncThumbnails;
    procedure OutlineTreeChange(Sender: TObject; Node: TTreeNode);
    procedure ActivateOutlineNode(Node: TTreeNode);

    function GetDocument: TPdfDocument;
    { Создать вложенный контрол движка, если его ещё нет. False — pdfium
      недоступен (нет pdfium.dll), причина в AError. }
    function EnsureViewer(out AError: string): Boolean;
    procedure SetFileName(const Value: TFileName);
    procedure SetPdfiumDllFile(const Value: TFileName);
    procedure SetScaleMode(const Value: TFb2PdfScaleMode);
    procedure SetZoomPercentage(const Value: Integer);
    procedure SetRotation(const Value: TFb2PdfRotation);
    procedure SetPageBackgroundColor(const Value: TColor);
    procedure SetDrawOptions(const Value: TFb2PdfRenderOptions);
    procedure SetHighlightTextColor(const Value: TColor);
    procedure SetAllowFormEvents(const Value: Boolean);
    { Задать масштаб и переключить режим в smZoom (общая часть ZoomIn/Out). }
    procedure SetZoom(APercentage: Integer);
    { Передать путь к движку в PdfiumCore (глобальная PDFiumDllFileName). }
    procedure ApplyPdfiumDllFile;
    procedure FailLoad(const AFileName: TFileName; const AMessage: string);
    procedure NotifyDocumentLoad;
    procedure NotifyPageChange;
    procedure InternalPageChanged(const APageIndex: Integer);
    procedure ViewerLinkClick(Sender: TObject; Url: string);

  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    { Явно создать вложенный контрол движка (загружает pdfium.dll), не дожидаясь
      первой загрузки документа. False — движок недоступен, причина в LastError. }
    function InitViewer: Boolean;

    { Открыть PDF. Исключения не выбрасываются: при сбое документ остаётся
      закрытым, причина — в LastError и OnLoadError. }
    procedure LoadFromFile(const AFileName: TFileName);
    procedure Reload;
    { Закрыть документ: страниц не остаётся, подписчики получают событие. }
    procedure Close;
    function IsLoaded: Boolean;

    { Всего страниц (0 — документа нет). }
    function PageCount: Integer;
    { Текущая страница, 0-based (как индексы TPdfDocument.Pages). }
    property PageIndex: Integer read FPageIndex;
    { Текущая страница, 1-based — для интерфейса («с. 5 из 42»). 0 — нет
      документа. }
    function PageNumber: Integer;

    { Переход: индекс вне диапазона прижимается к границам. True — страница
      выбрана (в том числе если она уже была текущей). }
    function GoToPage(APageIndex: Integer): Boolean;
    function GoToPageNumber(APageNumber: Integer): Boolean;
    function FirstPage: Boolean;
    function LastPage: Boolean;
    function NextPage: Boolean;
    function PrevPage: Boolean;
    function CanGoNext: Boolean;
    function CanGoPrev: Boolean;

    { Масштаб. ZoomIn/ZoomOut переключают ScaleMode в smZoom и меняют процент
      на ZoomStep; ZoomReset — страница целиком (smFitAuto). }
    procedure ZoomIn;
    procedure ZoomOut;
    procedure ZoomReset;

    { Поворот на 90° (по/против часовой) и сброс. }
    procedure RotateLeft;
    procedure RotateRight;
    procedure RotateReset;

    { Подсветить совпадения на ТЕКУЩЕЙ странице (ограничение
      TPdfPageViewControl: поиск идёт только по открытой странице). Пустая
      строка снимает подсветку. }
    function FindText(const S: UnicodeString; MatchCase: Boolean = False;
      MatchWholeWord: Boolean = False): Boolean;
    procedure ClearSearch;

    { Состояние чтения в JSON (UTF-8): файл, страница, масштаб, поворот. }
    function SessionToJson: UnicodeString;
    { Применить состояние: при другом файле — открыть его, затем восстановить
      страницу/масштаб/поворот. Ошибки разбора JSON — исключением. }
    procedure ApplySession(const AJson: UnicodeString);
    procedure SaveSessionToFile(const AFileName: TFileName);
    procedure LoadSessionFromFile(const AFileName: TFileName);

    { Подписка на загрузку документа: в отличие от OnDocumentLoad, подписчиков
      может быть несколько (панель читалки, статус-бар и т. п.). }
    procedure AddDocumentLoadListener(const Handler: TNotifyEvent);
    procedure RemoveDocumentLoadListener(const Handler: TNotifyEvent);
    { Подписка на смену страницы (статус-бар, панель миниатюр и т. п.). }
    procedure AddPageChangeListener(const Handler: TFb2PdfPageChangeEvent);
    procedure RemovePageChangeListener(const Handler: TFb2PdfPageChangeEvent);

    { Вложенный контрол движка: масштаб, поворот, подсветка, формы, ссылки —
      всё, что опубликовано в TPdfPageViewControl. }
    property Viewer: TPdfPageViewControl read FViewer;
    { Документ pdfium: Pages, Attachments, метаданные, печать. }
    property Document: TPdfDocument read GetDocument;
    { Дерево оглавления встроенного сайдбара (закладки PDF). }
    property OutlineTree: TTreeView read FOutlineTree;
    { Лента миниатюр встроенного сайдбара. }
    property ThumbnailsControl: TPdfThumbnailsControl read FThumbnailsCtrl;
    { Закладки текущего документа (nil — не читались). Владеет компонент. }
    property Bookmarks: TFb2PdfBookmarks read FBookmarks;
    { Номер текущего документа: растёт при каждой загрузке и закрытии. По нему
      связанные компоненты отличают новый документ от повторного события. }
    property DocumentSerial: Integer read FDocumentSerial;
    { Причина последнего сбоя открытия ('' — сбоя не было). }
    property LastError: string read FLastError;
    { Имя открытого файла ('' — документа нет). }
    property OpenedFileName: TFileName read FFileName;

  published
    { У «Custom»-предков (TCustomPanel) Align и Anchors объявлены public,
      поэтому переопубликовываем их для инспектора объектов и .lfm (как в
      TFb2Viewer). }
    property Align;
    property Anchors;
    { Показывать встроенную колонку с оглавлением (закладки PDF) на вкладке
      «Содержание». }
    property ShowOutline: Boolean read FShowOutline write SetShowOutline
      default False;
    { Показывать встроенную колонку с миниатюрами страниц на вкладке
      «Миниатюры». }
    property ShowThumbnails: Boolean read FShowThumbnails
      write SetShowThumbnails default False;
    { Ширина колонки по умолчанию (пользователь может тянуть сплиттер). }
    property SidebarWidth: Integer read FSidebarWidth write SetSidebarWidth
      default 220;
    { С какой стороны показывать колонку: spLeft (по умолчанию) или spRight. }
    property SidebarPosition: TFb2PdfSidebarPosition read FSidebarPosition
      write SetSidebarPosition default spLeft;
    { PDF-файл. Установка загружает документ (в IDE — только если файл есть).
      При сбое открытия значение сбрасывается в '' — смотрите LastError. }
    property FileName: TFileName read FFileName write SetFileName;
    { Пароль для защищённых документов (RC4/AES). Применяется при загрузке. }
    property Password: UnicodeString read FPassword write FPassword;
    { Путь к pdfium.dll/libpdfium.so. Пусто — стандартный поиск движка.
      Действует до первой загрузки документа в процессе. }
    property PdfiumDllFile: TFileName read FPdfiumDllFile
      write SetPdfiumDllFile;
    { Как читать файл. dloDefault — штатный путь pdfium (FPDF_LoadDocument):
      работает с любыми путями и файлами > 2 ГБ; документ держит файл
      открытым. dloMemory/dloMMF/dloOnDemand — альтернативные режимы PdfiumLib
      (файл читается в память/через MMF). }
    property LoadOption: TFb2PdfLoadOption read FLoadOption write FLoadOption
      default dloDefault;
    property ScaleMode: TFb2PdfScaleMode read FScaleMode write SetScaleMode
      default smFitAuto;
    property ZoomPercentage: Integer read FZoomPercentage
      write SetZoomPercentage default 100;
    { Шаг ZoomIn/ZoomOut, % (значения < 1 не применяются). }
    property ZoomStep: Integer read FZoomStep write FZoomStep default 10;
    property Rotation: TFb2PdfRotation read FRotation write SetRotation
      default prNormal;
    property PageBackgroundColor: TColor read FPageBackgroundColor
      write SetPageBackgroundColor default clWhite;
    property DrawOptions: TFb2PdfRenderOptions read FDrawOptions
      write SetDrawOptions default [proAnnotations];
    property HighlightTextColor: TColor read FHighlightTextColor
      write SetHighlightTextColor default clYellow;
    property AllowFormEvents: Boolean read FAllowFormEvents
      write SetAllowFormEvents default True;
    { Открывать внешние ссылки документа в системном браузере
      (LCLIntf.OpenURL). }
    property OpenLinks: Boolean read FOpenLinks write FOpenLinks default False;
    { Документ открыт и отрисован — либо закрыт (счётчик DocumentSerial вырос). }
    property OnDocumentLoad: TNotifyEvent read FOnDocumentLoad
      write FOnDocumentLoad;
    property OnPageChange: TFb2PdfPageChangeEvent read FOnPageChange
      write FOnPageChange;
    property OnLoadError: TFb2PdfLoadErrorEvent read FOnLoadError
      write FOnLoadError;
    property OnLinkClick: TFb2PdfLinkClickEvent read FOnLinkClick
      write FOnLinkClick;
  end;

implementation

type
  { Указатели на подписчиков (тот же приём, что в fb2viewer.pas). }
  PNotifyEvent = ^TNotifyEvent;
  PFb2PdfPageChangeEvent = ^TFb2PdfPageChangeEvent;

const
  { Границы ZoomPercentage: TPdfPageViewControl принимает 1..1000 %. }
  PDF_MIN_ZOOM = 1;
  PDF_MAX_ZOOM = 1000;

{ ===================== Вспомогательные функции ===================== }

function ClampInt(Value: Int64): Integer;
begin
  if Value < 0 then
    Result := 0
  else if Value > MaxInt then
    Result := MaxInt
  else
    Result := Value;
end;

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

{ Числовое поле JSON; Default — поля нет, оно не число или строка не парсится. }
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

{ Текстовый файл в UTF-8 без BOM (сессия чтения). }
procedure SaveTextUtf8(const FileName: TFileName; const Text: UnicodeString);
var
  FS: TFileStream;
  Bytes: TBytes;
begin
  Bytes := TEncoding.UTF8.GetBytes(Text);
  FS := TFileStream.Create(FileName, fmCreate);
  try
    if Length(Bytes) > 0 then
      FS.WriteBuffer(Bytes[0], Length(Bytes));
  finally
    FS.Free;
  end;
end;

{ Прочитать текстовый файл UTF-8 (BOM, если есть, отбрасывается). False —
  файл недоступен. }
function LoadTextUtf8(const FileName: TFileName; out Text: UnicodeString): Boolean;
var
  FS: TFileStream;
  Bytes: TBytes;
  N, Start: Integer;
begin
  Result := False;
  Text := '';
  try
    FS := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
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
  Start := 0;
  if (Length(Bytes) >= 3) and (Bytes[0] = $EF) and (Bytes[1] = $BB) and
    (Bytes[2] = $BF) then
    Start := 3;
  Text := TEncoding.UTF8.GetString(Bytes, Start, Length(Bytes) - Start);
  Result := True;
end;

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

procedure PageChangeListAddListener(List: TList;
  const Handler: TFb2PdfPageChangeEvent);
var
  P: PFb2PdfPageChangeEvent;
begin
  if not Assigned(Handler) or (List = nil) then
    Exit;
  New(P);
  P^ := Handler;
  List.Add(P);
end;

procedure PageChangeListRemoveListener(List: TList;
  const Handler: TFb2PdfPageChangeEvent);
var
  I: Integer;
  P: PFb2PdfPageChangeEvent;
  H: TMethod;
begin
  if not Assigned(Handler) or (List = nil) then
    Exit;
  H := TMethod(Handler);
  for I := List.Count - 1 downto 0 do
  begin
    P := PFb2PdfPageChangeEvent(List[I]);
    if (TMethod(P^).Code = H.Code) and (TMethod(P^).Data = H.Data) then
    begin
      Dispose(P);
      List.Delete(I);
    end;
  end;
end;

procedure PageChangeListFire(List: TList; Sender: TObject;
  PageNumber, PageCount: Integer);
var
  I: Integer;
begin
  if List = nil then
    Exit;
  for I := 0 to List.Count - 1 do
    PFb2PdfPageChangeEvent(List[I])^(Sender, PageNumber, PageCount);
end;

procedure PageChangeListFree(List: TList);
var
  I: Integer;
begin
  if List = nil then
    Exit;
  for I := 0 to List.Count - 1 do
    Dispose(PFb2PdfPageChangeEvent(List[I]));
  List.Clear;
end;

{ ===================== Адаптер событий движка ===================== }

procedure TFb2PdfPageNotify.ChangePage(const aPageIndex: Integer);
begin
  if FView <> nil then
    FView.InternalPageChanged(aPageIndex);
end;

{ ===================== Создание и уничтожение ===================== }

constructor TFb2PdfView.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FLoadOption := dloDefault;
  FScaleMode := smFitAuto;
  FZoomPercentage := 100;
  FZoomStep := 10;
  FRotation := prNormal;
  FPageBackgroundColor := clWhite;
  FDrawOptions := [proAnnotations];
  FHighlightTextColor := clYellow;
  FAllowFormEvents := True;
  FOpenLinks := False;
  FPageIndex := 0;
  FDocumentSerial := 0;
  FShowOutline := False;
  FShowThumbnails := False;
  FSidebarWidth := 220;
  FSidebarPosition := spLeft;
  FDocLoadListeners := TList.Create;
  FPageChangeListeners := TList.Create;

  { PdfiumPascal рисует страницу через назначаемую процедуру-бэкенд, причём
    Paint вызывает её без проверки на nil. По умолчанию подставляем PdfiumLaz
    (LCL/IntfGraphics); приложение может заменить бэкенд на Graphics32/Image32
    до создания компонента. }
  if not Assigned(GraphicsBackend_DrawPageToCanvas) then
    GraphicsBackend_DrawPageToCanvas :=
      TPdfControlDrawPageToCanvasProcedure(@PdfiumLaz.DrawPageToCanvas);
  { Затемнение неактивных миниатюр (PdfiumPascal): без него лента миниатюр
    просто не приглушает соседние страницы. }
  if not Assigned(GraphicsBackend_DarkenProcedure) then
    GraphicsBackend_DarkenProcedure := @PdfiumLaz.DarkenBitmap;

  { Колонка-сайдбар создаётся до контрола движка. Сплиттер создаётся РАНЬШЕ
    панели: для alLeft LCL выравнивает соседей в обратном порядке создания,
    иначе сплиттер оказался бы слева от колонки (проверено). }
  CreateSidebar;

  { Вложенный контрол создаётся лениво: TPdfDocument.Create загружает pdfium.dll
    и падает, если библиотеки нет. Компонент должен ставиться на форму и в
    системе без движка, поэтому сбой здесь не фатален — причина запоминается, а
    контрол будет создан при первой загрузке (когда PdfiumDllFile уже задан). }
  EnsureViewer(FLastError);
end;

destructor TFb2PdfView.Destroy;
begin
  { Документ закрываем до уничтожения контрола: pdfium.dll может быть выгружен
    раньше, чем освободится TPdfPageViewControl. }
  if FViewer <> nil then
  begin
    try
      FViewer.Document.Close;
    except
      { документ и не открывался — закрывать нечего }
    end;
  end;
  ListFree(FDocLoadListeners);
  PageChangeListFree(FPageChangeListeners);
  FreeAndNil(FDocLoadListeners);
  FreeAndNil(FPageChangeListeners);
  FreeAndNil(FBookmarks);
  inherited Destroy;
end;

function TFb2PdfView.GetDocument: TPdfDocument;
begin
  if FViewer = nil then
    Result := nil
  else
    Result := FViewer.Document;
end;

{ Создание вложенного контрола движка. TPdfPageViewControl внутри создаёт
  TPdfDocument, а тот в конструкторе вызывает InitLib — загрузку pdfium.dll
  (SafeLoadLibrary). Без библиотеки конструктор бросает EOSError, поэтому
  исключение глушим и отдаём текст наружу: компонент обязан пережить отсутствие
  движка, иначе его нельзя поставить на форму в IDE. }
function TFb2PdfView.EnsureViewer(out AError: string): Boolean;
begin
  AError := '';
  if FViewer <> nil then
  begin
    Result := True;
    Exit;
  end;
  Result := False;
  try
    FViewer := TPdfPageViewControl.Create(Self);
    FViewer.Parent := Self;
    FViewer.Align := alClient;
    FViewer.OnWebLinkClick := @ViewerLinkClick;
    { Настройки, накопленные до создания контрола, применяем сразу. }
    FViewer.PageBackgroundColor := FPageBackgroundColor;
    FViewer.ScaleMode := FScaleMode;
    FViewer.ZoomPercentage := FZoomPercentage;
    FViewer.Rotation := FRotation;
    FViewer.DrawOptions := FDrawOptions;
    FViewer.HighLightTextColor := FHighlightTextColor;
    FViewer.AllowFormEvents := FAllowFormEvents;
    { Контрол уведомляет подписчиков о смене страницы, но собственного события
      не публикует — подписываемся и транслируем наружу. Экземпляр подписки
      освобождает сам контрол. }
    FNotifier := TFb2PdfPageNotify(FViewer.SubscribeToEvents(TFb2PdfPageNotify));
    FNotifier.View := Self;
    { Миниатюры привязываем к движку сразу: ViewControl назначается ровно один
      раз (повторная установка в PdfiumPascal освобождает подписку, оставляя
      её в списке прежнего контрола). }
    if FThumbnailsCtrl <> nil then
    begin
      FThumbnailsCtrl.ViewControl := FViewer;
      { Document присваиваем только когда в нём есть страницы: SetDocument в
        PdfiumPascal ставит ScrollBar.Max := PageCount при Min = 1 и падает
        («ScrollBar property out of range») на документе с нулём страниц.
        Пустой документ лента и так рисует пустой. }
      if FViewer.Document.PageCount > 0 then
        FThumbnailsCtrl.Document := FViewer.Document;
    end;
    Result := True;
  except
    on E: Exception do
    begin
      AError := E.Message;
      { Подсказка для самой частой причины: библиотеки движка нет ни в
        PdfiumDllFile, ни рядом с .exe. }
      if (FPdfiumDllFile = '') or not FileExists(UTF8ToSys(FPdfiumDllFile)) then
        AError := Format('%s (%s не найден: задайте PdfiumDllFile или положите '
          + 'файл рядом с исполняемым файлом)', [AError, FB2_PDF_LIB_NAME]);
      FNotifier := nil;
      FreeAndNil(FViewer);
    end;
  end;
end;

function TFb2PdfView.InitViewer: Boolean;
begin
  Result := EnsureViewer(FLastError);
  if Result then
    FLastError := '';
end;

{ ===================== Свойства ===================== }

procedure TFb2PdfView.SetFileName(const Value: TFileName);
begin
  if Value = FFileName then
    Exit;
  if Value = '' then
  begin
    Close;
    Exit;
  end;
  { В IDE файла может не быть (проект перенесли) — молча ждём загрузки. }
  FFileName := Value;
  if (csDesigning in ComponentState) and not FileExists(UTF8ToSys(Value)) then
    Exit;
  LoadFromFile(Value);
end;

procedure TFb2PdfView.SetPdfiumDllFile(const Value: TFileName);
begin
  { Движок грузится один раз на процесс, поэтому значение применяется при
    следующей загрузке документа (см. ApplyPdfiumDllFile). }
  FPdfiumDllFile := Value;
end;

procedure TFb2PdfView.SetScaleMode(const Value: TFb2PdfScaleMode);
begin
  if FScaleMode = Value then
    Exit;
  FScaleMode := Value;
  if FViewer <> nil then
    FViewer.ScaleMode := Value;
end;

procedure TFb2PdfView.SetZoomPercentage(const Value: Integer);
var
  Percent: Integer;
begin
  { Движок молча игнорирует значения вне 1..1000 — прижимаем сами, иначе наши
    поля разошлись бы с фактическим масштабом. }
  Percent := Value;
  if Percent < PDF_MIN_ZOOM then
    Percent := PDF_MIN_ZOOM;
  if Percent > PDF_MAX_ZOOM then
    Percent := PDF_MAX_ZOOM;
  if FZoomPercentage = Percent then
    Exit;
  FZoomPercentage := Percent;
  if FViewer <> nil then
    FViewer.ZoomPercentage := Percent;
end;

procedure TFb2PdfView.SetRotation(const Value: TFb2PdfRotation);
begin
  if FRotation = Value then
    Exit;
  FRotation := Value;
  if FViewer <> nil then
    FViewer.Rotation := Value;
end;

procedure TFb2PdfView.SetPageBackgroundColor(const Value: TColor);
begin
  if FPageBackgroundColor = Value then
    Exit;
  FPageBackgroundColor := Value;
  if FViewer <> nil then
    FViewer.PageBackgroundColor := Value;
end;

procedure TFb2PdfView.SetDrawOptions(const Value: TFb2PdfRenderOptions);
begin
  if FDrawOptions = Value then
    Exit;
  FDrawOptions := Value;
  if FViewer <> nil then
    FViewer.DrawOptions := Value;
end;

procedure TFb2PdfView.SetHighlightTextColor(const Value: TColor);
begin
  if FHighlightTextColor = Value then
    Exit;
  FHighlightTextColor := Value;
  if FViewer <> nil then
    FViewer.HighLightTextColor := Value;
end;

procedure TFb2PdfView.SetAllowFormEvents(const Value: Boolean);
begin
  if FAllowFormEvents = Value then
    Exit;
  FAllowFormEvents := Value;
  if FViewer <> nil then
    FViewer.AllowFormEvents := Value;
end;

{ ===================== Встроенный сайдбар ===================== }

{ Колонка с вкладками «Содержание» (дерево закладок PDF) и «Миниатюры»
  (TPdfThumbnailsControl из PdfiumPascal). Вкладки скрыты, пока не включены
  свойства ShowOutline/ShowThumbnails.

  Сторону задаёт ApplySidebarPosition: LCL сортирует выравниваемые контролы по
  их ТЕКУЩИМ координатам, поэтому одной установки Align недостаточно — перед
  выравниванием нужны ещё и корректные позиции. }
procedure TFb2PdfView.CreateSidebar;
begin
  FSplitter := TSplitter.Create(Self);
  FSplitter.Parent := Self;
  FSplitter.Align := alNone;
  FSplitter.MinSize := 120;
  FSplitter.Visible := False;

  FSidebar := TPanel.Create(Self);
  FSidebar.Parent := Self;
  FSidebar.Align := alNone;
  FSidebar.Width := FSidebarWidth;
  FSidebar.BevelOuter := bvNone;
  FSidebar.Visible := False;

  FSidebarPages := TPageControl.Create(Self);
  FSidebarPages.Parent := FSidebar;
  FSidebarPages.Align := alClient;

  FTabOutline := TTabSheet.Create(Self);
  FTabOutline.PageControl := FSidebarPages;
  FTabOutline.Caption := 'Содержание';
  FTabOutline.TabVisible := False;

  FTabThumbs := TTabSheet.Create(Self);
  FTabThumbs.PageControl := FSidebarPages;
  FTabThumbs.Caption := 'Миниатюры';
  FTabThumbs.TabVisible := False;

  FOutlineTree := TTreeView.Create(Self);
  FOutlineTree.Parent := FTabOutline;
  FOutlineTree.Align := alClient;
  FOutlineTree.ReadOnly := True;
  FOutlineTree.ShowButtons := True;
  FOutlineTree.ShowLines := False;
  FOutlineTree.HideSelection := False;
  FOutlineTree.OnChange := @OutlineTreeChange;

  FThumbnailsCtrl := TPdfThumbnailsControl.Create(Self);
  FThumbnailsCtrl.Parent := FTabThumbs;
  FThumbnailsCtrl.Align := alClient;
  FThumbnailsCtrl.Orientation := tcVertical;
  FThumbnailsCtrl.TextColor := clWindowText;

  ApplySidebarPosition;
end;

procedure TFb2PdfView.SetShowOutline(const Value: Boolean);
begin
  if FShowOutline = Value then
    Exit;
  FShowOutline := Value;
  UpdateSidebar;
  if Value and (FSidebarPages <> nil) then
    FSidebarPages.ActivePage := FTabOutline;
end;

procedure TFb2PdfView.SetShowThumbnails(const Value: Boolean);
begin
  if FShowThumbnails = Value then
    Exit;
  FShowThumbnails := Value;
  UpdateSidebar;
  if Value and (FSidebarPages <> nil) then
    FSidebarPages.ActivePage := FTabThumbs;
end;

procedure TFb2PdfView.SetSidebarWidth(const Value: Integer);
var
  W: Integer;
begin
  W := Value;
  if W < 120 then
    W := 120;
  if FSidebarWidth = W then
    Exit;
  FSidebarWidth := W;
  if FSidebar <> nil then
    FSidebar.Width := W;
end;

procedure TFb2PdfView.SetSidebarPosition(const Value: TFb2PdfSidebarPosition);
begin
  if FSidebarPosition = Value then
    Exit;
  FSidebarPosition := Value;
  ApplySidebarPosition;
end;

{ Разместить колонку и сплиттер с выбранной стороны.

  ВАЖНО (LCL): порядок выравнивания alLeft/alRight задаётся НЕ порядком
  создания, а текущими координатами контролов — CreateControlAlignList
  сортирует их через InsertBefore по Left (для alLeft) или Left+Width (для
  alRight). Поэтому перед установкой Align расставляем контролы так, чтобы
  первой в списке оказалась колонка: она занимает край, а сплиттер встаёт к ней
  вплотную. Без этого при переключении стороны «на лету» сплиттер уезжал на
  внешнюю сторону (проверено тестом). }
procedure TFb2PdfView.ApplySidebarPosition;
var
  W, H, SplitW, X: Integer;
begin
  if (FSidebar = nil) or (FSplitter = nil) then
    Exit;
  W := FSidebar.Width;
  if W <= 0 then
    W := FSidebarWidth;
  SplitW := FSplitter.Width;
  if SplitW <= 0 then
    SplitW := 5;
  H := ClientHeight;

  FSidebar.Align := alNone;
  FSplitter.Align := alNone;
  if FSidebarPosition = spRight then
  begin
    X := ClientWidth - W;
    if X < 0 then
      X := 0;
    FSidebar.SetBounds(X, 0, W, H);
    FSplitter.SetBounds(0, 0, SplitW, H);
    FSidebar.Align := alRight;
    FSplitter.Align := alRight;
  end
  else
  begin
    FSidebar.SetBounds(0, 0, W, H);
    X := ClientWidth - SplitW;
    if X < 0 then
      X := 0;
    FSplitter.SetBounds(X, 0, SplitW, H);
    FSidebar.Align := alLeft;
    FSplitter.Align := alLeft;
  end;
  Realign;
end;

{ Показать/спрятать колонку и её вкладки; активной делаем первую доступную. }
procedure TFb2PdfView.UpdateSidebar;
var
  NeedSidebar: Boolean;
begin
  if (FSidebar = nil) or (FSidebarPages = nil) then
    Exit;
  FTabOutline.TabVisible := FShowOutline;
  FTabThumbs.TabVisible := FShowThumbnails;
  NeedSidebar := FShowOutline or FShowThumbnails;
  FSidebar.Visible := NeedSidebar;
  FSplitter.Visible := NeedSidebar;
  { Позиции колонки и сплиттера выставляем заново: LCL учитывает при
    выравнивании текущие координаты (см. ApplySidebarPosition), а скрытые
    контролы в списке выравнивания не участвуют. }
  ApplySidebarPosition;
  if not NeedSidebar then
    Exit;
  if (FSidebarPages.ActivePage = nil) or
    (not FSidebarPages.ActivePage.TabVisible) then
  begin
    if FShowOutline then
      FSidebarPages.ActivePage := FTabOutline
    else
      FSidebarPages.ActivePage := FTabThumbs;
  end;
end;

{ Перестроить дерево закладок по текущему документу (пусто — закладок нет). }
procedure TFb2PdfView.RefreshOutline;
begin
  if FOutlineTree = nil then
    Exit;
  FreeAndNil(FBookmarks);
  FIgnoreOutlineChange := nil;
  FUpdatingOutline := True;
  try
    if IsLoaded then
      FBookmarks := CollectPdfBookmarks(Document);
    FillBookmarkTree(FOutlineTree, FBookmarks);
  finally
    FUpdatingOutline := False;
  end;
  if FOutlineTree.Items.Count > 0 then
  begin
    FOutlineTree.FullExpand;
    SyncOutlineSelection;
  end;
end;

{ Выделить раздел, в котором находится текущая страница. }
procedure TFb2PdfView.SyncOutlineSelection;
var
  Node: TTreeNode;
begin
  if (FOutlineTree = nil) or (FOutlineTree.Items.Count = 0) or
    (PageCount <= 0) then
    Exit;
  Node := FindBookmarkNode(FOutlineTree, FPageIndex);
  if (Node = nil) or (FOutlineTree.Selected = Node) then
    Exit;
  FUpdatingOutline := True;
  try
    FIgnoreOutlineChange := Node;   { отложенный OnChange этого узла игнорируем }
    Node.Selected := True;
    Node.MakeVisible;
  finally
    FUpdatingOutline := False;
  end;
end;

{ Пересобрать миниатюры под текущий документ (сброс кэша страниц). }
procedure TFb2PdfView.SyncThumbnails;
begin
  if (FThumbnailsCtrl = nil) or (FViewer = nil) then
    Exit;
  { Страниц нет (документ закрыт) — не трогаем: SetDocument на нуле страниц
    падает («ScrollBar property out of range»), а пустую ленту панель рисует
    сама по общему TPdfDocument с PageCount = 0.
    Повторная установка того же документа при загрузке пересобирает список
    страниц и сбрасывает кэш миниатюр. }
  if FViewer.Document.PageCount > 0 then
    FThumbnailsCtrl.Document := FViewer.Document;
end;

procedure TFb2PdfView.OutlineTreeChange(Sender: TObject; Node: TTreeNode);
begin
  if FUpdatingOutline then
    Exit;
  { Программное выделение раздела — не повод для перехода. }
  if Node = FIgnoreOutlineChange then
  begin
    FIgnoreOutlineChange := nil;
    Exit;
  end;
  FIgnoreOutlineChange := nil;
  ActivateOutlineNode(Node);
end;

procedure TFb2PdfView.ActivateOutlineNode(Node: TTreeNode);
var
  Bm: TFb2PdfBookmark;
begin
  if (Node = nil) or not (TObject(Node.Data) is TFb2PdfBookmark) then
    Exit;
  Bm := TFb2PdfBookmark(Node.Data);
  if Bm.Url <> '' then
  begin
    if FOpenLinks then
      LCLIntf.OpenURL(Bm.Url);
    Exit;
  end;
  if Bm.PageIndex >= 0 then
    GoToPage(Bm.PageIndex);
end;

{ ===================== Загрузка документа ===================== }

{ Передать путь к движку. pdfium грузится один раз на процесс: InitPDFiumEx
  игнорирует повторные вызовы, поэтому PdfiumDllFile действует только до
  первой загрузки документа. }
procedure TFb2PdfView.ApplyPdfiumDllFile;
begin
  if FPdfiumDllFile <> '' then
    PDFiumDllFileName := UTF8Decode(FPdfiumDllFile);
end;

{ Сбой открытия: документ закрыт, причина — в LastError и OnLoadError. }
procedure TFb2PdfView.FailLoad(const AFileName: TFileName;
  const AMessage: string);
begin
  FLastError := AMessage;
  Inc(FDocumentSerial);
  if FViewer <> nil then
    FViewer.Invalidate;
  if Assigned(FOnLoadError) then
    FOnLoadError(Self, AFileName, AMessage);
  NotifyDocumentLoad;
  NotifyPageChange;
end;

procedure TFb2PdfView.LoadFromFile(const AFileName: TFileName);
var
  ErrText: string;
begin
  if AFileName = '' then
  begin
    Close;
    Exit;
  end;

  FLastError := '';
  { Прежний документ закрываем сразу: если новая загрузка сорвётся, компонент
    не должен показывать старые страницы под новым именем. }
  if FViewer <> nil then
  begin
    try
      FViewer.Document.Close;
    except
      { закрывать нечего }
    end;
  end;
  FFileName := '';
  FPageIndex := 0;

  if not FileExists(UTF8ToSys(AFileName)) then
  begin
    FailLoad(AFileName, Format('Файл не найден: %s', [AFileName]));
    Exit;
  end;

  { Путь к движку применяем ДО создания вложенного контрола: pdfium грузится
    в конструкторе TPdfDocument и только один раз на процесс. }
  ApplyPdfiumDllFile;
  if not EnsureViewer(ErrText) then
  begin
    FailLoad(AFileName, ErrText);
    Exit;
  end;

  try
    { PdfiumLib ждёт ANSI-строки: имена файлов в LCL и так UTF-8, а пароль
      (UnicodeString) переводим в UTF-8 явно. }
    FViewer.LoadFromFile(AFileName, AnsiString(UTF8Encode(FPassword)),
      FLoadOption);
  except
    on E: Exception do
    begin
      { Самые частые причины: нет pdfium.dll (см. PdfiumDllFile) или файл
        защищён паролем/повреждён. }
      FailLoad(AFileName, E.Message);
      Exit;
    end;
  end;

  { Движок мог открыть контейнер, но не найти в нём страниц. }
  if FViewer.Document.PageCount <= 0 then
  begin
    try
      FViewer.Document.Close;
    except
      { уже закрыт }
    end;
    FailLoad(AFileName, 'Документ не содержит страниц (повреждённый PDF?)');
    Exit;
  end;

  FFileName := AFileName;
  FPageIndex := 0;
  Inc(FDocumentSerial);
  NotifyDocumentLoad;
  NotifyPageChange;
end;

procedure TFb2PdfView.Reload;
begin
  if FFileName <> '' then
    LoadFromFile(FFileName);
end;

procedure TFb2PdfView.Close;
begin
  if FViewer <> nil then
  begin
    try
      FViewer.Document.Close;
    except
      { закрывать нечего }
    end;
  end;
  FFileName := '';
  FPageIndex := 0;
  FLastError := '';
  Inc(FDocumentSerial);
  if FViewer <> nil then
    FViewer.Invalidate;
  NotifyDocumentLoad;
  NotifyPageChange;
end;

function TFb2PdfView.IsLoaded: Boolean;
begin
  Result := (FViewer <> nil) and FViewer.Document.Active and
    (FViewer.Document.PageCount > 0);
end;

{ ===================== Страницы ===================== }

function TFb2PdfView.PageCount: Integer;
begin
  if IsLoaded then
    Result := FViewer.Document.PageCount
  else
    Result := 0;
end;

function TFb2PdfView.PageNumber: Integer;
begin
  if PageCount <= 0 then
    Result := 0
  else
    Result := FPageIndex + 1;
end;

function TFb2PdfView.GoToPage(APageIndex: Integer): Boolean;
var
  LastIndex: Integer;
begin
  Result := False;
  LastIndex := PageCount - 1;
  if LastIndex < 0 then
    Exit;
  if APageIndex < 0 then
    APageIndex := 0;
  if APageIndex > LastIndex then
    APageIndex := LastIndex;
  if APageIndex = FPageIndex then
  begin
    { Страница уже открыта. GotoPage в этом случае вернул бы False, но для
      вызывающего это успех: нужная страница на экране. }
    Result := True;
    Exit;
  end;
  { Индекс страницы и события обновит адаптер (ChangePage) внутри GotoPage. }
  Result := FViewer.GotoPage(APageIndex);
end;

function TFb2PdfView.GoToPageNumber(APageNumber: Integer): Boolean;
begin
  if PageCount <= 0 then
    Result := False
  else
    Result := GoToPage(APageNumber - 1);
end;

function TFb2PdfView.FirstPage: Boolean;
begin
  Result := GoToPage(0);
end;

function TFb2PdfView.LastPage: Boolean;
begin
  Result := GoToPage(PageCount - 1);
end;

function TFb2PdfView.CanGoNext: Boolean;
begin
  Result := (PageCount > 0) and (FPageIndex < PageCount - 1);
end;

function TFb2PdfView.CanGoPrev: Boolean;
begin
  Result := (PageCount > 0) and (FPageIndex > 0);
end;

function TFb2PdfView.NextPage: Boolean;
begin
  Result := CanGoNext and GoToPage(FPageIndex + 1);
end;

function TFb2PdfView.PrevPage: Boolean;
begin
  Result := CanGoPrev and GoToPage(FPageIndex - 1);
end;

{ ===================== Масштаб и поворот ===================== }

procedure TFb2PdfView.SetZoom(APercentage: Integer);
begin
  { Процент выставляем до переключения режима: SetZoomPercentage сам прижмёт
    значение к 1..1000, а ScaleMode = smZoom применит его при раскладке. }
  SetZoomPercentage(APercentage);
  SetScaleMode(smZoom);
end;

procedure TFb2PdfView.ZoomIn;
var
  Step: Integer;
begin
  Step := FZoomStep;
  if Step < 1 then
    Step := 1;
  SetZoom(FZoomPercentage + Step);
end;

procedure TFb2PdfView.ZoomOut;
var
  Step: Integer;
begin
  Step := FZoomStep;
  if Step < 1 then
    Step := 1;
  SetZoom(FZoomPercentage - Step);
end;

procedure TFb2PdfView.ZoomReset;
begin
  { «Сброс» — страница целиком: самый предсказуемый вид для читалки. }
  SetScaleMode(smFitAuto);
end;

procedure TFb2PdfView.RotateLeft;
begin
  case FRotation of
    prNormal: SetRotation(pr90CounterClockwide);
    pr90Clockwise: SetRotation(prNormal);
    pr180: SetRotation(pr90Clockwise);
    pr90CounterClockwide: SetRotation(pr180);
  end;
end;

procedure TFb2PdfView.RotateRight;
begin
  case FRotation of
    prNormal: SetRotation(pr90Clockwise);
    pr90Clockwise: SetRotation(pr180);
    pr180: SetRotation(pr90CounterClockwide);
    pr90CounterClockwide: SetRotation(prNormal);
  end;
end;

procedure TFb2PdfView.RotateReset;
begin
  SetRotation(prNormal);
end;

{ ===================== Поиск ===================== }

function TFb2PdfView.FindText(const S: UnicodeString; MatchCase: Boolean;
  MatchWholeWord: Boolean): Boolean;
begin
  Result := False;
  if not IsLoaded then
    Exit;
  if S = '' then
  begin
    ClearSearch;
    Exit;
  end;
  { HightlightText ищет только по текущей странице — так устроен
    TPdfPageViewControl; подсветка снимается ClearSearch/сменой страницы.
    Строка поиска переводится в UTF-8 (движок работает с ANSI-строками). }
  FViewer.HightlightText(AnsiString(UTF8Encode(S)), MatchCase, MatchWholeWord);
  Result := True;
end;

procedure TFb2PdfView.ClearSearch;
begin
  if FViewer <> nil then
    FViewer.HightlightText('', False, False);
end;

{ ===================== События и подписки ===================== }

procedure TFb2PdfView.NotifyDocumentLoad;
begin
  if Assigned(FOnDocumentLoad) then
    FOnDocumentLoad(Self);
  ListFire(FDocLoadListeners, Self);
  { Документ сменился (или закрыт) — обновляем встроенные панели. }
  RefreshOutline;
  SyncThumbnails;
end;

procedure TFb2PdfView.NotifyPageChange;
var
  N, C: Integer;
begin
  N := PageNumber;
  C := PageCount;
  if Assigned(FOnPageChange) then
    FOnPageChange(Self, N, C);
  PageChangeListFire(FPageChangeListeners, Self, N, C);
end;

procedure TFb2PdfView.InternalPageChanged(const APageIndex: Integer);
begin
  FPageIndex := APageIndex;
  NotifyPageChange;
  { Подсветить раздел, в котором оказалась страница. }
  SyncOutlineSelection;
end;

procedure TFb2PdfView.ViewerLinkClick(Sender: TObject; Url: string);
begin
  { URL из движка — UTF-8 (ANSI-строка PdfiumPascal), наружу отдаём
    UnicodeString, как принято в остальных событиях пакета. }
  if Assigned(FOnLinkClick) then
    FOnLinkClick(Self, UTF8Decode(Url));
  if FOpenLinks and (Url <> '') then
    LCLIntf.OpenURL(Url);
end;

procedure TFb2PdfView.AddDocumentLoadListener(const Handler: TNotifyEvent);
begin
  ListAddListener(FDocLoadListeners, Handler);
end;

procedure TFb2PdfView.RemoveDocumentLoadListener(const Handler: TNotifyEvent);
begin
  ListRemoveListener(FDocLoadListeners, Handler);
end;

procedure TFb2PdfView.AddPageChangeListener(const Handler: TFb2PdfPageChangeEvent);
begin
  PageChangeListAddListener(FPageChangeListeners, Handler);
end;

procedure TFb2PdfView.RemovePageChangeListener(
  const Handler: TFb2PdfPageChangeEvent);
begin
  PageChangeListRemoveListener(FPageChangeListeners, Handler);
end;

{ ===================== Сессия чтения (JSON) ===================== }

function TFb2PdfView.SessionToJson: UnicodeString;
var
  Obj: TJSONObject;
begin
  Obj := TJSONObject.Create;
  try
    Obj.Add('version', PDF_SESSION_JSON_VERSION);
    Obj.Add('file', TJSONStringType(UTF8Decode(FFileName)));
    Obj.Add('page', Int64(FPageIndex));
    Obj.Add('scale_mode', Ord(FScaleMode));
    Obj.Add('zoom', Int64(FZoomPercentage));
    Obj.Add('rotation', Ord(FRotation));
    Result := UTF8Decode(Obj.FormatJSON(DefaultFormat, 2));
  finally
    Obj.Free;
  end;
end;

procedure TFb2PdfView.ApplySession(const AJson: UnicodeString);
var
  Data: TJSONData;
  Obj: TJSONObject;
  SessionFileName: TFileName;
  Value: Int64;
begin
  Data := GetJSON(UTF8Encode(AJson), True);
  try
    if (Data = nil) or (Data.JSONType <> jtObject) then
      raise Exception.Create('Некорректный JSON сессии: ожидается объект');
    Obj := TJSONObject(Data);

    SessionFileName := TFileName(UTF8Encode(JsonStr(Obj, 'file')));
    if (SessionFileName <> '') and (SessionFileName <> FFileName) then
      LoadFromFile(SessionFileName);

    Value := JsonInt(Obj, 'rotation', Ord(FRotation));
    if (Value >= Ord(Low(TFb2PdfRotation))) and
      (Value <= Ord(High(TFb2PdfRotation))) then
      SetRotation(TFb2PdfRotation(Value));

    Value := JsonInt(Obj, 'scale_mode', Ord(FScaleMode));
    if (Value >= Ord(Low(TFb2PdfScaleMode))) and
      (Value <= Ord(High(TFb2PdfScaleMode))) then
      SetScaleMode(TFb2PdfScaleMode(Value));

    SetZoomPercentage(ClampInt(JsonInt(Obj, 'zoom', FZoomPercentage)));

    GoToPage(ClampInt(JsonInt(Obj, 'page', FPageIndex)));
  finally
    Data.Free;
  end;
end;

procedure TFb2PdfView.SaveSessionToFile(const AFileName: TFileName);
begin
  SaveTextUtf8(AFileName, SessionToJson);
end;

procedure TFb2PdfView.LoadSessionFromFile(const AFileName: TFileName);
var
  Json: UnicodeString;
begin
  if not LoadTextUtf8(AFileName, Json) then
    raise Exception.Create(Format('Не удалось прочитать файл сессии: %s',
      [AFileName]));
  ApplySession(Json);
end;

end.
