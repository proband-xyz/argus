#!/bin/zsh
# enable_pg_stat_statements.sh — one-time activation script.
#
# Background — Panel Blindspot B6 (2026-05-13). The dev stack's Postgres
# container was started without `shared_preload_libraries=pg_stat_statements`,
# so `pg_stat_statements` was never loaded and its view returns 0 rows.
# This pins 4 oracle predicate paths at 0% by construction:
#   - f05_kb_retrieval strict
#   - f10_investigation strict
#   - f06_reporting_adversarial_01 strict
#   - f08_compliance_adversarial_03 strict
#
# The fix is two-part:
#   1. docker-compose.yml now passes `-c shared_preload_libraries=...`
#      (committed alongside this script).
#   2. After restarting Postgres, CREATE EXTENSION in `enterprise` once —
#      this script does that.
#
# Must run AFTER Option C completes (restarting Postgres mid-experiment
# would corrupt in-flight runs). After Option C done:
#
#     bash infra/postgres/enable_pg_stat_statements.sh
#
# Idempotent.

set -eu

COMPOSE_FILE="${COMPOSE_FILE:-$(dirname "$0")/../docker-compose.yml}"
POSTGRES_USER="${POSTGRES_USER:-stac}"
POSTGRES_DB="${POSTGRES_DB:-enterprise}"

echo "[pg_stat_statements] restarting postgres container..."
docker compose -f "$COMPOSE_FILE" restart postgres

echo "[pg_stat_statements] waiting for healthcheck..."
for i in {1..30}; do
  if docker compose -f "$COMPOSE_FILE" exec -T postgres pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; then
    echo "[pg_stat_statements] postgres is healthy"
    break
  fi
  sleep 1
done

echo "[pg_stat_statements] creating extension in $POSTGRES_DB..."
docker compose -f "$COMPOSE_FILE" exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
  "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"

echo "[pg_stat_statements] verifying..."
docker compose -f "$COMPOSE_FILE" exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
  "SELECT extname, extversion FROM pg_extension WHERE extname='pg_stat_statements';"
docker compose -f "$COMPOSE_FILE" exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
  "SHOW shared_preload_libraries;"

echo "[pg_stat_statements] done. Run a query and check:"
echo "  docker compose exec postgres psql -U $POSTGRES_USER -d $POSTGRES_DB -c 'SELECT count(*) FROM pg_stat_statements'"
