# Runbook: Daemon Management

Start/stop operations, log rotation, and daemon upgrades.

---

## Overview

This runbook covers the complete management of Commit-Relay daemons including startup, shutdown, log management, and upgrade procedures.

---

## Daemon Registry

| Daemon | PID File | Log File | Purpose |
|--------|----------|----------|---------|
| worker | `/tmp/commit-relay-worker.pid` | `worker-daemon.log` | Worker spawning |
| pm | `/tmp/commit-relay-pm.pid` | `pm-daemon.log` | Process management |
| heartbeat | `/tmp/commit-relay-heartbeat.pid` | `heartbeat-monitor-daemon.log` | Health monitoring |
| metrics | `/tmp/commit-relay-metrics.pid` | `metrics-snapshot-daemon.log` | Metrics collection |
| coordinator | `/tmp/commit-relay-coordinator.pid` | `coordinator-daemon.log` | Task coordination |
| integration | `/tmp/commit-relay-integration.pid` | `integration-validator-daemon.log` | Validation |
| failure-pattern | `/tmp/commit-relay-failure-pattern.pid` | `failure-pattern-daemon.log` | Pattern detection |
| auto-fix | `/tmp/commit-relay-auto-fix.pid` | `auto-fix-daemon.log` | Automatic fixes |

---

## Starting Daemons

### Start All Daemons

```bash
# Using startup script
./scripts/start-commit-relay.sh

# Using daemon control wizard
./scripts/wizards/daemon-control.sh
# Select option 1: Start all daemons
```

### Start Individual Daemon

```bash
# Using daemon monitor
./scripts/dashboards/daemon-monitor.sh --start <daemon-name>

# Example
./scripts/dashboards/daemon-monitor.sh --start worker

# Direct start
./scripts/worker-daemon.sh &
./scripts/daemons/heartbeat-monitor-daemon.sh &
./scripts/coordinator-daemon.sh &
```

### Start with Logging

```bash
# Start with output logged
DAEMON="worker"
LOG_FILE="$COMMIT_RELAY_HOME/agents/logs/system/${DAEMON}-daemon.log"
nohup ./scripts/${DAEMON}-daemon.sh >> "$LOG_FILE" 2>&1 &
echo $! > /tmp/commit-relay-${DAEMON}.pid
```

### Verify Startup

```bash
# Check daemon started
DAEMON="worker"
sleep 2
if [[ -f "/tmp/commit-relay-${DAEMON}.pid" ]]; then
    PID=$(cat "/tmp/commit-relay-${DAEMON}.pid")
    if ps -p $PID > /dev/null 2>&1; then
        echo "$DAEMON started successfully (PID: $PID)"
    else
        echo "ERROR: $DAEMON failed to start"
    fi
fi
```

---

## Stopping Daemons

### Stop All Daemons

```bash
# Graceful stop all
for pidfile in /tmp/commit-relay-*.pid; do
    if [[ -f "$pidfile" ]]; then
        PID=$(cat "$pidfile")
        NAME=$(basename "$pidfile" .pid | sed 's/commit-relay-//')
        if ps -p $PID > /dev/null 2>&1; then
            echo "Stopping $NAME (PID: $PID)"
            kill -TERM $PID
        fi
        rm -f "$pidfile"
    fi
done

# Wait for graceful shutdown
sleep 5

# Force kill any remaining
pkill -9 -f "commit-relay.*daemon" 2>/dev/null || true
```

### Stop Individual Daemon

```bash
# Using daemon monitor
./scripts/dashboards/daemon-monitor.sh --stop <daemon-name>

# Manual stop
DAEMON="worker"
PID_FILE="/tmp/commit-relay-${DAEMON}.pid"

if [[ -f "$PID_FILE" ]]; then
    PID=$(cat "$PID_FILE")
    if ps -p $PID > /dev/null 2>&1; then
        kill -TERM $PID
        echo "Sent SIGTERM to $DAEMON (PID: $PID)"

        # Wait for graceful shutdown
        sleep 5

        # Force if still running
        if ps -p $PID > /dev/null 2>&1; then
            kill -9 $PID
            echo "Force killed $DAEMON"
        fi
    fi
    rm -f "$PID_FILE"
fi
```

### Emergency Stop

```bash
# Kill everything immediately
pkill -9 -f "commit-relay"

# Clean up all PID files
rm -f /tmp/commit-relay-*.pid

echo "All daemons force stopped"
```

---

## Restarting Daemons

### Restart Single Daemon

```bash
# Using daemon monitor
./scripts/dashboards/daemon-monitor.sh --restart <daemon-name>

# Manual restart
DAEMON="worker"
./scripts/dashboards/daemon-monitor.sh --stop $DAEMON
sleep 2
./scripts/dashboards/daemon-monitor.sh --start $DAEMON
```

### Rolling Restart All

```bash
# Restart one at a time to maintain availability
for daemon in worker pm heartbeat metrics coordinator integration failure-pattern auto-fix; do
    echo "Restarting $daemon..."
    ./scripts/dashboards/daemon-monitor.sh --stop $daemon
    sleep 2
    ./scripts/dashboards/daemon-monitor.sh --start $daemon
    sleep 5  # Wait for stabilization
done

echo "Rolling restart complete"
```

---

## Log Management

### View Daemon Logs

```bash
# View specific daemon log
DAEMON="worker"
tail -100 $COMMIT_RELAY_HOME/agents/logs/system/${DAEMON}-daemon.log

# Follow log in real-time
tail -f $COMMIT_RELAY_HOME/agents/logs/system/${DAEMON}-daemon.log

# Search for errors
grep -i "error\|exception\|failed" $COMMIT_RELAY_HOME/agents/logs/system/${DAEMON}-daemon.log | tail -20
```

### Log Rotation

```bash
# Manual rotation for all daemon logs
LOG_DIR="$COMMIT_RELAY_HOME/agents/logs/system"
DATE=$(date +%Y%m%d)

for log in "$LOG_DIR"/*.log; do
    if [[ -f "$log" ]]; then
        # Rotate if larger than 10MB
        SIZE=$(stat -f%z "$log" 2>/dev/null || stat -c%s "$log")
        if (( SIZE > 10000000 )); then
            mv "$log" "${log}.${DATE}"
            gzip "${log}.${DATE}"
            echo "Rotated: $(basename $log)"
        fi
    fi
done
```

### Automated Log Rotation Setup

```bash
# Create logrotate config
cat > /etc/logrotate.d/commit-relay << 'EOF'
/path/to/commit-relay/agents/logs/system/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0644
    postrotate
        # Signal daemons to reopen logs
        pkill -HUP -f "commit-relay.*daemon" || true
    endscript
}
EOF
```

### Clean Old Logs

```bash
# Remove logs older than 14 days
find $COMMIT_RELAY_HOME/agents/logs -name "*.log*" -mtime +14 -delete

# Remove old compressed logs
find $COMMIT_RELAY_HOME/agents/logs -name "*.gz" -mtime +30 -delete

# Show remaining disk usage
du -sh $COMMIT_RELAY_HOME/agents/logs/
```

### Archive Logs

```bash
# Create archive
ARCHIVE_DATE=$(date +%Y-%m-%d)
ARCHIVE_DIR="$COMMIT_RELAY_HOME/archives/logs/$ARCHIVE_DATE"
mkdir -p "$ARCHIVE_DIR"

# Move old logs to archive
find $COMMIT_RELAY_HOME/agents/logs -name "*.log.*" -exec mv {} "$ARCHIVE_DIR/" \;

# Compress archive
cd "$(dirname $ARCHIVE_DIR)"
tar -czf "${ARCHIVE_DATE}.tar.gz" "$(basename $ARCHIVE_DIR)"
rm -rf "$ARCHIVE_DIR"
```

---

## Daemon Upgrades

### Pre-Upgrade Checklist

```bash
# 1. Check current version/state
git log --oneline -1

# 2. Verify no critical tasks
QUEUED=$(cat $COMMIT_RELAY_HOME/coordination/task-queue.json | \
    jq '[.tasks[] | select(.status == "in_progress" and .priority == "critical")] | length')
if (( QUEUED > 0 )); then
    echo "WARNING: Critical tasks in progress"
fi

# 3. Create backup
BACKUP_DIR="$COMMIT_RELAY_HOME/backups/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp -r $COMMIT_RELAY_HOME/coordination "$BACKUP_DIR/"
cp -r $COMMIT_RELAY_HOME/scripts "$BACKUP_DIR/"
echo "Backup created: $BACKUP_DIR"
```

### Upgrade Procedure

```bash
# 1. Stop all daemons
./scripts/dashboards/daemon-monitor.sh --stop-all

# Wait for workers to complete
sleep 30

# 2. Pull latest changes
cd $COMMIT_RELAY_HOME
git fetch origin
git checkout main
git pull origin main

# 3. Update dependencies (if any)
# npm install  # if using node

# 4. Run migrations (if any)
# ./scripts/migrate.sh

# 5. Validate scripts
for script in $COMMIT_RELAY_HOME/scripts/daemons/*.sh; do
    bash -n "$script" && echo "[OK] $script" || echo "[FAIL] $script"
done

# 6. Start daemons
./scripts/start-commit-relay.sh

# 7. Verify health
sleep 10
./scripts/dashboards/daemon-monitor.sh --status
```

### Rollback Procedure

```bash
# If upgrade fails
BACKUP_DIR="$COMMIT_RELAY_HOME/backups/YYYYMMDD_HHMMSS"  # Use actual backup

# 1. Stop daemons
./scripts/dashboards/daemon-monitor.sh --stop-all

# 2. Restore from backup
cp -r "$BACKUP_DIR/coordination/"* $COMMIT_RELAY_HOME/coordination/
cp -r "$BACKUP_DIR/scripts/"* $COMMIT_RELAY_HOME/scripts/

# 3. Restore git state
git checkout <previous-commit>

# 4. Restart
./scripts/start-commit-relay.sh
```

---

## Health Monitoring

### Check All Daemons

```bash
# Quick status
./scripts/dashboards/daemon-monitor.sh --status

# Detailed status
for pidfile in /tmp/commit-relay-*.pid; do
    if [[ -f "$pidfile" ]]; then
        NAME=$(basename "$pidfile" .pid | sed 's/commit-relay-//')
        PID=$(cat "$pidfile")

        if ps -p $PID > /dev/null 2>&1; then
            UPTIME=$(ps -p $PID -o etime= | xargs)
            MEM=$(ps -p $PID -o rss= | awk '{printf "%.1fMB", $1/1024}')
            CPU=$(ps -p $PID -o %cpu= | xargs)
            echo "[OK] $NAME - PID: $PID, Uptime: $UPTIME, Mem: $MEM, CPU: $CPU%"
        else
            echo "[DEAD] $NAME - PID file exists but process dead"
        fi
    fi
done
```

### Daemon Self-Check Script

```bash
# Add to crontab: */5 * * * * /path/to/check-daemons.sh

#!/bin/bash
for pidfile in /tmp/commit-relay-*.pid; do
    if [[ -f "$pidfile" ]]; then
        NAME=$(basename "$pidfile" .pid | sed 's/commit-relay-//')
        PID=$(cat "$pidfile")

        if ! ps -p $PID > /dev/null 2>&1; then
            echo "$(date): Restarting dead daemon: $NAME"
            $COMMIT_RELAY_HOME/scripts/dashboards/daemon-monitor.sh --start $NAME
        fi
    fi
done
```

---

## Configuration

### Daemon Settings

Each daemon may have configuration in `coordination/config/`:

```bash
# View daemon configs
ls $COMMIT_RELAY_HOME/coordination/config/*.json

# Example: heartbeat policy
cat $COMMIT_RELAY_HOME/coordination/config/heartbeat-policy.json | jq .

# Example: restart policy
cat $COMMIT_RELAY_HOME/coordination/config/worker-restart-policy.json | jq .
```

### Adjust Daemon Intervals

```bash
# Edit daemon scripts to change intervals
# Most daemons have a sleep interval in main loop

# Example: Change metrics snapshot interval
# Edit scripts/metrics-snapshot-daemon.sh
# Find: sleep 60
# Change to: sleep 30
```

---

## Troubleshooting

### Daemon Won't Start

1. Check for existing PID file
2. Verify script is executable
3. Check for syntax errors
4. Review log for startup errors
5. Check dependencies available

```bash
# Remove stale PID
rm -f /tmp/commit-relay-worker.pid

# Check script
bash -n ./scripts/worker-daemon.sh

# Check permissions
chmod +x ./scripts/worker-daemon.sh

# Try with debug
DEBUG=1 ./scripts/worker-daemon.sh
```

### Daemon Crashes Repeatedly

1. Check error logs
2. Review resource usage
3. Check for infinite loops
4. Verify configuration valid

```bash
# Check recent errors
grep -i "error\|fatal" $COMMIT_RELAY_HOME/agents/logs/system/*.log | tail -50

# Monitor resources
top -pid $(cat /tmp/commit-relay-worker.pid)
```

### High Resource Usage

```bash
# Find resource-heavy daemons
ps aux | grep commit-relay | sort -k3 -rn | head -5  # By CPU
ps aux | grep commit-relay | sort -k4 -rn | head -5  # By memory
```

---

## Related Runbooks

- [Daemon Failure](./daemon-failure.md)
- [Daily Operations](./daily-operations.md)
- [Emergency Recovery](./emergency-recovery.md)

---

**Last Updated**: 2025-11-21
