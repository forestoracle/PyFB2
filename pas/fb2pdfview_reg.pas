unit fb2pdfview_reg;
{ Регистрация компонентов просмотра PDF в палитре Lazarus: TFb2PdfView
  (панель просмотра), TFb2PdfOutline (дерево оглавления) и TFb2PdfThumbnails
  (панель миниатюр) — вкладка «FB2», рядом с компонентами FB2.

  Design-time unit пакета pyfb2pdfview.lpk. Требует исходников PdfiumLib и
  PdfiumPascal в пути поиска пакета (см. README_PASCAL.md). }
{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Classes, LResources, fb2pdfview, fb2pdfoutline, fb2pdfthumbnails;

procedure Register;

implementation

procedure Register;
begin
  RegisterComponents('FB2', [TFb2PdfView, TFb2PdfOutline, TFb2PdfThumbnails]);
end;

end.
