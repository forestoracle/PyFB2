unit fb2_to_fb3;
{ Преобразование книги FB2 в FictionBook 3 (FB3) — перевод fb2_to_fb3.py.

  FB3 — это OPC-контейнер (ZIP) с частями Open XML:

      [Content_Types].xml                     типы частей
      _rels/.rels                             связи пакета (описание, метаданные)
      fb3/description.xml                     <fb3-description> (метаданные)
      fb3/body.xml                            <fb3-body> (текст)
      fb3/meta/core.xml                       Dublin Core свойства
      fb3/_rels/description.xml.rels          связь описания с телом
      fb3/_rels/body.xml.rels                 связи тела с изображениями
      fb3/img/*                               изображения

  Пространства имён: http://www.fictionbook.org/FictionBook3/description
  (описание) и .../body (текст). Идентификаторы секций и субъектов — UUID.

  Промежуточное представление — TFb3Document (метаданные + готовые XML-части +
  изображения); сериализуется в байты (ToBytes) или пишется в файл (Write).
  Обратное преобразование — fb3_to_fb2.pas.

  Пример:
      C := TFb2ToFb3Converter.Create;
      try
        C.Write('book.fb2', 'book.fb3');
      finally
        C.Free;
      end;

  Особенности перевода с Python:
      * ZIP пишется через TZipper (paszlib); порядок записей как в Python;
      * html.escape -> XmlEscape. }

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Classes, SysUtils, fgl,
  fb2_structures, fb2_parser, fb2_errors, fb2_images, fb2_files;

const
  { Пространства имён FB3. }
  NS_DESCR = 'http://www.fictionbook.org/FictionBook3/description';
  NS_BODY = 'http://www.fictionbook.org/FictionBook3/body';
  NS_XLINK = 'http://www.w3.org/1999/xlink';
  NS_CONTENT_TYPES = 'http://schemas.openxmlformats.org/package/2006/content-types';
  NS_RELS = 'http://schemas.openxmlformats.org/package/2006/relationships';
  NS_CORE = 'http://schemas.openxmlformats.org/package/2006/metadata/core-properties';
  NS_DC = 'http://purl.org/dc/elements/1.1/';
  NS_DCTERMS = 'http://purl.org/dc/terms/';

  { Типы связей FB3. }
  REL_BOOK = 'http://www.fictionbook.org/FictionBook3/relationships/Book';
  REL_BODY = 'http://www.fictionbook.org/FictionBook3/relationships/body';
  REL_IMAGE = 'http://www.fictionbook.org/FictionBook3/relationships/image';
  REL_THUMBNAIL =
    'http://schemas.openxmlformats.org/package/2006/relationships/metadata/thumbnail';
  REL_CORE =
    'http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties';

  { Типы частей FB3. }
  CT_DESCRIPTION = 'application/fb3-description+xml';
  CT_BODY = 'application/fb3-body+xml';
  CT_CORE = 'application/vnd.openxmlformats-package.core-properties+xml';
  CT_RELS = 'application/vnd.openxmlformats-package.relationships+xml';

type
  { Изображение контейнера FB3 (fb3/img/...). }
  TFb3Image = class
  public
    RelId: UnicodeString;
    FileName: UnicodeString;
    MediaType: UnicodeString;
    Data: TBytes;
  end;

  TFb3ImageList = specialize TFPGObjectList<TFb3Image>;

  { Промежуточное представление документа FB3. }
  TFb3Document = class
  public
    Identifier: UnicodeString;
    DescriptionXml: UnicodeString;
    BodyXml: UnicodeString;
    CoreXml: UnicodeString;
    Images: TFb3ImageList;
    Cover: UnicodeString;          { имя файла обложки ('' — нет) }
    constructor Create;
    destructor Destroy; override;
  end;

  { Преобразование книги FB2 в контейнер FB3. }
  TFb2ToFb3Converter = class
  private
    FParser: TFb2Parser;
    FSource: UnicodeString;
    FDoc: TFb3Document;
    FImages: TFb3ImageList;
    FImageIds: TStringList;        { id FB2 -> rel_id }
    FRelCounter: Integer;
    FTitle: UnicodeString;
    FCreators: TTextList;
    FGenres: TTextList;
    FLanguage: UnicodeString;
    FAnnotation: TTextList;

    procedure Reset;
    procedure ReadMetadata(TI: TTitleInfo);
    procedure CollectImages(Binaries: TFb2ObjectList);
    function ImageRel(const Href: UnicodeString): UnicodeString;
    function CoverName(TI: TTitleInfo): UnicodeString;

    function RenderBody(Bodies: TFb2ObjectList): UnicodeString;
    function RenderSection(Section: TSection): UnicodeString;
    function RenderTitle(Title: TTitle): UnicodeString;
    function RenderEpigraph(E: TEpigraph): UnicodeString;
    function RenderAnnotation(A: TAnnotation): UnicodeString;
    function RenderBlock(Block: TFb2Object): UnicodeString;
    function Paragraph(Nodes: TFb2ObjectList): UnicodeString;
    function RenderImageParagraph(Img: TImage): UnicodeString;
    function RenderPoem(P: TPoem): UnicodeString;
    function RenderStanza(S: TStanza): UnicodeString;
    function RenderCite(C: TCite): UnicodeString;
    function RenderTable(T: TTable): UnicodeString;
    function RenderMarkup(Nodes: TFb2ObjectList): UnicodeString;
    function Link(Node: TStyleNode): UnicodeString;

    function DescriptionXml(const Identifier: UnicodeString;
      DI: TDocumentInfo): UnicodeString;
    function SubjectXml(const Name: UnicodeString): UnicodeString;
    function DocumentDate(DI: TDocumentInfo): UnicodeString;
    function CoreXml: UnicodeString;
    function ContentTypes: UnicodeString;
    function PackageRels(Doc: TFb3Document): UnicodeString;
    function DescriptionRels: UnicodeString;
    function BodyRels(Doc: TFb3Document): UnicodeString;
  public
    constructor Create(AParser: TFb2Parser = nil);
    destructor Destroy; override;

    { Прочитать FB2 и вернуть структуру TFb3Document (владелец — конвертер). }
    function Convert(const Source: UnicodeString = ''): TFb3Document;

    { Сериализовать документ в FB3 (ZIP). Doc = nil — результат Convert. }
    function ToBytes(Doc: TFb3Document = nil): TBytes;

    { Преобразовать FB2 в файл FB3 и вернуть путь к результату. }
    function Write(const Source: UnicodeString;
      const Output: UnicodeString = ''): UnicodeString;

    property Document: TFb3Document read FDoc;
  end;

{ Экранирование XML (аналог html.escape с quote=True). }
function XmlEscape(const S: UnicodeString): UnicodeString;

implementation

uses
  zipper;

{ ===================== Служебные помощники ===================== }

function XmlEscape(const S: UnicodeString): UnicodeString;
var
  I: Integer;
  C: WideChar;
begin
  Result := '';
  for I := 1 to Length(S) do
  begin
    C := S[I];
    if C = '&' then
      Result := Result + '&amp;'
    else if C = '<' then
      Result := Result + '&lt;'
    else if C = '>' then
      Result := Result + '&gt;'
    else if C = '"' then
      Result := Result + '&quot;'
    else if C = '''' then
      Result := Result + '&#x27;'
    else
      Result := Result + C;
  end;
end;

{ Простой текст из узлов разметки (аналог _markup_text). }
function MarkupPlain(Nodes: TFb2ObjectList): UnicodeString;
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
      Result := Result + MarkupPlain(Node.Children);
  end;
end;

{ Имя автора: «Имя Отчество Фамилия» либо никнейм. }
function AuthorTextOf(A: TAuthor): UnicodeString;
var
  Parts: TTextList;
begin
  Result := '';
  if A = nil then
    Exit;
  Parts := TTextList.Create;
  try
    if UTrim(A.FirstName) <> '' then
      Parts.Add(UTrim(A.FirstName));
    if UTrim(A.MiddleName) <> '' then
      Parts.Add(UTrim(A.MiddleName));
    if UTrim(A.LastName) <> '' then
      Parts.Add(UTrim(A.LastName));
    Result := JoinText(Parts, ' ');
  finally
    Parts.Free;
  end;
  if Result = '' then
    Result := UTrim(A.Nickname);
end;

{ Новый UUID в нижнем регистре, как uuid.uuid4() (с дефисами). }
function NewUuid: UnicodeString;
var
  G: TGUID;
begin
  CreateGUID(G);
  Result := LowerCase(GUIDToString(G));
  if (Length(Result) >= 2) and (Result[1] = '{') then
    Result := Copy(Result, 2, Length(Result) - 2);
end;

{ Новый UUID без дефисов, как uuid.uuid4().hex. }
function NewUuidHex: UnicodeString;
var
  S: UnicodeString;
  I: Integer;
begin
  S := NewUuid;
  Result := '';
  for I := 1 to Length(S) do
    if S[I] <> '-' then
      Result := Result + S[I];
end;

{ Сегодняшняя дата в формате ISO (date.today().isoformat()). }
function TodayIso: UnicodeString;
begin
  Result := FormatDateTime('yyyy-mm-dd', Now);
end;

{ Получить значение карты "ключ=значение" по имени ключа. }
function MapGet(L: TStringList; const Key: UnicodeString): UnicodeString;
var
  I: Integer;
begin
  I := L.IndexOfName(Key);
  if I >= 0 then
    Result := L.ValueFromIndex[I]
  else
    Result := '';
end;

{ Записать значение в карту "ключ=значение". }
procedure MapSet(L: TStringList; const Key, Value: UnicodeString);
var
  I: Integer;
begin
  I := L.IndexOfName(Key);
  if I >= 0 then
    L[I] := Key + '=' + Value
  else
    L.Add(Key + '=' + Value);
end;

{ Объединить части списка; пустые части можно пропускать. }
function JoinParts(Parts: TTextList; const Sep: UnicodeString;
  SkipEmpty: Boolean): UnicodeString;
var
  I: Integer;
  First: Boolean;
begin
  Result := '';
  First := True;
  for I := 0 to Parts.Count - 1 do
  begin
    if SkipEmpty and (Parts[I] = '') then
      Continue;
    if not First then
      Result := Result + Sep;
    Result := Result + Parts[I];
    First := False;
  end;
end;

{ ===================== ZIP: добавление записей ===================== }

procedure AddTextEntry(Z: TZipper; const Name, Text: UnicodeString);
var
  MS: TMemoryStream;
  B: TBytes;
begin
  B := TEncoding.UTF8.GetBytes(Text);
  MS := TMemoryStream.Create;
  if Length(B) > 0 then
    MS.WriteBuffer(B[0], Length(B));
  MS.Position := 0;
  Z.Entries.AddFileEntry(MS, Name);
end;

procedure AddDataEntry(Z: TZipper; const Name: UnicodeString;
  const Data: TBytes);
var
  MS: TMemoryStream;
begin
  MS := TMemoryStream.Create;
  if Length(Data) > 0 then
    MS.WriteBuffer(Data[0], Length(Data));
  MS.Position := 0;
  Z.Entries.AddFileEntry(MS, Name);
end;

{ ===================== TFb3Document ===================== }

constructor TFb3Document.Create;
begin
  inherited Create;
  Images := TFb3ImageList.Create(True);
end;

destructor TFb3Document.Destroy;
begin
  FreeAndNil(Images);
  inherited Destroy;
end;

{ ===================== TFb2ToFb3Converter ===================== }

constructor TFb2ToFb3Converter.Create(AParser: TFb2Parser);
begin
  inherited Create;
  if AParser <> nil then
    FParser := AParser
  else
    FParser := TFb2Parser.Create;
  FSource := '';
  FDoc := nil;
  FImages := nil;
  FImageIds := TStringList.Create;
  FImageIds.CaseSensitive := True;
  FImageIds.NameValueSeparator := '=';
  Reset;
end;

destructor TFb2ToFb3Converter.Destroy;
begin
  FreeAndNil(FDoc);
  FreeAndNil(FImages);
  FreeAndNil(FCreators);
  FreeAndNil(FGenres);
  FreeAndNil(FAnnotation);
  FreeAndNil(FImageIds);
  FreeAndNil(FParser);
  inherited Destroy;
end;

procedure TFb2ToFb3Converter.Reset;
begin
  FreeAndNil(FImages);
  FImages := TFb3ImageList.Create(True);
  FImageIds.Clear;
  FRelCounter := 0;
  FTitle := 'Untitled';
  FreeAndNil(FCreators);
  FCreators := TTextList.Create;
  FreeAndNil(FGenres);
  FGenres := TTextList.Create;
  FLanguage := 'ru';
  FreeAndNil(FAnnotation);
  FAnnotation := TTextList.Create;
end;

procedure TFb2ToFb3Converter.ReadMetadata(TI: TTitleInfo);
var
  I: Integer;
  S: UnicodeString;
  Item: TFb2Object;
begin
  if TI = nil then
    Exit;
  if (TI.BookTitle <> nil) and (TI.BookTitle.Value <> '') then
    FTitle := TI.BookTitle.Value;
  FCreators.Clear;
  for I := 0 to TI.Authors.Count - 1 do
  begin
    S := AuthorTextOf(TAuthor(TI.Authors[I]));
    if S <> '' then
      FCreators.Add(S);
  end;
  FGenres.Clear;
  for I := 0 to TI.Genres.Count - 1 do
    if TGenre(TI.Genres[I]).Value <> '' then
      FGenres.Add(TGenre(TI.Genres[I]).Value);
  if TI.Lang <> '' then
    FLanguage := TI.Lang;
  if TI.Annotation <> nil then
  begin
    FAnnotation.Clear;
    for I := 0 to TI.Annotation.Items.Count - 1 do
    begin
      Item := TI.Annotation.Items[I];
      if Item is TParagraph then
        S := MarkupPlain(TParagraph(Item).Content)
      else if Item is TSubtitle then
        S := MarkupPlain(TSubtitle(Item).Content)
      else
        S := '';
      if S <> '' then
        FAnnotation.Add(S);
    end;
  end;
end;

procedure TFb2ToFb3Converter.CollectImages(Binaries: TFb2ObjectList);
var
  I: Integer;
  Bin: TBinary;
  Data: TBytes;
  Ext, MediaType, RawId, Base, FileName, RelId, Key: UnicodeString;
  Img: TFb3Image;
begin
  if Binaries = nil then
    Exit;
  for I := 0 to Binaries.Count - 1 do
  begin
    Bin := TBinary(Binaries[I]);
    if (Bin.ContentType <> '') and
      (Copy(LowerCase(Bin.ContentType), 1, 9) = 'image/svg') then
      Continue;
    try
      Data := Base64DecodeString(Bin.Data);
    except
      Continue;
    end;
    if Length(Data) = 0 then
      Continue;
    MediaType := DetectImageType(Data, Ext);
    RawId := Bin.Id;
    if RawId = '' then
      RawId := 'image';
    if Pos('.', RawId) > 0 then
      Base := ChangeFileExt(ExtractFileName(RawId), '')
    else
      Base := RawId;
    if Base = '' then
      Base := 'image';
    FileName := Base + Ext;

    Inc(FRelCounter);
    RelId := 'img' + IntToStr(FRelCounter);
    Img := TFb3Image.Create;
    Img.RelId := RelId;
    Img.FileName := FileName;
    Img.MediaType := MediaType;
    Img.Data := Data;
    FImages.Add(Img);

    Key := RawId;
    while (Key <> '') and (Key[1] = '#') do
      Delete(Key, 1, 1);
    MapSet(FImageIds, Key, RelId);
  end;
end;

function TFb2ToFb3Converter.ImageRel(const Href: UnicodeString): UnicodeString;
var
  Key: UnicodeString;
begin
  Result := '';
  if Href = '' then
    Exit;
  Key := Href;
  while (Key <> '') and (Key[1] = '#') do
    Delete(Key, 1, 1);
  Result := MapGet(FImageIds, Key);
end;

function TFb2ToFb3Converter.CoverName(TI: TTitleInfo): UnicodeString;
var
  I, J: Integer;
  RelId: UnicodeString;
begin
  Result := '';
  if (TI = nil) or (TI.Coverpage = nil) then
    Exit;
  for I := 0 to TI.Coverpage.Images.Count - 1 do
  begin
    RelId := ImageRel(TImage(TI.Coverpage.Images[I]).Href);
    if RelId <> '' then
      for J := 0 to FImages.Count - 1 do
        if FImages[J].RelId = RelId then
          Exit(FImages[J].FileName);
  end;
end;

{ ===================== Рендер тела ===================== }

function TFb2ToFb3Converter.RenderBody(Bodies: TFb2ObjectList): UnicodeString;
var
  Parts: TTextList;
  I, J: Integer;
  Body: TBody;
  Inner: UnicodeString;
begin
  Parts := TTextList.Create;
  try
    if Bodies <> nil then
      for I := 0 to Bodies.Count - 1 do
      begin
        Body := TBody(Bodies[I]);
        if Body.Title <> nil then
          Parts.Add(RenderTitle(Body.Title));
        for J := 0 to Body.Epigraphs.Count - 1 do
          Parts.Add(RenderEpigraph(TEpigraph(Body.Epigraphs[J])));
        if Body.Image <> nil then
          Parts.Add(RenderImageParagraph(Body.Image));
        for J := 0 to Body.Sections.Count - 1 do
          Parts.Add(RenderSection(TSection(Body.Sections[J])));
      end;
    Inner := JoinParts(Parts, #10, True);
    Result :=
      '<?xml version="1.0" encoding="UTF-8"?>' + #10 +
      '<fb3-body xmlns="' + NS_BODY + '" xmlns:xlink="' + NS_XLINK +
      '" id="' + NewUuid + '">' + #10 + Inner + #10 + '</fb3-body>' + #10;
  finally
    Parts.Free;
  end;
end;

function TFb2ToFb3Converter.RenderSection(Section: TSection): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
begin
  Parts := TTextList.Create;
  try
    Parts.Add('<section id="' + NewUuid + '">');
    if Section.Title <> nil then
      Parts.Add(RenderTitle(Section.Title));
    for I := 0 to Section.Epigraphs.Count - 1 do
      Parts.Add(RenderEpigraph(TEpigraph(Section.Epigraphs[I])));
    if Section.Annotation <> nil then
      Parts.Add(RenderAnnotation(Section.Annotation));
    if Section.Image <> nil then
      Parts.Add(RenderImageParagraph(Section.Image));
    for I := 0 to Section.Content.Count - 1 do
      Parts.Add(RenderBlock(TFb2Object(Section.Content[I])));
    for I := 0 to Section.Sections.Count - 1 do
      Parts.Add(RenderSection(TSection(Section.Sections[I])));
    Parts.Add('</section>');
    Result := JoinParts(Parts, #10, True);
  finally
    Parts.Free;
  end;
end;

function TFb2ToFb3Converter.RenderTitle(Title: TTitle): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
  Item: TFb2Object;
begin
  Result := '';
  Parts := TTextList.Create;
  try
    for I := 0 to Title.Items.Count - 1 do
    begin
      Item := Title.Items[I];
      if Item is TParagraph then
        Parts.Add(Paragraph(TParagraph(Item).Content));
    end;
    if Parts.Count > 0 then
      Result := '<title>' + JoinParts(Parts, '', False) + '</title>';
  finally
    Parts.Free;
  end;
end;

function TFb2ToFb3Converter.RenderEpigraph(E: TEpigraph): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
  Inner: UnicodeString;
begin
  Result := '';
  Parts := TTextList.Create;
  try
    for I := 0 to E.Items.Count - 1 do
      Parts.Add(RenderBlock(TFb2Object(E.Items[I])));
    for I := 0 to E.TextAuthor.Count - 1 do
      Parts.Add('<subscription>' +
        Paragraph(TParagraph(E.TextAuthor[I]).Content) + '</subscription>');
    Inner := JoinParts(Parts, '', True);
    if Inner <> '' then
      Result := '<epigraph>' + Inner + '</epigraph>';
  finally
    Parts.Free;
  end;
end;

function TFb2ToFb3Converter.RenderAnnotation(A: TAnnotation): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
  Inner: UnicodeString;
begin
  Result := '';
  Parts := TTextList.Create;
  try
    for I := 0 to A.Items.Count - 1 do
      Parts.Add(RenderBlock(TFb2Object(A.Items[I])));
    Inner := JoinParts(Parts, '', True);
    if Inner <> '' then
      Result := '<annotation>' + Inner + '</annotation>';
  finally
    Parts.Free;
  end;
end;

function TFb2ToFb3Converter.RenderBlock(Block: TFb2Object): UnicodeString;
begin
  if Block is TParagraph then
    Result := Paragraph(TParagraph(Block).Content)
  else if Block is TSubtitle then
    Result := Paragraph(TSubtitle(Block).Content)
  else if Block is TEmptyLine then
    Result := '<br/>'
  else if Block is TPoem then
    Result := RenderPoem(TPoem(Block))
  else if Block is TCite then
    Result := RenderCite(TCite(Block))
  else if Block is TTable then
    Result := RenderTable(TTable(Block))
  else if Block is TImage then
    Result := RenderImageParagraph(TImage(Block))
  else if Block is TEpigraph then
    Result := RenderEpigraph(TEpigraph(Block))
  else
    Result := '';
end;

function TFb2ToFb3Converter.Paragraph(Nodes: TFb2ObjectList): UnicodeString;
begin
  Result := '<p>' + RenderMarkup(Nodes) + '</p>';
end;

function TFb2ToFb3Converter.RenderImageParagraph(Img: TImage): UnicodeString;
var
  RelId: UnicodeString;
begin
  RelId := ImageRel(Img.Href);
  if RelId = '' then
    Result := ''
  else
    Result := '<p><img src="' + RelId + '"/></p>';
end;

function TFb2ToFb3Converter.RenderPoem(P: TPoem): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
  Item: TFb2Object;
  Inner: UnicodeString;
begin
  Result := '';
  Parts := TTextList.Create;
  try
    if P.Title <> nil then
      Parts.Add(RenderTitle(P.Title));
    for I := 0 to P.Epigraphs.Count - 1 do
      Parts.Add(RenderEpigraph(TEpigraph(P.Epigraphs[I])));
    for I := 0 to P.Items.Count - 1 do
    begin
      Item := P.Items[I];
      if Item is TStanza then
        Parts.Add(RenderStanza(TStanza(Item)))
      else if Item is TSubtitle then
        Parts.Add(Paragraph(TSubtitle(Item).Content));
    end;
    for I := 0 to P.TextAuthor.Count - 1 do
      Parts.Add('<subscription>' +
        Paragraph(TParagraph(P.TextAuthor[I]).Content) + '</subscription>');
    Inner := JoinParts(Parts, '', True);
    if Inner <> '' then
      Result := '<poem>' + Inner + '</poem>';
  finally
    Parts.Free;
  end;
end;

function TFb2ToFb3Converter.RenderStanza(S: TStanza): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
begin
  Result := '';
  Parts := TTextList.Create;
  try
    if S.Subtitle <> nil then
      Parts.Add(Paragraph(S.Subtitle.Content));
    for I := 0 to S.Verses.Count - 1 do
      Parts.Add(Paragraph(TParagraph(S.Verses[I]).Content));
    if Parts.Count > 0 then
      Result := '<stanza>' + JoinParts(Parts, '', False) + '</stanza>';
  finally
    Parts.Free;
  end;
end;

function TFb2ToFb3Converter.RenderCite(C: TCite): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
  Inner: UnicodeString;
begin
  Result := '';
  Parts := TTextList.Create;
  try
    for I := 0 to C.Items.Count - 1 do
      Parts.Add(RenderBlock(TFb2Object(C.Items[I])));
    for I := 0 to C.TextAuthor.Count - 1 do
      Parts.Add('<subscription>' +
        Paragraph(TParagraph(C.TextAuthor[I]).Content) + '</subscription>');
    Inner := JoinParts(Parts, '', True);
    if Inner <> '' then
      Result := '<blockquote>' + Inner + '</blockquote>';
  finally
    Parts.Free;
  end;
end;

function TFb2ToFb3Converter.RenderTable(T: TTable): UnicodeString;
var
  Rows, Cells: TTextList;
  I, J: Integer;
  Row: TTableRow;
  Cell: TTableCell;
  Tag: UnicodeString;
begin
  Result := '';
  Rows := TTextList.Create;
  try
    for I := 0 to T.Rows.Count - 1 do
    begin
      Row := TTableRow(T.Rows[I]);
      Cells := TTextList.Create;
      try
        for J := 0 to Row.Cells.Count - 1 do
        begin
          Cell := TTableCell(Row.Cells[J]);
          if Cell.IsHeader then
            Tag := 'th'
          else
            Tag := 'td';
          Cells.Add('<' + Tag + '><p>' + RenderMarkup(Cell.Children) +
            '</p></' + Tag + '>');
        end;
        Rows.Add('<tr>' + JoinParts(Cells, '', False) + '</tr>');
      finally
        Cells.Free;
      end;
    end;
    if Rows.Count > 0 then
      Result := '<table>' + JoinParts(Rows, '', False) + '</table>';
  finally
    Rows.Free;
  end;
end;

function TFb2ToFb3Converter.RenderMarkup(Nodes: TFb2ObjectList): UnicodeString;
var
  I: Integer;
  Node: TStyleNode;
  Tag, Href, RelId, ClassAttr: UnicodeString;
begin
  Result := '';
  if Nodes = nil then
    Exit;
  for I := 0 to Nodes.Count - 1 do
  begin
    Node := TStyleNode(Nodes[I]);
    Tag := Node.Tag;
    if Tag = TEXT_NODE_NAME then
      Result := Result + XmlEscape(Node.Text)
    else if Tag = 'a' then
      Result := Result + Link(Node)
    else if Tag = 'image' then
    begin
      Href := Node.ImageHref;
      if Href = '' then
        Href := Node.Href;
      RelId := ImageRel(Href);
      if RelId <> '' then
        Result := Result + '<img src="' + RelId + '"/>';
    end
    else if Tag = 'strong' then
      Result := Result + '<strong>' + RenderMarkup(Node.Children) + '</strong>'
    else if Tag = 'emphasis' then
      Result := Result + '<em>' + RenderMarkup(Node.Children) + '</em>'
    else if Tag = 'code' then
      Result := Result + '<code>' + RenderMarkup(Node.Children) + '</code>'
    else if Tag = 'strikethrough' then
      Result := Result + '<strikethrough>' + RenderMarkup(Node.Children) +
        '</strikethrough>'
    else if Tag = 'sub' then
      Result := Result + '<sub>' + RenderMarkup(Node.Children) + '</sub>'
    else if Tag = 'sup' then
      Result := Result + '<sup>' + RenderMarkup(Node.Children) + '</sup>'
    else if Tag = 'style' then
    begin
      ClassAttr := '';
      if Node.StyleName <> '' then
        ClassAttr := ' class="' + XmlEscape(Node.StyleName) + '"';
      Result := Result + '<span' + ClassAttr + '>' +
        RenderMarkup(Node.Children) + '</span>';
    end
    else
      Result := Result + RenderMarkup(Node.Children);
  end;
end;

function TFb2ToFb3Converter.Link(Node: TStyleNode): UnicodeString;
var
  Inner: UnicodeString;
begin
  Inner := RenderMarkup(Node.Children);
  if Node.Href = '' then
    Result := Inner
  else
    Result := '<a xlink:href="' + XmlEscape(Node.Href) + '">' + Inner + '</a>';
end;

{ ===================== Файлы контейнера ===================== }

{ Разбить строку по пробельным символам (аналог str.split()). }
function SplitWords(const S: UnicodeString): TTextList;
var
  I: Integer;
  Cur: UnicodeString;
begin
  Result := TTextList.Create;
  Cur := '';
  for I := 1 to Length(S) do
  begin
    if Ord(S[I]) <= 32 then
    begin
      if Cur <> '' then
      begin
        Result.Add(Cur);
        Cur := '';
      end;
    end
    else
      Cur := Cur + S[I];
  end;
  if Cur <> '' then
    Result.Add(Cur);
end;

function TFb2ToFb3Converter.SubjectXml(const Name: UnicodeString): UnicodeString;
var
  Words, Body: TTextList;
  First, Middle, Last: UnicodeString;
  I: Integer;
begin
  Words := SplitWords(Name);
  try
    if Words.Count = 1 then
    begin
      First := '';
      Middle := '';
      Last := Words[0];
    end
    else if Words.Count = 0 then
    begin
      First := '';
      Middle := '';
      Last := '';
    end
    else
    begin
      First := Words[0];
      Last := Words[Words.Count - 1];
      Middle := '';
      for I := 1 to Words.Count - 2 do
      begin
        if I > 1 then
          Middle := Middle + ' ';
        Middle := Middle + Words[I];
      end;
    end;
  finally
    Words.Free;
  end;

  Body := TTextList.Create;
  try
    Body.Add('<title><main>' + XmlEscape(Name) + '</main></title>');
    if First <> '' then
      Body.Add('<first-name>' + XmlEscape(First) + '</first-name>');
    if Middle <> '' then
      Body.Add('<middle-name>' + XmlEscape(Middle) + '</middle-name>');
    if Last <> '' then
      Body.Add('<last-name>' + XmlEscape(Last) + '</last-name>');
    Result := '<subject link="author" id="' + NewUuid + '">' +
      JoinText(Body, '') + '</subject>';
  finally
    Body.Free;
  end;
end;

function TFb2ToFb3Converter.DocumentDate(DI: TDocumentInfo): UnicodeString;
var
  V: UnicodeString;
begin
  if (DI <> nil) and (DI.Date <> nil) then
  begin
    V := DI.Date.DateValue;
    if V = '' then
      V := DI.Date.Value;
    if V <> '' then
      Exit(V);
  end;
  Result := TodayIso;
end;

function TFb2ToFb3Converter.DescriptionXml(const Identifier: UnicodeString;
  DI: TDocumentInfo): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
  Created: UnicodeString;
begin
  Parts := TTextList.Create;
  try
    Parts.Add('<?xml version="1.0" encoding="UTF-8"?>');
    Parts.Add('<fb3-description xmlns="' + NS_DESCR + '" xmlns:xlink="' +
      NS_XLINK + '" id="' + Identifier + '" version="1.0">');
    Parts.Add('<title><main>' + XmlEscape(FTitle) + '</main></title>');
    if FCreators.Count > 0 then
    begin
      Parts.Add('<fb3-relations>');
      for I := 0 to FCreators.Count - 1 do
        Parts.Add(SubjectXml(FCreators[I]));
      Parts.Add('</fb3-relations>');
    end;
    if FGenres.Count > 0 then
    begin
      Parts.Add('<fb3-classification>');
      for I := 0 to FGenres.Count - 1 do
        Parts.Add('<subject>' + XmlEscape(FGenres[I]) + '</subject>');
      Parts.Add('</fb3-classification>');
    end;
    Parts.Add('<lang>' + XmlEscape(FLanguage) + '</lang>');
    Created := DocumentDate(DI);
    Parts.Add('<document-info created="' + Created + '" updated="' +
      Created + '"/>');
    if FAnnotation.Count > 0 then
    begin
      Parts.Add('<annotation>');
      for I := 0 to FAnnotation.Count - 1 do
        Parts.Add('<p>' + XmlEscape(FAnnotation[I]) + '</p>');
      Parts.Add('</annotation>');
    end;
    Parts.Add('</fb3-description>');
    Result := JoinText(Parts, #10) + #10;
  finally
    Parts.Free;
  end;
end;

function TFb2ToFb3Converter.CoreXml: UnicodeString;
var
  Parts: TTextList;
  I: Integer;
begin
  Parts := TTextList.Create;
  try
    Parts.Add('<?xml version="1.0" encoding="UTF-8"?>');
    Parts.Add('<cp:coreProperties xmlns:cp="' + NS_CORE + '" xmlns:dc="' +
      NS_DC + '" xmlns:dcterms="' + NS_DCTERMS + '">');
    Parts.Add('<dc:title>' + XmlEscape(FTitle) + '</dc:title>');
    for I := 0 to FCreators.Count - 1 do
      Parts.Add('<dc:creator>' + XmlEscape(FCreators[I]) + '</dc:creator>');
    if FAnnotation.Count > 0 then
      Parts.Add('<dc:description>' +
        XmlEscape(JoinText(FAnnotation, #10)) + '</dc:description>');
    Parts.Add('<dc:language>' + XmlEscape(FLanguage) + '</dc:language>');
    Parts.Add('<dcterms:created>' + TodayIso + '</dcterms:created>');
    Parts.Add('</cp:coreProperties>');
    Result := JoinText(Parts, #10) + #10;
  finally
    Parts.Free;
  end;
end;

function TFb2ToFb3Converter.ContentTypes: UnicodeString;
const
  DEF_EXT: array[0..7] of UnicodeString =
    ('rels', 'png', 'jpg', 'jpeg', 'gif', 'svg', 'xml', 'css');
  DEF_CT: array[0..7] of UnicodeString =
    (CT_RELS, 'image/png', 'image/jpeg', 'image/jpeg', 'image/gif',
     'image/svg+xml', 'application/xml', 'text/css');
var
  Parts: TTextList;
  I: Integer;
begin
  Parts := TTextList.Create;
  try
    Parts.Add('<?xml version="1.0" encoding="UTF-8"?>');
    Parts.Add('<Types xmlns="' + NS_CONTENT_TYPES + '">');
    for I := 0 to High(DEF_EXT) do
      Parts.Add('<Default Extension="' + DEF_EXT[I] + '" ContentType="' +
        DEF_CT[I] + '"/>');
    Parts.Add('<Override PartName="/fb3/meta/core.xml" ContentType="' +
      CT_CORE + '"/>');
    Parts.Add('<Override PartName="/fb3/description.xml" ContentType="' +
      CT_DESCRIPTION + '"/>');
    Parts.Add('<Override PartName="/fb3/body.xml" ContentType="' +
      CT_BODY + '"/>');
    Parts.Add('</Types>');
    Result := JoinText(Parts, #10) + #10;
  finally
    Parts.Free;
  end;
end;

function TFb2ToFb3Converter.PackageRels(Doc: TFb3Document): UnicodeString;
var
  Parts: TTextList;
  Counter: Integer;
begin
  Parts := TTextList.Create;
  try
    Parts.Add('<?xml version="1.0" encoding="UTF-8"?>');
    Parts.Add('<Relationships xmlns="' + NS_RELS + '">');
    Counter := 0;
    if Doc.Cover <> '' then
    begin
      Parts.Add('<Relationship Id="rId' + IntToStr(Counter) + '" Type="' +
        REL_THUMBNAIL + '" Target="fb3/img/' + Doc.Cover + '"/>');
      Inc(Counter);
    end;
    Parts.Add('<Relationship Id="rId' + IntToStr(Counter) + '" Type="' +
      REL_CORE + '" Target="fb3/meta/core.xml"/>');
    Inc(Counter);
    Parts.Add('<Relationship Id="rId' + IntToStr(Counter) + '" Type="' +
      REL_BOOK + '" Target="fb3/description.xml"/>');
    Parts.Add('</Relationships>');
    Result := JoinText(Parts, #10) + #10;
  finally
    Parts.Free;
  end;
end;

function TFb2ToFb3Converter.DescriptionRels: UnicodeString;
begin
  Result :=
    '<?xml version="1.0" encoding="UTF-8"?>' + #10 +
    '<Relationships xmlns="' + NS_RELS + '">' + #10 +
    '<Relationship Id="rId0" Type="' + REL_BODY +
    '" Target="body.xml"/>' + #10 +
    '</Relationships>' + #10;
end;

function TFb2ToFb3Converter.BodyRels(Doc: TFb3Document): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
begin
  Parts := TTextList.Create;
  try
    Parts.Add('<?xml version="1.0" encoding="UTF-8"?>');
    Parts.Add('<Relationships xmlns="' + NS_RELS + '" xmlns:xlink="' +
      NS_XLINK + '">');
    for I := 0 to Doc.Images.Count - 1 do
      Parts.Add('<Relationship Id="' + Doc.Images[I].RelId + '" Type="' +
        REL_IMAGE + '" Target="img/' + Doc.Images[I].FileName + '"/>');
    Parts.Add('</Relationships>');
    Result := JoinText(Parts, #10) + #10;
  finally
    Parts.Free;
  end;
end;

{ ===================== Публичный API ===================== }

function TFb2ToFb3Converter.Convert(const Source: UnicodeString): TFb3Document;
var
  Desc: TDescription;
  Bodies, Binaries: TFb2ObjectList;
  TI: TTitleInfo;
  DI: TDocumentInfo;
  Identifier, Cover, BodyXml: UnicodeString;
begin
  if Source <> '' then
    FSource := Source;
  Reset;

  FParser.LoadFile(FSource);
  Desc := FParser.Parse;
  Bodies := FParser.ParseBodies;
  Binaries := FParser.ParseBinaries;
  try
    TI := nil;
    DI := nil;
    if Desc <> nil then
    begin
      TI := Desc.TitleInfo;
      DI := Desc.DocumentInfo;
    end;

    ReadMetadata(TI);
    CollectImages(Binaries);

    Identifier := NewUuid;
    Cover := CoverName(TI);
    BodyXml := RenderBody(Bodies);

    FreeAndNil(FDoc);
    FDoc := TFb3Document.Create;
    FDoc.Identifier := Identifier;
    FDoc.DescriptionXml := DescriptionXml(Identifier, DI);
    FDoc.BodyXml := BodyXml;
    FDoc.CoreXml := CoreXml;
    FDoc.Cover := Cover;
    FreeAndNil(FDoc.Images);
    FDoc.Images := FImages;
    FImages := nil;
    Result := FDoc;
  finally
    Binaries.Free;
    Bodies.Free;
    Desc.Free;
  end;
end;

function TFb2ToFb3Converter.ToBytes(Doc: TFb3Document): TBytes;
var
  Z: TZipper;
  OutStream: TMemoryStream;
  I: Integer;
begin
  if Doc = nil then
    Doc := FDoc;
  if Doc = nil then
    raise EFb2ConversionError.Create(
      'Нет книги для сериализации: вызовите Convert');

  OutStream := TMemoryStream.Create;
  try
    Z := TZipper.Create;
    try
      AddTextEntry(Z, '[Content_Types].xml', ContentTypes);
      AddTextEntry(Z, '_rels/.rels', PackageRels(Doc));
      AddTextEntry(Z, 'fb3/description.xml', Doc.DescriptionXml);
      AddTextEntry(Z, 'fb3/body.xml', Doc.BodyXml);
      AddTextEntry(Z, 'fb3/meta/core.xml', Doc.CoreXml);
      AddTextEntry(Z, 'fb3/_rels/description.xml.rels', DescriptionRels);
      AddTextEntry(Z, 'fb3/_rels/body.xml.rels', BodyRels(Doc));
      for I := 0 to Doc.Images.Count - 1 do
        AddDataEntry(Z, 'fb3/img/' + Doc.Images[I].FileName,
          Doc.Images[I].Data);
      Z.SaveToStream(OutStream);
    finally
      Z.Free;
    end;
    SetLength(Result, OutStream.Size);
    if OutStream.Size > 0 then
      Move(OutStream.Memory^, Result[0], OutStream.Size);
  finally
    OutStream.Free;
  end;
end;

function TFb2ToFb3Converter.Write(const Source: UnicodeString;
  const Output: UnicodeString): UnicodeString;
var
  Doc: TFb3Document;
  Data: TBytes;
  Target: UnicodeString;
begin
  Doc := Convert(Source);
  Data := ToBytes(Doc);
  if Output <> '' then
    Target := Output
  else if FSource <> '' then
    Target := ChangeFileExt(FSource, '.fb3')
  else
    Target := 'book.fb3';
  WriteFileAtomic(Target, Data);
  Result := Target;
end;

end.
