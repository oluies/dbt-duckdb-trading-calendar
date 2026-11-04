#!/usr/bin/env python3
"""Refresh seeds/riksbank_sekeur.csv from the Riksbank SWEA API.

The change point example (models/changepoint/) reads a frozen copy of the
Riksbank's daily SEK/EUR fixing (series SEKEURPMI) so CI never depends on
the API, which is rate-limited. Run this by hand to extend the series, then
commit the CSV:

    python scripts/fetch_riksbank_fx.py [END_DATE]

END_DATE defaults to today. The API needs no key. Source: Sveriges
Riksbank, https://www.riksbank.se/en-gb/statistics/
"""
from __future__ import annotations

import datetime as dt
import sys
from pathlib import Path

import duckdb

SERIES = "SEKEURPMI"
START = "2015-01-01"
URL = "https://api.riksbank.se/swea/v1/Observations/{series}/{start}/{end}"
SEED = Path(__file__).resolve().parent.parent / "seeds" / "riksbank_sekeur.csv"


def main() -> int:
    end = sys.argv[1] if len(sys.argv) > 1 else dt.date.today().isoformat()
    url = URL.format(series=SERIES, start=START, end=end)
    con = duckdb.connect()
    # The API answers DuckDB's HEAD probe with 404; GET works.
    con.execute("SET force_download = true")
    con.execute(
        f"""
        COPY (
            SELECT date::DATE AS rate_date, value::DECIMAL(10, 4) AS sek_per_eur
            FROM read_json('{url}')
            ORDER BY rate_date
        ) TO '{SEED}' (HEADER)
        """
    )
    n, first, last = con.execute(
        f"SELECT count(*), min(rate_date), max(rate_date) FROM read_csv('{SEED}')"
    ).fetchone()
    print(f"{SEED.name}: {n} fixings, {first} .. {last}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
