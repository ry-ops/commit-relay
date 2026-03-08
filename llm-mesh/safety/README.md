# Safety & Quality - Enterprise-Grade Protection

## Overview

Phase 4 provides enterprise-grade safety filters, quality evaluators, and compliance monitoring with MoE learning to continuously improve protection.

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                    Safety Gateway                             │
│  (All LLM inputs/outputs flow through safety checks)         │
└──────┬──────────┬──────────┬──────────┬──────────────────────┘
       │          │          │          │
       ↓          ↓          ↓          ↓
   ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐
   │  PII   │ │Prompt  │ │Content │ │Secrets │
   │Detector│ │Inject  │ │Moderate│ │Detector│
   │        │ │Defense │ │        │ │        │
   └────────┘ └────────┘ └────────┘ └────────┘
       │          │          │          │
       ↓          ↓          ↓          ↓
   ┌──────────────────────────────────────────┐
   │         Quality Evaluators                │
   │  • Hallucination detection                │
   │  • Output validation                      │
   │  • Format compliance                      │
   └──────────────────────────────────────────┘
       │
       ↓
   ┌──────────────────────────────────────────┐
   │      Compliance Monitoring                │
   │  • Audit logging                          │
   │  • Access control                         │
   │  • Governance checks                      │
   └──────────────────────────────────────────┘
       │
       ↓
   ┌──────────────────────────────────────────┐
   │       MoE Learning & Optimization         │
   │  • Filter performance tracking            │
   │  • False positive reduction               │
   │  • Detection accuracy improvement         │
   └──────────────────────────────────────────┘
```

## Directory Structure

```
llm-mesh/safety/
├── README.md                      # This file
├── filters/
│   ├── pii-detector.sh            # PII detection & redaction
│   ├── prompt-injection-defense.sh # Injection attack prevention
│   ├── content-moderator.sh       # Content moderation
│   └── secrets-detector.sh        # API keys, tokens, passwords
├── evaluators/
│   ├── hallucination-detector.sh  # Detect fabricated information
│   ├── output-validator.sh        # Validate output format/quality
│   └── quality-scorer.sh          # Score output quality
├── compliance/
│   ├── audit-logger.sh            # Complete audit trail
│   ├── access-control.sh          # Permission checking
│   └── governance-checker.sh      # Policy enforcement
├── learning/
│   ├── safety-patterns.jsonl      # Learned safety patterns
│   ├── filter-performance.jsonl   # Filter effectiveness
│   └── improve-filters.sh         # MoE learning for filters
├── schemas/
│   ├── safety-check.json          # Safety check schema
│   ├── quality-score.json         # Quality scoring schema
│   └── audit-log.json             # Audit log schema
└── safety-gateway.sh              # Main safety gateway
```

## Safety Filters

### 1. PII Detector

Detects and redacts personally identifiable information:

**Detects**:
- Email addresses
- Phone numbers
- Credit card numbers
- Social Security Numbers
- IP addresses
- Physical addresses
- Names (when in sensitive contexts)

**Actions**:
- Detect: Flag PII presence
- Redact: Replace with `[PII_REDACTED]`
- Alert: Notify security team
- Log: Record PII detection for compliance

**MoE Learning**:
- Tracks false positives/negatives
- Learns context-specific PII patterns
- Optimizes detection accuracy

### 2. Prompt Injection Defense

Prevents malicious prompt manipulation:

**Detects**:
- System prompt overrides
- Jailbreak attempts
- Role confusion attacks
- Delimiter injection
- Instruction bypass

**Actions**:
- Block: Reject malicious inputs
- Sanitize: Clean suspicious patterns
- Alert: Flag potential attacks
- Log: Track attack attempts

**MoE Learning**:
- Learns new attack patterns
- Reduces false positives
- Improves defense effectiveness

### 3. Content Moderator

Filters inappropriate or harmful content:

**Detects**:
- Hate speech
- Violence
- Self-harm content
- Illegal activities
- Harassment
- Spam

**Actions**:
- Filter: Block harmful content
- Flag: Mark for review
- Score: Rate content safety (0-1)

**MoE Learning**:
- Learns context-appropriate filtering
- Balances safety vs. false positives
- Adapts to policy changes

### 4. Secrets Detector

Prevents credential leakage:

**Detects**:
- API keys
- Access tokens
- Passwords
- Private keys
- Database credentials
- OAuth tokens

**Actions**:
- Block: Prevent credential exposure
- Redact: Mask secrets
- Alert: Immediate security notification
- Rotate: Trigger credential rotation

**MoE Learning**:
- Learns new credential patterns
- Reduces false positives on code examples
- Improves detection accuracy

## Quality Evaluators

### 1. Hallucination Detector

Detects fabricated or unreliable information:

**Methods**:
- **Consistency Check**: Cross-reference with known facts
- **Confidence Analysis**: Low confidence = potential hallucination
- **Source Verification**: Check if claims are grounded
- **Pattern Detection**: Known hallucination patterns

**Scoring**:
- 0.0-0.3: High hallucination risk
- 0.4-0.6: Moderate risk (needs verification)
- 0.7-0.9: Low risk (likely accurate)
- 0.9-1.0: Very high confidence

**MoE Learning**:
- Learns hallucination patterns per model
- Tracks accuracy by task type
- Improves detection over time

### 2. Output Validator

Validates output meets requirements:

**Checks**:
- **Format Compliance**: JSON, markdown, etc.
- **Completeness**: All required fields present
- **Correctness**: Values in valid ranges
- **Consistency**: Internal consistency
- **Schema Validation**: Matches expected schema

**Actions**:
- Pass: Output meets all requirements
- Fail: Output rejected
- Retry: Request regeneration
- Fix: Attempt automatic correction

**MoE Learning**:
- Learns common validation failures
- Improves fix success rate
- Optimizes retry strategies

### 3. Quality Scorer

Scores overall output quality:

**Dimensions**:
- **Accuracy**: Factually correct
- **Completeness**: Fully answers question
- **Relevance**: On-topic and useful
- **Clarity**: Well-written and clear
- **Format**: Properly formatted

**Scoring**:
- Overall: 0.0-1.0
- Per dimension: 0.0-1.0
- Confidence: How certain is the score

**MoE Learning**:
- Learns quality patterns per task type
- Calibrates scores against human feedback
- Improves scoring accuracy

## Compliance Monitoring

### 1. Audit Logger

Complete audit trail of all operations:

**Logs**:
- All LLM calls (inputs, outputs, metadata)
- All safety filter activations
- All quality evaluations
- All access control decisions
- All configuration changes

**Features**:
- **Immutable**: Append-only logs
- **Searchable**: Full-text search
- **Exportable**: JSON, CSV formats
- **Retention**: Configurable retention periods
- **Encryption**: Encrypted at rest

**Compliance**:
- SOC 2 Type II
- GDPR Article 30
- HIPAA audit requirements
- ISO 27001

### 2. Access Control

Role-based access control:

**Roles**:
- **Admin**: Full system access
- **Developer**: Code and configuration
- **Security**: Safety and compliance
- **Auditor**: Read-only access
- **Agent**: Automated agent access

**Permissions**:
- Read/write catalog
- Execute LLM calls
- Modify safety filters
- Access audit logs
- Change configuration

**MoE Learning**:
- Detects unusual access patterns
- Learns normal behavior per role
- Flags suspicious activity

### 3. Governance Checker

Enforces organizational policies:

**Policies**:
- **Budget**: LLM spending limits
- **Rate Limits**: Calls per minute/hour/day
- **Content Policies**: Allowed content types
- **Data Residency**: Where data can be processed
- **Model Policies**: Which models can be used

**Enforcement**:
- **Block**: Reject policy violations
- **Warn**: Flag potential violations
- **Log**: Record policy checks
- **Alert**: Notify administrators

**MoE Learning**:
- Learns policy violation patterns
- Optimizes enforcement
- Suggests policy improvements

## MoE Learning for Safety

Safety filters improve over time:

### Learning Cycle

```
1. Filter Activation
   - PII detector finds potential email
   - Flags as PII, redacts

2. Track Outcome
   - Was it really PII? (manual review / feedback)
   - False positive or true positive?

3. Analyze Patterns
   - What patterns cause false positives?
   - What patterns are missed?

4. Learn & Improve
   - Update detection rules
   - Adjust confidence thresholds
   - Add new patterns

5. Measure Impact
   - Track accuracy improvement
   - Monitor false positive rate
   - Validate effectiveness
```

### Safety Metrics

```jsonl
{
  "filter": "pii-detector",
  "timestamp": "2025-11-15T15:00:00-0600",
  "total_checks": 1000,
  "detections": 45,
  "true_positives": 42,
  "false_positives": 3,
  "false_negatives": 2,
  "accuracy": 0.95,
  "precision": 0.93,
  "recall": 0.95
}
```

## Integration with Phases 1-3

### With Phase 1 (MoE Learning)
- Safety checks before routing decisions
- Quality scoring of routing outcomes
- Compliance logging of all routing

### With Phase 2 (LLM Gateway)
- Safety filters on all LLM inputs/outputs
- Model selection considers safety requirements
- Cost tracking includes safety overhead

### With Phase 3 (Catalog)
- Agents cataloged with safety requirements
- Tools cataloged with permission levels
- Prompts validated for safety

### Complete Flow

```
1. Task Input
   ↓
2. Safety Gateway: Input Filters
   - PII detection
   - Prompt injection defense
   - Content moderation
   ↓
3. Phase 3: Route to Agent (catalog)
   ↓
4. Phase 2: Select LLM Model (gateway)
   ↓
5. Access Control: Check Permissions
   ↓
6. Execute LLM Call
   ↓
7. Safety Gateway: Output Filters
   - PII detection
   - Secrets detection
   - Content moderation
   ↓
8. Quality Evaluation
   - Hallucination detection
   - Output validation
   - Quality scoring
   ↓
9. Governance Check
   - Budget compliance
   - Rate limit check
   - Policy enforcement
   ↓
10. Audit Logging
    - Record complete transaction
    - Log all safety checks
    - Track compliance
    ↓
11. Phase 1: Track Outcome & Learn
    - Update routing patterns
    - Update safety patterns
    - Update quality patterns
```

## Usage

### Basic Safety Check

```bash
# Check input for safety
./safety-gateway.sh check-input "User prompt here..."
# Returns: {safe: true/false, filters_triggered: [...], redacted_text: "..."}

# Check output for safety
./safety-gateway.sh check-output "LLM response here..."
# Returns: {safe: true/false, quality_score: 0.95, issues: [...]}
```

### Quality Evaluation

```bash
# Score output quality
./evaluators/quality-scorer.sh "LLM response" "expected output"
# Returns: {quality: 0.95, accuracy: 0.98, completeness: 0.92, ...}

# Detect hallucinations
./evaluators/hallucination-detector.sh "LLM response" "source context"
# Returns: {hallucination_risk: 0.15, confidence: 0.85, concerns: [...]}
```

### Compliance

```bash
# Check audit logs
./compliance/audit-logger.sh query --date "2025-11-15" --type "llm_call"

# Verify access
./compliance/access-control.sh check "user@example.com" "catalog" "read"
# Returns: {allowed: true, role: "developer"}

# Check governance
./compliance/governance-checker.sh check-budget
# Returns: {current: $45.23, limit: $100.00, status: "ok"}
```

## Configuration

### Safety Policies

```json
{
  "pii_detection": {
    "enabled": true,
    "action": "redact",
    "alert_on_detection": true,
    "patterns": ["email", "phone", "ssn", "credit_card"]
  },
  "prompt_injection": {
    "enabled": true,
    "action": "block",
    "alert_on_attempt": true
  },
  "content_moderation": {
    "enabled": true,
    "threshold": 0.7,
    "categories": ["hate", "violence", "self_harm"]
  },
  "quality_requirements": {
    "minimum_quality_score": 0.7,
    "hallucination_threshold": 0.3,
    "require_validation": true
  }
}
```

## Next Steps

1. Implement all safety filters
2. Build quality evaluators
3. Create compliance monitoring
4. Add MoE learning for safety
5. Test complete system end-to-end
6. Validate enterprise readiness
