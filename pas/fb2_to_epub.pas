unit fb2_to_epub;
{ Преобразование FictionBook (FB2) в книгу EPUB — перевод fb2_to_epub.py.

  Читает FB2 (через TFb2Parser), извлекает метаданные, текст и встроенные
  изображения и собирает EPUB-архив (ZIP): mimetype, META-INF/container.xml,
  OPF-манифест, оглавление (NCX и/или XHTML Navigation Document),
  XHTML-документы и изображения.

  Поддерживаются обе версии:
      * EPUB 2.0 (по умолчанию) — OPF 2.0, toc.ncx, XHTML 1.1;
      * EPUB 3.0 (EpubVersion = 3) — OPF 3.0, nav.xhtml, properties="nav"/
        "cover-image", обязательный <meta property="dcterms:modified">,
        HTML5-doctype (toc.ncx пишется дополнительно для совместимости).

  Промежуточное представление — TEpubBook (метаданные + документы + ресурсы);
  сериализуется в байты (ToBytes) или пишется в файл (Write).

  Пример:
      C := TFb2ToEpubConverter.Create;
      try
        C.Write('book.fb2', 'book.epub');
      finally
        C.Free;
      end;

  Особенности перевода с Python:
      * ZIP пишется через TZipper (paszlib); mimetype кладётся первым и
        без сжатия (clNone) — требование EPUB;
      * источник задаётся путём к файлу;
      * html.escape -> HtmlEscape. }

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Classes, SysUtils, fgl,
  fb2_structures, fb2_parser, fb2_errors, fb2_files;

const
  { Пространства имён EPUB. }
  NS_CONTAINER = 'urn:oasis:names:tc:opendocument:xmlns:container';
  NS_OPF = 'http://www.idpf.org/2007/opf';
  NS_DC = 'http://purl.org/dc/elements/1.1/';
  NS_NCX = 'http://www.daisy.org/z3986/2005/ncx/';
  NS_XHTML = 'http://www.w3.org/1999/xhtml';
  NS_EPUB = 'http://www.idpf.org/2007/ops';

  { Версия EPUB по умолчанию (2 — EPUB 2.0, 3 — EPUB 3.0). }
  DEFAULT_EPUB_VERSION = 2;

  { Заголовок оглавления в nav.xhtml (EPUB 3). }
  TOC_TITLE = 'Оглавление';

  { Простой CSS для EPUB. }
  DEFAULT_CSS =
    'body { font-family: serif; line-height: 1.4; }' + #10 +
    'h1, h2, h3, h4, h5, h6 { text-align: center; }' + #10 +
    'p { margin: 0; text-indent: 1.2em; }' + #10 +
    'p.subtitle { text-align: center; font-weight: bold; text-indent: 0;' +
    ' margin: 1em 0; }' + #10 +
    'p.empty-line { text-indent: 0; height: 1em; }' + #10 +
    'blockquote { margin: 1em 2em; }' + #10 +
    'blockquote.epigraph { font-style: italic; }' + #10 +
    'div.poem { margin: 1em 2em; }' + #10 +
    'div.poem p { text-indent: 0; }' + #10 +
    'div.image, div.cover { text-align: center; margin: 1em 0; }' + #10 +
    'table { border-collapse: collapse; margin: 1em auto; }' + #10 +
    'td, th { border: 1px solid #888; padding: 0.2em 0.5em; }' + #10;

type
  { Файл-ресурс EPUB (изображение, CSS и т. п.). }
  TEpubResource = class
  public
    Id: UnicodeString;
    Href: UnicodeString;
    MediaType: UnicodeString;
    Data: TBytes;
  end;

  TEpubResourceList = specialize TFPGObjectList<TEpubResource>;

  { XHTML-документ EPUB. }
  TEpubDocument = class
  public
    Id: UnicodeString;
    Href: UnicodeString;
    Title: UnicodeString;
    Content: UnicodeString;
  end;

  TEpubDocumentList = specialize TFPGObjectList<TEpubDocument>;

  { Промежуточное представление EPUB-книги. }
  TEpubBook = class
  public
    Title: UnicodeString;
    Creators: TTextList;
    Language: UnicodeString;
    Identifier: UnicodeString;
    Date: UnicodeString;
    Description: UnicodeString;
    Subjects: TTextList;
    CoverId: UnicodeString;
    HasCover: Boolean;
    Resources: TEpubResourceList;
    Documents: TEpubDocumentList;
    Version: Integer;
    constructor Create;
    destructor Destroy; override;
  end;

  { Преобразование книги FB2 в EPUB. }
  TFb2ToEpubConverter = class
  private
    FParser: TFb2Parser;
    FCss: UnicodeString;
    FEpubVersion: Integer;
    FTocTitle: UnicodeString;
    FSource: UnicodeString;
    FBook: TEpubBook;

    function BuildDocuments(Bodies: TFb2ObjectList;
      ImageMap: TStringList): TEpubDocumentList;
    function BodyTitleDocument(Body: TBody; Number: Integer;
      ImageMap: TStringList): TEpubDocument;
    function BodyDocument(Body: TBody; Number: Integer;
      ImageMap: TStringList): TEpubDocument;
    function SectionDocument(Section: TSection; Number: Integer;
      ImageMap: TStringList): TEpubDocument;
    function CoverDocument(const CoverHref: UnicodeString): TEpubDocument;
    function Xhtml(const Title, BodyHtml: UnicodeString): UnicodeString;
    function RenderSection(Section: TSection; Level: Integer;
      ImageMap: TStringList): UnicodeString;
    function RenderTitle(Title: TTitle; Level: Integer;
      ImageMap: TStringList): UnicodeString;
    function RenderEpigraph(E: TEpigraph; ImageMap: TStringList): UnicodeString;
    function RenderAnnotation(A: TAnnotation;
      ImageMap: TStringList): UnicodeString;
    function RenderBlock(Block: TFb2Object;
      ImageMap: TStringList): UnicodeString;
    function RenderParagraph(P: TParagraph; ImageMap: TStringList;
      const CssClass: UnicodeString): UnicodeString;
    function RenderSubtitle(S: TSubtitle;
      ImageMap: TStringList): UnicodeString;
    function RenderCite(C: TCite; ImageMap: TStringList): UnicodeString;
    function RenderPoem(P: TPoem; ImageMap: TStringList): UnicodeString;
    function RenderStanza(S: TStanza; ImageMap: TStringList): UnicodeString;
    function RenderTable(T: TTable; ImageMap: TStringList): UnicodeString;
    function RenderMarkup(Nodes: TFb2ObjectList;
      ImageMap: TStringList): UnicodeString;
    function RenderBlockImage(I: TImage;
      ImageMap: TStringList): UnicodeString;
    function RenderInlineImage(Node: TStyleNode;
      ImageMap: TStringList): UnicodeString;
    procedure CollectResources(Binaries: TFb2ObjectList;
      ImageMap: TStringList; Resources: TEpubResourceList);
    function CoverHref(TI: TTitleInfo;
      ImageMap: TStringList): UnicodeString;
    function ResourceId(Resources: TEpubResourceList;
      const Href: UnicodeString): UnicodeString;
    function ContainerXml: UnicodeString;
    function Opf(Book: TEpubBook): UnicodeString;
    function Opf2(Book: TEpubBook): UnicodeString;
    function Opf3(Book: TEpubBook): UnicodeString;
    function Ncx(Book: TEpubBook): UnicodeString;
    function NavXhtml(Book: TEpubBook): UnicodeString;
  public
    constructor Create(const Css: UnicodeString = DEFAULT_CSS;
      EpubVersion: Integer = DEFAULT_EPUB_VERSION;
      const TocTitle: UnicodeString = TOC_TITLE);
    destructor Destroy; override;

    { Прочитать FB2 и вернуть структуру TEpubBook (владелец — конвертер). }
    function Convert(const Source: UnicodeString): TEpubBook;

    { Сериализовать книгу в EPUB (ZIP). Book = nil — результат Convert. }
    function ToBytes(Book: TEpubBook = nil): TBytes;

    { Преобразовать FB2 в файл EPUB и вернуть путь к результату. }
    function Write(const Source: UnicodeString;
      const Output: UnicodeString = ''): UnicodeString;

    property Book: TEpubBook read FBook;
  end;

{ Экранирование HTML (аналог html.escape). }
function HtmlEscape(const S: UnicodeString; Quote: Boolean): UnicodeString;

implementation

uses
  zipper, zstream, DateUtils;

{ ===================== Служебные помощники ===================== }

function HtmlEscape(const S: UnicodeString; Quote: Boolean): UnicodeString;
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
    else if (C = '"') and Quote then
      Result := Result + '&quot;'
    else if (C = '''') and Quote then
      Result := Result + '&#x27;'
    else
      Result := Result + C;
  end;
end;

{ Объединить непустые строки списка через #10. }
function JoinNonEmpty(List: TTextList): UnicodeString;
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

{ Объединить непустые строки списка через Sep. }
function JoinNonEmptySep(List: TTextList; const Sep: UnicodeString): UnicodeString;
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

{ Тег заголовка по уровню (h1..h6). }
function HeadingTag(Level: Integer): UnicodeString;
begin
  if Level < 1 then
    Level := 1;
  if Level > 6 then
    Level := 6;
  Result := 'h' + IntToStr(Level);
end;

{ Текущая метка времени UTC (EPUB 3 dcterms:modified). }
function ModifiedTimestamp: UnicodeString;
begin
  Result := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"',
    LocalTimeToUniversal(Now));
end;

{ ===================== Метаданные FB2 ===================== }

{ Простой текст из узлов разметки. }
function MarkupTextPlain(Nodes: TFb2ObjectList): UnicodeString;
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
      Result := Result + MarkupTextPlain(Node.Children);
  end;
end;

function BookTitleOf(TI: TTitleInfo): UnicodeString;
begin
  if (TI <> nil) and (TI.BookTitle <> nil) and (TI.BookTitle.Value <> '') then
    Result := TI.BookTitle.Value
  else
    Result := 'Untitled';
end;

{ Человекочитаемое имя автора. }
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

{ Список авторов из <title-info> (владелец — вызывающий). }
function CreatorsOf(TI: TTitleInfo): TTextList;
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

function LanguageOf(TI: TTitleInfo): UnicodeString;
begin
  if (TI <> nil) and (TI.Lang <> '') then
    Result := TI.Lang
  else
    Result := 'ru';
end;

function IdentifierOf(DI: TDocumentInfo): UnicodeString;
var
  G: TGUID;
  S: UnicodeString;
  I: Integer;
begin
  if (DI <> nil) and (DI.Id <> '') then
    Exit(DI.Id);
  CreateGUID(G);
  S := GUIDToString(G);
  if (Length(S) >= 2) and (S[1] = '{') then
    S := Copy(S, 2, Length(S) - 2);
  Result := '';
  for I := 1 to Length(S) do
    if S[I] <> '-' then
      Result := Result + S[I];
end;

function DateOf(TI: TTitleInfo; DI: TDocumentInfo): UnicodeString;
begin
  Result := '';
  if (TI <> nil) and (TI.Date <> nil) and (TI.Date.Value <> '') then
    Exit(TI.Date.Value);
  if (DI <> nil) and (DI.Date <> nil) and (DI.Date.Value <> '') then
    Exit(DI.Date.Value);
end;

{ Аннотация книги как простой текст. }
function AnnotationTextOf(TI: TTitleInfo): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
  S: UnicodeString;
begin
  Result := '';
  if (TI = nil) or (TI.Annotation = nil) then
    Exit;
  Parts := TTextList.Create;
  try
    for I := 0 to TI.Annotation.Items.Count - 1 do
    begin
      if TI.Annotation.Items[I] is TParagraph then
        S := MarkupTextPlain(TParagraph(TI.Annotation.Items[I]).Content)
      else if TI.Annotation.Items[I] is TSubtitle then
        S := MarkupTextPlain(TSubtitle(TI.Annotation.Items[I]).Content)
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

{ Жанры книги (владелец — вызывающий). }
function SubjectsOf(TI: TTitleInfo): TTextList;
var
  I: Integer;
begin
  Result := TTextList.Create;
  if TI = nil then
    Exit;
  for I := 0 to TI.Genres.Count - 1 do
    Result.Add(TGenre(TI.Genres[I]).Value);
end;

{ Текст заголовка в одну строку. }
function TitleTextOf(T: TTitle): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
  S: UnicodeString;
begin
  Result := '';
  if T = nil then
    Exit;
  Parts := TTextList.Create;
  try
    for I := 0 to T.Items.Count - 1 do
      if T.Items[I] is TParagraph then
      begin
        S := MarkupTextPlain(TParagraph(T.Items[I]).Content);
        if S <> '' then
          Parts.Add(S);
      end;
    Result := JoinText(Parts, ' ');
  finally
    Parts.Free;
  end;
end;

{ ===================== TEpubBook ===================== }

constructor TEpubBook.Create;
begin
  inherited Create;
  Title := 'Untitled';
  Language := 'ru';
  Creators := TTextList.Create;
  Subjects := TTextList.Create;
  Resources := TEpubResourceList.Create;
  Documents := TEpubDocumentList.Create;
  Version := DEFAULT_EPUB_VERSION;
end;

destructor TEpubBook.Destroy;
begin
  FreeAndNil(Creators);
  FreeAndNil(Subjects);
  FreeAndNil(Resources);
  FreeAndNil(Documents);
  inherited Destroy;
end;

{ ===================== ZIP: добавление записей ===================== }

{ Добавить в архив текстовую запись (UTF-8). Поток освобождает TZipper. }
procedure AddTextEntry(Z: TZipper; const Name, Text: UnicodeString;
  Stored: Boolean);
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
  if Stored then
    E.CompressionLevel := clNone;
end;

{ Добавить в архив двоичную запись. }
procedure AddDataEntry(Z: TZipper; const Name: UnicodeString;
  const Data: TBytes);
var
  MS: TMemoryStream;
  E: TZipFileEntry;
begin
  MS := TMemoryStream.Create;
  if Length(Data) > 0 then
    MS.WriteBuffer(Data[0], Length(Data));
  MS.Position := 0;
  E := Z.Entries.AddFileEntry(MS, Name);
end;

{ ===================== TFb2ToEpubConverter ===================== }

constructor TFb2ToEpubConverter.Create(const Css: UnicodeString;
  EpubVersion: Integer; const TocTitle: UnicodeString);
begin
  inherited Create;
  FParser := TFb2Parser.Create;
  FCss := Css;
  if EpubVersion >= 3 then
    FEpubVersion := 3
  else
    FEpubVersion := 2;
  FTocTitle := TocTitle;
  FBook := nil;
end;

destructor TFb2ToEpubConverter.Destroy;
begin
  FreeAndNil(FBook);
  FreeAndNil(FParser);
  inherited Destroy;
end;

function TFb2ToEpubConverter.Convert(const Source: UnicodeString): TEpubBook;
var
  Desc: TDescription;
  Bodies, Binaries: TFb2ObjectList;
  TI: TTitleInfo;
  DI: TDocumentInfo;
  ImageMap: TStringList;
  Resources: TEpubResourceList;
  Documents: TEpubDocumentList;
  CoverH: UnicodeString;
begin
  if Source <> '' then
    FSource := Source;
  FParser.LoadFile(FSource);
  Desc := FParser.Parse;
  Bodies := FParser.ParseBodies;
  Binaries := FParser.ParseBinaries;
  Resources := nil;
  Documents := nil;
  try
    TI := nil;
    DI := nil;
    if Desc <> nil then
    begin
      TI := Desc.TitleInfo;
      DI := Desc.DocumentInfo;
    end;

    ImageMap := TStringList.Create;
    try
      Resources := TEpubResourceList.Create;
      CollectResources(Binaries, ImageMap, Resources);
      Documents := BuildDocuments(Bodies, ImageMap);
      CoverH := CoverHref(TI, ImageMap);

      FreeAndNil(FBook);
      FBook := TEpubBook.Create;
      FBook.Title := BookTitleOf(TI);
      FreeAndNil(FBook.Creators);
      FBook.Creators := CreatorsOf(TI);
      FBook.Language := LanguageOf(TI);
      FBook.Identifier := IdentifierOf(DI);
      FBook.Date := DateOf(TI, DI);
      FBook.Description := AnnotationTextOf(TI);
      FreeAndNil(FBook.Subjects);
      FBook.Subjects := SubjectsOf(TI);
      if CoverH <> '' then
      begin
        FBook.CoverId := ResourceId(Resources, CoverH);
        FBook.HasCover := FBook.CoverId <> '';
      end;
      FreeAndNil(FBook.Resources);
      FBook.Resources := Resources;
      Resources := nil;
      if CoverH <> '' then
        Documents.Insert(0, CoverDocument(CoverH));
      FreeAndNil(FBook.Documents);
      FBook.Documents := Documents;
      Documents := nil;
      FBook.Version := FEpubVersion;
    finally
      ImageMap.Free;
    end;
    Result := FBook;
  finally
    Resources.Free;
    Documents.Free;
    Bodies.Free;
    Binaries.Free;
    Desc.Free;
  end;
end;

function TFb2ToEpubConverter.ToBytes(Book: TEpubBook): TBytes;
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
      { mimetype должен идти первым и без сжатия (требование EPUB). }
      AddTextEntry(Z, 'mimetype', 'application/epub+zip', True);
      AddTextEntry(Z, 'META-INF/container.xml', ContainerXml, False);
      AddTextEntry(Z, 'OEBPS/content.opf', Opf(Book), False);
      AddTextEntry(Z, 'OEBPS/toc.ncx', Ncx(Book), False);
      if Book.Version >= 3 then
        AddTextEntry(Z, 'OEBPS/nav.xhtml', NavXhtml(Book), False);
      AddTextEntry(Z, 'OEBPS/style.css', FCss, False);
      for I := 0 to Book.Documents.Count - 1 do
        AddTextEntry(Z, 'OEBPS/' + Book.Documents[I].Href,
          Book.Documents[I].Content, False);
      for I := 0 to Book.Resources.Count - 1 do
        AddDataEntry(Z, 'OEBPS/' + Book.Resources[I].Href,
          Book.Resources[I].Data);
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

function TFb2ToEpubConverter.Write(const Source: UnicodeString;
  const Output: UnicodeString): UnicodeString;
var
  Bk: TEpubBook;
  Data: TBytes;
  Target: UnicodeString;
begin
  Bk := Convert(Source);
  Data := ToBytes(Bk);
  if Output <> '' then
    Target := Output
  else if FSource <> '' then
    Target := ChangeFileExt(FSource, '.epub')
  else
    Target := 'book.epub';
  WriteFileAtomic(Target, Data);
  Result := Target;
end;

{ Собрать изображения в ресурсы EPUB и карту ссылок FB2 -> EPUB. }
procedure TFb2ToEpubConverter.CollectResources(Binaries: TFb2ObjectList;
  ImageMap: TStringList; Resources: TEpubResourceList);
var
  I: Integer;
  Bin: TBinary;
  Data: TBytes;
  FileName, Href: UnicodeString;
  R: TEpubResource;
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
    FileName := FParser.BinaryFilename(Bin);
    Href := 'images/' + FileName;
    R := TEpubResource.Create;
    R.Id := 'img' + IntToStr(I + 1);
    R.Href := Href;
    if Bin.ContentType <> '' then
      R.MediaType := Bin.ContentType
    else
      R.MediaType := 'application/octet-stream';
    R.Data := Data;
    Resources.Add(R);

    if Bin.Id <> '' then
    begin
      ImageMap.Values[Bin.Id] := Href;
      ImageMap.Values['#' + Bin.Id] := Href;
    end;
    if FileName <> '' then
    begin
      ImageMap.Values[FileName] := Href;
      ImageMap.Values['#' + FileName] := Href;
    end;
  end;
end;

{ Определить href обложки в EPUB (или ''). }
function TFb2ToEpubConverter.CoverHref(TI: TTitleInfo;
  ImageMap: TStringList): UnicodeString;
var
  I, J: Integer;
  Href, H, Key: UnicodeString;
begin
  Result := '';
  if (TI = nil) or (TI.Coverpage = nil) then
    Exit;
  for I := 0 to TI.Coverpage.Images.Count - 1 do
  begin
    Href := TInlineImage(TI.Coverpage.Images[I]).Href;
    if Href = '' then
      Continue;
    H := '';
    J := ImageMap.IndexOfName(Href);
    if J >= 0 then
      H := ImageMap.ValueFromIndex[J];
    if H = '' then
    begin
      Key := Href;
      while (Key <> '') and (Key[1] = '#') do
        Key := Copy(Key, 2, MaxInt);
      J := ImageMap.IndexOfName(Key);
      if J >= 0 then
        H := ImageMap.ValueFromIndex[J];
    end;
    if H <> '' then
      Exit(H);
  end;
end;

{ Найти id ресурса по его href. }
function TFb2ToEpubConverter.ResourceId(Resources: TEpubResourceList;
  const Href: UnicodeString): UnicodeString;
var
  I: Integer;
begin
  Result := '';
  if Href = '' then
    Exit;
  for I := 0 to Resources.Count - 1 do
    if Resources[I].Href = Href then
      Exit(Resources[I].Id);
end;

{ ===================== Сборка XHTML-документов ===================== }

function TFb2ToEpubConverter.BuildDocuments(Bodies: TFb2ObjectList;
  ImageMap: TStringList): TEpubDocumentList;
var
  I, J, Counter: Integer;
  Body: TBody;
  Doc: TEpubDocument;
begin
  Result := TEpubDocumentList.Create;
  Counter := 0;
  if Bodies = nil then
    Exit;
  for I := 0 to Bodies.Count - 1 do
  begin
    Body := TBody(Bodies[I]);
    if (Body.Title <> nil) and (Body.Sections.Count > 0) then
    begin
      Inc(Counter);
      Result.Add(BodyTitleDocument(Body, Counter, ImageMap));
    end;
    if Body.Sections.Count > 0 then
    begin
      for J := 0 to Body.Sections.Count - 1 do
      begin
        Inc(Counter);
        Result.Add(SectionDocument(TSection(Body.Sections[J]), Counter,
          ImageMap));
      end;
    end
    else
    begin
      Inc(Counter);
      Result.Add(BodyDocument(Body, Counter, ImageMap));
    end;
  end;

  if Result.Count = 0 then
  begin
    Doc := TEpubDocument.Create;
    Doc.Id := 'doc1';
    Doc.Href := 'chap1.xhtml';
    Doc.Title := 'Book';
    Doc.Content := Xhtml('Book', '');
    Result.Add(Doc);
  end;
end;

function TFb2ToEpubConverter.BodyTitleDocument(Body: TBody; Number: Integer;
  ImageMap: TStringList): TEpubDocument;
var
  Title: UnicodeString;
  Parts: TTextList;
  I: Integer;
begin
  Title := TitleTextOf(Body.Title);
  if Title = '' then
    Title := 'Part ' + IntToStr(Number);
  Parts := TTextList.Create;
  try
    Parts.Add(RenderTitle(Body.Title, 1, ImageMap));
    for I := 0 to Body.Epigraphs.Count - 1 do
      Parts.Add(RenderEpigraph(TEpigraph(Body.Epigraphs[I]), ImageMap));
    if Body.Image <> nil then
      Parts.Add(RenderBlockImage(Body.Image, ImageMap));
    Result := TEpubDocument.Create;
    Result.Id := 'doc' + IntToStr(Number);
    Result.Href := 'chap' + IntToStr(Number) + '.xhtml';
    Result.Title := Title;
    Result.Content := Xhtml(Title, JoinNonEmpty(Parts));
  finally
    Parts.Free;
  end;
end;

function TFb2ToEpubConverter.BodyDocument(Body: TBody; Number: Integer;
  ImageMap: TStringList): TEpubDocument;
var
  Title: UnicodeString;
  Parts: TTextList;
  I: Integer;
begin
  Title := TitleTextOf(Body.Title);
  if Title = '' then
    Title := 'Book ' + IntToStr(Number);
  Parts := TTextList.Create;
  try
    if Body.Title <> nil then
      Parts.Add(RenderTitle(Body.Title, 1, ImageMap));
    for I := 0 to Body.Epigraphs.Count - 1 do
      Parts.Add(RenderEpigraph(TEpigraph(Body.Epigraphs[I]), ImageMap));
    if Body.Image <> nil then
      Parts.Add(RenderBlockImage(Body.Image, ImageMap));
    Result := TEpubDocument.Create;
    Result.Id := 'doc' + IntToStr(Number);
    Result.Href := 'chap' + IntToStr(Number) + '.xhtml';
    Result.Title := Title;
    Result.Content := Xhtml(Title, JoinNonEmpty(Parts));
  finally
    Parts.Free;
  end;
end;

function TFb2ToEpubConverter.SectionDocument(Section: TSection;
  Number: Integer; ImageMap: TStringList): TEpubDocument;
var
  Title: UnicodeString;
begin
  Title := TitleTextOf(Section.Title);
  if Title = '' then
    Title := 'Section ' + IntToStr(Number);
  Result := TEpubDocument.Create;
  Result.Id := 'doc' + IntToStr(Number);
  Result.Href := 'chap' + IntToStr(Number) + '.xhtml';
  Result.Title := Title;
  Result.Content := Xhtml(Title, RenderSection(Section, 1, ImageMap));
end;

{ Документ с изображением обложки. }
function TFb2ToEpubConverter.CoverDocument(
  const CoverHref: UnicodeString): TEpubDocument;
var
  Body: UnicodeString;
begin
  Body := '<div class="cover">' +
    '<img src="' + HtmlEscape(CoverHref, True) + '" alt="cover"/>' +
    '</div>';
  Result := TEpubDocument.Create;
  Result.Id := 'cover';
  Result.Href := 'cover.xhtml';
  Result.Title := 'Cover';
  Result.Content := Xhtml('Cover', Body);
end;

{ Обернуть фрагмент в полноценный XHTML-документ. }
function TFb2ToEpubConverter.Xhtml(const Title,
  BodyHtml: UnicodeString): UnicodeString;
var
  Header, Meta: UnicodeString;
begin
  if FEpubVersion >= 3 then
  begin
    Header := '<?xml version="1.0" encoding="utf-8"?>' + #10 +
      '<!DOCTYPE html>' + #10 +
      '<html xmlns="' + NS_XHTML + '" xmlns:epub="' + NS_EPUB + '">' + #10;
    Meta := '  <meta charset="utf-8"/>' + #10;
  end
  else
  begin
    Header := '<?xml version="1.0" encoding="utf-8"?>' + #10 +
      '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" ' +
      '"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">' + #10 +
      '<html xmlns="' + NS_XHTML + '">' + #10;
    Meta := '  <meta http-equiv="Content-Type" content="text/html; ' +
      'charset=utf-8"/>' + #10;
  end;
  Result := Header +
    '<head>' + #10 +
    '  <title>' + HtmlEscape(Title, False) + '</title>' + #10 +
    Meta +
    '  <link rel="stylesheet" type="text/css" href="style.css"/>' + #10 +
    '</head>' + #10 +
    '<body>' + #10 +
    BodyHtml + #10 +
    '</body>' + #10 +
    '</html>' + #10;
end;

{ ===================== Рендеринг XHTML ===================== }

{ Отрисовать секцию (рекурсивно) в XHTML-фрагмент. }
function TFb2ToEpubConverter.RenderSection(Section: TSection; Level: Integer;
  ImageMap: TStringList): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
begin
  Parts := TTextList.Create;
  try
    if Section.Title <> nil then
      Parts.Add(RenderTitle(Section.Title, Level, ImageMap));
    for I := 0 to Section.Epigraphs.Count - 1 do
      Parts.Add(RenderEpigraph(TEpigraph(Section.Epigraphs[I]), ImageMap));
    if Section.Image <> nil then
      Parts.Add(RenderBlockImage(Section.Image, ImageMap));
    if Section.Annotation <> nil then
      Parts.Add(RenderAnnotation(Section.Annotation, ImageMap));
    for I := 0 to Section.Content.Count - 1 do
      Parts.Add(RenderBlock(Section.Content[I], ImageMap));
    for I := 0 to Section.Sections.Count - 1 do
      Parts.Add(RenderSection(TSection(Section.Sections[I]), Level + 1,
        ImageMap));
    Result := JoinNonEmpty(Parts);
  finally
    Parts.Free;
  end;
end;

{ Отрисовать заголовок как <h1>..<h6>. }
function TFb2ToEpubConverter.RenderTitle(Title: TTitle; Level: Integer;
  ImageMap: TStringList): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
  Text, Tag: UnicodeString;
begin
  Result := '';
  if Title = nil then
    Exit;
  Parts := TTextList.Create;
  try
    for I := 0 to Title.Items.Count - 1 do
      if Title.Items[I] is TParagraph then
        Parts.Add(RenderMarkup(TParagraph(Title.Items[I]).Content, ImageMap));
    Text := '';
    for I := 0 to Parts.Count - 1 do
    begin
      if Parts[I] = '' then
        Continue;
      if Text <> '' then
        Text := Text + ' ';
      Text := Text + Parts[I];
    end;
    if Text = '' then
      Exit;
    Tag := HeadingTag(Level);
    Result := '<' + Tag + '>' + Text + '</' + Tag + '>';
  finally
    Parts.Free;
  end;
end;

{ Отрисовать эпиграф как <blockquote class="epigraph">. }
function TFb2ToEpubConverter.RenderEpigraph(E: TEpigraph;
  ImageMap: TStringList): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
  Inner: UnicodeString;
begin
  Result := '';
  Parts := TTextList.Create;
  try
    for I := 0 to E.Items.Count - 1 do
      Parts.Add(RenderBlock(E.Items[I], ImageMap));
    for I := 0 to E.TextAuthor.Count - 1 do
      Parts.Add(RenderParagraph(TParagraph(E.TextAuthor[I]), ImageMap,
        'text-author'));
    Inner := JoinNonEmpty(Parts);
    if Inner <> '' then
      Result := '<blockquote class="epigraph">' + #10 + Inner + #10 +
        '</blockquote>';
  finally
    Parts.Free;
  end;
end;

{ Отрисовать аннотацию как <div class="annotation">. }
function TFb2ToEpubConverter.RenderAnnotation(A: TAnnotation;
  ImageMap: TStringList): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
  Inner: UnicodeString;
begin
  Result := '';
  Parts := TTextList.Create;
  try
    for I := 0 to A.Items.Count - 1 do
      Parts.Add(RenderBlock(A.Items[I], ImageMap));
    Inner := JoinNonEmpty(Parts);
    if Inner <> '' then
      Result := '<div class="annotation">' + #10 + Inner + #10 + '</div>';
  finally
    Parts.Free;
  end;
end;

{ Отрисовать блочный элемент FB2 в XHTML. }
function TFb2ToEpubConverter.RenderBlock(Block: TFb2Object;
  ImageMap: TStringList): UnicodeString;
begin
  Result := '';
  if Block = nil then
    Exit;
  if Block is TParagraph then
    Result := RenderParagraph(TParagraph(Block), ImageMap, '')
  else if Block is TSubtitle then
    Result := RenderSubtitle(TSubtitle(Block), ImageMap)
  else if Block is TEmptyLine then
    Result := '<p class="empty-line">&#160;</p>'
  else if Block is TCite then
    Result := RenderCite(TCite(Block), ImageMap)
  else if Block is TPoem then
    Result := RenderPoem(TPoem(Block), ImageMap)
  else if Block is TTable then
    Result := RenderTable(TTable(Block), ImageMap)
  else if Block is TImage then
    Result := RenderBlockImage(TImage(Block), ImageMap);
end;

{ Отрисовать абзац как <p>. }
function TFb2ToEpubConverter.RenderParagraph(P: TParagraph;
  ImageMap: TStringList; const CssClass: UnicodeString): UnicodeString;
var
  Inner, Attr: UnicodeString;
begin
  Inner := RenderMarkup(P.Content, ImageMap);
  if CssClass <> '' then
    Attr := ' class="' + CssClass + '"'
  else
    Attr := '';
  Result := '<p' + Attr + '>' + Inner + '</p>';
end;

{ Отрисовать подзаголовок как <p class="subtitle">. }
function TFb2ToEpubConverter.RenderSubtitle(S: TSubtitle;
  ImageMap: TStringList): UnicodeString;
begin
  Result := '<p class="subtitle">' + RenderMarkup(S.Content, ImageMap) + '</p>';
end;

{ Получить href изображения в EPUB по ссылке FB2 (#id). }
function ImageSrc(const Href: UnicodeString; ImageMap: TStringList): UnicodeString;
var
  J: Integer;
  S, Key: UnicodeString;
begin
  Result := '';
  if Href = '' then
    Exit;
  S := '';
  J := ImageMap.IndexOfName(Href);
  if J >= 0 then
    S := ImageMap.ValueFromIndex[J];
  if S = '' then
  begin
    Key := Href;
    while (Key <> '') and (Key[1] = '#') do
      Key := Copy(Key, 2, MaxInt);
    J := ImageMap.IndexOfName(Key);
    if J >= 0 then
      S := ImageMap.ValueFromIndex[J];
  end;
  if S <> '' then
    Result := HtmlEscape(S, True);
end;

{ Отрисовать блочное изображение. }
function TFb2ToEpubConverter.RenderBlockImage(I: TImage;
  ImageMap: TStringList): UnicodeString;
var
  Src, Alt: UnicodeString;
begin
  Result := '';
  Src := ImageSrc(I.Href, ImageMap);
  if Src = '' then
    Exit;
  Alt := HtmlEscape(I.Alt, True);
  Result := '<div class="image"><img src="' + Src + '" alt="' + Alt +
    '"/></div>';
end;

{ Отрисовать inline-изображение. }
function TFb2ToEpubConverter.RenderInlineImage(Node: TStyleNode;
  ImageMap: TStringList): UnicodeString;
var
  Src, Alt: UnicodeString;
begin
  Result := '';
  Src := ImageSrc(Node.ImageHref, ImageMap);
  if Src = '' then
    Exit;
  Alt := HtmlEscape(Node.ImageAlt, True);
  Result := '<img src="' + Src + '" alt="' + Alt + '"/>';
end;

{ Отрисовать цитату как <blockquote>. }
function TFb2ToEpubConverter.RenderCite(C: TCite;
  ImageMap: TStringList): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
  Inner: UnicodeString;
begin
  Result := '';
  Parts := TTextList.Create;
  try
    for I := 0 to C.Items.Count - 1 do
      Parts.Add(RenderBlock(C.Items[I], ImageMap));
    for I := 0 to C.TextAuthor.Count - 1 do
      Parts.Add(RenderParagraph(TParagraph(C.TextAuthor[I]), ImageMap,
        'text-author'));
    Inner := JoinNonEmpty(Parts);
    if Inner <> '' then
      Result := '<blockquote>' + #10 + Inner + #10 + '</blockquote>';
  finally
    Parts.Free;
  end;
end;

{ Отрисовать стихотворение как <div class="poem">. }
function TFb2ToEpubConverter.RenderPoem(P: TPoem;
  ImageMap: TStringList): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
  Inner: UnicodeString;
begin
  Result := '';
  Parts := TTextList.Create;
  try
    if P.Title <> nil then
      Parts.Add(RenderTitle(P.Title, 4, ImageMap));
    for I := 0 to P.Epigraphs.Count - 1 do
      Parts.Add(RenderEpigraph(TEpigraph(P.Epigraphs[I]), ImageMap));
    for I := 0 to P.Items.Count - 1 do
    begin
      if P.Items[I] is TStanza then
        Parts.Add(RenderStanza(TStanza(P.Items[I]), ImageMap))
      else if P.Items[I] is TSubtitle then
        Parts.Add(RenderSubtitle(TSubtitle(P.Items[I]), ImageMap));
    end;
    for I := 0 to P.TextAuthor.Count - 1 do
      Parts.Add(RenderParagraph(TParagraph(P.TextAuthor[I]), ImageMap,
        'text-author'));
    Inner := JoinNonEmpty(Parts);
    if Inner <> '' then
      Result := '<div class="poem">' + #10 + Inner + #10 + '</div>';
  finally
    Parts.Free;
  end;
end;

{ Отрисовать строфу. }
function TFb2ToEpubConverter.RenderStanza(S: TStanza;
  ImageMap: TStringList): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
begin
  Parts := TTextList.Create;
  try
    if S.Title <> nil then
      Parts.Add(RenderTitle(S.Title, 5, ImageMap));
    if S.Subtitle <> nil then
      Parts.Add(RenderSubtitle(S.Subtitle, ImageMap));
    for I := 0 to S.Verses.Count - 1 do
      Parts.Add('<p>' +
        RenderMarkup(TParagraph(S.Verses[I]).Content, ImageMap) + '</p>');
    Result := JoinNonEmpty(Parts);
  finally
    Parts.Free;
  end;
end;

{ Отрисовать таблицу как <table>. }
function TFb2ToEpubConverter.RenderTable(T: TTable;
  ImageMap: TStringList): UnicodeString;
var
  Rows: TTextList;
  I, J: Integer;
  Row: TTableRow;
  Cell: TTableCell;
  Tag, Attrs, Cells: UnicodeString;
begin
  Rows := TTextList.Create;
  try
    for I := 0 to T.Rows.Count - 1 do
    begin
      Row := TTableRow(T.Rows[I]);
      Cells := '';
      for J := 0 to Row.Cells.Count - 1 do
      begin
        Cell := TTableCell(Row.Cells[J]);
        if Cell.IsHeader then
          Tag := 'th'
        else
          Tag := 'td';
        Attrs := '';
        if Cell.Colspan <> NO_VALUE then
          Attrs := Attrs + ' colspan="' + IntToStr(Cell.Colspan) + '"';
        if Cell.Rowspan <> NO_VALUE then
          Attrs := Attrs + ' rowspan="' + IntToStr(Cell.Rowspan) + '"';
        Cells := Cells + '<' + Tag + Attrs + '>' +
          RenderMarkup(Cell.Children, ImageMap) + '</' + Tag + '>';
      end;
      Rows.Add('<tr>' + Cells + '</tr>');
    end;
    Result := '<table>' + JoinText(Rows, '') + '</table>';
  finally
    Rows.Free;
  end;
end;

{ Отрисовать mixed-разметку (текст + inline-элементы). }
function TFb2ToEpubConverter.RenderMarkup(Nodes: TFb2ObjectList;
  ImageMap: TStringList): UnicodeString;
var
  I: Integer;
  Node: TStyleNode;
  Tag: UnicodeString;
begin
  Result := '';
  if Nodes = nil then
    Exit;
  for I := 0 to Nodes.Count - 1 do
  begin
    Node := TStyleNode(Nodes[I]);
    Tag := Node.Tag;
    if Tag = TEXT_NODE_NAME then
      Result := Result + HtmlEscape(Node.Text, False)
    else if Tag = 'strong' then
      Result := Result + '<strong>' + RenderMarkup(Node.Children, ImageMap) +
        '</strong>'
    else if Tag = 'emphasis' then
      Result := Result + '<em>' + RenderMarkup(Node.Children, ImageMap) +
        '</em>'
    else if Tag = 'strikethrough' then
      Result := Result + '<del>' + RenderMarkup(Node.Children, ImageMap) +
        '</del>'
    else if (Tag = 'sub') or (Tag = 'sup') or (Tag = 'code') then
      Result := Result + '<' + Tag + '>' + RenderMarkup(Node.Children,
        ImageMap) + '</' + Tag + '>'
    else if Tag = 'style' then
      Result := Result + '<span class="' + HtmlEscape(Node.StyleName, True) +
        '">' + RenderMarkup(Node.Children, ImageMap) + '</span>'
    else if Tag = 'a' then
      Result := Result + '<a href="' + HtmlEscape(Node.Href, True) + '">' +
        RenderMarkup(Node.Children, ImageMap) + '</a>'
    else if Tag = 'image' then
      Result := Result + RenderInlineImage(Node, ImageMap);
  end;
end;

{ ===================== Метафайлы EPUB ===================== }

{ Содержимое META-INF/container.xml. }
function TFb2ToEpubConverter.ContainerXml: UnicodeString;
begin
  Result :=
    '<?xml version="1.0" encoding="utf-8"?>' + #10 +
    '<container version="1.0" xmlns="' + NS_CONTAINER + '">' + #10 +
    '  <rootfiles>' + #10 +
    '    <rootfile full-path="OEBPS/content.opf"' +
    ' media-type="application/oebps-package+xml"/>' + #10 +
    '  </rootfiles>' + #10 +
    '</container>' + #10;
end;

function TFb2ToEpubConverter.Opf(Book: TEpubBook): UnicodeString;
begin
  if Book.Version >= 3 then
    Result := Opf3(Book)
  else
    Result := Opf2(Book);
end;

{ Собрать OPF 2.0 (content.opf). }
function TFb2ToEpubConverter.Opf2(Book: TEpubBook): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
begin
  Parts := TTextList.Create;
  try
    Parts.Add('<?xml version="1.0" encoding="utf-8"?>');
    Parts.Add('<package xmlns="' + NS_OPF +
      '" version="2.0" unique-identifier="BookId">');
    Parts.Add('  <metadata xmlns:dc="' + NS_DC + '" xmlns:opf="' + NS_OPF +
      '">');
    Parts.Add('    <dc:title>' + HtmlEscape(Book.Title, False) +
      '</dc:title>');
    for I := 0 to Book.Creators.Count - 1 do
      Parts.Add('    <dc:creator opf:role="aut">' +
        HtmlEscape(Book.Creators[I], False) + '</dc:creator>');
    Parts.Add('    <dc:language>' + HtmlEscape(Book.Language, False) +
      '</dc:language>');
    Parts.Add('    <dc:identifier id="BookId">' +
      HtmlEscape(Book.Identifier, False) + '</dc:identifier>');
    if Book.Date <> '' then
      Parts.Add('    <dc:date>' + HtmlEscape(Book.Date, False) + '</dc:date>');
    if Book.Description <> '' then
      Parts.Add('    <dc:description>' + HtmlEscape(Book.Description, False) +
        '</dc:description>');
    for I := 0 to Book.Subjects.Count - 1 do
      Parts.Add('    <dc:subject>' + HtmlEscape(Book.Subjects[I], False) +
        '</dc:subject>');
    if Book.HasCover then
      Parts.Add('    <meta name="cover" content="' + Book.CoverId + '"/>');
    Parts.Add('  </metadata>');

    Parts.Add('  <manifest>');
    Parts.Add('    <item id="ncx" href="toc.ncx"' +
      ' media-type="application/x-dtbncx+xml"/>');
    Parts.Add('    <item id="css" href="style.css" media-type="text/css"/>');
    for I := 0 to Book.Documents.Count - 1 do
      Parts.Add('    <item id="' + Book.Documents[I].Id + '" href="' +
        Book.Documents[I].Href +
        '" media-type="application/xhtml+xml"/>');
    for I := 0 to Book.Resources.Count - 1 do
      Parts.Add('    <item id="' + Book.Resources[I].Id + '" href="' +
        Book.Resources[I].Href + '" media-type="' +
        Book.Resources[I].MediaType + '"/>');
    Parts.Add('  </manifest>');

    Parts.Add('  <spine toc="ncx">');
    for I := 0 to Book.Documents.Count - 1 do
      Parts.Add('    <itemref idref="' + Book.Documents[I].Id + '"/>');
    Parts.Add('  </spine>');

    if Book.HasCover then
    begin
      Parts.Add('  <guide>');
      Parts.Add('    <reference type="cover" title="Cover"' +
        ' href="cover.xhtml"/>');
      Parts.Add('  </guide>');
    end;

    Parts.Add('</package>');
    Result := JoinText(Parts, #10) + #10;
  finally
    Parts.Free;
  end;
end;

{ Собрать OPF 3.0 (content.opf). }
function TFb2ToEpubConverter.Opf3(Book: TEpubBook): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
  Properties: UnicodeString;
begin
  Parts := TTextList.Create;
  try
    Parts.Add('<?xml version="1.0" encoding="utf-8"?>');
    Parts.Add('<package xmlns="' + NS_OPF +
      '" version="3.0" unique-identifier="BookId" xml:lang="' +
      HtmlEscape(Book.Language, False) + '">');
    Parts.Add('  <metadata xmlns:dc="' + NS_DC + '">');
    Parts.Add('    <dc:title>' + HtmlEscape(Book.Title, False) +
      '</dc:title>');
    for I := 0 to Book.Creators.Count - 1 do
    begin
      Parts.Add('    <dc:creator id="creator' + IntToStr(I + 1) + '">' +
        HtmlEscape(Book.Creators[I], False) + '</dc:creator>');
      Parts.Add('    <meta refines="#creator' + IntToStr(I + 1) +
        '" property="role" scheme="marc:relators">aut</meta>');
    end;
    Parts.Add('    <dc:language>' + HtmlEscape(Book.Language, False) +
      '</dc:language>');
    Parts.Add('    <dc:identifier id="BookId">' +
      HtmlEscape(Book.Identifier, False) + '</dc:identifier>');
    if Book.Date <> '' then
      Parts.Add('    <dc:date>' + HtmlEscape(Book.Date, False) + '</dc:date>');
    if Book.Description <> '' then
      Parts.Add('    <dc:description>' + HtmlEscape(Book.Description, False) +
        '</dc:description>');
    for I := 0 to Book.Subjects.Count - 1 do
      Parts.Add('    <dc:subject>' + HtmlEscape(Book.Subjects[I], False) +
        '</dc:subject>');
    Parts.Add('    <meta property="dcterms:modified">' + ModifiedTimestamp +
      '</meta>');
    if Book.HasCover then
      Parts.Add('    <meta name="cover" content="' + Book.CoverId + '"/>');
    Parts.Add('  </metadata>');

    Parts.Add('  <manifest>');
    Parts.Add('    <item id="nav" href="nav.xhtml"' +
      ' media-type="application/xhtml+xml" properties="nav"/>');
    Parts.Add('    <item id="ncx" href="toc.ncx"' +
      ' media-type="application/x-dtbncx+xml"/>');
    Parts.Add('    <item id="css" href="style.css" media-type="text/css"/>');
    for I := 0 to Book.Documents.Count - 1 do
      Parts.Add('    <item id="' + Book.Documents[I].Id + '" href="' +
        Book.Documents[I].Href +
        '" media-type="application/xhtml+xml"/>');
    for I := 0 to Book.Resources.Count - 1 do
    begin
      if Book.HasCover and (Book.Resources[I].Id = Book.CoverId) then
        Properties := ' properties="cover-image"'
      else
        Properties := '';
      Parts.Add('    <item id="' + Book.Resources[I].Id + '" href="' +
        Book.Resources[I].Href + '" media-type="' +
        Book.Resources[I].MediaType + '"' + Properties + '/>');
    end;
    Parts.Add('  </manifest>');

    Parts.Add('  <spine toc="ncx">');
    for I := 0 to Book.Documents.Count - 1 do
      Parts.Add('    <itemref idref="' + Book.Documents[I].Id + '"/>');
    Parts.Add('  </spine>');

    Parts.Add('</package>');
    Result := JoinText(Parts, #10) + #10;
  finally
    Parts.Free;
  end;
end;

{ Собрать NCX-оглавление (toc.ncx). }
function TFb2ToEpubConverter.Ncx(Book: TEpubBook): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
begin
  Parts := TTextList.Create;
  try
    Parts.Add('<?xml version="1.0" encoding="utf-8"?>');
    Parts.Add('<ncx xmlns="' + NS_NCX + '" version="2005-1">');
    Parts.Add('  <head>');
    Parts.Add('    <meta name="dtb:uid" content="' +
      HtmlEscape(Book.Identifier, False) + '"/>');
    Parts.Add('    <meta name="dtb:depth" content="1"/>');
    Parts.Add('    <meta name="dtb:totalPageCount" content="0"/>');
    Parts.Add('    <meta name="dtb:maxPageNumber" content="0"/>');
    Parts.Add('  </head>');
    Parts.Add('  <docTitle><text>' + HtmlEscape(Book.Title, False) +
      '</text></docTitle>');
    Parts.Add('  <navMap>');
    for I := 0 to Book.Documents.Count - 1 do
    begin
      Parts.Add('    <navPoint id="navPoint-' + IntToStr(I + 1) +
        '" playOrder="' + IntToStr(I + 1) + '">');
      Parts.Add('      <navLabel><text>' +
        HtmlEscape(Book.Documents[I].Title, False) + '</text></navLabel>');
      Parts.Add('      <content src="' + Book.Documents[I].Href + '"/>');
      Parts.Add('    </navPoint>');
    end;
    Parts.Add('  </navMap>');
    Parts.Add('</ncx>');
    Result := JoinText(Parts, #10) + #10;
  finally
    Parts.Free;
  end;
end;

{ Собрать XHTML Navigation Document (nav.xhtml) для EPUB 3. }
function TFb2ToEpubConverter.NavXhtml(Book: TEpubBook): UnicodeString;
var
  TocItems, Landmarks, LandmarksBlock, Language: UnicodeString;
  I: Integer;
  First: Boolean;
  BodyDoc: TEpubDocument;
begin
  TocItems := '';
  First := True;
  BodyDoc := nil;
  for I := 0 to Book.Documents.Count - 1 do
  begin
    if Book.Documents[I].Id = 'cover' then
      Continue;
    if BodyDoc = nil then
      BodyDoc := Book.Documents[I];
    if not First then
      TocItems := TocItems + #10;
    TocItems := TocItems + '      <li><a href="' +
      HtmlEscape(Book.Documents[I].Href, True) + '">' +
      HtmlEscape(Book.Documents[I].Title, False) + '</a></li>';
    First := False;
  end;

  Landmarks := '';
  First := True;
  for I := 0 to Book.Documents.Count - 1 do
  begin
    if Book.Documents[I].Id <> 'cover' then
      Continue;
    if not First then
      Landmarks := Landmarks + #10;
    Landmarks := Landmarks + '      <li><a epub:type="cover" href="' +
      HtmlEscape(Book.Documents[I].Href, True) + '">Обложка</a></li>';
    First := False;
  end;
  if BodyDoc <> nil then
  begin
    if not First then
      Landmarks := Landmarks + #10;
    Landmarks := Landmarks + '      <li><a epub:type="bodymatter" href="' +
      HtmlEscape(BodyDoc.Href, True) + '">Начало</a></li>';
  end;

  if Landmarks = '' then
    LandmarksBlock := ''
  else
    LandmarksBlock := #10 + '  <nav epub:type="landmarks" hidden="hidden">' +
      #10 + '    <h2>Ориентиры</h2>' + #10 + '    <ol>' + #10 +
      Landmarks + #10 + '    </ol>' + #10 + '  </nav>';

  Language := HtmlEscape(Book.Language, False);
  Result :=
    '<?xml version="1.0" encoding="utf-8"?>' + #10 +
    '<!DOCTYPE html>' + #10 +
    '<html xmlns="' + NS_XHTML + '" xmlns:epub="' + NS_EPUB +
    '" xml:lang="' + Language + '" lang="' + Language + '">' + #10 +
    '<head>' + #10 +
    '  <title>' + HtmlEscape(FTocTitle, False) + '</title>' + #10 +
    '  <meta charset="utf-8"/>' + #10 +
    '  <link rel="stylesheet" type="text/css" href="style.css"/>' + #10 +
    '</head>' + #10 +
    '<body>' + #10 +
    '  <nav epub:type="toc" id="toc">' + #10 +
    '    <h1>' + HtmlEscape(FTocTitle, False) + '</h1>' + #10 +
    '    <ol>' + #10 +
    TocItems + #10 +
    '    </ol>' + #10 +
    '  </nav>' +
    LandmarksBlock + #10 +
    '</body>' + #10 +
    '</html>' + #10;
end;

end.
