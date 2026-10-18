unit fb3_to_fb2;
{ Преобразование FictionBook 3 (FB3) в книгу FB2 — перевод fb3_to_fb2.py.

  Модуль читает OPC-контейнер FB3 (ZIP): fb3/description.xml (метаданные),
  fb3/body.xml (текст), связи *_rels/*.rels (тело и изображения) и собирает
  структуру TFictionBook (fb2_structures). XML разбирается через fcl-xml (DOM).

  Обратное преобразование к fb2_to_fb3.pas.

  Пример:
      C := TFb3ToFb2Converter.Create;
      try
        C.Write('book.fb3', 'book.fb2');
      finally
        C.Free;
      end;

  Особенности перевода с Python:
      * вместо ElementTree — DOM из fcl-xml; сопоставление по локальному имени;
      * xlink:href читается через GetAttributeNS с фолбэком;
      * ZIP читается через TEpubArchive (fb2_archive.pas). }

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Classes, SysUtils, fgl, DOM, XMLRead,
  fb2_structures, fb2_writer, fb2_errors, fb2_images, fb2_archive;

const
  { Пространства имён FB3. }
  NS_DESCR = 'http://www.fictionbook.org/FictionBook3/description';
  NS_BODY = 'http://www.fictionbook.org/FictionBook3/body';
  NS_XLINK = 'http://www.w3.org/1999/xlink';
  NS_RELS = 'http://schemas.openxmlformats.org/package/2006/relationships';

  { Типы связей FB3. }
  REL_BOOK = 'http://www.fictionbook.org/FictionBook3/relationships/Book';
  REL_BODY = 'http://www.fictionbook.org/FictionBook3/relationships/body';
  REL_IMAGE = 'http://www.fictionbook.org/FictionBook3/relationships/image';
  REL_THUMBNAIL =
    'http://schemas.openxmlformats.org/package/2006/relationships/metadata/thumbnail';

  { Пути частей по умолчанию (если связи не указаны). }
  DEFAULT_DESCRIPTION = 'fb3/description.xml';
  DEFAULT_BODY = 'fb3/body.xml';

  { Значения по умолчанию для отсутствующих метаданных. }
  DEFAULT_GENRE = 'sf';
  DEFAULT_PROGRAM_USED = 'pyFB2';

type
  { Поля субъекта-автора (first/middle/last/main). }
  TSubjectParts = record
    First: UnicodeString;
    Middle: UnicodeString;
    Last: UnicodeString;
    Main: UnicodeString;
  end;

  { Метаданные, прочитанные из fb3-description. }
  TFb3Meta = class
  public
    Title: UnicodeString;
    Language: UnicodeString;
    Authors: array of TSubjectParts;
    Genres: TTextList;
    Annotation: TTextList;
    constructor Create;
    destructor Destroy; override;
  end;

  { Преобразование FB3 в FB2. }
  TFb3ToFb2Converter = class
  private
    FWriter: TFb2Writer;
    FDefaultGenre: UnicodeString;
    FProgramUsed: UnicodeString;
    FSource: UnicodeString;
    FBook: TFictionBook;
    FZip: TEpubArchive;
    FImages: TStringList;        { rel_id -> путь в архиве }
    FBinaries: TFb2ObjectList;   { список TBinary }
    FBinaryIds: TStringList;     { путь -> id в FB2 }
    FCoverId: UnicodeString;
    FParseDocs: TList;           { TXMLDocument, разобранные за один Convert }

    procedure Reset;
    function ReadZip(const Name: UnicodeString): TBytes;
    function ParseBytes(const Data: TBytes): TXMLDocument;
    function TryPart(const Name: UnicodeString; out Root: TDOMElement): Boolean;
    function ReadPart(const Name: UnicodeString): TDOMElement;
    function FindPart(const RelsPath, RelType,
      Default: UnicodeString): UnicodeString;
    procedure LoadImages(const BodyPath: UnicodeString);
    procedure LoadCover;
    function ReadDescription(const Path: UnicodeString): TFb3Meta;
    function RegisterBinary(const RelId: UnicodeString): UnicodeString;

    function ConvertBody(Root: TDOMElement): TBody;
    function ConvertSection(Elem: TDOMElement): TSection;
    function TitleNode(Elem: TDOMElement): TTitle;
    function EpigraphNode(Elem: TDOMElement): TEpigraph;
    function AnnotationNode(Elem: TDOMElement): TAnnotation;
    function ConvertBlock(Elem: TDOMElement): TFb2Object;
    function PoemNode(Elem: TDOMElement): TPoem;
    function StanzaNode(Elem: TDOMElement): TStanza;
    function CiteNode(Elem: TDOMElement): TCite;
    function TableNode(Elem: TDOMElement): TTable;
    function InlineNodes(Elem: TDOMElement): TFb2ObjectList;
    procedure InlineNodesInto(Elem: TDOMElement; Dest: TFb2ObjectList);
    function BlockImages(Elem: TDOMElement): TList;
    procedure CollectSubscription(Elem: TDOMElement; Target: TFb2ObjectList);

    function Assemble(Meta: TFb3Meta; Body: TBody): TFictionBook;
  public
    constructor Create(AWriter: TFb2Writer = nil;
      const ADefaultGenre: UnicodeString = DEFAULT_GENRE;
      const AProgramUsed: UnicodeString = DEFAULT_PROGRAM_USED);
    destructor Destroy; override;

    { Прочитать FB3 и вернуть структуру TFictionBook (владелец — конвертер). }
    function Convert(const Source: UnicodeString = ''): TFictionBook;

    { Сериализовать книгу (или результат Convert) в XML FB2. }
    function ToXml(Book: TFictionBook = nil): UnicodeString;

    { Преобразовать FB3 в файл FB2 и вернуть путь к результату. }
    function Write(const Source: UnicodeString;
      const Output: UnicodeString = ''): UnicodeString;

    property Book: TFictionBook read FBook;
  end;

implementation

uses
  fb2_parser,   { LocalName, Base64DecodeString }
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

{ Убрать ведущие слэши (аналог str.lstrip('/')). }
function LStripSlash(const S: UnicodeString): UnicodeString;
var
  I: Integer;
begin
  I := 1;
  while (I <= Length(S)) and (S[I] = '/') do
    Inc(I);
  Result := Copy(S, I, MaxInt);
end;

{ Позиция последнего вхождения подстроки Sub в S (0 — нет). }
function RPosSub(const Sub, S: UnicodeString): Integer;
var
  I: Integer;
begin
  Result := 0;
  if (Sub = '') or (Length(Sub) > Length(S)) then
    Exit;
  for I := Length(S) - Length(Sub) + 1 downto 1 do
    if Copy(S, I, Length(Sub)) = Sub then
      Exit(I);
end;

{ Значение атрибута элемента (пусто, если нет). }
function GetAttr(E: TDOMElement; const Name: UnicodeString): UnicodeString;
begin
  if E = nil then
    Exit('');
  Result := E.GetAttribute(Name);
end;

{ xlink:href с фолбэком на квалифицированное и локальное имя. }
function GetXlinkHref(E: TDOMElement): UnicodeString;
begin
  Result := '';
  if E = nil then
    Exit;
  try
    Result := E.GetAttributeNS(NS_XLINK, 'href');
  except
    Result := '';
  end;
  if Result = '' then
    Result := E.GetAttribute('xlink:href');
  if Result = '' then
    Result := E.GetAttribute('href');
end;

{ Ведущий текстовый узел элемента (аналог ElementTree .text). }
function LeadingText(E: TDOMNode): UnicodeString;
begin
  Result := '';
  if (E <> nil) and (E.FirstChild <> nil) and
    (E.FirstChild.NodeType = TEXT_NODE) then
    Result := E.FirstChild.NodeValue;
end;

{ Весь текст поддерева (аналог ''.join(...) по всем текстовым узлам). }
function CollectText(N: TDOMNode): UnicodeString;
var
  C: TDOMNode;
begin
  Result := '';
  if N = nil then
    Exit;
  C := N.FirstChild;
  while C <> nil do
  begin
    if C.NodeType = TEXT_NODE then
      Result := Result + C.NodeValue
    else if C.NodeType = ELEMENT_NODE then
      Result := Result + CollectText(C);
    C := C.NextSibling;
  end;
end;

{ Inline-теги FB3 -> теги разметки FB2 ('' — не тег разметки). }
function MapMarkupTag(const Local: UnicodeString): UnicodeString;
begin
  if Local = 'strong' then
    Result := 'strong'
  else if Local = 'em' then
    Result := 'emphasis'
  else if Local = 'code' then
    Result := 'code'
  else if Local = 'strikethrough' then
    Result := 'strikethrough'
  else if Local = 'sub' then
    Result := 'sub'
  else if Local = 'sup' then
    Result := 'sup'
  else
    Result := '';
end;

{ Разбить строку по пробельным символам (аналог str.split()). }
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

{ Сегодняшняя дата в формате ISO (date.today().isoformat()). }
function TodayIso: UnicodeString;
begin
  Result := FormatDateTime('yyyy-mm-dd', Now);
end;

{ Новый UUID без дефисов, как uuid.uuid4().hex. }
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

{ ===================== TFb3Meta ===================== }

constructor TFb3Meta.Create;
begin
  inherited Create;
  Title := '';
  Language := '';
  SetLength(Authors, 0);
  Genres := TTextList.Create;
  Annotation := TTextList.Create;
end;

destructor TFb3Meta.Destroy;
begin
  FreeAndNil(Genres);
  FreeAndNil(Annotation);
  inherited Destroy;
end;

{ Получить значение карты "ключ=значение" по имени ключа. }
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

{ Записать значение в карту "ключ=значение". }
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

{ Имя оканчивается на известное расширение изображения. }
function IsImageTarget(const LowerName: UnicodeString): Boolean;
const
  EXTS: array[0..5] of UnicodeString =
    ('.png', '.jpg', '.jpeg', '.gif', '.svg', '.webp');
var
  I: Integer;
begin
  Result := False;
  for I := Low(EXTS) to High(EXTS) do
    if (Length(LowerName) >= Length(EXTS[I])) and
      (Copy(LowerName, Length(LowerName) - Length(EXTS[I]) + 1, Length(EXTS[I]))
        = EXTS[I]) then
      Exit(True);
end;

{ Текст дочернего элемента по локальному имени (аналог _child_text). }
function ChildText(Parent: TDOMElement; const Name: UnicodeString): UnicodeString;
var
  C: TDOMNode;
  E: TDOMElement;
begin
  Result := '';
  if Parent = nil then
    Exit;
  C := Parent.FirstChild;
  while C <> nil do
  begin
    if C.NodeType = ELEMENT_NODE then
    begin
      E := TDOMElement(C);
      if LocalName(E.TagName) = Name then
        Exit(UTrim(LeadingText(E)));
    end;
    C := C.NextSibling;
  end;
end;

{ Поля субъекта-автора (first/middle/last/main). }
function SubjectParts(SE: TDOMElement): TSubjectParts;
var
  C: TDOMNode;
  E: TDOMElement;
  Local, T: UnicodeString;
begin
  Result.First := '';
  Result.Middle := '';
  Result.Last := '';
  Result.Main := '';
  if SE = nil then
    Exit;
  C := SE.FirstChild;
  while C <> nil do
  begin
    if C.NodeType = ELEMENT_NODE then
    begin
      E := TDOMElement(C);
      Local := LocalName(E.TagName);
      T := UTrim(LeadingText(E));
      if Local = 'first-name' then
        Result.First := T
      else if Local = 'middle-name' then
        Result.Middle := T
      else if Local = 'last-name' then
        Result.Last := T
      else if Local = 'title' then
        Result.Main := ChildText(E, 'main');
    end;
    C := C.NextSibling;
  end;
end;

{ ===================== TFb3ToFb2Converter ===================== }

constructor TFb3ToFb2Converter.Create(AWriter: TFb2Writer;
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
  FImages := nil;
  FBinaries := nil;
  FBinaryIds := nil;
  FParseDocs := nil;
  FCoverId := '';
  Reset;
end;

destructor TFb3ToFb2Converter.Destroy;
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
  FreeAndNil(FImages);
  FreeAndNil(FBinaries);
  FreeAndNil(FBinaryIds);
  FreeAndNil(FWriter);
  inherited Destroy;
end;

procedure TFb3ToFb2Converter.Reset;
var
  I: Integer;
begin
  FreeAndNil(FBook);
  FreeAndNil(FImages);
  FImages := TStringList.Create;
  FImages.CaseSensitive := True;
  FImages.NameValueSeparator := '=';
  FreeAndNil(FBinaries);
  FBinaries := TFb2ObjectList.Create;
  FreeAndNil(FBinaryIds);
  FBinaryIds := TStringList.Create;
  FBinaryIds.CaseSensitive := True;
  FBinaryIds.NameValueSeparator := '=';
  if FParseDocs <> nil then
  begin
    { Освободить XML-документы, разобранные в предыдущем преобразовании. }
    for I := 0 to FParseDocs.Count - 1 do
      TObject(FParseDocs[I]).Free;
    FreeAndNil(FParseDocs);
  end;
  FParseDocs := TList.Create;
  FCoverId := '';
end;

{ ===================== Чтение контейнера ===================== }

function TFb3ToFb2Converter.ReadZip(const Name: UnicodeString): TBytes;
begin
  SetLength(Result, 0);
  if (FZip <> nil) and FZip.Has(Name) then
    Result := FZip.Read(Name);
end;

function TFb3ToFb2Converter.ParseBytes(const Data: TBytes): TXMLDocument;
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

function TFb3ToFb2Converter.TryPart(const Name: UnicodeString;
  out Root: TDOMElement): Boolean;
var
  Data: TBytes;
  Doc: TXMLDocument;
begin
  Root := nil;
  Data := ReadZip(Name);
  if Length(Data) = 0 then
    Exit(False);
  try
    Doc := ParseBytes(Data);
  except
    Exit(False);
  end;
  FParseDocs.Add(Doc);
  Root := Doc.DocumentElement;
  Result := Root <> nil;
end;

function TFb3ToFb2Converter.ReadPart(const Name: UnicodeString): TDOMElement;
var
  Data: TBytes;
  Doc: TXMLDocument;
begin
  Data := ReadZip(Name);
  if Length(Data) = 0 then
    raise EFb2ConversionError.Create('В FB3 не найдена часть: ' + Name);
  try
    Doc := ParseBytes(Data);
  except
    raise EFb2ConversionError.Create('Не удалось разобрать ' + Name);
  end;
  FParseDocs.Add(Doc);
  Result := Doc.DocumentElement;
  if Result = nil then
    raise EFb2ConversionError.Create('Не удалось разобрать ' + Name);
end;

function TFb3ToFb2Converter.FindPart(const RelsPath, RelType,
  Default: UnicodeString): UnicodeString;
var
  Root: TDOMElement;
  C: TDOMNode;
  E: TDOMElement;
  Target, Base: UnicodeString;
  P: Integer;
begin
  Result := Default;
  if not TryPart(RelsPath, Root) then
    Exit;
  C := Root.FirstChild;
  while C <> nil do
  begin
    if C.NodeType = ELEMENT_NODE then
    begin
      E := TDOMElement(C);
      if (LocalName(E.TagName) = 'Relationship') and
        (GetAttr(E, 'Type') = RelType) then
      begin
        Target := GetAttr(E, 'Target');
        if Target <> '' then
        begin
          if RelsPath = '_rels/.rels' then
            Exit(LStripSlash(Target));
          P := RPosSub('/_rels/', RelsPath);
          if P > 0 then
            Base := Copy(RelsPath, 1, P - 1)
          else
            Base := RelsPath;
          Exit(LStripSlash(Base + '/' + Target));
        end;
      end;
    end;
    C := C.NextSibling;
  end;
end;

procedure TFb3ToFb2Converter.LoadImages(const BodyPath: UnicodeString);
var
  Root: TDOMElement;
  C: TDOMNode;
  E: TDOMElement;
  RelsPath, Base, Folder, Name, RelId, Target, RelType, Path: UnicodeString;
  P: Integer;
begin
  if Pos('/', BodyPath) > 0 then
  begin
    P := RPosSub('/', BodyPath);
    Folder := Copy(BodyPath, 1, P - 1);
    Name := Copy(BodyPath, P + 1, MaxInt);
    RelsPath := Folder + '/_rels/' + Name + '.rels';
    Base := Folder;
  end
  else
  begin
    RelsPath := '_rels/' + BodyPath + '.rels';
    Base := '';
  end;
  if not TryPart(RelsPath, Root) then
    Exit;
  C := Root.FirstChild;
  while C <> nil do
  begin
    if C.NodeType = ELEMENT_NODE then
    begin
      E := TDOMElement(C);
      if LocalName(E.TagName) = 'Relationship' then
      begin
        RelId := GetAttr(E, 'Id');
        Target := GetAttr(E, 'Target');
        if (RelId <> '') and (Target <> '') then
        begin
          RelType := GetAttr(E, 'Type');
          if ((RelType = '') or (RelType = REL_IMAGE)) and
            IsImageTarget(LowerCase(Target)) then
          begin
            if Base <> '' then
              Path := LStripSlash(Base + '/' + Target)
            else
              Path := Target;
            MapSet(FImages, RelId, Path);
          end;
        end;
      end;
    end;
    C := C.NextSibling;
  end;
end;

procedure TFb3ToFb2Converter.LoadCover;
var
  CoverPath: UnicodeString;
begin
  CoverPath := FindPart('_rels/.rels', REL_THUMBNAIL, '');
  if CoverPath = '' then
    Exit;
  MapSet(FImages, '__cover__', CoverPath);
  FCoverId := RegisterBinary('__cover__');
end;

function TFb3ToFb2Converter.ReadDescription(const Path: UnicodeString): TFb3Meta;
var
  Root: TDOMElement;
  C, C2: TDOMNode;
  E, SE: TDOMElement;
  Local, T: UnicodeString;
  Parts: TSubjectParts;
begin
  Root := ReadPart(Path);
  Result := TFb3Meta.Create;
  C := Root.FirstChild;
  while C <> nil do
  begin
    if C.NodeType = ELEMENT_NODE then
    begin
      E := TDOMElement(C);
      Local := LocalName(E.TagName);
      if Local = 'title' then
      begin
        T := ChildText(E, 'main');
        if T <> '' then
          Result.Title := T;
      end
      else if Local = 'fb3-relations' then
      begin
        C2 := E.FirstChild;
        while C2 <> nil do
        begin
          if C2.NodeType = ELEMENT_NODE then
          begin
            SE := TDOMElement(C2);
            if (LocalName(SE.TagName) = 'subject') and
              (GetAttr(SE, 'link') = 'author') then
            begin
              Parts := SubjectParts(SE);
              SetLength(Result.Authors, Length(Result.Authors) + 1);
              Result.Authors[High(Result.Authors)] := Parts;
            end;
          end;
          C2 := C2.NextSibling;
        end;
      end
      else if Local = 'fb3-classification' then
      begin
        C2 := E.FirstChild;
        while C2 <> nil do
        begin
          if C2.NodeType = ELEMENT_NODE then
          begin
            SE := TDOMElement(C2);
            if LocalName(SE.TagName) = 'subject' then
            begin
              T := UTrim(LeadingText(SE));
              if T <> '' then
                Result.Genres.Add(T);
            end;
          end;
          C2 := C2.NextSibling;
        end;
      end
      else if Local = 'lang' then
      begin
        T := UTrim(LeadingText(E));
        if T <> '' then
          Result.Language := T;
      end
      else if Local = 'annotation' then
      begin
        C2 := E.FirstChild;
        while C2 <> nil do
        begin
          if C2.NodeType = ELEMENT_NODE then
          begin
            SE := TDOMElement(C2);
            if LocalName(SE.TagName) = 'p' then
            begin
              T := UTrim(CollectText(SE));
              if T <> '' then
                Result.Annotation.Add(T);
            end;
          end;
          C2 := C2.NextSibling;
        end;
      end;
    end;
    C := C.NextSibling;
  end;
end;

function TFb3ToFb2Converter.RegisterBinary(const RelId: UnicodeString): UnicodeString;
var
  Path, MediaType, Ext, Base, BinaryId: UnicodeString;
  Data: TBytes;
  Bin: TBinary;
  I: Integer;
begin
  Result := '';
  Path := MapGet(FImages, RelId);
  if Path = '' then
    Exit;
  I := FBinaryIds.IndexOfName(Path);
  if I >= 0 then
    Exit(FBinaryIds.ValueFromIndex[I]);
  Data := ReadZip(Path);
  if Length(Data) = 0 then
    Exit;
  MediaType := DetectImageType(Data, Ext);
  Base := ChangeFileExt(ExtractFileName(Path), '');
  if Base = '' then
    Base := 'image';
  BinaryId := Base + Ext;
  MapSet(FBinaryIds, Path, BinaryId);
  Bin := TBinary.Create;
  Bin.Id := BinaryId;
  Bin.ContentType := MediaType;
  Bin.Data := Base64EncodeBytes(Data);
  FBinaries.Add(Bin);
  Result := BinaryId;
end;

{ ===================== Тело ===================== }

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

function TFb3ToFb2Converter.ConvertBody(Root: TDOMElement): TBody;
var
  Loose: TFb2ObjectList;
  C: TDOMNode;
  E: TDOMElement;
  Local: UnicodeString;
  Block: TFb2Object;
  Sec: TSection;
begin
  Result := TBody.Create;
  Loose := TFb2ObjectList.Create;
  C := Root.FirstChild;
  while C <> nil do
  begin
    if C.NodeType = ELEMENT_NODE then
    begin
      E := TDOMElement(C);
      Local := LocalName(E.TagName);
      if Local = 'title' then
        Result.Title := TitleNode(E)
      else if Local = 'epigraph' then
        Result.Epigraphs.Add(EpigraphNode(E))
      else if Local = 'section' then
        Result.Sections.Add(ConvertSection(E))
      else
      begin
        Block := ConvertBlock(E);
        if Block <> nil then
          Loose.Add(Block);
      end;
    end;
    C := C.NextSibling;
  end;
  if Loose.Count > 0 then
  begin
    Sec := TSection.Create;
    FreeAndNil(Sec.Content);
    Sec.Content := Loose;
    Loose := nil;
    Result.Sections.Insert(0, Sec);
  end;
  if Result.Sections.Count = 0 then
    Result.Sections.Add(TSection.Create);
  Loose.Free;
end;

function TFb3ToFb2Converter.ConvertSection(Elem: TDOMElement): TSection;
var
  C: TDOMNode;
  E: TDOMElement;
  Local: UnicodeString;
  Block: TFb2Object;
begin
  Result := TSection.Create;
  C := Elem.FirstChild;
  while C <> nil do
  begin
    if C.NodeType = ELEMENT_NODE then
    begin
      E := TDOMElement(C);
      Local := LocalName(E.TagName);
      if Local = 'title' then
        Result.Title := TitleNode(E)
      else if Local = 'epigraph' then
        Result.Epigraphs.Add(EpigraphNode(E))
      else if Local = 'annotation' then
        Result.Annotation := AnnotationNode(E)
      else if Local = 'section' then
        Result.Sections.Add(ConvertSection(E))
      else
      begin
        Block := ConvertBlock(E);
        if Block <> nil then
          Result.Content.Add(Block);
      end;
    end;
    C := C.NextSibling;
  end;
end;

function TFb3ToFb2Converter.TitleNode(Elem: TDOMElement): TTitle;
var
  Items: TFb2ObjectList;
  C: TDOMNode;
  CE: TDOMElement;
  Nodes: TFb2ObjectList;
  P: TParagraph;
begin
  Items := TFb2ObjectList.Create;
  C := Elem.FirstChild;
  while C <> nil do
  begin
    if (C.NodeType = ELEMENT_NODE) and
      (LocalName(TDOMElement(C).TagName) = 'p') then
    begin
      CE := TDOMElement(C);
      Nodes := InlineNodes(CE);
      if Nodes.Count > 0 then
      begin
        P := TParagraph.Create;
        FreeAndNil(P.Content);
        P.Content := Nodes;
        Items.Add(P);
      end
      else
        Nodes.Free;
    end;
    C := C.NextSibling;
  end;
  Result := nil;
  if Items.Count > 0 then
  begin
    Result := TTitle.Create;
    FreeAndNil(Result.Items);
    Result.Items := Items;
    Items := nil;
  end;
  Items.Free;
end;

function TFb3ToFb2Converter.EpigraphNode(Elem: TDOMElement): TEpigraph;
var
  C, CC: TDOMNode;
  CE: TDOMElement;
  Local: UnicodeString;
  Block: TFb2Object;
  Nodes: TFb2ObjectList;
  P: TParagraph;
begin
  Result := TEpigraph.Create;
  C := Elem.FirstChild;
  while C <> nil do
  begin
    if C.NodeType = ELEMENT_NODE then
    begin
      CE := TDOMElement(C);
      Local := LocalName(CE.TagName);
      if Local = 'subscription' then
      begin
        CC := CE.FirstChild;
        while CC <> nil do
        begin
          if (CC.NodeType = ELEMENT_NODE) and
            (LocalName(TDOMElement(CC).TagName) = 'p') then
          begin
            Nodes := InlineNodes(TDOMElement(CC));
            if Nodes.Count > 0 then
            begin
              P := TParagraph.Create;
              FreeAndNil(P.Content);
              P.Content := Nodes;
              Result.TextAuthor.Add(P);
            end
            else
              Nodes.Free;
          end;
          CC := CC.NextSibling;
        end;
      end
      else
      begin
        Block := ConvertBlock(CE);
        if Block <> nil then
        begin
          if (Block is TParagraph) or (Block is TPoem) or (Block is TCite) or
            (Block is TEmptyLine) then
            Result.Items.Add(Block)
          else
            Block.Free;
        end;
      end;
    end;
    C := C.NextSibling;
  end;
end;

function TFb3ToFb2Converter.AnnotationNode(Elem: TDOMElement): TAnnotation;
var
  C: TDOMNode;
  Block: TFb2Object;
begin
  Result := TAnnotation.Create;
  C := Elem.FirstChild;
  while C <> nil do
  begin
    if C.NodeType = ELEMENT_NODE then
    begin
      Block := ConvertBlock(TDOMElement(C));
      if Block <> nil then
      begin
        if (Block is TParagraph) or (Block is TPoem) or (Block is TCite) or
          (Block is TSubtitle) or (Block is TTable) or (Block is TEmptyLine) then
          Result.Items.Add(Block)
        else
          Block.Free;
      end;
    end;
    C := C.NextSibling;
  end;
end;

function TFb3ToFb2Converter.ConvertBlock(Elem: TDOMElement): TFb2Object;
var
  Local, BinaryId: UnicodeString;
  Images: TList;
  Nodes: TFb2ObjectList;
  K: Integer;
  P: TParagraph;
  Img: TImage;
begin
  Local := LocalName(Elem.TagName);
  if Local = 'p' then
  begin
    Images := BlockImages(Elem);
    Nodes := InlineNodes(Elem);
    if (Images.Count > 0) and (NodesText(Nodes) = '') then
    begin
      Result := TFb2Object(Images[0]);
      for K := 1 to Images.Count - 1 do
        TObject(Images[K]).Free;
      Nodes.Free;
      Images.Free;
      Exit;
    end;
    for K := 0 to Images.Count - 1 do
      TObject(Images[K]).Free;
    Images.Free;
    if Nodes.Count > 0 then
    begin
      P := TParagraph.Create;
      FreeAndNil(P.Content);
      P.Content := Nodes;
      Result := P;
    end
    else
    begin
      Nodes.Free;
      Result := nil;
    end;
    Exit;
  end;
  if Local = 'br' then
    Exit(TEmptyLine.Create);
  if Local = 'poem' then
    Exit(PoemNode(Elem));
  if Local = 'blockquote' then
    Exit(CiteNode(Elem));
  if Local = 'table' then
    Exit(TableNode(Elem));
  if Local = 'img' then
  begin
    BinaryId := RegisterBinary(GetAttr(Elem, 'src'));
    if BinaryId = '' then
      Exit(nil);
    Img := TImage.Create;
    Img.Href := '#' + BinaryId;
    Exit(Img);
  end;
  Result := nil;
end;

function TFb3ToFb2Converter.PoemNode(Elem: TDOMElement): TPoem;
var
  C: TDOMNode;
  CE: TDOMElement;
  Local: UnicodeString;
  Nodes: TFb2ObjectList;
  Sub: TSubtitle;
begin
  Result := TPoem.Create;
  C := Elem.FirstChild;
  while C <> nil do
  begin
    if C.NodeType = ELEMENT_NODE then
    begin
      CE := TDOMElement(C);
      Local := LocalName(CE.TagName);
      if Local = 'title' then
        Result.Title := TitleNode(CE)
      else if Local = 'epigraph' then
        Result.Epigraphs.Add(EpigraphNode(CE))
      else if Local = 'stanza' then
        Result.Items.Add(StanzaNode(CE))
      else if Local = 'subscription' then
        CollectSubscription(CE, Result.TextAuthor)
      else if Local = 'p' then
      begin
        Nodes := InlineNodes(CE);
        if Nodes.Count > 0 then
        begin
          Sub := TSubtitle.Create;
          FreeAndNil(Sub.Content);
          Sub.Content := Nodes;
          Result.Items.Add(Sub);
        end
        else
          Nodes.Free;
      end;
    end;
    C := C.NextSibling;
  end;
end;

function TFb3ToFb2Converter.StanzaNode(Elem: TDOMElement): TStanza;
var
  C: TDOMNode;
  CE: TDOMElement;
  Local: UnicodeString;
  Title: TTitle;
  First: TFb2Object;
  Sub: TSubtitle;
  Nodes: TFb2ObjectList;
  P: TParagraph;
begin
  Result := TStanza.Create;
  C := Elem.FirstChild;
  while C <> nil do
  begin
    if C.NodeType = ELEMENT_NODE then
    begin
      CE := TDOMElement(C);
      Local := LocalName(CE.TagName);
      if Local = 'title' then
      begin
        Title := TitleNode(CE);
        if (Title <> nil) and (Title.Items.Count > 0) then
        begin
          First := Title.Items[0];
          if First is TParagraph then
          begin
            Sub := TSubtitle.Create;
            FreeAndNil(Sub.Content);
            Sub.Content := TParagraph(First).Content;
            TParagraph(First).Content := nil;
            Result.Subtitle := Sub;
          end;
        end;
        Title.Free;
      end
      else if Local = 'p' then
      begin
        Nodes := InlineNodes(CE);
        if Nodes.Count > 0 then
        begin
          P := TParagraph.Create;
          FreeAndNil(P.Content);
          P.Content := Nodes;
          Result.Verses.Add(P);
        end
        else
          Nodes.Free;
      end;
    end;
    C := C.NextSibling;
  end;
end;

function TFb3ToFb2Converter.CiteNode(Elem: TDOMElement): TCite;
var
  C: TDOMNode;
  CE: TDOMElement;
  Block: TFb2Object;
begin
  Result := TCite.Create;
  C := Elem.FirstChild;
  while C <> nil do
  begin
    if C.NodeType = ELEMENT_NODE then
    begin
      CE := TDOMElement(C);
      if LocalName(CE.TagName) = 'subscription' then
        CollectSubscription(CE, Result.TextAuthor)
      else
      begin
        Block := ConvertBlock(CE);
        if Block <> nil then
          Result.Items.Add(Block);
      end;
    end;
    C := C.NextSibling;
  end;
end;

function TFb3ToFb2Converter.TableNode(Elem: TDOMElement): TTable;
var
  C, CC, CCC: TDOMNode;
  CE, CCE, CCCE: TDOMElement;
  CLocal: UnicodeString;
  Row: TTableRow;
  Cell: TTableCell;
  Nodes: TFb2ObjectList;
begin
  Result := TTable.Create;
  C := Elem.FirstChild;
  while C <> nil do
  begin
    if (C.NodeType = ELEMENT_NODE) and
      (LocalName(TDOMElement(C).TagName) = 'tr') then
    begin
      CE := TDOMElement(C);
      Row := TTableRow.Create;
      CC := CE.FirstChild;
      while CC <> nil do
      begin
        if CC.NodeType = ELEMENT_NODE then
        begin
          CCE := TDOMElement(CC);
          CLocal := LocalName(CCE.TagName);
          if (CLocal = 'th') or (CLocal = 'td') then
          begin
            Nodes := TFb2ObjectList.Create;
            CCC := CCE.FirstChild;
            while CCC <> nil do
            begin
              if (CCC.NodeType = ELEMENT_NODE) and
                (LocalName(TDOMElement(CCC).TagName) = 'p') then
              begin
                CCCE := TDOMElement(CCC);
                InlineNodesInto(CCCE, Nodes);
              end;
              CCC := CCC.NextSibling;
            end;
            Cell := TTableCell.Create;
            Cell.Tag := CLocal;
            FreeAndNil(Cell.Children);
            Cell.Children := Nodes;
            Cell.IsHeader := (CLocal = 'th');
            Row.Cells.Add(Cell);
          end;
        end;
        CC := CC.NextSibling;
      end;
      Result.Rows.Add(Row);
    end;
    C := C.NextSibling;
  end;
  if Result.Rows.Count = 0 then
    FreeAndNil(Result);
end;

function TFb3ToFb2Converter.InlineNodes(Elem: TDOMElement): TFb2ObjectList;
begin
  Result := TFb2ObjectList.Create;
  InlineNodesInto(Elem, Result);
end;

procedure TFb3ToFb2Converter.InlineNodesInto(Elem: TDOMElement;
  Dest: TFb2ObjectList);
var
  C: TDOMNode;
  E: TDOMElement;
  Local, T, Markup, BinaryId: UnicodeString;
  S: TStyleNode;
begin
  C := Elem.FirstChild;
  while C <> nil do
  begin
    if C.NodeType = TEXT_NODE then
    begin
      T := C.NodeValue;
      if UTrim(T) <> '' then
      begin
        S := TStyleNode.Create(TEXT_NODE_NAME);
        S.Text := T;
        Dest.Add(S);
      end;
    end
    else if C.NodeType = ELEMENT_NODE then
    begin
      E := TDOMElement(C);
      Local := LocalName(E.TagName);
      if Local = 'img' then
      begin
        BinaryId := RegisterBinary(GetAttr(E, 'src'));
        if BinaryId <> '' then
        begin
          S := TStyleNode.Create('image');
          S.ImageHref := '#' + BinaryId;
          Dest.Add(S);
        end;
      end
      else if Local = 'a' then
      begin
        S := TStyleNode.Create('a');
        S.Href := GetXlinkHref(E);
        InlineNodesInto(E, S.Children);
        Dest.Add(S);
      end
      else
      begin
        Markup := MapMarkupTag(Local);
        if Markup <> '' then
        begin
          S := TStyleNode.Create(Markup);
          InlineNodesInto(E, S.Children);
          Dest.Add(S);
        end
        else if Local = 'span' then
        begin
          S := TStyleNode.Create('style');
          S.StyleName := GetAttr(E, 'class');
          InlineNodesInto(E, S.Children);
          Dest.Add(S);
        end
        else if Local = 'subscription' then
        begin
          { пропустить }
        end
        else
          InlineNodesInto(E, Dest);
      end;
    end;
    C := C.NextSibling;
  end;
end;

function TFb3ToFb2Converter.BlockImages(Elem: TDOMElement): TList;
var
  C: TDOMNode;
  E: TDOMElement;
  BinaryId: UnicodeString;
  Img: TImage;
begin
  Result := TList.Create;
  C := Elem.FirstChild;
  while C <> nil do
  begin
    if (C.NodeType = ELEMENT_NODE) and
      (LocalName(TDOMElement(C).TagName) = 'img') then
    begin
      E := TDOMElement(C);
      BinaryId := RegisterBinary(GetAttr(E, 'src'));
      if BinaryId <> '' then
      begin
        Img := TImage.Create;
        Img.Href := '#' + BinaryId;
        Result.Add(Img);
      end;
    end;
    C := C.NextSibling;
  end;
end;

procedure TFb3ToFb2Converter.CollectSubscription(Elem: TDOMElement;
  Target: TFb2ObjectList);
var
  C: TDOMNode;
  CE: TDOMElement;
  T: UnicodeString;
  P: TParagraph;
  S: TStyleNode;
begin
  C := Elem.FirstChild;
  while C <> nil do
  begin
    if (C.NodeType = ELEMENT_NODE) and
      (LocalName(TDOMElement(C).TagName) = 'p') then
    begin
      CE := TDOMElement(C);
      T := UTrim(CollectText(CE));
      if T <> '' then
      begin
        P := TParagraph.Create;
        S := TStyleNode.Create(TEXT_NODE_NAME);
        S.Text := T;
        P.Content.Add(S);
        Target.Add(P);
      end;
    end;
    C := C.NextSibling;
  end;
end;

{ ===================== Сборка FictionBook ===================== }

{ Автор из полей субъекта FB3. }
function AuthorFromParts(const E: TSubjectParts): TAuthor;
var
  Main, Mid: UnicodeString;
  Words: TTextList;
  I: Integer;
begin
  if (E.Last <> '') or (E.First <> '') then
  begin
    Result := TAuthor.Create;
    Result.FirstName := E.First;
    Result.MiddleName := E.Middle;
    Result.LastName := E.Last;
    Exit;
  end;
  Main := UTrim(E.Main);
  if Main = '' then
  begin
    Result := TAuthor.Create;
    Result.Nickname := 'Неизвестный автор';
    Exit;
  end;
  Words := SplitWords(Main);
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

function TFb3ToFb2Converter.Assemble(Meta: TFb3Meta; Body: TBody): TFictionBook;
var
  Desc: TDescription;
  TI: TTitleInfo;
  DI: TDocumentInfo;
  Title, Lang, S: UnicodeString;
  I: Integer;
  Codes: TTextList;
  G: TGenre;
  A: TAuthor;
  Ann: TAnnotation;
  Items: TFb2ObjectList;
  P: TParagraph;
  SN: TStyleNode;
  CP: TCoverPage;
  II: TInlineImage;
begin
  Title := Meta.Title;
  if Title = '' then
    Title := 'Untitled';

  Result := TFictionBook.Create;
  Desc := TDescription.Create;
  Result.Description := Desc;
  TI := TTitleInfo.Create;
  Desc.TitleInfo := TI;

  { Жанры: только коды без пробелов, иначе — жанр по умолчанию. }
  Codes := TTextList.Create;
  try
    for I := 0 to Meta.Genres.Count - 1 do
    begin
      S := UTrim(Meta.Genres[I]);
      if (S <> '') and (Pos(' ', S) = 0) then
        Codes.Add(S);
    end;
    if Codes.Count = 0 then
      Codes.Add(FDefaultGenre);
    for I := 0 to Codes.Count - 1 do
    begin
      G := TGenre.Create;
      G.Value := Codes[I];
      TI.Genres.Add(G);
    end;
  finally
    Codes.Free;
  end;

  { Авторы. }
  for I := 0 to High(Meta.Authors) do
    TI.Authors.Add(AuthorFromParts(Meta.Authors[I]));

  { Название книги. }
  TI.BookTitle := TTextField.Create;
  TI.BookTitle.Value := Title;

  { Аннотация. }
  if Meta.Annotation.Count > 0 then
  begin
    Items := TFb2ObjectList.Create;
    for I := 0 to Meta.Annotation.Count - 1 do
      if UTrim(Meta.Annotation[I]) <> '' then
      begin
        P := TParagraph.Create;
        SN := TStyleNode.Create(TEXT_NODE_NAME);
        SN.Text := Meta.Annotation[I];
        P.Content.Add(SN);
        Items.Add(P);
      end;
    if Items.Count > 0 then
    begin
      Ann := TAnnotation.Create;
      FreeAndNil(Ann.Items);
      Ann.Items := Items;
      TI.Annotation := Ann;
    end
    else
      Items.Free;
  end;

  { Обложка. }
  if FCoverId <> '' then
  begin
    CP := TCoverPage.Create;
    II := TInlineImage.Create;
    II.Href := '#' + FCoverId;
    CP.Images.Add(II);
    TI.Coverpage := CP;
  end;

  { Язык. }
  Lang := Meta.Language;
  if Lang = '' then
    Lang := 'ru';
  TI.Lang := Lang;

  { document-info. }
  DI := TDocumentInfo.Create;
  Desc.DocumentInfo := DI;
  A := TAuthor.Create;
  A.Nickname := 'pyFB2';
  DI.Authors.Add(A);
  DI.ProgramUsed := TTextField.Create;
  DI.ProgramUsed.Value := FProgramUsed;
  DI.Date := TDateField.Create;
  DI.Date.Value := TodayIso;
  DI.Id := NewUuidHex;
  DI.Version := 1.0;
  DI.HasVersion := True;

  { Тело и бинарные данные. }
  Result.Bodies.Add(Body);
  for I := 0 to FBinaries.Count - 1 do
    Result.Binaries.Add(FBinaries[I]);
  FBinaries.FreeObjects := False;
  FBinaries.Clear;
end;

{ ===================== Публичный API ===================== }

function TFb3ToFb2Converter.Convert(const Source: UnicodeString): TFictionBook;
var
  DescPath, BodyPath: UnicodeString;
  Meta: TFb3Meta;
  Body: TBody;
begin
  if Source <> '' then
    FSource := Source;
  if FSource = '' then
    raise EFb2ConversionError.Create('Не задан источник FB3 (source)');

  Reset;
  FZip := TEpubArchive.Create;
  try
    FZip.LoadFromFile(FSource);
    DescPath := FindPart('_rels/.rels', REL_BOOK, DEFAULT_DESCRIPTION);
    BodyPath := FindPart('fb3/_rels/description.xml.rels', REL_BODY,
      DEFAULT_BODY);
    LoadImages(BodyPath);
    LoadCover;
    Meta := ReadDescription(DescPath);
    try
      Body := ConvertBody(ReadPart(BodyPath));
      FBook := Assemble(Meta, Body);
      Result := FBook;
    finally
      Meta.Free;
    end;
  finally
    FreeAndNil(FZip);
  end;
end;

function TFb3ToFb2Converter.ToXml(Book: TFictionBook): UnicodeString;
begin
  if Book = nil then
    Book := FBook;
  if Book = nil then
    Book := Convert;
  Result := FWriter.ToXML(Book);
end;

function TFb3ToFb2Converter.Write(const Source: UnicodeString;
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
