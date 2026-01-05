#!/bin/bash
#===============================================================================
# Claude Code Hivemind Setup Script V3
# 
# VERIFIED AGAINST:
#   - anthropics/claude-code GitHub issues (Jan 2026)
#   - Issue #13572: PreCompact hooks not firing (WORKAROUND: transcript watcher)
#   - Issue #2805: CRLF line endings on Linux (WORKAROUND: PostToolUse sed fix)
#   - Issue #1041: @ imports fail in global CLAUDE.md (USE: project-level only)
#   - Issue #10373: SessionStart buggy for new sessions (USE: UserPromptSubmit)
#   - Issue #7881: SubagentStop can't identify agent (USE: PreToolUse tracking)
#
# KEY V3 CHANGES FROM V2:
#   - Removed reliance on PreCompact hooks (broken per #13572)
#   - Use UserPromptSubmit instead of SessionStart for context injection
#   - Added PostToolUse CRLF fix for Linux (issue #2805)
#   - Removed @ imports in global CLAUDE.md (broken per #1041)
#   - Added hook isolation via environment variables (not fake disableAllHooks)
#   - Added transcript watcher for context preservation
#   - Gemini CLI is optional, not required
#
# For Arch Linux (or any Linux with claude-code installed)
# Run: chmod +x setup-claude-hivemind-v3.sh && ./setup-claude-hivemind-v3.sh
#===============================================================================

set -e

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

#===============================================================================
# CONFIGURATION
#===============================================================================
CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks/hivemind"
SCRIPTS_DIR="$CLAUDE_DIR/scripts"

# Detect config directory (Issue #2277 - may be ~/.config/claude)
if [ -d "$HOME/.config/claude" ] && [ ! -d "$HOME/.claude" ]; then
    CLAUDE_DIR="$HOME/.config/claude"
    HOOKS_DIR="$CLAUDE_DIR/hooks/hivemind"
    SCRIPTS_DIR="$CLAUDE_DIR/scripts"
    log_warn "Using ~/.config/claude (detected alternative location)"
fi

log_info "Setting up Claude Code Hivemind V3..."
log_info "Config directory: $CLAUDE_DIR"

# Create directory structure
mkdir -p "$HOOKS_DIR" "$SCRIPTS_DIR" "$CLAUDE_DIR/agent-logs"

#===============================================================================
# SQLITE MEMORY DATABASE MANAGER
# Simplified, focused on core functionality
#===============================================================================
cat > "$SCRIPTS_DIR/hivemind-db.py" << 'DBSCRIPT'
#!/usr/bin/env python3
"""
Claude Code Hivemind SQLite Manager V3
Database location: .claude/hivemind.db (project) or ~/.claude/hivemind.db (global)

Commands:
  init                    Initialize database
  set <key> <value> [cat] Store a key-value pair
  get <key>               Retrieve a value
  list [category]         List all memory entries
  dump                    Dump all state as JSON
  dump-compact            Compact format for context injection
  task-start <desc>       Record task start
  task-complete <id> [result] Mark task complete
  task-list               List recent tasks
  snapshot-save <name>    Save current state snapshot
  snapshot-load <name>    Load snapshot
  learning-add <type> <content> Record a learning
  learnings-export        Export unexported learnings
"""
import sqlite3
import json
import sys
import os
from datetime import datetime
from pathlib import Path

def get_db_path():
    """Prefer project db if .claude exists, else global"""
    project_dir = os.environ.get('CLAUDE_PROJECT_DIR', os.getcwd())
    project_db = Path(project_dir) / '.claude' / 'hivemind.db'
    
    # Check for config dir ambiguity
    config_dir = os.environ.get('CLAUDE_CONFIG_DIR', str(Path.home() / '.claude'))
    global_db = Path(config_dir) / 'hivemind.db'
    
    if (Path(project_dir) / '.claude').exists():
        return project_db
    return global_db

def init_db(conn):
    """Initialize database with WAL mode and schema"""
    conn.execute('PRAGMA journal_mode=WAL')
    conn.execute('PRAGMA busy_timeout=5000')
    conn.execute('PRAGMA synchronous=NORMAL')
    
    conn.executescript('''
        CREATE TABLE IF NOT EXISTS memory (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            key TEXT UNIQUE NOT NULL,
            value TEXT NOT NULL,
            category TEXT DEFAULT 'general',
            created_at TEXT DEFAULT (datetime('now')),
            updated_at TEXT DEFAULT (datetime('now'))
        );
        
        CREATE TABLE IF NOT EXISTS agent_tasks (
            id TEXT PRIMARY KEY,
            session_id TEXT,
            task_description TEXT NOT NULL,
            status TEXT DEFAULT 'running',
            started_at TEXT DEFAULT (datetime('now')),
            completed_at TEXT,
            result_summary TEXT,
            files_touched TEXT
        );
        
        CREATE TABLE IF NOT EXISTS context_snapshots (
            id TEXT PRIMARY KEY,
            session_id TEXT,
            snapshot_type TEXT DEFAULT 'manual',
            summary TEXT,
            key_facts TEXT,
            created_at TEXT DEFAULT (datetime('now'))
        );
        
        CREATE TABLE IF NOT EXISTS learnings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            learning_type TEXT NOT NULL,
            content TEXT NOT NULL,
            created_at TEXT DEFAULT (datetime('now')),
            exported INTEGER DEFAULT 0
        );
        
        CREATE TABLE IF NOT EXISTS project_state (
            key TEXT PRIMARY KEY,
            value TEXT,
            updated_at TEXT DEFAULT (datetime('now'))
        );
        
        CREATE INDEX IF NOT EXISTS idx_memory_key ON memory(key);
        CREATE INDEX IF NOT EXISTS idx_memory_category ON memory(category);
        CREATE INDEX IF NOT EXISTS idx_tasks_status ON agent_tasks(status);
        CREATE INDEX IF NOT EXISTS idx_learnings_exported ON learnings(exported);
    ''')
    conn.commit()

def ensure_db():
    db_path = get_db_path()
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(db_path))
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
            print(json.dumps({"key": sys.argv[2], "value": row[0], "category": row[1]} if row else {"key": sys.argv[2], "value": None}))
        
        elif cmd == "list":
            category = sys.argv[2] if len(sys.argv) > 2 else None
            if category:
                cursor.execute('SELECT key, value, category FROM memory WHERE category = ?', (category,))
            else:
                cursor.execute('SELECT key, value, category FROM memory')
            rows = cursor.fetchall()
            print(json.dumps({"memories": [{"key": r[0], "value": r[1], "category": r[2]} for r in rows]}))
        
        elif cmd == "dump":
            cursor.execute('SELECT key, value, category FROM memory')
            memories = cursor.fetchall()
            cursor.execute('SELECT id, task_description, status, started_at, completed_at FROM agent_tasks ORDER BY started_at DESC LIMIT 10')
            tasks = cursor.fetchall()
            cursor.execute('SELECT key, value FROM project_state')
            state = cursor.fetchall()
            print(json.dumps({
                "memories": {r[0]: {"value": r[1], "category": r[2]} for r in memories},
                "recent_tasks": [{"id": r[0], "desc": r[1], "status": r[2], "started": r[3], "completed": r[4]} for r in tasks],
                "project_state": {r[0]: r[1] for r in state}
            }, indent=2))
        
        elif cmd == "dump-compact":
            # Compact format for context injection - minimize tokens
            cursor.execute('SELECT key, value FROM memory ORDER BY updated_at DESC LIMIT 20')
            memories = cursor.fetchall()
            cursor.execute('SELECT task_description, status FROM agent_tasks ORDER BY started_at DESC LIMIT 5')
            tasks = cursor.fetchall()
            cursor.execute('SELECT key, value FROM project_state WHERE key IN ("current_phase", "blockers", "next_milestone")')
            state = cursor.fetchall()
            
            output = []
            if state:
                output.append("STATE: " + " | ".join(f"{k}={v}" for k,v in state))
            if tasks:
                output.append("RECENT: " + "; ".join(f"{t[0][:40]}[{t[1]}]" for t in tasks))
            if memories:
                output.append("MEMORY: " + "; ".join(f"{k}={v[:50]}" for k,v in memories[:10]))
            
            print("\n".join(output) if output else "No state")
        
        elif cmd == "task-start":
            if len(sys.argv) < 3:
                print(json.dumps({"error": "Usage: task-start <description>"}))
                sys.exit(1)
            import uuid
            task_id = f"task-{uuid.uuid4().hex[:8]}"
            desc = sys.argv[2]
            session_id = os.environ.get('CLAUDE_SESSION_ID', 'unknown')
            cursor.execute('''
                INSERT INTO agent_tasks (id, session_id, task_description, status)
                VALUES (?, ?, ?, 'running')
            ''', (task_id, session_id, desc))
            conn.commit()
            print(json.dumps({"status": "started", "task_id": task_id}))
        
        elif cmd == "task-complete":
            if len(sys.argv) < 3:
                print(json.dumps({"error": "Usage: task-complete <task_id> [result]"}))
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
            cursor.execute('''
                SELECT id, task_description, status, started_at, completed_at 
                FROM agent_tasks ORDER BY started_at DESC LIMIT 20
            ''')
            rows = cursor.fetchall()
            print(json.dumps({"tasks": [
                {"id": r[0], "desc": r[1], "status": r[2], "started": r[3], "completed": r[4]}
                for r in rows
            ]}))
        
        elif cmd == "snapshot-save":
            if len(sys.argv) < 3:
                print(json.dumps({"error": "Usage: snapshot-save <name>"}))
                sys.exit(1)
            import uuid
            name = sys.argv[2]
            snapshot_id = f"snap-{uuid.uuid4().hex[:8]}"
            session_id = os.environ.get('CLAUDE_SESSION_ID', 'unknown')
            
            # Gather current state
            cursor.execute('SELECT key, value FROM memory')
            memories = cursor.fetchall()
            cursor.execute('SELECT id, task_description, status FROM agent_tasks WHERE status="running"')
            running = cursor.fetchall()
            
            summary = json.dumps({
                "memories": {k: v for k, v in memories},
                "running_tasks": [{"id": r[0], "desc": r[1]} for r in running]
            })
            
            cursor.execute('''
                INSERT INTO context_snapshots (id, session_id, snapshot_type, summary)
                VALUES (?, ?, ?, ?)
            ''', (snapshot_id, session_id, name, summary))
            conn.commit()
            print(json.dumps({"status": "saved", "snapshot_id": snapshot_id}))
        
        elif cmd == "snapshot-load":
            if len(sys.argv) < 3:
                print(json.dumps({"error": "Usage: snapshot-load <name>"}))
                sys.exit(1)
            cursor.execute('''
                SELECT summary FROM context_snapshots WHERE snapshot_type=? ORDER BY created_at DESC LIMIT 1
            ''', (sys.argv[2],))
            row = cursor.fetchone()
            if row:
                print(row[0])
            else:
                print(json.dumps({"error": "snapshot not found"}))
        
        elif cmd == "learning-add":
            if len(sys.argv) < 4:
                print(json.dumps({"error": "Usage: learning-add <type> <content>"}))
                sys.exit(1)
            cursor.execute('''
                INSERT INTO learnings (learning_type, content) VALUES (?, ?)
            ''', (sys.argv[2], sys.argv[3]))
            conn.commit()
            print(json.dumps({"status": "added", "learning_id": cursor.lastrowid}))
        
        elif cmd == "learnings-export":
            cursor.execute('''
                SELECT id, learning_type, content, created_at 
                FROM learnings WHERE exported=0 ORDER BY created_at
            ''')
            rows = cursor.fetchall()
            if rows:
                ids = [r[0] for r in rows]
                cursor.execute(f'UPDATE learnings SET exported=1 WHERE id IN ({",".join("?" * len(ids))})', ids)
                conn.commit()
            print(json.dumps({"learnings": [
                {"id": r[0], "type": r[1], "content": r[2], "created_at": r[3]}
                for r in rows
            ]}))
        
        elif cmd == "state-set":
            if len(sys.argv) < 4:
                print(json.dumps({"error": "Usage: state-set <key> <value>"}))
                sys.exit(1)
            cursor.execute('''
                INSERT INTO project_state (key, value, updated_at) VALUES (?, ?, datetime('now'))
                ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=datetime('now')
            ''', (sys.argv[2], sys.argv[3]))
            conn.commit()
            print(json.dumps({"status": "set", "key": sys.argv[2]}))
        
        else:
            print(json.dumps({"error": f"Unknown command: {cmd}", 
                "commands": ["init", "set", "get", "list", "dump", "dump-compact", 
                            "task-start", "task-complete", "task-list",
                            "snapshot-save", "snapshot-load", 
                            "learning-add", "learnings-export", "state-set"]}))
            sys.exit(1)
            
    except Exception as e:
        print(json.dumps({"error": str(e)}))
        sys.exit(1)
    finally:
        conn.close()

if __name__ == "__main__":
    main()
DBSCRIPT

chmod +x "$SCRIPTS_DIR/hivemind-db.py"
log_success "Created hivemind-db.py"

#===============================================================================
# CRLF FIX HOOK (Issue #2805 workaround)
# Runs after Write tool to convert CRLF to LF on Linux
#===============================================================================
cat > "$HOOKS_DIR/crlf-fix.sh" << 'CRLFHOOK'
#!/bin/bash
# PostToolUse hook: Fix CRLF line endings on Linux (Issue #2805)
# Reads JSON from stdin, extracts file path, runs sed

# Guard against recursive execution
[ "$HIVEMIND_HOOK_ACTIVE" = "true" ] && exit 0

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    # Handle both Write and Edit tools
    fp = d.get('tool_input', {}).get('file_path') or d.get('tool_input', {}).get('path', '')
    print(fp)
except:
    pass
" 2>/dev/null)

if [ -n "$FILE_PATH" ] && [ -f "$FILE_PATH" ]; then
    # Only fix text files, skip binaries
    if file "$FILE_PATH" | grep -q "text"; then
        sed -i 's/\r$//' "$FILE_PATH" 2>/dev/null
    fi
fi

exit 0
CRLFHOOK

chmod +x "$HOOKS_DIR/crlf-fix.sh"
log_success "Created crlf-fix.sh (Issue #2805 workaround)"

#===============================================================================
# USER PROMPT SUBMIT HOOK - Context Injection
# More reliable than SessionStart for new sessions (Issue #10373 workaround)
#===============================================================================
cat > "$HOOKS_DIR/inject-context.sh" << 'INJECTHOOK'
#!/bin/bash
# UserPromptSubmit hook: Inject database statute into context
# This is more reliable than SessionStart for new sessions (Issue #10373)

SCRIPT_DIR="$HOME/.claude/scripts"
[ -d "$HOME/.config/claude/scripts" ] && SCRIPT_DIR="$HOME/.config/claude/scripts"

# Guard against recursive execution
[ "$HIVEMIND_HOOK_ACTIVE" = "true" ] && exit 0

# Get compact state from database
CONTEXT=$(python3 "$SCRIPT_DIR/hivemind-db.py" dump-compact 2>/dev/null)

if [ -n "$CONTEXT" ] && [ "$CONTEXT" != "No state" ]; then
    # Escape for JSON
    CONTEXT_ESCAPED=$(echo "$CONTEXT" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null)
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
INJECTHOOK

chmod +x "$HOOKS_DIR/inject-context.sh"
log_success "Created inject-context.sh (Issue #10373 workaround)"

#===============================================================================
# SUBAGENT COMPLETE HOOK - Record task completion
#===============================================================================
cat > "$HOOKS_DIR/subagent-complete.sh" << 'SUBHOOK'
#!/bin/bash
# SubagentStop hook: Record task completion in database
# Note: Cannot identify specific subagent (Issue #7881), but logs completion

SCRIPT_DIR="$HOME/.claude/scripts"
[ -d "$HOME/.config/claude/scripts" ] && SCRIPT_DIR="$HOME/.config/claude/scripts"

# Guard against recursive execution
[ "$HIVEMIND_HOOK_ACTIVE" = "true" ] && exit 0

INPUT=$(cat)

# Check stop_hook_active to prevent loops
STOP_ACTIVE=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('stop_hook_active', False))" 2>/dev/null || echo "False")
[ "$STOP_ACTIVE" = "True" ] && exit 0

# Extract session info
SESSION_ID=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id', 'unknown'))" 2>/dev/null || echo "unknown")

# Save snapshot
CLAUDE_SESSION_ID="$SESSION_ID" python3 "$SCRIPT_DIR/hivemind-db.py" snapshot-save "subagent-complete" >/dev/null 2>&1

exit 0
SUBHOOK

chmod +x "$HOOKS_DIR/subagent-complete.sh"
log_success "Created subagent-complete.sh"

#===============================================================================
# STOP HOOK - Update plan status and export learnings
#===============================================================================
cat > "$HOOKS_DIR/update-plan.sh" << 'STOPHOOK'
#!/bin/bash
# Stop hook: Export learnings to project CLAUDE.md and save snapshot

SCRIPT_DIR="$HOME/.claude/scripts"
[ -d "$HOME/.config/claude/scripts" ] && SCRIPT_DIR="$HOME/.config/claude/scripts"

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# Guard against recursive execution
[ "$HIVEMIND_HOOK_ACTIVE" = "true" ] && exit 0

INPUT=$(cat)

# Check stop_hook_active to prevent loops
STOP_ACTIVE=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('stop_hook_active', False))" 2>/dev/null || echo "False")
[ "$STOP_ACTIVE" = "True" ] && exit 0

# Save snapshot
python3 "$SCRIPT_DIR/hivemind-db.py" snapshot-save "stop-$TIMESTAMP" >/dev/null 2>&1

# Export learnings to project CLAUDE.md if project has .claude directory
LEARNINGS=$(python3 "$SCRIPT_DIR/hivemind-db.py" learnings-export 2>/dev/null)
COUNT=$(echo "$LEARNINGS" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('learnings',[])))" 2>/dev/null || echo "0")

if [ "$COUNT" -gt 0 ] && [ -d "$PROJECT_DIR/.claude" ]; then
    PROJECT_CLAUDE="$PROJECT_DIR/.claude/CLAUDE.md"
    
    if [ ! -f "$PROJECT_CLAUDE" ]; then
        echo -e "# Project Memory\n\n## Session Learnings" > "$PROJECT_CLAUDE"
    fi
    
    {
        echo -e "\n### Session $TIMESTAMP"
        echo "$LEARNINGS" | python3 -c "
import sys, json
for l in json.load(sys.stdin).get('learnings', []):
    print(f\"- [{l['type']}] {l['content']}\")"
    } >> "$PROJECT_CLAUDE" 2>/dev/null
fi

exit 0
STOPHOOK

chmod +x "$HOOKS_DIR/update-plan.sh"
log_success "Created update-plan.sh"

#===============================================================================
# TRANSCRIPT WATCHER - Monitor context window usage
# Alternative to broken PreCompact hooks (Issue #13572)
#===============================================================================
cat > "$SCRIPTS_DIR/context-watcher.sh" << 'WATCHERSCRIPT'
#!/bin/bash
# Context window watcher - monitors transcript files for context growth
# Run as background process: nohup ~/.claude/scripts/context-watcher.sh &
#
# This is a workaround for Issue #13572 (PreCompact hooks not firing)

SCRIPT_DIR="$HOME/.claude/scripts"
[ -d "$HOME/.config/claude/scripts" ] && SCRIPT_DIR="$HOME/.config/claude/scripts"

TRANSCRIPT_DIR="$HOME/.claude/projects"
[ -d "$HOME/.config/claude/projects" ] && TRANSCRIPT_DIR="$HOME/.config/claude/projects"

MAX_CONTEXT=200000   # Claude's context window
WARN_THRESHOLD=75    # Warn at 75%
CRITICAL_THRESHOLD=90
CHECK_INTERVAL=30    # seconds
LOG_FILE="/tmp/hivemind-watcher.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

calculate_usage() {
    local jsonl_file="$1"
    
    # Get last entry with usage data
    local usage_line=$(grep '"usage"' "$jsonl_file" 2>/dev/null | tail -1)
    
    if [ -n "$usage_line" ]; then
        local total=$(echo "$usage_line" | python3 -c "
import sys, json, re
line = sys.stdin.read()
# Find JSON object containing usage
match = re.search(r'\"usage\":\s*\{[^}]+\}', line)
if match:
    # Extract just the usage object
    usage_str = '{' + match.group() + '}'
    # This is a bit hacky, extract numbers
    import re
    input_tokens = int(re.search(r'\"input_tokens\":\s*(\d+)', line).group(1)) if re.search(r'\"input_tokens\":\s*(\d+)', line) else 0
    cache_read = int(re.search(r'\"cache_read_input_tokens\":\s*(\d+)', line).group(1)) if re.search(r'\"cache_read_input_tokens\":\s*(\d+)', line) else 0
    cache_create = int(re.search(r'\"cache_creation_input_tokens\":\s*(\d+)', line).group(1)) if re.search(r'\"cache_creation_input_tokens\":\s*(\d+)', line) else 0
    print(input_tokens + cache_read + cache_create)
else:
    print(0)
" 2>/dev/null)
        
        if [ -n "$total" ] && [ "$total" -gt 0 ]; then
            echo $((total * 100 / MAX_CONTEXT))
        else
            echo 0
        fi
    else
        echo 0
    fi
}

preserve_context() {
    local jsonl_file="$1"
    local session_id=$(basename "$jsonl_file" .jsonl)
    
    log "Preserving context for session $session_id"
    
    # Save snapshot via database
    CLAUDE_SESSION_ID="$session_id" python3 "$SCRIPT_DIR/hivemind-db.py" snapshot-save "auto-preserve-$(date +%s)" >/dev/null 2>&1
    
    # Send desktop notification if available
    if command -v notify-send &>/dev/null; then
        notify-send "Claude Hivemind" "Context at critical level - snapshot saved"
    fi
}

log "Context watcher started (checking every ${CHECK_INTERVAL}s)"
log "Transcript directory: $TRANSCRIPT_DIR"

while true; do
    # Find active transcripts (modified in last 5 minutes)
    while IFS= read -r jsonl; do
        [ -z "$jsonl" ] && continue
        
        usage=$(calculate_usage "$jsonl")
        session=$(basename "$jsonl" .jsonl | cut -c1-8)
        
        if [ "$usage" -gt "$CRITICAL_THRESHOLD" ]; then
            log "[CRITICAL] Session $session at ${usage}% - preserving context"
            preserve_context "$jsonl"
        elif [ "$usage" -gt "$WARN_THRESHOLD" ]; then
            log "[WARNING] Session $session at ${usage}%"
        fi
    done < <(find "$TRANSCRIPT_DIR" -name "*.jsonl" -mmin -5 2>/dev/null)
    
    sleep $CHECK_INTERVAL
done
WATCHERSCRIPT

chmod +x "$SCRIPTS_DIR/context-watcher.sh"
log_success "Created context-watcher.sh (Issue #13572 workaround)"

#===============================================================================
# HEADLESS AGENT SPAWNER (Simplified)
#===============================================================================
cat > "$SCRIPTS_DIR/spawn-agent.sh" << 'SPAWNSCRIPT'
#!/bin/bash
# Spawn a headless Claude Code agent
# Usage: spawn-agent.sh <task-prompt> [working-dir]

SCRIPT_DIR="$HOME/.claude/scripts"
[ -d "$HOME/.config/claude/scripts" ] && SCRIPT_DIR="$HOME/.config/claude/scripts"

TASK_PROMPT="$1"
WORK_DIR="${2:-$(pwd)}"
LOG_DIR="$HOME/.claude/agent-logs"
[ -d "$HOME/.config/claude/agent-logs" ] && LOG_DIR="$HOME/.config/claude/agent-logs"

mkdir -p "$LOG_DIR"

if [ -z "$TASK_PROMPT" ]; then
    echo "Usage: spawn-agent.sh <task-prompt> [working-dir]"
    exit 1
fi

SESSION_ID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || date +%s%N)
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# Record task start
TASK_RESULT=$(python3 "$SCRIPT_DIR/hivemind-db.py" task-start "$TASK_PROMPT" 2>/dev/null)
TASK_ID=$(echo "$TASK_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('task_id',''))" 2>/dev/null)

cd "$WORK_DIR"

# IMPORTANT: Set HIVEMIND_HOOK_ACTIVE to prevent hook recursion
# This is the correct isolation method (not the fake disableAllHooks)
export HIVEMIND_HOOK_ACTIVE=true

nohup claude -p "$TASK_PROMPT" \
    --output-format stream-json \
    --allowedTools "Read,Write,Edit,Bash,Grep,Glob" \
    > "$LOG_DIR/agent-${TIMESTAMP}.log" 2>&1 &

AGENT_PID=$!
echo "$AGENT_PID" > "$LOG_DIR/agent-${TIMESTAMP}.pid"

# Complete task when agent finishes
(
    wait $AGENT_PID 2>/dev/null
    [ -n "$TASK_ID" ] && python3 "$SCRIPT_DIR/hivemind-db.py" task-complete "$TASK_ID" "completed" 2>/dev/null
) &

echo "{\"pid\": $AGENT_PID, \"task_id\": \"$TASK_ID\", \"log\": \"$LOG_DIR/agent-${TIMESTAMP}.log\"}"
SPAWNSCRIPT

chmod +x "$SCRIPTS_DIR/spawn-agent.sh"
log_success "Created spawn-agent.sh"

#===============================================================================
# HIVEMIND CLI
#===============================================================================
cat > "$SCRIPTS_DIR/hivemind.sh" << 'HIVESCRIPT'
#!/bin/bash
# Hivemind CLI - orchestrate agents and manage state

SCRIPT_DIR="$HOME/.claude/scripts"
[ -d "$HOME/.config/claude/scripts" ] && SCRIPT_DIR="$HOME/.config/claude/scripts"

LOG_DIR="$HOME/.claude/agent-logs"
[ -d "$HOME/.config/claude/agent-logs" ] && LOG_DIR="$HOME/.config/claude/agent-logs"

case "$1" in
    spawn)
        "$SCRIPT_DIR/spawn-agent.sh" "$2" "$3"
        ;;
    status)
        python3 "$SCRIPT_DIR/hivemind-db.py" task-list
        ;;
    dump)
        python3 "$SCRIPT_DIR/hivemind-db.py" dump
        ;;
    set)
        python3 "$SCRIPT_DIR/hivemind-db.py" set "$2" "$3" "$4"
        ;;
    get)
        python3 "$SCRIPT_DIR/hivemind-db.py" get "$2"
        ;;
    learn)
        python3 "$SCRIPT_DIR/hivemind-db.py" learning-add "$2" "$3"
        ;;
    state)
        python3 "$SCRIPT_DIR/hivemind-db.py" state-set "$2" "$3"
        ;;
    snapshot)
        python3 "$SCRIPT_DIR/hivemind-db.py" snapshot-save "$2"
        ;;
    logs)
        ls -lt "$LOG_DIR"/*.log 2>/dev/null | head -10
        ;;
    tail)
        LATEST=$(ls -t "$LOG_DIR"/*.log 2>/dev/null | head -1)
        [ -n "$LATEST" ] && tail -f "$LATEST" || echo "No logs found"
        ;;
    watcher-start)
        nohup "$SCRIPT_DIR/context-watcher.sh" > /tmp/hivemind-watcher.log 2>&1 &
        echo "Context watcher started (PID: $!)"
        ;;
    watcher-stop)
        pkill -f "context-watcher.sh"
        echo "Context watcher stopped"
        ;;
    help|*)
        echo "Hivemind CLI - Claude Code multi-agent orchestration"
        echo ""
        echo "Commands:"
        echo "  spawn <task> [dir]     Spawn headless agent"
        echo "  status                 List recent tasks"
        echo "  dump                   Dump full database state"
        echo "  set <key> <val> [cat]  Store memory"
        echo "  get <key>              Retrieve memory"
        echo "  learn <type> <content> Record a learning"
        echo "  state <key> <val>      Set project state"
        echo "  snapshot <name>        Save context snapshot"
        echo "  logs                   List agent logs"
        echo "  tail                   Tail latest agent log"
        echo "  watcher-start          Start context watcher"
        echo "  watcher-stop           Stop context watcher"
        ;;
esac
HIVESCRIPT

chmod +x "$SCRIPTS_DIR/hivemind.sh"
log_success "Created hivemind.sh CLI"

#===============================================================================
# SETTINGS.JSON - Verified hook configuration
#===============================================================================
SETTINGS_FILE="$CLAUDE_DIR/settings.json"

# Backup existing settings
if [ -f "$SETTINGS_FILE" ]; then
    cp "$SETTINGS_FILE" "$SETTINGS_FILE.backup.$(date +%Y%m%d-%H%M%S)"
    log_info "Backed up existing settings.json"
fi

cat > "$SETTINGS_FILE" << SETTINGS_JSON
{
  "permissions": {
    "allow": [
      "Read(*)", "Grep(*)", "Glob(*)",
      "Bash(python3 ~/.claude/scripts/*)",
      "Bash(python3 ~/.config/claude/scripts/*)",
      "Bash(~/.claude/scripts/*)",
      "Bash(~/.config/claude/scripts/*)",
      "Bash(git status)", "Bash(git diff*)", "Bash(git log*)", "Bash(git branch*)",
      "Bash(ls*)", "Bash(cat*)", "Bash(head*)", "Bash(tail*)", "Bash(find*)",
      "Bash(file*)", "Bash(sed*)", "Bash(date*)", "Bash(mkdir*)"
    ],
    "deny": ["Bash(rm -rf /)", "Bash(rm -rf ~)", "Bash(:(){ :|:& };:)"]
  },
  "hooks": {
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [{
          "type": "command",
          "command": "$HOOKS_DIR/inject-context.sh",
          "timeout": 5
        }]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [{
          "type": "command",
          "command": "$HOOKS_DIR/crlf-fix.sh",
          "timeout": 5
        }]
      }
    ],
    "SubagentStop": [
      {
        "matcher": "",
        "hooks": [{
          "type": "command",
          "command": "$HOOKS_DIR/subagent-complete.sh",
          "timeout": 10
        }]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [{
          "type": "command",
          "command": "$HOOKS_DIR/update-plan.sh",
          "timeout": 15
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

log_success "Created settings.json with hooks"

#===============================================================================
# GLOBAL CLAUDE.MD
# NOTE: No @ imports - they're broken per Issue #1041
#===============================================================================
cat > "$CLAUDE_DIR/CLAUDE.md" << 'GLOBAL_CLAUDE'
# Claude Code Hivemind V3

## Automatic Persistence

This system provides cross-session memory via SQLite database and hooks.

**Active Hooks:**
- **UserPromptSubmit**: Injects database state into each prompt
- **PostToolUse:Write**: Fixes CRLF line endings on Linux
- **SubagentStop**: Records task completion
- **Stop**: Exports learnings to project CLAUDE.md

## Commands

Record learnings (auto-exported on stop):
```bash
~/.claude/scripts/hivemind.sh learn decision "Why we chose X over Y"
~/.claude/scripts/hivemind.sh learn pattern "Always verify before..."
~/.claude/scripts/hivemind.sh learn bug "Issue when X happens"
```

Store persistent memory:
```bash
~/.claude/scripts/hivemind.sh set findings "API uses OAuth2" research
~/.claude/scripts/hivemind.sh get findings
```

Track project state:
```bash
~/.claude/scripts/hivemind.sh state current_phase "implementation"
~/.claude/scripts/hivemind.sh state blockers "awaiting API key"
```

Spawn background agent:
```bash
~/.claude/scripts/hivemind.sh spawn "Analyze the error logs"
~/.claude/scripts/hivemind.sh status
~/.claude/scripts/hivemind.sh tail
```

## Context Preservation

The context watcher monitors for high context usage (since PreCompact hooks are broken):
```bash
~/.claude/scripts/hivemind.sh watcher-start
~/.claude/scripts/hivemind.sh watcher-stop
```

## Known Limitations

1. PreCompact hooks don't fire (Issue #13572) - use context watcher
2. SessionStart unreliable for new sessions (Issue #10373) - use UserPromptSubmit
3. @ imports fail in this file (Issue #1041) - instructions embedded directly
4. SubagentStop can't identify specific agent (Issue #7881)
GLOBAL_CLAUDE

log_success "Created global CLAUDE.md"

#===============================================================================
# INITIALIZE DATABASE
#===============================================================================
python3 "$SCRIPTS_DIR/hivemind-db.py" init

#===============================================================================
# VERIFY INSTALLATION
#===============================================================================
echo ""
echo "================================================================"
echo -e "${GREEN}Claude Code Hivemind V3 Installation Complete${NC}"
echo "================================================================"
echo ""
echo "Configuration directory: $CLAUDE_DIR"
echo ""
echo "V3 VERIFIED WORKAROUNDS:"
echo "  ✓ UserPromptSubmit hook (instead of broken SessionStart)"
echo "  ✓ PostToolUse CRLF fix (Issue #2805)"
echo "  ✓ Context watcher (instead of broken PreCompact)"
echo "  ✓ Environment variable hook isolation (HIVEMIND_HOOK_ACTIVE)"
echo "  ✓ No @ imports in global CLAUDE.md (Issue #1041)"
echo ""
echo "NEXT STEPS:"
echo "  1. Start Claude Code: claude"
echo "  2. Check hooks are loaded: /hooks"
echo "  3. Optional - start context watcher:"
echo "     ~/.claude/scripts/hivemind.sh watcher-start"
echo ""
echo "TEST COMMANDS:"
echo "  ~/.claude/scripts/hivemind.sh set test_key 'hello world' testing"
echo "  ~/.claude/scripts/hivemind.sh get test_key"
echo "  ~/.claude/scripts/hivemind.sh learn decision 'Test learning'"
echo "  ~/.claude/scripts/hivemind.sh dump"
echo ""
echo "================================================================"
