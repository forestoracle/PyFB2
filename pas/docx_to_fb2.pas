unit docx_to_fb2;
{ Преобразование документа Word (DOCX) в FictionBook (FB2) — перевод docx_to_fb2.py.

  Класс TDocxToFb2Converter читает DOCX (архив Office Open XML) без внешних
  зависимостей и собирает структуры FB2, после чего сериализует их в XML
  FictionBook 2.0 (через TFb2Writer). XML разбирается через fcl-xml (DOM).

  Что поддерживается:
      * метаданные docProps/core.xml -> <title-info>/<document-info>;
      * стили Heading1-Heading6 -> иерархия <section>/<title>;
      * абзацы с разметкой (bold/italic/strike/sub/sup/code), гиперссылки
        <w:hyperlink>, встроенные изображения <w:drawing>;
      * таблицы <w:tbl> -> <table>;
      * изображения word/media/* -> <binary> (base64).

  Пример:
      C := TDocxToFb2Converter.Create;
      try
        C.Write('book.docx', 'book.fb2');
      finally
        C.Free;
      end; }

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Classes, SysUtils, fgl, DOM, XMLRead,
  fb2_structures, fb2_writer, fb2_errors, fb2_archive;

const
  { Пространства имён OOXML. }
  NS_W = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
  NS_R = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';

  { Жанр по умолчанию (если в DOCX нет подходящих метаданных). }
  DEFAULT_GENRE = 'prose';
  DEFAULT_PROGRAM_USED = 'pyFB2';

type
  { Кадр стека секций при разборе заголовков. }
  TSectionFrame = record
    Level: Integer;
    Sec: TSection;
  end;

  TSectionStack = array of TSectionFrame;

  { Метаданные, прочитанные из docProps/core.xml. }
  TDocxMeta = class
  public
    Title: UnicodeString;
    Language: UnicodeString;
    Description: UnicodeString;
    Identifier: UnicodeString;
    Date: UnicodeString;
    Creators: TTextList;
    Subjects: TTextList;
    constructor Create;
    destructor Destroy; override;
  end;

  { Преобразование DOCX в структуры FB2 и XML. }
  TDocxToFb2Converter = class
  private
    FWriter: TFb2Writer;
    FDefaultGenre: UnicodeString;
    FProgramUsed: UnicodeString;
    FSource: UnicodeString;
    FBook: TFictionBook;
    FZip: TEpubArchive;
    FRels: TStringList;              { rId -> target }
    FDefaultContentTypes: TStringList; { extension -> content-type }
    FBinaries: TFb2ObjectList;       { список TBinary }
    FUsedIds: TStringList;           { занятые XML-ID }
    FRidToFb2Id: TStringList;        { rId -> fb2 id }
    FTitleOverride: UnicodeString;
    FParseDocs: TList;               { TXMLDocument, разобранные за один Convert }

    procedure Reset;
    function ReadZip(const Name: UnicodeString): TBytes;
    function ParseBytes(const Data: TBytes): TXMLDocument;
    function ReadDocument: TDOMElement;
    function FindBody(Root: TDOMElement): TDOMElement;
    procedure LoadRels;
    procedure LoadContentTypes;
    function ReadCoreMetadata: TDocxMeta;

    function ConvertBody(BodyElem: TDOMElement): TBody;
    procedure HandleParagraph(P: TDOMElement; var Stack: TSectionStack;
      var StackLen: Integer);
    function ConvertTable(Tbl: TDOMElement): TTable;
    function CellNodes(Tc: TDOMElement): TFb2ObjectList;
    function ParagraphStyle(P: TDOMElement): UnicodeString;
    function HeadingLevel(const Style: UnicodeString): Integer;
    function ParagraphNodes(P: TDOMElement): TFb2ObjectList;
    function RunNode(R: TDOMElement): TStyleNode;
    function RunProps(R: TDOMElement): TTextList;
    function HyperlinkTarget(Hyperlink: TDOMElement): UnicodeString;
    function DrawingImage(Drawing: TDOMElement): UnicodeString;
    function HasDrawing(P: TDOMElement): Boolean;
    function NodesText(Nodes: TFb2ObjectList): UnicodeString;

    function ImageHrefForRid(const RelId: UnicodeString): UnicodeString;
    function ContentTypeFor(const Target: UnicodeString): UnicodeString;
    function AllocateImageId(const Target: UnicodeString): UnicodeString;

    function SplitAuthor(const Name: UnicodeString): TAuthor;
    function GenresOf(Meta: TDocxMeta): TTextList;
    function AnnotationOf(Meta: TDocxMeta): TAnnotation;
    function Assemble(Meta: TDocxMeta; Body: TBody): TFictionBook;
  public
    constructor Create(AWriter: TFb2Writer = nil;
      const ADefaultGenre: UnicodeString = DEFAULT_GENRE;
      const AProgramUsed: UnicodeString = DEFAULT_PROGRAM_USED);
    destructor Destroy; override;

    { Прочитать DOCX и вернуть структуру TFictionBook (владелец — конвертер). }
    function Convert(const Source: UnicodeString = ''): TFictionBook;

    { Сериализовать книгу (или результат Convert) в XML FB2. }
    function ToXml(Book: TFictionBook = nil): UnicodeString;

    { Преобразовать DOCX в файл FB2 и вернуть путь к результату. }
    function Write(const Source: UnicodeString;
      const Output: UnicodeString = ''): UnicodeString;

    property Book: TFictionBook read FBook;
  end;

implementation

uses
  fb2_parser,   { LocalName }
  fb2_genres,   { GenreCodeExists, GenreCodeByName }
  fb2_files;    { WriteFileAtomic }

{ ===================== Служебные помощники ===================== }

const
  B64_ALPHABET =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

{ base64-кодирование байтов (аналог base64.b64encode). }
function Base64EncodeBytes(const Data: TBytes): UnicodeString;
var
  I, L: Integer;
  B0, B1, B2: Byte;
  Triple: LongWord;
begin
  Result := '';
  L := Length(Data);
  I := 0;
  while I < L do
  begin
    B0 := Data[I];
    if I + 1 < L then
      B1 := Data[I + 1]
    else
      B1 := 0;
    if I + 2 < L then
      B2 := Data[I + 2]
    else
      B2 := 0;
    Triple := (LongWord(B0) shl 16) or (LongWord(B1) shl 8) or LongWord(B2);
    Result := Result + B64_ALPHABET[(Triple shr 18) and $3F + 1];
    Result := Result + B64_ALPHABET[(Triple shr 12) and $3F + 1];
    if I + 1 < L then
      Result := Result + B64_ALPHABET[(Triple shr 6) and $3F + 1]
    else
      Result := Result + '=';
    if I + 2 < L then
      Result := Result + B64_ALPHABET[Triple and $3F + 1]
    else
      Result := Result + '=';
    Inc(I, 3);
  end;
end;

function LStripSlash(const S: UnicodeString): UnicodeString;
var
  I: Integer;
begin
  I := 1;
  while (I <= Length(S)) and (S[I] = '/') do
    Inc(I);
  Result := Copy(S, I, MaxInt);
end;

function SplitWords(const S: UnicodeString): TTextList;
var
  I: Integer;
  Cur: UnicodeString;
begin
  Result := TTextList.Create;
  Cur := '';
  for I := 1 to Length(S) do
  begin
    if Ord(S[I]) <= 32 then
    begin
      if Cur <> '' then
      begin
        Result.Add(Cur);
        Cur := '';
      end;
    end
    else
      Cur := Cur + S[I];
  end;
  if Cur <> '' then
    Result.Add(Cur);
end;

function TodayIso: UnicodeString;
begin
  Result := FormatDateTime('yyyy-mm-dd', Now);
end;

function NewUuidHex: UnicodeString;
var
  G: TGUID;
  S: UnicodeString;
  I: Integer;
begin
  CreateGUID(G);
  S := LowerCase(GUIDToString(G));
  Result := '';
  for I := 1 to Length(S) do
    if S[I] <> '-' then
      Result := Result + S[I];
end;

function MapGet(L: TStringList; const Key: UnicodeString): UnicodeString;
var
  I: Integer;
begin
  I := L.IndexOfName(Key);
  if I >= 0 then
    Result := L.ValueFromIndex[I]
  else
    Result := '';
end;

procedure MapSet(L: TStringList; const Key, Value: UnicodeString);
var
  I: Integer;
begin
  I := L.IndexOfName(Key);
  if I >= 0 then
    L[I] := Key + '=' + Value
  else
    L.Add(Key + '=' + Value);
end;

{ Переместить объекты из Src в Dest без освобождения (Src нужно освободить). }
procedure MoveList(Dest, Src: TFb2ObjectList);
var
  I: Integer;
begin
  for I := 0 to Src.Count - 1 do
    Dest.Add(Src[I]);
  Src.FreeObjects := False;
end;

function ContentTypeByExt(const Ext: UnicodeString): UnicodeString;
begin
  if Ext = '.jpg' then
    Result := 'image/jpeg'
  else if Ext = '.jpeg' then
    Result := 'image/jpeg'
  else if Ext = '.png' then
    Result := 'image/png'
  else if Ext = '.gif' then
    Result := 'image/gif'
  else if Ext = '.svg' then
    Result := 'image/svg+xml'
  else if Ext = '.webp' then
    Result := 'image/webp'
  else if Ext = '.bmp' then
    Result := 'image/bmp'
  else if Ext = '.tif' then
    Result := 'image/tiff'
  else if Ext = '.tiff' then
    Result := 'image/tiff'
  else
    Result := 'application/octet-stream';
end;

function LeadingText(E: TDOMNode): UnicodeString;
begin
  Result := '';
  if (E <> nil) and (E.FirstChild <> nil) and
    (E.FirstChild.NodeType = TEXT_NODE) then
    Result := E.FirstChild.NodeValue;
end;

function FindChildElem(Parent: TDOMNode; const Local: UnicodeString): TDOMElement;
var
  C: TDOMNode;
begin
  Result := nil;
  if Parent = nil then
    Exit;
  C := Parent.FirstChild;
  while C <> nil do
  begin
    if (C.NodeType = ELEMENT_NODE) and
      (LocalName(TDOMElement(C).TagName) = Local) then
      Exit(TDOMElement(C));
    C := C.NextSibling;
  end;
end;

function FindInSubtree(N: TDOMNode; const Local: UnicodeString): TDOMElement;
var
  C: TDOMNode;
  R: TDOMElement;
begin
  Result := nil;
  if N = nil then
    Exit;
  if (N.NodeType = ELEMENT_NODE) and
    (LocalName(TDOMElement(N).TagName) = Local) then
    Exit(TDOMElement(N));
  C := N.FirstChild;
  while C <> nil do
  begin
    R := FindInSubtree(C, Local);
    if R <> nil then
      Exit(R);
    C := C.NextSibling;
  end;
end;

function GetWAttr(E: TDOMElement; const Name: UnicodeString): UnicodeString;
begin
  Result := '';
  if E = nil then
    Exit;
  try
    Result := E.GetAttributeNS(NS_W, Name);
  except
    Result := '';
  end;
  if Result = '' then
    Result := E.GetAttribute('w:' + Name);
  if Result = '' then
    Result := E.GetAttribute(Name);
end;

function GetRAttr(E: TDOMElement; const Name: UnicodeString): UnicodeString;
begin
  Result := '';
  if E = nil then
    Exit;
  try
    Result := E.GetAttributeNS(NS_R, Name);
  except
    Result := '';
  end;
  if Result = '' then
    Result := E.GetAttribute('r:' + Name);
  if Result = '' then
    Result := E.GetAttribute(Name);
end;

{ ===================== TDocxMeta ===================== }

constructor TDocxMeta.Create;
begin
  inherited Create;
  Title := '';
  Language := '';
  Description := '';
  Identifier := '';
  Date := '';
  Creators := TTextList.Create;
  Subjects := TTextList.Create;
end;

destructor TDocxMeta.Destroy;
begin
  FreeAndNil(Creators);
  FreeAndNil(Subjects);
  inherited Destroy;
end;

{ Обойти docProps/core.xml (аналог root.iter() в _read_core_metadata). }
procedure WalkCoreMeta(N: TDOMNode; Meta: TDocxMeta);
var
  C: TDOMNode;
  Local, Text: UnicodeString;
begin
  if N = nil then
    Exit;
  if N.NodeType = ELEMENT_NODE then
  begin
    Local := LocalName(TDOMElement(N).TagName);
    Text := UTrim(LeadingText(N));
    if Text <> '' then
    begin
      if Local = 'title' then
        Meta.Title := Text
      else if Local = 'creator' then
        Meta.Creators.Add(Text)
      else if Local = 'language' then
        Meta.Language := Text
      else if Local = 'description' then
        Meta.Description := Text
      else if Local = 'subject' then
        Meta.Subjects.Add(Text)
      else if Local = 'identifier' then
        Meta.Identifier := Text
      else if Local = 'date' then
        Meta.Date := Text;
    end;
  end;
  C := N.FirstChild;
  while C <> nil do
  begin
    WalkCoreMeta(C, Meta);
    C := C.NextSibling;
  end;
end;

{ ===================== TDocxToFb2Converter ===================== }

constructor TDocxToFb2Converter.Create(AWriter: TFb2Writer;
  const ADefaultGenre: UnicodeString; const AProgramUsed: UnicodeString);
begin
  inherited Create;
  if AWriter <> nil then
    FWriter := AWriter
  else
    FWriter := TFb2Writer.Create;
  FDefaultGenre := ADefaultGenre;
  FProgramUsed := AProgramUsed;
  FSource := '';
  FBook := nil;
  FZip := nil;
  FRels := nil;
  FDefaultContentTypes := nil;
  FBinaries := nil;
  FUsedIds := nil;
  FRidToFb2Id := nil;
  FParseDocs := nil;
  FTitleOverride := '';
  Reset;
end;

destructor TDocxToFb2Converter.Destroy;
var
  I: Integer;
begin
  FreeAndNil(FBook);
  if FParseDocs <> nil then
  begin
    for I := 0 to FParseDocs.Count - 1 do
      TObject(FParseDocs[I]).Free;
    FreeAndNil(FParseDocs);
  end;
  FreeAndNil(FRels);
  FreeAndNil(FDefaultContentTypes);
  FreeAndNil(FBinaries);
  FreeAndNil(FUsedIds);
  FreeAndNil(FRidToFb2Id);
  FreeAndNil(FWriter);
  inherited Destroy;
end;

procedure TDocxToFb2Converter.Reset;
var
  I: Integer;
begin
  FreeAndNil(FBook);
  FreeAndNil(FRels);
  FRels := TStringList.Create;
  FRels.CaseSensitive := True;
  FRels.NameValueSeparator := '=';
  FreeAndNil(FDefaultContentTypes);
  FDefaultContentTypes := TStringList.Create;
  FDefaultContentTypes.CaseSensitive := True;
  FDefaultContentTypes.NameValueSeparator := '=';
  FreeAndNil(FBinaries);
  FBinaries := TFb2ObjectList.Create;
  FreeAndNil(FUsedIds);
  FUsedIds := TStringList.Create;
  FUsedIds.CaseSensitive := True;
  FreeAndNil(FRidToFb2Id);
  FRidToFb2Id := TStringList.Create;
  FRidToFb2Id.CaseSensitive := True;
  FRidToFb2Id.NameValueSeparator := '=';
  if FParseDocs <> nil then
  begin
    for I := 0 to FParseDocs.Count - 1 do
      TObject(FParseDocs[I]).Free;
    FreeAndNil(FParseDocs);
  end;
  FParseDocs := TList.Create;
  FTitleOverride := '';
end;

{ ===================== Чтение DOCX-архива ===================== }

function TDocxToFb2Converter.ReadZip(const Name: UnicodeString): TBytes;
begin
  SetLength(Result, 0);
  if (FZip <> nil) and FZip.Has(Name) then
    Result := FZip.Read(Name);
end;

function TDocxToFb2Converter.ParseBytes(const Data: TBytes): TXMLDocument;
var
  MS: TMemoryStream;
begin
  Result := nil;
  MS := TMemoryStream.Create;
  try
    if Length(Data) > 0 then
      MS.WriteBuffer(Data[0], Length(Data));
    MS.Position := 0;
    ReadXMLFile(Result, MS);
  finally
    MS.Free;
  end;
end;

function TDocxToFb2Converter.ReadDocument: TDOMElement;
var
  Data: TBytes;
  Doc: TXMLDocument;
begin
  Data := ReadZip('word/document.xml');
  if Length(Data) = 0 then
    raise EFb2ConversionError.Create('DOCX не содержит word/document.xml');
  try
    Doc := ParseBytes(Data);
  except
    raise EFb2ConversionError.Create('Не удалось разобрать word/document.xml');
  end;
  FParseDocs.Add(Doc);
  Result := Doc.DocumentElement;
  if Result = nil then
    raise EFb2ConversionError.Create('Не удалось разобрать word/document.xml');
end;

function TDocxToFb2Converter.FindBody(Root: TDOMElement): TDOMElement;
begin
  Result := FindInSubtree(Root, 'body');
end;

procedure TDocxToFb2Converter.LoadRels;
var
  Data: TBytes;
  Doc: TXMLDocument;
  Root: TDOMElement;
  C: TDOMNode;
  E: TDOMElement;
  RelId, Target: UnicodeString;
begin
  Data := ReadZip('word/_rels/document.xml.rels');
  if Length(Data) = 0 then
    Exit;
  Doc := ParseBytes(Data);
  FParseDocs.Add(Doc);
  Root := Doc.DocumentElement;
  if Root = nil then
    Exit;
  C := Root.FirstChild;
  while C <> nil do
  begin
    if C.NodeType = ELEMENT_NODE then
    begin
      E := TDOMElement(C);
      if LocalName(E.TagName) = 'Relationship' then
      begin
        RelId := E.GetAttribute('Id');
        Target := E.GetAttribute('Target');
        if (RelId <> '') and (Target <> '') then
          MapSet(FRels, RelId, Target);
      end;
    end;
    C := C.NextSibling;
  end;
end;

procedure TDocxToFb2Converter.LoadContentTypes;
var
  Data: TBytes;
  Doc: TXMLDocument;
  Root: TDOMElement;
  C: TDOMNode;
  E: TDOMElement;
  Ext, CT: UnicodeString;
begin
  Data := ReadZip('[Content_Types].xml');
  if Length(Data) = 0 then
    Exit;
  Doc := ParseBytes(Data);
  FParseDocs.Add(Doc);
  Root := Doc.DocumentElement;
  if Root = nil then
    Exit;
  C := Root.FirstChild;
  while C <> nil do
  begin
    if C.NodeType = ELEMENT_NODE then
    begin
      E := TDOMElement(C);
      if LocalName(E.TagName) = 'Default' then
      begin
        Ext := LowerCase(E.GetAttribute('Extension'));
        CT := E.GetAttribute('ContentType');
        if (Ext <> '') and (CT <> '') then
          MapSet(FDefaultContentTypes, Ext, CT);
      end;
    end;
    C := C.NextSibling;
  end;
end;

function TDocxToFb2Converter.ReadCoreMetadata: TDocxMeta;
var
  Data: TBytes;
  Doc: TXMLDocument;
begin
  Result := TDocxMeta.Create;
  Data := ReadZip('docProps/core.xml');
  if Length(Data) = 0 then
    Exit;
  Doc := ParseBytes(Data);
  FParseDocs.Add(Doc);
  WalkCoreMeta(Doc.DocumentElement, Result);
end;

{ ===================== Разбор содержимого ===================== }

function TDocxToFb2Converter.ConvertBody(BodyElem: TDOMElement): TBody;
var
  Root: TSection;
  Stack: TSectionStack;
  StackLen: Integer;
  C: TDOMNode;
  Local: UnicodeString;
  Table: TTable;
  Sec: TSection;
begin
  Result := TBody.Create;
  Root := TSection.Create;
  SetLength(Stack, 4);
  Stack[0].Level := 0;
  Stack[0].Sec := Root;
  StackLen := 1;

  C := BodyElem.FirstChild;
  while C <> nil do
  begin
    if C.NodeType = ELEMENT_NODE then
    begin
      Local := LocalName(TDOMElement(C).TagName);
      if Local = 'p' then
        HandleParagraph(TDOMElement(C), Stack, StackLen)
      else if Local = 'tbl' then
      begin
        Table := ConvertTable(TDOMElement(C));
        if Table <> nil then
          Stack[StackLen - 1].Sec.Content.Add(Table);
      end;
    end;
    C := C.NextSibling;
  end;

  FreeAndNil(Result.Sections);
  Result.Sections := Root.Sections;
  Root.Sections := nil;
  if Root.Content.Count > 0 then
  begin
    Sec := TSection.Create;
    FreeAndNil(Sec.Content);
    Sec.Content := Root.Content;
    Root.Content := nil;
    Result.Sections.Insert(0, Sec);
  end;
  if Result.Sections.Count = 0 then
    Result.Sections.Add(TSection.Create);
  Root.Free;
end;

procedure TDocxToFb2Converter.HandleParagraph(P: TDOMElement;
  var Stack: TSectionStack; var StackLen: Integer);
var
  Style, Text: UnicodeString;
  Nodes: TFb2ObjectList;
  Level: Integer;
  NewSec: TSection;
  Par: TParagraph;
  Sub: TSubtitle;
  Cite: TCite;
begin
  Style := ParagraphStyle(P);
  Nodes := ParagraphNodes(P);

  if Pos('Heading', Style) = 1 then
  begin
    Level := HeadingLevel(Style);
    while (StackLen > 1) and (Stack[StackLen - 1].Level >= Level) do
      Dec(StackLen);
    NewSec := TSection.Create;
    Par := TParagraph.Create;
    FreeAndNil(Par.Content);
    Par.Content := Nodes;
    NewSec.Title := TTitle.Create;
    NewSec.Title.Items.Add(Par);
    Stack[StackLen - 1].Sec.Sections.Add(NewSec);
    if StackLen = Length(Stack) then
      SetLength(Stack, StackLen * 2);
    Stack[StackLen].Level := Level;
    Stack[StackLen].Sec := NewSec;
    Inc(StackLen);
    Exit;
  end;

  if Style = 'Title' then
  begin
    Text := NodesText(Nodes);
    if Text <> '' then
      FTitleOverride := Text;
    Nodes.Free;
    Exit;
  end;

  if (Nodes.Count = 0) and (not HasDrawing(P)) then
  begin
    Nodes.Free;
    Exit;
  end;

  if Style = 'Subtitle' then
  begin
    Sub := TSubtitle.Create;
    FreeAndNil(Sub.Content);
    Sub.Content := Nodes;
    Stack[StackLen - 1].Sec.Content.Add(Sub);
  end
  else if Style = 'Quote' then
  begin
    Par := TParagraph.Create;
    FreeAndNil(Par.Content);
    Par.Content := Nodes;
    Cite := TCite.Create;
    Cite.Items.Add(Par);
    Stack[StackLen - 1].Sec.Content.Add(Cite);
  end
  else
  begin
    Par := TParagraph.Create;
    FreeAndNil(Par.Content);
    Par.Content := Nodes;
    Stack[StackLen - 1].Sec.Content.Add(Par);
  end;
end;

function TDocxToFb2Converter.ConvertTable(Tbl: TDOMElement): TTable;
var
  RowIndex: Integer;
  C, CC: TDOMNode;
  Cells: TFb2ObjectList;
  Row: TTableRow;
  Cell: TTableCell;
begin
  Result := TTable.Create;
  RowIndex := 0;
  C := Tbl.FirstChild;
  while C <> nil do
  begin
    if (C.NodeType = ELEMENT_NODE) and
      (LocalName(TDOMElement(C).TagName) = 'tr') then
    begin
      Cells := TFb2ObjectList.Create;
      CC := C.FirstChild;
      while CC <> nil do
      begin
        if (CC.NodeType = ELEMENT_NODE) and
          (LocalName(TDOMElement(CC).TagName) = 'tc') then
        begin
          Cell := TTableCell.Create;
          Cell.Tag := 'td';
          FreeAndNil(Cell.Children);
          Cell.Children := CellNodes(TDOMElement(CC));
          Cell.IsHeader := (RowIndex = 0);
          Cells.Add(Cell);
        end;
        CC := CC.NextSibling;
      end;
      if Cells.Count > 0 then
      begin
        Row := TTableRow.Create;
        FreeAndNil(Row.Cells);
        Row.Cells := Cells;
        Result.Rows.Add(Row);
      end
      else
        Cells.Free;
      Inc(RowIndex);
    end;
    C := C.NextSibling;
  end;
  if Result.Rows.Count = 0 then
    FreeAndNil(Result);
end;

function TDocxToFb2Converter.CellNodes(Tc: TDOMElement): TFb2ObjectList;
var
  C: TDOMNode;
  Sub: TFb2ObjectList;
  SN: TStyleNode;
begin
  Result := TFb2ObjectList.Create;
  C := Tc.FirstChild;
  while C <> nil do
  begin
    if (C.NodeType = ELEMENT_NODE) and
      (LocalName(TDOMElement(C).TagName) = 'p') then
    begin
      if Result.Count > 0 then
      begin
        SN := TStyleNode.Create(TEXT_NODE_NAME);
        SN.Text := #10;
        Result.Add(SN);
      end;
      Sub := ParagraphNodes(TDOMElement(C));
      MoveList(Result, Sub);
      Sub.Free;
    end;
    C := C.NextSibling;
  end;
end;

function TDocxToFb2Converter.ParagraphStyle(P: TDOMElement): UnicodeString;
var
  Ppr, Pstyle: TDOMElement;
begin
  Ppr := FindChildElem(P, 'pPr');
  if Ppr = nil then
    Exit('Normal');
  Pstyle := FindChildElem(Ppr, 'pStyle');
  if Pstyle = nil then
    Exit('Normal');
  Result := GetWAttr(Pstyle, 'val');
  if Result = '' then
    Result := 'Normal';
end;

function TDocxToFb2Converter.HeadingLevel(const Style: UnicodeString): Integer;
var
  Digits: UnicodeString;
  I, Level: Integer;
begin
  Digits := '';
  for I := 1 to Length(Style) do
    if (Style[I] >= '0') and (Style[I] <= '9') then
      Digits := Digits + Style[I];
  Level := StrToIntDef(Digits, -1);
  if Level < 0 then
    Exit(1);
  if Level < 1 then
    Level := 1;
  if Level > 6 then
    Level := 6;
  Result := Level;
end;

function TDocxToFb2Converter.ParagraphNodes(P: TDOMElement): TFb2ObjectList;
var
  C, CC: TDOMNode;
  Local, Href: UnicodeString;
  Node: TStyleNode;
  Children: TFb2ObjectList;
  SN: TStyleNode;
begin
  Result := TFb2ObjectList.Create;
  C := P.FirstChild;
  while C <> nil do
  begin
    if C.NodeType = ELEMENT_NODE then
    begin
      Local := LocalName(TDOMElement(C).TagName);
      if Local = 'r' then
      begin
        Node := RunNode(TDOMElement(C));
        if Node <> nil then
          Result.Add(Node);
      end
      else if Local = 'hyperlink' then
      begin
        Href := HyperlinkTarget(TDOMElement(C));
        Children := TFb2ObjectList.Create;
        CC := C.FirstChild;
        while CC <> nil do
        begin
          if (CC.NodeType = ELEMENT_NODE) and
            (LocalName(TDOMElement(CC).TagName) = 'r') then
          begin
            Node := RunNode(TDOMElement(CC));
            if Node <> nil then
              Children.Add(Node);
          end;
          CC := CC.NextSibling;
        end;
        if Href <> '' then
        begin
          SN := TStyleNode.Create('a');
          SN.Href := Href;
          FreeAndNil(SN.Children);
          SN.Children := Children;
          Children := nil;
          Result.Add(SN);
        end
        else
          MoveList(Result, Children);
        Children.Free;
      end;
    end;
    C := C.NextSibling;
  end;
end;

function TDocxToFb2Converter.RunNode(R: TDOMElement): TStyleNode;
var
  Props: TTextList;
  TextParts: TTextList;
  C: TDOMNode;
  Local, Text, Href: UnicodeString;
  Node, Outer: TStyleNode;
  K: Integer;
begin
  Props := RunProps(R);
  TextParts := TTextList.Create;
  C := R.FirstChild;
  while C <> nil do
  begin
    if C.NodeType = ELEMENT_NODE then
    begin
      Local := LocalName(TDOMElement(C).TagName);
      if Local = 't' then
        TextParts.Add(LeadingText(C))
      else if Local = 'drawing' then
      begin
        Href := DrawingImage(TDOMElement(C));
        if Href <> '' then
        begin
          Result := TStyleNode.Create('image');
          Result.ImageHref := Href;
          TextParts.Free;
          Props.Free;
          Exit;
        end;
      end;
    end;
    C := C.NextSibling;
  end;
  Text := JoinText(TextParts, '');
  TextParts.Free;
  if Text = '' then
  begin
    Props.Free;
    Result := nil;
    Exit;
  end;
  Node := TStyleNode.Create(TEXT_NODE_NAME);
  Node.Text := Text;
  for K := 0 to Props.Count - 1 do
  begin
    Outer := TStyleNode.Create(Props[K]);
    Outer.Children.Add(Node);
    Node := Outer;
  end;
  Props.Free;
  Result := Node;
end;

function TDocxToFb2Converter.RunProps(R: TDOMElement): TTextList;
var
  Rpr, Vert, Rstyle: TDOMElement;
  V: UnicodeString;
begin
  Result := TTextList.Create;
  Rpr := FindChildElem(R, 'rPr');
  if Rpr = nil then
    Exit;
  if FindChildElem(Rpr, 'b') <> nil then
    Result.Add('strong');
  if FindChildElem(Rpr, 'i') <> nil then
    Result.Add('emphasis');
  if FindChildElem(Rpr, 'strike') <> nil then
    Result.Add('strikethrough');
  Vert := FindChildElem(Rpr, 'vertAlign');
  if Vert <> nil then
  begin
    V := GetWAttr(Vert, 'val');
    if V = 'subscript' then
      Result.Add('sub')
    else if V = 'superscript' then
      Result.Add('sup');
  end;
  Rstyle := FindChildElem(Rpr, 'rStyle');
  if (Rstyle <> nil) and (GetWAttr(Rstyle, 'val') = 'Code') then
    Result.Add('code');
end;

function TDocxToFb2Converter.HyperlinkTarget(Hyperlink: TDOMElement): UnicodeString;
var
  RelId: UnicodeString;
begin
  RelId := GetRAttr(Hyperlink, 'id');
  if RelId = '' then
    Exit('');
  Result := MapGet(FRels, RelId);
end;

function TDocxToFb2Converter.DrawingImage(Drawing: TDOMElement): UnicodeString;
var
  Blip: TDOMElement;
  Embed: UnicodeString;
begin
  Blip := FindInSubtree(Drawing, 'blip');
  if Blip = nil then
    Exit('');
  Embed := GetRAttr(Blip, 'embed');
  if Embed = '' then
    Exit('');
  Result := ImageHrefForRid(Embed);
end;

function TDocxToFb2Converter.HasDrawing(P: TDOMElement): Boolean;
begin
  Result := FindInSubtree(P, 'drawing') <> nil;
end;

function TDocxToFb2Converter.ImageHrefForRid(const RelId: UnicodeString): UnicodeString;
var
  Existing, Target, ContentType, Fb2Id: UnicodeString;
  Data: TBytes;
  Bin: TBinary;
begin
  Existing := MapGet(FRidToFb2Id, RelId);
  if Existing <> '' then
    Exit('#' + Existing);
  Target := MapGet(FRels, RelId);
  if Target = '' then
    Exit('');
  Data := ReadZip('word/' + LStripSlash(Target));
  if Length(Data) = 0 then
    Exit('');
  ContentType := ContentTypeFor(Target);
  Fb2Id := AllocateImageId(Target);
  Bin := TBinary.Create;
  Bin.Id := Fb2Id;
  Bin.ContentType := ContentType;
  Bin.Data := Base64EncodeBytes(Data);
  FBinaries.Add(Bin);
  MapSet(FRidToFb2Id, RelId, Fb2Id);
  Result := '#' + Fb2Id;
end;

function TDocxToFb2Converter.ContentTypeFor(const Target: UnicodeString): UnicodeString;
var
  I, P: Integer;
  Ext: UnicodeString;
begin
  P := 0;
  for I := Length(Target) downto 1 do
    if Target[I] = '.' then
    begin
      P := I;
      Break;
    end;
  if P > 0 then
    Ext := LowerCase(Copy(Target, P + 1, MaxInt))
  else
    Ext := '';
  if MapGet(FDefaultContentTypes, Ext) <> '' then
    Exit(MapGet(FDefaultContentTypes, Ext));
  Result := ContentTypeByExt('.' + Ext);
end;

function TDocxToFb2Converter.AllocateImageId(const Target: UnicodeString): UnicodeString;
var
  Base, S, Candidate: UnicodeString;
  I, Counter: Integer;
  C: WideChar;
begin
  Base := ChangeFileExt(ExtractFileName(Target), '');
  S := '';
  for I := 1 to Length(Base) do
  begin
    C := Base[I];
    if ((C >= 'A') and (C <= 'Z')) or ((C >= 'a') and (C <= 'z')) or
      ((C >= '0') and (C <= '9')) or (C = '_') or (C = '.') or (C = '-') then
      S := S + C
    else
      S := S + '_';
  end;
  Base := S;
  if Base = '' then
    Base := 'image';
  C := Base[1];
  if not (((C >= 'A') and (C <= 'Z')) or ((C >= 'a') and (C <= 'z')) or
    (C = '_')) then
    Base := 'image_' + Base;
  Candidate := Base;
  Counter := 1;
  while FUsedIds.IndexOf(Candidate) >= 0 do
  begin
    Inc(Counter);
    Candidate := Base + '_' + IntToStr(Counter);
  end;
  FUsedIds.Add(Candidate);
  Result := Candidate;
end;

function TDocxToFb2Converter.SplitAuthor(const Name: UnicodeString): TAuthor;
var
  N, Last, First, Mid: UnicodeString;
  P, I: Integer;
  Words: TTextList;
begin
  N := UTrim(Name);
  if Pos(',', N) > 0 then
  begin
    P := Pos(',', N);
    Last := UTrim(Copy(N, 1, P - 1));
    First := UTrim(Copy(N, P + 1, MaxInt));
    Result := TAuthor.Create;
    Result.LastName := Last;
    if First <> '' then
      Result.FirstName := First;
    Exit;
  end;
  Words := SplitWords(N);
  try
    if Words.Count = 1 then
    begin
      Result := TAuthor.Create;
      Result.LastName := Words[0];
    end
    else if Words.Count = 2 then
    begin
      Result := TAuthor.Create;
      Result.FirstName := Words[0];
      Result.LastName := Words[1];
    end
    else if Words.Count = 0 then
    begin
      Result := TAuthor.Create;
      Result.Nickname := N;
    end
    else
    begin
      Result := TAuthor.Create;
      Result.FirstName := Words[0];
      Result.LastName := Words[Words.Count - 1];
      Mid := '';
      for I := 1 to Words.Count - 2 do
      begin
        if I > 1 then
          Mid := Mid + ' ';
        Mid := Mid + Words[I];
      end;
      Result.MiddleName := Mid;
    end;
  finally
    Words.Free;
  end;
end;

{ ===================== Сборка FictionBook ===================== }

function TDocxToFb2Converter.GenresOf(Meta: TDocxMeta): TTextList;
var
  I: Integer;
  S, Code: UnicodeString;
begin
  Result := TTextList.Create;
  for I := 0 to Meta.Subjects.Count - 1 do
  begin
    S := UTrim(Meta.Subjects[I]);
    if S = '' then
      Continue;
    if GenreCodeExists(S) then
      Result.Add(S)
    else
    begin
      Code := GenreCodeByName(S);
      if Code <> '' then
        Result.Add(Code);
    end;
  end;
  if Result.Count = 0 then
    Result.Add(FDefaultGenre);
end;

function TDocxToFb2Converter.AnnotationOf(Meta: TDocxMeta): TAnnotation;
var
  P: TParagraph;
  SN: TStyleNode;
begin
  if Meta.Description = '' then
    Exit(nil);
  Result := TAnnotation.Create;
  P := TParagraph.Create;
  SN := TStyleNode.Create(TEXT_NODE_NAME);
  SN.Text := Meta.Description;
  P.Content.Add(SN);
  Result.Items.Add(P);
end;

function TDocxToFb2Converter.Assemble(Meta: TDocxMeta; Body: TBody): TFictionBook;
var
  Desc: TDescription;
  TI: TTitleInfo;
  DI: TDocumentInfo;
  Title, Lang: UnicodeString;
  I: Integer;
  Genres: TTextList;
  A: TAuthor;
  G: TGenre;
begin
  Title := Meta.Title;
  if Title = '' then
    Title := FTitleOverride;
  if Title = '' then
    Title := 'Untitled';

  Result := TFictionBook.Create;
  Desc := TDescription.Create;
  Result.Description := Desc;
  TI := TTitleInfo.Create;
  Desc.TitleInfo := TI;

  Genres := GenresOf(Meta);
  try
    for I := 0 to Genres.Count - 1 do
    begin
      G := TGenre.Create;
      G.Value := Genres[I];
      TI.Genres.Add(G);
    end;
  finally
    Genres.Free;
  end;

  for I := 0 to Meta.Creators.Count - 1 do
    TI.Authors.Add(SplitAuthor(Meta.Creators[I]));

  TI.BookTitle := TTextField.Create;
  TI.BookTitle.Value := Title;
  TI.Annotation := AnnotationOf(Meta);

  Lang := Meta.Language;
  if Lang = '' then
    Lang := 'ru';
  TI.Lang := Lang;

  DI := TDocumentInfo.Create;
  Desc.DocumentInfo := DI;
  A := TAuthor.Create;
  A.Nickname := 'pyFB2';
  DI.Authors.Add(A);
  DI.ProgramUsed := TTextField.Create;
  DI.ProgramUsed.Value := FProgramUsed;
  DI.Date := TDateField.Create;
  DI.Date.Value := Meta.Date;
  if DI.Date.Value = '' then
    DI.Date.Value := TodayIso;
  DI.Id := Meta.Identifier;
  if DI.Id = '' then
    DI.Id := NewUuidHex;
  DI.Version := 1.0;
  DI.HasVersion := True;

  Result.Bodies.Add(Body);
  for I := 0 to FBinaries.Count - 1 do
    Result.Binaries.Add(FBinaries[I]);
  FBinaries.FreeObjects := False;
  FBinaries.Clear;
end;

{ ===================== Публичный API ===================== }

function TDocxToFb2Converter.Convert(const Source: UnicodeString): TFictionBook;
var
  Meta: TDocxMeta;
  DocRoot, BodyElem: TDOMElement;
  Body: TBody;
begin
  if Source <> '' then
    FSource := Source;
  if FSource = '' then
    raise EFb2ConversionError.Create('Не задан источник DOCX (source)');

  Reset;
  FZip := TEpubArchive.Create;
  try
    FZip.LoadFromFile(FSource);
    LoadRels;
    LoadContentTypes;
    Meta := ReadCoreMetadata;
    try
      DocRoot := ReadDocument;
      BodyElem := FindBody(DocRoot);
      if BodyElem = nil then
        raise EFb2ConversionError.Create('В DOCX не найден элемент <w:body>');
      Body := ConvertBody(BodyElem);
      FBook := Assemble(Meta, Body);
      Result := FBook;
    finally
      Meta.Free;
    end;
  finally
    FreeAndNil(FZip);
  end;
end;

function TDocxToFb2Converter.ToXml(Book: TFictionBook): UnicodeString;
begin
  if Book = nil then
    Book := FBook;
  if Book = nil then
    Book := Convert;
  Result := FWriter.ToXML(Book);
end;

function TDocxToFb2Converter.Write(const Source: UnicodeString;
  const Output: UnicodeString): UnicodeString;
var
  Bk: TFictionBook;
  Xml: UnicodeString;
  Target: UnicodeString;
begin
  Bk := Convert(Source);
  Xml := ToXml(Bk);
  if Output <> '' then
    Target := Output
  else if FSource <> '' then
    Target := ChangeFileExt(FSource, '.fb2')
  else
    Target := 'book.fb2';
  WriteFileAtomic(Target, TEncoding.UTF8.GetBytes(Xml));
  Result := Target;
end;

function TDocxToFb2Converter.NodesText(Nodes: TFb2ObjectList): UnicodeString;
var
  I: Integer;
  Node: TStyleNode;
begin
  Result := '';
  if Nodes = nil then
    Exit;
  for I := 0 to Nodes.Count - 1 do
  begin
    Node := TStyleNode(Nodes[I]);
    if Node.Tag = TEXT_NODE_NAME then
      Result := Result + Node.Text
    else
      Result := Result + NodesText(Node.Children);
  end;
end;

end.
