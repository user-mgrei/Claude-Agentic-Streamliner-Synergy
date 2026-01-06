#!/usr/bin/env python3
"""
Auto Knowledge Extraction Tool
Hook script that automatically extracts knowledge from scraped content
and adds it to the knowledge graph.
"""

import json
import sys
import subprocess
import logging
from pathlib import Path

# Setup logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

def extract_content_from_hook_input(hook_input: dict) -> dict:
    """Extract content from web scraping hook input"""
    try:
        # Get the tool output from web research MCP
        if 'tool_output' in hook_input:
            output = json.loads(hook_input['tool_output'])
            
            if output.get('success'):
                return {
                    'title': output.get('title', ''),
                    'content': output.get('summary', ''), # Use summary for now
                    'url': output.get('url', ''),
                    'session': output.get('session', 'default'),
                    'page_id': output.get('page_id', 0)
                }
    except Exception as e:
        logger.error(f"Failed to extract content from hook input: {e}")
    
    return None

def call_knowledge_graph_mcp(content_data: dict) -> bool:
    """Call knowledge graph MCP to extract entities and relationships"""
    try:
        # Prepare text for extraction
        text_content = f"{content_data['title']}. {content_data['content']}"
        
        # Call the knowledge graph MCP server
        # This is a simplified approach - in practice you'd use the MCP protocol
        import sys
        sys.path.append('research-mcps/servers')
        
        from knowledge_graph_mcp import extract_knowledge_from_text
        import asyncio
        
        # Run the extraction
        result = asyncio.run(extract_knowledge_from_text(
            text=text_content,
            source_document=content_data['url'],
            document_id=str(content_data['page_id'])
        ))
        
        result_data = json.loads(result)
        
        if result_data.get('success'):
            logger.info(f"Extracted {result_data.get('entities_count', 0)} entities and "
                       f"{result_data.get('relationships_count', 0)} relationships")
            return True
        else:
            logger.warning(f"Knowledge extraction failed: {result_data.get('error', 'Unknown error')}")
            return False
            
    except Exception as e:
        logger.error(f"Failed to call knowledge graph MCP: {e}")
        return False

def main():
    """Main hook execution"""
    try:
        # Read hook input from stdin
        hook_input = json.load(sys.stdin)
        
        # Extract content data
        content_data = extract_content_from_hook_input(hook_input)
        
        if not content_data:
            logger.warning("No content data found in hook input")
            sys.exit(0)
        
        # Skip if content is too short
        if len(content_data['content']) < 100:
            logger.info("Content too short for knowledge extraction")
            sys.exit(0)
        
        # Extract knowledge
        success = call_knowledge_graph_mcp(content_data)
        
        # Output hook result
        if success:
            result = {
                "systemMessage": f"Auto-extracted knowledge from {content_data['url']}"
            }
        else:
            result = {
                "systemMessage": f"Failed to extract knowledge from {content_data['url']}"
            }
        
        print(json.dumps(result))
        sys.exit(0)
        
    except Exception as e:
        logger.error(f"Hook execution failed: {e}")
        error_result = {
            "systemMessage": f"Auto-knowledge extraction failed: {str(e)}"
        }
        print(json.dumps(error_result))
        sys.exit(0)

if __name__ == "__main__":
    main()