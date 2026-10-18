{ CLI для fb2_to_mobi — аналог main() из fb2_to_mobi.py.

  Использование:
      fb2tomobi_cli <файл.fb2> [выход.mobi] }

program fb2tomobi_cli;

{$mode objfpc}{$H+}
{$codepage utf8}

uses
  Classes, SysUtils
  {$IFDEF WINDOWS}, Windows{$ENDIF}
  , fb2_structures, fb2_to_mobi, fb2_errors;

procedure SetupConsole;
begin
  {$IFDEF WINDOWS}
  SetConsoleOutputCP(65001);
  {$ENDIF}
end;

var
  Source, Output, Path: UnicodeString;
  C: TFb2ToMobiConverter;
begin
  SetupConsole;
  if ParamCount < 1 then
  begin
    WriteLn(ErrOutput, 'Использование: fb2tomobi_cli <файл.fb2> [выход.mobi]');
    Halt(2);
  end;
  Source := ParamStr(1);
  if ParamCount > 1 then
    Output := ParamStr(2)
  else
    Output := ChangeFileExt(Source, '.mobi');

  C := TFb2ToMobiConverter.Create;
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
    WriteLn('MOBI: ', Path);
    if C.Book <> nil then
      WriteLn('Изображений: ', C.Book.Images.Count)
    else
      WriteLn('Изображений: 0');
  finally
    C.Free;
  end;
end.
