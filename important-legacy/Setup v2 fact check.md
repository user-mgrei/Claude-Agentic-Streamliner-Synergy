# Claude Code CLI configuration verified against official docs

Your assumptions are **mostly correct with critical exceptions**. Before first run on Arch Linux, you should address the config directory location issue and known AUR path problems. The hooks system, memory, and subagent configurations match documentation, but several items need correction.

## Hooks system: 9 of 10 events confirmed

Your hook event list is **missing one event**: `PermissionRequest`, which runs when permission dialogs appear and allows programmatic allow/deny. The full official list contains 10 hooks: PreToolUse, PermissionRequest, PostToolUse, Notification, UserPromptSubmit, Stop, SubagentStop, PreCompact, SessionStart, and SessionEnd.

**SessionStart output format** is exactly as you described:
```json
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "My additional context here"
  }
}
```

**PreCompact matchers** `"auto"` and `"manual"` are **confirmed valid**. Auto triggers on context window exhaustion; manual triggers on `/compact` command. However, **Issue #13572 documents that PreCompact hooks currently don't fire on `/compact`**—this is a known bug affecting Linux users.

**Hook input JSON** matches your expectations. All hooks receive `session_id`, `transcript_path`, `cwd`, `permission_mode`, and `hook_event_name`. Event-specific fields include `stop_hook_active` for Stop/SubagentStop, `trigger` for PreCompact, and `source` for SessionStart.

**Exit codes** are correct: **0** = success with JSON output parsed, **2** = blocking error with stderr fed back to Claude. Other codes produce non-blocking warnings. Timeout defaults to **60 seconds** and is configurable per-hook via the `timeout` field.

## Directory structure: one correction needed

| Path | Status | Notes |
|------|--------|-------|
| `~/.claude/` | ⚠️ **CHECK** | May have moved to `~/.config/claude/` per Issue #2277 |
| `~/.claude/settings.json` | ✅ Correct | User-level settings file |
| `~/.claude/CLAUDE.md` | ✅ Correct | Global prompt for all projects |
| `~/.claude/agents/` | ✅ Correct | User-level subagent storage |
| `~/.claude/commands/` | ✅ Correct | Personal slash commands |
| `~/.claude/rules/` | ❌ **INCORRECT** | Only `.claude/rules/` at project level exists |

The `~/.claude/rules/` directory is **not documented**. Rules auto-loading only works at project level (`.claude/rules/` inside project directory). For user-level preferences, use `~/.claude/CLAUDE.md` or @ imports instead.

## Memory system has documented Linux bugs

**@ import syntax** `@~/.claude/path/to/file.md` is officially documented but **has known issues on Linux**. Multiple GitHub issues confirm problems:

- **Issue #1041**: @ imports fail in global `~/.claude/CLAUDE.md` entirely
- **Issue #4754**: Relative paths resolve from CWD instead of containing directory  
- **Issue #1941**: Files in directories starting with `.` aren't picked up

**Max import depth** is **5 hops** as documented. **CLAUDE.md precedence** order is: Enterprise policy → Project (`.claude/CLAUDE.md`) → User (`~/.claude/CLAUDE.md`) → Local (`CLAUDE.local.md`). Note that `CLAUDE.local.md` is deprecated in favor of imports.

## Subagent YAML frontmatter requires only two fields

```yaml
---
name: my-agent          # REQUIRED - lowercase with hyphens
description: Agent description   # REQUIRED - include "Use PROACTIVELY" for auto-delegation
tools: Read, Write, Bash        # Optional - omit to inherit all tools
model: sonnet                    # Optional - sonnet|opus|haiku|'inherit'
permissionMode: default          # Optional - default|acceptEdits|bypassPermissions|plan
skills: skill-name               # Optional - comma-separated skills to auto-load
---
```

Your tool list is **incomplete**. The full set includes: Read, Write, Edit, **MultiEdit**, Bash, Grep, Glob, **LS**, **WebFetch**, **WebSearch**, **TodoRead**, **TodoWrite**, **NotebookRead**, **NotebookEdit**, Task, plus MCP tools. Model aliases `sonnet`, `opus`, `haiku` are correct; `'inherit'` is also valid.

## Headless mode flags are current

`--output-format stream-json` is **confirmed correct**. Key headless flags:

| Flag | Purpose |
|------|---------|
| `-p` / `--print` | Primary non-interactive mode flag |
| `--output-format` | `text`, `json`, or `stream-json` |
| `--input-format` | `text` or `stream-json` for multi-turn |
| `--max-turns N` | Limit agentic turns to prevent runaway |
| `--permission-mode` | `default`, `acceptEdits`, `bypassPermissions`, `plan` |
| `--allowedTools` | Tools to permit without prompting |
| `--resume SESSION_ID` | Continue specific session |
| `--continue` / `-c` | Resume most recent conversation |

Spawn background agents via: `claude -p "Task" --output-format stream-json --permission-mode acceptEdits`

## settings.json structure matches your expectations

```json
{
  "permissions": {
    "allow": ["Bash(npm run lint)", "Read(~/.zshrc)"],
    "deny": ["Read(./.env)", "Bash(curl:*)"],
    "ask": ["Bash(git push:*)"]
  },
  "env": {
    "MY_VAR": "value"
  },
  "hooks": {
    "PostToolUse": [{
      "matcher": "Write|Edit",
      "hooks": [{"type": "command", "command": "prettier --write \"$CLAUDE_FILE_PATHS\"", "timeout": 30}]
    }]
  }
}
```

The `env` object, allow/deny arrays, and nested hooks structure are all **confirmed correct**. Hook matchers support exact strings, regex with `|`, or `*` for all tools.

## Critical Arch Linux issues to address before first run

**AUR path mismatch**: The AUR package installs to `/usr/sbin/claude`, but Claude Code expects `~/.local/bin/claude`. Create a symlink:
```bash
mkdir -p ~/.local/bin
ln -sf /usr/sbin/claude ~/.local/bin/claude
```

**Config directory ambiguity**: Issue #2277 documents that config may have moved from `~/.claude` to `~/.config/claude`. Check which your version uses by running `claude` once and observing where it creates files.

**Disable auto-updates**: AUR packages should not self-update. Run immediately after first launch:
```bash
claude config set -g autoUpdates disabled
```

**Line endings bug**: Issue #2805 reports Claude creates shell scripts with Windows CRLF endings on Linux. Fix generated scripts with:
```bash
sed -i 's/\r$//' script.sh
```

## Known issues affecting your planned use

| Feature | Issue | Status |
|---------|-------|--------|
| PreCompact hooks | Don't fire on `/compact` (Issue #13572) | **Open** |
| @ imports in ~/.claude/CLAUDE.md | Don't load (Issue #1041) | **Open** |
| Dotfile paths in @ imports | Not recognized (Issue #1941) | **Open** |
| Bash deny rules | Bypassed by absolute paths (Issue #11662) | **Open, security risk** |
| Auto-compact | Fails with Opus 4.5 thinking blocks (#12311) | **Open** |

## Verification summary

Your configuration assumptions are **85% accurate**. Key corrections:

1. Add `PermissionRequest` to your hook events list
2. Remove `~/.claude/rules/` from your directory structure—it's project-level only
3. Expand your tool names list to include MultiEdit, LS, WebFetch, WebSearch, TodoRead/Write, NotebookRead/Edit
4. Create the AUR symlink before relying on `claude` command
5. Don't rely on PreCompact hooks—they're currently broken
6. Consider using project-level CLAUDE.md instead of global for @ imports until bugs are fixed