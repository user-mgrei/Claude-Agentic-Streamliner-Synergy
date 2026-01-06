# Claude Code Hivemind V3 - Fact Check Summary

**Date**: January 2026  
**Claude Code Version Verified**: 2.0.76  
**Sources**: GitHub API, Official Plugins Repository, CHANGELOG

---

## Issue Verification

| Issue # | Title | Status | Impact on Hivemind |
|---------|-------|--------|-------------------|
| **#13572** | PreCompact hook not firing on /compact | **OPEN** ✗ | CRITICAL - Must use transcript watcher |
| **#1041** | @ imports fail in global CLAUDE.md | **OPEN** ✗ | No @ imports in ~/.config/claude/CLAUDE.md |
| **#2805** | CRLF line endings on Linux | **OPEN** ✗ | PostToolUse sed fix required |
| **#7881** | SubagentStop can't identify subagent | **OPEN** ✗ | Track via PreToolUse on Task tool |
| **#10373** | SessionStart not working for new sessions | **OPEN** ✗ | UserPromptSubmit fallback needed |
| **#15174** | SessionStart compact matcher not injected | **CLOSED** ✓ | Fixed in recent version |
| **#2277** | Config dir changed to ~/.config/claude | **CLOSED** ✓ | Must detect/support both paths |

---

## Hook System Verification

### Verified Hook Events (from CHANGELOG 2.0.x)
1. **SessionStart** - Matchers: `startup`, `resume`, `clear`, `compact`
2. **Stop** - Main agent stop
3. **SubagentStop** - Task tool completion
4. **PreToolUse** - Before tool execution (can modify inputs as of 2.0.10)
5. **PostToolUse** - After tool execution
6. **UserPromptSubmit** - On user message submission
7. **Notification** - System notifications
8. **PreCompact** - **BROKEN** (Issue #13572)

### ❌ NOT Found: PermissionRequest Hook
The V2 fact-check claimed this hook exists. **No evidence found** in:
- CHANGELOG (all versions)
- GitHub issues
- Official plugins

### Verified Hook Output Formats

**SessionStart** (from `plugins/explanatory-output-style/hooks-handlers/session-start.sh`):
```json
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "Your context string here"
  }
}
```

**Stop Blocking** (from `plugins/ralph-wiggum/hooks/stop-hook.sh`):
```json
{
  "decision": "block",
  "reason": "Prompt to send back to Claude",
  "systemMessage": "Status message for user"
}
```

**PreToolUse/PostToolUse Deny** (from `plugins/hookify/core/rule_engine.py`):
```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny"
  },
  "systemMessage": "Reason for denial"
}
```

### Hook Input Fields (Verified)
- `session_id` - Session identifier
- `transcript_path` - Path to JSONL transcript
- `cwd` - Current working directory
- `permission_mode` - default|plan|acceptEdits|bypassPermissions
- `hook_event_name` - Event type
- `stop_hook_active` - Boolean (Stop/SubagentStop only)
- `tool_name` - Tool being used (PreToolUse/PostToolUse)
- `tool_input` - Tool parameters (PreToolUse/PostToolUse)

---

## CLI Flags Verification

### ✓ Verified Flags (from CHANGELOG)
| Flag | Purpose | Version Added |
|------|---------|---------------|
| `-p` / `--print` | Headless/non-interactive mode | Original |
| `--output-format` | `text`, `json`, `stream-json` | Original |
| `--max-turns N` | Limit agentic turns | Original |
| `--permission-mode` | default|acceptEdits|bypassPermissions|plan | Original |
| `--dangerously-skip-permissions` | Skip all permission prompts | Original |
| `--resume SESSION_ID` | Resume specific session | Original |
| `--continue` / `-c` | Resume most recent | Original |
| `--max-budget-usd` | Budget limit | 2.0.28 |
| `--agents` | Add subagents dynamically | 2.0.0 |
| `--mcp-config` | Override MCP configuration | 2.0.30 |
| `--disable-slash-commands` | Disable slash commands | 2.0.60 |
| `--system-prompt` | Custom system prompt | 2.0.14 |
| `--system-prompt-file` | System prompt from file | 2.0.30 |
| `--agent` | Override agent setting | 2.0.59 |

### ❌ NOT Found: --settings Flag
The V3 proposal claimed:
```bash
claude --settings .claude/no-hooks.json -p "task"
```

**This flag does not exist.** No evidence in:
- CHANGELOG (searched all versions)
- GitHub issues
- npm package

### ❌ NOT Found: disableAllHooks Setting
The V3 proposal claimed:
```json
{"disableAllHooks": true}
```

**This setting does not exist.** No evidence in any documentation.

---

## Config Directory

### Change History
- **Before ~v1.0.29**: `~/.claude/`
- **After ~v1.0.29**: `~/.config/claude/`

Issue #2277 documents this change was undocumented, causing user confusion.

### V3 Implementation
```bash
# Detect config directory (support both)
if [ -d "$HOME/.config/claude" ]; then
    CLAUDE_DIR="$HOME/.config/claude"
elif [ -d "$HOME/.claude" ]; then
    CLAUDE_DIR="$HOME/.claude"
else
    CLAUDE_DIR="$HOME/.config/claude"  # New default
fi
```

---

## Transcript Format (Verified)

From `plugins/ralph-wiggum/hooks/stop-hook.sh`:

- **Format**: JSONL (one JSON object per line)
- **Assistant messages**: `{"role":"assistant", "message": {"content": [...]}}`
- **Content structure**: Array of `{type: "text", text: "..."}` objects

**Example extraction**:
```bash
grep '"role":"assistant"' "$TRANSCRIPT_PATH" | tail -1 | jq -r '
  .message.content |
  map(select(.type == "text")) |
  map(.text) |
  join("\n")
'
```

---

## Gemini CLI (Verified)

- **Package**: `@google/gemini-cli`
- **Version**: 0.22.5 (as of verification)
- **Installation**: `npm install -g @google/gemini-cli`

**Note**: The V3 proposal's Gemini integration syntax should be verified against actual CLI behavior, as the npm description is minimal.

---

## Corrections Made in V3 Script

| V2/V3 Proposal Claim | Correction |
|---------------------|------------|
| `--settings` flag exists | ❌ Removed - use environment guards |
| `disableAllHooks` setting | ❌ Removed - use environment guards |
| Config at `~/.claude/` | ✓ Detect both, default `~/.config/claude/` |
| PreCompact hooks work | ❌ Transcript watcher required |
| SessionStart reliable | ⚠️ Added UserPromptSubmit fallback |
| `~/.claude/rules/` exists | ❌ Removed - only project-level |
| PermissionRequest hook | ❌ Not found - removed from docs |

---

## Workarounds Implemented

### 1. PreCompact Hook Broken (Issue #13572)
**Solution**: Background transcript watcher script that monitors JSONL files and triggers preservation at 75%/90% context thresholds.

### 2. SessionStart Unreliable (Issue #10373)
**Solution**: Dual approach - SessionStart for resume/compact, UserPromptSubmit for new sessions.

### 3. SubagentStop Can't Identify Subagent (Issue #7881)
**Solution**: PreToolUse hook on Task tool tracks spawns before completion.

### 4. CRLF Line Endings (Issue #2805)
**Solution**: PostToolUse hook on Write tool runs `sed -i 's/\r$//'`.

### 5. No --settings Flag for Isolated Subagents
**Solution**: Environment variable guards (`HIVEMIND_SPAWNED_AGENT`, `HIVEMIND_CONTEXT_INJECTED`) that hooks check before executing.

---

## Testing Checklist

- [ ] Hooks load without errors (`/hooks` command)
- [ ] CRLF fix activates on Write tool
- [ ] SubagentStop writes to database
- [ ] Context watcher detects transcript growth
- [ ] Learnings export to project CLAUDE.md on Stop
- [ ] Environment guards prevent hook loops
- [ ] Database operates in WAL mode

---

## References

- **Claude Code Repository**: https://github.com/anthropics/claude-code
- **Official Docs**: https://docs.anthropic.com/en/docs/claude-code/overview
- **npm Package**: @anthropic-ai/claude-code v2.0.76
- **Verified Plugins**: hookify, ralph-wiggum, explanatory-output-style
