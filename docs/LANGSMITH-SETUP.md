# LangSmith Integration Guide

This guide explains how to connect commit-relay to your LangSmith account for observability and monitoring of LangChain operations.

## What is LangSmith?

LangSmith is LangChain's observability and monitoring platform. It provides:

- **Tracing**: Track every LLM call, chain execution, and agent action
- **Evaluation**: Test and evaluate your LangChain applications
- **Monitoring**: Monitor production deployments with alerts
- **Debugging**: Drill down into traces to understand behavior
- **Datasets**: Create test sets for evaluation
- **Feedback**: Collect and analyze user feedback

## Quick Setup

### Step 1: Get Your LangSmith API Key

1. Go to https://smith.langchain.com/
2. Sign in or create an account
3. Navigate to Settings → API Keys
4. Create a new API key
5. Copy the API key (you won't see it again)

### Step 2: Configure Environment Variables

Edit `llm-mesh/.env` and add your LangSmith credentials:

```bash
# Enable LangChain tracing
LANGCHAIN_TRACING_V2=true

# Your LangSmith API key
LANGCHAIN_API_KEY=lsv2_pt_xxx...

# Project name (organizes traces)
LANGCHAIN_PROJECT=commit-relay
```

### Step 3: Install Dependencies

```bash
# Install langsmith package
pip install langsmith==0.0.77

# Or install all ML dependencies
pip install -r python-sdk/requirements-ml.txt
```

### Step 4: Test Connection

```bash
cd /Users/ryandahlberg/Projects/commit-relay
python llm-mesh/scripts/setup/test-langsmith.py
```

You should see:
```
✅ Successfully connected to LangSmith!
✅ LangSmith is properly configured!
```

## How It Works

Once configured, LangSmith automatically traces all LangChain operations:

1. **Automatic Tracing**: Every LangChain call sends trace data to LangSmith
2. **No Code Changes**: Works with existing LangChain code
3. **Environment-Based**: Enable/disable with `LANGCHAIN_TRACING_V2`
4. **Project Organization**: Group traces by project using `LANGCHAIN_PROJECT`

## Viewing Traces

### In LangSmith Dashboard

1. Go to https://smith.langchain.com/
2. Select your project (e.g., "commit-relay")
3. View traces in real-time as they execute
4. Click on a trace to see detailed breakdown

### What You'll See

For each traced operation:
- Input/output for each step
- Latency and token usage
- Chain/agent structure
- Errors and exceptions
- Model parameters

## Organizing Traces

### By Project

Set different projects for different environments:

```bash
# Development
LANGCHAIN_PROJECT=commit-relay-dev

# Staging
LANGCHAIN_PROJECT=commit-relay-staging

# Production
LANGCHAIN_PROJECT=commit-relay-prod
```

### By Component

You can also set project names programmatically:

```python
import os
os.environ["LANGCHAIN_PROJECT"] = "commit-relay-moe-routing"

# Your LangChain code here
```

## Advanced Features

### 1. Evaluation Datasets

Create test sets for your LangChain applications:

```python
from langsmith import Client

client = Client()

# Create dataset
dataset = client.create_dataset("routing-test-cases")

# Add examples
client.create_example(
    dataset_id=dataset.id,
    inputs={"task": "Fix authentication bug"},
    outputs={"master": "development-master"}
)
```

### 2. Feedback Collection

Track how well your chains perform:

```python
from langsmith import Client

client = Client()

# Add feedback to a trace
client.create_feedback(
    run_id="xxx",
    key="correctness",
    score=0.9
)
```

### 3. Monitoring & Alerts

In LangSmith dashboard:
1. Go to Monitoring → Alerts
2. Create alerts for:
   - High latency
   - Error rates
   - Token usage
   - Custom metrics

### 4. A/B Testing

Compare different routing strategies:

```python
# Strategy A
os.environ["LANGCHAIN_PROJECT"] = "routing-neural"
result_a = neural_router.route(task)

# Strategy B
os.environ["LANGCHAIN_PROJECT"] = "routing-ensemble"
result_b = ensemble_router.route(task)
```

Then compare in LangSmith dashboard.

## Integration with Commit-Relay

### Where Tracing Applies

LangSmith will trace these commit-relay components:

1. **RAG Retrieval** (`llm-mesh/lib/rag/`)
   - Vector store searches
   - Document retrieval
   - Context building

2. **Agent Chains** (future)
   - Worker agents
   - Chain-of-thought reasoning
   - Tool use

3. **LLM Calls** (if using LangChain wrappers)
   - Anthropic Claude
   - OpenAI GPT
   - Local models

### Example: Tracing RAG

```python
from llm_mesh.lib.rag.retriever import CodebaseRetriever

# This will automatically be traced in LangSmith
retriever = CodebaseRetriever()
results = retriever.retrieve("authentication implementation")

# View trace at https://smith.langchain.com/
```

## Best Practices

### 1. Use Descriptive Project Names

```bash
# Good
LANGCHAIN_PROJECT=commit-relay-moe-routing

# Not ideal
LANGCHAIN_PROJECT=test
```

### 2. Tag Important Runs

```python
from langchain.callbacks import tracing_v2_enabled

with tracing_v2_enabled(
    project_name="commit-relay",
    tags=["production", "high-priority"]
):
    result = chain.run(input)
```

### 3. Sample in Production

For high-volume production:

```python
import random

# Trace 10% of requests
if random.random() < 0.1:
    os.environ["LANGCHAIN_TRACING_V2"] = "true"
else:
    os.environ["LANGCHAIN_TRACING_V2"] = "false"
```

### 4. Secure Your API Key

```bash
# Never commit API keys
echo "llm-mesh/.env" >> .gitignore

# Use secure storage in production
# - AWS Secrets Manager
# - HashiCorp Vault
# - Kubernetes Secrets
```

## Troubleshooting

### Traces Not Appearing

1. Check environment variables:
   ```bash
   echo $LANGCHAIN_TRACING_V2
   echo $LANGCHAIN_API_KEY
   ```

2. Verify API key is valid:
   ```bash
   python llm-mesh/scripts/setup/test-langsmith.py
   ```

3. Check network connectivity:
   ```bash
   curl https://api.smith.langchain.com/
   ```

### Slow Performance

LangSmith tracing adds minimal overhead (~10-50ms per trace). If you notice slowness:

1. Ensure you're on the latest langsmith version
2. Check network latency to api.smith.langchain.com
3. Consider sampling (trace only X% of requests)

### Too Many Traces

LangSmith has rate limits based on your plan:

1. **Free Tier**: 5,000 traces/month
2. **Team Plan**: 50,000 traces/month
3. **Enterprise**: Custom limits

If you hit limits:
- Use sampling (trace 10% of requests)
- Archive old projects
- Upgrade your plan

## Resources

### Documentation
- [LangSmith Docs](https://docs.smith.langchain.com/)
- [LangChain Docs](https://python.langchain.com/)
- [Tracing Guide](https://docs.smith.langchain.com/tracing)

### Dashboard
- [LangSmith](https://smith.langchain.com/)
- [API Status](https://status.smith.langchain.com/)

### Support
- [LangChain Discord](https://discord.gg/langchain)
- [GitHub Issues](https://github.com/langchain-ai/langsmith-sdk)

## Next Steps

1. ✅ Set up LangSmith (you're here!)
2. 📊 Create evaluation datasets for routing accuracy
3. 🔍 Monitor RAG retrieval performance
4. 🧪 A/B test neural vs rule-based routing
5. 📈 Set up alerts for anomalies

---

**Need Help?** Run the test script or check LangSmith documentation.
