unit mobi_to_fb2;
{ Преобразование MOBI (Mobipocket/Kindle KF7) в книгу FB2 — перевод mobi_to_fb2.py.

  Модуль разбирает базу данных Palm (PDB): заголовки PalmDOC/MOBI/EXTH,
  распаковывает текст (PalmDOC LZ77) и изображения, преобразует HTML-разметку
  в структуры FB2 (через THtmlToFb2Converter из html_to_fb2).

  Поддерживаются файлы без DRM с компрессией 1 (без сжатия) и 2 (PalmDOC).
  HUFF/CDIC-компрессия не поддерживается.

  Пример:
      C := TMobiToFb2Converter.Create;
      try
        C.Write('book.mobi', 'book.fb2');
      finally
        C.Free;
      end; }

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Classes, SysUtils, StrUtils, fgl,
  fb2_structures, fb2_parser, fb2_errors, fb2_images, fb2_files,
  fb2_writer, html_to_fb2;

const
  { Компрессия текста. }
  COMPRESSION_NONE = 1;
  COMPRESSION_PALMDOC = 2;
  COMPRESSION_HUFFCDIC = 17480;

  { Смещения в MOBI-заголовке (от начала блока «MOBI»). }
  MOBI_FIRST_IMAGE = $5C;
  MOBI_FULL_NAME_OFFSET = $44;
  MOBI_FULL_NAME_LENGTH = $48;
  MOBI_EXTH_FLAGS = $70;
  MOBI_HEADER_LENGTH_FIELD = $04;

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
  { Набор байтовых блоков (записи PDB, изображения). }
  TBytesArray = array of TBytes;

  { Запись EXTH (метаданные MOBI). }
  TMobiExthEntry = class
  public
    Kind: Integer;
    Data: TBytes;
  end;

  TMobiExthList = specialize TFPGObjectList<TMobiExthEntry>;

  { Разобранные заголовки записи 0. }
  TMobiHeader = class
  public
    Compression: Integer;
    TextLength: Integer;
    TextRecords: Integer;
    FirstImageIndex: Integer;
    FullNameOffset: Integer;
    FullNameLength: Integer;
    Title: UnicodeString;
    Exth: TMobiExthList;
    constructor Create;
    destructor Destroy; override;
    function HasFirst(Kind: Integer): Boolean;
    function First(Kind: Integer): TBytes;
    function Texts(Kind: Integer): TTextList;
  end;

  { Преобразование MOBI в FB2. }
  TMobiToFb2Converter = class
  private
    FWriter: TFb2Writer;
    FHtml: THtmlToFb2Converter;
    FDefaultGenre: UnicodeString;
    FProgramUsed: UnicodeString;
    FSource: UnicodeString;
    FBook: TFictionBook;

    function ReadSource(const Source: UnicodeString): TBytes;
    function SplitRecords(const Data: TBytes): TBytesArray;
    function ParseRecordZero(const Record_: TBytes): TMobiHeader;
    procedure ParseExth(const Record_: TBytes; Start: Integer;
      Header: TMobiHeader);
    function ReadText(const Records: TBytesArray;
      Header: TMobiHeader): UnicodeString;
    function ReadImages(const Records: TBytesArray;
      Header: TMobiHeader): TBytesArray;
    function InlineImages(const Html: UnicodeString;
      const Images: TBytesArray): UnicodeString;
    procedure ApplyMetadata(Book: TFictionBook; Header: TMobiHeader;
      const Images: TBytesArray);
    procedure ApplyCover(Book: TFictionBook; Header: TMobiHeader;
      const Images: TBytesArray);
  public
    constructor Create(AWriter: TFb2Writer = nil;
      const ADefaultGenre: UnicodeString = 'sf';
      const AProgramUsed: UnicodeString = 'pyFB2');
    destructor Destroy; override;

    { Прочитать MOBI и вернуть структуру TFictionBook. }
    function Convert(const Source: UnicodeString = ''): TFictionBook;

    { Сериализовать книгу (или результат Convert) в XML FB2. }
    function ToXml(Book: TFictionBook = nil): UnicodeString;

    { Преобразовать MOBI в файл FB2 и вернуть путь к результату. }
    function Write(const Source: UnicodeString;
      const Output: UnicodeString = ''): UnicodeString;

    property Book: TFictionBook read FBook;
  end;

{ Распаковать блок данных, сжатый алгоритмом PalmDOC (LZ77). }
function PalmDocDecompress(const Data: TBytes): TBytes;

implementation

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

function ReadU16(const B: TBytes; Ofs: Integer): Word;
begin
  Result := (Word(B[Ofs]) shl 8) or B[Ofs + 1];
end;

function ReadU32(const B: TBytes; Ofs: Integer): LongWord;
begin
  Result := (LongWord(B[Ofs]) shl 24) or (LongWord(B[Ofs + 1]) shl 16) or
    (LongWord(B[Ofs + 2]) shl 8) or B[Ofs + 3];
end;

{ Декодировать UTF-8 байты в UnicodeString (аналог decode("utf-8","replace")). }
function DecodeUtf8(const Data: TBytes): UnicodeString;
var
  Raw: RawByteString;
begin
  SetLength(Raw, Length(Data));
  if Length(Data) > 0 then
    Move(Data[0], Raw[1], Length(Data));
  Result := UTF8Decode(Raw);
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

{ Разбить строку автора на first/middle/last (аналог _split_author). }
function SplitAuthor(const Name: UnicodeString): TAuthor;
var
  S, Last, First: UnicodeString;
  P: Integer;
  Parts: TTextList;
  Mid: TTextList;
  I: Integer;
begin
  Result := nil;
  S := UTrim(Name);
  P := Pos(',', S);
  if P > 0 then
  begin
    Last := UTrim(Copy(S, 1, P - 1));
    First := UTrim(Copy(S, P + 1, MaxInt));
    Result := TAuthor.Create;
    Result.LastName := Last;
    if First <> '' then
      Result.FirstName := First;
    Exit;
  end;
  Parts := SplitWords(S);
  try
    if Parts.Count = 0 then
    begin
      Result := TAuthor.Create;
      Result.Nickname := 'Неизвестный автор';
      Exit;
    end;
    if Parts.Count = 1 then
    begin
      Result := TAuthor.Create;
      Result.LastName := Parts[0];
      Exit;
    end;
    if Parts.Count = 2 then
    begin
      Result := TAuthor.Create;
      Result.FirstName := Parts[0];
      Result.LastName := Parts[1];
      Exit;
    end;
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
  finally
    Parts.Free;
  end;
end;

{ Вырезать байты [A, BEnd) с безопасным зажимом (аналог среза Python). }
function SliceBytes(const B: TBytes; A, BEnd: Integer): TBytes;
var
  N: Integer;
begin
  if A < 0 then
    A := 0;
  if BEnd > Length(B) then
    BEnd := Length(B);
  if BEnd < A then
    BEnd := A;
  N := BEnd - A;
  SetLength(Result, N);
  if N > 0 then
    Move(B[A], Result[0], N);
end;

{ Сравнить 4 байта начиная с Ofs с ASCII-строкой. }
function BytesAtEqual(const B: TBytes; Ofs: Integer;
  const S: AnsiString): Boolean;
var
  I: Integer;
begin
  Result := False;
  if Ofs < 0 then
    Exit;
  if Ofs + Length(S) > Length(B) then
    Exit;
  for I := 1 to Length(S) do
    if B[Ofs + I - 1] <> Byte(S[I]) then
      Exit;
  Result := True;
end;

{ ===================== TMobiHeader ===================== }

constructor TMobiHeader.Create;
begin
  inherited Create;
  Compression := COMPRESSION_NONE;
  TextLength := 0;
  TextRecords := 0;
  FirstImageIndex := 0;
  FullNameOffset := 0;
  FullNameLength := 0;
  Title := '';
  Exth := TMobiExthList.Create(True);
end;

destructor TMobiHeader.Destroy;
begin
  FreeAndNil(Exth);
  inherited Destroy;
end;

function TMobiHeader.HasFirst(Kind: Integer): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to Exth.Count - 1 do
    if TMobiExthEntry(Exth[I]).Kind = Kind then
      Exit(True);
end;

function TMobiHeader.First(Kind: Integer): TBytes;
var
  I: Integer;
begin
  SetLength(Result, 0);
  for I := 0 to Exth.Count - 1 do
    if TMobiExthEntry(Exth[I]).Kind = Kind then
      Exit(TMobiExthEntry(Exth[I]).Data);
end;

function TMobiHeader.Texts(Kind: Integer): TTextList;
var
  I: Integer;
begin
  Result := TTextList.Create;
  for I := 0 to Exth.Count - 1 do
    if TMobiExthEntry(Exth[I]).Kind = Kind then
      Result.Add(DecodeUtf8(TMobiExthEntry(Exth[I]).Data));
end;

{ ===================== TMobiToFb2Converter ===================== }

constructor TMobiToFb2Converter.Create(AWriter: TFb2Writer;
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
  FHtml := THtmlToFb2Converter.Create(ADefaultGenre, AProgramUsed);
end;

destructor TMobiToFb2Converter.Destroy;
begin
  FBook := nil;              { владелец — FHtml }
  FreeAndNil(FHtml);
  FreeAndNil(FWriter);
  inherited Destroy;
end;

function TMobiToFb2Converter.ReadSource(const Source: UnicodeString): TBytes;
var
  FS: TFileStream;
begin
  FS := TFileStream.Create(Source, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Result, FS.Size);
    if FS.Size > 0 then
      FS.ReadBuffer(Result[0], FS.Size);
  finally
    FS.Free;
  end;
end;

function TMobiToFb2Converter.SplitRecords(const Data: TBytes): TBytesArray;
var
  Count, I, Start_, End_: Integer;
  Offsets: array of Integer;
begin
  SetLength(Result, 0);
  if Length(Data) < 78 then
    raise EFb2ConversionError.Create('Файл слишком короткий для базы данных Palm');
  Count := ReadU16(Data, 76);
  if Count = 0 then
    Exit;
  SetLength(Offsets, Count + 1);
  for I := 0 to Count - 1 do
    Offsets[I] := Integer(ReadU32(Data, 78 + 8 * I));
  Offsets[Count] := Length(Data);
  SetLength(Result, Count);
  for I := 0 to Count - 1 do
  begin
    Start_ := Offsets[I];
    End_ := Offsets[I + 1];
    if (Start_ > Length(Data)) or (End_ > Length(Data)) or (Start_ > End_) then
      raise EFb2ConversionError.Create('Повреждён список записей PDB');
    Result[I] := SliceBytes(Data, Start_, End_);
  end;
end;

procedure TMobiToFb2Converter.ParseExth(const Record_: TBytes; Start: Integer;
  Header: TMobiHeader);
var
  Length_, Count, Position, End_, Kind, Size: Integer;
  E: TMobiExthEntry;
begin
  if Start + 12 > Length(Record_) then
    Exit;
  Length_ := Integer(ReadU32(Record_, Start + 4));
  Count := Integer(ReadU32(Record_, Start + 8));
  Position := Start + 12;
  End_ := Start + Length_;
  if End_ > Length(Record_) then
    End_ := Length(Record_);
  while Count > 0 do
  begin
    if Position + 8 > End_ then
      Break;
    Kind := Integer(ReadU32(Record_, Position));
    Size := Integer(ReadU32(Record_, Position + 4));
    if Size < 8 then
      Break;
    E := TMobiExthEntry.Create;
    E.Kind := Kind;
    E.Data := SliceBytes(Record_, Position + 8, Position + Size);
    Header.Exth.Add(E);
    Inc(Position, Size);
    Dec(Count);
  end;
end;

function TMobiToFb2Converter.ParseRecordZero(const Record_: TBytes): TMobiHeader;
var
  MobiLength, MobiEnd, ExthFlags, Start_, End_: Integer;
begin
  if Length(Record_) < 24 then
    raise EFb2ConversionError.Create('Запись 0 слишком короткая');
  Result := TMobiHeader.Create;
  Result.Compression := ReadU16(Record_, 0);
  Result.TextLength := Integer(ReadU32(Record_, 4));
  Result.TextRecords := ReadU16(Record_, 8);

  if not BytesAtEqual(Record_, 16, 'MOBI') then
    Exit; { чистый PalmDOC без MOBI-заголовка }

  MobiLength := Integer(ReadU32(Record_, 16 + MOBI_HEADER_LENGTH_FIELD));
  MobiEnd := 16 + MobiLength;
  Result.FirstImageIndex := Integer(ReadU32(Record_, 16 + MOBI_FIRST_IMAGE));
  Result.FullNameOffset := Integer(ReadU32(Record_, 16 + MOBI_FULL_NAME_OFFSET));
  Result.FullNameLength := Integer(ReadU32(Record_, 16 + MOBI_FULL_NAME_LENGTH));
  ExthFlags := Integer(ReadU32(Record_, 16 + MOBI_EXTH_FLAGS));
  if (ExthFlags and $40 <> 0) and BytesAtEqual(Record_, MobiEnd, 'EXTH') then
    ParseExth(Record_, MobiEnd, Result);

  if (Result.FullNameOffset <> 0) and (Result.FullNameLength <> 0) then
  begin
    Start_ := Result.FullNameOffset;
    End_ := Start_ + Result.FullNameLength;
    Result.Title := DecodeUtf8(SliceBytes(Record_, Start_, End_));
  end;
end;

{ ===================== PalmDOC ===================== }

function PalmDocDecompress(const Data: TBytes): TBytes;
var
  Out_: TBytes;
  OutLen, Index, Size, Value, Pair, Len_, Distance, Start_, Offset: Integer;

  procedure Ensure;
  begin
    if OutLen >= Length(Out_) then
      SetLength(Out_, Length(Out_) * 2 + 16);
  end;

begin
  Size := Length(Data);
  SetLength(Out_, Size + Size div 2 + 64);
  OutLen := 0;
  Index := 0;
  while Index < Size do
  begin
    Value := Data[Index];
    Inc(Index);
    if (Value = 0) or ((Value >= $09) and (Value <= $7F)) then
    begin
      Ensure;
      Out_[OutLen] := Byte(Value);
      Inc(OutLen);
    end
    else if (Value >= $01) and (Value <= $08) then
    begin
      for Offset := 0 to Value - 1 do
      begin
        if Index >= Size then
          Break;
        Ensure;
        Out_[OutLen] := Data[Index];
        Inc(OutLen);
        Inc(Index);
      end;
    end
    else if (Value >= $80) and (Value <= $BF) then
    begin
      if Index >= Size then
        Break;
      Pair := ((Value and $3F) shl 8) or Data[Index];
      Inc(Index);
      Len_ := (Pair and $07) + 3;
      Distance := (Pair shr 3) and $7FF;
      if Distance = 0 then
        Break;
      Start_ := OutLen - Distance;
      if Start_ < 0 then
        Break;
      for Offset := 0 to Len_ - 1 do
      begin
        Ensure;
        Out_[OutLen] := Out_[Start_ + Offset];
        Inc(OutLen);
      end;
    end
    else
    begin
      Ensure;
      Out_[OutLen] := $20;
      Inc(OutLen);
      Ensure;
      Out_[OutLen] := Byte(Value xor $80);
      Inc(OutLen);
    end;
  end;
  SetLength(Result, OutLen);
  if OutLen > 0 then
    Move(Out_[0], Result[0], OutLen);
end;

{ ===================== Чтение PDB ===================== }

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

{ Служебная запись PDB (FLIS/FCIS/INDX/...)? }
function IsServiceRecord(const Rec: TBytes): Boolean;
const
  TAGS: array[0..6] of AnsiString =
    ('FLIS', 'FCIS', 'INDX', 'SRCS', 'CMET', 'FDST', 'EOF ');
var
  I: Integer;
begin
  for I := Low(TAGS) to High(TAGS) do
    if BytesAtEqual(Rec, 0, TAGS[I]) then
      Exit(True);
  Result := False;
end;

function TMobiToFb2Converter.ReadText(const Records: TBytesArray;
  Header: TMobiHeader): UnicodeString;
var
  Count, I: Integer;
  Parts, Text: TBytes;
begin
  if Header.Compression = COMPRESSION_HUFFCDIC then
    raise EFb2ConversionError.Create('HUFF/CDIC-компрессия не поддерживается');
  Count := Header.TextRecords;
  if Count = 0 then
  begin
    Count := Length(Records) - 1;
    if Count < 0 then
      Count := 0;
  end;
  Parts := nil;
  for I := 1 to Count do
  begin
    if I >= Length(Records) then
      Break;
    if Header.Compression = COMPRESSION_PALMDOC then
      Parts := ConcatBytes(Parts, PalmDocDecompress(Records[I]))
    else
      Parts := ConcatBytes(Parts, Records[I]);
  end;
  Text := Parts;
  if (Header.TextLength > 0) and (Length(Text) > Header.TextLength) then
    Text := SliceBytes(Text, 0, Header.TextLength);
  Result := DecodeUtf8(Text);
end;

function TMobiToFb2Converter.ReadImages(const Records: TBytesArray;
  Header: TMobiHeader): TBytesArray;
var
  Start_, I, N: Integer;
begin
  SetLength(Result, 0);
  Start_ := Header.FirstImageIndex;
  if (Start_ = 0) or (Start_ >= Length(Records)) then
    Exit;
  SetLength(Result, Length(Records) - Start_);
  N := 0;
  for I := Start_ to Length(Records) - 1 do
    if (Length(Records[I]) > 0) and (not IsServiceRecord(Records[I])) then
    begin
      Result[N] := Records[I];
      Inc(N);
    end;
  SetLength(Result, N);
end;

{ Найти начало тега <img (регистронезависимо). }
function FindImgStart(const S: UnicodeString; From: Integer): Integer;
var
  I, N: Integer;
begin
  N := Length(S);
  I := From;
  while I + 3 <= N do
  begin
    if (S[I] = '<') and ((S[I + 1] = 'i') or (S[I + 1] = 'I')) and
      ((S[I + 2] = 'm') or (S[I + 2] = 'M')) and
      ((S[I + 3] = 'g') or (S[I + 3] = 'G')) then
      Exit(I);
    Inc(I);
  end;
  Result := 0;
end;

function IsWordChar(C: WideChar): Boolean;
begin
  Result := ((C >= 'A') and (C <= 'Z')) or ((C >= 'a') and (C <= 'z')) or
    ((C >= '0') and (C <= '9')) or (C = '_');
end;

{ Найти атрибут recindex="0*(\d+)" в теге; вернуть номер и границы атрибута. }
function FindRecindex(const Tag: UnicodeString; out AttrStart, AttrEnd: Integer): Integer;
var
  K, P, Q: Integer;
  Lower: UnicodeString;
  Num: Integer;
  HadDigit: Boolean;
begin
  Result := -1;
  AttrStart := 0;
  AttrEnd := 0;
  Lower := LowerCase(Tag);
  K := Pos('recindex="', Lower);
  while K > 0 do
  begin
    if (K = 1) or (not IsWordChar(Tag[K - 1])) then
    begin
      P := K + Length('recindex="');
      Num := 0;
      HadDigit := False;
      Q := P;
      while (Q <= Length(Tag)) and (Tag[Q] >= '0') and (Tag[Q] <= '9') do
      begin
        Num := Num * 10 + (Ord(Tag[Q]) - Ord('0'));
        HadDigit := True;
        Inc(Q);
      end;
      if HadDigit and (Q <= Length(Tag)) and (Tag[Q] = '"') then
      begin
        AttrStart := K;
        AttrEnd := Q;
        Exit(Num);
      end;
    end;
    K := PosEx('recindex="', Lower, K + 1);
  end;
end;

function TMobiToFb2Converter.InlineImages(const Html: UnicodeString;
  const Images: TBytesArray): UnicodeString;
var
  I, N, P, J, Num, AttrStart, AttrEnd, PosImg: Integer;
  Tag, Cleaned, Tag2, MediaType, Ext, Encoded: UnicodeString;
  Data: TBytes;
begin
  Result := '';
  N := Length(Html);
  I := 1;
  while I <= N do
  begin
    P := FindImgStart(Html, I);
    if P = 0 then
    begin
      Result := Result + Copy(Html, I, N - I + 1);
      Break;
    end;
    Result := Result + Copy(Html, I, P - I);
    J := P;
    while (J <= N) and (Html[J] <> '>') do
      Inc(J);
    if J > N then
    begin
      Result := Result + Copy(Html, P, N - P + 1);
      Break;
    end;
    Tag := Copy(Html, P, J - P + 1);
    Num := FindRecindex(Tag, AttrStart, AttrEnd);
    if (Num >= 1) and (Num <= Length(Images)) then
    begin
      Data := Images[Num - 1];
      MediaType := DetectImageType(Data, Ext);
      Encoded := Base64EncodeBytes(Data);
      Cleaned := Copy(Tag, 1, AttrStart - 1) + Copy(Tag, AttrEnd + 1, MaxInt);
      PosImg := Pos('<img', Cleaned);
      if PosImg > 0 then
        Tag2 := Copy(Cleaned, 1, PosImg + 3) + ' src="data:' + MediaType +
          ';base64,' + Encoded + '"' + Copy(Cleaned, PosImg + 4, MaxInt)
      else
        Tag2 := Cleaned;
      Result := Result + Tag2;
    end
    else
      Result := Result + Tag;
    I := J + 1;
  end;
end;

{ ===================== Метаданные ===================== }

function MakeGenre(const V: UnicodeString): TGenre;
begin
  Result := TGenre.Create;
  Result.Value := V;
end;

procedure TMobiToFb2Converter.ApplyMetadata(Book: TFictionBook;
  Header: TMobiHeader; const Images: TBytesArray);
var
  TI: TTitleInfo;
  Names, Subjects: TTextList;
  Authors, Genres: TFb2ObjectList;
  I, Dash: Integer;
  Lang: TBytes;
  Code, G: UnicodeString;
begin
  if (Book = nil) or (Book.Description = nil) then
    Exit;
  TI := Book.Description.TitleInfo;
  if TI = nil then
    Exit;

  if Header.Title <> '' then
  begin
    FreeAndNil(TI.BookTitle);
    TI.BookTitle := TTextField.Create;
    TI.BookTitle.Value := Header.Title;
  end;

  Names := Header.Texts(EXTH_AUTHOR);
  try
    if Names.Count > 0 then
    begin
      Authors := TFb2ObjectList.Create;
      for I := 0 to Names.Count - 1 do
        Authors.Add(SplitAuthor(Names[I]));
      FreeAndNil(TI.Authors);
      TI.Authors := Authors;
    end;
  finally
    Names.Free;
  end;

  Subjects := Header.Texts(EXTH_SUBJECT);
  try
    Genres := TFb2ObjectList.Create;
    for I := 0 to Subjects.Count - 1 do
    begin
      G := Trim(Subjects[I]);
      if (G <> '') and (Pos(' ', G) = 0) then
        Genres.Add(MakeGenre(G));
    end;
    if Genres.Count > 0 then
    begin
      FreeAndNil(TI.Genres);
      TI.Genres := Genres;
    end
    else
      Genres.Free;
  finally
    Subjects.Free;
  end;

  if Header.HasFirst(EXTH_LANGUAGE) then
  begin
    Lang := Header.First(EXTH_LANGUAGE);
    Code := Trim(DecodeUtf8(Lang));
    if Code <> '' then
    begin
      Dash := Pos('-', Code);
      if Dash > 0 then
        Code := Copy(Code, 1, Dash - 1);
      TI.Lang := LowerCase(Code);
    end;
  end;

  ApplyCover(Book, Header, Images);
end;

procedure TMobiToFb2Converter.ApplyCover(Book: TFictionBook;
  Header: TMobiHeader; const Images: TBytesArray);
var
  Raw, Data: TBytes;
  Index: LongWord;
  MediaType, Ext, BinaryId: UnicodeString;
  B: TBinary;
  CP: TCoverPage;
  Img: TInlineImage;
  Exists: Boolean;
  I: Integer;
begin
  Raw := Header.First(EXTH_COVER_OFFSET);
  if Length(Raw) < 4 then
    Exit;
  Index := ReadU32(Raw, 0);
  if Index >= LongWord(Length(Images)) then
    Exit;
  Data := Images[Index];
  MediaType := DetectImageType(Data, Ext);
  BinaryId := 'cover' + Ext;

  Exists := False;
  for I := 0 to Book.Binaries.Count - 1 do
    if TBinary(Book.Binaries[I]).Id = BinaryId then
    begin
      Exists := True;
      Break;
    end;
  if not Exists then
  begin
    B := TBinary.Create;
    B.Id := BinaryId;
    B.ContentType := MediaType;
    B.Data := Base64EncodeBytes(Data);
    Book.Binaries.Add(B);
  end;

  CP := TCoverPage.Create;
  Img := TInlineImage.Create;
  Img.Href := '#' + BinaryId;
  CP.Images.Add(Img);
  FreeAndNil(Book.Description.TitleInfo.Coverpage);
  Book.Description.TitleInfo.Coverpage := CP;
end;

{ ===================== Публичный API ===================== }

function TMobiToFb2Converter.Convert(const Source: UnicodeString): TFictionBook;
var
  Data: TBytes;
  Records: TBytesArray;
  Header: TMobiHeader;
  Html: UnicodeString;
  Images: TBytesArray;
begin
  if Source <> '' then
    FSource := Source;
  if FSource = '' then
    raise EFb2ConversionError.Create('Не задан источник MOBI (source)');

  Data := ReadSource(FSource);
  Records := SplitRecords(Data);
  if Length(Records) = 0 then
    raise EFb2ConversionError.Create('Файл MOBI не содержит записей');
  Header := ParseRecordZero(Records[0]);
  try
    Html := ReadText(Records, Header);
    Images := ReadImages(Records, Header);
    Html := InlineImages(Html, Images);
    FBook := FHtml.Convert(Html);
    ApplyMetadata(FBook, Header, Images);
    Result := FBook;
  finally
    Header.Free;
  end;
end;

function TMobiToFb2Converter.ToXml(Book: TFictionBook): UnicodeString;
begin
  if Book = nil then
    Book := FBook;
  if Book = nil then
    Book := Convert;
  Result := FWriter.ToXML(Book);
end;

function TMobiToFb2Converter.Write(const Source: UnicodeString;
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
