{ CLI для fb2_to_epub — аналог main() из fb2_to_epub.py.

  Использование:
      fb2epub_cli <файл.fb2> [выход.epub] [--epub3] }

program fb2epub_cli;

{$mode objfpc}{$H+}
{$codepage utf8}

uses
  Classes, SysUtils
  {$IFDEF WINDOWS}, Windows{$ENDIF}
  , fb2_structures, fb2_to_epub, fb2_errors;

procedure SetupConsole;
begin
  {$IFDEF WINDOWS}
  SetConsoleOutputCP(65001);
  {$ENDIF}
end;

function HasFlag(const Args: array of UnicodeString;
  const Flag: UnicodeString): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to High(Args) do
    if Args[I] = Flag then
      Exit(True);
end;

function Positionals(const Args: array of UnicodeString): TTextList;
var
  I: Integer;
begin
  Result := TTextList.Create;
  for I := 0 to High(Args) do
    if (Args[I] <> '') and (Args[I][1] <> '-') then
      Result.Add(Args[I]);
end;

var
  Args: array of UnicodeString;
  Pos: TTextList;
  Source, Output: UnicodeString;
  Epub3: Boolean;
  I: Integer;
  C: TFb2ToEpubConverter;
  Path: UnicodeString;
begin
  SetupConsole;
  SetLength(Args, 0);
  for I := 1 to ParamCount do
  begin
    SetLength(Args, Length(Args) + 1);
    Args[High(Args)] := ParamStr(I);
  end;

  Epub3 := HasFlag(Args, '--epub3');
  Pos := Positionals(Args);
  try
    if Pos.Count = 0 then
    begin
      WriteLn(ErrOutput,
        'Использование: fb2epub_cli <файл.fb2> [выход.epub] [--epub3]');
      Halt(2);
    end;
    Source := Pos[0];
    if Pos.Count > 1 then
      Output := Pos[1]
    else
      Output := '';
  finally
    Pos.Free;
  end;

  if Epub3 then
    C := TFb2ToEpubConverter.Create(DEFAULT_CSS, 3)
  else
    C := TFb2ToEpubConverter.Create(DEFAULT_CSS, 2);
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
    WriteLn('EPUB: ', Path, ' ', BoolToStr(Epub3, '(3.0)', '(2.0)'));
    if C.Book <> nil then
    begin
      WriteLn('Документов: ', C.Book.Documents.Count);
      WriteLn('Изображений: ', C.Book.Resources.Count);
    end;
  finally
    C.Free;
  end;
end.
