unit fb2_to_txt;
{ Экспорт FB2 в обычный текст (TXT) — перевод fb2_to_txt.py.

  Собирает простой текстовый документ:
      * метаданные (<description>) -> заголовок, автор, аннотация;
      * вложенные <section>        -> заголовки (с подчёркиванием/отступом);
      * <p>                        -> абзацы (с отступом и переносом);
      * <epigraph>, <cite>         -> отступы;
      * <poem>/<stanza>/<v>        -> стихи;
      * <table>                    -> колонки через '  ';
      * <binary>                   -> строка-заглушка;
      * оглавление (опционально).

  Пример:
      C := TFb2ToTxtConverter.Create(1, 6, True, True);
      try
        C.Write('book.fb2', 'book.txt');
        Text := C.Convert('book.fb2');
      finally
        C.Free;
      end;

  Особенности перевода с Python:
      * источник задаётся путём к файлу или строкой XML;
      * перенос строк реализован без разрыва «длинных» слов (в Python
        textwrap по умолчанию их разрывает). }

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Classes, SysUtils, fgl,
  fb2_structures, fb2_parser, fb2_errors, fb2_files;

type
  { Заголовок для оглавления: уровень + текст. }
  THeading = record
    Level: Integer;
    Text: UnicodeString;
  end;

  THeadingArr = array of THeading;

  { Преобразование разобранного FB2 в обычный текст. }
  TFb2ToTxtConverter = class
  private
    FParser: TFb2Parser;
    FHeadingOffset: Integer;
    FMaxHeadingLevel: Integer;
    FIncludeMetadata: Boolean;
    FIncludeToc: Boolean;
    FTocTitle: UnicodeString;
    FIncludeAnnotation: Boolean;
    FIncludeEpigraphs: Boolean;
    FParagraphIndent: UnicodeString;
    FBlankLineBetweenParagraphs: Boolean;
    FHeadingUnderline: Boolean;
    FImagePlaceholder: UnicodeString;
    FHasImagePlaceholder: Boolean;
    FLineWidth: Integer;
    FDescription: TDescription;
    FBodies: TFb2ObjectList;

    procedure Prepare(const Source: UnicodeString);
    function BuildText: UnicodeString;
    function RenderMetadata: TTextList;
    function RenderToc: TTextList;
    function CollectHeadings: THeadingArr;
    function RenderBody(Body: TBody): TTextList;
    function RenderSection(Section: TSection; Level: Integer): TTextList;
    function HeadingLines(Title: TTitle; Level: Integer): TTextList;
    function RenderBlock(Block: TFb2Object;
      const Indent: UnicodeString): TTextList;
    function RenderCite(C: TCite): TTextList;
    function RenderEpigraph(E: TEpigraph): TTextList;
    function RenderPoem(P: TPoem): TTextList;
    function RenderStanza(S: TStanza): TTextList;
    function RenderTable(T: TTable): TTextList;
    function ParagraphLines(const Text, Indent: UnicodeString): TTextList;
    function ImagePlaceholderText(const Alt: UnicodeString): UnicodeString;
    function InlineText(Nodes: TFb2ObjectList): UnicodeString;
    function TitleText(Title: TTitle): UnicodeString;
    function AuthorText: UnicodeString;
    function FormatAuthor(A: TAuthor): UnicodeString;
  public
    constructor Create(HeadingOffset: Integer = 1; MaxHeadingLevel: Integer = 6;
      IncludeMetadata: Boolean = True; IncludeToc: Boolean = False;
      const TocTitle: UnicodeString = 'Оглавление';
      IncludeAnnotation: Boolean = True; IncludeEpigraphs: Boolean = True;
      const ParagraphIndent: UnicodeString = '    ';
      BlankLineBetweenParagraphs: Boolean = True;
      HeadingUnderline: Boolean = True;
      const ImagePlaceholder: UnicodeString = '[изображение]';
      LineWidth: Integer = 0);
    destructor Destroy; override;

    { Текстовое представление FB2-источника. }
    function Convert(const Source: UnicodeString): UnicodeString;

    { Сохранить книгу как TXT и вернуть путь к файлу. }
    function Write(const Source: UnicodeString;
      const Output: UnicodeString = ''): UnicodeString;
  end;

{ Собрать строки, схлопнув повторные пустые; результат завершается #10. }
function FinalizeText(Lines: TTextList): UnicodeString;

{ Объединить строки списка через #10. }
function JoinLines(Lines: TTextList): UnicodeString;

implementation

{ ===================== Служебные помощники ===================== }

{ Пробельный символ в смысле Python str.isspace(). }
function IsPySpace(C: WideChar): Boolean;
var
  U: LongWord;
begin
  U := Ord(C);
  Result := (U = $20) or ((U >= $09) and (U <= $0D)) or
    ((U >= $1C) and (U <= $1F)) or (U = $85) or (U = $A0) or (U = $1680) or
    ((U >= $2000) and (U <= $200A)) or (U = $2028) or (U = $2029) or
    (U = $202F) or (U = $205F) or (U = $3000);
end;

{ Аналог str.strip(): снимает пробелы по краям, включая Unicode-пробелы
  (в частности NBSP, который SysUtils.Trim не убирает). }
function PyStrip(const S: UnicodeString): UnicodeString;
var
  L, R: Integer;
begin
  L := 1;
  R := Length(S);
  while (L <= R) and IsPySpace(S[L]) do
    Inc(L);
  while (R >= L) and IsPySpace(S[R]) do
    Dec(R);
  Result := Copy(S, L, R - L + 1);
end;

{ Обрезать завершающие пробелы. }
function RTrimU(const S: UnicodeString): UnicodeString;
var
  N: Integer;
begin
  N := Length(S);
  while (N > 0) and ((S[N] = ' ') or (S[N] = #9) or (S[N] = #10) or
    (S[N] = #13)) do
    Dec(N);
  Result := Copy(S, 1, N);
end;

function RepeatCharU(C: WideChar; N: Integer): UnicodeString;
begin
  if N <= 0 then
    Result := ''
  else
    Result := StringOfChar(C, N);
end;

{ Дополнить строку пробелами справа до ширины N. }
function LJustU(const S: UnicodeString; N: Integer): UnicodeString;
begin
  Result := S;
  if Length(Result) < N then
    Result := Result + RepeatCharU(' ', N - Length(Result));
end;

{ Объединить строки списка через #10. }
function JoinLines(Lines: TTextList): UnicodeString;
var
  I: Integer;
begin
  Result := '';
  if Lines = nil then
    Exit;
  for I := 0 to Lines.Count - 1 do
  begin
    if I > 0 then
      Result := Result + #10;
    Result := Result + Lines[I];
  end;
end;

{ Собрать строки, схлопнув повторные пустые; результат завершается #10. }
function FinalizeText(Lines: TTextList): UnicodeString;
var
  Res: TTextList;
  I, Blanks: Integer;
  Line: UnicodeString;
begin
  Res := TTextList.Create;
  try
    Blanks := 0;
    for I := 0 to Lines.Count - 1 do
    begin
      Line := RTrimU(Lines[I]);
      if Line <> '' then
        Blanks := 0
      else
      begin
        Inc(Blanks);
        if Blanks > 1 then
          Continue;
      end;
      Res.Add(Line);
    end;
    while (Res.Count > 0) and (PyStrip(Res[0]) = '') do
      Res.Delete(0);
    while (Res.Count > 0) and (PyStrip(Res[Res.Count - 1]) = '') do
      Res.Delete(Res.Count - 1);
    Result := JoinLines(Res) + #10;
  finally
    Res.Free;
  end;
end;

{ Разбить текст на слова по пробельным символам. }
function SplitWords(const S: UnicodeString): TTextList;
var
  I: Integer;
  Cur: UnicodeString;
begin
  Result := TTextList.Create;
  Cur := '';
  for I := 1 to Length(S) + 1 do
  begin
    if (I <= Length(S)) and (S[I] > ' ') then
      Cur := Cur + S[I]
    else
    begin
      if Cur <> '' then
        Result.Add(Cur);
      Cur := '';
    end;
  end;
end;

{ Перенос текста: первая строка с отступом, последующие — без. }
function WrapText(const Text, InitialIndent: UnicodeString;
  Width: Integer): TTextList;
var
  Words: TTextList;
  I: Integer;
  Cur: UnicodeString;
begin
  Result := TTextList.Create;
  Words := SplitWords(Text);
  try
    Cur := InitialIndent;
    for I := 0 to Words.Count - 1 do
    begin
      if Cur = '' then
        Cur := Words[I]
      else if Length(Cur) + 1 + Length(Words[I]) <= Width then
        Cur := Cur + ' ' + Words[I]
      else
      begin
        Result.Add(Cur);
        Cur := Words[I];
      end;
    end;
    if Cur <> '' then
      Result.Add(Cur);
  finally
    Words.Free;
  end;
end;

{ ===================== TFb2ToTxtConverter ===================== }

constructor TFb2ToTxtConverter.Create(HeadingOffset: Integer;
  MaxHeadingLevel: Integer; IncludeMetadata: Boolean; IncludeToc: Boolean;
  const TocTitle: UnicodeString; IncludeAnnotation: Boolean;
  IncludeEpigraphs: Boolean; const ParagraphIndent: UnicodeString;
  BlankLineBetweenParagraphs: Boolean; HeadingUnderline: Boolean;
  const ImagePlaceholder: UnicodeString; LineWidth: Integer);
begin
  inherited Create;
  FParser := TFb2Parser.Create;
  FHeadingOffset := HeadingOffset;
  FMaxHeadingLevel := MaxHeadingLevel;
  FIncludeMetadata := IncludeMetadata;
  FIncludeToc := IncludeToc;
  FTocTitle := TocTitle;
  FIncludeAnnotation := IncludeAnnotation;
  FIncludeEpigraphs := IncludeEpigraphs;
  FParagraphIndent := ParagraphIndent;
  FBlankLineBetweenParagraphs := BlankLineBetweenParagraphs;
  FHeadingUnderline := HeadingUnderline;
  FImagePlaceholder := ImagePlaceholder;
  FHasImagePlaceholder := ImagePlaceholder <> '';
  FLineWidth := LineWidth;
  FDescription := nil;
  FBodies := nil;
end;

destructor TFb2ToTxtConverter.Destroy;
begin
  FreeAndNil(FDescription);
  FreeAndNil(FBodies);
  FreeAndNil(FParser);
  inherited Destroy;
end;

{ Разобрать источник (путь к файлу или строка XML) в структуры. }
procedure TFb2ToTxtConverter.Prepare(const Source: UnicodeString);
var
  Mem: TMemoryStream;
  B: TBytes;
begin
  if FileExists(Source) then
    FParser.LoadFile(Source)
  else
  begin
    B := TEncoding.UTF8.GetBytes(Source);
    Mem := TMemoryStream.Create;
    try
      if Length(B) > 0 then
        Mem.WriteBuffer(B[0], Length(B));
      Mem.Position := 0;
      FParser.LoadStream(Mem);
    finally
      Mem.Free;
    end;
  end;

  FreeAndNil(FDescription);
  try
    FDescription := FParser.Parse;
  except
    on E: EFb2Error do
      FDescription := nil;
  end;
  FreeAndNil(FBodies);
  FBodies := FParser.ParseBodies;
end;

function TFb2ToTxtConverter.Convert(const Source: UnicodeString): UnicodeString;
begin
  Prepare(Source);
  Result := BuildText;
end;

function TFb2ToTxtConverter.Write(const Source: UnicodeString;
  const Output: UnicodeString): UnicodeString;
var
  Text, Target: UnicodeString;
begin
  Text := Convert(Source);
  if Output <> '' then
    Target := Output
  else if FileExists(Source) then
    Target := ChangeFileExt(Source, '.txt')
  else
    Target := 'book.txt';
  WriteFileAtomic(Target, TEncoding.UTF8.GetBytes(Text));
  Result := Target;
end;

{ --- Вспомогательные методы --------------------------------------- }

{ Плоский текст inline-узлов (без разметки). }
function TFb2ToTxtConverter.InlineText(Nodes: TFb2ObjectList): UnicodeString;
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
    else if Node.Tag = 'image' then
      Result := Result + ImagePlaceholderText(Node.ImageAlt)
    else
      Result := Result + InlineText(Node.Children);
  end;
end;

{ Строка-заглушка для изображения. }
function TFb2ToTxtConverter.ImagePlaceholderText(
  const Alt: UnicodeString): UnicodeString;
begin
  if not FHasImagePlaceholder then
    Exit('');
  if Alt <> '' then
    Result := FImagePlaceholder + ' ' + Alt
  else
    Result := FImagePlaceholder;
end;

{ Плоский текст заголовка. }
function TFb2ToTxtConverter.TitleText(Title: TTitle): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
  S: UnicodeString;
begin
  Result := '';
  if Title = nil then
    Exit;
  Parts := TTextList.Create;
  try
    for I := 0 to Title.Items.Count - 1 do
      if Title.Items[I] is TParagraph then
      begin
        S := PyStrip(InlineText(TParagraph(Title.Items[I]).Content));
        if S <> '' then
          Parts.Add(S);
      end;
    Result := JoinText(Parts, ' ');
  finally
    Parts.Free;
  end;
end;

{ Имя автора из структуры TAuthor. }
function TFb2ToTxtConverter.FormatAuthor(A: TAuthor): UnicodeString;
var
  Parts: TTextList;
begin
  Result := '';
  if A = nil then
    Exit;
  Parts := TTextList.Create;
  try
    if A.FirstName <> '' then
      Parts.Add(A.FirstName);
    if A.MiddleName <> '' then
      Parts.Add(A.MiddleName);
    if A.LastName <> '' then
      Parts.Add(A.LastName);
    Result := JoinText(Parts, ' ');
  finally
    Parts.Free;
  end;
  if Result = '' then
    Result := A.Nickname;
end;

{ Строка со всеми авторами книги. }
function TFb2ToTxtConverter.AuthorText: UnicodeString;
var
  Info: TTitleInfo;
  Parts: TTextList;
  I: Integer;
begin
  Result := '';
  Info := nil;
  if FDescription <> nil then
    Info := FDescription.TitleInfo;
  if Info = nil then
    Exit;
  Parts := TTextList.Create;
  try
    for I := 0 to Info.Authors.Count - 1 do
      Parts.Add(FormatAuthor(TAuthor(Info.Authors[I])));
    Result := JoinText(Parts, '; ');
  finally
    Parts.Free;
  end;
end;

{ Строки абзаца (отступ первой строки + опциональный перенос). }
function TFb2ToTxtConverter.ParagraphLines(const Text,
  Indent: UnicodeString): TTextList;
var
  T: UnicodeString;
  Wrapped: TTextList;
  I: Integer;
begin
  Result := TTextList.Create;
  T := PyStrip(Text);
  if T = '' then
    Exit;
  if FLineWidth > 0 then
  begin
    Wrapped := WrapText(T, Indent, FLineWidth);
    try
      for I := 0 to Wrapped.Count - 1 do
        Result.Add(Wrapped[I]);
    finally
      Wrapped.Free;
    end;
  end
  else
    Result.Add(Indent + T);
  if FBlankLineBetweenParagraphs then
    Result.Add('');
end;

{ ===================== Блочные элементы ===================== }

type
  TTextListList = specialize TFPGObjectList<TTextList>;

{ Дописать строки Src в Dst и освободить Src. }
procedure AppendAndFree(Dst, Src: TTextList);
var
  I: Integer;
begin
  if (Dst = nil) or (Src = nil) then
    Exit;
  for I := 0 to Src.Count - 1 do
    Dst.Add(Src[I]);
  Src.Free;
end;

{ Строки заголовка (подчёркивание/отступ). }
function TFb2ToTxtConverter.HeadingLines(Title: TTitle;
  Level: Integer): TTextList;
var
  Text: UnicodeString;
begin
  Result := TTextList.Create;
  Text := TitleText(Title);
  if Text = '' then
    Exit;
  if Level < 1 then
    Level := 1;
  if Level > FMaxHeadingLevel then
    Level := FMaxHeadingLevel;
  if FHeadingUnderline and (Level = 1) then
  begin
    Result.Add(Text);
    Result.Add(RepeatCharU('=', Length(Text)));
  end
  else if FHeadingUnderline and (Level = 2) then
  begin
    Result.Add(Text);
    Result.Add(RepeatCharU('-', Length(Text)));
  end
  else
    Result.Add(RepeatCharU(' ', 2 * (Level - 1)) + Text);
  Result.Add('');
end;

{ Отрисовать блочный элемент FB2. }
function TFb2ToTxtConverter.RenderBlock(Block: TFb2Object;
  const Indent: UnicodeString): TTextList;
var
  Effective, Text: UnicodeString;
begin
  Result := TTextList.Create;
  if Block = nil then
    Exit;

  if Block is TParagraph then
  begin
    if Indent <> '' then
      Effective := Indent
    else
      Effective := FParagraphIndent;
    AppendAndFree(Result,
      ParagraphLines(InlineText(TParagraph(Block).Content), Effective));
    Exit;
  end;

  if Block is TSubtitle then
  begin
    Result.Add(Indent + InlineText(TSubtitle(Block).Content));
    Result.Add('');
    Exit;
  end;

  if Block is TEmptyLine then
  begin
    Result.Add('');
    Exit;
  end;

  if Block is TCite then
    Exit(RenderCite(TCite(Block)));
  if Block is TEpigraph then
    Exit(RenderEpigraph(TEpigraph(Block)));
  if Block is TPoem then
    Exit(RenderPoem(TPoem(Block)));
  if Block is TTable then
    Exit(RenderTable(TTable(Block)));
  if Block is TImage then
  begin
    Text := ImagePlaceholderText(TImage(Block).Alt);
    if Text <> '' then
    begin
      Result.Add(Text);
      Result.Add('');
    end;
  end;
end;

{ Цитата <cite> (с отступом). }
function TFb2ToTxtConverter.RenderCite(C: TCite): TTextList;
var
  Indent: UnicodeString;
  I: Integer;
begin
  Result := TTextList.Create;
  Indent := FParagraphIndent + '    ';
  for I := 0 to C.Items.Count - 1 do
    AppendAndFree(Result, RenderBlock(C.Items[I], Indent));
  for I := 0 to C.TextAuthor.Count - 1 do
  begin
    Result.Add(Indent + '— ' +
      InlineText(TParagraph(C.TextAuthor[I]).Content));
    Result.Add('');
  end;
end;

{ Эпиграф <epigraph> (с отступом). }
function TFb2ToTxtConverter.RenderEpigraph(E: TEpigraph): TTextList;
var
  Indent: UnicodeString;
  I: Integer;
begin
  Result := TTextList.Create;
  Indent := FParagraphIndent + '    ';
  for I := 0 to E.Items.Count - 1 do
    AppendAndFree(Result, RenderBlock(E.Items[I], Indent));
  for I := 0 to E.TextAuthor.Count - 1 do
  begin
    Result.Add(Indent + '— ' +
      InlineText(TParagraph(E.TextAuthor[I]).Content));
    Result.Add('');
  end;
end;

{ Стихотворение <poem>. }
function TFb2ToTxtConverter.RenderPoem(P: TPoem): TTextList;
var
  I: Integer;
begin
  Result := TTextList.Create;
  if P.Title <> nil then
    AppendAndFree(Result, HeadingLines(P.Title, 3));
  for I := 0 to P.Epigraphs.Count - 1 do
    AppendAndFree(Result, RenderEpigraph(TEpigraph(P.Epigraphs[I])));
  for I := 0 to P.Items.Count - 1 do
  begin
    if P.Items[I] is TStanza then
      AppendAndFree(Result, RenderStanza(TStanza(P.Items[I])))
    else if P.Items[I] is TSubtitle then
    begin
      Result.Add(FParagraphIndent +
        InlineText(TSubtitle(P.Items[I]).Content));
      Result.Add('');
    end;
  end;
  for I := 0 to P.TextAuthor.Count - 1 do
  begin
    Result.Add(FParagraphIndent + '— ' +
      InlineText(TParagraph(P.TextAuthor[I]).Content));
    Result.Add('');
  end;
end;

{ Строфа <stanza> (строки с отступом). }
function TFb2ToTxtConverter.RenderStanza(S: TStanza): TTextList;
var
  I: Integer;
begin
  Result := TTextList.Create;
  if S.Subtitle <> nil then
  begin
    Result.Add(FParagraphIndent + InlineText(S.Subtitle.Content));
    Result.Add('');
  end;
  for I := 0 to S.Verses.Count - 1 do
    Result.Add(FParagraphIndent +
      InlineText(TParagraph(S.Verses[I]).Content));
  Result.Add('');
end;

{ Таблица <table> (колонки через два пробела). }
function TFb2ToTxtConverter.RenderTable(T: TTable): TTextList;
var
  Rows: TTextListList;
  Row: TTextList;
  I, J, Width: Integer;
  ColWidths: array of Integer;
  Line: UnicodeString;
  First: Boolean;
begin
  Result := TTextList.Create;
  Rows := TTextListList.Create;
  try
    for I := 0 to T.Rows.Count - 1 do
    begin
      Row := TTextList.Create;
      for J := 0 to TTableRow(T.Rows[I]).Cells.Count - 1 do
        Row.Add(PyStrip(InlineText(
          TTableCell(TTableRow(T.Rows[I]).Cells[J]).Children)));
      Rows.Add(Row);
    end;
    if Rows.Count = 0 then
      Exit;

    Width := 0;
    for I := 0 to Rows.Count - 1 do
      if Rows[I].Count > Width then
        Width := Rows[I].Count;
    for I := 0 to Rows.Count - 1 do
      while Rows[I].Count < Width do
        Rows[I].Add('');

    SetLength(ColWidths, Width);
    for J := 0 to Width - 1 do
    begin
      ColWidths[J] := 0;
      for I := 0 to Rows.Count - 1 do
        if Length(Rows[I][J]) > ColWidths[J] then
          ColWidths[J] := Length(Rows[I][J]);
    end;

    for I := 0 to Rows.Count - 1 do
    begin
      Line := '';
      First := True;
      for J := 0 to Width - 1 do
      begin
        if not First then
          Line := Line + '  ';
        Line := Line + LJustU(Rows[I][J], ColWidths[J]);
        First := False;
      end;
      Result.Add(RTrimU(Line));
    end;
    Result.Add('');
  finally
    Rows.Free;
  end;
end;

{ ===================== Сборка текста ===================== }

function TFb2ToTxtConverter.BuildText: UnicodeString;
var
  Lines: TTextList;
  I: Integer;
begin
  Lines := TTextList.Create;
  try
    if FIncludeMetadata then
      AppendAndFree(Lines, RenderMetadata);
    if FIncludeToc then
      AppendAndFree(Lines, RenderToc);
    if FBodies <> nil then
      for I := 0 to FBodies.Count - 1 do
        AppendAndFree(Lines, RenderBody(TBody(FBodies[I])));
    Result := FinalizeText(Lines);
  finally
    Lines.Free;
  end;
end;

{ Заголовок книги, автор, аннотация. }
function TFb2ToTxtConverter.RenderMetadata: TTextList;
var
  Info: TTitleInfo;
  Title, Authors: UnicodeString;
  I: Integer;
begin
  Result := TTextList.Create;
  Info := nil;
  if FDescription <> nil then
    Info := FDescription.TitleInfo;
  if Info = nil then
    Exit;

  if (Info.BookTitle <> nil) and (Info.BookTitle.Value <> '') then
  begin
    Title := Info.BookTitle.Value;
    Result.Add(Title);
    if FHeadingUnderline then
      Result.Add(RepeatCharU('=', Length(Title)));
    Result.Add('');
  end;

  Authors := AuthorText;
  if Authors <> '' then
  begin
    Result.Add(Authors);
    Result.Add('');
  end;

  if FIncludeAnnotation and (Info.Annotation <> nil) then
  begin
    for I := 0 to Info.Annotation.Items.Count - 1 do
      AppendAndFree(Result,
        RenderBlock(Info.Annotation.Items[I], FParagraphIndent));
    Result.Add('');
  end;
end;

{ Собрать (уровень, текст) заголовков для оглавления. }
function TFb2ToTxtConverter.CollectHeadings: THeadingArr;
var
  Res: THeadingArr;
  I, J: Integer;
  Text: UnicodeString;

  procedure AddHeading(Level: Integer; const AText: UnicodeString);
  begin
    if AText = '' then
      Exit;
    SetLength(Res, Length(Res) + 1);
    Res[High(Res)].Level := Level;
    Res[High(Res)].Text := AText;
  end;

  procedure Walk(S: TSection; Level: Integer);
  var
    K: Integer;
  begin
    if S.Title <> nil then
      AddHeading(Level, TitleText(S.Title));
    for K := 0 to S.Sections.Count - 1 do
      Walk(TSection(S.Sections[K]), Level + 1);
  end;

begin
  SetLength(Res, 0);
  if FBodies <> nil then
    for I := 0 to FBodies.Count - 1 do
    begin
      if TBody(FBodies[I]).Title <> nil then
      begin
        Text := TitleText(TBody(FBodies[I]).Title);
        if Text <> '' then
          AddHeading(0, Text);
      end;
      for J := 0 to TBody(FBodies[I]).Sections.Count - 1 do
        Walk(TSection(TBody(FBodies[I]).Sections[J]), FHeadingOffset);
    end;
  Result := Res;
end;

{ Оглавление (список заголовков с отступами по уровню). }
function TFb2ToTxtConverter.RenderToc: TTextList;
var
  Headings: THeadingArr;
  I, Pad: Integer;
begin
  Result := TTextList.Create;
  Headings := CollectHeadings;
  if Length(Headings) = 0 then
    Exit;
  Result.Add(FTocTitle);
  Result.Add('');
  for I := 0 to High(Headings) do
  begin
    Pad := Headings[I].Level - 1;
    if Pad < 0 then
      Pad := 0;
    Result.Add(RepeatCharU(' ', 2 * Pad) + Headings[I].Text);
  end;
  Result.Add('');
end;

{ Отрисовать <body>. }
function TFb2ToTxtConverter.RenderBody(Body: TBody): TTextList;
var
  I: Integer;
  Text: UnicodeString;
begin
  Result := TTextList.Create;
  if Body.Title <> nil then
    AppendAndFree(Result, HeadingLines(Body.Title, 1));
  if FIncludeEpigraphs then
    for I := 0 to Body.Epigraphs.Count - 1 do
      AppendAndFree(Result, RenderEpigraph(TEpigraph(Body.Epigraphs[I])));
  if Body.Image <> nil then
  begin
    Text := ImagePlaceholderText(Body.Image.Alt);
    if Text <> '' then
    begin
      Result.Add(Text);
      Result.Add('');
    end;
  end;
  for I := 0 to Body.Sections.Count - 1 do
    AppendAndFree(Result,
      RenderSection(TSection(Body.Sections[I]), FHeadingOffset));
end;

{ Отрисовать секцию (рекурсивно). }
function TFb2ToTxtConverter.RenderSection(Section: TSection;
  Level: Integer): TTextList;
var
  I: Integer;
  Text: UnicodeString;
begin
  Result := TTextList.Create;
  if Section.Title <> nil then
    AppendAndFree(Result, HeadingLines(Section.Title, Level));
  if FIncludeEpigraphs then
    for I := 0 to Section.Epigraphs.Count - 1 do
      AppendAndFree(Result, RenderEpigraph(TEpigraph(Section.Epigraphs[I])));
  if Section.Image <> nil then
  begin
    Text := ImagePlaceholderText(Section.Image.Alt);
    if Text <> '' then
    begin
      Result.Add(Text);
      Result.Add('');
    end;
  end;
  if FIncludeAnnotation and (Section.Annotation <> nil) then
    for I := 0 to Section.Annotation.Items.Count - 1 do
      AppendAndFree(Result,
        RenderBlock(Section.Annotation.Items[I], FParagraphIndent));
  for I := 0 to Section.Content.Count - 1 do
    AppendAndFree(Result, RenderBlock(Section.Content[I], ''));
  for I := 0 to Section.Sections.Count - 1 do
    AppendAndFree(Result,
      RenderSection(TSection(Section.Sections[I]), Level + 1));
end;

end.
