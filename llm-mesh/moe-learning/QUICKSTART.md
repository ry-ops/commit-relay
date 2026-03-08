# MoE Learning System - Quick Start Guide

Get started with the MoE Learning System in 5 minutes!

## Prerequisites

- commit-relay installed and running
- (Optional) Anthropic API key for LLM analysis

## Step 1: Configure LLM Access (Optional)

For real LLM analysis, set up your API key:

```bash
# Add to ~/.bashrc or ~/.zshrc
export ANTHROPIC_API_KEY="sk-ant-your-key-here"
export LLM_PROVIDER="anthropic"
export LLM_MODEL="claude-sonnet-4"
```

Without an API key, the system uses mock responses (good for testing).

## Step 2: Track Your First Outcome

When a task completes, track its outcome:

```bash
cd /path/to/commit-relay/llm-mesh/moe-learning

# Successful task
./moe-learn.sh track task-123 completed 0.9

# Failed task
./moe-learn.sh track task-456 failed 0.3

# Reassigned task
./moe-learn.sh track task-789 reassigned 0.5
```

## Step 3: Check Status

See what's been tracked:

```bash
./moe-learn.sh status
```

Output:
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  MoE Learning System Status
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Decisions Analyzed: 0
Successful Routings: 0
Failed Routings: 0

Recent Activity:
Total routing decisions tracked: 3
Unanalyzed outcomes: 3

Metrics:
No metrics available yet.
```

## Step 4: Run First Learning Cycle

After tracking 5-10 outcomes:

```bash
./moe-learn.sh learn
```

This will:
1. Analyze outcomes with LLM
2. Extract routing patterns
3. Generate improvements
4. Prompt you to apply them

## Step 5: Review Improvements

Before applying, review what's being suggested:

```bash
cat catalog/learned-patterns.json | jq '.routing_improvements[]'
```

Example improvement:
```json
{
  "improvement_id": "imp-001",
  "priority": "high",
  "improvement_type": "add_keyword",
  "expert": "security",
  "changes": {
    "category": "activation_keywords",
    "add": ["CVE", "vulnerability scan"]
  },
  "expected_impact": "Increase security confidence from 0.45 to 0.75"
}
```

## Step 6: Apply Improvements

If improvements look good:

```bash
./moe-learn.sh apply
```

This updates `coordination/masters/coordinator/knowledge-base/routing-patterns.json` with:
- New keywords
- Adjusted confidence thresholds
- Improved collaboration patterns

## Step 7: Monitor Impact

Track routing accuracy over time:

```bash
# After applying improvements
./moe-learn.sh stats
```

Check if routing accuracy improves!

## Common Workflows

### Daily Task Tracking

Track outcomes as tasks complete:

```bash
# Hook into your task completion
./moe-learn.sh track $TASK_ID completed 0.9
```

### Weekly Learning Cycle

Run learning every week:

```bash
# Sunday night cron job
0 2 * * 0 cd /path/to/llm-mesh/moe-learning && ./moe-learn.sh learn
```

### Rollback Bad Changes

If improvements degrade performance:

```bash
./moe-learn.sh rollback
```

## Understanding Metrics

### Routing Accuracy (0-1)

- **1.0**: Perfect routing - right expert every time
- **0.8**: Good routing - mostly correct
- **0.6**: Acceptable routing - room for improvement
- **<0.5**: Poor routing - needs learning

### Confidence Calibration (0-1)

- **1.0**: Confidence scores match reality perfectly
- **0.5**: Underconfident or overconfident
- **0.2**: Severely miscalibrated

### Quality Score (0-1)

- **0.9+**: Excellent task completion
- **0.7-0.9**: Good completion
- **0.5-0.7**: Acceptable but could improve
- **<0.5**: Poor completion quality

## Troubleshooting

### No API Key Set

```bash
# Error: Mock responses being used
# Solution: Set ANTHROPIC_API_KEY or use mock mode for testing
export ANTHROPIC_API_KEY="your-key"
```

### No Outcomes Tracked

```bash
# Error: No routing decisions tracked yet
# Solution: Track some task outcomes first
./moe-learn.sh track task-1 completed 0.9
```

### Improvements Not Applied

```bash
# Check status of improvements
./moe-learn.sh stats

# Manually apply
./moe-learn.sh apply
```

### Routing Accuracy Decreased

```bash
# Rollback to previous routing patterns
./moe-learn.sh rollback

# Review what changed
diff routing-patterns.json.backup-* routing-patterns.json
```

## Next Steps

1. **Integrate with Task Queue**: Automatically track outcomes
2. **Dashboard Integration**: Visualize learning progress
3. **Custom Prompts**: Tune prompts for your specific use case
4. **Scheduled Learning**: Set up automated learning cycles

## Example Integration

```bash
#!/bin/bash
# task-complete-hook.sh
# Called when a task completes

TASK_ID="$1"
STATUS="$2"  # completed, failed, reassigned
QUALITY="${3:-0.5}"

# Track outcome
/path/to/llm-mesh/moe-learning/moe-learn.sh track \
    "$TASK_ID" "$STATUS" "$QUALITY"

# Run learning if we have 10+ unanalyzed outcomes
UNANALYZED=$(grep -c '"analyzed":false' \
    /path/to/llm-mesh/moe-learning/catalog/routing-decisions.jsonl)

if [ "$UNANALYZED" -ge 10 ]; then
    echo "Running learning cycle (10+ unanalyzed outcomes)..."
    /path/to/llm-mesh/moe-learning/moe-learn.sh learn
fi
```

## Questions?

See full documentation: `../README.md`
