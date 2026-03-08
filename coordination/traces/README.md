# OpenTelemetry Traces

This directory contains distributed tracing data for commit-relay agent workflows.

## File Format

Traces are stored in daily JSONL files:
- `traces-YYYY-MM-DD.jsonl` - Span data
- `events-YYYY-MM-DD.jsonl` - Span events

## Trace Format

```json
{
  "traceId": "128-bit hex trace ID",
  "spanId": "64-bit hex span ID",
  "parentSpanId": "64-bit hex parent span ID (optional)",
  "name": "operation name",
  "startTime": 1234567890000,
  "duration": 1500,
  "attributes": {},
  "status": "ok|error",
  "timestamp": "2025-11-26T13:00:00-06:00"
}
```

## Usage

### Node.js
```javascript
const { getTracer } = require('./lib/observability/tracing/tracer');

const tracer = getTracer();

await tracer.withSpan('routing-decision', { taskId: 'task-123' }, async () => {
  // Your code here
  tracer.addEvent('routing-complete', { expert: 'development' });
});
```

### Bash
```bash
source scripts/lib/tracing/trace-context.sh

span_id=$(start_trace "worker-execution")
# Your code here
trace_event "task-completed" '{"status":"success"}'
end_trace "$span_id" "ok"
```

## Retention

Traces are kept for 30 days by default. Old files can be archived or deleted.
