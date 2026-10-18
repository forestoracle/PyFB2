unit fb2_structures;
{ Структуры данных FB2 (FictionBook 2.0) — перевод fb2_structures.py.

  Файл содержит ТОЛЬКО описания структур (классы / перечисления),
  соответствующие типам из XSD-схемы FictionBook.xsd. Алгоритмов разбора
  здесь нет.

  Соответствие типам схемы:
      authorType                   -> TAuthor
      textFieldType                -> TTextField
      dateType                     -> TDateField
      titleType                    -> TTitle
      imageType                    -> TImage
      inlineImageType              -> TInlineImage
      pType                        -> TParagraph
      citeType                     -> TCite
      poemType                     -> TPoem
      epigraphType                 -> TEpigraph
      annotationType               -> TAnnotation
      sectionType                  -> TSection
      styleType                    -> TStyleNode
      namedStyleType               -> TNamedStyle
      linkType                     -> TLink
      styleLinkType                -> TStyleLink
      sequenceType                 -> TSequence
      tableType                    -> TTable (+ TTableRow, TTableCell = tdType)
      title-infoType               -> TTitleInfo
      alignType / vAlignType       -> TAlign / TVAlign
      shareModesType               -> TShareMode
      docGenerationInstructionType -> TDocGenerationInstruction

  Анонимные (встроенные) типы элементов схемы:
      stylesheet, description, document-info, publish-info, custom-info,
      body, binary, genre (с match), coverpage, stanza, tr

  Особенности перевода с Python:
      * Optional[int]  -> Integer со значением NO_VALUE (-1);
      * Optional[Enum] -> значение перечисления с «None»-вариантом
                          (alNone / vaNone);
      * list[T]        -> TFb2ObjectList (владеет объектами и освобождает их)
                          либо TTextList (список строк UnicodeString);
      * Optional[T]    -> ссылка на объект, nil означает отсутствие.

  ВАЖНО (отличие от Python): в Pascal тип должен быть объявлен ДО его
  использования, поэтому порядок объявлений отражает граф зависимостей
  (сначала «простые» типы, затем составные). }

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Classes, SysUtils, fgl;

const
  NS_FB    = 'http://www.gribuser.ru/xml/fictionbook/2.0';
  NS_XLINK = 'http://www.w3.org/1999/xlink';
  NS_XML   = 'http://www.w3.org/XML/1998/namespace';

  { Тег-заглушка для текстовых фрагментов внутри mixed-контента
    (в Python — TEXT_NODE). }
  TEXT_NODE_NAME = '#text';

  { Значение «не задано» (аналог None) для целочисленных полей. }
  NO_VALUE = -1;

type
  { ------------------------------------------------------------------
    simpleType-перечисления
    ------------------------------------------------------------------ }
  TAlign = (alNone, alLeft, alRight, alCenter);
  TVAlign = (vaNone, vaTop, vaMiddle, vaBottom);
  TShareMode = (smFree, smPaid);
  TDocGenerationInstruction = (dgiRequire, dgiAllow, dgiDeny);

  { ------------------------------------------------------------------
    Базовые типы-контейнеры
    ------------------------------------------------------------------ }
  { Базовый класс всех узлов FB2. }
  TFb2Object = class(TObject)
  end;

  { Список узлов FB2. Владеет объектами и освобождает их при удалении. }
  TFb2ObjectList = specialize TFPGObjectList<TFb2Object>;

  { Список строк UnicodeString (аналог list[str] в Python). }
  TTextList = class(TObject)
  private
    FItems: array of UnicodeString;
    FCount: Integer;
    function GetItem(Index: Integer): UnicodeString;
    procedure SetItem(Index: Integer; const AValue: UnicodeString);
  public
    procedure Add(const S: UnicodeString);
    procedure Clear;
    procedure Delete(Index: Integer);
    procedure AddStrings(Src: TTextList);
    function Text: UnicodeString;
    property Count: Integer read FCount;
    property Items[Index: Integer]: UnicodeString read GetItem write SetItem; default;
  end;

  { ------------------------------------------------------------------
    Простые (simpleContent) элементы
    ------------------------------------------------------------------ }
  { textFieldType — xs:string + xml:lang. }
  TTextField = class(TFb2Object)
  public
    Value: UnicodeString;
    Lang: UnicodeString;
  end;

  { dateType — xs:string + необязательный атрибут value (xs:date) + xml:lang. }
  TDateField = class(TFb2Object)
  public
    Value: UnicodeString;
    DateValue: UnicodeString;      { атрибут value }
    Lang: UnicodeString;
  end;

  { custom-info — textFieldType + обязательный атрибут info-type. }
  TCustomInfo = class(TFb2Object)
  public
    Value: UnicodeString;
    InfoType: UnicodeString;
  end;

  { stylesheet — xs:string + обязательный атрибут type. }
  TStylesheet = class(TFb2Object)
  public
    SheetType: UnicodeString;      { атрибут type }
    Value: UnicodeString;
  end;

  { ------------------------------------------------------------------
    Разметка (styleType и его варианты)
    ------------------------------------------------------------------ }
  { styleType (mixed) — узел разметки: strong/emphasis/style/a/... + текст. }
  TStyleNode = class(TFb2Object)
  public
    Tag: UnicodeString;            { локальное имя элемента }
    Text: UnicodeString;           { текстовое содержимое узла }
    Children: TFb2ObjectList;
    Href: UnicodeString;           { для <a> (xlink:href) }
    StyleName: UnicodeString;      { для <style> (name) }
    LinkType: UnicodeString;       { для <a type="..."> }
    ImageHref: UnicodeString;      { для inline <image> }
    ImageAlt: UnicodeString;
    constructor Create(const ATag: UnicodeString = '';
      const AText: UnicodeString = '');
    destructor Destroy; override;
  end;

  { namedStyleType (mixed) — style с обязательным атрибутом name. }
  TNamedStyle = class(TStyleNode);

  { linkType (mixed) — <a> с обязательным xlink:href, опциональным type. }
  TLink = class(TStyleNode);

  { styleLinkType (mixed) — разметка внутри ссылки. }
  TStyleLink = class(TStyleNode);

  { ------------------------------------------------------------------
    Таблицы
    ------------------------------------------------------------------ }
  { tdType (mixed) — ячейка таблицы (td или th). }
  TTableCell = class(TStyleNode)
  public
    Colspan: Integer;
    Rowspan: Integer;
    Align: TAlign;
    VAlign: TVAlign;
    Style: UnicodeString;
    Id: UnicodeString;
    IsHeader: Boolean;             { True для <th>, False для <td> }
    constructor Create(const ATag: UnicodeString = '';
      const AText: UnicodeString = '');
  end;

  { tr — строка таблицы: choice из th/td*, атрибут align. }
  TTableRow = class(TFb2Object)
  public
    Align: TAlign;
    Cells: TFb2ObjectList;
    constructor Create;
    destructor Destroy; override;
  end;

  { tableType — tr+, атрибуты style, id. }
  TTable = class(TFb2Object)
  public
    Rows: TFb2ObjectList;
    Style: UnicodeString;
    Id: UnicodeString;
    constructor Create;
    destructor Destroy; override;
  end;

  { ------------------------------------------------------------------
    Изображения и бинарные данные
    ------------------------------------------------------------------ }
  { inlineImageType — xlink:type?, xlink:href?, alt?. }
  TInlineImage = class(TFb2Object)
  public
    Href: UnicodeString;
    Alt: UnicodeString;
    XlinkType: UnicodeString;
  end;

  { imageType — xlink:type?, xlink:href?, alt?, title?, id?. }
  TImage = class(TFb2Object)
  public
    Href: UnicodeString;
    Alt: UnicodeString;
    Title: UnicodeString;
    Id: UnicodeString;
    XlinkType: UnicodeString;
  end;

  { binary (xs:base64Binary) — content-type (обязателен), id (xs:ID). }
  TBinary = class(TFb2Object)
  public
    Id: UnicodeString;
    ContentType: UnicodeString;
    Data: UnicodeString;           { base64-строка }
  end;

  { ------------------------------------------------------------------
    Блочные элементы контента
    ------------------------------------------------------------------ }
  { pType (mixed) — абзац; id?, style?, xml:lang? + разметка styleType. }
  TParagraph = class(TFb2Object)
  public
    Content: TFb2ObjectList;
    Id: UnicodeString;
    Style: UnicodeString;
    Lang: UnicodeString;
    constructor Create;
    destructor Destroy; override;
  end;

  { subtitle — использует pType. }
  TSubtitle = class(TFb2Object)
  public
    Content: TFb2ObjectList;
    Id: UnicodeString;
    Style: UnicodeString;
    Lang: UnicodeString;
    constructor Create;
    destructor Destroy; override;
  end;

  { empty-line — пустой элемент. }
  TEmptyLine = class(TFb2Object)
  end;

  { titleType — choice (p | empty-line)* + xml:lang?. }
  TTitle = class(TFb2Object)
  public
    Items: TFb2ObjectList;
    Lang: UnicodeString;
    constructor Create;
    destructor Destroy; override;
  end;

  { epigraphType — choice(p|poem|cite|empty-line)*, затем text-author*, id?. }
  TEpigraph = class(TFb2Object)
  public
    Items: TFb2ObjectList;
    TextAuthor: TFb2ObjectList;
    Id: UnicodeString;
    constructor Create;
    destructor Destroy; override;
  end;

  { stanza — title?, subtitle?, v+, xml:lang?. }
  TStanza = class(TFb2Object)
  public
    Title: TTitle;
    Subtitle: TSubtitle;
    Verses: TFb2ObjectList;        { v+ }
    Lang: UnicodeString;
    constructor Create;
    destructor Destroy; override;
  end;

  { poemType — title?, epigraph*, choice(subtitle|stanza)+, text-author*,
    date?, id?, lang?. }
  TPoem = class(TFb2Object)
  public
    Title: TTitle;
    Epigraphs: TFb2ObjectList;
    Items: TFb2ObjectList;
    TextAuthor: TFb2ObjectList;
    Date: TDateField;
    Id: UnicodeString;
    Lang: UnicodeString;
    constructor Create;
    destructor Destroy; override;
  end;

  { citeType — choice(p|poem|empty-line|subtitle|table)*, text-author*, id?, lang?. }
  TCite = class(TFb2Object)
  public
    Items: TFb2ObjectList;
    TextAuthor: TFb2ObjectList;
    Id: UnicodeString;
    Lang: UnicodeString;
    constructor Create;
    destructor Destroy; override;
  end;

  { annotationType — choice(p|poem|cite|subtitle|table|empty-line)*, id?, lang?. }
  TAnnotation = class(TFb2Object)
  public
    Items: TFb2ObjectList;
    Id: UnicodeString;
    Lang: UnicodeString;
    constructor Create;
    destructor Destroy; override;
  end;

  { ------------------------------------------------------------------
    Секции и body
    ------------------------------------------------------------------ }
  { sectionType.

    sequence:
      title?, epigraph*, image?, annotation?,
      choice(section+ | (choice(p|poem|subtitle|cite|empty-line|table),
                         choice(p|image|poem|subtitle|cite|empty-line|table)*))
    атрибуты: id?, xml:lang?. }
  TSection = class(TFb2Object)
  public
    Title: TTitle;
    Epigraphs: TFb2ObjectList;
    Image: TImage;
    Annotation: TAnnotation;
    Sections: TFb2ObjectList;
    Content: TFb2ObjectList;
    Id: UnicodeString;
    Lang: UnicodeString;
    { Целочисленные идентификаторы заголовков (заполняет TFb2Parser). }
    HeadingId: Integer;            { номер этого заголовка (NO_VALUE, если нет) }
    ParentId: Integer;             { номер ближайшего заголовка-предка }
    constructor Create;
    destructor Destroy; override;
  end;

  { body — image?, title?, epigraph*, section+; атрибуты name?, xml:lang?. }
  TBody = class(TFb2Object)
  public
    Image: TImage;
    Title: TTitle;
    Epigraphs: TFb2ObjectList;
    Sections: TFb2ObjectList;
    Name: UnicodeString;
    Lang: UnicodeString;
    HeadingId: Integer;
    ParentId: Integer;
    constructor Create;
    destructor Destroy; override;
  end;

  { ------------------------------------------------------------------
    Автор и серия
    ------------------------------------------------------------------ }
  { authorType.

    choice:
      (first-name, middle-name?, last-name, nickname?, home-page*, email*, id?)
      | (nickname, home-page*, email*, id?) }
  TAuthor = class(TFb2Object)
  public
    FirstName: UnicodeString;
    MiddleName: UnicodeString;
    LastName: UnicodeString;
    Nickname: UnicodeString;
    HomePages: TTextList;
    Emails: TTextList;
    Id: UnicodeString;
    constructor Create;
    destructor Destroy; override;
  end;

  { sequenceType — name (обязателен), number?, xml:lang?, вложенные sequence*. }
  TSequence = class(TFb2Object)
  public
    Name: UnicodeString;
    Number: Integer;               { NO_VALUE, если не задан }
    Lang: UnicodeString;
    Sequences: TFb2ObjectList;
    constructor Create;
    destructor Destroy; override;
  end;

  { ------------------------------------------------------------------
    Описание книги
    ------------------------------------------------------------------ }
  { genre — genre:genreType + атрибут match (default = 100). }
  TGenre = class(TFb2Object)
  public
    Value: UnicodeString;
    Match: Integer;
    constructor Create;
  end;

  { coverpage — sequence: image+ (inlineImageType). }
  TCoverPage = class(TFb2Object)
  public
    Images: TFb2ObjectList;
    constructor Create;
    destructor Destroy; override;
  end;

  { ------------------------------------------------------------------
    output (shareInstructionType и связанные)
    ------------------------------------------------------------------ }
  { partShareInstructionType — xlink:type?, xlink:href (обязателен),
    include (обязателен). }
  TPartShareInstruction = class(TFb2Object)
  public
    Href: UnicodeString;
    IncludeInstr: TDocGenerationInstruction;
    XlinkType: UnicodeString;
  end;

  { outPutDocumentType — part*, name (обязателен), create?, price?. }
  TOutputDocument = class(TFb2Object)
  public
    Name: UnicodeString;
    CreateInstr: TDocGenerationInstruction;
    Price: Double;
    HasPrice: Boolean;
    Parts: TFb2ObjectList;
    constructor Create;
    destructor Destroy; override;
  end;

  { shareInstructionType.

    choice(part | output-document-class)*;
    атрибуты: mode (обязателен), include-all (обязателен), price?, currency?. }
  TShareInstruction = class(TFb2Object)
  public
    Mode: TShareMode;
    IncludeAll: TDocGenerationInstruction;
    Price: Double;
    HasPrice: Boolean;
    Currency: UnicodeString;
    Parts: TFb2ObjectList;
    OutputDocuments: TFb2ObjectList;
    constructor Create;
    destructor Destroy; override;
  end;

  { title-infoType (используется и для <src-title-info>).

    sequence: genre+, author+, book-title, annotation?, keywords?, date?,
    coverpage?, lang, src-lang?, translator*, sequence*. }
  TTitleInfo = class(TFb2Object)
  public
    Genres: TFb2ObjectList;
    Authors: TFb2ObjectList;
    BookTitle: TTextField;
    Annotation: TAnnotation;
    Keywords: TTextField;
    Date: TDateField;
    Coverpage: TCoverPage;
    Lang: UnicodeString;
    SrcLang: UnicodeString;
    Translators: TFb2ObjectList;
    Sequences: TFb2ObjectList;
    constructor Create;
    destructor Destroy; override;
  end;

  { document-info.

    sequence: author+, program-used?, date, src-url*, src-ocr?, id,
    version (xs:float), history?, publisher*. }
  TDocumentInfo = class(TFb2Object)
  public
    Authors: TFb2ObjectList;
    ProgramUsed: TTextField;
    Date: TDateField;
    SrcUrls: TTextList;
    SrcOcr: TTextField;
    Id: UnicodeString;
    Version: Double;
    HasVersion: Boolean;
    History: TAnnotation;
    Publishers: TFb2ObjectList;
    constructor Create;
    destructor Destroy; override;
  end;

  { publish-info: book-name?, publisher?, city?, year?, isbn?, sequence*. }
  TPublishInfo = class(TFb2Object)
  public
    BookName: TTextField;
    Publisher: TTextField;
    City: TTextField;
    Year: UnicodeString;           { xs:gYear }
    Isbn: TTextField;
    Sequences: TFb2ObjectList;
    constructor Create;
    destructor Destroy; override;
  end;

  { description.

    sequence: title-info, src-title-info?, document-info, publish-info?,
    custom-info*, output* (maxOccurs=2). }
  TDescription = class(TFb2Object)
  public
    TitleInfo: TTitleInfo;
    SrcTitleInfo: TTitleInfo;
    DocumentInfo: TDocumentInfo;
    PublishInfo: TPublishInfo;
    CustomInfos: TFb2ObjectList;
    Outputs: TFb2ObjectList;
    constructor Create;
    destructor Destroy; override;
  end;

  { FictionBook — корневой элемент.

    sequence: stylesheet*, description, body+, binary*. }
  TFictionBook = class(TFb2Object)
  public
    Stylesheets: TFb2ObjectList;
    Description: TDescription;
    Bodies: TFb2ObjectList;
    Binaries: TFb2ObjectList;
    constructor Create;
    destructor Destroy; override;
  end;

{ ---------------------------------------------------------------------
  Утилиты работы со строками UnicodeString
  --------------------------------------------------------------------- }
function UTrim(const S: UnicodeString): UnicodeString;
function UTrimRight(const S: UnicodeString): UnicodeString;
function UReplace(const S, AOld, ANew: UnicodeString): UnicodeString;
function UIntToStr(V: Integer): UnicodeString;
function JoinText(List: TTextList; const Sep: UnicodeString): UnicodeString;

implementation

{ ===================== TTextList ===================== }

function TTextList.GetItem(Index: Integer): UnicodeString;
begin
  Result := FItems[Index];
end;

procedure TTextList.SetItem(Index: Integer; const AValue: UnicodeString);
begin
  FItems[Index] := AValue;
end;

procedure TTextList.Add(const S: UnicodeString);
begin
  if FCount = Length(FItems) then
  begin
    if FCount = 0 then
      SetLength(FItems, 4)
    else
      SetLength(FItems, FCount * 2);
  end;
  FItems[FCount] := S;
  Inc(FCount);
end;

procedure TTextList.Clear;
begin
  SetLength(FItems, 0);
  FCount := 0;
end;

procedure TTextList.Delete(Index: Integer);
var
  I: Integer;
begin
  if (Index < 0) or (Index >= FCount) then
    Exit;
  for I := Index to FCount - 2 do
    FItems[I] := FItems[I + 1];
  Dec(FCount);
  FItems[FCount] := '';
  if (FCount > 0) and (Length(FItems) > FCount * 4) then
    SetLength(FItems, FCount);
end;

procedure TTextList.AddStrings(Src: TTextList);
var
  I: Integer;
begin
  if Src = nil then
    Exit;
  for I := 0 to Src.Count - 1 do
    Add(Src[I]);
end;

function TTextList.Text: UnicodeString;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to FCount - 1 do
    Result := Result + FItems[I] + #10;
end;

{ ===================== Утилиты строк ===================== }

function UTrim(const S: UnicodeString): UnicodeString;
var
  I, J: Integer;
begin
  I := 1;
  J := Length(S);
  while (I <= J) and (Ord(S[I]) <= 32) do
    Inc(I);
  while (J >= I) and (Ord(S[J]) <= 32) do
    Dec(J);
  Result := Copy(S, I, J - I + 1);
end;

function UTrimRight(const S: UnicodeString): UnicodeString;
var
  J: Integer;
begin
  J := Length(S);
  while (J >= 1) and (Ord(S[J]) <= 32) do
    Dec(J);
  Result := Copy(S, 1, J);
end;

function UReplace(const S, AOld, ANew: UnicodeString): UnicodeString;
var
  I, LA, LS: Integer;
begin
  Result := '';
  if AOld = '' then
    Exit(S);
  LA := Length(AOld);
  LS := Length(S);
  I := 1;
  while I <= LS do
  begin
    if (I + LA - 1 <= LS) and (Copy(S, I, LA) = AOld) then
    begin
      Result := Result + ANew;
      Inc(I, LA);
    end
    else
    begin
      Result := Result + S[I];
      Inc(I);
    end;
  end;
end;

function UIntToStr(V: Integer): UnicodeString;
begin
  Result := IntToStr(V);
end;

function JoinText(List: TTextList; const Sep: UnicodeString): UnicodeString;
var
  I: Integer;
begin
  Result := '';
  if List = nil then
    Exit;
  for I := 0 to List.Count - 1 do
  begin
    if I > 0 then
      Result := Result + Sep;
    Result := Result + List[I];
  end;
end;

{ ===================== Разметка ===================== }

constructor TStyleNode.Create(const ATag: UnicodeString;
  const AText: UnicodeString);
begin
  inherited Create;
  Tag := ATag;
  Text := AText;
  Children := TFb2ObjectList.Create;
end;

destructor TStyleNode.Destroy;
begin
  FreeAndNil(Children);
  inherited Destroy;
end;

{ ===================== Таблицы ===================== }

constructor TTableCell.Create(const ATag: UnicodeString;
  const AText: UnicodeString);
begin
  inherited Create(ATag, AText);
  Colspan := NO_VALUE;
  Rowspan := NO_VALUE;
  Align := alNone;
  VAlign := vaNone;
  IsHeader := False;
end;

constructor TTableRow.Create;
begin
  inherited Create;
  Cells := TFb2ObjectList.Create;
  Align := alNone;
end;

destructor TTableRow.Destroy;
begin
  FreeAndNil(Cells);
  inherited Destroy;
end;

constructor TTable.Create;
begin
  inherited Create;
  Rows := TFb2ObjectList.Create;
end;

destructor TTable.Destroy;
begin
  FreeAndNil(Rows);
  inherited Destroy;
end;

{ ===================== Блочные элементы ===================== }

constructor TParagraph.Create;
begin
  inherited Create;
  Content := TFb2ObjectList.Create;
end;

destructor TParagraph.Destroy;
begin
  FreeAndNil(Content);
  inherited Destroy;
end;

constructor TSubtitle.Create;
begin
  inherited Create;
  Content := TFb2ObjectList.Create;
end;

destructor TSubtitle.Destroy;
begin
  FreeAndNil(Content);
  inherited Destroy;
end;

constructor TTitle.Create;
begin
  inherited Create;
  Items := TFb2ObjectList.Create;
end;

destructor TTitle.Destroy;
begin
  FreeAndNil(Items);
  inherited Destroy;
end;

constructor TEpigraph.Create;
begin
  inherited Create;
  Items := TFb2ObjectList.Create;
  TextAuthor := TFb2ObjectList.Create;
end;

destructor TEpigraph.Destroy;
begin
  FreeAndNil(Items);
  FreeAndNil(TextAuthor);
  inherited Destroy;
end;

constructor TStanza.Create;
begin
  inherited Create;
  Verses := TFb2ObjectList.Create;
end;

destructor TStanza.Destroy;
begin
  FreeAndNil(Title);
  FreeAndNil(Subtitle);
  FreeAndNil(Verses);
  inherited Destroy;
end;

constructor TPoem.Create;
begin
  inherited Create;
  Epigraphs := TFb2ObjectList.Create;
  Items := TFb2ObjectList.Create;
  TextAuthor := TFb2ObjectList.Create;
end;

destructor TPoem.Destroy;
begin
  FreeAndNil(Title);
  FreeAndNil(Epigraphs);
  FreeAndNil(Items);
  FreeAndNil(TextAuthor);
  FreeAndNil(Date);
  inherited Destroy;
end;

constructor TCite.Create;
begin
  inherited Create;
  Items := TFb2ObjectList.Create;
  TextAuthor := TFb2ObjectList.Create;
end;

destructor TCite.Destroy;
begin
  FreeAndNil(Items);
  FreeAndNil(TextAuthor);
  inherited Destroy;
end;

constructor TAnnotation.Create;
begin
  inherited Create;
  Items := TFb2ObjectList.Create;
end;

destructor TAnnotation.Destroy;
begin
  FreeAndNil(Items);
  inherited Destroy;
end;

{ ===================== Секции и body ===================== }

constructor TSection.Create;
begin
  inherited Create;
  Epigraphs := TFb2ObjectList.Create;
  Sections := TFb2ObjectList.Create;
  Content := TFb2ObjectList.Create;
  HeadingId := NO_VALUE;
  ParentId := NO_VALUE;
end;

destructor TSection.Destroy;
begin
  FreeAndNil(Title);
  FreeAndNil(Epigraphs);
  FreeAndNil(Image);
  FreeAndNil(Annotation);
  FreeAndNil(Sections);
  FreeAndNil(Content);
  inherited Destroy;
end;

constructor TBody.Create;
begin
  inherited Create;
  Epigraphs := TFb2ObjectList.Create;
  Sections := TFb2ObjectList.Create;
  HeadingId := NO_VALUE;
  ParentId := NO_VALUE;
end;

destructor TBody.Destroy;
begin
  FreeAndNil(Image);
  FreeAndNil(Title);
  FreeAndNil(Epigraphs);
  FreeAndNil(Sections);
  inherited Destroy;
end;

{ ===================== Автор и серия ===================== }

constructor TAuthor.Create;
begin
  inherited Create;
  HomePages := TTextList.Create;
  Emails := TTextList.Create;
end;

destructor TAuthor.Destroy;
begin
  FreeAndNil(HomePages);
  FreeAndNil(Emails);
  inherited Destroy;
end;

constructor TSequence.Create;
begin
  inherited Create;
  Sequences := TFb2ObjectList.Create;
  Number := NO_VALUE;
end;

destructor TSequence.Destroy;
begin
  FreeAndNil(Sequences);
  inherited Destroy;
end;

{ ===================== Описание ===================== }

constructor TGenre.Create;
begin
  inherited Create;
  Match := 100;
end;

constructor TCoverPage.Create;
begin
  inherited Create;
  Images := TFb2ObjectList.Create;
end;

destructor TCoverPage.Destroy;
begin
  FreeAndNil(Images);
  inherited Destroy;
end;

constructor TOutputDocument.Create;
begin
  inherited Create;
  Parts := TFb2ObjectList.Create;
end;

destructor TOutputDocument.Destroy;
begin
  FreeAndNil(Parts);
  inherited Destroy;
end;

constructor TShareInstruction.Create;
begin
  inherited Create;
  Mode := smFree;
  IncludeAll := dgiAllow;
  Parts := TFb2ObjectList.Create;
  OutputDocuments := TFb2ObjectList.Create;
end;

destructor TShareInstruction.Destroy;
begin
  FreeAndNil(Parts);
  FreeAndNil(OutputDocuments);
  inherited Destroy;
end;

constructor TTitleInfo.Create;
begin
  inherited Create;
  Genres := TFb2ObjectList.Create;
  Authors := TFb2ObjectList.Create;
  Translators := TFb2ObjectList.Create;
  Sequences := TFb2ObjectList.Create;
end;

destructor TTitleInfo.Destroy;
begin
  FreeAndNil(Genres);
  FreeAndNil(Authors);
  FreeAndNil(BookTitle);
  FreeAndNil(Annotation);
  FreeAndNil(Keywords);
  FreeAndNil(Date);
  FreeAndNil(Coverpage);
  FreeAndNil(Translators);
  FreeAndNil(Sequences);
  inherited Destroy;
end;

constructor TDocumentInfo.Create;
begin
  inherited Create;
  Authors := TFb2ObjectList.Create;
  SrcUrls := TTextList.Create;
  Publishers := TFb2ObjectList.Create;
end;

destructor TDocumentInfo.Destroy;
begin
  FreeAndNil(Authors);
  FreeAndNil(ProgramUsed);
  FreeAndNil(Date);
  FreeAndNil(SrcUrls);
  FreeAndNil(SrcOcr);
  FreeAndNil(History);
  FreeAndNil(Publishers);
  inherited Destroy;
end;

constructor TPublishInfo.Create;
begin
  inherited Create;
  Sequences := TFb2ObjectList.Create;
end;

destructor TPublishInfo.Destroy;
begin
  FreeAndNil(BookName);
  FreeAndNil(Publisher);
  FreeAndNil(City);
  FreeAndNil(Isbn);
  FreeAndNil(Sequences);
  inherited Destroy;
end;

constructor TDescription.Create;
begin
  inherited Create;
  CustomInfos := TFb2ObjectList.Create;
  Outputs := TFb2ObjectList.Create;
end;

destructor TDescription.Destroy;
begin
  FreeAndNil(TitleInfo);
  FreeAndNil(SrcTitleInfo);
  FreeAndNil(DocumentInfo);
  FreeAndNil(PublishInfo);
  FreeAndNil(CustomInfos);
  FreeAndNil(Outputs);
  inherited Destroy;
end;

{ ===================== Корень ===================== }

constructor TFictionBook.Create;
begin
  inherited Create;
  Stylesheets := TFb2ObjectList.Create;
  Bodies := TFb2ObjectList.Create;
  Binaries := TFb2ObjectList.Create;
end;

destructor TFictionBook.Destroy;
begin
  FreeAndNil(Stylesheets);
  FreeAndNil(Description);
  FreeAndNil(Bodies);
  FreeAndNil(Binaries);
  inherited Destroy;
end;

end.