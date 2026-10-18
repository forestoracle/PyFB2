unit fb2_archive;
{ Чтение ZIP-архива (EPUB) в память.

  Обёртка над TUnZipper (paszlib): все записи распаковываются в TMemoryStream
  через события OnCreateStream/OnDoneStream, поэтому архив НЕ распаковывается
  на диск. Имена записей берутся из UTF-8 поля (если задано), иначе из
  системного ArchiveFileName.

  Используется конвертером EPUB -> FB2 (аналог zipfile.ZipFile в Python). }

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

    { Прочитать архив с диска. }
    procedure LoadFromFile(const FileName: UnicodeString);

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

procedure TEpubArchive.LoadFromFile(const FileName: UnicodeString);
var
  UZ: TUnZipper;
begin
  FFile := FileName;
  UZ := TUnZipper.Create;
  try
    UZ.FileName := UTF8Encode(FileName);
    UZ.OnCreateStream := @HandleCreateStream;
    UZ.OnDoneStream := @HandleDoneStream;
    UZ.UnZipAllFiles;
  finally
    UZ.Free;
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

end.
