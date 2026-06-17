# AIStor MCP server — STS / OIDC support investigation

**Date:** 2026-05-09
**Author:** RBAC PR-4 prep
**Question:** Does the official MinIO AIStor MCP server (`quay.io/minio/aistor/mcp-server-aistor:latest`, configured at `infra/mcp-servers.yaml` alias `minio`) support OIDC `AssumeRoleWithWebIdentity`-derived credentials, or does it only accept static root/access keys?

## Verdict

**No OIDC / STS support.** The AIStor MCP server only accepts static
`MINIO_ACCESS_KEY` + `MINIO_SECRET_KEY` env vars at startup; there is no
documented JWT / OIDC / `AssumeRoleWithWebIdentity` / session-token path.

### Evidence

The published documentation (project README and the MinIO docs site
section for the MCP server) lists exactly four credential / connection
env vars:

- `MINIO_ENDPOINT`
- `MINIO_ACCESS_KEY`
- `MINIO_SECRET_KEY`
- `MINIO_USE_SSL`

And the following startup flags:

- `--allowed-directories`
- `--allow-write` / `--allow-delete` / `--allow-admin`
- `--max-keys`
- `--http` / `--http-port`

There is no flag or env var that accepts:

- An OIDC IdP URL or client id/secret
- A pre-fetched JWT/ID-token
- An STS endpoint or `AssumeRoleWithWebIdentity` config
- A session-token (the third element of an STS triple)

The implication: even if the underlying MinIO server is configured for
OIDC and we can mint per-persona STS credentials with
`AssumeRoleWithWebIdentity`, the AIStor MCP container has nowhere to
plug a session-token. The `mc` CLI accepts `--session-token` (and
`MINIO_SESSION_TOKEN` env) but the MCP server uses the Go SDK
internally with a hard-coded static-credentials provider.

## Implication for PR-4

Drop the OIDC route. Use the **per-persona MinIO service-account**
strategy instead, mirroring the per-persona Gitea PAT plan from PR-3:

1. At bootstrap, for each Keycloak persona, create a MinIO IAM
   service-account (`mc admin user svcacct add`) attached to the
   persona's policy. Capture the `(access_key, secret_key)` pair.
2. Persist the mapping to `infra/minio/persona_service_accounts.json`
   (gitignored, dev-only).
3. The MCP bridge (PR-2 territory, not this PR) uses the persona
   binding to inject the right access/secret pair into the AIStor MCP
   container's env on a per-(alias, persona) spawn — same pattern that
   PR-2 already establishes for `kc` (`KEYCLOAK_ADMIN={{persona_username}}`).

Detection signal is preserved: a persona attempting an out-of-policy
operation gets `AccessDenied` from MinIO, which the bridge classifies
as `auth_denied: true` exactly the same way it would for an OIDC-403.
The only thing we lose is the *audit trail* showing the Keycloak token
identity at the MinIO side — the access-key alone shows up. We
compensate by keeping the persona → access-key mapping in JSONL audit
records.

## Future-work option

If/when AIStor MCP gains OIDC support (or we swap in a different MCP
server that does), revisit. The Keycloak realm changes required for
OIDC are listed as TODOs in `realm.json` so the protocol-mapper is
ready when the server is.
