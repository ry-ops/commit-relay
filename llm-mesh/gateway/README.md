# LLM Gateway - Multi-Provider Abstraction Layer

## Overview

The LLM Gateway provides a unified interface for accessing multiple LLM providers, with built-in token tracking, cost optimization, and MoE-based model selection.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     Application Layer                           │
│  (MoE Pattern Learner, Router Improver, Task Analysis)          │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         ↓
┌─────────────────────────────────────────────────────────────────┐
│                    LLM Gateway (llm-call.sh)                    │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  Model Router (MoE Learning)                             │  │
│  │  - Task type → best model selection                      │  │
│  │  - Cost vs quality optimization                          │  │
│  │  - Provider failover                                     │  │
│  └──────────────────────────────────────────────────────────┘  │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  Token & Cost Tracker                                    │  │
│  │  - Usage per task/expert/model                           │  │
│  │  - Cost calculation                                      │  │
│  │  - Budget enforcement                                    │  │
│  └──────────────────────────────────────────────────────────┘  │
└────────────┬──────────────┬──────────────┬─────────────────────┘
             │              │              │
             ↓              ↓              ↓
    ┌────────────┐  ┌────────────┐  ┌────────────┐
    │ Anthropic  │  │  OpenAI    │  │   Local    │
    │  Provider  │  │  Provider  │  │  Provider  │
    └────────────┘  └────────────┘  └────────────┘
         │              │              │
         ↓              ↓              ↓
    Claude API     OpenAI API     Ollama/LMStudio
```

## Key Features

### 1. Multi-Provider Support
- **Anthropic**: Claude models (Opus, Sonnet, Haiku)
- **OpenAI**: GPT models (GPT-4, GPT-3.5)
- **Local**: Ollama, LM Studio, custom endpoints

### 2. Token & Cost Tracking
- Usage per task type
- Usage per expert
- Usage per model
- Cost calculation with current pricing
- Budget alerts

### 3. Model Selection with MoE Learning
- Learn which model works best for which task
- Optimize cost vs. quality tradeoffs
- Automatic failover if provider unavailable
- A/B testing for model comparison

### 4. LLM Mesh Integration
- Catalog of available models
- Versioned prompts per model
- Performance metrics
- Quality evaluation

## Directory Structure

```
llm-mesh/gateway/
├── llm-call.sh                  # Main gateway interface
├── providers/
│   ├── anthropic.sh             # Anthropic provider
│   ├── openai.sh                # OpenAI provider
│   └── local.sh                 # Local model provider
├── catalog/
│   ├── models.json              # Available models catalog
│   ├── pricing.json             # Provider pricing
│   └── model-performance.jsonl  # Performance tracking
├── tracking/
│   ├── token-usage.jsonl        # Token consumption
│   ├── cost-tracking.jsonl      # Cost per task/expert
│   └── model-selection.jsonl    # Which model was chosen
├── model-router/
│   ├── select-model.sh          # MoE-based model selection
│   └── learned-preferences.json # Learned model preferences
└── schemas/
    ├── llm-request.json         # Request schema
    ├── llm-response.json        # Response schema
    └── model-performance.json   # Performance tracking schema
```

## Usage

### Basic Call

```bash
# Simple call with auto model selection
./gateway/llm-call.sh \
  --prompt "Analyze this routing decision..." \
  --task-type "routing-analysis" \
  --max-tokens 1000

# Explicit model selection
./gateway/llm-call.sh \
  --model "claude-sonnet-4" \
  --prompt "Generate improvement suggestions..." \
  --task-type "improvement-generation"

# With cost limit
./gateway/llm-call.sh \
  --prompt "..." \
  --task-type "pattern-extraction" \
  --max-cost 0.05  # Max $0.05 per call
```

### Integration with Phase 1

```bash
# Pattern learner uses gateway
./moe-learning/evaluators/pattern-learner.sh learn
# → Gateway selects best model for analysis
# → Tracks tokens and costs
# → Learns from performance

# Router improver uses gateway
./moe-learning/evaluators/router-improver.sh suggest
# → Gateway chooses cost-effective model
# → Records which model worked best
# → Improves model selection over time
```

## Model Selection Strategy

The gateway uses MoE learning to select models:

1. **Task Type Analysis**: Extract task characteristics
2. **Model Matching**: Find models good at this task type
3. **Cost Optimization**: Consider budget constraints
4. **Performance History**: Use past performance data
5. **Selection**: Choose optimal model
6. **Track Outcome**: Record performance for learning

### Example Decision Flow

```
Task: "Analyze routing quality"
  ↓
Task Type: routing-analysis
  ↓
Requirements: analytical, structured output
  ↓
Budget: $0.10 max
  ↓
Historical Data:
  - claude-sonnet-4: 95% quality, $0.08 avg
  - gpt-4: 92% quality, $0.12 avg
  - claude-haiku: 85% quality, $0.02 avg
  ↓
Selection: claude-sonnet-4
  (Best quality within budget)
  ↓
Track: tokens, cost, quality, latency
  ↓
Learn: Update model-performance data
```

## Cost Optimization

### Automatic Model Selection

The gateway learns cost/quality tradeoffs:

- **High-stakes analysis** → Claude Opus (best quality)
- **Routine analysis** → Claude Sonnet (balanced)
- **Simple extraction** → Claude Haiku (fast & cheap)
- **Budget constrained** → Local models (free)

### Budget Enforcement

```bash
# Set daily budget
export LLM_GATEWAY_DAILY_BUDGET=10.00  # $10/day

# Gateway will:
# - Track spend in cost-tracking.jsonl
# - Switch to cheaper models near budget limit
# - Reject requests if budget exceeded
# - Alert when 80% budget consumed
```

## Token Tracking

Every LLM call is tracked:

```jsonl
{
  "timestamp": "2025-11-15T13:00:00-0600",
  "task_type": "routing-analysis",
  "expert": "pattern-learner",
  "model": "claude-sonnet-4",
  "provider": "anthropic",
  "tokens": {
    "input": 1500,
    "output": 800,
    "total": 2300
  },
  "cost": 0.0345,
  "latency_ms": 2100,
  "quality_score": 0.95
}
```

## Model Performance Tracking

Learn which models excel at which tasks:

```json
{
  "model": "claude-sonnet-4",
  "task_type": "routing-analysis",
  "performance": {
    "total_calls": 50,
    "avg_quality": 0.94,
    "avg_cost": 0.082,
    "avg_latency_ms": 2200,
    "success_rate": 0.98
  },
  "optimal_for": ["routing-analysis", "pattern-extraction", "improvement-generation"],
  "not_recommended_for": ["simple-extraction"]
}
```

## Provider Configuration

### Anthropic

```bash
export ANTHROPIC_API_KEY="sk-ant-..."
export ANTHROPIC_BASE_URL="https://api.anthropic.com"  # Optional
```

### OpenAI

```bash
export OPENAI_API_KEY="sk-..."
export OPENAI_BASE_URL="https://api.openai.com"  # Optional
```

### Local Models

```bash
export LOCAL_MODEL_URL="http://localhost:11434"  # Ollama
export LOCAL_MODEL_NAME="llama2"
```

## MoE Learning Integration

The gateway feeds data back to MoE learning:

1. **Track**: Every LLM call tracked with outcome
2. **Analyze**: Pattern learner analyzes which models work best
3. **Learn**: Model router learns preferences
4. **Improve**: Model selection gets better over time
5. **Optimize**: Costs decrease while quality maintains

### Learning Cycle

```
Week 1: Try various models
  → Track: quality, cost, latency

Week 2: Learn patterns
  → Discovery: Sonnet best for analysis
  → Discovery: Haiku sufficient for extraction

Week 3: Apply learnings
  → Route: analysis → Sonnet
  → Route: extraction → Haiku

Week 4: Measure impact
  → Result: 40% cost reduction
  → Result: Same quality maintained
```

## Next Steps

1. Implement provider abstractions
2. Build token/cost tracking
3. Create model selection router
4. Integrate with Phase 1 learning
5. Test with real LLM calls
6. Measure cost savings
