unit fb2_renamer;
{ Переименование ОДНОГО файла FB2 по шаблону — перевод fb2_renamer.py.

  В шаблоне доступны:
      $AL $AF $AM — фамилия/имя/отчество автора в ВЕРХНЕМ регистре;
      $Al $Af $Am — они же с заглавной буквы;
      $al $af $am — они же в нижнем регистре;
      $F $M       — первая буква имени/отчества + '.';
      $T $t $Tt   — заголовок: ВЕРХНИЙ/нижний/как в файле;
      $S $SN      — серия и номер в серии.
  Допускаются обе формы записи параметра: $NAME и с фигурными скобками.

  Пример:
      var R: TFB2Renamer;
      begin
        R := TFB2Renamer.Create('book.fb2', '$Al $Tt', '$Al');
        try
          WriteLn(R.Rename);
        finally
          R.Free;
        end;
      end; }

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Classes, SysUtils, fb2_structures, fb2_parser, fb2_errors;

type
  { Переименование одного FB2-файла по шаблону. }
  TFB2Renamer = class
  private
    FTt, FTUp, FTLo: UnicodeString;
    FS, FSN: UnicodeString;
    FALUp, FAFUp, FAMUp: UnicodeString;
    FALCap, FAFCap, FAMCap: UnicodeString;
    FALLo, FAFLo, FAMLo: UnicodeString;
    FF, FM: UnicodeString;
    FDebug: Boolean;
    FFilename: UnicodeString;
    FTemplate: UnicodeString;
    FOutDirRaw: UnicodeString;
    FOutDir: UnicodeString;
    FNewPath: UnicodeString;
    FNewFilename: UnicodeString;
    procedure GetFb2Properties;
  public
    constructor Create(const Filename, Template: UnicodeString;
      const OutDir: UnicodeString = ''; Debug: Boolean = False);
    { Выполнить переименование; возвращает новое имя файла. }
    function Rename: UnicodeString;
    { Подставить значения книги в шаблон. }
    function ProcessTemplate(const Template: UnicodeString;
      KeepSeparators: Boolean = False): UnicodeString;
    { Удалить символы, запрещённые в именах файлов (кроме Keep). }
    class function RemoveRestrictedChars(const Value: UnicodeString;
      const Keep: UnicodeString = ''): UnicodeString; static;

    property NewPath: UnicodeString read FNewPath;
    property NewFilename: UnicodeString read FNewFilename;
    property Title: UnicodeString read FTt;
    property AuthorLast: UnicodeString read FALUp;
    property AuthorFirst: UnicodeString read FAFUp;
    property AuthorMiddle: UnicodeString read FAMUp;
    property Series: UnicodeString read FS;
    property SeriesNumber: UnicodeString read FSN;
  end;

implementation

{ --- Служебные помощники -------------------------------------------- }

{ Верхний регистр для Latin-1 и кириллицы (детерминированно, без codepage). }
function UpCaseU(const S: UnicodeString): UnicodeString;
var
  I: Integer;
  U: LongWord;
begin
  SetLength(Result, Length(S));
  for I := 1 to Length(S) do
  begin
    U := Ord(S[I]);
    if (U >= Ord('a')) and (U <= Ord('z')) then
      Result[I] := WideChar(U - 32)
    else if (U >= $0430) and (U <= $044F) then
      Result[I] := WideChar(U - 32)
    else if U = $0451 then
      Result[I] := WideChar($0401)
    else
      Result[I] := S[I];
  end;
end;

{ Нижний регистр для Latin-1 и кириллицы. }
function LoCaseU(const S: UnicodeString): UnicodeString;
var
  I: Integer;
  U: LongWord;
begin
  SetLength(Result, Length(S));
  for I := 1 to Length(S) do
  begin
    U := Ord(S[I]);
    if (U >= Ord('A')) and (U <= Ord('Z')) then
      Result[I] := WideChar(U + 32)
    else if (U >= $0410) and (U <= $042F) then
      Result[I] := WideChar(U + 32)
    else if U = $0401 then
      Result[I] := WideChar($0451)
    else
      Result[I] := S[I];
  end;
end;

{ Как str.capitalize(): первая буква заглавная, остальные — строчные. }
function CapitalizeFirst(const S: UnicodeString): UnicodeString;
begin
  Result := LoCaseU(S);
  if Result <> '' then
    Result := UpCaseU(Copy(Result, 1, 1)) + Copy(Result, 2, MaxInt);
end;

{ Заменить цепочки ПРОБЕЛОВ на один пробел (как re.sub(' +', ' ', s)). }
function CollapseSpacesOnly(const S: UnicodeString): UnicodeString;
var
  I: Integer;
  PrevSpace: Boolean;
begin
  Result := '';
  PrevSpace := False;
  for I := 1 to Length(S) do
    if S[I] = ' ' then
    begin
      if not PrevSpace then
        Result := Result + ' ';
      PrevSpace := True;
    end
    else
    begin
      Result := Result + S[I];
      PrevSpace := False;
    end;
end;

function CharIn(const C: WideChar; const S: UnicodeString): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to Length(S) do
    if S[I] = C then
      Exit(True);
end;

function IsRestrictedChar(const C: WideChar): Boolean;
begin
  Result := CharIn(C, '/\:*?"<>|');
end;

function IsIdentChar(const C: WideChar): Boolean;
begin
  Result := ((C >= 'a') and (C <= 'z')) or ((C >= 'A') and (C <= 'Z')) or
    ((C >= '0') and (C <= '9')) or (C = '_');
end;

{ Подстановка параметров шаблона (аналог string.Template.substitute). }
function SubstituteTemplate(const Template: UnicodeString;
  Values: TStringList): UnicodeString;
var
  I, L, J: Integer;
  Name: UnicodeString;
begin
  Result := '';
  L := Length(Template);
  I := 1;
  while I <= L do
  begin
    if Template[I] <> '$' then
    begin
      Result := Result + Template[I];
      Inc(I);
      Continue;
    end;

    if (I < L) and (Template[I + 1] = '$') then
    begin
      Result := Result + '$';
      Inc(I, 2);
      Continue;
    end;

    Inc(I);   { пропустить '$' }
    Name := '';
    if (I <= L) and (Template[I] = '{') then
    begin
      Inc(I);
      while (I <= L) and (Template[I] <> '}') do
      begin
        Name := Name + Template[I];
        Inc(I);
      end;
      if I <= L then
        Inc(I);   { закрывающая фигурная скобка }
    end
    else
      while (I <= L) and IsIdentChar(Template[I]) do
      begin
        Name := Name + Template[I];
        Inc(I);
      end;

    if Name = '' then
      raise EFb2OperationError.Create('Некорректный шаблон: пустое имя $');
    J := Values.IndexOfName(Name);
    if J < 0 then
      raise EFb2OperationError.CreateFmt('Неизвестный параметр шаблона: %s', [Name]);
    Result := Result + Values.ValueFromIndex[J];
  end;
end;

{ Обрезать заданные символы с обоих концов строки. }
function TrimChars(const S: UnicodeString; const Chars: UnicodeString): UnicodeString;
var
  A, B: Integer;
begin
  A := 1;
  B := Length(S);
  while (A <= B) and CharIn(S[A], Chars) do
    Inc(A);
  while (B >= A) and CharIn(S[B], Chars) do
    Dec(B);
  Result := Copy(S, A, B - A + 1);
end;

{ Убрать пробелы вокруг разделителей каталогов: ' a / b ' -> 'a/b'. }
function StripSpacesAroundSeparators(const S: UnicodeString): UnicodeString;
var
  I: Integer;
begin
  Result := '';
  I := 1;
  while I <= Length(S) do
  begin
    if (S[I] = '/') or (S[I] = '\') then
    begin
      { снять пробелы, добавленные ранее }
      while (Result <> '') and (Result[Length(Result)] = ' ') do
        Delete(Result, Length(Result), 1);
      Result := Result + S[I];
      Inc(I);
      while (I <= Length(S)) and (S[I] = ' ') do
        Inc(I);
    end
    else
    begin
      Result := Result + S[I];
      Inc(I);
    end;
  end;
end;

{ --- TFB2Renamer ---------------------------------------------------- }

constructor TFB2Renamer.Create(const Filename, Template: UnicodeString;
  const OutDir: UnicodeString; Debug: Boolean);
var
  Base: UnicodeString;
begin
  inherited Create;
  FTt := ''; FTUp := ''; FTLo := '';
  FS := ''; FSN := '';
  FALUp := ''; FAFUp := ''; FAMUp := '';
  FALCap := ''; FAFCap := ''; FAMCap := '';
  FALLo := ''; FAFLo := ''; FAMLo := '';
  FF := ''; FM := '';

  FDebug := Debug;
  FFilename := Filename;
  FTemplate := Template;
  FOutDirRaw := OutDir;

  GetFb2Properties;

  FOutDir := ProcessTemplate(OutDir, True);
  Base := ExtractFileDir(ExpandFileName(Filename));
  if FOutDir = '' then
    FNewPath := Base
  else
    FNewPath := IncludeTrailingPathDelimiter(Base) + FOutDir;
  FNewFilename := ProcessTemplate(Template, False) + '.fb2';
end;

procedure TFB2Renamer.GetFb2Properties;
var
  Parser: TFb2Parser;
  Desc: TDescription;
  TI: TTitleInfo;
  I: Integer;
  A: TAuthor;
  Seq: TSequence;
begin
  Parser := TFb2Parser.Create;
  Desc := nil;
  try
    try
      Parser.LoadFile(FFilename);
      Desc := Parser.Parse;
    except
      on E: Exception do
        raise EFb2OperationError.CreateFmt(
          'Не удалось прочитать FB2-файл [%s]: %s', [FFilename, E.Message]);
    end;
    if Desc = nil then
      raise EFb2OperationError.CreateFmt(
        'Не удалось прочитать FB2-файл [%s]', [FFilename]);
    TI := Desc.TitleInfo;
    if (TI = nil) or (TI.BookTitle = nil) then
      raise EFb2OperationError.CreateFmt(
        'В файле не найдено название книги: %s', [FFilename]);

    { Название }
    FTt := TI.BookTitle.Value;
    FTUp := UpCaseU(FTt);
    FTLo := LoCaseU(FTt);

    { Серия }
    for I := 0 to TI.Sequences.Count - 1 do
    begin
      Seq := TSequence(TI.Sequences[I]);
      FS := Seq.Name;
      if Seq.Number <> NO_VALUE then
        FSN := IntToStr(Seq.Number)
      else
        FSN := '';
    end;

    { Автор(ы): как и в Python, берётся последний }
    for I := 0 to TI.Authors.Count - 1 do
    begin
      A := TAuthor(TI.Authors[I]);
      if Trim(A.LastName) <> '' then FALUp := UpCaseU(Trim(A.LastName)) else FALUp := '';
      if Trim(A.FirstName) <> '' then FAFUp := UpCaseU(Trim(A.FirstName)) else FAFUp := '';
      if Trim(A.MiddleName) <> '' then FAMUp := UpCaseU(Trim(A.MiddleName)) else FAMUp := '';
    end;

    FALLo := LoCaseU(FALUp);
    FAFLo := LoCaseU(FAFUp);
    FAMLo := LoCaseU(FAMUp);

    FALCap := CapitalizeFirst(FALUp);
    FAFCap := CapitalizeFirst(FAFUp);
    FAMCap := CapitalizeFirst(FAMUp);

    if FAFUp <> '' then FF := Copy(FAFUp, 1, 1) + '.' else FF := '';
    if FAMUp <> '' then FM := Copy(FAMUp, 1, 1) + '.' else FM := '';
  finally
    Desc.Free;
    Parser.Free;
  end;
end;

function TFB2Renamer.Rename: UnicodeString;
var
  Target: UnicodeString;
begin
  ForceDirectories(FNewPath);
  Target := IncludeTrailingPathDelimiter(FNewPath) + FNewFilename;
  if not RenameFile(FFilename, Target) then
    raise EFb2OperationError.CreateFmt(
      'Ошибка: Не удалось переименовать [%s] в [%s]',
      [FFilename, FNewFilename]);
  Result := FNewFilename;
end;

function TFB2Renamer.ProcessTemplate(const Template: UnicodeString;
  KeepSeparators: Boolean): UnicodeString;
var
  Values: TStringList;
begin
  Values := TStringList.Create;
  try
    Values.CaseSensitive := True;   { $T и $t — разные параметры }
    Values.Values['S'] := FS;
    Values.Values['SN'] := FSN;
    Values.Values['AM'] := FAMUp;
    Values.Values['AF'] := FAFUp;
    Values.Values['AL'] := FALUp;
    Values.Values['Al'] := FALCap;
    Values.Values['Am'] := FAMCap;
    Values.Values['Af'] := FAFCap;
    Values.Values['al'] := FALLo;
    Values.Values['am'] := FAMLo;
    Values.Values['af'] := FAFLo;
    Values.Values['F'] := FF;
    Values.Values['M'] := FM;
    Values.Values['T'] := FTUp;
    Values.Values['t'] := FTLo;
    Values.Values['Tt'] := FTt;

    Result := SubstituteTemplate(Template, Values);
  finally
    Values.Free;
  end;

  Result := UnicodeString(Trim(CollapseSpacesOnly(Result)));
  if KeepSeparators then
  begin
    Result := StripSpacesAroundSeparators(Result);
    Result := TrimChars(Result, '/\');
    Result := RemoveRestrictedChars(Result, '/\');
  end
  else
    Result := RemoveRestrictedChars(Result, '');
end;

class function TFB2Renamer.RemoveRestrictedChars(const Value: UnicodeString;
  const Keep: UnicodeString): UnicodeString;
var
  I: Integer;
  C: WideChar;
begin
  Result := '';
  for I := 1 to Length(Value) do
  begin
    C := Value[I];
    if IsRestrictedChar(C) and (not CharIn(C, Keep)) then
      Continue;
    Result := Result + C;
  end;
end;

end.
