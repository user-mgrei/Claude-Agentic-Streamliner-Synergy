#!/bin/bash
#===============================================================================
# Claude Code Hivemind Setup Script V3 (Arch Linux Optimized)
# 
# FEATURES:
#   - Qdrant Vector Database Integration (Local MCP)
#   - TUI-based Setup (Whiptail)
#   - Specialized Programming Agents (QuickShell+QML, Arch Hyprland)
#   - Preconfigured LSP Setup
#   - Hivemind V2 Core (SQLite, Hooks) + V3 Enhancements
#
# USAGE:
#   chmod +x setup-claude-hivemind-v3.sh && ./setup-claude-hivemind-v3.sh
#===============================================================================

set -e

# Configuration
CLAUDE_DIR="$HOME/.claude"
BIN_DIR="$CLAUDE_DIR/bin"
SCRIPTS_DIR="$CLAUDE_DIR/scripts"
AGENTS_DIR="$CLAUDE_DIR/agents"
MEMORY_DIR="$CLAUDE_DIR/memory"
HOOKS_DIR="$CLAUDE_DIR/hooks"
LOG_DIR="$CLAUDE_DIR/logs"
COMMANDS_DIR="$CLAUDE_DIR/commands"
RULES_DIR="$CLAUDE_DIR/rules"

# Ensure directories
mkdir -p "$CLAUDE_DIR" "$BIN_DIR" "$SCRIPTS_DIR" "$AGENTS_DIR" "$MEMORY_DIR" "$HOOKS_DIR" "$LOG_DIR" "$COMMANDS_DIR" "$RULES_DIR"

# TUI Helper
msg_box() {
    if command -v whiptail >/dev/null; then
        whiptail --title "Claude Hivemind V3" --msgbox "$1" 12 70
    else
        echo "----------------------------------------------------------------"
        echo "$1"
        echo "----------------------------------------------------------------"
        read -p "Press Enter to continue..."
    fi
}

menu_selection() {
    if command -v whiptail >/dev/null; then
        whiptail --title "Claude Hivemind V3 Setup" --checklist \
        "Select components to install:" 15 60 4 \
        "CORE" "Core Hivemind (SQLite, Hooks, Utils)" ON \
        "QDRANT" "Qdrant Vector DB & MCP Server" ON \
        "AGENTS" "Specialized Agents (QML, Hyprland)" ON \
        "LSP" "Language Server Configurations" ON 3>&1 1>&2 2>&3
    else
        echo "whiptail not found. Installing ALL components."
        echo "\"CORE\" \"QDRANT\" \"AGENTS\" \"LSP\""
    fi
}

#===============================================================================
# 1. DEPENDENCY CHECK & INSTALL
#===============================================================================
echo "==> Checking dependencies..."
if ! command -v python3 >/dev/null; then
    echo "Python 3 is required."
    exit 1
fi

# Install Python dependencies for MCP
echo "==> Installing Python dependencies (fastmcp, qdrant-client)..."
pip install --break-system-packages qdrant-client fastmcp || pip install qdrant-client fastmcp

#===============================================================================
# 2. QDRANT SETUP (Local Binary)
#===============================================================================
setup_qdrant() {
    echo "==> Setting up Qdrant..."
    if [ ! -f "$BIN_DIR/qdrant" ]; then
        echo "Downloading Qdrant binary..."
        # Detect architecture
        ARCH=$(uname -m)
        if [ "$ARCH" = "x86_64" ]; then
            QDRANT_URL="https://github.com/qdrant/qdrant/releases/latest/download/qdrant-x86_64-unknown-linux-gnu"
        elif [ "$ARCH" = "aarch64" ]; then
            QDRANT_URL="https://github.com/qdrant/qdrant/releases/latest/download/qdrant-aarch64-unknown-linux-gnu"
        else
            echo "Unsupported architecture for automatic Qdrant download: $ARCH"
            return 1
        fi
        
        curl -L -o "$BIN_DIR/qdrant" "$QDRANT_URL"
        chmod +x "$BIN_DIR/qdrant"
    else
        echo "Qdrant binary already exists."
    fi

    # Create User Service for Qdrant
    mkdir -p "$HOME/.config/systemd/user"
    cat > "$HOME/.config/systemd/user/claude-qdrant.service" <<EOF
[Unit]
Description=Qdrant Vector Database for Claude Hivemind
After=network.target

[Service]
ExecStart=$BIN_DIR/qdrant
WorkingDirectory=$CLAUDE_DIR
Restart=always
RestartSec=10
StandardOutput=append:$LOG_DIR/qdrant.log
StandardError=append:$LOG_DIR/qdrant.error.log

[Install]
WantedBy=default.target
EOF

    # Reload systemd and enable
    if command -v systemctl >/dev/null; then
        systemctl --user daemon-reload
        systemctl --user enable --now claude-qdrant.service
        echo "Qdrant service enabled and started."
    else
        echo "Systemd not found. You will need to start qdrant manually: $BIN_DIR/qdrant"
    fi
}

#===============================================================================
# 3. QDRANT MCP SERVER
#===============================================================================
create_qdrant_mcp() {
    cat > "$SCRIPTS_DIR/qdrant_mcp.py" << 'PYTHON_MCP'
#!/usr/bin/env python3
"""
Qdrant MCP Server for Claude Hivemind
Provides semantic search and memory storage capabilities.
"""
from fastmcp import FastMCP
from qdrant_client import QdrantClient
from qdrant_client.http import models
import os
import uuid
import datetime

# Configuration
QDRANT_HOST = os.environ.get("QDRANT_HOST", "localhost")
QDRANT_PORT = int(os.environ.get("QDRANT_PORT", 6333))
COLLECTION_NAME = "hivemind_memory"

mcp = FastMCP("Hivemind Memory (Qdrant)")
client = None

def get_client():
    global client
    if client is None:
        client = QdrantClient(host=QDRANT_HOST, port=QDRANT_PORT)
    return client

def ensure_collection():
    c = get_client()
    try:
        if not c.collection_exists(COLLECTION_NAME):
            c.create_collection(
                collection_name=COLLECTION_NAME,
                vectors_config=models.VectorParams(size=384, distance=models.Distance.COSINE),
            )
    except Exception as e:
        pass # Might already exist or connection error

@mcp.tool()
def save_memory(content: str, category: str = "general", tags: list[str] = []) -> str:
    """
    Save a piece of text to long-term memory with semantic indexing.
    Args:
        content: The text content to save.
        category: Category of the memory (e.g., 'decision', 'learning', 'reference').
        tags: List of tags for filtering.
    """
    ensure_collection()
    c = get_client()
    doc_id = str(uuid.uuid4())
    
    try:
        # Note: This assumes qdrant-client[fastembed] is available or Qdrant server does embedding.
        # If running purely local binary without fastembed, vectors might need to be computed manually.
        # We assume the user has installed qdrant-client[fastembed].
        c.add(
            collection_name=COLLECTION_NAME,
            documents=[content],
            metadata=[{
                "category": category,
                "tags": tags,
                "timestamp": datetime.datetime.now().isoformat(),
                "type": "memory"
            }],
            ids=[doc_id]
        )
        return f"Memory saved with ID: {doc_id}"
    except Exception as e:
        return f"Error saving memory: {str(e)}. Ensure qdrant-client[fastembed] is installed."

@mcp.tool()
def search_memory(query: str, limit: int = 5, category: str = None) -> str:
    """
    Semantically search the memory database.
    Args:
        query: The search query string.
        limit: Number of results to return.
        category: Optional category filter.
    """
    ensure_collection()
    c = get_client()
    try:
        search_filter = None
        if category:
            search_filter = models.Filter(
                must=[models.FieldCondition(key="category", match=models.MatchValue(value=category))]
            )
            
        results = c.query(
            collection_name=COLLECTION_NAME,
            query_text=query,
            limit=limit,
            query_filter=search_filter
        )
        
        output = []
        for res in results:
            meta = res.metadata
            output.append(f"[{res.score:.2f}] {res.document} (Category: {meta.get('category')})")
        
        return "\n".join(output) if output else "No relevant memories found."
    except Exception as e:
        return f"Error searching memory: {str(e)}"

if __name__ == "__main__":
    mcp.run()
PYTHON_MCP
    chmod +x "$SCRIPTS_DIR/qdrant_mcp.py"
    
    # Install fastembed for client-side embedding
    pip install "qdrant-client[fastembed]" || echo "Warning: Could not install fastembed. Semantic search might fail if not configured."
}

#===============================================================================
# 4. AGENT TEMPLATES (YAML/Markdown)
#===============================================================================
create_agents() {
    echo "==> Creating Specialized Agents..."

    # QuickShell + QML Agent
    cat > "$AGENTS_DIR/quickshell-qml.md" << 'EOF'
---
name: quickshell-qml
description: Expert in QuickShell and QML for creating custom desktop shells.
tools: Read, Write, Edit, Bash, Grep, Glob, mcp__qdrant_mcp__search_memory, mcp__qdrant_mcp__save_memory
model: sonnet
---
You are a QuickShell and QML expert. Your goal is to help the user create beautiful, functional desktop shells using the QuickShell framework.

Capabilities:
- You know QML (Qt Modeling Language) deeply.
- You understand the QuickShell API and its bindings to Hyprland/Wayland.
- You can debug QML/JS errors.

Guidelines:
- When writing QML, ensure you use the correct QuickShell imports (`import QuickShell 1.0`, etc.).
- Prefer anchoring and layouts over absolute positioning.
- Use `qmllint` to verify your code if available.
- Check the `~/.config/quickshell` directory for existing configs.
- Record key architectural decisions using `mcp__qdrant_mcp__save_memory`.
EOF

    # Arch Hyprland Agent
    cat > "$AGENTS_DIR/arch-hyprland.md" << 'EOF'
---
name: arch-hyprland
description: Arch Linux and Hyprland configuration specialist.
tools: Read, Write, Edit, Bash, Grep, Glob, mcp__qdrant_mcp__search_memory, mcp__qdrant_mcp__save_memory
model: sonnet
---
You are an Arch Linux and Hyprland expert. You assist with system configuration, package management, and window manager tuning.

Capabilities:
- Arch Linux package management (`pacman`, `yay`).
- Hyprland configuration (`hyprland.conf`).
- Waybar, Rofi, and other ecosystem tools.

Guidelines:
- ALWAYS check for existing configuration before overwriting (`~/.config/hypr/hyprland.conf`).
- Use `hyprctl` to query the current state of the window manager.
- When suggesting packages, prefer `pacman` first, then `yay`.
- Be careful with `sudo` commands; explanation is required before execution.
- Record successful configurations using `mcp__qdrant_mcp__save_memory`.
EOF

    # Orchestrator (Standard)
    cat > "$AGENTS_DIR/orchestrator.md" << 'EOF'
---
name: orchestrator
description: High-level task coordinator and planner.
tools: Read, Write, Edit, Bash, Grep, Glob, mcp__qdrant_mcp__save_memory, mcp__qdrant_mcp__search_memory
model: sonnet
---
You are the Hivemind Orchestrator. Your job is to break down complex tasks, assign them to specialized agents (like `quickshell-qml` or `arch-hyprland`), and synthesize the results.

- Use `mcp__qdrant_mcp__save_memory` to record architectural decisions.
- Use `mcp__qdrant_mcp__search_memory` to recall past decisions.
- Coordinate the team effectively.
EOF
}

#===============================================================================
# 5. LSP CONFIGURATION
#===============================================================================
setup_lsp() {
    echo "==> Configuring LSPs..."
    
    # Create a helper script to install common LSPs
    cat > "$SCRIPTS_DIR/install-lsps.sh" << 'EOF'
#!/bin/bash
echo "Installing LSPs..."

# QML LSP (qmlls) - Part of qt6-declarative on Arch
if command -v pacman >/dev/null; then
    echo "Detected Arch Linux. Installing qt6-declarative for qmlls..."
    sudo pacman -S --needed qt6-declarative qt6-languageserver
fi

# Bash LSP
if command -v npm >/dev/null; then
    echo "Installing bash-language-server..."
    npm install -g bash-language-server
fi

# Python LSP
pip install python-lsp-server

echo "LSPs installed (if package managers were available)."
EOF
    chmod +x "$SCRIPTS_DIR/install-lsps.sh"
    
    # Run it
    "$SCRIPTS_DIR/install-lsps.sh"
}

#===============================================================================
# 6. CORE HIVEMIND (V2 Logic)
#===============================================================================
setup_core() {
    echo "==> Setting up Core Hivemind (SQLite + Hooks)..."
    
    # --- memory-db.py ---
    cat > "$SCRIPTS_DIR/memory-db.py" << 'MEMORY_SCRIPT'
#!/usr/bin/env python3
"""
Claude Code SQLite Memory Manager V2
"""
import sqlite3
import json
import sys
import os
from datetime import datetime
from pathlib import Path

def get_db_path():
    project_dir = os.environ.get('CLAUDE_PROJECT_DIR', os.getcwd())
    project_db = Path(project_dir) / '.claude' / 'claude.db'
    global_db = Path.home() / '.claude' / 'claude.db'
    if (Path(project_dir) / '.claude').exists():
        return project_db
    return global_db

def init_db(conn):
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
        
        elif cmd == "dump":
             # Simplified dump
            cursor.execute('SELECT key, value, category FROM memory')
            memories = cursor.fetchall()
            print(json.dumps({
                "memories": {r[0]: {"value": r[1], "category": r[2]} for r in memories}
            }, indent=2))
            
        elif cmd == "dump-compact":
            cursor.execute('SELECT key, value FROM memory ORDER BY updated_at DESC LIMIT 50')
            memories = cursor.fetchall()
            output = []
            if memories:
                output.append("MEMORY:")
                for k, v in memories:
                    v_short = v[:200] + "..." if len(v) > 200 else v
                    output.append(f"  {k}: {v_short}")
            print("\n".join(output) if output else "No memory state")

    except Exception as e:
        print(json.dumps({"error": str(e)}))
        sys.exit(1)
    finally:
        conn.close()

if __name__ == "__main__":
    main()
MEMORY_SCRIPT
    chmod +x "$SCRIPTS_DIR/memory-db.py"

    # --- Hooks ---
    cat > "$HOOKS_DIR/session-start.sh" << 'SESSION_HOOK'
#!/bin/bash
MEMORY_SCRIPT="$HOME/.claude/scripts/memory-db.py"
python3 "$MEMORY_SCRIPT" init >/dev/null 2>&1
CONTEXT=$(python3 "$MEMORY_SCRIPT" dump-compact 2>/dev/null)
if [ -n "$CONTEXT" ] && [ "$CONTEXT" != "No memory state" ]; then
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

    # --- Settings Update ---
    SETTINGS_FILE="$CLAUDE_DIR/settings.json"
    if [ -f "$SETTINGS_FILE" ]; then
        python3 -c "
import json
import os
path = '$SETTINGS_FILE'
try:
    with open(path, 'r') as f:
        data = json.load(f)
except:
    data = {}

if 'mcpServers' not in data:
    data['mcpServers'] = {}

# Add Qdrant MCP
data['mcpServers']['qdrant_mcp'] = {
    'command': 'python3',
    'args': [os.path.expanduser('~/.claude/scripts/qdrant_mcp.py')]
}

# Ensure hooks exist
if 'hooks' not in data:
    data['hooks'] = {}
if 'SessionStart' not in data['hooks']:
    data['hooks']['SessionStart'] = []
    
# Add session-start hook if not present (simple check)
has_hook = False
for h in data['hooks']['SessionStart']:
    if 'session-start.sh' in str(h):
        has_hook = True
if not has_hook:
    data['hooks']['SessionStart'].append({\"matcher\": \"\", \"hooks\": [{\"type\": \"command\", \"command\": \"~/.claude/hooks/session-start.sh\", \"timeout\": 10}]})

with open(path, 'w') as f:
    json.dump(data, f, indent=2)
"
    else
        cat > "$SETTINGS_FILE" <<EOF
{
  "mcpServers": {
    "qdrant_mcp": {
      "command": "python3",
      "args": ["$SCRIPTS_DIR/qdrant_mcp.py"]
    }
  },
  "hooks": {
    "SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "~/.claude/hooks/session-start.sh", "timeout": 10}]}]
  },
  "permissions": {
    "allow": ["Bash(*)", "Read(*)", "Write(*)", "Edit(*)", "Grep(*)", "Glob(*)"]
  }
}
EOF
    fi
}

#===============================================================================
# MAIN EXECUTION
#===============================================================================
SELECTION=$(menu_selection)

if [[ $SELECTION == *"CORE"* ]]; then
    setup_core
fi

if [[ $SELECTION == *"QDRANT"* ]]; then
    setup_qdrant
    create_qdrant_mcp
fi

if [[ $SELECTION == *"AGENTS"* ]]; then
    create_agents
fi

if [[ $SELECTION == *"LSP"* ]]; then
    setup_lsp
fi

msg_box "Setup Complete!
1. Ensure Qdrant service is running (if selected).
2. Restart Claude Code to load new agents and MCPs.
3. Use 'quickshell-qml' or 'arch-hyprland' agents for specific tasks.
4. Use 'orchestrator' to manage memory."

exit 0
