# Runbook: Performance Troubleshooting

Diagnosis and resolution for slow execution and bottlenecks.

---

## Symptoms

- Tasks taking longer than expected
- Workers not spawning quickly
- High CPU or memory usage
- Queue backing up
- Dashboard updates lagging
- API rate limiting
- Slow file I/O operations

---

## Root Causes

1. **Resource Exhaustion**: CPU, memory, or disk full
2. **API Rate Limiting**: Too many Claude API calls
3. **I/O Bottlenecks**: Slow disk or network
4. **Large Files**: Processing oversized data
5. **Concurrent Load**: Too many simultaneous workers
6. **Inefficient Code**: Bugs or poor algorithms
7. **Network Issues**: Latency or packet loss

---

## Diagnosis Steps

### 1. System Resources

```bash
# Check CPU usage
top -l 1 | head -10

# Check memory
vm_stat | head -20

# Check disk I/O
iostat -d 1 5

# Check disk space
df -h $COMMIT_RELAY_HOME

# Check open files
lsof | wc -l
lsof -p $(cat /tmp/commit-relay-worker.pid) | wc -l
```

### 2. Process Analysis

```bash
# Find resource-hungry processes
ps aux | grep commit-relay | sort -k3 -rn | head -10  # CPU
ps aux | grep commit-relay | sort -k4 -rn | head -10  # Memory

# Check specific daemon
DAEMON_PID=$(cat /tmp/commit-relay-worker.pid)
ps -p $DAEMON_PID -o pid,ppid,%cpu,%mem,vsz,rss,etime,command
```

### 3. Worker Performance

```bash
# Check worker execution times
for spec in $COMMIT_RELAY_HOME/coordination/worker-specs/completed/worker-*.json; do
    if [[ -f "$spec" ]]; then
        CREATED=$(jq -r '.created_at // ""' "$spec")
        COMPLETED=$(jq -r '.completed_at // ""' "$spec")
        TYPE=$(jq -r '.worker_type' "$spec")

        if [[ -n "$CREATED" && -n "$COMPLETED" ]]; then
            START=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${CREATED%%.*}" +%s 2>/dev/null || echo 0)
            END=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${COMPLETED%%.*}" +%s 2>/dev/null || echo 0)
            DURATION=$((END - START))
            echo "$TYPE: ${DURATION}s"
        fi
    fi
done | sort -t: -k2 -rn | head -10
```

### 4. Queue Metrics

```bash
# Queue wait times
cat $COMMIT_RELAY_HOME/coordination/task-queue.json | \
    jq '[.tasks[] | select(.started_at != null and .created_at != null)] |
        map({task_id, wait: (.started_at | sub("\\.[0-9]+"; "") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) -
                          (.created_at | sub("\\.[0-9]+"; "") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime)}) |
        sort_by(.wait) | reverse | .[0:5]'
```

### 5. API Performance

```bash
# Check for rate limiting in logs
grep -i "rate.*limit\|429\|too many" $COMMIT_RELAY_HOME/agents/logs/system/*.log | tail -20
grep -i "rate.*limit\|429\|too many" $COMMIT_RELAY_HOME/agents/logs/workers/**/*.log | tail -20
```

### 6. File System Performance

```bash
# Time file operations
time cat $COMMIT_RELAY_HOME/coordination/task-queue.json | jq '.tasks | length'

# Check for large files
find $COMMIT_RELAY_HOME -type f -size +100M -exec ls -lh {} \;

# Check file counts
echo "Worker specs: $(find $COMMIT_RELAY_HOME/coordination/worker-specs -name "*.json" | wc -l)"
echo "Events: $(wc -l < $COMMIT_RELAY_HOME/coordination/dashboard-events.jsonl)"
```

---

## Resolution Steps

### Resource Issues

#### Free Up Memory

```bash
# Stop unnecessary workers
./scripts/cleanup-zombie-workers.sh

# Clear caches
rm -rf /tmp/commit-relay-cache/*

# Reduce concurrent workers
jq '.max_concurrent_workers = 3' \
   $COMMIT_RELAY_HOME/coordination/config/system.json > /tmp/config.json && \
mv /tmp/config.json $COMMIT_RELAY_HOME/coordination/config/system.json
```

#### Free Up Disk Space

```bash
# Clean logs
find $COMMIT_RELAY_HOME/agents/logs -name "*.log*" -mtime +7 -delete

# Compress old events
gzip $COMMIT_RELAY_HOME/coordination/dashboard-events.jsonl.old.*

# Trim metrics
tail -5000 $COMMIT_RELAY_HOME/coordination/metrics-snapshots.jsonl > /tmp/snapshots.jsonl
mv /tmp/snapshots.jsonl $COMMIT_RELAY_HOME/coordination/metrics-snapshots.jsonl
```

### API Rate Limiting

#### Reduce Request Rate

```bash
# Increase delay between API calls
# Edit worker scripts to add delays

# Or reduce concurrent workers
jq '.max_concurrent_workers = 2' \
   $COMMIT_RELAY_HOME/coordination/config/system.json > /tmp/config.json && \
mv /tmp/config.json $COMMIT_RELAY_HOME/coordination/config/system.json
```

#### Implement Backoff

```bash
# Add to worker scripts:
# if [[ $response_code == 429 ]]; then
#     sleep $((2 ** retry_count))
# fi
```

### I/O Bottlenecks

#### Reduce File Operations

```bash
# Batch writes instead of frequent small writes
# Use memory buffers for temporary data

# Example: Write events in batches
# Collect events in array, write every N events
```

#### Optimize JSON Processing

```bash
# Use streaming for large files
jq -c '.tasks[]' $COMMIT_RELAY_HOME/coordination/task-queue.json | while read -r task; do
    # Process one at a time
    echo "$task" | jq '.task_id'
done

# Pre-filter before full parse
grep '"status":"queued"' $COMMIT_RELAY_HOME/coordination/task-queue.json | jq -c .
```

### Queue Optimization

#### Parallel Processing

```bash
# Ensure multiple workers can run
jq '.max_concurrent_workers = 5' \
   $COMMIT_RELAY_HOME/coordination/config/system.json > /tmp/config.json && \
mv /tmp/config.json $COMMIT_RELAY_HOME/coordination/config/system.json

# Verify daemons spawning workers
ps aux | grep worker-daemon
```

#### Priority Tuning

```bash
# Ensure high-priority tasks processed first
jq '.tasks |= sort_by(
    if .priority == "critical" then 0
    elif .priority == "high" then 1
    elif .priority == "medium" then 2
    else 3 end
)' $COMMIT_RELAY_HOME/coordination/task-queue.json > /tmp/queue.json && \
mv /tmp/queue.json $COMMIT_RELAY_HOME/coordination/task-queue.json
```

### Worker Performance

#### Reduce Token Budget

```bash
# Smaller budgets = faster completion
jq '.worker_types["analysis-worker"].default_budget = 30000' \
   $COMMIT_RELAY_HOME/coordination/config/worker-types.json > /tmp/types.json && \
mv /tmp/types.json $COMMIT_RELAY_HOME/coordination/config/worker-types.json
```

#### Simplify Tasks

Break complex tasks into smaller, focused subtasks that complete faster.

---

## Monitoring Performance

### Setup Performance Monitoring

```bash
# Add to crontab for regular checks
*/5 * * * * $COMMIT_RELAY_HOME/scripts/check-performance.sh >> /tmp/perf.log

# check-performance.sh content:
#!/bin/bash
echo "=== $(date) ==="
echo "CPU: $(top -l 1 | grep 'CPU usage' | head -1)"
echo "Mem: $(vm_stat | grep 'Pages free' | awk '{print $3}')"
echo "Queue: $(cat $COMMIT_RELAY_HOME/coordination/task-queue.json | jq '[.tasks[] | select(.status == "queued")] | length')"
echo "Workers: $(ls $COMMIT_RELAY_HOME/coordination/worker-specs/active/ | wc -l)"
```

### Performance Dashboard

```bash
# Use metrics dashboard
./scripts/dashboards/metrics-dashboard.sh

# Key metrics to watch:
# - Token usage trend
# - Worker count over time
# - Task completion rate
```

### Alert on Performance Issues

```bash
# In monitoring script:
QUEUE_SIZE=$(cat $COMMIT_RELAY_HOME/coordination/task-queue.json | \
    jq '[.tasks[] | select(.status == "queued")] | length')

if (( QUEUE_SIZE > 50 )); then
    ./scripts/emit-event.sh --type "performance_alert" --severity "warning" \
        --message "Queue size: $QUEUE_SIZE"
fi
```

---

## Performance Best Practices

### Worker Configuration

- Set appropriate token budgets (not too high)
- Use timeouts to prevent runaway workers
- Clean up completed workers promptly

### File Management

- Rotate logs regularly
- Trim large JSONL files
- Archive old data
- Avoid very large JSON files (split if >10MB)

### System Configuration

- Limit concurrent workers based on resources
- Use SSDs for coordination directory
- Keep adequate free disk space (>20%)
- Monitor and alert on resource usage

### Code Optimization

- Use streaming JSON processing
- Batch file writes
- Cache frequently accessed data
- Profile slow operations

---

## Verification

After applying fixes:

```bash
# 1. Check resource usage
top -l 1 | head -10

# 2. Check queue processing
watch -n 5 'cat $COMMIT_RELAY_HOME/coordination/task-queue.json | \
    jq "[.tasks[] | select(.status == \"queued\")] | length"'

# 3. Time a task
time ./scripts/create-task.sh --description "Performance test" --priority low

# 4. Check worker spawn time
# Monitor logs for spawn time

# 5. Verify no errors
grep -i "error\|timeout" $COMMIT_RELAY_HOME/agents/logs/system/*.log | tail -20
```

---

## Escalation

If performance issues persist:

1. Profile specific bottlenecks
2. Review recent changes
3. Check external dependencies
4. Consider hardware upgrades
5. Consult system architecture

---

## Related Runbooks

- [Token Budget Exhaustion](./token-budget-exhaustion.md)
- [Worker Failure](./worker-failure.md)
- [Daily Operations](./daily-operations.md)

---

**Last Updated**: 2025-11-21
