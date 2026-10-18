unit fb2outline;
{ Дерево заголовков FB2 (TTreeView), связанное с TFb2Viewer.

  Показывает оглавление загруженного документа (тела книги + секции) и
  выполняет навигацию: выбор узла -> TFb2Viewer.GoToAnchor (переход к якорю
  'sec-N', который генерирует fb2_html.pas).

  Обратная связь: дерево подписывается на TFb2Viewer.AddScrollListener и при
  ручной прокрутке текста (колесо, клавиши, полоса прокрутки) или переходе по
  внутренней ссылке подсвечивает текущую главу — узел с наибольшей позицией,
  не выходящей за верхнюю границу области чтения.

  ВАЖНО (LCL): TTreeView шлёт OnChange ОТЛОЖЕННО — при смене выделения
  InternalSelectionChanged включает таймер (интервал 1 мс), и только потом
  ChangeTimer вызывает Change(Node) -> OnChange. Поэтому программную подсветку
  главы нельзя заглушить флагом на время присвоения Node.Selected (к моменту
  OnChange флаг уже сброшен): дерево запоминает узел, выделенный программно
  (FIgnoreChange), и игнорирует ровно его OnChange. Иначе после перехода к
  сноске (или обратно в текст) вид «прыгал» бы к началу текущей главы.

  Источник данных — TFb2ToHtmlConverter.TocEntries (плоский список
  level/anchor/title), то есть ровно то же, из чего строится <nav class="toc">.

  Картинки: у TCustomTreeView свойства Images/StateImages объявлены только
  public (в инспекторе объектов их нет), поэтому здесь они переопубликованы и
  компонент сам раздаёт узлам ImageIndex по уровню заголовка: тело книги
  (level 0) — BodyImageIndex, главы (level 1) — ChapterImageIndex, подглавы
  (level >= 2) — SubchapterImageIndex; текущая (подсвеченная) глава получает
  CurrentImageIndex, а её маркер в StateImages — CurrentStateIndex. Если
  AutoImages = False, иконки не трогаются — их можно задавать самому в
  OnGetImageIndex/OnGetSelectedIndex (события тоже переопубликованы).
  ВАЖНО: LCL рисует у ВЫДЕЛЕННОГО узла Node.SelectedIndex, а не ImageIndex,
  поэтому компонент присваивает SelectedIndex то же значение — иначе иконка у
  текущей главы (она выделена программно) просто исчезала бы.

  Требует fb2viewer.pas (а значит пакет HtmlViewer 11) и LCL. GUI-модуль.

  Пример:
      V := TFb2Viewer.Create(Self);
      V.Parent := ...;  V.Align := alClient;
      O := TFb2Outline.Create(Self);
      O.Parent := ...;  O.Viewer := V;
      V.FileName := 'book.fb2';   ( дерево построится само: клик — переход,
                                    прокрутка — подсветка текущей главы ) }

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Classes, SysUtils, ComCtrls, Controls, ImgList, fb2_html, fb2viewer;

type
  { Дерево заголовков, привязанное к TFb2Viewer. }
  TFb2Outline = class(TCustomTreeView)
  private
    FViewer: TFb2Viewer;
    FAnchors: TStringList;         { якоря в порядке следования в документе }
    FNodes: TList;                 { узлы, соответствующие FAnchors }
    FLastSerial: Integer;          { номер документа последнего построения }
    FUpdating: Boolean;
    FLastAnchor: UnicodeString;
    FCurrentIdx: Integer;          { индекс подсвеченной главы }
    FIgnoreChange: TTreeNode;      { узел, выделенный программно: его OnChange игнорируем }
    FAutoTrackScroll: Boolean;
    FTrackMargin: Integer;
    FAutoImages: Boolean;          { раздавать иконки узлам автоматически }
    FBodyImageIndex: TImageIndex;        { иконка тела книги (level 0) }
    FChapterImageIndex: TImageIndex;     { иконка глав (level 1) }
    FSubchapterImageIndex: TImageIndex;  { иконка подглав (level >= 2) }
    FCurrentImageIndex: TImageIndex;     { иконка текущей (подсвеченной) главы }
    FCurrentStateIndex: TImageIndex;     { маркер текущей главы в StateImages }

    procedure SetViewer(const Value: TFb2Viewer);
    procedure ViewerDocumentLoad(Sender: TObject);
    procedure ViewerScroll(Sender: TObject);
    procedure TreeChange(Sender: TObject; Node: TTreeNode);
    procedure SelectNode(Index: Integer);
    procedure SetAutoImages(const Value: Boolean);
    procedure SetBodyImageIndex(const Value: TImageIndex);
    procedure SetChapterImageIndex(const Value: TImageIndex);
    procedure SetSubchapterImageIndex(const Value: TImageIndex);
    procedure SetCurrentImageIndex(const Value: TImageIndex);
    procedure SetCurrentStateIndex(const Value: TImageIndex);
    { Иконка узла по уровню заголовка (-1 — не задана). }
    function ImageIndexForLevel(Level: Integer): TImageIndex;
    { Назначить иконку и маркер одному узлу (IsCurrent — это текущая глава). }
    procedure ApplyNodeImages(Node: TTreeNode; IsCurrent: Boolean);
    { Сделать главу текущей (без выделения узла): переставить картинки у прежней
      и новой текущей главы. }
    procedure MarkCurrent(Index: Integer);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    { Перестроить дерево по заголовкам текущего документа. }
    procedure Rebuild;
    { Пересчитать позиции якорей и подсветить текущую главу. }
    procedure UpdateCurrent;
    { Раздать иконки всем узлам по текущим настройкам (нужно после ручного
      изменения индексов; при AutoImages = False ничего не делает). }
    procedure ApplyImages;
    { Индекс подсвеченной главы (-1 — нет). }
    function CurrentIndex: Integer;
  published
    { Размещение на форме: у TCustomTreeView свойства Align, Anchors и Visible
      объявлены public, поэтому переопубликовываем их для инспектора объектов.
      Visible — чтобы дерево можно было скрывать/показывать (в том числе из
      .lfm и в инспекторе объектов). }
    property Align;
    property Anchors;
    property Visible;
    { Связанный просмотрщик: после загрузки документа дерево строится само,
      выбор узла переходит к соответствующему якорю, а прокрутка текста
      подсвечивает текущую главу. }
    property Viewer: TFb2Viewer read FViewer write SetViewer;
    { Подсвечивать текущую главу при прокрутке текста. }
    property AutoTrackScroll: Boolean read FAutoTrackScroll write FAutoTrackScroll default True;
    { Отступ от верхнего края области чтения (в пикселях): глава считается
      текущей, если её заголовок находится выше этой границы. }
    property TrackMargin: Integer read FTrackMargin write FTrackMargin default 16;

    { Поставщик картинок для узлов (TImageList). Переопубликовано: у
      TCustomTreeView свойство объявлено только public и в инспекторе объектов
      его не видно. Индексы картинок задаются свойствами BodyImageIndex,
      ChapterImageIndex, SubchapterImageIndex, CurrentImageIndex. }
    property Images;
    { Второй список картинок — маркер текущей главы (CurrentStateIndex);
      переопубликовано по той же причине, что и Images. }
    property StateImages;
    { Раздавать узлам картинки из Images автоматически, по уровню заголовка и
      для текущей главы. False — индексы не трогаются (задавайте сами, например
      в OnGetImageIndex/OnGetSelectedIndex). }
    property AutoImages: Boolean read FAutoImages write SetAutoImages default True;
    { Картинка узла тела книги (level 0). -1 — без картинки. }
    property BodyImageIndex: TImageIndex read FBodyImageIndex write SetBodyImageIndex default -1;
    { Картинка глав (level 1). -1 — без картинки. }
    property ChapterImageIndex: TImageIndex read FChapterImageIndex write SetChapterImageIndex default -1;
    { Картинка подглав (level >= 2). -1 — без картинки. }
    property SubchapterImageIndex: TImageIndex read FSubchapterImageIndex write SetSubchapterImageIndex default -1;
    { Картинка текущей (подсвеченной) главы. -1 — как у её уровня. }
    property CurrentImageIndex: TImageIndex read FCurrentImageIndex write SetCurrentImageIndex default -1;
    { Номер картинки-маркера текущей главы в StateImages. -1 — без маркера. }
    property CurrentStateIndex: TImageIndex read FCurrentStateIndex write SetCurrentStateIndex default -1;
    { События LCL для ручной выдачи картинок узлам (нужны при AutoImages =
      False); переопубликованы, т. к. у TCustomTreeView они только public. }
    property OnGetImageIndex;
    property OnGetSelectedIndex;
  end;

implementation

constructor TFb2Outline.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FAnchors := TStringList.Create;
  FNodes := TList.Create;
  FCurrentIdx := -1;
  FAutoTrackScroll := True;
  FTrackMargin := 16;
  { Картинки: по умолчанию индексы не заданы (-1) — вид дерева не меняется,
    пока пользователь не назначит Images и не укажет индексы. }
  FAutoImages := True;
  FBodyImageIndex := -1;
  FChapterImageIndex := -1;
  FSubchapterImageIndex := -1;
  FCurrentImageIndex := -1;
  FCurrentStateIndex := -1;
  ReadOnly := True;
  ShowButtons := True;
  ShowLines := False;
  ShowRoot := True;
  OnChange := @TreeChange;
end;

destructor TFb2Outline.Destroy;
begin
  if FViewer <> nil then
  begin
    FViewer.RemoveDocumentLoadListener(@ViewerDocumentLoad);
    FViewer.RemoveScrollListener(@ViewerScroll);
  end;
  FreeAndNil(FNodes);
  FreeAndNil(FAnchors);
  inherited Destroy;
end;

procedure TFb2Outline.SetViewer(const Value: TFb2Viewer);
begin
  if FViewer = Value then
    Exit;
  if FViewer <> nil then
  begin
    FViewer.RemoveDocumentLoadListener(@ViewerDocumentLoad);
    FViewer.RemoveScrollListener(@ViewerScroll);
  end;
  FViewer := Value;
  FLastSerial := -1;
  if FViewer <> nil then
  begin
    FViewer.AddDocumentLoadListener(@ViewerDocumentLoad);
    FViewer.AddScrollListener(@ViewerScroll);
    Rebuild;
  end
  else
  begin
    Items.Clear;
    FAnchors.Clear;
    FNodes.Clear;
    FCurrentIdx := -1;
    FIgnoreChange := nil;
  end;
end;

procedure TFb2Outline.ViewerDocumentLoad(Sender: TObject);
begin
  if (FViewer <> nil) and (FViewer.DocumentSerial = FLastSerial) and
    (FAnchors.Count > 0) then
  begin
    { Тот же документ (переход по якорю, смена размера шрифта): дерево не
      перестраиваем — позиции заголовков уже пересчитаны просмотрщиком,
      остаётся подсветить главу. }
    UpdateCurrent;
  end
  else
    Rebuild;
end;

procedure TFb2Outline.ViewerScroll(Sender: TObject);
begin
  if FAutoTrackScroll then
    UpdateCurrent;
end;

procedure TFb2Outline.Rebuild;
var
  Entries: TTocEntryList;
  I, Lvl: Integer;
  E: TTocEntry;
  Parents: array of TTreeNode;
  Node: TTreeNode;
begin
  FUpdating := True;
  Items.BeginUpdate;
  try
    Items.Clear;
    FAnchors.Clear;
    FNodes.Clear;
    FLastAnchor := '';
    FCurrentIdx := -1;
    FIgnoreChange := nil;
    if (FViewer = nil) or (FViewer.Converter = nil) then
      Exit;
    Entries := FViewer.Converter.TocEntries;
    if Entries = nil then
      Exit;

    SetLength(Parents, 0);
    for I := 0 to Entries.Count - 1 do
    begin
      E := Entries[I];
      Lvl := E.Level;
      if Lvl < 0 then
        Lvl := 0;
      if Lvl > Length(Parents) then
        Lvl := Length(Parents);       { пропуск уровня не допускаем }
      SetLength(Parents, Lvl + 1);

      if Lvl = 0 then
        Node := Items.AddChild(nil, UTF8Encode(E.Title))
      else
        Node := Items.AddChild(Parents[Lvl - 1], UTF8Encode(E.Title));

      FAnchors.Add(E.Anchor);
      FNodes.Add(Node);
      Node.Data := Pointer(PtrInt(FAnchors.Count - 1));
      Parents[Lvl] := Node;
    end;
    FLastSerial := FViewer.DocumentSerial;
  finally
    Items.EndUpdate;
    FUpdating := False;
  end;

  ApplyImages;      { картинки по уровням заголовков }
  UpdateCurrent;
end;

function TFb2Outline.CurrentIndex: Integer;
begin
  Result := FCurrentIdx;
end;

{ ===================== Картинки узлов ===================== }

function TFb2Outline.ImageIndexForLevel(Level: Integer): TImageIndex;
begin
  if Level <= 0 then
    Result := FBodyImageIndex
  else if Level = 1 then
    Result := FChapterImageIndex
  else
    Result := FSubchapterImageIndex;
end;

{ Назначить картинку и маркер одному узлу. SelectedIndex дублирует ImageIndex:
  LCL рисует у ВЫДЕЛЕННОГО узла именно SelectedIndex, а текущая глава выделена
  программно — иначе её картинка исчезала бы. }
procedure TFb2Outline.ApplyNodeImages(Node: TTreeNode; IsCurrent: Boolean);
var
  Idx: TImageIndex;
  State: TImageIndex;
begin
  if Node = nil then
    Exit;
  Idx := -1;
  if IsCurrent then
    Idx := FCurrentImageIndex;
  if Idx < 0 then
    Idx := ImageIndexForLevel(Node.Level);
  Node.ImageIndex := Idx;
  Node.SelectedIndex := Idx;

  if IsCurrent then
    State := FCurrentStateIndex
  else
    State := -1;
  if (StateImages <> nil) and (State >= 0) then
    Node.StateIndex := State
  else if Node.StateIndex <> -1 then
    Node.StateIndex := -1;   { иначе у всех узлов рисовался бы маркер 0 }
end;

procedure TFb2Outline.ApplyImages;
var
  I: Integer;
begin
  if not FAutoImages or (FNodes = nil) or (FNodes.Count = 0) then
    Exit;
  Items.BeginUpdate;
  try
    for I := 0 to FNodes.Count - 1 do
      ApplyNodeImages(TTreeNode(FNodes[I]), I = FCurrentIdx);
  finally
    Items.EndUpdate;
  end;
end;

{ Текущая глава сменилась: у прежней узла — картинка её уровня, у нового —
  CurrentImageIndex (и маркер в StateImages). }
procedure TFb2Outline.MarkCurrent(Index: Integer);
begin
  if FCurrentIdx = Index then
    Exit;
  if FAutoImages then
  begin
    if (FCurrentIdx >= 0) and (FCurrentIdx < FNodes.Count) then
      ApplyNodeImages(TTreeNode(FNodes[FCurrentIdx]), False);
    if (Index >= 0) and (Index < FNodes.Count) then
      ApplyNodeImages(TTreeNode(FNodes[Index]), True);
  end;
  FCurrentIdx := Index;
end;

procedure TFb2Outline.SetAutoImages(const Value: Boolean);
begin
  if FAutoImages = Value then
    Exit;
  FAutoImages := Value;
  ApplyImages;
end;

procedure TFb2Outline.SetBodyImageIndex(const Value: TImageIndex);
begin
  if FBodyImageIndex = Value then
    Exit;
  FBodyImageIndex := Value;
  ApplyImages;
end;

procedure TFb2Outline.SetChapterImageIndex(const Value: TImageIndex);
begin
  if FChapterImageIndex = Value then
    Exit;
  FChapterImageIndex := Value;
  ApplyImages;
end;

procedure TFb2Outline.SetSubchapterImageIndex(const Value: TImageIndex);
begin
  if FSubchapterImageIndex = Value then
    Exit;
  FSubchapterImageIndex := Value;
  ApplyImages;
end;

procedure TFb2Outline.SetCurrentImageIndex(const Value: TImageIndex);
begin
  if FCurrentImageIndex = Value then
    Exit;
  FCurrentImageIndex := Value;
  ApplyImages;
end;

procedure TFb2Outline.SetCurrentStateIndex(const Value: TImageIndex);
begin
  if FCurrentStateIndex = Value then
    Exit;
  FCurrentStateIndex := Value;
  ApplyImages;
end;

{ Подсветить главу, в начале которой находится читатель. }
procedure TFb2Outline.UpdateCurrent;
var
  Idx: Integer;
begin
  if FUpdating or (FViewer = nil) or (FAnchors.Count = 0) then
    Exit;
  Idx := FViewer.TocIndexOfCurrent(FTrackMargin);
  if (Idx < 0) or (Idx >= FNodes.Count) or (Idx = FCurrentIdx) then
    Exit;
  SelectNode(Idx);
end;

{ Выделить узел программно (без перехода к якорю). }
procedure TFb2Outline.SelectNode(Index: Integer);
var
  Node: TTreeNode;
begin
  if (Index < 0) or (Index >= FNodes.Count) then
    Exit;
  Node := TTreeNode(FNodes[Index]);
  MarkCurrent(Index);
  { ВАЖНО: LCL TTreeView шлёт OnChange ОТЛОЖЕННО — при смене выделения
    InternalSelectionChanged включает таймер (интервал 1 мс), и лишь потом
    ChangeTimer вызывает Change(Node) -> OnChange. Поэтому флага FUpdating
    недостаточно (к моменту OnChange он уже сброшен). Запоминаем узел, чтобы
    TreeChange проигнорировал именно это программное выделение и не «прыгал»
    к главе при подсветке текущей главы (в т.ч. при переходе к сноске). }
  FIgnoreChange := Node;
  FUpdating := True;
  try
    Node.Selected := True;
    Node.MakeVisible;
  finally
    FUpdating := False;
  end;
end;

procedure TFb2Outline.TreeChange(Sender: TObject; Node: TTreeNode);
var
  Idx: PtrInt;
  Anchor: UnicodeString;
begin
  if FUpdating or (FViewer = nil) or (Node = nil) then
    Exit;
  { Отложенный OnChange от программного выделения (подсветка текущей главы):
    навигацию выполнять не нужно, иначе вид «прыгает» к началу главы. }
  if Node = FIgnoreChange then
  begin
    FIgnoreChange := nil;
    Exit;
  end;
  { Пришёл OnChange для другого узла — метка устарела (например, OnChange
    программного выделения «склеился» с этим же событием). }
  FIgnoreChange := nil;
  Idx := PtrInt(Node.Data);
  if (Idx < 0) or (Idx >= FAnchors.Count) then
    Exit;
  Anchor := FAnchors[Idx];
  if Anchor = FLastAnchor then
    Exit;
  FLastAnchor := Anchor;
  MarkCurrent(Idx);
  FViewer.GoToAnchor(Anchor);
end;

end.
