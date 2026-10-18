{ CLI для fb2_html — аналог main() из fb2_to_html.py.

  Использование:
      fb2html_cli <файл.fb2> [выход.html] [каталог_изображений]

  По умолчанию выходной файл — рядом с исходным с расширением .html,
  каталог изображений — "images". Оглавление включается всегда. }

program fb2html_cli;

{$mode objfpc}{$H+}
{$codepage utf8}

uses
  SysUtils
  {$IFDEF WINDOWS}, Windows{$ENDIF}
  , fb2_structures, fb2_parser, fb2_html;

{ Включить вывод UTF-8 в консоли Windows (иначе кириллица -> «?»). }
procedure SetupConsole;
begin
  {$IFDEF WINDOWS}
  SetConsoleOutputCP(65001);
  {$ENDIF}
end;

procedure PrintUsage;
begin
  WriteLn(ErrOutput,
    'Использование: fb2html_cli <файл.fb2> [выход.html] [каталог_изображений]');
end;

var
  Source, Output, ImageDir, Path: UnicodeString;
  Converter: TFb2ToHtmlConverter;
begin
  SetupConsole;
  if ParamCount < 1 then
  begin
    PrintUsage;
    Halt(2);
  end;

  Source := ParamStr(1);
  if ParamCount > 1 then
    Output := ParamStr(2)
  else
    Output := ChangeFileExt(Source, '.html');
  if ParamCount > 2 then
    ImageDir := ParamStr(3)
  else
    ImageDir := 'images';

  Converter := TFb2ToHtmlConverter.Create(nil, ImageDir);
  try
    Path := Converter.Write(Source, Output);
    WriteLn('HTML: ', Path);
    WriteLn('Изображений: ', Converter.Binaries.Count);
  finally
    Converter.Free;
  end;
end.
