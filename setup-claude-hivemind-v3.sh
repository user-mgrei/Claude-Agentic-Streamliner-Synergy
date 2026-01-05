#!/bin/bash
#===============================================================================
# Claude Code Hivemind Setup Script V3 - FACT-CHECKED IMPLEMENTATION
#
# Verified against: Claude Code v2.0.76 (January 2026)
#                   GitHub issues #13572, #1041, #2805, #7881, #10373
#                   Official plugins: hookify, ralph-wiggum, explanatory-output-style
#
# CRITICAL CORRECTIONS FROM V2:
#   - Config directory is now ~/.config/claude/ (not ~/.claude/)
#   - --settings flag DOES NOT EXIST - removed from implementation
#   - disableAllHooks setting DOES NOT EXIST - using environment guards instead
#   - PreCompact hooks are BROKEN (Issue #13572) - using transcript watcher
#   - SessionStart is UNRELIABLE for new sessions - using UserPromptSubmit
#   - Added CRLF fix PostToolUse hook (Issue #2805)
#
# For Arch Linux with yay-installed claude-code
# Run: chmod +x setup-claude-hivemind-v3.sh && ./setup-claude-hivemind-v3.sh
#===============================================================================

set -e

# Detect config directory (changed in recent versions)
if [ -d "$HOME/.config/claude" ]; then
    CLAUDE_DIR="$HOME/.config/claude"
elif [ -d "$HOME/.claude" ]; then
    CLAUDE_DIR="$HOME/.claude"
else
    # Default to new location
    CLAUDE_DIR="$HOME/.config/claude"
fi

echo "==> Claude Code Hivemind V3 Setup"
echo "    Config directory: $CLAUDE_DIR"
echo ""

HOOKS_DIR="$CLAUDE_DIR/hooks/hivemind"
SCRIPTS_DIR="$CLAUDE_DIR/scripts"
AGENTS_DIR="$CLAUDE_DIR/agents"
COMMANDS_DIR="$CLAUDE_DIR/commands"

# Create directory structure
mkdir -p "$HOOKS_DIR" "$SCRIPTS_DIR" "$AGENTS_DIR" "$COMMANDS_DIR"

#===============================================================================
# SQLITE MEMORY MANAGEMENT SCRIPT (V3 - Streamlined)
#===============================================================================
cat > "$SCRIPTS_DIR/hivemind-db.py" << 'MEMORY_SCRIPT'
#!/usr/bin/env python3
"""
Claude Code Hivemind SQLite Database Manager V3
Provides persistent memory storage with WAL mode for concurrent access.
"""
import sqlite3
import json
import sys
import os
from datetime import datetime
from pathlib import Path

def get_db_path():
    """Get database path - project .claude/ or fallback to global"""
    cwd = os.environ.get('CLAUDE_CWD', os.getcwd())
    project_db = Path(cwd) / '.claude' / 'hivemind.db'
    
    # Prefer project-level database
    if (Path(cwd) / '.claude').exists():
        project_db.parent.mkdir(parents=True, exist_ok=True)
        return project_db
    
    # Fallback to config directory
    config_dir = os.environ.get('CLAUDE_CONFIG_DIR', 
                  str(Path.home() / '.config' / 'claude'))
    global_db = Path(config_dir) / 'hivemind.db'
    global_db.parent.mkdir(parents=True, exist_ok=True)
    return global_db

def init_db(conn):
    """Initialize database with WAL mode and schema"""
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
            files_touched TEXT,
            context_tokens_used INTEGER
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
            key_facts TEXT,
            active_files TEXT,
            created_at REAL DEFAULT (julianday('now'))
        );
        
        CREATE TABLE IF NOT EXISTS learnings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            learning_type TEXT NOT NULL,
            content TEXT NOT NULL,
            exported INTEGER DEFAULT 0,
            created_at REAL DEFAULT (julianday('now'))
        );
        
        CREATE INDEX IF NOT EXISTS idx_tasks_session ON agent_tasks(session_id);
        CREATE INDEX IF NOT EXISTS idx_tasks_status ON agent_tasks(status);
        CREATE INDEX IF NOT EXISTS idx_learnings_exported ON learnings(exported);
    ''')
    conn.commit()

def ensure_db():
    """Ensure database exists and is initialized"""
    db_path = get_db_path()
    conn = sqlite3.connect(str(db_path), timeout=10.0)
    init_db(conn)
    return conn

def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "Usage: hivemind-db.py <command> [args]"}))
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
        
        elif cmd == "set":
            if len(sys.argv) < 4:
                print(json.dumps({"error": "Usage: set <key> <value>"}))
                sys.exit(1)
            key, value = sys.argv[2], sys.argv[3]
            cursor.execute('''
                INSERT INTO project_state (key, value, updated_at) 
                VALUES (?, ?, julianday('now'))
                ON CONFLICT(key) DO UPDATE SET 
                    value=excluded.value, 
                    updated_at=julianday('now')
            ''', (key, value))
            conn.commit()
            print(json.dumps({"status": "set", "key": key}))
        
        elif cmd == "get":
            if len(sys.argv) < 3:
                print(json.dumps({"error": "Usage: get <key>"}))
                sys.exit(1)
            key = sys.argv[2]
            cursor.execute('SELECT value FROM project_state WHERE key = ?', (key,))
            row = cursor.fetchone()
            print(json.dumps({"key": key, "value": row[0] if row else None}))
        
        elif cmd == "task-start":
            if len(sys.argv) < 4:
                print(json.dumps({"error": "Usage: task-start <session_id> <description> [agent_type]"}))
                sys.exit(1)
            session_id = sys.argv[2]
            description = sys.argv[3]
            agent_type = sys.argv[4] if len(sys.argv) > 4 else 'subagent'
            task_id = f"task-{datetime.now().strftime('%Y%m%d%H%M%S')}-{session_id[:8]}"
            cursor.execute('''
                INSERT INTO agent_tasks (id, session_id, agent_type, task_description, status)
                VALUES (?, ?, ?, ?, 'running')
            ''', (task_id, session_id, agent_type, description))
            conn.commit()
            print(json.dumps({"status": "started", "task_id": task_id}))
        
        elif cmd == "task-complete":
            if len(sys.argv) < 3:
                print(json.dumps({"error": "Usage: task-complete <task_id> [result]"}))
                sys.exit(1)
            task_id = sys.argv[2]
            result = sys.argv[3] if len(sys.argv) > 3 else None
            cursor.execute('''
                UPDATE agent_tasks 
                SET status = 'completed', 
                    completed_at = julianday('now'),
                    result_summary = ?
                WHERE id = ?
            ''', (result, task_id))
            conn.commit()
            print(json.dumps({"status": "completed", "task_id": task_id}))
        
        elif cmd == "learning-add":
            if len(sys.argv) < 4:
                print(json.dumps({"error": "Usage: learning-add <type> <content>"}))
                sys.exit(1)
            learning_type = sys.argv[2]
            content = sys.argv[3]
            cursor.execute('''
                INSERT INTO learnings (learning_type, content)
                VALUES (?, ?)
            ''', (learning_type, content))
            conn.commit()
            print(json.dumps({"status": "added", "id": cursor.lastrowid}))
        
        elif cmd == "learnings-export":
            cursor.execute('''
                SELECT id, learning_type, content, created_at 
                FROM learnings WHERE exported = 0 
                ORDER BY created_at ASC
            ''')
            rows = cursor.fetchall()
            if rows:
                ids = [r[0] for r in rows]
                cursor.execute(f'UPDATE learnings SET exported = 1 WHERE id IN ({",".join("?" * len(ids))})', ids)
                conn.commit()
            print(json.dumps({"learnings": [
                {"id": r[0], "type": r[1], "content": r[2]}
                for r in rows
            ]}))
        
        elif cmd == "snapshot-save":
            if len(sys.argv) < 4:
                print(json.dumps({"error": "Usage: snapshot-save <session_id> <summary>"}))
                sys.exit(1)
            session_id = sys.argv[2]
            summary = sys.argv[3]
            snap_id = f"snap-{datetime.now().strftime('%Y%m%d%H%M%S')}"
            cursor.execute('''
                INSERT INTO context_snapshots (id, session_id, snapshot_type, summary)
                VALUES (?, ?, 'auto', ?)
            ''', (snap_id, session_id, summary))
            conn.commit()
            print(json.dumps({"status": "saved", "snapshot_id": snap_id}))
        
        elif cmd == "statute":
            # Generate database statute for context injection
            cursor.execute('''
                SELECT agent_type, task_description, status, result_summary
                FROM agent_tasks 
                ORDER BY completed_at DESC 
                LIMIT 5
            ''')
            tasks = cursor.fetchall()
            
            cursor.execute('SELECT key, value FROM project_state')
            state = cursor.fetchall()
            
            output = ["## Database Statute"]
            if state:
                output.append("**Project State:**")
                for k, v in state:
                    output.append(f"- {k}: {v[:100]}{'...' if len(v) > 100 else ''}")
            if tasks:
                output.append("**Recent Tasks:**")
                for t in tasks:
                    output.append(f"- [{t[2]}] {t[0]}: {t[1][:50]}...")
            
            print("\n".join(output) if len(output) > 1 else "No statute data")
        
        elif cmd == "dump":
            cursor.execute('SELECT key, value FROM project_state')
            state = cursor.fetchall()
            cursor.execute('SELECT id, status, task_description FROM agent_tasks WHERE status = "running"')
            running = cursor.fetchall()
            print(json.dumps({
                "state": {r[0]: r[1] for r in state},
                "running_tasks": [{"id": r[0], "status": r[1], "desc": r[2]} for r in running]
            }, indent=2))
        
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

chmod +x "$SCRIPTS_DIR/hivemind-db.py"

#===============================================================================
# SESSION START HOOK - Verified format from official plugins
# NOTE: Issue #10373 - may not work for NEW sessions, use UserPromptSubmit fallback
#===============================================================================
cat > "$HOOKS_DIR/session-start.sh" << 'SESSION_HOOK'
#!/bin/bash
# Session Start Hook - Loads database statute into context
# Verified format from plugins/explanatory-output-style/hooks-handlers/session-start.sh

SCRIPT_DIR="$(dirname "$(dirname "$(readlink -f "$0")")")/scripts"

# Initialize database (idempotent)
python3 "$SCRIPT_DIR/hivemind-db.py" init >/dev/null 2>&1

# Get statute for context
STATUTE=$(python3 "$SCRIPT_DIR/hivemind-db.py" statute 2>/dev/null)

if [ -n "$STATUTE" ] && [ "$STATUTE" != "No statute data" ]; then
    # Escape for JSON (verified format from official plugins)
    CONTEXT_ESCAPED=$(echo "$STATUTE" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')
    cat << EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": ${CONTEXT_ESCAPED}
  }
}
EOF
fi

exit 0
SESSION_HOOK

chmod +x "$HOOKS_DIR/session-start.sh"

#===============================================================================
# USER PROMPT SUBMIT HOOK - Backup context injection (more reliable than SessionStart)
# Used because SessionStart is buggy for new sessions (Issue #10373)
#===============================================================================
cat > "$HOOKS_DIR/inject-context.sh" << 'INJECT_HOOK'
#!/bin/bash
# UserPromptSubmit Hook - Injects database statute into each prompt
# More reliable than SessionStart for new sessions (Issue #10373)

SCRIPT_DIR="$(dirname "$(dirname "$(readlink -f "$0")")")/scripts"

# Check environment guard to prevent double-injection
if [ "$HIVEMIND_CONTEXT_INJECTED" = "1" ]; then
    exit 0
fi

STATUTE=$(python3 "$SCRIPT_DIR/hivemind-db.py" statute 2>/dev/null)

if [ -n "$STATUTE" ] && [ "$STATUTE" != "No statute data" ]; then
    CONTEXT_ESCAPED=$(echo "$STATUTE" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')
    cat << EOF
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": ${CONTEXT_ESCAPED}
  }
}
EOF
fi

exit 0
INJECT_HOOK

chmod +x "$HOOKS_DIR/inject-context.sh"

#===============================================================================
# STOP HOOK - Exports learnings to project CLAUDE.md
# Verified format from plugins/ralph-wiggum/hooks/stop-hook.sh
#===============================================================================
cat > "$HOOKS_DIR/stop-hook.sh" << 'STOP_HOOK'
#!/bin/bash
# Stop Hook - Exports learnings and updates plan
# Verified format from ralph-wiggum plugin

SCRIPT_DIR="$(dirname "$(dirname "$(readlink -f "$0")")")/scripts"

# Read hook input
INPUT=$(cat)

# Check stop_hook_active to prevent infinite loops (verified field)
STOP_ACTIVE=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('stop_hook_active', False))" 2>/dev/null || echo "False")
if [ "$STOP_ACTIVE" = "True" ]; then
    exit 0
fi

# Environment guard for nested calls
if [ "$HIVEMIND_STOP_ACTIVE" = "1" ]; then
    exit 0
fi
export HIVEMIND_STOP_ACTIVE=1

# Export learnings to project CLAUDE.md
PROJECT_DIR=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('cwd', '.'))" 2>/dev/null || echo ".")
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

LEARNINGS=$(python3 "$SCRIPT_DIR/hivemind-db.py" learnings-export 2>/dev/null)
COUNT=$(echo "$LEARNINGS" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('learnings',[])))" 2>/dev/null || echo "0")

if [ "$COUNT" -gt 0 ] && [ -d "$PROJECT_DIR/.claude" ]; then
    PROJECT_CLAUDE="$PROJECT_DIR/.claude/CLAUDE.md"
    if [ ! -f "$PROJECT_CLAUDE" ]; then
        echo -e "# Project Memory\n\n## Session Learnings" > "$PROJECT_CLAUDE"
    fi
    echo -e "\n### Session $TIMESTAMP" >> "$PROJECT_CLAUDE"
    echo "$LEARNINGS" | python3 -c "
import sys, json
for l in json.load(sys.stdin).get('learnings', []):
    print(f\"- [{l['type']}] {l['content']}\")" >> "$PROJECT_CLAUDE" 2>/dev/null
fi

exit 0
STOP_HOOK

chmod +x "$HOOKS_DIR/stop-hook.sh"

#===============================================================================
# SUBAGENT STOP HOOK - Track task completion
# Note: Cannot identify WHICH subagent (Issue #7881) but can log completion
#===============================================================================
cat > "$HOOKS_DIR/subagent-complete.sh" << 'SUBAGENT_HOOK'
#!/bin/bash
# SubagentStop Hook - Records task completion
# Note: Issue #7881 - cannot identify specific subagent

SCRIPT_DIR="$(dirname "$(dirname "$(readlink -f "$0")")")/scripts"
INPUT=$(cat)

# Check stop_hook_active
STOP_ACTIVE=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('stop_hook_active', False))" 2>/dev/null || echo "False")
if [ "$STOP_ACTIVE" = "True" ]; then
    exit 0
fi

SESSION_ID=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id', 'unknown'))" 2>/dev/null || echo "unknown")

# Record completion (we don't know which task, just that a subagent finished)
python3 "$SCRIPT_DIR/hivemind-db.py" set "last_subagent_complete" "$SESSION_ID" 2>/dev/null

exit 0
SUBAGENT_HOOK

chmod +x "$HOOKS_DIR/subagent-complete.sh"

#===============================================================================
# PRE-TOOL-USE HOOK - Track Task tool spawns (workaround for Issue #7881)
#===============================================================================
cat > "$HOOKS_DIR/track-task-spawn.sh" << 'PRETOOL_HOOK'
#!/bin/bash
# PreToolUse Hook for Task tool - Tracks subagent spawns
# Workaround for Issue #7881 (SubagentStop can't identify which subagent)

SCRIPT_DIR="$(dirname "$(dirname "$(readlink -f "$0")")")/scripts"
INPUT=$(cat)

# Extract task description
DESCRIPTION=$(echo "$INPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
tool_input = d.get('tool_input', {})
print(tool_input.get('description', tool_input.get('prompt', 'unknown task'))[:200])
" 2>/dev/null || echo "unknown task")

SESSION_ID=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id', 'unknown'))" 2>/dev/null || echo "unknown")

# Record the task spawn
python3 "$SCRIPT_DIR/hivemind-db.py" task-start "$SESSION_ID" "$DESCRIPTION" "subagent" 2>/dev/null

exit 0
PRETOOL_HOOK

chmod +x "$HOOKS_DIR/track-task-spawn.sh"

#===============================================================================
# POST-TOOL-USE HOOK - CRLF fix for Write tool (Issue #2805)
#===============================================================================
cat > "$HOOKS_DIR/crlf-fix.sh" << 'CRLF_HOOK'
#!/bin/bash
# PostToolUse Hook - Fixes CRLF line endings on Linux (Issue #2805)
# This is a confirmed bug where Claude creates Windows line endings

INPUT=$(cat)

# Extract file path from Write tool input
FILE_PATH=$(echo "$INPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('tool_input', {}).get('file_path', ''))
" 2>/dev/null || echo "")

if [ -n "$FILE_PATH" ] && [ -f "$FILE_PATH" ]; then
    # Fix CRLF to LF (safe, idempotent)
    sed -i 's/\r$//' "$FILE_PATH" 2>/dev/null || true
fi

exit 0
CRLF_HOOK

chmod +x "$HOOKS_DIR/crlf-fix.sh"

#===============================================================================
# CONTEXT WATCHER SCRIPT - Monitors transcript for context usage
# REQUIRED because PreCompact hooks are broken (Issue #13572)
#===============================================================================
cat > "$SCRIPTS_DIR/context-watcher.sh" << 'WATCHER_SCRIPT'
#!/bin/bash
# Context Window Watcher - Monitors transcript growth
# Required because PreCompact hooks don't fire (Issue #13572)
# Run as: nohup ~/.config/claude/scripts/context-watcher.sh &

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

# Find transcript directory (encoded project path)
find_transcript_dir() {
    local config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.config/claude}"
    if [ ! -d "$config_dir" ]; then
        config_dir="$HOME/.claude"
    fi
    echo "$config_dir/projects"
}

TRANSCRIPT_DIR=$(find_transcript_dir)
MAX_CONTEXT=200000
WARN_THRESHOLD=75
CRITICAL_THRESHOLD=90
CHECK_INTERVAL=30

calculate_usage() {
    local jsonl_file="$1"
    # Get last entry with usage data
    local usage=$(grep '"usage"' "$jsonl_file" 2>/dev/null | tail -1 | \
                  python3 -c "
import sys, json
try:
    line = sys.stdin.read().strip()
    if line:
        d = json.loads(line)
        u = d.get('message', {}).get('usage', {})
        total = u.get('input_tokens', 0) + u.get('cache_read_input_tokens', 0) + u.get('cache_creation_input_tokens', 0)
        print(int(total * 100 / $MAX_CONTEXT))
except:
    print(0)
" 2>/dev/null || echo "0")
    echo "$usage"
}

preserve_context() {
    local jsonl_file="$1"
    local session_id=$(basename "$jsonl_file" .jsonl)
    
    # Extract key information
    local summary=$(grep '"role":"assistant"' "$jsonl_file" 2>/dev/null | tail -5 | \
                   python3 -c "
import sys, json
texts = []
for line in sys.stdin:
    try:
        d = json.loads(line.strip())
        for c in d.get('message', {}).get('content', []):
            if c.get('type') == 'text':
                texts.append(c.get('text', '')[:200])
    except:
        pass
print(' | '.join(texts[-3:])[:500])
" 2>/dev/null || echo "No summary available")
    
    # Save snapshot
    python3 "$SCRIPT_DIR/hivemind-db.py" snapshot-save "$session_id" "$summary" 2>/dev/null
    
    echo "[$(date)] Preserved context for session $session_id (${summary:0:50}...)"
}

echo "[$(date)] Context watcher started. Monitoring: $TRANSCRIPT_DIR"
echo "    Warn at ${WARN_THRESHOLD}%, Critical at ${CRITICAL_THRESHOLD}%"

while true; do
    # Find active transcripts (modified in last 5 minutes)
    if [ -d "$TRANSCRIPT_DIR" ]; then
        for jsonl in $(find "$TRANSCRIPT_DIR" -name "*.jsonl" -mmin -5 2>/dev/null); do
            usage=$(calculate_usage "$jsonl")
            
            if [ "$usage" -gt "$CRITICAL_THRESHOLD" ] 2>/dev/null; then
                echo "[CRITICAL] $(basename "$jsonl") at ${usage}%"
                preserve_context "$jsonl"
                # Desktop notification if available
                which notify-send >/dev/null 2>&1 && \
                    notify-send "Claude Context Critical" "Session at ${usage}% - snapshot saved"
            elif [ "$usage" -gt "$WARN_THRESHOLD" ] 2>/dev/null; then
                echo "[WARNING] $(basename "$jsonl") at ${usage}%"
            fi
        done
    fi
    sleep $CHECK_INTERVAL
done
WATCHER_SCRIPT

chmod +x "$SCRIPTS_DIR/context-watcher.sh"

#===============================================================================
# HEADLESS AGENT SPAWNER - With loop prevention
# NOTE: --settings flag DOES NOT EXIST, using environment guards instead
#===============================================================================
cat > "$SCRIPTS_DIR/spawn-agent.sh" << 'SPAWN_SCRIPT'
#!/bin/bash
# Spawn a headless Claude Code agent with loop prevention
# NOTE: --settings flag does not exist, using environment guards instead

AGENT_NAME="${1:-worker}"
TASK_PROMPT="$2"
WORK_DIR="${3:-$(pwd)}"
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
LOG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.config/claude}/agent-logs"

mkdir -p "$LOG_DIR"

if [ -z "$TASK_PROMPT" ]; then
    echo "Usage: spawn-agent.sh <agent-name> <task-prompt> [working-dir]"
    exit 1
fi

SESSION_ID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || date +%s%N)

# Register in database
python3 "$SCRIPT_DIR/hivemind-db.py" task-start "$SESSION_ID" "$TASK_PROMPT" "$AGENT_NAME" 2>/dev/null

cd "$WORK_DIR"

# Spawn with environment guards to prevent hook loops
# NOTE: We cannot disable hooks, but we set guards that our hooks check
HIVEMIND_SPAWNED_AGENT=1 \
HIVEMIND_CONTEXT_INJECTED=1 \
nohup claude -p "$TASK_PROMPT" \
    --output-format stream-json \
    --max-turns 20 \
    > "$LOG_DIR/${AGENT_NAME}-${SESSION_ID:0:8}.log" 2>&1 &

AGENT_PID=$!
echo "$AGENT_PID" > "$LOG_DIR/${AGENT_NAME}.pid"

echo "{\"agent\": \"$AGENT_NAME\", \"session_id\": \"$SESSION_ID\", \"pid\": $AGENT_PID}"

# Background completion tracking
(
    wait $AGENT_PID 2>/dev/null
    python3 "$SCRIPT_DIR/hivemind-db.py" task-complete "task-*-${SESSION_ID:0:8}" "Process exited" 2>/dev/null
) &
SPAWN_SCRIPT

chmod +x "$SCRIPTS_DIR/spawn-agent.sh"

#===============================================================================
# HIVEMIND CLI
#===============================================================================
cat > "$SCRIPTS_DIR/hivemind.sh" << 'HIVEMIND_CLI'
#!/bin/bash
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
LOG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.config/claude}/agent-logs"

case "$1" in
    spawn)
        "$SCRIPT_DIR/spawn-agent.sh" "$2" "$3" "$4"
        ;;
    status)
        python3 "$SCRIPT_DIR/hivemind-db.py" dump
        ;;
    watcher)
        case "$2" in
            start)
                nohup "$SCRIPT_DIR/context-watcher.sh" > "$LOG_DIR/watcher.log" 2>&1 &
                echo "Context watcher started (PID: $!)"
                ;;
            stop)
                pkill -f "context-watcher.sh" 2>/dev/null && echo "Stopped" || echo "Not running"
                ;;
            logs)
                tail -f "$LOG_DIR/watcher.log" 2>/dev/null || echo "No logs"
                ;;
            *)
                echo "Usage: hivemind.sh watcher [start|stop|logs]"
                ;;
        esac
        ;;
    learn)
        shift
        python3 "$SCRIPT_DIR/hivemind-db.py" learning-add "$@"
        ;;
    set)
        shift
        python3 "$SCRIPT_DIR/hivemind-db.py" set "$@"
        ;;
    get)
        shift
        python3 "$SCRIPT_DIR/hivemind-db.py" get "$@"
        ;;
    statute)
        python3 "$SCRIPT_DIR/hivemind-db.py" statute
        ;;
    logs)
        ls -la "$LOG_DIR"/*.log 2>/dev/null || echo "No logs"
        ;;
    *)
        echo "Claude Code Hivemind V3 CLI"
        echo ""
        echo "Commands:"
        echo "  spawn <name> <task> [dir]  - Spawn headless agent"
        echo "  status                      - Show database state"
        echo "  watcher [start|stop|logs]  - Context watcher (REQUIRED - PreCompact broken)"
        echo "  learn <type> <content>      - Record learning"
        echo "  set <key> <value>           - Set project state"
        echo "  get <key>                   - Get project state"
        echo "  statute                     - Generate context statute"
        echo "  logs                        - Show agent logs"
        ;;
esac
HIVEMIND_CLI

chmod +x "$SCRIPTS_DIR/hivemind.sh"

#===============================================================================
# SETTINGS.JSON - Verified hook format from official plugins
#===============================================================================
cat > "$CLAUDE_DIR/settings.json" << 'SETTINGS_JSON'
{
  "permissions": {
    "allow": [
      "Read(*)",
      "Grep(*)",
      "Glob(*)",
      "Bash(python3:*)",
      "Bash(git status)",
      "Bash(git diff:*)",
      "Bash(git log:*)"
    ],
    "deny": [
      "Bash(rm -rf /)",
      "Bash(rm -rf ~)"
    ]
  },
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume|compact",
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_CONFIG_DIR:-~/.config/claude}/hooks/hivemind/session-start.sh",
            "timeout": 10
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_CONFIG_DIR:-~/.config/claude}/hooks/hivemind/inject-context.sh",
            "timeout": 5
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_CONFIG_DIR:-~/.config/claude}/hooks/hivemind/stop-hook.sh",
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
            "command": "${CLAUDE_CONFIG_DIR:-~/.config/claude}/hooks/hivemind/subagent-complete.sh",
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
            "command": "${CLAUDE_CONFIG_DIR:-~/.config/claude}/hooks/hivemind/track-task-spawn.sh",
            "timeout": 5
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Write",
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_CONFIG_DIR:-~/.config/claude}/hooks/hivemind/crlf-fix.sh",
            "timeout": 5
          }
        ]
      }
    ]
  },
  "env": {
    "PYTHONUNBUFFERED": "1",
    "CLAUDE_HIVEMIND_ENABLED": "1"
  }
}
SETTINGS_JSON

#===============================================================================
# GLOBAL CLAUDE.MD - No @ imports (Issue #1041)
#===============================================================================
cat > "$CLAUDE_DIR/CLAUDE.md" << 'GLOBAL_CLAUDE_MD'
# Claude Code Hivemind V3

## Automatic Systems

- **SessionStart/UserPromptSubmit**: Loads database statute into context
- **Stop**: Exports learnings to project .claude/CLAUDE.md  
- **SubagentStop**: Tracks task completions
- **PreToolUse[Task]**: Tracks subagent spawns
- **PostToolUse[Write]**: Fixes CRLF line endings (Issue #2805)

## CRITICAL: Start Context Watcher

PreCompact hooks are broken (Issue #13572). Run the watcher to preserve context:
```bash
~/.config/claude/scripts/hivemind.sh watcher start
```

## Record Learnings

```bash
~/.config/claude/scripts/hivemind.sh learn decision "Chose X because Y"
~/.config/claude/scripts/hivemind.sh learn pattern "Always check for..."
~/.config/claude/scripts/hivemind.sh learn bug "Issue when..."
```

## Project State

```bash
~/.config/claude/scripts/hivemind.sh set current_phase "Implementation"
~/.config/claude/scripts/hivemind.sh get current_phase
~/.config/claude/scripts/hivemind.sh statute
```

## Spawn Agents

```bash
~/.config/claude/scripts/hivemind.sh spawn researcher "Analyze codebase"
~/.config/claude/scripts/hivemind.sh spawn coder "Implement feature X"
~/.config/claude/scripts/hivemind.sh status
```
GLOBAL_CLAUDE_MD

#===============================================================================
# SLASH COMMANDS
#===============================================================================
cat > "$COMMANDS_DIR/hivemind.md" << 'EOF'
---
description: Manage hivemind agents and memory
argument-hint: [status|spawn|watcher|learn|statute]
---
Run: `~/.config/claude/scripts/hivemind.sh $ARGUMENTS`
EOF

cat > "$COMMANDS_DIR/learn.md" << 'EOF'
---
description: Record a learning (decision, pattern, bug, etc)
argument-hint: <type> <content>
---
Run: `~/.config/claude/scripts/hivemind.sh learn $ARGUMENTS`
Types: decision, pattern, convention, bug, optimization
EOF

#===============================================================================
# CREATE LOG DIRECTORY
#===============================================================================
mkdir -p "$CLAUDE_DIR/agent-logs"

#===============================================================================
# INITIALIZE DATABASE
#===============================================================================
python3 "$SCRIPTS_DIR/hivemind-db.py" init

#===============================================================================
# OUTPUT
#===============================================================================
echo ""
echo "==> Claude Code Hivemind V3 Complete!"
echo ""
echo "VERIFIED AGAINST:"
echo "  • Claude Code v2.0.76"
echo "  • Official plugins: hookify, ralph-wiggum, explanatory-output-style"
echo "  • GitHub Issues: #13572, #1041, #2805, #7881, #10373"
echo ""
echo "CRITICAL FIXES:"
echo "  ✓ Config directory: $CLAUDE_DIR (detected automatically)"
echo "  ✓ PreCompact hooks BROKEN - using context watcher instead"
echo "  ✓ SessionStart unreliable - using UserPromptSubmit fallback"
echo "  ✓ CRLF fix for Linux (Issue #2805)"
echo "  ✓ Removed non-existent --settings flag"
echo "  ✓ Removed non-existent disableAllHooks setting"
echo "  ✓ Using environment guards for loop prevention"
echo ""
echo "REQUIRED: Start the context watcher (PreCompact is broken):"
echo "  $SCRIPTS_DIR/hivemind.sh watcher start"
echo ""
echo "TEST:"
echo "  python3 $SCRIPTS_DIR/hivemind-db.py set test_key 'hello'"
echo "  python3 $SCRIPTS_DIR/hivemind-db.py statute"
echo ""
echo "IMPORTANT: Run 'claude' and use /hooks to verify hooks loaded!"
