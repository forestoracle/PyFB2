unit fb2pdfoutline;
{ Дерево оглавления PDF (закладки документа), связанное с TFb2PdfView.

  Показывает дерево bookmarks загруженного PDF и выполняет навигацию: выбор
  узла → TFb2PdfView.GoToPage(PageIndex закладки). Внешние закладки (URI,
  файл) открываются в системном браузере (AutoOpenLinks).

  Обратная связь: дерево подписывается на TFb2PdfView.AddPageChangeListener и
  при смене страницы (кнопками, кликом по миниатюре, программно) выделяет
  закладку текущего раздела — последнюю с PageIndex <= текущей страницы.
  Поэтому ручная прокрутка страницы внутри документа раздел не меняет.

  ВАЖНО (LCL): TTreeView шлёт OnChange ОТЛОЖЕННО (через таймер), поэтому
  программное выделение нельзя «заглушить» флагом на время присвоения
  Node.Selected — к моменту OnChange флаг уже сброшен. Дерево запоминает
  программно выделенный узел (FIgnoreChange) и игнорирует ровно его OnChange
  (тот же приём, что в fb2outline.pas).

  Источник данных — fb2pdfbookmarks.pas (обход FPDFBookmark_* из PdfiumLib).
  Требует fb2pdfview.pas, то есть PdfiumPascal, PdfiumLib и pdfium.dll; GUI.

  Пример:
      V := TFb2PdfView.Create(Self);
      V.Parent := ...;  V.Align := alClient;
      O := TFb2PdfOutline.Create(Self);
      O.Parent := ...;  O.Viewer := V;
      V.FileName := 'book.pdf';   ( дерево построится само: клик — переход,
                                    смена страницы — подсветка раздела ) }

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Classes, SysUtils, ComCtrls, Controls, ImgList, LCLIntf,
  fb2pdfbookmarks, fb2pdfview;

type
  { Дерево оглавления PDF, привязанное к TFb2PdfView. }
  TFb2PdfOutline = class(TCustomTreeView)
  private
    FViewer: TFb2PdfView;
    FBookmarks: TFb2PdfBookmarks;
    FLastSerial: Integer;          { номер документа последнего построения }
    FUpdating: Boolean;
    FIgnoreChange: TTreeNode;      { узел, выделенный программно }
    FCurrentNode: TTreeNode;
    FAutoImages: Boolean;
    FAutoOpenLinks: Boolean;
    FBookmarkImageIndex: TImageIndex;
    FCurrentImageIndex: TImageIndex;
    FCurrentStateIndex: TImageIndex;
    procedure SetViewer(const Value: TFb2PdfView);
    procedure SetAutoImages(const Value: Boolean);
    procedure SetBookmarkImageIndex(const Value: TImageIndex);
    procedure SetCurrentImageIndex(const Value: TImageIndex);
    procedure SetCurrentStateIndex(const Value: TImageIndex);
    procedure ViewerDocumentLoad(Sender: TObject);
    procedure ViewerPageChange(Sender: TObject; PageNumber, PageCount: Integer);
    procedure TreeChange(Sender: TObject; Node: TTreeNode);
    procedure ActivateNode(Node: TTreeNode);
    procedure ApplyImages;
    procedure ApplyNodeImages(Node: TTreeNode; IsCurrent: Boolean);
    procedure UpdateCurrent;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    { Перестроить дерево по текущему документу просмотрщика. }
    procedure Rebuild;
    { Если документ тот же — только подсветить текущий раздел, иначе перестроить. }
    procedure Refresh;
    { Перейти к выбранному узлу (обычно не нужно: переход идёт по выбору). }
    procedure GoToSelected;
    { Узел текущего раздела (nil — документа нет или закладок нет). }
    function CurrentNode: TTreeNode;
    { Текущий раздел в списке закладок: индекс в Bookmarks или -1. }
    function CurrentIndex: Integer;
    { Прочитанные закладки (nil — ещё не читались). Владеет компонент. }
    property Bookmarks: TFb2PdfBookmarks read FBookmarks;
  published
    { У «Custom»-предков Align/Anchors объявлены public — переопубликовываем
      для инспектора объектов (как в TFb2Viewer/TFb2Outline). }
    property Align;
    property Anchors;
    { Связанный просмотрщик PDF. }
    property Viewer: TFb2PdfView read FViewer write SetViewer;
    { Открывать внешние закладки (URI/файл) в системном браузере. }
    property AutoOpenLinks: Boolean read FAutoOpenLinks write FAutoOpenLinks
      default True;
    { Поставщик картинок узлов (переопубликовано: у TCustomTreeView свойство
      только public). }
    property Images;
    { Второй список — маркер текущего раздела (CurrentStateIndex). }
    property StateImages;
    { Раздавать узлам картинки автоматически. False — индексы не трогаются. }
    property AutoImages: Boolean read FAutoImages write SetAutoImages
      default True;
    { Картинка закладки. -1 — без картинки. }
    property BookmarkImageIndex: TImageIndex read FBookmarkImageIndex
      write SetBookmarkImageIndex default -1;
    { Картинка текущего (выделенного) раздела. -1 — как у BookmarkImageIndex. }
    property CurrentImageIndex: TImageIndex read FCurrentImageIndex
      write SetCurrentImageIndex default -1;
    { Номер картинки-маркера текущего раздела в StateImages. -1 — без маркера. }
    property CurrentStateIndex: TImageIndex read FCurrentStateIndex
      write SetCurrentStateIndex default -1;
    { События LCL для ручной выдачи картинок (нужны при AutoImages = False). }
    property OnGetImageIndex;
    property OnGetSelectedIndex;
  end;

implementation

constructor TFb2PdfOutline.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FLastSerial := -1;
  FAutoImages := True;
  FAutoOpenLinks := True;
  FBookmarkImageIndex := -1;
  FCurrentImageIndex := -1;
  FCurrentStateIndex := -1;
  ReadOnly := True;
  ShowButtons := True;
  ShowLines := False;
  ShowRoot := True;
  OnChange := @TreeChange;
end;

destructor TFb2PdfOutline.Destroy;
begin
  if FViewer <> nil then
  begin
    FViewer.RemoveDocumentLoadListener(@ViewerDocumentLoad);
    FViewer.RemovePageChangeListener(@ViewerPageChange);
  end;
  FreeAndNil(FBookmarks);
  inherited Destroy;
end;

{ ===================== Связывание с просмотрщиком ===================== }

procedure TFb2PdfOutline.SetViewer(const Value: TFb2PdfView);
begin
  if FViewer = Value then
    Exit;
  if FViewer <> nil then
  begin
    FViewer.RemoveDocumentLoadListener(@ViewerDocumentLoad);
    FViewer.RemovePageChangeListener(@ViewerPageChange);
  end;
  FViewer := Value;
  FLastSerial := -1;
  if FViewer <> nil then
  begin
    FViewer.AddDocumentLoadListener(@ViewerDocumentLoad);
    FViewer.AddPageChangeListener(@ViewerPageChange);
    Rebuild;
  end
  else
  begin
    Items.Clear;
    FreeAndNil(FBookmarks);
    FCurrentNode := nil;
    FIgnoreChange := nil;
  end;
end;

procedure TFb2PdfOutline.ViewerDocumentLoad(Sender: TObject);
begin
  Refresh;
end;

procedure TFb2PdfOutline.ViewerPageChange(Sender: TObject; PageNumber,
  PageCount: Integer);
begin
  UpdateCurrent;
end;

{ ===================== Построение дерева ===================== }

procedure TFb2PdfOutline.Rebuild;
begin
  FUpdating := True;
  try
    Items.BeginUpdate;
    try
      Items.Clear;
      FreeAndNil(FBookmarks);
      FIgnoreChange := nil;
      FCurrentNode := nil;
      if FViewer = nil then
        Exit;
      FBookmarks := CollectPdfBookmarks(FViewer.Document);
      FillBookmarkTree(Self, FBookmarks);
      FLastSerial := FViewer.DocumentSerial;
    finally
      Items.EndUpdate;
    end;
  finally
    FUpdating := False;
  end;

  if Items.Count > 0 then
    FullExpand;
  ApplyImages;
  UpdateCurrent;
end;

procedure TFb2PdfOutline.Refresh;
begin
  if (FViewer <> nil) and (FViewer.DocumentSerial = FLastSerial) and
    (Items.Count > 0) then
    { Тот же документ: дерево не перестраиваем — только подсвечиваем раздел. }
    UpdateCurrent
  else
    Rebuild;
end;

{ ===================== Навигация ===================== }

procedure TFb2PdfOutline.ActivateNode(Node: TTreeNode);
var
  Bm: TFb2PdfBookmark;
begin
  if (FViewer = nil) or (Node = nil) or not (TObject(Node.Data) is TFb2PdfBookmark) then
    Exit;
  Bm := TFb2PdfBookmark(Node.Data);
  if Bm.Url <> '' then
  begin
    if FAutoOpenLinks then
      LCLIntf.OpenURL(Bm.Url);
    Exit;
  end;
  if Bm.PageIndex >= 0 then
    FViewer.GoToPage(Bm.PageIndex);
end;

procedure TFb2PdfOutline.GoToSelected;
begin
  ActivateNode(Selected);
end;

procedure TFb2PdfOutline.TreeChange(Sender: TObject; Node: TTreeNode);
begin
  if FUpdating then
    Exit;
  { Программное выделение (подсветка раздела) — не повод для перехода. }
  if Node = FIgnoreChange then
  begin
    FIgnoreChange := nil;
    Exit;
  end;
  FIgnoreChange := nil;
  ActivateNode(Node);
end;

{ ===================== Текущий раздел ===================== }

function TFb2PdfOutline.CurrentNode: TTreeNode;
begin
  Result := FCurrentNode;
end;

function TFb2PdfOutline.CurrentIndex: Integer;
var
  I: Integer;
begin
  Result := -1;
  if (FCurrentNode = nil) or (FBookmarks = nil) then
    Exit;
  if not (TObject(FCurrentNode.Data) is TFb2PdfBookmark) then
    Exit;
  for I := 0 to FBookmarks.Count - 1 do
    if FBookmarks.Item(I) = TFb2PdfBookmark(FCurrentNode.Data) then
    begin
      Result := I;
      Exit;
    end;
end;

procedure TFb2PdfOutline.UpdateCurrent;
var
  Node: TTreeNode;
begin
  if (FViewer = nil) or (Items.Count = 0) or (FViewer.PageCount <= 0) then
  begin
    if FCurrentNode <> nil then
    begin
      FCurrentNode := nil;
      ApplyImages;
    end;
    Exit;
  end;

  Node := FindBookmarkNode(Self, FViewer.PageIndex);
  if Node = FCurrentNode then
    Exit;
  FCurrentNode := Node;
  ApplyImages;          { у прежнего раздела снять картинку-маркер }
  if Node = nil then
    Exit;

  FUpdating := True;
  try
    FIgnoreChange := Node;   { отложенный OnChange этого узла игнорируем }
    Node.Selected := True;
    Node.MakeVisible;
  finally
    FUpdating := False;
  end;
end;

{ ===================== Картинки узлов ===================== }

procedure TFb2PdfOutline.SetAutoImages(const Value: Boolean);
begin
  if FAutoImages = Value then
    Exit;
  FAutoImages := Value;
  ApplyImages;
end;

procedure TFb2PdfOutline.SetBookmarkImageIndex(const Value: TImageIndex);
begin
  if FBookmarkImageIndex = Value then
    Exit;
  FBookmarkImageIndex := Value;
  ApplyImages;
end;

procedure TFb2PdfOutline.SetCurrentImageIndex(const Value: TImageIndex);
begin
  if FCurrentImageIndex = Value then
    Exit;
  FCurrentImageIndex := Value;
  ApplyImages;
end;

procedure TFb2PdfOutline.SetCurrentStateIndex(const Value: TImageIndex);
begin
  if FCurrentStateIndex = Value then
    Exit;
  FCurrentStateIndex := Value;
  ApplyImages;
end;

{ Назначить картинку и маркер одному узлу. SelectedIndex дублирует ImageIndex:
  LCL рисует у ВЫДЕЛЕННОГО узла именно SelectedIndex, а текущий раздел выделен
  программно — иначе его картинка исчезала бы (как в fb2outline.pas). }
procedure TFb2PdfOutline.ApplyNodeImages(Node: TTreeNode; IsCurrent: Boolean);
var
  Idx, State: TImageIndex;
begin
  if Node = nil then
    Exit;
  Idx := -1;
  if IsCurrent then
    Idx := FCurrentImageIndex;
  if Idx < 0 then
    Idx := FBookmarkImageIndex;
  Node.ImageIndex := Idx;
  Node.SelectedIndex := Idx;

  if IsCurrent then
    State := FCurrentStateIndex
  else
    State := -1;
  if (StateImages <> nil) and (State >= 0) then
    Node.StateIndex := State
  else if Node.StateIndex <> -1 then
    Node.StateIndex := -1;
end;

procedure TFb2PdfOutline.ApplyImages;
var
  I: Integer;
begin
  if not FAutoImages then
    Exit;
  if (Images = nil) and (StateImages = nil) then
    Exit;
  for I := 0 to Items.Count - 1 do
    ApplyNodeImages(Items[I], Items[I] = FCurrentNode);
end;

end.
