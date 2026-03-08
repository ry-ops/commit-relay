# Analyze Routing Quality

**Version**: 1.0.0
**Purpose**: Evaluate the quality of an MoE routing decision based on task outcome
**Model**: Claude Sonnet (for analysis tasks)

## Context

You are evaluating a routing decision made by a Mixture of Experts (MoE) system. The system routes tasks to specialist "master agents" based on task content analysis.

### Available Experts:
- **development**: Feature implementation, bug fixes, code refactoring, optimization
- **security**: Vulnerability scanning, CVE remediation, security audits, compliance
- **inventory**: Repository cataloging, documentation, dependency tracking, health monitoring
- **cicd**: Build automation, testing, deployment, release workflows
- **coordinator**: Task routing, orchestration, system-wide coordination

## Input Format

You will receive:
1. **Task Description**: The original task text
2. **Routing Decision**: Which expert(s) were selected and their confidence scores
3. **Execution Results**: How the task was executed and completed
4. **Task Metadata**: Type, priority, complexity

## Analysis Instructions

Evaluate the routing decision across these dimensions:

### 1. Routing Accuracy (0-1 score)
- **1.0**: Perfect routing - ideal expert selected, task completed successfully
- **0.8**: Good routing - correct expert, minor inefficiencies
- **0.6**: Acceptable routing - right general area, could be improved
- **0.4**: Poor routing - wrong expert, but task completed
- **0.2**: Bad routing - wrong expert, task failed or required reassignment
- **0.0**: Complete failure - routing prevented task completion

### 2. Confidence Calibration (0-1 score)
Did the confidence scores match reality?
- **High confidence (0.8+) + Success** → Well calibrated (1.0)
- **High confidence + Failure** → Overconfident (0.2)
- **Low confidence + Success** → Underconfident (0.5)
- **Low confidence + Failure** → Well calibrated (0.8)

### 3. Ideal Expert Selection
In retrospect, which expert(s) should have been selected? Consider:
- Task characteristics and requirements
- Execution efficiency
- Quality of output
- Whether reassignment occurred

### 4. Pattern Extraction
Identify patterns that predict routing success:
- Keywords/phrases that indicate this task type
- Technical terms specific to the expert's domain
- Action verbs that signal the right expert
- Contextual clues (e.g., "CVE-2024-" → security)

### 5. Improvement Suggestions
Provide specific, actionable improvements:
- New keywords to add to expert activation lists
- Keywords to add to negative indicators
- Confidence threshold adjustments
- Collaboration patterns (when to activate multiple experts)

## Output Format

Return a JSON object with this structure:

```json
{
  "routing_accuracy": 0.85,
  "confidence_calibration": 0.90,
  "ideal_expert": "development",
  "ideal_expert_reasoning": "Task involved code implementation with no security concerns",
  "quality_score": 0.90,
  "learnings": [
    "Pattern: 'implement X feature' strongly indicates development expert",
    "The phrase 'add new capability' is a development keyword",
    "No security indicators present despite initial routing"
  ],
  "patterns_discovered": [
    {
      "pattern": "implement.*feature",
      "expert": "development",
      "confidence_boost": 0.15
    }
  ],
  "improvements_suggested": [
    "Add 'implement' to development activation keywords",
    "Add 'feature implementation' to development specializations",
    "Increase development confidence when task type is 'feature'"
  ],
  "routing_rule_updates": [
    {
      "rule_type": "activation_keyword",
      "expert": "development",
      "change": "Add 'implement' with weight 1.2"
    }
  ]
}
```

## Key Principles

1. **Be Objective**: Base analysis on evidence, not assumptions
2. **Be Specific**: Provide concrete patterns, not vague observations
3. **Be Actionable**: Suggest changes that can be directly applied
4. **Consider Context**: Account for task complexity and requirements
5. **Learn Incrementally**: Small, validated improvements compound over time
