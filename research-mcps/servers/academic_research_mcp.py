#!/usr/bin/env python3
"""
Academic Research MCP Server
Specializes in scholarly sources, citations, and academic paper analysis.
Integrates with arXiv, PubMed, Semantic Scholar, and other academic databases.
"""

import json
import sqlite3
import hashlib
import asyncio
import aiohttp
import re
from datetime import datetime
from pathlib import Path
from typing import List, Dict, Optional, Union
import logging
from urllib.parse import quote, urljoin
import xml.etree.ElementTree as ET

try:
    from fastmcp import FastMCP
    import requests
    from bs4 import BeautifulSoup
    import feedparser
    from sentence_transformers import SentenceTransformer
    import numpy as np
except ImportError as e:
    print(f"Missing dependencies: {e}")
    print("Install with: pip install fastmcp requests beautifulsoup4 feedparser sentence-transformers numpy")
    exit(1)

# Configuration
DB_PATH = Path("research-mcps/databases/academic_research.db")
EMBEDDINGS_MODEL = "all-MiniLM-L6-v2"
USER_AGENT = "Academic Research Bot/1.0"

# API Endpoints
ARXIV_API = "http://export.arxiv.org/api/query"
PUBMED_API = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/"
SEMANTIC_SCHOLAR_API = "https://api.semanticscholar.org/graph/v1/"
CROSSREF_API = "https://api.crossref.org/works/"

# Setup logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Initialize MCP
mcp = FastMCP("Academic Research Server")

# Load embeddings model (lazy loading)
_embedding_model = None

def get_embedding_model():
    global _embedding_model
    if _embedding_model is None:
        logger.info(f"Loading embedding model: {EMBEDDINGS_MODEL}")
        _embedding_model = SentenceTransformer(EMBEDDINGS_MODEL)
    return _embedding_model

class AcademicResearchDB:
    def __init__(self, db_path: Path):
        self.db_path = db_path
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self.init_db()
    
    def init_db(self):
        """Initialize academic research database schema"""
        conn = sqlite3.connect(self.db_path)
        conn.executescript('''
            CREATE TABLE IF NOT EXISTS papers (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                title TEXT NOT NULL,
                authors TEXT, -- JSON array
                abstract TEXT,
                publication_date TEXT,
                arxiv_id TEXT UNIQUE,
                doi TEXT,
                pubmed_id TEXT,
                semantic_scholar_id TEXT,
                journal TEXT,
                venue TEXT,
                pdf_url TEXT,
                citation_count INTEGER DEFAULT 0,
                reference_count INTEGER DEFAULT 0,
                influence_score REAL DEFAULT 0.0,
                h_index REAL DEFAULT 0.0,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                metadata TEXT, -- JSON
                embedding BLOB -- Abstract embedding
            );
            
            CREATE TABLE IF NOT EXISTS authors (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                normalized_name TEXT,
                affiliation TEXT,
                h_index REAL DEFAULT 0.0,
                citation_count INTEGER DEFAULT 0,
                paper_count INTEGER DEFAULT 0,
                semantic_scholar_id TEXT,
                orcid TEXT,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                metadata TEXT -- JSON
            );
            
            CREATE TABLE IF NOT EXISTS paper_authors (
                paper_id INTEGER,
                author_id INTEGER,
                author_order INTEGER DEFAULT 0,
                is_corresponding BOOLEAN DEFAULT FALSE,
                FOREIGN KEY (paper_id) REFERENCES papers(id),
                FOREIGN KEY (author_id) REFERENCES authors(id),
                PRIMARY KEY (paper_id, author_id)
            );
            
            CREATE TABLE IF NOT EXISTS citations (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                citing_paper_id INTEGER,
                cited_paper_id INTEGER,
                context TEXT, -- Citation context from paper
                citation_intent TEXT, -- background, method, result, etc.
                is_influential BOOLEAN DEFAULT FALSE,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY (citing_paper_id) REFERENCES papers(id),
                FOREIGN KEY (cited_paper_id) REFERENCES papers(id)
            );
            
            CREATE TABLE IF NOT EXISTS research_topics (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                topic_name TEXT UNIQUE NOT NULL,
                description TEXT,
                keywords TEXT, -- JSON array
                field_of_study TEXT,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            );
            
            CREATE TABLE IF NOT EXISTS paper_topics (
                paper_id INTEGER,
                topic_id INTEGER,
                relevance_score REAL DEFAULT 1.0,
                FOREIGN KEY (paper_id) REFERENCES papers(id),
                FOREIGN KEY (topic_id) REFERENCES research_topics(id),
                PRIMARY KEY (paper_id, topic_id)
            );
            
            CREATE TABLE IF NOT EXISTS search_queries (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                query_text TEXT NOT NULL,
                source TEXT, -- arxiv, pubmed, semantic_scholar
                results_count INTEGER DEFAULT 0,
                executed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                parameters TEXT -- JSON
            );
            
            CREATE TABLE IF NOT EXISTS research_collections (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                collection_name TEXT UNIQUE NOT NULL,
                description TEXT,
                topic_focus TEXT,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                paper_count INTEGER DEFAULT 0
            );
            
            CREATE TABLE IF NOT EXISTS collection_papers (
                collection_id INTEGER,
                paper_id INTEGER,
                relevance_score REAL DEFAULT 1.0,
                notes TEXT,
                added_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY (collection_id) REFERENCES research_collections(id),
                FOREIGN KEY (paper_id) REFERENCES papers(id),
                PRIMARY KEY (collection_id, paper_id)
            );
            
            CREATE INDEX IF NOT EXISTS idx_papers_arxiv ON papers(arxiv_id);
            CREATE INDEX IF NOT EXISTS idx_papers_doi ON papers(doi);
            CREATE INDEX IF NOT EXISTS idx_papers_pubmed ON papers(pubmed_id);
            CREATE INDEX IF NOT EXISTS idx_papers_date ON papers(publication_date);
            CREATE INDEX IF NOT EXISTS idx_papers_citations ON papers(citation_count DESC);
            CREATE INDEX IF NOT EXISTS idx_authors_name ON authors(normalized_name);
            CREATE INDEX IF NOT EXISTS idx_citations_citing ON citations(citing_paper_id);
            CREATE INDEX IF NOT EXISTS idx_citations_cited ON citations(cited_paper_id);
            CREATE INDEX IF NOT EXISTS idx_topics_name ON research_topics(topic_name);
        ''')
        conn.commit()
        conn.close()

    def save_paper(self, title: str, authors: List[str], abstract: str = "",
                  publication_date: str = "", arxiv_id: str = "", doi: str = "",
                  pubmed_id: str = "", journal: str = "", metadata: dict = None) -> int:
        """Save paper to database"""
        model = get_embedding_model()
        
        # Generate embedding for abstract
        embedding_text = f"{title}. {abstract}".strip()
        embedding = model.encode([embedding_text])[0].astype(np.float32).tobytes()
        
        conn = sqlite3.connect(self.db_path)
        try:
            cursor = conn.execute('''
                INSERT OR REPLACE INTO papers 
                (title, authors, abstract, publication_date, arxiv_id, doi, pubmed_id,
                 journal, metadata, embedding, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
            ''', (title, json.dumps(authors), abstract, publication_date, arxiv_id,
                  doi, pubmed_id, journal, json.dumps(metadata or {}), embedding))
            
            conn.commit()
            return cursor.lastrowid
        finally:
            conn.close()

    def save_author(self, name: str, affiliation: str = "", metadata: dict = None) -> int:
        """Save author to database"""
        normalized_name = self.normalize_author_name(name)
        
        conn = sqlite3.connect(self.db_path)
        try:
            # Check if author exists
            cursor = conn.execute('SELECT id FROM authors WHERE normalized_name = ?', 
                                (normalized_name,))
            row = cursor.fetchone()
            
            if row:
                return row[0]
            
            cursor = conn.execute('''
                INSERT INTO authors (name, normalized_name, affiliation, metadata)
                VALUES (?, ?, ?, ?)
            ''', (name, normalized_name, affiliation, json.dumps(metadata or {})))
            
            conn.commit()
            return cursor.lastrowid
        finally:
            conn.close()

    def search_similar_papers(self, query_text: str, limit: int = 10) -> List[Dict]:
        """Search for similar papers using embeddings"""
        model = get_embedding_model()
        query_embedding = model.encode([query_text])[0].astype(np.float32)
        
        conn = sqlite3.connect(self.db_path)
        try:
            cursor = conn.execute('''
                SELECT id, title, authors, abstract, publication_date, citation_count, embedding
                FROM papers WHERE embedding IS NOT NULL
            ''')
            
            results = []
            for row in cursor.fetchall():
                paper_id, title, authors_json, abstract, pub_date, citations, embedding_blob = row
                
                # Calculate similarity
                embedding = np.frombuffer(embedding_blob, dtype=np.float32)
                similarity = np.dot(query_embedding, embedding) / (
                    np.linalg.norm(query_embedding) * np.linalg.norm(embedding)
                )
                
                results.append({
                    'paper_id': paper_id,
                    'title': title,
                    'authors': json.loads(authors_json),
                    'abstract': abstract[:300] + "..." if len(abstract) > 300 else abstract,
                    'publication_date': pub_date,
                    'citation_count': citations,
                    'similarity': float(similarity)
                })
            
            # Sort by similarity and return top results
            results.sort(key=lambda x: x['similarity'], reverse=True)
            return results[:limit]
            
        finally:
            conn.close()

    @staticmethod
    def normalize_author_name(name: str) -> str:
        """Normalize author name for consistent storage"""
        # Convert to lowercase, remove extra spaces
        normalized = re.sub(r'\s+', ' ', name.strip().lower())
        # Handle common name variations
        normalized = re.sub(r'\b([a-z])\.\s*', r'\1 ', normalized)  # J. Smith -> j smith
        return normalized

# Initialize database
db = AcademicResearchDB(DB_PATH)

class ArxivSearcher:
    """Search arXiv for academic papers"""
    
    @staticmethod
    async def search_papers(query: str, max_results: int = 20, 
                           category: str = None, author: str = None) -> List[Dict]:
        """Search arXiv papers"""
        # Build search query
        search_terms = []
        if query:
            search_terms.append(f"all:{query}")
        if author:
            search_terms.append(f"au:{author}")
        if category:
            search_terms.append(f"cat:{category}")
        
        search_query = " AND ".join(search_terms) if search_terms else query
        
        params = {
            'search_query': search_query,
            'start': 0,
            'max_results': max_results,
            'sortBy': 'relevance',
            'sortOrder': 'descending'
        }
        
        try:
            async with aiohttp.ClientSession() as session:
                async with session.get(ARXIV_API, params=params) as response:
                    content = await response.text()
                    
            # Parse Atom feed
            feed = feedparser.parse(content)
            papers = []
            
            for entry in feed.entries:
                # Extract arXiv ID
                arxiv_id = entry.id.split('/')[-1]
                
                # Extract authors
                authors = []
                if hasattr(entry, 'authors'):
                    authors = [author.name for author in entry.authors]
                
                # Extract categories
                categories = []
                if hasattr(entry, 'tags'):
                    categories = [tag.term for tag in entry.tags]
                
                # Extract publication date
                pub_date = entry.published if hasattr(entry, 'published') else ""
                
                # Extract PDF URL
                pdf_url = ""
                if hasattr(entry, 'links'):
                    for link in entry.links:
                        if link.type == 'application/pdf':
                            pdf_url = link.href
                            break
                
                papers.append({
                    'title': entry.title,
                    'authors': authors,
                    'abstract': entry.summary if hasattr(entry, 'summary') else "",
                    'arxiv_id': arxiv_id,
                    'publication_date': pub_date,
                    'categories': categories,
                    'pdf_url': pdf_url,
                    'arxiv_url': entry.link
                })
            
            return papers
            
        except Exception as e:
            logger.error(f"arXiv search failed: {e}")
            return []

class SemanticScholarSearcher:
    """Search Semantic Scholar for academic papers"""
    
    @staticmethod
    async def search_papers(query: str, limit: int = 20, 
                           fields: List[str] = None) -> List[Dict]:
        """Search Semantic Scholar papers"""
        if not fields:
            fields = ['title', 'authors', 'abstract', 'year', 'citationCount', 
                     'referenceCount', 'influentialCitationCount', 'venue', 'externalIds']
        
        params = {
            'query': query,
            'limit': limit,
            'fields': ','.join(fields)
        }
        
        try:
            async with aiohttp.ClientSession() as session:
                url = f"{SEMANTIC_SCHOLAR_API}paper/search"
                async with session.get(url, params=params) as response:
                    data = await response.json()
            
            papers = []
            if 'data' in data:
                for paper in data['data']:
                    # Extract author names
                    authors = []
                    if 'authors' in paper and paper['authors']:
                        authors = [author['name'] for author in paper['authors']]
                    
                    # Extract external IDs
                    arxiv_id = ""
                    doi = ""
                    pubmed_id = ""
                    if 'externalIds' in paper and paper['externalIds']:
                        ext_ids = paper['externalIds']
                        arxiv_id = ext_ids.get('ArXiv', '')
                        doi = ext_ids.get('DOI', '')
                        pubmed_id = ext_ids.get('PubMed', '')
                    
                    papers.append({
                        'title': paper.get('title', ''),
                        'authors': authors,
                        'abstract': paper.get('abstract', ''),
                        'publication_date': str(paper.get('year', '')),
                        'citation_count': paper.get('citationCount', 0),
                        'reference_count': paper.get('referenceCount', 0),
                        'influential_citations': paper.get('influentialCitationCount', 0),
                        'venue': paper.get('venue', ''),
                        'arxiv_id': arxiv_id,
                        'doi': doi,
                        'pubmed_id': pubmed_id,
                        'semantic_scholar_id': paper.get('paperId', ''),
                        'semantic_scholar_url': f"https://www.semanticscholar.org/paper/{paper.get('paperId', '')}"
                    })
            
            return papers
            
        except Exception as e:
            logger.error(f"Semantic Scholar search failed: {e}")
            return []

    @staticmethod
    async def get_paper_details(paper_id: str, fields: List[str] = None) -> Optional[Dict]:
        """Get detailed information about a specific paper"""
        if not fields:
            fields = ['title', 'authors', 'abstract', 'year', 'citationCount',
                     'referenceCount', 'citations', 'references', 'venue', 'externalIds']
        
        try:
            async with aiohttp.ClientSession() as session:
                url = f"{SEMANTIC_SCHOLAR_API}paper/{paper_id}"
                params = {'fields': ','.join(fields)}
                async with session.get(url, params=params) as response:
                    return await response.json()
        except Exception as e:
            logger.error(f"Failed to get paper details for {paper_id}: {e}")
            return None

@mcp.tool()
async def search_arxiv(query: str, max_results: int = 20, category: str = None, 
                      author: str = None, save_to_collection: str = None) -> str:
    """
    Search arXiv for academic papers.
    
    Args:
        query: Search query terms
        max_results: Maximum number of results to return
        category: arXiv category filter (e.g., 'cs.AI', 'physics.gen-ph')
        author: Author name filter
        save_to_collection: Collection name to save results to
    
    Returns:
        JSON array of paper results
    """
    try:
        papers = await ArxivSearcher.search_papers(query, max_results, category, author)
        
        saved_papers = []
        if save_to_collection:
            for paper in papers:
                # Save paper to database
                paper_id = db.save_paper(
                    title=paper['title'],
                    authors=paper['authors'],
                    abstract=paper['abstract'],
                    publication_date=paper['publication_date'],
                    arxiv_id=paper['arxiv_id'],
                    metadata={'source': 'arxiv', 'categories': paper['categories']}
                )
                
                # Add to collection
                await add_to_collection(save_to_collection, paper_id, 1.0)
                paper['paper_id'] = paper_id
                saved_papers.append(paper)
        
        # Log search query
        conn = sqlite3.connect(db.db_path)
        conn.execute('''
            INSERT INTO search_queries (query_text, source, results_count, parameters)
            VALUES (?, ?, ?, ?)
        ''', (query, 'arxiv', len(papers), json.dumps({
            'max_results': max_results, 'category': category, 'author': author
        })))
        conn.commit()
        conn.close()
        
        return json.dumps({
            'source': 'arxiv',
            'query': query,
            'results_count': len(papers),
            'papers': saved_papers if save_to_collection else papers,
            'collection': save_to_collection
        }, indent=2)
        
    except Exception as e:
        logger.error(f"arXiv search failed: {e}")
        return json.dumps({'error': f'arXiv search failed: {str(e)}'})

@mcp.tool()
async def search_semantic_scholar(query: str, limit: int = 20, 
                                 save_to_collection: str = None) -> str:
    """
    Search Semantic Scholar for academic papers.
    
    Args:
        query: Search query terms
        limit: Maximum number of results to return
        save_to_collection: Collection name to save results to
    
    Returns:
        JSON array of paper results with citation metrics
    """
    try:
        papers = await SemanticScholarSearcher.search_papers(query, limit)
        
        saved_papers = []
        if save_to_collection:
            for paper in papers:
                # Save paper to database
                paper_id = db.save_paper(
                    title=paper['title'],
                    authors=paper['authors'],
                    abstract=paper['abstract'],
                    publication_date=paper['publication_date'],
                    arxiv_id=paper['arxiv_id'],
                    doi=paper['doi'],
                    pubmed_id=paper['pubmed_id'],
                    journal=paper['venue'],
                    metadata={'source': 'semantic_scholar', 
                             'semantic_scholar_id': paper['semantic_scholar_id'],
                             'citation_count': paper['citation_count'],
                             'influential_citations': paper['influential_citations']}
                )
                
                # Update citation count
                conn = sqlite3.connect(db.db_path)
                conn.execute('''
                    UPDATE papers SET citation_count = ?, reference_count = ?,
                    influence_score = ?, semantic_scholar_id = ?
                    WHERE id = ?
                ''', (paper['citation_count'], paper['reference_count'],
                      paper['influential_citations'], paper['semantic_scholar_id'], paper_id))
                conn.commit()
                conn.close()
                
                # Add to collection
                await add_to_collection(save_to_collection, paper_id, 1.0)
                paper['paper_id'] = paper_id
                saved_papers.append(paper)
        
        # Log search query
        conn = sqlite3.connect(db.db_path)
        conn.execute('''
            INSERT INTO search_queries (query_text, source, results_count, parameters)
            VALUES (?, ?, ?, ?)
        ''', (query, 'semantic_scholar', len(papers), json.dumps({'limit': limit})))
        conn.commit()
        conn.close()
        
        return json.dumps({
            'source': 'semantic_scholar',
            'query': query,
            'results_count': len(papers),
            'papers': saved_papers if save_to_collection else papers,
            'collection': save_to_collection
        }, indent=2)
        
    except Exception as e:
        logger.error(f"Semantic Scholar search failed: {e}")
        return json.dumps({'error': f'Semantic Scholar search failed: {str(e)}'})

@mcp.tool()
def search_papers_database(query: str, limit: int = 20, 
                          collection_name: str = None) -> str:
    """
    Search papers in the local database using semantic similarity.
    
    Args:
        query: Search query text
        limit: Maximum number of results
        collection_name: Limit search to specific collection
    
    Returns:
        JSON array of matching papers with similarity scores
    """
    try:
        if collection_name:
            # Search within collection
            conn = sqlite3.connect(db.db_path)
            try:
                # Get collection papers and calculate similarity
                cursor = conn.execute('''
                    SELECT p.id, p.title, p.authors, p.abstract, p.publication_date,
                           p.citation_count, p.embedding, cp.relevance_score
                    FROM papers p
                    JOIN collection_papers cp ON p.id = cp.paper_id
                    JOIN research_collections rc ON cp.collection_id = rc.id
                    WHERE rc.collection_name = ? AND p.embedding IS NOT NULL
                ''', (collection_name,))
                
                papers_data = cursor.fetchall()
            finally:
                conn.close()
            
            # Calculate similarities
            if papers_data:
                model = get_embedding_model()
                query_embedding = model.encode([query])[0].astype(np.float32)
                
                results = []
                for row in papers_data:
                    paper_id, title, authors_json, abstract, pub_date, citations, embedding_blob, relevance = row
                    
                    embedding = np.frombuffer(embedding_blob, dtype=np.float32)
                    similarity = np.dot(query_embedding, embedding) / (
                        np.linalg.norm(query_embedding) * np.linalg.norm(embedding)
                    )
                    
                    results.append({
                        'paper_id': paper_id,
                        'title': title,
                        'authors': json.loads(authors_json),
                        'abstract': abstract[:300] + "..." if len(abstract) > 300 else abstract,
                        'publication_date': pub_date,
                        'citation_count': citations,
                        'similarity': float(similarity),
                        'collection_relevance': relevance
                    })
                
                results.sort(key=lambda x: x['similarity'], reverse=True)
                return json.dumps(results[:limit], indent=2)
        else:
            # Search all papers
            results = db.search_similar_papers(query, limit)
            return json.dumps(results, indent=2)
            
    except Exception as e:
        logger.error(f"Database search failed: {e}")
        return json.dumps({'error': f'Database search failed: {str(e)}'})

async def add_to_collection(collection_name: str, paper_id: int, relevance: float = 1.0):
    """Add paper to research collection (internal helper)"""
    conn = sqlite3.connect(db.db_path)
    try:
        # Get or create collection
        cursor = conn.execute('SELECT id FROM research_collections WHERE collection_name = ?', 
                            (collection_name,))
        row = cursor.fetchone()
        
        if not row:
            # Create collection
            cursor = conn.execute('''
                INSERT INTO research_collections (collection_name, description)
                VALUES (?, ?)
            ''', (collection_name, f"Auto-created collection: {collection_name}"))
            collection_id = cursor.lastrowid
        else:
            collection_id = row[0]
        
        # Add paper to collection
        conn.execute('''
            INSERT OR REPLACE INTO collection_papers (collection_id, paper_id, relevance_score)
            VALUES (?, ?, ?)
        ''', (collection_id, paper_id, relevance))
        
        # Update paper count
        conn.execute('''
            UPDATE research_collections 
            SET paper_count = (
                SELECT COUNT(*) FROM collection_papers WHERE collection_id = ?
            ),
            updated_at = CURRENT_TIMESTAMP
            WHERE id = ?
        ''', (collection_id, collection_id))
        
        conn.commit()
    finally:
        conn.close()

@mcp.tool()
def create_research_collection(collection_name: str, description: str = "", 
                              topic_focus: str = "") -> str:
    """
    Create a new research collection for organizing papers.
    
    Args:
        collection_name: Unique name for the collection
        description: Description of the collection
        topic_focus: Research topic focus area
    
    Returns:
        JSON with creation result
    """
    conn = sqlite3.connect(db.db_path)
    try:
        cursor = conn.execute('''
            INSERT INTO research_collections (collection_name, description, topic_focus)
            VALUES (?, ?, ?)
        ''', (collection_name, description, topic_focus))
        conn.commit()
        
        return json.dumps({
            'success': True,
            'collection_id': cursor.lastrowid,
            'collection_name': collection_name,
            'description': description,
            'topic_focus': topic_focus
        })
        
    except sqlite3.IntegrityError:
        return json.dumps({'error': f'Collection "{collection_name}" already exists'})
    except Exception as e:
        return json.dumps({'error': f'Collection creation failed: {str(e)}'})
    finally:
        conn.close()

@mcp.tool()
def list_research_collections() -> str:
    """
    List all research collections.
    
    Returns:
        JSON array of collections with metadata
    """
    conn = sqlite3.connect(db.db_path)
    try:
        cursor = conn.execute('''
            SELECT collection_name, description, topic_focus, created_at, updated_at, paper_count
            FROM research_collections
            ORDER BY updated_at DESC
        ''')
        
        collections = []
        for row in cursor.fetchall():
            collections.append({
                'collection_name': row[0],
                'description': row[1],
                'topic_focus': row[2],
                'created_at': row[3],
                'updated_at': row[4],
                'paper_count': row[5]
            })
        
        return json.dumps(collections, indent=2)
    finally:
        conn.close()

@mcp.tool()
async def get_paper_citations(paper_id: int, include_context: bool = True) -> str:
    """
    Get citations for a paper from Semantic Scholar.
    
    Args:
        paper_id: Internal paper ID
        include_context: Include citation contexts
    
    Returns:
        JSON with citation information
    """
    conn = sqlite3.connect(db.db_path)
    try:
        # Get paper's Semantic Scholar ID
        cursor = conn.execute('''
            SELECT semantic_scholar_id, title, authors 
            FROM papers WHERE id = ?
        ''', (paper_id,))
        row = cursor.fetchone()
        
        if not row or not row[0]:
            return json.dumps({'error': 'Paper not found or no Semantic Scholar ID'})
        
        semantic_id, title, authors_json = row
        
        # Get citations from Semantic Scholar
        fields = ['title', 'authors', 'year', 'citationCount', 'venue', 'externalIds']
        if include_context:
            fields.append('contexts')
        
        try:
            async with aiohttp.ClientSession() as session:
                url = f"{SEMANTIC_SCHOLAR_API}paper/{semantic_id}/citations"
                params = {'fields': ','.join(fields), 'limit': 100}
                async with session.get(url, params=params) as response:
                    data = await response.json()
            
            citations = []
            if 'data' in data:
                for citation in data['data']:
                    citing_paper = citation['citingPaper']
                    
                    citation_info = {
                        'title': citing_paper.get('title', ''),
                        'authors': [a['name'] for a in citing_paper.get('authors', [])],
                        'year': citing_paper.get('year'),
                        'venue': citing_paper.get('venue', ''),
                        'citation_count': citing_paper.get('citationCount', 0),
                        'semantic_scholar_id': citing_paper.get('paperId', '')
                    }
                    
                    if include_context and 'contexts' in citation:
                        citation_info['contexts'] = citation['contexts']
                    
                    citations.append(citation_info)
            
            return json.dumps({
                'paper_title': title,
                'paper_authors': json.loads(authors_json),
                'total_citations': len(citations),
                'citations': citations
            }, indent=2)
            
        except Exception as e:
            logger.error(f"Failed to get citations: {e}")
            return json.dumps({'error': f'Failed to get citations: {str(e)}'})
            
    finally:
        conn.close()

@mcp.tool()
def get_research_statistics() -> str:
    """
    Get statistics about the academic research database.
    
    Returns:
        JSON with database statistics and insights
    """
    conn = sqlite3.connect(db.db_path)
    try:
        # Basic counts
        cursor = conn.execute('SELECT COUNT(*) FROM papers')
        paper_count = cursor.fetchone()[0]
        
        cursor = conn.execute('SELECT COUNT(*) FROM authors')
        author_count = cursor.fetchone()[0]
        
        cursor = conn.execute('SELECT COUNT(*) FROM research_collections')
        collection_count = cursor.fetchone()[0]
        
        # Top venues
        cursor = conn.execute('''
            SELECT journal, COUNT(*) as count
            FROM papers
            WHERE journal != ''
            GROUP BY journal
            ORDER BY count DESC
            LIMIT 10
        ''')
        top_venues = [{'venue': row[0], 'paper_count': row[1]} for row in cursor.fetchall()]
        
        # Top authors by paper count
        cursor = conn.execute('''
            SELECT a.name, COUNT(pa.paper_id) as paper_count,
                   AVG(p.citation_count) as avg_citations
            FROM authors a
            JOIN paper_authors pa ON a.id = pa.author_id
            JOIN papers p ON pa.paper_id = p.id
            GROUP BY a.id, a.name
            HAVING paper_count > 1
            ORDER BY paper_count DESC
            LIMIT 10
        ''')
        
        top_authors = []
        for row in cursor.fetchall():
            top_authors.append({
                'name': row[0],
                'paper_count': row[1],
                'avg_citations': round(row[2], 2) if row[2] else 0
            })
        
        # Papers by year
        cursor = conn.execute('''
            SELECT SUBSTR(publication_date, 1, 4) as year, COUNT(*) as count
            FROM papers
            WHERE publication_date != ''
            GROUP BY year
            ORDER BY year DESC
            LIMIT 10
        ''')
        papers_by_year = [{'year': row[0], 'count': row[1]} for row in cursor.fetchall()]
        
        # Most cited papers
        cursor = conn.execute('''
            SELECT title, authors, citation_count, publication_date, journal
            FROM papers
            WHERE citation_count > 0
            ORDER BY citation_count DESC
            LIMIT 10
        ''')
        
        most_cited = []
        for row in cursor.fetchall():
            most_cited.append({
                'title': row[0],
                'authors': json.loads(row[1]) if row[1] else [],
                'citation_count': row[2],
                'publication_date': row[3],
                'journal': row[4]
            })
        
        return json.dumps({
            'overview': {
                'total_papers': paper_count,
                'total_authors': author_count,
                'total_collections': collection_count
            },
            'top_venues': top_venues,
            'top_authors': top_authors,
            'papers_by_year': papers_by_year,
            'most_cited_papers': most_cited
        }, indent=2)
        
    finally:
        conn.close()

if __name__ == "__main__":
    mcp.run()