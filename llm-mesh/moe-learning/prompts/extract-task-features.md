# Extract Task Features

**Version**: 1.0.0
**Purpose**: Extract structured features from task descriptions for routing analysis
**Model**: Claude Haiku (for fast feature extraction)

## Context

You are analyzing a task description to extract features that help route it to the right expert. This analysis happens BEFORE routing to enhance the MoE decision.

## Input Format

You will receive a task description (plain text).

## Extraction Instructions

Extract these features:

### 1. Domain Classification
What domain does this task belong to? (can be multiple)
- `code_development`: Writing, modifying, or improving code
- `security`: Security scanning, vulnerability remediation, compliance
- `documentation`: Creating or updating documentation
- `infrastructure`: CI/CD, deployment, build systems
- `analysis`: Investigation, research, understanding codebase
- `testing`: Writing or running tests
- `monitoring`: Health checks, metrics, observability

### 2. Action Verbs
What actions are requested? Examples:
- implement, create, add, build, develop
- fix, repair, resolve, debug
- refactor, optimize, improve, enhance
- scan, audit, check, validate
- document, catalog, list, describe
- deploy, release, build, test

### 3. Technical Terms
Domain-specific terminology:
- Language/framework names (JavaScript, React, Node.js)
- Security terms (CVE, vulnerability, XSS, CSRF)
- Infrastructure terms (Docker, Kubernetes, CI/CD)
- Development terms (API, endpoint, function, class)

### 4. Complexity Indicators
Assess task complexity:
- **simple**: Single, well-defined action ("Fix typo in README")
- **moderate**: Multiple steps or moderate scope ("Add user authentication")
- **complex**: Multiple components or subsystems ("Refactor database layer")
- **very_complex**: Architecture changes or system-wide impact ("Redesign CI/CD pipeline")

### 5. Implied Expertise
What expertise is implied by the task?
- development_skills
- security_knowledge
- infrastructure_expertise
- documentation_ability
- testing_capabilities

### 6. Urgency/Priority Signals
Words indicating priority:
- critical, urgent, ASAP, emergency
- high priority, important
- when convenient, nice to have

### 7. Collaboration Signals
Does this task need multiple experts?
- "comprehensive", "full audit" → multiple experts
- "security audit of new feature" → security + development
- "deploy and monitor" → cicd + infrastructure

## Output Format

Return a JSON object:

```json
{
  "domains": ["code_development", "testing"],
  "action_verbs": ["implement", "add", "test"],
  "technical_terms": ["API", "endpoint", "Jest", "unit tests"],
  "complexity": "moderate",
  "complexity_reasoning": "Requires implementation + testing, moderate scope",
  "implied_expertise": ["development_skills", "testing_capabilities"],
  "priority_level": "medium",
  "priority_signals": ["should", "needed"],
  "collaboration_needed": false,
  "collaboration_reasoning": "Single domain task, no cross-cutting concerns",
  "key_phrases": [
    "implement new API endpoint",
    "add unit tests"
  ],
  "routing_hints": {
    "primary_expert_suggested": "development",
    "confidence": 0.85,
    "reasoning": "Code implementation with testing is core development work"
  }
}
```

## Key Principles

1. **Be Precise**: Extract actual words/phrases from the task
2. **Be Conservative**: Don't over-infer complexity or needs
3. **Be Comprehensive**: Capture all relevant features
4. **Provide Context**: Explain reasoning for complexity/priority assessments
