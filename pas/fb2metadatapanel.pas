unit fb2metadatapanel;
{ Карточка книги FB2: просмотр и редактирование метаданных с записью обратно.

  Показывает <description> — title-info (название, авторы, жанры, аннотация,
  дата, язык, ключевые слова, обложка) и document-info (id, версия), позволяет
  править поля и сохранять результат в FB2 через fb2_writer.

  Текст (bodies) и бинарные данные (binaries) сохраняются как есть — правится
  только описательная часть. Файл при сохранении перезаписывается целиком
  средствами fb2_writer, поэтому форматирование исходного файла может
  измениться (отступы, порядок атрибутов) — это ожидаемо.

  Кодировки: строки LCL (TEdit.Text, TListBox.Items и т. п.) — UTF-8, поэтому
  при чтении/записи выполняется явная конвертация (UTF8ToString/UTF8Encode), а
  путь файла — через UTF8ToSys/UTF8ToString. Это важно: DefaultSystemCodePage
  на русской Windows = 1251, и неявные конверсии испортили бы кириллицу.

  Аннотация в поле ввода — простой текст, один абзац на строку (при сохранении
  каждый непустой строке соответствует <p> в <annotation>).

  Требует LCL и библиотечных модулей fb2_parser/fb2_writer/fb2_genres.
  GUI-модуль (в make-сборку библиотеки не входит). }

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Classes, SysUtils, Controls, StdCtrls, ExtCtrls, Forms, Graphics, Dialogs,
  LazUTF8,
  fb2_structures, fb2_parser, fb2_writer, fb2_genres, fb2_files;

type
  { Панель метаданных FB2. }
  TFb2MetadataPanel = class(TCustomPanel)
  private
    FParser: TFb2Parser;
    FBook: TFictionBook;
    FFileName: TFileName;
    FModified: Boolean;
    FUpdating: Boolean;
    FShowButtons: Boolean;
    FGenreCodes: TStringList;      { коды жанров параллельно ComboGenre.Items }
    FOnModifiedChange: TNotifyEvent;

    { --- управление ------------------------------------------------- }
    FTopPanel: TPanel;
    FBtnOpen, FBtnSave, FBtnSaveAs, FBtnRevert: TButton;
    FScroll: TScrollBox;
    FLblTitle, FLblAuthors, FLblGenres, FLblAnnotation: TLabel;
    FEditTitle: TEdit;
    FListAuthors: TListBox;
    FLblFirst, FLblMiddle, FLblLast, FLblNick: TLabel;
    FEditFirst, FEditMiddle, FEditLast, FEditNick: TEdit;
    FBtnAuthorAdd, FBtnAuthorSet, FBtnAuthorDel: TButton;
    FListGenres: TListBox;
    FComboGenre: TComboBox;
    FBtnGenreAdd, FBtnGenreDel: TButton;
    FMemoAnnotation: TMemo;
    FLblDate, FLblLang, FLblKeywords: TLabel;
    FEditDate, FEditLang, FEditKeywords: TEdit;
    FLblId, FLblVersion: TLabel;
    FEditId, FEditVersion: TEdit;
    FLblCover: TLabel;
    { ExtCtrls.TImage: в fb2_structures тоже есть TImage (элемент FB2), и он
      перекрыл бы LCL-овский (в FPC побеждает последний юнит в uses). }
    FImageCover: ExtCtrls.TImage;
    FBtnCoverClear: TButton;
    FStatus: TLabel;

    { --- построение интерфейса -------------------------------------- }
    procedure BuildUi;
    function NewLabel(const ACaption: string; ALeft, ATop: Integer): TLabel;
    function NewEdit(ALeft, ATop, AWidth: Integer): TEdit;
    function NewButton(const ACaption: string; ALeft, ATop,
      AWidth: Integer): TButton;
    procedure LayoutUi;

    { --- свойства и события ----------------------------------------- }
    procedure SetFileName(const Value: TFileName);
    procedure SetShowButtons(const Value: Boolean);
    procedure SetModified(const Value: Boolean);
    procedure Changed(Sender: TObject);
    procedure AuthorSelect(Sender: TObject);
    procedure AuthorAdd(Sender: TObject);
    procedure AuthorSet(Sender: TObject);
    procedure AuthorDel(Sender: TObject);
    procedure GenreAdd(Sender: TObject);
    procedure GenreDel(Sender: TObject);
    procedure CoverClear(Sender: TObject);
    procedure OpenClick(Sender: TObject);
    procedure SaveClick(Sender: TObject);
    procedure SaveAsClick(Sender: TObject);
    procedure RevertClick(Sender: TObject);

    { --- данные ------------------------------------------------------ }
    function TitleInfo: TTitleInfo;
    function DocumentInfo: TDocumentInfo;
    function AuthorFromFields: TAuthor;
    procedure FillAuthors;
    procedure FillGenres;
    procedure FillAnnotation;
    procedure FillGenreCombo;
    procedure ShowCover;
    procedure ShowStatus(const S: UnicodeString; IsError: Boolean);
  protected
    procedure Resize; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    { Прочитать FB2 и показать карточку. }
    procedure LoadFromFile(const AFileName: TFileName);
    { Записать книгу в файл (по умолчанию — в исходный). }
    procedure SaveToFile(const AFileName: TFileName = '');
    { Перечитать исходный файл (отмена правок). }
    procedure Revert;
    { Перенести значения полей в структуру книги. }
    procedure ApplyToBook;
    { Обновить поля из структуры книги. }
    procedure Refresh;

    { Текущая книга (владелец — панель). }
    property Book: TFictionBook read FBook;
    { Есть несохранённые правки. }
    property Modified: Boolean read FModified;
  published
    { Путь к FB2: установка сразу загружает карточку. }
    property FileName: TFileName read FFileName write SetFileName;
    { Показывать панель кнопок «Открыть/Сохранить/Сохранить как/Отменить». }
    property ShowButtons: Boolean read FShowButtons write SetShowButtons default True;
    { Событие: изменилось состояние «есть несохранённые правки». }
    property OnModifiedChange: TNotifyEvent read FOnModifiedChange write FOnModifiedChange;
  end;

implementation

{ ===================== Помощники ===================== }

{ Человекочитаемое имя автора. }
function AuthorText(A: TAuthor): UnicodeString;
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

{ Простой текст узлов разметки. }
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

{ Аннотация как простой текст: абзац на строку. }
function AnnotationToText(A: TAnnotation): UnicodeString;
var
  I: Integer;
  Lines: TTextList;
  Item: TFb2Object;
  S: UnicodeString;
begin
  Result := '';
  if A = nil then
    Exit;
  Lines := TTextList.Create;
  try
    for I := 0 to A.Items.Count - 1 do
    begin
      Item := A.Items[I];
      if Item is TParagraph then
        S := MarkupPlain(TParagraph(Item).Content)
      else if Item is TSubtitle then
        S := MarkupPlain(TSubtitle(Item).Content)
      else
        Continue;
      Lines.Add(S);
    end;
    Result := JoinText(Lines, #10);
  finally
    Lines.Free;
  end;
end;

{ Разбить текст на непустые строки (для сборки аннотации). }
procedure TextToLines(const Text: UnicodeString; Lines: TTextList);
var
  I, Start: Integer;
  S: UnicodeString;
begin
  Start := 1;
  for I := 1 to Length(Text) + 1 do
    if (I > Length(Text)) or (Text[I] = #10) or (Text[I] = #13) then
    begin
      S := Copy(Text, Start, I - Start);
      if S <> '' then
        Lines.Add(S);
      Start := I + 1;
    end;
end;

{ ===================== Создание ===================== }

constructor TFb2MetadataPanel.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FParser := TFb2Parser.Create;
  FGenreCodes := TStringList.Create;
  FShowButtons := True;
  BevelOuter := bvNone;
  BuildUi;
  LayoutUi;
  ShowStatus('', False);
end;

destructor TFb2MetadataPanel.Destroy;
begin
  FreeAndNil(FBook);
  FreeAndNil(FGenreCodes);
  FreeAndNil(FParser);
  inherited Destroy;
end;

function TFb2MetadataPanel.NewLabel(const ACaption: string;
  ALeft, ATop: Integer): TLabel;
begin
  Result := TLabel.Create(Self);
  Result.Parent := FScroll;
  Result.Caption := ACaption;
  Result.Left := ALeft;
  Result.Top := ATop;
  Result.AutoSize := True;
end;

function TFb2MetadataPanel.NewEdit(ALeft, ATop, AWidth: Integer): TEdit;
begin
  Result := TEdit.Create(Self);
  Result.Parent := FScroll;
  Result.Left := ALeft;
  Result.Top := ATop;
  Result.Width := AWidth;
  Result.OnChange := @Changed;
end;

function TFb2MetadataPanel.NewButton(const ACaption: string;
  ALeft, ATop, AWidth: Integer): TButton;
begin
  Result := TButton.Create(Self);
  Result.Parent := FScroll;
  Result.Caption := ACaption;
  Result.Left := ALeft;
  Result.Top := ATop;
  Result.Width := AWidth;
end;

{ ===================== Интерфейс ===================== }

procedure TFb2MetadataPanel.BuildUi;
begin
  { --- панель кнопок (сверху) --- }
  FTopPanel := TPanel.Create(Self);
  FTopPanel.Parent := Self;
  FTopPanel.Align := alTop;
  FTopPanel.Height := 34;
  FTopPanel.BevelOuter := bvNone;

  FBtnOpen := NewButton('Открыть…', 6, 5, 90);
  FBtnOpen.Parent := FTopPanel;
  FBtnOpen.OnClick := @OpenClick;
  FBtnSave := NewButton('Сохранить', 100, 5, 90);
  FBtnSave.Parent := FTopPanel;
  FBtnSave.OnClick := @SaveClick;
  FBtnSaveAs := NewButton('Сохранить как…', 194, 5, 124);
  FBtnSaveAs.Parent := FTopPanel;
  FBtnSaveAs.OnClick := @SaveAsClick;
  FBtnRevert := NewButton('Отменить', 322, 5, 90);
  FBtnRevert.Parent := FTopPanel;
  FBtnRevert.OnClick := @RevertClick;

  { --- строка состояния (снизу) --- }
  FStatus := TLabel.Create(Self);
  FStatus.Parent := Self;
  FStatus.Align := alBottom;
  FStatus.AutoSize := False;
  FStatus.Height := 18;
  FStatus.Caption := '';

  { --- прокручиваемая область (всё остальное) --- }
  FScroll := TScrollBox.Create(Self);
  FScroll.Parent := Self;
  FScroll.Align := alClient;
  FScroll.BorderStyle := bsNone;

  { Название }
  FLblTitle := NewLabel('Название:', 8, 11);
  FEditTitle := NewEdit(108, 8, 400);

  { Авторы }
  FLblAuthors := NewLabel('Авторы:', 8, 42);
  FListAuthors := TListBox.Create(Self);
  FListAuthors.Parent := FScroll;
  FListAuthors.Left := 108;
  FListAuthors.Top := 40;
  FListAuthors.Width := 400;
  FListAuthors.Height := 88;
  FListAuthors.OnClick := @AuthorSelect;

  FLblFirst := NewLabel('Имя:', 108, 140);
  FEditFirst := NewEdit(190, 137, 140);
  FLblMiddle := NewLabel('Отчество:', 344, 140);
  FEditMiddle := NewEdit(412, 137, 140);
  FLblLast := NewLabel('Фамилия:', 108, 168);
  FEditLast := NewEdit(190, 165, 140);
  FLblNick := NewLabel('Псевдоним:', 344, 168);
  FEditNick := NewEdit(412, 165, 140);

  FBtnAuthorAdd := NewButton('Добавить', 108, 196, 90);
  FBtnAuthorAdd.OnClick := @AuthorAdd;
  FBtnAuthorSet := NewButton('Заменить', 204, 196, 90);
  FBtnAuthorSet.OnClick := @AuthorSet;
  FBtnAuthorDel := NewButton('Удалить', 300, 196, 90);
  FBtnAuthorDel.OnClick := @AuthorDel;

  { Жанры }
  FLblGenres := NewLabel('Жанры:', 8, 240);
  FListGenres := TListBox.Create(Self);
  FListGenres.Parent := FScroll;
  FListGenres.Left := 108;
  FListGenres.Top := 238;
  FListGenres.Width := 190;
  FListGenres.Height := 88;

  FComboGenre := TComboBox.Create(Self);
  FComboGenre.Parent := FScroll;
  FComboGenre.Left := 306;
  FComboGenre.Top := 238;
  FComboGenre.Width := 202;
  FComboGenre.Style := csDropDown;
  FBtnGenreAdd := NewButton('Добавить', 306, 268, 96);
  FBtnGenreAdd.OnClick := @GenreAdd;
  FBtnGenreDel := NewButton('Удалить', 406, 268, 102);
  FBtnGenreDel.OnClick := @GenreDel;

  { Аннотация }
  FLblAnnotation := NewLabel('Аннотация:', 8, 340);
  FMemoAnnotation := TMemo.Create(Self);
  FMemoAnnotation.Parent := FScroll;
  FMemoAnnotation.Left := 108;
  FMemoAnnotation.Top := 338;
  FMemoAnnotation.Width := 400;
  FMemoAnnotation.Height := 110;
  FMemoAnnotation.ScrollBars := ssVertical;
  FMemoAnnotation.OnChange := @Changed;

  { Дата / язык / ключевые слова }
  FLblDate := NewLabel('Дата:', 8, 458);
  FEditDate := NewEdit(108, 455, 80);
  FLblLang := NewLabel('Язык:', 200, 458);
  FEditLang := NewEdit(248, 455, 60);
  FLblKeywords := NewLabel('Ключевые слова:', 320, 458);
  FEditKeywords := NewEdit(420, 455, 88);

  { Идентификатор / версия }
  FLblId := NewLabel('Идентификатор:', 8, 486);
  FEditId := NewEdit(108, 483, 400);
  FLblVersion := NewLabel('Версия:', 8, 514);
  FEditVersion := NewEdit(108, 511, 60);

  { Обложка }
  FLblCover := NewLabel('Обложка:', 8, 546);
  FImageCover := ExtCtrls.TImage.Create(Self);
  FImageCover.Parent := FScroll;
  FImageCover.Left := 108;
  FImageCover.Top := 544;
  FImageCover.Width := 120;
  FImageCover.Height := 160;
  FImageCover.Stretch := True;
  FImageCover.Proportional := True;
  FImageCover.Center := True;
  FImageCover.Visible := False;
  FBtnCoverClear := NewButton('Убрать обложку', 240, 544, 120);
  FBtnCoverClear.OnClick := @CoverClear;

  FillGenreCombo;
end;

{ Ширины «широких» полей — по ширине области прокрутки. }
procedure TFb2MetadataPanel.LayoutUi;
var
  W: Integer;
begin
  if FScroll = nil then
    Exit;
  W := FScroll.ClientWidth;
  if W < 520 then
    W := 520;                    { ниже этого — появится горизонтальная полоса }
  if FEditTitle <> nil then
  begin
    FEditTitle.Width := W - FEditTitle.Left - 12;
    FListAuthors.Width := FEditTitle.Width;
    FMemoAnnotation.Width := FEditTitle.Width;
    FEditId.Width := FEditTitle.Width;
  end;
end;

procedure TFb2MetadataPanel.Resize;
begin
  inherited Resize;
  LayoutUi;
end;

{ ===================== Свойства ===================== }

procedure TFb2MetadataPanel.SetFileName(const Value: TFileName);
begin
  if Value = FFileName then
    Exit;
  FFileName := Value;
  if (Value <> '') and FileExists(UTF8ToSys(Value)) then
    LoadFromFile(Value);
end;

procedure TFb2MetadataPanel.SetShowButtons(const Value: Boolean);
begin
  if FShowButtons = Value then
    Exit;
  FShowButtons := Value;
  if FTopPanel <> nil then
    FTopPanel.Visible := Value;
end;

procedure TFb2MetadataPanel.SetModified(const Value: Boolean);
begin
  if FModified = Value then
    Exit;
  FModified := Value;
  if Assigned(FOnModifiedChange) then
    FOnModifiedChange(Self);
end;

procedure TFb2MetadataPanel.ShowStatus(const S: UnicodeString;
  IsError: Boolean);
begin
  if FStatus = nil then
    Exit;
  FStatus.Caption := UTF8Encode(S);
  if IsError then
    FStatus.Font.Color := clRed
  else
    FStatus.Font.Color := clGray;
end;

{ ===================== Данные ===================== }

function TFValue(F: TTextField): UnicodeString;
begin
  if F = nil then
    Result := ''
  else
    Result := F.Value;
end;

function TFb2MetadataPanel.TitleInfo: TTitleInfo;
begin
  Result := nil;
  if (FBook = nil) or (FBook.Description = nil) then
    Exit;
  Result := FBook.Description.TitleInfo;
end;

function TFb2MetadataPanel.DocumentInfo: TDocumentInfo;
begin
  Result := nil;
  if (FBook = nil) or (FBook.Description = nil) then
    Exit;
  Result := FBook.Description.DocumentInfo;
end;

{ Перенести элементы Src в Dst (без освобождения объектов). }
procedure MoveAll(Src, Dst: TFb2ObjectList);
var
  Obj: TFb2Object;
begin
  while Src.Count > 0 do
  begin
    Obj := Src.Items[0];
    Src.Extract(Obj);
    Dst.Add(Obj);
  end;
end;

{ Подпись жанра: «Название (код)», если код известен. }
function GenreCaption(const Code: UnicodeString): UnicodeString;
var
  I: Integer;
begin
  for I := 0 to High(GENRES) do
    if GENRES[I].Code = Code then
      Exit(GENRES[I].Name + ' (' + Code + ')');
  Result := Code;
end;

procedure TFb2MetadataPanel.LoadFromFile(const AFileName: TFileName);
var
  Desc: TDescription;
  Bodies, Binaries: TFb2ObjectList;
begin
  FParser.LoadFile(UTF8ToString(AFileName));
  Desc := FParser.Parse;
  Bodies := FParser.ParseBodies;
  Binaries := FParser.ParseBinaries;

  FreeAndNil(FBook);
  FBook := TFictionBook.Create;
  try
    FBook.Description := Desc;
    Desc := nil;
    MoveAll(Bodies, FBook.Bodies);
    MoveAll(Binaries, FBook.Binaries);
  finally
    Desc.Free;
    Bodies.Free;
    Binaries.Free;
  end;

  FFileName := AFileName;
  SetModified(False);
  Refresh;
  ShowStatus('Загружено: ' + UTF8ToString(AFileName), False);
end;

procedure TFb2MetadataPanel.Revert;
begin
  if (FFileName <> '') and FileExists(UTF8ToSys(FFileName)) then
    LoadFromFile(FFileName)
  else
    ShowStatus('Нет файла для перечитывания', True);
end;

procedure TFb2MetadataPanel.Refresh;
var
  TI: TTitleInfo;
  DI: TDocumentInfo;
begin
  if FEditTitle = nil then
    Exit;
  FUpdating := True;
  try
    TI := TitleInfo;
    DI := DocumentInfo;

    if TI = nil then
      FEditTitle.Text := ''
    else
      FEditTitle.Text := UTF8Encode(TFValue(TI.BookTitle));
    if TI = nil then
      FEditDate.Text := ''
    else if TI.Date = nil then
      FEditDate.Text := ''
    else
      FEditDate.Text := UTF8Encode(TI.Date.Value);
    if TI = nil then
      FEditLang.Text := ''
    else
      FEditLang.Text := UTF8Encode(TI.Lang);
    if TI = nil then
      FEditKeywords.Text := ''
    else
      FEditKeywords.Text := UTF8Encode(TFValue(TI.Keywords));
    if TI = nil then
      FMemoAnnotation.Text := ''
    else
      FillAnnotation;

    if DI = nil then
    begin
      FEditId.Text := '';
      FEditVersion.Text := '';
    end
    else
    begin
      FEditId.Text := UTF8Encode(DI.Id);
      FEditVersion.Text := FloatToStr(DI.Version);
    end;

    FillAuthors;
    FillGenres;
    ShowCover;
  finally
    FUpdating := False;
  end;
end;

procedure TFb2MetadataPanel.ApplyToBook;
var
  TI: TTitleInfo;
  DI: TDocumentInfo;
  Lines: TTextList;
  P: TParagraph;
  I: Integer;
  V: Double;
begin
  if FUpdating or (FBook = nil) then
    Exit;
  TI := TitleInfo;
  DI := DocumentInfo;
  if TI = nil then
    Exit;

  { Название }
  if TI.BookTitle = nil then
    TI.BookTitle := TTextField.Create;
  TI.BookTitle.Value := UTF8ToString(FEditTitle.Text);

  { Дата }
  if UTF8ToString(FEditDate.Text) <> '' then
  begin
    if TI.Date = nil then
      TI.Date := TDateField.Create;
    TI.Date.Value := UTF8ToString(FEditDate.Text);
  end
  else
    FreeAndNil(TI.Date);

  { Язык }
  TI.Lang := UTF8ToString(FEditLang.Text);

  { Ключевые слова }
  if UTF8ToString(FEditKeywords.Text) <> '' then
  begin
    if TI.Keywords = nil then
      TI.Keywords := TTextField.Create;
    TI.Keywords.Value := UTF8ToString(FEditKeywords.Text);
  end
  else
    FreeAndNil(TI.Keywords);

  { Аннотация: один абзац на строку }
  Lines := TTextList.Create;
  try
    TextToLines(UTF8ToString(FMemoAnnotation.Text), Lines);
    if Lines.Count = 0 then
      FreeAndNil(TI.Annotation)
    else
    begin
      if TI.Annotation = nil then
        TI.Annotation := TAnnotation.Create;
      TI.Annotation.Items.Clear;
      for I := 0 to Lines.Count - 1 do
      begin
        P := TParagraph.Create;
        P.Content.Add(TStyleNode.Create(TEXT_NODE_NAME, Lines[I]));
        TI.Annotation.Items.Add(P);
      end;
    end;
  finally
    Lines.Free;
  end;

  { document-info }
  if DI <> nil then
  begin
    DI.Id := UTF8ToString(FEditId.Text);
    if TryStrToFloat(UTF8ToString(FEditVersion.Text), V) then
    begin
      DI.Version := V;
      DI.HasVersion := True;
    end;
  end;
end;

{ ===================== Заполнение списков и обложки ===================== }

procedure TFb2MetadataPanel.FillAuthors;
var
  TI: TTitleInfo;
  I, Sel: Integer;
begin
  if FListAuthors = nil then
    Exit;
  Sel := FListAuthors.ItemIndex;
  FListAuthors.Items.BeginUpdate;
  try
    FListAuthors.Items.Clear;
    TI := TitleInfo;
    if TI <> nil then
      for I := 0 to TI.Authors.Count - 1 do
        FListAuthors.Items.Add(UTF8Encode(AuthorText(TAuthor(TI.Authors[I]))));
  finally
    FListAuthors.Items.EndUpdate;
  end;
  if (Sel >= 0) and (Sel < FListAuthors.Items.Count) then
    FListAuthors.ItemIndex := Sel;
end;

procedure TFb2MetadataPanel.FillGenres;
var
  TI: TTitleInfo;
  I: Integer;
begin
  if FListGenres = nil then
    Exit;
  FListGenres.Items.BeginUpdate;
  try
    FListGenres.Items.Clear;
    TI := TitleInfo;
    if TI <> nil then
      for I := 0 to TI.Genres.Count - 1 do
        FListGenres.Items.Add(
          UTF8Encode(GenreCaption(TGenre(TI.Genres[I]).Value)));
  finally
    FListGenres.Items.EndUpdate;
  end;
end;

procedure TFb2MetadataPanel.FillAnnotation;
var
  TI: TTitleInfo;
begin
  if FMemoAnnotation = nil then
    Exit;
  TI := TitleInfo;
  if TI = nil then
    FMemoAnnotation.Text := ''
  else
    FMemoAnnotation.Text := UTF8Encode(AnnotationToText(TI.Annotation));
end;

{ Список жанров в выпадающем списке: «Название (код)». }
procedure TFb2MetadataPanel.FillGenreCombo;
var
  I: Integer;
begin
  if FComboGenre = nil then
    Exit;
  FComboGenre.Items.BeginUpdate;
  try
    FComboGenre.Items.Clear;
    FGenreCodes.Clear;
    for I := 0 to High(GENRES) do
    begin
      FComboGenre.Items.Add(UTF8Encode(GENRES[I].Name + ' (' +
        GENRES[I].Code + ')'));
      FGenreCodes.Add(GENRES[I].Code);
    end;
  finally
    FComboGenre.Items.EndUpdate;
  end;
end;

function TFb2MetadataPanel.AuthorFromFields: TAuthor;
begin
  Result := TAuthor.Create;
  Result.FirstName := UTF8ToString(FEditFirst.Text);
  Result.MiddleName := UTF8ToString(FEditMiddle.Text);
  Result.LastName := UTF8ToString(FEditLast.Text);
  Result.Nickname := UTF8ToString(FEditNick.Text);
end;

procedure TFb2MetadataPanel.ShowCover;
var
  TI: TTitleInfo;
  Id: UnicodeString;
  B: TBinary;
  Data: TBytes;
  MS: TMemoryStream;
  I: Integer;
begin
  if FImageCover = nil then
    Exit;
  FImageCover.Picture.Clear;
  FImageCover.Visible := False;

  TI := TitleInfo;
  if (TI = nil) or (TI.Coverpage = nil) or (TI.Coverpage.Images.Count = 0) then
    Exit;
  Id := TInlineImage(TI.Coverpage.Images[0]).Href;
  if (Id <> '') and (Id[1] = '#') then
    Id := Copy(Id, 2, MaxInt);
  if Id = '' then
    Exit;

  B := nil;
  if FBook <> nil then
    for I := 0 to FBook.Binaries.Count - 1 do
      if TBinary(FBook.Binaries[I]).Id = Id then
      begin
        B := TBinary(FBook.Binaries[I]);
        Break;
      end;
  if B = nil then
    Exit;

  Data := FParser.BinaryData(B);
  if Length(Data) = 0 then
    Exit;
  MS := TMemoryStream.Create;
  try
    MS.WriteBuffer(Data[0], Length(Data));
    MS.Position := 0;
    try
      FImageCover.Picture.LoadFromStream(MS);
      FImageCover.Visible := True;
    except
      { Формат не поддержан обработчиками LCL — просто не показываем. }
      FImageCover.Picture.Clear;
      FImageCover.Visible := False;
    end;
  finally
    MS.Free;
  end;
end;

{ ===================== Обработчики ===================== }

procedure TFb2MetadataPanel.Changed(Sender: TObject);
begin
  if FUpdating then
    Exit;
  ApplyToBook;
  SetModified(True);
end;

procedure TFb2MetadataPanel.AuthorSelect(Sender: TObject);
var
  TI: TTitleInfo;
  Idx: Integer;
  A: TAuthor;
begin
  if FUpdating then
    Exit;
  TI := TitleInfo;
  if TI = nil then
    Exit;
  Idx := FListAuthors.ItemIndex;
  if (Idx < 0) or (Idx >= TI.Authors.Count) then
    Exit;
  A := TAuthor(TI.Authors[Idx]);
  FUpdating := True;
  try
    FEditFirst.Text := UTF8Encode(A.FirstName);
    FEditMiddle.Text := UTF8Encode(A.MiddleName);
    FEditLast.Text := UTF8Encode(A.LastName);
    FEditNick.Text := UTF8Encode(A.Nickname);
  finally
    FUpdating := False;
  end;
end;

procedure TFb2MetadataPanel.AuthorAdd(Sender: TObject);
var
  TI: TTitleInfo;
  A: TAuthor;
begin
  TI := TitleInfo;
  if TI = nil then
    Exit;
  A := AuthorFromFields;
  if (A.FirstName = '') and (A.MiddleName = '') and (A.LastName = '') and
    (A.Nickname = '') then
  begin
    A.Free;
    ShowStatus('Укажите имя, фамилию или псевдоним автора', True);
    Exit;
  end;
  TI.Authors.Add(A);
  FillAuthors;
  FListAuthors.ItemIndex := TI.Authors.Count - 1;
  AuthorSelect(nil);
  SetModified(True);
  ShowStatus('Автор добавлен', False);
end;

procedure TFb2MetadataPanel.AuthorSet(Sender: TObject);
var
  TI: TTitleInfo;
  Idx: Integer;
  Old, A: TAuthor;
begin
  TI := TitleInfo;
  if TI = nil then
    Exit;
  Idx := FListAuthors.ItemIndex;
  if (Idx < 0) or (Idx >= TI.Authors.Count) then
  begin
    ShowStatus('Выберите автора в списке', True);
    Exit;
  end;
  A := AuthorFromFields;
  Old := TAuthor(TI.Authors.Items[Idx]);
  TI.Authors.Extract(Old);
  Old.Free;
  TI.Authors.Insert(Idx, A);
  FillAuthors;
  FListAuthors.ItemIndex := Idx;
  SetModified(True);
  ShowStatus('Автор заменён', False);
end;

procedure TFb2MetadataPanel.AuthorDel(Sender: TObject);
var
  TI: TTitleInfo;
  Idx: Integer;
  Old: TAuthor;
begin
  TI := TitleInfo;
  if TI = nil then
    Exit;
  Idx := FListAuthors.ItemIndex;
  if (Idx < 0) or (Idx >= TI.Authors.Count) then
  begin
    ShowStatus('Выберите автора в списке', True);
    Exit;
  end;
  Old := TAuthor(TI.Authors.Items[Idx]);
  TI.Authors.Extract(Old);
  Old.Free;
  FillAuthors;
  SetModified(True);
  ShowStatus('Автор удалён', False);
end;

procedure TFb2MetadataPanel.GenreAdd(Sender: TObject);
var
  TI: TTitleInfo;
  Code, ByName: UnicodeString;
  G: TGenre;
begin
  TI := TitleInfo;
  if TI = nil then
    Exit;
  if FComboGenre.ItemIndex >= 0 then
    Code := FGenreCodes[FComboGenre.ItemIndex]
  else
    Code := UTF8ToString(FComboGenre.Text);
  Code := Trim(Code);
  if Code = '' then
  begin
    ShowStatus('Выберите жанр из списка или введите код', True);
    Exit;
  end;
  if not GenreCodeExists(Code) then
  begin
    { возможно, введено название жанра }
    ByName := GenreCodeByName(Code);
    if ByName <> '' then
      Code := ByName;
  end;
  G := TGenre.Create;
  G.Value := Code;
  TI.Genres.Add(G);
  FillGenres;
  SetModified(True);
  ShowStatus('Жанр добавлен: ' + Code, False);
end;

procedure TFb2MetadataPanel.GenreDel(Sender: TObject);
var
  TI: TTitleInfo;
  Idx: Integer;
  Old: TGenre;
begin
  TI := TitleInfo;
  if TI = nil then
    Exit;
  Idx := FListGenres.ItemIndex;
  if (Idx < 0) or (Idx >= TI.Genres.Count) then
  begin
    ShowStatus('Выберите жанр в списке', True);
    Exit;
  end;
  Old := TGenre(TI.Genres.Items[Idx]);
  TI.Genres.Extract(Old);
  Old.Free;
  FillGenres;
  SetModified(True);
  ShowStatus('Жанр удалён', False);
end;

procedure TFb2MetadataPanel.CoverClear(Sender: TObject);
var
  TI: TTitleInfo;
begin
  TI := TitleInfo;
  if (TI = nil) or (TI.Coverpage = nil) then
  begin
    ShowStatus('Обложки нет', True);
    Exit;
  end;
  FreeAndNil(TI.Coverpage);
  ShowCover;
  SetModified(True);
  ShowStatus('Обложка удалена (binary остаётся в файле)', False);
end;

procedure TFb2MetadataPanel.OpenClick(Sender: TObject);
var
  D: TOpenDialog;
begin
  D := TOpenDialog.Create(Self);
  try
    D.Filter := 'FictionBook (*.fb2)|*.fb2|Все файлы (*.*)|*.*';
    D.Options := D.Options + [ofFileMustExist];
    if D.Execute then
      LoadFromFile(D.FileName);
  finally
    D.Free;
  end;
end;

procedure TFb2MetadataPanel.SaveClick(Sender: TObject);
begin
  SaveToFile('');
end;

procedure TFb2MetadataPanel.SaveAsClick(Sender: TObject);
var
  D: TSaveDialog;
begin
  if FBook = nil then
  begin
    ShowStatus('Нет загруженной книги', True);
    Exit;
  end;
  D := TSaveDialog.Create(Self);
  try
    D.Filter := 'FictionBook (*.fb2)|*.fb2|Все файлы (*.*)|*.*';
    D.DefaultExt := 'fb2';
    if FFileName <> '' then
      D.FileName := FFileName;
    if D.Execute then
      SaveToFile(D.FileName);
  finally
    D.Free;
  end;
end;

procedure TFb2MetadataPanel.RevertClick(Sender: TObject);
begin
  Revert;
end;

procedure TFb2MetadataPanel.SaveToFile(const AFileName: TFileName);
var
  Target: TFileName;
  W: TFb2Writer;
begin
  if FBook = nil then
  begin
    ShowStatus('Нет загруженной книги', True);
    Exit;
  end;
  if AFileName <> '' then
    Target := AFileName
  else
    Target := FFileName;
  if Target = '' then
  begin
    ShowStatus('Не задан файл для сохранения', True);
    Exit;
  end;
  { ApplyToBook здесь не вызывается: значения полей переносятся в структуру
    сразу при их изменении (Changed), поэтому структура уже актуальна — и
    правки, сделанные приложением напрямую в Book, не затираются. }
  W := TFb2Writer.Create;
  try
    W.Write(FBook, UTF8ToString(Target));
  finally
    W.Free;
  end;
  FFileName := Target;
  SetModified(False);
  ShowStatus('Сохранено: ' + UTF8ToString(Target), False);
end;

end.
