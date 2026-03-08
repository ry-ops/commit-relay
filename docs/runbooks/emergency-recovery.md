# Runbook: Emergency Recovery

System-wide failure response, rollback, and backup restore procedures.

---

## Overview

This runbook provides procedures for recovering from critical system failures including complete system outages, data corruption, and configuration disasters.

---

## Emergency Severity Levels

| Level | Description | Response Time |
|-------|-------------|---------------|
| P1 - Critical | Complete system down | Immediate |
| P2 - Major | Core functionality impaired | < 15 minutes |
| P3 - Minor | Degraded performance | < 1 hour |

---

## P1: Complete System Failure

### Symptoms

- All daemons stopped
- No workers processing
- Dashboard inaccessible
- All tasks stuck

### Immediate Response

#### 1. Stop Everything

```bash
# Kill all processes
pkill -9 -f "commit-relay"

# Remove all PID files
rm -f /tmp/commit-relay-*.pid

# Wait for cleanup
sleep 5

# Verify nothing running
ps aux | grep commit-relay | grep -v grep && echo "Processes still running!" || echo "All stopped"
```

#### 2. Check System Health

```bash
# Check disk space
df -h $COMMIT_RELAY_HOME

# Check memory
vm_stat | head -20

# Check critical files exist
for file in coordination/task-queue.json coordination/token-budget.json; do
    [[ -f "$COMMIT_RELAY_HOME/$file" ]] && echo "[OK] $file" || echo "[MISSING] $file"
done
```

#### 3. Validate Core Files

```bash
# Check JSON validity
for file in $COMMIT_RELAY_HOME/coordination/*.json; do
    if ! jq empty "$file" 2>/dev/null; then
        echo "[CORRUPT] $file"
    fi
done
```

#### 4. Initialize Missing Files

```bash
# Create missing essential files
[[ ! -f "$COMMIT_RELAY_HOME/coordination/task-queue.json" ]] && \
    echo '{"tasks": []}' > "$COMMIT_RELAY_HOME/coordination/task-queue.json"

[[ ! -f "$COMMIT_RELAY_HOME/coordination/token-budget.json" ]] && \
    cat > "$COMMIT_RELAY_HOME/coordination/token-budget.json" << 'EOF'
{
  "total": 500000,
  "used": 0,
  "available": 500000,
  "last_updated": "2025-01-01T00:00:00Z"
}
EOF

[[ ! -f "$COMMIT_RELAY_HOME/coordination/dashboard-events.jsonl" ]] && \
    touch "$COMMIT_RELAY_HOME/coordination/dashboard-events.jsonl"
```

#### 5. Restart System

```bash
# Start core system
./scripts/start-commit-relay.sh

# Verify startup
sleep 10
./scripts/dashboards/daemon-monitor.sh --status

# Log recovery event
./scripts/emit-event.sh --type "emergency_recovery" --severity "critical" \
    --message "System recovered from P1 failure"
```

---

## P2: Configuration Disaster

### Symptoms

- Daemons crash on startup
- Invalid configuration errors
- Routing failures

### Recovery Procedure

#### 1. Identify Corrupt Config

```bash
# Validate all configs
for config in $COMMIT_RELAY_HOME/coordination/config/*.json; do
    if ! jq empty "$config" 2>/dev/null; then
        echo "[CORRUPT] $config"
    fi
done

# Check MoE router
jq empty $COMMIT_RELAY_HOME/coordination/moe/router-config.json || echo "Router config corrupt"
```

#### 2. Restore from Git

```bash
# Restore config directory from last commit
git checkout -- coordination/config/
git checkout -- coordination/moe/

# Verify restored
jq empty $COMMIT_RELAY_HOME/coordination/config/*.json && echo "Configs restored"
```

#### 3. Restore from Backup

```bash
# Find latest backup
LATEST_BACKUP=$(ls -t $COMMIT_RELAY_HOME/backups/*.tar.gz 2>/dev/null | head -1)

if [[ -n "$LATEST_BACKUP" ]]; then
    echo "Restoring from: $LATEST_BACKUP"

    # Extract to temp
    TEMP_DIR=$(mktemp -d)
    tar -xzf "$LATEST_BACKUP" -C "$TEMP_DIR"

    # Restore configs
    cp "$TEMP_DIR"/*/coordination/config/*.json $COMMIT_RELAY_HOME/coordination/config/

    rm -rf "$TEMP_DIR"
fi
```

#### 4. Reset to Defaults

If no backup available:

```bash
# Create default configurations
cat > $COMMIT_RELAY_HOME/coordination/config/worker-types.json << 'EOF'
{
  "worker_types": {
    "implementation-worker": {"default_budget": 100000, "default_duration": 45},
    "analysis-worker": {"default_budget": 50000, "default_duration": 15},
    "scan-worker": {"default_budget": 70000, "default_duration": 15},
    "fix-worker": {"default_budget": 70000, "default_duration": 20}
  }
}
EOF

cat > $COMMIT_RELAY_HOME/coordination/moe/router-config.json << 'EOF'
{
  "rules": [
    {"pattern": "implement", "worker_type": "implementation-worker", "confidence": 0.9},
    {"pattern": "scan|security", "worker_type": "scan-worker", "confidence": 0.9},
    {"pattern": "fix|bug", "worker_type": "fix-worker", "confidence": 0.9},
    {"pattern": ".*", "worker_type": "analysis-worker", "confidence": 0.5, "is_default": true}
  ]
}
EOF
```

---

## Data Corruption Recovery

### Symptoms

- JSON parse errors
- Missing data
- Inconsistent state

### Recovery Steps

#### 1. Identify Corrupt Files

```bash
# Find all corrupt files
find $COMMIT_RELAY_HOME/coordination -name "*.json" -exec sh -c '
    jq empty "$1" 2>/dev/null || echo "$1"
' _ {} \;
```

#### 2. Repair JSONL Files

```bash
# Remove invalid lines
for jsonl in $COMMIT_RELAY_HOME/coordination/*.jsonl; do
    TEMP=$(mktemp)
    while IFS= read -r line; do
        echo "$line" | jq empty 2>/dev/null && echo "$line"
    done < "$jsonl" > "$TEMP"
    mv "$TEMP" "$jsonl"
done
```

#### 3. Restore Worker Specs

```bash
# Clear corrupted specs
rm -f $COMMIT_RELAY_HOME/coordination/worker-specs/active/*.json

# Recalculate token budget
echo '{"total": 500000, "used": 0, "available": 500000}' > \
    $COMMIT_RELAY_HOME/coordination/token-budget.json
```

#### 4. Restore Task Queue

```bash
# Backup current
cp $COMMIT_RELAY_HOME/coordination/task-queue.json \
   $COMMIT_RELAY_HOME/coordination/task-queue.json.corrupt

# Initialize empty
echo '{"tasks": []}' > $COMMIT_RELAY_HOME/coordination/task-queue.json

# Try to recover tasks
if jq -e '.tasks' $COMMIT_RELAY_HOME/coordination/task-queue.json.corrupt > /dev/null 2>&1; then
    jq '{tasks: [.tasks[] | select(.task_id != null)]}' \
       $COMMIT_RELAY_HOME/coordination/task-queue.json.corrupt > \
       $COMMIT_RELAY_HOME/coordination/task-queue.json
fi
```

---

## Backup and Restore

### Create Backup

```bash
# Full backup
BACKUP_NAME="commit-relay-backup-$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$COMMIT_RELAY_HOME/backups"
mkdir -p "$BACKUP_DIR"

tar -czf "$BACKUP_DIR/$BACKUP_NAME.tar.gz" \
    -C "$COMMIT_RELAY_HOME" \
    coordination \
    agents/prompts \
    scripts

echo "Backup created: $BACKUP_DIR/$BACKUP_NAME.tar.gz"
```

### Restore from Backup

```bash
# List available backups
ls -la $COMMIT_RELAY_HOME/backups/*.tar.gz

# Restore specific backup
BACKUP_FILE="$COMMIT_RELAY_HOME/backups/commit-relay-backup-20251121-100000.tar.gz"

# Stop system
pkill -f "commit-relay"

# Restore
cd $COMMIT_RELAY_HOME
tar -xzf "$BACKUP_FILE"

# Restart
./scripts/start-commit-relay.sh
```

### Restore Script

Use the dedicated restore script:

```bash
# View restore options
./scripts/restore-from-backup.sh --help

# Restore latest
./scripts/restore-from-backup.sh --latest

# Restore specific backup
./scripts/restore-from-backup.sh --file backups/backup.tar.gz
```

---

## Rollback Procedures

### Rollback Code Changes

```bash
# Stop system
pkill -f "commit-relay"

# Find last known good commit
git log --oneline -10

# Rollback to specific commit
GOOD_COMMIT="abc123"
git checkout $GOOD_COMMIT

# Or rollback last N commits
git revert HEAD~3..HEAD

# Restart
./scripts/start-commit-relay.sh
```

### Rollback Configuration

```bash
# Restore config from git history
git show HEAD~1:coordination/config/worker-types.json > \
    $COMMIT_RELAY_HOME/coordination/config/worker-types.json

# Or restore all configs
git checkout HEAD~1 -- coordination/config/
```

---

## Post-Recovery Verification

### System Health Check

```bash
# 1. All daemons running
./scripts/dashboards/daemon-monitor.sh --status

# 2. Files valid
for file in $COMMIT_RELAY_HOME/coordination/*.json; do
    jq empty "$file" 2>/dev/null || echo "[INVALID] $file"
done

# 3. Token budget healthy
cat $COMMIT_RELAY_HOME/coordination/token-budget.json | jq .

# 4. Task queue accessible
cat $COMMIT_RELAY_HOME/coordination/task-queue.json | jq '.tasks | length'

# 5. Can create task
./scripts/create-task.sh --description "Recovery test" --priority low

# 6. Dashboard works
./scripts/dashboards/system-live.sh &
sleep 5
kill $!
```

### Log Recovery Event

```bash
./scripts/emit-event.sh \
    --type "system_recovery_complete" \
    --severity "info" \
    --message "System recovered and verified"
```

### Post-Mortem

Document the incident:

```bash
cat > $COMMIT_RELAY_HOME/incidents/incident-$(date +%Y%m%d).md << 'EOF'
# Incident Report

**Date**: $(date)
**Severity**: P1/P2/P3
**Duration**: X minutes

## Summary
Brief description of what happened

## Root Cause
What caused the failure

## Recovery Actions
Steps taken to recover

## Prevention
Actions to prevent recurrence

## Lessons Learned
What we learned from this incident
EOF
```

---

## Prevention

### Regular Backups

```bash
# Add to crontab
# Daily backup at 2 AM
0 2 * * * $COMMIT_RELAY_HOME/scripts/backup.sh >> /tmp/backup.log 2>&1
```

### Health Monitoring

```bash
# Continuous monitoring
# Add to crontab
*/5 * * * * $COMMIT_RELAY_HOME/scripts/health-check.sh >> /tmp/health.log 2>&1
```

### Configuration Validation

Validate configs before applying changes:

```bash
# Before modifying
jq empty new-config.json && mv new-config.json config.json
```

### Git Hygiene

- Commit configuration changes
- Tag stable releases
- Keep clean history

---

## Emergency Contacts

- **System Logs**: `$COMMIT_RELAY_HOME/agents/logs/`
- **Backups**: `$COMMIT_RELAY_HOME/backups/`
- **Configuration**: `$COMMIT_RELAY_HOME/coordination/config/`
- **Runbooks**: `$COMMIT_RELAY_HOME/docs/runbooks/`

---

## Quick Reference

### Complete Reset

```bash
# Nuclear option - complete reset
pkill -f "commit-relay"
rm -rf $COMMIT_RELAY_HOME/coordination/worker-specs/active/*
rm -rf $COMMIT_RELAY_HOME/coordination/worker-specs/zombie/*
echo '{"tasks": []}' > $COMMIT_RELAY_HOME/coordination/task-queue.json
echo '{"total": 500000, "used": 0, "available": 500000}' > $COMMIT_RELAY_HOME/coordination/token-budget.json
./scripts/start-commit-relay.sh
```

### Emergency Commands

```bash
# Stop all
pkill -9 -f "commit-relay"

# Clear state
rm -f /tmp/commit-relay-*.pid

# Start fresh
./scripts/start-commit-relay.sh

# Check status
./scripts/dashboards/system-live.sh
```

---

## Related Runbooks

- [Daemon Failure](./daemon-failure.md)
- [Data Quality Issues](./data-quality-issues.md)
- [Daily Operations](./daily-operations.md)

---

**Last Updated**: 2025-11-21
