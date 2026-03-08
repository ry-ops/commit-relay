# Daemon Monitoring Architecture

This document describes the health monitoring system for commit-relay daemons and expected behavior patterns.

## Overview

The commit-relay system uses a Health Monitor Daemon (`health-monitor-daemon.sh`) to track the health of all system components and automatically spawn backups when failures are detected.

## Daemon Types

### Continuous Daemons

These daemons run continuously and should maintain regular heartbeats:

#### 1. PM Daemon (`pm-daemon.sh`)
- **Purpose**: Project Manager - monitors worker health and intervention
- **Heartbeat Source**: `coordination/pm-state.json` (field: `pm_daemon.last_loop`)
- **Expected Frequency**: Every 3 minutes (180 seconds)
- **PID File**: `/tmp/commit-relay-pm-daemon.pid`
- **Monitoring Strategy**:
  - Check process via PID file first
  - Then verify `pm-state.json` has recent `last_loop` timestamp
  - Only create alert if process is NOT running AND state is stale

#### 2. Worker Daemon (`worker-daemon.sh`)
- **Purpose**: Automatically launches pending workers
- **Heartbeat Source**: Process check via `pgrep`
- **Expected Frequency**: Continuous process
- **PID File**: `/tmp/commit-relay-worker-daemon.pid`
- **Monitoring Strategy**: Check if process is running

#### 3. Health Monitor Daemon (`health-monitor-daemon.sh`)
- **Purpose**: Monitors all other daemons and system health
- **Heartbeat Source**: Self-monitoring (this daemon)
- **Expected Frequency**: Every 3 minutes (180 seconds)
- **PID File**: `/tmp/commit-relay-health-monitor.pid`
- **Monitoring Strategy**: Monitored by external dashboard/admin

#### 4. Metrics Snapshot Daemon (`metrics-snapshot-daemon.sh`)
- **Purpose**: Collects historical metrics snapshots
- **Expected Frequency**: Periodic snapshots
- **PID File**: `/tmp/commit-relay-metrics-snapshot.pid`

#### 5. Dashboard Server
- **Purpose**: Real-time monitoring and admin interface
- **Heartbeat Source**: Port 3000 listening check
- **Monitoring Strategy**: Check if port 5001 is responding

### On-Demand Services

These services run only when triggered, not continuously:

#### 1. Coordinator Master (`run-coordinator-master.sh`)
- **Purpose**: Routes tasks to appropriate master agents using MoE
- **Execution Model**: Task-based, on-demand
- **Heartbeat Source**: `coordination/coordinator-heartbeat.json`
- **Expected Frequency**: Only when tasks are created
- **Monitoring Strategy**:
  - Use 24-hour threshold (not 5 minutes)
  - Only create "medium" severity alert if no activity in 48+ hours
  - Do NOT treat as continuous daemon

#### 2. Master Agents (Development, Security, Inventory, CI/CD)
- **Purpose**: Specialized agents for specific task types
- **Execution Model**: On-demand via coordinator routing
- **Monitoring Strategy**:
  - Check for recent handoffs (24-hour window)
  - Low activity is informational only, not an error

## Health Monitoring Configuration

### Intervals and Thresholds

```bash
MONITOR_INTERVAL=180      # Health checks every 3 minutes
HEARTBEAT_THRESHOLD=300   # 5-minute threshold for continuous daemons
COORDINATOR_THRESHOLD=86400  # 24-hour threshold for on-demand services
```

### Heartbeat Files

| Component | Heartbeat File | Timestamp Field | Type |
|-----------|---------------|-----------------|------|
| PM Daemon | `coordination/pm-state.json` | `pm_daemon.last_loop` | ISO 8601 |
| PM Agent | `coordination/pm-agent-heartbeat.json` | `timestamp` | Unix epoch |
| Coordinator | `coordination/coordinator-heartbeat.json` | `timestamp` | Unix epoch |

### False Positive Prevention

The health monitor implements multiple checks to prevent false positives:

1. **Process Verification First**
   - Check if daemon process is actually running via PID file
   - Only create alert if BOTH process is down AND heartbeat is stale

2. **Service Type Awareness**
   - Continuous daemons: 5-minute threshold, critical alerts
   - On-demand services: 24-hour threshold, informational logging

3. **Dual Verification**
   - Check both heartbeat timestamp AND process status
   - Resolve alerts immediately when daemon is confirmed healthy

## Alert Severity Levels

| Severity | SLA (minutes) | Use Case |
|----------|---------------|----------|
| critical | 15 | Core system failures (Dashboard down, data loss risk) |
| high | 30 | Daemon failures with backup available (PM Daemon) |
| medium | 60 | Non-critical failures (On-demand services inactive 48h+) |
| low | 120 | Informational (Master low activity) |

## Common Issues and Fixes

### Issue: PM Daemon False Positive

**Symptom**: Alert "PM Daemon heartbeat stale" but daemon is running

**Root Cause**:
- Heartbeat file (`pm-daemon-heartbeat.json`) not being updated
- Health monitor checking wrong file

**Fix Applied**:
- Health monitor now checks `pm-state.json` (which IS updated)
- Added process verification before creating alerts
- Daemon must be both NOT running AND state stale to trigger alert

### Issue: Coordinator False Positive

**Symptom**: Alert "Coordinator heartbeat stale" after normal operation

**Root Cause**:
- Coordinator runs on-demand, not continuously
- Health monitor treating it as continuous daemon

**Fix Applied**:
- Increased threshold to 24 hours
- Changed severity to "medium"
- Only alerts if no activity for 48+ hours
- Added documentation noting on-demand architecture

## Automated Repair System

The health monitoring system integrates with the commit-relay automation system:

### Auto-Repair Flow

1. **Detection**: Health monitor detects issue and creates alert
2. **Dashboard**: Alert appears in dashboard with "Auto Repair" button
3. **Task Creation**: Clicking repair creates task (format: `task-repair-{timestamp}`)
4. **MoE Routing**: Task routed through coordinator to appropriate master
5. **Worker Execution**: Development master spawns worker to fix issue
6. **Resolution**: Worker fixes issue, updates alert status to "resolved"

### Manual Repair

Health alerts can also be resolved manually:

```bash
# Update alert status in coordination/health-alerts.json
jq '.alerts[] | select(.id == "alert-id") | .status = "resolved"' \
   coordination/health-alerts.json
```

## Monitoring the Monitor

The Health Monitor Daemon itself should be monitored:

- **Dashboard**: Admin page shows Health Monitor status and controls
- **Process Check**: `ps aux | grep health-monitor-daemon`
- **Log Monitoring**: `tail -f agents/logs/system/health-monitor.log`
- **PID File**: Check `/tmp/commit-relay-health-monitor.pid`

## Best Practices

1. **Don't Monitor On-Demand Services Like Continuous Daemons**
   - Use appropriate thresholds
   - Understand execution patterns
   - Avoid alert fatigue

2. **Always Verify Process Status**
   - Check PID file and `kill -0 $PID`
   - Don't rely solely on heartbeat files
   - Confirm daemon is actually down before alerting

3. **Document Expected Behavior**
   - Clearly mark on-demand vs continuous services
   - Document typical activity patterns
   - Set appropriate alerting thresholds

4. **Regular Testing**
   - Test daemon restart scenarios
   - Verify heartbeat file updates
   - Confirm alert creation and resolution

## Architecture Diagram

```
┌─────────────────────────────────────────────────┐
│      Health Monitor Daemon (180s interval)       │
│                                                   │
│  ┌──────────────────────────────────────────┐  │
│  │  Check Continuous Daemons (5min threshold)│  │
│  │  • PM Daemon (process + pm-state.json)    │  │
│  │  • Worker Daemon (process check)          │  │
│  │  • Dashboard (port 5001 check)            │  │
│  └──────────────────────────────────────────┘  │
│                                                   │
│  ┌──────────────────────────────────────────┐  │
│  │  Check On-Demand Services (24h threshold) │  │
│  │  • Coordinator (coordinator-heartbeat)     │  │
│  │  • Masters (handoff activity)             │  │
│  └──────────────────────────────────────────┘  │
│                                                   │
│  ┌──────────────────────────────────────────┐  │
│  │  Alert Management                         │  │
│  │  • Create alerts (health-alerts.json)     │  │
│  │  • Resolve alerts (when healthy)          │  │
│  │  • Log incidents (health-incidents/)      │  │
│  └──────────────────────────────────────────┘  │
└──────────────┬────────────────────────────────┬─┘
               │                                │
               ▼                                ▼
    ┌──────────────────┐           ┌──────────────────┐
    │  Health Alerts   │           │  Auto Repair     │
    │  (Dashboard UI)  │──────────>│  (commit-relay)  │
    └──────────────────┘           └──────────────────┘
```

## Related Documentation

- [Health Alert SLA Plan](./HEALTH-ALERT-SLA-PLAN.md)
- [Worker Daemon](./DAEMON.md)
- [MoE Architecture](./MOE-ARCHITECTURE.md)
- [PM System Summary](./PM-SYSTEM-SUMMARY.md)

---

*Last Updated: 2025-11-08 (Automated Repair System Implementation)*
