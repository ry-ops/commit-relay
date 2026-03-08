# Runbook: Token Budget Exhaustion

Diagnosis and resolution for budget exceeded issues.

---

## Overview

This runbook covers token budget issues including:
- Daily budget exceeded
- Individual worker budget exceeded
- Allocation failures
- Budget calculation errors

---

## Symptoms

### Budget Exhausted
- New tasks not being assigned workers
- Workers reporting "insufficient budget" errors
- Dashboard showing 100% budget usage
- Error messages in coordinator logs

### Worker Budget Exceeded
- Worker stuck waiting for budget
- Worker terminated due to budget limit
- Partial task completion

---

## Diagnostic Commands

### 1. Check Current Budget Status

```bash
# View token budget
cat $COMMIT_RELAY_HOME/coordination/token-budget.json | jq .

# Quick summary
jq '{
    total: .total_budget,
    used: .usage_metrics.total_tokens_used_today,
    available: (.total_budget - .usage_metrics.total_tokens_used_today),
    usage_pct: ((.usage_metrics.total_tokens_used_today * 100) / .total_budget)
}' $COMMIT_RELAY_HOME/coordination/token-budget.json
```

### 2. Check Worker Allocations

```bash
# List all worker allocations
jq '.workers | to_entries[] | {
    worker: .key,
    allocated: .value.allocated,
    used: .value.used,
    remaining: (.value.allocated - .value.used)
}' $COMMIT_RELAY_HOME/coordination/token-budget.json

# Find workers over budget
jq '.workers | to_entries[] | select(.value.used > .value.allocated) | .key' \
    $COMMIT_RELAY_HOME/coordination/token-budget.json
```

### 3. Check Recent Usage Trends

```bash
# View hourly snapshots for token usage trend
for snapshot in $(ls -t $COMMIT_RELAY_HOME/coordination/history/hourly/*.json | head -12); do
    ts=$(jq -r '.timestamp' "$snapshot")
    used=$(jq -r '.tokens.total_used // 0' "$snapshot")
    echo "$ts: $used tokens"
done
```

### 4. Find Budget-Related Errors

```bash
# Check for budget errors in logs
grep -i "budget\|allocation\|tokens" \
    $COMMIT_RELAY_HOME/agents/logs/system/pm-daemon.log | tail -20

# Check coordinator logs
grep -i "insufficient\|exceeded\|budget" \
    $COMMIT_RELAY_HOME/agents/logs/system/coordinator-daemon.log | tail -20
```

---

## Resolution Steps

### A. Reset Daily Budget

If the daily budget needs to be reset:

```bash
# View current budget
cat $COMMIT_RELAY_HOME/coordination/token-budget.json | jq .

# Reset daily usage counter
jq '.usage_metrics.total_tokens_used_today = 0 |
    .usage_metrics.reset_at = "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"' \
    $COMMIT_RELAY_HOME/coordination/token-budget.json > \
    $COMMIT_RELAY_HOME/coordination/token-budget.json.tmp && \
    mv $COMMIT_RELAY_HOME/coordination/token-budget.json.tmp \
       $COMMIT_RELAY_HOME/coordination/token-budget.json

# Log the reset
./scripts/emit-event.sh --type "budget_reset" \
    --severity "info" \
    --message "Daily token budget reset manually"
```

### B. Increase Total Budget

```bash
# Increase budget to 500000
jq '.total_budget = 500000' \
    $COMMIT_RELAY_HOME/coordination/token-budget.json > \
    $COMMIT_RELAY_HOME/coordination/token-budget.json.tmp && \
    mv $COMMIT_RELAY_HOME/coordination/token-budget.json.tmp \
       $COMMIT_RELAY_HOME/coordination/token-budget.json

echo "Budget increased to 500000 tokens"
```

### C. Clean Up Completed Worker Allocations

```bash
# Remove allocations for completed/failed workers
BUDGET_FILE="$COMMIT_RELAY_HOME/coordination/token-budget.json"

# Get list of active workers
active_workers=$(ls $COMMIT_RELAY_HOME/coordination/worker-specs/active/*.json 2>/dev/null | \
    xargs -I {} jq -r '.worker_id' {} | sort | uniq)

# Filter budget to only keep active workers
jq --argjson active "$(echo "$active_workers" | jq -R . | jq -s .)" \
    '.workers = (.workers | to_entries | map(select(.key as $k | $active | index($k))) | from_entries)' \
    "$BUDGET_FILE" > "${BUDGET_FILE}.tmp" && \
    mv "${BUDGET_FILE}.tmp" "$BUDGET_FILE"

echo "Cleaned up completed worker allocations"
```

### D. Recalculate Budget Usage

```bash
# Recalculate total usage from worker allocations
jq '.usage_metrics.total_tokens_used_today = ([.workers[].used] | add // 0)' \
    $COMMIT_RELAY_HOME/coordination/token-budget.json > \
    $COMMIT_RELAY_HOME/coordination/token-budget.json.tmp && \
    mv $COMMIT_RELAY_HOME/coordination/token-budget.json.tmp \
       $COMMIT_RELAY_HOME/coordination/token-budget.json
```

### E. Reallocate Budget to Stuck Worker

```bash
WORKER_ID="worker-implementation-001"

# Increase worker allocation
jq --arg wid "$WORKER_ID" \
    '.workers[$wid].allocated = 150000' \
    $COMMIT_RELAY_HOME/coordination/token-budget.json > \
    $COMMIT_RELAY_HOME/coordination/token-budget.json.tmp && \
    mv $COMMIT_RELAY_HOME/coordination/token-budget.json.tmp \
       $COMMIT_RELAY_HOME/coordination/token-budget.json
```

### F. Emergency Budget Override

For critical situations when budget cannot wait:

```bash
# Create emergency budget override
cat > $COMMIT_RELAY_HOME/coordination/token-budget.json << 'EOF'
{
  "total_budget": 500000,
  "usage_metrics": {
    "total_tokens_used_today": 0,
    "reset_at": "2025-11-21T00:00:00Z"
  },
  "workers": {},
  "emergency_override": true,
  "override_timestamp": "2025-11-21T12:00:00Z"
}
EOF

# Update timestamp
jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.override_timestamp = $ts | .usage_metrics.reset_at = $ts' \
    $COMMIT_RELAY_HOME/coordination/token-budget.json > \
    $COMMIT_RELAY_HOME/coordination/token-budget.json.tmp && \
    mv $COMMIT_RELAY_HOME/coordination/token-budget.json.tmp \
       $COMMIT_RELAY_HOME/coordination/token-budget.json
```

---

## Prevention

### 1. Set Appropriate Worker Budgets

Configure default budgets based on task complexity:

```json
{
  "implementation-worker": {"default_budget": 100000},
  "scan-worker": {"default_budget": 50000},
  "analysis-worker": {"default_budget": 30000},
  "documentation-worker": {"default_budget": 40000}
}
```

### 2. Monitor Budget Usage

Check budget regularly:

```bash
# Add to daily operations
jq '{
    total: .total_budget,
    used: .usage_metrics.total_tokens_used_today,
    pct: ((.usage_metrics.total_tokens_used_today * 100) / .total_budget)
}' $COMMIT_RELAY_HOME/coordination/token-budget.json
```

### 3. Set Up Budget Alerts

Configure alerts when budget exceeds thresholds:

```bash
# Check for 75% usage
USAGE_PCT=$(jq '((.usage_metrics.total_tokens_used_today * 100) / .total_budget)' \
    $COMMIT_RELAY_HOME/coordination/token-budget.json)

if (( $(echo "$USAGE_PCT > 75" | bc -l) )); then
    ./scripts/emit-event.sh --type "budget_warning" \
        --severity "warning" \
        --message "Token budget at ${USAGE_PCT}%"
fi
```

### 4. Automatic Daily Reset

Configure automatic reset at midnight:

```bash
# Add to crontab
0 0 * * * $COMMIT_RELAY_HOME/scripts/system-maintenance.sh --reset-token-budget
```

---

## Quick Reference

| Issue | Command |
|-------|---------|
| View current budget | `jq . coordination/token-budget.json` |
| Check usage percentage | `jq '(.usage_metrics.total_tokens_used_today * 100) / .total_budget' coordination/token-budget.json` |
| Reset daily usage | Set `.usage_metrics.total_tokens_used_today = 0` |
| Increase total budget | Set `.total_budget = NEW_VALUE` |
| Clean up allocations | Remove non-active workers from `.workers` |
| View worker usage | `jq '.workers' coordination/token-budget.json` |

---

## Related Runbooks

- [Performance Troubleshooting](./performance-troubleshooting.md)
- [Daily Operations](./daily-operations.md)
- [Worker Lifecycle](./worker-lifecycle.md)
- [Emergency Recovery](./emergency-recovery.md)

---

**Last Updated**: 2025-11-21
