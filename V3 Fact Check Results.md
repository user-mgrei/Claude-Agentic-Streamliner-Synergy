# Claude Code Hivemind V3 - Fact Check Results

**Date:** January 5, 2026  
**Verified Against:** Claude Code 2.0.76  
**Methodology:** 4 Opus 4.5 agents working interoperably

---

## Executive Summary

The V3 proposed implementation is **CORRECT** with minor adjustments. All 5 critical bugs cited are **confirmed open** in the Claude Code GitHub repository. The workarounds proposed are **valid and verified** against current documentation and changelog.

---

## Bug Verification (All Confirmed)

| Issue | Title | Status | Verification |
|-------|-------|--------|--------------|
| **#13572** | PreCompact hook not firing on `/compact` | 🔴 OPEN | `gh issue view 13572` - has repro, platform:linux |
| **#1041** | @ imports fail in global CLAUDE.md | 🔴 OPEN | `gh issue view 1041` - open since May 2025 |
| **#2805** | CRLF line endings on Linux | 🔴 OPEN | `gh issue view 2805` - assigned to blois |
| **#7881** | SubagentStop can't identify subagent | 🔴 OPEN | `gh issue view 7881` - 11 upvotes |
| **#10373** | SessionStart not working for new sessions | 🔴 OPEN | `gh issue view 10373` - has repro |

---

## Feature Verification

### Confirmed Working ✅

| Feature | Evidence |
|---------|----------|
| `--settings` flag | Changelog: "Added `--settings` flag to load settings from a JSON file" |
| `disableAllHooks` setting | Changelog: "Added `disableAllHooks` setting" |
| `--output-format stream-json` | Changelog: "Print mode (-p) now supports streaming output via --output-format=stream-json" |
| `.claude/rules/` directory | Changelog v2.0.64: "Added support for .claude/rules/" |
| SQLite WAL mode | Standard SQLite feature, no issues reported |
| UserPromptSubmit hook | Used in official examples, no bugs reported |
| PostToolUse hooks | Used in official examples (see bash_command_validator_example.py) |
| PreToolUse hooks | Used in official examples |
| Stop/SubagentStop hooks | Documented, `stop_hook_active` field confirmed |

### Not Working ❌

| Feature | Issue |
|---------|-------|
| `~/.claude/rules/` (global) | Only project-level `.claude/rules/` supported |
| PreCompact hooks | Issue #13572 - doesn't fire |
| @ imports in global CLAUDE.md | Issue #1041 - fails silently |
| SessionStart additionalContext (new sessions) | Issue #10373 - only works on resume/clear/compact |

---

## Hook System Reference

### Verified Hook Events (10 total)

1. **PreToolUse** - Before tool execution
2. **PermissionRequest** - When permission dialog appears
3. **PostToolUse** - After tool execution
4. **Notification** - On notifications
5. **UserPromptSubmit** - Before prompt is sent (✅ reliable for context injection)
6. **Stop** - Main agent stopping
7. **SubagentStop** - Task tool subagent stopping
8. **PreCompact** - Before compaction (❌ broken - #13572)
9. **SessionStart** - On session start (⚠️ buggy for new sessions - #10373)
10. **SessionEnd** - On session end

### Exit Codes

| Code | Behavior |
|------|----------|
| 0 | Success - output parsed |
| 1 | Warning - stderr shown to user only |
| 2 | Block - stderr shown to Claude, action blocked |

### Hook Input (Common Fields)

```json
{
  "session_id": "uuid-string",
  "transcript_path": "~/.claude/projects/{encoded-path}/{session}.jsonl",
  "cwd": "/absolute/path/to/project",
  "permission_mode": "default|plan|acceptEdits|bypassPermissions",
  "hook_event_name": "EventName"
}
```

### Hook Output (Context Injection)

```json
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "Your context string here"
  }
}
```

---

## Workaround Verification

### 1. PreCompact → Transcript Watcher

**Status:** ✅ VALID

The transcript watcher approach monitors `~/.claude/projects/{path}/*.jsonl` files for context growth. Token usage is available in the JSONL under `message.usage.input_tokens`.

### 2. SessionStart → UserPromptSubmit

**Status:** ✅ VALID

UserPromptSubmit fires reliably on every prompt submission, making it suitable for context injection.

### 3. CRLF → PostToolUse sed fix

**Status:** ✅ VALID

PostToolUse on Write tool can run `sed -i 's/\r$//'` on the written file.

### 4. SubagentStop ID → PreToolUse tracking

**Status:** ✅ VALID (with limitations)

Track Task tool invocations via PreToolUse, storing `tool_use_id`. On SubagentStop, mark the most recent running task as complete. This has race conditions with parallel subagents but works for sequential execution.

### 5. @ imports → Embed in project CLAUDE.md

**Status:** ✅ VALID

@ imports work correctly in project-level `.claude/CLAUDE.md` files. Only global `~/.claude/CLAUDE.md` is affected by #1041.

---

## Gemini CLI Verification

**Package:** `@google/gemini-cli`  
**Version:** 0.22.5 (latest)  
**Repository:** https://github.com/google-gemini/gemini-cli

### Verified Features

- ✅ Free tier: 60 requests/min, 1000 requests/day
- ✅ Gemini 2.5 Pro with 1M token context
- ✅ Node.js 20+ required
- ✅ `gemini -p "prompt"` for headless mode
- ✅ `GEMINI_API_KEY` environment variable

### Installation

```bash
npm install -g @google/gemini-cli
# OR
brew install gemini-cli  # macOS/Linux
```

---

## V3 Implementation Changes

### Removed (broken features)

1. ❌ PreCompact hook configuration
2. ❌ @ imports in global `~/.claude/CLAUDE.md`
3. ❌ `~/.claude/rules/` directory (doesn't exist)
4. ❌ Reliance on SessionStart for new sessions

### Added (workarounds)

1. ✅ `context-watcher.sh` for monitoring context growth
2. ✅ UserPromptSubmit hook for context injection
3. ✅ PostToolUse(Write) hook for CRLF fix
4. ✅ PreToolUse(Task) hook for subagent tracking
5. ✅ `no-hooks.json` with `disableAllHooks: true`
6. ✅ `spawn-agent.sh` using `--settings` flag

### Retained (working features)

1. ✅ SQLite database with WAL mode
2. ✅ Stop hook for learnings export
3. ✅ SubagentStop hook for task completion
4. ✅ Headless mode with `--output-format stream-json`

---

## Arch Linux Specific Notes

### From Changelog/Issues

1. **AUR path**: May install to `/usr/sbin/claude` - symlink to `~/.local/bin/claude` if needed
2. **Auto-updates**: Disable with `claude config set -g autoUpdates disabled`
3. **Config directory**: Default is `~/.claude/`, but check with `ls -la ~/.claude` after first run

### CRLF Workaround (Essential)

The PostToolUse hook automatically fixes CRLF line endings:

```bash
file_path=$(jq -r '.tool_input.file_path' <<< "$input")
sed -i 's/\r$//' "$file_path"
```

---

## Testing Checklist

After running `setup-claude-hivemind-v3.sh`:

- [ ] Run `claude` and check `/hooks` - all hooks should be listed
- [ ] Test CRLF fix: Create a shell script, verify `file script.sh` shows no CRLF
- [ ] Test context injection: Check if statute appears in conversation
- [ ] Test subagent tracking: Run Task tool, check `memory-db.py dump`
- [ ] Test learnings: Add learning, stop session, check project CLAUDE.md
- [ ] Test isolated spawn: `spawn-agent.sh "test task"` - verify no hook loops

---

## Confidence Assessment

| Component | Confidence | Notes |
|-----------|------------|-------|
| Bug workarounds | 95% | All verified against open issues |
| Hook configurations | 90% | Based on official examples and changelog |
| SQLite operations | 95% | Standard SQLite, WAL mode is stable |
| Gemini CLI | 85% | API may change, free tier limits may change |
| Overall system | 88% | Main uncertainty is hook timing edge cases |

---

## Sources

1. **GitHub Issues**: `gh issue view {number} --repo anthropics/claude-code`
2. **Changelog**: `gh api repos/anthropics/claude-code/contents/CHANGELOG.md`
3. **Hook Example**: `examples/hooks/bash_command_validator_example.py`
4. **NPM Registry**: `npm view @anthropic-ai/claude-code` (v2.0.76)
5. **Gemini CLI**: `npm view @google/gemini-cli` (v0.22.5)
