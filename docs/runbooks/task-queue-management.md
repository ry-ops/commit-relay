# Runbook: Task Queue Management

Adding, prioritizing, and monitoring tasks in the queue.

---

## Overview

The task queue is the central system for managing work items that get distributed to workers. This runbook covers all aspects of task queue management.

---

## Task Structure

```json
{
  "task_id": "task-001",
  "description": "Implement user authentication feature",
  "status": "queued",
  "priority": "high",
  "type": "implementation",
  "assigned_worker": null,
  "repository": "owner/repo",
  "created_at": "2025-11-21T10:00:00Z",
  "started_at": null,
  "completed_at": null,
  "metadata": {
    "requested_by": "user@example.com",
    "tags": ["feature", "auth"]
  }
}
```

### Task States

| Status | Description |
|--------|-------------|
| `queued` | Waiting to be assigned |
| `in_progress` | Assigned to worker |
| `completed` | Successfully finished |
| `failed` | Task failed |
| `cancelled` | Manually cancelled |

### Priority Levels

| Priority | Description | Queue Position |
|----------|-------------|----------------|
| `critical` | Emergency, process first | Top |
| `high` | Important, prioritize | Near top |
| `medium` | Standard processing | Middle |
| `low` | Background work | Bottom |

---

## Adding Tasks

### Using Task Creation Script

```bash
# Basic task creation
./scripts/create-task.sh \
    --description "Fix login bug" \
    --priority high \
    --type fix

# Full options
./scripts/create-task.sh \
    --description "Implement payment processing" \
    --priority critical \
    --type implementation \
    --repo owner/payment-service \
    --tags "feature,payment,urgent"
```

### Using Enhanced Task Creation

```bash
# Interactive mode with validation
./scripts/create-task-enhanced.sh
```

### Manual Task Addition

```bash
TASK_ID="task-$(date +%s)"

# Create task object
NEW_TASK=$(cat << EOF
{
  "task_id": "$TASK_ID",
  "description": "Your task description",
  "status": "queued",
  "priority": "medium",
  "type": "analysis",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
)

# Add to queue
jq --argjson task "$NEW_TASK" '.tasks += [$task]' \
   $COMMIT_RELAY_HOME/coordination/task-queue.json > /tmp/queue.json && \
mv /tmp/queue.json $COMMIT_RELAY_HOME/coordination/task-queue.json

echo "Added task: $TASK_ID"
```

### Bulk Task Import

```bash
# From JSON file
cat tasks-to-import.json | jq -c '.[]' | while read -r task; do
    jq --argjson task "$task" '.tasks += [$task]' \
       $COMMIT_RELAY_HOME/coordination/task-queue.json > /tmp/queue.json && \
    mv /tmp/queue.json $COMMIT_RELAY_HOME/coordination/task-queue.json
done

# Emit event
./scripts/emit-event.sh --type "tasks_imported" --message "Bulk import completed"
```

---

## Viewing Task Queue

### Dashboard View

```bash
# Real-time task queue monitor
./scripts/dashboards/task-queue-monitor.sh
```

### Command Line Queries

```bash
# View all tasks
cat $COMMIT_RELAY_HOME/coordination/task-queue.json | jq '.tasks[]'

# Count by status
cat $COMMIT_RELAY_HOME/coordination/task-queue.json | \
    jq '[.tasks[] | .status] | group_by(.) | map({status: .[0], count: length})'

# View queued tasks
cat $COMMIT_RELAY_HOME/coordination/task-queue.json | \
    jq '.tasks[] | select(.status == "queued") | {task_id, description, priority}'

# View by priority
cat $COMMIT_RELAY_HOME/coordination/task-queue.json | \
    jq '.tasks | sort_by(.priority) | reverse | .[] | {task_id, priority, status}'

# Search by description
SEARCH="authentication"
cat $COMMIT_RELAY_HOME/coordination/task-queue.json | \
    jq --arg s "$SEARCH" '.tasks[] | select(.description | test($s; "i"))'
```

### Check Specific Task

```bash
TASK_ID="task-001"

# Get task details
cat $COMMIT_RELAY_HOME/coordination/task-queue.json | \
    jq --arg id "$TASK_ID" '.tasks[] | select(.task_id == $id)'

# Get assigned worker
cat $COMMIT_RELAY_HOME/coordination/task-queue.json | \
    jq --arg id "$TASK_ID" '.tasks[] | select(.task_id == $id) | .assigned_worker'
```

---

## Prioritizing Tasks

### Change Task Priority

```bash
TASK_ID="task-001"
NEW_PRIORITY="critical"

jq --arg id "$TASK_ID" --arg p "$NEW_PRIORITY" \
   '(.tasks[] | select(.task_id == $id) | .priority) = $p' \
   $COMMIT_RELAY_HOME/coordination/task-queue.json > /tmp/queue.json && \
mv /tmp/queue.json $COMMIT_RELAY_HOME/coordination/task-queue.json

echo "Updated priority for $TASK_ID to $NEW_PRIORITY"
```

### Reorder Queue

```bash
# Sort all tasks by priority
jq '.tasks |= sort_by(
    if .priority == "critical" then 0
    elif .priority == "high" then 1
    elif .priority == "medium" then 2
    else 3 end
)' $COMMIT_RELAY_HOME/coordination/task-queue.json > /tmp/queue.json && \
mv /tmp/queue.json $COMMIT_RELAY_HOME/coordination/task-queue.json
```

### Move Task to Front

```bash
TASK_ID="task-001"

# Extract task and reinsert at front
TASK=$(cat $COMMIT_RELAY_HOME/coordination/task-queue.json | \
    jq --arg id "$TASK_ID" '.tasks[] | select(.task_id == $id)')

jq --arg id "$TASK_ID" --argjson task "$TASK" \
   '.tasks = [$task] + [.tasks[] | select(.task_id != $id)]' \
   $COMMIT_RELAY_HOME/coordination/task-queue.json > /tmp/queue.json && \
mv /tmp/queue.json $COMMIT_RELAY_HOME/coordination/task-queue.json
```

---

## Managing Task Status

### Cancel Task

```bash
TASK_ID="task-001"

# Mark as cancelled
jq --arg id "$TASK_ID" \
   '(.tasks[] | select(.task_id == $id) | .status) = "cancelled" |
    (.tasks[] | select(.task_id == $id) | .cancelled_at) = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"' \
   $COMMIT_RELAY_HOME/coordination/task-queue.json > /tmp/queue.json && \
mv /tmp/queue.json $COMMIT_RELAY_HOME/coordination/task-queue.json

# If worker assigned, clean it up
WORKER=$(cat $COMMIT_RELAY_HOME/coordination/task-queue.json | \
    jq -r --arg id "$TASK_ID" '.tasks[] | select(.task_id == $id) | .assigned_worker')

if [[ -n "$WORKER" && "$WORKER" != "null" ]]; then
    ./scripts/cleanup-zombie-workers.sh "$WORKER"
fi
```

### Retry Failed Task

```bash
TASK_ID="task-001"

# Reset to queued
jq --arg id "$TASK_ID" \
   '(.tasks[] | select(.task_id == $id) | .status) = "queued" |
    (.tasks[] | select(.task_id == $id) | .assigned_worker) = null |
    (.tasks[] | select(.task_id == $id) | .retry_count) = ((.tasks[] | select(.task_id == $id) | .retry_count // 0) + 1)' \
   $COMMIT_RELAY_HOME/coordination/task-queue.json > /tmp/queue.json && \
mv /tmp/queue.json $COMMIT_RELAY_HOME/coordination/task-queue.json

echo "Task $TASK_ID queued for retry"
```

### Complete Task Manually

```bash
TASK_ID="task-001"

jq --arg id "$TASK_ID" \
   '(.tasks[] | select(.task_id == $id) | .status) = "completed" |
    (.tasks[] | select(.task_id == $id) | .completed_at) = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"' \
   $COMMIT_RELAY_HOME/coordination/task-queue.json > /tmp/queue.json && \
mv /tmp/queue.json $COMMIT_RELAY_HOME/coordination/task-queue.json
```

---

## Queue Maintenance

### Remove Completed Tasks

```bash
# Archive completed tasks older than 7 days
CUTOFF=$(date -v-7d -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
    date -d '7 days ago' -u +%Y-%m-%dT%H:%M:%SZ)

# Extract for archiving
cat $COMMIT_RELAY_HOME/coordination/task-queue.json | \
    jq --arg c "$CUTOFF" '[.tasks[] | select(.status == "completed" and .completed_at < $c)]' \
    >> $COMMIT_RELAY_HOME/coordination/archived-tasks.jsonl

# Remove from queue
jq --arg c "$CUTOFF" \
   '.tasks = [.tasks[] | select(.status != "completed" or .completed_at >= $c)]' \
   $COMMIT_RELAY_HOME/coordination/task-queue.json > /tmp/queue.json && \
mv /tmp/queue.json $COMMIT_RELAY_HOME/coordination/task-queue.json
```

### Remove Cancelled Tasks

```bash
# Remove all cancelled tasks
jq '.tasks = [.tasks[] | select(.status != "cancelled")]' \
   $COMMIT_RELAY_HOME/coordination/task-queue.json > /tmp/queue.json && \
mv /tmp/queue.json $COMMIT_RELAY_HOME/coordination/task-queue.json
```

### Clear Entire Queue (Emergency)

```bash
# Backup first
cp $COMMIT_RELAY_HOME/coordination/task-queue.json \
   $COMMIT_RELAY_HOME/coordination/task-queue.json.backup.$(date +%s)

# Clear all tasks
jq '.tasks = []' $COMMIT_RELAY_HOME/coordination/task-queue.json > /tmp/queue.json && \
mv /tmp/queue.json $COMMIT_RELAY_HOME/coordination/task-queue.json

echo "Queue cleared. Backup saved."
```

---

## Monitoring Queue Health

### Queue Metrics

```bash
# Queue statistics
echo "=== Queue Statistics ==="
echo "Total tasks: $(cat $COMMIT_RELAY_HOME/coordination/task-queue.json | jq '.tasks | length')"
echo "Queued: $(cat $COMMIT_RELAY_HOME/coordination/task-queue.json | jq '[.tasks[] | select(.status == "queued")] | length')"
echo "In Progress: $(cat $COMMIT_RELAY_HOME/coordination/task-queue.json | jq '[.tasks[] | select(.status == "in_progress")] | length')"
echo "Completed: $(cat $COMMIT_RELAY_HOME/coordination/task-queue.json | jq '[.tasks[] | select(.status == "completed")] | length')"
echo "Failed: $(cat $COMMIT_RELAY_HOME/coordination/task-queue.json | jq '[.tasks[] | select(.status == "failed")] | length')"
```

### Detect Stuck Tasks

```bash
# Tasks in progress for more than 1 hour
NOW=$(date +%s)
cat $COMMIT_RELAY_HOME/coordination/task-queue.json | \
    jq --argjson now "$NOW" '.tasks[] | select(.status == "in_progress") |
        select((.started_at // "") != "") |
        select(($now - (. as $t | $t.started_at | sub("\\.[0-9]+"; "") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime)) > 3600) |
        {task_id, description, started_at}'
```

### Queue Throughput

```bash
# Tasks completed in last 24 hours
YESTERDAY=$(date -v-1d -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
    date -d '1 day ago' -u +%Y-%m-%dT%H:%M:%SZ)

cat $COMMIT_RELAY_HOME/coordination/task-queue.json | \
    jq --arg y "$YESTERDAY" '[.tasks[] | select(.status == "completed" and .completed_at >= $y)] | length'
```

---

## Troubleshooting

### Tasks Not Processing

1. Check coordinator daemon running
2. Verify MoE router configuration
3. Check token budget available
4. Review task format validity

### Duplicate Tasks

```bash
# Find duplicates by description
cat $COMMIT_RELAY_HOME/coordination/task-queue.json | \
    jq '[.tasks[] | .description] | group_by(.) | map(select(length > 1))'
```

### Queue File Corrupted

```bash
# Validate JSON
jq empty $COMMIT_RELAY_HOME/coordination/task-queue.json || echo "Invalid JSON"

# Restore from backup
cp $COMMIT_RELAY_HOME/coordination/task-queue.json.backup \
   $COMMIT_RELAY_HOME/coordination/task-queue.json

# Or initialize empty
echo '{"tasks": []}' > $COMMIT_RELAY_HOME/coordination/task-queue.json
```

---

## Related Runbooks

- [Worker Lifecycle](./worker-lifecycle.md)
- [MoE Router Issues](./moe-router-issues.md)
- [Daily Operations](./daily-operations.md)

---

**Last Updated**: 2025-11-21
