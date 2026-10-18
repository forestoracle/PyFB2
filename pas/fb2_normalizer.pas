unit fb2_normalizer;
{ Нормализация и авто-исправление FB2-файлов — перевод fb2_normalizer.py.

  Класс TFb2Normalizer приводит произвольный («грязный») FB2 к виду,
  максимально близкому к XSD-схеме FictionBook 2.0. Исправления «мягкие»:
  данные не теряются, добавляется только необходимое.

  Что исправляется:
      * кодировка — приведение к UTF-8 (BOM, XML-декларация, переводы строк,
        недопустимые управляющие символы);
      * структура — порядок дочерних элементов по FictionBook.xsd;
      * обязательные поля — description/title-info/document-info/body/section,
        genre, author, book-title, lang, id, version, date;
      * дубликаты — повторяющиеся <binary> с одинаковым id;
      * пробелы — схлопывание в простых текстовых полях;
      * битые ссылки на изображения (опционально).

  Пример:
      N := TFb2Normalizer.Create;
      try
        Xml := N.Normalize('book.fb2');            { строка XML (UTF-8) }
        N.Write('book.fb2', 'book.fixed.fb2');
        Res := N.Report('book.fb2');
        try ... Res.Fixes ... finally Res.Free; end;
      finally
        N.Free;
      end;

  Особенности перевода с Python:
      * вместо lxml используется fcl-xml (DOM); у него нет режима
        восстановления (recover) — при Recover=True делается повторный разбор
        после экранирования «голых» амперсандов, при неудаче ошибка
        пробрасывается;
      * проверка по XSD недоступна (в fcl-xml нет XSD-валидатора), поэтому
        ValidAfter всегда не определён (как в Python при недоступном
        валидаторе);
      * источники задаются путём к файлу или строкой XML. }

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Classes, SysUtils, fgl, DOM, XMLRead, XMLWrite,
  fb2_structures, fb2_errors, fb2_files, fb2_transcoder;

const
  { Пространство имён FB2. }
  FB2_NS = 'http://www.gribuser.ru/xml/fictionbook/2.0';
  { Пространство имён xlink. }
  XLINK_NS = 'http://www.w3.org/1999/xlink';
  { Расширение FB2-файлов. }
  FB2_MASK = '*.fb2';
  { Путь-заглушка для источника «в памяти». }
  MEMORY_SOURCE = '<memory>';
  { Коды возврата CLI. }
  EXIT_OK = 0;
  EXIT_ERRORS = 1;
  EXIT_USAGE = 2;

type
  { Одно выполненное исправление. }
  TNormalizationFix = class
  public
    Code: UnicodeString;
    Message: UnicodeString;
    constructor Create(const ACode, AMessage: UnicodeString);
    { Текст вида "[code] message". }
    function AsText: UnicodeString;
  end;

  TNormalizationFixList = specialize TFPGObjectList<TNormalizationFix>;

  { Результат нормализации одного файла. }
  TNormalizationResult = class
  public
    Source: UnicodeString;
    Target: UnicodeString;
    Fixes: TNormalizationFixList;
    SourceEncoding: UnicodeString;
    Xml: UnicodeString;
    HasXml: Boolean;
    ValidAfter: Boolean;
    HasValidAfter: Boolean;
    Error: UnicodeString;
    constructor Create;
    destructor Destroy; override;
    { Были ли внесены изменения. }
    function Changed: Boolean;
    { Успешно ли завершилась нормализация. }
    function Ok: Boolean;
  end;

  TNormalizationResultList = specialize TFPGObjectList<TNormalizationResult>;

  { Нормализация и авто-исправление FB2. }
  TFb2Normalizer = class
  private
    FNormalizeEncoding: Boolean;
    FFixOrder: Boolean;
    FFillRequired: Boolean;
    FDropDuplicateBinaries: Boolean;
    FDropBrokenImages: Boolean;
    FCollapseWhitespace: Boolean;
    FStripControlChars: Boolean;
    FRecover: Boolean;
    FPretty: Boolean;
    FDefaultGenre: UnicodeString;
    FDefaultLang: UnicodeString;
    FDefaultTitle: UnicodeString;
    FDefaultAuthor: UnicodeString;
    FProgramUsed: UnicodeString;
    FHasProgramUsed: Boolean;
    FValidate: Boolean;

    function ReadSourceBytes(const Source: UnicodeString): TBytes;
    function Decode(const Data: TBytes; const Encoding: UnicodeString;
      Fixes: TNormalizationFixList): UnicodeString;
    function CleanText(const Text: UnicodeString;
      Fixes: TNormalizationFixList): UnicodeString;
    function ParseXml(const Text: UnicodeString;
      Fixes: TNormalizationFixList): TXMLDocument;
    function Serialize(Doc: TXMLDocument): UnicodeString;
    procedure ApplyFixes(Root: TDOMElement; Fixes: TNormalizationFixList);
    procedure EnsureStructure(Root: TDOMElement; Fixes: TNormalizationFixList);
    procedure EnsureTitleInfo(TitleInfo: TDOMElement;
      Fixes: TNormalizationFixList);
    procedure EnsureDocumentInfo(DocInfo: TDOMElement;
      Fixes: TNormalizationFixList);
    function AppendAuthor(Parent: TDOMElement): TDOMElement;
    procedure ReorderAll(Root: TDOMElement; Fixes: TNormalizationFixList);
    procedure DoDropDuplicateBinaries(Root: TDOMElement;
      Fixes: TNormalizationFixList);
    procedure DoDropBrokenImages(Root: TDOMElement;
      Fixes: TNormalizationFixList);
    procedure DoCollapseWhitespace(Root: TDOMElement;
      Fixes: TNormalizationFixList);
    function NormalizeBytes(const Data: TBytes; Fixes: TNormalizationFixList;
      out Encoding: UnicodeString): TXMLDocument;
  public
    constructor Create(NormalizeEncoding: Boolean = True;
      FixOrder: Boolean = True; FillRequired: Boolean = True;
      DropDuplicateBinaries: Boolean = True;
      DropBrokenImages: Boolean = False;
      CollapseWhitespace: Boolean = True; StripControlChars: Boolean = True;
      Recover: Boolean = True; Pretty: Boolean = True;
      const DefaultGenre: UnicodeString = 'prose';
      const DefaultLang: UnicodeString = 'ru';
      const DefaultTitle: UnicodeString = 'Без названия';
      const DefaultAuthor: UnicodeString = 'Неизвестный автор';
      const ProgramUsed: UnicodeString = ''; Validate: Boolean = False);
    destructor Destroy; override;

    { Нормализованный XML (строка UTF-8). }
    function Normalize(const Source: UnicodeString): UnicodeString;

    { Нормализовать без записи и вернуть отчёт. }
    function Report(const Source: UnicodeString): TNormalizationResult;

    { Нормализовать из байтов (аналог report(bytes) в Python). }
    function ReportBytes(const Data: TBytes;
      const SourcePath: UnicodeString = MEMORY_SOURCE): TNormalizationResult;

    { Нормализовать источник и записать результат в файл. }
    function Write(const Source: UnicodeString;
      const Output: UnicodeString = ''): UnicodeString;

    { Нормализовать один файл (с записью или без). }
    function NormalizeFile(const Path: UnicodeString;
      const Dest: UnicodeString = ''; DryRun: Boolean = False)
      : TNormalizationResult;

    { Нормализовать все *.fb2 каталога (рекурсивно). }
    function NormalizeDir(const Directory: UnicodeString;
      const OutDir: UnicodeString = ''; const Suffix: UnicodeString = '';
      DryRun: Boolean = False): TNormalizationResultList;

    property Pretty: Boolean read FPretty write FPretty;
    property Validate: Boolean read FValidate write FValidate;
  end;

{ Тег — простое текстовое поле (пробелы схлопываются)? }
function IsTextFieldTag(const Name: UnicodeString): Boolean;

{ Есть ли для родителя описание порядка по XSD? }
function HasElementOrder(const ParentName: UnicodeString): Boolean;

{ Позиция ребёнка в порядке XSD; неизвестный ребёнок — «в конец». }
function ChildOrderIndex(const ParentName, ChildName: UnicodeString): Integer;

implementation

{ ===================== Порядок элементов по XSD ===================== }

type
  TOrderEntry = record
    Parent: UnicodeString;
    Children: UnicodeString;   { имена через пробел }
  end;

const
  ELEMENT_ORDER: array[0..17] of TOrderEntry = (
    (Parent: 'FictionBook'; Children: 'stylesheet description body binary'),
    (Parent: 'description'; Children:
      'title-info src-title-info document-info publish-info custom-info output'),
    (Parent: 'title-info'; Children:
      'genre author book-title annotation keywords date coverpage lang ' +
      'src-lang translator sequence'),
    (Parent: 'src-title-info'; Children:
      'genre author book-title annotation keywords date coverpage lang ' +
      'src-lang translator sequence'),
    (Parent: 'document-info'; Children:
      'author program-used date src-url src-ocr id version history'),
    (Parent: 'publish-info'; Children:
      'book-name publisher city year isbn sequence'),
    (Parent: 'body'; Children: 'image title epigraph section'),
    { В секции 'image' — это НЕ только шапочная картинка (слот image?), но и
      блочный контент (иллюстрации между абзацами), поэтому в порядок его не
      включаем: иначе сортировка сдвинула бы ВСЕ картинки в начало секции. }
    (Parent: 'section'; Children: 'title epigraph annotation'),
    (Parent: 'poem'; Children:
      'title epigraph subtitle stanza text-author date'),
    (Parent: 'stanza'; Children: 'title subtitle v'),
    (Parent: 'epigraph'; Children: 'p poem cite empty-line text-author'),
    (Parent: 'cite'; Children: 'p poem empty-line subtitle table text-author'),
    (Parent: 'annotation'; Children: 'p poem cite subtitle table empty-line'),
    (Parent: 'title'; Children: 'p empty-line'),
    (Parent: 'author'; Children:
      'first-name middle-name last-name nickname home-page email id'),
    (Parent: 'coverpage'; Children: 'image'),
    (Parent: 'table'; Children: 'tr'),
    (Parent: 'tr'; Children: 'th td')
  );

  { Простые текстовые поля (textFieldType и аналоги). }
  TEXT_FIELD_TAGS: array[0..15] of UnicodeString = (
    'book-title', 'first-name', 'middle-name', 'last-name', 'nickname',
    'program-used', 'src-ocr', 'book-name', 'publisher', 'city', 'isbn',
    'genre', 'lang', 'src-lang', 'keywords', 'src-url'
  );

function IsTextFieldTag(const Name: UnicodeString): Boolean;
var
  I: Integer;
begin
  for I := Low(TEXT_FIELD_TAGS) to High(TEXT_FIELD_TAGS) do
    if TEXT_FIELD_TAGS[I] = Name then
      Exit(True);
  Result := False;
end;

function HasElementOrder(const ParentName: UnicodeString): Boolean;
var
  I: Integer;
begin
  for I := Low(ELEMENT_ORDER) to High(ELEMENT_ORDER) do
    if ELEMENT_ORDER[I].Parent = ParentName then
      Exit(True);
  Result := False;
end;

function ChildOrderIndex(const ParentName, ChildName: UnicodeString): Integer;
var
  I, K, P, Count: Integer;
  List, Padded, Tok: UnicodeString;
  Found: Boolean;
begin
  Result := 0;
  List := '';
  Found := False;
  for I := Low(ELEMENT_ORDER) to High(ELEMENT_ORDER) do
    if ELEMENT_ORDER[I].Parent = ParentName then
    begin
      List := ELEMENT_ORDER[I].Children;
      Found := True;
      Break;
    end;
  if not Found then
    Exit(0);

  Count := 1;
  for K := 1 to Length(List) do
    if List[K] = ' ' then
      Inc(Count);

  Padded := ' ' + List + ' ';
  Tok := ' ' + ChildName + ' ';
  P := Pos(Tok, Padded);
  if P = 0 then
    Exit(Count);   { неизвестный элемент -> в конец }

  Result := 0;
  for K := 1 to P - 1 do
    if Padded[K] = ' ' then
      Inc(Result);
end;

{ ===================== Строковые помощники ===================== }

{ Локальное имя тега (без префикса и без {uri}). }
function LocName(const AName: UnicodeString): UnicodeString;
var
  P: Integer;
begin
  Result := AName;
  P := LastDelimiter('}', AName);
  if P > 0 then
  begin
    Result := Copy(AName, P + 1, MaxInt);
    Exit;
  end;
  P := LastDelimiter(':', AName);
  if P > 0 then
    Result := Copy(AName, P + 1, MaxInt);
end;

{ Пробельный символ (как \s в Python, включая Unicode-пробелы). }
function IsSpaceU(C: WideChar): Boolean;
var
  U: LongWord;
begin
  U := Ord(C);
  Result := (U = 32) or ((U >= 9) and (U <= 13)) or (U = $85) or (U = $A0) or
    (U = $1680) or ((U >= $2000) and (U <= $200A)) or (U = $2028) or
    (U = $2029) or (U = $202F) or (U = $205F) or (U = $3000);
end;

{ Схлопнуть последовательности пробелов в один и обрезать по краям. }
function CollapseSpaces(const S: UnicodeString): UnicodeString;
var
  I: Integer;
  PrevSpace: Boolean;
  C: WideChar;
begin
  Result := '';
  PrevSpace := True;   { обрезаем ведущие пробелы }
  for I := 1 to Length(S) do
  begin
    C := S[I];
    if IsSpaceU(C) then
    begin
      if not PrevSpace then
      begin
        Result := Result + ' ';
        PrevSpace := True;
      end;
    end
    else
    begin
      Result := Result + C;
      PrevSpace := False;
    end;
  end;
  if (Result <> '') and (Result[Length(Result)] = ' ') then
    Result := Copy(Result, 1, Length(Result) - 1);
end;

{ Удалить недопустимые в XML 1.0 управляющие символы (кроме \t, \n, \r). }
function StripControlChars(const S: UnicodeString): UnicodeString;
var
  I: Integer;
  U: LongWord;
begin
  Result := '';
  for I := 1 to Length(S) do
  begin
    U := Ord(S[I]);
    if (U <= $08) or ((U >= $0B) and (U <= $0C)) or
      ((U >= $0E) and (U <= $1F)) then
      Continue;
    Result := Result + S[I];
  end;
end;

{ Найти подстроку Sub в S, начиная с позиции Start (1-based); 0 — не найдено. }
function FindSub(const Sub, S: UnicodeString; Start: Integer): Integer;
var
  I, J: Integer;
begin
  Result := 0;
  if (Sub = '') or (S = '') then
    Exit;
  for I := Start to Length(S) - Length(Sub) + 1 do
  begin
    J := 1;
    while (J <= Length(Sub)) and (S[I + J - 1] = Sub[J]) do
      Inc(J);
    if J > Length(Sub) then
      Exit(I);
  end;
end;

{ Привести атрибут encoding в XML-декларации к "utf-8". }
function FixEncodingAttr(const Decl: UnicodeString): UnicodeString;
var
  I, J, K, N: Integer;
  Name: UnicodeString;
  Quote: WideChar;
  IsWordStart: Boolean;
begin
  Result := Decl;
  N := Length(Decl);
  I := 1;
  while I + 8 <= N do
  begin
    Name := Copy(Decl, I, 8);
    IsWordStart := (I = 1) or
      not (((Decl[I - 1] >= 'a') and (Decl[I - 1] <= 'z')) or
           ((Decl[I - 1] >= 'A') and (Decl[I - 1] <= 'Z')) or
           ((Decl[I - 1] >= '0') and (Decl[I - 1] <= '9')) or
           (Decl[I - 1] = '_'));
    if (LowerCase(Name) = 'encoding') and IsWordStart then
    begin
      J := I + 8;
      while (J <= N) and IsSpaceU(Decl[J]) do
        Inc(J);
      if (J <= N) and (Decl[J] = '=') then
      begin
        Inc(J);
        while (J <= N) and IsSpaceU(Decl[J]) do
          Inc(J);
        if (J <= N) and ((Decl[J] = '"') or (Decl[J] = '''')) then
        begin
          Quote := Decl[J];
          K := J + 1;
          while (K <= N) and (Decl[K] <> Quote) do
            Inc(K);
          if K <= N then
            Exit(Copy(Decl, 1, I - 1) + 'encoding="utf-8"' +
              Copy(Decl, K + 1, MaxInt));
        end;
      end;
    end;
    Inc(I);
  end;

  { атрибута нет — вставляем перед "?>" }
  K := FindSub('?>', Decl, 1);
  if K > 0 then
    Result := Copy(Decl, 1, K - 1) + ' encoding="utf-8"' +
      Copy(Decl, K, MaxInt);
end;

{ Привести XML-декларацию в начале текста к encoding="utf-8". }
function FixDeclaration(const Text: UnicodeString): UnicodeString;
var
  I, K: Integer;
  Decl, Fixed: UnicodeString;
begin
  Result := Text;
  I := 1;
  while (I <= Length(Text)) and IsSpaceU(Text[I]) do
    Inc(I);
  if Copy(Text, I, 5) <> '<?xml' then
    Exit;
  K := FindSub('?>', Text, I);
  if K = 0 then
    Exit;
  Decl := Copy(Text, I, K - I + 2);
  Fixed := FixEncodingAttr(Decl);
  if Fixed = Decl then
    Exit;
  Result := Copy(Text, 1, I - 1) + Fixed + Copy(Text, K + 2, MaxInt);
end;

{ Экранировать «голые» амперсанды (не сущности и не ссылки). }
function EscapeBareAmpersands(const S: UnicodeString): UnicodeString;
var
  I, J: Integer;
  InCData, InComment, IsEntity: Boolean;
  C: WideChar;
begin
  Result := '';
  InCData := False;
  InComment := False;
  I := 1;
  while I <= Length(S) do
  begin
    C := S[I];
    if not InCData and not InComment and (Copy(S, I, 9) = '<![CDATA[') then
    begin
      InCData := True;
      Result := Result + '<![CDATA[';
      Inc(I, 9);
      Continue;
    end;
    if InCData and (Copy(S, I, 3) = ']]>') then
    begin
      InCData := False;
      Result := Result + ']]>';
      Inc(I, 3);
      Continue;
    end;
    if not InCData and not InComment and (Copy(S, I, 4) = '<!--') then
    begin
      InComment := True;
      Result := Result + '<!--';
      Inc(I, 4);
      Continue;
    end;
    if InComment and (Copy(S, I, 3) = '-->') then
    begin
      InComment := False;
      Result := Result + '-->';
      Inc(I, 3);
      Continue;
    end;

    if (C = '&') and not InCData and not InComment then
    begin
      IsEntity := False;
      J := I + 1;
      if (J <= Length(S)) and (S[J] = '#') then
      begin
        Inc(J);
        if (J <= Length(S)) and ((S[J] = 'x') or (S[J] = 'X')) then
          Inc(J);
        while (J <= Length(S)) and (S[J] >= '0') and (S[J] <= '9') do
          Inc(J);
      end
      else
        while (J <= Length(S)) and
          (((S[J] >= 'a') and (S[J] <= 'z')) or
           ((S[J] >= 'A') and (S[J] <= 'Z')) or
           ((S[J] >= '0') and (S[J] <= '9')) or (S[J] = '_')) do
          Inc(J);
      if (J > I + 1) and (J <= Length(S)) and (S[J] = ';') then
        IsEntity := True;
      if IsEntity then
        Result := Result + '&'
      else
        Result := Result + '&amp;';
      Inc(I);
      Continue;
    end;

    Result := Result + C;
    Inc(I);
  end;
end;

{ ===================== Помощники DOM ===================== }

{ Текст элемента (конкатенация текстовых детей; для простых полей это
  совпадает с element.text в lxml). }
function ElText(El: TDOMElement): UnicodeString;
var
  N: TDOMNode;
begin
  Result := '';
  if El = nil then
    Exit;
  N := El.FirstChild;
  while N <> nil do
  begin
    if N.NodeType = TEXT_NODE then
      Result := Result + UnicodeString(N.NodeValue);
    N := N.NextSibling;
  end;
end;

{ Заменить текст элемента одним текстовым узлом. }
procedure SetElText(Doc: TXMLDocument; El: TDOMElement;
  const S: UnicodeString);
var
  N, Next: TDOMNode;
begin
  if El = nil then
    Exit;
  N := El.FirstChild;
  while N <> nil do
  begin
    Next := N.NextSibling;
    if N.NodeType = TEXT_NODE then
    begin
      El.RemoveChild(N);
      N.Free;
    end;
    N := Next;
  end;
  if S <> '' then
    El.AppendChild(Doc.CreateTextNode(S));
end;

{ Первый дочерний элемент с заданным локальным именем. }
function FindChildEl(Parent: TDOMNode; const AName: UnicodeString): TDOMElement;
var
  N: TDOMNode;
begin
  Result := nil;
  if Parent = nil then
    Exit;
  N := Parent.FirstChild;
  while N <> nil do
  begin
    if (N.NodeType = ELEMENT_NODE) and (LocName(N.NodeName) = AName) then
      Exit(TDOMElement(N));
    N := N.NextSibling;
  end;
end;

{ Все дочерние элементы с заданным локальным именем. }
procedure CollectChildEls(Parent: TDOMNode; const AName: UnicodeString;
  List: TList);
var
  N: TDOMNode;
begin
  if Parent = nil then
    Exit;
  N := Parent.FirstChild;
  while N <> nil do
  begin
    if (N.NodeType = ELEMENT_NODE) and (LocName(N.NodeName) = AName) then
      List.Add(N);
    N := N.NextSibling;
  end;
end;

{ Все элементы-потомки (включая сам Node) с заданным именем. }
procedure CollectByTag(Node: TDOMNode; const AName: UnicodeString; List: TList);
var
  N: TDOMNode;
begin
  if Node = nil then
    Exit;
  if (Node.NodeType = ELEMENT_NODE) and (LocName(Node.NodeName) = AName) then
    List.Add(Node);
  N := Node.FirstChild;
  while N <> nil do
  begin
    CollectByTag(N, AName, List);
    N := N.NextSibling;
  end;
end;

{ Все элементы-потомки (включая сам Node). }
procedure CollectAllElements(Node: TDOMNode; List: TList);
var
  N: TDOMNode;
begin
  if Node = nil then
    Exit;
  if Node.NodeType = ELEMENT_NODE then
    List.Add(Node);
  N := Node.FirstChild;
  while N <> nil do
  begin
    CollectAllElements(N, List);
    N := N.NextSibling;
  end;
end;

{ Создать дочерний элемент. Если пространство имён NS объявлено в корне
  как пространство по умолчанию, элемент создаётся БЕЗ явного NS — тогда
  он наследует xmlns корня (как lxml в Python) и лишний xmlns не выводится. }
function CreateSubEl(Doc: TXMLDocument; Parent: TDOMElement;
  const NS, AName: UnicodeString): TDOMElement;
var
  Root: TDOMElement;
begin
  Root := nil;
  if Doc.DocumentElement <> nil then
    Root := TDOMElement(Doc.DocumentElement);
  if (NS <> '') and
    ((Root = nil) or (UnicodeString(Root.GetAttribute('xmlns')) <> NS)) then
    Result := Doc.CreateElementNS(NS, AName)
  else
    Result := Doc.CreateElement(AName);
  Parent.AppendChild(Result);
end;

{ URI пространства имён корневого элемента ('' — нет). }
function NamespaceOf(Root: TDOMElement): UnicodeString;
begin
  Result := '';
  if Root = nil then
    Exit;
  Result := UnicodeString(Root.NamespaceURI);
  if Result <> '' then
    Exit;
  Result := UnicodeString(Root.GetAttribute('xmlns'));
end;

{ ===================== Сериализация ===================== }

{ Сериализовать документ в строку. Форматирование выполняет писатель
  fcl-xml (2 пробела при Pretty, иначе без отступов), переводы строк — LF. }
function DomToString(Doc: TXMLDocument; APretty: Boolean): UnicodeString;
var
  Mem: TMemoryStream;
  W: TDOMWriter;
  Bytes: TBytes;
  Raw: RawByteString;
begin
  Mem := TMemoryStream.Create;
  try
    W := TDOMWriter.Create(Mem, Doc);
    try
      if APretty then
        W.IndentSize := 2
      else
        W.IndentSize := 0;
      W.LineBreak := #10;
      W.WriteNode(Doc);
    finally
      W.Free;
    end;
    SetLength(Bytes, Mem.Size);
    if Mem.Size > 0 then
      Move(Mem.Memory^, Bytes[0], Mem.Size);
  finally
    Mem.Free;
  end;
  SetLength(Raw, Length(Bytes));
  if Length(Bytes) > 0 then
    Move(Bytes[0], Raw[1], Length(Bytes));
  Result := UTF8Decode(Raw);
end;

{ Отбросить XML-декларацию в начале строки. }
function StripXmlDeclaration(const S: UnicodeString): UnicodeString;
var
  I, K: Integer;
begin
  Result := S;
  I := 1;
  while (I <= Length(S)) and IsSpaceU(S[I]) do
    Inc(I);
  if Copy(S, I, 5) <> '<?xml' then
    Exit;
  K := FindSub('?>', S, I);
  if K = 0 then
    Exit;
  Result := Copy(S, K + 2, MaxInt);
end;

{ Удалить текстовые узлы из одних пробелов (аналог remove_blank_text). }
procedure RemoveBlankTextNodes(Node: TDOMNode);
var
  N, Next: TDOMNode;
begin
  if Node = nil then
    Exit;
  N := Node.FirstChild;
  while N <> nil do
  begin
    Next := N.NextSibling;
    if N.NodeType = TEXT_NODE then
    begin
      if Trim(UnicodeString(N.NodeValue)) = '' then
      begin
        Node.RemoveChild(N);
        N.Free;
      end;
    end
    else if N.NodeType = ELEMENT_NODE then
      RemoveBlankTextNodes(N);
    N := Next;
  end;
end;

{ Примечание: отступы вывода расставляет писатель fcl-xml (см. DomToString),
  поэтому собственный pretty-printer не нужен. }

{ ===================== TNormalizationFix ===================== }

constructor TNormalizationFix.Create(const ACode, AMessage: UnicodeString);
begin
  inherited Create;
  Code := ACode;
  Message := AMessage;
end;

function TNormalizationFix.AsText: UnicodeString;
begin
  Result := '[' + Code + '] ' + Message;
end;

{ ===================== TNormalizationResult ===================== }

constructor TNormalizationResult.Create;
begin
  inherited Create;
  Fixes := TNormalizationFixList.Create;
end;

destructor TNormalizationResult.Destroy;
begin
  FreeAndNil(Fixes);
  inherited Destroy;
end;

function TNormalizationResult.Changed: Boolean;
begin
  Result := Fixes.Count > 0;
end;

function TNormalizationResult.Ok: Boolean;
begin
  Result := Error = '';
end;

{ ===================== TFb2Normalizer ===================== }

constructor TFb2Normalizer.Create(NormalizeEncoding: Boolean;
  FixOrder: Boolean; FillRequired: Boolean; DropDuplicateBinaries: Boolean;
  DropBrokenImages: Boolean; CollapseWhitespace: Boolean;
  StripControlChars: Boolean; Recover: Boolean; Pretty: Boolean;
  const DefaultGenre, DefaultLang, DefaultTitle, DefaultAuthor: UnicodeString;
  const ProgramUsed: UnicodeString; Validate: Boolean);
begin
  inherited Create;
  FNormalizeEncoding := NormalizeEncoding;
  FFixOrder := FixOrder;
  FFillRequired := FillRequired;
  FDropDuplicateBinaries := DropDuplicateBinaries;
  FDropBrokenImages := DropBrokenImages;
  FCollapseWhitespace := CollapseWhitespace;
  FStripControlChars := StripControlChars;
  FRecover := Recover;
  FPretty := Pretty;
  FDefaultGenre := DefaultGenre;
  FDefaultLang := DefaultLang;
  FDefaultTitle := DefaultTitle;
  FDefaultAuthor := DefaultAuthor;
  FProgramUsed := ProgramUsed;
  FHasProgramUsed := ProgramUsed <> '';
  FValidate := Validate;
end;

destructor TFb2Normalizer.Destroy;
begin
  inherited Destroy;
end;

{ Источник -> байты: файл читается, строка кодируется в UTF-8. }
function TFb2Normalizer.ReadSourceBytes(const Source: UnicodeString): TBytes;
begin
  if FileExists(Source) then
    Result := ReadFileBytes(Source)
  else
    Result := TEncoding.UTF8.GetBytes(Source);
end;

{ Декодировать байты в текст (с удалением BOM UTF-8). }
function TFb2Normalizer.Decode(const Data: TBytes;
  const Encoding: UnicodeString; Fixes: TNormalizationFixList): UnicodeString;
var
  Payload: TBytes;
  Enc: TEncoding;
  Raw: RawByteString;
  Norm: UnicodeString;
begin
  Payload := Data;
  if (Length(Payload) >= 3) and (Payload[0] = $EF) and (Payload[1] = $BB) and
    (Payload[2] = $BF) then
  begin
    Payload := Copy(Payload, 3, MaxInt);
    Fixes.Add(TNormalizationFix.Create('bom-removed', 'удалён BOM UTF-8'));
  end;

  Enc := EncodingByName(Encoding);
  try
    Result := Enc.GetString(Payload);
  except
    on E: Exception do
    begin
      { аналог errors="replace": конвертация через кодовую страницу }
      SetLength(Raw, Length(Payload));
      if Length(Payload) > 0 then
        Move(Payload[0], Raw[1], Length(Payload));
      SetCodePage(Raw, Enc.CodePage, False);
      Result := UnicodeString(Raw);
      Fixes.Add(TNormalizationFix.Create('decode-replaced',
        'часть байтов заменена при декодировании ' + Encoding));
    end;
  end;

  Norm := NormalizeEnc(Encoding);
  if FNormalizeEncoding and (Norm <> 'utf-8') and (Norm <> 'utf8') then
    Fixes.Add(TNormalizationFix.Create('encoding-fixed',
      'кодировка ' + Encoding + ' -> utf-8'));
end;

{ Нормализовать переводы строк, BOM и управляющие символы. }
function TFb2Normalizer.CleanText(const Text: UnicodeString;
  Fixes: TNormalizationFixList): UnicodeString;
var
  T, Cleaned: UnicodeString;
begin
  T := Text;
  if (Length(T) > 0) and (T[1] = #$FEFF) then
  begin
    T := Copy(T, 2, MaxInt);
    Fixes.Add(TNormalizationFix.Create('bom-removed',
      'удалён BOM в начале текста'));
  end;

  if Pos(#13, T) > 0 then
  begin
    T := UReplace(T, #13#10, #10);
    T := UReplace(T, #13, #10);
    Fixes.Add(TNormalizationFix.Create('newlines-normalized',
      'переводы строк приведены к LF'));
  end;

  if FStripControlChars then
  begin
    Cleaned := StripControlChars(T);
    if Cleaned <> T then
    begin
      T := Cleaned;
      Fixes.Add(TNormalizationFix.Create('control-chars-removed',
        'удалены недопустимые управляющие символы'));
    end;
  end;

  Result := FixDeclaration(T);
end;

{ Разобрать XML (при Recover — повторная попытка после ремонта). }
function TFb2Normalizer.ParseXml(const Text: UnicodeString;
  Fixes: TNormalizationFixList): TXMLDocument;
var
  Mem: TMemoryStream;
  Doc: TXMLDocument;
  Repaired: UnicodeString;

  function TryRead(const S: UnicodeString; out D: TXMLDocument): Boolean;
  var
    B: TBytes;
  begin
    D := nil;
    B := TEncoding.UTF8.GetBytes(S);
    Mem.Size := 0;
    if Length(B) > 0 then
      Mem.WriteBuffer(B[0], Length(B));
    Mem.Position := 0;
    try
      ReadXMLFile(D, Mem);
      Result := D <> nil;
    except
      on E: Exception do
      begin
        if D <> nil then
          FreeAndNil(D);
        Result := False;
      end;
    end;
  end;

begin
  Result := nil;
  Mem := TMemoryStream.Create;
  try
    if TryRead(Text, Doc) then
      Exit(Doc);
    if not FRecover then
      raise EFb2ParseError.Create('Не удалось разобрать XML');
    Repaired := EscapeBareAmpersands(Text);
    if (Repaired <> Text) and TryRead(Repaired, Doc) then
    begin
      Fixes.Add(TNormalizationFix.Create('recovered',
        'XML восстановлен после экранирования амперсандов'));
      Exit(Doc);
    end;
    raise EFb2ParseError.Create(
      'Не удалось разобрать XML (восстановление не помогло)');
  finally
    Mem.Free;
  end;
end;

{ Сериализовать дерево в строку XML с декларацией UTF-8. }
function TFb2Normalizer.Serialize(Doc: TXMLDocument): UnicodeString;
var
  Body: UnicodeString;
begin
  if FPretty and (Doc.DocumentElement <> nil) then
    RemoveBlankTextNodes(Doc.DocumentElement);
  Body := Trim(StripXmlDeclaration(DomToString(Doc, FPretty)));
  Result := '<?xml version="1.0" encoding="utf-8"?>' + #10 + Body + #10;
end;

{ Байты -> нормализованное дерево. }
function TFb2Normalizer.NormalizeBytes(const Data: TBytes;
  Fixes: TNormalizationFixList; out Encoding: UnicodeString): TXMLDocument;
var
  Text: UnicodeString;
  Root: TDOMElement;
begin
  Encoding := DetectEncodingOf(Data);
  Text := Decode(Data, Encoding, Fixes);
  Text := CleanText(Text, Fixes);
  Result := ParseXml(Text, Fixes);
  Root := Result.DocumentElement;
  if Root <> nil then
    ApplyFixes(Root, Fixes);
end;

function TFb2Normalizer.ReportBytes(const Data: TBytes;
  const SourcePath: UnicodeString): TNormalizationResult;
var
  Fixes: TNormalizationFixList;
  Doc: TXMLDocument;
  Encoding: UnicodeString;
begin
  Result := TNormalizationResult.Create;
  Result.Source := SourcePath;
  Fixes := TNormalizationFixList.Create;
  Doc := nil;
  try
    try
      Doc := NormalizeBytes(Data, Fixes, Encoding);
      Result.Xml := Serialize(Doc);
      Result.HasXml := True;
      Result.SourceEncoding := Encoding;
      while Fixes.Count > 0 do
        Result.Fixes.Add(Fixes.Extract(Fixes[0]));
    except
      on E: Exception do
        Result.Error := E.Message;
    end;
  finally
    Doc.Free;
    Fixes.Free;
  end;
  { Проверка по XSD: в fcl-xml нет валидатора, поэтому ValidAfter остаётся
    неопределённым — как в Python при недоступном Fb2Validator. }
end;

function TFb2Normalizer.Report(const Source: UnicodeString): TNormalizationResult;
var
  Path: UnicodeString;
begin
  if FileExists(Source) then
    Path := Source
  else
    Path := MEMORY_SOURCE;
  Result := ReportBytes(ReadSourceBytes(Source), Path);
end;

function TFb2Normalizer.Normalize(const Source: UnicodeString): UnicodeString;
var
  R: TNormalizationResult;
begin
  Result := '';
  R := Report(Source);
  try
    if R.Error <> '' then
      raise EFb2ConversionError.Create(R.Error);
    if R.HasXml then
      Result := R.Xml;
  finally
    R.Free;
  end;
end;

function TFb2Normalizer.Write(const Source: UnicodeString;
  const Output: UnicodeString): UnicodeString;
var
  R: TNormalizationResult;
  Target: UnicodeString;
begin
  R := Report(Source);
  try
    if R.Error <> '' then
      raise EFb2ConversionError.Create(R.Error);
    if Output <> '' then
      Target := Output
    else if FileExists(Source) then
      Target := ChangeFileExt(Source, '.fb2')
    else
      Target := 'book.fb2';
    WriteFileAtomic(Target, TEncoding.UTF8.GetBytes(R.Xml));
    Result := Target;
  finally
    R.Free;
  end;
end;

function TFb2Normalizer.NormalizeFile(const Path: UnicodeString;
  const Dest: UnicodeString; DryRun: Boolean): TNormalizationResult;
var
  Data: TBytes;
  Target: UnicodeString;
begin
  try
    Data := ReadFileBytes(Path);
  except
    on E: Exception do
    begin
      Result := TNormalizationResult.Create;
      Result.Source := Path;
      Result.Error := 'Не удалось прочитать: ' + E.Message;
      Exit;
    end;
  end;

  Result := ReportBytes(Data, Path);
  if Result.Error <> '' then
    Exit;

  if Dest <> '' then
    Target := Dest
  else
    Target := Path;
  Result.Target := Target;
  if DryRun then
    Exit;

  try
    WriteFileAtomic(Target, TEncoding.UTF8.GetBytes(Result.Xml));
  except
    on E: Exception do
      Result.Error := 'Не удалось записать: ' + E.Message;
  end;
end;

function TFb2Normalizer.NormalizeDir(const Directory, OutDir,
  Suffix: UnicodeString; DryRun: Boolean): TNormalizationResultList;
var
  Files: TStringList;
  I: Integer;
  Dest, Rel, Stem, Ext: UnicodeString;
begin
  Result := TNormalizationResultList.Create;
  Files := ListFilesRecursive(Directory, FB2_MASK);
  try
    for I := 0 to Files.Count - 1 do
    begin
      Dest := '';
      if (OutDir <> '') or (Suffix <> '') then
      begin
        Rel := RelPath(Directory, Files[I]);
        if Suffix <> '' then
        begin
          Stem := ChangeFileExt(ExtractFileName(Rel), '');
          Ext := ExtractFileExt(Rel);
          if ExtractFileDir(Rel) = '' then
            Rel := Stem + Suffix + Ext
          else
            Rel := ExtractFileDir(Rel) + PathDelim + Stem + Suffix + Ext;
        end;
        if OutDir <> '' then
          Dest := IncludeTrailingPathDelimiter(OutDir) + Rel
        else
          Dest := ExtractFilePath(Files[I]) + ExtractFileName(Rel);
      end;
      Result.Add(NormalizeFile(Files[I], Dest, DryRun));
    end;
  finally
    Files.Free;
  end;
end;

{ ===================== Исправления структуры ===================== }

{ Новый идентификатор (urn:uuid). }
function MakeUrnUuid: UnicodeString;
var
  G: TGUID;
  S: UnicodeString;
  I: Integer;
begin
  CreateGUID(G);
  S := GUIDToString(G);
  if (Length(S) >= 2) and (S[1] = '{') then
    S := Copy(S, 2, Length(S) - 2);
  for I := 1 to Length(S) do
    if (S[I] >= 'A') and (S[I] <= 'Z') then
      S[I] := WideChar(Ord(S[I]) + 32);
  Result := 'urn:uuid:' + S;
end;

{ Пространство имён корня документа. }
function RootNS(El: TDOMElement): UnicodeString;
var
  D: TDOMDocument;
begin
  Result := '';
  if El = nil then
    Exit;
  D := El.OwnerDocument;
  if (D <> nil) and (D.DocumentElement <> nil) then
    Result := NamespaceOf(TDOMElement(D.DocumentElement));
end;

{ xlink:href элемента. }
function GetXlinkHref(El: TDOMElement): UnicodeString;
begin
  Result := '';
  if El = nil then
    Exit;
  Result := UnicodeString(El.GetAttribute('xlink:href'));
  if Result = '' then
    Result := UnicodeString(El.GetAttribute('href'));
end;

{ Удалить элемент из дерева (текст после него остаётся на месте). }
procedure RemoveElement(El: TDOMElement);
var
  Parent: TDOMNode;
begin
  if El = nil then
    Exit;
  Parent := El.ParentNode;
  if Parent = nil then
    Exit;
  Parent.RemoveChild(El);
  El.Free;
end;

procedure TFb2Normalizer.ApplyFixes(Root: TDOMElement;
  Fixes: TNormalizationFixList);
begin
  if FFillRequired then
    EnsureStructure(Root, Fixes);
  if FDropDuplicateBinaries then
    DoDropDuplicateBinaries(Root, Fixes);
  if FDropBrokenImages then
    DoDropBrokenImages(Root, Fixes);
  if FCollapseWhitespace then
    DoCollapseWhitespace(Root, Fixes);
  if FFixOrder then
    ReorderAll(Root, Fixes);
end;

procedure TFb2Normalizer.EnsureStructure(Root: TDOMElement;
  Fixes: TNormalizationFixList);
var
  Doc: TXMLDocument;
  NS: UnicodeString;
  Description, TitleInfo, DocInfo, Body: TDOMElement;
  Bodies: TList;
  I: Integer;
begin
  Doc := TXMLDocument(Root.OwnerDocument);
  NS := NamespaceOf(Root);

  Description := FindChildEl(Root, 'description');
  if Description = nil then
  begin
    Description := CreateSubEl(Doc, Root, NS, 'description');
    { как в Python: root.insert(0, description) }
    Root.RemoveChild(Description);
    Root.InsertBefore(Description, Root.FirstChild);
    Fixes.Add(TNormalizationFix.Create('added-description',
      'добавлен <description>'));
  end;

  TitleInfo := FindChildEl(Description, 'title-info');
  if TitleInfo = nil then
  begin
    TitleInfo := CreateSubEl(Doc, Description, NS, 'title-info');
    Fixes.Add(TNormalizationFix.Create('added-title-info',
      'добавлен <title-info>'));
  end;
  EnsureTitleInfo(TitleInfo, Fixes);

  DocInfo := FindChildEl(Description, 'document-info');
  if DocInfo = nil then
  begin
    DocInfo := CreateSubEl(Doc, Description, NS, 'document-info');
    Fixes.Add(TNormalizationFix.Create('added-document-info',
      'добавлен <document-info>'));
  end;
  EnsureDocumentInfo(DocInfo, Fixes);

  Bodies := TList.Create;
  try
    CollectChildEls(Root, 'body', Bodies);
    if Bodies.Count = 0 then
    begin
      Body := CreateSubEl(Doc, Root, NS, 'body');
      CreateSubEl(Doc, Body, NS, 'section');
      Fixes.Add(TNormalizationFix.Create('added-body',
        'добавлены <body> и <section>'));
      Bodies.Add(Body);
    end;
    for I := 0 to Bodies.Count - 1 do
    begin
      Body := TDOMElement(Bodies[I]);
      if FindChildEl(Body, 'section') = nil then
      begin
        CreateSubEl(Doc, Body, NS, 'section');
        Fixes.Add(TNormalizationFix.Create('added-section',
          'добавлена пустая <section>'));
      end;
    end;
  finally
    Bodies.Free;
  end;
end;

procedure TFb2Normalizer.EnsureTitleInfo(TitleInfo: TDOMElement;
  Fixes: TNormalizationFixList);
var
  Doc: TXMLDocument;
  NS: UnicodeString;
  El: TDOMElement;
begin
  Doc := TXMLDocument(TitleInfo.OwnerDocument);
  NS := RootNS(TitleInfo);

  if FindChildEl(TitleInfo, 'genre') = nil then
  begin
    El := CreateSubEl(Doc, TitleInfo, NS, 'genre');
    SetElText(Doc, El, FDefaultGenre);
    Fixes.Add(TNormalizationFix.Create('added-genre',
      'добавлен <genre>' + FDefaultGenre + '</genre>'));
  end;

  if FindChildEl(TitleInfo, 'author') = nil then
  begin
    AppendAuthor(TitleInfo);
    Fixes.Add(TNormalizationFix.Create('added-author',
      'добавлен <author><nickname>' + FDefaultAuthor + '</nickname></author>'));
  end;

  if FindChildEl(TitleInfo, 'book-title') = nil then
  begin
    El := CreateSubEl(Doc, TitleInfo, NS, 'book-title');
    SetElText(Doc, El, FDefaultTitle);
    Fixes.Add(TNormalizationFix.Create('added-book-title',
      'добавлен <book-title>' + FDefaultTitle + '</book-title>'));
  end;

  if FindChildEl(TitleInfo, 'lang') = nil then
  begin
    El := CreateSubEl(Doc, TitleInfo, NS, 'lang');
    SetElText(Doc, El, FDefaultLang);
    Fixes.Add(TNormalizationFix.Create('added-lang',
      'добавлен <lang>' + FDefaultLang + '</lang>'));
  end;
end;

procedure TFb2Normalizer.EnsureDocumentInfo(DocInfo: TDOMElement;
  Fixes: TNormalizationFixList);
var
  Doc: TXMLDocument;
  NS: UnicodeString;
  El: TDOMElement;
begin
  Doc := TXMLDocument(DocInfo.OwnerDocument);
  NS := RootNS(DocInfo);

  if FindChildEl(DocInfo, 'author') = nil then
  begin
    AppendAuthor(DocInfo);
    Fixes.Add(TNormalizationFix.Create('added-document-author',
      'добавлен <author> в <document-info>'));
  end;

  if FHasProgramUsed and (FindChildEl(DocInfo, 'program-used') = nil) then
  begin
    El := CreateSubEl(Doc, DocInfo, NS, 'program-used');
    SetElText(Doc, El, FProgramUsed);
    Fixes.Add(TNormalizationFix.Create('added-program-used',
      'добавлен <program-used>' + FProgramUsed + '</program-used>'));
  end;

  if FindChildEl(DocInfo, 'date') = nil then
  begin
    El := CreateSubEl(Doc, DocInfo, NS, 'date');
    SetElText(Doc, El, FormatDateTime('yyyy-mm-dd', Date));
    Fixes.Add(TNormalizationFix.Create('added-document-date',
      'добавлен <date> в <document-info>'));
  end;

  if FindChildEl(DocInfo, 'id') = nil then
  begin
    El := CreateSubEl(Doc, DocInfo, NS, 'id');
    SetElText(Doc, El, MakeUrnUuid);
    Fixes.Add(TNormalizationFix.Create('added-document-id',
      'добавлен <id> (urn:uuid)'));
  end;

  if FindChildEl(DocInfo, 'version') = nil then
  begin
    El := CreateSubEl(Doc, DocInfo, NS, 'version');
    SetElText(Doc, El, '1.0');
    Fixes.Add(TNormalizationFix.Create('added-document-version',
      'добавлен <version>1.0</version>'));
  end;
end;

function TFb2Normalizer.AppendAuthor(Parent: TDOMElement): TDOMElement;
var
  Doc: TXMLDocument;
  NS: UnicodeString;
  Nick: TDOMElement;
begin
  Doc := TXMLDocument(Parent.OwnerDocument);
  NS := RootNS(Parent);
  Result := CreateSubEl(Doc, Parent, NS, 'author');
  Nick := CreateSubEl(Doc, Result, NS, 'nickname');
  SetElText(Doc, Nick, FDefaultAuthor);
end;

procedure TFb2Normalizer.ReorderAll(Root: TDOMElement;
  Fixes: TNormalizationFixList);
var
  All: TList;
  Changed: TStringList;
  I, J, K, N, Tmp: Integer;
  Parent, NodeTmp, E: TDOMElement;
  N2, Next2: TDOMNode;
  Name, Joined: UnicodeString;
  Keys: array of Integer;
  Nodes: array of TDOMElement;
  Sorted: Boolean;
begin
  All := TList.Create;
  Changed := TStringList.Create;
  Changed.Sorted := True;
  Changed.Duplicates := dupIgnore;
  Joined := '';
  try
    CollectAllElements(Root, All);
    for I := 0 to All.Count - 1 do
    begin
      Parent := TDOMElement(All[I]);
      Name := LocName(Parent.NodeName);
      if not HasElementOrder(Name) then
        Continue;

      N := 0;
      N2 := Parent.FirstChild;
      while N2 <> nil do
      begin
        if N2.NodeType = ELEMENT_NODE then
          Inc(N);
        N2 := N2.NextSibling;
      end;
      if N < 2 then
        Continue;

      SetLength(Nodes, N);
      SetLength(Keys, N);
      J := 0;
      N2 := Parent.FirstChild;
      while N2 <> nil do
      begin
        if N2.NodeType = ELEMENT_NODE then
        begin
          E := TDOMElement(N2);
          Nodes[J] := E;
          Keys[J] := ChildOrderIndex(Name, LocName(E.NodeName));
          Inc(J);
        end;
        N2 := N2.NextSibling;
      end;

      Sorted := True;
      for J := 1 to N - 1 do
        if Keys[J] < Keys[J - 1] then
        begin
          Sorted := False;
          Break;
        end;
      if Sorted then
        Continue;

      { устойчивая сортировка вставками по (ключ, исходный индекс) }
      for J := 1 to N - 1 do
      begin
        Tmp := Keys[J];
        NodeTmp := Nodes[J];
        K := J - 1;
        while (K >= 0) and (Keys[K] > Tmp) do
        begin
          Keys[K + 1] := Keys[K];
          Nodes[K + 1] := Nodes[K];
          Dec(K);
        end;
        Keys[K + 1] := Tmp;
        Nodes[K + 1] := NodeTmp;
      end;

      { убрать незначащие пробелы между элементами: lxml при remove()
        отбрасывает tail, поэтому и здесь пробелы не сохраняются }
      N2 := Parent.FirstChild;
      while N2 <> nil do
      begin
        Next2 := N2.NextSibling;
        if (N2.NodeType = TEXT_NODE) and
          (Trim(UnicodeString(N2.NodeValue)) = '') then
        begin
          Parent.RemoveChild(N2);
          N2.Free;
        end;
        N2 := Next2;
      end;

      for J := 0 to N - 1 do
        Parent.RemoveChild(Nodes[J]);
      for J := 0 to N - 1 do
        Parent.AppendChild(Nodes[J]);

      Changed.Add(Name);
    end;

    for I := 0 to Changed.Count - 1 do
    begin
      if I > 0 then
        Joined := Joined + ', ';
      Joined := Joined + Changed[I];
    end;
  finally
    All.Free;
    Changed.Free;
  end;

  if Joined <> '' then
    Fixes.Add(TNormalizationFix.Create('reordered',
      'исправлен порядок элементов: ' + Joined));
end;

procedure TFb2Normalizer.DoDropDuplicateBinaries(Root: TDOMElement;
  Fixes: TNormalizationFixList);
var
  List: TList;
  Seen: TStringList;
  I, Removed: Integer;
  Bin: TDOMElement;
  Id: UnicodeString;
begin
  List := TList.Create;
  Seen := TStringList.Create;
  Seen.Sorted := True;
  Seen.Duplicates := dupIgnore;
  Removed := 0;
  try
    CollectByTag(Root, 'binary', List);
    for I := 0 to List.Count - 1 do
    begin
      Bin := TDOMElement(List[I]);
      Id := UnicodeString(Bin.GetAttribute('id'));
      if Id = '' then
        Continue;
      if Seen.IndexOf(Id) >= 0 then
      begin
        RemoveElement(Bin);
        Inc(Removed);
      end
      else
        Seen.Add(Id);
    end;
  finally
    List.Free;
    Seen.Free;
  end;
  if Removed > 0 then
    Fixes.Add(TNormalizationFix.Create('duplicate-binary-removed',
      'удалено дубликатов <binary>: ' + IntToStr(Removed)));
end;

procedure TFb2Normalizer.DoDropBrokenImages(Root: TDOMElement;
  Fixes: TNormalizationFixList);
var
  Bins, Images: TList;
  Available: TStringList;
  I, Removed: Integer;
  Href: UnicodeString;
begin
  Bins := TList.Create;
  Images := TList.Create;
  Available := TStringList.Create;
  Available.Sorted := True;
  Available.Duplicates := dupIgnore;
  Removed := 0;
  try
    CollectByTag(Root, 'binary', Bins);
    for I := 0 to Bins.Count - 1 do
    begin
      Href := UnicodeString(TDOMElement(Bins[I]).GetAttribute('id'));
      if Href <> '' then
        Available.Add(Href);
    end;

    CollectByTag(Root, 'image', Images);
    for I := 0 to Images.Count - 1 do
    begin
      Href := GetXlinkHref(TDOMElement(Images[I]));
      if (Href = '') or (Href[1] <> '#') or
        (Available.IndexOf(Copy(Href, 2, MaxInt)) >= 0) then
        Continue;
      if TDOMElement(Images[I]).ParentNode = nil then
        Continue;
      RemoveElement(TDOMElement(Images[I]));
      Inc(Removed);
    end;
  finally
    Bins.Free;
    Images.Free;
    Available.Free;
  end;
  if Removed > 0 then
    Fixes.Add(TNormalizationFix.Create('broken-image-removed',
      'удалено <image> без <binary>: ' + IntToStr(Removed)));
end;

procedure TFb2Normalizer.DoCollapseWhitespace(Root: TDOMElement;
  Fixes: TNormalizationFixList);
var
  All: TList;
  I, Changed: Integer;
  El: TDOMElement;
  T, C: UnicodeString;
begin
  All := TList.Create;
  Changed := 0;
  try
    CollectAllElements(Root, All);
    for I := 0 to All.Count - 1 do
    begin
      El := TDOMElement(All[I]);
      if not IsTextFieldTag(LocName(El.NodeName)) then
        Continue;
      T := ElText(El);
      if T = '' then
        Continue;
      C := CollapseSpaces(T);
      if C <> T then
      begin
        SetElText(TXMLDocument(El.OwnerDocument), El, C);
        Inc(Changed);
      end;
    end;
  finally
    All.Free;
  end;
  if Changed > 0 then
    Fixes.Add(TNormalizationFix.Create('whitespace-collapsed',
      'нормализованы пробелы в полях: ' + IntToStr(Changed)));
end;

end.
