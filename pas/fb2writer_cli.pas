{ CLI для fb2_writer — аналог main() из fb2_writer.py (round-trip FB2).

  Использование:
      fb2writer_cli <вход.fb2> [выход.fb2]

  Читает FB2, разбирает его в структуры (fb2_parser) и сериализует обратно
  (fb2_writer). Без второго аргумента XML печатается в stdout, иначе
  записывается в файл. Это проверка цикла «разбор → сборка» (round-trip). }

program fb2writer_cli;

{$mode objfpc}{$H+}
{$codepage utf8}

uses
  SysUtils
  {$IFDEF WINDOWS}, Windows{$ENDIF}
  , fb2_structures, fb2_parser, fb2_writer;

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
    'Использование: fb2writer_cli <вход.fb2> [выход.fb2]');
end;

var
  Parser: TFb2Parser;
  Writer: TFb2Writer;
  Book: TFictionBook;
  Xml: UnicodeString;
begin
  SetupConsole;
  if ParamCount < 1 then
  begin
    PrintUsage;
    Halt(2);
  end;

  Parser := TFb2Parser.Create;
  Writer := TFb2Writer.Create;
  Book := TFictionBook.Create;
  try
    try
      Parser.LoadFile(ParamStr(1));
    except
      on E: Exception do
      begin
        WriteLn(ErrOutput, 'Ошибка чтения: ', E.Message);
        Halt(1);
      end;
    end;

    { Списки, возвращённые парсером, передаём книге: она станет их
      владельцем и освободит при удалении. }
    Book.Stylesheets.Free;
    Book.Stylesheets := Parser.ParseStylesheets;
    Book.Description := Parser.Parse;
    Book.Bodies.Free;
    Book.Bodies := Parser.ParseBodies;
    Book.Binaries.Free;
    Book.Binaries := Parser.ParseBinaries;

    if ParamCount > 1 then
    begin
      try
        Writer.Write(Book, ParamStr(2));
      except
        on E: Exception do
        begin
          WriteLn(ErrOutput, 'Ошибка записи: ', E.Message);
          Halt(1);
        end;
      end;
      WriteLn('Записано: ', ParamStr(2));
      WriteLn('Тела: ', Book.Bodies.Count,
        ', binary: ', Book.Binaries.Count);
    end
    else
    begin
      Xml := Writer.ToXML(Book);
      Write(Xml);
    end;
  finally
    Book.Free;
    Writer.Free;
    Parser.Free;
  end;
end.
