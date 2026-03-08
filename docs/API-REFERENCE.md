# commit-relay API Reference

**Total Endpoints**: 128 | **Base URL**: `http://localhost:5001`

---

## Table of Contents

- [Health & Status](#health--status)
- [Metrics & Monitoring](#metrics--monitoring)
- [Worker Management](#worker-management)
- [Task Management](#task-management)
- [MoE Routing & Intelligence](#moe-routing--intelligence)
- [Security & CVE Monitoring](#security--cve-monitoring)
- [Governance & Compliance](#governance--compliance)
- [Event Streaming](#event-streaming)
- [Git Operations](#git-operations)
- [Daemon Management](#daemon-management)
- [AgentStudio](#agentstudio)
- [DDQD Testing](#ddqd-testing)
- [Learning & Analytics](#learning--analytics)
- [System Logs](#system-logs)

---

## Health & Status

### GET /api/health
**Description**: Server health check with uptime
**Response**:
```json
{
  "status": "healthy",
  "uptime": 150.524656792,
  "timestamp": "2025-11-25T19:10:56.601Z"
}
```

### GET /api/system/info
**Description**: System information and configuration

---

## Metrics & Monitoring

### GET /api/metrics
**Description**: Comprehensive system metrics
**APM Instrumented**: ✅
**Response**: Worker stats, task stats, token usage, system health

### GET /api/metrics/history
**Description**: Historical metrics data with time-series

### GET /api/metrics-daemon/status
**Description**: Metrics collection daemon status

---

## Worker Management

### GET /api/workers
**Description**: Live worker pool status from all directories
**APM Instrumented**: ✅
**Custom Span**: `worker-pool-query`
**Custom Labels**:
- `worker.active_count`
- `worker.completed_count`
- `worker.failed_count`
- `worker.total_count`

**Response**:
```json
{
  "version": "2.0-live",
  "active_workers": [...],
  "completed_workers": [...],
  "failed_workers": [...],
  "stats": {
    "total_active": 6,
    "total_completed": 60,
    "total_failed": 0
  }
}
```

### POST /api/worker-restart/start
**Description**: Start worker restart daemon

### POST /api/worker-restart/stop
**Description**: Stop worker restart daemon

---

## Task Management

### GET /api/tasks
**Description**: Task queue information
**APM Instrumented**: ✅
**Custom Span**: `task-queue-query`
**Custom Labels**:
- `task.pending_count`
- `task.active_count`
- `task.completed_count`
- `task.total_count`

### GET /api/execution-managers
**Description**: Execution Manager data (v4.0) with active/completed/failed EMs

---

## MoE Routing & Intelligence

### GET /api/moe-intelligence
**Description**: MoE routing decisions and pattern analysis
**APM Instrumented**: ✅
**Query Parameters**: `range` (1h, 6h, 24h, 7d, 30d)
**Custom Labels**:
- `moe.total_decisions`
- `moe.avg_confidence`
- `moe.most_used_master`
- `moe.unique_strategies`
- `moe.time_range`

**Response**:
```json
{
  "summary": {
    "totalDecisions": 39,
    "avgConfidence": "0.765",
    "mostUsedMaster": "development"
  },
  "routingFlow": {...},
  "confidenceDistribution": {...},
  "masterStatistics": {...}
}
```

### GET /api/moe-learning
**Description**: MoE learning state and routing intelligence

### GET /api/moe/routing
**Description**: Current routing configuration

### GET /api/moe/accuracy
**Description**: Routing accuracy metrics

### GET /api/moe/confidence-distribution
**Description**: Distribution of routing confidence scores

### GET /api/moe/pool-utilization
**Description**: Master agent pool utilization

### GET /api/moe/pool
**Description**: Current pool state

### GET /api/moe/learning
**Description**: Learning system state

### GET /api/moe/learning/deliverables
**Description**: List of learning deliverable files

### GET /api/moe/learning/deliverables/:filename
**Description**: Download specific learning deliverable

---

## Security & CVE Monitoring

### GET /api/security/scans
**Description**: Security scan history with CVE tracking
**APM Instrumented**: ✅
**Query Parameters**: `range` (1h, 6h, 24h, 7d, 30d)
**Custom Span**: `security-scan-history-read`
**Custom Labels**:
- `security.total_scans`
- `security.critical_findings`
- `security.high_findings`
- `security.medium_findings`
- `security.total_vulnerabilities`
- `security.risk_level`
- `security.trend`

**Response**:
```json
{
  "summary": {
    "totalScans": 3,
    "completedScans": 2,
    "latestScan": {
      "findings": {
        "critical": 1,
        "high": 2,
        "medium": 4,
        "low": 2
      },
      "risk_level": "HIGH"
    },
    "trend": "decreasing"
  },
  "aggregatedFindings": {...},
  "vulnerabilityTrend": [...]
}
```

### GET /api/security/current
**Description**: Current security posture with real-time CVE status
**APM Instrumented**: ✅
**Custom Labels**:
- `security.current_risk`
- `security.health_score`
- `security.requires_attention`

**Response**:
```json
{
  "lastScanned": "2025-11-23T19:52:38.000Z",
  "riskLevel": "HIGH",
  "findings": {
    "critical": 1,
    "high": 2,
    "medium": 4,
    "low": 2,
    "total": 9
  },
  "requiresAttention": true,
  "healthScore": 8
}
```

---

## Governance & Compliance

### GET /api/governance/compliance-report
**Description**: Complete compliance report

### GET /api/governance/compliance-check/:framework
**Description**: Check compliance for specific framework (SOC2, GDPR, HIPAA)

### GET /api/governance/metrics
**Description**: Governance metrics across all components

### GET /api/governance/trends
**Description**: 30-day governance trend analysis

---

## Event Streaming

### GET /api/events
**Description**: Read coordination events with filtering and sorting
**Query Parameters**: `type`, `severity`, `limit`, `offset`

### GET /api/activity-feed
**Description**: Real-time activity feed with event aggregation

### GET /api/event-log/info
**Description**: Event log statistics and information

---

## Git Operations

### GET /api/git-status
**Description**: Repository git status

### GET /api/git-operations
**Description**: Recent git operations history

### GET /api/git-info
**Description**: Git repository information

---

## Daemon Management

### GET /api/daemons/all
**Description**: Status of all system daemons

### GET /api/daemon/status
**Description**: Individual daemon status

### GET /api/coordinator-daemon/status
**Description**: Coordinator daemon status

### GET /api/health-daemon/status
**Description**: Health monitor daemon status

### POST /api/health-monitor/start
**Description**: Start health monitoring daemon

### POST /api/health-monitor/stop
**Description**: Stop health monitoring daemon

### POST /api/metrics-snapshot/start
**Description**: Start metrics snapshot daemon

### POST /api/metrics-snapshot/stop
**Description**: Stop metrics snapshot daemon

### POST /api/heartbeat-monitor/start
**Description**: Start heartbeat monitoring daemon

### POST /api/heartbeat-monitor/stop
**Description**: Stop heartbeat monitoring daemon

### POST /api/learning-monitor/start
**Description**: Start learning monitor daemon

### POST /api/learning-monitor/stop
**Description**: Stop learning monitor daemon

### POST /api/daemon-supervisor/start
**Description**: Start daemon supervisor

### POST /api/daemon-supervisor/stop
**Description**: Stop daemon supervisor

### POST /api/zombie-cleanup/start
**Description**: Start zombie cleanup daemon

### POST /api/zombie-cleanup/stop
**Description**: Stop zombie cleanup daemon

### POST /api/handoff-processor/start
**Description**: Start handoff processor daemon

### POST /api/handoff-processor/stop
**Description**: Stop handoff processor daemon

### POST /api/threat-intel/start
**Description**: Start threat intelligence daemon

### POST /api/threat-intel/stop
**Description**: Stop threat intelligence daemon

### POST /api/backup/start
**Description**: Start backup daemon

### POST /api/backup/stop
**Description**: Stop backup daemon

---

## AgentStudio

### GET /api/agentstudio/agents
**Description**: List all registered agents

### GET /api/agentstudio/agents/:id
**Description**: Get specific agent details

### POST /api/agentstudio/agents
**Description**: Register new agent

### PUT /api/agentstudio/agents/:id
**Description**: Update agent configuration

### DELETE /api/agentstudio/agents/:id
**Description**: Deregister agent

### GET /api/agentstudio/registry/summary
**Description**: Agent registry summary statistics

### GET /api/agentstudio/templates
**Description**: List available agent templates

---

## DDQD Testing

### GET /api/ddqd-testing
**Description**: DDQD (Distributed Dynamic Quality Deployment) testing status

### GET /api/ddqd/status/:testId
**Description**: Get specific DDQD test status

### GET /api/ddqd/history
**Description**: DDQD test execution history

### GET /api/ddqd/active
**Description**: Currently active DDQD tests

### GET /api/ddqd/schedule
**Description**: Scheduled DDQD tests

### POST /api/ddqd/schedule
**Description**: Schedule new DDQD test

---

## Learning & Analytics

### GET /api/learning-monitor/status
**Description**: Learning monitor daemon status

### GET /api/learning-monitor/events
**Description**: Learning-related events

### GET /api/optimizer/pool/stats
**Description**: Pool optimizer statistics

### GET /api/optimizer/profile/bottlenecks
**Description**: Performance bottleneck analysis

---

## System Logs

### GET /api/logs/available
**Description**: List available log files

### GET /api/logs/tail
**Description**: Tail log file in real-time
**Query Parameters**: `file`, `lines`

### GET /api/logs/stream
**Description**: Stream log file with Server-Sent Events

---

## Health Alerts

### GET /api/health-alerts
**Description**: Get all health alerts with enrichment

### DELETE /api/health-alerts/:id
**Description**: Dismiss health alert

### POST /api/health-alerts/:id/restart-worker
**Description**: Restart worker from health alert

---

## Coordination

### GET /api/coordination/raw
**Description**: Raw coordination data

### GET /api/streams
**Description**: Worker stream information

---

## User Management

### DELETE /api/users/:id
**Description**: Delete user (if user management is enabled)

---

## Integration Validator

### GET /api/integration-validator/status
**Description**: Integration validator status

---

## APM Instrumented Endpoints

The following endpoints have full Elastic APM instrumentation with custom spans and labels:

| Endpoint | Custom Spans | Labels | Purpose |
|----------|--------------|--------|---------|
| `/api/workers` | `worker-pool-query` | worker.* | Worker pool metrics |
| `/api/tasks` | `task-queue-query` | task.* | Task queue metrics |
| `/api/moe-intelligence` | - | moe.* | MoE routing metrics |
| `/api/security/scans` | `security-scan-history-read` | security.* | CVE tracking |
| `/api/security/current` | - | security.* | Real-time security |

---

## Rate Limiting

**Default Rate Limit**: 100 requests per minute per IP
**Applied to**: GET requests
**Headers**:
- `X-RateLimit-Limit`: Maximum requests allowed
- `X-RateLimit-Remaining`: Requests remaining
- `X-RateLimit-Reset`: Time when limit resets

---

## Error Responses

### 400 Bad Request
```json
{
  "error": "Invalid request parameters"
}
```

### 404 Not Found
```json
{
  "error": "Resource not found"
}
```

### 429 Too Many Requests
```json
{
  "error": "Rate limit exceeded"
}
```

### 500 Internal Server Error
```json
{
  "error": "Internal server error"
}
```

---

## WebSocket Support

**Endpoint**: `ws://localhost:5001`
**Events**: Real-time worker, task, and system events

---

## Elastic APM Integration

All instrumented endpoints send the following telemetry to Elastic Cloud:
- Transaction duration and throughput
- Custom spans for expensive operations
- Custom labels for business metrics
- Error tracking with stack traces
- Distributed tracing support

**View in Kibana**: [See Observability Setup Guide](./QUICK-START-MONITORING.md)

---

## Developer Resources

- **Full Integration Examples**: `api-server/server/examples/apm-instrumentation-examples.js`
- **APM Events Utilities**: `api-server/server/utils/apm-events.js`
- **Quick Start Guide**: `docs/QUICK-START-MONITORING.md`
- **Dashboard Setup**: `docs/KIBANA-DASHBOARD-SETUP.md`

---

**Last Updated**: 2025-11-25
**API Version**: 2.0
**Server**: commit-relay API Server
