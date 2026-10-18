unit fb2_images;
{ Определение типа и размеров изображений — перевод fb2_images.py.

  Нужен конвертерам в контейнерные форматы (ODT, MOBI, FB3, DOCX): там
  изображения встраиваются с указанием типа и размеров, а исходные данные
  лежат в <binary> FB2 без этой информации.

  Пример:
      Ext := '';
      MT := DetectImageType(Data, Ext);        { 'image/png', '.png' }
      if ImageSize(Data, MT, W, H) then ...; }

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Classes, SysUtils;

const
  { MIME-тип по умолчанию, если сигнатура не распознана. }
  DEFAULT_MEDIA_TYPE = 'image/jpeg';

type
  { Размер изображения в пикселях. }
  TImageSize = record
    Width: Integer;
    Height: Integer;
    Valid: Boolean;
  end;

{ Определить тип изображения по сигнатуре.
  Возвращает MIME-тип, в Ext — расширение ('.jpg' для неизвестных данных). }
function DetectImageType(const Data: TBytes; out Ext: UnicodeString): UnicodeString;

{ Расширение файла для MIME-типа ('.bin', если тип неизвестен). }
function ExtensionForMediaType(const MediaType: UnicodeString): UnicodeString;

{ Определить размеры изображения в пикселях.
  Valid = False, если размер неизвестен. }
function ImageSize(const Data: TBytes;
  const MediaType: UnicodeString = ''): TImageSize;

{ Масштабировать размер так, чтобы ширина не превышала MaxWidth. }
procedure ScaleToWidth(Width, Height, MaxWidth: Double;
  out OutWidth, OutHeight: Double);

implementation

{ ===================== Сигнатуры ===================== }

type
  TSignature = record
    Magic: array[0..7] of Byte;
    MagicLen: Integer;
    MediaType: UnicodeString;
    Ext: UnicodeString;
  end;

const
  SIGNATURES: array[0..6] of TSignature = (
    (Magic: ($89, $50, $4E, $47, $0D, $0A, $1A, $0A); MagicLen: 8;
     MediaType: 'image/png'; Ext: '.png'),
    (Magic: ($FF, $D8, $FF, 0, 0, 0, 0, 0); MagicLen: 3;
     MediaType: 'image/jpeg'; Ext: '.jpg'),
    (Magic: ($47, $49, $46, $38, $37, $61, 0, 0); MagicLen: 6;
     MediaType: 'image/gif'; Ext: '.gif'),
    (Magic: ($47, $49, $46, $38, $39, $61, 0, 0); MagicLen: 6;
     MediaType: 'image/gif'; Ext: '.gif'),
    (Magic: ($42, $4D, 0, 0, 0, 0, 0, 0); MagicLen: 2;
     MediaType: 'image/bmp'; Ext: '.bmp'),
    (Magic: ($49, $49, $2A, $00, 0, 0, 0, 0); MagicLen: 4;
     MediaType: 'image/tiff'; Ext: '.tiff'),
    (Magic: ($4D, $4D, $00, $2A, 0, 0, 0, 0); MagicLen: 4;
     MediaType: 'image/tiff'; Ext: '.tiff')
  );

function StartsWith(const Data: TBytes; const Sig: TSignature): Boolean;
var
  I: Integer;
begin
  Result := False;
  if Length(Data) < Sig.MagicLen then
    Exit;
  for I := 0 to Sig.MagicLen - 1 do
    if Data[I] <> Sig.Magic[I] then
      Exit;
  Result := True;
end;

function DetectImageType(const Data: TBytes; out Ext: UnicodeString): UnicodeString;
var
  I: Integer;
begin
  Ext := '.jpg';
  for I := Low(SIGNATURES) to High(SIGNATURES) do
    if StartsWith(Data, SIGNATURES[I]) then
    begin
      Ext := SIGNATURES[I].Ext;
      Exit(SIGNATURES[I].MediaType);
    end;

  { WEBP: 'RIFF' .... 'WEBP' }
  if (Length(Data) >= 12) and (Data[0] = Ord('R')) and (Data[1] = Ord('I')) and
    (Data[2] = Ord('F')) and (Data[3] = Ord('F')) and
    (Data[8] = Ord('W')) and (Data[9] = Ord('E')) and
    (Data[10] = Ord('B')) and (Data[11] = Ord('P')) then
  begin
    Ext := '.webp';
    Exit('image/webp');
  end;

  Result := DEFAULT_MEDIA_TYPE;
end;

function ExtensionForMediaType(const MediaType: UnicodeString): UnicodeString;
var
  N: UnicodeString;
  I: Integer;
begin
  N := LowerCase(Trim(MediaType));
  for I := Low(SIGNATURES) to High(SIGNATURES) do
    if LowerCase(SIGNATURES[I].MediaType) = N then
      Exit(SIGNATURES[I].Ext);
  if N = 'image/jpg' then
    Exit('.jpg');
  if N = 'image/svg+xml' then
    Exit('.svg');
  if N = 'image/webp' then
    Exit('.webp');
  if N = 'application/octet-stream' then
    Exit('.bin');
  Result := '.bin';
end;

{ ===================== Чтение размеров ===================== }

function ReadBE32(const Data: TBytes; Ofs: Integer): LongWord;
begin
  Result := (LongWord(Data[Ofs]) shl 24) or (LongWord(Data[Ofs + 1]) shl 16) or
    (LongWord(Data[Ofs + 2]) shl 8) or LongWord(Data[Ofs + 3]);
end;

function ReadBE16(const Data: TBytes; Ofs: Integer): Word;
begin
  Result := (Word(Data[Ofs]) shl 8) or Word(Data[Ofs + 1]);
end;

function ReadLE16(const Data: TBytes; Ofs: Integer): Word;
begin
  Result := Word(Data[Ofs]) or (Word(Data[Ofs + 1]) shl 8);
end;

function ReadLE32s(const Data: TBytes; Ofs: Integer): LongInt;
begin
  Result := LongInt(ReadLE16(Data, Ofs)) or
    (LongInt(ReadLE16(Data, Ofs + 2)) shl 16);
end;

{ Размер PNG из заголовка IHDR. }
function PngSize(const Data: TBytes; out W, H: Integer): Boolean;
begin
  Result := False;
  if Length(Data) < 24 then
    Exit;
  W := Integer(ReadBE32(Data, 16));
  H := Integer(ReadBE32(Data, 20));
  Result := True;
end;

{ Размер GIF из логического дескриптора экрана. }
function GifSize(const Data: TBytes; out W, H: Integer): Boolean;
begin
  Result := False;
  if Length(Data) < 10 then
    Exit;
  W := ReadLE16(Data, 6);
  H := ReadLE16(Data, 8);
  Result := True;
end;

{ Размер BMP из DIB-заголовка. }
function BmpSize(const Data: TBytes; out W, H: Integer): Boolean;
begin
  Result := False;
  if Length(Data) < 26 then
    Exit;
  W := Abs(ReadLE32s(Data, 18));
  H := Abs(ReadLE32s(Data, 22));
  Result := True;
end;

{ Размер JPEG (поиск маркера SOF). }
function JpegSize(const Data: TBytes; out W, H: Integer): Boolean;
var
  Index, Size, Marker: Integer;
  Len: Word;
begin
  Result := False;
  Index := 2;
  Size := Length(Data);
  while Index + 9 < Size do
  begin
    if Data[Index] <> $FF then
    begin
      Inc(Index);
      Continue;
    end;
    Marker := Data[Index + 1];
    if (Marker = $D8) or (Marker = $01) or
      ((Marker >= $D0) and (Marker <= $D7)) then
    begin
      Inc(Index, 2);
      Continue;
    end;
    Len := ReadBE16(Data, Index + 2);
    if (Marker = $C0) or (Marker = $C1) or (Marker = $C2) or (Marker = $C3) or
      (Marker = $C5) or (Marker = $C6) or (Marker = $C7) or (Marker = $C9) or
      (Marker = $CA) or (Marker = $CB) then
    begin
      H := ReadBE16(Data, Index + 5);
      W := ReadBE16(Data, Index + 7);
      Result := True;
      Exit;
    end;
    Inc(Index, 2 + Len);
  end;
end;

function ImageSize(const Data: TBytes; const MediaType: UnicodeString): TImageSize;
var
  Kind, DummyExt: UnicodeString;
begin
  Result.Width := 0;
  Result.Height := 0;
  Result.Valid := False;
  Kind := LowerCase(Trim(MediaType));
  if (Kind <> 'image/png') and (Kind <> 'image/jpeg') and
    (Kind <> 'image/jpg') and (Kind <> 'image/gif') and (Kind <> 'image/bmp') then
    Kind := DetectImageType(Data, DummyExt);

  if Kind = 'image/png' then
    Result.Valid := PngSize(Data, Result.Width, Result.Height)
  else if (Kind = 'image/jpeg') or (Kind = 'image/jpg') then
    Result.Valid := JpegSize(Data, Result.Width, Result.Height)
  else if Kind = 'image/gif' then
    Result.Valid := GifSize(Data, Result.Width, Result.Height)
  else if Kind = 'image/bmp' then
    Result.Valid := BmpSize(Data, Result.Width, Result.Height);
end;

procedure ScaleToWidth(Width, Height, MaxWidth: Double;
  out OutWidth, OutHeight: Double);
begin
  if (Width <= 0) or (Height <= 0) then
  begin
    OutWidth := MaxWidth;
    OutHeight := MaxWidth;
    Exit;
  end;
  if Width <= MaxWidth then
  begin
    OutWidth := Width;
    OutHeight := Height;
    Exit;
  end;
  OutWidth := MaxWidth;
  OutHeight := Round(Height * (MaxWidth / Width) * 100) / 100;
end;

end.
