#!/bin/bash
# Monitor ML router performance

METRICS_FILE="${COMMIT_RELAY_HOME:-/Users/ryandahlberg/Projects/commit-relay}/coordination/metrics/ml-router-metrics.jsonl"

echo "📊 ML Router Metrics"
echo "===================="

if [ -f "$METRICS_FILE" ]; then
    total_routes=$(wc -l < "$METRICS_FILE")
    ml_routes=$(grep -c '"method":"ml"' "$METRICS_FILE" || echo 0)
    rule_routes=$(grep -c '"method":"rule-based"' "$METRICS_FILE" || echo 0)

    echo "Total routes: $total_routes"
    echo "ML routes: $ml_routes"
    echo "Rule-based routes: $rule_routes"

    if [ "$total_routes" -gt 0 ]; then
        ml_percentage=$(echo "scale=2; $ml_routes * 100 / $total_routes" | bc)
        echo "ML percentage: ${ml_percentage}%"
    fi
else
    echo "No metrics found yet"
fi
