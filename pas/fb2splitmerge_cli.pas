{ CLI для fb2_split_merge — аналог main() из fb2_split_merge.py.

  Использование:
      fb2splitmerge_cli split <файл> [-o КАТАЛОГ] [--stem ОСНОВА]
          [--by sections|size|parts] [--level N] [--max-size N] [--parts N]
          [--title-suffix ШАБЛОН] [--no-sequence] [--keep-ids]
      fb2splitmerge_cli merge <выход> <вход> [<вход>...] [--title НАЗВАНИЕ]
          [--no-source-titles] [--keep-metadata] [--no-binaries]

  Коды возврата: 0 — успех, 1 — ошибка, 2 — неверные аргументы. }

program fb2splitmerge_cli;

{$mode objfpc}{$H+}
{$codepage utf8}

uses
  SysUtils
  {$IFDEF WINDOWS}, Windows{$ENDIF}
  , fb2_structures, fb2_split_merge, fb2_errors;

const
  EXIT_OK = 0;
  EXIT_ERRORS = 1;
  EXIT_USAGE = 2;

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

{ Собрать позиционные аргументы (не начинающиеся с '-' и не значения флагов). }
function Positional(const Args: array of UnicodeString): TTextList;
const
  VALUE_FLAGS: array[0..8] of UnicodeString =
    ('-o', '--out-dir', '--stem', '--by', '--level', '--max-size',
     '--parts', '--title-suffix', '--title');
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
  Args, CmdArgs: array of UnicodeString;
  Cmd, Source, OutDir, Stem, OutFile, TitleSuffix, By: UnicodeString;
  Level, MaxSize, Parts: Integer;
  I, P: Integer;
  Splitter: TFb2Splitter;
  Merger: TFb2Merger;
  Paths: TTextList;
  Sources: TTextList;
  Pos: TTextList;
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
    WriteLn(ErrOutput, 'Использование: fb2splitmerge_cli {split|merge} ...');
    Halt(EXIT_USAGE);
  end;

  Cmd := Args[0];
  SetLength(CmdArgs, Length(Args) - 1);
  for I := 0 to High(CmdArgs) do
    CmdArgs[I] := Args[I + 1];

  if Cmd = 'split' then
  begin
    Pos := Positional(CmdArgs);
    try
      if Pos.Count = 0 then
      begin
        WriteLn(ErrOutput, 'split требует исходный файл');
        Halt(EXIT_USAGE);
      end;
      Source := Pos[0];
    finally
      Pos.Free;
    end;
    OutDir := StrValue(CmdArgs, '--out-dir', StrValue(CmdArgs, '-o', ''));
    Stem := StrValue(CmdArgs, '--stem', '');
    By := StrValue(CmdArgs, '--by', SPLIT_MODE_SECTIONS);
    Level := IntValue(CmdArgs, '--level', 1);
    MaxSize := IntValue(CmdArgs, '--max-size', 0);
    Parts := IntValue(CmdArgs, '--parts', 0);
    TitleSuffix := StrValue(CmdArgs, '--title-suffix', '');

    try
      Splitter := TFb2Splitter.Create(Level, By, MaxSize, Parts, TitleSuffix,
        not HasFlag(CmdArgs, '--no-sequence'),
        not HasFlag(CmdArgs, '--keep-ids'));
    except
      on E: Exception do
      begin
        WriteLn(ErrOutput, 'Ошибка: ', E.Message);
        Halt(EXIT_USAGE);
      end;
    end;
    try
      try
        Paths := Splitter.Split(Source, OutDir, Stem);
      except
        on E: Exception do
        begin
          WriteLn(ErrOutput, 'Ошибка: ', E.Message);
          Halt(EXIT_ERRORS);
        end;
      end;
      try
        if Paths.Count = 0 then
        begin
          WriteLn(ErrOutput, 'Не найдено секций для разбиения.');
          Halt(EXIT_ERRORS);
        end;
        for I := 0 to Paths.Count - 1 do
          WriteLn(Paths[I]);
        WriteLn(ErrOutput, 'Частей: ', Paths.Count);
      finally
        Paths.Free;
      end;
    finally
      Splitter.Free;
    end;
  end
  else if Cmd = 'merge' then
  begin
    Pos := Positional(CmdArgs);
    try
      if Pos.Count < 2 then
      begin
        WriteLn(ErrOutput, 'merge требует выходной файл и хотя бы один входной');
        Halt(EXIT_USAGE);
      end;
      OutFile := Pos[0];
      Sources := TTextList.Create;
      try
        for I := 1 to Pos.Count - 1 do
          Sources.Add(Pos[I]);
        Merger := TFb2Merger.Create(StrValue(CmdArgs, '--title', ''),
          not HasFlag(CmdArgs, '--keep-metadata'),
          not HasFlag(CmdArgs, '--no-source-titles'),
          not HasFlag(CmdArgs, '--no-binaries'));
        try
          try
            WriteLn(Merger.MergeToFile(Sources, OutFile));
          except
            on E: Exception do
            begin
              WriteLn(ErrOutput, 'Ошибка: ', E.Message);
              Halt(EXIT_ERRORS);
            end;
          end;
        finally
          Merger.Free;
        end;
      finally
        Sources.Free;
      end;
    finally
      Pos.Free;
    end;
  end
  else
  begin
    WriteLn(ErrOutput, 'Неизвестная команда: ', Cmd);
    Halt(EXIT_USAGE);
  end;
end.
