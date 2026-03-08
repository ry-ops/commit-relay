# Runbook: Worker Lifecycle

Management of worker spawn, monitor, shutdown, and cleanup operations.

---

## Overview

This runbook covers the complete worker lifecycle from creation to cleanup, including monitoring and graceful shutdown procedures.

---

## Worker Lifecycle States

```
[Pending] -> [Running] -> [Completed]
    |           |            |
    |           v            |
    |       [Idle]           |
    |           |            |
    +---------> [Failed] ----+
                   |
                   v
               [Zombie] -> [Cleaned Up]
```

### State Descriptions

| State | Description | Duration |
|-------|-------------|----------|
| Pending | Task assigned, waiting to spawn | < 1 minute |
| Running | Actively processing task | Variable |
| Idle | Spawned but no active task | < 5 minutes |
| Completed | Task finished successfully | Immediate archive |
| Failed | Task failed | Moved to zombie |
| Zombie | Awaiting cleanup | Until cleaned |

---

## Spawning Workers

### Using Wizard (Recommended)

```bash
# Interactive worker creation
./scripts/wizards/create-worker.sh
```

### Using Spawn Script

```bash
# Spawn with parameters
./scripts/spawn-worker.sh \
    --type implementation-worker \
    --task-id task-001 \
    --master development-master \
    --priority high \
    --repo owner/repo
```

### Manual Worker Spec Creation

```bash
WORKER_ID="worker-implementation-$(date +%s)"
TASK_ID="task-001"

cat > $COMMIT_RELAY_HOME/coordination/worker-specs/active/$WORKER_ID.json << EOF
{
  "worker_id": "$WORKER_ID",
  "worker_type": "implementation-worker",
  "status": "pending",
  "task_id": "$TASK_ID",
  "priority": "high",
  "token_budget": {
    "allocated": 100000,
    "used": 0
  },
  "heartbeat": {
    "last_seen": null,
    "health_score": 100
  },
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo "Created worker: $WORKER_ID"
```

### Validate Before Spawn

```bash
# Use validation script
./scripts/validate-and-write-worker-spec.sh $WORKER_ID.json

# Check token budget
AVAILABLE=$(jq -r '.available' $COMMIT_RELAY_HOME/coordination/token-budget.json)
REQUIRED=100000
if (( AVAILABLE < REQUIRED )); then
    echo "Insufficient budget: $AVAILABLE < $REQUIRED"
    exit 1
fi
```

---

## Monitoring Workers

### Real-Time Dashboard

```bash
# Worker-specific dashboard
./scripts/dashboards/worker-monitor.sh

# Filter by status
./scripts/dashboards/worker-monitor.sh --status running

# Filter by type
./scripts/dashboards/worker-monitor.sh --type implementation-worker
```

### Check Individual Worker

```bash
WORKER_ID="worker-implementation-001"

# View worker spec
cat $COMMIT_RELAY_HOME/coordination/worker-specs/active/$WORKER_ID.json | jq .

# Check process running
PID=$(jq -r '.pid // empty' $COMMIT_RELAY_HOME/coordination/worker-specs/active/$WORKER_ID.json)
if [[ -n "$PID" ]]; then
    ps -p $PID && echo "Worker running" || echo "Worker process dead"
fi

# Check heartbeat
jq '.heartbeat' $COMMIT_RELAY_HOME/coordination/worker-specs/active/$WORKER_ID.json

# View logs
LOG_DIR=$(find $COMMIT_RELAY_HOME/agents/logs/workers -type d -name "$WORKER_ID" 2>/dev/null)
if [[ -d "$LOG_DIR" ]]; then
    tail -50 "$LOG_DIR/worker.log"
fi
```

### Monitor Heartbeats

```bash
# List workers by health score
for spec in $COMMIT_RELAY_HOME/coordination/worker-specs/active/worker-*.json; do
    if [[ -f "$spec" ]]; then
        ID=$(jq -r '.worker_id' "$spec")
        HEALTH=$(jq -r '.heartbeat.health_score // 0' "$spec")
        LAST=$(jq -r '.heartbeat.last_seen // "never"' "$spec")
        echo "$HEALTH% | $ID | $LAST"
    fi
done | sort -rn

# Check for stale heartbeats (>5 min)
NOW=$(date +%s)
for spec in $COMMIT_RELAY_HOME/coordination/worker-specs/active/worker-*.json; do
    if [[ -f "$spec" ]]; then
        LAST=$(jq -r '.heartbeat.last_seen // ""' "$spec")
        if [[ -n "$LAST" ]]; then
            LAST_TS=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${LAST%%.*}" +%s 2>/dev/null || echo 0)
            AGE=$((NOW - LAST_TS))
            if (( AGE > 300 )); then
                ID=$(jq -r '.worker_id' "$spec")
                echo "Stale: $ID (${AGE}s)"
            fi
        fi
    fi
done
```

### Monitor Token Usage

```bash
# Check worker token usage
for spec in $COMMIT_RELAY_HOME/coordination/worker-specs/active/worker-*.json; do
    if [[ -f "$spec" ]]; then
        ID=$(jq -r '.worker_id' "$spec")
        ALLOCATED=$(jq -r '.token_budget.allocated // 0' "$spec")
        USED=$(jq -r '.token_budget.used // 0' "$spec")
        PCT=$((USED * 100 / (ALLOCATED + 1)))
        echo "$PCT% | $ID | $USED/$ALLOCATED"
    fi
done | sort -rn | head -10
```

---

## Graceful Shutdown

### Shutdown Single Worker

```bash
WORKER_ID="worker-implementation-001"

# Update status
jq '.status = "shutting_down"' \
   $COMMIT_RELAY_HOME/coordination/worker-specs/active/$WORKER_ID.json > /tmp/spec.json && \
mv /tmp/spec.json $COMMIT_RELAY_HOME/coordination/worker-specs/active/$WORKER_ID.json

# Send SIGTERM to process
PID=$(jq -r '.pid // empty' $COMMIT_RELAY_HOME/coordination/worker-specs/active/$WORKER_ID.json)
if [[ -n "$PID" ]]; then
    kill -TERM $PID 2>/dev/null
    sleep 5
    # Force kill if still running
    kill -9 $PID 2>/dev/null || true
fi

# Move to completed
mv $COMMIT_RELAY_HOME/coordination/worker-specs/active/$WORKER_ID.json \
   $COMMIT_RELAY_HOME/coordination/worker-specs/completed/
```

### Shutdown All Workers

```bash
# Graceful shutdown all
for spec in $COMMIT_RELAY_HOME/coordination/worker-specs/active/worker-*.json; do
    if [[ -f "$spec" ]]; then
        PID=$(jq -r '.pid // empty' "$spec")
        if [[ -n "$PID" ]]; then
            kill -TERM $PID 2>/dev/null
        fi
    fi
done

# Wait for graceful shutdown
sleep 10

# Force kill remaining
for spec in $COMMIT_RELAY_HOME/coordination/worker-specs/active/worker-*.json; do
    if [[ -f "$spec" ]]; then
        PID=$(jq -r '.pid // empty' "$spec")
        if [[ -n "$PID" ]] && ps -p $PID > /dev/null 2>&1; then
            kill -9 $PID 2>/dev/null
        fi
    fi
done
```

### Emergency Kill

```bash
# Kill all worker processes immediately
pkill -9 -f "worker.*claude"

# Remove all active specs
rm -f $COMMIT_RELAY_HOME/coordination/worker-specs/active/worker-*.json

# Reset token budget
# WARNING: Only if all workers are truly dead
```

---

## Cleanup Operations

### Cleanup Single Zombie

```bash
WORKER_ID="worker-implementation-001"

# Verify worker is dead
PID=$(jq -r '.pid // empty' $COMMIT_RELAY_HOME/coordination/worker-specs/zombie/$WORKER_ID.json)
if [[ -n "$PID" ]] && ps -p $PID > /dev/null 2>&1; then
    echo "Worker still running, stopping first"
    kill $PID 2>/dev/null
fi

# Get allocated tokens for budget recovery
ALLOCATED=$(jq -r '.token_budget.allocated // 0' \
    $COMMIT_RELAY_HOME/coordination/worker-specs/zombie/$WORKER_ID.json)

# Update budget
USED=$(jq -r '.used' $COMMIT_RELAY_HOME/coordination/token-budget.json)
AVAILABLE=$(jq -r '.available' $COMMIT_RELAY_HOME/coordination/token-budget.json)
NEW_USED=$((USED - ALLOCATED))
NEW_AVAILABLE=$((AVAILABLE + ALLOCATED))

jq ".used = $NEW_USED | .available = $NEW_AVAILABLE" \
   $COMMIT_RELAY_HOME/coordination/token-budget.json > /tmp/budget.json && \
mv /tmp/budget.json $COMMIT_RELAY_HOME/coordination/token-budget.json

# Archive zombie spec
mv $COMMIT_RELAY_HOME/coordination/worker-specs/zombie/$WORKER_ID.json \
   $COMMIT_RELAY_HOME/coordination/worker-specs/archived/

echo "Cleaned up $WORKER_ID, recovered $ALLOCATED tokens"
```

### Bulk Cleanup

```bash
# Use cleanup script
./scripts/cleanup-zombie-workers.sh

# Or manual bulk cleanup
for spec in $COMMIT_RELAY_HOME/coordination/worker-specs/zombie/worker-*.json; do
    if [[ -f "$spec" ]]; then
        ID=$(jq -r '.worker_id' "$spec")
        ALLOCATED=$(jq -r '.token_budget.allocated // 0' "$spec")

        # Kill if running
        PID=$(jq -r '.pid // empty' "$spec")
        [[ -n "$PID" ]] && kill $PID 2>/dev/null

        # Archive
        mv "$spec" $COMMIT_RELAY_HOME/coordination/worker-specs/archived/

        echo "Cleaned: $ID ($ALLOCATED tokens)"
    fi
done

# Recalculate budget after bulk cleanup
./scripts/recalculate-token-budget.sh 2>/dev/null || true
```

### Archive Old Completed Workers

```bash
# Archive completed workers older than 7 days
ARCHIVE_DATE=$(date -v-7d +%Y-%m-%d 2>/dev/null || date -d '7 days ago' +%Y-%m-%d)

for spec in $COMMIT_RELAY_HOME/coordination/worker-specs/completed/worker-*.json; do
    if [[ -f "$spec" ]]; then
        COMPLETED=$(jq -r '.completed_at // ""' "$spec")
        if [[ "$COMPLETED" < "$ARCHIVE_DATE" ]]; then
            mv "$spec" $COMMIT_RELAY_HOME/coordination/worker-specs/archived/
        fi
    fi
done
```

---

## Automation

### Automatic Zombie Detection

The heartbeat monitor daemon automatically detects zombies:

```bash
# Check heartbeat monitor is running
ps aux | grep heartbeat-monitor-daemon

# Configuration
cat $COMMIT_RELAY_HOME/coordination/config/heartbeat-policy.json | jq .

# View detection events
grep "zombie_detected" $COMMIT_RELAY_HOME/coordination/dashboard-events.jsonl | tail -10
```

### Automatic Restart

Workers are automatically restarted by the worker-restart daemon:

```bash
# Check restart daemon
ps aux | grep worker-restart-daemon

# View restart history
tail -20 $COMMIT_RELAY_HOME/coordination/metrics/worker-restart-history.jsonl | jq .
```

### Scheduled Cleanup

Add to crontab:

```bash
# Cleanup zombies every hour
0 * * * * $COMMIT_RELAY_HOME/scripts/cleanup-zombie-workers.sh >> /tmp/cleanup.log 2>&1

# Archive old completed every day
0 2 * * * find $COMMIT_RELAY_HOME/coordination/worker-specs/completed -name "*.json" -mtime +7 \
    -exec mv {} $COMMIT_RELAY_HOME/coordination/worker-specs/archived/ \;
```

---

## Troubleshooting

### Worker Won't Spawn

1. Check token budget
2. Verify worker type exists
3. Check daemon is running
4. Review daemon logs

### Worker Stuck

1. Check heartbeat status
2. View worker logs
3. Check for API errors
4. Consider forced termination

### Worker Not Cleaning Up

1. Check zombie cleanup daemon
2. Verify PID file exists
3. Manual kill and cleanup
4. Recalculate budget

---

## Related Runbooks

- [Worker Failure](./worker-failure.md)
- [Token Budget Exhaustion](./token-budget-exhaustion.md)
- [Self-Healing System](./self-healing-system.md)

---

**Last Updated**: 2025-11-21
