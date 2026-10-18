unit fb2_to_docx;
{ Преобразование FictionBook (FB2) в документ Word (DOCX) — перевод fb2_to_docx.py.

  Класс TFb2ToDocxConverter читает FB2 (через TFb2Parser) и собирает DOCX —
  архив Office Open XML (ZIP) без внешних зависимостей:

      * метаданные <description> -> заголовок, авторы, аннотация;
      * секция верхнего уровня -> заголовок стиля HeadingN;
      * <p>, <strong>, <emphasis>, <a>, <image>, <sub>/<sup>/<code>,
        <strikethrough>, <style>;
      * <cite>/<epigraph> -> стиль Quote, стихи -> отступ строк;
      * <table> -> настоящая таблица Word;
      * <binary> -> изображения (word/media/*) со встроенными ссылками.

  Промежуточное представление — TDocxBook (метаданные + XML документа +
  изображения); сериализуется в байты (ToBytes) или пишется в файл (Write).
  Обратное преобразование — docx_to_fb2.pas.

  Пример:
      C := TFb2ToDocxConverter.Create;
      try
        C.Write('book.fb2', 'book.docx');
      finally
        C.Free;
      end;

  Особенности перевода с Python:
      * ZIP пишется через TZipper (paszlib); порядок записей как в Python;
      * html.escape -> XmlEscape;
      * размеры изображений — через fb2_images.ImageSize. }

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Classes, SysUtils, fgl,
  fb2_structures, fb2_parser, fb2_errors, fb2_images, fb2_files;

const
  { Пространства имён OOXML. }
  NS_W = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
  NS_R = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
  NS_WP = 'http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing';
  NS_A = 'http://schemas.openxmlformats.org/drawingml/2006/main';
  NS_PIC = 'http://schemas.openxmlformats.org/drawingml/2006/picture';
  NS_CT = 'http://schemas.openxmlformats.org/package/2006/content-types';
  NS_REL = 'http://schemas.openxmlformats.org/package/2006/relationships';

  { Типы связей (relationships). }
  REL_STYLES =
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles';
  REL_IMAGE =
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships/image';
  REL_HYPERLINK =
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink';
  REL_CORE =
    'http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties';
  REL_APP =
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties';
  REL_OFFICE =
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument';

  { Английские единицы измерения Office (EMU). }
  EMU_PER_INCH = 914400;
  EMU_PER_PIXEL = 9525;   { 96 DPI }

  { Размер изображения по умолчанию (пиксели). }
  DEFAULT_IMAGE_WIDTH = 400;
  DEFAULT_IMAGE_HEIGHT = 300;

type
  { Свойства run <w:rPr> (аналог dict props в Python). }
  TDocxProps = record
    Bold: Boolean;
    Italic: Boolean;
    Strike: Boolean;
    Code: Boolean;
    Link: Boolean;
    Vert: UnicodeString;      { 'subscript' / 'superscript' / '' }
    Sz: Integer;              { 0 — не задан }
  end;

  { Изображение, встраиваемое в документ Word. }
  TDocxImage = class
  public
    RelId: UnicodeString;
    FileName: UnicodeString;
    Extension: UnicodeString;
    MediaType: UnicodeString;
    Data: TBytes;
    WidthEmu: Int64;
    HeightEmu: Int64;
  end;

  TDocxImageList = specialize TFPGObjectList<TDocxImage>;

  { Гиперссылка (rId -> URL). }
  TDocxHyperlink = class
  public
    RelId: UnicodeString;
    Url: UnicodeString;
  end;

  TDocxHyperlinkList = specialize TFPGObjectList<TDocxHyperlink>;

  { Промежуточное представление документа DOCX. }
  TDocxBook = class
  public
    Title: UnicodeString;
    Creators: TTextList;
    Language: UnicodeString;
    Identifier: UnicodeString;
    Date: UnicodeString;
    Description: UnicodeString;
    DocumentXml: UnicodeString;
    Images: TDocxImageList;
    Hyperlinks: TDocxHyperlinkList;
    constructor Create;
    destructor Destroy; override;
  end;

  { Преобразование книги FB2 в документ Word (DOCX). }
  TFb2ToDocxConverter = class
  private
    FParser: TFb2Parser;
    FMaxImageWidthEmu: Int64;
    FSource: UnicodeString;
    FBook: TDocxBook;
    FImages: TDocxImageList;
    FImageMap: TStringList;        { ключ (id/.#id) -> индекс в FImages }
    FHyperlinks: TDocxHyperlinkList;
    FRidCounter: Integer;
    FDrawingCounter: Integer;

    procedure Reset;
    function BookTitle(TI: TTitleInfo): UnicodeString;
    function CreatorList(TI: TTitleInfo): TTextList;
    function LanguageOf(TI: TTitleInfo): UnicodeString;
    function IdentifierOf(DI: TDocumentInfo): UnicodeString;
    function DateOf(TI: TTitleInfo; DI: TDocumentInfo): UnicodeString;
    function AnnotationText(TI: TTitleInfo): UnicodeString;
    function NewRid: UnicodeString;
    function NextDrawingId: Integer;

    procedure CollectImages(Binaries: TFb2ObjectList);
    function ImageByHref(const Href: UnicodeString): TDocxImage;
    function ComputeImageSize(const Data: TBytes;
      const MediaType: UnicodeString; out W, H: Integer): Boolean;
    procedure ScaleDimensions(W, H: Integer; out WEmu, HEmu: Int64);
    function CoverImage(TI: TTitleInfo): TDocxImage;

    function RenderDocumentBody(const Title: UnicodeString;
      Creators: TTextList; const Description: UnicodeString;
      Cover: TDocxImage; Bodies: TFb2ObjectList): UnicodeString;
    function RenderBody(Body: TBody): UnicodeString;
    function RenderSection(Section: TSection; Level: Integer): UnicodeString;
    function RenderTitle(Title: TTitle; Level: Integer): UnicodeString;
    function RenderEpigraph(E: TEpigraph): UnicodeString;
    function RenderAnnotation(A: TAnnotation): UnicodeString;
    function RenderBlock(Block: TFb2Object): UnicodeString;
    function Paragraph(const Runs: UnicodeString;
      const Style: UnicodeString = ''; const Jc: UnicodeString = ''): UnicodeString;
    function RenderCite(C: TCite): UnicodeString;
    function RenderPoem(P: TPoem): UnicodeString;
    function RenderStanza(S: TStanza): UnicodeString;
    function RenderTable(T: TTable): UnicodeString;
    function RenderBlockImage(Img: TImage): UnicodeString;

    function RenderMarkup(Nodes: TFb2ObjectList;
      const Props: TDocxProps): UnicodeString;
    function Run(const Text: UnicodeString;
      const Props: TDocxProps): UnicodeString;
    function RunProps(const Props: TDocxProps): UnicodeString;
    function RenderHyperlink(Node: TStyleNode;
      const Props: TDocxProps): UnicodeString;
    function ImageRun(Node: TStyleNode): UnicodeString;
    function Drawing(Image: TDocxImage; DrawingId: Integer): UnicodeString;

    function ContentTypes(Book: TDocxBook): UnicodeString;
    function RootRels: UnicodeString;
    function DocumentRels(Book: TDocxBook): UnicodeString;
    function DocumentXml(Book: TDocxBook): UnicodeString;
    function StylesXml: UnicodeString;
    function CoreXml(Book: TDocxBook): UnicodeString;
    function AppXml: UnicodeString;
  public
    constructor Create(AParser: TFb2Parser = nil;
      MaxImageWidthInches: Double = 6.0);
    destructor Destroy; override;

    { Прочитать FB2 и вернуть структуру TDocxBook (владелец — конвертер). }
    function Convert(const Source: UnicodeString = ''): TDocxBook;

    { Сериализовать книгу в DOCX (ZIP). Book = nil — результат Convert. }
    function ToBytes(Book: TDocxBook = nil): TBytes;

    { Преобразовать FB2 в файл DOCX и вернуть путь к результату. }
    function Write(const Source: UnicodeString;
      const Output: UnicodeString = ''): UnicodeString;

    property Book: TDocxBook read FBook;
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

{ Расширение файла media/ по MIME-типу. }
function ExtByMediaType(const MediaType: UnicodeString): UnicodeString;
begin
  if (MediaType = 'image/jpeg') or (MediaType = 'image/jpg') then
    Result := 'jpeg'
  else if MediaType = 'image/png' then
    Result := 'png'
  else if MediaType = 'image/gif' then
    Result := 'gif'
  else if MediaType = 'image/bmp' then
    Result := 'bmp'
  else if MediaType = 'image/tiff' then
    Result := 'tiff'
  else if MediaType = 'image/webp' then
    Result := 'webp'
  else
    Result := 'bin';
end;

{ MIME-тип по расширению (для [Content_Types].xml). '' — неизвестно. }
function MediaTypeByExt(const Ext: UnicodeString): UnicodeString;
begin
  if Ext = 'jpeg' then
    Result := 'image/jpeg'
  else if Ext = 'png' then
    Result := 'image/png'
  else if Ext = 'gif' then
    Result := 'image/gif'
  else if Ext = 'bmp' then
    Result := 'image/bmp'
  else if Ext = 'tiff' then
    Result := 'image/tiff'
  else if Ext = 'webp' then
    Result := 'image/webp'
  else
    Result := '';
end;

{ Новый UUID без дефисов (uuid.uuid4().hex). }
function NewUuidHex: UnicodeString;
var
  G: TGUID;
  S: UnicodeString;
  I: Integer;
begin
  CreateGUID(G);
  S := LowerCase(GUIDToString(G));
  Result := '';
  for I := 1 to Length(S) do
    if S[I] <> '-' then
      Result := Result + S[I];
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

{ ===================== TDocxBook ===================== }

constructor TDocxBook.Create;
begin
  inherited Create;
  Title := 'Untitled';
  Creators := TTextList.Create;
  Language := 'ru';
  Identifier := '';
  Date := '';
  Description := '';
  DocumentXml := '';
  Images := TDocxImageList.Create(True);
  Hyperlinks := TDocxHyperlinkList.Create(True);
end;

destructor TDocxBook.Destroy;
begin
  FreeAndNil(Creators);
  FreeAndNil(Images);
  FreeAndNil(Hyperlinks);
  inherited Destroy;
end;

{ ===================== TFb2ToDocxConverter ===================== }

constructor TFb2ToDocxConverter.Create(AParser: TFb2Parser;
  MaxImageWidthInches: Double);
begin
  inherited Create;
  if AParser <> nil then
    FParser := AParser
  else
    FParser := TFb2Parser.Create;
  FMaxImageWidthEmu := Round(MaxImageWidthInches * EMU_PER_INCH);
  FSource := '';
  FBook := nil;
  FImages := nil;
  FImageMap := TStringList.Create;
  FImageMap.CaseSensitive := True;
  FImageMap.NameValueSeparator := '=';
  FHyperlinks := nil;
  Reset;
end;

destructor TFb2ToDocxConverter.Destroy;
begin
  FreeAndNil(FBook);
  FreeAndNil(FImages);
  FreeAndNil(FHyperlinks);
  FreeAndNil(FImageMap);
  FreeAndNil(FParser);
  inherited Destroy;
end;

procedure TFb2ToDocxConverter.Reset;
begin
  FreeAndNil(FImages);
  FImages := TDocxImageList.Create(True);
  FImageMap.Clear;
  FreeAndNil(FHyperlinks);
  FHyperlinks := TDocxHyperlinkList.Create(True);
  FRidCounter := 1;      { rId1 занят styles.xml }
  FDrawingCounter := 0;
end;

{ ===================== Метаданные FB2 -> DOCX ===================== }

function TFb2ToDocxConverter.BookTitle(TI: TTitleInfo): UnicodeString;
begin
  if (TI <> nil) and (TI.BookTitle <> nil) and (TI.BookTitle.Value <> '') then
    Result := TI.BookTitle.Value
  else
    Result := 'Untitled';
end;

function TFb2ToDocxConverter.CreatorList(TI: TTitleInfo): TTextList;
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

function TFb2ToDocxConverter.LanguageOf(TI: TTitleInfo): UnicodeString;
begin
  if (TI <> nil) and (TI.Lang <> '') then
    Result := TI.Lang
  else
    Result := 'ru';
end;

function TFb2ToDocxConverter.IdentifierOf(DI: TDocumentInfo): UnicodeString;
begin
  if (DI <> nil) and (DI.Id <> '') then
    Result := DI.Id
  else
    Result := NewUuidHex;
end;

function TFb2ToDocxConverter.DateOf(TI: TTitleInfo;
  DI: TDocumentInfo): UnicodeString;
begin
  Result := '';
  if (TI <> nil) and (TI.Date <> nil) and (TI.Date.Value <> '') then
    Exit(TI.Date.Value);
  if (DI <> nil) and (DI.Date <> nil) and (DI.Date.Value <> '') then
    Exit(DI.Date.Value);
end;

function TFb2ToDocxConverter.AnnotationText(TI: TTitleInfo): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
  Item: TFb2Object;
  S: UnicodeString;
begin
  Result := '';
  if (TI = nil) or (TI.Annotation = nil) then
    Exit;
  Parts := TTextList.Create;
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
        Parts.Add(S);
    end;
    Result := JoinText(Parts, ' ');
  finally
    Parts.Free;
  end;
end;

function TFb2ToDocxConverter.NewRid: UnicodeString;
begin
  Inc(FRidCounter);
  Result := 'rId' + IntToStr(FRidCounter);
end;

function TFb2ToDocxConverter.NextDrawingId: Integer;
begin
  Inc(FDrawingCounter);
  Result := FDrawingCounter;
end;

{ ===================== Изображения ===================== }

procedure TFb2ToDocxConverter.CollectImages(Binaries: TFb2ObjectList);
var
  I: Integer;
  Bin: TBinary;
  Data: TBytes;
  MediaType, Extension, RelId, FileName: UnicodeString;
  W, H: Integer;
  WEmu, HEmu: Int64;
  Img: TDocxImage;
  Idx: Integer;
begin
  if Binaries = nil then
    Exit;
  for I := 0 to Binaries.Count - 1 do
  begin
    Bin := TBinary(Binaries[I]);
    try
      Data := FParser.BinaryData(Bin);
    except
      Continue;
    end;
    MediaType := LowerCase(Bin.ContentType);
    Extension := ExtByMediaType(MediaType);
    ComputeImageSize(Data, MediaType, W, H);
    ScaleDimensions(W, H, WEmu, HEmu);

    RelId := NewRid;
    FileName := 'image' + IntToStr(FImages.Count + 1) + '.' + Extension;
    Img := TDocxImage.Create;
    Img.RelId := RelId;
    Img.FileName := FileName;
    Img.Extension := Extension;
    Img.MediaType := MediaType;
    Img.Data := Data;
    Img.WidthEmu := WEmu;
    Img.HeightEmu := HEmu;
    FImages.Add(Img);
    Idx := FImages.Count - 1;

    if Bin.Id <> '' then
      MapSet(FImageMap, Bin.Id, IntToStr(Idx));
    if Bin.Id <> '' then
      MapSet(FImageMap, '#' + Bin.Id, IntToStr(Idx));
  end;
end;

function TFb2ToDocxConverter.ImageByHref(const Href: UnicodeString): TDocxImage;
var
  S, Key: UnicodeString;
  Idx: Integer;
begin
  Result := nil;
  if Href = '' then
    Exit;
  S := MapGet(FImageMap, Href);
  if S = '' then
  begin
    Key := Href;
    while (Key <> '') and (Key[1] = '#') do
      Delete(Key, 1, 1);
    S := MapGet(FImageMap, Key);
  end;
  if S = '' then
    Exit;
  Idx := StrToIntDef(S, -1);
  if (Idx >= 0) and (Idx < FImages.Count) then
    Result := FImages[Idx];
end;

function TFb2ToDocxConverter.ComputeImageSize(const Data: TBytes;
  const MediaType: UnicodeString; out W, H: Integer): Boolean;
var
  Sz: TImageSize;
begin
  Sz := fb2_images.ImageSize(Data, MediaType);
  if Sz.Valid and (Sz.Width > 0) and (Sz.Height > 0) then
  begin
    W := Sz.Width;
    H := Sz.Height;
    Result := True;
  end
  else
  begin
    W := DEFAULT_IMAGE_WIDTH;
    H := DEFAULT_IMAGE_HEIGHT;
    Result := False;
  end;
end;

procedure TFb2ToDocxConverter.ScaleDimensions(W, H: Integer;
  out WEmu, HEmu: Int64);
var
  Ratio: Double;
begin
  if (W <= 0) or (H <= 0) then
  begin
    W := DEFAULT_IMAGE_WIDTH;
    H := DEFAULT_IMAGE_HEIGHT;
  end;
  WEmu := Int64(W) * EMU_PER_PIXEL;
  HEmu := Int64(H) * EMU_PER_PIXEL;
  if WEmu > FMaxImageWidthEmu then
  begin
    Ratio := FMaxImageWidthEmu / WEmu;
    WEmu := FMaxImageWidthEmu;
    HEmu := Trunc(HEmu * Ratio);
  end;
end;

function TFb2ToDocxConverter.CoverImage(TI: TTitleInfo): TDocxImage;
var
  I: Integer;
  DI: TDocxImage;
begin
  Result := nil;
  if (TI = nil) or (TI.Coverpage = nil) then
    Exit;
  for I := 0 to TI.Coverpage.Images.Count - 1 do
  begin
    DI := ImageByHref(TImage(TI.Coverpage.Images[I]).Href);
    if DI <> nil then
      Exit(DI);
  end;
end;

{ ===================== Построение документа ===================== }

{ Свойства run по умолчанию (все выключены). }
function Props0: TDocxProps;
begin
  Result.Bold := False;
  Result.Italic := False;
  Result.Strike := False;
  Result.Code := False;
  Result.Link := False;
  Result.Vert := '';
  Result.Sz := 0;
end;

{ Объединить непустые части. }
function JoinParts(Parts: TTextList): UnicodeString;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to Parts.Count - 1 do
    if Parts[I] <> '' then
      Result := Result + Parts[I];
end;

function TFb2ToDocxConverter.RenderDocumentBody(const Title: UnicodeString;
  Creators: TTextList; const Description: UnicodeString;
  Cover: TDocxImage; Bodies: TFb2ObjectList): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
  P: TDocxProps;
begin
  Parts := TTextList.Create;
  try
    if Title <> '' then
      Parts.Add(Paragraph(Run(Title, Props0), 'Title', ''));
    for I := 0 to Creators.Count - 1 do
    begin
      P := Props0;
      P.Sz := 28;
      Parts.Add(Paragraph(Run(Creators[I], P), '', 'center'));
    end;
    if Description <> '' then
    begin
      P := Props0;
      P.Italic := True;
      Parts.Add(Paragraph(Run(Description, P), 'Quote', ''));
    end;
    if Cover <> nil then
      Parts.Add(Paragraph(Drawing(Cover, NextDrawingId), '', 'center'));
    if (Title <> '') or (Creators.Count > 0) or (Description <> '') or
      (Cover <> nil) then
      Parts.Add('<w:p/>');
    if Bodies <> nil then
      for I := 0 to Bodies.Count - 1 do
        Parts.Add(RenderBody(TBody(Bodies[I])));
    Result := JoinParts(Parts);
  finally
    Parts.Free;
  end;
end;

function TFb2ToDocxConverter.RenderBody(Body: TBody): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
begin
  Parts := TTextList.Create;
  try
    if Body.Title <> nil then
      Parts.Add(RenderTitle(Body.Title, 1));
    for I := 0 to Body.Epigraphs.Count - 1 do
      Parts.Add(RenderEpigraph(TEpigraph(Body.Epigraphs[I])));
    if Body.Image <> nil then
      Parts.Add(RenderBlockImage(Body.Image));
    for I := 0 to Body.Sections.Count - 1 do
      Parts.Add(RenderSection(TSection(Body.Sections[I]), 1));
    Result := JoinParts(Parts);
  finally
    Parts.Free;
  end;
end;

function TFb2ToDocxConverter.RenderSection(Section: TSection;
  Level: Integer): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
begin
  Parts := TTextList.Create;
  try
    if Section.Title <> nil then
      Parts.Add(RenderTitle(Section.Title, Level));
    for I := 0 to Section.Epigraphs.Count - 1 do
      Parts.Add(RenderEpigraph(TEpigraph(Section.Epigraphs[I])));
    if Section.Image <> nil then
      Parts.Add(RenderBlockImage(Section.Image));
    if Section.Annotation <> nil then
      Parts.Add(RenderAnnotation(Section.Annotation));
    for I := 0 to Section.Content.Count - 1 do
      Parts.Add(RenderBlock(TFb2Object(Section.Content[I])));
    for I := 0 to Section.Sections.Count - 1 do
      Parts.Add(RenderSection(TSection(Section.Sections[I]), Level + 1));
    Result := JoinParts(Parts);
  finally
    Parts.Free;
  end;
end;

function TFb2ToDocxConverter.RenderTitle(Title: TTitle;
  Level: Integer): UnicodeString;
var
  Style, Runs, Text: UnicodeString;
  I: Integer;
  Item: TFb2Object;
begin
  Result := '';
  if Title = nil then
    Exit;
  if Level < 1 then
    Level := 1;
  if Level > 6 then
    Level := 6;
  Style := 'Heading' + IntToStr(Level);
  Runs := '';
  for I := 0 to Title.Items.Count - 1 do
  begin
    Item := Title.Items[I];
    if Item is TParagraph then
    begin
      Text := RenderMarkup(TParagraph(Item).Content, Props0);
      if Text <> '' then
      begin
        if Runs <> '' then
          Runs := Runs + Run(' ', Props0);
        Runs := Runs + Text;
      end;
    end;
  end;
  Result := Paragraph(Runs, Style, '');
end;

function TFb2ToDocxConverter.RenderEpigraph(E: TEpigraph): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
  Item: TFb2Object;
begin
  Parts := TTextList.Create;
  try
    for I := 0 to E.Items.Count - 1 do
    begin
      Item := E.Items[I];
      if Item is TParagraph then
        Parts.Add(Paragraph(RenderMarkup(TParagraph(Item).Content, Props0),
          'Quote', ''))
      else
        Parts.Add(RenderBlock(Item));
    end;
    for I := 0 to E.TextAuthor.Count - 1 do
      Parts.Add(Paragraph(
        RenderMarkup(TParagraph(E.TextAuthor[I]).Content, Props0),
        'Quote', ''));
    Result := JoinParts(Parts);
  finally
    Parts.Free;
  end;
end;

function TFb2ToDocxConverter.RenderAnnotation(A: TAnnotation): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
begin
  Parts := TTextList.Create;
  try
    for I := 0 to A.Items.Count - 1 do
      Parts.Add(RenderBlock(TFb2Object(A.Items[I])));
    Result := JoinParts(Parts);
  finally
    Parts.Free;
  end;
end;

function TFb2ToDocxConverter.RenderBlock(Block: TFb2Object): UnicodeString;
begin
  if Block is TParagraph then
    Result := Paragraph(RenderMarkup(TParagraph(Block).Content, Props0))
  else if Block is TSubtitle then
    Result := Paragraph(RenderMarkup(TSubtitle(Block).Content, Props0),
      'Subtitle', '')
  else if Block is TEmptyLine then
    Result := '<w:p/>'
  else if Block is TCite then
    Result := RenderCite(TCite(Block))
  else if Block is TPoem then
    Result := RenderPoem(TPoem(Block))
  else if Block is TTable then
    Result := RenderTable(TTable(Block))
  else if Block is TImage then
    Result := RenderBlockImage(TImage(Block))
  else
    Result := '';
end;

function TFb2ToDocxConverter.Paragraph(const Runs: UnicodeString;
  const Style: UnicodeString; const Jc: UnicodeString): UnicodeString;
var
  Props, Ppr: UnicodeString;
begin
  Props := '';
  if Style <> '' then
    Props := Props + '<w:pStyle w:val="' + Style + '"/>';
  if Jc <> '' then
    Props := Props + '<w:jc w:val="' + Jc + '"/>';
  if Props <> '' then
    Ppr := '<w:pPr>' + Props + '</w:pPr>'
  else
    Ppr := '';
  Result := '<w:p>' + Ppr + Runs + '</w:p>';
end;

function TFb2ToDocxConverter.RenderCite(C: TCite): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
  Item: TFb2Object;
begin
  Parts := TTextList.Create;
  try
    for I := 0 to C.Items.Count - 1 do
    begin
      Item := C.Items[I];
      if Item is TParagraph then
        Parts.Add(Paragraph(RenderMarkup(TParagraph(Item).Content, Props0),
          'Quote', ''))
      else
        Parts.Add(RenderBlock(Item));
    end;
    for I := 0 to C.TextAuthor.Count - 1 do
      Parts.Add(Paragraph(
        RenderMarkup(TParagraph(C.TextAuthor[I]).Content, Props0),
        'Quote', ''));
    Result := JoinParts(Parts);
  finally
    Parts.Free;
  end;
end;

function TFb2ToDocxConverter.RenderPoem(P: TPoem): UnicodeString;
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
        Parts.Add(Paragraph(RenderMarkup(TSubtitle(Item).Content, Props0),
          'Subtitle', ''));
    end;
    for I := 0 to P.TextAuthor.Count - 1 do
      Parts.Add(Paragraph(
        RenderMarkup(TParagraph(P.TextAuthor[I]).Content, Props0),
        'Quote', ''));
    Result := JoinParts(Parts);
  finally
    Parts.Free;
  end;
end;

function TFb2ToDocxConverter.RenderStanza(S: TStanza): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
begin
  Parts := TTextList.Create;
  try
    if S.Subtitle <> nil then
      Parts.Add(Paragraph(RenderMarkup(S.Subtitle.Content, Props0),
        'Subtitle', ''));
    for I := 0 to S.Verses.Count - 1 do
      Parts.Add(Paragraph(
        RenderMarkup(TParagraph(S.Verses[I]).Content, Props0),
        'PoemLine', ''));
    Result := JoinParts(Parts);
  finally
    Parts.Free;
  end;
end;

function TFb2ToDocxConverter.RenderTable(T: TTable): UnicodeString;
const
  BORDERS =
    '<w:tblBorders>' +
    '<w:top w:val="single" w:sz="4" w:space="0" w:color="auto"/>' +
    '<w:left w:val="single" w:sz="4" w:space="0" w:color="auto"/>' +
    '<w:bottom w:val="single" w:sz="4" w:space="0" w:color="auto"/>' +
    '<w:right w:val="single" w:sz="4" w:space="0" w:color="auto"/>' +
    '<w:insideH w:val="single" w:sz="4" w:space="0" w:color="auto"/>' +
    '<w:insideV w:val="single" w:sz="4" w:space="0" w:color="auto"/>' +
    '</w:tblBorders>';
var
  Rows, Cells: TTextList;
  I, J: Integer;
  Row: TTableRow;
  Cell: TTableCell;
  P: TDocxProps;
  Runs: UnicodeString;
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
          P := Props0;
          if Cell.IsHeader then
            P.Bold := True;
          Runs := RenderMarkup(Cell.Children, P);
          Cells.Add('<w:tc><w:tcPr><w:tcW w:w="0" w:type="auto"/></w:tcPr>' +
            Paragraph(Runs, '', '') + '</w:tc>');
        end;
        Rows.Add('<w:tr>' + JoinText(Cells, '') + '</w:tr>');
      finally
        Cells.Free;
      end;
    end;
    Result := '<w:tbl><w:tblPr><w:tblW w:w="0" w:type="auto"/>' + BORDERS +
      '</w:tblPr>' + JoinText(Rows, '') + '</w:tbl><w:p/>';
  finally
    Rows.Free;
  end;
end;

function TFb2ToDocxConverter.RenderBlockImage(Img: TImage): UnicodeString;
var
  DI: TDocxImage;
begin
  Result := '';
  DI := ImageByHref(Img.Href);
  if DI = nil then
    Exit;
  Result := Paragraph(Drawing(DI, NextDrawingId), '', 'center');
end;

{ ===================== Inline-разметка ===================== }

function TFb2ToDocxConverter.RenderMarkup(Nodes: TFb2ObjectList;
  const Props: TDocxProps): UnicodeString;
var
  I: Integer;
  Node: TStyleNode;
  Tag: UnicodeString;
  P: TDocxProps;
begin
  Result := '';
  if Nodes = nil then
    Exit;
  for I := 0 to Nodes.Count - 1 do
  begin
    Node := TStyleNode(Nodes[I]);
    Tag := Node.Tag;
    if Tag = TEXT_NODE_NAME then
      Result := Result + Run(Node.Text, Props)
    else if Tag = 'strong' then
    begin
      P := Props;
      P.Bold := True;
      Result := Result + RenderMarkup(Node.Children, P);
    end
    else if Tag = 'emphasis' then
    begin
      P := Props;
      P.Italic := True;
      Result := Result + RenderMarkup(Node.Children, P);
    end
    else if Tag = 'strikethrough' then
    begin
      P := Props;
      P.Strike := True;
      Result := Result + RenderMarkup(Node.Children, P);
    end
    else if Tag = 'sub' then
    begin
      P := Props;
      P.Vert := 'subscript';
      Result := Result + RenderMarkup(Node.Children, P);
    end
    else if Tag = 'sup' then
    begin
      P := Props;
      P.Vert := 'superscript';
      Result := Result + RenderMarkup(Node.Children, P);
    end
    else if Tag = 'code' then
    begin
      P := Props;
      P.Code := True;
      Result := Result + RenderMarkup(Node.Children, P);
    end
    else if Tag = 'style' then
      Result := Result + RenderMarkup(Node.Children, Props)
    else if Tag = 'a' then
      Result := Result + RenderHyperlink(Node, Props)
    else if Tag = 'image' then
      Result := Result + ImageRun(Node);
  end;
end;

function TFb2ToDocxConverter.Run(const Text: UnicodeString;
  const Props: TDocxProps): UnicodeString;
begin
  if Text = '' then
    Exit('');
  Result := '<w:r>' + RunProps(Props) +
    '<w:t xml:space="preserve">' + XmlEscape(Text) + '</w:t></w:r>';
end;

function TFb2ToDocxConverter.RunProps(const Props: TDocxProps): UnicodeString;
var
  Parts: TTextList;
begin
  Parts := TTextList.Create;
  try
    if Props.Link then
      Parts.Add('<w:rStyle w:val="Hyperlink"/>')
    else if Props.Code then
      Parts.Add('<w:rStyle w:val="Code"/>');
    if Props.Bold then
      Parts.Add('<w:b/>');
    if Props.Italic then
      Parts.Add('<w:i/>');
    if Props.Strike then
      Parts.Add('<w:strike/>');
    if Props.Vert <> '' then
      Parts.Add('<w:vertAlign w:val="' + Props.Vert + '"/>');
    if Props.Sz <> 0 then
      Parts.Add('<w:sz w:val="' + IntToStr(Props.Sz) + '"/>');
    if Parts.Count = 0 then
      Result := ''
    else
      Result := '<w:rPr>' + JoinText(Parts, '') + '</w:rPr>';
  finally
    Parts.Free;
  end;
end;

function TFb2ToDocxConverter.RenderHyperlink(Node: TStyleNode;
  const Props: TDocxProps): UnicodeString;
var
  P: TDocxProps;
  Inner, Href, RelId: UnicodeString;
  Hl: TDocxHyperlink;
begin
  P := Props;
  P.Link := True;
  Inner := RenderMarkup(Node.Children, P);
  Href := Node.Href;
  if Href = '' then
    Exit(Inner);
  RelId := NewRid;
  Hl := TDocxHyperlink.Create;
  Hl.RelId := RelId;
  Hl.Url := Href;
  FHyperlinks.Add(Hl);
  Result := '<w:hyperlink r:id="' + RelId + '">' + Inner + '</w:hyperlink>';
end;

function TFb2ToDocxConverter.ImageRun(Node: TStyleNode): UnicodeString;
var
  DI: TDocxImage;
begin
  Result := '';
  DI := ImageByHref(Node.ImageHref);
  if DI = nil then
    Exit;
  Result := Drawing(DI, NextDrawingId);
end;

function TFb2ToDocxConverter.Drawing(Image: TDocxImage;
  DrawingId: Integer): UnicodeString;
var
  Cx, Cy, Id: UnicodeString;
begin
  Cx := IntToStr(Image.WidthEmu);
  Cy := IntToStr(Image.HeightEmu);
  Id := IntToStr(DrawingId);
  Result :=
    '<w:r><w:drawing>' +
    '<wp:inline distT="0" distB="0" distL="0" distR="0">' +
    '<wp:extent cx="' + Cx + '" cy="' + Cy + '"/>' +
    '<wp:effectExtent l="0" t="0" r="0" b="0"/>' +
    '<wp:docPr id="' + Id + '" name="Picture ' + Id + '"/>' +
    '<wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/>' +
    '</wp:cNvGraphicFramePr>' +
    '<a:graphic>' +
    '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
    '<pic:pic>' +
    '<pic:nvPicPr><pic:cNvPr id="' + Id + '" name="' + Image.FileName +
    '"/><pic:cNvPicPr/></pic:nvPicPr>' +
    '<pic:blipFill><a:blip r:embed="' + Image.RelId +
    '"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>' +
    '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="' + Cx + '" cy="' + Cy +
    '"/></a:xfrm>' +
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>' +
    '</pic:pic></a:graphicData></a:graphic></wp:inline>' +
    '</w:drawing></w:r>';
end;

{ ===================== Метафайлы DOCX ===================== }

function TFb2ToDocxConverter.ContentTypes(Book: TDocxBook): UnicodeString;
var
  Parts: TTextList;
  Exts: TStringList;
  I: Integer;
  MT: UnicodeString;
begin
  Parts := TTextList.Create;
  Exts := TStringList.Create;
  try
    Exts.Sorted := True;
    Exts.Duplicates := dupIgnore;
    for I := 0 to Book.Images.Count - 1 do
      Exts.Add(Book.Images[I].Extension);
    Parts.Add('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>');
    Parts.Add('<Types xmlns="' + NS_CT + '">');
    Parts.Add('<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>');
    Parts.Add('<Default Extension="xml" ContentType="application/xml"/>');
    for I := 0 to Exts.Count - 1 do
    begin
      MT := MediaTypeByExt(Exts[I]);
      if MT <> '' then
        Parts.Add('<Default Extension="' + Exts[I] + '" ContentType="' +
          MT + '"/>');
    end;
    Parts.Add('<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>');
    Parts.Add('<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>');
    Parts.Add('<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>');
    Parts.Add('<Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>');
    Parts.Add('</Types>');
    Result := JoinText(Parts, '');
  finally
    Exts.Free;
    Parts.Free;
  end;
end;

function TFb2ToDocxConverter.RootRels: UnicodeString;
begin
  Result :=
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
    '<Relationships xmlns="' + NS_REL + '">' +
    '<Relationship Id="rId1" Type="' + REL_OFFICE +
    '" Target="word/document.xml"/>' +
    '<Relationship Id="rId2" Type="' + REL_CORE +
    '" Target="docProps/core.xml"/>' +
    '<Relationship Id="rId3" Type="' + REL_APP +
    '" Target="docProps/app.xml"/>' +
    '</Relationships>';
end;

function TFb2ToDocxConverter.DocumentRels(Book: TDocxBook): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
begin
  Parts := TTextList.Create;
  try
    Parts.Add('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>');
    Parts.Add('<Relationships xmlns="' + NS_REL + '">');
    Parts.Add('<Relationship Id="rId1" Type="' + REL_STYLES +
      '" Target="styles.xml"/>');
    for I := 0 to Book.Images.Count - 1 do
      Parts.Add('<Relationship Id="' + Book.Images[I].RelId + '" Type="' +
        REL_IMAGE + '" Target="media/' + Book.Images[I].FileName + '"/>');
    for I := 0 to Book.Hyperlinks.Count - 1 do
      Parts.Add('<Relationship Id="' + Book.Hyperlinks[I].RelId + '" Type="' +
        REL_HYPERLINK + '" Target="' + XmlEscape(Book.Hyperlinks[I].Url) +
        '" TargetMode="External"/>');
    Parts.Add('</Relationships>');
    Result := JoinText(Parts, '');
  finally
    Parts.Free;
  end;
end;

function TFb2ToDocxConverter.DocumentXml(Book: TDocxBook): UnicodeString;
begin
  Result :=
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
    '<w:document xmlns:w="' + NS_W + '" xmlns:r="' + NS_R + '" ' +
    'xmlns:wp="' + NS_WP + '" xmlns:a="' + NS_A + '" xmlns:pic="' + NS_PIC +
    '">' +
    '<w:body>' + Book.DocumentXml +
    '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>' +
    '<w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1134" ' +
    'w:header="709" w:footer="709" w:gutter="0"/>' +
    '</w:sectPr>' +
    '</w:body></w:document>';
end;

function TFb2ToDocxConverter.StylesXml: UnicodeString;
var
  Headings: UnicodeString;
  Level, Size: Integer;
begin
  Headings := '';
  for Level := 1 to 6 do
  begin
    Size := 28 - (Level - 1) * 2;
    if Size < 22 then
      Size := 22;
    Headings := Headings +
      '<w:style w:type="paragraph" w:styleId="Heading' + IntToStr(Level) + '">' +
      '<w:name w:val="heading ' + IntToStr(Level) +
      '"/><w:basedOn w:val="Normal"/>' +
      '<w:next w:val="Normal"/>' +
      '<w:pPr><w:keepNext/><w:spacing w:before="240" w:after="120"/>' +
      '<w:outlineLvl w:val="' + IntToStr(Level - 1) + '"/></w:pPr>' +
      '<w:rPr><w:b/><w:sz w:val="' + IntToStr(Size) + '"/></w:rPr></w:style>';
  end;
  Result :=
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
    '<w:styles xmlns:w="' + NS_W + '">' +
    '<w:docDefaults><w:rPrDefault><w:rPr>' +
    '<w:rFonts w:ascii="Times New Roman" w:hAnsi="Times New Roman" w:cs="Times New Roman"/>' +
    '<w:sz w:val="24"/><w:szCs w:val="24"/>' +
    '</w:rPr></w:rPrDefault>' +
    '<w:pPrDefault><w:pPr><w:spacing w:after="120" w:line="240" w:lineRule="auto"/></w:pPr></w:pPrDefault>' +
    '</w:docDefaults>' +
    '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>' +
    Headings +
    '<w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/>' +
    '<w:basedOn w:val="Normal"/><w:pPr><w:jc w:val="center"/>' +
    '<w:spacing w:before="240" w:after="240"/></w:pPr>' +
    '<w:rPr><w:b/><w:sz w:val="36"/></w:rPr></w:style>' +
    '<w:style w:type="paragraph" w:styleId="Subtitle"><w:name w:val="Subtitle"/>' +
    '<w:basedOn w:val="Normal"/><w:pPr><w:jc w:val="center"/></w:pPr>' +
    '<w:rPr><w:b/></w:rPr></w:style>' +
    '<w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/>' +
    '<w:basedOn w:val="Normal"/><w:pPr><w:ind w:left="720" w:right="720"/></w:pPr>' +
    '<w:rPr><w:i/></w:rPr></w:style>' +
    '<w:style w:type="paragraph" w:styleId="PoemLine"><w:name w:val="Poem Line"/>' +
    '<w:basedOn w:val="Normal"/><w:pPr><w:ind w:left="720"/>' +
    '<w:spacing w:after="0"/></w:pPr></w:style>' +
    '<w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/>' +
    '<w:rPr><w:color w:val="0563C1"/><w:u w:val="single"/></w:rPr></w:style>' +
    '<w:style w:type="character" w:styleId="Code"><w:name w:val="Code"/>' +
    '<w:rPr><w:rFonts w:ascii="Courier New" w:hAnsi="Courier New"/></w:rPr></w:style>' +
    '</w:styles>';
end;

function TFb2ToDocxConverter.CoreXml(Book: TDocxBook): UnicodeString;
var
  Creators, LastModified: UnicodeString;
  I: Integer;
begin
  Creators := '';
  for I := 0 to Book.Creators.Count - 1 do
    Creators := Creators + '<dc:creator>' + XmlEscape(Book.Creators[I]) +
      '</dc:creator>';
  if Book.Creators.Count > 0 then
    LastModified := XmlEscape(Book.Creators[0])
  else
    LastModified := '';
  Result :=
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
    '<cp:coreProperties ' +
    'xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" ' +
    'xmlns:dc="http://purl.org/dc/elements/1.1/" ' +
    'xmlns:dcterms="http://purl.org/dc/terms/" ' +
    'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">' +
    '<dc:title>' + XmlEscape(Book.Title) + '</dc:title>' +
    Creators +
    '<cp:lastModifiedBy>' + LastModified + '</cp:lastModifiedBy>' +
    '<dc:language>' + XmlEscape(Book.Language) + '</dc:language>' +
    '<dc:identifier>' + XmlEscape(Book.Identifier) + '</dc:identifier>' +
    '<dc:description>' + XmlEscape(Book.Description) + '</dc:description>' +
    '</cp:coreProperties>';
end;

function TFb2ToDocxConverter.AppXml: UnicodeString;
begin
  Result :=
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
    '<Properties ' +
    'xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" ' +
    'xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">' +
    '<Application>pyFB2</Application>' +
    '</Properties>';
end;

{ ===================== Публичный API ===================== }

function TFb2ToDocxConverter.Convert(const Source: UnicodeString): TDocxBook;
var
  Desc: TDescription;
  Bodies, Binaries: TFb2ObjectList;
  TI: TTitleInfo;
  DI: TDocumentInfo;
  Title, DescText, DocXml: UnicodeString;
  Cr: TTextList;
  Cover: TDocxImage;
begin
  if Source <> '' then
    FSource := Source;
  Reset;

  FParser.LoadFile(FSource);
  Desc := FParser.Parse;
  Bodies := FParser.ParseBodies;
  Binaries := FParser.ParseBinaries;
  Cr := nil;
  try
    TI := nil;
    DI := nil;
    if Desc <> nil then
    begin
      TI := Desc.TitleInfo;
      DI := Desc.DocumentInfo;
    end;

    Title := BookTitle(TI);
    Cr := CreatorList(TI);
    DescText := AnnotationText(TI);
    CollectImages(Binaries);
    Cover := CoverImage(TI);
    DocXml := RenderDocumentBody(Title, Cr, DescText, Cover, Bodies);

    FreeAndNil(FBook);
    FBook := TDocxBook.Create;
    FBook.Title := Title;
    FBook.Language := LanguageOf(TI);
    FBook.Identifier := IdentifierOf(DI);
    FBook.Date := DateOf(TI, DI);
    FBook.Description := DescText;
    FBook.DocumentXml := DocXml;
    FreeAndNil(FBook.Creators);
    FBook.Creators := Cr;
    Cr := nil;
    FreeAndNil(FBook.Images);
    FBook.Images := FImages;
    FImages := nil;
    FreeAndNil(FBook.Hyperlinks);
    FBook.Hyperlinks := FHyperlinks;
    FHyperlinks := nil;
    Result := FBook;
  finally
    Cr.Free;
    Binaries.Free;
    Bodies.Free;
    Desc.Free;
  end;
end;

function TFb2ToDocxConverter.ToBytes(Book: TDocxBook): TBytes;
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
      AddTextEntry(Z, '[Content_Types].xml', ContentTypes(Book));
      AddTextEntry(Z, '_rels/.rels', RootRels);
      AddTextEntry(Z, 'word/document.xml', DocumentXml(Book));
      AddTextEntry(Z, 'word/_rels/document.xml.rels', DocumentRels(Book));
      AddTextEntry(Z, 'word/styles.xml', StylesXml);
      AddTextEntry(Z, 'docProps/core.xml', CoreXml(Book));
      AddTextEntry(Z, 'docProps/app.xml', AppXml);
      for I := 0 to Book.Images.Count - 1 do
        AddDataEntry(Z, 'word/media/' + Book.Images[I].FileName,
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

function TFb2ToDocxConverter.Write(const Source: UnicodeString;
  const Output: UnicodeString): UnicodeString;
var
  Bk: TDocxBook;
  Data: TBytes;
  Target: UnicodeString;
begin
  Bk := Convert(Source);
  Data := ToBytes(Bk);
  if Output <> '' then
    Target := Output
  else if FSource <> '' then
    Target := ChangeFileExt(FSource, '.docx')
  else
    Target := 'book.docx';
  WriteFileAtomic(Target, Data);
  Result := Target;
end;

end.
