{ CLI для fb2_to_fb3 — аналог main() из fb2_to_fb3.py.

  Использование:
      fb2tofb3_cli <файл.fb2> [выход.fb3] }

program fb2tofb3_cli;

{$mode objfpc}{$H+}
{$codepage utf8}

uses
  Classes, SysUtils
  {$IFDEF WINDOWS}, Windows{$ENDIF}
  , fb2_structures, fb2_to_fb3, fb2_errors;

procedure SetupConsole;
begin
  {$IFDEF WINDOWS}
  SetConsoleOutputCP(65001);
  {$ENDIF}
end;

var
  Source, Output, Path: UnicodeString;
  C: TFb2ToFb3Converter;
begin
  SetupConsole;
  if ParamCount < 1 then
  begin
    WriteLn(ErrOutput, 'Использование: fb2tofb3_cli <файл.fb2> [выход.fb3]');
    Halt(2);
  end;
  Source := ParamStr(1);
  if ParamCount > 1 then
    Output := ParamStr(2)
  else
    Output := ChangeFileExt(Source, '.fb3');

  C := TFb2ToFb3Converter.Create;
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
    WriteLn('FB3: ', Path);
    if C.Document <> nil then
      WriteLn('Изображений: ', C.Document.Images.Count)
    else
      WriteLn('Изображений: 0');
  finally
    C.Free;
  end;
end.
