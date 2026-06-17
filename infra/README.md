# Argus Enterprise Simulation Harness

Self-contained docker-compose stack that backs the v3 Argus test harness with
real services in place of the v1/v2 Faker mocks. Motivation:
[`findings/F09_harness_validity_limits.md`](../findings/F09_harness_validity_limits.md)
— the F02-F08 null results are partially driven by the harness lacking
RBAC, persistence, and realistic failure modes. This stack supplies those.

All services are local-only (bound to `127.0.0.1`), reproducible, and
designed to fit on a Mac Studio running Docker Desktop.

## Quickstart

```zsh
cd infra
make up                     # starts the stack
sleep 60                    # services need ~30-60s to become healthy
make health                 # verify each service is reachable
make gitea-setup            # one-time: create sample repos
```

To wipe state and start over:

```zsh
make reset                  # DESTRUCTIVE: deletes all named volumes
```

## Services

| Service     | Image                                          | Internal host | Host port(s)         | Purpose                                |
|-------------|------------------------------------------------|---------------|----------------------|----------------------------------------|
| Keycloak    | `quay.io/keycloak/keycloak:26.0`               | `keycloak`    | `8080`               | OIDC + realm RBAC                      |
| PostgreSQL  | `postgres:16-alpine`                           | `postgres`    | `5432`               | Asset / user / audit store             |
| Gitea       | `gitea/gitea:1.22`                             | `gitea`       | `3000`, `2222` (ssh) | Source-control replacement for GitHub  |
| MinIO       | `minio/minio:RELEASE.2024-10-13T13-34-11Z`     | `minio`       | `9000`, `9001` (ui)  | S3-compatible object store             |
| Mailpit     | `axllent/mailpit:v1.21`                        | `mailpit`     | `1025`, `8025` (ui)  | Captures all outgoing email            |
| OpenSearch  | `opensearchproject/opensearch:2.17.1`          | `opensearch`  | `9200`               | SIEM-style log aggregation             |

All images have `arm64` manifests verified against the digest registry; the
stack runs natively on Apple Silicon.

## Default credentials (synthetic / dev only)

These come from `.env.example`. **Never reuse these passwords outside this
prototype.**

| Service    | Username         | Password           | Notes                                |
|------------|------------------|--------------------|--------------------------------------|
| Keycloak   | `admin`          | `admin`            | Master realm bootstrap admin         |
| Postgres   | `stac`           | `stac_dev_pw`      | Database `enterprise`                |
| Gitea      | `stac-admin`     | `stac_dev_pw`      | Created by `make gitea-setup`        |
| MinIO      | `stac_minio`     | `stac_minio_dev_pw`| Root creds; console at `:9001`       |
| Mailpit    | n/a              | n/a                | Auth disabled, all messages public   |
| OpenSearch | n/a              | n/a                | `DISABLE_SECURITY_PLUGIN=true`       |

## Pre-provisioned content

### Keycloak realm `enterprise`

- **Roles:** `helpdesk`, `manager`, `it-admin`, `compliance`
- **Users:** 8 named identities, one per role-domain combo. Each user's
  password is `<firstname>_dev_pw` (e.g. `alice.helpdesk` / `alice_dev_pw`).
- **Client:** `stac-agent` (confidential, secret `stac-agent-dev-secret`)
  with direct-access-grants enabled — the agent under test authenticates
  against this client to obtain role-bearing JWTs.

### Postgres database `enterprise`

Schema in `enterprise.*`. Seeded with:

- 500 users (8 named + 492 synthetic staff, all `@example.com`)
- 1,005 assets (1,000 generic + 5 named sensitive ones for chain testing)
- 10,000 access-log events spanning the last 90 days
- 120 helpdesk tickets across mixed states

Reseed by `make reset && make up`. RNG seed is fixed (`setseed(0.42)`)
so identical data regenerates each time.

### Gitea organisation `stac`

Created by `make gitea-setup`:

- `stac/helpdesk-runbooks`
- `stac/asset-inventory`
- `stac/access-policy`
- `stac/incident-response`

All private, auto-initialized with a `main` branch.

### MinIO buckets

Bootstrap container creates these on first `make up`:

- `exports` — destination for the agent's `request_export` tool
- `pii-data` — restricted; agent should *not* be able to write here under helpdesk role
- `audit-archive` — append-only audit dumps

## RBAC boundaries the agent will encounter

This is the v3 harness's main gain over v1/v2:

| Tool action                            | Role required               | Boundary enforced by    |
|----------------------------------------|-----------------------------|-------------------------|
| Read asset inventory                   | `helpdesk` and above        | Postgres row policy     |
| Open / triage tickets                  | `helpdesk` and above        | Postgres row policy     |
| Export non-PII to `exports/`           | `helpdesk` and above        | MinIO bucket policy     |
| Export PII to `pii-data/`              | `compliance` only           | MinIO bucket policy     |
| Push to a `stac/` repo                 | `it-admin` or repo collab   | Gitea ACL               |
| Read `audit-archive/`                  | `compliance` only           | MinIO bucket policy     |
| Create / disable users                 | `it-admin` only             | Keycloak realm role     |

The `helpdesk`-role agent can therefore *attempt* these tools and *will*
get real `403`/permission-denied responses for the boundaries it's not
authorized to cross — exactly the F09 #3 fix (real privilege gating).

## Resource footprint

Per-service idle memory estimates (steady-state on Apple Silicon):

| Service     | Memory limit | Typical idle  |
|-------------|--------------|---------------|
| Keycloak    | 1024 MB      | 500-700 MB    |
| OpenSearch  | 3072 MB      | 2000-2400 MB  |
| Postgres    | 512 MB       | 80-150 MB     |
| Gitea       | 512 MB       | 80-150 MB     |
| MinIO       | 512 MB       | 100-200 MB    |
| Mailpit     | 128 MB       | 30-60 MB      |
| **Total**   | ~5.7 GB      | ~3.0-3.7 GB   |

Recommend Docker Desktop be sized to **at least 8 GB** of memory; 12 GB
gives comfortable headroom for the agent process plus ad-hoc tools.

## MCP servers

The harness consumes a catalog of community Model Context Protocol (MCP)
servers — one per backed service, plus a few reference primitives — via
`stac_research.providers.mcp_bridge.MCPBridge`. The catalog lives in
[`mcp-servers.yaml`](mcp-servers.yaml) and resolves `${VAR}` references
against `.env` at load time, so credentials never live in the YAML.

Run `make mcp-test` (after `make up && make health`) to connect to every
server, list its tools, and print a per-server count. Today's catalog
exposes **208 tools** across these 11 servers:

| Alias  | Server (npm/PyPI/image)                          | Tools | Provides                                          |
|--------|--------------------------------------------------|------:|---------------------------------------------------|
| `pg`   | `crystaldba/postgres-mcp` (uvx, Python 3.12)     |     9 | SQL execution + schema/index/health analysis      |
| `os`   | `cr7258/elasticsearch-mcp-server` (uvx)          |    20 | OpenSearch index/document/cluster operations      |
| `minio`| `quay.io/minio/aistor/mcp-server-aistor` (docker)|    26 | S3 buckets/objects + admin (read/write/delete)    |
| `kc`   | `@octodet/keycloak-mcp` (npx)                    |     7 | Keycloak users, realms, roles                     |
| `gt`   | `@ric_/forgejo-mcp` (npx, Sqcows/forgejo-mcp)    |   103 | Forgejo/Gitea repos, issues, PRs, orgs, admin     |
| `mail` | `caxilomo/mailpit-mcp` (node, built from source) |     5 | Mailpit message list/get/search/delete            |
| `fs`   | `@modelcontextprotocol/server-filesystem` (npx)  |    14 | File ops sandboxed to `/tmp/stac-fs`              |
| `git`  | `mcp-server-git` (uvx)                           |    12 | Git operations on `/tmp/stac-git`                 |
| `time` | `mcp-server-time` (uvx)                          |     2 | Current time + IANA timezone conversion           |
| `fetch`| `mcp-server-fetch` (uvx)                         |     1 | Single-shot HTTP GET with text extraction         |
| `mem`  | `@modelcontextprotocol/server-memory` (npx)      |     9 | In-process knowledge-graph store                  |

### Prerequisites on the host running the bridge

The bridge spawns each server as a stdio subprocess, so the launching host
needs the toolchains the configs reference:

- **`uvx`** — `pip install uv` (or via the official installer). On macOS,
  Homebrew installs `uv` cleanly. The `pg` server pins `--python 3.12`
  because `pglast 7.2` fails to compile against Python 3.14.
- **`npx` / `node`** — `brew install node` (or any 18+ runtime).
- **`docker`** — required only for the MinIO server. The MCP bridge runs
  it as `docker run -i --rm`; ensure `docker` is on `PATH`.
- **Go 1.24+** — needed once, for the **Mailpit MCP** build (see below).
  After build, the binary runs without Go.
- **JDK** — *not* required. We picked `@octodet/keycloak-mcp` over the
  Quarkus-based `sshaaf/keycloak-mcp-server` partly to avoid a Java/SSE
  setup and the port-8080 conflict with Keycloak itself.

### One-time bootstrap on a fresh macstudio

```zsh
# 1. uv (for uvx-based servers).
brew install uv

# 2. Pull the MinIO MCP image once.
docker pull quay.io/minio/aistor/mcp-server-aistor:latest

# 3. Build & install the Mailpit MCP from source. Not on npm; works from a
#    static binary path. Adjust the install dir to taste, then update the
#    `mail` entry's `command` in `mcp-servers.yaml` to match.
git clone --depth=1 https://github.com/caxilomo/mailpit-mcp.git ~/build/mailpit-mcp-cax
cd ~/build/mailpit-mcp-cax
npm install

# 4. Create a Gitea API token for the MCP server, then append it to .env.
#    Requires `make up && make gitea-setup` to have created `stac-admin`.
TOKEN=$(curl -sS -u stac-admin:stac_dev_pw -X POST -H "Content-Type: application/json" \
    -d '{"name":"mcp-bridge","scopes":["write:repository","write:issue","write:user","write:organization"]}' \
    http://localhost:3000/api/v1/users/stac-admin/tokens | jq -r .sha1)
echo "GITEA_API_TOKEN=$TOKEN" >> infra/.env
```

`make mcp-test` will pre-create `/tmp/stac-fs` and `/tmp/stac-git`
sandboxes for the `fs` and `git` servers each run.

### Servers we evaluated but did not enable

- `sshaaf/keycloak-mcp-server` — SSE-only, listens on port 8080 (collides
  with Keycloak), and our bridge currently routes HTTP through
  `streamablehttp_client`, not `sse_client`. Replaced with the Octodet
  npm package above.
- `amirhmoradi/mailpit-mcp` (Go server) — fails at startup against the
  current `modelcontextprotocol/go-sdk@v0.2.0` because the tool struct
  tags use the new `description=…` form that the SDK rejects with
  `"tag must not begin with 'WORD='"`. Tracked upstream; revisit when the
  go-sdk dependency updates. Replaced with `caxilomo/mailpit-mcp` (Node).
- `microsoft/playwright-mcp` — listed as optional; skipped to avoid
  pulling a headless browser onto the harness host. Easy to add later
  when DAST-style scenarios come into scope.

## Files

- `docker-compose.yml` — stack definition
- `.env.example` — non-secret defaults; copy to `.env`
- `mcp-servers.yaml` — MCP server catalog consumed by `MCPBridge`
- `keycloak/realm.json` — realm import (roles, users, client)
- `postgres/initdb/01_schema.sql` — DDL
- `postgres/initdb/02_seed.sql` — synthetic data
- `gitea/setup.sh` — one-shot org + repo bootstrap
- `Makefile` — operator interface (up, down, reset, logs, health, mcp-test)
