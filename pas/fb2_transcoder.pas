unit fb2_transcoder;
{ Перекодирование FB2-файлов в целевую кодировку (обычно UTF-8) —
  перевод fb2_transcoder.py.

  Читает файл в исходной кодировке, декодирует текст, приводит XML-декларацию
  к целевой кодировке и записывает результат. Байты переносов строк не
  изменяются (запись идёт в бинарном режиме).

  Пример:
      var T: TFb2Transcoder;
      begin
        T := TFb2Transcoder.Create;        ( windows-1251 -> utf-8 )
        try
          T.TranscodeFile('book.fb2');     ( перезапись )
        finally
          T.Free;
        end;
      end; }

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Classes, SysUtils, fgl, fb2_files, fb2_errors;

const
  { Расширение FB2-файлов. }
  FB2_MASK = '*.fb2';
  { Кодировка-источник по умолчанию. }
  DEFAULT_SOURCE = 'windows-1251';
  { Кодировка-назначение по умолчанию. }
  DEFAULT_TARGET = 'utf-8';
  { Сколько байт читать для анализа декларации. }
  HEAD_SIZE = 4096;

type
  { Результат перекодирования одного файла. }
  TTranscodeResult = class
  public
    Source: UnicodeString;
    Target: UnicodeString;
    SourceEncoding: UnicodeString;
    Skipped: Boolean;
    Error: UnicodeString;
    constructor Create;
    { Успешно ли выполнено перекодирование (включая пропуск). }
    function Ok: Boolean;
  end;

  TTranscodeResultList = specialize TFPGObjectList<TTranscodeResult>;

  { Перекодировщик FB2-файлов. }
  TFb2Transcoder = class
  private
    FSourceEncoding: UnicodeString;
    FTargetEncoding: UnicodeString;
    FBom: Boolean;
    FForce: Boolean;
    FErrors: UnicodeString;
    function ConvertBytes(const Data: TBytes; out UsedEncoding: UnicodeString;
      out Skipped: Boolean): TBytes;
    function FixDeclaration(const Text: UnicodeString): UnicodeString;
    class function DestPath(const Fb2, Root, OutRoot,
      Suffix: UnicodeString): UnicodeString; static;
  public
    { SourceEncoding: '' — автоопределение; по умолчанию windows-1251. }
    constructor Create(const SourceEncoding: UnicodeString = DEFAULT_SOURCE;
      const TargetEncoding: UnicodeString = DEFAULT_TARGET;
      Bom: Boolean = False; Force: Boolean = False;
      const Errors: UnicodeString = 'strict');

    { Перекодировать один файл (Dest = '' — перезапись исходного). }
    function TranscodeFile(const Path: UnicodeString;
      const Dest: UnicodeString = ''; DryRun: Boolean = False): TTranscodeResult;

    { Перекодировать все *.fb2 каталога (рекурсивно). }
    function TranscodeDir(const Directory: UnicodeString;
      const OutDir: UnicodeString = ''; const Suffix: UnicodeString = '';
      DryRun: Boolean = False): TTranscodeResultList;

    property SourceEncoding: UnicodeString read FSourceEncoding write FSourceEncoding;
    property TargetEncoding: UnicodeString read FTargetEncoding write FTargetEncoding;
    property Bom: Boolean read FBom write FBom;
    property Force: Boolean read FForce write FForce;
    property Errors: UnicodeString read FErrors write FErrors;
  end;

{ Определить кодировку по BOM и XML-декларации (по байтам файла). }
function DetectEncodingOf(const Data: TBytes): UnicodeString;

{ Нормализовать имя кодировки для сравнения. }
function NormalizeEnc(const Encoding: UnicodeString): UnicodeString;

{ Кодировка по имени (распространённые имена + числовой codepage).
  Для неизвестного имени возбуждает EFb2OperationError. }
function EncodingByName(const Name: UnicodeString): TEncoding;

implementation

{ --- Служебные помощники -------------------------------------------- }

function NormalizeEnc(const Encoding: UnicodeString): UnicodeString;
begin
  Result := LowerCase(Trim(Encoding));
end;

function ConcatBytes(const A, B: TBytes): TBytes;
begin
  SetLength(Result, Length(A) + Length(B));
  if Length(A) > 0 then
    Move(A[0], Result[0], Length(A));
  if Length(B) > 0 then
    Move(B[0], Result[Length(A)], Length(B));
end;

{ Убрать BOM из начала данных, если он есть. }
function StripBom(const Data: TBytes): TBytes;
var
  L: Integer;
begin
  L := Length(Data);
  if (L >= 3) and (Data[0] = $EF) and (Data[1] = $BB) and (Data[2] = $BF) then
    Exit(Copy(Data, 3, MaxInt));
  if (L >= 4) and (Data[0] = $FF) and (Data[1] = $FE) and
    (Data[2] = 0) and (Data[3] = 0) then
    Exit(Copy(Data, 4, MaxInt));
  if (L >= 4) and (Data[0] = 0) and (Data[1] = 0) and
    (Data[2] = $FE) and (Data[3] = $FF) then
    Exit(Copy(Data, 4, MaxInt));
  if (L >= 2) and (Data[0] = $FF) and (Data[1] = $FE) then
    Exit(Copy(Data, 2, MaxInt));
  if (L >= 2) and (Data[0] = $FE) and (Data[1] = $FF) then
    Exit(Copy(Data, 2, MaxInt));
  Result := Data;
end;

{ BOM для целевой кодировки (пустой, если не предусмотрен). }
function BomBytes(const TargetEncoding: UnicodeString): TBytes;
var
  T: UnicodeString;
begin
  SetLength(Result, 0);
  T := NormalizeEnc(TargetEncoding);
  if (T = 'utf-8') or (T = 'utf8') then
  begin
    SetLength(Result, 3);
    Result[0] := $EF; Result[1] := $BB; Result[2] := $BF;
  end
  else if (T = 'utf-16') or (T = 'utf-16-le') or (T = 'utf16') then
  begin
    SetLength(Result, 2);
    Result[0] := $FF; Result[1] := $FE;
  end
  else if T = 'utf-16-be' then
  begin
    SetLength(Result, 2);
    Result[0] := $FE; Result[1] := $FF;
  end
  else if (T = 'utf-32') or (T = 'utf-32-le') then
  begin
    SetLength(Result, 4);
    Result[0] := $FF; Result[1] := $FE; Result[2] := 0; Result[3] := 0;
  end
  else if T = 'utf-32-be' then
  begin
    SetLength(Result, 4);
    Result[0] := 0; Result[1] := 0; Result[2] := $FE; Result[3] := $FF;
  end;
end;

function DetectEncodingOf(const Data: TBytes): UnicodeString;
var
  L, I, J: Integer;
  Name: UnicodeString;
  Quote: Byte;
begin
  Result := '';
  L := Length(Data);

  if (L >= 3) and (Data[0] = $EF) and (Data[1] = $BB) and (Data[2] = $BF) then
    Exit('utf-8');
  if (L >= 4) and (Data[0] = $FF) and (Data[1] = $FE) and
    (Data[2] = 0) and (Data[3] = 0) then
    Exit('utf-32-le');
  if (L >= 4) and (Data[0] = 0) and (Data[1] = 0) and
    (Data[2] = $FE) and (Data[3] = $FF) then
    Exit('utf-32-be');
  if (L >= 2) and (Data[0] = $FF) and (Data[1] = $FE) then
    Exit('utf-16-le');
  if (L >= 2) and (Data[0] = $FE) and (Data[1] = $FF) then
    Exit('utf-16-be');

  { encoding="..." в первых HEAD_SIZE байтах }
  if L > HEAD_SIZE then
    L := HEAD_SIZE;
  I := 0;
  while I + 8 <= L do
  begin
    if (Data[I] or $20 = Ord('e')) and
      (LowerCase(AnsiChar(Data[I + 1])) = 'n') and
      (LowerCase(AnsiChar(Data[I + 2])) = 'c') and
      (LowerCase(AnsiChar(Data[I + 3])) = 'o') and
      (LowerCase(AnsiChar(Data[I + 4])) = 'd') and
      (LowerCase(AnsiChar(Data[I + 5])) = 'i') and
      (LowerCase(AnsiChar(Data[I + 6])) = 'n') and
      (LowerCase(AnsiChar(Data[I + 7])) = 'g') then
    begin
      J := I + 8;
      while (J < L) and (Data[J] in [9, 10, 13, 32]) do
        Inc(J);
      if (J < L) and (Data[J] = Ord('=')) then
      begin
        Inc(J);
        while (J < L) and (Data[J] in [9, 10, 13, 32]) do
          Inc(J);
        if (J < L) and ((Data[J] = Ord('"')) or (Data[J] = Ord(''''))) then
        begin
          Quote := Data[J];
          Inc(J);
          Name := '';
          while (J < L) and (Data[J] <> Quote) do
          begin
            Name := Name + WideChar(Data[J]);
            Inc(J);
          end;
          Exit(UnicodeString(Trim(Name)));
        end;
      end;
    end;
    Inc(I);
  end;

  Result := DEFAULT_TARGET;
end;

{ Кодировка по имени (распространённые имена + числовой codepage). }
function EncodingByName(const Name: UnicodeString): TEncoding;
var
  N: UnicodeString;
begin
  N := NormalizeEnc(Name);
  if (N = 'utf-8') or (N = 'utf8') then
    Exit(TEncoding.UTF8);
  if (N = 'utf-16') or (N = 'utf-16-le') or (N = 'utf16') or (N = 'unicode') then
    Exit(TEncoding.Unicode);
  if (N = 'utf-16-be') or (N = 'utf16be') then
    Exit(TEncoding.BigEndianUnicode);
  if (N = 'utf-32') or (N = 'utf-32-le') or (N = 'utf32') then
    Exit(TEncoding.GetEncoding(12000));
  if (N = 'us-ascii') or (N = 'ascii') then
    Exit(TEncoding.ASCII);
  if (N = 'windows-1251') or (N = 'cp1251') or (N = 'win-1251') then
    Exit(TEncoding.GetEncoding(1251));
  if (N = 'windows-1252') or (N = 'cp1252') then
    Exit(TEncoding.GetEncoding(1252));
  if (N = 'windows-1250') or (N = 'cp1250') then
    Exit(TEncoding.GetEncoding(1250));
  if (N = 'koi8-r') or (N = 'koi8r') then
    Exit(TEncoding.GetEncoding(20866));
  if (N = 'iso-8859-1') or (N = 'latin1') or (N = 'latin-1') then
    Exit(TEncoding.GetEncoding(28591));
  if (N = 'iso-8859-5') then
    Exit(TEncoding.GetEncoding(28595));
  { запасной вариант: числовой codepage }
  if (Length(N) > 2) and (N[1] = 'c') and (N[2] = 'p') then
    Exit(TEncoding.GetEncoding(StrToIntDef(Copy(N, 3, MaxInt), 0)));
  raise EFb2OperationError.CreateFmt('Неизвестная кодировка: %s', [Name]);
end;

{ Заменить значение атрибута encoding в декларации на Target.
  Found = True, если атрибут найден и заменён. }
function ReplaceEncodingInDecl(const Decl, Target: UnicodeString;
  out Found: Boolean): UnicodeString;
var
  I, J, L, VE: Integer;
  Quote: WideChar;
begin
  Result := Decl;
  Found := False;
  L := Length(Decl);
  I := 1;
  while I + 8 <= L do
  begin
    if LowerCase(Copy(Decl, I, 8)) = 'encoding' then
    begin
      J := I + 8;
      while (J <= L) and (Decl[J] <= ' ') do
        Inc(J);
      if (J <= L) and (Decl[J] = '=') then
      begin
        Inc(J);
        while (J <= L) and (Decl[J] <= ' ') do
          Inc(J);
        if (J <= L) and ((Decl[J] = '"') or (Decl[J] = '''')) then
        begin
          Quote := Decl[J];
          VE := J + 1;
          while (VE <= L) and (Decl[VE] <> Quote) do
            Inc(VE);
          if VE <= L then
          begin
            Result := Copy(Decl, 1, I - 1) + 'encoding="' + Target + '"' +
              Copy(Decl, VE + 1, MaxInt);
            Found := True;
            Exit;
          end;
        end;
      end;
    end;
    Inc(I);
  end;
end;

function TFb2Transcoder.ConvertBytes(const Data: TBytes;
  out UsedEncoding: UnicodeString; out Skipped: Boolean): TBytes;
var
  Actual, Source: UnicodeString;
  Payload: TBytes;
  Text: UnicodeString;
  SrcEnc, TgtEnc: TEncoding;
begin
  Skipped := False;
  SetLength(Result, 0);

  Actual := DetectEncodingOf(Data);
  if FSourceEncoding <> '' then
    Source := FSourceEncoding
  else
    Source := Actual;

  { Файл уже в целевой кодировке — пропускаем (кроме режима Force). }
  if (not FForce) and (NormalizeEnc(Actual) = NormalizeEnc(FTargetEncoding)) then
  begin
    Skipped := True;
    UsedEncoding := Actual;
    Exit;
  end;

  Payload := StripBom(Data);
  SrcEnc := EncodingByName(Source);
  Text := SrcEnc.GetString(Payload);
  Text := FixDeclaration(Text);
  TgtEnc := EncodingByName(FTargetEncoding);
  Result := TgtEnc.GetBytes(Text);

  if FBom then
    Result := ConcatBytes(BomBytes(FTargetEncoding), Result);
  UsedEncoding := Source;
end;

function TFb2Transcoder.FixDeclaration(const Text: UnicodeString): UnicodeString;
var
  Decl, OldDecl, NewDecl: UnicodeString;
  I, J, L, DeclStart, DeclEnd: Integer;
  HasEncoding: Boolean;
begin
  Decl := '<?xml version="1.0" encoding="' + FTargetEncoding + '"?>';
  L := Length(Text);

  I := 1;
  if (L >= 1) and (Text[1] = #$FEFF) then
    Inc(I);
  while (I <= L) and (Text[I] <= ' ') do
    Inc(I);

  DeclStart := I;
  if (I + 4 <= L) and (Copy(Text, I, 5) = '<?xml') then
  begin
    DeclEnd := 0;
    J := I;
    while J + 1 <= L do
    begin
      if (Text[J] = '?') and (Text[J + 1] = '>') then
      begin
        DeclEnd := J + 1;
        Break;
      end;
      Inc(J);
    end;
    if DeclEnd > 0 then
    begin
      OldDecl := Copy(Text, DeclStart, DeclEnd - DeclStart + 1);
      NewDecl := ReplaceEncodingInDecl(OldDecl, FTargetEncoding, HasEncoding);
      if not HasEncoding then
        NewDecl := Copy(OldDecl, 1, Length(OldDecl) - 2) + ' encoding="' +
          FTargetEncoding + '"?>';
      Result := NewDecl + Copy(Text, DeclEnd + 1, MaxInt);
      Exit;
    end;
  end;

  { Декларации нет — добавляем её в начало. }
  Result := Decl + #10 + Text;
end;

function TFb2Transcoder.TranscodeFile(const Path: UnicodeString;
  const Dest: UnicodeString; DryRun: Boolean): TTranscodeResult;
var
  Data, Converted: TBytes;
  Used, TargetPath: UnicodeString;
  Skipped: Boolean;
begin
  Result := TTranscodeResult.Create;
  Result.Source := Path;

  if not FileExists(Path) then
  begin
    Result.Error := 'Не удалось прочитать: файл недоступен';
    Exit;
  end;
  Data := ReadFileBytes(Path);

  try
    Converted := ConvertBytes(Data, Used, Skipped);
  except
    on E: Exception do
    begin
      Result.Error := E.Message;
      Result.SourceEncoding := FSourceEncoding;
      Exit;
    end;
  end;

  if Skipped then
  begin
    Result.SourceEncoding := Used;
    Result.Skipped := True;
    Exit;
  end;

  if Dest <> '' then
    TargetPath := Dest
  else
    TargetPath := Path;
  Result.Target := TargetPath;
  Result.SourceEncoding := Used;

  if DryRun then
    Exit;

  try
    WriteFileAtomic(TargetPath, Converted);
  except
    on E: Exception do
      Result.Error := 'Не удалось записать: ' + E.Message;
  end;
end;

class function TFb2Transcoder.DestPath(const Fb2, Root, OutRoot,
  Suffix: UnicodeString): UnicodeString;
var
  Name, Rel, RelDir: UnicodeString;
begin
  Name := ChangeFileExt(ExtractFileName(Fb2), '') + Suffix + ExtractFileExt(Fb2);
  if OutRoot <> '' then
  begin
    Rel := RelPath(Root, Fb2);
    RelDir := ExtractFileDir(Rel);
    if RelDir <> '' then
      Result := IncludeTrailingPathDelimiter(OutRoot) + RelDir + PathDelim + Name
    else
      Result := IncludeTrailingPathDelimiter(OutRoot) + Name;
  end
  else if Suffix <> '' then
    Result := IncludeTrailingPathDelimiter(ExtractFileDir(Fb2)) + Name
  else
    Result := Fb2;
end;

function TFb2Transcoder.TranscodeDir(const Directory, OutDir,
  Suffix: UnicodeString; DryRun: Boolean): TTranscodeResultList;
var
  Files: TStringList;
  I: Integer;
  Dest: UnicodeString;
begin
  Result := TTranscodeResultList.Create;
  Files := ListFilesRecursive(Directory, FB2_MASK);
  try
    for I := 0 to Files.Count - 1 do
    begin
      Dest := DestPath(Files[I], Directory, OutDir, Suffix);
      Result.Add(TranscodeFile(Files[I], Dest, DryRun));
    end;
  finally
    Files.Free;
  end;
end;

{ --- TTranscodeResult ----------------------------------------------- }

constructor TTranscodeResult.Create;
begin
  inherited Create;
  Source := '';
  Target := '';
  SourceEncoding := '';
  Skipped := False;
  Error := '';
end;

function TTranscodeResult.Ok: Boolean;
begin
  Result := Error = '';
end;

{ --- TFb2Transcoder ------------------------------------------------- }

constructor TFb2Transcoder.Create(const SourceEncoding, TargetEncoding: UnicodeString;
  Bom: Boolean; Force: Boolean; const Errors: UnicodeString);
begin
  inherited Create;
  FSourceEncoding := SourceEncoding;
  FTargetEncoding := TargetEncoding;
  FBom := Bom;
  FForce := Force;
  FErrors := Errors;
end;

end.
