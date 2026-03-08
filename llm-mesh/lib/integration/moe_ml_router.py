"""
ML-Enhanced MoE Router Integration

Combines traditional rule-based routing with neural routing for improved
task-to-master assignment.
"""

import json
import sys
from pathlib import Path
from typing import Dict, Optional, Tuple
import subprocess

# Handle imports for both package and standalone use
try:
    from ..routing.neural_router import NeuralRouter, EnsembleRouter
    from ..rag.vectorstore import CodebaseVectorStore
    from ..rag.retriever import ContextRetriever
except ImportError:
    sys.path.insert(0, str(Path(__file__).parent.parent))
    try:
        from routing.neural_router import NeuralRouter, EnsembleRouter
        from rag.vectorstore import CodebaseVectorStore
        from rag.retriever import ContextRetriever
    except ImportError:
        # Fallback - ML not available, use rule-based only
        NeuralRouter = None
        EnsembleRouter = None
        CodebaseVectorStore = None
        ContextRetriever = None


class MLEnhancedRouter:
    """
    ML-enhanced router for MoE system

    Provides both neural routing and RAG-enhanced context for workers.
    Falls back to rule-based routing if ML components unavailable.
    """

    def __init__(
        self,
        model_path: Optional[Path] = None,
        vectorstore_path: Optional[Path] = None,
        enable_neural: bool = True,
        enable_rag: bool = True,
        ab_test_percentage: float = 0.0
    ):
        """
        Initialize ML-enhanced router

        Args:
            model_path: Path to trained neural router model
            vectorstore_path: Path to vector store for RAG
            enable_neural: Enable neural routing
            enable_rag: Enable RAG context retrieval
            ab_test_percentage: Percentage of traffic for ML routing (0-1)
        """
        self.enable_neural = enable_neural and NeuralRouter is not None
        self.enable_rag = enable_rag and CodebaseVectorStore is not None
        self.ab_test_percentage = ab_test_percentage

        # Initialize neural router if enabled
        self.neural_router = None
        if self.enable_neural:
            try:
                self.neural_router = NeuralRouter(model_path=model_path)
                print(f"✅ Neural router initialized", file=sys.stderr)
            except Exception as e:
                print(f"⚠️  Neural router failed to initialize: {e}", file=sys.stderr)
                self.enable_neural = False

        # Initialize RAG if enabled
        self.vectorstore = None
        self.retriever = None
        if self.enable_rag and vectorstore_path and vectorstore_path.exists():
            try:
                self.vectorstore = CodebaseVectorStore(
                    persist_directory=vectorstore_path,
                    collection_name="codebase"
                )
                self.retriever = ContextRetriever(self.vectorstore)
                print(f"✅ RAG system initialized", file=sys.stderr)
            except Exception as e:
                print(f"⚠️  RAG failed to initialize: {e}", file=sys.stderr)
                self.enable_rag = False

    def route_task(
        self,
        task_description: str,
        task_metadata: Optional[Dict] = None,
        use_ml: Optional[bool] = None
    ) -> Dict:
        """
        Route task to optimal master

        Args:
            task_description: Natural language task description
            task_metadata: Optional task metadata
            use_ml: Force ML routing (overrides A/B test)

        Returns:
            Dict with routing decision and metadata
        """
        # Determine if ML should be used
        should_use_ml = use_ml if use_ml is not None else self._should_use_ml()

        if should_use_ml and self.enable_neural:
            return self._ml_route(task_description, task_metadata)
        else:
            return self._rule_based_route(task_description, task_metadata)

    def get_enhanced_context(
        self,
        task_description: str,
        n_results: int = 5
    ) -> Optional[Dict]:
        """
        Get RAG-enhanced context for task

        Args:
            task_description: Task description
            n_results: Number of context items to retrieve

        Returns:
            Context dict or None if RAG disabled
        """
        if not self.enable_rag or not self.retriever:
            return None

        try:
            return self.retriever.get_context_for_task(
                task_description=task_description,
                n_results=n_results
            )
        except Exception as e:
            print(f"⚠️  RAG context retrieval failed: {e}", file=sys.stderr)
            return None

    def _should_use_ml(self) -> bool:
        """Determine if ML should be used based on A/B test percentage"""
        if self.ab_test_percentage <= 0:
            return False
        if self.ab_test_percentage >= 1.0:
            return True

        # Simple hash-based A/B test (deterministic per task)
        import random
        return random.random() < self.ab_test_percentage

    def _ml_route(
        self,
        task_description: str,
        task_metadata: Optional[Dict]
    ) -> Dict:
        """ML-based routing using neural router"""
        try:
            # For now, use rule-based routing since we don't have a trained model
            # TODO: Implement actual neural routing once model is trained
            print("⚠️  Neural routing not yet implemented, falling back to rules", file=sys.stderr)
            return self._rule_based_route(task_description, task_metadata)
        except Exception as e:
            print(f"⚠️  ML routing failed: {e}, falling back to rules", file=sys.stderr)
            return self._rule_based_route(task_description, task_metadata)

    def _rule_based_route(
        self,
        task_description: str,
        task_metadata: Optional[Dict]
    ) -> Dict:
        """Traditional rule-based routing"""
        desc_lower = task_description.lower()

        # Pattern matching for keywords
        if any(word in desc_lower for word in ["security", "vulnerability", "cve", "audit", "scan"]):
            master = "security-master"
            rule = "security-keywords"
        elif any(word in desc_lower for word in ["build", "deploy", "ci/cd", "pipeline", "test"]):
            master = "cicd-master"
            rule = "cicd-keywords"
        elif any(word in desc_lower for word in ["document", "catalog", "inventory", "dependency"]):
            master = "inventory-master"
            rule = "inventory-keywords"
        elif any(word in desc_lower for word in ["fix", "bug", "implement", "feature", "refactor"]):
            master = "development-master"
            rule = "development-keywords"
        else:
            master = "coordinator-master"
            rule = "fallback"

        return {
            "selected_master": master,
            "routing_method": "rule-based",
            "rule_used": rule,
            "confidence": 0.8 if rule != "fallback" else 0.5,
            "task_description": task_description
        }

    def get_stats(self) -> Dict:
        """Get router statistics"""
        return {
            "neural_enabled": self.enable_neural,
            "rag_enabled": self.enable_rag,
            "ab_test_percentage": self.ab_test_percentage,
            "vectorstore_stats": self.vectorstore.get_stats() if self.vectorstore else None
        }
