# Claude Code CLI configuration and hooks reference (January 2026)

Claude Code's hooks system enables programmatic control over agent lifecycle events, but **several critical Linux bugs remain unresolved** including PreCompact hooks not firing (#13572) and CRLF line endings breaking scripts (#2805). The headless CLI syntax `claude -p "prompt" --output-format stream-json` remains correct, with subagents inheriting all hooks from `~/.claude/settings.json`—a behavior that can cause infinite loops if hooks spawn additional Claude processes.

## Hooks system: complete technical reference

The hooks system fires at specific lifecycle events, accepting JSON input on stdin and producing JSON output on stdout. **Default timeout is 60 seconds**, configurable per-command via the `timeout` field. All matching hooks execute in parallel with automatic deduplication.

### SubagentStop hook

Fires when a subagent (Task tool call) completes—not the main agent, which uses the `Stop` hook instead. The input JSON includes a critical `stop_hook_active` field:

```json
{
  "session_id": "abc123",
  "transcript_path": "~/.claude/projects/.../session.jsonl",
  "permission_mode": "default",
  "hook_event_name": "SubagentStop",
  "stop_hook_active": true
}
```

When `stop_hook_active` is true, Claude is already continuing from a previous stop hook—**check this value to prevent infinite loops**. Output format uses `decision: "block"` with mandatory `reason` field to prevent stopping:

```json
{
  "decision": "block",
  "reason": "Subagent must verify test results before stopping"
}
```

### SessionStart hook with additionalContext

Fires on startup, resume, clear, or compact operations. Matchers include `startup`, `resume`, `clear`, and `compact`. The `additionalContext` format adds strings to conversation context:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "Project uses Node 20 with strict TypeScript"
  }
}
```

Multiple hooks' `additionalContext` values concatenate. **SessionStart hooks exclusively access `CLAUDE_ENV_FILE`** for persisting environment variables across the session.

### PreCompact hook status: Issue #13572 confirmed open

Matchers support `manual` (from `/compact` command) and `auto` (context window full). Input includes `trigger` and `custom_instructions` fields. **However, Issue #13572 confirms PreCompact hooks are not firing on the `/compact` command**—this bug remains open with no workaround. The hook is correctly configured and visible in `/hook:status` but simply doesn't execute.

### PostToolUse matcher syntax for multiple tools

Use pipe-separated regex patterns: `"matcher": "Write|Edit|MultiEdit"`. Full tool matcher list includes `Bash`, `Read`, `Write`, `Edit`, `Glob`, `Grep`, `WebFetch`, `WebSearch`, `Task`, and wildcard `*`. MCP tools follow the pattern `mcp__<server>__<tool>` with regex support like `mcp__memory__.*`.

## Known Linux bugs and their current status

| Issue | Status | Description | Workaround |
|-------|--------|-------------|------------|
| **#13572** | Open | PreCompact hooks not firing on `/compact` | None—run scripts manually |
| **#1041** | Open | @ imports fail in global `~/.claude/CLAUDE.md` | Use project-level CLAUDE.md |
| **#2277** | Open | Config directory changed to `~/.config/claude` | Set `CLAUDE_CONFIG_DIR` or move configs |
| **#1941** | **Closed** | Dotfile paths in @ imports not recognized | Fixed |
| **#2805** | Open | CRLF line endings in generated scripts | `sed -i 's/\r$//' script.sh` |

The **CRLF issue (#2805)** has significant community impact with 14+ reactions. Despite running on Ubuntu, Claude generates Windows line endings, breaking shebangs. The config directory confusion (#2277) lacks documentation—users should explicitly set `CLAUDE_CONFIG_DIR=~/.claude` if using the traditional location.

### AUR installation requires manual intervention

Arch users face Node.js version compatibility issues (downgrade to 23.11.0), bloated ripgrep binaries (symlink system `rg` to save 54MB), and must disable auto-updates via `claude config set -g autoUpdates disabled` to avoid permission errors.

## Headless agent spawning: verified syntax

The correct headless syntax remains:
```bash
claude -p "prompt" --output-format stream-json --permission-mode acceptEdits
```

**Valid permission modes**: `default` (standard prompts), `acceptEdits` (auto-approve edits), `plan` (read-only analysis), `bypassPermissions` (skip all—dangerous). Output formats include `text`, `json`, and `stream-json` (NDJSON for streaming).

### Subagent hooks inheritance creates loop risk

Subagents **do inherit hooks** from `~/.claude/settings.json` and project settings. This creates a dangerous infinite loop if a hook spawns additional Claude processes. The solution is passing separate settings:

```bash
# In hook script, spawn subagent without hooks
claude -p "subtask" --settings no-hooks.json
```

Where `no-hooks.json` contains `{"disableAllHooks": true}`. If the `tools` field is omitted in subagent definitions, they inherit **all tools including MCP**—whitelist explicitly for security.

## Memory system and CLAUDE.md precedence

The exact precedence order (highest to lowest):
1. **Enterprise policy**: `/etc/claude-code/CLAUDE.md` (Linux)
2. **Project memory**: `./CLAUDE.md` or `./.claude/CLAUDE.md`
3. **User memory**: `~/.claude/CLAUDE.md`
4. **Project local**: `./CLAUDE.local.md` (auto-gitignored)

Memory files load recursively from cwd toward root. Nested CLAUDE.md files in subdirectories load on-demand when accessing those subtrees.

### @ import syntax and the 5-hop depth limit

Import syntax uses `@path/to/file.md` with support for home directory (`@~/.claude/shared.md`) and relative paths. **Maximum import depth is 5 hops**—beyond this, nested imports silently fail. URL imports are not supported. Imports inside markdown code blocks are correctly ignored.

**Known limitation**: Issue #1041 confirms @ imports in `~/.claude/CLAUDE.md` don't resolve properly—use project-level CLAUDE.md as workaround.

### Symlinks have inconsistent support

Symlinks for `.claude/rules/` directory work correctly. However, **symlinks for `.claude/commands/` broke in v2.0.28** (Issue #10573), and symlinking `~/.claude` itself causes user commands to not be discovered (#764).

## settings.json structure with hooks and permissions

```json
{
  "permissions": {
    "allow": ["Bash(npm run:*)", "Bash(git:*)", "Edit"],
    "ask": ["Bash(git push:*)"],
    "deny": ["Bash(rm -rf:*)", "Read(./.env)", "Read(./secrets/**)"]
  },
  "hooks": {
    "PostToolUse": [{
      "matcher": "Write|Edit",
      "hooks": [{
        "type": "command",
        "command": "npx prettier --write \"$1\"",
        "timeout": 30
      }]
    }],
    "SessionStart": [{
      "matcher": "startup",
      "hooks": [{
        "type": "command",
        "command": "echo 'export NODE_ENV=dev' >> \"$CLAUDE_ENV_FILE\""
      }]
    }]
  },
  "env": {
    "BASH_DEFAULT_TIMEOUT_MS": "30000",
    "MAX_THINKING_TOKENS": "50000"
  }
}
```

Tool patterns support exact match (`Bash(npm run lint)`), prefix wildcards (`Bash(git:*)`), and recursive globs (`Read(./secrets/**)`). **Critical bug**: Issues #6699/#6631 report `deny` permissions may not enforce for Read/Write tools—use PreToolUse hooks for security-critical restrictions.

## Subagent YAML frontmatter format

Files in `~/.claude/agents/*.md` or `.claude/agents/*.md` use this structure:

```yaml
---
name: security-auditor
description: Use PROACTIVELY when reviewing auth or data handling code
tools: Read, Grep, Glob, Bash
model: opus
permissionMode: default
---

You are a security expert. Focus on authentication flaws and data exposure.
```

**Required fields**: `name` (lowercase with hyphens) and `description`. **Optional fields**: `tools` (comma-separated, inherits all if omitted), `model` (`sonnet`/`opus`/`haiku`/`inherit`), `permissionMode`, `skills`, `color`. Project subagents take precedence over user subagents with the same name.

### Available tools for subagent configuration

Core tools: `Read`, `Write`, `Edit`, `MultiEdit`, `Bash`, `Glob`, `Grep`, `LS`, `WebFetch`, `WebSearch`, `Task`, `TodoWrite`, `TodoRead`, `NotebookEdit`, `NotebookRead`, `Skill`, `SlashCommand`, `AskUserQuestion`. MCP tools use `mcp__<server>__<tool>` format.

Auto-discovery scans both directories at startup, loading all `.md` files with valid frontmatter. Files created via `/agents` command are available immediately; manually created files require restart.

## December 2025 documentation changes flagged

Several items differ from or update December 2025 documentation: the config directory default has shifted toward `~/.config/claude` on some Linux systems (#2277), the `permissions.deny` enforcement bug makes hooks necessary for security, PreCompact hooks have a blocking bug preventing `/compact` triggering, and the `disableAllHooks` setting in separate config files is the recommended pattern for preventing subagent hook loops.