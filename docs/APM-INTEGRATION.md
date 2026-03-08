# Elastic APM Integration for Commit-Relay

Complete guide for Elastic APM observability integration in the commit-relay system.

## Overview

Commit-relay is now fully instrumented with Elastic APM for comprehensive observability including:

- **Distributed Tracing**: Full request traces across API endpoints and workers
- **Performance Monitoring**: Response times, throughput, and resource usage
- **Error Tracking**: Automatic exception capture with stack traces and context
- **Custom Events**: Agent lifecycle, tool usage, and task completion tracking
- **Log Correlation**: Trace IDs injected into logs for seamless correlation
- **Real-time Metrics**: System health, performance metrics, and dashboards

## Architecture

```
┌──────────────────┐
│   API Requests   │
└────────┬─────────┘
         │
    ┌────▼────┐
    │  APM    │ ← Initialized first (before Express)
    │ Client  │
    └────┬────┘
         │
    ┌────▼────────────────────┐
    │  Express Middleware     │ ← Auto-instrumentation
    └────┬────────────────────┘
         │
    ┌────▼──────────────────┐
    │  Custom APM Events    │ ← Manual instrumentation
    │  - Agent Events       │
    │  - Tool Usage         │
    │  - Task Completions   │
    └───────────────────────┘
```

## Setup

### 1. Install Dependencies

APM dependency is already added to `package.json`:

```bash
cd api-server
npm install
```

This installs `elastic-apm-node` v4.5.4.

### 2. Configure Environment Variables

Copy `.env.example` to `.env` and configure APM settings:

```bash
cp .env.example .env
```

**Required Configuration**:

```bash
# Enable APM
ELASTIC_APM_ENABLED=true

# Service name in APM (identifies your service)
ELASTIC_APM_SERVICE_NAME=commit-relay

# APM Server URL (get from Elastic Cloud deployment)
ELASTIC_APM_SERVER_URL=https://your-deployment.apm.region.cloud.es.io:443

# Secret token (get from Elastic Cloud APM integration)
ELASTIC_APM_SECRET_TOKEN=your-secret-token-here

# Environment (production, staging, development)
ELASTIC_APM_ENVIRONMENT=production
```

**Optional Configuration**:

```bash
# Logging level (trace, debug, info, warn, error, fatal)
ELASTIC_APM_LOG_LEVEL=info

# Capture request/response bodies (off, errors, transactions, all)
ELASTIC_APM_CAPTURE_BODY=errors

# Sample rate: 0.0 to 1.0 (1.0 = 100% of transactions)
ELASTIC_APM_TRANSACTION_SAMPLE_RATE=1.0
```

### 3. Get Elastic Cloud Credentials

1. Log into [Elastic Cloud](https://cloud.elastic.co/)
2. Navigate to your deployment
3. Go to **Integrations** → **APM**
4. Copy:
   - **Server URL** → `ELASTIC_APM_SERVER_URL`
   - **Secret Token** → `ELASTIC_APM_SECRET_TOKEN`

### 4. Start the Server

```bash
cd api-server
npm start
```

You should see:

```
[APM] Elastic APM initialized successfully
[APM]   Service: commit-relay
[APM]   Environment: production
[APM]   Server: https://your-deployment.apm.region.cloud.es.io:443
[APM]   Sample Rate: 1.0
```

## Features

### 1. Automatic Instrumentation

The following are automatically instrumented with no code changes required:

**HTTP Requests**:
- All Express routes
- Request/response timing
- Status codes
- Headers (configurable)

**Database Queries**:
- Automatic span creation for DB operations
- Query timing and performance

**HTTP Client Calls**:
- Outbound HTTP requests
- External API calls

**Frameworks**:
- Express middleware
- WebSocket connections
- File system operations

### 2. Custom Event Tracking

Use the `apm-events` utility module for custom instrumentation:

```javascript
const {
  trackAgentEvent,
  trackToolUsage,
  trackRelayCompletion,
  withCustomSpan,
  captureException
} = require('./server/utils/apm-events');
```

**Track Agent Lifecycle Events**:

```javascript
// When spawning a worker
trackAgentEvent('spawned', {
  agentId: 'worker-impl-001',
  agentType: 'implementation-worker',
  taskId: 'task-123',
  metadata: {
    master: 'development-master',
    tokenBudget: 10000
  }
});

// When worker completes
trackAgentEvent('completed', {
  agentId: 'worker-impl-001',
  agentType: 'implementation-worker',
  taskId: 'task-123',
  metadata: {
    duration: 3600,
    tokensUsed: 8500,
    status: 'success'
  }
});
```

**Track Tool Usage**:

```javascript
trackToolUsage('github-api', {
  operation: 'create-pr',
  duration: 1200,
  status: 'success',
  metadata: {
    repository: 'org/repo',
    prNumber: 42
  }
});
```

**Track Task Completions**:

```javascript
trackRelayCompletion('task-123', {
  status: 'success',
  duration: 180000,
  master: 'development-master',
  workersUsed: 3,
  metrics: {
    linesChanged: 245,
    filesModified: 8,
    testsAdded: 12
  }
});
```

**Custom Spans for Operations**:

```javascript
const result = await withCustomSpan('llm-request', 'external', async () => {
  return await anthropic.messages.create({
    model: 'claude-3-5-sonnet-20241022',
    messages: [{ role: 'user', content: 'Hello' }]
  });
});
```

**Exception Tracking**:

```javascript
try {
  await riskyOperation();
} catch (error) {
  captureException(error, {
    operation: 'process-task',
    metadata: {
      taskId: 'task-123',
      workerId: 'worker-001'
    }
  });
  throw error;
}
```

### 3. Log Correlation

Get trace IDs for log correlation:

```javascript
const { getTraceId, getTransactionId } = require('./server/utils/apm-events');

console.log(`[trace.id=${getTraceId()}] Processing task...`);
```

In Kibana, you can then search logs by trace ID to see all logs for a specific request.

### 4. Error Tracking

All uncaught exceptions in Express routes are automatically captured by the global error handler:

```javascript
// This error will be automatically captured in APM
app.get('/api/example', async (req, res) => {
  throw new Error('Something went wrong!');
  // APM will capture: stack trace, request context, headers
});
```

### 5. User Context

Set user context for requests (useful for multi-tenant scenarios):

```javascript
const { setUser } = require('./server/utils/apm-events');

app.use((req, res, next) => {
  if (req.user) {
    setUser({
      id: req.user.id,
      username: req.user.username,
      email: req.user.email
    });
  }
  next();
});
```

### 6. Custom Labels

Add custom labels for filtering in Kibana:

```javascript
const { addLabels } = require('./server/utils/apm-events');

addLabels({
  'deployment.region': 'us-east-1',
  'feature.flag': 'new-routing',
  'experiment.variant': 'control'
});
```

## Viewing Data in Kibana

### 1. Access APM

1. Go to Elastic Cloud → Your Deployment
2. Click **Kibana**
3. Navigate to **Observability** → **APM**
4. Select **Services** → **commit-relay**

### 2. Key Views

**Service Overview**:
- Transactions per minute
- Average response time
- Error rate
- Throughput

**Transactions**:
- View all API endpoints
- Sort by latency, throughput, or error rate
- Drill down into slow transactions

**Errors**:
- All captured exceptions
- Stack traces
- Request context
- Error trends over time

**Metrics**:
- CPU usage
- Memory usage
- Event loop delay
- Garbage collection metrics

**Service Map**:
- Visualize service dependencies
- External API calls
- Database connections

### 3. Querying Custom Events

**Filter by Agent Events**:
```
labels.agent.event.type: "spawned"
```

**Filter by Task ID**:
```
labels.task.id: "task-123"
```

**Filter by Tool Usage**:
```
span.name: "tool.github-api"
```

**Find Errors in Specific Operation**:
```
labels.error.operation: "process-task"
```

## Performance Considerations

### 1. Sampling

For high-traffic production systems, use sampling to reduce APM overhead:

```bash
# Sample 10% of transactions
ELASTIC_APM_TRANSACTION_SAMPLE_RATE=0.1
```

### 2. Body Capture

Control request/response body capture:

```bash
# Only capture bodies on errors (recommended for production)
ELASTIC_APM_CAPTURE_BODY=errors

# Capture all bodies (useful for debugging, high overhead)
ELASTIC_APM_CAPTURE_BODY=all

# Never capture bodies (lowest overhead)
ELASTIC_APM_CAPTURE_BODY=off
```

### 3. Disable APM in Development

```bash
# Disable APM locally
ELASTIC_APM_ENABLED=false
```

### 4. Overhead

- **Latency**: < 1ms per instrumented operation
- **Memory**: ~50MB base + ~1KB per active transaction
- **CPU**: < 1% additional CPU usage
- **Network**: ~1KB per transaction sent to APM Server

## Troubleshooting

### APM Not Working

**Check Configuration**:
```bash
# Verify APM is enabled
grep ELASTIC_APM_ENABLED .env

# Check server URL is valid
grep ELASTIC_APM_SERVER_URL .env

# Ensure secret token is set
grep ELASTIC_APM_SECRET_TOKEN .env
```

**Check Logs**:
```bash
# Start server and check for APM initialization
npm start | grep APM
```

You should see:
```
[APM] Elastic APM initialized successfully
```

**Test Connection**:
```bash
# Test APM Server connectivity
curl -X POST "${ELASTIC_APM_SERVER_URL}/intake/v2/events" \
  -H "Authorization: Bearer ${ELASTIC_APM_SECRET_TOKEN}" \
  -H "Content-Type: application/x-ndjson"
```

### Data Not Appearing in Kibana

1. **Wait 10-30 seconds** - Data ingestion has a slight delay
2. **Check time range** - Expand to "Last 1 hour"
3. **Verify service name** - Ensure it matches `ELASTIC_APM_SERVICE_NAME`
4. **Check sampling** - If sample rate is low, you may need to generate more traffic

### High Overhead

1. **Reduce sample rate**: Set `ELASTIC_APM_TRANSACTION_SAMPLE_RATE=0.1`
2. **Disable body capture**: Set `ELASTIC_APM_CAPTURE_BODY=errors`
3. **Increase metrics interval**: APM config `metricsInterval: '60s'`

### Missing Custom Events

Ensure APM is initialized:
```javascript
const apm = require('../apm');
if (!apm) {
  console.warn('APM is not initialized');
}
```

## Security Best Practices

### 1. Protect Sensitive Data

Never log sensitive information:
```javascript
// ❌ BAD
captureException(error, {
  metadata: { password: user.password }
});

// ✅ GOOD
captureException(error, {
  metadata: { userId: user.id }
});
```

### 2. Secure Secret Token

- Use environment variables
- Never commit to git
- Rotate periodically
- Use different tokens per environment

### 3. Network Security

- Use HTTPS for APM Server URL
- Whitelist APM Server IPs if possible
- Use firewall rules

### 4. Data Retention

Configure data retention in Kibana:
- **Traces**: 7-30 days
- **Metrics**: 30-90 days
- **Logs**: 7-30 days

## Integration Examples

### Express Route with Custom Span

```javascript
const { withCustomSpan, addLabels } = require('./utils/apm-events');

app.post('/api/tasks', async (req, res) => {
  addLabels({ 'task.type': req.body.type });

  const result = await withCustomSpan('process-task', 'custom', async () => {
    // Complex task processing
    return await processTask(req.body);
  });

  res.json(result);
});
```

### Worker Lifecycle Tracking

```javascript
const { trackAgentEvent } = require('./utils/apm-events');

class Worker {
  async spawn(taskId) {
    trackAgentEvent('spawned', {
      agentId: this.id,
      agentType: 'implementation-worker',
      taskId: taskId
    });

    try {
      const result = await this.execute();

      trackAgentEvent('completed', {
        agentId: this.id,
        agentType: 'implementation-worker',
        taskId: taskId,
        metadata: { status: 'success' }
      });

      return result;
    } catch (error) {
      trackAgentEvent('failed', {
        agentId: this.id,
        agentType: 'implementation-worker',
        taskId: taskId,
        metadata: { error: error.message }
      });

      throw error;
    }
  }
}
```

## References

- [Elastic APM Node.js Documentation](https://www.elastic.co/guide/en/apm/agent/nodejs/current/index.html)
- [Elastic APM API Reference](https://www.elastic.co/guide/en/apm/agent/nodejs/current/api.html)
- [Elastic Cloud Documentation](https://www.elastic.co/guide/en/cloud/current/index.html)
- [APM Best Practices](https://www.elastic.co/guide/en/apm/guide/current/apm-best-practices.html)

## Support

For issues or questions:
1. Check Elastic APM agent logs
2. Review [Troubleshooting Guide](https://www.elastic.co/guide/en/apm/agent/nodejs/current/troubleshooting.html)
3. Open an issue in the commit-relay repository

---

**Status**: Implemented
**Version**: 1.0.0
**Last Updated**: 2025-11-25
