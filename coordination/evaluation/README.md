# Agent Ops Evaluation Framework

**Status**: ✅ Phase 1 Complete - Foundation Ready
**Version**: 1.0.0
**Created**: 2025-11-26

## Overview

The Agent Ops Evaluation Framework provides systematic quality measurement for commit-relay's MoE routing system. It uses **LM-as-Judge** (Claude) to evaluate routing decisions against a golden dataset, enabling data-driven improvement of the routing algorithm.

This is the first implementation from the [Agent Architecture Implementation Review](../../docs/AGENT-ARCHITECTURE-IMPLEMENTATION-REVIEW.md), chosen as the foundation for commit-relay's evolution into a sustainable platform.

## Architecture

```
coordination/evaluation/
├── golden-routing-decisions.jsonl    # 20 labeled examples (expand to 50-100)
├── prompts/
│   └── judge-routing-quality.md      # LM-as-Judge evaluation prompt
├── results/
│   ├── eval-run-*.jsonl              # Detailed per-example results
│   ├── eval-summary-*.json           # Aggregate metrics
│   └── comparison-*.json             # A/B test results
└── README.md                         # This file

llm-mesh/moe-learning/evaluation/
├── eval-router.sh                    # Main evaluation harness
└── compare-strategies.sh             # A/B testing tool
```

## Quick Start

### 1. Run Your First Evaluation

```bash
cd /Users/ryandahlberg/Projects/commit-relay

# Ensure ANTHROPIC_API_KEY is set
export ANTHROPIC_API_KEY="your-key-here"

# Run evaluation against golden dataset
./llm-mesh/moe-learning/moe-learn.sh eval
```

**Expected Output:**
```
╔═══════════════════════════════════════════════╗
║  MoE Router Evaluation Harness                ║
╚═══════════════════════════════════════════════╝

Golden dataset: 20 examples
Model: claude-sonnet-4-5-20250929

Evaluating eval-001...
Task: Fix authentication bug causing login failures after password reset
  Running router...
  Routed to: development (confidence: 0.87)
  Expected: development (confidence: 0.95)
  Calling LM-as-Judge...
  ✓ Optimal routing (accuracy: 92, calibration: 88)

[... 19 more examples ...]

╔═══════════════════════════════════════════════╗
║  Evaluation Summary                           ║
╚═══════════════════════════════════════════════╝

Total Evaluated: 20
Optimal Routings: 15 (75%)
Expert Matches: 18 (90%)

Avg Routing Accuracy: 82.5/100
Avg Confidence Calibration: 76.3/100

✓ GOOD routing quality, room for improvement

Results saved to:
  Details: coordination/evaluation/results/eval-run-20251126-143022.jsonl
  Summary: coordination/evaluation/results/eval-summary-20251126-143022.json
```

### 2. Run Evaluation in Learning Cycle

```bash
# Run complete learning cycle with before/after evaluation
./llm-mesh/moe-learning/moe-learn.sh learn
```

**What happens:**
1. **Phase 0**: Baseline evaluation (measures current routing quality)
2. **Phase 1-3**: Pattern learning, improvement generation, statistics
3. **Phase 4**: Apply improvements (if you approve)
4. **Phase 5**: Post-improvement evaluation (measures impact)
5. **Phase 6**: Impact analysis (shows delta between before/after)

### 3. A/B Test Two Strategies

```bash
# Compare current config vs experimental changes
./llm-mesh/moe-learning/evaluation/compare-strategies.sh \
  current "" \
  experimental coordination/masters/coordinator/knowledge-base/routing-patterns-experimental.json
```

## Golden Dataset

### Current Dataset: 20 Examples

The golden dataset (`golden-routing-decisions.jsonl`) contains 20 labeled routing decisions covering:

- **Development tasks** (7): Bug fixes, features, refactoring, testing
- **Security tasks** (5): Vulnerability scans, security audits, code review
- **Inventory tasks** (4): Repository cataloging, documentation, compliance
- **CI/CD tasks** (4): Pipeline setup, monitoring, release automation

### Example Entry

```json
{
  "eval_id": "eval-001",
  "task_description": "Fix authentication bug causing login failures after password reset",
  "ideal_expert": "development",
  "ideal_confidence": 0.95,
  "rationale": "Bug fix in application code requires development expertise. Security is involved but not primary.",
  "difficulty": "medium",
  "task_characteristics": {
    "type": "bug_fix",
    "domain": "authentication",
    "urgency": "high",
    "security_implications": "medium"
  }
}
```

### Expanding the Dataset

**Goal**: 50-100 examples for robust evaluation

**How to add examples:**

1. **From Production Logs** (Recommended):
   ```bash
   # Extract recent successful routing decisions
   grep '"status":"completed"' coordination/masters/coordinator/logs/routing-decisions.jsonl | \
     tail -30 > recent-successes.jsonl

   # Use LLM to label them as golden examples
   # (Script coming in Phase 1.5)
   ```

2. **Manual Creation**:
   - Copy existing format from `golden-routing-decisions.jsonl`
   - Add diverse task types (edge cases, ambiguous tasks, multi-domain)
   - Include both easy and hard examples
   - Balance across all expert types

3. **Edge Cases to Add**:
   - Ambiguous tasks requiring multi-expert coordination
   - Security-critical operations (authentication migration, crypto changes)
   - High-complexity refactors touching multiple domains
   - Tasks that historically caused reassignments

## LM-as-Judge Evaluation

### How It Works

1. **Router runs** on task description → produces routing decision
2. **Judge prompt** compares actual vs ideal routing
3. **Claude evaluates** with two scores:
   - **Routing Accuracy** (0-100): Did we pick the right expert?
   - **Confidence Calibration** (0-100): Does confidence match task clarity?
4. **Learning insights** extracted for improving routing algorithm

### Judge Prompt

See: `prompts/judge-routing-quality.md`

**Key evaluation criteria:**
- Primary responsibility match
- Task characteristics alignment
- Security implications consideration
- Multi-expert coordination needs
- Confidence calibration

### Interpretation

| Avg Routing Accuracy | Assessment | Action |
|---------------------|------------|--------|
| 85-100 | **EXCELLENT** | Maintain current quality, expand dataset |
| 70-84  | **GOOD** | Identify improvement opportunities |
| 50-69  | **FAIR** | Focused improvements needed |
| 0-49   | **POOR** | Major routing issues, immediate attention |

## Evaluation Metrics

### Per-Example Metrics

Each evaluation produces:
```json
{
  "eval_id": "eval-001",
  "judgment": {
    "routing_accuracy": 92,
    "confidence_calibration": 88,
    "is_optimal": true,
    "suggested_expert": null,
    "analysis": {
      "strengths": "...",
      "weaknesses": "...",
      "reasoning": "..."
    },
    "learning_insights": [
      "Actionable improvement suggestion 1",
      "Pattern to strengthen 2"
    ]
  }
}
```

### Aggregate Metrics

Evaluation summary includes:
- **Total Evaluated**: Number of examples processed
- **Optimal Routings**: Count meeting ideal routing (is_optimal=true)
- **Expert Matches**: Count where actual_expert == ideal_expert
- **Avg Routing Accuracy**: Mean accuracy score across all examples
- **Avg Confidence Calibration**: Mean calibration score
- **Optimal Rate %**: Percentage of optimal routings
- **Expert Match Rate %**: Percentage of exact expert matches

## A/B Testing

### Comparing Routing Strategies

Use `compare-strategies.sh` to measure impact of changes:

```bash
# Test keyword weight adjustments
./llm-mesh/moe-learning/evaluation/compare-strategies.sh \
  baseline routing-patterns-baseline.json \
  higher-security-weight routing-patterns-security-boost.json
```

**Output:**
```
╔════════════════════════════════════════════════╗
║  Comparison Results                            ║
╚════════════════════════════════════════════════╝

Metric                         Strategy A      Strategy B          Delta
──────────────────────────────────────────────────────────────────────────
Routing Accuracy                    82.50           87.20          +4.70
Confidence Calibration              76.30           78.50          +2.20
Optimal Rate                        75.00%          85.00%        +10.00%
Expert Match Rate                   90.00%          92.50%         +2.50%

Winner: Strategy B (higher-security-weight)
Wins 4 out of 4 metrics
```

### Use Cases for A/B Testing

1. **Keyword weight tuning**: Does increasing security keyword weight improve accuracy?
2. **Threshold changes**: Should single-expert threshold be 0.70 or 0.75?
3. **Algorithm changes**: Compare keyword-based vs embedding-based routing
4. **Learning iterations**: Measure improvement after each learning cycle

## Integration with Learning System

The evaluation framework integrates with the existing MoE learning system:

```bash
# moe-learn.sh now includes evaluation in learning cycle
./llm-mesh/moe-learning/moe-learn.sh learn
```

**Learning Cycle Flow:**
```
Phase 0: Baseline Eval → Measure current quality (e.g., 82.5 accuracy)
Phase 1-2: Learn patterns, generate improvements
Phase 3: Review improvements
Phase 4: Apply improvements
Phase 5: Post-improvement Eval → Measure new quality (e.g., 87.2 accuracy)
Phase 6: Impact Analysis → Delta = +4.7 accuracy ✓
```

## Configuration

### Environment Variables

```bash
# Required for LM-as-Judge
export ANTHROPIC_API_KEY="sk-ant-..."

# Optional: Override model (default: claude-sonnet-4-5-20250929)
export LLM_MODEL="claude-sonnet-4-5-20250929"
```

### Evaluation Settings

Edit evaluation harness for tuning:
- `llm-mesh/moe-learning/evaluation/eval-router.sh`
- Temperature: 0.3 (consistent evaluation)
- Max tokens: 2048 (sufficient for detailed analysis)

## Usage Examples

### Example 1: Measure Current Routing Quality

```bash
# Quick check: How good is our routing?
./llm-mesh/moe-learning/moe-learn.sh eval
```

### Example 2: Validate Improvement After Changes

```bash
# 1. Run baseline eval
./llm-mesh/moe-learning/evaluation/eval-router.sh run

# 2. Make changes to routing-patterns.json
vim coordination/masters/coordinator/knowledge-base/routing-patterns.json

# 3. Run eval again and compare
./llm-mesh/moe-learning/evaluation/eval-router.sh run
```

### Example 3: Continuous Improvement Loop

```bash
# Weekly: Run learning cycle with evaluation
./llm-mesh/moe-learning/moe-learn.sh learn

# Expected flow:
# - Baseline: 82.5 accuracy
# - Learn from production outcomes
# - Apply improvements
# - New score: 85.3 accuracy (+2.8 improvement)
```

### Example 4: Debug Specific Routing Decision

```bash
# Evaluate single example
./llm-mesh/moe-learning/evaluation/eval-router.sh single eval-003

# Output shows:
# - How router decided
# - Judge's detailed assessment
# - Specific improvement suggestions
```

## Cost Considerations

### API Usage

Each evaluation run:
- **Examples**: 20 golden examples
- **LLM calls**: 20 calls to Claude (one per example)
- **Tokens per call**: ~2000-3000 tokens (prompt + response)
- **Total tokens**: ~40,000-60,000 tokens per run

**Cost estimate** (Claude Sonnet 4.5):
- Input: ~$0.12 per run (40k tokens @ $3/MTok)
- Output: ~$0.60 per run (40k tokens @ $15/MTok)
- **Total: ~$0.72 per evaluation run**

### Optimization

- Run evaluations strategically (not on every commit)
- Use evaluation in learning cycles (weekly/bi-weekly)
- Cache judge responses for unchanged routing patterns
- Consider smaller eval set (10 examples) for quick checks

## Roadmap

### Phase 1: Foundation ✅ (Complete)
- [x] Golden dataset with 20 examples
- [x] LM-as-Judge evaluation prompt
- [x] Evaluation harness script
- [x] A/B comparison tool
- [x] Integration with learning cycle

### Phase 1.5: Enhancement (Next 1-2 weeks)
- [ ] Expand golden dataset to 50 examples
- [ ] Auto-generate examples from production logs
- [ ] Add evaluation result visualization
- [ ] Cache judge responses for performance
- [ ] Add confidence interval calculations

### Phase 2: Advanced Metrics (2-3 weeks)
- [ ] Per-expert accuracy breakdown
- [ ] Confusion matrix (which experts get mis-routed to which)
- [ ] Difficulty-stratified metrics (easy vs hard tasks)
- [ ] Temporal trend analysis (is quality improving over time?)
- [ ] Cost-quality tradeoff analysis

### Phase 3: Automated Tuning (3-4 weeks)
- [ ] Hyperparameter optimization (keyword weights, thresholds)
- [ ] Grid search over routing parameters
- [ ] Bayesian optimization for efficient tuning
- [ ] Auto-apply improvements above quality threshold

## Troubleshooting

### Issue: "ANTHROPIC_API_KEY not set"

```bash
# Set your API key
export ANTHROPIC_API_KEY="sk-ant-your-key-here"

# Or add to .env (not committed)
echo 'ANTHROPIC_API_KEY=sk-ant-your-key-here' >> .env.local
source .env.local
```

### Issue: "Routing failed" during evaluation

**Cause**: MoE router script not found or syntax error

**Fix**:
```bash
# Check router script exists
ls coordination/masters/coordinator/lib/moe-router.sh

# Test router directly
bash coordination/masters/coordinator/lib/moe-router.sh
```

### Issue: Low routing accuracy scores

**Cause**: Current routing algorithm needs improvement

**Fix**:
```bash
# 1. Run learning cycle to improve
./llm-mesh/moe-learning/moe-learn.sh learn

# 2. Review learning insights in results
cat coordination/evaluation/results/eval-run-latest.jsonl | \
  jq '.judgment.learning_insights[]'

# 3. Apply suggested improvements manually or via learning system
```

### Issue: Judge evaluation too slow

**Cause**: 20 sequential LLM calls take time (~2-3 min total)

**Solutions**:
- **Quick checks**: Use smaller eval set (10 examples)
- **Caching**: Results are saved, re-use for unchanged patterns
- **Parallel calls**: Coming in Phase 1.5 (5x speedup)

## Best Practices

### 1. Run Evaluation Before Major Changes

```bash
# Baseline before implementing new feature
./llm-mesh/moe-learning/moe-learn.sh eval

# Implement feature...

# Validate no regression
./llm-mesh/moe-learning/moe-learn.sh eval
```

### 2. Expand Dataset Gradually

- Start with 20 examples (current)
- Add 5-10 examples per week
- Target 50-100 for robust evaluation
- Focus on edge cases and failure modes

### 3. Track Trends Over Time

```bash
# Keep evaluation summaries
ls coordination/evaluation/results/eval-summary-*.json

# Compare across weeks
# Week 1: 82.5 accuracy
# Week 2: 85.3 accuracy (+2.8)
# Week 3: 87.1 accuracy (+1.8)
```

### 4. Use Learning Insights

Judge provides actionable insights:
```json
"learning_insights": [
  "Strengthen keyword matching for 'CI/CD', 'pipeline' → cicd-master",
  "Add negative indicator for development: 'pipeline setup'"
]
```

**Act on them:**
- Add suggested keywords to `routing-patterns.json`
- Adjust keyword weights based on patterns
- Validate improvement with new eval run

## Next Steps

You have a working Agent Ops foundation! Here's what to do next:

### Immediate (Today)
1. ✅ Run first evaluation: `./llm-mesh/moe-learning/moe-learn.sh eval`
2. ✅ Review results in `coordination/evaluation/results/`
3. ✅ Understand baseline routing quality

### This Week
1. Add 10 more examples to golden dataset (focus on edge cases)
2. Run learning cycle with eval: `./llm-mesh/moe-learning/moe-learn.sh learn`
3. Measure improvement from learning

### Next Week
1. Expand dataset to 40-50 examples
2. Set up automated weekly evaluation runs
3. Track trend: Is quality improving?

### Next Phase
Decision point: Continue with **Phase 2 (Agent Identity)** or **Phase 3 (Gateway)** from the [Implementation Review](../../docs/AGENT-ARCHITECTURE-IMPLEMENTATION-REVIEW.md).

---

**Questions?** Review the [Agent Architecture Implementation Review](../../docs/AGENT-ARCHITECTURE-IMPLEMENTATION-REVIEW.md) for strategic context.

**Ready for next phase?** Let's build the Gateway/Control Plane! 🚀
