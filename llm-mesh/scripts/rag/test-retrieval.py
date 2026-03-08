#!/usr/bin/env python3
"""
Test RAG retrieval system with sample queries.

Demonstrates semantic search capabilities over the indexed codebase.
"""

import sys
from pathlib import Path
import argparse

# Add project root to path
project_root = Path(__file__).parent.parent.parent.parent
sys.path.insert(0, str(project_root))

# Import directly from files
rag_path = project_root / "llm-mesh" / "lib" / "rag"
sys.path.insert(0, str(rag_path))

from vectorstore import CodebaseVectorStore
from retriever import ContextRetriever


def test_retrieval(vectorstore_path: Path, query: str, n_results: int = 5):
    """
    Test retrieval with a query

    Args:
        vectorstore_path: Path to vector store
        query: Search query
        n_results: Number of results to return
    """
    print(f"🔍 Query: {query}")
    print(f"📁 Vector store: {vectorstore_path}\n")

    # Initialize vector store
    vectorstore = CodebaseVectorStore(
        persist_directory=vectorstore_path,
        collection_name="codebase"
    )

    # Show stats
    stats = vectorstore.get_stats()
    print(f"📊 Vector Store Stats:")
    print(f"  - Total chunks: {stats['total_chunks']}")
    print(f"  - Embedding model: {stats['embedding_model']}\n")

    # Initialize retriever
    retriever = ContextRetriever(vectorstore)

    # Get context
    context = retriever.get_context_for_task(
        task_description=query,
        n_results=n_results
    )

    # Display results
    print(f"📚 {context['context_summary']}\n")
    print("=" * 80)

    for i, item in enumerate(context['relevant_code'], 1):
        print(f"\n### Result {i}: {item['file']}")
        print(f"Lines: {item['lines']}")
        if item['relevance_score']:
            print(f"Relevance: {item['relevance_score']:.2%}")
        print("-" * 80)
        # Show first 10 lines of content
        lines = item['content'].split('\n')[:10]
        print('\n'.join(lines))
        if len(item['content'].split('\n')) > 10:
            print("...")

    # Test enhanced prompt
    print("\n" + "=" * 80)
    print("\n### Enhanced Prompt Example\n")
    base_prompt = "You are a development worker. Complete the following task:"
    enhanced = retriever.build_enhanced_prompt(
        base_prompt=base_prompt,
        task_description=query,
        n_context=3
    )
    print(enhanced[:800] + "..." if len(enhanced) > 800 else enhanced)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Test RAG retrieval system"
    )
    parser.add_argument(
        "--query",
        type=str,
        required=True,
        help="Search query"
    )
    parser.add_argument(
        "--vectorstore",
        type=Path,
        default=Path("llm-mesh/vectors/codebase"),
        help="Path to vector store"
    )
    parser.add_argument(
        "--n-results",
        type=int,
        default=5,
        help="Number of results to retrieve"
    )

    args = parser.parse_args()

    test_retrieval(
        vectorstore_path=args.vectorstore,
        query=args.query,
        n_results=args.n_results
    )
