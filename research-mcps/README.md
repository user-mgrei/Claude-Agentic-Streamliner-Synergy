# Research MCPs - Deep Research & Database Tools

A comprehensive suite of MCP (Model Context Protocol) servers for Claude Code that provides advanced research capabilities including web scraping, document processing, knowledge graph construction, and academic research integration.

## Overview

This system transforms Claude Code into a powerful research assistant capable of:

- **Web Research**: Intelligent scraping and content extraction from websites
- **Document Analysis**: PDF processing with semantic search capabilities
- **Knowledge Graphs**: Entity extraction and relationship mapping across sources
- **Academic Research**: Integration with arXiv, Semantic Scholar, and other scholarly databases
- **Auto Knowledge Extraction**: Automatic entity and relationship extraction from scraped content

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Claude Code                             │
│  ┌─────────────────────────────────────────────────────────┐│
│  │                 MCP Integration                         ││
│  └─────────────────────────────────────────────────────────┘│
└──────────────────┬──────────────────┬──────────────────────┘
                   │                  │
    ┌──────────────▼─────────┐    ┌───▼──────────────┐
    │   Web Research MCP     │    │ Document Research │
    │   • Content scraping   │    │ • PDF processing  │
    │   • Session management │    │ • Semantic search │
    │   • Rate limiting      │    │ • Collections     │
    └─────────────┬──────────┘    └───┬──────────────┘
                  │                   │
    ┌─────────────▼──────────┐    ┌───▼──────────────┐
    │  Knowledge Graph MCP   │    │ Academic Research │
    │  • Entity extraction   │    │ • arXiv search    │
    │  • Relationship mapping│    │ • Semantic Scholar│
    │  • Graph analysis      │    │ • Citation analysis│
    └────────────────────────┘    └───────────────────┘
                  │
    ┌─────────────▼──────────┐
    │    SQLite Databases    │
    │    • web_research.db   │
    │    • documents.db      │
    │    • knowledge_graph.db│
    │    • academic.db       │
    └────────────────────────┘
```

## Features

### Web Research MCP (`web_research_mcp.py`)

**Capabilities:**
- Intelligent content extraction using Trafilatura and Readability
- Session-based organization of scraped content
- Bulk scraping with rate limiting
- Content search and export (JSON, Markdown, CSV)
- Automatic CRLF handling for cross-platform compatibility

**Key Tools:**
- `scrape_url` - Extract and store content from URLs
- `bulk_scrape` - Scrape multiple URLs with rate limiting  
- `search_research` - Search stored content semantically
- `list_sessions` - Manage research sessions
- `export_session` - Export research data in multiple formats

### Document Research MCP (`document_research_mcp.py`)

**Capabilities:**
- Multi-format document processing (PDF, TXT)
- Vector embeddings for semantic search
- Document collections for organization
- Automatic content chunking with overlap
- Support for both local files and URL downloads

**Key Tools:**
- `process_document` - Process local documents with embeddings
- `download_and_process_pdf` - Download and process PDFs from URLs
- `search_documents` - Semantic search across document collections
- `create_collection` - Organize documents into collections
- `list_collections` - View document collections

### Knowledge Graph MCP (`knowledge_graph_mcp.py`)

**Capabilities:**
- Named Entity Recognition using spaCy
- Relationship extraction based on proximity and patterns
- Vector similarity for entity deduplication
- Graph analysis with NetworkX
- Subgraph generation and visualization data

**Key Tools:**
- `extract_knowledge_from_text` - Extract entities and relationships
- `search_entities` - Find entities by name or type
- `get_entity_relationships` - Analyze entity connections
- `build_subgraph` - Create focused subgraphs
- `get_graph_statistics` - Analyze graph structure

### Academic Research MCP (`academic_research_mcp.py`)

**Capabilities:**
- arXiv integration with category filtering
- Semantic Scholar API integration  
- Citation analysis and tracking
- Author and venue statistics
- Research collection management

**Key Tools:**
- `search_arxiv` - Search arXiv papers with filters
- `search_semantic_scholar` - Access Semantic Scholar database
- `search_papers_database` - Search local academic database
- `get_paper_citations` - Analyze citation networks
- `create_research_collection` - Organize academic papers

## Installation

### Prerequisites

- Python 3.8+
- Claude Code installed and configured
- Git (for model downloads)
- 4GB+ RAM (for embedding models)

### Quick Install

```bash
cd research-mcps/
chmod +x install_research_mcps.sh
./install_research_mcps.sh
```

The installer will:
1. Check system prerequisites
2. Install Python dependencies
3. Download required AI models (spaCy, SentenceTransformers)
4. Create database structures
5. Configure Claude Code integration
6. Test all MCP servers

### Manual Installation

If you prefer manual setup:

```bash
# Install Python dependencies
pip install fastmcp aiohttp requests beautifulsoup4 trafilatura readability-lxml
pip install PyPDF2 PyMuPDF python-magic feedparser sentence-transformers numpy
pip install networkx spacy

# Download spaCy model
python -m spacy download en_core_web_sm

# Make scripts executable
chmod +x servers/*.py tools/*.py

# Update Claude Code settings
# Add the MCP configuration from configs/claude_settings.json to your ~/.claude/settings.json
```

## Usage Examples

### Basic Web Research Workflow

```python
# 1. Scrape content from a website
result = mcp__web_research__scrape_url("https://example.com", "my_research")

# 2. Automatically extract knowledge (via hook)
# Entities and relationships are automatically extracted and stored

# 3. Search the content
results = mcp__web_research__search_research("artificial intelligence", "my_research")

# 4. Export the research session
export = mcp__web_research__export_session("my_research", "markdown")
```

### Academic Research Pipeline

```python
# 1. Search for papers
arxiv_papers = mcp__academic_research__search_arxiv(
    "transformer architecture", 20, "cs.AI", None, "transformers_research"
)

semantic_papers = mcp__academic_research__search_semantic_scholar(
    "attention mechanism", 15, "transformers_research"
)

# 2. Download and process papers
for paper in arxiv_papers['papers']:
    if paper['pdf_url']:
        mcp__document_research__download_and_process_pdf(
            paper['pdf_url'], "transformers_research", paper['title']
        )

# 3. Search processed documents
results = mcp__document_research__search_documents(
    "self-attention mechanism", "transformers_research"
)

# 4. Build knowledge graph
for result in results:
    mcp__knowledge_graph__extract_knowledge_from_text(
        result['content'], f"paper_{result['document_id']}"
    )

# 5. Analyze relationships
entities = mcp__knowledge_graph__search_entities("attention", "CONCEPT")
if entities:
    subgraph = mcp__knowledge_graph__build_subgraph([entities[0]['entity_id']], 2)
```

### Document Analysis Workflow

```python
# 1. Create a collection
mcp__document_research__create_collection(
    "ai_papers", 
    "Collection of AI research papers",
    "Artificial Intelligence"
)

# 2. Process documents
mcp__document_research__process_document(
    "/path/to/paper.pdf", 
    "ai_papers", 
    "Attention Is All You Need"
)

# 3. Semantic search
results = mcp__document_research__search_documents(
    "transformer architecture", "ai_papers", 10
)

# 4. Extract knowledge from results
for result in results:
    mcp__knowledge_graph__extract_knowledge_from_text(
        result['content'], 
        f"doc_{result['document_id']}_page_{result['page_number']}"
    )
```

## Configuration

### Claude Code Integration

The system automatically configures Claude Code by updating `~/.claude/settings.json`:

```json
{
  "mcpServers": {
    "web_research": {
      "command": "python3",
      "args": ["research-mcps/servers/web_research_mcp.py"]
    },
    "document_research": {
      "command": "python3",
      "args": ["research-mcps/servers/document_research_mcp.py"]
    },
    "knowledge_graph": {
      "command": "python3", 
      "args": ["research-mcps/servers/knowledge_graph_mcp.py"]
    },
    "academic_research": {
      "command": "python3",
      "args": ["research-mcps/servers/academic_research_mcp.py"]
    }
  },
  "permissions": {
    "allow": [
      "mcp__web_research__*",
      "mcp__document_research__*",
      "mcp__knowledge_graph__*", 
      "mcp__academic_research__*"
    ]
  }
}
```

### Database Configuration

All databases are SQLite-based and stored in `research-mcps/databases/`:

- `web_research.db` - Scraped web content and sessions
- `document_research.db` - Processed documents with embeddings
- `knowledge_graph.db` - Entities, relationships, and graph data
- `academic_research.db` - Academic papers and citations

### Embedding Models

The system uses SentenceTransformers for semantic search:

- **Model**: `all-MiniLM-L6-v2` (384 dimensions)
- **Use case**: Fast, good quality embeddings for research content
- **Memory**: ~500MB RAM when loaded
- **Performance**: ~1000 embeddings/second on modern CPU

## Advanced Features

### Auto Knowledge Extraction

The system includes hooks that automatically extract knowledge:

```bash
# When you scrape a URL:
mcp__web_research__scrape_url("https://example.com", "session")

# This automatically triggers:
# 1. Content extraction and storage  
# 2. Entity and relationship extraction
# 3. Knowledge graph updates
# 4. Cross-reference with existing knowledge
```

### Knowledge Graph Analysis

Build and analyze knowledge graphs:

```python
# Get graph statistics
stats = mcp__knowledge_graph__get_graph_statistics()

# Find related entities
entity_id = 42
relationships = mcp__knowledge_graph__get_entity_relationships(entity_id)

# Build focused subgraphs
subgraph = mcp__knowledge_graph__build_subgraph([entity_id], max_depth=3)

# The subgraph includes:
# - Nodes with metadata (frequency, confidence, type)
# - Edges with relationship types and strength
# - Graph statistics (centrality, density, components)
```

### Citation Analysis

Track academic influence and connections:

```python
# Get citations for a paper
citations = mcp__academic_research__get_paper_citations(paper_id, True)

# Get research statistics
stats = mcp__academic_research__get_research_statistics()

# Includes:
# - Most cited papers
# - Top venues and authors
# - Publication trends over time
# - Citation networks and influence
```

## Performance Optimization

### Memory Management

- **Lazy Loading**: Models load only when first used
- **Connection Pooling**: SQLite connections are efficiently managed
- **Chunking**: Large documents split into optimal chunk sizes
- **Caching**: Embeddings cached to avoid recomputation

### Rate Limiting

- **Web Scraping**: Configurable delays between requests
- **API Calls**: Respect rate limits for academic APIs
- **Bulk Operations**: Batch processing with progress tracking
- **Retry Logic**: Exponential backoff for failed requests

### Database Optimization

- **Indexes**: Optimized indexes on frequently queried columns
- **WAL Mode**: SQLite WAL mode for concurrent access
- **Vacuum**: Automatic database optimization
- **Backups**: Built-in backup and export functionality

## Troubleshooting

### Common Issues

**MCP servers not loading:**
```bash
# Check if Python dependencies are installed
python3 -c "import fastmcp, aiohttp, requests; print('OK')"

# Test individual servers
python3 research-mcps/servers/web_research_mcp.py --test
```

**Embedding models not downloading:**
```bash
# Manual model download
python3 -c "from sentence_transformers import SentenceTransformer; SentenceTransformer('all-MiniLM-L6-v2')"

# spaCy model
python3 -m spacy download en_core_web_sm
```

**Database permissions:**
```bash
# Ensure database directory is writable
chmod 755 research-mcps/databases/
```

**Claude Code integration:**
```bash
# Verify settings.json syntax
python3 -c "import json; json.load(open('~/.claude/settings.json'))"

# Check MCP servers in Claude
# Run: /mcp in Claude Code
```

### Performance Issues

**Slow semantic search:**
- Reduce chunk size in document processing
- Limit search results with the `limit` parameter
- Consider using smaller embedding models

**Memory usage:**
- Models use ~500MB-1GB RAM each
- Disable unused MCPs in settings.json
- Process documents in smaller batches

**Database size:**
- Use `VACUUM` on SQLite databases periodically
- Export and archive old research sessions
- Set retention policies for scraped content

## API Reference

### Web Research MCP

| Tool | Description | Parameters |
|------|-------------|------------|
| `scrape_url` | Extract content from URL | `url, session_name, max_retries` |
| `bulk_scrape` | Scrape multiple URLs | `urls, session_name, delay` |
| `search_research` | Search stored content | `query, session_name, limit` |
| `list_sessions` | List research sessions | None |
| `get_session_summary` | Get session details | `session_name` |
| `export_session` | Export session data | `session_name, format_type` |

### Document Research MCP  

| Tool | Description | Parameters |
|------|-------------|------------|
| `process_document` | Process local document | `file_path, collection_name, title, author` |
| `download_and_process_pdf` | Download and process PDF | `url, collection_name, title, author` |
| `search_documents` | Semantic document search | `query, collection_name, limit` |
| `create_collection` | Create document collection | `collection_name, description` |
| `list_collections` | List all collections | None |
| `get_collection_summary` | Get collection details | `collection_name` |

### Knowledge Graph MCP

| Tool | Description | Parameters |
|------|-------------|------------|
| `extract_knowledge_from_text` | Extract entities/relationships | `text, source_document, document_id` |
| `search_entities` | Find entities | `query, entity_type, limit` |
| `get_entity_relationships` | Get entity connections | `entity_id, relationship_types` |
| `build_subgraph` | Create subgraph | `entity_ids, max_depth` |
| `get_graph_statistics` | Analyze graph structure | None |

### Academic Research MCP

| Tool | Description | Parameters |
|------|-------------|------------|
| `search_arxiv` | Search arXiv papers | `query, max_results, category, author, save_to_collection` |
| `search_semantic_scholar` | Search Semantic Scholar | `query, limit, save_to_collection` |
| `search_papers_database` | Search local papers | `query, limit, collection_name` |
| `get_paper_citations` | Get paper citations | `paper_id, include_context` |
| `create_research_collection` | Create paper collection | `collection_name, description, topic_focus` |
| `list_research_collections` | List paper collections | None |
| `get_research_statistics` | Get research stats | None |

## Contributing

This research MCP system is part of the Claude Agentic Streamliner Synergy project. Contributions are welcome!

### Development Setup

```bash
git clone <repository>
cd research-mcps/
pip install -e .
python3 -m pytest tests/
```

### Adding New MCPs

1. Create server file in `servers/`
2. Implement FastMCP tools
3. Add database schema if needed
4. Update configuration files
5. Add tests and documentation

### Testing

```bash
# Test individual MCPs
python3 servers/web_research_mcp.py
python3 servers/knowledge_graph_mcp.py

# Test installation
./install_research_mcps.sh --test

# Test Claude integration
# Start Claude Code and run: /mcp
```

## License

This project is part of the Claude Agentic Streamliner Synergy and follows the same licensing terms.

## Support

For issues and questions:
1. Check the troubleshooting section
2. Review the examples and API reference  
3. Test with minimal examples
4. Check Claude Code logs for MCP errors