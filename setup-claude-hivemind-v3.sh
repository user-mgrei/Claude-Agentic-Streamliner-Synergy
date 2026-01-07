#!/bin/bash
#===============================================================================
# Claude Code Hivemind Setup Script V3
# 
# MAJOR CHANGES FROM V2:
#   - Qdrant vector database integration for semantic memory (local instance)
#   - Programming-optimized agents with proper YAML frontmatter
#   - LSP configuration system with TUI wizard for new language servers
#   - Preconfigured LSPs: QuickShell+QML, Hyprland config language
#   - Context watcher script (workaround for PreCompact bug #13572)
#   - CRLF fix PostToolUse hook (workaround for bug #2805)
#   - UserPromptSubmit hook for reliable context injection (#10373, #15174)
#   - Isolated subagent settings to prevent hook loops
#   - Enhanced swarm orchestration with parallel execution
#
# Known Issues Addressed:
#   - #13572: PreCompact hook unreliable → Context watcher + manual preservation
#   - #2805: CRLF line endings on Linux → PostToolUse sed fix
#   - #10373/#15174: SessionStart injection bugs → Use UserPromptSubmit
#   - #1041: @ imports fail in global CLAUDE.md → Project-level only
#   - #7881: SubagentStop can't identify agent → PreToolUse tracking
#
# For Arch Linux with yay-installed claude-code
# Run once: chmod +x setup-claude-hivemind-v3.sh && ./setup-claude-hivemind-v3.sh
#===============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║         Claude Code Hivemind V3 Setup Script                   ║${NC}"
echo -e "${BLUE}║     Qdrant Vector Memory + LSP Config + Optimized Agents       ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

#===============================================================================
# DIRECTORY STRUCTURE
#===============================================================================
CLAUDE_DIR="$HOME/.claude"
AGENTS_DIR="$CLAUDE_DIR/agents"
COMMANDS_DIR="$CLAUDE_DIR/commands"
HOOKS_DIR="$CLAUDE_DIR/hooks/hivemind"
SCRIPTS_DIR="$CLAUDE_DIR/scripts"
MEMORY_DIR="$CLAUDE_DIR/memory"
LSP_DIR="$CLAUDE_DIR/lsp"
LOGS_DIR="$CLAUDE_DIR/agent-logs"
BACKUP_DIR="$CLAUDE_DIR/memory/backups"

echo -e "${YELLOW}==> Creating directory structure...${NC}"
mkdir -p "$AGENTS_DIR" "$COMMANDS_DIR" "$HOOKS_DIR" "$SCRIPTS_DIR" "$MEMORY_DIR" "$LSP_DIR" "$LOGS_DIR" "$BACKUP_DIR"

#===============================================================================
# DEPENDENCY CHECK
#===============================================================================
echo -e "${YELLOW}==> Checking dependencies...${NC}"

check_dep() {
    if command -v "$1" &> /dev/null; then
        echo -e "  ${GREEN}✓${NC} $1 found"
        return 0
    else
        echo -e "  ${RED}✗${NC} $1 not found"
        return 1
    fi
}

MISSING_DEPS=()
check_dep python3 || MISSING_DEPS+=("python")
check_dep sqlite3 || MISSING_DEPS+=("sqlite")
check_dep jq || MISSING_DEPS+=("jq")
check_dep uuidgen || MISSING_DEPS+=("util-linux")

# Optional but recommended
check_dep dialog || echo -e "  ${YELLOW}!${NC} dialog not found (optional, for TUI wizard)"
check_dep notify-send || echo -e "  ${YELLOW}!${NC} notify-send not found (optional, for desktop notifications)"

if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    echo -e "\n${RED}Missing required dependencies: ${MISSING_DEPS[*]}${NC}"
    echo "Install with: sudo pacman -S ${MISSING_DEPS[*]}"
    exit 1
fi

#===============================================================================
# PYTHON DEPENDENCIES (for Qdrant)
#===============================================================================
echo -e "${YELLOW}==> Setting up Python environment for Qdrant...${NC}"

# Create a virtual environment for Qdrant client
VENV_DIR="$CLAUDE_DIR/venv"
if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
fi

# Install Qdrant client and dependencies
source "$VENV_DIR/bin/activate"
pip install -q --upgrade pip
pip install -q qdrant-client sentence-transformers numpy
deactivate

echo -e "  ${GREEN}✓${NC} Qdrant Python environment ready"

#===============================================================================
# QDRANT LOCAL INSTALLATION
#===============================================================================
echo -e "${YELLOW}==> Setting up Qdrant vector database...${NC}"

QDRANT_DIR="$CLAUDE_DIR/qdrant"
QDRANT_DATA="$QDRANT_DIR/storage"
mkdir -p "$QDRANT_DATA"

# Check if Qdrant binary exists or download
QDRANT_BIN="$QDRANT_DIR/qdrant"
if [ ! -f "$QDRANT_BIN" ]; then
    echo "  Downloading Qdrant..."
    QDRANT_VERSION="v1.12.1"
    QDRANT_URL="https://github.com/qdrant/qdrant/releases/download/${QDRANT_VERSION}/qdrant-x86_64-unknown-linux-gnu.tar.gz"
    
    curl -sL "$QDRANT_URL" | tar xz -C "$QDRANT_DIR" 2>/dev/null || {
        echo -e "  ${YELLOW}!${NC} Could not download Qdrant binary. Will use in-memory mode."
        touch "$QDRANT_DIR/.use_memory_mode"
    }
fi

# Create Qdrant config
cat > "$QDRANT_DIR/config.yaml" << 'QDRANT_CONFIG'
storage:
  storage_path: ./storage
  on_disk_payload: true

service:
  http_port: 6333
  grpc_port: 6334
  enable_cors: true

cluster:
  enabled: false

telemetry_disabled: true
QDRANT_CONFIG

# Create Qdrant service script
cat > "$QDRANT_DIR/start-qdrant.sh" << 'QDRANT_START'
#!/bin/bash
QDRANT_DIR="$HOME/.claude/qdrant"
cd "$QDRANT_DIR"

if [ -f ".use_memory_mode" ]; then
    echo "Qdrant binary not available, using in-memory Python mode"
    exit 0
fi

# Check if already running
if pgrep -f "qdrant" > /dev/null; then
    echo "Qdrant already running"
    exit 0
fi

# Start Qdrant in background
nohup ./qdrant --config-path config.yaml > "$HOME/.claude/agent-logs/qdrant.log" 2>&1 &
echo $! > "$QDRANT_DIR/qdrant.pid"
echo "Qdrant started on http://localhost:6333"
QDRANT_START
chmod +x "$QDRANT_DIR/start-qdrant.sh"

echo -e "  ${GREEN}✓${NC} Qdrant configuration ready"

#===============================================================================
# QDRANT VECTOR MEMORY MANAGER (Python)
#===============================================================================
echo -e "${YELLOW}==> Creating Qdrant Vector Memory Manager...${NC}"

cat > "$SCRIPTS_DIR/vector-memory.py" << 'VECTOR_MEMORY_SCRIPT'
#!/usr/bin/env python3
"""
Claude Code Vector Memory Manager V3
Provides semantic memory storage using Qdrant vector database.

Features:
- Semantic search across all stored memories
- Automatic embedding generation using sentence-transformers
- Hybrid SQLite + Qdrant storage (metadata + vectors)
- Collection management for different memory types
- Context-aware memory retrieval

Usage:
    vector-memory.py init                              # Initialize collections
    vector-memory.py store <key> <content> [type]     # Store memory with embedding
    vector-memory.py search <query> [limit] [type]    # Semantic search
    vector-memory.py get <key>                        # Retrieve by key
    vector-memory.py list [type]                      # List all memories
    vector-memory.py delete <key>                     # Delete memory
    vector-memory.py context <query> [tokens]         # Get relevant context for query
    vector-memory.py export-statute [limit]           # Export statute for injection
"""
import sys
import os
import json
import hashlib
import sqlite3
from datetime import datetime
from pathlib import Path

# Add venv to path
VENV_PATH = Path.home() / '.claude' / 'venv' / 'lib'
for p in VENV_PATH.glob('python*/site-packages'):
    sys.path.insert(0, str(p))

try:
    from qdrant_client import QdrantClient
    from qdrant_client.models import Distance, VectorParams, PointStruct, Filter, FieldCondition, MatchValue
    from sentence_transformers import SentenceTransformer
    import numpy as np
    QDRANT_AVAILABLE = True
except ImportError:
    QDRANT_AVAILABLE = False

# Configuration
QDRANT_HOST = "localhost"
QDRANT_PORT = 6333
EMBEDDING_MODEL = "all-MiniLM-L6-v2"  # Fast, lightweight model
EMBEDDING_DIM = 384
USE_IN_MEMORY = os.path.exists(Path.home() / '.claude' / 'qdrant' / '.use_memory_mode')

# Memory types/collections
MEMORY_TYPES = ['decision', 'pattern', 'convention', 'bug', 'learning', 'context', 'task', 'agent', 'general']

def get_db_path():
    """Get SQLite database path for metadata storage"""
    project_dir = os.environ.get('CLAUDE_PROJECT_DIR', os.getcwd())
    project_db = Path(project_dir) / '.claude' / 'hivemind.db'
    global_db = Path.home() / '.claude' / 'hivemind.db'
    
    if (Path(project_dir) / '.claude').exists():
        return project_db
    return global_db

def init_sqlite(conn):
    """Initialize SQLite schema for hybrid storage"""
    conn.executescript('''
        PRAGMA journal_mode=WAL;
        PRAGMA busy_timeout=5000;
        PRAGMA synchronous=NORMAL;
        
        CREATE TABLE IF NOT EXISTS vector_memories (
            id TEXT PRIMARY KEY,
            key TEXT UNIQUE NOT NULL,
            content TEXT NOT NULL,
            memory_type TEXT DEFAULT 'general',
            embedding_id TEXT,
            metadata TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            access_count INTEGER DEFAULT 0,
            last_accessed TIMESTAMP
        );
        
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
        
        CREATE TABLE IF NOT EXISTS swarm_queue (
            id TEXT PRIMARY KEY,
            priority INTEGER DEFAULT 5,
            task_type TEXT NOT NULL,
            payload TEXT,
            assigned_agent TEXT,
            created_at REAL DEFAULT (julianday('now')),
            claimed_at REAL
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
        
        CREATE TABLE IF NOT EXISTS compaction_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            trigger_type TEXT NOT NULL,
            summary TEXT NOT NULL,
            memories_count INTEGER,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
        
        CREATE INDEX IF NOT EXISTS idx_memories_key ON vector_memories(key);
        CREATE INDEX IF NOT EXISTS idx_memories_type ON vector_memories(memory_type);
        CREATE INDEX IF NOT EXISTS idx_tasks_session ON agent_tasks(session_id);
        CREATE INDEX IF NOT EXISTS idx_tasks_status ON agent_tasks(status);
        CREATE INDEX IF NOT EXISTS idx_queue_priority ON swarm_queue(priority DESC, created_at);
    ''')
    conn.commit()

class VectorMemory:
    def __init__(self):
        self.db_path = get_db_path()
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self.conn = sqlite3.connect(str(self.db_path))
        init_sqlite(self.conn)
        
        if not QDRANT_AVAILABLE:
            self.qdrant = None
            self.model = None
            return
        
        # Initialize Qdrant client
        if USE_IN_MEMORY:
            self.qdrant = QdrantClient(":memory:")
        else:
            try:
                self.qdrant = QdrantClient(host=QDRANT_HOST, port=QDRANT_PORT, timeout=5)
                self.qdrant.get_collections()  # Test connection
            except Exception:
                # Fall back to in-memory mode
                self.qdrant = QdrantClient(":memory:")
        
        # Load embedding model (lazy load)
        self._model = None
    
    @property
    def model(self):
        if self._model is None and QDRANT_AVAILABLE:
            self._model = SentenceTransformer(EMBEDDING_MODEL)
        return self._model
    
    def _embed(self, text):
        """Generate embedding for text"""
        if self.model is None:
            return None
        return self.model.encode(text, normalize_embeddings=True).tolist()
    
    def _get_collection_name(self, memory_type):
        """Get Qdrant collection name for memory type"""
        return f"hivemind_{memory_type}"
    
    def init_collections(self):
        """Initialize Qdrant collections for all memory types"""
        if self.qdrant is None:
            return {"status": "initialized", "mode": "sqlite_only", "db_path": str(self.db_path)}
        
        created = []
        for mem_type in MEMORY_TYPES:
            collection_name = self._get_collection_name(mem_type)
            try:
                self.qdrant.get_collection(collection_name)
            except Exception:
                self.qdrant.create_collection(
                    collection_name=collection_name,
                    vectors_config=VectorParams(size=EMBEDDING_DIM, distance=Distance.COSINE)
                )
                created.append(collection_name)
        
        return {
            "status": "initialized",
            "mode": "qdrant" if not USE_IN_MEMORY else "qdrant_memory",
            "db_path": str(self.db_path),
            "collections_created": created
        }
    
    def store(self, key, content, memory_type='general', metadata=None):
        """Store memory with vector embedding"""
        memory_id = hashlib.md5(f"{key}:{memory_type}".encode()).hexdigest()
        
        # Store in SQLite
        cursor = self.conn.cursor()
        meta_json = json.dumps(metadata) if metadata else '{}'
        cursor.execute('''
            INSERT INTO vector_memories (id, key, content, memory_type, metadata, updated_at)
            VALUES (?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
            ON CONFLICT(key) DO UPDATE SET 
                content=excluded.content,
                memory_type=excluded.memory_type,
                metadata=excluded.metadata,
                updated_at=CURRENT_TIMESTAMP
        ''', (memory_id, key, content, memory_type, meta_json))
        self.conn.commit()
        
        # Store embedding in Qdrant
        if self.qdrant is not None:
            embedding = self._embed(content)
            if embedding:
                collection_name = self._get_collection_name(memory_type)
                try:
                    self.qdrant.get_collection(collection_name)
                except Exception:
                    self.qdrant.create_collection(
                        collection_name=collection_name,
                        vectors_config=VectorParams(size=EMBEDDING_DIM, distance=Distance.COSINE)
                    )
                
                self.qdrant.upsert(
                    collection_name=collection_name,
                    points=[PointStruct(
                        id=memory_id,
                        vector=embedding,
                        payload={"key": key, "content": content[:500], "type": memory_type}
                    )]
                )
        
        return {"status": "stored", "key": key, "id": memory_id, "type": memory_type}
    
    def search(self, query, limit=5, memory_type=None):
        """Semantic search across memories"""
        results = []
        
        if self.qdrant is not None and self.model is not None:
            query_embedding = self._embed(query)
            collections = [self._get_collection_name(memory_type)] if memory_type else \
                         [self._get_collection_name(t) for t in MEMORY_TYPES]
            
            for collection_name in collections:
                try:
                    search_results = self.qdrant.search(
                        collection_name=collection_name,
                        query_vector=query_embedding,
                        limit=limit
                    )
                    for r in search_results:
                        results.append({
                            "key": r.payload.get("key"),
                            "content": r.payload.get("content"),
                            "type": r.payload.get("type"),
                            "score": r.score
                        })
                except Exception:
                    continue
            
            # Sort by score and deduplicate
            results = sorted(results, key=lambda x: x['score'], reverse=True)[:limit]
        
        else:
            # Fallback to SQLite text search
            cursor = self.conn.cursor()
            if memory_type:
                cursor.execute('''
                    SELECT key, content, memory_type FROM vector_memories
                    WHERE memory_type = ? AND content LIKE ?
                    ORDER BY updated_at DESC LIMIT ?
                ''', (memory_type, f'%{query}%', limit))
            else:
                cursor.execute('''
                    SELECT key, content, memory_type FROM vector_memories
                    WHERE content LIKE ?
                    ORDER BY updated_at DESC LIMIT ?
                ''', (f'%{query}%', limit))
            
            for row in cursor.fetchall():
                results.append({
                    "key": row[0],
                    "content": row[1][:500],
                    "type": row[2],
                    "score": 0.5  # Default score for text match
                })
        
        return {"query": query, "results": results, "count": len(results)}
    
    def get(self, key):
        """Retrieve memory by key"""
        cursor = self.conn.cursor()
        cursor.execute('''
            SELECT key, content, memory_type, metadata, created_at, updated_at
            FROM vector_memories WHERE key = ?
        ''', (key,))
        row = cursor.fetchone()
        
        if row:
            # Update access count
            cursor.execute('''
                UPDATE vector_memories SET access_count = access_count + 1, last_accessed = CURRENT_TIMESTAMP
                WHERE key = ?
            ''', (key,))
            self.conn.commit()
            
            return {
                "key": row[0],
                "content": row[1],
                "type": row[2],
                "metadata": json.loads(row[3]) if row[3] else {},
                "created_at": row[4],
                "updated_at": row[5]
            }
        return {"key": key, "content": None}
    
    def list_memories(self, memory_type=None, limit=50):
        """List all memories, optionally filtered by type"""
        cursor = self.conn.cursor()
        if memory_type:
            cursor.execute('''
                SELECT key, content, memory_type, updated_at FROM vector_memories
                WHERE memory_type = ?
                ORDER BY updated_at DESC LIMIT ?
            ''', (memory_type, limit))
        else:
            cursor.execute('''
                SELECT key, content, memory_type, updated_at FROM vector_memories
                ORDER BY updated_at DESC LIMIT ?
            ''', (limit,))
        
        rows = cursor.fetchall()
        return {
            "memories": [
                {"key": r[0], "content": r[1][:200], "type": r[2], "updated": r[3]}
                for r in rows
            ],
            "count": len(rows)
        }
    
    def delete(self, key):
        """Delete memory by key"""
        cursor = self.conn.cursor()
        cursor.execute('SELECT id, memory_type FROM vector_memories WHERE key = ?', (key,))
        row = cursor.fetchone()
        
        if row:
            memory_id, memory_type = row
            cursor.execute('DELETE FROM vector_memories WHERE key = ?', (key,))
            self.conn.commit()
            
            if self.qdrant is not None:
                try:
                    self.qdrant.delete(
                        collection_name=self._get_collection_name(memory_type),
                        points_selector=[memory_id]
                    )
                except Exception:
                    pass
            
            return {"status": "deleted", "key": key}
        return {"status": "not_found", "key": key}
    
    def get_context(self, query, max_tokens=2000):
        """Get relevant context for a query, optimized for injection"""
        search_results = self.search(query, limit=10)
        
        context_parts = []
        current_tokens = 0
        
        for result in search_results.get('results', []):
            content = result['content']
            # Rough token estimate: 4 chars per token
            est_tokens = len(content) // 4
            
            if current_tokens + est_tokens > max_tokens:
                break
            
            context_parts.append(f"[{result['type']}] {result['key']}: {content}")
            current_tokens += est_tokens
        
        return {
            "context": "\n".join(context_parts),
            "sources": len(context_parts),
            "estimated_tokens": current_tokens
        }
    
    def export_statute(self, limit=5):
        """Export database statute for context injection"""
        cursor = self.conn.cursor()
        
        # Get recent agent tasks
        cursor.execute('''
            SELECT agent_type, task_description, status, completed_at
            FROM agent_tasks
            ORDER BY started_at DESC LIMIT ?
        ''', (limit,))
        tasks = cursor.fetchall()
        
        # Get project state
        cursor.execute('''
            SELECT key, value FROM project_state
            WHERE key IN ('current_phase', 'blockers', 'next_milestone', 'focus')
        ''')
        state = dict(cursor.fetchall())
        
        # Get recent important memories
        cursor.execute('''
            SELECT key, content, memory_type FROM vector_memories
            WHERE memory_type IN ('decision', 'pattern', 'bug')
            ORDER BY updated_at DESC LIMIT 5
        ''')
        memories = cursor.fetchall()
        
        statute_parts = ["## Database Statute"]
        
        if state:
            statute_parts.append("\n### Project State")
            for k, v in state.items():
                statute_parts.append(f"- **{k}**: {v}")
        
        if tasks:
            statute_parts.append("\n### Recent Agent Activity")
            for t in tasks:
                status = f"[{t[2]}]" if t[2] else ""
                desc = (t[1] or "")[:50]
                statute_parts.append(f"- {t[0] or 'agent'}: {desc}... {status}")
        
        if memories:
            statute_parts.append("\n### Key Memories")
            for m in memories:
                content = (m[1] or "")[:100]
                statute_parts.append(f"- [{m[2]}] {m[0]}: {content}...")
        
        return {"statute": "\n".join(statute_parts)}
    
    # SQLite-based methods for backward compatibility
    def set(self, key, value, category='general'):
        """Backward-compatible set (wraps store)"""
        return self.store(key, value, category)
    
    def phase_start(self, name, context=None, parent_id=None):
        """Start a new phase"""
        cursor = self.conn.cursor()
        cursor.execute('''
            INSERT INTO project_state (key, value, updated_at)
            VALUES ('current_phase', ?, julianday('now'))
            ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=julianday('now')
        ''', (name,))
        self.conn.commit()
        return {"status": "phase_started", "phase": name}
    
    def task_add(self, description, priority=5):
        """Add task to swarm queue"""
        task_id = hashlib.md5(f"{description}:{datetime.now().isoformat()}".encode()).hexdigest()[:12]
        cursor = self.conn.cursor()
        cursor.execute('''
            INSERT INTO swarm_queue (id, task_type, payload, priority)
            VALUES (?, 'task', ?, ?)
        ''', (task_id, json.dumps({"description": description}), priority))
        self.conn.commit()
        return {"status": "added", "task_id": task_id}
    
    def task_queue(self):
        """Get pending tasks"""
        cursor = self.conn.cursor()
        cursor.execute('''
            SELECT id, payload, priority, assigned_agent, created_at
            FROM swarm_queue
            WHERE claimed_at IS NULL
            ORDER BY priority DESC, created_at
        ''')
        tasks = []
        for row in cursor.fetchall():
            payload = json.loads(row[1]) if row[1] else {}
            tasks.append({
                "id": row[0],
                "description": payload.get("description", ""),
                "priority": row[2],
                "assigned": row[3],
                "created": row[4]
            })
        return {"queue": tasks, "count": len(tasks)}
    
    def snapshot_save(self, name, data='{}', snapshot_type='manual'):
        """Save context snapshot"""
        session_id = os.environ.get('CLAUDE_SESSION_ID', 'unknown')
        snap_id = hashlib.md5(f"{name}:{datetime.now().isoformat()}".encode()).hexdigest()[:12]
        cursor = self.conn.cursor()
        cursor.execute('''
            INSERT INTO context_snapshots (id, session_id, snapshot_type, summary)
            VALUES (?, ?, ?, ?)
        ''', (snap_id, session_id, snapshot_type, data))
        self.conn.commit()
        return {"status": "saved", "snapshot_id": snap_id}
    
    def compact_summary(self, trigger='auto'):
        """Generate pre-compact summary"""
        cursor = self.conn.cursor()
        
        # Gather current state
        cursor.execute('SELECT key, content, memory_type FROM vector_memories ORDER BY updated_at DESC LIMIT 20')
        memories = cursor.fetchall()
        
        cursor.execute('SELECT * FROM project_state')
        state = dict(cursor.fetchall())
        
        cursor.execute('SELECT id, payload, status FROM swarm_queue WHERE claimed_at IS NULL')
        pending = cursor.fetchall()
        
        summary = {
            "trigger": trigger,
            "timestamp": datetime.now().isoformat(),
            "memories_count": len(memories),
            "memories": [{"key": m[0], "type": m[2]} for m in memories],
            "project_state": state,
            "pending_tasks": len(pending)
        }
        
        # Save to compaction log
        cursor.execute('''
            INSERT INTO compaction_log (trigger_type, summary, memories_count)
            VALUES (?, ?, ?)
        ''', (trigger, json.dumps(summary), len(memories)))
        self.conn.commit()
        
        # Also save as snapshot
        self.snapshot_save(f"pre-compact-{datetime.now().strftime('%Y%m%d-%H%M%S')}", 
                          json.dumps(summary), f"pre-compact-{trigger}")
        
        return summary
    
    def dump(self):
        """Dump current state (compact format)"""
        cursor = self.conn.cursor()
        
        cursor.execute('SELECT key, content, memory_type FROM vector_memories ORDER BY updated_at DESC LIMIT 10')
        memories = cursor.fetchall()
        
        cursor.execute('SELECT key, value FROM project_state')
        state = dict(cursor.fetchall())
        
        cursor.execute('SELECT COUNT(*) FROM swarm_queue WHERE claimed_at IS NULL')
        pending_count = cursor.fetchone()[0]
        
        return {
            "memories": [{"key": m[0], "content": m[1][:200], "type": m[2]} for m in memories],
            "project_state": state,
            "pending_tasks": pending_count
        }

def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "Usage: vector-memory.py <command> [args]"}))
        sys.exit(1)
    
    cmd = sys.argv[1]
    
    try:
        vm = VectorMemory()
    except Exception as e:
        print(json.dumps({"error": f"Initialization failed: {str(e)}"}))
        sys.exit(1)
    
    try:
        if cmd == "init":
            result = vm.init_collections()
        
        elif cmd == "store":
            if len(sys.argv) < 4:
                print(json.dumps({"error": "Usage: store <key> <content> [type]"}))
                sys.exit(1)
            key, content = sys.argv[2], sys.argv[3]
            memory_type = sys.argv[4] if len(sys.argv) > 4 else 'general'
            result = vm.store(key, content, memory_type)
        
        elif cmd == "search":
            if len(sys.argv) < 3:
                print(json.dumps({"error": "Usage: search <query> [limit] [type]"}))
                sys.exit(1)
            query = sys.argv[2]
            limit = int(sys.argv[3]) if len(sys.argv) > 3 else 5
            memory_type = sys.argv[4] if len(sys.argv) > 4 else None
            result = vm.search(query, limit, memory_type)
        
        elif cmd == "get":
            if len(sys.argv) < 3:
                print(json.dumps({"error": "Usage: get <key>"}))
                sys.exit(1)
            result = vm.get(sys.argv[2])
        
        elif cmd == "list":
            memory_type = sys.argv[2] if len(sys.argv) > 2 else None
            result = vm.list_memories(memory_type)
        
        elif cmd == "delete":
            if len(sys.argv) < 3:
                print(json.dumps({"error": "Usage: delete <key>"}))
                sys.exit(1)
            result = vm.delete(sys.argv[2])
        
        elif cmd == "context":
            if len(sys.argv) < 3:
                print(json.dumps({"error": "Usage: context <query> [max_tokens]"}))
                sys.exit(1)
            query = sys.argv[2]
            max_tokens = int(sys.argv[3]) if len(sys.argv) > 3 else 2000
            result = vm.get_context(query, max_tokens)
        
        elif cmd == "export-statute":
            limit = int(sys.argv[2]) if len(sys.argv) > 2 else 5
            result = vm.export_statute(limit)
        
        # Backward compatibility commands
        elif cmd == "set":
            if len(sys.argv) < 4:
                print(json.dumps({"error": "Usage: set <key> <value> [category]"}))
                sys.exit(1)
            category = sys.argv[4] if len(sys.argv) > 4 else 'general'
            result = vm.set(sys.argv[2], sys.argv[3], category)
        
        elif cmd == "phase-start":
            if len(sys.argv) < 3:
                print(json.dumps({"error": "Usage: phase-start <name>"}))
                sys.exit(1)
            result = vm.phase_start(sys.argv[2])
        
        elif cmd == "task-add":
            if len(sys.argv) < 3:
                print(json.dumps({"error": "Usage: task-add <description> [priority]"}))
                sys.exit(1)
            priority = int(sys.argv[3]) if len(sys.argv) > 3 else 5
            result = vm.task_add(sys.argv[2], priority)
        
        elif cmd == "task-queue":
            result = vm.task_queue()
        
        elif cmd == "snapshot-save":
            if len(sys.argv) < 3:
                print(json.dumps({"error": "Usage: snapshot-save <name> [data] [type]"}))
                sys.exit(1)
            name = sys.argv[2]
            data = sys.argv[3] if len(sys.argv) > 3 else '{}'
            snap_type = sys.argv[4] if len(sys.argv) > 4 else 'manual'
            result = vm.snapshot_save(name, data, snap_type)
        
        elif cmd == "compact-summary":
            trigger = sys.argv[2] if len(sys.argv) > 2 else 'auto'
            result = vm.compact_summary(trigger)
        
        elif cmd == "dump":
            result = vm.dump()
        
        elif cmd == "dump-compact":
            result = vm.dump()
            # Format as text
            output = ["MEMORY STATE:"]
            for m in result.get('memories', []):
                output.append(f"  [{m['type']}] {m['key']}: {m['content'][:100]}...")
            if result.get('project_state'):
                output.append("\nPROJECT STATE:")
                for k, v in result['project_state'].items():
                    output.append(f"  {k}: {v}")
            output.append(f"\nPending tasks: {result.get('pending_tasks', 0)}")
            print("\n".join(output))
            sys.exit(0)
        
        else:
            result = {"error": f"Unknown command: {cmd}"}
            sys.exit(1)
        
        print(json.dumps(result, indent=2))
        
    except Exception as e:
        print(json.dumps({"error": str(e)}))
        sys.exit(1)

if __name__ == "__main__":
    main()
VECTOR_MEMORY_SCRIPT

chmod +x "$SCRIPTS_DIR/vector-memory.py"
echo -e "  ${GREEN}✓${NC} Vector Memory Manager created"

#===============================================================================
# CONTEXT WATCHER SCRIPT (Workaround for #13572)
#===============================================================================
echo -e "${YELLOW}==> Creating Context Watcher...${NC}"

cat > "$HOOKS_DIR/context-watcher.sh" << 'CONTEXT_WATCHER'
#!/bin/bash
#===============================================================================
# Context Window Watcher
# Monitors transcript growth and preserves context before auto-compaction
# Workaround for Issue #13572: PreCompact hooks don't fire reliably
#
# Run as background process: nohup ~/.claude/hooks/hivemind/context-watcher.sh &
#===============================================================================

TRANSCRIPT_DIR="$HOME/.claude/projects"
MEMORY_SCRIPT="$HOME/.claude/scripts/vector-memory.py"
VENV_PYTHON="$HOME/.claude/venv/bin/python"
MAX_CONTEXT=200000
WARN_THRESHOLD=75
CRITICAL_THRESHOLD=90
CHECK_INTERVAL=30
LOG_FILE="$HOME/.claude/agent-logs/context-watcher.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

calculate_usage() {
    local jsonl_file="$1"
    # Get last entry with usage data
    local usage=$(grep '"usage"' "$jsonl_file" 2>/dev/null | tail -1 | jq -r '.message.usage // empty' 2>/dev/null)
    
    if [ -n "$usage" ] && [ "$usage" != "null" ]; then
        local input=$(echo "$usage" | jq '(.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)' 2>/dev/null)
        if [ -n "$input" ] && [ "$input" != "null" ]; then
            echo $((input * 100 / MAX_CONTEXT))
            return
        fi
    fi
    echo 0
}

preserve_context() {
    local jsonl_file="$1"
    local usage_pct="$2"
    local session_id=$(basename "$jsonl_file" .jsonl)
    
    log "Preserving context for session $session_id at ${usage_pct}%"
    
    # Extract summary from recent messages
    local summary=$(jq -r 'select(.type=="assistant") | .message.content[0].text // empty' "$jsonl_file" 2>/dev/null | \
                   tail -c 5000 | head -c 3000)
    
    # Save snapshot via memory script
    "$VENV_PYTHON" "$MEMORY_SCRIPT" snapshot-save "auto-preserve-$session_id" "$summary" "context-critical" 2>/dev/null
    
    # Desktop notification if available
    if command -v notify-send &> /dev/null; then
        notify-send -u critical "Claude Context ${usage_pct}%" \
            "Session $session_id approaching auto-compact. Context preserved."
    fi
}

log "Context watcher started"
log "Monitoring: $TRANSCRIPT_DIR"
log "Thresholds: warn=${WARN_THRESHOLD}%, critical=${CRITICAL_THRESHOLD}%"

declare -A WARNED_SESSIONS

while true; do
    # Find active transcripts (modified in last 10 minutes)
    while IFS= read -r jsonl; do
        [ -z "$jsonl" ] && continue
        
        usage=$(calculate_usage "$jsonl")
        session_id=$(basename "$jsonl" .jsonl)
        
        if [ "$usage" -gt "$CRITICAL_THRESHOLD" ]; then
            if [ "${WARNED_SESSIONS[$session_id]}" != "critical" ]; then
                log "[CRITICAL] $session_id at ${usage}% - preserving context"
                preserve_context "$jsonl" "$usage"
                WARNED_SESSIONS[$session_id]="critical"
            fi
        elif [ "$usage" -gt "$WARN_THRESHOLD" ]; then
            if [ -z "${WARNED_SESSIONS[$session_id]}" ]; then
                log "[WARNING] $session_id at ${usage}% - approaching limit"
                WARNED_SESSIONS[$session_id]="warned"
            fi
        fi
    done < <(find "$TRANSCRIPT_DIR" -name "*.jsonl" -mmin -10 2>/dev/null)
    
    sleep $CHECK_INTERVAL
done
CONTEXT_WATCHER

chmod +x "$HOOKS_DIR/context-watcher.sh"
echo -e "  ${GREEN}✓${NC} Context Watcher created"

#===============================================================================
# HOOK SCRIPTS
#===============================================================================
echo -e "${YELLOW}==> Creating hook scripts...${NC}"

# Session Start Hook
cat > "$HOOKS_DIR/session-start.sh" << 'SESSION_START'
#!/bin/bash
# Session Start Hook - Initialize database, load memory
MEMORY_SCRIPT="$HOME/.claude/scripts/vector-memory.py"
VENV_PYTHON="$HOME/.claude/venv/bin/python"

# Always init
"$VENV_PYTHON" "$MEMORY_SCRIPT" init >/dev/null 2>&1

# Get compact memory for context (only for resume/compact)
INPUT=$(cat)
SOURCE=$(echo "$INPUT" | jq -r '.source // "unknown"' 2>/dev/null)

if [ "$SOURCE" = "compact" ] || [ "$SOURCE" = "resume" ]; then
    CONTEXT=$("$VENV_PYTHON" "$MEMORY_SCRIPT" dump-compact 2>/dev/null)
    
    if [ -n "$CONTEXT" ] && [ "$CONTEXT" != "MEMORY STATE:" ]; then
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
fi

exit 0
SESSION_START
chmod +x "$HOOKS_DIR/session-start.sh"

# User Prompt Submit Hook - Inject context (more reliable than SessionStart)
cat > "$HOOKS_DIR/inject-context.sh" << 'INJECT_CONTEXT'
#!/bin/bash
# UserPromptSubmit Hook - Inject database statute into conversation
# More reliable than SessionStart for context injection (#10373, #15174)
MEMORY_SCRIPT="$HOME/.claude/scripts/vector-memory.py"
VENV_PYTHON="$HOME/.claude/venv/bin/python"

# Prevent infinite loops
[ "$HIVEMIND_INJECT_ACTIVE" = "true" ] && exit 0
export HIVEMIND_INJECT_ACTIVE=true

# Only inject on first prompt of session (check for marker)
MARKER_FILE="/tmp/hivemind-injected-$(echo "$CLAUDE_SESSION_ID" | head -c 8 2>/dev/null || echo "default")"
[ -f "$MARKER_FILE" ] && exit 0

# Get statute from database
STATUTE=$("$VENV_PYTHON" "$MEMORY_SCRIPT" export-statute 5 2>/dev/null | jq -r '.statute // empty')

if [ -n "$STATUTE" ] && [ ${#STATUTE} -gt 20 ]; then
    touch "$MARKER_FILE"
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
INJECT_CONTEXT
chmod +x "$HOOKS_DIR/inject-context.sh"

# CRLF Fix Hook (Workaround for #2805)
cat > "$HOOKS_DIR/crlf-fix.sh" << 'CRLF_FIX'
#!/bin/bash
# PostToolUse Hook - Fix CRLF line endings on Linux
# Workaround for Issue #2805
INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)

if [ -n "$FILE_PATH" ] && [ -f "$FILE_PATH" ]; then
    # Only fix text files
    if file "$FILE_PATH" | grep -q "text"; then
        sed -i 's/\r$//' "$FILE_PATH" 2>/dev/null
    fi
fi

exit 0
CRLF_FIX
chmod +x "$HOOKS_DIR/crlf-fix.sh"

# Subagent Tracking - PreToolUse
cat > "$HOOKS_DIR/register-subagent.sh" << 'REGISTER_SUBAGENT'
#!/bin/bash
# PreToolUse Hook - Register subagent before spawn
# Workaround for #7881: SubagentStop can't identify agent
MEMORY_SCRIPT="$HOME/.claude/scripts/vector-memory.py"
VENV_PYTHON="$HOME/.claude/venv/bin/python"

INPUT=$(cat)
TOOL_USE_ID=$(echo "$INPUT" | jq -r '.tool_use_id // empty' 2>/dev/null)
DESCRIPTION=$(echo "$INPUT" | jq -r '.tool_input.description // empty' 2>/dev/null)

if [ -n "$TOOL_USE_ID" ]; then
    # Store pending subagent info
    "$VENV_PYTHON" "$MEMORY_SCRIPT" store \
        "pending_subagent_$TOOL_USE_ID" \
        "$DESCRIPTION" \
        "agent" 2>/dev/null
fi

exit 0
REGISTER_SUBAGENT
chmod +x "$HOOKS_DIR/register-subagent.sh"

# Subagent Complete Hook
cat > "$HOOKS_DIR/subagent-complete.sh" << 'SUBAGENT_COMPLETE'
#!/bin/bash
# SubagentStop Hook - Record completion in database
MEMORY_SCRIPT="$HOME/.claude/scripts/vector-memory.py"
VENV_PYTHON="$HOME/.claude/venv/bin/python"

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)

if [ -n "$SESSION_ID" ]; then
    "$VENV_PYTHON" "$MEMORY_SCRIPT" store \
        "subagent_complete_$(date +%s)" \
        "Subagent session $SESSION_ID completed" \
        "task" 2>/dev/null
fi

exit 0
SUBAGENT_COMPLETE
chmod +x "$HOOKS_DIR/subagent-complete.sh"

# Stop Hook - Update plan and save state
cat > "$HOOKS_DIR/update-plan.sh" << 'UPDATE_PLAN'
#!/bin/bash
# Stop Hook - Save state and update project memory
MEMORY_SCRIPT="$HOME/.claude/scripts/vector-memory.py"
VENV_PYTHON="$HOME/.claude/venv/bin/python"

# Check stop_hook_active to prevent loops
INPUT=$(cat)
STOP_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)
[ "$STOP_ACTIVE" = "true" ] && exit 0

# Save snapshot
"$VENV_PYTHON" "$MEMORY_SCRIPT" snapshot-save "stop-$(date +%Y%m%d-%H%M%S)" "{}" "auto-stop" 2>/dev/null

exit 0
UPDATE_PLAN
chmod +x "$HOOKS_DIR/update-plan.sh"

# Session End Hook
cat > "$HOOKS_DIR/session-end.sh" << 'SESSION_END'
#!/bin/bash
# SessionEnd Hook - Cleanup and logging
MEMORY_SCRIPT="$HOME/.claude/scripts/vector-memory.py"
VENV_PYTHON="$HOME/.claude/venv/bin/python"
LOG_FILE="$HOME/.claude/session-log.txt"

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null)
REASON=$(echo "$INPUT" | jq -r '.reason // "unknown"' 2>/dev/null)

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Session $SESSION_ID ended: $REASON" >> "$LOG_FILE"

# Clean up injection marker
rm -f "/tmp/hivemind-injected-$(echo "$SESSION_ID" | head -c 8)"* 2>/dev/null

"$VENV_PYTHON" "$MEMORY_SCRIPT" snapshot-save "session-end-$SESSION_ID" "{}" "session-end" 2>/dev/null

exit 0
SESSION_END
chmod +x "$HOOKS_DIR/session-end.sh"

# Pre-Compact Hook (may not fire reliably - #13572)
cat > "$HOOKS_DIR/pre-compact.sh" << 'PRE_COMPACT'
#!/bin/bash
# PreCompact Hook - Save state before compaction
# NOTE: May not fire reliably (Issue #13572) - context-watcher.sh is the primary backup
MEMORY_SCRIPT="$HOME/.claude/scripts/vector-memory.py"
VENV_PYTHON="$HOME/.claude/venv/bin/python"

INPUT=$(cat)
TRIGGER=$(echo "$INPUT" | jq -r '.trigger // "unknown"' 2>/dev/null)

"$VENV_PYTHON" "$MEMORY_SCRIPT" compact-summary "$TRIGGER" 2>/dev/null

exit 0
PRE_COMPACT
chmod +x "$HOOKS_DIR/pre-compact.sh"

echo -e "  ${GREEN}✓${NC} All hook scripts created"

#===============================================================================
# HEADLESS AGENT SPAWNER
#===============================================================================
echo -e "${YELLOW}==> Creating agent spawner...${NC}"

cat > "$SCRIPTS_DIR/spawn-agent.sh" << 'SPAWN_AGENT'
#!/bin/bash
# Spawn a headless Claude Code agent for background task execution
# Usage: spawn-agent.sh <agent-name> <task-prompt> [working-dir]

AGENT_NAME="${1:-worker}"
TASK_PROMPT="$2"
WORK_DIR="${3:-$(pwd)}"
MEMORY_SCRIPT="$HOME/.claude/scripts/vector-memory.py"
VENV_PYTHON="$HOME/.claude/venv/bin/python"
LOG_DIR="$HOME/.claude/agent-logs"
NO_HOOKS_SETTINGS="$HOME/.claude/no-hooks.json"

mkdir -p "$LOG_DIR"

if [ -z "$TASK_PROMPT" ]; then
    echo "Usage: spawn-agent.sh <agent-name> <task-prompt> [working-dir]"
    exit 1
fi

SESSION_ID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || date +%s%N)

# Register agent in database
"$VENV_PYTHON" "$MEMORY_SCRIPT" store "agent_${AGENT_NAME}_${SESSION_ID}" \
    "Task: $TASK_PROMPT" "agent" 2>/dev/null

cd "$WORK_DIR"

# Spawn with isolated settings to prevent hook loops
nohup claude -p "$TASK_PROMPT" \
    --settings "$NO_HOOKS_SETTINGS" \
    --output-format stream-json \
    --permission-mode acceptEdits \
    --allowedTools "Read,Write,Edit,MultiEdit,Bash,Grep,Glob,LS" \
    --max-turns 50 \
    > "$LOG_DIR/${AGENT_NAME}-${SESSION_ID}.log" 2>&1 &

AGENT_PID=$!
echo "$AGENT_PID" > "$LOG_DIR/${AGENT_NAME}.pid"

echo "{\"agent\": \"$AGENT_NAME\", \"session_id\": \"$SESSION_ID\", \"pid\": $AGENT_PID, \"log\": \"$LOG_DIR/${AGENT_NAME}-${SESSION_ID}.log\"}"

# Background task to update status on completion
(
    wait $AGENT_PID 2>/dev/null
    "$VENV_PYTHON" "$MEMORY_SCRIPT" store "agent_${AGENT_NAME}_complete" \
        "Completed: $TASK_PROMPT" "task" 2>/dev/null
) &
SPAWN_AGENT

chmod +x "$SCRIPTS_DIR/spawn-agent.sh"
echo -e "  ${GREEN}✓${NC} Agent spawner created"

#===============================================================================
# HIVEMIND ORCHESTRATOR
#===============================================================================
cat > "$SCRIPTS_DIR/hivemind.sh" << 'HIVEMIND'
#!/bin/bash
# Hivemind Orchestrator - Manage swarm of Claude agents
MEMORY_SCRIPT="$HOME/.claude/scripts/vector-memory.py"
VENV_PYTHON="$HOME/.claude/venv/bin/python"
SPAWN_SCRIPT="$HOME/.claude/scripts/spawn-agent.sh"
LOG_DIR="$HOME/.claude/agent-logs"

case "$1" in
    spawn)
        "$SPAWN_SCRIPT" "$2" "$3" "$4"
        ;;
    status)
        "$VENV_PYTHON" "$MEMORY_SCRIPT" list agent
        ;;
    tasks)
        "$VENV_PYTHON" "$MEMORY_SCRIPT" task-queue
        ;;
    add-task)
        "$VENV_PYTHON" "$MEMORY_SCRIPT" task-add "$2" "${3:-5}"
        ;;
    search)
        "$VENV_PYTHON" "$MEMORY_SCRIPT" search "$2" "${3:-5}"
        ;;
    store)
        "$VENV_PYTHON" "$MEMORY_SCRIPT" store "$2" "$3" "${4:-general}"
        ;;
    context)
        "$VENV_PYTHON" "$MEMORY_SCRIPT" context "$2" "${3:-2000}"
        ;;
    logs)
        ls -la "$LOG_DIR"/${2:-*}*.log 2>/dev/null || echo "No logs"
        ;;
    tail)
        [ -n "$2" ] && {
            LATEST=$(ls -t "$LOG_DIR"/${2}*.log 2>/dev/null | head -1)
            [ -n "$LATEST" ] && tail -f "$LATEST"
        } || echo "Usage: tail <agent>"
        ;;
    kill)
        [ -f "$LOG_DIR/${2}.pid" ] && {
            kill $(cat "$LOG_DIR/${2}.pid") 2>/dev/null
            rm "$LOG_DIR/${2}.pid"
            echo "Agent $2 killed"
        }
        ;;
    killall)
        for p in "$LOG_DIR"/*.pid; do
            [ -f "$p" ] && {
                kill $(cat "$p") 2>/dev/null
                rm "$p"
            }
        done
        echo "All agents killed"
        ;;
    swarm)
        COUNT="${2:-3}"
        TASK="$3"
        for i in $(seq 1 $COUNT); do
            "$SPAWN_SCRIPT" "swarm-$i" "$TASK (Worker $i)"
            sleep 1
        done
        ;;
    start-watcher)
        nohup "$HOME/.claude/hooks/hivemind/context-watcher.sh" > /dev/null 2>&1 &
        echo "Context watcher started (PID: $!)"
        ;;
    start-qdrant)
        "$HOME/.claude/qdrant/start-qdrant.sh"
        ;;
    *)
        echo "Hivemind Orchestrator V3"
        echo ""
        echo "Commands:"
        echo "  spawn <name> <task> [dir]  - Spawn headless agent"
        echo "  status                     - List agent states"
        echo "  tasks                      - Show task queue"
        echo "  add-task <desc> [priority] - Add task to queue"
        echo "  search <query> [limit]     - Semantic search memories"
        echo "  store <key> <val> [type]   - Store memory"
        echo "  context <query> [tokens]   - Get relevant context"
        echo "  logs [agent]               - List agent logs"
        echo "  tail <agent>               - Tail agent log"
        echo "  kill <agent>               - Kill agent"
        echo "  killall                    - Kill all agents"
        echo "  swarm <num> <task>         - Spawn agent swarm"
        echo "  start-watcher              - Start context watcher"
        echo "  start-qdrant               - Start Qdrant server"
        ;;
esac
HIVEMIND

chmod +x "$SCRIPTS_DIR/hivemind.sh"

#===============================================================================
# LSP CONFIGURATION SYSTEM
#===============================================================================
echo -e "${YELLOW}==> Creating LSP configuration system...${NC}"

# LSP Manager Script
cat > "$SCRIPTS_DIR/lsp-manager.sh" << 'LSP_MANAGER'
#!/bin/bash
# LSP Configuration Manager for Claude Code Hivemind
# Manages Language Server Protocol configurations

LSP_DIR="$HOME/.claude/lsp"
CONFIG_FILE="$LSP_DIR/lsp-config.json"

# Initialize config if not exists
[ ! -f "$CONFIG_FILE" ] && echo '{"servers": {}}' > "$CONFIG_FILE"

add_lsp() {
    local name="$1"
    local command="$2"
    local filetypes="$3"
    local root_markers="$4"
    
    local tmp=$(mktemp)
    jq --arg name "$name" \
       --arg cmd "$command" \
       --arg ft "$filetypes" \
       --arg rm "$root_markers" \
       '.servers[$name] = {
           "command": $cmd,
           "filetypes": ($ft | split(",")),
           "rootMarkers": ($rm | split(","))
       }' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
    
    echo "Added LSP: $name"
}

remove_lsp() {
    local name="$1"
    local tmp=$(mktemp)
    jq --arg name "$name" 'del(.servers[$name])' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
    echo "Removed LSP: $name"
}

list_lsp() {
    jq -r '.servers | keys[]' "$CONFIG_FILE" 2>/dev/null
}

show_lsp() {
    local name="$1"
    jq --arg name "$name" '.servers[$name]' "$CONFIG_FILE"
}

# TUI Wizard for adding new LSP
wizard() {
    if ! command -v dialog &> /dev/null; then
        echo "dialog not installed. Using text mode."
        echo ""
        read -p "LSP Name: " name
        read -p "Command (e.g., 'pylsp'): " command
        read -p "File types (comma-separated, e.g., 'python,py'): " filetypes
        read -p "Root markers (comma-separated, e.g., 'setup.py,pyproject.toml'): " markers
        add_lsp "$name" "$command" "$filetypes" "$markers"
        return
    fi
    
    # TUI mode with dialog
    name=$(dialog --inputbox "LSP Server Name:" 8 50 2>&1 >/dev/tty)
    [ -z "$name" ] && return
    
    command=$(dialog --inputbox "Server Command (e.g., 'clangd', 'pylsp'):" 8 60 2>&1 >/dev/tty)
    [ -z "$command" ] && return
    
    filetypes=$(dialog --inputbox "File Types (comma-separated):\ne.g., cpp,c,h,hpp" 10 50 2>&1 >/dev/tty)
    [ -z "$filetypes" ] && return
    
    markers=$(dialog --inputbox "Root Markers (comma-separated):\ne.g., compile_commands.json,CMakeLists.txt" 10 60 2>&1 >/dev/tty)
    
    add_lsp "$name" "$command" "$filetypes" "$markers"
    dialog --msgbox "LSP '$name' configured successfully!" 6 40
    clear
}

case "$1" in
    add)
        add_lsp "$2" "$3" "$4" "$5"
        ;;
    remove)
        remove_lsp "$2"
        ;;
    list)
        list_lsp
        ;;
    show)
        show_lsp "$2"
        ;;
    wizard)
        wizard
        ;;
    *)
        echo "LSP Manager - Configure Language Servers"
        echo ""
        echo "Commands:"
        echo "  add <name> <cmd> <filetypes> <markers>  - Add LSP config"
        echo "  remove <name>                           - Remove LSP config"
        echo "  list                                    - List configured LSPs"
        echo "  show <name>                             - Show LSP details"
        echo "  wizard                                  - Interactive TUI wizard"
        echo ""
        echo "Preconfigured LSPs:"
        echo "  quickshell-qml, hyprland"
        ;;
esac
LSP_MANAGER

chmod +x "$SCRIPTS_DIR/lsp-manager.sh"

# Initialize LSP config with presets
cat > "$LSP_DIR/lsp-config.json" << 'LSP_CONFIG'
{
  "servers": {
    "quickshell-qml": {
      "command": "qmlls",
      "filetypes": ["qml", "qmlproject"],
      "rootMarkers": ["shell.qml", "quickshell.conf", ".qmlproject"],
      "settings": {
        "qmlls": {
          "qmlImportPath": [".", "./imports", "/usr/lib/qt6/qml"],
          "documentationStyle": "qdoc"
        }
      },
      "installation": {
        "arch": "sudo pacman -S qt6-declarative qt6-languageserver",
        "notes": "QuickShell QML Language Server for Qt6-based shell scripting"
      }
    },
    "hyprland": {
      "command": "hyprls",
      "filetypes": ["hypr", "conf"],
      "rootMarkers": ["hyprland.conf", ".hyprland"],
      "settings": {},
      "installation": {
        "arch": "yay -S hyprls-git",
        "notes": "Language server for Hyprland configuration files"
      }
    },
    "python": {
      "command": "pylsp",
      "filetypes": ["python", "py"],
      "rootMarkers": ["setup.py", "pyproject.toml", "requirements.txt", ".git"],
      "settings": {
        "pylsp": {
          "plugins": {
            "pycodestyle": {"enabled": true},
            "pyflakes": {"enabled": true}
          }
        }
      },
      "installation": {
        "arch": "pip install python-lsp-server",
        "notes": "Python Language Server"
      }
    },
    "rust": {
      "command": "rust-analyzer",
      "filetypes": ["rust", "rs"],
      "rootMarkers": ["Cargo.toml", "rust-project.json"],
      "settings": {},
      "installation": {
        "arch": "sudo pacman -S rust-analyzer",
        "notes": "Rust Analyzer Language Server"
      }
    },
    "typescript": {
      "command": "typescript-language-server",
      "args": ["--stdio"],
      "filetypes": ["typescript", "javascript", "ts", "js", "tsx", "jsx"],
      "rootMarkers": ["package.json", "tsconfig.json", "jsconfig.json"],
      "settings": {},
      "installation": {
        "arch": "npm install -g typescript-language-server typescript",
        "notes": "TypeScript/JavaScript Language Server"
      }
    },
    "lua": {
      "command": "lua-language-server",
      "filetypes": ["lua"],
      "rootMarkers": [".luarc.json", ".luacheckrc", ".git"],
      "settings": {},
      "installation": {
        "arch": "sudo pacman -S lua-language-server",
        "notes": "Lua Language Server - great for Neovim/Awesome configs"
      }
    },
    "bash": {
      "command": "bash-language-server",
      "args": ["start"],
      "filetypes": ["sh", "bash", "zsh"],
      "rootMarkers": [".git"],
      "settings": {},
      "installation": {
        "arch": "npm install -g bash-language-server",
        "notes": "Bash Language Server"
      }
    }
  }
}
LSP_CONFIG

echo -e "  ${GREEN}✓${NC} LSP configuration system created"
echo -e "  ${GREEN}✓${NC} Preconfigured: quickshell-qml, hyprland, python, rust, typescript, lua, bash"

#===============================================================================
# PROGRAMMING-OPTIMIZED AGENTS
#===============================================================================
echo -e "${YELLOW}==> Creating programming-optimized agents...${NC}"

# Orchestrator Agent
cat > "$AGENTS_DIR/orchestrator.md" << 'ORCHESTRATOR_AGENT'
---
name: orchestrator
description: Use PROACTIVELY for coordinating multi-file changes, parallel tasks, or complex refactoring. Spawns and manages subagents.
tools: Read, Write, Edit, MultiEdit, Bash, Grep, Glob, LS, Task, TodoRead, TodoWrite
model: opus
permissionMode: acceptEdits
---
# Hivemind Orchestrator

You are the orchestrator agent responsible for coordinating complex development tasks.

## Capabilities
- Spawn specialized subagents for parallel work
- Coordinate multi-file refactoring
- Manage task queues and priorities
- Track progress across agents

## Commands
```bash
# Spawn agents
~/.claude/scripts/hivemind.sh spawn <name> "<task>" [dir]
~/.claude/scripts/hivemind.sh swarm <count> "<task>"

# Monitor
~/.claude/scripts/hivemind.sh status
~/.claude/scripts/hivemind.sh tasks
~/.claude/scripts/hivemind.sh logs <agent>

# Memory
~/.claude/scripts/hivemind.sh store "key" "value" "type"
~/.claude/scripts/hivemind.sh search "<query>"
```

## Workflow
1. Analyze the task and decompose into subtasks
2. Assign subtasks to appropriate agent types
3. Spawn agents or queue tasks
4. Monitor progress and aggregate results
5. Store learnings in vector memory

Always record important decisions:
```bash
~/.claude/venv/bin/python ~/.claude/scripts/vector-memory.py store \
    "decision_$(date +%s)" "Decision: <what> because <why>" "decision"
```
ORCHESTRATOR_AGENT

# Researcher Agent
cat > "$AGENTS_DIR/researcher.md" << 'RESEARCHER_AGENT'
---
name: researcher
description: Use PROACTIVELY for codebase analysis, documentation review, architecture understanding, and information gathering. Read-only operations.
tools: Read, Grep, Glob, LS, WebFetch, WebSearch
model: sonnet
permissionMode: plan
---
# Research Specialist

You are a research-focused agent. Your role is to gather information, analyze codebases, and document findings WITHOUT making changes.

## Capabilities
- Deep codebase exploration
- Pattern identification
- Documentation analysis
- Web research for best practices
- Architecture understanding

## Workflow
1. Understand the research question
2. Systematically search the codebase
3. Document findings in vector memory
4. Provide structured analysis

## Storing Findings
```bash
# Store research findings
~/.claude/venv/bin/python ~/.claude/scripts/vector-memory.py store \
    "research_<topic>" "<findings>" "pattern"

# Store discovered conventions
~/.claude/venv/bin/python ~/.claude/scripts/vector-memory.py store \
    "convention_<name>" "<description>" "convention"
```

## Output Format
Always structure findings as:
1. Summary
2. Key findings (bullet points)
3. Patterns observed
4. Recommendations
RESEARCHER_AGENT

# Implementer Agent
cat > "$AGENTS_DIR/implementer.md" << 'IMPLEMENTER_AGENT'
---
name: implementer
description: Use PROACTIVELY for implementing features, writing code, and making file changes based on specifications.
tools: Read, Write, Edit, MultiEdit, Bash, Grep, Glob, LS
model: sonnet
permissionMode: acceptEdits
---
# Implementation Specialist

You are an implementation-focused agent. Execute coding tasks based on specifications.

## Capabilities
- Feature implementation
- Bug fixes
- Code refactoring
- Test writing
- Multi-file changes with MultiEdit

## Workflow
1. Load relevant context: `~/.claude/scripts/hivemind.sh context "<task description>"`
2. Review specifications and existing code
3. Implement changes following project conventions
4. Run tests if available
5. Document changes

## After Implementation
```bash
# Record what was done
~/.claude/venv/bin/python ~/.claude/scripts/vector-memory.py store \
    "impl_$(date +%s)" "Implemented: <feature>. Changes: <files>" "task"

# Record any patterns discovered
~/.claude/venv/bin/python ~/.claude/scripts/vector-memory.py store \
    "pattern_<name>" "<pattern description>" "pattern"
```

## Best Practices
- Check existing patterns before creating new ones
- Follow project code style
- Add appropriate comments
- Consider edge cases
IMPLEMENTER_AGENT

# Debugger Agent
cat > "$AGENTS_DIR/debugger.md" << 'DEBUGGER_AGENT'
---
name: debugger
description: Use PROACTIVELY for debugging issues, analyzing errors, tracing bugs, and understanding failure modes.
tools: Read, Grep, Glob, LS, Bash, Edit
model: sonnet
permissionMode: default
---
# Debug Specialist

You are a debugging expert. Analyze issues, trace bugs, and propose fixes.

## Capabilities
- Error analysis
- Stack trace interpretation
- Log analysis
- Reproducing issues
- Root cause identification

## Debugging Workflow
1. Understand the symptoms
2. Gather error information (logs, traces)
3. Form hypotheses
4. Test hypotheses systematically
5. Identify root cause
6. Propose fix (don't implement unless asked)

## Record Bugs
```bash
# Store bug information for future reference
~/.claude/venv/bin/python ~/.claude/scripts/vector-memory.py store \
    "bug_$(date +%s)" "Bug: <description>. Root cause: <cause>. Fix: <solution>" "bug"
```

## Analysis Commands
```bash
# Search for related errors
grep -r "ERROR\|Exception\|WARN" logs/

# Find related code
~/.claude/scripts/hivemind.sh search "error handling <module>"
```
DEBUGGER_AGENT

# Tester Agent
cat > "$AGENTS_DIR/tester.md" << 'TESTER_AGENT'
---
name: tester
description: Use PROACTIVELY for writing tests, reviewing test coverage, and validating implementations.
tools: Read, Write, Edit, Bash, Grep, Glob, LS
model: sonnet
permissionMode: acceptEdits
---
# Testing Specialist

You are a testing expert. Write comprehensive tests and validate code quality.

## Capabilities
- Unit test creation
- Integration test design
- Test coverage analysis
- Edge case identification
- Test data generation

## Testing Workflow
1. Analyze the code to test
2. Identify test scenarios (happy path, edge cases, errors)
3. Write comprehensive tests
4. Run tests and validate
5. Document test coverage

## Test Patterns
```bash
# Search for existing test patterns
~/.claude/scripts/hivemind.sh search "test pattern"

# Store new test patterns
~/.claude/venv/bin/python ~/.claude/scripts/vector-memory.py store \
    "test_pattern_<name>" "<description>" "pattern"
```

## Common Test Frameworks
- Python: pytest, unittest
- JavaScript: jest, mocha
- Rust: cargo test
- Go: go test
TESTER_AGENT

# Reviewer Agent
cat > "$AGENTS_DIR/reviewer.md" << 'REVIEWER_AGENT'
---
name: reviewer
description: Use PROACTIVELY for code review, security analysis, and quality checks. Does not make changes, only reports.
tools: Read, Grep, Glob, LS
model: sonnet
permissionMode: plan
---
# Code Review Specialist

You are a code review expert. Analyze code for quality, security, and best practices.

## Review Checklist
- [ ] Code correctness
- [ ] Error handling
- [ ] Security vulnerabilities
- [ ] Performance issues
- [ ] Code style consistency
- [ ] Documentation
- [ ] Test coverage
- [ ] Edge cases

## Security Checks
- Input validation
- SQL injection
- XSS vulnerabilities
- Authentication/authorization
- Secrets in code
- Dependency vulnerabilities

## Output Format
Structure reviews as:
1. **Summary**: Overall assessment
2. **Critical Issues**: Must fix
3. **Warnings**: Should fix
4. **Suggestions**: Nice to have
5. **Positive Notes**: What's done well

## Store Findings
```bash
~/.claude/venv/bin/python ~/.claude/scripts/vector-memory.py store \
    "review_$(date +%s)" "Review findings: <summary>" "learning"
```
REVIEWER_AGENT

# Meta Agent (creates other agents)
cat > "$AGENTS_DIR/meta-agent.md" << 'META_AGENT'
---
name: meta-agent
description: Use to CREATE NEW SPECIALIZED SUBAGENTS for specific project needs.
tools: Read, Write, Edit, Bash
model: sonnet
permissionMode: acceptEdits
---
# Agent Factory

You create new specialized subagents for the Hivemind.

## Agent YAML Format
```yaml
---
name: agent-name              # lowercase with hyphens
description: When to use...   # Include "PROACTIVELY" for auto-delegation
tools: Tool1, Tool2           # Available tools for this agent
model: sonnet                 # sonnet|opus|haiku
permissionMode: default       # default|acceptEdits|bypassPermissions|plan
---
# Agent Title

System prompt and instructions...
```

## Available Tools
Read, Write, Edit, MultiEdit, Bash, Grep, Glob, LS, WebFetch, WebSearch, 
TodoRead, TodoWrite, NotebookRead, NotebookEdit, Task

## Permission Modes
- `default`: Ask for dangerous operations
- `acceptEdits`: Auto-accept file edits
- `bypassPermissions`: Skip all permission checks
- `plan`: Read-only, planning mode

## Creating an Agent
```bash
cat > ~/.claude/agents/<name>.md << 'EOF'
---
name: <name>
description: <description>
tools: <tools>
model: sonnet
---
<instructions>
EOF
```
META_AGENT

echo -e "  ${GREEN}✓${NC} Created agents: orchestrator, researcher, implementer, debugger, tester, reviewer, meta-agent"

#===============================================================================
# SLASH COMMANDS
#===============================================================================
echo -e "${YELLOW}==> Creating slash commands...${NC}"

cat > "$COMMANDS_DIR/hivemind.md" << 'EOF'
---
description: Manage hivemind agent swarm
argument-hint: [spawn|status|tasks|search|store|swarm|logs]
---
Run: `~/.claude/scripts/hivemind.sh $ARGUMENTS`

Examples:
- `/hivemind spawn worker "Fix all linting errors"`
- `/hivemind status`
- `/hivemind search "authentication"`
- `/hivemind swarm 3 "Review code quality"`
EOF

cat > "$COMMANDS_DIR/memory.md" << 'EOF'
---
description: Access vector memory database
argument-hint: [store|search|get|list|context]
---
Run: `~/.claude/venv/bin/python ~/.claude/scripts/vector-memory.py $ARGUMENTS`

Examples:
- `/memory store mykey "important info" decision`
- `/memory search "authentication pattern"`
- `/memory context "how to handle errors"`
EOF

cat > "$COMMANDS_DIR/lsp.md" << 'EOF'
---
description: Manage LSP configurations
argument-hint: [list|show|wizard|add]
---
Run: `~/.claude/scripts/lsp-manager.sh $ARGUMENTS`

Examples:
- `/lsp list`
- `/lsp wizard`
- `/lsp show quickshell-qml`
EOF

cat > "$COMMANDS_DIR/learn.md" << 'EOF'
---
description: Record a learning in vector memory
argument-hint: <type> <content>
---
Run: `~/.claude/venv/bin/python ~/.claude/scripts/vector-memory.py store "learning_$(date +%s)" "$ARGUMENTS"`

Types: decision, pattern, convention, bug, learning
EOF

echo -e "  ${GREEN}✓${NC} Slash commands created"

#===============================================================================
# SETTINGS.JSON - V3
#===============================================================================
echo -e "${YELLOW}==> Creating settings.json...${NC}"

cat > "$CLAUDE_DIR/settings.json" << 'SETTINGS_JSON'
{
  "permissions": {
    "allow": [
      "Read(*)",
      "Grep(*)",
      "Glob(*)",
      "LS(*)",
      "Bash(~/.claude/venv/bin/python ~/.claude/scripts/*)",
      "Bash(~/.claude/scripts/*)",
      "Bash(git status)",
      "Bash(git diff*)",
      "Bash(git log*)",
      "Bash(git branch*)",
      "Bash(git show*)",
      "Bash(ls*)",
      "Bash(cat*)",
      "Bash(head*)",
      "Bash(tail*)",
      "Bash(find*)",
      "Bash(uuidgen)",
      "Bash(date*)",
      "Bash(mkdir*)",
      "Bash(file*)",
      "Bash(wc*)"
    ],
    "deny": [
      "Bash(rm -rf /)",
      "Bash(rm -rf ~)",
      "Bash(:(){ :|:& };:)",
      "Bash(dd if=/dev/*)"
    ]
  },
  "hooks": {
    "SessionStart": [{
      "matcher": "",
      "hooks": [{
        "type": "command",
        "command": "~/.claude/hooks/hivemind/session-start.sh",
        "timeout": 10
      }]
    }],
    "UserPromptSubmit": [{
      "hooks": [{
        "type": "command",
        "command": "~/.claude/hooks/hivemind/inject-context.sh",
        "timeout": 5
      }]
    }],
    "PreToolUse": [{
      "matcher": "Task",
      "hooks": [{
        "type": "command",
        "command": "~/.claude/hooks/hivemind/register-subagent.sh",
        "timeout": 5
      }]
    }],
    "PostToolUse": [
      {
        "matcher": "Write|Edit|MultiEdit",
        "hooks": [{
          "type": "command",
          "command": "~/.claude/hooks/hivemind/crlf-fix.sh",
          "timeout": 5
        }]
      },
      {
        "matcher": "Task",
        "hooks": [{
          "type": "command",
          "command": "~/.claude/hooks/hivemind/subagent-complete.sh",
          "timeout": 10
        }]
      }
    ],
    "SubagentStop": [{
      "hooks": [{
        "type": "command",
        "command": "~/.claude/hooks/hivemind/subagent-complete.sh",
        "timeout": 10
      }]
    }],
    "Stop": [{
      "hooks": [{
        "type": "command",
        "command": "~/.claude/hooks/hivemind/update-plan.sh",
        "timeout": 15
      }]
    }],
    "PreCompact": [
      {
        "matcher": "auto",
        "hooks": [{
          "type": "command",
          "command": "~/.claude/hooks/hivemind/pre-compact.sh",
          "timeout": 30
        }]
      },
      {
        "matcher": "manual",
        "hooks": [{
          "type": "command",
          "command": "~/.claude/hooks/hivemind/pre-compact.sh",
          "timeout": 30
        }]
      }
    ],
    "SessionEnd": [{
      "hooks": [{
        "type": "command",
        "command": "~/.claude/hooks/hivemind/session-end.sh",
        "timeout": 10
      }]
    }]
  },
  "env": {
    "CLAUDE_HIVEMIND_ENABLED": "1",
    "PYTHONUNBUFFERED": "1",
    "QDRANT_HOST": "localhost",
    "QDRANT_PORT": "6333"
  }
}
SETTINGS_JSON

# Create isolated settings for subagents (prevents hook loops)
cat > "$CLAUDE_DIR/no-hooks.json" << 'NO_HOOKS'
{
  "disableAllHooks": true,
  "permissions": {
    "allow": [
      "Read(*)",
      "Grep(*)",
      "Glob(*)",
      "LS(*)",
      "Bash(~/.claude/venv/bin/python ~/.claude/scripts/*)",
      "Bash(git*)",
      "Bash(ls*)",
      "Bash(cat*)",
      "Bash(head*)",
      "Bash(tail*)"
    ]
  }
}
NO_HOOKS

echo -e "  ${GREEN}✓${NC} Settings created"

#===============================================================================
# GLOBAL CLAUDE.MD
#===============================================================================
echo -e "${YELLOW}==> Creating global CLAUDE.md...${NC}"

cat > "$CLAUDE_DIR/CLAUDE.md" << 'GLOBAL_CLAUDE'
# Claude Code Hivemind V3

## Automatic Systems

- **SessionStart**: Initializes vector database, loads memory on resume
- **UserPromptSubmit**: Injects database statute into context (more reliable than SessionStart)
- **PostToolUse**: Fixes CRLF line endings (Linux bug #2805)
- **PreToolUse (Task)**: Registers subagent before spawn (tracking for #7881)
- **SubagentStop**: Records task completion
- **Stop**: Saves state snapshot
- **PreCompact**: Attempts pre-compaction backup (unreliable - #13572)

## Context Watcher

Run for automatic context preservation (workaround for PreCompact bug):
```bash
~/.claude/scripts/hivemind.sh start-watcher
```

## Vector Memory Commands

```bash
# Store memories with semantic embeddings
~/.claude/venv/bin/python ~/.claude/scripts/vector-memory.py store "<key>" "<content>" "<type>"
# Types: decision, pattern, convention, bug, learning, context, task, agent, general

# Semantic search across all memories
~/.claude/venv/bin/python ~/.claude/scripts/vector-memory.py search "<query>" [limit]

# Get relevant context for a task
~/.claude/venv/bin/python ~/.claude/scripts/vector-memory.py context "<query>" [max_tokens]

# Export database statute
~/.claude/venv/bin/python ~/.claude/scripts/vector-memory.py export-statute
```

## Agent Orchestration

```bash
# Spawn specialized agent
~/.claude/scripts/hivemind.sh spawn <name> "<task>" [dir]

# Spawn agent swarm
~/.claude/scripts/hivemind.sh swarm <count> "<task>"

# Monitor agents
~/.claude/scripts/hivemind.sh status
~/.claude/scripts/hivemind.sh logs [agent]
~/.claude/scripts/hivemind.sh tail <agent>
```

## LSP Configuration

```bash
# List configured LSPs
~/.claude/scripts/lsp-manager.sh list

# Interactive LSP setup wizard
~/.claude/scripts/lsp-manager.sh wizard

# Show LSP details
~/.claude/scripts/lsp-manager.sh show quickshell-qml
```

## Available Subagents

- **orchestrator**: Multi-task coordination, agent spawning
- **researcher**: Read-only codebase analysis
- **implementer**: Feature implementation
- **debugger**: Bug analysis and tracing
- **tester**: Test writing and validation
- **reviewer**: Code review (read-only)
- **meta-agent**: Create new specialized agents

## Recording Learnings

When you discover something important:
```bash
# Decisions
~/.claude/venv/bin/python ~/.claude/scripts/vector-memory.py store \
    "decision_$(date +%s)" "Chose X because Y" decision

# Patterns
~/.claude/venv/bin/python ~/.claude/scripts/vector-memory.py store \
    "pattern_<name>" "Pattern description" pattern

# Bugs found
~/.claude/venv/bin/python ~/.claude/scripts/vector-memory.py store \
    "bug_$(date +%s)" "Bug: X. Cause: Y. Fix: Z" bug
```

## Known Issues & Workarounds

| Issue | Description | Workaround |
|-------|-------------|------------|
| #13572 | PreCompact hooks unreliable | Use context-watcher.sh |
| #2805 | CRLF line endings on Linux | PostToolUse sed fix |
| #10373 | SessionStart injection buggy | Use UserPromptSubmit |
| #7881 | SubagentStop can't identify agent | PreToolUse tracking |
| #1041 | @ imports fail in global CLAUDE.md | Project-level only |
GLOBAL_CLAUDE

echo -e "  ${GREEN}✓${NC} Global CLAUDE.md created"

#===============================================================================
# MEMORY FILES
#===============================================================================
cat > "$MEMORY_DIR/commands.md" << 'EOF'
# Memory Commands Quick Reference

## Vector Memory (Qdrant)
```bash
# Store with embedding
store <key> <content> [type]

# Semantic search
search <query> [limit] [type]

# Get relevant context
context <query> [max_tokens]

# List memories
list [type]

# Get by key
get <key>

# Delete
delete <key>
```

## Types
- decision, pattern, convention, bug
- learning, context, task, agent, general

## Legacy (SQLite compatible)
```bash
set <key> <value> [category]
get <key>
dump
dump-compact
```
EOF

cat > "$MEMORY_DIR/agents.md" << 'EOF'
# Subagent Reference

## Spawning
```bash
# Single agent
hivemind.sh spawn <name> "<task>" [dir]

# Swarm (parallel)
hivemind.sh swarm <count> "<task>"
```

## Available Types
| Agent | Use For | Mode |
|-------|---------|------|
| orchestrator | Coordination | acceptEdits |
| researcher | Analysis | plan (read-only) |
| implementer | Coding | acceptEdits |
| debugger | Bug hunting | default |
| tester | Testing | acceptEdits |
| reviewer | Code review | plan (read-only) |

## Creating Custom Agents
```bash
cat > ~/.claude/agents/my-agent.md << 'AGENT'
---
name: my-agent
description: Use PROACTIVELY for <purpose>
tools: Read, Write, Edit, Bash, Grep, Glob
model: sonnet
permissionMode: default
---
<System prompt>
AGENT
```
EOF

#===============================================================================
# INITIALIZATION
#===============================================================================
echo -e "${YELLOW}==> Initializing...${NC}"

# Initialize vector memory database
source "$VENV_DIR/bin/activate"
python "$SCRIPTS_DIR/vector-memory.py" init
deactivate

echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         Claude Code Hivemind V3 Setup Complete!                ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BLUE}V3 FEATURES:${NC}"
echo "  ✓ Qdrant vector database for semantic memory search"
echo "  ✓ Programming-optimized agents (orchestrator, researcher, etc.)"
echo "  ✓ LSP configuration system with TUI wizard"
echo "  ✓ Preconfigured LSPs: QuickShell+QML, Hyprland, Python, Rust, etc."
echo "  ✓ Context watcher (workaround for PreCompact bug #13572)"
echo "  ✓ CRLF fix hook (workaround for bug #2805)"
echo "  ✓ UserPromptSubmit context injection (workaround for #10373)"
echo "  ✓ Isolated subagent settings (prevents hook loops)"
echo ""
echo -e "${YELLOW}NEXT STEPS:${NC}"
echo ""
echo "1. Start Qdrant (optional, for vector search):"
echo -e "   ${BLUE}~/.claude/scripts/hivemind.sh start-qdrant${NC}"
echo ""
echo "2. Start context watcher (recommended):"
echo -e "   ${BLUE}~/.claude/scripts/hivemind.sh start-watcher${NC}"
echo ""
echo "3. Test the setup:"
echo -e "   ${BLUE}~/.claude/venv/bin/python ~/.claude/scripts/vector-memory.py store test_key 'Hello V3!' general${NC}"
echo -e "   ${BLUE}~/.claude/venv/bin/python ~/.claude/scripts/vector-memory.py search 'hello'${NC}"
echo ""
echo "4. Configure LSPs (interactive):"
echo -e "   ${BLUE}~/.claude/scripts/lsp-manager.sh wizard${NC}"
echo ""
echo "5. Launch Claude Code and approve hooks:"
echo -e "   ${BLUE}claude${NC}"
echo "   Then run /hooks to see all configured hooks"
echo ""
echo -e "${RED}IMPORTANT:${NC} On first run, use /hooks to approve new hooks!"
echo ""
