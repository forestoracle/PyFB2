unit epub_to_fb2;
{ Преобразование книги EPUB в FictionBook (FB2) — перевод epub_to_fb2.py.

  Читает EPUB-архив (ZIP, см. fb2_archive), разбирает META-INF/container.xml и
  OPF-манифест, извлекает метаданные и содержимое XHTML-документов spine и
  собирает структуры FB2 (fb2_structures), после чего сериализует их в XML
  FictionBook 2.0 (TFb2Writer).

  Что поддерживается:
      * метаданные dc:title/creator/language/identifier/date/description/
        subject -> description;
      * обложка (EPUB2 guide-reference / EPUB3 meta name="cover");
      * изображения из manifest (media-type image/*) -> binary (base64);
      * порядок чтения spine -> body/section;
      * заголовки h1-h6 -> иерархия section/title;
      * если заголовков нет — разделы строятся по оглавлению EPUB
        (nav.xhtml для EPUB3 либо toc.ncx для EPUB2);
      * p, strong/b, em/i, a, img, sub, sup, code, strike, blockquote,
        ul/ol, table, pre, hr.

  Пример:
      C := TEpubToFb2Converter.Create;
      try
        C.Write('book.epub', 'book.fb2');
      finally
        C.Free;
      end;

  Особенности перевода с Python:
      * источник — путь к файлу .epub;
      * XML разбирается fcl-xml (DOM); именованные HTML-сущности заменяются на
        числовые ссылки (FixHtmlEntities) — таблица покрывает часто
        встречающиеся сущности, неизвестные остаются как есть;
      * ZIP читается целиком в память (TEpubArchive). }

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Classes, SysUtils, fgl, DOM, XMLRead,
  fb2_structures, fb2_writer, fb2_errors, fb2_files,
  fb2_archive, fb2_genres, fb2_parser;

const
  { Жанр по умолчанию, если в EPUB нет подходящих subject. }
  DEFAULT_GENRE = 'prose';

type
  { Элемент OPF-манифеста. }
  TEpubManifestItem = class
  public
    Id: UnicodeString;
    Href: UnicodeString;
    MediaType: UnicodeString;
    Properties: UnicodeString;
  end;

  TEpubManifestList = specialize TFPGObjectList<TEpubManifestItem>;

  { Уровень стека секций при обходе заголовков XHTML. }
  TSectionLevel = class
  public
    Level: Integer;
    Section: TSection;
  end;

  TSectionLevelList = specialize TFPGObjectList<TSectionLevel>;

  { Узел оглавления EPUB (nav.xhtml / toc.ncx). }
  TTocEntry = class
  public
    Caption: UnicodeString;      { подпись (label) }
    Path: UnicodeString;         { путь в архиве ('' если нет) }
    Fragment: UnicodeString;     { якорь #id ('' если нет) }
    Children: TList;             { список TTocEntry (владелец) }
    constructor Create;
    destructor Destroy; override;
  end;

  { Прочитанный XHTML-документ spine (владеет DOM-деревом). }
  TSpineDoc = class
  public
    Path: UnicodeString;
    Body: TDOMElement;
    Doc: TXMLDocument;
    destructor Destroy; override;
  end;

  TSpineDocList = specialize TFPGObjectList<TSpineDoc>;

  { Секция оглавления, привязанная к документу и якорю. }
  TDocEntry = class
  public
    Path: UnicodeString;
    Fragment: UnicodeString;
    Section: TSection;           { владелец — дерево body }
  end;

  TDocEntryList = specialize TFPGObjectList<TDocEntry>;

  { Преобразование книги EPUB в структуры FB2 и обратно в XML. }
  TEpubToFb2Converter = class
  private
    FSource: UnicodeString;
    FDefaultGenre: UnicodeString;
    FProgramUsed: UnicodeString;
    FBook: TFictionBook;
    FZip: TEpubArchive;
    FOppDoc: TXMLDocument;         { документ OPF (владелец) }
    FOppDir: UnicodeString;
    FMeta: TStringList;            { строки вида 'local=value' }
    FManifest: TEpubManifestList;
    FPathToId: TStringList;        { путь в архиве -> fb2 id }
    FManifestIdMap: TStringList;   { id манифеста -> fb2 id }
    FBinaries: TFb2ObjectList;
    FImageCounter: Integer;
    FCoverHref: UnicodeString;

    procedure Reset;
    function ParseOpf: TDOMElement;
    procedure ReadMetadata(Root: TDOMElement);
    procedure LoadManifest(Root: TDOMElement);
    procedure LoadBinaries;
    procedure DetectCover(Root: TDOMElement);
    function FindManifestItem(const Id: UnicodeString): TEpubManifestItem;
    function MetaValues(const Name: UnicodeString): TTextList;
    function ResolveHref(const Href: UnicodeString): UnicodeString;

    { --- Изображения ------------------------------------------------ }
    function AllocateId(const Prefix: UnicodeString): UnicodeString;
    function ResolveImage(const Src, CurrentPath: UnicodeString): UnicodeString;
    function RegisterDataUri(const Src: UnicodeString): UnicodeString;

    { --- Метаданные EPUB -> FB2 ------------------------------------- }
    function Genres: TFb2ObjectList;
    function MatchGenres(Subjects: TTextList): TTextList;
    function Authors: TFb2ObjectList;
    function AnnotationOf: TAnnotation;
    function DateFieldOf: TDateField;
    function CoverPageOf: TCoverPage;
    function Assemble(Body: TBody): TFictionBook;

    { --- Spine -> Body ---------------------------------------------- }
    function ConvertSpine(Root: TDOMElement): TBody;
    procedure Walk(Elem: TDOMNode; const CurrentPath: UnicodeString;
      Stack: TSectionLevelList);
    function MakeTitle(Heading: TDOMNode;
      const CurrentPath: UnicodeString): TTitle;

    { --- Оглавление EPUB (nav.xhtml / toc.ncx) --------------------- }
    procedure ReadSpineDocs(Root: TDOMElement; Docs: TSpineDocList);
    function HasHeading(Node: TDOMNode): Boolean;
    function ParseToc(Root: TDOMElement): TList;
    function FindNcxPath(Root: TDOMElement): UnicodeString;
    function ParseTocNav(const NavPath: UnicodeString): TList;
    procedure ParseNavOl(Ol: TDOMElement; const BaseDir: UnicodeString;
      Entries: TList);
    function ParseTocNcx(const NcxPath: UnicodeString): TList;
    procedure ParseNavPoints(Parent: TDOMNode; const BaseDir: UnicodeString;
      Entries: TList);
    function BodyFromToc(Docs: TSpineDocList; Toc: TList): TBody;
    procedure BuildTocSections(Entries: TList; ParentSection: TSection;
      DocEntries: TDocEntryList);
    procedure WalkToc(Elem: TDOMNode; const CurrentPath: UnicodeString;
      Stack: TSectionLevelList; Structured: Boolean; Remaining: TList;
      var Idx: Integer);
    function MakeTextTitle(const Text: UnicodeString): TTitle;
    function SectionTitleText(Section: TSection): UnicodeString;
    function IsTitleRepeat(Block: TFb2Object; Section: TSection): Boolean;
    function IsTitleDuplicate(Node: TDOMNode; Section: TSection): Boolean;
    procedure FixEmptySections(Sections: TFb2ObjectList);
    function ConvertBlock(Elem: TDOMNode;
      const CurrentPath: UnicodeString): TFb2Object;
    function ConvertCite(Elem: TDOMNode;
      const CurrentPath: UnicodeString): TCite;
    function ConvertList(Elem: TDOMNode;
      const CurrentPath: UnicodeString): TFb2ObjectList;
    function ConvertTable(Elem: TDOMNode;
      const CurrentPath: UnicodeString): TTable;
    function ConvertPre(Elem: TDOMNode;
      const CurrentPath: UnicodeString): TFb2ObjectList;
    function ConvertInline(Elem: TDOMNode;
      const CurrentPath: UnicodeString): TFb2ObjectList;
    function ConvertInlineNode(Elem: TDOMNode; const Name,
      CurrentPath: UnicodeString): TStyleNode;
  public
    constructor Create(const DefaultGenre: UnicodeString = DEFAULT_GENRE;
      const ProgramUsed: UnicodeString = 'pyFB2');
    destructor Destroy; override;

    { Прочитать EPUB и вернуть структуру TFictionBook (владелец — конвертер). }
    function Convert(const Source: UnicodeString): TFictionBook;

    { Сериализовать книгу в XML FB2. Book = nil — результат Convert. }
    function ToXml(Book: TFictionBook = nil): UnicodeString;

    { Преобразовать EPUB в файл FB2 и вернуть путь к результату. }
    function Write(const Source: UnicodeString;
      const Output: UnicodeString = ''): UnicodeString;

    property Book: TFictionBook read FBook;
  end;

{ Заменить именованные HTML-сущности на числовые ссылки для XML
  (аналог _fix_entities). Предопределённые XML-сущности не трогаются. }
function FixHtmlEntities(const Text: UnicodeString): UnicodeString;

{ Локальное имя тега: '{ns}body' -> 'body'. }
function ElemLocalName(const AName: UnicodeString): UnicodeString;

{ Разбор XML из байтов UTF-8 (владелец — вызывающий). }
function ParseXmlBytes(const Data: TBytes): TXMLDocument;

implementation

uses
  StrUtils;

type
  THtmlEntity = record
    Name: string;
    Code: LongWord;
  end;

const
  { Часто встречающиеся именованные сущности HTML (name -> код символа).
    Полный список html5 огромен; здесь практическое подмножество. }
  HTML_ENTITIES: array[0..162] of THtmlEntity = (
    (Name: 'nbsp'; Code: 160), (Name: 'iexcl'; Code: 161),
    (Name: 'cent'; Code: 162), (Name: 'pound'; Code: 163),
    (Name: 'curren'; Code: 164), (Name: 'yen'; Code: 165),
    (Name: 'brvbar'; Code: 166), (Name: 'sect'; Code: 167),
    (Name: 'uml'; Code: 168), (Name: 'copy'; Code: 169),
    (Name: 'ordf'; Code: 170), (Name: 'laquo'; Code: 171),
    (Name: 'not'; Code: 172), (Name: 'shy'; Code: 173),
    (Name: 'reg'; Code: 174), (Name: 'macr'; Code: 175),
    (Name: 'deg'; Code: 176), (Name: 'plusmn'; Code: 177),
    (Name: 'sup2'; Code: 178), (Name: 'sup3'; Code: 179),
    (Name: 'acute'; Code: 180), (Name: 'micro'; Code: 181),
    (Name: 'para'; Code: 182), (Name: 'middot'; Code: 183),
    (Name: 'cedil'; Code: 184), (Name: 'sup1'; Code: 185),
    (Name: 'ordm'; Code: 186), (Name: 'raquo'; Code: 187),
    (Name: 'frac14'; Code: 188), (Name: 'frac12'; Code: 189),
    (Name: 'frac34'; Code: 190), (Name: 'iquest'; Code: 191),
    (Name: 'Agrave'; Code: 192), (Name: 'Aacute'; Code: 193),
    (Name: 'Acirc'; Code: 194), (Name: 'Atilde'; Code: 195),
    (Name: 'Auml'; Code: 196), (Name: 'Aring'; Code: 197),
    (Name: 'AElig'; Code: 198), (Name: 'Ccedil'; Code: 199),
    (Name: 'Egrave'; Code: 200), (Name: 'Eacute'; Code: 201),
    (Name: 'Ecirc'; Code: 202), (Name: 'Euml'; Code: 203),
    (Name: 'Igrave'; Code: 204), (Name: 'Iacute'; Code: 205),
    (Name: 'Icirc'; Code: 206), (Name: 'Iuml'; Code: 207),
    (Name: 'ETH'; Code: 208), (Name: 'Ntilde'; Code: 209),
    (Name: 'Ograve'; Code: 210), (Name: 'Oacute'; Code: 211),
    (Name: 'Ocirc'; Code: 212), (Name: 'Otilde'; Code: 213),
    (Name: 'Ouml'; Code: 214), (Name: 'times'; Code: 215),
    (Name: 'Oslash'; Code: 216), (Name: 'Ugrave'; Code: 217),
    (Name: 'Uacute'; Code: 218), (Name: 'Ucirc'; Code: 219),
    (Name: 'Uuml'; Code: 220), (Name: 'Yacute'; Code: 221),
    (Name: 'THORN'; Code: 222), (Name: 'szlig'; Code: 223),
    (Name: 'agrave'; Code: 224), (Name: 'aacute'; Code: 225),
    (Name: 'acirc'; Code: 226), (Name: 'atilde'; Code: 227),
    (Name: 'auml'; Code: 228), (Name: 'aring'; Code: 229),
    (Name: 'aelig'; Code: 230), (Name: 'ccedil'; Code: 231),
    (Name: 'egrave'; Code: 232), (Name: 'eacute'; Code: 233),
    (Name: 'ecirc'; Code: 234), (Name: 'euml'; Code: 235),
    (Name: 'igrave'; Code: 236), (Name: 'iacute'; Code: 237),
    (Name: 'icirc'; Code: 238), (Name: 'iuml'; Code: 239),
    (Name: 'eth'; Code: 240), (Name: 'ntilde'; Code: 241),
    (Name: 'ograve'; Code: 242), (Name: 'oacute'; Code: 243),
    (Name: 'ocirc'; Code: 244), (Name: 'otilde'; Code: 245),
    (Name: 'ouml'; Code: 246), (Name: 'divide'; Code: 247),
    (Name: 'oslash'; Code: 248), (Name: 'ugrave'; Code: 249),
    (Name: 'uacute'; Code: 250), (Name: 'ucirc'; Code: 251),
    (Name: 'uuml'; Code: 252), (Name: 'yacute'; Code: 253),
    (Name: 'thorn'; Code: 254), (Name: 'yuml'; Code: 255),
    (Name: 'OElig'; Code: 338), (Name: 'oelig'; Code: 339),
    (Name: 'Scaron'; Code: 352), (Name: 'scaron'; Code: 353),
    (Name: 'Yuml'; Code: 376), (Name: 'fnof'; Code: 402),
    (Name: 'circ'; Code: 710), (Name: 'tilde'; Code: 732),
    (Name: 'ensp'; Code: 8194), (Name: 'emsp'; Code: 8195),
    (Name: 'thinsp'; Code: 8201), (Name: 'zwnj'; Code: 8204),
    (Name: 'zwj'; Code: 8205), (Name: 'lrm'; Code: 8206),
    (Name: 'rlm'; Code: 8207), (Name: 'ndash'; Code: 8211),
    (Name: 'mdash'; Code: 8212), (Name: 'lsquo'; Code: 8216),
    (Name: 'rsquo'; Code: 8217), (Name: 'sbquo'; Code: 8218),
    (Name: 'ldquo'; Code: 8220), (Name: 'rdquo'; Code: 8221),
    (Name: 'bdquo'; Code: 8222), (Name: 'dagger'; Code: 8224),
    (Name: 'Dagger'; Code: 8225), (Name: 'bull'; Code: 8226),
    (Name: 'hellip'; Code: 8230), (Name: 'permil'; Code: 8240),
    (Name: 'prime'; Code: 8242), (Name: 'Prime'; Code: 8243),
    (Name: 'lsaquo'; Code: 8249), (Name: 'rsaquo'; Code: 8250),
    (Name: 'oline'; Code: 8254), (Name: 'frasl'; Code: 8260),
    (Name: 'euro'; Code: 8364), (Name: 'trade'; Code: 8482),
    (Name: 'larr'; Code: 8592), (Name: 'uarr'; Code: 8593),
    (Name: 'rarr'; Code: 8594), (Name: 'darr'; Code: 8595),
    (Name: 'harr'; Code: 8596), (Name: 'minus'; Code: 8722),
    (Name: 'lowast'; Code: 8727), (Name: 'radic'; Code: 8730),
    (Name: 'infin'; Code: 8734), (Name: 'and'; Code: 8743),
    (Name: 'or'; Code: 8744), (Name: 'int'; Code: 8747),
    (Name: 'there4'; Code: 8756), (Name: 'sim'; Code: 8764),
    (Name: 'asymp'; Code: 8776), (Name: 'ne'; Code: 8800),
    (Name: 'equiv'; Code: 8801), (Name: 'le'; Code: 8804),
    (Name: 'ge'; Code: 8805), (Name: 'sdot'; Code: 8901),
    (Name: 'lceil'; Code: 8968), (Name: 'rceil'; Code: 8969),
    (Name: 'lfloor'; Code: 8970), (Name: 'rfloor'; Code: 8971),
    (Name: 'lang'; Code: 9001), (Name: 'rang'; Code: 9002),
    (Name: 'loz'; Code: 9674), (Name: 'spades'; Code: 9824),
    (Name: 'clubs'; Code: 9827), (Name: 'hearts'; Code: 9829),
    (Name: 'diams'; Code: 9830)
  );

function EntityCode(const Name: string): LongWord;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(HTML_ENTITIES) do
    if HTML_ENTITIES[I].Name = Name then
      Exit(HTML_ENTITIES[I].Code);
end;

{ Предопределённые XML-сущности (их не трогаем). }
function IsXmlEntity(const Name: string): Boolean;
begin
  Result := (Name = 'amp') or (Name = 'lt') or (Name = 'gt') or
    (Name = 'quot') or (Name = 'apos');
end;

function IsNameChar(C: WideChar): Boolean;
begin
  Result := ((C >= 'A') and (C <= 'Z')) or ((C >= 'a') and (C <= 'z')) or
    ((C >= '0') and (C <= '9'));
end;

{ Шестнадцатеричная цифра. }
function IsHexDigitU(C: WideChar): Boolean;
begin
  Result := ((C >= '0') and (C <= '9')) or ((C >= 'a') and (C <= 'f')) or
    ((C >= 'A') and (C <= 'F'));
end;

function FixHtmlEntities(const Text: UnicodeString): UnicodeString;
var
  I, J: Integer;
  Name: string;
  Code: LongWord;
begin
  Result := '';
  I := 1;
  while I <= Length(Text) do
  begin
    if Text[I] <> '&' then
    begin
      Result := Result + Text[I];
      Inc(I);
      Continue;
    end;
    { Ищем '&name;' — имя начинается с буквы. }
    J := I + 1;
    if (J <= Length(Text)) and
      (((Text[J] >= 'A') and (Text[J] <= 'Z')) or
       ((Text[J] >= 'a') and (Text[J] <= 'z'))) then
    begin
      while (J <= Length(Text)) and IsNameChar(Text[J]) do
        Inc(J);
      if (J <= Length(Text)) and (Text[J] = ';') then
      begin
        Name := UTF8Encode(Copy(Text, I + 1, J - I - 1));
        if IsXmlEntity(Name) then
          Result := Result + Copy(Text, I, J - I + 1)
        else
        begin
          Code := EntityCode(Name);
          if Code > 0 then
            Result := Result + '&#' + IntToStr(Code) + ';'
          else
            Result := Result + Copy(Text, I, J - I + 1);
        end;
        I := J + 1;
        Continue;
      end;
    end;
    Result := Result + Text[I];
    Inc(I);
  end;
end;

function ElemLocalName(const AName: UnicodeString): UnicodeString;
begin
  Result := LocalName(AName);
end;

function ParseXmlBytes(const Data: TBytes): TXMLDocument;
var
  MS: TMemoryStream;
  B: TBytes;
begin
  Result := nil;
  B := TEncoding.UTF8.GetBytes(FixHtmlEntities(
    TEncoding.UTF8.GetString(Data)));
  MS := TMemoryStream.Create;
  try
    if Length(B) > 0 then
      MS.WriteBuffer(B[0], Length(B));
    MS.Position := 0;
    ReadXMLFile(Result, MS);
  finally
    MS.Free;
  end;
end;

{ ===================== Posix-пути ===================== }

function PosixDirname(const P: UnicodeString): UnicodeString;
var
  I: Integer;
begin
  I := LastDelimiter('/', P);
  if I = 0 then
    Result := ''
  else
    Result := Copy(P, 1, I - 1);
end;

function PosixJoin(const A, B: UnicodeString): UnicodeString;
begin
  if A = '' then
    Result := B
  else if B = '' then
    Result := A
  else
    Result := A + '/' + B;
end;

{ Нормализация posix-пути (аналог posixpath.normpath). }
function PosixNormPath(const P: UnicodeString): UnicodeString;
var
  Stack: TTextList;
  I: Integer;
  Seg: UnicodeString;
  Abs: Boolean;

  procedure Push(const S: UnicodeString);
  begin
    if (S = '') or (S = '.') then
      Exit;
    if S = '..' then
    begin
      if (Stack.Count > 0) and (Stack[Stack.Count - 1] <> '..') then
        Stack.Delete(Stack.Count - 1)
      else if not Abs then
        Stack.Add('..');
      Exit;
    end;
    Stack.Add(S);
  end;

begin
  Abs := (P <> '') and (P[1] = '/');
  Stack := TTextList.Create;
  try
    Seg := '';
    for I := 1 to Length(P) do
    begin
      if P[I] = '/' then
      begin
        Push(Seg);
        Seg := '';
      end
      else
        Seg := Seg + P[I];
    end;
    Push(Seg);
    if Stack.Count = 0 then
    begin
      if Abs then
        Result := '/'
      else
        Result := '.';
    end
    else
    begin
      Result := JoinText(Stack, '/');
      if Abs then
        Result := '/' + Result;
    end;
  finally
    Stack.Free;
  end;
end;

{ Расширение файла в нижнем регистре (аналог posixpath.splitext). }
function PosixExt(const P: UnicodeString): UnicodeString;
var
  I, Slash: Integer;
begin
  Result := '';
  Slash := LastDelimiter('/', P);
  for I := Length(P) downto Slash + 1 do
    if P[I] = '.' then
    begin
      Result := LowerCase(Copy(P, I, Length(P) - I + 1));
      Exit;
    end;
end;

{ Процентное декодирование (аналог urllib.parse.unquote). }
function Unquote(const S: UnicodeString): UnicodeString;
var
  I, N: Integer;
  Buf: TBytes;
  U, C: UTF8String;
begin
  SetLength(Buf, 0);
  N := 0;
  I := 1;
  while I <= Length(S) do
  begin
    if (S[I] = '%') and (I + 2 <= Length(S)) and
      IsHexDigitU(S[I + 1]) and IsHexDigitU(S[I + 2]) then
    begin
      SetLength(Buf, N + 1);
      Buf[N] := Byte(StrToInt('$' + Copy(S, I + 1, 2)));
      Inc(N);
      Inc(I, 3);
    end
    else
    begin
      C := UTF8Encode(S[I]);
      SetLength(Buf, N + Length(C));
      Move(C[1], Buf[N], Length(C));
      Inc(N, Length(C));
      Inc(I);
    end;
  end;
  SetLength(U, N);
  if N > 0 then
    Move(Buf[0], U[1], N);
  Result := UTF8ToString(U);
end;

{ Первый прямой потомок-элемент с указанным локальным именем. }
function FindChildElement(Parent: TDOMNode;
  const AName: UnicodeString): TDOMElement;
var
  N: TDOMNode;
begin
  Result := nil;
  if Parent = nil then
    Exit;
  N := Parent.FirstChild;
  while N <> nil do
  begin
    if (N.NodeType = ELEMENT_NODE) and
      (ElemLocalName(N.NodeName) = AName) then
      Exit(TDOMElement(N));
    N := N.NextSibling;
  end;
end;

{ Первый элемент в поддереве с указанным локальным именем. }
function FindDescendant(Parent: TDOMNode;
  const AName: UnicodeString): TDOMElement;
var
  N: TDOMNode;
begin
  Result := nil;
  if Parent = nil then
    Exit;
  N := Parent.FirstChild;
  while N <> nil do
  begin
    if N.NodeType = ELEMENT_NODE then
    begin
      if ElemLocalName(N.NodeName) = AName then
        Exit(TDOMElement(N));
      Result := FindDescendant(N, AName);
      if Result <> nil then
        Exit;
    end;
    N := N.NextSibling;
  end;
end;

{ Собственный текст элемента (аналог elem.text). }
function OwnText(E: TDOMNode): UnicodeString;
begin
  if (E <> nil) and (E.FirstChild <> nil) and
    (E.FirstChild.NodeType = TEXT_NODE) then
    Result := E.FirstChild.NodeValue
  else
    Result := '';
end;

{ Текст после элемента (аналог elem.tail). }
function TailText(E: TDOMNode): UnicodeString;
begin
  if (E <> nil) and (E.NextSibling <> nil) and
    (E.NextSibling.NodeType = TEXT_NODE) then
    Result := E.NextSibling.NodeValue
  else
    Result := '';
end;

{ Значение атрибута ('' если нет). }
function GetAttr(E: TDOMElement; const AName: UnicodeString): UnicodeString;
var
  A: TDOMNode;
begin
  Result := '';
  if E = nil then
    Exit;
  A := E.Attributes.GetNamedItem(AName);
  if A <> nil then
    Result := A.NodeValue;
end;

{ ===================== Прочие помощники ===================== }

{ Аналог str.isspace() для одного символа. }
function IsPySpace(C: WideChar): Boolean;
var
  U: LongWord;
begin
  U := Ord(C);
  Result := (U = $20) or ((U >= $09) and (U <= $0D)) or
    ((U >= $1C) and (U <= $1F)) or (U = $85) or (U = $A0) or (U = $1680) or
    ((U >= $2000) and (U <= $200A)) or (U = $2028) or (U = $2029) or
    (U = $202F) or (U = $205F) or (U = $3000);
end;

{ Аналог str.strip(): снимает пробелы по краям, включая NBSP. }
function PyStrip(const S: UnicodeString): UnicodeString;
var
  L, R: Integer;
begin
  L := 1;
  R := Length(S);
  while (L <= R) and IsPySpace(S[L]) do
    Inc(L);
  while (R >= L) and IsPySpace(S[R]) do
    Dec(R);
  Result := Copy(S, L, R - L + 1);
end;

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

{ base64-декодирование (аналог base64.b64decode с игнорированием пробелов). }
function Base64DecodeBytes(const S: UnicodeString): TBytes;
var
  I, N: Integer;
  Acc: LongWord;
  Bits: Integer;
  C: WideChar;
  V: Integer;
begin
  SetLength(Result, (Length(S) div 4 + 1) * 3);
  N := 0;
  Acc := 0;
  Bits := 0;
  for I := 1 to Length(S) do
  begin
    C := S[I];
    if (C = '=') then
      Break;
    V := Pos(C, B64_ALPHABET);
    if V = 0 then
      Continue;
    Acc := (Acc shl 6) or LongWord(V - 1);
    Inc(Bits, 6);
    if Bits >= 8 then
    begin
      Dec(Bits, 8);
      Result[N] := Byte((Acc shr Bits) and $FF);
      Inc(N);
    end;
  end;
  SetLength(Result, N);
end;

{ GUID без дефисов (аналог uuid.uuid4().hex). }
function NewGuidHex: UnicodeString;
var
  G: TGUID;
  S: UnicodeString;
  I: Integer;
begin
  CreateGUID(G);
  S := GUIDToString(G);
  if (Length(S) >= 2) and (S[1] = '{') then
    S := Copy(S, 2, Length(S) - 2);
  Result := '';
  for I := 1 to Length(S) do
    if S[I] <> '-' then
      Result := Result + S[I];
end;

{ ===================== TEpubToFb2Converter ===================== }

constructor TEpubToFb2Converter.Create(const DefaultGenre: UnicodeString;
  const ProgramUsed: UnicodeString);
begin
  inherited Create;
  FDefaultGenre := DefaultGenre;
  FProgramUsed := ProgramUsed;
  FMeta := TStringList.Create;
  FMeta.CaseSensitive := True;
  FManifest := TEpubManifestList.Create;
  FPathToId := TStringList.Create;
  FManifestIdMap := TStringList.Create;
  FBinaries := TFb2ObjectList.Create;
  Reset;
end;

destructor TEpubToFb2Converter.Destroy;
begin
  FreeAndNil(FBook);
  FreeAndNil(FZip);
  FreeAndNil(FOppDoc);
  FreeAndNil(FBinaries);
  FreeAndNil(FManifestIdMap);
  FreeAndNil(FPathToId);
  FreeAndNil(FManifest);
  FreeAndNil(FMeta);
  inherited Destroy;
end;

{ Очистить состояние для нового преобразования. }
procedure TEpubToFb2Converter.Reset;
begin
  FreeAndNil(FZip);
  FreeAndNil(FOppDoc);
  FOppDir := '';
  FMeta.Clear;
  FManifest.Clear;
  FPathToId.Clear;
  FManifestIdMap.Clear;
  FBinaries.Clear;
  FImageCounter := 0;
  FCoverHref := '';
end;

function TEpubToFb2Converter.Convert(
  const Source: UnicodeString): TFictionBook;
var
  Root: TDOMElement;
begin
  if Source <> '' then
    FSource := Source;
  if FSource = '' then
    raise EFb2ConversionError.Create('Не задан источник EPUB (Source)');

  FreeAndNil(FBook);
  Reset;
  FZip := TEpubArchive.Create;
  FZip.LoadFromFile(FSource);
  try
    Root := ParseOpf;
    ReadMetadata(Root);
    LoadManifest(Root);
    LoadBinaries;
    DetectCover(Root);
    FBook := Assemble(ConvertSpine(Root));
    Result := FBook;
  finally
    FreeAndNil(FZip);
  end;
end;

function TEpubToFb2Converter.ToXml(Book: TFictionBook): UnicodeString;
var
  W: TFb2Writer;
begin
  if Book = nil then
    Book := FBook;
  if Book = nil then
    Book := Convert('');
  W := TFb2Writer.Create;
  try
    Result := W.ToXML(Book);
  finally
    W.Free;
  end;
end;

function TEpubToFb2Converter.Write(const Source: UnicodeString;
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

const
  { Пространство имён Dublin Core. }
  DC_NS = 'http://purl.org/dc/elements/1.1/';

{ Является ли узел элементом Dublin Core.

  fcl-xml не заполняет NamespaceURI/Prefix/LocalName (они пусты), поэтому
  пространство имён определяется по NodeName: 'dc:title' либо
  '{http://purl.org/dc/elements/1.1/}title'. }
function IsDcElement(N: TDOMNode): Boolean;
var
  Name: UnicodeString;
begin
  Name := N.NodeName;
  Result := (Pos(DC_NS, Name) > 0) or
    ((Length(Name) > 3) and (LowerCase(Copy(Name, 1, 3)) = 'dc:'));
end;

{ Найти и разобрать OPF-файл по META-INF/container.xml. }
function TEpubToFb2Converter.ParseOpf: TDOMElement;
var
  Container: TXMLDocument;
  ContainerData, OpfData: TBytes;
  Names: TStringList;
  OpfPath: UnicodeString;
  I: Integer;

  function FindRootfilePath(N: TDOMNode): UnicodeString;
  var
    S: UnicodeString;
  begin
    Result := '';
    while N <> nil do
    begin
      if N.NodeType = ELEMENT_NODE then
      begin
        if ElemLocalName(N.NodeName) = 'rootfile' then
        begin
          S := GetAttr(TDOMElement(N), 'full-path');
          if S <> '' then
            Exit(S);
        end;
        Result := FindRootfilePath(N.FirstChild);
        if Result <> '' then
          Exit;
      end;
      N := N.NextSibling;
    end;
  end;

begin
  if FZip = nil then
    raise EFb2ConversionError.Create('EPUB-архив не открыт');

  OpfPath := '';
  ContainerData := FZip.Read('META-INF/container.xml');
  if Length(ContainerData) > 0 then
  begin
    Container := nil;
    try
      try
        Container := ParseXmlBytes(ContainerData);
      except
        Container := nil;
      end;
      if Container <> nil then
        OpfPath := FindRootfilePath(Container.DocumentElement);
    finally
      Container.Free;
    end;
  end;

  if OpfPath = '' then
  begin
    { Фолбэк: первый файл с расширением .opf в архиве. }
    Names := FZip.Names;
    try
      for I := 0 to Names.Count - 1 do
        if PosixExt(Names[I]) = '.opf' then
        begin
          OpfPath := Names[I];
          Break;
        end;
    finally
      Names.Free;
    end;
  end;

  if OpfPath = '' then
    raise EFb2ConversionError.Create(
      'Не найден OPF-файл в EPUB (container.xml)');

  FOppDir := PosixDirname(OpfPath);
  OpfData := FZip.Read(OpfPath);
  if Length(OpfData) = 0 then
    raise EFb2ConversionError.Create(
      'OPF-файл отсутствует в архиве: ' + OpfPath);
  try
    FOppDoc := ParseXmlBytes(OpfData);
  except
    raise EFb2ConversionError.Create('Не удалось разобрать OPF: ' + OpfPath);
  end;
  Result := FOppDoc.DocumentElement;
end;

{ Собрать dc:* метаданные в FMeta (строки 'local=value'). }
procedure TEpubToFb2Converter.ReadMetadata(Root: TDOMElement);

  procedure WalkMeta(N: TDOMNode);
  var
    E: TDOMElement;
    Value: UnicodeString;
  begin
    while N <> nil do
    begin
      if N.NodeType = ELEMENT_NODE then
      begin
        E := TDOMElement(N);
        if IsDcElement(N) then
        begin
          Value := PyStrip(N.TextContent);
          if Value <> '' then
            FMeta.Add(ElemLocalName(N.NodeName) + '=' + Value);
        end;
        WalkMeta(N.FirstChild);
      end;
      N := N.NextSibling;
    end;
  end;

begin
  FMeta.Clear;
  WalkMeta(Root);
end;

{ Прочитать manifest: id, href, media-type, properties. }
procedure TEpubToFb2Converter.LoadManifest(Root: TDOMElement);

  procedure WalkManifest(N: TDOMNode);
  var
    E: TDOMElement;
    Item: TEpubManifestItem;
    Id, Href: UnicodeString;
  begin
    while N <> nil do
    begin
      if N.NodeType = ELEMENT_NODE then
      begin
        E := TDOMElement(N);
        if ElemLocalName(N.NodeName) = 'item' then
        begin
          Id := GetAttr(E, 'id');
          Href := GetAttr(E, 'href');
          if (Id <> '') and (Href <> '') then
          begin
            Item := TEpubManifestItem.Create;
            Item.Id := Id;
            Item.Href := Unquote(Href);
            Item.MediaType := GetAttr(E, 'media-type');
            Item.Properties := GetAttr(E, 'properties');
            FManifest.Add(Item);
          end;
        end;
        WalkManifest(N.FirstChild);
      end;
      N := N.NextSibling;
    end;
  end;

begin
  FManifest.Clear;
  WalkManifest(Root);
end;

{ Найти элемент манифеста по id (последний — как dict в Python). }
function TEpubToFb2Converter.FindManifestItem(
  const Id: UnicodeString): TEpubManifestItem;
var
  I: Integer;
begin
  Result := nil;
  for I := FManifest.Count - 1 downto 0 do
    if FManifest[I].Id = Id then
      Exit(FManifest[I]);
end;

{ Значения dc-поля в порядке появления. }
function TEpubToFb2Converter.MetaValues(
  const Name: UnicodeString): TTextList;
var
  I, P: Integer;
  S: UnicodeString;
begin
  Result := TTextList.Create;
  for I := 0 to FMeta.Count - 1 do
  begin
    S := FMeta[I];
    P := Pos('=', S);
    if (P > 0) and (Copy(S, 1, P - 1) = Name) then
      Result.Add(Copy(S, P + 1, MaxInt));
  end;
end;

{ Привести относительный href к абсолютному пути в архиве. }
function TEpubToFb2Converter.ResolveHref(
  const Href: UnicodeString): UnicodeString;
var
  H: UnicodeString;
begin
  H := Unquote(Href);
  if (H <> '') and (H[1] = '#') then
    Exit(H);
  if (H <> '') and (H[1] = '/') then
  begin
    while (H <> '') and (H[1] = '/') do
      H := Copy(H, 2, MaxInt);
    Exit(H);
  end;
  Result := PosixNormPath(PosixJoin(FOppDir, H));
end;

{ ===================== Изображения ===================== }

type
  TExtMime = record
    Ext: string;
    Mime: string;
  end;

const
  CONTENT_TYPES: array[0..8] of TExtMime = (
    (Ext: '.jpg'; Mime: 'image/jpeg'),
    (Ext: '.jpeg'; Mime: 'image/jpeg'),
    (Ext: '.png'; Mime: 'image/png'),
    (Ext: '.gif'; Mime: 'image/gif'),
    (Ext: '.svg'; Mime: 'image/svg+xml'),
    (Ext: '.webp'; Mime: 'image/webp'),
    (Ext: '.bmp'; Mime: 'image/bmp'),
    (Ext: '.tif'; Mime: 'image/tiff'),
    (Ext: '.tiff'; Mime: 'image/tiff')
  );

{ MIME-тип изображения по расширению файла. }
function GuessContentType(const Path: UnicodeString): UnicodeString;
var
  I: Integer;
  E: UnicodeString;
begin
  Result := '';
  E := PosixExt(Path);
  for I := 0 to High(CONTENT_TYPES) do
    if CONTENT_TYPES[I].Ext = E then
      Exit(CONTENT_TYPES[I].Mime);
end;

{ Разбить строку по разделителю, добавляя части в список. }
procedure SplitTo(const S, Sep: UnicodeString; List: TTextList);
var
  Start, I: Integer;
  Seg: UnicodeString;
begin
  if Sep = '' then
  begin
    List.Add(S);
    Exit;
  end;
  Start := 1;
  I := 1;
  while I <= Length(S) do
  begin
    if Copy(S, I, Length(Sep)) = Sep then
    begin
      List.Add(Copy(S, Start, I - Start));
      Inc(I, Length(Sep));
      Start := I;
    end
    else
      Inc(I);
  end;
  List.Add(Copy(S, Start, MaxInt));
end;

{ Выделить уникальный XML-ID для бинарника. }
function TEpubToFb2Converter.AllocateId(
  const Prefix: UnicodeString): UnicodeString;
begin
  Inc(FImageCounter);
  Result := Prefix + '_' + IntToStr(FImageCounter);
end;

{ Загрузить изображения из манифеста в binary (base64). }
procedure TEpubToFb2Converter.LoadBinaries;
var
  I: Integer;
  Item: TEpubManifestItem;
  Path, Fb2Id: UnicodeString;
  Data: TBytes;
  B: TBinary;
begin
  for I := 0 to FManifest.Count - 1 do
  begin
    Item := FManifest[I];
    if Copy(Item.MediaType, 1, 6) <> 'image/' then
      Continue;
    Path := ResolveHref(Item.Href);
    if not FZip.Has(Path) then
      Continue;
    Data := FZip.Read(Path);
    Fb2Id := AllocateId('image');
    FManifestIdMap.Values[Item.Id] := Fb2Id;
    FPathToId.Values[Path] := Fb2Id;
    B := TBinary.Create;
    B.Id := Fb2Id;
    B.ContentType := Item.MediaType;
    B.Data := Base64EncodeBytes(Data);
    FBinaries.Add(B);
  end;
end;

{ Определить обложку: EPUB3 meta name=cover / EPUB2 guide reference. }
procedure TEpubToFb2Converter.DetectCover(Root: TDOMElement);
var
  CoverHref, CoverId, Path, Fb2Id: UnicodeString;
  Item: TEpubManifestItem;

  function FindCoverMeta(N: TDOMNode): UnicodeString;
  var
    E: TDOMElement;
    S: UnicodeString;
  begin
    Result := '';
    while N <> nil do
    begin
      if N.NodeType = ELEMENT_NODE then
      begin
        E := TDOMElement(N);
        if ElemLocalName(N.NodeName) = 'meta' then
        begin
          if GetAttr(E, 'name') = 'cover' then
          begin
            S := GetAttr(E, 'content');
            if (S <> '') and (FindManifestItem(S) <> nil) then
              Exit(S);
          end;
        end;
        Result := FindCoverMeta(N.FirstChild);
        if Result <> '' then
          Exit;
      end;
      N := N.NextSibling;
    end;
  end;

  function FindCoverRef(N: TDOMNode): UnicodeString;
  var
    E: TDOMElement;
    S: UnicodeString;
  begin
    Result := '';
    while N <> nil do
    begin
      if N.NodeType = ELEMENT_NODE then
      begin
        E := TDOMElement(N);
        if (ElemLocalName(N.NodeName) = 'reference') and
          (GetAttr(E, 'type') = 'cover') then
        begin
          S := GetAttr(E, 'href');
          if S <> '' then
            Exit(S);
        end;
        Result := FindCoverRef(N.FirstChild);
        if Result <> '' then
          Exit;
      end;
      N := N.NextSibling;
    end;
  end;

begin
  CoverHref := '';
  CoverId := FindCoverMeta(Root);
  if CoverId <> '' then
  begin
    Item := FindManifestItem(CoverId);
    if Item <> nil then
      CoverHref := Item.Href;
  end;
  if CoverHref = '' then
    CoverHref := FindCoverRef(Root);

  FCoverHref := '';
  if CoverHref <> '' then
  begin
    Path := ResolveHref(CoverHref);
    Fb2Id := FPathToId.Values[Path];
    if Fb2Id <> '' then
      FCoverHref := '#' + Fb2Id;
  end;
end;

{ Разрешить ссылку на изображение в href вида #id (или ''). }
function TEpubToFb2Converter.ResolveImage(const Src,
  CurrentPath: UnicodeString): UnicodeString;
var
  S, Path, Fb2Id, CT: UnicodeString;
  Data: TBytes;
  B: TBinary;
begin
  Result := '';
  if Src = '' then
    Exit;
  S := PyStrip(Src);
  if Copy(S, 1, 5) = 'data:' then
    Exit(RegisterDataUri(S));
  if (S <> '') and (S[1] = '#') then
    Exit;

  Path := PosixNormPath(PosixJoin(PosixDirname(CurrentPath), Unquote(S)));
  Fb2Id := FPathToId.Values[Path];
  if Fb2Id <> '' then
    Exit('#' + Fb2Id);

  if FZip.Has(Path) then
  begin
    CT := GuessContentType(Path);
    if Copy(CT, 1, 6) = 'image/' then
    begin
      Data := FZip.Read(Path);
      Fb2Id := AllocateId('image');
      FPathToId.Values[Path] := Fb2Id;
      B := TBinary.Create;
      B.Id := Fb2Id;
      B.ContentType := CT;
      B.Data := Base64EncodeBytes(Data);
      FBinaries.Add(B);
      Exit('#' + Fb2Id);
    end;
  end;
end;

{ Зарегистрировать изображение из data-URI как binary. }
function TEpubToFb2Converter.RegisterDataUri(
  const Src: UnicodeString): UnicodeString;
var
  Header, Payload, Meta, CT: UnicodeString;
  P, I: Integer;
  Parts: TTextList;
  IsB64: Boolean;
  Data: TBytes;
  B: TBinary;
  Fb2Id: UnicodeString;
begin
  Result := '';
  P := Pos(',', Src);
  if P = 0 then
    Exit;
  Header := Copy(Src, 1, P - 1);
  Payload := Copy(Src, P + 1, MaxInt);
  Meta := Copy(Header, 6, MaxInt);

  Parts := TTextList.Create;
  try
    SplitTo(Meta, ';', Parts);
    CT := '';
    if Parts.Count > 0 then
      CT := Parts[0];
    if CT = '' then
      CT := 'image/png';
    IsB64 := False;
    for I := 1 to Parts.Count - 1 do
      if Parts[I] = 'base64' then
        IsB64 := True;

    if IsB64 then
      Data := Base64DecodeBytes(Payload)
    else
      Data := TEncoding.UTF8.GetBytes(Unquote(Payload));

    if Copy(CT, 1, 6) <> 'image/' then
      Exit;

    Fb2Id := AllocateId('image');
    B := TBinary.Create;
    B.Id := Fb2Id;
    B.ContentType := CT;
    B.Data := Base64EncodeBytes(Data);
    FBinaries.Add(B);
    Result := '#' + Fb2Id;
  finally
    Parts.Free;
  end;
end;

{ ===================== Метаданные EPUB -> FB2 ===================== }

{ Разбить строку по пробельным символам (аналог str.split()). }
procedure SplitWhitespace(const S: UnicodeString; List: TTextList);
var
  I, Start: Integer;
  InWord: Boolean;
begin
  InWord := False;
  Start := 1;
  for I := 1 to Length(S) do
  begin
    if IsPySpace(S[I]) then
    begin
      if InWord then
      begin
        List.Add(Copy(S, Start, I - Start));
        InWord := False;
      end;
    end
    else if not InWord then
    begin
      Start := I;
      InWord := True;
    end;
  end;
  if InWord then
    List.Add(Copy(S, Start, Length(S) - Start + 1));
end;

{ Соединить элементы списка с AFrom по ATo через Sep. }
function JoinRange(List: TTextList; AFrom, ATo: Integer;
  const Sep: UnicodeString): UnicodeString;
var
  I: Integer;
begin
  Result := '';
  for I := AFrom to ATo do
  begin
    if I > AFrom then
      Result := Result + Sep;
    Result := Result + List[I];
  end;
end;

{ Префикс даты вида YYYY или YYYY-MM-DD (аналог regex в _date_field). }
function MatchDatePrefix(const S: UnicodeString): UnicodeString;
var
  I: Integer;

  function Dig(Index: Integer): Boolean;
  begin
    Result := (Index <= Length(S)) and (S[Index] >= '0') and (S[Index] <= '9');
  end;

begin
  Result := '';
  for I := 1 to 4 do
    if not Dig(I) then
      Exit;
  if (Length(S) >= 10) and (S[5] = '-') and Dig(6) and Dig(7) and
    (S[8] = '-') and Dig(9) and Dig(10) then
    Result := Copy(S, 1, 10);
end;

{ Разбить строку автора на first/last/middle. }
function SplitAuthor(const Name: UnicodeString): TAuthor;
var
  S: UnicodeString;
  Parts: TTextList;
  P: Integer;
begin
  Result := TAuthor.Create;
  S := PyStrip(Name);
  P := Pos(',', S);
  if P > 0 then
  begin
    Result.LastName := PyStrip(Copy(S, 1, P - 1));
    Result.FirstName := PyStrip(Copy(S, P + 1, MaxInt));
    Exit;
  end;
  Parts := TTextList.Create;
  try
    SplitWhitespace(S, Parts);
    if Parts.Count = 1 then
      Result.LastName := Parts[0]
    else if Parts.Count = 2 then
    begin
      Result.FirstName := Parts[0];
      Result.LastName := Parts[1];
    end
    else if Parts.Count >= 3 then
    begin
      Result.FirstName := Parts[0];
      Result.MiddleName := JoinRange(Parts, 1, Parts.Count - 2, ' ');
      Result.LastName := Parts[Parts.Count - 1];
    end;
  finally
    Parts.Free;
  end;
end;

{ Перенести элементы Src в Dst (без освобождения объектов). }
procedure MoveAll(Src, Dst: TFb2ObjectList);
var
  Obj: TFb2Object;
begin
  while Src.Count > 0 do
  begin
    Obj := Src.Items[0];
    Src.Extract(Obj);
    Dst.Add(Obj);
  end;
end;

{ Сопоставить темы с кодами жанров; фолбэк — default_genre. }
function TEpubToFb2Converter.MatchGenres(Subjects: TTextList): TTextList;
var
  I: Integer;
  S, Code: UnicodeString;
begin
  Result := TTextList.Create;
  for I := 0 to Subjects.Count - 1 do
  begin
    S := PyStrip(Subjects[I]);
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

function TEpubToFb2Converter.Genres: TFb2ObjectList;
var
  Subjects, Codes: TTextList;
  I: Integer;
  G: TGenre;
begin
  Result := TFb2ObjectList.Create;
  Subjects := MetaValues('subject');
  try
    Codes := MatchGenres(Subjects);
  finally
    Subjects.Free;
  end;
  try
    for I := 0 to Codes.Count - 1 do
    begin
      G := TGenre.Create;
      G.Value := Codes[I];
      Result.Add(G);
    end;
  finally
    Codes.Free;
  end;
end;

function TEpubToFb2Converter.Authors: TFb2ObjectList;
var
  Values: TTextList;
  I: Integer;
begin
  Result := TFb2ObjectList.Create;
  Values := MetaValues('creator');
  try
    for I := 0 to Values.Count - 1 do
      Result.Add(SplitAuthor(Values[I]));
  finally
    Values.Free;
  end;
end;

{ Аннотация из description. }
function TEpubToFb2Converter.AnnotationOf: TAnnotation;
var
  Values: TTextList;
  Desc: UnicodeString;
  P: TParagraph;
begin
  Result := nil;
  Values := MetaValues('description');
  try
    if Values.Count = 0 then
      Exit;
    Desc := Values[0];
  finally
    Values.Free;
  end;
  if Desc = '' then
    Exit;
  Result := TAnnotation.Create;
  P := TParagraph.Create;
  P.Content.Add(TStyleNode.Create(TEXT_NODE_NAME, Desc));
  Result.Items.Add(P);
end;

{ Дата публикации из date. }
function TEpubToFb2Converter.DateFieldOf: TDateField;
var
  Values: TTextList;
  Value: UnicodeString;
begin
  Result := nil;
  Values := MetaValues('date');
  try
    if Values.Count = 0 then
      Exit;
    Value := Values[0];
  finally
    Values.Free;
  end;
  if Value = '' then
    Exit;
  Result := TDateField.Create;
  Result.Value := Value;
  Result.DateValue := MatchDatePrefix(Value);
end;

{ Обложка coverpage, если найдена. }
function TEpubToFb2Converter.CoverPageOf: TCoverPage;
var
  Img: TInlineImage;
begin
  Result := nil;
  if FCoverHref = '' then
    Exit;
  Result := TCoverPage.Create;
  Img := TInlineImage.Create;
  Img.Href := FCoverHref;
  Result.Images.Add(Img);
end;

{ Собрать корневую структуру FictionBook. }
function TEpubToFb2Converter.Assemble(Body: TBody): TFictionBook;
var
  TI: TTitleInfo;
  DI: TDocumentInfo;
  Desc: TDescription;
  Values: TTextList;
  Title, Ident, Lang: UnicodeString;
  A: TAuthor;
  T: TTextField;
  L: TFb2ObjectList;
begin
  { --- title-info --- }
  Values := MetaValues('title');
  try
    if Values.Count > 0 then
      Title := Values[0]
    else
      Title := '';
  finally
    Values.Free;
  end;
  if Title = '' then
    Title := 'Untitled';

  Values := MetaValues('language');
  try
    if Values.Count > 0 then
      Lang := Values[0]
    else
      Lang := '';
  finally
    Values.Free;
  end;

  TI := TTitleInfo.Create;
  L := Genres;
  try
    MoveAll(L, TI.Genres);
  finally
    L.Free;
  end;
  L := Authors;
  try
    MoveAll(L, TI.Authors);
  finally
    L.Free;
  end;
  T := TTextField.Create;
  T.Value := Title;
  TI.BookTitle := T;
  TI.Annotation := AnnotationOf;
  TI.Date := DateFieldOf;
  TI.Coverpage := CoverPageOf;
  TI.Lang := Lang;

  { --- document-info --- }
  DI := TDocumentInfo.Create;
  A := TAuthor.Create;
  A.Nickname := 'pyFB2';
  DI.Authors.Add(A);
  T := TTextField.Create;
  T.Value := FProgramUsed;
  DI.ProgramUsed := T;
  DI.Date := TDateField.Create;
  DI.Date.Value := FormatDateTime('yyyy-mm-dd', Now);

  Values := MetaValues('identifier');
  try
    if Values.Count > 0 then
      Ident := Values[0]
    else
      Ident := '';
  finally
    Values.Free;
  end;
  if Ident = '' then
    Ident := NewGuidHex;
  DI.Id := Ident;
  DI.Version := 1.0;
  DI.HasVersion := True;

  Desc := TDescription.Create;
  Desc.TitleInfo := TI;
  Desc.DocumentInfo := DI;

  Result := TFictionBook.Create;
  Result.Description := Desc;
  Result.Bodies.Add(Body);
  MoveAll(FBinaries, Result.Binaries);
end;

{ ===================== Spine -> Body ===================== }

const
  { Уровни заголовков XHTML. }
  HEADING_LEVELS: array[0..5] of string =
    ('h1', 'h2', 'h3', 'h4', 'h5', 'h6');

{ Уровень заголовка h1..h6 (0 — не заголовок). }
function HeadingLevel(const Name: UnicodeString): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(HEADING_LEVELS) do
    if Name = HEADING_LEVELS[I] then
      Exit(I + 1);
end;

{ Инлайн-элементы XHTML, преобразуемые в styleType. }
function IsInlineTag(const Name: UnicodeString): Boolean;
begin
  Result := (Name = 'strong') or (Name = 'b') or (Name = 'em') or
    (Name = 'i') or (Name = 'sub') or (Name = 'sup') or (Name = 'code') or
    (Name = 'tt') or (Name = 'kbd') or (Name = 'samp') or (Name = 'var') or
    (Name = 'strike') or (Name = 's') or (Name = 'del') or (Name = 'a') or
    (Name = 'img') or (Name = 'br') or (Name = 'span') or (Name = 'font') or
    (Name = 'small') or (Name = 'big') or (Name = 'q') or (Name = 'mark') or
    (Name = 'u') or (Name = 'abbr') or (Name = 'bdi') or (Name = 'bdo') or
    (Name = 'label') or (Name = 'cite') or (Name = 'dfn');
end;

{ Контейнерные элементы XHTML, которые разворачиваются на месте. }
function IsBlockContainer(const Name: UnicodeString): Boolean;
begin
  Result := (Name = 'div') or (Name = 'section') or (Name = 'article') or
    (Name = 'header') or (Name = 'footer') or (Name = 'main') or
    (Name = 'aside') or (Name = 'nav') or (Name = 'center');
end;

{ Блочные элементы XHTML. Нужны, чтобы распознавать «обёртки» — например
  <span> вокруг <p>/<div> (типично для EPUB, собранных из FB2): такие
  элементы нельзя разбирать как инлайн, их содержимое надо обойти как
  контейнер, иначе текст книги теряется. }
function IsBlockTag(const Name: UnicodeString): Boolean;
begin
  Result := IsBlockContainer(Name) or (HeadingLevel(Name) > 0) or
    (Name = 'p') or (Name = 'blockquote') or (Name = 'table') or
    (Name = 'ul') or (Name = 'ol') or (Name = 'li') or (Name = 'pre') or
    (Name = 'address') or (Name = 'figure') or (Name = 'img') or
    (Name = 'hr') or (Name = 'dl') or (Name = 'dt') or (Name = 'dd') or
    (Name = 'form') or (Name = 'fieldset');
end;

{ Есть ли внутри узла блочные элементы (узел — «обёртка»). }
function HasBlockContent(Node: TDOMNode): Boolean;
var
  Child: TDOMNode;
begin
  Result := False;
  if Node = nil then
    Exit;
  Child := Node.FirstChild;
  while Child <> nil do
  begin
    if Child.NodeType = ELEMENT_NODE then
      if IsBlockTag(ElemLocalName(Child.NodeName)) or HasBlockContent(Child) then
        Exit(True);
    Child := Child.NextSibling;
  end;
end;

{ Перенести узлы из Nodes в Dst и освободить контейнер Nodes. }
procedure TakeNodes(Nodes, Dst: TFb2ObjectList);
begin
  MoveAll(Nodes, Dst);
  Nodes.Free;
end;

{ Мягкое приведение строки к int (NO_VALUE при ошибке). }
function ToIntOrNoValue(const S: UnicodeString): Integer;
var
  T: UnicodeString;
begin
  T := PyStrip(S);
  if (T = '') or (not TryStrToInt(T, Result)) then
    Result := NO_VALUE;
end;

{ Разбить текст по строкам (аналог str.splitlines()). }
procedure SplitLines(const S: UnicodeString; List: TTextList);
var
  I, Start: Integer;
  C: WideChar;
  U: LongWord;

  function IsBreak(Index: Integer): Boolean;
  begin
    C := S[Index];
    U := Ord(C);
    Result := (C = #10) or (C = #13) or (C = #11) or (C = #12) or
      ((U >= $1C) and (U <= $1E)) or (U = $85) or (U = $2028) or (U = $2029);
  end;

begin
  Start := 1;
  I := 1;
  while I <= Length(S) do
  begin
    if IsBreak(I) then
    begin
      List.Add(Copy(S, Start, I - Start));
      if (S[I] = #13) and (I < Length(S)) and (S[I + 1] = #10) then
        Inc(I);
      Inc(I);
      Start := I;
    end
    else
      Inc(I);
  end;
  if Start <= Length(S) then
    List.Add(Copy(S, Start, MaxInt));
end;

{ Добавить уровень в стек секций. }
procedure AddLevel(Stack: TSectionLevelList; Level: Integer;
  Section: TSection);
var
  Lvl: TSectionLevel;
begin
  Lvl := TSectionLevel.Create;
  Lvl.Level := Level;
  Lvl.Section := Section;
  Stack.Add(Lvl);
end;

{ Преобразовать документы spine в структуру Body. }
{ ===================== Оглавление EPUB (nav/NCX) ===================== }

constructor TTocEntry.Create;
begin
  inherited Create;
  Children := TList.Create;
end;

destructor TTocEntry.Destroy;
var
  I: Integer;
begin
  for I := 0 to Children.Count - 1 do
    TTocEntry(Children[I]).Free;
  FreeAndNil(Children);
  inherited Destroy;
end;

destructor TSpineDoc.Destroy;
begin
  FreeAndNil(Doc);
  inherited Destroy;
end;

{ Освободить список узлов оглавления (рекурсивно). }
procedure FreeTocEntries(L: TList);
var
  I: Integer;
begin
  if L = nil then
    Exit;
  for I := 0 to L.Count - 1 do
    TTocEntry(L[I]).Free;
  L.Free;
end;

{ Весь текст поддерева (аналог "".join(elem.itertext())). }
function SubtreeText(Node: TDOMNode): UnicodeString;
var
  Child: TDOMNode;
begin
  Result := '';
  if Node = nil then
    Exit;
  Child := Node.FirstChild;
  while Child <> nil do
  begin
    if (Child.NodeType = TEXT_NODE) or (Child.NodeType = CDATA_SECTION_NODE) then
      Result := Result + Child.NodeValue
    else if Child.NodeType = ELEMENT_NODE then
      Result := Result + SubtreeText(Child);
    Child := Child.NextSibling;
  end;
end;

{ Простой текст списка узлов разметки. }
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
end;

{ Нормализация заголовка для сравнения (пробелы, звёздочки). }
function NormTitle(const S: UnicodeString): UnicodeString;
var
  I: Integer;
  Cur: UnicodeString;
  C: WideChar;
  PrevSpace: Boolean;
begin
  Cur := '';
  PrevSpace := True;
  for I := 1 to Length(S) do
  begin
    C := S[I];
    if (C = ' ') or (C = #9) or (C = #10) or (C = #13) then
    begin
      if not PrevSpace then
        Cur := Cur + ' ';
      PrevSpace := True;
    end
    else
    begin
      Cur := Cur + C;
      PrevSpace := False;
    end;
  end;
  Cur := PyStrip(Cur);
  while (Cur <> '') and (Cur[1] = '*') do
    Cur := Copy(Cur, 2, MaxInt);
  while (Cur <> '') and (Cur[Length(Cur)] = '*') do
    Cur := Copy(Cur, 1, Length(Cur) - 1);
  Result := PyStrip(Cur);
end;

{ Убрать все пробельные символы (сравнение «склеенных» строк). }
function Squash(const S: UnicodeString): UnicodeString;
var
  I: Integer;
  C: WideChar;
begin
  Result := '';
  for I := 1 to Length(S) do
  begin
    C := S[I];
    if (C <> ' ') and (C <> #9) and (C <> #10) and (C <> #13) then
      Result := Result + C;
  end;
end;

{ Есть ли Token среди пробельно-разделённых слов S. }
function HasToken(const S, Token: UnicodeString): Boolean;
var
  I: Integer;
  Cur: UnicodeString;
  C: WideChar;
begin
  Result := False;
  Cur := '';
  for I := 1 to Length(S) + 1 do
  begin
    if I <= Length(S) then
      C := S[I]
    else
      C := ' ';
    if (C = ' ') or (C = #9) or (C = #10) or (C = #13) then
    begin
      if Cur = Token then
        Exit(True);
      Cur := '';
    end
    else
      Cur := Cur + C;
  end;
end;

{ Значение атрибута по локальному имени (аналог GetAttrQ). }
function GetAttrLocal(E: TDOMElement; const ALocal: UnicodeString): UnicodeString;
var
  Attrs: TDOMNamedNodeMap;
  I: Integer;
  Count: LongWord;
  Attr: TDOMNode;
begin
  Result := '';
  if E = nil then
    Exit;
  Attrs := E.Attributes;
  if Attrs = nil then
    Exit;
  Count := Attrs.Length;
  for I := 0 to Integer(Count) - 1 do
  begin
    Attr := Attrs.Item[LongWord(I)];
    if (Attr <> nil) and (LocalName(Attr.NodeName) = ALocal) then
      Exit(Attr.NodeValue);
  end;
end;

{ Разделить href оглавления на путь в архиве и фрагмент (#id). }
procedure SplitTocHref(const BaseDir, Href: UnicodeString;
  out Path, Fragment: UnicodeString);
var
  H: UnicodeString;
  P: Integer;
begin
  H := Href;
  Fragment := '';
  P := Pos('#', H);
  if P > 0 then
  begin
    Fragment := Copy(H, P + 1, MaxInt);
    H := Copy(H, 1, P - 1);
  end;
  H := Unquote(H);
  if H = '' then
    Path := ''
  else if H[1] = '/' then
  begin
    while (H <> '') and (H[1] = '/') do
      H := Copy(H, 2, MaxInt);
    Path := H;
  end
  else
    Path := PosixNormPath(PosixJoin(BaseDir, H));
end;

{ Собрать все элементы <nav> в поддереве (в порядке обхода). }
procedure CollectNavs(Node: TDOMNode; Navs: TList);
var
  Child: TDOMNode;
begin
  if Node = nil then
    Exit;
  Child := Node.FirstChild;
  while Child <> nil do
  begin
    if Child.NodeType = ELEMENT_NODE then
    begin
      if ElemLocalName(Child.NodeName) = 'nav' then
        Navs.Add(Child);
      CollectNavs(Child, Navs);
    end;
    Child := Child.NextSibling;
  end;
end;

{ Преобразовать документы spine в структуру Body. }
function TEpubToFb2Converter.ConvertSpine(Root: TDOMElement): TBody;
var
  Docs: TSpineDocList;
  Toc: TList;
  I: Integer;
  RootSection, Extra: TSection;
  Stack: TSectionLevelList;
begin
  Docs := TSpineDocList.Create(True);
  try
    ReadSpineDocs(Root, Docs);

    Toc := ParseToc(Root);
    if Toc <> nil then
    begin
      try
        Result := BodyFromToc(Docs, Toc);
      finally
        FreeTocEntries(Toc);
      end;
      Exit;
    end;

    Result := TBody.Create;
    RootSection := TSection.Create;
    Stack := TSectionLevelList.Create;
    try
      AddLevel(Stack, 0, RootSection);
      for I := 0 to Docs.Count - 1 do
        Walk(Docs[I].Body, Docs[I].Path, Stack);

      MoveAll(RootSection.Sections, Result.Sections);
      if RootSection.Content.Count > 0 then
      begin
        Extra := TSection.Create;
        MoveAll(RootSection.Content, Extra.Content);
        Result.Sections.Insert(0, Extra);
      end;
      if Result.Sections.Count = 0 then
        Result.Sections.Add(TSection.Create);
      FixEmptySections(Result.Sections);
    finally
      Stack.Free;
      RootSection.Free;
    end;
  finally
    Docs.Free;
  end;
end;

{ Прочитать документы spine как список (путь, <body>). }
procedure TEpubToFb2Converter.ReadSpineDocs(Root: TDOMElement;
  Docs: TSpineDocList);
var
  Spine: TDOMElement;
  ItemRef: TDOMNode;
  Item: TEpubManifestItem;
  IdRef, Path: UnicodeString;
  Data: TBytes;
  Doc: TXMLDocument;
  HtmlBody: TDOMElement;
  D: TSpineDoc;
begin
  Spine := FindChildElement(Root, 'spine');
  if Spine = nil then
    Exit;
  ItemRef := Spine.FirstChild;
  while ItemRef <> nil do
  begin
    if (ItemRef.NodeType = ELEMENT_NODE) and
      (ElemLocalName(ItemRef.NodeName) = 'itemref') then
    begin
      IdRef := GetAttr(TDOMElement(ItemRef), 'idref');
      Item := nil;
      if IdRef <> '' then
        Item := FindManifestItem(IdRef);
      if Item <> nil then
      begin
        Path := ResolveHref(Item.Href);
        if FZip.Has(Path) then
        begin
          Data := FZip.Read(Path);
          Doc := nil;
          try
            try
              Doc := ParseXmlBytes(Data);
            except
              Doc := nil;
            end;
            if Doc <> nil then
            begin
              HtmlBody := FindDescendant(Doc.DocumentElement, 'body');
              if HtmlBody <> nil then
              begin
                D := TSpineDoc.Create;
                D.Path := Path;
                D.Body := HtmlBody;
                D.Doc := Doc;
                Docs.Add(D);
                Doc := nil;
              end;
            end;
          finally
            if Doc <> nil then
              Doc.Free;
          end;
        end;
      end;
    end;
    ItemRef := ItemRef.NextSibling;
  end;
end;

{ Есть ли в поддереве заголовок h1-h6. }
function TEpubToFb2Converter.HasHeading(Node: TDOMNode): Boolean;
var
  Child: TDOMNode;
begin
  Result := False;
  if Node = nil then
    Exit;
  Child := Node.FirstChild;
  while Child <> nil do
  begin
    if Child.NodeType = ELEMENT_NODE then
    begin
      if HeadingLevel(ElemLocalName(Child.NodeName)) > 0 then
        Exit(True);
      if HasHeading(Child) then
        Exit(True);
    end;
    Child := Child.NextSibling;
  end;
end;

{ Прочитать оглавление EPUB (nav.xhtml либо toc.ncx). nil — нет оглавления. }
function TEpubToFb2Converter.ParseToc(Root: TDOMElement): TList;
var
  I: Integer;
  Entries: TList;
  NcxPath: UnicodeString;
begin
  Result := nil;
  for I := 0 to FManifest.Count - 1 do
    if HasToken(FManifest[I].Properties, 'nav') then
    begin
      Entries := ParseTocNav(ResolveHref(FManifest[I].Href));
      if (Entries <> nil) and (Entries.Count > 0) then
        Exit(Entries);
      FreeTocEntries(Entries);
    end;
  NcxPath := FindNcxPath(Root);
  if NcxPath <> '' then
    Exit(ParseTocNcx(NcxPath));
end;

{ Путь к toc.ncx в архиве (по spine@toc либо media-type). }
function TEpubToFb2Converter.FindNcxPath(Root: TDOMElement): UnicodeString;
var
  Spine: TDOMElement;
  TocId: UnicodeString;
  Item: TEpubManifestItem;
  I: Integer;
begin
  Result := '';
  Spine := FindChildElement(Root, 'spine');
  if Spine <> nil then
  begin
    TocId := GetAttr(Spine, 'toc');
    if TocId <> '' then
    begin
      Item := FindManifestItem(TocId);
      if Item <> nil then
        Exit(ResolveHref(Item.Href));
    end;
  end;
  for I := 0 to FManifest.Count - 1 do
    if FManifest[I].MediaType = 'application/x-dtbncx+xml' then
      Exit(ResolveHref(FManifest[I].Href));
end;

{ Разобрать nav.xhtml (EPUB3). }
function TEpubToFb2Converter.ParseTocNav(const NavPath: UnicodeString): TList;
var
  Data: TBytes;
  Doc: TXMLDocument;
  Navs: TList;
  Nav, Fallback, El, Ol: TDOMElement;
  I: Integer;
begin
  Result := nil;
  if not FZip.Has(NavPath) then
    Exit;
  Data := FZip.Read(NavPath);
  Doc := nil;
  Navs := TList.Create;
  try
    try
      Doc := ParseXmlBytes(Data);
    except
      Doc := nil;
    end;
    if Doc = nil then
      Exit;
    CollectNavs(Doc.DocumentElement, Navs);
    Nav := nil;
    Fallback := nil;
    for I := 0 to Navs.Count - 1 do
    begin
      El := TDOMElement(Navs[I]);
      if GetAttrLocal(El, 'type') = 'toc' then
      begin
        Nav := El;
        Break;
      end;
      if Fallback = nil then
        Fallback := El;
    end;
    if Nav = nil then
      Nav := Fallback;
    if Nav = nil then
      Exit;
    Ol := FindChildElement(Nav, 'ol');
    if Ol = nil then
      Exit;
    Result := TList.Create;
    ParseNavOl(Ol, PosixDirname(NavPath), Result);
  finally
    Navs.Free;
    Doc.Free;
  end;
end;

{ Разобрать <ol> навигационного документа. }
procedure TEpubToFb2Converter.ParseNavOl(Ol: TDOMElement;
  const BaseDir: UnicodeString; Entries: TList);
var
  Li, Child: TDOMNode;
  Name, Caption, Href, Path, Frag: UnicodeString;
  SubOl: TDOMElement;
  Entry: TTocEntry;
  Kids: TList;
  I: Integer;
begin
  if Ol = nil then
    Exit;
  Li := Ol.FirstChild;
  while Li <> nil do
  begin
    if (Li.NodeType = ELEMENT_NODE) and (ElemLocalName(Li.NodeName) = 'li') then
    begin
      Caption := '';
      Href := '';
      Child := Li.FirstChild;
      while Child <> nil do
      begin
        if Child.NodeType = ELEMENT_NODE then
        begin
          Name := ElemLocalName(Child.NodeName);
          if Name = 'a' then
          begin
            Caption := PyStrip(SubtreeText(Child));
            Href := GetAttr(TDOMElement(Child), 'href');
            Break;
          end
          else if Name = 'span' then
          begin
            Caption := PyStrip(SubtreeText(Child));
            Break;
          end;
        end;
        Child := Child.NextSibling;
      end;
      SubOl := FindChildElement(Li, 'ol');
      Kids := TList.Create;
      if SubOl <> nil then
        ParseNavOl(SubOl, BaseDir, Kids);
      SplitTocHref(BaseDir, Href, Path, Frag);
      if (Caption <> '') or (Path <> '') or (Kids.Count > 0) then
      begin
        Entry := TTocEntry.Create;
        Entry.Caption := Caption;
        Entry.Path := Path;
        Entry.Fragment := Frag;
        for I := 0 to Kids.Count - 1 do
          Entry.Children.Add(Kids[I]);
        Kids.Clear;
        Kids.Free;
        Entries.Add(Entry);
      end
      else
      begin
        for I := 0 to Kids.Count - 1 do
          TTocEntry(Kids[I]).Free;
        Kids.Free;
      end;
    end;
    Li := Li.NextSibling;
  end;
end;

{ Разобрать toc.ncx (EPUB2). }
function TEpubToFb2Converter.ParseTocNcx(const NcxPath: UnicodeString): TList;
var
  Data: TBytes;
  Doc: TXMLDocument;
  NavMap: TDOMElement;
begin
  Result := nil;
  if not FZip.Has(NcxPath) then
    Exit;
  Data := FZip.Read(NcxPath);
  Doc := nil;
  try
    try
      Doc := ParseXmlBytes(Data);
    except
      Doc := nil;
    end;
    if Doc = nil then
      Exit;
    NavMap := FindDescendant(Doc.DocumentElement, 'navMap');
    if NavMap = nil then
      Exit;
    Result := TList.Create;
    ParseNavPoints(NavMap, PosixDirname(NcxPath), Result);
  finally
    Doc.Free;
  end;
end;

{ Разобрать <navPoint> внутри navMap/navPoint. }
procedure TEpubToFb2Converter.ParseNavPoints(Parent: TDOMNode;
  const BaseDir: UnicodeString; Entries: TList);
var
  Child, Sub: TDOMNode;
  Name, Caption, Href, Path, Frag: UnicodeString;
  Entry: TTocEntry;
  Kids: TList;
  I: Integer;
begin
  if Parent = nil then
    Exit;
  Child := Parent.FirstChild;
  while Child <> nil do
  begin
    if (Child.NodeType = ELEMENT_NODE) and
      (ElemLocalName(Child.NodeName) = 'navPoint') then
    begin
      Caption := '';
      Href := '';
      Sub := Child.FirstChild;
      while Sub <> nil do
      begin
        if Sub.NodeType = ELEMENT_NODE then
        begin
          Name := ElemLocalName(Sub.NodeName);
          if Name = 'navLabel' then
            Caption := PyStrip(SubtreeText(Sub))
          else if Name = 'content' then
            Href := GetAttr(TDOMElement(Sub), 'src');
        end;
        Sub := Sub.NextSibling;
      end;
      SplitTocHref(BaseDir, Href, Path, Frag);
      Kids := TList.Create;
      ParseNavPoints(Child, BaseDir, Kids);
      Entry := TTocEntry.Create;
      Entry.Caption := Caption;
      Entry.Path := Path;
      Entry.Fragment := Frag;
      for I := 0 to Kids.Count - 1 do
        Entry.Children.Add(Kids[I]);
      Kids.Clear;
      Kids.Free;
      Entries.Add(Entry);
    end;
    Child := Child.NextSibling;
  end;
end;

{ Построить Body по оглавлению EPUB (когда в XHTML нет заголовков). }
function TEpubToFb2Converter.BodyFromToc(Docs: TSpineDocList;
  Toc: TList): TBody;
var
  RootSection, Extra, Trailing, Current, Target: TSection;
  DocEntries: TDocEntryList;
  I, K, Idx, LastAnchor: Integer;
  Match, Empty: TList;
  Stack: TSectionLevelList;
  D: TSpineDoc;
  Structured, TrailingOwned: Boolean;
begin
  Result := TBody.Create;
  RootSection := TSection.Create;
  Trailing := TSection.Create;
  TrailingOwned := False;
  DocEntries := TDocEntryList.Create(True);
  Empty := TList.Create;
  try
    BuildTocSections(Toc, RootSection, DocEntries);
    { Последний документ spine, привязанный к оглавлению. }
    LastAnchor := -1;
    for I := 0 to Docs.Count - 1 do
    begin
      D := Docs[I];
      for K := 0 to DocEntries.Count - 1 do
        if DocEntries[K].Path = D.Path then
        begin
          LastAnchor := I;
          Break;
        end;
    end;
    Current := RootSection;
    for I := 0 to Docs.Count - 1 do
    begin
      D := Docs[I];
      Match := TList.Create;
      Stack := TSectionLevelList.Create;
      try
        for K := 0 to DocEntries.Count - 1 do
          if DocEntries[K].Path = D.Path then
            Match.Add(DocEntries[K]);
        if Match.Count > 0 then
        begin
          Current := TDocEntry(Match[0]).Section;
          AddLevel(Stack, 0, Current);
          Idx := 1;
          WalkToc(D.Body, D.Path, Stack, True, Match, Idx);
          { Продолжение главы дописывается в последнюю её подсекцию. }
          Current := Stack[Stack.Count - 1].Section;
        end
        else
        begin
          if LastAnchor < 0 then
          begin
            { Оглавление не ссылается ни на один документ spine. }
            Target := RootSection;
            Structured := False;
          end
          else if I > LastAnchor then
          begin
            { Сноски и приложения после последнего раздела оглавления. }
            Target := Trailing;
            Structured := True;
          end
          else
          begin
            { Продолжение предыдущей главы (документ разбит на части). }
            Target := Current;
            Structured := False;
          end;
          AddLevel(Stack, 0, Target);
          Idx := 0;
          WalkToc(D.Body, D.Path, Stack, Structured, Empty, Idx);
        end;
      finally
        Stack.Free;
        Match.Free;
      end;
    end;
    MoveAll(RootSection.Sections, Result.Sections);
    if RootSection.Content.Count > 0 then
    begin
      Extra := TSection.Create;
      MoveAll(RootSection.Content, Extra.Content);
      Result.Sections.Insert(0, Extra);
    end;
    if (Trailing.Content.Count > 0) or (Trailing.Sections.Count > 0) then
    begin
      Result.Sections.Add(Trailing);
      TrailingOwned := True;
    end;
    if Result.Sections.Count = 0 then
      Result.Sections.Add(TSection.Create);
    FixEmptySections(Result.Sections);
  finally
    Empty.Free;
    DocEntries.Free;
    RootSection.Free;
    if not TrailingOwned then
      Trailing.Free;
  end;
end;

{ Создать секции по дереву оглавления и запомнить их по документам. }
procedure TEpubToFb2Converter.BuildTocSections(Entries: TList;
  ParentSection: TSection; DocEntries: TDocEntryList);
var
  I: Integer;
  Entry: TTocEntry;
  Section: TSection;
  DE: TDocEntry;
  Caption: UnicodeString;
begin
  if Entries = nil then
    Exit;
  for I := 0 to Entries.Count - 1 do
  begin
    Entry := TTocEntry(Entries[I]);
    Section := TSection.Create;
    Caption := NormTitle(Entry.Caption);
    if Caption <> '' then
      Section.Title := MakeTextTitle(Caption);
    ParentSection.Sections.Add(Section);
    if Entry.Path <> '' then
    begin
      DE := TDocEntry.Create;
      DE.Path := Entry.Path;
      DE.Fragment := Entry.Fragment;
      DE.Section := Section;
      DocEntries.Add(DE);
    end;
    BuildTocSections(Entry.Children, Section, DocEntries);
  end;
end;

{ Обойти документ, раскладывая блоки по секциям оглавления (по якорям). }
procedure TEpubToFb2Converter.WalkToc(Elem: TDOMNode;
  const CurrentPath: UnicodeString; Stack: TSectionLevelList;
  Structured: Boolean; Remaining: TList; var Idx: Integer);
var
  Child: TDOMNode;
  Name, Anchor, Text: UnicodeString;
  Block: TFb2Object;
  List: TFb2ObjectList;
  S: TSubtitle;
  DE: TDocEntry;
  NewSection: TSection;
  Level, K: Integer;
  Titles: TStringList;
begin
  if Elem = nil then
    Exit;
  Child := Elem.FirstChild;
  while Child <> nil do
  begin
    if Child.NodeType = ELEMENT_NODE then
    begin
      Name := ElemLocalName(Child.NodeName);
      Anchor := GetAttr(TDOMElement(Child), 'id');
      if (Anchor <> '') and (Idx < Remaining.Count) then
      begin
        DE := TDocEntry(Remaining[Idx]);
        if DE.Fragment = Anchor then
        begin
          Stack.Clear;
          AddLevel(Stack, 0, DE.Section);
          Inc(Idx);
        end;
      end;
      if HeadingLevel(Name) > 0 then
      begin
        if not Structured then
        begin
          S := TSubtitle.Create;
          TakeNodes(ConvertInline(Child, CurrentPath), S.Content);
          Stack[Stack.Count - 1].Section.Content.Add(S);
        end
        else
        begin
          Text := NormTitle(SubtreeText(Child));
          Titles := TStringList.Create;
          try
            Titles.CaseSensitive := True;
            for K := 0 to Stack.Count - 1 do
              Titles.Add(SectionTitleText(Stack[K].Section));
            if (Text = '') or (Titles.IndexOf(Text) < 0) then
            begin
              Level := HeadingLevel(Name);
              while (Stack.Count > 1) and
                (Stack[Stack.Count - 1].Level >= Level) do
                Stack.Delete(Stack.Count - 1);
              NewSection := TSection.Create;
              NewSection.Title := MakeTitle(Child, CurrentPath);
              Stack[Stack.Count - 1].Section.Sections.Add(NewSection);
              AddLevel(Stack, Level, NewSection);
            end;
          finally
            Titles.Free;
          end;
        end;
      end
      else if IsBlockContainer(Name) then
      begin
        if not IsTitleDuplicate(Child, Stack[Stack.Count - 1].Section) then
          WalkToc(Child, CurrentPath, Stack, Structured, Remaining, Idx);
      end
      else if (Name = 'ul') or (Name = 'ol') then
      begin
        List := ConvertList(Child, CurrentPath);
        try
          MoveAll(List, Stack[Stack.Count - 1].Section.Content);
        finally
          List.Free;
        end;
      end
      else if (Name = 'pre') or (Name = 'address') then
      begin
        List := ConvertPre(Child, CurrentPath);
        try
          MoveAll(List, Stack[Stack.Count - 1].Section.Content);
        finally
          List.Free;
        end;
      end
      else
      begin
        Block := ConvertBlock(Child, CurrentPath);
        if Block = nil then
        begin
          { Обёртка (например <span>) вокруг блочных элементов. }
          if HasBlockContent(Child) and
            (not IsTitleDuplicate(Child, Stack[Stack.Count - 1].Section)) then
            WalkToc(Child, CurrentPath, Stack, Structured, Remaining, Idx);
        end
        else if not IsTitleRepeat(Block, Stack[Stack.Count - 1].Section) then
          Stack[Stack.Count - 1].Section.Content.Add(Block);
      end;
    end;
    Child := Child.NextSibling;
  end;
end;

{ Заголовок секции из простого текста. }
function TEpubToFb2Converter.MakeTextTitle(const Text: UnicodeString): TTitle;
var
  P: TParagraph;
begin
  Result := TTitle.Create;
  P := TParagraph.Create;
  P.Content.Add(TStyleNode.Create(TEXT_NODE_NAME, Text));
  Result.Items.Add(P);
end;

{ Нормализованный текст заголовка секции. }
function TEpubToFb2Converter.SectionTitleText(Section: TSection): UnicodeString;
var
  I: Integer;
  Item: TFb2Object;
  Parts: UnicodeString;
begin
  Result := '';
  if (Section = nil) or (Section.Title = nil) then
    Exit;
  Parts := '';
  for I := 0 to Section.Title.Items.Count - 1 do
  begin
    Item := Section.Title.Items[I];
    if Item is TParagraph then
    begin
      if Parts <> '' then
        Parts := Parts + ' ';
      Parts := Parts + NodesText(TParagraph(Item).Content);
    end;
  end;
  Result := NormTitle(Parts);
end;

{ Повторяет ли блок заголовок секции (заголовок уже есть в <title> из
  оглавления, конвертеры FB2 -> EPUB оставляют его и в тексте). }
function TEpubToFb2Converter.IsTitleRepeat(Block: TFb2Object;
  Section: TSection): Boolean;
var
  Title: UnicodeString;
begin
  Result := False;
  if (Block = nil) or (Section = nil) or (Section.Content.Count > 0) then
    Exit;
  if not (Block is TParagraph) then
    Exit;
  Title := SectionTitleText(Section);
  if Title = '' then
    Exit;
  Result := NormTitle(NodesText(TParagraph(Block).Content)) = Title;
end;

{ Дублирует ли контейнер (<div class="title">) заголовок секции. Заголовок
  может собираться из нескольких строк (<div class="title1"><p>Глава 1</p>
  <p>КТО СУДЬИ...</p></div>) — сравнение идёт по тексту без пробелов. }
function TEpubToFb2Converter.IsTitleDuplicate(Node: TDOMNode;
  Section: TSection): Boolean;
var
  Title: UnicodeString;
begin
  Result := False;
  if (Node = nil) or (Section = nil) or (Section.Content.Count > 0) then
    Exit;
  Title := SectionTitleText(Section);
  if Title = '' then
    Exit;
  Result := Squash(SubtreeText(Node)) = Squash(Title);
end;

{ Секция обязана иметь текстовое содержимое: добавить empty-line. }
procedure TEpubToFb2Converter.FixEmptySections(Sections: TFb2ObjectList);
var
  I, J: Integer;
  Section: TSection;
  OnlyImages: Boolean;
begin
  if Sections = nil then
    Exit;
  for I := 0 to Sections.Count - 1 do
  begin
    Section := TSection(Sections[I]);
    FixEmptySections(Section.Sections);
    if Section.Content.Count = 0 then
    begin
      if Section.Sections.Count = 0 then
        Section.Content.Add(TEmptyLine.Create);
    end
    else
    begin
      OnlyImages := True;
      for J := 0 to Section.Content.Count - 1 do
        if not (Section.Content[J] is TImage) then
        begin
          OnlyImages := False;
          Break;
        end;
      if OnlyImages then
        Section.Content.Add(TEmptyLine.Create);
    end;
  end;
end;

{ Рекурсивно обойти контейнер, строя иерархию секций по заголовкам. }
procedure TEpubToFb2Converter.Walk(Elem: TDOMNode;
  const CurrentPath: UnicodeString; Stack: TSectionLevelList);
var
  Child: TDOMNode;
  Name: UnicodeString;
  Level: Integer;
  NewSection: TSection;
  Block: TFb2Object;
  List: TFb2ObjectList;
  Top: TSection;
begin
  if Elem = nil then
    Exit;
  Child := Elem.FirstChild;
  while Child <> nil do
  begin
    if Child.NodeType = ELEMENT_NODE then
    begin
      Name := ElemLocalName(Child.NodeName);
      Top := Stack[Stack.Count - 1].Section;
      Level := HeadingLevel(Name);
      if Level > 0 then
      begin
        while (Stack.Count > 1) and
          (Stack[Stack.Count - 1].Level >= Level) do
          Stack.Delete(Stack.Count - 1);
        NewSection := TSection.Create;
        NewSection.Title := MakeTitle(Child, CurrentPath);
        Stack[Stack.Count - 1].Section.Sections.Add(NewSection);
        AddLevel(Stack, Level, NewSection);
      end
      else if IsBlockContainer(Name) then
      begin
        if not IsTitleDuplicate(Child, Top) then
          Walk(Child, CurrentPath, Stack);
      end
      else if (Name = 'ul') or (Name = 'ol') then
      begin
        List := ConvertList(Child, CurrentPath);
        try
          MoveAll(List, Stack[Stack.Count - 1].Section.Content);
        finally
          List.Free;
        end;
      end
      else if (Name = 'pre') or (Name = 'address') then
      begin
        List := ConvertPre(Child, CurrentPath);
        try
          MoveAll(List, Stack[Stack.Count - 1].Section.Content);
        finally
          List.Free;
        end;
      end
      else
      begin
        Block := ConvertBlock(Child, CurrentPath);
        if Block = nil then
        begin
          { Обёртка (например <span>) вокруг блочных элементов. }
          if HasBlockContent(Child) and (not IsTitleDuplicate(Child, Top)) then
            Walk(Child, CurrentPath, Stack);
        end
        else
          Top.Content.Add(Block);
      end;
    end;
    Child := Child.NextSibling;
  end;
end;

{ Заголовок h1-h6 -> title. }
function TEpubToFb2Converter.MakeTitle(Heading: TDOMNode;
  const CurrentPath: UnicodeString): TTitle;
var
  P: TParagraph;
begin
  Result := TTitle.Create;
  P := TParagraph.Create;
  TakeNodes(ConvertInline(Heading, CurrentPath), P.Content);
  Result.Items.Add(P);
end;

{ Один блочный элемент HTML -> структура FB2 (или nil). }
function TEpubToFb2Converter.ConvertBlock(Elem: TDOMNode;
  const CurrentPath: UnicodeString): TFb2Object;
var
  Name, Href: UnicodeString;
  P: TParagraph;
  S: TSubtitle;
  Img: TImage;
  ImgEl: TDOMElement;
begin
  Result := nil;
  Name := ElemLocalName(Elem.NodeName);
  if Name = 'p' then
  begin
    { <p/> / <p class="empty-line"/> -> <empty-line/>. }
    if (Elem.FirstChild = nil) and (PyStrip(SubtreeText(Elem)) = '') then
      Exit(TEmptyLine.Create);
    P := TParagraph.Create;
    TakeNodes(ConvertInline(Elem, CurrentPath), P.Content);
    Exit(P);
  end;
  if Name = 'blockquote' then
    Exit(ConvertCite(Elem, CurrentPath));
  if Name = 'table' then
    Exit(ConvertTable(Elem, CurrentPath));
  if Name = 'img' then
  begin
    Href := ResolveImage(GetAttr(TDOMElement(Elem), 'src'), CurrentPath);
    if Href = '' then
      Exit;
    Img := TImage.Create;
    Img.Href := Href;
    Img.Alt := GetAttr(TDOMElement(Elem), 'alt');
    Img.Title := GetAttr(TDOMElement(Elem), 'title');
    Exit(Img);
  end;
  if Name = 'figure' then
  begin
    ImgEl := FindDescendant(Elem, 'img');
    if ImgEl = nil then
      Exit;
    Href := ResolveImage(GetAttr(ImgEl, 'src'), CurrentPath);
    if Href = '' then
      Exit;
    Img := TImage.Create;
    Img.Href := Href;
    Img.Alt := GetAttr(ImgEl, 'alt');
    Img.Title := GetAttr(ImgEl, 'title');
    Exit(Img);
  end;
  if Name = 'hr' then
    Exit(TEmptyLine.Create);
  if HeadingLevel(Name) > 0 then
  begin
    S := TSubtitle.Create;
    TakeNodes(ConvertInline(Elem, CurrentPath), S.Content);
    Exit(S);
  end;
end;

{ blockquote -> cite. }
function TEpubToFb2Converter.ConvertCite(Elem: TDOMNode;
  const CurrentPath: UnicodeString): TCite;
var
  Child: TDOMNode;
  Name: UnicodeString;
  Block: TFb2Object;
  S: TSubtitle;
  Nested: TCite;
begin
  Result := TCite.Create;
  Child := Elem.FirstChild;
  while Child <> nil do
  begin
    if Child.NodeType = ELEMENT_NODE then
    begin
      Name := ElemLocalName(Child.NodeName);
      if HeadingLevel(Name) > 0 then
      begin
        S := TSubtitle.Create;
        TakeNodes(ConvertInline(Child, CurrentPath), S.Content);
        Result.Items.Add(S);
      end
      else
      begin
        Block := ConvertBlock(Child, CurrentPath);
        if Block <> nil then
          Result.Items.Add(Block)
        else if IsBlockContainer(Name) or HasBlockContent(Child) then
        begin
          { Обёртка (например <span>) вокруг блочных элементов. }
          Nested := ConvertCite(Child, CurrentPath);
          try
            MoveAll(Nested.Items, Result.Items);
          finally
            Nested.Free;
          end;
        end;
      end;
    end;
    Child := Child.NextSibling;
  end;
end;

{ ul/ol -> список абзацев (FB2 не имеет списков). }
function TEpubToFb2Converter.ConvertList(Elem: TDOMNode;
  const CurrentPath: UnicodeString): TFb2ObjectList;
var
  Child: TDOMNode;
  P: TParagraph;
begin
  Result := TFb2ObjectList.Create;
  Child := Elem.FirstChild;
  while Child <> nil do
  begin
    if (Child.NodeType = ELEMENT_NODE) and
      (ElemLocalName(Child.NodeName) = 'li') then
    begin
      P := TParagraph.Create;
      TakeNodes(ConvertInline(Child, CurrentPath), P.Content);
      Result.Add(P);
    end;
    Child := Child.NextSibling;
  end;
end;

{ table -> table (tr/td/th). }
function TEpubToFb2Converter.ConvertTable(Elem: TDOMNode;
  const CurrentPath: UnicodeString): TTable;
var
  RowEl, CellEl: TDOMNode;
  Row: TTableRow;
  Cell: TTableCell;
  Name: UnicodeString;
begin
  Result := TTable.Create;
  RowEl := Elem.FirstChild;
  while RowEl <> nil do
  begin
    if (RowEl.NodeType = ELEMENT_NODE) and
      (ElemLocalName(RowEl.NodeName) = 'tr') then
    begin
      Row := TTableRow.Create;
      CellEl := RowEl.FirstChild;
      while CellEl <> nil do
      begin
        if CellEl.NodeType = ELEMENT_NODE then
        begin
          Name := ElemLocalName(CellEl.NodeName);
          if (Name = 'td') or (Name = 'th') then
          begin
            Cell := TTableCell.Create;
            Cell.Tag := Name;
            TakeNodes(ConvertInline(CellEl, CurrentPath), Cell.Children);
            Cell.Colspan := ToIntOrNoValue(
              GetAttr(TDOMElement(CellEl), 'colspan'));
            Cell.Rowspan := ToIntOrNoValue(
              GetAttr(TDOMElement(CellEl), 'rowspan'));
            Cell.IsHeader := (Name = 'th');
            Row.Cells.Add(Cell);
          end;
        end;
        CellEl := CellEl.NextSibling;
      end;
      Result.Rows.Add(Row);
    end;
    RowEl := RowEl.NextSibling;
  end;
end;

{ pre/address -> абзацы по строкам (пустые строки -> empty-line). }
function TEpubToFb2Converter.ConvertPre(Elem: TDOMNode;
  const CurrentPath: UnicodeString): TFb2ObjectList;
var
  Lines: TTextList;
  I: Integer;
  P: TParagraph;
begin
  Result := TFb2ObjectList.Create;
  Lines := TTextList.Create;
  try
    SplitLines(Elem.TextContent, Lines);
    for I := 0 to Lines.Count - 1 do
    begin
      if PyStrip(Lines[I]) <> '' then
      begin
        P := TParagraph.Create;
        P.Content.Add(TStyleNode.Create(TEXT_NODE_NAME, Lines[I]));
        Result.Add(P);
      end
      else
        Result.Add(TEmptyLine.Create);
    end;
  finally
    Lines.Free;
  end;
end;

{ Mixed-содержимое HTML -> список StyleNode. }
function TEpubToFb2Converter.ConvertInline(Elem: TDOMNode;
  const CurrentPath: UnicodeString): TFb2ObjectList;
var
  Child: TDOMNode;
  Name, T: UnicodeString;
  Node: TStyleNode;
  L: TFb2ObjectList;
begin
  Result := TFb2ObjectList.Create;
  T := OwnText(Elem);
  if T <> '' then
    Result.Add(TStyleNode.Create(TEXT_NODE_NAME, T));
  Child := Elem.FirstChild;
  while Child <> nil do
  begin
    if Child.NodeType = ELEMENT_NODE then
    begin
      Name := ElemLocalName(Child.NodeName);
      Node := nil;
      if IsInlineTag(Name) then
        Node := ConvertInlineNode(Child, Name, CurrentPath);
      if Node <> nil then
        Result.Add(Node)
      else
      begin
        { Прозрачный элемент — разворачиваем его содержимое. }
        L := ConvertInline(Child, CurrentPath);
        MoveAll(L, Result);
        L.Free;
      end;
      T := TailText(Child);
      if T <> '' then
        Result.Add(TStyleNode.Create(TEXT_NODE_NAME, T));
    end;
    Child := Child.NextSibling;
  end;
end;

{ Один инлайн-элемент -> StyleNode (или nil для прозрачных). }
function TEpubToFb2Converter.ConvertInlineNode(Elem: TDOMNode; const Name,
  CurrentPath: UnicodeString): TStyleNode;
var
  Href: UnicodeString;
begin
  Result := nil;
  if (Name = 'strong') or (Name = 'b') then
  begin
    Result := TStyleNode.Create('strong');
    TakeNodes(ConvertInline(Elem, CurrentPath), Result.Children);
  end
  else if (Name = 'em') or (Name = 'i') then
  begin
    Result := TStyleNode.Create('emphasis');
    TakeNodes(ConvertInline(Elem, CurrentPath), Result.Children);
  end
  else if Name = 'sub' then
  begin
    Result := TStyleNode.Create('sub');
    TakeNodes(ConvertInline(Elem, CurrentPath), Result.Children);
  end
  else if Name = 'sup' then
  begin
    Result := TStyleNode.Create('sup');
    TakeNodes(ConvertInline(Elem, CurrentPath), Result.Children);
  end
  else if (Name = 'code') or (Name = 'tt') or (Name = 'kbd') or
    (Name = 'samp') or (Name = 'var') then
  begin
    Result := TStyleNode.Create('code');
    TakeNodes(ConvertInline(Elem, CurrentPath), Result.Children);
  end
  else if (Name = 'strike') or (Name = 's') or (Name = 'del') then
  begin
    Result := TStyleNode.Create('strikethrough');
    TakeNodes(ConvertInline(Elem, CurrentPath), Result.Children);
  end
  else if Name = 'a' then
  begin
    Result := TStyleNode.Create('a');
    TakeNodes(ConvertInline(Elem, CurrentPath), Result.Children);
    Href := GetAttr(TDOMElement(Elem), 'href');
    if Href <> '' then
      Result.Href := Href;
  end
  else if Name = 'img' then
  begin
    Href := ResolveImage(GetAttr(TDOMElement(Elem), 'src'), CurrentPath);
    if Href = '' then
      Exit;
    Result := TStyleNode.Create('image');
    Result.ImageHref := Href;
    Result.ImageAlt := GetAttr(TDOMElement(Elem), 'alt');
  end
  else if Name = 'br' then
    Result := TStyleNode.Create(TEXT_NODE_NAME, #10);
end;

end.

{ ===================== TEpubToFb2Converter ===================== }

constructor TEpubToFb2Converter.Create(const DefaultGenre: UnicodeString;
  const ProgramUsed: UnicodeString);
begin
  inherited Create;
  FDefaultGenre := DefaultGenre;
  FProgramUsed := ProgramUsed;
  FMeta := TStringList.Create;
  FMeta.CaseSensitive := True;
  FManifest := TEpubManifestList.Create;
  FPathToId := TStringList.Create;
  FManifestIdMap := TStringList.Create;
  FBinaries := TFb2ObjectList.Create;
  Reset;
end;

destructor TEpubToFb2Converter.Destroy;
begin
  FreeAndNil(FBook);
  FreeAndNil(FZip);
  FreeAndNil(FOppDoc);
  FreeAndNil(FBinaries);
  FreeAndNil(FManifestIdMap);
  FreeAndNil(FPathToId);
  FreeAndNil(FManifest);
  FreeAndNil(FMeta);
  inherited Destroy;
end;

{ Очистить состояние для нового преобразования. }
procedure TEpubToFb2Converter.Reset;
begin
  FreeAndNil(FZip);
  FreeAndNil(FOppDoc);
  FOppDir := '';
  FMeta.Clear;
  FManifest.Clear;
  FPathToId.Clear;
  FManifestIdMap.Clear;
  FBinaries.Clear;
  FImageCounter := 0;
  FCoverHref := '';
end;

function TEpubToFb2Converter.Convert(
  const Source: UnicodeString): TFictionBook;
var
  Root: TDOMElement;
begin
  if Source <> '' then
    FSource := Source;
  if FSource = '' then
    raise EFb2ConversionError.Create('Не задан источник EPUB (Source)');

  FreeAndNil(FBook);
  Reset;
  FZip := TEpubArchive.Create;
  FZip.LoadFromFile(FSource);
  try
    Root := ParseOpf;
    ReadMetadata(Root);
    LoadManifest(Root);
    LoadBinaries;
    DetectCover(Root);
    FBook := Assemble(ConvertSpine(Root));
    Result := FBook;
  finally
    FreeAndNil(FZip);
  end;
end;

function TEpubToFb2Converter.ToXml(Book: TFictionBook): UnicodeString;
var
  W: TFb2Writer;
begin
  if Book = nil then
    Book := FBook;
  if Book = nil then
    Book := Convert('');
  W := TFb2Writer.Create;
  try
    Result := W.ToXML(Book);
  finally
    W.Free;
  end;
end;

function TEpubToFb2Converter.Write(const Source: UnicodeString;
  const Output: UnicodeString): UnicodeString;
var
  Book: TFictionBook;
  Xml: UnicodeString;
  Target: UnicodeString;
begin
  Book := Convert(Source);
  Xml := ToXml(Book);
  if Output <> '' then
    Target := Output
  else if FSource <> '' then
    Target := ChangeFileExt(FSource, '.fb2')
  else
    Target := 'book.fb2';
  WriteFileAtomic(Target, TEncoding.UTF8.GetBytes(Xml));
  Result := Target;
end;
