"""
Context retriever for enhancing worker prompts with relevant codebase context.
"""

from typing import List, Dict, Optional
from pathlib import Path

# Handle imports for both package and standalone use
try:
    from .vectorstore import CodebaseVectorStore
except ImportError:
    from vectorstore import CodebaseVectorStore


class ContextRetriever:
    """
    Retrieves relevant context for task execution

    Enhances worker agent prompts by finding similar code, documentation,
    and historical task patterns.
    """

    def __init__(self, vectorstore: CodebaseVectorStore):
        """
        Initialize context retriever

        Args:
            vectorstore: Initialized vector store
        """
        self.vectorstore = vectorstore

    def get_context_for_task(
        self,
        task_description: str,
        task_type: Optional[str] = None,
        n_results: int = 5
    ) -> Dict:
        """
        Retrieve relevant context for a task

        Args:
            task_description: Natural language task description
            task_type: Optional task type filter (code, docs, config)
            n_results: Number of context chunks to retrieve

        Returns:
            Dict with context chunks and metadata
        """
        # Build metadata filter
        filter_metadata = None
        if task_type:
            filter_metadata = {'type': task_type}

        # Search vector store
        results = self.vectorstore.search(
            query=task_description,
            n_results=n_results,
            filter_metadata=filter_metadata
        )

        # Format for worker consumption
        return {
            'task_description': task_description,
            'relevant_code': [
                {
                    'file': r['metadata']['file_path'],
                    'lines': f"{r['metadata']['start_line']}-{r['metadata']['end_line']}",
                    'content': r['text'],
                    'relevance_score': 1.0 - r['distance'] if r['distance'] else None
                }
                for r in results
            ],
            'context_summary': self._generate_summary(results)
        }

    def build_enhanced_prompt(
        self,
        base_prompt: str,
        task_description: str,
        n_context: int = 3
    ) -> str:
        """
        Build enhanced prompt with RAG context

        Args:
            base_prompt: Original worker prompt
            task_description: Task to find context for
            n_context: Number of context items to include

        Returns:
            Enhanced prompt with relevant context
        """
        context = self.get_context_for_task(task_description, n_results=n_context)

        # Build context section
        context_section = "\n## Relevant Codebase Context\n\n"

        for i, item in enumerate(context['relevant_code'], 1):
            context_section += f"### Context {i}: {item['file']}\n"
            context_section += f"Lines {item['lines']}\n"
            context_section += f"```\n{item['content']}\n```\n\n"

        # Insert context before task description
        enhanced_prompt = f"{base_prompt}\n\n{context_section}\n## Task\n{task_description}"

        return enhanced_prompt

    def _generate_summary(self, results: List[Dict]) -> str:
        """Generate a summary of retrieved context"""
        if not results:
            return "No relevant context found."

        files = set(r['metadata']['file_path'] for r in results)
        return f"Found {len(results)} relevant code chunks across {len(files)} files."
