# Changelog

All notable changes to Argus are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] — 2026-06-17

Initial public release.

### Added

- **Gateway model**: `proband-xyz/argus-baseline-v3-prod-r2` — a LoRA adapter
  (~660 MB) on Llama-3.3-70B-Instruct-bf16, trained as a refusal gatekeeper
  in a decoupled gateway-executor architecture. Published on
  [HuggingFace Hub](https://huggingface.co/proband-xyz/argus-baseline-v3-prod-r2).
- **Two composable runtime defense layers** (Python, 31 unit tests):
  - `argus.defenses.audit_namespace_guard` — schema-layer check that blocks
    tool calls in a registered sensitive-tool set when the target principal
    matches an audit-stack pattern.
  - `argus.defenses.intent_critic` — small adversarial judge model
    (Qwen2.5-7B-Instruct-4bit by default) that reviews the gateway's
    resolved INTENT and overrides APPROVE to REJECT for forbidden actions.
- **Two probe sets** under `data/probes/`:
  - `argus_eval_v1.jsonl` — 175 broad agentic-safety probes across six
    categories (E1–E7).
  - `corpus_v1_adversarial.jsonl` — 198 MITRE ATT&CK-mapped IAM probes
    across 10 behavioral families.
- **Two runnable examples**:
  - `examples/quickstart.py` — 30-line gateway-in-isolation demo.
  - `examples/run_eval.py` — full decoupled pipeline (gateway → critic →
    executor → guard) with per-layer defense counts.
- **Enterprise stack** (`infra/`) — 7-service `docker compose` setup
  (Keycloak, PostgreSQL, Gitea, MinIO, Mailpit, OpenSearch, MinIO MC init)
  with a `Makefile` for `up`/`down`/`health`/`reset`/`logs`/`gitea-setup`/
  `mcp-test`.
- **`bootstrap.sh`** — idempotent one-command install for Apple Silicon Macs:
  platform preflight → Docker + Python check → venv + `pip install -e .[dev]`
  → mlx-lm GPU verify → stack `up` + health-wait → next-step printout.
- **Python package** `argus-safety` on PyPI. Mac-only (Apple Silicon +
  `mlx-lm`). Python 3.10+.

### Defense profile (baseline, measured at v3-prod-r2)

- Argus eval (175 probes, E1–E7): PASS 5/6 categories.
- corpus/v1 adversarial (198 probes, 10 MITRE-mapped IAM families):
  PASS — grant rate 10.1%, target-hit rate 0%.

### Known limitations

- The adapter was trained against a fixed tool registry; behavior on tools
  outside that registry is not characterized.
- Refusal-training has documented general limits; production deployments
  should stack runtime defense layers regardless of gateway-training quality.
- Hardened variants (`argus-deliberative`, `argus-constitutional`,
  `argus-rr`) are planned and will publish their own defense profiles
  when ready.

[0.1.0]: https://github.com/proband-xyz/argus/releases/tag/v0.1.0
