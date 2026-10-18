unit markdown_to_fb2;
{ Преобразование Markdown в FictionBook (FB2) — перевод markdown_to_fb2.py.

  Класс TMarkdownToFb2Converter читает Markdown (в формате, генерируемом
  fb2_to_markdown) и собирает структуры FB2, после чего сериализует их в XML
  FictionBook 2.0 (через TFb2Writer).

  Что поддерживается:
      * # (уровень 1) -> <book-title>, ## и глубже -> <section>;
      * **Автор:**, **Жанры:**, **Дата:**, **Язык:** -> метаданные;
      * > (цитата) -> аннотация/<cite>, ![…](…) -> обложка/изображение;
      * **жирный**, *курсив*, ~~зачёркнутый~~, `код`, <sub>/<sup>,
        [текст](url) -> inline-разметка;
      * | … | -> <table>, строки с двумя пробелами в конце -> стихи;
      * изображения из файлов -> <binary> (base64).

  Пример:
      C := TMarkdownToFb2Converter.Create;
      try
        C.Write('book.md', 'book.fb2');
      finally
        C.Free;
      end; }

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Classes, SysUtils, StrUtils, fgl,
  fb2_structures, fb2_writer, fb2_errors, fb2_files, fb2_genres;

const
  { Жанр по умолчанию (если в Markdown нет подходящих «Жанры:»). }
  DEFAULT_GENRE = 'prose';

type
  { Кадр стека секций при обходе заголовков. }
  TSectionFrame = record
    Level: Integer;
    Sec: TSection;
  end;

  TSectionStack = array of TSectionFrame;

  { Преобразование Markdown в структуры FB2 и обратно в XML. }
  TMarkdownToFb2Converter = class
  private
    FWriter: TFb2Writer;
    FSource: UnicodeString;
    FDefaultGenre: UnicodeString;
    FProgramUsed: UnicodeString;
    FBook: TFictionBook;
    FBaseDir: UnicodeString;
    FHasBaseDir: Boolean;
    FBinaries: TFb2ObjectList;
    FUsedIds: TStringList;

    procedure Reset;
    function ReadSource(const Source: UnicodeString; out BaseDir: UnicodeString;
      out HasBaseDir: Boolean): UnicodeString;
    function ParseMarkdown(const Text: UnicodeString): TFictionBook;

    function ParseInline(const Text: UnicodeString): TFb2ObjectList;
    function FindClosing(const Text, Token: UnicodeString;
      Start: Integer): Integer;
    function SplitImage(const S: UnicodeString;
      out Alt: UnicodeString): UnicodeString;
    function NodesText(Nodes: TFb2ObjectList): UnicodeString;

    function CollectQuote(Lines: TTextList; Start: Integer): TTextList;
    function ParseBlocks(Lines: TTextList): TFb2ObjectList;
    function CollectTable(Lines: TTextList; Start: Integer): TTextList;
    function ParseTable(Lines: TTextList): TTable;
    function IsSeparator(Cells: TTextList): Boolean;
    function CollectPoem(Lines: TTextList; Start: Integer): TTextList;
    function ParsePoem(Lines: TTextList): TPoem;

    function RegisterImage(const Src: UnicodeString): UnicodeString;
    function UniqueId(const Name: UnicodeString): UnicodeString;
    function MatchGenres(Subjects: TTextList): TTextList;
    function SplitAuthor(const Name: UnicodeString): TAuthor;

    function AnnotationOf(Items: TFb2ObjectList): TAnnotation;
    function DateFieldOf(const Value: UnicodeString): TDateField;
    function Assemble(const Title: UnicodeString; Creators, Genres: TTextList;
      AnnotationItems: TFb2ObjectList; const CoverHref, DateValue,
      Lang: UnicodeString; Body: TBody): TFictionBook;
  public
    constructor Create(const ASource: UnicodeString = '';
      const ADefaultGenre: UnicodeString = DEFAULT_GENRE;
      const AProgramUsed: UnicodeString = 'pyFB2');
    destructor Destroy; override;

    { Прочитать Markdown и вернуть структуру TFictionBook. }
    function Convert(const Source: UnicodeString = ''): TFictionBook;

    { Сериализовать книгу (или результат Convert) в XML FB2. }
    function ToXml(Book: TFictionBook = nil): UnicodeString;

    { Преобразовать Markdown в файл FB2 и вернуть путь к результату. }
    function Write(const Source: UnicodeString;
      const Output: UnicodeString = ''): UnicodeString;

    property Book: TFictionBook read FBook;
  end;

implementation

{ ===================== Служебные помощники ===================== }

{ Разбить текст на строки (аналог str.splitlines для \r\n, \n, \r). }
function SplitLines(const Text: UnicodeString): TTextList;
var
  I, N: Integer;
  Cur: UnicodeString;
  C: WideChar;
begin
  Result := TTextList.Create;
  Cur := '';
  N := Length(Text);
  I := 1;
  while I <= N do
  begin
    C := Text[I];
    if C = #13 then
    begin
      Result.Add(Cur);
      Cur := '';
      if (I < N) and (Text[I + 1] = #10) then
        Inc(I);
    end
    else if C = #10 then
    begin
      Result.Add(Cur);
      Cur := '';
    end
    else
      Cur := Cur + C;
    Inc(I);
  end;
  if Cur <> '' then
    Result.Add(Cur);
end;

{ Разбить строку по пробельным символам (аналог str.split()). }
function SplitWords(const S: UnicodeString): TTextList;
var
  I: Integer;
  Cur: UnicodeString;
  C: WideChar;
begin
  Result := TTextList.Create;
  Cur := '';
  for I := 1 to Length(S) do
  begin
    C := S[I];
    if (C = ' ') or (C = #9) or (C = #10) or (C = #13) or (C = #12) or
      (C = #11) then
    begin
      if Cur <> '' then
      begin
        Result.Add(Cur);
        Cur := '';
      end;
    end
    else
      Cur := Cur + C;
  end;
  if Cur <> '' then
    Result.Add(Cur);
end;

{ Строка — корректный XML-ID (аналог _ID_RE)? }
function IsValidId(const S: UnicodeString): Boolean;
var
  I: Integer;
  C: WideChar;
begin
  Result := False;
  if S = '' then
    Exit;
  C := S[1];
  if not (((C >= 'A') and (C <= 'Z')) or ((C >= 'a') and (C <= 'z')) or
    (C = '_')) then
    Exit;
  for I := 2 to Length(S) do
  begin
    C := S[I];
    if not (((C >= 'A') and (C <= 'Z')) or ((C >= 'a') and (C <= 'z')) or
      ((C >= '0') and (C <= '9')) or (C = '_') or (C = '.') or (C = '-')) then
      Exit;
  end;
  Result := True;
end;

{ Привести имя к корректному XML-ID (аналог _sanitize_id). }
function SanitizeId(const Name: UnicodeString): UnicodeString;
var
  I: Integer;
  C: WideChar;
begin
  Result := '';
  for I := 1 to Length(Name) do
  begin
    C := Name[I];
    if ((C >= 'A') and (C <= 'Z')) or ((C >= 'a') and (C <= 'z')) or
      ((C >= '0') and (C <= '9')) or (C = '_') or (C = '.') or (C = '-') then
      Result := Result + C
    else
      Result := Result + '_';
  end;
  if not IsValidId(Result) then
    Result := 'image_' + Result;
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

{ MIME-тип по расширению (аналог _CONTENT_TYPE_BY_EXT). }
function ContentTypeByExt(const Ext: UnicodeString): UnicodeString;
var
  E: UnicodeString;
begin
  E := LowerCase(Ext);
  if (E = '.jpg') or (E = '.jpeg') then
    Result := 'image/jpeg'
  else if E = '.png' then
    Result := 'image/png'
  else if E = '.gif' then
    Result := 'image/gif'
  else if E = '.svg' then
    Result := 'image/svg+xml'
  else if E = '.webp' then
    Result := 'image/webp'
  else if E = '.bmp' then
    Result := 'image/bmp'
  else if (E = '.tif') or (E = '.tiff') then
    Result := 'image/tiff'
  else
    Result := 'application/octet-stream';
end;

{ Строка заканчивается двумя пробелами? }
function EndsWithTwoSpaces(const S: UnicodeString): Boolean;
var
  N: Integer;
begin
  N := Length(S);
  Result := (N >= 2) and (S[N] = ' ') and (S[N - 1] = ' ');
end;

{ Разобрать заголовок ``#{1,6}\s+...``. }
function MatchHeading(const Line: UnicodeString; out Level: Integer;
  out Rest: UnicodeString): Boolean;
var
  I, N: Integer;
begin
  Result := False;
  Level := 0;
  Rest := '';
  N := Length(Line);
  I := 1;
  while (I <= N) and (I <= 6) and (Line[I] = '#') do
    Inc(I);
  Level := I - 1;
  if Level < 1 then
    Exit;
  if I > N then
    Exit;
  if (Line[I] <> ' ') and (Line[I] <> #9) then
    Exit;
  while (I <= N) and ((Line[I] = ' ') or (Line[I] = #9)) do
    Inc(I);
  Rest := Copy(Line, I, N - I + 1);
  Result := True;
end;

{ Разобрать метаданные ``**Ключ:** значение`` (аналог _META_RE). }
function MatchMeta(const S: UnicodeString; out Key, Value: UnicodeString): Boolean;
var
  Rest, VPart: UnicodeString;
  P: Integer;
begin
  Result := False;
  Key := '';
  Value := '';
  if Copy(S, 1, 2) <> '**' then
    Exit;
  Rest := Copy(S, 3, Length(S) - 2);
  P := Pos(':**', Rest);
  if P < 2 then
    Exit;
  Key := Copy(Rest, 1, P - 1);
  VPart := Copy(Rest, P + 3, MaxInt);
  while (VPart <> '') and ((VPart[1] = ' ') or (VPart[1] = #9)) do
    Delete(VPart, 1, 1);
  Key := Trim(Key);
  Value := Trim(VPart);
  Result := True;
end;

{ Разобрать ``![alt](src)`` (аналог _IMAGE_RE). }
function MatchImage(const S: UnicodeString; out Alt, Src: UnicodeString): Boolean;
var
  P: Integer;
begin
  Result := False;
  Alt := '';
  Src := '';
  if Copy(S, 1, 2) <> '![' then
    Exit;
  P := Pos('](', S);
  if P < 3 then
    Exit;
  if (Length(S) < P + 2) or (S[Length(S)] <> ')') then
    Exit;
  Alt := Copy(S, 3, P - 3);
  Src := Copy(S, P + 2, Length(S) - P - 2);
  Result := True;
end;

{ Разбить строку по разделителю, отбрасывая пустые (аналог
  ``[x.strip() for x in value.split(d) if x.strip()]``). }
procedure SplitTrim(const S: UnicodeString; Delim: WideChar; Dest: TTextList);
var
  I: Integer;
  Cur, T: UnicodeString;
begin
  Dest.Clear;
  Cur := '';
  for I := 1 to Length(S) do
  begin
    if S[I] = Delim then
    begin
      T := Trim(Cur);
      if T <> '' then
        Dest.Add(T);
      Cur := '';
    end
    else
      Cur := Cur + S[I];
  end;
  T := Trim(Cur);
  if T <> '' then
    Dest.Add(T);
end;

{ ===================== TMarkdownToFb2Converter ===================== }

constructor TMarkdownToFb2Converter.Create(const ASource: UnicodeString;
  const ADefaultGenre: UnicodeString; const AProgramUsed: UnicodeString);
begin
  inherited Create;
  FSource := ASource;
  FDefaultGenre := ADefaultGenre;
  FProgramUsed := AProgramUsed;
  FWriter := TFb2Writer.Create;
  FBook := nil;
  Reset;
end;

destructor TMarkdownToFb2Converter.Destroy;
begin
  FreeAndNil(FBook);
  FreeAndNil(FBinaries);
  FreeAndNil(FUsedIds);
  FreeAndNil(FWriter);
  inherited Destroy;
end;

procedure TMarkdownToFb2Converter.Reset;
begin
  FBaseDir := '';
  FHasBaseDir := False;
  FreeAndNil(FBinaries);
  FBinaries := TFb2ObjectList.Create;
  FreeAndNil(FUsedIds);
  FUsedIds := TStringList.Create;
  FUsedIds.CaseSensitive := True;
end;

function TMarkdownToFb2Converter.ReadSource(const Source: UnicodeString;
  out BaseDir: UnicodeString; out HasBaseDir: Boolean): UnicodeString;
var
  FS: TFileStream;
  B: TBytes;
  Raw: RawByteString;
begin
  if FileExists(Source) then
  begin
    BaseDir := ExtractFileDir(Source);
    HasBaseDir := True;
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
    HasBaseDir := False;
    Result := Source;
  end;
end;

function TMarkdownToFb2Converter.ParseMarkdown(const Text: UnicodeString): TFictionBook;
var
  Lines: TTextList;
  Title, CoverHref, DateValue, Lang, HeadingRest: UnicodeString;
  Creators, Genres: TTextList;
  AnnotationItems: TFb2ObjectList;
  Body: TBody;
  Root, Section, Sec: TSection;
  Stack: TSectionStack;
  StackLen, I, J, N, Level: Integer;
  Line, Stripped, MetaKey, MetaValue, Alt, Src, Href: UnicodeString;
  HeadingText, Inner, Nodes: TFb2ObjectList;
  BlockLines, TableLines, PoemLines: TTextList;
  Table: TTable;
  Poem: TPoem;
  Cite: TCite;
  P: TParagraph;
  Img: TImage;

  procedure Push(L: Integer; S: TSection);
  begin
    if StackLen >= Length(Stack) then
      SetLength(Stack, Length(Stack) * 2 + 4);
    Stack[StackLen].Level := L;
    Stack[StackLen].Sec := S;
    Inc(StackLen);
  end;

begin
  Lines := SplitLines(Text);
  Creators := TTextList.Create;
  Genres := TTextList.Create;
  AnnotationItems := TFb2ObjectList.Create;
  Title := 'Untitled';
  CoverHref := '';
  DateValue := '';
  Lang := '';
  Body := TBody.Create;
  Root := TSection.Create;
  SetLength(Stack, 8);
  StackLen := 0;
  Push(0, Root);
  try
    I := 0;
    while I < Lines.Count do
    begin
      Line := Lines[I];
      Stripped := Trim(Line);

      if Stripped = '---' then
      begin
        Inc(I);
        Continue;
      end;

      if MatchHeading(Line, Level, HeadingRest) then
      begin
        HeadingText := ParseInline(HeadingRest);
        if (Level = 1) and (Title = 'Untitled') then
          Title := NodesText(HeadingText)
        else
        begin
          while (StackLen > 1) and (Stack[StackLen - 1].Level >= Level) do
            Dec(StackLen);
          Section := TSection.Create;
          Section.Title := TTitle.Create;
          P := TParagraph.Create;
          FreeAndNil(P.Content);
          P.Content := HeadingText;
          HeadingText := nil;
          Section.Title.Items.Add(P);
          Stack[StackLen - 1].Sec.Sections.Add(Section);
          Push(Level, Section);
        end;
        if HeadingText <> nil then
          HeadingText.Free;
        Inc(I);
        Continue;
      end;

      if MatchMeta(Stripped, MetaKey, MetaValue) then
      begin
        MetaKey := WideLowerCase(MetaKey);
        if MetaKey = 'автор' then
          SplitTrim(MetaValue, ';', Creators)
        else if MetaKey = 'жанры' then
          SplitTrim(MetaValue, ',', Genres)
        else if MetaKey = 'дата' then
          DateValue := MetaValue
        else if MetaKey = 'язык' then
          Lang := MetaValue;
        Inc(I);
        Continue;
      end;

      if MatchImage(Stripped, Alt, Src) then
      begin
        Href := RegisterImage(Src);
        if Href <> '' then
        begin
          if (CoverHref = '') and (Alt <> '') and
            ((WideLowerCase(Alt) = 'обложка') or (WideLowerCase(Alt) = 'cover')) then
            CoverHref := Href
          else
          begin
            Img := TImage.Create;
            Img.Href := Href;
            if Alt <> '' then
              Img.Alt := Alt;
            Stack[StackLen - 1].Sec.Content.Add(Img);
          end;
        end;
        Inc(I);
        Continue;
      end;

      if (Stripped <> '') and (Stripped[1] = '>') then
      begin
        BlockLines := CollectQuote(Lines, I);
        N := BlockLines.Count;
        Inner := ParseBlocks(BlockLines);
        BlockLines.Free;
        if (Root.Sections.Count = 0) and (AnnotationItems.Count = 0) then
        begin
          for J := 0 to Inner.Count - 1 do
            AnnotationItems.Add(Inner[J]);
          Inner.FreeObjects := False;
          Inner.Free;
        end
        else
        begin
          Cite := TCite.Create;
          FreeAndNil(Cite.Items);
          Cite.Items := Inner;
          Stack[StackLen - 1].Sec.Content.Add(Cite);
        end;
        Inc(I, N);
        Continue;
      end;

      if (Stripped <> '') and (Stripped[1] = '|') then
      begin
        TableLines := CollectTable(Lines, I);
        N := TableLines.Count;
        Table := ParseTable(TableLines);
        TableLines.Free;
        if Table <> nil then
          Stack[StackLen - 1].Sec.Content.Add(Table);
        Inc(I, N);
        Continue;
      end;

      if EndsWithTwoSpaces(Line) and (Stripped <> '') then
      begin
        PoemLines := CollectPoem(Lines, I);
        N := PoemLines.Count;
        Poem := ParsePoem(PoemLines);
        PoemLines.Free;
        Stack[StackLen - 1].Sec.Content.Add(Poem);
        Inc(I, N);
        Continue;
      end;

      if Stripped <> '' then
      begin
        Nodes := ParseInline(Stripped);
        P := TParagraph.Create;
        FreeAndNil(P.Content);
        P.Content := Nodes;
        Stack[StackLen - 1].Sec.Content.Add(P);
      end;
      Inc(I);
    end;

    FreeAndNil(Body.Sections);
    Body.Sections := Root.Sections;
    Root.Sections := nil;
    if Root.Content.Count > 0 then
    begin
      Sec := TSection.Create;
      FreeAndNil(Sec.Content);
      Sec.Content := Root.Content;
      Root.Content := nil;
      Body.Sections.Insert(0, Sec);
    end;
    if Body.Sections.Count = 0 then
    begin
      FreeAndNil(Body.Sections);
      Body.Sections := TFb2ObjectList.Create;
      Body.Sections.Add(TSection.Create);
    end;
    Root.Free;

    Result := Assemble(Title, Creators, Genres, AnnotationItems, CoverHref,
      DateValue, Lang, Body);
  finally
    Lines.Free;
    Creators.Free;
    Genres.Free;
  end;
end;

{ ===================== Inline-разметка ===================== }

function TMarkdownToFb2Converter.ParseInline(const Text: UnicodeString): TFb2ObjectList;
var
  Nodes: TFb2ObjectList;
  Buf: UnicodeString;
  I, N, End_, Close: Integer;
  Alt, Src, Href, Label_: UnicodeString;
  Node: TStyleNode;

  procedure Flush;
  begin
    if Buf <> '' then
    begin
      Nodes.Add(TStyleNode.Create(TEXT_NODE_NAME, Buf));
      Buf := '';
    end;
  end;

  function StartsAt(P: Integer; const Tok: UnicodeString): Boolean;
  begin
    Result := (P >= 1) and (P + Length(Tok) - 1 <= N) and
      (Copy(Text, P, Length(Tok)) = Tok);
  end;

  function MakeNode(const Tag: UnicodeString): TStyleNode;
  begin
    Result := TStyleNode.Create(Tag);
    FreeAndNil(Result.Children);
  end;

begin
  Nodes := TFb2ObjectList.Create;
  Buf := '';
  N := Length(Text);
  I := 1;
  while I <= N do
  begin
    if StartsAt(I, '**') then
    begin
      End_ := FindClosing(Text, '**', I + 2);
      if End_ <> -1 then
      begin
        Flush;
        Node := MakeNode('strong');
        Node.Children := ParseInline(Copy(Text, I + 2, End_ - I - 2));
        Nodes.Add(Node);
        I := End_ + 2;
        Continue;
      end;
    end;
    if StartsAt(I, '~~') then
    begin
      End_ := FindClosing(Text, '~~', I + 2);
      if End_ <> -1 then
      begin
        Flush;
        Node := MakeNode('strikethrough');
        Node.Children := ParseInline(Copy(Text, I + 2, End_ - I - 2));
        Nodes.Add(Node);
        I := End_ + 2;
        Continue;
      end;
    end;
    if StartsAt(I, '![') then
    begin
      End_ := PosEx(')', Text, I);
      if End_ <> 0 then
      begin
        Src := SplitImage(Copy(Text, I + 2, End_ - I - 2), Alt);
        Href := RegisterImage(Src);
        Flush;
        if Href <> '' then
        begin
          Node := TStyleNode.Create('image');
          Node.ImageHref := Href;
          Node.ImageAlt := Alt;
          Nodes.Add(Node);
        end
        else
          Nodes.Add(TStyleNode.Create(TEXT_NODE_NAME, Alt));
        I := End_ + 1;
        Continue;
      end;
    end;
    if Text[I] = '[' then
    begin
      End_ := PosEx(']', Text, I);
      if (End_ <> 0) and (End_ + 1 <= N) and (Text[End_ + 1] = '(') then
      begin
        Close := PosEx(')', Text, End_ + 2);
        if Close <> 0 then
        begin
          Label_ := Copy(Text, I + 1, End_ - I - 1);
          Href := Copy(Text, End_ + 2, Close - End_ - 2);
          Flush;
          Node := MakeNode('a');
          Node.Href := Href;
          Node.Children := ParseInline(Label_);
          Nodes.Add(Node);
          I := Close + 1;
          Continue;
        end;
      end;
    end;
    if Text[I] = '`' then
    begin
      End_ := PosEx('`', Text, I + 1);
      if End_ <> 0 then
      begin
        Flush;
        Node := MakeNode('code');
        Node.Children := TFb2ObjectList.Create;
        Node.Children.Add(TStyleNode.Create(TEXT_NODE_NAME,
          Copy(Text, I + 1, End_ - I - 1)));
        Nodes.Add(Node);
        I := End_ + 1;
        Continue;
      end;
    end;
    if StartsAt(I, '<sub>') then
    begin
      End_ := PosEx('</sub>', Text, I);
      if End_ <> 0 then
      begin
        Flush;
        Node := MakeNode('sub');
        Node.Children := ParseInline(Copy(Text, I + 5, End_ - I - 5));
        Nodes.Add(Node);
        I := End_ + 6;
        Continue;
      end;
    end;
    if StartsAt(I, '<sup>') then
    begin
      End_ := PosEx('</sup>', Text, I);
      if End_ <> 0 then
      begin
        Flush;
        Node := MakeNode('sup');
        Node.Children := ParseInline(Copy(Text, I + 5, End_ - I - 5));
        Nodes.Add(Node);
        I := End_ + 6;
        Continue;
      end;
    end;
    if Text[I] = '*' then
    begin
      End_ := FindClosing(Text, '*', I + 1);
      if End_ <> -1 then
      begin
        Flush;
        Node := MakeNode('emphasis');
        Node.Children := ParseInline(Copy(Text, I + 1, End_ - I - 1));
        Nodes.Add(Node);
        I := End_ + 1;
        Continue;
      end;
    end;
    if (Text[I] = '\') and (I + 1 <= N) and
      (Pos(Text[I + 1], '\`*_[]()') > 0) then
    begin
      Buf := Buf + Text[I + 1];
      Inc(I, 2);
      Continue;
    end;
    Buf := Buf + Text[I];
    Inc(I);
  end;
  Flush;
  Result := Nodes;
end;

function TMarkdownToFb2Converter.FindClosing(const Text, Token: UnicodeString;
  Start: Integer): Integer;
var
  Idx, I, Backslashes: Integer;
begin
  I := Start;
  while True do
  begin
    Idx := PosEx(Token, Text, I);
    if Idx = 0 then
      Exit(-1);
    Backslashes := 0;
    I := Idx - 1;
    while (I >= 1) and (Text[I] = '\') do
    begin
      Inc(Backslashes);
      Dec(I);
    end;
    if Backslashes mod 2 = 0 then
      Exit(Idx);
    I := Idx + Length(Token);
  end;
end;

function TMarkdownToFb2Converter.SplitImage(const S: UnicodeString;
  out Alt: UnicodeString): UnicodeString;
var
  Idx: Integer;
begin
  Idx := Pos('](', S);
  if Idx = 0 then
  begin
    Alt := S;
    Result := '';
    Exit;
  end;
  Alt := Copy(S, 1, Idx - 1);
  Result := Copy(S, Idx + 2, MaxInt);
end;

function TMarkdownToFb2Converter.NodesText(Nodes: TFb2ObjectList): UnicodeString;
var
  I: Integer;
  Node: TStyleNode;
begin
  Result := '';
  for I := 0 to Nodes.Count - 1 do
  begin
    Node := TStyleNode(Nodes[I]);
    if Node.Tag = TEXT_NODE_NAME then
      Result := Result + Node.Text
    else
      Result := Result + NodesText(Node.Children);
  end;
end;

{ ===================== Блочные элементы ===================== }

function TMarkdownToFb2Converter.CollectQuote(Lines: TTextList;
  Start: Integer): TTextList;
var
  J: Integer;
  L: UnicodeString;
begin
  Result := TTextList.Create;
  J := Start;
  while (J < Lines.Count) and (Trim(Lines[J]) <> '') and
    (Trim(Lines[J])[1] = '>') do
  begin
    L := Trim(Lines[J]);
    Result.Add(Trim(Copy(L, 2, MaxInt)));
    Inc(J);
  end;
end;

function TMarkdownToFb2Converter.ParseBlocks(Lines: TTextList): TFb2ObjectList;
var
  Blocks: TFb2ObjectList;
  I, N: Integer;
  Stripped: UnicodeString;
  Table: TTable;
  Poem: TPoem;
  TLines, PLines: TTextList;
  P: TParagraph;
begin
  Blocks := TFb2ObjectList.Create;
  I := 0;
  while I < Lines.Count do
  begin
    Stripped := Trim(Lines[I]);
    if Stripped = '' then
    begin
      Inc(I);
      Continue;
    end;
    if Stripped[1] = '|' then
    begin
      TLines := CollectTable(Lines, I);
      N := TLines.Count;
      Table := ParseTable(TLines);
      TLines.Free;
      if Table <> nil then
        Blocks.Add(Table);
      Inc(I, N);
      Continue;
    end;
    if EndsWithTwoSpaces(Lines[I]) and (Stripped <> '') then
    begin
      PLines := CollectPoem(Lines, I);
      N := PLines.Count;
      Poem := ParsePoem(PLines);
      PLines.Free;
      Blocks.Add(Poem);
      Inc(I, N);
      Continue;
    end;
    P := TParagraph.Create;
    FreeAndNil(P.Content);
    P.Content := ParseInline(Stripped);
    Blocks.Add(P);
    Inc(I);
  end;
  Result := Blocks;
end;

function TMarkdownToFb2Converter.CollectTable(Lines: TTextList;
  Start: Integer): TTextList;
var
  J: Integer;
begin
  Result := TTextList.Create;
  J := Start;
  while (J < Lines.Count) and (Trim(Lines[J]) <> '') and
    (Trim(Lines[J])[1] = '|') do
  begin
    Result.Add(Trim(Lines[J]));
    Inc(J);
  end;
end;

function TMarkdownToFb2Converter.IsSeparator(Cells: TTextList): Boolean;
var
  I, J: Integer;
  C: WideChar;
  S: UnicodeString;
  HasDash, Ok: Boolean;
begin
  Result := False;
  if Cells.Count = 0 then
    Exit;
  for I := 0 to Cells.Count - 1 do
  begin
    S := Cells[I];
    HasDash := False;
    Ok := True;
    for J := 1 to Length(S) do
    begin
      C := S[J];
      if (C <> '-') and (C <> ':') and (C <> ' ') then
      begin
        Ok := False;
        Break;
      end;
      if C = '-' then
        HasDash := True;
    end;
    if (not Ok) or (not HasDash) then
      Exit;
  end;
  Result := True;
end;

function TMarkdownToFb2Converter.ParseTable(Lines: TTextList): TTable;
var
  Rows: array of TTextList;
  RowCount, I, J: Integer;
  Cells: TTextList;
  Line, Cur: UnicodeString;
  Row: TTableRow;
  Cell: TTableCell;
begin
  Result := nil;
  SetLength(Rows, 0);
  RowCount := 0;
  for I := 0 to Lines.Count - 1 do
  begin
    Line := Trim(Lines[I]);
    while (Line <> '') and (Line[1] = '|') do
      Delete(Line, 1, 1);
    while (Line <> '') and (Line[Length(Line)] = '|') do
      Delete(Line, Length(Line), 1);
    Cells := TTextList.Create;
    Cur := '';
    for J := 1 to Length(Line) do
      if Line[J] = '|' then
      begin
        Cells.Add(Trim(Cur));
        Cur := '';
      end
      else
        Cur := Cur + Line[J];
    Cells.Add(Trim(Cur));
    if IsSeparator(Cells) then
      Cells.Free
    else
    begin
      if RowCount >= Length(Rows) then
        SetLength(Rows, Length(Rows) * 2 + 4);
      Rows[RowCount] := Cells;
      Inc(RowCount);
    end;
  end;

  if RowCount = 0 then
  begin
    SetLength(Rows, 0);
    Exit;
  end;

  Result := TTable.Create;
  for I := 0 to RowCount - 1 do
  begin
    Row := TTableRow.Create;
    for J := 0 to Rows[I].Count - 1 do
    begin
      Cell := TTableCell.Create('td');
      FreeAndNil(Cell.Children);
      Cell.Children := ParseInline(Rows[I][J]);
      Cell.IsHeader := (I = 0);
      Row.Cells.Add(Cell);
    end;
    Result.Rows.Add(Row);
  end;
  for I := 0 to RowCount - 1 do
    Rows[I].Free;
end;

function TMarkdownToFb2Converter.CollectPoem(Lines: TTextList;
  Start: Integer): TTextList;
var
  J: Integer;
begin
  Result := TTextList.Create;
  J := Start;
  while (J < Lines.Count) and EndsWithTwoSpaces(Lines[J]) and
    (Trim(Lines[J]) <> '') do
  begin
    Result.Add(UTrimRight(Lines[J]));
    Inc(J);
  end;
end;

function TMarkdownToFb2Converter.ParsePoem(Lines: TTextList): TPoem;
var
  Stanza: TStanza;
  I: Integer;
  P: TParagraph;
begin
  Result := TPoem.Create;
  Stanza := TStanza.Create;
  for I := 0 to Lines.Count - 1 do
    if Trim(Lines[I]) <> '' then
    begin
      P := TParagraph.Create;
      FreeAndNil(P.Content);
      P.Content := ParseInline(Trim(Lines[I]));
      Stanza.Verses.Add(P);
    end;
  Result.Items.Add(Stanza);
end;

{ ===================== Изображения ===================== }

{ base64-кодирование байтов (аналог base64.b64encode). }
function B64Encode(const Data: TBytes): UnicodeString;
const
  ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
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
    Result := Result + ALPHABET[(Triple shr 18) and $3F + 1];
    Result := Result + ALPHABET[(Triple shr 12) and $3F + 1];
    if I + 1 < L then
      Result := Result + ALPHABET[(Triple shr 6) and $3F + 1]
    else
      Result := Result + '=';
    if I + 2 < L then
      Result := Result + ALPHABET[Triple and $3F + 1]
    else
      Result := Result + '=';
    Inc(I, 3);
  end;
end;

function TMarkdownToFb2Converter.RegisterImage(const Src: UnicodeString): UnicodeString;
var
  Path, Ext, Name, Fb2Id: UnicodeString;
  FS: TFileStream;
  Bytes: TBytes;
  B: TBinary;
begin
  Result := '';
  if (Src = '') or (not FHasBaseDir) then
    Exit;
  Path := FBaseDir + PathDelim + StringReplace(Src, '/', PathDelim,
    [rfReplaceAll]);
  if not FileExists(Path) then
    Exit;
  FS := TFileStream.Create(Path, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Bytes, FS.Size);
    if FS.Size > 0 then
      FS.ReadBuffer(Bytes[0], FS.Size);
  finally
    FS.Free;
  end;
  Ext := ExtractFileExt(Path);
  Name := ExtractFileName(Path);
  Fb2Id := UniqueId(Name);
  B := TBinary.Create;
  B.Id := Fb2Id;
  B.ContentType := ContentTypeByExt(Ext);
  B.Data := B64Encode(Bytes);
  FBinaries.Add(B);
  Result := '#' + Fb2Id;
end;

function TMarkdownToFb2Converter.UniqueId(const Name: UnicodeString): UnicodeString;
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
  Stem := ChangeFileExt(Name, '');
  Suffix := ExtractFileExt(Name);
  Counter := 1;
  while FUsedIds.IndexOf(Format('%s_%d%s', [Stem, Counter, Suffix])) >= 0 do
    Inc(Counter);
  Result := Format('%s_%d%s', [Stem, Counter, Suffix]);
  FUsedIds.Add(Result);
end;

{ ===================== Жанры и авторы ===================== }

function TMarkdownToFb2Converter.MatchGenres(Subjects: TTextList): TTextList;
var
  I: Integer;
  Subject, Code: UnicodeString;
begin
  Result := TTextList.Create;
  for I := 0 to Subjects.Count - 1 do
  begin
    Subject := Trim(Subjects[I]);
    if Subject = '' then
      Continue;
    if GenreCodeExists(Subject) then
      Result.Add(Subject)
    else
    begin
      Code := GenreCodeByName(Subject);
      if Code <> '' then
        Result.Add(Code);
    end;
  end;
  if Result.Count = 0 then
    Result.Add(FDefaultGenre);
end;

function TMarkdownToFb2Converter.AnnotationOf(Items: TFb2ObjectList): TAnnotation;
begin
  Result := nil;
  if (Items = nil) or (Items.Count = 0) then
    Exit;
  Result := TAnnotation.Create;
  FreeAndNil(Result.Items);
  Result.Items := Items;
end;

function IsDigits(const S: UnicodeString; Start, Count: Integer): Boolean;
var
  I: Integer;
begin
  Result := False;
  if Start + Count - 1 > Length(S) then
    Exit;
  for I := Start to Start + Count - 1 do
    if (S[I] < '0') or (S[I] > '9') then
      Exit;
  Result := True;
end;

function MatchDatePrefix(const S: UnicodeString): UnicodeString;
begin
  Result := '';
  if not IsDigits(S, 1, 4) then
    Exit;
  if (Length(S) >= 10) and (S[5] = '-') and IsDigits(S, 6, 2) and
    (S[8] = '-') and IsDigits(S, 9, 2) then
    Result := Copy(S, 1, 10)
  else
    Result := Copy(S, 1, 4);
end;

function TMarkdownToFb2Converter.DateFieldOf(const Value: UnicodeString): TDateField;
var
  M: UnicodeString;
begin
  Result := nil;
  if Value = '' then
    Exit;
  Result := TDateField.Create;
  Result.Value := Value;
  M := MatchDatePrefix(Value);
  if M <> '' then
    Result.DateValue := M;
end;

function TMarkdownToFb2Converter.SplitAuthor(const Name: UnicodeString): TAuthor;
var
  S, Last, First: UnicodeString;
  P, I: Integer;
  Parts, Mid: TTextList;
begin
  Result := nil;
  S := Trim(Name);
  P := Pos(',', S);
  if P > 0 then
  begin
    Last := Trim(Copy(S, 1, P - 1));
    First := Trim(Copy(S, P + 1, MaxInt));
    Result := TAuthor.Create;
    Result.LastName := Last;
    if First <> '' then
      Result.FirstName := First;
    Exit;
  end;
  Parts := SplitWords(S);
  try
    if Parts.Count = 1 then
    begin
      Result := TAuthor.Create;
      Result.LastName := Parts[0];
    end
    else if Parts.Count = 2 then
    begin
      Result := TAuthor.Create;
      Result.FirstName := Parts[0];
      Result.LastName := Parts[1];
    end
    else if Parts.Count >= 3 then
    begin
      Result := TAuthor.Create;
      Result.FirstName := Parts[0];
      Mid := TTextList.Create;
      try
        for I := 1 to Parts.Count - 2 do
          Mid.Add(Parts[I]);
        Result.MiddleName := JoinText(Mid, ' ');
      finally
        Mid.Free;
      end;
      Result.LastName := Parts[Parts.Count - 1];
    end
    else
    begin
      Result := TAuthor.Create;
      Result.LastName := '';
    end;
  finally
    Parts.Free;
  end;
end;

{ ===================== Сборка FictionBook ===================== }

function TMarkdownToFb2Converter.Assemble(const Title: UnicodeString;
  Creators, Genres: TTextList; AnnotationItems: TFb2ObjectList;
  const CoverHref, DateValue, Lang: UnicodeString; Body: TBody): TFictionBook;
var
  TI: TTitleInfo;
  DI: TDocumentInfo;
  Desc: TDescription;
  FB: TFictionBook;
  Matched: TTextList;
  I: Integer;
  G: TGenre;
  CP: TCoverPage;
  Img: TInlineImage;
  A: TAuthor;
  D: TDateField;
  L: UnicodeString;
begin
  TI := TTitleInfo.Create;

  Matched := MatchGenres(Genres);
  FreeAndNil(TI.Genres);
  TI.Genres := TFb2ObjectList.Create;
  for I := 0 to Matched.Count - 1 do
  begin
    G := TGenre.Create;
    G.Value := Matched[I];
    TI.Genres.Add(G);
  end;
  Matched.Free;

  FreeAndNil(TI.Authors);
  TI.Authors := TFb2ObjectList.Create;
  for I := 0 to Creators.Count - 1 do
    TI.Authors.Add(SplitAuthor(Creators[I]));

  FreeAndNil(TI.BookTitle);
  TI.BookTitle := TTextField.Create;
  TI.BookTitle.Value := Title;

  FreeAndNil(TI.Annotation);
  TI.Annotation := AnnotationOf(AnnotationItems);

  FreeAndNil(TI.Date);
  TI.Date := DateFieldOf(DateValue);

  if CoverHref <> '' then
  begin
    CP := TCoverPage.Create;
    Img := TInlineImage.Create;
    Img.Href := CoverHref;
    CP.Images.Add(Img);
    FreeAndNil(TI.Coverpage);
    TI.Coverpage := CP;
  end;

  if Lang <> '' then
    L := Lang
  else
    L := 'ru';
  TI.Lang := L;

  DI := TDocumentInfo.Create;
  A := TAuthor.Create;
  A.Nickname := 'pyFB2';
  DI.Authors.Add(A);
  DI.ProgramUsed := TTextField.Create;
  DI.ProgramUsed.Value := FProgramUsed;
  D := TDateField.Create;
  if DateValue <> '' then
    D.Value := DateValue
  else
    D.Value := FormatDateTime('yyyy-mm-dd', Now);
  DI.Date := D;
  DI.Id := NewGuidHex;
  DI.Version := 1.0;
  DI.HasVersion := True;

  Desc := TDescription.Create;
  Desc.TitleInfo := TI;
  Desc.DocumentInfo := DI;

  FB := TFictionBook.Create;
  FB.Description := Desc;
  FB.Bodies.Add(Body);
  FreeAndNil(FB.Binaries);
  FB.Binaries := FBinaries;
  FBinaries := nil;

  Result := FB;
end;

{ ===================== Публичный API ===================== }

function TMarkdownToFb2Converter.Convert(const Source: UnicodeString): TFictionBook;
var
  Text, BaseDir: UnicodeString;
  HasBaseDir: Boolean;
begin
  if Source <> '' then
    FSource := Source;
  if FSource = '' then
    raise EFb2ConversionError.Create('Не задан источник Markdown (source)');

  Reset;
  Text := ReadSource(FSource, BaseDir, HasBaseDir);
  FBaseDir := BaseDir;
  FHasBaseDir := HasBaseDir;
  FreeAndNil(FBook);
  FBook := ParseMarkdown(Text);
  Result := FBook;
end;

function TMarkdownToFb2Converter.ToXml(Book: TFictionBook): UnicodeString;
begin
  if Book = nil then
    Book := FBook;
  if Book = nil then
    Book := Convert;
  Result := FWriter.ToXML(Book);
end;

function TMarkdownToFb2Converter.Write(const Source: UnicodeString;
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






