// OpenTelemetry Tracer for Commit-Relay
// Distributed tracing across agent workflows

const { NodeTracerProvider } = require('@opentelemetry/sdk-trace-node');
const { Resource } = require('@opentelemetry/resources');
const { SemanticResourceAttributes } = require('@opentelemetry/semantic-conventions');
const api = require('@opentelemetry/api');
const fs = require('fs');
const path = require('path');

class CommitRelayTracer {
  constructor(config = {}) {
    this.config = {
      serviceName: config.serviceName || 'commit-relay',
      exportFormat: config.exportFormat || 'file', // 'file' or 'jaeger'
      tracesDir: config.tracesDir || 'coordination/traces',
      ...config
    };

    this.provider = null;
    this.tracer = null;
  }

  initialize() {
    // Create provider with resource info
    this.provider = new NodeTracerProvider({
      resource: new Resource({
        [SemanticResourceAttributes.SERVICE_NAME]: this.config.serviceName,
        [SemanticResourceAttributes.SERVICE_VERSION]: '1.0.0',
      }),
    });

    // File exporter (simple JSONL format)
    this.provider.addSpanProcessor({
      onStart: (span) => {},
      onEnd: (span) => {
        this.exportSpan(span);
      },
      shutdown: async () => {},
      forceFlush: async () => {},
    });

    // Register provider
    this.provider.register();

    // Get tracer
    this.tracer = api.trace.getTracer(this.config.serviceName, '1.0.0');

    // Ensure traces directory
    if (!fs.existsSync(this.config.tracesDir)) {
      fs.mkdirSync(this.config.tracesDir, { recursive: true });
    }

    console.log(`✓ Tracing initialized (${this.config.exportFormat})`);
    return true;
  }

  exportSpan(span) {
    try {
      const spanContext = span.spanContext();
      const traceId = spanContext.traceId;
      const spanId = spanContext.spanId;

      const spanData = {
        traceId,
        spanId,
        name: span.name,
        startTime: span.startTime[0] * 1000 + span.startTime[1] / 1000000,
        duration: span.duration ? span.duration[0] * 1000 + span.duration[1] / 1000000 : 0,
        attributes: span.attributes,
        events: span.events,
        status: span.status,
        timestamp: new Date().toISOString()
      };

      // Write to daily trace file
      const date = new Date().toISOString().split('T')[0];
      const traceFile = path.join(this.config.tracesDir, `traces-${date}.jsonl`);

      fs.appendFileSync(traceFile, JSON.stringify(spanData) + '\n');
    } catch (error) {
      console.error('Failed to export span:', error);
    }
  }

  startSpan(name, attributes = {}) {
    return this.tracer.startSpan(name, {
      attributes
    });
  }

  async withSpan(name, attributes, fn) {
    const span = this.startSpan(name, attributes);

    try {
      const result = await api.context.with(
        api.trace.setSpan(api.context.active(), span),
        fn
      );
      span.setStatus({ code: api.SpanStatusCode.OK });
      return result;
    } catch (error) {
      span.setStatus({
        code: api.SpanStatusCode.ERROR,
        message: error.message
      });
      span.recordException(error);
      throw error;
    } finally {
      span.end();
    }
  }

  getCurrentSpan() {
    return api.trace.getSpan(api.context.active());
  }

  addEvent(name, attributes = {}) {
    const span = this.getCurrentSpan();
    if (span) {
      span.addEvent(name, attributes);
    }
  }

  setAttributes(attributes) {
    const span = this.getCurrentSpan();
    if (span) {
      span.setAttributes(attributes);
    }
  }
}

// Singleton instance
let globalTracer = null;

function getTracer(config) {
  if (!globalTracer) {
    globalTracer = new CommitRelayTracer(config);
    globalTracer.initialize();
  }
  return globalTracer;
}

module.exports = { CommitRelayTracer, getTracer };
