#!/bin/zsh
# ---------------------------------------------------------------------------
# infra/minio/setup_personas.sh
#
# Idempotent bootstrap for per-persona MinIO RBAC (PR-4 of the Keycloak
# token-passthrough plan, per-svcacct route — see INVESTIGATION.md).
#
# What it does:
#   1. Configures `mc alias` against the local MinIO using root creds.
#   2. Creates buckets declared in bucket_policies.yaml (idempotent).
#   3. Renders one MinIO IAM policy JSON per policy entry; uploads via
#      `mc admin policy create` (replaces existing on re-run).
#   4. For each persona, mints a MinIO service-account, attaches the
#      mapped policy, and writes the (access_key, secret_key) to
#      infra/minio/persona_service_accounts.json (gitignored).
#
# Re-run-safe: existing svcaccts for a persona are detected via a
# stable comment field and rotated only when --rotate is passed.
#
# Requirements: zsh, mc (>= RELEASE.2024-10-08), yq (mikefarah v4),
# jq, openssl. Does NOT require docker on the host running this script
# (mc talks to MinIO over HTTP).
# ---------------------------------------------------------------------------

set -euo pipefail

# --- Config ----------------------------------------------------------------
SCRIPT_DIR="${0:A:h}"
SPEC_FILE="${SCRIPT_DIR}/bucket_policies.yaml"
SVCACCT_FILE="${SCRIPT_DIR}/persona_service_accounts.json"

MINIO_ALIAS="${MINIO_ALIAS:-stac-local}"
MINIO_URL="${MINIO_URL:-http://127.0.0.1:9000}"
MINIO_ROOT_USER="${MINIO_ROOT_USER:-stac_minio}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-stac_minio_dev_pw}"
SVCACCT_TAG="stac-persona-svcacct"  # stable marker on the svcacct comment

ROTATE=0
for arg in "$@"; do
  case "$arg" in
    --rotate) ROTATE=1 ;;
    --help|-h)
      print "Usage: $0 [--rotate]"
      print "  --rotate  recreate every persona's service-account (new keys)"
      exit 0
      ;;
  esac
done

# --- Pre-flight -----------------------------------------------------------
require_bin() {
  if ! command -v "$1" >/dev/null 2>&1; then
    print -u2 "error: required binary '$1' not on PATH"
    exit 1
  fi
}
require_bin mc
require_bin yq
require_bin jq
require_bin openssl

if [[ ! -f "$SPEC_FILE" ]]; then
  print -u2 "error: spec file not found: $SPEC_FILE"
  exit 1
fi

# --- mc alias --------------------------------------------------------------
print "[1/4] configuring mc alias '$MINIO_ALIAS' -> $MINIO_URL"
mc alias set --quiet "$MINIO_ALIAS" "$MINIO_URL" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null

# --- Buckets ---------------------------------------------------------------
print "[2/4] creating buckets"
bucket_count=$(yq '.buckets | length' "$SPEC_FILE")
for ((i=0; i<bucket_count; i++)); do
  name=$(yq ".buckets[$i].name" "$SPEC_FILE")
  mc mb --ignore-existing "${MINIO_ALIAS}/${name}" >/dev/null
  print "  - bucket '$name' ok"
done

# --- Policies --------------------------------------------------------------
# Render one policy doc per entry in .policies and upload via mc.
# Policy JSON shape:
#   readonly  -> Allow s3:GetObject + s3:ListBucket on bucket arn
#   readwrite -> Allow s3:* on bucket arn (Get/List/Put/Delete/Abort/MultipartUpload)
#   denied    -> Deny s3:* on bucket arn (explicit, defense in depth)
render_policy_doc() {
  local policy_name="$1"
  local rw_buckets ro_buckets denied_buckets
  rw_buckets=$(yq -o=json ".policies[\"$policy_name\"].readwrite // []" "$SPEC_FILE")
  ro_buckets=$(yq -o=json ".policies[\"$policy_name\"].readonly // []" "$SPEC_FILE")
  denied_buckets=$(yq -o=json ".policies[\"$policy_name\"].denied // []" "$SPEC_FILE")

  jq -n \
    --argjson rw "$rw_buckets" \
    --argjson ro "$ro_buckets" \
    --argjson dn "$denied_buckets" \
    '
    def bucket_arns(buckets): buckets | map("arn:aws:s3:::" + .);
    def object_arns(buckets): buckets | map("arn:aws:s3:::" + . + "/*");

    def rw_stmts(buckets):
      if (buckets | length) == 0 then []
      else [
        {Effect:"Allow",
         Action:["s3:ListBucket","s3:GetBucketLocation"],
         Resource: bucket_arns(buckets)},
        {Effect:"Allow",
         Action:["s3:GetObject","s3:PutObject","s3:DeleteObject",
                 "s3:AbortMultipartUpload","s3:ListMultipartUploadParts"],
         Resource: object_arns(buckets)}
      ] end;

    def ro_stmts(buckets):
      if (buckets | length) == 0 then []
      else [
        {Effect:"Allow",
         Action:["s3:ListBucket","s3:GetBucketLocation"],
         Resource: bucket_arns(buckets)},
        {Effect:"Allow",
         Action:["s3:GetObject"],
         Resource: object_arns(buckets)}
      ] end;

    def deny_stmts(buckets):
      if (buckets | length) == 0 then []
      else [
        {Effect:"Deny",
         Action:["s3:*"],
         Resource: (bucket_arns(buckets) + object_arns(buckets))}
      ] end;

    {
      Version:"2012-10-17",
      Statement: (rw_stmts($rw) + ro_stmts($ro) + deny_stmts($dn))
    }'
}

print "[3/4] creating IAM policies"
policy_names=("${(@f)$(yq '.policies | keys | .[]' "$SPEC_FILE")}")
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

for policy_name in "${policy_names[@]}"; do
  doc_file="${tmp_dir}/${policy_name}.json"
  render_policy_doc "$policy_name" > "$doc_file"
  # `mc admin policy create` is upsert-y in modern mc; older versions
  # error if the policy exists, so we delete-then-create for idempotency.
  mc admin policy rm "$MINIO_ALIAS" "$policy_name" >/dev/null 2>&1 || true
  mc admin policy create "$MINIO_ALIAS" "$policy_name" "$doc_file" >/dev/null
  print "  - policy '$policy_name' ok"
done

# --- Per-persona service accounts -----------------------------------------
# Service-account add returns the new (access_key, secret_key) on stdout
# in JSON when --json is passed. Persist to persona_service_accounts.json
# with structure:
#   { "<persona>": { "access_key": "...", "secret_key": "...",
#                    "policy": "...", "created_at": "..." }, ... }

random_key() { openssl rand -hex 10 | tr 'a-f' 'A-F'; }     # 20 upper-hex
random_secret() { openssl rand -base64 30 | tr -d '/+=' | cut -c1-40; }

print "[4/4] minting per-persona service accounts"

# Load existing file if present so we can merge across re-runs.
existing="{}"
if [[ -f "$SVCACCT_FILE" ]]; then
  existing=$(cat "$SVCACCT_FILE")
fi

new_state="$existing"
personas=("${(@f)$(yq '.persona_policy_map | keys | .[]' "$SPEC_FILE")}")

for persona in "${personas[@]}"; do
  policy=$(yq ".persona_policy_map[\"$persona\"]" "$SPEC_FILE")
  has_existing=$(jq -r --arg p "$persona" 'has($p)' <<<"$new_state")

  if [[ "$has_existing" == "true" && "$ROTATE" -ne 1 ]]; then
    # Already provisioned and not rotating — re-attach policy in case
    # the policy doc was edited; the (access_key, secret_key) stays.
    ak=$(jq -r --arg p "$persona" '.[$p].access_key' <<<"$new_state")
    mc admin policy attach "$MINIO_ALIAS" "$policy" --user "$ak" >/dev/null 2>&1 || true
    print "  - $persona: existing svcacct retained ($ak)"
    continue
  fi

  # Need a fresh svcacct. If rotating, remove the prior one first.
  if [[ "$has_existing" == "true" ]]; then
    old_ak=$(jq -r --arg p "$persona" '.[$p].access_key' <<<"$new_state")
    mc admin user svcacct rm "$MINIO_ALIAS" "$old_ak" >/dev/null 2>&1 || true
  fi

  ak=$(random_key)
  sk=$(random_secret)
  # Note: --policy attaches the named policy; --comment carries the
  # SVCACCT_TAG marker so a future cleanup can find STAC-managed accts.
  mc admin user svcacct add "$MINIO_ALIAS" "$MINIO_ROOT_USER" \
    --access-key "$ak" --secret-key "$sk" \
    --policy "/dev/stdin" \
    --comment "${SVCACCT_TAG}:${persona}:${policy}" >/dev/null \
    < <(render_policy_doc "$policy")

  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  new_state=$(jq \
    --arg p "$persona" --arg ak "$ak" --arg sk "$sk" \
    --arg pol "$policy" --arg ts "$ts" \
    '.[$p] = {access_key:$ak, secret_key:$sk, policy:$pol, created_at:$ts}' \
    <<<"$new_state")

  print "  - $persona: minted svcacct ($ak) -> policy '$policy'"
done

# Write back atomically (tmp + mv).
tmp_out=$(mktemp)
print -- "$new_state" | jq '.' > "$tmp_out"
mv "$tmp_out" "$SVCACCT_FILE"
chmod 600 "$SVCACCT_FILE"

print ""
print "done. ${#personas[@]} persona(s) provisioned."
print "service-account map written to: $SVCACCT_FILE (gitignored)"
