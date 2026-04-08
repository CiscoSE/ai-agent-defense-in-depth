# AetherClaude: Autonomous AI Coding Agent with 9 Rings of Defense

A production-ready framework for deploying an autonomous AI coding agent on open-source projects, secured by a 9-ring defense-in-depth model.

## What This Is

AetherClaude is an autonomous agent that:
- Triages GitHub issues and implements fixes as draft PRs
- Reviews community pull requests for convention compliance
- Detects duplicate issues
- Explains CI failures to contributors
- Responds to GitHub Discussions
- Welcomes first-time contributors
- Triages stale issues

It runs on a timer (hourly fallback) and via GitHub webhooks (real-time), unattended, on commodity hardware (Raspberry Pi 5 or any Linux server).

## Prerequisites

- Linux host (tested on Raspberry Pi 5 / ARM64 and x86_64)
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) with a Claude Max subscription
- A GitHub App (for token isolation)
- Python 3.10+, Node.js 18+
- `nftables`, `tinyproxy` (for network isolation rings)
- Optional: [Cilium Tetragon](https://isovalent.com/products/runtime-security/) for eBPF observability
- Optional: [Cisco DefenseClaw CodeGuard](https://cisco-ai-defense.github.io/docs/defenseclaw) for static analysis
- Optional: [Cisco MCP Scanner](https://github.com/cisco-ai-defense/mcp-scanner) and [Skill Scanner](https://github.com/cisco-ai-defense/skill-scanner)
- Optional: [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) for public dashboard access

## Architecture

```
9 Rings of Defense (outermost to innermost):

1. nftables        — Kernel packet filter (UID-based egress allowlist)
2. tinyproxy       — Domain-level HTTPS filter (6 allowed domains)
3. OS Isolation    — Dedicated user, rbash, no sudo, Tetragon eBPF
4. systemd Sandbox — NoNewPrivileges, read-only FS, private /tmp
5. Claude Code     — Tool-level allow/deny lists
6. AI Defense      — CodeGuard, MCP Scanner, Skill Scanner, AIBOM
7. MCP Isolation   — Tokens in deterministic server, never in AI context
8. Validation Gate — 8-check pre-push gate (credentials, patterns, CodeGuard)
9. Human Review    — CODEOWNERS, GPG signing, CI checks, draft quarantine
```

## Setup Guide

### 1. Create the Agent User

```bash
sudo useradd -m -s /bin/rbash -u 965 aetherclaude
sudo passwd -l aetherclaude  # Lock password — no direct login
```

### 2. Create the Directory Structure

```bash
sudo -u aetherclaude mkdir -p \
  ~/bin ~/logs ~/prompts ~/state ~/skills ~/workspace
```

### 3. Clone Your Project

```bash
# Fork the upstream repo to your agent's GitHub account first
sudo -u aetherclaude git clone https://github.com/YOUR-FORK-ORG/YOUR-PROJECT.git ~/workspace/YOUR-PROJECT
cd ~/workspace/YOUR-PROJECT
git remote add upstream https://github.com/YOUR-ORG/YOUR-PROJECT.git
```

### 4. Create a GitHub App

1. Go to https://github.com/settings/apps → **New GitHub App**
2. **Permissions:**
   - Issues: Read & write
   - Pull requests: Read & write
   - Discussions: Read & write
   - Contents: Read-only
   - Actions: Read-only
   - Metadata: Read-only
3. Generate a private key (PEM file)
4. Install the app on **both** the upstream repo and the fork
5. Copy the PEM key:
   ```bash
   sudo cp your-app-key.pem /home/aetherclaude/.github-app-key.pem
   sudo chown aetherclaude:aetherclaude /home/aetherclaude/.github-app-key.pem
   sudo chmod 600 /home/aetherclaude/.github-app-key.pem
   ```

### 5. Configure Environment

```bash
sudo cp config.env.example /home/aetherclaude/.env
sudo chown aetherclaude:aetherclaude /home/aetherclaude/.env
sudo chmod 600 /home/aetherclaude/.env
# Edit .env with your values
sudo -u aetherclaude nano /home/aetherclaude/.env
```

Required values:
| Variable | Description | Example |
|----------|-------------|---------|
| `GITHUB_APP_ID` | Your GitHub App's ID | `1234567` |
| `WEBHOOK_SECRET` | HMAC secret for webhook validation | Generate with `python3 -c "import secrets; print(secrets.token_hex(32))"` |
| `HTTPS_PROXY` | Proxy address for network isolation | `http://127.0.0.1:8888` |

### 6. Set Agent Environment Variables

The scripts use these environment variables (set them in the systemd service or export before running):

| Variable | Default | Description |
|----------|---------|-------------|
| `AGENT_HOME` | `/home/aetherclaude` | Agent's home directory |
| `AGENT_USER` | `aetherclaude` | Agent's Unix username |
| `UPSTREAM_REPO` | — | Upstream repo (`org/repo`) |
| `UPSTREAM_OWNER` | — | Upstream org/user |
| `FORK_OWNER` | — | Fork org/user |
| `PROJECT_NAME` | — | Repository name |
| `BOT_USERNAME` | — | GitHub App bot username (e.g., `your-app[bot]`) |
| `AGENT_DATA_DIR` | `/var/lib/aetherclaude` | SQLite database directory |

### 7. Install Scripts

```bash
sudo cp bin/run-agent.sh /home/aetherclaude/bin/
sudo cp bin/github-mcp-server.js /home/aetherclaude/bin/
sudo cp bin/validate-diff.sh /home/aetherclaude/bin/
sudo cp bin/github-app-token.sh /home/aetherclaude/bin/
sudo cp bin/gh-request.py /home/aetherclaude/bin/
sudo cp bin/git-credential-app-token.py /home/aetherclaude/bin/
sudo cp skills/*.md /home/aetherclaude/skills/
sudo chmod +x /home/aetherclaude/bin/*.sh /home/aetherclaude/bin/*.py
sudo chown -R aetherclaude:aetherclaude /home/aetherclaude/bin /home/aetherclaude/skills
```

### 8. Configure Claude Code

```bash
sudo mkdir -p /home/aetherclaude/.claude
sudo cp config/claude-settings.json /home/aetherclaude/.claude/settings.json
sudo cp config/mcp-servers.json /home/aetherclaude/.claude/mcp-servers.json
sudo chown -R aetherclaude:aetherclaude /home/aetherclaude/.claude

# Authenticate Claude Code
sudo -u aetherclaude bash -c 'PATH="$HOME/.local/bin:$PATH" claude /login'
```

### 9. Configure Git Credential Helper

```bash
sudo -u aetherclaude git -C ~/workspace/YOUR-PROJECT config credential.helper \
  '/home/aetherclaude/bin/git-credential-app-token.py'
```

### 10. Install systemd Service

```bash
# Edit the service file — replace <AGENT_HOME> and <AGENT_USER> placeholders
sudo cp systemd/aetherclaude.service /etc/systemd/system/
sudo cp systemd/aetherclaude.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable aetherclaude.timer
sudo systemctl start aetherclaude.timer
```

### 11. Network Isolation (Rings 1-2)

#### nftables (Ring 1)
```bash
# Allow outbound only to GitHub + Anthropic for the agent UID
sudo nft add table inet filter
sudo nft add chain inet filter output '{ type filter hook output priority 0; policy accept; }'
# Add rules for UID-based filtering — see your nftables documentation
```

#### tinyproxy (Ring 2)
```bash
sudo pacman -S tinyproxy  # or apt install tinyproxy
# Configure /etc/tinyproxy/tinyproxy.conf:
#   FilterDefaultDeny Yes
#   Filter "/etc/tinyproxy/allowlist"
# Allowlist domains: api.github.com, github.com, api.anthropic.com
```

### 12. Dashboard (Optional)

```bash
sudo cp bin/tetragon-dashboard.py /usr/local/bin/
sudo mkdir -p /var/lib/aetherclaude
sudo chown aetherclaude:aetherclaude /var/lib/aetherclaude

# Set environment variables for the dashboard
export AGENT_HOME=/home/aetherclaude
export UPSTREAM_REPO=your-org/your-repo
export UPSTREAM_OWNER=your-org
export PROJECT_NAME=your-repo
export FORK_OWNER=your-fork-org
export BOT_USERNAME=your-app[bot]
export WEBHOOK_SECRET=your-webhook-secret

# Start the dashboard
sudo python3 /usr/local/bin/tetragon-dashboard.py --port 8080 &
```

### 13. GitHub Webhook (Optional)

1. In your GitHub App settings, enable webhooks:
   - **URL:** `https://your-dashboard-domain/webhook`
   - **Secret:** Same as `WEBHOOK_SECRET` in your `.env`
   - **Events:** Issues, Issue comment, Pull request, Pull request review, Discussion, Discussion comment
2. The dashboard's `/webhook` endpoint validates HMAC-SHA256 signatures and triggers the agent on relevant events.

### 14. Cloudflare Tunnel (Optional)

```bash
# Install cloudflared
cloudflared tunnel create agent-dashboard
cloudflared tunnel route dns <TUNNEL-UUID> your-dashboard-domain

# Edit config/cloudflared.yml with your tunnel UUID and domain
sudo cp config/cloudflared.yml /etc/cloudflared/config.yml
sudo systemctl enable cloudflared
sudo systemctl start cloudflared
```

## Security Model

Every secret flows through stdin or in-process memory — never as process arguments (visible to eBPF). The GitHub App generates short-lived installation tokens (1-hour expiry) instead of long-lived PATs.

The dashboard redacts 13+ secret patterns at event ingestion and again at API response, ensuring secrets never reach the browser even if they appear in log sources.

See the whitepaper (accessible from the dashboard) for the full 9-ring defense-in-depth analysis.

## File Reference

```
bin/
  run-agent.sh              — Main orchestrator (8 skills, webhook + timer trigger)
  github-mcp-server.js      — MCP server (14 GitHub operations, token isolation)
  validate-diff.sh           — 8-check validation gate (pre-push)
  github-app-token.sh       — GitHub App JWT → installation token generator
  gh-request.py              — GitHub API helper (token via stdin)
  git-credential-app-token.py — Git credential helper (app tokens for push)
  tetragon-dashboard.py     — Live defense-in-depth dashboard

skills/
  triage-issue.md            — Issue analysis + plan prompt
  implement-fix.md           — Code fix + PR creation prompt
  review-pr.md               — Community PR review prompt
  detect-duplicate.md        — Duplicate issue detection prompt
  respond-discussion.md      — Discussion response prompt
  explain-ci.md              — CI failure explanation prompt
  triage-stale.md            — Stale issue follow-up prompt

config/
  config.env.example         — Environment variable template
  claude-settings.json       — Claude Code permission configuration
  mcp-servers.json           — MCP server configuration
  cloudflared.yml            — Cloudflare Tunnel template

systemd/
  aetherclaude.service       — Agent systemd service unit
  aetherclaude.timer         — Hourly fallback timer
```

## License

MIT
