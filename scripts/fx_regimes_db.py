"""Read the change point example's tables back out of SQL Server.

Shared by plot_fx_regimes.py (seaborn PNG) and chart_fx_regimes_tv.py
(TradingView Lightweight Charts HTML). Goes through DuckDB's mssql
extension, like scripts/db_init.py. Needs SA_PASSWORD in the environment.
"""
from __future__ import annotations

import os

import duckdb

SERVER = "localhost,1433"
SCHEMA = os.environ.get("DBT_SCHEMA", "main_azuredl")


def read_tables(password: str):
    """Return (days, regimes) as pandas DataFrames.

    days:    fixing days of fct_trading_day_fx (date_day, sek_per_eur, log_return_pct)
    regimes: fct_fx_regimes in regime order
    """
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
