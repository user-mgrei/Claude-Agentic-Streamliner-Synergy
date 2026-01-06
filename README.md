# Claude Agentic Streamliner Synergy

A comprehensive Claude Code enhancement suite providing persistent memory, multi-agent coordination, and advanced research capabilities.

## 📊 Project Analysis

**Complete project analysis available in:** [`PROJECT_ANALYSIS.json`](PROJECT_ANALYSIS.json) - Machine-readable comprehensive analysis of all components, implementations, and capabilities.

## 🚨 IMPORTANT: Production Recommendations

**Stable Implementation:** `important-legacy/` - **V2 Hivemind** (85% verified, production-ready)
**Advanced Research:** `research-mcps/` - **Research MCP System** (95% complete, production-ready) 
**Experimental Reference:** `v3-current/` - V3 implementations (known issues, reference only)

## Repository Organization

This repository has been reorganized to separate working implementations from experimental branches:

```
├── README.md                          # This file
├── important-legacy/                  # ✅ V2 - STABLE & WORKING
│   ├── setup-claude-hivemind-v2.sh   # Working installation script
│   ├── Setup v2 fact check.md        # V2 verification against docs
│   └── Setup v2 full analysis.md     # V2 technical reference
├── v3-current/                       # ⚠️ V3 - EXPERIMENTAL (has errors)
│   ├── setup-claude-hivemind-v3.sh   # V3 installation script
│   ├── Proposed v3 implementation.md # V3 specification
│   └── V3 Fact Check and Implementation Report.md
├── archive/                          # 📚 Research materials
│   └── research/
│       ├── legacy chat.md            # Context transfer document
│       └── fact check 1.md           # Initial verification work
├── branches/                         # 🔍 All remote branch contents
│   ├── claud-hivemind-v3-research-*/
│   └── memory-database-qdrant-integration-*/
└── docs/                            # 📖 Documentation
    └── branch-analysis.md
```

## Quick Start (Recommended)

**Use the stable V2 implementation:**

```bash
cd important-legacy/
chmod +x setup-claude-hivemind-v2.sh
./setup-claude-hivemind-v2.sh
```

## What This System Provides

### Core Features
- **Persistent Memory**: SQLite database maintains state across Claude sessions
- **Context Preservation**: Automatic backup before context window compaction
- **Multi-Agent Orchestration**: Spawn and coordinate multiple Claude instances
- **Learning Export**: Discoveries automatically saved to project documentation

### Architecture
- **SessionStart Hook**: Loads memory into conversation context
- **PreCompact Hook**: Saves state before auto-compaction (V2 only)
- **Stop Hook**: Exports learnings to project CLAUDE.md files
- **SubagentStop Hook**: Tracks completion of Task tool invocations

## Branch Analysis

Multiple development branches explored different approaches:

### Research Branches (`claud-hivemind-v3-research-*`)
- **11e6**: Research-focused verification branch
- **717e**: Alternative implementation approach  
- **c216**: Experimental hook configurations
- **ce52**: Final research iteration

### Integration Branches (`memory-database-qdrant-integration-*`)
- **5222**: Initial Qdrant vector database integration
- **8811**: Enhanced MCP server implementation
- **9fcb**: TUI-based setup system
- **aee7**: Arch Linux optimization

## Known Issues

### V3 Limitations (Why V2 is Recommended)
- Contains unverified claims about Claude Code APIs
- Complex setup process with potential failure points
- Qdrant integration adds unnecessary complexity for basic use

### V2 Verified Working Features
- ✅ Hook system matches official plugin patterns
- ✅ SQLite persistence with WAL mode for concurrency
- ✅ CRLF fix for Linux line ending issues
- ✅ Subagent tracking via PreToolUse/SubagentStop hooks

## Contributing

When working on this project:

1. **Test changes against V2 baseline** - ensure new features don't break working functionality
2. **Verify against official docs** - check claims against `anthropics/claude-code` repository
3. **Document known issues** - track GitHub issues that affect functionality
4. **Preserve working versions** - maintain `important-legacy/` for stable implementations

## Documentation

- [Branch Analysis](docs/branch-analysis.md) - Detailed comparison of all development branches
- [V2 Technical Reference](important-legacy/Setup%20v2%20full%20analysis.md) - Complete V2 implementation details
- [V3 Fact Check Report](v3-current/V3%20Fact%20Check%20and%20Implementation%20Report.md) - V3 verification results

## License

This project is experimental software for Claude Code enhancement. Use at your own risk and ensure compliance with Anthropic's terms of service.