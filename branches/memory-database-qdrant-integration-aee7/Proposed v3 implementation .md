# Claude Code Hivemind V2: Complete Implementation Specification for Arch Linux

**January 2026 | Implementation-Ready Documentation**

This specification document provides everything needed to build the Claude Code Hivemind V2 orchestration system—a multi-agent coordination layer that leverages hooks, external LLMs, and shared database state to manage complex development workflows on Arch Linux.

---

## Architecture overview

The Hivemind system coordinates multiple Claude Code instances through a **SQLite-backed shared memory layer**, with Gemini CLI as a fallback/summarization engine. Hooks intercept key lifecycle events, while a transcript watcher monitors context window consumption to trigger preservation strategies before auto-compaction.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         HIVEMIND ORCHESTRATOR                                │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │  CLAUDE.md (Project Memory)                                             ││
│  │  ├── # Current Plan                                                     ││
│  │  ├── ## Phase Status (auto-updated by hooks)                            ││
│  │  └── ## Database Statute (last 5 entries + summary)                     ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                    │                                         │
│  ┌─────────────────────────────────▼────────────────────────────────────┐   │
│  │                      HOOK SYSTEM (.claude/settings.json)             │   │
│  │  SessionStart───►Load DB statute into context                        │   │
│  │  SubagentStop───►Write task completion to DB                         │   │
│  │  PostToolUse────►CRLF fix + file tracking                            │   │
│  │  Stop───────────►Update CLAUDE.md plan status                        │   │
│  │  UserPromptSubmit─►Context injection                                 │   │
│  └───────────────────────────────────┬──────────────────────────────────┘   │
│                                      │                                       │
│  ┌───────────────────────────────────▼──────────────────────────────────┐   │
│  │                    TRANSCRIPT WATCHER (Context Monitor)              │   │
│  │  ~/.claude/projects/{project}/*.jsonl                                │   │
│  │  ├── Parse last entry for usage.input_tokens                         │   │
│  │  ├── Calculate: (input + cache_read + cache_creation) / 200000       │   │
│  │  └── At 75%: trigger backup + manual /compact suggestion             │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                      │                                       │
│  ┌────────────────────┬──────────────┴───────────────┬──────────────────┐   │
│  │   SQLite DB        │      Gemini CLI              │   Subagent Pool  │   │
│  │   (WAL mode)       │      (summarizer)            │   (isolated)     │   │
│  │   hivemind.db      │      @google/gemini-cli      │   --settings     │   │
│  └────────────────────┴──────────────────────────────┴──────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## File paths and their purposes

| Path | Purpose |
|------|---------|
| `~/.claude/settings.json` | Global user hooks and preferences |
| `.claude/settings.json` | Project-shared hooks (team, git-tracked) |
| `.claude/settings.local.json` | Local hooks (personal, gitignored) |
| `~/.claude.json` | OAuth tokens, per-project trust state, MCP configs |
| `~/.claude/projects/{encoded-path}/{uuid}.jsonl` | Session transcripts |
| `./CLAUDE.md` | Project memory with execution plan |
| `./.claude/hivemind.db` | Shared SQLite database for swarm state |
| `./.claude/no-hooks.json` | Isolated settings for subagent spawning |
| `~/.claude/hooks/hivemind/` | Hook scripts directory |

**Path encoding rule**: Directory paths in transcript storage replace `/` with `-`. Example: `/home/user/projects/myapp` becomes `-home-user-projects-myapp`.

---

## All known issues with status and chosen workarounds

### Issue #13572: PreCompact hook not firing

**Status**: Open, unassigned, labeled `has repro`, `platform:linux`  
**Impact**: Critical—cannot preserve state before auto-compaction  
**Workaround chosen**: **Transcript watcher script** that monitors JSONL files for context growth and triggers manual preservation at 75% threshold. PreCompact hooks cannot be relied upon.

### Issue #1041: @ import fails in global CLAUDE.md

**Status**: Open since May 2025, no official fix  
**Impact**: Cannot use `@~/.claude/instructions.md` in global settings  
**Workaround chosen**: Place all @ imports in **project-level CLAUDE.md only**. For global instructions, embed content directly without @ references. The `hasClaudeMdExternalIncludesApproved: true` in `~/.claude.json` remains **unverified** as a solution—community reports mixed results.

### Issue #2805: CRLF line endings on Linux

**Status**: Open, **assigned to Anthropic engineer (blois)**, 14+ upvotes  
**Impact**: Shell scripts fail with `cannot execute: required file not found`  
**Workaround chosen**: PostToolUse hook that runs `sed -i 's/\r$//'` on all written files:

```json
{
  "PostToolUse": [{
    "matcher": "Write",
    "hooks": [{
      "type": "command",
      "command": "file_path=$(jq -r '.tool_input.file_path // empty'); [ -n \"$file_path\" ] && sed -i 's/\\r$//' \"$file_path\" || true"
    }]
  }]
}
```

### Issue #7881: SubagentStop cannot identify specific subagent

**Status**: Open, 11 upvotes, no official response  
**Impact**: When multiple subagents run, SubagentStop fires but provides only `session_id`—no way to know which subagent finished  
**Workaround chosen**: Track subagent spawns via **PreToolUse hook on Task tool**, storing agent metadata before completion. This breaks with parallel subagents but works for sequential execution.

### SessionStart additionalContext injection bugs (#10373, #15174)

**Status**: Multiple open issues confirm SessionStart output not injected for new conversations  
**Impact**: Cannot reliably load database statute at session start for fresh sessions  
**Workaround chosen**: **UserPromptSubmit hook** instead—more reliable for context injection. SessionStart reserved for `/clear` and `/compact` resume scenarios only.

---

## Complete hook configurations with verified JSON schemas

### Settings file location: `.claude/settings.json`

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume|compact",
        "hooks": [{
          "type": "command",
          "command": "~/.claude/hooks/hivemind/session-start.sh",
          "timeout": 10
        }]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [{
          "type": "command",
          "command": "~/.claude/hooks/hivemind/inject-context.sh"
        }]
      }
    ],
    "SubagentStop": [
      {
        "hooks": [{
          "type": "command",
          "command": "~/.claude/hooks/hivemind/subagent-complete.sh"
        }]
      }
    ],
    "Stop": [
      {
        "hooks": [{
          "type": "command",
          "command": "~/.claude/hooks/hivemind/update-plan.sh"
        }]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Write",
        "hooks": [{
          "type": "command",
          "command": "~/.claude/hooks/hivemind/crlf-fix.sh"
        }]
      },
      {
        "matcher": "Task",
        "hooks": [{
          "type": "command",
          "command": "~/.claude/hooks/hivemind/track-subagent-spawn.sh"
        }]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Task",
        "hooks": [{
          "type": "command",
          "command": "~/.claude/hooks/hivemind/register-subagent.sh"
        }]
      }
    ]
  }
}
```

### Hook input schemas

**Common fields (all hooks)**:
```json
{
  "session_id": "uuid-string",
  "transcript_path": "~/.claude/projects/{path}/{session}.jsonl",
  "cwd": "/absolute/path/to/project",
  "permission_mode": "default|plan|acceptEdits|bypassPermissions",
  "hook_event_name": "EventName"
}
```

**SubagentStop input** (complete):
```json
{
  "session_id": "cb67a406-fd98-47ca-9b03-fcca9cc43e8d",
  "transcript_path": "/home/user/.claude/projects/-path/session.jsonl",
  "permission_mode": "default",
  "hook_event_name": "SubagentStop",
  "stop_hook_active": false
}
```

**PreToolUse input for Task tool** (captures subagent metadata):
```json
{
  "hook_event_name": "PreToolUse",
  "tool_name": "Task",
  "tool_input": {
    "description": "Build authentication module",
    "prompt": "Create OAuth2 flow with refresh tokens"
  },
  "tool_use_id": "toolu_01ABC..."
}
```

### Hook output schemas

**Stop/SubagentStop blocking** (to continue agent work):
```json
{
  "decision": "block",
  "reason": "Continue with next phase: testing"
}
```

**UserPromptSubmit context injection** (plain text also works):
```json
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "## Database Statute\nLast 5 entries..."
  }
}
```

---

## Database schema

### File: `.claude/hivemind.db`

```sql
-- Enable WAL mode (run once, persists)
PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=5000;
PRAGMA synchronous=NORMAL;

-- Agent task tracking
CREATE TABLE agent_tasks (
    id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL,
    agent_type TEXT,           -- 'researcher', 'coder', 'tester'
    task_description TEXT,
    status TEXT DEFAULT 'running',  -- running, completed, failed
    started_at REAL DEFAULT (julianday('now')),
    completed_at REAL,
    result_summary TEXT,
    files_touched TEXT,        -- JSON array of file paths
    context_tokens_used INTEGER
);

CREATE INDEX idx_tasks_session ON agent_tasks(session_id);
CREATE INDEX idx_tasks_status ON agent_tasks(status);

-- Project state (for statute generation)
CREATE TABLE project_state (
    key TEXT PRIMARY KEY,
    value TEXT,
    updated_at REAL DEFAULT (julianday('now'))
);

-- Swarm coordination
CREATE TABLE swarm_queue (
    id TEXT PRIMARY KEY,
    priority INTEGER DEFAULT 5,
    task_type TEXT NOT NULL,
    payload TEXT,              -- JSON
    assigned_agent TEXT,
    created_at REAL DEFAULT (julianday('now')),
    claimed_at REAL
);

CREATE INDEX idx_queue_priority ON swarm_queue(priority DESC, created_at);

-- Context preservation (pre-compact snapshots)
CREATE TABLE context_snapshots (
    id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL,
    snapshot_type TEXT,        -- 'auto', 'manual'
    summary TEXT,
    key_facts TEXT,            -- JSON array
    active_files TEXT,         -- JSON array
    created_at REAL DEFAULT (julianday('now'))
);
```

### Database statute generation query

```sql
-- Get last 5 completed tasks + project summary for injection
SELECT 
    'Recent: ' || agent_type || ' - ' || 
    substr(task_description, 1, 50) || '... [' || status || ']'
FROM agent_tasks 
ORDER BY completed_at DESC 
LIMIT 5;

-- Combined with project state
SELECT key || ': ' || value 
FROM project_state 
WHERE key IN ('current_phase', 'blockers', 'next_milestone');
```

---

## Gemini CLI integration commands

### Installation on Arch Linux

```bash
# Install Node.js 18+ (required)
sudo pacman -S nodejs npm

# Install Gemini CLI globally
npm install -g @google/gemini-cli

# Or use without global install
npx @google/gemini-cli
```

### Authentication setup

```bash
# Option 1: API Key (recommended for automation)
export GEMINI_API_KEY="your-key-from-aistudio.google.com"

# Option 2: Interactive Google login
gemini
# Select "Login with Google" → browser auth
# Credentials cached at ~/.gemini/oauth_creds.json

# Persist in shell config
echo 'export GEMINI_API_KEY="YOUR_KEY"' >> ~/.bashrc
```

### Commands for Hivemind integration

```bash
# Summarize transcript for context preservation
cat session.jsonl | jq -r 'select(.type=="assistant") | .message.content[0].text' | \
  gemini -p "Summarize these Claude responses into key decisions and code changes. Be concise."

# Generate plan continuation
gemini -p "Given this project state, suggest next 3 development tasks:" < project-status.md

# Headless mode with JSON output (for scripting)
gemini -p "Analyze this error log" --output-format json < error.log | jq '.response'

# Rate limits on free tier
# 60 requests/minute, 1000 requests/day, Gemini 2.5 Pro model
```

---

## Swarm planning workflow

### Plan storage in CLAUDE.md

```markdown
# Project: MyApp Hivemind

## Current Execution Plan
**Phase**: 2 of 4 - API Development  
**Updated**: 2026-01-05T14:30:00Z  

### Phase 1: Setup [COMPLETE]
- [x] Initialize project structure
- [x] Configure database schema

### Phase 2: API Development [IN PROGRESS]
- [x] Auth endpoints (subagent-001)
- [ ] User CRUD (subagent-002 running)
- [ ] Permissions middleware (queued)

### Phase 3: Frontend [PENDING]
### Phase 4: Testing [PENDING]

## Database Statute
<!-- Auto-injected by UserPromptSubmit hook -->
Last 5 agent completions:
1. coder: Created auth module [completed]
2. researcher: Analyzed OAuth2 best practices [completed]
...

## Active Context
Current focus: Implementing JWT refresh token rotation
Blockers: None
```

### How plans get updated

1. **Stop hook** (`update-plan.sh`) reads CLAUDE.md, parses current phase, marks completed items
2. **SubagentStop hook** appends completion record to database
3. **UserPromptSubmit hook** regenerates Database Statute section from last 5 DB entries
4. **SessionStart hook** (on `/compact` resume) injects full plan context

---

## Auto-compact watcher script specification

### File: `~/.claude/hooks/hivemind/context-watcher.sh`

```bash
#!/bin/bash
# Context window watcher - monitors transcript growth
# Run as background process: nohup ./context-watcher.sh &

TRANSCRIPT_DIR="$HOME/.claude/projects"
MAX_CONTEXT=200000
WARN_THRESHOLD=75   # Warn at 75%
CRITICAL_THRESHOLD=90
CHECK_INTERVAL=30   # seconds
DB_PATH=".claude/hivemind.db"

calculate_usage() {
    local jsonl_file="$1"
    # Get last entry with usage data (skip sidechains)
    local usage=$(grep -v '"isSidechain":true' "$jsonl_file" | \
                  grep '"usage"' | tail -1 | \
                  jq -r '.message.usage // empty')
    
    if [ -n "$usage" ]; then
        local input=$(echo "$usage" | jq '(.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)')
        echo $((input * 100 / MAX_CONTEXT))
    else
        echo 0
    fi
}

preserve_context() {
    local jsonl_file="$1"
    local session_id=$(basename "$jsonl_file" .jsonl)
    local project_dir=$(dirname "$jsonl_file")
    
    # Extract key information before potential compaction
    local summary=$(jq -r 'select(.type=="assistant") | .message.content[0].text // empty' "$jsonl_file" | \
                   tail -c 10000 | \
                   gemini -p "Extract: 1) Key decisions made 2) Files modified 3) Current task status. Be very concise." 2>/dev/null)
    
    # Store snapshot in database
    sqlite3 "$project_dir/$DB_PATH" <<EOF
INSERT INTO context_snapshots (id, session_id, snapshot_type, summary, created_at)
VALUES ('snap-$(date +%s)', '$session_id', 'auto', '$(echo "$summary" | sed "s/'/''/g")', julianday('now'));
EOF
    
    echo "[$(date)] Preserved context for session $session_id"
}

while true; do
    # Find active transcripts (modified in last 5 minutes)
    for jsonl in $(find "$TRANSCRIPT_DIR" -name "*.jsonl" -mmin -5 2>/dev/null); do
        usage=$(calculate_usage "$jsonl")
        
        if [ "$usage" -gt "$CRITICAL_THRESHOLD" ]; then
            echo "[CRITICAL] $jsonl at ${usage}% - auto-compact imminent!"
            preserve_context "$jsonl"
            # Send desktop notification
            notify-send "Claude Context Critical" "Session at ${usage}% - preserved snapshot"
        elif [ "$usage" -gt "$WARN_THRESHOLD" ]; then
            echo "[WARNING] $jsonl at ${usage}%"
        fi
    done
    sleep $CHECK_INTERVAL
done
```

### Systemd user service (optional)

```ini
# ~/.config/systemd/user/hivemind-watcher.service
[Unit]
Description=Claude Code Hivemind Context Watcher

[Service]
ExecStart=%h/.claude/hooks/hivemind/context-watcher.sh
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
```

---

## Settings pollution prevention

### The isolated subagent config pattern

Create `.claude/no-hooks.json`:
```json
{
  "disableAllHooks": true
}
```

When spawning subagents from hooks:
```bash
# In hook scripts, spawn isolated subagents
claude --settings .claude/no-hooks.json -p "Analyze this file" --max-turns 5
```

### Preventing infinite loops

```bash
#!/bin/bash
# Hook script with loop prevention

# Method 1: Environment variable guard
if [ "$HIVEMIND_HOOK_ACTIVE" = "true" ]; then
    exit 0
fi
export HIVEMIND_HOOK_ACTIVE=true

# Method 2: Check stop_hook_active flag
input=$(cat)
stop_active=$(echo "$input" | jq -r '.stop_hook_active // false')
if [ "$stop_active" = "true" ]; then
    exit 0
fi

# Method 3: File lock to prevent concurrent hook execution
LOCK_FILE="/tmp/hivemind-hook-$(echo "$input" | jq -r '.session_id').lock"
if ! mkdir "$LOCK_FILE" 2>/dev/null; then
    exit 0
fi
trap "rmdir '$LOCK_FILE'" EXIT

# Your hook logic here...
```

---

## Step-by-step installation and testing

### Prerequisites

```bash
# Arch Linux packages
sudo pacman -S nodejs npm sqlite jq inotify-tools libnotify

# Verify versions
node --version   # Should be 18+
sqlite3 --version
```

### Installation

```bash
# 1. Create directory structure
mkdir -p ~/.claude/hooks/hivemind
mkdir -p ~/.claude/projects

# 2. Install Gemini CLI
npm install -g @google/gemini-cli
echo 'export GEMINI_API_KEY="your-key"' >> ~/.bashrc
source ~/.bashrc

# 3. Initialize project database
cd /your/project
mkdir -p .claude
sqlite3 .claude/hivemind.db < schema.sql  # Use schema from above

# 4. Create isolated subagent settings
cat > .claude/no-hooks.json << 'EOF'
{"disableAllHooks": true}
EOF

# 5. Copy hook scripts
cp context-watcher.sh ~/.claude/hooks/hivemind/
cp session-start.sh ~/.claude/hooks/hivemind/
cp subagent-complete.sh ~/.claude/hooks/hivemind/
cp inject-context.sh ~/.claude/hooks/hivemind/
cp crlf-fix.sh ~/.claude/hooks/hivemind/
chmod +x ~/.claude/hooks/hivemind/*.sh

# 6. Create settings.json with hook configs
cp settings.json .claude/settings.json

# 7. Start context watcher (background)
nohup ~/.claude/hooks/hivemind/context-watcher.sh > /tmp/hivemind-watcher.log 2>&1 &
```

### Testing procedure

```bash
# Test 1: Verify hooks are loaded
claude
# Type: /hooks
# Should show all configured hooks

# Test 2: Test CRLF fix
claude -p "Create a shell script called test.sh that prints hello world"
file test.sh   # Should show: "POSIX shell script, ASCII text executable"
# If CRLF: "POSIX shell script, ASCII text executable, with CRLF line terminators"

# Test 3: Test database write from SubagentStop
claude -p "Use the Task tool to create a simple function"
sqlite3 .claude/hivemind.db "SELECT * FROM agent_tasks ORDER BY started_at DESC LIMIT 1;"

# Test 4: Test context injection
# Check that UserPromptSubmit adds Database Statute to conversation
claude
# First message should include statute if DB has entries

# Test 5: Context watcher
# Check watcher log
tail -f /tmp/hivemind-watcher.log
# In another terminal, have a long conversation to build context
# Should see percentage updates

# Test 6: Gemini integration
echo "Test prompt" | gemini -p "Respond with OK"
# Should return response without errors
```

### Verification checklist

- [ ] Hooks load without errors (`/hooks` command)
- [ ] CRLF fix activates on Write tool (check file endings)
- [ ] SubagentStop writes to database
- [ ] UserPromptSubmit injects context (visible in conversation)
- [ ] Context watcher detects transcript growth
- [ ] Gemini CLI responds to prompts
- [ ] Isolated subagents don't trigger parent hooks
- [ ] No infinite loops when hooks spawn Claude processes

---

## Key limitations and caveats

**PreCompact hook is unreliable** (Issue #13572). Do not depend on it for context preservation. Use the transcript watcher instead.

**SubagentStop cannot identify which subagent finished** (Issue #7881). For parallel subagents, implement PreToolUse tracking of Task invocations, but accept that identification may be ambiguous.

**SessionStart additionalContext is buggy for new sessions** (Issues #10373, #15174). Use UserPromptSubmit for reliable context injection.

**CRLF bug affects Arch Linux** (Issue #2805, affects all Linux). The PostToolUse sed workaround is essential until officially fixed.

**@ imports fail in global CLAUDE.md** (Issue #1041). Use project-level files exclusively for @ import functionality.

**Task tool parallelism is capped at 10 concurrent subagents**. Design swarm workflows with this constraint—queue additional tasks rather than spawning more.

---

## Quick reference card

| Component | Command/Path |
|-----------|-------------|
| Check context usage | `/context` in Claude Code |
| View hooks | `/hooks` in Claude Code |
| Gemini summarize | `cat file \| gemini -p "summarize"` |
| Spawn isolated subagent | `claude --settings .claude/no-hooks.json -p "task"` |
| Check transcript | `~/.claude/projects/{encoded-path}/*.jsonl` |
| Database location | `.claude/hivemind.db` |
| Enable WAL mode | `PRAGMA journal_mode=WAL;` |
| Convert CRLF | `sed -i 's/\r$//' file` |
| Manual compact | `/compact` in Claude Code |

This specification reflects Claude Code's state as of January 2026. Monitor GitHub issues #13572, #7881, #2805, and #1041 for upstream fixes that may supersede these workarounds.