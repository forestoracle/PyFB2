{ CLI для fb2_index — аналог main() из fb2_index.py.

  Использование:
      fb2index_cli [--db ФАЙЛ] <команда> [аргументы]

  Команды:
      build <каталог> [-r] [--force] [--hash] [--no-text] [--text-limit N]
      stats
      authors [-n N]
      books <имя автора>
      search <запрос> [--by ПОЛЕ] [-n N]
      find <запрос> [-n N] [--snippet-length N] [--no-prefix]
      dups [-n N] }

program fb2index_cli;

{$mode objfpc}{$H+}
{$codepage utf8}

uses
  SysUtils
  {$IFDEF WINDOWS}, Windows{$ENDIF}
  , fb2_index, fb2_errors;

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

function FlagValue(const Args: array of UnicodeString;
  const Flag: UnicodeString; Default: Integer): Integer;
var
  I: Integer;
begin
  Result := Default;
  for I := 0 to High(Args) do
    if (Args[I] = Flag) and (I < High(Args)) then
      Result := StrToIntDef(Args[I + 1], Default);
end;

function ByValue(const Args: array of UnicodeString): UnicodeString;
var
  I: Integer;
begin
  Result := 'any';
  for I := 0 to High(Args) do
    if (Args[I] = '--by') and (I < High(Args)) then
      Result := Args[I + 1];
end;

{ Первый аргумент, не начинающийся с '-'. }
function FirstPositional(const Args: array of UnicodeString): UnicodeString;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(Args) do
    if (Args[I] <> '') and (Args[I][1] <> '-') then
      Exit(Args[I]);
end;

procedure PrintStats(Idx: TFb2Index);
var
  St: TFb2IndexStats;
  I: Integer;
begin
  St := Idx.Stats;
  try
    WriteLn('книг: ', St.Books, ' (валидных: ', St.Valid,
      ', с ошибками: ', St.Broken, ')');
    WriteLn('авторов: ', St.Authors, ' | жанров: ', St.Genres);
    WriteLn('с текстом в индексе: ', St.Text);
    WriteLn('кодировки:');
    for I := 0 to St.Encodings.Count - 1 do
      WriteLn('  ', St.Encodings.Names[I], ': ', St.Encodings.ValueFromIndex[I]);
    WriteLn('языки:');
    for I := 0 to St.Langs.Count - 1 do
      WriteLn('  ', St.Langs.Names[I], ': ', St.Langs.ValueFromIndex[I]);
  finally
    St.Free;
  end;
end;

var
  Args, CmdArgs: array of UnicodeString;
  DbPath, Cmd, Root, Query, Name: UnicodeString;
  I, P: Integer;
  Idx: TFb2Index;
  BS: TFb2BuildStats;
  NC: TNameCountList;
  TP: TTitlePathList;
  Books: TBookHitList;
  Texts: TTextHitList;
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
    WriteLn(ErrOutput, 'Использование: fb2index_cli [--db ФАЙЛ] <команда> ...');
    Halt(2);
  end;

  DbPath := DEFAULT_DB;
  P := 0;
  if Args[0] = '--db' then
  begin
    if Length(Args) < 3 then
    begin
      WriteLn(ErrOutput, '--db требует значения');
      Halt(2);
    end;
    DbPath := Args[1];
    P := 2;
  end;
  if P >= Length(Args) then
  begin
    WriteLn(ErrOutput, 'не указана команда');
    Halt(2);
  end;
  Cmd := Args[P];
  SetLength(CmdArgs, Length(Args) - P - 1);
  for I := 0 to High(CmdArgs) do
    CmdArgs[I] := Args[P + 1 + I];

  try
    Idx := TFb2Index.Create(DbPath, False, not HasFlag(CmdArgs, '--no-text'),
      FlagValue(CmdArgs, '--text-limit', DEFAULT_TEXT_LIMIT));
  except
    on E: Exception do
    begin
      WriteLn(ErrOutput, 'Ошибка: ', E.Message);
      Halt(1);
    end;
  end;
  try
    if Cmd = 'build' then
    begin
      Root := FirstPositional(CmdArgs);
      if Root = '' then
      begin
        WriteLn(ErrOutput, 'build требует каталог');
        Halt(2);
      end;
      BS := Idx.Build(Root, HasFlag(CmdArgs, '-r') or HasFlag(CmdArgs, '--recursive'),
        HasFlag(CmdArgs, '--force'), HasFlag(CmdArgs, '--hash'),
        not HasFlag(CmdArgs, '--no-text'));
      try
        WriteLn('добавлено: ', BS.Added, ', обновлено: ', BS.Updated,
          ', пропущено: ', BS.Skipped, ', ошибок: ', BS.Errors);
      finally
        BS.Free;
      end;
    end
    else if Cmd = 'stats' then
      PrintStats(Idx)
    else if Cmd = 'authors' then
    begin
      NC := Idx.TopAuthors(FlagValue(CmdArgs, '-n', 50));
      try
        for I := 0 to NC.Count - 1 do
          WriteLn(Format('%6d  %s', [NC[I].Count, NC[I].Name]));
      finally
        NC.Free;
      end;
    end
    else if Cmd = 'books' then
    begin
      Name := FirstPositional(CmdArgs);
      TP := Idx.BooksByAuthor(Name);
      try
        for I := 0 to TP.Count - 1 do
          WriteLn(TP[I].Title, ' | ', TP[I].Path);
      finally
        TP.Free;
      end;
    end
    else if Cmd = 'search' then
    begin
      Query := FirstPositional(CmdArgs);
      Books := Idx.SearchBooks(Query, ByValue(CmdArgs), FlagValue(CmdArgs, '-n', 50));
      try
        if Books.Count = 0 then
          WriteLn('Ничего не найдено.');
        for I := 0 to Books.Count - 1 do
          WriteLn(Books[I].Title, ' | ', Books[I].Path);
      finally
        Books.Free;
      end;
    end
    else if Cmd = 'find' then
    begin
      Query := FirstPositional(CmdArgs);
      Texts := Idx.SearchText(Query, FlagValue(CmdArgs, '-n', 20),
        FlagValue(CmdArgs, '--snippet-length', 200),
        not HasFlag(CmdArgs, '--no-prefix'));
      try
        if Texts.Count = 0 then
          WriteLn('Ничего не найдено.');
        for I := 0 to Texts.Count - 1 do
        begin
          WriteLn(Texts[I].Title, ' | ', Texts[I].Path);
          WriteLn('  ', Texts[I].Snippet);
        end;
      finally
        Texts.Free;
      end;
    end
    else if Cmd = 'dups' then
    begin
      NC := Idx.DuplicateHashes(FlagValue(CmdArgs, '-n', 100));
      try
        if NC.Count = 0 then
          WriteLn('дублей не найдено (соберите индекс с --hash)');
        for I := 0 to NC.Count - 1 do
          WriteLn(Format('%4d  %s', [NC[I].Count, NC[I].Name]));
      finally
        NC.Free;
      end;
    end
    else
    begin
      WriteLn(ErrOutput, 'Неизвестная команда: ', Cmd);
      Halt(2);
    end;
  except
    on E: EFb2Error do
    begin
      WriteLn(ErrOutput, 'Ошибка: ', E.Message);
      Halt(1);
    end;
  end;
  Idx.Free;
end.
