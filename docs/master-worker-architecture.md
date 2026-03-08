# Master-Worker Agent Architecture

**Version**: 2.0
**Status**: Design Phase
**Last Updated**: 2025-11-01

---

## Executive Summary

This document describes a Kubernetes-inspired master-worker architecture for commit-relay that addresses token efficiency and scalability challenges. The system transitions from persistent long-running agents to a model where:

- **Master Agents** provide orchestration and strategic decision-making
- **Worker Agents** execute focused, ephemeral tasks with minimal context
- **Token budgets** are managed across the entire agent fleet
- **Parallel execution** enables faster task completion

### Key Metrics
- **Token efficiency**: 80-90% reduction per task (focused context)
- **Parallelization**: 3-5x faster for independent tasks
- **Cost reduction**: Better budget allocation and tracking
- **Scalability**: Spawn workers on-demand based on queue depth

---

## Problem Statement

### Current Architecture Issues

1. **Token Exhaustion**: Long conversations consume entire token budgets
2. **Context Bloat**: Agents load full coordination history every check-in
3. **Sequential Bottlenecks**: Tasks processed one-at-a-time per agent
4. **No Load Balancing**: Can't distribute work efficiently
5. **All-or-Nothing**: Can't partial-complete large tasks
6. **Resource Waste**: Idle agents still holding context

### Real-World Example

**Current**: Security agent scans 3 repositories sequentially
- Check-in: 2k tokens (load coordination files)
- Scan repo 1: 15k tokens (tools + analysis)
- Scan repo 2: 15k tokens
- Scan repo 3: 15k tokens
- Report: 3k tokens
- **Total**: 50k tokens, ~45 minutes

**New**: Security master spawns 3 scan workers in parallel
- Master check-in: 2k tokens
- Spawn 3 workers: 1k tokens
- Worker 1: 8k tokens (focused on single repo)
- Worker 2: 8k tokens (parallel)
- Worker 3: 8k tokens (parallel)
- Aggregate results: 2k tokens
- **Total**: 29k tokens, ~15 minutes

---

## Architecture Overview

### System Layers

```
┌─────────────────────────────────────────────────────────────┐
│                     ORCHESTRATION LAYER                      │
│                   (Coordinator Master)                       │
│  • Task decomposition & assignment                           │
│  • Token budget management                                   │
│  • Worker lifecycle orchestration                            │
│  • System health monitoring                                  │
└────────────────────────┬────────────────────────────────────┘
                         │
         ┌───────────────┼───────────────┐
         │               │               │
┌────────▼───────┐ ┌────▼─────┐ ┌───────▼────────┐
│ Security Master │ │Dev Master│ │ Future Masters │
│ • Strategy      │ │• Planning│ │ • PR Mgmt      │
│ • Delegation    │ │• Review  │ │ • Content      │
└────────┬───────┘ └────┬─────┘ └────────────────┘
         │               │
    ┌────┴────┐     ┌────┴────┐
    │ Workers │     │ Workers │
    │ (Pool)  │     │ (Pool)  │
    └─────────┘     └─────────┘
         │               │
         ▼               ▼
┌─────────────────────────────────────────────────────────────┐
│                   COORDINATION LAYER                         │
│  • task-queue.json (master tasks + worker jobs)              │
│  • worker-pool.json (active workers + status)                │
│  • token-budget.json (allocation + tracking)                 │
│  • handoffs.json (master ↔ master + results)                │
└─────────────────────────────────────────────────────────────┘
```

---

## Agent Types

### Master Agents (Control Plane)

Long-running strategic agents that orchestrate work.

#### Coordinator Master
**Role**: System orchestrator and task decomposer

**Responsibilities**:
- Monitor task queue and system health
- Decompose complex tasks into worker jobs
- Allocate token budgets to masters and workers
- Spawn/terminate workers based on load
- Aggregate worker results
- Handle escalations and human interaction
- Generate system reports and metrics

**Token Allocation**: 50k (reserved, long-running)

**Check-in Frequency**: Every 2-4 hours or on-demand

**Spawns**:
- Analysis workers (investigate issues)
- Coordinator workers (handle overflow)

---

#### Security Master
**Role**: Security strategy and delegation

**Responsibilities**:
- Define security scan strategies
- Spawn scan workers for repositories
- Review worker findings and prioritize
- Create remediation tasks
- Coordinate with Development Master on fixes
- Track security metrics across fleet

**Token Allocation**: 30k (reserved)

**Check-in Frequency**: Daily or on security events

**Spawns**:
- Scan workers (dependency audit, SAST)
- Audit workers (security review)
- Remediation workers (apply patches)

---

#### Development Master
**Role**: Development planning and code review

**Responsibilities**:
- Break down features into implementation tasks
- Spawn implementation workers
- Review worker PRs and code quality
- Coordinate integration of worker outputs
- Manage technical debt
- Architectural decisions

**Token Allocation**: 30k (reserved)

**Check-in Frequency**: Daily or when tasks assigned

**Spawns**:
- Implementation workers (build features)
- Fix workers (bug fixes)
- Refactor workers (code improvements)
- Test workers (add/fix tests)

---

### Worker Agents (Ephemeral Pods)

Short-lived, single-purpose agents with minimal context.

#### General Worker Characteristics

- **Lifespan**: Single task execution (minutes to hours)
- **Context**: Only task-specific information
- **Token Budget**: 3k-10k per worker
- **State**: Stateless (results written to coordination)
- **Spawning**: On-demand by master agents
- **Termination**: Auto-terminates on completion/failure/timeout

---

#### Worker Types

**1. Scan Worker**
- **Purpose**: Security scan of single repository
- **Input**: Repository URL, scan type
- **Output**: Vulnerabilities, dependencies, findings
- **Token Budget**: 8k
- **Typical Duration**: 10-15 minutes

**2. Fix Worker**
- **Purpose**: Apply specific fix (dependency update, patch)
- **Input**: Repository, fix instructions, target files
- **Output**: Commit hash, test results
- **Token Budget**: 5k
- **Typical Duration**: 15-20 minutes

**3. Implementation Worker**
- **Purpose**: Build specific feature component
- **Input**: Feature spec, file scope, acceptance criteria
- **Output**: Code changes, tests, documentation
- **Token Budget**: 10k
- **Typical Duration**: 30-45 minutes

**4. Analysis Worker**
- **Purpose**: Research, investigation, code exploration
- **Input**: Question, scope, search parameters
- **Output**: Research report, findings document
- **Token Budget**: 5k
- **Typical Duration**: 10-15 minutes

**5. Test Worker**
- **Purpose**: Add tests for specific module
- **Input**: Module path, coverage requirements
- **Output**: Test files, coverage report
- **Token Budget**: 6k
- **Typical Duration**: 15-20 minutes

**6. Review Worker**
- **Purpose**: Code review of specific PR or commit
- **Input**: PR number or commit hash
- **Output**: Review comments, approval/changes requested
- **Token Budget**: 5k
- **Typical Duration**: 10-15 minutes

**7. PR Worker**
- **Purpose**: Create pull request with specific changes
- **Input**: Branch, title, description template
- **Output**: PR URL, checks status
- **Token Budget**: 4k
- **Typical Duration**: 10 minutes

**8. Documentation Worker**
- **Purpose**: Write/update specific documentation
- **Input**: Topic, target file, outline
- **Output**: Updated documentation
- **Token Budget**: 6k
- **Typical Duration**: 15-20 minutes

---

## Token Management System

### Budget Allocation

```json
{
  "version": "1.0",
  "updated_at": "2025-11-01T10:00:00Z",
  "total_budget": 200000,
  "allocation": {
    "masters": {
      "coordinator": {
        "allocated": 50000,
        "used": 12500,
        "reserved_for_workers": 30000
      },
      "security": {
        "allocated": 30000,
        "used": 8000,
        "reserved_for_workers": 15000
      },
      "development": {
        "allocated": 30000,
        "used": 10000,
        "reserved_for_workers": 20000
      }
    },
    "worker_pool": {
      "total_allocated": 65000,
      "available": 40000,
      "in_use": 25000
    },
    "emergency_reserve": 25000
  }
}
```

### Budget Management Rules

1. **Master Reservation**: Each master gets base allocation (30-50k)
2. **Worker Pool**: Masters request worker tokens from pool
3. **Dynamic Allocation**: Redistribute based on queue priorities
4. **Budget Alerts**: Warn at 75% usage, escalate at 90%
5. **Emergency Reserve**: Untouchable reserve for critical fixes
6. **Worker Timeout**: Reclaim tokens if worker exceeds time limit

### Worker Token Requests

```json
{
  "worker_request": {
    "id": "worker-req-001",
    "master_agent": "security-master",
    "worker_type": "scan-worker",
    "estimated_tokens": 8000,
    "priority": "high",
    "justification": "Security scan required for new dependency",
    "timeout": "15m"
  }
}
```

### Approval Flow

1. Master requests tokens for worker
2. Coordinator checks available pool
3. If available: approve and spawn
4. If limited: queue or reject low-priority
5. Worker allocated exact budget
6. Tokens reclaimed on completion/timeout

---

## Worker Lifecycle

### 1. Worker Definition

Master agent creates worker specification:

```json
{
  "worker_id": "worker-scan-001",
  "worker_type": "scan-worker",
  "created_by": "security-master",
  "created_at": "2025-11-01T10:15:00Z",
  "task_id": "task-010",
  "scope": {
    "repository": "ry-ops/n8n-mcp-server",
    "scan_types": ["dependencies", "vulnerabilities", "secrets"],
    "depth": "full"
  },
  "context": {
    "parent_task": "Initial security assessment",
    "priority": "high",
    "deadline": "2025-11-01T12:00:00Z"
  },
  "token_budget": 8000,
  "timeout": "15m",
  "deliverables": [
    "scan_results.json",
    "vulnerability_list.md",
    "dependency_report.md"
  ],
  "prompt_template": "agents/prompts/workers/scan-worker.md"
}
```

### 2. Worker Spawning

Coordinator or master spawns worker via Claude Code:

```bash
# Start new Claude Code session with worker prompt
claude-code --session-name "worker-scan-001" \
            --prompt-file "agents/prompts/workers/scan-worker.md" \
            --context "worker-specs/worker-scan-001.json" \
            --max-tokens 8000
```

### 3. Worker Execution

Worker performs focused task:
1. Read worker specification from coordination layer
2. Clone/access target repository
3. Execute assigned work (scan, fix, build, etc.)
4. Write results to designated location
5. Update coordination files with status
6. Self-terminate

### 4. Worker Reporting

Worker writes results to standard location:

```
agents/logs/workers/
├── 2025-11-01/
│   ├── worker-scan-001/
│   │   ├── spec.json          # Worker specification
│   │   ├── log.md             # Execution log
│   │   ├── results.json       # Structured results
│   │   └── artifacts/         # Output files
│   ├── worker-fix-002/
│   └── worker-impl-003/
```

### 5. Result Aggregation

Master agent collects worker results:

```json
{
  "task_id": "task-010",
  "worker_results": [
    {
      "worker_id": "worker-scan-001",
      "status": "completed",
      "duration": "12m",
      "tokens_used": 7200,
      "findings": {
        "vulnerabilities": 2,
        "dependencies_outdated": 5,
        "secrets_found": 0
      }
    }
  ],
  "aggregated_by": "security-master",
  "aggregated_at": "2025-11-01T10:30:00Z"
}
```

### 6. Worker Cleanup

After result collection:
1. Master marks worker as completed
2. Worker tokens returned to pool
3. Worker logs archived
4. Session terminated (if automated)

---

## Coordination Files (Updated Schemas)

### worker-pool.json (NEW)

Tracks all active workers:

```json
{
  "version": "1.0",
  "updated_at": "2025-11-01T10:15:00Z",
  "active_workers": [
    {
      "worker_id": "worker-scan-001",
      "worker_type": "scan-worker",
      "spawned_by": "security-master",
      "spawned_at": "2025-11-01T10:00:00Z",
      "status": "running",
      "task_id": "task-010",
      "token_budget": 8000,
      "tokens_used": 5200,
      "timeout_at": "2025-11-01T10:15:00Z",
      "last_heartbeat": "2025-11-01T10:12:00Z",
      "session_id": "claude-session-abc123"
    }
  ],
  "completed_workers": [
    {
      "worker_id": "worker-fix-001",
      "status": "completed",
      "tokens_used": 4800,
      "duration_minutes": 18,
      "completed_at": "2025-11-01T09:45:00Z",
      "result_location": "agents/logs/workers/2025-11-01/worker-fix-001/"
    }
  ],
  "failed_workers": [
    {
      "worker_id": "worker-impl-002",
      "status": "timeout",
      "tokens_used": 10000,
      "error": "Exceeded 15m timeout",
      "failed_at": "2025-11-01T09:30:00Z"
    }
  ]
}
```

### task-queue.json (UPDATED)

New fields for worker tasks:

```json
{
  "tasks": [
    {
      "id": "task-010",
      "title": "Security scan: n8n-mcp-server",
      "type": "security",
      "execution_mode": "workers",
      "assigned_to": "security-master",
      "worker_plan": {
        "total_workers": 1,
        "workers_spawned": ["worker-scan-001"],
        "workers_completed": [],
        "estimated_tokens": 8000
      }
    }
  ]
}
```

### token-budget.json (NEW)

Centralized token tracking:

```json
{
  "version": "1.0",
  "updated_at": "2025-11-01T10:15:00Z",
  "budget_period": "daily",
  "resets_at": "2025-11-02T00:00:00Z",
  "total_budget": 200000,
  "masters": {
    "coordinator": {
      "allocated": 50000,
      "used": 12500,
      "worker_pool": 30000
    },
    "security": {
      "allocated": 30000,
      "used": 8000,
      "worker_pool": 15000
    },
    "development": {
      "allocated": 30000,
      "used": 10000,
      "worker_pool": 20000
    }
  },
  "worker_pool": {
    "total": 65000,
    "allocated_to_workers": 25000,
    "available": 40000
  },
  "emergency_reserve": {
    "total": 25000,
    "used": 0,
    "trigger_threshold": "critical_only"
  },
  "usage_metrics": {
    "total_tokens_used_today": 55500,
    "masters_percentage": 55,
    "workers_percentage": 45,
    "efficiency_score": 0.85
  }
}
```

---

## Communication Protocol

### Master → Worker Communication

Masters communicate with workers via:

1. **Worker Specification File**: JSON definition in `coordination/worker-specs/`
2. **Prompt Template**: Markdown file with worker instructions
3. **Context Package**: Repository info, credentials, relevant data

### Worker → Master Communication

Workers report via:

1. **Results File**: JSON output in standard location
2. **Status Updates**: Update `worker-pool.json` periodically
3. **Heartbeats**: Timestamp updates every 2-3 minutes
4. **Completion Signal**: Mark worker as completed in coordination

### Master ↔ Master Communication

Same as current system via `handoffs.json`:

```json
{
  "handoff_id": "handoff-010",
  "from_agent": "security-master",
  "to_agent": "development-master",
  "task_id": "task-011",
  "context": {
    "summary": "Found 2 vulnerabilities requiring code fixes",
    "worker_results": ["worker-scan-001", "worker-scan-002"],
    "priority_issues": [
      "CVE-2025-12345: SQL injection in login.py",
      "CVE-2025-67890: XSS in comment rendering"
    ]
  }
}
```

---

## Worker Spawning Strategies

### On-Demand Spawning

Spawn workers as tasks arrive:

```python
if task.type == "security-scan" and queue_depth < 3:
    spawn_worker("scan-worker", task)
elif task.type == "security-scan" and queue_depth >= 3:
    # Batch spawn multiple workers
    for repo in task.repositories:
        spawn_worker("scan-worker", repo)
```

### Scheduled Spawning

Pre-spawn workers for predictable workloads:

```json
{
  "scheduled_workers": [
    {
      "schedule": "daily@09:00",
      "worker_type": "scan-worker",
      "count": 3,
      "repositories": ["mcp-server-unifi", "n8n-mcp-server", "aiana"]
    }
  ]
}
```

### Adaptive Spawning

Scale workers based on queue depth and priority:

```python
def calculate_worker_count(queue_depth, avg_task_duration):
    if queue_depth < 3:
        return 1  # Serial processing
    elif queue_depth < 10:
        return 3  # Moderate parallelization
    else:
        return min(5, queue_depth)  # Max 5 parallel workers
```

---

## Implementation Roadmap

### Phase 1: Foundation (Week 1-2)

**Goal**: Basic master-worker infrastructure

1. Create new coordination files (worker-pool.json, token-budget.json)
2. Design worker specification schema
3. Build worker prompt templates (scan, fix, analysis)
4. Update task-queue.json schema for worker tasks
5. Create worker spawning script
6. Implement token budget tracking

**Deliverables**:
- Worker specification schema
- 3 worker prompt templates
- Basic spawning mechanism
- Token tracking infrastructure

### Phase 2: Master Conversion (Week 3)

**Goal**: Convert existing agents to masters

1. Update coordinator prompt for orchestration role
2. Update security prompt for delegation
3. Update development prompt for planning
4. Test master → worker spawning
5. Verify worker result aggregation

**Deliverables**:
- 3 updated master prompts
- Working spawn-execute-aggregate cycle
- Documentation and examples

### Phase 3: Worker Types (Week 4)

**Goal**: Implement all worker types

1. Scan worker (security scans)
2. Fix worker (dependency updates, patches)
3. Implementation worker (feature development)
4. Test worker (add tests)
5. Analysis worker (research)
6. PR worker (create PRs)

**Deliverables**:
- 6 worker templates
- Test cases for each worker type
- Performance benchmarks

### Phase 4: Optimization (Week 5-6)

**Goal**: Improve efficiency and automation

1. Adaptive worker spawning
2. Token optimization algorithms
3. Worker pooling/reuse
4. Parallel execution orchestration
5. Metrics and monitoring

**Deliverables**:
- Automated spawning strategies
- Token efficiency metrics
- Performance dashboard
- Complete documentation

---

## Example Workflows

### Workflow 1: Security Scan (Parallel)

**Task**: Scan 3 repositories for vulnerabilities

**Old Approach** (50k tokens, 45 minutes):
1. Security agent checks in
2. Scans repo 1 (15k tokens, 15m)
3. Scans repo 2 (15k tokens, 15m)
4. Scans repo 3 (15k tokens, 15m)
5. Creates report and handoff

**New Approach** (29k tokens, 15 minutes):
1. Security Master checks in (2k tokens)
2. Spawns 3 scan workers in parallel (3k tokens)
   - Worker 1: scans repo 1 (8k tokens) ⚡
   - Worker 2: scans repo 2 (8k tokens) ⚡
   - Worker 3: scans repo 3 (8k tokens) ⚡
3. Aggregates results (2k tokens)
4. Creates prioritized fix tasks (6k tokens)

**Savings**: 42% tokens, 67% time

---

### Workflow 2: Feature Development (Decomposed)

**Task**: Implement user authentication feature

**Old Approach** (80k+ tokens, would exceed budget):
1. Dev agent reads requirements
2. Designs architecture
3. Implements database models
4. Implements API endpoints
5. Implements frontend components
6. Writes tests
7. Creates documentation
8. Creates PR
**Risk**: Token exhaustion mid-task

**New Approach** (55k tokens, no exhaustion risk):
1. Development Master reads requirements (5k tokens)
2. Decomposes into subtasks (3k tokens)
3. Spawns 4 workers in parallel:
   - Worker A: Database models (8k tokens) ⚡
   - Worker B: API endpoints (10k tokens) ⚡
   - Worker C: Frontend components (10k tokens) ⚡
   - Worker D: Tests (8k tokens) ⚡
4. Master reviews integration (5k tokens)
5. Spawns PR worker (4k tokens)
6. Final verification (2k tokens)

**Benefit**: Task completes successfully, 30% faster

---

### Workflow 3: Emergency Response

**Task**: Critical security vulnerability announced

**Approach**:
1. Coordinator receives GitHub security alert
2. Creates emergency task (uses emergency reserve)
3. Security Master immediately spawns audit workers for ALL repos (10 workers)
4. Workers scan in parallel (80k tokens from emergency pool)
5. Security Master prioritizes findings
6. Spawns fix workers for affected repos
7. Development Master reviews fixes
8. PR workers create urgent PRs

**Timeline**: 30 minutes vs. 4+ hours serially
**Token Usage**: Emergency reserve justifies high usage

---

## Monitoring & Metrics

### Key Performance Indicators (KPIs)

1. **Token Efficiency**
   - Tokens per task (before/after)
   - Master vs. worker token ratio
   - Unused budget percentage

2. **Throughput**
   - Tasks completed per day
   - Worker utilization rate
   - Parallel execution ratio

3. **Quality**
   - Worker success rate
   - Rework percentage
   - Master intervention frequency

4. **Cost**
   - Total tokens used per day
   - Cost per task
   - Emergency reserve usage

### Dashboard View

```
┌─────────────────────────────────────────────────────────┐
│ Commit-Relay System Status - 2025-11-01 10:30 AM       │
├─────────────────────────────────────────────────────────┤
│ MASTERS                                                 │
│  ✓ coordinator-master  [12.5k/50k tokens]  Active      │
│  ✓ security-master     [8k/30k tokens]     Active      │
│  ✓ development-master  [10k/30k tokens]    Active      │
│                                                         │
│ WORKERS (Active: 3 | Completed: 8 | Failed: 0)         │
│  🔄 worker-scan-001    [5.2k/8k]   Running   [12m/15m] │
│  🔄 worker-fix-002     [3.1k/5k]   Running   [8m/20m]  │
│  🔄 worker-impl-003    [7.8k/10k]  Running   [25m/45m] │
│                                                         │
│ TOKEN BUDGET                                            │
│  Daily Budget: 200k  Used: 55.5k (27%)  Available: 144k│
│  Emergency Reserve: 25k (unused)                        │
│                                                         │
│ TASK QUEUE                                              │
│  Pending: 2  |  In Progress: 3  |  Completed Today: 12 │
│                                                         │
│ EFFICIENCY SCORE: 85% ████████████████████░░░░          │
└─────────────────────────────────────────────────────────┘
```

---

## Migration Strategy

### Backward Compatibility

Maintain compatibility during transition:

1. **Dual Mode**: Support both traditional and worker-based execution
2. **Gradual Rollout**: Migrate one master at a time
3. **Fallback**: Traditional execution if worker spawning fails
4. **Feature Flags**: Enable/disable worker mode per agent

### Migration Checklist

- [ ] Create worker-pool.json and token-budget.json
- [ ] Update coordination protocol documentation
- [ ] Build worker prompt templates
- [ ] Implement spawning scripts
- [ ] Test with coordinator master first
- [ ] Migrate security master
- [ ] Migrate development master
- [ ] Monitor token usage and efficiency
- [ ] Deprecate old execution mode
- [ ] Update all documentation

---

## Security Considerations

### Worker Isolation

1. **Token Limits**: Strict enforcement prevents runaway workers
2. **Timeout Enforcement**: Workers auto-terminate after timeout
3. **Scope Restriction**: Workers only access designated repositories
4. **Credential Management**: Workers receive minimal necessary permissions
5. **Output Validation**: Master validates worker results before acceptance

### Token Budget Security

1. **Emergency Reserve**: Protected pool for critical issues only
2. **Budget Alerts**: Notify on unusual token consumption
3. **Audit Trail**: Log all token allocations and usage
4. **Quota Enforcement**: Hard limits prevent over-spending
5. **Master Authorization**: Only masters can spawn workers

---

## Future Enhancements

### Worker Pooling
- Pre-warmed workers for instant task execution
- Worker reuse for similar tasks
- Connection pooling to repositories

### Advanced Scheduling
- Priority queuing with SLA guarantees
- Deadline-aware scheduling
- Cost-optimized task batching

### Machine Learning
- Predict optimal worker count for task types
- Learn token budgets from historical data
- Anomaly detection for failing workers

### Distributed Execution
- Run workers across multiple Claude Code instances
- Geographic distribution for 24/7 operation
- Load balancing across regions

---

## Conclusion

The master-worker architecture transforms commit-relay from a monolithic agent system into a scalable, efficient orchestration platform. By decomposing work and leveraging parallel execution, the system achieves:

- **80-90% token efficiency improvement**
- **3-5x throughput increase**
- **Better budget control**
- **Reduced risk of token exhaustion**
- **Foundation for future scale**

This architecture positions commit-relay as a production-ready multi-agent system capable of managing dozens of repositories autonomously.

---

## Appendices

### Appendix A: Worker Prompt Template Example

See `agents/prompts/workers/scan-worker.md`

### Appendix B: Token Budget Calculation

```python
def calculate_daily_budget():
    """
    Claude Code: 200k tokens per session
    Masters: 3 agents × 30-50k = 110k
    Workers: 90k pool
    Emergency: 25k reserve
    Total: 225k (requires 2 sessions per day)
    """
    pass
```

### Appendix C: Spawning Script Example

See `scripts/spawn-worker.sh`

### Appendix D: Glossary

- **Master Agent**: Long-running orchestration agent
- **Worker Agent**: Ephemeral task-specific agent
- **Token Budget**: Allocated tokens for agent conversation
- **Worker Pool**: Available tokens for spawning workers
- **Emergency Reserve**: Protected tokens for critical tasks
- **Handoff**: Transfer of work between agents
- **Aggregation**: Combining multiple worker results

---

**Document Status**: Ready for review and feedback
**Next Steps**: Phase 1 implementation planning
