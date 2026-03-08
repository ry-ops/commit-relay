"""
Vector store for codebase semantic search.

Uses FAISS for efficient similarity search over code chunks.
"""

import faiss
import numpy as np
import pickle
from pathlib import Path
from typing import List, Dict, Optional
from sentence_transformers import SentenceTransformer


class CodebaseVectorStore:
    """
    Vector store for semantic search over codebase

    Stores code chunks with metadata for retrieval by workers during
    task execution. Enables context-aware agent behavior.
    """

    def __init__(
        self,
        persist_directory: Path,
        collection_name: str = "codebase",
        embedding_model: str = "all-MiniLM-L6-v2"
    ):
        """
        Initialize vector store

        Args:
            persist_directory: Where to store the vector database
            collection_name: Name of the collection
            embedding_model: Sentence transformer model for embeddings
        """
        self.persist_directory = Path(persist_directory)
        self.persist_directory.mkdir(parents=True, exist_ok=True)
        self.collection_name = collection_name
        self.embedding_model_name = embedding_model

        # Initialize embedding model
        print(f"Loading embedding model: {embedding_model}")
        self.embedding_model = SentenceTransformer(embedding_model)
        self.dimension = self.embedding_model.get_sentence_embedding_dimension()

        # Initialize FAISS index
        self.index_path = self.persist_directory / f"{collection_name}.index"
        self.metadata_path = self.persist_directory / f"{collection_name}.metadata.pkl"

        if self.index_path.exists():
            # Load existing index
            self.index = faiss.read_index(str(self.index_path))
            with open(self.metadata_path, 'rb') as f:
                self.metadata = pickle.load(f)
        else:
            # Create new index
            self.index = faiss.IndexFlatL2(self.dimension)
            self.metadata = []

    def add_code_chunks(
        self,
        chunks: List[Dict[str, str]],
        batch_size: int = 100
    ):
        """
        Add code chunks to vector store

        Args:
            chunks: List of dicts with 'text', 'file_path', 'start_line', 'end_line'
            batch_size: Batch size for embedding
        """
        for i in range(0, len(chunks), batch_size):
            batch = chunks[i:i + batch_size]

            # Extract text for embedding
            texts = [chunk['text'] for chunk in batch]

            # Generate embeddings
            embeddings = self.embedding_model.encode(texts, show_progress_bar=True)

            # Add to index
            self.index.add(np.array(embeddings).astype('float32'))

            # Store metadata
            for chunk in batch:
                self.metadata.append({
                    'text': chunk['text'],
                    'file_path': chunk['file_path'],
                    'start_line': chunk.get('start_line', 0),
                    'end_line': chunk.get('end_line', 0),
                    'type': chunk.get('type', 'code')
                })

    def search(
        self,
        query: str,
        n_results: int = 5,
        filter_metadata: Optional[Dict] = None
    ) -> List[Dict]:
        """
        Search for relevant code chunks

        Args:
            query: Search query (natural language or code)
            n_results: Number of results to return
            filter_metadata: Optional metadata filters (basic support)

        Returns:
            List of search results with text, metadata, and similarity scores
        """
        # Generate query embedding
        query_embedding = self.embedding_model.encode([query])

        # Search index
        distances, indices = self.index.search(
            np.array(query_embedding).astype('float32'),
            min(n_results, self.index.ntotal)
        )

        # Format results
        formatted_results = []
        for i, idx in enumerate(indices[0]):
            if idx < len(self.metadata):
                result = {
                    'text': self.metadata[idx]['text'],
                    'metadata': {
                        'file_path': self.metadata[idx]['file_path'],
                        'start_line': str(self.metadata[idx]['start_line']),
                        'end_line': str(self.metadata[idx]['end_line']),
                        'type': self.metadata[idx]['type']
                    },
                    'distance': float(distances[0][i])
                }

                # Apply metadata filter if provided
                if filter_metadata:
                    if all(result['metadata'].get(k) == v for k, v in filter_metadata.items()):
                        formatted_results.append(result)
                else:
                    formatted_results.append(result)

        return formatted_results

    def get_stats(self) -> Dict:
        """Get statistics about the vector store"""
        return {
            'total_chunks': self.index.ntotal,
            'collection_name': self.collection_name,
            'embedding_model': self.embedding_model_name,
            'dimension': self.dimension
        }

    def persist(self):
        """Persist the vector store to disk"""
        faiss.write_index(self.index, str(self.index_path))
        with open(self.metadata_path, 'wb') as f:
            pickle.dump(self.metadata, f)
        print(f"✅ Vector store saved to {self.persist_directory}")
