# Commit-Relay Command Cheatsheet

Quick reference for common Commit-Relay operations.

---

## 🚀 Quick Start

```bash
# Set environment variable
export COMMIT_RELAY_HOME=/path/to/commit-relay

# Start all daemons
./scripts/wizards/daemon-control.sh  # Interactive
# or
./scripts/start-commit-relay.sh      # Automated

# Monitor system
./scripts/dashboards/system-live.sh

# Create your first worker
./scripts/wizards/create-worker.sh
```

---

## 📊 System Monitoring

### Real-Time Dashboards

```bash
# System overview (auto-refresh every 5s)
./scripts/dashboards/system-live.sh

# Daemon control center
./scripts/wizards/daemon-control.sh
```

### Manual Status Checks

```bash
# Check all daemon status
for pidfile in /tmp/commit-relay-*.pid; do
    [ -f "$pidfile" ] && ps -p $(cat "$pidfile") && echo "✓ $(basename $pidfile)" || echo "✗ $(basename $pidfile)"
done

# Check token budget
cat coordination/token-budget.json | jq '{used, available, total}'

# Check active workers
ls -la coordination/worker-specs/active/

# Check task queue
cat coordination/task-queue.json | jq '.tasks[] | {task_id, status, priority}'

# Check recent events
tail -20 coordination/dashboard-events.jsonl | jq .

# Check health alerts
cat coordination/health-alerts.json | jq '.alerts[-10:]'
```

---

## 👷 Worker Management

### Creating Workers

```bash
# Interactive wizard (recommended)
./scripts/wizards/create-worker.sh

# Manual spawn
./scripts/spawn-worker.sh \
  --type analysis-worker \
  --task-id task-001 \
  --master development-master \
  --priority high \
  --repo owner/repo
```

### Worker Types

| Type | Purpose | Default Budget | Duration |
|------|---------|----------------|----------|
| `scan-worker` | Security scanning | 70,000 | 15min |
| `fix-worker` | Apply fixes | 70,000 | 20min |
| `analysis-worker` | Research/investigation | 50,000 | 15min |
| `implementation-worker` | Feature development | 100,000 | 45min |
| `test-worker` | Test creation | 70,000 | 20min |
| `review-worker` | Code review | 50,000 | 15min |
| `pr-worker` | Create PRs | 30,000 | 10min |
| `documentation-worker` | Write docs | 70,000 | 20min |

### Monitoring Workers

```bash
# List all active workers
ls coordination/worker-specs/active/

# Check specific worker
cat coordination/worker-specs/active/worker-<ID>.json | jq .

# Check worker health
cat coordination/worker-specs/active/worker-<ID>.json | jq '.heartbeat'

# View worker logs
tail -f agents/logs/workers/<date>/worker-<ID>/worker.log

# Search for errors in logs
grep -i "error" agents/logs/workers/<date>/worker-<ID>/worker.log

# Check worker status script
./scripts/worker-status.sh
```

### Cleanup Workers

```bash
# Cleanup specific zombie worker
./scripts/cleanup-zombie-workers.sh worker-<ID>

# List zombie workers
ls -la coordination/worker-specs/zombie/

# Check zombie cleanup history
cat coordination/worker-specs/zombie/worker-<ID>.json | jq '.cleanup_metadata'
```

---

## 🔧 Daemon Management

### Daemon Control

```bash
# Interactive control center (recommended)
./scripts/wizards/daemon-control.sh

# Start all daemons
./scripts/start-commit-relay.sh

# Stop all daemons
pkill -f "commit-relay.*daemon"
```

### Individual Daemon Control

```bash
# Start specific daemon
scripts/worker-daemon.sh &
scripts/pm-daemon.sh &
scripts/daemons/heartbeat-monitor-daemon.sh &
scripts/metrics-snapshot-daemon.sh &
scripts/coordinator-daemon.sh &
scripts/integration-validator-daemon.sh &
scripts/daemons/failure-pattern-daemon.sh &
scripts/daemons/worker-restart-daemon.sh &
scripts/daemons/auto-fix-daemon.sh &

# Check daemon PID
cat /tmp/commit-relay-<daemon>.pid

# Kill specific daemon
kill $(cat /tmp/commit-relay-<daemon>.pid)
```

### Daemon Logs

```bash
# View daemon logs
tail -f agents/logs/system/failure-pattern-daemon.log
tail -f agents/logs/system/worker-restart-daemon.log
tail -f agents/logs/system/auto-fix-daemon.log
tail -f agents/logs/system/heartbeat-monitor-daemon.log

# Search for errors in all daemon logs
grep -r "error" agents/logs/system/

# Check daemon activity
grep -i "cycle" agents/logs/system/*.log
```

---

## 📋 Task Management

### Task Queue

```bash
# View all tasks
cat coordination/task-queue.json | jq .

# Filter by status
cat coordination/task-queue.json | jq '.tasks[] | select(.status == "queued")'
cat coordination/task-queue.json | jq '.tasks[] | select(.status == "in_progress")'
cat coordination/task-queue.json | jq '.tasks[] | select(.status == "completed")'

# Count tasks by status
cat coordination/task-queue.json | jq '[.tasks[] | .status] | group_by(.) | map({status: .[0], count: length})'

# Check specific task
cat coordination/task-queue.json | jq '.tasks[] | select(.task_id == "task-001")'
```

### Task Creation

```bash
# Create task (manual)
cat > coordination/tasks/task-001.json <<EOF
{
  "task_id": "task-001",
  "description": "Task description",
  "priority": "high",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

# Add to queue
# (Use task creation wizard - coming soon)
```

---

## 💰 Token Budget

### Check Budget

```bash
# Current budget
cat coordination/token-budget.json | jq .

# Available tokens
cat coordination/token-budget.json | jq '.available'

# Token usage percentage
cat coordination/token-budget.json | jq '((.used / .total) * 100 | floor)'

# Token budget history
cat coordination/metrics-snapshots.jsonl | tail -20 | jq -r '[.timestamp, .token_budget.available] | @tsv'
```

### Budget Management

```bash
# Cleanup zombies to recover tokens
./scripts/cleanup-zombie-workers.sh

# Check zombie token allocation
for zombie in coordination/worker-specs/zombie/*.json; do
    echo "$(basename $zombie): $(jq -r '.token_budget.allocated // 0' $zombie) tokens"
done

# Manual budget adjustment (emergency only)
# Edit coordination/token-budget.json
```

---

## 🔍 Debugging & Troubleshooting

### System Health

```bash
# Quick health check
./scripts/wizards/daemon-control.sh
# Select option 8: Health check

# Check system health file
cat coordination/system-health-check.json | jq .

# Check health reports
cat coordination/health-reports.jsonl | tail -10 | jq .

# Check routing health
cat coordination/routing-health.json | jq .
```

### Log Analysis

```bash
# All daemon logs
ls -la agents/logs/system/

# All worker logs
ls -la agents/logs/workers/

# Search for specific error
grep -r "error_code" agents/logs/

# Find failed workers
grep -r "failed" coordination/worker-specs/

# Check observability events
grep "error" coordination/dashboard-events.jsonl | tail -20 | jq .
```

### Pattern Detection

```bash
# View detected patterns
cat coordination/patterns/failure-patterns.jsonl | jq .

# High-confidence patterns
cat coordination/patterns/failure-patterns.jsonl | jq 'select(.confidence > 0.7)'

# Patterns by category
cat coordination/patterns/failure-patterns.jsonl | jq -s 'group_by(.category) | map({category: .[0].category, count: length})'

# Pattern detection metrics
cat coordination/metrics/failure-pattern-metrics.json | jq .
```

### Auto-Fix

```bash
# View auto-fix history
cat coordination/auto-fix/fix-history.jsonl | jq .

# Recent fixes
cat coordination/auto-fix/fix-history.jsonl | tail -10 | jq .

# Successful fixes
cat coordination/auto-fix/fix-history.jsonl | jq 'select(.status == "success")'

# Fix success rate
cat coordination/auto-fix/fix-history.jsonl | jq -s '[group_by(.status) | .[] | {status: .[0].status, count: length}]'
```

---

## 🏥 Self-Healing System

### Heartbeat Monitoring

```bash
# Check heartbeat monitor daemon
ps aux | grep heartbeat-monitor-daemon

# View heartbeat logs
tail -f agents/logs/system/heartbeat-monitor-daemon.log

# Check worker heartbeats
cat coordination/worker-specs/active/worker-<ID>.json | jq '.heartbeat'

# Heartbeat events
grep "heartbeat" coordination/dashboard-events.jsonl | tail -20 | jq .
```

### Worker Restart

```bash
# Check restart daemon
ps aux | grep worker-restart-daemon

# View restart logs
tail -f agents/logs/system/worker-restart-daemon.log

# Check restart queue
ls -la coordination/restart-queue/

# Restart policy
cat coordination/config/worker-restart-policy.json | jq .

# Circuit breaker status
grep "circuit_breaker" coordination/dashboard-events.jsonl | tail -10 | jq .
```

### Zombie Detection

```bash
# List zombies
ls -la coordination/worker-specs/zombie/

# Zombie cleanup policy
cat coordination/config/zombie-cleanup-policy.json | jq .

# Recent zombie cleanups
grep "zombie" coordination/dashboard-events.jsonl | tail -20 | jq .
```

---

## 📈 Metrics & Analytics

### Historical Metrics

```bash
# Recent snapshots
tail -20 coordination/metrics-snapshots.jsonl | jq .

# Worker count over time
cat coordination/metrics-snapshots.jsonl | jq -r '[.timestamp, .workers.active] | @tsv'

# Task completion rate
cat coordination/metrics-snapshots.jsonl | jq -r '[.timestamp, .tasks.completed] | @tsv'

# Token budget over time
cat coordination/metrics-snapshots.jsonl | jq -r '[.timestamp, .token_budget.available] | @tsv'
```

### Performance Analysis

```bash
# Average worker completion time
# (Parse worker logs - TODO: add helper script)

# Task throughput
cat coordination/task-queue.json | jq '[.tasks[] | select(.status == "completed")] | length'

# Failure rate
cat coordination/patterns/failure-patterns.jsonl | wc -l
```

---

## 🔐 Governance

### PII Scanning

```bash
# Scan file for PII
./coordination/governance/lib/pii-scanner.sh <file>

# PII scan reports
ls -la coordination/governance/reports/pii/

# Recent PII detections
grep "pii_detected" coordination/governance/access-log.jsonl | tail -10 | jq .
```

### Quality Monitoring

```bash
# Check data quality
./coordination/governance/lib/quality-monitor.sh <file>

# Quality reports
ls -la coordination/governance/reports/quality/

# Quality metrics
cat coordination/governance/quality-metrics.json | jq .
```

### Bypass Auditing

```bash
# Audit log
cat coordination/governance/access-log.jsonl | jq .

# Bypass attempts
cat coordination/governance/access-log.jsonl | jq 'select(.action == "bypass_attempt")'

# Approval workflow
cat coordination/governance/approval-workflow.json | jq .
```

---

## 🚨 Emergency Procedures

### System-Wide Issues

```bash
# Stop all workers
pkill -f "worker-.*"

# Stop all daemons
pkill -f "commit-relay.*daemon"

# Restart system
./scripts/start-commit-relay.sh

# Check system status
./scripts/dashboards/system-live.sh
```

### Critical Failures

```bash
# View critical alerts
cat coordination/health-alerts.json | jq '.alerts[] | select(.severity == "critical")'

# Emergency worker cleanup
find coordination/worker-specs/active/ -name "*.json" -mtime +1 -exec mv {} coordination/worker-specs/zombie/ \;

# Reset token budget (CAREFUL!)
# Manually edit coordination/token-budget.json

# Clear circuit breakers
# Delete coordination/circuit-breakers/*.json
```

### Recovery

```bash
# Restore from backup
# (Implement backup strategy - TODO)

# Reset state files
# rm coordination/orchestrator/state/current.json
# rm coordination/pm-state.json

# Reinitialize system
# ./scripts/init-system.sh (TODO: create this)
```

---

## 📚 Documentation

### Quick Links

```bash
# Quick start guide
cat docs/QUICK-START.md

# Phase 5 plan
cat docs/PHASE-5-DEVELOPER-EXPERIENCE.md

# Implementation status
cat IMPLEMENTATION-STATUS.md

# Architecture docs
ls -la docs/*.md
```

### Runbooks

```bash
# List all runbooks
ls -la docs/runbooks/

# Worker failure
cat docs/runbooks/worker-failure.md

# Daemon failure
cat docs/runbooks/daemon-failure.md

# Daily operations
cat docs/runbooks/daily-operations.md
```

---

## 🛠️ Common Workflows

### Daily Operations

```bash
# 1. Check system health
./scripts/dashboards/system-live.sh

# 2. Check daemons
./scripts/wizards/daemon-control.sh

# 3. Review alerts
cat coordination/health-alerts.json | jq '.alerts[-10:]'

# 4. Check token budget
cat coordination/token-budget.json | jq '{available, used, total}'

# 5. Cleanup zombies (if needed)
./scripts/cleanup-zombie-workers.sh
```

### Spawn and Monitor Worker

```bash
# 1. Create worker
./scripts/wizards/create-worker.sh

# 2. Monitor in dashboard
./scripts/dashboards/system-live.sh

# 3. Check logs
tail -f agents/logs/workers/$(date +%Y-%m-%d)/worker-*/worker.log

# 4. Verify completion
cat coordination/task-queue.json | jq '.tasks[] | select(.task_id == "task-001")'
```

### Troubleshoot Worker Failure

```bash
# 1. Identify failed worker
ls coordination/worker-specs/zombie/

# 2. Check worker logs
cat agents/logs/workers/<date>/worker-<ID>/worker.log

# 3. Check pattern detection
cat coordination/patterns/failure-patterns.jsonl | jq 'select(.worker_id == "worker-<ID>")'

# 4. Check auto-fix suggestions
cat coordination/auto-fix/fix-history.jsonl | jq 'select(.pattern_id | contains("worker-<ID>"))'

# 5. Manual cleanup (if needed)
./scripts/cleanup-zombie-workers.sh worker-<ID>
```

---

## 💡 Tips & Tricks

### Productivity Boosters

```bash
# Create aliases for common commands
alias cr-dash='cd $COMMIT_RELAY_HOME && ./scripts/dashboards/system-live.sh'
alias cr-worker='cd $COMMIT_RELAY_HOME && ./scripts/wizards/create-worker.sh'
alias cr-daemon='cd $COMMIT_RELAY_HOME && ./scripts/wizards/daemon-control.sh'
alias cr-budget='cat $COMMIT_RELAY_HOME/coordination/token-budget.json | jq .'

# Watch logs in real-time
watch -n 5 'tail -20 $COMMIT_RELAY_HOME/coordination/dashboard-events.jsonl | jq .'

# Auto-refresh daemon status
watch -n 10 'ps aux | grep "commit-relay.*daemon"'
```

### jq Filters

```bash
# Pretty print JSON
cat file.json | jq .

# Get specific field
cat file.json | jq '.field'

# Filter array
cat file.json | jq '.items[] | select(.status == "active")'

# Count items
cat file.json | jq '.items | length'

# Group by field
cat file.json | jq 'group_by(.status) | map({status: .[0].status, count: length})'
```

---

## 🔗 Related Resources

- [Quick Start Guide](./QUICK-START.md) - Get started in <30 minutes
- [Worker Failure Runbook](./runbooks/worker-failure.md) - Handle worker issues
- [Daemon Failure Runbook](./runbooks/daemon-failure.md) - Recover daemons
- [Daily Operations](./runbooks/daily-operations.md) - Daily checklist
- [Implementation Status](../IMPLEMENTATION-STATUS.md) - System status

---

## 🆘 Getting Help

Can't find what you need?

1. Check the [Quick Start Guide](./QUICK-START.md)
2. Search [runbooks](./runbooks/)
3. Check [GitHub Issues](https://github.com/ry-ops/commit-relay/issues)
4. Review system logs: `agents/logs/system/`

---

**Last Updated**: 2025-11-18

**Pro Tip**: Keep this cheatsheet bookmarked for quick reference!
