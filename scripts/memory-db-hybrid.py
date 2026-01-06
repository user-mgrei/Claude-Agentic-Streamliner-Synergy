#!/usr/bin/env python3
"""
Claude Code SQLite + Qdrant Hybrid Memory Manager V3

Provides persistent memory storage between phases/sessions with both:
  - SQLite: Structured data, metadata, relationships
  - Qdrant: Semantic vector search for intelligent retrieval

Database locations:
  - SQLite: $PROJECT_DIR/.claude/claude.db or ~/.claude/claude.db
  - Qdrant: localhost:6333 or ~/.claude/qdrant_data (file mode)

Enhanced in V3 (Qdrant Integration):
  - Automatic dual-write to SQLite + Qdrant
  - Hybrid search combining keyword + semantic results
  - Smart context injection with relevance scoring
  - Background sync for existing SQLite data
  - Graceful degradation when Qdrant unavailable

Usage:
  memory-db-hybrid.py set <key> <value> [category]
  memory-db-hybrid.py get <key>
  memory-db-hybrid.py search <query>              # Hybrid search
  memory-db-hybrid.py semantic-search <query>     # Vector-only search
  memory-db-hybrid.py context-for <topic>         # Smart context injection
  memory-db-hybrid.py sync-vectors               # Sync SQLite to Qdrant
  memory-db-hybrid.py status                     # Show both DB status
"""

import sqlite3
import json
import sys
import os
import hashlib
from datetime import datetime
from pathlib import Path
from typing import Optional, List, Dict, Any, Tuple

# Optional Qdrant imports
try:
    from qdrant_client import QdrantClient
    from qdrant_client.models import (
        Distance, VectorParams, PointStruct, Filter,
        FieldCondition, MatchValue, MatchText
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
        """Determine SQLite database path."""
        project_dir = os.environ.get('CLAUDE_PROJECT_DIR', os.getcwd())
        project_db = Path(project_dir) / '.claude' / 'claude.db'
        global_db = Path.home() / '.claude' / 'claude.db'
        
        if (Path(project_dir) / '.claude').exists():
            return project_db
        return global_db
        
    def _get_qdrant_path(self) -> Path:
        """Determine Qdrant file storage path."""
        project_dir = os.environ.get('CLAUDE_PROJECT_DIR', os.getcwd())
        project_qdrant = Path(project_dir) / '.claude' / 'qdrant_data'
        global_qdrant = Path.home() / '.claude' / 'qdrant_data'
        
        if (Path(project_dir) / '.claude').exists():
            return project_qdrant
        return global_qdrant
        
    def _ensure_sqlite(self) -> sqlite3.Connection:
        """Ensure SQLite connection exists."""
        if self.sqlite_conn is None:
            db_path = self._get_sqlite_path()
            db_path.parent.mkdir(parents=True, exist_ok=True)
            self.sqlite_conn = sqlite3.connect(str(db_path))
            self._init_sqlite_schema()
        return self.sqlite_conn
        
    def _init_sqlite_schema(self):
        """Initialize SQLite schema (from V2)."""
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
            CREATE INDEX IF NOT EXISTS idx_learnings_vector_synced ON learnings(vector_synced);
        ''')
        self.sqlite_conn.commit()
        
    def _ensure_qdrant(self) -> bool:
        """Lazily initialize Qdrant connection."""
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
                self.qdrant_client.get_collections()  # Test connection
                
            # Initialize embedding model
            if EMBEDDINGS_AVAILABLE:
                self.embedding_model = SentenceTransformer(EMBEDDING_MODEL)
                
            # Ensure collection exists
            self._ensure_qdrant_collection()
            
            self._qdrant_initialized = True
            return True
        except Exception as e:
            self._qdrant_initialized = True
            return False
            
    def _ensure_qdrant_collection(self):
        """Create Qdrant collection if not exists."""
        if not self.qdrant_client:
            return
            
        collections = self.qdrant_client.get_collections().collections
        if not any(c.name == COLLECTION_NAME for c in collections):
            self.qdrant_client.create_collection(
                collection_name=COLLECTION_NAME,
                vectors_config=VectorParams(
                    size=EMBEDDING_DIM,
                    distance=Distance.COSINE
                )
            )
            
    def _generate_embedding(self, text: str) -> List[float]:
        """Generate embedding vector."""
        if not self.embedding_model:
            raise RuntimeError("Embedding model not available")
        return self.embedding_model.encode(text).tolist()
        
    def _generate_id(self, key: str) -> str:
        """Generate deterministic ID from key."""
        return hashlib.md5(key.encode()).hexdigest()
        
    def _store_in_qdrant(self, key: str, content: str, category: str, 
                         metadata: Optional[Dict] = None) -> bool:
        """Store content in Qdrant with embedding."""
        if not self._ensure_qdrant() or not self.embedding_model:
            return False
            
        try:
            embedding = self._generate_embedding(content)
            payload = {
                "key": key,
                "content": content,
                "category": category,
                "created_at": datetime.now().isoformat(),
                "content_hash": hashlib.sha256(content.encode()).hexdigest()[:16]
            }
            if metadata:
                payload.update(metadata)
                
            self.qdrant_client.upsert(
                collection_name=COLLECTION_NAME,
                points=[PointStruct(
                    id=self._generate_id(key),
                    vector=embedding,
                    payload=payload
                )]
            )
            return True
        except Exception:
            return False
            
    # =========================================================================
    # Core Memory Operations (Hybrid)
    # =========================================================================
    
    def set(self, key: str, value: str, category: str = 'general') -> Dict[str, Any]:
        """Store key-value in both SQLite and Qdrant."""
        conn = self._ensure_sqlite()
        cursor = conn.cursor()
        
        # Store in SQLite
        cursor.execute('''
            INSERT INTO memory (key, value, category, updated_at, vector_synced) 
            VALUES (?, ?, ?, CURRENT_TIMESTAMP, 0)
            ON CONFLICT(key) DO UPDATE SET 
                value=excluded.value, 
                category=excluded.category,
                updated_at=CURRENT_TIMESTAMP,
                vector_synced=0
        ''', (key, value, category))
        conn.commit()
        
        # Store in Qdrant (async-safe, non-blocking on failure)
        qdrant_synced = self._store_in_qdrant(key, value, category)
        
        if qdrant_synced:
            cursor.execute('UPDATE memory SET vector_synced = 1 WHERE key = ?', (key,))
            conn.commit()
            
        return {
            "status": "set",
            "key": key,
            "category": category,
            "sqlite": True,
            "qdrant": qdrant_synced
        }
        
    def get(self, key: str) -> Dict[str, Any]:
        """Get value by exact key from SQLite."""
        conn = self._ensure_sqlite()
        cursor = conn.cursor()
        cursor.execute(
            'SELECT value, category, updated_at, vector_synced FROM memory WHERE key = ?', 
            (key,)
        )
        row = cursor.fetchone()
        
        if row:
            return {
                "key": key,
                "value": row[0],
                "category": row[1],
                "updated_at": row[2],
                "vector_synced": bool(row[3])
            }
        return {"key": key, "value": None}
        
    def delete(self, key: str) -> Dict[str, Any]:
        """Delete from both SQLite and Qdrant."""
        conn = self._ensure_sqlite()
        cursor = conn.cursor()
        
        cursor.execute('DELETE FROM memory WHERE key = ?', (key,))
        conn.commit()
        deleted_sqlite = cursor.rowcount > 0
        
        deleted_qdrant = False
        if self._ensure_qdrant():
            try:
                self.qdrant_client.delete(
                    collection_name=COLLECTION_NAME,
                    points_selector=[self._generate_id(key)]
                )
                deleted_qdrant = True
            except Exception:
                pass
                
        return {
            "status": "deleted" if deleted_sqlite else "not_found",
            "key": key,
            "sqlite": deleted_sqlite,
            "qdrant": deleted_qdrant
        }
        
    def list(self, category: Optional[str] = None) -> Dict[str, Any]:
        """List memories from SQLite, optionally filtered by category."""
        conn = self._ensure_sqlite()
        cursor = conn.cursor()
        
        if category:
            cursor.execute(
                'SELECT key, value, category, vector_synced FROM memory WHERE category = ?', 
                (category,)
            )
        else:
            cursor.execute('SELECT key, value, category, vector_synced FROM memory')
            
        rows = cursor.fetchall()
        return {
            "memories": [
                {
                    "key": r[0], 
                    "value": r[1], 
                    "category": r[2],
                    "vector_synced": bool(r[3])
                } 
                for r in rows
            ]
        }
        
    # =========================================================================
    # Semantic Search Operations
    # =========================================================================
    
    def semantic_search(self, query: str, limit: int = 5, 
                        category: Optional[str] = None,
                        score_threshold: float = 0.3) -> Dict[str, Any]:
        """Pure semantic search using Qdrant vectors."""
        if not self._ensure_qdrant() or not self.embedding_model:
            return {
                "error": "Qdrant not available",
                "results": [],
                "fallback": "Use 'search' for SQLite keyword search"
            }
            
        try:
            query_embedding = self._generate_embedding(query)
            
            query_filter = None
            if category:
                query_filter = Filter(must=[
                    FieldCondition(key="category", match=MatchValue(value=category))
                ])
                
            results = self.qdrant_client.search(
                collection_name=COLLECTION_NAME,
                query_vector=query_embedding,
                query_filter=query_filter,
                limit=limit,
                score_threshold=score_threshold,
                with_payload=True
            )
            
            return {
                "query": query,
                "results": [
                    {
                        "key": hit.payload.get("key"),
                        "content": hit.payload.get("content"),
                        "category": hit.payload.get("category"),
                        "score": round(hit.score, 4),
                        "source": "qdrant"
                    }
                    for hit in results
                ],
                "count": len(results)
            }
        except Exception as e:
            return {"error": str(e), "results": []}
            
    def keyword_search(self, query: str, limit: int = 10) -> Dict[str, Any]:
        """Keyword search using SQLite LIKE."""
        conn = self._ensure_sqlite()
        cursor = conn.cursor()
        
        # Search in key, value, and category
        search_pattern = f'%{query}%'
        cursor.execute('''
            SELECT key, value, category FROM memory 
            WHERE key LIKE ? OR value LIKE ? OR category LIKE ?
            ORDER BY updated_at DESC
            LIMIT ?
        ''', (search_pattern, search_pattern, search_pattern, limit))
        
        rows = cursor.fetchall()
        return {
            "query": query,
            "results": [
                {
                    "key": r[0],
                    "content": r[1],
                    "category": r[2],
                    "source": "sqlite"
                }
                for r in rows
            ],
            "count": len(rows)
        }
        
    def hybrid_search(self, query: str, limit: int = 5) -> Dict[str, Any]:
        """
        Hybrid search combining semantic and keyword results.
        Deduplicates and ranks by relevance.
        """
        # Get semantic results (if available)
        semantic_results = self.semantic_search(query, limit=limit * 2)
        
        # Get keyword results
        keyword_results = self.keyword_search(query, limit=limit * 2)
        
        # Combine and deduplicate
        seen_keys = set()
        combined = []
        
        # Add semantic results first (higher quality)
        for r in semantic_results.get("results", []):
            key = r.get("key")
            if key and key not in seen_keys:
                seen_keys.add(key)
                r["hybrid_rank"] = len(combined) + 1
                combined.append(r)
                
        # Add keyword results that weren't in semantic
        for r in keyword_results.get("results", []):
            key = r.get("key")
            if key and key not in seen_keys:
                seen_keys.add(key)
                r["score"] = 0.5  # Lower score for keyword-only matches
                r["hybrid_rank"] = len(combined) + 1
                combined.append(r)
                
        return {
            "query": query,
            "results": combined[:limit],
            "count": min(len(combined), limit),
            "semantic_available": not semantic_results.get("error"),
            "sources": {
                "semantic": len([r for r in combined if r.get("source") == "qdrant"]),
                "keyword": len([r for r in combined if r.get("source") == "sqlite"])
            }
        }
        
    def context_for(self, topic: str, max_tokens: int = 2000) -> str:
        """
        Generate context injection string for a topic.
        Combines hybrid search results into a coherent context block.
        """
        results = self.hybrid_search(topic, limit=10)
        
        if not results.get("results"):
            return ""
            
        context_parts = [f"## Relevant Memory: {topic}\n"]
        current_tokens = 50
        
        for r in results["results"]:
            content = r.get("content", "")
            estimated_tokens = len(content) // 4
            
            if current_tokens + estimated_tokens > max_tokens:
                break
                
            score = r.get("score", 0)
            key = r.get("key", "unknown")
            category = r.get("category", "general")
            
            context_parts.append(f"**{key}** [{category}] (relevance: {score:.2f}):")
            context_parts.append(f"  {content[:500]}{'...' if len(content) > 500 else ''}\n")
            current_tokens += estimated_tokens + 30
            
        return "\n".join(context_parts)
        
    # =========================================================================
    # Sync Operations
    # =========================================================================
    
    def sync_vectors(self) -> Dict[str, Any]:
        """Sync all unsynced SQLite memories to Qdrant."""
        if not self._ensure_qdrant():
            return {"error": "Qdrant not available"}
            
        conn = self._ensure_sqlite()
        cursor = conn.cursor()
        
        # Get unsynced memories
        cursor.execute('SELECT key, value, category FROM memory WHERE vector_synced = 0')
        memories = cursor.fetchall()
        
        # Get unsynced learnings
        cursor.execute('''
            SELECT id, learning_type, content FROM learnings 
            WHERE vector_synced = 0
        ''')
        learnings = cursor.fetchall()
        
        synced = 0
        errors = []
        
        for key, value, category in memories:
            if self._store_in_qdrant(key, value, category):
                cursor.execute('UPDATE memory SET vector_synced = 1 WHERE key = ?', (key,))
                synced += 1
            else:
                errors.append({"key": key, "type": "memory"})
                
        for learning_id, learning_type, content in learnings:
            key = f"learning_{learning_id}"
            if self._store_in_qdrant(key, content, f"learning_{learning_type}"):
                cursor.execute('UPDATE learnings SET vector_synced = 1 WHERE id = ?', (learning_id,))
                synced += 1
            else:
                errors.append({"key": key, "type": "learning"})
                
        conn.commit()
        
        return {
            "status": "synced",
            "synced_count": synced,
            "errors": errors if errors else None,
            "pending_memories": len(memories),
            "pending_learnings": len(learnings)
        }
        
    # =========================================================================
    # Status and Diagnostics
    # =========================================================================
    
    def status(self) -> Dict[str, Any]:
        """Get comprehensive status of both databases."""
        status = {
            "sqlite": {},
            "qdrant": {},
            "capabilities": {
                "qdrant_available": QDRANT_AVAILABLE,
                "embeddings_available": EMBEDDINGS_AVAILABLE
            }
        }
        
        # SQLite status
        try:
            conn = self._ensure_sqlite()
            cursor = conn.cursor()
            
            cursor.execute('SELECT COUNT(*) FROM memory')
            memory_count = cursor.fetchone()[0]
            
            cursor.execute('SELECT COUNT(*) FROM memory WHERE vector_synced = 0')
            unsynced_count = cursor.fetchone()[0]
            
            cursor.execute('SELECT COUNT(*) FROM learnings')
            learnings_count = cursor.fetchone()[0]
            
            status["sqlite"] = {
                "connected": True,
                "path": str(self._get_sqlite_path()),
                "memories": memory_count,
                "learnings": learnings_count,
                "unsynced_to_qdrant": unsynced_count
            }
        except Exception as e:
            status["sqlite"] = {"connected": False, "error": str(e)}
            
        # Qdrant status
        if self._ensure_qdrant():
            try:
                collection_info = self.qdrant_client.get_collection(COLLECTION_NAME)
                status["qdrant"] = {
                    "connected": True,
                    "storage": "file" if self.use_file_storage else "server",
                    "path": str(self._get_qdrant_path()) if self.use_file_storage else DEFAULT_QDRANT_URL,
                    "collection": COLLECTION_NAME,
                    "vectors_count": collection_info.vectors_count,
                    "status": collection_info.status.value
                }
            except Exception as e:
                status["qdrant"] = {"connected": False, "error": str(e)}
        else:
            status["qdrant"] = {
                "connected": False,
                "reason": "Dependencies not installed or server unavailable"
            }
            
        return status
        
    # =========================================================================
    # Phase/Task Operations (from V2, unchanged)
    # =========================================================================
    
    def phase_start(self, phase_name: str, context: Optional[str] = None,
                    parent_id: Optional[int] = None) -> Dict[str, Any]:
        """Start a new phase."""
        conn = self._ensure_sqlite()
        cursor = conn.cursor()
        cursor.execute('''
            INSERT INTO phases (phase_name, status, context, started_at, parent_phase_id)
            VALUES (?, 'active', ?, CURRENT_TIMESTAMP, ?)
        ''', (phase_name, context, parent_id))
        conn.commit()
        return {"status": "phase_started", "phase_id": cursor.lastrowid, "phase_name": phase_name}
        
    def phase_complete(self, phase_id: int) -> Dict[str, Any]:
        """Complete a phase."""
        conn = self._ensure_sqlite()
        cursor = conn.cursor()
        cursor.execute('''
            UPDATE phases SET status = 'completed', completed_at = CURRENT_TIMESTAMP
            WHERE id = ?
        ''', (phase_id,))
        conn.commit()
        return {"status": "phase_completed", "phase_id": phase_id}
        
    def phase_list(self) -> Dict[str, Any]:
        """List recent phases."""
        conn = self._ensure_sqlite()
        cursor = conn.cursor()
        cursor.execute('''
            SELECT id, phase_name, status, context, started_at, completed_at 
            FROM phases ORDER BY id DESC LIMIT 20
        ''')
        rows = cursor.fetchall()
        return {"phases": [
            {"id": r[0], "name": r[1], "status": r[2], "context": r[3], 
             "started": r[4], "completed": r[5]} 
            for r in rows
        ]}
        
    def learning_add(self, learning_type: str, content: str, 
                     phase_id: Optional[int] = None) -> Dict[str, Any]:
        """Add a learning with automatic vector storage."""
        conn = self._ensure_sqlite()
        cursor = conn.cursor()
        cursor.execute('''
            INSERT INTO learnings (learning_type, content, source_phase, vector_synced)
            VALUES (?, ?, ?, 0)
        ''', (learning_type, content, phase_id))
        conn.commit()
        learning_id = cursor.lastrowid
        
        # Try to store in Qdrant
        key = f"learning_{learning_id}"
        if self._store_in_qdrant(key, content, f"learning_{learning_type}"):
            cursor.execute('UPDATE learnings SET vector_synced = 1 WHERE id = ?', (learning_id,))
            conn.commit()
            
        return {"status": "added", "learning_id": learning_id}
        
    def dump(self) -> Dict[str, Any]:
        """Dump current state for context injection."""
        conn = self._ensure_sqlite()
        cursor = conn.cursor()
        
        cursor.execute('SELECT key, value, category FROM memory')
        memories = cursor.fetchall()
        
        cursor.execute('SELECT id, phase_name, status FROM phases WHERE status = "active"')
        active_phases = cursor.fetchall()
        
        cursor.execute('SELECT agent_name, status, current_task FROM agents WHERE status != "idle"')
        active_agents = cursor.fetchall()
        
        cursor.execute('''
            SELECT id, task_description, status FROM tasks 
            WHERE status IN ("queued", "assigned") LIMIT 10
        ''')
        pending_tasks = cursor.fetchall()
        
        return {
            "memories": {r[0]: {"value": r[1], "category": r[2]} for r in memories},
            "active_phases": [{"id": r[0], "name": r[1], "status": r[2]} for r in active_phases],
            "active_agents": [{"name": r[0], "status": r[1], "task": r[2]} for r in active_agents],
            "pending_tasks": [{"id": r[0], "desc": r[1], "status": r[2]} for r in pending_tasks]
        }
        
    def dump_compact(self) -> str:
        """Compact dump for minimal context injection."""
        conn = self._ensure_sqlite()
        cursor = conn.cursor()
        
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
                
        return "\n".join(output) if output else "No memory state"
        
    def close(self):
        """Close database connections."""
        if self.sqlite_conn:
            self.sqlite_conn.close()


def main():
    if len(sys.argv) < 2:
        print(json.dumps({
            "error": "Usage: memory-db-hybrid.py <command> [args]",
            "commands": {
                "Core": ["init", "set", "get", "delete", "list", "dump"],
                "Search": ["search", "semantic-search", "context-for"],
                "Sync": ["sync-vectors", "status"],
                "Phases": ["phase-start", "phase-complete", "phase-list"],
                "Learnings": ["learning-add"]
            }
        }))
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
            key, value = sys.argv[2], sys.argv[3]
            category = sys.argv[4] if len(sys.argv) > 4 else 'general'
            result = manager.set(key, value, category)
            print(json.dumps(result))
            
        elif cmd == "get":
            if len(sys.argv) < 3:
                print(json.dumps({"error": "Usage: get <key>"}))
                sys.exit(1)
            result = manager.get(sys.argv[2])
            print(json.dumps(result))
            
        elif cmd == "delete":
            if len(sys.argv) < 3:
                print(json.dumps({"error": "Usage: delete <key>"}))
                sys.exit(1)
            result = manager.delete(sys.argv[2])
            print(json.dumps(result))
            
        elif cmd == "list":
            category = sys.argv[2] if len(sys.argv) > 2 else None
            result = manager.list(category)
            print(json.dumps(result))
            
        elif cmd == "search":
            if len(sys.argv) < 3:
                print(json.dumps({"error": "Usage: search <query> [limit]"}))
                sys.exit(1)
            query = sys.argv[2]
            limit = int(sys.argv[3]) if len(sys.argv) > 3 else 5
            result = manager.hybrid_search(query, limit)
            print(json.dumps(result, indent=2))
            
        elif cmd == "semantic-search":
            if len(sys.argv) < 3:
                print(json.dumps({"error": "Usage: semantic-search <query> [limit]"}))
                sys.exit(1)
            query = sys.argv[2]
            limit = int(sys.argv[3]) if len(sys.argv) > 3 else 5
            result = manager.semantic_search(query, limit)
            print(json.dumps(result, indent=2))
            
        elif cmd == "context-for":
            if len(sys.argv) < 3:
                print(json.dumps({"error": "Usage: context-for <topic>"}))
                sys.exit(1)
            context = manager.context_for(sys.argv[2])
            print(context)
            
        elif cmd == "sync-vectors":
            result = manager.sync_vectors()
            print(json.dumps(result, indent=2))
            
        elif cmd == "status":
            result = manager.status()
            print(json.dumps(result, indent=2))
            
        elif cmd == "phase-start":
            if len(sys.argv) < 3:
                print(json.dumps({"error": "Usage: phase-start <name> [context] [parent_id]"}))
                sys.exit(1)
            phase_name = sys.argv[2]
            context = sys.argv[3] if len(sys.argv) > 3 else None
            parent_id = int(sys.argv[4]) if len(sys.argv) > 4 else None
            result = manager.phase_start(phase_name, context, parent_id)
            print(json.dumps(result))
            
        elif cmd == "phase-complete":
            if len(sys.argv) < 3:
                print(json.dumps({"error": "Usage: phase-complete <phase_id>"}))
                sys.exit(1)
            result = manager.phase_complete(int(sys.argv[2]))
            print(json.dumps(result))
            
        elif cmd == "phase-list":
            result = manager.phase_list()
            print(json.dumps(result))
            
        elif cmd == "learning-add":
            if len(sys.argv) < 4:
                print(json.dumps({"error": "Usage: learning-add <type> <content> [phase_id]"}))
                sys.exit(1)
            learning_type = sys.argv[2]
            content = sys.argv[3]
            phase_id = int(sys.argv[4]) if len(sys.argv) > 4 else None
            result = manager.learning_add(learning_type, content, phase_id)
            print(json.dumps(result))
            
        elif cmd == "dump":
            result = manager.dump()
            print(json.dumps(result, indent=2))
            
        elif cmd == "dump-compact":
            result = manager.dump_compact()
            print(result)
            
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
