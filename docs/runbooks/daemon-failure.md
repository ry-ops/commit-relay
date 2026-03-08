# Runbook: Daemon Failure

Diagnosis and resolution for daemon stopped or unhealthy conditions.

---

## Overview

This runbook covers daemon failure scenarios including:
- Daemon process stopped unexpectedly
- Daemon running but not functioning correctly
- Stale PID files
- Configuration issues preventing startup

---

## Symptoms

### Daemon Stopped
- PID file missing or contains invalid PID
- No process running
- No updates to state files
- Tasks not being processed

### Daemon Unhealthy
- PID file exists and process running
- But no activity in logs
- State file timestamps not updating
- No new events being generated

### Startup Failures
- Daemon exits immediately after start
- Error messages in logs
- "Already running" errors with stale PID

---

## Diagnostic Commands

### 1. Check All Daemon Status

```bash
# Quick status check
./scripts/dashboards/daemon-monitor.sh --status

# Detailed check
for pid_file in /tmp/pm-daemon.pid /tmp/coordinator-daemon.pid /tmp/heartbeat-monitor.pid /tmp/zombie-killer.pid /tmp/metrics-snapshot-daemon.pid /tmp/governance-monitor.pid; do
    daemon=$(basename "$pid_file" .pid)
    if [ -f "$pid_file" ]; then
        pid=$(cat "$pid_file")
        if ps -p "$pid" > /dev/null 2>&1; then
            echo "$daemon: RUNNING (PID $pid)"
        else
            echo "$daemon: STALE PID FILE"
        fi
    else
        echo "$daemon: STOPPED"
    fi
done
```

### 2. Check Specific Daemon

```bash
# PM Daemon
DAEMON_NAME="pm-daemon"
PID_FILE="/tmp/${DAEMON_NAME}.pid"
LOG_FILE="$COMMIT_RELAY_HOME/agents/logs/system/${DAEMON_NAME}.log"

# Check PID
if [ -f "$PID_FILE" ]; then
    pid=$(cat "$PID_FILE")
    ps -p "$pid" -o pid,ppid,etime,comm
fi

# Check recent logs
tail -50 "$LOG_FILE"

# Check state file freshness
ls -la $COMMIT_RELAY_HOME/coordination/pm-state.json
stat -f "%Sm" $COMMIT_RELAY_HOME/coordination/pm-state.json
```

### 3. Check for Errors

```bash
# Search for errors in PM daemon log
grep -i "error\|fatal\|exception" \
    $COMMIT_RELAY_HOME/agents/logs/system/pm-daemon.log | tail -20

# Check if daemon exited abnormally
grep -i "stopped\|exit\|crash" \
    $COMMIT_RELAY_HOME/agents/logs/system/pm-daemon.log | tail -10
```

### 4. Verify State File Freshness

```bash
# Check PM state last update
jq -r '.pm_daemon.last_loop' $COMMIT_RELAY_HOME/coordination/pm-state.json

# Calculate minutes since last update
LAST_LOOP=$(jq -r '.pm_daemon.last_loop' $COMMIT_RELAY_HOME/coordination/pm-state.json)
NOW=$(date +%s)
THEN=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$LAST_LOOP" +%s 2>/dev/null || echo 0)
AGE_MIN=$(((NOW - THEN) / 60))
echo "PM daemon last active: $AGE_MIN minutes ago"
```

---

## Resolution Steps

### A. Restart Stopped Daemon

```bash
# Remove stale PID file
rm -f /tmp/pm-daemon.pid

# Start daemon
./scripts/pm-daemon.sh &

# Verify startup
sleep 5
./scripts/dashboards/daemon-monitor.sh --status
```

### B. Fix Stale PID File

```bash
# Check if process is actually dead
PID_FILE="/tmp/pm-daemon.pid"
if [ -f "$PID_FILE" ]; then
    pid=$(cat "$PID_FILE")
    if ! ps -p "$pid" > /dev/null 2>&1; then
        echo "Removing stale PID file"
        rm -f "$PID_FILE"
    fi
fi

# Start daemon
./scripts/pm-daemon.sh &
```

### C. Diagnose Startup Failure

```bash
# Run daemon in foreground to see errors
bash -x ./scripts/pm-daemon.sh 2>&1 | head -100

# Check for permission issues
ls -la $COMMIT_RELAY_HOME/coordination/pm-state.json
ls -la $COMMIT_RELAY_HOME/agents/logs/system/

# Check for disk space
df -h $COMMIT_RELAY_HOME

# Validate required files
for file in coordination/pm-state.json coordination/task-queue.json; do
    if [ ! -f "$COMMIT_RELAY_HOME/$file" ]; then
        echo "MISSING: $file"
    fi
done
```

### D. Reset Daemon State

If daemon state is corrupted:

```bash
# Backup current state
cp $COMMIT_RELAY_HOME/coordination/pm-state.json \
   $COMMIT_RELAY_HOME/coordination/pm-state.json.backup

# Stop daemon
pkill -f "pm-daemon" || true
rm -f /tmp/pm-daemon.pid

# Re-initialize state
rm -f $COMMIT_RELAY_HOME/coordination/pm-state.json

# Start daemon (will re-initialize)
./scripts/pm-daemon.sh &
```

### E. Restart All Daemons

```bash
# Stop all daemons
./scripts/dashboards/daemon-monitor.sh --stop-all

# Wait for cleanup
sleep 5

# Remove any stale PIDs
rm -f /tmp/pm-daemon.pid /tmp/coordinator-daemon.pid \
      /tmp/heartbeat-monitor.pid /tmp/zombie-killer.pid \
      /tmp/metrics-snapshot-daemon.pid /tmp/governance-monitor.pid

# Start all daemons
./scripts/dashboards/daemon-monitor.sh --start-all

# Verify
./scripts/dashboards/daemon-monitor.sh --status
```

### F. Fix Configuration Issues

```bash
# Validate daemon config
jq empty $COMMIT_RELAY_HOME/coordination/config/daemon-config.json || \
    echo "Invalid daemon config"

# Check environment
echo "COMMIT_RELAY_HOME: $COMMIT_RELAY_HOME"
ls -la $COMMIT_RELAY_HOME/scripts/pm-daemon.sh

# Check permissions
chmod +x $COMMIT_RELAY_HOME/scripts/*.sh
```

---

## Daemon-Specific Recovery

### PM Daemon

```bash
# Stop
pkill -f "pm-daemon" || true
rm -f /tmp/pm-daemon.pid

# Clear PM monitoring state (optional, keeps workers but resets monitoring)
jq '.monitored_workers = {}' \
    $COMMIT_RELAY_HOME/coordination/pm-state.json > \
    $COMMIT_RELAY_HOME/coordination/pm-state.json.tmp && \
    mv $COMMIT_RELAY_HOME/coordination/pm-state.json.tmp \
       $COMMIT_RELAY_HOME/coordination/pm-state.json

# Start
./scripts/pm-daemon.sh &
```

### Coordinator Daemon

```bash
# Stop
pkill -f "coordinator-daemon" || true
rm -f /tmp/coordinator-daemon.pid

# Clear coordinator state
rm -f $COMMIT_RELAY_HOME/coordination/coordinator-state.json

# Start
./scripts/coordinator-daemon.sh &
```

### Zombie Killer Daemon

```bash
# Stop
pkill -f "zombie-killer" || true
rm -f /tmp/zombie-killer.pid

# Start
./scripts/zombie-killer-daemon.sh &
```

---

## Prevention

### 1. Monitor Daemon Health

Set up regular health checks:

```bash
# Add to crontab
*/5 * * * * $COMMIT_RELAY_HOME/scripts/health-check-pm-daemon.sh >> /tmp/health-check.log 2>&1
```

### 2. Configure Heartbeat Monitor

Ensure heartbeat-monitor daemon is running to detect daemon failures:

```bash
./scripts/health-monitor-daemon.sh &
```

### 3. Log Rotation

Prevent log files from consuming disk space:

```bash
# Rotate PM daemon logs
./scripts/system-maintenance.sh --rotate-logs
```

### 4. State File Validation

Validate state files after recovery:

```bash
# Validate all JSON state files
for file in $COMMIT_RELAY_HOME/coordination/*.json; do
    if ! jq empty "$file" 2>/dev/null; then
        echo "INVALID: $file"
    fi
done
```

---

## Quick Reference

| Issue | Command |
|-------|---------|
| Check all daemons | `./scripts/dashboards/daemon-monitor.sh --status` |
| Start all daemons | `./scripts/dashboards/daemon-monitor.sh --start-all` |
| Stop all daemons | `./scripts/dashboards/daemon-monitor.sh --stop-all` |
| Remove stale PIDs | `rm -f /tmp/*-daemon.pid /tmp/zombie-killer.pid /tmp/heartbeat-monitor.pid` |
| View PM logs | `tail -f $COMMIT_RELAY_HOME/agents/logs/system/pm-daemon.log` |
| Check PM last loop | `jq '.pm_daemon.last_loop' coordination/pm-state.json` |
| Reset PM state | Remove pm-state.json and restart daemon |

---

## Related Runbooks

- [Daily Operations](./daily-operations.md)
- [Daemon Management](./daemon-management.md)
- [Emergency Recovery](./emergency-recovery.md)
- [Self-Healing System](./self-healing-system.md)

---

**Last Updated**: 2025-11-21
