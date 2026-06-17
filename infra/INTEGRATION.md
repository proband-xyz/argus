# v3 MCP integration runbook

Run a Argus chain with tools sourced from MCP servers alongside the Faker catalog.

## 1. Bring up the v3 stack

```zsh
cd infra && make up && sleep 60 && make health && make gitea-setup
```

## 2. Author `infra/mcp-servers.yaml`

Each entry validates against `McpServerConfig`
(`stac_research/providers/mcp_bridge.py`). A bare list or a `servers:` mapping is accepted.

```yaml
servers:
  - alias: postgres
    transport: stdio
    command: ["uvx", "mcp-server-postgres"]
    env:
      DATABASE_URL: "postgresql://stac:stac_dev_pw@localhost:5432/enterprise"
  - alias: gitea
    transport: http
    url: "http://localhost:3000/api/v1/mcp"
    headers:
      Authorization: "token <gitea-pat>"
```

## 3. Run a v3 chain

```zsh
python run_attack.py \
  --chains-file config/attack_chains_v3.yaml \
  --chain A_priv_recon_01 \
  --model qwen3.6:27b \
  --provider ollama \
  --mcp-config infra/mcp-servers.yaml \
  --output logs/v3-smoke
```

The harness unions Faker + MCP tool catalogs per turn and routes each call by name. Bridge sessions tear down via `bridge.close()` in a `finally` block.
