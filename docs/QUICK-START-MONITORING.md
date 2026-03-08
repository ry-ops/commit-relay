# Quick Start: commit-relay Monitoring & Observability

## 5-Minute Setup

### Prerequisites
- ✅ Elastic Cloud account with APM
- ✅ commit-relay running with APM enabled
- ✅ You can see metrics in Kibana (completed earlier)

---

## Step 1: Verify APM is Working (1 minute)

```bash
# Check server is running
ps aux | grep "node server/index.js"

# Generate test traffic
curl http://localhost:5001/api/health
curl http://localhost:5001/api/workers
curl http://localhost:5001/api/security/current

# Check Kibana
# Go to: Observability → APM → Services → commit-relay
# You should see transactions appearing
```

**Expected**: You see `commit-relay` service with recent transactions

---

## Step 2: Create Your First Visualization (3 minutes)

### Option A: Security Health Score (Quickest)

1. **Go to Kibana** → **Analytics** → **Visualize Library**
2. Click **Create visualization** → **Lens**
3. Configure:
   - Index: `apm-*`
   - Filter: `transaction.name: "GET /api/security/current"`
   - Visualization type: **Metric**
   - Field: `labels.security.health_score` (Average)
4. Click **Save** → Name it "Security Health Score"

### Option B: Worker Pool Status (Most Useful)

1. **Visualize Library** → **Create** → **Lens**
2. Configure:
   - Index: `apm-*`
   - Filter: `transaction.name: "GET /api/workers"`
   - Visualization: **Line**
   - X-axis: `@timestamp` (Date histogram, 5m intervals)
   - Y-axis: Add 3 series:
     - `labels.worker.active_count` (Average) - Blue
     - `labels.worker.completed_count` (Average) - Green
     - `labels.worker.failed_count` (Average) - Red
3. **Save** as "Worker Pool Health"

---

## Step 3: Create Simple Dashboard (1 minute)

1. **Analytics** → **Dashboard** → **Create dashboard**
2. **Add from library** → Select your visualizations
3. Arrange them on the canvas
4. Click **Options** (top right):
   - Enable **Show time range selector**
   - Set default to **Last 1 hour**
5. Click refresh icon → **Auto-refresh every 30 seconds**
6. **Save** as "commit-relay Monitor"

---

## Step 4: Set Up Critical Alert (2 minutes)

### Alert: Critical CVE Detected

1. **Observability** → **Alerts and rules** → **Create rule**
2. Select **Custom threshold**
3. Configure:
   - **Name**: Critical CVE Detected
   - **Index pattern**: `apm-*`
   - **WHEN**: `labels.security.critical_findings` IS ABOVE `0`
   - **FOR THE LAST**: 1 minute
   - **Check every**: 1 minute
4. **Actions**:
   - For now, just add **Webhook** or **Email** (set up later)
5. Click **Save**

---

## What You Can See Right Now

### In Kibana APM

Navigate: **Observability** → **APM** → **Services** → **commit-relay**

#### 1. Transactions Tab
- See all API endpoint calls
- Response times
- Throughput (requests/minute)
- Error rate

#### 2. Click any transaction (e.g., GET /api/workers)
- See timeline of the request
- Custom span: `worker-pool-query` (file I/O time)
- Custom labels with metrics

#### 3. Dependencies Tab
- External services called
- Database operations
- LLM API calls (once instrumented)

---

## Available Custom Metrics

### Worker Pool
```
labels.worker.active_count      - Currently running workers
labels.worker.completed_count   - Successfully completed workers
labels.worker.failed_count      - Failed workers
labels.worker.total_count       - Total workers
```

### Task Queue
```
labels.task.pending_count       - Tasks waiting to start
labels.task.active_count        - Currently running tasks
labels.task.completed_count     - Finished tasks
labels.task.total_count         - Total tasks
```

### MoE Routing
```
labels.moe.total_decisions      - Number of routing decisions
labels.moe.avg_confidence       - Average confidence score
labels.moe.most_used_master     - Most frequently used master
labels.moe.unique_strategies    - Number of routing strategies
```

### Security/CVE
```
labels.security.critical_findings    - Critical vulnerabilities
labels.security.high_findings        - High severity issues
labels.security.medium_findings      - Medium severity issues
labels.security.total_vulnerabilities- Total vulnerabilities
labels.security.risk_level          - Overall risk level
labels.security.health_score        - Security health (0-100)
labels.security.trend               - Trend (increasing/decreasing)
```

---

## Useful Kibana Queries

### Find Slow Operations
```
transaction.duration.us > 100000
```

### Monitor High Vulnerability Count
```
labels.security.critical_findings > 0
```

### Track High Worker Activity
```
labels.worker.active_count > 5
```

### Low MoE Confidence
```
labels.moe.avg_confidence < 0.5
```

### Find Errors
```
transaction.result: "HTTP 5xx"
```

---

## Testing Your Setup

### Generate Load for Testing

```bash
# Create test traffic script
cat > /tmp/generate-traffic.sh << 'EOF'
#!/bin/bash
echo "Generating test traffic..."
for i in {1..50}; do
  curl -s http://localhost:5001/api/workers > /dev/null
  curl -s http://localhost:5001/api/tasks > /dev/null
  curl -s http://localhost:5001/api/security/current > /dev/null
  curl -s http://localhost:5001/api/moe-intelligence > /dev/null
  echo "Request batch $i sent"
  sleep 1
done
echo "Test traffic complete!"
EOF

chmod +x /tmp/generate-traffic.sh

# Run it
/tmp/generate-traffic.sh
```

**Watch in Kibana**: You should see transaction rate increase in real-time!

---

## Next Steps

### Today (30 minutes):
1. ✅ Create 2-3 key visualizations
2. ✅ Set up one critical alert
3. ✅ Bookmark your Kibana dashboard

### This Week:
1. Complete all 8 visualizations from `docs/KIBANA-DASHBOARD-SETUP.md`
2. Set up Slack/Email connectors
3. Enable all critical alerts
4. Monitor for patterns

### This Month:
1. Review alert thresholds
2. Optimize slow transactions
3. Create weekly performance reports
4. Address security vulnerabilities

---

## Troubleshooting

### "No data in Kibana"
```bash
# Check APM is enabled
cat /Users/ryandahlberg/Projects/commit-relay/.env | grep ELASTIC_APM_ENABLED
# Should show: ELASTIC_APM_ENABLED=true

# Check server logs
cat /tmp/apm-server.log | grep APM
# Should show: [APM] Elastic APM initialized successfully

# Generate traffic
curl http://localhost:5001/api/health

# Wait 30-60 seconds, then check Kibana
```

### "Custom labels not showing"
```bash
# Restart server
kill $(cat /tmp/server.pid)
cd /Users/ryandahlberg/Projects/commit-relay/api-server
node server/index.js > /tmp/apm-server.log 2>&1 &
echo $! > /tmp/server.pid

# Generate traffic to instrumented endpoints
curl http://localhost:5001/api/workers
curl http://localhost:5001/api/security/current

# Check in Kibana after 30 seconds
```

### "Visualizations showing errors"
- Check index pattern is `apm-*`
- Verify time range includes recent data
- Try "Last 24 hours" time range
- Refresh the page

---

## Quick Reference Commands

```bash
# Check if server is running
ps aux | grep "node server/index.js"

# View server logs
tail -f /tmp/apm-server.log

# Restart server
kill $(cat /tmp/server.pid) && sleep 2 && \
  cd /Users/ryandahlberg/Projects/commit-relay/api-server && \
  node server/index.js > /tmp/apm-server.log 2>&1 & \
  echo $! > /tmp/server.pid

# Check security status
curl -s http://localhost:5001/api/security/current | jq '.'

# Check worker pool
curl -s http://localhost:5001/api/workers | jq '.stats'

# Generate test traffic
for i in {1..10}; do curl -s http://localhost:5001/api/health > /dev/null; done
```

---

## Success Criteria

After setup, you should have:

- [ ] commit-relay service visible in Kibana APM
- [ ] At least 1 visualization created
- [ ] Dashboard with auto-refresh enabled
- [ ] 1 alert configured (even if not fully connected)
- [ ] Can see custom labels in transaction details
- [ ] Security health score visible
- [ ] Worker pool metrics showing

---

## Getting Help

- **Full Dashboard Setup**: `docs/KIBANA-DASHBOARD-SETUP.md`
- **Alert Configuration**: `docs/APM-ALERT-RULES.json`
- **APM Integration**: `docs/APM-INTEGRATION.md`
- **Deployment Checklist**: `docs/APM-DEPLOYMENT-CHECKLIST.md`

---

**Time to Complete**: 5-15 minutes (depending on how many visualizations you create)

**Status**: Ready to use!

**Last Updated**: 2025-11-25
