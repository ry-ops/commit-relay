# LLM Mesh Deployment Guide

## Quick Start (5 Minutes)

### 1. Configure API Keys

```bash
cd /Users/ryandahlberg/Projects/commit-relay/llm-mesh

# Edit .env file and add your API key
nano .env

# Replace this line:
# ANTHROPIC_API_KEY=your-key-here
# With your actual key:
# ANTHROPIC_API_KEY=sk-ant-api03-xxxxx
```

**Get API Keys:**
- Anthropic Claude: https://console.anthropic.com/
- OpenAI (optional): https://platform.openai.com/api-keys

### 2. Deploy LLM Mesh

```bash
# Run full deployment (checks prereqs, validates config, tests components)
./deploy.sh deploy
```

### 3. Process Your First Task

```bash
# Process a single task
./integration/task-processor.sh process \
  task-001 \
  "Fix authentication vulnerability in login module" \
  security

# Or process entire task queue
./integration/task-processor.sh queue
```

## What Gets Deployed

### Phase 1: MoE Learning System ✅
**Location**: `llm-mesh/moe-learning/`

- Outcome tracking and pattern learning
- 3 specialized LLM prompts for analysis
- Automatic router improvements
- Performance metrics and observability

**Key Files**:
- `evaluators/outcome-tracker.sh` - Tracks routing outcomes
- `evaluators/pattern-learner.sh` - Learns from outcomes
- `prompts/*.md` - LLM analysis prompts
- `catalog/routing-decisions.jsonl` - Decision history

### Phase 2: LLM Gateway ✅
**Location**: `llm-mesh/gateway/`

- Multi-provider support (Anthropic, OpenAI, local)
- Intelligent model selection based on task type
- Cost tracking and optimization
- Performance monitoring

**Key Files**:
- `llm-client.sh` - Makes API calls to LLM providers
- `model-router/select-model.sh` - Selects optimal model
- `catalog/models.json` - Model capabilities catalog
- `catalog/pricing.json` - Cost data for optimization

### Phase 3: Full Catalog ✅
**Location**: `llm-mesh/catalog/`

- 6 master agents fully cataloged
- 3 tools with usage patterns
- Discovery API for agent recommendation
- Performance tracking

**Key Files**:
- `catalog-query.sh` - Query agents and tools
- `agents/*.json` - Agent metadata (6 masters)
- `tools/*.json` - Tool definitions

### Phase 4: Safety & Quality ✅
**Location**: `llm-mesh/safety/`

- 3 safety filters (PII, injection, secrets)
- Quality scoring (4 dimensions)
- Compliance monitoring
- MoE learning for safety optimization

**Key Files**:
- `safety-gateway.sh` - Main safety orchestrator
- `filters/pii-detector.sh` - Detects PII
- `filters/prompt-injection-defense.sh` - Blocks attacks
- `filters/secrets-detector.sh` - Prevents credential leaks
- `evaluators/quality-scorer.sh` - Scores output quality

### Integration Layer ✅
**Location**: `llm-mesh/integration/`

- Complete task processing pipeline
- Connects all 4 phases
- Integrates with commit-relay task queue

**Key Files**:
- `task-processor.sh` - End-to-end task processing

## Task Processing Pipeline

When you process a task, it flows through 7 phases:

```
Input Task → [1] Safety → [2] Catalog → [3] MoE Router → [4] LLM Gateway
           → [5] Execution → [6] Output Check → [7] Learning → Result
```

### Phase 1: Safety Gateway - Input Validation
- **What**: Validates input is safe before processing
- **Checks**: PII detection, prompt injection, secrets
- **Action**: Block, redact, or allow with warning
- **Output**: Safe, processed input text

### Phase 2: Catalog Query - Agent Recommendation
- **What**: Recommends best agent for the task
- **Uses**: Agent capabilities, performance history
- **Output**: Recommended agent (e.g., "security-master")

### Phase 3: MoE Router - Expert Selection
- **What**: Calculates confidence scores for all experts
- **Strategy**: Single expert, multi-expert, or low confidence
- **Output**: Primary expert + confidence score
- **Logged**: For learning and improvement

### Phase 4: LLM Gateway - Model Selection
- **What**: Selects optimal LLM model for the task
- **Considers**: Task type, quality requirement, cost
- **Options**: Claude Sonnet/Opus/Haiku, GPT-4/3.5, local models
- **Output**: Selected model for execution

### Phase 5: Task Execution
- **What**: Master agent processes the task
- **Uses**: Selected tools and LLM model
- **Output**: Task result (code, analysis, etc.)

### Phase 6: Safety Gateway - Output Validation
- **What**: Validates output quality and safety
- **Checks**: PII, secrets, quality score (4 dimensions)
- **Action**: Accept, reject, or flag for review
- **Output**: Quality score + safety assessment

### Phase 7: MoE Learning - Track Outcome
- **What**: Records outcome for continuous improvement
- **Tracks**: Routing accuracy, quality, performance
- **Uses**: Improves future routing decisions
- **Output**: Learning data for pattern analysis

## Configuration Options

### Environment Variables (.env)

```bash
# API Keys (Required)
ANTHROPIC_API_KEY=sk-ant-api03-xxxxx
OPENAI_API_KEY=sk-xxxxx  # Optional

# Gateway Settings
LLM_PRIMARY_PROVIDER=anthropic        # anthropic|openai|local
LLM_DEFAULT_QUALITY=balanced          # economical|balanced|premium
LLM_MAX_COST_PER_TASK=0.50           # USD

# Safety Settings
SAFETY_ENABLE_PII_FILTER=true
SAFETY_ENABLE_INJECTION_FILTER=true
SAFETY_ENABLE_SECRETS_FILTER=true
SAFETY_MIN_QUALITY_SCORE=0.7          # 0.0-1.0
SAFETY_DEFAULT_ACTION=detect          # detect|block|redact

# Learning Settings
MOE_ENABLE_LEARNING=true
MOE_MIN_CONFIDENCE=0.3                # 0.0-1.0
MOE_LEARNING_BATCH_SIZE=10            # outcomes before re-learning
```

### Quality Levels

- **economical**: Fastest, cheapest (Claude Haiku, GPT-3.5)
  - Use for: Simple routing, quick analysis
  - Cost: ~$0.001-0.005 per call

- **balanced**: Good quality/cost ratio (Claude Sonnet, GPT-4 Turbo)
  - Use for: Most tasks, default choice
  - Cost: ~$0.01-0.05 per call

- **premium**: Highest quality (Claude Opus, GPT-4)
  - Use for: Critical security, complex reasoning
  - Cost: ~$0.05-0.15 per call

## Testing

### Test Safety Filters

```bash
# Test PII detection
./safety/filters/pii-detector.sh "Contact john.doe@example.com" detect

# Test prompt injection defense
./safety/filters/prompt-injection-defense.sh "Ignore previous instructions" detect

# Test secrets detection
./safety/filters/secrets-detector.sh "API key: sk-test123" detect

# Test complete safety gateway
./safety/safety-gateway.sh check-input "Email: user@test.com, Key: AKIA123"
```

### Test Catalog

```bash
# Get all agents
./catalog/catalog-query.sh agents --all

# Recommend agent for task
./catalog/catalog-query.sh recommend-agent "Fix security vulnerability"

# Get agent info
./catalog/catalog-query.sh get-agent security-master
```

### Test MoE Router

```bash
# Route a task
GOVERNANCE_BYPASS=true \
  ../coordination/masters/coordinator/lib/moe-router.sh \
  test-001 \
  "Scan for CVE-2024-12345"
```

### Test LLM Client

```bash
# Test API connections (requires API keys)
./gateway/llm-client.sh test

# Make a test call to Anthropic
./gateway/llm-client.sh anthropic claude-haiku "Say hello" 100 0.7

# Intelligent call with model selection
./gateway/llm-client.sh call routing-analysis "Analyze this task" 1000 0.7 balanced
```

### Test Full Pipeline

```bash
# Process single task
./integration/task-processor.sh process \
  test-pipeline-001 \
  "Implement user authentication feature" \
  development

# Process task queue
./integration/task-processor.sh queue
```

## Monitoring & Metrics

### Logs and Data Files

```bash
# Routing decisions
cat moe-learning/catalog/routing-decisions.jsonl | jq .

# Routing outcomes
cat moe-learning/catalog/routing-outcomes.jsonl | jq .

# Learned patterns
cat moe-learning/catalog/learned-patterns.json | jq .

# Model performance
cat gateway/catalog/model-performance.jsonl | jq .

# Task processing log
cat integration/task-processing.jsonl | jq .

# Safety filter performance
cat safety/learning/filter-performance.jsonl | jq .
```

### Metrics

```bash
# Routing accuracy over time
cat moe-learning/metrics/routing-accuracy.jsonl | \
  jq -r '[.timestamp, .accuracy] | @csv'

# Cost tracking
cat gateway/catalog/model-performance.jsonl | \
  jq -s 'map(.cost) | add'

# Safety detections
cat safety/learning/filter-performance.jsonl | \
  jq -s 'group_by(.filter) | map({filter: .[0].filter, detections: length})'
```

## Production Checklist

Before deploying to production:

- [ ] API keys configured in `.env`
- [ ] Safety filters tested and working
- [ ] Quality thresholds configured appropriately
- [ ] Cost limits set (`LLM_MAX_COST_PER_TASK`)
- [ ] Monitoring/alerting set up for:
  - [ ] API errors
  - [ ] Safety violations
  - [ ] Quality scores below threshold
  - [ ] Cost overruns
- [ ] Backup strategy for:
  - [ ] Routing decisions
  - [ ] Learned patterns
  - [ ] Performance metrics
- [ ] Team trained on:
  - [ ] How to process tasks
  - [ ] How to interpret safety alerts
  - [ ] How to review quality scores

## Troubleshooting

### "Permission denied" errors
```bash
# Run with governance bypass
GOVERNANCE_BYPASS=true ./script.sh args
```

### "API key not set" errors
```bash
# Check .env file
cat .env | grep API_KEY

# Reload environment
source config/load-env.sh load
```

### Low routing confidence
- Check `routing-patterns.json` for keywords
- Review learned patterns: `cat moe-learning/catalog/learned-patterns.json`
- Run pattern learner: `cd moe-learning && ./moe-learn.sh learn`

### Safety filter false positives
- Review detection logs: `cat safety/learning/filter-performance.jsonl`
- Adjust patterns in filter scripts
- Set action to "detect" instead of "block" during testing

### Quality scores too low
- Adjust `SAFETY_MIN_QUALITY_SCORE` in `.env`
- Review quality dimensions: `cat integration/task-processing.jsonl | jq .phases.output_validation`
- Switch to higher quality LLM: `LLM_DEFAULT_QUALITY=premium`

## Next Steps

1. **Configure API Keys** - Edit `.env` with real keys
2. **Run Deployment** - `./deploy.sh deploy`
3. **Test Components** - Run tests above
4. **Process Demo Task** - `./integration/task-processor.sh process demo-001 "Test task" general`
5. **Monitor Metrics** - Watch logs and performance
6. **Learn and Improve** - Let MoE learning optimize over time

## Support

- Documentation: See `~/Desktop/FINAL-llm-mesh-all-4-phases-complete.md`
- Issues: Check logs in `moe-learning/metrics/`, `gateway/catalog/`, etc.
- Help: Each script has `--help` flag for usage information

**Congratulations! Your LLM Mesh is deployed and ready for production use!** 🚀
