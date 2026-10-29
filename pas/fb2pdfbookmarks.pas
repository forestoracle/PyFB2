unit fb2pdfbookmarks;
{ Закладки PDF (оглавление документа): чтение дерева bookmarks через pdfium и
  помощники для показа в TTreeView.

  В PdfiumCore высокоуровневой обёртки закладок нет, зато PdfiumLib импортирует
  сырые функции FPDFBookmark_GetFirstChild/GetNextSibling/GetTitle/GetCount/
  GetDest/GetAction и FPDFDest_GetDestPageIndex/FPDFAction_GetURIPath/
  FPDFAction_GetFilePath — обход дерева сделан здесь.

  Результат — ПЛОСКИЙ список с уровнем вложенности (как TocEntries в fb2_html):
  так проще и строить дерево, и синхронизировать его с текущей страницей.
  pdfium отдаёт текст (заголовки, URI) в UTF-16LE, длина возвращается в байтах
  вместе с завершающим нулём — поэтому чтение всегда двумя вызовами.

  Модуль не знает про компоненты просмотра: им пользуются и TFb2PdfOutline
  (отдельный компонент-дерево), и сам TFb2PdfView (встроенный сайдбар).

  Требует PdfiumLib и PdfiumCore (MPL-2.0) и LCL (TTreeView в помощниках). }
{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Classes, Contnrs, ComCtrls, PdfiumCore, PdfiumLib;

type
  { Одна закладка PDF. }
  TFb2PdfBookmark = class
  public
    { Уровень вложенности: 0 — верхний. }
    Level: Integer;
    { Заголовок узла. }
    Title: UnicodeString;
    { Страница назначения (0-based); -1 — перехода внутри документа нет. }
    PageIndex: Integer;
    { Внешняя ссылка (URI или путь к файлу); '' — закладка ведёт в документ. }
    Url: UnicodeString;
    { Есть вложенные закладки (дерево можно раскрыть). }
    HasChildren: Boolean;
  end;

  { Плоский список закладок в порядке документа. Владеет объектами. }
  TFb2PdfBookmarks = class(TObjectList)
  public
    constructor Create;
    function AddItem(const ATitle: UnicodeString; APageIndex: Integer;
      const AUrl: UnicodeString; ALevel: Integer): TFb2PdfBookmark;
    function Item(AIndex: Integer): TFb2PdfBookmark;
  end;

{ Прочитать закладки документа. Пустой список — в PDF нет оглавления.
  Безопасно для nil/неактивного документа. }
function CollectPdfBookmarks(ADocument: TPdfDocument): TFb2PdfBookmarks;

{ Заголовок закладки (FPDFBookmark_GetTitle). }
function PdfBookmarkTitle(ABookmark: FPDF_BOOKMARK): UnicodeString;

{ Построить дерево в TTreeView; в Data каждого узла — TFb2PdfBookmark.
  Существующее содержимое дерева очищается. }
procedure FillBookmarkTree(ATree: TCustomTreeView; ABookmarks: TFb2PdfBookmarks);

{ Узел для страницы: последняя закладка с PageIndex <= APageIndex (иначе первая
  закладка с переходом). Nil — закладок нет. }
function FindBookmarkNode(ATree: TCustomTreeView; APageIndex: Integer): TTreeNode;

implementation

uses
  SysUtils;

{ ===================== Список закладок ===================== }

constructor TFb2PdfBookmarks.Create;
begin
  inherited Create(True);   { OwnsObjects }
end;

function TFb2PdfBookmarks.AddItem(const ATitle: UnicodeString;
  APageIndex: Integer; const AUrl: UnicodeString;
  ALevel: Integer): TFb2PdfBookmark;
begin
  Result := TFb2PdfBookmark.Create;
  Result.Title := ATitle;
  Result.PageIndex := APageIndex;
  Result.Url := AUrl;
  Result.Level := ALevel;
  Result.HasChildren := False;
  Add(Result);
end;

function TFb2PdfBookmarks.Item(AIndex: Integer): TFb2PdfBookmark;
begin
  Result := TFb2PdfBookmark(Items[AIndex]);
end;

{ ===================== Чтение из pdfium ===================== }

{ Текст pdfium (UTF-16LE): буфер, длина в байтах вместе с завершающим нулём.
  Обрезаем по первому #0 (и по неполной паре байт — Length div 2). }
function DecodePdfText(const Data: TBytes): UnicodeString;
var
  Zero: Integer;
begin
  Result := '';
  if Length(Data) < 2 then
    Exit;
  SetLength(Result, Length(Data) div 2);
  Move(Data[0], Result[1], Length(Result) * SizeOf(WideChar));
  Zero := Pos(#0, Result);
  if Zero > 0 then
    SetLength(Result, Zero - 1);
end;

function PdfBookmarkTitle(ABookmark: FPDF_BOOKMARK): UnicodeString;
var
  Len: LongWord;
  Data: TBytes;
begin
  Result := '';
  if ABookmark = nil then
    Exit;
  Len := FPDFBookmark_GetTitle(ABookmark, nil, 0);
  if Len = 0 then
    Exit;
  SetLength(Data, Len);
  if FPDFBookmark_GetTitle(ABookmark, @Data[0], Len) = 0 then
    Exit;
  Result := DecodePdfText(Data);
end;

{ Разобрать назначение закладки: страница внутри документа и/или внешняя ссылка. }
procedure ResolveBookmarkTarget(ADocument: TPdfDocument;
  ABookmark: FPDF_BOOKMARK; out APageIndex: Integer; out AUrl: UnicodeString);
var
  Dest: FPDF_DEST;
  Act: FPDF_ACTION;
  Len: LongWord;
  Data: TBytes;
begin
  APageIndex := -1;
  AUrl := '';
  if (ADocument = nil) or not ADocument.Active then
    Exit;

  Dest := FPDFBookmark_GetDest(ADocument.Handle, ABookmark);
  if Dest <> nil then
  begin
    APageIndex := Integer(FPDFDest_GetDestPageIndex(ADocument.Handle, Dest));
    Exit;
  end;

  { Назначения нет — закладка может быть действием (внешняя ссылка/файл). }
  Act := FPDFBookmark_GetAction(ABookmark);
  if Act = nil then
    Exit;
  case FPDFAction_GetType(Act) of
    PDFACTION_GOTO:
      begin
        Dest := FPDFAction_GetDest(ADocument.Handle, Act);
        if Dest <> nil then
          APageIndex := Integer(FPDFDest_GetDestPageIndex(ADocument.Handle, Dest));
      end;
    PDFACTION_URI:
      begin
        Len := FPDFAction_GetURIPath(ADocument.Handle, Act, nil, 0);
        if Len > 0 then
        begin
          SetLength(Data, Len);
          if FPDFAction_GetURIPath(ADocument.Handle, Act, @Data[0], Len) <> 0 then
            AUrl := DecodePdfText(Data);
        end;
      end;
    PDFACTION_LAUNCH, PDFACTION_REMOTEGOTO, PDFACTION_EMBEDDEDGOTO:
      begin
        Len := FPDFAction_GetFilePath(Act, nil, 0);
        if Len > 0 then
        begin
          SetLength(Data, Len);
          if FPDFAction_GetFilePath(Act, @Data[0], Len) <> 0 then
            AUrl := DecodePdfText(Data);
        end;
      end;
  end;
end;

{ Рекурсивный обход: дети идут с уровнем + 1. }
procedure WalkBookmarks(ADocument: TPdfDocument; ABookmark: FPDF_BOOKMARK;
  ALevel: Integer; AList: TFb2PdfBookmarks);
var
  Bm: FPDF_BOOKMARK;
  PageIndex: Integer;
  Url: UnicodeString;
  Item: TFb2PdfBookmark;
begin
  Bm := ABookmark;
  while Bm <> nil do
  begin
    ResolveBookmarkTarget(ADocument, Bm, PageIndex, Url);
    Item := AList.AddItem(PdfBookmarkTitle(Bm), PageIndex, Url, ALevel);
    Item.HasChildren := FPDFBookmark_GetCount(Bm) <> 0;
    WalkBookmarks(ADocument, FPDFBookmark_GetFirstChild(ADocument.Handle, Bm),
      ALevel + 1, AList);
    Bm := FPDFBookmark_GetNextSibling(ADocument.Handle, Bm);
  end;
end;

function CollectPdfBookmarks(ADocument: TPdfDocument): TFb2PdfBookmarks;
begin
  Result := TFb2PdfBookmarks.Create;
  if (ADocument = nil) or not ADocument.Active then
    Exit;
  try
    WalkBookmarks(ADocument, FPDFBookmark_GetFirstChild(ADocument.Handle, nil),
      0, Result);
  except
    { Битые закладки не должны ломать открытие документа: отдаём пустой список. }
    FreeAndNil(Result);
    Result := TFb2PdfBookmarks.Create;
  end;
end;

{ ===================== Помощники для TTreeView ===================== }

procedure FillBookmarkTree(ATree: TCustomTreeView; ABookmarks: TFb2PdfBookmarks);
var
  I, Lvl: Integer;
  Parents: array of TTreeNode;
  Bm: TFb2PdfBookmark;
  Node: TTreeNode;
begin
  if ATree = nil then
    Exit;
  ATree.Items.BeginUpdate;
  try
    ATree.Items.Clear;
    if ABookmarks = nil then
      Exit;
    SetLength(Parents, 0);
    for I := 0 to ABookmarks.Count - 1 do
    begin
      Bm := ABookmarks.Item(I);
      Lvl := Bm.Level;
      if Lvl < 0 then
        Lvl := 0;
      { Пропуск уровня не допускаем: pdfium такого не отдаёт, но данные могут
        быть битыми. }
      if Lvl > Length(Parents) then
        Lvl := Length(Parents);
      SetLength(Parents, Lvl + 1);

      if Lvl = 0 then
        Node := ATree.Items.AddChild(nil, UTF8Encode(Bm.Title))
      else
        Node := ATree.Items.AddChild(Parents[Lvl - 1], UTF8Encode(Bm.Title));
      Node.Data := Bm;
      Parents[Lvl] := Node;
    end;
  finally
    ATree.Items.EndUpdate;
  end;
end;

function FindBookmarkNode(ATree: TCustomTreeView; APageIndex: Integer): TTreeNode;
var
  I: Integer;
  Node: TTreeNode;
  Bm: TFb2PdfBookmark;
  Best, First: TTreeNode;
  BestPage: Integer;
begin
  Result := nil;
  if (ATree = nil) or (ATree.Items.Count = 0) then
    Exit;
  Best := nil;
  First := nil;
  BestPage := -1;
  for I := 0 to ATree.Items.Count - 1 do
  begin
    Node := ATree.Items[I];
    if not (TObject(Node.Data) is TFb2PdfBookmark) then
      Continue;
    Bm := TFb2PdfBookmark(Node.Data);
    if Bm.PageIndex < 0 then
      Continue;
    if First = nil then
      First := Node;
    { Закладка «не позже» текущей страницы с максимальным номером — это и есть
      текущий раздел. Из нескольких закладок на одной странице берём ПЕРВУЮ
      (верхнюю): «Chapter 2» должна подсвечиваться раньше, чем «Section 2.1»,
      которая начинается ниже на той же странице. }
    if (Bm.PageIndex <= APageIndex) and (Bm.PageIndex > BestPage) then
    begin
      Best := Node;
      BestPage := Bm.PageIndex;
    end;
  end;
  if Best <> nil then
    Result := Best
  else
    Result := First;
end;

end.

