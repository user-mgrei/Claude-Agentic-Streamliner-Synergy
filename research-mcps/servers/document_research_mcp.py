#!/usr/bin/env python3
"""
Document Research MCP Server
Handles PDF processing, academic paper analysis, and document intelligence.
Integrates with vector embeddings for semantic search.
"""

import os
import json
import sqlite3
import hashlib
import tempfile
from datetime import datetime
from pathlib import Path
from typing import List, Dict, Optional, Union
import logging
import asyncio

try:
    from fastmcp import FastMCP
    import PyPDF2
    import fitz  # PyMuPDF
    from sentence_transformers import SentenceTransformer
    import numpy as np
    import requests
    from urllib.parse import urlparse
    import magic  # python-magic
except ImportError as e:
    print(f"Missing dependencies: {e}")
    print("Install with: pip install fastmcp PyPDF2 PyMuPDF sentence-transformers numpy requests python-magic")
    exit(1)

# Configuration
DB_PATH = Path("research-mcps/databases/document_research.db")
EMBEDDINGS_MODEL = "all-MiniLM-L6-v2"  # Fast, good quality embeddings
CHUNK_SIZE = 512  # Text chunk size for embeddings
CHUNK_OVERLAP = 50  # Overlap between chunks

# Setup logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Initialize MCP
mcp = FastMCP("Document Research Server")

# Load embeddings model (lazy loading)
_embedding_model = None

def get_embedding_model():
    global _embedding_model
    if _embedding_model is None:
        logger.info(f"Loading embedding model: {EMBEDDINGS_MODEL}")
        _embedding_model = SentenceTransformer(EMBEDDINGS_MODEL)
    return _embedding_model

class DocumentResearchDB:
    def __init__(self, db_path: Path):
        self.db_path = db_path
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self.init_db()
    
    def init_db(self):
        """Initialize database schema for document research"""
        conn = sqlite3.connect(self.db_path)
        conn.executescript('''
            CREATE TABLE IF NOT EXISTS documents (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                filename TEXT NOT NULL,
                file_path TEXT UNIQUE,
                url TEXT,
                title TEXT,
                author TEXT,
                document_type TEXT, -- pdf, docx, txt, academic_paper, etc.
                file_size INTEGER,
                page_count INTEGER,
                content_hash TEXT,
                language TEXT,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                processed_at TIMESTAMP,
                metadata TEXT, -- JSON
                summary TEXT,
                keywords TEXT, -- JSON array
                status TEXT DEFAULT 'pending' -- pending, processed, failed
            );
            
            CREATE TABLE IF NOT EXISTS document_chunks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                document_id INTEGER,
                chunk_index INTEGER,
                page_number INTEGER,
                content TEXT,
                content_hash TEXT,
                embedding BLOB, -- Numpy array as blob
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY (document_id) REFERENCES documents(id)
            );
            
            CREATE TABLE IF NOT EXISTS research_collections (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                collection_name TEXT UNIQUE NOT NULL,
                description TEXT,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                document_count INTEGER DEFAULT 0,
                metadata TEXT -- JSON
            );
            
            CREATE TABLE IF NOT EXISTS collection_documents (
                collection_id INTEGER,
                document_id INTEGER,
                added_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                relevance_score REAL DEFAULT 1.0,
                notes TEXT,
                FOREIGN KEY (collection_id) REFERENCES research_collections(id),
                FOREIGN KEY (document_id) REFERENCES documents(id),
                PRIMARY KEY (collection_id, document_id)
            );
            
            CREATE TABLE IF NOT EXISTS citations (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                document_id INTEGER,
                cited_document_id INTEGER,
                citation_text TEXT,
                page_number INTEGER,
                confidence REAL DEFAULT 1.0,
                FOREIGN KEY (document_id) REFERENCES documents(id),
                FOREIGN KEY (cited_document_id) REFERENCES documents(id)
            );
            
            CREATE TABLE IF NOT EXISTS academic_metadata (
                document_id INTEGER PRIMARY KEY,
                doi TEXT,
                arxiv_id TEXT,
                pubmed_id TEXT,
                publication_year INTEGER,
                journal TEXT,
                venue TEXT,
                abstract TEXT,
                subject_areas TEXT, -- JSON array
                citation_count INTEGER DEFAULT 0,
                h_index REAL,
                impact_factor REAL,
                FOREIGN KEY (document_id) REFERENCES documents(id)
            );
            
            CREATE INDEX IF NOT EXISTS idx_documents_type ON documents(document_type);
            CREATE INDEX IF NOT EXISTS idx_documents_status ON documents(status);
            CREATE INDEX IF NOT EXISTS idx_chunks_document ON document_chunks(document_id);
            CREATE INDEX IF NOT EXISTS idx_chunks_page ON document_chunks(page_number);
            CREATE INDEX IF NOT EXISTS idx_collections_name ON research_collections(collection_name);
        ''')
        conn.commit()
        conn.close()

    def save_document(self, filename: str, file_path: str = None, url: str = None, 
                     title: str = None, author: str = None, document_type: str = None,
                     metadata: dict = None) -> int:
        """Save document metadata to database"""
        conn = sqlite3.connect(self.db_path)
        try:
            # Calculate file stats if local file
            file_size = 0
            content_hash = ""
            if file_path and os.path.exists(file_path):
                file_size = os.path.getsize(file_path)
                with open(file_path, 'rb') as f:
                    content_hash = hashlib.md5(f.read()).hexdigest()
            
            cursor = conn.execute('''
                INSERT INTO documents 
                (filename, file_path, url, title, author, document_type, file_size, 
                 content_hash, metadata)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ''', (filename, file_path, url, title, author, document_type, 
                  file_size, content_hash, json.dumps(metadata or {})))
            
            conn.commit()
            return cursor.lastrowid
        finally:
            conn.close()

    def save_chunks(self, document_id: int, chunks: List[Dict]):
        """Save document chunks with embeddings"""
        conn = sqlite3.connect(self.db_path)
        model = get_embedding_model()
        
        try:
            for chunk in chunks:
                # Generate embedding
                embedding = model.encode([chunk['content']])[0]
                embedding_blob = embedding.astype(np.float32).tobytes()
                
                # Calculate content hash
                content_hash = hashlib.md5(chunk['content'].encode()).hexdigest()
                
                conn.execute('''
                    INSERT INTO document_chunks 
                    (document_id, chunk_index, page_number, content, content_hash, embedding)
                    VALUES (?, ?, ?, ?, ?, ?)
                ''', (document_id, chunk['index'], chunk.get('page', 0), 
                      chunk['content'], content_hash, embedding_blob))
            
            # Update document status
            conn.execute('''
                UPDATE documents SET status = 'processed', processed_at = CURRENT_TIMESTAMP,
                page_count = ? WHERE id = ?
            ''', (max([c.get('page', 0) for c in chunks], default=0), document_id))
            
            conn.commit()
        finally:
            conn.close()

    def search_similar_chunks(self, query_text: str, limit: int = 10, 
                            collection_name: str = None) -> List[Dict]:
        """Search for similar document chunks using embeddings"""
        model = get_embedding_model()
        query_embedding = model.encode([query_text])[0].astype(np.float32)
        
        conn = sqlite3.connect(self.db_path)
        try:
            if collection_name:
                cursor = conn.execute('''
                    SELECT dc.id, dc.document_id, dc.content, dc.page_number, 
                           dc.embedding, d.title, d.filename, d.author
                    FROM document_chunks dc
                    JOIN documents d ON dc.document_id = d.id
                    JOIN collection_documents cd ON d.id = cd.document_id
                    JOIN research_collections rc ON cd.collection_id = rc.id
                    WHERE d.status = 'processed' AND rc.collection_name = ?
                ''', (collection_name,))
            else:
                cursor = conn.execute('''
                    SELECT dc.id, dc.document_id, dc.content, dc.page_number,
                           dc.embedding, d.title, d.filename, d.author
                    FROM document_chunks dc
                    JOIN documents d ON dc.document_id = d.id
                    WHERE d.status = 'processed'
                ''')
            
            results = []
            for row in cursor.fetchall():
                chunk_id, doc_id, content, page_num, embedding_blob, title, filename, author = row
                
                # Convert embedding back from blob
                embedding = np.frombuffer(embedding_blob, dtype=np.float32)
                
                # Calculate cosine similarity
                similarity = np.dot(query_embedding, embedding) / (
                    np.linalg.norm(query_embedding) * np.linalg.norm(embedding)
                )
                
                results.append({
                    'chunk_id': chunk_id,
                    'document_id': doc_id,
                    'content': content,
                    'page_number': page_num,
                    'title': title,
                    'filename': filename,
                    'author': author,
                    'similarity': float(similarity)
                })
            
            # Sort by similarity and return top results
            results.sort(key=lambda x: x['similarity'], reverse=True)
            return results[:limit]
            
        finally:
            conn.close()

# Initialize database
db = DocumentResearchDB(DB_PATH)

class DocumentProcessor:
    """Document processing utilities"""
    
    @staticmethod
    def detect_document_type(file_path: str) -> str:
        """Detect document type using python-magic"""
        try:
            mime_type = magic.from_file(file_path, mime=True)
            if 'pdf' in mime_type:
                return 'pdf'
            elif 'word' in mime_type or 'msword' in mime_type:
                return 'docx'
            elif 'text' in mime_type:
                return 'txt'
            else:
                return 'unknown'
        except Exception:
            # Fallback to file extension
            ext = Path(file_path).suffix.lower()
            if ext == '.pdf':
                return 'pdf'
            elif ext in ['.docx', '.doc']:
                return 'docx'
            elif ext in ['.txt', '.md']:
                return 'txt'
            else:
                return 'unknown'

    @staticmethod
    def extract_text_from_pdf(file_path: str) -> List[Dict]:
        """Extract text from PDF with page information"""
        chunks = []
        
        try:
            # Try PyMuPDF first (better for complex PDFs)
            doc = fitz.open(file_path)
            
            for page_num in range(len(doc)):
                page = doc[page_num]
                text = page.get_text()
                
                if text.strip():
                    # Split into smaller chunks
                    text_chunks = DocumentProcessor.split_text(text, CHUNK_SIZE, CHUNK_OVERLAP)
                    for i, chunk in enumerate(text_chunks):
                        chunks.append({
                            'index': len(chunks),
                            'page': page_num + 1,
                            'content': chunk,
                            'method': 'pymupdf'
                        })
            
            doc.close()
            
        except Exception as e:
            logger.warning(f"PyMuPDF failed, trying PyPDF2: {e}")
            
            # Fallback to PyPDF2
            try:
                with open(file_path, 'rb') as file:
                    pdf_reader = PyPDF2.PdfReader(file)
                    
                    for page_num in range(len(pdf_reader.pages)):
                        page = pdf_reader.pages[page_num]
                        text = page.extract_text()
                        
                        if text.strip():
                            text_chunks = DocumentProcessor.split_text(text, CHUNK_SIZE, CHUNK_OVERLAP)
                            for chunk in text_chunks:
                                chunks.append({
                                    'index': len(chunks),
                                    'page': page_num + 1,
                                    'content': chunk,
                                    'method': 'pypdf2'
                                })
                                
            except Exception as e2:
                logger.error(f"Both PDF extraction methods failed: {e2}")
                raise
        
        return chunks

    @staticmethod
    def extract_text_from_txt(file_path: str) -> List[Dict]:
        """Extract text from plain text files"""
        chunks = []
        
        try:
            with open(file_path, 'r', encoding='utf-8') as file:
                content = file.read()
                
            text_chunks = DocumentProcessor.split_text(content, CHUNK_SIZE, CHUNK_OVERLAP)
            for i, chunk in enumerate(text_chunks):
                chunks.append({
                    'index': i,
                    'page': 1,
                    'content': chunk
                })
                
        except UnicodeDecodeError:
            # Try different encodings
            for encoding in ['latin-1', 'cp1252', 'iso-8859-1']:
                try:
                    with open(file_path, 'r', encoding=encoding) as file:
                        content = file.read()
                    
                    text_chunks = DocumentProcessor.split_text(content, CHUNK_SIZE, CHUNK_OVERLAP)
                    for i, chunk in enumerate(text_chunks):
                        chunks.append({
                            'index': i,
                            'page': 1,
                            'content': chunk
                        })
                    break
                except UnicodeDecodeError:
                    continue
        
        return chunks

    @staticmethod
    def split_text(text: str, chunk_size: int = CHUNK_SIZE, overlap: int = CHUNK_OVERLAP) -> List[str]:
        """Split text into overlapping chunks"""
        if len(text) <= chunk_size:
            return [text]
        
        chunks = []
        start = 0
        
        while start < len(text):
            end = start + chunk_size
            
            # Try to break at sentence boundaries
            if end < len(text):
                # Look for sentence endings near the chunk boundary
                for i in range(min(100, chunk_size // 4)):
                    if end - i > start and text[end - i] in '.!?':
                        end = end - i + 1
                        break
            
            chunk = text[start:end].strip()
            if chunk:
                chunks.append(chunk)
            
            start = end - overlap
            if start >= len(text):
                break
        
        return chunks

@mcp.tool()
async def process_document(file_path: str, collection_name: str = "default", 
                          title: str = None, author: str = None) -> str:
    """
    Process a document (PDF, TXT, etc.) for research analysis.
    
    Args:
        file_path: Path to the document file
        collection_name: Research collection to add document to
        title: Document title (optional, will extract if not provided)
        author: Document author (optional)
    
    Returns:
        JSON with processing results and document metadata
    """
    if not os.path.exists(file_path):
        return json.dumps({'error': f'File not found: {file_path}'})
    
    try:
        filename = os.path.basename(file_path)
        doc_type = DocumentProcessor.detect_document_type(file_path)
        
        # Save document metadata
        doc_id = db.save_document(
            filename=filename,
            file_path=file_path,
            title=title or filename,
            author=author,
            document_type=doc_type,
            metadata={'processor': 'document_research_mcp', 'collection': collection_name}
        )
        
        # Extract text chunks based on document type
        if doc_type == 'pdf':
            chunks = DocumentProcessor.extract_text_from_pdf(file_path)
        elif doc_type == 'txt':
            chunks = DocumentProcessor.extract_text_from_txt(file_path)
        else:
            return json.dumps({'error': f'Unsupported document type: {doc_type}'})
        
        if not chunks:
            return json.dumps({'error': 'No text content extracted from document'})
        
        # Save chunks with embeddings
        db.save_chunks(doc_id, chunks)
        
        # Add to collection
        await add_document_to_collection(collection_name, doc_id)
        
        return json.dumps({
            'success': True,
            'document_id': doc_id,
            'filename': filename,
            'document_type': doc_type,
            'chunk_count': len(chunks),
            'total_pages': max([c.get('page', 1) for c in chunks]),
            'collection': collection_name
        })
        
    except Exception as e:
        logger.error(f"Document processing failed for {file_path}: {e}")
        return json.dumps({'error': f'Processing failed: {str(e)}'})

@mcp.tool()
async def download_and_process_pdf(url: str, collection_name: str = "default",
                                  title: str = None, author: str = None) -> str:
    """
    Download a PDF from URL and process it for research.
    
    Args:
        url: URL of the PDF to download
        collection_name: Research collection to add document to
        title: Document title (optional)
        author: Document author (optional)
    
    Returns:
        JSON with download and processing results
    """
    try:
        # Download the PDF
        response = requests.get(url, headers={'User-Agent': 'Research Bot'})
        response.raise_for_status()
        
        # Save to temporary file
        with tempfile.NamedTemporaryFile(delete=False, suffix='.pdf') as temp_file:
            temp_file.write(response.content)
            temp_path = temp_file.name
        
        try:
            # Process the downloaded file
            result = await process_document(temp_path, collection_name, title, author)
            result_data = json.loads(result)
            
            if result_data.get('success'):
                # Update with URL info
                conn = sqlite3.connect(db.db_path)
                conn.execute('UPDATE documents SET url = ? WHERE id = ?', 
                           (url, result_data['document_id']))
                conn.commit()
                conn.close()
                
                result_data['url'] = url
                result_data['downloaded'] = True
            
            return json.dumps(result_data)
            
        finally:
            # Clean up temporary file
            os.unlink(temp_path)
            
    except Exception as e:
        logger.error(f"PDF download/processing failed for {url}: {e}")
        return json.dumps({'error': f'Download failed: {str(e)}'})

@mcp.tool()
def search_documents(query: str, collection_name: str = None, limit: int = 10) -> str:
    """
    Search documents using semantic similarity.
    
    Args:
        query: Search query text
        collection_name: Limit search to specific collection (optional)
        limit: Maximum number of results
    
    Returns:
        JSON array of matching document chunks with similarity scores
    """
    try:
        results = db.search_similar_chunks(query, limit, collection_name)
        return json.dumps(results, indent=2)
    except Exception as e:
        logger.error(f"Document search failed: {e}")
        return json.dumps({'error': f'Search failed: {str(e)}'})

@mcp.tool()
async def create_collection(collection_name: str, description: str = "") -> str:
    """
    Create a new research collection.
    
    Args:
        collection_name: Unique name for the collection
        description: Description of the collection
    
    Returns:
        JSON with creation result
    """
    conn = sqlite3.connect(db.db_path)
    try:
        cursor = conn.execute('''
            INSERT INTO research_collections (collection_name, description)
            VALUES (?, ?)
        ''', (collection_name, description))
        conn.commit()
        
        return json.dumps({
            'success': True,
            'collection_id': cursor.lastrowid,
            'collection_name': collection_name,
            'description': description
        })
        
    except sqlite3.IntegrityError:
        return json.dumps({'error': f'Collection "{collection_name}" already exists'})
    except Exception as e:
        return json.dumps({'error': f'Collection creation failed: {str(e)}'})
    finally:
        conn.close()

async def add_document_to_collection(collection_name: str, document_id: int):
    """Add document to collection (internal helper)"""
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
        
        # Add document to collection
        conn.execute('''
            INSERT OR REPLACE INTO collection_documents (collection_id, document_id)
            VALUES (?, ?)
        ''', (collection_id, document_id))
        
        # Update document count
        conn.execute('''
            UPDATE research_collections 
            SET document_count = (
                SELECT COUNT(*) FROM collection_documents WHERE collection_id = ?
            ),
            updated_at = CURRENT_TIMESTAMP
            WHERE id = ?
        ''', (collection_id, collection_id))
        
        conn.commit()
    finally:
        conn.close()

@mcp.tool()
def list_collections() -> str:
    """
    List all research collections with document counts.
    
    Returns:
        JSON array of collections
    """
    conn = sqlite3.connect(db.db_path)
    try:
        cursor = conn.execute('''
            SELECT collection_name, description, created_at, updated_at, document_count
            FROM research_collections
            ORDER BY updated_at DESC
        ''')
        
        collections = []
        for row in cursor.fetchall():
            collections.append({
                'collection_name': row[0],
                'description': row[1],
                'created_at': row[2],
                'updated_at': row[3],
                'document_count': row[4]
            })
        
        return json.dumps(collections, indent=2)
    finally:
        conn.close()

@mcp.tool()
def get_collection_summary(collection_name: str) -> str:
    """
    Get detailed summary of a research collection.
    
    Args:
        collection_name: Name of the collection
    
    Returns:
        JSON summary with documents and statistics
    """
    conn = sqlite3.connect(db.db_path)
    try:
        # Get collection info
        cursor = conn.execute('''
            SELECT description, created_at, updated_at, document_count
            FROM research_collections 
            WHERE collection_name = ?
        ''', (collection_name,))
        collection_info = cursor.fetchone()
        
        if not collection_info:
            return json.dumps({'error': f'Collection "{collection_name}" not found'})
        
        # Get documents in collection
        cursor = conn.execute('''
            SELECT d.id, d.filename, d.title, d.author, d.document_type,
                   d.page_count, d.created_at, cd.relevance_score
            FROM documents d
            JOIN collection_documents cd ON d.id = cd.document_id
            JOIN research_collections rc ON cd.collection_id = rc.id
            WHERE rc.collection_name = ?
            ORDER BY cd.relevance_score DESC, d.created_at DESC
        ''', (collection_name,))
        
        documents = []
        doc_types = {}
        for row in cursor.fetchall():
            doc_data = {
                'document_id': row[0],
                'filename': row[1],
                'title': row[2],
                'author': row[3],
                'document_type': row[4],
                'page_count': row[5],
                'created_at': row[6],
                'relevance_score': row[7]
            }
            documents.append(doc_data)
            doc_types[row[4]] = doc_types.get(row[4], 0) + 1
        
        summary = {
            'collection_name': collection_name,
            'description': collection_info[0],
            'created_at': collection_info[1],
            'updated_at': collection_info[2],
            'document_count': collection_info[3],
            'document_types': doc_types,
            'documents': documents
        }
        
        return json.dumps(summary, indent=2)
    finally:
        conn.close()

if __name__ == "__main__":
    mcp.run()