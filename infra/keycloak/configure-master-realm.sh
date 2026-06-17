#!/bin/zsh
# Configure the Keycloak master realm post-startup.
#
# WHY: the master realm is Keycloak's built-in administration realm.
# It is NOT imported from `realm.json` (only the `enterprise` realm
# is). Out of the box, master's `accessTokenLifespan` defaults to
# 60 seconds, which is too short for the @octodet/keycloak-mcp
# server we use as the agent's MCP-driven Keycloak interface — that
# server caches the admin token without refresh, so any tool call
# more than 60 s after the first one returns "Network response was
# not OK" (a 401 from Keycloak masked by the MCP error handler).
#
# This script idempotently bumps `accessTokenLifespan` to 3600 s on
# the master realm. Run after `docker compose up -d keycloak` and
# Keycloak is reachable on its admin port. Safe to re-run.
#
# See iter_034 (F-C investigation) for the full diagnostic trail.

set -eu
KC_BASE="${KEYCLOAK_BASE_URL:-http://localhost:8080}"
KC_USER="${KEYCLOAK_ADMIN_USER:-admin}"
KC_PASS="${KEYCLOAK_ADMIN_PASSWORD:-admin}"
TARGET_LIFESPAN="${MASTER_ACCESS_TOKEN_LIFESPAN:-3600}"

echo "[configure-master-realm] target accessTokenLifespan=${TARGET_LIFESPAN}s on ${KC_BASE}"

TOKEN=$(curl -fsS -X POST "${KC_BASE}/realms/master/protocol/openid-connect/token" \
  -d "grant_type=password" \
  -d "client_id=admin-cli" \
  -d "username=${KC_USER}" \
  -d "password=${KC_PASS}" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')

current=$(curl -fsS "${KC_BASE}/admin/realms/master" \
  -H "Authorization: Bearer ${TOKEN}" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("accessTokenLifespan",-1))')

if [[ "${current}" == "${TARGET_LIFESPAN}" ]]; then
  echo "[configure-master-realm] already at ${TARGET_LIFESPAN}s; no-op"
  exit 0
fi

curl -fsS -X PUT "${KC_BASE}/admin/realms/master" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"accessTokenLifespan\": ${TARGET_LIFESPAN}}"

echo "[configure-master-realm] applied: ${current}s → ${TARGET_LIFESPAN}s"
