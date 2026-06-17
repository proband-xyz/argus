# Argus enterprise stack — operator interface.
#
# All targets must be run from inside infra/.
# Reset is destructive: it drops every named volume, wiping all state.

SHELL := /bin/zsh
# Docker Desktop on macOS installs the credential helper outside the default
# shell PATH; ssh sessions then fail to pull images. Prepend the bin dir so
# `make` invocations from any context find docker-credential-desktop.
export PATH := /Applications/Docker.app/Contents/Resources/bin:$(PATH)
COMPOSE := docker compose
ENV_FILE := .env

# Services exposed for `make health`. Format: name:url
HEALTH_TARGETS := \
	keycloak:http://localhost:8080/realms/master \
	postgres:tcp://localhost:5432 \
	gitea:http://localhost:3000/api/healthz \
	minio:http://localhost:9000/minio/health/live \
	mailpit:http://localhost:8025/readyz \
	opensearch:http://localhost:9200/_cluster/health

.DEFAULT_GOAL := help

.PHONY: help
help:
	@print "Argus enterprise stack targets:"
	@print "  make up        — start the stack (creates .env from .env.example if missing)"
	@print "  make down      — stop the stack (preserves volumes)"
	@print "  make reset     — DESTRUCTIVE: stop + delete all volumes"
	@print "  make logs      — tail logs from all services"
	@print "  make health    — probe each service for readiness"
	@print "  make gitea-setup — run gitea/setup.sh against the live stack"
	@print "  make mcp-test  — connect to every server in mcp-servers.yaml and list tools"

.PHONY: up
up: $(ENV_FILE)
	@$(COMPOSE) up -d
	@print "Stack starting. Run 'make health' in ~60s to verify readiness."

.PHONY: down
down:
	@$(COMPOSE) down

.PHONY: reset
reset:
	@print "About to DELETE all named volumes (keycloak, postgres, gitea, minio, opensearch)."
	@print -n "Type 'yes' to confirm: "
	@read confirm; \
		if [[ $$confirm == "yes" ]]; then \
			$(COMPOSE) down --volumes --remove-orphans; \
			print "Volumes destroyed. Re-run 'make up' for a clean start."; \
		else \
			print "Aborted."; \
		fi

.PHONY: logs
logs:
	@$(COMPOSE) logs -f --tail=100

.PHONY: health
health:
	@for entry in $(HEALTH_TARGETS); do \
		name=$${entry%%:*}; \
		url=$${entry#*:}; \
		if [[ $$url == tcp://* ]]; then \
			hostport=$${url#tcp://}; \
			host=$${hostport%:*}; \
			port=$${hostport#*:}; \
			if nc -z -w 2 $$host $$port >/dev/null 2>&1; then \
				print "  [OK]   $$name ($$url)"; \
			else \
				print "  [FAIL] $$name ($$url)"; \
			fi; \
		else \
			if curl -fsS -o /dev/null -m 5 "$$url"; then \
				print "  [OK]   $$name ($$url)"; \
			else \
				print "  [FAIL] $$name ($$url)"; \
			fi; \
		fi; \
	done

.PHONY: gitea-setup
gitea-setup:
	@./gitea/setup.sh

# Smoke-test the MCP bridge: load infra/mcp-servers.yaml, connect to every
# server, list its tools, and report per-server counts.
#
# Sources .env so ${VAR} placeholders in the YAML resolve to credentials,
# and prepends Docker Desktop's bin dir so the dockerized MinIO MCP can run.
# Pre-creates the filesystem/git sandbox dirs the reference servers expect.
.PHONY: mcp-test
mcp-test: $(ENV_FILE)
	@mkdir -p /tmp/stac-fs /tmp/stac-git
	@if [[ ! -d /tmp/stac-git/.git ]]; then \
		git -C /tmp/stac-git init -q; \
	fi
	@set -a; source $(ENV_FILE); set +a; \
		cd .. && uv run --no-sync python scripts/mcp_smoke_test.py

# Auto-create .env from the example if the operator hasn't yet.
$(ENV_FILE):
	@if [[ ! -f $(ENV_FILE) ]]; then \
		cp .env.example $(ENV_FILE); \
		print "Created $(ENV_FILE) from .env.example. Edit before bringing up the stack."; \
	fi
