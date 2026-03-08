# Commit-Relay Observability Strategy
## Complete Visibility Across the Agentic Hierarchy

**Status**: Draft Proposal
**Created**: 2025-11-17
**Priority**: CRITICAL

---

## Executive Summary

Commit-relay currently has **partial observability** with critical blind spots that make debugging agent failures extremely difficult. This document proposes a comprehensive observability solution that provides complete visibility across the entire agentic hierarchy.

### Current State
- ❌ No distributed tracing across master→worker→task chains
- ❌ No correlation IDs linking related operations
- ⚠️ Mixed log formats (plain text + JSONL)
- ⚠️ Worker heartbeat mechanism broken
- ⚠️ 32 zombie workers with no failure analysis
- ✅ Basic health monitoring exists
- ✅ Dashboard with metrics snapshots

### Target State
- ✅ Complete request tracing from task creation → completion
- ✅ Unified structured logging with correlation IDs
- ✅ Real-time agent health and progress monitoring
- ✅ Automated failure analysis and categorization
- ✅ Queryable observability data
- ✅ Proactive anomaly detection

---

## Architecture: 3-Layer Observability Model

```
┌─────────────────────────────────────────────────────────────┐
│                    Layer 1: Collection                       │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │ Trace Events │  │ Metric Events│  │  Log Events  │      │
│  │  (Spans)     │  │  (Counters)  │  │  (Structured)│      │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘      │
└─────────┼──────────────────┼──────────────────┼─────────────┘
          │                  │                  │
          └──────────────────┼──────────────────┘
                             ▼
┌─────────────────────────────────────────────────────────────┐
│                    Layer 2: Aggregation                      │
│  ┌──────────────────────────────────────────────────────┐   │
│  │     ObservabilityHub (coordination/observability/)   │   │
│  │  - Unified event stream (observability-stream.jsonl)│   │
│  │  - Correlation index (trace-id → events)            │   │
│  │  - Real-time aggregation and enrichment              │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────┬───────────────────────────────┘
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    Layer 3: Analysis                         │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │   Dashboard  │  │  Query API   │  │  Alerting    │      │
│  │  Visualization│  │  (search)    │  │  (anomaly)   │      │
│  └──────────────┘  └──────────────┘  └──────────────┘      │
└─────────────────────────────────────────────────────────────┘
```

---

## Core Components

### 1. Correlation ID System

Every operation gets a hierarchical trace ID:

```
Format: {trace_id}.{span_id}

Example trace:
task-1234.0           ← Task created
  └─ task-1234.1      ← Coordinator routes to master
       └─ task-1234.2 ← Master spawns worker
            └─ task-1234.3 ← Worker executes
                 └─ task-1234.4 ← Worker reports progress
```

**Implementation:**
- Generate trace_id when task is created
- Propagate via environment variables to all child processes
- Include in ALL log entries, metrics, and events

### 2. Structured Event Schema

**Unified Event Format** (all events use this schema):

```json
{
  "timestamp": "2025-11-17T11:12:44Z",
  "trace_id": "task-1234",
  "span_id": "task-1234.3",
  "parent_span_id": "task-1234.2",
  "event_type": "worker.spawn | worker.progress | worker.complete | worker.fail",
  "severity": "debug | info | warn | error | critical",
  "component": "master | worker | coordinator | daemon",
  "component_id": "development-master | worker-impl-001",
  "actor": "development-master",
  "action": "spawn_worker",
  "target": "worker-implementation-001",
  "status": "success | failure | in_progress",
  "metadata": {
    "task_id": "task-1234",
    "worker_type": "implementation-worker",
    "error_code": "CONTEXT_INJECTION_FAILED",
    "error_message": "Task context returned null fields",
    "duration_ms": 1234,
    "resource_usage": {
      "tokens": 5000,
      "memory_mb": 128
    }
  },
  "context": {
    "hostname": "MacBookAir",
    "pid": 12345,
    "session_id": "session-abc123"
  }
}
```

### 3. Event Collection Points

**Master Agents:**
```bash
# In every master script
source coordination/observability/lib/trace.sh
trace_start "master.task_received" "$TASK_ID"
trace_event "master.routing_decision" "success" '{"routed_to":"development-worker"}'
trace_event "master.worker_spawn" "success" '{"worker_id":"worker-001"}'
trace_end "master.task_received" "success"
```

**Workers:**
```bash
# In worker launcher script
source coordination/observability/lib/trace.sh
trace_start "worker.execution" "$TASK_ID"
trace_event "worker.context_loaded" "$STATUS" "$CONTEXT_JSON"
trace_event "worker.progress" "info" '{"step":"3/5","progress_pct":60}'
trace_end "worker.execution" "$FINAL_STATUS"
```

**Daemons:**
```bash
# In daemon monitoring loops
trace_event "daemon.health_check" "success" '{"workers_alive":10,"zombies":2}'
trace_event "daemon.alert_triggered" "warn" '{"alert_type":"zombie_threshold"}'
```

### 4. ObservabilityHub Service

**New Daemon: `observability-hub-daemon.sh`**

Responsibilities:
1. **Event Ingestion**: Listens to `coordination/observability/events/` directory
2. **Stream Aggregation**: Merges events into unified stream
3. **Correlation**: Builds trace_id → events index
4. **Enrichment**: Adds derived fields (duration, error category, etc.)
5. **Retention**: Rotates logs, compresses old data
6. **Query Interface**: Provides API for searching events

**File Structure:**
```
coordination/observability/
├── events/                        # Event drop-off (inotify watched)
│   ├── master-events.jsonl        # Masters write here
│   ├── worker-events.jsonl        # Workers write here
│   └── daemon-events.jsonl        # Daemons write here
├── stream/                        # Unified stream
│   ├── current.jsonl              # Today's stream
│   └── archive/                   # Compressed archives
│       └── 2025-11-16.jsonl.gz
├── indices/                       # Fast lookups
│   ├── by-trace-id.json           # trace_id → [event_ids]
│   ├── by-worker.json             # worker_id → [event_ids]
│   └── by-error.json              # error_code → [event_ids]
└── lib/                           # Shared libraries
    ├── trace.sh                   # Bash tracing library
    └── trace.js                   # Node.js tracing library
```

### 5. Enhanced Worker Monitoring

**Fix Worker Heartbeat Mechanism:**

```javascript
// In worker execution environment
const heartbeat = setInterval(() => {
  fs.appendFileSync('coordination/observability/events/worker-events.jsonl',
    JSON.stringify({
      timestamp: new Date().toISOString(),
      trace_id: process.env.TRACE_ID,
      span_id: process.env.SPAN_ID,
      event_type: 'worker.heartbeat',
      component: 'worker',
      component_id: process.env.WORKER_ID,
      metadata: {
        progress_pct: getCurrentProgress(),
        tokens_used: getTokensUsed(),
        current_step: getCurrentStep()
      }
    }) + '\n'
  );
}, 30000); // Every 30 seconds
```

**Worker Status Transitions:**

Track ALL state changes:
```
pending → starting → context_loading → executing → completing → completed
                                         ↓
                                      failed
                                         ↓
                                   (capture failure reason)
```

### 6. Failure Analysis System

**Automatic Failure Categorization:**

```javascript
// coordination/observability/lib/failure-analyzer.js
const FAILURE_CATEGORIES = {
  CONTEXT_INJECTION_FAILED: {
    category: 'configuration',
    severity: 'critical',
    auto_fix: 'retry_with_fixed_context',
    runbook: 'docs/runbooks/context-injection-failure.md'
  },
  TIMEOUT_EXCEEDED: {
    category: 'performance',
    severity: 'high',
    auto_fix: 'increase_timeout',
    runbook: 'docs/runbooks/timeout-exceeded.md'
  },
  OUT_OF_MEMORY: {
    category: 'resource',
    severity: 'high',
    auto_fix: 'increase_memory_limit',
    runbook: 'docs/runbooks/out-of-memory.md'
  },
  DEPENDENCY_UNAVAILABLE: {
    category: 'infrastructure',
    severity: 'critical',
    auto_fix: 'restart_dependency',
    runbook: 'docs/runbooks/dependency-unavailable.md'
  }
};

function analyzeFailure(event) {
  const errorCode = event.metadata.error_code;
  const category = FAILURE_CATEGORIES[errorCode];

  // Record categorized failure
  recordFailureMetric(category);

  // Trigger auto-fix if available
  if (category.auto_fix) {
    triggerAutoFix(event, category.auto_fix);
  }

  // Create incident report
  createIncidentReport(event, category);
}
```

### 7. Query Interface

**Observability Query Language (Simple JSON-based):**

```bash
# Find all failures for a task
./scripts/obs-query.sh --trace-id task-1234 --event-type '*.fail'

# Find all worker spawns in last hour
./scripts/obs-query.sh --since 1h --event-type 'worker.spawn'

# Find all errors by error code
./scripts/obs-query.sh --error-code CONTEXT_INJECTION_FAILED

# Get complete trace timeline
./scripts/obs-query.sh --trace-id task-1234 --timeline

# Find slow operations
./scripts/obs-query.sh --duration-gt 5000 --event-type '*.complete'
```

**Example Output:**
```
Trace Timeline for task-1234:
────────────────────────────────────────────────────────────
[11:12:44.123] task.created (coordinator) → task-1234
[11:12:44.456] master.task_received (development-master) → task-1234.1
[11:12:45.789] worker.spawn (development-master) → task-1234.2
[11:12:46.012] worker.starting (worker-001) → task-1234.3
[11:12:46.345] ❌ worker.context_loading (worker-001) → FAILED
              Error: CONTEXT_INJECTION_FAILED
              Message: Task context returned null fields
[11:12:46.678] worker.failed (worker-001) → task-1234.4
[11:12:47.901] task.failed (coordinator) → task-1234.5

Duration: 3.778s | Status: FAILED | Error: CONTEXT_INJECTION_FAILED
Runbook: docs/runbooks/context-injection-failure.md
────────────────────────────────────────────────────────────
```

### 8. Dashboard Integration

**Enhanced Dashboard Views:**

1. **Trace Explorer**
   - Search by trace_id, worker_id, error_code
   - Visual timeline of events
   - Drill-down into individual events

2. **Agent Health Matrix**
   ```
   Master Agents      Workers Active    Success Rate    Avg Duration
   ─────────────────────────────────────────────────────────────────
   development-master      12/15         87.5%          4.2s
   security-master          5/8          100%           2.1s
   inventory-master         3/5          60%            6.8s ⚠️
   cicd-master             8/10          90%            3.5s
   coordinator-master       1/1          100%           0.5s
   ```

3. **Failure Analysis Dashboard**
   - Top 10 error codes
   - Failure trends over time
   - Mean time to recovery (MTTR)
   - Zombie worker investigation tool

4. **Real-time Event Stream**
   - Live tail of events
   - Filter by component, severity, event type
   - Alert highlighting

---

## Implementation Roadmap

### Phase 1: Foundation (Week 1)
**Goal**: Get basic tracing working end-to-end

- [ ] Create `coordination/observability/` directory structure
- [ ] Implement `trace.sh` library for bash scripts
- [ ] Implement `trace.js` library for Node.js
- [ ] Add trace_id generation to task creation
- [ ] Add trace_id propagation to worker spawner
- [ ] Create unified event schema

**Validation**: Single task traces from creation → completion

### Phase 2: Collection (Week 2)
**Goal**: Instrument all components

- [ ] Add tracing to all 5 master agents
- [ ] Fix worker heartbeat mechanism
- [ ] Add tracing to worker launcher
- [ ] Add tracing to coordinator daemon
- [ ] Add tracing to health monitor daemon

**Validation**: All events flowing to event files

### Phase 3: Aggregation (Week 3)
**Goal**: Build ObservabilityHub daemon

- [ ] Create `observability-hub-daemon.sh`
- [ ] Implement event ingestion (inotify)
- [ ] Implement stream aggregation
- [ ] Build correlation indices
- [ ] Add log rotation and compression

**Validation**: Unified stream contains all events with indices

### Phase 4: Analysis (Week 4)
**Goal**: Make data queryable and actionable

- [ ] Create `obs-query.sh` CLI tool
- [ ] Implement failure analyzer
- [ ] Create runbooks for common failures
- [ ] Build auto-fix framework
- [ ] Add anomaly detection

**Validation**: Can query any trace, identify failure root cause

### Phase 5: Visualization (Week 5)
**Goal**: Dashboard integration

- [ ] Add Trace Explorer to dashboard
- [ ] Add Agent Health Matrix
- [ ] Add Failure Analysis view
- [ ] Add Real-time Event Stream
- [ ] Add alerting integration

**Validation**: Dashboard shows complete system observability

### Phase 6: Optimization (Week 6)
**Goal**: Performance and cleanup

- [ ] Optimize event ingestion performance
- [ ] Add event sampling for high-volume components
- [ ] Implement retention policies
- [ ] Add metrics export (Prometheus format)
- [ ] Performance tuning

**Validation**: System handles 1000+ events/minute

---

## Immediate Quick Wins

These can be implemented TODAY to gain immediate visibility:

### 1. Add Trace IDs to Existing Logs (30 minutes)

```bash
# In task creation
TRACE_ID="task-$(date +%s)-$(uuidgen | cut -d'-' -f1)"
echo "$TRACE_ID" > coordination/tasks/$TASK_ID.trace

# In worker spawner
TRACE_ID=$(cat coordination/tasks/$TASK_ID.trace 2>/dev/null || echo "unknown")
export TRACE_ID
```

### 2. Create Simple Event Logger (1 hour)

```bash
# coordination/observability/lib/trace.sh
trace_event() {
  local event_type="$1"
  local status="$2"
  local metadata="$3"

  echo "{\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"trace_id\":\"${TRACE_ID:-unknown}\",\"event_type\":\"$event_type\",\"status\":\"$status\",\"metadata\":$metadata}" \
    >> coordination/observability/events/all-events.jsonl
}
```

### 3. Simple Query Script (1 hour)

```bash
#!/bin/bash
# scripts/obs-query.sh
TRACE_ID="$1"
jq -r "select(.trace_id == \"$TRACE_ID\") | [.timestamp, .event_type, .status] | @tsv" \
  coordination/observability/events/all-events.jsonl | sort
```

### 4. Worker Failure Analyzer (2 hours)

```bash
# Scan worker logs for failures
./scripts/analyze-worker-failures.sh

# Output:
# worker-001: CONTEXT_INJECTION_FAILED (2025-11-14T12:50:17Z)
# worker-002: TIMEOUT_EXCEEDED (2025-11-14T13:15:22Z)
# worker-003: OUT_OF_MEMORY (2025-11-14T14:20:45Z)
```

---

## Success Metrics

### Observability Coverage
- [ ] 100% of task executions have trace_id
- [ ] 100% of worker spawns emit events
- [ ] 100% of failures have categorized error codes
- [ ] 95% of workers send heartbeats

### Debugging Efficiency
- [ ] Mean time to identify (MTTI) root cause: < 5 minutes
- [ ] Mean time to resolution (MTTR): < 30 minutes
- [ ] 90% of failures have automated runbooks
- [ ] 50% of failures have auto-fix capabilities

### System Health
- [ ] Zero zombie workers without failure analysis
- [ ] Zero silent failures (all failures logged and categorized)
- [ ] 100% uptime for ObservabilityHub daemon
- [ ] Query response time: < 1 second for any trace

---

## Example: Debugging Worker Failure

**Before (Current State):**
```
1. Check worker-pool.json → see "pending" status
2. Check worker logs → see "Unknown task"
3. Manually grep task-queue.json for task details
4. Manually compare task spec vs worker context
5. Guess at root cause: "context injection failed?"
6. No automated fix, manual intervention required
Time to debug: 30+ minutes
```

**After (With Observability):**
```
1. Run: obs-query.sh --worker-id worker-001 --timeline
2. See trace:
   [11:12:46.345] ❌ worker.context_loading FAILED
   Error: CONTEXT_INJECTION_FAILED
   Runbook: docs/runbooks/context-injection-failure.md
3. Click runbook link
4. Run suggested fix: scripts/fix-context-injection.sh worker-001
5. Worker auto-retries with fixed context
Time to debug: 2 minutes (automated)
```

---

## Security Considerations

- **Log Sanitization**: Automatically redact sensitive data (API keys, passwords)
- **Access Control**: Observability data requires authentication
- **Retention**: Compliance with data retention policies (30-day default)
- **PII Detection**: Flag and mask PII in trace data
- **Audit Trail**: All queries logged for security audit

---

## Cost Analysis

### Storage (30-day retention)
- Events: ~10k/day × 1KB = 10MB/day × 30 = 300MB
- Compressed archives: ~30MB
- Indices: ~50MB
- **Total**: ~380MB (negligible)

### Compute (ObservabilityHub daemon)
- CPU: ~1-2% average
- Memory: ~50MB
- **Total**: Minimal overhead

### Development Time
- Phase 1-6: ~6 weeks (1 engineer)
- Immediate quick wins: 4-5 hours

### ROI
- Current debugging time: 30 min/failure × 50 failures/month = 25 hours/month
- New debugging time: 2 min/failure × 50 failures/month = 1.7 hours/month
- **Time saved**: 23.3 hours/month per engineer

---

## Next Steps

1. **Review this proposal** with team
2. **Approve Phase 1** (Foundation)
3. **Implement quick wins** (today)
4. **Start Phase 1 development** (this week)
5. **Iterate and refine** based on real-world usage

---

## Appendix

### A. Related Documents
- `DAEMON-MANAGEMENT.md` - Daemon supervision strategy
- `coordination/governance/` - Data governance framework
- `coordination/lineage-log.jsonl` - Existing lineage tracking

### B. Alternative Approaches Considered

**Option 1: Use External APM (Datadog, New Relic)**
- ❌ Cost: $500-2000/month
- ❌ External dependency
- ✅ Full-featured
- **Verdict**: Overkill for current scale

**Option 2: OpenTelemetry + Jaeger**
- ✅ Industry standard
- ❌ Complex setup (requires containers, databases)
- ❌ Overhead for bash-based scripts
- **Verdict**: Too heavyweight for file-based system

**Option 3: Custom File-Based (Proposed)**
- ✅ Zero external dependencies
- ✅ Works with existing bash/Node.js architecture
- ✅ Lightweight and fast
- ✅ Easy to query and extend
- **Verdict**: Best fit for commit-relay ✓

### C. Glossary

- **Trace ID**: Unique identifier for a complete operation (task creation → completion)
- **Span ID**: Unique identifier for a single step within a trace
- **Event**: A point-in-time occurrence with metadata
- **Correlation**: Linking related events via trace_id
- **Observability Hub**: Central aggregation and indexing service
- **MTTI**: Mean Time To Identify (root cause)
- **MTTR**: Mean Time To Resolution (fix deployed)

---

**Document Version**: 1.0
**Last Updated**: 2025-11-17
**Author**: Claude (Commit-Relay Analysis)
**Status**: Awaiting Approval
