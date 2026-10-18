{ CLI для fb2_parser — аналог main() из fb2_parser.py.

  Использование:
      fb2parser_cli <файл.fb2> [каталог_для_binary]

  Выводит stylesheets, список binary, метаданные <description> и дерево
  заголовков с текстом. }

program fb2parser_cli;

{$mode objfpc}{$H+}
{$codepage utf8}

uses
  SysUtils
  {$IFDEF WINDOWS}, Windows{$ENDIF}
  , fb2_structures, fb2_parser;

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
    'Использование: fb2parser_cli <файл.fb2> [каталог_для_binary]');
end;

var
  Parser: TFb2Parser;
  Stylesheets, Binaries, Bodies: TFb2ObjectList;
  Paths: TTextList;
  Description: TDescription;
  I: Integer;
  Sheet: TStylesheet;
  Binary: TBinary;
begin
  SetupConsole;
  if ParamCount < 1 then
  begin
    PrintUsage;
    Halt(2);
  end;

  Parser := TFb2Parser.Create;
  try
    Parser.LoadFile(ParamStr(1));

    Stylesheets := Parser.ParseStylesheets;
    try
      if Stylesheets.Count > 0 then
      begin
        WriteLn('== stylesheets ==');
        for I := 0 to Stylesheets.Count - 1 do
        begin
          Sheet := TStylesheet(Stylesheets[I]);
          WriteLn('[', Sheet.SheetType, ']');
          WriteLn(Sheet.Value);
        end;
      end;
    finally
      Stylesheets.Free;
    end;

    Binaries := Parser.ParseBinaries;
    try
      if Binaries.Count > 0 then
      begin
        WriteLn('== binaries ==');
        for I := 0 to Binaries.Count - 1 do
        begin
          Binary := TBinary(Binaries[I]);
          WriteLn(Binary.Id, ' [', Binary.ContentType, '] (',
            Length(Parser.BinaryData(Binary)), ' байт)');
        end;
      end;
    finally
      Binaries.Free;
    end;

    if ParamCount > 1 then
    begin
      Paths := Parser.SaveBinaries(ParamStr(2));
      try
        for I := 0 to Paths.Count - 1 do
          WriteLn('сохранено: ', Paths[I]);
      finally
        Paths.Free;
      end;
    end;

    Description := Parser.Parse;
    try
      WriteLn(Parser.Describe(Description));
    finally
      Description.Free;
    end;

    Bodies := Parser.ParseBodies;
    try
      if Bodies.Count > 0 then
        WriteLn(Parser.DescribeBodies(Bodies));
    finally
      Bodies.Free;
    end;
  finally
    Parser.Free;
  end;
end.