#!/bin/bash
#===============================================================================
# Claude Code Hivemind Setup Script V3 - With Qdrant Vector Memory
# 
# CHANGES FROM V2:
#   - Added Qdrant vector database integration for semantic memory
#   - Hybrid memory manager combining SQLite + Qdrant
#   - Semantic search slash commands
#   - Context-aware memory injection via hooks
#   - Auto-sync between SQLite and Qdrant
#   - Support for file-based Qdrant (no server needed)
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
# Run once: chmod +x setup-claude-hivemind-v3.sh && ./setup-claude-hivemind-v3.sh
#
# Options:
#   --with-qdrant-docker   : Set up Qdrant using Docker
#   --with-qdrant-file     : Set up Qdrant with file-based storage (default)
#   --without-qdrant       : Skip Qdrant setup entirely
#===============================================================================

set -e

CLAUDE_DIR="$HOME/.claude"
AGENTS_DIR="$CLAUDE_DIR/agents"
COMMANDS_DIR="$CLAUDE_DIR/commands"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SCRIPTS_DIR="$CLAUDE_DIR/scripts"
RULES_DIR="$CLAUDE_DIR/rules"
MEMORY_DIR="$CLAUDE_DIR/memory"

# Parse arguments
QDRANT_MODE="file"  # Default to file-based
for arg in "$@"; do
    case $arg in
        --with-qdrant-docker) QDRANT_MODE="docker" ;;
        --with-qdrant-file) QDRANT_MODE="file" ;;
        --without-qdrant) QDRANT_MODE="none" ;;
        --help|-h)
            echo "Usage: $0 [--with-qdrant-docker|--with-qdrant-file|--without-qdrant]"
            echo "  --with-qdrant-docker : Run Qdrant in Docker container"
            echo "  --with-qdrant-file   : Use file-based Qdrant storage (default)"
            echo "  --without-qdrant     : Skip Qdrant setup entirely"
            exit 0
            ;;
    esac
done

echo "==> Setting up Claude Code Hivemind V3 configuration..."
echo "    Qdrant mode: $QDRANT_MODE"

# Create directory structure
mkdir -p "$AGENTS_DIR" "$COMMANDS_DIR" "$HOOKS_DIR" "$SCRIPTS_DIR" "$RULES_DIR" "$MEMORY_DIR"
mkdir -p "$HOME/.claude/agent-logs" "$HOME/.claude/memory/compact-backups"

#===============================================================================
# HYBRID MEMORY MANAGER (SQLite + Qdrant)
#===============================================================================
cat > "$SCRIPTS_DIR/memory-db.py" << 'MEMORY_SCRIPT'
#!/usr/bin/env python3
"""
Claude Code SQLite + Qdrant Hybrid Memory Manager V3

Provides persistent memory storage between phases/sessions with both:
  - SQLite: Structured data, metadata, relationships
  - Qdrant: Semantic vector search for intelligent retrieval

Database locations:
  - SQLite: $PROJECT_DIR/.claude/claude.db or ~/.claude/claude.db
  - Qdrant: localhost:6333 or ~/.claude/qdrant_data (file mode)

Usage:
  memory-db.py set <key> <value> [category]
  memory-db.py get <key>
  memory-db.py search <query>              # Hybrid search
  memory-db.py semantic-search <query>     # Vector-only search
  memory-db.py context-for <topic>         # Smart context injection
  memory-db.py sync-vectors               # Sync SQLite to Qdrant
  memory-db.py status                     # Show both DB status
"""

import sqlite3
import json
import sys
import os
import hashlib
from datetime import datetime
from pathlib import Path
from typing import Optional, List, Dict, Any

# Optional Qdrant imports
try:
    from qdrant_client import QdrantClient
    from qdrant_client.models import (
        Distance, VectorParams, PointStruct, Filter,
        FieldCondition, MatchValue
    )
    QDRANT_AVAILABLE = True
except ImportError:
    QDRANT_AVAILABLE = False

try:
    from sentence_transformers import SentenceTransformer
    EMBEDDINGS_AVAILABLE = True
except ImportError:
    EMBEDDINGS_AVAILABLE = False

# Configuration
COLLECTION_NAME = "hivemind_memory"
EMBEDDING_MODEL = "all-MiniLM-L6-v2"
EMBEDDING_DIM = 384
DEFAULT_QDRANT_URL = "http://localhost:6333"


class HybridMemoryManager:
    """Unified interface for SQLite + Qdrant hybrid storage."""
    
    def __init__(self):
        self.sqlite_conn: Optional[sqlite3.Connection] = None
        self.qdrant_client: Optional[Any] = None
        self.embedding_model: Optional[Any] = None
        self.use_file_storage = os.environ.get("QDRANT_FILE_STORAGE") == "1"
        self._qdrant_initialized = False
        
    def _get_sqlite_path(self) -> Path:
        project_dir = os.environ.get('CLAUDE_PROJECT_DIR', os.getcwd())
        project_db = Path(project_dir) / '.claude' / 'claude.db'
        global_db = Path.home() / '.claude' / 'claude.db'
        if (Path(project_dir) / '.claude').exists():
            return project_db
        return global_db
        
    def _get_qdrant_path(self) -> Path:
        project_dir = os.environ.get('CLAUDE_PROJECT_DIR', os.getcwd())
        project_qdrant = Path(project_dir) / '.claude' / 'qdrant_data'
        global_qdrant = Path.home() / '.claude' / 'qdrant_data'
        if (Path(project_dir) / '.claude').exists():
            return project_qdrant
        return global_qdrant
        
    def _ensure_sqlite(self) -> sqlite3.Connection:
        if self.sqlite_conn is None:
            db_path = self._get_sqlite_path()
            db_path.parent.mkdir(parents=True, exist_ok=True)
            self.sqlite_conn = sqlite3.connect(str(db_path))
            self._init_sqlite_schema()
        return self.sqlite_conn
        
    def _init_sqlite_schema(self):
        self.sqlite_conn.executescript('''
            CREATE TABLE IF NOT EXISTS memory (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                key TEXT UNIQUE NOT NULL,
                value TEXT NOT NULL,
                category TEXT DEFAULT 'general',
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                vector_synced INTEGER DEFAULT 0
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
                vector_synced INTEGER DEFAULT 0,
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
            CREATE INDEX IF NOT EXISTS idx_memory_vector_synced ON memory(vector_synced);
            CREATE INDEX IF NOT EXISTS idx_phases_status ON phases(status);
            CREATE INDEX IF NOT EXISTS idx_agents_status ON agents(status);
            CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
            CREATE INDEX IF NOT EXISTS idx_learnings_exported ON learnings(exported);
        ''')
        self.sqlite_conn.commit()
        
    def _ensure_qdrant(self) -> bool:
        if self._qdrant_initialized:
            return self.qdrant_client is not None
        if not QDRANT_AVAILABLE:
            self._qdrant_initialized = True
            return False
        try:
            if self.use_file_storage:
                qdrant_path = self._get_qdrant_path()
                qdrant_path.mkdir(parents=True, exist_ok=True)
                self.qdrant_client = QdrantClient(path=str(qdrant_path))
            else:
                qdrant_url = os.environ.get('QDRANT_URL', DEFAULT_QDRANT_URL)
                self.qdrant_client = QdrantClient(url=qdrant_url)
                self.qdrant_client.get_collections()
            if EMBEDDINGS_AVAILABLE:
                self.embedding_model = SentenceTransformer(EMBEDDING_MODEL)
            self._ensure_qdrant_collection()
            self._qdrant_initialized = True
            return True
        except Exception:
            self._qdrant_initialized = True
            return False
            
    def _ensure_qdrant_collection(self):
        if not self.qdrant_client:
            return
        collections = self.qdrant_client.get_collections().collections
        if not any(c.name == COLLECTION_NAME for c in collections):
            self.qdrant_client.create_collection(
                collection_name=COLLECTION_NAME,
                vectors_config=VectorParams(size=EMBEDDING_DIM, distance=Distance.COSINE)
            )
            
    def _generate_embedding(self, text: str) -> List[float]:
        if not self.embedding_model:
            raise RuntimeError("Embedding model not available")
        return self.embedding_model.encode(text).tolist()
        
    def _generate_id(self, key: str) -> str:
        return hashlib.md5(key.encode()).hexdigest()
        
    def _store_in_qdrant(self, key: str, content: str, category: str) -> bool:
        if not self._ensure_qdrant() or not self.embedding_model:
            return False
        try:
            embedding = self._generate_embedding(content)
            payload = {
                "key": key, "content": content, "category": category,
                "created_at": datetime.now().isoformat()
            }
            self.qdrant_client.upsert(
                collection_name=COLLECTION_NAME,
                points=[PointStruct(id=self._generate_id(key), vector=embedding, payload=payload)]
            )
            return True
        except Exception:
            return False

    def set(self, key: str, value: str, category: str = 'general') -> Dict[str, Any]:
        conn = self._ensure_sqlite()
        cursor = conn.cursor()
        cursor.execute('''
            INSERT INTO memory (key, value, category, updated_at, vector_synced) 
            VALUES (?, ?, ?, CURRENT_TIMESTAMP, 0)
            ON CONFLICT(key) DO UPDATE SET 
                value=excluded.value, category=excluded.category,
                updated_at=CURRENT_TIMESTAMP, vector_synced=0
        ''', (key, value, category))
        conn.commit()
        qdrant_synced = self._store_in_qdrant(key, value, category)
        if qdrant_synced:
            cursor.execute('UPDATE memory SET vector_synced = 1 WHERE key = ?', (key,))
            conn.commit()
        return {"status": "set", "key": key, "sqlite": True, "qdrant": qdrant_synced}
        
    def get(self, key: str) -> Dict[str, Any]:
        conn = self._ensure_sqlite()
        cursor = conn.cursor()
        cursor.execute('SELECT value, category, updated_at FROM memory WHERE key = ?', (key,))
        row = cursor.fetchone()
        if row:
            return {"key": key, "value": row[0], "category": row[1], "updated_at": row[2]}
        return {"key": key, "value": None}
        
    def delete(self, key: str) -> Dict[str, Any]:
        conn = self._ensure_sqlite()
        cursor = conn.cursor()
        cursor.execute('DELETE FROM memory WHERE key = ?', (key,))
        conn.commit()
        deleted = cursor.rowcount > 0
        if self._ensure_qdrant():
            try:
                self.qdrant_client.delete(collection_name=COLLECTION_NAME, points_selector=[self._generate_id(key)])
            except Exception:
                pass
        return {"status": "deleted" if deleted else "not_found", "key": key}
        
    def list(self, category: Optional[str] = None) -> Dict[str, Any]:
        conn = self._ensure_sqlite()
        cursor = conn.cursor()
        if category:
            cursor.execute('SELECT key, value, category FROM memory WHERE category = ?', (category,))
        else:
            cursor.execute('SELECT key, value, category FROM memory')
        rows = cursor.fetchall()
        return {"memories": [{"key": r[0], "value": r[1], "category": r[2]} for r in rows]}

    def semantic_search(self, query: str, limit: int = 5) -> Dict[str, Any]:
        if not self._ensure_qdrant() or not self.embedding_model:
            return {"error": "Qdrant not available", "results": []}
        try:
            query_embedding = self._generate_embedding(query)
            results = self.qdrant_client.search(
                collection_name=COLLECTION_NAME, query_vector=query_embedding,
                limit=limit, score_threshold=0.3, with_payload=True
            )
            return {
                "query": query,
                "results": [
                    {"key": hit.payload.get("key"), "content": hit.payload.get("content"),
                     "category": hit.payload.get("category"), "score": round(hit.score, 4)}
                    for hit in results
                ]
            }
        except Exception as e:
            return {"error": str(e), "results": []}

    def keyword_search(self, query: str, limit: int = 10) -> Dict[str, Any]:
        conn = self._ensure_sqlite()
        cursor = conn.cursor()
        pattern = f'%{query}%'
        cursor.execute('''
            SELECT key, value, category FROM memory 
            WHERE key LIKE ? OR value LIKE ? ORDER BY updated_at DESC LIMIT ?
        ''', (pattern, pattern, limit))
        rows = cursor.fetchall()
        return {"query": query, "results": [{"key": r[0], "content": r[1], "category": r[2]} for r in rows]}

    def hybrid_search(self, query: str, limit: int = 5) -> Dict[str, Any]:
        semantic = self.semantic_search(query, limit * 2)
        keyword = self.keyword_search(query, limit * 2)
        seen, combined = set(), []
        for r in semantic.get("results", []):
            if r["key"] not in seen:
                seen.add(r["key"])
                r["source"] = "semantic"
                combined.append(r)
        for r in keyword.get("results", []):
            if r["key"] not in seen:
                seen.add(r["key"])
                r["score"] = 0.5
                r["source"] = "keyword"
                combined.append(r)
        return {"query": query, "results": combined[:limit], "count": min(len(combined), limit)}

    def context_for(self, topic: str, max_tokens: int = 2000) -> str:
        results = self.hybrid_search(topic, limit=10)
        if not results.get("results"):
            return ""
        parts = [f"## Relevant Memory: {topic}\n"]
        tokens = 50
        for r in results["results"]:
            content = r.get("content", "")
            est = len(content) // 4
            if tokens + est > max_tokens:
                break
            parts.append(f"**{r['key']}** [{r.get('category', 'general')}]: {content[:500]}\n")
            tokens += est + 30
        return "\n".join(parts)

    def sync_vectors(self) -> Dict[str, Any]:
        if not self._ensure_qdrant():
            return {"error": "Qdrant not available"}
        conn = self._ensure_sqlite()
        cursor = conn.cursor()
        cursor.execute('SELECT key, value, category FROM memory WHERE vector_synced = 0')
        memories = cursor.fetchall()
        synced = 0
        for key, value, category in memories:
            if self._store_in_qdrant(key, value, category):
                cursor.execute('UPDATE memory SET vector_synced = 1 WHERE key = ?', (key,))
                synced += 1
        conn.commit()
        return {"status": "synced", "synced_count": synced}

    def status(self) -> Dict[str, Any]:
        status = {"sqlite": {}, "qdrant": {}, "capabilities": {"qdrant": QDRANT_AVAILABLE, "embeddings": EMBEDDINGS_AVAILABLE}}
        try:
            conn = self._ensure_sqlite()
            cursor = conn.cursor()
            cursor.execute('SELECT COUNT(*) FROM memory')
            count = cursor.fetchone()[0]
            cursor.execute('SELECT COUNT(*) FROM memory WHERE vector_synced = 0')
            unsynced = cursor.fetchone()[0]
            status["sqlite"] = {"connected": True, "path": str(self._get_sqlite_path()), "memories": count, "unsynced": unsynced}
        except Exception as e:
            status["sqlite"] = {"connected": False, "error": str(e)}
        if self._ensure_qdrant():
            try:
                info = self.qdrant_client.get_collection(COLLECTION_NAME)
                status["qdrant"] = {"connected": True, "vectors": info.vectors_count}
            except Exception as e:
                status["qdrant"] = {"connected": False, "error": str(e)}
        else:
            status["qdrant"] = {"connected": False}
        return status

    def phase_start(self, name: str, context: Optional[str] = None, parent: Optional[int] = None) -> Dict:
        conn = self._ensure_sqlite()
        cursor = conn.cursor()
        cursor.execute('INSERT INTO phases (phase_name, status, context, started_at, parent_phase_id) VALUES (?, "active", ?, CURRENT_TIMESTAMP, ?)', (name, context, parent))
        conn.commit()
        return {"status": "started", "phase_id": cursor.lastrowid}

    def phase_complete(self, phase_id: int) -> Dict:
        conn = self._ensure_sqlite()
        cursor = conn.cursor()
        cursor.execute('UPDATE phases SET status = "completed", completed_at = CURRENT_TIMESTAMP WHERE id = ?', (phase_id,))
        conn.commit()
        return {"status": "completed", "phase_id": phase_id}

    def phase_list(self) -> Dict:
        conn = self._ensure_sqlite()
        cursor = conn.cursor()
        cursor.execute('SELECT id, phase_name, status FROM phases ORDER BY id DESC LIMIT 20')
        return {"phases": [{"id": r[0], "name": r[1], "status": r[2]} for r in cursor.fetchall()]}

    def agent_register(self, name: str, agent_type: str = 'subagent') -> Dict:
        conn = self._ensure_sqlite()
        cursor = conn.cursor()
        cursor.execute('INSERT INTO agents (agent_name, agent_type) VALUES (?, ?) ON CONFLICT(agent_name) DO UPDATE SET last_active=CURRENT_TIMESTAMP', (name, agent_type))
        conn.commit()
        return {"status": "registered", "agent": name}

    def agent_status(self, name: str, status: str, task: Optional[str] = None, session: Optional[str] = None) -> Dict:
        conn = self._ensure_sqlite()
        cursor = conn.cursor()
        cursor.execute('UPDATE agents SET status = ?, current_task = ?, session_id = ?, last_active = CURRENT_TIMESTAMP WHERE agent_name = ?', (status, task, session, name))
        conn.commit()
        return {"status": "updated"}

    def agent_list(self) -> Dict:
        conn = self._ensure_sqlite()
        cursor = conn.cursor()
        cursor.execute('SELECT agent_name, agent_type, status, current_task FROM agents')
        return {"agents": [{"name": r[0], "type": r[1], "status": r[2], "task": r[3]} for r in cursor.fetchall()]}

    def task_add(self, desc: str, priority: int = 5) -> Dict:
        conn = self._ensure_sqlite()
        cursor = conn.cursor()
        cursor.execute('INSERT INTO tasks (task_description, priority) VALUES (?, ?)', (desc, priority))
        conn.commit()
        return {"status": "added", "task_id": cursor.lastrowid}

    def task_assign(self, task_id: int, agent: str) -> Dict:
        conn = self._ensure_sqlite()
        cursor = conn.cursor()
        cursor.execute('UPDATE tasks SET assigned_agent = ?, status = "assigned", started_at = CURRENT_TIMESTAMP WHERE id = ?', (agent, task_id))
        conn.commit()
        return {"status": "assigned"}

    def task_complete(self, task_id: int, result: Optional[str] = None) -> Dict:
        conn = self._ensure_sqlite()
        cursor = conn.cursor()
        cursor.execute('UPDATE tasks SET status = "completed", result = ?, completed_at = CURRENT_TIMESTAMP WHERE id = ?', (result, task_id))
        conn.commit()
        return {"status": "completed"}

    def task_queue(self) -> Dict:
        conn = self._ensure_sqlite()
        cursor = conn.cursor()
        cursor.execute('SELECT id, task_description, assigned_agent, status, priority FROM tasks WHERE status IN ("queued", "assigned") ORDER BY priority DESC')
        return {"queue": [{"id": r[0], "desc": r[1], "agent": r[2], "status": r[3], "priority": r[4]} for r in cursor.fetchall()]}

    def snapshot_save(self, name: str, data: str = '{}', snap_type: str = 'manual') -> Dict:
        conn = self._ensure_sqlite()
        cursor = conn.cursor()
        cursor.execute('INSERT INTO context_snapshots (snapshot_name, snapshot_type, context_data) VALUES (?, ?, ?)', (name, snap_type, data))
        conn.commit()
        return {"status": "saved", "snapshot_id": cursor.lastrowid}

    def snapshot_load(self, name: str) -> str:
        conn = self._ensure_sqlite()
        cursor = conn.cursor()
        cursor.execute('SELECT context_data FROM context_snapshots WHERE snapshot_name = ? ORDER BY id DESC LIMIT 1', (name,))
        row = cursor.fetchone()
        return row[0] if row else json.dumps({"error": "not found"})

    def learning_add(self, ltype: str, content: str, phase_id: Optional[int] = None) -> Dict:
        conn = self._ensure_sqlite()
        cursor = conn.cursor()
        cursor.execute('INSERT INTO learnings (learning_type, content, source_phase) VALUES (?, ?, ?)', (ltype, content, phase_id))
        conn.commit()
        lid = cursor.lastrowid
        if self._store_in_qdrant(f"learning_{lid}", content, f"learning_{ltype}"):
            cursor.execute('UPDATE learnings SET vector_synced = 1 WHERE id = ?', (lid,))
            conn.commit()
        return {"status": "added", "learning_id": lid}

    def learnings_export(self) -> Dict:
        conn = self._ensure_sqlite()
        cursor = conn.cursor()
        cursor.execute('SELECT id, learning_type, content, created_at FROM learnings WHERE exported = 0')
        rows = cursor.fetchall()
        if rows:
            ids = [r[0] for r in rows]
            cursor.execute(f'UPDATE learnings SET exported = 1 WHERE id IN ({",".join("?" * len(ids))})', ids)
            conn.commit()
        return {"learnings": [{"id": r[0], "type": r[1], "content": r[2], "created_at": r[3]} for r in rows]}

    def compact_summary(self, trigger: str = 'auto') -> Dict:
        conn = self._ensure_sqlite()
        cursor = conn.cursor()
        cursor.execute('SELECT key, value, category FROM memory')
        memories = cursor.fetchall()
        cursor.execute('SELECT id, phase_name, status FROM phases WHERE status = "active"')
        phases = cursor.fetchall()
        summary = {
            "trigger": trigger, "timestamp": datetime.now().isoformat(),
            "memories": {r[0]: {"value": r[1], "category": r[2]} for r in memories},
            "active_phases": [{"id": r[0], "name": r[1], "status": r[2]} for r in phases]
        }
        cursor.execute('INSERT INTO compaction_log (trigger_type, summary, memories_count, phases_count) VALUES (?, ?, ?, ?)',
                       (trigger, json.dumps(summary), len(memories), len(phases)))
        cursor.execute('INSERT INTO context_snapshots (snapshot_name, snapshot_type, context_data) VALUES (?, ?, ?)',
                       (f"pre-compact-{datetime.now().strftime('%Y%m%d-%H%M%S')}", f"pre-compact-{trigger}", json.dumps(summary)))
        conn.commit()
        return summary

    def dump(self) -> Dict:
        conn = self._ensure_sqlite()
        cursor = conn.cursor()
        cursor.execute('SELECT key, value, category FROM memory')
        memories = cursor.fetchall()
        cursor.execute('SELECT id, phase_name, status FROM phases WHERE status = "active"')
        phases = cursor.fetchall()
        cursor.execute('SELECT agent_name, status, current_task FROM agents WHERE status != "idle"')
        agents = cursor.fetchall()
        cursor.execute('SELECT id, task_description, status FROM tasks WHERE status IN ("queued", "assigned") LIMIT 10')
        tasks = cursor.fetchall()
        return {
            "memories": {r[0]: {"value": r[1], "category": r[2]} for r in memories},
            "active_phases": [{"id": r[0], "name": r[1], "status": r[2]} for r in phases],
            "active_agents": [{"name": r[0], "status": r[1], "task": r[2]} for r in agents],
            "pending_tasks": [{"id": r[0], "desc": r[1], "status": r[2]} for r in tasks]
        }

    def dump_compact(self) -> str:
        conn = self._ensure_sqlite()
        cursor = conn.cursor()
        cursor.execute('SELECT key, value FROM memory ORDER BY updated_at DESC LIMIT 50')
        memories = cursor.fetchall()
        cursor.execute('SELECT phase_name, status FROM phases WHERE status = "active"')
        phases = cursor.fetchall()
        output = []
        if memories:
            output.append("MEMORY:")
            for k, v in memories:
                output.append(f"  {k}: {v[:200]}{'...' if len(v) > 200 else ''}")
        if phases:
            output.append("ACTIVE PHASES:")
            for name, status in phases:
                output.append(f"  - {name} ({status})")
        return "\n".join(output) if output else "No memory state"

    def close(self):
        if self.sqlite_conn:
            self.sqlite_conn.close()


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "Usage: memory-db.py <command> [args]"}))
        sys.exit(1)
    cmd = sys.argv[1]
    manager = HybridMemoryManager()
    try:
        if cmd == "init":
            manager._ensure_sqlite()
            manager._ensure_qdrant()
            print(json.dumps({"status": "initialized", "db_path": str(manager._get_sqlite_path())}))
        elif cmd == "set":
            if len(sys.argv) < 4:
                print(json.dumps({"error": "Usage: set <key> <value> [category]"}))
                sys.exit(1)
            result = manager.set(sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else 'general')
            print(json.dumps(result))
        elif cmd == "get":
            if len(sys.argv) < 3:
                print(json.dumps({"error": "Usage: get <key>"}))
                sys.exit(1)
            print(json.dumps(manager.get(sys.argv[2])))
        elif cmd == "delete":
            if len(sys.argv) < 3:
                print(json.dumps({"error": "Usage: delete <key>"}))
                sys.exit(1)
            print(json.dumps(manager.delete(sys.argv[2])))
        elif cmd == "list":
            print(json.dumps(manager.list(sys.argv[2] if len(sys.argv) > 2 else None)))
        elif cmd == "search":
            if len(sys.argv) < 3:
                print(json.dumps({"error": "Usage: search <query>"}))
                sys.exit(1)
            print(json.dumps(manager.hybrid_search(sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 5), indent=2))
        elif cmd == "semantic-search":
            if len(sys.argv) < 3:
                print(json.dumps({"error": "Usage: semantic-search <query>"}))
                sys.exit(1)
            print(json.dumps(manager.semantic_search(sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 5), indent=2))
        elif cmd == "context-for":
            if len(sys.argv) < 3:
                print(json.dumps({"error": "Usage: context-for <topic>"}))
                sys.exit(1)
            print(manager.context_for(sys.argv[2]))
        elif cmd == "sync-vectors":
            print(json.dumps(manager.sync_vectors(), indent=2))
        elif cmd == "status":
            print(json.dumps(manager.status(), indent=2))
        elif cmd == "phase-start":
            if len(sys.argv) < 3:
                print(json.dumps({"error": "Usage: phase-start <name>"}))
                sys.exit(1)
            print(json.dumps(manager.phase_start(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None, int(sys.argv[4]) if len(sys.argv) > 4 else None)))
        elif cmd == "phase-complete":
            if len(sys.argv) < 3:
                print(json.dumps({"error": "Usage: phase-complete <id>"}))
                sys.exit(1)
            print(json.dumps(manager.phase_complete(int(sys.argv[2]))))
        elif cmd == "phase-list":
            print(json.dumps(manager.phase_list()))
        elif cmd == "agent-register":
            if len(sys.argv) < 3:
                print(json.dumps({"error": "Usage: agent-register <name>"}))
                sys.exit(1)
            print(json.dumps(manager.agent_register(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else 'subagent')))
        elif cmd == "agent-status":
            if len(sys.argv) < 4:
                print(json.dumps({"error": "Usage: agent-status <name> <status>"}))
                sys.exit(1)
            print(json.dumps(manager.agent_status(sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else None, sys.argv[5] if len(sys.argv) > 5 else None)))
        elif cmd == "agent-list":
            print(json.dumps(manager.agent_list()))
        elif cmd == "task-add":
            if len(sys.argv) < 3:
                print(json.dumps({"error": "Usage: task-add <desc>"}))
                sys.exit(1)
            print(json.dumps(manager.task_add(sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 5)))
        elif cmd == "task-assign":
            if len(sys.argv) < 4:
                print(json.dumps({"error": "Usage: task-assign <id> <agent>"}))
                sys.exit(1)
            print(json.dumps(manager.task_assign(int(sys.argv[2]), sys.argv[3])))
        elif cmd == "task-complete":
            if len(sys.argv) < 3:
                print(json.dumps({"error": "Usage: task-complete <id>"}))
                sys.exit(1)
            print(json.dumps(manager.task_complete(int(sys.argv[2]), sys.argv[3] if len(sys.argv) > 3 else None)))
        elif cmd == "task-queue":
            print(json.dumps(manager.task_queue()))
        elif cmd == "snapshot-save":
            if len(sys.argv) < 3:
                print(json.dumps({"error": "Usage: snapshot-save <name>"}))
                sys.exit(1)
            print(json.dumps(manager.snapshot_save(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else '{}', sys.argv[4] if len(sys.argv) > 4 else 'manual')))
        elif cmd == "snapshot-load":
            if len(sys.argv) < 3:
                print(json.dumps({"error": "Usage: snapshot-load <name>"}))
                sys.exit(1)
            print(manager.snapshot_load(sys.argv[2]))
        elif cmd == "learning-add":
            if len(sys.argv) < 4:
                print(json.dumps({"error": "Usage: learning-add <type> <content>"}))
                sys.exit(1)
            print(json.dumps(manager.learning_add(sys.argv[2], sys.argv[3], int(sys.argv[4]) if len(sys.argv) > 4 else None)))
        elif cmd == "learnings-export":
            print(json.dumps(manager.learnings_export()))
        elif cmd == "compact-summary":
            print(json.dumps(manager.compact_summary(sys.argv[2] if len(sys.argv) > 2 else 'auto'), indent=2))
        elif cmd == "dump":
            print(json.dumps(manager.dump(), indent=2))
        elif cmd == "dump-compact":
            print(manager.dump_compact())
        else:
            print(json.dumps({"error": f"Unknown command: {cmd}"}))
            sys.exit(1)
    except Exception as e:
        print(json.dumps({"error": str(e)}))
        sys.exit(1)
    finally:
        manager.close()

if __name__ == "__main__":
    main()
MEMORY_SCRIPT

chmod +x "$SCRIPTS_DIR/memory-db.py"

#===============================================================================
# HEADLESS AGENT SPAWNER SCRIPT
#===============================================================================
cat > "$SCRIPTS_DIR/spawn-agent.sh" << 'SPAWN_SCRIPT'
#!/bin/bash
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
nohup claude -p "$TASK_PROMPT" --output-format stream-json --allowedTools "Read,Write,Edit,Bash,Grep,Glob" > "$LOG_DIR/${AGENT_NAME}-${SESSION_ID}.log" 2>&1 &
AGENT_PID=$!
echo "$AGENT_PID" > "$LOG_DIR/${AGENT_NAME}.pid"
echo "{\"agent\": \"$AGENT_NAME\", \"session_id\": \"$SESSION_ID\", \"pid\": $AGENT_PID}"
(wait $AGENT_PID 2>/dev/null; python3 "$MEMORY_SCRIPT" agent-status "$AGENT_NAME" "completed" "" "$SESSION_ID" 2>/dev/null) &
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
    search) python3 "$MEMORY_SCRIPT" search "$2" "${3:-5}" ;;
    semantic) python3 "$MEMORY_SCRIPT" semantic-search "$2" "${3:-5}" ;;
    sync) python3 "$MEMORY_SCRIPT" sync-vectors ;;
    *) echo "Commands: spawn|status|tasks|add-task|assign|complete|logs|tail|kill|killall|swarm|search|semantic|sync" ;;
esac
HIVEMIND_SCRIPT

chmod +x "$SCRIPTS_DIR/hivemind.sh"

#===============================================================================
# SESSION START HOOK - V3: Now includes semantic context injection
#===============================================================================
cat > "$HOOKS_DIR/session-start.sh" << 'SESSION_HOOK'
#!/bin/bash
MEMORY_SCRIPT="$HOME/.claude/scripts/memory-db.py"
python3 "$MEMORY_SCRIPT" init >/dev/null 2>&1

INPUT=$(cat)
CWD=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('cwd',''))" 2>/dev/null || echo "")
PROJECT=$(basename "$CWD" 2>/dev/null || echo "general")

# Get compact memory state
CONTEXT=$(python3 "$MEMORY_SCRIPT" dump-compact 2>/dev/null)

# Get semantic context for current project
SEMANTIC=$(python3 "$MEMORY_SCRIPT" context-for "$PROJECT" 2>/dev/null || echo "")

# Combine contexts
FULL_CONTEXT="$CONTEXT"
[ -n "$SEMANTIC" ] && FULL_CONTEXT="$CONTEXT

$SEMANTIC"

if [ -n "$FULL_CONTEXT" ] && [ "$FULL_CONTEXT" != "No memory state" ]; then
    CONTEXT_ESCAPED=$(echo "$FULL_CONTEXT" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')
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
# PRE-COMPACT HOOK
#===============================================================================
cat > "$HOOKS_DIR/pre-compact.sh" << 'PRECOMPACT_HOOK'
#!/bin/bash
MEMORY_SCRIPT="$HOME/.claude/scripts/memory-db.py"
BACKUP_DIR="$HOME/.claude/memory/compact-backups"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p "$BACKUP_DIR"
INPUT=$(cat)
TRIGGER=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('trigger','unknown'))" 2>/dev/null || echo "unknown")
python3 "$MEMORY_SCRIPT" compact-summary "$TRIGGER" > "$BACKUP_DIR/pre-compact-$TIMESTAMP.json" 2>/dev/null
echo "Memory saved before $TRIGGER compaction" >&2
exit 0
PRECOMPACT_HOOK

chmod +x "$HOOKS_DIR/pre-compact.sh"

#===============================================================================
# STOP HOOK - V3: Exports learnings and syncs vectors
#===============================================================================
cat > "$HOOKS_DIR/stop-autosave.sh" << 'STOP_HOOK'
#!/bin/bash
MEMORY_SCRIPT="$HOME/.claude/scripts/memory-db.py"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

INPUT=$(cat)
ACTIVE=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('stop_hook_active', False))" 2>/dev/null || echo "False")
[ "$ACTIVE" = "True" ] && exit 0

python3 "$MEMORY_SCRIPT" snapshot-save "auto-$TIMESTAMP" '{}' "auto-stop" 2>/dev/null
python3 "$MEMORY_SCRIPT" sync-vectors 2>/dev/null

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
echo "[$TIMESTAMP] Session $SESSION_ID ended" >> "$LOG_FILE"
python3 "$MEMORY_SCRIPT" snapshot-save "session-end-$TIMESTAMP" '{}' "session-end" 2>/dev/null
exit 0
SESSION_END_HOOK

chmod +x "$HOOKS_DIR/session-end.sh"

#===============================================================================
# SETTINGS.JSON - V3
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
    "SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "~/.claude/hooks/session-start.sh", "timeout": 15}]}],
    "PreCompact": [
      {"matcher": "auto", "hooks": [{"type": "command", "command": "~/.claude/hooks/pre-compact.sh", "timeout": 30}]},
      {"matcher": "manual", "hooks": [{"type": "command", "command": "~/.claude/hooks/pre-compact.sh", "timeout": 30}]}
    ],
    "Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "~/.claude/hooks/stop-autosave.sh", "timeout": 20}]}],
    "SessionEnd": [{"matcher": "", "hooks": [{"type": "command", "command": "~/.claude/hooks/session-end.sh", "timeout": 10}]}]
  },
  "env": {"CLAUDE_HIVEMIND_ENABLED": "1", "PYTHONUNBUFFERED": "1"}
}
SETTINGS_JSON

#===============================================================================
# SLASH COMMANDS - V3: Added semantic search commands
#===============================================================================
cat > "$COMMANDS_DIR/hivemind.md" << 'EOF'
---
description: Manage hivemind agents and search
argument-hint: [status|spawn|tasks|swarm|search|semantic|sync]
---
Run: `~/.claude/scripts/hivemind.sh $ARGUMENTS`
EOF

cat > "$COMMANDS_DIR/memory.md" << 'EOF'
---
description: Access hybrid memory database
argument-hint: [dump|set|get|list|search|status]
---
Run: `python3 ~/.claude/scripts/memory-db.py $ARGUMENTS`
EOF

cat > "$COMMANDS_DIR/learn.md" << 'EOF'
---
description: Record a learning (auto-vectorized)
argument-hint: <type> <content>
---
Run: `python3 ~/.claude/scripts/memory-db.py learning-add $ARGUMENTS`
Types: decision, pattern, convention, bug, optimization
EOF

cat > "$COMMANDS_DIR/search.md" << 'EOF'
---
description: Hybrid keyword + semantic search
argument-hint: <query> [limit]
---
Run: `python3 ~/.claude/scripts/memory-db.py search $ARGUMENTS`
EOF

cat > "$COMMANDS_DIR/semantic.md" << 'EOF'
---
description: Pure semantic vector search
argument-hint: <query> [limit]
---
Run: `python3 ~/.claude/scripts/memory-db.py semantic-search $ARGUMENTS`
EOF

cat > "$COMMANDS_DIR/remember.md" << 'EOF'
---
description: Store in hybrid memory (SQLite + Qdrant)
argument-hint: <key> <value> [category]
---
Run: `python3 ~/.claude/scripts/memory-db.py set $ARGUMENTS`
Categories: general, decision, pattern, architecture, bug, learning
EOF

cat > "$COMMANDS_DIR/memory-status.md" << 'EOF'
---
description: Check SQLite and Qdrant status
---
Run: `python3 ~/.claude/scripts/memory-db.py status`
EOF

#===============================================================================
# MODULAR MEMORY FILES
#===============================================================================
cat > "$MEMORY_DIR/commands.md" << 'EOF'
# Memory Commands (V3 - Hybrid)
```bash
# Core (dual-write to SQLite + Qdrant)
memory-db.py set <key> <value> [category]
memory-db.py get <key>
memory-db.py list [category]
memory-db.py delete <key>
memory-db.py dump

# Search
memory-db.py search <query>           # Hybrid (semantic + keyword)
memory-db.py semantic-search <query>  # Vector-only
memory-db.py context-for <topic>      # Context injection

# Sync
memory-db.py sync-vectors             # Sync SQLite to Qdrant
memory-db.py status                   # Both DB status

# Phases
memory-db.py phase-start "Name" "{}" [parent_id]
memory-db.py phase-complete <id>

# Learnings (auto-vectorized)
memory-db.py learning-add <type> "<content>"
# Types: decision, pattern, convention, bug, optimization
```
EOF

cat > "$MEMORY_DIR/hivemind.md" << 'EOF'
# Hivemind Commands (V3)
```bash
# Agents
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

# Search (integrated)
hivemind.sh search "<query>" [limit]
hivemind.sh semantic "<query>" [limit]
hivemind.sh sync                      # Sync vectors
```
EOF

#===============================================================================
# GLOBAL CLAUDE.MD - V3 with hybrid memory
#===============================================================================
cat > "$CLAUDE_DIR/CLAUDE.md" << 'GLOBAL_CLAUDE_MD'
# Claude Code Hivemind V3 - Hybrid Memory

## Automatic Persistence

- **SessionStart**: Inits DBs, loads memory + semantic context
- **PreCompact**: Saves full state before auto/manual compaction
- **Stop**: Snapshots + exports learnings + syncs vectors
- **SessionEnd**: Logs session, final snapshot

## Hybrid Memory (SQLite + Qdrant)

All memory operations write to both databases:
- **SQLite**: Structured queries, metadata, relationships
- **Qdrant**: Semantic vector search for intelligent retrieval

```bash
# Store (dual-write)
python3 ~/.claude/scripts/memory-db.py set "key" "content" "category"

# Hybrid search (semantic + keyword)
python3 ~/.claude/scripts/memory-db.py search "query"

# Pure semantic search
python3 ~/.claude/scripts/memory-db.py semantic-search "query"

# Get context for topic
python3 ~/.claude/scripts/memory-db.py context-for "topic"

# Status of both DBs
python3 ~/.claude/scripts/memory-db.py status
```

## Record Learnings (Auto-Vectorized)

```bash
python3 ~/.claude/scripts/memory-db.py learning-add decision "Chose X because Y"
python3 ~/.claude/scripts/memory-db.py learning-add pattern "Always check for..."
python3 ~/.claude/scripts/memory-db.py learning-add bug "Issue when..."
```

## Quick Reference

@~/.claude/memory/commands.md
@~/.claude/memory/hivemind.md

## Slash Commands

- `/memory` - Core memory operations
- `/search` - Hybrid search
- `/semantic` - Pure semantic search
- `/remember` - Store in memory
- `/learn` - Record learnings
- `/memory-status` - Check both DBs
- `/hivemind` - Agent management
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
Search related: memory-db.py search "query"
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
Search: memory-db.py search "related topic"
EOF

cat > "$AGENTS_DIR/implementer.md" << 'EOF'
---
name: implementer
description: Use for code implementation from specifications
tools: Read, Write, Edit, Bash, Grep, Glob
model: sonnet
---
Implementation specialist.
1. Load context: memory-db.py context-for "<feature>"
2. Search related: memory-db.py search "<keywords>"
3. Implement per specs
4. Store: memory-db.py set "impl_<feature>" "<notes>" "implementation"
5. Record: memory-db.py learning-add pattern "<what learned>"
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
# QDRANT SETUP (if requested)
#===============================================================================
if [ "$QDRANT_MODE" != "none" ]; then
    echo ""
    echo "==> Setting up Qdrant vector database..."
    
    # Install Python dependencies
    echo "    Installing Python dependencies..."
    pip3 install --user --upgrade qdrant-client sentence-transformers 2>/dev/null || {
        echo "    WARNING: pip3 install failed, trying without --user..."
        pip3 install qdrant-client sentence-transformers 2>/dev/null || {
            echo "    WARNING: Could not install dependencies. Install manually:"
            echo "             pip3 install qdrant-client sentence-transformers"
        }
    }
    
    if [ "$QDRANT_MODE" = "docker" ]; then
        echo "    Setting up Docker-based Qdrant..."
        if command -v docker &> /dev/null; then
            QDRANT_DATA="$CLAUDE_DIR/qdrant_data"
            mkdir -p "$QDRANT_DATA"
            
            if ! docker ps -a --format '{{.Names}}' | grep -q '^hivemind-qdrant$'; then
                docker pull qdrant/qdrant:latest 2>/dev/null
                docker run -d --name hivemind-qdrant --restart unless-stopped \
                    -p 6333:6333 -p 6334:6334 \
                    -v "${QDRANT_DATA}:/qdrant/storage" \
                    qdrant/qdrant:latest 2>/dev/null
                echo "    Qdrant container created"
            else
                docker start hivemind-qdrant 2>/dev/null || true
                echo "    Qdrant container started"
            fi
        else
            echo "    WARNING: Docker not found. Install docker or use --with-qdrant-file"
        fi
    else
        echo "    Setting up file-based Qdrant storage..."
        mkdir -p "$CLAUDE_DIR/qdrant_data"
        
        # Add to shell config
        SHELL_RC=""
        [ -f "$HOME/.bashrc" ] && SHELL_RC="$HOME/.bashrc"
        [ -f "$HOME/.zshrc" ] && SHELL_RC="$HOME/.zshrc"
        
        if [ -n "$SHELL_RC" ] && ! grep -q "QDRANT_FILE_STORAGE" "$SHELL_RC"; then
            echo "" >> "$SHELL_RC"
            echo "# Qdrant file-based storage for Hivemind" >> "$SHELL_RC"
            echo "export QDRANT_FILE_STORAGE=1" >> "$SHELL_RC"
            echo "    Added QDRANT_FILE_STORAGE=1 to $SHELL_RC"
        fi
        export QDRANT_FILE_STORAGE=1
    fi
fi

#===============================================================================
# FINALIZE
#===============================================================================
python3 "$SCRIPTS_DIR/memory-db.py" init 2>/dev/null || true

echo ""
echo "==> Claude Code Hivemind V3 Complete!"
echo ""
echo "V3 FEATURES:"
echo "  ✓ Hybrid memory: SQLite + Qdrant vector search"
echo "  ✓ Semantic search with sentence-transformers"
echo "  ✓ Auto-vectorization of memories and learnings"
echo "  ✓ Context-aware memory injection in SessionStart"
echo "  ✓ Automatic vector sync on session Stop"
echo ""
echo "V2 FIXES (inherited):"
echo "  ✓ PreCompact hook - saves state before compaction"
echo "  ✓ SessionStart - correct hookSpecificOutput format"
echo "  ✓ Stop hook - exports learnings to project CLAUDE.md"
echo "  ✓ SessionEnd hook - cleanup and logging"
echo ""

if [ "$QDRANT_MODE" = "docker" ]; then
    echo "Qdrant: Docker (http://localhost:6333)"
elif [ "$QDRANT_MODE" = "file" ]; then
    echo "Qdrant: File-based (~/.claude/qdrant_data)"
else
    echo "Qdrant: Disabled"
fi

echo ""
echo "Test:"
echo "  python3 ~/.claude/scripts/memory-db.py set test 'hello world' testing"
echo "  python3 ~/.claude/scripts/memory-db.py search 'hello'"
echo "  python3 ~/.claude/scripts/memory-db.py status"
echo ""
echo "IMPORTANT: Run 'claude' and use /hooks to approve new hooks!"
