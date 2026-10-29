unit fb2pdfthumbnails;
{ Панель миниатюр страниц PDF, связанная с TFb2PdfView.

  Внутри — готовый контрол PdfiumPascal TPdfThumbnailsControl
  (PdfiumPascalThumbnailsPanelCtrl.pas): прокручиваемая лента миниатюр с
  номерами страниц, вертикальная или горизонтальная. Миниатюры рисуются тем же
  бэкендом, что и просмотр (GraphicsBackend_DrawPageToCanvas), и кэшируются по
  индексу страницы; при наведении миниатюра «подсвечивается» (затемнение через
  GraphicsBackend_DarkenProcedure, см. TFb2PdfView).

  Связывание: свойство Viewer подключает и документ (Document), и контрол
  просмотра (ViewControl). После этого клик по миниатюре сам переключает
  страницу в просмотрщике, а смена страницы прокручивает ленту к текущей.

  ВАЖНО (особенность PdfiumPascal): TPdfThumbnailsControl.SetViewControl
  подписывается на события просмотрщика и при повторном вызове освобождает
  прежнюю подписку, которая остаётся в списке старого контрола — это двойное
  освобождение. Поэтому ViewControl назначается ровно один раз на просмотрщик,
  а при смене Viewer внутренний контрол пересоздаётся (старый остаётся жить до
  уничтожения панели, чтобы не оставить висячих подписок).
  По той же причине Document нельзя присвоить nil (SetDocument обращается к
  PageCount без проверки): закрытому документу передаётся сам TPdfDocument с
  нулём страниц — лента просто остаётся пустой.

  Требует fb2pdfview.pas (PdfiumPascal, PdfiumLib, pdfium.dll) и LCL. GUI-модуль.

  Пример:
      T := TFb2PdfThumbnails.Create(Self);
      T.Parent := SidePanel;  T.Align := alClient;
      T.Viewer := Viewer;     ( миниатюры появятся после загрузки PDF ) }

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Classes, SysUtils, Controls, ExtCtrls, Graphics,
  PdfiumCore, PdfiumPascalThumbnailsPanelCtrl,
  fb2pdfview;

type
  { Ориентация ленты миниатюр (псевдоним типа PdfiumPascal). }
  TFb2PdfThumbOrientation = TPdfThumbnailsControlOrientation;
  { tcHorizontal — лента внизу, tcVertical — колонка слева. }

  { Панель миниатюр страниц PDF. }
  TFb2PdfThumbnails = class(TCustomPanel)
  private
    FViewer: TFb2PdfView;
    FThumbs: TPdfThumbnailsControl;
    FWiredViewer: TFb2PdfView;   { для какого просмотрщика подключён ViewControl }
    FOrientation: TFb2PdfThumbOrientation;
    FTextColor: TColor;
    FAllowMovePages: Boolean;
    procedure SetViewer(const Value: TFb2PdfView);
    procedure SetOrientation(const Value: TFb2PdfThumbOrientation);
    procedure SetTextColor(const Value: TColor);
    procedure SetAllowMovePages(const Value: Boolean);
    procedure ViewerDocumentLoad(Sender: TObject);
    procedure CreateThumbs;
    procedure SyncDocument;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    { Пересобрать миниатюры (сбросить кэш) — например, после правки страниц. }
    procedure Rebuild;

    { Внутренний контрол PdfiumPascal (для тонкой настройки). }
    property Thumbs: TPdfThumbnailsControl read FThumbs;
  published
    { У «Custom»-предков Align/Anchors объявлены public — переопубликовываем
      для инспектора объектов. }
    property Align;
    property Anchors;
    { Связанный просмотрщик PDF. }
    property Viewer: TFb2PdfView read FViewer write SetViewer;
    { Вертикальная колонка (tcVertical, по умолчанию) или лента снизу. }
    property Orientation: TFb2PdfThumbOrientation read FOrientation
      write SetOrientation default tcVertical;
    { Цвет номеров страниц. }
    property TextColor: TColor read FTextColor write SetTextColor
      default clWindowText;
    { Разрешить перетаскивание миниатюр (меняет порядок страниц в документе:
      Options = [tpoMovePages] в PdfiumPascal). По умолчанию выключено. }
    property AllowMovePages: Boolean read FAllowMovePages
      write SetAllowMovePages default False;
  end;

implementation

constructor TFb2PdfThumbnails.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FOrientation := tcVertical;
  FTextColor := clWindowText;
  FAllowMovePages := False;
  CreateThumbs;
end;

destructor TFb2PdfThumbnails.Destroy;
begin
  if FViewer <> nil then
    FViewer.RemoveDocumentLoadListener(@ViewerDocumentLoad);
  inherited Destroy;
end;

{ Создать внутренний контрол миниатюр с текущими настройками. }
procedure TFb2PdfThumbnails.CreateThumbs;
begin
  FThumbs := TPdfThumbnailsControl.Create(Self);
  FThumbs.Parent := Self;
  FThumbs.Align := alClient;
  FThumbs.Orientation := FOrientation;
  FThumbs.TextColor := FTextColor;
  if FAllowMovePages then
    FThumbs.Options := [tpoMovePages]
  else
    FThumbs.Options := [];
end;

{ ===================== Связывание с просмотрщиком ===================== }

procedure TFb2PdfThumbnails.SetViewer(const Value: TFb2PdfView);
begin
  if FViewer = Value then
    Exit;
  if FViewer <> nil then
    FViewer.RemoveDocumentLoadListener(@ViewerDocumentLoad);
  FViewer := Value;
  if FViewer <> nil then
  begin
    FViewer.AddDocumentLoadListener(@ViewerDocumentLoad);
    FThumbs.Show;
  end
  else
    { Очистить ленту нельзя (SetDocument(nil) в PdfiumPascal падает) — прячем. }
    FThumbs.Hide;
  SyncDocument;
end;

{ Подключить документ и контрол просмотра к внутреннему контролу миниатюр.
  См. шапку модуля: ViewControl назначается один раз на просмотрщик. }
procedure TFb2PdfThumbnails.SyncDocument;
var
  Doc: TPdfDocument;
begin
  if (FViewer = nil) or (FThumbs = nil) then
    Exit;

  if (FViewer.Viewer <> nil) and (FWiredViewer <> FViewer) then
  begin
    if FWiredViewer <> nil then
    begin
      { Старый контрол скрываем, но не освобождаем: на нём висит подписка
        прежнего просмотрщика, а уничтожит его владелец (эта панель). }
      FThumbs.Hide;
      FThumbs := nil;
      CreateThumbs;
    end;
    FThumbs.ViewControl := FViewer.Viewer;
    FWiredViewer := FViewer;
  end;

  Doc := nil;
  if FViewer.Viewer <> nil then
    Doc := FViewer.Document;      { у закрытого документа PageCount = 0 }
  { Document присваиваем только при наличии страниц: SetDocument в PdfiumPascal
    ставит ScrollBar.Max := PageCount при Min = 1 и падает на нуле страниц.
    Повторная установка того же документа пересобирает список страниц и
    сбрасывает кэш миниатюр — это и нужно после каждой загрузки. }
  if (Doc <> nil) and (Doc.PageCount > 0) then
    FThumbs.Document := Doc;
end;

procedure TFb2PdfThumbnails.ViewerDocumentLoad(Sender: TObject);
begin
  SyncDocument;
end;

procedure TFb2PdfThumbnails.Rebuild;
begin
  SyncDocument;
end;

{ ===================== Свойства ===================== }

procedure TFb2PdfThumbnails.SetOrientation(
  const Value: TFb2PdfThumbOrientation);
begin
  if FOrientation = Value then
    Exit;
  FOrientation := Value;
  if FThumbs <> nil then
    FThumbs.Orientation := Value;
end;

procedure TFb2PdfThumbnails.SetTextColor(const Value: TColor);
begin
  if FTextColor = Value then
    Exit;
  FTextColor := Value;
  if FThumbs <> nil then
    FThumbs.TextColor := Value;
end;

procedure TFb2PdfThumbnails.SetAllowMovePages(const Value: Boolean);
begin
  if FAllowMovePages = Value then
    Exit;
  FAllowMovePages := Value;
  if FThumbs <> nil then
  begin
    if Value then
      FThumbs.Options := [tpoMovePages]
    else
      FThumbs.Options := [];
  end;
end;

end.
