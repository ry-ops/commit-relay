# Commit-Relay Developer Guide

Comprehensive guide to understanding, developing, and operating the commit-relay autonomous automation system.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Key Concepts](#key-concepts)
3. [Development Workflow](#development-workflow)
4. [Creating Workers](#creating-workers)
5. [Task Management](#task-management)
6. [MoE Routing System](#moe-routing-system)
7. [Daemon Operations](#daemon-operations)
8. [Testing and Debugging](#testing-and-debugging)
9. [Best Practices](#best-practices)

---

## Architecture Overview

### System Components

```
                    +-------------------+
                    |   User/Operator   |
                    +--------+----------+
                             |
                    +--------v----------+
                    | Coordinator Master|
                    +--------+----------+
                             |
              +--------------+--------------+
              |              |              |
     +--------v----+  +------v-----+  +-----v------+
     | Development |  |  Security  |  | Inventory  |
     |   Master    |  |   Master   |  |   Master   |
     +------+------+  +-----+------+  +-----+------+
            |               |               |
     +------v------+ +------v------+ +------v------+
     |   Workers   | |   Workers   | |   Workers   |
     +-------------+ +-------------+ +-------------+
```

### Directory Structure

```
commit-relay/
├── coordination/                    # Central coordination state
│   ├── task-queue.json             # Pending tasks
│   ├── token-budget.json           # Token budget management
│   ├── pm-state.json               # PM daemon state
│   ├── worker-specs/               # Worker specifications
│   │   ├── active/                 # Currently running workers
│   │   ├── completed/              # Successfully completed
│   │   └── failed/                 # Failed workers
│   ├── masters/                    # Master agent state
│   │   ├── coordinator/
│   │   ├── development/
│   │   ├── security/
│   │   └── inventory/
│   └── history/                    # Historical snapshots
├── agents/
│   ├── prompts/                    # Agent prompt templates
│   └── logs/                       # Agent execution logs
├── scripts/                        # Operational scripts
│   └── dashboards/                 # Terminal dashboards
└── docs/                           # Documentation
    └── runbooks/                   # Operational runbooks
```

### Data Flow

1. **Task Creation**: Tasks enter via `scripts/create-task.sh` or API
2. **MoE Routing**: Tasks routed to appropriate worker type
3. **Worker Spawn**: Worker created with spec and token budget
4. **Execution**: Worker executes task autonomously
5. **Check-ins**: Worker reports progress to PM daemon
6. **Completion**: Results recorded, tokens reconciled

---

## Key Concepts

### Workers

Workers are autonomous Claude instances that execute specific tasks.

**Worker Types**:
- `implementation-worker`: Code implementation and features
- `scan-worker`: Security scanning and analysis
- `analysis-worker`: Code review and documentation
- `documentation-worker`: Documentation generation
- `fix-worker`: Bug fixes and patches

**Worker Lifecycle**:
1. `pending` - Created but not started
2. `running` - Actively executing
3. `completed` - Successfully finished
4. `failed` - Encountered error
5. `zombie` - Stalled without check-ins

### Token Budget

Token budget controls resource allocation across workers.

```json
{
  "total_budget": 200000,
  "usage_metrics": {
    "total_tokens_used_today": 45000
  },
  "workers": {
    "worker-impl-001": {
      "allocated": 100000,
      "used": 45000
    }
  }
}
```

### MoE (Mixture of Experts) Routing

The MoE system routes tasks to the most appropriate worker type based on:
- Task description keywords
- Historical success patterns
- Worker type capabilities

Routing rules are defined in:
`coordination/masters/coordinator/knowledge-base/routing-rules.json`

### Daemons

Background processes that maintain system health:

| Daemon | Purpose | Interval |
|--------|---------|----------|
| pm-daemon | Monitor workers, track health | 3 min |
| coordinator-daemon | Route tasks, manage queue | 1 min |
| heartbeat-monitor | Monitor daemon health | 5 min |
| zombie-killer | Detect and clean zombies | 5 min |
| metrics-snapshot | Historical snapshots | 5 min |
| governance-monitor | PII/compliance scanning | 10 min |

---

## Development Workflow

### Setting Up

```bash
# Clone repository
git clone https://github.com/ry-ops/commit-relay.git
cd commit-relay

# Set environment
export COMMIT_RELAY_HOME=$(pwd)

# Initialize system
./scripts/start-commit-relay.sh
```

### Creating a Task

```bash
# Create a simple task
./scripts/create-task.sh \
    --description "Implement user authentication" \
    --priority high \
    --worker-type implementation-worker

# Create task with custom budget
./scripts/create-task.sh \
    --description "Security scan of api module" \
    --priority critical \
    --worker-type scan-worker \
    --token-budget 50000 \
    --time-limit 30
```

### Monitoring Progress

```bash
# Watch worker status
watch -n 5 ./scripts/worker-status.sh

# View daemon status
./scripts/dashboards/daemon-monitor.sh --status

# Live metrics
./scripts/dashboards/metrics-dashboard.sh
```

### Debugging

```bash
# Check PM daemon logs
tail -f $COMMIT_RELAY_HOME/agents/logs/system/pm-daemon.log

# Debug MoE routing
./scripts/debug-moe-router.sh "your task description"

# View worker spec
jq . $COMMIT_RELAY_HOME/coordination/worker-specs/active/worker-impl-001.json
```

---

## Creating Workers

### Worker Specification

Workers are defined by JSON specifications:

```json
{
  "worker_id": "worker-implementation-001",
  "worker_type": "implementation-worker",
  "task_id": "task-abc123",
  "status": "pending",
  "task": {
    "description": "Implement feature X",
    "requirements": ["Create API endpoint", "Add tests"],
    "context": {
      "files": ["src/api.ts", "src/routes.ts"]
    }
  },
  "resources": {
    "token_allocation": 100000,
    "time_limit_minutes": 60
  },
  "execution": {
    "started_at": null,
    "completed_at": null
  }
}
```

### Programmatic Worker Creation

```bash
# Using the spawn script
./scripts/spawn-worker.sh \
    --type implementation-worker \
    --task-id "task-12345" \
    --description "Implement new feature" \
    --token-budget 100000 \
    --time-limit 60
```

### Custom Worker Types

To create a new worker type:

1. **Define the prompt template**:
```bash
cat > agents/prompts/custom-worker-prompt.md << 'EOF'
# Custom Worker Agent

You are a specialized worker for [purpose].

## Capabilities
- Capability 1
- Capability 2

## Instructions
1. Read the task specification
2. Execute the task
3. Report completion
EOF
```

2. **Register in worker-types.json**:
```json
{
  "custom-worker": {
    "default_budget": 50000,
    "default_duration": 30,
    "capabilities": ["custom_capability"],
    "prompt_template": "agents/prompts/custom-worker-prompt.md"
  }
}
```

3. **Add routing rules**:
```json
{
  "pattern": "custom|special",
  "worker_type": "custom-worker",
  "confidence": 0.9
}
```

### Worker Check-ins

Workers should report progress periodically:

```bash
# Worker check-in script
./scripts/worker-checkin.sh \
    --worker-id "worker-impl-001" \
    --status "in_progress" \
    --progress 50 \
    --message "Completed API endpoint"
```

Check-in data:
```json
{
  "worker_id": "worker-impl-001",
  "timestamp": "2025-11-21T10:00:00Z",
  "status": "in_progress",
  "progress_pct": 50,
  "message": "Completed API endpoint"
}
```

---

## Task Management

### Task Structure

```json
{
  "task_id": "task-abc123",
  "description": "Implement user authentication",
  "priority": "high",
  "status": "pending",
  "created_at": "2025-11-21T10:00:00Z",
  "worker_type": "implementation-worker",
  "metadata": {
    "source": "user",
    "tags": ["auth", "security"]
  }
}
```

### Task Priorities

| Priority | Description | SLA |
|----------|-------------|-----|
| critical | System breaking | Immediate |
| high | Important feature | < 1 hour |
| medium | Normal work | < 4 hours |
| low | Nice to have | < 24 hours |

### Task Queue Operations

```bash
# List pending tasks
jq '.tasks[] | select(.status == "pending")' \
    $COMMIT_RELAY_HOME/coordination/task-queue.json

# Count tasks by status
jq '.tasks | group_by(.status) | map({status: .[0].status, count: length})' \
    $COMMIT_RELAY_HOME/coordination/task-queue.json

# Find task by ID
jq '.tasks[] | select(.task_id == "task-abc123")' \
    $COMMIT_RELAY_HOME/coordination/task-queue.json
```

---

## MoE Routing System

### Routing Configuration

```json
{
  "rules": [
    {
      "pattern": "implement|create|build|add",
      "worker_type": "implementation-worker",
      "confidence": 0.9
    },
    {
      "pattern": "scan|security|vulnerability",
      "worker_type": "scan-worker",
      "confidence": 0.95
    },
    {
      "pattern": "document|readme|guide",
      "worker_type": "documentation-worker",
      "confidence": 0.9
    }
  ]
}
```

### Testing Routing

```bash
# Test routing decision
./scripts/debug-moe-router.sh "implement user authentication"

# Expected output:
# Task: implement user authentication
# Matched: implementation-worker (confidence: 0.95)
# Alternative: analysis-worker (confidence: 0.3)
```

### Routing Metrics

```bash
# View routing health
cat $COMMIT_RELAY_HOME/coordination/routing-health.json | jq .

# Check for null routes
jq '.null_routes' $COMMIT_RELAY_HOME/coordination/routing-health.json
```

---

## Daemon Operations

### Starting Daemons

```bash
# Start all daemons
./scripts/dashboards/daemon-monitor.sh --start-all

# Start specific daemon
./scripts/pm-daemon.sh &
./scripts/coordinator-daemon.sh &
```

### Stopping Daemons

```bash
# Stop all daemons
./scripts/dashboards/daemon-monitor.sh --stop-all

# Stop specific daemon
kill $(cat /tmp/pm-daemon.pid)
```

### Daemon Health Checks

```bash
# Check PM daemon
./scripts/health-check-pm-daemon.sh

# View daemon status
./scripts/dashboards/daemon-monitor.sh --status
```

### Daemon Logs

```bash
# PM daemon logs
tail -f $COMMIT_RELAY_HOME/agents/logs/system/pm-daemon.log

# Coordinator daemon logs
tail -f $COMMIT_RELAY_HOME/agents/logs/system/coordinator-daemon.log
```

---

## Testing and Debugging

### Running Tests

```bash
# Test core foundation
./scripts/test-core-foundation.sh

# Test autonomous execution
./scripts/test-autonomous-execution.sh

# Load test workers
./scripts/load-test-workers.sh --count 10
```

### Debugging MoE

```bash
# Enable debug logging
export MOE_DEBUG=1

# Debug routing decision
./scripts/debug-moe-router.sh "your task description"

# View routing decisions log
tail -100 $COMMIT_RELAY_HOME/coordination/masters/coordinator/knowledge-base/routing-decisions.jsonl
```

### Debugging Workers

```bash
# View worker spec
cat $COMMIT_RELAY_HOME/coordination/worker-specs/active/worker-impl-001.json | jq .

# Check worker logs
ls -la $COMMIT_RELAY_HOME/agents/logs/

# View PM monitoring state
jq '.monitored_workers["worker-impl-001"]' \
    $COMMIT_RELAY_HOME/coordination/pm-state.json
```

### Common Issues

**Worker stuck in "running" state**:
```bash
# Check for zombie
./scripts/cleanup-zombie-workers.sh

# Force complete worker
jq '.status = "failed" | .error = "Manual termination"' \
    worker-spec.json > worker-spec.json.tmp && \
    mv worker-spec.json.tmp worker-spec.json
```

**MoE routing to null**:
```bash
# Check routing rules
cat $COMMIT_RELAY_HOME/coordination/masters/coordinator/knowledge-base/routing-rules.json | jq .

# Add default rule if missing
```

**Token budget exhausted**:
```bash
# Check budget
cat $COMMIT_RELAY_HOME/coordination/token-budget.json | jq .

# Reset daily budget
./scripts/system-maintenance.sh --reset-token-budget
```

---

## Best Practices

### Worker Design

1. **Single Responsibility**: Each worker should do one thing well
2. **Idempotent Operations**: Workers should be safely restartable
3. **Regular Check-ins**: Report progress every 5-10 minutes
4. **Clean Exits**: Always report completion/failure status
5. **Budget Awareness**: Monitor token usage and stay within limits

### Task Design

1. **Clear Descriptions**: Be specific about what needs to be done
2. **Appropriate Priority**: Use priorities correctly
3. **Reasonable Budgets**: Allocate enough tokens for the task
4. **Context Provision**: Include relevant files and context

### Monitoring

1. **Watch Dashboards**: Regularly check daemon-monitor and metrics
2. **Review Logs**: Check daemon logs for issues
3. **Track Success Rate**: Monitor completion rates
4. **Clean Up Zombies**: Regular zombie detection

### Development

1. **Test Locally**: Test routing and worker creation locally
2. **Use Debug Scripts**: Leverage debug-moe-router.sh
3. **Read Runbooks**: Follow runbooks for common operations
4. **Document Changes**: Update docs when adding features

---

## Related Documentation

- [MOE Architecture](./MOE-ARCHITECTURE.md)
- [Worker Lifecycle](./WORKER-LIFECYCLE.md)
- [Daemon Monitoring](./DAEMON-MONITORING.md)
- [Quick Start](./QUICK-START.md)
- [Cheatsheet](./CHEATSHEET.md)

## Runbooks

- [Worker Failure](./runbooks/worker-failure.md)
- [Daemon Failure](./runbooks/daemon-failure.md)
- [Token Budget Exhaustion](./runbooks/token-budget-exhaustion.md)
- [Daily Operations](./runbooks/daily-operations.md)
- [Emergency Recovery](./runbooks/emergency-recovery.md)

---

**Last Updated**: 2025-11-21
