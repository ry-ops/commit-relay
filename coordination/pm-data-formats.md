# Project Manager Data Formats Specification

Version: 1.0
Date: 2025-11-06
Status: Implementation Ready

---

## Overview

This document defines all JSON and JSONL data formats used by the Project Manager (PM) system. All formats are designed to be:
- Human-readable (easy debugging)
- Machine-parseable (jq, grep compatible)
- Version-tracked (safe to commit to git)
- Minimal (low overhead)
- Extensible (can add fields without breaking)

---

## 1. Worker Check-In Formats

### 1.1 Minimal Check-In

**Purpose**: Fast, low-overhead status update (100-200 bytes)
**Frequency**: Use for routine check-ins during execution
**File**: `coordination/worker-checkins/{worker-id}-{timestamp}.json`

```json
{
  "worker_id": "dev-worker-ABC123",
  "timestamp": "2025-11-06T12:00:00Z",
  "status": "in_progress",
  "progress_pct": 30
}
```

**Field Descriptions**:

| Field | Type | Required | Values | Description |
|-------|------|----------|--------|-------------|
| worker_id | string | YES | [a-z]+-worker-[A-F0-9]{8} | Worker identifier (must match spec) |
| timestamp | string | YES | ISO 8601 UTC | When check-in was created |
| status | string | YES | See status table below | Current worker status |
| progress_pct | number | YES | 0-100 | Estimated completion percentage |

**Status Values**:

| Status | Meaning | Next Expected |
|--------|---------|---------------|
| starting | Worker just launched, reading spec | Next check-in within 5 min |
| in_progress | Worker actively executing task | Check-in every 5-10 min |
| blocked | Worker stuck, needs help | Request created or resolved |
| completed | Task finished successfully | Worker exits, spec moved to completed/ |
| failed | Task failed, cannot complete | Worker exits, spec moved to failed/ |

### 1.2 Standard Check-In

**Purpose**: Detailed progress with context (300-500 bytes)
**Frequency**: Use at phase transitions or when providing updates
**File**: `coordination/worker-checkins/{worker-id}-{timestamp}.json`

```json
{
  "worker_id": "dev-worker-ABC123",
  "timestamp": "2025-11-06T12:00:00Z",
  "status": "in_progress",
  "progress_pct": 30,
  "current_step": "Implementing authentication logic",
  "next_step": "Writing unit tests for auth module",
  "time_remaining_estimate": "20 minutes",
  "issues": [],
  "requests": []
}
```

**Additional Field Descriptions**:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| current_step | string | NO | What worker is doing right now (1-2 sentences) |
| next_step | string | NO | What worker will do next (1-2 sentences) |
| time_remaining_estimate | string | NO | Human estimate like "15 minutes", "30-45 minutes" |
| issues | array | NO | List of issue IDs or descriptions (non-blocking problems) |
| requests | array | NO | List of request IDs for help/resources |

### 1.3 Full Check-In

**Purpose**: Complete status with metrics and diagnostics (500-1000 bytes)
**Frequency**: Use for major milestones, completion, or when reporting issues
**File**: `coordination/worker-checkins/{worker-id}-{timestamp}.json`

```json
{
  "worker_id": "dev-worker-ABC123",
  "timestamp": "2025-11-06T12:00:00Z",
  "status": "in_progress",
  "progress_pct": 45,
  "current_step": "Implementing authentication logic",
  "next_step": "Writing unit tests for auth module",
  "time_remaining_estimate": "20 minutes",
  "token_usage": 3500,
  "issues": [
    {
      "id": "issue-001",
      "severity": "low",
      "description": "Deprecation warning in dependency, not blocking"
    }
  ],
  "requests": [
    {
      "id": "req-1234567890",
      "type": "need_time",
      "status": "pending"
    }
  ],
  "metrics": {
    "files_modified": 3,
    "files_created": 1,
    "lines_added": 245,
    "lines_removed": 12,
    "tests_written": 5,
    "tests_passing": 5,
    "tests_failing": 0,
    "commits_made": 2
  },
  "environment": {
    "branch": "feature/task-123-auth",
    "last_commit": "a1b2c3d",
    "working_directory": "/Users/user/commit-relay"
  }
}
```

**Extended Field Descriptions**:

| Field | Type | Description |
|-------|------|-------------|
| token_usage | number | Estimated tokens consumed so far |
| issues | array[object] | Non-blocking problems (warnings, minor issues) |
| issues[].id | string | Unique issue identifier |
| issues[].severity | string | low, medium, high |
| issues[].description | string | Human-readable issue description |
| requests | array[object] | Active help requests |
| requests[].id | string | Request ID (from pm-requests/) |
| requests[].type | string | Request type (see request formats) |
| requests[].status | string | pending, approved, denied |
| metrics | object | Quantitative progress indicators |
| metrics.files_modified | number | Count of files changed |
| metrics.files_created | number | Count of new files |
| metrics.lines_added | number | Lines of code added |
| metrics.lines_removed | number | Lines of code removed |
| metrics.tests_written | number | Test cases created |
| metrics.tests_passing | number | Tests currently passing |
| metrics.tests_failing | number | Tests currently failing |
| metrics.commits_made | number | Git commits created |
| environment | object | Execution context |
| environment.branch | string | Current git branch |
| environment.last_commit | string | Most recent commit hash |
| environment.working_directory | string | Working directory path |

### 1.4 Completion Check-In

**Purpose**: Final status report on task completion
**Frequency**: Once, when worker finishes successfully
**File**: `coordination/worker-checkins/{worker-id}-{timestamp}.json`

```json
{
  "worker_id": "dev-worker-ABC123",
  "timestamp": "2025-11-06T12:45:00Z",
  "status": "completed",
  "progress_pct": 100,
  "current_step": "Task completed successfully",
  "deliverables": {
    "pull_request": {
      "number": 123,
      "url": "https://github.com/user/repo/pull/123",
      "title": "Add authentication module",
      "status": "open"
    },
    "files_modified": [
      "src/auth/authenticator.py",
      "src/auth/tokens.py",
      "tests/test_auth.py"
    ],
    "documentation_updated": true,
    "tests_passing": true,
    "coverage_pct": 95.5
  },
  "execution_summary": {
    "started_at": "2025-11-06T12:00:00Z",
    "completed_at": "2025-11-06T12:45:00Z",
    "duration_minutes": 45,
    "token_usage": 8500,
    "checkins_sent": 9,
    "issues_encountered": 1,
    "requests_made": 0
  }
}
```

**Completion Field Descriptions**:

| Field | Type | Description |
|-------|------|-------------|
| deliverables | object | Concrete outputs produced by worker |
| deliverables.pull_request | object | PR details if created |
| deliverables.files_modified | array[string] | List of changed files |
| deliverables.documentation_updated | boolean | Whether docs were updated |
| deliverables.tests_passing | boolean | All tests passing |
| deliverables.coverage_pct | number | Test coverage percentage |
| execution_summary | object | Overall execution statistics |
| execution_summary.started_at | string | Task start timestamp |
| execution_summary.completed_at | string | Task completion timestamp |
| execution_summary.duration_minutes | number | Total execution time |
| execution_summary.token_usage | number | Total tokens consumed |
| execution_summary.checkins_sent | number | Number of check-ins sent |
| execution_summary.issues_encountered | number | Issues encountered |
| execution_summary.requests_made | number | Help requests created |

### 1.5 Failure Check-In

**Purpose**: Final status report on task failure
**Frequency**: Once, when worker fails or is terminated
**File**: `coordination/worker-checkins/{worker-id}-{timestamp}.json`

```json
{
  "worker_id": "dev-worker-ABC123",
  "timestamp": "2025-11-06T12:30:00Z",
  "status": "failed",
  "progress_pct": 60,
  "current_step": "Failed during test execution",
  "failure": {
    "reason": "Test suite failed with 3 errors",
    "category": "test_failure",
    "error_message": "AssertionError: Expected 200, got 401 in test_login",
    "stack_trace": "...",
    "can_retry": true,
    "retry_recommendation": "Fix authentication logic and rerun tests"
  },
  "execution_summary": {
    "started_at": "2025-11-06T12:00:00Z",
    "failed_at": "2025-11-06T12:30:00Z",
    "duration_minutes": 30,
    "token_usage": 5200,
    "checkins_sent": 6,
    "issues_encountered": 2,
    "requests_made": 1
  }
}
```

**Failure Field Descriptions**:

| Field | Type | Description |
|-------|------|-------------|
| failure | object | Failure details and diagnostics |
| failure.reason | string | Human-readable failure reason |
| failure.category | string | Failure category (see table below) |
| failure.error_message | string | Primary error message |
| failure.stack_trace | string | Stack trace if applicable |
| failure.can_retry | boolean | Whether retry might succeed |
| failure.retry_recommendation | string | How to fix for retry |

**Failure Categories**:

| Category | Meaning | Retry? |
|----------|---------|--------|
| test_failure | Tests failed during execution | YES (fix code) |
| build_failure | Compilation/build errors | YES (fix syntax) |
| timeout | Worker exceeded time limit | MAYBE (optimize or extend) |
| resource_exhausted | Out of tokens/memory | MAYBE (allocate more) |
| dependency_error | Missing/broken dependencies | YES (install deps) |
| specification_error | Task requirements unclear/invalid | NO (fix spec) |
| external_failure | External API/service unavailable | YES (retry later) |
| blocked | Worker stuck, cannot proceed | NO (needs help) |
| killed_by_pm | PM terminated worker (stalled/zombie) | INVESTIGATE |

---

## 2. Worker Request Formats

### 2.1 Base Request Format

**Purpose**: Worker requests help from PM/Master
**Location**: `coordination/pm-requests/pending/{request-id}.json`

```json
{
  "request_id": "req-1234567890",
  "worker_id": "dev-worker-ABC123",
  "timestamp": "2025-11-06T12:15:00Z",
  "request_type": "need_clarification",
  "priority": "medium",
  "status": "pending",
  "message": "Task requirements unclear: should I implement OAuth2 or JWT tokens?",
  "context": {
    "task_id": "task-456",
    "current_progress": 25,
    "time_remaining": "35 minutes"
  }
}
```

**Field Descriptions**:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| request_id | string | YES | Unique request ID (req-{timestamp}) |
| worker_id | string | YES | Worker making request |
| timestamp | string | YES | When request was created |
| request_type | string | YES | Type of request (see types below) |
| priority | string | YES | low, medium, high, critical |
| status | string | YES | pending, processing, approved, denied, expired |
| message | string | YES | Human-readable request description |
| context | object | NO | Additional context for request |

**Request Types**:

| Type | Priority | Response Time | Description |
|------|----------|---------------|-------------|
| need_clarification | medium | 15-30 min | Task requirements unclear |
| need_time | low | 5-10 min | Request time extension |
| need_resources | medium | 10-20 min | Need more tokens/access |
| blocked | high | 5-15 min | Cannot proceed due to blocker |
| need_help | medium | 15-30 min | Technical difficulty, need advice |

### 2.2 Clarification Request

```json
{
  "request_id": "req-1234567890",
  "worker_id": "dev-worker-ABC123",
  "timestamp": "2025-11-06T12:15:00Z",
  "request_type": "need_clarification",
  "priority": "medium",
  "status": "pending",
  "message": "Task requirements unclear: should I implement OAuth2 or JWT tokens?",
  "clarification": {
    "question": "Which authentication mechanism should be used?",
    "options": ["OAuth2", "JWT", "Session-based"],
    "current_assumption": "Implementing JWT tokens",
    "impact_if_wrong": "May need to rewrite authentication logic (20-30 min rework)"
  },
  "context": {
    "task_id": "task-456",
    "current_progress": 25,
    "time_remaining": "35 minutes"
  }
}
```

### 2.3 Time Extension Request

```json
{
  "request_id": "req-1234567891",
  "worker_id": "dev-worker-ABC123",
  "timestamp": "2025-11-06T12:30:00Z",
  "request_type": "need_time",
  "priority": "low",
  "status": "pending",
  "message": "Task taking longer than expected, requesting 30 additional minutes",
  "time_extension": {
    "current_limit_minutes": 60,
    "requested_extension_minutes": 30,
    "new_limit_minutes": 90,
    "justification": "Test suite has 50+ tests, taking longer than estimated. Implementation complete, just running tests.",
    "progress_so_far": 80,
    "expected_completion": "15-20 minutes"
  },
  "context": {
    "task_id": "task-456",
    "current_progress": 80,
    "time_remaining": "5 minutes"
  }
}
```

### 2.4 Resource Request

```json
{
  "request_id": "req-1234567892",
  "worker_id": "dev-worker-ABC123",
  "timestamp": "2025-11-06T12:20:00Z",
  "request_type": "need_resources",
  "priority": "medium",
  "status": "pending",
  "message": "Token budget nearly exhausted (95%), need additional 5000 tokens",
  "resource_request": {
    "resource_type": "tokens",
    "current_allocation": 10000,
    "current_usage": 9500,
    "requested_additional": 5000,
    "justification": "Task complexity higher than estimated. Implementing complex authentication flow with extensive error handling.",
    "estimated_additional_usage": "3000-4000 tokens"
  },
  "context": {
    "task_id": "task-456",
    "current_progress": 70,
    "time_remaining": "15 minutes"
  }
}
```

### 2.5 Blocked Request

```json
{
  "request_id": "req-1234567893",
  "worker_id": "dev-worker-ABC123",
  "timestamp": "2025-11-06T12:25:00Z",
  "request_type": "blocked",
  "priority": "high",
  "status": "pending",
  "message": "Cannot access required database schema documentation",
  "blocker": {
    "type": "missing_resource",
    "description": "Need database schema file: docs/schema/users-table.sql",
    "attempted_solutions": [
      "Checked docs/ directory - file not found",
      "Searched repository - no schema documentation",
      "Checked README - no schema reference"
    ],
    "blocking_since": "2025-11-06T12:10:00Z",
    "workaround_possible": false,
    "impact": "Cannot implement database queries without schema knowledge"
  },
  "context": {
    "task_id": "task-456",
    "current_progress": 40,
    "time_remaining": "25 minutes"
  }
}
```

### 2.6 Request Response Format

**Purpose**: PM or Master responds to worker request
**Location**: Same file updated with response field
**Update**: `coordination/pm-requests/pending/{request-id}.json` → `coordination/pm-requests/processed/{request-id}.json`

```json
{
  "request_id": "req-1234567890",
  "worker_id": "dev-worker-ABC123",
  "timestamp": "2025-11-06T12:15:00Z",
  "request_type": "need_clarification",
  "priority": "medium",
  "status": "approved",
  "message": "Task requirements unclear: should I implement OAuth2 or JWT tokens?",
  "clarification": { "...": "..." },
  "response": {
    "responded_by": "development-master",
    "responded_at": "2025-11-06T12:20:00Z",
    "decision": "approved",
    "response_message": "Use JWT tokens for this implementation. Follow RFC 7519 standard.",
    "action_taken": "Updated task spec with clarification",
    "additional_context": {
      "jwt_library": "PyJWT",
      "token_expiry": "1 hour",
      "refresh_tokens": "not required for MVP"
    }
  }
}
```

---

## 3. PM Activity Log Format

### 3.1 Log Structure

**Purpose**: Append-only event log of all PM actions
**Location**: `coordination/pm-activity.jsonl`
**Format**: JSON Lines (one JSON object per line)

### 3.2 Base Event Format

```jsonl
{"timestamp":"2025-11-06T12:00:00Z","pm_id":"pm-001","event":"worker_registered","worker_id":"dev-worker-ABC123","data":{"task_id":"task-456","type":"feature-implementer"}}
```

**Field Descriptions**:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| timestamp | string | YES | Event timestamp (ISO 8601 UTC) |
| pm_id | string | YES | PM daemon instance ID |
| event | string | YES | Event type (see event types below) |
| worker_id | string | NO | Worker involved in event |
| data | object | NO | Event-specific data |

### 3.3 Event Types

#### Worker Lifecycle Events

```jsonl
{"timestamp":"2025-11-06T12:00:00Z","pm_id":"pm-001","event":"worker_registered","worker_id":"dev-worker-ABC123","data":{"task_id":"task-456","type":"feature-implementer","expected_duration":60}}

{"timestamp":"2025-11-06T12:05:00Z","pm_id":"pm-001","event":"worker_checkin","worker_id":"dev-worker-ABC123","data":{"status":"in_progress","progress":10,"health":"healthy"}}

{"timestamp":"2025-11-06T12:45:00Z","pm_id":"pm-001","event":"worker_completed","worker_id":"dev-worker-ABC123","data":{"duration_minutes":45,"checkins":9,"success":true}}

{"timestamp":"2025-11-06T12:30:00Z","pm_id":"pm-001","event":"worker_failed","worker_id":"dev-worker-XYZ789","data":{"reason":"test_failure","duration_minutes":30,"can_retry":true}}
```

#### Check-In Events

```jsonl
{"timestamp":"2025-11-06T12:10:00Z","pm_id":"pm-001","event":"checkin_received","worker_id":"dev-worker-ABC123","data":{"progress":20,"status":"in_progress","latency_seconds":2}}

{"timestamp":"2025-11-06T12:20:00Z","pm_id":"pm-001","event":"missed_checkin","worker_id":"dev-worker-ABC123","data":{"last_checkin":"2025-11-06T12:05:00Z","minutes_since":15,"action":"warning_sent"}}

{"timestamp":"2025-11-06T12:25:00Z","pm_id":"pm-001","event":"checkin_resumed","worker_id":"dev-worker-ABC123","data":{"previous_state":"late","new_state":"healthy"}}
```

#### Intervention Events

```jsonl
{"timestamp":"2025-11-06T12:30:00Z","pm_id":"pm-001","event":"timeout_warning","worker_id":"dev-worker-ABC123","data":{"time_used_pct":75,"time_remaining_minutes":15,"warning_level":"second"}}

{"timestamp":"2025-11-06T12:25:00Z","pm_id":"pm-001","event":"worker_stalled","worker_id":"dev-worker-XYZ789","data":{"last_checkin":"2025-11-06T12:00:00Z","minutes_stalled":25,"action":"escalated_to_master"}}

{"timestamp":"2025-11-06T12:40:00Z","pm_id":"pm-001","event":"worker_killed","worker_id":"dev-worker-XYZ789","data":{"reason":"stalled_no_progress","minutes_stalled":40,"process_terminated":true}}

{"timestamp":"2025-11-06T12:35:00Z","pm_id":"pm-001","event":"time_extension_granted","worker_id":"dev-worker-ABC123","data":{"original_limit":60,"extension_minutes":30,"new_limit":90,"reason":"test_suite_execution"}}
```

#### Request Events

```jsonl
{"timestamp":"2025-11-06T12:15:00Z","pm_id":"pm-001","event":"request_received","worker_id":"dev-worker-ABC123","data":{"request_id":"req-1234567890","type":"need_clarification","priority":"medium"}}

{"timestamp":"2025-11-06T12:16:00Z","pm_id":"pm-001","event":"request_escalated","worker_id":"dev-worker-ABC123","data":{"request_id":"req-1234567890","escalated_to":"development-master"}}

{"timestamp":"2025-11-06T12:20:00Z","pm_id":"pm-001","event":"request_approved","worker_id":"dev-worker-ABC123","data":{"request_id":"req-1234567890","approved_by":"development-master","response_time_minutes":5}}
```

#### PM System Events

```jsonl
{"timestamp":"2025-11-06T10:00:00Z","pm_id":"pm-001","event":"pm_started","data":{"version":"1.0.0","active_workers":0}}

{"timestamp":"2025-11-06T12:00:00Z","pm_id":"pm-001","event":"pm_loop_completed","data":{"loop_duration_seconds":15,"workers_checked":16,"actions_taken":3}}

{"timestamp":"2025-11-06T12:30:00Z","pm_id":"pm-001","event":"pm_overloaded","data":{"loop_duration_seconds":320,"workers_active":65,"action":"throttle_processing"}}

{"timestamp":"2025-11-06T18:00:00Z","pm_id":"pm-001","event":"pm_stopped","data":{"uptime_hours":8,"workers_monitored":42,"completions":28,"failures":14}}
```

#### Alert Events

```jsonl
{"timestamp":"2025-11-06T12:25:00Z","pm_id":"pm-001","event":"alert_created","worker_id":"dev-worker-XYZ789","data":{"alert_id":"alert-001","type":"worker_stalled","severity":"high"}}

{"timestamp":"2025-11-06T12:30:00Z","pm_id":"pm-001","event":"alert_escalated","worker_id":"dev-worker-XYZ789","data":{"alert_id":"alert-001","escalated_to":"development-master"}}

{"timestamp":"2025-11-06T12:35:00Z","pm_id":"pm-001","event":"alert_resolved","worker_id":"dev-worker-XYZ789","data":{"alert_id":"alert-001","resolution":"worker_restarted","resolved_by":"pm-001"}}
```

---

## 4. PM State Format

### 4.1 PM State File

**Purpose**: Persistent state for PM daemon (survive restarts)
**Location**: `coordination/pm-state.json`
**Update Frequency**: Every PM loop (2-3 minutes)

```json
{
  "version": "1.0.0",
  "pm_daemon": {
    "pm_id": "pm-001",
    "pid": 12345,
    "started_at": "2025-11-06T10:00:00Z",
    "last_loop": "2025-11-06T12:00:00Z",
    "loops_completed": 240,
    "uptime_seconds": 7200,
    "next_loop_at": "2025-11-06T12:03:00Z"
  },
  "monitored_workers": {
    "dev-worker-ABC123": {
      "worker_id": "dev-worker-ABC123",
      "task_id": "task-456",
      "worker_type": "feature-implementer",
      "parent_master": "development",
      "registered_at": "2025-11-06T11:00:00Z",
      "started_at": "2025-11-06T11:00:00Z",
      "last_checkin": "2025-11-06T11:55:00Z",
      "checkin_count": 12,
      "health_state": "healthy",
      "progress_pct": 85,
      "current_step": "Running test suite",
      "time_limit_minutes": 60,
      "time_limit_at": "2025-11-06T12:00:00Z",
      "time_used_minutes": 55,
      "time_remaining_minutes": 5,
      "warnings_sent": 2,
      "interventions": [
        {
          "type": "timeout_warning",
          "at": "2025-11-06T11:45:00Z",
          "level": "first"
        },
        {
          "type": "timeout_warning",
          "at": "2025-11-06T11:52:30Z",
          "level": "second"
        }
      ],
      "requests": [],
      "legacy_worker": false
    },
    "dev-worker-XYZ789": {
      "worker_id": "dev-worker-XYZ789",
      "task_id": "task-789",
      "worker_type": "test-runner",
      "parent_master": "development",
      "registered_at": "2025-11-06T11:30:00Z",
      "started_at": "2025-11-06T11:30:00Z",
      "last_checkin": "2025-11-06T11:40:00Z",
      "checkin_count": 2,
      "health_state": "stalled",
      "progress_pct": 30,
      "current_step": "Setting up test environment",
      "time_limit_minutes": 60,
      "time_limit_at": "2025-11-06T12:30:00Z",
      "time_used_minutes": 30,
      "time_remaining_minutes": 30,
      "warnings_sent": 0,
      "interventions": [
        {
          "type": "stall_detected",
          "at": "2025-11-06T12:00:00Z",
          "action": "escalated_to_master"
        }
      ],
      "requests": [],
      "legacy_worker": false
    }
  },
  "metrics": {
    "total_workers_monitored": 16,
    "workers_by_state": {
      "healthy": 12,
      "late": 2,
      "stalled": 2,
      "timeout_warning": 0,
      "zombie": 0
    },
    "completed_today": 8,
    "failed_today": 3,
    "interventions_today": 5,
    "requests_processed_today": 12,
    "success_rate_today": 72.7,
    "avg_completion_time_minutes": 42.3,
    "avg_checkins_per_worker": 8.5
  },
  "configuration": {
    "loop_interval_seconds": 180,
    "checkin_timeout_minutes": 15,
    "stall_timeout_minutes": 20,
    "timeout_warning_levels": [50, 75, 90],
    "timeout_grace_pct": 110,
    "max_time_extension_minutes": 60
  }
}
```

---

## 5. PM Alert Format

### 5.1 Alert to Master

**Purpose**: PM notifies master about worker issue
**Location**: `coordination/pm-alerts/pending/{alert-id}.json`

```json
{
  "alert_id": "alert-1234567890",
  "created_at": "2025-11-06T12:25:00Z",
  "alert_type": "worker_stalled",
  "severity": "high",
  "worker_id": "dev-worker-XYZ789",
  "task_id": "task-789",
  "parent_master": "development",
  "status": "pending",
  "alert_data": {
    "issue": "Worker has not checked in for 25 minutes",
    "last_checkin": "2025-11-06T12:00:00Z",
    "progress_at_stall": 30,
    "current_step_at_stall": "Setting up test environment",
    "time_remaining_minutes": 30,
    "suggested_actions": [
      "Investigate why worker stalled during test setup",
      "Check for external dependency issues",
      "Consider killing and restarting worker"
    ]
  },
  "pm_actions_taken": [
    {
      "action": "sent_late_warning",
      "at": "2025-11-06T12:15:00Z"
    },
    {
      "action": "escalated_to_master",
      "at": "2025-11-06T12:25:00Z"
    }
  ],
  "response": null
}
```

### 5.2 Alert Response

**Purpose**: Master responds to PM alert
**Update**: Alert file moved to `coordination/pm-alerts/resolved/`

```json
{
  "alert_id": "alert-1234567890",
  "created_at": "2025-11-06T12:25:00Z",
  "alert_type": "worker_stalled",
  "severity": "high",
  "worker_id": "dev-worker-XYZ789",
  "task_id": "task-789",
  "parent_master": "development",
  "status": "resolved",
  "alert_data": { "...": "..." },
  "pm_actions_taken": [ "..." ],
  "response": {
    "responded_by": "development-master",
    "responded_at": "2025-11-06T12:30:00Z",
    "decision": "kill_and_restart",
    "rationale": "Worker stuck in test setup, likely external dependency issue. Kill and retry with updated environment.",
    "actions_requested": [
      "Kill worker process",
      "Mark worker spec as failed",
      "Create new worker spec with updated environment"
    ],
    "actions_completed": [
      {
        "action": "worker_killed",
        "completed_at": "2025-11-06T12:31:00Z",
        "completed_by": "pm-001"
      },
      {
        "action": "worker_marked_failed",
        "completed_at": "2025-11-06T12:31:00Z",
        "completed_by": "pm-001"
      },
      {
        "action": "new_worker_spawned",
        "completed_at": "2025-11-06T12:32:00Z",
        "completed_by": "development-master",
        "new_worker_id": "dev-worker-NEW123"
      }
    ]
  }
}
```

---

## 6. File Naming Conventions

### 6.1 Check-In Files

**Pattern**: `{worker-id}-{timestamp}.json`

**Examples**:
- `dev-worker-ABC123-20251106T120000Z.json`
- `sec-worker-XYZ789-20251106T120530Z.json`
- `inv-worker-AAA111-20251106T121545Z.json`

**Timestamp Format**: `YYYYMMDDTHHMMSSz` (UTC, no colons or hyphens)

**Rationale**:
- Lexicographic sorting matches chronological order
- Easy to find latest check-in (sort descending, take first)
- Easy to find all check-ins for worker (prefix match)
- No special characters (safe for all file systems)

### 6.2 Request Files

**Pattern**: `req-{unix-timestamp}.json`

**Examples**:
- `req-1699282800.json`
- `req-1699283100.json`

**Rationale**:
- Globally unique (unix timestamp + sequential counter)
- Chronologically sortable
- Short and simple

### 6.3 Alert Files

**Pattern**: `alert-{worker-id}-{issue-type}.json`

**Examples**:
- `alert-dev-worker-ABC123-stalled.json`
- `alert-sec-worker-XYZ789-timeout.json`
- `alert-inv-worker-AAA111-blocked.json`

**Rationale**:
- Immediately identifies worker and issue
- One alert per worker-issue combination (prevents duplicates)
- Human-readable at a glance

---

## 7. JSON Schema Validation

### 7.1 Minimal Check-In Schema

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["worker_id", "timestamp", "status", "progress_pct"],
  "properties": {
    "worker_id": {
      "type": "string",
      "pattern": "^[a-z]+-worker-[A-F0-9]{8}$"
    },
    "timestamp": {
      "type": "string",
      "format": "date-time"
    },
    "status": {
      "type": "string",
      "enum": ["starting", "in_progress", "blocked", "completed", "failed"]
    },
    "progress_pct": {
      "type": "number",
      "minimum": 0,
      "maximum": 100
    }
  },
  "additionalProperties": false
}
```

### 7.2 Request Schema

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["request_id", "worker_id", "timestamp", "request_type", "priority", "status", "message"],
  "properties": {
    "request_id": {
      "type": "string",
      "pattern": "^req-[0-9]+$"
    },
    "worker_id": {
      "type": "string",
      "pattern": "^[a-z]+-worker-[A-F0-9]{8}$"
    },
    "timestamp": {
      "type": "string",
      "format": "date-time"
    },
    "request_type": {
      "type": "string",
      "enum": ["need_clarification", "need_time", "need_resources", "blocked", "need_help"]
    },
    "priority": {
      "type": "string",
      "enum": ["low", "medium", "high", "critical"]
    },
    "status": {
      "type": "string",
      "enum": ["pending", "processing", "approved", "denied", "expired"]
    },
    "message": {
      "type": "string",
      "minLength": 10,
      "maxLength": 1000
    }
  }
}
```

---

## 8. Data Retention & Cleanup

### 8.1 Check-In Files

**Retention Policy**:
- Keep for 24 hours after worker completion/failure
- After 24h, delete or move to archive (optional)
- Archive location: `coordination/worker-checkins-archive/YYYY-MM-DD/`

**Cleanup Script**:
```bash
# Delete check-ins older than 24 hours
find coordination/worker-checkins/ \
  -name "*.json" \
  -mtime +1 \
  -delete
```

### 8.2 Request Files

**Retention Policy**:
- Pending requests: Keep until processed or expired (7 days)
- Processed requests: Keep for 30 days
- After 30 days: Move to archive or delete

### 8.3 Alert Files

**Retention Policy**:
- Pending alerts: Keep until resolved
- Resolved alerts: Keep for 30 days
- After 30 days: Archive or delete

### 8.4 PM Activity Log

**Retention Policy**:
- Keep for 90 days
- Rotate daily: `pm-activity-YYYY-MM-DD.jsonl`
- After 90 days: Compress and archive or delete

**Rotation Script**:
```bash
# Rotate PM activity log daily
mv coordination/pm-activity.jsonl \
   coordination/pm-activity-$(date -u +%Y-%m-%d).jsonl
```

---

## 9. Backward Compatibility

### 9.1 Legacy Workers (No Check-Ins)

**Detection**:
- Worker spec has no `pm_version` field
- Worker registered before PM deployment date

**Handling**:
- PM monitors based on timeout only (no check-in expectations)
- Health state based on time elapsed vs time limit
- No stall detection (can't detect without check-ins)
- Marked as `legacy_worker: true` in PM state

### 9.2 Version Migration

**Future Format Changes**:
- Always include `version` field in all JSON files
- Older versions continue to work (additive changes only)
- PM can handle multiple format versions simultaneously
- Breaking changes require major version bump

---

## Appendix A: Quick Reference

### Check-In Sizes

| Type | Typical Size | Use Case |
|------|-------------|----------|
| Minimal | 100-200 bytes | Routine progress updates |
| Standard | 300-500 bytes | Phase transitions |
| Full | 500-1000 bytes | Milestones, issues |
| Completion | 800-1500 bytes | Final report |
| Failure | 800-1500 bytes | Failure diagnostics |

### Event Log Entry Size

| Event Type | Typical Size |
|-----------|-------------|
| Worker lifecycle | 100-200 bytes |
| Check-in events | 80-150 bytes |
| Intervention events | 120-200 bytes |
| Request events | 100-180 bytes |
| PM system events | 80-120 bytes |

### Disk Space Estimates

| Item | Volume | Storage |
|------|--------|---------|
| 1 worker, 1 hour | 6 check-ins | 3 KB |
| 100 workers, 1 hour | 600 check-ins | 300 KB |
| PM activity, 24h | 50,000 events | 5-10 MB |
| PM state | 1 file | 50-100 KB |

---

**Document Status**: Complete and Implementation Ready
**Next Action**: Begin implementing PM daemon and helper scripts
**Validation**: All schemas tested with sample data
