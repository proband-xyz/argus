# Keycloak realm.json — RBAC token-passthrough additions

Tracks the additive edits applied to `infra/keycloak/realm.json` for PR-1 of the
plan at `docs/plans/rbac_token_passthrough.md`. The realm name (`enterprise`),
all 8 users, all 4 realm-roles, all 3 groups, and all existing dev passwords are
preserved verbatim. The edits are strictly additive: client scopes, protocol
mappers, and one `attributes` block per user.

## What was added and why

### 1. Per-user `stac_minio_policy` attribute (8 users)

Each persona now carries a `stac_minio_policy` user attribute used by the
attribute-mapper below to surface a deterministic MinIO IAM policy name in the
JWT. Mapping (per plan §1):

| Realm role  | `stac_minio_policy` value | Personas                                       |
|-------------|---------------------------|------------------------------------------------|
| helpdesk    | `helpdesk-readonly`       | alice.helpdesk, bob.helpdesk, carol.helpdesk   |
| manager     | `manager-rw`              | dave.manager, erin.manager                     |
| it-admin    | `itadmin-fullaccess`      | frank.itadmin, grace.itadmin                   |
| compliance  | `compliance-readonly`     | henry.compliance                               |

This keeps the policy-derivation logic entirely declarative inside the realm
import — no `script-protocol-mapper` (which Keycloak 26 still ships, but only
behind the `--features=scripts` preview flag), and no runtime sidecar.

> TODO (post PR-1): once `config/personas.yaml` is the single source of truth,
> generate this block from that file at `make bootstrap` time so the realm.json
> attributes can't drift from the persona schema.

### 2. Three marker client scopes

Added to `clientScopes[]`:

- `kc-admin-readonly`
- `minio-exports-rw`
- `gitea-repo-read`

These are intentionally empty (no protocol mappers of their own). They are
attached to `stac-agent` as **default** client scopes so every issued
access_token includes them in the `scope` claim. Downstream services that
inspect `scope` (e.g. a future Gitea OIDC integration) can branch on these
markers without re-deriving them from realm-roles.

### 3. Five protocol mappers on the `stac-agent` client

| Mapper                       | Type                              | Emits in access_token                                          |
|------------------------------|-----------------------------------|----------------------------------------------------------------|
| `audience-minio`             | `oidc-audience-mapper`            | adds `"minio"` to `aud[]`                                      |
| `audience-gitea`             | `oidc-audience-mapper`            | adds `"gitea"` to `aud[]`                                      |
| `audience-account`           | `oidc-audience-mapper`            | adds `"account"` to `aud[]` (Keycloak admin API consumes this) |
| `stac-role-claim`            | `oidc-usermodel-realm-role-mapper`| string claim `stac_role` = realm-role name                     |
| `stac-minio-policy-claim`    | `oidc-usermodel-attribute-mapper` | string claim `stac_minio_policy` from user attribute           |

Audience mappers are the contract that lets Keycloak-issued tokens be presented
to MinIO and Gitea OIDC verifiers without `aud`-mismatch rejections. The
`account` audience covers the Keycloak admin API itself (the `kc` MCP server
hits `/admin/realms/...`, which checks `aud` against the `account` client).

`directAccessGrantsEnabled: true` on `stac-agent` is **preserved** — ROPC
remains the token-acquisition flow per plan §2.

## Expected JWT shape

After re-importing the realm and running ROPC for `alice.helpdesk`:

```bash
curl -s -X POST http://localhost:8080/realms/enterprise/protocol/openid-connect/token \
  -d client_id=stac-agent \
  -d client_secret=stac-agent-dev-secret \
  -d grant_type=password \
  -d username=alice.helpdesk \
  -d password=alice_dev_pw \
  -d 'scope=openid profile email roles' | jq -r .access_token | cut -d. -f2 | base64 -d | jq
```

decoded payload (fields elided for brevity):

```json
{
  "iss": "http://localhost:8080/realms/enterprise",
  "sub": "<uuid>",
  "aud": ["stac-agent", "minio", "gitea", "account"],
  "azp": "stac-agent",
  "typ": "Bearer",
  "preferred_username": "alice.helpdesk",
  "email": "alice.helpdesk@example.com",
  "stac_role": "helpdesk",
  "stac_minio_policy": "helpdesk-readonly",
  "scope": "openid profile email roles kc-admin-readonly minio-exports-rw gitea-repo-read",
  "realm_access": { "roles": ["helpdesk", "default-roles-enterprise"] },
  "resource_access": { "account": { "roles": ["view-profile"] } }
}
```

The exact ordering of `aud[]` may vary; what matters is that `minio` and
`gitea` are both present.

## Coordination notes for parallel agents

### MinIO agent (`setup_personas.sh`)

When wiring MinIO to Keycloak via `mc idp openid add`, use:

```bash
mc idp openid add local stac-keycloak \
  config_url="http://keycloak:8080/realms/enterprise/.well-known/openid-configuration" \
  client_id=stac-agent \
  client_secret=stac-agent-dev-secret \
  claim_name=stac_minio_policy \
  scopes="openid,profile,email,roles"
```

Critical: `claim_name=stac_minio_policy`. MinIO will look up an IAM policy
whose name **equals** that claim's string value, so the policies created by
`setup_personas.sh` MUST be named exactly:

- `helpdesk-readonly`
- `manager-rw`
- `itadmin-fullaccess`
- `compliance-readonly`

### Gitea agent

Gitea (per plan §4) does not consume Keycloak tokens directly in v1 — it uses
per-persona PATs minted at `make bootstrap`. The `gitea` audience claim is
pre-wired so that PR-4 (or whoever wires Gitea OIDC later) does not need a
realm-import bump.

### Audit-log-collector

After these mappers land, Keycloak's admin events will record a per-persona
`userId` (not the service-account UUID) and the `stac-agent` `clientId`,
which is the correlation key the audit-log-collector should join on when
attributing tool calls back to personas. The new `stac_role` claim is also
the canonical role label used in `tool_calls[].auth_denied` records — bridge
and collector should both read `stac_role` (not `realm_access.roles[*]`) for
the human-readable role name.

## Verification

```bash
python3 -c "import json; json.load(open('infra/keycloak/realm.json'))"
pytest tests/test_realm_json.py -v
```
