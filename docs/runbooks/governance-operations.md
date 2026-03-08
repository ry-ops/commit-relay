# Runbook: Governance Operations

PII scanning, compliance reporting, and governance management.

---

## Overview

This runbook covers the governance and compliance operations for Commit-Relay, including PII detection, data quality monitoring, and compliance reporting.

---

## Governance Components

| Component | Purpose | Location |
|-----------|---------|----------|
| PII Scanner | Detect sensitive data | `governance/lib/pii-scanner.sh` |
| Quality Monitor | Data quality checks | `governance/lib/quality-monitor.sh` |
| Access Log | Audit trail | `governance/access-log.jsonl` |
| Approval Workflow | Bypass approvals | `governance/approval-workflow.json` |

---

## PII Scanning

### Manual File Scan

```bash
# Scan single file
./coordination/governance/lib/pii-scanner.sh /path/to/file.txt

# Scan with detailed output
./coordination/governance/lib/pii-scanner.sh --verbose /path/to/file.txt
```

### Scan Directory

```bash
# Scan all files in directory
find /path/to/directory -type f -name "*.json" | while read -r file; do
    echo "Scanning: $file"
    ./coordination/governance/lib/pii-scanner.sh "$file"
done
```

### Scan Worker Output

```bash
# Scan all worker results
for result in $COMMIT_RELAY_HOME/agents/results/*.json; do
    echo "=== $(basename $result) ==="
    ./coordination/governance/lib/pii-scanner.sh "$result"
done
```

### PII Detection Patterns

The scanner checks for:

| Pattern | Examples |
|---------|----------|
| Email | `user@example.com` |
| Phone | `555-123-4567`, `(555) 123-4567` |
| SSN | `123-45-6789` |
| Credit Card | `4111-1111-1111-1111` |
| API Keys | `sk-xxxx`, `api_key_xxx` |
| IP Address | `192.168.1.1` |

### Configure PII Rules

```bash
# View current rules
cat $COMMIT_RELAY_HOME/coordination/governance/config/pii-rules.json | jq .

# Add custom pattern
jq '.patterns += [{
  "name": "custom_id",
  "regex": "CID-[0-9]{8}",
  "severity": "high",
  "description": "Custom identifier"
}]' $COMMIT_RELAY_HOME/coordination/governance/config/pii-rules.json > /tmp/rules.json && \
mv /tmp/rules.json $COMMIT_RELAY_HOME/coordination/governance/config/pii-rules.json
```

---

## Data Quality Monitoring

### Run Quality Check

```bash
# Check specific file
./coordination/governance/lib/quality-monitor.sh /path/to/data.json

# Check all coordination files
for file in $COMMIT_RELAY_HOME/coordination/*.json; do
    echo "Checking: $file"
    jq empty "$file" 2>/dev/null && echo "  [OK] Valid JSON" || echo "  [FAIL] Invalid JSON"
done
```

### Quality Metrics

```bash
# View quality metrics
cat $COMMIT_RELAY_HOME/coordination/governance/quality-metrics.json | jq .

# Expected structure:
# {
#   "valid_json": 95,
#   "schema_compliant": 90,
#   "complete_records": 88,
#   "last_check": "2025-11-21T10:00:00Z"
# }
```

### Validate Worker Specs

```bash
# Check all worker specs have required fields
for spec in $COMMIT_RELAY_HOME/coordination/worker-specs/active/worker-*.json; do
    ID=$(jq -r '.worker_id // "MISSING"' "$spec")
    TYPE=$(jq -r '.worker_type // "MISSING"' "$spec")
    STATUS=$(jq -r '.status // "MISSING"' "$spec")

    if [[ "$ID" == "MISSING" || "$TYPE" == "MISSING" || "$STATUS" == "MISSING" ]]; then
        echo "[INVALID] $(basename $spec): Missing required fields"
    fi
done
```

### Schema Validation

```bash
# Validate against schema (if using JSON Schema)
# Install ajv-cli: npm install -g ajv-cli

# Validate worker spec
ajv validate -s $COMMIT_RELAY_HOME/coordination/schemas/worker-spec.json \
   -d $COMMIT_RELAY_HOME/coordination/worker-specs/active/worker-001.json
```

---

## Compliance Reporting

### Generate Compliance Report

```bash
# Generate daily compliance report
REPORT_DATE=$(date +%Y-%m-%d)
REPORT_FILE="$COMMIT_RELAY_HOME/coordination/governance/reports/compliance-${REPORT_DATE}.json"

cat > "$REPORT_FILE" << EOF
{
  "report_date": "$REPORT_DATE",
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "pii_scans": {
    "files_scanned": $(find $COMMIT_RELAY_HOME/agents/results -name "*.json" | wc -l | xargs),
    "detections": $(grep -c "pii_detected" $COMMIT_RELAY_HOME/coordination/governance/access-log.jsonl 2>/dev/null || echo 0)
  },
  "data_quality": $(cat $COMMIT_RELAY_HOME/coordination/governance/quality-metrics.json 2>/dev/null || echo '{}'),
  "access_events": $(wc -l < $COMMIT_RELAY_HOME/coordination/governance/access-log.jsonl 2>/dev/null || echo 0),
  "bypass_requests": $(grep -c "bypass" $COMMIT_RELAY_HOME/coordination/governance/access-log.jsonl 2>/dev/null || echo 0)
}
EOF

echo "Generated: $REPORT_FILE"
```

### View Compliance History

```bash
# List all compliance reports
ls -la $COMMIT_RELAY_HOME/coordination/governance/reports/compliance-*.json

# View recent reports
for report in $(ls -t $COMMIT_RELAY_HOME/coordination/governance/reports/compliance-*.json | head -5); do
    echo "=== $(basename $report) ==="
    jq '{date: .report_date, pii_detections: .pii_scans.detections, quality: .data_quality.valid_json}' "$report"
done
```

### PII Detection Summary

```bash
# Summary of PII detections
echo "=== PII Detection Summary ==="
grep "pii_detected" $COMMIT_RELAY_HOME/coordination/governance/access-log.jsonl | \
    jq -s 'group_by(.pii_type) | map({type: .[0].pii_type, count: length})'
```

---

## Access Logging

### View Access Log

```bash
# Recent access events
tail -20 $COMMIT_RELAY_HOME/coordination/governance/access-log.jsonl | jq .

# Filter by action
grep '"action":"read"' $COMMIT_RELAY_HOME/coordination/governance/access-log.jsonl | tail -10 | jq .

# Filter by user/worker
grep '"actor":"worker-001"' $COMMIT_RELAY_HOME/coordination/governance/access-log.jsonl | jq .
```

### Log Structure

```json
{
  "timestamp": "2025-11-21T10:00:00Z",
  "actor": "worker-implementation-001",
  "action": "read",
  "resource": "/path/to/file.json",
  "result": "allowed",
  "metadata": {
    "pii_detected": false,
    "file_size": 1234
  }
}
```

### Search Access Log

```bash
# Find all denied actions
grep '"result":"denied"' $COMMIT_RELAY_HOME/coordination/governance/access-log.jsonl | jq .

# Find PII detections
grep '"pii_detected":true' $COMMIT_RELAY_HOME/coordination/governance/access-log.jsonl | jq .

# Find bypass attempts
grep '"action":"bypass_attempt"' $COMMIT_RELAY_HOME/coordination/governance/access-log.jsonl | jq .
```

---

## Bypass Workflow

### Request Bypass

```bash
# Log bypass request
BYPASS_ID="bypass-$(date +%s)"
cat >> $COMMIT_RELAY_HOME/coordination/governance/access-log.jsonl << EOF
{"timestamp":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","actor":"user","action":"bypass_request","bypass_id":"$BYPASS_ID","reason":"Emergency data recovery","resource":"/path/to/sensitive","status":"pending"}
EOF

echo "Bypass request: $BYPASS_ID"
```

### Approve Bypass

```bash
BYPASS_ID="bypass-123456"

# Update approval workflow
jq --arg id "$BYPASS_ID" '.pending_approvals[] | select(.bypass_id == $id) | .status = "approved" | .approved_by = "admin" | .approved_at = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"' \
   $COMMIT_RELAY_HOME/coordination/governance/approval-workflow.json > /tmp/approval.json && \
mv /tmp/approval.json $COMMIT_RELAY_HOME/coordination/governance/approval-workflow.json

# Log approval
cat >> $COMMIT_RELAY_HOME/coordination/governance/access-log.jsonl << EOF
{"timestamp":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","actor":"admin","action":"bypass_approved","bypass_id":"$BYPASS_ID"}
EOF
```

### View Pending Approvals

```bash
# List pending bypass requests
jq '.pending_approvals[] | select(.status == "pending")' \
   $COMMIT_RELAY_HOME/coordination/governance/approval-workflow.json
```

---

## Governance Daemon

### Start Governance Monitor

```bash
# Start daemon
./scripts/governance-monitor-daemon.sh &

# Verify running
ps aux | grep governance-monitor-daemon
```

### Configure Monitoring

```bash
# View governance config
cat $COMMIT_RELAY_HOME/coordination/governance/config/governance-policy.json | jq .

# Example configuration:
# {
#   "pii_scan_enabled": true,
#   "scan_interval_minutes": 60,
#   "quality_check_enabled": true,
#   "auto_block_pii": true,
#   "retention_days": 90
# }
```

### View Daemon Logs

```bash
# Check governance daemon logs
tail -50 $COMMIT_RELAY_HOME/agents/logs/system/governance-monitor-daemon.log

# Find scanning events
grep -i "scan" $COMMIT_RELAY_HOME/agents/logs/system/governance-monitor-daemon.log | tail -20
```

---

## Data Retention

### Configure Retention Policy

```bash
# Set retention policy
cat > $COMMIT_RELAY_HOME/coordination/governance/config/retention-policy.json << 'EOF'
{
  "access_logs": {
    "retention_days": 90,
    "archive_enabled": true
  },
  "compliance_reports": {
    "retention_days": 365,
    "archive_enabled": true
  },
  "worker_results": {
    "retention_days": 30,
    "archive_enabled": false
  }
}
EOF
```

### Apply Retention

```bash
# Delete old access logs
find $COMMIT_RELAY_HOME/coordination/governance -name "access-log*.jsonl" -mtime +90 -delete

# Archive old reports
find $COMMIT_RELAY_HOME/coordination/governance/reports -name "*.json" -mtime +365 \
    -exec mv {} $COMMIT_RELAY_HOME/archives/governance/ \;
```

---

## Audit Procedures

### Weekly Audit Checklist

```bash
# 1. Review access log summary
echo "=== Access Log Summary ==="
echo "Total events: $(wc -l < $COMMIT_RELAY_HOME/coordination/governance/access-log.jsonl)"
echo "Denied: $(grep -c '"result":"denied"' $COMMIT_RELAY_HOME/coordination/governance/access-log.jsonl)"
echo "PII detected: $(grep -c '"pii_detected":true' $COMMIT_RELAY_HOME/coordination/governance/access-log.jsonl)"

# 2. Check pending approvals
echo -e "\n=== Pending Approvals ==="
jq '.pending_approvals | length' $COMMIT_RELAY_HOME/coordination/governance/approval-workflow.json

# 3. Verify data quality
echo -e "\n=== Data Quality ==="
cat $COMMIT_RELAY_HOME/coordination/governance/quality-metrics.json | jq '{valid_json, schema_compliant}'

# 4. Check compliance reports generated
echo -e "\n=== Recent Reports ==="
ls -lt $COMMIT_RELAY_HOME/coordination/governance/reports/compliance-*.json | head -5
```

### Export Audit Data

```bash
# Export for external audit
EXPORT_DIR="$COMMIT_RELAY_HOME/exports/audit-$(date +%Y%m%d)"
mkdir -p "$EXPORT_DIR"

# Copy relevant files
cp $COMMIT_RELAY_HOME/coordination/governance/access-log.jsonl "$EXPORT_DIR/"
cp $COMMIT_RELAY_HOME/coordination/governance/reports/compliance-*.json "$EXPORT_DIR/"
cp $COMMIT_RELAY_HOME/coordination/governance/quality-metrics.json "$EXPORT_DIR/"

# Create summary
tar -czf "${EXPORT_DIR}.tar.gz" "$EXPORT_DIR"
echo "Exported to: ${EXPORT_DIR}.tar.gz"
```

---

## Troubleshooting

### PII Scanner Not Working

1. Check script permissions
2. Verify regex patterns valid
3. Check for special characters in files

```bash
chmod +x $COMMIT_RELAY_HOME/coordination/governance/lib/pii-scanner.sh
./coordination/governance/lib/pii-scanner.sh --test
```

### Access Log Not Recording

1. Check governance daemon running
2. Verify log file permissions
3. Check disk space

```bash
ps aux | grep governance-monitor-daemon
ls -la $COMMIT_RELAY_HOME/coordination/governance/access-log.jsonl
```

### Quality Metrics Not Updating

1. Check quality monitor running
2. Verify metrics file writable
3. Check configuration

---

## Related Runbooks

- [Data Quality Issues](./data-quality-issues.md)
- [Daily Operations](./daily-operations.md)
- [Observability Debugging](./observability-debugging.md)

---

**Last Updated**: 2025-11-21
