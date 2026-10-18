unit fb2statusbar;
{ Статус-бар читалки: книга, текущая глава, номер главы и полоса прогресса.

  Подключается к TFb2Viewer так же, как дерево заголовков: подписывается на
  загрузку документа и на изменение прокрутки, поэтому значения обновляются и
  при ручном чтении, и при переходе по внутренним ссылкам.

  Панели (слева направо): книга («Название — Автор»), текущая глава,
  «глава N из M», полоса прогресса. Во время загрузки книги полоса показывает
  прогресс загрузки (0..100 %), после — прогресс чтения. Любую панель можно
  выключить свойствами ShowBook/ShowChapter/ShowCounter/ShowProgress.

  Пример:
      S := TFb2StatusBar.Create(Self);
      S.Parent := Self;   S.Align := alBottom;
      S.Viewer := V;
      V.FileName := 'book.fb2';

  Требует fb2viewer.pas (пакет HtmlViewer 11) и LCL. GUI-модуль. }

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Classes, SysUtils, Graphics, Types, ComCtrls, Controls,
  fb2_structures, fb2_html, fb2viewer;

type
  { Статус-бар, привязанный к TFb2Viewer. }
  TFb2StatusBar = class(TStatusBar)
  private
    FViewer: TFb2Viewer;
    FUpdating: Boolean;
    FTrackMargin: Integer;
    FShowBook: Boolean;
    FShowChapter: Boolean;
    FShowCounter: Boolean;
    FShowProgress: Boolean;
    FLoading: Boolean;          { идёт загрузка книги — панель показывает её прогресс }
    FLoadPercent: Integer;

    procedure SetViewer(const Value: TFb2Viewer);
    procedure SetShowBook(const Value: Boolean);
    procedure SetShowChapter(const Value: Boolean);
    procedure SetShowCounter(const Value: Boolean);
    procedure SetShowProgress(const Value: Boolean);
    procedure ViewerDocumentLoad(Sender: TObject);
    procedure ViewerScroll(Sender: TObject);
    procedure ViewerLoadProgress(Sender: TObject; Stage: TFb2LoadStage;
      Percent: Integer);
    procedure LayoutPanels;
    procedure SetPanel(Index: Integer; const AText: UnicodeString);
    procedure DrawProgressBar(const Rect: TRect);
    procedure InvalidateProgress;
    function ReadingProgressPercent: Integer;
    function ProgressPercent: Integer;
    function BookCaption(Desc: TDescription): UnicodeString;
    function ChapterCaption(Conv: TFb2ToHtmlConverter; Idx: Integer): UnicodeString;
    function ProgressCaption: UnicodeString;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    { Обновить содержимое панелей. }
    procedure Refresh;
    { Идёт загрузка книги (в панели прогресса — индикатор загрузки). }
    property Loading: Boolean read FLoading;
  protected
    procedure Resize; override;
    { Полоса прогресса в последней панели (psOwnerDraw). }
    procedure DrawPanel(Panel: TStatusPanel; const Rect: TRect); override;
  published
    { Связанный просмотрщик: панели обновляются при загрузке книги и при
      изменении позиции чтения. }
    property Viewer: TFb2Viewer read FViewer write SetViewer;
    { Отступ от верхнего края области чтения (пиксели) при определении текущей
      главы — тот же смысл, что у TFb2Outline.TrackMargin. }
    property TrackMargin: Integer read FTrackMargin write FTrackMargin default 16;
    property ShowBook: Boolean read FShowBook write SetShowBook default True;
    property ShowChapter: Boolean read FShowChapter write SetShowChapter default True;
    property ShowCounter: Boolean read FShowCounter write SetShowCounter default True;
    property ShowProgress: Boolean read FShowProgress write SetShowProgress default True;
  end;

implementation

{ Человекочитаемое имя автора (как в остальных модулях библиотеки). }
function AuthorText(A: TAuthor): UnicodeString;
var
  Parts: TTextList;
begin
  Result := '';
  if A = nil then
    Exit;
  Parts := TTextList.Create;
  try
    if A.FirstName <> '' then
      Parts.Add(A.FirstName);
    if A.MiddleName <> '' then
      Parts.Add(A.MiddleName);
    if A.LastName <> '' then
      Parts.Add(A.LastName);
    Result := JoinText(Parts, ' ');
  finally
    Parts.Free;
  end;
  if Result = '' then
    Result := A.Nickname;
end;

constructor TFb2StatusBar.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  SimplePanel := False;
  FTrackMargin := 16;
  FShowBook := True;
  FShowChapter := True;
  FShowCounter := True;
  FShowProgress := True;
  FLoading := False;
  FLoadPercent := 0;
  LayoutPanels;
  Refresh;
end;

destructor TFb2StatusBar.Destroy;
begin
  SetViewer(nil);
  inherited Destroy;
end;

procedure TFb2StatusBar.SetViewer(const Value: TFb2Viewer);
begin
  if FViewer = Value then
    Exit;
  if FViewer <> nil then
  begin
    FViewer.RemoveDocumentLoadListener(@ViewerDocumentLoad);
    FViewer.RemoveLoadProgressListener(@ViewerLoadProgress);
    FViewer.RemoveScrollListener(@ViewerScroll);
  end;
  FViewer := Value;
  FLoading := False;
  FLoadPercent := 0;
  if FViewer <> nil then
  begin
    FViewer.AddDocumentLoadListener(@ViewerDocumentLoad);
    FViewer.AddLoadProgressListener(@ViewerLoadProgress);
    FViewer.AddScrollListener(@ViewerScroll);
  end;
  Refresh;
end;

procedure TFb2StatusBar.SetShowBook(const Value: Boolean);
begin
  if FShowBook = Value then
    Exit;
  FShowBook := Value;
  LayoutPanels;
  Refresh;
end;

procedure TFb2StatusBar.SetShowChapter(const Value: Boolean);
begin
  if FShowChapter = Value then
    Exit;
  FShowChapter := Value;
  LayoutPanels;
  Refresh;
end;

procedure TFb2StatusBar.SetShowCounter(const Value: Boolean);
begin
  if FShowCounter = Value then
    Exit;
  FShowCounter := Value;
  LayoutPanels;
  Refresh;
end;

procedure TFb2StatusBar.SetShowProgress(const Value: Boolean);
begin
  if FShowProgress = Value then
    Exit;
  FShowProgress := Value;
  LayoutPanels;
  Refresh;
end;

procedure TFb2StatusBar.ViewerDocumentLoad(Sender: TObject);
begin
  Refresh;
end;

procedure TFb2StatusBar.ViewerScroll(Sender: TObject);
begin
  Refresh;
end;

{ Прогресс загрузки: панель прогресса на время загрузки показывает её процент,
  затем снова — прогресс чтения. }
procedure TFb2StatusBar.ViewerLoadProgress(Sender: TObject;
  Stage: TFb2LoadStage; Percent: Integer);
begin
  if (Stage = lsDone) or (Stage = lsFailed) then
  begin
    FLoading := False;
    FLoadPercent := 0;
    Refresh;
  end
  else
  begin
    FLoading := True;
    FLoadPercent := Percent;
  end;
  InvalidateProgress;
end;

procedure TFb2StatusBar.InvalidateProgress;
begin
  if FShowProgress and HandleAllocated then
  begin
    Invalidate;
    { Перерисовать немедленно: загрузка идёт в этом же потоке, и без Update
      полоса обновилась бы только после её окончания. }
    Update;
  end;
end;

procedure TFb2StatusBar.Resize;
begin
  inherited Resize;
  LayoutPanels;
  Refresh;
end;

{ Пересоздать панели по свойствам Show* и распределить ширину. }
procedure TFb2StatusBar.LayoutPanels;
var
  Idx, W, Fixed, Flex, BookW, ChapW: Integer;
begin
  Panels.BeginUpdate;
  try
    Panels.Clear;
    if FShowBook then
      Panels.Add;
    if FShowChapter then
      Panels.Add;
    if FShowCounter then
      Panels.Add;
    if FShowProgress then
      Panels.Add;
  finally
    Panels.EndUpdate;
  end;

  W := ClientWidth - 4;
  if W < 80 then
    W := 80;
  Fixed := 0;
  if FShowCounter then
    Inc(Fixed, 90);
  if FShowProgress then
    Inc(Fixed, 90);
  Flex := W - Fixed;
  if Flex < 0 then
    Flex := 0;

  BookW := 0;
  ChapW := 0;
  if FShowBook and FShowChapter then
  begin
    BookW := Flex * 2 div 5;
    ChapW := Flex - BookW;
  end
  else if FShowBook then
    BookW := Flex
  else if FShowChapter then
    ChapW := Flex;

  Idx := 0;
  if FShowBook then
  begin
    Panels[Idx].Width := BookW;
    Inc(Idx);
  end;
  if FShowChapter then
  begin
    Panels[Idx].Width := ChapW;
    Inc(Idx);
  end;
  if FShowCounter then
  begin
    Panels[Idx].Width := 90;
    Inc(Idx);
  end;
  if FShowProgress then
  begin
    Panels[Idx].Width := 90;
    Panels[Idx].Style := psOwnerDraw;   { рисуем полосу сами }
  end;
end;

{ LCL-строки — UTF-8, а DefaultSystemCodePage может быть 1251, поэтому
  конвертируем явно (иначе кириллица в панелях поедет). }
procedure TFb2StatusBar.SetPanel(Index: Integer; const AText: UnicodeString);
begin
  if (Index >= 0) and (Index < Panels.Count) then
    Panels[Index].Text := UTF8Encode(AText);
end;

function TFb2StatusBar.BookCaption(Desc: TDescription): UnicodeString;
var
  TI: TTitleInfo;
  Authors: TTextList;
  I: Integer;
  Title, Who: UnicodeString;
begin
  Result := '';
  if Desc = nil then
    Exit;
  TI := Desc.TitleInfo;
  if TI = nil then
    Exit;
  Title := '';
  if TI.BookTitle <> nil then
    Title := TI.BookTitle.Value;
  Authors := TTextList.Create;
  try
    for I := 0 to TI.Authors.Count - 1 do
      Authors.Add(AuthorText(TAuthor(TI.Authors[I])));
    Who := JoinText(Authors, ', ');
  finally
    Authors.Free;
  end;
  if (Title <> '') and (Who <> '') then
    Result := Title + ' — ' + Who
  else if Title <> '' then
    Result := Title
  else
    Result := Who;
end;

function TFb2StatusBar.ChapterCaption(Conv: TFb2ToHtmlConverter;
  Idx: Integer): UnicodeString;
var
  Entries: TTocEntryList;
begin
  Result := '';
  if (Conv = nil) or (Idx < 0) then
    Exit;
  Entries := Conv.TocEntries;
  if (Entries = nil) or (Idx >= Entries.Count) then
    Exit;
  Result := Entries[Idx].Title;
end;

function TFb2StatusBar.ReadingProgressPercent: Integer;
var
  Pos, Max: Integer;
begin
  Result := -1;
  if FViewer = nil then
    Exit;
  Max := FViewer.Viewer.VScrollBarRange;
  if Max <= 0 then
    Exit;
  Pos := FViewer.ScrollPosition;
  if Pos < 0 then
    Pos := 0;
  if Pos > Max then
    Pos := Max;
  Result := Pos * 100 div Max;
end;

{ Что показывает панель: во время загрузки — прогресс загрузки, иначе — чтения. }
function TFb2StatusBar.ProgressPercent: Integer;
begin
  if FLoading then
    Result := FLoadPercent
  else
    Result := ReadingProgressPercent;
  if Result < 0 then
    Result := 0;
  if Result > 100 then
    Result := 100;
end;

function TFb2StatusBar.ProgressCaption: UnicodeString;
begin
  if FLoading then
    Result := Format('%d %%', [FLoadPercent])
  else if ReadingProgressPercent < 0 then
    Result := ''
  else
    Result := Format('%d %%', [ReadingProgressPercent]);
end;

{ Owner-draw панель прогресса: дорожка + заливка + процент справа. }
procedure TFb2StatusBar.DrawProgressBar(const Rect: TRect);
const
  Gap = 3;
var
  BarR, FillR, TextR: TRect;
  Pct, TextW, FillW: Integer;
  S: UnicodeString;
  S8: UTF8String;
  Style: TTextStyle;
begin
  Canvas.Brush.Style := bsSolid;
  if Color = clDefault then
    Canvas.Brush.Color := clBtnFace
  else
    Canvas.Brush.Color := Color;
  Canvas.FillRect(Rect);

  { Нет книги и нет загрузки — панель пустая (как раньше с пустым текстом). }
  if (not FLoading) and (ReadingProgressPercent < 0) then
    Exit;

  S := ProgressCaption;
  Canvas.Font.Assign(Font);
  S8 := UTF8Encode(S);
  if S8 <> '' then
    TextW := Canvas.TextWidth(S8) + 4
  else
    TextW := 0;

  BarR := Rect;
  InflateRect(BarR, -Gap, -Gap);
  if BarR.Right - BarR.Left > TextW + 8 then
    Dec(BarR.Right, TextW + 2);

  if (BarR.Right > BarR.Left) and (BarR.Bottom > BarR.Top) then
  begin
    Pct := ProgressPercent;
    Canvas.Brush.Color := clBtnShadow;
    Canvas.FillRect(BarR);
    FillW := (BarR.Right - BarR.Left) * Pct div 100;
    if FillW > 0 then
    begin
      FillR := BarR;
      FillR.Right := FillR.Left + FillW;
      Canvas.Brush.Color := clHighlight;
      Canvas.FillRect(FillR);
    end;
    { Рамка дорожки: Rectangle при bsClear рисует только контур. }
    Canvas.Brush.Style := bsClear;
    Canvas.Pen.Color := clBtnShadow;
    Canvas.Rectangle(BarR.Left, BarR.Top, BarR.Right, BarR.Bottom);
    Canvas.Brush.Style := bsSolid;
  end;

  if S <> '' then
  begin
    TextR := Rect;
    if BarR.Right > BarR.Left then
      TextR.Left := BarR.Right + 2;
    if TextR.Right > TextR.Left then
    begin
      Canvas.Brush.Style := bsClear;
      Canvas.Font.Color := clBtnText;
      Style := Canvas.TextStyle;
      Style.Alignment := taCenter;
      Style.Layout := tlCenter;
      Style.SingleLine := True;
      Style.Clipping := True;
      Canvas.TextRect(TextR, TextR.Left, TextR.Top, S8, Style);
      Canvas.Brush.Style := bsSolid;
    end;
  end;
end;

procedure TFb2StatusBar.DrawPanel(Panel: TStatusPanel; const Rect: TRect);
begin
  inherited DrawPanel(Panel, Rect);
  if FShowProgress and (Panels.Count > 0) and (Panel.Index >= 0) and
     (Panel.Index = Panels.Count - 1) then
    DrawProgressBar(Rect);
end;

procedure TFb2StatusBar.Refresh;
var
  Conv: TFb2ToHtmlConverter;
  Idx, Total, P: Integer;
begin
  if FUpdating then
    Exit;
  { Во время загрузки остальные панели могут обращаться к ещё не готовому
    конвертеру/документу; обновляем только полосу прогресса. }
  if FLoading then
  begin
    if FShowProgress and (Panels.Count > 0) then
      SetPanel(Panels.Count - 1, ProgressCaption);
    Exit;
  end;
  FUpdating := True;
  try
    Conv := nil;
    if FViewer <> nil then
      Conv := FViewer.Converter;

    Idx := -1;
    Total := 0;
    if Conv <> nil then
    begin
      Idx := FViewer.TocIndexOfCurrent(FTrackMargin);
      if Conv.TocEntries <> nil then
        Total := Conv.TocEntries.Count;
    end;

    P := 0;
    if FShowBook then
    begin
      if Conv = nil then
        SetPanel(P, '')
      else
        SetPanel(P, BookCaption(Conv.Description));
      Inc(P);
    end;
    if FShowChapter then
    begin
      SetPanel(P, ChapterCaption(Conv, Idx));
      Inc(P);
    end;
    if FShowCounter then
    begin
      if (Idx >= 0) and (Total > 0) then
        SetPanel(P, Format('%d / %d', [Idx + 1, Total]))
      else
        SetPanel(P, '');
      Inc(P);
    end;
    if FShowProgress then
      SetPanel(P, ProgressCaption);
  finally
    FUpdating := False;
  end;
end;

end.
