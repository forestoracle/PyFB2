"""SVG -> PNG с прозрачным фоном (использован для набора в pas/icons).

Зависимости: Pillow, svglib, reportlab (и rlPyCairo, если нужен рендер с альфой;
здесь альфа получается из белого фона, поэтому достаточно renderPM по умолчанию).

Использование:
    python svg2png.py <каталог-с-svg> <каталог-вывода> [размер ...]

Особенности Bootstrap Icons: fill="currentColor" (подставляем #000000) и
viewBox 0 0 16 16 (масштабируем по viewBox, а не по width/height).
"""
import os
import re
import sys

from PIL import Image
from reportlab.graphics import renderPM
from svglib.svglib import svg2rlg

VIEWBOX = re.compile(r'viewBox="0 0 ([\d.]+) ([\d.]+)"')


def viewbox_size(svg):
    m = VIEWBOX.search(svg)
    return (float(m.group(1)), float(m.group(2))) if m else (16.0, 16.0)


def render(src_svg, dst_png, size):
    svg = open(src_svg, encoding="utf-8").read().replace("currentColor", "#000000")
    vb_w, vb_h = viewbox_size(svg)
    tmp = dst_png + ".svg"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(svg)
    try:
        drawing = svg2rlg(tmp)
        if drawing is None:
            raise RuntimeError("svg2rlg returned None")
        k = size / max(vb_w, vb_h)
        drawing.scale(k, k)
        drawing.width = size
        drawing.height = size
        renderPM.drawToFile(drawing, dst_png, fmt="PNG", dpi=72, bg=0xFFFFFF)
    finally:
        os.remove(tmp)

    # Белый фон -> прозрачность (иконка монохромная, RGB = чёрный).
    with Image.open(dst_png) as im:
        alpha = im.convert("L").point(lambda v: 255 - v)
        rgba = Image.new("RGBA", im.size, (0, 0, 0, 0))
        rgba.putalpha(alpha)
        rgba.save(dst_png)


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    src, out = argv[1], argv[2]
    sizes = [int(s) for s in argv[3:]] or [64, 48, 32, 24, 16]
    names = sorted(f[:-4] for f in os.listdir(src) if f.lower().endswith(".svg"))
    for size in sizes:
        target = os.path.join(out, str(size))
        os.makedirs(target, exist_ok=True)
        for name in names:
            dst = os.path.join(target, name + ".png")
            try:
                render(os.path.join(src, name + ".svg"), dst, size)
                print("ok", size, name)
            except Exception as exc:  # noqa: BLE001 - отчёт о проблемной иконке
                print("FAIL", size, name, exc)
    print(f"done: {len(names)} icons x {len(sizes)} sizes")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
