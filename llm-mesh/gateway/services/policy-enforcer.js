// Policy Enforcer Service
// Runtime policy enforcement: rate limiting, circuit breaking, validation

const fs = require('fs').promises;

class PolicyEnforcer {
  constructor() {
    this.policiesPath = 'coordination/gateway/runtime-policies.json';
    this.policies = null;
    this.circuitBreakers = new Map();
    this.rateLimiters = new Map();
  }

  async initialize() {
    try {
      const data = await fs.readFile(this.policiesPath, 'utf8');
      this.policies = JSON.parse(data);
    } catch {
      this.policies = this.getDefaultPolicies();
      await fs.mkdir(require('path').dirname(this.policiesPath), { recursive: true });
      await fs.writeFile(this.policiesPath, JSON.stringify(this.policies, null, 2));
    }
    return true;
  }

  getDefaultPolicies() {
    return {
      rate_limits: {
        per_agent_per_minute: 60,
        global_per_second: 100
      },
      circuit_breaker: {
        failure_threshold: 5,
        timeout_ms: 30000,
        reset_timeout_ms: 60000
      },
      validation: {
        max_task_description_length: 10000,
        required_fields: ['task_id', 'description']
      }
    };
  }

  checkRateLimit(agentId) {
    const key = `rate:${agentId}`;
    const now = Date.now();
    const window = 60000; // 1 minute

    if (!this.rateLimiters.has(key)) {
      this.rateLimiters.set(key, []);
    }

    const requests = this.rateLimiters.get(key);
    const recent = requests.filter(t => now - t < window);

    if (recent.length >= this.policies.rate_limits.per_agent_per_minute) {
      return { allowed: false, reason: 'Rate limit exceeded' };
    }

    recent.push(now);
    this.rateLimiters.set(key, recent);
    return { allowed: true };
  }

  checkCircuitBreaker(agentId) {
    const breaker = this.circuitBreakers.get(agentId);
    if (!breaker) return { open: false };

    if (breaker.state === 'open') {
      if (Date.now() - breaker.openedAt > this.policies.circuit_breaker.reset_timeout_ms) {
        breaker.state = 'half-open';
        return { open: false, state: 'half-open' };
      }
      return { open: true, reason: 'Circuit breaker open' };
    }

    return { open: false, state: breaker.state };
  }

  recordFailure(agentId) {
    if (!this.circuitBreakers.has(agentId)) {
      this.circuitBreakers.set(agentId, {
        failures: 0,
        state: 'closed',
        openedAt: null
      });
    }

    const breaker = this.circuitBreakers.get(agentId);
    breaker.failures++;

    if (breaker.failures >= this.policies.circuit_breaker.failure_threshold) {
      breaker.state = 'open';
      breaker.openedAt = Date.now();
    }
  }

  recordSuccess(agentId) {
    const breaker = this.circuitBreakers.get(agentId);
    if (breaker) {
      if (breaker.state === 'half-open') {
        breaker.state = 'closed';
      }
      breaker.failures = Math.max(0, breaker.failures - 1);
    }
  }

  validateRequest(data, schema) {
    const required = schema || this.policies.validation.required_fields;
    for (const field of required) {
      if (!data[field]) {
        return { valid: false, error: `Missing required field: ${field}` };
      }
    }
    return { valid: true };
  }
}

module.exports = PolicyEnforcer;
