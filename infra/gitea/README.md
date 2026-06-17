# Gitea — RBAC bootstrap for Argus personas

This directory holds Gitea-side bootstrap material for the per-persona
RBAC story (`docs/plans/rbac_token_passthrough.md`, PR-3).

## Is Gitea OIDC-integrated with Keycloak?

**No.** As of this writing, the Gitea service in `infra/docker-compose.yml`
runs with a stock SQLite backend and no `oauth2_*` / `OAUTH2_*` env vars.
There is no `oauth2 add-source` step in `infra/gitea/setup.sh`, and the
admin user is a local Gitea account (`stac-admin`), not a Keycloak-mirrored
identity. Consequently:

* Keycloak JWTs are **not** accepted by the Gitea API.
* The 8 Keycloak personas (`alice.helpdesk` … `henry.compliance`) **do
  not** auto-materialise as Gitea users.
* To get per-persona RBAC signal we mirror the persona model in Gitea
  itself: one local Gitea user per Keycloak persona, scoped per role
  via Personal Access Tokens.

This is the workaround documented in plan §4 ("Gitea uses its own
user/token model... functionally equivalent for detection purposes").

## What `bootstrap_gitea_pats.py` does

For each persona resolved from `config/personas.yaml` (with a fallback
to the 8-persona realm.json list when PR-1 hasn't landed yet):

1. Ensures a Gitea user exists with username matching the Keycloak
   username, email `<user>@stac.local`, and a known dev password.
2. Ensures the role's organisation exists (`helpdesk-org`,
   `engineering-org`, `it-admins-org`, `compliance-org`) and adds the
   user as a member.
3. Lists existing PATs for that user, deletes any prior token named
   `stac-persona`, and mints a fresh one with role-appropriate scopes:

   | Role         | Scopes                                       |
   |--------------|----------------------------------------------|
   | `helpdesk`   | `read:repository`, `read:user`               |
   | `manager`    | `read:repository`, `write:repository`        |
   | `it-admin`   | `admin:repo`, `admin:org`, `admin:user`      |
   | `compliance` | `read:repository`, `read:user` (read-only)   |

4. Writes the PATs to `infra/gitea/persona_pats.json` (gitignored,
   mode 0600) with shape:

   ```json
   {
     "schema_version": 1,
     "issued_at": "2026-05-09T...",
     "tokens": {"alice.helpdesk": "gtea_pat_xxx", ...}
   }
   ```

5. Prints a per-persona summary table to stdout (token values are
   **not** printed — they only land in the JSON file).

The script is idempotent: re-running it will detect existing users
and orgs (no double-create errors) and rotate the `stac-persona` PAT.

## Running it

```sh
uv run python scripts/bootstrap_gitea_pats.py \
  --gitea-url http://macstudio:3000 \
  --admin-user gitea_admin \
  --admin-password "$GITEA_ADMIN_PASSWORD"
```

Flags default to the docker-compose dev values (`http://localhost:3000`,
`stac-admin`, `stac_dev_pw`) so when running against the local stack
no flags are required:

```sh
uv run python scripts/bootstrap_gitea_pats.py
```

Other flags:

* `--user-password` — password assigned to newly-created persona users
  (dev-only synthetic; default `stac_persona_dev_pw`).
* `--personas-config` — path to `config/personas.yaml` (defaults to the
  repo path; falls back to the hardcoded 8-persona list when missing).
* `--output` — alternate path for the PAT JSON (default
  `infra/gitea/persona_pats.json`).
* `--timeout` — per-request HTTP timeout in seconds (default 10).

## How the tokens are consumed

The PAT inventory at `infra/gitea/persona_pats.json` is consumed by
`MCPBridge` once persona-binding is active (after PR-2 / PR-3 land).
Until then the file is dormant — present but not read by the bridge.

Wiring sketch (PR-3):

* `MCPBridge.bind_persona(persona, run_id)` looks up the persona's
  Gitea PAT from this JSON file.
* `infra/mcp-servers.yaml` has the `gt` server's `FORGEJO_TOKEN` env
  rewritten from `${GITEA_API_TOKEN}` to `{{persona_token:gitea}}` (or
  similar) so the per-(alias, persona) session inherits the
  role-scoped PAT.
* 401/403 responses from Gitea are tagged `auth_denied: true` in the
  `tool_calls[]` JSONL stream (plan §6), giving outcome-based ASR.

## Threat-model notes

* The PATs in `persona_pats.json` are real Gitea credentials. They are
  gitignored and written 0600. Treat them like any other dev secret.
* The user passwords are deterministic and are deliberately weak —
  this is a synthetic lab, not production.
* The `it-admins-org` membership is purely organisational; Gitea
  global admin on the persona accounts is **not** granted (only the
  bootstrap admin is global-admin).

## Open items

* Confirm the env var name the `gt` MCP server (or its replacement)
  expects when persona-binding is active. Today `mcp-servers.yaml`
  uses `FORGEJO_TOKEN`, and PR-3 plumbing will need to align.
* Once `config/personas.yaml` lands (PR-1), drop the `FALLBACK_PERSONAS`
  list in `scripts/bootstrap_gitea_pats.py` and rely solely on the YAML.
