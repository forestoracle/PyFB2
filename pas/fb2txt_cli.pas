{ CLI для fb2_to_txt — аналог main() из fb2_to_txt.py.

  Использование:
      fb2txt_cli <файл.fb2> [выход.txt] [--no-toc] [--no-metadata]
          [--no-annotation] [--no-epigraphs] [--no-underline]
          [--level N] [--width N] [--indent СТРОКА] [--placeholder ТЕКСТ]

  По умолчанию (как в Python) оглавление включается. }

program fb2txt_cli;

{$mode objfpc}{$H+}
{$codepage utf8}

uses
  Classes, SysUtils
  {$IFDEF WINDOWS}, Windows{$ENDIF}
  , fb2_structures, fb2_to_txt, fb2_errors;

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

function StrValue(const Args: array of UnicodeString;
  const Flag: UnicodeString; const Default: UnicodeString): UnicodeString;
var
  I: Integer;
begin
  Result := Default;
  for I := 0 to High(Args) do
    if (Args[I] = Flag) and (I < High(Args)) then
      Result := Args[I + 1];
end;

function IntValue(const Args: array of UnicodeString;
  const Flag: UnicodeString; Default: Integer): Integer;
var
  I: Integer;
begin
  Result := Default;
  for I := 0 to High(Args) do
    if (Args[I] = Flag) and (I < High(Args)) then
      Result := StrToIntDef(Args[I + 1], Default);
end;

const
  VALUE_FLAGS: array[0..3] of UnicodeString =
    ('--level', '--width', '--indent', '--placeholder');

{ Позиционные аргументы (не начинающиеся с '-' и не значения флагов). }
function Positionals(const Args: array of UnicodeString): TTextList;
var
  I, J: Integer;
  IsValue: Boolean;
begin
  Result := TTextList.Create;
  I := 0;
  while I <= High(Args) do
  begin
    if Args[I] = '' then
    begin
      Inc(I);
      Continue;
    end;
    if Args[I][1] = '-' then
    begin
      IsValue := False;
      for J := Low(VALUE_FLAGS) to High(VALUE_FLAGS) do
        if Args[I] = VALUE_FLAGS[J] then
          IsValue := True;
      if IsValue then
        Inc(I, 2)
      else
        Inc(I);
      Continue;
    end;
    Result.Add(Args[I]);
    Inc(I);
  end;
end;

var
  Args: array of UnicodeString;
  Pos: TTextList;
  Source, Output: UnicodeString;
  I: Integer;
  C: TFb2ToTxtConverter;
  Path: UnicodeString;
begin
  SetupConsole;
  SetLength(Args, 0);
  for I := 1 to ParamCount do
  begin
    SetLength(Args, Length(Args) + 1);
    Args[High(Args)] := ParamStr(I);
  end;
  if Length(Args) = 0 then
  begin
    WriteLn(ErrOutput, 'Использование: fb2txt_cli <файл.fb2> [выход.txt] ...');
    Halt(2);
  end;

  Pos := Positionals(Args);
  try
    if Pos.Count = 0 then
    begin
      WriteLn(ErrOutput, 'Не указан исходный файл');
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

  C := TFb2ToTxtConverter.Create(
    IntValue(Args, '--level', 1),
    6,
    not HasFlag(Args, '--no-metadata'),
    not HasFlag(Args, '--no-toc'),
    'Оглавление',
    not HasFlag(Args, '--no-annotation'),
    not HasFlag(Args, '--no-epigraphs'),
    StrValue(Args, '--indent', '    '),
    True,
    not HasFlag(Args, '--no-underline'),
    StrValue(Args, '--placeholder', '[изображение]'),
    IntValue(Args, '--width', 0));
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
  finally
    C.Free;
  end;
  WriteLn('TXT: ', Path);
end.
