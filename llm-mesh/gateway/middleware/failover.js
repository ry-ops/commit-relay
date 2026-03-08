/**
 * Failover Chain for LLM Gateway
 *
 * Provides automatic failover between LLM providers when primary
 * providers fail or have open circuits.
 *
 * @module llm-mesh/gateway/middleware/failover
 */

'use strict';

const EventEmitter = require('events');
const { circuitBreakerManager } = require('./circuit-breaker');

/**
 * FailoverChain class
 * Manages failover logic between multiple LLM providers
 */
class FailoverChain extends EventEmitter {
  /**
   * Create a new FailoverChain
   * @param {Object} options - Chain options
   * @param {Object} options.providers - Map of provider name to provider instance
   * @param {Array<string>} options.priority - Provider priority order
   * @param {number} options.maxRetries - Max retries per provider (default: 1)
   * @param {number} options.retryDelay - Delay between retries in ms (default: 1000)
   */
  constructor(options = {}) {
    super();
    this.providers = options.providers || {};
    this.priority = options.priority || Object.keys(this.providers);
    this.maxRetries = options.maxRetries || 1;
    this.retryDelay = options.retryDelay || 1000;

    // Metrics
    this.metrics = {
      totalRequests: 0,
      successfulRequests: 0,
      failoverEvents: 0,
      failuresByProvider: {},
      successByProvider: {}
    };

    // Initialize metrics for each provider
    for (const provider of this.priority) {
      this.metrics.failuresByProvider[provider] = 0;
      this.metrics.successByProvider[provider] = 0;
    }
  }

  /**
   * Execute a request with automatic failover
   * @param {Array<Object>} messages - Chat messages
   * @param {Object} options - Request options
   * @returns {Promise<Object>} Response from the first successful provider
   */
  async execute(messages, options = {}) {
    this.metrics.totalRequests++;
    const errors = [];
    const preferredProvider = options.provider;

    // Determine provider order
    let providerOrder = [...this.priority];

    // If a preferred provider is specified, try it first
    if (preferredProvider && this.providers[preferredProvider]) {
      providerOrder = providerOrder.filter(p => p !== preferredProvider);
      providerOrder.unshift(preferredProvider);
    }

    for (const providerName of providerOrder) {
      const provider = this.providers[providerName];
      if (!provider) continue;

      // Skip providers with open circuits
      if (circuitBreakerManager.isOpen(providerName)) {
        this._log('debug', `Skipping ${providerName} - circuit is open`);
        errors.push({
          provider: providerName,
          error: 'Circuit breaker is open',
          skipped: true
        });
        continue;
      }

      // Attempt request with retries
      for (let attempt = 1; attempt <= this.maxRetries; attempt++) {
        try {
          this._log('debug', `Attempting ${providerName} (attempt ${attempt}/${this.maxRetries})`);

          const response = await this._executeWithBreaker(providerName, provider, messages, options);

          // Success!
          this.metrics.successfulRequests++;
          this.metrics.successByProvider[providerName]++;

          // Add failover metadata to response
          response.failoverMetadata = {
            primaryProvider: providerOrder[0],
            actualProvider: providerName,
            failoverOccurred: providerName !== providerOrder[0],
            attempts: errors.length + 1,
            errors: errors
          };

          if (providerName !== providerOrder[0]) {
            this.metrics.failoverEvents++;
            this.emit('failover', {
              from: providerOrder[0],
              to: providerName,
              reason: errors.length > 0 ? errors[errors.length - 1].error : 'unknown',
              timestamp: new Date().toISOString()
            });
          }

          this.emit('success', {
            provider: providerName,
            attempt,
            timestamp: new Date().toISOString()
          });

          return response;

        } catch (error) {
          this.metrics.failuresByProvider[providerName]++;

          const errorInfo = {
            provider: providerName,
            attempt,
            error: error.message,
            timestamp: new Date().toISOString()
          };

          errors.push(errorInfo);
          this._log('warn', `Provider ${providerName} failed`, errorInfo);
          this.emit('providerFailure', errorInfo);

          // If this was the last retry for this provider, move to next
          if (attempt === this.maxRetries) {
            break;
          }

          // Wait before retrying
          await this._delay(this.retryDelay * attempt);
        }
      }
    }

    // All providers failed
    const allFailedError = new Error('All providers failed');
    allFailedError.errors = errors;
    allFailedError.code = 'ALL_PROVIDERS_FAILED';

    this._log('error', 'All providers failed', { errors });
    this.emit('allProvidersFailed', {
      errors,
      timestamp: new Date().toISOString()
    });

    throw allFailedError;
  }

  /**
   * Execute request through circuit breaker
   * @private
   */
  async _executeWithBreaker(providerName, provider, messages, options) {
    const breaker = circuitBreakerManager.getBreaker(providerName);

    if (breaker) {
      // Use circuit breaker
      return await breaker.fire(messages, options);
    } else {
      // Direct call if no breaker configured
      return await provider.complete(messages, options);
    }
  }

  /**
   * Get available providers (circuits not open)
   * @returns {Array<string>} List of available provider names
   */
  getAvailableProviders() {
    return this.priority.filter(provider => {
      return this.providers[provider] && !circuitBreakerManager.isOpen(provider);
    });
  }

  /**
   * Check if any provider is available
   * @returns {boolean}
   */
  hasAvailableProvider() {
    return this.getAvailableProviders().length > 0;
  }

  /**
   * Get failover chain metrics
   * @returns {Object}
   */
  getMetrics() {
    return {
      ...this.metrics,
      successRate: this.metrics.totalRequests > 0
        ? ((this.metrics.successfulRequests / this.metrics.totalRequests) * 100).toFixed(2) + '%'
        : 'N/A',
      failoverRate: this.metrics.totalRequests > 0
        ? ((this.metrics.failoverEvents / this.metrics.totalRequests) * 100).toFixed(2) + '%'
        : 'N/A',
      availableProviders: this.getAvailableProviders(),
      providerHealth: this._getProviderHealth()
    };
  }

  /**
   * Get health status for all providers
   * @private
   */
  _getProviderHealth() {
    const health = {};
    for (const provider of this.priority) {
      health[provider] = {
        available: !circuitBreakerManager.isOpen(provider),
        state: circuitBreakerManager.getState(provider),
        health: circuitBreakerManager.getHealth(provider)
      };
    }
    return health;
  }

  /**
   * Update provider priority order
   * @param {Array<string>} newPriority - New priority order
   */
  setPriority(newPriority) {
    this.priority = newPriority;
    this._log('info', 'Provider priority updated', { priority: newPriority });
    this.emit('priorityUpdated', {
      priority: newPriority,
      timestamp: new Date().toISOString()
    });
  }

  /**
   * Add a provider to the chain
   * @param {string} name - Provider name
   * @param {Object} provider - Provider instance
   * @param {number} position - Position in priority (default: end)
   */
  addProvider(name, provider, position = -1) {
    this.providers[name] = provider;

    if (position === -1) {
      this.priority.push(name);
    } else {
      this.priority.splice(position, 0, name);
    }

    this.metrics.failuresByProvider[name] = 0;
    this.metrics.successByProvider[name] = 0;

    this._log('info', `Provider ${name} added to failover chain`, { position });
  }

  /**
   * Remove a provider from the chain
   * @param {string} name - Provider name
   */
  removeProvider(name) {
    delete this.providers[name];
    this.priority = this.priority.filter(p => p !== name);
    this._log('info', `Provider ${name} removed from failover chain`);
  }

  /**
   * Helper delay function
   * @private
   */
  _delay(ms) {
    return new Promise(resolve => setTimeout(resolve, ms));
  }

  /**
   * Log failover events
   * @private
   */
  _log(level, message, data = {}) {
    const logEntry = {
      timestamp: new Date().toISOString(),
      component: 'FailoverChain',
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
   * Reset metrics
   */
  resetMetrics() {
    this.metrics = {
      totalRequests: 0,
      successfulRequests: 0,
      failoverEvents: 0,
      failuresByProvider: {},
      successByProvider: {}
    };

    for (const provider of this.priority) {
      this.metrics.failuresByProvider[provider] = 0;
      this.metrics.successByProvider[provider] = 0;
    }
  }
}

/**
 * Create failover middleware for the gateway
 * @param {FailoverChain} failoverChain - Configured failover chain
 */
function failoverMiddleware(failoverChain) {
  return {
    name: 'failover',

    async before(request) {
      // Add failover chain to request context
      request.failoverChain = failoverChain;
      request.availableProviders = failoverChain.getAvailableProviders();
      return request;
    },

    async after(response) {
      // Add failover metrics to response
      if (response.failoverMetadata) {
        response.failover = response.failoverMetadata;
        delete response.failoverMetadata;
      }
      return response;
    }
  };
}

module.exports = {
  FailoverChain,
  failoverMiddleware
};
