{ CLI для fb2_to_docx — аналог main() из fb2_to_docx.py.

  Использование:
      fb2todocx_cli <файл.fb2> [выход.docx] }

program fb2todocx_cli;

{$mode objfpc}{$H+}
{$codepage utf8}

uses
  Classes, SysUtils
  {$IFDEF WINDOWS}, Windows{$ENDIF}
  , fb2_structures, fb2_to_docx, fb2_errors;

procedure SetupConsole;
begin
  {$IFDEF WINDOWS}
  SetConsoleOutputCP(65001);
  {$ENDIF}
end;

var
  Source, Output, Path: UnicodeString;
  C: TFb2ToDocxConverter;
begin
  SetupConsole;
  if ParamCount < 1 then
  begin
    WriteLn(ErrOutput, 'Использование: fb2todocx_cli <файл.fb2> [выход.docx]');
    Halt(2);
  end;
  Source := ParamStr(1);
  if ParamCount > 1 then
    Output := ParamStr(2)
  else
    Output := ChangeFileExt(Source, '.docx');

  C := TFb2ToDocxConverter.Create;
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
    WriteLn('DOCX: ', Path);
    if C.Book <> nil then
    begin
      WriteLn('Изображений: ', C.Book.Images.Count);
      WriteLn('Гиперссылок: ', C.Book.Hyperlinks.Count);
    end
    else
      WriteLn('Изображений: 0');
  finally
    C.Free;
  end;
end.
