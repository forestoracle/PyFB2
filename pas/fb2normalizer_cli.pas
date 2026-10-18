{ CLI для fb2_normalizer — аналог main() из fb2_normalizer.py.

  Использование:
      fb2normalizer_cli <файл.fb2 | каталог> [-r] [--out-dir КАТАЛОГ]
          [--suffix СУФФИКС] [--dry-run] [--no-pretty] [--validate] [-q]

  Коды возврата: 0 — успех, 1 — ошибки обработки, 2 — ошибка запуска. }

program fb2normalizer_cli;

{$mode objfpc}{$H+}
{$codepage utf8}

uses
  Classes, SysUtils
  {$IFDEF WINDOWS}, Windows{$ENDIF}
  , fb2_structures, fb2_normalizer, fb2_files, fb2_errors;

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

var
  Args: array of UnicodeString;
  Source, OutDir, Suffix, Dest, Stem, Ext, Name: UnicodeString;
  Quiet, DryRun: Boolean;
  N: TFb2Normalizer;
  Results: TNormalizationResultList;
  Files: TStringList;
  I, J, Errors: Integer;
  R: TNormalizationResult;
  Status, Xsd: UnicodeString;
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
    WriteLn(ErrOutput, 'Использование: fb2normalizer_cli <файл|каталог> ...');
    Halt(EXIT_USAGE);
  end;

  Source := FirstPositional(Args);
  if Source = '' then
  begin
    WriteLn(ErrOutput, 'Не указан исходный файл или каталог');
    Halt(EXIT_USAGE);
  end;
  OutDir := StrValue(Args, '--out-dir', '');
  Suffix := StrValue(Args, '--suffix', '');
  DryRun := HasFlag(Args, '--dry-run');
  Quiet := HasFlag(Args, '-q') or HasFlag(Args, '--quiet');

  Results := TNormalizationResultList.Create;
  N := TFb2Normalizer.Create(True, True, True, True, False, True, True, True,
    not HasFlag(Args, '--no-pretty'), 'prose', 'ru', 'Без названия',
    'Неизвестный автор', '', HasFlag(Args, '--validate'));
  try
    if DirectoryExists(Source) then
    begin
      { каталог -> обход всех *.fb2 }
      FreeAndNil(Results);
      Results := N.NormalizeDir(Source, OutDir, Suffix, DryRun);
    end
    else if FileExists(Source) then
    begin
      Dest := '';
      if OutDir <> '' then
        Dest := IncludeTrailingPathDelimiter(OutDir) + ExtractFileName(Source)
      else if Suffix <> '' then
      begin
        Stem := ChangeFileExt(ExtractFileName(Source), '');
        Ext := ExtractFileExt(Source);
        Dest := ExtractFilePath(Source) + Stem + Suffix + Ext;
      end;
      Results.Add(N.NormalizeFile(Source, Dest, DryRun));
    end
    else
    begin
      { не файл и не каталог: возможно, -r и это каталог-маска }
      Files := ListFilesRecursive(Source, FB2_MASK);
      try
        if Files.Count = 0 then
        begin
          WriteLn(ErrOutput, 'Ошибка: не найдено FB2-файлов: ', Source);
          Halt(EXIT_USAGE);
        end;
        for I := 0 to Files.Count - 1 do
        begin
          Dest := '';
          if OutDir <> '' then
            Dest := IncludeTrailingPathDelimiter(OutDir) +
              ExtractFileName(Files[I])
          else if Suffix <> '' then
          begin
            Stem := ChangeFileExt(ExtractFileName(Files[I]), '');
            Ext := ExtractFileExt(Files[I]);
            Dest := ExtractFilePath(Files[I]) + Stem + Suffix + Ext;
          end;
          Results.Add(N.NormalizeFile(Files[I], Dest, DryRun));
        end;
      finally
        Files.Free;
      end;
    end;

    Errors := 0;
    for I := 0 to Results.Count - 1 do
    begin
      R := Results[I];
      if not R.Ok then
      begin
        Inc(Errors);
        WriteLn(ErrOutput, 'ОШИБКА: ', R.Source);
        WriteLn(ErrOutput, '  - ', R.Error);
        Continue;
      end;
      if Quiet then
        Continue;
      if R.Changed then
        Status := 'изменён'
      else
        Status := 'без изменений';
      Xsd := '';
      if R.HasValidAfter then
      begin
        if R.ValidAfter then
          Xsd := ' [XSD: OK]'
        else
          Xsd := ' [XSD: ОШИБКИ]';
      end;
      Name := R.Source;
      if R.Target <> '' then
        Name := Name + ' -> ' + R.Target;
      WriteLn(Name, ': ', Status, ' (правок: ', R.Fixes.Count, ')', Xsd);
      for J := 0 to R.Fixes.Count - 1 do
        WriteLn('  - ', R.Fixes[J].AsText);
    end;

    WriteLn(ErrOutput, 'Обработано файлов: ', Results.Count,
      ', ошибок: ', Errors);
    if Errors > 0 then
      Halt(EXIT_ERRORS);
  finally
    Results.Free;
    N.Free;
  end;
end.
