# Suggest Routing Improvements

**Version**: 1.0.0
**Purpose**: Analyze learned patterns and suggest concrete routing system improvements
**Model**: Claude Sonnet (for strategic analysis)

## Context

You are analyzing accumulated routing patterns and outcomes to suggest systematic improvements to the MoE routing system.

## Input Format

You will receive:
1. **Current Routing Patterns**: Expert definitions with keywords, confidence boosters, negative indicators
2. **Learned Patterns**: Success/failure patterns from historical routing decisions
3. **Performance Metrics**: Routing accuracy, confidence calibration, expert utilization
4. **Recent Failures**: Specific routing decisions that failed or needed reassignment

## Analysis Instructions

### 1. Identify Gaps
Where is the routing system underperforming?
- Experts with low confidence scores
- High reassignment rates
- Poor confidence calibration
- Specific task types consistently misrouted

### 2. Pattern Analysis
What patterns emerge from successful vs. failed routings?
- Keywords present in successful routings but missing from expert profiles
- False positive keywords (trigger expert but shouldn't)
- Missing collaboration patterns
- Threshold misconfigurations

### 3. Expert Profile Refinement
How should expert profiles be updated?
- **Activation Keywords**: Add/remove keywords that predict expert success
- **Confidence Boosters**: Terms that strongly indicate this expert
- **Negative Indicators**: Terms that predict expert will fail
- **Specializations**: Refined description of expert capabilities

### 4. Threshold Tuning
Should routing thresholds be adjusted?
- **Single Expert Threshold** (currently 0.8): Too high/low?
- **Multi-Expert Threshold** (currently 0.6): Appropriate?
- **Minimum Activation** (currently 0.3): Catching the right cases?

### 5. Collaboration Patterns
When should multiple experts be activated?
- Identify task patterns that benefit from parallel expert activation
- Define sequential workflows (expert A → expert B)
- Establish voting patterns for ambiguous tasks

## Improvement Types

### Type 1: Keyword Additions
```json
{
  "improvement_type": "add_keyword",
  "expert": "development",
  "keyword_category": "activation_keywords",
  "keyword": "implement",
  "rationale": "98% of tasks with 'implement' succeeded with development expert",
  "expected_impact": "Increase development confidence by ~15% on implementation tasks"
}
```

### Type 2: Confidence Adjustments
```json
{
  "improvement_type": "confidence_adjustment",
  "expert": "security",
  "adjustment": {
    "type": "boost_on_pattern",
    "pattern": "CVE-\\d{4}-\\d+",
    "boost_amount": 0.25,
    "rationale": "CVE pattern is 100% accurate predictor of security tasks"
  }
}
```

### Type 3: Threshold Tuning
```json
{
  "improvement_type": "threshold_adjustment",
  "threshold_name": "single_expert",
  "current_value": 0.8,
  "proposed_value": 0.75,
  "rationale": "Current threshold too conservative, causing unnecessary multi-expert activations"
}
```

### Type 4: Collaboration Rules
```json
{
  "improvement_type": "collaboration_rule",
  "pattern": "security.*vulnerability.*fix",
  "experts": ["security", "development"],
  "strategy": "sequential",
  "workflow": "security scans → development fixes",
  "rationale": "Security + development collaboration has 95% success rate on vulnerability fixes"
}
```

### Type 5: Negative Indicators
```json
{
  "improvement_type": "add_negative_indicator",
  "expert": "development",
  "pattern": "CVE|vulnerability scan",
  "rationale": "Development incorrectly activated on pure security scan tasks"
}
```

## Output Format

```json
{
  "analysis_summary": {
    "overall_routing_accuracy": 0.76,
    "main_issues": [
      "Security expert underutilized (only 0.45 avg confidence)",
      "Development over-activated on documentation tasks",
      "Poor confidence calibration on complex tasks"
    ],
    "key_opportunities": [
      "Add type-based routing rules for 20% accuracy boost",
      "Refine security keywords for better CVE detection",
      "Implement collaboration rule for security-dev tasks"
    ]
  },
  "improvements": [
    {
      "improvement_id": "imp-001",
      "priority": "high",
      "improvement_type": "add_keyword",
      "expert": "security",
      "changes": {
        "category": "activation_keywords",
        "add": ["CVE", "vulnerability", "security scan", "audit"]
      },
      "expected_impact": "Increase security confidence from 0.45 to 0.75 on security tasks",
      "validation_strategy": "Test on next 10 security-related tasks"
    },
    {
      "improvement_id": "imp-002",
      "priority": "medium",
      "improvement_type": "add_negative_indicator",
      "expert": "development",
      "changes": {
        "category": "negative_indicators",
        "add": ["document only", "catalog only", "list repositories"]
      },
      "expected_impact": "Reduce false development activations by 30%",
      "validation_strategy": "Monitor development confidence on documentation tasks"
    }
  ],
  "validation_plan": {
    "test_cases": [
      {
        "task_description": "Scan for CVE-2024-12345 vulnerability",
        "expected_primary": "security",
        "expected_confidence": ">= 0.85"
      }
    ],
    "success_criteria": "Routing accuracy improves from 76% to >= 85% over next 20 tasks"
  }
}
```

## Key Principles

1. **Data-Driven**: Base all suggestions on actual routing outcomes
2. **Incremental**: Propose small, testable improvements
3. **Measurable**: Define clear success metrics for each improvement
4. **Reversible**: Improvements should be easy to roll back if ineffective
5. **Prioritized**: Focus on high-impact, low-risk changes first
