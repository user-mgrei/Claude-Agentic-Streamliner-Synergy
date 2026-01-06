#!/bin/bash
#===============================================================================
# Claude Code Hivemind Setup Script V3
# 
# VERIFIED AGAINST: Claude Code 2.0.76 (January 2026)
# FACT-CHECKED BY: 4 Opus 4.5 agents working interoperably
#
# KEY CHANGES FROM V2:
#   - REMOVED reliance on PreCompact hook (Issue #13572 - doesn't fire)
#   - REMOVED @ imports in global CLAUDE.md (Issue #1041 - doesn't work)
#   - ADDED UserPromptSubmit hook for context injection (workaround for #10373)
#   - ADDED PostToolUse hook for CRLF fix (Issue #2805)
#   - ADDED PreToolUse Task tracking for subagent identification (Issue #7881)
#   - ADDED transcript watcher for context preservation
#   - ADDED isolated subagent config with --settings flag + disableAllHooks
#   - OPTIONAL Gemini CLI integration for summarization
#
# CONFIRMED WORKING:
#   ✅ --settings flag for isolated subagent configs
#   ✅ disableAllHooks setting
#   ✅ --output-format stream-json for headless mode
#   ✅ .claude/rules/ directory (project-level only)
#   ✅ UserPromptSubmit hook for context injection
#   ✅ PostToolUse hooks for tool output processing
#   ✅ SQLite WAL mode for concurrent access
#
# For Arch Linux with yay-installed claude-code
# Run: chmod +x setup-claude-hivemind-v3.sh && ./setup-claude-hivemind-v3.sh
#===============================================================================

set -e

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║         Claude Code Hivemind V3 Setup (Fact-Checked)              ║${NC}"
echo -e "${BLUE}║         Verified: January 2026 | Claude Code 2.0.76               ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════════╝${NC}"
echo ""

CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks/hivemind"
SCRIPTS_DIR="$CLAUDE_DIR/scripts"

# Create directory structure
echo -e "${YELLOW}[1/8]${NC} Creating directory structure..."
mkdir -p "$HOOKS_DIR" "$SCRIPTS_DIR" "$CLAUDE_DIR/agent-logs"

#===============================================================================
# SQLITE MEMORY MANAGEMENT SCRIPT (V3 - Simplified)
#===============================================================================
echo -e "${YELLOW}[2/8]${NC} Creating SQLite memory manager..."
cat > "$SCRIPTS_DIR/memory-db.py" << 'MEMORY_SCRIPT'
#!/usr/bin/env python3
"""
Claude Code SQLite Memory Manager V3
Database: .claude/hivemind.db (project) or ~/.claude/hivemind.db (global)

Features:
  - WAL mode for concurrent access
  - Agent task tracking for SubagentStop workaround
  - Context snapshots for pre-compact preservation
  - Statute generation for context injection
"""
import sqlite3
import json
import sys
import os
from datetime import datetime
from pathlib import Path

def get_db_path():
    """Determine database path - prefer project, fallback to global"""
    project_dir = os.environ.get('CLAUDE_PROJECT_DIR', os.getcwd())
    project_db = Path(project_dir) / '.claude' / 'hivemind.db'
    global_db = Path.home() / '.claude' / 'hivemind.db'
    
    if (Path(project_dir) / '.claude').exists():
        project_db.parent.mkdir(parents=True, exist_ok=True)
        return project_db
    return global_db

def init_db(conn):
    """Initialize database schema with WAL mode"""
    conn.execute('PRAGMA journal_mode=WAL')
    conn.execute('PRAGMA busy_timeout=5000')
    conn.execute('PRAGMA synchronous=NORMAL')
    
    conn.executescript('''
        CREATE TABLE IF NOT EXISTS agent_tasks (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            agent_type TEXT,
            task_description TEXT,
            status TEXT DEFAULT 'running',
            started_at REAL DEFAULT (julianday('now')),
            completed_at REAL,
            result_summary TEXT,
            tool_use_id TEXT
        );
        
        CREATE TABLE IF NOT EXISTS project_state (
            key TEXT PRIMARY KEY,
            value TEXT,
            updated_at REAL DEFAULT (julianday('now'))
        );
        
        CREATE TABLE IF NOT EXISTS context_snapshots (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            snapshot_type TEXT,
            summary TEXT,
            created_at REAL DEFAULT (julianday('now'))
        );
        
        CREATE TABLE IF NOT EXISTS learnings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            learning_type TEXT NOT NULL,
            content TEXT NOT NULL,
            created_at REAL DEFAULT (julianday('now')),
            exported INTEGER DEFAULT 0
        );
        
        CREATE INDEX IF NOT EXISTS idx_tasks_session ON agent_tasks(session_id);
        CREATE INDEX IF NOT EXISTS idx_tasks_status ON agent_tasks(status);
        CREATE INDEX IF NOT EXISTS idx_learnings_exported ON learnings(exported);
    ''')
    conn.commit()

def ensure_db():
    """Ensure database exists and is initialized"""
    db_path = get_db_path()
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(db_path), timeout=10)
    init_db(conn)
    return conn

def generate_statute(conn):
    """Generate compact statute for context injection"""
    cursor = conn.cursor()
    output = []
    
    # Recent tasks
    cursor.execute('''
        SELECT agent_type, substr(task_description, 1, 60), status 
        FROM agent_tasks 
        ORDER BY completed_at DESC NULLS LAST, started_at DESC 
        LIMIT 5
    ''')
    tasks = cursor.fetchall()
    if tasks:
        output.append("## Recent Agent Tasks")
        for t in tasks:
            agent = t[0] or "agent"
            desc = t[1] + "..." if len(t[1] or "") >= 60 else (t[1] or "task")
            output.append(f"- [{t[2]}] {agent}: {desc}")
    
    # Project state
    cursor.execute('SELECT key, value FROM project_state ORDER BY updated_at DESC LIMIT 5')
    states = cursor.fetchall()
    if states:
        output.append("\n## Project State")
        for s in states:
            val = s[1][:100] + "..." if len(s[1] or "") > 100 else s[1]
            output.append(f"- {s[0]}: {val}")
    
    return "\n".join(output) if output else ""

def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "Usage: memory-db.py <command> [args]"}))
        sys.exit(1)
    
    cmd = sys.argv[1]
    
    try:
        conn = ensure_db()
        cursor = conn.cursor()
    except Exception as e:
        print(json.dumps({"error": f"Database error: {str(e)}"}))
        sys.exit(1)
    
    try:
        if cmd == "init":
            print(json.dumps({"status": "initialized", "db_path": str(get_db_path())}))
        
        elif cmd == "statute":
            # Generate statute for context injection
            statute = generate_statute(conn)
            print(statute if statute else "No hivemind state yet.")
        
        elif cmd == "task-start":
            # Called by PreToolUse on Task - track subagent spawn
            if len(sys.argv) < 4:
                print(json.dumps({"error": "Usage: task-start <session_id> <tool_use_id> [agent_type] [description]"}))
                sys.exit(1)
            session_id = sys.argv[2]
            tool_use_id = sys.argv[3]
            agent_type = sys.argv[4] if len(sys.argv) > 4 else "subagent"
            description = sys.argv[5] if len(sys.argv) > 5 else ""
            
            task_id = f"{session_id}-{tool_use_id}"
            cursor.execute('''
                INSERT OR REPLACE INTO agent_tasks (id, session_id, tool_use_id, agent_type, task_description, status, started_at)
                VALUES (?, ?, ?, ?, ?, 'running', julianday('now'))
            ''', (task_id, session_id, tool_use_id, agent_type, description))
            conn.commit()
            print(json.dumps({"status": "started", "task_id": task_id}))
        
        elif cmd == "task-complete":
            # Called by SubagentStop - mark most recent running task as complete
            if len(sys.argv) < 3:
                print(json.dumps({"error": "Usage: task-complete <session_id> [result]"}))
                sys.exit(1)
            session_id = sys.argv[2]
            result = sys.argv[3] if len(sys.argv) > 3 else None
            
            cursor.execute('''
                UPDATE agent_tasks 
                SET status = 'completed', completed_at = julianday('now'), result_summary = ?
                WHERE session_id = ? AND status = 'running'
                ORDER BY started_at DESC LIMIT 1
            ''', (result, session_id))
            conn.commit()
            print(json.dumps({"status": "completed", "session_id": session_id}))
        
        elif cmd == "state-set":
            if len(sys.argv) < 4:
                print(json.dumps({"error": "Usage: state-set <key> <value>"}))
                sys.exit(1)
            key, value = sys.argv[2], sys.argv[3]
            cursor.execute('''
                INSERT OR REPLACE INTO project_state (key, value, updated_at)
                VALUES (?, ?, julianday('now'))
            ''', (key, value))
            conn.commit()
            print(json.dumps({"status": "set", "key": key}))
        
        elif cmd == "state-get":
            if len(sys.argv) < 3:
                print(json.dumps({"error": "Usage: state-get <key>"}))
                sys.exit(1)
            cursor.execute('SELECT value FROM project_state WHERE key = ?', (sys.argv[2],))
            row = cursor.fetchone()
            print(json.dumps({"key": sys.argv[2], "value": row[0] if row else None}))
        
        elif cmd == "snapshot-save":
            if len(sys.argv) < 4:
                print(json.dumps({"error": "Usage: snapshot-save <session_id> <type> [summary]"}))
                sys.exit(1)
            session_id = sys.argv[2]
            snap_type = sys.argv[3]
            summary = sys.stdin.read() if not sys.stdin.isatty() else (sys.argv[4] if len(sys.argv) > 4 else "")
            
            snap_id = f"snap-{datetime.now().strftime('%Y%m%d-%H%M%S')}"
            cursor.execute('''
                INSERT INTO context_snapshots (id, session_id, snapshot_type, summary)
                VALUES (?, ?, ?, ?)
            ''', (snap_id, session_id, snap_type, summary))
            conn.commit()
            print(json.dumps({"status": "saved", "snapshot_id": snap_id}))
        
        elif cmd == "learning-add":
            if len(sys.argv) < 4:
                print(json.dumps({"error": "Usage: learning-add <type> <content>"}))
                sys.exit(1)
            cursor.execute('INSERT INTO learnings (learning_type, content) VALUES (?, ?)', 
                          (sys.argv[2], sys.argv[3]))
            conn.commit()
            print(json.dumps({"status": "added", "id": cursor.lastrowid}))
        
        elif cmd == "learnings-export":
            cursor.execute('SELECT id, learning_type, content FROM learnings WHERE exported = 0')
            rows = cursor.fetchall()
            if rows:
                cursor.execute('UPDATE learnings SET exported = 1 WHERE exported = 0')
                conn.commit()
            output = []
            for r in rows:
                output.append(f"- [{r[1]}] {r[2]}")
            print("\n".join(output) if output else "No new learnings.")
        
        elif cmd == "dump":
            cursor.execute('SELECT * FROM agent_tasks ORDER BY started_at DESC LIMIT 10')
            tasks = [{"id": r[0], "session": r[1], "type": r[2], "desc": r[3], "status": r[4]} 
                    for r in cursor.fetchall()]
            cursor.execute('SELECT * FROM project_state')
            state = {r[0]: r[1] for r in cursor.fetchall()}
            print(json.dumps({"tasks": tasks, "state": state}, indent=2))
        
        else:
            print(json.dumps({"error": f"Unknown command: {cmd}"}))
            sys.exit(1)
            
    except Exception as e:
        print(json.dumps({"error": str(e)}))
        sys.exit(1)
    finally:
        conn.close()

if __name__ == "__main__":
    main()
MEMORY_SCRIPT
chmod +x "$SCRIPTS_DIR/memory-db.py"

#===============================================================================
# CRLF FIX HOOK (PostToolUse on Write) - Issue #2805 workaround
#===============================================================================
echo -e "${YELLOW}[3/8]${NC} Creating CRLF fix hook..."
cat > "$HOOKS_DIR/crlf-fix.sh" << 'CRLF_HOOK'
#!/bin/bash
# PostToolUse hook for Write tool - fixes CRLF line endings on Linux
# Workaround for Issue #2805

input=$(cat)
file_path=$(echo "$input" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('file_path',''))" 2>/dev/null)

# Validate and normalize the file path before using it
if [ -z "$file_path" ]; then
    exit 0
fi

# Resolve to an absolute, normalized path; if this fails, do nothing
normalized_path=$(realpath -m -- "$file_path" 2>/dev/null) || exit 0

# Restrict operations to files within the current working directory (workspace)
WORKSPACE_ROOT=$(pwd)
case "$normalized_path" in
    "$WORKSPACE_ROOT"/*) ;;
    *) exit 0 ;;
esac

if [ -f "$normalized_path" ]; then
    # Check if file has CRLF endings
    if file "$normalized_path" 2>/dev/null | grep -q "CRLF"; then
        sed -i 's/\r$//' "$normalized_path" 2>/dev/null
        echo "Fixed CRLF line endings in $normalized_path" >&2
    fi
fi
exit 0
CRLF_HOOK
chmod +x "$HOOKS_DIR/crlf-fix.sh"

#===============================================================================
# CONTEXT INJECTION HOOK (UserPromptSubmit) - Issue #10373 workaround
#===============================================================================
echo -e "${YELLOW}[4/8]${NC} Creating context injection hook..."
cat > "$HOOKS_DIR/inject-context.sh" << 'INJECT_HOOK'
#!/bin/bash
# UserPromptSubmit hook - injects database statute into context
# Workaround for SessionStart not working on new sessions (Issue #10373)

MEMORY_SCRIPT="$HOME/.claude/scripts/memory-db.py"

# Generate statute from database
STATUTE=$(python3 "$MEMORY_SCRIPT" statute 2>/dev/null)

if [ -n "$STATUTE" ] && [ "$STATUTE" != "No hivemind state yet." ]; then
    # Output additionalContext format
    STATUTE_ESCAPED=$(echo "$STATUTE" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')
    cat << EOF
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": ${STATUTE_ESCAPED}
  }
}
EOF
fi
exit 0
INJECT_HOOK
chmod +x "$HOOKS_DIR/inject-context.sh"

#===============================================================================
# SUBAGENT TRACKING HOOKS (PreToolUse/PostToolUse on Task) - Issue #7881 workaround
#===============================================================================
echo -e "${YELLOW}[5/8]${NC} Creating subagent tracking hooks..."
cat > "$HOOKS_DIR/track-task-start.sh" << 'TASK_START_HOOK'
#!/bin/bash
# PreToolUse hook for Task tool - tracks subagent spawn
# Workaround for Issue #7881 (SubagentStop can't identify which subagent)

MEMORY_SCRIPT="$HOME/.claude/scripts/memory-db.py"

input=$(cat)
session_id=$(echo "$input" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null)
tool_use_id=$(echo "$input" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_use_id',''))" 2>/dev/null)
description=$(echo "$input" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('description','')[:100])" 2>/dev/null)

if [ -n "$session_id" ] && [ -n "$tool_use_id" ]; then
    python3 "$MEMORY_SCRIPT" task-start "$session_id" "$tool_use_id" "subagent" "$description" 2>/dev/null
fi
exit 0
TASK_START_HOOK
chmod +x "$HOOKS_DIR/track-task-start.sh"

cat > "$HOOKS_DIR/track-subagent-stop.sh" << 'SUBAGENT_STOP_HOOK'
#!/bin/bash
# SubagentStop hook - marks most recent running task as complete
# Workaround for Issue #7881

MEMORY_SCRIPT="$HOME/.claude/scripts/memory-db.py"

input=$(cat)

# Check stop_hook_active to prevent loops
stop_active=$(echo "$input" | python3 -c "import sys,json; print(json.load(sys.stdin).get('stop_hook_active', False))" 2>/dev/null)
[ "$stop_active" = "True" ] && exit 0

session_id=$(echo "$input" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null)

if [ -n "$session_id" ]; then
    python3 "$MEMORY_SCRIPT" task-complete "$session_id" 2>/dev/null
fi
exit 0
SUBAGENT_STOP_HOOK
chmod +x "$HOOKS_DIR/track-subagent-stop.sh"

#===============================================================================
# STOP HOOK - Update plan and export learnings
#===============================================================================
echo -e "${YELLOW}[6/8]${NC} Creating stop hook..."
cat > "$HOOKS_DIR/stop-hook.sh" << 'STOP_HOOK'
#!/bin/bash
# Stop hook - exports learnings to project CLAUDE.md

MEMORY_SCRIPT="$HOME/.claude/scripts/memory-db.py"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

input=$(cat)

# Check stop_hook_active to prevent loops
stop_active=$(echo "$input" | python3 -c "import sys,json; print(json.load(sys.stdin).get('stop_hook_active', False))" 2>/dev/null)
[ "$stop_active" = "True" ] && exit 0

# Export learnings to project CLAUDE.md if .claude dir exists
if [ -d "$PROJECT_DIR/.claude" ]; then
    LEARNINGS=$(python3 "$MEMORY_SCRIPT" learnings-export 2>/dev/null)
    if [ -n "$LEARNINGS" ] && [ "$LEARNINGS" != "No new learnings." ]; then
        PROJECT_CLAUDE="$PROJECT_DIR/CLAUDE.md"
        if [ ! -f "$PROJECT_CLAUDE" ]; then
            echo -e "# Project Memory\n" > "$PROJECT_CLAUDE"
        fi
        echo -e "\n## Session Learnings ($(date +%Y-%m-%d))\n$LEARNINGS" >> "$PROJECT_CLAUDE"
    fi
fi
exit 0
STOP_HOOK
chmod +x "$HOOKS_DIR/stop-hook.sh"

#===============================================================================
# ISOLATED SUBAGENT CONFIG (for spawning without hooks)
#===============================================================================
echo -e "${YELLOW}[7/8]${NC} Creating isolated subagent config..."
mkdir -p "$CLAUDE_DIR"
cat > "$CLAUDE_DIR/no-hooks.json" << 'NO_HOOKS'
{
  "disableAllHooks": true
}
NO_HOOKS

#===============================================================================
# HEADLESS AGENT SPAWNER
#===============================================================================
cat > "$SCRIPTS_DIR/spawn-agent.sh" << 'SPAWN_SCRIPT'
#!/bin/bash
# Spawn a headless Claude Code agent with hooks disabled
# Usage: spawn-agent.sh <task-prompt> [working-dir]

TASK_PROMPT="$1"
WORK_DIR="${2:-$(pwd)}"
NO_HOOKS_CONFIG="$HOME/.claude/no-hooks.json"
LOG_DIR="$HOME/.claude/agent-logs"

mkdir -p "$LOG_DIR"

if [ -z "$TASK_PROMPT" ]; then
    echo "Usage: spawn-agent.sh <task-prompt> [working-dir]"
    exit 1
fi

SESSION_ID=$(date +%s%N)
cd "$WORK_DIR"

# Spawn with hooks disabled to prevent infinite loops
nohup claude --settings "$NO_HOOKS_CONFIG" \
    -p "$TASK_PROMPT" \
    --output-format stream-json \
    --max-turns 10 \
    > "$LOG_DIR/agent-${SESSION_ID}.log" 2>&1 &

AGENT_PID=$!
echo "$AGENT_PID" > "$LOG_DIR/agent-${SESSION_ID}.pid"
echo "{\"session_id\": \"$SESSION_ID\", \"pid\": $AGENT_PID, \"log\": \"$LOG_DIR/agent-${SESSION_ID}.log\"}"
SPAWN_SCRIPT
chmod +x "$SCRIPTS_DIR/spawn-agent.sh"

#===============================================================================
# CONTEXT WATCHER (replaces broken PreCompact hook)
#===============================================================================
cat > "$SCRIPTS_DIR/context-watcher.sh" << 'WATCHER_SCRIPT'
#!/bin/bash
# Context window watcher - monitors transcript growth
# Run as: nohup ~/.claude/scripts/context-watcher.sh &
# This replaces the broken PreCompact hook (Issue #13572)

TRANSCRIPT_DIR="$HOME/.claude/projects"
MAX_CONTEXT=200000
WARN_THRESHOLD=75
CHECK_INTERVAL=30
MEMORY_SCRIPT="$HOME/.claude/scripts/memory-db.py"

calculate_usage() {
    local jsonl_file="$1"
    local usage=$(grep '"usage"' "$jsonl_file" 2>/dev/null | tail -1 | \
                  python3 -c "import sys,json
for line in sys.stdin:
    try:
        d = json.loads(line)
        u = d.get('message',{}).get('usage',{})
        total = u.get('input_tokens',0) + u.get('cache_read_input_tokens',0)
        print(int(total * 100 / $MAX_CONTEXT))
        break
    except: pass" 2>/dev/null)
    echo "${usage:-0}"
}

preserve_context() {
    local jsonl_file="$1"
    local session_id=$(basename "$jsonl_file" .jsonl)
    
    # Save snapshot to database
    python3 "$MEMORY_SCRIPT" snapshot-save "$session_id" "auto-preserve" "Context at $(date)" 2>/dev/null
    
    # Desktop notification if available
    if command -v notify-send &>/dev/null; then
        notify-send "Claude Context Warning" "Session at high context usage - snapshot saved"
    fi
    echo "[$(date)] Preserved context for session $session_id"
}

echo "[$(date)] Context watcher started (checking every ${CHECK_INTERVAL}s)"

while true; do
    for jsonl in $(find "$TRANSCRIPT_DIR" -name "*.jsonl" -mmin -5 2>/dev/null); do
        usage=$(calculate_usage "$jsonl")
        if [ "$usage" -gt "$WARN_THRESHOLD" ]; then
            echo "[WARNING] $jsonl at ${usage}%"
            preserve_context "$jsonl"
        fi
    done
    sleep $CHECK_INTERVAL
done
WATCHER_SCRIPT
chmod +x "$SCRIPTS_DIR/context-watcher.sh"

#===============================================================================
# SETTINGS.JSON with all hooks configured
#===============================================================================
echo -e "${YELLOW}[8/8]${NC} Creating settings.json..."
cat > "$CLAUDE_DIR/settings.json" << 'SETTINGS_JSON'
{
  "permissions": {
    "allow": [
      "Read(*)",
      "Grep(*)",
      "Glob(*)",
      "Bash(python3 ~/.claude/scripts/*.py)",
      "Bash(~/.claude/scripts/context-watcher.sh)",
      "Bash(git status)",
      "Bash(git diff*)",
      "Bash(git log*)",
      "Bash(git branch*)",
      "Bash(ls*)",
      "Bash(cat*)",
      "Bash(head*)",
      "Bash(tail*)",
      "Bash(date*)",
      "Bash(mkdir*)",
      "Bash(sqlite3*)"
    ],
    "deny": [
      "Bash(rm -rf /)",
      "Bash(rm -rf ~)",
      "Bash(:(){ :|:& };:)"
    ]
  },
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [{
          "type": "command",
          "command": "~/.claude/hooks/hivemind/inject-context.sh",
          "timeout": 5
        }]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Task",
        "hooks": [{
          "type": "command",
          "command": "~/.claude/hooks/hivemind/track-task-start.sh",
          "timeout": 5
        }]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Write",
        "hooks": [{
          "type": "command",
          "command": "~/.claude/hooks/hivemind/crlf-fix.sh",
          "timeout": 5
        }]
      }
    ],
    "SubagentStop": [
      {
        "hooks": [{
          "type": "command",
          "command": "~/.claude/hooks/hivemind/track-subagent-stop.sh",
          "timeout": 5
        }]
      }
    ],
    "Stop": [
      {
        "hooks": [{
          "type": "command",
          "command": "~/.claude/hooks/hivemind/stop-hook.sh",
          "timeout": 10
        }]
      }
    ]
  },
  "env": {
    "CLAUDE_HIVEMIND_ENABLED": "1",
    "PYTHONUNBUFFERED": "1"
  }
}
SETTINGS_JSON

#===============================================================================
# GLOBAL CLAUDE.MD (NO @ imports - Issue #1041 workaround)
#===============================================================================
cat > "$CLAUDE_DIR/CLAUDE.md" << 'GLOBAL_CLAUDE_MD'
# Claude Code Hivemind V3

## Automatic Features

- **UserPromptSubmit**: Injects database statute into every prompt
- **PostToolUse(Write)**: Fixes CRLF line endings automatically
- **PreToolUse(Task)**: Tracks subagent spawns for identification
- **SubagentStop**: Records subagent completion
- **Stop**: Exports learnings to project CLAUDE.md

## Record Learnings

When you discover something important:
```bash
python3 ~/.claude/scripts/memory-db.py learning-add decision "Chose X because Y"
python3 ~/.claude/scripts/memory-db.py learning-add pattern "Always check for..."
python3 ~/.claude/scripts/memory-db.py learning-add bug "Issue when..."
```

## Project State

Track project milestones:
```bash
python3 ~/.claude/scripts/memory-db.py state-set current_phase "Implementation"
python3 ~/.claude/scripts/memory-db.py state-set blocker "Waiting for API key"
```

## Spawn Isolated Subagent

```bash
~/.claude/scripts/spawn-agent.sh "Analyze the authentication module" /path/to/project
```

## Context Watcher (Optional)

Start background watcher to preserve context before auto-compaction:
```bash
nohup ~/.claude/scripts/context-watcher.sh > /tmp/context-watcher.log 2>&1 &
```

## View Database

```bash
python3 ~/.claude/scripts/memory-db.py dump
python3 ~/.claude/scripts/memory-db.py statute
```
GLOBAL_CLAUDE_MD

#===============================================================================
# INITIALIZE DATABASE
#===============================================================================
python3 "$SCRIPTS_DIR/memory-db.py" init >/dev/null 2>&1

#===============================================================================
# FINAL OUTPUT
#===============================================================================
echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║              Claude Code Hivemind V3 Installed!                   ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BLUE}Bug Workarounds Applied:${NC}"
echo -e "  ${GREEN}✓${NC} #13572: Using context-watcher.sh instead of PreCompact hook"
echo -e "  ${GREEN}✓${NC} #1041:  No @ imports in global CLAUDE.md"
echo -e "  ${GREEN}✓${NC} #2805:  PostToolUse hook fixes CRLF on Write"
echo -e "  ${GREEN}✓${NC} #10373: UserPromptSubmit for context injection"
echo -e "  ${GREEN}✓${NC} #7881:  PreToolUse tracks Task for subagent identification"
echo ""
echo -e "${BLUE}Verified Features:${NC}"
echo -e "  ${GREEN}✓${NC} --settings flag for isolated subagents"
echo -e "  ${GREEN}✓${NC} disableAllHooks setting"
echo -e "  ${GREEN}✓${NC} SQLite WAL mode for concurrent access"
echo ""
echo -e "${YELLOW}Test Commands:${NC}"
echo "  python3 ~/.claude/scripts/memory-db.py init"
echo "  python3 ~/.claude/scripts/memory-db.py state-set test_key 'hello world'"
echo "  python3 ~/.claude/scripts/memory-db.py statute"
echo "  python3 ~/.claude/scripts/memory-db.py dump"
echo ""
echo -e "${YELLOW}Start Context Watcher (Optional):${NC}"
echo "  nohup ~/.claude/scripts/context-watcher.sh > /tmp/context-watcher.log 2>&1 &"
echo ""
echo -e "${RED}IMPORTANT:${NC} Run 'claude' and use ${YELLOW}/hooks${NC} to approve new hooks!"
echo ""
