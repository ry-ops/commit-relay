#!/usr/bin/env python3
"""
Create vector store from codebase for RAG-enhanced workers.

This script indexes the codebase into a vector database for semantic search.
"""

import sys
from pathlib import Path
import argparse

# Add project root to path
project_root = Path(__file__).parent.parent.parent.parent
sys.path.insert(0, str(project_root))

# Import directly from file
rag_path = project_root / "llm-mesh" / "lib" / "rag"
sys.path.insert(0, str(rag_path))

from vectorstore import CodebaseVectorStore


def chunk_file(file_path: Path, chunk_size: int = 1000) -> list:
    """
    Split file into chunks for embedding

    Args:
        file_path: Path to file
        chunk_size: Maximum lines per chunk

    Returns:
        List of chunks with metadata
    """
    chunks = []

    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            lines = f.readlines()

        # Chunk by size
        for i in range(0, len(lines), chunk_size):
            chunk_lines = lines[i:i + chunk_size]
            chunk_text = ''.join(chunk_lines)

            chunks.append({
                'text': chunk_text,
                'file_path': str(file_path),
                'start_line': i + 1,
                'end_line': min(i + chunk_size, len(lines)),
                'type': _determine_file_type(file_path)
            })

    except Exception as e:
        print(f"⚠️  Error reading {file_path}: {e}")

    return chunks


def _determine_file_type(file_path: Path) -> str:
    """Determine file type from extension"""
    ext = file_path.suffix.lower()

    if ext in ['.md', '.txt', '.rst']:
        return 'documentation'
    elif ext in ['.json', '.yaml', '.yml', '.toml', '.ini']:
        return 'config'
    elif ext in ['.sh', '.bash', '.py', '.js', '.ts', '.go', '.rs']:
        return 'code'
    else:
        return 'other'


def should_index_file(file_path: Path) -> bool:
    """
    Check if file should be indexed

    Args:
        file_path: Path to check

    Returns:
        True if file should be indexed
    """
    # Skip common exclusions
    exclude_patterns = [
        'node_modules',
        '.git',
        '__pycache__',
        '.venv',
        'venv',
        '.pytest_cache',
        '.mypy_cache',
        'dist',
        'build',
        '.DS_Store',
        'coordination/history',  # Skip large history files
        'coordination/metrics',  # Skip metrics
        '.parquet',              # Skip binary files
        '.json',                 # Skip JSON (can add back selectively)
    ]

    path_str = str(file_path)
    if any(pattern in path_str for pattern in exclude_patterns):
        return False

    # Only index text-based files
    valid_extensions = [
        '.sh', '.bash', '.py', '.js', '.ts', '.go', '.rs',  # Code
        '.md', '.txt', '.rst',                               # Docs
        '.yaml', '.yml', '.toml'                             # Config
    ]

    return file_path.suffix.lower() in valid_extensions


def create_vectorstore(
    source_dir: Path,
    output_dir: Path,
    chunk_size: int = 1000
):
    """
    Create vector store from codebase

    Args:
        source_dir: Root directory to index
        output_dir: Where to store vector database
        chunk_size: Lines per chunk
    """
    print(f"📚 Indexing codebase from: {source_dir}")
    print(f"💾 Vector store will be saved to: {output_dir}")

    # Initialize vector store
    vectorstore = CodebaseVectorStore(
        persist_directory=output_dir,
        collection_name="codebase"
    )

    # Collect all files
    all_chunks = []
    file_count = 0

    for file_path in source_dir.rglob('*'):
        if file_path.is_file() and should_index_file(file_path):
            file_count += 1
            chunks = chunk_file(file_path, chunk_size)
            all_chunks.extend(chunks)

            if file_count % 10 == 0:
                print(f"  Processed {file_count} files, {len(all_chunks)} chunks...")

    print(f"\n📊 Total files processed: {file_count}")
    print(f"📊 Total chunks created: {len(all_chunks)}")

    # Add to vector store
    if all_chunks:
        print("\n🔄 Adding chunks to vector store...")
        vectorstore.add_code_chunks(all_chunks)
        vectorstore.persist()
        print("✅ Vector store created successfully!")

        # Show stats
        stats = vectorstore.get_stats()
        print(f"\n📈 Vector Store Statistics:")
        print(f"  - Collection: {stats['collection_name']}")
        print(f"  - Total chunks: {stats['total_chunks']}")
        print(f"  - Embedding model: {stats['embedding_model']}")
    else:
        print("⚠️  No files found to index!")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Create vector store from codebase for RAG"
    )
    parser.add_argument(
        "--source",
        type=Path,
        default=Path.cwd(),
        help="Source directory to index (default: current directory)"
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("llm-mesh/vectors/codebase"),
        help="Output directory for vector store"
    )
    parser.add_argument(
        "--chunk-size",
        type=int,
        default=1000,
        help="Lines per chunk (default: 1000)"
    )

    args = parser.parse_args()

    create_vectorstore(
        source_dir=args.source,
        output_dir=args.output,
        chunk_size=args.chunk_size
    )
