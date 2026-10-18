unit fb2_to_odt;
{ Преобразование книги FB2 в OpenDocument Text (ODT) — перевод fb2_to_odt.py.

  Собирает ODT-файл (ZIP-контейнер OpenDocument 1.2): текст с заголовками,
  разметкой (жирный/курсив/код/ссылки), цитатами, стихами, эпиграфами,
  таблицами и изображениями, а также метаданные (meta.xml).

  Состав контейнера:
      mimetype                     (без сжатия, как требует ODF)
      META-INF/manifest.xml
      content.xml                  (текст + автоматические стили)
      styles.xml                   (базовые стили)
      meta.xml                     (название, автор, язык, дата)
      Pictures/*                   (изображения)

  Промежуточное представление — TOdtBook; сериализуется в байты (ToBytes) или
  пишется в файл (Write). Обратное преобразование — odt_to_fb2.pas.

  Пример:
      C := TFb2ToOdtConverter.Create;
      try
        C.Write('book.fb2', 'book.odt');
      finally
        C.Free;
      end; }

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Classes, SysUtils, fgl,
  fb2_structures, fb2_parser, fb2_errors, fb2_images, fb2_files;

const
  { MIME-тип ODT (первая запись архива, без сжатия). }
  ODT_MIMETYPE = 'application/vnd.oasis.opendocument.text';

  { Служебные пространства имён ODF. }
  NS_OFFICE = 'urn:oasis:names:tc:opendocument:xmlns:office:1.0';
  NS_TEXT = 'urn:oasis:names:tc:opendocument:xmlns:text:1.0';
  NS_STYLE = 'urn:oasis:names:tc:opendocument:xmlns:style:1.0';
  NS_FO = 'urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0';
  NS_DRAW = 'urn:oasis:names:tc:opendocument:xmlns:drawing:1.0';
  NS_SVG = 'urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0';
  NS_TABLE = 'urn:oasis:names:tc:opendocument:xmlns:table:1.0';
  NS_XLINK = 'http://www.w3.org/1999/xlink';
  NS_META = 'urn:oasis:names:tc:opendocument:xmlns:meta:1.0';
  NS_DC = 'http://purl.org/dc/elements/1.1/';
  NS_MANIFEST = 'urn:oasis:names:tc:opendocument:xmlns:manifest:1.0';

  { Ширина страницы A4 за вычетом полей (см) — для масштаба картинок. }
  MAX_IMAGE_WIDTH_CM = 16.0;

  { Перевод пикселей в сантиметры (96 dpi). }
  PX_TO_CM = 2.54 / 96.0;

type
  { Изображение, встраиваемое в ODT (Pictures/...). }
  TOdtImage = class
  public
    FileName: UnicodeString;
    MediaType: UnicodeString;
    Data: TBytes;
    WidthCm: Double;
    HeightCm: Double;
  end;

  TOdtImageList = specialize TFPGObjectList<TOdtImage>;

  { Промежуточное представление документа ODT. }
  TOdtBook = class
  public
    Title: UnicodeString;
    Creators: TTextList;
    Language: UnicodeString;
    Identifier: UnicodeString;
    Date: UnicodeString;
    Description: UnicodeString;
    ContentXml: UnicodeString;
    AutomaticStyles: UnicodeString;
    Images: TOdtImageList;
    constructor Create;
    destructor Destroy; override;
  end;

  { Преобразование книги FB2 в OpenDocument Text (ODT). }
  TFb2ToOdtConverter = class
  private
    FParser: TFb2Parser;
    FMaxImageWidthCm: Double;
    FSource: UnicodeString;
    FBook: TOdtBook;
    FImages: TOdtImageList;
    FImageMap: TStringList;        { id -> индекс в FImages }
    FAutoStyles: TTextList;
    FStyleNames: TStringList;      { ключ флагов -> имя стиля }
    FFrameCounter: Integer;

    procedure Reset;
    function BookTitle(TI: TTitleInfo): UnicodeString;
    function CreatorList(TI: TTitleInfo): TTextList;
    function LanguageOf(TI: TTitleInfo): UnicodeString;
    function IdentifierOf(DI: TDocumentInfo): UnicodeString;
    function DateOf(TI: TTitleInfo; DI: TDocumentInfo): UnicodeString;
    function AnnotationText(TI: TTitleInfo): UnicodeString;

    procedure CollectImages(Binaries: TFb2ObjectList);
    function ImageByHref(const Href: UnicodeString): TOdtImage;
    function CoverImage(TI: TTitleInfo): TOdtImage;

    function RenderBody(Bodies: TFb2ObjectList; const Title: UnicodeString;
      Creators: TTextList; const Annotation: UnicodeString;
      Cover: TOdtImage): UnicodeString;
    function RenderBodyContent(Body: TBody): UnicodeString;
    function RenderSection(Section: TSection; Level: Integer): UnicodeString;
    function RenderTitle(Title: TTitle; Level: Integer): UnicodeString;
    function RenderEpigraph(E: TEpigraph): UnicodeString;
    function RenderAnnotation(A: TAnnotation): UnicodeString;
    function Paragraph(const Text, Style: UnicodeString): UnicodeString;
    function RenderBlock(Block: TFb2Object; const Style: UnicodeString): UnicodeString;
    function RenderCite(C: TCite): UnicodeString;
    function RenderPoem(P: TPoem): UnicodeString;
    function RenderStanza(S: TStanza): UnicodeString;
    function RenderTable(T: TTable): UnicodeString;

    function RenderMarkup(Nodes: TFb2ObjectList;
      Flags: TStringList): UnicodeString;
    function RenderText(const AText: UnicodeString; Flags: TStringList): UnicodeString;
    function MarkupStyleName(Flags: TStringList): UnicodeString;
    function Link(Node: TStyleNode; Flags: TStringList): UnicodeString;
    function InlineFrame(Node: TStyleNode): UnicodeString;
    function Frame(Image: TOdtImage; const Anchor: UnicodeString): UnicodeString;
    function ImageFrame(Image: TOdtImage; Centered: Boolean): UnicodeString;

    function NamespaceAttrs: UnicodeString;
    function ContentXml(Book: TOdtBook): UnicodeString;
    function StylesXml: UnicodeString;
    function MetaXml(Book: TOdtBook): UnicodeString;
    function ManifestXml(Book: TOdtBook): UnicodeString;
  public
    constructor Create(AParser: TFb2Parser = nil;
      MaxImageWidthCm: Double = MAX_IMAGE_WIDTH_CM);
    destructor Destroy; override;

    { Прочитать FB2 и вернуть структуру TOdtBook (владелец — конвертер). }
    function Convert(const Source: UnicodeString = ''): TOdtBook;

    { Сериализовать книгу в ODT (ZIP). Book = nil — результат Convert. }
    function ToBytes(Book: TOdtBook = nil): TBytes;

    { Преобразовать FB2 в файл ODT и вернуть путь к результату. }
    function Write(const Source: UnicodeString;
      const Output: UnicodeString = ''): UnicodeString;

    property Book: TOdtBook read FBook;
  end;

{ Экранирование XML (аналог html.escape с quote=True). }
function XmlEscape(const S: UnicodeString): UnicodeString;

implementation

uses
  zipper, zstream;

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

{ Новый набор флагов: копия A плюс тег Tag. }
function FlagsUnion(A: TStringList; const Tag: UnicodeString): TStringList;
var
  I: Integer;
begin
  Result := TStringList.Create;
  Result.Sorted := True;
  Result.Duplicates := dupIgnore;
  if A <> nil then
    for I := 0 to A.Count - 1 do
      Result.Add(A[I]);
  Result.Add(Tag);
end;

{ Ключ набора флагов (отсортированные имена через запятую). }
function FlagsKey(A: TStringList): UnicodeString;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to A.Count - 1 do
  begin
    if I > 0 then
      Result := Result + ',';
    Result := Result + A[I];
  end;
end;

{ Объединить непустые части через #10. }
function JoinNonEmptyLf(Parts: TTextList): UnicodeString;
var
  I: Integer;
  First: Boolean;
begin
  Result := '';
  First := True;
  for I := 0 to Parts.Count - 1 do
  begin
    if Parts[I] = '' then
      Continue;
    if not First then
      Result := Result + #10;
    Result := Result + Parts[I];
    First := False;
  end;
end;

{ Округлить до 2 знаков (round(x, 2)). }
function Round2(X: Double): Double;
begin
  Result := Round(X * 100) / 100;
end;

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

procedure AddStoredEntry(Z: TZipper; const Name, Text: UnicodeString);
var
  MS: TMemoryStream;
  B: TBytes;
  E: TZipFileEntry;
begin
  B := TEncoding.UTF8.GetBytes(Text);
  MS := TMemoryStream.Create;
  if Length(B) > 0 then
    MS.WriteBuffer(B[0], Length(B));
  MS.Position := 0;
  E := Z.Entries.AddFileEntry(MS, Name);
  E.CompressionLevel := clNone;
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

{ ===================== TOdtBook ===================== }

constructor TOdtBook.Create;
begin
  inherited Create;
  Title := 'Untitled';
  Creators := TTextList.Create;
  Language := 'ru';
  Identifier := '';
  Date := '';
  Description := '';
  ContentXml := '';
  AutomaticStyles := '';
  Images := TOdtImageList.Create(True);
end;

destructor TOdtBook.Destroy;
begin
  FreeAndNil(Creators);
  FreeAndNil(Images);
  inherited Destroy;
end;

{ ===================== TFb2ToOdtConverter ===================== }

constructor TFb2ToOdtConverter.Create(AParser: TFb2Parser;
  MaxImageWidthCm: Double);
begin
  inherited Create;
  if AParser <> nil then
    FParser := AParser
  else
    FParser := TFb2Parser.Create;
  FMaxImageWidthCm := MaxImageWidthCm;
  FSource := '';
  FBook := nil;
  FImages := nil;
  FImageMap := TStringList.Create;
  FImageMap.CaseSensitive := True;
  FImageMap.NameValueSeparator := '=';
  FAutoStyles := nil;
  FStyleNames := TStringList.Create;
  FStyleNames.CaseSensitive := True;
  FStyleNames.NameValueSeparator := '=';
  Reset;
end;

destructor TFb2ToOdtConverter.Destroy;
begin
  FreeAndNil(FBook);
  FreeAndNil(FImages);
  FreeAndNil(FAutoStyles);
  FreeAndNil(FImageMap);
  FreeAndNil(FStyleNames);
  FreeAndNil(FParser);
  inherited Destroy;
end;

procedure TFb2ToOdtConverter.Reset;
begin
  FreeAndNil(FImages);
  FImages := TOdtImageList.Create(True);
  FImageMap.Clear;
  FreeAndNil(FAutoStyles);
  FAutoStyles := TTextList.Create;
  FStyleNames.Clear;
  FFrameCounter := 0;
end;

{ ===================== Метаданные FB2 ===================== }

function TFb2ToOdtConverter.BookTitle(TI: TTitleInfo): UnicodeString;
begin
  if (TI <> nil) and (TI.BookTitle <> nil) and (TI.BookTitle.Value <> '') then
    Result := TI.BookTitle.Value
  else
    Result := 'Untitled';
end;

function TFb2ToOdtConverter.CreatorList(TI: TTitleInfo): TTextList;
var
  I: Integer;
  S: UnicodeString;
begin
  Result := TTextList.Create;
  if TI = nil then
    Exit;
  for I := 0 to TI.Authors.Count - 1 do
  begin
    S := AuthorTextOf(TAuthor(TI.Authors[I]));
    if S <> '' then
      Result.Add(S);
  end;
end;

function TFb2ToOdtConverter.LanguageOf(TI: TTitleInfo): UnicodeString;
begin
  if (TI <> nil) and (TI.Lang <> '') then
    Result := TI.Lang
  else
    Result := 'ru';
end;

function TFb2ToOdtConverter.IdentifierOf(DI: TDocumentInfo): UnicodeString;
begin
  if DI <> nil then
    Result := DI.Id
  else
    Result := '';
end;

function TFb2ToOdtConverter.DateOf(TI: TTitleInfo; DI: TDocumentInfo): UnicodeString;
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
  if (TI <> nil) and (TI.Date <> nil) then
  begin
    V := TI.Date.DateValue;
    if V = '' then
      V := TI.Date.Value;
    if V <> '' then
      Exit(V);
  end;
  Result := '';
end;

function TFb2ToOdtConverter.AnnotationText(TI: TTitleInfo): UnicodeString;
var
  Paragraphs: TTextList;
  I: Integer;
  Item: TFb2Object;
  S: UnicodeString;
begin
  Result := '';
  if (TI = nil) or (TI.Annotation = nil) then
    Exit;
  Paragraphs := TTextList.Create;
  try
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
        Paragraphs.Add(S);
    end;
    Result := JoinText(Paragraphs, #10);
  finally
    Paragraphs.Free;
  end;
end;

{ ===================== Изображения ===================== }

procedure TFb2ToOdtConverter.CollectImages(Binaries: TFb2ObjectList);
var
  I: Integer;
  Bin: TBinary;
  Data: TBytes;
  MediaType, Ext, RawId, Base, Name: UnicodeString;
  Sz: TImageSize;
  WidthCm, HeightCm: Double;
  Img: TOdtImage;
  Key: UnicodeString;
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
    Sz := fb2_images.ImageSize(Data, MediaType);
    if not Sz.Valid then
    begin
      WidthCm := FMaxImageWidthCm;
      HeightCm := FMaxImageWidthCm;
    end
    else
      fb2_images.ScaleToWidth(Sz.Width * PX_TO_CM, Sz.Height * PX_TO_CM,
        FMaxImageWidthCm, WidthCm, HeightCm);
    RawId := Bin.Id;
    if RawId = '' then
      RawId := 'image';
    if Pos('.', RawId) > 0 then
      Base := ChangeFileExt(ExtractFileName(RawId), '')
    else
      Base := RawId;
    if Base = '' then
      Base := 'image';
    Name := Base + Ext;

    Img := TOdtImage.Create;
    Img.FileName := Name;
    Img.MediaType := MediaType;
    Img.Data := Data;
    Img.WidthCm := Round2(WidthCm);
    Img.HeightCm := Round2(HeightCm);
    FImages.Add(Img);

    Key := Bin.Id;
    while (Key <> '') and (Key[1] = '#') do
      Delete(Key, 1, 1);
    MapSet(FImageMap, Key, IntToStr(FImages.Count - 1));
  end;
end;

function TFb2ToOdtConverter.ImageByHref(const Href: UnicodeString): TOdtImage;
var
  Key, S: UnicodeString;
  Idx: Integer;
begin
  Result := nil;
  if Href = '' then
    Exit;
  Key := Href;
  while (Key <> '') and (Key[1] = '#') do
    Delete(Key, 1, 1);
  S := MapGet(FImageMap, Key);
  if S = '' then
    Exit;
  Idx := StrToIntDef(S, -1);
  if (Idx >= 0) and (Idx < FImages.Count) then
    Result := FImages[Idx];
end;

function TFb2ToOdtConverter.CoverImage(TI: TTitleInfo): TOdtImage;
var
  I: Integer;
  Found: TOdtImage;
begin
  Result := nil;
  if (TI = nil) or (TI.Coverpage = nil) then
    Exit;
  for I := 0 to TI.Coverpage.Images.Count - 1 do
  begin
    Found := ImageByHref(TImage(TI.Coverpage.Images[I]).Href);
    if Found <> nil then
      Exit(Found);
  end;
end;

{ ===================== Рендеринг текста ===================== }

{ Разбить текст по строкам (аналог str.splitlines). }
function SplitLines(const S: UnicodeString): TTextList;
var
  I: Integer;
  Cur: UnicodeString;
begin
  Result := TTextList.Create;
  Cur := '';
  for I := 1 to Length(S) do
  begin
    if (S[I] = #10) or (S[I] = #13) then
    begin
      Result.Add(Cur);
      Cur := '';
    end
    else
      Cur := Cur + S[I];
  end;
  Result.Add(Cur);
end;

function TFb2ToOdtConverter.RenderBody(Bodies: TFb2ObjectList;
  const Title: UnicodeString; Creators: TTextList;
  const Annotation: UnicodeString; Cover: TOdtImage): UnicodeString;
var
  Parts, Lines: TTextList;
  I: Integer;
begin
  Parts := TTextList.Create;
  try
    Parts.Add(Paragraph(Title, 'Title'));
    if Creators.Count > 0 then
      Parts.Add(Paragraph(JoinText(Creators, ', '), 'Subtitle'));
    if Annotation <> '' then
    begin
      Lines := SplitLines(Annotation);
      try
        for I := 0 to Lines.Count - 1 do
          Parts.Add(Paragraph(Lines[I], 'Annotation'));
      finally
        Lines.Free;
      end;
    end;
    if Cover <> nil then
      Parts.Add(ImageFrame(Cover, True));
    if Bodies <> nil then
      for I := 0 to Bodies.Count - 1 do
        Parts.Add(RenderBodyContent(TBody(Bodies[I])));
    Result := JoinNonEmptyLf(Parts);
  finally
    Parts.Free;
  end;
end;

function TFb2ToOdtConverter.RenderBodyContent(Body: TBody): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
  Image: TOdtImage;
begin
  Parts := TTextList.Create;
  try
    if Body.Image <> nil then
    begin
      Image := ImageByHref(Body.Image.Href);
      if Image <> nil then
        Parts.Add(ImageFrame(Image, True));
    end;
    if Body.Title <> nil then
      Parts.Add(RenderTitle(Body.Title, 1));
    for I := 0 to Body.Epigraphs.Count - 1 do
      Parts.Add(RenderEpigraph(TEpigraph(Body.Epigraphs[I])));
    for I := 0 to Body.Sections.Count - 1 do
      Parts.Add(RenderSection(TSection(Body.Sections[I]), 1));
    Result := JoinNonEmptyLf(Parts);
  finally
    Parts.Free;
  end;
end;

function TFb2ToOdtConverter.RenderSection(Section: TSection;
  Level: Integer): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
  Image: TOdtImage;
begin
  Parts := TTextList.Create;
  try
    if Section.Title <> nil then
      Parts.Add(RenderTitle(Section.Title, Level));
    for I := 0 to Section.Epigraphs.Count - 1 do
      Parts.Add(RenderEpigraph(TEpigraph(Section.Epigraphs[I])));
    if Section.Image <> nil then
    begin
      Image := ImageByHref(Section.Image.Href);
      if Image <> nil then
        Parts.Add(ImageFrame(Image, True));
    end;
    if Section.Annotation <> nil then
      Parts.Add(RenderAnnotation(Section.Annotation));
    for I := 0 to Section.Content.Count - 1 do
      Parts.Add(RenderBlock(TFb2Object(Section.Content[I]), ''));
    for I := 0 to Section.Sections.Count - 1 do
      Parts.Add(RenderSection(TSection(Section.Sections[I]), Level + 1));
    Result := JoinNonEmptyLf(Parts);
  finally
    Parts.Free;
  end;
end;

function TFb2ToOdtConverter.RenderTitle(Title: TTitle;
  Level: Integer): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
  Item: TFb2Object;
  Text, Inner: UnicodeString;
begin
  if Level < 1 then
    Level := 1;
  if Level > 10 then
    Level := 10;
  Parts := TTextList.Create;
  try
    for I := 0 to Title.Items.Count - 1 do
    begin
      Item := Title.Items[I];
      if Item is TParagraph then
      begin
        Text := RenderMarkup(TParagraph(Item).Content, nil);
        if Text <> '' then
          Parts.Add(Text);
      end;
    end;
    Inner := JoinText(Parts, ' ');
    if Inner <> '' then
      Result := '<text:h text:outline-level="' + IntToStr(Level) + '">' +
        Inner + '</text:h>';
  finally
    Parts.Free;
  end;
end;

function TFb2ToOdtConverter.RenderEpigraph(E: TEpigraph): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
  Rendered: UnicodeString;
begin
  Parts := TTextList.Create;
  try
    for I := 0 to E.Items.Count - 1 do
    begin
      Rendered := RenderBlock(TFb2Object(E.Items[I]), 'Epigraph');
      if Rendered <> '' then
        Parts.Add(Rendered);
    end;
    for I := 0 to E.TextAuthor.Count - 1 do
      Parts.Add(Paragraph(
        RenderMarkup(TParagraph(E.TextAuthor[I]).Content, nil),
        'EpigraphAuthor'));
    Result := JoinText(Parts, #10);
  finally
    Parts.Free;
  end;
end;

function TFb2ToOdtConverter.RenderAnnotation(A: TAnnotation): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
  Rendered: UnicodeString;
begin
  Parts := TTextList.Create;
  try
    for I := 0 to A.Items.Count - 1 do
    begin
      Rendered := RenderBlock(TFb2Object(A.Items[I]), 'Annotation');
      if Rendered <> '' then
        Parts.Add(Rendered);
    end;
    Result := JoinText(Parts, #10);
  finally
    Parts.Free;
  end;
end;

function TFb2ToOdtConverter.Paragraph(const Text,
  Style: UnicodeString): UnicodeString;
var
  Name: UnicodeString;
begin
  if Text = '' then
    Exit('');
  if Style <> '' then
    Name := ' text:style-name="' + Style + '"'
  else
    Name := '';
  Result := '<text:p' + Name + '>' + Text + '</text:p>';
end;

function TFb2ToOdtConverter.RenderBlock(Block: TFb2Object;
  const Style: UnicodeString): UnicodeString;
var
  Image: TOdtImage;
  SubStyle: UnicodeString;
begin
  if Block is TParagraph then
    Result := Paragraph(RenderMarkup(TParagraph(Block).Content, nil), Style)
  else if Block is TSubtitle then
  begin
    if Style <> '' then
      SubStyle := Style
    else
      SubStyle := 'Subtitle2';
    Result := Paragraph(RenderMarkup(TSubtitle(Block).Content, nil), SubStyle);
  end
  else if Block is TEmptyLine then
    Result := Paragraph('&#160;', Style)
  else if Block is TPoem then
    Result := RenderPoem(TPoem(Block))
  else if Block is TCite then
    Result := RenderCite(TCite(Block))
  else if Block is TTable then
    Result := RenderTable(TTable(Block))
  else if Block is TImage then
  begin
    Image := ImageByHref(TImage(Block).Href);
    if Image <> nil then
      Result := ImageFrame(Image, True)
    else
      Result := '';
  end
  else if Block is TEpigraph then
    Result := RenderEpigraph(TEpigraph(Block))
  else if Block is TTitle then
    Result := RenderTitle(TTitle(Block), 2)
  else if Block is TAnnotation then
    Result := RenderAnnotation(TAnnotation(Block))
  else
    Result := '';
end;

function TFb2ToOdtConverter.RenderCite(C: TCite): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
  Rendered: UnicodeString;
begin
  Parts := TTextList.Create;
  try
    for I := 0 to C.Items.Count - 1 do
    begin
      Rendered := RenderBlock(TFb2Object(C.Items[I]), 'Quotation');
      if Rendered <> '' then
        Parts.Add(Rendered);
    end;
    for I := 0 to C.TextAuthor.Count - 1 do
      Parts.Add(Paragraph(
        RenderMarkup(TParagraph(C.TextAuthor[I]).Content, nil),
        'QuotationAuthor'));
    Result := JoinText(Parts, #10);
  finally
    Parts.Free;
  end;
end;

function TFb2ToOdtConverter.RenderPoem(P: TPoem): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
  Item: TFb2Object;
begin
  Parts := TTextList.Create;
  try
    if P.Title <> nil then
      Parts.Add(RenderTitle(P.Title, 3));
    for I := 0 to P.Epigraphs.Count - 1 do
      Parts.Add(RenderEpigraph(TEpigraph(P.Epigraphs[I])));
    for I := 0 to P.Items.Count - 1 do
    begin
      Item := P.Items[I];
      if Item is TStanza then
        Parts.Add(RenderStanza(TStanza(Item)))
      else if Item is TSubtitle then
        Parts.Add(Paragraph(RenderMarkup(TSubtitle(Item).Content, nil),
          'Subtitle2'));
    end;
    for I := 0 to P.TextAuthor.Count - 1 do
      Parts.Add(Paragraph(
        RenderMarkup(TParagraph(P.TextAuthor[I]).Content, nil), 'PoemAuthor'));
    Result := JoinNonEmptyLf(Parts);
  finally
    Parts.Free;
  end;
end;

function TFb2ToOdtConverter.RenderStanza(S: TStanza): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
begin
  Parts := TTextList.Create;
  try
    if S.Subtitle <> nil then
      Parts.Add(Paragraph(RenderMarkup(S.Subtitle.Content, nil), 'Subtitle2'));
    for I := 0 to S.Verses.Count - 1 do
      Parts.Add(Paragraph(RenderMarkup(TParagraph(S.Verses[I]).Content, nil),
        'PoemLine'));
    Result := JoinNonEmptyLf(Parts);
  finally
    Parts.Free;
  end;
end;

function TFb2ToOdtConverter.RenderTable(T: TTable): UnicodeString;
var
  Rows, Cells: TTextList;
  I, J: Integer;
  Row: TTableRow;
  Cell: TTableCell;
  Style, Content: UnicodeString;
begin
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
            Style := 'HeaderCell'
          else
            Style := '';
          Content := Paragraph(RenderMarkup(Cell.Children, nil), Style);
          Cells.Add('<table:table-cell>' + Content + '</table:table-cell>');
        end;
        Rows.Add('<table:table-row>' + JoinText(Cells, '') +
          '</table:table-row>');
      finally
        Cells.Free;
      end;
    end;
    Result := '<table:table>' + JoinText(Rows, '') + '</table:table>';
  finally
    Rows.Free;
  end;
end;

{ Inline-тег, влияющий на оформление текста. }
function IsMarkupTag(const Tag: UnicodeString): Boolean;
begin
  Result := (Tag = 'strong') or (Tag = 'emphasis') or (Tag = 'code') or
    (Tag = 'strikethrough') or (Tag = 'sub') or (Tag = 'sup') or
    (Tag = 'style');
end;

function TFb2ToOdtConverter.RenderMarkup(Nodes: TFb2ObjectList;
  Flags: TStringList): UnicodeString;
var
  I: Integer;
  Node: TStyleNode;
  Tag: UnicodeString;
  NF: TStringList;
begin
  Result := '';
  if Nodes = nil then
    Exit;
  for I := 0 to Nodes.Count - 1 do
  begin
    Node := TStyleNode(Nodes[I]);
    Tag := Node.Tag;
    if Tag = TEXT_NODE_NAME then
      Result := Result + RenderText(Node.Text, Flags)
    else if Tag = 'a' then
      Result := Result + Link(Node, Flags)
    else if Tag = 'image' then
      Result := Result + InlineFrame(Node)
    else if IsMarkupTag(Tag) then
    begin
      NF := FlagsUnion(Flags, Tag);
      try
        Result := Result + RenderMarkup(Node.Children, NF);
      finally
        NF.Free;
      end;
    end
    else
      Result := Result + RenderMarkup(Node.Children, Flags);
  end;
end;

function TFb2ToOdtConverter.RenderText(const AText: UnicodeString;
  Flags: TStringList): UnicodeString;
var
  Escaped, Name: UnicodeString;
begin
  if AText = '' then
    Exit('');
  Escaped := XmlEscape(AText);
  if (Flags = nil) or (Flags.Count = 0) then
    Exit(Escaped);
  Name := MarkupStyleName(Flags);
  Result := '<text:span text:style-name="' + Name + '">' + Escaped +
    '</text:span>';
end;

function TFb2ToOdtConverter.MarkupStyleName(Flags: TStringList): UnicodeString;
var
  Key, Name: UnicodeString;
  Props: TTextList;
begin
  Key := FlagsKey(Flags);
  Name := MapGet(FStyleNames, Key);
  if Name <> '' then
    Exit(Name);
  Name := 'T' + IntToStr(FStyleNames.Count + 1);
  Props := TTextList.Create;
  try
    if Flags.IndexOf('strong') >= 0 then
      Props.Add('fo:font-weight="bold"');
    if Flags.IndexOf('emphasis') >= 0 then
      Props.Add('fo:font-style="italic"');
    if Flags.IndexOf('code') >= 0 then
      Props.Add('style:font-name="Courier New"');
    if Flags.IndexOf('strikethrough') >= 0 then
      Props.Add('style:text-line-through-style="solid"');
    if Flags.IndexOf('sub') >= 0 then
      Props.Add('style:text-position="sub 58%"');
    if Flags.IndexOf('sup') >= 0 then
      Props.Add('style:text-position="super 58%"');
    FAutoStyles.Add('<style:style style:name="' + Name +
      '" style:family="text"><style:text-properties ' +
      JoinText(Props, ' ') + '/></style:style>');
  finally
    Props.Free;
  end;
  MapSet(FStyleNames, Key, Name);
  Result := Name;
end;

function TFb2ToOdtConverter.Link(Node: TStyleNode;
  Flags: TStringList): UnicodeString;
var
  Inner, Href: UnicodeString;
begin
  Inner := RenderMarkup(Node.Children, Flags);
  Href := Node.Href;
  if Href = '' then
    Exit(Inner);
  Result := '<text:a xlink:type="simple" xlink:href="' + XmlEscape(Href) +
    '">' + Inner + '</text:a>';
end;

function TFb2ToOdtConverter.InlineFrame(Node: TStyleNode): UnicodeString;
var
  Href: UnicodeString;
  Image: TOdtImage;
begin
  Href := Node.ImageHref;
  if Href = '' then
    Href := Node.Href;
  Image := ImageByHref(Href);
  if Image <> nil then
    Result := Frame(Image, 'as-char')
  else
    Result := '';
end;

{ Размер в сантиметрах в виде строки с точкой (аналог str(float)). }
function FmtCm(X: Double): UnicodeString;
var
  FS: TFormatSettings;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  Result := FormatFloat('0.0#########', X, FS);
end;

function TFb2ToOdtConverter.Frame(Image: TOdtImage;
  const Anchor: UnicodeString): UnicodeString;
var
  StyleName: UnicodeString;
begin
  Inc(FFrameCounter);
  StyleName := 'fr' + IntToStr(FFrameCounter);
  FAutoStyles.Add(
    '<style:style style:name="' + StyleName + '" style:family="graphic">' +
    '<style:graphic-properties style:vertical-pos="top" ' +
    'style:vertical-rel="baseline" style:horizontal-pos="center" ' +
    'style:horizontal-rel="paragraph" style:wrap="none"/></style:style>');
  Result :=
    '<draw:frame draw:style-name="' + StyleName + '" text:anchor-type="' +
    Anchor + '" svg:width="' + FmtCm(Image.WidthCm) + 'cm" svg:height="' +
    FmtCm(Image.HeightCm) + 'cm">' +
    '<draw:image xlink:href="Pictures/' + Image.FileName +
    '" xlink:type="simple" xlink:show="embed" xlink:actuate="onLoad"/>' +
    '</draw:frame>';
end;

function TFb2ToOdtConverter.ImageFrame(Image: TOdtImage;
  Centered: Boolean): UnicodeString;
var
  Style: UnicodeString;
begin
  if Image = nil then
    Exit('');
  if Centered then
    Style := 'Centered'
  else
    Style := 'Standard';
  Result := '<text:p text:style-name="' + Style + '">' +
    Frame(Image, 'as-char') + '</text:p>';
end;

function TFb2ToOdtConverter.NamespaceAttrs: UnicodeString;
begin
  Result :=
    'xmlns:office="' + NS_OFFICE + '" xmlns:text="' + NS_TEXT +
    '" xmlns:style="' + NS_STYLE + '" xmlns:fo="' + NS_FO +
    '" xmlns:draw="' + NS_DRAW + '" xmlns:svg="' + NS_SVG +
    '" xmlns:table="' + NS_TABLE + '" xmlns:xlink="' + NS_XLINK + '"';
end;

function TFb2ToOdtConverter.ContentXml(Book: TOdtBook): UnicodeString;
begin
  Result :=
    '<?xml version="1.0" encoding="UTF-8"?>' + #10 +
    '<office:document-content ' + NamespaceAttrs + ' office:version="1.2">' +
    #10 +
    '<office:automatic-styles>' + #10 +
    Book.AutomaticStyles + #10 +
    '</office:automatic-styles>' + #10 +
    '<office:body><office:text>' + #10 +
    Book.ContentXml + #10 +
    '</office:text></office:body>' + #10 +
    '</office:document-content>' + #10;
end;

type
  TParaStyle = record
    Name: UnicodeString;
    Paragraph: UnicodeString;
    Text: UnicodeString;
  end;

const
  { Базовые стили абзацев ODT: имя, свойства абзаца, свойства текста. }
  PARAGRAPH_STYLES: array[0..11] of TParaStyle = (
    (Name: 'Title';
     Paragraph: 'fo:text-align="center" fo:margin-bottom="0.5cm"';
     Text: 'fo:font-size="20pt" fo:font-weight="bold"'),
    (Name: 'Subtitle';
     Paragraph: 'fo:text-align="center" fo:margin-bottom="0.5cm"';
     Text: 'fo:font-size="14pt" fo:font-style="italic"'),
    (Name: 'Subtitle2';
     Paragraph: 'fo:margin-top="0.3cm" fo:margin-bottom="0.2cm"';
     Text: 'fo:font-weight="bold"'),
    (Name: 'Annotation';
     Paragraph: 'fo:margin-left="1cm" fo:margin-right="1cm" fo:margin-bottom="0.3cm"';
     Text: 'fo:font-size="11pt"'),
    (Name: 'Epigraph';
     Paragraph: 'fo:margin-left="2cm" fo:margin-right="1cm"';
     Text: 'fo:font-style="italic"'),
    (Name: 'EpigraphAuthor';
     Paragraph: 'fo:margin-left="3cm" fo:text-align="end"'; Text: ''),
    (Name: 'Quotation';
     Paragraph: 'fo:margin-left="1cm" fo:margin-right="1cm"'; Text: ''),
    (Name: 'QuotationAuthor';
     Paragraph: 'fo:margin-left="2cm" fo:text-align="end"'; Text: ''),
    (Name: 'PoemLine'; Paragraph: 'fo:margin-left="2cm"'; Text: ''),
    (Name: 'PoemAuthor';
     Paragraph: 'fo:margin-left="2cm" fo:text-align="end"'; Text: ''),
    (Name: 'Centered'; Paragraph: 'fo:text-align="center"'; Text: ''),
    (Name: 'HeaderCell';
     Paragraph: 'fo:text-align="center"'; Text: 'fo:font-weight="bold"')
  );

function TFb2ToOdtConverter.StylesXml: UnicodeString;
var
  Rendered, Parts: TTextList;
  I: Integer;
  S: TParaStyle;
begin
  Rendered := TTextList.Create;
  try
    for I := 0 to High(PARAGRAPH_STYLES) do
    begin
      S := PARAGRAPH_STYLES[I];
      Parts := TTextList.Create;
      try
        Parts.Add('<style:style style:name="' + S.Name +
          '" style:family="paragraph">');
        if S.Paragraph <> '' then
          Parts.Add('<style:paragraph-properties ' + S.Paragraph + '/>');
        if S.Text <> '' then
          Parts.Add('<style:text-properties ' + S.Text + '/>');
        Parts.Add('</style:style>');
        Rendered.Add(JoinText(Parts, ''));
      finally
        Parts.Free;
      end;
    end;
    Result :=
      '<?xml version="1.0" encoding="UTF-8"?>' + #10 +
      '<office:document-styles ' + NamespaceAttrs + ' office:version="1.2">' +
      #10 +
      '<office:styles>' + #10 +
      '<style:style style:name="Standard" style:family="paragraph" ' +
      'style:class="text"/>' + #10 +
      JoinText(Rendered, #10) +
      #10 + '</office:styles>' + #10 +
      '<office:automatic-styles>' + #10 +
      '<style:page-layout style:name="pm1">' +
      '<style:page-layout-properties fo:page-width="21cm" ' +
      'fo:page-height="29.7cm" style:print-orientation="portrait" ' +
      'fo:margin="2cm"/></style:page-layout>' + #10 +
      '</office:automatic-styles>' + #10 +
      '<office:master-styles>' +
      '<style:master-page style:name="Standard" style:page-layout-name="pm1"/>' +
      '</office:master-styles>' + #10 +
      '</office:document-styles>' + #10;
  finally
    Rendered.Free;
  end;
end;

function TFb2ToOdtConverter.MetaXml(Book: TOdtBook): UnicodeString;
var
  Lines: TTextList;
  I: Integer;
begin
  Lines := TTextList.Create;
  try
    Lines.Add('<?xml version="1.0" encoding="UTF-8"?>');
    Lines.Add('<office:document-meta xmlns:office="' + NS_OFFICE +
      '" xmlns:meta="' + NS_META + '" xmlns:dc="' + NS_DC +
      '" office:version="1.2">');
    Lines.Add('<office:meta>');
    Lines.Add('<dc:title>' + XmlEscape(Book.Title) + '</dc:title>');
    for I := 0 to Book.Creators.Count - 1 do
      Lines.Add('<dc:creator>' + XmlEscape(Book.Creators[I]) + '</dc:creator>');
    Lines.Add('<dc:language>' + XmlEscape(Book.Language) + '</dc:language>');
    if Book.Date <> '' then
      Lines.Add('<dc:date>' + XmlEscape(Book.Date) + '</dc:date>');
    if Book.Description <> '' then
      Lines.Add('<dc:description>' + XmlEscape(Book.Description) +
        '</dc:description>');
    Lines.Add('<meta:generator>pyFB2</meta:generator>');
    Lines.Add('</office:meta>');
    Lines.Add('</office:document-meta>');
    Result := JoinText(Lines, #10) + #10;
  finally
    Lines.Free;
  end;
end;

function TFb2ToOdtConverter.ManifestXml(Book: TOdtBook): UnicodeString;
var
  Lines: TTextList;
  I: Integer;
begin
  Lines := TTextList.Create;
  try
    Lines.Add('<?xml version="1.0" encoding="UTF-8"?>');
    Lines.Add('<manifest:manifest xmlns:manifest="' + NS_MANIFEST +
      '" manifest:version="1.2">');
    Lines.Add('<manifest:file-entry manifest:full-path="/" ' +
      'manifest:media-type="' + ODT_MIMETYPE + '"/>');
    Lines.Add('<manifest:file-entry manifest:full-path="content.xml" ' +
      'manifest:media-type="text/xml"/>');
    Lines.Add('<manifest:file-entry manifest:full-path="styles.xml" ' +
      'manifest:media-type="text/xml"/>');
    Lines.Add('<manifest:file-entry manifest:full-path="meta.xml" ' +
      'manifest:media-type="text/xml"/>');
    for I := 0 to Book.Images.Count - 1 do
      Lines.Add('<manifest:file-entry manifest:full-path="Pictures/' +
        Book.Images[I].FileName + '" manifest:media-type="' +
        Book.Images[I].MediaType + '"/>');
    Lines.Add('</manifest:manifest>');
    Result := JoinText(Lines, #10) + #10;
  finally
    Lines.Free;
  end;
end;

{ ===================== Публичный API ===================== }

function TFb2ToOdtConverter.Convert(const Source: UnicodeString): TOdtBook;
var
  Desc: TDescription;
  Bodies, Binaries: TFb2ObjectList;
  TI: TTitleInfo;
  DI: TDocumentInfo;
  Title, Annotation, Content: UnicodeString;
  Creators: TTextList;
  Cover: TOdtImage;
begin
  if Source <> '' then
    FSource := Source;
  Reset;

  FParser.LoadFile(FSource);
  Desc := FParser.Parse;
  Bodies := FParser.ParseBodies;
  Binaries := FParser.ParseBinaries;
  Creators := nil;
  try
    TI := nil;
    DI := nil;
    if Desc <> nil then
    begin
      TI := Desc.TitleInfo;
      DI := Desc.DocumentInfo;
    end;

    Title := BookTitle(TI);
    Creators := CreatorList(TI);
    Annotation := AnnotationText(TI);
    CollectImages(Binaries);
    Cover := CoverImage(TI);
    Content := RenderBody(Bodies, Title, Creators, Annotation, Cover);

    FreeAndNil(FBook);
    FBook := TOdtBook.Create;
    FBook.Title := Title;
    FBook.Language := LanguageOf(TI);
    FBook.Identifier := IdentifierOf(DI);
    FBook.Date := DateOf(TI, DI);
    FBook.Description := Annotation;
    FBook.ContentXml := Content;
    FBook.AutomaticStyles := JoinText(FAutoStyles, #10);
    FreeAndNil(FBook.Creators);
    FBook.Creators := Creators;
    Creators := nil;
    FreeAndNil(FBook.Images);
    FBook.Images := FImages;
    FImages := nil;
    Result := FBook;
  finally
    Creators.Free;
    Binaries.Free;
    Bodies.Free;
    Desc.Free;
  end;
end;

function TFb2ToOdtConverter.ToBytes(Book: TOdtBook): TBytes;
var
  Z: TZipper;
  OutStream: TMemoryStream;
  I: Integer;
begin
  if Book = nil then
    Book := FBook;
  if Book = nil then
    raise EFb2ConversionError.Create(
      'Нет книги для сериализации: вызовите Convert');

  OutStream := TMemoryStream.Create;
  try
    Z := TZipper.Create;
    try
      AddStoredEntry(Z, 'mimetype', ODT_MIMETYPE);
      AddTextEntry(Z, 'META-INF/manifest.xml', ManifestXml(Book));
      AddTextEntry(Z, 'content.xml', ContentXml(Book));
      AddTextEntry(Z, 'styles.xml', StylesXml);
      AddTextEntry(Z, 'meta.xml', MetaXml(Book));
      for I := 0 to Book.Images.Count - 1 do
        AddDataEntry(Z, 'Pictures/' + Book.Images[I].FileName,
          Book.Images[I].Data);
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

function TFb2ToOdtConverter.Write(const Source: UnicodeString;
  const Output: UnicodeString): UnicodeString;
var
  Bk: TOdtBook;
  Data: TBytes;
  Target: UnicodeString;
begin
  Bk := Convert(Source);
  Data := ToBytes(Bk);
  if Output <> '' then
    Target := Output
  else if FSource <> '' then
    Target := ChangeFileExt(FSource, '.odt')
  else
    Target := 'book.odt';
  WriteFileAtomic(Target, Data);
  Result := Target;
end;

end.
