#!/usr/bin/env python3
"""
Web Research MCP Server
Provides tools for deep web research, content extraction, and analysis.
Integrates with SQLite for persistent storage.
"""

import asyncio
import aiohttp
import json
import sqlite3
import hashlib
import re
from datetime import datetime
from pathlib import Path
from urllib.parse import urljoin, urlparse
from typing import List, Dict, Optional
import logging

try:
    from fastmcp import FastMCP
    from readability import Document
    import trafilatura
    from bs4 import BeautifulSoup
except ImportError as e:
    print(f"Missing dependencies: {e}")
    print("Install with: pip install fastmcp readability-lxml trafilatura beautifulsoup4 aiohttp")
    exit(1)

# Configuration
DB_PATH = Path("research-mcps/databases/web_research.db")
CACHE_PATH = Path("research-mcps/databases/content_cache")
USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Research Bot"

# Setup logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Initialize MCP
mcp = FastMCP("Web Research Server")

class WebResearchDB:
    def __init__(self, db_path: Path):
        self.db_path = db_path
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self.init_db()
    
    def init_db(self):
        """Initialize database schema"""
        conn = sqlite3.connect(self.db_path)
        conn.executescript('''
            CREATE TABLE IF NOT EXISTS pages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                url TEXT UNIQUE NOT NULL,
                title TEXT,
                content TEXT,
                summary TEXT,
                content_hash TEXT,
                domain TEXT,
                scraped_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                status TEXT DEFAULT 'active',
                metadata TEXT  -- JSON
            );
            
            CREATE TABLE IF NOT EXISTS research_sessions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_name TEXT UNIQUE NOT NULL,
                description TEXT,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                metadata TEXT  -- JSON
            );
            
            CREATE TABLE IF NOT EXISTS session_pages (
                session_id INTEGER,
                page_id INTEGER,
                relevance_score REAL DEFAULT 1.0,
                notes TEXT,
                added_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY (session_id) REFERENCES research_sessions(id),
                FOREIGN KEY (page_id) REFERENCES pages(id),
                PRIMARY KEY (session_id, page_id)
            );
            
            CREATE TABLE IF NOT EXISTS keywords (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                keyword TEXT UNIQUE NOT NULL,
                frequency INTEGER DEFAULT 1,
                context TEXT,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            );
            
            CREATE TABLE IF NOT EXISTS page_keywords (
                page_id INTEGER,
                keyword_id INTEGER,
                frequency INTEGER DEFAULT 1,
                context TEXT,
                FOREIGN KEY (page_id) REFERENCES pages(id),
                FOREIGN KEY (keyword_id) REFERENCES keywords(id),
                PRIMARY KEY (page_id, keyword_id)
            );
            
            CREATE TABLE IF NOT EXISTS research_queries (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                query TEXT NOT NULL,
                session_id INTEGER,
                results_count INTEGER DEFAULT 0,
                executed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                metadata TEXT,  -- JSON
                FOREIGN KEY (session_id) REFERENCES research_sessions(id)
            );
            
            CREATE INDEX IF NOT EXISTS idx_pages_domain ON pages(domain);
            CREATE INDEX IF NOT EXISTS idx_pages_scraped ON pages(scraped_at);
            CREATE INDEX IF NOT EXISTS idx_keywords_freq ON keywords(frequency DESC);
            CREATE INDEX IF NOT EXISTS idx_session_pages_relevance ON session_pages(relevance_score DESC);
        ''')
        conn.commit()
        conn.close()

    def save_page(self, url: str, title: str, content: str, summary: str, metadata: dict = None) -> int:
        """Save scraped page to database"""
        conn = sqlite3.connect(self.db_path)
        content_hash = hashlib.md5(content.encode()).hexdigest()
        domain = urlparse(url).netloc
        
        try:
            cursor = conn.execute('''
                INSERT OR REPLACE INTO pages 
                (url, title, content, summary, content_hash, domain, updated_at, metadata)
                VALUES (?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP, ?)
            ''', (url, title, content, summary, content_hash, domain, json.dumps(metadata or {})))
            conn.commit()
            return cursor.lastrowid
        finally:
            conn.close()

    def get_session_id(self, session_name: str) -> int:
        """Get or create research session"""
        conn = sqlite3.connect(self.db_path)
        try:
            cursor = conn.execute('SELECT id FROM research_sessions WHERE session_name = ?', (session_name,))
            row = cursor.fetchone()
            if row:
                return row[0]
            
            cursor = conn.execute('''
                INSERT INTO research_sessions (session_name, description)
                VALUES (?, ?)
            ''', (session_name, f"Research session: {session_name}"))
            conn.commit()
            return cursor.lastrowid
        finally:
            conn.close()

    def add_page_to_session(self, session_name: str, page_id: int, relevance_score: float = 1.0, notes: str = ""):
        """Add page to research session"""
        session_id = self.get_session_id(session_name)
        conn = sqlite3.connect(self.db_path)
        try:
            conn.execute('''
                INSERT OR REPLACE INTO session_pages 
                (session_id, page_id, relevance_score, notes)
                VALUES (?, ?, ?, ?)
            ''', (session_id, page_id, relevance_score, notes))
            conn.commit()
        finally:
            conn.close()

    def search_content(self, query: str, limit: int = 10) -> List[dict]:
        """Search stored content"""
        conn = sqlite3.connect(self.db_path)
        try:
            cursor = conn.execute('''
                SELECT url, title, summary, scraped_at, domain
                FROM pages 
                WHERE content LIKE ? OR title LIKE ? OR summary LIKE ?
                ORDER BY scraped_at DESC
                LIMIT ?
            ''', (f'%{query}%', f'%{query}%', f'%{query}%', limit))
            
            results = []
            for row in cursor.fetchall():
                results.append({
                    'url': row[0],
                    'title': row[1],
                    'summary': row[2],
                    'scraped_at': row[3],
                    'domain': row[4]
                })
            return results
        finally:
            conn.close()

# Initialize database
db = WebResearchDB(DB_PATH)

class ContentExtractor:
    """Extract and clean content from web pages"""
    
    @staticmethod
    async def extract_content(html: str, url: str) -> Dict[str, str]:
        """Extract clean content from HTML"""
        try:
            # Method 1: Trafilatura (best for articles)
            content = trafilatura.extract(html, include_comments=False, include_tables=True)
            
            # Method 2: Readability as fallback
            if not content or len(content) < 100:
                doc = Document(html)
                content = doc.summary()
                soup = BeautifulSoup(content, 'html.parser')
                content = soup.get_text(separator=' ', strip=True)
            
            # Extract title
            soup = BeautifulSoup(html, 'html.parser')
            title = soup.find('title')
            title = title.get_text().strip() if title else urlparse(url).path
            
            # Generate summary (first 500 chars of clean content)
            summary = content[:500] + "..." if len(content) > 500 else content
            
            return {
                'title': title,
                'content': content or "",
                'summary': summary,
                'extracted_successfully': bool(content)
            }
        except Exception as e:
            logger.error(f"Content extraction failed for {url}: {e}")
            return {
                'title': url,
                'content': "",
                'summary': "",
                'extracted_successfully': False
            }

@mcp.tool()
async def scrape_url(url: str, session_name: str = "default", max_retries: int = 3) -> str:
    """
    Scrape content from a URL and store in research database.
    
    Args:
        url: The URL to scrape
        session_name: Research session to associate with
        max_retries: Number of retry attempts for failed requests
    
    Returns:
        JSON string with scraping results and stored content summary
    """
    headers = {'User-Agent': USER_AGENT}
    
    for attempt in range(max_retries):
        try:
            timeout = aiohttp.ClientTimeout(total=30)
            async with aiohttp.ClientSession(timeout=timeout, headers=headers) as session:
                async with session.get(url) as response:
                    if response.status == 200:
                        html = await response.text()
                        
                        # Extract content
                        extracted = await ContentExtractor.extract_content(html, url)
                        
                        # Save to database
                        metadata = {
                            'status_code': response.status,
                            'content_type': response.headers.get('content-type', ''),
                            'scraped_with': 'web_research_mcp'
                        }
                        
                        page_id = db.save_page(
                            url=url,
                            title=extracted['title'],
                            content=extracted['content'],
                            summary=extracted['summary'],
                            metadata=metadata
                        )
                        
                        # Add to session
                        db.add_page_to_session(session_name, page_id)
                        
                        return json.dumps({
                            'success': True,
                            'url': url,
                            'title': extracted['title'],
                            'content_length': len(extracted['content']),
                            'summary': extracted['summary'],
                            'page_id': page_id,
                            'session': session_name
                        })
                    else:
                        logger.warning(f"HTTP {response.status} for {url}")
                        if attempt == max_retries - 1:
                            return json.dumps({
                                'success': False,
                                'error': f"HTTP {response.status}",
                                'url': url
                            })
        except Exception as e:
            logger.error(f"Attempt {attempt + 1} failed for {url}: {e}")
            if attempt == max_retries - 1:
                return json.dumps({
                    'success': False,
                    'error': str(e),
                    'url': url
                })
            await asyncio.sleep(2 ** attempt)  # Exponential backoff

@mcp.tool()
async def bulk_scrape(urls: List[str], session_name: str = "bulk_research", delay: float = 1.0) -> str:
    """
    Scrape multiple URLs with rate limiting.
    
    Args:
        urls: List of URLs to scrape
        session_name: Research session name
        delay: Delay between requests in seconds
    
    Returns:
        JSON summary of scraping results
    """
    results = {'successful': 0, 'failed': 0, 'pages': []}
    
    for i, url in enumerate(urls):
        result = await scrape_url(url, session_name)
        result_data = json.loads(result)
        
        if result_data['success']:
            results['successful'] += 1
        else:
            results['failed'] += 1
        
        results['pages'].append(result_data)
        
        # Rate limiting
        if i < len(urls) - 1:
            await asyncio.sleep(delay)
    
    return json.dumps(results)

@mcp.tool()
def search_research(query: str, session_name: str = None, limit: int = 10) -> str:
    """
    Search stored research content.
    
    Args:
        query: Search query
        session_name: Limit search to specific session (optional)
        limit: Maximum number of results
    
    Returns:
        JSON array of matching pages
    """
    if session_name:
        # Search within specific session
        conn = sqlite3.connect(db.db_path)
        try:
            cursor = conn.execute('''
                SELECT p.url, p.title, p.summary, p.scraped_at, p.domain, sp.relevance_score
                FROM pages p
                JOIN session_pages sp ON p.id = sp.page_id
                JOIN research_sessions rs ON sp.session_id = rs.id
                WHERE rs.session_name = ? 
                AND (p.content LIKE ? OR p.title LIKE ? OR p.summary LIKE ?)
                ORDER BY sp.relevance_score DESC, p.scraped_at DESC
                LIMIT ?
            ''', (session_name, f'%{query}%', f'%{query}%', f'%{query}%', limit))
            
            results = []
            for row in cursor.fetchall():
                results.append({
                    'url': row[0],
                    'title': row[1],
                    'summary': row[2],
                    'scraped_at': row[3],
                    'domain': row[4],
                    'relevance_score': row[5],
                    'session': session_name
                })
        finally:
            conn.close()
    else:
        # Search all content
        results = db.search_content(query, limit)
    
    return json.dumps(results, indent=2)

@mcp.tool()
def list_sessions() -> str:
    """
    List all research sessions with page counts.
    
    Returns:
        JSON array of sessions with metadata
    """
    conn = sqlite3.connect(db.db_path)
    try:
        cursor = conn.execute('''
            SELECT rs.session_name, rs.description, rs.created_at, rs.updated_at,
                   COUNT(sp.page_id) as page_count
            FROM research_sessions rs
            LEFT JOIN session_pages sp ON rs.id = sp.session_id
            GROUP BY rs.id
            ORDER BY rs.updated_at DESC
        ''')
        
        sessions = []
        for row in cursor.fetchall():
            sessions.append({
                'session_name': row[0],
                'description': row[1],
                'created_at': row[2],
                'updated_at': row[3],
                'page_count': row[4]
            })
        
        return json.dumps(sessions, indent=2)
    finally:
        conn.close()

@mcp.tool()
def get_session_summary(session_name: str) -> str:
    """
    Get detailed summary of a research session.
    
    Args:
        session_name: Name of the research session
    
    Returns:
        JSON summary with pages, domains, and statistics
    """
    conn = sqlite3.connect(db.db_path)
    try:
        # Get session info
        cursor = conn.execute('''
            SELECT description, created_at, updated_at
            FROM research_sessions 
            WHERE session_name = ?
        ''', (session_name,))
        session_info = cursor.fetchone()
        
        if not session_info:
            return json.dumps({'error': f'Session "{session_name}" not found'})
        
        # Get pages in session
        cursor = conn.execute('''
            SELECT p.url, p.title, p.domain, p.scraped_at, sp.relevance_score, sp.notes
            FROM pages p
            JOIN session_pages sp ON p.id = sp.page_id
            JOIN research_sessions rs ON sp.session_id = rs.id
            WHERE rs.session_name = ?
            ORDER BY sp.relevance_score DESC, p.scraped_at DESC
        ''', (session_name,))
        
        pages = []
        domains = {}
        for row in cursor.fetchall():
            page_data = {
                'url': row[0],
                'title': row[1],
                'domain': row[2],
                'scraped_at': row[3],
                'relevance_score': row[4],
                'notes': row[5]
            }
            pages.append(page_data)
            domains[row[2]] = domains.get(row[2], 0) + 1
        
        summary = {
            'session_name': session_name,
            'description': session_info[0],
            'created_at': session_info[1],
            'updated_at': session_info[2],
            'total_pages': len(pages),
            'domains': domains,
            'pages': pages
        }
        
        return json.dumps(summary, indent=2)
    finally:
        conn.close()

@mcp.tool()
def export_session(session_name: str, format_type: str = "json") -> str:
    """
    Export research session data.
    
    Args:
        session_name: Name of session to export
        format_type: Export format ('json', 'markdown', 'csv')
    
    Returns:
        Exported data in requested format
    """
    session_data = json.loads(get_session_summary(session_name))
    
    if 'error' in session_data:
        return json.dumps(session_data)
    
    if format_type == "json":
        return json.dumps(session_data, indent=2)
    
    elif format_type == "markdown":
        md = [f"# Research Session: {session_name}\n"]
        md.append(f"**Description:** {session_data['description']}")
        md.append(f"**Created:** {session_data['created_at']}")
        md.append(f"**Total Pages:** {session_data['total_pages']}\n")
        
        md.append("## Domain Distribution")
        for domain, count in session_data['domains'].items():
            md.append(f"- {domain}: {count} pages")
        
        md.append("\n## Pages\n")
        for page in session_data['pages']:
            md.append(f"### {page['title']}")
            md.append(f"- **URL:** {page['url']}")
            md.append(f"- **Domain:** {page['domain']}")
            md.append(f"- **Scraped:** {page['scraped_at']}")
            md.append(f"- **Relevance:** {page['relevance_score']}")
            if page['notes']:
                md.append(f"- **Notes:** {page['notes']}")
            md.append("")
        
        return "\n".join(md)
    
    elif format_type == "csv":
        import csv
        from io import StringIO
        
        output = StringIO()
        writer = csv.writer(output)
        writer.writerow(['URL', 'Title', 'Domain', 'Scraped At', 'Relevance Score', 'Notes'])
        
        for page in session_data['pages']:
            writer.writerow([
                page['url'], page['title'], page['domain'],
                page['scraped_at'], page['relevance_score'], page['notes']
            ])
        
        return output.getvalue()
    
    else:
        return json.dumps({'error': f'Unsupported format: {format_type}'})

if __name__ == "__main__":
    mcp.run()