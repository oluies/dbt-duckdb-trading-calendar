#!/usr/bin/env pwsh
<#
.SYNOPSIS
  One command to browse the marts locally on Windows.

.DESCRIPTION
  Brings up SQL Server, builds the dbt marts into Referensdata, starts the
  DBGate web SQL client / table browser, and prints how to open it.

    scripts\view-marts.ps1          # build everything + start the viewer
    scripts\view-marts.ps1 down     # stop + remove the viewer and SQL Server

  Architecture-aware: on Windows ARM64 it uses the native arm64 image
  (Azure SQL Edge, docker-compose.arm.yml); otherwise SQL Server
  (docker-compose.yml). DBGate itself is multi-arch.

  Self-contained: drives docker compose directly (no 'make' needed) and
  creates a local .venv with dbt-core + dbt-duckdb if one is not present.
#>
[CmdletBinding()]
param([Parameter(Position = 0)][string]$Action = "up")

$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")    # repo root

$ViewerUrl   = "http://localhost:8085"
$DbContainer = "holiday_loader_mssql"

function Say($m)  { Write-Host "`n$m" -ForegroundColor Cyan }
function Info($m) { Write-Host "  $m" }
function Die($m)  { Write-Host "`nERROR: $m" -ForegroundColor Red; exit 1 }

# --- pick compose file / DB image by CPU architecture ----------------------
if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") {
  $ComposeFile = "docker-compose.arm.yml"; $DbImage = "Azure SQL Edge (native arm64)"
} else {
  $ComposeFile = "docker-compose.yml";     $DbImage = "SQL Server (amd64)"
}

# --- teardown mode ---------------------------------------------------------
if ($Action -eq "down") {
  Say "Tearing down viewer + SQL Server..."
  docker compose -f $ComposeFile --profile tools rm -sf dbviewer 2>$null | Out-Null
  docker compose -f $ComposeFile down 2>$null | Out-Null
  Info "Done. (DuckDB working file and .venv are left in place.)"
  exit 0
}

# --- preflight -------------------------------------------------------------
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { Die "docker not found on PATH." }
docker info *> $null; if ($LASTEXITCODE -ne 0) { Die "Docker daemon is not running." }
if (-not (Test-Path ".env")) { Die ".env not found. Copy .env.example to .env and set SA_PASSWORD." }

# Read SA_PASSWORD from .env (docker compose also reads .env on its own).
$pw = $null
foreach ($line in Get-Content ".env") {
  if ($line -match '^\s*SA_PASSWORD\s*=\s*(.+?)\s*$') { $pw = $Matches[1].Trim('"').Trim("'") }
}
if (-not $pw) { Die "SA_PASSWORD is empty in .env." }
$env:SA_PASSWORD = $pw

Say "1/4  Starting SQL Server  --  arch=$($env:PROCESSOR_ARCHITECTURE) -> $DbImage"
docker compose -f $ComposeFile up -d mssql
if ($LASTEXITCODE -ne 0) { Die "docker compose up failed (is host port 1433 free?)." }

# Wait for the healthcheck.
$healthy = $false
for ($i = 1; $i -le 60; $i++) {
  $h = (docker inspect -f '{{.State.Health.Status}}' $DbContainer 2>$null)
  Info "[$i] $h"
  if ($h -eq "healthy") { $healthy = $true; break }
  Start-Sleep -Seconds 3
}
if (-not $healthy) { Die "SQL Server did not become healthy in time." }

# Detect the bundled sqlcmd path (SQL Server uses mssql-tools18; Azure SQL
# Edge uses the older mssql-tools).
$Sqlcmd = "/opt/mssql-tools18/bin/sqlcmd"; $Tls = "-C"
docker exec $DbContainer test -x $Sqlcmd *> $null
if ($LASTEXITCODE -ne 0) { $Sqlcmd = "/opt/mssql-tools/bin/sqlcmd"; $Tls = "" }

function Invoke-Sql {
  param([string]$Sql, [string]$Db = "")
  $a = @("-S", "localhost", "-U", "sa", "-P", $pw, "-b")
  if ($Tls) { $a += $Tls }
  if ($Db)  { $a += @("-d", $Db) }
  $Sql | docker exec -i $DbContainer $Sqlcmd @a    # SQL via stdin -> no arg-quoting issues
}

Info "Creating Referensdata + azuredl schema..."
Invoke-Sql "IF DB_ID('Referensdata') IS NULL CREATE DATABASE Referensdata;"
Invoke-Sql "IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'azuredl') EXEC('CREATE SCHEMA azuredl');" "Referensdata"

# --- ensure a dbt with the DuckDB adapter ----------------------------------
Say "2/4  Preparing dbt (dbt-core + dbt-duckdb)"
$DbtExe = ".venv\Scripts\dbt.exe"
if (Test-Path $DbtExe) {
  Info "Using existing .venv"
} else {
  $pyCmd = $null
  foreach ($cand in @(@("py","-3.12"), @("py","-3.11"), @("py","-3.13"), @("py","-3.10"), @("python"), @("python3"))) {
    $exe = $cand[0]
    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { continue }
    $extra = if ($cand.Count -gt 1) { $cand[1..($cand.Count - 1)] } else { @() }
    $v = & $exe @extra -c "import sys;print('%d.%d'%sys.version_info[:2])" 2>$null
    if ($LASTEXITCODE -eq 0 -and $v) {
      $p = $v.Trim().Split('.')
      if ([int]$p[0] -eq 3 -and [int]$p[1] -ge 10) { $pyCmd = $cand; break }
    }
  }
  if (-not $pyCmd) { Die "Need Python >= 3.10 to create the dbt venv (none found)." }
  $extra = if ($pyCmd.Count -gt 1) { $pyCmd[1..($pyCmd.Count - 1)] } else { @() }
  Info "Creating .venv with $($pyCmd -join ' ')"
  & $pyCmd[0] @extra -m venv .venv
  & ".venv\Scripts\python.exe" -m pip install -q --upgrade pip
  & ".venv\Scripts\pip.exe" install -q -r requirements.txt
}

# --- build the marts -------------------------------------------------------
Say "3/4  Building marts into Referensdata (dbt seed + run)"
$env:DBT_PROFILES_DIR = (Get-Location).Path
# The dbt profile's default CA bundle is a Linux path that does not exist on
# Windows; DuckDB's azure extension needs a real bundle to read the public
# holiday parquet over HTTPS. certifi (installed with dbt) ships one.
if (-not $env:AZURE_CA_CERT_FILE) {
  $certifi = & ".venv\Scripts\python.exe" -c "import certifi;print(certifi.where())" 2>$null
  if ($LASTEXITCODE -eq 0 -and $certifi) { $env:AZURE_CA_CERT_FILE = $certifi.Trim() }
}
& $DbtExe deps; if ($LASTEXITCODE -ne 0) { Die "dbt deps failed." }
& $DbtExe seed; if ($LASTEXITCODE -ne 0) { Die "dbt seed failed." }
& $DbtExe run;  if ($LASTEXITCODE -ne 0) { Die "dbt run failed." }

# --- start the viewer ------------------------------------------------------
Say "4/4  Starting DBGate web SQL / table browser"
docker compose -f $ComposeFile --profile tools up -d dbviewer

# --- report ----------------------------------------------------------------
$listSql = "SET NOCOUNT ON; SELECT s.name, t.name, SUM(p.rows) FROM sys.tables t JOIN sys.schemas s ON s.schema_id = t.schema_id JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0,1) GROUP BY s.name, t.name ORDER BY s.name, t.name"
$a = @("-S", "localhost", "-U", "sa", "-P", $pw, "-d", "Referensdata", "-h", "-1", "-W", "-s", "|")
if ($Tls) { $a += $Tls }
$rows = ($listSql | docker exec -i $DbContainer $Sqlcmd @a) 2>$null

Say "Ready -- the marts are live in DBGate."
Info "Open:  $ViewerUrl   (auto-connected as `"Referensdata`")"
Info "Tables (expand the main_azuredl schema in the UI):"
$any = $false
foreach ($r in $rows) {
  $c = $r -split '\|'
  if ($c.Count -ge 3 -and $c[0].Trim()) {
    Info "    $($c[0].Trim()).$($c[1].Trim())  rows=$($c[2].Trim())"; $any = $true
  }
}
if (-not $any) { Info "    (could not read row counts; the tables are still there to browse)" }
Info ""
Info "Try in the SQL tab:"
Info "    SELECT TOP 20 * FROM main_azuredl.fct_holiday_calendar ORDER BY calendar_date;"
Info ""
Info "When done, tear it all down with:"
Info "    scripts\view-marts.ps1 down"

Start-Process $ViewerUrl -ErrorAction SilentlyContinue
