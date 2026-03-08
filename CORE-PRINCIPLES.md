# Commit-Relay Core Principles Framework
## Building Systematic Excellence Into the DNA

**Status**: CRITICAL - Foundation for all development
**Created**: 2025-11-17
**Version**: 1.0
**Philosophy**: Make the right thing the easy thing

---

## Table of Contents

1. [The Problem](#the-problem)
2. [The 7 Core Principles](#the-7-core-principles)
3. [Systematic Enforcement Architecture](#systematic-enforcement-architecture)
4. [Core Services Infrastructure](#core-services-infrastructure)
5. [Development Workflows](#development-workflows)
6. [Implementation Roadmap](#implementation-roadmap)
7. [Measuring Success](#measuring-success)

---

## The Problem

### What We've Learned from Past Incidents

**2025-11-11: The Uninitialized Variable Disaster**
```json
{
  "skills_required": ,
  "token_allocation": ,
  "timeout_minutes": ,
}
```
- 10 worker specs generated with uninitialized variables
- 100% worker spawn failure rate
- Complete system paralysis
- Root cause: No validation before writing JSON

**2025-11-14: The Context Injection Failure**
```
Task context loaded: {"title":null,"type":null,"priority":null}
Worker process not detected (may have already completed or failed)
```
- Task existed but context wasn't injected
- Worker spawned but immediately failed silently
- No error categorization, no runbook, no auto-fix
- Root cause: No observability, no validation

**Ongoing: The Zombie Worker Problem**
- 32 zombie workers accumulating with no failure analysis
- Worker heartbeat mechanism broken (all showing `null`)
- No automatic cleanup or recovery
- Root cause: No systematic health monitoring

### The Pattern

**Every incident shares common root causes:**
1. ❌ **No systematic validation** - Hope instead of enforcement
2. ❌ **No observability** - Failures happen in darkness
3. ❌ **Manual processes** - Depends on remembering to do the right thing
4. ❌ **No guardrails** - Easy to bypass or forget critical steps
5. ❌ **No feedback loops** - Can't learn from failures automatically

### The Solution

**Make excellence automatic by embedding it at the core:**
- ✅ Validation happens automatically, can't be skipped
- ✅ Observability is built-in, not bolted-on
- ✅ Automation is the default, manual is the exception
- ✅ Guardrails prevent common mistakes
- ✅ System learns and improves continuously

---

## The 7 Core Principles

These are **non-negotiable foundations** that must be present in every component:

### 1. Observability First

**Principle**: Every operation must be traceable, measurable, and debuggable.

**Requirements:**
- Every task/worker/operation has a unique trace_id
- All events emit structured logs with correlation IDs
- All state transitions are captured
- All failures include categorized error codes
- All operations emit metrics (duration, tokens, resources)

**Enforcement:**
- Automatic trace_id generation and propagation
- Mandatory structured logging library (no plain echo)
- ObservabilityHub daemon aggregates all events
- Query API makes all data searchable
- Dashboard visualizes real-time system state

**Why It Matters:**
> "You can't fix what you can't see. Without observability, debugging takes 30+ minutes. With it, 2 minutes."

### 2. Validation Always

**Principle**: Validate early, validate often, fail fast.

**Requirements:**
- JSON must be syntactically valid before writing
- JSON must pass schema validation before use
- Worker specs must be validated before spawning
- Configuration must be validated on load
- No uninitialized variables allowed in templates

**Enforcement:**
- `safe_write_json()` wrapper that validates before writing
- Automatic schema validation for all coordination files
- Template variable checker prevents `, ,` patterns
- Required field validator ensures no null critical fields
- Pre-flight checks before every worker spawn

**Why It Matters:**
> "The 2025-11-11 incident: 10 malformed specs paralyzed the entire system. One validation check would have prevented it."

### 3. Governance by Default

**Principle**: Security and compliance are not optional extras.

**Requirements:**
- All operations check permissions before execution
- All access attempts are logged (allow + deny)
- Role-based access control (RBAC) enforced
- Sensitive data automatically detected and protected
- Audit trail for all coordination file changes

**Enforcement:**
- Mandatory `check_permission()` calls in all libraries
- Access log audit trail (currently 670KB of real checks)
- PII scanner runs automatically
- Data quality monitor validates all writes
- Governance bypass only allowed with explicit audit

**Why It Matters:**
> "Governance prevents security incidents. Current access log shows 2,489 permission checks - that's 2,489 potential security decisions being made correctly."

### 4. Self-Healing Systems

**Principle**: Detect failures automatically, recover automatically.

**Requirements:**
- Health checks for all services (heartbeat-based)
- Automatic restart of failed daemons
- Zombie worker detection and cleanup
- Backup service spawning on critical failures
- Automatic retry with exponential backoff

**Enforcement:**
- Health Monitor Daemon checks every 3 minutes
- Daemon Supervisor restarts failed daemons within 30 seconds
- Zombie Killer Daemon cleans up stale workers
- SLA-based alerting (15/30/60/120 minute thresholds)
- Auto-fix framework for common failures

**Why It Matters:**
> "Manual recovery takes hours. Automatic recovery takes seconds. The difference between downtime and resilience."

### 5. Fail-Safe Defaults

**Principle**: The default behavior should be the safe behavior.

**Requirements:**
- Governance enabled by default (can't bypass without audit)
- Logging enabled at INFO level by default
- Heartbeats required for all long-running processes
- Token budgets enforced by default
- Timeouts set conservatively by default

**Enforcement:**
- Central configuration with safe defaults
- Environment variable overrides audited
- Bypass flags logged critically
- Required services checked before starting
- Lock files prevent concurrent unsafe operations

**Why It Matters:**
> "If doing the wrong thing is easier than doing the right thing, people will do the wrong thing. Make safety effortless."

### 6. Continuous Learning

**Principle**: The system must learn from every execution.

**Requirements:**
- Success/failure patterns captured
- Error categorization and frequency tracking
- Performance metrics analyzed for trends
- Routing decisions tracked (MoE learning)
- Runbooks generated from common failures

**Enforcement:**
- MoE Code Learner analyzes task outcomes
- Failure Analyzer categorizes all errors
- Metrics dashboard shows trends over time
- Knowledge base updated from routing decisions
- Automated runbook generation from incidents

**Why It Matters:**
> "Experience without learning is just repetition. Every failure should make the system smarter."

### 7. Developer Experience

**Principle**: Make doing the right thing the easy thing.

**Requirements:**
- One-line initialization for all scripts
- Automatic service registration (no manual JSON editing)
- Helper scripts for common tasks
- Clear error messages with suggested fixes
- Comprehensive documentation with examples

**Enforcement:**
- `init-common.sh` loads all libraries automatically
- `register-service.sh` handles all registration tasks
- `generate-worker-spec.sh` creates validated specs
- Error messages include runbook links
- Every script has `--help` with examples

**Why It Matters:**
> "If it's hard to do the right thing, people will find shortcuts. Make excellence effortless."

---

## Systematic Enforcement Architecture

### The Core Services Layer

```
┌─────────────────────────────────────────────────────────────┐
│                    Application Layer                         │
│  (Masters, Workers, Daemons, Scripts)                       │
└──────────────────────┬──────────────────────────────────────┘
                       │ All operations go through ↓
┌─────────────────────────────────────────────────────────────┐
│                  Core Services Layer (NEW)                   │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │ Observability│  │  Validation  │  │  Governance  │      │
│  │     Hub      │  │   Service    │  │   Service    │      │
│  └──────────────┘  └──────────────┘  └──────────────┘      │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │    Health    │  │ Configuration│  │   Learning   │      │
│  │   Monitor    │  │   Service    │  │   Service    │      │
│  └──────────────┘  └──────────────┘  └──────────────┘      │
└──────────────────────┬──────────────────────────────────────┘
                       │ Built on ↓
┌─────────────────────────────────────────────────────────────┐
│                  Foundation Layer                            │
│  (Shared Libraries, Common Utilities)                       │
│  - init-common.sh (mandatory loading)                       │
│  - logging.sh (structured events)                           │
│  - coordination.sh (task/worker/token ops)                  │
│  - access-check.sh (permission checks)                      │
└─────────────────────────────────────────────────────────────┘
```

### Initialization Flow (Enforced)

**Every script/agent follows this mandatory pattern:**

```bash
#!/bin/bash
# Step 1: Load core foundation (MANDATORY)
source "$(dirname "$0")/lib/init-common.sh" || {
  echo "FATAL: Cannot initialize core services"
  exit 99
}

# Step 2: Automatic initialization happens in init-common.sh:
# - Loads all libraries in correct order
# - Sets up environment variables
# - Creates required directories
# - Registers principal with governance
# - Starts trace for this operation
# - Validates core services are running

# Step 3: Script-specific work (with core services available)
main() {
  trace_start "my-operation" "$OPERATION_ID"

  # Validation is automatic
  safe_write_json "$data" "$path" "schema-name"

  # Governance is automatic
  check_permission "$PRINCIPAL" "asset" "write" || exit 1

  # Logging is automatic
  log_info "Operation succeeded"

  # Observability is automatic
  trace_event "step-completed" "success" "$metadata"

  trace_end "my-operation" "success"
}

# Step 4: Automatic cleanup happens on exit
# - Trace finalized
# - Resources released
# - Status updated
# - Events flushed
```

**What This Prevents:**
- ❌ Can't forget to load libraries
- ❌ Can't skip validation
- ❌ Can't bypass governance without audit
- ❌ Can't create operations without observability
- ❌ Can't fail silently without categorization

### The "Pit of Success" Pattern

**Old Way (Easy to mess up):**
```bash
#!/bin/bash
# Hope you remembered to source all the right libraries
source ../lib/logging.sh  # Oops, wrong path!
source ../lib/coordination.sh  # Forgot access-check.sh!

# Hope you remember to validate JSON
worker_spec='{"worker_id":"'$WORKER_ID'","skills_required": ,}'  # Oops!
echo "$worker_spec" > spec.json  # No validation!

# Hope you remember to check permissions
# (Forgot to check, now we have unauthorized access)

# Hope you remember to log events
# (Forgot to log, now failure is invisible)
```

**New Way (Pit of Success):**
```bash
#!/bin/bash
# One line - everything initialized correctly
source "$(dirname "$0")/lib/init-common.sh" || exit 99

# Helper enforces validation
generate_worker_spec \
  --worker-type implementation-worker \
  --task-id "$TASK_ID" \
  --output spec.json
# Automatically: validated, correct schema, no uninitialized vars

# Helper enforces governance
safe_write_json "$data" "coordination/tasks/$TASK_ID.json" "task-schema"
# Automatically: permission check, validation, audit log

# Helper enforces observability
trace_event "worker-spawned" "success" '{"worker_id":"'$WORKER_ID'"}'
# Automatically: structured log, correlation ID, dashboard event
```

---

## Core Services Infrastructure

### 1. ObservabilityHub Service

**Purpose**: Unified observability across all components

**Location**: `scripts/daemons/observability-hub-daemon.sh`

**Responsibilities:**
- Event ingestion from all components
- Stream aggregation into unified timeline
- Correlation index building (trace_id → events)
- Real-time dashboard broadcasting
- Query API for searching events
- Automatic log rotation and archival

**Files:**
```
coordination/observability/
├── events/                     # Event drop-off (watched by inotify)
│   ├── master-events.jsonl
│   ├── worker-events.jsonl
│   └── daemon-events.jsonl
├── stream/
│   ├── current.jsonl           # Today's unified stream
│   └── archive/                # Compressed archives
│       └── YYYY-MM-DD.jsonl.gz
├── indices/
│   ├── by-trace-id.json        # Fast trace lookup
│   ├── by-worker.json          # Fast worker lookup
│   └── by-error.json           # Fast error lookup
└── lib/
    ├── trace.sh                # Bash tracing library
    └── trace.js                # Node.js tracing library
```

**API:**
```bash
# Library usage (automatic via init-common.sh)
trace_start "operation-name" "$OPERATION_ID"
trace_event "event-type" "status" "$metadata_json"
trace_end "operation-name" "final-status"

# Query API
obs-query --trace-id task-1234 --timeline
obs-query --worker-id worker-001 --events
obs-query --error-code CONTEXT_INJECTION_FAILED --last 24h
obs-query --component development-master --performance-stats
```

### 2. ValidationService

**Purpose**: Systematic validation before operations

**Location**: `scripts/lib/validation-service.sh`

**Responsibilities:**
- JSON syntax validation
- Schema compliance checking
- Template variable validation (no uninitialized)
- Required field validation
- Value constraint checking
- Pre-flight checks before spawning

**API:**
```bash
# Safe JSON write (validates automatically)
safe_write_json "$json_data" "$output_path" "$schema_name"
# Returns: 0 if valid and written, 1 if invalid

# Schema validation
validate_json_schema "$json_data" "worker-spec"
# Checks against schemas/worker-spec.json

# Template validation
validate_template_vars "$template_content"
# Ensures no ", ," patterns (uninitialized variables)

# Worker spec validation (comprehensive)
validate_worker_spec "$worker_spec_path"
# Checks:
# - JSON syntax valid
# - Schema compliant
# - All required fields present
# - No uninitialized variables
# - Token budget within limits
# - Worker type registered
# - Task exists
```

**Schemas Location:**
```
coordination/schemas/
├── worker-spec.json
├── task-spec.json
├── agent-registry.json
├── handoff.json
└── health-alert.json
```

### 3. GovernanceService

**Purpose**: Centralized access control and compliance

**Location**: Enhanced `scripts/lib/access-check.sh`

**Responsibilities:**
- Permission checking (RBAC)
- Access logging (all decisions)
- PII detection and masking
- Data quality monitoring
- Compliance reporting
- Bypass auditing

**API:**
```bash
# Check permission (existing, enhanced)
check_permission "$PRINCIPAL" "$ASSET" "$OPERATION"
# Returns: 0 if allowed, 1 if denied
# Logs: coordination/governance/access-log.jsonl

# Require permission (fails script if denied)
require_permission "$PRINCIPAL" "$ASSET" "$OPERATION"

# Detect PII
detect_pii "$content"
# Returns: JSON array of PII findings

# Validate data quality
validate_data_quality "$data" "$quality_rules"

# Audit bypass (when GOVERNANCE_BYPASS=true)
audit_bypass "$PRINCIPAL" "$REASON"
# Logs: coordination/governance/bypass-log.jsonl (CRITICAL level)
```

**Current State (Already Robust):**
- 2,489 permission checks logged in access-log.jsonl
- RBAC with 3 roles: system-admin, agent-operator, observer
- Automatic access denial and logging
- Can be enhanced with PII detection and quality checks

### 4. HealthMonitorService

**Purpose**: Continuous health monitoring and auto-recovery

**Location**: Enhanced `scripts/daemons/health-monitor-daemon.sh`

**Responsibilities:**
- Heartbeat checking (every 3 minutes)
- SLA-based alerting (15/30/60/120 min)
- Zombie detection and cleanup
- Backup service spawning
- Health incident tracking
- Recovery orchestration

**Current Implementation (Strong Foundation):**
```bash
# Already monitoring:
- PM daemon (5-min heartbeat threshold)
- Coordinator agent (5-min threshold)
- All daemons (via daemon-supervisor)
- Worker pool (zombie detection: >10 triggers alert)

# Already responding:
- Spawns backup PM daemon if critical stale
- Creates health incidents in coordination/health-incidents/
- Alerts in coordination/health-alerts.json with SLA tracking
```

**Enhancements Needed:**
- Worker-level heartbeats (currently broken, all null)
- Automatic failure categorization
- Auto-fix framework integration
- Proactive anomaly detection

### 5. ConfigurationService

**Purpose**: Centralized, versioned configuration management

**Location**: `coordination/config/system.json` (NEW)

**Responsibilities:**
- Single source of truth for all settings
- Environment-specific overrides
- Version control of configuration
- Runtime configuration updates
- Configuration validation

**Structure:**
```json
{
  "version": "1.0",
  "last_updated": "2025-11-17T11:00:00Z",

  "logging": {
    "level": "info",
    "directory": "agents/logs/system",
    "retention_days": 30,
    "broadcast_errors_to_dashboard": true,
    "structured_format": "jsonl"
  },

  "observability": {
    "enabled": true,
    "trace_all_operations": true,
    "event_buffer_size": 10000,
    "query_api_enabled": true,
    "dashboard_streaming": true
  },

  "governance": {
    "enabled": true,
    "bypass_allowed": false,
    "audit_all_operations": true,
    "pii_detection_enabled": true,
    "enforce_on": [
      "worker-spawn",
      "asset-write",
      "sensitive-read",
      "coordination-update"
    ]
  },

  "services": {
    "heartbeat_interval_seconds": 30,
    "health_check_interval_seconds": 180,
    "stale_heartbeat_threshold_seconds": 300,
    "max_workers_per_master": 20,
    "max_zombies_before_alert": 10,
    "token_budget_enforcement": true
  },

  "workers": {
    "default_timeout_minutes": 45,
    "default_token_budget": 10000,
    "heartbeat_required": true,
    "auto_retry_on_failure": true,
    "max_retries": 3
  },

  "masters": {
    "coordinator": { "token_budget": 50000, "priority": "critical" },
    "development": { "token_budget": 100000, "priority": "high" },
    "security": { "token_budget": 75000, "priority": "critical" },
    "inventory": { "token_budget": 50000, "priority": "medium" },
    "cicd": { "token_budget": 75000, "priority": "high" }
  }
}
```

**API:**
```bash
# Get configuration value
get_config "logging.level"  # Returns: "info"
get_config "workers.default_timeout_minutes"  # Returns: 45

# Get entire section
get_config_section "governance"  # Returns: JSON object

# Override with environment variable
# COMMIT_RELAY_LOG_LEVEL=debug overrides logging.level

# Validate configuration on load
validate_system_config
# Ensures all required fields present, types correct
```

### 6. LearningService

**Purpose**: Continuous improvement from execution data

**Location**: Enhanced `coordination/masters/coordinator/lib/moe-code-learner.sh`

**Responsibilities:**
- Success/failure pattern analysis
- Error categorization and trending
- Performance metric analysis
- Routing decision optimization (MoE)
- Automatic runbook generation
- Knowledge base updates

**Current Foundation (Already Implemented):**
```bash
# MoE Learning System:
- Task routing decisions logged to routing-decisions.jsonl
- Routing patterns in knowledge-base/routing-patterns.json
- Performance metrics tracked per master

# Example routing pattern:
{
  "pattern": "security_vulnerability",
  "confidence": 0.95,
  "expert": "security-master",
  "learned_from": 47,
  "success_rate": 0.98
}
```

**Enhancements Needed:**
- Failure pattern detection
- Automatic runbook generation from common errors
- Anomaly detection (performance degradation)
- Predictive failure warnings

### 7. ServiceDiscoveryService

**Purpose**: Dynamic service registration and discovery

**Location**: `scripts/lib/service-discovery.sh` (NEW)

**Responsibilities:**
- Automatic service registration
- Runtime service discovery
- Health status querying
- Dependency resolution
- Service endpoints management

**API:**
```bash
# Register service (automatic in init-common.sh)
register_service "$SERVICE_NAME" "$SERVICE_TYPE" "$SCRIPT_PATH"
# Automatically:
# - Adds to agent-registry.json
# - Creates role in roles.json
# - Creates log directory
# - Registers heartbeat

# Discover services
discover_all_services  # Returns: JSON array of all services
discover_by_type "daemon"  # Returns: All daemon services
discover_by_capability "scan"  # Returns: Services that can scan

# Check service status
get_service_status "health-monitor-daemon"
# Returns: {"status":"running","pid":12345,"uptime":3600}

# Wait for dependency
wait_for_service "coordinator-daemon" 30
# Blocks until service is running or timeout
```

**Registry Structure:**
```json
{
  "services": {
    "health-monitor-daemon": {
      "type": "daemon",
      "status": "running",
      "pid": 31184,
      "started_at": "2025-11-17T11:12:50Z",
      "script": "scripts/daemons/health-monitor-daemon.sh",
      "endpoints": {
        "heartbeat": "coordination/health-monitor-heartbeat.json",
        "alerts": "coordination/health-alerts.json"
      },
      "dependencies": ["pm-daemon"],
      "capabilities": ["health-check", "auto-recovery"]
    }
  }
}
```

---

## Development Workflows

### Creating a New Master Agent

**Old Way (Manual, Error-Prone):**
```bash
# 1. Manually edit agent-registry.json (hope JSON stays valid)
vim agents/configs/agent-registry.json

# 2. Manually edit roles.json (hope permissions are right)
vim coordination/governance/roles.json

# 3. Create directory structure (hope you got all the paths)
mkdir -p coordination/masters/my-master/{context,logs,handoffs}

# 4. Copy and modify a run script (hope you updated all variables)
cp scripts/run-development-master.sh scripts/run-my-master.sh
vim scripts/run-my-master.sh

# 5. Hope you didn't forget anything...
```

**New Way (Automated, Validated):**
```bash
# One command - everything automated
./scripts/create-new-master.sh \
  --name "analysis-master" \
  --capabilities "code-analysis,pattern-detection" \
  --token-budget 75000 \
  --priority high

# Automatically:
# ✅ Validates name is unique
# ✅ Updates agent-registry.json (validated)
# ✅ Creates role in roles.json
# ✅ Creates directory structure
# ✅ Generates run script from template
# ✅ Registers with service discovery
# ✅ Creates initial state files
# ✅ Logs to governance audit trail
# ✅ Displays next steps

Output:
✅ analysis-master created successfully
   Registry: agents/configs/agent-registry.json
   Role: coordination/governance/roles.json
   Directory: coordination/masters/analysis-master/
   Run script: scripts/run-analysis-master.sh

Next steps:
1. Create prompt: agents/prompts/analysis-master.md
2. Test: ./scripts/run-analysis-master.sh
3. Verify: ./scripts/obs-query.sh --component analysis-master
```

### Spawning a Worker

**Old Way:**
```bash
# Manually create worker spec (hope JSON is valid)
cat > coordination/worker-specs/active/worker-001.json <<EOF
{
  "worker_id": "worker-001",
  "worker_type": "implementation-worker",
  "task_id": "$TASK_ID",
  "skills_required": $SKILLS,  # Oops! Uninitialized variable!
  "token_budget": 10000
}
EOF

# Manually spawn (no validation)
./scripts/start-worker.sh worker-001
```

**New Way:**
```bash
# Helper validates everything
./scripts/spawn-worker.sh \
  --task-id task-feature-001 \
  --worker-type implementation-worker \
  --skills "golang,testing" \
  --priority high

# Automatically:
# ✅ Validates task exists
# ✅ Checks permissions
# ✅ Generates validated worker spec
# ✅ Performs pre-flight checks
# ✅ Spawns with trace_id
# ✅ Registers heartbeat
# ✅ Emits observability events

Output:
✅ Worker worker-implementation-005 spawned
   Trace ID: task-feature-001
   Spec: coordination/worker-specs/active/worker-implementation-005.json
   Logs: agents/workers/worker-implementation-005/logs/
   Timeline: obs-query --trace-id task-feature-001
```

### Debugging a Failure

**Old Way:**
```bash
# 1. Notice worker failed (from dashboard or logs)
# 2. Manually check worker pool
jq '.active_workers[] | select(.worker_id == "worker-001")' coordination/worker-pool.json

# 3. Manually check worker logs
cat agents/workers/worker-001/logs/stdout.log | grep -i error

# 4. Manually check task queue
jq '.tasks[] | select(.id == "task-123")' coordination/task-queue.json

# 5. Try to piece together what happened...
# ⏰ Time: 30+ minutes
```

**New Way:**
```bash
# One command - complete timeline
./scripts/obs-query.sh --worker-id worker-001 --timeline

Output:
Trace Timeline for task-feature-001 (worker-001):
─────────────────────────────────────────────────────────
[11:12:44.123] task.created (coordinator)
[11:12:44.456] master.task_received (development-master)
[11:12:44.789] master.routing_decision (development-master)
              → Routed to: implementation-worker
[11:12:45.123] worker.spawn (development-master)
              → Worker ID: worker-001
[11:12:45.456] worker.starting (worker-001)
[11:12:45.789] worker.context_loading (worker-001)
[11:12:46.012] ❌ worker.context_loading FAILED
              Error Code: CONTEXT_INJECTION_FAILED
              Error: Task context returned null fields
              Expected: {title, type, priority}
              Actual: {null, null, null}
[11:12:46.345] worker.failed (worker-001)
[11:12:46.678] task.failed (coordinator)
              Final Status: FAILED

Failure Analysis:
  Category: Configuration Error
  Severity: Critical
  Root Cause: Worker launcher did not properly inject task context
  Runbook: docs/runbooks/context-injection-failure.md
  Auto-Fix: Available (run: scripts/fix-context-injection.sh worker-001)

Suggested Actions:
  1. Review worker launcher script for context injection logic
  2. Verify task spec has all required fields
  3. Run auto-fix to retry with corrected context

⏱️ Time: 2 minutes
─────────────────────────────────────────────────────────
```

### Adding a New Daemon

**Old Way:**
```bash
# 1. Write daemon script
vim scripts/my-daemon.sh

# 2. Manually add to daemon-supervisor
vim scripts/daemon-supervisor.sh
# Add to DAEMON_LIST array

# 3. Manually add to startup script
vim scripts/start-commit-relay.sh
# Add to DAEMONS array

# 4. Manually create log directory
mkdir -p logs/daemons

# 5. Test manually
./scripts/my-daemon.sh &

# 6. Hope everything works...
```

**New Way:**
```bash
# Register daemon (handles everything)
./scripts/daemon-control.sh register \
  --name my-monitor-daemon \
  --script scripts/my-monitor-daemon.sh \
  --auto-start \
  --supervise

# Automatically:
# ✅ Adds to daemon-supervisor.sh
# ✅ Adds to start-commit-relay.sh
# ✅ Creates log directory
# ✅ Sets up PID file location
# ✅ Registers with service discovery
# ✅ Creates launchd plist (optional)
# ✅ Validates script exists and is executable

# Start it
./scripts/daemon-control.sh start my-monitor-daemon

# Verify it's working
./scripts/daemon-control.sh status my-monitor-daemon
✅ my-monitor-daemon is running (PID: 45678)
   Uptime: 2m 34s
   Memory: 12MB
   Heartbeat: OK (8 seconds ago)
```

---

## Implementation Roadmap

### Phase 0: Foundation (Week 0 - Immediate)

**Goal**: Set up core infrastructure files and libraries

**Tasks:**
- [x] Create `CORE-PRINCIPLES.md` (this document)
- [ ] Create `coordination/config/system.json` with defaults
- [ ] Create `scripts/lib/init-common.sh` (mandatory initialization)
- [ ] Create `scripts/lib/validation-service.sh`
- [ ] Create `scripts/lib/service-discovery.sh`
- [ ] Create `coordination/schemas/` directory with JSON schemas
- [ ] Update all existing scripts to source `init-common.sh`

**Deliverables:**
- Core libraries ready to use
- Configuration management in place
- Foundation for all other phases

**Validation:**
- All existing scripts load init-common.sh successfully
- Configuration can be queried with get_config()
- JSON validation works with safe_write_json()

### Phase 1: Observability Integration (Week 1)

**Goal**: Implement ObservabilityHub and tracing

**From OBSERVABILITY-STRATEGY.md:**
- [ ] Create `coordination/observability/` structure
- [ ] Implement `trace.sh` and `trace.js` libraries
- [ ] Create `observability-hub-daemon.sh`
- [ ] Add trace_id generation to task creation
- [ ] Add trace_id propagation to worker spawner
- [ ] Implement event ingestion and aggregation
- [ ] Create `obs-query.sh` CLI tool

**Deliverables:**
- Complete end-to-end tracing
- Queryable event stream
- Real-time observability

**Validation:**
- Single task traces from creation → completion
- obs-query returns complete timelines
- Dashboard shows live event stream

### Phase 2: Validation Enforcement (Week 2)

**Goal**: Prevent malformed data from entering the system

**Tasks:**
- [ ] Implement JSON schema validation for all coordination files
- [ ] Create `safe_write_json()` wrapper (mandatory use)
- [ ] Implement template variable validator
- [ ] Create worker spec validator
- [ ] Add pre-flight checks to worker spawner
- [ ] Update all write operations to use safe_write_json()

**Deliverables:**
- Zero malformed JSON can be written
- All worker specs validated before spawning
- Template variables checked for initialization

**Validation:**
- Test with intentionally malformed JSON (should be rejected)
- Reproduce 2025-11-11 incident (should be prevented)
- All existing specs pass validation

### Phase 3: Governance Enhancement (Week 3)

**Goal**: Strengthen security and compliance

**Tasks:**
- [ ] Implement PII detection scanner
- [ ] Add data quality monitoring
- [ ] Create bypass auditing system
- [ ] Enhance access logging with categorization
- [ ] Implement compliance reporting dashboard
- [ ] Add automatic sensitive data masking

**Deliverables:**
- PII automatically detected and protected
- All bypass attempts audited
- Compliance reports generated

**Validation:**
- PII scanner detects test data (SSN, email, etc.)
- Governance bypass logs to CRITICAL
- Access log shows all permission checks

### Phase 4: Self-Healing Implementation (Week 4)

**Goal**: Automatic failure detection and recovery

**Tasks:**
- [ ] Fix worker heartbeat mechanism
- [ ] Implement failure categorization system
- [ ] Create auto-fix framework with runbooks
- [ ] Add proactive anomaly detection
- [ ] Implement automatic retry logic
- [ ] Create incident response automation

**Deliverables:**
- Zero zombie workers without analysis
- Common failures auto-fixed
- Anomalies detected proactively

**Validation:**
- Kill a daemon, verify auto-restart
- Trigger known failure, verify auto-fix
- Worker heartbeats updating correctly

### Phase 5: Developer Experience (Week 5)

**Goal**: Make common tasks effortless

**Tasks:**
- [ ] Create `create-new-master.sh` helper
- [ ] Create `spawn-worker.sh` helper (validated)
- [ ] Create `register-service.sh` helper
- [ ] Add `--help` to all scripts
- [ ] Generate runbooks for all error codes
- [ ] Create interactive troubleshooting guide

**Deliverables:**
- Zero manual JSON editing required
- One-command service creation
- Comprehensive help system

**Validation:**
- Create new master in <2 minutes
- Spawn worker with full validation in <1 minute
- All scripts have helpful --help output

### Phase 6: Learning & Optimization (Week 6)

**Goal**: Continuous improvement from data

**Tasks:**
- [ ] Enhance MoE learning system
- [ ] Implement failure pattern detection
- [ ] Create automatic runbook generation
- [ ] Add performance trend analysis
- [ ] Implement predictive failure warnings
- [ ] Create optimization recommendations

**Deliverables:**
- System learns from every execution
- Runbooks auto-generated from incidents
- Performance optimizations suggested

**Validation:**
- New failure patterns automatically detected
- Runbooks created for common errors
- Performance trends visualized

---

## Measuring Success

### Key Performance Indicators (KPIs)

**1. Reliability Metrics**
- Zero malformed JSON incidents (was: 1 major incident)
- Zero zombie workers without failure analysis (was: 32 zombies)
- <1% worker spawn failure rate (was: unknown, suspected >10%)
- 99.9% daemon uptime with auto-recovery

**2. Debugging Efficiency**
- Mean Time To Identify (MTTI): <5 minutes (was: 30+ minutes)
- Mean Time To Resolution (MTTR): <30 minutes (was: hours)
- 90% of failures have runbooks
- 50% of failures have auto-fix

**3. Developer Productivity**
- New master creation: <5 minutes (was: 30+ minutes manual)
- Worker spawn with validation: <1 minute
- Service registration: <2 minutes (was: 15+ minutes manual)
- Zero manual JSON editing required

**4. System Intelligence**
- 100% of operations traced with correlation IDs
- 100% of failures categorized with error codes
- 95%+ routing decision accuracy (MoE learning)
- Automatic runbook generation for common failures

**5. Governance & Compliance**
- 100% of access attempts logged
- Zero governance bypasses without audit
- 100% of PII detected and masked
- Compliance reports generated automatically

### Success Criteria Checklist

**Foundation (Must Have):**
- [x] Core principles documented
- [ ] init-common.sh loads in all scripts
- [ ] Configuration centralized in system.json
- [ ] All coordination files have JSON schemas
- [ ] Service discovery operational

**Observability (Must Have):**
- [ ] 100% of tasks have trace_id
- [ ] obs-query returns complete timelines
- [ ] Dashboard shows real-time events
- [ ] All failures include error codes
- [ ] Query API responds <1 second

**Validation (Must Have):**
- [ ] safe_write_json() enforced everywhere
- [ ] Worker specs validated before spawn
- [ ] Zero malformed JSON can be written
- [ ] Pre-flight checks prevent bad spawns
- [ ] Template variables validated

**Self-Healing (Must Have):**
- [ ] Daemons auto-restart within 30 seconds
- [ ] Worker heartbeats functional
- [ ] Zombie detection and cleanup working
- [ ] Common failures have auto-fix
- [ ] Health alerts have SLA tracking

**Developer Experience (Should Have):**
- [ ] One-command master creation
- [ ] One-command worker spawn
- [ ] One-command service registration
- [ ] All scripts have --help
- [ ] Error messages include runbook links

**Learning (Nice to Have):**
- [ ] MoE learning from routing decisions
- [ ] Failure patterns detected automatically
- [ ] Runbooks generated from incidents
- [ ] Performance trends analyzed
- [ ] Optimization recommendations provided

---

## Preventing Regression

### How We Ensure Principles Survive Development

**1. Automated Testing**
```bash
# tests/core-principles-validation.sh
#!/bin/bash
# Runs on every commit

# Test 1: All scripts load init-common.sh
echo "Testing mandatory initialization..."
for script in scripts/**/*.sh; do
  if ! grep -q 'init-common.sh' "$script"; then
    echo "❌ FAIL: $script missing init-common.sh"
    exit 1
  fi
done

# Test 2: No direct JSON writes (must use safe_write_json)
echo "Testing safe JSON writes..."
if grep -r 'echo.*> .*\.json' scripts/; then
  echo "❌ FAIL: Direct JSON write detected (use safe_write_json)"
  exit 1
fi

# Test 3: All worker spawns have validation
echo "Testing worker spawn validation..."
if grep -r 'start-worker.sh' scripts/ | grep -v 'validate_worker_spec'; then
  echo "❌ FAIL: Worker spawn without validation"
  exit 1
fi

echo "✅ All core principle tests passed"
```

**2. Pre-Commit Hooks**
```bash
# .git/hooks/pre-commit
#!/bin/bash
# Enforce core principles before commit

./tests/core-principles-validation.sh || {
  echo "❌ Core principles validation failed"
  echo "Fix issues before committing"
  exit 1
}

./tests/json-schema-validation.sh || {
  echo "❌ JSON schema validation failed"
  exit 1
}

./tests/governance-compliance.sh || {
  echo "❌ Governance compliance check failed"
  exit 1
}

echo "✅ All validation passed"
```

**3. CI/CD Enforcement**
```yaml
# .github/workflows/core-principles.yml
name: Core Principles Validation
on: [push, pull_request]
jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      - name: Validate Core Principles
        run: ./tests/core-principles-validation.sh
      - name: Validate JSON Schemas
        run: ./tests/json-schema-validation.sh
      - name: Check Observability Coverage
        run: ./tests/observability-coverage.sh
      - name: Governance Compliance
        run: ./tests/governance-compliance.sh
```

**4. Documentation Requirements**
- Every new script must include header comment with:
  - Purpose
  - Core principles it uses
  - Validation it performs
  - Observability events it emits

**5. Code Review Checklist**
- [ ] Uses init-common.sh for initialization
- [ ] Validates all JSON before writing (safe_write_json)
- [ ] Checks permissions before sensitive operations
- [ ] Emits observability events (trace_event)
- [ ] Includes error handling with categorization
- [ ] Has --help documentation
- [ ] Updates relevant schemas if needed

**6. Quarterly Audits**
- Review observability coverage (should be 100%)
- Analyze failure patterns (should decrease over time)
- Check governance compliance (should be 100%)
- Measure MTTI/MTTR (should improve)
- Review auto-fix success rate (should increase)

---

## Conclusion

**These core principles are not optional extras.**

They are the foundation that prevents:
- ❌ Malformed JSON paralysis (2025-11-11 incident)
- ❌ Silent failures (context injection failures)
- ❌ Zombie accumulation (32 zombies with no analysis)
- ❌ 30-minute debugging sessions
- ❌ Manual JSON editing errors
- ❌ Security bypasses without audit
- ❌ Configuration drift and chaos

**By implementing this framework, we gain:**
- ✅ Systematic excellence embedded in architecture
- ✅ Self-healing, resilient systems
- ✅ 2-minute debugging instead of 30 minutes
- ✅ Automatic failure prevention and recovery
- ✅ Continuous learning and improvement
- ✅ Developer productivity through automation
- ✅ Compliance and security by default

**The test of success:**
> "Can a new developer write a correct, observable, secure, validated script without reading this document?"

If yes, we've achieved the "pit of success."

---

**Next Steps:**

1. Review this document with team
2. Approve Phase 0 (Foundation)
3. Begin implementation immediately
4. Track progress in PROJECT-STATUS.md
5. Measure improvements weekly

**Questions? Issues?**
- Document: `/Users/ryandahlberg/commit-relay/CORE-PRINCIPLES.md`
- Related: `OBSERVABILITY-STRATEGY.md`, `DAEMON-MANAGEMENT.md`
- Contact: System Architecture Team

---

**Document Version**: 1.0
**Last Updated**: 2025-11-17
**Status**: APPROVED FOR IMPLEMENTATION
