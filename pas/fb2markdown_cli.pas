{ CLI для fb2_markdown — аналог main() из fb2_markdown.py.

  Использование:
      fb2markdown_cli <файл.fb2> [выход.md] [каталог_изображений]

  По умолчанию выходной файл — рядом с исходным с расширением .md,
  каталог изображений — "images". }

program fb2markdown_cli;

{$mode objfpc}{$H+}
{$codepage utf8}

uses
  SysUtils
  {$IFDEF WINDOWS}, Windows{$ENDIF}
  , fb2_structures, fb2_parser, fb2_markdown;

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
    'Usage: fb2markdown_cli <file.fb2> [out.md] [image_dir]');
end;

var
  Source, Output, ImageDir, Path: UnicodeString;
  Writer: TFb2MarkdownWriter;
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
    Output := ChangeFileExt(Source, '.md');
  if ParamCount > 2 then
    ImageDir := ParamStr(3)
  else
    ImageDir := 'images';

  Writer := TFb2MarkdownWriter.Create(nil, ImageDir);
  try
    Path := Writer.Write(Source, Output);
    WriteLn('Markdown: ', Path);
    WriteLn('Images: ', Writer.Binaries.Count);
  finally
    Writer.Free;
  end;
end.