#!/bin/bash
#===============================================================================
# Qdrant Vector Database Setup for Claude Code Hivemind
#
# This script sets up Qdrant for semantic memory search capabilities.
# Supports both server mode (Docker/native) and file-based storage.
#
# Options:
#   --docker     : Use Docker to run Qdrant server (recommended)
#   --native     : Install native Qdrant binary
#   --file       : Use file-based storage (no server required)
#   --skip-deps  : Skip Python dependency installation
#
# Requirements:
#   - Python 3.8+
#   - Docker (for --docker mode)
#   - pip3 for Python packages
#
# For Arch Linux: pacman -S python docker
#===============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
QDRANT_DATA_DIR="$CLAUDE_DIR/qdrant_data"
QDRANT_PORT="${QDRANT_PORT:-6333}"
QDRANT_GRPC_PORT="${QDRANT_GRPC_PORT:-6334}"

# Parse arguments
USE_DOCKER=false
USE_NATIVE=false
USE_FILE=false
SKIP_DEPS=false

for arg in "$@"; do
    case $arg in
        --docker) USE_DOCKER=true ;;
        --native) USE_NATIVE=true ;;
        --file) USE_FILE=true ;;
        --skip-deps) SKIP_DEPS=true ;;
        --help|-h)
            echo "Usage: $0 [--docker|--native|--file] [--skip-deps]"
            echo "  --docker    : Run Qdrant in Docker container (recommended)"
            echo "  --native    : Install native Qdrant binary"
            echo "  --file      : Use file-based storage (no server needed)"
            echo "  --skip-deps : Skip Python dependency installation"
            exit 0
            ;;
    esac
done

# Default to file storage if no mode specified
if ! $USE_DOCKER && ! $USE_NATIVE && ! $USE_FILE; then
    USE_FILE=true
    echo "==> No mode specified, defaulting to file-based storage"
fi

echo "==> Setting up Qdrant for Claude Code Hivemind..."
echo "    Mode: $([ $USE_DOCKER = true ] && echo 'Docker' || ([ $USE_NATIVE = true ] && echo 'Native' || echo 'File-based'))"

#===============================================================================
# Install Python dependencies
#===============================================================================
if ! $SKIP_DEPS; then
    echo ""
    echo "==> Installing Python dependencies..."
    
    # Check for pip
    if ! command -v pip3 &> /dev/null; then
        echo "ERROR: pip3 not found. Install with: sudo pacman -S python-pip"
        exit 1
    fi
    
    # Install qdrant-client
    pip3 install --user --upgrade qdrant-client 2>/dev/null || {
        echo "WARNING: Could not install qdrant-client with --user, trying without..."
        pip3 install qdrant-client
    }
    
    # Install sentence-transformers for embeddings
    echo "    Installing sentence-transformers (this may take a minute)..."
    pip3 install --user --upgrade sentence-transformers 2>/dev/null || {
        echo "WARNING: Could not install sentence-transformers with --user, trying without..."
        pip3 install sentence-transformers
    }
    
    echo "    Python dependencies installed!"
fi

#===============================================================================
# Docker setup
#===============================================================================
if $USE_DOCKER; then
    echo ""
    echo "==> Setting up Qdrant with Docker..."
    
    # Check for Docker
    if ! command -v docker &> /dev/null; then
        echo "ERROR: Docker not found. Install with: sudo pacman -S docker"
        echo "       Then: sudo systemctl enable --now docker"
        exit 1
    fi
    
    # Check if Docker is running
    if ! docker info &> /dev/null; then
        echo "ERROR: Docker daemon not running."
        echo "       Start with: sudo systemctl start docker"
        echo "       Add yourself to docker group: sudo usermod -aG docker $USER"
        exit 1
    fi
    
    # Create data directory
    mkdir -p "$QDRANT_DATA_DIR"
    
    # Check if container already exists
    if docker ps -a --format '{{.Names}}' | grep -q '^hivemind-qdrant$'; then
        echo "    Container 'hivemind-qdrant' already exists"
        if ! docker ps --format '{{.Names}}' | grep -q '^hivemind-qdrant$'; then
            echo "    Starting existing container..."
            docker start hivemind-qdrant
        else
            echo "    Container already running"
        fi
    else
        echo "    Pulling Qdrant image..."
        docker pull qdrant/qdrant:latest
        
        echo "    Creating container..."
        docker run -d \
            --name hivemind-qdrant \
            --restart unless-stopped \
            -p "${QDRANT_PORT}:6333" \
            -p "${QDRANT_GRPC_PORT}:6334" \
            -v "${QDRANT_DATA_DIR}:/qdrant/storage" \
            qdrant/qdrant:latest
            
        echo "    Waiting for Qdrant to start..."
        sleep 3
    fi
    
    # Verify connection
    if curl -s "http://localhost:${QDRANT_PORT}/collections" > /dev/null 2>&1; then
        echo "    Qdrant is running on port ${QDRANT_PORT}"
    else
        echo "WARNING: Could not connect to Qdrant. Check Docker logs:"
        echo "         docker logs hivemind-qdrant"
    fi
    
    # Create systemd user service for auto-start
    mkdir -p "$HOME/.config/systemd/user"
    cat > "$HOME/.config/systemd/user/hivemind-qdrant.service" << EOF
[Unit]
Description=Qdrant Docker Container for Hivemind
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/docker start hivemind-qdrant
ExecStop=/usr/bin/docker stop hivemind-qdrant

[Install]
WantedBy=default.target
EOF

    echo "    Created systemd user service"
    echo "    Enable auto-start: systemctl --user enable hivemind-qdrant"
fi

#===============================================================================
# Native binary setup (Arch Linux)
#===============================================================================
if $USE_NATIVE; then
    echo ""
    echo "==> Setting up native Qdrant..."
    
    # Check AUR helper
    if command -v yay &> /dev/null; then
        AUR_HELPER="yay"
    elif command -v paru &> /dev/null; then
        AUR_HELPER="paru"
    else
        echo "ERROR: No AUR helper found (yay or paru required)"
        echo "       Install yay: https://github.com/Jguer/yay"
        exit 1
    fi
    
    # Install Qdrant
    if ! command -v qdrant &> /dev/null; then
        echo "    Installing Qdrant from AUR..."
        $AUR_HELPER -S --noconfirm qdrant-bin || {
            echo "WARNING: AUR package failed, trying cargo install..."
            if command -v cargo &> /dev/null; then
                cargo install qdrant
            else
                echo "ERROR: Neither AUR nor cargo available for Qdrant installation"
                exit 1
            fi
        }
    else
        echo "    Qdrant already installed"
    fi
    
    # Create data directory
    mkdir -p "$QDRANT_DATA_DIR"
    
    # Create config file
    mkdir -p "$CLAUDE_DIR/qdrant_config"
    cat > "$CLAUDE_DIR/qdrant_config/config.yaml" << EOF
storage:
  storage_path: ${QDRANT_DATA_DIR}

service:
  http_port: ${QDRANT_PORT}
  grpc_port: ${QDRANT_GRPC_PORT}
  
log_level: INFO
EOF

    # Create systemd user service
    mkdir -p "$HOME/.config/systemd/user"
    cat > "$HOME/.config/systemd/user/hivemind-qdrant.service" << EOF
[Unit]
Description=Qdrant Vector Database for Hivemind
After=network.target

[Service]
Type=simple
ExecStart=$(which qdrant) --config-path ${CLAUDE_DIR}/qdrant_config/config.yaml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

    echo "    Created systemd user service"
    echo "    Start Qdrant: systemctl --user start hivemind-qdrant"
    echo "    Enable auto-start: systemctl --user enable hivemind-qdrant"
fi

#===============================================================================
# File-based storage setup (no server needed)
#===============================================================================
if $USE_FILE; then
    echo ""
    echo "==> Setting up file-based Qdrant storage..."
    
    # Create data directory
    mkdir -p "$QDRANT_DATA_DIR"
    
    # Set environment variable
    echo "    Data directory: $QDRANT_DATA_DIR"
    
    # Add to shell config
    SHELL_RC=""
    if [ -f "$HOME/.bashrc" ]; then
        SHELL_RC="$HOME/.bashrc"
    elif [ -f "$HOME/.zshrc" ]; then
        SHELL_RC="$HOME/.zshrc"
    fi
    
    if [ -n "$SHELL_RC" ]; then
        if ! grep -q "QDRANT_FILE_STORAGE" "$SHELL_RC"; then
            echo "" >> "$SHELL_RC"
            echo "# Qdrant file-based storage for Hivemind" >> "$SHELL_RC"
            echo "export QDRANT_FILE_STORAGE=1" >> "$SHELL_RC"
            echo "    Added QDRANT_FILE_STORAGE=1 to $SHELL_RC"
        fi
    fi
    
    echo "    File-based storage configured!"
    echo "    Note: Run 'export QDRANT_FILE_STORAGE=1' or restart shell"
fi

#===============================================================================
# Copy scripts to .claude directory
#===============================================================================
echo ""
echo "==> Installing Qdrant memory scripts..."

mkdir -p "$CLAUDE_DIR/scripts"

# Copy qdrant-memory.py if it exists in the same directory
if [ -f "$SCRIPT_DIR/qdrant-memory.py" ]; then
    cp "$SCRIPT_DIR/qdrant-memory.py" "$CLAUDE_DIR/scripts/"
    chmod +x "$CLAUDE_DIR/scripts/qdrant-memory.py"
    echo "    Installed qdrant-memory.py"
fi

#===============================================================================
# Initialize Qdrant collection
#===============================================================================
echo ""
echo "==> Initializing Qdrant collection..."

# Set file storage mode if applicable
if $USE_FILE; then
    export QDRANT_FILE_STORAGE=1
fi

# Initialize collection
python3 "$CLAUDE_DIR/scripts/qdrant-memory.py" init 2>/dev/null || {
    echo "WARNING: Could not initialize collection. This is normal if dependencies are still installing."
    echo "         Run manually later: python3 ~/.claude/scripts/qdrant-memory.py init"
}

#===============================================================================
# Create integration hook for SessionStart
#===============================================================================
echo ""
echo "==> Creating Qdrant integration hook..."

cat > "$CLAUDE_DIR/hooks/qdrant-context.sh" << 'QDRANT_HOOK'
#!/bin/bash
# Qdrant context injection hook for SessionStart
# Searches relevant memories based on recent conversation context

MEMORY_SCRIPT="$HOME/.claude/scripts/qdrant-memory.py"

# Read input JSON to get any context hints
INPUT=$(cat)
CWD=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('cwd',''))" 2>/dev/null || echo "")

# Extract project name as search context
PROJECT_NAME=$(basename "$CWD" 2>/dev/null || echo "general")

# Search for relevant memories
CONTEXT=$(python3 "$MEMORY_SCRIPT" context-inject "$PROJECT_NAME" 2>/dev/null || echo "")

if [ -n "$CONTEXT" ] && [ "$CONTEXT" != "" ]; then
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
QDRANT_HOOK

chmod +x "$CLAUDE_DIR/hooks/qdrant-context.sh"

#===============================================================================
# Create slash command for semantic search
#===============================================================================
echo "==> Creating slash commands..."

mkdir -p "$CLAUDE_DIR/commands"

cat > "$CLAUDE_DIR/commands/semantic-search.md" << 'EOF'
---
description: Semantic search through memory using Qdrant
argument-hint: <query> [limit]
---
Search memories semantically:
```bash
python3 ~/.claude/scripts/qdrant-memory.py search "$ARGUMENTS"
```
EOF

cat > "$CLAUDE_DIR/commands/remember.md" << 'EOF'
---
description: Store content in semantic memory (Qdrant)
argument-hint: <key> <content> [category]
---
Store in vector memory:
```bash
python3 ~/.claude/scripts/qdrant-memory.py store $ARGUMENTS
```
Categories: general, decision, pattern, architecture, bug, learning
EOF

cat > "$CLAUDE_DIR/commands/qdrant-status.md" << 'EOF'
---
description: Check Qdrant vector database status
argument-hint: 
---
Check Qdrant status:
```bash
python3 ~/.claude/scripts/qdrant-memory.py status
```
EOF

#===============================================================================
# Update global CLAUDE.md with Qdrant reference
#===============================================================================
echo ""
echo "==> Updating CLAUDE.md with Qdrant reference..."

if [ -f "$CLAUDE_DIR/CLAUDE.md" ]; then
    if ! grep -q "Qdrant" "$CLAUDE_DIR/CLAUDE.md"; then
        cat >> "$CLAUDE_DIR/CLAUDE.md" << 'EOF'

## Semantic Memory (Qdrant)

Store and search memories semantically:

```bash
# Store with embedding
python3 ~/.claude/scripts/qdrant-memory.py store "key" "content" "category"

# Semantic search
python3 ~/.claude/scripts/qdrant-memory.py search "query" [limit]

# Check status
python3 ~/.claude/scripts/qdrant-memory.py status

# Sync SQLite memories to Qdrant
python3 ~/.claude/scripts/qdrant-memory.py sync-from-sqlite
```

Slash commands: `/semantic-search`, `/remember`, `/qdrant-status`
EOF
    fi
fi

#===============================================================================
# Summary
#===============================================================================
echo ""
echo "=============================================="
echo "Qdrant Setup Complete!"
echo "=============================================="
echo ""
echo "Mode: $([ $USE_DOCKER = true ] && echo 'Docker' || ([ $USE_NATIVE = true ] && echo 'Native' || echo 'File-based'))"
echo "Data: $QDRANT_DATA_DIR"
echo ""
echo "Commands:"
echo "  python3 ~/.claude/scripts/qdrant-memory.py status    # Check status"
echo "  python3 ~/.claude/scripts/qdrant-memory.py store ... # Store memory"
echo "  python3 ~/.claude/scripts/qdrant-memory.py search .. # Semantic search"
echo ""
echo "Slash commands in Claude Code:"
echo "  /semantic-search <query>     # Search memories"
echo "  /remember <key> <content>    # Store memory"
echo "  /qdrant-status               # Check status"
echo ""

if $USE_DOCKER; then
    echo "Docker management:"
    echo "  docker logs hivemind-qdrant          # View logs"
    echo "  docker restart hivemind-qdrant       # Restart"
    echo "  systemctl --user enable hivemind-qdrant  # Auto-start"
fi

if $USE_NATIVE; then
    echo "Service management:"
    echo "  systemctl --user start hivemind-qdrant   # Start"
    echo "  systemctl --user enable hivemind-qdrant  # Auto-start"
    echo "  systemctl --user status hivemind-qdrant  # Status"
fi

if $USE_FILE; then
    echo "File-based storage notes:"
    echo "  - No server required"
    echo "  - Data stored in: $QDRANT_DATA_DIR"
    echo "  - Set QDRANT_FILE_STORAGE=1 in environment"
fi

echo ""
echo "Next steps:"
echo "  1. Restart Claude Code or run 'claude'"
echo "  2. Approve hooks with /hooks command"
echo "  3. Test: /semantic-search 'your query'"
echo ""
