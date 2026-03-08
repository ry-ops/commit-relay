# Runbook: Daily Operations

Morning health check checklist and daily operational tasks.

---

## Overview

This runbook provides a daily checklist for maintaining Commit-Relay system health and ensuring optimal operation.

---

## Morning Health Check Checklist

### Quick Status Check (2 minutes)

```bash
# 1. System Dashboard
./scripts/dashboards/system-live.sh

# Press Ctrl+C after reviewing

# 2. Quick daemon status
./scripts/dashboards/daemon-monitor.sh --status
```

### Daemon Health (3 minutes)

```bash
# Check all daemons are running
for pidfile in /tmp/commit-relay-*.pid; do
    if [[ -f "$pidfile" ]]; then
        NAME=$(basename "$pidfile" .pid | sed 's/commit-relay-//')
        PID=$(cat "$pidfile")
        if ps -p $PID > /dev/null 2>&1; then
            UPTIME=$(ps -p $PID -o etime= | xargs)
            echo "[OK] $NAME (PID: $PID, Uptime: $UPTIME)"
        else
            echo "[FAIL] $NAME - Process dead"
        fi
    fi
done

# Expected daemons:
# - worker
# - pm
# - heartbeat
# - metrics
# - coordinator
# - auto-fix
# - failure-pattern
```

### Token Budget (2 minutes)

```bash
# Check token budget health
BUDGET=$(cat $COMMIT_RELAY_HOME/coordination/token-budget.json)
TOTAL=$(echo "$BUDGET" | jq -r '.total')
AVAILABLE=$(echo "$BUDGET" | jq -r '.available')
PCT=$((100 - (AVAILABLE * 100 / TOTAL)))

echo "Token Budget: ${PCT}% used, ${AVAILABLE} available"

# Alert if usage > 80%
if (( PCT > 80 )); then
    echo "[WARNING] Token budget usage high!"
fi
```

### Worker Status (3 minutes)

```bash
# Count workers by status
ACTIVE=$(ls $COMMIT_RELAY_HOME/coordination/worker-specs/active/ 2>/dev/null | wc -l | xargs)
ZOMBIE=$(ls $COMMIT_RELAY_HOME/coordination/worker-specs/zombie/ 2>/dev/null | wc -l | xargs)
COMPLETED=$(ls $COMMIT_RELAY_HOME/coordination/worker-specs/completed/ 2>/dev/null | wc -l | xargs)

echo "Workers: Active=$ACTIVE, Zombie=$ZOMBIE, Completed=$COMPLETED"

# Alert if zombies present
if (( ZOMBIE > 0 )); then
    echo "[WARNING] $ZOMBIE zombie workers need cleanup"
fi
```

### Task Queue (2 minutes)

```bash
# Check task queue status
QUEUED=$(cat $COMMIT_RELAY_HOME/coordination/task-queue.json | \
    jq '[.tasks[] | select(.status == "queued")] | length')
IN_PROGRESS=$(cat $COMMIT_RELAY_HOME/coordination/task-queue.json | \
    jq '[.tasks[] | select(.status == "in_progress")] | length')

echo "Tasks: Queued=$QUEUED, In Progress=$IN_PROGRESS"

# Alert if queue is stuck
if (( QUEUED > 10 && IN_PROGRESS == 0 )); then
    echo "[WARNING] Tasks queued but none in progress"
fi
```

### Health Alerts (2 minutes)

```bash
# Check recent health alerts
ALERTS=$(cat $COMMIT_RELAY_HOME/coordination/health-alerts.json | \
    jq '[.alerts[] | select(.severity == "critical")] | length')

if (( ALERTS > 0 )); then
    echo "[CRITICAL] $ALERTS critical alerts!"
    cat $COMMIT_RELAY_HOME/coordination/health-alerts.json | \
        jq '.alerts[] | select(.severity == "critical") | {message, timestamp}'
fi

# View last 5 alerts
cat $COMMIT_RELAY_HOME/coordination/health-alerts.json | jq '.alerts[-5:]'
```

### Disk Space (1 minute)

```bash
# Check disk usage
USAGE=$(df -h $COMMIT_RELAY_HOME | tail -1 | awk '{print $5}' | tr -d '%')
echo "Disk usage: ${USAGE}%"

if (( USAGE > 80 )); then
    echo "[WARNING] Disk space low!"
    du -sh $COMMIT_RELAY_HOME/agents/logs/*
fi
```

---

## Daily Maintenance Tasks

### 1. Cleanup Zombie Workers

```bash
# Run zombie cleanup
./scripts/cleanup-zombie-workers.sh

# Verify cleanup
ls $COMMIT_RELAY_HOME/coordination/worker-specs/zombie/ | wc -l
```

### 2. Rotate Logs

```bash
# Rotate dashboard events
./scripts/rotate-dashboard-events.sh

# Clean old worker logs (>7 days)
find $COMMIT_RELAY_HOME/agents/logs/workers -type f -mtime +7 -delete 2>/dev/null

# Trim metrics snapshots
tail -10000 $COMMIT_RELAY_HOME/coordination/metrics-snapshots.jsonl > /tmp/snapshots.jsonl
mv /tmp/snapshots.jsonl $COMMIT_RELAY_HOME/coordination/metrics-snapshots.jsonl
```

### 3. Review Pattern Detection

```bash
# Check for new high-confidence patterns
NEW_PATTERNS=$(cat $COMMIT_RELAY_HOME/coordination/patterns/failure-patterns.jsonl | \
    tail -50 | jq -s '[.[] | select(.confidence > 0.8)] | length')

echo "New high-confidence patterns: $NEW_PATTERNS"

# View patterns
if (( NEW_PATTERNS > 0 )); then
    cat $COMMIT_RELAY_HOME/coordination/patterns/failure-patterns.jsonl | \
        tail -50 | jq 'select(.confidence > 0.8) | {type, root_cause, confidence}'
fi
```

### 4. Check Auto-Fix Results

```bash
# Review auto-fix history
tail -20 $COMMIT_RELAY_HOME/coordination/metrics/auto-fix-history.jsonl | \
    jq '{result: .result, pattern: .pattern_id, time: .timestamp}'

# Success rate
SUCCESS=$(grep '"result":"success"' $COMMIT_RELAY_HOME/coordination/metrics/auto-fix-history.jsonl | wc -l)
TOTAL=$(wc -l < $COMMIT_RELAY_HOME/coordination/metrics/auto-fix-history.jsonl)
RATE=$((SUCCESS * 100 / (TOTAL + 1)))
echo "Auto-fix success rate: ${RATE}%"
```

### 5. Verify Metrics Collection

```bash
# Check metrics are being collected
LAST_SNAPSHOT=$(tail -1 $COMMIT_RELAY_HOME/coordination/metrics-snapshots.jsonl | \
    jq -r '.timestamp')
echo "Last metrics snapshot: $LAST_SNAPSHOT"

# Compare with current time
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "Current time: $NOW"
```

---

## Weekly Tasks

### Monday: Full System Review

```bash
# Generate health report
./scripts/generate-health-report.sh

# Review weekly metrics
cat $COMMIT_RELAY_HOME/coordination/health-reports.jsonl | tail -7 | jq .
```

### Wednesday: Configuration Audit

```bash
# Validate all JSON configs
for config in $COMMIT_RELAY_HOME/coordination/config/*.json; do
    jq empty "$config" 2>/dev/null && echo "[OK] $config" || echo "[FAIL] $config"
done

# Check MoE router config
jq '.rules | length' $COMMIT_RELAY_HOME/coordination/moe/router-config.json
```

### Friday: Log Archive

```bash
# Archive old logs
ARCHIVE_DIR="$COMMIT_RELAY_HOME/archives/logs/$(date +%Y-%m-%d)"
mkdir -p "$ARCHIVE_DIR"

# Move old worker logs
find $COMMIT_RELAY_HOME/agents/logs/workers -type f -mtime +7 -exec mv {} "$ARCHIVE_DIR/" \;

# Compress archive
tar -czf "${ARCHIVE_DIR}.tar.gz" "$ARCHIVE_DIR" && rm -rf "$ARCHIVE_DIR"
```

---

## Monitoring Dashboard Commands

### Real-Time Monitoring

```bash
# System overview (auto-refresh)
./scripts/dashboards/system-live.sh

# Daemon monitor with controls
./scripts/dashboards/daemon-monitor.sh

# Metrics with sparklines
./scripts/dashboards/metrics-dashboard.sh

# Worker details
./scripts/dashboards/worker-monitor.sh

# Task queue
./scripts/dashboards/task-queue-monitor.sh
```

### Ad-Hoc Queries

```bash
# Recent events
tail -20 $COMMIT_RELAY_HOME/coordination/dashboard-events.jsonl | jq .

# Active workers details
for spec in $COMMIT_RELAY_HOME/coordination/worker-specs/active/worker-*.json; do
    [[ -f "$spec" ]] && jq '{id: .worker_id, type: .worker_type, status: .status}' "$spec"
done

# Task completion rate
COMPLETED=$(cat $COMMIT_RELAY_HOME/coordination/task-queue.json | \
    jq '[.tasks[] | select(.status == "completed")] | length')
TOTAL=$(cat $COMMIT_RELAY_HOME/coordination/task-queue.json | jq '.tasks | length')
echo "Completion rate: $COMPLETED / $TOTAL"
```

---

## Troubleshooting Quick Reference

### Daemon Not Running

```bash
./scripts/dashboards/daemon-monitor.sh --start <daemon-name>
```

### Token Budget Full

```bash
./scripts/cleanup-zombie-workers.sh
```

### Tasks Stuck

```bash
# Check coordinator daemon
grep error $COMMIT_RELAY_HOME/agents/logs/system/coordinator-daemon.log | tail -10

# Restart coordinator
kill $(cat /tmp/commit-relay-coordinator.pid) && ./scripts/coordinator-daemon.sh &
```

### Workers Failing

```bash
# Check recent failures
tail -20 $COMMIT_RELAY_HOME/coordination/patterns/failure-patterns.jsonl | jq .
```

---

## Alert Response Guide

| Alert Severity | Response Time | Action |
|----------------|---------------|--------|
| Critical | Immediate | Page on-call, investigate |
| Warning | 15 minutes | Review and monitor |
| Info | Next check | Note and track |

### Critical Alert Actions

1. Check system dashboard
2. Identify affected component
3. Review related logs
4. Apply immediate fix
5. Document incident

### Warning Alert Actions

1. Note alert details
2. Check during next daily review
3. Plan corrective action
4. Update monitoring if needed

---

## Contact Information

- **System Logs**: `$COMMIT_RELAY_HOME/agents/logs/system/`
- **Health Reports**: `$COMMIT_RELAY_HOME/coordination/health-reports.jsonl`
- **Runbooks**: `$COMMIT_RELAY_HOME/docs/runbooks/`
- **Issue Tracker**: GitHub Issues

---

## Related Runbooks

- [Daemon Failure](./daemon-failure.md)
- [Worker Failure](./worker-failure.md)
- [Token Budget Exhaustion](./token-budget-exhaustion.md)
- [Emergency Recovery](./emergency-recovery.md)

---

**Last Updated**: 2025-11-21
