unit fb2_errors;
{ Единая иерархия исключений pyFB2 — перевод fb2_errors.py.

  Все ошибки библиотеки наследуют EFb2Error, поэтому приложению достаточно
  одного обработчика:

      try
        Book := TFb2Parser.Create(...)...;
      except
        on E: EFb2Error do ...;
      end;

  В Python каждый класс дополнительно наследовал «классический» тип
  (ValueError/RuntimeError/LookupError). В Pascal множественного наследования
  классов нет, поэтому сохранено только общее наследование от EFb2Error
  (а сам он — от Exception).

  Классы:
      * EFb2ParseError      — FB2/XML не удалось прочитать или разобрать;
      * EFb2ValidationError — документ или XSD-схема не подходят;
      * EFb2ConversionError — не удалось преобразовать книгу;
      * EFb2OperationError  — ошибка файловой операции (переименование);
      * EFb2NotFoundError   — запрошенные данные не найдены;
      * EFb2NetworkError    — сетевой запрос не удался. }

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  SysUtils;

type
  { Базовое исключение pyFB2: ловит любую ошибку библиотеки. }
  EFb2Error = class(Exception);

  { FB2/XML не удалось прочитать или разобрать. }
  EFb2ParseError = class(EFb2Error);

  { Документ не соответствует XSD-схеме (или сама схема непригодна). }
  EFb2ValidationError = class(EFb2Error);

  { Не удалось преобразовать книгу: входные данные, формат или состояние. }
  EFb2ConversionError = class(EFb2Error);

  { Ошибка операции с файлами (например, переименование). }
  EFb2OperationError = class(EFb2Error);

  { Запрошенные данные не найдены (книга, статья, автор, обложка). }
  EFb2NotFoundError = class(EFb2Error);

  { Сетевая ошибка или некорректный ответ сервиса. }
  EFb2NetworkError = class(EFb2Error);

implementation

end.
