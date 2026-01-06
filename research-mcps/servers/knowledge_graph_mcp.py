#!/usr/bin/env python3
"""
Knowledge Graph MCP Server
Creates and manages knowledge graphs from research data.
Connects entities, concepts, and relationships across sources.
"""

import json
import sqlite3
import hashlib
from datetime import datetime
from pathlib import Path
from typing import List, Dict, Optional, Tuple, Set
import logging
import re

try:
    from fastmcp import FastMCP
    import networkx as nx
    from sentence_transformers import SentenceTransformer
    import numpy as np
    from collections import defaultdict, Counter
    import spacy
except ImportError as e:
    print(f"Missing dependencies: {e}")
    print("Install with: pip install fastmcp networkx sentence-transformers spacy")
    print("Also run: python -m spacy download en_core_web_sm")
    exit(1)

# Configuration
DB_PATH = Path("research-mcps/databases/knowledge_graph.db")
EMBEDDINGS_MODEL = "all-MiniLM-L6-v2"
SIMILARITY_THRESHOLD = 0.75  # Threshold for entity similarity
MIN_ENTITY_FREQUENCY = 2    # Minimum frequency for entity extraction

# Setup logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Initialize MCP
mcp = FastMCP("Knowledge Graph Server")

# Load models (lazy loading)
_embedding_model = None
_nlp_model = None

def get_embedding_model():
    global _embedding_model
    if _embedding_model is None:
        logger.info(f"Loading embedding model: {EMBEDDINGS_MODEL}")
        _embedding_model = SentenceTransformer(EMBEDDINGS_MODEL)
    return _embedding_model

def get_nlp_model():
    global _nlp_model
    if _nlp_model is None:
        logger.info("Loading spaCy NLP model")
        try:
            _nlp_model = spacy.load("en_core_web_sm")
        except OSError:
            logger.error("spaCy English model not found. Install with: python -m spacy download en_core_web_sm")
            raise
    return _nlp_model

class KnowledgeGraphDB:
    def __init__(self, db_path: Path):
        self.db_path = db_path
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self.init_db()
    
    def init_db(self):
        """Initialize knowledge graph database schema"""
        conn = sqlite3.connect(self.db_path)
        conn.executescript('''
            CREATE TABLE IF NOT EXISTS entities (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                entity_type TEXT, -- PERSON, ORG, CONCEPT, LOCATION, etc.
                canonical_name TEXT, -- Normalized form
                description TEXT,
                frequency INTEGER DEFAULT 1,
                confidence REAL DEFAULT 1.0,
                embedding BLOB, -- Vector embedding
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                metadata TEXT -- JSON
            );
            
            CREATE TABLE IF NOT EXISTS relationships (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                source_entity_id INTEGER,
                target_entity_id INTEGER,
                relationship_type TEXT, -- MENTIONS, CITES, RELATED_TO, PART_OF, etc.
                strength REAL DEFAULT 1.0,
                context TEXT, -- Context where relationship was found
                source_document TEXT, -- Source document/URL
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                metadata TEXT, -- JSON
                FOREIGN KEY (source_entity_id) REFERENCES entities(id),
                FOREIGN KEY (target_entity_id) REFERENCES entities(id)
            );
            
            CREATE TABLE IF NOT EXISTS concepts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                concept_name TEXT UNIQUE NOT NULL,
                concept_type TEXT, -- TOPIC, THEME, METHODOLOGY, etc.
                description TEXT,
                keywords TEXT, -- JSON array
                definition TEXT,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            );
            
            CREATE TABLE IF NOT EXISTS entity_concepts (
                entity_id INTEGER,
                concept_id INTEGER,
                relevance_score REAL DEFAULT 1.0,
                context TEXT,
                FOREIGN KEY (entity_id) REFERENCES entities(id),
                FOREIGN KEY (concept_id) REFERENCES concepts(id),
                PRIMARY KEY (entity_id, concept_id)
            );
            
            CREATE TABLE IF NOT EXISTS document_entities (
                document_id TEXT, -- External document ID
                entity_id INTEGER,
                mention_count INTEGER DEFAULT 1,
                first_mention TEXT,
                contexts TEXT, -- JSON array of contexts
                document_source TEXT, -- web_research, document_research, etc.
                FOREIGN KEY (entity_id) REFERENCES entities(id),
                PRIMARY KEY (document_id, entity_id)
            );
            
            CREATE TABLE IF NOT EXISTS knowledge_clusters (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                cluster_name TEXT UNIQUE NOT NULL,
                description TEXT,
                entity_ids TEXT, -- JSON array of entity IDs
                concept_ids TEXT, -- JSON array of concept IDs
                cluster_score REAL DEFAULT 1.0,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                metadata TEXT -- JSON
            );
            
            CREATE INDEX IF NOT EXISTS idx_entities_name ON entities(canonical_name);
            CREATE INDEX IF NOT EXISTS idx_entities_type ON entities(entity_type);
            CREATE INDEX IF NOT EXISTS idx_entities_freq ON entities(frequency DESC);
            CREATE INDEX IF NOT EXISTS idx_relationships_source ON relationships(source_entity_id);
            CREATE INDEX IF NOT EXISTS idx_relationships_target ON relationships(target_entity_id);
            CREATE INDEX IF NOT EXISTS idx_relationships_type ON relationships(relationship_type);
            CREATE INDEX IF NOT EXISTS idx_concepts_name ON concepts(concept_name);
            CREATE INDEX IF NOT EXISTS idx_document_entities_doc ON document_entities(document_id);
        ''')
        conn.commit()
        conn.close()

    def save_entity(self, name: str, entity_type: str, description: str = "", 
                   confidence: float = 1.0, metadata: dict = None) -> int:
        """Save or update entity"""
        canonical_name = self.normalize_entity_name(name)
        model = get_embedding_model()
        embedding = model.encode([canonical_name])[0].astype(np.float32).tobytes()
        
        conn = sqlite3.connect(self.db_path)
        try:
            # Check if entity exists
            cursor = conn.execute('''
                SELECT id, frequency FROM entities WHERE canonical_name = ? AND entity_type = ?
            ''', (canonical_name, entity_type))
            row = cursor.fetchone()
            
            if row:
                # Update existing entity
                entity_id, freq = row
                conn.execute('''
                    UPDATE entities 
                    SET frequency = frequency + 1, confidence = MAX(confidence, ?),
                        updated_at = CURRENT_TIMESTAMP,
                        description = CASE WHEN description = '' THEN ? ELSE description END
                    WHERE id = ?
                ''', (confidence, description, entity_id))
            else:
                # Create new entity
                cursor = conn.execute('''
                    INSERT INTO entities 
                    (name, entity_type, canonical_name, description, confidence, embedding, metadata)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                ''', (name, entity_type, canonical_name, description, confidence, 
                      embedding, json.dumps(metadata or {})))
                entity_id = cursor.lastrowid
            
            conn.commit()
            return entity_id
        finally:
            conn.close()

    def save_relationship(self, source_entity_id: int, target_entity_id: int,
                         relationship_type: str, strength: float = 1.0,
                         context: str = "", source_document: str = "",
                         metadata: dict = None) -> int:
        """Save entity relationship"""
        conn = sqlite3.connect(self.db_path)
        try:
            cursor = conn.execute('''
                INSERT INTO relationships 
                (source_entity_id, target_entity_id, relationship_type, strength, 
                 context, source_document, metadata)
                VALUES (?, ?, ?, ?, ?, ?, ?)
            ''', (source_entity_id, target_entity_id, relationship_type, strength,
                  context, source_document, json.dumps(metadata or {})))
            conn.commit()
            return cursor.lastrowid
        finally:
            conn.close()

    def find_similar_entities(self, entity_name: str, entity_type: str = None, 
                            threshold: float = SIMILARITY_THRESHOLD) -> List[Dict]:
        """Find similar entities using embeddings"""
        model = get_embedding_model()
        query_embedding = model.encode([self.normalize_entity_name(entity_name)])[0].astype(np.float32)
        
        conn = sqlite3.connect(self.db_path)
        try:
            if entity_type:
                cursor = conn.execute('''
                    SELECT id, name, canonical_name, entity_type, embedding, frequency
                    FROM entities WHERE entity_type = ?
                ''', (entity_type,))
            else:
                cursor = conn.execute('''
                    SELECT id, name, canonical_name, entity_type, embedding, frequency
                    FROM entities
                ''')
            
            similar_entities = []
            for row in cursor.fetchall():
                entity_id, name, canonical_name, ent_type, embedding_blob, frequency = row
                
                # Calculate similarity
                embedding = np.frombuffer(embedding_blob, dtype=np.float32)
                similarity = np.dot(query_embedding, embedding) / (
                    np.linalg.norm(query_embedding) * np.linalg.norm(embedding)
                )
                
                if similarity >= threshold:
                    similar_entities.append({
                        'entity_id': entity_id,
                        'name': name,
                        'canonical_name': canonical_name,
                        'entity_type': ent_type,
                        'frequency': frequency,
                        'similarity': float(similarity)
                    })
            
            # Sort by similarity
            similar_entities.sort(key=lambda x: x['similarity'], reverse=True)
            return similar_entities
            
        finally:
            conn.close()

    @staticmethod
    def normalize_entity_name(name: str) -> str:
        """Normalize entity name for consistent storage"""
        # Remove extra whitespace, convert to lowercase
        normalized = re.sub(r'\s+', ' ', name.strip().lower())
        # Remove common prefixes/suffixes
        normalized = re.sub(r'\b(the|a|an)\s+', '', normalized)
        normalized = re.sub(r'\s+(inc|ltd|corp|llc)\.?$', '', normalized)
        return normalized

# Initialize database
db = KnowledgeGraphDB(DB_PATH)

class EntityExtractor:
    """Extract entities and relationships from text"""
    
    @staticmethod
    def extract_entities(text: str, source_document: str = "") -> List[Dict]:
        """Extract named entities from text using spaCy"""
        nlp = get_nlp_model()
        doc = nlp(text)
        
        entities = []
        entity_counts = Counter()
        
        for ent in doc.ents:
            # Filter by entity types of interest
            if ent.label_ in ['PERSON', 'ORG', 'GPE', 'EVENT', 'WORK_OF_ART', 'LAW', 'LANGUAGE']:
                entity_text = ent.text.strip()
                if len(entity_text) > 2:  # Filter very short entities
                    entity_counts[entity_text] += 1
                    
                    # Get surrounding context
                    start = max(0, ent.start - 10)
                    end = min(len(doc), ent.end + 10)
                    context = ' '.join([token.text for token in doc[start:end]])
                    
                    entities.append({
                        'name': entity_text,
                        'type': ent.label_,
                        'context': context,
                        'start_pos': ent.start_char,
                        'end_pos': ent.end_char,
                        'confidence': 0.8  # Default confidence for spaCy entities
                    })
        
        # Filter by minimum frequency if multiple occurrences
        frequent_entities = []
        for entity in entities:
            if entity_counts[entity['name']] >= MIN_ENTITY_FREQUENCY or len(entities) < 10:
                frequent_entities.append(entity)
        
        return frequent_entities

    @staticmethod
    def extract_relationships(text: str, entities: List[Dict]) -> List[Dict]:
        """Extract relationships between entities based on proximity and patterns"""
        nlp = get_nlp_model()
        doc = nlp(text)
        
        relationships = []
        entity_positions = {}
        
        # Map entity positions
        for entity in entities:
            entity_positions[entity['name']] = {
                'start': entity['start_pos'],
                'end': entity['end_pos'],
                'type': entity['type']
            }
        
        # Find co-occurrences within sentence boundaries
        for sent in doc.sents:
            sent_entities = []
            for entity_name, pos_info in entity_positions.items():
                if sent.start_char <= pos_info['start'] <= sent.end_char:
                    sent_entities.append((entity_name, pos_info))
            
            # Create relationships between entities in the same sentence
            for i, (entity1, pos1) in enumerate(sent_entities):
                for j, (entity2, pos2) in enumerate(sent_entities[i+1:], i+1):
                    # Determine relationship type based on patterns
                    rel_type = EntityExtractor.determine_relationship_type(
                        entity1, pos1, entity2, pos2, sent.text
                    )
                    
                    relationships.append({
                        'source': entity1,
                        'target': entity2,
                        'type': rel_type,
                        'context': sent.text,
                        'strength': 1.0 / (abs(i - j) + 1)  # Closer entities have stronger relationships
                    })
        
        return relationships

    @staticmethod
    def determine_relationship_type(entity1: str, pos1: Dict, entity2: str, pos2: Dict, context: str) -> str:
        """Determine relationship type based on entity types and context"""
        type1, type2 = pos1['type'], pos2['type']
        context_lower = context.lower()
        
        # Person-Organization relationships
        if type1 == 'PERSON' and type2 == 'ORG':
            if any(word in context_lower for word in ['ceo', 'president', 'director', 'founder']):
                return 'LEADS'
            elif any(word in context_lower for word in ['works at', 'employed by', 'member of']):
                return 'WORKS_AT'
            else:
                return 'AFFILIATED_WITH'
        
        # Organization-Location relationships
        elif type1 == 'ORG' and type2 == 'GPE':
            if any(word in context_lower for word in ['based in', 'headquarters', 'located in']):
                return 'LOCATED_IN'
            else:
                return 'OPERATES_IN'
        
        # Person-Person relationships
        elif type1 == 'PERSON' and type2 == 'PERSON':
            if any(word in context_lower for word in ['and', 'with', 'colleague']):
                return 'COLLABORATES_WITH'
            else:
                return 'ASSOCIATED_WITH'
        
        # Citation/Reference patterns
        elif any(word in context_lower for word in ['cited', 'references', 'according to']):
            return 'CITES'
        
        # Default relationship
        else:
            return 'MENTIONED_WITH'

@mcp.tool()
async def extract_knowledge_from_text(text: str, source_document: str = "", 
                                    document_id: str = "") -> str:
    """
    Extract entities and relationships from text to build knowledge graph.
    
    Args:
        text: Text content to analyze
        source_document: Source document identifier
        document_id: External document ID for tracking
    
    Returns:
        JSON with extracted entities and relationships
    """
    try:
        # Extract entities
        entities = EntityExtractor.extract_entities(text, source_document)
        
        if not entities:
            return json.dumps({
                'success': True,
                'entities_count': 0,
                'relationships_count': 0,
                'message': 'No significant entities found in text'
            })
        
        # Save entities to database
        entity_ids = {}
        saved_entities = []
        
        for entity in entities:
            entity_id = db.save_entity(
                name=entity['name'],
                entity_type=entity['type'],
                description=f"Entity found in {source_document}",
                confidence=entity['confidence']
            )
            entity_ids[entity['name']] = entity_id
            saved_entities.append({
                'entity_id': entity_id,
                'name': entity['name'],
                'type': entity['type'],
                'confidence': entity['confidence']
            })
        
        # Extract relationships
        relationships = EntityExtractor.extract_relationships(text, entities)
        saved_relationships = []
        
        for rel in relationships:
            if rel['source'] in entity_ids and rel['target'] in entity_ids:
                rel_id = db.save_relationship(
                    source_entity_id=entity_ids[rel['source']],
                    target_entity_id=entity_ids[rel['target']],
                    relationship_type=rel['type'],
                    strength=rel['strength'],
                    context=rel['context'],
                    source_document=source_document
                )
                saved_relationships.append({
                    'relationship_id': rel_id,
                    'source': rel['source'],
                    'target': rel['target'],
                    'type': rel['type'],
                    'strength': rel['strength']
                })
        
        return json.dumps({
            'success': True,
            'entities_count': len(saved_entities),
            'relationships_count': len(saved_relationships),
            'entities': saved_entities,
            'relationships': saved_relationships,
            'source_document': source_document
        })
        
    except Exception as e:
        logger.error(f"Knowledge extraction failed: {e}")
        return json.dumps({'error': f'Extraction failed: {str(e)}'})

@mcp.tool()
def search_entities(query: str, entity_type: str = None, limit: int = 20) -> str:
    """
    Search entities in the knowledge graph.
    
    Args:
        query: Search query
        entity_type: Filter by entity type (optional)
        limit: Maximum number of results
    
    Returns:
        JSON array of matching entities
    """
    conn = sqlite3.connect(db.db_path)
    try:
        if entity_type:
            cursor = conn.execute('''
                SELECT id, name, canonical_name, entity_type, description, frequency, confidence
                FROM entities 
                WHERE (name LIKE ? OR canonical_name LIKE ?) AND entity_type = ?
                ORDER BY frequency DESC, confidence DESC
                LIMIT ?
            ''', (f'%{query}%', f'%{query}%', entity_type, limit))
        else:
            cursor = conn.execute('''
                SELECT id, name, canonical_name, entity_type, description, frequency, confidence
                FROM entities 
                WHERE name LIKE ? OR canonical_name LIKE ?
                ORDER BY frequency DESC, confidence DESC
                LIMIT ?
            ''', (f'%{query}%', f'%{query}%', limit))
        
        entities = []
        for row in cursor.fetchall():
            entities.append({
                'entity_id': row[0],
                'name': row[1],
                'canonical_name': row[2],
                'entity_type': row[3],
                'description': row[4],
                'frequency': row[5],
                'confidence': row[6]
            })
        
        return json.dumps(entities, indent=2)
    finally:
        conn.close()

@mcp.tool()
def get_entity_relationships(entity_id: int, relationship_types: List[str] = None) -> str:
    """
    Get all relationships for an entity.
    
    Args:
        entity_id: Entity ID to get relationships for
        relationship_types: Filter by relationship types (optional)
    
    Returns:
        JSON with incoming and outgoing relationships
    """
    conn = sqlite3.connect(db.db_path)
    try:
        # Get entity info
        cursor = conn.execute('SELECT name, entity_type FROM entities WHERE id = ?', (entity_id,))
        entity_info = cursor.fetchone()
        
        if not entity_info:
            return json.dumps({'error': f'Entity {entity_id} not found'})
        
        entity_name, entity_type = entity_info
        
        # Build relationship filter
        rel_filter = ""
        params = [entity_id, entity_id]
        if relationship_types:
            rel_filter = "AND relationship_type IN ({})".format(','.join('?' * len(relationship_types)))
            params.extend(relationship_types)
        
        # Get outgoing relationships
        cursor = conn.execute(f'''
            SELECT r.id, r.target_entity_id, e.name, e.entity_type, r.relationship_type,
                   r.strength, r.context, r.source_document
            FROM relationships r
            JOIN entities e ON r.target_entity_id = e.id
            WHERE r.source_entity_id = ? {rel_filter}
            ORDER BY r.strength DESC
        ''', params[:1] + params[2:] if relationship_types else [entity_id])
        
        outgoing = []
        for row in cursor.fetchall():
            outgoing.append({
                'relationship_id': row[0],
                'target_entity_id': row[1],
                'target_name': row[2],
                'target_type': row[3],
                'relationship_type': row[4],
                'strength': row[5],
                'context': row[6],
                'source_document': row[7]
            })
        
        # Get incoming relationships
        cursor = conn.execute(f'''
            SELECT r.id, r.source_entity_id, e.name, e.entity_type, r.relationship_type,
                   r.strength, r.context, r.source_document
            FROM relationships r
            JOIN entities e ON r.source_entity_id = e.id
            WHERE r.target_entity_id = ? {rel_filter}
            ORDER BY r.strength DESC
        ''', [entity_id] + (params[2:] if relationship_types else []))
        
        incoming = []
        for row in cursor.fetchall():
            incoming.append({
                'relationship_id': row[0],
                'source_entity_id': row[1],
                'source_name': row[2],
                'source_type': row[3],
                'relationship_type': row[4],
                'strength': row[5],
                'context': row[6],
                'source_document': row[7]
            })
        
        return json.dumps({
            'entity': {
                'id': entity_id,
                'name': entity_name,
                'type': entity_type
            },
            'outgoing_relationships': outgoing,
            'incoming_relationships': incoming,
            'total_relationships': len(outgoing) + len(incoming)
        }, indent=2)
        
    finally:
        conn.close()

@mcp.tool()
def build_subgraph(entity_ids: List[int], max_depth: int = 2) -> str:
    """
    Build a subgraph around specified entities.
    
    Args:
        entity_ids: List of entity IDs to center the subgraph around
        max_depth: Maximum relationship depth to include
    
    Returns:
        JSON representation of the subgraph
    """
    conn = sqlite3.connect(db.db_path)
    try:
        # Build graph using NetworkX
        G = nx.Graph()
        visited_entities = set()
        current_entities = set(entity_ids)
        
        for depth in range(max_depth):
            next_entities = set()
            
            for entity_id in current_entities:
                if entity_id in visited_entities:
                    continue
                
                visited_entities.add(entity_id)
                
                # Get entity info
                cursor = conn.execute('''
                    SELECT name, entity_type, frequency, confidence
                    FROM entities WHERE id = ?
                ''', (entity_id,))
                entity_info = cursor.fetchone()
                
                if entity_info:
                    G.add_node(entity_id, 
                             name=entity_info[0],
                             entity_type=entity_info[1],
                             frequency=entity_info[2],
                             confidence=entity_info[3])
                
                # Get relationships
                cursor = conn.execute('''
                    SELECT target_entity_id, relationship_type, strength, context
                    FROM relationships WHERE source_entity_id = ?
                    UNION
                    SELECT source_entity_id, relationship_type, strength, context
                    FROM relationships WHERE target_entity_id = ?
                ''', (entity_id, entity_id))
                
                for row in cursor.fetchall():
                    related_id, rel_type, strength, context = row
                    next_entities.add(related_id)
                    
                    G.add_edge(entity_id, related_id,
                             relationship_type=rel_type,
                             strength=strength,
                             context=context)
            
            current_entities = next_entities - visited_entities
            
            if not current_entities:  # No more entities to explore
                break
        
        # Convert to JSON-serializable format
        nodes = []
        for node_id, data in G.nodes(data=True):
            nodes.append({
                'id': node_id,
                **data
            })
        
        edges = []
        for source, target, data in G.edges(data=True):
            edges.append({
                'source': source,
                'target': target,
                **data
            })
        
        # Calculate graph statistics
        stats = {
            'node_count': len(nodes),
            'edge_count': len(edges),
            'density': nx.density(G),
            'connected_components': nx.number_connected_components(G)
        }
        
        # Find central entities
        if len(nodes) > 1:
            centrality = nx.degree_centrality(G)
            central_entities = sorted(centrality.items(), key=lambda x: x[1], reverse=True)[:5]
            stats['central_entities'] = [{'entity_id': eid, 'centrality': score} 
                                       for eid, score in central_entities]
        
        return json.dumps({
            'success': True,
            'subgraph': {
                'nodes': nodes,
                'edges': edges
            },
            'statistics': stats,
            'max_depth': max_depth
        }, indent=2)
        
    except Exception as e:
        logger.error(f"Subgraph building failed: {e}")
        return json.dumps({'error': f'Subgraph building failed: {str(e)}'})
    finally:
        conn.close()

@mcp.tool()
def get_graph_statistics() -> str:
    """
    Get overall knowledge graph statistics.
    
    Returns:
        JSON with graph metrics and insights
    """
    conn = sqlite3.connect(db.db_path)
    try:
        # Basic counts
        cursor = conn.execute('SELECT COUNT(*) FROM entities')
        entity_count = cursor.fetchone()[0]
        
        cursor = conn.execute('SELECT COUNT(*) FROM relationships')
        relationship_count = cursor.fetchone()[0]
        
        # Entity types distribution
        cursor = conn.execute('''
            SELECT entity_type, COUNT(*) as count
            FROM entities
            GROUP BY entity_type
            ORDER BY count DESC
        ''')
        entity_types = [{'type': row[0], 'count': row[1]} for row in cursor.fetchall()]
        
        # Relationship types distribution
        cursor = conn.execute('''
            SELECT relationship_type, COUNT(*) as count
            FROM relationships
            GROUP BY relationship_type
            ORDER BY count DESC
        ''')
        relationship_types = [{'type': row[0], 'count': row[1]} for row in cursor.fetchall()]
        
        # Top entities by frequency
        cursor = conn.execute('''
            SELECT name, entity_type, frequency, confidence
            FROM entities
            ORDER BY frequency DESC
            LIMIT 10
        ''')
        top_entities = []
        for row in cursor.fetchall():
            top_entities.append({
                'name': row[0],
                'type': row[1],
                'frequency': row[2],
                'confidence': row[3]
            })
        
        # Most connected entities
        cursor = conn.execute('''
            SELECT e.id, e.name, e.entity_type, COUNT(*) as connection_count
            FROM entities e
            LEFT JOIN relationships r ON e.id = r.source_entity_id OR e.id = r.target_entity_id
            GROUP BY e.id, e.name, e.entity_type
            HAVING connection_count > 0
            ORDER BY connection_count DESC
            LIMIT 10
        ''')
        connected_entities = []
        for row in cursor.fetchall():
            connected_entities.append({
                'entity_id': row[0],
                'name': row[1],
                'type': row[2],
                'connections': row[3]
            })
        
        return json.dumps({
            'overview': {
                'total_entities': entity_count,
                'total_relationships': relationship_count,
                'graph_density': relationship_count / max(entity_count * (entity_count - 1) / 2, 1)
            },
            'entity_types': entity_types,
            'relationship_types': relationship_types,
            'top_entities_by_frequency': top_entities,
            'most_connected_entities': connected_entities
        }, indent=2)
        
    finally:
        conn.close()

if __name__ == "__main__":
    mcp.run()