unit fb2_group_renamer;
{ Групповое переименование FB2-файлов — перевод fb2_group_renamer.py.

  Обходит каталог (при необходимости рекурсивно) и переименовывает каждый
  найденный *.fb2 через TFB2Renamer по одному шаблону. Ошибки отдельных
  файлов не прерывают обработку.

  Пример:
      var G: TFB2GroupRenamer;
      begin
        G := TFB2GroupRenamer.Create('C:\Books', '$Al', '$Al $Tt');
        try
          WriteLn('Переименовано: ', G.RenameAll);
        finally
          G.Free;
        end;
      end; }

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Classes, SysUtils, fb2_files, fb2_renamer;

const
  { Расширение FB2-файлов. }
  FB2_MASK = '*.fb2';

type
  { Групповое переименование FB2-файлов. }
  TFB2GroupRenamer = class
  private
    FStartDir: UnicodeString;
    FOutDir: UnicodeString;
    FTemplate: UnicodeString;
    FDebug: Boolean;
  public
    constructor Create(const StartDir, OutDir, Template: UnicodeString;
      Debug: Boolean = False);
    { Переименовать файлы; возвращает число успешно переименованных. }
    function RenameAll(Recursive: Boolean = False): Integer;

    property StartDir: UnicodeString read FStartDir;
    property OutDir: UnicodeString read FOutDir;
    property Template: UnicodeString read FTemplate;
  end;

implementation

constructor TFB2GroupRenamer.Create(const StartDir, OutDir, Template: UnicodeString;
  Debug: Boolean);
begin
  inherited Create;
  FStartDir := StartDir;
  FTemplate := Template;
  FDebug := Debug;
  FOutDir := OutDir;
end;

function TFB2GroupRenamer.RenameAll(Recursive: Boolean): Integer;
var
  Files: TStringList;
  I: Integer;
  Renamer: TFB2Renamer;
begin
  Result := 0;
  if not DirectoryExists(FStartDir) then
    Exit;

  if Recursive then
    Files := ListFilesRecursive(FStartDir, FB2_MASK)
  else
    Files := ListFiles(FStartDir, FB2_MASK);
  try
    for I := 0 to Files.Count - 1 do
    begin
      Renamer := nil;
      try
        Renamer := TFB2Renamer.Create(Files[I], FTemplate, FOutDir, FDebug);
        Renamer.Rename;
        Inc(Result);
      except
        { как в Python: ошибка отдельного файла не прерывает обработку }
      end;
      Renamer.Free;
    end;
  finally
    Files.Free;
  end;
end;

end.
