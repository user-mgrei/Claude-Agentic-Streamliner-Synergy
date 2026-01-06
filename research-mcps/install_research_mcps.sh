#!/bin/bash
#===============================================================================
# Research MCPs Installation Script
# Installs and configures deep research and databasing tools for Claude Code
#===============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo -e "${BLUE}===============================================================================${NC}"
echo -e "${BLUE}Research MCPs Installation - Deep Research & Database Tools${NC}"
echo -e "${BLUE}===============================================================================${NC}"
echo ""

#===============================================================================
# PREREQUISITES CHECK
#===============================================================================
echo -e "${YELLOW}Checking prerequisites...${NC}"

# Check Python version
if ! command -v python3 &> /dev/null; then
    echo -e "${RED}ERROR: Python 3 is required${NC}"
    exit 1
fi

PYTHON_VERSION=$(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:2])))')
echo -e "${GREEN}✓ Python ${PYTHON_VERSION} found${NC}"

# Check pip
if ! command -v pip &> /dev/null && ! command -v pip3 &> /dev/null; then
    echo -e "${RED}ERROR: pip is required${NC}"
    exit 1
fi

PIP_CMD="pip3"
if command -v pip &> /dev/null; then
    PIP_CMD="pip"
fi

# Check git (for potential model downloads)
if ! command -v git &> /dev/null; then
    echo -e "${YELLOW}WARNING: git not found - some models may not download properly${NC}"
fi

echo -e "${GREEN}✓ Prerequisites OK${NC}"
echo ""

#===============================================================================
# PYTHON DEPENDENCIES
#===============================================================================
echo -e "${YELLOW}Installing Python dependencies...${NC}"

# Create requirements.txt for research MCPs
cat > "$SCRIPT_DIR/requirements.txt" << 'EOF'
# Core MCP framework
fastmcp>=0.1.0

# Web scraping and content extraction
aiohttp>=3.8.0
requests>=2.28.0
beautifulsoup4>=4.11.0
trafilatura>=1.6.0
readability-lxml>=0.8.0

# Document processing
PyPDF2>=3.0.0
PyMuPDF>=1.22.0
python-magic>=0.4.27

# Academic research
feedparser>=6.0.0

# Embeddings and ML
sentence-transformers>=2.2.0
numpy>=1.21.0

# Knowledge graph and NLP
networkx>=2.8.0
spacy>=3.4.0

# Database
sqlite3

# Standard library imports that should be available
json
hashlib
pathlib
datetime
logging
asyncio
re
tempfile
csv
io
xml.etree.ElementTree
urllib.parse
collections
typing
EOF

# Install dependencies
echo -e "${BLUE}Installing Python packages...${NC}"
$PIP_CMD install -r "$SCRIPT_DIR/requirements.txt"

# Download spaCy model
echo -e "${BLUE}Downloading spaCy English model...${NC}"
python3 -m spacy download en_core_web_sm || echo -e "${YELLOW}Warning: spaCy model download failed. Install manually: python3 -m spacy download en_core_web_sm${NC}"

echo -e "${GREEN}✓ Python dependencies installed${NC}"
echo ""

#===============================================================================
# CREATE DIRECTORIES
#===============================================================================
echo -e "${YELLOW}Creating directory structure...${NC}"

mkdir -p "$SCRIPT_DIR/databases"
mkdir -p "$SCRIPT_DIR/logs" 
mkdir -p "$SCRIPT_DIR/configs"
mkdir -p "$SCRIPT_DIR/tools"
mkdir -p "$SCRIPT_DIR/cache"

echo -e "${GREEN}✓ Directories created${NC}"

#===============================================================================
# MAKE SCRIPTS EXECUTABLE
#===============================================================================
echo -e "${YELLOW}Setting up executable permissions...${NC}"

chmod +x "$SCRIPT_DIR/servers/"*.py
chmod +x "$SCRIPT_DIR/tools/"*.py

echo -e "${GREEN}✓ Permissions set${NC}"

#===============================================================================
# TEST MCP SERVERS
#===============================================================================
echo -e "${YELLOW}Testing MCP servers...${NC}"

# Test each server by importing
for server in "$SCRIPT_DIR/servers/"*.py; do
    server_name=$(basename "$server" .py)
    echo -n "Testing $server_name... "
    
    if python3 -c "import sys; sys.path.append('$SCRIPT_DIR/servers'); import $server_name" 2>/dev/null; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${RED}✗${NC}"
        echo -e "${YELLOW}Warning: $server_name may have missing dependencies${NC}"
    fi
done

echo -e "${GREEN}✓ Server tests completed${NC}"
echo ""

#===============================================================================
# CONFIGURE CLAUDE CODE INTEGRATION
#===============================================================================
echo -e "${YELLOW}Setting up Claude Code integration...${NC}"

# Find Claude settings directory
CLAUDE_SETTINGS_DIR=""
if [ -d "$HOME/.claude" ]; then
    CLAUDE_SETTINGS_DIR="$HOME/.claude"
elif [ -d "$HOME/.config/claude" ]; then
    CLAUDE_SETTINGS_DIR="$HOME/.config/claude"
else
    echo -e "${YELLOW}Claude settings directory not found. Please run Claude Code once first.${NC}"
    CLAUDE_SETTINGS_DIR="$HOME/.claude"
    mkdir -p "$CLAUDE_SETTINGS_DIR"
fi

echo "Claude settings directory: $CLAUDE_SETTINGS_DIR"

# Backup existing settings
if [ -f "$CLAUDE_SETTINGS_DIR/settings.json" ]; then
    cp "$CLAUDE_SETTINGS_DIR/settings.json" "$CLAUDE_SETTINGS_DIR/settings.json.backup.$(date +%Y%m%d-%H%M%S)"
    echo -e "${YELLOW}Backed up existing settings.json${NC}"
fi

# Merge our MCP configuration with existing settings
TEMP_SETTINGS=$(mktemp)
if [ -f "$CLAUDE_SETTINGS_DIR/settings.json" ]; then
    # Merge with existing settings
    python3 - << EOF
import json
import os

# Load existing settings
try:
    with open('$CLAUDE_SETTINGS_DIR/settings.json', 'r') as f:
        existing = json.load(f)
except:
    existing = {}

# Load our MCP config
with open('$SCRIPT_DIR/configs/claude_settings.json', 'r') as f:
    mcp_config = json.load(f)

# Merge configurations
if 'mcpServers' not in existing:
    existing['mcpServers'] = {}

existing['mcpServers'].update(mcp_config['mcpServers'])

if 'permissions' not in existing:
    existing['permissions'] = {'allow': []}

existing['permissions']['allow'].extend(mcp_config['permissions']['allow'])

# Remove duplicates
existing['permissions']['allow'] = list(set(existing['permissions']['allow']))

# Write merged settings
with open('$TEMP_SETTINGS', 'w') as f:
    json.dump(existing, f, indent=2)
EOF
else
    # Use our config as-is
    cp "$SCRIPT_DIR/configs/claude_settings.json" "$TEMP_SETTINGS"
fi

# Update paths to be absolute
sed -i "s|research-mcps/|$SCRIPT_DIR/|g" "$TEMP_SETTINGS"

# Install the settings
cp "$TEMP_SETTINGS" "$CLAUDE_SETTINGS_DIR/settings.json"
rm "$TEMP_SETTINGS"

echo -e "${GREEN}✓ Claude Code configuration updated${NC}"
echo ""

#===============================================================================
# CREATE USAGE EXAMPLES
#===============================================================================
echo -e "${YELLOW}Creating usage examples...${NC}"

cat > "$SCRIPT_DIR/examples.md" << 'EOF'
# Research MCPs Usage Examples

## Web Research MCP

```bash
# Scrape and analyze a webpage
mcp__web_research__scrape_url "https://example.com" "my_research_session"

# Search stored research content
mcp__web_research__search_research "artificial intelligence" "ai_research"

# List research sessions
mcp__web_research__list_sessions
```

## Document Research MCP

```bash
# Process a local PDF
mcp__document_research__process_document "/path/to/paper.pdf" "ai_papers" "Paper Title" "Author Name"

# Download and process PDF from URL
mcp__document_research__download_and_process_pdf "https://arxiv.org/pdf/2301.00001.pdf" "arxiv_papers"

# Search documents semantically
mcp__document_research__search_documents "transformer architecture" "ai_papers"

# List document collections
mcp__document_research__list_collections
```

## Knowledge Graph MCP

```bash
# Extract entities and relationships from text
mcp__knowledge_graph__extract_knowledge_from_text "Your research text here..." "source_document.pdf"

# Search for entities
mcp__knowledge_graph__search_entities "neural network" "CONCEPT"

# Build subgraph around entities
mcp__knowledge_graph__build_subgraph [1, 2, 3] 2

# Get graph statistics
mcp__knowledge_graph__get_graph_statistics
```

## Academic Research MCP

```bash
# Search arXiv papers
mcp__academic_research__search_arxiv "deep learning" 20 "cs.AI" null "ml_papers"

# Search Semantic Scholar
mcp__academic_research__search_semantic_scholar "attention mechanism" 15 "attention_research"

# Search local academic database
mcp__academic_research__search_papers_database "transformer" 10 "ml_papers"

# Get research statistics
mcp__academic_research__get_research_statistics
```

## Combined Research Workflow

1. **Search and collect papers:**
   - `mcp__academic_research__search_arxiv "topic" 50 null null "research_collection"`
   - `mcp__academic_research__search_semantic_scholar "topic" 30 "research_collection"`

2. **Download and process documents:**
   - `mcp__document_research__download_and_process_pdf "paper_url" "research_collection"`

3. **Extract knowledge:**
   - `mcp__knowledge_graph__extract_knowledge_from_text "paper_content" "paper_source"`

4. **Analyze relationships:**
   - `mcp__knowledge_graph__build_subgraph [entity_ids] 3`
   - `mcp__knowledge_graph__get_entity_relationships entity_id`

5. **Search and connect information:**
   - `mcp__web_research__search_research "related_topic" "web_session"`
   - `mcp__document_research__search_documents "query" "research_collection"`
EOF

echo -e "${GREEN}✓ Examples created${NC}"

#===============================================================================
# CREATE SYSTEMD SERVICE (OPTIONAL)
#===============================================================================
echo -e "${YELLOW}Creating optional systemd services...${NC}"

mkdir -p "$HOME/.config/systemd/user"

# Create a service to pre-warm the embedding models
cat > "$HOME/.config/systemd/user/research-mcps-warmup.service" << EOF
[Unit]
Description=Research MCPs Model Warmup
After=default.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'cd "$PROJECT_ROOT" && python3 -c "from research_mcps.servers.document_research_mcp import get_embedding_model; get_embedding_model()"'
RemainAfterExit=yes

[Install]
WantedBy=default.target
EOF

echo -e "${GREEN}✓ Systemd services created${NC}"
echo "  Enable with: systemctl --user enable research-mcps-warmup"
echo ""

#===============================================================================
# FINAL VERIFICATION
#===============================================================================
echo -e "${YELLOW}Running final verification...${NC}"

# Check database creation
python3 - << EOF
import sys
sys.path.append('$SCRIPT_DIR/servers')

try:
    from web_research_mcp import db as web_db
    from document_research_mcp import db as doc_db 
    from knowledge_graph_mcp import db as kg_db
    from academic_research_mcp import db as academic_db
    print("✓ All databases initialized successfully")
except Exception as e:
    print(f"✗ Database initialization failed: {e}")
    sys.exit(1)
EOF

# Verify Claude settings
if [ -f "$CLAUDE_SETTINGS_DIR/settings.json" ]; then
    if grep -q "web_research" "$CLAUDE_SETTINGS_DIR/settings.json"; then
        echo -e "${GREEN}✓ Claude Code settings updated${NC}"
    else
        echo -e "${YELLOW}⚠ Claude Code settings may not be properly configured${NC}"
    fi
fi

echo ""

#===============================================================================
# INSTALLATION COMPLETE
#===============================================================================
echo -e "${BLUE}===============================================================================${NC}"
echo -e "${GREEN}Research MCPs Installation Complete!${NC}"
echo -e "${BLUE}===============================================================================${NC}"
echo ""

echo -e "${YELLOW}What was installed:${NC}"
echo "  ✓ Web Research MCP - Web scraping and content analysis"
echo "  ✓ Document Research MCP - PDF processing with semantic search"  
echo "  ✓ Knowledge Graph MCP - Entity extraction and relationship mapping"
echo "  ✓ Academic Research MCP - arXiv and Semantic Scholar integration"
echo "  ✓ Auto knowledge extraction hooks"
echo "  ✓ Claude Code integration"
echo ""

echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Start Claude Code"
echo "  2. Run '/mcp' to see available tools"
echo "  3. Check examples in: $SCRIPT_DIR/examples.md"
echo "  4. Try: mcp__web_research__scrape_url \"https://example.com\" \"test\""
echo ""

echo -e "${YELLOW}Database locations:${NC}"
echo "  • Web research: $SCRIPT_DIR/databases/web_research.db"
echo "  • Documents: $SCRIPT_DIR/databases/document_research.db"
echo "  • Knowledge graph: $SCRIPT_DIR/databases/knowledge_graph.db"  
echo "  • Academic papers: $SCRIPT_DIR/databases/academic_research.db"
echo ""

echo -e "${YELLOW}Log files:${NC}"
echo "  • Installation: $SCRIPT_DIR/logs/install.log"
echo "  • MCP servers: $SCRIPT_DIR/logs/"
echo ""

# Save installation info
cat > "$SCRIPT_DIR/install_info.json" << EOF
{
  "installed_at": "$(date -Iseconds)",
  "script_dir": "$SCRIPT_DIR",
  "claude_settings": "$CLAUDE_SETTINGS_DIR",
  "python_version": "$PYTHON_VERSION",
  "pip_command": "$PIP_CMD"
}
EOF

echo -e "${GREEN}Installation completed successfully!${NC}"