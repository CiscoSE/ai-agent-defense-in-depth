# 9 Rings of Defense

### Securing an Autonomous AI Coding Agent with Isovalent and Cisco AI Defense

> **An autonomous AI agent is writing code on a public open-source project right now, monitored by Cisco's Isovalent and AI Defense scanners, on an $80 Raspberry Pi.**

---

## Executive Summary

AetherClaude is an AI coding agent that triages GitHub issues, implements fixes, reviews community pull requests, detects duplicates, explains CI failures, answers community questions, and compiles release notes for [AetherSDR](https://github.com/ten9876/AetherSDR) — an open-source Linux-native SDR client for the amateur radio community. It runs eight skills across three trigger patterns on an hourly timer cycle with real-time webhook triggers, unattended, on dedicated commodity hardware.

AetherSDR has a community of over 1,000 users around the world actively consuming software produced by this pipeline — running builds that include AI-authored code, filing bug reports that the agent triages, and requesting features that the agent implements. Contributors who have never written a line of C++ are shaping the project through AI-assisted issue and feature requests that the agent turns into production-ready code. This has democratized participation: the barrier to contributing is no longer knowing how to code, it's knowing how to describe what you need.

This repository contains the complete **9-ring defense-in-depth framework** securing that deployment. Each ring addresses distinct attack vectors — from kernel-level packet filtering (Ring 1) through Cisco AI Defense static analysis (Ring 6) to mandatory human review (Ring 9). An attacker must penetrate all nine rings to cause damage to the upstream project.

## The Problem

Open-source projects have a scaling problem. A solo maintainer receives bug reports, feature requests, and community questions at a rate that exceeds available time. AI coding agents promise to bridge this gap — but they create a novel threat model.

The agent's input — GitHub issues, pull requests, discussion threads — is **untrusted public text** written by anyone on the internet. That text is fed into an LLM with code-writing capabilities, repository access, and credentials for GitHub APIs. A carefully crafted issue body is a prompt injection vector.

Our solution: treat the AI agent the way you would treat any untrusted process with network access and write permissions — assume it will be compromised, and make compromise survivable. Rather than relying on any single control, we layer nine independent defenses so that no single failure can result in damage to the upstream project.

## The 9-Ring Defense-in-Depth Model

| Ring | Control | Protection | Dashboard Metric |
|------|---------|------------|-----------------|
| 1 | **nftables** | Kernel-level egress by UID. Only GitHub + Anthropic IPs permitted. All other outbound dropped. | Packets blocked |
| 2 | **tinyproxy** | Domain-level HTTPS filtering, default-deny. Six permitted domains. | Sessions allowed / denied |
| 3 | **OS isolation** | Dedicated UID 965, rbash, no sudo, locked password, minimal PATH. [Tetragon](https://isovalent.com/products/runtime-security/) tracks every exec. | Agent commands (eBPF) |
| 4 | **systemd sandbox** | NoNewPrivileges, ProtectSystem=strict, read-only FS, private /tmp. | Sandboxed runs |
| 5 | **Claude Code perms** | Specific tool allow/deny lists, --bare mode. | Tool calls tracked |
| 6 | **[Cisco AI Defense](https://www.cisco.com/site/us/en/products/security/ai-defense/index.html)** | [CodeGuard](https://cisco-ai-defense.github.io/docs/defenseclaw) static analysis, [MCP Scanner](https://github.com/cisco-ai-defense/mcp-scanner) (YARA), [Skill Scanner](https://github.com/cisco-ai-defense/skill-scanner) (injection detection), [C++ AIBOM](https://github.com/cisco-ai-defense/aibom), Agent SBOM. | Files scanned / findings / blocks |
| 7 | **MCP token isolation** | Tokens held by deterministic server (14 ops). Rate limiting, content validation, credential blocking. | Operations / blocked / rate-limited |
| 8 | **Validation Gate** | 8-check automated pre-flight: protected files, directory restrictions, suspicious patterns, credentials, binaries, diff size, CodeGuard, Skill Scanner. | Checks passed / failed |
| 9 | **Human Review** | All PRs draft-quarantined. CODEOWNERS approval, signed commits, CI status checks required. | PRs merged / rejected / open |

A prompt injection might trick Claude into writing strange code (bypassing rings 1-5), but the Cisco AI Defense scanners analyze the output (ring 6), the MCP server prevents token theft (ring 7), the validation gate blocks bad diffs (ring 8), and the maintainer must approve every merge (ring 9).

## Cisco Technology in Production

Four [Cisco AI Defense](https://www.cisco.com/site/us/en/products/security/ai-defense/index.html) technologies are in production today. All on ARM64, all on commodity hardware:

- **[Cilium Tetragon (Isovalent)](https://isovalent.com/products/runtime-security/)** — eBPF-based process execution tracking, network connection monitoring, and privilege escalation detection on a custom BTF-enabled kernel
- **[DefenseClaw CodeGuard](https://cisco-ai-defense.github.io/docs/defenseclaw)** — Static analysis on every changed file. 10 rules covering credentials, unsafe exec, outbound HTTP, deserialization, SQL injection, weak crypto, path traversal. HIGH/CRITICAL = block.
- **[MCP Scanner](https://github.com/cisco-ai-defense/mcp-scanner)** — YARA + Prompt Defense analysis on all MCP tool declarations
- **[Skill Scanner](https://github.com/cisco-ai-defense/skill-scanner)** — Injection risk analysis on agent skill templates

## MCP Token Isolation Pattern

If the AI has the credentials, a prompt injection can abuse them. Rather than passing GitHub tokens to Claude Code as environment variables, we interpose a deterministic MCP server. It holds all credentials and exposes exactly 14 named operations across four categories (Issues, Pull Requests, CI, Discussions). No delete operations, no repository management, no settings changes.

The MCP server uses native Node.js `https` with CONNECT proxy tunneling — zero `execSync` or `curl` subprocess calls. All credentials stay in-process memory, invisible to eBPF process argument capture. GitHub App installation tokens auto-expire after 1 hour.

## Live Dashboard

All nine rings are monitored in real time through a unified web dashboard:

- **9-Ring Status Bar** with live counters, clickable for event details
- **Unified Event Stream** from 8 data sources, color-coded by type
- **Cisco AI Defense Scanner Modals** with DB-backed finding details
- **Token Usage** tracking with MAX subscription ROI monitoring
- **GitHub Activity** with per-operation breakdown
- **Secret Redaction** at ingestion and API response layers
- **SQLite Event Store** for historical queries
- **GitHub Webhook** integration for real-time agent triggering

## Agent Skills

| # | Skill | Function |
|---|-------|----------|
| 1 | Issue Triage | Analyzes issues, posts structured plans |
| 2 | Issue Fix + PR | Implements fixes, creates draft PRs |
| 3 | Community PR Review | Reviews contributor PRs for convention compliance |
| 4 | Duplicate Detection | Searches for similar issues |
| 5 | CI Failure Explainer | Reads build logs, explains errors |
| 6 | Discussion Responder | Answers community questions |
| 7 | Stale Issue Triage | Follow-up on issues with 30+ days inactivity |

Plus: first-time contributor welcome messages and bug report quality checks (template-based, no AI).

## The $147 AI Agent Governance Platform

| Component | Cost | Purpose |
|-----------|------|---------|
| Raspberry Pi 5 (8GB) | $80 | Compute |
| NVMe SSD (256GB) | $40 | Storage |
| M.2 HAT+ for Pi 5 | $15 | NVMe interface |
| USB-C power supply (27W) | $12 | Power |
| **Total** | **$147** | **Complete platform** |

Enterprise AI agent governance does not require enterprise infrastructure. No cloud accounts. No Kubernetes clusters. No container orchestration. No license servers.

---

## Deploying AI Agent Defense-in-Depth

This repository contains everything you need to deploy your own secured AI coding agent. The framework is project-agnostic — it works with any GitHub repository.

### Quick Start

1. **Create the agent user** — dedicated unprivileged UID with restricted shell
2. **Set up a GitHub App** — for token isolation (no long-lived PATs)
3. **Configure environment** — copy `config.env.example` to `~/.env` and fill in your values
4. **Install scripts** — orchestrator, MCP server, validation gate, credential helpers
5. **Install skill templates** — 7 prompt templates in `skills/`
6. **Configure Claude Code** — settings and MCP server config
7. **Set up systemd** — timer for hourly fallback + service unit with sandboxing
8. **Configure network isolation** — nftables (Ring 1) + tinyproxy (Ring 2)
9. **Deploy dashboard** (optional) — real-time observability across all rings
10. **Configure webhooks** (optional) — real-time GitHub event triggers

See **[SETUP.md](SETUP.md)** for the complete step-by-step deployment guide.

### Repository Structure

```
bin/
  run-agent.sh                — Main orchestrator (8 skills, webhook + timer)
  github-mcp-server.js        — MCP server (14 ops, token isolation)
  validate-diff.sh             — 8-check validation gate
  github-app-token.sh         — GitHub App token generator
  gh-request.py                — GitHub API helper (token via stdin)
  git-credential-app-token.py — Git credential helper (app tokens)
  tetragon-dashboard.py       — Live defense-in-depth dashboard

skills/                        — 7 agent skill prompt templates
config/                        — Claude Code, MCP, Cloudflare configs
systemd/                       — Service and timer units
config.env.example             — Environment variable template
SETUP.md                       — Full deployment guide
```

### Configuration

All deployment-specific values are parameterized via environment variables:

| Variable | Description |
|----------|-------------|
| `AGENT_HOME` | Agent's home directory |
| `UPSTREAM_REPO` | Target repository (`org/repo`) |
| `FORK_OWNER` | Fork organization for PRs |
| `GITHUB_APP_ID` | GitHub App ID |
| `WEBHOOK_SECRET` | HMAC secret for webhook validation |
| `MAINTAINER_NAME` | Displayed in welcome messages |

See `config.env.example` for the complete list.

---

## Red Team Results

An independent review by Grok (xAI) evaluated the security architecture and proposed 15 improvements. 5 were already implemented, 2 were implemented from the review (immutable audit logs, draft PR quarantine), 4 are planned, and 6 were declined with justification.

## Credits

- **Jeremy Fielder (KK7GWY)** — Systems Engineer, Cisco Systems
- **Claude** (Anthropic) — AI development partner
- **Cisco Isovalent** — Tetragon eBPF runtime security
- **Cisco AI Defense** — CodeGuard, MCP Scanner, Skill Scanner, AIBOM

## License

MIT

---

*"The agents are already deployed. The question is whether we govern them, or hope for the best."*
