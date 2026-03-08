/**
 * Health Check System for LLM Providers
 *
 * Performs periodic health checks on LLM providers to detect
 * availability and performance issues proactively.
 *
 * @module llm-mesh/gateway/middleware/health-check
 */

'use strict';

const EventEmitter = require('events');
const { circuitBreakerManager } = require('./circuit-breaker');
const fs = require('fs');
const path = require('path');

// Load configuration
const CONFIG_PATH = path.join(__dirname, '../config/circuit-breaker.json');
let config = {
  healthCheck: {
    interval: 60000, // 1 minute
    timeout: 10000, // 10 seconds
    consecutiveFailuresThreshold: 3,
    consecutiveSuccessesThreshold: 2
  },
  providers: {}
};

try {
  if (fs.existsSync(CONFIG_PATH)) {
    const loadedConfig = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf-8'));
    config = { ...config, ...loadedConfig };
  }
} catch (error) {
  console.warn('Could not load health check config, using defaults:', error.message);
}

/**
 * Health Check Manager
 * Manages periodic health checks for all LLM providers
 */
class HealthCheckManager extends EventEmitter {
  constructor() {
    super();
    this.providers = new Map();
    this.healthStatus = new Map();
    this.checkIntervals = new Map();
    this.isRunning = false;

    // Health check history
    this.history = new Map();
  }

  /**
   * Register a provider for health monitoring
   * @param {string} name - Provider name
   * @param {Object} provider - Provider instance
   * @param {Object} options - Health check options
   */
  registerProvider(name, provider, options = {}) {
    const providerConfig = config.providers[name]?.healthCheck || {};
    const checkOptions = {
      interval: config.healthCheck.interval,
      timeout: config.healthCheck.timeout,
      ...providerConfig,
      ...options
    };

    this.providers.set(name, {
      instance: provider,
      options: checkOptions,
      consecutiveFailures: 0,
      consecutiveSuccesses: 0,
      lastCheck: null,
      lastSuccess: null,
      lastFailure: null
    });

    this.healthStatus.set(name, {
      status: 'unknown',
      lastChecked: null,
      responseTime: null,
      error: null
    });

    this.history.set(name, []);

    this._log('info', `Provider ${name} registered for health monitoring`, checkOptions);
  }

  /**
   * Start health monitoring for all providers
   */
  start() {
    if (this.isRunning) return;

    this.isRunning = true;

    for (const [name, providerData] of this.providers) {
      // Run initial check
      this.checkProvider(name);

      // Set up interval
      const interval = setInterval(
        () => this.checkProvider(name),
        providerData.options.interval
      );

      this.checkIntervals.set(name, interval);
    }

    this._log('info', 'Health monitoring started', {
      providers: Array.from(this.providers.keys())
    });

    this.emit('started', {
      providers: Array.from(this.providers.keys()),
      timestamp: new Date().toISOString()
    });
  }

  /**
   * Stop health monitoring
   */
  stop() {
    if (!this.isRunning) return;

    this.isRunning = false;

    for (const [name, interval] of this.checkIntervals) {
      clearInterval(interval);
    }

    this.checkIntervals.clear();

    this._log('info', 'Health monitoring stopped');
    this.emit('stopped', { timestamp: new Date().toISOString() });
  }

  /**
   * Check health of a specific provider
   * @param {string} name - Provider name
   * @returns {Promise<Object>} Health check result
   */
  async checkProvider(name) {
    const providerData = this.providers.get(name);
    if (!providerData) {
      return { status: 'unknown', error: 'Provider not registered' };
    }

    const startTime = Date.now();
    let result;

    try {
      // Create a timeout promise
      const timeoutPromise = new Promise((_, reject) => {
        setTimeout(() => reject(new Error('Health check timeout')), providerData.options.timeout);
      });

      // Run health check
      const checkPromise = this._performHealthCheck(name, providerData.instance);

      // Race between check and timeout
      await Promise.race([checkPromise, timeoutPromise]);

      const responseTime = Date.now() - startTime;

      // Success
      result = {
        status: 'healthy',
        responseTime,
        timestamp: new Date().toISOString()
      };

      providerData.consecutiveSuccesses++;
      providerData.consecutiveFailures = 0;
      providerData.lastSuccess = new Date().toISOString();

      // Check for recovery
      if (this.healthStatus.get(name)?.status === 'unhealthy' &&
          providerData.consecutiveSuccesses >= config.healthCheck.consecutiveSuccessesThreshold) {
        this._onRecovery(name);
      }

      this._log('debug', `Health check passed for ${name}`, { responseTime });

    } catch (error) {
      const responseTime = Date.now() - startTime;

      // Failure
      result = {
        status: 'unhealthy',
        responseTime,
        error: error.message,
        timestamp: new Date().toISOString()
      };

      providerData.consecutiveFailures++;
      providerData.consecutiveSuccesses = 0;
      providerData.lastFailure = new Date().toISOString();

      // Check for degradation
      if (providerData.consecutiveFailures >= config.healthCheck.consecutiveFailuresThreshold) {
        this._onDegraded(name, error);
      }

      this._log('warn', `Health check failed for ${name}`, {
        error: error.message,
        consecutiveFailures: providerData.consecutiveFailures
      });
    }

    providerData.lastCheck = new Date().toISOString();
    this.healthStatus.set(name, result);

    // Store in history
    const history = this.history.get(name) || [];
    history.push(result);
    if (history.length > 100) history.shift(); // Keep last 100 checks
    this.history.set(name, history);

    this.emit('checkComplete', { provider: name, result });

    return result;
  }

  /**
   * Perform the actual health check
   * @private
   */
  async _performHealthCheck(name, provider) {
    // Try different health check methods based on provider capabilities

    // Method 1: Use provider's built-in health check if available
    if (typeof provider.healthCheck === 'function') {
      return await provider.healthCheck();
    }

    // Method 2: List models as a basic connectivity check
    if (typeof provider.listModels === 'function') {
      const models = await provider.listModels();
      if (models && models.length > 0) {
        return { models: models.length };
      }
    }

    // Method 3: Simple ping/connect check
    if (typeof provider.ping === 'function') {
      return await provider.ping();
    }

    // Method 4: Try a minimal completion (if no other method available)
    if (typeof provider.complete === 'function') {
      // This is expensive, only use as last resort
      const testMessages = [{ role: 'user', content: 'ping' }];
      const options = { maxTokens: 1 };
      return await provider.complete(testMessages, options);
    }

    throw new Error('No health check method available');
  }

  /**
   * Handle provider recovery
   * @private
   */
  _onRecovery(name) {
    this._log('info', `Provider ${name} has recovered`);

    // Reset circuit breaker if open
    if (circuitBreakerManager.isOpen(name)) {
      circuitBreakerManager.reset(name);
    }

    this.emit('recovery', {
      provider: name,
      timestamp: new Date().toISOString()
    });
  }

  /**
   * Handle provider degradation
   * @private
   */
  _onDegraded(name, error) {
    this._log('error', `Provider ${name} is degraded`, { error: error.message });

    // Update status to unhealthy
    const status = this.healthStatus.get(name);
    if (status) {
      status.status = 'unhealthy';
    }

    this.emit('degraded', {
      provider: name,
      error: error.message,
      timestamp: new Date().toISOString()
    });
  }

  /**
   * Get health status for a provider
   * @param {string} name - Provider name
   * @returns {Object|null}
   */
  getStatus(name) {
    return this.healthStatus.get(name) || null;
  }

  /**
   * Get health status for all providers
   * @returns {Object}
   */
  getAllStatus() {
    const status = {};
    for (const [name, health] of this.healthStatus) {
      const providerData = this.providers.get(name);
      status[name] = {
        ...health,
        consecutiveFailures: providerData?.consecutiveFailures || 0,
        consecutiveSuccesses: providerData?.consecutiveSuccesses || 0,
        lastCheck: providerData?.lastCheck,
        circuitState: circuitBreakerManager.getState(name)
      };
    }
    return status;
  }

  /**
   * Get health check history for a provider
   * @param {string} name - Provider name
   * @param {number} limit - Number of records to return
   * @returns {Array}
   */
  getHistory(name, limit = 50) {
    const history = this.history.get(name) || [];
    return history.slice(-limit);
  }

  /**
   * Get overall system health
   * @returns {Object}
   */
  getOverallHealth() {
    const providers = Array.from(this.healthStatus.entries());
    const healthy = providers.filter(([, status]) => status.status === 'healthy').length;
    const unhealthy = providers.filter(([, status]) => status.status === 'unhealthy').length;
    const unknown = providers.filter(([, status]) => status.status === 'unknown').length;

    let overallStatus = 'healthy';
    if (unhealthy > 0 && healthy > 0) {
      overallStatus = 'degraded';
    } else if (unhealthy === providers.length || healthy === 0) {
      overallStatus = 'unhealthy';
    }

    return {
      status: overallStatus,
      totalProviders: providers.length,
      healthy,
      unhealthy,
      unknown,
      timestamp: new Date().toISOString()
    };
  }

  /**
   * Mark a provider as healthy (manual override)
   * @param {string} name - Provider name
   */
  markHealthy(name) {
    const providerData = this.providers.get(name);
    if (providerData) {
      providerData.consecutiveFailures = 0;
      providerData.consecutiveSuccesses = config.healthCheck.consecutiveSuccessesThreshold;
    }

    this.healthStatus.set(name, {
      status: 'healthy',
      lastChecked: new Date().toISOString(),
      responseTime: null,
      error: null,
      manualOverride: true
    });

    this._log('info', `Provider ${name} manually marked as healthy`);
  }

  /**
   * Mark a provider as unhealthy (manual override)
   * @param {string} name - Provider name
   * @param {string} reason - Reason for marking unhealthy
   */
  markUnhealthy(name, reason = 'Manual override') {
    const providerData = this.providers.get(name);
    if (providerData) {
      providerData.consecutiveFailures = config.healthCheck.consecutiveFailuresThreshold;
      providerData.consecutiveSuccesses = 0;
    }

    this.healthStatus.set(name, {
      status: 'unhealthy',
      lastChecked: new Date().toISOString(),
      responseTime: null,
      error: reason,
      manualOverride: true
    });

    this._log('warn', `Provider ${name} manually marked as unhealthy`, { reason });
  }

  /**
   * Log health check events
   * @private
   */
  _log(level, message, data = {}) {
    const logEntry = {
      timestamp: new Date().toISOString(),
      component: 'HealthCheckManager',
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
}

// Singleton instance
const healthCheckManager = new HealthCheckManager();

/**
 * Health check function for a single provider
 * @param {string} name - Provider name
 * @returns {Promise<Object>}
 */
async function healthCheck(name) {
  return await healthCheckManager.checkProvider(name);
}

/**
 * Health check middleware for the gateway
 */
function healthCheckMiddleware() {
  return {
    name: 'healthCheck',

    async before(request) {
      // Add health status to request context
      request.providerHealth = healthCheckManager.getAllStatus();
      return request;
    },

    async after(response) {
      // Add health info to response
      if (response.provider) {
        response.providerHealthStatus = healthCheckManager.getStatus(response.provider);
      }
      return response;
    }
  };
}

module.exports = {
  HealthCheckManager,
  healthCheckManager,
  healthCheck,
  healthCheckMiddleware
};
