unit html_to_fb2;
{ Преобразование HTML в FictionBook (FB2) — перевод html_to_fb2.py.

  Класс THtmlToFb2Converter читает HTML-документ (в формате fb2_to_html либо
  произвольный) и собирает из него структуры FB2, после чего сериализует их в
  XML FictionBook 2.0 (через TFb2Writer).

  Что поддерживается:
      * <header class="book-header"> -> заголовок, автор, жанры, обложка,
        аннотация;
      * <h1>-<h6> (с id-якорями) -> иерархия <section>/<title>;
      * <p>, <strong>, <em>, <del>, <sub>/<sup>/<code>, <span class>, <a>, <img>;
      * <blockquote>/class="epigraph" -> <cite>/<epigraph>;
      * <div class="poem"> -> <poem>/<stanza>/<v>;
      * <table> -> <table>, <hr> -> <empty-line>;
      * изображения (файлы рядом с .html или data-URI) -> <binary> (base64).

  HTML разбирается собственным толерантным парсером (аналог HTMLParser).

  Пример:
      C := THtmlToFb2Converter.Create;
      try
        C.Write('book.html', 'book.fb2');
      finally
        C.Free;
      end; }

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Classes, SysUtils, fgl,
  fb2_structures, fb2_writer, fb2_errors, fb2_genres, fb2_files;

const
  { Жанр по умолчанию (если в HTML нет подходящих жанров). }
  DEFAULT_GENRE = 'prose';
  DEFAULT_PROGRAM_USED = 'pyFB2';

type
  THtmlNode = class;

  THtmlNodeList = specialize TFPGObjectList<THtmlNode>;

  { Кадр стека секций при обходе заголовков. }
  TSectionFrame = record
    Level: Integer;
    Sec: TSection;
  end;

  TSectionStack = array of TSectionFrame;

  { Узел разобранного HTML-дерева (текстовые узлы: Tag = '#text'). }
  THtmlNode = class
  public
    Tag: UnicodeString;
    Attrs: TStringList;          { имя=значение }
    Children: THtmlNodeList;
    Text: UnicodeString;         { для текстовых узлов }
    constructor Create(const ATag: UnicodeString);
    destructor Destroy; override;
    function Attr(const Name: UnicodeString): UnicodeString;
    function HasClass(const Cls: UnicodeString): Boolean;
  end;

  { Толерантный HTML-парсер, строящий дерево узлов. }
  THtmlParser = class
  private
    FRoot: THtmlNode;
    FStack: TList;               { THtmlNode, открытые узлы (владелец — дерево) }
    procedure HandleStartTag(const ATag: UnicodeString; Attrs: TStringList;
      SelfClose: Boolean);
    procedure HandleEndTag(const ATag: UnicodeString);
    procedure HandleData(const AData: UnicodeString);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Feed(const Text: UnicodeString);
    property Root: THtmlNode read FRoot;
  end;

  { Преобразование HTML в структуры FB2 и обратно в XML. }
  THtmlToFb2Converter = class
  private
    FDefaultGenre: UnicodeString;
    FProgramUsed: UnicodeString;
    FWriter: TFb2Writer;
    FBook: TFictionBook;
    FBaseDir: UnicodeString;
    FSource: UnicodeString;
    FBinaries: TFb2ObjectList;
    FUsedIds: TStringList;

    procedure Reset;
    function ReadSource(const Source: UnicodeString;
      out BaseDir: UnicodeString): UnicodeString;
    function Parse(const Text: UnicodeString): TFictionBook;
    function FindBody(Node: THtmlNode): THtmlNode;
    function ConvertContent(Body: THtmlNode): TBody;
    procedure Walk(Node: THtmlNode; var Stack: TSectionStack;
      var StackLen: Integer);
    procedure WalkChildren(Node: THtmlNode; var Stack: TSectionStack;
      var StackLen: Integer);
    function IsSkip(Node: THtmlNode): Boolean;
    procedure CollectMetadata(Body: THtmlNode; Meta: TStringList;
      var Annotation: TAnnotation; var Cover: UnicodeString);
    procedure ParseHeader(Header: THtmlNode; Meta: TStringList;
      var Annotation: TAnnotation; var Cover: UnicodeString);
    function ConvertAnnotation(Node: THtmlNode): TAnnotation;

    function ConvertBlock(Node: THtmlNode): TFb2Object;
    function ConvertCite(Node: THtmlNode): TCite;
    function ConvertEpigraph(Node: THtmlNode): TEpigraph;
    function ConvertPoem(Node: THtmlNode): TPoem;
    function ConvertStanza(Node: THtmlNode): TStanza;
    function ConvertTable(Node: THtmlNode): TTable;
    function ConvertInline(Children: THtmlNodeList): TFb2ObjectList;
    function ConvertImageBlock(Node: THtmlNode): TImage;
    function RegisterImage(const Src: UnicodeString): UnicodeString;
    function RegisterDataUri(const Src: UnicodeString): UnicodeString;
    function UniqueId(const Name: UnicodeString): UnicodeString;
    function MatchGenres(Subjects: TTextList): TTextList;

    function Assemble(Meta: TStringList; Annotation: TAnnotation;
      const Cover: UnicodeString; Body: TBody): TFictionBook;
  public
    constructor Create(const ADefaultGenre: UnicodeString = DEFAULT_GENRE;
      const AProgramUsed: UnicodeString = DEFAULT_PROGRAM_USED);
    destructor Destroy; override;

    { Прочитать HTML и вернуть структуру TFictionBook (владелец — конвертер). }
    function Convert(const Source: UnicodeString = ''): TFictionBook;

    { Сериализовать книгу (или результат Convert) в XML FB2. }
    function ToXml(Book: TFictionBook = nil): UnicodeString;

    { Преобразовать HTML в файл FB2 и вернуть путь к результату. }
    function Write(const Source: UnicodeString;
      const Output: UnicodeString = ''): UnicodeString;

    property Book: TFictionBook read FBook;
  end;

implementation

uses
  fb2_parser;   { Base64DecodeString }

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
    if I + 1 < L then B1 := Data[I + 1] else B1 := 0;
    if I + 2 < L then B2 := Data[I + 2] else B2 := 0;
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

{ ===================== Служебные помощники ===================== }

{ Декодировать HTML-сущности (именованные и числовые). }
function DecodeEntities(const S: UnicodeString): UnicodeString;
var
  I, J, Code: Integer;
  Name: UnicodeString;
begin
  Result := '';
  I := 1;
  while I <= Length(S) do
  begin
    if S[I] = '&' then
    begin
      J := Pos(';', S, I + 1);
      if (J > 0) and (J - I <= 12) then
      begin
        Name := Copy(S, I + 1, J - I - 1);
        if (Length(Name) > 0) and (Name[1] = '#') then
        begin
          if (Length(Name) > 1) and ((Name[2] = 'x') or (Name[2] = 'X')) then
            Code := StrToIntDef('$' + Copy(Name, 3, MaxInt), -1)
          else
            Code := StrToIntDef(Copy(Name, 2, MaxInt), -1);
          if (Code >= 0) and (Code <= $FFFF) then
          begin
            Result := Result + WideChar(Code);
            I := J + 1;
            Continue;
          end;
        end
        else
        begin
          if Name = 'amp' then Code := Ord('&')
          else if Name = 'lt' then Code := Ord('<')
          else if Name = 'gt' then Code := Ord('>')
          else if Name = 'quot' then Code := Ord('"')
          else if Name = 'apos' then Code := Ord('''')
          else if Name = 'nbsp' then Code := 160
          else if Name = 'mdash' then Code := 8212
          else if Name = 'ndash' then Code := 8211
          else if Name = 'laquo' then Code := 171
          else if Name = 'raquo' then Code := 187
          else if Name = 'hellip' then Code := 8230
          else if Name = 'copy' then Code := 169
          else if Name = 'deg' then Code := 176
          else if Name = 'times' then Code := 215
          else if Name = 'middot' then Code := 183
          else if Name = 'bull' then Code := 8226
          else if Name = 'ldquo' then Code := 8220
          else if Name = 'rdquo' then Code := 8221
          else if Name = 'lsquo' then Code := 8216
          else if Name = 'rsquo' then Code := 8217
          else Code := -1;
          if Code >= 0 then
          begin
            Result := Result + WideChar(Code);
            I := J + 1;
            Continue;
          end;
        end;
      end;
    end;
    Result := Result + S[I];
    Inc(I);
  end;
end;

{ Проверка корректности XML-ID: ^[A-Za-z_][A-Za-z0-9_.-]*$. }
function IsValidId(const S: UnicodeString): Boolean;
var
  I: Integer;
  C: WideChar;
begin
  if S = '' then
    Exit(False);
  C := S[1];
  if not (((C >= 'A') and (C <= 'Z')) or ((C >= 'a') and (C <= 'z')) or
    (C = '_')) then
    Exit(False);
  for I := 2 to Length(S) do
  begin
    C := S[I];
    if not (((C >= 'A') and (C <= 'Z')) or ((C >= 'a') and (C <= 'z')) or
      ((C >= '0') and (C <= '9')) or (C = '_') or (C = '.') or (C = '-')) then
      Exit(False);
  end;
  Result := True;
end;

{ Привести имя к валидному XML-ID. }
function SanitizeId(const S: UnicodeString): UnicodeString;
var
  I: Integer;
  C: WideChar;
begin
  Result := '';
  for I := 1 to Length(S) do
  begin
    C := S[I];
    if ((C >= 'A') and (C <= 'Z')) or ((C >= 'a') and (C <= 'z')) or
      ((C >= '0') and (C <= '9')) or (C = '_') or (C = '.') or (C = '-') then
      Result := Result + C
    else
      Result := Result + '_';
  end;
  if not IsValidId(Result) then
    Result := 'image_' + Result;
end;

{ MIME-тип по расширению файла (для <binary content-type>). }
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

function IsVoidTag(const Tag: UnicodeString): Boolean;
begin
  Result := (Tag = 'area') or (Tag = 'base') or (Tag = 'br') or (Tag = 'col') or
    (Tag = 'embed') or (Tag = 'hr') or (Tag = 'img') or (Tag = 'input') or
    (Tag = 'link') or (Tag = 'meta') or (Tag = 'param') or (Tag = 'source') or
    (Tag = 'track') or (Tag = 'wbr');
end;

function IsHeadingTag(const Tag: UnicodeString): Boolean;
begin
  Result := (Tag = 'h1') or (Tag = 'h2') or (Tag = 'h3') or (Tag = 'h4') or
    (Tag = 'h5') or (Tag = 'h6');
end;

{ Разбить строку по пробельным символам (аналог str.split()). }
function SplitWhitespace(const S: UnicodeString): TTextList;
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

{ Разбить строку по разделителю, обрезая и пропуская пустые части. }
function SplitStripped(const S: UnicodeString; Sep: WideChar): TTextList;
var
  I: Integer;
  Cur: UnicodeString;
begin
  Result := TTextList.Create;
  Cur := '';
  for I := 1 to Length(S) + 1 do
  begin
    if (I > Length(S)) or (S[I] = Sep) then
    begin
      Cur := UTrim(Cur);
      if Cur <> '' then
        Result.Add(Cur);
      Cur := '';
    end
    else
      Cur := Cur + S[I];
  end;
end;

{ ===================== THtmlNode ===================== }

constructor THtmlNode.Create(const ATag: UnicodeString);
begin
  inherited Create;
  Tag := ATag;
  Attrs := TStringList.Create;
  Attrs.NameValueSeparator := '=';
  Children := THtmlNodeList.Create(True);
  Text := '';
end;

destructor THtmlNode.Destroy;
begin
  FreeAndNil(Children);
  FreeAndNil(Attrs);
  inherited Destroy;
end;

function THtmlNode.Attr(const Name: UnicodeString): UnicodeString;
var
  I: Integer;
begin
  I := Attrs.IndexOfName(Name);
  if I >= 0 then
    Result := Attrs.ValueFromIndex[I]
  else
    Result := '';
end;

function THtmlNode.HasClass(const Cls: UnicodeString): Boolean;
var
  Classes: TTextList;
  I: Integer;
begin
  Result := False;
  Classes := SplitWhitespace(Attr('class'));
  try
    for I := 0 to Classes.Count - 1 do
      if Classes[I] = Cls then
      begin
        Result := True;
        Break;
      end;
  finally
    Classes.Free;
  end;
end;

{ ===================== THtmlParser ===================== }

constructor THtmlParser.Create;
begin
  inherited Create;
  FRoot := THtmlNode.Create('#document');
  FStack := TList.Create;
  FStack.Add(FRoot);
end;

destructor THtmlParser.Destroy;
begin
  FreeAndNil(FStack);
  FreeAndNil(FRoot);
  inherited Destroy;
end;

procedure THtmlParser.HandleStartTag(const ATag: UnicodeString;
  Attrs: TStringList; SelfClose: Boolean);
var
  Node: THtmlNode;
  I: Integer;
begin
  Node := THtmlNode.Create(ATag);
  for I := 0 to Attrs.Count - 1 do
    Node.Attrs.Add(Attrs[I]);
  THtmlNode(FStack[FStack.Count - 1]).Children.Add(Node);
  if (not IsVoidTag(ATag)) and (not SelfClose) then
    FStack.Add(Node);
end;

procedure THtmlParser.HandleEndTag(const ATag: UnicodeString);
var
  Idx: Integer;
begin
  if IsVoidTag(ATag) then
    Exit;
  for Idx := FStack.Count - 1 downto 1 do
    if THtmlNode(FStack[Idx]).Tag = ATag then
    begin
      while FStack.Count > Idx do
        FStack.Delete(FStack.Count - 1);
      Break;
    end;
end;

procedure THtmlParser.HandleData(const AData: UnicodeString);
var
  Node: THtmlNode;
begin
  if AData = '' then
    Exit;
  Node := THtmlNode.Create('#text');
  Node.Text := AData;
  THtmlNode(FStack[FStack.Count - 1]).Children.Add(Node);
end;

procedure THtmlParser.Feed(const Text: UnicodeString);
var
  I, N, J, K, Q: Integer;
  C: WideChar;
  TagName, AttrName, AttrValue, TextBuf: UnicodeString;
  Attrs: TStringList;
  SelfClose: Boolean;
begin
  I := 1;
  N := Length(Text);
  while I <= N do
  begin
    C := Text[I];
    if C = '<' then
    begin
      if (I + 3 <= N) and (Copy(Text, I, 4) = '<!--') then
      begin
        J := Pos('-->', Text, I + 4);
        if J = 0 then
          I := N + 1
        else
          I := J + 3;
        Continue;
      end;
      if (I + 1 <= N) and ((Text[I + 1] = '!') or (Text[I + 1] = '?')) then
      begin
        J := Pos('>', Text, I + 2);
        if J = 0 then
          I := N + 1
        else
          I := J + 1;
        Continue;
      end;
      if (I + 1 <= N) and (Text[I + 1] = '/') then
      begin
        J := Pos('>', Text, I + 2);
        if J = 0 then
        begin
          TagName := Copy(Text, I + 2, N - (I + 1));
          I := N + 1;
        end
        else
        begin
          TagName := Copy(Text, I + 2, J - (I + 2));
          I := J + 1;
        end;
        TagName := LowerCase(UTrim(TagName));
        K := Pos(' ', TagName);
        if K > 0 then
          TagName := Copy(TagName, 1, K - 1);
        HandleEndTag(TagName);
        Continue;
      end;
      J := I + 1;
      while (J <= N) and (not (Text[J] in [' ', #9, #10, #13, '>', '/'])) do
        Inc(J);
      TagName := LowerCase(Copy(Text, I + 1, J - (I + 1)));
      Attrs := TStringList.Create;
      Attrs.NameValueSeparator := '=';
      SelfClose := False;
      while (J <= N) and (Text[J] <> '>') do
      begin
        while (J <= N) and (Text[J] in [' ', #9, #10, #13]) do
          Inc(J);
        if J > N then
          Break;
        if Text[J] = '>' then
          Break;
        if Text[J] = '/' then
        begin
          SelfClose := True;
          Inc(J);
          Continue;
        end;
        K := J;
        while (J <= N) and
          (not (Text[J] in [' ', #9, #10, #13, '=', '>', '/'])) do
          Inc(J);
        AttrName := LowerCase(Copy(Text, K, J - K));
        while (J <= N) and (Text[J] in [' ', #9, #10, #13]) do
          Inc(J);
        AttrValue := '';
        if (J <= N) and (Text[J] = '=') then
        begin
          Inc(J);
          while (J <= N) and (Text[J] in [' ', #9, #10, #13]) do
            Inc(J);
          if (J <= N) and ((Text[J] = '"') or (Text[J] = '''')) then
          begin
            Q := Ord(Text[J]);
            Inc(J);
            K := J;
            while (J <= N) and (Ord(Text[J]) <> Q) do
              Inc(J);
            AttrValue := Copy(Text, K, J - K);
            if J <= N then
              Inc(J);
          end
          else
          begin
            K := J;
            while (J <= N) and (not (Text[J] in [' ', #9, #10, #13, '>'])) do
              Inc(J);
            AttrValue := Copy(Text, K, J - K);
          end;
        end;
        if AttrName <> '' then
          Attrs.Values[AttrName] := DecodeEntities(AttrValue);
      end;
      if (J <= N) and (Text[J] = '>') then
        Inc(J);
      I := J;
      HandleStartTag(TagName, Attrs, SelfClose);
      Attrs.Free;
      Continue;
    end
    else
    begin
      J := I;
      while (J <= N) and (Text[J] <> '<') do
        Inc(J);
      TextBuf := Copy(Text, I, J - I);
      HandleData(DecodeEntities(TextBuf));
      I := J;
    end;
  end;
end;

{ ===================== THtmlToFb2Converter ===================== }

{ Простой текст из дочерних узлов (аналог _nodes_text). }
function NodesText(Children: THtmlNodeList): UnicodeString;
var
  I: Integer;
  C: THtmlNode;
begin
  Result := '';
  if Children = nil then
    Exit;
  for I := 0 to Children.Count - 1 do
  begin
    C := Children[I];
    if C.Tag = '#text' then
      Result := Result + C.Text
    else
      Result := Result + NodesText(C.Children);
  end;
  Result := UTrim(Result);
end;

procedure MoveList(Dest, Src: TFb2ObjectList);
var
  I: Integer;
begin
  for I := 0 to Src.Count - 1 do
    Dest.Add(Src[I]);
  Src.FreeObjects := False;
end;

constructor THtmlToFb2Converter.Create(const ADefaultGenre: UnicodeString;
  const AProgramUsed: UnicodeString);
begin
  inherited Create;
  FDefaultGenre := ADefaultGenre;
  FProgramUsed := AProgramUsed;
  FWriter := TFb2Writer.Create;
  FBook := nil;
  FBaseDir := '';
  FBinaries := nil;
  FUsedIds := nil;
  Reset;
end;

destructor THtmlToFb2Converter.Destroy;
begin
  FreeAndNil(FBook);
  FreeAndNil(FBinaries);
  FreeAndNil(FUsedIds);
  FreeAndNil(FWriter);
  inherited Destroy;
end;

procedure THtmlToFb2Converter.Reset;
begin
  FBaseDir := '';
  FreeAndNil(FBinaries);
  FBinaries := TFb2ObjectList.Create;
  FreeAndNil(FUsedIds);
  FUsedIds := TStringList.Create;
  FUsedIds.CaseSensitive := True;
end;

function THtmlToFb2Converter.ReadSource(const Source: UnicodeString;
  out BaseDir: UnicodeString): UnicodeString;
var
  FS: TFileStream;
  B: TBytes;
  Raw: RawByteString;
begin
  if FileExists(Source) then
  begin
    BaseDir := ExtractFileDir(Source);
    FS := TFileStream.Create(Source, fmOpenRead or fmShareDenyWrite);
    try
      SetLength(B, FS.Size);
      if FS.Size > 0 then
        FS.ReadBuffer(B[0], FS.Size);
    finally
      FS.Free;
    end;
    SetLength(Raw, Length(B));
    if Length(B) > 0 then
      Move(B[0], Raw[1], Length(B));
    Result := UTF8Decode(Raw);
  end
  else
  begin
    BaseDir := '';
    Result := Source;
  end;
end;

function THtmlToFb2Converter.FindBody(Node: THtmlNode): THtmlNode;
var
  I: Integer;
  C, Found: THtmlNode;
begin
  Result := nil;
  for I := 0 to Node.Children.Count - 1 do
  begin
    C := Node.Children[I];
    if C.Tag = 'body' then
      Exit(C);
    Found := FindBody(C);
    if Found <> nil then
      Exit(Found);
  end;
end;

function THtmlToFb2Converter.Parse(const Text: UnicodeString): TFictionBook;
var
  P: THtmlParser;
  Body: THtmlNode;
  Meta: TStringList;
  Annotation: TAnnotation;
  Cover: UnicodeString;
  FB: TBody;
begin
  P := THtmlParser.Create;
  Meta := TStringList.Create;
  try
    Meta.NameValueSeparator := '=';
    P.Feed(Text);
    Body := FindBody(P.Root);
    if Body = nil then
      Body := P.Root;
    Annotation := nil;
    Cover := '';
    CollectMetadata(Body, Meta, Annotation, Cover);
    FB := ConvertContent(Body);
    Result := Assemble(Meta, Annotation, Cover, FB);
  finally
    Meta.Free;
    P.Free;
  end;
end;

function THtmlToFb2Converter.ConvertContent(Body: THtmlNode): TBody;
var
  RootSection: TSection;
  Stack: TSectionStack;
  StackLen: Integer;
  I: Integer;
  C: THtmlNode;
  Sec: TSection;
begin
  Result := TBody.Create;
  RootSection := TSection.Create;
  SetLength(Stack, 4);
  Stack[0].Level := 0;
  Stack[0].Sec := RootSection;
  StackLen := 1;

  for I := 0 to Body.Children.Count - 1 do
  begin
    C := Body.Children[I];
    if (C.Tag <> '#text') and (not IsSkip(C)) then
      Walk(C, Stack, StackLen);
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

function THtmlToFb2Converter.IsSkip(Node: THtmlNode): Boolean;
begin
  if (Node.Tag = 'header') or (Node.Tag = 'nav') or (Node.Tag = 'head') or
    (Node.Tag = 'script') or (Node.Tag = 'style') then
    Exit(True);
  Result := Node.HasClass('book-header') or Node.HasClass('toc');
end;

procedure THtmlToFb2Converter.Walk(Node: THtmlNode; var Stack: TSectionStack;
  var StackLen: Integer);
var
  Tag: UnicodeString;
  Level, I: Integer;
  Nodes: TFb2ObjectList;
  Section, Container: TSection;
  Par: TParagraph;
  Block: TFb2Object;
  LocalStack: TSectionStack;
  LocalLen: Integer;
begin
  Tag := Node.Tag;

  if IsHeadingTag(Tag) then
  begin
    Level := Ord(Tag[2]) - Ord('0');
    while (StackLen > 1) and (Stack[StackLen - 1].Level >= Level) do
      Dec(StackLen);
    Nodes := ConvertInline(Node.Children);
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
    Exit;
  end;

  if Tag = 'div' then
  begin
    if Node.HasClass('poem') or Node.HasClass('image') or
      Node.HasClass('annotation') then
    begin
      Block := ConvertBlock(Node);
      if Block <> nil then
        Stack[StackLen - 1].Sec.Content.Add(Block);
      Exit;
    end;
    WalkChildren(Node, Stack, StackLen);
    Exit;
  end;

  if (Tag = 'section') or (Tag = 'article') or (Tag = 'main') then
  begin
    if (Node.Attr('id') <> '') and Node.HasClass('footnote') then
    begin
      Container := TSection.Create;
      Container.Id := Node.Attr('id');
      Stack[StackLen - 1].Sec.Sections.Add(Container);
      SetLength(LocalStack, 4);
      LocalStack[0].Level := Stack[StackLen - 1].Level;
      LocalStack[0].Sec := Container;
      LocalLen := 1;
      WalkChildren(Node, LocalStack, LocalLen);
      Exit;
    end;
    WalkChildren(Node, Stack, StackLen);
    Exit;
  end;

  Block := ConvertBlock(Node);
  if Block <> nil then
    Stack[StackLen - 1].Sec.Content.Add(Block);
end;

procedure THtmlToFb2Converter.WalkChildren(Node: THtmlNode;
  var Stack: TSectionStack; var StackLen: Integer);
var
  I: Integer;
  C: THtmlNode;
begin
  for I := 0 to Node.Children.Count - 1 do
  begin
    C := Node.Children[I];
    if C.Tag <> '#text' then
      Walk(C, Stack, StackLen);
  end;
end;

{ ===================== Метаданные ===================== }

{ Первый вложенный <img>. }
function FindImg(Node: THtmlNode): THtmlNode;
var
  I: Integer;
  C, Found: THtmlNode;
begin
  Result := nil;
  for I := 0 to Node.Children.Count - 1 do
  begin
    C := Node.Children[I];
    if C.Tag = 'img' then
      Exit(C);
    Found := FindImg(C);
    if Found <> nil then
      Exit(Found);
  end;
end;

procedure THtmlToFb2Converter.CollectMetadata(Body: THtmlNode;
  Meta: TStringList; var Annotation: TAnnotation; var Cover: UnicodeString);
var
  I: Integer;
  C: THtmlNode;
begin
  Meta.Values['title'] := '';
  Meta.Values['creators'] := '';
  Meta.Values['genres'] := '';
  Annotation := nil;
  Cover := '';
  for I := 0 to Body.Children.Count - 1 do
  begin
    C := Body.Children[I];
    if (C.Tag = 'header') or C.HasClass('book-header') then
      ParseHeader(C, Meta, Annotation, Cover);
  end;
end;

procedure THtmlToFb2Converter.ParseHeader(Header: THtmlNode;
  Meta: TStringList; var Annotation: TAnnotation; var Cover: UnicodeString);
var
  I: Integer;
  C, Img: THtmlNode;
  Text: UnicodeString;
  L: TTextList;
begin
  for I := 0 to Header.Children.Count - 1 do
  begin
    C := Header.Children[I];
    if C.HasClass('book-title') then
      Meta.Values['title'] := NodesText(C.Children)
    else if C.HasClass('book-author') then
    begin
      Text := NodesText(C.Children);
      L := SplitStripped(Text, ';');
      try
        Meta.Values['creators'] := JoinText(L, #10);
      finally
        L.Free;
      end;
    end
    else if C.HasClass('book-genres') then
    begin
      Text := NodesText(C.Children);
      L := SplitStripped(Text, ',');
      try
        Meta.Values['genres'] := JoinText(L, #10);
      finally
        L.Free;
      end;
    end
    else if C.HasClass('annotation') then
    begin
      if Annotation <> nil then
        Annotation.Free;
      Annotation := ConvertAnnotation(C);
    end
    else if C.HasClass('cover') then
    begin
      Img := FindImg(C);
      if Img <> nil then
        Cover := RegisterImage(Img.Attr('src'));
    end;
  end;
end;

function THtmlToFb2Converter.ConvertAnnotation(Node: THtmlNode): TAnnotation;
var
  Items: TFb2ObjectList;
  I: Integer;
  C: THtmlNode;
  Block: TFb2Object;
begin
  Items := TFb2ObjectList.Create;
  for I := 0 to Node.Children.Count - 1 do
  begin
    C := Node.Children[I];
    if C.Tag <> '#text' then
    begin
      Block := ConvertBlock(C);
      if Block <> nil then
        Items.Add(Block);
    end;
  end;
  Result := nil;
  if Items.Count > 0 then
  begin
    Result := TAnnotation.Create;
    FreeAndNil(Result.Items);
    Result.Items := Items;
  end
  else
    Items.Free;
end;

{ ===================== Блочные элементы ===================== }

function THtmlToFb2Converter.ConvertBlock(Node: THtmlNode): TFb2Object;
var
  Tag: UnicodeString;
  Par: TParagraph;
  Sub: TSubtitle;
  Img: THtmlNode;
begin
  Tag := Node.Tag;

  if Tag = 'p' then
  begin
    if Node.HasClass('footnote-back') then
      Exit(nil);
    if Node.HasClass('subtitle') then
    begin
      Sub := TSubtitle.Create;
      FreeAndNil(Sub.Content);
      Sub.Content := ConvertInline(Node.Children);
      Exit(Sub);
    end;
    if Node.HasClass('empty-line') then
      Exit(TEmptyLine.Create);
    Par := TParagraph.Create;
    FreeAndNil(Par.Content);
    Par.Content := ConvertInline(Node.Children);
    Exit(Par);
  end;
  if Tag = 'blockquote' then
  begin
    if Node.HasClass('epigraph') then
      Exit(ConvertEpigraph(Node))
    else
      Exit(ConvertCite(Node));
  end;
  if Tag = 'table' then
    Exit(ConvertTable(Node));
  if Tag = 'hr' then
    Exit(TEmptyLine.Create);
  if Tag = 'img' then
    Exit(ConvertImageBlock(Node));
  if IsHeadingTag(Tag) then
  begin
    Sub := TSubtitle.Create;
    FreeAndNil(Sub.Content);
    Sub.Content := ConvertInline(Node.Children);
    Exit(Sub);
  end;
  if Tag = 'div' then
  begin
    if Node.HasClass('poem') then
      Exit(ConvertPoem(Node));
    if Node.HasClass('image') then
    begin
      Img := FindImg(Node);
      if Img <> nil then
        Exit(ConvertImageBlock(Img));
    end;
    Exit(nil);
  end;
  Result := nil;
end;

function THtmlToFb2Converter.ConvertPoem(Node: THtmlNode): TPoem;
var
  I: Integer;
  C: THtmlNode;
  Par: TParagraph;
  Sub: TSubtitle;
begin
  Result := TPoem.Create;
  for I := 0 to Node.Children.Count - 1 do
  begin
    C := Node.Children[I];
    if C.Tag = '#text' then
      Continue;
    if (C.Tag = 'p') and C.HasClass('poem-title') then
    begin
      Par := TParagraph.Create;
      FreeAndNil(Par.Content);
      Par.Content := ConvertInline(C.Children);
      Result.Title := TTitle.Create;
      Result.Title.Items.Add(Par);
    end
    else if (C.Tag = 'div') and C.HasClass('stanza') then
      Result.Items.Add(ConvertStanza(C))
    else if (C.Tag = 'p') and C.HasClass('text-author') then
    begin
      Par := TParagraph.Create;
      FreeAndNil(Par.Content);
      Par.Content := ConvertInline(C.Children);
      Result.TextAuthor.Add(Par);
    end
    else if (C.Tag = 'p') and C.HasClass('subtitle') then
    begin
      Sub := TSubtitle.Create;
      FreeAndNil(Sub.Content);
      Sub.Content := ConvertInline(C.Children);
      Result.Items.Add(Sub);
    end
    else if C.Tag = 'blockquote' then
      Result.Epigraphs.Add(ConvertEpigraph(C));
  end;
end;

function THtmlToFb2Converter.ConvertStanza(Node: THtmlNode): TStanza;
var
  I: Integer;
  C: THtmlNode;
  Par: TParagraph;
begin
  Result := TStanza.Create;
  for I := 0 to Node.Children.Count - 1 do
  begin
    C := Node.Children[I];
    if C.Tag = '#text' then
      Continue;
    if (C.Tag = 'p') and C.HasClass('verse') then
    begin
      Par := TParagraph.Create;
      FreeAndNil(Par.Content);
      Par.Content := ConvertInline(C.Children);
      Result.Verses.Add(Par);
    end
    else if (C.Tag = 'p') and C.HasClass('subtitle') then
    begin
      Result.Subtitle := TSubtitle.Create;
      FreeAndNil(Result.Subtitle.Content);
      Result.Subtitle.Content := ConvertInline(C.Children);
    end
    else if (C.Tag = 'p') and C.HasClass('poem-title') then
    begin
      Par := TParagraph.Create;
      FreeAndNil(Par.Content);
      Par.Content := ConvertInline(C.Children);
      Result.Title := TTitle.Create;
      Result.Title.Items.Add(Par);
    end;
  end;
end;

{ Собрать все вложенные узлы с данным тегом (аналог _iter). }
procedure IterTag(Node: THtmlNode; const Tag: UnicodeString; List: TList);
var
  I: Integer;
  C: THtmlNode;
begin
  for I := 0 to Node.Children.Count - 1 do
  begin
    C := Node.Children[I];
    if C.Tag = Tag then
      List.Add(C);
    IterTag(C, Tag, List);
  end;
end;

{ Мягкое приведение строки к int (None -> NO_VALUE). }
function ToIntOrNone(const Value: UnicodeString): Integer;
begin
  if Value = '' then
    Result := NO_VALUE
  else
    Result := StrToIntDef(Value, NO_VALUE);
end;

function THtmlToFb2Converter.ConvertTable(Node: THtmlNode): TTable;
var
  Trs: TList;
  I, J: Integer;
  Tr, Td: THtmlNode;
  Cells: TFb2ObjectList;
  Row: TTableRow;
  Cell: TTableCell;
begin
  Result := TTable.Create;
  Trs := TList.Create;
  try
    IterTag(Node, 'tr', Trs);
    for I := 0 to Trs.Count - 1 do
    begin
      Tr := THtmlNode(Trs[I]);
      Cells := TFb2ObjectList.Create;
      for J := 0 to Tr.Children.Count - 1 do
      begin
        Td := Tr.Children[J];
        if (Td.Tag = 'td') or (Td.Tag = 'th') then
        begin
          Cell := TTableCell.Create;
          Cell.Tag := Td.Tag;
          FreeAndNil(Cell.Children);
          Cell.Children := ConvertInline(Td.Children);
          Cell.Colspan := ToIntOrNone(Td.Attr('colspan'));
          Cell.Rowspan := ToIntOrNone(Td.Attr('rowspan'));
          Cell.IsHeader := (Td.Tag = 'th');
          Cells.Add(Cell);
        end;
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
    end;
    if Result.Rows.Count = 0 then
      FreeAndNil(Result);
  finally
    Trs.Free;
  end;
end;

{ ===================== Inline-разметка ===================== }

function THtmlToFb2Converter.ConvertInline(Children: THtmlNodeList): TFb2ObjectList;
var
  I: Integer;
  C: THtmlNode;
  Tag, Href: UnicodeString;
  SN: TStyleNode;
  Sub: TFb2ObjectList;
begin
  Result := TFb2ObjectList.Create;
  for I := 0 to Children.Count - 1 do
  begin
    C := Children[I];
    if C.Tag = '#text' then
    begin
      if C.Text <> '' then
      begin
        SN := TStyleNode.Create(TEXT_NODE_NAME);
        SN.Text := C.Text;
        Result.Add(SN);
      end;
      Continue;
    end;

    Tag := C.Tag;
    if (Tag = 'strong') or (Tag = 'b') then
    begin
      SN := TStyleNode.Create('strong');
      FreeAndNil(SN.Children);
      SN.Children := ConvertInline(C.Children);
      Result.Add(SN);
    end
    else if (Tag = 'em') or (Tag = 'i') then
    begin
      SN := TStyleNode.Create('emphasis');
      FreeAndNil(SN.Children);
      SN.Children := ConvertInline(C.Children);
      Result.Add(SN);
    end
    else if (Tag = 'del') or (Tag = 's') or (Tag = 'strike') then
    begin
      SN := TStyleNode.Create('strikethrough');
      FreeAndNil(SN.Children);
      SN.Children := ConvertInline(C.Children);
      Result.Add(SN);
    end
    else if (Tag = 'sub') or (Tag = 'sup') or (Tag = 'code') then
    begin
      SN := TStyleNode.Create(Tag);
      FreeAndNil(SN.Children);
      SN.Children := ConvertInline(C.Children);
      Result.Add(SN);
    end
    else if Tag = 'span' then
    begin
      SN := TStyleNode.Create('style');
      SN.StyleName := C.Attr('class');
      FreeAndNil(SN.Children);
      SN.Children := ConvertInline(C.Children);
      Result.Add(SN);
    end
    else if Tag = 'a' then
    begin
      if C.HasClass('footnote-back') then
        Continue;
      SN := TStyleNode.Create('a');
      SN.Href := C.Attr('href');
      if C.HasClass('note-ref') then
        SN.LinkType := 'note';
      FreeAndNil(SN.Children);
      SN.Children := ConvertInline(C.Children);
      Result.Add(SN);
    end
    else if Tag = 'img' then
    begin
      Href := RegisterImage(C.Attr('src'));
      if Href <> '' then
      begin
        SN := TStyleNode.Create('image');
        SN.ImageHref := Href;
        SN.ImageAlt := C.Attr('alt');
        Result.Add(SN);
      end;
    end
    else if Tag = 'br' then
    begin
      SN := TStyleNode.Create(TEXT_NODE_NAME);
      SN.Text := #10;
      Result.Add(SN);
    end
    else
    begin
      Sub := ConvertInline(C.Children);
      MoveList(Result, Sub);
      Sub.Free;
    end;
  end;
end;

function THtmlToFb2Converter.ConvertImageBlock(Node: THtmlNode): TImage;
var
  Href: UnicodeString;
begin
  Href := RegisterImage(Node.Attr('src'));
  if Href = '' then
    Exit(nil);
  Result := TImage.Create;
  Result.Href := Href;
  Result.Alt := Node.Attr('alt');
end;

function THtmlToFb2Converter.RegisterImage(const Src: UnicodeString): UnicodeString;
var
  S, Path, ContentType, Fb2Id: UnicodeString;
  Data: TBytes;
  Bin: TBinary;
begin
  Result := '';
  S := UTrim(Src);
  if S = '' then
    Exit;
  if Pos('data:', S) = 1 then
    Exit(RegisterDataUri(S));
  if FBaseDir = '' then
    Exit;
  Path := IncludeTrailingPathDelimiter(FBaseDir) +
    StringReplace(S, '/', PathDelim, [rfReplaceAll]);
  if not FileExists(Path) then
    Exit;
  Data := ReadFileBytes(Path);
  if Length(Data) = 0 then
    Exit;
  ContentType := ContentTypeByExt(LowerCase(ExtractFileExt(Path)));
  Fb2Id := UniqueId(ExtractFileName(Path));
  Bin := TBinary.Create;
  Bin.Id := Fb2Id;
  Bin.ContentType := ContentType;
  Bin.Data := Base64EncodeBytes(Data);
  FBinaries.Add(Bin);
  Result := '#' + Fb2Id;
end;

function THtmlToFb2Converter.RegisterDataUri(const Src: UnicodeString): UnicodeString;
var
  P: Integer;
  Header, Payload, Meta, CT, Rest, Fb2Id: UnicodeString;
  IsB64: Boolean;
  Data: TBytes;
  Bin: TBinary;
begin
  Result := '';
  P := Pos(',', Src);
  if P = 0 then
    Exit;
  Header := Copy(Src, 1, P - 1);
  Payload := Copy(Src, P + 1, MaxInt);
  Meta := Copy(Header, Length('data:') + 1, MaxInt);
  P := Pos(';', Meta);
  if P > 0 then
  begin
    CT := Copy(Meta, 1, P - 1);
    Rest := Copy(Meta, P + 1, MaxInt);
  end
  else
  begin
    CT := Meta;
    Rest := '';
  end;
  if CT = '' then
    CT := 'image/png';
  IsB64 := Pos('base64', Rest) > 0;
  if IsB64 then
    Data := Base64DecodeString(Payload)
  else
    Data := TEncoding.UTF8.GetBytes(Payload);
  if Copy(CT, 1, 6) <> 'image/' then
    Exit;
  Fb2Id := UniqueId('image');
  Bin := TBinary.Create;
  Bin.Id := Fb2Id;
  Bin.ContentType := CT;
  Bin.Data := Base64EncodeBytes(Data);
  FBinaries.Add(Bin);
  Result := '#' + Fb2Id;
end;

function THtmlToFb2Converter.UniqueId(const Name: UnicodeString): UnicodeString;
var
  Candidate, Stem, Suffix: UnicodeString;
  Counter: Integer;
begin
  if IsValidId(Name) then
    Candidate := Name
  else
    Candidate := SanitizeId(Name);
  if FUsedIds.IndexOf(Candidate) < 0 then
  begin
    FUsedIds.Add(Candidate);
    Exit(Candidate);
  end;
  Stem := ChangeFileExt(ExtractFileName(Name), '');
  Suffix := ExtractFileExt(Name);
  Counter := 1;
  while FUsedIds.IndexOf(Stem + '_' + IntToStr(Counter) + Suffix) >= 0 do
    Inc(Counter);
  Result := Stem + '_' + IntToStr(Counter) + Suffix;
  FUsedIds.Add(Result);
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
  Words := SplitWhitespace(N);
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

function THtmlToFb2Converter.MatchGenres(Subjects: TTextList): TTextList;
var
  I: Integer;
  S, Code: UnicodeString;
begin
  Result := TTextList.Create;
  for I := 0 to Subjects.Count - 1 do
  begin
    S := UTrim(Subjects[I]);
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

function THtmlToFb2Converter.Assemble(Meta: TStringList;
  Annotation: TAnnotation; const Cover: UnicodeString;
  Body: TBody): TFictionBook;
var
  Desc: TDescription;
  TI: TTitleInfo;
  DI: TDocumentInfo;
  Title: UnicodeString;
  I: Integer;
  Creators, Genres, Matched: TTextList;
  A: TAuthor;
  G: TGenre;
  CP: TCoverPage;
  II: TInlineImage;
begin
  Title := Meta.Values['title'];
  if Title = '' then
    Title := 'Untitled';
  Creators := SplitStripped(Meta.Values['creators'], #10);
  Genres := SplitStripped(Meta.Values['genres'], #10);

  Result := TFictionBook.Create;
  Desc := TDescription.Create;
  Result.Description := Desc;
  TI := TTitleInfo.Create;
  Desc.TitleInfo := TI;

  Matched := MatchGenres(Genres);
  try
    for I := 0 to Matched.Count - 1 do
    begin
      G := TGenre.Create;
      G.Value := Matched[I];
      TI.Genres.Add(G);
    end;
  finally
    Matched.Free;
  end;

  for I := 0 to Creators.Count - 1 do
    TI.Authors.Add(SplitAuthorName(Creators[I]));

  TI.BookTitle := TTextField.Create;
  TI.BookTitle.Value := Title;
  TI.Annotation := Annotation;
  if Cover <> '' then
  begin
    CP := TCoverPage.Create;
    II := TInlineImage.Create;
    II.Href := Cover;
    CP.Images.Add(II);
    TI.Coverpage := CP;
  end;
  TI.Lang := 'ru';

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

  Result.Bodies.Add(Body);
  for I := 0 to FBinaries.Count - 1 do
    Result.Binaries.Add(FBinaries[I]);
  FBinaries.FreeObjects := False;
  FBinaries.Clear;

  Creators.Free;
  Genres.Free;
end;

{ ===================== Публичный API ===================== }

function THtmlToFb2Converter.Convert(const Source: UnicodeString): TFictionBook;
var
  Text, BaseDir: UnicodeString;
begin
  if Source <> '' then
    FSource := Source;
  if FSource = '' then
    raise EFb2ConversionError.Create('Не задан источник HTML (source)');

  Reset;
  Text := ReadSource(FSource, BaseDir);
  FBaseDir := BaseDir;
  FBook := Parse(Text);
  Result := FBook;
end;

function THtmlToFb2Converter.ToXml(Book: TFictionBook): UnicodeString;
begin
  if Book = nil then
    Book := FBook;
  if Book = nil then
    Book := Convert;
  Result := FWriter.ToXML(Book);
end;

function THtmlToFb2Converter.Write(const Source: UnicodeString;
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

function THtmlToFb2Converter.ConvertCite(Node: THtmlNode): TCite;
var
  I: Integer;
  C: THtmlNode;
  Block: TFb2Object;
  Par: TParagraph;
begin
  Result := TCite.Create;
  for I := 0 to Node.Children.Count - 1 do
  begin
    C := Node.Children[I];
    if C.Tag = '#text' then
      Continue;
    if (C.Tag = 'p') and C.HasClass('text-author') then
    begin
      Par := TParagraph.Create;
      FreeAndNil(Par.Content);
      Par.Content := ConvertInline(C.Children);
      Result.TextAuthor.Add(Par);
    end
    else
    begin
      Block := ConvertBlock(C);
      if Block <> nil then
        Result.Items.Add(Block);
    end;
  end;
end;

function THtmlToFb2Converter.ConvertEpigraph(Node: THtmlNode): TEpigraph;
var
  I: Integer;
  C: THtmlNode;
  Block: TFb2Object;
  Par: TParagraph;
begin
  Result := TEpigraph.Create;
  for I := 0 to Node.Children.Count - 1 do
  begin
    C := Node.Children[I];
    if C.Tag = '#text' then
      Continue;
    if (C.Tag = 'p') and C.HasClass('text-author') then
    begin
      Par := TParagraph.Create;
      FreeAndNil(Par.Content);
      Par.Content := ConvertInline(C.Children);
      Result.TextAuthor.Add(Par);
    end
    else
    begin
      Block := ConvertBlock(C);
      if Block <> nil then
        Result.Items.Add(Block);
    end;
  end;
end;

end.

