/**
 * Queue Manager - Backpressure and Task Queuing for Orchestration
 *
 * Provides a priority-based task queue with backpressure handling:
 * - Priority-based ordering (critical, high, medium, low)
 * - Overflow protection with BackpressureError
 * - Concurrency limits for task processing
 * - Queue metrics and status monitoring
 *
 * Part of commit-relay orchestration system.
 */

const fs = require('fs');
const path = require('path');
const EventEmitter = require('events');

// Default configuration
const DEFAULT_CONFIG = {
  max_queue_size: 1000,
  max_concurrent: 50,
  priority_weights: {
    critical: 100,
    high: 75,
    medium: 50,
    low: 25
  },
  overflow_action: 'reject', // 'reject' or 'drop_lowest'
  processing_interval_ms: 100,
  metrics_interval_ms: 5000
};

// Paths
const QUEUE_POLICY_PATH = path.join(__dirname, '../../coordination/config/queue-policy.json');
const QUEUE_METRICS_PATH = path.join(__dirname, '../../coordination/metrics/queue-metrics.jsonl');

/**
 * Custom error for backpressure conditions
 */
class BackpressureError extends Error {
  constructor(message, details = {}) {
    super(message);
    this.name = 'BackpressureError';
    this.code = 'QUEUE_FULL';
    this.details = details;
  }
}

/**
 * QueueManager class with backpressure handling
 */
class QueueManager extends EventEmitter {
  constructor(options = {}) {
    super();

    this.config = this.loadConfig(options);
    this.queue = [];
    this.processing = new Map(); // task_id -> task
    this.paused = false;
    this.processingInterval = null;
    this.metricsInterval = null;

    // Metrics
    this.metrics = {
      total_enqueued: 0,
      total_processed: 0,
      total_rejected: 0,
      total_dropped: 0,
      total_errors: 0,
      avg_wait_time_ms: 0,
      avg_processing_time_ms: 0,
      peak_queue_size: 0,
      current_throughput: 0,
      started_at: new Date().toISOString()
    };

    // Throughput tracking
    this.throughputWindow = [];
    this.throughputWindowSize = 60; // Track last 60 samples
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
      console.warn(`[QueueManager] Failed to load config: ${error.message}`);
    }

    return {
      ...DEFAULT_CONFIG,
      ...fileConfig,
      ...options
    };
  }

  /**
   * Enqueue a task with overflow protection
   *
   * @param {object} task - Task to enqueue
   * @returns {object} Enqueue result with position
   * @throws {BackpressureError} When queue is full
   */
  enqueue(task) {
    // Validate task
    if (!task || !task.id) {
      throw new Error('Task must have an id');
    }

    // Check for duplicates
    if (this.queue.some(t => t.id === task.id) || this.processing.has(task.id)) {
      throw new Error(`Task ${task.id} already in queue or processing`);
    }

    // Check queue capacity
    if (this.queue.length >= this.config.max_queue_size) {
      if (this.config.overflow_action === 'drop_lowest') {
        // Drop lowest priority task
        const dropped = this.dropLowestPriority(task);
        if (!dropped) {
          this.metrics.total_rejected++;
          throw new BackpressureError('Queue full and cannot drop lower priority task', {
            queue_size: this.queue.length,
            max_size: this.config.max_queue_size,
            task_priority: task.priority
          });
        }
      } else {
        // Reject the task
        this.metrics.total_rejected++;
        throw new BackpressureError('Queue full - backpressure active', {
          queue_size: this.queue.length,
          max_size: this.config.max_queue_size,
          retry_after_ms: 1000
        });
      }
    }

    // Prepare task for queue
    const queuedTask = {
      ...task,
      priority: task.priority || 'medium',
      enqueued_at: Date.now(),
      attempts: 0
    };

    // Calculate priority score for ordering
    queuedTask._priority_score = this.calculatePriorityScore(queuedTask);

    // Insert in priority order
    this.insertByPriority(queuedTask);

    // Update metrics
    this.metrics.total_enqueued++;
    if (this.queue.length > this.metrics.peak_queue_size) {
      this.metrics.peak_queue_size = this.queue.length;
    }

    // Emit event
    this.emit('enqueued', queuedTask);

    // Find position
    const position = this.queue.findIndex(t => t.id === task.id);

    return {
      task_id: task.id,
      position,
      queue_size: this.queue.length,
      estimated_wait_ms: this.estimateWaitTime(position)
    };
  }

  /**
   * Calculate priority score for ordering
   */
  calculatePriorityScore(task) {
    const baseScore = this.config.priority_weights[task.priority] || 50;

    // Add time-based bonus to prevent starvation
    // Older tasks get slight priority boost
    const ageBonus = Math.min(10, (Date.now() - task.enqueued_at) / 10000);

    // Master-specific priority adjustments
    let masterBonus = 0;
    if (task.master) {
      const masterLimits = this.config.per_master_limits || {};
      const masterConfig = masterLimits[task.master];
      if (masterConfig && masterConfig.priority_boost) {
        masterBonus = masterConfig.priority_boost;
      }
    }

    return baseScore + ageBonus + masterBonus;
  }

  /**
   * Insert task in priority order (highest first)
   */
  insertByPriority(task) {
    let insertIndex = this.queue.length;

    for (let i = 0; i < this.queue.length; i++) {
      if (task._priority_score > this.queue[i]._priority_score) {
        insertIndex = i;
        break;
      }
    }

    this.queue.splice(insertIndex, 0, task);
  }

  /**
   * Drop lowest priority task to make room
   */
  dropLowestPriority(newTask) {
    const newScore = this.calculatePriorityScore({
      ...newTask,
      enqueued_at: Date.now()
    });

    // Find lowest priority task
    let lowestIndex = -1;
    let lowestScore = newScore;

    for (let i = this.queue.length - 1; i >= 0; i--) {
      if (this.queue[i]._priority_score < lowestScore) {
        lowestIndex = i;
        lowestScore = this.queue[i]._priority_score;
        break; // Queue is sorted, so last item is lowest
      }
    }

    if (lowestIndex >= 0) {
      const dropped = this.queue.splice(lowestIndex, 1)[0];
      this.metrics.total_dropped++;
      this.emit('dropped', dropped);
      return dropped;
    }

    return null;
  }

  /**
   * Dequeue next task for processing
   */
  dequeue() {
    if (this.queue.length === 0) {
      return null;
    }

    // Check concurrency limit
    if (this.processing.size >= this.config.max_concurrent) {
      return null;
    }

    // Get highest priority task (first in queue)
    const task = this.queue.shift();

    if (task) {
      task.started_at = Date.now();
      task.wait_time_ms = task.started_at - task.enqueued_at;
      this.processing.set(task.id, task);

      // Update wait time average
      this.updateWaitTimeAverage(task.wait_time_ms);

      this.emit('dequeued', task);
    }

    return task;
  }

  /**
   * Mark task as complete
   */
  complete(taskId, result = {}) {
    const task = this.processing.get(taskId);

    if (!task) {
      return false;
    }

    this.processing.delete(taskId);

    const processingTime = Date.now() - task.started_at;
    this.updateProcessingTimeAverage(processingTime);

    this.metrics.total_processed++;
    this.throughputWindow.push(Date.now());

    // Trim throughput window
    const windowStart = Date.now() - (this.throughputWindowSize * 1000);
    this.throughputWindow = this.throughputWindow.filter(t => t > windowStart);

    this.emit('completed', { task, result, processing_time_ms: processingTime });

    return true;
  }

  /**
   * Mark task as failed
   */
  fail(taskId, error = {}) {
    const task = this.processing.get(taskId);

    if (!task) {
      return false;
    }

    this.processing.delete(taskId);
    this.metrics.total_errors++;

    this.emit('failed', { task, error });

    return true;
  }

  /**
   * Retry a failed task
   */
  retry(taskId, maxRetries = 3) {
    const task = this.processing.get(taskId);

    if (!task) {
      return false;
    }

    task.attempts++;

    if (task.attempts >= maxRetries) {
      return this.fail(taskId, { reason: 'max_retries_exceeded' });
    }

    // Remove from processing
    this.processing.delete(taskId);

    // Re-enqueue with slight priority penalty
    task._priority_score = Math.max(0, task._priority_score - 5);
    this.insertByPriority(task);

    this.emit('retried', task);

    return true;
  }

  /**
   * Process queue - called periodically
   */
  async processQueue(handler) {
    if (this.paused) {
      return { processed: 0, reason: 'paused' };
    }

    let processed = 0;

    while (this.processing.size < this.config.max_concurrent && this.queue.length > 0) {
      const task = this.dequeue();

      if (!task) {
        break;
      }

      try {
        if (handler) {
          // Execute handler asynchronously
          handler(task)
            .then(result => this.complete(task.id, result))
            .catch(error => {
              console.error(`[QueueManager] Task ${task.id} failed:`, error.message);
              this.fail(task.id, { message: error.message });
            });
        }

        processed++;
      } catch (error) {
        this.fail(task.id, { message: error.message });
      }
    }

    return { processed };
  }

  /**
   * Start automatic queue processing
   */
  start(handler) {
    if (this.processingInterval) {
      return;
    }

    this.paused = false;

    this.processingInterval = setInterval(() => {
      this.processQueue(handler);
    }, this.config.processing_interval_ms);

    this.metricsInterval = setInterval(() => {
      this.logMetrics();
    }, this.config.metrics_interval_ms);

    this.emit('started');
  }

  /**
   * Stop queue processing
   */
  stop() {
    if (this.processingInterval) {
      clearInterval(this.processingInterval);
      this.processingInterval = null;
    }

    if (this.metricsInterval) {
      clearInterval(this.metricsInterval);
      this.metricsInterval = null;
    }

    this.emit('stopped');
  }

  /**
   * Pause queue processing
   */
  pause() {
    this.paused = true;
    this.emit('paused');
  }

  /**
   * Resume queue processing
   */
  resume() {
    this.paused = false;
    this.emit('resumed');
  }

  /**
   * Get queue status
   */
  getStatus() {
    return {
      queue_depth: this.queue.length,
      active_tasks: this.processing.size,
      max_queue_size: this.config.max_queue_size,
      max_concurrent: this.config.max_concurrent,
      paused: this.paused,
      utilization: this.processing.size / this.config.max_concurrent,
      priority_distribution: this.getPriorityDistribution(),
      master_distribution: this.getMasterDistribution()
    };
  }

  /**
   * Get queue metrics
   */
  getMetrics() {
    // Calculate current throughput (tasks per second)
    const windowStart = Date.now() - (this.throughputWindowSize * 1000);
    const recentTasks = this.throughputWindow.filter(t => t > windowStart).length;
    this.metrics.current_throughput = recentTasks / this.throughputWindowSize;

    return {
      ...this.metrics,
      queue_depth: this.queue.length,
      active_tasks: this.processing.size,
      uptime_ms: Date.now() - new Date(this.metrics.started_at).getTime()
    };
  }

  /**
   * Get priority distribution in queue
   */
  getPriorityDistribution() {
    const distribution = {
      critical: 0,
      high: 0,
      medium: 0,
      low: 0
    };

    for (const task of this.queue) {
      const priority = task.priority || 'medium';
      distribution[priority] = (distribution[priority] || 0) + 1;
    }

    return distribution;
  }

  /**
   * Get master distribution in queue
   */
  getMasterDistribution() {
    const distribution = {};

    for (const task of this.queue) {
      const master = task.master || 'unknown';
      distribution[master] = (distribution[master] || 0) + 1;
    }

    return distribution;
  }

  /**
   * Estimate wait time for position
   */
  estimateWaitTime(position) {
    if (this.metrics.avg_processing_time_ms === 0) {
      return position * 100; // Default estimate
    }

    const tasksAhead = position;
    const concurrent = this.config.max_concurrent;
    const batches = Math.ceil(tasksAhead / concurrent);

    return batches * this.metrics.avg_processing_time_ms;
  }

  /**
   * Update running average of wait times
   */
  updateWaitTimeAverage(waitTime) {
    const n = this.metrics.total_processed + 1;
    this.metrics.avg_wait_time_ms =
      ((this.metrics.avg_wait_time_ms * (n - 1)) + waitTime) / n;
  }

  /**
   * Update running average of processing times
   */
  updateProcessingTimeAverage(processingTime) {
    const n = this.metrics.total_processed;
    if (n === 0) {
      this.metrics.avg_processing_time_ms = processingTime;
    } else {
      this.metrics.avg_processing_time_ms =
        ((this.metrics.avg_processing_time_ms * (n - 1)) + processingTime) / n;
    }
  }

  /**
   * Log metrics to file
   */
  async logMetrics() {
    const entry = {
      timestamp: new Date().toISOString(),
      ...this.getMetrics(),
      status: this.getStatus()
    };

    try {
      const dir = path.dirname(QUEUE_METRICS_PATH);
      if (!fs.existsSync(dir)) {
        fs.mkdirSync(dir, { recursive: true });
      }
      fs.appendFileSync(QUEUE_METRICS_PATH, JSON.stringify(entry) + '\n');
    } catch (error) {
      console.error(`[QueueManager] Failed to log metrics: ${error.message}`);
    }
  }

  /**
   * Clear all tasks from queue
   */
  clear() {
    const cleared = this.queue.length;
    this.queue = [];
    this.emit('cleared', { count: cleared });
    return cleared;
  }

  /**
   * Get task by ID
   */
  getTask(taskId) {
    const queued = this.queue.find(t => t.id === taskId);
    if (queued) {
      return { status: 'queued', task: queued };
    }

    const processing = this.processing.get(taskId);
    if (processing) {
      return { status: 'processing', task: processing };
    }

    return null;
  }

  /**
   * Remove task from queue
   */
  remove(taskId) {
    const index = this.queue.findIndex(t => t.id === taskId);
    if (index >= 0) {
      const removed = this.queue.splice(index, 1)[0];
      this.emit('removed', removed);
      return removed;
    }
    return null;
  }
}

/**
 * Factory function to create QueueManager
 */
function createQueueManager(options = {}) {
  return new QueueManager(options);
}

module.exports = {
  QueueManager,
  BackpressureError,
  createQueueManager
};
