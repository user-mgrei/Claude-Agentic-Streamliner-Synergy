#!/bin/bash
#===============================================================================
# Claude Code Hivemind Setup Script V2
# 
# CHANGES FROM V1:
#   - Added PreCompact hook (auto + manual) to save memory before context loss
#   - Fixed SessionStart hook to use correct hookSpecificOutput.additionalContext format
#   - Added project CLAUDE.md auto-update mechanism via Stop hook
#   - DB init is now deterministic via hook, not just prompt instruction
#   - Added @ import syntax in global CLAUDE.md for modular configs
#   - Added SessionEnd hook for cleanup/logging
#   - Improved error handling throughout
#
# Verified against: code.claude.com/docs/en/hooks (December 2025)
#                   code.claude.com/docs/en/memory (December 2025)
#
# For Arch Linux with yay-installed claude-code
# Run once: chmod +x setup-claude-hivemind-v2.sh && ./setup-claude-hivemind-v2.sh
#===============================================================================

set -e

CLAUDE_DIR="$HOME/.claude"
AGENTS_DIR="$CLAUDE_DIR/agents"
COMMANDS_DIR="$CLAUDE_DIR/commands"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SCRIPTS_DIR="$CLAUDE_DIR/scripts"
RULES_DIR="$CLAUDE_DIR/rules"
MEMORY_DIR="$CLAUDE_DIR/memory"

echo "==> Setting up Claude Code Hivemind V2 configuration..."

# Create directory structure
mkdir -p "$AGENTS_DIR" "$COMMANDS_DIR" "$HOOKS_DIR" "$SCRIPTS_DIR" "$RULES_DIR" "$MEMORY_DIR"

#===============================================================================
# SQLITE MEMORY MANAGEMENT SCRIPT (Enhanced)
#===============================================================================
cat > "$SCRIPTS_DIR/memory-db.py" << 'MEMORY_SCRIPT'
#!/usr/bin/env python3
"""
Claude Code SQLite Memory Manager V2
Provides persistent memory storage between phases/sessions.
Database location: $PROJECT_DIR/.claude/claude.db (project) or ~/.claude/claude.db (global)

Enhanced in V2:
  - compact-summary command for pre-compact context preservation
  - learnings-export for project CLAUDE.md updates
  - Better error handling and JSON output
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
    project_db = Path(project_dir) / '.claude' / 'claude.db'
    global_db = Path.home() / '.claude' / 'claude.db'
    
    # If in a project with .claude dir, use project db
    if (Path(project_dir) / '.claude').exists():
        return project_db
    return global_db

def init_db(conn):
    """Initialize database schema"""
    conn.executescript('''
        CREATE TABLE IF NOT EXISTS memory (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            key TEXT UNIQUE NOT NULL,
            value TEXT NOT NULL,
            category TEXT DEFAULT 'general',
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
        
        CREATE TABLE IF NOT EXISTS phases (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            phase_name TEXT NOT NULL,
            status TEXT DEFAULT 'pending',
            context TEXT,
            started_at TIMESTAMP,
            completed_at TIMESTAMP,
            parent_phase_id INTEGER,
            FOREIGN KEY (parent_phase_id) REFERENCES phases(id)
        );
        
        CREATE TABLE IF NOT EXISTS agents (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            agent_name TEXT UNIQUE NOT NULL,
            agent_type TEXT DEFAULT 'subagent',
            status TEXT DEFAULT 'idle',
            current_task TEXT,
            session_id TEXT,
            spawned_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            last_active TIMESTAMP
        );
        
        CREATE TABLE IF NOT EXISTS tasks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            task_description TEXT NOT NULL,
            assigned_agent TEXT,
            status TEXT DEFAULT 'queued',
            priority INTEGER DEFAULT 5,
            result TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            started_at TIMESTAMP,
            completed_at TIMESTAMP
        );
        
        CREATE TABLE IF NOT EXISTS context_snapshots (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            snapshot_name TEXT NOT NULL,
            snapshot_type TEXT DEFAULT 'manual',
            context_data TEXT NOT NULL,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
        
        CREATE TABLE IF NOT EXISTS learnings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            learning_type TEXT NOT NULL,
            content TEXT NOT NULL,
            source_phase INTEGER,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            exported INTEGER DEFAULT 0,
            FOREIGN KEY (source_phase) REFERENCES phases(id)
        );
        
        CREATE TABLE IF NOT EXISTS compaction_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            trigger_type TEXT NOT NULL,
            summary TEXT NOT NULL,
            memories_count INTEGER,
            phases_count INTEGER,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
        
        CREATE INDEX IF NOT EXISTS idx_memory_key ON memory(key);
        CREATE INDEX IF NOT EXISTS idx_memory_category ON memory(category);
        CREATE INDEX IF NOT EXISTS idx_phases_status ON phases(status);
        CREATE INDEX IF NOT EXISTS idx_agents_status ON agents(status);
        CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
        CREATE INDEX IF NOT EXISTS idx_learnings_exported ON learnings(exported);
        CREATE INDEX IF NOT EXISTS idx_snapshots_type ON context_snapshots(snapshot_type);
    ''')
    conn.commit()

def ensure_db():
    """Ensure database exists and is initialized"""
    db_path = get_db_path()
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(db_path))
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
                VALUES (?, ?, ?, CURRENT_TIMESTAMP)
                ON CONFLICT(key) DO UPDATE SET 
                    value=excluded.value, 
                    category=excluded.category,
                    updated_at=CURRENT_TIMESTAMP
            ''', (key, value, category))
            conn.commit()
            print(json.dumps({"status": "set", "key": key}))
        
        elif cmd == "get":
            if len(sys.argv) < 3:
                print(json.dumps({"error": "Usage: get <key>"}))
                sys.exit(1)
            key = sys.argv[2]
            cursor.execute('SELECT value, category, updated_at FROM memory WHERE key = ?', (key,))
            row = cursor.fetchone()
            if row:
                print(json.dumps({"key": key, "value": row[0], "category": row[1], "updated_at": row[2]}))
            else:
                print(json.dumps({"key": key, "value": None}))
        
        elif cmd == "list":
            category = sys.argv[2] if len(sys.argv) > 2 else None
            if category:
                cursor.execute('SELECT key, value, category FROM memory WHERE category = ?', (category,))
            else:
                cursor.execute('SELECT key, value, category FROM memory')
            rows = cursor.fetchall()
            print(json.dumps({"memories": [{"key": r[0], "value": r[1], "category": r[2]} for r in rows]}))
        
        elif cmd == "phase-start":
            if len(sys.argv) < 3:
                print(json.dumps({"error": "Usage: phase-start <name> [context] [parent_id]"}))
                sys.exit(1)
            phase_name = sys.argv[2]
            context = sys.argv[3] if len(sys.argv) > 3 else None
            parent_id = int(sys.argv[4]) if len(sys.argv) > 4 else None
            cursor.execute('''
                INSERT INTO phases (phase_name, status, context, started_at, parent_phase_id)
                VALUES (?, 'active', ?, CURRENT_TIMESTAMP, ?)
            ''', (phase_name, context, parent_id))
            conn.commit()
            print(json.dumps({"status": "phase_started", "phase_id": cursor.lastrowid, "phase_name": phase_name}))
        
        elif cmd == "phase-complete":
            if len(sys.argv) < 3:
                print(json.dumps({"error": "Usage: phase-complete <phase_id>"}))
                sys.exit(1)
            phase_id = int(sys.argv[2])
            cursor.execute('''
                UPDATE phases SET status = 'completed', completed_at = CURRENT_TIMESTAMP
                WHERE id = ?
            ''', (phase_id,))
            conn.commit()
            print(json.dumps({"status": "phase_completed", "phase_id": phase_id}))
        
        elif cmd == "phase-list":
            cursor.execute('SELECT id, phase_name, status, context, started_at, completed_at FROM phases ORDER BY id DESC LIMIT 20')
            rows = cursor.fetchall()
            print(json.dumps({"phases": [
                {"id": r[0], "name": r[1], "status": r[2], "context": r[3], "started": r[4], "completed": r[5]} 
                for r in rows
            ]}))
        
        elif cmd == "agent-register":
            if len(sys.argv) < 3:
                print(json.dumps({"error": "Usage: agent-register <name> [type]"}))
                sys.exit(1)
            agent_name = sys.argv[2]
            agent_type = sys.argv[3] if len(sys.argv) > 3 else 'subagent'
            cursor.execute('''
                INSERT INTO agents (agent_name, agent_type, status, spawned_at)
                VALUES (?, ?, 'idle', CURRENT_TIMESTAMP)
                ON CONFLICT(agent_name) DO UPDATE SET 
                    status='idle', 
                    last_active=CURRENT_TIMESTAMP
            ''', (agent_name, agent_type))
            conn.commit()
            print(json.dumps({"status": "registered", "agent": agent_name}))
        
        elif cmd == "agent-status":
            if len(sys.argv) < 4:
                print(json.dumps({"error": "Usage: agent-status <name> <status> [task] [session_id]"}))
                sys.exit(1)
            agent_name = sys.argv[2]
            status = sys.argv[3]
            task = sys.argv[4] if len(sys.argv) > 4 else None
            session_id = sys.argv[5] if len(sys.argv) > 5 else None
            cursor.execute('''
                UPDATE agents SET status = ?, current_task = ?, session_id = ?, last_active = CURRENT_TIMESTAMP
                WHERE agent_name = ?
            ''', (status, task, session_id, agent_name))
            conn.commit()
            print(json.dumps({"status": "updated", "agent": agent_name}))
        
        elif cmd == "agent-list":
            cursor.execute('SELECT agent_name, agent_type, status, current_task, session_id, last_active FROM agents')
            rows = cursor.fetchall()
            print(json.dumps({"agents": [
                {"name": r[0], "type": r[1], "status": r[2], "task": r[3], "session": r[4], "last_active": r[5]}
                for r in rows
            ]}))
        
        elif cmd == "task-add":
            if len(sys.argv) < 3:
                print(json.dumps({"error": "Usage: task-add <description> [priority]"}))
                sys.exit(1)
            desc = sys.argv[2]
            priority = int(sys.argv[3]) if len(sys.argv) > 3 else 5
            cursor.execute('''
                INSERT INTO tasks (task_description, priority, status)
                VALUES (?, ?, 'queued')
            ''', (desc, priority))
            conn.commit()
            print(json.dumps({"status": "added", "task_id": cursor.lastrowid}))
        
        elif cmd == "task-assign":
            if len(sys.argv) < 4:
                print(json.dumps({"error": "Usage: task-assign <task_id> <agent_name>"}))
                sys.exit(1)
            task_id = int(sys.argv[2])
            agent_name = sys.argv[3]
            cursor.execute('''
                UPDATE tasks SET assigned_agent = ?, status = 'assigned', started_at = CURRENT_TIMESTAMP
                WHERE id = ?
            ''', (agent_name, task_id))
            conn.commit()
            print(json.dumps({"status": "assigned", "task_id": task_id, "agent": agent_name}))
        
        elif cmd == "task-complete":
            if len(sys.argv) < 3:
                print(json.dumps({"error": "Usage: task-complete <task_id> [result]"}))
                sys.exit(1)
            task_id = int(sys.argv[2])
            result = sys.argv[3] if len(sys.argv) > 3 else None
            cursor.execute('''
                UPDATE tasks SET status = 'completed', result = ?, completed_at = CURRENT_TIMESTAMP
                WHERE id = ?
            ''', (result, task_id))
            conn.commit()
            print(json.dumps({"status": "completed", "task_id": task_id}))
        
        elif cmd == "task-queue":
            cursor.execute('''
                SELECT id, task_description, assigned_agent, status, priority 
                FROM tasks WHERE status IN ('queued', 'assigned') 
                ORDER BY priority DESC, created_at ASC
            ''')
            rows = cursor.fetchall()
            print(json.dumps({"queue": [
                {"id": r[0], "desc": r[1], "agent": r[2], "status": r[3], "priority": r[4]}
                for r in rows
            ]}))
        
        elif cmd == "snapshot-save":
            if len(sys.argv) < 3:
                print(json.dumps({"error": "Usage: snapshot-save <name> [data] [type]"}))
                sys.exit(1)
            name = sys.argv[2]
            context_data = sys.stdin.read() if not sys.stdin.isatty() else sys.argv[3] if len(sys.argv) > 3 else '{}'
            snapshot_type = sys.argv[4] if len(sys.argv) > 4 else 'manual'
            cursor.execute('''
                INSERT INTO context_snapshots (snapshot_name, snapshot_type, context_data)
                VALUES (?, ?, ?)
            ''', (name, snapshot_type, context_data))
            conn.commit()
            print(json.dumps({"status": "saved", "snapshot_id": cursor.lastrowid, "name": name}))
        
        elif cmd == "snapshot-load":
            if len(sys.argv) < 3:
                print(json.dumps({"error": "Usage: snapshot-load <name>"}))
                sys.exit(1)
            name = sys.argv[2]
            cursor.execute('SELECT context_data, created_at FROM context_snapshots WHERE snapshot_name = ? ORDER BY id DESC LIMIT 1', (name,))
            row = cursor.fetchone()
            if row:
                print(row[0])
            else:
                print(json.dumps({"error": "snapshot not found"}))
        
        elif cmd == "learning-add":
            if len(sys.argv) < 4:
                print(json.dumps({"error": "Usage: learning-add <type> <content> [phase_id]"}))
                sys.exit(1)
            learning_type = sys.argv[2]
            content = sys.argv[3]
            phase_id = int(sys.argv[4]) if len(sys.argv) > 4 else None
            cursor.execute('''
                INSERT INTO learnings (learning_type, content, source_phase)
                VALUES (?, ?, ?)
            ''', (learning_type, content, phase_id))
            conn.commit()
            print(json.dumps({"status": "added", "learning_id": cursor.lastrowid}))
        
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
                {"id": r[0], "type": r[1], "content": r[2], "created_at": r[3]}
                for r in rows
            ]}))
        
        elif cmd == "compact-summary":
            trigger = sys.argv[2] if len(sys.argv) > 2 else 'auto'
            
            cursor.execute('SELECT key, value, category FROM memory')
            memories = cursor.fetchall()
            cursor.execute('SELECT id, phase_name, status, context FROM phases WHERE status = "active"')
            active_phases = cursor.fetchall()
            cursor.execute('SELECT agent_name, status, current_task FROM agents WHERE status NOT IN ("idle", "completed")')
            active_agents = cursor.fetchall()
            cursor.execute('SELECT id, task_description, status FROM tasks WHERE status IN ("queued", "assigned")')
            pending_tasks = cursor.fetchall()
            
            summary = {
                "trigger": trigger,
                "timestamp": datetime.now().isoformat(),
                "memories": {r[0]: {"value": r[1], "category": r[2]} for r in memories},
                "active_phases": [{"id": r[0], "name": r[1], "status": r[2], "context": r[3]} for r in active_phases],
                "active_agents": [{"name": r[0], "status": r[1], "task": r[2]} for r in active_agents],
                "pending_tasks": [{"id": r[0], "desc": r[1], "status": r[2]} for r in pending_tasks]
            }
            
            cursor.execute('''
                INSERT INTO compaction_log (trigger_type, summary, memories_count, phases_count)
                VALUES (?, ?, ?, ?)
            ''', (trigger, json.dumps(summary), len(memories), len(active_phases)))
            
            cursor.execute('''
                INSERT INTO context_snapshots (snapshot_name, snapshot_type, context_data)
                VALUES (?, ?, ?)
            ''', (f"pre-compact-{datetime.now().strftime('%Y%m%d-%H%M%S')}", f"pre-compact-{trigger}", json.dumps(summary)))
            
            conn.commit()
            print(json.dumps(summary, indent=2))
        
        elif cmd == "dump":
            cursor.execute('SELECT key, value, category FROM memory')
            memories = cursor.fetchall()
            cursor.execute('SELECT id, phase_name, status FROM phases WHERE status = "active"')
            active_phases = cursor.fetchall()
            cursor.execute('SELECT agent_name, status, current_task FROM agents WHERE status != "idle"')
            active_agents = cursor.fetchall()
            cursor.execute('SELECT id, task_description, status FROM tasks WHERE status IN ("queued", "assigned") LIMIT 10')
            pending_tasks = cursor.fetchall()
            
            print(json.dumps({
                "memories": {r[0]: {"value": r[1], "category": r[2]} for r in memories},
                "active_phases": [{"id": r[0], "name": r[1], "status": r[2]} for r in active_phases],
                "active_agents": [{"name": r[0], "status": r[1], "task": r[2]} for r in active_agents],
                "pending_tasks": [{"id": r[0], "desc": r[1], "status": r[2]} for r in pending_tasks]
            }, indent=2))
        
        elif cmd == "dump-compact":
            cursor.execute('SELECT key, value FROM memory ORDER BY updated_at DESC LIMIT 50')
            memories = cursor.fetchall()
            cursor.execute('SELECT phase_name, status FROM phases WHERE status = "active"')
            active_phases = cursor.fetchall()
            
            output = []
            if memories:
                output.append("MEMORY:")
                for k, v in memories:
                    v_short = v[:200] + "..." if len(v) > 200 else v
                    output.append(f"  {k}: {v_short}")
            if active_phases:
                output.append("ACTIVE PHASES:")
                for name, status in active_phases:
                    output.append(f"  - {name} ({status})")
            
            print("\n".join(output) if output else "No memory state")
        
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
# HEADLESS AGENT SPAWNER SCRIPT
#===============================================================================
cat > "$SCRIPTS_DIR/spawn-agent.sh" << 'SPAWN_SCRIPT'
#!/bin/bash
# Spawn a headless Claude Code agent for background task execution
# Usage: spawn-agent.sh <agent-name> <task-prompt> [working-dir]

AGENT_NAME="${1:-worker}"
TASK_PROMPT="$2"
WORK_DIR="${3:-$(pwd)}"
MEMORY_SCRIPT="$HOME/.claude/scripts/memory-db.py"
LOG_DIR="$HOME/.claude/agent-logs"

mkdir -p "$LOG_DIR"

if [ -z "$TASK_PROMPT" ]; then
    echo "Usage: spawn-agent.sh <agent-name> <task-prompt> [working-dir]"
    exit 1
fi

SESSION_ID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || date +%s%N)
python3 "$MEMORY_SCRIPT" agent-register "$AGENT_NAME" "headless" 2>/dev/null
python3 "$MEMORY_SCRIPT" agent-status "$AGENT_NAME" "running" "$TASK_PROMPT" "$SESSION_ID" 2>/dev/null

cd "$WORK_DIR"
nohup claude -p "$TASK_PROMPT" \
    --output-format stream-json \
    --allowedTools "Read,Write,Edit,Bash,Grep,Glob" \
    > "$LOG_DIR/${AGENT_NAME}-${SESSION_ID}.log" 2>&1 &

AGENT_PID=$!
echo "$AGENT_PID" > "$LOG_DIR/${AGENT_NAME}.pid"

echo "{\"agent\": \"$AGENT_NAME\", \"session_id\": \"$SESSION_ID\", \"pid\": $AGENT_PID, \"log\": \"$LOG_DIR/${AGENT_NAME}-${SESSION_ID}.log\"}"

(
    wait $AGENT_PID 2>/dev/null
    python3 "$MEMORY_SCRIPT" agent-status "$AGENT_NAME" "completed" "" "$SESSION_ID" 2>/dev/null
) &
SPAWN_SCRIPT

chmod +x "$SCRIPTS_DIR/spawn-agent.sh"

#===============================================================================
# HIVEMIND ORCHESTRATOR SCRIPT
#===============================================================================
cat > "$SCRIPTS_DIR/hivemind.sh" << 'HIVEMIND_SCRIPT'
#!/bin/bash
MEMORY_SCRIPT="$HOME/.claude/scripts/memory-db.py"
SPAWN_SCRIPT="$HOME/.claude/scripts/spawn-agent.sh"
LOG_DIR="$HOME/.claude/agent-logs"

case "$1" in
    spawn) "$SPAWN_SCRIPT" "$2" "$3" "$4" ;;
    status) python3 "$MEMORY_SCRIPT" agent-list ;;
    tasks) python3 "$MEMORY_SCRIPT" task-queue ;;
    add-task) python3 "$MEMORY_SCRIPT" task-add "$2" "${3:-5}" ;;
    assign) python3 "$MEMORY_SCRIPT" task-assign "$2" "$3" ;;
    complete) python3 "$MEMORY_SCRIPT" task-complete "$2" "$3" ;;
    logs) ls -la "$LOG_DIR"/${2:-*}*.log 2>/dev/null || echo "No logs" ;;
    tail) [ -n "$2" ] && { LATEST=$(ls -t "$LOG_DIR"/${2}*.log 2>/dev/null | head -1); [ -n "$LATEST" ] && tail -f "$LATEST"; } || echo "Usage: tail <agent>" ;;
    kill) [ -f "$LOG_DIR/${2}.pid" ] && { kill $(cat "$LOG_DIR/${2}.pid") 2>/dev/null; python3 "$MEMORY_SCRIPT" agent-status "$2" "killed" "" ""; rm "$LOG_DIR/${2}.pid"; } ;;
    killall) for p in "$LOG_DIR"/*.pid; do [ -f "$p" ] && { kill $(cat "$p") 2>/dev/null; rm "$p"; }; done ;;
    swarm) for i in $(seq 1 ${2:-3}); do "$SPAWN_SCRIPT" "swarm-$i" "$3 (Worker $i)"; sleep 1; done ;;
    *) echo "Commands: spawn|status|tasks|add-task|assign|complete|logs|tail|kill|killall|swarm" ;;
esac
HIVEMIND_SCRIPT

chmod +x "$SCRIPTS_DIR/hivemind.sh"

#===============================================================================
# SESSION START HOOK - V2: Correct hookSpecificOutput format
# Verified: code.claude.com/docs/en/hooks#sessionstart-decision-control
#===============================================================================
cat > "$HOOKS_DIR/session-start.sh" << 'SESSION_HOOK'
#!/bin/bash
MEMORY_SCRIPT="$HOME/.claude/scripts/memory-db.py"

# DETERMINISTIC: Always init DB
python3 "$MEMORY_SCRIPT" init >/dev/null 2>&1

# Get compact memory for context
CONTEXT=$(python3 "$MEMORY_SCRIPT" dump-compact 2>/dev/null)

# Output hookSpecificOutput.additionalContext format per docs
if [ -n "$CONTEXT" ] && [ "$CONTEXT" != "No memory state" ]; then
    # Escape for JSON
    CONTEXT_ESCAPED=$(echo "$CONTEXT" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')
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
# PRE-COMPACT HOOK - NEW IN V2
# Verified: code.claude.com/docs/en/hooks#precompact
#===============================================================================
cat > "$HOOKS_DIR/pre-compact.sh" << 'PRECOMPACT_HOOK'
#!/bin/bash
MEMORY_SCRIPT="$HOME/.claude/scripts/memory-db.py"
BACKUP_DIR="$HOME/.claude/memory/compact-backups"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

mkdir -p "$BACKUP_DIR"

# Get trigger type from stdin
INPUT=$(cat)
TRIGGER=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('trigger','unknown'))" 2>/dev/null || echo "unknown")

# Save state before compaction
python3 "$MEMORY_SCRIPT" compact-summary "$TRIGGER" > "$BACKUP_DIR/pre-compact-$TIMESTAMP.json" 2>/dev/null

echo "Memory saved before $TRIGGER compaction" >&2
exit 0
PRECOMPACT_HOOK

chmod +x "$HOOKS_DIR/pre-compact.sh"

#===============================================================================
# STOP HOOK - V2: Exports learnings to project CLAUDE.md
#===============================================================================
cat > "$HOOKS_DIR/stop-autosave.sh" << 'STOP_HOOK'
#!/bin/bash
MEMORY_SCRIPT="$HOME/.claude/scripts/memory-db.py"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# Check stop_hook_active to prevent loops
INPUT=$(cat)
ACTIVE=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('stop_hook_active', False))" 2>/dev/null || echo "False")
[ "$ACTIVE" = "True" ] && exit 0

# Save snapshot
python3 "$MEMORY_SCRIPT" snapshot-save "auto-$TIMESTAMP" '{}' "auto-stop" 2>/dev/null

# Export learnings to project CLAUDE.md
LEARNINGS=$(python3 "$MEMORY_SCRIPT" learnings-export 2>/dev/null)
COUNT=$(echo "$LEARNINGS" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('learnings',[])))" 2>/dev/null || echo "0")

if [ "$COUNT" -gt 0 ] && [ -d "$PROJECT_DIR/.claude" ]; then
    PROJECT_CLAUDE="$PROJECT_DIR/.claude/CLAUDE.md"
    [ ! -f "$PROJECT_CLAUDE" ] && echo -e "# Project Memory\n\n## Session Learnings" > "$PROJECT_CLAUDE"
    echo -e "\n### Session $TIMESTAMP" >> "$PROJECT_CLAUDE"
    echo "$LEARNINGS" | python3 -c "
import sys, json
for l in json.load(sys.stdin).get('learnings', []):
    print(f\"- [{l['type']}] {l['content']}\")" >> "$PROJECT_CLAUDE" 2>/dev/null
fi

exit 0
STOP_HOOK

chmod +x "$HOOKS_DIR/stop-autosave.sh"

#===============================================================================
# SESSION END HOOK
#===============================================================================
cat > "$HOOKS_DIR/session-end.sh" << 'SESSION_END_HOOK'
#!/bin/bash
MEMORY_SCRIPT="$HOME/.claude/scripts/memory-db.py"
LOG_FILE="$HOME/.claude/session-log.txt"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id','?'))" 2>/dev/null || echo "?")
REASON=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('reason','?'))" 2>/dev/null || echo "?")

echo "[$TIMESTAMP] Session $SESSION_ID ended: $REASON" >> "$LOG_FILE"
python3 "$MEMORY_SCRIPT" snapshot-save "session-end-$TIMESTAMP" '{}' "session-end" 2>/dev/null
exit 0
SESSION_END_HOOK

chmod +x "$HOOKS_DIR/session-end.sh"

#===============================================================================
# SETTINGS.JSON - V2
#===============================================================================
cat > "$CLAUDE_DIR/settings.json" << 'SETTINGS_JSON'
{
  "permissions": {
    "allow": [
      "Read(*)", "Grep(*)", "Glob(*)",
      "Bash(python3 ~/.claude/scripts/*)",
      "Bash(~/.claude/scripts/*)",
      "Bash(git status)", "Bash(git diff*)", "Bash(git log*)", "Bash(git branch*)",
      "Bash(ls*)", "Bash(cat*)", "Bash(head*)", "Bash(tail*)", "Bash(find*)",
      "Bash(uuidgen)", "Bash(date*)", "Bash(mkdir*)"
    ],
    "deny": ["Bash(rm -rf /)", "Bash(rm -rf ~)", "Bash(:(){ :|:& };:)"]
  },
  "hooks": {
    "SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "~/.claude/hooks/session-start.sh", "timeout": 10}]}],
    "PreCompact": [
      {"matcher": "auto", "hooks": [{"type": "command", "command": "~/.claude/hooks/pre-compact.sh", "timeout": 30}]},
      {"matcher": "manual", "hooks": [{"type": "command", "command": "~/.claude/hooks/pre-compact.sh", "timeout": 30}]}
    ],
    "Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "~/.claude/hooks/stop-autosave.sh", "timeout": 15}]}],
    "SessionEnd": [{"matcher": "", "hooks": [{"type": "command", "command": "~/.claude/hooks/session-end.sh", "timeout": 10}]}]
  },
  "env": {"CLAUDE_HIVEMIND_ENABLED": "1", "PYTHONUNBUFFERED": "1"}
}
SETTINGS_JSON

#===============================================================================
# MODULAR MEMORY FILES
#===============================================================================
cat > "$MEMORY_DIR/commands.md" << 'EOF'
# Memory Commands
```bash
# Core
memory-db.py set <key> <value> [category]
memory-db.py get <key>
memory-db.py list [category]
memory-db.py dump

# Phases
memory-db.py phase-start "Name" "{}" [parent_id]
memory-db.py phase-complete <id>

# Learnings (auto-export to project CLAUDE.md)
memory-db.py learning-add <type> "<content>"
# Types: decision, pattern, convention, bug, optimization

# Snapshots
memory-db.py snapshot-save "name"
memory-db.py snapshot-load "name"
```
EOF

cat > "$MEMORY_DIR/hivemind.md" << 'EOF'
# Hivemind Commands
```bash
hivemind.sh spawn <name> "<task>" [dir]
hivemind.sh status
hivemind.sh swarm <num> "<task>"
hivemind.sh tail <agent>
hivemind.sh kill <agent>
hivemind.sh killall

# Task queue
hivemind.sh add-task "<desc>" [priority]
hivemind.sh tasks
hivemind.sh assign <task-id> <agent>
hivemind.sh complete <task-id> "<result>"
```
EOF

#===============================================================================
# GLOBAL CLAUDE.MD - V2 with @ imports
#===============================================================================
cat > "$CLAUDE_DIR/CLAUDE.md" << 'GLOBAL_CLAUDE_MD'
# Claude Code Hivemind V2

## Automatic Persistence

- **SessionStart**: Inits DB, loads memory into context
- **PreCompact**: Saves full state before auto/manual compaction
- **Stop**: Snapshots + exports learnings to project .claude/CLAUDE.md
- **SessionEnd**: Logs session, final snapshot

## Record Learnings

When you discover something important:
```bash
python3 ~/.claude/scripts/memory-db.py learning-add decision "Chose X because Y"
python3 ~/.claude/scripts/memory-db.py learning-add pattern "Always check for..."
python3 ~/.claude/scripts/memory-db.py learning-add bug "Issue when..."
```

These export to project `.claude/CLAUDE.md` automatically on session stop.

## Quick Reference

@~/.claude/memory/commands.md
@~/.claude/memory/hivemind.md

## Phase Workflow

```bash
memory-db.py phase-start "Research" "{}"
memory-db.py set "findings" "<data>" "research"
memory-db.py phase-complete 1
memory-db.py phase-start "Implement" "{}" 1
```

## Create Subagents

```bash
cat > ~/.claude/agents/<name>.md << 'EOF'
---
name: <name>
description: <when to use - PROACTIVELY for auto-delegation>
tools: Read, Write, Edit, Bash, Grep, Glob
model: sonnet
---
<System prompt>
EOF
memory-db.py agent-register "<name>" "subagent"
```
GLOBAL_CLAUDE_MD

#===============================================================================
# SUBAGENTS
#===============================================================================
cat > "$AGENTS_DIR/orchestrator.md" << 'EOF'
---
name: orchestrator
description: Use PROACTIVELY for coordinating multiple tasks or parallel work
tools: Read, Write, Edit, Bash, Grep, Glob, Task
model: sonnet
---
Hivemind Orchestrator. Decompose tasks, spawn agents, aggregate results.
Use: hivemind.sh spawn/status/swarm
Store state: memory-db.py set "orch_state" "<data>" "orchestration"
EOF

cat > "$AGENTS_DIR/researcher.md" << 'EOF'
---
name: researcher
description: Use for research, codebase analysis, documentation review (read-only)
tools: Read, Grep, Glob, Bash
model: sonnet
---
Research specialist. Investigate without changes.
Store: memory-db.py set "research_<topic>" "<findings>" "research"
EOF

cat > "$AGENTS_DIR/implementer.md" << 'EOF'
---
name: implementer
description: Use for code implementation from specifications
tools: Read, Write, Edit, Bash, Grep, Glob
model: sonnet
---
Implementation specialist.
1. Load: memory-db.py dump
2. Implement per specs
3. Store: memory-db.py set "impl_<feature>" "<notes>" "implementation"
4. Record: memory-db.py learning-add pattern "<what learned>"
EOF

cat > "$AGENTS_DIR/meta-agent.md" << 'EOF'
---
name: meta-agent
description: Use to CREATE NEW SUBAGENTS for specialized tasks
tools: Read, Write, Edit, Bash
model: sonnet
---
Creates new subagents. Write to ~/.claude/agents/<name>.md with YAML frontmatter.
Register: memory-db.py agent-register "<name>" "subagent"
EOF

#===============================================================================
# SLASH COMMANDS
#===============================================================================
cat > "$COMMANDS_DIR/hivemind.md" << 'EOF'
---
description: Manage hivemind agents
argument-hint: [status|spawn|tasks|swarm]
---
Run: `~/.claude/scripts/hivemind.sh $ARGUMENTS`
EOF

cat > "$COMMANDS_DIR/memory.md" << 'EOF'
---
description: Access memory database
argument-hint: [dump|set|get|list]
---
Run: `python3 ~/.claude/scripts/memory-db.py $ARGUMENTS`
EOF

cat > "$COMMANDS_DIR/learn.md" << 'EOF'
---
description: Record a learning
argument-hint: <type> <content>
---
Run: `python3 ~/.claude/scripts/memory-db.py learning-add $ARGUMENTS`
Types: decision, pattern, convention, bug, optimization
EOF

#===============================================================================
# FINALIZE
#===============================================================================
mkdir -p "$HOME/.claude/agent-logs" "$HOME/.claude/memory/compact-backups"
python3 "$SCRIPTS_DIR/memory-db.py" init

echo ""
echo "==> Claude Code Hivemind V2 Complete!"
echo ""
echo "V2 FIXES:"
echo "  ✓ PreCompact hook - saves state before auto/manual compaction"
echo "  ✓ SessionStart - correct hookSpecificOutput.additionalContext format"
echo "  ✓ Stop hook - exports learnings to project .claude/CLAUDE.md"
echo "  ✓ SessionEnd hook - cleanup and logging"
echo "  ✓ @ imports in CLAUDE.md for modular configs"
echo "  ✓ learning-add command for session discoveries"
echo "  ✓ compact-summary for pre-compact state capture"
echo ""
echo "Test:"
echo "  python3 ~/.claude/scripts/memory-db.py set test 'hello' testing"
echo "  python3 ~/.claude/scripts/memory-db.py learning-add decision 'Test'"
echo "  python3 ~/.claude/scripts/memory-db.py dump"
echo ""
echo "IMPORTANT: Run 'claude' and use /hooks to approve new hooks!"
