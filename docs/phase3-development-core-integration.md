# Phase 3 Development Core Capabilities - Integration Guide

This document provides integration notes for the Phase 3 Development Core Capabilities implemented in commit-relay.

## Overview

Phase 3 adds 13 core development capabilities across 5 categories:
- Goal & Task Management (Items 23-25)
- Automation & Risk (Items 27, 29)
- API (Items 31-32)
- RAG Optimization (Items 35-36)
- Verification (Items 37-38)

---

## Goal & Task Management

### Item 23: Goal Decomposition with Verification

**Location**: `/Users/ryandahlberg/commit-relay/scripts/lib/worker-spec-builder.sh`

**New Functions**:
- `build_checkpoint_criteria()` - Create checkpoint criteria for a step
- `validate_checkpoint()` - Validate a checkpoint between steps
- `get_checkpoints()` - Get all checkpoints for a spec

**Usage**:
```bash
source "$COMMIT_RELAY_HOME/scripts/lib/worker-spec-builder.sh"

# Build checkpoint criteria
checkpoint=$(build_checkpoint_criteria \
    "compile-code" \
    "command_success" \
    "npm run build" \
    300 \
    "true")

# Build worker spec with checkpoints
build_worker_spec \
    --worker-id "worker-impl-001" \
    --worker-type "implementation-worker" \
    --task-id "task-123" \
    --checkpoint-criteria "[$checkpoint]" \
    --output "/path/to/spec.json"

# Validate checkpoint
validate_checkpoint "/path/to/spec.json" "compile-code"
```

**Verification Types**:
- `file_exists` - Check if file exists
- `command_success` - Run command and check exit code
- `json_field` - Check JSON field value
- `custom` - Run custom validation script

---

### Item 24: Context-aware Resource Allocation

**Location**: `/Users/ryandahlberg/commit-relay/scripts/lib/task-allocator.sh`

**Key Functions**:
- `allocate_resources()` - Main allocation function
- `estimate_complexity()` - Estimate task complexity
- `record_allocation_outcome()` - Record for learning

**Usage**:
```bash
source "$COMMIT_RELAY_HOME/scripts/lib/task-allocator.sh"

# Allocate resources for a task
allocation=$(allocate_resources \
    --task-description "Implement OAuth2 authentication with JWT tokens" \
    --task-type "feature" \
    --task-id "task-456")

# Extract allocation
token_budget=$(echo "$allocation" | jq -r '.allocation.token_budget')
timeout=$(echo "$allocation" | jq -r '.allocation.timeout_minutes')

# Record outcome for learning
record_allocation_outcome \
    "task-456" \
    "implementation-worker" \
    "feature" \
    "$token_budget" \
    "8500" \
    "$timeout" \
    "25" \
    "completed"
```

**Configuration**: `/Users/ryandahlberg/commit-relay/coordination/config/task-allocation-policy.json`

---

### Item 25: Prompt Versioning and A/B Testing

**Location**: `/Users/ryandahlberg/commit-relay/scripts/lib/prompt-manager.sh`

**Key Functions**:
- `register_prompt_version()` - Register a new prompt version
- `get_prompt()` - Get prompt with optional A/B testing
- `start_ab_test()` - Start A/B test between versions
- `record_prompt_outcome()` - Record outcome for a version
- `analyze_ab_test()` - Analyze test results

**Usage**:
```bash
source "$COMMIT_RELAY_HOME/scripts/lib/prompt-manager.sh"

# Register prompt versions
register_prompt_version \
    "implementation-worker" \
    "v1.0.0" \
    "$(cat prompts/impl-worker-v1.md)" \
    "Original prompt" \
    "true"  # is control

register_prompt_version \
    "implementation-worker" \
    "v1.1.0" \
    "$(cat prompts/impl-worker-v1.1.md)" \
    "Improved with examples"

# Start A/B test
test_id=$(start_ab_test "implementation-worker" "v1.0.0" "v1.1.0" 50)

# Get prompt (with A/B selection)
prompt=$(get_prompt "implementation-worker" --ab-test)

# Record outcome
record_prompt_outcome "v1.1.0" "success" "implementation-worker" "$test_id" "variant"

# Analyze and end test
analyze_ab_test "$test_id"
end_ab_test "$test_id" "true"  # promote winner
```

**Data Location**: `/Users/ryandahlberg/commit-relay/coordination/prompt-versions/`

---

## Automation & Risk

### Item 27: Automated Remediation Playbooks

**Location**: `/Users/ryandahlberg/commit-relay/scripts/lib/auto-remediate.sh`

**Key Functions**:
- `remediate_pattern()` - Main remediation entry point
- `execute_playbook()` - Execute a specific playbook
- `validate_remediation()` - Validate remediation effectiveness

**Usage**:
```bash
source "$COMMIT_RELAY_HOME/scripts/lib/auto-remediate.sh"

# Remediate a detected pattern
remediate_pattern "resource:timeout" "implementation-worker" "worker-impl-001"

# Execute specific playbook
execute_playbook "pb-timeout-increase" '{"worker_type":"implementation-worker"}'

# Validate effectiveness
validate_remediation "exec-12345" 24
```

**Playbook Index**: `/Users/ryandahlberg/commit-relay/coordination/remediation-playbooks/index.json`

**Built-in Playbooks**:
- `pb-timeout-increase` - Increase worker timeout
- `pb-token-budget-increase` - Increase token budget
- `pb-circuit-breaker-reset` - Reset circuit breaker
- `pb-worker-restart` - Restart failed worker

---

### Item 29: Risk-based Resource Allocation

**Location**: `/Users/ryandahlberg/commit-relay/scripts/lib/risk-scorer.sh`

**Key Functions**:
- `score_task_risk()` - Calculate risk score for a task
- `record_task_outcome()` - Record outcome for learning
- `get_risk_summary()` - Get risk distribution summary

**Usage**:
```bash
source "$COMMIT_RELAY_HOME/scripts/lib/risk-scorer.sh"

# Score task risk
risk=$(score_task_risk \
    --task-description "Migrate database schema with user data" \
    --worker-type "implementation-worker" \
    --task-type "feature" \
    --token-budget 10000 \
    --timeout-minutes 30 \
    --file-count 5 \
    --dependencies 3)

# Extract risk-adjusted resources
risk_level=$(echo "$risk" | jq -r '.risk_level')
adjusted_tokens=$(echo "$risk" | jq -r '.resource_adjustments.adjusted_token_budget')
priority_boost=$(echo "$risk" | jq -r '.resource_adjustments.priority_boost')

# Record outcome
record_task_outcome "task-789" "implementation-worker" "feature" "completed" 65
```

**Risk Levels**: `low`, `medium`, `high`, `critical`

---

## API

### Item 31: API Versioning

**Location**: `/Users/ryandahlberg/commit-relay/dashboard/server/routes/api-v1.js`

**Integration in index.js**:
```javascript
const apiV1Router = require('./routes/api-v1');
const docsRouter = require('./routes/docs');

// Mount versioned API
app.use('/api/v1', apiV1Router);

// Mount documentation
app.use('/api/docs', docsRouter);

// Backward compatibility
app.use('/api', (req, res, next) => {
  if (!req.path.startsWith('/v1') && !req.path.startsWith('/docs')) {
    req.url = `/v1${req.url}`;
  }
  next();
});
```

**Version Header**: Responses include `X-API-Version: 1.0.0`

---

### Item 32: OpenAPI Specification

**Location**: `/Users/ryandahlberg/commit-relay/dashboard/server/openapi.json`

**Documentation Routes** (`/Users/ryandahlberg/commit-relay/dashboard/server/routes/docs.js`):
- `GET /api/docs` - OpenAPI JSON
- `GET /api/docs/openapi.json` - Raw JSON
- `GET /api/docs/openapi.yaml` - YAML format
- `GET /api/docs/ui` - Swagger UI
- `GET /api/docs/endpoints` - Simplified endpoint list

**Access Swagger UI**: `http://localhost:3000/api/docs/ui`

---

## RAG Optimization

### Item 35: Query Optimization for RAG

**Location**: `/Users/ryandahlberg/commit-relay/scripts/lib/rag/query-optimizer.sh`

**Key Functions**:
- `optimize_query()` - Main optimization function
- `expand_query()` - Expand with synonyms
- `rewrite_query()` - Rewrite for clarity
- `rerank_results()` - Re-rank by relevance

**Usage**:
```bash
source "$COMMIT_RELAY_HOME/scripts/lib/rag/query-optimizer.sh"

# Optimize a query
optimized=$(optimize_query "how to implement auth")
expanded=$(echo "$optimized" | jq -r '.expanded_query')

# Re-rank results
results='[{"content":"Auth guide...","timestamp":"2025-01-15"},...]'
reranked=$(rerank_results "$results" "$expanded")
```

**Features**:
- Synonym expansion
- Stop word removal
- Query templates (how_to, what_is, best_practice)
- BM25 + recency re-ranking
- Query caching

**Configuration**: `/Users/ryandahlberg/commit-relay/coordination/config/rag-query-optimizer.json`

---

### Item 36: Semantic Chunking Strategies

**Location**: `/Users/ryandahlberg/commit-relay/scripts/lib/rag/semantic-chunker.sh`

**Key Functions**:
- `chunk_document()` - Chunk a file
- `chunk_text()` - Chunk text content
- `chunk_markdown()` - Markdown-specific chunking
- `chunk_code()` - Code-specific chunking

**Usage**:
```bash
source "$COMMIT_RELAY_HOME/scripts/lib/rag/semantic-chunker.sh"

# Chunk a document
chunks=$(chunk_document "/path/to/file.md")
chunk_count=$(echo "$chunks" | jq 'length')

# Chunk text directly
chunks=$(chunk_text "$content" "markdown" "inline")

# Get chunking metrics
metrics=$(get_chunking_metrics)
```

**Features**:
- Paragraph boundary detection
- Section/heading detection
- Code block handling
- Overlap management
- Keyword extraction per chunk

**Configuration**: `/Users/ryandahlberg/commit-relay/coordination/config/semantic-chunker.json`

---

## Verification

### Item 37: Step-by-step Verification

**Location**: `/Users/ryandahlberg/commit-relay/scripts/lib/step-verifier.sh`

**Key Functions**:
- `verify_step()` - Verify a single step
- `verify_all_steps()` - Verify all steps in sequence
- `get_verification_progress()` - Get progress
- `add_step_verification()` - Add criteria to step

**Usage**:
```bash
source "$COMMIT_RELAY_HOME/scripts/lib/step-verifier.sh"

# Add verification to spec
add_step_verification \
    "/path/to/spec.json" \
    "build-step" \
    "command_succeeds" \
    "npm run build" \
    "true"

# Verify single step
verify_step "/path/to/spec.json" "build-step"

# Verify all steps
result=$(verify_all_steps "/path/to/spec.json")

# Get progress
progress=$(get_verification_progress "/path/to/spec.json")
```

**Verification Types**:
- `file_exists`
- `file_contains`
- `command_succeeds`
- `command_output`
- `json_field`
- `http_status`
- `tests_pass`
- `custom_script`

---

### Item 38: Reasoning Trace Validation

**Location**: `/Users/ryandahlberg/commit-relay/scripts/lib/reasoning-validator.sh`

**Key Functions**:
- `validate_reasoning_trace()` - Full validation
- `score_reasoning_quality()` - Get quality score
- `add_to_training_set()` - Add to training if valid

**Usage**:
```bash
source "$COMMIT_RELAY_HOME/scripts/lib/reasoning-validator.sh"

# Validate a reasoning trace
trace='{
    "problem_statement": "How to improve API response time?",
    "reasoning_steps": [
        "First, profile current endpoints",
        "Then, identify bottlenecks",
        "Next, implement caching"
    ],
    "conclusion": "Implement Redis caching to reduce response time by 50%"
}'

result=$(validate_reasoning_trace "$trace")
score=$(echo "$result" | jq -r '.total_score')
valid=$(echo "$result" | jq -r '.valid_for_training')

# Add to training set if valid
add_to_training_set "$trace"
```

**Quality Checks**:
- Step coherence
- Logical consistency
- Evidence support
- Conclusion validity
- Format quality

**Quality Levels**: `excellent` (90+), `good` (70+), `acceptable` (50+), `poor` (<50)

---

## Configuration Files Created

All configuration files are auto-generated on first use:

1. `/Users/ryandahlberg/commit-relay/coordination/config/task-allocation-policy.json`
2. `/Users/ryandahlberg/commit-relay/coordination/config/risk-scoring-policy.json`
3. `/Users/ryandahlberg/commit-relay/coordination/config/rag-query-optimizer.json`
4. `/Users/ryandahlberg/commit-relay/coordination/config/semantic-chunker.json`
5. `/Users/ryandahlberg/commit-relay/coordination/config/step-verifier.json`
6. `/Users/ryandahlberg/commit-relay/coordination/config/reasoning-validator.json`
7. `/Users/ryandahlberg/commit-relay/coordination/remediation-playbooks/index.json`
8. `/Users/ryandahlberg/commit-relay/coordination/prompt-versions/registry.json`

---

## Metrics & History Files

Each capability writes to its own history/metrics file:

- Task allocation: `/Users/ryandahlberg/commit-relay/coordination/metrics/task-allocation-history.jsonl`
- Risk scoring: `/Users/ryandahlberg/commit-relay/coordination/metrics/risk-scoring-history.jsonl`
- Query optimization: `/Users/ryandahlberg/commit-relay/coordination/metrics/query-history.jsonl`
- Chunking: `/Users/ryandahlberg/commit-relay/coordination/metrics/chunking-history.jsonl`
- Verification: `/Users/ryandahlberg/commit-relay/coordination/metrics/verification-history.jsonl`
- Reasoning validation: `/Users/ryandahlberg/commit-relay/coordination/metrics/reasoning-validation-history.jsonl`
- Remediation: `/Users/ryandahlberg/commit-relay/coordination/remediation-playbooks/history.jsonl`
- Prompt outcomes: `/Users/ryandahlberg/commit-relay/coordination/prompt-versions/outcomes.jsonl`

---

## Integration with Existing System

### Worker Spec Builder Integration

The checkpoint criteria integrate with the existing worker spec builder. Use the `--checkpoint-criteria` flag when building specs.

### Auto-Fix Integration

The auto-remediate library extends the existing auto-fix system. It uses the same pattern detection from `failure-pattern-detection.sh`.

### Dashboard Integration

To enable API versioning and documentation:

1. Add to index.js imports:
```javascript
const apiV1Router = require('./routes/api-v1');
const docsRouter = require('./routes/docs');
```

2. Mount routes after authentication middleware:
```javascript
app.use('/api/v1', apiV1Router);
app.use('/api/docs', docsRouter);
```

---

## Dependencies

All scripts use standard tools available in the commit-relay environment:
- bash
- jq
- bc
- curl (for HTTP verification)

No additional dependencies required.

---

## Testing

Test each capability individually:

```bash
# Test task allocation
source scripts/lib/task-allocator.sh
allocate_resources --task-description "test task" --task-type "feature"

# Test risk scoring
source scripts/lib/risk-scorer.sh
score_task_risk --task-description "test" --worker-type "implementation-worker"

# Test query optimization
source scripts/lib/rag/query-optimizer.sh
optimize_query "how to test"

# Test semantic chunking
source scripts/lib/rag/semantic-chunker.sh
chunk_text "# Header\nParagraph 1\n\nParagraph 2" "markdown"
```

---

## Future Enhancements

1. **Machine Learning Integration**: Connect risk scorer and allocator to ML models
2. **Statistical A/B Testing**: Add proper statistical significance testing
3. **Semantic Similarity**: Add embedding-based similarity for re-ranking
4. **Auto-tuning**: Self-adjust based on historical performance
