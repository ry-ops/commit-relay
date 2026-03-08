# Governance Architecture for Commit-Relay

**Version**: 1.0
**Date**: 2025-11-17
**Phase**: 3 (Governance Enhancement)
**Status**: Design → Implementation

---

## Executive Summary

This document defines the governance architecture for commit-relay, building on the observability and validation foundations established in Phases 0-2. The governance layer provides automated compliance checking, data quality monitoring, PII detection, and executive visibility.

**Key Objectives:**
1. Automated compliance with GDPR, SOC2, and internal policies
2. Proactive data quality issue detection
3. PII detection and protection
4. Complete audit trail for governance operations
5. Executive dashboard for governance metrics

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    GOVERNANCE LAYER                          │
│  Built on: Observability (Phase 1) + Validation (Phase 2)   │
└─────────────────────────────────────────────────────────────┘
                            │
        ┌───────────────────┼───────────────────┐
        │                   │                   │
        ▼                   ▼                   ▼
   ┌─────────┐        ┌─────────┐        ┌─────────┐
   │   PII   │        │  Data   │        │ Bypass  │
   │ Scanner │        │ Quality │        │ Auditor │
   └─────────┘        └─────────┘        └─────────┘
        │                   │                   │
        └───────────────────┼───────────────────┘
                            ▼
                   ┌─────────────────┐
                   │   Governance    │
                   │   Dashboard     │
                   └─────────────────┘
```

---

## Component 1: PII Detection Scanner

### Purpose
Automatically detect and flag Personally Identifiable Information (PII) in:
- Worker prompts and context
- Task descriptions
- Agent outputs
- Coordination files

### Detection Patterns

**High-Confidence PII:**
- Email addresses: `[\w\.-]+@[\w\.-]+\.\w+`
- Phone numbers: `\d{3}[-.]?\d{3}[-.]?\d{4}`
- SSN: `\d{3}-\d{2}-\d{4}`
- Credit cards: `\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4}`
- API keys: `(sk|pk)_[a-zA-Z0-9]{20,}`
- AWS keys: `AKIA[0-9A-Z]{16}`

**Medium-Confidence PII:**
- IP addresses: `\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}`
- Usernames: Context-dependent
- Addresses: Natural language processing

### Implementation

**File**: `coordination/governance/lib/pii-scanner.sh`

**API:**
```bash
scan_for_pii() {
    local content="$1"
    local context="${2:-unknown}"

    # Returns: JSON with findings
    # {
    #   "has_pii": true/false,
    #   "findings": [
    #     {"type": "email", "value": "redacted", "confidence": "high"},
    #     {"type": "api_key", "value": "redacted", "confidence": "high"}
    #   ],
    #   "risk_level": "high|medium|low"
    # }
}

redact_pii() {
    local content="$1"
    # Returns: content with PII redacted
}
```

**Actions on Detection:**
1. Log to governance log
2. Emit observability event
3. Flag for review if high confidence
4. Auto-redact if configured
5. Block operation if critical PII detected

---

## Component 2: Data Quality Monitoring

### Purpose
Proactively detect data quality issues before they cause system failures.

### Quality Checks

**1. Schema Validation**
- All JSON matches defined schemas
- Required fields present
- Data types correct
- Enum values valid

**2. Referential Integrity**
- Worker references valid tasks
- Tasks reference valid repositories
- Cross-references are consistent

**3. Data Freshness**
- Worker specs updated recently
- Task queue not stale
- Metrics current

**4. Data Completeness**
- No empty required fields
- Descriptions meaningful (not "TODO")
- Context has required information

**5. Data Consistency**
- Worker status matches reality
- Token budgets within limits
- Timestamps logical

### Implementation

**File**: `coordination/governance/lib/quality-monitor.sh`

**API:**
```bash
check_data_quality() {
    local file_path="$1"
    local schema_name="${2:-auto}"

    # Returns: Quality report JSON
    # {
    #   "overall_score": 95,
    #   "issues": [
    #     {"severity": "warning", "check": "freshness", "message": "..."},
    #     {"severity": "error", "check": "schema", "message": "..."}
    #   ],
    #   "passed": 18,
    #   "failed": 2
    # }
}
```

**Monitoring Daemon**: `scripts/daemons/quality-monitor-daemon.sh`
- Runs every 5 minutes
- Checks all active workers, tasks, coordination files
- Emits observability events
- Updates quality dashboard

---

## Component 3: Bypass Auditing

### Purpose
Track and audit all governance bypass operations to ensure accountability.

### What Triggers Bypass Audit

1. **Environment Variable**: `GOVERNANCE_BYPASS=true`
2. **Explicit Flag**: `--bypass-governance`
3. **Emergency Mode**: System-wide bypass
4. **Schema Override**: Writing without validation

### Audit Record

**File**: `coordination/governance/bypass-audit.jsonl`

**Format:**
```json
{
  "timestamp": "2025-11-17T21:45:00Z",
  "trace_id": "trace-...",
  "bypass_type": "governance|validation|access",
  "principal": "user@example.com",
  "component": "spawn-worker.sh",
  "reason": "Emergency production fix",
  "approved_by": "manager@example.com",
  "duration_minutes": 30,
  "scope": {
    "operation": "worker-spawn",
    "resources": ["worker-emergency-001"]
  },
  "risk_level": "high"
}
```

### Implementation

**File**: `coordination/governance/lib/bypass-auditor.sh`

**API:**
```bash
audit_bypass() {
    local bypass_type="$1"
    local reason="$2"
    local approved_by="${3:-none}"

    # Logs bypass to audit trail
    # Emits observability event
    # Checks if bypass is authorized
    # Returns: 0 if allowed, 1 if denied
}

check_bypass_authorization() {
    local principal="$1"
    local bypass_type="$2"

    # Checks authorization matrix
    # Returns: 0 if authorized, 1 if not
}
```

**Authorization Matrix:**
```
User Role        | Validation | Governance | Access
-----------------|------------|------------|--------
Developer        | ❌         | ❌         | ❌
Senior Engineer  | ✅ (30min) | ❌         | ❌
Tech Lead        | ✅ (2hr)   | ✅ (30min) | ❌
Engineering Mgr  | ✅ (8hr)   | ✅ (2hr)   | ✅ (30min)
Director         | ✅         | ✅         | ✅
```

---

## Component 4: Governance Dashboard

### Purpose
Provide executive and operational visibility into governance health.

### Metrics Tracked

**Compliance Metrics:**
- PII incidents (last 7/30/90 days)
- Data quality score (0-100)
- Bypass operations (count, duration)
- Policy violations
- Audit coverage percentage

**Operational Metrics:**
- Active workers with quality issues
- Tasks with data problems
- Configuration drift
- Schema validation failures

**Trend Analysis:**
- Quality score over time
- PII incidents trend
- Bypass frequency
- Violation patterns

### Implementation

**File**: `coordination/governance/dashboard-summary.json`

**Format:**
```json
{
  "generated_at": "2025-11-17T21:45:00Z",
  "period": "24h",
  "compliance": {
    "pii_incidents": 0,
    "data_quality_score": 95,
    "bypass_count": 3,
    "violations": 1,
    "audit_coverage": 100
  },
  "quality": {
    "workers_with_issues": 2,
    "tasks_with_issues": 0,
    "schema_failures": 0,
    "referential_errors": 1
  },
  "trends": {
    "quality_trend": "improving",
    "pii_trend": "stable",
    "bypass_trend": "stable"
  },
  "alerts": [
    {
      "severity": "warning",
      "message": "2 workers have stale timestamps",
      "action": "Review worker status"
    }
  ]
}
```

**CLI Tool**: `scripts/governance-report.sh`

**Usage:**
```bash
# Show current governance status
./scripts/governance-report.sh --summary

# Generate compliance report
./scripts/governance-report.sh --compliance --period 30d

# Show PII incidents
./scripts/governance-report.sh --pii-incidents --since 7d

# Export for auditors
./scripts/governance-report.sh --export --format csv
```

---

## Integration with Existing Systems

### With Observability (Phase 1)

- All governance events → observability events
- Trace IDs link governance to operations
- Dashboard queries observability indices

### With Validation (Phase 2)

- PII scanner runs during validation
- Quality checks integrated into safe_write_json()
- Bypass auditing wraps validation overrides

### With Access Control

- Bypass authorization checks access matrix
- Principal identity from COMMIT_RELAY_PRINCIPAL
- Audit trail includes access decisions

---

## Compliance Frameworks

### GDPR Compliance

**Right to be Forgotten:**
- PII scanner identifies personal data
- Redaction tools for data removal
- Audit trail of deletions

**Data Minimization:**
- Quality checks flag unnecessary PII
- Auto-redaction reduces PII storage
- Retention policies enforced

**Accountability:**
- Complete audit trail
- Bypass tracking
- Principal attribution

### SOC 2 Compliance

**Security:**
- Access control integration
- Bypass requires authorization
- Audit trail immutable

**Availability:**
- Quality monitoring prevents outages
- Proactive issue detection
- Dashboard visibility

**Confidentiality:**
- PII detection and redaction
- Sensitive data flagging
- Access logging

---

## Implementation Timeline

**Week 1 (Current):**
- ✅ Architecture design (this document)
- [ ] PII scanner implementation
- [ ] Quality monitor core functions
- [ ] Bypass auditor framework

**Week 2:**
- [ ] Complete quality monitoring
- [ ] Dashboard data generation
- [ ] CLI reporting tool
- [ ] Integration testing

**Week 3:**
- [ ] Compliance framework validation
- [ ] Performance optimization
- [ ] Documentation
- [ ] Production deployment

---

## Success Metrics

**Phase 3 Complete When:**
- ✅ PII scanner catches 95%+ of known patterns
- ✅ Data quality score >90% system-wide
- ✅ 100% of bypasses logged and attributed
- ✅ Dashboard updates every 5 minutes
- ✅ Zero compliance violations in production

**Long-term KPIs:**
- PII incidents: 0 per month
- Data quality: >95% average
- Unauthorized bypasses: 0
- Audit coverage: 100%
- Compliance ready: <1 week for audits

---

## Security Considerations

1. **Audit Trail Integrity**: Append-only, immutable logs
2. **PII in Logs**: Scanner itself doesn't log PII values
3. **Access Control**: Bypass requires proper authorization
4. **Encryption**: Sensitive governance data encrypted at rest
5. **Retention**: Audit logs kept for 7 years (compliance requirement)

---

**Next Steps**: Begin implementation with PII scanner (highest risk reduction)
