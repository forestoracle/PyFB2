unit fb2_to_mobi;
{ Преобразование книги FB2 в MOBI (Mobipocket/Kindle KF7) — перевод fb2_to_mobi.py.

  Собирает файл MOBI из структур TFictionBook:
      * текст размечается простым HTML (Mobi7) и сжимается алгоритмом PalmDOC;
      * файл упаковывается в базу данных Palm (PDB): запись 0 — заголовки
        PalmDOC, MOBI и EXTH (метаданные), далее текстовые записи, затем
        изображения;
      * обложка помечается через EXTH-записи coveroffset/thumboffset.

  Промежуточное представление — TMobiBook; сериализуется в байты (ToBytes) или
  пишется в файл (Write). Обратное преобразование — mobi_to_fb2.pas.

  Пример:
      C := TFb2ToMobiConverter.Create;
      try
        C.Write('book.fb2', 'book.mobi');
      finally
        C.Free;
      end; }

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Classes, SysUtils, fgl,
  fb2_structures, fb2_parser, fb2_errors, fb2_images, fb2_files;

const
  { Размер текстового блока PalmDOC/MOBI. }
  TEXT_RECORD_SIZE = 4096;

  { Максимальный размер записи PDB (картинки больше не помещаются). }
  MAX_RECORD_SIZE = 65536;

  { Компрессия: 1 — без сжатия, 2 — PalmDOC. }
  COMPRESSION_NONE = 1;
  COMPRESSION_PALMDOC = 2;

  { Длина MOBI-заголовка (версия 6). }
  MOBI_HEADER_LENGTH = 232;

  { Кодировка текста MOBI (UTF-8). }
  ENCODING_UTF8 = 65001;

  { Значения EXTH-записей. }
  EXTH_AUTHOR = 100;
  EXTH_PUBLISHER = 101;
  EXTH_DESCRIPTION = 103;
  EXTH_SUBJECT = 105;
  EXTH_PUBLISHING_DATE = 106;
  EXTH_COVER_OFFSET = 201;
  EXTH_THUMB_OFFSET = 202;
  EXTH_CDE_TYPE = 503;
  EXTH_LANGUAGE = 524;

type
  { Изображение, встраиваемое в MOBI. }
  TMobiImage = class
  public
    FileName: UnicodeString;
    MediaType: UnicodeString;
    Data: TBytes;
  end;

  TMobiImageList = specialize TFPGObjectList<TMobiImage>;

  { Набор байтовых блоков (записи PDB). }
  TBytesArray = array of TBytes;

  { Промежуточное представление документа MOBI. }
  TMobiBook = class
  public
    Title: UnicodeString;
    Authors: TTextList;
    Language: UnicodeString;
    Description: UnicodeString;
    Genres: TTextList;
    Html: UnicodeString;
    Images: TMobiImageList;
    CoverIndex: Integer;        { -1 — нет }
    constructor Create;
    destructor Destroy; override;
  end;

  { Преобразование книги FB2 в MOBI. }
  TFb2ToMobiConverter = class
  private
    FParser: TFb2Parser;
    FCompress: Boolean;
    FSource: UnicodeString;
    FBook: TMobiBook;
    FImages: TMobiImageList;
    FImageIndex: TStringList;    { id -> индекс в FImages }

    procedure Reset;
    function BookTitle(TI: TTitleInfo): UnicodeString;
    function CreatorList(TI: TTitleInfo): TTextList;
    function LanguageOf(TI: TTitleInfo): UnicodeString;
    function GenreList(TI: TTitleInfo): TTextList;
    function AnnotationText(TI: TTitleInfo): UnicodeString;

    procedure CollectImages(Binaries: TFb2ObjectList);
    function ImageNumber(const Href: UnicodeString): Integer;
    function CoverIndex(TI: TTitleInfo): Integer;

    function RenderHtml(Bodies: TFb2ObjectList): UnicodeString;
    function RenderBody(Body: TBody): UnicodeString;
    function RenderSection(Section: TSection; Level: Integer): UnicodeString;
    function RenderTitle(Title: TTitle; Level: Integer): UnicodeString;
    function RenderEpigraph(E: TEpigraph): UnicodeString;
    function RenderBlock(Block: TFb2Object): UnicodeString;
    function Paragraph(Nodes: TFb2ObjectList): UnicodeString;
    function RenderPoem(P: TPoem): UnicodeString;
    function RenderStanza(S: TStanza): UnicodeString;
    function RenderCite(C: TCite): UnicodeString;
    function RenderTable(T: TTable): UnicodeString;
    function RenderMarkup(Nodes: TFb2ObjectList): UnicodeString;
    function Link(Node: TStyleNode): UnicodeString;
    function ImageTagInline(Node: TStyleNode): UnicodeString;
    function ImageTag(Img: TImage): UnicodeString;

    procedure TextRecords(const Text: TBytes; out Records: TBytesArray;
      out Compression: Integer);
    function RecordZero(Book: TMobiBook; Compression, TextLength,
      TextRecordsCount, FirstImageIndex: Integer): TBytes;
    function Exth(Book: TMobiBook): TBytes;
    function PalmDatabase(const Name: UnicodeString;
      const Records: TBytesArray): TBytes;
  public
    constructor Create(AParser: TFb2Parser = nil; Compress: Boolean = True);
    destructor Destroy; override;

    { Прочитать FB2 и вернуть структуру TMobiBook (владелец — конвертер). }
    function Convert(const Source: UnicodeString = ''): TMobiBook;

    { Сериализовать книгу в MOBI. Book = nil — результат Convert. }
    function ToBytes(Book: TMobiBook = nil): TBytes;

    { Преобразовать FB2 в файл MOBI и вернуть путь к результату. }
    function Write(const Source: UnicodeString;
      const Output: UnicodeString = ''): UnicodeString;

    property Book: TMobiBook read FBook;
  end;

{ Сжать блок данных (до 4096 байт) алгоритмом PalmDOC (LZ77). }
function PalmDocCompress(const Data: TBytes): TBytes;

implementation

{ ===================== Служебные помощники ===================== }

{ Экранирование HTML (аналог html.escape с quote=True). }
function HtmlEscape(const S: UnicodeString): UnicodeString;
var
  I: Integer;
  C: WideChar;
begin
  Result := '';
  for I := 1 to Length(S) do
  begin
    C := S[I];
    if C = '&' then
      Result := Result + '&amp;'
    else if C = '<' then
      Result := Result + '&lt;'
    else if C = '>' then
      Result := Result + '&gt;'
    else if C = '"' then
      Result := Result + '&quot;'
    else if C = '''' then
      Result := Result + '&#x27;'
    else
      Result := Result + C;
  end;
end;

{ Имя автора: «Имя Отчество Фамилия» либо никнейм. }
function AuthorTextOf(A: TAuthor): UnicodeString;
var
  Parts: TTextList;
begin
  Result := '';
  if A = nil then
    Exit;
  Parts := TTextList.Create;
  try
    if UTrim(A.FirstName) <> '' then
      Parts.Add(UTrim(A.FirstName));
    if UTrim(A.MiddleName) <> '' then
      Parts.Add(UTrim(A.MiddleName));
    if UTrim(A.LastName) <> '' then
      Parts.Add(UTrim(A.LastName));
    Result := JoinText(Parts, ' ');
  finally
    Parts.Free;
  end;
  if Result = '' then
    Result := UTrim(A.Nickname);
end;

{ Простой текст из узлов разметки (аналог _markup_text). }
function MarkupPlainText(Nodes: TFb2ObjectList): UnicodeString;
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
      Result := Result + MarkupPlainText(Node.Children);
  end;
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

{ LCID (Microsoft) для распространённых языков. }
function LocaleFor(const Lang: UnicodeString): LongWord;
begin
  if Lang = 'ru' then
    Result := 1049
  else if Lang = 'en' then
    Result := 1033
  else if Lang = 'uk' then
    Result := 1058
  else if Lang = 'de' then
    Result := 1031
  else if Lang = 'fr' then
    Result := 1036
  else if Lang = 'es' then
    Result := 1034
  else
    Result := 1033;
end;

{ Inline-теги разметки FB2 -> HTML. '' — не тег разметки. }
function MarkupTag(const Tag: UnicodeString): UnicodeString;
begin
  if Tag = 'strong' then
    Result := 'b'
  else if Tag = 'emphasis' then
    Result := 'i'
  else if Tag = 'code' then
    Result := 'tt'
  else if Tag = 'strikethrough' then
    Result := 's'
  else if Tag = 'sub' then
    Result := 'sub'
  else if Tag = 'sup' then
    Result := 'sup'
  else
    Result := '';
end;

{ ===================== base64 / big-endian ===================== }

const
  B64_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

{ base64-декодирование (аналог base64.b64decode). }
function Base64DecodeString(const S: UnicodeString): TBytes;
var
  I, N, Bits, V: Integer;
  Acc: LongWord;
  C: WideChar;
begin
  SetLength(Result, (Length(S) div 4 + 1) * 3);
  N := 0;
  Acc := 0;
  Bits := 0;
  for I := 1 to Length(S) do
  begin
    C := S[I];
    if C = '=' then
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

procedure PutBE32(var B: TBytes; Ofs: Integer; V: LongWord);
begin
  B[Ofs] := Byte((V shr 24) and $FF);
  B[Ofs + 1] := Byte((V shr 16) and $FF);
  B[Ofs + 2] := Byte((V shr 8) and $FF);
  B[Ofs + 3] := Byte(V and $FF);
end;

procedure PutBE16(var B: TBytes; Ofs: Integer; V: Word);
begin
  B[Ofs] := Byte((V shr 8) and $FF);
  B[Ofs + 1] := Byte(V and $FF);
end;

function BE32Bytes(V: LongWord): TBytes;
begin
  SetLength(Result, 4);
  PutBE32(Result, 0, V);
end;

function BE16Bytes(V: Word): TBytes;
begin
  SetLength(Result, 2);
  PutBE16(Result, 0, V);
end;

function ConcatBytes(const A, B: TBytes): TBytes;
var
  LA: Integer;
begin
  LA := Length(A);
  SetLength(Result, LA + Length(B));
  if LA > 0 then
    Move(A[0], Result[0], LA);
  if Length(B) > 0 then
    Move(B[0], Result[LA], Length(B));
end;

function UTF8Bytes(const S: UnicodeString): TBytes;
var
  U: UTF8String;
begin
  U := UTF8Encode(S);
  SetLength(Result, Length(U));
  if Length(U) > 0 then
    Move(U[1], Result[0], Length(U));
end;

function ZeroPad(N: Integer): TBytes;
begin
  SetLength(Result, N);
  if N > 0 then
    FillChar(Result[0], N, 0);
end;

{ ===================== PalmDOC ===================== }

function PalmDocCompress(const Data: TBytes): TBytes;
var
  Out_: TBytes;
  OutLen, LitLen, Size, Index, I, C, Candidate, Ln, BestLen, BestDist,
    Start, Value: Integer;
  Lit: TBytes;

  procedure Flush;
  var
    K: Integer;
  begin
    while LitLen > 0 do
    begin
      if LitLen >= 8 then
        C := 8
      else
        C := LitLen;
      if (C = 1) and ((Lit[0] = 0) or ((Lit[0] >= $09) and (Lit[0] <= $7F))) then
      begin
        Out_[OutLen] := Lit[0];
        Inc(OutLen);
      end
      else
      begin
        Out_[OutLen] := Byte(C);
        Inc(OutLen);
        for K := 0 to C - 1 do
        begin
          Out_[OutLen] := Lit[K];
          Inc(OutLen);
        end;
      end;
      for K := 0 to LitLen - C - 1 do
        Lit[K] := Lit[K + C];
      Dec(LitLen, C);
    end;
  end;

begin
  Size := Length(Data);
  SetLength(Out_, Size + Size div 4 + 32);
  OutLen := 0;
  SetLength(Lit, 8);
  LitLen := 0;
  Index := 0;
  while Index < Size do
  begin
    if (Data[Index] = $20) and (Index + 1 < Size) and
      (Data[Index + 1] >= $40) and (Data[Index + 1] <= $7F) then
    begin
      Flush;
      Out_[OutLen] := Data[Index + 1] xor $80;
      Inc(OutLen);
      Inc(Index, 2);
      Continue;
    end;

    BestLen := 0;
    BestDist := 0;
    Start := Index - 2047;
    if Start < 0 then
      Start := 0;
    Candidate := Start;
    while Candidate < Index do
    begin
      Ln := 0;
      while (Ln < 10) and (Index + Ln < Size) and
        (Data[Candidate + Ln] = Data[Index + Ln]) do
        Inc(Ln);
      if Ln > BestLen then
      begin
        BestLen := Ln;
        BestDist := Index - Candidate;
        if BestLen = 10 then
          Break;
      end;
      Inc(Candidate);
    end;

    if BestLen >= 3 then
    begin
      Flush;
      Value := ((BestDist shl 3) or (BestLen - 3)) and $3FFF;
      Out_[OutLen] := Byte($80 or (Value shr 8));
      Inc(OutLen);
      Out_[OutLen] := Byte(Value and $FF);
      Inc(OutLen);
      Inc(Index, BestLen);
      Continue;
    end;

    Lit[LitLen] := Data[Index];
    Inc(LitLen);
    Inc(Index);
    if LitLen = 8 then
      Flush;
  end;
  Flush;
  SetLength(Result, OutLen);
  if OutLen > 0 then
    Move(Out_[0], Result[0], OutLen);
end;

{ ===================== TMobiBook ===================== }

constructor TMobiBook.Create;
begin
  inherited Create;
  Title := 'Untitled';
  Authors := TTextList.Create;
  Language := 'ru';
  Description := '';
  Genres := TTextList.Create;
  Html := '';
  Images := TMobiImageList.Create(True);
  CoverIndex := -1;
end;

destructor TMobiBook.Destroy;
begin
  FreeAndNil(Authors);
  FreeAndNil(Genres);
  FreeAndNil(Images);
  inherited Destroy;
end;

{ ===================== TFb2ToMobiConverter ===================== }

constructor TFb2ToMobiConverter.Create(AParser: TFb2Parser; Compress: Boolean);
begin
  inherited Create;
  if AParser <> nil then
    FParser := AParser
  else
    FParser := TFb2Parser.Create;
  FCompress := Compress;
  FSource := '';
  FBook := nil;
  FImages := nil;
  FImageIndex := TStringList.Create;
  FImageIndex.CaseSensitive := True;
  FImageIndex.NameValueSeparator := '=';
  Reset;
end;

destructor TFb2ToMobiConverter.Destroy;
begin
  FreeAndNil(FBook);
  FreeAndNil(FImages);
  FreeAndNil(FImageIndex);
  FreeAndNil(FParser);
  inherited Destroy;
end;

procedure TFb2ToMobiConverter.Reset;
begin
  FreeAndNil(FImages);
  FImages := TMobiImageList.Create(True);
  FImageIndex.Clear;
end;

{ ===================== Метаданные ===================== }

function TFb2ToMobiConverter.BookTitle(TI: TTitleInfo): UnicodeString;
begin
  if (TI <> nil) and (TI.BookTitle <> nil) and (TI.BookTitle.Value <> '') then
    Result := TI.BookTitle.Value
  else
    Result := 'Untitled';
end;

function TFb2ToMobiConverter.CreatorList(TI: TTitleInfo): TTextList;
var
  I: Integer;
  S: UnicodeString;
begin
  Result := TTextList.Create;
  if TI = nil then
    Exit;
  for I := 0 to TI.Authors.Count - 1 do
  begin
    S := AuthorTextOf(TAuthor(TI.Authors[I]));
    if S <> '' then
      Result.Add(S);
  end;
end;

function TFb2ToMobiConverter.LanguageOf(TI: TTitleInfo): UnicodeString;
begin
  if (TI <> nil) and (TI.Lang <> '') then
    Result := TI.Lang
  else
    Result := 'ru';
end;

function TFb2ToMobiConverter.GenreList(TI: TTitleInfo): TTextList;
var
  I: Integer;
begin
  Result := TTextList.Create;
  if TI = nil then
    Exit;
  for I := 0 to TI.Genres.Count - 1 do
    if TGenre(TI.Genres[I]).Value <> '' then
      Result.Add(TGenre(TI.Genres[I]).Value);
end;

function TFb2ToMobiConverter.AnnotationText(TI: TTitleInfo): UnicodeString;
var
  Paragraphs: TTextList;
  I: Integer;
  Item: TFb2Object;
  S: UnicodeString;
begin
  Result := '';
  if (TI = nil) or (TI.Annotation = nil) then
    Exit;
  Paragraphs := TTextList.Create;
  try
    for I := 0 to TI.Annotation.Items.Count - 1 do
    begin
      Item := TI.Annotation.Items[I];
      if Item is TParagraph then
        S := MarkupPlainText(TParagraph(Item).Content)
      else if Item is TSubtitle then
        S := MarkupPlainText(TSubtitle(Item).Content)
      else
        S := '';
      if S <> '' then
        Paragraphs.Add(S);
    end;
    Result := JoinText(Paragraphs, #10);
  finally
    Paragraphs.Free;
  end;
end;

{ ===================== Изображения ===================== }

procedure TFb2ToMobiConverter.CollectImages(Binaries: TFb2ObjectList);
var
  I: Integer;
  Bin: TBinary;
  Data: TBytes;
  MediaType, Ext, Identifier: UnicodeString;
  Img: TMobiImage;
begin
  if Binaries = nil then
    Exit;
  for I := 0 to Binaries.Count - 1 do
  begin
    Bin := TBinary(Binaries[I]);
    if (Bin.ContentType <> '') and
      (Copy(LowerCase(Bin.ContentType), 1, 9) = 'image/svg') then
      Continue;
    try
      Data := Base64DecodeString(Bin.Data);
    except
      Continue;
    end;
    if (Length(Data) = 0) or (Length(Data) > MAX_RECORD_SIZE) then
      Continue;
    MediaType := DetectImageType(Data, Ext);
    Identifier := Bin.Id;
    if Identifier = '' then
      Identifier := 'image';
    while (Identifier <> '') and (Identifier[1] = '#') do
      Delete(Identifier, 1, 1);
    MapSet(FImageIndex, Identifier, IntToStr(FImages.Count));
    Img := TMobiImage.Create;
    Img.FileName := Identifier;
    Img.MediaType := MediaType;
    Img.Data := Data;
    FImages.Add(Img);
  end;
end;

function TFb2ToMobiConverter.ImageNumber(const Href: UnicodeString): Integer;
var
  Key, S: UnicodeString;
  Idx: Integer;
begin
  Result := -1;
  if Href = '' then
    Exit;
  Key := Href;
  while (Key <> '') and (Key[1] = '#') do
    Delete(Key, 1, 1);
  S := MapGet(FImageIndex, Key);
  if S = '' then
    Exit;
  Idx := StrToIntDef(S, -1);
  if Idx >= 0 then
    Result := Idx + 1;
end;

function TFb2ToMobiConverter.CoverIndex(TI: TTitleInfo): Integer;
var
  I, N: Integer;
begin
  Result := -1;
  if (TI = nil) or (TI.Coverpage = nil) then
    Exit;
  for I := 0 to TI.Coverpage.Images.Count - 1 do
  begin
    N := ImageNumber(TImage(TI.Coverpage.Images[I]).Href);
    if N <> -1 then
      Exit(N - 1);
  end;
end;

{ ===================== HTML (Mobi7) ===================== }

{ Соединить непустые части (аналог "\n".join(part for part in parts if part)). }
function JoinParts(Parts: TTextList; const Sep: UnicodeString): UnicodeString;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to Parts.Count - 1 do
    if Parts[I] <> '' then
    begin
      if Result <> '' then
        Result := Result + Sep;
      Result := Result + Parts[I];
    end;
end;

function TFb2ToMobiConverter.RenderHtml(Bodies: TFb2ObjectList): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
begin
  Parts := TTextList.Create;
  try
    Parts.Add('<html><head><guide>');
    Parts.Add('<reference type="toc" title="Оглавление" filepos="0000000000"/>');
    Parts.Add('</guide></head><body>');
    if Bodies <> nil then
      for I := 0 to Bodies.Count - 1 do
        Parts.Add(RenderBody(TBody(Bodies[I])));
    Parts.Add('</body></html>');
    Result := JoinParts(Parts, #10);
  finally
    Parts.Free;
  end;
end;

function TFb2ToMobiConverter.RenderBody(Body: TBody): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
begin
  Parts := TTextList.Create;
  try
    if Body.Image <> nil then
      Parts.Add(ImageTag(Body.Image));
    if Body.Title <> nil then
      Parts.Add(RenderTitle(Body.Title, 1));
    for I := 0 to Body.Epigraphs.Count - 1 do
      Parts.Add(RenderEpigraph(TEpigraph(Body.Epigraphs[I])));
    for I := 0 to Body.Sections.Count - 1 do
      Parts.Add(RenderSection(TSection(Body.Sections[I]), 1));
    Result := JoinParts(Parts, #10);
  finally
    Parts.Free;
  end;
end;

function TFb2ToMobiConverter.RenderSection(Section: TSection;
  Level: Integer): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
begin
  Parts := TTextList.Create;
  try
    if Section.Title <> nil then
      Parts.Add(RenderTitle(Section.Title, Level));
    for I := 0 to Section.Epigraphs.Count - 1 do
      Parts.Add(RenderEpigraph(TEpigraph(Section.Epigraphs[I])));
    if Section.Image <> nil then
      Parts.Add(ImageTag(Section.Image));
    for I := 0 to Section.Content.Count - 1 do
      Parts.Add(RenderBlock(Section.Content[I]));
    for I := 0 to Section.Sections.Count - 1 do
      Parts.Add(RenderSection(TSection(Section.Sections[I]), Level + 1));
    Result := JoinParts(Parts, #10);
  finally
    Parts.Free;
  end;
end;

function TFb2ToMobiConverter.RenderTitle(Title: TTitle;
  Level: Integer): UnicodeString;
var
  Parts: TTextList;
  L, I: Integer;
  Tag, Text, Inner: UnicodeString;
begin
  Result := '';
  if Title = nil then
    Exit;
  L := Level;
  if L < 1 then
    L := 1;
  if L > 6 then
    L := 6;
  Tag := 'h' + IntToStr(L);
  Parts := TTextList.Create;
  try
    for I := 0 to Title.Items.Count - 1 do
      if Title.Items[I] is TParagraph then
      begin
        Text := RenderMarkup(TParagraph(Title.Items[I]).Content);
        if Text <> '' then
          Parts.Add(Text);
      end;
    Inner := JoinParts(Parts, ' ');
    if Inner <> '' then
      Result := '<' + Tag + '>' + Inner + '</' + Tag + '>';
  finally
    Parts.Free;
  end;
end;

function TFb2ToMobiConverter.RenderEpigraph(E: TEpigraph): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
  Rendered, Inner: UnicodeString;
begin
  Result := '';
  if E = nil then
    Exit;
  Parts := TTextList.Create;
  try
    for I := 0 to E.Items.Count - 1 do
    begin
      Rendered := RenderBlock(E.Items[I]);
      if Rendered <> '' then
        Parts.Add(Rendered);
    end;
    for I := 0 to E.TextAuthor.Count - 1 do
      Parts.Add('<p><i>' +
        RenderMarkup(TParagraph(E.TextAuthor[I]).Content) + '</i></p>');
    Inner := JoinParts(Parts, #10);
    if Inner <> '' then
      Result := '<blockquote>' + Inner + '</blockquote>';
  finally
    Parts.Free;
  end;
end;

function TFb2ToMobiConverter.RenderBlock(Block: TFb2Object): UnicodeString;
begin
  if Block is TParagraph then
    Result := Paragraph(TParagraph(Block).Content)
  else if Block is TSubtitle then
    Result := '<p><b>' + RenderMarkup(TSubtitle(Block).Content) + '</b></p>'
  else if Block is TEmptyLine then
    Result := '<p>&#160;</p>'
  else if Block is TPoem then
    Result := RenderPoem(TPoem(Block))
  else if Block is TCite then
    Result := RenderCite(TCite(Block))
  else if Block is TTable then
    Result := RenderTable(TTable(Block))
  else if Block is TImage then
    Result := ImageTag(TImage(Block))
  else if Block is TEpigraph then
    Result := RenderEpigraph(TEpigraph(Block))
  else
    Result := '';
end;

function TFb2ToMobiConverter.Paragraph(Nodes: TFb2ObjectList): UnicodeString;
var
  Content: UnicodeString;
begin
  Content := RenderMarkup(Nodes);
  if Content <> '' then
    Result := '<p>' + Content + '</p>'
  else
    Result := '';
end;

function TFb2ToMobiConverter.RenderPoem(P: TPoem): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
  Inner: UnicodeString;
begin
  Result := '';
  if P = nil then
    Exit;
  Parts := TTextList.Create;
  try
    if P.Title <> nil then
      Parts.Add(RenderTitle(P.Title, 3));
    for I := 0 to P.Items.Count - 1 do
    begin
      if P.Items[I] is TStanza then
        Parts.Add(RenderStanza(TStanza(P.Items[I])))
      else if P.Items[I] is TSubtitle then
        Parts.Add('<p><b>' + RenderMarkup(TSubtitle(P.Items[I]).Content) +
          '</b></p>');
    end;
    for I := 0 to P.TextAuthor.Count - 1 do
      Parts.Add('<p><i>' +
        RenderMarkup(TParagraph(P.TextAuthor[I]).Content) + '</i></p>');
    Inner := JoinParts(Parts, #10);
    if Inner <> '' then
      Result := '<blockquote>' + Inner + '</blockquote>';
  finally
    Parts.Free;
  end;
end;

function TFb2ToMobiConverter.RenderStanza(S: TStanza): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
begin
  Result := '';
  if S = nil then
    Exit;
  Parts := TTextList.Create;
  try
    if S.Subtitle <> nil then
      Parts.Add('<p><b>' + RenderMarkup(S.Subtitle.Content) + '</b></p>');
    for I := 0 to S.Verses.Count - 1 do
      Parts.Add(Paragraph(TParagraph(S.Verses[I]).Content));
    Result := JoinParts(Parts, #10);
  finally
    Parts.Free;
  end;
end;

function TFb2ToMobiConverter.RenderCite(C: TCite): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
  Rendered, Inner: UnicodeString;
begin
  Result := '';
  if C = nil then
    Exit;
  Parts := TTextList.Create;
  try
    for I := 0 to C.Items.Count - 1 do
    begin
      Rendered := RenderBlock(C.Items[I]);
      if Rendered <> '' then
        Parts.Add(Rendered);
    end;
    for I := 0 to C.TextAuthor.Count - 1 do
      Parts.Add('<p><i>' +
        RenderMarkup(TParagraph(C.TextAuthor[I]).Content) + '</i></p>');
    Inner := JoinParts(Parts, #10);
    if Inner <> '' then
      Result := '<blockquote>' + Inner + '</blockquote>';
  finally
    Parts.Free;
  end;
end;

function TFb2ToMobiConverter.RenderTable(T: TTable): UnicodeString;
var
  Rows, Cells: UnicodeString;
  R, C: Integer;
  Row: TTableRow;
  Cell: TTableCell;
  Tag: UnicodeString;
begin
  Result := '';
  if T = nil then
    Exit;
  Rows := '';
  for R := 0 to T.Rows.Count - 1 do
  begin
    Row := TTableRow(T.Rows[R]);
    Cells := '';
    for C := 0 to Row.Cells.Count - 1 do
    begin
      Cell := TTableCell(Row.Cells[C]);
      if Cell.IsHeader then
        Tag := 'th'
      else
        Tag := 'td';
      Cells := Cells + '<' + Tag + '>' + RenderMarkup(Cell.Children) +
        '</' + Tag + '>';
    end;
    Rows := Rows + '<tr>' + Cells + '</tr>';
  end;
  if Rows <> '' then
    Result := '<table>' + Rows + '</table>';
end;

function TFb2ToMobiConverter.RenderMarkup(Nodes: TFb2ObjectList): UnicodeString;
var
  I: Integer;
  Node: TStyleNode;
  Tag: UnicodeString;
begin
  Result := '';
  if Nodes = nil then
    Exit;
  for I := 0 to Nodes.Count - 1 do
  begin
    Node := TStyleNode(Nodes[I]);
    if Node.Tag = TEXT_NODE_NAME then
      Result := Result + HtmlEscape(Node.Text)
    else if Node.Tag = 'a' then
      Result := Result + Link(Node)
    else if Node.Tag = 'image' then
      Result := Result + ImageTagInline(Node)
    else
    begin
      Tag := MarkupTag(Node.Tag);
      if Tag <> '' then
        Result := Result + '<' + Tag + '>' + RenderMarkup(Node.Children) +
          '</' + Tag + '>'
      else
        Result := Result + RenderMarkup(Node.Children);
    end;
  end;
end;

function TFb2ToMobiConverter.Link(Node: TStyleNode): UnicodeString;
var
  Inner, Href: UnicodeString;
begin
  Inner := RenderMarkup(Node.Children);
  Href := Node.Href;
  if Href = '' then
    Result := Inner
  else
    Result := '<a href="' + HtmlEscape(Href) + '">' + Inner + '</a>';
end;

function TFb2ToMobiConverter.ImageTagInline(Node: TStyleNode): UnicodeString;
var
  Href: UnicodeString;
  Number: Integer;
begin
  Href := Node.ImageHref;
  if Href = '' then
    Href := Node.Href;
  Number := ImageNumber(Href);
  if Number = -1 then
    Result := ''
  else
    Result := Format('<img recindex="%.5d"/>', [Number]);
end;

function TFb2ToMobiConverter.ImageTag(Img: TImage): UnicodeString;
var
  Number: Integer;
begin
  Number := ImageNumber(Img.Href);
  if Number = -1 then
    Result := ''
  else
    Result := Format('<p><img recindex="%.5d"/></p>', [Number]);
end;

{ ===================== Контейнер PDB/MOBI ===================== }

procedure TFb2ToMobiConverter.TextRecords(const Text: TBytes;
  out Records: TBytesArray; out Compression: Integer);
var
  Plain, Compressed: TBytesArray;
  Start, Count, I: Integer;
  Block, PackedRec: TBytes;
begin
  Plain := nil;
  Start := 0;
  while Start < Length(Text) do
  begin
    Count := TEXT_RECORD_SIZE;
    if Start + Count > Length(Text) then
      Count := Length(Text) - Start;
    SetLength(Block, Count);
    Move(Text[Start], Block[0], Count);
    SetLength(Plain, Length(Plain) + 1);
    Plain[High(Plain)] := Block;
    Inc(Start, TEXT_RECORD_SIZE);
  end;
  if Length(Plain) = 0 then
  begin
    SetLength(Plain, 1);
    SetLength(Plain[0], 0);
  end;

  if not FCompress then
  begin
    Records := Plain;
    Compression := COMPRESSION_NONE;
    Exit;
  end;

  Compressed := nil;
  for I := 0 to Length(Plain) - 1 do
  begin
    PackedRec := PalmDocCompress(Plain[I]);
    if Length(PackedRec) > TEXT_RECORD_SIZE then
    begin
      Records := Plain;
      Compression := COMPRESSION_NONE;
      Exit;
    end;
    SetLength(Compressed, Length(Compressed) + 1);
    Compressed[High(Compressed)] := PackedRec;
  end;
  Records := Compressed;
  Compression := COMPRESSION_PALMDOC;
end;

function TFb2ToMobiConverter.RecordZero(Book: TMobiBook; Compression,
  TextLength, TextRecordsCount, FirstImageIndex: Integer): TBytes;
const
  NIL_OFFSETS: array[0..9] of Integer =
    ($18, $1C, $20, $24, $28, $2C, $30, $34, $38, $3C);
var
  Exth_, Title, Mobi, PalmDoc, Rec: TBytes;
  I: Integer;
begin
  Exth_ := Exth(Book);
  Title := UTF8Bytes(Book.Title);

  Mobi := ZeroPad(MOBI_HEADER_LENGTH);
  Mobi[0] := $4D; { M }
  Mobi[1] := $4F; { O }
  Mobi[2] := $42; { B }
  Mobi[3] := $49; { I }
  PutBE32(Mobi, $04, MOBI_HEADER_LENGTH);
  PutBE32(Mobi, $08, 2);
  PutBE32(Mobi, $0C, ENCODING_UTF8);
  PutBE32(Mobi, $10, LongWord(Random($7FFFFFFF) + 1));
  PutBE32(Mobi, $14, 6);
  for I := Low(NIL_OFFSETS) to High(NIL_OFFSETS) do
    PutBE32(Mobi, NIL_OFFSETS[I], $FFFFFFFF);
  PutBE32(Mobi, $40, LongWord(FirstImageIndex));
  PutBE32(Mobi, $44, LongWord(16 + MOBI_HEADER_LENGTH + Length(Exth_)));
  PutBE32(Mobi, $48, LongWord(Length(Title)));
  PutBE32(Mobi, $4C, LocaleFor(Book.Language));
  PutBE32(Mobi, $58, 6);
  PutBE32(Mobi, $5C, LongWord(FirstImageIndex));
  PutBE32(Mobi, $60, $FFFFFFFF);
  PutBE32(Mobi, $70, $40);
  PutBE32(Mobi, $94, $FFFFFFFF);
  PutBE16(Mobi, $AC, 1);
  PutBE16(Mobi, $AE, Word(TextRecordsCount));
  PutBE32(Mobi, $B4, $FFFFFFFF);
  PutBE32(Mobi, $BC, $FFFFFFFF);
  PutBE32(Mobi, $D4, $FFFFFFFF);

  PalmDoc := ZeroPad(16);
  PutBE16(PalmDoc, $00, Word(Compression));
  PutBE16(PalmDoc, $02, 0);
  PutBE32(PalmDoc, $04, LongWord(TextLength));
  PutBE16(PalmDoc, $08, Word(TextRecordsCount));
  PutBE16(PalmDoc, $0A, TEXT_RECORD_SIZE);
  PutBE16(PalmDoc, $0C, 0);
  PutBE16(PalmDoc, $0E, 0);

  Rec := ConcatBytes(ConcatBytes(ConcatBytes(PalmDoc, Mobi), Exth_), Title);
  Result := ConcatBytes(Rec, ZeroPad((4 - Length(Rec) mod 4) mod 4));
end;

function TFb2ToMobiConverter.Exth(Book: TMobiBook): TBytes;
var
  Recs: TBytesArray;
  I: Integer;
  Body, Header: TBytes;
  Length_: Integer;
  OffsetBytes: TBytes;

  procedure AddRec(Kind: LongWord; const Data: TBytes);
  var
    R: TBytes;
  begin
    R := ConcatBytes(BE32Bytes(Kind), BE32Bytes(LongWord(Length(Data) + 8)));
    R := ConcatBytes(R, Data);
    SetLength(Recs, Length(Recs) + 1);
    Recs[High(Recs)] := R;
  end;

begin
  Recs := nil;
  for I := 0 to Book.Authors.Count - 1 do
    AddRec(EXTH_AUTHOR, UTF8Bytes(Book.Authors[I]));
  if Book.Description <> '' then
    AddRec(EXTH_DESCRIPTION, UTF8Bytes(Book.Description));
  for I := 0 to Book.Genres.Count - 1 do
    AddRec(EXTH_SUBJECT, UTF8Bytes(Book.Genres[I]));
  AddRec(EXTH_LANGUAGE, UTF8Bytes(Book.Language));
  AddRec(EXTH_CDE_TYPE, UTF8Bytes('EBOK'));
  if Book.CoverIndex >= 0 then
  begin
    OffsetBytes := BE32Bytes(LongWord(Book.CoverIndex));
    AddRec(EXTH_COVER_OFFSET, OffsetBytes);
    AddRec(EXTH_THUMB_OFFSET, OffsetBytes);
  end;

  Body := nil;
  for I := 0 to Length(Recs) - 1 do
    Body := ConcatBytes(Body, Recs[I]);
  Length_ := Length(Body) + 12;
  Header := ConcatBytes(
    ConcatBytes(UTF8Bytes('EXTH'), BE32Bytes(LongWord(Length_))),
    BE32Bytes(LongWord(Length(Recs))));
  Result := ConcatBytes(ConcatBytes(Header, Body),
    ZeroPad((4 - Length_ mod 4) mod 4));
end;

function TFb2ToMobiConverter.PalmDatabase(const Name: UnicodeString;
  const Records: TBytesArray): TBytes;
var
  Header, Entries, Payload, RawName, Rec, Entry: TBytes;
  I, Offset, Padding: Integer;
  Stamp: LongWord;
begin
  Header := ZeroPad(78);
  RawName := UTF8Bytes(Name);
  if Length(RawName) > 31 then
    SetLength(RawName, 31);
  for I := 0 to Length(RawName) - 1 do
    Header[I] := RawName[I];
  Stamp := LongWord(Trunc((Now - 25569.0) * 86400.0) + 2082844800);
  PutBE32(Header, 36, Stamp);
  PutBE32(Header, 40, Stamp);
  PutBE32(Header, 44, 0);
  Header[60] := Ord('B'); Header[61] := Ord('O');
  Header[62] := Ord('O'); Header[63] := Ord('K');
  Header[64] := Ord('M'); Header[65] := Ord('O');
  Header[66] := Ord('B'); Header[67] := Ord('I');
  PutBE16(Header, 76, Word(Length(Records)));

  Offset := 78 + 8 * Length(Records) + 2;
  Entries := nil;
  Payload := nil;
  for I := 0 to Length(Records) - 1 do
  begin
    Rec := Records[I];
    SetLength(Entry, 8);
    PutBE32(Entry, 0, LongWord(Offset));
    Entry[4] := 0;
    Entry[5] := 0;
    PutBE16(Entry, 6, Word(I));
    Entries := ConcatBytes(Entries, Entry);
    Payload := ConcatBytes(Payload, Rec);
    Inc(Offset, Length(Rec));
    Padding := (4 - Length(Rec) mod 4) mod 4;
    Payload := ConcatBytes(Payload, ZeroPad(Padding));
    Inc(Offset, Padding);
  end;
  Result := ConcatBytes(ConcatBytes(ConcatBytes(Header, Entries), ZeroPad(2)),
    Payload);
end;

{ ===================== Публичный API ===================== }

function TFb2ToMobiConverter.Convert(const Source: UnicodeString): TMobiBook;
var
  Desc: TDescription;
  Bodies, Binaries: TFb2ObjectList;
  TI: TTitleInfo;
begin
  if Source <> '' then
    FSource := Source;
  Reset;

  FParser.LoadFile(FSource);
  Desc := FParser.Parse;
  Bodies := FParser.ParseBodies;
  Binaries := FParser.ParseBinaries;
  try
    TI := nil;
    if Desc <> nil then
      TI := Desc.TitleInfo;

    CollectImages(Binaries);

    FreeAndNil(FBook);
    FBook := TMobiBook.Create;
    FBook.Title := BookTitle(TI);
    FreeAndNil(FBook.Authors);
    FBook.Authors := CreatorList(TI);
    FBook.Language := LanguageOf(TI);
    FBook.Description := AnnotationText(TI);
    FreeAndNil(FBook.Genres);
    FBook.Genres := GenreList(TI);
    FBook.Html := RenderHtml(Bodies);
    FreeAndNil(FBook.Images);
    FBook.Images := FImages;
    FImages := nil;
    FBook.CoverIndex := CoverIndex(TI);
    Result := FBook;
  finally
    Binaries.Free;
    Bodies.Free;
    Desc.Free;
  end;
end;

function TFb2ToMobiConverter.ToBytes(Book: TMobiBook): TBytes;
var
  Text: TBytes;
  TextRecs, ImageRecs, Records: TBytesArray;
  Compression, FirstImageIndex, I, Total: Integer;
  RecordZeroBytes: TBytes;
begin
  if Book = nil then
    Book := FBook;
  if Book = nil then
    raise EFb2ConversionError.Create(
      'Нет книги для сериализации: вызовите Convert');

  Text := UTF8Bytes(Book.Html);
  TextRecords(Text, TextRecs, Compression);

  SetLength(ImageRecs, Book.Images.Count);
  for I := 0 to Book.Images.Count - 1 do
    ImageRecs[I] := TMobiImage(Book.Images[I]).Data;

  FirstImageIndex := 1 + Length(TextRecs);
  RecordZeroBytes := RecordZero(Book, Compression, Length(Text),
    Length(TextRecs), FirstImageIndex);

  Total := 1 + Length(TextRecs) + Length(ImageRecs);
  SetLength(Records, Total);
  Records[0] := RecordZeroBytes;
  for I := 0 to Length(TextRecs) - 1 do
    Records[1 + I] := TextRecs[I];
  for I := 0 to Length(ImageRecs) - 1 do
    Records[1 + Length(TextRecs) + I] := ImageRecs[I];

  Result := PalmDatabase(Book.Title, Records);
end;

function TFb2ToMobiConverter.Write(const Source: UnicodeString;
  const Output: UnicodeString): UnicodeString;
var
  Bk: TMobiBook;
  Data: TBytes;
  Target: UnicodeString;
begin
  Bk := Convert(Source);
  Data := ToBytes(Bk);
  if Output <> '' then
    Target := Output
  else if FSource <> '' then
    Target := ChangeFileExt(FSource, '.mobi')
  else
    Target := 'book.mobi';
  WriteFileAtomic(Target, Data);
  Result := Target;
end;

end.





