#!/bin/zsh
# Enable Keycloak event recording on the enterprise realm.
#
# WHY: by default Keycloak does not record auth events (login,
# UPDATE_PASSWORD, ...) or admin events (admin API calls). The v3
# stack's audit_log_collector reads these via the admin API; if
# recording is off, the collector gets `admin_events_count: 0`
# regardless of what actually happened. Discovered iter_034 during
# F-D investigation when a successful `reset-user-password` left
# zero audit-event trail.
#
# This script idempotently enables events + admin events on the
# enterprise realm. Run once after the stack is up; safe to re-run.

set -eu
KC_BASE="${KEYCLOAK_BASE_URL:-http://localhost:8080}"
KC_USER="${KEYCLOAK_ADMIN_USER:-admin}"
KC_PASS="${KEYCLOAK_ADMIN_PASSWORD:-admin}"
REALM="${KEYCLOAK_REALM:-enterprise}"

echo "[configure-realm-events] enabling events on realm=${REALM} via ${KC_BASE}"

TOKEN=$(curl -fsS -X POST "${KC_BASE}/realms/master/protocol/openid-connect/token" \
  -d "grant_type=password" \
  -d "client_id=admin-cli" \
  -d "username=${KC_USER}" \
  -d "password=${KC_PASS}" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')

current=$(curl -fsS "${KC_BASE}/admin/realms/${REALM}/events/config" \
  -H "Authorization: Bearer ${TOKEN}")

events_now=$(python3 -c "import sys,json; r=json.loads(sys.argv[1]); print(r.get('eventsEnabled'), r.get('adminEventsEnabled'))" "${current}")

if [[ "${events_now}" == "True True" ]]; then
  echo "[configure-realm-events] already enabled; no-op"
  exit 0
fi

# Keep the existing enabledEventTypes; just flip the two boolean flags
# and bump expiration so events don't roll off too fast in long runs.
patched=$(python3 -c "
import sys, json
cfg = json.loads(sys.argv[1])
cfg['eventsEnabled'] = True
cfg['adminEventsEnabled'] = True
cfg['adminEventsDetailsEnabled'] = True
cfg['eventsExpiration'] = 86400
print(json.dumps(cfg))
" "${current}")

curl -fsS -X PUT "${KC_BASE}/admin/realms/${REALM}/events/config" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${patched}"

echo "[configure-realm-events] applied: eventsEnabled=${events_now} → True True"
