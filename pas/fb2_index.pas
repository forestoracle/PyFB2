unit fb2_index;
{ SQLite-индекс библиотеки FB2 — перевод fb2_index.py.

  Модуль один раз обходит дерево каталогов, читает метаданные FB2 через
  TFb2Parser и складывает результат в базу SQLite. Обновление инкрементальное:
  файлы с неизменившимися size/mtime пропускаются (Force пересобирает всё).

  Схема базы: books (путь, размер, mtime, sha1, кодировка, статус),
  authors, titles, genres, author_facts и book_text (FTS5-индекс текста).

  Поиск: SearchBooks — по метаданным (регистро- и ё-независимо, SQL-функция
  fb2_norm); SearchText — полнотекстовый (FTS5) со сниппетом и BM25.

  Требуется sqlite3.dll (FPC-юнит sqlite3, статическая линковка).

  Пример:
      var Idx: TFb2Index;
      begin
        Idx := TFb2Index.Create('library.db');
        try
          Idx.Build('C:\Books', True);
        finally
          Idx.Free;
        end;
      end; }

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Classes, SysUtils, fgl, ctypes, sqlite3,
  fb2_structures, fb2_parser, fb2_errors, fb2_files, fb2_encoding_scanner;

const
  { Путь к базе по умолчанию. }
  DEFAULT_DB = 'fb2_index.db';
  { Сколько символов текста книги хранить в FTS-индексе. }
  DEFAULT_TEXT_LIMIT = 200000;
  { Имя FTS-таблицы и её токенизатор. }
  FTS_TABLE = 'book_text';
  FTS_TOKENIZER = 'unicode61 remove_diacritics 2';
  { Минимальная длина слова, к которому добавляется префиксный '*'. }
  MIN_PREFIX_LENGTH = 3;
  { Поля, по которым ищет SearchBooks. }
  SEARCH_FIELDS: array[0..5] of UnicodeString =
    ('any', 'author', 'title', 'series', 'genre', 'year');

type
  { Результат поиска по метаданным (SearchBooks). }
  TBookHit = class
  public
    Path: UnicodeString;
    Title: UnicodeString;
    Authors: UnicodeString;
    Series: UnicodeString;
    Year: UnicodeString;
  end;

  TBookHitList = specialize TFPGObjectList<TBookHit>;

  { Результат полнотекстового поиска (SearchText). }
  TTextHit = class
  public
    Path: UnicodeString;
    Title: UnicodeString;
    Snippet: UnicodeString;
    Rank: Double;
  end;

  TTextHitList = specialize TFPGObjectList<TTextHit>;

  { Счётчики обхода (Build). }
  TFb2BuildStats = class
  public
    Added: Integer;
    Updated: Integer;
    Skipped: Integer;
    Errors: Integer;
  end;

  { Сводная статистика индекса (Stats). }
  TFb2IndexStats = class
  public
    Books: Integer;
    Valid: Integer;
    Broken: Integer;
    Authors: Integer;
    Genres: Integer;
    Text: Integer;
    Encodings: TStringList;   { кодировка -> количество }
    Langs: TStringList;       { язык -> количество }
    constructor Create;
    destructor Destroy; override;
  end;

  { Пара «имя — количество» (авторы, жанры, хеши). }
  TNameCount = class
  public
    Name: UnicodeString;
    Count: Int64;
  end;

  TNameCountList = specialize TFPGObjectList<TNameCount>;

  { Пара «название — путь» (книги автора). }
  TTitlePath = class
  public
    Title: UnicodeString;
    Path: UnicodeString;
  end;

  TTitlePathList = specialize TFPGObjectList<TTitlePath>;

  { Индекс библиотеки FB2 в базе SQLite. }
  TFb2Index = class
  private
    FDbPath: UnicodeString;
    FDebug: Boolean;
    FIndexText: Boolean;
    FTextLimit: Integer;
    FDb: psqlite3;
    FTextSearch: Boolean;

    function EnsureTextTable: Boolean;
    function BookRow(const Path: UnicodeString; out Id: Int64;
      out Size: Int64; out Mtime: Double): Boolean;
    procedure DeleteBook(const Path: UnicodeString);
    procedure DeleteText(BookId: Int64);
    function HasText(BookId: Int64): Boolean;
    procedure Store(const Path: UnicodeString; Desc: TDescription;
      const Encoding, Sha1, Text: UnicodeString; StoreText: Boolean);
    procedure MarkError(const Path: UnicodeString; const Message: UnicodeString);
  public
    constructor Create(const DbPath: UnicodeString = DEFAULT_DB;
      Debug: Boolean = False; IndexText: Boolean = True;
      TextLimit: Integer = DEFAULT_TEXT_LIMIT);
    destructor Destroy; override;
    procedure Close;

    { Индексирует один файл: 'added' / 'updated' / 'skipped' / 'error'. }
    function IndexFile(const Path: UnicodeString; Force: Boolean = False;
      ComputeHash: Boolean = False; IndexText: Boolean = True): UnicodeString;

    { Обходит каталог и обновляет индекс. }
    function Build(const Root: UnicodeString; Recursive: Boolean = True;
      Force: Boolean = False; ComputeHash: Boolean = False;
      IndexText: Boolean = True): TFb2BuildStats;

    function Stats: TFb2IndexStats;
    function TopAuthors(Limit: Integer = 50): TNameCountList;
    function GenreCounts: TNameCountList;
    function DuplicateHashes(Limit: Integer = 100): TNameCountList;
    function BooksByAuthor(const Name: UnicodeString): TTitlePathList;
    function SearchBooks(const Query: UnicodeString;
      const By: UnicodeString = 'any'; Limit: Integer = 50): TBookHitList;
    function SearchText(const Query: UnicodeString; Limit: Integer = 50;
      SnippetLength: Integer = 200; Prefix: Boolean = True): TTextHitList;

    property DbPath: UnicodeString read FDbPath;
    property TextSearch: Boolean read FTextSearch;
  end;

{ Нормализовать имя для сопоставления (регистр, ё->е, не-слово -> пробел). }
function NormalizeName(const Value: UnicodeString): UnicodeString;

{ Полное имя автора: 'Фамилия Имя Отчество' или никнейм. }
function AuthorFullName(Author: TAuthor): UnicodeString;

{ SHA-1 содержимого файла (для поиска дублей). }
function Sha1OfFile(const Path: UnicodeString): UnicodeString;

{ Век по году: 1799 -> 18, 1801 -> 19. }
function CenturyOf(Year: Integer): Integer;

{ Извлечь год (4 цифры) из строки даты; '' — если не найдено. }
function YearFromDate(const Value: UnicodeString): UnicodeString;

{ Нормализовать текст для поиска (регистр, ё->е) без изменения длины. }
function FoldText(const Value: UnicodeString): UnicodeString;

{ Собрать запрос для FTS5 (ё->е, регистр вниз, префиксы). }
function BuildFtsQuery(const Query: UnicodeString;
  Prefix: Boolean = True): UnicodeString;

{ Слова запроса (нормализованные) — для подсветки в сниппете. }
function QueryTerms(const Query: UnicodeString): TTextList;

{ Фрагмент текста вокруг первого совпадения с подсветкой в [скобках]. }
function MakeSnippet(const Body, Folded: UnicodeString; Terms: TTextList;
  ALength: Integer = 200): UnicodeString;

{ Plain text книги из тел FB2 (для полнотекстового индекса). }
function BookText(Bodies: TFb2ObjectList;
  Limit: Integer = DEFAULT_TEXT_LIMIT): UnicodeString;

implementation

uses
  sha1;

{ ===================== SQLite: низкоуровневая обёртка ===================== }

{ Значение-деструктор SQLITE_TRANSIENT (SQLite делает приватную копию). }
function Transient: sqlite3_destructor_type; inline;
begin
  Result := sqlite3_destructor_type(Pointer(-1));
end;

{ UTF-8 байты -> UnicodeString. }
function Utf8ToStr(P: PAnsiChar; L: Integer): UnicodeString;
var
  U: RawByteString;
begin
  if (P = nil) or (L <= 0) then
    Exit('');
  SetString(U, P, L);
  SetCodePage(U, CP_UTF8, False);
  Result := UTF8Decode(U);
end;

function StrToUtf8(const S: UnicodeString): RawByteString;
begin
  Result := UTF8Encode(S);
end;

function DbErr(Db: psqlite3): UnicodeString;
var
  P: PAnsiChar;
begin
  Result := '';
  if Db = nil then
    Exit;
  P := sqlite3_errmsg(Db);
  if P <> nil then
    Result := Utf8ToStr(P, StrLen(P));
end;

{ Выполнить SQL без параметров (несколько операторов допустимо). }
procedure DbExec(Db: psqlite3; const Sql: UnicodeString);
var
  U: RawByteString;
  R: cint;
begin
  U := StrToUtf8(Sql);
  R := sqlite3_exec(Db, PAnsiChar(U), nil, nil, nil);
  if R <> SQLITE_OK then
    raise EFb2OperationError.CreateFmt('SQLite: %s', [DbErr(Db)]);
end;

{ ===================== Параметры и подготовленные выражения ===================== }

type
  TParamKind = (pkNull, pkInt, pkInt64, pkReal, pkText);

  TParam = record
    Kind: TParamKind;
    I: Int64;
    D: Double;
    S: UnicodeString;
  end;

function PNull: TParam;
begin
  Result.Kind := pkNull;
end;

function PInt(V: Integer): TParam;
begin
  Result.Kind := pkInt;
  Result.I := V;
end;

function PInt64(V: Int64): TParam;
begin
  Result.Kind := pkInt64;
  Result.I := V;
end;

function PReal(V: Double): TParam;
begin
  Result.Kind := pkReal;
  Result.D := V;
end;

function PText(const V: UnicodeString): TParam;
begin
  Result.Kind := pkText;
  Result.S := V;
end;

{ Пустая строка -> NULL (как None в Python). }
function PTextOrNull(const V: UnicodeString): TParam;
begin
  if V = '' then
    Result := PNull
  else
    Result := PText(V);
end;

{ Подготовленное выражение: привязка параметров и чтение колонок. }
type
  TSqlStmt = class
  private
    FStmt: psqlite3_stmt;
  public
    constructor Create(Db: psqlite3; const Sql: UnicodeString);
    destructor Destroy; override;
    procedure Bind(const Params: array of TParam);
    function Step: cint;
    procedure Reset;
    function ColText(I: Integer): UnicodeString;
    function ColInt64(I: Integer): Int64;
    function ColInt(I: Integer): Integer;
    function ColDouble(I: Integer): Double;
    function ColIsNull(I: Integer): Boolean;
  end;

constructor TSqlStmt.Create(Db: psqlite3; const Sql: UnicodeString);
var
  U: RawByteString;
  R: cint;
begin
  inherited Create;
  FStmt := nil;
  U := StrToUtf8(Sql);
  R := sqlite3_prepare_v2(Db, PAnsiChar(U), -1, @FStmt, nil);
  if R <> SQLITE_OK then
    raise EFb2OperationError.CreateFmt('SQLite prepare: %s (%s)',
      [DbErr(Db), Sql]);
end;

destructor TSqlStmt.Destroy;
begin
  if FStmt <> nil then
    sqlite3_finalize(FStmt);
  inherited Destroy;
end;

procedure TSqlStmt.Bind(const Params: array of TParam);
var
  I: Integer;
  U: RawByteString;
begin
  for I := 0 to High(Params) do
    case Params[I].Kind of
      pkNull: sqlite3_bind_null(FStmt, I + 1);
      pkInt: sqlite3_bind_int(FStmt, I + 1, Params[I].I);
      pkInt64: sqlite3_bind_int64(FStmt, I + 1, Params[I].I);
      pkReal: sqlite3_bind_double(FStmt, I + 1, Params[I].D);
      pkText:
        begin
          U := StrToUtf8(Params[I].S);
          sqlite3_bind_text(FStmt, I + 1, PAnsiChar(U), Length(U), Transient);
        end;
    end;
end;

function TSqlStmt.Step: cint;
begin
  Result := sqlite3_step(FStmt);
end;

procedure TSqlStmt.Reset;
begin
  sqlite3_reset(FStmt);
end;

function TSqlStmt.ColText(I: Integer): UnicodeString;
var
  P: PAnsiChar;
  L: cint;
begin
  if sqlite3_column_type(FStmt, I) = SQLITE_NULL then
    Exit('');
  P := sqlite3_column_text(FStmt, I);
  L := sqlite3_column_bytes(FStmt, I);
  Result := Utf8ToStr(P, L);
end;

function TSqlStmt.ColInt64(I: Integer): Int64;
begin
  Result := sqlite3_column_int64(FStmt, I);
end;

function TSqlStmt.ColInt(I: Integer): Integer;
begin
  Result := sqlite3_column_int(FStmt, I);
end;

function TSqlStmt.ColDouble(I: Integer): Double;
begin
  Result := sqlite3_column_double(FStmt, I);
end;

function TSqlStmt.ColIsNull(I: Integer): Boolean;
begin
  Result := sqlite3_column_type(FStmt, I) = SQLITE_NULL;
end;

{ ===================== Запросы-однострочники ===================== }

function DbQueryInt64(Db: psqlite3; const Sql: UnicodeString;
  const Params: array of TParam): Int64;
var
  St: TSqlStmt;
begin
  Result := 0;
  St := TSqlStmt.Create(Db, Sql);
  try
    St.Bind(Params);
    if St.Step = SQLITE_ROW then
      Result := St.ColInt64(0);
  finally
    St.Free;
  end;
end;

function DbQueryText(Db: psqlite3; const Sql: UnicodeString;
  const Params: array of TParam): UnicodeString;
var
  St: TSqlStmt;
begin
  Result := '';
  St := TSqlStmt.Create(Db, Sql);
  try
    St.Bind(Params);
    if St.Step = SQLITE_ROW then
      Result := St.ColText(0);
  finally
    St.Free;
  end;
end;

{ ===================== SQL-функция fb2_norm ===================== }

procedure Fb2NormFunc(ctx: psqlite3_context; N: cint; V: ppsqlite3_value); cdecl;
var
  P: PAnsiChar;
  Src: UnicodeString;
  OutU: RawByteString;
begin
  if (N < 1) or (V = nil) or (V[0] = nil) then
  begin
    sqlite3_result_null(ctx);
    Exit;
  end;
  P := sqlite3_value_text(V[0]);
  if P = nil then
  begin
    sqlite3_result_null(ctx);
    Exit;
  end;
  Src := Utf8ToStr(P, StrLen(P));
  OutU := StrToUtf8(NormalizeName(Src));
  sqlite3_result_text(ctx, PAnsiChar(OutU), Length(OutU), Transient);
end;

{ ===================== Текстовые помощники ===================== }

{ Нижний регистр для Latin-1 и кириллицы (детерминированно). }
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

{ Символ «слова»: буква (латиница/кириллица), цифра или '_'. }
function IsWordCharU(C: WideChar): Boolean;
var
  U: LongWord;
begin
  U := Ord(C);
  Result := ((U >= Ord('a')) and (U <= Ord('z'))) or
    ((U >= Ord('A')) and (U <= Ord('Z'))) or
    ((U >= Ord('0')) and (U <= Ord('9'))) or (C = '_') or
    ((U >= $0410) and (U <= $044F)) or (U = $0401) or (U = $0451) or
    ((U >= $0400) and (U <= $04FF));
end;

function IsSpaceU(C: WideChar): Boolean;
begin
  Result := (C = ' ') or (C = #9) or (C = #10) or (C = #13);
end;

function NormalizeName(const Value: UnicodeString): UnicodeString;
var
  I: Integer;
  C: WideChar;
  PrevSpace: Boolean;
begin
  Result := '';
  PrevSpace := True;   { обрезать ведущие пробелы }
  for I := 1 to Length(Value) do
  begin
    C := Value[I];
    if C = 'Ё' then
      C := 'Е'
    else if C = 'ё' then
      C := 'е';
    { привести к нижнему регистру посимвольно }
    C := LoCaseU(C)[1];
    if IsWordCharU(C) then
    begin
      Result := Result + C;
      PrevSpace := False;
    end
    else if IsSpaceU(C) then
    begin
      if not PrevSpace then
      begin
        Result := Result + ' ';
        PrevSpace := True;
      end;
    end
    else
    begin
      { прочие символы -> пробел }
      if not PrevSpace then
      begin
        Result := Result + ' ';
        PrevSpace := True;
      end;
    end;
  end;
  Result := UnicodeString(Trim(Result));
end;

function FoldText(const Value: UnicodeString): UnicodeString;
var
  I: Integer;
  C: WideChar;
begin
  SetLength(Result, Length(Value));
  for I := 1 to Length(Value) do
  begin
    C := Value[I];
    if C = 'Ё' then
      C := 'Е'
    else if C = 'ё' then
      C := 'е';
    Result[I] := LoCaseU(C)[1];
  end;
end;

function AuthorFullName(Author: TAuthor): UnicodeString;
var
  Parts: TTextList;
  S: UnicodeString;
begin
  Result := '';
  if Author = nil then
    Exit;
  Parts := TTextList.Create;
  try
    if Trim(Author.LastName) <> '' then
      Parts.Add(Trim(Author.LastName));
    if Trim(Author.FirstName) <> '' then
      Parts.Add(Trim(Author.FirstName));
    if Trim(Author.MiddleName) <> '' then
      Parts.Add(Trim(Author.MiddleName));
    S := JoinText(Parts, ' ');
  finally
    Parts.Free;
  end;
  if S <> '' then
    Result := S
  else
    Result := Trim(Author.Nickname);
end;

function Sha1OfFile(const Path: UnicodeString): UnicodeString;
begin
  Result := UnicodeString(SHA1Print(SHA1File(Path)));
end;

function CenturyOf(Year: Integer): Integer;
begin
  if Year <= 0 then
    Result := NO_VALUE
  else
    Result := (Year - 1) div 100 + 1;
end;

function YearFromDate(const Value: UnicodeString): UnicodeString;
var
  I, K: Integer;
  Digits: Integer;
begin
  Result := '';
  Digits := 0;
  for I := 1 to Length(Value) do
  begin
    if (Value[I] >= '0') and (Value[I] <= '9') then
    begin
      Inc(Digits);
      if Digits = 4 then
      begin
        for K := I - 3 to I do
          Result := Result + Value[K];
        Exit;
      end;
    end
    else
      Digits := 0;
  end;
end;

{ ===================== FTS-запрос, слова, сниппет ===================== }

const
  FTS_OPERATORS: array[0..3] of UnicodeString = ('AND', 'OR', 'NOT', 'NEAR');

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

function IsFtsOperator(const S: UnicodeString): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := Low(FTS_OPERATORS) to High(FTS_OPERATORS) do
    if UpCaseU(S) = FTS_OPERATORS[I] then
      Exit(True);
end;

{ Слово без FTS-синтаксиса (кавычек, звёздочек, скобок, двоеточий). }
function IsSimpleWord(const Token: UnicodeString): Boolean;
var
  I: Integer;
  C: WideChar;
begin
  Result := True;
  for I := 1 to Length(Token) do
  begin
    C := Token[I];
    if (C = '"') or (C = '*') or (C = '(') or (C = ')') or
      (C = ':') or (C = '^') then
      Exit(False);
  end;
end;

function BuildFtsQuery(const Query: UnicodeString; Prefix: Boolean): UnicodeString;
var
  Q, Cur, Token, Folded: UnicodeString;
  I: Integer;
  CurIsSpace: Boolean;
  Runs: TTextList;
begin
  Result := '';
  Q := UnicodeString(Trim(Query));
  if Q = '' then
    Exit;

  Runs := TTextList.Create;
  try
    { разбить на чередующиеся пробельные / непробельные фрагменты }
    Cur := Q[1];
    CurIsSpace := IsSpaceU(Q[1]);
    for I := 2 to Length(Q) do
    begin
      if IsSpaceU(Q[I]) = CurIsSpace then
        Cur := Cur + Q[I]
      else
      begin
        Runs.Add(Cur);
        Cur := Q[I];
        CurIsSpace := not CurIsSpace;
      end;
    end;
    Runs.Add(Cur);

    for I := 0 to Runs.Count - 1 do
    begin
      Token := Runs[I];
      if Trim(Token) = '' then
        Result := Result + Token
      else if IsFtsOperator(Trim(Token)) then
        Result := Result + UpCaseU(Trim(Token))
      else
      begin
        Folded := FoldText(Token);
        if Prefix and IsSimpleWord(Token) and
          (Length(Folded) >= MIN_PREFIX_LENGTH) then
          Folded := Folded + '*';
        Result := Result + Folded;
      end;
    end;
  finally
    Runs.Free;
  end;
  Result := UnicodeString(Trim(Result));
end;

function QueryTerms(const Query: UnicodeString): TTextList;
var
  F, Token: UnicodeString;
  I: Integer;
begin
  Result := TTextList.Create;
  F := FoldText(Query);
  Token := '';
  for I := 1 to Length(F) + 1 do
  begin
    if (I <= Length(F)) and IsWordCharU(F[I]) then
      Token := Token + F[I]
    else
    begin
      if (Length(Token) >= 2) and (not IsFtsOperator(UpCaseU(Token))) then
        Result.Add(Token);
      Token := '';
    end;
  end;
end;

function MakeSnippet(const Body, Folded: UnicodeString; Terms: TTextList;
  ALength: Integer): UnicodeString;
var
  Haystack, Matched, Fragment, Prefix, Suffix: UnicodeString;
  BodyLen, Pos1, Pos0, Start0, End0, Rel, Idx, I: Integer;
begin
  Result := '';
  if Body = '' then
    Exit;

  if Length(Folded) = Length(Body) then
    Haystack := Folded
  else
    Haystack := FoldText(Body);

  Pos1 := 0;
  Matched := '';
  if Terms <> nil then
    for I := 0 to Terms.Count - 1 do
    begin
      Idx := Pos(Terms[I], Haystack);
      if (Idx <> 0) and ((Pos1 = 0) or (Idx < Pos1)) then
      begin
        Pos1 := Idx;
        Matched := Terms[I];
      end;
    end;

  if Pos1 = 0 then
  begin
    Result := Copy(Body, 1, ALength);
    if Length(Body) > ALength then
      Result := Result + '…';
    Exit;
  end;

  BodyLen := Length(Body);
  Pos0 := Pos1 - 1;
  Start0 := Pos0 - (ALength div 3);
  if Start0 < 0 then
    Start0 := 0;
  End0 := Start0 + ALength;
  if End0 > BodyLen then
    End0 := BodyLen;

  Fragment := Copy(Body, Start0 + 1, End0 - Start0);
  if (Matched <> '') and (Length(Haystack) = BodyLen) then
  begin
    Rel := Pos0 - Start0;
    Fragment := Copy(Fragment, 1, Rel) + '[' +
      Copy(Fragment, Rel + 1, Length(Matched)) + ']' +
      Copy(Fragment, Rel + 1 + Length(Matched), MaxInt);
  end;

  if Start0 > 0 then
    Prefix := '…'
  else
    Prefix := '';
  if End0 < BodyLen then
    Suffix := '…'
  else
    Suffix := '';
  Result := Prefix + Fragment + Suffix;
end;

{ ===================== Текст книги ===================== }

{ Объединение непустых строк через #10 (аналог "\n".join(p for p in parts if p)). }
function JoinNonEmptyLines(List: TTextList): UnicodeString;
var
  I: Integer;
  First: Boolean;
begin
  Result := '';
  First := True;
  for I := 0 to List.Count - 1 do
  begin
    if List[I] = '' then
      Continue;
    if not First then
      Result := Result + #10;
    Result := Result + List[I];
    First := False;
  end;
end;

function MarkupText(Nodes: TFb2ObjectList): UnicodeString;
var
  I: Integer;
  Node: TStyleNode;
begin
  Result := '';
  if Nodes = nil then
    Exit;
  for I := 0 to Nodes.Count - 1 do
  begin
    Node := TStyleNode(Nodes[I]);
    if Node.Tag = TEXT_NODE_NAME then
      Result := Result + Node.Text
    else
      Result := Result + MarkupText(Node.Children);
  end;
end;

{ Текст одного блочного элемента FB2 (абзац, стихи, цитата, таблица). }
function BlockText(Block: TFb2Object): UnicodeString;
var
  Parts: TTextList;
  I, J: Integer;
begin
  Result := '';
  if Block = nil then
    Exit;

  if Block is TParagraph then
    Result := MarkupText(TParagraph(Block).Content)
  else if Block is TSubtitle then
    Result := MarkupText(TSubtitle(Block).Content)
  else if Block is TTitle then
  begin
    Parts := TTextList.Create;
    try
      for I := 0 to TTitle(Block).Items.Count - 1 do
        Parts.Add(BlockText(TTitle(Block).Items[I]));
      Result := JoinText(Parts, #10);
    finally
      Parts.Free;
    end;
  end
  else if Block is TAnnotation then
  begin
    Parts := TTextList.Create;
    try
      for I := 0 to TAnnotation(Block).Items.Count - 1 do
        Parts.Add(BlockText(TAnnotation(Block).Items[I]));
      Result := JoinText(Parts, #10);
    finally
      Parts.Free;
    end;
  end
  else if (Block is TEpigraph) or (Block is TCite) or (Block is TPoem) then
  begin
    Parts := TTextList.Create;
    try
      if Block is TEpigraph then
      begin
        for I := 0 to TEpigraph(Block).Items.Count - 1 do
          Parts.Add(BlockText(TEpigraph(Block).Items[I]));
        for I := 0 to TEpigraph(Block).TextAuthor.Count - 1 do
          Parts.Add(MarkupText(TParagraph(TEpigraph(Block).TextAuthor[I]).Content));
      end
      else if Block is TCite then
      begin
        for I := 0 to TCite(Block).Items.Count - 1 do
          Parts.Add(BlockText(TCite(Block).Items[I]));
        for I := 0 to TCite(Block).TextAuthor.Count - 1 do
          Parts.Add(MarkupText(TParagraph(TCite(Block).TextAuthor[I]).Content));
      end
      else
      begin
        for I := 0 to TPoem(Block).Items.Count - 1 do
          Parts.Add(BlockText(TPoem(Block).Items[I]));
        for I := 0 to TPoem(Block).TextAuthor.Count - 1 do
          Parts.Add(MarkupText(TParagraph(TPoem(Block).TextAuthor[I]).Content));
      end;
      Result := JoinNonEmptyLines(Parts);
    finally
      Parts.Free;
    end;
  end
  else if Block is TStanza then
  begin
    Parts := TTextList.Create;
    try
      if TStanza(Block).Subtitle <> nil then
        Parts.Add(BlockText(TStanza(Block).Subtitle));
      for I := 0 to TStanza(Block).Verses.Count - 1 do
        Parts.Add(MarkupText(TParagraph(TStanza(Block).Verses[I]).Content));
      Result := JoinNonEmptyLines(Parts);
    finally
      Parts.Free;
    end;
  end
  else if Block is TTable then
  begin
    Parts := TTextList.Create;
    try
      for I := 0 to TTable(Block).Rows.Count - 1 do
        for J := 0 to TTableRow(TTable(Block).Rows[I]).Cells.Count - 1 do
          Parts.Add(MarkupText(TTableCell(
            TTableRow(TTable(Block).Rows[I]).Cells[J]).Children));
      Result := JoinNonEmptyLines(Parts);
    finally
      Parts.Free;
    end;
  end;
end;

{ Текст секции (заголовок, эпиграфы, аннотация, содержимое, подсекции). }
function SectionText(Section: TSection): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
begin
  Result := '';
  if Section = nil then
    Exit;
  Parts := TTextList.Create;
  try
    if Section.Title <> nil then
      Parts.Add(BlockText(Section.Title));
    for I := 0 to Section.Epigraphs.Count - 1 do
      Parts.Add(BlockText(Section.Epigraphs[I]));
    if Section.Annotation <> nil then
      Parts.Add(BlockText(Section.Annotation));
    for I := 0 to Section.Content.Count - 1 do
      Parts.Add(BlockText(Section.Content[I]));
    for I := 0 to Section.Sections.Count - 1 do
      Parts.Add(SectionText(TSection(Section.Sections[I])));
    Result := JoinNonEmptyLines(Parts);
  finally
    Parts.Free;
  end;
end;

function BookText(Bodies: TFb2ObjectList; Limit: Integer): UnicodeString;
var
  Parts: TTextList;
  I, J: Integer;
  Body: TBody;
begin
  Result := '';
  if Bodies = nil then
    Exit;
  Parts := TTextList.Create;
  try
    for I := 0 to Bodies.Count - 1 do
    begin
      Body := TBody(Bodies[I]);
      if Body.Title <> nil then
        Parts.Add(BlockText(Body.Title));
      for J := 0 to Body.Epigraphs.Count - 1 do
        Parts.Add(BlockText(Body.Epigraphs[J]));
      for J := 0 to Body.Sections.Count - 1 do
        Parts.Add(SectionText(TSection(Body.Sections[J])));
    end;
    Result := JoinNonEmptyLines(Parts);
  finally
    Parts.Free;
  end;
  if Length(Result) > Limit then
    Result := Copy(Result, 1, Limit);
end;

{ ===================== TFb2IndexStats ===================== }

constructor TFb2IndexStats.Create;
begin
  inherited Create;
  Encodings := TStringList.Create;
  Langs := TStringList.Create;
end;

destructor TFb2IndexStats.Destroy;
begin
  FreeAndNil(Encodings);
  FreeAndNil(Langs);
  inherited Destroy;
end;

{ ===================== Схема базы ===================== }

const
  SCHEMA =
    'CREATE TABLE IF NOT EXISTS books (' + #10 +
    '    id        INTEGER PRIMARY KEY AUTOINCREMENT,' + #10 +
    '    path      TEXT    NOT NULL UNIQUE,' + #10 +
    '    dir       TEXT    NOT NULL,' + #10 +
    '    filename  TEXT    NOT NULL,' + #10 +
    '    size      INTEGER NOT NULL,' + #10 +
    '    mtime     REAL    NOT NULL,' + #10 +
    '    sha1      TEXT,' + #10 +
    '    encoding  TEXT,' + #10 +
    '    is_valid  INTEGER NOT NULL DEFAULT 1,' + #10 +
    '    error     TEXT,' + #10 +
    '    scanned_at REAL NOT NULL' + #10 +
    ');' + #10 +
    'CREATE TABLE IF NOT EXISTS authors (' + #10 +
    '    book_id   INTEGER NOT NULL REFERENCES books(id) ON DELETE CASCADE,' + #10 +
    '    ord       INTEGER NOT NULL,' + #10 +
    '    last_name TEXT,' + #10 +
    '    first_name TEXT,' + #10 +
    '    middle_name TEXT,' + #10 +
    '    nickname  TEXT,' + #10 +
    '    full_name TEXT' + #10 +
    ');' + #10 +
    'CREATE TABLE IF NOT EXISTS titles (' + #10 +
    '    book_id   INTEGER PRIMARY KEY REFERENCES books(id) ON DELETE CASCADE,' + #10 +
    '    title     TEXT,' + #10 +
    '    series    TEXT,' + #10 +
    '    series_num INTEGER,' + #10 +
    '    lang      TEXT,' + #10 +
    '    src_lang  TEXT,' + #10 +
    '    year      TEXT,' + #10 +
    '    book_id_fb2 TEXT' + #10 +
    ');' + #10 +
    'CREATE TABLE IF NOT EXISTS genres (' + #10 +
    '    book_id INTEGER NOT NULL REFERENCES books(id) ON DELETE CASCADE,' + #10 +
    '    code    TEXT NOT NULL,' + #10 +
    '    match   INTEGER' + #10 +
    ');' + #10 +
    'CREATE TABLE IF NOT EXISTS author_facts (' + #10 +
    '    name_norm  TEXT PRIMARY KEY,' + #10 +
    '    country    TEXT,' + #10 +
    '    birth_year INTEGER,' + #10 +
    '    death_year INTEGER,' + #10 +
    '    century    INTEGER,' + #10 +
    '    source     TEXT,' + #10 +
    '    fetched_at REAL' + #10 +
    ');' + #10 +
    'CREATE INDEX IF NOT EXISTS idx_books_dir      ON books(dir);' + #10 +
    'CREATE INDEX IF NOT EXISTS idx_books_sha1     ON books(sha1);' + #10 +
    'CREATE INDEX IF NOT EXISTS idx_authors_book   ON authors(book_id);' + #10 +
    'CREATE INDEX IF NOT EXISTS idx_authors_name   ON authors(full_name);' + #10 +
    'CREATE INDEX IF NOT EXISTS idx_genres_book    ON genres(book_id);' + #10 +
    'CREATE INDEX IF NOT EXISTS idx_genres_code    ON genres(code);';

  SCHEMA_TEXT =
    'CREATE VIRTUAL TABLE IF NOT EXISTS ' + FTS_TABLE + ' USING fts5(' + #10 +
    '    path   UNINDEXED,' + #10 +
    '    title  UNINDEXED,' + #10 +
    '    body   UNINDEXED,' + #10 +
    '    folded,' + #10 +
    '    tokenize = ''' + FTS_TOKENIZER + '''' + #10 +
    ');';

{ Выполнить SQL с параметрами (результат не читаем). }
procedure DbRun(Db: psqlite3; const Sql: UnicodeString;
  const Params: array of TParam);
var
  St: TSqlStmt;
begin
  St := TSqlStmt.Create(Db, Sql);
  try
    St.Bind(Params);
    while St.Step = SQLITE_ROW do
      ;
  finally
    St.Free;
  end;
end;

{ ===================== TFb2Index: создание/закрытие ===================== }

constructor TFb2Index.Create(const DbPath: UnicodeString; Debug: Boolean;
  IndexText: Boolean; TextLimit: Integer);
var
  U: RawByteString;
  R: cint;
  Msg: UnicodeString;
begin
  inherited Create;
  FDbPath := DbPath;
  FDebug := Debug;
  FIndexText := IndexText;
  FTextLimit := TextLimit;
  FDb := nil;

  U := StrToUtf8(DbPath);
  R := sqlite3_open(PAnsiChar(U), @FDb);
  if R <> SQLITE_OK then
  begin
    Msg := DbErr(FDb);
    if FDb <> nil then
      sqlite3_close(FDb);
    FDb := nil;
    raise EFb2OperationError.CreateFmt('Не удалось открыть базу [%s]: %s',
      [DbPath, Msg]);
  end;

  DbExec(FDb, 'PRAGMA foreign_keys = ON');
  R := sqlite3_create_function(FDb, 'fb2_norm', 1, SQLITE_UTF8, nil,
    @Fb2NormFunc, nil, nil);
  if R <> SQLITE_OK then
    raise EFb2OperationError.CreateFmt(
      'Не удалось зарегистрировать fb2_norm: %s', [DbErr(FDb)]);

  DbExec(FDb, SCHEMA);
  FTextSearch := EnsureTextTable;
end;

destructor TFb2Index.Destroy;
begin
  Close;
  inherited Destroy;
end;

procedure TFb2Index.Close;
begin
  if FDb <> nil then
  begin
    sqlite3_close(FDb);
    FDb := nil;
  end;
end;

function TFb2Index.EnsureTextTable: Boolean;
begin
  Result := True;
  try
    DbExec(FDb, SCHEMA_TEXT);
  except
    Result := False;   { SQLite собран без FTS5 }
  end;
end;

function TFb2Index.BookRow(const Path: UnicodeString; out Id: Int64;
  out Size: Int64; out Mtime: Double): Boolean;
var
  St: TSqlStmt;
begin
  Result := False;
  Id := 0;
  Size := 0;
  Mtime := 0;
  St := TSqlStmt.Create(FDb, 'SELECT id, size, mtime FROM books WHERE path = ?');
  try
    St.Bind([PText(Path)]);
    if St.Step = SQLITE_ROW then
    begin
      Id := St.ColInt64(0);
      Size := St.ColInt64(1);
      Mtime := St.ColDouble(2);
      Result := True;
    end;
  finally
    St.Free;
  end;
end;

procedure TFb2Index.DeleteBook(const Path: UnicodeString);
var
  Id: Int64;
begin
  Id := DbQueryInt64(FDb, 'SELECT id FROM books WHERE path = ?', [PText(Path)]);
  if Id <> 0 then
    DeleteText(Id);
  DbRun(FDb, 'DELETE FROM books WHERE path = ?', [PText(Path)]);
end;

procedure TFb2Index.DeleteText(BookId: Int64);
begin
  if not FTextSearch then
    Exit;
  DbRun(FDb, 'DELETE FROM ' + FTS_TABLE + ' WHERE rowid = ?', [PInt64(BookId)]);
end;

function TFb2Index.HasText(BookId: Int64): Boolean;
begin
  if not FTextSearch then
    Exit(True);
  Result := DbQueryInt64(FDb,
    'SELECT 1 FROM ' + FTS_TABLE + ' WHERE rowid = ? LIMIT 1',
    [PInt64(BookId)]) <> 0;
end;

{ ===================== Запись метаданных ===================== }

{ Размер и mtime (Unix-секунды) файла; 0/0 — если недоступен. }
procedure FileStat(const Path: UnicodeString; out Size: Int64; out Mtime: Double);
var
  Rec: TSearchRec;
begin
  Size := 0;
  Mtime := 0;
  if FindFirst(Path, faAnyFile, Rec) = 0 then
  begin
    Size := Rec.Size;
    Mtime := (FileDateToDateTime(Rec.Time) - 25569.0) * 86400.0;
    FindClose(Rec);
  end;
end;

function NowUnix: Double;
begin
  Result := (Now - 25569.0) * 86400.0;
end;

procedure TFb2Index.Store(const Path: UnicodeString; Desc: TDescription;
  const Encoding, Sha1, Text: UnicodeString; StoreText: Boolean);
var
  Size: Int64;
  Mtime: Double;
  BookId: Int64;
  TI: TTitleInfo;
  DI: TDocumentInfo;
  PI: TPublishInfo;
  I: Integer;
  Title, Lang, SrcLang, Year, BookIdFb2, Body: UnicodeString;
  SeriesParam, SeriesNumParam: TParam;
  Seq: TSequence;
  A: TAuthor;
  G: TGenre;
  St: TSqlStmt;
begin
  FileStat(Path, Size, Mtime);
  DeleteBook(Path);

  St := TSqlStmt.Create(FDb,
    'INSERT INTO books(path, dir, filename, size, mtime, sha1, encoding,' +
    ' is_valid, error, scanned_at) VALUES (?,?,?,?,?,?,?,?,?,?)');
  try
    St.Bind([PText(Path), PText(ExtractFileDir(Path)),
      PText(ExtractFileName(Path)), PInt64(Size), PReal(Mtime),
      PTextOrNull(Sha1), PTextOrNull(Encoding), PInt(1), PNull,
      PReal(NowUnix)]);
    St.Step;
  finally
    St.Free;
  end;
  BookId := sqlite3_last_insert_rowid(FDb);

  TI := nil;
  DI := nil;
  PI := nil;
  if Desc <> nil then
  begin
    TI := Desc.TitleInfo;
    DI := Desc.DocumentInfo;
    PI := Desc.PublishInfo;
  end;

  { --- авторы --- }
  if TI <> nil then
    for I := 0 to TI.Authors.Count - 1 do
    begin
      A := TAuthor(TI.Authors[I]);
      DbRun(FDb, 'INSERT INTO authors(book_id, ord, last_name, first_name,' +
        ' middle_name, nickname, full_name) VALUES (?,?,?,?,?,?,?)',
        [PInt64(BookId), PInt(I), PTextOrNull(A.LastName),
         PTextOrNull(A.FirstName), PTextOrNull(A.MiddleName),
         PTextOrNull(A.Nickname), PTextOrNull(AuthorFullName(A))]);
    end;

  { --- название / серия / язык / год --- }
  Title := '';
  if (TI <> nil) and (TI.BookTitle <> nil) then
    Title := TI.BookTitle.Value;

  SeriesParam := PNull;
  SeriesNumParam := PNull;
  if (TI <> nil) and (TI.Sequences.Count > 0) then
  begin
    Seq := TSequence(TI.Sequences[0]);
    SeriesParam := PTextOrNull(Seq.Name);
    if Seq.Number <> NO_VALUE then
      SeriesNumParam := PInt64(Seq.Number);
  end;

  Lang := '';
  SrcLang := '';
  if TI <> nil then
  begin
    Lang := TI.Lang;
    SrcLang := TI.SrcLang;
  end;

  Year := '';
  if (PI <> nil) and (PI.Year <> '') then
    Year := YearFromDate(PI.Year);
  if (Year = '') and (DI <> nil) and (DI.Date <> nil) then
  begin
    if DI.Date.DateValue <> '' then
      Year := YearFromDate(DI.Date.DateValue)
    else
      Year := YearFromDate(DI.Date.Value);
  end;
  if (Year = '') and (TI <> nil) and (TI.Date <> nil) then
  begin
    if TI.Date.DateValue <> '' then
      Year := YearFromDate(TI.Date.DateValue)
    else
      Year := YearFromDate(TI.Date.Value);
  end;

  BookIdFb2 := '';
  if DI <> nil then
    BookIdFb2 := DI.Id;

  DbRun(FDb, 'INSERT INTO titles(book_id, title, series, series_num, lang,' +
    ' src_lang, year, book_id_fb2) VALUES (?,?,?,?,?,?,?,?)',
    [PInt64(BookId), PTextOrNull(Title), SeriesParam, SeriesNumParam,
     PTextOrNull(Lang), PTextOrNull(SrcLang), PTextOrNull(Year),
     PTextOrNull(BookIdFb2)]);

  { --- жанры --- }
  if TI <> nil then
    for I := 0 to TI.Genres.Count - 1 do
    begin
      G := TGenre(TI.Genres[I]);
      DbRun(FDb, 'INSERT INTO genres(book_id, code, match) VALUES (?,?,?)',
        [PInt64(BookId), PText(G.Value), PInt(G.Match)]);
    end;

  { --- текст книги (полнотекстовый поиск) --- }
  if FTextSearch and StoreText then
  begin
    if Title <> '' then
      Body := Title + #10#10 + Text
    else
      Body := Text;
    DbRun(FDb, 'INSERT INTO ' + FTS_TABLE +
      '(rowid, path, title, body, folded) VALUES (?,?,?,?,?)',
      [PInt64(BookId), PText(Path), PText(Title), PText(Body),
       PText(FoldText(Body))]);
  end;
end;

procedure TFb2Index.MarkError(const Path: UnicodeString;
  const Message: UnicodeString);
var
  Size: Int64;
  Mtime: Double;
  Msg: UnicodeString;
begin
  FileStat(Path, Size, Mtime);
  DeleteBook(Path);
  Msg := Message;
  if Length(Msg) > 500 then
    Msg := Copy(Msg, 1, 500);
  DbRun(FDb, 'INSERT INTO books(path, dir, filename, size, mtime, is_valid,' +
    ' error, scanned_at) VALUES (?,?,?,?,?,?,?,?)',
    [PText(Path), PText(ExtractFileDir(Path)), PText(ExtractFileName(Path)),
     PInt64(Size), PReal(Mtime), PInt(0), PText(Msg), PReal(NowUnix)]);
end;

{ ===================== Индексация ===================== }

function TFb2Index.IndexFile(const Path: UnicodeString; Force: Boolean;
  ComputeHash: Boolean; IndexText: Boolean): UnicodeString;
var
  WantText: Boolean;
  Size, RowId, RowSize: Int64;
  Mtime, RowMtime: Double;
  HasRow: Boolean;
  Encoding, Sha1, Text: UnicodeString;
  Parser: TFb2Parser;
  Desc: TDescription;
  Bodies: TFb2ObjectList;
begin
  WantText := FIndexText and IndexText;

  FileStat(Path, Size, Mtime);
  HasRow := BookRow(Path, RowId, RowSize, RowMtime);
  if HasRow and (not Force) then
    if (RowSize = Size) and (Abs(RowMtime - Mtime) < 1e-6) and
      ((not WantText) or HasText(RowId)) then
      Exit('skipped');

  Encoding := DetectEncoding(Path);
  Sha1 := '';
  Text := '';

  Parser := TFb2Parser.Create;
  Desc := nil;
  Bodies := nil;
  try
    try
      Parser.LoadFile(Path);
      Desc := Parser.Parse;
      Bodies := Parser.ParseBodies;
      if WantText and FTextSearch then
        Text := BookText(Bodies, FTextLimit);
      if ComputeHash then
        Sha1 := Sha1OfFile(Path);
      Store(Path, Desc, Encoding, Sha1, Text, WantText and FTextSearch);
    except
      on E: Exception do
      begin
        MarkError(Path, E.ClassName + ': ' + E.Message);
        Exit('error');
      end;
    end;
  finally
    Bodies.Free;
    Desc.Free;
    Parser.Free;
  end;

  if HasRow then
    Result := 'updated'
  else
    Result := 'added';
end;

function TFb2Index.Build(const Root: UnicodeString; Recursive, Force,
  ComputeHash, IndexText: Boolean): TFb2BuildStats;
var
  Files: TStringList;
  I: Integer;
  R: UnicodeString;
begin
  Result := TFb2BuildStats.Create;
  if not DirectoryExists(Root) then
  begin
    Result.Free;
    raise EFb2OperationError.CreateFmt('Каталог не существует: %s', [Root]);
  end;

  if Recursive then
    Files := ListFilesRecursive(Root, '*.fb2')
  else
    Files := ListFiles(Root, '*.fb2');

  DbExec(FDb, 'BEGIN');
  try
    try
      for I := 0 to Files.Count - 1 do
      begin
        R := IndexFile(Files[I], Force, ComputeHash, IndexText);
        if R = 'added' then
          Inc(Result.Added)
        else if R = 'updated' then
          Inc(Result.Updated)
        else if R = 'skipped' then
          Inc(Result.Skipped)
        else
          Inc(Result.Errors);
      end;
      DbExec(FDb, 'COMMIT');
    except
      DbExec(FDb, 'ROLLBACK');
      raise;
    end;
  finally
    Files.Free;
  end;
end;

{ ===================== Запросы ===================== }

procedure AddNameCount(List: TNameCountList; const Name: UnicodeString;
  Count: Int64);
var
  It: TNameCount;
begin
  It := TNameCount.Create;
  It.Name := Name;
  It.Count := Count;
  List.Add(It);
end;

function TFb2Index.Stats: TFb2IndexStats;
var
  St: TSqlStmt;
begin
  Result := TFb2IndexStats.Create;
  Result.Books := DbQueryInt64(FDb, 'SELECT COUNT(*) FROM books', []);
  Result.Valid := DbQueryInt64(FDb,
    'SELECT COUNT(*) FROM books WHERE is_valid = 1', []);
  Result.Broken := Result.Books - Result.Valid;
  Result.Authors := DbQueryInt64(FDb,
    'SELECT COUNT(DISTINCT full_name) FROM authors WHERE length(full_name) > 0',
    []);
  Result.Genres := DbQueryInt64(FDb,
    'SELECT COUNT(DISTINCT code) FROM genres', []);

  St := TSqlStmt.Create(FDb,
    'SELECT COALESCE(encoding, ''?''), COUNT(*) FROM books' +
    ' GROUP BY encoding ORDER BY 2 DESC');
  try
    while St.Step = SQLITE_ROW do
      Result.Encodings.Values[St.ColText(0)] := IntToStr(St.ColInt64(1));
  finally
    St.Free;
  end;

  St := TSqlStmt.Create(FDb,
    'SELECT COALESCE(lang, ''?''), COUNT(*) FROM titles' +
    ' GROUP BY lang ORDER BY 2 DESC');
  try
    while St.Step = SQLITE_ROW do
      Result.Langs.Values[St.ColText(0)] := IntToStr(St.ColInt64(1));
  finally
    St.Free;
  end;

  if FTextSearch then
    Result.Text := DbQueryInt64(FDb,
      'SELECT COUNT(*) FROM ' + FTS_TABLE, []);
end;

function TFb2Index.TopAuthors(Limit: Integer): TNameCountList;
var
  St: TSqlStmt;
begin
  Result := TNameCountList.Create;
  St := TSqlStmt.Create(FDb,
    'SELECT full_name, COUNT(DISTINCT book_id) AS n FROM authors' +
    ' WHERE length(full_name) > 0' +
    ' GROUP BY full_name ORDER BY n DESC, full_name LIMIT ?');
  try
    St.Bind([PInt(Limit)]);
    while St.Step = SQLITE_ROW do
      AddNameCount(Result, St.ColText(0), St.ColInt64(1));
  finally
    St.Free;
  end;
end;

function TFb2Index.GenreCounts: TNameCountList;
var
  St: TSqlStmt;
begin
  Result := TNameCountList.Create;
  St := TSqlStmt.Create(FDb,
    'SELECT code, COUNT(DISTINCT book_id) AS n FROM genres' +
    ' GROUP BY code ORDER BY n DESC, code');
  try
    while St.Step = SQLITE_ROW do
      AddNameCount(Result, St.ColText(0), St.ColInt64(1));
  finally
    St.Free;
  end;
end;

function TFb2Index.DuplicateHashes(Limit: Integer): TNameCountList;
var
  St: TSqlStmt;
begin
  Result := TNameCountList.Create;
  St := TSqlStmt.Create(FDb,
    'SELECT sha1, COUNT(*) AS n FROM books WHERE sha1 IS NOT NULL' +
    ' GROUP BY sha1 HAVING n > 1 ORDER BY n DESC LIMIT ?');
  try
    St.Bind([PInt(Limit)]);
    while St.Step = SQLITE_ROW do
      AddNameCount(Result, St.ColText(0), St.ColInt64(1));
  finally
    St.Free;
  end;
end;

function TFb2Index.BooksByAuthor(const Name: UnicodeString): TTitlePathList;
var
  St: TSqlStmt;
  It: TTitlePath;
begin
  Result := TTitlePathList.Create;
  St := TSqlStmt.Create(FDb,
    'SELECT t.title, b.path FROM books b' +
    ' JOIN authors a ON a.book_id = b.id' +
    ' LEFT JOIN titles t ON t.book_id = b.id' +
    ' WHERE a.full_name LIKE ? ORDER BY t.title');
  try
    St.Bind([PText('%' + Name + '%')]);
    while St.Step = SQLITE_ROW do
    begin
      It := TTitlePath.Create;
      It.Title := St.ColText(0);
      It.Path := St.ColText(1);
      Result.Add(It);
    end;
  finally
    St.Free;
  end;
end;

function IsSearchField(const By: UnicodeString): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := Low(SEARCH_FIELDS) to High(SEARCH_FIELDS) do
    if By = SEARCH_FIELDS[I] then
      Exit(True);
end;

function TFb2Index.SearchBooks(const Query, By: UnicodeString;
  Limit: Integer): TBookHitList;
var
  Pattern, Sql: UnicodeString;
  Conds: TTextList;
  Params: array of TParam;
  I: Integer;
  St: TSqlStmt;
  H: TBookHit;
begin
  Result := TBookHitList.Create;
  if not IsSearchField(By) then
  begin
    Result.Free;
    raise EFb2OperationError.CreateFmt(
      'неизвестное поле поиска: %s (any, author, title, series, genre, year)',
      [By]);
  end;

  Pattern := '%' + NormalizeName(Query) + '%';
  if Pattern = '%%' then
    Exit;

  Conds := TTextList.Create;
  try
    if (By = 'any') or (By = 'author') then
      Conds.Add('EXISTS (SELECT 1 FROM authors a WHERE a.book_id = b.id' +
        ' AND fb2_norm(a.full_name) LIKE ?)');
    if (By = 'any') or (By = 'title') then
      Conds.Add('fb2_norm(t.title) LIKE ?');
    if (By = 'any') or (By = 'series') then
      Conds.Add('fb2_norm(t.series) LIKE ?');
    if (By = 'any') or (By = 'genre') then
      Conds.Add('EXISTS (SELECT 1 FROM genres g WHERE g.book_id = b.id' +
        ' AND fb2_norm(g.code) LIKE ?)');
    if (By = 'any') or (By = 'year') then
      Conds.Add('t.year LIKE ?');

    Sql := 'SELECT b.path, COALESCE(t.title, ''''),' +
      ' COALESCE((SELECT GROUP_CONCAT(full_name, '', '')' +
      '           FROM authors WHERE book_id = b.id), ''''),' +
      ' t.series, t.year' +
      ' FROM books b LEFT JOIN titles t ON t.book_id = b.id' +
      ' WHERE ' + JoinText(Conds, ' OR ') +
      ' ORDER BY t.title, b.path LIMIT ?';

    SetLength(Params, Conds.Count + 1);
    for I := 0 to Conds.Count - 1 do
      Params[I] := PText(Pattern);
    Params[Conds.Count] := PInt(Limit);

    St := TSqlStmt.Create(FDb, Sql);
    try
      St.Bind(Params);
      while St.Step = SQLITE_ROW do
      begin
        H := TBookHit.Create;
        H.Path := St.ColText(0);
        H.Title := St.ColText(1);
        H.Authors := St.ColText(2);
        H.Series := St.ColText(3);
        H.Year := St.ColText(4);
        Result.Add(H);
      end;
    finally
      St.Free;
    end;
  finally
    Conds.Free;
  end;
end;

function TFb2Index.SearchText(const Query: UnicodeString; Limit: Integer;
  SnippetLength: Integer; Prefix: Boolean): TTextHitList;
var
  FtsQuery, Sql: UnicodeString;
  Terms: TTextList;
  St: TSqlStmt;
  H: TTextHit;
  Body, Folded: UnicodeString;
begin
  Result := TTextHitList.Create;
  if not FTextSearch then
  begin
    Result.Free;
    raise EFb2OperationError.Create(
      'полнотекстовый поиск недоступен: SQLite без FTS5');
  end;

  FtsQuery := BuildFtsQuery(Query, Prefix);
  if FtsQuery = '' then
    Exit;

  Terms := QueryTerms(Query);
  Sql := 'SELECT path, title, body, folded, bm25(' + FTS_TABLE + ') AS rank' +
    ' FROM ' + FTS_TABLE + ' WHERE ' + FTS_TABLE + ' MATCH ?' +
    ' ORDER BY rank LIMIT ?';

  St := nil;
  try
    try
      St := TSqlStmt.Create(FDb, Sql);
      St.Bind([PText(FtsQuery), PInt(Limit)]);
      while St.Step = SQLITE_ROW do
      begin
        H := TTextHit.Create;
        H.Path := St.ColText(0);
        H.Title := St.ColText(1);
        Body := St.ColText(2);
        Folded := St.ColText(3);
        H.Snippet := MakeSnippet(Body, Folded, Terms, SnippetLength);
        H.Rank := St.ColDouble(4);
        Result.Add(H);
      end;
    except
      on E: Exception do
      begin
        Result.Free;
        raise EFb2OperationError.CreateFmt(
          'некорректный поисковый запрос: %s', [E.Message]);
      end;
    end;
  finally
    St.Free;
    Terms.Free;
  end;
end;

end.
