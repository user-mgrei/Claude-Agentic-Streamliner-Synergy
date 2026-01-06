#!/usr/bin/env python3
"""
Claude Code Hivemind - Qdrant Vector Memory Manager

Provides semantic memory storage and retrieval using Qdrant vector database.
Integrates with the existing SQLite memory system for hybrid structured + semantic search.

Features:
  - Semantic search across all stored memories
  - Automatic embedding generation using sentence-transformers
  - Hybrid retrieval combining SQLite metadata with Qdrant vectors
  - Context-aware memory injection for Claude sessions

Database location: 
  - Qdrant: localhost:6333 (default) or file-based storage at .claude/qdrant_data
  - Falls back to SQLite-only mode if Qdrant unavailable

Usage:
  qdrant-memory.py store <key> <content> [category]
  qdrant-memory.py search <query> [limit]
  qdrant-memory.py hybrid-search <query> [limit]
  qdrant-memory.py context-inject <query>
  qdrant-memory.py init [--file-storage]
  qdrant-memory.py status
  qdrant-memory.py sync-from-sqlite
"""

import json
import sys
import os
import hashlib
from datetime import datetime
from pathlib import Path
from typing import Optional, List, Dict, Any

# Qdrant imports - graceful fallback if not installed
try:
    from qdrant_client import QdrantClient
    from qdrant_client.models import (
        Distance,
        VectorParams,
        PointStruct,
        Filter,
        FieldCondition,
        MatchValue,
        SearchParams,
    )
    QDRANT_AVAILABLE = True
except ImportError:
    QDRANT_AVAILABLE = False

# Sentence transformers for embeddings - graceful fallback
try:
    from sentence_transformers import SentenceTransformer
    EMBEDDINGS_AVAILABLE = True
except ImportError:
    EMBEDDINGS_AVAILABLE = False

# Configuration
COLLECTION_NAME = "hivemind_memory"
EMBEDDING_MODEL = "all-MiniLM-L6-v2"  # Fast, 384-dim embeddings
EMBEDDING_DIM = 384
DEFAULT_QDRANT_URL = "http://localhost:6333"
DEFAULT_SEARCH_LIMIT = 5


class QdrantMemoryManager:
    """Manages vector-based memory storage with Qdrant."""
    
    def __init__(self, use_file_storage: bool = False):
        self.client: Optional[QdrantClient] = None
        self.model: Optional[Any] = None
        self.use_file_storage = use_file_storage
        self.qdrant_path = self._get_qdrant_path()
        self._initialized = False
        
    def _get_qdrant_path(self) -> Path:
        """Determine Qdrant file storage path."""
        project_dir = os.environ.get('CLAUDE_PROJECT_DIR', os.getcwd())
        project_qdrant = Path(project_dir) / '.claude' / 'qdrant_data'
        global_qdrant = Path.home() / '.claude' / 'qdrant_data'
        
        # If in a project with .claude dir, use project storage
        if (Path(project_dir) / '.claude').exists():
            return project_qdrant
        return global_qdrant
        
    def _ensure_initialized(self) -> bool:
        """Lazy initialization of Qdrant client and embedding model."""
        if self._initialized:
            return True
            
        if not QDRANT_AVAILABLE:
            return False
            
        try:
            if self.use_file_storage:
                self.qdrant_path.mkdir(parents=True, exist_ok=True)
                self.client = QdrantClient(path=str(self.qdrant_path))
            else:
                qdrant_url = os.environ.get('QDRANT_URL', DEFAULT_QDRANT_URL)
                self.client = QdrantClient(url=qdrant_url)
                # Test connection
                self.client.get_collections()
                
            if EMBEDDINGS_AVAILABLE:
                self.model = SentenceTransformer(EMBEDDING_MODEL)
                
            self._initialized = True
            return True
        except Exception as e:
            # Connection failed, will operate in degraded mode
            self._initialized = False
            return False
            
    def _generate_embedding(self, text: str) -> List[float]:
        """Generate embedding vector for text."""
        if not self.model:
            raise RuntimeError("Embedding model not available")
        return self.model.encode(text).tolist()
        
    def _generate_id(self, key: str) -> str:
        """Generate deterministic ID from key."""
        return hashlib.md5(key.encode()).hexdigest()
        
    def init_collection(self) -> Dict[str, Any]:
        """Initialize Qdrant collection with proper schema."""
        if not self._ensure_initialized():
            return {"error": "Qdrant not available", "fallback": "sqlite-only"}
            
        try:
            # Check if collection exists
            collections = self.client.get_collections().collections
            exists = any(c.name == COLLECTION_NAME for c in collections)
            
            if not exists:
                self.client.create_collection(
                    collection_name=COLLECTION_NAME,
                    vectors_config=VectorParams(
                        size=EMBEDDING_DIM,
                        distance=Distance.COSINE
                    )
                )
                return {
                    "status": "created",
                    "collection": COLLECTION_NAME,
                    "vector_size": EMBEDDING_DIM,
                    "storage": "file" if self.use_file_storage else "server"
                }
            else:
                return {
                    "status": "exists",
                    "collection": COLLECTION_NAME
                }
        except Exception as e:
            return {"error": str(e)}
            
    def store(self, key: str, content: str, category: str = "general", 
              metadata: Optional[Dict] = None) -> Dict[str, Any]:
        """Store content with vector embedding in Qdrant."""
        if not self._ensure_initialized():
            return {"error": "Qdrant not available", "suggestion": "Use SQLite fallback"}
            
        if not EMBEDDINGS_AVAILABLE:
            return {"error": "sentence-transformers not installed"}
            
        try:
            # Generate embedding
            embedding = self._generate_embedding(content)
            
            # Build payload
            payload = {
                "key": key,
                "content": content,
                "category": category,
                "created_at": datetime.now().isoformat(),
                "content_hash": hashlib.sha256(content.encode()).hexdigest()[:16]
            }
            if metadata:
                payload.update(metadata)
                
            # Upsert point
            point_id = self._generate_id(key)
            self.client.upsert(
                collection_name=COLLECTION_NAME,
                points=[
                    PointStruct(
                        id=point_id,
                        vector=embedding,
                        payload=payload
                    )
                ]
            )
            
            return {
                "status": "stored",
                "key": key,
                "category": category,
                "point_id": point_id
            }
        except Exception as e:
            return {"error": str(e)}
            
    def search(self, query: str, limit: int = DEFAULT_SEARCH_LIMIT, 
               category: Optional[str] = None, 
               score_threshold: float = 0.3) -> Dict[str, Any]:
        """Semantic search across stored memories."""
        if not self._ensure_initialized():
            return {"error": "Qdrant not available", "results": []}
            
        if not EMBEDDINGS_AVAILABLE:
            return {"error": "sentence-transformers not installed", "results": []}
            
        try:
            # Generate query embedding
            query_embedding = self._generate_embedding(query)
            
            # Build filter if category specified
            query_filter = None
            if category:
                query_filter = Filter(
                    must=[
                        FieldCondition(
                            key="category",
                            match=MatchValue(value=category)
                        )
                    ]
                )
                
            # Search
            results = self.client.search(
                collection_name=COLLECTION_NAME,
                query_vector=query_embedding,
                query_filter=query_filter,
                limit=limit,
                score_threshold=score_threshold,
                with_payload=True
            )
            
            formatted_results = []
            for hit in results:
                formatted_results.append({
                    "key": hit.payload.get("key"),
                    "content": hit.payload.get("content"),
                    "category": hit.payload.get("category"),
                    "score": round(hit.score, 4),
                    "created_at": hit.payload.get("created_at")
                })
                
            return {
                "query": query,
                "results": formatted_results,
                "count": len(formatted_results)
            }
        except Exception as e:
            return {"error": str(e), "results": []}
            
    def context_inject(self, query: str, max_tokens: int = 2000) -> str:
        """Generate context injection string for Claude session."""
        results = self.search(query, limit=10)
        
        if results.get("error") or not results.get("results"):
            return ""
            
        context_parts = ["## Relevant Memory Context\n"]
        current_tokens = 50  # Rough estimate for header
        
        for r in results["results"]:
            content = r["content"]
            # Rough token estimation (4 chars per token)
            estimated_tokens = len(content) // 4
            
            if current_tokens + estimated_tokens > max_tokens:
                break
                
            context_parts.append(f"**{r['key']}** ({r['category']}, relevance: {r['score']}):")
            context_parts.append(f"  {content}\n")
            current_tokens += estimated_tokens + 20
            
        return "\n".join(context_parts)
        
    def get_status(self) -> Dict[str, Any]:
        """Get Qdrant connection and collection status."""
        status = {
            "qdrant_available": QDRANT_AVAILABLE,
            "embeddings_available": EMBEDDINGS_AVAILABLE,
            "storage_type": "file" if self.use_file_storage else "server",
            "storage_path": str(self.qdrant_path) if self.use_file_storage else DEFAULT_QDRANT_URL
        }
        
        if not self._ensure_initialized():
            status["connection"] = "failed"
            return status
            
        try:
            collections = self.client.get_collections().collections
            hivemind_collection = next(
                (c for c in collections if c.name == COLLECTION_NAME), 
                None
            )
            
            if hivemind_collection:
                collection_info = self.client.get_collection(COLLECTION_NAME)
                status["collection"] = {
                    "name": COLLECTION_NAME,
                    "vectors_count": collection_info.vectors_count,
                    "points_count": collection_info.points_count,
                    "status": collection_info.status.value
                }
            else:
                status["collection"] = {"status": "not_created"}
                
            status["connection"] = "ok"
        except Exception as e:
            status["connection"] = "error"
            status["error"] = str(e)
            
        return status
        
    def delete(self, key: str) -> Dict[str, Any]:
        """Delete a memory by key."""
        if not self._ensure_initialized():
            return {"error": "Qdrant not available"}
            
        try:
            point_id = self._generate_id(key)
            self.client.delete(
                collection_name=COLLECTION_NAME,
                points_selector=[point_id]
            )
            return {"status": "deleted", "key": key}
        except Exception as e:
            return {"error": str(e)}
            
    def list_by_category(self, category: str, limit: int = 50) -> Dict[str, Any]:
        """List all memories in a category."""
        if not self._ensure_initialized():
            return {"error": "Qdrant not available", "results": []}
            
        try:
            results, _ = self.client.scroll(
                collection_name=COLLECTION_NAME,
                scroll_filter=Filter(
                    must=[
                        FieldCondition(
                            key="category",
                            match=MatchValue(value=category)
                        )
                    ]
                ),
                limit=limit,
                with_payload=True
            )
            
            formatted = []
            for point in results:
                formatted.append({
                    "key": point.payload.get("key"),
                    "category": point.payload.get("category"),
                    "created_at": point.payload.get("created_at"),
                    "content_preview": point.payload.get("content", "")[:100]
                })
                
            return {"category": category, "results": formatted, "count": len(formatted)}
        except Exception as e:
            return {"error": str(e), "results": []}


def sync_from_sqlite(manager: QdrantMemoryManager, sqlite_db_path: Optional[str] = None) -> Dict[str, Any]:
    """Sync memories from SQLite database to Qdrant."""
    import sqlite3
    
    if sqlite_db_path is None:
        project_dir = os.environ.get('CLAUDE_PROJECT_DIR', os.getcwd())
        project_db = Path(project_dir) / '.claude' / 'claude.db'
        global_db = Path.home() / '.claude' / 'claude.db'
        
        if project_db.exists():
            sqlite_db_path = str(project_db)
        elif global_db.exists():
            sqlite_db_path = str(global_db)
        else:
            return {"error": "SQLite database not found"}
            
    try:
        conn = sqlite3.connect(sqlite_db_path)
        cursor = conn.cursor()
        
        # Sync memory table
        cursor.execute('SELECT key, value, category FROM memory')
        memories = cursor.fetchall()
        
        synced = 0
        errors = []
        
        for key, value, category in memories:
            result = manager.store(key, value, category or "general")
            if result.get("status") == "stored":
                synced += 1
            else:
                errors.append({"key": key, "error": result.get("error")})
                
        # Sync learnings table
        cursor.execute('SELECT id, learning_type, content FROM learnings')
        learnings = cursor.fetchall()
        
        for learning_id, learning_type, content in learnings:
            key = f"learning_{learning_id}"
            result = manager.store(key, content, f"learning_{learning_type}")
            if result.get("status") == "stored":
                synced += 1
            else:
                errors.append({"key": key, "error": result.get("error")})
                
        conn.close()
        
        return {
            "status": "synced",
            "memories_synced": synced,
            "errors": errors if errors else None,
            "source": sqlite_db_path
        }
    except Exception as e:
        return {"error": str(e)}


def main():
    if len(sys.argv) < 2:
        print(json.dumps({
            "error": "Usage: qdrant-memory.py <command> [args]",
            "commands": [
                "init [--file-storage]",
                "store <key> <content> [category]",
                "search <query> [limit]",
                "context-inject <query>",
                "delete <key>",
                "list <category>",
                "sync-from-sqlite",
                "status"
            ]
        }))
        sys.exit(1)
        
    cmd = sys.argv[1]
    use_file_storage = "--file-storage" in sys.argv or os.environ.get("QDRANT_FILE_STORAGE") == "1"
    
    # Remove flag from args
    args = [a for a in sys.argv[2:] if a != "--file-storage"]
    
    manager = QdrantMemoryManager(use_file_storage=use_file_storage)
    
    try:
        if cmd == "init":
            result = manager.init_collection()
            print(json.dumps(result, indent=2))
            
        elif cmd == "store":
            if len(args) < 2:
                print(json.dumps({"error": "Usage: store <key> <content> [category]"}))
                sys.exit(1)
            key = args[0]
            content = args[1]
            category = args[2] if len(args) > 2 else "general"
            result = manager.store(key, content, category)
            print(json.dumps(result))
            
        elif cmd == "search":
            if len(args) < 1:
                print(json.dumps({"error": "Usage: search <query> [limit]"}))
                sys.exit(1)
            query = args[0]
            limit = int(args[1]) if len(args) > 1 else DEFAULT_SEARCH_LIMIT
            result = manager.search(query, limit=limit)
            print(json.dumps(result, indent=2))
            
        elif cmd == "context-inject":
            if len(args) < 1:
                print(json.dumps({"error": "Usage: context-inject <query>"}))
                sys.exit(1)
            query = args[0]
            context = manager.context_inject(query)
            # Output raw text for context injection
            print(context)
            
        elif cmd == "delete":
            if len(args) < 1:
                print(json.dumps({"error": "Usage: delete <key>"}))
                sys.exit(1)
            result = manager.delete(args[0])
            print(json.dumps(result))
            
        elif cmd == "list":
            if len(args) < 1:
                print(json.dumps({"error": "Usage: list <category>"}))
                sys.exit(1)
            result = manager.list_by_category(args[0])
            print(json.dumps(result, indent=2))
            
        elif cmd == "sync-from-sqlite":
            sqlite_path = args[0] if args else None
            result = sync_from_sqlite(manager, sqlite_path)
            print(json.dumps(result, indent=2))
            
        elif cmd == "status":
            result = manager.get_status()
            print(json.dumps(result, indent=2))
            
        else:
            print(json.dumps({"error": f"Unknown command: {cmd}"}))
            sys.exit(1)
            
    except Exception as e:
        print(json.dumps({"error": str(e)}))
        sys.exit(1)


if __name__ == "__main__":
    main()
