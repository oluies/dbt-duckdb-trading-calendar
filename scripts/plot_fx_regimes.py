#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["duckdb>=2.0.0", "pandas", "matplotlib", "seaborn"]
# ///
"""Plot the SEK/EUR volatility regimes that the change point example built.

Reads fct_trading_day_fx and fct_fx_regimes back out of SQL Server (through
DuckDB's mssql extension, like scripts/db_init.py) and draws two panels:

* top:    the SEK/EUR fixing, each regime shaded by its annualised volatility
* bottom: the daily log returns with each regime's +-2 sigma band

Run after `dbt build --vars '{with_changepoint: true}'`:

    uv run scripts/plot_fx_regimes.py [OUTPUT.png]

Needs SA_PASSWORD in the environment (the Makefile exports .env).
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

import duckdb
import matplotlib.pyplot as plt
import seaborn as sns
from matplotlib.colors import Normalize

SERVER = "localhost,1433"
SCHEMA = os.environ.get("DBT_SCHEMA", "main_azuredl")
DEFAULT_OUT = Path(__file__).resolve().parent.parent / "docs" / "fx_regimes.png"


def read_tables(password: str):
    dsn = (
        f"Server={SERVER};Database=Referensdata;UID=sa;PWD={password};"
        "Encrypt=yes;TrustServerCertificate=yes"
    )
    con = duckdb.connect()
    con.execute("INSTALL mssql FROM community")
    con.execute("LOAD mssql")
    con.execute(f"ATTACH '{dsn.replace(chr(39), chr(39) * 2)}' AS ref (TYPE mssql)")
    days = con.execute(
        f"SELECT date_day, sek_per_eur, log_return_pct FROM ref.{SCHEMA}.fct_trading_day_fx "
        "WHERE has_fixing ORDER BY date_day"
    ).df()
    regimes = con.execute(
        f"SELECT * FROM ref.{SCHEMA}.fct_fx_regimes ORDER BY regime_number"
    ).df()
    return days, regimes


def plot(days, regimes, out: Path) -> None:
    sns.set_theme(style="whitegrid", context="notebook")
    cmap = sns.color_palette("flare", as_cmap=True)
    vol = regimes["annualised_vol_pct"]
    norm = Normalize(vol.min(), vol.max())

    fig, (top, bottom) = plt.subplots(
        2, 1, figsize=(13, 7.5), sharex=True, layout="constrained",
        gridspec_kw={"height_ratios": [3, 2]},
    )
    for r in regimes.itertuples():
        top.axvspan(r.start_date, r.end_date, color=cmap(norm(r.annualised_vol_pct)), alpha=0.35, lw=0)
        band = 2 * r.daily_vol_pct
        bottom.fill_between(
            [r.start_date, r.end_date], r.mean_log_return_pct - band, r.mean_log_return_pct + band,
            color=cmap(norm(r.annualised_vol_pct)), alpha=0.35, lw=0,
        )
    for r in regimes[vol >= 2 * vol.median()].itertuples():
        top.annotate(
            f"{r.start_date:%b %Y}\n{r.annualised_vol_pct:.1f}% vol",
            xy=(r.start_date, 1), xycoords=("data", "axes fraction"),
            xytext=(2, -4), textcoords="offset points", va="top", fontsize=9,
        )

    sns.lineplot(data=days, x="date_day", y="sek_per_eur", ax=top, color="black", lw=0.9)
    sns.lineplot(data=days, x="date_day", y="log_return_pct", ax=bottom, color="black", lw=0.5)
    top.set(ylabel="SEK per EUR", xlabel=None,
            title="SEK/EUR volatility regimes (PELT, normal cost) over Nasdaq Stockholm trading days")
    bottom.set_ylabel("daily log return, %")
    bottom.set_xlabel("Data: Sveriges Riksbank (SEKEURPMI). Regimes: cpt DuckDB extension.",
                      fontsize=8, color="0.4", loc="left")
    bottom.text(0.005, 0.03, "band: regime mean ± 2σ", transform=bottom.transAxes, fontsize=9)

    bar = fig.colorbar(plt.cm.ScalarMappable(norm=norm, cmap=cmap), ax=[top, bottom])
    bar.set_label("annualised volatility, %")
    out.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out, dpi=150, bbox_inches="tight")
    print(f"wrote {out}")


def main() -> int:
    password = os.environ.get("SA_PASSWORD")
    if not password:
        print("SA_PASSWORD not set.", file=sys.stderr)
        return 1
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_OUT
    plot(*read_tables(password), out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
