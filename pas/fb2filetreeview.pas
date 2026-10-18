unit fb2filetreeview;
{ Дерево файловой системы, показывающее только FB2-файлы.

  Наследник TShellTreeView (unit ShellCtrls, входит в LCL): в дереве видны
  каталоги и файлы, подходящие под маску FileMask (по умолчанию '*.fb2';
  несколько шаблонов — через ';', например '*.fb2;*.fb2.zip').

  Фильтрация выполняется через штатное событие TShellTreeView.OnAddItem —
  другой точки расширения у него нет (DoAddItem/PopulateTreeNodeWithFiles
  не виртуальны). Компонент сам подписывается на это событие, поэтому
  пользовательский обработчик OnAddItem задаётся как обычно: он вызывается
  ПОСЛЕ проверки по маске и может дополнительно запретить элемент
  (CanAdd := False).

  Каталоги показываются всегда (иначе до файлов не добраться); скрытые
  элементы — по унаследованному ObjectTypes. Если HideEmptyDirs = True,
  каталоги без подходящих файлов (ни прямо, ни в подкаталогах) не показываются
  (результаты сканирования кэшируются — см. ClearDirCache). Объём этого
  сканирования ограничен свойством HideEmptyDirsScanLimit: на гигантских
  деревьях (например, Root = 'C:\') бюджет исчерпывается, и каталоги начинают
  показываться все — так дерево не «зависает».

  Метод SelectFile раскрывает дерево до указанного файла и выделяет его
  (удобно, например, чтобы открыть текущую книгу при старте приложения).

  Свойство Viewer связывает дерево с читалкой TFb2Viewer: при AutoOpen = True
  (по умолчанию) выбранная книга открывается по двойному щелчку мышью или по
  Enter. Одиночное выделение ничего не открывает; открыть можно и вручную —
  методом OpenSelectedFile.

  Пример:
      T := TFb2FileTreeView.Create(Self);
      T.Parent := Self;   T.Align := alClient;
      T.Root := 'C:\\Books';          (или '' — вся файловая система)
      T.FileMask := '*.fb2';
      T.Viewer := Viewer;             (открытие по двойному щелчку / Enter)
      T.OnChange := @FileTreeChanged;
      ...
      if T.SelectedFilePath <> '' then ...   (выбранный файл)

  Требует LCL (unit ShellCtrls). GUI-модуль (в make-сборку библиотеки не
  входит). }

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Classes, SysUtils, ComCtrls, ShellCtrls, Masks, LazFileUtils, LCLType,
  fb2viewer;

const
  { Значение по умолчанию для TFb2FileTreeView.HideEmptyDirsScanLimit. }
  DefaultHideEmptyDirsScanLimit = 100000;

type
  { Дерево файловой системы с фильтром по маске (по умолчанию — только FB2). }
  TFb2FileTreeView = class(TShellTreeView)
  private
    FFileMask: string;
    FMatcher: TMaskList;
    FHideEmptyDirs: Boolean;
    FHideEmptyDirsScanLimit: Integer;
    FScanBudget: Integer;
    FDirWithMatches: TStringList;
    FDirWithoutMatches: TStringList;
    FUserAddItem: TAddItemEvent;
    FViewer: TFb2Viewer;
    FAutoOpen: Boolean;
    procedure SetFileMask(const Value: string);
    procedure SetHideEmptyDirs(const Value: Boolean);
    procedure SetHideEmptyDirsScanLimit(const Value: Integer);
    procedure SetUserAddItem(const Value: TAddItemEvent);
    procedure SetViewer(const Value: TFb2Viewer);
    procedure SetAutoOpen(const Value: Boolean);
    procedure RebuildMatcher;
    procedure ResetScanBudget;
    procedure RefreshTree;
    procedure FilterAddItem(Sender: TObject; const ABasePath: string;
      const AFileInfo: TSearchRec; var CanAdd: Boolean);
    function DirHasMatches(const ADir: string; ADepth: Integer): Boolean;
    function GetSelectedFilePath: TFileName;
  protected
    { Открыть книгу в связанном Viewer по двойному щелчку (если AutoOpen). }
    procedure DblClick; override;
    { То же по Enter (если AutoOpen). Пользовательский OnKeyDown вызывается
      первым и может «съесть» клавишу (Key := 0) — тогда открытия не будет. }
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    { Обнулить FViewer, если связанная читалка удаляется (иначе остался бы
      «висячий» указатель). }
    procedure Notification(AComponent: TComponent; Operation: TOperation);
      override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    { Раскрыть дерево до AFileName и выделить его (для каталога — просто
      перейти в него). False — путь пуст, не существует или файл отсеян
      маской FileMask. }
    function SelectFile(const AFileName: TFileName): Boolean;
    { Забыть результаты сканирования каталогов (нужны для HideEmptyDirs):
      вызывайте после изменения содержимого каталогов на диске. }
    procedure ClearDirCache;
    { Открыть выделенный файл в связанном Viewer. False — Viewer не задан,
      ничего не выделено или выделен каталог. }
    function OpenSelectedFile: Boolean;
    { Полный путь выбранного файла ('' — выбран каталог или ничего не выбрано). }
    property SelectedFilePath: TFileName read GetSelectedFilePath;
  published
    { Показывать/скрывать дерево. Унаследовано от TShellTreeView (published),
      переопубликовано явно, чтобы свойство гарантированно было доступно в
      инспекторе объектов и сохранялось в .lfm. }
    property Visible;
    { Маска файлов; несколько шаблонов — через ';'. По умолчанию '*.fb2'. }
    property FileMask: string read FFileMask write SetFileMask;
    { Не показывать каталоги, в которых нет ни одного подходящего файла — ни
      прямо, ни в подкаталогах. По умолчанию False. }
    property HideEmptyDirs: Boolean read FHideEmptyDirs write SetHideEmptyDirs default False;
    { Сколько элементов разрешено просмотреть при проверке «в каталоге есть
      подходящие файлы» (для HideEmptyDirs). Защита от «зависания» на
      гигантских деревьях (например, при Root = 'C:\'): когда бюджет исчерпан,
      каталоги считаются непустыми — дерево ведёт себя как при
      HideEmptyDirs = False, пока не будет вызван ClearDirCache.
      0 — без ограничения. По умолчанию 100000. }
    property HideEmptyDirsScanLimit: Integer
      read FHideEmptyDirsScanLimit write SetHideEmptyDirsScanLimit
      default DefaultHideEmptyDirsScanLimit;
    { Читалка, в которой открываются книги. nil (по умолчанию) — дерево только
      показывает файлы. }
    property Viewer: TFb2Viewer read FViewer write SetViewer;
    { Открывать выбранную книгу в Viewer по двойному щелчку или Enter.
      По умолчанию True; одиночное выделение книгу не открывает. }
    property AutoOpen: Boolean read FAutoOpen write SetAutoOpen default True;
    { Пользовательский обработчик добавления элемента: вызывается после
      фильтра по маске (можно дополнительно установить CanAdd := False). }
    property OnAddItem: TAddItemEvent read FUserAddItem write SetUserAddItem;
  end;

implementation

const
  { Ограничение глубины рекурсии в DirHasMatches — защита от бесконечного
    обхода по символическим ссылкам и точкам монтирования. }
  MaxDirDepth = 64;

constructor TFb2FileTreeView.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FAutoOpen := True;
  { По умолчанию TShellTreeView показывает ТОЛЬКО каталоги (ObjectTypes =
    [otFolders]) — включаем и файлы. }
  ObjectTypes := [otFolders, otNonFolders];
  { Кэш «в каталоге есть / нет подходящие файлы» (используется при
    HideEmptyDirs): Sorted + CaseSensitive = False дают регистронезависимый
    поиск (пути Windows регистронезависимы). }
  FDirWithMatches := TStringList.Create;
  FDirWithMatches.Sorted := True;
  FDirWithMatches.CaseSensitive := False;
  FDirWithoutMatches := TStringList.Create;
  FDirWithoutMatches.Sorted := True;
  FDirWithoutMatches.CaseSensitive := False;
  FFileMask := '*.fb2';
  RebuildMatcher;
  FHideEmptyDirsScanLimit := DefaultHideEmptyDirsScanLimit;
  ResetScanBudget;
  { Штатное OnAddItem базового класса — наш фильтр; пользовательский
    обработчик хранится отдельно (FUserAddItem) и вызывается из фильтра.
    Квалификатор типа нужен потому, что OnAddItem переобъявлен ниже. }
  TShellTreeView(Self).OnAddItem := @FilterAddItem;
end;

destructor TFb2FileTreeView.Destroy;
begin
  FreeAndNil(FMatcher);
  FreeAndNil(FDirWithMatches);
  FreeAndNil(FDirWithoutMatches);
  inherited Destroy;
end;

procedure TFb2FileTreeView.RefreshTree;
begin
  if csLoading in ComponentState then
    Exit;
  { Перестроить дерево (так же, как это делает SetObjectTypes). }
  BeginUpdate;
  try
    UpdateView;
  finally
    EndUpdate;
  end;
end;

procedure TFb2FileTreeView.ClearDirCache;
begin
  FDirWithMatches.Clear;
  FDirWithoutMatches.Clear;
  { Новый проход — бюджет сканирования снова полный. }
  ResetScanBudget;
end;

procedure TFb2FileTreeView.ResetScanBudget;
begin
  if FHideEmptyDirsScanLimit <= 0 then
    FScanBudget := -1              { 0 — без ограничения }
  else
    FScanBudget := FHideEmptyDirsScanLimit;
end;

procedure TFb2FileTreeView.RebuildMatcher;
begin
  FreeAndNil(FMatcher);
  if Trim(FFileMask) <> '' then
    FMatcher := TMaskList.Create(FFileMask, ';', False);
end;

procedure TFb2FileTreeView.SetFileMask(const Value: string);
begin
  if FFileMask = Value then
    Exit;
  FFileMask := Value;
  RebuildMatcher;
  { Маска изменилась — прежние результаты сканирования каталогов не годятся. }
  ClearDirCache;
  RefreshTree;
end;

procedure TFb2FileTreeView.SetHideEmptyDirs(const Value: Boolean);
begin
  if FHideEmptyDirs = Value then
    Exit;
  FHideEmptyDirs := Value;
  ClearDirCache;
  RefreshTree;
end;

procedure TFb2FileTreeView.SetHideEmptyDirsScanLimit(const Value: Integer);
begin
  if FHideEmptyDirsScanLimit = Value then
    Exit;
  FHideEmptyDirsScanLimit := Value;
  ClearDirCache;                   { сбрасывает и бюджет сканирования }
  RefreshTree;
end;

procedure TFb2FileTreeView.SetUserAddItem(const Value: TAddItemEvent);
begin
  FUserAddItem := Value;
end;

procedure TFb2FileTreeView.SetViewer(const Value: TFb2Viewer);
begin
  if FViewer = Value then
    Exit;
  if FViewer <> nil then
    FViewer.RemoveFreeNotification(Self);
  FViewer := Value;
  if FViewer <> nil then
    FViewer.FreeNotification(Self);
end;

procedure TFb2FileTreeView.Notification(AComponent: TComponent;
  Operation: TOperation);
begin
  inherited Notification(AComponent, Operation);
  if (Operation = opRemove) and (AComponent = FViewer) then
    FViewer := nil;
end;

procedure TFb2FileTreeView.SetAutoOpen(const Value: Boolean);
begin
  FAutoOpen := Value;
end;

function TFb2FileTreeView.OpenSelectedFile: Boolean;
var
  SelPath: TFileName;
begin
  Result := False;
  if FViewer = nil then
    Exit;
  SelPath := SelectedFilePath;
  if SelPath = '' then
    Exit;
  FViewer.FileName := SelPath;
  Result := True;
end;

procedure TFb2FileTreeView.DblClick;
begin
  inherited DblClick;
  if FAutoOpen then
    OpenSelectedFile;
end;

procedure TFb2FileTreeView.KeyDown(var Key: Word; Shift: TShiftState);
begin
  inherited KeyDown(Key, Shift);
  if FAutoOpen and (Key = VK_RETURN) then
  begin
    { Key := 0 — клавиша обработана, иначе LCL отдаст Enter форме (кнопке по
      умолчанию). }
    Key := 0;
    OpenSelectedFile;
  end;
end;

procedure TFb2FileTreeView.FilterAddItem(Sender: TObject;
  const ABasePath: string; const AFileInfo: TSearchRec;
  var CanAdd: Boolean);
begin
  if CanAdd then
  begin
    if (AFileInfo.Attr and faDirectory) <> 0 then
    begin
      { Каталоги видны всегда (иначе до файлов не добраться), но в режиме
        HideEmptyDirs каталог без подходящих файлов пропускаем. }
      if FHideEmptyDirs and (AFileInfo.Name <> '.') and
        (AFileInfo.Name <> '..') and
        not DirHasMatches(IncludeTrailingPathDelimiter(ABasePath) +
          AFileInfo.Name, 0) then
        CanAdd := False;
    end
    else
      { Файлы — только по маске. }
      if (FMatcher = nil) or not FMatcher.Matches(AFileInfo.Name) then
        CanAdd := False;
  end;
  { Пользовательский обработчик — после нашего фильтра. }
  if Assigned(FUserAddItem) then
    FUserAddItem(Self, ABasePath, AFileInfo, CanAdd);
end;

{$WARN 5044 OFF}  { faHidden платформенная константа — так же поступает и LCL }
function TFb2FileTreeView.DirHasMatches(const ADir: string;
  ADepth: Integer): Boolean;
var
  Key: string;
  SR: TSearchRec;
begin
  Key := ExcludeTrailingPathDelimiter(ADir);
  if FDirWithMatches.IndexOf(Key) >= 0 then
    Exit(True);
  if FDirWithoutMatches.IndexOf(Key) >= 0 then
    Exit(False);

  { Не уходим глубже лимита и не продолжаем, когда бюджет сканирования
    исчерпан: считаем каталог НЕпустым. Лучше показать лишний каталог, чем
    подвесить приложение на обходе гигантского дерева. }
  Result := (ADepth >= MaxDirDepth) or (FScanBudget = 0);
  if not Result then
  begin
    if FindFirstUTF8(IncludeTrailingPathDelimiter(Key) + '*', faAnyFile, SR) = 0
    then
      try
        repeat
          if (SR.Name = '') or (SR.Name = '.') or (SR.Name = '..') then
            Continue;
          { Бюджет: ограничивает суммарный объём сканирования. }
          if FScanBudget > 0 then
          begin
            Dec(FScanBudget);
            if FScanBudget = 0 then
            begin
              Result := True;
              Break;
            end;
          end;
          { Скрытые элементы учитываем только если они видны в дереве. }
          if ((SR.Attr and faHidden) <> 0) and
            not (otHidden in ObjectTypes) then
            Continue;
          if (SR.Attr and faDirectory) <> 0 then
          begin
            { По символическим ссылкам/junction'ам НЕ идём: на Windows их
              циклы («Application Data» и т. п.) раздувают обход в разы. Такой
              каталог считаем непустым — он не будет скрыт. }
            if (SR.Attr and faSymLink) <> 0 then
            begin
              Result := True;
              Break;
            end;
            if (otFolders in ObjectTypes) and
              DirHasMatches(IncludeTrailingPathDelimiter(Key) + SR.Name,
                ADepth + 1) then
            begin
              Result := True;
              Break;
            end;
          end
          else if (otNonFolders in ObjectTypes) and (FMatcher <> nil) and
            FMatcher.Matches(SR.Name) then
          begin
            Result := True;
            Break;
          end;
        until FindNextUTF8(SR) <> 0;
      finally
        FindCloseUTF8(SR);
      end;
  end;

  if Result then
    FDirWithMatches.Add(Key)
  else
    FDirWithoutMatches.Add(Key);
end;
{$WARN 5044 ON}

function TFb2FileTreeView.SelectFile(const AFileName: TFileName): Boolean;
var
  Full, Dir: string;
  N: TTreeNode;
  I: Integer;

  function IsTarget(ANode: TTreeNode): Boolean;
  begin
    Result := CompareFilenames(GetPathFromNode(ANode), Full) = 0;
  end;

begin
  Result := False;
  if Trim(AFileName) = '' then
    Exit;
  Full := ExpandFileNameUTF8(AFileName);
  if DirectoryExistsUTF8(Full) then
  begin
    Path := Full;
    Exit(True);
  end;
  if not FileExistsUTF8(Full) then
    Exit;

  { Path раскрывает дерево до каталога, поэтому появляется и узел файла. }
  Dir := ExtractFileDir(Full);
  if Dir <> '' then
    Path := Dir;

  { Обычно достаточно детей выделенного каталога. }
  N := Selected;
  if N <> nil then
    for I := 0 to N.Count - 1 do
      if IsTarget(N.Items[I]) then
      begin
        N.Items[I].Selected := True;
        N.Items[I].MakeVisible;
        Exit(True);
      end;

  { Запасной вариант: полный перебор. }
  for I := 0 to Items.Count - 1 do
    if IsTarget(Items[I]) then
    begin
      Items[I].Selected := True;
      Items[I].MakeVisible;
      Exit(True);
    end;
end;

function TFb2FileTreeView.GetSelectedFilePath: TFileName;
var
  N: TTreeNode;
  P: string;
begin
  Result := '';
  N := Selected;
  if N = nil then
    Exit;
  P := GetPathFromNode(N);
  if (P <> '') and (not DirectoryExistsUTF8(P)) and FileExistsUTF8(P) then
    Result := P;
end;

end.
