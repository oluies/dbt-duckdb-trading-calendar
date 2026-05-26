SHELL := /bin/bash

# Load .env so SA_PASSWORD etc. are available to recipes and to
# `docker compose` (which reads .env from the project dir on its own,
# but we also need it for sqlcmd invocations from the host).
ifneq (,$(wildcard ./.env))
include .env
export
endif

# PLATFORM selects which compose file + bundled sqlcmd path to use.
#   PLATFORM=default  -> docker-compose.yml,   SQL Server 2022 (amd64)
#   PLATFORM=arm-mac  -> docker-compose.arm.yml, Azure SQL Edge (arm64)
# Override on the command line, e.g.:  make PLATFORM=arm-mac db-up
PLATFORM ?= default

ifeq ($(PLATFORM),arm-mac)
COMPOSE_FILE := docker-compose.arm.yml
# Azure SQL Edge ships the older mssql-tools path.
SQLCMD       := /opt/mssql-tools/bin/sqlcmd
SQLCMD_TLS   :=
else
COMPOSE_FILE := docker-compose.yml
SQLCMD       := /opt/mssql-tools18/bin/sqlcmd
# mssql-tools18 defaults to encrypted connections and rejects the
# self-signed cert that ships with the dev image; -C trusts it.
SQLCMD_TLS   := -C
endif

COMPOSE := docker compose -f $(COMPOSE_FILE)
SERVICE := mssql

.PHONY: help db-up db-down db-shell db-init db-logs db-status

help:
	@echo "Targets (set PLATFORM=arm-mac on Apple Silicon for native arm64):"
	@echo "  db-up      Start SQL Server (waits for healthy)"
	@echo "  db-down    Stop SQL Server (keeps volume)"
	@echo "  db-shell   Open a sqlcmd shell inside the container"
	@echo "  db-init    Create Referensdata database and azuredl schema"
	@echo "  db-logs    Tail SQL Server logs"
	@echo "  db-status  Show container + healthcheck status"
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

db-shell:
	$(COMPOSE) exec $(SERVICE) $(SQLCMD) -S localhost -U sa -P "$$SA_PASSWORD" $(SQLCMD_TLS)

db-init:
	@test -n "$$SA_PASSWORD" || (echo "SA_PASSWORD not set." && exit 1)
	$(COMPOSE) exec -T $(SERVICE) $(SQLCMD) -S localhost -U sa -P "$$SA_PASSWORD" $(SQLCMD_TLS) -b -Q \
	  "IF DB_ID('Referensdata') IS NULL CREATE DATABASE Referensdata;"
	$(COMPOSE) exec -T $(SERVICE) $(SQLCMD) -S localhost -U sa -P "$$SA_PASSWORD" $(SQLCMD_TLS) -b -d Referensdata -Q \
	  "IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'azuredl') EXEC('CREATE SCHEMA azuredl');"
	@echo "Referensdata.azuredl is ready."

db-logs:
	$(COMPOSE) logs -f $(SERVICE)

db-status:
	$(COMPOSE) ps $(SERVICE)
