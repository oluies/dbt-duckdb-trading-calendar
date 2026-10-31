SHELL := /bin/bash

# Load .env so SA_PASSWORD etc. are available to recipes and to
# `docker compose` (which reads .env from the project dir on its own,
# but we also need it for the host-side db-init and db-shell).
ifneq (,$(wildcard ./.env))
include .env
export
endif

# PLATFORM selects which compose file + db-shell sqlcmd to use.
#   PLATFORM=default  -> docker-compose.yml,   SQL Server 2022 (amd64)
#   PLATFORM=arm-mac  -> docker-compose.arm.yml, Azure SQL Edge (arm64)
# Override on the command line, e.g.:  make PLATFORM=arm-mac db-up
PLATFORM ?= default

ifeq ($(PLATFORM),arm-mac)
COMPOSE_FILE := docker-compose.arm.yml
# azure-sql-edge:latest ships no sqlcmd, so db-shell needs one on the host.
DB_SHELL     := sqlcmd -S localhost,1433
else
COMPOSE_FILE := docker-compose.yml
DB_SHELL     := docker compose -f $(COMPOSE_FILE) exec mssql /opt/mssql-tools18/bin/sqlcmd -S localhost
endif

COMPOSE := docker compose -f $(COMPOSE_FILE)
# db-init runs on the host and needs the duckdb package from
# requirements.txt (activate the venv first, or override PYTHON).
PYTHON  ?= python3
SERVICE := mssql

.PHONY: help db-up db-down db-shell db-init db-logs db-status db-viewer db-viewer-down

help:
	@echo "Targets (set PLATFORM=arm-mac on Apple Silicon for native arm64):"
	@echo "  db-up      Start SQL Server (waits for healthy)"
	@echo "  db-down    Stop SQL Server (keeps volume)"
	@echo "  db-shell   Open a sqlcmd shell inside the container"
	@echo "  db-init    Create Referensdata database and azuredl schema"
	@echo "  db-logs    Tail SQL Server logs"
	@echo "  db-status  Show container + healthcheck status"
	@echo "  db-viewer  Start DBGate web SQL browser at http://localhost:8085"
	@echo "  db-viewer-down  Stop and remove the DBGate viewer"
	@echo ""
	@echo "Current PLATFORM=$(PLATFORM) -> $(COMPOSE_FILE)"

db-up:
	@test -n "$$SA_PASSWORD" || (echo "SA_PASSWORD not set. Copy .env.example to .env first." && exit 1)
	$(COMPOSE) up -d $(SERVICE)
	@echo "Waiting for SQL Server to become healthy..."
	@for i in $$(seq 1 60); do \
	  status=$$($(COMPOSE) ps --format '{{.Health}}' $(SERVICE) 2>/dev/null); \
	  if [ "$$status" = "healthy" ]; then echo "SQL Server is healthy."; exit 0; fi; \
	  sleep 2; \
	done; \
	echo "Timed out waiting for SQL Server to be healthy." && \
	$(COMPOSE) ps $(SERVICE) && exit 1

db-down:
	$(COMPOSE) down

# -C trusts the self-signed cert that ships with the dev images.
db-shell:
	$(DB_SHELL) -U sa -P "$$SA_PASSWORD" -C

db-init:
	@test -n "$$SA_PASSWORD" || (echo "SA_PASSWORD not set." && exit 1)
	$(PYTHON) scripts/db_init.py

db-logs:
	$(COMPOSE) logs -f $(SERVICE)

db-status:
	$(COMPOSE) ps $(SERVICE)

# DBGate web SQL client / table browser for the marts. Opt-in via the
# compose "tools" profile so it never starts with a normal db-up. It
# auto-connects to the mssql service (connection "Referensdata").
db-viewer:
	@test -n "$$SA_PASSWORD" || (echo "SA_PASSWORD not set. Copy .env.example to .env first." && exit 1)
	$(COMPOSE) --profile tools up -d dbviewer
	@echo "DBGate starting at http://localhost:8085 (connection: Referensdata)."
	@echo "If SQL Server isn't running yet, run 'make db-up' first (or 'make PLATFORM=arm-mac db-up')."

db-viewer-down:
	$(COMPOSE) --profile tools rm -sf dbviewer
