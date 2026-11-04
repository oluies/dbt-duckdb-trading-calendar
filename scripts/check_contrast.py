#!/usr/bin/env python3
"""Check the regime page's colour palettes against WCAG 2.1 AA.

Reads every palette from web/index.html (the default :root block and each
:root[data-bg=...] block) and the regimes from web/public/fx_regimes.json,
then checks the colour pairs the page draws:

* text: --fg and --muted on --bg and on --row, 4.5:1 (1.4.3)
* chart lines, regime swatches, the returns bars and --focus against
  --bg, and the rate line over each regime's band, 3:1 (1.4.11)
* marker labels (drawn in --fg) over each band, 4.5:1

The band opacity follows RegimeChart.applyPalette: --band-alpha scaled by
0.7 + 0.9 x the regime's volatility position. Exits 1 on any failure.

    python3 scripts/check_contrast.py
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HTML = ROOT / "web" / "index.html"
DATA = ROOT / "web" / "public" / "fx_regimes.json"


def rgb(c: str) -> tuple[int, int, int]:
    c = c.lstrip("#")
    return tuple(int(c[i:i + 2], 16) for i in (0, 2, 4))


def luminance(c: str) -> float:
    def channel(v: int) -> float:
        v /= 255
        return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = rgb(c)
    return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)


def ratio(a: str, b: str) -> float:
    hi, lo = sorted((luminance(a), luminance(b)), reverse=True)
    return (hi + 0.05) / (lo + 0.05)


def blend(fg: str, bg: str, alpha: float) -> str:
    return "#" + "".join(f"{round(f * alpha + b * (1 - alpha)):02x}" for f, b in zip(rgb(fg), rgb(bg)))


def ramp(stops: list[str], t: float) -> str:
    x = min(max(t, 0.0), 1.0) * (len(stops) - 1)
    i = min(int(x), len(stops) - 2)
    f = x - i
    return "#" + "".join(f"{round(a + (b - a) * f):02x}" for a, b in zip(rgb(stops[i]), rgb(stops[i + 1])))


def palettes(html: str) -> dict[str, dict[str, str]]:
    """The default palette and every data-bg palette, as token -> value."""
    blocks = {"default": re.search(r":root \{(.*?)\}", html, re.S).group(1)}
    blocks |= dict(re.findall(r':root\[data-bg="([a-z]+)"\] \{(.*?)\}', html, re.S))
    return {name: dict(re.findall(r"--([a-z0-9-]+):\s*([^;]+);", body)) for name, body in blocks.items()}


def audit(name: str, p: dict[str, str], vols: list[float]) -> int:
    failures = 0

    def check(what: str, a: str, b: str, need: float) -> None:
        nonlocal failures
        r = ratio(a, b)
        if r < need:
            failures += 1
            print(f"FAIL {name}: {what}: {r:.2f}:1, needs {need}:1")

    bg, fg, muted, row = p["bg"], p["fg"], p["muted"], p["row"]
    check("text on background", fg, bg, 4.5)
    check("muted text on background", muted, bg, 4.5)
    check("text on row and code background", fg, row, 4.5)
    check("muted text on row and code background", muted, row, 4.5)
    check("focus ring", p["focus"], bg, 3)
    check("returns bars", blend(muted, bg, 0.8), bg, 3)
    stops = [p["ramp-0"], p["ramp-1"], p["ramp-2"]]
    lo, hi = min(vols), max(vols)
    for v in vols:
        t = (v - lo) / (hi - lo) if hi > lo else 0.0
        colour = ramp(stops, t)
        band = blend(colour, bg, float(p["band-alpha"]) * (0.7 + 0.9 * t))
        check(f"{v:.1f}% regime: line and swatch", colour, bg, 3)
        check(f"{v:.1f}% regime: rate line over band", fg, band, 3)
        check(f"{v:.1f}% regime: marker label over band", fg, band, 4.5)
    return failures


def main() -> int:
    vols = [r["annualised_vol_pct"] for r in json.loads(DATA.read_text())["regimes"]]
    found = palettes(HTML.read_text())
    failures = sum(audit(name, p, vols) for name, p in found.items())
    print(f"{len(found)} palettes ({', '.join(found)}): {failures} failing")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
