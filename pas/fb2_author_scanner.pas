unit fb2_author_scanner;
{ Поиск каталогов, в которых FB2-файлы имеют РАЗНЫХ авторов —
  перевод fb2_author_scanner.py.

  Имена авторов формируются из полей authorType (last-name, first-name,
  middle-name), при их отсутствии — nickname. Сравнение выполняется без учёта
  регистра и лишних пробелов. }

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Classes, SysUtils, fgl, fb2_structures, fb2_parser, fb2_files;

const
  { Расширение FB2-файлов. }
  FB2_MASK = '*.fb2';

type
  { Каталог с различающимися авторами FB2-файлов. }
  TFb2AuthorScanEntry = class
  public
    Directory: UnicodeString;
    Authors: TTextList;        { отсортированные имена авторов }
    constructor Create;
    destructor Destroy; override;
  end;

  TFb2AuthorScanEntryList = specialize TFPGObjectList<TFb2AuthorScanEntry>;

  { Рекурсивный поиск каталогов с различающимися авторами. }
  TFb2AuthorScanner = class
  private
    FStartDir: UnicodeString;
    FDebug: Boolean;
    FParser: TFb2Parser;
    procedure ScanDir(const Dir: UnicodeString;
      Results: TFb2AuthorScanEntryList);
  public
    constructor Create(const StartDir: UnicodeString; Debug: Boolean = False);
    destructor Destroy; override;
    { Имена авторов одного файла (пустой список при ошибке разбора). }
    function FileAuthors(const Path: UnicodeString): TTextList;
    { Авторы файлов каталога: нормализованное имя -> имя для вывода. }
    function DirAuthors(const Directory: UnicodeString): TStringList;
    { Рекурсивный обход: каталоги, где более одного РАЗЛИЧАЮЩЕГОСЯ автора. }
    function Scan: TFb2AuthorScanEntryList;

    property StartDir: UnicodeString read FStartDir;
    property Debug: Boolean read FDebug write FDebug;
    property Parser: TFb2Parser read FParser;
  end;

{ Имя автора: "Фамилия Имя Отчество" либо nickname (пусто, если данных нет). }
function FormatAuthorName(Author: TAuthor): UnicodeString;

{ Нормализовать имя для сравнения (регистр + лишние пробелы). }
function NormalizeAuthorName(const Name: UnicodeString): UnicodeString;

implementation

{ Сжать последовательности пробельных символов в один пробел и обрезать. }
function CollapseSpaces(const S: UnicodeString): UnicodeString;
var
  I: Integer;
  C: WideChar;
  PrevSpace: Boolean;
begin
  Result := '';
  PrevSpace := True;   { чтобы обрезать ведущие пробелы }
  for I := 1 to Length(S) do
  begin
    C := S[I];
    if (C = ' ') or (C = #9) or (C = #10) or (C = #13) then
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
  Result := UnicodeString(Trim(Result));
end;

function FormatAuthorName(Author: TAuthor): UnicodeString;
var
  Parts: TTextList;
  S: UnicodeString;
begin
  Result := '';
  if Author = nil then
    Exit;
  Parts := TTextList.Create;
  try
    if Trim(Author.LastName) <> '' then
      Parts.Add(Trim(Author.LastName));
    if Trim(Author.FirstName) <> '' then
      Parts.Add(Trim(Author.FirstName));
    if Trim(Author.MiddleName) <> '' then
      Parts.Add(Trim(Author.MiddleName));
    S := JoinText(Parts, ' ');
  finally
    Parts.Free;
  end;
  if S <> '' then
    Result := S
  else
    Result := Trim(Author.Nickname);
end;

function NormalizeAuthorName(const Name: UnicodeString): UnicodeString;
begin
  Result := LowerCase(CollapseSpaces(Name));
end;

{ --- TFb2AuthorScanEntry -------------------------------------------- }

constructor TFb2AuthorScanEntry.Create;
begin
  inherited Create;
  Authors := TTextList.Create;
end;

destructor TFb2AuthorScanEntry.Destroy;
begin
  FreeAndNil(Authors);
  inherited Destroy;
end;

{ --- TFb2AuthorScanner ---------------------------------------------- }

constructor TFb2AuthorScanner.Create(const StartDir: UnicodeString;
  Debug: Boolean);
begin
  inherited Create;
  FStartDir := StartDir;
  FDebug := Debug;
  FParser := TFb2Parser.Create;
end;

destructor TFb2AuthorScanner.Destroy;
begin
  FreeAndNil(FParser);
  inherited Destroy;
end;

function TFb2AuthorScanner.FileAuthors(const Path: UnicodeString): TTextList;
var
  Desc: TDescription;
  TI: TTitleInfo;
  I: Integer;
  Name: UnicodeString;
begin
  Result := TTextList.Create;
  Desc := nil;
  try
    try
      FParser.LoadFile(Path);
      Desc := FParser.Parse;
    except
      Exit;                 { файл может быть повреждён }
    end;
    if Desc = nil then
      Exit;
    TI := Desc.TitleInfo;
    if TI = nil then
      Exit;
    for I := 0 to TI.Authors.Count - 1 do
    begin
      Name := FormatAuthorName(TAuthor(TI.Authors[I]));
      if Name <> '' then
        Result.Add(Name);
    end;
  finally
    Desc.Free;
  end;
end;

function TFb2AuthorScanner.DirAuthors(
  const Directory: UnicodeString): TStringList;
var
  Files: TStringList;
  Names: TTextList;
  I, J: Integer;
  Key: UnicodeString;
begin
  Result := TStringList.Create;
  Files := ListFiles(Directory, FB2_MASK);
  try
    for I := 0 to Files.Count - 1 do
    begin
      Names := FileAuthors(Files[I]);
      try
        for J := 0 to Names.Count - 1 do
        begin
          Key := NormalizeAuthorName(Names[J]);
          if Result.IndexOfName(Key) < 0 then
            Result.Values[Key] := Names[J];
        end;
      finally
        Names.Free;
      end;
    end;
  finally
    Files.Free;
  end;
end;

procedure TFb2AuthorScanner.ScanDir(const Dir: UnicodeString;
  Results: TFb2AuthorScanEntryList);
var
  Names: TStringList;
  Sorted, Sub: TStringList;
  I: Integer;
  Entry: TFb2AuthorScanEntry;
begin
  Names := DirAuthors(Dir);
  try
    if Names.Count > 1 then
    begin
      Sorted := TStringList.Create;
      try
        Sorted.Sorted := True;
        Sorted.Duplicates := dupIgnore;
        for I := 0 to Names.Count - 1 do
          Sorted.Add(Names.ValueFromIndex[I]);
        Entry := TFb2AuthorScanEntry.Create;
        Entry.Directory := Dir;
        for I := 0 to Sorted.Count - 1 do
          Entry.Authors.Add(Sorted[I]);
        Results.Add(Entry);
      finally
        Sorted.Free;
      end;
    end;
  finally
    Names.Free;
  end;

  Sub := ListDirs(Dir);
  try
    for I := 0 to Sub.Count - 1 do
      ScanDir(IncludeTrailingPathDelimiter(Dir) + Sub[I], Results);
  finally
    Sub.Free;
  end;
end;

function TFb2AuthorScanner.Scan: TFb2AuthorScanEntryList;
begin
  Result := TFb2AuthorScanEntryList.Create;
  if DirectoryExists(FStartDir) then
    ScanDir(FStartDir, Result);
end;

end.
