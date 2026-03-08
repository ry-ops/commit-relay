/**
 * Circuit Breaker Pattern Implementation
 *
 * Provides resilience for rate-limited and failure-prone operations by implementing
 * the circuit breaker pattern with three states:
 *
 * - CLOSED: Normal operation, requests pass through
 * - OPEN: Too many failures, requests fail immediately (fail-fast)
 * - HALF_OPEN: Testing recovery, limited requests allowed
 *
 * Configuration:
 * - Failure threshold: 5 errors in 60 seconds triggers OPEN state
 * - Timeout: 30 seconds before transitioning to HALF_OPEN
 * - Success threshold: 3 consecutive successes to return to CLOSED
 *
 * Features:
 * - Metrics tracking (success/failure counts, state transitions)
 * - Event logging for observability
 * - Configurable thresholds per breaker instance
 * - Graceful degradation during failures
 */

const fs = require('fs').promises;
const path = require('path');

// Circuit breaker states
const CircuitState = {
  CLOSED: 'CLOSED',       // Normal operation
  OPEN: 'OPEN',           // Failing, reject immediately
  HALF_OPEN: 'HALF_OPEN'  // Testing recovery
};

// Default configuration
const DEFAULT_CONFIG = {
  failureThreshold: 5,           // Number of failures before opening
  failureWindow: 60000,          // Time window for failures (ms)
  openTimeout: 30000,            // Time to wait before half-open (ms)
  successThreshold: 3,           // Successes needed to close from half-open
  name: 'circuit-breaker'        // Name for logging
};

class CircuitBreaker {
  /**
   * Create a circuit breaker
   * @param {Function} action - The async function to protect
   * @param {Object} config - Configuration options
   */
  constructor(action, config = {}) {
    if (typeof action !== 'function') {
      throw new Error('Circuit breaker action must be a function');
    }

    this.action = action;
    this.config = { ...DEFAULT_CONFIG, ...config };

    // State management
    this.state = CircuitState.CLOSED;
    this.failures = [];
    this.successCount = 0;
    this.openedAt = null;

    // Metrics
    this.metrics = {
      totalCalls: 0,
      totalSuccesses: 0,
      totalFailures: 0,
      totalRejected: 0,
      stateTransitions: [],
      lastFailure: null,
      lastSuccess: null
    };

    // Event log file
    this.logFile = null;
  }

  /**
   * Execute the protected action
   * @param  {...any} args - Arguments to pass to the action
   * @returns {Promise} Result of the action
   */
  async execute(...args) {
    this.metrics.totalCalls++;

    // Check if circuit is open
    if (this.state === CircuitState.OPEN) {
      // Check if timeout has passed
      const now = Date.now();
      if (now - this.openedAt >= this.config.openTimeout) {
        this._transitionTo(CircuitState.HALF_OPEN);
      } else {
        this.metrics.totalRejected++;
        const error = new Error(`Circuit breaker is OPEN for ${this.config.name}`);
        error.code = 'CIRCUIT_OPEN';
        await this._logEvent('request_rejected', {
          reason: 'circuit_open',
          timeRemaining: this.config.openTimeout - (now - this.openedAt)
        });
        throw error;
      }
    }

    try {
      // Execute the action
      const result = await this.action(...args);

      // Record success
      await this._onSuccess();

      return result;
    } catch (error) {
      // Record failure
      await this._onFailure(error);
      throw error;
    }
  }

  /**
   * Handle successful execution
   */
  async _onSuccess() {
    this.metrics.totalSuccesses++;
    this.metrics.lastSuccess = new Date().toISOString();

    if (this.state === CircuitState.HALF_OPEN) {
      this.successCount++;

      await this._logEvent('success_in_half_open', {
        successCount: this.successCount,
        threshold: this.config.successThreshold
      });

      if (this.successCount >= this.config.successThreshold) {
        this._transitionTo(CircuitState.CLOSED);
        this.successCount = 0;
      }
    } else if (this.state === CircuitState.CLOSED) {
      // In closed state, reset success count
      this.successCount = 0;

      await this._logEvent('success', {
        state: this.state
      });
    }
  }

  /**
   * Handle failed execution
   */
  async _onFailure(error) {
    this.metrics.totalFailures++;
    this.metrics.lastFailure = {
      timestamp: new Date().toISOString(),
      error: error.message,
      code: error.code
    };

    const now = Date.now();

    // Add failure to the window
    this.failures.push(now);

    // Remove old failures outside the window
    this.failures = this.failures.filter(
      timestamp => now - timestamp < this.config.failureWindow
    );

    await this._logEvent('failure', {
      error: error.message,
      code: error.code,
      failureCount: this.failures.length,
      threshold: this.config.failureThreshold
    });

    // Check if we should open the circuit
    if (this.state === CircuitState.HALF_OPEN) {
      // Any failure in half-open should re-open
      this._transitionTo(CircuitState.OPEN);
      this.successCount = 0;
    } else if (this.state === CircuitState.CLOSED) {
      // Check failure threshold
      if (this.failures.length >= this.config.failureThreshold) {
        this._transitionTo(CircuitState.OPEN);
      }
    }
  }

  /**
   * Transition to a new state
   */
  _transitionTo(newState) {
    const oldState = this.state;
    this.state = newState;

    const transition = {
      from: oldState,
      to: newState,
      timestamp: new Date().toISOString(),
      reason: this._getTransitionReason(oldState, newState)
    };

    this.metrics.stateTransitions.push(transition);

    // Set openedAt timestamp when opening
    if (newState === CircuitState.OPEN) {
      this.openedAt = Date.now();
    }

    // Clear failures when closing
    if (newState === CircuitState.CLOSED) {
      this.failures = [];
      this.openedAt = null;
    }

    this._logEvent('state_transition', transition);

    console.log(`[CircuitBreaker:${this.config.name}] State transition: ${oldState} -> ${newState}`);
  }

  /**
   * Get human-readable transition reason
   */
  _getTransitionReason(from, to) {
    if (from === CircuitState.CLOSED && to === CircuitState.OPEN) {
      return `Failure threshold exceeded (${this.failures.length}/${this.config.failureThreshold})`;
    }
    if (from === CircuitState.OPEN && to === CircuitState.HALF_OPEN) {
      return `Timeout elapsed (${this.config.openTimeout}ms), testing recovery`;
    }
    if (from === CircuitState.HALF_OPEN && to === CircuitState.CLOSED) {
      return `Success threshold reached (${this.config.successThreshold} successes)`;
    }
    if (from === CircuitState.HALF_OPEN && to === CircuitState.OPEN) {
      return 'Failure during recovery test';
    }
    return 'Unknown transition';
  }

  /**
   * Log event for observability
   */
  async _logEvent(eventType, data = {}) {
    const event = {
      timestamp: new Date().toISOString(),
      breaker: this.config.name,
      type: eventType,
      state: this.state,
      data,
      metrics: {
        totalCalls: this.metrics.totalCalls,
        totalSuccesses: this.metrics.totalSuccesses,
        totalFailures: this.metrics.totalFailures,
        totalRejected: this.metrics.totalRejected,
        currentFailures: this.failures.length
      }
    };

    // Log to console in development
    if (process.env.NODE_ENV === 'development') {
      console.log(`[CircuitBreaker:${this.config.name}]`, eventType, data);
    }

    // Write to log file if configured
    if (this.logFile) {
      try {
        await fs.appendFile(
          this.logFile,
          JSON.stringify(event) + '\n',
          'utf-8'
        );
      } catch (error) {
        console.error(`Failed to write circuit breaker log: ${error.message}`);
      }
    }

    return event;
  }

  /**
   * Configure log file for this breaker
   */
  setLogFile(filePath) {
    this.logFile = filePath;
  }

  /**
   * Get current state
   */
  getState() {
    return this.state;
  }

  /**
   * Get metrics
   */
  getMetrics() {
    return {
      ...this.metrics,
      state: this.state,
      config: this.config,
      currentFailures: this.failures.length,
      openedAt: this.openedAt,
      openTimeRemaining: this.openedAt
        ? Math.max(0, this.config.openTimeout - (Date.now() - this.openedAt))
        : null
    };
  }

  /**
   * Force close the circuit (for testing/recovery)
   */
  forceClose() {
    this._transitionTo(CircuitState.CLOSED);
    this.failures = [];
    this.successCount = 0;
    this.openedAt = null;
  }

  /**
   * Force open the circuit (for maintenance)
   */
  forceOpen() {
    this._transitionTo(CircuitState.OPEN);
    this.openedAt = Date.now();
  }

  /**
   * Reset all metrics
   */
  resetMetrics() {
    this.metrics = {
      totalCalls: 0,
      totalSuccesses: 0,
      totalFailures: 0,
      totalRejected: 0,
      stateTransitions: [],
      lastFailure: null,
      lastSuccess: null
    };
  }
}

/**
 * Create a circuit breaker with sensible defaults
 */
function createCircuitBreaker(action, config = {}) {
  return new CircuitBreaker(action, config);
}

/**
 * Create a circuit breaker specifically for API calls
 */
function createApiCircuitBreaker(apiFunction, config = {}) {
  const defaultApiConfig = {
    failureThreshold: 5,
    failureWindow: 60000,
    openTimeout: 30000,
    successThreshold: 3,
    name: config.name || 'api-breaker'
  };

  return new CircuitBreaker(apiFunction, { ...defaultApiConfig, ...config });
}

/**
 * Create a circuit breaker specifically for rate-limited operations
 */
function createRateLimitBreaker(operation, config = {}) {
  const defaultRateLimitConfig = {
    failureThreshold: 3,      // Lower threshold for rate limits
    failureWindow: 60000,
    openTimeout: 45000,       // Longer timeout for rate limit recovery
    successThreshold: 2,      // Lower success threshold
    name: config.name || 'rate-limit-breaker'
  };

  return new CircuitBreaker(operation, { ...defaultRateLimitConfig, ...config });
}

module.exports = {
  CircuitBreaker,
  CircuitState,
  createCircuitBreaker,
  createApiCircuitBreaker,
  createRateLimitBreaker
};
