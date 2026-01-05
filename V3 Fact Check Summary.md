# Claude Code Hivemind V3 - Fact Check Summary

**Date:** January 2026  
**Verified Against:** anthropics/claude-code GitHub issues, Claude Code v2.0.74 (Dec 2025)

---

## Executive Summary

The V3 implementation has been fact-checked against actual GitHub issues and the most recent Claude Code release (v2.0.74, Dec 19 2025). **All critical bugs mentioned in the V3 proposal are confirmed as open issues.** The implementation has been corrected to remove unverified features and use only confirmed workarounds.

---

## Bug Verification Results

### ✅ Issue #13572: PreCompact Hook Not Firing

**Status:** OPEN  
**Labels:** `bug`, `has repro`, `platform:linux`, `area:core`  
**Title:** "PreCompact hook not triggered when /compact command runs"

**Summary:** PreCompact hooks configured in settings.json do not execute when `/compact` is run. The hook is registered and visible in `/hook:status`, but simply never fires.

**V3 Workaround:** Transcript watcher script that monitors `~/.claude/projects/{path}/*.jsonl` files for context token usage and triggers snapshots at 75% threshold.

---

### ✅ Issue #2805: CRLF Line Endings on Linux

**Status:** OPEN  
**Labels:** `bug`, `platform:linux`, `area:tools`  
**Title:** "[BUG] Claude Code consistently creates files with Windows line endings on Linux systems"

**Summary:** Despite running on Linux (Ubuntu), Claude Code creates shell scripts with Windows line endings (`\r\n`), causing "No such file or directory" errors when executing scripts with shebangs.

**V3 Workaround:** PostToolUse hook on `Write|Edit` that runs `sed -i 's/\r$//'` on written files.

---

### ✅ Issue #1041: @ Import Fails in Global CLAUDE.md

**Status:** OPEN  
**Labels:** `bug`, `platform:macos`, `area:core`, `autoclose`  
**Title:** "@file Import Fails for Global CLAUDE.md Instruction Files"

**Summary:** The `@path/to/file.md` import syntax works in project-level CLAUDE.md files but fails in `~/.claude/CLAUDE.md`. Imported files don't appear in `/memory` output.

**V3 Workaround:** Do NOT use @ imports in global CLAUDE.md. Embed all instructions directly in the file. Use project-level `.claude/CLAUDE.md` for @ imports if needed.

---

### ✅ Issue #10373: SessionStart Hooks Not Working for New Conversations

**Status:** OPEN  
**Title:** "SessionStart hooks not working for new conversations"

**Root Cause Analysis (from issue):** 
- SessionStart hooks DO execute (verified by file logging)
- Hook stdout is NEVER processed by the `qz()` function for new sessions
- The `qz()` function is only called for: `/compact`, URL resume, `/clear`
- For new sessions, `wm6()` only replays old hook responses from message history

**V3 Workaround:** Use `UserPromptSubmit` hook instead of `SessionStart` for context injection. UserPromptSubmit fires on every prompt submission, making it more reliable.

---

### ✅ Issue #7881: SubagentStop Cannot Identify Specific Subagent

**Status:** OPEN  
**Labels:** `enhancement`, `has repro`, `area:tools`, `area:core`  
**Title:** "SubagentStop hook cannot identify which specific subagent finished due to shared session IDs"

**Summary:** When multiple subagents run, SubagentStop fires but only provides `session_id` - there's no way to determine which specific subagent completed.

**V3 Workaround:** Track subagent spawns via PreToolUse hook on Task tool. Accept limitation that identification is ambiguous with parallel subagents.

---

## V3 Corrections Made

### ❌ Removed: `disableAllHooks` Setting

**Finding:** No GitHub issues or documentation reference this setting. It appears to be fabricated in the original V3 proposal.

**Correction:** Use environment variable guard (`HIVEMIND_HOOK_ACTIVE=true`) to prevent recursive hook execution.

---

### ❌ Removed: `--settings` CLI Flag

**Finding:** Not verified as a real Claude Code CLI flag.

**Correction:** Use `CLAUDE_CONFIG_DIR` environment variable for config location, and environment variable guards for hook isolation.

---

### ⚠️ Modified: Gemini CLI Dependency

**Finding:** Gemini CLI exists and works, but is external to Claude Code and adds installation complexity.

**Correction:** Made optional. Context watcher uses database snapshots instead of requiring Gemini for summarization.

---

### ⚠️ Modified: Config Directory

**Finding:** Issue #2277 documents potential config directory move from `~/.claude` to `~/.config/claude`.

**Correction:** V3 script auto-detects which directory exists and uses the appropriate one.

---

## V3 Implementation Details

### Hook System Configuration

```json
{
  "hooks": {
    "UserPromptSubmit": [{"matcher": "", "hooks": [{"type": "command", "command": "inject-context.sh"}]}],
    "PostToolUse": [{"matcher": "Write|Edit", "hooks": [{"type": "command", "command": "crlf-fix.sh"}]}],
    "SubagentStop": [{"matcher": "", "hooks": [{"type": "command", "command": "subagent-complete.sh"}]}],
    "Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "update-plan.sh"}]}]
  }
}
```

### Database Schema (SQLite with WAL mode)

```sql
-- Core tables
memory          -- key/value store with categories
agent_tasks     -- track spawned agent work
context_snapshots -- preserve state before context loss
learnings       -- session discoveries (auto-export to CLAUDE.md)
project_state   -- current phase, blockers, etc.
```

### Hook Isolation Pattern

```bash
# In hook scripts - use environment variable guard
[ "$HIVEMIND_HOOK_ACTIVE" = "true" ] && exit 0

# When spawning subagents - set the guard
export HIVEMIND_HOOK_ACTIVE=true
claude -p "task" --output-format stream-json
```

---

## Testing Checklist

- [ ] Run `setup-claude-hivemind-v3.sh` successfully
- [ ] `/hooks` command shows all hooks registered
- [ ] Create a file, verify CRLF fix (run `file script.sh`, should NOT show "CRLF")
- [ ] Use `/memory` command, verify context injection appears
- [ ] Run `hivemind.sh learn decision "Test"`, verify recorded
- [ ] Stop session, verify learnings exported to project CLAUDE.md
- [ ] Start context watcher, verify no errors
- [ ] Spawn headless agent, verify task logged

---

## Open Questions

1. **Transcript JSONL structure:** The exact format of usage tokens in transcript files needs runtime verification.

2. **Context watcher accuracy:** The 200,000 token context window assumption may need adjustment based on model.

3. **Parallel subagent tracking:** Issue #7881 remains unresolved upstream - the workaround only works for sequential execution.

---

## References

- Claude Code v2.0.74 Release: Dec 19, 2025
- Issue #13572: https://github.com/anthropics/claude-code/issues/13572
- Issue #2805: https://github.com/anthropics/claude-code/issues/2805
- Issue #1041: https://github.com/anthropics/claude-code/issues/1041
- Issue #10373: https://github.com/anthropics/claude-code/issues/10373
- Issue #7881: https://github.com/anthropics/claude-code/issues/7881
