unit fb2_parser;
{ Чтение FB2 (FictionBook 2.0) через fcl-xml (DOM) — перевод fb2_parser.py.

  Модуль предоставляет класс TFb2Parser, который заполняет структуры из
  fb2_structures.pas значениями из XML-документа.

  С ЧЕГО НАЧИНАТЬ РАЗБОР FB2:
      1. Корень документа  -> <FictionBook>
      2. <stylesheet>*     -> до <description>, читаются отдельно
      3. <description>     -> метаданные книги
      4. внутри описания   -> <title-info> (первый), затем <document-info>,
                              <publish-info>, <custom-info>, <output>
      5. <body>+           -> основной текст, внутри — рекурсивные <section>

  Особенности перевода с Python:
      * вместо xml.etree.ElementTree используется DOM из fcl-xml
        (units DOM, XMLRead);
      * сопоставление имён идёт по локальному имени (без префикса), что
        покрывает и документы с xmlns, и документы без него;
      * атрибуты xlink:href / xml:lang читаются через GetAttributeNS с
        фолбэком на квалифицированные и локальные имена.

  Пример:
      var P: TFb2Parser;
      begin
        P := TFb2Parser.Create;
        try
          P.LoadFile('book.fb2');
          WriteLn(P.Describe(P.Parse));
        finally
          P.Free;
        end;
      end; }

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Classes, SysUtils, fgl, DOM, XMLRead,
  fb2_structures;

const
  {: content-type по умолчанию, если атрибут не задан. }
  DEFAULT_CONTENT_TYPE = 'application/octet-stream';

type
  { Парсер FB2: преобразует XML-элементы в структуры из fb2_structures. }
  TFb2Parser = class
  private
    FDoc: TXMLDocument;
    FRoot: TDOMElement;

    { --- Разбор <description> и его частей --------------------------- }
    function ParseTitleInfo(Elem: TDOMElement): TTitleInfo;
    function ParseDocumentInfo(Elem: TDOMElement): TDocumentInfo;
    function ParsePublishInfo(Elem: TDOMElement): TPublishInfo;
    function ParseCustomInfo(Elem: TDOMElement): TCustomInfo;
    function ParseStylesheetElem(Elem: TDOMElement): TStylesheet;
    function ParseBinaryElem(Elem: TDOMElement): TBinary;

    { --- Разметка (styleType / mixed-контент) ------------------------ }
    function ParseMarkup(Elem: TDOMNode): TFb2ObjectList;
    function ParseStyleNode(Elem: TDOMElement): TStyleNode;
    function MarkupText(Nodes: TFb2ObjectList): UnicodeString;

    { --- Блочные элементы -------------------------------------------- }
    function ParseBlock(Elem: TDOMElement): TFb2Object;
    function ParseParagraph(Elem: TDOMElement): TParagraph;
    function ParseSubtitle(Elem: TDOMElement): TSubtitle;
    function ParseAnnotation(Elem: TDOMElement): TAnnotation;
    function ParseTitle(Elem: TDOMElement): TTitle;
    function ParseEpigraph(Elem: TDOMElement): TEpigraph;
    function ParseStanza(Elem: TDOMElement): TStanza;
    function ParsePoem(Elem: TDOMElement): TPoem;
    function ParseCite(Elem: TDOMElement): TCite;
    function ParseTable(Elem: TDOMElement): TTable;
    function ParseImage(Elem: TDOMElement): TImage;

    { --- Простые элементы -------------------------------------------- }
    function ParseTextField(Elem: TDOMElement): TTextField;
    function ParseDate(Elem: TDOMElement): TDateField;

    { --- Автор, жанр, серия, обложка --------------------------------- }
    function ParseAuthor(Elem: TDOMElement): TAuthor;
    function ParseGenre(Elem: TDOMElement): TGenre;
    function ParseSequence(Elem: TDOMElement): TSequence;
    function ParseInlineImage(Elem: TDOMElement): TInlineImage;
    function ParseCoverpage(Elem: TDOMElement): TCoverPage;
  public
    constructor Create;
    destructor Destroy; override;

    { --- Вывод ------------------------------------------------------- }
    { Автор в виде "Имя Отчество Фамилия" (или никнейм). Используется
      также в fb2_markdown. }
    function FormatAuthor(Author: TAuthor): UnicodeString;

    { --- Загрузка документа ------------------------------------------ }
    procedure LoadFile(const AFileName: UnicodeString);
    procedure LoadStream(AStream: TStream);
    property Root: TDOMElement read FRoot;

    { --- Публичный API ----------------------------------------------- }
    function Parse: TDescription;
    function ParseStylesheets: TFb2ObjectList;
    function ParseBinaries: TFb2ObjectList;
    function ParseBodies: TFb2ObjectList;

    function ParseDescriptionElem(Elem: TDOMElement): TDescription;
    function ParseBody(Elem: TDOMElement): TBody;
    function ParseSection(Elem: TDOMElement): TSection;

    { --- Целочисленные идентификаторы заголовков --------------------- }
    function AssignHeadingIds(Bodies: TFb2ObjectList): Integer;

    { --- Дерево заголовков и текста ---------------------------------- }
    function SectionTitle(Section: TSection): UnicodeString;
    function BlockText(Block: TFb2Object): UnicodeString;
    function DescribeSectionTree(Section: TSection; Depth: Integer = 0;
      WithText: Boolean = True; const Indent: UnicodeString = '  ';
      WithIds: Boolean = False): UnicodeString;
    function DescribeBodies(Bodies: TFb2ObjectList = nil;
      WithText: Boolean = True; const Indent: UnicodeString = '  ';
      WithIds: Boolean = False): UnicodeString;
    function Describe(Description: TDescription): UnicodeString;

    { --- Бинарные данные --------------------------------------------- }
    function BinaryData(Binary: TBinary): TBytes;
    function BinaryFilename(Binary: TBinary): UnicodeString;
    function SaveBinary(Binary: TBinary;
      const Directory: UnicodeString): UnicodeString;
    function SaveBinaries(const Directory: UnicodeString): TTextList;
  end;

{ --- Низкоуровневые помощники (доступны и извне) --------------------- }
function LocalName(const AName: UnicodeString): UnicodeString;
function IsStyleTag(const AName: UnicodeString): Boolean;
function ToAlignEnum(const S: UnicodeString): TAlign;
function ToVAlignEnum(const S: UnicodeString): TVAlign;
function ToShareModeEnum(const S: UnicodeString): TShareMode;
function ToDocGenEnum(const S: UnicodeString): TDocGenerationInstruction;
function Base64DecodeString(const S: UnicodeString): TBytes;

implementation

{ ===================== Общие помощники ===================== }

function LocalName(const AName: UnicodeString): UnicodeString;
var
  P: Integer;
begin
  Result := AName;
  P := LastDelimiter('}', AName);
  if P > 0 then
  begin
    Result := Copy(AName, P + 1, Length(AName) - P);
    Exit;
  end;
  P := LastDelimiter(':', AName);
  if P > 0 then
    Result := Copy(AName, P + 1, Length(AName) - P);
end;

function IsStyleTag(const AName: UnicodeString): Boolean;
begin
  Result :=
    (AName = 'strong') or (AName = 'emphasis') or (AName = 'style') or
    (AName = 'a') or (AName = 'strikethrough') or (AName = 'sub') or
    (AName = 'sup') or (AName = 'code') or (AName = 'image');
end;

function ToAlignEnum(const S: UnicodeString): TAlign;
begin
  if S = 'left' then Result := alLeft
  else if S = 'right' then Result := alRight
  else if S = 'center' then Result := alCenter
  else Result := alNone;
end;

function ToVAlignEnum(const S: UnicodeString): TVAlign;
begin
  if S = 'top' then Result := vaTop
  else if S = 'middle' then Result := vaMiddle
  else if S = 'bottom' then Result := vaBottom
  else Result := vaNone;
end;

function ToShareModeEnum(const S: UnicodeString): TShareMode;
begin
  if S = 'paid' then Result := smPaid
  else Result := smFree;
end;

function ToDocGenEnum(const S: UnicodeString): TDocGenerationInstruction;
begin
  if S = 'require' then Result := dgiRequire
  else if S = 'deny' then Result := dgiDeny
  else Result := dgiAllow;
end;

function RepeatStr(const S: UnicodeString; N: Integer): UnicodeString;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to N do
    Result := Result + S;
end;

function IdOrNone(V: Integer): UnicodeString;
begin
  if V = NO_VALUE then
    Result := 'None'
  else
    Result := IntToStr(V);
end;

function JoinNonEmpty(List: TTextList; const Sep: UnicodeString): UnicodeString;
var
  I: Integer;
  First: Boolean;
begin
  Result := '';
  First := True;
  for I := 0 to List.Count - 1 do
  begin
    if List[I] = '' then
      Continue;
    if not First then
      Result := Result + Sep;
    Result := Result + List[I];
    First := False;
  end;
end;

function ContentTypeExtension(const CT: UnicodeString): UnicodeString;
begin
  if (CT = 'image/jpeg') or (CT = 'image/jpg') then Result := '.jpg'
  else if CT = 'image/png' then Result := '.png'
  else if CT = 'image/gif' then Result := '.gif'
  else if CT = 'image/bmp' then Result := '.bmp'
  else if CT = 'image/webp' then Result := '.webp'
  else if CT = 'image/svg+xml' then Result := '.svg'
  else if CT = 'image/tiff' then Result := '.tiff'
  else if CT = 'application/octet-stream' then Result := '.bin'
  else Result := '';
end;

function Base64DecodeString(const S: UnicodeString): TBytes;
var
  Clean: UnicodeString;
  I, V, Bits, OutLen: Integer;
  Ch: WideChar;
  Acc: LongWord;
begin
  Clean := '';
  for I := 1 to Length(S) do
    if not ((S[I] = ' ') or (S[I] = #9) or (S[I] = #10) or (S[I] = #13)) then
      Clean := Clean + S[I];

  SetLength(Result, (Length(Clean) * 3) div 4 + 4);
  OutLen := 0;
  Acc := 0;
  Bits := 0;
  for I := 1 to Length(Clean) do
  begin
    Ch := Clean[I];
    if Ch = '=' then
      Break;
    if (Ch >= 'A') and (Ch <= 'Z') then V := Ord(Ch) - Ord('A')
    else if (Ch >= 'a') and (Ch <= 'z') then V := Ord(Ch) - Ord('a') + 26
    else if (Ch >= '0') and (Ch <= '9') then V := Ord(Ch) - Ord('0') + 52
    else if Ch = '+' then V := 62
    else if Ch = '/' then V := 63
    else Continue;
    Acc := (Acc shl 6) or LongWord(V);
    Inc(Bits, 6);
    if Bits >= 8 then
    begin
      Dec(Bits, 8);
      Result[OutLen] := Byte((Acc shr Bits) and $FF);
      Inc(OutLen);
    end;
  end;
  SetLength(Result, OutLen);
end;

{ ===================== Помощники DOM ===================== }

function FindChildElement(Parent: TDOMNode; const ALocal: UnicodeString): TDOMElement;
var
  N: TDOMNode;
begin
  Result := nil;
  if Parent = nil then
    Exit;
  N := Parent.FirstChild;
  while N <> nil do
  begin
    if (N.NodeType = ELEMENT_NODE) and (LocalName(N.NodeName) = ALocal) then
    begin
      Result := TDOMElement(N);
      Exit;
    end;
    N := N.NextSibling;
  end;
end;

function FindChildElements(Parent: TDOMNode; const ALocal: UnicodeString): TList;
var
  N: TDOMNode;
begin
  Result := TList.Create;
  if Parent = nil then
    Exit;
  N := Parent.FirstChild;
  while N <> nil do
  begin
    if (N.NodeType = ELEMENT_NODE) and (LocalName(N.NodeName) = ALocal) then
      Result.Add(TDOMElement(N));
    N := N.NextSibling;
  end;
end;

function GetAttrQ(Elem: TDOMElement; const AName: UnicodeString): UnicodeString;
begin
  Result := '';
  if Elem = nil then
    Exit;
  Result := Elem.GetAttribute(AName);
end;

{ Значение атрибута по локальному имени (игнорируя префикс/пространство имён).
  Не использует GetAttributeNS, чтобы не зависеть от версии DOM в FPC. }
function GetAttrByLocal(Elem: TDOMElement; const ALocal: UnicodeString): UnicodeString;
var
  Attrs: TDOMNamedNodeMap;
  I: Integer;
  Count: LongWord;
  Attr: TDOMNode;
begin
  Result := '';
  if Elem = nil then
    Exit;
  Attrs := Elem.Attributes;
  if Attrs = nil then
    Exit;
  { Attrs.Length — беззнаковый LongWord: при пустом списке атрибутов
    выражение Length - 1 дало бы 4294967295 и цикл фактически завис бы.
    Поэтому граница сохраняется в Count, а счётчик — знаковый Integer. }
  Count := Attrs.Length;
  if Count = 0 then
    Exit;
  for I := 0 to Integer(Count) - 1 do
  begin
    Attr := Attrs.Item[LongWord(I)];
    if Attr = nil then
      Continue;
    if LocalName(Attr.NodeName) = ALocal then
    begin
      Result := Attr.NodeValue;
      Exit;
    end;
  end;
end;

function GetHref(Elem: TDOMElement): UnicodeString;
begin
  Result := '';
  if Elem = nil then
    Exit;
  Result := GetAttrQ(Elem, 'xlink:href');
  if Result = '' then
    Result := GetAttrQ(Elem, 'href');
  if Result = '' then
    Result := GetAttrByLocal(Elem, 'href');
end;

function GetXmlLang(Elem: TDOMElement): UnicodeString;
begin
  Result := '';
  if Elem = nil then
    Exit;
  Result := GetAttrQ(Elem, 'xml:lang');
  if Result = '' then
    Result := GetAttrQ(Elem, 'lang');
  if Result = '' then
    Result := GetAttrByLocal(Elem, 'lang');
end;

function ElementText(Elem: TDOMNode): UnicodeString;
var
  N: TDOMNode;
begin
  Result := '';
  if Elem = nil then
    Exit;
  N := Elem.FirstChild;
  while N <> nil do
  begin
    if N.NodeType = TEXT_NODE then
      Result := Result + N.NodeValue;
    N := N.NextSibling;
  end;
  Result := UTrim(Result);
end;

{ Разбор целого из строки (без зависимости от перегрузок SysUtils). }
function ToIntDef(const S: UnicodeString; Def: Integer): Integer;
var
  T: UnicodeString;
  I, Sign, V: Integer;
begin
  Result := Def;
  T := UTrim(S);
  if T = '' then
    Exit;
  I := 1;
  Sign := 1;
  if T[1] = '-' then
  begin
    Sign := -1;
    Inc(I);
  end
  else if T[1] = '+' then
    Inc(I);
  if I > Length(T) then
    Exit;
  V := 0;
  while I <= Length(T) do
  begin
    if (T[I] < '0') or (T[I] > '9') then
      Exit;
    V := V * 10 + (Ord(T[I]) - Ord('0'));
    Inc(I);
  end;
  Result := Sign * V;
end;

{ Разбор вещественного из строки (без зависимости от перегрузок SysUtils). }
function ToFloatDef(const S: UnicodeString; Def: Double; out Ok: Boolean): Double;
var
  T: UnicodeString;
  I, Sign: Integer;
  IntPart, Frac, Scale: Double;
begin
  Ok := False;
  Result := Def;
  T := UTrim(S);
  if T = '' then
    Exit;
  I := 1;
  Sign := 1;
  if T[1] = '-' then
  begin
    Sign := -1;
    Inc(I);
  end
  else if T[1] = '+' then
    Inc(I);
  IntPart := 0;
  while (I <= Length(T)) and (T[I] >= '0') and (T[I] <= '9') do
  begin
    IntPart := IntPart * 10 + (Ord(T[I]) - Ord('0'));
    Inc(I);
  end;
  Frac := 0;
  Scale := 1;
  if (I <= Length(T)) and (T[I] = '.') then
  begin
    Inc(I);
    while (I <= Length(T)) and (T[I] >= '0') and (T[I] <= '9') do
    begin
      Scale := Scale / 10;
      Frac := Frac + (Ord(T[I]) - Ord('0')) * Scale;
      Inc(I);
    end;
  end;
  if I <= Length(T) then
    Exit;
  Result := Sign * (IntPart + Frac);
  Ok := True;
end;

{ ===================== Конструктор / деструктор ===================== }

constructor TFb2Parser.Create;
begin
  inherited Create;
  FDoc := nil;
  FRoot := nil;
end;

destructor TFb2Parser.Destroy;
begin
  FreeAndNil(FDoc);
  inherited Destroy;
end;

procedure TFb2Parser.LoadFile(const AFileName: UnicodeString);
var
  FS: TFileStream;
begin
  FreeAndNil(FDoc);
  FRoot := nil;
  FS := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  try
    ReadXMLFile(FDoc, FS);
  finally
    FS.Free;
  end;
  FRoot := FDoc.DocumentElement;
end;

procedure TFb2Parser.LoadStream(AStream: TStream);
begin
  FreeAndNil(FDoc);
  FRoot := nil;
  ReadXMLFile(FDoc, AStream);
  FRoot := FDoc.DocumentElement;
end;

{ ===================== Публичный API ===================== }

function TFb2Parser.Parse: TDescription;
var
  Elem: TDOMElement;
begin
  Elem := FindChildElement(FRoot, 'description');
  if Elem = nil then
    raise Exception.Create('В документе отсутствует элемент <description>');
  Result := ParseDescriptionElem(Elem);
end;

function TFb2Parser.ParseStylesheets: TFb2ObjectList;
var
  List: TList;
  I: Integer;
begin
  Result := TFb2ObjectList.Create;
  List := FindChildElements(FRoot, 'stylesheet');
  try
    for I := 0 to List.Count - 1 do
      Result.Add(ParseStylesheetElem(TDOMElement(List[I])));
  finally
    List.Free;
  end;
end;

function TFb2Parser.ParseBinaries: TFb2ObjectList;
var
  List: TList;
  I: Integer;
begin
  Result := TFb2ObjectList.Create;
  List := FindChildElements(FRoot, 'binary');
  try
    for I := 0 to List.Count - 1 do
      Result.Add(ParseBinaryElem(TDOMElement(List[I])));
  finally
    List.Free;
  end;
end;

function TFb2Parser.ParseBodies: TFb2ObjectList;
var
  List: TList;
  I: Integer;
begin
  Result := TFb2ObjectList.Create;
  List := FindChildElements(FRoot, 'body');
  try
    for I := 0 to List.Count - 1 do
      Result.Add(ParseBody(TDOMElement(List[I])));
  finally
    List.Free;
  end;
  AssignHeadingIds(Result);
end;

{ ===================== Разбор <description> ===================== }

function TFb2Parser.ParseDescriptionElem(Elem: TDOMElement): TDescription;
var
  N: TDOMNode;
  Name: UnicodeString;
begin
  Result := TDescription.Create;
  N := Elem.FirstChild;
  while N <> nil do
  begin
    if N.NodeType = ELEMENT_NODE then
    begin
      Name := LocalName(N.NodeName);
      if Name = 'title-info' then
        Result.TitleInfo := ParseTitleInfo(TDOMElement(N))
      else if Name = 'src-title-info' then
        Result.SrcTitleInfo := ParseTitleInfo(TDOMElement(N))
      else if Name = 'document-info' then
        Result.DocumentInfo := ParseDocumentInfo(TDOMElement(N))
      else if Name = 'publish-info' then
        Result.PublishInfo := ParsePublishInfo(TDOMElement(N))
      else if Name = 'custom-info' then
        Result.CustomInfos.Add(ParseCustomInfo(TDOMElement(N)));
    end;
    N := N.NextSibling;
  end;
end;

function TFb2Parser.ParseBody(Elem: TDOMElement): TBody;
var
  N: TDOMNode;
  Name: UnicodeString;
begin
  Result := TBody.Create;
  Result.Name := GetAttrQ(Elem, 'name');
  Result.Lang := GetXmlLang(Elem);
  N := Elem.FirstChild;
  while N <> nil do
  begin
    if N.NodeType = ELEMENT_NODE then
    begin
      Name := LocalName(N.NodeName);
      if Name = 'image' then
        Result.Image := ParseImage(TDOMElement(N))
      else if Name = 'title' then
        Result.Title := ParseTitle(TDOMElement(N))
      else if Name = 'epigraph' then
        Result.Epigraphs.Add(ParseEpigraph(TDOMElement(N)))
      else if Name = 'section' then
        Result.Sections.Add(ParseSection(TDOMElement(N)));
    end;
    N := N.NextSibling;
  end;
end;

function TFb2Parser.ParseSection(Elem: TDOMElement): TSection;
var
  N: TDOMNode;
  Name: UnicodeString;
  Block: TFb2Object;
  HeaderOpen: Boolean;
begin
  Result := TSection.Create;
  Result.Id := GetAttrQ(Elem, 'id');
  Result.Lang := GetXmlLang(Elem);
  { По XSD в шапке секции может быть только ОДНА картинка (слот image?).
    Первое <image> до annotation/контента/подсекций — «главная» картинка
    секции (Result.Image), все последующие — обычный блочный контент.
    Иначе несколько иллюстраций в одной секции затирали бы друг друга. }
  HeaderOpen := True;
  N := Elem.FirstChild;
  while N <> nil do
  begin
    if N.NodeType = ELEMENT_NODE then
    begin
      Name := LocalName(N.NodeName);
      if Name = 'title' then
        Result.Title := ParseTitle(TDOMElement(N))
      else if Name = 'epigraph' then
        Result.Epigraphs.Add(ParseEpigraph(TDOMElement(N)))
      else if Name = 'image' then
      begin
        if HeaderOpen and (Result.Image = nil) then
          Result.Image := ParseImage(TDOMElement(N))
        else
        begin
          Block := ParseImage(TDOMElement(N));
          if Block <> nil then
            Result.Content.Add(Block);
        end;
      end
      else if Name = 'annotation' then
      begin
        Result.Annotation := ParseAnnotation(TDOMElement(N));
        HeaderOpen := False;
      end
      else if Name = 'section' then
      begin
        Result.Sections.Add(ParseSection(TDOMElement(N)));
        HeaderOpen := False;
      end
      else
      begin
        Block := ParseBlock(TDOMElement(N));
        if Block <> nil then
          Result.Content.Add(Block);
        HeaderOpen := False;
      end;
    end;
    N := N.NextSibling;
  end;
end;

{ ===================== Идентификаторы заголовков ===================== }

function TFb2Parser.AssignHeadingIds(Bodies: TFb2ObjectList): Integer;
var
  Counter: Integer;
  I, J: Integer;
  Body: TBody;
  Cur: Integer;

  procedure VisitSection(Section: TSection; ParentId: Integer);
  var
    K: Integer;
    ThisCur: Integer;
  begin
    if Section.Title <> nil then
    begin
      Inc(Counter);
      Section.HeadingId := Counter;
      ThisCur := Section.HeadingId;
    end
    else
      ThisCur := ParentId;
    Section.ParentId := ParentId;
    for K := 0 to Section.Sections.Count - 1 do
      VisitSection(TSection(Section.Sections[K]), ThisCur);
  end;

begin
  Counter := 0;
  if Bodies = nil then
  begin
    Result := 0;
    Exit;
  end;
  for I := 0 to Bodies.Count - 1 do
  begin
    Body := TBody(Bodies[I]);
    Body.ParentId := NO_VALUE;
    if Body.Title <> nil then
    begin
      Inc(Counter);
      Body.HeadingId := Counter;
      Cur := Body.HeadingId;
    end
    else
      Cur := NO_VALUE;
    for J := 0 to Body.Sections.Count - 1 do
      VisitSection(TSection(Body.Sections[J]), Cur);
  end;
  Result := Counter;
end;

{ ===================== Дерево заголовков и текста ===================== }

function TFb2Parser.SectionTitle(Section: TSection): UnicodeString;
var
  I: Integer;
  Item: TFb2Object;
  Parts: TTextList;
begin
  Result := '';
  if (Section = nil) or (Section.Title = nil) then
    Exit;
  Parts := TTextList.Create;
  try
    for I := 0 to Section.Title.Items.Count - 1 do
    begin
      Item := Section.Title.Items[I];
      if Item is TParagraph then
        Parts.Add(MarkupText(TParagraph(Item).Content));
    end;
    Result := JoinText(Parts, ' / ');
  finally
    Parts.Free;
  end;
end;

function TFb2Parser.BlockText(Block: TFb2Object): UnicodeString;
var
  I, J: Integer;
  Parts, CellTexts: TTextList;
  Item: TFb2Object;
  Row: TTableRow;
  Cell: TTableCell;
begin
  Result := '';
  if Block = nil then
    Exit;

  if Block is TParagraph then
    Result := MarkupText(TParagraph(Block).Content)
  else if Block is TSubtitle then
    Result := MarkupText(TSubtitle(Block).Content)
  else if Block is TEmptyLine then
    Result := ''
  else if Block is TPoem then
  begin
    Parts := TTextList.Create;
    try
      for I := 0 to TPoem(Block).Items.Count - 1 do
      begin
        Item := TPoem(Block).Items[I];
        Parts.Add(BlockText(Item));
      end;
      Result := JoinNonEmpty(Parts, ' / ');
    finally
      Parts.Free;
    end;
  end
  else if Block is TCite then
  begin
    Parts := TTextList.Create;
    try
      for I := 0 to TCite(Block).Items.Count - 1 do
      begin
        Item := TCite(Block).Items[I];
        Parts.Add(BlockText(Item));
      end;
      Result := JoinNonEmpty(Parts, ' / ');
    finally
      Parts.Free;
    end;
  end
  else if Block is TTable then
  begin
    Parts := TTextList.Create;
    try
      for I := 0 to TTable(Block).Rows.Count - 1 do
      begin
        Row := TTableRow(TTable(Block).Rows[I]);
        CellTexts := TTextList.Create;
        try
          for J := 0 to Row.Cells.Count - 1 do
          begin
            Cell := TTableCell(Row.Cells[J]);
            CellTexts.Add(MarkupText(Cell.Children));
          end;
          Parts.Add(JoinText(CellTexts, ' '));
        finally
          CellTexts.Free;
        end;
      end;
      Result := JoinText(Parts, ' | ');
    finally
      Parts.Free;
    end;
  end;
end;

function TFb2Parser.DescribeSectionTree(Section: TSection; Depth: Integer;
  WithText: Boolean; const Indent: UnicodeString; WithIds: Boolean): UnicodeString;
var
  Prefix, Caption, Txt: UnicodeString;
  Lines: TTextList;
  I: Integer;
  Block: TFb2Object;
begin
  Prefix := RepeatStr(Indent, Depth);
  Caption := SectionTitle(Section);
  if Caption = '' then
    Caption := '(без заголовка)';
  if WithIds then
    Caption := '[id=' + IdOrNone(Section.HeadingId) + ' parent=' +
      IdOrNone(Section.ParentId) + '] ' + Caption;

  Lines := TTextList.Create;
  try
    Lines.Add(Prefix + '- ' + Caption);
    if WithText then
      for I := 0 to Section.Content.Count - 1 do
      begin
        Block := Section.Content[I];
        Txt := BlockText(Block);
        if Txt <> '' then
          Lines.Add(Prefix + Indent + Txt);
      end;
    for I := 0 to Section.Sections.Count - 1 do
      Lines.Add(DescribeSectionTree(TSection(Section.Sections[I]), Depth + 1,
        WithText, Indent, WithIds));
    Result := JoinText(Lines, #10);
  finally
    Lines.Free;
  end;
end;

function TFb2Parser.DescribeBodies(Bodies: TFb2ObjectList; WithText: Boolean;
  const Indent: UnicodeString; WithIds: Boolean): UnicodeString;
var
  Lines, TitleParts: TTextList;
  I, J: Integer;
  Body: TBody;
  Name, BodyTitle: UnicodeString;
begin
  if Bodies = nil then
    Bodies := ParseBodies;

  Lines := TTextList.Create;
  try
    for I := 0 to Bodies.Count - 1 do
    begin
      Body := TBody(Bodies[I]);
      Name := '';
      if Body.Name <> '' then
        Name := ' name=''' + Body.Name + '''';
      Lines.Add('== body[' + IntToStr(I) + ']' + Name + ' ==');
      if Body.Title <> nil then
      begin
        TitleParts := TTextList.Create;
        try
          for J := 0 to Body.Title.Items.Count - 1 do
            if Body.Title.Items[J] is TParagraph then
              TitleParts.Add(MarkupText(TParagraph(Body.Title.Items[J]).Content));
          BodyTitle := JoinNonEmpty(TitleParts, ' / ');
        finally
          TitleParts.Free;
        end;
        if BodyTitle <> '' then
        begin
          if WithIds then
            BodyTitle := '[id=' + IdOrNone(Body.HeadingId) + ' parent=' +
              IdOrNone(Body.ParentId) + '] ' + BodyTitle;
          Lines.Add('# ' + BodyTitle);
        end;
      end;
      for J := 0 to Body.Sections.Count - 1 do
        Lines.Add(DescribeSectionTree(TSection(Body.Sections[J]), 0,
          WithText, Indent, WithIds));
    end;
    Result := JoinText(Lines, #10);
  finally
    Lines.Free;
  end;
end;

{ ===================== Бинарные данные ===================== }

function TFb2Parser.BinaryData(Binary: TBinary): TBytes;
begin
  Result := Base64DecodeString(Binary.Data);
end;

function TFb2Parser.BinaryFilename(Binary: TBinary): UnicodeString;
var
  CT, Ext_, Base: UnicodeString;
  P: Integer;
begin
  CT := LowerCase(Binary.ContentType);
  Ext_ := ContentTypeExtension(CT);
  Base := UTrim(Binary.Id);
  if Base = '' then
    Base := 'binary';
  Base := UReplace(Base, '/', '_');
  Base := UReplace(Base, '\', '_');
  P := LastDelimiter('.', Base);
  if (P > 0) and (P < Length(Base)) then
    Result := Base
  else
  begin
    if Ext_ = '' then
      Ext_ := '.bin';
    Result := Base + Ext_;
  end;
end;

function TFb2Parser.SaveBinary(Binary: TBinary;
  const Directory: UnicodeString): UnicodeString;
var
  Dir, Path: UnicodeString;
  Data: TBytes;
  FS: TFileStream;
begin
  Dir := Directory;
  if Dir = '' then
    Dir := '.';
  ForceDirectories(Dir);
  Path := IncludeTrailingPathDelimiter(Dir) + BinaryFilename(Binary);
  Data := BinaryData(Binary);
  FS := TFileStream.Create(Path, fmCreate);
  try
    if Length(Data) > 0 then
      FS.WriteBuffer(Data[0], Length(Data));
  finally
    FS.Free;
  end;
  Result := Path;
end;

function TFb2Parser.SaveBinaries(const Directory: UnicodeString): TTextList;
var
  Binaries: TFb2ObjectList;
  I: Integer;
begin
  Result := TTextList.Create;
  Binaries := ParseBinaries;
  try
    for I := 0 to Binaries.Count - 1 do
      Result.Add(SaveBinary(TBinary(Binaries[I]), Directory));
  finally
    Binaries.Free;
  end;
end;

{ ===================== Разбор разметки ===================== }

function TFb2Parser.ParseMarkup(Elem: TDOMNode): TFb2ObjectList;
var
  N: TDOMNode;
  Txt, Name: UnicodeString;
begin
  Result := TFb2ObjectList.Create;
  if Elem = nil then
    Exit;
  N := Elem.FirstChild;
  while N <> nil do
  begin
    if N.NodeType = TEXT_NODE then
    begin
      Txt := N.NodeValue;
      if UTrim(Txt) <> '' then
        Result.Add(TStyleNode.Create(TEXT_NODE_NAME, Txt));
    end
    else if N.NodeType = ELEMENT_NODE then
    begin
      Name := LocalName(N.NodeName);
      if IsStyleTag(Name) then
        Result.Add(ParseStyleNode(TDOMElement(N)));
    end;
    N := N.NextSibling;
  end;
end;

function TFb2Parser.ParseStyleNode(Elem: TDOMElement): TStyleNode;
var
  Name: UnicodeString;
begin
  Name := LocalName(Elem.NodeName);
  Result := TStyleNode.Create(Name);
  FreeAndNil(Result.Children);
  Result.Children := ParseMarkup(Elem);
  if Name = 'style' then
    Result.StyleName := GetAttrQ(Elem, 'name')
  else if Name = 'a' then
  begin
    Result.Href := GetHref(Elem);
    Result.LinkType := GetAttrQ(Elem, 'type');
  end
  else if Name = 'image' then
  begin
    Result.ImageHref := GetHref(Elem);
    Result.ImageAlt := GetAttrQ(Elem, 'alt');
  end;
end;

function TFb2Parser.MarkupText(Nodes: TFb2ObjectList): UnicodeString;
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
      Result := Result + MarkupText(Node.Children);
  end;
end;

{ ===================== Блочные элементы ===================== }

function TFb2Parser.ParseBlock(Elem: TDOMElement): TFb2Object;
var
  Name: UnicodeString;
begin
  Result := nil;
  Name := LocalName(Elem.NodeName);
  if Name = 'p' then
    Result := ParseParagraph(Elem)
  else if Name = 'subtitle' then
    Result := ParseSubtitle(Elem)
  else if Name = 'empty-line' then
    Result := TEmptyLine.Create
  else if Name = 'poem' then
    Result := ParsePoem(Elem)
  else if Name = 'cite' then
    Result := ParseCite(Elem)
  else if Name = 'table' then
    Result := ParseTable(Elem)
  else if Name = 'image' then
    Result := ParseImage(Elem);
end;

function TFb2Parser.ParseParagraph(Elem: TDOMElement): TParagraph;
begin
  Result := TParagraph.Create;
  FreeAndNil(Result.Content);
  Result.Content := ParseMarkup(Elem);
  Result.Id := GetAttrQ(Elem, 'id');
  Result.Style := GetAttrQ(Elem, 'style');
  Result.Lang := GetXmlLang(Elem);
end;

function TFb2Parser.ParseSubtitle(Elem: TDOMElement): TSubtitle;
begin
  Result := TSubtitle.Create;
  FreeAndNil(Result.Content);
  Result.Content := ParseMarkup(Elem);
  Result.Id := GetAttrQ(Elem, 'id');
  Result.Style := GetAttrQ(Elem, 'style');
  Result.Lang := GetXmlLang(Elem);
end;

function TFb2Parser.ParseAnnotation(Elem: TDOMElement): TAnnotation;
var
  N: TDOMNode;
  Block: TFb2Object;
begin
  Result := TAnnotation.Create;
  Result.Id := GetAttrQ(Elem, 'id');
  Result.Lang := GetXmlLang(Elem);
  N := Elem.FirstChild;
  while N <> nil do
  begin
    if N.NodeType = ELEMENT_NODE then
    begin
      Block := ParseBlock(TDOMElement(N));
      if Block <> nil then
        Result.Items.Add(Block);
    end;
    N := N.NextSibling;
  end;
end;

function TFb2Parser.ParseTitle(Elem: TDOMElement): TTitle;
var
  N: TDOMNode;
  Name: UnicodeString;
begin
  Result := TTitle.Create;
  Result.Lang := GetXmlLang(Elem);
  N := Elem.FirstChild;
  while N <> nil do
  begin
    if N.NodeType = ELEMENT_NODE then
    begin
      Name := LocalName(N.NodeName);
      if Name = 'p' then
        Result.Items.Add(ParseParagraph(TDOMElement(N)))
      else if Name = 'empty-line' then
        Result.Items.Add(TEmptyLine.Create);
    end;
    N := N.NextSibling;
  end;
end;

function TFb2Parser.ParseEpigraph(Elem: TDOMElement): TEpigraph;
var
  N: TDOMNode;
  Block: TFb2Object;
begin
  Result := TEpigraph.Create;
  Result.Id := GetAttrQ(Elem, 'id');
  N := Elem.FirstChild;
  while N <> nil do
  begin
    if N.NodeType = ELEMENT_NODE then
    begin
      if LocalName(N.NodeName) = 'text-author' then
        Result.TextAuthor.Add(ParseParagraph(TDOMElement(N)))
      else
      begin
        Block := ParseBlock(TDOMElement(N));
        if Block <> nil then
          Result.Items.Add(Block);
      end;
    end;
    N := N.NextSibling;
  end;
end;

function TFb2Parser.ParseStanza(Elem: TDOMElement): TStanza;
var
  N: TDOMNode;
  Name: UnicodeString;
begin
  Result := TStanza.Create;
  Result.Lang := GetXmlLang(Elem);
  N := Elem.FirstChild;
  while N <> nil do
  begin
    if N.NodeType = ELEMENT_NODE then
    begin
      Name := LocalName(N.NodeName);
      if Name = 'title' then
        Result.Title := ParseTitle(TDOMElement(N))
      else if Name = 'subtitle' then
        Result.Subtitle := ParseSubtitle(TDOMElement(N))
      else if Name = 'v' then
        Result.Verses.Add(ParseParagraph(TDOMElement(N)));
    end;
    N := N.NextSibling;
  end;
end;

function TFb2Parser.ParsePoem(Elem: TDOMElement): TPoem;
var
  N: TDOMNode;
  Name: UnicodeString;
begin
  Result := TPoem.Create;
  Result.Id := GetAttrQ(Elem, 'id');
  Result.Lang := GetXmlLang(Elem);
  N := Elem.FirstChild;
  while N <> nil do
  begin
    if N.NodeType = ELEMENT_NODE then
    begin
      Name := LocalName(N.NodeName);
      if Name = 'title' then
        Result.Title := ParseTitle(TDOMElement(N))
      else if Name = 'epigraph' then
        Result.Epigraphs.Add(ParseEpigraph(TDOMElement(N)))
      else if Name = 'subtitle' then
        Result.Items.Add(ParseSubtitle(TDOMElement(N)))
      else if Name = 'stanza' then
        Result.Items.Add(ParseStanza(TDOMElement(N)))
      else if Name = 'text-author' then
        Result.TextAuthor.Add(ParseParagraph(TDOMElement(N)))
      else if Name = 'date' then
        Result.Date := ParseDate(TDOMElement(N));
    end;
    N := N.NextSibling;
  end;
end;

function TFb2Parser.ParseCite(Elem: TDOMElement): TCite;
var
  N: TDOMNode;
  Block: TFb2Object;
begin
  Result := TCite.Create;
  Result.Id := GetAttrQ(Elem, 'id');
  Result.Lang := GetXmlLang(Elem);
  N := Elem.FirstChild;
  while N <> nil do
  begin
    if N.NodeType = ELEMENT_NODE then
    begin
      if LocalName(N.NodeName) = 'text-author' then
        Result.TextAuthor.Add(ParseParagraph(TDOMElement(N)))
      else
      begin
        Block := ParseBlock(TDOMElement(N));
        if Block <> nil then
          Result.Items.Add(Block);
      end;
    end;
    N := N.NextSibling;
  end;
end;

function TFb2Parser.ParseTable(Elem: TDOMElement): TTable;
var
  TrList: TList;
  I: Integer;
  Tr, CellElem: TDOMElement;
  Row: TTableRow;
  N: TDOMNode;
  Cell: TTableCell;
  Name: UnicodeString;
begin
  Result := TTable.Create;
  Result.Style := GetAttrQ(Elem, 'style');
  Result.Id := GetAttrQ(Elem, 'id');
  TrList := FindChildElements(Elem, 'tr');
  try
    for I := 0 to TrList.Count - 1 do
    begin
      Tr := TDOMElement(TrList[I]);
      Row := TTableRow.Create;
      Row.Align := ToAlignEnum(GetAttrQ(Tr, 'align'));
      N := Tr.FirstChild;
      while N <> nil do
      begin
        if N.NodeType = ELEMENT_NODE then
        begin
          Name := LocalName(N.NodeName);
          if (Name = 'td') or (Name = 'th') then
          begin
            CellElem := TDOMElement(N);
            Cell := TTableCell.Create(Name);
            FreeAndNil(Cell.Children);
            Cell.Children := ParseMarkup(CellElem);
            Cell.Colspan := ToIntDef(GetAttrQ(CellElem, 'colspan'), NO_VALUE);
            Cell.Rowspan := ToIntDef(GetAttrQ(CellElem, 'rowspan'), NO_VALUE);
            Cell.Align := ToAlignEnum(GetAttrQ(CellElem, 'align'));
            Cell.VAlign := ToVAlignEnum(GetAttrQ(CellElem, 'valign'));
            Cell.Style := GetAttrQ(CellElem, 'style');
            Cell.Id := GetAttrQ(CellElem, 'id');
            Cell.IsHeader := (Name = 'th');
            Row.Cells.Add(Cell);
          end;
        end;
        N := N.NextSibling;
      end;
      Result.Rows.Add(Row);
    end;
  finally
    TrList.Free;
  end;
end;

function TFb2Parser.ParseImage(Elem: TDOMElement): TImage;
begin
  Result := TImage.Create;
  Result.Href := GetHref(Elem);
  Result.Alt := GetAttrQ(Elem, 'alt');
  Result.Title := GetAttrQ(Elem, 'title');
  Result.Id := GetAttrQ(Elem, 'id');
  Result.XlinkType := GetAttrQ(Elem, 'xlink:type');
end;

{ ===================== Простые элементы ===================== }

function TFb2Parser.ParseTextField(Elem: TDOMElement): TTextField;
begin
  Result := TTextField.Create;
  Result.Value := ElementText(Elem);
  Result.Lang := GetXmlLang(Elem);
end;

function TFb2Parser.ParseDate(Elem: TDOMElement): TDateField;
begin
  Result := TDateField.Create;
  Result.Value := ElementText(Elem);
  Result.DateValue := GetAttrQ(Elem, 'value');
  Result.Lang := GetXmlLang(Elem);
end;

{ ===================== Автор, жанр, серия, обложка ===================== }

function TFb2Parser.ParseAuthor(Elem: TDOMElement): TAuthor;
var
  Child: TDOMElement;
  List: TList;
  I: Integer;
begin
  Result := TAuthor.Create;
  Child := FindChildElement(Elem, 'first-name');
  if Child <> nil then Result.FirstName := ElementText(Child);
  Child := FindChildElement(Elem, 'middle-name');
  if Child <> nil then Result.MiddleName := ElementText(Child);
  Child := FindChildElement(Elem, 'last-name');
  if Child <> nil then Result.LastName := ElementText(Child);
  Child := FindChildElement(Elem, 'nickname');
  if Child <> nil then Result.Nickname := ElementText(Child);
  Child := FindChildElement(Elem, 'id');
  if Child <> nil then Result.Id := ElementText(Child);

  List := FindChildElements(Elem, 'home-page');
  try
    for I := 0 to List.Count - 1 do
      Result.HomePages.Add(ElementText(TDOMNode(List[I])));
  finally
    List.Free;
  end;
  List := FindChildElements(Elem, 'email');
  try
    for I := 0 to List.Count - 1 do
      Result.Emails.Add(ElementText(TDOMNode(List[I])));
  finally
    List.Free;
  end;
end;

function TFb2Parser.ParseGenre(Elem: TDOMElement): TGenre;
begin
  Result := TGenre.Create;
  Result.Value := ElementText(Elem);
  Result.Match := ToIntDef(GetAttrQ(Elem, 'match'), 100);
end;

function TFb2Parser.ParseSequence(Elem: TDOMElement): TSequence;
var
  List: TList;
  I: Integer;
begin
  Result := TSequence.Create;
  Result.Name := GetAttrQ(Elem, 'name');
  Result.Number := ToIntDef(GetAttrQ(Elem, 'number'), NO_VALUE);
  Result.Lang := GetXmlLang(Elem);
  List := FindChildElements(Elem, 'sequence');
  try
    for I := 0 to List.Count - 1 do
      Result.Sequences.Add(ParseSequence(TDOMElement(List[I])));
  finally
    List.Free;
  end;
end;

function TFb2Parser.ParseInlineImage(Elem: TDOMElement): TInlineImage;
begin
  Result := TInlineImage.Create;
  Result.Href := GetHref(Elem);
  Result.Alt := GetAttrQ(Elem, 'alt');
  Result.XlinkType := GetAttrQ(Elem, 'xlink:type');
end;

function TFb2Parser.ParseCoverpage(Elem: TDOMElement): TCoverPage;
var
  List: TList;
  I: Integer;
begin
  Result := TCoverPage.Create;
  List := FindChildElements(Elem, 'image');
  try
    for I := 0 to List.Count - 1 do
      Result.Images.Add(ParseInlineImage(TDOMElement(List[I])));
  finally
    List.Free;
  end;
end;

{ ===================== title-info и прочие info ===================== }

function TFb2Parser.ParseTitleInfo(Elem: TDOMElement): TTitleInfo;
var
  N: TDOMNode;
  Name: UnicodeString;
begin
  Result := TTitleInfo.Create;
  N := Elem.FirstChild;
  while N <> nil do
  begin
    if N.NodeType = ELEMENT_NODE then
    begin
      Name := LocalName(N.NodeName);
      if Name = 'genre' then
        Result.Genres.Add(ParseGenre(TDOMElement(N)))
      else if Name = 'author' then
        Result.Authors.Add(ParseAuthor(TDOMElement(N)))
      else if Name = 'book-title' then
        Result.BookTitle := ParseTextField(TDOMElement(N))
      else if Name = 'annotation' then
        Result.Annotation := ParseAnnotation(TDOMElement(N))
      else if Name = 'keywords' then
        Result.Keywords := ParseTextField(TDOMElement(N))
      else if Name = 'date' then
        Result.Date := ParseDate(TDOMElement(N))
      else if Name = 'coverpage' then
        Result.Coverpage := ParseCoverpage(TDOMElement(N))
      else if Name = 'lang' then
        Result.Lang := ElementText(N)
      else if Name = 'src-lang' then
        Result.SrcLang := ElementText(N)
      else if Name = 'translator' then
        Result.Translators.Add(ParseAuthor(TDOMElement(N)))
      else if Name = 'sequence' then
        Result.Sequences.Add(ParseSequence(TDOMElement(N)));
    end;
    N := N.NextSibling;
  end;
end;

function TFb2Parser.ParseDocumentInfo(Elem: TDOMElement): TDocumentInfo;
var
  N: TDOMNode;
  Name: UnicodeString;
  F: Double;
  Ok: Boolean;
begin
  Result := TDocumentInfo.Create;
  N := Elem.FirstChild;
  while N <> nil do
  begin
    if N.NodeType = ELEMENT_NODE then
    begin
      Name := LocalName(N.NodeName);
      if Name = 'author' then
        Result.Authors.Add(ParseAuthor(TDOMElement(N)))
      else if Name = 'program-used' then
        Result.ProgramUsed := ParseTextField(TDOMElement(N))
      else if Name = 'date' then
        Result.Date := ParseDate(TDOMElement(N))
      else if Name = 'src-url' then
        Result.SrcUrls.Add(ElementText(N))
      else if Name = 'src-ocr' then
        Result.SrcOcr := ParseTextField(TDOMElement(N))
      else if Name = 'id' then
        Result.Id := ElementText(N)
      else if Name = 'version' then
      begin
        F := ToFloatDef(ElementText(N), 0.0, Ok);
        if Ok then
        begin
          Result.Version := F;
          Result.HasVersion := True;
        end;
      end
      else if Name = 'history' then
        Result.History := ParseAnnotation(TDOMElement(N))
      else if Name = 'publisher' then
        Result.Publishers.Add(ParseAuthor(TDOMElement(N)));
    end;
    N := N.NextSibling;
  end;
end;

function TFb2Parser.ParsePublishInfo(Elem: TDOMElement): TPublishInfo;
var
  N: TDOMNode;
  Name: UnicodeString;
begin
  Result := TPublishInfo.Create;
  N := Elem.FirstChild;
  while N <> nil do
  begin
    if N.NodeType = ELEMENT_NODE then
    begin
      Name := LocalName(N.NodeName);
      if Name = 'book-name' then
        Result.BookName := ParseTextField(TDOMElement(N))
      else if Name = 'publisher' then
        Result.Publisher := ParseTextField(TDOMElement(N))
      else if Name = 'city' then
        Result.City := ParseTextField(TDOMElement(N))
      else if Name = 'year' then
        Result.Year := ElementText(N)
      else if Name = 'isbn' then
        Result.Isbn := ParseTextField(TDOMElement(N))
      else if Name = 'sequence' then
        Result.Sequences.Add(ParseSequence(TDOMElement(N)));
    end;
    N := N.NextSibling;
  end;
end;

function TFb2Parser.ParseCustomInfo(Elem: TDOMElement): TCustomInfo;
begin
  Result := TCustomInfo.Create;
  Result.Value := ElementText(Elem);
  Result.InfoType := GetAttrQ(Elem, 'info-type');
end;

function TFb2Parser.ParseStylesheetElem(Elem: TDOMElement): TStylesheet;
begin
  Result := TStylesheet.Create;
  Result.SheetType := GetAttrQ(Elem, 'type');
  Result.Value := ElementText(Elem);
end;

function TFb2Parser.ParseBinaryElem(Elem: TDOMElement): TBinary;
var
  CT: UnicodeString;
begin
  Result := TBinary.Create;
  Result.Id := GetAttrQ(Elem, 'id');
  CT := GetAttrQ(Elem, 'content-type');
  if CT = '' then
    CT := DEFAULT_CONTENT_TYPE;
  Result.ContentType := CT;
  Result.Data := ElementText(Elem);
end;

{ ===================== Вывод (для CLI) ===================== }

function TFb2Parser.FormatAuthor(Author: TAuthor): UnicodeString;
var
  Parts: TTextList;
begin
  Parts := TTextList.Create;
  try
    if Author.FirstName <> '' then Parts.Add(Author.FirstName);
    if Author.MiddleName <> '' then Parts.Add(Author.MiddleName);
    if Author.LastName <> '' then Parts.Add(Author.LastName);
    Result := JoinText(Parts, ' ');
  finally
    Parts.Free;
  end;
  if Result = '' then
  begin
    if Author.Nickname <> '' then
      Result := Author.Nickname
    else
      Result := '—';
  end;
end;

function TFb2Parser.Describe(Description: TDescription): UnicodeString;
var
  Lines: TTextList;
  TI: TTitleInfo;
  DI: TDocumentInfo;
  PI: TPublishInfo;
  I: Integer;
  S: UnicodeString;
  GenreParts, AuthorParts, ImgParts: TTextList;
begin
  Lines := TTextList.Create;
  try
    TI := Description.TitleInfo;
    if TI <> nil then
    begin
      Lines.Add('== title-info ==');
      GenreParts := TTextList.Create;
      try
        for I := 0 to TI.Genres.Count - 1 do
          GenreParts.Add(TGenre(TI.Genres[I]).Value + ' (' +
            IntToStr(TGenre(TI.Genres[I]).Match) + '%)');
        Lines.Add('жанры: ' + JoinText(GenreParts, ', '));
      finally
        GenreParts.Free;
      end;
      AuthorParts := TTextList.Create;
      try
        for I := 0 to TI.Authors.Count - 1 do
          AuthorParts.Add(FormatAuthor(TAuthor(TI.Authors[I])));
        Lines.Add('авторы: ' + JoinText(AuthorParts, '; '));
      finally
        AuthorParts.Free;
      end;
      if TI.BookTitle <> nil then
        Lines.Add('название: ' + TI.BookTitle.Value);
      Lines.Add('язык: ' + TI.Lang + ' | src-lang: ' + TI.SrcLang);
      if TI.Date <> nil then
        Lines.Add('дата: ' + TI.Date.Value + ' | value: ' + TI.Date.DateValue);
      if TI.Keywords <> nil then
        Lines.Add('ключевые слова: ' + TI.Keywords.Value);
      if TI.Coverpage <> nil then
      begin
        ImgParts := TTextList.Create;
        try
          for I := 0 to TI.Coverpage.Images.Count - 1 do
            ImgParts.Add(TInlineImage(TI.Coverpage.Images[I]).Href);
          Lines.Add('обложка: [' + JoinText(ImgParts, ', ') + ']');
        finally
          ImgParts.Free;
        end;
      end;
      for I := 0 to TI.Sequences.Count - 1 do
      begin
        S := TSequence(TI.Sequences[I]).Name + ' ' +
          IdOrNone(TSequence(TI.Sequences[I]).Number);
        Lines.Add('серия: ' + S);
      end;
    end;

    DI := Description.DocumentInfo;
    if DI <> nil then
    begin
      Lines.Add('== document-info ==');
      if DI.HasVersion then
        Lines.Add('id: ' + DI.Id + ' | version: ' + FloatToStr(DI.Version))
      else
        Lines.Add('id: ' + DI.Id + ' | version: ');
      if DI.Date <> nil then
        Lines.Add('дата: ' + DI.Date.Value);
      AuthorParts := TTextList.Create;
      try
        for I := 0 to DI.Authors.Count - 1 do
          AuthorParts.Add(FormatAuthor(TAuthor(DI.Authors[I])));
        Lines.Add('авторы документа: ' + JoinText(AuthorParts, '; '));
      finally
        AuthorParts.Free;
      end;
      if DI.ProgramUsed <> nil then
        Lines.Add('программа: ' + DI.ProgramUsed.Value);
    end;

    PI := Description.PublishInfo;
    if PI <> nil then
    begin
      Lines.Add('== publish-info ==');
      if PI.BookName <> nil then Lines.Add('книга: ' + PI.BookName.Value);
      if PI.Publisher <> nil then Lines.Add('издательство: ' + PI.Publisher.Value);
      if PI.City <> nil then Lines.Add('город: ' + PI.City.Value);
      if PI.Isbn <> nil then Lines.Add('ISBN: ' + PI.Isbn.Value);
      Lines.Add('год: ' + PI.Year);
    end;

    for I := 0 to Description.CustomInfos.Count - 1 do
      Lines.Add('custom-info[' + TCustomInfo(Description.CustomInfos[I]).InfoType +
        ']: ' + TCustomInfo(Description.CustomInfos[I]).Value);

    Result := JoinText(Lines, #10);
  finally
    Lines.Free;
  end;
end;

end.
