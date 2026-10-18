unit fb2_split_merge;
{ Слияние и разбиение FB2-файлов — перевод fb2_split_merge.py.

  Два класса:

      * TFb2Splitter — разбиение одной книги на части: по главам (секциям),
        по размеру (байтам) или на N частей. Метаданные копируются,
        <document-info>/<id> обновляется, в <title-info> добавляется
        <sequence> с номером части, а <binary> — только фактически
        используемые в части.
      * TFb2Merger — слияние нескольких книг в одну: объединение
        авторов/жанров, единый <body> (при желании с заголовком-обёрткой на
        каждую исходную книгу) и объединение <binary> с разрешением
        конфликтов id и перепривязкой ссылок.

  Пример разбиения:
      Splitter := TFb2Splitter.Create(1, SPLIT_MODE_SECTIONS);
      try
        Paths := Splitter.Split('book.fb2', 'parts');
        try ... finally Paths.Free; end;
      finally
        Splitter.Free;
      end;

  Пример слияния:
      Merger := TFb2Merger.Create('Сборник');
      try
        Merger.MergeToFile(Sources, 'collection.fb2');
      finally
        Merger.Free;
      end;

  Особенности перевода с Python:
      * источники задаются путями к файлам (file-like / ET.Element в Pascal
        отсутствуют);
      * copy.deepcopy заменён явными функциями клонирования структур
        (см. CloneObject ниже);
      * parser/writer создаются внутри классов (внедрение не поддерживается). }

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Classes, SysUtils, fgl,
  fb2_structures, fb2_parser, fb2_writer, fb2_errors;

const
  { Шаблон имени файла части по умолчанию (доступны stem, n, total). }
  DEFAULT_FILENAME_TEMPLATE = '{stem}_part{n:02d}.fb2';

  { Допустимые режимы разбиения. }
  SPLIT_MODE_SECTIONS = 'sections';
  SPLIT_MODE_SIZE = 'size';
  SPLIT_MODE_PARTS = 'parts';

type
  { --- внутренние типы разбиения (цепочки секций, без владения) ----- }

  { Цепочка секций-предков. }
  TSectionArr = array of TSection;

  { Единица разбиения: цепочка предков + секция. }
  TSplitUnit = record
    Ancestors: TSectionArr;
    Section: TSection;
  end;

  TSplitUnits = array of TSplitUnit;
  TSplitGroup = array of TSplitUnit;
  TSplitGroups = array of TSplitGroup;

  { Список книг (владеет ими) — используется в TFb2Merger. }
  TBookList = specialize TFPGObjectList<TFictionBook>;

  { Часть книги: имя файла + структура (владеет книгой). }
  TSplitPart = class
  public
    Name: UnicodeString;
    Book: TFictionBook;
    constructor Create(const AName: UnicodeString; ABook: TFictionBook);
    destructor Destroy; override;
  end;

  TSplitPartList = specialize TFPGObjectList<TSplitPart>;

  { Разбиение FB2-книги на части. }
  TFb2Splitter = class
  private
    FParser: TFb2Parser;
    FWriter: TFb2Writer;
    FLevel: Integer;
    FBy: UnicodeString;
    FMaxSize: Integer;
    FParts: Integer;
    FTitleSuffix: UnicodeString;
    FAddSequence: Boolean;
    FUpdateId: Boolean;
    FCopyBinaries: Boolean;
    FKeepExtraBodies: Boolean;
    FFilenameTemplate: UnicodeString;
    function ReadBook(const Source: UnicodeString): TFictionBook;
    function CollectUnits(Book: TFictionBook): TSplitUnits;
    function WalkSections(Sections: TFb2ObjectList; Level: Integer;
      const Ancestors: TSectionArr): TSplitUnits;
    function GroupUnits(const Units: TSplitUnits): TSplitGroups;
    function GroupBySize(const Units: TSplitUnits): TSplitGroups;
    function GroupByParts(const Units: TSplitUnits): TSplitGroups;
    function UnitSize(const U: TSplitUnit): Integer;
    function Skeleton(const Ancestors: TSectionArr;
      Section: TSection): TSection;
    function BuildPart(Book: TFictionBook; const Group: TSplitGroup;
      Number, Total: Integer): TFictionBook;
    function PartBody(SourceBody: TBody; const Group: TSplitGroup): TBody;
    function PartBinaries(Book: TFictionBook; Desc: TDescription;
      Bodies: TFb2ObjectList): TFb2ObjectList;
    procedure UpdateTitleInfo(Desc: TDescription; Number, Total: Integer);
    procedure UpdateDocumentInfo(Desc: TDescription);
  public
    constructor Create(Level: Integer = 1;
      const By: UnicodeString = SPLIT_MODE_SECTIONS;
      MaxSize: Integer = 0; Parts: Integer = 0;
      const TitleSuffix: UnicodeString = '';
      AddSequence: Boolean = True; UpdateId: Boolean = True;
      CopyBinaries: Boolean = True; KeepExtraBodies: Boolean = True;
      const FilenameTemplate: UnicodeString = DEFAULT_FILENAME_TEMPLATE);
    destructor Destroy; override;

    { Разбить FB2 и записать части; возвращает список путей (владеет он). }
    function Split(const Source: UnicodeString; const OutDir: UnicodeString = '';
      const Stem: UnicodeString = ''): TTextList;

    { Разбить книгу и вернуть пары (имя файла, книга). }
    function SplitBook(const Source: UnicodeString;
      const Stem: UnicodeString = 'book'): TSplitPartList;

    property By: UnicodeString read FBy;
    property Level: Integer read FLevel;
    property MaxSize: Integer read FMaxSize;
    property Parts: Integer read FParts;
  end;

  { Слияние нескольких FB2-книг в одну. }
  TFb2Merger = class
  private
    FParser: TFb2Parser;
    FWriter: TFb2Writer;
    FTitle: UnicodeString;
    FCombineMetadata: Boolean;
    FAddSourceTitles: Boolean;
    FMergeBinaries: Boolean;
    FUpdateId: Boolean;
    function ReadBook(const Source: UnicodeString): TFictionBook;
    function MergeDescription(Books: TBookList): TDescription;
    function MergeTitleInfo(Books: TBookList): TTitleInfo;
    function MergeBodies(Books: TBookList): TBody;
    function NewDocumentInfo(Books: TBookList): TDocumentInfo;
    function DoMergeBinaries(Books: TBookList): TFb2ObjectList;
  public
    constructor Create(const Title: UnicodeString = '';
      CombineMetadata: Boolean = True; AddSourceTitles: Boolean = True;
      MergeBinaries: Boolean = True; UpdateId: Boolean = True);
    destructor Destroy; override;

    { Слить книги в одну структуру (владелец — вызывающий). }
    function Merge(Sources: TTextList): TFictionBook;

    { Слить и записать в файл; возвращает путь. }
    function MergeToFile(Sources: TTextList;
      const Output: UnicodeString): UnicodeString;

    { Синоним MergeToFile. }
    function Write(Sources: TTextList;
      const Output: UnicodeString): UnicodeString;

    property Title: UnicodeString read FTitle write FTitle;
  end;

{ Режим разбиения допустим? }
function IsSplitMode(const By: UnicodeString): Boolean;

{ Новый идентификатор книги (urn:uuid). }
function NewUrnUuid: UnicodeString;

{ Поле даты с текущей датой (владелец — вызывающий). }
function TodayField: TDateField;

{ Имя файла части по шаблону (плейсхолдеры: stem, n, n:02d, total). }
function FormatPartName(const Template, Stem: UnicodeString;
  N, Total: Integer): UnicodeString;

implementation

{ ===================== Глубокая копия структур ===================== }
{ В Python используется copy.deepcopy; в Pascal — явные функции клонирования. }

function CloneObject(Obj: TFb2Object): TFb2Object; forward;

function CloneList(Src: TFb2ObjectList): TFb2ObjectList;
var
  I: Integer;
begin
  Result := TFb2ObjectList.Create;
  if Src = nil then
    Exit;
  for I := 0 to Src.Count - 1 do
    Result.Add(CloneObject(Src[I]));
end;

function CloneTextList(Src: TTextList): TTextList;
var
  I: Integer;
begin
  Result := TTextList.Create;
  if Src = nil then
    Exit;
  for I := 0 to Src.Count - 1 do
    Result.Add(Src[I]);
end;

{ Заменить список на копию исходного (nil -> пустой список). }
procedure SetObjList(var Target: TFb2ObjectList; Src: TFb2ObjectList);
begin
  FreeAndNil(Target);
  Target := CloneList(Src);
end;

procedure SetTextList(var Target: TTextList; Src: TTextList);
begin
  FreeAndNil(Target);
  Target := CloneTextList(Src);
end;

procedure CopyStyleFields(Src, Dst: TStyleNode);
begin
  Dst.Tag := Src.Tag;
  Dst.Text := Src.Text;
  SetObjList(Dst.Children, Src.Children);
  Dst.Href := Src.Href;
  Dst.StyleName := Src.StyleName;
  Dst.LinkType := Src.LinkType;
  Dst.ImageHref := Src.ImageHref;
  Dst.ImageAlt := Src.ImageAlt;
end;

function CloneStyleNode(Src: TStyleNode): TStyleNode;
begin
  Result := TStyleNode.Create(Src.Tag);
  CopyStyleFields(Src, Result);
end;

function CloneObject(Obj: TFb2Object): TFb2Object;
var
  R: TFb2Object;
begin
  Result := nil;
  if Obj = nil then
    Exit;

  { --- простые элементы --------------------------------------------- }
  if Obj is TTextField then
  begin
    R := TTextField.Create;
    TTextField(R).Value := TTextField(Obj).Value;
    TTextField(R).Lang := TTextField(Obj).Lang;
    Exit(R);
  end;

  if Obj is TDateField then
  begin
    R := TDateField.Create;
    TDateField(R).Value := TDateField(Obj).Value;
    TDateField(R).DateValue := TDateField(Obj).DateValue;
    TDateField(R).Lang := TDateField(Obj).Lang;
    Exit(R);
  end;

  if Obj is TCustomInfo then
  begin
    R := TCustomInfo.Create;
    TCustomInfo(R).Value := TCustomInfo(Obj).Value;
    TCustomInfo(R).InfoType := TCustomInfo(Obj).InfoType;
    Exit(R);
  end;

  if Obj is TStylesheet then
  begin
    R := TStylesheet.Create;
    TStylesheet(R).SheetType := TStylesheet(Obj).SheetType;
    TStylesheet(R).Value := TStylesheet(Obj).Value;
    Exit(R);
  end;

  { --- разметка (порядок важен: наследники раньше TStyleNode) ------ }
  if Obj is TTableCell then
  begin
    R := TTableCell.Create;
    CopyStyleFields(TTableCell(Obj), TStyleNode(R));
    TTableCell(R).Colspan := TTableCell(Obj).Colspan;
    TTableCell(R).Rowspan := TTableCell(Obj).Rowspan;
    TTableCell(R).Align := TTableCell(Obj).Align;
    TTableCell(R).VAlign := TTableCell(Obj).VAlign;
    TTableCell(R).Style := TTableCell(Obj).Style;
    TTableCell(R).Id := TTableCell(Obj).Id;
    TTableCell(R).IsHeader := TTableCell(Obj).IsHeader;
    Exit(R);
  end;

  if Obj is TStyleNode then
    Exit(CloneStyleNode(TStyleNode(Obj)));

  { --- таблицы ------------------------------------------------------ }
  if Obj is TTableRow then
  begin
    R := TTableRow.Create;
    TTableRow(R).Align := TTableRow(Obj).Align;
    SetObjList(TTableRow(R).Cells, TTableRow(Obj).Cells);
    Exit(R);
  end;

  if Obj is TTable then
  begin
    R := TTable.Create;
    SetObjList(TTable(R).Rows, TTable(Obj).Rows);
    TTable(R).Style := TTable(Obj).Style;
    TTable(R).Id := TTable(Obj).Id;
    Exit(R);
  end;

  { --- изображения и бинарные данные -------------------------------- }
  if Obj is TImage then
  begin
    R := TImage.Create;
    TImage(R).Href := TImage(Obj).Href;
    TImage(R).Alt := TImage(Obj).Alt;
    TImage(R).Title := TImage(Obj).Title;
    TImage(R).Id := TImage(Obj).Id;
    TImage(R).XlinkType := TImage(Obj).XlinkType;
    Exit(R);
  end;

  if Obj is TInlineImage then
  begin
    R := TInlineImage.Create;
    TInlineImage(R).Href := TInlineImage(Obj).Href;
    TInlineImage(R).Alt := TInlineImage(Obj).Alt;
    TInlineImage(R).XlinkType := TInlineImage(Obj).XlinkType;
    Exit(R);
  end;

  if Obj is TBinary then
  begin
    R := TBinary.Create;
    TBinary(R).Id := TBinary(Obj).Id;
    TBinary(R).ContentType := TBinary(Obj).ContentType;
    TBinary(R).Data := TBinary(Obj).Data;
    Exit(R);
  end;

  { --- блочные элементы --------------------------------------------- }
  if Obj is TParagraph then
  begin
    R := TParagraph.Create;
    SetObjList(TParagraph(R).Content, TParagraph(Obj).Content);
    TParagraph(R).Id := TParagraph(Obj).Id;
    TParagraph(R).Style := TParagraph(Obj).Style;
    TParagraph(R).Lang := TParagraph(Obj).Lang;
    Exit(R);
  end;

  if Obj is TSubtitle then
  begin
    R := TSubtitle.Create;
    SetObjList(TSubtitle(R).Content, TSubtitle(Obj).Content);
    TSubtitle(R).Id := TSubtitle(Obj).Id;
    TSubtitle(R).Style := TSubtitle(Obj).Style;
    TSubtitle(R).Lang := TSubtitle(Obj).Lang;
    Exit(R);
  end;

  if Obj is TEmptyLine then
  begin
    R := TEmptyLine.Create;
    Exit(R);
  end;

  if Obj is TTitle then
  begin
    R := TTitle.Create;
    SetObjList(TTitle(R).Items, TTitle(Obj).Items);
    TTitle(R).Lang := TTitle(Obj).Lang;
    Exit(R);
  end;

  if Obj is TEpigraph then
  begin
    R := TEpigraph.Create;
    SetObjList(TEpigraph(R).Items, TEpigraph(Obj).Items);
    SetObjList(TEpigraph(R).TextAuthor, TEpigraph(Obj).TextAuthor);
    TEpigraph(R).Id := TEpigraph(Obj).Id;
    Exit(R);
  end;

  if Obj is TStanza then
  begin
    R := TStanza.Create;
    if TStanza(Obj).Title <> nil then
      TStanza(R).Title := TTitle(CloneObject(TStanza(Obj).Title));
    if TStanza(Obj).Subtitle <> nil then
      TStanza(R).Subtitle := TSubtitle(CloneObject(TStanza(Obj).Subtitle));
    SetObjList(TStanza(R).Verses, TStanza(Obj).Verses);
    TStanza(R).Lang := TStanza(Obj).Lang;
    Exit(R);
  end;

  if Obj is TPoem then
  begin
    R := TPoem.Create;
    if TPoem(Obj).Title <> nil then
      TPoem(R).Title := TTitle(CloneObject(TPoem(Obj).Title));
    SetObjList(TPoem(R).Epigraphs, TPoem(Obj).Epigraphs);
    SetObjList(TPoem(R).Items, TPoem(Obj).Items);
    SetObjList(TPoem(R).TextAuthor, TPoem(Obj).TextAuthor);
    if TPoem(Obj).Date <> nil then
      TPoem(R).Date := TDateField(CloneObject(TPoem(Obj).Date));
    TPoem(R).Id := TPoem(Obj).Id;
    TPoem(R).Lang := TPoem(Obj).Lang;
    Exit(R);
  end;

  if Obj is TCite then
  begin
    R := TCite.Create;
    SetObjList(TCite(R).Items, TCite(Obj).Items);
    SetObjList(TCite(R).TextAuthor, TCite(Obj).TextAuthor);
    TCite(R).Id := TCite(Obj).Id;
    TCite(R).Lang := TCite(Obj).Lang;
    Exit(R);
  end;

  if Obj is TAnnotation then
  begin
    R := TAnnotation.Create;
    SetObjList(TAnnotation(R).Items, TAnnotation(Obj).Items);
    TAnnotation(R).Id := TAnnotation(Obj).Id;
    TAnnotation(R).Lang := TAnnotation(Obj).Lang;
    Exit(R);
  end;

  { --- секции и body ------------------------------------------------ }
  if Obj is TSection then
  begin
    R := TSection.Create;
    if TSection(Obj).Title <> nil then
      TSection(R).Title := TTitle(CloneObject(TSection(Obj).Title));
    SetObjList(TSection(R).Epigraphs, TSection(Obj).Epigraphs);
    if TSection(Obj).Image <> nil then
      TSection(R).Image := TImage(CloneObject(TSection(Obj).Image));
    if TSection(Obj).Annotation <> nil then
      TSection(R).Annotation := TAnnotation(CloneObject(TSection(Obj).Annotation));
    SetObjList(TSection(R).Sections, TSection(Obj).Sections);
    SetObjList(TSection(R).Content, TSection(Obj).Content);
    TSection(R).Id := TSection(Obj).Id;
    TSection(R).Lang := TSection(Obj).Lang;
    TSection(R).HeadingId := TSection(Obj).HeadingId;
    TSection(R).ParentId := TSection(Obj).ParentId;
    Exit(R);
  end;

  if Obj is TBody then
  begin
    R := TBody.Create;
    if TBody(Obj).Image <> nil then
      TBody(R).Image := TImage(CloneObject(TBody(Obj).Image));
    if TBody(Obj).Title <> nil then
      TBody(R).Title := TTitle(CloneObject(TBody(Obj).Title));
    SetObjList(TBody(R).Epigraphs, TBody(Obj).Epigraphs);
    SetObjList(TBody(R).Sections, TBody(Obj).Sections);
    TBody(R).Name := TBody(Obj).Name;
    TBody(R).Lang := TBody(Obj).Lang;
    TBody(R).HeadingId := TBody(Obj).HeadingId;
    TBody(R).ParentId := TBody(Obj).ParentId;
    Exit(R);
  end;

  { --- автор, серия, жанр, обложка ---------------------------------- }
  if Obj is TAuthor then
  begin
    R := TAuthor.Create;
    TAuthor(R).FirstName := TAuthor(Obj).FirstName;
    TAuthor(R).MiddleName := TAuthor(Obj).MiddleName;
    TAuthor(R).LastName := TAuthor(Obj).LastName;
    TAuthor(R).Nickname := TAuthor(Obj).Nickname;
    SetTextList(TAuthor(R).HomePages, TAuthor(Obj).HomePages);
    SetTextList(TAuthor(R).Emails, TAuthor(Obj).Emails);
    TAuthor(R).Id := TAuthor(Obj).Id;
    Exit(R);
  end;

  if Obj is TSequence then
  begin
    R := TSequence.Create;
    TSequence(R).Name := TSequence(Obj).Name;
    TSequence(R).Number := TSequence(Obj).Number;
    TSequence(R).Lang := TSequence(Obj).Lang;
    SetObjList(TSequence(R).Sequences, TSequence(Obj).Sequences);
    Exit(R);
  end;

  if Obj is TGenre then
  begin
    R := TGenre.Create;
    TGenre(R).Value := TGenre(Obj).Value;
    TGenre(R).Match := TGenre(Obj).Match;
    Exit(R);
  end;

  if Obj is TCoverPage then
  begin
    R := TCoverPage.Create;
    SetObjList(TCoverPage(R).Images, TCoverPage(Obj).Images);
    Exit(R);
  end;

  { --- output (shareInstructionType) -------------------------------- }
  if Obj is TPartShareInstruction then
  begin
    R := TPartShareInstruction.Create;
    TPartShareInstruction(R).Href := TPartShareInstruction(Obj).Href;
    TPartShareInstruction(R).IncludeInstr :=
      TPartShareInstruction(Obj).IncludeInstr;
    TPartShareInstruction(R).XlinkType := TPartShareInstruction(Obj).XlinkType;
    Exit(R);
  end;

  if Obj is TOutputDocument then
  begin
    R := TOutputDocument.Create;
    TOutputDocument(R).Name := TOutputDocument(Obj).Name;
    TOutputDocument(R).CreateInstr := TOutputDocument(Obj).CreateInstr;
    TOutputDocument(R).Price := TOutputDocument(Obj).Price;
    TOutputDocument(R).HasPrice := TOutputDocument(Obj).HasPrice;
    SetObjList(TOutputDocument(R).Parts, TOutputDocument(Obj).Parts);
    Exit(R);
  end;

  if Obj is TShareInstruction then
  begin
    R := TShareInstruction.Create;
    TShareInstruction(R).Mode := TShareInstruction(Obj).Mode;
    TShareInstruction(R).IncludeAll := TShareInstruction(Obj).IncludeAll;
    TShareInstruction(R).Price := TShareInstruction(Obj).Price;
    TShareInstruction(R).HasPrice := TShareInstruction(Obj).HasPrice;
    TShareInstruction(R).Currency := TShareInstruction(Obj).Currency;
    SetObjList(TShareInstruction(R).Parts, TShareInstruction(Obj).Parts);
    SetObjList(TShareInstruction(R).OutputDocuments,
      TShareInstruction(Obj).OutputDocuments);
    Exit(R);
  end;

  { --- описание книги ----------------------------------------------- }
  if Obj is TTitleInfo then
  begin
    R := TTitleInfo.Create;
    SetObjList(TTitleInfo(R).Genres, TTitleInfo(Obj).Genres);
    SetObjList(TTitleInfo(R).Authors, TTitleInfo(Obj).Authors);
    if TTitleInfo(Obj).BookTitle <> nil then
      TTitleInfo(R).BookTitle := TTextField(CloneObject(TTitleInfo(Obj).BookTitle));
    if TTitleInfo(Obj).Annotation <> nil then
      TTitleInfo(R).Annotation :=
        TAnnotation(CloneObject(TTitleInfo(Obj).Annotation));
    if TTitleInfo(Obj).Keywords <> nil then
      TTitleInfo(R).Keywords := TTextField(CloneObject(TTitleInfo(Obj).Keywords));
    if TTitleInfo(Obj).Date <> nil then
      TTitleInfo(R).Date := TDateField(CloneObject(TTitleInfo(Obj).Date));
    if TTitleInfo(Obj).Coverpage <> nil then
      TTitleInfo(R).Coverpage :=
        TCoverPage(CloneObject(TTitleInfo(Obj).Coverpage));
    TTitleInfo(R).Lang := TTitleInfo(Obj).Lang;
    TTitleInfo(R).SrcLang := TTitleInfo(Obj).SrcLang;
    SetObjList(TTitleInfo(R).Translators, TTitleInfo(Obj).Translators);
    SetObjList(TTitleInfo(R).Sequences, TTitleInfo(Obj).Sequences);
    Exit(R);
  end;

  if Obj is TDocumentInfo then
  begin
    R := TDocumentInfo.Create;
    SetObjList(TDocumentInfo(R).Authors, TDocumentInfo(Obj).Authors);
    if TDocumentInfo(Obj).ProgramUsed <> nil then
      TDocumentInfo(R).ProgramUsed :=
        TTextField(CloneObject(TDocumentInfo(Obj).ProgramUsed));
    if TDocumentInfo(Obj).Date <> nil then
      TDocumentInfo(R).Date := TDateField(CloneObject(TDocumentInfo(Obj).Date));
    SetTextList(TDocumentInfo(R).SrcUrls, TDocumentInfo(Obj).SrcUrls);
    if TDocumentInfo(Obj).SrcOcr <> nil then
      TDocumentInfo(R).SrcOcr := TTextField(CloneObject(TDocumentInfo(Obj).SrcOcr));
    TDocumentInfo(R).Id := TDocumentInfo(Obj).Id;
    TDocumentInfo(R).Version := TDocumentInfo(Obj).Version;
    TDocumentInfo(R).HasVersion := TDocumentInfo(Obj).HasVersion;
    if TDocumentInfo(Obj).History <> nil then
      TDocumentInfo(R).History :=
        TAnnotation(CloneObject(TDocumentInfo(Obj).History));
    SetObjList(TDocumentInfo(R).Publishers, TDocumentInfo(Obj).Publishers);
    Exit(R);
  end;

  if Obj is TPublishInfo then
  begin
    R := TPublishInfo.Create;
    if TPublishInfo(Obj).BookName <> nil then
      TPublishInfo(R).BookName := TTextField(CloneObject(TPublishInfo(Obj).BookName));
    if TPublishInfo(Obj).Publisher <> nil then
      TPublishInfo(R).Publisher :=
        TTextField(CloneObject(TPublishInfo(Obj).Publisher));
    if TPublishInfo(Obj).City <> nil then
      TPublishInfo(R).City := TTextField(CloneObject(TPublishInfo(Obj).City));
    TPublishInfo(R).Year := TPublishInfo(Obj).Year;
    if TPublishInfo(Obj).Isbn <> nil then
      TPublishInfo(R).Isbn := TTextField(CloneObject(TPublishInfo(Obj).Isbn));
    SetObjList(TPublishInfo(R).Sequences, TPublishInfo(Obj).Sequences);
    Exit(R);
  end;

  if Obj is TDescription then
  begin
    R := TDescription.Create;
    if TDescription(Obj).TitleInfo <> nil then
      TDescription(R).TitleInfo :=
        TTitleInfo(CloneObject(TDescription(Obj).TitleInfo));
    if TDescription(Obj).SrcTitleInfo <> nil then
      TDescription(R).SrcTitleInfo :=
        TTitleInfo(CloneObject(TDescription(Obj).SrcTitleInfo));
    if TDescription(Obj).DocumentInfo <> nil then
      TDescription(R).DocumentInfo :=
        TDocumentInfo(CloneObject(TDescription(Obj).DocumentInfo));
    if TDescription(Obj).PublishInfo <> nil then
      TDescription(R).PublishInfo :=
        TPublishInfo(CloneObject(TDescription(Obj).PublishInfo));
    SetObjList(TDescription(R).CustomInfos, TDescription(Obj).CustomInfos);
    SetObjList(TDescription(R).Outputs, TDescription(Obj).Outputs);
    Exit(R);
  end;

  if Obj is TFictionBook then
  begin
    R := TFictionBook.Create;
    SetObjList(TFictionBook(R).Stylesheets, TFictionBook(Obj).Stylesheets);
    if TFictionBook(Obj).Description <> nil then
      TFictionBook(R).Description :=
        TDescription(CloneObject(TFictionBook(Obj).Description));
    SetObjList(TFictionBook(R).Bodies, TFictionBook(Obj).Bodies);
    SetObjList(TFictionBook(R).Binaries, TFictionBook(Obj).Binaries);
    Exit(R);
  end;
end;

{ ===================== Перепривязка ссылок на изображения ===================== }

type
  { Функция преобразования href (аналог HrefMapper в Python). }
  THrefMapper = function(const Href: UnicodeString): UnicodeString of object;

  { Сборщик id ссылок вида "#id" (значения не меняет). }
  TIdCollector = class
  private
    FUsed: TStringList;
  public
    constructor Create;
    destructor Destroy; override;
    function Map(const Href: UnicodeString): UnicodeString;
    function Contains(const Id: UnicodeString): Boolean;
  end;

  { Перепривязка "#old" -> "#new" по словарю (остальное без изменений). }
  TRemapper = class
  private
    FMapping: TStringList;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Add(const OldId, NewId: UnicodeString);
    function Map(const Href: UnicodeString): UnicodeString;
  end;

constructor TIdCollector.Create;
begin
  inherited Create;
  FUsed := TStringList.Create;
  FUsed.Sorted := True;
  FUsed.Duplicates := dupIgnore;
end;

destructor TIdCollector.Destroy;
begin
  FreeAndNil(FUsed);
  inherited Destroy;
end;

function TIdCollector.Map(const Href: UnicodeString): UnicodeString;
begin
  if (Href <> '') and (Href[1] = '#') then
    FUsed.Add(Copy(Href, 2, MaxInt));
  Result := Href;
end;

function TIdCollector.Contains(const Id: UnicodeString): Boolean;
begin
  Result := FUsed.IndexOf(Id) >= 0;
end;

constructor TRemapper.Create;
begin
  inherited Create;
  FMapping := TStringList.Create;
end;

destructor TRemapper.Destroy;
begin
  FreeAndNil(FMapping);
  inherited Destroy;
end;

procedure TRemapper.Add(const OldId, NewId: UnicodeString);
begin
  FMapping.Values[OldId] := NewId;
end;

function TRemapper.Map(const Href: UnicodeString): UnicodeString;
var
  Idx: Integer;
begin
  Result := Href;
  if (Href = '') or (Href[1] <> '#') then
    Exit;
  Idx := FMapping.IndexOfName(Copy(Href, 2, MaxInt));
  if Idx >= 0 then
    Result := '#' + FMapping.ValueFromIndex[Idx];
end;

{ --- Обход дерева книги с преобразованием ссылок --------------------- }

procedure MapMarkup(Nodes: TFb2ObjectList; Mapper: THrefMapper); forward;
procedure MapTitle(T: TTitle; Mapper: THrefMapper); forward;
procedure MapStanza(S: TStanza; Mapper: THrefMapper); forward;
procedure MapPoem(P: TPoem; Mapper: THrefMapper); forward;
procedure MapEpigraph(E: TEpigraph; Mapper: THrefMapper); forward;
procedure MapCite(C: TCite; Mapper: THrefMapper); forward;
procedure MapTable(T: TTable; Mapper: THrefMapper); forward;
procedure MapAnnotation(A: TAnnotation; Mapper: THrefMapper); forward;
procedure MapBlock(Block: TFb2Object; Mapper: THrefMapper); forward;
procedure MapSection(S: TSection; Mapper: THrefMapper); forward;

procedure MapMarkup(Nodes: TFb2ObjectList; Mapper: THrefMapper);
var
  I: Integer;
  Node: TStyleNode;
begin
  if Nodes = nil then
    Exit;
  for I := 0 to Nodes.Count - 1 do
  begin
    Node := TStyleNode(Nodes[I]);
    if (Node.Tag = 'image') and (Node.ImageHref <> '') then
      Node.ImageHref := Mapper(Node.ImageHref);
    if Node.Children <> nil then
      MapMarkup(Node.Children, Mapper);
  end;
end;

procedure MapTitle(T: TTitle; Mapper: THrefMapper);
var
  I: Integer;
begin
  if T = nil then
    Exit;
  for I := 0 to T.Items.Count - 1 do
    if T.Items[I] is TParagraph then
      MapMarkup(TParagraph(T.Items[I]).Content, Mapper);
end;

procedure MapStanza(S: TStanza; Mapper: THrefMapper);
var
  I: Integer;
begin
  MapTitle(S.Title, Mapper);
  if S.Subtitle <> nil then
    MapMarkup(S.Subtitle.Content, Mapper);
  for I := 0 to S.Verses.Count - 1 do
    MapMarkup(TParagraph(S.Verses[I]).Content, Mapper);
end;

procedure MapPoem(P: TPoem; Mapper: THrefMapper);
var
  I: Integer;
begin
  MapTitle(P.Title, Mapper);
  for I := 0 to P.Epigraphs.Count - 1 do
    MapEpigraph(TEpigraph(P.Epigraphs[I]), Mapper);
  for I := 0 to P.Items.Count - 1 do
  begin
    if P.Items[I] is TStanza then
      MapStanza(TStanza(P.Items[I]), Mapper)
    else if P.Items[I] is TSubtitle then
      MapMarkup(TSubtitle(P.Items[I]).Content, Mapper);
  end;
  for I := 0 to P.TextAuthor.Count - 1 do
    MapMarkup(TParagraph(P.TextAuthor[I]).Content, Mapper);
end;

procedure MapEpigraph(E: TEpigraph; Mapper: THrefMapper);
var
  I: Integer;
begin
  for I := 0 to E.Items.Count - 1 do
    MapBlock(E.Items[I], Mapper);
  for I := 0 to E.TextAuthor.Count - 1 do
    MapMarkup(TParagraph(E.TextAuthor[I]).Content, Mapper);
end;

procedure MapCite(C: TCite; Mapper: THrefMapper);
var
  I: Integer;
begin
  for I := 0 to C.Items.Count - 1 do
    MapBlock(C.Items[I], Mapper);
  for I := 0 to C.TextAuthor.Count - 1 do
    MapMarkup(TParagraph(C.TextAuthor[I]).Content, Mapper);
end;

procedure MapTable(T: TTable; Mapper: THrefMapper);
var
  I, J: Integer;
begin
  for I := 0 to T.Rows.Count - 1 do
    for J := 0 to TTableRow(T.Rows[I]).Cells.Count - 1 do
      MapMarkup(TTableCell(TTableRow(T.Rows[I]).Cells[J]).Children, Mapper);
end;

procedure MapAnnotation(A: TAnnotation; Mapper: THrefMapper);
var
  I: Integer;
begin
  if A = nil then
    Exit;
  for I := 0 to A.Items.Count - 1 do
    MapBlock(A.Items[I], Mapper);
end;

procedure MapBlock(Block: TFb2Object; Mapper: THrefMapper);
begin
  if Block = nil then
    Exit;
  if Block is TParagraph then
    MapMarkup(TParagraph(Block).Content, Mapper)
  else if Block is TSubtitle then
    MapMarkup(TSubtitle(Block).Content, Mapper)
  else if Block is TImage then
  begin
    if TImage(Block).Href <> '' then
      TImage(Block).Href := Mapper(TImage(Block).Href);
  end
  else if Block is TPoem then
    MapPoem(TPoem(Block), Mapper)
  else if Block is TCite then
    MapCite(TCite(Block), Mapper)
  else if Block is TEpigraph then
    MapEpigraph(TEpigraph(Block), Mapper)
  else if Block is TTable then
    MapTable(TTable(Block), Mapper)
  else if Block is TSection then
    MapSection(TSection(Block), Mapper);
end;

procedure MapSection(S: TSection; Mapper: THrefMapper);
var
  I: Integer;
begin
  MapTitle(S.Title, Mapper);
  for I := 0 to S.Epigraphs.Count - 1 do
    MapEpigraph(TEpigraph(S.Epigraphs[I]), Mapper);
  if (S.Image <> nil) and (S.Image.Href <> '') then
    S.Image.Href := Mapper(S.Image.Href);
  MapAnnotation(S.Annotation, Mapper);
  for I := 0 to S.Content.Count - 1 do
    MapBlock(S.Content[I], Mapper);
  for I := 0 to S.Sections.Count - 1 do
    MapSection(TSection(S.Sections[I]), Mapper);
end;

procedure MapBody(B: TBody; Mapper: THrefMapper);
var
  I: Integer;
begin
  if (B.Image <> nil) and (B.Image.Href <> '') then
    B.Image.Href := Mapper(B.Image.Href);
  MapTitle(B.Title, Mapper);
  for I := 0 to B.Epigraphs.Count - 1 do
    MapEpigraph(TEpigraph(B.Epigraphs[I]), Mapper);
  for I := 0 to B.Sections.Count - 1 do
    MapSection(TSection(B.Sections[I]), Mapper);
end;

procedure MapTitleInfo(TI: TTitleInfo; Mapper: THrefMapper);
var
  I: Integer;
begin
  if (TI = nil) or (TI.Coverpage = nil) then
    Exit;
  for I := 0 to TI.Coverpage.Images.Count - 1 do
    if TInlineImage(TI.Coverpage.Images[I]).Href <> '' then
      TInlineImage(TI.Coverpage.Images[I]).Href :=
        Mapper(TInlineImage(TI.Coverpage.Images[I]).Href);
end;

procedure MapBookImages(Book: TFictionBook; Mapper: THrefMapper);
var
  I: Integer;
begin
  if Book.Description <> nil then
    MapTitleInfo(Book.Description.TitleInfo, Mapper);
  for I := 0 to Book.Bodies.Count - 1 do
    MapBody(TBody(Book.Bodies[I]), Mapper);
end;

{ ===================== Даты, uuid, имена файлов ===================== }

{ Нижний регистр для ASCII (GUID-строка). }
function AsciiLower(const S: UnicodeString): UnicodeString;
var
  I: Integer;
begin
  Result := S;
  for I := 1 to Length(Result) do
    if (Result[I] >= 'A') and (Result[I] <= 'Z') then
      Result[I] := WideChar(Ord(Result[I]) + 32);
end;

function NewUrnUuid: UnicodeString;
var
  G: TGUID;
  S: UnicodeString;
begin
  CreateGUID(G);
  S := GUIDToString(G);
  if (Length(S) >= 2) and (S[1] = '{') then
    S := Copy(S, 2, Length(S) - 2);
  Result := 'urn:uuid:' + AsciiLower(S);
end;

function TodayField: TDateField;
var
  S: UnicodeString;
begin
  S := FormatDateTime('yyyy-mm-dd', Date);
  Result := TDateField.Create;
  Result.Value := S;
  Result.DateValue := S;
end;

function FormatIntSpec(V: Integer; const Spec: UnicodeString): UnicodeString;
begin
  if (Spec = '02d') or (Spec = '02') then
    Result := Format('%.2d', [V])
  else
    Result := IntToStr(V);
end;

function ExpandPlaceholder(const Key, Stem: UnicodeString;
  N, Total: Integer): UnicodeString;
var
  Name, Spec: UnicodeString;
  P: Integer;
begin
  P := Pos(':', Key);
  if P > 0 then
  begin
    Name := Copy(Key, 1, P - 1);
    Spec := Copy(Key, P + 1, MaxInt);
  end
  else
  begin
    Name := Key;
    Spec := '';
  end;

  if Name = 'stem' then
    Result := Stem
  else if Name = 'n' then
    Result := FormatIntSpec(N, Spec)
  else if Name = 'total' then
    Result := FormatIntSpec(Total, Spec)
  else
    Result := '{' + Key + '}';
end;

function FormatPartName(const Template, Stem: UnicodeString;
  N, Total: Integer): UnicodeString;
var
  I, J: Integer;
begin
  Result := '';
  I := 1;
  while I <= Length(Template) do
  begin
    if Template[I] = '{' then
    begin
      J := I + 1;
      while (J <= Length(Template)) and (Template[J] <> '}') do
        Inc(J);
      if J > Length(Template) then
      begin
        Result := Result + Copy(Template, I, MaxInt);
        Break;
      end;
      Result := Result + ExpandPlaceholder(
        Copy(Template, I + 1, J - I - 1), Stem, N, Total);
      I := J + 1;
    end
    else
    begin
      Result := Result + Template[I];
      Inc(I);
    end;
  end;
end;

function IsSplitMode(const By: UnicodeString): Boolean;
begin
  Result := (By = SPLIT_MODE_SECTIONS) or (By = SPLIT_MODE_SIZE) or
    (By = SPLIT_MODE_PARTS);
end;

{ ===================== TSplitPart ===================== }

constructor TSplitPart.Create(const AName: UnicodeString; ABook: TFictionBook);
begin
  inherited Create;
  Name := AName;
  Book := ABook;
end;

destructor TSplitPart.Destroy;
begin
  FreeAndNil(Book);
  inherited Destroy;
end;

{ ===================== TFb2Splitter ===================== }

function CopySectionArr(const Anc: TSectionArr): TSectionArr;
begin
  SetLength(Result, Length(Anc));
  if Length(Anc) > 0 then
    Move(Anc[0], Result[0], Length(Anc) * SizeOf(TSection));
end;

function AppendSection(const Anc: TSectionArr; S: TSection): TSectionArr;
begin
  SetLength(Result, Length(Anc) + 1);
  if Length(Anc) > 0 then
    Move(Anc[0], Result[0], Length(Anc) * SizeOf(TSection));
  Result[High(Result)] := S;
end;

procedure AddUnit(var Units: TSplitUnits; const U: TSplitUnit);
begin
  SetLength(Units, Length(Units) + 1);
  Units[High(Units)] := U;
end;

procedure AddGroup(var Groups: TSplitGroups; const G: TSplitGroup);
begin
  SetLength(Groups, Length(Groups) + 1);
  Groups[High(Groups)] := G;
end;

procedure AddToGroup(var G: TSplitGroup; const U: TSplitUnit);
begin
  SetLength(G, Length(G) + 1);
  G[High(G)] := U;
end;

{ Дописать объекты Src в Dst и освободить контейнер Src без удаления
  объектов (Extract не освобождает элемент). }
procedure MoveList(Dst, Src: TFb2ObjectList);
begin
  if (Dst = nil) or (Src = nil) then
    Exit;
  while Src.Count > 0 do
    Dst.Add(Src.Extract(Src[Src.Count - 1]));
  Src.Free;
end;

constructor TFb2Splitter.Create(Level: Integer; const By: UnicodeString;
  MaxSize: Integer; Parts: Integer; const TitleSuffix: UnicodeString;
  AddSequence: Boolean; UpdateId: Boolean; CopyBinaries: Boolean;
  KeepExtraBodies: Boolean; const FilenameTemplate: UnicodeString);
begin
  inherited Create;
  if not IsSplitMode(By) then
    raise EFb2ConversionError.CreateFmt(
      'Неизвестный режим разбиения: %s (ожидается sections/size/parts)', [By]);
  if (By = SPLIT_MODE_SIZE) and (MaxSize <= 0) then
    raise EFb2ConversionError.Create('Для by=size требуется max_size > 0');
  if (By = SPLIT_MODE_PARTS) and (Parts <= 0) then
    raise EFb2ConversionError.Create('Для by=parts требуется parts > 0');

  FParser := TFb2Parser.Create;
  FWriter := TFb2Writer.Create;
  if Level < 1 then
    FLevel := 1
  else
    FLevel := Level;
  FBy := By;
  FMaxSize := MaxSize;
  FParts := Parts;
  FTitleSuffix := TitleSuffix;
  FAddSequence := AddSequence;
  FUpdateId := UpdateId;
  FCopyBinaries := CopyBinaries;
  FKeepExtraBodies := KeepExtraBodies;
  FFilenameTemplate := FilenameTemplate;
end;

destructor TFb2Splitter.Destroy;
begin
  FreeAndNil(FParser);
  FreeAndNil(FWriter);
  inherited Destroy;
end;

function TFb2Splitter.ReadBook(const Source: UnicodeString): TFictionBook;
begin
  FParser.LoadFile(Source);
  Result := TFictionBook.Create;
  try
    FreeAndNil(Result.Stylesheets);
    Result.Stylesheets := FParser.ParseStylesheets;
    Result.Description := FParser.Parse;
    FreeAndNil(Result.Bodies);
    Result.Bodies := FParser.ParseBodies;
    FreeAndNil(Result.Binaries);
    Result.Binaries := FParser.ParseBinaries;
  except
    FreeAndNil(Result);
    raise;
  end;
end;

function TFb2Splitter.CollectUnits(Book: TFictionBook): TSplitUnits;
begin
  SetLength(Result, 0);
  if Book.Bodies.Count = 0 then
    Exit;
  Result := WalkSections(TBody(Book.Bodies[0]).Sections, FLevel, nil);
end;

function TFb2Splitter.WalkSections(Sections: TFb2ObjectList; Level: Integer;
  const Ancestors: TSectionArr): TSplitUnits;
var
  I, J: Integer;
  Sub: TSplitUnits;
  U: TSplitUnit;
begin
  SetLength(Result, 0);
  if Sections = nil then
    Exit;
  for I := 0 to Sections.Count - 1 do
  begin
    if (Level <= 1) or (TSection(Sections[I]).Sections.Count = 0) then
    begin
      U.Ancestors := CopySectionArr(Ancestors);
      U.Section := TSection(Sections[I]);
      AddUnit(Result, U);
    end
    else
    begin
      Sub := WalkSections(TSection(Sections[I]).Sections, Level - 1,
        AppendSection(Ancestors, TSection(Sections[I])));
      for J := 0 to High(Sub) do
        AddUnit(Result, Sub[J]);
    end;
  end;
end;

function TFb2Splitter.GroupUnits(const Units: TSplitUnits): TSplitGroups;
var
  I: Integer;
begin
  SetLength(Result, 0);
  if FBy = SPLIT_MODE_SECTIONS then
  begin
    SetLength(Result, Length(Units));
    for I := 0 to High(Units) do
    begin
      SetLength(Result[I], 1);
      Result[I][0] := Units[I];
    end;
    Exit;
  end;
  if FBy = SPLIT_MODE_SIZE then
    Result := GroupBySize(Units)
  else
    Result := GroupByParts(Units);
end;

function TFb2Splitter.GroupBySize(const Units: TSplitUnits): TSplitGroups;
var
  I, Size: Integer;
  Cur: TSplitGroup;
  CurSize: Int64;
begin
  SetLength(Result, 0);
  SetLength(Cur, 0);
  CurSize := 0;
  for I := 0 to High(Units) do
  begin
    Size := UnitSize(Units[I]);
    if (Length(Cur) > 0) and (CurSize + Size > FMaxSize) then
    begin
      AddGroup(Result, Cur);
      SetLength(Cur, 0);
      CurSize := 0;
    end;
    AddToGroup(Cur, Units[I]);
    Inc(CurSize, Size);
  end;
  if Length(Cur) > 0 then
    AddGroup(Result, Cur);
end;

function TFb2Splitter.GroupByParts(const Units: TSplitUnits): TSplitGroups;
var
  Sizes: array of Integer;
  I: Integer;
  TotalSize: Int64;
  Target: Double;
  Cur: TSplitGroup;
  CurSize: Int64;
begin
  SetLength(Result, 0);
  SetLength(Sizes, Length(Units));
  TotalSize := 0;
  for I := 0 to High(Units) do
  begin
    Sizes[I] := UnitSize(Units[I]);
    Inc(TotalSize, Sizes[I]);
  end;
  if TotalSize = 0 then
    TotalSize := 1;
  Target := TotalSize / FParts;

  SetLength(Cur, 0);
  CurSize := 0;
  for I := 0 to High(Units) do
  begin
    AddToGroup(Cur, Units[I]);
    Inc(CurSize, Sizes[I]);
    if (Length(Result) < FParts - 1) and (CurSize >= Target) then
    begin
      AddGroup(Result, Cur);
      SetLength(Cur, 0);
      CurSize := 0;
    end;
  end;
  if Length(Cur) > 0 then
    AddGroup(Result, Cur);
end;

{ Длина XML-декларации в начале строки (в Python ET.tostring(encoding=...)
  декларацию не добавляет, поэтому её длину вычитаем). }
function DeclPrefixLen(const XML: UnicodeString): Integer;
var
  P: Integer;
begin
  Result := 0;
  if (Length(XML) >= 5) and (Copy(XML, 1, 5) = '<?xml') then
  begin
    P := Pos('?>', XML);
    if P > 0 then
    begin
      Result := P + 1;
      if (Result < Length(XML)) and (XML[Result + 1] = #13) then
        Inc(Result);
      if (Result < Length(XML)) and (XML[Result + 1] = #10) then
        Inc(Result);
    end;
  end;
end;

function TFb2Splitter.UnitSize(const U: TSplitUnit): Integer;
var
  Book: TFictionBook;
  Body: TBody;
  Raw: RawByteString;
  XML: UnicodeString;
begin
  Book := TFictionBook.Create;
  try
    Body := TBody.Create;
    Body.Sections.Add(Skeleton(U.Ancestors, U.Section));
    Book.Bodies.Add(Body);
    XML := FWriter.ToXML(Book);
  finally
    Book.Free;
  end;
  Raw := UTF8Encode(XML);
  Result := Length(Raw) - DeclPrefixLen(XML);
  if Result < 0 then
    Result := 0;
end;

function TFb2Splitter.Skeleton(const Ancestors: TSectionArr;
  Section: TSection): TSection;
var
  I: Integer;
  Node, Shell: TSection;
begin
  Node := TSection(CloneObject(Section));
  for I := High(Ancestors) downto 0 do
  begin
    Shell := TSection(CloneObject(Ancestors[I]));
    FreeAndNil(Shell.Sections);
    Shell.Sections := TFb2ObjectList.Create;
    Shell.Sections.Add(Node);
    Node := Shell;
  end;
  Result := Node;
end;

function TFb2Splitter.BuildPart(Book: TFictionBook; const Group: TSplitGroup;
  Number, Total: Integer): TFictionBook;
var
  Desc: TDescription;
  I: Integer;
begin
  Desc := TDescription(CloneObject(Book.Description));
  UpdateTitleInfo(Desc, Number, Total);
  UpdateDocumentInfo(Desc);

  Result := TFictionBook.Create;
  try
    FreeAndNil(Result.Stylesheets);
    Result.Stylesheets := CloneList(Book.Stylesheets);
    Result.Description := Desc;
    if Book.Bodies.Count > 0 then
      Result.Bodies.Add(PartBody(TBody(Book.Bodies[0]), Group));
    if FKeepExtraBodies then
      for I := 1 to Book.Bodies.Count - 1 do
        Result.Bodies.Add(CloneObject(Book.Bodies[I]));
    FreeAndNil(Result.Binaries);
    Result.Binaries := PartBinaries(Book, Desc, Result.Bodies);
  except
    FreeAndNil(Result);
    raise;
  end;
end;

function TFb2Splitter.PartBody(SourceBody: TBody;
  const Group: TSplitGroup): TBody;
var
  I: Integer;
begin
  Result := TBody.Create;
  if SourceBody.Image <> nil then
    Result.Image := TImage(CloneObject(SourceBody.Image));
  if SourceBody.Title <> nil then
    Result.Title := TTitle(CloneObject(SourceBody.Title));
  FreeAndNil(Result.Epigraphs);
  Result.Epigraphs := CloneList(SourceBody.Epigraphs);
  Result.Name := SourceBody.Name;
  Result.Lang := SourceBody.Lang;
  for I := 0 to High(Group) do
    Result.Sections.Add(Skeleton(Group[I].Ancestors, Group[I].Section));
end;

procedure TFb2Splitter.UpdateTitleInfo(Desc: TDescription;
  Number, Total: Integer);
var
  TI: TTitleInfo;
  Base, Suffix: UnicodeString;
  Seq: TSequence;
begin
  if (Desc = nil) or (Desc.TitleInfo = nil) then
    Exit;
  TI := Desc.TitleInfo;
  if TI.BookTitle <> nil then
    Base := TI.BookTitle.Value
  else
    Base := '';

  if FTitleSuffix <> '' then
  begin
    Suffix := FormatPartName(FTitleSuffix, '', Number, Total);
    FreeAndNil(TI.BookTitle);
    TI.BookTitle := TTextField.Create;
    TI.BookTitle.Value := Base + Suffix;
  end;

  if FAddSequence and (Base <> '') then
  begin
    Seq := TSequence.Create;
    Seq.Name := Base;
    Seq.Number := Number;
    TI.Sequences.Add(Seq);
  end;
end;

procedure TFb2Splitter.UpdateDocumentInfo(Desc: TDescription);
var
  Info: TDocumentInfo;
begin
  if Desc = nil then
    Exit;
  if Desc.DocumentInfo = nil then
    Desc.DocumentInfo := TDocumentInfo.Create;
  Info := Desc.DocumentInfo;
  if FUpdateId then
  begin
    Info.Id := NewUrnUuid;
    Info.Version := 1.0;
    Info.HasVersion := True;
    FreeAndNil(Info.Date);
    Info.Date := TodayField;
  end;
  if Info.ProgramUsed = nil then
  begin
    Info.ProgramUsed := TTextField.Create;
    Info.ProgramUsed.Value := 'pyFB2 Fb2Splitter';
  end;
end;

function TFb2Splitter.PartBinaries(Book: TFictionBook; Desc: TDescription;
  Bodies: TFb2ObjectList): TFb2ObjectList;
var
  Collector: TIdCollector;
  I: Integer;
  Bin: TBinary;
begin
  Result := TFb2ObjectList.Create;
  if not FCopyBinaries then
    Exit;

  Collector := TIdCollector.Create;
  try
    if Desc <> nil then
      MapTitleInfo(Desc.TitleInfo, @Collector.Map);
    for I := 0 to Bodies.Count - 1 do
      MapBody(TBody(Bodies[I]), @Collector.Map);

    for I := 0 to Book.Binaries.Count - 1 do
    begin
      Bin := TBinary(Book.Binaries[I]);
      if Collector.Contains(Bin.Id) then
        Result.Add(CloneObject(Bin));
    end;
  finally
    Collector.Free;
  end;
end;

function TFb2Splitter.SplitBook(const Source: UnicodeString;
  const Stem: UnicodeString): TSplitPartList;
var
  Book: TFictionBook;
  Units: TSplitUnits;
  Groups: TSplitGroups;
  Total, I: Integer;
begin
  Result := TSplitPartList.Create;
  Book := ReadBook(Source);
  try
    Units := CollectUnits(Book);
    if Length(Units) = 0 then
      Exit;
    Groups := GroupUnits(Units);
    Total := Length(Groups);
    for I := 0 to Total - 1 do
      Result.Add(TSplitPart.Create(
        FormatPartName(FFilenameTemplate, Stem, I + 1, Total),
        BuildPart(Book, Groups[I], I + 1, Total)));
  finally
    Book.Free;
  end;
end;

function TFb2Splitter.Split(const Source: UnicodeString;
  const OutDir: UnicodeString; const Stem: UnicodeString): TTextList;
var
  Dir, AStem, Path: UnicodeString;
  PartList: TSplitPartList;
  I: Integer;
begin
  Result := TTextList.Create;
  if Stem <> '' then
    AStem := Stem
  else
    AStem := ChangeFileExt(ExtractFileName(Source), '');
  if OutDir <> '' then
    Dir := OutDir
  else
    Dir := ExtractFileDir(Source);
  if Dir = '' then
    Dir := '.';

  ForceDirectories(Dir);
  PartList := SplitBook(Source, AStem);
  try
    for I := 0 to PartList.Count - 1 do
    begin
      Path := IncludeTrailingPathDelimiter(Dir) + PartList[I].Name;
      FWriter.Write(PartList[I].Book, Path);
      Result.Add(Path);
    end;
  finally
    PartList.Free;
  end;
end;

{ ===================== TFb2Merger ===================== }

{ Обрезать ведущие/замыкающие '|' (аналог str.strip("|")). }
function StripPipes(const S: UnicodeString): UnicodeString;
var
  L, R: Integer;
begin
  L := 1;
  R := Length(S);
  while (L <= R) and (S[L] = '|') do
    Inc(L);
  while (R >= L) and (S[R] = '|') do
    Dec(R);
  Result := Copy(S, L, R - L + 1);
end;

{ Ключ автора для дедупликации: имя|отчество|фамилия|никнейм. }
function AuthorKey(A: TAuthor): UnicodeString;
begin
  Result := StripPipes(A.FirstName + '|' + A.MiddleName + '|' +
    A.LastName + '|' + A.Nickname);
end;

function MergeAuthors(const Infos: array of TTitleInfo): TFb2ObjectList;
var
  Seen: TStringList;
  I, J: Integer;
  A: TAuthor;
  Key: UnicodeString;
begin
  Result := TFb2ObjectList.Create;
  Seen := TStringList.Create;
  Seen.Sorted := True;
  Seen.Duplicates := dupIgnore;
  try
    for I := 0 to High(Infos) do
      for J := 0 to Infos[I].Authors.Count - 1 do
      begin
        A := TAuthor(Infos[I].Authors[J]);
        Key := AuthorKey(A);
        if (Key <> '') and (Seen.IndexOf(Key) < 0) then
        begin
          Seen.Add(Key);
          Result.Add(CloneObject(A));
        end;
      end;
  finally
    Seen.Free;
  end;
end;

function MergeGenres(const Infos: array of TTitleInfo): TFb2ObjectList;
var
  Seen: TStringList;
  I, J: Integer;
  G: TGenre;
begin
  Result := TFb2ObjectList.Create;
  Seen := TStringList.Create;
  Seen.Sorted := True;
  Seen.Duplicates := dupIgnore;
  try
    for I := 0 to High(Infos) do
      for J := 0 to Infos[I].Genres.Count - 1 do
      begin
        G := TGenre(Infos[I].Genres[J]);
        if (G.Value <> '') and (Seen.IndexOf(G.Value) < 0) then
        begin
          Seen.Add(G.Value);
          Result.Add(CloneObject(G));
        end;
      end;
  finally
    Seen.Free;
  end;
end;

function BookTitle(Book: TFictionBook): UnicodeString;
var
  Info: TTitleInfo;
begin
  Info := nil;
  if Book.Description <> nil then
    Info := Book.Description.TitleInfo;
  if (Info <> nil) and (Info.BookTitle <> nil) and
    (Info.BookTitle.Value <> '') then
    Result := Info.BookTitle.Value
  else
    Result := 'Без названия';
end;

{ Обернуть секции книги в секцию с заголовком (принимает владение). }
function WrapSections(const TitleText: UnicodeString;
  Sections: TFb2ObjectList): TSection;
var
  T: TTitle;
  P: TParagraph;
begin
  T := TTitle.Create;
  P := TParagraph.Create;
  P.Content.Add(TStyleNode.Create(TEXT_NODE_NAME, TitleText));
  T.Items.Add(P);

  Result := TSection.Create;
  FreeAndNil(Result.Title);
  Result.Title := T;
  FreeAndNil(Result.Sections);
  Result.Sections := Sections;
end;

constructor TFb2Merger.Create(const Title: UnicodeString;
  CombineMetadata: Boolean; AddSourceTitles: Boolean;
  MergeBinaries: Boolean; UpdateId: Boolean);
begin
  inherited Create;
  FParser := TFb2Parser.Create;
  FWriter := TFb2Writer.Create;
  FTitle := Title;
  FCombineMetadata := CombineMetadata;
  FAddSourceTitles := AddSourceTitles;
  FMergeBinaries := MergeBinaries;
  FUpdateId := UpdateId;
end;

destructor TFb2Merger.Destroy;
begin
  FreeAndNil(FParser);
  FreeAndNil(FWriter);
  inherited Destroy;
end;

function TFb2Merger.ReadBook(const Source: UnicodeString): TFictionBook;
begin
  FParser.LoadFile(Source);
  Result := TFictionBook.Create;
  try
    FreeAndNil(Result.Stylesheets);
    Result.Stylesheets := FParser.ParseStylesheets;
    Result.Description := FParser.Parse;
    FreeAndNil(Result.Bodies);
    Result.Bodies := FParser.ParseBodies;
    FreeAndNil(Result.Binaries);
    Result.Binaries := FParser.ParseBinaries;
  except
    FreeAndNil(Result);
    raise;
  end;
end;

function TFb2Merger.Merge(Sources: TTextList): TFictionBook;
var
  Books: TBookList;
  I: Integer;
  Binaries: TFb2ObjectList;
begin
  Result := nil;
  Books := TBookList.Create;
  try
    for I := 0 to Sources.Count - 1 do
      Books.Add(ReadBook(Sources[I]));
    if Books.Count = 0 then
      raise EFb2ConversionError.Create('Не задано ни одной книги для слияния');

    { Порядок важен: сначала перепривязка <binary> (мутирует книги),
      затем копирование секций и метаданных в итоговую книгу. }
    if FMergeBinaries then
      Binaries := DoMergeBinaries(Books)
    else
      Binaries := TFb2ObjectList.Create;

    Result := TFictionBook.Create;
    try
      FreeAndNil(Result.Binaries);
      Result.Binaries := Binaries;
      Result.Description := MergeDescription(Books);
      Result.Bodies.Add(MergeBodies(Books));
    except
      FreeAndNil(Result);
      raise;
    end;
  finally
    Books.Free;
  end;
end;

function TFb2Merger.MergeToFile(Sources: TTextList;
  const Output: UnicodeString): UnicodeString;
var
  Book: TFictionBook;
begin
  Book := Merge(Sources);
  try
    Result := FWriter.Write(Book, Output);
  finally
    Book.Free;
  end;
end;

function TFb2Merger.Write(Sources: TTextList;
  const Output: UnicodeString): UnicodeString;
begin
  Result := MergeToFile(Sources, Output);
end;

function TFb2Merger.MergeDescription(Books: TBookList): TDescription;
begin
  Result := TDescription.Create;
  try
    Result.TitleInfo := MergeTitleInfo(Books);
    Result.DocumentInfo := NewDocumentInfo(Books);
  except
    FreeAndNil(Result);
    raise;
  end;
end;

function TFb2Merger.MergeTitleInfo(Books: TBookList): TTitleInfo;
var
  Infos: array of TTitleInfo;
  I: Integer;
  First: TTitleInfo;
  BaseTitle: UnicodeString;
  A: TAuthor;
  G: TGenre;
begin
  SetLength(Infos, 0);
  for I := 0 to Books.Count - 1 do
    if (Books[I].Description <> nil) and
      (Books[I].Description.TitleInfo <> nil) then
    begin
      SetLength(Infos, Length(Infos) + 1);
      Infos[High(Infos)] := Books[I].Description.TitleInfo;
    end;

  Result := TTitleInfo.Create;
  try
    if Length(Infos) = 0 then
    begin
      Result.BookTitle := TTextField.Create;
      if FTitle <> '' then
        Result.BookTitle.Value := FTitle
      else
        Result.BookTitle.Value := 'Untitled';
      Result.Lang := 'ru';
      Exit;
    end;

    First := Infos[0];
    if First.BookTitle <> nil then
      BaseTitle := First.BookTitle.Value
    else
      BaseTitle := 'Untitled';
    Result.BookTitle := TTextField.Create;
    if FTitle <> '' then
      Result.BookTitle.Value := FTitle
    else
      Result.BookTitle.Value := BaseTitle;
    if First.Lang <> '' then
      Result.Lang := First.Lang
    else
      Result.Lang := 'ru';
    if First.Coverpage <> nil then
      Result.Coverpage := TCoverPage(CloneObject(First.Coverpage));
    if First.Annotation <> nil then
      Result.Annotation := TAnnotation(CloneObject(First.Annotation));

    if FCombineMetadata then
    begin
      FreeAndNil(Result.Authors);
      Result.Authors := MergeAuthors(Infos);
      FreeAndNil(Result.Genres);
      Result.Genres := MergeGenres(Infos);
    end
    else
    begin
      FreeAndNil(Result.Authors);
      Result.Authors := CloneList(First.Authors);
      FreeAndNil(Result.Genres);
      Result.Genres := CloneList(First.Genres);
    end;

    { Схема требует минимум одного автора и один жанр. }
    if Result.Authors.Count = 0 then
    begin
      A := TAuthor.Create;
      A.Nickname := 'Неизвестный автор';
      Result.Authors.Add(A);
    end;
    if Result.Genres.Count = 0 then
    begin
      G := TGenre.Create;
      G.Value := 'prose';
      Result.Genres.Add(G);
    end;
  except
    FreeAndNil(Result);
    raise;
  end;
end;

function TFb2Merger.MergeBodies(Books: TBookList): TBody;
var
  I: Integer;
  Sections: TFb2ObjectList;
begin
  Result := TBody.Create;
  for I := 0 to Books.Count - 1 do
  begin
    if Books[I].Bodies.Count = 0 then
      Continue;
    Sections := CloneList(TBody(Books[I].Bodies[0]).Sections);
    if Sections.Count = 0 then
    begin
      Sections.Free;
      Continue;
    end;
    if FAddSourceTitles then
      Result.Sections.Add(WrapSections(BookTitle(Books[I]), Sections))
    else
      MoveList(Result.Sections, Sections);
  end;
end;

function TFb2Merger.NewDocumentInfo(Books: TBookList): TDocumentInfo;
var
  SourceInfo: TDocumentInfo;
  I: Integer;
  A: TAuthor;
begin
  SourceInfo := nil;
  for I := 0 to Books.Count - 1 do
    if (Books[I].Description <> nil) and
      (Books[I].Description.DocumentInfo <> nil) then
    begin
      SourceInfo := Books[I].Description.DocumentInfo;
      Break;
    end;

  Result := TDocumentInfo.Create;
  try
    if FUpdateId or (SourceInfo = nil) then
    begin
      Result.Id := NewUrnUuid;
      Result.Version := 1.0;
      Result.HasVersion := True;
      Result.Date := TodayField;
    end
    else
    begin
      if SourceInfo.Id <> '' then
        Result.Id := SourceInfo.Id
      else
        Result.Id := NewUrnUuid;
      Result.Version := SourceInfo.Version;
      Result.HasVersion := SourceInfo.HasVersion;
      if SourceInfo.Date <> nil then
        Result.Date := TDateField(CloneObject(SourceInfo.Date));
    end;

    Result.ProgramUsed := TTextField.Create;
    Result.ProgramUsed.Value := 'pyFB2 Fb2Merger';

    if (SourceInfo <> nil) and (SourceInfo.Authors.Count > 0) then
    begin
      FreeAndNil(Result.Authors);
      Result.Authors := CloneList(SourceInfo.Authors);
    end
    else
    begin
      A := TAuthor.Create;
      A.Nickname := 'pyFB2';
      Result.Authors.Add(A);
    end;
  except
    FreeAndNil(Result);
    raise;
  end;
end;

function TFb2Merger.DoMergeBinaries(Books: TBookList): TFb2ObjectList;
var
  UsedIds: TStringList;
  I, J: Integer;
  Book: TFictionBook;
  Bin, Clone: TBinary;
  Remap: TRemapper;
  Original, NewId: UnicodeString;
  Counter: Integer;
  HasMapping: Boolean;
begin
  Result := TFb2ObjectList.Create;
  UsedIds := TStringList.Create;
  UsedIds.Sorted := True;
  UsedIds.Duplicates := dupIgnore;
  try
    for I := 0 to Books.Count - 1 do
    begin
      Book := Books[I];
      Remap := TRemapper.Create;
      try
        HasMapping := False;
        for J := 0 to Book.Binaries.Count - 1 do
        begin
          Bin := TBinary(Book.Binaries[J]);
          Original := Bin.Id;
          if Original <> '' then
            NewId := Original
          else
            NewId := 'binary' + IntToStr(Result.Count + 1);
          Counter := 2;
          while UsedIds.IndexOf(NewId) >= 0 do
          begin
            NewId := Original + '_' + IntToStr(Counter);
            Inc(Counter);
          end;
          UsedIds.Add(NewId);
          if (Original <> '') and (NewId <> Original) then
          begin
            Remap.Add(Original, NewId);
            HasMapping := True;
          end;
          Clone := TBinary(CloneObject(Bin));
          Clone.Id := NewId;
          Result.Add(Clone);
        end;

        if HasMapping then
          MapBookImages(Book, @Remap.Map);
      finally
        Remap.Free;
      end;
    end;
  finally
    UsedIds.Free;
  end;
end;

end.
