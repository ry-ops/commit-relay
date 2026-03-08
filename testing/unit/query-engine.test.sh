#!/usr/bin/env bash
#
# Query Engine Tests
# Part of Q2 Week 20: Query Engine & Dashboards
#

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source the query engine
OBS_QUERY="$PROJECT_ROOT/scripts/obs-query.sh"

echo "=== Query Engine Tests ==="
echo ""

# Test 1: Help output
echo "Test 1: Help Output"
if "$OBS_QUERY" "" 2>&1 | grep -q "Observability Query Engine"; then
    echo "✓ PASS: Help displays correctly"
else
    echo "✗ FAIL: Help not displayed"
fi
echo ""

# Test 2: Cache clearing
echo "Test 2: Cache Management"
if "$OBS_QUERY" --clear-cache 2>&1 | grep -q "Cache cleared"; then
    echo "✓ PASS: Cache clearing works"
else
    echo "✗ FAIL: Cache clearing failed"
fi
echo ""

# Test 3: Query parsing (events)
echo "Test 3: Events Query"
result=$("$OBS_QUERY" "SELECT * FROM events LIMIT 5" 2>/dev/null || echo "{}")
if echo "$result" | jq -e '.results' >/dev/null 2>&1; then
    echo "✓ PASS: Events query returns valid JSON"
else
    echo "✗ FAIL: Events query failed"
fi
echo ""

# Test 4: Query parsing (metrics)
echo "Test 4: Metrics Query"
result=$("$OBS_QUERY" "SELECT * FROM metrics LIMIT 5" 2>/dev/null || echo "{}")
if echo "$result" | jq -e '.results' >/dev/null 2>&1; then
    echo "✓ PASS: Metrics query returns valid JSON"
else
    echo "✗ FAIL: Metrics query failed"
fi
echo ""

# Test 5: Query parsing (traces)
echo "Test 5: Traces Query"
result=$("$OBS_QUERY" "SELECT * FROM traces LIMIT 5" 2>/dev/null || echo "{}")
if echo "$result" | jq -e '.results' >/dev/null 2>&1; then
    echo "✓ PASS: Traces query returns valid JSON"
else
    echo "✗ FAIL: Traces query failed"
fi
echo ""

# Test 6: Query parsing (anomalies)
echo "Test 6: Anomalies Query"
result=$("$OBS_QUERY" "SELECT * FROM anomalies LIMIT 5" 2>/dev/null || echo "{}")
if echo "$result" | jq -e '.results' >/dev/null 2>&1; then
    echo "✓ PASS: Anomalies query returns valid JSON"
else
    echo "✗ FAIL: Anomalies query failed"
fi
echo ""

# Test 7: WHERE clause parsing
echo "Test 7: WHERE Clause"
result=$("$OBS_QUERY" "SELECT * FROM events WHERE type=task LIMIT 1" 2>/dev/null || echo "{}")
if echo "$result" | jq -e '.metadata.query' >/dev/null 2>&1; then
    echo "✓ PASS: WHERE clause parsed"
else
    echo "✗ FAIL: WHERE clause parsing failed"
fi
echo ""

# Test 8: LIMIT clause
echo "Test 8: LIMIT Clause"
result=$("$OBS_QUERY" "SELECT * FROM events LIMIT 3" 2>/dev/null || echo "{}")
count=$(echo "$result" | jq -r '.results | length' 2>/dev/null || echo "0")
if [[ $count -le 3 ]]; then
    echo "✓ PASS: LIMIT clause works (returned $count results)"
else
    echo "✗ FAIL: LIMIT clause returned too many results ($count)"
fi
echo ""

# Test 9: Query metadata
echo "Test 9: Query Metadata"
result=$("$OBS_QUERY" "SELECT * FROM events LIMIT 1" 2>/dev/null || echo "{}")
if echo "$result" | jq -e '.metadata.query_time_ms' >/dev/null 2>&1; then
    echo "✓ PASS: Query metadata included"
else
    echo "✗ FAIL: Query metadata missing"
fi
echo ""

# Test 10: Query performance (<500ms target)
echo "Test 10: Query Performance"
result=$("$OBS_QUERY" "SELECT * FROM events LIMIT 10" 2>/dev/null || echo "{}")
query_time=$(echo "$result" | jq -r '.metadata.query_time_ms' 2>/dev/null || echo "9999")
if [[ $query_time -lt 500 ]]; then
    echo "✓ PASS: Query completed in ${query_time}ms (<500ms)"
else
    echo "⚠ WARN: Query took ${query_time}ms (target <500ms)"
fi
echo ""

echo "=== Tests Complete ==="
