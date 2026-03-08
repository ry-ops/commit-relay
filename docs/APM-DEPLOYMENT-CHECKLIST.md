# Elastic APM Deployment Checklist

**Implementation**: ✅ Complete (commit 71e8c3e)
**Status**: Ready for Staging Deployment
**Date**: 2025-11-25

---

## Prerequisites

### 1. Elastic Cloud Setup
- [ ] Elastic Cloud account created
- [ ] Deployment created (or use existing)
- [ ] APM integration enabled
- [ ] Server URL obtained
- [ ] Secret token obtained

**Get credentials**:
1. Log into [Elastic Cloud](https://cloud.elastic.co/)
2. Navigate to your deployment
3. Go to **Integrations** → **APM**
4. Copy:
   - Server URL → `ELASTIC_APM_SERVER_URL`
   - Secret Token → `ELASTIC_APM_SECRET_TOKEN`

---

## Staging Environment Deployment

### Step 1: Environment Configuration
- [ ] Copy `.env.example` to `.env` on staging server
- [ ] Configure APM environment variables:

```bash
# Enable APM
ELASTIC_APM_ENABLED=true

# Service identification
ELASTIC_APM_SERVICE_NAME=commit-relay-staging

# Elastic Cloud credentials
ELASTIC_APM_SERVER_URL=https://your-deployment.apm.region.cloud.es.io:443
ELASTIC_APM_SECRET_TOKEN=your-secret-token-here

# Environment
ELASTIC_APM_ENVIRONMENT=staging

# Logging
ELASTIC_APM_LOG_LEVEL=info

# Performance (sample 100% in staging for testing)
ELASTIC_APM_TRANSACTION_SAMPLE_RATE=1.0

# Capture (errors only for security)
ELASTIC_APM_CAPTURE_BODY=errors
```

- [ ] Verify environment variables:
```bash
grep ELASTIC_APM .env
```

### Step 2: Install Dependencies
- [ ] Pull latest code from `main` branch
- [ ] Install npm dependencies:

```bash
cd api-server
npm install
```

- [ ] Verify `elastic-apm-node` installed:
```bash
npm list elastic-apm-node
# Should show: elastic-apm-node@4.5.4
```

### Step 3: Start the Server
- [ ] Start the API server:

```bash
npm start
```

- [ ] Verify APM initialization in logs:
```
[APM] Elastic APM initialized successfully
[APM]   Service: commit-relay-staging
[APM]   Environment: staging
[APM]   Server: https://your-deployment...
[APM]   Sample Rate: 1.0
```

- [ ] If APM fails, check:
  - Server URL is correct
  - Secret token is valid
  - Network connectivity to Elastic Cloud

### Step 4: Verify in Kibana
- [ ] Open Kibana in Elastic Cloud
- [ ] Navigate to **Observability** → **APM**
- [ ] Verify service appears: **commit-relay-staging**
- [ ] Make test requests to API endpoints
- [ ] Verify transactions appear (may take 10-30 seconds)

**Test Endpoints**:
```bash
# Health check
curl http://localhost:5001/api/health

# System info
curl http://localhost:5001/api/system/info

# Metrics
curl http://localhost:5001/api/metrics
```

- [ ] Check in Kibana:
  - **Services** → commit-relay-staging → Transactions
  - Verify requests appear with timing
  - Check service map shows dependencies

### Step 5: Test Custom Events
- [ ] Trigger agent operations (spawn worker, complete task)
- [ ] Check custom events in transaction metadata
- [ ] Verify custom labels appear in Kibana

**Filter by custom events**:
```
labels.agent.event.type: "spawned"
labels.task.id: "task-*"
```

### Step 6: Test Error Tracking
- [ ] Trigger an intentional error (404, 500)
- [ ] Navigate to **Observability** → **APM** → **Errors**
- [ ] Verify error appears with:
  - Stack trace
  - Request context
  - Custom labels

### Step 7: Monitor for 24 Hours
- [ ] Set up monitoring dashboard
- [ ] Track key metrics:
  - Response times
  - Error rate
  - Throughput
  - Memory usage
- [ ] Create alerts if needed

---

## Production Environment Deployment

**Prerequisites**:
- ✅ Staging deployment successful
- ✅ 24 hours of stable operation in staging
- ✅ No critical issues identified

### Step 1: Production Configuration
- [ ] Create separate Elastic Cloud deployment for production (recommended)
- [ ] Or use separate APM namespace in existing deployment
- [ ] Configure production environment variables:

```bash
ELASTIC_APM_ENABLED=true
ELASTIC_APM_SERVICE_NAME=commit-relay-production
ELASTIC_APM_SERVER_URL=https://your-production-deployment.apm.region.cloud.es.io:443
ELASTIC_APM_SECRET_TOKEN=your-production-secret-token
ELASTIC_APM_ENVIRONMENT=production
ELASTIC_APM_LOG_LEVEL=warn
ELASTIC_APM_TRANSACTION_SAMPLE_RATE=0.1  # Sample 10% for lower overhead
ELASTIC_APM_CAPTURE_BODY=errors
```

### Step 2: Deploy to Production
- [ ] Follow same steps as staging (Steps 2-6)
- [ ] Use production credentials
- [ ] Verify in production Kibana

### Step 3: Production Monitoring
- [ ] Set up production dashboards
- [ ] Configure critical alerts:
  - Error rate > 5%
  - Response time > 2 seconds
  - Throughput drop > 50%
- [ ] Document runbook for alerts

---

## Post-Deployment Tasks

### Week 1: Custom Instrumentation
- [ ] Add custom events to existing API routes
- [ ] Instrument worker lifecycle events
- [ ] Track LLM API calls
- [ ] Monitor token usage

**Example**:
```javascript
const { trackToolUsage } = require('./server/utils/apm-events');

// In API route
trackToolUsage('anthropic-api', {
  operation: 'messages.create',
  duration: 2400,
  status: 'success'
});
```

### Week 2: Dashboards & Alerts
- [ ] Create custom Kibana dashboard
- [ ] Add key metrics visualizations:
  - Response time by endpoint
  - Error rate by type
  - Agent spawn rate
  - Token usage trends
- [ ] Configure alerts for SLA thresholds
- [ ] Set up incident response workflow

### Week 3: Optimization
- [ ] Review high-latency transactions
- [ ] Identify bottlenecks
- [ ] Optimize slow operations
- [ ] Adjust sample rate if needed
- [ ] Review data retention policies

### Month 1: Advanced Features
- [ ] Enable anomaly detection in Kibana
- [ ] Set up SLA monitoring
- [ ] Create service map
- [ ] Document APM best practices
- [ ] Train team on Kibana usage

---

## Rollback Plan

If issues occur, rollback by disabling APM:

### Immediate Rollback
```bash
# Set in .env
ELASTIC_APM_ENABLED=false

# Restart server
npm restart
```

Application will continue working normally with APM disabled.

### Full Rollback
```bash
# Revert to previous commit
git revert 71e8c3e

# Or reset to previous version
git reset --hard 72617d3

# Push changes
git push origin main

# Redeploy
```

---

## Troubleshooting

### APM Not Appearing in Kibana
1. Check environment variables are correct
2. Verify network connectivity to APM Server
3. Check server logs for APM errors
4. Increase log level: `ELASTIC_APM_LOG_LEVEL=debug`

### High Overhead
1. Reduce sample rate: `ELASTIC_APM_TRANSACTION_SAMPLE_RATE=0.1`
2. Disable body capture: `ELASTIC_APM_CAPTURE_BODY=off`
3. Check for custom span issues

### Missing Custom Events
1. Verify APM is enabled
2. Check custom event code is executing
3. Look for errors in logs

---

## Support Resources

- [APM Integration Guide](./APM-INTEGRATION.md)
- [Elastic APM Node.js Docs](https://www.elastic.co/guide/en/apm/agent/nodejs/current/index.html)
- [Kibana APM Guide](https://www.elastic.co/guide/en/kibana/current/xpack-apm.html)
- [Elastic Cloud Support](https://www.elastic.co/support)

---

## Sign-off

| Role | Name | Date | Status |
|------|------|------|--------|
| Developer | worker-implementation-039 | 2025-11-25 | ✅ Complete |
| Code Review | | | ⏳ Pending |
| QA - Staging | | | ⏳ Pending |
| QA - Production | | | ⏳ Pending |
| Product Owner | | | ⏳ Pending |

---

**Implementation Commit**: `71e8c3e`
**GitHub URL**: https://github.com/ry-ops/commit-relay/commit/71e8c3e
**Documentation**: docs/APM-INTEGRATION.md
**Status**: ✅ Ready for Staging Deployment
