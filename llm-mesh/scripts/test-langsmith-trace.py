#!/usr/bin/env python3
"""
Test LangSmith tracing with a simple LangChain operation.

This script demonstrates LangSmith tracing by executing a simple
LangChain chain that will appear in your LangSmith dashboard.
"""

import os
import sys
from pathlib import Path
from dotenv import load_dotenv

# Load environment variables
env_path = Path(__file__).parent.parent / '.env'
load_dotenv(env_path)

# Verify LangSmith is configured
if not os.getenv('LANGCHAIN_TRACING_V2') == 'true':
    print("⚠️  LANGCHAIN_TRACING_V2 is not enabled in .env")
    sys.exit(1)

if not os.getenv('LANGCHAIN_API_KEY') or os.getenv('LANGCHAIN_API_KEY') == 'your-langsmith-api-key-here':
    print("⚠️  LANGCHAIN_API_KEY is not set in .env")
    sys.exit(1)

print("=" * 80)
print("LangSmith Tracing Test")
print("=" * 80)
print()
print(f"✅ LangSmith tracing enabled")
print(f"✅ Project: {os.getenv('LANGCHAIN_PROJECT', 'default')}")
print(f"✅ API key configured")
print()

try:
    from langchain_core.prompts import PromptTemplate
    from langchain_community.llms.fake import FakeListLLM

    print("🧪 Creating a simple LangChain operation...")
    print()

    # Create a simple prompt template
    prompt = PromptTemplate(
        input_variables=["task"],
        template="Analyze this task and identify the best master to handle it:\n\nTask: {task}\n\nAnalysis:"
    )

    # Use a fake LLM for testing (no API calls needed)
    llm = FakeListLLM(
        responses=[
            "This appears to be a development task. The development-master would be best suited to handle implementation work like this.",
            "This is a security-related task. The security-master should handle vulnerability scanning and security audits.",
            "This is an inventory task. The inventory-master should handle documentation and cataloging."
        ]
    )

    # Create a chain using modern LCEL (LangChain Expression Language)
    chain = prompt | llm

    # Test with a few different tasks
    test_tasks = [
        "Implement new API endpoint for user authentication",
        "Scan repository for CVE-2024-12345 vulnerability",
        "Document all repositories with dependency versions"
    ]

    print("📊 Running test chains (these will appear in LangSmith):")
    print()

    for i, task in enumerate(test_tasks, 1):
        print(f"Test {i}: {task}")
        result = chain.invoke({"task": task})
        print(f"Result: {result[:100]}...")
        print()

    print("=" * 80)
    print("✅ Test completed successfully!")
    print()
    print("🌐 View traces in LangSmith:")
    print(f"   https://smith.langchain.com/")
    print()
    print("💡 What to look for:")
    print("   - 3 traces (one for each test task)")
    print("   - Each trace shows: input, prompt, LLM call, output")
    print("   - Execution time and metadata")
    print("=" * 80)

except ImportError as e:
    print(f"⚠️  Missing LangChain dependencies: {e}")
    print()
    print("Install with:")
    print("  source python-sdk/.venv/bin/activate")
    print("  pip install langchain langchain-community")
    sys.exit(1)
except Exception as e:
    print(f"❌ Error: {e}")
    import traceback
    traceback.print_exc()
    sys.exit(1)
