# Runbook: Circuit Breaker Tripped

Diagnosis and resolution when circuit breakers prevent worker restarts.

---

## Symptoms

- Workers not automatically restarting after failure
- "Circuit breaker open" messages in logs
- Tasks stuck after worker failure
- Self-healing system not responding
- Worker restart daemon shows blocked restarts
- High failure count for specific worker types

---

## Root Causes

1. **Repeated Failures**: Too many failures in short time period
2. **Cascading Failures**: One failure causing others
3. **Resource Exhaustion**: System cannot handle restarts
4. **Configuration Error**: Invalid settings causing failures
5. **External Dependency**: API or service unavailable
6. **Bug in Worker**: Same error on every restart

---

## Diagnosis Steps

### 1. Check Circuit Breaker Status

```bash
# List all circuit breakers
ls $COMMIT_RELAY_HOME/coordination/circuit-breakers/

# Check specific circuit breaker
for cb in $COMMIT_RELAY_HOME/coordination/circuit-breakers/*.json; do
    if [[ -f "$cb" ]]; then
        echo "=== $(basename $cb) ==="
        jq . "$cb"
    fi
done
```

### 2. Review Circuit Breaker Events

```bash
# Find circuit breaker events
grep -i "circuit_breaker\|circuit-breaker" $COMMIT_RELAY_HOME/coordination/dashboard-events.jsonl | \
    tail -20 | jq .

# Check when breaker was tripped
grep "tripped\|opened" $COMMIT_RELAY_HOME/coordination/dashboard-events.jsonl | tail -10 | jq .
```

### 3. Analyze Failure Patterns

```bash
# Get worker type with tripped breaker
WORKER_TYPE="implementation-worker"

# Count recent failures
grep "$WORKER_TYPE" $COMMIT_RELAY_HOME/coordination/patterns/failure-patterns.jsonl | \
    jq -s 'length'

# See failure details
grep "$WORKER_TYPE" $COMMIT_RELAY_HOME/coordination/patterns/failure-patterns.jsonl | \
    tail -5 | jq .
```

### 4. Check Restart History

```bash
# View restart attempts
cat $COMMIT_RELAY_HOME/coordination/metrics/worker-restart-history.jsonl | tail -20 | jq .

# Count restarts by worker type
cat $COMMIT_RELAY_HOME/coordination/metrics/worker-restart-history.jsonl | \
    jq -s 'group_by(.worker_type) | map({type: .[0].worker_type, count: length})'
```

### 5. Review Worker Restart Policy

```bash
# Check restart policy configuration
cat $COMMIT_RELAY_HOME/coordination/config/worker-restart-policy.json | jq .

# Expected fields:
# - max_retries: 3
# - retry_interval_seconds: 60
# - circuit_breaker_threshold: 5
# - circuit_breaker_reset_seconds: 300
```

---

## Resolution Steps

### Immediate Actions

#### 1. Reset Specific Circuit Breaker

```bash
# Find and reset circuit breaker for worker type
WORKER_TYPE="implementation-worker"
CB_FILE="$COMMIT_RELAY_HOME/coordination/circuit-breakers/${WORKER_TYPE}.json"

if [[ -f "$CB_FILE" ]]; then
    # Reset to closed state
    cat > "$CB_FILE" << EOF
{
  "worker_type": "$WORKER_TYPE",
  "state": "closed",
  "failure_count": 0,
  "last_failure": null,
  "last_reset": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "manual_reset": true
}
EOF
    echo "Reset circuit breaker for $WORKER_TYPE"
fi
```

#### 2. Reset All Circuit Breakers

```bash
# Reset all circuit breakers
for cb in $COMMIT_RELAY_HOME/coordination/circuit-breakers/*.json; do
    if [[ -f "$cb" ]]; then
        WORKER_TYPE=$(jq -r '.worker_type' "$cb")
        cat > "$cb" << EOF
{
  "worker_type": "$WORKER_TYPE",
  "state": "closed",
  "failure_count": 0,
  "last_failure": null,
  "last_reset": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "manual_reset": true
}
EOF
        echo "Reset: $WORKER_TYPE"
    fi
done
```

#### 3. Delete Circuit Breaker Files

```bash
# Remove all circuit breaker state (forces fresh start)
rm -f $COMMIT_RELAY_HOME/coordination/circuit-breakers/*.json

echo "All circuit breakers cleared"
```

#### 4. Restart Worker Restart Daemon

```bash
# Restart the daemon to pick up new state
kill $(cat /tmp/commit-relay-worker-restart.pid) 2>/dev/null || true
sleep 1
./scripts/daemons/worker-restart-daemon.sh &
```

### Fix Underlying Issues

#### 1. Address Repeated Failure Pattern

```bash
# Identify common failure cause
grep "$WORKER_TYPE" $COMMIT_RELAY_HOME/coordination/patterns/failure-patterns.jsonl | \
    jq -s 'group_by(.root_cause) | map({cause: .[0].root_cause, count: length}) | sort_by(-.count)'

# If token exhaustion:
# - Increase worker budget
# - Simplify tasks

# If timeout:
# - Increase duration limit
# - Break into smaller tasks

# If API error:
# - Check Claude API status
# - Review rate limits
```

#### 2. Fix Configuration Issues

```bash
# Validate worker type configuration
WORKER_TYPE="implementation-worker"
jq --arg t "$WORKER_TYPE" '.worker_types[$t]' \
   $COMMIT_RELAY_HOME/coordination/config/worker-types.json

# Increase budget if too low
jq --arg t "$WORKER_TYPE" '.worker_types[$t].default_budget = 100000' \
   $COMMIT_RELAY_HOME/coordination/config/worker-types.json > /tmp/types.json && \
mv /tmp/types.json $COMMIT_RELAY_HOME/coordination/config/worker-types.json

# Increase timeout if too short
jq --arg t "$WORKER_TYPE" '.worker_types[$t].default_duration = 45' \
   $COMMIT_RELAY_HOME/coordination/config/worker-types.json > /tmp/types.json && \
mv /tmp/types.json $COMMIT_RELAY_HOME/coordination/config/worker-types.json
```

#### 3. Adjust Circuit Breaker Settings

```bash
# Increase threshold before tripping
jq '.circuit_breaker_threshold = 10 | .circuit_breaker_reset_seconds = 600' \
   $COMMIT_RELAY_HOME/coordination/config/worker-restart-policy.json > /tmp/policy.json && \
mv /tmp/policy.json $COMMIT_RELAY_HOME/coordination/config/worker-restart-policy.json
```

#### 4. Temporarily Disable Circuit Breaker

```bash
# Disable circuit breaker for specific worker type
jq '.circuit_breaker_enabled = false' \
   $COMMIT_RELAY_HOME/coordination/config/worker-restart-policy.json > /tmp/policy.json && \
mv /tmp/policy.json $COMMIT_RELAY_HOME/coordination/config/worker-restart-policy.json

# Remember to re-enable after fixing root cause!
```

---

## Prevention

### Configure Appropriate Thresholds

```bash
# Set reasonable circuit breaker settings
cat > $COMMIT_RELAY_HOME/coordination/config/worker-restart-policy.json << 'EOF'
{
  "max_retries": 3,
  "retry_interval_seconds": 60,
  "backoff_multiplier": 2,
  "circuit_breaker_enabled": true,
  "circuit_breaker_threshold": 5,
  "circuit_breaker_reset_seconds": 300,
  "circuit_breaker_half_open_requests": 1
}
EOF
```

### Monitor Circuit Breaker Events

```bash
# Add alerting for circuit breaker trips
# In monitoring script:
TRIPPED=$(grep '"state":"open"' $COMMIT_RELAY_HOME/coordination/circuit-breakers/*.json 2>/dev/null | wc -l)
if (( TRIPPED > 0 )); then
    ./scripts/emit-event.sh --type "circuit_breaker_alert" --severity "warning" \
        --message "$TRIPPED circuit breakers are open"
fi
```

### Implement Gradual Recovery

Use half-open state to test before fully closing:

```bash
# Set circuit breaker to half-open for testing
CB_FILE="$COMMIT_RELAY_HOME/coordination/circuit-breakers/${WORKER_TYPE}.json"
jq '.state = "half-open" | .test_requests = 0' "$CB_FILE" > /tmp/cb.json && \
mv /tmp/cb.json "$CB_FILE"
```

### Track Success After Reset

```bash
# Monitor first few restarts after reset
tail -f $COMMIT_RELAY_HOME/coordination/metrics/worker-restart-history.jsonl | \
    jq 'select(.worker_type == "implementation-worker") | {result: .result, time: .timestamp}'
```

---

## Verification

After resetting circuit breakers:

```bash
# 1. Verify circuit breakers are closed
for cb in $COMMIT_RELAY_HOME/coordination/circuit-breakers/*.json; do
    [[ -f "$cb" ]] && jq -r '"\(.worker_type): \(.state)"' "$cb"
done

# 2. Create test task to trigger restart
./scripts/create-task.sh --description "Test circuit breaker reset" --priority low

# 3. Monitor restart attempts
tail -f $COMMIT_RELAY_HOME/coordination/metrics/worker-restart-history.jsonl | jq .

# 4. Verify worker spawns successfully
ls $COMMIT_RELAY_HOME/coordination/worker-specs/active/

# 5. Check no new circuit breaker trips
sleep 60
grep '"state":"open"' $COMMIT_RELAY_HOME/coordination/circuit-breakers/*.json || echo "All breakers closed"
```

---

## Escalation

If circuit breakers keep tripping:

1. Review all failure patterns for root cause
2. Check Claude API status and limits
3. Analyze worker logs for common errors
4. Verify system resources (memory, disk)
5. Consider disabling affected worker types temporarily
6. Consult [Emergency Recovery](./emergency-recovery.md)

---

## Related Runbooks

- [Worker Failure](./worker-failure.md)
- [Self-Healing System](./self-healing-system.md)
- [Performance Troubleshooting](./performance-troubleshooting.md)

---

**Last Updated**: 2025-11-21
