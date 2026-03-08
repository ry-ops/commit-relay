# Worker Lifecycle Management

## Overview

Workers in the commit-relay system have a well-defined lifecycle from creation to archival. This document describes the complete lifecycle, monitoring, and automated cleanup processes.

## Worker States

### 1. Pending
- Worker spec created but not yet spawned
- Located in: `coordination/worker-specs/active/`
- Status field: `"status": "pending"`

### 2. Running
- Worker actively executing task
- Has PID and session information
- Status field: `"status": "running"`
- Has `execution.started_at` and `execution.pid`

### 3. Completed
- Worker successfully finished task
- Ready for archival
- Status field: `"status": "completed"`
- Has `execution.completed_at`

### 4. Failed
- Worker encountered error and stopped
- Requires investigation
- Status field: `"status": "failed"`
- Has `execution.failed_at` and error details

### 5. Archived
- Worker moved to long-term storage
- Located in: `coordination/worker-specs/archived/YYYY-MM-DD/`
- No longer in active pool

## Lifecycle Flow

```
┌──────────┐
│ Pending  │
└────┬─────┘
     │
     │ Spawn Worker
     ▼
┌──────────┐
│ Running  │
└────┬─────┘
     │
     ├─ Success ──────┐
     │                │
     │                ▼
     │           ┌──────────┐
     │           │Completed │
     │           └────┬─────┘
     │                │
     │                │ Archive (automated)
     │                ▼
     │           ┌──────────┐
     │           │Archived  │
     │           └──────────┘
     │
     └─ Failure ──────┐
                      │
                      ▼
                 ┌──────────┐
                 │ Failed   │
                 └────┬─────┘
                      │
                      │ Review & Archive
                      ▼
                 ┌──────────┐
                 │Archived  │
                 └──────────┘
```

## Automated Worker Cleanup

### Purpose
Prevent worker pool bloat by automatically archiving completed and stale workers.

### Script: `scripts/worker-cleanup-cron.sh`

#### Features
- Identifies completed workers for archival
- Detects stale workers (>24hr old with dead processes)
- Archives workers to dated directories
- Updates `worker-pool.json` automatically
- Monitors pool size and alerts on anomalies
- Maintains audit trail of all cleanup actions

#### Usage

**Manual Execution:**
```bash
# Dry run (preview changes)
./scripts/worker-cleanup-cron.sh --dry-run --verbose

# Execute cleanup
./scripts/worker-cleanup-cron.sh

# Verbose output
./scripts/worker-cleanup-cron.sh --verbose
```

**Automated Execution (Cron):**

1. Edit your crontab:
   ```bash
   crontab -e
   ```

2. Add one of these schedules:

   **Option 1: Hourly Cleanup (Recommended)**
   ```cron
   0 * * * * /path/to/commit-relay/scripts/worker-cleanup-cron.sh >> /path/to/commit-relay/agents/logs/system/worker-cleanup.log 2>&1
   ```

   **Option 2: Every 4 Hours**
   ```cron
   0 */4 * * * /path/to/commit-relay/scripts/worker-cleanup-cron.sh >> /path/to/commit-relay/agents/logs/system/worker-cleanup.log 2>&1
   ```

   **Option 3: Daily at 2 AM**
   ```cron
   0 2 * * * /path/to/commit-relay/scripts/worker-cleanup-cron.sh >> /path/to/commit-relay/agents/logs/system/worker-cleanup.log 2>&1
   ```

3. Save and exit (`:wq` in vi/vim)

4. Verify cron job:
   ```bash
   crontab -l
   ```

#### Configuration

Edit `scripts/worker-cleanup-cron.sh` to adjust thresholds:

```bash
# Thresholds
MAX_WORKER_AGE_HOURS=24      # Archive workers older than 24 hours
POOL_SIZE_WARNING=10         # Warn if pool exceeds 10 workers
POOL_SIZE_CRITICAL=15        # Critical alert if pool exceeds 15 workers
```

### Cleanup Criteria

Workers are archived when they meet ANY of these conditions:

1. **Status = Completed**
   - Worker successfully finished its task
   - Immediate archival candidate

2. **Status = Failed**
   - Worker encountered an error
   - Archived after investigation period

3. **Stale Worker (>24hr old)**
   - Worker age exceeds `MAX_WORKER_AGE_HOURS`
   - Process PID is not running
   - Status reconciliation fails

### Archive Structure

```
coordination/worker-specs/
├── active/                  # Current active workers
│   ├── dev-worker-ABC123.json
│   └── sec-worker-XYZ789.json
├── archived/               # Long-term storage
│   ├── 2025-11-07/
│   │   ├── dev-worker-OLD123.json
│   │   └── sec-worker-OLD456.json
│   └── 2025-11-08/
│       └── dev-worker-OLD789.json
├── completed/              # Recently completed (manual archival)
└── failed/                 # Failed workers (manual review)
```

## Pool Size Monitoring

### Health Thresholds

- **Healthy:** <10 active workers
- **Warning:** 10-14 active workers (yellow alert)
- **Critical:** ≥15 active workers (red alert)

### Alerts

The cleanup script emits dashboard events when pool size exceeds thresholds:

```json
{
  "timestamp": "2025-11-08T12:00:00-0600",
  "type": "pool_size_alert",
  "data": {
    "pool_size": 12,
    "threshold": 10,
    "severity": "warning"
  }
}
```

### Manual Pool Size Check

```bash
# Count active workers
ls coordination/worker-specs/active/*.json | wc -l

# View worker health report
./scripts/worker-cleanup-cron.sh --dry-run | grep "Health Report" -A 6
```

## Worker Status Reconciliation

The cleanup script validates worker status by checking:

1. **Process Status**
   - Extracts PID from `execution.pid`
   - Checks if process is running: `kill -0 $PID`
   - Marks as stale if process not found

2. **Timestamp Validation**
   - Calculates worker age from `created_at` or `execution.started_at`
   - Compares against `MAX_WORKER_AGE_HOURS` threshold

3. **Status Consistency**
   - Verifies `status` field matches actual process state
   - Updates inconsistencies automatically

## Monitoring & Logs

### View Cleanup Logs

```bash
# Tail recent cleanup activity
tail -f agents/logs/system/worker-cleanup.log

# View last cleanup run
tail -50 agents/logs/system/worker-cleanup.log

# Search for specific worker
grep "dev-worker-ABC123" agents/logs/system/worker-cleanup.log
```

### Dashboard Events

All cleanup actions emit events to `coordination/dashboard-events.jsonl`:

```bash
# Watch real-time events
tail -f coordination/dashboard-events.jsonl | grep worker_archived
```

## Best Practices

### 1. Regular Cleanup Schedule
- Run cleanup at least once per day
- Hourly cleanup recommended for active systems
- Monitor logs for anomalies

### 2. Pool Size Limits
- Keep active pool under 10 workers
- Investigate if pool exceeds 15 workers
- Archive completed workers promptly

### 3. Failed Worker Investigation
- Review failed workers before archiving
- Check logs for failure patterns
- Update master logic if failures repeat

### 4. Archive Retention
- Archives are date-stamped for easy cleanup
- Consider deleting archives >30 days old
- Keep recent archives for analysis

### 5. Status Reconciliation
- Run cleanup with `--verbose` to see reconciliation
- Check for "stale worker" warnings
- Investigate process termination issues

## Troubleshooting

### Issue: Workers Not Being Archived

**Symptoms:**
- Active pool keeps growing
- Completed workers remain in `active/`

**Solution:**
```bash
# Check if cron job is running
crontab -l

# Check cleanup logs for errors
tail -50 agents/logs/system/worker-cleanup.log

# Run manually to test
./scripts/worker-cleanup-cron.sh --verbose
```

### Issue: Pool Size Alerts

**Symptoms:**
- Pool size exceeds 10-15 workers
- Dashboard shows pool_size_alert events

**Solution:**
```bash
# Run immediate cleanup
./scripts/worker-cleanup-cron.sh

# Check for stuck workers
for f in coordination/worker-specs/active/*.json; do
    echo "$f: $(jq -r '.status' "$f")"
done

# Manually archive stuck workers
mv coordination/worker-specs/active/stuck-worker-*.json \
   coordination/worker-specs/archived/$(date +%Y-%m-%d)/
```

### Issue: Stale Worker Detection

**Symptoms:**
- Workers marked as "running" but process not found
- Age calculation errors in logs

**Solution:**
```bash
# Check worker timestamps
jq -r '.created_at, .execution.started_at' \
   coordination/worker-specs/active/worker-*.json

# Manually mark as stale
jq '.status = "stale"' worker.json > worker-updated.json
mv worker-updated.json worker.json
```

## Manual Cleanup

For urgent cleanup or testing:

```bash
# Archive all completed workers immediately
for f in coordination/worker-specs/active/*.json; do
    status=$(jq -r '.status' "$f")
    if [ "$status" = "completed" ]; then
        mkdir -p coordination/worker-specs/archived/$(date +%Y-%m-%d)
        mv "$f" coordination/worker-specs/archived/$(date +%Y-%m-%d)/
    fi
done

# Update worker-pool.json
./scripts/worker-cleanup-cron.sh
```

## Integration with MoE System

Worker lifecycle management integrates with the MoE (Mixture of Experts) system:

- **Sparse Activation:** Cleanup maintains optimal pool size for efficient sparse activation
- **Pool Efficiency:** Monitors active worker percentage (target: <30% utilization)
- **Resource Conservation:** Prevents token budget waste on idle workers
- **Learning System:** Archives preserve worker execution history for future routing improvements

## Future Enhancements

Planned improvements to worker lifecycle management:

1. **Predictive Cleanup:** Machine learning to predict optimal cleanup times
2. **Worker Reuse:** Pool idle workers for similar tasks instead of spawning new ones
3. **Cost Tracking:** Track token costs per worker for budget optimization
4. **Performance Metrics:** Measure worker efficiency and success rates
5. **Auto-scaling:** Dynamically adjust pool size based on task queue depth

---

**Last Updated:** 2025-11-08
**Maintained By:** MoE Self-Improvement System (Phase 2)
