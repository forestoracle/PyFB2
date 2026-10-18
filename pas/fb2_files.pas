unit fb2_files;
{ Вспомогательные функции работы с файлами и каталогами (Pascal-only).

  Аналога в Python-версии нет: там используются pathlib/os.walk, в Pascal —
  FindFirst/FindNext. Модуль выделен, чтобы не дублировать обход каталогов в
  сканерах, переименователях, трансcoder'е и индексе. }

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Classes, SysUtils;

{ Подкаталоги первого уровня (без '.' и '..'), отсортированные по имени. }
function ListDirs(const Dir: UnicodeString): TStringList;

{ Файлы по маске в каталоге (НЕ рекурсивно), отсортированные (полные пути). }
function ListFiles(const Dir, Mask: UnicodeString): TStringList;

{ Файлы по маске во всём поддереве, отсортированные (полные пути). }
function ListFilesRecursive(const Dir, Mask: UnicodeString): TStringList;

{ Первые MaxBytes байт файла; пустой массив — если файл недоступен. }
function ReadFileHead(const Path: UnicodeString; MaxBytes: Integer): TBytes;

{ Файл целиком; пустой массив — если файл недоступен. }
function ReadFileBytes(const Path: UnicodeString): TBytes;

{ Относительный путь Path от Base (аналог os.path.relpath). }
function RelPath(const Base, Path: UnicodeString): UnicodeString;

{ Записать байты в файл атомарно (через временный файл + переименование). }
procedure WriteFileAtomic(const Path: UnicodeString; const Data: TBytes);

implementation

function ListDirs(const Dir: UnicodeString): TStringList;
var
  SR: TSearchRec;
begin
  Result := TStringList.Create;
  Result.Sorted := True;
  Result.Duplicates := dupIgnore;
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faDirectory, SR) = 0 then
  try
    repeat
      if (SR.Name <> '.') and (SR.Name <> '..') and
        ((SR.Attr and faDirectory) <> 0) then
        Result.Add(SR.Name);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

function ListFiles(const Dir, Mask: UnicodeString): TStringList;
var
  SR: TSearchRec;
begin
  Result := TStringList.Create;
  Result.Sorted := True;
  Result.Duplicates := dupIgnore;
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + Mask, faAnyFile, SR) = 0 then
  try
    repeat
      if (SR.Name <> '.') and (SR.Name <> '..') and
        ((SR.Attr and faDirectory) = 0) then
        Result.Add(IncludeTrailingPathDelimiter(Dir) + SR.Name);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

procedure AppendAll(Dest, Src: TStringList);
var
  I: Integer;
begin
  for I := 0 to Src.Count - 1 do
    Dest.Add(Src[I]);
end;

function ListFilesRecursive(const Dir, Mask: UnicodeString): TStringList;
var
  Sub, Local: TStringList;
  I: Integer;
begin
  Result := TStringList.Create;
  Result.Sorted := True;
  Result.Duplicates := dupIgnore;

  Local := ListFiles(Dir, Mask);
  try
    AppendAll(Result, Local);
  finally
    Local.Free;
  end;

  Sub := ListDirs(Dir);
  try
    for I := 0 to Sub.Count - 1 do
    begin
      Local := ListFilesRecursive(
        IncludeTrailingPathDelimiter(Dir) + Sub[I], Mask);
      try
        AppendAll(Result, Local);
      finally
        Local.Free;
      end;
    end;
  finally
    Sub.Free;
  end;
end;

function ReadFileHead(const Path: UnicodeString; MaxBytes: Integer): TBytes;
var
  FS: TFileStream;
  N: Integer;
begin
  SetLength(Result, 0);
  try
    FS := TFileStream.Create(Path, fmOpenRead or fmShareDenyWrite);
  except
    Exit;
  end;
  try
    N := FS.Size;
    if N > MaxBytes then
      N := MaxBytes;
    if N < 0 then
      N := 0;
    SetLength(Result, N);
    if N > 0 then
      FS.ReadBuffer(Result[0], N);
  finally
    FS.Free;
  end;
end;

function ReadFileBytes(const Path: UnicodeString): TBytes;
var
  FS: TFileStream;
  N: Int64;
begin
  SetLength(Result, 0);
  try
    FS := TFileStream.Create(Path, fmOpenRead or fmShareDenyWrite);
  except
    Exit;
  end;
  try
    N := FS.Size;
    if N < 0 then
      N := 0;
    SetLength(Result, N);
    if N > 0 then
      FS.ReadBuffer(Result[0], N);
  finally
    FS.Free;
  end;
end;

function RelPath(const Base, Path: UnicodeString): UnicodeString;
var
  B, P: UnicodeString;
begin
  B := IncludeTrailingPathDelimiter(ExpandFileName(Base));
  P := ExpandFileName(Path);
  if LowerCase(Copy(P, 1, Length(B))) = LowerCase(B) then
    Result := Copy(P, Length(B) + 1, MaxInt)
  else
    Result := P;
end;

procedure WriteFileAtomic(const Path: UnicodeString; const Data: TBytes);
var
  Dir, Tmp: UnicodeString;
  FS: TFileStream;
begin
  Dir := ExtractFileDir(Path);
  if Dir <> '' then
    ForceDirectories(Dir);
  Tmp := Path + '.tmp';
  FS := TFileStream.Create(Tmp, fmCreate);
  try
    if Length(Data) > 0 then
      FS.WriteBuffer(Data[0], Length(Data));
  finally
    FS.Free;
  end;
  if FileExists(Path) then
    DeleteFile(Path);
  if not RenameFile(Tmp, Path) then
    raise EFOpenError.CreateFmt('Не удалось заменить файл: %s', [Path]);
end;

end.
