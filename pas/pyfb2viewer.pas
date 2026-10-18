{ This file was automatically created by Lazarus. Do not edit!
  This source is only used to compile and install the package.
 }

unit pyfb2viewer;

{$warn 5023 off : no warning about unused units}
interface

uses
  fb2_structures, fb2_parser, fb2_html, fb2viewer, fb2outline, 
  fb2viewertoolbar, fb2statusbar, fb2metadatapanel, fb2viewer_reg, 
  fb2renamelist, fb2filetreeview, fb2filelistview, LazarusPackageIntf;

implementation

procedure Register;
begin
  RegisterUnit('fb2viewer_reg', @fb2viewer_reg.Register);
end;

initialization
  RegisterPackage('pyfb2viewer', @Register);
end.
