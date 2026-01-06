# Claude Code Hivemind V2 - Context Transfer Document

**Created:** 2026-01-05  
**Purpose:** Transfer context for fresh verification in research mode  
**User:** Michael (Arch Linux, yay-installed claude-code, never run yet)

---

## TL;DR

Built a bash setup script that preconfigures `~/.claude` for:
- SQLite-based persistent memory across sessions
- Automatic context preservation before compaction events
- Self-spawning headless background agents (hivemind orchestration)
- Auto-updating project CLAUDE.md files with session learnings

**Script location:** `setup-claude-hivemind-v2.sh`

---

## What Was Built

### Directory Structure Created by Script

```
~/.claude/
├── CLAUDE.md                 # Global prompt with @ imports
├── settings.json             # All hooks + permissions
├── agents/
│   ├── orchestrator.md       # Multi-agent coordination
│   ├── researcher.md         # Read-only analysis
│   ├── implementer.md        # Code writing
│   └── meta-agent.md         # Creates new subagents
├── commands/
│   ├── hivemind.md           # /hivemind slash command
│   ├── memory.md             # /memory slash command
│   └── learn.md              # /learn slash command
├── hooks/
│   ├── session-start.sh      # DB init + context injection
│   ├── pre-compact.sh        # Memory save before compaction
│   ├── stop-autosave.sh      # Snapshot + learning export
│   └── session-end.sh        # Cleanup and logging
├── scripts/
│   ├── memory-db.py          # SQLite manager (Python)
│   ├── spawn-agent.sh        # Headless agent launcher
│   └── hivemind.sh           # Swarm orchestration CLI
├── memory/
│   ├── commands.md           # Reference doc (@ imported)
│   ├── hivemind.md           # Reference doc (@ imported)
│   └── compact-backups/      # Pre-compaction state saves
├── rules/                    # Conditional rules (future use)
└── agent-logs/               # Headless agent output
```

### SQLite Database Schema

```sql
-- Tables in claude.db (project or global)
memory          -- key/value store with categories
phases          -- workflow phase tracking with parent chains
agents          -- registered agent status/tasks
tasks           -- priority queue for agent work
context_snapshots -- timestamped state backups
learnings       -- session discoveries (auto-export to CLAUDE.md)
compaction_log  -- history of compact events
```

---

## V1 → V2 Fixes

| Issue | V1 Problem | V2 Fix |
|-------|------------|--------|
| **PreCompact hook** | MISSING - no memory save before context loss | Added with `auto` + `manual` matchers |
| **SessionStart format** | Wrong JSON output structure | Correct `hookSpecificOutput.additionalContext` format |
| **Project CLAUDE.md** | No auto-updates | Stop hook exports learnings table |
| **DB initialization** | Relied on prompt instruction (non-deterministic) | Now deterministic in SessionStart hook |
| **@ imports** | Not used | Global CLAUDE.md uses `@~/.claude/memory/*.md` |
| **SessionEnd hook** | Missing | Added for cleanup/logging |
| **Stop hook loops** | Not checked | Checks `stop_hook_active` from input |

---

## Documentation Sources Used

### Official (Fetched December 2025)

1. **code.claude.com/docs/en/hooks** - Full hooks reference
   - Hook events: SessionStart, PreCompact, Stop, SubagentStop, SessionEnd, PreToolUse, PostToolUse, UserPromptSubmit, Notification
   - Matchers: PreCompact uses `auto` or `manual`
   - Output format: `hookSpecificOutput.additionalContext` for SessionStart
   - Input format: JSON via stdin with `session_id`, `transcript_path`, `stop_hook_active`, etc.
   - Exit codes: 0=success, 2=blocking error

2. **code.claude.com/docs/en/memory** - Memory management
   - CLAUDE.md locations: `~/.claude/CLAUDE.md` (user), `./.claude/CLAUDE.md` (project)
   - @ import syntax: `@path/to/file.md` (relative or absolute)
   - Rules directory: `.claude/rules/*.md` auto-loaded
   - Max import depth: 5 hops

3. **Anthropic engineering blog** - Best practices
   - Headless mode: `claude -p "prompt" --output-format stream-json`
   - Subagent format: YAML frontmatter with `name`, `description`, `tools`, `model`
   - Git worktrees for parallel isolated instances

### Community/GitHub Issues Referenced

- Bug: `@~/.claude/...` paths may have issues on Linux (issue #8765)
- Feature request: PreCompact auto-save (issue #13239)
- claude-diary project: PreCompact hook pattern for memory preservation

---

## Key Technical Details

### Hook Output Formats (Verified)

**SessionStart** - Context injection:
```json
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "Your context string here"
  }
}
```

**PreCompact** - Cannot block, just backup:
```bash
# Matcher can be "auto" or "manual"
# Exit 0, stderr shown in verbose mode
# Save state to file before compaction wipes context
```

**Stop** - Can block with exit 2:
```json
{
  "decision": "block",
  "reason": "Must continue because X"
}
```

**Stop input** - Check for loops:
```json
{
  "session_id": "...",
  "stop_hook_active": true,  // If true, we're in a stop hook chain
  "transcript_path": "..."
}
```

### Headless Agent Spawning

```bash
claude -p "task prompt" \
  --output-format stream-json \
  --allowedTools "Read,Write,Edit,Bash,Grep,Glob" \
  > logfile.log 2>&1 &
```

### Subagent YAML Frontmatter

```markdown
---
name: agent-name
description: Use PROACTIVELY when... (triggers auto-delegation)
tools: Read, Write, Edit, Bash, Grep, Glob, Task
model: sonnet
---

System prompt content here...
```

---

## New Commands in V2

```bash
# Record learnings (auto-exported to project CLAUDE.md on Stop)
python3 ~/.claude/scripts/memory-db.py learning-add <type> "<content>"
# Types: decision, pattern, convention, bug, optimization, architecture

# Export unexported learnings manually
python3 ~/.claude/scripts/memory-db.py learnings-export

# Compact summary (called by PreCompact hook)
python3 ~/.claude/scripts/memory-db.py compact-summary <trigger>

# Compact dump for context injection
python3 ~/.claude/scripts/memory-db.py dump-compact
```

---

## What Needs Verification

### High Confidence (Verified Against Docs)
- ✅ Hook JSON output schemas match official docs
- ✅ PreCompact matchers `auto`/`manual` are documented
- ✅ SessionStart `additionalContext` format is correct
- ✅ Stop hook `stop_hook_active` check prevents loops
- ✅ Subagent YAML frontmatter format
- ✅ Headless mode CLI flags

### Medium Confidence (Docs Say Yes, Untested)
- ⚠️ Whether hooks actually fire in correct order
- ⚠️ Whether context injection appears in Claude's awareness
- ⚠️ Whether @ imports work with absolute `~/.claude/...` paths on Linux
- ⚠️ Whether learnings export creates valid markdown

### Low Confidence (Needs Testing)
- ❓ Timing of PreCompact relative to actual compaction
- ❓ SQLite concurrency with multiple headless agents
- ❓ Whether Claude Code reads ~/.claude/agents/*.md on Arch Linux
- ❓ Hook timeout behavior (set to 10-30s)

---

## Known Issues/Limitations

1. **@ paths on Linux** - GitHub issue #8765 reports `@~/.claude/...` not loading. Workaround: use relative paths or check `/memory` command output.

2. **PreCompact cannot block** - Per docs, exit code 2 for PreCompact only shows stderr to user, doesn't prevent compaction.

3. **No native cross-session memory** - Claude Code doesn't persist memory natively. This entire system is a workaround using hooks + SQLite.

4. **Context window consumption** - SessionStart injects memory dump, consuming tokens. Keep dumps concise.

5. **Hook approval required** - After running script, must use `/hooks` menu in Claude Code to approve new hooks.

---

## Installation & Testing

```bash
# Install
chmod +x setup-claude-hivemind-v2.sh
./setup-claude-hivemind-v2.sh

# Test memory system
python3 ~/.claude/scripts/memory-db.py init
python3 ~/.claude/scripts/memory-db.py set test_key "hello" testing
python3 ~/.claude/scripts/memory-db.py learning-add decision "Test learning"
python3 ~/.claude/scripts/memory-db.py dump

# Start Claude Code
claude

# In Claude Code:
# 1. Check /hooks - approve new hooks
# 2. Check /memory - verify files loaded
# 3. Test: /memory dump
# 4. Test: /learn decision "something important"
```

---

## Research Mode Verification Tasks

For a fresh chat in research mode, verify:

1. **Fetch current docs** - `code.claude.com/docs/en/hooks` and `/memory`
2. **Confirm hook output formats** - Especially SessionStart additionalContext
3. **Check PreCompact behavior** - Can it block? What's the input JSON?
4. **Verify @ import syntax** - Does `@~/.claude/...` work or only relative?
5. **Test subagent discovery** - Does Claude Code auto-load `~/.claude/agents/*.md`?
6. **Validate headless mode flags** - Is `--output-format stream-json` still current?

---

## File Deliverable

**Script:** `setup-claude-hivemind-v2.sh`  
**Size:** ~25KB  
**Components:** 4 hooks, 3 scripts, 4 agents, 3 commands, 2 memory docs, settings.json, CLAUDE.md

---

## Confidence Assessment

**Overall: 85%**

The infrastructure matches current docs. Unknowns are:
- Runtime behavior on Arch Linux specifically
- Whether hooks fire with expected timing
- SQLite locking under concurrent agent writes

The 15% uncertainty is "will this actually work when you run it" vs "does this match the docs" (which it does).
