unit fb2filelistview;
{ Список файлов каталога, показывающий только FB2-файлы.

  Наследник TShellListView (unit ShellCtrls, входит в LCL): показывает файлы
  текущего каталога, подходящие под маску Mask (по умолчанию '*.fb2';
  несколько шаблонов — через ';'). Парный компонент к TFb2FileTreeView:
  связав их свойством ShellTreeView, получите «дерево + список» (список
  следует за выделением в дереве).

  Каталог, содержимое которого показывается, задаётся свойством Path
  (синоним унаследованного Root) — так же, как у TFb2FileTreeView.

  Пример:
      L := TFb2FileListView.Create(Self);
      L.Parent := Self;   L.Align := alClient;
      L.ShellTreeView := FileTree;   (необязательно — синхронизация с деревом)
      L.Path := 'C:\\Books';
      L.OnSelectItem := @FileSelected;
      ...
      if L.SelectedFilePath <> '' then ...   (выбранный файл)

  Требует LCL (unit ShellCtrls). GUI-модуль (в make-сборку библиотеки не
  входит). }

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Classes, SysUtils, ComCtrls, ShellCtrls, LazFileUtils;

type
  { Список файлов каталога с фильтром по маске (по умолчанию — только FB2). }
  TFb2FileListView = class(TShellListView)
  private
    function GetPath: string;
    procedure SetPath(const Value: string);
    function GetSelectedFilePath: TFileName;
  public
    constructor Create(AOwner: TComponent); override;
    { Полные пути всех выделенных файлов (для MultiSelect = True). }
    procedure SelectedFilePaths(AList: TStrings);
    { Полный путь выделенного файла ('' — ничего не выделено). }
    property SelectedFilePath: TFileName read GetSelectedFilePath;
  published
    { Каталог, содержимое которого показывается (синоним унаследованного
      свойства Root — для единообразия с TFb2FileTreeView.Path). }
    property Path: string read GetPath write SetPath;
  end;

implementation

constructor TFb2FileListView.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  { TShellListView по умолчанию показывает ВСЕ файлы (Mask = '') — фильтруем
    так же, как TFb2FileTreeView. }
  Mask := '*.fb2';
end;

function TFb2FileListView.GetPath: string;
begin
  Result := Root;
end;

procedure TFb2FileListView.SetPath(const Value: string);
begin
  { SetRoot сам перечитывает содержимое каталога. }
  Root := Value;
end;

function TFb2FileListView.GetSelectedFilePath: TFileName;
var
  Item: TListItem;
  P: string;
begin
  Result := '';
  Item := Selected;
  if Item = nil then
    Exit;
  P := GetPathFromItem(Item);
  if (P <> '') and (not DirectoryExistsUTF8(P)) and FileExistsUTF8(P) then
    Result := P;
end;

procedure TFb2FileListView.SelectedFilePaths(AList: TStrings);
var
  I: Integer;
  Item: TListItem;
  P: string;
begin
  AList.BeginUpdate;
  try
    AList.Clear;
    for I := 0 to Items.Count - 1 do
    begin
      Item := Items[I];
      if not Item.Selected then
        Continue;
      P := GetPathFromItem(Item);
      if (P <> '') and (not DirectoryExistsUTF8(P)) and FileExistsUTF8(P) then
        AList.Add(P);
    end;
  finally
    AList.EndUpdate;
  end;
end;

end.