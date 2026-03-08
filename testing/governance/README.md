# MoE Governance Test Suite

## Overview

Comprehensive testing framework for the Mixture of Experts (MoE) governance system, validating risk assessment, routing accuracy, audit trails, approval workflows, and compliance monitoring.

## Quick Start

```bash
# Run the complete test suite
./tests/governance/run-all-governance-tests.sh

# Run individual test phases
./tests/governance/create-governance-test-tasks.sh      # Create test tasks
./tests/governance/governance-test-framework.sh         # Test framework
./tests/governance/route-test-tasks.sh                  # Route through MoE
./tests/governance/validate-governance.sh               # Validate controls
```

## Test Suite Components

### 1. Governance Test Framework

**File**: `governance-test-framework.sh`

Core testing framework that validates:
- Risk assessment for low/medium/high/critical tasks
- Approval workflow logic (auto-approve vs. require approval)
- Audit trail generation and integrity
- Circuit breaker triggers and thresholds
- Service auto-recovery mechanisms
- Compliance monitoring

**Usage**:
```bash
./governance-test-framework.sh
```

**Output**:
- Test report: `results/governance-test-report.json`
- Audit trail: `results/governance-audit-trail.jsonl`

### 2. Test Task Generator

**File**: `create-governance-test-tasks.sh`

Generates 12 test tasks across all risk levels:
- 3 low risk tasks (documentation, feature, bug-fix)
- 3 medium risk tasks (config, refactor, optimization)
- 3 high risk tasks (security-fix, deploy, migration)
- 3 critical risk tasks (CVE, security-cleanup, security-audit)

**Usage**:
```bash
./create-governance-test-tasks.sh
```

**Output**: `results/task-*.json` (12 task files)

### 3. MoE Router Integration

**File**: `route-test-tasks.sh`

Routes all test tasks through the MoE router and captures:
- Routing decisions (which master)
- Confidence scores
- Risk level associations

**Usage**:
```bash
./route-test-tasks.sh
```

**Output**: `results/routing-results.jsonl`

### 4. Governance Validator

**File**: `validate-governance.sh`

Validates governance controls by checking:
- Routing accuracy for security/critical tasks
- Risk assessment correctness
- Audit trail completeness and integrity
- Approval workflow requirements
- Routing confidence levels
- Compliance with governance framework

**Usage**:
```bash
./validate-governance.sh
```

**Output**: `results/validation-report.json`

### 5. Master Test Runner

**File**: `run-all-governance-tests.sh`

Orchestrates all test phases in sequence:
1. Create test tasks
2. Run framework tests
3. Route tasks through MoE
4. Validate governance controls
5. Generate comprehensive summary

**Usage**:
```bash
./run-all-governance-tests.sh
```

**Output**: `results/comprehensive-summary.json`

## Test Results

Results are saved to `tests/governance/results/`:

```
results/
├── task-low-001.json                    # Low risk test tasks (3)
├── task-medium-001.json                 # Medium risk test tasks (3)
├── task-high-001.json                   # High risk test tasks (3)
├── task-critical-001.json               # Critical risk test tasks (3)
├── governance-test-report.json          # Framework test summary
├── routing-results.jsonl                # MoE routing decisions
├── governance-audit-trail.jsonl         # Complete audit trail
├── validation-report.json               # Validation results
└── comprehensive-summary.json           # Executive summary
```

## Test Scenarios

### Low Risk Tasks

| Task | Type | Description | Expected Master |
|------|------|-------------|-----------------|
| task-low-001 | documentation | Update README with governance docs | inventory |
| task-low-002 | feature | User profile avatar upload | development |
| task-low-003 | bug-fix | CSS alignment issue | development |

### Medium Risk Tasks

| Task | Type | Description | Expected Master |
|------|------|-------------|-----------------|
| task-medium-001 | config-update | Database connection pooling | development |
| task-medium-002 | refactor | Authentication middleware | development |
| task-medium-003 | optimization | API response times | development |

### High Risk Tasks

| Task | Type | Description | Expected Master |
|------|------|-------------|-----------------|
| task-high-001 | security-fix | Patch auth vulnerability | security |
| task-high-002 | deploy | Production deployment | cicd |
| task-high-003 | migration | Database schema migration | cicd |

### Critical Risk Tasks

| Task | Type | Description | Expected Master |
|------|------|-------------|-----------------|
| task-critical-001 | cve-2024-9999 | Emergency security patch | security |
| task-critical-002 | security-cleanup | Delete vulnerable code | security |
| task-critical-003 | security-audit | Comprehensive security scan | security |

## Governance Controls Tested

### 1. Risk Assessment

Tests the risk scoring algorithm:

```bash
Risk Score Calculation:
- High risk keywords (+30): security, vulnerability, cve, critical, production, deploy, delete
- Medium risk keywords (+15): refactor, update, modify, change, config, settings
- Low risk keywords (baseline): feature, bug-fix, documentation, test

Risk Levels:
- Critical: Score >= 60
- High: Score 40-59
- Medium: Score 20-39
- Low: Score < 20
```

### 2. MoE Routing

Tests type-based routing accuracy:

```bash
Expected Routing Patterns:
- security-*, cve-*, vulnerability-* → security master
- feature, bug-fix, refactor, optimization → development master
- documentation, inventory, catalog → inventory master
- deploy, build, release, migration → cicd master
```

### 3. Audit Trail

Validates audit trail:
- All governance decisions logged
- Timestamps present
- JSON structure valid
- Required fields populated

### 4. Approval Workflows

Tests approval logic:
- Critical/High risk → Requires approval
- Medium risk → Recommended for review
- Low risk → Auto-approved

### 5. Circuit Breaker

Validates failure handling:
- Failure threshold: 5 failures
- States: CLOSED → OPEN → HALF_OPEN
- Auto-recovery timeout: 30 seconds

### 6. Compliance

Checks required components:
- MoE router exists
- Documentation present
- Circuit breaker documented
- Test framework operational

## Expected Results

### Pass Criteria

A governance control is considered operational if:

1. **Risk Assessment**: 90%+ accuracy identifying risk levels
2. **MoE Routing**: 80%+ correct master selection
3. **Audit Trail**: 100% entries valid JSON with timestamps
4. **Approval Workflows**: Correct gating based on risk level
5. **Circuit Breaker**: Triggers at threshold, recovers automatically
6. **Compliance**: All required components present

### Known Issues

1. **CI/CD Routing Patterns Missing**
   - Deploy and migration types not recognized
   - Routes to development instead of cicd
   - **Fix**: Add routing patterns to moe-router.sh

2. **Security Pattern Gaps**
   - `security-cleanup` not recognized as security task
   - **Fix**: Expand security type patterns

3. **Audit Trail Formatting**
   - Some entries contain ANSI color codes
   - **Fix**: Redirect log output to stderr

## Troubleshooting

### Issue: Tests fail with "jq: parse error"

**Cause**: JSON files contain non-JSON output (log messages)

**Solution**: Ensure all log output goes to stderr:
```bash
log_info "Message" >&2
```

### Issue: Routing results show 0% confidence

**Cause**: MoE router not finding type patterns

**Solution**: Check if task type is recognized in moe-router.sh:
```bash
./coordination/masters/coordinator/lib/moe-router.sh test-id "type: description"
```

### Issue: Audit trail has invalid JSON

**Cause**: ANSI color codes in output

**Solution**: Strip color codes or redirect to stderr:
```bash
# Option 1: Strip colors
sed 's/\x1b\[[0-9;]*m//g' file.jsonl

# Option 2: Redirect logs
echo -e "${BLUE}[INFO]${NC} Message" >&2
```

## Integration with MoE System

### Running in Production

1. Enable governance logging in MoE router:
```bash
export MOE_GOVERNANCE_AUDIT=true
export MOE_AUDIT_LOG="/path/to/audit.jsonl"
```

2. Configure approval thresholds:
```bash
export MOE_APPROVAL_THRESHOLD_HIGH=80
export MOE_APPROVAL_THRESHOLD_CRITICAL=95
```

3. Monitor audit trail:
```bash
tail -f /path/to/audit.jsonl | jq
```

### Continuous Testing

Run governance tests nightly:

```bash
# Add to crontab
0 2 * * * /path/to/tests/governance/run-all-governance-tests.sh >> /var/log/governance-tests.log 2>&1
```

## Documentation

- **Test Report**: `/docs/governance-testing-report.md`
- **MoE Architecture**: `/docs/MOE-ARCHITECTURE.md`
- **Circuit Breaker**: `/docs/circuit-breaker.md`
- **Worker Lifecycle**: `/docs/WORKER-LIFECYCLE.md`

## Version History

- **v1.0.0** (2025-11-11): Initial release
  - Risk assessment testing
  - MoE routing validation
  - Audit trail verification
  - Approval workflow simulation
  - Circuit breaker testing
  - Compliance monitoring

## Contributing

To add new governance tests:

1. Add test function to `governance-test-framework.sh`
2. Update test count in report generation
3. Add test scenario to `create-governance-test-tasks.sh`
4. Update validation logic in `validate-governance.sh`
5. Document in this README

## License

Part of the commit-relay project. See main LICENSE file.

---

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>
