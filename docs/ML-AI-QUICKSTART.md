# ML/AI Integration - Quick Start Guide

This guide helps you get started with PyTorch and LangChain integration in commit-relay.

## What We've Built

### 1. Architecture Foundation
- Complete ML/AI architecture design (see `ML-AI-ARCHITECTURE.md`)
- Hybrid approach: PyTorch for learning + LangChain for orchestration
- Focus on MoE routing improvement and worker intelligence

### 2. Directory Structure
```
llm-mesh/
├── lib/                    # Python ML libraries
│   ├── routing/           # Neural router implementation
│   ├── rag/               # RAG for context-aware agents
│   ├── prediction/        # Task outcome predictors
│   └── embeddings/        # Code/task embeddings
├── models/                # Trained model checkpoints
│   ├── routing/           # MoE routing models
│   ├── prediction/        # Performance predictors
│   └── embeddings/        # Embedding models
├── training-data/         # Training datasets
│   ├── routing/           # Historical routing decisions
│   ├── performance/       # Worker metrics
│   └── embeddings/        # Precomputed embeddings
├── vectors/               # Vector stores for RAG
│   ├── codebase/          # Source code embeddings
│   └── documentation/     # Documentation embeddings
└── scripts/               # Training/inference scripts
```

### 3. Neural Router (PyTorch)
- Transformer-based task-to-master routing
- Learns from historical routing decisions
- Provides confidence scores
- Ensemble with rule-based fallback

### 4. Next: LangChain Integration
- RAG for context-aware workers
- Vector store for codebase knowledge
- Enhanced prompt templates
- Memory systems for stateful agents

## Installation

### Step 1: Install ML Dependencies
```bash
cd /Users/ryandahlberg/Projects/commit-relay

# Install PyTorch, LangChain, and dependencies
pip install -r python-sdk/requirements-ml.txt
```

### Step 2: Verify Installation
```python
# Test PyTorch
import torch
print(f"PyTorch version: {torch.__version__}")
print(f"CUDA available: {torch.cuda.is_available()}")

# Test LangChain
from langchain import __version__
print(f"LangChain version: {__version__}")

# Test our neural router
from llm_mesh.lib.routing import NeuralRouter
router = NeuralRouter()
print("Neural router initialized successfully!")
```

## Quick Examples

### Example 1: Neural Routing
```python
import torch
from llm_mesh.lib.routing import NeuralRouter

# Initialize router
router = NeuralRouter()

# Create dummy task embedding (in practice, use CodeBERT)
task_embedding = torch.randn(512)  # 512-dim embedding

# Route task
master, confidence, probs = router.route(
    task_description="Fix authentication bug in login system",
    task_embedding=task_embedding
)

print(f"Selected: {master}")
print(f"Confidence: {confidence:.2%}")
print(f"All probabilities: {probs}")
```

### Example 2: Routing with Explanation
```python
# Get detailed explanation
explanation = router.explain_routing(
    task_description="Scan repository for CVE vulnerabilities",
    task_embedding=task_embedding
)

print(f"Selected: {explanation['selected_master']}")
print(f"Reasoning: {explanation['reasoning']}")
print("\nRanking:")
for rank in explanation['ranking']:
    print(f"  {rank['master']}: {rank['probability']:.2%}")
```

### Example 3: Ensemble Routing
```python
from llm_mesh.lib.routing import EnsembleRouter

# Create ensemble (neural + rule-based fallback)
ensemble = EnsembleRouter(
    neural_router=router,
    confidence_threshold=0.7
)

# Route with fallback
master, conf, method = ensemble.route(
    task_description="Implement new feature for user dashboard",
    task_embedding=task_embedding
)

print(f"Master: {master}")
print(f"Method: {method}")  # "neural" or "fallback"
```

## Next Steps

### Phase 1: Data Collection (This Week)
```bash
# Export historical routing decisions
python llm-mesh/scripts/data/export-routing-data.py \
  --source coordination/masters/coordinator/knowledge-base/ \
  --output llm-mesh/training-data/routing/

# Export worker performance metrics
python llm-mesh/scripts/data/export-metrics.py \
  --source coordination/metrics/ \
  --output llm-mesh/training-data/performance/
```

### Phase 2: Train Initial Model (Next Week)
```bash
# Generate task embeddings
python llm-mesh/scripts/training/generate-embeddings.py \
  --input llm-mesh/training-data/routing/ \
  --output llm-mesh/training-data/embeddings/

# Train routing model
python llm-mesh/scripts/training/train-router.py \
  --data llm-mesh/training-data/routing/ \
  --output llm-mesh/models/routing/v1/ \
  --epochs 50

# Evaluate model
python llm-mesh/scripts/training/evaluate.py \
  --model llm-mesh/models/routing/v1/ \
  --test-data llm-mesh/training-data/routing/test.parquet
```

### Phase 3: LangChain RAG (Week 3)
```bash
# Create vector store
python llm-mesh/scripts/rag/create-vectorstore.py \
  --source . \
  --output llm-mesh/vectors/codebase/ \
  --chunk-size 1000

# Test RAG retrieval
python llm-mesh/scripts/rag/test-retrieval.py \
  --query "authentication implementation" \
  --vectorstore llm-mesh/vectors/codebase/
```

### Phase 4: Integration (Week 4)
```bash
# Update MoE router to use neural model
# Update workers to use RAG
# A/B test neural vs rule-based routing
# Deploy to production
```

## Development Workflow

### 1. Data Pipeline
```bash
# Daily: Export new routing decisions
python scripts/data/daily-export.py

# Weekly: Retrain models
python scripts/training/weekly-retrain.py

# Monthly: Full evaluation
python scripts/evaluation/monthly-eval.py
```

### 2. Model Development
```bash
# Create new experiment
python scripts/training/train-router.py \
  --experiment-name routing-v2 \
  --config configs/routing-v2.yaml

# Track with MLflow
mlflow ui --backend-store-uri sqlite:///mlflow.db

# Compare experiments
python scripts/evaluation/compare-experiments.py \
  --baseline routing-v1 \
  --candidate routing-v2
```

### 3. Deployment
```bash
# Deploy to staging
python scripts/deployment/deploy.py \
  --model models/routing/v2/ \
  --environment staging

# A/B test (10% traffic)
python scripts/deployment/ab-test.py \
  --control models/routing/v1/ \
  --treatment models/routing/v2/ \
  --traffic 0.1

# Promote to production
python scripts/deployment/promote.py \
  --model models/routing/v2/
```

## Monitoring

### Metrics Dashboard
```bash
# Start MLflow UI
mlflow ui

# Start TensorBoard
tensorboard --logdir llm-mesh/models/routing/

# View metrics
python scripts/monitoring/view-metrics.py
```

### Key Metrics to Track
- **Routing Accuracy**: % correct master selection
- **Confidence Calibration**: Are high-confidence predictions accurate?
- **Inference Latency**: Time to route (target: <100ms)
- **Model Freshness**: Days since last training
- **Task Success Rate**: Overall improvement

## Troubleshooting

### Common Issues

**1. Import Errors**
```bash
# Ensure you're in the right directory
cd /Users/ryandahlberg/Projects/commit-relay

# Re-install dependencies
pip install -r python-sdk/requirements-ml.txt
```

**2. CUDA/GPU Issues**
```bash
# Force CPU inference
export CUDA_VISIBLE_DEVICES=""

# Or specify CPU in code
router = NeuralRouter(device="cpu")
```

**3. Memory Issues**
```bash
# Reduce batch size
export BATCH_SIZE=16

# Use model quantization
python scripts/quantize-model.py --model models/routing/current/
```

## Resources

### Documentation
- [ML/AI Architecture](ML-AI-ARCHITECTURE.md) - Complete architecture
- [LLM Mesh README](../llm-mesh/README.md) - Module documentation
- [PyTorch Docs](https://pytorch.org/docs/)
- [LangChain Docs](https://python.langchain.com/)

### Code Examples
- `llm-mesh/lib/routing/neural_router.py` - Neural router implementation
- `llm-mesh/scripts/training/` - Training scripts
- `llm-mesh/scripts/rag/` - RAG examples

### Support
- GitHub Issues: Report bugs and request features
- Architecture Docs: Design decisions and rationale
- Code Comments: Inline documentation

## Roadmap

### Current Phase: Foundation
- [x] Architecture design
- [x] Directory structure
- [x] Neural router implementation
- [ ] Data collection pipeline
- [ ] Training scripts

### Next Phase: Training
- [ ] Generate embeddings
- [ ] Train initial routing model
- [ ] Evaluate performance
- [ ] A/B testing framework

### Future Phases
- [ ] LangChain RAG integration
- [ ] Performance prediction
- [ ] Continuous learning pipeline
- [ ] Advanced features (RL, graph RAG)

---

**Status**: Foundation complete, ready for data collection
**Next Action**: Export historical routing data for training
**Timeline**: 4-week implementation plan
