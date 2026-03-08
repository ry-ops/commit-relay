# Logging Best Practices

## Overview

Comprehensive logging strategy for commit-relay ensuring observability, debugging, and compliance.

**Log Formats**: JSONL (structured), Plain text (human-readable)  
**Log Levels**: ERROR, WARN, INFO, DEBUG, TRACE  
**Retention**: 90 days (hot), 1 year (cold)

---

## Log Levels

### ERROR (Level 0)

**When to use**: System failures, unrecoverable errors  
**Examples**:
- Database connection failed
- API endpoint returning 500
- Worker crash

```javascript
logger.error('Database connection failed', {
  error: error.message,
  stack: error.stack,
  database: config.database.host,
  timestamp: new Date().toISOString()
});
```

### WARN (Level 1)

**When to use**: Potential issues, degraded performance  
**Examples**:
- API rate limit approaching
- High memory usage
- Deprecated API usage

```javascript
logger.warn('GitHub API rate limit warning', {
  remaining: rateLimitRemaining,
  reset: rateLimitReset,
  threshold: 500
});
```

### INFO (Level 2)

**When to use**: Important business events  
**Examples**:
- Task completion
- Achievement unlocked
- Worker spawned

```javascript
logger.info('Achievement unlocked', {
  achievement: 'pull_shark',
  tier: 'silver',
  user: username,
  count: 16
});
```

### DEBUG (Level 3)

**When to use**: Development debugging  
**Examples**:
- Function entry/exit
- Variable values
- Control flow

```javascript
logger.debug('MoE routing decision', {
  task_id: taskId,
  assigned_master: 'development-master',
  confidence: 0.85,
  pattern: 'bug_fix'
});
```

### TRACE (Level 4)

**When to use**: Fine-grained debugging  
**Examples**:
- Loop iterations
- Detailed data transformations

```javascript
logger.trace('Processing batch item', {
  index: i,
  total: items.length,
  item_id: item.id
});
```

---

## Structured Logging

### JSONL Format

```jsonl
{"timestamp":"2025-11-25T21:00:00Z","level":"info","message":"Task completed","task_id":"task-001","duration_ms":1234,"master":"development-master"}
{"timestamp":"2025-11-25T21:01:00Z","level":"error","message":"API request failed","error":"Rate limit exceeded","endpoint":"/api/achievements","status_code":429}
```

### Benefits

- Machine-parseable
- Easy to query (jq, grep, ELK)
- Consistent structure
- Automatic indexing

### Implementation

```javascript
const winston = require('winston');

const logger = winston.createLogger({
  level: process.env.LOG_LEVEL || 'info',
  format: winston.format.combine(
    winston.format.timestamp(),
    winston.format.json()
  ),
  transports: [
    new winston.transports.File({ 
      filename: 'logs/error.jsonl', 
      level: 'error' 
    }),
    new winston.transports.File({ 
      filename: 'logs/combined.jsonl' 
    })
  ]
});

// Add console transport in development
if (process.env.NODE_ENV !== 'production') {
  logger.add(new winston.transports.Console({
    format: winston.format.simple()
  }));
}
```

---

## Log Context

### Request Context

```javascript
// Add request ID to all logs
app.use((req, res, next) => {
  req.id = uuidv4();
  req.logger = logger.child({ request_id: req.id });
  next();
});

// Use request logger
app.get('/api/achievements', (req, res) => {
  req.logger.info('Fetching achievements', {
    user: req.query.username
  });
  
  // ... handle request
});
```

### Worker Context

```bash
#!/usr/bin/env bash
# Worker script logging

WORKER_ID="${1}"
TASK_ID="${2}"

log_event() {
  local level="$1"
  local message="$2"
  local metadata="${3:-{}}"
  
  jq -n \
    --arg level "$level" \
    --arg msg "$message" \
    --arg worker "$WORKER_ID" \
    --arg task "$TASK_ID" \
    --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --argjson meta "$metadata" \
    '{timestamp: $ts, level: $level, message: $msg, worker_id: $worker, task_id: $task, metadata: $meta}' \
    >> logs/workers.jsonl
}

log_event "info" "Worker started" '{"type": "scan-worker"}'
```

---

## Log Aggregation

### Elastic Stack Integration

```javascript
const { ElasticsearchTransport } = require('winston-elasticsearch');

logger.add(new ElasticsearchTransport({
  level: 'info',
  clientOpts: {
    node: process.env.ELASTICSEARCH_URL,
    auth: {
      apiKey: process.env.ELASTICSEARCH_API_KEY
    }
  },
  index: 'commit-relay-logs'
}));
```

### Kibana Queries

**Find all errors in last hour**:
```
level: error AND @timestamp:[now-1h TO now]
```

**Worker failures by type**:
```
level: error AND worker_id:* 
| stats count by metadata.type
```

**Slow API requests** (> 1 second):
```
duration_ms:>1000 AND transaction.name:/api/*
```

---

## Log Retention

### Hot Storage (0-90 days)

- **Location**: Local disk / S3
- **Access**: Instant query
- **Cost**: High
- **Use**: Active debugging, monitoring

### Cold Storage (90 days - 1 year)

- **Location**: S3 Glacier
- **Access**: 12-hour restore
- **Cost**: Low
- **Use**: Compliance, historical analysis

### Archive (> 1 year)

- **Location**: Glacier Deep Archive
- **Access**: 48-hour restore
- **Cost**: Very low
- **Use**: Long-term compliance only

### Rotation Script

```bash
#!/usr/bin/env bash
# Log rotation and archiving

LOGS_DIR="logs"
ARCHIVE_DIR="logs/archive"
HOT_DAYS=90
COLD_DAYS=365

# Compress logs older than 7 days
find "$LOGS_DIR" -name "*.jsonl" -mtime +7 -exec gzip {} \;

# Move to cold storage
find "$LOGS_DIR" -name "*.jsonl.gz" -mtime +$HOT_DAYS -exec mv {} "$ARCHIVE_DIR/" \;

# Delete archived logs
find "$ARCHIVE_DIR" -name "*.jsonl.gz" -mtime +$COLD_DAYS -delete
```

---

## Sensitive Data

### PII Redaction

```javascript
function redactPII(logData) {
  const redacted = { ...logData };
  
  // Redact email addresses
  if (redacted.email) {
    redacted.email = redacted.email.replace(/(.{2}).*(@.*)/, '$1***$2');
  }
  
  // Redact API tokens
  if (redacted.token) {
    redacted.token = redacted.token.substring(0, 8) + '...';
  }
  
  // Redact IP addresses
  if (redacted.ip) {
    redacted.ip = redacted.ip.replace(/\d+\.\d+\.\d+\.(\d+)/, 'xxx.xxx.xxx.$1');
  }
  
  return redacted;
}

logger.info('User login', redactPII({
  email: 'user@example.com',  // Logged as: us***@example.com
  ip: '192.168.1.100'         // Logged as: xxx.xxx.xxx.100
}));
```

---

## Performance

### Async Logging

```javascript
// Non-blocking logging
logger.add(new winston.transports.File({
  filename: 'logs/combined.jsonl',
  options: { flags: 'a' },  // Append mode
  stream: fs.createWriteStream('logs/combined.jsonl', { flags: 'a' })
}));
```

### Sampling

```javascript
// Log only 10% of high-volume events
function shouldLog(eventType) {
  const samplingRates = {
    'api_request': 0.1,   // 10%
    'worker_heartbeat': 0.01,  // 1%
    'achievement_check': 1.0   // 100%
  };
  
  return Math.random() < (samplingRates[eventType] || 1.0);
}

if (shouldLog('api_request')) {
  logger.debug('API request', { ... });
}
```

---

## Monitoring & Alerts

### Log-Based Alerts

```yaml
# Kibana Watcher alert
{
  "trigger": {
    "schedule": { "interval": "5m" }
  },
  "input": {
    "search": {
      "request": {
        "indices": ["commit-relay-logs"],
        "body": {
          "query": {
            "bool": {
              "must": [
                { "term": { "level": "error" } },
                { "range": { "@timestamp": { "gte": "now-5m" } } }
              ]
            }
          }
        }
      }
    }
  },
  "condition": {
    "compare": { "ctx.payload.hits.total": { "gte": 10 } }
  },
  "actions": {
    "slack": {
      "webhook": {
        "url": "${SLACK_WEBHOOK}",
        "body": "🚨 10+ errors in last 5 minutes"
      }
    }
  }
}
```

---

**Last Updated**: 2025-11-25  
**Log Level**: INFO (production)  
**Retention**: 90 days (hot), 1 year (cold)
