#!/bin/zsh
# bootstrap.sh — one-command Argus setup for Apple Silicon Macs.
#
# What this does:
#   1. Verifies platform (macOS + Apple Silicon)
#   2. Verifies Docker Desktop + Python 3.10+ are present and running
#   3. Creates .venv and pip-installs Argus + mlx-lm
#   4. Confirms mlx-lm sees the GPU
#   5. Starts the 7-service enterprise stack via docker compose
#   6. Waits for every service to report healthy
#   7. Prints next-step commands
#
# Idempotent — safe to re-run. Failures explain how to recover.
#
# Usage:  ./bootstrap.sh

set -euo pipefail

# ---------- presentation helpers ----------
if [[ -t 1 ]]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
  BLUE=$'\033[34m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; RESET=""
fi

step()    { print "${BLUE}${BOLD}==>${RESET} $1"; }
ok()      { print "    ${GREEN}OK${RESET} $1"; }
warn()    { print "    ${YELLOW}!!${RESET} $1"; }
fatal()   { print "${RED}${BOLD}FATAL:${RESET} $1" 1>&2; print "" 1>&2; print "$2" 1>&2; exit 1; }

ARGUS_ROOT="${0:A:h}"
cd "${ARGUS_ROOT}"

print "${BOLD}Argus bootstrap${RESET} — Apple Silicon Mac install"
print "Repo: ${ARGUS_ROOT}"
print ""

# ---------- 1. Platform preflight ----------
step "Verifying platform"
if [[ "$(uname -s)" != "Darwin" ]]; then
  fatal "Argus requires macOS." "Detected: $(uname -s). Windows and Linux are out of scope for v1."
fi
ok "macOS detected"

if [[ "$(uname -m)" != "arm64" ]]; then
  fatal "Argus requires Apple Silicon (M-series)." \
        "Detected: $(uname -m). Intel Macs are unsupported because mlx-lm has no fallback path."
fi
ok "Apple Silicon detected ($(uname -m))"

OS_VERSION=$(sw_vers -productVersion)
OS_MAJOR=${OS_VERSION%%.*}
if (( OS_MAJOR < 14 )); then
  warn "macOS ${OS_VERSION} detected; recommended is 14+. Proceeding, but mlx-lm may misbehave."
else
  ok "macOS ${OS_VERSION}"
fi

# ---------- 2. Docker preflight ----------
step "Verifying Docker"
if ! command -v docker >/dev/null 2>&1; then
  fatal "Docker not found in PATH." \
        "Install Docker Desktop from https://www.docker.com/products/docker-desktop/ then re-run."
fi
ok "docker binary found at $(command -v docker)"

if ! docker info >/dev/null 2>&1; then
  fatal "Docker daemon not running." \
        "Launch Docker Desktop (open -a Docker), wait for it to finish starting, then re-run."
fi
DOCKER_VERSION=$(docker version --format '{{.Server.Version}}')
ok "Docker daemon up (${DOCKER_VERSION})"

if ! docker compose version >/dev/null 2>&1; then
  fatal "docker compose not available." \
        "Update Docker Desktop to a recent release; 'docker compose' is bundled with v20.10+."
fi
ok "docker compose available"

# ---------- 3. Python preflight ----------
step "Verifying Python 3.10+"
PYTHON_BIN=""
for candidate in python3.13 python3.12 python3.11 python3.10 python3; do
  if command -v "${candidate}" >/dev/null 2>&1; then
    if "${candidate}" -c "import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)" 2>/dev/null; then
      PYTHON_BIN="${candidate}"
      break
    fi
  fi
done
if [[ -z "${PYTHON_BIN}" ]]; then
  fatal "Python 3.10 or newer not found." \
        "Install with: brew install python@3.12  (or download from python.org). Then re-run."
fi
PY_VERSION=$(${PYTHON_BIN} --version 2>&1 | awk '{print $2}')
ok "${PYTHON_BIN} (${PY_VERSION})"

# ---------- 4. venv + pip install ----------
step "Setting up virtual environment"
if [[ ! -d .venv ]]; then
  ${PYTHON_BIN} -m venv .venv
  ok "Created .venv"
else
  ok ".venv already exists"
fi

# shellcheck source=/dev/null
source .venv/bin/activate

print "    Installing/updating pip..."
pip install --quiet --upgrade pip

if ! pip show argus-safety >/dev/null 2>&1; then
  print "    Installing Argus + mlx-lm (this may take a minute)..."
  pip install --quiet -e ".[dev]"
  ok "Installed argus-safety (editable)"
else
  print "    Re-syncing local install..."
  pip install --quiet -e ".[dev]"
  ok "argus-safety up to date"
fi

# ---------- 5. mlx-lm GPU check ----------
step "Verifying mlx-lm Metal device"
GPU_INFO=$(python -c "import mlx.core as mx; d = mx.default_device(); print(d)" 2>&1) || \
  fatal "mlx-lm failed to import." \
        "Output: ${GPU_INFO}. Try: pip install --upgrade mlx-lm"
ok "${GPU_INFO}"

# ---------- 6. Enterprise stack ----------
step "Starting enterprise stack (7 services)"
cd infra
if [[ ! -f .env ]]; then
  cp .env.example .env
  ok "Created infra/.env from .env.example"
fi

make up >/dev/null
ok "docker compose up -d issued"

# ---------- 7. Health check loop ----------
step "Waiting for services to report healthy (up to 3 minutes)"
SERVICES=(keycloak postgres gitea minio mailpit opensearch)
DEADLINE=$(( $(date +%s) + 180 ))

while true; do
  ALL_OK=true
  PENDING=()
  for svc in "${SERVICES[@]}"; do
    state=$(docker inspect --format '{{.State.Health.Status}}' "argus-${svc}" 2>/dev/null \
            || docker inspect --format '{{.State.Health.Status}}' "stac-${svc}" 2>/dev/null \
            || echo "missing")
    if [[ "${state}" != "healthy" ]]; then
      ALL_OK=false
      PENDING+=("${svc}:${state}")
    fi
  done
  if [[ "${ALL_OK}" == "true" ]]; then
    ok "All 6 services healthy (keycloak postgres gitea minio mailpit opensearch)"
    break
  fi
  if (( $(date +%s) > DEADLINE )); then
    warn "Timed out waiting for: ${PENDING[*]}"
    warn "Check 'make logs' in the infra/ directory for details. Bootstrap continues."
    break
  fi
  sleep 5
done

cd "${ARGUS_ROOT}"

# ---------- 8. Next steps ----------
print ""
print "${GREEN}${BOLD}✓ Argus is ready.${RESET}"
print ""
print "Next steps:"
print "  ${BOLD}1.${RESET} Test the gateway in isolation (downloads ~140 GB base model on first run):"
print "      ${BLUE}source .venv/bin/activate${RESET}"
print "      ${BLUE}python examples/quickstart.py${RESET}"
print ""
print "  ${BOLD}2.${RESET} Run the full eval pipeline against 198 corpus/v1 adversarial probes:"
print "      ${BLUE}python examples/run_eval.py --limit 20${RESET}    # quick smoke (~5 min)"
print "      ${BLUE}python examples/run_eval.py${RESET}                # full run (~30 min)"
print ""
print "  ${BOLD}3.${RESET} Inspect the enterprise stack:"
print "      Keycloak:    http://localhost:8080  (admin / admin)"
print "      Gitea:       http://localhost:3000"
print "      MinIO:       http://localhost:9001"
print "      Mailpit:     http://localhost:8025"
print "      OpenSearch:  http://localhost:9200"
print ""
print "  ${BOLD}4.${RESET} Stop the stack when finished (preserves volumes):"
print "      ${BLUE}cd infra && make down${RESET}"
print ""
print "Documentation: ${BLUE}https://github.com/proband-xyz/argus${RESET}"
