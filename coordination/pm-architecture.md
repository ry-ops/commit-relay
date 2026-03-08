# Project Manager (PM) Agent Architecture

Version: 1.0
Date: 2025-11-06
Status: Design Phase

---

## Executive Summary

The Project Manager (PM) Agent is a critical system component designed to bridge the gap between Coordinator Master and Worker agents, addressing the current 26.8% worker success rate crisis. The PM provides active monitoring, progress tracking, two-way communication, and early intervention to ensure workers complete their assigned tasks reliably.

### Current Crisis

- **Success Rate**: 26.8% (11/41 workers completed)
- **Target**: 75% minimum success rate
- **Primary Issue**: Workers start but don't execute, running as zombies for 19-23 hours
- **Root Causes**:
  - No progress monitoring
  - No communication protocol
  - No timeout enforcement (60 min limit ignored)
  - No failure diagnostics
  - Workers marked "running" but no actual execution

### Solution Overview

The PM system implements a daemon-based monitoring architecture with:
- Active worker health monitoring (check-ins every 5-10 minutes)
- Early stall detection (within 15 minutes)
- Two-way communication protocol (workers can request help)
- Timeout enforcement (60-minute limits respected)
- Intervention system (auto-restart stalled workers)
- Comprehensive logging and metrics

---

## 1. System Architecture

### 1.1 Core Design Principles

**Daemon-Based Architecture**
- PM runs as a persistent background process
- Continuous monitoring loop (every 2-3 minutes)
- Handles 16+ concurrent workers efficiently
- Low resource overhead (< 10 MB memory, < 1% CPU)

**Defense in Depth**
- Multiple detection mechanisms (check-ins, timeouts, process monitoring)
- Graceful degradation (PM failure doesn't crash workers)
- Redundant state tracking (file-based + process-based)

**Observable Operations**
- All actions logged to coordination/pm-activity.jsonl
- Real-time metrics fed to dashboard
- Audit trail for debugging and analysis

**Minimal Worker Disruption**
- Check-ins are non-blocking background writes
- Workers control their own check-in frequency
- No forced interruptions during execution

### 1.2 Component Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                     Coordinator Master                          │
│                 (Task Assignment & Routing)                     │
└─────────────────────┬───────────────────────────────────────────┘
                      │
                      │ Creates worker spec
                      ↓
┌─────────────────────────────────────────────────────────────────┐
│                  Worker Daemon (Launcher)                       │
│         Spawns workers from pending specs                       │
└─────────────────────┬───────────────────────────────────────────┘
                      │
                      │ Launches worker
                      ↓
┌─────────────────────────────────────────────────────────────────┐
│                   Worker Process (Claude)                       │
│                   ┌─────────────────────┐                       │
│                   │   Task Execution    │                       │
│                   │   ┌──────────────┐  │                       │
│                   │   │ Check-in     │  │────┐                  │
│                   │   │ Helper       │  │    │                  │
│                   │   └──────────────┘  │    │                  │
│                   └─────────────────────┘    │                  │
└──────────────────────────────────────────────┼──────────────────┘
                                               │
                                               │ Writes check-in
                                               ↓
┌─────────────────────────────────────────────────────────────────┐
│              coordination/worker-checkins/                      │
│         {worker-id}-{timestamp}.json (check-in files)           │
└─────────────────────┬───────────────────────────────────────────┘
                      │
                      │ Monitored by
                      ↓
┌─────────────────────────────────────────────────────────────────┐
│                   PM Daemon (Monitor)                           │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  Main Loop (every 2-3 minutes)                           │  │
│  │  • Scan for new workers                                  │  │
│  │  • Check for missed check-ins                            │  │
│  │  • Enforce timeouts                                      │  │
│  │  • Detect stalled workers                                │  │
│  │  • Process worker requests                               │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                 │
│  Intervention Actions:                                          │
│  • Send warnings (50%, 75%, 90% of time limit)                 │
│  • Escalate to master (no check-in for 15+ min)               │
│  • Kill and restart (stalled > 20 min)                         │
│  • Extend timeouts (approved requests)                         │
│  • Update dashboard metrics                                    │
└─────────────────────┬───────────────────────────────────────────┘
                      │
                      │ Logs to
                      ↓
┌─────────────────────────────────────────────────────────────────┐
│               coordination/pm-activity.jsonl                    │
│                  (PM event audit log)                           │
└─────────────────────────────────────────────────────────────────┘
                      │
                      │ Feeds data to
                      ↓
┌─────────────────────────────────────────────────────────────────┐
│                    Dashboard (UI & WebSocket)                   │
│              Real-time PM metrics and worker health             │
└─────────────────────────────────────────────────────────────────┘
```

### 1.3 File System Layout

```
commit-relay/
├── coordination/
│   ├── worker-checkins/              # NEW: Worker check-in files
│   │   ├── dev-worker-ABC123-20251106T120000Z.json
│   │   ├── dev-worker-ABC123-20251106T120500Z.json
│   │   └── sec-worker-XYZ789-20251106T120300Z.json
│   │
│   ├── pm-requests/                  # NEW: Worker → PM requests
│   │   ├── pending/                  # Awaiting PM processing
│   │   │   └── req-1234567890.json
│   │   └── processed/                # Completed requests
│   │       └── req-1234567891.json
│   │
│   ├── pm-alerts/                    # NEW: PM → Master alerts
│   │   ├── pending/                  # Awaiting master attention
│   │   │   └── alert-worker-ABC123-stalled.json
│   │   └── resolved/                 # Handled alerts
│   │       └── alert-worker-ABC123-stalled.json
│   │
│   ├── pm-activity.jsonl             # NEW: PM event log (append-only)
│   ├── pm-state.json                 # NEW: PM daemon state
│   │
│   └── worker-specs/                 # EXISTING: Worker specs
│       ├── active/                   # Workers currently running
│       ├── completed/                # Successfully finished
│       └── failed/                   # Failed workers
│
├── scripts/
│   ├── pm-daemon.sh                  # NEW: PM monitoring daemon
│   ├── worker-checkin.sh             # NEW: Helper for worker check-ins
│   ├── pm-intervention.sh            # NEW: Intervention actions
│   └── worker-daemon.sh              # EXISTING: Worker launcher
│
└── agents/
    └── prompts/workers/
        ├── CHECKIN-INSTRUCTIONS.md   # NEW: How to use check-ins
        ├── implementation-worker.md  # UPDATE: Add check-in calls
        ├── analysis-worker.md        # UPDATE: Add check-in calls
        └── ...                       # UPDATE: All worker types
```

---

## 2. Worker Communication Protocol

### 2.1 Check-In Mechanism

**How It Works**:
1. Worker executes task as normal (no interruption)
2. At natural breakpoints (every 5-10 minutes), worker calls check-in helper
3. Check-in helper writes small JSON file to coordination/worker-checkins/
4. PM daemon periodically scans for new check-in files
5. PM updates worker health status and takes action if needed

**When to Check In**:
- **Required**: Task start (within 5 minutes of launch)
- **Required**: Task completion (success or failure)
- **Recommended**: Every 5-10 minutes during execution
- **Optional**: Before major steps (design → implementation → testing)
- **Optional**: When requesting help or time extensions

**Check-In Helper Usage**:
```bash
# In worker prompt/script
source $COMMIT_RELAY_HOME/scripts/worker-checkin.sh

# Quick check-in (minimal data)
worker_checkin "in_progress" 30

# Detailed check-in
worker_checkin "in_progress" 45 \
  --current-step "Writing tests for authentication module" \
  --next-step "Running test suite" \
  --time-remaining "15 minutes"

# Check-in with issue
worker_checkin "blocked" 60 \
  --issue "Cannot access database schema documentation" \
  --request "need_clarification"

# Completion check-in
worker_checkin "completed" 100 \
  --deliverables "PR #123, updated docs, passing tests"
```

### 2.2 Request Types

Workers can request help via the PM system:

**1. need_clarification**
- Task requirements unclear
- Ambiguous acceptance criteria
- Conflicting instructions
- PM forwards to master for guidance

**2. need_time**
- Task taking longer than expected
- Request time extension (e.g., +30 minutes)
- Must provide justification
- PM evaluates and approves/denies

**3. need_resources**
- Token budget exhausted
- Need access to additional files
- Missing dependencies
- PM coordinates with master for resource allocation

**4. blocked**
- External dependency not available
- Blocker outside worker's control
- Waiting on another system
- PM escalates to master immediately

**5. need_help**
- Technical difficulty
- Stuck on implementation problem
- Need expert consultation
- PM routes to appropriate master/specialist

### 2.3 Check-In Data Format

See `coordination/pm-data-formats.md` for complete schemas.

**Minimal Check-In** (fast, low overhead):
```json
{
  "worker_id": "dev-worker-ABC123",
  "timestamp": "2025-11-06T12:00:00Z",
  "status": "in_progress",
  "progress_pct": 30
}
```

**Full Check-In** (detailed progress):
```json
{
  "worker_id": "dev-worker-ABC123",
  "timestamp": "2025-11-06T12:00:00Z",
  "status": "in_progress",
  "progress_pct": 30,
  "current_step": "Implementing authentication logic",
  "next_step": "Writing unit tests",
  "time_remaining_estimate": "20 minutes",
  "token_usage": 3500,
  "issues": [],
  "requests": [],
  "metrics": {
    "files_modified": 3,
    "tests_written": 5,
    "tests_passing": 5
  }
}
```

---

## 3. PM Daemon Architecture

### 3.1 Daemon Lifecycle

**Startup**:
1. Load PM state from coordination/pm-state.json
2. Scan for active workers in coordination/worker-specs/active/
3. Register existing workers for monitoring
4. Initialize check-in tracking
5. Start main monitoring loop

**Main Loop** (every 2-3 minutes):
1. **Worker Registration**: Detect new workers, expect first check-in
2. **Check-In Monitoring**: Process new check-in files
3. **Timeout Enforcement**: Check workers against time limits
4. **Stall Detection**: Identify workers with no recent check-ins
5. **Request Processing**: Handle worker help requests
6. **Intervention Execution**: Take corrective actions
7. **Metrics Update**: Feed data to dashboard
8. **State Persistence**: Save PM state to disk

**Shutdown**:
1. Log shutdown event
2. Save final PM state
3. Do NOT kill active workers (continue monitoring on restart)

### 3.2 Worker Health States

PM tracks each worker in one of these states:

**HEALTHY**: Check-ins on schedule, progressing normally
- Last check-in < 15 minutes ago
- Progress increasing over time
- No issues reported
- Within time limit

**LATE**: Missed check-in window but not yet critical
- Last check-in 15-20 minutes ago
- PM sends reminder (soft warning)
- Continue monitoring closely

**STALLED**: No progress or missed multiple check-ins
- Last check-in > 20 minutes ago, OR
- Progress stuck at same % for 30+ minutes
- PM escalates to master
- Prepare for intervention

**TIMEOUT_WARNING**: Approaching time limit
- Used 50% of time limit → First warning
- Used 75% of time limit → Second warning
- Used 90% of time limit → Final warning
- Used 110% of time limit → Force termination

**ZOMBIE**: Running but not executing
- Process exists but no check-ins ever received, OR
- Marked "running" in spec but no active process
- PM kills process and marks as failed

**COMPLETED**: Task finished successfully
- Worker reported "completed" status
- Deliverables validated
- Moved to worker-specs/completed/

**FAILED**: Task failed or was terminated
- Worker reported "failed" status, OR
- Killed by PM due to stall/timeout
- Moved to worker-specs/failed/

### 3.3 Intervention Actions

PM can take these actions:

**1. Send Warning**
- Write alert to worker's check-in directory
- Worker sees warning on next check-in
- Used for: timeout warnings, gentle nudges

**2. Escalate to Master**
- Create alert in coordination/pm-alerts/pending/
- Master picks up alert and decides action
- Used for: clarification requests, stalled workers

**3. Request Help on Behalf of Worker**
- Worker reported issue but didn't request help
- PM interprets situation and creates request
- Used for: workers stuck but not self-aware

**4. Extend Time Limit**
- Worker requested more time with good reason
- PM approves extension (e.g., +30 minutes)
- Update worker spec with new time_limit_minutes

**5. Kill and Restart**
- Worker clearly stalled with no recovery
- PM kills process, marks spec as "failed"
- Optionally: spawn replacement worker
- Used for: zombie workers, infinite loops

**6. Allocate Additional Resources**
- Worker needs more tokens or access
- PM coordinates with master to provide resources
- Update worker spec with new allocations

---

## 4. State Management

### 4.1 PM State File

`coordination/pm-state.json`:
```json
{
  "pm_daemon": {
    "pid": 12345,
    "started_at": "2025-11-06T10:00:00Z",
    "last_loop": "2025-11-06T12:00:00Z",
    "loops_completed": 240,
    "version": "1.0.0"
  },
  "monitored_workers": {
    "dev-worker-ABC123": {
      "registered_at": "2025-11-06T11:00:00Z",
      "last_checkin": "2025-11-06T11:55:00Z",
      "checkin_count": 12,
      "health_state": "healthy",
      "time_limit_at": "2025-11-06T12:00:00Z",
      "warnings_sent": 0,
      "interventions": []
    }
  },
  "metrics": {
    "total_workers_monitored": 16,
    "healthy_count": 12,
    "stalled_count": 2,
    "late_count": 2,
    "completed_today": 8,
    "failed_today": 3,
    "interventions_today": 5,
    "success_rate": 72.7
  }
}
```

### 4.2 Check-In File Lifecycle

1. **Creation**: Worker writes check-in to coordination/worker-checkins/
2. **Detection**: PM daemon scans directory (every 2-3 minutes)
3. **Processing**: PM reads file, updates worker health state
4. **Archival**: After processing, file can be deleted or moved
5. **Retention**: Keep last 24 hours for debugging (optional)

**File Naming Convention**:
```
{worker-id}-{timestamp}.json

Examples:
dev-worker-ABC123-20251106T120000Z.json
sec-worker-XYZ789-20251106T120530Z.json
```

**Why This Design**:
- File-based: Simple, no database needed, survives restarts
- Timestamped: Natural ordering, easy to find latest
- Worker-prefixed: Easy to find all check-ins for one worker
- Small files: Fast to write (workers) and read (PM)
- Append-only: No file locking issues

---

## 5. Integration Points

### 5.1 Worker Daemon Integration

**Current Behavior**:
- Worker daemon spawns workers from pending specs
- Marks worker as "running" immediately
- No further tracking

**New Behavior with PM**:
- Worker daemon spawns worker (unchanged)
- Marks worker as "running" (unchanged)
- PM daemon detects new worker automatically
- PM expects first check-in within 5 minutes
- If no check-in, PM escalates to master

**No Changes Required**: Worker daemon and PM are decoupled.

### 5.2 Worker Prompt Integration

**Changes Required**:
Workers must be updated to call check-in helper at key points.

**Example for implementation-worker.md**:

```markdown
### 1. Initialize (2-3 minutes)

# Read worker spec and set up environment
...

# REQUIRED: Check in to confirm task received
source $COMMIT_RELAY_HOME/scripts/worker-checkin.sh
worker_checkin "in_progress" 5 \
  --current-step "Initialized environment, read task spec" \
  --next-step "Planning implementation approach"

### 2. Design & Plan (3-5 minutes)

# Plan implementation approach
...

# RECOMMENDED: Check in after planning
worker_checkin "in_progress" 15 \
  --current-step "Completed design, ready to implement" \
  --next-step "Writing core implementation"

### 3. Implement Component (25-35 minutes)

# Build the feature
...

# RECOMMENDED: Check in every 10 minutes during implementation
worker_checkin "in_progress" 40 \
  --current-step "Implementing feature logic" \
  --next-step "Writing tests"

### 4. Test & Validate (5-10 minutes)

# Run tests
...

# RECOMMENDED: Check in after tests
worker_checkin "in_progress" 85 \
  --current-step "Tests passing, preparing deliverables" \
  --next-step "Creating PR and final documentation"

### 5. Deliver (2-3 minutes)

# Create PR, update docs
...

# REQUIRED: Final check-in on completion
worker_checkin "completed" 100 \
  --deliverables "PR #123 created, tests passing, docs updated"
```

See `agents/prompts/workers/CHECKIN-INSTRUCTIONS.md` for full guide.

### 5.3 Dashboard Integration

**New PM Metrics Panel**:
- Workers monitored: 16 active
- Health distribution: 12 healthy, 2 late, 2 stalled
- Success rate (24h): 72.7%
- Avg completion time: 42 minutes
- Active interventions: 1 escalation, 1 timeout warning

**Worker Status Enhancements**:
- Show last check-in timestamp
- Display current progress percentage
- Show current step description
- Indicate health state (color-coded badge)
- Show time remaining vs time limit

**PM Activity Feed**:
- Live feed of PM interventions
- Worker check-ins (aggregated)
- Alerts and escalations
- Completions and failures

**Data Source**: coordination/pm-activity.jsonl

---

## 6. Failure Modes & Recovery

### 6.1 PM Daemon Failure

**Scenario**: PM daemon crashes or is killed.

**Detection**:
- PM PID file exists but process not running
- Last PM loop timestamp > 10 minutes old
- Dashboard shows "PM Offline" alert

**Recovery**:
1. Restart PM daemon automatically (systemd/launchd)
2. PM loads state from coordination/pm-state.json
3. Re-register all active workers
4. Resume monitoring from last known state
5. Send "PM restarted" event to dashboard

**Worker Impact**: Workers continue executing normally (no disruption).

### 6.2 Worker Fails to Check In

**Scenario**: Worker is running but doesn't call check-in helper.

**Detection**:
- No check-in received within 15 minutes of worker start
- Worker spec shows "running" but no check-in files

**PM Actions**:
1. 15 min: Log "missing_checkin" event
2. 20 min: Escalate to master (alert: worker not checking in)
3. 30 min: Mark as stalled, prepare for intervention
4. 40 min: Kill worker, mark as failed with reason: "No check-ins received"

**Root Cause**: Worker prompt missing check-in calls (fix prompt template).

### 6.3 Worker Stalls Mid-Execution

**Scenario**: Worker checked in initially but stopped progressing.

**Detection**:
- Last check-in > 20 minutes ago, OR
- Progress stuck at same percentage for 30+ minutes, OR
- Worker reports "blocked" status

**PM Actions**:
1. 20 min: Log "worker_stalled" event
2. 22 min: Escalate to master (alert: worker may need help)
3. 25 min: If no master response, attempt automatic restart
4. 30 min: Kill and restart if clearly unrecoverable

**Worker Impact**: Killed gracefully, new worker may be spawned with same task.

### 6.4 PM Falls Behind

**Scenario**: PM daemon can't keep up with worker volume (> 50 workers).

**Detection**:
- PM loop taking > 5 minutes to complete
- Check-in files accumulating faster than processed
- PM metrics show increasing lag

**PM Actions**:
1. Log "pm_overloaded" event
2. Increase loop priority (process only critical checks)
3. Batch process check-in files
4. Alert coordinator to reduce worker spawn rate
5. Scale horizontally (spawn additional PM daemons per stream)

**Long-term Fix**: Optimize PM loop, parallel processing, or shard workers across multiple PMs.

### 6.5 Race Conditions

**Scenario 1**: Worker completes as PM decides to kill it.

**Solution**:
- PM checks worker status immediately before kill
- If status changed to "completed", abort kill
- Log near-miss event for analysis

**Scenario 2**: Multiple check-ins written simultaneously.

**Solution**:
- Timestamped filenames prevent overwrites
- PM processes all check-in files in chronological order
- Latest check-in wins for worker state

**Scenario 3**: Worker and PM both update worker spec.

**Solution**:
- Workers only write check-in files (never modify spec)
- PM owns worker spec updates (execution.* fields)
- Clear separation of responsibilities

---

## 7. Performance & Scalability

### 7.1 Resource Requirements

**PM Daemon**:
- Memory: < 10 MB baseline, +100 KB per monitored worker
- CPU: < 1% during normal operation, < 5% during interventions
- Disk I/O: Minimal (small JSON files, append-only log)
- Network: None (local file system only)

**Worker Check-In Overhead**:
- Time: < 100ms per check-in call
- File Size: 200-500 bytes per check-in
- Disk Space: ~10 KB per worker per hour (assuming 10 min intervals)
- Impact: Negligible (workers spend 99%+ on actual work)

### 7.2 Scalability Limits

**Single PM Daemon**:
- Handles up to 50-100 concurrent workers comfortably
- Beyond that, consider sharding by workforce stream

**Check-In Volume**:
- 100 workers × 6 check-ins/hour = 600 files/hour
- Over 24h: 14,400 files (~7 MB)
- Rotate/archive older than 24h to prevent buildup

**Intervention Latency**:
- Detection: 2-3 minutes (PM loop interval)
- Escalation: < 30 seconds (file write + master poll)
- Kill & Restart: < 10 seconds

### 7.3 Optimization Opportunities

**Phase 1** (Current Design):
- Sequential processing (simple, reliable)
- File-based state (no dependencies)
- Human-readable logs (easy debugging)

**Phase 2** (If Needed):
- Parallel check-in processing (faster for high volume)
- SQLite for worker state (faster queries)
- Aggregated metrics (reduce log size)

**Phase 3** (Future):
- Multiple PM daemons per workforce stream
- Real-time WebSocket to dashboard (no file polling)
- Predictive stall detection (ML-based patterns)

---

## 8. Security Considerations

### 8.1 File System Security

**Check-In Directory**:
- Location: coordination/worker-checkins/ (inside project)
- Permissions: Writable by workers, readable by PM
- Validation: PM validates JSON schema, rejects malformed files
- Sanitization: Worker IDs must match [a-z0-9-]+ pattern

**Worker Specs**:
- PM has read-only access (workers can't modify their own specs)
- Only PM and masters can update worker status
- All changes logged to pm-activity.jsonl

### 8.2 Request Validation

**Worker Requests**:
- Schema validated before processing
- Time extension requests capped at +60 minutes
- Resource requests limited by master budget
- Clarification requests require valid master agent

**Injection Prevention**:
- No shell command execution from worker data
- All file paths validated and canonicalized
- Worker IDs and task IDs are UUIDs (no special chars)

### 8.3 Denial of Service Prevention

**Check-In Flood**:
- PM ignores duplicate check-ins within 1 minute
- Max 20 check-ins per worker per hour
- Excessive check-ins logged as anomaly

**Request Spam**:
- Workers limited to 5 active requests at once
- Duplicate requests ignored
- Excessive requests trigger stall investigation

---

## 9. Migration Strategy

### 9.1 Existing Workers

**Current State**: 16 active workers (likely stuck/zombie)

**Migration Plan**:
1. **DO NOT** kill existing workers immediately
2. Deploy PM daemon in monitoring mode (log only, no interventions)
3. Run for 1 hour to establish baseline
4. Identify truly stuck workers (no check-ins, no progress)
5. Kill stuck workers in batches (5 at a time)
6. Enable PM intervention mode
7. Monitor new workers with PM from day 1

### 9.2 Backward Compatibility

**Workers Without Check-Ins**:
- PM detects workers spawned before PM deployment
- Monitors based on timeout only (60 min hard limit)
- Does NOT expect check-ins from legacy workers
- Gradually migrate to new check-in-enabled prompts

**Worker Prompt Updates**:
- Phase 1: Update implementation-worker.md (highest volume)
- Phase 2: Update analysis-worker.md, test-worker.md
- Phase 3: Update all remaining worker types
- Timeline: 1-2 weeks for full migration

### 9.3 Rollback Plan

**If PM Causes Issues**:
1. Stop PM daemon (kill process)
2. Workers continue executing normally
3. Worker daemon continues spawning workers
4. System reverts to pre-PM behavior
5. No data loss (all state in files)

**Rollback Trigger**:
- PM daemon crashing repeatedly (> 3 times/hour)
- Worker success rate drops below 25% (worse than baseline)
- Masters report excessive false-positive alerts

---

## 10. Key Architectural Decisions

### Q1: Daemon vs Agent?

**Decision**: Daemon (continuous background process)

**Rationale**:
- Monitoring requires continuous operation (24/7)
- Agents are ephemeral, spawn for tasks then exit
- Need persistent state across multiple worker batches
- Simpler to manage one long-running process vs many short-lived

**Alternative Considered**: Spawn PM agent per task batch
- **Rejected**: Would need complex coordination between PM instances

### Q2: Check-In Frequency?

**Decision**: Worker-controlled, recommended every 5-10 minutes

**Rationale**:
- Workers know their own natural breakpoints
- Forced intervals would interrupt work
- 5-10 min balances detection speed vs overhead
- Flexibility for fast tasks (check in less) vs slow tasks (more frequent)

**Alternative Considered**: Fixed 2-minute intervals
- **Rejected**: Too intrusive, high overhead for simple tasks

### Q3: File-Based vs Database?

**Decision**: File-based (JSON/JSONL) for Phase 1

**Rationale**:
- Simple to implement (no dependencies)
- Easy to debug (cat, jq, grep)
- Survives restarts (persistent)
- Handles expected load (< 100 workers)
- Can migrate to DB later if needed

**Alternative Considered**: SQLite or Postgres
- **Rejected** for Phase 1: Over-engineering, adds complexity
- **Revisit** in Phase 3 if scale demands it

### Q4: Handle 16 Active Workers?

**Decision**: PM monitors ALL active workers (existing + new)

**Rationale**:
- Need visibility into all workers, not just new ones
- Existing workers likely stuck, need intervention
- PM can identify and clean up zombies
- Gradual migration (don't break existing system)

**Implementation**:
- PM scans worker-specs/active/ on startup
- Registers existing workers as "legacy" (no check-ins expected)
- Monitors timeout only for legacy workers
- Full monitoring for new workers (check-ins required)

### Q5: PM Failure Handling?

**Decision**: Workers are independent, continue if PM fails

**Rationale**:
- PM is observer/helper, not controller
- Workers should complete successfully even without PM
- PM enhances reliability but isn't required
- Graceful degradation (better than crashing)

**Safety Net**: Worker daemon hard-kills zombies after 23 hours (unchanged).

### Q6: Migration Path?

**Decision**: Phased rollout over 1-2 weeks

**Rationale**:
- Avoid big-bang deployment (high risk)
- Validate each phase before proceeding
- Allow time to fix issues
- Minimize disruption to ongoing work

**Phases**:
1. **Phase 1** (Days 1-3): Deploy PM daemon, monitoring only
2. **Phase 2** (Days 4-7): Enable interventions, update first worker type
3. **Phase 3** (Days 8-14): Migrate all worker types, full automation

---

## 11. Success Criteria

### Functional Requirements

- PM daemon runs continuously for 24+ hours without crashes
- PM monitors 16+ concurrent workers without performance degradation
- Workers can check in within 100ms (no noticeable delay)
- Stalled workers detected within 15 minutes
- Timeouts enforced within 5 minutes of limit exceeded
- All PM actions logged to pm-activity.jsonl
- Dashboard displays real-time PM metrics

### Success Metrics

**Primary Goal**: Increase worker success rate from 26.8% to 75%+

**Secondary Goals**:
- 95%+ of workers check in at least once
- 90%+ of timeouts enforced correctly
- 80%+ of stalls detected within 15 minutes
- 100% of completions/failures logged
- 0 false-positive kills (worker marked failed but actually working)

**Operational Metrics**:
- PM uptime: 99%+ (< 15 min downtime/day)
- Intervention latency: < 5 minutes (detection to action)
- Check-in overhead: < 1% of worker execution time
- Resource usage: < 10 MB memory, < 1% CPU

---

## 12. Next Steps

### Immediate (This Session)

1. Create coordination/pm-data-formats.md (data schemas)
2. Create docs/PM-IMPLEMENTATION-PLAN.md (phased timeline)
3. Create scripts/pm-daemon.sh (monitoring loop)
4. Create scripts/worker-checkin.sh (helper function)
5. Create scripts/pm-intervention.sh (action library)
6. Create agents/prompts/workers/CHECKIN-INSTRUCTIONS.md
7. Create docs/PM-TESTING-PLAN.md
8. Create docs/PM-DASHBOARD-INTEGRATION.md

### Phase 1: Core Infrastructure (Days 1-3)

1. Implement pm-daemon.sh (basic monitoring)
2. Implement worker-checkin.sh (basic check-ins)
3. Test with 1-2 workers
4. Deploy in monitoring mode (no interventions)
5. Validate PM can track workers accurately

### Phase 2: Communication Protocol (Days 4-7)

1. Implement pm-intervention.sh (actions)
2. Enable timeout enforcement
3. Enable stall detection
4. Update implementation-worker.md (add check-ins)
5. Test with 5-10 workers
6. Validate interventions working correctly

### Phase 3: Full Deployment (Days 8-14)

1. Update all worker prompt templates
2. Enable all intervention types
3. Deploy to production (all workers)
4. Monitor success rate improvement
5. Tune parameters (check-in frequency, timeouts)
6. Document lessons learned

---

## Appendix A: Terminology

- **Worker**: Ephemeral Claude agent executing a specific task
- **PM Daemon**: Continuous background process monitoring workers
- **Check-In**: Worker status update written to file system
- **Intervention**: PM action taken on behalf of stalled/stuck worker
- **Stall**: Worker not making progress (no check-ins or progress)
- **Zombie**: Worker marked "running" but not actually executing
- **Timeout**: Worker exceeds time_limit_minutes threshold
- **Escalation**: PM alerts master agent about worker issue
- **Health State**: PM's assessment of worker status (healthy, late, stalled, etc.)

## Appendix B: File Locations

All paths relative to commit-relay project root:

```
coordination/pm-architecture.md              # This document
coordination/pm-data-formats.md              # JSON/JSONL schemas
coordination/pm-state.json                   # PM daemon state
coordination/pm-activity.jsonl               # PM event log
coordination/worker-checkins/                # Check-in files
coordination/pm-requests/                    # Worker requests
coordination/pm-alerts/                      # PM alerts to masters

scripts/pm-daemon.sh                         # PM monitoring daemon
scripts/worker-checkin.sh                    # Check-in helper
scripts/pm-intervention.sh                   # Intervention actions

agents/prompts/workers/CHECKIN-INSTRUCTIONS.md  # How to check in

docs/PM-IMPLEMENTATION-PLAN.md               # Phased timeline
docs/PM-TESTING-PLAN.md                      # Test strategy
docs/PM-DASHBOARD-INTEGRATION.md             # Dashboard specs
```

---

**Document Status**: Design Complete, Ready for Implementation
**Next Action**: Create pm-data-formats.md with complete JSON schemas
**Owner**: Meta-Agent (Orchestrator)
**Approved By**: [Pending Human Review]
