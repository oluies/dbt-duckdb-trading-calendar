#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["duckdb>=2.0.0", "pandas"]
# ///
"""Interactive version of docs/fx_regimes.png, drawn with TradingView
Lightweight Charts (https://github.com/tradingview/lightweight-charts,
Apache-2.0).

Writes one self-contained HTML page with the data embedded; the library
loads from unpkg at a pinned version. Open it in a browser:

* top pane:    SEK/EUR fixing over regime bands shaded by volatility,
               a marker at each regime start
* bottom pane: daily log returns with the regime mean +- 2 sigma band
* a regime table below; click a row to zoom to that regime

Run after `dbt build --vars '{with_changepoint: true}'`:

    uv run scripts/chart_fx_regimes_tv.py [OUTPUT.html]

Needs SA_PASSWORD in the environment (the Makefile exports .env).
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

from fx_regimes_db import read_tables

LIGHTWEIGHT_CHARTS = "https://unpkg.com/lightweight-charts@5.2.1/dist/lightweight-charts.standalone.production.js"
DEFAULT_OUT = Path(__file__).resolve().parent.parent / "docs" / "fx_regimes.html"

# Low -> high volatility, like seaborn's "flare" in the PNG but ending in a
# brighter purple so the stress regimes stay visible on a dark background.
RAMP = [(0xED, 0xB0, 0x81), (0xD1, 0x4A, 0x61), (0x9A, 0x3A, 0xA8)]


def ramp(t: float) -> str:
    """Hex colour at position t in [0, 1] along RAMP."""
    t = min(max(t, 0.0), 1.0) * (len(RAMP) - 1)
    i = min(int(t), len(RAMP) - 2)
    f = t - i
    rgb = (round(a + (b - a) * f) for a, b in zip(RAMP[i], RAMP[i + 1]))
    return "#" + "".join(f"{c:02x}" for c in rgb)


def payload(days, regimes) -> dict:
    lo, hi = regimes["annualised_vol_pct"].min(), regimes["annualised_vol_pct"].max()
    median = regimes["annualised_vol_pct"].median()
    return {
        "days": [
            [d.date_day.strftime("%Y-%m-%d"), round(d.sek_per_eur, 4),
             None if d.log_return_pct != d.log_return_pct else round(d.log_return_pct, 4)]
            for d in days.itertuples()
        ],
        "regimes": [
            {
                "n": int(r.regime_number),
                "start": r.start_date.strftime("%Y-%m-%d"),
                "end": r.end_date.strftime("%Y-%m-%d"),
                "days": int(r.trading_days),
                "mean": r.mean_log_return_pct,
                "sd": r.daily_vol_pct,
                "vol": r.annualised_vol_pct,
                "stress": bool(r.annualised_vol_pct >= 2 * median),
                "color": ramp((r.annualised_vol_pct - lo) / (hi - lo) if hi > lo else 0.0),
            }
            for r in regimes.itertuples()
        ],
    }


PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>SEK/EUR volatility regimes</title>
<meta name="claude:viewport-fit-sides" content="cover">
<style>
  /* Light by default; dark follows the OS unless the page's host sets
     data-theme on the root, which wins either way. */
  :root { --bg: #ffffff; --fg: #1d1d1f; --muted: #6e6e73; --line: #e5e5ea; --row: #f5f5f7; }
  @media (prefers-color-scheme: dark) {
    :root:not([data-theme="light"]) { --bg: #131316; --fg: #ececf0; --muted: #9a9aa2; --line: #2c2c31; --row: #1d1d22; color-scheme: dark; }
  }
  :root[data-theme="dark"] { --bg: #131316; --fg: #ececf0; --muted: #9a9aa2; --line: #2c2c31; --row: #1d1d22; color-scheme: dark; }
  * { box-sizing: border-box; }
  body { margin: 0; padding-block: 16px; background: var(--bg); color: var(--fg);
         padding-left: max(16px, env(safe-area-inset-left, 0px));
         padding-right: max(16px, env(safe-area-inset-right, 0px));
         font: 14px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
  main { max-width: 1200px; margin: 0 auto; }
  h1 { font-size: 18px; margin: 0 0 4px; }
  p.sub { margin: 0 0 12px; color: var(--muted); }
  #legend { min-height: 1.45em; margin-bottom: 6px; font-variant-numeric: tabular-nums; }
  #legend .swatch { display: inline-block; width: 10px; height: 10px; border-radius: 2px;
                    margin: 0 4px 0 12px; vertical-align: -1px; }
  #chart { height: 560px; }
  /* Scoped: Lightweight Charts lays itself out with a <table> too. */
  .regimes { width: 100%; border-collapse: collapse; margin-top: 16px; font-variant-numeric: tabular-nums; }
  .regimes th, .regimes td { padding: 6px 8px; text-align: right; border-bottom: 1px solid var(--line); white-space: nowrap; }
  .regimes th:first-child, .regimes td:first-child,
  .regimes th:nth-child(2), .regimes td:nth-child(2) { text-align: left; }
  .regimes th { color: var(--muted); font-weight: 600; }
  .regimes tbody tr { cursor: pointer; }
  .regimes tbody tr:hover, .regimes tbody tr.active { background: var(--row); }
  .wrap { overflow-x: auto; }
  footer { margin-top: 12px; color: var(--muted); font-size: 12px; }
  footer a { color: inherit; }
  @media (max-width: 640px) { #chart { height: 440px; } }
</style>
</head>
<body>
<main>
  <h1>SEK/EUR volatility regimes</h1>
  <p class="sub">PELT change points (cpt DuckDB extension, normal cost) in the daily log return of the
    Riksbank SEK/EUR fixing, over Nasdaq Stockholm trading days. Click a regime to zoom; double-click the chart to reset.</p>
  <div id="legend"></div>
  <div id="chart"></div>
  <div class="wrap">
  <table class="regimes">
    <thead><tr><th>#</th><th>Regime</th><th>Trading days</th><th>Mean return %</th>
      <th>Daily vol %</th><th>Annualised vol %</th></tr></thead>
    <tbody id="regimes"></tbody>
  </table>
  </div>
  <footer>Data: Sveriges Riksbank, series SEKEURPMI. Regimes:
    <a href="https://github.com/hugr-lab/duck-changepoint">cpt</a>. Chart:
    <a href="https://www.tradingview.com/lightweight-charts/">TradingView Lightweight Charts</a>.</footer>
</main>
<script src="__LIB__"></script>
<script>
const DATA = __DATA__;
const LC = LightweightCharts;
const css = n => getComputedStyle(document.documentElement).getPropertyValue(n).trim();
const alpha = (hex, a) => hex + Math.round(a * 255).toString(16).padStart(2, '0');

const isDark = () => {
  const t = document.documentElement.dataset.theme;
  return t === 'dark' || (t !== 'light' && matchMedia('(prefers-color-scheme: dark)').matches);
};

const chart = LC.createChart(document.getElementById('chart'), {
  autoSize: true,
  layout: { fontSize: 12 },
  // ~3000 daily points: allow sub-pixel bars so fitContent shows them all.
  timeScale: { minBarSpacing: 0.05, fixLeftEdge: true, fixRightEdge: true },
  crosshair: { mode: LC.CrosshairMode.Normal },
});

// Regime of a date: regimes are sorted and tile the return series. The
// first fixing has no return and so no regime.
const regimeOf = t => DATA.regimes.find(r => t >= r.start && t <= r.end);

// Pane 0: one full-height area per regime on a hidden overlay scale (a
// histogram would leave gaps between sub-pixel bars), then the rate.
const bands = DATA.regimes.map(r => {
  const band = chart.addSeries(LC.AreaSeries, {
    priceScaleId: 'bands', lineVisible: false,
    lastValueVisible: false, priceLineVisible: false, crosshairMarkerVisible: false,
    autoscaleInfoProvider: () => ({ priceRange: { minValue: 0, maxValue: 1 } }),
  });
  // A return covers the interval since the previous fixing, so the band
  // starts one fixing before the regime: neighbouring bands then meet.
  const from = Math.max(0, DATA.days.findIndex(d => d[0] === r.start) - 1);
  const to = DATA.days.findIndex(d => d[0] === r.end);
  band.setData(DATA.days.slice(from, to + 1).map(d => ({ time: d[0], value: 1 })));
  return band;
});
chart.priceScale('bands').applyOptions({ scaleMargins: { top: 0, bottom: 0 }, visible: false });
const rate = chart.addSeries(LC.LineSeries, {
  lineWidth: 1, priceFormat: { type: 'price', precision: 4, minMove: 0.0001 },
  title: 'SEK/EUR',
});

// Pane 1: returns and the regime mean +- 2 sigma band.
const returns = chart.addSeries(LC.HistogramSeries, {
  priceFormat: { type: 'price', precision: 2, minMove: 0.01 },
  lastValueVisible: false, priceLineVisible: false, title: 'log return %',
}, 1);
const bandLine = { lineWidth: 1, lineType: LC.LineType.WithSteps, lastValueVisible: false,
                   priceLineVisible: false, crosshairMarkerVisible: false };
const upper = chart.addSeries(LC.LineSeries, bandLine, 1);
const lower = chart.addSeries(LC.LineSeries, bandLine, 1);

const rateData = [], retData = [], upData = [], loData = [];
for (const [time, value, ret] of DATA.days) {
  const r = regimeOf(time);
  rateData.push({ time, value });
  if (ret === null || !r) continue;
  retData.push({ time, value: ret });
  upData.push({ time, value: r.mean + 2 * r.sd, color: r.color });
  loData.push({ time, value: r.mean - 2 * r.sd, color: r.color });
}
rate.setData(rateData);
returns.setData(retData);
upper.setData(upData);
lower.setData(loData);

const markers = LC.createSeriesMarkers(rate, []);

// Everything that takes a theme colour, re-read from the CSS tokens so the
// chart follows a theme switch without a reload.
function applyTheme() {
  const line = css('--line');
  chart.applyOptions({
    layout: { background: { color: css('--bg') }, textColor: css('--muted'), panes: { separatorColor: line } },
    grid: { vertLines: { color: line }, horzLines: { color: line } },
    rightPriceScale: { borderColor: line },
    timeScale: { borderColor: line },
  });
  const bandAlpha = isDark() ? 0.4 : 0.28;
  bands.forEach((band, i) => {
    const fill = alpha(DATA.regimes[i].color, bandAlpha);
    band.applyOptions({ topColor: fill, bottomColor: fill });
  });
  rate.applyOptions({ color: css('--fg') });
  returns.applyOptions({ color: alpha(css('--muted'), 0.8) });
  markers.setMarkers(DATA.regimes.map(r => ({
    // Stress labels above the line, the rest below, so a stress regime's label
    // does not collide with the marker of the calm regime right after it.
    time: r.start, position: r.stress ? 'aboveBar' : 'belowBar', shape: r.stress ? 'arrowDown' : 'circle', size: r.stress ? 1.2 : 0.6,
    color: r.stress ? css('--fg') : r.color, text: r.stress ? `R${r.n} ${r.vol.toFixed(1)}% vol` : `R${r.n}`,
  })));
}
applyTheme();
matchMedia('(prefers-color-scheme: dark)').addEventListener('change', applyTheme);
new MutationObserver(applyTheme).observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });

const panes = chart.panes();
// Relative sizes: a fixed setHeight() can push the time axis out of view.
panes[0].setStretchFactor(2.2);
if (panes[1]) panes[1].setStretchFactor(1);
chart.timeScale().fitContent();

// Legend follows the crosshair; falls back to the last day.
const legend = document.getElementById('legend');
const byTime = new Map(DATA.days.map(d => [d[0], d]));
function showLegend(time) {
  const d = byTime.get(time) || DATA.days[DATA.days.length - 1];
  const r = regimeOf(d[0]);
  const ret = d[2] === null ? '–' : (d[2] >= 0 ? '+' : '') + d[2].toFixed(2) + '%';
  legend.innerHTML = `<b>${d[0]}</b> &nbsp; ${d[1].toFixed(4)} SEK/EUR &nbsp; return ${ret}` + (r ?
    `<span class="swatch" style="background:${r.color}"></span>regime R${r.n}: ` +
    `${r.vol.toFixed(1)}% annualised vol, ${r.start} → ${r.end}` : '');
}
chart.subscribeCrosshairMove(p => showLegend(p.time));
showLegend();

// Regime table: click to zoom, double-click the chart to reset.
const tbody = document.getElementById('regimes');
const pad = (iso, days) => { const t = new Date(iso); t.setUTCDate(t.getUTCDate() + days); return t.toISOString().slice(0, 10); };
for (const r of DATA.regimes) {
  const tr = document.createElement('tr');
  tr.innerHTML = `<td><span class="swatch" style="display:inline-block;width:10px;height:10px;border-radius:2px;background:${r.color}"></span> R${r.n}</td>` +
    `<td>${r.start} → ${r.end}</td><td>${r.days}</td><td>${r.mean.toFixed(3)}</td>` +
    `<td>${r.sd.toFixed(3)}</td><td>${r.vol.toFixed(1)}</td>`;
  tr.addEventListener('click', () => {
    tbody.querySelectorAll('tr').forEach(x => x.classList.toggle('active', x === tr));
    const margin = Math.max(10, Math.round(r.days * 0.15));
    chart.timeScale().setVisibleRange({ from: pad(r.start, -margin), to: pad(r.end, margin) });
  });
  tbody.appendChild(tr);
}
document.getElementById('chart').addEventListener('dblclick', () => {
  tbody.querySelectorAll('tr').forEach(x => x.classList.remove('active'));
  chart.timeScale().fitContent();
});
</script>
</body>
</html>
"""


def main() -> int:
    password = os.environ.get("SA_PASSWORD")
    if not password:
        print("SA_PASSWORD not set.", file=sys.stderr)
        return 1
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_OUT
    data = json.dumps(payload(*read_tables(password)), separators=(",", ":"))
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(PAGE.replace("__LIB__", LIGHTWEIGHT_CHARTS).replace("__DATA__", data))
    print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
