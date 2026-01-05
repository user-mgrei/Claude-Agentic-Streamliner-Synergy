#!/bin/bash
#===============================================================================
# Claude Code Hivemind Setup Script V3
# 
# VERIFIED AGAINST: anthropics/claude-code repo (January 2026)
# DOCUMENTATION: https://docs.anthropic.com/en/docs/claude-code/overview
#
# V3 CHANGES FROM V2 (Based on fact-checking):
#   - REMOVED: PreCompact hooks (Issue #13572 confirms they don't fire)
#   - REMOVED: ~/.claude/rules/ directory (project-level only)
#   - ADDED: PostToolUse CRLF fix hook (Issue #2805 workaround)
#   - ADDED: UserPromptSubmit for context injection (more reliable than SessionStart)
#   - ADDED: Transcript watcher for context monitoring (replaces broken PreCompact)
#   - FIXED: Hook JSON structure matches official plugin patterns
#   - FIXED: Settings isolation for subagents (empty hooks, not disableAllHooks)
#   - REMOVED: Global @ imports (Issue #1041 confirms they fail)
#
# Target: Arch Linux with yay-installed claude-code
#===============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}==> Claude Code Hivemind V3 Setup${NC}"
echo ""

#===============================================================================
# VERIFY PREREQUISITES
#===============================================================================
echo -e "${YELLOW}Checking prerequisites...${NC}"

# Check for required tools
for cmd in python3 sqlite3 jq; do
    if ! command -v $cmd &> /dev/null; then
        echo -e "${RED}ERROR: $cmd is required but not installed${NC}"
        echo "Install with: sudo pacman -S $cmd"
        exit 1
    fi
done

# Check for optional tools
if ! command -v notify-send &> /dev/null; then
    echo -e "${YELLOW}WARNING: libnotify not installed - desktop notifications disabled${NC}"
    echo "Install with: sudo pacman -S libnotify"
fi

echo -e "${GREEN}✓ Prerequisites OK${NC}"
echo ""

#===============================================================================
# DIRECTORY SETUP
#===============================================================================
CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks/hivemind"
SCRIPTS_DIR="$CLAUDE_DIR/scripts"
AGENTS_DIR="$CLAUDE_DIR/agents"
COMMANDS_DIR="$CLAUDE_DIR/commands"

echo -e "${YELLOW}Creating directory structure...${NC}"
mkdir -p "$HOOKS_DIR" "$SCRIPTS_DIR" "$AGENTS_DIR" "$COMMANDS_DIR"
mkdir -p "$CLAUDE_DIR/agent-logs"
echo -e "${GREEN}✓ Directories created${NC}"

#===============================================================================
# SQLITE MEMORY MANAGER (ENHANCED FOR V3)
#===============================================================================
echo -e "${YELLOW}Installing memory database manager...${NC}"

cat > "$SCRIPTS_DIR/memory-db.py" << 'MEMORY_SCRIPT'
#!/usr/bin/env python3
"""
Claude Code Hivemind SQLite Memory Manager V3
Database location: PROJECT_DIR/.claude/hivemind.db (per-project)

Changes in V3:
  - WAL mode for concurrent access from multiple agents
  - Simplified schema focused on practical use
  - Added context preservation without PreCompact hook
"""
import sqlite3
import json
import sys
import os
from datetime import datetime
from pathlib import Path

def get_db_path():
    """Get database path - always project-level"""
    cwd = os.environ.get('CLAUDE_CWD', os.getcwd())
    project_db = Path(cwd) / '.claude' / 'hivemind.db'
    project_db.parent.mkdir(parents=True, exist_ok=True)
    return project_db

def init_db(conn):
    """Initialize database with WAL mode and schema"""
    # Enable WAL mode for concurrent access
    conn.execute('PRAGMA journal_mode=WAL')
    conn.execute('PRAGMA busy_timeout=5000')
    conn.execute('PRAGMA synchronous=NORMAL')
    
    conn.executescript('''
        -- Key/value memory store
        CREATE TABLE IF NOT EXISTS memory (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL,
            category TEXT DEFAULT 'general',
            updated_at TEXT DEFAULT (datetime('now'))
        );
        
        -- Agent task tracking (for SubagentStop identification)
        CREATE TABLE IF NOT EXISTS agent_tasks (
            id TEXT PRIMARY KEY,
            tool_use_id TEXT,
            description TEXT,
            status TEXT DEFAULT 'running',
            started_at TEXT DEFAULT (datetime('now')),
            completed_at TEXT,
            result_summary TEXT
        );
        
        -- Context snapshots (for manual preservation)
        CREATE TABLE IF NOT EXISTS context_snapshots (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT,
            snapshot_type TEXT DEFAULT 'manual',
            summary TEXT,
            key_facts TEXT,
            created_at TEXT DEFAULT (datetime('now'))
        );
        
        -- Session learnings (exported to CLAUDE.md)
        CREATE TABLE IF NOT EXISTS learnings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            learning_type TEXT NOT NULL,
            content TEXT NOT NULL,
            exported INTEGER DEFAULT 0,
            created_at TEXT DEFAULT (datetime('now'))
        );
        
        CREATE INDEX IF NOT EXISTS idx_memory_category ON memory(category);
        CREATE INDEX IF NOT EXISTS idx_tasks_status ON agent_tasks(status);
        CREATE INDEX IF NOT EXISTS idx_learnings_exported ON learnings(exported);
    ''')
    conn.commit()

def ensure_db():
    """Get database connection, initializing if needed"""
    db_path = get_db_path()
    conn = sqlite3.connect(str(db_path), timeout=10.0)
    init_db(conn)
    return conn

def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "Usage: memory-db.py <command> [args]"}))
        sys.exit(1)
    
    cmd = sys.argv[1]
    
    try:
        conn = ensure_db()
        cursor = conn.cursor()
        
        if cmd == "init":
            print(json.dumps({"status": "initialized", "db_path": str(get_db_path())}))
        
        elif cmd == "set":
            if len(sys.argv) < 4:
                print(json.dumps({"error": "Usage: set <key> <value> [category]"}))
                sys.exit(1)
            key, value = sys.argv[2], sys.argv[3]
            category = sys.argv[4] if len(sys.argv) > 4 else 'general'
            cursor.execute('''
                INSERT INTO memory (key, value, category, updated_at) 
                VALUES (?, ?, ?, datetime('now'))
                ON CONFLICT(key) DO UPDATE SET 
                    value=excluded.value, category=excluded.category, updated_at=datetime('now')
            ''', (key, value, category))
            conn.commit()
            print(json.dumps({"status": "set", "key": key}))
        
        elif cmd == "get":
            if len(sys.argv) < 3:
                print(json.dumps({"error": "Usage: get <key>"}))
                sys.exit(1)
            cursor.execute('SELECT value, category FROM memory WHERE key = ?', (sys.argv[2],))
            row = cursor.fetchone()
            print(json.dumps({"key": sys.argv[2], "value": row[0] if row else None, "category": row[1] if row else None}))
        
        elif cmd == "list":
            category = sys.argv[2] if len(sys.argv) > 2 else None
            if category:
                cursor.execute('SELECT key, value, category FROM memory WHERE category = ?', (category,))
            else:
                cursor.execute('SELECT key, value, category FROM memory')
            rows = cursor.fetchall()
            print(json.dumps({"memories": [{"key": r[0], "value": r[1], "category": r[2]} for r in rows]}))
        
        elif cmd == "task-start":
            if len(sys.argv) < 4:
                print(json.dumps({"error": "Usage: task-start <id> <description> [tool_use_id]"}))
                sys.exit(1)
            task_id = sys.argv[2]
            desc = sys.argv[3]
            tool_use_id = sys.argv[4] if len(sys.argv) > 4 else None
            cursor.execute('''
                INSERT OR REPLACE INTO agent_tasks (id, tool_use_id, description, status, started_at)
                VALUES (?, ?, ?, 'running', datetime('now'))
            ''', (task_id, tool_use_id, desc))
            conn.commit()
            print(json.dumps({"status": "started", "task_id": task_id}))
        
        elif cmd == "task-complete":
            if len(sys.argv) < 3:
                print(json.dumps({"error": "Usage: task-complete <id> [result]"}))
                sys.exit(1)
            task_id = sys.argv[2]
            result = sys.argv[3] if len(sys.argv) > 3 else None
            cursor.execute('''
                UPDATE agent_tasks SET status='completed', completed_at=datetime('now'), result_summary=?
                WHERE id=?
            ''', (result, task_id))
            conn.commit()
            print(json.dumps({"status": "completed", "task_id": task_id}))
        
        elif cmd == "task-list":
            cursor.execute('SELECT id, description, status, started_at, completed_at FROM agent_tasks ORDER BY started_at DESC LIMIT 20')
            rows = cursor.fetchall()
            print(json.dumps({"tasks": [{"id": r[0], "desc": r[1], "status": r[2], "started": r[3], "completed": r[4]} for r in rows]}))
        
        elif cmd == "learning-add":
            if len(sys.argv) < 4:
                print(json.dumps({"error": "Usage: learning-add <type> <content>"}))
                sys.exit(1)
            cursor.execute('INSERT INTO learnings (learning_type, content) VALUES (?, ?)', (sys.argv[2], sys.argv[3]))
            conn.commit()
            print(json.dumps({"status": "added", "id": cursor.lastrowid}))
        
        elif cmd == "learnings-export":
            cursor.execute('SELECT id, learning_type, content FROM learnings WHERE exported=0')
            rows = cursor.fetchall()
            if rows:
                ids = [r[0] for r in rows]
                cursor.execute(f'UPDATE learnings SET exported=1 WHERE id IN ({",".join("?" * len(ids))})', ids)
                conn.commit()
            print(json.dumps({"learnings": [{"id": r[0], "type": r[1], "content": r[2]} for r in rows]}))
        
        elif cmd == "snapshot-save":
            if len(sys.argv) < 3:
                print(json.dumps({"error": "Usage: snapshot-save <session_id> [summary] [type]"}))
                sys.exit(1)
            session_id = sys.argv[2]
            summary = sys.argv[3] if len(sys.argv) > 3 else ""
            snap_type = sys.argv[4] if len(sys.argv) > 4 else "manual"
            cursor.execute('INSERT INTO context_snapshots (session_id, snapshot_type, summary) VALUES (?, ?, ?)',
                          (session_id, snap_type, summary))
            conn.commit()
            print(json.dumps({"status": "saved", "id": cursor.lastrowid}))
        
        elif cmd == "dump":
            cursor.execute('SELECT key, value, category FROM memory ORDER BY updated_at DESC LIMIT 30')
            memories = cursor.fetchall()
            cursor.execute('SELECT id, description, status FROM agent_tasks WHERE status="running"')
            active = cursor.fetchall()
            print(json.dumps({
                "memories": {r[0]: {"value": r[1][:200], "category": r[2]} for r in memories},
                "active_tasks": [{"id": r[0], "desc": r[1], "status": r[2]} for r in active]
            }, indent=2))
        
        elif cmd == "statute":
            # Generate concise statute for context injection
            cursor.execute('SELECT key, value FROM memory ORDER BY updated_at DESC LIMIT 10')
            memories = cursor.fetchall()
            cursor.execute('SELECT description, status, completed_at FROM agent_tasks ORDER BY completed_at DESC LIMIT 5')
            tasks = cursor.fetchall()
            
            lines = ["## Hivemind Statute"]
            if memories:
                lines.append("**Memory:**")
                for k, v in memories:
                    lines.append(f"- {k}: {v[:100]}...")
            if tasks:
                lines.append("**Recent Tasks:**")
                for desc, status, completed in tasks:
                    lines.append(f"- [{status}] {desc[:60]}...")
            
            print("\n".join(lines) if len(lines) > 1 else "No statute data yet.")
        
        else:
            print(json.dumps({"error": f"Unknown command: {cmd}"}))
            sys.exit(1)
            
    except Exception as e:
        print(json.dumps({"error": str(e)}))
        sys.exit(1)
    finally:
        if 'conn' in dir():
            conn.close()

if __name__ == "__main__":
    main()
MEMORY_SCRIPT

chmod +x "$SCRIPTS_DIR/memory-db.py"
echo -e "${GREEN}✓ Memory database manager installed${NC}"

#===============================================================================
# HOOK: CRLF FIX (PostToolUse for Write)
# Workaround for Issue #2805
#===============================================================================
echo -e "${YELLOW}Installing CRLF fix hook...${NC}"

cat > "$HOOKS_DIR/crlf-fix.sh" << 'CRLF_HOOK'
#!/bin/bash
# PostToolUse hook to fix CRLF line endings (Issue #2805 workaround)
# Triggers on Write tool to convert any Windows line endings to Unix

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.filePath // empty' 2>/dev/null)

if [[ -n "$FILE_PATH" ]] && [[ -f "$FILE_PATH" ]]; then
    # Check if file contains CRLF
    if file "$FILE_PATH" 2>/dev/null | grep -q "CRLF"; then
        sed -i 's/\r$//' "$FILE_PATH" 2>/dev/null
        echo '{"systemMessage": "Fixed CRLF line endings in '"$FILE_PATH"'"}' 
    fi
fi

exit 0
CRLF_HOOK

chmod +x "$HOOKS_DIR/crlf-fix.sh"
echo -e "${GREEN}✓ CRLF fix hook installed${NC}"

#===============================================================================
# HOOK: CONTEXT INJECTION (UserPromptSubmit)
# More reliable than SessionStart (Issue #10373)
#===============================================================================
echo -e "${YELLOW}Installing context injection hook...${NC}"

cat > "$HOOKS_DIR/inject-context.sh" << 'INJECT_HOOK'
#!/bin/bash
# UserPromptSubmit hook for context injection
# More reliable than SessionStart which has bugs (#10373)

MEMORY_SCRIPT="$HOME/.claude/scripts/memory-db.py"
INPUT=$(cat)

# Get project directory from hook input
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
if [[ -z "$CWD" ]]; then
    CWD=$(pwd)
fi

export CLAUDE_CWD="$CWD"

# Check if database exists for this project
if [[ -f "$CWD/.claude/hivemind.db" ]]; then
    STATUTE=$(python3 "$MEMORY_SCRIPT" statute 2>/dev/null)
    
    if [[ -n "$STATUTE" ]] && [[ "$STATUTE" != "No statute data yet." ]]; then
        # Output additionalContext format
        cat << EOF
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": $(echo "$STATUTE" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')
  }
}
EOF
    fi
fi

exit 0
INJECT_HOOK

chmod +x "$HOOKS_DIR/inject-context.sh"
echo -e "${GREEN}✓ Context injection hook installed${NC}"

#===============================================================================
# HOOK: STOP (Update CLAUDE.md with learnings)
#===============================================================================
echo -e "${YELLOW}Installing stop hook...${NC}"

cat > "$HOOKS_DIR/stop-update.sh" << 'STOP_HOOK'
#!/bin/bash
# Stop hook - exports learnings to project CLAUDE.md

MEMORY_SCRIPT="$HOME/.claude/scripts/memory-db.py"
INPUT=$(cat)

# Check stop_hook_active to prevent loops
STOP_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)
if [[ "$STOP_ACTIVE" == "true" ]]; then
    exit 0
fi

CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
if [[ -z "$CWD" ]]; then
    CWD=$(pwd)
fi

export CLAUDE_CWD="$CWD"
PROJECT_CLAUDE="$CWD/CLAUDE.md"

# Export learnings if database exists
if [[ -f "$CWD/.claude/hivemind.db" ]]; then
    LEARNINGS=$(python3 "$MEMORY_SCRIPT" learnings-export 2>/dev/null)
    COUNT=$(echo "$LEARNINGS" | jq '.learnings | length' 2>/dev/null || echo "0")
    
    if [[ "$COUNT" -gt 0 ]]; then
        TIMESTAMP=$(date +%Y-%m-%d\ %H:%M)
        
        # Append to CLAUDE.md
        echo "" >> "$PROJECT_CLAUDE"
        echo "## Session Learnings ($TIMESTAMP)" >> "$PROJECT_CLAUDE"
        echo "$LEARNINGS" | jq -r '.learnings[] | "- [\(.type)] \(.content)"' >> "$PROJECT_CLAUDE" 2>/dev/null
    fi
fi

exit 0
STOP_HOOK

chmod +x "$HOOKS_DIR/stop-update.sh"
echo -e "${GREEN}✓ Stop hook installed${NC}"

#===============================================================================
# HOOK: SUBAGENT TRACKING (PreToolUse for Task)
# Workaround for Issue #7881
#===============================================================================
echo -e "${YELLOW}Installing subagent tracking hooks...${NC}"

cat > "$HOOKS_DIR/track-task-start.sh" << 'TASK_START_HOOK'
#!/bin/bash
# PreToolUse hook for Task tool - tracks subagent spawns (Issue #7881 workaround)

MEMORY_SCRIPT="$HOME/.claude/scripts/memory-db.py"
INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
if [[ "$TOOL_NAME" != "Task" ]]; then
    exit 0
fi

CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
export CLAUDE_CWD="${CWD:-$(pwd)}"

TOOL_USE_ID=$(echo "$INPUT" | jq -r '.tool_use_id // empty' 2>/dev/null)
DESCRIPTION=$(echo "$INPUT" | jq -r '.tool_input.description // .tool_input.prompt // "Unknown task"' 2>/dev/null)

# Generate unique task ID
TASK_ID="task-$(date +%s)-$$"

if [[ -n "$TOOL_USE_ID" ]]; then
    python3 "$MEMORY_SCRIPT" task-start "$TASK_ID" "$DESCRIPTION" "$TOOL_USE_ID" 2>/dev/null
fi

exit 0
TASK_START_HOOK

cat > "$HOOKS_DIR/track-task-complete.sh" << 'TASK_COMPLETE_HOOK'
#!/bin/bash
# SubagentStop hook - marks tasks as completed

MEMORY_SCRIPT="$HOME/.claude/scripts/memory-db.py"
INPUT=$(cat)

# Check stop_hook_active to prevent loops
STOP_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)
if [[ "$STOP_ACTIVE" == "true" ]]; then
    exit 0
fi

CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
export CLAUDE_CWD="${CWD:-$(pwd)}"

# Mark most recent running task as completed
# (Limitation: can't identify specific subagent per Issue #7881)
if [[ -f "$CLAUDE_CWD/.claude/hivemind.db" ]]; then
    sqlite3 "$CLAUDE_CWD/.claude/hivemind.db" \
        "UPDATE agent_tasks SET status='completed', completed_at=datetime('now') WHERE status='running' ORDER BY started_at DESC LIMIT 1" 2>/dev/null
fi

exit 0
TASK_COMPLETE_HOOK

chmod +x "$HOOKS_DIR/track-task-start.sh"
chmod +x "$HOOKS_DIR/track-task-complete.sh"
echo -e "${GREEN}✓ Subagent tracking hooks installed${NC}"

#===============================================================================
# CONTEXT WATCHER SCRIPT (Replaces broken PreCompact)
#===============================================================================
echo -e "${YELLOW}Installing context watcher...${NC}"

cat > "$SCRIPTS_DIR/context-watcher.sh" << 'WATCHER_SCRIPT'
#!/bin/bash
# Context watcher - monitors transcript growth
# Replaces broken PreCompact hook (Issue #13572)
#
# Usage: nohup ~/.claude/scripts/context-watcher.sh &
# Or: systemctl --user start hivemind-watcher

TRANSCRIPT_DIR="$HOME/.claude/projects"
MAX_CONTEXT=200000
WARN_THRESHOLD=75
CRITICAL_THRESHOLD=90
CHECK_INTERVAL=30
MEMORY_SCRIPT="$HOME/.claude/scripts/memory-db.py"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

calculate_usage() {
    local jsonl_file="$1"
    # Get last entry with usage data
    local usage=$(tail -100 "$jsonl_file" 2>/dev/null | \
                  grep '"usage"' | tail -1 | \
                  jq -r '.message.usage // empty' 2>/dev/null)
    
    if [[ -n "$usage" ]]; then
        local input=$(echo "$usage" | jq '(.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)' 2>/dev/null)
        if [[ -n "$input" ]] && [[ "$input" =~ ^[0-9]+$ ]]; then
            echo $((input * 100 / MAX_CONTEXT))
            return
        fi
    fi
    echo 0
}

preserve_context() {
    local jsonl_file="$1"
    local session_id=$(basename "$jsonl_file" .jsonl)
    
    # Extract project path from transcript location
    local project_encoded=$(basename "$(dirname "$jsonl_file")")
    local project_path=$(echo "$project_encoded" | sed 's/-/\//g')
    
    log "Preserving context for session $session_id"
    
    # Extract last few assistant messages for summary
    local summary=$(tail -50 "$jsonl_file" | \
                   jq -r 'select(.type=="assistant") | .message.content[0].text // empty' 2>/dev/null | \
                   tail -c 5000)
    
    # Store snapshot
    if [[ -d "$project_path/.claude" ]]; then
        export CLAUDE_CWD="$project_path"
        python3 "$MEMORY_SCRIPT" snapshot-save "$session_id" "$summary" "auto-watcher" 2>/dev/null
    fi
    
    # Desktop notification if available
    if command -v notify-send &> /dev/null; then
        notify-send "Claude Context Warning" "Session at high context usage - snapshot saved"
    fi
}

log "Context watcher started"
log "Watching: $TRANSCRIPT_DIR"
log "Thresholds: warn=${WARN_THRESHOLD}%, critical=${CRITICAL_THRESHOLD}%"

while true; do
    # Find active transcripts (modified in last 5 minutes)
    while IFS= read -r -d '' jsonl; do
        usage=$(calculate_usage "$jsonl")
        
        if [[ "$usage" -gt 0 ]]; then
            if [[ "$usage" -gt "$CRITICAL_THRESHOLD" ]]; then
                log "CRITICAL: $jsonl at ${usage}%"
                preserve_context "$jsonl"
            elif [[ "$usage" -gt "$WARN_THRESHOLD" ]]; then
                log "WARNING: $jsonl at ${usage}%"
            fi
        fi
    done < <(find "$TRANSCRIPT_DIR" -name "*.jsonl" -mmin -5 -print0 2>/dev/null)
    
    sleep $CHECK_INTERVAL
done
WATCHER_SCRIPT

chmod +x "$SCRIPTS_DIR/context-watcher.sh"
echo -e "${GREEN}✓ Context watcher installed${NC}"

#===============================================================================
# SETTINGS.JSON - V3 (Verified hook structure)
#===============================================================================
echo -e "${YELLOW}Creating settings.json...${NC}"

# Backup existing settings
if [[ -f "$CLAUDE_DIR/settings.json" ]]; then
    cp "$CLAUDE_DIR/settings.json" "$CLAUDE_DIR/settings.json.backup.$(date +%Y%m%d-%H%M%S)"
    echo -e "${YELLOW}  Backed up existing settings.json${NC}"
fi

cat > "$CLAUDE_DIR/settings.json" << 'SETTINGS_JSON'
{
  "permissions": {
    "allow": [
      "Read(*)",
      "Grep(*)",
      "Glob(*)",
      "Bash(python3 ~/.claude/scripts/*)",
      "Bash(sqlite3 *)",
      "Bash(jq *)",
      "Bash(git status)",
      "Bash(git diff*)",
      "Bash(git log*)"
    ],
    "deny": [
      "Bash(rm -rf /)",
      "Bash(rm -rf ~)",
      "Bash(sudo rm -rf *)"
    ]
  },
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/hivemind/crlf-fix.sh",
            "timeout": 5
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/hivemind/inject-context.sh",
            "timeout": 10
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/hivemind/stop-update.sh",
            "timeout": 15
          }
        ]
      }
    ],
    "SubagentStop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/hivemind/track-task-complete.sh",
            "timeout": 10
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Task",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/hivemind/track-task-start.sh",
            "timeout": 5
          }
        ]
      }
    ]
  },
  "env": {
    "PYTHONUNBUFFERED": "1",
    "HIVEMIND_ENABLED": "1"
  }
}
SETTINGS_JSON

echo -e "${GREEN}✓ settings.json created${NC}"

#===============================================================================
# ISOLATED SETTINGS FOR SUBAGENTS (No hooks)
#===============================================================================
echo -e "${YELLOW}Creating isolated subagent settings...${NC}"

cat > "$CLAUDE_DIR/no-hooks-settings.json" << 'NO_HOOKS'
{
  "permissions": {
    "allow": ["Read(*)", "Grep(*)", "Glob(*)"]
  },
  "hooks": {}
}
NO_HOOKS

echo -e "${GREEN}✓ Isolated settings created${NC}"

#===============================================================================
# GLOBAL CLAUDE.MD (Minimal - no @ imports due to Issue #1041)
#===============================================================================
echo -e "${YELLOW}Creating global CLAUDE.md...${NC}"

cat > "$CLAUDE_DIR/CLAUDE.md" << 'GLOBAL_MD'
# Claude Code Hivemind V3

## Automatic Features

- **Context Injection**: Memory statute injected via UserPromptSubmit hook
- **CRLF Fix**: PostToolUse hook fixes Windows line endings automatically
- **Learning Export**: Stop hook exports learnings to project CLAUDE.md
- **Subagent Tracking**: PreToolUse/SubagentStop hooks track Task invocations

## Record Learnings

Save important discoveries to the database:

```bash
python3 ~/.claude/scripts/memory-db.py learning-add decision "Chose X because Y"
python3 ~/.claude/scripts/memory-db.py learning-add pattern "Always check for..."
python3 ~/.claude/scripts/memory-db.py learning-add bug "Issue when X happens"
```

## Memory Commands

```bash
# Store values
python3 ~/.claude/scripts/memory-db.py set key "value" category

# Retrieve
python3 ~/.claude/scripts/memory-db.py get key
python3 ~/.claude/scripts/memory-db.py list [category]

# View all state
python3 ~/.claude/scripts/memory-db.py dump
```

## Context Watcher

Start the background context monitor (replaces broken PreCompact):

```bash
nohup ~/.claude/scripts/context-watcher.sh > /tmp/hivemind-watcher.log 2>&1 &
```

## Spawn Isolated Subagent

To spawn a subagent without triggering parent hooks:

```bash
claude --settings ~/.claude/no-hooks-settings.json -p "task" --max-turns 5
```
GLOBAL_MD

echo -e "${GREEN}✓ Global CLAUDE.md created${NC}"

#===============================================================================
# SLASH COMMANDS
#===============================================================================
echo -e "${YELLOW}Creating slash commands...${NC}"

cat > "$COMMANDS_DIR/memory.md" << 'MEMORY_CMD'
---
description: Access Hivemind memory database
argument-hint: [dump|set|get|list|statute]
---
Run the memory database command:
```bash
python3 ~/.claude/scripts/memory-db.py $ARGUMENTS
```
MEMORY_CMD

cat > "$COMMANDS_DIR/learn.md" << 'LEARN_CMD'
---
description: Record a learning to the database
argument-hint: <type> <content>
---
Record a learning (types: decision, pattern, bug, convention):
```bash
python3 ~/.claude/scripts/memory-db.py learning-add $ARGUMENTS
```
LEARN_CMD

cat > "$COMMANDS_DIR/watcher.md" << 'WATCHER_CMD'
---
description: Manage context watcher
argument-hint: [start|stop|status]
---
Context watcher commands:
- start: `nohup ~/.claude/scripts/context-watcher.sh > /tmp/hivemind-watcher.log 2>&1 &`
- stop: `pkill -f context-watcher.sh`
- status: `pgrep -f context-watcher.sh && tail -20 /tmp/hivemind-watcher.log`
WATCHER_CMD

echo -e "${GREEN}✓ Slash commands created${NC}"

#===============================================================================
# SYSTEMD USER SERVICE (Optional)
#===============================================================================
echo -e "${YELLOW}Creating systemd service (optional)...${NC}"

mkdir -p "$HOME/.config/systemd/user"

cat > "$HOME/.config/systemd/user/hivemind-watcher.service" << 'SYSTEMD_SERVICE'
[Unit]
Description=Claude Code Hivemind Context Watcher
After=default.target

[Service]
Type=simple
ExecStart=%h/.claude/scripts/context-watcher.sh
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
SYSTEMD_SERVICE

echo -e "${GREEN}✓ Systemd service created${NC}"
echo -e "${YELLOW}  Enable with: systemctl --user enable --now hivemind-watcher${NC}"

#===============================================================================
# INITIALIZATION
#===============================================================================
echo ""
echo -e "${YELLOW}Initializing...${NC}"

# Test memory script
if python3 "$SCRIPTS_DIR/memory-db.py" init > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Memory database working${NC}"
else
    echo -e "${RED}✗ Memory database test failed${NC}"
fi

#===============================================================================
# SUMMARY
#===============================================================================
echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Claude Code Hivemind V3 Installation Complete!${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}V3 Features:${NC}"
echo "  ✓ PostToolUse CRLF fix (Issue #2805 workaround)"
echo "  ✓ UserPromptSubmit context injection (Issue #10373 workaround)"
echo "  ✓ Stop hook for learning export"
echo "  ✓ Subagent tracking via PreToolUse/SubagentStop (Issue #7881 workaround)"
echo "  ✓ Context watcher replaces broken PreCompact (Issue #13572)"
echo ""
echo -e "${YELLOW}Known Limitations:${NC}"
echo "  - PreCompact hooks don't work (Issue #13572)"
echo "  - @ imports fail in global CLAUDE.md (Issue #1041)"
echo "  - SubagentStop can't identify specific subagent (Issue #7881)"
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo "  1. Run 'claude' and use /hooks to approve hooks"
echo "  2. Start context watcher:"
echo "     nohup ~/.claude/scripts/context-watcher.sh > /tmp/hivemind-watcher.log 2>&1 &"
echo "  3. Or enable systemd service:"
echo "     systemctl --user enable --now hivemind-watcher"
echo ""
echo -e "${YELLOW}Test Commands:${NC}"
echo "  python3 ~/.claude/scripts/memory-db.py set test 'hello world' testing"
echo "  python3 ~/.claude/scripts/memory-db.py learning-add decision 'V3 installed'"
echo "  python3 ~/.claude/scripts/memory-db.py dump"
echo ""
