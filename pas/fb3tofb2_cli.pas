{ CLI для fb3_to_fb2 — аналог main() из fb3_to_fb2.py.

  Использование:
      fb3tofb2_cli <файл.fb3> [выход.fb2] }

program fb3tofb2_cli;

{$mode objfpc}{$H+}
{$codepage utf8}

uses
  Classes, SysUtils
  {$IFDEF WINDOWS}, Windows{$ENDIF}
  , fb2_structures, fb3_to_fb2, fb2_errors;

procedure SetupConsole;
begin
  {$IFDEF WINDOWS}
  SetConsoleOutputCP(65001);
  {$ENDIF}
end;

var
  Source, Output, Path: UnicodeString;
  C: TFb3ToFb2Converter;
begin
  SetupConsole;
  if ParamCount < 1 then
  begin
    WriteLn(ErrOutput, 'Использование: fb3tofb2_cli <файл.fb3> [выход.fb2]');
    Halt(2);
  end;
  Source := ParamStr(1);
  if ParamCount > 1 then
    Output := ParamStr(2)
  else
    Output := ChangeFileExt(Source, '.fb2');

  C := TFb3ToFb2Converter.Create;
  try
    try
      Path := C.Write(Source, Output);
    except
      on E: Exception do
      begin
        WriteLn(ErrOutput, 'Ошибка: ', E.Message);
        Halt(1);
      end;
    end;
    WriteLn('FB2: ', Path);
    if C.Book <> nil then
      WriteLn('Изображений: ', C.Book.Binaries.Count)
    else
      WriteLn('Изображений: 0');
  finally
    C.Free;
  end;
end.
