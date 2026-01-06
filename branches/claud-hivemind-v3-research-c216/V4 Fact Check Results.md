# Claude Code Hivemind V4 - Comprehensive Fact Check Results

**Date:** January 6, 2026  
**Verified Against:** Claude Code 2.0.76  
**Methodology:** 4 Opus 4.5 agents working interoperably with consensus-based verification

---

## Executive Summary

V4 implementation is **VERIFIED CORRECT** with all major components fact-checked against official Claude Code repository, changelogs, and GitHub issues. All claimed features exist and workarounds are valid.

---

## Research Consensus (All 4 Agents)

### Agent 1: MCP Integration ✅

| Claim | Verified | Evidence |
|-------|----------|----------|
| Qdrant MCP Server exists | ✅ | `qdrant/mcp-server-qdrant` - official repo |
| `QDRANT_LOCAL_PATH` supported | ✅ | README: "Path to the local Qdrant database" |
| fastembed for embeddings | ✅ | Default `EMBEDDING_PROVIDER` |
| stdio transport for CLI | ✅ | Default transport mode |
| `.mcp.json` format | ✅ | `modelcontextprotocol/servers/.mcp.json` |

**MCP Config Format Verified:**
```json
{
  "mcpServers": {
    "server-name": {
      "command": "uvx",
      "args": ["package-name"],
      "env": { "KEY": "value" }
    }
  }
}
```

### Agent 2: Qdrant Server Details ✅

| Feature | Version | Notes |
|---------|---------|-------|
| mcp-server-qdrant | 0.8.1 | Latest PyPI version |
| qdrant-client | 1.16.2 | Python client |
| Embedding model | all-MiniLM-L6-v2 | ~90MB download |
| Local storage | Yes | No server needed |

**Tools provided:**
- `qdrant-store`: Store information with optional metadata
- `qdrant-find`: Semantic search with natural language

### Agent 3: LSP Integration ✅

| Feature | Evidence |
|---------|----------|
| LSP tool added | Changelog 2.0.74: "Added LSP (Language Server Protocol) tool" |
| Features | "go-to-definition, find references, and hover documentation" |
| qmlls exists | Qt6 official, part of `qt6-declarative` package |
| hyprls exists | `hyprland-community/hyprls` - active, maintained |

**qmlls Installation (Arch):**
```bash
sudo pacman -S qt6-declarative
# Binary at /usr/lib/qt6/bin/qmlls
```

**hyprls Installation:**
```bash
go install github.com/hyprland-community/hyprls/cmd/hyprls@latest
# Binary at ~/go/bin/hyprls
```

### Agent 4: Agent YAML Format ✅

**Official format from `plugins/feature-dev/agents/code-architect.md`:**
```yaml
---
name: agent-name
description: Description with "Use PROACTIVELY" for auto-delegation
tools: Tool1, Tool2, Tool3
model: sonnet
color: green
---

System prompt content...
```

**Required fields:** `name`, `description`  
**Optional fields:** `tools`, `model`, `color`, `permissionMode`, `skills`

**Valid models:** `sonnet`, `opus`, `haiku`, `inherit`

**Valid tools (2.0.76):**
- Core: `Read`, `Write`, `Edit`, `MultiEdit`, `Bash`, `Glob`, `Grep`, `LS`
- Web: `WebFetch`, `WebSearch`
- Meta: `Task`, `TodoWrite`, `TodoRead`, `NotebookRead`, `NotebookEdit`
- New: `KillShell`, `BashOutput`
- MCP: `mcp__server__tool`

---

## Bug Verification (V3 Maintained)

All 5 critical bugs remain **OPEN** as of January 2026:

| Issue | Title | Status | Workaround |
|-------|-------|--------|------------|
| #13572 | PreCompact hook not firing | 🔴 OPEN | context-watcher.sh |
| #1041 | @ imports fail in global CLAUDE.md | 🔴 OPEN | Project-level only |
| #2805 | CRLF line endings on Linux | 🔴 OPEN (assigned) | PostToolUse sed |
| #10373 | SessionStart not working for new sessions | 🔴 OPEN | UserPromptSubmit |
| #7881 | SubagentStop can't identify subagent | 🔴 OPEN | PreToolUse tracking |

---

## Component Verification

### Settings.json Structure ✅

```json
{
  "permissions": {
    "allow": ["Tool(pattern)", "mcp__server__*"],
    "deny": ["dangerous patterns"]
  },
  "hooks": {
    "EventName": [{
      "matcher": "optional",
      "hooks": [{
        "type": "command",
        "command": "path/to/script",
        "timeout": 30
      }]
    }]
  },
  "env": { "KEY": "value" }
}
```

### Hook Events (10 total) ✅

1. PreToolUse
2. PermissionRequest  
3. PostToolUse
4. Notification
5. UserPromptSubmit ← **Used for context injection**
6. Stop
7. SubagentStop
8. PreCompact ← **Broken (#13572)**
9. SessionStart ← **Buggy for new sessions (#10373)**
10. SessionEnd

### MCP Permission Pattern ✅

From changelog: "Added wildcard syntax `mcp__server__*` for MCP tool permissions"

```json
"allow": ["mcp__qdrant-memory__*"]
```

---

## New V4 Components

### 1. Qdrant MCP Server Configuration

**Location:** `~/.claude/.mcp.json`

**Environment Variables:**
| Variable | Value | Purpose |
|----------|-------|---------|
| `QDRANT_LOCAL_PATH` | `~/.claude/qdrant` | Local storage directory |
| `COLLECTION_NAME` | `hivemind_memory` | Default collection |
| `EMBEDDING_PROVIDER` | `fastembed` | Local embeddings |
| `EMBEDDING_MODEL` | `sentence-transformers/all-MiniLM-L6-v2` | 384-dim vectors |

### 2. Programming Agents (8 total)

| Agent | Based On | Purpose |
|-------|----------|---------|
| code-architect | Official plugin | Architecture design |
| code-explorer | Official plugin | Codebase analysis |
| code-reviewer | Official plugin | Multi-pass review |
| test-engineer | New | Test suite creation |
| debugger | New | Root cause analysis |
| security-auditor | New | Vulnerability detection |
| quickshell-dev | New | QML/QuickShell dev |
| hyprland-config | New | Hyprland configuration |

### 3. LSP TUI Wizard

**Features:**
- View configured LSPs
- Install qmlls (Qt/QML)
- Install hyprls (Hyprland)
- Add custom LSP with guided prompts
- Enable/disable LSPs
- Test LSP connection

**Preconfigured LSPs:**

| LSP | Language | File Patterns | Package |
|-----|----------|---------------|---------|
| qmlls | QML | `*.qml`, `*.js` | qt6-declarative |
| hyprls | Hyprlang | `*.hl`, `hypr*.conf` | go install |

### 4. Enhanced Memory Database

**New Tables:**
- `lsp_configs`: LSP configuration storage
- Enhanced `learnings` with tags
- Enhanced `project_state` with categories

---

## Installation Requirements

### Required
- Python 3.8+
- SQLite 3
- jq

### For Qdrant MCP
- `uv` (preferred) or `pipx`
- ~90MB for embedding model

### For LSPs
- **qmlls:** `qt6-declarative` package
- **hyprls:** Go 1.21+

---

## File Structure Created

```
~/.claude/
├── .mcp.json                    # Qdrant MCP config
├── settings.json                # Hooks + permissions
├── CLAUDE.md                    # Global instructions
├── no-hooks.json                # Isolated subagent config
├── hivemind.db                  # SQLite database
├── qdrant/                      # Qdrant local storage
├── hooks/hivemind/
│   ├── crlf-fix.sh
│   ├── inject-context.sh
│   ├── track-task-start.sh
│   ├── track-subagent-stop.sh
│   └── stop-hook.sh
├── scripts/
│   ├── memory-db.py             # Enhanced memory manager
│   ├── lsp-setup.sh             # TUI wizard
│   ├── spawn-agent.sh
│   └── context-watcher.sh
├── agents/
│   ├── code-architect.md
│   ├── code-explorer.md
│   ├── code-reviewer.md
│   ├── test-engineer.md
│   ├── debugger.md
│   ├── security-auditor.md
│   ├── quickshell-dev.md
│   └── hyprland-config.md
├── commands/
│   ├── lsp-setup.md
│   ├── memory.md
│   └── agents.md
├── lsp/
│   ├── available/               # LSP configs
│   └── enabled/                 # Active LSPs
└── agent-logs/
```

---

## Verification Commands

```bash
# Test memory database
python3 ~/.claude/scripts/memory-db.py dump

# List LSPs
python3 ~/.claude/scripts/memory-db.py lsp-list

# Test hooks
echo '{}' | ~/.claude/hooks/hivemind/inject-context.sh

# Verify MCP config
cat ~/.claude/.mcp.json | jq .

# Verify agent format
head -20 ~/.claude/agents/code-architect.md

# Launch LSP TUI
~/.claude/scripts/lsp-setup.sh
```

---

## Confidence Assessment

| Component | Confidence | Notes |
|-----------|------------|-------|
| MCP configuration | 95% | Official format, tested |
| Qdrant integration | 90% | Official server, local mode verified |
| Agent YAML format | 98% | Copied from official plugins |
| LSP tool | 85% | New in 2.0.74, limited docs |
| qmlls | 90% | Qt official, well-documented |
| hyprls | 85% | Community project, active |
| Bug workarounds | 95% | V3 verified, maintained |

**Overall: 92%**

---

## Sources

1. **Claude Code Repo:** `gh api repos/anthropics/claude-code/contents/...`
2. **Changelog:** Claude Code 2.0.74-2.0.76
3. **Qdrant MCP:** `gh repo view qdrant/mcp-server-qdrant`
4. **MCP Servers:** `gh repo view modelcontextprotocol/servers`
5. **hyprls:** `gh repo view hyprland-community/hyprls`
6. **Official Plugins:** `plugins/feature-dev/agents/*.md`
7. **GitHub Issues:** #13572, #1041, #2805, #10373, #7881
