# Иконки для панели читалки (16–64 px)

Монохромные иконки (чёрные штрихи на прозрачном фоне) для команд
`TFb2ViewerToolbar` и любых других кнопок приложения. PNG в пяти размерах:
`16/`, `24/`, `32/`, `48/`, `64/` — по 10 файлов в каждом.

**Источник:** [Bootstrap Icons](https://icons.getbootstrap.com/)
(репозиторий [twbs/icons](https://github.com/twbs/icons)).
**Лицензия: MIT** — полный текст в `LICENSE-bootstrap-icons.txt`,
копирайт «The Bootstrap Authors» сохраняется. Использование в MIT-проекте
(pyFB2) совместимо; при распространении достаточно сохранить текст лицензии.

## Соответствие командам `TFb2ViewerToolbar`

| Команда | Смысл | Иконка Bootstrap | Файл |
|---|---|---|---|
| `tcBack` | назад по истории | `arrow-left` | `arrow-left.png` |
| `tcForward` | вперёд по истории | `arrow-right` | `arrow-right.png` |
| `tcTop` | в начало документа | `arrow-up` | `arrow-up.png` |
| `tcFontDown` | меньше шрифт (A−) | `zoom-out` | `zoom-out.png` |
| `tcFontUp` | больше шрифт (A+) | `zoom-in` | `zoom-in.png` |
| `tcFontReset` | исходный размер (A) | `arrow-counterclockwise` | `arrow-counterclockwise.png` |
| `tcFind` | поиск | `search` | `search.png` |
| `tcFindNext` | найти далее | `chevron-down` | `chevron-down.png` |
| `tcCopy` | копировать | `clipboard` | `clipboard.png` |
| `tcPrint` | печать | `printer` | `printer.png` |

Альтернативы, если нужен другой смысл: «в начало» — `house`, «найти далее» —
`arrow-down`/`chevron-right`, «размер шрифта» — `fonts` (в Bootstrap Icons нет
отдельных `font-size-up/down`, поэтому взяты `zoom-in`/`zoom-out`).

## Как подключить

Проще всего через редактор `TImageList` (двойной щелчок → `Add` → выбрать PNG):
LCL хранит картинки прямо в `.lfm`/ресурсах формы. Размер списка задаётся
`Width`/`Height` (64×64 или, что обычно удобнее для тулбара, 32×32 или 24×24),
`ColorDepth := cd32Bit`.

Загрузка во время выполнения:

```pascal
uses Graphics, ImgList;

procedure LoadIcon(AList: TImageList; const AFile: string);
var
  Png: TPortableNetworkGraphic;
  Bmp: TBitmap;
begin
  Png := TPortableNetworkGraphic.Create;
  try
    Png.LoadFromFile(AFile);
    Bmp := TBitmap.Create;
    try
      Bmp.Assign(Png);          { приводим к формату списка }
      AList.Add(Bmp, nil);      { индекс = AList.Count - 1 }
    finally
      Bmp.Free;
    end;
  finally
    Png.Free;
  end;
end;
```

Индексы в `TImageList` идут в порядке добавления, поэтому удобно добавлять
файлы в порядке команд (см. таблицу).

> Подключение картинок к самой панели `TFb2ViewerToolbar` (свойство `Images` +
> индексы для кнопок) пока не сделано: сейчас кнопки подписаны текстом
> (`◀`, `▶`, `A−`, `Найти`, …). Набор иконок положен именно для этого шага.

## Как перегенерировать

SVG-исходники качаются из `twbs/icons` (`icons/<name>.svg`), затем
`tools/svg2png.py` растеризует их в PNG нужных размеров:

```sh
python tools/svg2png.py <каталог-с-svg> <каталог-вывода> 64 48 32 24 16
```

Особенности конвертации (учтены в скрипте):

* Bootstrap Icons рисуются через `fill="currentColor"` — svglib его не
  разрешает, поэтому цвет подставляется (`#000000`);
* размер берётся из `viewBox="0 0 16 16"` (svglib неверно читает `width`/`height`);
* фон рендерится белым и затем превращается в прозрачность по яркости —
  получаются сглаженные чёрные штрихи с альфа-каналом.
