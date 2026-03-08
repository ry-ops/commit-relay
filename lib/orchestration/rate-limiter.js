/**
 * Rate Limiter - Token Bucket Algorithm for Orchestration
 *
 * Provides rate limiting for task execution:
 * - Per-master concurrent task limits
 * - Token bucket algorithm for request rate
 * - Sliding window for burst handling
 * - Graceful degradation under load
 *
 * Part of commit-relay orchestration system.
 */

const fs = require('fs');
const path = require('path');
const EventEmitter = require('events');

// Default configuration
const DEFAULT_CONFIG = {
  global_rate: 100, // requests per second
  global_burst: 200, // max burst size
  default_master_concurrent: 10,
  default_master_rate: 20,
  per_master_limits: {
    security: {
      concurrent: 5,
      rate: 10,
      burst: 15
    },
    development: {
      concurrent: 10,
      rate: 25,
      burst: 40
    },
    inventory: {
      concurrent: 8,
      rate: 15,
      burst: 25
    },
    cicd: {
      concurrent: 8,
      rate: 20,
      burst: 30
    },
    coordinator: {
      concurrent: 15,
      rate: 30,
      burst: 50
    }
  },
  refill_interval_ms: 100,
  cleanup_interval_ms: 60000
};

// Paths
const QUEUE_POLICY_PATH = path.join(__dirname, '../../coordination/config/queue-policy.json');
const RATE_LIMIT_METRICS_PATH = path.join(__dirname, '../../coordination/metrics/rate-limit-metrics.jsonl');

/**
 * Custom error for rate limit exceeded
 */
class RateLimitError extends Error {
  constructor(message, details = {}) {
    super(message);
    this.name = 'RateLimitError';
    this.code = 'RATE_LIMIT_EXCEEDED';
    this.details = details;
  }
}

/**
 * Token bucket implementation
 */
class TokenBucket {
  constructor(rate, burst) {
    this.rate = rate; // tokens per second
    this.burst = burst; // max tokens
    this.tokens = burst; // start full
    this.lastRefill = Date.now();
  }

  /**
   * Refill tokens based on elapsed time
   */
  refill() {
    const now = Date.now();
    const elapsed = (now - this.lastRefill) / 1000; // seconds
    const tokensToAdd = elapsed * this.rate;

    this.tokens = Math.min(this.burst, this.tokens + tokensToAdd);
    this.lastRefill = now;
  }

  /**
   * Try to consume tokens
   */
  consume(count = 1) {
    this.refill();

    if (this.tokens >= count) {
      this.tokens -= count;
      return true;
    }

    return false;
  }

  /**
   * Check if tokens available without consuming
   */
  check(count = 1) {
    this.refill();
    return this.tokens >= count;
  }

  /**
   * Get time until tokens available
   */
  getWaitTime(count = 1) {
    this.refill();

    if (this.tokens >= count) {
      return 0;
    }

    const needed = count - this.tokens;
    return (needed / this.rate) * 1000; // ms
  }

  /**
   * Get current state
   */
  getState() {
    this.refill();
    return {
      tokens: this.tokens,
      rate: this.rate,
      burst: this.burst,
      utilization: 1 - (this.tokens / this.burst)
    };
  }
}

/**
 * RateLimiter class with per-master limits
 */
class RateLimiter extends EventEmitter {
  constructor(options = {}) {
    super();

    this.config = this.loadConfig(options);

    // Global token bucket
    this.globalBucket = new TokenBucket(
      this.config.global_rate,
      this.config.global_burst
    );

    // Per-master buckets
    this.masterBuckets = new Map();

    // Per-master active task counts
    this.activeTasks = new Map();

    // Request tracking for metrics
    this.requestHistory = [];
    this.requestWindowMs = 60000; // 1 minute window

    // Metrics
    this.metrics = {
      total_requests: 0,
      total_allowed: 0,
      total_rejected: 0,
      total_waited: 0,
      avg_wait_time_ms: 0,
      started_at: new Date().toISOString()
    };

    // Cleanup interval
    this.cleanupInterval = setInterval(() => {
      this.cleanup();
    }, this.config.cleanup_interval_ms);

    // Metrics logging interval
    this.metricsInterval = setInterval(() => {
      this.logMetrics();
    }, 10000); // Log every 10 seconds
  }

  /**
   * Load configuration from file or use defaults
   */
  loadConfig(options) {
    let fileConfig = {};

    try {
      if (fs.existsSync(QUEUE_POLICY_PATH)) {
        const content = fs.readFileSync(QUEUE_POLICY_PATH, 'utf-8');
        fileConfig = JSON.parse(content);
      }
    } catch (error) {
      console.warn(`[RateLimiter] Failed to load config: ${error.message}`);
    }

    return {
      ...DEFAULT_CONFIG,
      ...fileConfig,
      ...options
    };
  }

  /**
   * Get or create bucket for master
   */
  getMasterBucket(master) {
    if (!this.masterBuckets.has(master)) {
      const limits = this.config.per_master_limits[master] || {
        rate: this.config.default_master_rate,
        burst: this.config.default_master_rate * 2
      };

      this.masterBuckets.set(master, new TokenBucket(limits.rate, limits.burst));
    }

    return this.masterBuckets.get(master);
  }

  /**
   * Get concurrent limit for master
   */
  getMasterConcurrentLimit(master) {
    const limits = this.config.per_master_limits[master];
    return limits?.concurrent || this.config.default_master_concurrent;
  }

  /**
   * Get current active count for master
   */
  getActiveCount(master) {
    return this.activeTasks.get(master) || 0;
  }

  /**
   * Check if request is within limits (without consuming)
   *
   * @param {string} master - Master identifier
   * @returns {object} Check result with allowed status and details
   */
  checkLimit(master) {
    this.metrics.total_requests++;

    // Check global rate
    if (!this.globalBucket.check()) {
      return {
        allowed: false,
        reason: 'global_rate_exceeded',
        wait_time_ms: this.globalBucket.getWaitTime(),
        global_state: this.globalBucket.getState()
      };
    }

    // Check master rate
    const masterBucket = this.getMasterBucket(master);
    if (!masterBucket.check()) {
      return {
        allowed: false,
        reason: 'master_rate_exceeded',
        master,
        wait_time_ms: masterBucket.getWaitTime(),
        master_state: masterBucket.getState()
      };
    }

    // Check master concurrent limit
    const activeCount = this.getActiveCount(master);
    const concurrentLimit = this.getMasterConcurrentLimit(master);

    if (activeCount >= concurrentLimit) {
      return {
        allowed: false,
        reason: 'concurrent_limit_exceeded',
        master,
        active: activeCount,
        limit: concurrentLimit
      };
    }

    return {
      allowed: true,
      master,
      active: activeCount,
      limit: concurrentLimit,
      global_state: this.globalBucket.getState(),
      master_state: masterBucket.getState()
    };
  }

  /**
   * Consume rate limit tokens and increment active count
   *
   * @param {string} master - Master identifier
   * @returns {object} Consumption result
   * @throws {RateLimitError} When limit exceeded
   */
  consume(master) {
    const check = this.checkLimit(master);

    if (!check.allowed) {
      this.metrics.total_rejected++;
      this.emit('rejected', { master, reason: check.reason, details: check });

      throw new RateLimitError(`Rate limit exceeded: ${check.reason}`, check);
    }

    // Consume tokens
    this.globalBucket.consume();
    this.getMasterBucket(master).consume();

    // Increment active count
    const currentActive = this.getActiveCount(master);
    this.activeTasks.set(master, currentActive + 1);

    // Track request
    this.requestHistory.push({
      timestamp: Date.now(),
      master,
      allowed: true
    });

    this.metrics.total_allowed++;
    this.emit('consumed', { master, active: currentActive + 1 });

    return {
      success: true,
      master,
      active: currentActive + 1,
      limit: this.getMasterConcurrentLimit(master)
    };
  }

  /**
   * Release an active task slot
   *
   * @param {string} master - Master identifier
   */
  release(master) {
    const currentActive = this.getActiveCount(master);

    if (currentActive > 0) {
      this.activeTasks.set(master, currentActive - 1);
      this.emit('released', { master, active: currentActive - 1 });
    }
  }

  /**
   * Wait for rate limit to allow request
   *
   * @param {string} master - Master identifier
   * @param {number} timeout - Max wait time in ms
   * @returns {Promise<object>} Result when allowed
   */
  async waitForLimit(master, timeout = 30000) {
    const startTime = Date.now();

    while (true) {
      const check = this.checkLimit(master);

      if (check.allowed) {
        const waitTime = Date.now() - startTime;
        if (waitTime > 0) {
          this.metrics.total_waited++;
          this.updateWaitTimeAverage(waitTime);
        }
        return this.consume(master);
      }

      // Check timeout
      const elapsed = Date.now() - startTime;
      if (elapsed >= timeout) {
        throw new RateLimitError('Timeout waiting for rate limit', {
          master,
          timeout,
          elapsed,
          last_check: check
        });
      }

      // Wait before retry
      const waitTime = Math.min(check.wait_time_ms || 100, timeout - elapsed);
      await new Promise(resolve => setTimeout(resolve, waitTime));
    }
  }

  /**
   * Get rate limiter status
   */
  getStatus() {
    const masterStatus = {};

    for (const [master, bucket] of this.masterBuckets) {
      masterStatus[master] = {
        active: this.getActiveCount(master),
        limit: this.getMasterConcurrentLimit(master),
        bucket: bucket.getState()
      };
    }

    // Add any masters with active tasks but no bucket yet
    for (const [master, count] of this.activeTasks) {
      if (!masterStatus[master]) {
        masterStatus[master] = {
          active: count,
          limit: this.getMasterConcurrentLimit(master),
          bucket: this.getMasterBucket(master).getState()
        };
      }
    }

    return {
      global: this.globalBucket.getState(),
      masters: masterStatus,
      total_active: Array.from(this.activeTasks.values()).reduce((a, b) => a + b, 0)
    };
  }

  /**
   * Get rate limiter metrics
   */
  getMetrics() {
    // Calculate current request rate
    const windowStart = Date.now() - this.requestWindowMs;
    const recentRequests = this.requestHistory.filter(r => r.timestamp > windowStart);

    return {
      ...this.metrics,
      current_request_rate: recentRequests.length / (this.requestWindowMs / 1000),
      requests_in_window: recentRequests.length,
      rejection_rate: this.metrics.total_requests > 0
        ? this.metrics.total_rejected / this.metrics.total_requests
        : 0,
      status: this.getStatus()
    };
  }

  /**
   * Update running average of wait times
   */
  updateWaitTimeAverage(waitTime) {
    const n = this.metrics.total_waited;
    this.metrics.avg_wait_time_ms =
      ((this.metrics.avg_wait_time_ms * (n - 1)) + waitTime) / n;
  }

  /**
   * Cleanup old request history
   */
  cleanup() {
    const windowStart = Date.now() - this.requestWindowMs;
    this.requestHistory = this.requestHistory.filter(r => r.timestamp > windowStart);
  }

  /**
   * Log metrics to file
   */
  async logMetrics() {
    const entry = {
      timestamp: new Date().toISOString(),
      ...this.getMetrics()
    };

    try {
      const dir = path.dirname(RATE_LIMIT_METRICS_PATH);
      if (!fs.existsSync(dir)) {
        fs.mkdirSync(dir, { recursive: true });
      }
      fs.appendFileSync(RATE_LIMIT_METRICS_PATH, JSON.stringify(entry) + '\n');
    } catch (error) {
      console.error(`[RateLimiter] Failed to log metrics: ${error.message}`);
    }
  }

  /**
   * Reset all limits and counters
   */
  reset() {
    this.globalBucket = new TokenBucket(
      this.config.global_rate,
      this.config.global_burst
    );
    this.masterBuckets.clear();
    this.activeTasks.clear();
    this.requestHistory = [];

    this.emit('reset');
  }

  /**
   * Update configuration dynamically
   */
  updateConfig(newConfig) {
    this.config = {
      ...this.config,
      ...newConfig
    };

    // Update global bucket
    this.globalBucket = new TokenBucket(
      this.config.global_rate,
      this.config.global_burst
    );

    // Clear master buckets to recreate with new config
    this.masterBuckets.clear();

    this.emit('config_updated', this.config);
  }

  /**
   * Stop the rate limiter
   */
  stop() {
    if (this.cleanupInterval) {
      clearInterval(this.cleanupInterval);
      this.cleanupInterval = null;
    }

    if (this.metricsInterval) {
      clearInterval(this.metricsInterval);
      this.metricsInterval = null;
    }

    this.emit('stopped');
  }
}

/**
 * Factory function to create RateLimiter
 */
function createRateLimiter(options = {}) {
  return new RateLimiter(options);
}

module.exports = {
  RateLimiter,
  RateLimitError,
  TokenBucket,
  createRateLimiter
};
