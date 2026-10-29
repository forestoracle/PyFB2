{ This file was automatically created by Lazarus. Do not edit!
  This source is only used to compile and install the package.
 }

unit pyfb2pdfview;

{$warn 5023 off : no warning about unused units}
interface

uses
  fb2pdfbookmarks, fb2pdfview, fb2pdfoutline, fb2pdfthumbnails, 
  fb2pdfview_reg, LazarusPackageIntf;

implementation

procedure Register;
begin
  RegisterUnit('fb2pdfview_reg', @fb2pdfview_reg.Register);
end;

initialization
  RegisterPackage('pyfb2pdfview', @Register);
end.
