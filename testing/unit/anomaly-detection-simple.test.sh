#!/usr/bin/env bash
# Simple Anomaly Detection Tests

set -euo pipefail

source scripts/lib/observability/anomaly-detector.sh 2>/dev/null || true

echo "=== Anomaly Detection - Quick Tests ==="
echo ""

# Test 1: ID Generation
id=$(generate_anomaly_id)
[[ "$id" =~ ^anomaly- ]] && echo "✓ ID generation" || echo "✗ ID generation"

# Test 2: Classification
type=$(classify_anomaly_type "task_success_rate" "-2.0")
[[ "$type" == "success_rate_drop" ]] && echo "✓ Classification" || echo "✗ Classification"

# Test 3: Severity
sev=$(calculate_severity "5.5")
[[ "$sev" == "critical" ]] && echo "✓ Severity calculation" || echo "✗ Severity"

# Test 4: Suggested actions
actions=$(generate_suggested_actions "token_usage_spike")
[[ "$actions" =~ token ]] && echo "✓ Suggested actions" || echo "✗ Suggested actions"

echo ""
echo "=== Quick tests complete ==="
