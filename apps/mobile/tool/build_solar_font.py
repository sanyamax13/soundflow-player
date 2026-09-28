#!/usr/bin/env python3
"""Собрать свой шрифт значков Solar для приложения (28.09.2026).

Зачем: в пакете solar_icons у части жирных значков при переводе в шрифт потерялись вырезы (у «Радостного»
смайлика один глаз, у значка профиля нет лица — Alex, скрин 28.09.2026). Здесь те же рисунки Solar
(с Iconify, лицензия CC BY 4.0) переводятся в шрифт правильно: чётно-нечётная заливка SVG через
skia-pathops превращается в обычные контуры шрифта, вырезы сохраняются.

Берёт значки, которые реально используются в коде (SolarBold.x / SolarOutline.x в lib/ и test/),
пишет assets/fonts/SolarApp.ttf и lib/core/solar.dart. Запуск (нужны fonttools и skia-pathops):
  python tool/build_solar_font.py
"""
import pathlib, re, subprocess, xml.etree.ElementTree as ET

import pathops
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.cu2quPen import Cu2QuPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.svgLib.path import parse_path

ROOT = pathlib.Path(__file__).resolve().parent.parent
UPM = 1024
FAMILY = "SolarApp"
SVGNS = "{http://www.w3.org/2000/svg}"


def kebab(name: str) -> str:
    s = re.sub(r"(?<=[a-z])(?=[A-Z0-9])|(?<=[0-9])(?=[A-Za-z])", "-", name).lower()
    return s.replace("wifi", "wi-fi")  # на Iconify «wi-fi-router-…»


def used_icons():
    names = set()
    for f in list((ROOT / "lib").rglob("*.dart")) + list((ROOT / "test").rglob("*.dart")):
        for style, name in re.findall(r"\bSolar(Bold|Outline)\.([a-zA-Z0-9]+)", f.read_text()):
            names.add((style, name))
    return sorted(names)


def slug(style: str, name: str) -> str:
    return f"{kebab(name)}-{'bold' if style == 'Bold' else 'outline'}"


def fetch_all(icons) -> dict:
    """Все нужные SVG одним запросом (по одному Iconify быстро начинает отказывать)."""
    import json
    names = ",".join(slug(st, n) for st, n in icons)
    out = subprocess.run(["curl", "-fsS", "-m", "60", f"https://api.iconify.design/solar.json?icons={names}"],
                         capture_output=True, text=True, check=True)
    data = json.loads(out.stdout)
    missing = [n for n in names.split(",") if n not in data.get("icons", {})]
    if missing:
        raise SystemExit(f"нет на Iconify: {missing}")
    return {k: f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">{v["body"]}</svg>'
            for k, v in data["icons"].items()}


def glyph_path(svg: str) -> pathops.Path:
    root = ET.fromstring(svg)
    total = pathops.Path()
    for el in root.iter():
        if el.tag != SVGNS + "path":
            continue
        p = pathops.Path()
        parse_path(el.get("d"), p.getPen())
        if el.get("fill-rule") == "evenodd":
            p.fillType = pathops.FillType.EVEN_ODD
        p.simplify()
        total = pathops.op(total, p, pathops.PathOp.UNION)
    return total


def main():
    icons = used_icons()
    svgs = fetch_all(icons)
    fb = FontBuilder(UPM, isTTF=True)
    order = [".notdef"]
    glyphs = {".notdef": TTGlyphPen(None).glyph()}
    cmap, metrics, dart = {}, {".notdef": (UPM, 0)}, []
    scale = UPM / 24
    for i, (style, name) in enumerate(icons):
        gname = f"{style.lower()}_{name}"
        code = 0xE000 + i
        path = glyph_path(svgs[slug(style, name)])
        pen = TTGlyphPen(None)
        # SVG: y вниз, 24×24; шрифт: y вверх, UPM; базовая линия — низ квадрата
        path.draw(TransformPen(Cu2QuPen(pen, max_err=1, reverse_direction=True), (scale, 0, 0, -scale, 0, UPM * 0.875)))
        glyphs[gname] = pen.glyph()
        order.append(gname)
        cmap[code] = gname
        metrics[gname] = (UPM, 0)
        dart.append((style, name, code))
    fb.setupGlyphOrder(order)
    fb.setupCharacterMap(cmap)
    fb.setupGlyf(glyphs)
    fb.setupHorizontalMetrics(metrics)
    fb.setupHorizontalHeader(ascent=int(UPM * 0.875), descent=-int(UPM * 0.125))
    fb.setupNameTable({"familyName": FAMILY, "styleName": "Regular"})
    fb.setupOS2(sTypoAscender=int(UPM * 0.875), sTypoDescender=-int(UPM * 0.125), usWinAscent=UPM, usWinDescent=int(UPM * 0.125))
    fb.setupPost()
    out = ROOT / "assets" / "fonts" / f"{FAMILY}.ttf"
    fb.save(str(out))

    lines = ["// Сгенерировано tool/build_solar_font.py — руками не править (значки Solar, CC BY 4.0).",
             "// ignore_for_file: constant_identifier_names", "",
             "import 'package:flutter/widgets.dart';", ""]
    for style in ("Bold", "Outline"):
        lines.append(f"/// Значки Solar ({'жирные' if style == 'Bold' else 'контурные'}), шрифт assets/fonts/{FAMILY}.ttf.")
        lines.append(f"abstract final class Solar{style} {{")
        for st, name, code in dart:
            if st == style:
                lines.append(f"  static const {name} = IconData(0x{code:04X}, fontFamily: '{FAMILY}');")
        lines.append("}")
        lines.append("")
    (ROOT / "lib" / "core" / "solar.dart").write_text("\n".join(lines))
    print(f"{len(dart)} значков → {out}")


if __name__ == "__main__":
    main()
