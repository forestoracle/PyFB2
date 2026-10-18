unit fb2_encoding_scanner;
{ Поиск каталогов, в которых FB2-файлы имеют РАЗНЫЕ кодировки —
  перевод fb2_encoding_scanner.py.

  Кодировка определяется в таком порядке:
      1. BOM в начале файла (UTF-8 / UTF-16 / UTF-32);
      2. атрибут encoding в XML-декларации (<?xml ... encoding="..."?>);
      3. значение по умолчанию XML — "utf-8". }

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Classes, SysUtils, fgl, fb2_structures, fb2_files;

const
  { Расширение FB2-файлов. }
  FB2_MASK = '*.fb2';
  { Сколько байт читать для анализа (декларация всегда в начале файла). }
  HEAD_SIZE = 4096;
  { Кодировка по умолчанию для XML без декларации и без BOM. }
  DEFAULT_ENCODING = 'utf-8';

type
  { Каталог с различающимися кодировками FB2-файлов. }
  TFb2EncodingScanEntry = class
  public
    Directory: UnicodeString;
    Encodings: TTextList;      { отсортированные кодировки }
    constructor Create;
    destructor Destroy; override;
  end;

  TFb2EncodingScanEntryList = specialize TFPGObjectList<TFb2EncodingScanEntry>;

  { Рекурсивный поиск каталогов с различающимися кодировками. }
  TFb2EncodingScanner = class
  private
    FStartDir: UnicodeString;
    FDebug: Boolean;
    procedure ScanDir(const Dir: UnicodeString;
      Results: TFb2EncodingScanEntryList);
  public
    constructor Create(const StartDir: UnicodeString; Debug: Boolean = False);
    { Кодировка одного файла в виде списка (пустой при ошибке чтения). }
    function FileEncodings(const Path: UnicodeString): TTextList;
    { Кодировки файлов каталога: нормализованное имя -> имя для вывода. }
    function DirEncodings(const Directory: UnicodeString): TStringList;
    { Рекурсивный обход: каталоги, где более одной РАЗЛИЧАЮЩЕЙСЯ кодировки. }
    function Scan: TFb2EncodingScanEntryList;

    property StartDir: UnicodeString read FStartDir;
    property Debug: Boolean read FDebug write FDebug;
  end;

{ Определить кодировку FB2-файла (BOM, затем encoding в декларации). }
function DetectEncoding(const Path: UnicodeString): UnicodeString;

{ Нормализовать имя кодировки для сравнения (регистр, пробелы). }
function NormalizeEncoding(const Encoding: UnicodeString): UnicodeString;

implementation

{ Совпадает ли последовательность байт (без учёта регистра) с Lit (в нижнем). }
function MatchCI(const Data: TBytes; Index, Len: Integer;
  const Lit: AnsiString): Boolean;
var
  K: Integer;
  C: AnsiChar;
begin
  Result := False;
  if Index + Length(Lit) > Len then
    Exit;
  for K := 1 to Length(Lit) do
  begin
    C := AnsiChar(Data[Index + K - 1]);
    if (C >= 'A') and (C <= 'Z') then
      C := AnsiChar(Ord(C) + 32);
    if C <> Lit[K] then
      Exit;
  end;
  Result := True;
end;

{ BOM в начале данных -> имя кодировки. Длинные последовательности раньше. }
function MatchBom(const Data: TBytes; out Name: UnicodeString): Boolean;
var
  L: Integer;
begin
  Result := True;
  L := Length(Data);
  if (L >= 3) and (Data[0] = $EF) and (Data[1] = $BB) and (Data[2] = $BF) then
    Name := 'utf-8'
  else if (L >= 4) and (Data[0] = $FF) and (Data[1] = $FE) and
    (Data[2] = 0) and (Data[3] = 0) then
    Name := 'utf-32-le'
  else if (L >= 4) and (Data[0] = 0) and (Data[1] = 0) and
    (Data[2] = $FE) and (Data[3] = $FF) then
    Name := 'utf-32-be'
  else if (L >= 2) and (Data[0] = $FF) and (Data[1] = $FE) then
    Name := 'utf-16-le'
  else if (L >= 2) and (Data[0] = $FE) and (Data[1] = $FF) then
    Name := 'utf-16-be'
  else
    Result := False;
end;

{ Найти encoding="..." в заголовке (значения — ASCII). }
function FindEncodingAttr(const Data: TBytes; out Value: UnicodeString): Boolean;
var
  I, J, L: Integer;
  Quote: Byte;
begin
  Result := False;
  Value := '';
  L := Length(Data);
  I := 0;
  while I + 8 <= L do
  begin
    if MatchCI(Data, I, L, 'encoding') then
    begin
      J := I + 8;
      while (J < L) and (Data[J] in [9, 10, 13, 32]) do
        Inc(J);
      if (J < L) and (Data[J] = Ord('=')) then
      begin
        Inc(J);
        while (J < L) and (Data[J] in [9, 10, 13, 32]) do
          Inc(J);
        if (J < L) and ((Data[J] = Ord('"')) or (Data[J] = Ord(''''))) then
        begin
          Quote := Data[J];
          Inc(J);
          while (J < L) and (Data[J] <> Quote) do
          begin
            Value := Value + WideChar(Data[J]);
            Inc(J);
          end;
          Value := UnicodeString(Trim(Value));
          Result := True;
          Exit;
        end;
      end;
    end;
    Inc(I);
  end;
end;

function NormalizeEncoding(const Encoding: UnicodeString): UnicodeString;
begin
  Result := LowerCase(Trim(Encoding));
end;

function DetectEncoding(const Path: UnicodeString): UnicodeString;
var
  FS: TFileStream;
  Head: TBytes;
  N: Int64;
  Name: UnicodeString;
begin
  try
    FS := TFileStream.Create(Path, fmOpenRead or fmShareDenyWrite);
  except
    Exit('');   { файл недоступен — как в Python }
  end;
  try
    N := FS.Size;
    if N > HEAD_SIZE then
      N := HEAD_SIZE;
    if N < 0 then
      N := 0;
    SetLength(Head, N);
    if N > 0 then
      FS.ReadBuffer(Head[0], N);
  finally
    FS.Free;
  end;

  if MatchBom(Head, Name) then
  begin
    Result := Name;
    Exit;
  end;
  if FindEncodingAttr(Head, Name) then
  begin
    Result := Name;
    Exit;
  end;
  Result := DEFAULT_ENCODING;
end;

{ --- TFb2EncodingScanEntry ------------------------------------------ }

constructor TFb2EncodingScanEntry.Create;
begin
  inherited Create;
  Encodings := TTextList.Create;
end;

destructor TFb2EncodingScanEntry.Destroy;
begin
  FreeAndNil(Encodings);
  inherited Destroy;
end;

{ --- TFb2EncodingScanner -------------------------------------------- }

constructor TFb2EncodingScanner.Create(const StartDir: UnicodeString;
  Debug: Boolean);
begin
  inherited Create;
  FStartDir := StartDir;
  FDebug := Debug;
end;

function TFb2EncodingScanner.FileEncodings(const Path: UnicodeString): TTextList;
var
  Enc: UnicodeString;
begin
  Result := TTextList.Create;
  Enc := DetectEncoding(Path);
  if Enc = '' then
    Exit;               { не удалось определить кодировку }
  Result.Add(Enc);
end;

function TFb2EncodingScanner.DirEncodings(
  const Directory: UnicodeString): TStringList;
var
  Files: TStringList;
  Encodings: TTextList;
  I, J: Integer;
  Key: UnicodeString;
begin
  Result := TStringList.Create;
  Files := ListFiles(Directory, FB2_MASK);
  try
    for I := 0 to Files.Count - 1 do
    begin
      Encodings := FileEncodings(Files[I]);
      try
        for J := 0 to Encodings.Count - 1 do
        begin
          Key := NormalizeEncoding(Encodings[J]);
          if Result.IndexOfName(Key) < 0 then
            Result.Values[Key] := Encodings[J];
        end;
      finally
        Encodings.Free;
      end;
    end;
  finally
    Files.Free;
  end;
end;

procedure TFb2EncodingScanner.ScanDir(const Dir: UnicodeString;
  Results: TFb2EncodingScanEntryList);
var
  Enc: TStringList;
  Sorted, Sub: TStringList;
  I: Integer;
  Entry: TFb2EncodingScanEntry;
begin
  Enc := DirEncodings(Dir);
  try
    if Enc.Count > 1 then
    begin
      Sorted := TStringList.Create;
      try
        Sorted.Sorted := True;
        Sorted.Duplicates := dupIgnore;
        for I := 0 to Enc.Count - 1 do
          Sorted.Add(Enc.ValueFromIndex[I]);
        Entry := TFb2EncodingScanEntry.Create;
        Entry.Directory := Dir;
        for I := 0 to Sorted.Count - 1 do
          Entry.Encodings.Add(Sorted[I]);
        Results.Add(Entry);
      finally
        Sorted.Free;
      end;
    end;
  finally
    Enc.Free;
  end;

  Sub := ListDirs(Dir);
  try
    for I := 0 to Sub.Count - 1 do
      ScanDir(IncludeTrailingPathDelimiter(Dir) + Sub[I], Results);
  finally
    Sub.Free;
  end;
end;

function TFb2EncodingScanner.Scan: TFb2EncodingScanEntryList;
begin
  Result := TFb2EncodingScanEntryList.Create;
  if DirectoryExists(FStartDir) then
    ScanDir(FStartDir, Result);
end;

end.
