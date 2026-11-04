#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["duckdb>=2.0.0", "pandas"]
# ///
"""Export the change point example's tables as JSON for the Scala.js app.

Writes web/public/fx_regimes.json (or OUTPUT.json):

    {"days":    [[date, sek_per_eur, log_return_pct | null], ...],
     "regimes": [{n, start, end, trading_days, mean_log_return_pct,
                  daily_vol_pct, annualised_vol_pct}, ...]}

Run after `dbt build --vars '{with_changepoint: true}'`:

    uv run scripts/export_fx_regimes_json.py [OUTPUT.json]

Needs SA_PASSWORD in the environment (the Makefile exports .env).
"""
from __future__ import annotations

import json
import math
import os
import sys
from pathlib import Path

from fx_regimes_db import read_tables

DEFAULT_OUT = Path(__file__).resolve().parent.parent / "web" / "public" / "fx_regimes.json"


def export(days, regimes) -> dict:
    def ret(x: float) -> float | None:
        return None if math.isnan(x) else round(x, 4)

    return {
        "days": [
            [d.date_day.strftime("%Y-%m-%d"), round(d.sek_per_eur, 4), ret(d.log_return_pct)]
            for d in days.itertuples()
        ],
        "regimes": [
            {
                "n": int(r.regime_number),
                "start": r.start_date.strftime("%Y-%m-%d"),
                "end": r.end_date.strftime("%Y-%m-%d"),
                "trading_days": int(r.trading_days),
                "mean_log_return_pct": r.mean_log_return_pct,
                "daily_vol_pct": r.daily_vol_pct,
                "annualised_vol_pct": r.annualised_vol_pct,
            }
            for r in regimes.itertuples()
        ],
    }


def main() -> int:
    password = os.environ.get("SA_PASSWORD")
    if not password:
        print("SA_PASSWORD not set.", file=sys.stderr)
        return 1
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_OUT
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(export(*read_tables(password)), separators=(",", ":")) + "\n")
    print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
