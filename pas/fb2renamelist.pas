unit fb2renamelist;
{ Предпросмотр переименования FB2 «было → станет» по шаблону.

  Компонент-обёртка над fb2_renamer.pas / fb2_group_renamer.pas: выбирается
  каталог с книгами и шаблон имени (и, при желании, шаблон подкаталога), после
  чего в таблице показывается, что с чем станется, — но на диске ничего не
  трогается, пока не нажата кнопка «Переименовать».

  Предпросмотр строится теми же объектами TFB2Renamer, что и настоящее
  переименование (fb2_group_renamer.pas делает ровно это в цикле), поэтому
  показанное имя — это в точности то, что получится на диске.

  В шаблоне доступны параметры (см. fb2_renamer.pas; допустимы обе формы
  записи — $NAME и с фигурными скобками):
      $AL $AF $AM — фамилия/имя/отчество автора (ВЕРХНИЙ регистр);
      $Al $Af $Am — они же с заглавной буквы;
      $al $af $am — они же в нижнем регистре;
      $F $M       — первая буква имени/отчества + '.';
      $T $t $Tt   — заголовок: ВЕРХНИЙ/нижний/как в файле;
      $S $SN      — серия и номер в серии.

  Кодировки: строки LCL — UTF-8, поэтому при вводе/выводе выполняется явная
  конвертация (UTF8ToString/UTF8Encode), а пути — через UTF8ToSys.

  Пример:
      R := TFb2RenameList.Create(Self);
      R.Parent := Self;   R.Align := alClient;
      R.StartDir := 'C:\\Books';
      R.Template := '$Al - $Tt';
      R.BuildPreview;      ( в таблице: было → станет )
      R.RenameAll;         ( выполнить )

  Требует LCL и библиотечных модулей fb2_renamer/fb2_group_renamer/fb2_files.
  GUI-модуль (в make-сборку библиотеки не входит). }

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Classes, SysUtils, Controls, StdCtrls, ExtCtrls, ComCtrls, Graphics, Dialogs,
  LazUTF8,
  fb2_renamer, fb2_group_renamer, fb2_files;

type
  { Результат предпросмотра по одному файлу. }
  TFb2RenameEntry = class
  private
    FOldPath: UnicodeString;
    FNewName: UnicodeString;
    FNewPath: UnicodeString;
    FError: UnicodeString;
    FRenamed: Boolean;
    FRenamer: TFB2Renamer;
  public
    destructor Destroy; override;
    { Полный путь исходного файла. }
    property OldPath: UnicodeString read FOldPath;
    { Новое имя файла (без каталога). }
    property NewName: UnicodeString read FNewName;
    { Полный путь каталога, куда файл переедет. }
    property NewPath: UnicodeString read FNewPath;
    { Причина, по которой переименование невозможно (пусто — можно). }
    property Error: UnicodeString read FError;
    { Файл уже переименован в этой сессии. }
    property Renamed: Boolean read FRenamed;
    { Объект-переименователь (владелец — запись); может быть nil при ошибке. }
    property Renamer: TFB2Renamer read FRenamer;
  end;

  { Список переименования FB2: предпросмотр «было → станет» и выполнение. }
  TFb2RenameList = class(TCustomPanel)
  private
    FStartDir: TFileName;
    FTemplate: UnicodeString;
    FOutDir: UnicodeString;
    FRecursive: Boolean;
    FEntries: TList;                { TFb2RenameEntry }
    FOnRenamed: TNotifyEvent;

    { --- управление ------------------------------------------------- }
    FTopPanel: TPanel;
    FLblDir, FLblTemplate, FLblOutDir: TLabel;
    FEditDir, FEditTemplate, FEditOutDir: TEdit;
    FBtnBrowse: TButton;
    FCheckRecursive: TCheckBox;
    FBtnPreview, FBtnRename: TButton;
    FList: TListView;
    FStatus: TLabel;

    { --- построение интерфейса -------------------------------------- }
    procedure BuildUi;
    function NewLabel(const ACaption: string; ALeft, ATop: Integer): TLabel;
    function NewEdit(ALeft, ATop, AWidth: Integer): TEdit;
    function NewButton(const ACaption: string; ALeft, ATop,
      AWidth: Integer): TButton;
    procedure LayoutUi;

    { --- свойства ---------------------------------------------------- }
    function GetTemplate: string;
    procedure SetTemplate(const Value: string);
    function GetOutDir: string;
    procedure SetOutDir(const Value: string);
    procedure SetStartDir(const Value: TFileName);
    procedure SetRecursive(const Value: Boolean);

    { --- обработчики ------------------------------------------------- }
    procedure BrowseClick(Sender: TObject);
    procedure PreviewClick(Sender: TObject);
    procedure RenameClick(Sender: TObject);
    procedure RecursiveClick(Sender: TObject);

    { --- данные ------------------------------------------------------ }
    procedure ClearEntries;
    procedure FillList;
    procedure ShowStatus(const S: UnicodeString; IsError: Boolean);
  protected
    procedure Resize; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    { Построить предпросмотр по StartDir/Template/OutDir/Recursive.
      Возвращает число файлов, которые удастся переименовать. }
    function BuildPreview: Integer;
    { Выполнить переименование всех распознанных файлов.
      Возвращает число успешно переименованных. }
    function RenameAll: Integer;

    { Число строк предпросмотра. }
    function PreviewCount: Integer;
    { Число строк с ошибками (переименовать нельзя). }
    function PreviewErrors: Integer;
    { Запись предпросмотра по индексу (nil — вне диапазона). }
    function EntryAt(Idx: Integer): TFb2RenameEntry;
  published
    { Каталог поиска FB2 (установка не запускает предпросмотр — вызовите
      BuildPreview). }
    property StartDir: TFileName read FStartDir write SetStartDir;
    { Шаблон нового имени, например: $Al - $Tt. }
    property Template: string read GetTemplate write SetTemplate;
    { Шаблон подкаталога результата (пусто — рядом с исходным файлом). }
    property OutDir: string read GetOutDir write SetOutDir;
    { Обходить подкаталоги. }
    property Recursive: Boolean read FRecursive write SetRecursive default False;
    { Событие: переименование выполнено (после RenameAll). }
    property OnRenamed: TNotifyEvent read FOnRenamed write FOnRenamed;
  end;

implementation


{ ===================== Помощники ===================== }

destructor TFb2RenameEntry.Destroy;
begin
  FreeAndNil(FRenamer);
  inherited Destroy;
end;

{ ===================== Создание ===================== }

constructor TFb2RenameList.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FEntries := TList.Create;
  FRecursive := False;
  BevelOuter := bvNone;
  BuildUi;
  LayoutUi;
  ShowStatus('', False);
end;

destructor TFb2RenameList.Destroy;
begin
  ClearEntries;
  FreeAndNil(FEntries);
  inherited Destroy;
end;

function TFb2RenameList.NewLabel(const ACaption: string;
  ALeft, ATop: Integer): TLabel;
begin
  Result := TLabel.Create(Self);
  Result.Parent := FTopPanel;
  Result.Caption := ACaption;
  Result.Left := ALeft;
  Result.Top := ATop;
  Result.AutoSize := True;
end;

function TFb2RenameList.NewEdit(ALeft, ATop, AWidth: Integer): TEdit;
begin
  Result := TEdit.Create(Self);
  Result.Parent := FTopPanel;
  Result.Left := ALeft;
  Result.Top := ATop;
  Result.Width := AWidth;
end;

function TFb2RenameList.NewButton(const ACaption: string;
  ALeft, ATop, AWidth: Integer): TButton;
begin
  Result := TButton.Create(Self);
  Result.Parent := FTopPanel;
  Result.Caption := ACaption;
  Result.Left := ALeft;
  Result.Top := ATop;
  Result.Width := AWidth;
end;

{ ===================== Интерфейс ===================== }

procedure TFb2RenameList.BuildUi;
var
  Col: TListColumn;
begin
  { --- строка состояния (снизу) --- }
  FStatus := TLabel.Create(Self);
  FStatus.Parent := Self;
  FStatus.Align := alBottom;
  FStatus.AutoSize := False;
  FStatus.Height := 18;
  FStatus.Caption := '';

  { --- таблица предпросмотра (заполняет всё остальное) --- }
  FList := TListView.Create(Self);
  FList.Parent := Self;
  FList.Align := alClient;
  FList.ViewStyle := vsReport;
  FList.ReadOnly := True;
  FList.RowSelect := True;
  FList.GridLines := True;
  FList.HideSelection := False;

  Col := FList.Columns.Add;
  Col.Caption := UTF8Encode('Было');
  Col.Width := 300;
  Col := FList.Columns.Add;
  Col.Caption := UTF8Encode('Станет');
  Col.Width := 300;
  Col := FList.Columns.Add;
  Col.Caption := UTF8Encode('Примечание');
  Col.Width := 180;

  { --- панель настроек (сверху) --- }
  FTopPanel := TPanel.Create(Self);
  FTopPanel.Parent := Self;
  FTopPanel.Align := alTop;
  FTopPanel.Height := 130;
  FTopPanel.BevelOuter := bvNone;

  FLblDir := NewLabel('Каталог:', 8, 11);
  FEditDir := NewEdit(110, 8, 300);
  FBtnBrowse := NewButton('Обзор…', 418, 6, 90);
  FBtnBrowse.OnClick := @BrowseClick;

  FLblTemplate := NewLabel('Шаблон имени:', 8, 41);
  FEditTemplate := NewEdit(110, 38, 398);
  FEditTemplate.Hint := 'например: ${Al} - ${Tt}';
  FEditTemplate.ShowHint := True;

  FLblOutDir := NewLabel('Подкаталог:', 8, 71);
  FEditOutDir := NewEdit(110, 68, 220);
  FEditOutDir.Hint := 'необязательно, например: ${Al}';
  FEditOutDir.ShowHint := True;

  FCheckRecursive := TCheckBox.Create(Self);
  FCheckRecursive.Parent := FTopPanel;
  FCheckRecursive.Left := 340;
  FCheckRecursive.Top := 69;
  FCheckRecursive.Width := 168;
  FCheckRecursive.Caption := 'Рекурсивно';
  FCheckRecursive.OnClick := @RecursiveClick;

  FBtnPreview := NewButton('Предпросмотр', 110, 98, 110);
  FBtnPreview.OnClick := @PreviewClick;
  FBtnRename := NewButton('Переименовать', 226, 98, 120);
  FBtnRename.OnClick := @RenameClick;
end;

{ Ширины «резиновых» полей — по ширине панели. }
procedure TFb2RenameList.LayoutUi;
var
  W: Integer;
begin
  if (FTopPanel = nil) or (FList = nil) then
    Exit;
  W := ClientWidth;
  if W < 300 then
    W := 300;

  FBtnBrowse.Left := W - FBtnBrowse.Width - 8;
  FEditDir.Width := FBtnBrowse.Left - FEditDir.Left - 8;
  if FEditDir.Width < 60 then
    FEditDir.Width := 60;

  FEditTemplate.Width := W - FEditTemplate.Left - 12;
  if FEditTemplate.Width < 60 then
    FEditTemplate.Width := 60;

  FBtnRename.Left := W - FBtnRename.Width - 8;
  FBtnPreview.Left := FBtnRename.Left - FBtnPreview.Width - 6;
  if FBtnPreview.Left < 110 then
    FBtnPreview.Left := 110;
end;

procedure TFb2RenameList.Resize;
begin
  inherited Resize;
  LayoutUi;
end;

{ ===================== Свойства ===================== }

function TFb2RenameList.GetTemplate: string;
begin
  Result := UTF8Encode(FTemplate);
end;

procedure TFb2RenameList.SetTemplate(const Value: string);
begin
  FTemplate := UTF8ToString(Value);
end;

function TFb2RenameList.GetOutDir: string;
begin
  Result := UTF8Encode(FOutDir);
end;

procedure TFb2RenameList.SetOutDir(const Value: string);
begin
  FOutDir := UTF8ToString(Value);
end;

procedure TFb2RenameList.SetStartDir(const Value: TFileName);
begin
  if FStartDir = Value then
    Exit;
  FStartDir := Value;
  if FEditDir <> nil then
    FEditDir.Text := Value;
end;

procedure TFb2RenameList.SetRecursive(const Value: Boolean);
begin
  if FRecursive = Value then
    Exit;
  FRecursive := Value;
  if FCheckRecursive <> nil then
    FCheckRecursive.Checked := Value;
end;

{ ===================== Данные ===================== }

procedure TFb2RenameList.ClearEntries;
var
  I: Integer;
begin
  for I := 0 to FEntries.Count - 1 do
    TFb2RenameEntry(FEntries[I]).Free;
  FEntries.Clear;
end;

function TFb2RenameList.PreviewCount: Integer;
begin
  Result := FEntries.Count;
end;

function TFb2RenameList.PreviewErrors: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to FEntries.Count - 1 do
    if TFb2RenameEntry(FEntries[I]).Error <> '' then
      Inc(Result);
end;

function TFb2RenameList.EntryAt(Idx: Integer): TFb2RenameEntry;
begin
  if (Idx >= 0) and (Idx < FEntries.Count) then
    Result := TFb2RenameEntry(FEntries[Idx])
  else
    Result := nil;
end;

procedure TFb2RenameList.ShowStatus(const S: UnicodeString; IsError: Boolean);
begin
  if FStatus = nil then
    Exit;
  FStatus.Caption := UTF8Encode(S);
  if IsError then
    FStatus.Font.Color := clRed
  else
    FStatus.Font.Color := clWindowText;
end;

{ Заполнить таблицу: «было» → «станет» и примечание. }
procedure TFb2RenameList.FillList;
var
  I: Integer;
  E: TFb2RenameEntry;
  It: TListItem;
  NewRel: UnicodeString;
begin
  FList.Items.BeginUpdate;
  try
    FList.Items.Clear;
    for I := 0 to FEntries.Count - 1 do
    begin
      E := TFb2RenameEntry(FEntries[I]);
      It := FList.Items.Add;
      It.Data := Pointer(PtrInt(I));
      It.Caption := UTF8Encode(RelPath(UTF8ToString(FStartDir), E.OldPath));
      if E.Error = '' then
      begin
        NewRel := RelPath(UTF8ToString(FStartDir),
          IncludeTrailingPathDelimiter(E.NewPath) + E.NewName);
        It.SubItems.Add(UTF8Encode(NewRel));
      end
      else
        It.SubItems.Add('');
      It.SubItems.Add(UTF8Encode(E.Error));
    end;
  finally
    FList.Items.EndUpdate;
  end;
end;

{ ===================== Предпросмотр и переименование ===================== }

function TFb2RenameList.BuildPreview: Integer;
var
  Files: TStringList;
  I, Ok, Err: Integer;
  E: TFb2RenameEntry;
begin
  Result := 0;
  ClearEntries;
  if FList <> nil then
    FList.Items.Clear;

  if FStartDir = '' then
  begin
    ShowStatus('Не задан каталог с книгами', True);
    Exit;
  end;
  if not DirectoryExists(UTF8ToSys(FStartDir)) then
  begin
    ShowStatus('Каталог не найден: ' + UTF8ToString(FStartDir), True);
    Exit;
  end;
  if Trim(FTemplate) = '' then
  begin
    ShowStatus('Не задан шаблон имени', True);
    Exit;
  end;

  { тот же набор файлов, что обходит TFB2GroupRenamer.RenameAll }
  if FRecursive then
    Files := ListFilesRecursive(UTF8ToString(FStartDir), FB2_MASK)
  else
    Files := ListFiles(UTF8ToString(FStartDir), FB2_MASK);
  Ok := 0;
  Err := 0;
  try
    for I := 0 to Files.Count - 1 do
    begin
      E := TFb2RenameEntry.Create;
      E.FOldPath := Files[I];
      try
        E.FRenamer := TFB2Renamer.Create(E.FOldPath, FTemplate, FOutDir, False);
        E.FNewName := E.FRenamer.NewFilename;
        E.FNewPath := E.FRenamer.NewPath;
        Inc(Ok);
      except
        on Ex: Exception do
        begin
          E.FError := Ex.Message;
          Inc(Err);
        end;
      end;
      FEntries.Add(E);
    end;
  finally
    Files.Free;
  end;

  FillList;
  ShowStatus('Найдено ' + IntToStr(FEntries.Count) +
    ': готовы к переименованию ' + IntToStr(Ok) + ', с ошибками ' + IntToStr(Err),
    Err > 0);
  Result := Ok;
end;

function TFb2RenameList.RenameAll: Integer;
var
  I, Ok, Fail: Integer;
  E: TFb2RenameEntry;
  It: TListItem;
begin
  Result := 0;
  if FEntries.Count = 0 then
  begin
    ShowStatus('Нет предпросмотра — нажмите «Предпросмотр»', True);
    Exit;
  end;

  Ok := 0;
  Fail := 0;
  FList.Items.BeginUpdate;
  try
    for I := 0 to FEntries.Count - 1 do
    begin
      E := TFb2RenameEntry(FEntries[I]);
      It := FList.Items[I];
      if E.Renamed then
        Continue;
      if (E.Error <> '') or (E.Renamer = nil) then
      begin
        Inc(Fail);
        Continue;
      end;
      try
        E.Renamer.Rename;
        E.FRenamed := True;
        Inc(Ok);
        It.SubItems[1] := UTF8Encode('переименован');
      except
        on Ex: Exception do
        begin
          E.FError := Ex.Message;
          It.SubItems[1] := UTF8Encode(Ex.Message);
          Inc(Fail);
        end;
      end;
    end;
  finally
    FList.Items.EndUpdate;
  end;

  ShowStatus('Переименовано ' + IntToStr(Ok) + ' из ' + IntToStr(FEntries.Count) +
    ', ошибок ' + IntToStr(Fail), Fail > 0);
  if Assigned(FOnRenamed) then
    FOnRenamed(Self);
  Result := Ok;
end;

{ ===================== Обработчики ===================== }

procedure TFb2RenameList.BrowseClick(Sender: TObject);
var
  D: TSelectDirectoryDialog;
begin
  D := TSelectDirectoryDialog.Create(Self);
  try
    if FStartDir <> '' then
      D.InitialDir := FStartDir;
    if D.Execute then
      SetStartDir(D.FileName);
  finally
    D.Free;
  end;
end;

procedure TFb2RenameList.PreviewClick(Sender: TObject);
begin
  { поля могли измениться — синхронизируем значения свойств }
  if FEditDir <> nil then
    SetStartDir(FEditDir.Text);
  if FEditTemplate <> nil then
    SetTemplate(FEditTemplate.Text);
  if FEditOutDir <> nil then
    SetOutDir(FEditOutDir.Text);
  BuildPreview;
end;

procedure TFb2RenameList.RenameClick(Sender: TObject);
begin
  RenameAll;
end;

procedure TFb2RenameList.RecursiveClick(Sender: TObject);
begin
  SetRecursive(FCheckRecursive.Checked);
end;

end.

