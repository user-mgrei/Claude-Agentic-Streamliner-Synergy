# Claude Code Hivemind V3 - Qdrant Vector Memory Integration

**January 2026 | Implementation Documentation**

This document describes the Qdrant vector database integration added to the Claude Code Hivemind system, enabling semantic memory search and intelligent context retrieval.

---

## Overview

The V3 release adds **Qdrant vector database support** to the existing SQLite-based memory system, creating a hybrid storage architecture that combines:

- **SQLite**: Structured data storage, metadata, relationships, phase/task tracking
- **Qdrant**: Vector embeddings for semantic similarity search

This enables Claude to find relevant memories not just by exact keyword matches, but by semantic meaning—finding related concepts even when they use different terminology.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         HIVEMIND V3 MEMORY LAYER                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   ┌─────────────────────────────┐    ┌─────────────────────────────┐       │
│   │         SQLite DB           │    │        Qdrant DB            │       │
│   │   (.claude/claude.db)       │    │   (.claude/qdrant_data)     │       │
│   ├─────────────────────────────┤    ├─────────────────────────────┤       │
│   │ • memory table              │    │ • hivemind_memory collection│       │
│   │ • phases table              │    │ • 384-dim vectors           │       │
│   │ • agents table              │    │ • COSINE similarity         │       │
│   │ • tasks table               │    │ • Payload: key, content,    │       │
│   │ • learnings table           │    │   category, timestamp       │       │
│   │ • context_snapshots         │    │                             │       │
│   └──────────────┬──────────────┘    └──────────────┬──────────────┘       │
│                  │                                   │                      │
│                  └─────────────┬─────────────────────┘                      │
│                                │                                            │
│                    ┌───────────▼───────────┐                               │
│                    │   HybridMemoryManager │                               │
│                    │   (memory-db.py)      │                               │
│                    ├───────────────────────┤                               │
│                    │ • Dual-write on set() │                               │
│                    │ • Hybrid search       │                               │
│                    │ • Context injection   │                               │
│                    │ • Auto-sync vectors   │                               │
│                    └───────────────────────┘                               │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Installation

### Quick Start

```bash
# Default: file-based Qdrant (no server needed)
chmod +x setup-claude-hivemind-v3.sh
./setup-claude-hivemind-v3.sh

# Or with Docker-based Qdrant server
./setup-claude-hivemind-v3.sh --with-qdrant-docker

# Or without Qdrant (SQLite only)
./setup-claude-hivemind-v3.sh --without-qdrant
```

### Manual Qdrant Setup

```bash
# Install Python dependencies
pip3 install qdrant-client sentence-transformers

# For file-based storage (no server)
export QDRANT_FILE_STORAGE=1
mkdir -p ~/.claude/qdrant_data

# For Docker-based server
docker run -d --name hivemind-qdrant \
    -p 6333:6333 -p 6334:6334 \
    -v ~/.claude/qdrant_data:/qdrant/storage \
    qdrant/qdrant:latest
```

---

## Storage Modes

### File-Based Storage (Default)

Uses Qdrant's embedded mode—no server process required.

**Pros:**
- Zero infrastructure overhead
- Works offline
- Simple setup
- Data stored alongside SQLite

**Cons:**
- Single-process access only
- No web UI
- Slightly slower for large collections

**Configuration:**
```bash
export QDRANT_FILE_STORAGE=1
# Data stored in: ~/.claude/qdrant_data
```

### Server Mode (Docker)

Runs Qdrant as a persistent service.

**Pros:**
- Multi-process access
- Web UI at http://localhost:6333/dashboard
- Better performance at scale
- gRPC support

**Cons:**
- Requires Docker
- Uses system resources
- More complex setup

**Configuration:**
```bash
# Start container
docker start hivemind-qdrant

# Or specify custom URL
export QDRANT_URL=http://localhost:6333
```

---

## Usage

### Storing Memories

All `set` operations automatically write to both SQLite and Qdrant:

```bash
# Store with embedding
python3 ~/.claude/scripts/memory-db.py set "auth_decision" "Chose JWT with refresh tokens for stateless auth" "decision"

# Store learning (auto-vectorized)
python3 ~/.claude/scripts/memory-db.py learning-add pattern "Always validate input at API boundaries"
```

### Searching Memories

**Hybrid Search** (recommended):
```bash
# Combines semantic + keyword results
python3 ~/.claude/scripts/memory-db.py search "authentication tokens"
```

Output:
```json
{
  "query": "authentication tokens",
  "results": [
    {
      "key": "auth_decision",
      "content": "Chose JWT with refresh tokens...",
      "category": "decision",
      "score": 0.8234,
      "source": "semantic"
    },
    {
      "key": "api_security",
      "content": "Implemented token validation...",
      "score": 0.5,
      "source": "keyword"
    }
  ],
  "count": 2
}
```

**Semantic-Only Search**:
```bash
# Pure vector similarity (finds conceptually related content)
python3 ~/.claude/scripts/memory-db.py semantic-search "user login flow"
```

### Context Injection

Generate a context block for a topic (used by SessionStart hook):

```bash
python3 ~/.claude/scripts/memory-db.py context-for "API design"
```

Output:
```markdown
## Relevant Memory: API design

**rest_conventions** [architecture] (relevance: 0.82):
  Use RESTful conventions with JSON responses...

**error_handling** [pattern] (relevance: 0.71):
  Return consistent error objects with code, message...
```

### Checking Status

```bash
python3 ~/.claude/scripts/memory-db.py status
```

Output:
```json
{
  "sqlite": {
    "connected": true,
    "path": "/home/user/.claude/claude.db",
    "memories": 42,
    "unsynced": 0
  },
  "qdrant": {
    "connected": true,
    "vectors": 42
  },
  "capabilities": {
    "qdrant": true,
    "embeddings": true
  }
}
```

### Syncing Vectors

If Qdrant was unavailable when memories were stored:

```bash
python3 ~/.claude/scripts/memory-db.py sync-vectors
```

---

## Hook Integration

### SessionStart

The SessionStart hook now injects semantic context based on the current project:

```bash
# ~/.claude/hooks/session-start.sh (excerpt)

# Get semantic context for current project
PROJECT=$(basename "$CWD")
SEMANTIC=$(python3 "$MEMORY_SCRIPT" context-for "$PROJECT")

# Inject into Claude's context
cat << EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": ${SEMANTIC_ESCAPED}
  }
}
EOF
```

### Stop Hook

The Stop hook now syncs vectors before session end:

```bash
# Auto-sync vectors when session ends
python3 "$MEMORY_SCRIPT" sync-vectors
```

---

## Slash Commands

| Command | Description |
|---------|-------------|
| `/search <query>` | Hybrid keyword + semantic search |
| `/semantic <query>` | Pure semantic vector search |
| `/remember <key> <value>` | Store in hybrid memory |
| `/learn <type> <content>` | Record learning (auto-vectorized) |
| `/memory-status` | Check SQLite and Qdrant status |
| `/memory dump` | Dump current memory state |

---

## Embedding Model

The integration uses **sentence-transformers** with the `all-MiniLM-L6-v2` model:

- **Dimensions**: 384
- **Performance**: Fast (CPU-friendly)
- **Quality**: Good for general-purpose semantic similarity
- **Size**: ~90MB

The model is loaded lazily on first use. Alternative models can be configured by modifying `EMBEDDING_MODEL` in `memory-db.py`.

---

## Graceful Degradation

The system gracefully handles missing components:

| Missing Component | Behavior |
|-------------------|----------|
| `qdrant-client` not installed | SQLite-only mode, semantic search returns empty |
| `sentence-transformers` not installed | Qdrant available but no embeddings |
| Qdrant server unreachable | Falls back to SQLite, logs warning |
| File storage directory missing | Creates automatically |

Check degradation status:
```bash
python3 ~/.claude/scripts/memory-db.py status
# Look at "capabilities" and "connected" fields
```

---

## File Locations

| File | Purpose |
|------|---------|
| `~/.claude/scripts/memory-db.py` | Hybrid memory manager |
| `~/.claude/claude.db` | SQLite database (global) |
| `.claude/claude.db` | SQLite database (project) |
| `~/.claude/qdrant_data/` | Qdrant file storage (global) |
| `.claude/qdrant_data/` | Qdrant file storage (project) |

---

## Database Schema

### SQLite (memory table)

```sql
CREATE TABLE memory (
    id INTEGER PRIMARY KEY,
    key TEXT UNIQUE NOT NULL,
    value TEXT NOT NULL,
    category TEXT DEFAULT 'general',
    created_at TIMESTAMP,
    updated_at TIMESTAMP,
    vector_synced INTEGER DEFAULT 0  -- NEW: tracks Qdrant sync status
);
```

### Qdrant Collection

```
Collection: hivemind_memory
Vector size: 384
Distance: Cosine

Payload schema:
{
  "key": string,
  "content": string,
  "category": string,
  "created_at": ISO timestamp
}
```

---

## Troubleshooting

### "Qdrant not available"

1. Check if dependencies are installed:
   ```bash
   pip3 list | grep -E "qdrant|sentence"
   ```

2. For file mode, ensure env var is set:
   ```bash
   export QDRANT_FILE_STORAGE=1
   ```

3. For server mode, check Docker:
   ```bash
   docker ps | grep qdrant
   ```

### Slow First Search

The embedding model loads on first use (~2-5 seconds). Subsequent searches are fast.

### Vectors Not Syncing

Check unsynced count and manually sync:
```bash
python3 ~/.claude/scripts/memory-db.py status
python3 ~/.claude/scripts/memory-db.py sync-vectors
```

### Memory Not Found in Semantic Search

The semantic search has a default threshold of 0.3 similarity. Very short or generic content may not match well. Try:
- Using more descriptive content when storing
- Lowering the threshold (edit `score_threshold` in source)
- Using hybrid search instead

---

## Migration from V2

V3 is fully backward-compatible with V2:

1. Existing SQLite data is preserved
2. Run setup script to add Qdrant support:
   ```bash
   ./setup-claude-hivemind-v3.sh
   ```
3. Sync existing memories to Qdrant:
   ```bash
   python3 ~/.claude/scripts/memory-db.py sync-vectors
   ```

---

## Performance Considerations

| Operation | SQLite | Qdrant |
|-----------|--------|--------|
| Exact key lookup | ~1ms | N/A |
| Keyword search | ~5ms | N/A |
| Semantic search | N/A | ~50ms |
| Hybrid search | ~55ms | Combined |
| Store (dual-write) | ~10ms | +embedding time |

For large collections (>10,000 items), consider:
- Using Docker-based Qdrant for better performance
- Indexing Qdrant on payload fields
- Limiting search results

---

## Security Notes

- Vector embeddings are stored locally, not sent to external services
- The sentence-transformers model runs entirely on-device
- Qdrant server (if used) binds to localhost only by default
- No API keys required for the embedding model

---

## Future Enhancements

Potential improvements for future versions:

1. **Configurable embedding models** - Support for larger/better models
2. **Metadata filtering** - Filter semantic search by date, category
3. **Incremental sync** - Background sync process
4. **Cross-project search** - Search across all project memories
5. **Embedding cache** - Cache frequently-used embeddings
6. **MCP integration** - Expose as MCP tool for other agents

---

## Quick Reference

```bash
# Store with embedding
memory-db.py set <key> <value> [category]

# Hybrid search (semantic + keyword)
memory-db.py search <query>

# Pure semantic search
memory-db.py semantic-search <query>

# Get context for topic
memory-db.py context-for <topic>

# Sync SQLite to Qdrant
memory-db.py sync-vectors

# Check both databases
memory-db.py status
```
