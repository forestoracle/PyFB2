unit fb2viewertoolbar;
{ Панель читалки FB2: навигация по истории, размер шрифта, поиск, копирование
  и печать — тонкая обёртка над возможностями THtmlViewer внутри TFb2Viewer.

  Компонент не требует никаких дополнительных портов библиотеки: всё, что он
  делает, уже умеет движок HtmlViewer, просто раньше это не было подключено к
  TFb2Viewer.

  Что даёт:
    * Назад / Вперёд — история переходов (THtmlViewer.HistoryIndex), кнопки
      включаются/выключаются сами (OnHistoryChange движка);
    * В начало — прокрутка к началу документа (Position := 0);
    * A- / A+ / A — размер шрифта (DefFontSize + Font.Size) с перерисовкой
      документа (TFb2Viewer.ReRender) и восстановлением позиции чтения;
    * Поиск — TFindDialog + THtmlViewer.FindEx (вперёд/назад, регистр);
    * Копировать / Выделить всё — буфер обмена;
    * Печать — TPrintDialog + TvwPrinter (диалог принтера и страниц);
    * Предпросмотр — рендеринг страниц в TMetaFilePrinter (окно предпросмотра
      предоставляет приложение, см. PrintPreview).

  Пример:
      V := TFb2Viewer.Create(Self);
      V.Parent := MainPanel;  V.Align := alClient;
      T := TFb2ViewerToolbar.Create(Self);
      T.Parent := Self;       T.Align := alTop;
      T.Viewer := V;
      V.FileName := 'book.fb2';   ( кнопки станут активными сами )

  Требует LCL, пакета HtmlViewer (FrameViewer09) и printer4lazarus.
  GUI-модуль: не входит в библиотечные .pas и собирается в составе пакета
  fb2viewer.lpk. }

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Classes, SysUtils, Controls, ComCtrls, Dialogs, PrintersDlgs,
  MetaFilePrinter,
  fb2viewer;

type
  { Команды панели читалки. Кнопки создаются по набору Commands. }
  TFb2ToolbarCommand = (
    tcBack,        { назад по истории }
    tcForward,     { вперёд по истории }
    tcTop,         { в начало документа }
    tcFontDown,    { меньше шрифт }
    tcFontUp,      { больше шрифт }
    tcFontReset,   { исходный размер шрифта }
    tcFind,        { найти (диалог) }
    tcFindNext,    { найти далее }
    tcCopy,        { копировать выделенное }
    tcPrint        { печать }
  );
  TFb2ToolbarCommands = set of TFb2ToolbarCommand;

const
  { Набор команд по умолчанию — все кнопки. }
  FB2_TOOLBAR_ALL = [tcBack, tcForward, tcTop, tcFontDown, tcFontUp,
    tcFontReset, tcFind, tcFindNext, tcCopy, tcPrint];

type
  { Панель читалки, связанная с TFb2Viewer. }
  TFb2ViewerToolbar = class(TToolBar)
  private
    FViewer: TFb2Viewer;
    FButtons: array[TFb2ToolbarCommand] of TToolButton;
    FFindDialog: TFindDialog;
    FPrintDialog: TPrintDialog;
    FCommands: TFb2ToolbarCommands;
    FFontSize: Integer;
    FBaseFontSize: Integer;
    FMinFontSize: Integer;
    FMaxFontSize: Integer;
    FFontStep: Integer;
    FSearchText: UnicodeString;
    FSearchMatchCase: Boolean;
    FSearchReverse: Boolean;
    FOnStateChange: TNotifyEvent;
    FUpdating: Boolean;

    procedure SetViewer(const Value: TFb2Viewer);
    procedure SetCommands(const Value: TFb2ToolbarCommands);
    procedure SetFontSize(const Value: Integer);
    procedure SetSearchText(const Value: UnicodeString);
    procedure ViewerDocumentLoad(Sender: TObject);
    procedure ViewerHistoryChange(Sender: TObject);
    procedure ButtonClick(Sender: TObject);
    procedure DoFind(Sender: TObject);
    procedure AddCommand(const Cmd: TFb2ToolbarCommand;
      const ACaption, AHint: string; Divider: Boolean = False);
    procedure EnableCmd(const Cmd: TFb2ToolbarCommand; Value: Boolean);
    procedure ApplyFontSize;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    { Пересоздать кнопки по набору Commands. }
    procedure Rebuild;
    { Обновить доступность кнопок (история, наличие документа). }
    procedure UpdateState;

    { --- навигация --- }
    procedure GoBack;
    procedure GoForward;
    procedure GoToTop;
    function CanGoBack: Boolean;
    function CanGoForward: Boolean;

    { --- размер шрифта --- }
    procedure ZoomIn;
    procedure ZoomOut;
    procedure ZoomReset;

    { --- поиск --- }
    function FindText(const S: UnicodeString; MatchCase: Boolean = False;
      Reverse: Boolean = False): Boolean;
    function FindNext: Boolean;
    function FindPrev: Boolean;
    procedure ShowFindDialog;

    { --- буфер обмена --- }
    procedure CopySelection;
    procedure SelectAllText;

    { --- печать --- }
    procedure PrintDocument;
    { Отрисовать страницы в подготовленный TMetaFilePrinter и вернуть их число.
      Показ окна предпросмотра — задача приложения (в HtmlViewer он реализован
      отдельной формой). }
    function PrintPreview(Prn: TMetaFilePrinter; FromPage: Integer = 1;
      ToPage: Integer = MaxInt): Integer;

    property FindDialog: TFindDialog read FFindDialog;
    property PrintDialog: TPrintDialog read FPrintDialog;
  published
    { Связанный просмотрщик: панель сама подписывается на загрузку документа
      и на изменение истории переходов. }
    property Viewer: TFb2Viewer read FViewer write SetViewer;
    { Набор кнопок панели. }
    property Commands: TFb2ToolbarCommands read FCommands write SetCommands
      default FB2_TOOLBAR_ALL;
    { Текущий размер шрифта читалки (в пунктах); 0 — взять из просмотрщика. }
    property FontSize: Integer read FFontSize write SetFontSize default 0;
    property MinFontSize: Integer read FMinFontSize write FMinFontSize default 6;
    property MaxFontSize: Integer read FMaxFontSize write FMaxFontSize default 72;
    property FontStep: Integer read FFontStep write FFontStep default 1;
    { Строка последнего поиска. }
    property SearchText: UnicodeString read FSearchText write SetSearchText;
    { Событие: изменилось состояние панели (история, шрифт, наличие книги). }
    property OnStateChange: TNotifyEvent read FOnStateChange write FOnStateChange;
  end;

implementation

uses
  Graphics, Forms, LCLType, HtmlGlobals, HtmlView, vwPrint;

{ ===================== Создание и настройка ===================== }

constructor TFb2ViewerToolbar.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Align := alTop;
  AutoSize := True;
  Flat := True;
  ShowCaptions := True;
  Wrapable := False;
  FCommands := FB2_TOOLBAR_ALL;
  FMinFontSize := 6;
  FMaxFontSize := 72;
  FFontStep := 1;
  FFontSize := 0;
  FBaseFontSize := 0;

  FFindDialog := TFindDialog.Create(Self);
  FFindDialog.OnFind := @DoFind;
  FPrintDialog := TPrintDialog.Create(Self);

  Rebuild;
  UpdateState;
end;

destructor TFb2ViewerToolbar.Destroy;
begin
  SetViewer(nil);          { отписаться от событий просмотрщика }
  inherited Destroy;
end;

procedure TFb2ViewerToolbar.SetViewer(const Value: TFb2Viewer);
begin
  if FViewer = Value then
    Exit;
  if FViewer <> nil then
  begin
    FViewer.RemoveDocumentLoadListener(@ViewerDocumentLoad);
    FViewer.Viewer.OnHistoryChange := nil;
  end;
  FViewer := Value;
  if FViewer <> nil then
  begin
    FViewer.AddDocumentLoadListener(@ViewerDocumentLoad);
    FViewer.Viewer.OnHistoryChange := @ViewerHistoryChange;
    FBaseFontSize := FViewer.Viewer.DefFontSize;
    if FBaseFontSize <= 0 then
      FBaseFontSize := 12;
    if FFontSize <= 0 then
      FFontSize := FBaseFontSize;
  end;
  UpdateState;
end;

procedure TFb2ViewerToolbar.SetCommands(const Value: TFb2ToolbarCommands);
begin
  if FCommands = Value then
    Exit;
  FCommands := Value;
  Rebuild;
  UpdateState;
end;

procedure TFb2ViewerToolbar.SetFontSize(const Value: Integer);
var
  V: Integer;
begin
  V := Value;
  if V < FMinFontSize then
    V := FMinFontSize;
  if V > FMaxFontSize then
    V := FMaxFontSize;
  if V = FFontSize then
    Exit;
  FFontSize := V;
  ApplyFontSize;
  UpdateState;
end;

procedure TFb2ViewerToolbar.SetSearchText(const Value: UnicodeString);
begin
  FSearchText := Value;
  if (FFindDialog <> nil) and (Value <> '') then
    FFindDialog.FindText := UTF8Encode(Value);
  UpdateState;
end;

procedure TFb2ViewerToolbar.ViewerDocumentLoad(Sender: TObject);
begin
  UpdateState;
end;

procedure TFb2ViewerToolbar.ViewerHistoryChange(Sender: TObject);
begin
  UpdateState;
end;

{ ===================== Кнопки ===================== }

procedure TFb2ViewerToolbar.AddCommand(const Cmd: TFb2ToolbarCommand;
  const ACaption, AHint: string; Divider: Boolean);
var
  B: TToolButton;
begin
  if not (Cmd in FCommands) then
    Exit;
  if Divider then
  begin
    B := TToolButton.Create(Self);
    B.Parent := Self;
    B.Style := tbsDivider;
  end;
  B := TToolButton.Create(Self);
  B.Parent := Self;
  B.Style := tbsButton;
  B.AutoSize := True;
  B.Caption := ACaption;
  B.Hint := AHint;
  B.ShowHint := True;
  B.Tag := Ord(Cmd);
  B.OnClick := @ButtonClick;
  FButtons[Cmd] := B;
end;

procedure TFb2ViewerToolbar.EnableCmd(const Cmd: TFb2ToolbarCommand;
  Value: Boolean);
begin
  if FButtons[Cmd] <> nil then
    FButtons[Cmd].Enabled := Value;
end;

procedure TFb2ViewerToolbar.Rebuild;
var
  I: Integer;
  Cmd: TFb2ToolbarCommand;
begin
  for I := ButtonCount - 1 downto 0 do
    Buttons[I].Free;
  for Cmd := Low(TFb2ToolbarCommand) to High(TFb2ToolbarCommand) do
    FButtons[Cmd] := nil;

  AddCommand(tcBack, '◀', 'Назад по истории');
  AddCommand(tcForward, '▶', 'Вперёд по истории');
  AddCommand(tcTop, '⌂', 'В начало документа', True);
  AddCommand(tcFontDown, 'A−', 'Уменьшить шрифт');
  AddCommand(tcFontUp, 'A+', 'Увеличить шрифт');
  AddCommand(tcFontReset, 'A', 'Исходный размер шрифта', True);
  AddCommand(tcFind, 'Найти', 'Поиск по тексту книги');
  AddCommand(tcFindNext, 'Далее', 'Найти следующее совпадение');
  AddCommand(tcCopy, 'Копировать', 'Копировать выделенное', True);
  AddCommand(tcPrint, 'Печать', 'Печать книги');
end;

procedure TFb2ViewerToolbar.UpdateState;
var
  HasDoc: Boolean;
begin
  if FUpdating then
    Exit;
  FUpdating := True;
  try
    HasDoc := (FViewer <> nil) and (FViewer.Converter <> nil);
    EnableCmd(tcBack, HasDoc and CanGoBack);
    EnableCmd(tcForward, HasDoc and CanGoForward);
    EnableCmd(tcTop, HasDoc);
    EnableCmd(tcFontDown, HasDoc and (FFontSize > FMinFontSize));
    EnableCmd(tcFontUp, HasDoc and (FFontSize < FMaxFontSize));
    EnableCmd(tcFontReset, HasDoc and (FFontSize <> FBaseFontSize));
    EnableCmd(tcFind, HasDoc);
    EnableCmd(tcFindNext, HasDoc and (FSearchText <> ''));
    EnableCmd(tcCopy, HasDoc);
    EnableCmd(tcPrint, HasDoc);
  finally
    FUpdating := False;
  end;
  if Assigned(FOnStateChange) then
    FOnStateChange(Self);
end;

procedure TFb2ViewerToolbar.ApplyFontSize;
var
  SavePos: Integer;
begin
  if (FViewer = nil) or (FFontSize <= 0) then
    Exit;
  SavePos := FViewer.Viewer.Position;      { запомнить позицию чтения }
  FViewer.Viewer.ParentFont := False;
  FViewer.Viewer.DefFontSize := FFontSize;
  FViewer.Viewer.Font.Size := FFontSize;
  FViewer.ReRender;                        { перерисовать с новым шрифтом }
  FViewer.Viewer.Position := SavePos;
end;

{ ===================== Навигация ===================== }

function TFb2ViewerToolbar.CanGoBack: Boolean;
begin
  Result := (FViewer <> nil) and (FViewer.Viewer.HistoryIndex > 0);
end;

function TFb2ViewerToolbar.CanGoForward: Boolean;
begin
  Result := (FViewer <> nil) and
    (FViewer.Viewer.HistoryIndex < FViewer.Viewer.History.Count - 1);
end;

procedure TFb2ViewerToolbar.GoBack;
begin
  if not CanGoBack then
    Exit;
  FViewer.Viewer.HistoryIndex := FViewer.Viewer.HistoryIndex - 1;
  UpdateState;
end;

procedure TFb2ViewerToolbar.GoForward;
begin
  if not CanGoForward then
    Exit;
  FViewer.Viewer.HistoryIndex := FViewer.Viewer.HistoryIndex + 1;
  UpdateState;
end;

procedure TFb2ViewerToolbar.GoToTop;
begin
  if FViewer = nil then
    Exit;
  FViewer.Viewer.Position := 0;
end;

{ ===================== Размер шрифта ===================== }

procedure TFb2ViewerToolbar.ZoomIn;
begin
  SetFontSize(FFontSize + FFontStep);
end;

procedure TFb2ViewerToolbar.ZoomOut;
begin
  SetFontSize(FFontSize - FFontStep);
end;

procedure TFb2ViewerToolbar.ZoomReset;
begin
  SetFontSize(FBaseFontSize);
end;

{ ===================== Поиск ===================== }

function TFb2ViewerToolbar.FindText(const S: UnicodeString;
  MatchCase: Boolean; Reverse: Boolean): Boolean;
begin
  Result := False;
  if (FViewer = nil) or (S = '') then
    Exit;
  if S <> FSearchText then
  begin
    { Новый запрос — начинаем с начала документа. }
    FSearchText := S;
    FViewer.Viewer.CaretPos := 0;
  end;
  FSearchMatchCase := MatchCase;
  FSearchReverse := Reverse;
  Result := FViewer.Viewer.FindEx(S, MatchCase, Reverse);
  UpdateState;
end;

function TFb2ViewerToolbar.FindNext: Boolean;
begin
  Result := FindText(FSearchText, FSearchMatchCase, False);
end;

function TFb2ViewerToolbar.FindPrev: Boolean;
begin
  Result := FindText(FSearchText, FSearchMatchCase, True);
end;

procedure TFb2ViewerToolbar.ShowFindDialog;
begin
  if FFindDialog = nil then
    Exit;
  if FSearchText <> '' then
    FFindDialog.FindText := UTF8Encode(FSearchText);
  FFindDialog.Execute;
end;

procedure TFb2ViewerToolbar.DoFind(Sender: TObject);
begin
  if not FindText(UTF8ToString(FFindDialog.FindText),
    frMatchCase in FFindDialog.Options,
    not (frDown in FFindDialog.Options)) then
    MessageDlg(UTF8Encode('Не найдено: ' + FSearchText),
      mtInformation, [mbOK], 0);
end;

{ ===================== Буфер обмена ===================== }

procedure TFb2ViewerToolbar.CopySelection;
begin
  if FViewer <> nil then
    FViewer.Viewer.CopyToClipboard;
end;

procedure TFb2ViewerToolbar.SelectAllText;
begin
  if FViewer <> nil then
    FViewer.Viewer.SelectAll;
end;

{ ===================== Печать ===================== }

procedure TFb2ViewerToolbar.PrintDocument;
var
  Prn: TvwPrinter;
  FromPg, ToPg: Integer;
begin
  if (FViewer = nil) or (FPrintDialog = nil) then
    Exit;
  if not FPrintDialog.Execute then
    Exit;
  FromPg := 1;
  ToPg := MaxInt;
  if FPrintDialog.PrintRange = prPageNums then
  begin
    FromPg := FPrintDialog.FromPage;
    ToPg := FPrintDialog.ToPage;
  end;
  Prn := TvwPrinter.Create(Self);
  try
    FViewer.Viewer.Print(Prn, FromPg, ToPg, ppSinglePrint);
  finally
    Prn.Free;
  end;
end;

function TFb2ViewerToolbar.PrintPreview(Prn: TMetaFilePrinter;
  FromPage, ToPage: Integer): Integer;
begin
  Result := 0;
  if (FViewer = nil) or (Prn = nil) then
    Exit;
  Result := FViewer.Viewer.PrintPreview(Prn, False, FromPage, ToPage);
end;

{ ===================== Обработчик кнопок ===================== }

procedure TFb2ViewerToolbar.ButtonClick(Sender: TObject);
var
  Cmd: TFb2ToolbarCommand;
begin
  if not (Sender is TToolButton) then
    Exit;
  Cmd := TFb2ToolbarCommand(TToolButton(Sender).Tag);
  case Cmd of
    tcBack: GoBack;
    tcForward: GoForward;
    tcTop: GoToTop;
    tcFontDown: ZoomOut;
    tcFontUp: ZoomIn;
    tcFontReset: ZoomReset;
    tcFind: ShowFindDialog;
    tcFindNext:
      begin
        if (FSearchText <> '') and not FindNext and not FindPrev then
          MessageDlg('Не найдено: ' + FSearchText, mtInformation, [mbOK], 0);
      end;
    tcCopy: CopySelection;
    tcPrint: PrintDocument;
  end;
end;

end.
