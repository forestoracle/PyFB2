unit odt_to_fb2;
{ Преобразование OpenDocument Text (ODT) в книгу FB2 — перевод odt_to_fb2.py.

  Читает ODT-файл (ZIP-контейнер OpenDocument), переносит текст (заголовки,
  абзацы, разметку, таблицы, изображения) и метаданные (meta.xml) в структуры
  TFictionBook. XML разбирается через fcl-xml (DOM).

  Обратное преобразование к fb2_to_odt.pas.

  Пример:
      C := TOdtToFb2Converter.Create;
      try
        C.Write('book.odt', 'book.fb2');
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
  { Пространства имён ODF. }
  NS_OFFICE = 'urn:oasis:names:tc:opendocument:xmlns:office:1.0';
  NS_TEXT = 'urn:oasis:names:tc:opendocument:xmlns:text:1.0';
  NS_STYLE = 'urn:oasis:names:tc:opendocument:xmlns:style:1.0';
  NS_FO = 'urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0';
  NS_DRAW = 'urn:oasis:names:tc:opendocument:xmlns:drawing:1.0';
  NS_TABLE = 'urn:oasis:names:tc:opendocument:xmlns:table:1.0';
  NS_XLINK = 'http://www.w3.org/1999/xlink';
  NS_DC = 'http://purl.org/dc/elements/1.1/';

  { Распознаваемые стили абзацев ODT. }
  HEADER_TITLE_STYLE = 'Title';
  HEADER_AUTHOR_STYLE = 'Subtitle';
  HEADER_ANNOTATION_STYLE = 'Annotation';

  DEFAULT_GENRE = 'sf';
  DEFAULT_PROGRAM_USED = 'pyFB2';

type
  { Кадр стека секций при разборе заголовков. }
  TSectionFrame = record
    Level: Integer;
    Sec: TSection;
  end;

  TSectionStack = array of TSectionFrame;

  { Метаданные, прочитанные из meta.xml. }
  TOdtMeta = class
  public
    Title: UnicodeString;
    Language: UnicodeString;
    Description: UnicodeString;
    Date: UnicodeString;
    Creators: TTextList;
    Subjects: TTextList;
    constructor Create;
    destructor Destroy; override;
  end;

  { Преобразование ODT в FB2. }
  TOdtToFb2Converter = class
  private
    FWriter: TFb2Writer;
    FDefaultGenre: UnicodeString;
    FProgramUsed: UnicodeString;
    FSource: UnicodeString;
    FBook: TFictionBook;
    FZip: TEpubArchive;
    FTextStyles: TStringList;        { имя стиля -> флаги }
    FBinaries: TFb2ObjectList;       { список TBinary }
    FBinaryIds: TStringList;         { путь -> id в FB2 }
    FTitleOverride: UnicodeString;
    FCreatorsOverride: TTextList;
    FAnnotationOverride: TTextList;
    FCoverHref: UnicodeString;
    FInHeader: Boolean;
    FParseDocs: TList;

    procedure Reset;
    function ReadZip(const Name: UnicodeString): TBytes;
    function ParseBytes(const Data: TBytes): TXMLDocument;
    function ReadContent: TDOMElement;
    function ReadMeta: TOdtMeta;
    procedure LoadTextStyles(Root: TDOMElement);

    function ConvertBody(TextElem: TDOMElement): TBody;
    procedure HandleElement(Element: TDOMElement; var Stack: TSectionStack;
      var StackLen: Integer);
    procedure HandleList(Element: TDOMElement; var Stack: TSectionStack;
      var StackLen: Integer);
    procedure HandleHeading(Element: TDOMElement; var Stack: TSectionStack;
      var StackLen: Integer);
    procedure HandleParagraph(Element: TDOMElement; var Stack: TSectionStack;
      var StackLen: Integer);
    function ConvertTable(Table: TDOMElement): TTable;

    function InlineNodes(Element: TDOMElement;
      Flags: TStringList): TFb2ObjectList;
    function BlockImages(Element: TDOMElement): TFb2ObjectList;
    function FrameNode(Frame: TDOMElement): TStyleNode;
    function ImageHref(Frame: TDOMElement): UnicodeString;
    function RegisterBinary(const Href: UnicodeString): UnicodeString;

    function CreatorsOf(Meta: TOdtMeta): TTextList;
    function GenresOf(Meta: TOdtMeta): TTextList;
    function AnnotationOf(Meta: TOdtMeta): TAnnotation;
    function AnnotationItems(Meta: TOdtMeta): TFb2ObjectList;
    function Assemble(Meta: TOdtMeta; Body: TBody): TFictionBook;
  public
    constructor Create(AWriter: TFb2Writer = nil;
      const ADefaultGenre: UnicodeString = DEFAULT_GENRE;
      const AProgramUsed: UnicodeString = DEFAULT_PROGRAM_USED);
    destructor Destroy; override;

    { Прочитать ODT и вернуть структуру TFictionBook (владелец — конвертер). }
    function Convert(const Source: UnicodeString = ''): TFictionBook;

    { Сериализовать книгу (или результат Convert) в XML FB2. }
    function ToXml(Book: TFictionBook = nil): UnicodeString;

    { Преобразовать ODT в файл FB2 и вернуть путь к результату. }
    function Write(const Source: UnicodeString;
      const Output: UnicodeString = ''): UnicodeString;

    property Book: TFictionBook read FBook;
  end;

implementation

uses
  fb2_parser,   { LocalName }
  fb2_images,   { DetectImageType, ExtensionForMediaType }
  fb2_files;    { WriteFileAtomic }

{ ===================== Служебные помощники ===================== }

const
  B64_ALPHABET =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

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

{ Новый (пустой) набор флагов. }
function NewFlags: TStringList;
begin
  Result := TStringList.Create;
  Result.Sorted := True;
  Result.Duplicates := dupIgnore;
end;

{ Объединение наборов флагов (новый список). }
function FlagsUnion(A, B: TStringList): TStringList;
var
  I: Integer;
begin
  Result := NewFlags;
  if A <> nil then
    for I := 0 to A.Count - 1 do
      Result.Add(A[I]);
  if B <> nil then
    for I := 0 to B.Count - 1 do
      Result.Add(B[I]);
end;

{ Разность наборов флагов A - B (новый список). }
function FlagsDiff(A, B: TStringList): TStringList;
var
  I: Integer;
begin
  Result := NewFlags;
  if A = nil then
    Exit;
  for I := 0 to A.Count - 1 do
    if (B = nil) or (B.IndexOf(A[I]) < 0) then
      Result.Add(A[I]);
end;

function FlagsKey(A: TStringList): UnicodeString;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to A.Count - 1 do
  begin
    if I > 0 then
      Result := Result + ',';
    Result := Result + A[I];
  end;
end;

function FlagToTag(const Flag: UnicodeString): UnicodeString;
begin
  if Flag = 'strong' then
    Result := 'strong'
  else if Flag = 'emphasis' then
    Result := 'emphasis'
  else if Flag = 'strikethrough' then
    Result := 'strikethrough'
  else if Flag = 'sub' then
    Result := 'sub'
  else if Flag = 'sup' then
    Result := 'sup'
  else if Flag = 'code' then
    Result := 'code'
  else
    Result := '';
end;

{ Значение атрибута по пространству имён (с фолбэками). }
function GetNSAttr(E: TDOMElement; const NSURI, Local: UnicodeString): UnicodeString;
var
  Map: TDOMNamedNodeMap;
  Attr: TDOMNode;
  I: Integer;
begin
  Result := '';
  if E = nil then
    Exit;
  try
    Result := E.GetAttributeNS(NSURI, Local);
  except
    Result := '';
  end;
  if Result <> '' then
    Exit;
  Result := E.GetAttribute(Local);
  if Result <> '' then
    Exit;
  Map := E.Attributes;
  if Map <> nil then
    for I := 0 to Map.Length - 1 do
    begin
      Attr := Map[I];
      if (Attr <> nil) and (LocalName(Attr.NodeName) = Local) then
        Exit(Attr.NodeValue);
    end;
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

procedure MoveList(Dest, Src: TFb2ObjectList);
var
  I: Integer;
begin
  for I := 0 to Src.Count - 1 do
    Dest.Add(Src[I]);
  Src.FreeObjects := False;
end;

{ ===================== TOdtMeta ===================== }

constructor TOdtMeta.Create;
begin
  inherited Create;
  Title := '';
  Language := '';
  Description := '';
  Date := '';
  Creators := TTextList.Create;
  Subjects := TTextList.Create;
end;

destructor TOdtMeta.Destroy;
begin
  FreeAndNil(Creators);
  FreeAndNil(Subjects);
  inherited Destroy;
end;

{ ===================== TOdtToFb2Converter ===================== }

constructor TOdtToFb2Converter.Create(AWriter: TFb2Writer;
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
  FTextStyles := nil;
  FBinaries := nil;
  FBinaryIds := nil;
  FCreatorsOverride := nil;
  FAnnotationOverride := nil;
  FParseDocs := nil;
  Reset;
end;

destructor TOdtToFb2Converter.Destroy;
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
  FreeAndNil(FTextStyles);
  FreeAndNil(FBinaries);
  FreeAndNil(FBinaryIds);
  FreeAndNil(FCreatorsOverride);
  FreeAndNil(FAnnotationOverride);
  FreeAndNil(FWriter);
  inherited Destroy;
end;

procedure TOdtToFb2Converter.Reset;
var
  I: Integer;
begin
  FreeAndNil(FBook);
  FreeAndNil(FTextStyles);
  FTextStyles := TStringList.Create;
  FTextStyles.CaseSensitive := True;
  FTextStyles.NameValueSeparator := '=';
  FreeAndNil(FBinaries);
  FBinaries := TFb2ObjectList.Create;
  FreeAndNil(FBinaryIds);
  FBinaryIds := TStringList.Create;
  FBinaryIds.CaseSensitive := True;
  FBinaryIds.NameValueSeparator := '=';
  FreeAndNil(FCreatorsOverride);
  FCreatorsOverride := TTextList.Create;
  FreeAndNil(FAnnotationOverride);
  FAnnotationOverride := TTextList.Create;
  if FParseDocs <> nil then
  begin
    for I := 0 to FParseDocs.Count - 1 do
      TObject(FParseDocs[I]).Free;
    FreeAndNil(FParseDocs);
  end;
  FParseDocs := TList.Create;
  FTitleOverride := '';
  FCoverHref := '';
  FInHeader := True;
end;

{ ===================== Чтение архива ===================== }

function TOdtToFb2Converter.ReadZip(const Name: UnicodeString): TBytes;
begin
  SetLength(Result, 0);
  if (FZip <> nil) and FZip.Has(Name) then
    Result := FZip.Read(Name);
end;

function TOdtToFb2Converter.ParseBytes(const Data: TBytes): TXMLDocument;
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

function TOdtToFb2Converter.ReadContent: TDOMElement;
var
  Data: TBytes;
  Doc: TXMLDocument;
begin
  Data := ReadZip('content.xml');
  if Length(Data) = 0 then
    raise EFb2ConversionError.Create('ODT не содержит content.xml');
  try
    Doc := ParseBytes(Data);
  except
    raise EFb2ConversionError.Create('Не удалось разобрать content.xml');
  end;
  FParseDocs.Add(Doc);
  Result := Doc.DocumentElement;
  if Result = nil then
    raise EFb2ConversionError.Create('Не удалось разобрать content.xml');
end;

{ Обойти meta.xml (аналог root.iter() в _read_meta). }
procedure WalkMeta(N: TDOMNode; Meta: TOdtMeta);
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
      else if Local = 'date' then
      begin
        if Meta.Date = '' then
          Meta.Date := Text;
      end
      else if Local = 'description' then
        Meta.Description := Text
      else if Local = 'subject' then
        Meta.Subjects.Add(Text);
    end;
  end;
  C := N.FirstChild;
  while C <> nil do
  begin
    WalkMeta(C, Meta);
    C := C.NextSibling;
  end;
end;

function TOdtToFb2Converter.ReadMeta: TOdtMeta;
var
  Data: TBytes;
  Doc: TXMLDocument;
begin
  Result := TOdtMeta.Create;
  Data := ReadZip('meta.xml');
  if Length(Data) = 0 then
    Exit;
  try
    Doc := ParseBytes(Data);
  except
    Exit;
  end;
  FParseDocs.Add(Doc);
  WalkMeta(Doc.DocumentElement, Result);
end;

{ Собрать флаги оформления из <style:text-properties>. }
procedure WalkTextProps(N: TDOMNode; Flags: TStringList);
var
  C: TDOMNode;
  E: TDOMElement;
  Position, Font: UnicodeString;
begin
  if N = nil then
    Exit;
  if (N.NodeType = ELEMENT_NODE) and
    (LocalName(TDOMElement(N).TagName) = 'text-properties') then
  begin
    E := TDOMElement(N);
    if LowerCase(GetNSAttr(E, NS_FO, 'font-weight')) = 'bold' then
      Flags.Add('strong');
    if LowerCase(GetNSAttr(E, NS_FO, 'font-style')) = 'italic' then
      Flags.Add('emphasis');
    if GetNSAttr(E, NS_STYLE, 'text-line-through-style') <> '' then
      Flags.Add('strikethrough');
    Position := LowerCase(GetNSAttr(E, NS_STYLE, 'text-position'));
    if Pos('sub', Position) = 1 then
      Flags.Add('sub')
    else if (Pos('super', Position) = 1) or (Pos('sup', Position) = 1) then
      Flags.Add('sup');
    Font := LowerCase(GetNSAttr(E, NS_STYLE, 'font-name'));
    if (Pos('courier', Font) > 0) or (Pos('mono', Font) > 0) then
      Flags.Add('code');
  end;
  C := N.FirstChild;
  while C <> nil do
  begin
    WalkTextProps(C, Flags);
    C := C.NextSibling;
  end;
end;

procedure LoadStylesInto(N: TDOMNode; Styles: TStringList);
var
  C: TDOMNode;
  E: TDOMElement;
  Name: UnicodeString;
  Flags: TStringList;
begin
  if N = nil then
    Exit;
  if (N.NodeType = ELEMENT_NODE) and
    (LocalName(TDOMElement(N).TagName) = 'style') then
  begin
    E := TDOMElement(N);
    Name := GetNSAttr(E, NS_STYLE, 'name');
    if Name <> '' then
    begin
      Flags := NewFlags;
      try
        WalkTextProps(E, Flags);
        if Flags.Count > 0 then
          MapSet(Styles, Name, FlagsKey(Flags));
      finally
        Flags.Free;
      end;
    end;
  end;
  C := N.FirstChild;
  while C <> nil do
  begin
    LoadStylesInto(C, Styles);
    C := C.NextSibling;
  end;
end;

procedure TOdtToFb2Converter.LoadTextStyles(Root: TDOMElement);
begin
  LoadStylesInto(Root, FTextStyles);
end;

{ ===================== Преобразование текста ===================== }

{ Простой текст из узлов разметки (аналог _nodes_text). }
function NodesText(Nodes: TFb2ObjectList): UnicodeString;
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
  Result := UTrim(Result);
end;

{ Разобрать строку флагов (через запятую) в набор. }
function ParseFlags(const S: UnicodeString): TStringList;
var
  I: Integer;
  Cur: UnicodeString;
begin
  Result := NewFlags;
  Cur := '';
  for I := 1 to Length(S) + 1 do
  begin
    if (I > Length(S)) or (S[I] = ',') then
    begin
      if Cur <> '' then
        Result.Add(Cur);
      Cur := '';
    end
    else
      Cur := Cur + S[I];
  end;
end;

{ Обернуть узлы в теги разметки FB2 по флагам. }
function WrapFlags(Nodes: TFb2ObjectList; Flags: TStringList): TFb2ObjectList;
var
  I: Integer;
  Tag: UnicodeString;
  Cur, NewList: TFb2ObjectList;
  SN: TStyleNode;
begin
  Cur := Nodes;
  for I := 0 to Flags.Count - 1 do
  begin
    Tag := FlagToTag(Flags[I]);
    if Tag <> '' then
    begin
      SN := TStyleNode.Create(Tag);
      FreeAndNil(SN.Children);
      SN.Children := Cur;
      NewList := TFb2ObjectList.Create;
      NewList.Add(SN);
      Cur := NewList;
    end;
  end;
  Result := Cur;
end;

function TOdtToFb2Converter.ConvertBody(TextElem: TDOMElement): TBody;
var
  RootSection: TSection;
  Stack: TSectionStack;
  StackLen: Integer;
  C: TDOMNode;
  Sec: TSection;
begin
  Result := TBody.Create;
  RootSection := TSection.Create;
  SetLength(Stack, 4);
  Stack[0].Level := 0;
  Stack[0].Sec := RootSection;
  StackLen := 1;

  C := TextElem.FirstChild;
  while C <> nil do
  begin
    if C.NodeType = ELEMENT_NODE then
      HandleElement(TDOMElement(C), Stack, StackLen);
    C := C.NextSibling;
  end;

  FreeAndNil(Result.Sections);
  Result.Sections := RootSection.Sections;
  RootSection.Sections := nil;
  if RootSection.Content.Count > 0 then
  begin
    Sec := TSection.Create;
    FreeAndNil(Sec.Content);
    Sec.Content := RootSection.Content;
    RootSection.Content := nil;
    Result.Sections.Insert(0, Sec);
  end;
  if Result.Sections.Count = 0 then
    Result.Sections.Add(TSection.Create);
  RootSection.Free;
end;

procedure TOdtToFb2Converter.HandleElement(Element: TDOMElement;
  var Stack: TSectionStack; var StackLen: Integer);
var
  Local: UnicodeString;
  C: TDOMNode;
  Table: TTable;
begin
  Local := LocalName(Element.TagName);
  if Local = 'h' then
    HandleHeading(Element, Stack, StackLen)
  else if Local = 'p' then
    HandleParagraph(Element, Stack, StackLen)
  else if Local = 'table' then
  begin
    Table := ConvertTable(Element);
    if Table <> nil then
      Stack[StackLen - 1].Sec.Content.Add(Table);
  end
  else if Local = 'list' then
    HandleList(Element, Stack, StackLen)
  else if Local = 'section' then
  begin
    C := Element.FirstChild;
    while C <> nil do
    begin
      if C.NodeType = ELEMENT_NODE then
        HandleElement(TDOMElement(C), Stack, StackLen);
      C := C.NextSibling;
    end;
  end;
end;

procedure TOdtToFb2Converter.HandleList(Element: TDOMElement;
  var Stack: TSectionStack; var StackLen: Integer);
var
  C: TDOMNode;
begin
  if (Element.NodeType = ELEMENT_NODE) and
    (LocalName(Element.TagName) = 'p') then
    HandleParagraph(Element, Stack, StackLen);
  C := Element.FirstChild;
  while C <> nil do
  begin
    if C.NodeType = ELEMENT_NODE then
      HandleList(TDOMElement(C), Stack, StackLen);
    C := C.NextSibling;
  end;
end;

{ Уровень заголовка (1..10). }
function OutlineLevel(Element: TDOMElement): Integer;
var
  V: UnicodeString;
  Level: Integer;
begin
  V := GetNSAttr(Element, NS_TEXT, 'outline-level');
  if V = '' then
    V := '1';
  Level := StrToIntDef(V, 1);
  if Level < 1 then
    Level := 1;
  if Level > 10 then
    Level := 10;
  Result := Level;
end;

procedure TOdtToFb2Converter.HandleHeading(Element: TDOMElement;
  var Stack: TSectionStack; var StackLen: Integer);
var
  Level: Integer;
  Nodes: TFb2ObjectList;
  Section: TSection;
  Par: TParagraph;
begin
  FInHeader := False;
  Level := OutlineLevel(Element);
  Nodes := InlineNodes(Element, nil);
  if Nodes.Count = 0 then
  begin
    Nodes.Free;
    Exit;
  end;
  while (StackLen > 1) and (Stack[StackLen - 1].Level >= Level) do
    Dec(StackLen);
  Section := TSection.Create;
  Par := TParagraph.Create;
  FreeAndNil(Par.Content);
  Par.Content := Nodes;
  Section.Title := TTitle.Create;
  Section.Title.Items.Add(Par);
  Stack[StackLen - 1].Sec.Sections.Add(Section);
  if StackLen = Length(Stack) then
    SetLength(Stack, StackLen * 2);
  Stack[StackLen].Level := Level;
  Stack[StackLen].Sec := Section;
  Inc(StackLen);
end;

{ Разбить строку по запятым, обрезая и пропуская пустые части. }
procedure SplitCommaStripped(const S: UnicodeString; Target: TTextList);
var
  I: Integer;
  Cur: UnicodeString;
begin
  Cur := '';
  for I := 1 to Length(S) + 1 do
  begin
    if (I > Length(S)) or (S[I] = ',') then
    begin
      Cur := UTrim(Cur);
      if Cur <> '' then
        Target.Add(Cur);
      Cur := '';
    end
    else
      Cur := Cur + S[I];
  end;
end;

procedure TOdtToFb2Converter.HandleParagraph(Element: TDOMElement;
  var Stack: TSectionStack; var StackLen: Integer);
var
  Style, Text: UnicodeString;
  Nodes, Images: TFb2ObjectList;
  Sub: TSubtitle;
  Par: TParagraph;
begin
  Style := GetNSAttr(Element, NS_TEXT, 'style-name');
  Nodes := InlineNodes(Element, nil);
  Text := NodesText(Nodes);

  if (Style = HEADER_TITLE_STYLE) and FInHeader then
  begin
    if Text <> '' then
      FTitleOverride := Text;
    Nodes.Free;
    Exit;
  end;
  if (Style = HEADER_AUTHOR_STYLE) and FInHeader then
  begin
    if Text <> '' then
    begin
      FCreatorsOverride.Clear;
      SplitCommaStripped(Text, FCreatorsOverride);
    end;
    Nodes.Free;
    Exit;
  end;
  if (Style = HEADER_ANNOTATION_STYLE) and FInHeader then
  begin
    if Text <> '' then
      FAnnotationOverride.Add(Text);
    Nodes.Free;
    Exit;
  end;

  Images := BlockImages(Element);
  if (Images.Count > 0) and (Text = '') then
  begin
    if FInHeader then
    begin
      if FCoverHref = '' then
        FCoverHref := TImage(Images[0]).Href;
    end
    else
      MoveList(Stack[StackLen - 1].Sec.Content, Images);
    Images.Free;
    Nodes.Free;
    Exit;
  end;
  Images.Free;

  FInHeader := False;
  if Nodes.Count = 0 then
  begin
    Nodes.Free;
    Exit;
  end;

  if Style = 'Subtitle2' then
  begin
    Sub := TSubtitle.Create;
    FreeAndNil(Sub.Content);
    Sub.Content := Nodes;
    Stack[StackLen - 1].Sec.Content.Add(Sub);
  end
  else
  begin
    Par := TParagraph.Create;
    FreeAndNil(Par.Content);
    Par.Content := Nodes;
    Stack[StackLen - 1].Sec.Content.Add(Par);
  end;
end;

function TOdtToFb2Converter.ConvertTable(Table: TDOMElement): TTable;
var
  Rows: TFb2ObjectList;
  C, CC, CCC: TDOMNode;
  Cells: TFb2ObjectList;
  Nodes: TFb2ObjectList;
  Sub: TFb2ObjectList;
  Row: TTableRow;
  Cell: TTableCell;
begin
  Rows := TFb2ObjectList.Create;
  C := Table.FirstChild;
  while C <> nil do
  begin
    if (C.NodeType = ELEMENT_NODE) and
      (LocalName(TDOMElement(C).TagName) = 'table-row') then
    begin
      Cells := TFb2ObjectList.Create;
      CC := C.FirstChild;
      while CC <> nil do
      begin
        if (CC.NodeType = ELEMENT_NODE) and
          (LocalName(TDOMElement(CC).TagName) = 'table-cell') then
        begin
          Nodes := TFb2ObjectList.Create;
          CCC := CC.FirstChild;
          while CCC <> nil do
          begin
            if (CCC.NodeType = ELEMENT_NODE) and
              (LocalName(TDOMElement(CCC).TagName) = 'p') then
            begin
              Sub := InlineNodes(TDOMElement(CCC), nil);
              MoveList(Nodes, Sub);
              Sub.Free;
            end;
            CCC := CCC.NextSibling;
          end;
          Cell := TTableCell.Create;
          Cell.Tag := 'td';
          FreeAndNil(Cell.Children);
          Cell.Children := Nodes;
          Cells.Add(Cell);
        end;
        CC := CC.NextSibling;
      end;
      Row := TTableRow.Create;
      FreeAndNil(Row.Cells);
      Row.Cells := Cells;
      Rows.Add(Row);
    end;
    C := C.NextSibling;
  end;
  Result := nil;
  if Rows.Count > 0 then
  begin
    Result := TTable.Create;
    FreeAndNil(Result.Rows);
    Result.Rows := Rows;
  end
  else
    Rows.Free;
end;

function TOdtToFb2Converter.InlineNodes(Element: TDOMElement;
  Flags: TStringList): TFb2ObjectList;
var
  C: TDOMNode;
  E: TDOMElement;
  Local, T, Style: UnicodeString;
  SN: TStyleNode;
  StyleFlags, ChildFlags, Extra: TStringList;
  Inner, Wrapped, Sub: TFb2ObjectList;
  Img: TStyleNode;
begin
  Result := TFb2ObjectList.Create;
  C := Element.FirstChild;
  while C <> nil do
  begin
    if C.NodeType = TEXT_NODE then
    begin
      T := C.NodeValue;
      if UTrim(T) <> '' then
      begin
        SN := TStyleNode.Create(TEXT_NODE_NAME);
        SN.Text := T;
        Result.Add(SN);
      end;
    end
    else if C.NodeType = ELEMENT_NODE then
    begin
      E := TDOMElement(C);
      Local := LocalName(E.TagName);
      if Local = 'span' then
      begin
        Style := GetNSAttr(E, NS_TEXT, 'style-name');
        StyleFlags := ParseFlags(MapGet(FTextStyles, Style));
        ChildFlags := FlagsUnion(Flags, StyleFlags);
        StyleFlags.Free;
        Inner := InlineNodes(E, ChildFlags);
        Extra := FlagsDiff(ChildFlags, Flags);
        Wrapped := WrapFlags(Inner, Extra);
        Extra.Free;
        ChildFlags.Free;
        MoveList(Result, Wrapped);
        Wrapped.Free;
      end
      else if Local = 'a' then
      begin
        Inner := InlineNodes(E, Flags);
        SN := TStyleNode.Create('a');
        SN.Href := GetNSAttr(E, NS_XLINK, 'href');
        FreeAndNil(SN.Children);
        SN.Children := Inner;
        Result.Add(SN);
      end
      else if Local = 'frame' then
      begin
        Img := FrameNode(E);
        if Img <> nil then
          Result.Add(Img);
      end
      else if (Local = 'line-break') or (Local = 'tab') or (Local = 's') then
      begin
        SN := TStyleNode.Create(TEXT_NODE_NAME);
        SN.Text := ' ';
        Result.Add(SN);
      end
      else
      begin
        Sub := InlineNodes(E, Flags);
        MoveList(Result, Sub);
        Sub.Free;
      end;
    end;
    C := C.NextSibling;
  end;
end;

function TOdtToFb2Converter.BlockImages(Element: TDOMElement): TFb2ObjectList;
var
  C: TDOMNode;
  Href, BinaryId: UnicodeString;
  Img: TImage;
begin
  Result := TFb2ObjectList.Create;
  C := Element.FirstChild;
  while C <> nil do
  begin
    if (C.NodeType = ELEMENT_NODE) and
      (LocalName(TDOMElement(C).TagName) = 'frame') then
    begin
      Href := ImageHref(TDOMElement(C));
      if Href <> '' then
      begin
        BinaryId := RegisterBinary(Href);
        if BinaryId <> '' then
        begin
          Img := TImage.Create;
          Img.Href := '#' + BinaryId;
          Result.Add(Img);
        end;
      end;
    end;
    C := C.NextSibling;
  end;
end;

function TOdtToFb2Converter.FrameNode(Frame: TDOMElement): TStyleNode;
var
  Href, BinaryId: UnicodeString;
begin
  Result := nil;
  Href := ImageHref(Frame);
  if Href = '' then
    Exit;
  BinaryId := RegisterBinary(Href);
  if BinaryId = '' then
    Exit;
  Result := TStyleNode.Create('image');
  Result.ImageHref := '#' + BinaryId;
end;

function TOdtToFb2Converter.ImageHref(Frame: TDOMElement): UnicodeString;
var
  Img: TDOMElement;
begin
  Img := FindInSubtree(Frame, 'image');
  if Img = nil then
    Exit('');
  Result := GetNSAttr(Img, NS_XLINK, 'href');
end;

function TOdtToFb2Converter.RegisterBinary(const Href: UnicodeString): UnicodeString;
var
  Name, Existing, MediaType, Ext, BinaryId: UnicodeString;
  Data: TBytes;
  Bin: TBinary;
begin
  Name := LStripSlash(Href);
  Existing := MapGet(FBinaryIds, Name);
  if Existing <> '' then
    Exit(Existing);
  Data := ReadZip(Name);
  if Length(Data) = 0 then
    Exit('');
  MediaType := DetectImageType(Data, Ext);
  BinaryId := ExtractFileName(Name);
  if BinaryId = '' then
    BinaryId := 'image' + ExtensionForMediaType(MediaType);
  MapSet(FBinaryIds, Name, BinaryId);
  Bin := TBinary.Create;
  Bin.Id := BinaryId;
  Bin.ContentType := MediaType;
  Bin.Data := Base64EncodeBytes(Data);
  FBinaries.Add(Bin);
  Result := BinaryId;
end;

{ ===================== Сборка FictionBook ===================== }

{ Разбить строку автора на first/middle/last. }
function SplitAuthorName(const Name: UnicodeString): TAuthor;
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

function TOdtToFb2Converter.CreatorsOf(Meta: TOdtMeta): TTextList;
begin
  Result := TTextList.Create;
  if Meta.Creators.Count > 0 then
    Result.AddStrings(Meta.Creators)
  else
    Result.AddStrings(FCreatorsOverride);
end;

function TOdtToFb2Converter.GenresOf(Meta: TOdtMeta): TTextList;
var
  I: Integer;
  S: UnicodeString;
begin
  Result := TTextList.Create;
  for I := 0 to Meta.Subjects.Count - 1 do
  begin
    S := UTrim(Meta.Subjects[I]);
    if (S <> '') and (Pos(' ', S) = 0) then
      Result.Add(S);
  end;
  if Result.Count = 0 then
    Result.Add(FDefaultGenre);
end;

function TOdtToFb2Converter.AnnotationOf(Meta: TOdtMeta): TAnnotation;
var
  Par: TParagraph;
  SN: TStyleNode;
begin
  if Meta.Description = '' then
    Exit(nil);
  Result := TAnnotation.Create;
  Par := TParagraph.Create;
  SN := TStyleNode.Create(TEXT_NODE_NAME);
  SN.Text := Meta.Description;
  Par.Content.Add(SN);
  Result.Items.Add(Par);
end;

{ Добавить абзац с текстом в список аннотации. }
procedure AddAnnotationPara(Items: TFb2ObjectList; const AText: UnicodeString);
var
  Par: TParagraph;
  SN: TStyleNode;
begin
  Par := TParagraph.Create;
  SN := TStyleNode.Create(TEXT_NODE_NAME);
  SN.Text := AText;
  Par.Content.Add(SN);
  Items.Add(Par);
end;

function TOdtToFb2Converter.AnnotationItems(Meta: TOdtMeta): TFb2ObjectList;
var
  I: Integer;
begin
  Result := TFb2ObjectList.Create;
  if Meta.Description <> '' then
    AddAnnotationPara(Result, Meta.Description)
  else
    for I := 0 to FAnnotationOverride.Count - 1 do
      if FAnnotationOverride[I] <> '' then
        AddAnnotationPara(Result, FAnnotationOverride[I]);
end;

function TOdtToFb2Converter.Assemble(Meta: TOdtMeta; Body: TBody): TFictionBook;
var
  Desc: TDescription;
  TI: TTitleInfo;
  DI: TDocumentInfo;
  Title, Lang: UnicodeString;
  I: Integer;
  Genres, Creators: TTextList;
  AnnItems: TFb2ObjectList;
  Ann: TAnnotation;
  A: TAuthor;
  G: TGenre;
  CP: TCoverPage;
  II: TInlineImage;
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

  Creators := CreatorsOf(Meta);
  try
    for I := 0 to Creators.Count - 1 do
      TI.Authors.Add(SplitAuthorName(Creators[I]));
  finally
    Creators.Free;
  end;

  TI.BookTitle := TTextField.Create;
  TI.BookTitle.Value := Title;

  AnnItems := AnnotationItems(Meta);
  if AnnItems.Count > 0 then
  begin
    Ann := TAnnotation.Create;
    FreeAndNil(Ann.Items);
    Ann.Items := AnnItems;
    TI.Annotation := Ann;
  end
  else
    AnnItems.Free;

  if FCoverHref <> '' then
  begin
    CP := TCoverPage.Create;
    II := TInlineImage.Create;
    II.Href := FCoverHref;
    CP.Images.Add(II);
    TI.Coverpage := CP;
  end;

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

function TOdtToFb2Converter.Convert(const Source: UnicodeString): TFictionBook;
var
  Meta: TOdtMeta;
  ContentRoot, TextRoot: TDOMElement;
  Body: TBody;
begin
  if Source <> '' then
    FSource := Source;
  if FSource = '' then
    raise EFb2ConversionError.Create('Не задан источник ODT (source)');

  Reset;
  FZip := TEpubArchive.Create;
  try
    FZip.LoadFromFile(FSource);
    Meta := ReadMeta;
    try
      ContentRoot := ReadContent;
      TextRoot := FindInSubtree(ContentRoot, 'text');
      if TextRoot = nil then
        raise EFb2ConversionError.Create('В ODT не найден элемент <office:text>');
      LoadTextStyles(ContentRoot);
      Body := ConvertBody(TextRoot);
      FBook := Assemble(Meta, Body);
      Result := FBook;
    finally
      Meta.Free;
    end;
  finally
    FreeAndNil(FZip);
  end;
end;

function TOdtToFb2Converter.ToXml(Book: TFictionBook): UnicodeString;
begin
  if Book = nil then
    Book := FBook;
  if Book = nil then
    Book := Convert;
  Result := FWriter.ToXML(Book);
end;

function TOdtToFb2Converter.Write(const Source: UnicodeString;
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

end.
