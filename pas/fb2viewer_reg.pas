unit fb2viewer_reg;
{ Регистрация компонентов FB2 в палитре Lazarus: TFb2Viewer, TFb2Outline,
  TFb2ViewerToolbar, TFb2StatusBar, TFb2MetadataPanel, TFb2RenameList,
  TFb2FileTreeView, TFb2FileListView.
  Design-time unit пакета pyfb2viewer.lpk. }
{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Classes, LResources, fb2viewer, fb2outline, fb2viewertoolbar, fb2statusbar,
  fb2metadatapanel, fb2renamelist, fb2filetreeview, fb2filelistview;

procedure Register;

implementation

procedure Register;
begin
  RegisterComponents('FB2', [TFb2Viewer, TFb2Outline, TFb2ViewerToolbar,
    TFb2StatusBar, TFb2MetadataPanel, TFb2RenameList, TFb2FileTreeView,
    TFb2FileListView]);
end;

end.
