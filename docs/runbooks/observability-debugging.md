# Runbook: Observability Debugging

Diagnosis and resolution for missing events, trace issues, and monitoring gaps.

---

## Symptoms

- Events not appearing in dashboard
- Metrics not updating
- Missing log entries
- Broken event chains
- Inconsistent counts
- Stale data in dashboards
- Alerts not firing

---

## Root Causes

1. **Daemon Stopped**: Metrics/event daemons not running
2. **File Permissions**: Cannot write to event files
3. **Disk Full**: No space for new events
4. **Invalid Events**: Malformed event data
5. **Buffer Overflow**: Events discarded
6. **Time Sync**: Timestamp issues
7. **Configuration**: Wrong file paths

---

## Diagnosis Steps

### 1. Check Event Collection Daemons

```bash
# Check metrics snapshot daemon
ps aux | grep metrics-snapshot-daemon
cat /tmp/commit-relay-metrics.pid

# Check observability hub
ps aux | grep observability-hub-daemon

# View daemon logs
tail -50 $COMMIT_RELAY_HOME/agents/logs/system/metrics-snapshot-daemon.log
```

### 2. Check Event Files

```bash
# Verify event files exist and are writable
ls -la $COMMIT_RELAY_HOME/coordination/dashboard-events.jsonl
ls -la $COMMIT_RELAY_HOME/coordination/metrics-snapshots.jsonl

# Check permissions
if [[ ! -w "$COMMIT_RELAY_HOME/coordination/dashboard-events.jsonl" ]]; then
    echo "Cannot write to events file"
fi

# Check file size
du -sh $COMMIT_RELAY_HOME/coordination/dashboard-events.jsonl
```

### 3. Verify Recent Events

```bash
# Check if events are being written
LAST_EVENT=$(tail -1 $COMMIT_RELAY_HOME/coordination/dashboard-events.jsonl | jq -r '.timestamp')
echo "Last event: $LAST_EVENT"

# Compare with current time
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "Current time: $NOW"

# Count events in last hour
HOUR_AGO=$(date -v-1H -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -d '1 hour ago' -u +%Y-%m-%dT%H:%M:%SZ)
RECENT=$(grep -c "$HOUR_AGO" $COMMIT_RELAY_HOME/coordination/dashboard-events.jsonl || echo 0)
echo "Events in last hour: ~$RECENT"
```

### 4. Check Metrics Collection

```bash
# Verify metrics are being collected
LAST_SNAPSHOT=$(tail -1 $COMMIT_RELAY_HOME/coordination/metrics-snapshots.jsonl | jq -r '.timestamp')
echo "Last metrics snapshot: $LAST_SNAPSHOT"

# Check snapshot daemon interval
grep -i "sleep\|interval" $COMMIT_RELAY_HOME/scripts/metrics-snapshot-daemon.sh | head -5
```

### 5. Validate Event Format

```bash
# Check for malformed events
tail -100 $COMMIT_RELAY_HOME/coordination/dashboard-events.jsonl | while IFS= read -r line; do
    if ! echo "$line" | jq empty 2>/dev/null; then
        echo "Invalid: $line"
    fi
done

# Check required fields
tail -100 $COMMIT_RELAY_HOME/coordination/dashboard-events.jsonl | \
    jq -r 'select(.timestamp == null or .event_type == null) | .timestamp'
```

### 6. Check Event Emitters

```bash
# Verify emit-event script works
./scripts/emit-event.sh --type "test_event" --message "Testing" --severity "info"

# Check if event was written
tail -1 $COMMIT_RELAY_HOME/coordination/dashboard-events.jsonl | jq .
```

---

## Resolution Steps

### Fix Missing Daemons

```bash
# Start metrics snapshot daemon
if ! ps aux | grep -q metrics-snapshot-daemon; then
    ./scripts/metrics-snapshot-daemon.sh &
    echo "Started metrics snapshot daemon"
fi

# Start observability hub (if used)
if ! ps aux | grep -q observability-hub-daemon; then
    ./scripts/daemons/observability-hub-daemon.sh &
fi

# Verify started
sleep 2
./scripts/dashboards/daemon-monitor.sh --status
```

### Fix File Permissions

```bash
# Fix ownership
chown $(whoami) $COMMIT_RELAY_HOME/coordination/*.jsonl
chown $(whoami) $COMMIT_RELAY_HOME/coordination/*.json

# Fix permissions
chmod 644 $COMMIT_RELAY_HOME/coordination/dashboard-events.jsonl
chmod 644 $COMMIT_RELAY_HOME/coordination/metrics-snapshots.jsonl

# Create if missing
touch $COMMIT_RELAY_HOME/coordination/dashboard-events.jsonl
touch $COMMIT_RELAY_HOME/coordination/metrics-snapshots.jsonl
```

### Fix Disk Space

```bash
# Check disk space
df -h $COMMIT_RELAY_HOME

# Rotate events file
./scripts/rotate-dashboard-events.sh

# Trim metrics snapshots
tail -5000 $COMMIT_RELAY_HOME/coordination/metrics-snapshots.jsonl > /tmp/snapshots.jsonl
mv /tmp/snapshots.jsonl $COMMIT_RELAY_HOME/coordination/metrics-snapshots.jsonl

# Clean old logs
find $COMMIT_RELAY_HOME/agents/logs -name "*.log*" -mtime +7 -delete
```

### Fix Invalid Events

```bash
# Remove invalid lines from event file
EVENTS_FILE="$COMMIT_RELAY_HOME/coordination/dashboard-events.jsonl"
TEMP=$(mktemp)

while IFS= read -r line; do
    if echo "$line" | jq empty 2>/dev/null; then
        echo "$line"
    fi
done < "$EVENTS_FILE" > "$TEMP"

mv "$TEMP" "$EVENTS_FILE"
echo "Cleaned invalid events"
```

### Reset Event Collection

```bash
# Backup current events
cp $COMMIT_RELAY_HOME/coordination/dashboard-events.jsonl \
   $COMMIT_RELAY_HOME/coordination/dashboard-events.jsonl.backup.$(date +%s)

# Start fresh (if severely corrupted)
echo "" > $COMMIT_RELAY_HOME/coordination/dashboard-events.jsonl

# Restart daemons
kill $(cat /tmp/commit-relay-metrics.pid) 2>/dev/null
./scripts/metrics-snapshot-daemon.sh &
```

### Fix Event Gaps

```bash
# Manually emit missing events
./scripts/emit-event.sh --type "system_recovery" --message "Event collection restored" --severity "info"

# Generate backfill metrics snapshot
$COMMIT_RELAY_HOME/scripts/metrics-snapshot-daemon.sh --once
```

---

## Monitoring Observability Health

### Event Flow Check

```bash
# Create event flow test
echo "Testing event flow..."

# Emit test event
TEST_ID="test-$(date +%s)"
./scripts/emit-event.sh --type "flow_test" --message "$TEST_ID"

# Wait for processing
sleep 2

# Verify event recorded
if grep -q "$TEST_ID" $COMMIT_RELAY_HOME/coordination/dashboard-events.jsonl; then
    echo "[OK] Event flow working"
else
    echo "[FAIL] Event not recorded"
fi
```

### Metrics Collection Check

```bash
# Verify metrics collection
COUNT_BEFORE=$(wc -l < $COMMIT_RELAY_HOME/coordination/metrics-snapshots.jsonl)

# Wait for collection cycle
sleep 65  # Assuming 60-second interval

COUNT_AFTER=$(wc -l < $COMMIT_RELAY_HOME/coordination/metrics-snapshots.jsonl)

if (( COUNT_AFTER > COUNT_BEFORE )); then
    echo "[OK] Metrics collection working"
else
    echo "[FAIL] No new metrics"
fi
```

### Dashboard Data Check

```bash
# Verify dashboard can read data
./scripts/dashboards/system-live.sh &
DASH_PID=$!
sleep 5
kill $DASH_PID

# If no errors, dashboard working
```

---

## Configure Alerting

### Alert on Stale Data

```bash
# Check for stale events (no events in last 10 minutes)
LAST_TS=$(tail -1 $COMMIT_RELAY_HOME/coordination/dashboard-events.jsonl | jq -r '.timestamp')
LAST_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${LAST_TS%%.*}" +%s 2>/dev/null || echo 0)
NOW_EPOCH=$(date +%s)
AGE=$((NOW_EPOCH - LAST_EPOCH))

if (( AGE > 600 )); then
    ./scripts/emit-event.sh --type "observability_alert" --severity "warning" \
        --message "No events in ${AGE}s"
fi
```

### Alert on Missing Metrics

```bash
# Add to monitoring script
METRICS_AGE=$(stat -f%m $COMMIT_RELAY_HOME/coordination/metrics-snapshots.jsonl 2>/dev/null || echo 0)
NOW=$(date +%s)

if (( NOW - METRICS_AGE > 120 )); then
    echo "WARNING: Metrics file not updated in $((NOW - METRICS_AGE))s"
fi
```

---

## Event Types Reference

| Event Type | Description | Emitter |
|------------|-------------|---------|
| `worker_spawned` | New worker created | Worker daemon |
| `worker_completed` | Worker finished | Worker daemon |
| `worker_failed` | Worker failure | Heartbeat monitor |
| `task_queued` | Task added to queue | Task creation |
| `task_completed` | Task finished | Worker |
| `daemon_started` | Daemon started | Daemons |
| `health_check` | Health check result | Health monitor |
| `pattern_detected` | Failure pattern found | Pattern daemon |
| `auto_fix_applied` | Automatic fix executed | Auto-fix daemon |

---

## Troubleshooting Specific Issues

### Dashboard Shows Stale Data

1. Check metrics daemon running
2. Verify file timestamps updating
3. Clear browser cache
4. Check dashboard refresh interval

### Events Missing from Specific Component

1. Find component's emit calls
2. Verify emit-event.sh accessible
3. Check component logs for errors
4. Test emit manually from component

### Inconsistent Counts

1. Compare source files
2. Check for duplicate events
3. Verify count queries
4. Check for concurrent writes

---

## Verification

After fixes:

```bash
# 1. Check all daemons running
./scripts/dashboards/daemon-monitor.sh --status

# 2. Emit test event
./scripts/emit-event.sh --type "obs_test" --message "Verification test"

# 3. Check event recorded
tail -1 $COMMIT_RELAY_HOME/coordination/dashboard-events.jsonl | jq .

# 4. Check metrics updating
watch -n 10 'tail -1 $COMMIT_RELAY_HOME/coordination/metrics-snapshots.jsonl | jq .timestamp'

# 5. Verify dashboard shows data
./scripts/dashboards/system-live.sh
```

---

## Related Runbooks

- [Daemon Failure](./daemon-failure.md)
- [Data Quality Issues](./data-quality-issues.md)
- [Daily Operations](./daily-operations.md)

---

**Last Updated**: 2025-11-21
