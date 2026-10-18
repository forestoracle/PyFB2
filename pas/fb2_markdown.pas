unit fb2_markdown;
{ Экспорт FB2 в Markdown с сохранением изображений — перевод fb2_markdown.py.

  Модуль предоставляет класс TFb2MarkdownWriter, который берёт структуры из
  fb2_parser.pas (см. TFb2Parser) и превращает книгу в Markdown-документ:

      * метаданные (<description>)        -> заголовок, автор, жанры, аннотация;
      * вложенные <section>               -> заголовки #/##/###;
      * <p>, <strong>, <emphasis>, <a>    -> абзацы и inline-разметка;
      * <epigraph>, <cite>                -> цитаты (>);
      * <poem>/<stanza>/<v>               -> стихи с переносами строк;
      * <table>/<tr>/<td>                 -> Markdown-таблица;
      * <binary>                          -> файлы изображений + ссылки ![](…).

  Особенности перевода с Python:
      * str.join(list)        -> JoinText;
      * re.sub экранирования  -> посимвольное экранирование;
      * dict id->файл         -> TStringList (Key = id, Value = имя файла);
      * список строк          -> TTextList.

  Пример:
      var W: TFb2MarkdownWriter;
      begin
        W := TFb2MarkdownWriter.Create(nil, 'images');
        try
          W.Write('book.fb2', 'book.md');
        finally
          W.Free;
        end;
      end; }

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Classes, SysUtils, fgl,
  fb2_structures, fb2_parser;

type
  { Преобразование разобранного FB2 в Markdown + выгрузка картинок. }
  TFb2MarkdownWriter = class
  private
    FParser: TFb2Parser;
    FOwnsParser: Boolean;
    FImageDir: UnicodeString;
    FHeadingOffset: Integer;
    FMaxHeadingLevel: Integer;
    FIncludeAnnotation: Boolean;
    FIncludeEpigraphs: Boolean;
    FIncludeCover: Boolean;
    FEscapeText: Boolean;

    FDescription: TDescription;
    FBodies: TFb2ObjectList;
    FBinaries: TFb2ObjectList;
    FImageFiles: TStringList;      { id <binary> -> имя файла }

    procedure Prepare;
    function BuildMarkdown: UnicodeString;

    function RenderDescription: TTextList;
    function RenderBody(Body: TBody): TTextList;
    function RenderSection(Section: TSection; Depth: Integer): TTextList;
    function RenderBlock(Block: TFb2Object): TTextList;
    function RenderAnnotation(Annotation: TAnnotation): TTextList;
    function RenderEpigraph(Epigraph: TEpigraph): TTextList;
    function RenderCite(Cite: TCite): TTextList;
    function RenderPoem(Poem: TPoem): TTextList;
    function RenderStanza(Stanza: TStanza): TTextList;
    function RenderTable(Table: TTable): TTextList;
    function RenderTableRowCells(Row: TTableRow): TTextList;
    function RenderTableCell(Cell: TTableCell): UnicodeString;
    function RenderInline(Nodes: TFb2ObjectList): UnicodeString;
    function RenderLink(Node: TStyleNode): UnicodeString;
    function RenderImage(Href, Alt: UnicodeString): UnicodeString;
    function ImageLink(Href: UnicodeString): UnicodeString;
    function TitleText(Title: TTitle): UnicodeString;
    function Escape(const S: UnicodeString): UnicodeString;
    procedure RegisterImages;
    function Finalize(Lines: TTextList): UnicodeString;
  public
    constructor Create(Parser: TFb2Parser = nil;
      const ImageDir: UnicodeString = 'images';
      HeadingOffset: Integer = 2;
      MaxHeadingLevel: Integer = 6;
      IncludeAnnotation: Boolean = True;
      IncludeEpigraphs: Boolean = True;
      IncludeCover: Boolean = True;
      EscapeText: Boolean = True);
    destructor Destroy; override;

    { Вернуть Markdown-текст (файлы не создаются). }
    function Convert(const SourceFile: UnicodeString): UnicodeString;
    { Сохранить книгу как Markdown и выгрузить все <binary>. }
    function Write(const SourceFile, MdPath: UnicodeString): UnicodeString;
    { Выгрузить все <binary> в каталог изображений. }
    function SaveImages(const BaseDir: UnicodeString): TTextList;

    property Parser: TFb2Parser read FParser;
    property Description: TDescription read FDescription;
    property Bodies: TFb2ObjectList read FBodies;
    property Binaries: TFb2ObjectList read FBinaries;
  end;

implementation

function IsMdSpecial(C: WideChar): Boolean;
begin
  Result := (C = '\') or (C = '`') or (C = '*') or (C = '_') or
    (C = '[') or (C = ']');
end;

function RepeatStrM(const S: UnicodeString; N: Integer): UnicodeString;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to N do
    Result := Result + S;
end;

function JoinNonEmpty(List: TTextList; const Sep: UnicodeString): UnicodeString;
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
      Result := Result + Sep;
    Result := Result + List[I];
    First := False;
  end;
end;

{ Записать текст в файл в кодировке UTF-8 без BOM. }
procedure WriteUtf8File(const FileName: UnicodeString; const Text: UnicodeString);
var
  FS: TFileStream;
  Bytes: TBytes;
begin
  Bytes := TEncoding.UTF8.GetBytes(Text);
  if (Length(Bytes) >= 3) and (Bytes[0] = $EF) and (Bytes[1] = $BB) and
    (Bytes[2] = $BF) then
    Delete(Bytes, 0, 3);
  FS := TFileStream.Create(FileName, fmCreate);
  try
    if Length(Bytes) > 0 then
      FS.WriteBuffer(Bytes[0], Length(Bytes));
  finally
    FS.Free;
  end;
end;

{ Оформить строки как цитату (blockquote) и добавить в приёмник. }
procedure QuoteInto(Dest: TTextList; Src: TTextList);
var
  I: Integer;
  Line: UnicodeString;
begin
  for I := 0 to Src.Count - 1 do
  begin
    Line := Src[I];
    if UTrim(Line) <> '' then
      Dest.Add(UTrimRight('> ' + Line))
    else
      Dest.Add('>');
  end;
end;

{ ===================== Конструктор / деструктор ===================== }

constructor TFb2MarkdownWriter.Create(Parser: TFb2Parser;
  const ImageDir: UnicodeString; HeadingOffset, MaxHeadingLevel: Integer;
  IncludeAnnotation, IncludeEpigraphs, IncludeCover, EscapeText: Boolean);
begin
  inherited Create;
  if Parser <> nil then
  begin
    FParser := Parser;
    FOwnsParser := False;
  end
  else
  begin
    FParser := TFb2Parser.Create;
    FOwnsParser := True;
  end;
  FImageDir := ImageDir;
  FHeadingOffset := HeadingOffset;
  FMaxHeadingLevel := MaxHeadingLevel;
  FIncludeAnnotation := IncludeAnnotation;
  FIncludeEpigraphs := IncludeEpigraphs;
  FIncludeCover := IncludeCover;
  FEscapeText := EscapeText;
  FImageFiles := TStringList.Create;
end;

destructor TFb2MarkdownWriter.Destroy;
begin
  FreeAndNil(FDescription);
  FreeAndNil(FBodies);
  FreeAndNil(FBinaries);
  FreeAndNil(FImageFiles);
  if FOwnsParser then
    FreeAndNil(FParser);
  inherited Destroy;
end;

{ ===================== Публичный API ===================== }

procedure TFb2MarkdownWriter.Prepare;
begin
  { Освобождаем результаты предыдущего разбора (повторные вызовы Convert/Write). }
  FreeAndNil(FDescription);
  FreeAndNil(FBodies);
  FreeAndNil(FBinaries);

  try
    FDescription := FParser.Parse;
  except
    FDescription := nil;
  end;
  FBodies := FParser.ParseBodies;
  FBinaries := FParser.ParseBinaries;
  RegisterImages;
end;

function TFb2MarkdownWriter.Convert(const SourceFile: UnicodeString): UnicodeString;
begin
  FParser.LoadFile(SourceFile);
  Prepare;
  Result := BuildMarkdown;
end;

function TFb2MarkdownWriter.Write(const SourceFile,
  MdPath: UnicodeString): UnicodeString;
var
  MdDir: UnicodeString;
  Saved: TTextList;
begin
  FParser.LoadFile(SourceFile);
  Prepare;
  Result := BuildMarkdown;

  MdDir := ExtractFileDir(MdPath);
  if MdDir <> '' then
    ForceDirectories(MdDir);
  Saved := SaveImages(MdDir);
  Saved.Free;
  WriteUtf8File(MdPath, Result);
end;

function TFb2MarkdownWriter.SaveImages(
  const BaseDir: UnicodeString): TTextList;
var
  TargetDir, Filename, Path: UnicodeString;
  I: Integer;
  Binary: TBinary;
  Data: TBytes;
  FS: TFileStream;
begin
  Result := TTextList.Create;
  if (FBinaries = nil) or (FBinaries.Count = 0) then
    Exit;

  if FImageDir <> '' then
  begin
    if BaseDir <> '' then
      TargetDir := IncludeTrailingPathDelimiter(BaseDir) + FImageDir
    else
      TargetDir := FImageDir;
  end
  else
    TargetDir := BaseDir;
  if TargetDir = '' then
    TargetDir := '.';
  ForceDirectories(TargetDir);

  for I := 0 to FBinaries.Count - 1 do
  begin
    Binary := TBinary(FBinaries[I]);
    Filename := FImageFiles.Values[Binary.Id];
    if Filename = '' then
      Continue;
    Path := IncludeTrailingPathDelimiter(TargetDir) + Filename;
    Data := FParser.BinaryData(Binary);
    FS := TFileStream.Create(Path, fmCreate);
    try
      if Length(Data) > 0 then
        FS.WriteBuffer(Data[0], Length(Data));
    finally
      FS.Free;
    end;
    Result.Add(Path);
  end;
end;

procedure TFb2MarkdownWriter.RegisterImages;
var
  I: Integer;
  Binary: TBinary;
  Filename, Stem, Suffix, Candidate: UnicodeString;
  Counter, P: Integer;
  Used: TStringList;
begin
  FImageFiles.Clear;
  Used := TStringList.Create;
  try
    for I := 0 to FBinaries.Count - 1 do
    begin
      Binary := TBinary(FBinaries[I]);
      Filename := FParser.BinaryFilename(Binary);
      P := LastDelimiter('.', Filename);
      if P > 0 then
      begin
        Stem := Copy(Filename, 1, P - 1);
        Suffix := Copy(Filename, P, Length(Filename) - P + 1);
      end
      else
      begin
        Stem := Filename;
        Suffix := '';
      end;
      Candidate := Filename;
      Counter := 1;
      while Used.IndexOf(Candidate) >= 0 do
      begin
        Candidate := Stem + '_' + IntToStr(Counter) + Suffix;
        Inc(Counter);
      end;
      Used.Add(Candidate);
      FImageFiles.Values[Binary.Id] := Candidate;
    end;
  finally
    Used.Free;
  end;
end;

{ ===================== Сборка документа ===================== }

function TFb2MarkdownWriter.BuildMarkdown: UnicodeString;
var
  Lines, Part: TTextList;
  I: Integer;
begin
  Lines := TTextList.Create;
  try
    Part := RenderDescription;
    try
      Lines.AddStrings(Part);
    finally
      Part.Free;
    end;

    for I := 0 to FBodies.Count - 1 do
    begin
      if I > 0 then
      begin
        Lines.Add('');
        Lines.Add('---');
        Lines.Add('');
      end;
      Part := RenderBody(TBody(FBodies[I]));
      try
        Lines.AddStrings(Part);
      finally
        Part.Free;
      end;
    end;

    Result := Finalize(Lines);
  finally
    Lines.Free;
  end;
end;

function TFb2MarkdownWriter.RenderDescription: TTextList;
var
  Info: TTitleInfo;
  Authors, Genres, SeqParts: TTextList;
  Inner: TTextList;
  I: Integer;
  S: UnicodeString;
begin
  Result := TTextList.Create;
  if FDescription = nil then
    Exit;
  Info := FDescription.TitleInfo;
  if Info = nil then
    Exit;

  if (Info.BookTitle <> nil) and (Info.BookTitle.Value <> '') then
  begin
    Result.Add('# ' + Escape(Info.BookTitle.Value));
    Result.Add('');
  end;

  Authors := TTextList.Create;
  try
    for I := 0 to Info.Authors.Count - 1 do
      Authors.Add(FParser.FormatAuthor(TAuthor(Info.Authors[I])));
    S := JoinText(Authors, '; ');
    if S <> '' then
    begin
      Result.Add('**Автор:** ' + S);
      Result.Add('');
    end;
  finally
    Authors.Free;
  end;

  if Info.Genres.Count > 0 then
  begin
    Genres := TTextList.Create;
    try
      for I := 0 to Info.Genres.Count - 1 do
        Genres.Add(TGenre(Info.Genres[I]).Value);
      Result.Add('**Жанры:** ' + JoinText(Genres, ', '));
      Result.Add('');
    finally
      Genres.Free;
    end;
  end;

  if Info.Sequences.Count > 0 then
  begin
    SeqParts := TTextList.Create;
    try
      for I := 0 to Info.Sequences.Count - 1 do
      begin
        if TSequence(Info.Sequences[I]).Number <> NO_VALUE then
          SeqParts.Add(TSequence(Info.Sequences[I]).Name + ' #' +
            IntToStr(TSequence(Info.Sequences[I]).Number))
        else
          SeqParts.Add(TSequence(Info.Sequences[I]).Name);
      end;
      Result.Add('**Серия:** ' + JoinText(SeqParts, '; '));
      Result.Add('');
    finally
      SeqParts.Free;
    end;
  end;

  if (Info.Date <> nil) and (Info.Date.Value <> '') then
  begin
    Result.Add('**Дата:** ' + Info.Date.Value);
    Result.Add('');
  end;

  if Info.Lang <> '' then
  begin
    Result.Add('**Язык:** ' + Info.Lang);
    Result.Add('');
  end;

  if FIncludeCover and (Info.Coverpage <> nil) then
    for I := 0 to Info.Coverpage.Images.Count - 1 do
    begin
      S := RenderImage(TInlineImage(Info.Coverpage.Images[I]).Href,
        TInlineImage(Info.Coverpage.Images[I]).Alt);
      if (S = '') and (TInlineImage(Info.Coverpage.Images[I]).Alt = '') then
        S := RenderImage(TInlineImage(Info.Coverpage.Images[I]).Href, 'Обложка');
      if S <> '' then
      begin
        Result.Add(S);
        Result.Add('');
      end;
    end;

  if FIncludeAnnotation and (Info.Annotation <> nil) then
  begin
    Inner := RenderAnnotation(Info.Annotation);
    try
      if Inner.Count > 0 then
      begin
        QuoteInto(Result, Inner);
        Result.Add('');
      end;
    finally
      Inner.Free;
    end;
  end;
end;

function TFb2MarkdownWriter.RenderBody(Body: TBody): TTextList;
var
  Title: UnicodeString;
  Level, I: Integer;
  Part: TTextList;
begin
  Result := TTextList.Create;

  if Body.Title <> nil then
  begin
    Title := TitleText(Body.Title);
    if Title <> '' then
    begin
      Level := FHeadingOffset - 1;
      if Level < 1 then
        Level := 1;
      Result.Add(RepeatStrM('#', Level) + ' ' + Title);
      Result.Add('');
    end;
  end;

  if FIncludeEpigraphs then
    for I := 0 to Body.Epigraphs.Count - 1 do
    begin
      Part := RenderEpigraph(TEpigraph(Body.Epigraphs[I]));
      try
        Result.AddStrings(Part);
      finally
        Part.Free;
      end;
    end;

  if Body.Image <> nil then
  begin
    Title := RenderImage(Body.Image.Href, Body.Image.Alt);
    if Title <> '' then
    begin
      Result.Add(Title);
      Result.Add('');
    end;
  end;

  for I := 0 to Body.Sections.Count - 1 do
  begin
    Part := RenderSection(TSection(Body.Sections[I]), 0);
    try
      Result.AddStrings(Part);
    finally
      Part.Free;
    end;
  end;
end;

function TFb2MarkdownWriter.RenderSection(Section: TSection;
  Depth: Integer): TTextList;
var
  Title: UnicodeString;
  Level, I: Integer;
  Part, Inner: TTextList;
begin
  Result := TTextList.Create;

  Title := TitleText(Section.Title);
  if Title <> '' then
  begin
    Level := FHeadingOffset + Depth;
    if Level > FMaxHeadingLevel then
      Level := FMaxHeadingLevel;
    Result.Add(RepeatStrM('#', Level) + ' ' + Title);
    Result.Add('');
  end;

  if FIncludeEpigraphs then
    for I := 0 to Section.Epigraphs.Count - 1 do
    begin
      Part := RenderEpigraph(TEpigraph(Section.Epigraphs[I]));
      try
        Result.AddStrings(Part);
      finally
        Part.Free;
      end;
    end;

  if Section.Image <> nil then
  begin
    Title := RenderImage(Section.Image.Href, Section.Image.Alt);
    if Title <> '' then
    begin
      Result.Add(Title);
      Result.Add('');
    end;
  end;

  if FIncludeAnnotation and (Section.Annotation <> nil) then
  begin
    Inner := RenderAnnotation(Section.Annotation);
    try
      if Inner.Count > 0 then
      begin
        QuoteInto(Result, Inner);
        Result.Add('');
      end;
    finally
      Inner.Free;
    end;
  end;

  for I := 0 to Section.Content.Count - 1 do
  begin
    Part := RenderBlock(Section.Content[I]);
    try
      Result.AddStrings(Part);
    finally
      Part.Free;
    end;
  end;

  for I := 0 to Section.Sections.Count - 1 do
  begin
    Part := RenderSection(TSection(Section.Sections[I]), Depth + 1);
    try
      Result.AddStrings(Part);
    finally
      Part.Free;
    end;
  end;
end;

{ ===================== Блочные элементы ===================== }

function TFb2MarkdownWriter.RenderBlock(Block: TFb2Object): TTextList;
var
  Rendered: UnicodeString;
  Part: TTextList;
begin
  Result := TTextList.Create;
  if Block is TParagraph then
  begin
    Result.Add(RenderInline(TParagraph(Block).Content));
    Result.Add('');
  end
  else if Block is TSubtitle then
  begin
    Result.Add('**' + RenderInline(TSubtitle(Block).Content) + '**');
    Result.Add('');
  end
  else if Block is TEmptyLine then
    Result.Add('')
  else if Block is TPoem then
  begin
    Part := RenderPoem(TPoem(Block));
    try
      Result.AddStrings(Part);
    finally
      Part.Free;
    end;
    Result.Add('');
  end
  else if Block is TCite then
  begin
    Part := RenderCite(TCite(Block));
    try
      Result.AddStrings(Part);
    finally
      Part.Free;
    end;
  end
  else if Block is TTable then
  begin
    Part := RenderTable(TTable(Block));
    try
      Result.AddStrings(Part);
    finally
      Part.Free;
    end;
    Result.Add('');
  end
  else if Block is TImage then
  begin
    Rendered := RenderImage(TImage(Block).Href, TImage(Block).Alt);
    if Rendered <> '' then
    begin
      Result.Add(Rendered);
      Result.Add('');
    end;
  end;
end;

function TFb2MarkdownWriter.RenderAnnotation(Annotation: TAnnotation): TTextList;
var
  I, J: Integer;
  Part: TTextList;
  HasNonEmpty: Boolean;
begin
  Result := TTextList.Create;
  for I := 0 to Annotation.Items.Count - 1 do
  begin
    Part := RenderBlock(Annotation.Items[I]);
    try
      Result.AddStrings(Part);
    finally
      Part.Free;
    end;
  end;
  { Если есть непустые строки — убрать пустые (как в Python). }
  HasNonEmpty := False;
  for I := 0 to Result.Count - 1 do
    if Result[I] <> '' then
    begin
      HasNonEmpty := True;
      Break;
    end;
  if HasNonEmpty then
  begin
    J := 0;
    while J < Result.Count do
      if Result[J] = '' then
        Result.Delete(J)
      else
        Inc(J);
  end;
end;

function TFb2MarkdownWriter.RenderEpigraph(Epigraph: TEpigraph): TTextList;
var
  Inner: TTextList;
  Part: TTextList;
  I: Integer;
begin
  Result := TTextList.Create;
  Inner := TTextList.Create;
  try
    for I := 0 to Epigraph.Items.Count - 1 do
    begin
      Part := RenderBlock(Epigraph.Items[I]);
      try
        Inner.AddStrings(Part);
      finally
        Part.Free;
      end;
    end;
    for I := 0 to Epigraph.TextAuthor.Count - 1 do
      Inner.Add('— *' +
        RenderInline(TParagraph(Epigraph.TextAuthor[I]).Content) + '*');
    if Inner.Count = 0 then
      Exit;
    QuoteInto(Result, Inner);
    Result.Add('');
  finally
    Inner.Free;
  end;
end;

function TFb2MarkdownWriter.RenderCite(Cite: TCite): TTextList;
var
  Inner: TTextList;
  Part: TTextList;
  I: Integer;
begin
  Result := TTextList.Create;
  Inner := TTextList.Create;
  try
    for I := 0 to Cite.Items.Count - 1 do
    begin
      Part := RenderBlock(Cite.Items[I]);
      try
        Inner.AddStrings(Part);
      finally
        Part.Free;
      end;
    end;
    for I := 0 to Cite.TextAuthor.Count - 1 do
      Inner.Add('— *' + RenderInline(TParagraph(Cite.TextAuthor[I]).Content) + '*');
    if Inner.Count = 0 then
      Exit;
    QuoteInto(Result, Inner);
    Result.Add('');
  finally
    Inner.Free;
  end;
end;

function TFb2MarkdownWriter.RenderPoem(Poem: TPoem): TTextList;
var
  Title: UnicodeString;
  I: Integer;
  Part: TTextList;
begin
  Result := TTextList.Create;

  if Poem.Title <> nil then
  begin
    Title := TitleText(Poem.Title);
    if Title <> '' then
    begin
      Result.Add('**' + Title + '**');
      Result.Add('');
    end;
  end;

  if FIncludeEpigraphs then
    for I := 0 to Poem.Epigraphs.Count - 1 do
    begin
      Part := RenderEpigraph(TEpigraph(Poem.Epigraphs[I]));
      try
        Result.AddStrings(Part);
      finally
        Part.Free;
      end;
    end;

  for I := 0 to Poem.Items.Count - 1 do
  begin
    if Poem.Items[I] is TSubtitle then
    begin
      Result.Add('**' + RenderInline(TSubtitle(Poem.Items[I]).Content) + '**');
      Result.Add('');
    end
    else if Poem.Items[I] is TStanza then
    begin
      Part := RenderStanza(TStanza(Poem.Items[I]));
      try
        Result.AddStrings(Part);
      finally
        Part.Free;
      end;
    end;
  end;

  for I := 0 to Poem.TextAuthor.Count - 1 do
  begin
    Result.Add('*' + RenderInline(TParagraph(Poem.TextAuthor[I]).Content) + '*');
    Result.Add('');
  end;

  if (Poem.Date <> nil) and (Poem.Date.Value <> '') then
  begin
    Result.Add('*' + Poem.Date.Value + '*');
    Result.Add('');
  end;
end;

function TFb2MarkdownWriter.RenderStanza(Stanza: TStanza): TTextList;
var
  Title: UnicodeString;
  I: Integer;
begin
  Result := TTextList.Create;
  if Stanza.Title <> nil then
  begin
    Title := TitleText(Stanza.Title);
    if Title <> '' then
    begin
      Result.Add('**' + Title + '**');
      Result.Add('');
    end;
  end;
  if Stanza.Subtitle <> nil then
  begin
    Result.Add('**' + RenderInline(Stanza.Subtitle.Content) + '**');
    Result.Add('');
  end;
  for I := 0 to Stanza.Verses.Count - 1 do
    Result.Add(RenderInline(TParagraph(Stanza.Verses[I]).Content) + '  ');
  Result.Add('');
end;

function TFb2MarkdownWriter.RenderTable(Table: TTable): TTextList;
var
  Rows: array of TTextList;
  I, J, Width: Integer;
  Row: TTableRow;
  Line: UnicodeString;
begin
  Result := TTextList.Create;
  SetLength(Rows, Table.Rows.Count);
  Width := 0;
  for I := 0 to Table.Rows.Count - 1 do
  begin
    Row := TTableRow(Table.Rows[I]);
    Rows[I] := RenderTableRowCells(Row);
    if Rows[I].Count > Width then
      Width := Rows[I].Count;
  end;

  if Width = 0 then
  begin
    for I := 0 to Length(Rows) - 1 do
      Rows[I].Free;
    Exit;
  end;

  Line := '|';
  for J := 0 to Width - 1 do
  begin
    if J < Rows[0].Count then
      Line := Line + ' ' + Rows[0][J] + ' |'
    else
      Line := Line + '  |';
  end;
  Result.Add(Line);

  Line := '|';
  for J := 0 to Width - 1 do
    Line := Line + ' --- |';
  Result.Add(Line);

  for I := 1 to Length(Rows) - 1 do
  begin
    Line := '|';
    for J := 0 to Width - 1 do
    begin
      if J < Rows[I].Count then
        Line := Line + ' ' + Rows[I][J] + ' |'
      else
        Line := Line + '  |';
    end;
    Result.Add(Line);
  end;

  for I := 0 to Length(Rows) - 1 do
    Rows[I].Free;
end;

function TFb2MarkdownWriter.RenderTableRowCells(Row: TTableRow): TTextList;
var
  I: Integer;
begin
  Result := TTextList.Create;
  for I := 0 to Row.Cells.Count - 1 do
    Result.Add(RenderTableCell(TTableCell(Row.Cells[I])));
end;

function TFb2MarkdownWriter.RenderTableCell(Cell: TTableCell): UnicodeString;
begin
  Result := RenderInline(Cell.Children);
  Result := UReplace(Result, '|', '\|');
  Result := UReplace(Result, #10, ' ');
end;

{ ===================== Inline-разметка ===================== }

function TFb2MarkdownWriter.RenderInline(Nodes: TFb2ObjectList): UnicodeString;
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
      Result := Result + Escape(Node.Text)
    else if Node.Tag = 'strong' then
      Result := Result + '**' + RenderInline(Node.Children) + '**'
    else if Node.Tag = 'emphasis' then
      Result := Result + '*' + RenderInline(Node.Children) + '*'
    else if Node.Tag = 'strikethrough' then
      Result := Result + '~~' + RenderInline(Node.Children) + '~~'
    else if Node.Tag = 'code' then
      Result := Result + '`' + RenderInline(Node.Children) + '`'
    else if Node.Tag = 'sub' then
      Result := Result + '<sub>' + RenderInline(Node.Children) + '</sub>'
    else if Node.Tag = 'sup' then
      Result := Result + '<sup>' + RenderInline(Node.Children) + '</sup>'
    else if Node.Tag = 'a' then
      Result := Result + RenderLink(Node)
    else if Node.Tag = 'image' then
      Result := Result + RenderImage(Node.ImageHref, Node.ImageAlt)
    else
      Result := Result + RenderInline(Node.Children);
  end;
end;

function TFb2MarkdownWriter.RenderLink(Node: TStyleNode): UnicodeString;
var
  Txt: UnicodeString;
begin
  Txt := RenderInline(Node.Children);
  if Txt = '' then
    Txt := Escape(Node.Href);
  if Node.Href <> '' then
    Result := '[' + Txt + '](' + Node.Href + ')'
  else
    Result := Txt;
end;

function TFb2MarkdownWriter.RenderImage(Href, Alt: UnicodeString): UnicodeString;
var
  Link: UnicodeString;
begin
  Link := ImageLink(Href);
  if Link = '' then
    Exit('');
  Result := '![' + Escape(Alt) + '](' + Link + ')';
end;

function TFb2MarkdownWriter.ImageLink(Href: UnicodeString): UnicodeString;
var
  ImageId, Filename: UnicodeString;
begin
  Result := '';
  if Href = '' then
    Exit;
  if Copy(Href, 1, 1) = '#' then
    ImageId := Copy(Href, 2, Length(Href) - 1)
  else
    ImageId := Href;
  Filename := FImageFiles.Values[ImageId];
  if Filename = '' then
    Filename := ExtractFileName(ImageId);
  if FImageDir <> '' then
    Result := FImageDir + '/' + Filename
  else
    Result := Filename;
end;

{ ===================== Утилиты ===================== }

function TFb2MarkdownWriter.TitleText(Title: TTitle): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
begin
  Result := '';
  if Title = nil then
    Exit;
  Parts := TTextList.Create;
  try
    for I := 0 to Title.Items.Count - 1 do
      if Title.Items[I] is TParagraph then
        Parts.Add(RenderInline(TParagraph(Title.Items[I]).Content));
    Result := JoinNonEmpty(Parts, ' ');
  finally
    Parts.Free;
  end;
end;

function TFb2MarkdownWriter.Escape(const S: UnicodeString): UnicodeString;
var
  I: Integer;
begin
  if (S = '') or (not FEscapeText) then
  begin
    Result := S;
    Exit;
  end;
  Result := '';
  for I := 1 to Length(S) do
  begin
    if IsMdSpecial(S[I]) then
      Result := Result + '\';
    Result := Result + S[I];
  end;
end;

function TFb2MarkdownWriter.Finalize(Lines: TTextList): UnicodeString;
var
  OutLines: TTextList;
  Blank, I: Integer;
  Line: UnicodeString;
begin
  OutLines := TTextList.Create;
  try
    Blank := 0;
    for I := 0 to Lines.Count - 1 do
    begin
      Line := UTrimRight(Lines[I]);
      if Line = '' then
      begin
        Inc(Blank);
        if Blank > 1 then
          Continue;
      end
      else
        Blank := 0;
      OutLines.Add(Line);
    end;

    while (OutLines.Count > 0) and (UTrim(OutLines[0]) = '') do
      OutLines.Delete(0);
    while (OutLines.Count > 0) and
      (UTrim(OutLines[OutLines.Count - 1]) = '') do
      OutLines.Delete(OutLines.Count - 1);

    Result := JoinText(OutLines, #10) + #10;
  finally
    OutLines.Free;
  end;
end;

end.