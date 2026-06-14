# Hermes Agent + WebUI Docker Compose

Production Docker Compose setup for [Hermes Agent](https://github.com/NousResearch/hermes-agent) + [Hermes WebUI](https://github.com/nesquena/hermes-webui) on a remote server.

Two containers: the agent (gateway + API server) and the workspace (browser UI). All LLM calls are proxied through the agent — the WebUI never connects to the LLM directly.

## Quick Start

```bash
git clone https://github.com/<your-username>/hermes-webui-docker-compose.git
cd hermes-webui-docker-compose

# Create .env from the example
cp .env.example .env
# Edit .env — add your LLM provider key and set API_SERVER_KEY + HERMES_WEBUI_PASSWORD

# Clone the hermes-agent source (needed for model auto-detect + CLI session import)
git clone https://github.com/NousResearch/hermes-agent.git agent-src

# Start
docker compose up -d

# Open the WebUI
open http://<your-server>:3003
```

## Ports

| Port | Service | Notes |
|------|---------|-------|
| 3003 | WebUI | Browser interface |
| 9119 | Dashboard | Hermes admin dashboard |
| 8642 | API Server | Agent REST API (internal — don't expose without auth) |
| 2222 | dev-container | SSH into the long-lived dev-container (host) |
| 9377 | camofox-browser | Camofox browser automation API (optional) |
| 3002 | firecrawl-api | Firecrawl web scraper API (optional) |

## Optional Services

Two services are included in the compose but only start with an explicit profile flag. This avoids port conflicts with the standalone camofox/firecrawl stacks that may already be running on the host.

### Camofox browser (opt-in via profile)

```bash
# 1. Stop the existing standalone camofox (if running)
docker stop yourprojectname-camofox-browser-1

# 2. Set the key in .env (must match the existing one to keep
#    the cookies/auth working)
echo 'CAMOFOX_API_KEY=*** >> .env

# 3. Start the in-compose version
docker compose --profile camofox up -d camofox-browser
```

The volume `camofox-cookies` is created fresh — to preserve existing cookies, copy them in from the old container's mount first.

### Firecrawl (opt-in via profile)

The full firecrawl stack (API + postgres + redis + rabbitmq + playwright) is included but **off by default** — start with the `firecrawl` profile:

```bash
docker compose --profile firecrawl up -d
```

When started, the agent automatically uses it for `web` tool calls (set `web.backend: firecrawl` in `config.yaml`, the default). The compose wires the in-network hostnames so no env override is needed.

### Honcho (opt-in via profile, but you may already be running it standalone)

Honcho (the AI memory layer) is included but **off by default** — start with the `honcho` profile:

```bash
docker compose --profile honcho up -d
```

The honcho services build from `/home/yoav/honcho` on the host (override `context:` in compose if your repo lives elsewhere). Reads `.env` from that same path. The api listens on host port 8055 (same as the original honcho compose).

**To migrate from a standalone honcho compose:**

1. Stop the existing one: `cd /home/yoav/honcho && docker compose down`
2. The data volumes (`honcho_pgdata`, `honcho_redis-data` from the standalone compose) are kept by Docker unless you add `-v`. So data is preserved.
3. Start the in-compose version: `docker compose --profile honcho up -d`

The volume names from the standalone compose match the in-compose ones (`honcho-pgdata` and `honcho-redis-data`) so data flows in seamlessly.

## Two Gotchas That Took Hours to Find

### 1. WebUI sends "Connection error" on every message

**Symptom:** The WebUI loads fine, sidebar works, but every message fails with `Error: Connection error. Provider details` shows `Connection error` to the LLM endpoint.

**Root cause:** Without `HERMES_WEBUI_CHAT_BACKEND=gateway`, the WebUI runs its own **embedded hermes-agent** (legacy mode) inside the WebUI container. That embedded agent tries to reach the LLM (e.g. `host.docker.internal:11434`) directly — but `host.docker.internal` doesn't resolve in the WebUI container (only the agent container has `extra_hosts` for it).

**Fix:** These three env vars on the `hermes-workspace` service are **mandatory**:

```yaml
environment:
  HERMES_WEBUI_CHAT_BACKEND: "gateway"
  HERMES_WEBUI_GATEWAY_BASE_URL: "http://hermes-agent:8642"
  HERMES_WEBUI_GATEWAY_API_KEY: ${API_SERVER_KEY:-}
```

Without them the WebUI silently falls back to legacy mode and all chat requests fail.

### 2. CLI / desktop sessions don't appear in the sidebar

**Symptom:** Sessions created via the Hermes CLI or desktop app don't show up in the WebUI sidebar, even though the same `state.db` is shared.

**Root cause:** The WebUI has a per-user `settings.json` with `show_cli_sessions: false` by default. This hides all sessions not created by the WebUI itself.

**Fix:** After first launch, update `/opt/data/settings.json` inside the WebUI container:

```bash
docker exec hermes-hermes-workspace-1 python3 -c "
import json
with open('/opt/data/settings.json') as f:
    d = json.load(f)
d['show_cli_sessions'] = True
d['show_cron_sessions'] = True
d['show_previous_messaging_sessions'] = True
with open('/opt/data/settings.json', 'w') as f:
    json.dump(d, f, indent=2)
"
# Hard-refresh the WebUI (Ctrl+Shift+R)
```

There is also a UI toggle in the sidebar settings panel once you know where to look.

## Architecture

```
Browser → :3003 → hermes-workspace (WebUI)
                     ↓ (Docker network, port 8642)
                   hermes-agent (gateway + API server)
                     ↓
                   LLM provider (host.docker.internal → host)
```

The WebUI and agent share a `./data` volume containing `state.db` (sessions, messages, config). This means:
- CLI/desktop sessions appear in the WebUI sidebar (when `show_cli_sessions` is enabled)
- WebUI-created sessions are accessible from the CLI
- Shared config, skills, and memory across all interfaces

## File Layout

```
./
├── docker-compose.yml    # This file
├── .env                  # Secrets (not committed)
├── .env.example          # Template
├── agent-src/            # Cloned hermes-agent repo (for Python package)
├── data/                 # Shared state volume
│   ├── config.yaml       # Hermes config
│   ├── .env              # Agent's own .env (API keys)
│   ├── state.db          # Sessions + messages SQLite
│   ├── sessions/         # WebUI session JSON files
│   ├── settings.json     # WebUI per-user settings
│   ├── skills/           # Installed skills
│   └── ...
└── docker-compose.yml
```

## Troubleshooting

### Check agent health

```bash
curl http://localhost:8642/health
# Should return: {"status": "ok", "platform": "hermes-agent", "version": "..."}
```

### Check if gateway chat backend is active

```bash
docker exec hermes-hermes-workspace-1 python3 -c "
from api.gateway_chat import webui_chat_backend_mode
print(f'Mode: {webui_chat_backend_mode()}')
"
# Should print: Mode: gateway
```

### Check how many sessions the sidebar sees

```bash
docker exec hermes-hermes-workspace-1 python3 -c "
from api.models import get_cli_sessions, all_sessions
webui = len(all_sessions())
cli = len(get_cli_sessions())
print(f'WebUI sessions: {webui}, CLI sessions: {cli}')
"
```

### Agent logs

```bash
docker compose logs -f hermes-agent
```

### WebUI logs

```bash
docker compose logs -f hermes-workspace
```

### Connection error persists

1. Verify `API_SERVER_KEY` matches in both the agent and WebUI env
2. Verify `HERMES_WEBUI_CHAT_BACKEND=gateway` is set on the WebUI container
3. Check the agent can reach the LLM from inside the container:
   ```bash
   docker exec hermes-hermes-agent-1 curl -s http://host.docker.internal:11434/v1/models
   ```
4. Restart: `docker compose restart hermes-workspace`

### Bitwarden MCP server fails with `spawn bw ENOENT`

**Symptom:** Calling any `vaultwarden_*` MCP tool returns `spawn bw ENOENT` or `bw: not found`.

**Root cause:** The `@bitwarden/mcp-server` shells out to the `bw` binary using `child_process.spawn`. The subprocess inherits the MCP server's environment, which may not have `bw` on its `PATH` even though `bw` works fine from an interactive shell.

**Fix:** In `config.yaml`, the `vaultwarden` MCP entry must include an `env` block that sets a sane `PATH` AND a writable `BITWARDENCLI_APPDATA_DIR` (otherwise `bw` tries to write to `~/` which may not exist or be writable inside the agent container):

```yaml
mcp_servers:
  vaultwarden:
    command: npx
    args: ["-y", "@bitwarden/mcp-server"]
    env:
      PATH: /usr/local/bin:/usr/bin:/bin
      BITWARDENCLI_APPDATA_DIR: /opt/data/.config/Bitwarden CLI
      BITWARDEN_BASE_URL: ${BITWARDEN_BASE_URL}
      BW_CLIENTID: ${BW_CLIENTID}
      BW_CLIENTSECRET: ${BW_CLIENTSECRET}
```

Make sure the appdata dir exists and is owned by the agent's runtime uid:

```bash
docker exec hermes-hermes-agent-1 mkdir -p '/opt/data/.config/Bitwarden CLI'
docker compose restart hermes-agent
```

## References

- [Hermes Agent docs](https://hermes-agent.nousresearch.com/docs)
- [Hermes WebUI repo](https://github.com/nesquena/hermes-webui)
- [Hermes Agent repo](https://github.com/NousResearch/hermes-agent)
