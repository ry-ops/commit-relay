# Runbook: Self-Healing System

Configuration and troubleshooting for heartbeat monitoring, zombie detection, and auto-restart.

---

## Overview

The self-healing system automatically detects and recovers from failures using three main components:

1. **Heartbeat Monitor**: Detects unresponsive workers
2. **Zombie Detection**: Identifies stuck/dead workers
3. **Auto-Restart**: Restarts failed workers automatically

---

## Components

### Heartbeat Monitor Daemon

- **Script**: `scripts/daemons/heartbeat-monitor-daemon.sh`
- **PID File**: `/tmp/commit-relay-heartbeat.pid`
- **Log**: `agents/logs/system/heartbeat-monitor-daemon.log`
- **Events**: `coordination/events/heartbeat-events.jsonl`

### Failure Pattern Daemon

- **Script**: `scripts/daemons/failure-pattern-daemon.sh`
- **PID File**: `/tmp/commit-relay-failure-pattern.pid`
- **Log**: `agents/logs/system/failure-pattern-daemon.log`
- **Patterns**: `coordination/patterns/failure-patterns.jsonl`

### Auto-Fix Daemon

- **Script**: `scripts/daemons/auto-fix-daemon.sh`
- **PID File**: `/tmp/commit-relay-auto-fix.pid`
- **Log**: `agents/logs/system/auto-fix-daemon.log`
- **History**: `coordination/metrics/auto-fix-history.jsonl`

---

## Configuration

### Heartbeat Policy

```bash
# View heartbeat configuration
cat $COMMIT_RELAY_HOME/coordination/config/heartbeat-policy.json | jq .

# Example configuration:
cat > $COMMIT_RELAY_HOME/coordination/config/heartbeat-policy.json << 'EOF'
{
  "heartbeat_interval_seconds": 30,
  "heartbeat_timeout_seconds": 120,
  "zombie_threshold_seconds": 300,
  "health_score_decay_rate": 5,
  "min_health_score": 20
}
EOF
```

### Worker Restart Policy

```bash
# View restart policy
cat $COMMIT_RELAY_HOME/coordination/config/worker-restart-policy.json | jq .

# Example configuration:
cat > $COMMIT_RELAY_HOME/coordination/config/worker-restart-policy.json << 'EOF'
{
  "max_retries": 3,
  "retry_interval_seconds": 60,
  "backoff_multiplier": 2,
  "circuit_breaker_enabled": true,
  "circuit_breaker_threshold": 5,
  "circuit_breaker_reset_seconds": 300
}
EOF
```

### Auto-Fix Configuration

```bash
# View auto-fix settings
cat $COMMIT_RELAY_HOME/coordination/config/auto-fix-policy.json | jq .

# Example:
cat > $COMMIT_RELAY_HOME/coordination/config/auto-fix-policy.json << 'EOF'
{
  "enabled": true,
  "min_confidence_threshold": 0.7,
  "max_fixes_per_hour": 10,
  "dry_run": false,
  "notification_enabled": true
}
EOF
```

---

## Heartbeat Monitoring

### How It Works

1. Workers emit heartbeats at regular intervals
2. Monitor daemon checks all active workers
3. Missing heartbeats decrease health score
4. Workers below threshold marked as zombie

### Worker Heartbeat Emission

Workers should emit heartbeats using:

```bash
# In worker script
source $COMMIT_RELAY_HOME/scripts/lib/worker-heartbeat-emitter.sh

# Emit heartbeat
emit_heartbeat "$WORKER_ID" "$HEALTH_SCORE" "$PROGRESS"
```

### Check Heartbeat Status

```bash
# View worker heartbeats
for spec in $COMMIT_RELAY_HOME/coordination/worker-specs/active/worker-*.json; do
    if [[ -f "$spec" ]]; then
        ID=$(jq -r '.worker_id' "$spec")
        HEALTH=$(jq -r '.heartbeat.health_score // 0' "$spec")
        LAST=$(jq -r '.heartbeat.last_seen // "never"' "$spec")
        echo "$HEALTH% | $ID | $LAST"
    fi
done | sort -rn
```

### View Heartbeat Events

```bash
# Recent heartbeat events
tail -20 $COMMIT_RELAY_HOME/coordination/events/heartbeat-events.jsonl | jq .

# Find timeout events
grep "timeout\|missed" $COMMIT_RELAY_HOME/coordination/events/heartbeat-events.jsonl | tail -10
```

---

## Zombie Detection

### How It Works

1. Monitor checks worker last activity
2. Workers without heartbeat for threshold period
3. Marked as zombie and moved to zombie directory
4. Triggers cleanup and token recovery

### View Zombies

```bash
# List zombie workers
ls -la $COMMIT_RELAY_HOME/coordination/worker-specs/zombie/

# Get zombie details
for spec in $COMMIT_RELAY_HOME/coordination/worker-specs/zombie/worker-*.json; do
    if [[ -f "$spec" ]]; then
        ID=$(jq -r '.worker_id' "$spec")
        TYPE=$(jq -r '.worker_type' "$spec")
        ALLOCATED=$(jq -r '.token_budget.allocated // 0' "$spec")
        echo "$ID | $TYPE | $ALLOCATED tokens"
    fi
done
```

### Manual Zombie Cleanup

```bash
# Cleanup all zombies
./scripts/cleanup-zombie-workers.sh

# Cleanup specific zombie
./scripts/cleanup-zombie-workers.sh worker-implementation-001
```

### View Cleanup Events

```bash
# Recent cleanup events
grep "zombie_cleanup\|zombie_detected" $COMMIT_RELAY_HOME/coordination/events/zombie-cleanup-events.jsonl | tail -10 | jq .
```

---

## Auto-Restart

### How It Works

1. Failed worker detected by heartbeat monitor
2. Pattern daemon analyzes failure
3. Auto-fix daemon determines if restart appropriate
4. Worker respawned with same task
5. Circuit breaker prevents infinite loops

### Restart Queue

```bash
# View pending restarts
ls -la $COMMIT_RELAY_HOME/coordination/restart/queue/

# Check specific restart request
cat $COMMIT_RELAY_HOME/coordination/restart/queue/worker-*.json | jq .
```

### Restart History

```bash
# View restart history
tail -20 $COMMIT_RELAY_HOME/coordination/metrics/worker-restart-history.jsonl | jq .

# Success rate
SUCCESS=$(grep -c '"result":"success"' $COMMIT_RELAY_HOME/coordination/metrics/worker-restart-history.jsonl)
TOTAL=$(wc -l < $COMMIT_RELAY_HOME/coordination/metrics/worker-restart-history.jsonl)
echo "Restart success rate: $((SUCCESS * 100 / (TOTAL + 1)))%"
```

### Circuit Breakers

```bash
# View circuit breaker status
for cb in $COMMIT_RELAY_HOME/coordination/circuit-breakers/*.json; do
    if [[ -f "$cb" ]]; then
        TYPE=$(jq -r '.worker_type' "$cb")
        STATE=$(jq -r '.state' "$cb")
        COUNT=$(jq -r '.failure_count' "$cb")
        echo "$TYPE: $STATE ($COUNT failures)"
    fi
done
```

---

## Troubleshooting

### Heartbeats Not Being Received

1. Check heartbeat monitor daemon running
2. Verify workers emitting heartbeats
3. Check worker logs for emit errors
4. Verify file permissions

```bash
# Check daemon
ps aux | grep heartbeat-monitor-daemon

# Check recent heartbeats
tail -f $COMMIT_RELAY_HOME/coordination/events/heartbeat-events.jsonl | jq .

# Test heartbeat emission
./scripts/lib/worker-heartbeat-emitter.sh test-worker 100 50
```

### Workers Not Restarting

1. Check restart daemon running
2. Verify circuit breaker not tripped
3. Check restart queue
4. Review restart policy

```bash
# Check daemon
ps aux | grep worker-restart-daemon

# Check circuit breakers
cat $COMMIT_RELAY_HOME/coordination/circuit-breakers/*.json | jq '{type: .worker_type, state: .state}'

# Check queue
ls $COMMIT_RELAY_HOME/coordination/restart/queue/
```

### Too Many False Positives

1. Increase heartbeat timeout
2. Adjust health score thresholds
3. Increase zombie threshold

```bash
# Increase timeouts
jq '.heartbeat_timeout_seconds = 180 | .zombie_threshold_seconds = 600' \
   $COMMIT_RELAY_HOME/coordination/config/heartbeat-policy.json > /tmp/policy.json && \
mv /tmp/policy.json $COMMIT_RELAY_HOME/coordination/config/heartbeat-policy.json

# Restart daemon to apply
kill $(cat /tmp/commit-relay-heartbeat.pid) && \
./scripts/daemons/heartbeat-monitor-daemon.sh &
```

### Auto-Fix Not Working

1. Check auto-fix daemon running
2. Verify confidence threshold met
3. Check max fixes not exceeded
4. Review pattern detection

```bash
# Check daemon
ps aux | grep auto-fix-daemon

# Check recent patterns
tail -10 $COMMIT_RELAY_HOME/coordination/patterns/failure-patterns.jsonl | jq '{type, confidence}'

# Check fix history
tail -5 $COMMIT_RELAY_HOME/coordination/metrics/auto-fix-history.jsonl | jq .
```

---

## Testing Self-Healing

### Test Heartbeat Detection

```bash
# Create worker that will timeout
./scripts/spawn-worker.sh --type test-worker --task-id test-heartbeat --timeout 30

# Wait for zombie detection
sleep 180

# Check if marked as zombie
ls $COMMIT_RELAY_HOME/coordination/worker-specs/zombie/ | grep test
```

### Test Auto-Restart

```bash
# Manually create restart request
WORKER_ID="worker-test-001"
cat > $COMMIT_RELAY_HOME/coordination/restart/queue/${WORKER_ID}-restart.json << EOF
{
  "worker_id": "$WORKER_ID",
  "worker_type": "test-worker",
  "task_id": "test-task",
  "reason": "manual_test",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

# Watch for restart
tail -f $COMMIT_RELAY_HOME/agents/logs/system/worker-restart-daemon.log
```

### Test Circuit Breaker

```bash
# Trigger multiple failures
for i in {1..6}; do
    cat >> $COMMIT_RELAY_HOME/coordination/metrics/worker-restart-history.jsonl << EOF
{"worker_type":"test-worker","result":"failure","timestamp":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOF
done

# Check circuit breaker tripped
cat $COMMIT_RELAY_HOME/coordination/circuit-breakers/test-worker.json | jq .
```

---

## Metrics

### Self-Healing Metrics

```bash
# View metrics
cat $COMMIT_RELAY_HOME/coordination/metrics/heartbeat-monitor-metrics.json | jq .
cat $COMMIT_RELAY_HOME/coordination/metrics/worker-restart-metrics.json | jq .
cat $COMMIT_RELAY_HOME/coordination/metrics/auto-fix-daemon-metrics.json | jq .

# Key metrics:
# - Workers monitored
# - Heartbeats received
# - Zombies detected
# - Restarts attempted
# - Restarts succeeded
# - Fixes applied
```

### Health Score Distribution

```bash
# Distribution of worker health scores
for spec in $COMMIT_RELAY_HOME/coordination/worker-specs/active/worker-*.json; do
    jq -r '.heartbeat.health_score // 0' "$spec"
done | sort -n | uniq -c
```

---

## Verification

After configuration changes:

```bash
# 1. Restart all self-healing daemons
kill $(cat /tmp/commit-relay-heartbeat.pid) 2>/dev/null
kill $(cat /tmp/commit-relay-failure-pattern.pid) 2>/dev/null
kill $(cat /tmp/commit-relay-auto-fix.pid) 2>/dev/null

./scripts/daemons/heartbeat-monitor-daemon.sh &
./scripts/daemons/failure-pattern-daemon.sh &
./scripts/daemons/auto-fix-daemon.sh &

# 2. Verify daemons running
sleep 5
ps aux | grep -E "heartbeat|pattern|auto-fix"

# 3. Create test worker
./scripts/wizards/create-worker.sh

# 4. Monitor heartbeats
tail -f $COMMIT_RELAY_HOME/coordination/events/heartbeat-events.jsonl | jq .

# 5. Check no errors
grep -i error $COMMIT_RELAY_HOME/agents/logs/system/*daemon.log | tail -10
```

---

## Related Runbooks

- [Worker Failure](./worker-failure.md)
- [Circuit Breaker Tripped](./circuit-breaker-tripped.md)
- [Daemon Failure](./daemon-failure.md)

---

**Last Updated**: 2025-11-21
