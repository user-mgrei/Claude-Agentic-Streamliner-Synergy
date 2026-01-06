#!/bin/bash
#===============================================================================
# Claude Code Hivemind Setup Script V3
# Enhanced with Qdrant MCP integration, programming-optimized agents,
# LSP configurations with TUI, and comprehensive Claude CLI issue workarounds
#
# For Arch Linux with yay-installed claude-code
# Version: 3.0.0
# Date: 2026-01-06
#===============================================================================

set -e

#-------------------------------------------------------------------------------
# Configuration Variables
#-------------------------------------------------------------------------------
CLAUDE_DIR="$HOME/.claude"
AGENTS_DIR="$CLAUDE_DIR/agents"
COMMANDS_DIR="$CLAUDE_DIR/commands"
HOOKS_DIR="$CLAUDE_DIR/hooks/hivemind"
SCRIPTS_DIR="$CLAUDE_DIR/scripts"
RULES_DIR="$CLAUDE_DIR/rules"
MEMORY_DIR="$CLAUDE_DIR/memory"
MCP_DIR="$CLAUDE_DIR/mcp"
LSP_DIR="$CLAUDE_DIR/lsp"
QDRANT_DIR="$CLAUDE_DIR/qdrant"
DB_FILE="$CLAUDE_DIR/hivemind.db"
QDRANT_STORAGE="$QDRANT_DIR/storage"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

#-------------------------------------------------------------------------------
# Utility Functions
#-------------------------------------------------------------------------------
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_command() {
    if command -v "$1" &> /dev/null; then
        log_success "$1 is installed"
        return 0
    else
        log_warn "$1 is not installed"
        return 1
    fi
}

#-------------------------------------------------------------------------------
# Prerequisites Check and Installation
#-------------------------------------------------------------------------------
install_prerequisites() {
    log_info "Checking and installing prerequisites..."
    
    local packages_to_install=()
    
    # Check for required packages
    if ! check_command nodejs; then packages_to_install+=("nodejs"); fi
    if ! check_command npm; then packages_to_install+=("npm"); fi
    if ! check_command sqlite3; then packages_to_install+=("sqlite"); fi
    if ! check_command jq; then packages_to_install+=("jq"); fi
    if ! check_command inotifywait; then packages_to_install+=("inotify-tools"); fi
    if ! check_command notify-send; then packages_to_install+=("libnotify"); fi
    if ! check_command python3; then packages_to_install+=("python"); fi
    if ! check_command pip; then packages_to_install+=("python-pip"); fi
    if ! check_command dialog; then packages_to_install+=("dialog"); fi
    if ! check_command uuidgen; then packages_to_install+=("util-linux"); fi
    
    # Install missing packages via pacman/yay
    if [ ${#packages_to_install[@]} -gt 0 ]; then
        log_info "Installing missing packages: ${packages_to_install[*]}"
        if command -v yay &> /dev/null; then
            yay -S --needed --noconfirm "${packages_to_install[@]}"
        else
            sudo pacman -S --needed --noconfirm "${packages_to_install[@]}"
        fi
    fi
    
    # Install Python packages for Qdrant MCP
    log_info "Installing Python dependencies for Qdrant MCP..."
    pip install --user --quiet qdrant-client fastembed numpy sentence-transformers aiohttp 2>/dev/null || \
        pip install --user qdrant-client fastembed numpy sentence-transformers aiohttp
    
    # Install Qdrant (local binary or Docker)
    if ! check_command qdrant; then
        log_info "Installing Qdrant..."
        if command -v yay &> /dev/null; then
            yay -S --needed --noconfirm qdrant-bin 2>/dev/null || {
                log_warn "Qdrant AUR package not found, downloading binary..."
                install_qdrant_binary
            }
        else
            install_qdrant_binary
        fi
    fi
    
    # Install Gemini CLI for summarization
    if ! check_command gemini; then
        log_info "Installing Gemini CLI..."
        npm install -g @anthropics/gemini-cli 2>/dev/null || log_warn "Gemini CLI installation failed - optional feature"
    fi
    
    log_success "Prerequisites check complete"
}

install_qdrant_binary() {
    local qdrant_version="v1.12.1"
    local qdrant_url="https://github.com/qdrant/qdrant/releases/download/${qdrant_version}/qdrant-x86_64-unknown-linux-gnu.tar.gz"
    local install_dir="$HOME/.local/bin"
    
    mkdir -p "$install_dir"
    
    log_info "Downloading Qdrant ${qdrant_version}..."
    curl -sL "$qdrant_url" | tar xz -C "$install_dir"
    chmod +x "$install_dir/qdrant"
    
    # Add to PATH if needed
    if [[ ":$PATH:" != *":$install_dir:"* ]]; then
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
        export PATH="$HOME/.local/bin:$PATH"
    fi
    
    log_success "Qdrant installed to $install_dir"
}

#-------------------------------------------------------------------------------
# Directory Structure Setup
#-------------------------------------------------------------------------------
setup_directories() {
    log_info "Creating directory structure..."
    
    mkdir -p "$AGENTS_DIR"
    mkdir -p "$COMMANDS_DIR"
    mkdir -p "$HOOKS_DIR"
    mkdir -p "$SCRIPTS_DIR"
    mkdir -p "$RULES_DIR"
    mkdir -p "$MEMORY_DIR"
    mkdir -p "$MCP_DIR"
    mkdir -p "$LSP_DIR"
    mkdir -p "$QDRANT_DIR"
    mkdir -p "$QDRANT_STORAGE"
    mkdir -p "$CLAUDE_DIR/transcripts"
    mkdir -p "$CLAUDE_DIR/plans"
    mkdir -p "$CLAUDE_DIR/snapshots"
    
    log_success "Directory structure created"
}

#-------------------------------------------------------------------------------
# SQLite Database Setup with WAL Mode
#-------------------------------------------------------------------------------
setup_database() {
    log_info "Setting up SQLite database with WAL mode..."
    
    sqlite3 "$DB_FILE" << 'SQLEOF'
-- Enable WAL mode for concurrent access
PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=5000;
PRAGMA synchronous=NORMAL;

-- Agent task tracking
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
    context_tokens_used INTEGER,
    parent_task_id TEXT,
    FOREIGN KEY (parent_task_id) REFERENCES agent_tasks(id)
);

-- Project state tracking
CREATE TABLE IF NOT EXISTS project_state (
    id INTEGER PRIMARY KEY,
    project_path TEXT NOT NULL UNIQUE,
    current_phase TEXT,
    active_plan TEXT,
    last_checkpoint TEXT,
    updated_at REAL DEFAULT (julianday('now')),
    metadata TEXT
);

-- Swarm task queue
CREATE TABLE IF NOT EXISTS swarm_queue (
    id TEXT PRIMARY KEY,
    priority INTEGER DEFAULT 5,
    task_type TEXT NOT NULL,
    task_data TEXT NOT NULL,
    status TEXT DEFAULT 'pending',
    assigned_agent TEXT,
    created_at REAL DEFAULT (julianday('now')),
    started_at REAL,
    completed_at REAL,
    dependencies TEXT,
    result TEXT
);

-- Context snapshots for recovery
CREATE TABLE IF NOT EXISTS context_snapshots (
    id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL,
    snapshot_type TEXT,
    trigger_reason TEXT,
    context_data TEXT,
    token_count INTEGER,
    created_at REAL DEFAULT (julianday('now'))
);

-- Memory entries (synced with Qdrant)
CREATE TABLE IF NOT EXISTS memory_entries (
    id TEXT PRIMARY KEY,
    collection TEXT NOT NULL,
    content TEXT NOT NULL,
    metadata TEXT,
    embedding_id TEXT,
    created_at REAL DEFAULT (julianday('now')),
    updated_at REAL DEFAULT (julianday('now')),
    synced_to_qdrant INTEGER DEFAULT 0
);

-- LSP configurations
CREATE TABLE IF NOT EXISTS lsp_configs (
    id TEXT PRIMARY KEY,
    language TEXT NOT NULL UNIQUE,
    server_command TEXT NOT NULL,
    server_args TEXT,
    root_markers TEXT,
    file_patterns TEXT,
    initialization_options TEXT,
    settings TEXT,
    enabled INTEGER DEFAULT 1,
    created_at REAL DEFAULT (julianday('now'))
);

-- Learning entries
CREATE TABLE IF NOT EXISTS learnings (
    id TEXT PRIMARY KEY,
    category TEXT NOT NULL,
    content TEXT NOT NULL,
    source_session TEXT,
    confidence REAL DEFAULT 1.0,
    usage_count INTEGER DEFAULT 0,
    created_at REAL DEFAULT (julianday('now')),
    last_used REAL
);

-- Create indexes for performance
CREATE INDEX IF NOT EXISTS idx_agent_tasks_session ON agent_tasks(session_id);
CREATE INDEX IF NOT EXISTS idx_agent_tasks_status ON agent_tasks(status);
CREATE INDEX IF NOT EXISTS idx_swarm_queue_status ON swarm_queue(status, priority);
CREATE INDEX IF NOT EXISTS idx_memory_entries_collection ON memory_entries(collection);
CREATE INDEX IF NOT EXISTS idx_context_snapshots_session ON context_snapshots(session_id);
SQLEOF

    log_success "Database initialized at $DB_FILE"
}

#-------------------------------------------------------------------------------
# Qdrant MCP Server Implementation
#-------------------------------------------------------------------------------
create_qdrant_mcp_server() {
    log_info "Creating Qdrant MCP server..."
    
    cat > "$MCP_DIR/qdrant-memory-server.py" << 'PYEOF'
#!/usr/bin/env python3
"""
Qdrant Memory MCP Server for Claude Code Hivemind V3
Provides vector-based semantic memory for project context and learnings.
"""

import asyncio
import json
import os
import sys
import sqlite3
import hashlib
from datetime import datetime
from pathlib import Path
from typing import Any, Optional
import logging

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

try:
    from qdrant_client import QdrantClient
    from qdrant_client.models import (
        Distance, VectorParams, PointStruct, Filter,
        FieldCondition, MatchValue, UpdateStatus
    )
    from sentence_transformers import SentenceTransformer
    QDRANT_AVAILABLE = True
except ImportError:
    QDRANT_AVAILABLE = False
    logger.warning("Qdrant client not available. Running in SQLite-only mode.")

# Configuration
CLAUDE_DIR = Path.home() / ".claude"
DB_PATH = CLAUDE_DIR / "hivemind.db"
QDRANT_PATH = CLAUDE_DIR / "qdrant" / "storage"
EMBEDDING_MODEL = "all-MiniLM-L6-v2"
VECTOR_SIZE = 384

# Collections for different memory types
COLLECTIONS = {
    "project_context": "Project-specific context and decisions",
    "code_patterns": "Learned code patterns and best practices",
    "session_memory": "Session-specific temporary memory",
    "learnings": "Long-term learnings and insights",
    "file_summaries": "Summaries of project files"
}


class QdrantMemoryServer:
    """MCP Server for Qdrant-based semantic memory."""
    
    def __init__(self):
        self.db_conn = None
        self.qdrant_client = None
        self.encoder = None
        self._initialized = False
    
    async def initialize(self):
        """Initialize database and Qdrant connections."""
        if self._initialized:
            return
        
        # Connect to SQLite
        self.db_conn = sqlite3.connect(str(DB_PATH), check_same_thread=False)
        self.db_conn.row_factory = sqlite3.Row
        
        if QDRANT_AVAILABLE:
            try:
                # Initialize Qdrant (local storage)
                QDRANT_PATH.mkdir(parents=True, exist_ok=True)
                self.qdrant_client = QdrantClient(path=str(QDRANT_PATH))
                
                # Initialize embedding model
                self.encoder = SentenceTransformer(EMBEDDING_MODEL)
                
                # Create collections
                for collection_name in COLLECTIONS.keys():
                    self._ensure_collection(collection_name)
                
                logger.info("Qdrant initialized successfully")
            except Exception as e:
                logger.error(f"Failed to initialize Qdrant: {e}")
                self.qdrant_client = None
        
        self._initialized = True
    
    def _ensure_collection(self, name: str):
        """Ensure a Qdrant collection exists."""
        if not self.qdrant_client:
            return
        
        collections = self.qdrant_client.get_collections().collections
        if not any(c.name == name for c in collections):
            self.qdrant_client.create_collection(
                collection_name=name,
                vectors_config=VectorParams(size=VECTOR_SIZE, distance=Distance.COSINE)
            )
            logger.info(f"Created collection: {name}")
    
    def _generate_id(self, content: str) -> str:
        """Generate a unique ID for content."""
        return hashlib.sha256(content.encode()).hexdigest()[:16]
    
    def _encode(self, text: str) -> list:
        """Encode text to vector embedding."""
        if self.encoder:
            return self.encoder.encode(text).tolist()
        return [0.0] * VECTOR_SIZE
    
    async def store_memory(self, collection: str, content: str, metadata: dict = None) -> dict:
        """Store a memory entry with vector embedding."""
        await self.initialize()
        
        entry_id = self._generate_id(content + str(datetime.now()))
        metadata = metadata or {}
        metadata["timestamp"] = datetime.now().isoformat()
        
        # Store in SQLite
        cursor = self.db_conn.cursor()
        cursor.execute("""
            INSERT INTO memory_entries (id, collection, content, metadata, synced_to_qdrant)
            VALUES (?, ?, ?, ?, ?)
        """, (entry_id, collection, content, json.dumps(metadata), 0))
        
        # Store in Qdrant if available
        if self.qdrant_client and collection in COLLECTIONS:
            try:
                vector = self._encode(content)
                self.qdrant_client.upsert(
                    collection_name=collection,
                    points=[PointStruct(
                        id=entry_id,
                        vector=vector,
                        payload={"content": content, **metadata}
                    )]
                )
                cursor.execute(
                    "UPDATE memory_entries SET synced_to_qdrant = 1, embedding_id = ? WHERE id = ?",
                    (entry_id, entry_id)
                )
            except Exception as e:
                logger.error(f"Failed to store in Qdrant: {e}")
        
        self.db_conn.commit()
        return {"id": entry_id, "status": "stored"}
    
    async def search_memory(self, collection: str, query: str, limit: int = 5) -> list:
        """Search memory using semantic similarity."""
        await self.initialize()
        
        results = []
        
        if self.qdrant_client and collection in COLLECTIONS:
            try:
                vector = self._encode(query)
                search_results = self.qdrant_client.search(
                    collection_name=collection,
                    query_vector=vector,
                    limit=limit
                )
                for hit in search_results:
                    results.append({
                        "id": hit.id,
                        "content": hit.payload.get("content", ""),
                        "score": hit.score,
                        "metadata": {k: v for k, v in hit.payload.items() if k != "content"}
                    })
            except Exception as e:
                logger.error(f"Qdrant search failed: {e}")
        
        # Fallback to SQLite if no Qdrant results
        if not results:
            cursor = self.db_conn.cursor()
            cursor.execute("""
                SELECT id, content, metadata FROM memory_entries
                WHERE collection = ? AND content LIKE ?
                ORDER BY created_at DESC LIMIT ?
            """, (collection, f"%{query}%", limit))
            for row in cursor.fetchall():
                results.append({
                    "id": row["id"],
                    "content": row["content"],
                    "score": 0.5,
                    "metadata": json.loads(row["metadata"]) if row["metadata"] else {}
                })
        
        return results
    
    async def get_context(self, project_path: str) -> dict:
        """Get aggregated context for a project."""
        await self.initialize()
        
        context = {
            "recent_memories": [],
            "relevant_patterns": [],
            "active_learnings": []
        }
        
        # Get recent session memories
        cursor = self.db_conn.cursor()
        cursor.execute("""
            SELECT content, metadata FROM memory_entries
            WHERE collection = 'session_memory'
            ORDER BY created_at DESC LIMIT 10
        """)
        context["recent_memories"] = [
            {"content": r["content"], "metadata": json.loads(r["metadata"]) if r["metadata"] else {}}
            for r in cursor.fetchall()
        ]
        
        # Get learnings
        cursor.execute("""
            SELECT content, category, confidence FROM learnings
            WHERE confidence > 0.7
            ORDER BY usage_count DESC, confidence DESC LIMIT 10
        """)
        context["active_learnings"] = [
            {"content": r["content"], "category": r["category"], "confidence": r["confidence"]}
            for r in cursor.fetchall()
        ]
        
        return context
    
    async def store_learning(self, category: str, content: str, confidence: float = 1.0) -> dict:
        """Store a learning entry."""
        await self.initialize()
        
        entry_id = self._generate_id(content)
        cursor = self.db_conn.cursor()
        
        # Check if similar learning exists
        cursor.execute("""
            SELECT id, usage_count FROM learnings WHERE id = ?
        """, (entry_id,))
        existing = cursor.fetchone()
        
        if existing:
            cursor.execute("""
                UPDATE learnings SET usage_count = usage_count + 1, 
                last_used = julianday('now'), confidence = MAX(confidence, ?)
                WHERE id = ?
            """, (confidence, entry_id))
        else:
            cursor.execute("""
                INSERT INTO learnings (id, category, content, confidence)
                VALUES (?, ?, ?, ?)
            """, (entry_id, category, content, confidence))
            
            # Also store in Qdrant for semantic search
            if self.qdrant_client:
                await self.store_memory("learnings", content, {
                    "category": category,
                    "confidence": confidence,
                    "learning_id": entry_id
                })
        
        self.db_conn.commit()
        return {"id": entry_id, "status": "stored"}
    
    async def sync_file_to_memory(self, file_path: str, content: str) -> dict:
        """Sync a file's content to semantic memory."""
        await self.initialize()
        
        # Create summary/embedding of file content
        summary = content[:2000] if len(content) > 2000 else content
        
        metadata = {
            "file_path": file_path,
            "file_type": Path(file_path).suffix,
            "char_count": len(content),
            "line_count": content.count('\n') + 1
        }
        
        return await self.store_memory("file_summaries", summary, metadata)
    
    def handle_mcp_request(self, request: dict) -> dict:
        """Handle MCP protocol requests."""
        method = request.get("method", "")
        params = request.get("params", {})
        
        if method == "tools/list":
            return {
                "tools": [
                    {
                        "name": "memory_store",
                        "description": "Store information in semantic memory",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "collection": {"type": "string", "enum": list(COLLECTIONS.keys())},
                                "content": {"type": "string"},
                                "metadata": {"type": "object"}
                            },
                            "required": ["collection", "content"]
                        }
                    },
                    {
                        "name": "memory_search",
                        "description": "Search semantic memory using natural language",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "collection": {"type": "string", "enum": list(COLLECTIONS.keys())},
                                "query": {"type": "string"},
                                "limit": {"type": "integer", "default": 5}
                            },
                            "required": ["collection", "query"]
                        }
                    },
                    {
                        "name": "memory_context",
                        "description": "Get aggregated context for current project",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "project_path": {"type": "string"}
                            }
                        }
                    },
                    {
                        "name": "learning_store",
                        "description": "Store a learning or insight",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "category": {"type": "string"},
                                "content": {"type": "string"},
                                "confidence": {"type": "number", "default": 1.0}
                            },
                            "required": ["category", "content"]
                        }
                    }
                ]
            }
        
        elif method == "tools/call":
            tool_name = params.get("name")
            args = params.get("arguments", {})
            
            loop = asyncio.get_event_loop()
            
            if tool_name == "memory_store":
                result = loop.run_until_complete(
                    self.store_memory(args["collection"], args["content"], args.get("metadata"))
                )
            elif tool_name == "memory_search":
                result = loop.run_until_complete(
                    self.search_memory(args["collection"], args["query"], args.get("limit", 5))
                )
            elif tool_name == "memory_context":
                result = loop.run_until_complete(
                    self.get_context(args.get("project_path", "."))
                )
            elif tool_name == "learning_store":
                result = loop.run_until_complete(
                    self.store_learning(args["category"], args["content"], args.get("confidence", 1.0))
                )
            else:
                return {"error": f"Unknown tool: {tool_name}"}
            
            return {"content": [{"type": "text", "text": json.dumps(result)}]}
        
        elif method == "resources/list":
            return {
                "resources": [
                    {
                        "uri": f"memory://{collection}",
                        "name": collection,
                        "description": desc,
                        "mimeType": "application/json"
                    }
                    for collection, desc in COLLECTIONS.items()
                ]
            }
        
        return {"error": "Unknown method"}


def main():
    """Main entry point for MCP server."""
    server = QdrantMemoryServer()
    
    # Read from stdin, write to stdout (MCP stdio transport)
    for line in sys.stdin:
        try:
            request = json.loads(line.strip())
            response = server.handle_mcp_request(request)
            response["jsonrpc"] = "2.0"
            response["id"] = request.get("id")
            print(json.dumps(response), flush=True)
        except json.JSONDecodeError as e:
            logger.error(f"Invalid JSON: {e}")
        except Exception as e:
            logger.error(f"Error handling request: {e}")
            print(json.dumps({
                "jsonrpc": "2.0",
                "id": None,
                "error": {"code": -32603, "message": str(e)}
            }), flush=True)


if __name__ == "__main__":
    main()
PYEOF

    chmod +x "$MCP_DIR/qdrant-memory-server.py"
    log_success "Qdrant MCP server created"
}

#-------------------------------------------------------------------------------
# Programming-Optimized Agent YAML Configurations
#-------------------------------------------------------------------------------
create_agent_configs() {
    log_info "Creating programming-optimized agent configurations..."
    
    # Orchestrator Agent
    cat > "$AGENTS_DIR/orchestrator.md" << 'AGENTEOF'
---
name: orchestrator
description: Master coordinator for multi-agent task orchestration
model: claude-sonnet-4-20250514
temperature: 0.3
max_tokens: 8192
system_prompt: |
  You are the Orchestrator agent in a multi-agent Claude Code system.
  
  Your responsibilities:
  1. Decompose complex tasks into subtasks for specialized agents
  2. Coordinate agent execution order based on dependencies
  3. Aggregate results and synthesize final outputs
  4. Monitor progress and handle failures gracefully
  
  Available agents to delegate to:
  - researcher: Deep analysis, documentation review, API exploration
  - implementer: Code writing, refactoring, feature implementation
  - reviewer: Code review, testing, quality assurance
  - debugger: Bug investigation, error analysis, performance profiling
  
  Task delegation format:
  ```task
  agent: <agent_name>
  priority: <1-10>
  description: <detailed task description>
  dependencies: [<task_ids>]
  expected_output: <what you expect back>
  ```
  
  Always think through the full execution plan before delegating.
capabilities:
  - task_decomposition
  - agent_coordination
  - result_aggregation
  - failure_recovery
tools:
  - Task
  - Read
  - Glob
  - Grep
memory_collections:
  - project_context
  - session_memory
---

# Orchestrator Agent

I coordinate complex multi-agent workflows. I analyze tasks, create execution plans,
delegate to specialized agents, and synthesize results into coherent outputs.

## Workflow Pattern

1. **Analyze** - Understand the full scope of the request
2. **Plan** - Create dependency-aware execution plan
3. **Delegate** - Spawn appropriate specialist agents
4. **Monitor** - Track progress and handle issues
5. **Synthesize** - Combine results into final deliverable
AGENTEOF

    # Researcher Agent
    cat > "$AGENTS_DIR/researcher.md" << 'AGENTEOF'
---
name: researcher
description: Deep analysis and knowledge gathering specialist
model: claude-sonnet-4-20250514
temperature: 0.4
max_tokens: 8192
system_prompt: |
  You are a Research specialist agent focused on deep analysis and knowledge gathering.
  
  Your responsibilities:
  1. Analyze codebases to understand architecture and patterns
  2. Research APIs, libraries, and documentation
  3. Investigate issues and find root causes
  4. Gather context needed for implementation decisions
  
  Research methodology:
  1. Start with broad exploration (file structure, key modules)
  2. Identify patterns and conventions used
  3. Deep dive into relevant sections
  4. Document findings in structured format
  
  Output format:
  ```research
  ## Summary
  <high-level findings>
  
  ## Key Patterns
  - <pattern 1>
  - <pattern 2>
  
  ## Relevant Code Locations
  - <file:lines> - <description>
  
  ## Recommendations
  <actionable recommendations>
  
  ## Open Questions
  <things that need clarification>
  ```
capabilities:
  - codebase_analysis
  - documentation_review
  - pattern_recognition
  - dependency_analysis
tools:
  - Read
  - Glob
  - Grep
  - LS
memory_collections:
  - code_patterns
  - learnings
---

# Researcher Agent

I specialize in deep analysis and knowledge gathering. I thoroughly explore codebases,
analyze patterns, research documentation, and provide comprehensive insights.
AGENTEOF

    # Implementer Agent
    cat > "$AGENTS_DIR/implementer.md" << 'AGENTEOF'
---
name: implementer
description: Expert code implementation and feature development
model: claude-sonnet-4-20250514
temperature: 0.2
max_tokens: 16384
system_prompt: |
  You are an Implementation specialist agent focused on writing high-quality code.
  
  Your responsibilities:
  1. Implement features following established patterns
  2. Write clean, maintainable, well-documented code
  3. Follow project conventions and style guides
  4. Create appropriate tests for new code
  
  Implementation principles:
  - DRY (Don't Repeat Yourself)
  - SOLID principles
  - Meaningful names and clear structure
  - Comprehensive error handling
  - Performance-conscious design
  
  Before implementing:
  1. Review existing patterns in the codebase
  2. Understand the full context of the change
  3. Plan the implementation approach
  4. Consider edge cases and error scenarios
  
  Code output should include:
  - Clear comments explaining complex logic
  - Type annotations where applicable
  - Error handling for failure modes
  - Unit test suggestions
capabilities:
  - feature_implementation
  - code_refactoring
  - test_writing
  - documentation
tools:
  - Read
  - Write
  - Edit
  - Glob
  - Grep
memory_collections:
  - code_patterns
  - project_context
---

# Implementer Agent

I specialize in writing high-quality code implementations. I follow project patterns,
write clean and maintainable code, and ensure comprehensive error handling.
AGENTEOF

    # Reviewer Agent
    cat > "$AGENTS_DIR/reviewer.md" << 'AGENTEOF'
---
name: reviewer
description: Code review and quality assurance specialist
model: claude-sonnet-4-20250514
temperature: 0.3
max_tokens: 8192
system_prompt: |
  You are a Code Review specialist agent focused on quality assurance.
  
  Your responsibilities:
  1. Review code for correctness, clarity, and maintainability
  2. Identify potential bugs, security issues, and performance problems
  3. Verify adherence to project conventions
  4. Suggest improvements and alternatives
  
  Review checklist:
  - [ ] Logic correctness
  - [ ] Error handling completeness
  - [ ] Edge case coverage
  - [ ] Security considerations
  - [ ] Performance implications
  - [ ] Code style consistency
  - [ ] Documentation adequacy
  - [ ] Test coverage
  
  Review output format:
  ```review
  ## Summary
  <overall assessment>
  
  ## Critical Issues
  - <issue with severity and location>
  
  ## Suggestions
  - <improvement suggestion>
  
  ## Positive Aspects
  - <what was done well>
  
  ## Approval Status
  <APPROVED | NEEDS_CHANGES | BLOCKED>
  ```
capabilities:
  - code_review
  - security_analysis
  - performance_review
  - style_checking
tools:
  - Read
  - Glob
  - Grep
memory_collections:
  - code_patterns
  - learnings
---

# Reviewer Agent

I specialize in thorough code review and quality assurance. I identify issues,
verify correctness, and ensure code meets quality standards.
AGENTEOF

    # Debugger Agent
    cat > "$AGENTS_DIR/debugger.md" << 'AGENTEOF'
---
name: debugger
description: Bug investigation and error analysis specialist
model: claude-sonnet-4-20250514
temperature: 0.2
max_tokens: 8192
system_prompt: |
  You are a Debugging specialist agent focused on bug investigation.
  
  Your responsibilities:
  1. Analyze error messages and stack traces
  2. Trace execution paths to find root causes
  3. Identify and fix bugs systematically
  4. Prevent regression through proper fixes
  
  Debugging methodology:
  1. Reproduce - Understand how to trigger the issue
  2. Isolate - Narrow down the problem location
  3. Identify - Find the root cause
  4. Fix - Implement the minimal correct fix
  5. Verify - Confirm the fix works
  6. Prevent - Add tests to prevent regression
  
  Debug output format:
  ```debug
  ## Issue Summary
  <what's happening>
  
  ## Root Cause
  <why it's happening>
  
  ## Location
  <file:lines where the bug exists>
  
  ## Fix
  <proposed fix with explanation>
  
  ## Prevention
  <how to prevent similar issues>
  ```
capabilities:
  - error_analysis
  - root_cause_identification
  - fix_implementation
  - regression_prevention
tools:
  - Read
  - Write
  - Edit
  - Glob
  - Grep
  - Bash
memory_collections:
  - learnings
  - code_patterns
---

# Debugger Agent

I specialize in systematic bug investigation and resolution. I analyze errors,
trace execution paths, identify root causes, and implement reliable fixes.
AGENTEOF

    # Meta Agent (Self-improvement)
    cat > "$AGENTS_DIR/meta-agent.md" << 'AGENTEOF'
---
name: meta-agent
description: System optimization and self-improvement specialist
model: claude-sonnet-4-20250514
temperature: 0.5
max_tokens: 8192
system_prompt: |
  You are a Meta-agent responsible for system optimization and improvement.
  
  Your responsibilities:
  1. Analyze agent performance and effectiveness
  2. Identify patterns in successful vs failed tasks
  3. Suggest improvements to agent configurations
  4. Optimize workflows and coordination
  
  Optimization areas:
  - Agent prompt effectiveness
  - Tool usage patterns
  - Memory utilization
  - Task decomposition strategies
  - Coordination efficiency
  
  Analysis output format:
  ```meta
  ## Performance Analysis
  <metrics and observations>
  
  ## Identified Patterns
  - Success patterns: <what works>
  - Failure patterns: <what doesn't>
  
  ## Recommendations
  - <specific improvement with rationale>
  
  ## Priority Actions
  1. <most impactful improvement>
  ```
capabilities:
  - performance_analysis
  - pattern_recognition
  - optimization_recommendation
  - workflow_improvement
tools:
  - Read
  - Glob
  - Grep
memory_collections:
  - learnings
  - session_memory
---

# Meta Agent

I analyze and optimize the multi-agent system itself. I identify patterns,
measure effectiveness, and recommend improvements to agent configurations and workflows.
AGENTEOF

    log_success "Agent configurations created"
}

#-------------------------------------------------------------------------------
# LSP Configuration System with TUI
#-------------------------------------------------------------------------------
create_lsp_system() {
    log_info "Creating LSP configuration system..."
    
    # LSP Manager Script
    cat > "$SCRIPTS_DIR/lsp-manager.py" << 'PYEOF'
#!/usr/bin/env python3
"""
LSP Configuration Manager for Claude Code Hivemind V3
Provides TUI-based LSP configuration and management.
"""

import json
import os
import sqlite3
import subprocess
import sys
from pathlib import Path

CLAUDE_DIR = Path.home() / ".claude"
DB_PATH = CLAUDE_DIR / "hivemind.db"
LSP_DIR = CLAUDE_DIR / "lsp"

# Preconfigured LSP templates
LSP_TEMPLATES = {
    "quickshell-qml": {
        "language": "quickshell-qml",
        "display_name": "QuickShell QML",
        "server_command": "qmlls",
        "server_args": ["--build-dir", "."],
        "root_markers": ["*.qml", "shell.qml", "quickshell.conf"],
        "file_patterns": ["*.qml"],
        "installation": {
            "arch": "yay -S qt6-languageserver qt6-declarative",
            "manual": "Install Qt6 QML Language Server from Qt"
        },
        "initialization_options": {
            "qmlImportPaths": [],
            "qmltypesFiles": []
        },
        "settings": {
            "qmlls": {
                "trace": {"server": "verbose"},
                "useQmlImportPathEnvVar": True
            }
        }
    },
    "hyprland": {
        "language": "hyprland",
        "display_name": "Hyprland Config",
        "server_command": "hyprls",
        "server_args": [],
        "root_markers": ["hyprland.conf", ".hyprland"],
        "file_patterns": ["*.conf", "hyprland.conf", "hyprland/*.conf"],
        "installation": {
            "arch": "yay -S hyprls-git",
            "manual": "cargo install hyprls"
        },
        "initialization_options": {},
        "settings": {}
    },
    "python": {
        "language": "python",
        "display_name": "Python (Pyright)",
        "server_command": "pyright-langserver",
        "server_args": ["--stdio"],
        "root_markers": ["pyproject.toml", "setup.py", "requirements.txt", ".git"],
        "file_patterns": ["*.py"],
        "installation": {
            "arch": "sudo pacman -S pyright",
            "pip": "pip install pyright"
        },
        "initialization_options": {},
        "settings": {
            "python": {
                "analysis": {
                    "autoSearchPaths": True,
                    "useLibraryCodeForTypes": True,
                    "diagnosticMode": "workspace"
                }
            }
        }
    },
    "typescript": {
        "language": "typescript",
        "display_name": "TypeScript",
        "server_command": "typescript-language-server",
        "server_args": ["--stdio"],
        "root_markers": ["tsconfig.json", "package.json", ".git"],
        "file_patterns": ["*.ts", "*.tsx", "*.js", "*.jsx"],
        "installation": {
            "npm": "npm install -g typescript typescript-language-server"
        },
        "initialization_options": {},
        "settings": {}
    },
    "rust": {
        "language": "rust",
        "display_name": "Rust (rust-analyzer)",
        "server_command": "rust-analyzer",
        "server_args": [],
        "root_markers": ["Cargo.toml", ".git"],
        "file_patterns": ["*.rs"],
        "installation": {
            "arch": "sudo pacman -S rust-analyzer",
            "rustup": "rustup component add rust-analyzer"
        },
        "initialization_options": {},
        "settings": {
            "rust-analyzer": {
                "checkOnSave": {"command": "clippy"},
                "cargo": {"allFeatures": True}
            }
        }
    },
    "go": {
        "language": "go",
        "display_name": "Go (gopls)",
        "server_command": "gopls",
        "server_args": [],
        "root_markers": ["go.mod", "go.sum", ".git"],
        "file_patterns": ["*.go"],
        "installation": {
            "arch": "sudo pacman -S gopls",
            "go": "go install golang.org/x/tools/gopls@latest"
        },
        "initialization_options": {},
        "settings": {
            "gopls": {
                "staticcheck": True,
                "analyses": {"unusedparams": True}
            }
        }
    },
    "lua": {
        "language": "lua",
        "display_name": "Lua",
        "server_command": "lua-language-server",
        "server_args": [],
        "root_markers": [".luarc.json", ".luacheckrc", ".git"],
        "file_patterns": ["*.lua"],
        "installation": {
            "arch": "sudo pacman -S lua-language-server"
        },
        "initialization_options": {},
        "settings": {}
    },
    "bash": {
        "language": "bash",
        "display_name": "Bash",
        "server_command": "bash-language-server",
        "server_args": ["start"],
        "root_markers": [".git"],
        "file_patterns": ["*.sh", "*.bash", ".bashrc", ".zshrc"],
        "installation": {
            "npm": "npm install -g bash-language-server"
        },
        "initialization_options": {},
        "settings": {}
    }
}


def get_db_connection():
    """Get database connection."""
    conn = sqlite3.connect(str(DB_PATH))
    conn.row_factory = sqlite3.Row
    return conn


def install_lsp(language: str) -> bool:
    """Install LSP for a language."""
    if language not in LSP_TEMPLATES:
        print(f"Unknown language: {language}")
        return False
    
    template = LSP_TEMPLATES[language]
    install_info = template.get("installation", {})
    
    print(f"\nInstalling {template['display_name']} LSP...")
    
    # Try Arch-specific installation first
    if "arch" in install_info:
        try:
            subprocess.run(install_info["arch"], shell=True, check=True)
            return True
        except subprocess.CalledProcessError:
            print("Arch installation failed, trying alternatives...")
    
    # Try other installation methods
    for method, cmd in install_info.items():
        if method == "arch":
            continue
        try:
            subprocess.run(cmd, shell=True, check=True)
            return True
        except subprocess.CalledProcessError:
            continue
    
    print(f"Failed to install {template['display_name']} LSP")
    return False


def configure_lsp(language: str) -> dict:
    """Configure and store LSP settings."""
    if language not in LSP_TEMPLATES:
        raise ValueError(f"Unknown language: {language}")
    
    template = LSP_TEMPLATES[language]
    
    conn = get_db_connection()
    cursor = conn.cursor()
    
    # Generate unique ID
    import hashlib
    lsp_id = hashlib.sha256(language.encode()).hexdigest()[:16]
    
    cursor.execute("""
        INSERT OR REPLACE INTO lsp_configs 
        (id, language, server_command, server_args, root_markers, 
         file_patterns, initialization_options, settings, enabled)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1)
    """, (
        lsp_id,
        language,
        template["server_command"],
        json.dumps(template["server_args"]),
        json.dumps(template["root_markers"]),
        json.dumps(template["file_patterns"]),
        json.dumps(template["initialization_options"]),
        json.dumps(template["settings"])
    ))
    
    conn.commit()
    conn.close()
    
    return template


def list_configured_lsps() -> list:
    """List all configured LSPs."""
    conn = get_db_connection()
    cursor = conn.cursor()
    cursor.execute("SELECT * FROM lsp_configs WHERE enabled = 1")
    results = [dict(row) for row in cursor.fetchall()]
    conn.close()
    return results


def run_tui():
    """Run the TUI for LSP configuration."""
    try:
        import dialog
        d = dialog.Dialog(dialog="dialog")
        d.set_background_title("Claude Hivemind V3 - LSP Configuration")
    except ImportError:
        # Fallback to basic CLI
        run_cli_menu()
        return
    
    while True:
        code, tag = d.menu(
            "LSP Configuration Manager",
            choices=[
                ("1", "Install Preconfigured LSP"),
                ("2", "Configure Custom LSP"),
                ("3", "List Configured LSPs"),
                ("4", "Test LSP Connection"),
                ("5", "Exit")
            ]
        )
        
        if code != d.OK or tag == "5":
            break
        
        if tag == "1":
            choices = [(k, v["display_name"]) for k, v in LSP_TEMPLATES.items()]
            code, selection = d.menu("Select LSP to Install", choices=choices)
            if code == d.OK:
                install_lsp(selection)
                configure_lsp(selection)
                d.msgbox(f"Installed and configured {selection} LSP")
        
        elif tag == "2":
            # Custom LSP configuration form
            code, values = d.form(
                "Configure Custom LSP",
                [
                    ("Language ID", 1, 1, "", 1, 20, 30, 50),
                    ("Server Command", 2, 1, "", 2, 20, 30, 100),
                    ("Server Args (comma-separated)", 3, 1, "", 3, 20, 30, 200),
                    ("File Patterns (comma-separated)", 4, 1, "*.ext", 4, 20, 30, 100),
                    ("Root Markers (comma-separated)", 5, 1, ".git", 5, 20, 30, 100)
                ]
            )
            if code == d.OK and values[0] and values[1]:
                custom_template = {
                    "language": values[0],
                    "display_name": values[0],
                    "server_command": values[1],
                    "server_args": [a.strip() for a in values[2].split(",") if a.strip()],
                    "file_patterns": [p.strip() for p in values[3].split(",") if p.strip()],
                    "root_markers": [m.strip() for m in values[4].split(",") if m.strip()],
                    "initialization_options": {},
                    "settings": {}
                }
                LSP_TEMPLATES[values[0]] = custom_template
                configure_lsp(values[0])
                d.msgbox(f"Configured custom LSP: {values[0]}")
        
        elif tag == "3":
            lsps = list_configured_lsps()
            if lsps:
                text = "\n".join([f"- {l['language']}: {l['server_command']}" for l in lsps])
            else:
                text = "No LSPs configured"
            d.msgbox(f"Configured LSPs:\n\n{text}")
        
        elif tag == "4":
            lsps = list_configured_lsps()
            if not lsps:
                d.msgbox("No LSPs configured to test")
                continue
            choices = [(l["language"], l["server_command"]) for l in lsps]
            code, selection = d.menu("Select LSP to Test", choices=choices)
            if code == d.OK:
                test_lsp(selection)


def run_cli_menu():
    """Fallback CLI menu without dialog."""
    while True:
        print("\n=== LSP Configuration Manager ===")
        print("1. Install Preconfigured LSP")
        print("2. List Available LSPs")
        print("3. List Configured LSPs")
        print("4. Exit")
        
        choice = input("\nSelect option: ").strip()
        
        if choice == "1":
            print("\nAvailable LSPs:")
            for i, (key, val) in enumerate(LSP_TEMPLATES.items(), 1):
                print(f"  {i}. {val['display_name']} ({key})")
            selection = input("\nEnter language ID: ").strip()
            if selection in LSP_TEMPLATES:
                install_lsp(selection)
                configure_lsp(selection)
        
        elif choice == "2":
            print("\nAvailable LSP Templates:")
            for key, val in LSP_TEMPLATES.items():
                print(f"  - {key}: {val['display_name']}")
        
        elif choice == "3":
            lsps = list_configured_lsps()
            print("\nConfigured LSPs:")
            for lsp in lsps:
                print(f"  - {lsp['language']}: {lsp['server_command']}")
        
        elif choice == "4":
            break


def test_lsp(language: str) -> bool:
    """Test if LSP server is working."""
    conn = get_db_connection()
    cursor = conn.cursor()
    cursor.execute("SELECT * FROM lsp_configs WHERE language = ?", (language,))
    config = cursor.fetchone()
    conn.close()
    
    if not config:
        print(f"LSP not configured: {language}")
        return False
    
    try:
        # Try to start the LSP server
        cmd = [config["server_command"]] + json.loads(config["server_args"])
        proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE
        )
        
        # Send initialize request
        init_request = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "processId": os.getpid(),
                "rootUri": None,
                "capabilities": {}
            }
        }
        
        content = json.dumps(init_request)
        message = f"Content-Length: {len(content)}\r\n\r\n{content}"
        proc.stdin.write(message.encode())
        proc.stdin.flush()
        
        # Wait briefly for response
        import select
        if select.select([proc.stdout], [], [], 2)[0]:
            print(f"✓ {language} LSP server responding")
            proc.terminate()
            return True
        else:
            print(f"✗ {language} LSP server not responding")
            proc.terminate()
            return False
            
    except FileNotFoundError:
        print(f"✗ {language} LSP server not found: {config['server_command']}")
        return False
    except Exception as e:
        print(f"✗ {language} LSP test failed: {e}")
        return False


def main():
    """Main entry point."""
    if len(sys.argv) > 1:
        cmd = sys.argv[1]
        if cmd == "install" and len(sys.argv) > 2:
            language = sys.argv[2]
            install_lsp(language)
            configure_lsp(language)
        elif cmd == "list":
            for lsp in list_configured_lsps():
                print(f"{lsp['language']}: {lsp['server_command']}")
        elif cmd == "test" and len(sys.argv) > 2:
            test_lsp(sys.argv[2])
        elif cmd == "tui":
            run_tui()
        else:
            print("Usage: lsp-manager.py [install|list|test|tui] [language]")
    else:
        run_tui()


if __name__ == "__main__":
    main()
PYEOF

    chmod +x "$SCRIPTS_DIR/lsp-manager.py"
    
    # Create LSP integration for Claude
    cat > "$LSP_DIR/lsp-integration.json" << 'JSONEOF'
{
  "description": "LSP integration configuration for Claude Code",
  "defaultServers": {
    "quickshell-qml": {
      "command": "qmlls",
      "args": ["--build-dir", "."],
      "filetypes": ["qml"],
      "rootMarkers": ["*.qml", "shell.qml"]
    },
    "hyprland": {
      "command": "hyprls",
      "args": [],
      "filetypes": ["conf"],
      "rootMarkers": ["hyprland.conf"]
    }
  },
  "diagnosticsOnSave": true,
  "autoComplete": true,
  "hoverInfo": true,
  "gotoDefinition": true
}
JSONEOF

    log_success "LSP configuration system created"
}

#-------------------------------------------------------------------------------
# Hook Scripts for Claude CLI Issue Workarounds
#-------------------------------------------------------------------------------
create_hooks() {
    log_info "Creating hook scripts with CLI issue workarounds..."
    
    # Session Start Hook
    cat > "$HOOKS_DIR/session-start.sh" << 'HOOKEOF'
#!/bin/bash
# Session Start Hook - Initialize session and load context
# Handles: SessionStart event (startup|resume|compact)

set -e

CLAUDE_DIR="$HOME/.claude"
DB_FILE="$CLAUDE_DIR/hivemind.db"
SCRIPTS_DIR="$CLAUDE_DIR/scripts"

# Parse input JSON
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
TRIGGER=$(echo "$INPUT" | jq -r '.trigger // "startup"')

# Generate session ID if not provided
if [ -z "$SESSION_ID" ]; then
    SESSION_ID=$(uuidgen)
fi

# Initialize session in database
python3 "$SCRIPTS_DIR/memory-db.py" init_session "$SESSION_ID" "$TRIGGER"

# Start context watcher in background (workaround for PreCompact unreliability - Issue #13572)
if [ "$TRIGGER" = "startup" ]; then
    nohup "$CLAUDE_DIR/scripts/context-watcher.sh" "$SESSION_ID" > /dev/null 2>&1 &
fi

# Output must be valid JSON for hook system
echo '{"status": "initialized", "session_id": "'"$SESSION_ID"'"}'
HOOKEOF

    # Context Injection Hook (UserPromptSubmit)
    # Workaround for SessionStart not receiving full context
    cat > "$HOOKS_DIR/inject-context.sh" << 'HOOKEOF'
#!/bin/bash
# Context Injection Hook - Inject memory context into prompts
# Handles: UserPromptSubmit event

set -e

CLAUDE_DIR="$HOME/.claude"
SCRIPTS_DIR="$CLAUDE_DIR/scripts"
MCP_DIR="$CLAUDE_DIR/mcp"

# Read input
INPUT=$(cat)
PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')

# Skip if no prompt
if [ -z "$PROMPT" ]; then
    echo "$INPUT"
    exit 0
fi

# Get relevant context from Qdrant memory (if available)
CONTEXT=$(python3 "$MCP_DIR/qdrant-memory-server.py" search_context "$PROMPT" 2>/dev/null || echo "")

# If we have relevant context, prepend it
if [ -n "$CONTEXT" ] && [ "$CONTEXT" != "null" ] && [ "$CONTEXT" != "[]" ]; then
    # Format: Add context as system note
    ENHANCED_PROMPT="[Relevant Memory Context]\n$CONTEXT\n\n[User Request]\n$PROMPT"
    echo "$INPUT" | jq --arg prompt "$ENHANCED_PROMPT" '.prompt = $prompt'
else
    echo "$INPUT"
fi
HOOKEOF

    # Subagent Complete Hook
    cat > "$HOOKS_DIR/subagent-complete.sh" << 'HOOKEOF'
#!/bin/bash
# Subagent Complete Hook - Track completed subagent tasks
# Handles: SubagentStop event

set -e

CLAUDE_DIR="$HOME/.claude"
DB_FILE="$CLAUDE_DIR/hivemind.db"

# Read input
INPUT=$(cat)
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty')
RESULT=$(echo "$INPUT" | jq -r '.result // empty')
EXIT_CODE=$(echo "$INPUT" | jq -r '.exit_code // 0')

if [ -n "$AGENT_ID" ]; then
    # Update agent task status in database
    sqlite3 "$DB_FILE" << SQL
UPDATE agent_tasks 
SET status = CASE WHEN $EXIT_CODE = 0 THEN 'completed' ELSE 'failed' END,
    completed_at = julianday('now'),
    result_summary = '$(echo "$RESULT" | sed "s/'/''/g" | head -c 1000)'
WHERE id = '$AGENT_ID';
SQL
fi

# Pass through
echo "$INPUT"
HOOKEOF

    # Update Plan Hook (Stop event)
    cat > "$HOOKS_DIR/update-plan.sh" << 'HOOKEOF'
#!/bin/bash
# Update Plan Hook - Save state on stop
# Handles: Stop event

set -e

CLAUDE_DIR="$HOME/.claude"
DB_FILE="$CLAUDE_DIR/hivemind.db"
PLANS_DIR="$CLAUDE_DIR/plans"

# Prevent hook loops
if [ "${STOP_HOOK_ACTIVE:-0}" = "1" ]; then
    exit 0
fi
export STOP_HOOK_ACTIVE=1

# Read input
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
STOP_REASON=$(echo "$INPUT" | jq -r '.stop_reason // "unknown"')

# Save current state
if [ -n "$SESSION_ID" ]; then
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    
    # Create checkpoint
    sqlite3 "$DB_FILE" << SQL
INSERT INTO context_snapshots (id, session_id, snapshot_type, trigger_reason)
VALUES ('snap_${TIMESTAMP}', '$SESSION_ID', 'stop', '$STOP_REASON');
SQL
    
    # If using Gemini for plan continuation
    if command -v gemini &> /dev/null; then
        # Generate plan continuation (async)
        (
            RECENT_TASKS=$(sqlite3 "$DB_FILE" "SELECT task_description FROM agent_tasks WHERE session_id='$SESSION_ID' ORDER BY started_at DESC LIMIT 5;")
            if [ -n "$RECENT_TASKS" ]; then
                echo "$RECENT_TASKS" | gemini "Generate a concise continuation plan for these tasks" > "$PLANS_DIR/continue_${SESSION_ID}.md" 2>/dev/null &
            fi
        ) &
    fi
fi

echo '{"status": "saved"}'
HOOKEOF

    # CRLF Fix Hook (PostToolUse for Write)
    # Workaround for Issue #2805
    cat > "$HOOKS_DIR/crlf-fix.sh" << 'HOOKEOF'
#!/bin/bash
# CRLF Fix Hook - Convert CRLF to LF on Linux
# Handles: PostToolUse event (matcher: Write)
# Workaround for Claude CLI Issue #2805

set -e

# Read input
INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_result.path // empty')

# Only process if we have a file path and it exists
if [ -n "$FILE_PATH" ] && [ -f "$FILE_PATH" ]; then
    # Check if file contains CRLF
    if grep -q $'\r' "$FILE_PATH" 2>/dev/null; then
        # Convert CRLF to LF
        sed -i 's/\r$//' "$FILE_PATH"
    fi
fi

# Pass through original input
echo "$INPUT"
HOOKEOF

    # Track Subagent Spawn Hook (PostToolUse for Task)
    cat > "$HOOKS_DIR/track-subagent-spawn.sh" << 'HOOKEOF'
#!/bin/bash
# Track Subagent Spawn Hook - Record spawned subagents
# Handles: PostToolUse event (matcher: Task)

set -e

CLAUDE_DIR="$HOME/.claude"
DB_FILE="$CLAUDE_DIR/hivemind.db"

# Read input
INPUT=$(cat)
TASK_PROMPT=$(echo "$INPUT" | jq -r '.tool_input.prompt // empty')
AGENT_ID=$(echo "$INPUT" | jq -r '.tool_result.agent_id // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')

if [ -n "$AGENT_ID" ] && [ -n "$TASK_PROMPT" ]; then
    # Determine agent type from prompt
    AGENT_TYPE="general"
    if echo "$TASK_PROMPT" | grep -qi "research\|analyze\|investigate"; then
        AGENT_TYPE="researcher"
    elif echo "$TASK_PROMPT" | grep -qi "implement\|code\|write\|create"; then
        AGENT_TYPE="implementer"
    elif echo "$TASK_PROMPT" | grep -qi "review\|check\|verify"; then
        AGENT_TYPE="reviewer"
    elif echo "$TASK_PROMPT" | grep -qi "debug\|fix\|error"; then
        AGENT_TYPE="debugger"
    fi
    
    # Record in database
    sqlite3 "$DB_FILE" << SQL
INSERT INTO agent_tasks (id, session_id, agent_type, task_description, status)
VALUES ('$AGENT_ID', '$SESSION_ID', '$AGENT_TYPE', '$(echo "$TASK_PROMPT" | sed "s/'/''/g" | head -c 500)', 'running');
SQL
fi

echo "$INPUT"
HOOKEOF

    # Register Subagent Hook (PreToolUse for Task)
    cat > "$HOOKS_DIR/register-subagent.sh" << 'HOOKEOF'
#!/bin/bash
# Register Subagent Hook - Pre-register subagent before spawn
# Handles: PreToolUse event (matcher: Task)

set -e

CLAUDE_DIR="$HOME/.claude"

# Read input
INPUT=$(cat)
TASK_PROMPT=$(echo "$INPUT" | jq -r '.tool_input.prompt // empty')

# Check if this should be an isolated subagent (no hooks)
# This prevents settings pollution and hook loops
if echo "$TASK_PROMPT" | grep -qi "isolated\|no-hooks\|clean"; then
    # Modify to use isolated settings
    echo "$INPUT" | jq '.tool_input.settings_override = {"disableAllHooks": true}'
else
    echo "$INPUT"
fi
HOOKEOF

    # Pre-compact Hook
    cat > "$HOOKS_DIR/pre-compact.sh" << 'HOOKEOF'
#!/bin/bash
# Pre-compact Hook - Save context before compaction
# Handles: PreCompact event
# Note: This hook may be unreliable (Issue #13572), context-watcher.sh provides backup

set -e

CLAUDE_DIR="$HOME/.claude"
DB_FILE="$CLAUDE_DIR/hivemind.db"
SNAPSHOTS_DIR="$CLAUDE_DIR/snapshots"

# Read input
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
COMPACT_TYPE=$(echo "$INPUT" | jq -r '.compact_type // "auto"')
TOKEN_COUNT=$(echo "$INPUT" | jq -r '.token_count // 0')

TIMESTAMP=$(date +%Y%m%d_%H%M%S)

if [ -n "$SESSION_ID" ]; then
    # Save snapshot
    sqlite3 "$DB_FILE" << SQL
INSERT INTO context_snapshots (id, session_id, snapshot_type, trigger_reason, token_count)
VALUES ('compact_${TIMESTAMP}', '$SESSION_ID', 'pre_compact', '$COMPACT_TYPE', $TOKEN_COUNT);
SQL
    
    # Save full context to file
    echo "$INPUT" | jq '.context // {}' > "$SNAPSHOTS_DIR/${SESSION_ID}_${TIMESTAMP}.json"
fi

echo '{"status": "snapshot_saved"}'
HOOKEOF

    # Session End Hook
    cat > "$HOOKS_DIR/session-end.sh" << 'HOOKEOF'
#!/bin/bash
# Session End Hook - Cleanup and final save
# Handles: SessionEnd event

set -e

CLAUDE_DIR="$HOME/.claude"
DB_FILE="$CLAUDE_DIR/hivemind.db"
SCRIPTS_DIR="$CLAUDE_DIR/scripts"

# Read input
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')

if [ -n "$SESSION_ID" ]; then
    # Kill context watcher for this session
    pkill -f "context-watcher.sh $SESSION_ID" 2>/dev/null || true
    
    # Finalize session
    python3 "$SCRIPTS_DIR/memory-db.py" end_session "$SESSION_ID"
    
    # Sync pending memories to Qdrant
    python3 "$CLAUDE_DIR/mcp/qdrant-memory-server.py" sync_pending 2>/dev/null || true
fi

echo '{"status": "ended"}'
HOOKEOF

    # Make all hooks executable
    chmod +x "$HOOKS_DIR"/*.sh
    
    log_success "Hook scripts created"
}

#-------------------------------------------------------------------------------
# Context Watcher Script (Workaround for PreCompact unreliability)
#-------------------------------------------------------------------------------
create_context_watcher() {
    log_info "Creating context watcher script..."
    
    cat > "$SCRIPTS_DIR/context-watcher.sh" << 'WATCHEREOF'
#!/bin/bash
# Context Watcher - Monitor transcript for context growth
# Workaround for unreliable PreCompact hook (Issue #13572)
# Triggers manual context preservation at 75%/90% thresholds

SESSION_ID="${1:-default}"
CLAUDE_DIR="$HOME/.claude"
DB_FILE="$CLAUDE_DIR/hivemind.db"
TRANSCRIPT_DIR="$HOME/.cursor/projects"

# Estimated context window (tokens)
MAX_CONTEXT=200000
WARN_THRESHOLD=0.75
CRITICAL_THRESHOLD=0.90

# Find transcript files
find_transcript() {
    find "$TRANSCRIPT_DIR" -name "*.jsonl" -newer /tmp/context_check_$SESSION_ID 2>/dev/null | head -1
}

estimate_tokens() {
    local file="$1"
    if [ -f "$file" ]; then
        # Rough estimate: 4 chars per token
        local chars=$(wc -c < "$file")
        echo $((chars / 4))
    else
        echo 0
    fi
}

save_checkpoint() {
    local reason="$1"
    local tokens="$2"
    
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    sqlite3 "$DB_FILE" << SQL
INSERT INTO context_snapshots (id, session_id, snapshot_type, trigger_reason, token_count)
VALUES ('watch_${TIMESTAMP}', '$SESSION_ID', 'watcher', '$reason', $tokens);
SQL
    
    notify-send "Claude Context Alert" "$reason - Tokens: $tokens" 2>/dev/null || true
}

# Touch marker file
touch /tmp/context_check_$SESSION_ID

# Main watch loop
while true; do
    sleep 30
    
    TRANSCRIPT=$(find_transcript)
    if [ -n "$TRANSCRIPT" ]; then
        TOKENS=$(estimate_tokens "$TRANSCRIPT")
        RATIO=$(echo "scale=2; $TOKENS / $MAX_CONTEXT" | bc)
        
        if (( $(echo "$RATIO >= $CRITICAL_THRESHOLD" | bc -l) )); then
            save_checkpoint "CRITICAL: Context at ${RATIO}%" "$TOKENS"
        elif (( $(echo "$RATIO >= $WARN_THRESHOLD" | bc -l) )); then
            save_checkpoint "WARNING: Context at ${RATIO}%" "$TOKENS"
        fi
        
        touch /tmp/context_check_$SESSION_ID
    fi
done
WATCHEREOF

    chmod +x "$SCRIPTS_DIR/context-watcher.sh"
    log_success "Context watcher created"
}

#-------------------------------------------------------------------------------
# Memory Database Python Helper
#-------------------------------------------------------------------------------
create_memory_db_script() {
    log_info "Creating memory database helper script..."
    
    cat > "$SCRIPTS_DIR/memory-db.py" << 'PYEOF'
#!/usr/bin/env python3
"""
Memory Database Helper for Claude Code Hivemind V3
Provides CLI interface for database operations.
"""

import json
import sqlite3
import sys
from datetime import datetime
from pathlib import Path
import hashlib

CLAUDE_DIR = Path.home() / ".claude"
DB_PATH = CLAUDE_DIR / "hivemind.db"


def get_connection():
    conn = sqlite3.connect(str(DB_PATH))
    conn.row_factory = sqlite3.Row
    return conn


def init_session(session_id: str, trigger: str = "startup"):
    """Initialize a new session."""
    conn = get_connection()
    cursor = conn.cursor()
    
    cursor.execute("""
        INSERT OR REPLACE INTO project_state (id, project_path, current_phase, updated_at)
        VALUES (1, ?, 'active', julianday('now'))
    """, (str(Path.cwd()),))
    
    conn.commit()
    conn.close()
    print(json.dumps({"status": "initialized", "session_id": session_id}))


def end_session(session_id: str):
    """End a session and save final state."""
    conn = get_connection()
    cursor = conn.cursor()
    
    # Mark all running tasks as interrupted
    cursor.execute("""
        UPDATE agent_tasks SET status = 'interrupted', completed_at = julianday('now')
        WHERE session_id = ? AND status = 'running'
    """, (session_id,))
    
    conn.commit()
    conn.close()
    print(json.dumps({"status": "ended", "session_id": session_id}))


def store_memory(collection: str, content: str, metadata: str = "{}"):
    """Store a memory entry."""
    conn = get_connection()
    cursor = conn.cursor()
    
    entry_id = hashlib.sha256((content + str(datetime.now())).encode()).hexdigest()[:16]
    
    cursor.execute("""
        INSERT INTO memory_entries (id, collection, content, metadata)
        VALUES (?, ?, ?, ?)
    """, (entry_id, collection, content, metadata))
    
    conn.commit()
    conn.close()
    print(json.dumps({"id": entry_id, "status": "stored"}))


def search_memory(collection: str, query: str, limit: int = 5):
    """Search memory entries."""
    conn = get_connection()
    cursor = conn.cursor()
    
    cursor.execute("""
        SELECT id, content, metadata FROM memory_entries
        WHERE collection = ? AND content LIKE ?
        ORDER BY created_at DESC LIMIT ?
    """, (collection, f"%{query}%", limit))
    
    results = [dict(row) for row in cursor.fetchall()]
    conn.close()
    print(json.dumps(results))


def store_learning(category: str, content: str, confidence: float = 1.0):
    """Store a learning entry."""
    conn = get_connection()
    cursor = conn.cursor()
    
    entry_id = hashlib.sha256(content.encode()).hexdigest()[:16]
    
    cursor.execute("""
        INSERT OR REPLACE INTO learnings (id, category, content, confidence, usage_count)
        VALUES (?, ?, ?, ?, COALESCE((SELECT usage_count + 1 FROM learnings WHERE id = ?), 1))
    """, (entry_id, category, content, confidence, entry_id))
    
    conn.commit()
    conn.close()
    print(json.dumps({"id": entry_id, "status": "stored"}))


def get_learnings(category: str = None, limit: int = 10):
    """Get learning entries."""
    conn = get_connection()
    cursor = conn.cursor()
    
    if category:
        cursor.execute("""
            SELECT id, category, content, confidence, usage_count FROM learnings
            WHERE category = ? ORDER BY usage_count DESC LIMIT ?
        """, (category, limit))
    else:
        cursor.execute("""
            SELECT id, category, content, confidence, usage_count FROM learnings
            ORDER BY usage_count DESC LIMIT ?
        """, (limit,))
    
    results = [dict(row) for row in cursor.fetchall()]
    conn.close()
    print(json.dumps(results))


def get_stats():
    """Get database statistics."""
    conn = get_connection()
    cursor = conn.cursor()
    
    stats = {}
    
    cursor.execute("SELECT COUNT(*) FROM memory_entries")
    stats["memory_entries"] = cursor.fetchone()[0]
    
    cursor.execute("SELECT COUNT(*) FROM learnings")
    stats["learnings"] = cursor.fetchone()[0]
    
    cursor.execute("SELECT COUNT(*) FROM agent_tasks")
    stats["agent_tasks"] = cursor.fetchone()[0]
    
    cursor.execute("SELECT COUNT(*) FROM context_snapshots")
    stats["snapshots"] = cursor.fetchone()[0]
    
    cursor.execute("SELECT COUNT(*) FROM lsp_configs WHERE enabled = 1")
    stats["lsp_configs"] = cursor.fetchone()[0]
    
    conn.close()
    print(json.dumps(stats))


def main():
    if len(sys.argv) < 2:
        print("Usage: memory-db.py <command> [args...]")
        print("Commands: init_session, end_session, store_memory, search_memory,")
        print("          store_learning, get_learnings, get_stats")
        sys.exit(1)
    
    command = sys.argv[1]
    args = sys.argv[2:]
    
    commands = {
        "init_session": lambda: init_session(args[0] if args else "default", args[1] if len(args) > 1 else "startup"),
        "end_session": lambda: end_session(args[0] if args else "default"),
        "store_memory": lambda: store_memory(args[0], args[1], args[2] if len(args) > 2 else "{}"),
        "search_memory": lambda: search_memory(args[0], args[1], int(args[2]) if len(args) > 2 else 5),
        "store_learning": lambda: store_learning(args[0], args[1], float(args[2]) if len(args) > 2 else 1.0),
        "get_learnings": lambda: get_learnings(args[0] if args else None, int(args[1]) if len(args) > 1 else 10),
        "get_stats": get_stats
    }
    
    if command in commands:
        commands[command]()
    else:
        print(f"Unknown command: {command}")
        sys.exit(1)


if __name__ == "__main__":
    main()
PYEOF

    chmod +x "$SCRIPTS_DIR/memory-db.py"
    log_success "Memory database helper created"
}

#-------------------------------------------------------------------------------
# Settings.json Configuration
#-------------------------------------------------------------------------------
create_settings() {
    log_info "Creating comprehensive settings.json..."
    
    cat > "$CLAUDE_DIR/settings.json" << 'JSONEOF'
{
  "permissions": {
    "allow": [
      "Read(*)",
      "Grep(*)",
      "Glob(*)",
      "LS(*)",
      "Bash(python3 ~/.claude/scripts/*)",
      "Bash(python3 ~/.claude/mcp/*)",
      "Bash(~/.claude/scripts/*)",
      "Bash(~/.claude/hooks/*)",
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
      "Bash(grep*)",
      "Bash(rg*)",
      "Bash(uuidgen)",
      "Bash(date*)",
      "Bash(mkdir*)",
      "Bash(sqlite3*)",
      "Bash(jq*)",
      "Bash(notify-send*)"
    ],
    "deny": [
      "Bash(rm -rf /)",
      "Bash(rm -rf ~)",
      "Bash(:(){ :|:& };:)",
      "Bash(chmod -R 777 /)",
      "Bash(dd if=/dev/*)",
      "Bash(mkfs.*)"
    ]
  },
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume|compact",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/hivemind/session-start.sh",
            "timeout": 10000
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/hivemind/inject-context.sh",
            "timeout": 5000
          }
        ]
      }
    ],
    "SubagentStop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/hivemind/subagent-complete.sh",
            "timeout": 5000
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/hivemind/update-plan.sh",
            "timeout": 15000
          }
        ]
      }
    ],
    "PreCompact": [
      {
        "matcher": "auto|manual",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/hivemind/pre-compact.sh",
            "timeout": 30000
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
            "command": "~/.claude/hooks/hivemind/crlf-fix.sh",
            "timeout": 2000
          }
        ]
      },
      {
        "matcher": "Task",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/hivemind/track-subagent-spawn.sh",
            "timeout": 5000
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
            "command": "~/.claude/hooks/hivemind/register-subagent.sh",
            "timeout": 2000
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/hivemind/session-end.sh",
            "timeout": 10000
          }
        ]
      }
    ]
  },
  "mcpServers": {
    "qdrant-memory": {
      "command": "python3",
      "args": ["~/.claude/mcp/qdrant-memory-server.py"],
      "env": {
        "PYTHONUNBUFFERED": "1"
      }
    }
  },
  "env": {
    "CLAUDE_HIVEMIND_ENABLED": "1",
    "CLAUDE_HIVEMIND_VERSION": "3",
    "PYTHONUNBUFFERED": "1",
    "QDRANT_PATH": "~/.claude/qdrant/storage"
  }
}
JSONEOF

    # Create no-hooks settings for isolated subagents
    mkdir -p "$CLAUDE_DIR/isolated"
    cat > "$CLAUDE_DIR/isolated/no-hooks.json" << 'JSONEOF'
{
  "disableAllHooks": true,
  "permissions": {
    "allow": ["Read(*)", "Grep(*)", "Glob(*)", "LS(*)"],
    "deny": []
  }
}
JSONEOF

    log_success "Settings configuration created"
}

#-------------------------------------------------------------------------------
# Memory Files (CLAUDE.md and related)
#-------------------------------------------------------------------------------
create_memory_files() {
    log_info "Creating memory and instruction files..."
    
    # Global CLAUDE.md
    # Note: @ imports have known bugs in global CLAUDE.md (Issue #1041)
    # Using direct content instead of imports
    cat > "$CLAUDE_DIR/CLAUDE.md" << 'MDEOF'
# Claude Code Hivemind V3

You are operating within the Hivemind V3 multi-agent coordination system with Qdrant-powered semantic memory.

## System Architecture

### Memory System
- **Qdrant Vector DB**: Semantic search across all project memories
- **SQLite (hivemind.db)**: Structured data, task tracking, learnings
- **Collections**: project_context, code_patterns, session_memory, learnings, file_summaries

### Available Agents
- **orchestrator**: Task decomposition and coordination
- **researcher**: Deep analysis and knowledge gathering
- **implementer**: Code writing and feature development
- **reviewer**: Code review and quality assurance
- **debugger**: Bug investigation and resolution
- **meta-agent**: System optimization

### MCP Tools
Use the qdrant-memory MCP for persistent memory:
- `memory_store`: Store information in semantic memory
- `memory_search`: Search using natural language
- `memory_context`: Get aggregated project context
- `learning_store`: Store learnings and insights

## Workflow Guidelines

1. **Check Memory First**: Search relevant collections before starting tasks
2. **Store Learnings**: Capture patterns, decisions, and insights
3. **Coordinate Tasks**: Use orchestrator for complex multi-step work
4. **Track Progress**: Agent tasks are automatically tracked

## Code Quality Standards

- Follow existing project patterns
- Write comprehensive error handling
- Include type annotations where applicable
- Document complex logic
- Consider edge cases

## Known Workarounds Active

- **CRLF Fix**: Auto-converts line endings on file writes (Issue #2805)
- **Context Watcher**: Monitors context growth (PreCompact unreliability #13572)
- **Settings Isolation**: Subagents can run with isolated settings
MDEOF

    # Commands directory
    cat > "$COMMANDS_DIR/hivemind.md" << 'CMDEOF'
# /hivemind - Multi-Agent Coordination

Activate multi-agent coordination mode.

## Usage
```
/hivemind <task_description>
```

## Behavior
1. Analyzes the task complexity
2. Decomposes into subtasks if needed
3. Assigns to appropriate specialist agents
4. Coordinates execution and aggregates results

## Examples
```
/hivemind Implement user authentication with JWT
/hivemind Refactor the database layer for better performance
/hivemind Debug the payment processing failures
```
CMDEOF

    cat > "$COMMANDS_DIR/memory.md" << 'CMDEOF'
# /memory - Memory Operations

Interact with the Qdrant semantic memory system.

## Usage
```
/memory store <collection> <content>
/memory search <collection> <query>
/memory context
/memory learn <category> <content>
```

## Collections
- project_context: Project-specific decisions and context
- code_patterns: Learned patterns and best practices
- session_memory: Current session temporary memory
- learnings: Long-term insights
- file_summaries: File content summaries

## Examples
```
/memory store code_patterns "Use dependency injection for testability"
/memory search learnings "error handling"
/memory context
/memory learn debugging "Always check null references first"
```
CMDEOF

    cat > "$COMMANDS_DIR/lsp.md" << 'CMDEOF'
# /lsp - LSP Configuration

Manage Language Server Protocol configurations.

## Usage
```
/lsp install <language>
/lsp list
/lsp test <language>
/lsp tui
```

## Preconfigured Languages
- quickshell-qml: QuickShell QML development
- hyprland: Hyprland configuration
- python: Python with Pyright
- typescript: TypeScript/JavaScript
- rust: Rust with rust-analyzer
- go: Go with gopls
- lua: Lua
- bash: Bash scripts

## Examples
```
/lsp install quickshell-qml
/lsp list
/lsp test python
/lsp tui
```
CMDEOF

    log_success "Memory files created"
}

#-------------------------------------------------------------------------------
# Verification and Testing
#-------------------------------------------------------------------------------
verify_installation() {
    log_info "Verifying installation..."
    
    local errors=0
    
    # Check directories
    for dir in "$AGENTS_DIR" "$HOOKS_DIR" "$SCRIPTS_DIR" "$MCP_DIR" "$LSP_DIR" "$QDRANT_DIR"; do
        if [ ! -d "$dir" ]; then
            log_error "Missing directory: $dir"
            ((errors++))
        fi
    done
    
    # Check critical files
    local critical_files=(
        "$CLAUDE_DIR/settings.json"
        "$CLAUDE_DIR/hivemind.db"
        "$MCP_DIR/qdrant-memory-server.py"
        "$SCRIPTS_DIR/memory-db.py"
        "$SCRIPTS_DIR/lsp-manager.py"
        "$HOOKS_DIR/session-start.sh"
        "$HOOKS_DIR/crlf-fix.sh"
    )
    
    for file in "${critical_files[@]}"; do
        if [ ! -f "$file" ]; then
            log_error "Missing file: $file"
            ((errors++))
        fi
    done
    
    # Test database
    if ! sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM memory_entries;" &>/dev/null; then
        log_error "Database not properly initialized"
        ((errors++))
    fi
    
    # Test Python dependencies
    if ! python3 -c "import sqlite3, json, hashlib" 2>/dev/null; then
        log_error "Python dependencies missing"
        ((errors++))
    fi
    
    # Check Qdrant availability
    if python3 -c "from qdrant_client import QdrantClient" 2>/dev/null; then
        log_success "Qdrant client available"
    else
        log_warn "Qdrant client not available - running in SQLite-only mode"
    fi
    
    if [ $errors -eq 0 ]; then
        log_success "All verification checks passed!"
        return 0
    else
        log_error "$errors verification errors found"
        return 1
    fi
}

#-------------------------------------------------------------------------------
# Preconfigure QuickShell/QML and Hyprland LSPs
#-------------------------------------------------------------------------------
preconfigure_lsps() {
    log_info "Preconfiguring LSPs for QuickShell/QML and Hyprland..."
    
    # Configure QuickShell/QML LSP
    python3 "$SCRIPTS_DIR/lsp-manager.py" install quickshell-qml 2>/dev/null || \
        log_warn "QuickShell/QML LSP installation skipped (manual install may be needed)"
    
    # Configure Hyprland LSP
    python3 "$SCRIPTS_DIR/lsp-manager.py" install hyprland 2>/dev/null || \
        log_warn "Hyprland LSP installation skipped (manual install may be needed)"
    
    log_success "LSP preconfiguration complete"
}

#-------------------------------------------------------------------------------
# Main Installation Flow
#-------------------------------------------------------------------------------
main() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║     Claude Code Hivemind V3 Setup                             ║"
    echo "║     Multi-Agent Coordination with Qdrant Memory               ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    # Check if running on Arch Linux
    if [ -f /etc/arch-release ]; then
        log_info "Detected Arch Linux"
    else
        log_warn "This script is optimized for Arch Linux"
    fi
    
    # Run installation steps
    install_prerequisites
    setup_directories
    setup_database
    create_qdrant_mcp_server
    create_agent_configs
    create_lsp_system
    create_hooks
    create_context_watcher
    create_memory_db_script
    create_settings
    create_memory_files
    preconfigure_lsps
    
    # Verify installation
    echo ""
    verify_installation
    
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║     Installation Complete!                                    ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Restart Claude Code to load new configuration"
    echo "  2. Run 'python3 ~/.claude/scripts/lsp-manager.py tui' to configure LSPs"
    echo "  3. Use '/memory context' to check memory system status"
    echo "  4. Use '/hivemind <task>' for multi-agent coordination"
    echo ""
    echo "Configuration location: $CLAUDE_DIR"
    echo "Database: $DB_FILE"
    echo "Qdrant storage: $QDRANT_STORAGE"
    echo ""
}

# Run main function
main "$@"
