#!/usr/bin/env python3
"""
Test LangSmith connection and tracing.

This script verifies that LangSmith is properly configured and can receive traces.
"""

import os
import sys
from pathlib import Path
from dotenv import load_dotenv

# Load environment variables from llm-mesh/.env
env_path = Path(__file__).parent.parent.parent / '.env'
load_dotenv(env_path)


def check_environment():
    """Check if required environment variables are set"""
    print("🔍 Checking LangSmith environment variables...\n")

    required_vars = {
        'LANGCHAIN_TRACING_V2': os.getenv('LANGCHAIN_TRACING_V2'),
        'LANGCHAIN_API_KEY': os.getenv('LANGCHAIN_API_KEY'),
        'LANGCHAIN_PROJECT': os.getenv('LANGCHAIN_PROJECT', 'default')
    }

    all_set = True
    for var, value in required_vars.items():
        if value and value != 'your-langsmith-api-key-here':
            print(f"✅ {var}: {value[:20]}..." if len(str(value)) > 20 else f"✅ {var}: {value}")
        else:
            print(f"❌ {var}: Not set or using placeholder")
            all_set = False

    print()
    return all_set


def test_langsmith_connection():
    """Test connection to LangSmith"""
    try:
        from langsmith import Client

        print("🔌 Testing LangSmith connection...\n")
        client = Client()

        # Test connection by listing projects
        projects = client.list_projects()
        print(f"✅ Successfully connected to LangSmith!")
        print(f"📊 Found {len(list(projects))} project(s)\n")

        return True
    except Exception as e:
        print(f"❌ Failed to connect to LangSmith: {e}\n")
        return False


def test_tracing():
    """Test LangChain tracing to LangSmith"""
    try:
        from langchain.chat_models import ChatOpenAI
        from langchain.schema import HumanMessage

        print("🧪 Testing LangChain tracing...\n")

        # Check if we have OpenAI key for testing
        if not os.getenv('OPENAI_API_KEY') or os.getenv('OPENAI_API_KEY') == 'your-key-here-optional':
            print("⚠️  OpenAI API key not set. Skipping trace test.")
            print("   Set OPENAI_API_KEY to test full tracing.\n")
            return True

        # Create a simple chain and invoke it
        llm = ChatOpenAI(temperature=0)
        response = llm.invoke([HumanMessage(content="Say 'LangSmith test successful'")])

        print(f"✅ Trace test completed!")
        print(f"📝 Response: {response.content}")
        print(f"\n🌐 View trace at: https://smith.langchain.com/\n")

        return True
    except ImportError:
        print("⚠️  LangChain ChatOpenAI not available. Skipping trace test.\n")
        return True
    except Exception as e:
        print(f"❌ Trace test failed: {e}\n")
        return False


def main():
    """Run all LangSmith tests"""
    print("=" * 60)
    print("LangSmith Connection Test")
    print("=" * 60)
    print()

    # Check environment variables
    env_ok = check_environment()
    if not env_ok:
        print("⚠️  Please configure LangSmith environment variables in llm-mesh/.env")
        print("\nSteps to configure:")
        print("1. Go to https://smith.langchain.com/settings")
        print("2. Create an API key")
        print("3. Add it to llm-mesh/.env as LANGCHAIN_API_KEY")
        print("4. Set LANGCHAIN_TRACING_V2=true")
        print("5. Set LANGCHAIN_PROJECT=commit-relay (or your preferred project name)")
        sys.exit(1)

    # Test connection
    connection_ok = test_langsmith_connection()
    if not connection_ok:
        print("⚠️  Could not connect to LangSmith. Check your API key.")
        sys.exit(1)

    # Test tracing
    trace_ok = test_tracing()

    # Summary
    print("=" * 60)
    if env_ok and connection_ok:
        print("✅ LangSmith is properly configured!")
        print("\nNext steps:")
        print("- Run your LangChain applications")
        print("- View traces at https://smith.langchain.com/")
        print("- Create datasets for evaluation")
        print("- Set up monitoring and alerts")
    else:
        print("⚠️  Some tests failed. Please review the errors above.")
    print("=" * 60)


if __name__ == '__main__':
    main()
