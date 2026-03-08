# ML/AI Deployment Guide

Complete deployment guide for ML-enhanced routing and RAG systems in commit-relay.

## Overview

This system integrates PyTorch neural routing and FAISS-based RAG to enhance the MoE (Mixture of Experts) orchestration system with learned intelligence.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Task Input                            │
└────────────────────┬────────────────────────────────────┘
                     │
         ┌───────────▼──────────┐
         │  MLEnhancedRouter    │
         │  (A/B Test Gateway)  │
         └───┬──────────────┬───┘
             │              │
    ┌────────▼────┐    ┌───▼──────────┐
    │  ML Route   │    │  Rule-Based  │
    │  (10% test) │    │  (90% safe)  │
    └────┬────────┘    └───┬──────────┘
         │                 │
         │   ┌─────────────▼───────────┐
         │   │   Neural Router         │
         │   │   (Not trained yet)     │
         │   └─────────────┬───────────┘
         │                 │
         └─────────┬───────┘
                   │
         ┌─────────▼──────────────┐
         │   Master Selection     │
         │ (development/security/ │
         │  inventory/cicd/coord) │
         └─────────┬──────────────┘
                   │
         ┌─────────▼──────────────┐
         │   RAG Context          │
         │   Retrieval            │
         │ (FAISS vectorstore)    │
         └────────────────────────┘
```

## Components

### 1. ML-Enhanced Router
**File**: `llm-mesh/lib/integration/moe_ml_router.py`

Provides:
- A/B testing framework (configurable traffic split)
- Neural routing (when model trained)
- Rule-based fallback
- RAG context retrieval
- Performance metrics

### 2. Vector Store
**Technology**: FAISS + sentence-transformers

Created by:
```bash
python3 llm-mesh/scripts/rag/create-vectorstore.py \
  --source . \
  --output llm-mesh/vectors/codebase \
  --chunk-size 500
```

Stats:
- **Model**: all-MiniLM-L6-v2 (384-dim embeddings)
- **Chunks**: 231 code chunks (test), 1000+ (full)
- **Coverage**: Bash scripts, Python modules, docs

### 3. Deployment Infrastructure
**Scripts**:
- `llm-mesh/scripts/integration/deploy-ml-router.sh` - Deploy with A/B config
- `llm-mesh/scripts/integration/test-ml-router.py` - Test routing
- `llm-mesh/scripts/integration/monitor-ml-router.sh` - Metrics monitoring

## Deployment Stages

### Stage 1: Shadow Mode (Current)
```bash
export AB_TEST_PERCENTAGE=0.0
bash llm-mesh/scripts/integration/deploy-ml-router.sh
```

- 0% ML traffic
- Collect baseline metrics
- Validate integration

### Stage 2: Canary Release
```bash
export AB_TEST_PERCENTAGE=0.1
bash llm-mesh/scripts/integration/deploy-ml-router.sh
```

- 10% ML traffic
- Monitor routing quality
- Compare with rule-based

### Stage 3: Gradual Rollout
```bash
# Week 1: 25%
export AB_TEST_PERCENTAGE=0.25
bash llm-mesh/scripts/integration/deploy-ml-router.sh

# Week 2: 50%
export AB_TEST_PERCENTAGE=0.5
bash llm-mesh/scripts/integration/deploy-ml-router.sh

# Week 3: 75%
export AB_TEST_PERCENTAGE=0.75
bash llm-mesh/scripts/integration/deploy-ml-router.sh
```

### Stage 4: Full Production
```bash
export AB_TEST_PERCENTAGE=1.0
bash llm-mesh/scripts/integration/deploy-ml-router.sh
```

- 100% ML traffic
- Neural routing (once model trained)
- RAG-enhanced workers

## Configuration

### Deployment Config
**File**: `llm-mesh/config/deployment.json`

```json
{
  "version": "1.0.0",
  "deployment_date": "2025-11-25T11:50:00-0600",
  "configuration": {
    "ab_test_percentage": 0.1,
    "enable_neural": false,
    "enable_rag": true,
    "model_path": "llm-mesh/models/routing/current",
    "vectorstore_path": "llm-mesh/vectors/codebase-test"
  },
  "status": "deployed"
}
```

### Environment Variables
```bash
# A/B testing
export AB_TEST_PERCENTAGE=0.1       # 10% ML traffic

# Feature flags
export ENABLE_NEURAL=false          # Neural routing (when model trained)
export ENABLE_RAG=true              # RAG context retrieval

# Paths
export MODEL_PATH="llm-mesh/models/routing/current"
export VECTORSTORE_PATH="llm-mesh/vectors/codebase-test"
```

## Monitoring

### Metrics Collection
**File**: `coordination/metrics/ml-router-metrics.jsonl`

Each routing decision logs:
```json
{
  "timestamp": "2025-11-25T11:50:00-0600",
  "task_id": "task-001",
  "method": "rule-based",
  "selected_master": "development-master",
  "confidence": 0.8,
  "ab_test_group": "control"
}
```

### Monitoring Script
```bash
bash llm-mesh/scripts/integration/monitor-ml-router.sh
```

Output:
```
📊 ML Router Metrics
====================
Total routes: 1000
ML routes: 100
Rule-based routes: 900
ML percentage: 10.00%
```

### Key Metrics

1. **Routing Accuracy**: % correct master selection
2. **Confidence Score**: Average confidence (target: >0.8)
3. **RAG Hit Rate**: % tasks with relevant context found
4. **Latency**: Routing decision time (target: <100ms)
5. **A/B Test Balance**: Verify traffic split

## Testing

### Unit Tests
```bash
source python-sdk/.venv/bin/activate
python3 llm-mesh/scripts/integration/test-ml-router.py
```

### Integration Tests
```bash
# Test routing decisions
python3 -c "
from llm_mesh.lib.integration import MLEnhancedRouter

router = MLEnhancedRouter(
    vectorstore_path='llm-mesh/vectors/codebase-test',
    enable_rag=True
)

decision = router.route_task('Fix authentication bug')
print(f'Master: {decision[\"selected_master\"]}')
print(f'Confidence: {decision[\"confidence\"]:.2%}')
"
```

### RAG Tests
```bash
python3 llm-mesh/scripts/rag/test-retrieval.py \
  --query "How do workers handle heartbeat monitoring?" \
  --vectorstore llm-mesh/vectors/codebase-test \
  --n-results 5
```

## Rollback Procedure

If issues detected:

```bash
# 1. Reduce ML traffic
export AB_TEST_PERCENTAGE=0.0
bash llm-mesh/scripts/integration/deploy-ml-router.sh

# 2. Verify rule-based working
python3 llm-mesh/scripts/integration/test-ml-router.py

# 3. Investigate metrics
bash llm-mesh/scripts/integration/monitor-ml-router.sh

# 4. Review logs
tail -100 coordination/metrics/ml-router-metrics.jsonl
```

## Future Enhancements

### Phase 5: Neural Router Training
```bash
# Collect training data
python3 llm-mesh/scripts/data/export-routing-data.py

# Train model
python3 llm-mesh/scripts/training/train-router.py \
  --data llm-mesh/training-data/routing/ \
  --output llm-mesh/models/routing/v1/

# Enable neural routing
export ENABLE_NEURAL=true
bash llm-mesh/scripts/integration/deploy-ml-router.sh
```

### Phase 6: Continuous Learning
- Daily model retraining
- Feedback loop from task outcomes
- Reinforcement learning integration
- Dynamic confidence thresholds

### Phase 7: Advanced RAG
- Multi-modal embeddings (code + docs + issues)
- Graph RAG for architectural context
- Task-specific vector stores
- Real-time vectorstore updates

## Troubleshooting

### RAG Not Working
```bash
# Verify vector store exists
ls -lh llm-mesh/vectors/codebase-test/

# Recreate if missing
python3 llm-mesh/scripts/rag/create-vectorstore.py \
  --source . \
  --output llm-mesh/vectors/codebase-test
```

### Poor Routing Quality
```bash
# Check confidence scores
grep '"confidence"' coordination/metrics/ml-router-metrics.jsonl | \
  jq '.confidence' | \
  awk '{sum+=$1; count++} END {print "Average:", sum/count}'

# Analyze failures
grep '"outcome":"failed"' coordination/metrics/ml-router-metrics.jsonl
```

### Performance Issues
```bash
# Monitor latency
time python3 llm-mesh/scripts/integration/test-ml-router.py

# Check vector store size
du -sh llm-mesh/vectors/codebase-test/

# Optimize: Use smaller chunks or fewer files
python3 llm-mesh/scripts/rag/create-vectorstore.py \
  --source scripts/lib \
  --chunk-size 200
```

## Security Considerations

1. **Vector Store Access**: Read-only for workers
2. **Model Integrity**: Verify checksums before loading
3. **Input Validation**: Sanitize task descriptions
4. **Rate Limiting**: Prevent RAG abuse
5. **Audit Trail**: Log all routing decisions

## Success Criteria

- [ ] A/B test running with 10% ML traffic
- [ ] Routing accuracy >= baseline (rule-based)
- [ ] RAG providing relevant context (>80% hit rate)
- [ ] Latency < 100ms per routing decision
- [ ] Zero routing errors/exceptions
- [ ] Metrics collection working
- [ ] Rollback procedure tested

## References

- [ML/AI Architecture](ML-AI-ARCHITECTURE.md)
- [ML/AI Quick Start](ML-AI-QUICKSTART.md)
- [MoE Router Design](moe-routing-design.md)
- [RAG Implementation](../llm-mesh/lib/rag/)
- [Integration Tests](../llm-mesh/scripts/integration/)

---

**Status**: Deployed (Stage 1: Shadow Mode)
**Version**: 1.0.0
**Last Updated**: 2025-11-25
