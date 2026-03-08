# Worker Health Monitoring Guide

## Overview

Comprehensive health monitoring for commit-relay worker fleet with automated remediation.

## Health Check Types

### 1. Heartbeat Monitoring

**Frequency**: Every 30 seconds

**Checks**:
- Worker process alive
- Task progress updates
- Memory usage < 80%
- CPU usage < 90%

**Implementation**:
```bash
# scripts/daemons/heartbeat-monitor-daemon.sh
check_worker_heartbeat() {
  local worker_id="$1"
  local last_heartbeat=$(jq -r ".workers[] | select(.id==\"$worker_id\") | .last_heartbeat" coordination/worker-pool.json)
  local now=$(date +%s)
  local age=$((now - last_heartbeat))
  
  if [ $age -gt 120 ]; then
    emit_event "heartbeat_timeout" "$worker_id"
    restart_worker "$worker_id"
  fi
}
```

### 2. Zombie Detection

**Detection Criteria**:
- No heartbeat for 5+ minutes
- Process exists but unresponsive
- Stuck in same state for 10+ minutes

**Auto-remediation**:
```bash
# scripts/lib/zombie-cleanup.sh
cleanup_zombie_worker() {
  local worker_id="$1"
  
  # Kill process
  pkill -9 -f "worker-${worker_id}"
  
  # Clean up state
  rm -f "coordination/worker-specs/active/worker-${worker_id}.json"
  
  # Respawn if needed
  if should_respawn "$worker_id"; then
    spawn_replacement_worker "$worker_id"
  fi
}
```

### 3. Failure Pattern Detection

**Patterns Tracked**:
- Timeout failures (> 3 in 1 hour)
- OOM errors (memory exhaustion)
- API rate limit hits
- Dependency errors

**Response**:
```javascript
// coordination/config/failure-pattern-detection-policy.json
{
  "patterns": {
    "timeout": {
      "threshold": 3,
      "window": "1h",
      "action": "increase_timeout",
      "severity": "medium"
    },
    "oom": {
      "threshold": 2,
      "window": "30m",
      "action": "reduce_concurrency",
      "severity": "high"
    }
  }
}
```

## Metrics

### Worker Fleet Metrics

| Metric | Type | Description | Alert Threshold |
|--------|------|-------------|----------------|
| `worker.active_count` | Gauge | Currently active workers | < 2 (critical) |
| `worker.failure_rate` | Counter | Worker failures per hour | > 5 (warning) |
| `worker.avg_task_duration` | Histogram | Task completion time | > 300s (warning) |
| `worker.zombie_count` | Gauge | Detected zombie workers | > 0 (critical) |

### Individual Worker Metrics

```javascript
// Elastic APM labels
apm.setLabel('worker.id', workerId);
apm.setLabel('worker.type', workerType);
apm.setLabel('worker.state', currentState);
apm.setLabel('worker.memory_mb', memoryUsage);
apm.setLabel('worker.cpu_percent', cpuUsage);
```

## Dashboard Visualizations

### Kibana Queries

**Active Worker Count**:
```
GET apm-*/_search
{
  "query": {
    "bool": {
      "must": [
        {"term": {"labels.worker.state": "active"}},
        {"range": {"@timestamp": {"gte": "now-5m"}}}
      ]
    }
  },
  "aggs": {
    "worker_count": {"cardinality": {"field": "labels.worker.id"}}
  }
}
```

**Failure Rate Timeline**:
```
labels.worker.state: failed
| timechart count by labels.worker.type
```

## Auto-remediation Policies

### Restart Policy

```json
{
  "restart_conditions": [
    {
      "trigger": "heartbeat_timeout",
      "max_attempts": 3,
      "backoff": "exponential",
      "base_delay": 60
    },
    {
      "trigger": "crash",
      "max_attempts": 5,
      "backoff": "linear",
      "delay": 30
    }
  ]
}
```

### Resource Adjustment

```bash
# Automatic resource tuning
if [ $failure_pattern == "oom" ]; then
  # Reduce concurrency
  jq '.concurrency -= 1' worker-config.json > tmp.json && mv tmp.json worker-config.json
  restart_worker "$worker_id"
elif [ $failure_pattern == "timeout" ]; then
  # Increase timeout
  jq '.timeout_ms += 30000' worker-config.json > tmp.json && mv tmp.json worker-config.json
fi
```

## Monitoring CLI

```bash
# Check worker health
./scripts/lib/worker-health-check.sh

# View zombie workers
./scripts/lib/zombie-cleanup.sh --list

# Worker fleet status
coordination/pm-state.json | jq '.workers[] | {id, state, health}'
```

## Alerting

### Slack Integration

```bash
# Send alert
send_worker_alert() {
  local severity="$1"
  local message="$2"
  
  curl -X POST "$SLACK_WEBHOOK" \
    -d "{\"text\":\"⚠️ Worker Health Alert [$severity]: $message\"}"
}
```

### PagerDuty Escalation

```javascript
// Critical worker failures
if (zombieCount > 3) {
  await pagerduty.trigger({
    severity: 'critical',
    summary: `${zombieCount} zombie workers detected`,
    source: 'commit-relay-worker-health'
  });
}
```

---

**Last Updated**: 2025-11-25  
**Monitoring Interval**: 30s  
**Auto-remediation**: Enabled
