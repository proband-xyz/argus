#!/bin/zsh
#
# Bootstrap script for the local Gitea instance.
# Run AFTER `make up` has brought the stack to healthy state.
#
# What this does:
#   1. Creates an initial admin user inside the Gitea container.
#   2. Creates a "stac" organisation.
#   3. Creates 4 sample repos under that org (synthetic content).
#
# Idempotent: safe to re-run; existing entities yield 422 from Gitea
# and are skipped.
#
# Requires: docker, curl, jq.

set -euo pipefail

# ---------- config ----------
SCRIPT_DIR=${0:A:h}
ENV_FILE=${SCRIPT_DIR}/../.env

if [[ -f $ENV_FILE ]]; then
    # shellcheck disable=SC1090
    source $ENV_FILE
fi

GITEA_URL=${GITEA_URL:-http://localhost:3000}
GITEA_CONTAINER=${GITEA_CONTAINER:-stac-gitea}
ADMIN_USER=${GITEA_ADMIN_USER:-stac-admin}
ADMIN_PASSWORD=${GITEA_ADMIN_PASSWORD:-stac_dev_pw}
ADMIN_EMAIL=${GITEA_ADMIN_EMAIL:-stac-admin@example.com}
ORG_NAME=${GITEA_ORG:-stac}

REPOS=(
    "helpdesk-runbooks:Internal helpdesk runbooks (synthetic)."
    "asset-inventory:Asset inventory automation scripts (synthetic)."
    "access-policy:Access-control policy as code (synthetic)."
    "incident-response:Incident response playbooks (synthetic)."
)

# ---------- helpers ----------
log() { print -P "%F{cyan}[gitea-setup]%f $*"; }
warn() { print -P "%F{yellow}[gitea-setup]%f $*"; }

api() {
    local method=$1
    local path=$2
    local data=${3:-}
    if [[ -n $data ]]; then
        curl -sS -o /dev/null -w "%{http_code}" -X $method \
            -u "${ADMIN_USER}:${ADMIN_PASSWORD}" \
            -H "Content-Type: application/json" \
            -d $data \
            "${GITEA_URL}/api/v1${path}"
    else
        curl -sS -o /dev/null -w "%{http_code}" -X $method \
            -u "${ADMIN_USER}:${ADMIN_PASSWORD}" \
            "${GITEA_URL}/api/v1${path}"
    fi
}

# ---------- 1. Create admin user inside the container ----------
log "Ensuring admin user '${ADMIN_USER}' exists..."

if docker exec -u git $GITEA_CONTAINER \
    gitea admin user list 2>/dev/null | grep -q "^[0-9]\+ \+${ADMIN_USER} "; then
    log "Admin user already exists; skipping creation."
else
    docker exec -u git $GITEA_CONTAINER \
        gitea admin user create \
            --username $ADMIN_USER \
            --password $ADMIN_PASSWORD \
            --email $ADMIN_EMAIL \
            --admin \
            --must-change-password=false \
        || warn "Admin user creation returned non-zero — may already exist."
fi

# ---------- 2. Wait for API readiness ----------
log "Probing API at ${GITEA_URL}..."
for i in {1..30}; do
    if curl -fsS "${GITEA_URL}/api/healthz" >/dev/null 2>&1; then
        log "API ready."
        break
    fi
    sleep 1
done

# ---------- 3. Create the org ----------
log "Creating organisation '${ORG_NAME}'..."
status=$(api POST /orgs "{\"username\":\"${ORG_NAME}\",\"full_name\":\"Argus Synthetic Org\",\"visibility\":\"private\"}")
case $status in
    201) log "Org created." ;;
    422) log "Org already exists; skipping." ;;
    *)   warn "Unexpected status creating org: ${status}" ;;
esac

# ---------- 4. Create the repos ----------
for entry in $REPOS; do
    name=${entry%%:*}
    description=${entry#*:}
    log "Creating repo '${ORG_NAME}/${name}'..."
    payload="{\"name\":\"${name}\",\"description\":\"${description}\",\"private\":true,\"auto_init\":true,\"default_branch\":\"main\"}"
    status=$(api POST "/orgs/${ORG_NAME}/repos" $payload)
    case $status in
        201) log "  created." ;;
        409|422) log "  already exists; skipping." ;;
        *)   warn "  unexpected status: ${status}" ;;
    esac
done

log "Gitea bootstrap complete."
log "Web UI:  ${GITEA_URL}"
log "Admin:   ${ADMIN_USER} / ${ADMIN_PASSWORD}"
log "Org:     ${ORG_NAME} (with ${#REPOS} repos)"
