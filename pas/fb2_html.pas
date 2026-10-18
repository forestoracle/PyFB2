unit fb2_html;
{ Экспорт FB2 в HTML с оглавлением и изображениями — перевод fb2_to_html.py.

  Модуль предоставляет класс TFb2ToHtmlConverter, который берёт структуры из
  fb2_parser.pas (см. TFb2Parser) и превращает книгу в HTML-документ:

      * метаданные (<description>)        -> заголовок, автор, жанры, аннотация;
      * вложенные <section>               -> <h1>…<h6> с якорями + <section>;
      * автоматическое оглавление (TOC)   -> вложенный список ссылок на главы;
      * <p>, <strong>, <emphasis>, <a>    -> абзацы и inline-разметка;
      * <epigraph>, <cite>                -> <blockquote>;
      * <poem>/<stanza>/<v>               -> блоки со строфами;
      * <table>                           -> HTML-таблица;
      * <binary>                          -> файлы изображений (или data-URI);
      * сноски (<a type="note">)          -> двусторонние ссылки: из текста в
        сноску (<a class="note-ref">) и обратно
        (<a class="footnote-back">↩</a>), секции-сноски получают id из FB2.

  Особенности перевода с Python:
      * html.escape(s, quote=...)  -> HtmlEscape(S, Quote);
      * base64.b64encode           -> Base64EncodeBytes;
      * dict id->файл              -> TStringList (Values);
      * set / dict счётчиков       -> TStringList (IndexOf / Values);
      * кортеж (level, anchor, …)  -> класс TTocEntry;
      * _TocNode                   -> TTocNode (+ TTocNodeList);
      * запись файла в UTF-8       -> WriteUtf8File (без BOM).

  Пример:
      var C: TFb2ToHtmlConverter;
      begin
        C := TFb2ToHtmlConverter.Create(nil, 'images', 1, 6, True, 'Оглавление');
        try
          C.Write('book.fb2', 'book.html');
        finally
          C.Free;
        end;
      end; }

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Classes, SysUtils, fgl, DOM,
  fb2_structures, fb2_parser;

const
  { Имена тел FB2, в которых лежат примечания/сноски. }
  NOTE_BODY_NAMES: array[0..4] of UnicodeString =
    ('notes', 'footnotes', 'endnotes', 'comments', 'commentaries');

  { Значения атрибута type у ссылок-сносок. }
  NOTE_LINK_TYPES: array[0..1] of UnicodeString = ('note', 'endnote');

  { Встроенный CSS для HTML-документа (аналог DEFAULT_CSS). }
  DEFAULT_CSS =
    'body { font-family: Georgia, ''Times New Roman'', serif; line-height: 1.5;' + #10 +
    '       max-width: 42em; margin: 0 auto; padding: 1em; }' + #10 +
    'h1, h2, h3, h4, h5, h6 { line-height: 1.25; }' + #10 +
    '.book-header { text-align: center; margin-bottom: 2em; }' + #10 +
    '.book-title { font-size: 1.8em; margin-bottom: 0.2em; }' + #10 +
    '.book-author { font-style: italic; margin: 0; }' + #10 +
    '.book-genres { color: #666; font-size: 0.9em; }' + #10 +
    '.toc { border: 1px solid #ccc; border-radius: 4px; padding: 1em 1.5em;' + #10 +
    '       margin: 1em 0 2em; background: #f9f9f9; }' + #10 +
    '.toc h2 { margin-top: 0; font-size: 1.2em; }' + #10 +
    '.toc ul { list-style: none; padding-left: 1.2em; margin: 0.3em 0; }' + #10 +
    '.toc a { text-decoration: none; color: #0645ad; }' + #10 +
    '.toc a:hover { text-decoration: underline; }' + #10 +
    'p { margin: 0; text-indent: 1.2em; }' + #10 +
    'p.subtitle { text-align: center; font-weight: bold; text-indent: 0; margin: 1em 0; }' + #10 +
    'p.empty-line { text-indent: 0; height: 1em; }' + #10 +
    'blockquote { margin: 1em 2em; }' + #10 +
    'blockquote.epigraph { font-style: italic; }' + #10 +
    '.poem { margin: 1em 2em; }' + #10 +
    '.poem .verse { text-indent: 0; }' + #10 +
    '.poem .poem-title { text-align: center; font-weight: bold; text-indent: 0; }' + #10 +
    '.text-author { text-align: right; font-style: italic; text-indent: 0; }' + #10 +
    '.annotation { border-left: 3px solid #ccc; padding-left: 1em;' + #10 +
    '              margin: 1em 0; font-style: italic; }' + #10 +
    'table { border-collapse: collapse; margin: 1em auto; }' + #10 +
    'td, th { border: 1px solid #888; padding: 0.2em 0.5em; }' + #10 +
    'th { background: #eee; }' + #10 +
    'img { max-width: 100%; height: auto; }' + #10 +
    '.cover { text-align: center; margin: 1em 0; }' + #10 +
    '.image { text-align: center; margin: 1em 0; }' + #10 +
    'a.note-ref { text-decoration: none; }' + #10 +
    'section.footnote { font-size: 0.92em; margin: 0.4em 0 0.4em 1.5em; }' + #10 +
    'section.footnote p { text-indent: 0; }' + #10 +
    'p.footnote-title { font-weight: bold; text-indent: 0; margin: 0.2em 0; }' + #10 +
    'p.footnote-back { text-indent: 0; margin-top: 0.2em; }' + #10 +
    'p.footnote-back a { text-decoration: none; }' + #10;

type
  { Узел оглавления: (level, anchor, title). Аналог кортежа в Python. }
  TTocEntry = class
  public
    Level: Integer;
    Anchor: UnicodeString;
    Title: UnicodeString;
  end;

  TTocEntryList = specialize TFPGObjectList<TTocEntry>;

  { Узел дерева оглавления. Аналог _TocNode. }
  TTocNode = class;
  TTocNodeList = specialize TFPGObjectList<TTocNode>;
  TTocNode = class
  public
    Anchor: UnicodeString;
    Title: UnicodeString;
    Children: TTocNodeList;
    constructor Create;
    destructor Destroy; override;
  end;

  { Преобразование разобранного FB2 в HTML + выгрузка картинок. }
  TFb2ToHtmlConverter = class
  private
    FParser: TFb2Parser;
    FOwnsParser: Boolean;
    FImageDir: UnicodeString;
    FHeadingOffset: Integer;
    FMaxHeadingLevel: Integer;
    FIncludeToc: Boolean;
    FTocTitle: UnicodeString;
    FIncludeAnnotation: Boolean;
    FIncludeEpigraphs: Boolean;
    FIncludeCover: Boolean;
    FInlineImages: Boolean;
    FNoteLinks: Boolean;
    FCss: UnicodeString;             { CSS-текст в <style> ('' — DEFAULT_CSS) }

    FDescription: TDescription;
    FBodies: TFb2ObjectList;
    FBinaries: TFb2ObjectList;
    FImageFiles: TStringList;      { id <binary> -> имя файла }
    FBinaryIndex: TStringList;     { id <binary> -> индекс в FBinaries }
    FUsedImages: TStringList;      { имена картинок, реально попавших в <img src> }
    FOnlyUsedImages: Boolean;      { выгружать только используемые <binary> }
    FTocEntries: TTocEntryList;
    FAnchorCounter: Integer;
    FNoteTargets: TStringList;     { id секций-сносок, на которые ссылаются }
    FNoteRefCounters: TStringList; { id -> счётчик ссылок }
    FNoteRefBlock: TStringList;    { id сноски -> блочный якорь её первой ссылки }
    FPendingNoteRefs: TStringList; { id сносок, чьи первые ссылки в текущем блоке }
    FParCounter: Integer;          { счётчик блочных якорей для сносок }

    procedure Prepare(const SourceFile: UnicodeString);
    procedure PrepareFromStream(AStream: TStream);
    procedure ParseLoaded;
    function BuildHtml: UnicodeString;
    function HtmlHead: UnicodeString;
    function RenderDescription: UnicodeString;
    function NewAnchor: UnicodeString;
    procedure AddTocEntry(Level: Integer; const Anchor, Title: UnicodeString);
    procedure BuildTocTree(Root: TTocNode);
    function RenderToc(Root: TTocNode): UnicodeString;
    function RenderTocTree(Node: TTocNode): UnicodeString;
    function RenderBodies: UnicodeString;
    function RenderBody(Body: TBody): UnicodeString;
    function RenderSection(Section: TSection; Level: Integer;
      InNotes: Boolean): UnicodeString;
    function RenderImageTag(const Src, Alt: UnicodeString): UnicodeString;
    function RenderBlock(Block: TFb2Object): UnicodeString;
    function RenderCite(Cite: TCite): UnicodeString;
    function RenderEpigraph(Epigraph: TEpigraph): UnicodeString;
    function RenderAnnotation(Annotation: TAnnotation): UnicodeString;
    function RenderPoem(Poem: TPoem): UnicodeString;
    function RenderStanza(Stanza: TStanza): UnicodeString;
    function RenderTable(Table: TTable): UnicodeString;
    function RenderInline(Nodes: TFb2ObjectList): UnicodeString;
    function RenderNoteRef(Node: TStyleNode;
      const Href: UnicodeString): UnicodeString;
    { Блочный якорь для только что отрисованного блока: если в нём были первые
      ссылки на сноски, возвращает ' id="noteref-<id>"' (иначе ''), запоминает
      блок для обратных ссылок и очищает FPendingNoteRefs. HtmlViewer корректно
      позиционирует ТОЛЬКО блочные якоря. }
    function TakeNoteBlockAttr: UnicodeString;
    function RenderTitleHtml(Title: TTitle): UnicodeString;
    function ImageSrc(const Href: UnicodeString): UnicodeString;
    function ImageDataUri(const ImageId: UnicodeString): UnicodeString;
    function TitleText(Title: TTitle): UnicodeString;
    function NodesText(Nodes: TFb2ObjectList): UnicodeString;
    procedure RegisterImages;
    procedure CollectNoteTargets;
    function ClampHeading(Level: Integer): Integer;
  public
    constructor Create(Parser: TFb2Parser = nil;
      const ImageDir: UnicodeString = 'images';
      HeadingOffset: Integer = 1;
      MaxHeadingLevel: Integer = 6;
      IncludeToc: Boolean = True;
      const TocTitle: UnicodeString = 'Оглавление';
      IncludeAnnotation: Boolean = True;
      IncludeEpigraphs: Boolean = True;
      IncludeCover: Boolean = True;
      InlineImages: Boolean = False;
      NoteLinks: Boolean = True;
      const Css: UnicodeString = DEFAULT_CSS);
    destructor Destroy; override;

    { Вернуть HTML-документ (файлы не создаются). }
    function Convert(const SourceFile: UnicodeString): UnicodeString;
    { То же, но источник — поток (файлы не создаются). }
    function ConvertStream(AStream: TStream): UnicodeString;
    { Записать HTML-файл и выгрузить все <binary>. }
    function Write(const SourceFile, HtmlPath: UnicodeString): UnicodeString;
    { То же, но источник — поток. }
    function WriteStream(AStream: TStream; const HtmlPath: UnicodeString): UnicodeString;
    { Пересобрать HTML из УЖЕ разобранного FB2 — без повторного чтения и
      разбора XML. Нужно после смены Css: текст, якоря и ссылки остаются теми
      же, меняется только блок <style> (движок CSS применяет при загрузке).
      Требует, чтобы до этого был вызван Convert/ConvertStream/Write*. }
    function RenderHtml: UnicodeString;
    { Выгрузить все <binary> в каталог изображений. }
    function SaveImages(const BaseDir: UnicodeString): TTextList;
    { id сносок, на которые ссылается текст (после Convert/Write). }
    function NoteTargets: TTextList;
    { <binary> по имени файла из <img src> ('images/cover.jpg' или 'cover.jpg');
      nil, если не найдено. Нужен для отдачи картинок из памяти (OnImageRequest). }
    function BinaryByFilename(const FileName: UnicodeString): TBinary;

    { Плоский список заголовков последнего Convert/Write:
      level (0 — тело книги, далее вложенность), anchor ('sec-N'), title.
      Именно из него строится оглавление (<nav class="toc">). }
    property TocEntries: TTocEntryList read FTocEntries;

    { Карта id <binary> -> имя файла (как в <img src>). }
    property ImageFiles: TStringList read FImageFiles;

    { Сохранять при SaveImages только те <binary>, что реально попали в <img src>
      (по умолчанию False — выгружаются все <binary>). }
    property OnlyUsedImages: Boolean read FOnlyUsedImages write FOnlyUsedImages;

    { CSS-текст документа (попадает в <style> в <head>; по умолчанию
      DEFAULT_CSS). Можно менять после Convert/ConvertStream и вызывать
      RenderHtml — оформление сменится без повторного разбора FB2. }
    property Css: UnicodeString read FCss write FCss;

    property Parser: TFb2Parser read FParser;
    property Description: TDescription read FDescription;
    property Bodies: TFb2ObjectList read FBodies;
    property Binaries: TFb2ObjectList read FBinaries;
  end;

implementation

{ ===================== Помощники уровня модуля ===================== }

{ Значение атрибута по имени (как в fb2_parser). }
function GetAttrQ(Elem: TDOMElement; const AName: UnicodeString): UnicodeString;
begin
  Result := '';
  if Elem = nil then
    Exit;
  Result := Elem.GetAttribute(AName);
end;

{ Значение атрибута по локальному имени (игнорируя префикс/пространство имён). }
function GetAttrByLocal(Elem: TDOMElement; const ALocal: UnicodeString): UnicodeString;
var
  Attrs: TDOMNamedNodeMap;
  I: Integer;
  Count: LongWord;
  Attr: TDOMNode;
begin
  Result := '';
  if Elem = nil then
    Exit;
  Attrs := Elem.Attributes;
  if Attrs = nil then
    Exit;
  Count := Attrs.Length;
  if Count = 0 then
    Exit;
  for I := 0 to Integer(Count) - 1 do
  begin
    Attr := Attrs.Item[LongWord(I)];
    if Attr = nil then
      Continue;
    if LocalName(Attr.NodeName) = ALocal then
    begin
      Result := Attr.NodeValue;
      Exit;
    end;
  end;
end;

{ Значение xlink:href (с фолбэком на href). }
function GetHref(Elem: TDOMElement): UnicodeString;
begin
  Result := '';
  if Elem = nil then
    Exit;
  Result := GetAttrQ(Elem, 'xlink:href');
  if Result = '' then
    Result := GetAttrQ(Elem, 'href');
  if Result = '' then
    Result := GetAttrByLocal(Elem, 'href');
end;

{ html.escape(s, quote=...): &, <, > всегда; " и ' — при Quote = True. }
function HtmlEscape(const S: UnicodeString; Quote: Boolean): UnicodeString;
var
  I: Integer;
  C: WideChar;
begin
  Result := '';
  for I := 1 to Length(S) do
  begin
    C := S[I];
    case C of
      '&': Result := Result + '&amp;';
      '<': Result := Result + '&lt;';
      '>': Result := Result + '&gt;';
      '"': if Quote then Result := Result + '&quot;' else Result := Result + '"';
      '''': if Quote then Result := Result + '&#x27;' else Result := Result + '''';
    else
      Result := Result + C;
    end;
  end;
end;

{ Объединение непустых строк (аналог "\n".join(p for p in parts if p)). }
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

const
  B64_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

{ base64-кодирование байтов (аналог base64.b64encode). }
function Base64EncodeBytes(const Data: TBytes): UnicodeString;
var
  I, L: Integer;
  B0, B1, B2: Byte;
  Triple: LongWord;
begin
  Result := '';
  L := Length(Data);
  I := 0;
  while I + 3 <= L do
  begin
    B0 := Data[I];
    B1 := Data[I + 1];
    B2 := Data[I + 2];
    Triple := (LongWord(B0) shl 16) or (LongWord(B1) shl 8) or B2;
    Result := Result + B64_ALPHABET[1 + ((Triple shr 18) and $3F)];
    Result := Result + B64_ALPHABET[1 + ((Triple shr 12) and $3F)];
    Result := Result + B64_ALPHABET[1 + ((Triple shr 6) and $3F)];
    Result := Result + B64_ALPHABET[1 + (Triple and $3F)];
    Inc(I, 3);
  end;
  if I < L then
  begin
    B0 := Data[I];
    B1 := 0;
    if I + 1 < L then
      B1 := Data[I + 1];
    Triple := (LongWord(B0) shl 16) or (LongWord(B1) shl 8);
    Result := Result + B64_ALPHABET[1 + ((Triple shr 18) and $3F)];
    Result := Result + B64_ALPHABET[1 + ((Triple shr 12) and $3F)];
    if I + 1 < L then
      Result := Result + B64_ALPHABET[1 + ((Triple shr 6) and $3F)]
    else
      Result := Result + '=';
    Result := Result + '=';
  end;
end;

function IsNoteBodyName(const S: UnicodeString): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := Low(NOTE_BODY_NAMES) to High(NOTE_BODY_NAMES) do
    if S = NOTE_BODY_NAMES[I] then
      Exit(True);
end;

function IsNoteLinkType(const S: UnicodeString): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := Low(NOTE_LINK_TYPES) to High(NOTE_LINK_TYPES) do
    if S = NOTE_LINK_TYPES[I] then
      Exit(True);
end;

{ Собрать id всех <section> внутри поддерева Node. }
procedure CollectSectionIds(Node: TDOMNode; Ids: TStringList);
var
  N: TDOMNode;
  Sid: UnicodeString;
begin
  N := Node.FirstChild;
  while N <> nil do
  begin
    if N.NodeType = ELEMENT_NODE then
    begin
      if LocalName(N.NodeName) = 'section' then
      begin
        Sid := GetAttrQ(TDOMElement(N), 'id');
        if (Sid <> '') and (Ids.IndexOf(Sid) < 0) then
          Ids.Add(Sid);
      end;
      CollectSectionIds(N, Ids);
    end;
    N := N.NextSibling;
  end;
end;

{ Для каждого <body name="notes|..."> собрать id его <section>. }
procedure CollectNoteBodySections(Node: TDOMNode; Ids: TStringList);
var
  N: TDOMNode;
  Name: UnicodeString;
begin
  N := Node.FirstChild;
  while N <> nil do
  begin
    if N.NodeType = ELEMENT_NODE then
    begin
      if LocalName(N.NodeName) = 'body' then
      begin
        Name := LowerCase(GetAttrQ(TDOMElement(N), 'name'));
        if IsNoteBodyName(Name) then
          CollectSectionIds(N, Ids);
      end;
      CollectNoteBodySections(N, Ids);
    end;
    N := N.NextSibling;
  end;
end;

{ Собрать цели <a href="#...">, которые являются сносками. }
procedure CollectNoteLinkTargets(Node: TDOMNode; NoteIds, Targets: TStringList);
var
  N: TDOMNode;
  Href, Target, LinkType: UnicodeString;
begin
  N := Node.FirstChild;
  while N <> nil do
  begin
    if N.NodeType = ELEMENT_NODE then
    begin
      if LocalName(N.NodeName) = 'a' then
      begin
        Href := GetHref(TDOMElement(N));
        if (Length(Href) >= 2) and (Copy(Href, 1, 1) = '#') then
        begin
          Target := Copy(Href, 2, Length(Href) - 1);
          LinkType := LowerCase(GetAttrQ(TDOMElement(N), 'type'));
          if (IsNoteLinkType(LinkType) or (NoteIds.IndexOf(Target) >= 0)) and
            (Targets.IndexOf(Target) < 0) then
            Targets.Add(Target);
        end;
      end;
      CollectNoteLinkTargets(N, NoteIds, Targets);
    end;
    N := N.NextSibling;
  end;
end;

{ ===================== TTocNode ===================== }

constructor TTocNode.Create;
begin
  inherited Create;
  Children := TTocNodeList.Create;
end;

destructor TTocNode.Destroy;
begin
  FreeAndNil(Children);
  inherited Destroy;
end;

{ ===================== Конструктор / деструктор ===================== }

constructor TFb2ToHtmlConverter.Create(Parser: TFb2Parser;
  const ImageDir: UnicodeString; HeadingOffset, MaxHeadingLevel: Integer;
  IncludeToc: Boolean; const TocTitle: UnicodeString; IncludeAnnotation,
  IncludeEpigraphs, IncludeCover, InlineImages, NoteLinks: Boolean;
  const Css: UnicodeString);
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
  FIncludeToc := IncludeToc;
  FTocTitle := TocTitle;
  FIncludeAnnotation := IncludeAnnotation;
  FIncludeEpigraphs := IncludeEpigraphs;
  FIncludeCover := IncludeCover;
  FInlineImages := InlineImages;
  FNoteLinks := NoteLinks;
  FCss := Css;

  FImageFiles := TStringList.Create;
  FBinaryIndex := TStringList.Create;
  FUsedImages := TStringList.Create;
  FUsedImages.Sorted := True;
  FUsedImages.Duplicates := dupIgnore;
  FTocEntries := TTocEntryList.Create;
  FNoteTargets := TStringList.Create;
  FNoteRefCounters := TStringList.Create;
  FNoteRefBlock := TStringList.Create;
  FPendingNoteRefs := TStringList.Create;
end;

destructor TFb2ToHtmlConverter.Destroy;
begin
  FreeAndNil(FDescription);
  FreeAndNil(FBodies);
  FreeAndNil(FBinaries);
  FreeAndNil(FImageFiles);
  FreeAndNil(FBinaryIndex);
  FreeAndNil(FUsedImages);
  FreeAndNil(FTocEntries);
  FreeAndNil(FNoteTargets);
  FreeAndNil(FNoteRefCounters);
  FreeAndNil(FNoteRefBlock);
  FreeAndNil(FPendingNoteRefs);
  if FOwnsParser then
    FreeAndNil(FParser);
  inherited Destroy;
end;

{ ===================== Публичный API ===================== }

procedure TFb2ToHtmlConverter.ParseLoaded;
begin
  try
    FDescription := FParser.Parse;
  except
    FDescription := nil;
  end;
  FBodies := FParser.ParseBodies;
  FBinaries := FParser.ParseBinaries;
  RegisterImages;
  CollectNoteTargets;
end;

procedure TFb2ToHtmlConverter.Prepare(const SourceFile: UnicodeString);
begin
  { Освобождаем результаты предыдущего разбора (повторные вызовы). }
  FreeAndNil(FDescription);
  FreeAndNil(FBodies);
  FreeAndNil(FBinaries);
  FUsedImages.Clear;
  FNoteRefCounters.Clear;
  FNoteRefBlock.Clear;
  FPendingNoteRefs.Clear;
  FParCounter := 0;

  FParser.LoadFile(SourceFile);
  ParseLoaded;
end;

procedure TFb2ToHtmlConverter.PrepareFromStream(AStream: TStream);
begin
  FreeAndNil(FDescription);
  FreeAndNil(FBodies);
  FreeAndNil(FBinaries);
  FUsedImages.Clear;
  FNoteRefCounters.Clear;
  FNoteRefBlock.Clear;
  FPendingNoteRefs.Clear;
  FParCounter := 0;

  FParser.LoadStream(AStream);
  ParseLoaded;
end;

function TFb2ToHtmlConverter.Convert(const SourceFile: UnicodeString): UnicodeString;
begin
  Prepare(SourceFile);
  Result := BuildHtml;
end;

function TFb2ToHtmlConverter.ConvertStream(AStream: TStream): UnicodeString;
begin
  PrepareFromStream(AStream);
  Result := BuildHtml;
end;

function TFb2ToHtmlConverter.RenderHtml: UnicodeString;
begin
  { Сброс ровно того же состояния, что и в Prepare/PrepareFromStream, но без
    повторного разбора XML: иначе повторная сборка дала бы другие якоря
    ('sec-N') и другие блочные якоря сносок ('noteref-<id>'). Сам BuildHtml
    сбрасывает FAnchorCounter, FTocEntries и FNoteRefCounters. }
  if (FParser = nil) or (FParser.Root = nil) then
    raise Exception.Create(
      'RenderHtml: FB2 ещё не разобран (сначала Convert/ConvertStream)');
  FUsedImages.Clear;
  FNoteRefBlock.Clear;
  FPendingNoteRefs.Clear;
  FParCounter := 0;
  Result := BuildHtml;
end;

function TFb2ToHtmlConverter.Write(const SourceFile,
  HtmlPath: UnicodeString): UnicodeString;
var
  HtmlDir: UnicodeString;
  Saved: TTextList;
begin
  Prepare(SourceFile);
  Result := BuildHtml;

  HtmlDir := ExtractFileDir(HtmlPath);
  if HtmlDir <> '' then
    ForceDirectories(HtmlDir);
  Saved := SaveImages(HtmlDir);
  Saved.Free;
  WriteUtf8File(HtmlPath, Result);

  Result := HtmlPath;
end;

function TFb2ToHtmlConverter.WriteStream(AStream: TStream;
  const HtmlPath: UnicodeString): UnicodeString;
var
  HtmlDir: UnicodeString;
  Saved: TTextList;
begin
  PrepareFromStream(AStream);
  Result := BuildHtml;

  HtmlDir := ExtractFileDir(HtmlPath);
  if HtmlDir <> '' then
    ForceDirectories(HtmlDir);
  Saved := SaveImages(HtmlDir);
  Saved.Free;
  WriteUtf8File(HtmlPath, Result);

  Result := HtmlPath;
end;

function TFb2ToHtmlConverter.BinaryByFilename(
  const FileName: UnicodeString): TBinary;
var
  Name: UnicodeString;
  I, Idx: Integer;
begin
  Result := nil;
  Name := ExtractFileName(FileName);
  if Name = '' then
    Exit;
  for I := 0 to FImageFiles.Count - 1 do
    if FImageFiles.ValueFromIndex[I] = Name then
    begin
      Idx := StrToIntDef(FBinaryIndex.Values[FImageFiles.Names[I]], -1);
      if (Idx >= 0) and (Idx < FBinaries.Count) then
        Result := TBinary(FBinaries[Idx]);
      Exit;
    end;
end;

function TFb2ToHtmlConverter.SaveImages(
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
    if FOnlyUsedImages and (FUsedImages.IndexOf(Filename) < 0) then
      Continue;   { картинка не попала в HTML — не выгружаем }
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

function TFb2ToHtmlConverter.NoteTargets: TTextList;
var
  Sorted: TStringList;
  I: Integer;
begin
  Result := TTextList.Create;
  Sorted := TStringList.Create;
  try
    Sorted.Assign(FNoteTargets);
    Sorted.Sort;
    for I := 0 to Sorted.Count - 1 do
      Result.Add(Sorted[I]);
  finally
    Sorted.Free;
  end;
end;

{ ===================== Подготовка данных ===================== }

procedure TFb2ToHtmlConverter.RegisterImages;
var
  I, P, Counter: Integer;
  Binary: TBinary;
  Filename, Stem, Suffix, Candidate: UnicodeString;
  Used: TStringList;
begin
  FImageFiles.Clear;
  FBinaryIndex.Clear;
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
      FBinaryIndex.Values[Binary.Id] := IntToStr(I);
    end;
  finally
    Used.Free;
  end;
end;

procedure TFb2ToHtmlConverter.CollectNoteTargets;
var
  NoteIds: TStringList;
begin
  FNoteTargets.Clear;
  if not FNoteLinks then
    Exit;
  if FParser.Root = nil then
    Exit;
  NoteIds := TStringList.Create;
  try
    CollectNoteBodySections(FParser.Root, NoteIds);
    CollectNoteLinkTargets(FParser.Root, NoteIds, FNoteTargets);
  finally
    NoteIds.Free;
  end;
end;

function TFb2ToHtmlConverter.ClampHeading(Level: Integer): Integer;
begin
  Result := Level;
  if Result < 1 then
    Result := 1;
  if Result > FMaxHeadingLevel then
    Result := FMaxHeadingLevel;
end;

{ ===================== Сборка документа ===================== }

function TFb2ToHtmlConverter.BuildHtml: UnicodeString;
var
  Parts: TTextList;
  TocHtml, Content: UnicodeString;
  Tree: TTocNode;
begin
  FAnchorCounter := 0;
  FTocEntries.Clear;
  FNoteRefCounters.Clear;

  Content := RenderBodies;

  TocHtml := '';
  if FIncludeToc then
  begin
    Tree := TTocNode.Create;
    try
      BuildTocTree(Tree);
      TocHtml := RenderToc(Tree);
    finally
      Tree.Free;
    end;
  end;

  Parts := TTextList.Create;
  try
    Parts.Add(HtmlHead);
    Parts.Add('<body>');
    Parts.Add(RenderDescription);
    Parts.Add(TocHtml);
    Parts.Add(Content);
    Parts.Add('</body>');
    Parts.Add('</html>');
    Result := JoinNonEmpty(Parts, #10);
  finally
    Parts.Free;
  end;
end;

function TFb2ToHtmlConverter.HtmlHead: UnicodeString;
var
  Info: TTitleInfo;
  Title: UnicodeString;
begin
  Title := 'FB2';
  if (FDescription <> nil) and (FDescription.TitleInfo <> nil) then
  begin
    Info := FDescription.TitleInfo;
    if Info.BookTitle <> nil then
      Title := Info.BookTitle.Value;
  end;
  Result := '<!DOCTYPE html>' + #10 +
    '<html lang="ru">' + #10 +
    '<head>' + #10 +
    '<meta charset="utf-8"/>' + #10 +
    '<title>' + HtmlEscape(Title, True) + '</title>' + #10 +
    '<style>' + #10 + FCss + '</style>' + #10 +
    '</head>';
end;

function TFb2ToHtmlConverter.RenderDescription: UnicodeString;
var
  Info: TTitleInfo;
  Parts, Authors, Genres: TTextList;
  I: Integer;
  Src, Alt, S: UnicodeString;
begin
  Result := '';
  if FDescription = nil then
    Exit;
  Info := FDescription.TitleInfo;
  if Info = nil then
    Exit;

  Parts := TTextList.Create;
  try
    Parts.Add('<header class="book-header">');

    if (Info.BookTitle <> nil) and (Info.BookTitle.Value <> '') then
      Parts.Add('<h1 class="book-title">' +
        HtmlEscape(Info.BookTitle.Value, True) + '</h1>');

    Authors := TTextList.Create;
    try
      for I := 0 to Info.Authors.Count - 1 do
        Authors.Add(FParser.FormatAuthor(TAuthor(Info.Authors[I])));
      S := JoinText(Authors, '; ');
      if S <> '' then
        Parts.Add('<p class="book-author">' + HtmlEscape(S, True) + '</p>');
    finally
      Authors.Free;
    end;

    if Info.Genres.Count > 0 then
    begin
      Genres := TTextList.Create;
      try
        for I := 0 to Info.Genres.Count - 1 do
          Genres.Add(TGenre(Info.Genres[I]).Value);
        Parts.Add('<p class="book-genres">' +
          HtmlEscape(JoinText(Genres, ', '), True) + '</p>');
      finally
        Genres.Free;
      end;
    end;

    if FIncludeCover and (Info.Coverpage <> nil) then
      for I := 0 to Info.Coverpage.Images.Count - 1 do
      begin
        Src := ImageSrc(TInlineImage(Info.Coverpage.Images[I]).Href);
        if Src <> '' then
        begin
          Alt := TInlineImage(Info.Coverpage.Images[I]).Alt;
          if Alt = '' then
            Alt := 'Обложка';
          Parts.Add('<div class="cover"><img src="' + Src +
            '" alt="' + HtmlEscape(Alt, True) + '"/></div>');
        end;
      end;

    if FIncludeAnnotation and (Info.Annotation <> nil) then
      Parts.Add(RenderAnnotation(Info.Annotation));

    Parts.Add('</header>');
    Result := JoinNonEmpty(Parts, #10);
  finally
    Parts.Free;
  end;
end;

{ ===================== Оглавление ===================== }

function TFb2ToHtmlConverter.NewAnchor: UnicodeString;
begin
  Inc(FAnchorCounter);
  Result := 'sec-' + IntToStr(FAnchorCounter);
end;

procedure TFb2ToHtmlConverter.AddTocEntry(Level: Integer;
  const Anchor, Title: UnicodeString);
var
  E: TTocEntry;
begin
  E := TTocEntry.Create;
  E.Level := Level;
  E.Anchor := Anchor;
  E.Title := Title;
  FTocEntries.Add(E);
end;

procedure TFb2ToHtmlConverter.BuildTocTree(Root: TTocNode);
var
  StackNodes: array of TTocNode;
  StackLevels: array of Integer;
  StackCount, I: Integer;
  Level: Integer;
  Entry: TTocEntry;
  Node: TTocNode;
begin
  StackCount := 1;
  SetLength(StackNodes, 1);
  SetLength(StackLevels, 1);
  StackNodes[0] := Root;
  StackLevels[0] := 0;

  for I := 0 to FTocEntries.Count - 1 do
  begin
    Entry := FTocEntries[I];
    Level := Entry.Level;
    while (StackCount > 1) and (StackLevels[StackCount - 1] >= Level) do
      Dec(StackCount);

    Node := TTocNode.Create;
    Node.Anchor := Entry.Anchor;
    Node.Title := Entry.Title;
    StackNodes[StackCount - 1].Children.Add(Node);

    if StackCount >= Length(StackNodes) then
    begin
      SetLength(StackNodes, StackCount + 1);
      SetLength(StackLevels, StackCount + 1);
    end;
    StackNodes[StackCount] := Node;
    StackLevels[StackCount] := Level;
    Inc(StackCount);
  end;
end;

function TFb2ToHtmlConverter.RenderToc(Root: TTocNode): UnicodeString;
var
  Inner: UnicodeString;
begin
  Result := '';
  if Root.Children.Count = 0 then
    Exit;
  Inner := RenderTocTree(Root);
  Result := '<nav class="toc">' + #10 +
    '<h2>' + HtmlEscape(FTocTitle, True) + '</h2>' + #10 +
    Inner + #10 +
    '</nav>';
end;

function TFb2ToHtmlConverter.RenderTocTree(Node: TTocNode): UnicodeString;
var
  Items: UnicodeString;
  I: Integer;
  Child: TTocNode;
  Sub, Link: UnicodeString;
begin
  Result := '';
  if Node.Children.Count = 0 then
    Exit;
  Items := '';
  for I := 0 to Node.Children.Count - 1 do
  begin
    Child := Node.Children[I];
    Sub := RenderTocTree(Child);
    Link := '<a href="#' + Child.Anchor + '">' +
      HtmlEscape(Child.Title, True) + '</a>';
    Items := Items + '<li>' + Link + Sub + '</li>';
  end;
  Result := '<ul>' + Items + '</ul>';
end;

{ ===================== Тело книги ===================== }

function TFb2ToHtmlConverter.RenderBodies: UnicodeString;
var
  Parts: TTextList;
  I: Integer;
begin
  Parts := TTextList.Create;
  try
    for I := 0 to FBodies.Count - 1 do
      Parts.Add(RenderBody(TBody(FBodies[I])));
    Result := JoinNonEmpty(Parts, #10);
  finally
    Parts.Free;
  end;
end;

function TFb2ToHtmlConverter.RenderBody(Body: TBody): UnicodeString;
var
  Parts: TTextList;
  I, Level: Integer;
  InNotes: Boolean;
  Classes, Src, Anchor, TitleHtml, HTag: UnicodeString;
begin
  Parts := TTextList.Create;
  try
    Classes := 'body';
    InNotes := IsNoteBodyName(LowerCase(Body.Name));
    if InNotes then
      Classes := Classes + ' notes';
    Parts.Add('<div class="' + Classes + '">');

    if Body.Title <> nil then
    begin
      Anchor := NewAnchor;
      AddTocEntry(0, Anchor, TitleText(Body.Title));
      Level := ClampHeading(FHeadingOffset);
      TitleHtml := RenderTitleHtml(Body.Title);
      HTag := '<h' + IntToStr(Level) + ' id="' + Anchor + '">';
      Parts.Add(HTag + TitleHtml + '</h' + IntToStr(Level) + '>');
    end;

    if FIncludeEpigraphs then
      for I := 0 to Body.Epigraphs.Count - 1 do
        Parts.Add(RenderEpigraph(TEpigraph(Body.Epigraphs[I])));

    if Body.Image <> nil then
    begin
      Src := ImageSrc(Body.Image.Href);
      if Src <> '' then
        Parts.Add(RenderImageTag(Src, Body.Image.Alt));
    end;

    for I := 0 to Body.Sections.Count - 1 do
      Parts.Add(RenderSection(TSection(Body.Sections[I]), FHeadingOffset,
        InNotes));

    Parts.Add('</div>');
    Result := JoinNonEmpty(Parts, #10);
  finally
    Parts.Free;
  end;
end;

function TFb2ToHtmlConverter.RenderSection(Section: TSection; Level: Integer;
  InNotes: Boolean): UnicodeString;
var
  Parts: TTextList;
  I, Lvl: Integer;
  IsNote: Boolean;
  Attrs, TitleHtml, Anchor, Tag, Back, Src: UnicodeString;
begin
  Parts := TTextList.Create;
  try
    IsNote := FNoteLinks and (Section.Id <> '') and
      (FNoteTargets.IndexOf(Section.Id) >= 0);
    Attrs := '';
    if Section.Id <> '' then
      Attrs := Attrs + ' id="' + HtmlEscape(Section.Id, True) + '"';
    if IsNote then
      Attrs := Attrs + ' class="footnote"';
    Parts.Add('<section' + Attrs + '>');

    if Section.Title <> nil then
    begin
      TitleHtml := RenderTitleHtml(Section.Title);
      if IsNote or InNotes then
        Parts.Add('<p class="footnote-title">' + TitleHtml + '</p>')
      else
      begin
        Anchor := NewAnchor;
        AddTocEntry(Level, Anchor, TitleText(Section.Title));
        Lvl := ClampHeading(Level);
        Tag := 'h' + IntToStr(Lvl);
        Parts.Add('<' + Tag + ' id="' + Anchor + '">' + TitleHtml +
          '</' + Tag + '>');
      end;
    end;

    if FIncludeEpigraphs then
      for I := 0 to Section.Epigraphs.Count - 1 do
        Parts.Add(RenderEpigraph(TEpigraph(Section.Epigraphs[I])));

    if Section.Image <> nil then
    begin
      Src := ImageSrc(Section.Image.Href);
      if Src <> '' then
        Parts.Add(RenderImageTag(Src, Section.Image.Alt));
    end;

    if FIncludeAnnotation and (Section.Annotation <> nil) then
      Parts.Add(RenderAnnotation(Section.Annotation));

    for I := 0 to Section.Content.Count - 1 do
      Parts.Add(RenderBlock(Section.Content[I]));

    for I := 0 to Section.Sections.Count - 1 do
      Parts.Add(RenderSection(TSection(Section.Sections[I]), Level + 1,
        InNotes));

    if IsNote then
    begin
      { Обратная ссылка ведёт на БЛОЧНЫЙ якорь абзаца с первой ссылкой на эту
        сноску (инлайновые якоря HtmlViewer позиционирует неверно — уводит в
        конец документа). Если ссылки на сноску в тексте нет — прежний id. }
      Back := FNoteRefBlock.Values[Section.Id];
      if Back = '' then
        Back := 'noteref-' + Section.Id;
      Back := HtmlEscape(Back, True);
      Parts.Add('<p class="footnote-back"><a href="#' + Back +
        '">↩</a></p>');
    end;

    Parts.Add('</section>');
    Result := JoinNonEmpty(Parts, #10);
  finally
    Parts.Free;
  end;
end;

function TFb2ToHtmlConverter.RenderImageTag(const Src,
  Alt: UnicodeString): UnicodeString;
begin
  Result := '<div class="image"><img src="' + Src + '" alt="' +
    HtmlEscape(Alt, True) + '"/></div>';
end;

{ ===================== Блочные элементы ===================== }

function TFb2ToHtmlConverter.RenderBlock(Block: TFb2Object): UnicodeString;
var
  Src, Inner: UnicodeString;
begin
  Result := '';
  if Block = nil then
    Exit;
  FPendingNoteRefs.Clear;
  if Block is TParagraph then
  begin
    Inner := RenderInline(TParagraph(Block).Content);
    Result := '<p' + TakeNoteBlockAttr + '>' + Inner + '</p>';
  end
  else if Block is TSubtitle then
  begin
    Inner := RenderInline(TSubtitle(Block).Content);
    Result := '<p class="subtitle"' + TakeNoteBlockAttr + '>' + Inner + '</p>';
  end
  else if Block is TEmptyLine then
    Result := '<p class="empty-line">&#160;</p>'
  else if Block is TCite then
    Result := RenderCite(TCite(Block))
  else if Block is TEpigraph then
    Result := RenderEpigraph(TEpigraph(Block))
  else if Block is TPoem then
    Result := RenderPoem(TPoem(Block))
  else if Block is TTable then
    Result := RenderTable(TTable(Block))
  else if Block is TImage then
  begin
    Src := ImageSrc(TImage(Block).Href);
    if Src <> '' then
      Result := RenderImageTag(Src, TImage(Block).Alt);
  end;
end;

function TFb2ToHtmlConverter.RenderCite(Cite: TCite): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
begin
  Parts := TTextList.Create;
  try
    Parts.Add('<blockquote>');
    for I := 0 to Cite.Items.Count - 1 do
      Parts.Add(RenderBlock(Cite.Items[I]));
    for I := 0 to Cite.TextAuthor.Count - 1 do
      Parts.Add('<p class="text-author">' +
        RenderInline(TParagraph(Cite.TextAuthor[I]).Content) + '</p>');
    Parts.Add('</blockquote>');
    Result := JoinNonEmpty(Parts, #10);
  finally
    Parts.Free;
  end;
end;

function TFb2ToHtmlConverter.RenderEpigraph(Epigraph: TEpigraph): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
begin
  Parts := TTextList.Create;
  try
    Parts.Add('<blockquote class="epigraph">');
    for I := 0 to Epigraph.Items.Count - 1 do
      Parts.Add(RenderBlock(Epigraph.Items[I]));
    for I := 0 to Epigraph.TextAuthor.Count - 1 do
      Parts.Add('<p class="text-author">' +
        RenderInline(TParagraph(Epigraph.TextAuthor[I]).Content) + '</p>');
    Parts.Add('</blockquote>');
    Result := JoinNonEmpty(Parts, #10);
  finally
    Parts.Free;
  end;
end;

function TFb2ToHtmlConverter.RenderAnnotation(
  Annotation: TAnnotation): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
begin
  Parts := TTextList.Create;
  try
    Parts.Add('<div class="annotation">');
    for I := 0 to Annotation.Items.Count - 1 do
      Parts.Add(RenderBlock(Annotation.Items[I]));
    Parts.Add('</div>');
    Result := JoinNonEmpty(Parts, #10);
  finally
    Parts.Free;
  end;
end;

function TFb2ToHtmlConverter.RenderPoem(Poem: TPoem): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
  Item: TFb2Object;
begin
  Parts := TTextList.Create;
  try
    Parts.Add('<div class="poem">');
    if Poem.Title <> nil then
      Parts.Add('<p class="poem-title">' + RenderTitleHtml(Poem.Title) + '</p>');
    for I := 0 to Poem.Epigraphs.Count - 1 do
      Parts.Add(RenderEpigraph(TEpigraph(Poem.Epigraphs[I])));
    for I := 0 to Poem.Items.Count - 1 do
    begin
      Item := Poem.Items[I];
      if Item is TStanza then
        Parts.Add(RenderStanza(TStanza(Item)))
      else if Item is TSubtitle then
        Parts.Add('<p class="subtitle">' + RenderInline(TSubtitle(Item).Content) +
          '</p>');
    end;
    for I := 0 to Poem.TextAuthor.Count - 1 do
      Parts.Add('<p class="text-author">' +
        RenderInline(TParagraph(Poem.TextAuthor[I]).Content) + '</p>');
    if (Poem.Date <> nil) and (Poem.Date.Value <> '') then
      Parts.Add('<p class="text-author">' + HtmlEscape(Poem.Date.Value, True) +
        '</p>');
    Parts.Add('</div>');
    Result := JoinNonEmpty(Parts, #10);
  finally
    Parts.Free;
  end;
end;

function TFb2ToHtmlConverter.RenderStanza(Stanza: TStanza): UnicodeString;
var
  Parts: TTextList;
  I: Integer;
begin
  Parts := TTextList.Create;
  try
    Parts.Add('<div class="stanza">');
    if Stanza.Title <> nil then
      Parts.Add('<p class="poem-title">' + RenderTitleHtml(Stanza.Title) +
        '</p>');
    if Stanza.Subtitle <> nil then
      Parts.Add('<p class="subtitle">' + RenderInline(Stanza.Subtitle.Content) +
        '</p>');
    for I := 0 to Stanza.Verses.Count - 1 do
      Parts.Add('<p class="verse">' +
        RenderInline(TParagraph(Stanza.Verses[I]).Content) + '</p>');
    Parts.Add('</div>');
    Result := JoinNonEmpty(Parts, #10);
  finally
    Parts.Free;
  end;
end;

function TFb2ToHtmlConverter.RenderTable(Table: TTable): UnicodeString;
var
  Rows, Cells: UnicodeString;
  I, J: Integer;
  Row: TTableRow;
  Cell: TTableCell;
  Tag, Attrs: UnicodeString;
begin
  Rows := '';
  for I := 0 to Table.Rows.Count - 1 do
  begin
    Row := TTableRow(Table.Rows[I]);
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
        RenderInline(Cell.Children) + '</' + Tag + '>';
    end;
    Rows := Rows + '<tr>' + Cells + '</tr>';
  end;
  Result := '<table>' + Rows + '</table>';
end;

{ ===================== Inline-разметка ===================== }

function TFb2ToHtmlConverter.RenderInline(Nodes: TFb2ObjectList): UnicodeString;
var
  I: Integer;
  Node: TStyleNode;
  Tag, Href, CssClass, Escaped, Src, Alt: UnicodeString;
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
      Result := Result + '<strong>' + RenderInline(Node.Children) + '</strong>'
    else if Tag = 'emphasis' then
      Result := Result + '<em>' + RenderInline(Node.Children) + '</em>'
    else if Tag = 'strikethrough' then
      Result := Result + '<del>' + RenderInline(Node.Children) + '</del>'
    else if (Tag = 'sub') or (Tag = 'sup') or (Tag = 'code') then
      Result := Result + '<' + Tag + '>' + RenderInline(Node.Children) +
        '</' + Tag + '>'
    else if Tag = 'style' then
    begin
      CssClass := HtmlEscape(Node.StyleName, True);
      Result := Result + '<span class="' + CssClass + '">' +
        RenderInline(Node.Children) + '</span>';
    end
    else if Tag = 'a' then
    begin
      Href := Node.Href;
      if FNoteLinks and (Length(Href) > 1) and (Copy(Href, 1, 1) = '#') and
        (FNoteTargets.IndexOf(Copy(Href, 2, Length(Href) - 1)) >= 0) then
        Result := Result + RenderNoteRef(Node, Href)
      else
      begin
        Escaped := HtmlEscape(Href, True);
        Result := Result + '<a href="' + Escaped + '">' +
          RenderInline(Node.Children) + '</a>';
      end;
    end
    else if Tag = 'image' then
    begin
      Src := ImageSrc(Node.ImageHref);
      if Src <> '' then
      begin
        Alt := HtmlEscape(Node.ImageAlt, True);
        Result := Result + '<img src="' + Src + '" alt="' + Alt + '"/>';
      end;
    end;
  end;
end;

function TFb2ToHtmlConverter.TakeNoteBlockAttr: UnicodeString;
var
  I: Integer;
  Id, BlockId: UnicodeString;
begin
  Result := '';
  if FPendingNoteRefs.Count = 0 then
    Exit;
  { Имя блочного якоря — по ПЕРВОЙ сноске в блоке; на него будут ссылаться
    обратные ссылки всех сносок, чьи первые ссылки оказались в этом блоке. }
  BlockId := 'noteref-' + FPendingNoteRefs[0];
  Result := ' id="' + HtmlEscape(BlockId, True) + '"';
  for I := 0 to FPendingNoteRefs.Count - 1 do
  begin
    Id := FPendingNoteRefs[I];
    if FNoteRefBlock.Values[Id] = '' then
      FNoteRefBlock.Values[Id] := BlockId;
  end;
  FPendingNoteRefs.Clear;
end;

function TFb2ToHtmlConverter.RenderNoteRef(Node: TStyleNode;
  const Href: UnicodeString): UnicodeString;
var
  Target, Inner, CountStr: UnicodeString;
  Count: Integer;
begin
  Target := Copy(Href, 2, Length(Href) - 1);
  CountStr := FNoteRefCounters.Values[Target];
  if CountStr = '' then
    Count := 0
  else
    Count := StrToIntDef(CountStr, 0);
  Inc(Count);
  FNoteRefCounters.Values[Target] := IntToStr(Count);
  { Первая ссылка на сноску: запомним её, чтобы блок (абзац), в котором она
    лежит, получил БЛОЧНЫЙ якорь — HtmlViewer корректно позиционирует только
    блочные якоря, а инлайновые ведут в конец документа. }
  if Count = 1 then
    FPendingNoteRefs.Add(Target);
  Inner := RenderInline(Node.Children);
  Result := '<a class="note-ref" href="' + HtmlEscape(Href, True) + '">' +
    Inner + '</a>';
end;

function TFb2ToHtmlConverter.RenderTitleHtml(Title: TTitle): UnicodeString;
var
  I: Integer;
  Item: TFb2Object;
  Parts: TTextList;
  Text: UnicodeString;
begin
  Result := '';
  if Title = nil then
    Exit;
  Parts := TTextList.Create;
  try
    for I := 0 to Title.Items.Count - 1 do
    begin
      Item := Title.Items[I];
      if Item is TParagraph then
        Parts.Add(RenderInline(TParagraph(Item).Content));
    end;
    Text := '';
    for I := 0 to Parts.Count - 1 do
    begin
      if Parts[I] = '' then
        Continue;
      if Text <> '' then
        Text := Text + ' ';
      Text := Text + Parts[I];
    end;
    Result := Text;
  finally
    Parts.Free;
  end;
end;

{ ===================== Изображения ===================== }

function TFb2ToHtmlConverter.ImageSrc(const Href: UnicodeString): UnicodeString;
var
  ImageId, Filename, Src: UnicodeString;
begin
  Result := '';
  if Href = '' then
    Exit;
  if Copy(Href, 1, 1) = '#' then
    ImageId := Copy(Href, 2, Length(Href) - 1)
  else
    ImageId := Href;
  if FInlineImages then
  begin
    Result := ImageDataUri(ImageId);
    Exit;
  end;
  Filename := FImageFiles.Values[ImageId];
  if Filename = '' then
    Filename := ExtractFileName(ImageId);
  if Filename <> '' then
    FUsedImages.Add(Filename);   { отметить, что картинка попала в HTML }
  if FImageDir <> '' then
    Src := FImageDir + '/' + Filename
  else
    Src := Filename;
  Result := HtmlEscape(Src, True);
end;

function TFb2ToHtmlConverter.ImageDataUri(const ImageId: UnicodeString): UnicodeString;
var
  V: UnicodeString;
  Idx: Integer;
  Binary: TBinary;
  Data: TBytes;
  Encoded, CT: UnicodeString;
begin
  Result := '';
  V := FBinaryIndex.Values[ImageId];
  if V = '' then
    Exit;
  Idx := StrToIntDef(V, -1);
  if (Idx < 0) or (Idx >= FBinaries.Count) then
    Exit;
  Binary := TBinary(FBinaries[Idx]);
  try
    Data := FParser.BinaryData(Binary);
  except
    Exit;
  end;
  Encoded := Base64EncodeBytes(Data);
  CT := Binary.ContentType;
  if CT = '' then
    CT := 'application/octet-stream';
  Result := 'data:' + CT + ';base64,' + Encoded;
end;

{ ===================== Утилиты ===================== }

function TFb2ToHtmlConverter.TitleText(Title: TTitle): UnicodeString;
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
        Parts.Add(NodesText(TParagraph(Title.Items[I]).Content));
    Result := JoinNonEmpty(Parts, ' ');
  finally
    Parts.Free;
  end;
end;

function TFb2ToHtmlConverter.NodesText(Nodes: TFb2ObjectList): UnicodeString;
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
      Result := Result + NodesText(Node.Children);
  end;
end;

end.
