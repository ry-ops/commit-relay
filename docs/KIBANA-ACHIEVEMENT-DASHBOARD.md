# Kibana Achievement Dashboard Setup

**Real-time GitHub Achievement Progress Monitoring**

This guide shows how to create visualizations in Kibana for tracking GitHub achievement progress via commit-relay's Achievement Master.

---

## Prerequisites

- Elastic APM configured (see [QUICK-START-MONITORING.md](./QUICK-START-MONITORING.md))
- commit-relay API server running on `http://localhost:5001`
- GitHub token configured (`GITHUB_TOKEN` environment variable)
- Achievement Master endpoints active

---

## Dashboard Overview

The Achievement Dashboard provides:

1. **Progress Gauge** - Overall achievement completion percentage
2. **Opportunity Chart** - Top achievement opportunities by score
3. **Tier Progress Table** - Current tier and progress for each achievement
4. **Workflow Timeline** - Automation workflow execution history
5. **Unlock Events Stream** - Real-time achievement unlock notifications

---

## Visualization 1: Achievement Progress Gauge

**Purpose**: Show overall achievement completion percentage

### Steps

1. Navigate to Kibana → **Visualize** → **Create visualization**
2. Select **Gauge** visualization type
3. Configure data source:
   - **Index pattern**: `apm-*`
   - **Metrics**:
     - Aggregation: `Unique Count`
     - Field: `labels.achievement.unlocked`
   - **Bucket**:
     - Aggregation: `Terms`
     - Field: `transaction.name.keyword`
     - Filter: `/api/achievements/progress`

4. **Gauge Options**:
   - Min: 0
   - Max: 8 (total earnable achievements)
   - Color ranges:
     - 0-2: Red
     - 3-5: Yellow
     - 6-8: Green

5. **Save**: "GitHub Achievements - Progress"

---

## Visualization 2: Opportunity Score Bar Chart

**Purpose**: Show which achievements are easiest to unlock next

### Steps

1. **Create visualization** → **Vertical Bar**
2. Configure:
   - **Index pattern**: `apm-*`
   - **Y-axis**:
     - Aggregation: `Average`
     - Field: `labels.achievement.top_score`
   - **X-axis**:
     - Aggregation: `Terms`
     - Field: `labels.achievement.top_opportunity.keyword`
     - Order by: `labels.achievement.top_score` descending
     - Size: 10

3. **Color**:
   - High priority (80-100): Green
   - Medium (60-79): Yellow
   - Low (<60): Red

4. **Save**: "Achievement Opportunities - Top 10"

---

## Visualization 3: Tier Progress Table

**Purpose**: Detailed progress for each achievement

### Steps

1. **Create visualization** → **Data Table**
2. Configure:
   - **Columns**:
     1. Achievement Name (`labels.achievement.*`)
     2. Current Count (`metric`)
     3. Current Tier (`labels.achievement.tier`)
     4. Progress % (`percentage` field)
     5. Next Requirement (`labels.achievement.next_requirement`)

3. **Filters**:
   - Transaction: `/api/achievements/progress`
   - Time range: Last 1 hour

4. **Save**: "Achievement Progress - Detailed Table"

---

## Visualization 4: Workflow Execution Timeline

**Purpose**: Track automation workflow successes/failures

### Steps

1. **Create visualization** → **Timeline**
2. Configure:
   - **Time field**: `@timestamp`
   - **Categories**:
     - Quickdraw workflows
     - PR automation workflows
     - Discussion responses

3. **Metrics**:
   - Total executions
   - Success rate
   - Average execution time

4. **Filters**:
   - Add filter: `transaction.name` contains `achievements/execute`

5. **Save**: "Achievement Workflows - Execution Timeline"

---

## Visualization 5: Achievement Unlock Events

**Purpose**: Stream of achievement unlock events

### Steps

1. **Create visualization** → **Table**
2. Configure:
   - **Index pattern**: `apm-*`
   - **Columns**:
     - Timestamp
     - Achievement unlocked
     - Previous tier
     - New tier
     - Progress made

3. **Filters**:
   - `labels.achievement.unlocked` > 0
   - OR `labels.achievement.tier` changed

4. **Sorting**: Timestamp descending (most recent first)

5. **Save**: "Achievement Unlocks - Event Stream"

---

## Dashboard Assembly

### Create Dashboard

1. Kibana → **Dashboard** → **Create dashboard**
2. Add visualizations:
   - Top row: Progress Gauge (large)
   - Second row: Opportunity Chart, Tier Progress Table
   - Third row: Workflow Timeline
   - Bottom: Unlock Events Stream

3. **Arrange layout**:
   ```
   ┌─────────────────────────────────────────┐
   │   Achievement Progress Gauge            │
   │        (Unlocked / Total)               │
   └─────────────────────────────────────────┘

   ┌──────────────────┬──────────────────────┐
   │  Opportunity     │  Tier Progress       │
   │  Score Chart     │  Table               │
   └──────────────────┴──────────────────────┘

   ┌─────────────────────────────────────────┐
   │   Workflow Execution Timeline           │
   └─────────────────────────────────────────┘

   ┌─────────────────────────────────────────┐
   │   Achievement Unlock Events             │
   └─────────────────────────────────────────┘
   ```

4. **Save dashboard**: "GitHub Achievements - Master Dashboard"

---

## Custom Queries

### Query 1: Achievements Unlocked This Week

```
@timestamp >= now-7d AND
labels.achievement.unlocked > 0
```

### Query 2: High-Opportunity Achievements

```
labels.achievement.top_score >= 80
```

### Query 3: Failed Workflow Executions

```
transaction.name: "/api/achievements/execute/*" AND
transaction.result: "failure"
```

### Query 4: Pull Shark Progress

```
labels.achievement.top_opportunity: "Pull Shark"
```

---

## Metrics to Monitor

### Key Performance Indicators (KPIs)

1. **Achievement Completion Rate**
   - Formula: `(unlocked / total) * 100`
   - Target: 75% (6/8 achievements)

2. **Weekly Achievement Velocity**
   - Formula: `achievements unlocked per week`
   - Target: 1+ per week

3. **Automation Success Rate**
   - Formula: `(successful workflows / total workflows) * 100`
   - Target: 95%+

4. **Average Opportunity Score**
   - Formula: `average(opportunity_scores)`
   - Target: 60+

---

## Alert Rules

### Alert 1: High-Opportunity Achievement Available

**Trigger**: `labels.achievement.top_score >= 90`

**Actions**:
- Send Slack notification
- Create task in coordination queue
- Log to achievement metrics

**Template**:
```
🎯 High-value achievement available!

Achievement: {{labels.achievement.top_opportunity}}
Score: {{labels.achievement.top_score}}/100
Strategy: {{labels.achievement.top_strategy}}

Action: Execute automation workflow
```

### Alert 2: Achievement Unlocked!

**Trigger**: `labels.achievement.unlocked` increases

**Actions**:
- Send celebration notification
- Update dashboard
- Log to achievement history

**Template**:
```
🎉 Achievement Unlocked!

{{labels.achievement.name}} - {{labels.achievement.tier}}

Progress: {{labels.achievement.unlocked}}/8 achievements
```

### Alert 3: Workflow Failure

**Trigger**: `/api/achievements/execute/*` returns error

**Actions**:
- Alert development team
- Log error details
- Create debugging task

**Template**:
```
❌ Achievement workflow failed

Workflow: {{transaction.name}}
Error: {{error.message}}

Action: Review workflow logs
```

---

## Data Sources

Achievement Master provides data through multiple channels:

### 1. APM Transaction Labels

```javascript
{
  'achievement.total': 8,
  'achievement.unlocked': 3,
  'achievement.in_progress': 2,
  'achievement.top_opportunity': 'Quickdraw',
  'achievement.top_score': 96,
  'achievement.top_strategy': 'instant_fix',
  'achievement.plan_tasks': 3,
  'achievement.immediate_wins': 2,
  'achievement.high_priority': 1
}
```

### 2. JSONL Metrics Files

**Location**: `coordination/masters/achievement/metrics/`

**Files**:
- `tracking-history.jsonl` - Achievement progress over time
- `plan-history.jsonl` - Strategic planning history
- `quickdraw-attempts.jsonl` - Quickdraw workflow results
- `pr-automation-history.jsonl` - PR automation logs

**Ingestion**: Use Filebeat to ingest into Elasticsearch

### 3. API Endpoints

**Base URL**: `http://localhost:5001/api/achievements/`

**Endpoints**:
- `/progress` - Real-time GitHub API data
- `/opportunities` - Opportunity scores
- `/plan` - Strategic plan
- `/metrics` - Historical metrics
- `/definitions` - Achievement metadata

---

## Refresh Settings

**Recommended refresh intervals**:

- **Dashboard auto-refresh**: 5 minutes
- **Progress gauge**: 10 minutes
- **Opportunity chart**: 5 minutes
- **Workflow timeline**: 1 minute (real-time)
- **Unlock events**: 30 seconds (real-time)

---

## Example Dashboard JSON

Save this as a Kibana dashboard import:

```json
{
  "title": "GitHub Achievements - Master Dashboard",
  "description": "Real-time achievement progress and automation monitoring",
  "panelsJSON": "[...]",
  "optionsJSON": "{\"darkTheme\":false}",
  "refreshInterval": {
    "pause": false,
    "value": 300000
  },
  "timeRestore": true,
  "timeFrom": "now-24h",
  "timeTo": "now"
}
```

---

## Advanced Features

### 1. Achievement Prediction

Use ML jobs to predict when achievements will be unlocked:

```
Machine Learning → Create job → "Achievement Unlock Prediction"
- Analyze: labels.achievement.unlocked
- Detect: Sudden increases
- Bucket span: 1 hour
```

### 2. Anomaly Detection

Detect unusual patterns in achievement progress:

```
Machine Learning → Create job → "Achievement Progress Anomaly"
- Analyze: labels.achievement.top_score
- Detect: Unusual drops (workflow failures)
- Bucket span: 6 hours
```

### 3. Custom Metrics

Create calculated fields for advanced metrics:

```
Achievement Velocity =
  (current_unlocked - previous_unlocked) / time_elapsed

Automation ROI =
  (achievements_unlocked_automated / total_workflow_executions) * 100

Time to Achievement =
  avg(time_to_unlock_per_achievement)
```

---

## Troubleshooting

### Issue: No data in visualizations

**Solution**:
1. Verify API server is running: `http://localhost:5001/api/achievements/progress`
2. Check GitHub token: `echo $GITHUB_TOKEN`
3. Verify APM is receiving data: Check `apm-*` indices
4. Test endpoint manually: `curl http://localhost:5001/api/achievements/progress`

### Issue: Outdated progress data

**Solution**:
1. Achievement data is cached by GitHub API (5-minute TTL)
2. Force refresh: Call `/api/achievements/progress?force=true`
3. Verify dashboard refresh interval is enabled

### Issue: Workflows not executing

**Solution**:
1. Check workflow logs: `coordination/masters/achievement/metrics/*-history.jsonl`
2. Verify GitHub token has required permissions (repo, workflow)
3. Test workflow manually: `bash coordination/masters/achievement/workflows/quickdraw-workflow.sh test`

---

## Best Practices

1. **Set up alerts** for high-opportunity achievements (score >= 80)
2. **Monitor automation success rate** - should be 95%+
3. **Review workflow failures** within 1 hour
4. **Track weekly velocity** - aim for 1+ achievement per week
5. **Use time-based comparisons** to measure improvement
6. **Export dashboard as PDF** for weekly reports

---

## Next Steps

1. ✅ Create dashboard visualizations
2. ✅ Set up alert rules
3. ✅ Configure refresh intervals
4. ⏭️ Execute first automation workflow
5. ⏭️ Monitor progress in real-time
6. ⏭️ Iterate on strategies based on data

---

## Resources

- [Achievement Master README](../coordination/masters/achievement/README.md)
- [API Reference](./API-REFERENCE.md#achievement-master-endpoints)
- [Kibana Dashboard Setup](./KIBANA-DASHBOARD-SETUP.md)
- [GitHub Achievements Guide](https://github.com/Schweinepriester/github-profile-achievements)

---

**Built with commit-relay Achievement Master** 🏆
