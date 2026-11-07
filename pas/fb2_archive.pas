unit fb2_archive;
{ Чтение ZIP-архива в память.

  Обёртка над TUnZipper (paszlib): записи распаковываются в TMemoryStream
  через события OnCreateStream/OnDoneStream, поэтому архив НЕ распаковывается
  на диск. Имена записей берутся из UTF-8 поля (если задано), иначе из
  системного ArchiveFileName.

  Модуль общий для двух задач:
    * EPUB -> FB2 (аналог zipfile.ZipFile в Python) — читается весь архив;
    * читалка TFb2Viewer — «однокнижный» архив book.fb2.zip: сначала имена
      записей читаются без распаковки (ListNames), затем распаковывается
      ТОЛЬКО выбранная книга (LoadFromFile(..., OnlyEntry)); помощники
      IsZipArchive / SelectFb2Entry / ReadFb2FromZip инкапсулируют выбор
      записи с книгой.
}

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Classes, SysUtils, zipper;

type
  TEpubArchive = class
  private
    FNames: TStringList;      { имя записи (Unicode) -> индекс в FStreams }
    FStreams: TList;          { TMemoryStream, владелец — архив }
    FFile: UnicodeString;
    procedure HandleCreateStream(Sender: TObject; var AStream: TStream;
      AItem: TFullZipFileEntry);
    procedure HandleDoneStream(Sender: TObject; var AStream: TStream;
      AItem: TFullZipFileEntry);
  public
    constructor Create;
    destructor Destroy; override;

    { Прочитать архив с диска. OnlyEntry = '' — распаковать все записи,
      иначе распаковывается только запись с этим именем (остальные книги
      многокнижного архива в память не попадают). }
    procedure LoadFromFile(const FileName: UnicodeString;
      const OnlyEntry: UnicodeString = '');

    { Имена записей архива БЕЗ распаковки данных (только оглавление ZIP);
      порядок — как в архиве. }
    class procedure ListNames(const FileName: UnicodeString; Names: TStrings);

    { Есть ли запись с таким именем. }
    function Has(const Name: UnicodeString): Boolean;

    { Данные записи; пустой массив, если записи нет. }
    function Read(const Name: UnicodeString): TBytes;

    { Имена всех записей (владелец — вызывающий). }
    function Names: TStringList;

    { Число записей. }
    function Count: Integer;

    property FileName: UnicodeString read FFile;
  end;

  { Общее имя ZIP-архива: тот же класс читает и EPUB, и «однокнижные»
    архивы book.fb2.zip (историческое имя — TEpubArchive). }
  TZipArchive = TEpubArchive;

{ Файл — ZIP-архив (по расширению '.zip'; в библиотеках это book.fb2.zip). }
function IsZipArchive(const FileName: UnicodeString): Boolean;

{ Выбрать в архиве запись с книгой FB2.

  Preferred ('' — автоматически): имя записи или её базовое имя без каталогов.
  Авто: запись, совпадающая с именем архива без '.zip' (book.fb2.zip ->
  book.fb2), затем первая запись с расширением '.fb2', затем единственная
  запись, если у неё нет расширения (book.zip -> book). '' — подходящей записи
  нет. }
function SelectFb2Entry(const Names: TStrings; const ArchiveFile: UnicodeString;
  const Preferred: UnicodeString = ''): UnicodeString;

{ Прочитать книгу из ZIP-архива в память (без временных файлов): байты FB2 и
  имя записи, из которой они взяты. Preferred — см. SelectFb2Entry.

  Исключение — архив не читается, книги в нём нет, запрошенной записи нет или
  она пуста. }
function ReadFb2FromZip(const ArchiveFile, Preferred: UnicodeString;
  out EntryName: UnicodeString): TBytes;

implementation

constructor TEpubArchive.Create;
begin
  inherited Create;
  FNames := TStringList.Create;
  FNames.CaseSensitive := True;
  FStreams := TList.Create;
end;

destructor TEpubArchive.Destroy;
var
  I: Integer;
begin
  for I := 0 to FStreams.Count - 1 do
    TObject(FStreams[I]).Free;
  FreeAndNil(FStreams);
  FreeAndNil(FNames);
  inherited Destroy;
end;

procedure TEpubArchive.HandleCreateStream(Sender: TObject;
  var AStream: TStream; AItem: TFullZipFileEntry);
var
  N: UnicodeString;
begin
  N := UTF8ToString(AItem.UTF8ArchiveFileName);
  if N = '' then
    N := AItem.ArchiveFileName;
  FNames.Add(N);
  AStream := TMemoryStream.Create;
  FStreams.Add(AStream);
end;

procedure TEpubArchive.HandleDoneStream(Sender: TObject;
  var AStream: TStream; AItem: TFullZipFileEntry);
begin
  { Поток остаётся нашим: TUnZipper при назначенном OnDoneStream его не
    освобождает, а просто обнуляет свою ссылку. }
  if AStream <> nil then
    AStream.Position := 0;
end;

procedure TEpubArchive.LoadFromFile(const FileName: UnicodeString;
  const OnlyEntry: UnicodeString);
var
  UZ: TUnZipper;
  Wanted: TStringList;
  I: Integer;
  N: UnicodeString;
begin
  FFile := FileName;
  UZ := TUnZipper.Create;
  try
    UZ.FileName := UTF8Encode(FileName);
    UZ.OnCreateStream := @HandleCreateStream;
    UZ.OnDoneStream := @HandleDoneStream;
    if OnlyEntry = '' then
      UZ.UnZipAllFiles
    else
    begin
      { Распаковываем только нужную запись: у многокнижного архива остальные
        книги в память не попадают. Имена берём из оглавления архива
        (Examine распаковку не делает). }
      Wanted := TStringList.Create;
      try
        UZ.Examine;
        for I := 0 to UZ.Entries.Count - 1 do
        begin
          N := UTF8ToString(UZ.Entries[I].UTF8ArchiveFileName);
          if N = '' then
            N := UZ.Entries[I].ArchiveFileName;
          if WideCompareText(WideString(N), WideString(OnlyEntry)) = 0 then
          begin
            { TUnZipper сопоставляет записи по системному имени (UseUTF8 =
              False), поэтому в список идёт именно ArchiveFileName. }
            Wanted.Add(UZ.Entries[I].ArchiveFileName);
            Break;
          end;
        end;
        if Wanted.Count = 0 then
          raise Exception.CreateFmt('В архиве нет записи "%s": %s',
            [OnlyEntry, FileName]);
        UZ.UnZipFiles(Wanted);
      finally
        Wanted.Free;
      end;
    end;
  finally
    UZ.Free;
  end;
end;

class procedure TEpubArchive.ListNames(const FileName: UnicodeString;
  Names: TStrings);
var
  UZ: TUnZipper;
  I: Integer;
  N: UnicodeString;
begin
  if Names = nil then
    Exit;
  Names.BeginUpdate;
  try
    Names.Clear;
    UZ := TUnZipper.Create;
    try
      UZ.FileName := UTF8Encode(FileName);
      UZ.Examine;                 { только оглавление архива, без распаковки }
      for I := 0 to UZ.Entries.Count - 1 do
      begin
        N := UTF8ToString(UZ.Entries[I].UTF8ArchiveFileName);
        if N = '' then
          N := UZ.Entries[I].ArchiveFileName;
        Names.Add(N);
      end;
    finally
      UZ.Free;
    end;
  finally
    Names.EndUpdate;
  end;
end;

function TEpubArchive.Has(const Name: UnicodeString): Boolean;
begin
  Result := FNames.IndexOf(Name) >= 0;
end;

function TEpubArchive.Read(const Name: UnicodeString): TBytes;
var
  J: Integer;
  MS: TMemoryStream;
begin
  SetLength(Result, 0);
  J := FNames.IndexOf(Name);
  if J < 0 then
    Exit;
  MS := TMemoryStream(FStreams[J]);
  SetLength(Result, MS.Size);
  if MS.Size > 0 then
  begin
    MS.Position := 0;
    MS.ReadBuffer(Result[0], MS.Size);
  end;
end;

function TEpubArchive.Names: TStringList;
begin
  Result := TStringList.Create;
  Result.CaseSensitive := True;
  Result.Assign(FNames);
end;

function TEpubArchive.Count: Integer;
begin
  Result := FNames.Count;
end;

{ ===================== Выбор книги в .fb2.zip ===================== }

{ Расширение имени записи вместе с точкой ('' — расширения нет). Своя
  реализация вместо ExtractFileExt: та в FPC работает с AnsiString и
  потеряла бы не-ASCII символы в имени записи. }
function EntryExt(const Name: UnicodeString): UnicodeString;
var
  I: Integer;
begin
  Result := '';
  I := Length(Name);
  while (I > 0) and (Name[I] <> '.') and (Name[I] <> PathDelim) and
    (Name[I] <> '/') do
    Dec(I);
  if (I > 0) and (Name[I] = '.') then
    Result := Copy(Name, I, MaxInt);
end;

{ Имя записи без каталогов: 'OEBPS/book.fb2' -> 'book.fb2'. }
function EntryBaseName(const Name: UnicodeString): UnicodeString;
var
  I: Integer;
begin
  I := Length(Name);
  while (I > 0) and (Name[I] <> PathDelim) and (Name[I] <> '/') do
    Dec(I);
  Result := Copy(Name, I + 1, MaxInt);
end;

{ Сравнение имён без учёта регистра (Unicode, а не системная кодировка). }
function SameName(const A, B: UnicodeString): Boolean;
begin
  Result := (A <> '') and (B <> '') and
    (WideCompareText(WideString(A), WideString(B)) = 0);
end;

function IsZipArchive(const FileName: UnicodeString): Boolean;
begin
  Result := SameName(EntryExt(EntryBaseName(FileName)), '.zip');
end;

function SelectFb2Entry(const Names: TStrings; const ArchiveFile: UnicodeString;
  const Preferred: UnicodeString): UnicodeString;
var
  Stem: UnicodeString;
  I: Integer;
begin
  Result := '';
  if (Names = nil) or (Names.Count = 0) then
    Exit;

  if Preferred <> '' then
  begin
    { Явно заданная запись: полное имя или только базовое. }
    for I := 0 to Names.Count - 1 do
      if SameName(Names[I], Preferred) or
        SameName(EntryBaseName(Names[I]), Preferred) then
        Exit(Names[I]);
    Exit;
  end;

  { book.fb2.zip -> book.fb2: обычно запись называется так же, как архив. }
  Stem := EntryBaseName(ArchiveFile);
  Stem := Copy(Stem, 1, Length(Stem) - Length(EntryExt(Stem)));
  for I := 0 to Names.Count - 1 do
    if SameName(EntryBaseName(Names[I]), Stem) or SameName(Names[I], Stem) then
      Exit(Names[I]);

  { Иначе — первая запись с расширением .fb2. }
  for I := 0 to Names.Count - 1 do
    if SameName(EntryExt(EntryBaseName(Names[I])), '.fb2') then
      Exit(Names[I]);

  { Единственная запись с именем без расширения (архив собран «как есть»,
    например book.zip с записью 'book'). Запись с чужим расширением
    (readme.txt) книгой не считается. }
  if (Names.Count = 1) and (EntryExt(EntryBaseName(Names[0])) = '') then
    Result := Names[0];
end;

function ReadFb2FromZip(const ArchiveFile, Preferred: UnicodeString;
  out EntryName: UnicodeString): TBytes;
var
  Archive: TEpubArchive;
  Names: TStringList;
begin
  SetLength(Result, 0);
  EntryName := '';
  Names := TStringList.Create;
  Archive := TEpubArchive.Create;
  try
    TEpubArchive.ListNames(ArchiveFile, Names);
    EntryName := SelectFb2Entry(Names, ArchiveFile, Preferred);
    if EntryName = '' then
    begin
      if Preferred <> '' then
        raise Exception.CreateFmt('В архиве нет записи "%s": %s',
          [Preferred, ArchiveFile]);
      raise Exception.CreateFmt('В архиве нет FB2-файла: %s', [ArchiveFile]);
    end;
    Archive.LoadFromFile(ArchiveFile, EntryName);   { только эта запись }
    Result := Archive.Read(EntryName);
  finally
    Archive.Free;
    Names.Free;
  end;
  if Length(Result) = 0 then
    raise Exception.CreateFmt('Пустая запись "%s" в архиве %s',
      [EntryName, ArchiveFile]);
end;

end.
