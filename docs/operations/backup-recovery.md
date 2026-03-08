# Backup and Recovery Procedures

## Overview

Comprehensive backup and disaster recovery strategy for commit-relay ensuring data protection and business continuity.

**RTO (Recovery Time Objective)**: < 4 hours
**RPO (Recovery Point Objective)**: < 1 hour

---

## Backup Strategy

### What to Backup

1. **Critical Data**:
   - Achievement progress: `coordination/masters/achievement/knowledge-base/`
   - MoE patterns: `coordination/knowledge-base/learned-patterns/`
   - Routing decisions: `coordination/masters/coordinator/knowledge-base/`
   - Worker state: `coordination/worker-pool.json`
   - Task queue: `coordination/tasks/`

2. **Configuration**:
   - Environment variables: `.env`
   - Governance policies: `coordination/config/`
   - Master specs: `coordination/masters/*/config/`

3. **Metrics**:
   - Achievement history: `coordination/metrics/`
   - Learning metrics: `coordination/metrics/learning/`

### Backup Schedule

| Data Type | Frequency | Retention | Storage |
|-----------|-----------|-----------|---------|
| Critical data | Hourly | 7 days | S3 Standard |
| Configuration | Daily | 30 days | S3 Standard |
| Metrics | Daily | 90 days | S3 IA |
| Full system | Weekly | 1 year | S3 Glacier |

---

## Automated Backups

### Backup Script

```bash
#!/usr/bin/env bash
# scripts/backup/backup.sh

set -euo pipefail

BACKUP_DIR="/tmp/commit-relay-backup-$(date +%Y%m%d-%H%M%S)"
S3_BUCKET="s3://commit-relay-backups"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Create backup directory
mkdir -p "$BACKUP_DIR"

# Backup critical data
tar -czf "$BACKUP_DIR/knowledge-base.tar.gz" \
  coordination/masters/achievement/knowledge-base/ \
  coordination/knowledge-base/learned-patterns/ \
  coordination/masters/coordinator/knowledge-base/

# Backup configuration
tar -czf "$BACKUP_DIR/config.tar.gz" \
  coordination/config/ \
  coordination/masters/*/config/ \
  .env

# Backup metrics
tar -czf "$BACKUP_DIR/metrics.tar.gz" \
  coordination/metrics/

# Upload to S3
aws s3 sync "$BACKUP_DIR" "$S3_BUCKET/$TIMESTAMP/" \
  --storage-class STANDARD

# Cleanup
rm -rf "$BACKUP_DIR"

echo "Backup completed: $S3_BUCKET/$TIMESTAMP/"
```

### Cron Schedule

```bash
# Hourly backups (critical data)
0 * * * * /path/to/scripts/backup/backup.sh critical

# Daily backups (full)
0 2 * * * /path/to/scripts/backup/backup.sh full

# Weekly backups (archive)
0 3 * * 0 /path/to/scripts/backup/backup.sh archive
```

---

## Recovery Procedures

### Scenario 1: Data Corruption

**Symptoms**: Invalid JSON, missing files

**Recovery**:

```bash
# List available backups
aws s3 ls s3://commit-relay-backups/

# Download latest backup
aws s3 sync s3://commit-relay-backups/TIMESTAMP/ /tmp/restore/

# Stop services
pm2 stop all

# Restore data
tar -xzf /tmp/restore/knowledge-base.tar.gz -C /

# Restart services
pm2 restart all

# Verify
curl http://localhost:5001/api/health
```

**Verification**:
```bash
# Check data integrity
node scripts/verify-data.js

# Check achievement progress
curl http://localhost:5001/api/achievements/progress
```

---

### Scenario 2: Complete Server Failure

**Recovery**:

1. **Provision new server**
2. **Install dependencies**:
```bash
# Clone repository
git clone https://github.com/ry-ops/commit-relay.git
cd commit-relay
npm install
```

3. **Restore from backup**:
```bash
# Download latest full backup
aws s3 sync s3://commit-relay-backups/LATEST/ /tmp/restore/

# Extract all backups
cd /tmp/restore
tar -xzf knowledge-base.tar.gz -C /path/to/commit-relay/
tar -xzf config.tar.gz -C /path/to/commit-relay/
tar -xzf metrics.tar.gz -C /path/to/commit-relay/
```

4. **Start services**:
```bash
npm run start
```

**Recovery Time**: ~2 hours

---

### Scenario 3: Database Corruption

**Recovery**:

```bash
# Export current state
pg_dump commit_relay > /tmp/current_backup.sql

# Restore from backup
psql commit_relay < /path/to/backup.sql

# Verify
psql commit_relay -c "SELECT COUNT(*) FROM achievements"
```

---

## Point-in-Time Recovery

### Enable WAL Archiving

```sql
-- PostgreSQL configuration
archive_mode = on
archive_command = 'cp %p /path/to/archive/%f'
wal_level = replica
```

### Restore to Specific Time

```bash
# Stop database
sudo systemctl stop postgresql

# Restore base backup
tar -xzf base-backup.tar.gz -C /var/lib/postgresql/data

# Configure recovery
cat > /var/lib/postgresql/data/recovery.conf << EOF
restore_command = 'cp /path/to/archive/%f %p'
recovery_target_time = '2025-11-25 14:30:00'
EOF

# Start database
sudo systemctl start postgresql
```

---

## Testing Recovery

### Monthly Recovery Test

```bash
#!/usr/bin/env bash
# Test recovery procedure

# 1. Create test backup
./scripts/backup/backup.sh test

# 2. Restore to staging environment
./scripts/backup/restore.sh --env staging --backup latest

# 3. Verify data integrity
./scripts/verify-integrity.sh staging

# 4. Run smoke tests
npm run test:smoke -- --env staging

# 5. Document results
echo "Recovery test passed: $(date)" >> recovery-test-log.txt
```

---

## Disaster Recovery Plan

### Priority 1 (Critical - RTO: 1 hour)
- API server
- Achievement tracking
- MoE coordinator

### Priority 2 (Important - RTO: 4 hours)
- Worker pool
- Monitoring dashboards
- Metrics collection

### Priority 3 (Standard - RTO: 24 hours)
- Historical metrics
- Documentation
- Non-critical workers

### Recovery Runbook

1. **Assess damage** (5 minutes)
2. **Notify stakeholders** (5 minutes)
3. **Provision infrastructure** (30 minutes)
4. **Restore from backup** (1 hour)
5. **Verify services** (30 minutes)
6. **Monitor for issues** (ongoing)

---

## Backup Verification

### Automated Verification

```bash
#!/usr/bin/env bash
# Verify backup integrity

BACKUP_PATH="$1"

# Check file integrity
tar -tzf "$BACKUP_PATH/knowledge-base.tar.gz" > /dev/null

# Check JSON validity
tar -xzf "$BACKUP_PATH/knowledge-base.tar.gz" -O | jq empty

# Verify checksum
sha256sum "$BACKUP_PATH/knowledge-base.tar.gz" > checksum.txt

echo "Backup verified: $BACKUP_PATH"
```

---

## Retention Policy

### Lifecycle Rules

```json
{
  "Rules": [
    {
      "Id": "transition-to-ia",
      "Status": "Enabled",
      "Transitions": [
        {
          "Days": 30,
          "StorageClass": "STANDARD_IA"
        }
      ]
    },
    {
      "Id": "transition-to-glacier",
      "Status": "Enabled",
      "Transitions": [
        {
          "Days": 90,
          "StorageClass": "GLACIER"
        }
      ]
    },
    {
      "Id": "delete-old-backups",
      "Status": "Enabled",
      "Expiration": {
        "Days": 365
      }
    }
  ]
}
```

---

## Monitoring

### Backup Success

```bash
# Check last backup time
aws s3 ls s3://commit-relay-backups/ | tail -1

# Alert if no backup in 2 hours
if [ $(find /var/backups -mmin +120 | wc -l) -gt 0 ]; then
  echo "Backup delayed!" | mail -s "Backup Alert" admin@example.com
fi
```

### Dashboard Metrics

- Last backup time
- Backup size trend
- Recovery test results
- Failed backup count

---

Last Updated: 2025-11-25
RTO: < 4 hours
RPO: < 1 hour
