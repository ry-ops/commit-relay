# Runbook: Worker Failure

Diagnosis and resolution for stuck, zombie, and crashed workers.

---

## Overview

This runbook covers worker failure scenarios including workers that:
- Stop responding (stalled/stuck)
- Become zombies (process dead but status shows running)
- Crash during execution
- Fail to complete tasks

---

## Symptoms

### Stalled Worker
- Worker status shows "running" for extended period
- No check-ins received for > 15 minutes
- Progress percentage unchanged
- No log activity

### Zombie Worker
- Worker spec shows "running" status
- No corresponding process found
- PM daemon reports "zombie_detected" event
- Worker in `health_state: "stalled"` in pm-state.json

### Crashed Worker
- Sudden process termination
- Incomplete task output
- Error in agent logs
- Status may show "running" but process is dead

---

## Diagnostic Commands

### 1. Check Worker Status

```bash
# View worker spec
WORKER_ID="worker-implementation-001"
cat $COMMIT_RELAY_HOME/coordination/worker-specs/active/${WORKER_ID}.json | jq .

# Check PM daemon monitoring state
jq ".monitored_workers[\"$WORKER_ID\"]" \
    $COMMIT_RELAY_HOME/coordination/pm-state.json
```

### 2. Check for Process

```bash
# Find worker process
WORKER_ID="worker-implementation-001"
ps aux | grep -i "$WORKER_ID" | grep -v grep

# Find all Claude processes
ps aux | grep -i "claude" | grep -v grep
```

### 3. Check Last Activity

```bash
# View recent PM activity for worker
WORKER_ID="worker-implementation-001"
grep "$WORKER_ID" $COMMIT_RELAY_HOME/coordination/pm-activity.jsonl | tail -10 | jq .
```

### 4. Check Worker Logs

```bash
# View worker-specific logs (if available)
WORKER_ID="worker-implementation-001"
ls -la $COMMIT_RELAY_HOME/agents/logs/ | grep "$WORKER_ID"

# View general system logs
tail -100 $COMMIT_RELAY_HOME/agents/logs/system/pm-daemon.log | grep "$WORKER_ID"
```

### 5. Identify Zombie Workers

```bash
# Count zombies in active directory
find $COMMIT_RELAY_HOME/coordination/worker-specs/active -name "*.json" \
    -exec sh -c '
        status=$(jq -r ".status" "$1")
        if [ "$status" = "running" ]; then
            worker_id=$(jq -r ".worker_id" "$1")
            if ! ps aux | grep -q "$worker_id"; then
                echo "ZOMBIE: $worker_id"
            fi
        fi
    ' _ {} \;

# List all stalled workers in PM state
jq '.monitored_workers | to_entries[] | select(.value.health_state == "stalled") | .key' \
    $COMMIT_RELAY_HOME/coordination/pm-state.json
```

---

## Resolution Steps

### A. Restart Stalled Worker

```bash
WORKER_ID="worker-implementation-001"
SPEC_FILE="$COMMIT_RELAY_HOME/coordination/worker-specs/active/${WORKER_ID}.json"

# 1. Kill existing process if any
pid=$(ps aux | grep "$WORKER_ID" | grep -v grep | awk '{print $2}')
if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null
fi

# 2. Reset worker state
jq '.status = "pending" | .execution.started_at = null' \
    "$SPEC_FILE" > "${SPEC_FILE}.tmp" && \
    mv "${SPEC_FILE}.tmp" "$SPEC_FILE"

# 3. Re-spawn worker
./scripts/start-worker.sh --spec "$SPEC_FILE"
```

### B. Clean Up Zombie Worker

```bash
WORKER_ID="worker-implementation-001"

# 1. Move to failed directory
mv "$COMMIT_RELAY_HOME/coordination/worker-specs/active/${WORKER_ID}.json" \
   "$COMMIT_RELAY_HOME/coordination/worker-specs/failed/"

# 2. Update status in failed spec
FAILED_SPEC="$COMMIT_RELAY_HOME/coordination/worker-specs/failed/${WORKER_ID}.json"
jq '.status = "failed" | .error = "Zombie worker - no process found"' \
    "$FAILED_SPEC" > "${FAILED_SPEC}.tmp" && \
    mv "${FAILED_SPEC}.tmp" "$FAILED_SPEC"

# 3. Remove from PM monitoring
jq "del(.monitored_workers[\"$WORKER_ID\"])" \
    $COMMIT_RELAY_HOME/coordination/pm-state.json > \
    $COMMIT_RELAY_HOME/coordination/pm-state.json.tmp && \
    mv $COMMIT_RELAY_HOME/coordination/pm-state.json.tmp \
       $COMMIT_RELAY_HOME/coordination/pm-state.json

# 4. Log the cleanup
./scripts/emit-event.sh --type "worker_zombie_cleaned" \
    --worker-id "$WORKER_ID" \
    --message "Zombie worker cleaned up manually"
```

### C. Mass Zombie Cleanup

```bash
# Run zombie cleanup script
./scripts/cleanup-zombie-workers.sh

# Or use archive script
./scripts/archive-failed-workers.sh
```

### D. Force Fail Worker

When a worker needs to be terminated and marked as failed:

```bash
WORKER_ID="worker-implementation-001"
SPEC_FILE="$COMMIT_RELAY_HOME/coordination/worker-specs/active/${WORKER_ID}.json"

# 1. Kill process
pkill -f "$WORKER_ID" || true

# 2. Update spec with failure
jq '.status = "failed" | 
    .error = "Manual termination" | 
    .execution.completed_at = "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"' \
    "$SPEC_FILE" > "${SPEC_FILE}.tmp" && \
    mv "${SPEC_FILE}.tmp" "$SPEC_FILE"

# 3. Move to failed directory
mv "$SPEC_FILE" "$COMMIT_RELAY_HOME/coordination/worker-specs/failed/"
```

### E. Recover Task from Failed Worker

```bash
WORKER_ID="worker-implementation-001"
FAILED_SPEC="$COMMIT_RELAY_HOME/coordination/worker-specs/failed/${WORKER_ID}.json"

# Extract task information
TASK_ID=$(jq -r '.task_id' "$FAILED_SPEC")
DESCRIPTION=$(jq -r '.task.description' "$FAILED_SPEC")
WORKER_TYPE=$(jq -r '.worker_type' "$FAILED_SPEC")

# Re-create task
./scripts/create-task.sh \
    --description "$DESCRIPTION" \
    --priority high \
    --worker-type "$WORKER_TYPE" \
    --metadata "{\"retry_of\": \"$TASK_ID\"}"
```

---

## Prevention

### 1. Configure Appropriate Timeouts

Ensure workers have reasonable time limits:

```bash
# Check default time limits
cat $COMMIT_RELAY_HOME/coordination/config/worker-types.json | jq .
```

### 2. Enable Regular Check-ins

Workers should check in every 5-10 minutes. Verify PM daemon is monitoring:

```bash
# Check PM daemon is running
./scripts/health-check-pm-daemon.sh

# Verify check-in detection
jq '.configuration' $COMMIT_RELAY_HOME/coordination/pm-state.json
```

### 3. Monitor Worker Health

Run daemon-monitor regularly:

```bash
./scripts/dashboards/daemon-monitor.sh --status
```

### 4. Set Up Alerting

Configure health alerts for zombie threshold:

```bash
# Check alert configuration
jq '.alerts[] | select(.type == "zombie_threshold")' \
    $COMMIT_RELAY_HOME/coordination/health-alerts.json
```

---

## Quick Reference

| Issue | Command |
|-------|---------|
| Find worker spec | `jq . coordination/worker-specs/active/WORKER_ID.json` |
| Check worker process | `ps aux \| grep WORKER_ID` |
| List all zombies | `./scripts/cleanup-zombie-workers.sh --dry-run` |
| Clean up zombies | `./scripts/cleanup-zombie-workers.sh` |
| View stalled workers | `jq '.monitored_workers \| to_entries[] \| select(.value.health_state == "stalled")' coordination/pm-state.json` |
| Force fail worker | Move to failed/ and update status |
| Restart worker | Reset state and re-spawn |

---

## Related Runbooks

- [Self-Healing System](./self-healing-system.md)
- [Daemon Failure](./daemon-failure.md)
- [Worker Lifecycle](./worker-lifecycle.md)
- [Emergency Recovery](./emergency-recovery.md)

---

**Last Updated**: 2025-11-21
