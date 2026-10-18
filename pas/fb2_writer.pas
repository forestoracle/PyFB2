unit fb2_writer;
{ Сериализация структур FB2 (FictionBook 2.0) в XML — перевод fb2_writer.py.

  Класс TFb2Writer принимает TFictionBook (см. fb2_structures) и собирает
  XML-документ FictionBook 2.0 через DOM из fcl-xml (units DOM, XMLWrite).

  Пример:
      var W: TFb2Writer; Book: TFictionBook;
      begin
        W := TFb2Writer.Create;
        try
          W.Write(Book, 'out.fb2');
        finally
          W.Free;
        end;
      end;

  Особенности перевода с Python:
      * элементы создаются через CreateElementNS — они попадают в
        пространство имён FB2, а xlink:href — в пространство имён xlink
        (объявление xmlns:xlink ставится один раз на корне);
      * mixed-контент (текст + разметка) собирается методом AppendStyle:
        текстовые узлы добавляются как TDOMText в порядке следования, что
        сохраняет структуру «текст — элемент — текст»;
      * как и в Python-версии, если в секции есть И контент, И подсекции,
        контент оборачивается в анонимную вложенную <section> (требование
        XSD: choice(section+ | контент)).

  ВАЖНО: набор сериализуемых полей совпадает с Python-версией
  (fb2_writer.py). }

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Classes, SysUtils, DOM, XMLWrite,
  fb2_structures;

const
  { Служебное пространство имён для объявления xmlns:xlink на корне. }
  NS_XMLNS = 'http://www.w3.org/2000/xmlns/';

type
  { Сериализатор структур FB2 в XML. }
  TFb2Writer = class
  private
    FDoc: TXMLDocument;
    FRoot: TDOMElement;

    { --- Помощники ---------------------------------------------------- }
    function NewElement(const AName: UnicodeString): TDOMElement;
    function AddElement(AParent: TDOMElement;
      const AName: UnicodeString): TDOMElement;
    procedure AddText(AParent: TDOMElement; const AText: UnicodeString);
    procedure AddAttr(AElement: TDOMElement; const AName,
      AValue: UnicodeString);
    procedure AddXlink(AElement: TDOMElement; const AValue: UnicodeString);
    procedure AddXmlLang(AElement: TDOMElement; const AValue: UnicodeString);
    function DocumentToBytes(Doc: TXMLDocument): TBytes;
    function DocumentToString(Doc: TXMLDocument): UnicodeString;

    { --- Метаданные --------------------------------------------------- }
    function BuildStylesheet(Sheet: TStylesheet): TDOMElement;
    function BuildDescription(Desc: TDescription): TDOMElement;
    function BuildTitleInfo(TI: TTitleInfo;
      const AName: UnicodeString): TDOMElement;
    function BuildAuthor(Author: TAuthor): TDOMElement;
    function BuildDocumentInfo(DI: TDocumentInfo): TDOMElement;
    function BuildGenre(Genre: TGenre): TDOMElement;
    function BuildSequence(Seq: TSequence): TDOMElement;
    function BuildCoverPage(Page: TCoverPage): TDOMElement;
    function BuildAnnotation(A: TAnnotation): TDOMElement;

    { --- Содержимое --------------------------------------------------- }
    function BuildBody(Body: TBody): TDOMElement;
    function BuildSection(Section: TSection): TDOMElement;
    function BuildBlock(Block: TFb2Object): TDOMElement;
    function BuildParagraph(P: TParagraph): TDOMElement;
    function BuildSubtitle(S: TSubtitle): TDOMElement;
    function BuildTitle(T: TTitle): TDOMElement;
    function BuildImage(I: TImage): TDOMElement;
    function BuildCite(C: TCite): TDOMElement;
    function BuildTable(T: TTable): TDOMElement;
    function BuildPoem(P: TPoem): TDOMElement;
    function BuildStanza(S: TStanza): TDOMElement;
    function BuildEpigraph(E: TEpigraph): TDOMElement;
    function BuildTextAuthor(P: TParagraph): TDOMElement;
    function BuildBinary(B: TBinary): TDOMElement;

    { --- Разметка ----------------------------------------------------- }
    procedure AppendStyle(AParent: TDOMElement; Nodes: TFb2ObjectList);
    function BuildStyleNode(Node: TStyleNode): TDOMElement;
  public
    constructor Create;
    destructor Destroy; override;

    { Собрать XML-документ из структуры (владелец — вызывающий). }
    function BuildDocument(Book: TFictionBook): TXMLDocument;
    { Сериализовать книгу в строку XML (с декларацией). }
    function ToXML(Book: TFictionBook): UnicodeString;
    { Записать книгу в файл (UTF-8); возвращает путь. }
    function Write(Book: TFictionBook;
      const AFileName: UnicodeString): UnicodeString;
  end;

implementation

{ ===================== Помощники ===================== }

{ Версия документа в виде "1.0" (аналог str(version) в Python). }
function VersionToText(V: Double): UnicodeString;
begin
  Result := UIntToStr(Trunc(V)) + '.' + UIntToStr(Round(Frac(V) * 10));
end;

function TFb2Writer.NewElement(const AName: UnicodeString): TDOMElement;
begin
  Result := FDoc.CreateElementNS(NS_FB, AName);
end;

function TFb2Writer.AddElement(AParent: TDOMElement;
  const AName: UnicodeString): TDOMElement;
begin
  Result := NewElement(AName);
  AParent.AppendChild(Result);
end;

procedure TFb2Writer.AddText(AParent: TDOMElement; const AText: UnicodeString);
begin
  if AText = '' then
    Exit;
  AParent.AppendChild(FDoc.CreateTextNode(AText));
end;

procedure TFb2Writer.AddAttr(AElement: TDOMElement; const AName,
  AValue: UnicodeString);
begin
  if AValue = '' then
    Exit;
  AElement.SetAttribute(AName, AValue);
end;

procedure TFb2Writer.AddXlink(AElement: TDOMElement; const AValue: UnicodeString);
begin
  if AValue = '' then
    Exit;
  AElement.SetAttributeNS(NS_XLINK, 'xlink:href', AValue);
end;

procedure TFb2Writer.AddXmlLang(AElement: TDOMElement;
  const AValue: UnicodeString);
begin
  if AValue = '' then
    Exit;
  AElement.SetAttributeNS(NS_XML, 'xml:lang', AValue);
end;

{ ===================== Метаданные ===================== }

function TFb2Writer.BuildStylesheet(Sheet: TStylesheet): TDOMElement;
begin
  Result := NewElement('stylesheet');
  AddAttr(Result, 'type', Sheet.SheetType);
  AddText(Result, Sheet.Value);
end;

function TFb2Writer.BuildDescription(Desc: TDescription): TDOMElement;
begin
  Result := NewElement('description');
  if Desc.TitleInfo <> nil then
    Result.AppendChild(BuildTitleInfo(Desc.TitleInfo, 'title-info'));
  if Desc.DocumentInfo <> nil then
    Result.AppendChild(BuildDocumentInfo(Desc.DocumentInfo));
end;

function TFb2Writer.BuildTitleInfo(TI: TTitleInfo;
  const AName: UnicodeString): TDOMElement;
var
  I: Integer;
  Elem: TDOMElement;
begin
  Result := NewElement(AName);

  for I := 0 to TI.Genres.Count - 1 do
    Result.AppendChild(BuildGenre(TGenre(TI.Genres[I])));

  for I := 0 to TI.Authors.Count - 1 do
    Result.AppendChild(BuildAuthor(TAuthor(TI.Authors[I])));

  Elem := AddElement(Result, 'book-title');
  if TI.BookTitle <> nil then
    AddText(Elem, TI.BookTitle.Value);

  if TI.Annotation <> nil then
    Result.AppendChild(BuildAnnotation(TI.Annotation));

  if TI.Date <> nil then
  begin
    Elem := AddElement(Result, 'date');
    AddText(Elem, TI.Date.Value);
    AddAttr(Elem, 'value', TI.Date.DateValue);
  end;

  if TI.Coverpage <> nil then
    Result.AppendChild(BuildCoverPage(TI.Coverpage));

  Elem := AddElement(Result, 'lang');
  AddText(Elem, TI.Lang);

  for I := 0 to TI.Sequences.Count - 1 do
    Result.AppendChild(BuildSequence(TSequence(TI.Sequences[I])));
end;

function TFb2Writer.BuildAuthor(Author: TAuthor): TDOMElement;
var
  Elem: TDOMElement;
begin
  Result := NewElement('author');

  if Author.FirstName <> '' then
  begin
    Elem := AddElement(Result, 'first-name');
    AddText(Elem, Author.FirstName);
  end;
  if Author.MiddleName <> '' then
  begin
    Elem := AddElement(Result, 'middle-name');
    AddText(Elem, Author.MiddleName);
  end;
  if Author.LastName <> '' then
  begin
    Elem := AddElement(Result, 'last-name');
    AddText(Elem, Author.LastName);
  end;
  if Author.Nickname <> '' then
  begin
    Elem := AddElement(Result, 'nickname');
    AddText(Elem, Author.Nickname);
  end;
  AddAttr(Result, 'id', Author.Id);
end;

function TFb2Writer.BuildDocumentInfo(DI: TDocumentInfo): TDOMElement;
var
  I: Integer;
  Elem: TDOMElement;
begin
  Result := NewElement('document-info');

  for I := 0 to DI.Authors.Count - 1 do
    Result.AppendChild(BuildAuthor(TAuthor(DI.Authors[I])));

  if DI.ProgramUsed <> nil then
  begin
    Elem := AddElement(Result, 'program-used');
    AddText(Elem, DI.ProgramUsed.Value);
  end;

  if DI.Date <> nil then
  begin
    Elem := AddElement(Result, 'date');
    AddText(Elem, DI.Date.Value);
    AddAttr(Elem, 'value', DI.Date.DateValue);
  end;

  if DI.Id <> '' then
  begin
    Elem := AddElement(Result, 'id');
    AddText(Elem, DI.Id);
  end;

  Elem := AddElement(Result, 'version');
  if DI.HasVersion then
    AddText(Elem, VersionToText(DI.Version))
  else
    AddText(Elem, '1.0');
end;

function TFb2Writer.BuildGenre(Genre: TGenre): TDOMElement;
begin
  Result := NewElement('genre');
  AddText(Result, Genre.Value);
  if Genre.Match <> 100 then
    AddAttr(Result, 'match', UIntToStr(Genre.Match));
end;

function TFb2Writer.BuildSequence(Seq: TSequence): TDOMElement;
var
  I: Integer;
begin
  Result := NewElement('sequence');
  AddAttr(Result, 'name', Seq.Name);
  if Seq.Number <> NO_VALUE then
    AddAttr(Result, 'number', UIntToStr(Seq.Number));
  AddXmlLang(Result, Seq.Lang);
  for I := 0 to Seq.Sequences.Count - 1 do
    Result.AppendChild(BuildSequence(TSequence(Seq.Sequences[I])));
end;

function TFb2Writer.BuildCoverPage(Page: TCoverPage): TDOMElement;
var
  I: Integer;
  Img: TInlineImage;
  Elem: TDOMElement;
begin
  Result := NewElement('coverpage');
  for I := 0 to Page.Images.Count - 1 do
  begin
    Img := TInlineImage(Page.Images[I]);
    Elem := AddElement(Result, 'image');
    AddXlink(Elem, Img.Href);
    AddAttr(Elem, 'alt', Img.Alt);
  end;
end;

function TFb2Writer.BuildAnnotation(A: TAnnotation): TDOMElement;
var
  I: Integer;
  Block: TDOMElement;
begin
  Result := NewElement('annotation');
  AddAttr(Result, 'id', A.Id);
  for I := 0 to A.Items.Count - 1 do
  begin
    Block := BuildBlock(A.Items[I]);
    if Block <> nil then
      Result.AppendChild(Block);
  end;
end;

{ ===================== Содержимое книги ===================== }

function TFb2Writer.BuildBody(Body: TBody): TDOMElement;
var
  I: Integer;
begin
  Result := NewElement('body');
  AddAttr(Result, 'name', Body.Name);

  { XSD bodyType: image?, title?, epigraph*, section+ — картинка идёт ПЕРВОЙ. }
  if Body.Image <> nil then
    Result.AppendChild(BuildImage(Body.Image));

  if Body.Title <> nil then
    Result.AppendChild(BuildTitle(Body.Title));

  for I := 0 to Body.Epigraphs.Count - 1 do
    Result.AppendChild(BuildEpigraph(TEpigraph(Body.Epigraphs[I])));

  for I := 0 to Body.Sections.Count - 1 do
    Result.AppendChild(BuildSection(TSection(Body.Sections[I])));
end;

function TFb2Writer.BuildSection(Section: TSection): TDOMElement;
var
  I: Integer;
  Block: TDOMElement;
  Wrapper: TDOMElement;
  HasContent, HasSections: Boolean;
begin
  Result := NewElement('section');
  AddAttr(Result, 'id', Section.Id);

  if Section.Title <> nil then
    Result.AppendChild(BuildTitle(Section.Title));

  for I := 0 to Section.Epigraphs.Count - 1 do
    Result.AppendChild(BuildEpigraph(TEpigraph(Section.Epigraphs[I])));

  { XSD sectionType: title?, epigraph*, image?, annotation?, далее контент. }
  if Section.Image <> nil then
    Result.AppendChild(BuildImage(Section.Image));

  if Section.Annotation <> nil then
    Result.AppendChild(BuildAnnotation(Section.Annotation));

  HasContent := Section.Content.Count > 0;
  HasSections := Section.Sections.Count > 0;

  { XSD: секция содержит ЛИБО подсекции, ЛИБО контент. Если есть и то и
    другое — контент оборачивается в анонимную вложенную секцию. }
  if HasContent and HasSections then
  begin
    Wrapper := AddElement(Result, 'section');
    for I := 0 to Section.Content.Count - 1 do
    begin
      Block := BuildBlock(Section.Content[I]);
      if Block <> nil then
        Wrapper.AppendChild(Block);
    end;
    for I := 0 to Section.Sections.Count - 1 do
      Result.AppendChild(BuildSection(TSection(Section.Sections[I])));
  end
  else
  begin
    for I := 0 to Section.Content.Count - 1 do
    begin
      Block := BuildBlock(Section.Content[I]);
      if Block <> nil then
        Result.AppendChild(Block);
    end;
    for I := 0 to Section.Sections.Count - 1 do
      Result.AppendChild(BuildSection(TSection(Section.Sections[I])));
  end;
end;

function TFb2Writer.BuildBlock(Block: TFb2Object): TDOMElement;
begin
  Result := nil;
  if Block is TParagraph then
    Result := BuildParagraph(TParagraph(Block))
  else if Block is TSubtitle then
    Result := BuildSubtitle(TSubtitle(Block))
  else if Block is TEmptyLine then
    Result := NewElement('empty-line')
  else if Block is TImage then
    Result := BuildImage(TImage(Block))
  else if Block is TCite then
    Result := BuildCite(TCite(Block))
  else if Block is TTable then
    Result := BuildTable(TTable(Block))
  else if Block is TPoem then
    Result := BuildPoem(TPoem(Block))
  else if Block is TEpigraph then
    Result := BuildEpigraph(TEpigraph(Block));
end;

function TFb2Writer.BuildParagraph(P: TParagraph): TDOMElement;
begin
  Result := NewElement('p');
  AddAttr(Result, 'id', P.Id);
  AppendStyle(Result, P.Content);
end;

function TFb2Writer.BuildSubtitle(S: TSubtitle): TDOMElement;
begin
  Result := NewElement('subtitle');
  AppendStyle(Result, S.Content);
end;

function TFb2Writer.BuildTitle(T: TTitle): TDOMElement;
var
  I: Integer;
  Elem: TDOMElement;
  Item: TFb2Object;
begin
  Result := NewElement('title');
  for I := 0 to T.Items.Count - 1 do
  begin
    Item := T.Items[I];
    if Item is TParagraph then
    begin
      Elem := AddElement(Result, 'p');
      AppendStyle(Elem, TParagraph(Item).Content);
    end
    else if Item is TEmptyLine then
      AddElement(Result, 'empty-line');
  end;
end;

function TFb2Writer.BuildImage(I: TImage): TDOMElement;
begin
  Result := NewElement('image');
  AddXlink(Result, I.Href);
  AddAttr(Result, 'alt', I.Alt);
  AddAttr(Result, 'title', I.Title);
end;

function TFb2Writer.BuildCite(C: TCite): TDOMElement;
var
  I: Integer;
  Block: TDOMElement;
begin
  Result := NewElement('cite');
  for I := 0 to C.Items.Count - 1 do
  begin
    Block := BuildBlock(C.Items[I]);
    if Block <> nil then
      Result.AppendChild(Block);
  end;
end;

function TFb2Writer.BuildTable(T: TTable): TDOMElement;
var
  R, C: Integer;
  Row: TTableRow;
  Cell: TTableCell;
  Tr, Td: TDOMElement;
begin
  Result := NewElement('table');
  AddAttr(Result, 'style', T.Style);
  AddAttr(Result, 'id', T.Id);

  for R := 0 to T.Rows.Count - 1 do
  begin
    Row := TTableRow(T.Rows[R]);
    Tr := AddElement(Result, 'tr');
    for C := 0 to Row.Cells.Count - 1 do
    begin
      Cell := TTableCell(Row.Cells[C]);
      if Cell.IsHeader then
        Td := AddElement(Tr, 'th')
      else
        Td := AddElement(Tr, 'td');
      if Cell.Colspan <> NO_VALUE then
        AddAttr(Td, 'colspan', UIntToStr(Cell.Colspan));
      if Cell.Rowspan <> NO_VALUE then
        AddAttr(Td, 'rowspan', UIntToStr(Cell.Rowspan));
      AppendStyle(Td, Cell.Children);
    end;
  end;
end;

function TFb2Writer.BuildPoem(P: TPoem): TDOMElement;
var
  I: Integer;
  Item: TFb2Object;
  Elem: TDOMElement;
begin
  Result := NewElement('poem');
  AddAttr(Result, 'id', P.Id);
  AddXmlLang(Result, P.Lang);

  if P.Title <> nil then
    Result.AppendChild(BuildTitle(P.Title));

  for I := 0 to P.Epigraphs.Count - 1 do
    Result.AppendChild(BuildEpigraph(TEpigraph(P.Epigraphs[I])));

  for I := 0 to P.Items.Count - 1 do
  begin
    Item := P.Items[I];
    if Item is TSubtitle then
      Result.AppendChild(BuildSubtitle(TSubtitle(Item)))
    else if Item is TStanza then
      Result.AppendChild(BuildStanza(TStanza(Item)));
  end;

  for I := 0 to P.TextAuthor.Count - 1 do
    Result.AppendChild(BuildTextAuthor(TParagraph(P.TextAuthor[I])));

  if P.Date <> nil then
  begin
    Elem := AddElement(Result, 'date');
    AddText(Elem, P.Date.Value);
    AddAttr(Elem, 'value', P.Date.DateValue);
  end;
end;

function TFb2Writer.BuildStanza(S: TStanza): TDOMElement;
var
  I: Integer;
  V: TDOMElement;
begin
  Result := NewElement('stanza');
  AddXmlLang(Result, S.Lang);

  if S.Title <> nil then
    Result.AppendChild(BuildTitle(S.Title));
  if S.Subtitle <> nil then
    Result.AppendChild(BuildSubtitle(S.Subtitle));

  for I := 0 to S.Verses.Count - 1 do
  begin
    V := AddElement(Result, 'v');
    AppendStyle(V, TParagraph(S.Verses[I]).Content);
  end;
end;

function TFb2Writer.BuildEpigraph(E: TEpigraph): TDOMElement;
var
  I: Integer;
  Block: TDOMElement;
begin
  Result := NewElement('epigraph');
  AddAttr(Result, 'id', E.Id);
  for I := 0 to E.Items.Count - 1 do
  begin
    Block := BuildBlock(E.Items[I]);
    if Block <> nil then
      Result.AppendChild(Block);
  end;
  for I := 0 to E.TextAuthor.Count - 1 do
    Result.AppendChild(BuildTextAuthor(TParagraph(E.TextAuthor[I])));
end;

function TFb2Writer.BuildTextAuthor(P: TParagraph): TDOMElement;
begin
  Result := NewElement('text-author');
  AppendStyle(Result, P.Content);
end;

function TFb2Writer.BuildBinary(B: TBinary): TDOMElement;
begin
  Result := NewElement('binary');
  AddAttr(Result, 'content-type', B.ContentType);
  AddAttr(Result, 'id', B.Id);
  AddText(Result, B.Data);
end;

{ ===================== Разметка (mixed-контент) ===================== }

procedure TFb2Writer.AppendStyle(AParent: TDOMElement; Nodes: TFb2ObjectList);
var
  I: Integer;
  Node: TStyleNode;
  Child: TDOMElement;
begin
  if Nodes = nil then
    Exit;
  for I := 0 to Nodes.Count - 1 do
  begin
    Node := TStyleNode(Nodes[I]);
    if Node.Tag = TEXT_NODE_NAME then
    begin
      AddText(AParent, Node.Text);
      Continue;
    end;
    Child := BuildStyleNode(Node);
    if Child <> nil then
      AParent.AppendChild(Child);
  end;
end;

function TFb2Writer.BuildStyleNode(Node: TStyleNode): TDOMElement;
begin
  Result := nil;

  if Node.Tag = 'image' then
  begin
    Result := NewElement('image');
    AddXlink(Result, Node.ImageHref);
    AddAttr(Result, 'alt', Node.ImageAlt);
    Exit;
  end;

  if Node.Tag = 'a' then
  begin
    Result := NewElement('a');
    AddXlink(Result, Node.Href);
    AppendStyle(Result, Node.Children);
    Exit;
  end;

  if (Node.Tag = 'strong') or (Node.Tag = 'emphasis') or (Node.Tag = 'style') or
     (Node.Tag = 'strikethrough') or (Node.Tag = 'sub') or
     (Node.Tag = 'sup') or (Node.Tag = 'code') then
  begin
    Result := NewElement(Node.Tag);
    if Node.Tag = 'style' then
      AddAttr(Result, 'name', Node.StyleName);
    AppendStyle(Result, Node.Children);
  end;
end;

{ ===================== Оформление inline-разметки ===================== }

const
  { Теги с mixed/inline-контентом: их содержимое НЕ разбивается
    переводами строк. Иначе закрывающий тег </a> (и вложенный <sup>)
    «повисает» на отдельной строке, а внутрь абзаца попадает лишний пробел. }
  INLINE_TAG_NAMES: array[0..12] of UnicodeString = (
    'a', 'code', 'emphasis', 'image', 'p', 'strikethrough',
    'strong', 'style', 'sub', 'sup', 'subtitle', 'text-author', 'v');

function IsInlineTag(const AName: UnicodeString): Boolean;
var
  I: Integer;
begin
  for I := Low(INLINE_TAG_NAMES) to High(INLINE_TAG_NAMES) do
    if AName = INLINE_TAG_NAMES[I] then
      Exit(True);
  Result := False;
end;

function IsWhitespaceChar(const C: WideChar): Boolean;
begin
  Result := (C = ' ') or (C = #9) or (C = #10) or (C = #13);
end;

{ Есть ли в S[AFrom..ATo] символ перевода строки. }
function RangeHasLineBreak(const S: UnicodeString; AFrom, ATo: Integer): Boolean;
var
  I: Integer;
begin
  for I := AFrom to ATo do
    if (S[I] = #10) or (S[I] = #13) then
      Exit(True);
  Result := False;
end;

{ Убрать переводы строк, которые fcl-xml вставляет внутрь inline-элементов
  (<a>, <sup>, <strong> …). Иначе закрывающий тег </a> «повисает» на
  отдельной строке (как и вложенный <sup>). }
function StripInlineWhitespace(const S: UnicodeString): UnicodeString;
var
  I, J, L, RunStart, RunEnd: Integer;
  Name: UnicodeString;
  Closing: Boolean;
begin
  Result := '';
  L := Length(S);
  I := 1;
  while I <= L do
  begin
    if S[I] <> '<' then
    begin
      Result := Result + S[I];
      Inc(I);
      Continue;
    end;

    Closing := (I < L) and (S[I + 1] = '/');

    { Имя тега. }
    if Closing then
      J := I + 2
    else
      J := I + 1;
    Name := '';
    while (J <= L) and (S[J] <> '>') and (S[J] <> ' ') and (S[J] <> '/') do
    begin
      Name := Name + S[J];
      Inc(J);
    end;

    { Конец тега (пропуская значения атрибутов в кавычках). }
    J := I + 1;
    while J <= L do
    begin
      if S[J] = '"' then
      begin
        Inc(J);
        while (J <= L) and (S[J] <> '"') do
          Inc(J);
      end
      else if S[J] = '>' then
        Break;
      Inc(J);
    end;
    if J > L then
    begin
      Result := Result + Copy(S, I, L - I + 1);
      Break;
    end;

    if Closing then
    begin
      if IsInlineTag(Name) then
      begin
        RunEnd := Length(Result);
        RunStart := RunEnd;
        while (RunStart >= 1) and IsWhitespaceChar(Result[RunStart]) do
          Dec(RunStart);
        if (RunStart < RunEnd) and
           RangeHasLineBreak(Result, RunStart + 1, RunEnd) then
          Delete(Result, RunStart + 1, RunEnd - RunStart);
      end;
      Result := Result + Copy(S, I, J - I + 1);
      I := J + 1;
    end
    else
    begin
      Result := Result + Copy(S, I, J - I + 1);
      I := J + 1;
      if IsInlineTag(Name) then
      begin
        RunStart := I;
        while (I <= L) and IsWhitespaceChar(S[I]) do
          Inc(I);
        if not ((I > RunStart) and RangeHasLineBreak(S, RunStart, I - 1)) then
          I := RunStart;
      end;
    end;
  end;
end;

{ ===================== Сборка и запись документа ===================== }

function TFb2Writer.DocumentToBytes(Doc: TXMLDocument): TBytes;
var
  Mem: TMemoryStream;
  Raw: RawByteString;
  Text: UnicodeString;
begin
  Result := nil;
  Mem := TMemoryStream.Create;
  try
    WriteXML(Doc, Mem);
    SetLength(Raw, Mem.Size);
    if Mem.Size > 0 then
      Move(Mem.Memory^, Raw[1], Mem.Size);
  finally
    Mem.Free;
  end;

  { Убираем переводы строк внутри inline-элементов (fcl-xml их добавляет). }
  Text := StripInlineWhitespace(UTF8Decode(Raw));
  Raw := UTF8Encode(Text);
  SetLength(Result, Length(Raw));
  if Length(Raw) > 0 then
    Move(Raw[1], Result[0], Length(Raw));
end;

function TFb2Writer.DocumentToString(Doc: TXMLDocument): UnicodeString;
var
  Bytes: TBytes;
  Raw: RawByteString;
begin
  Bytes := DocumentToBytes(Doc);
  SetLength(Raw, Length(Bytes));
  if Length(Bytes) > 0 then
    Move(Bytes[0], Raw[1], Length(Bytes));
  Result := UTF8Decode(Raw);
end;

function TFb2Writer.BuildDocument(Book: TFictionBook): TXMLDocument;
var
  I: Integer;
begin
  FDoc := TXMLDocument.Create;
  try
    FRoot := FDoc.CreateElementNS(NS_FB, 'FictionBook');
    FRoot.SetAttributeNS(NS_XMLNS, 'xmlns:xlink', NS_XLINK);
    FDoc.AppendChild(FRoot);

    if Book <> nil then
    begin
      for I := 0 to Book.Stylesheets.Count - 1 do
        FRoot.AppendChild(BuildStylesheet(TStylesheet(Book.Stylesheets[I])));

      if Book.Description <> nil then
        FRoot.AppendChild(BuildDescription(Book.Description));

      for I := 0 to Book.Bodies.Count - 1 do
        FRoot.AppendChild(BuildBody(TBody(Book.Bodies[I])));

      for I := 0 to Book.Binaries.Count - 1 do
        FRoot.AppendChild(BuildBinary(TBinary(Book.Binaries[I])));
    end;

    Result := FDoc;
  except
    FDoc.Free;
    FDoc := nil;
    FRoot := nil;
    raise;
  end;
end;

function TFb2Writer.ToXML(Book: TFictionBook): UnicodeString;
var
  Doc: TXMLDocument;
begin
  Doc := BuildDocument(Book);
  try
    Result := DocumentToString(Doc);
  finally
    Doc.Free;
  end;
end;

function TFb2Writer.Write(Book: TFictionBook;
  const AFileName: UnicodeString): UnicodeString;
var
  Doc: TXMLDocument;
  Bytes: TBytes;
  Stream: TFileStream;
begin
  Doc := BuildDocument(Book);
  try
    Bytes := DocumentToBytes(Doc);
  finally
    Doc.Free;
  end;

  Stream := TFileStream.Create(AFileName, fmCreate);
  try
    if Length(Bytes) > 0 then
      Stream.WriteBuffer(Bytes[0], Length(Bytes));
  finally
    Stream.Free;
  end;
  Result := AFileName;
end;

constructor TFb2Writer.Create;
begin
  inherited Create;
  FDoc := nil;
  FRoot := nil;
end;

destructor TFb2Writer.Destroy;
begin
  inherited Destroy;
end;

end.
