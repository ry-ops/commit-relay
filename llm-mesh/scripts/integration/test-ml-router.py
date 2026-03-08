#!/usr/bin/env python3
"""
Test ML-enhanced router integration.

Verifies routing decisions and RAG context retrieval.
"""

import sys
from pathlib import Path
import json

# Add project root to path
project_root = Path(__file__).parent.parent.parent.parent
sys.path.insert(0, str(project_root))

# Import integration module
integration_path = project_root / "llm-mesh" / "lib" / "integration"
sys.path.insert(0, str(integration_path))

from moe_ml_router import MLEnhancedRouter


def test_routing():
    """Test routing decisions"""
    print("🧪 Testing ML-Enhanced Router")
    print("=" * 80)

    # Initialize router
    vectorstore_path = project_root / "llm-mesh" / "vectors" / "codebase-test"

    router = MLEnhancedRouter(
        vectorstore_path=vectorstore_path,
        enable_neural=False,  # Neural not trained yet
        enable_rag=True,
        ab_test_percentage=0.0  # Use rule-based for testing
    )

    # Test cases
    test_cases = [
        "Fix authentication bug in login system",
        "Scan repository for CVE-2024-12345 vulnerability",
        "Document all API endpoints and dependencies",
        "Deploy new feature to production with CI/CD",
        "Implement user registration with validation",
    ]

    print(f"\n📊 Router Stats:")
    stats = router.get_stats()
    print(json.dumps(stats, indent=2))

    print(f"\n🎯 Test Routing Decisions:")
    print("-" * 80)

    for task in test_cases:
        print(f"\nTask: {task}")

        # Get routing decision
        decision = router.route_task(task)
        print(f"  → Master: {decision['selected_master']}")
        print(f"  → Method: {decision['routing_method']}")
        print(f"  → Rule: {decision['rule_used']}")
        print(f"  → Confidence: {decision['confidence']:.2%}")

        # Get RAG context
        if router.enable_rag:
            context = router.get_enhanced_context(task, n_results=2)
            if context and context['relevant_code']:
                print(f"  → RAG Context: {len(context['relevant_code'])} relevant chunks found")
                for i, item in enumerate(context['relevant_code'][:1], 1):
                    print(f"    {i}. {item['file']} (lines {item['lines']})")


if __name__ == "__main__":
    test_routing()
