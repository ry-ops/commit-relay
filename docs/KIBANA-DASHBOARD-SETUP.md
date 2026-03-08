# Kibana Dashboard Setup for commit-relay

## Overview

This guide provides step-by-step instructions for creating custom dashboards and alerts in Kibana to monitor commit-relay operations, including:
- Worker pool metrics
- Task queue monitoring
- MoE routing intelligence
- Security/CVE tracking
- Performance metrics

## Prerequisites

- Elastic Cloud account with APM enabled
- commit-relay API server running with APM instrumentation
- Access to Kibana

---

## Part 1: Create Custom Visualizations

### 1.1 Worker Pool Health Visualization

**Type**: Line Chart
**Purpose**: Track active, completed, and failed workers over time

1. Go to **Analytics** → **Visualize Library** → **Create visualization**
2. Select **Lens**
3. Configure:
   - **Index pattern**: `apm-*`
   - **Filter**: `transaction.name: "GET /api/workers"`
   - **X-axis**: `@timestamp` (Date histogram, 5 minute intervals)
   - **Y-axis (series 1)**: Average of `labels.worker.active_count`
   - **Y-axis (series 2)**: Average of `labels.worker.completed_count`
   - **Y-axis (series 3)**: Average of `labels.worker.failed_count`
4. **Save** as "Worker Pool Health"

### 1.2 Task Queue Depth

**Type**: Area Chart
**Purpose**: Monitor task backlog

1. Create new **Lens** visualization
2. Configure:
   - **Index pattern**: `apm-*`
   - **Filter**: `transaction.name: "GET /api/tasks"`
   - **X-axis**: `@timestamp` (Date histogram, 1 minute intervals)
   - **Y-axis (stacked)**:
     - `labels.task.pending_count` (Pending)
     - `labels.task.active_count` (Active)
     - `labels.task.completed_count` (Completed)
3. **Save** as "Task Queue Depth"

### 1.3 MoE Routing Confidence

**Type**: Gauge
**Purpose**: Show average routing confidence

1. Create new **Lens** visualization
2. Select **Metric** type
3. Configure:
   - **Index pattern**: `apm-*`
   - **Filter**: `transaction.name: "GET /api/moe-intelligence"`
   - **Metric**: Average of `labels.moe.avg_confidence`
   - **Display**: Gauge with thresholds:
     - 0-0.5: Red
     - 0.5-0.7: Yellow
     - 0.7-1.0: Green
4. **Save** as "MoE Routing Confidence"

### 1.4 Security Health Score

**Type**: Metric with Trend
**Purpose**: Display current security posture

1. Create new **Lens** visualization
2. Configure:
   - **Index pattern**: `apm-*`
   - **Filter**: `transaction.name: "GET /api/security/current"`
   - **Metric**: Latest value of `labels.security.health_score`
   - **Trend**: Line showing last 24 hours
3. **Save** as "Security Health Score"

### 1.5 CVE Vulnerability Breakdown

**Type**: Pie Chart
**Purpose**: Show distribution of security findings by severity

1. Create new **Lens** visualization
2. Select **Donut** chart
3. Configure:
   - **Index pattern**: `apm-*`
   - **Filter**: `transaction.name: "GET /api/security/scans"`
   - **Slices**:
     - Critical: `labels.security.critical_findings`
     - High: `labels.security.high_findings`
     - Medium: `labels.security.medium_findings`
   - **Colors**: Red (Critical), Orange (High), Yellow (Medium)
4. **Save** as "CVE Vulnerability Breakdown"

### 1.6 API Response Time by Endpoint

**Type**: Heat Map
**Purpose**: Identify slow endpoints

1. Create new **Lens** visualization
2. Configure:
   - **Index pattern**: `apm-*`
   - **X-axis**: `@timestamp` (Date histogram, 15 minute intervals)
   - **Y-axis**: `transaction.name`
   - **Cell value**: Average of `transaction.duration.us`
   - **Color scale**: 0-50ms (Green), 50-200ms (Yellow), 200ms+ (Red)
3. **Save** as "API Response Time Heatmap"

### 1.7 MoE Master Utilization

**Type**: Bar Chart
**Purpose**: Show which masters are used most often

1. Create new **Lens** visualization
2. Configure:
   - **Index pattern**: `apm-*`
   - **Filter**: `labels.moe.most_used_master:*`
   - **X-axis**: `labels.moe.most_used_master`
   - **Y-axis**: Count of records
3. **Save** as "MoE Master Utilization"

### 1.8 Worker Failure Rate

**Type**: Metric
**Purpose**: Calculate and display worker failure percentage

1. Create new **Lens** visualization
2. Configure:
   - **Index pattern**: `apm-*`
   - **Filter**: `transaction.name: "GET /api/workers"`
   - **Formula**:
     ```
     (average(labels.worker.failed_count) /
      (average(labels.worker.failed_count) + average(labels.worker.completed_count))) * 100
     ```
   - **Format**: Percentage with 1 decimal
4. **Save** as "Worker Failure Rate"

---

## Part 2: Create Dashboard

### 2.1 Create Main Dashboard

1. Go to **Analytics** → **Dashboard** → **Create dashboard**
2. Click **Add from library**
3. Add all visualizations created above:
   - Worker Pool Health (top left, full width)
   - Task Queue Depth (below worker pool)
   - MoE Routing Confidence (top right, gauge)
   - Security Health Score (below MoE gauge)
   - CVE Vulnerability Breakdown (middle right)
   - API Response Time Heatmap (bottom, full width)
   - MoE Master Utilization (bottom left)
   - Worker Failure Rate (bottom right)

4. Arrange in a 3-column layout:
```
┌─────────────────────────────────────────────────────────┐
│          Worker Pool Health (Line Chart)                │
├─────────────────────────────────────┬───────────────────┤
│     Task Queue Depth (Area)         │ MoE Confidence    │
│                                      │ (Gauge)           │
│                                      ├───────────────────┤
│                                      │ Security Health   │
│                                      │ (Metric)          │
│                                      ├───────────────────┤
│                                      │ CVE Breakdown     │
│                                      │ (Pie Chart)       │
├─────────────────────────────────────┴───────────────────┤
│       API Response Time Heatmap (Full Width)            │
├──────────────────────────┬──────────────────────────────┤
│ MoE Master Utilization   │   Worker Failure Rate        │
│ (Bar Chart)              │   (Metric)                   │
└──────────────────────────┴──────────────────────────────┘
```

5. **Save** as "commit-relay Operations Dashboard"

### 2.2 Add Time Range Selector

1. Click **Options** (top right)
2. Enable **Show time range selector**
3. Set default to **Last 1 hour**

### 2.3 Add Refresh Rate

1. Click refresh icon (top right)
2. Set to **Auto-refresh every 30 seconds**

---

## Part 3: Set Up Alerts

### 3.1 High Worker Failure Rate Alert

**Purpose**: Alert when worker failure rate exceeds 10%

1. Go to **Observability** → **Alerts and rules** → **Create rule**
2. Select **APM rule** → **Transaction error rate**
3. Configure:
   - **Name**: "High Worker Failure Rate"
   - **Service**: commit-relay
   - **Transaction type**: All
   - **Check every**: 1 minute
   - **Threshold**: Error rate > 10% for 5 minutes
   - **Severity**: High
4. **Actions**:
   - Send email to: ops-team@example.com
   - Post to Slack: #commit-relay-alerts
5. **Save**

### 3.2 Low MoE Confidence Alert

**Purpose**: Alert when routing confidence drops below threshold

1. Create new **Custom threshold** rule
2. Configure:
   - **Name**: "Low MoE Routing Confidence"
   - **Index**: `apm-*`
   - **When**: Average of `labels.moe.avg_confidence` is below 0.5
   - **For the last**: 15 minutes
   - **Check every**: 5 minutes
   - **Severity**: Medium
3. **Actions**:
   - Post to Slack: #commit-relay-alerts
4. **Save**

### 3.3 Critical Security Vulnerability Detected

**Purpose**: Alert immediately when critical CVEs are found

1. Create new **Custom threshold** rule
2. Configure:
   - **Name**: "Critical CVE Detected"
   - **Index**: `apm-*`
   - **When**: `labels.security.critical_findings` is above 0
   - **For the last**: 1 minute
   - **Check every**: 1 minute
   - **Severity**: Critical
3. **Actions**:
   - Send email to: security-team@example.com
   - Post to Slack: #security-alerts
   - Create PagerDuty incident
4. **Save**

### 3.4 High Task Queue Backlog

**Purpose**: Alert when task queue gets backed up

1. Create new **Custom threshold** rule
2. Configure:
   - **Name**: "High Task Queue Backlog"
   - **Index**: `apm-*`
   - **When**: `labels.task.pending_count` is above 50
   - **For the last**: 10 minutes
   - **Check every**: 5 minutes
   - **Severity**: Medium
3. **Actions**:
   - Post to Slack: #commit-relay-alerts
4. **Save**

### 3.5 API Response Time Degradation

**Purpose**: Alert when API becomes slow

1. Create new **APM** → **Transaction duration anomaly** rule
2. Configure:
   - **Name**: "API Response Time Degradation"
   - **Service**: commit-relay
   - **Transaction type**: request
   - **Anomaly severity**: Major
   - **Check every**: 1 minute
   - **Severity**: High
3. **Actions**:
   - Post to Slack: #commit-relay-alerts
4. **Save**

### 3.6 Security Health Score Low

**Purpose**: Alert when overall security posture degrades

1. Create new **Custom threshold** rule
2. Configure:
   - **Name**: "Security Health Score Low"
   - **Index**: `apm-*`
   - **When**: `labels.security.health_score` is below 60
   - **For the last**: 5 minutes
   - **Check every**: 5 minutes
   - **Severity**: High
3. **Actions**:
   - Send email to: security-team@example.com
   - Post to Slack: #security-alerts
4. **Save**

---

## Part 4: Advanced Queries

### 4.1 Find Slow Database Operations

```
transaction.type: "db" AND transaction.duration.us > 100000
```

### 4.2 Track Worker Lifecycle

```
labels.agent.event.type: "spawned" OR labels.agent.event.type: "completed" OR labels.agent.event.type: "failed"
```

### 4.3 Monitor High-Confidence MoE Decisions

```
labels.moe.avg_confidence > 0.8 AND labels.moe.total_decisions > 10
```

### 4.4 Security Scans with Critical Findings

```
transaction.name: "GET /api/security/scans" AND labels.security.critical_findings > 0
```

### 4.5 Correlated Performance and Worker Issues

```
transaction.duration.us > 200000 AND labels.worker.active_count > 20
```

---

## Part 5: Dashboard Sharing

### 5.1 Export Dashboard

1. Go to **Analytics** → **Dashboard**
2. Open "commit-relay Operations Dashboard"
3. Click **Share** → **Export**
4. Save as `commit-relay-dashboard.ndjson`

### 5.2 Import to Another Environment

1. Go to **Stack Management** → **Saved Objects**
2. Click **Import**
3. Upload `commit-relay-dashboard.ndjson`
4. Click **Import**

---

## Part 6: Monitoring Best Practices

### 6.1 Daily Checks

- Review Security Health Score
- Check Worker Failure Rate
- Verify no critical alerts

### 6.2 Weekly Reviews

- Analyze MoE routing patterns
- Review API response time trends
- Check for security vulnerabilities
- Optimize slow transactions

### 6.3 Monthly Audits

- Review all alert thresholds
- Update dashboard visualizations
- Archive old metrics data
- Performance optimization review

---

## Troubleshooting

### Dashboard Not Showing Data

1. Verify APM server is running: `ps aux | grep node`
2. Check APM logs: `cat /tmp/apm-server.log`
3. Verify data in APM: Go to APM → Services → commit-relay
4. Check time range in dashboard (try "Last 24 hours")

### Custom Labels Not Appearing

1. Verify custom instrumentation is active
2. Generate traffic: `curl http://localhost:5001/api/workers`
3. Wait 30-60 seconds for data ingestion
4. Refresh Kibana dashboard

### Alerts Not Firing

1. Check alert rule status in **Alerts and rules**
2. Verify alert conditions match current data
3. Check connector configuration (Slack, email)
4. Review alert execution logs

---

## Additional Resources

- [Kibana Dashboard Documentation](https://www.elastic.co/guide/en/kibana/current/dashboard.html)
- [APM Custom Dashboards](https://www.elastic.co/guide/en/kibana/current/apm-custom-dashboards.html)
- [Alerting in Kibana](https://www.elastic.co/guide/en/kibana/current/alerting-getting-started.html)
- commit-relay APM Integration Guide: [docs/APM-INTEGRATION.md](./APM-INTEGRATION.md)

---

**Last Updated**: 2025-11-25
**Version**: 1.0
**Status**: Ready for Use
