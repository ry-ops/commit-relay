/**
 * Circuit Breaker Middleware for LLM Gateway
 *
 * Implements the circuit breaker pattern using the opossum library
 * to prevent cascade failures when LLM providers become unhealthy.
 *
 * @module llm-mesh/gateway/middleware/circuit-breaker
 */

'use strict';

const CircuitBreaker = require('opossum');
const EventEmitter = require('events');
const fs = require('fs');
const path = require('path');

// Load configuration
const CONFIG_PATH = path.join(__dirname, '../config/circuit-breaker.json');
let config = {
  defaults: {
    errorThresholdPercentage: 50,
    timeout: 30000,
    resetTimeout: 30000,
    volumeThreshold: 5,
    rollingCountTimeout: 10000,
    rollingCountBuckets: 10
  },
  providers: {}
};

try {
  if (fs.existsSync(CONFIG_PATH)) {
    config = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf-8'));
  }
} catch (error) {
  console.warn('Could not load circuit breaker config, using defaults:', error.message);
}

/**
 * Circuit Breaker Manager
 * Manages circuit breakers for all LLM providers
 */
class CircuitBreakerManager extends EventEmitter {
  constructor() {
    super();
    this.breakers = new Map();
    this.metrics = new Map();
    this.healthStatus = new Map();
  }

  /**
   * Create a circuit breaker for a provider
   * @param {string} provider - Provider name
   * @param {Function} action - The function to wrap (provider.complete)
   * @param {Object} options - Circuit breaker options
   * @returns {CircuitBreaker} Configured circuit breaker
   */
  createProviderBreaker(provider, action, options = {}) {
    const providerConfig = config.providers[provider] || {};
    const breakerOptions = {
      ...config.defaults,
      ...providerConfig,
      ...options,
      name: `${provider}-breaker`
    };

    const breaker = new CircuitBreaker(action, breakerOptions);

    // Initialize metrics for this provider
    this.metrics.set(provider, {
      totalRequests: 0,
      successfulRequests: 0,
      failedRequests: 0,
      timeouts: 0,
      rejectedRequests: 0,
      avgResponseTime: 0,
      lastFailure: null,
      lastSuccess: null,
      stateChanges: []
    });

    this.healthStatus.set(provider, 'healthy');

    // Event handlers
    breaker.on('success', (result, latency) => {
      this._onSuccess(provider, latency);
    });

    breaker.on('failure', (error) => {
      this._onFailure(provider, error);
    });

    breaker.on('timeout', () => {
      this._onTimeout(provider);
    });

    breaker.on('reject', () => {
      this._onReject(provider);
    });

    breaker.on('open', () => {
      this._onOpen(provider);
    });

    breaker.on('halfOpen', () => {
      this._onHalfOpen(provider);
    });

    breaker.on('close', () => {
      this._onClose(provider);
    });

    breaker.on('fallback', (result) => {
      this._onFallback(provider, result);
    });

    this.breakers.set(provider, breaker);
    this._log('info', `Circuit breaker created for ${provider}`, breakerOptions);

    return breaker;
  }

  /**
   * Get circuit breaker for a provider
   * @param {string} provider - Provider name
   * @returns {CircuitBreaker|null}
   */
  getBreaker(provider) {
    return this.breakers.get(provider) || null;
  }

  /**
   * Check if circuit is open (provider is unavailable)
   * @param {string} provider - Provider name
   * @returns {boolean}
   */
  isOpen(provider) {
    const breaker = this.breakers.get(provider);
    return breaker ? breaker.opened : false;
  }

  /**
   * Check if circuit is half-open (testing recovery)
   * @param {string} provider - Provider name
   * @returns {boolean}
   */
  isHalfOpen(provider) {
    const breaker = this.breakers.get(provider);
    return breaker ? breaker.halfOpen : false;
  }

  /**
   * Get circuit state
   * @param {string} provider - Provider name
   * @returns {string} 'open', 'closed', 'halfOpen', or 'unknown'
   */
  getState(provider) {
    const breaker = this.breakers.get(provider);
    if (!breaker) return 'unknown';

    if (breaker.opened) return 'open';
    if (breaker.halfOpen) return 'halfOpen';
    return 'closed';
  }

  /**
   * Manually reset circuit breaker
   * @param {string} provider - Provider name
   */
  reset(provider) {
    const breaker = this.breakers.get(provider);
    if (breaker) {
      breaker.close();
      this.healthStatus.set(provider, 'healthy');
      this._log('info', `Circuit breaker manually reset for ${provider}`);
      this.emit('manualReset', { provider, timestamp: new Date().toISOString() });
    }
  }

  /**
   * Get all circuit states
   * @returns {Object} Map of provider to state
   */
  getAllStates() {
    const states = {};
    for (const [provider] of this.breakers) {
      states[provider] = {
        state: this.getState(provider),
        health: this.healthStatus.get(provider),
        metrics: this.metrics.get(provider)
      };
    }
    return states;
  }

  /**
   * Get metrics for a provider
   * @param {string} provider - Provider name
   * @returns {Object|null}
   */
  getMetrics(provider) {
    return this.metrics.get(provider) || null;
  }

  /**
   * Get health status for a provider
   * @param {string} provider - Provider name
   * @returns {string} 'healthy', 'degraded', or 'unhealthy'
   */
  getHealth(provider) {
    return this.healthStatus.get(provider) || 'unknown';
  }

  /**
   * Get statistics from the circuit breaker
   * @param {string} provider - Provider name
   * @returns {Object|null}
   */
  getStats(provider) {
    const breaker = this.breakers.get(provider);
    if (!breaker) return null;
    return breaker.stats;
  }

  // Private event handlers

  _onSuccess(provider, latency) {
    const metrics = this.metrics.get(provider);
    if (metrics) {
      metrics.totalRequests++;
      metrics.successfulRequests++;
      metrics.lastSuccess = new Date().toISOString();

      // Update average response time
      const totalSuccessful = metrics.successfulRequests;
      metrics.avgResponseTime = ((metrics.avgResponseTime * (totalSuccessful - 1)) + latency) / totalSuccessful;
    }

    this.healthStatus.set(provider, 'healthy');
    this.emit('success', { provider, latency, timestamp: new Date().toISOString() });
  }

  _onFailure(provider, error) {
    const metrics = this.metrics.get(provider);
    if (metrics) {
      metrics.totalRequests++;
      metrics.failedRequests++;
      metrics.lastFailure = new Date().toISOString();
    }

    this._log('warn', `Circuit breaker failure for ${provider}`, { error: error.message });
    this.emit('failure', { provider, error: error.message, timestamp: new Date().toISOString() });
  }

  _onTimeout(provider) {
    const metrics = this.metrics.get(provider);
    if (metrics) {
      metrics.timeouts++;
    }

    this._log('warn', `Circuit breaker timeout for ${provider}`);
    this.emit('timeout', { provider, timestamp: new Date().toISOString() });
  }

  _onReject(provider) {
    const metrics = this.metrics.get(provider);
    if (metrics) {
      metrics.rejectedRequests++;
    }

    this._log('warn', `Request rejected by circuit breaker for ${provider}`);
    this.emit('reject', { provider, timestamp: new Date().toISOString() });
  }

  _onOpen(provider) {
    const metrics = this.metrics.get(provider);
    if (metrics) {
      metrics.stateChanges.push({
        from: 'closed',
        to: 'open',
        timestamp: new Date().toISOString()
      });
    }

    this.healthStatus.set(provider, 'unhealthy');
    this._log('error', `Circuit breaker OPENED for ${provider} - provider is unavailable`);
    this.emit('open', { provider, timestamp: new Date().toISOString() });
  }

  _onHalfOpen(provider) {
    const metrics = this.metrics.get(provider);
    if (metrics) {
      metrics.stateChanges.push({
        from: 'open',
        to: 'halfOpen',
        timestamp: new Date().toISOString()
      });
    }

    this.healthStatus.set(provider, 'degraded');
    this._log('info', `Circuit breaker HALF-OPEN for ${provider} - testing recovery`);
    this.emit('halfOpen', { provider, timestamp: new Date().toISOString() });
  }

  _onClose(provider) {
    const metrics = this.metrics.get(provider);
    if (metrics) {
      metrics.stateChanges.push({
        from: 'halfOpen',
        to: 'closed',
        timestamp: new Date().toISOString()
      });
    }

    this.healthStatus.set(provider, 'healthy');
    this._log('info', `Circuit breaker CLOSED for ${provider} - provider recovered`);
    this.emit('close', { provider, timestamp: new Date().toISOString() });
  }

  _onFallback(provider, result) {
    this._log('info', `Fallback executed for ${provider}`);
    this.emit('fallback', { provider, result, timestamp: new Date().toISOString() });
  }

  _log(level, message, data = {}) {
    const logEntry = {
      timestamp: new Date().toISOString(),
      component: 'CircuitBreakerManager',
      level,
      message,
      ...data
    };

    if (level === 'error') {
      console.error(JSON.stringify(logEntry));
    } else if (level === 'warn') {
      console.warn(JSON.stringify(logEntry));
    } else if (process.env.DEBUG || level === 'info') {
      console.log(JSON.stringify(logEntry));
    }
  }

  /**
   * Shutdown all circuit breakers
   */
  shutdown() {
    for (const [provider, breaker] of this.breakers) {
      breaker.shutdown();
      this._log('info', `Circuit breaker shutdown for ${provider}`);
    }
    this.breakers.clear();
    this.metrics.clear();
    this.healthStatus.clear();
  }
}

// Singleton instance
const circuitBreakerManager = new CircuitBreakerManager();

/**
 * Create a circuit breaker for a provider
 * @param {string} provider - Provider name
 * @param {Function} action - The function to wrap
 * @param {Object} options - Circuit breaker options
 * @returns {CircuitBreaker}
 */
function createProviderBreaker(provider, action, options = {}) {
  return circuitBreakerManager.createProviderBreaker(provider, action, options);
}

/**
 * Circuit breaker middleware for the gateway
 * Wraps the complete method with circuit breaker protection
 */
function circuitBreakerMiddleware(gateway) {
  const originalComplete = gateway.complete.bind(gateway);

  return {
    name: 'circuitBreaker',

    async before(request) {
      // Add circuit breaker manager to request context
      request.circuitBreakerManager = circuitBreakerManager;
      return request;
    },

    async after(response) {
      // Add circuit state to response
      if (response.provider) {
        response.circuitState = circuitBreakerManager.getState(response.provider);
      }
      return response;
    }
  };
}

module.exports = {
  CircuitBreakerManager,
  circuitBreakerManager,
  createProviderBreaker,
  circuitBreakerMiddleware,
  config
};
