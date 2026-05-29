#!/usr/bin/env bash
#
# view-marts.sh -- one command to browse the marts locally.
#
# Brings up SQL Server, builds the dbt marts into Referensdata, starts the
# DBGate web SQL client / table browser, and prints how to open it.
#
#   scripts/view-marts.sh          # build everything + start the viewer
#   scripts/view-marts.sh down     # stop + remove the viewer and SQL Server
#
# Architecture-aware: on Apple Silicon it uses the native arm64 image
# (Azure SQL Edge, via docker-compose.arm.yml); on amd64 it uses SQL Server
# (docker-compose.yml). DBGate itself is multi-arch. Image selection rides on
# the Makefile's PLATFORM switch so there is a single source of truth.
#
set -euo pipefail

cd "$(dirname "$0")/.."   # repo root

VIEWER_URL="http://localhost:8085"

# --- helpers ---------------------------------------------------------------
say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
die()  { printf '\n\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# --- pick platform / DB image by CPU architecture --------------------------
ARCH="$(uname -m)"
case "$ARCH" in
  arm64|aarch64) PLATFORM=arm-mac; DB_IMAGE="Azure SQL Edge (native arm64)" ;;
  x86_64|amd64)  PLATFORM=default; DB_IMAGE="SQL Server (amd64)" ;;
  *)             PLATFORM=default; DB_IMAGE="SQL Server (amd64, unknown arch '$ARCH')" ;;
esac
export PLATFORM

# --- teardown mode ---------------------------------------------------------
if [ "${1:-}" = "down" ]; then
  say "Tearing down viewer + SQL Server (PLATFORM=$PLATFORM)..."
  make PLATFORM="$PLATFORM" db-viewer-down 2>/dev/null || true
  make PLATFORM="$PLATFORM" db-down        2>/dev/null || true
  info "Done. (DuckDB working file and .venv are left in place.)"
  exit 0
fi

# --- preflight -------------------------------------------------------------
command -v docker >/dev/null 2>&1 || die "docker not found on PATH."
docker info >/dev/null 2>&1       || die "Docker daemon is not running."
[ -f .env ]                       || die ".env not found. Copy .env.example to .env and set SA_PASSWORD."
# Load SA_PASSWORD for the dbt step (Makefile loads .env on its own).
set -a; . ./.env; set +a
[ -n "${SA_PASSWORD:-}" ]         || die "SA_PASSWORD is empty in .env."

# Warn (don't fail) if host port 1433 is already taken by something else --
# the compose stack publishes 1433 and db-up would fail to bind.
if command -v lsof >/dev/null 2>&1 && lsof -nP -iTCP:1433 -sTCP:LISTEN >/dev/null 2>&1; then
  if ! docker ps --format '{{.Names}}' | grep -q '^holiday_loader_mssql$'; then
    info "WARNING: host port 1433 is already in use by another process/container."
    info "         'make db-up' will fail to bind until it is freed."
  fi
fi

say "1/4  Starting SQL Server  --  arch=$ARCH -> $DB_IMAGE (PLATFORM=$PLATFORM)"
make PLATFORM="$PLATFORM" db-up
make PLATFORM="$PLATFORM" db-init

# --- ensure a dbt with the DuckDB adapter ----------------------------------
# The repo's requirements pin dbt-core + dbt-duckdb. A global dbt often lacks
# the duckdb adapter, so we prefer (and create) a local .venv.
say "2/4  Preparing dbt (dbt-core + dbt-duckdb)"
if [ -x .venv/bin/dbt ]; then
  DBT=.venv/bin/dbt
  info "Using existing .venv"
else
  PYBIN=""
  for c in python3.12 python3.11 python3.13 python3.10 python3; do
    if command -v "$c" >/dev/null 2>&1; then
      v="$("$c" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null || echo 0.0)"
      major="${v%%.*}"; minor="${v##*.}"
      if [ "$major" = "3" ] && [ "$minor" -ge 10 ] 2>/dev/null; then PYBIN="$c"; break; fi
    fi
  done
  [ -n "$PYBIN" ] || die "Need Python >= 3.10 to create the dbt venv (none found)."
  info "Creating .venv with $PYBIN ($("$PYBIN" --version 2>&1))"
  "$PYBIN" -m venv .venv
  .venv/bin/python -m pip install -q --upgrade pip
  .venv/bin/pip install -q -r requirements.txt
  DBT=.venv/bin/dbt
fi

# --- build the marts -------------------------------------------------------
say "3/4  Building marts into Referensdata (dbt seed + run)"
export DBT_PROFILES_DIR="$PWD"
# On macOS the dbt profile's default CA bundle path (a Debian path) does not
# exist; DuckDB's azure extension needs a real bundle to read the public
# holiday parquet over HTTPS. /etc/ssl/cert.pem is the macOS system bundle.
if [ "$(uname -s)" = "Darwin" ] && [ -z "${AZURE_CA_CERT_FILE:-}" ] && [ -f /etc/ssl/cert.pem ]; then
  export AZURE_CA_CERT_FILE=/etc/ssl/cert.pem
fi
"$DBT" deps
"$DBT" seed
"$DBT" run

# --- start the viewer ------------------------------------------------------
say "4/4  Starting DBGate web SQL / table browser"
make PLATFORM="$PLATFORM" db-viewer

# --- report ----------------------------------------------------------------
# Row counts straight from SQL Server. Try the mssql-tools18 path first
# (SQL Server) then the older mssql-tools path (Azure SQL Edge). Password is
# read from the container's own env so it never appears in the host process list.
# Plain columns (no SQL string literals -> no QUOTED_IDENTIFIER quoting issues);
# formatted on the host with awk. -s"|" sets the column separator.
TABLES="$(docker exec holiday_loader_mssql bash -lc '
  S=/opt/mssql-tools18/bin/sqlcmd; F=-C
  [ -x "$S" ] || { S=/opt/mssql-tools/bin/sqlcmd; F=; }
  "$S" -S localhost -U sa -P "$MSSQL_SA_PASSWORD" $F -d Referensdata -h -1 -W -s"|" -Q "SET NOCOUNT ON; SELECT s.name, t.name, SUM(p.rows) FROM sys.tables t JOIN sys.schemas s ON s.schema_id = t.schema_id JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0,1) GROUP BY s.name, t.name ORDER BY s.name, t.name"
' 2>/dev/null | awk -F'|' 'NF>=3 {printf "    %s.%s  rows=%s\n", $1, $2, $3}' || true)"

say "Ready -- the marts are live in DBGate."
info "Open:  $VIEWER_URL   (auto-connected as \"Referensdata\")"
info "Tables (expand the main_azuredl schema in the UI):"
if [ -n "$TABLES" ]; then
  printf '%s\n' "$TABLES"
else
  info "    (could not read row counts; the tables are still there to browse)"
fi
info ""
info "Try in the SQL tab:"
info "    SELECT TOP 20 * FROM main_azuredl.fct_holiday_calendar ORDER BY calendar_date;"
info ""
info "When done, tear it all down with:"
info "    scripts/view-marts.sh down"

# Best-effort: open the browser on desktop OSes.
if command -v open >/dev/null 2>&1; then open "$VIEWER_URL" >/dev/null 2>&1 || true
elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$VIEWER_URL" >/dev/null 2>&1 || true
fi
