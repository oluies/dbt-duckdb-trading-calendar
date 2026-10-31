#!/usr/bin/env python3
"""Create the Referensdata database and its azuredl schema (`make db-init`).

Talks to SQL Server through DuckDB's community `mssql` extension
(`mssql_exec`) over the published port, the same way dbt's ATTACH in
profiles.yml does. This replaces `sqlcmd` inside the container:
`azure-sql-edge:latest` no longer ships it, so the old `docker compose
exec ... sqlcmd` recipe failed on Apple Silicon.

Needs the `duckdb` package from requirements.txt and SA_PASSWORD in the
environment (the Makefile exports .env). Idempotent.
"""
from __future__ import annotations

import os
import sys

import duckdb

SERVER = "localhost,1433"


def attach(con: duckdb.DuckDBPyConnection, alias: str, database: str, password: str) -> None:
    dsn = (
        f"Server={SERVER};Database={database};UID=sa;PWD={password};"
        "Encrypt=yes;TrustServerCertificate=yes"
    )
    con.execute(f"ATTACH '{dsn.replace(chr(39), chr(39) * 2)}' AS {alias} (TYPE mssql)")


def main() -> int:
    password = os.environ.get("SA_PASSWORD")
    if not password:
        print("SA_PASSWORD not set.", file=sys.stderr)
        return 1

    con = duckdb.connect()
    con.execute("INSTALL mssql FROM community")
    con.execute("LOAD mssql")

    attach(con, "master_db", "master", password)
    con.execute(
        "SELECT mssql_exec('master_db', ?)",
        ["IF DB_ID('Referensdata') IS NULL CREATE DATABASE Referensdata;"],
    )

    attach(con, "ref", "Referensdata", password)
    con.execute(
        "SELECT mssql_exec('ref', ?)",
        ["IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'azuredl') "
         "EXEC('CREATE SCHEMA azuredl');"],
    )

    print("Referensdata.azuredl is ready.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
