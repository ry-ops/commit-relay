/**
 * SLA Monitor - Track and enforce task timeouts with escalation
 *
 * Provides SLA monitoring for task execution:
 * - Track tasks against configurable timeouts
 * - Warning at 80% of timeout (configurable)
 * - Critical alert at 95% of timeout (configurable)
 * - Timeout cancellation and escalation
 * - Metrics and breach tracking
 *
 * Part of commit-relay orchestration system.
 */

const fs = require('fs');
const path = require('path');
const EventEmitter = require('events');

// Paths
const SLA_POLICY_PATH = path.join(__dirname, '../../coordination/config/sla-policy.json');
const SLA_EVENTS_PATH = path.join(__dirname, '../../coordination/metrics/sla-events.jsonl');
const SLA_BREACHES_PATH = path.join(__dirname, '../../coordination/metrics/sla-breaches.jsonl');

/**
 * SLAMonitor class for tracking task timeouts and SLA compliance
 */
class SLAMonitor extends EventEmitter {
  constructor(options = {}) {
    super();

    this.policy = this.loadPolicy();
    this.activeTimers = new Map(); // taskId -> timer info
    this.notifier = options.notifier || null;
    this.checkInterval = null;

    // Metrics
    this.metrics = {
      total_monitored: 0,
      warnings_issued: 0,
      critical_alerts: 0,
      breaches: 0,
      tasks_completed_in_sla: 0
    };

    // Notification deduplication
    this.notificationHistory = new Map(); // taskId -> { warning: timestamp, critical: timestamp }
  }

  /**
   * Load SLA policy from configuration file
   */
  loadPolicy() {
    try {
      if (fs.existsSync(SLA_POLICY_PATH)) {
        const content = fs.readFileSync(SLA_POLICY_PATH, 'utf-8');
        return JSON.parse(content);
      }
    } catch (error) {
      console.error(`[SLAMonitor] Failed to load SLA policy: ${error.message}`);
    }

    // Return default policy
    return {
      global_settings: {
        default_timeout_ms: 300000,
        warning_threshold: 0.8,
        critical_threshold: 0.95,
        check_interval_ms: 5000
      },
      task_type_timeouts: {},
      priority_modifiers: {},
      escalation_channels: {},
      notification_config: {}
    };
  }

  /**
   * Reload policy from file (for runtime updates)
   */
  reloadPolicy() {
    this.policy = this.loadPolicy();
    console.log('[SLAMonitor] Policy reloaded');
  }

  /**
   * Set the notifier instance for sending alerts
   */
  setNotifier(notifier) {
    this.notifier = notifier;
  }

  /**
   * Get timeout configuration for a task
   */
  getTimeoutConfig(task) {
    const taskType = task.type || 'default';
    const priority = task.priority || 'P2';

    // Get base timeout from task type config or global default
    const typeConfig = this.policy.task_type_timeouts[taskType] || {};
    let timeout_ms = typeConfig.timeout_ms || this.policy.global_settings.default_timeout_ms;

    // Apply priority modifier
    const priorityMod = this.policy.priority_modifiers[priority] || { timeout_multiplier: 1.0 };
    timeout_ms = Math.round(timeout_ms * priorityMod.timeout_multiplier);

    // Get thresholds
    const warning_threshold = typeConfig.warning_threshold || this.policy.global_settings.warning_threshold;
    const critical_threshold = typeConfig.critical_threshold || this.policy.global_settings.critical_threshold;

    return {
      timeout_ms,
      warning_threshold,
      critical_threshold,
      warning_ms: Math.round(timeout_ms * warning_threshold),
      critical_ms: Math.round(timeout_ms * critical_threshold),
      escalation_immediate: priorityMod.escalation_immediate || false
    };
  }

  /**
   * Start monitoring a task against its SLA
   *
   * @param {object} task - Task to monitor
   * @returns {object} Timer info
   */
  startMonitoring(task) {
    if (!task || !task.id) {
      throw new Error('Task must have an id');
    }

    // Check max active timers
    if (this.activeTimers.size >= (this.policy.rate_limiting?.max_active_timers || 100)) {
      console.warn(`[SLAMonitor] Max active timers reached, cannot monitor task ${task.id}`);
      return null;
    }

    const config = this.getTimeoutConfig(task);
    const startTime = Date.now();

    const timerInfo = {
      task_id: task.id,
      task_type: task.type || 'unknown',
      priority: task.priority || 'P2',
      start_time: startTime,
      timeout_ms: config.timeout_ms,
      warning_ms: config.warning_ms,
      critical_ms: config.critical_ms,
      warning_threshold: config.warning_threshold,
      critical_threshold: config.critical_threshold,
      escalation_immediate: config.escalation_immediate,
      status: 'active',
      warning_sent: false,
      critical_sent: false,
      warning_timer: null,
      critical_timer: null,
      timeout_timer: null
    };

    // Set up warning timer
    timerInfo.warning_timer = setTimeout(() => {
      this.onWarning(task, timerInfo);
    }, config.warning_ms);

    // Set up critical timer
    timerInfo.critical_timer = setTimeout(() => {
      this.onCritical(task, timerInfo);
    }, config.critical_ms);

    // Set up timeout timer
    timerInfo.timeout_timer = setTimeout(() => {
      this.onTimeout(task, timerInfo);
    }, config.timeout_ms);

    // Store timer info
    this.activeTimers.set(task.id, timerInfo);
    this.metrics.total_monitored++;

    // Initialize notification history for this task
    this.notificationHistory.set(task.id, { warning: null, critical: null });

    // Emit event
    this.emit('monitoring_started', {
      task_id: task.id,
      task_type: timerInfo.task_type,
      timeout_ms: config.timeout_ms,
      start_time: new Date(startTime).toISOString()
    });

    console.log(`[SLAMonitor] Started monitoring task ${task.id} (${timerInfo.task_type}) - timeout: ${config.timeout_ms}ms`);

    return timerInfo;
  }

  /**
   * Handle warning threshold reached (80% of timeout by default)
   */
  onWarning(task, timerInfo) {
    if (!timerInfo || timerInfo.status !== 'active') return;

    timerInfo.warning_sent = true;
    this.metrics.warnings_issued++;

    const elapsed = Date.now() - timerInfo.start_time;
    const remaining = timerInfo.timeout_ms - elapsed;
    const percentage = Math.round((elapsed / timerInfo.timeout_ms) * 100);

    const event = {
      event_type: 'sla_warning',
      task_id: task.id,
      task_type: timerInfo.task_type,
      priority: timerInfo.priority,
      elapsed_ms: elapsed,
      remaining_ms: remaining,
      timeout_ms: timerInfo.timeout_ms,
      percentage,
      threshold: timerInfo.warning_threshold,
      timestamp: new Date().toISOString()
    };

    // Log event
    this.logSLAEvent(event);

    // Send notification
    if (this.notifier) {
      this.notifier.sendWarning(event);
    }

    // Emit event
    this.emit('warning', event);

    console.warn(`[SLAMonitor] WARNING: Task ${task.id} at ${percentage}% of timeout (${this.formatDuration(elapsed)} elapsed, ${this.formatDuration(remaining)} remaining)`);
  }

  /**
   * Handle critical threshold reached (95% of timeout by default)
   */
  onCritical(task, timerInfo) {
    if (!timerInfo || timerInfo.status !== 'active') return;

    timerInfo.critical_sent = true;
    this.metrics.critical_alerts++;

    const elapsed = Date.now() - timerInfo.start_time;
    const remaining = timerInfo.timeout_ms - elapsed;
    const percentage = Math.round((elapsed / timerInfo.timeout_ms) * 100);

    const event = {
      event_type: 'sla_critical',
      task_id: task.id,
      task_type: timerInfo.task_type,
      priority: timerInfo.priority,
      elapsed_ms: elapsed,
      remaining_ms: remaining,
      timeout_ms: timerInfo.timeout_ms,
      percentage,
      threshold: timerInfo.critical_threshold,
      timestamp: new Date().toISOString()
    };

    // Log event
    this.logSLAEvent(event);

    // Send notification
    if (this.notifier) {
      this.notifier.sendCritical(event);
    }

    // Emit event
    this.emit('critical', event);

    console.error(`[SLAMonitor] CRITICAL: Task ${task.id} at ${percentage}% of timeout (${this.formatDuration(remaining)} remaining). Immediate attention required!`);
  }

  /**
   * Handle timeout reached - cancel task and escalate
   */
  onTimeout(task, timerInfo) {
    if (!timerInfo || timerInfo.status !== 'active') return;

    timerInfo.status = 'breached';
    this.metrics.breaches++;

    const elapsed = Date.now() - timerInfo.start_time;

    const event = {
      event_type: 'sla_breach',
      task_id: task.id,
      task_type: timerInfo.task_type,
      priority: timerInfo.priority,
      elapsed_ms: elapsed,
      timeout_ms: timerInfo.timeout_ms,
      percentage: 100,
      timestamp: new Date().toISOString()
    };

    // Log SLA event
    this.logSLAEvent(event);

    // Log breach specifically
    this.logBreach({
      ...event,
      task: {
        id: task.id,
        type: task.type,
        title: task.title || task.description,
        priority: task.priority,
        assigned_to: task.assigned_to
      }
    });

    // Send notification
    if (this.notifier) {
      this.notifier.sendTimeout(event);
    }

    // Emit timeout event (task-executor should handle cancellation)
    this.emit('timeout', event);

    console.error(`[SLAMonitor] TIMEOUT: Task ${task.id} (${timerInfo.task_type}) exceeded SLA timeout of ${this.formatDuration(timerInfo.timeout_ms)}. Task cancelled and escalated.`);

    // Clean up
    this.clearTimer(task.id);
  }

  /**
   * Clear timer when task completes successfully
   */
  clearTimer(taskId) {
    const timerInfo = this.activeTimers.get(taskId);

    if (!timerInfo) {
      return false;
    }

    // Clear all timers
    if (timerInfo.warning_timer) clearTimeout(timerInfo.warning_timer);
    if (timerInfo.critical_timer) clearTimeout(timerInfo.critical_timer);
    if (timerInfo.timeout_timer) clearTimeout(timerInfo.timeout_timer);

    // Track success if not breached
    if (timerInfo.status === 'active') {
      timerInfo.status = 'completed';
      this.metrics.tasks_completed_in_sla++;

      const elapsed = Date.now() - timerInfo.start_time;
      const percentage = Math.round((elapsed / timerInfo.timeout_ms) * 100);

      // Emit completion event
      this.emit('completed', {
        task_id: taskId,
        task_type: timerInfo.task_type,
        elapsed_ms: elapsed,
        timeout_ms: timerInfo.timeout_ms,
        percentage,
        timestamp: new Date().toISOString()
      });

      console.log(`[SLAMonitor] Task ${taskId} completed within SLA (${this.formatDuration(elapsed)} / ${this.formatDuration(timerInfo.timeout_ms)} = ${percentage}%)`);
    }

    // Remove from active timers
    this.activeTimers.delete(taskId);
    this.notificationHistory.delete(taskId);

    return true;
  }

  /**
   * Get status of all active SLA timers
   */
  getActiveTimers() {
    const now = Date.now();
    const timers = [];

    for (const [taskId, timerInfo] of this.activeTimers) {
      const elapsed = now - timerInfo.start_time;
      const remaining = timerInfo.timeout_ms - elapsed;
      const percentage = Math.round((elapsed / timerInfo.timeout_ms) * 100);

      timers.push({
        task_id: taskId,
        task_type: timerInfo.task_type,
        priority: timerInfo.priority,
        status: timerInfo.status,
        elapsed_ms: elapsed,
        remaining_ms: Math.max(0, remaining),
        timeout_ms: timerInfo.timeout_ms,
        percentage: Math.min(100, percentage),
        warning_sent: timerInfo.warning_sent,
        critical_sent: timerInfo.critical_sent,
        start_time: new Date(timerInfo.start_time).toISOString()
      });
    }

    // Sort by remaining time (most urgent first)
    timers.sort((a, b) => a.remaining_ms - b.remaining_ms);

    return timers;
  }

  /**
   * Get SLA metrics
   */
  getMetrics() {
    return {
      ...this.metrics,
      active_timers: this.activeTimers.size,
      sla_compliance_rate: this.metrics.total_monitored > 0
        ? (this.metrics.tasks_completed_in_sla / this.metrics.total_monitored * 100).toFixed(2) + '%'
        : 'N/A',
      breach_rate: this.metrics.total_monitored > 0
        ? (this.metrics.breaches / this.metrics.total_monitored * 100).toFixed(2) + '%'
        : 'N/A'
    };
  }

  /**
   * Log SLA event to events file
   */
  logSLAEvent(event) {
    try {
      const dir = path.dirname(SLA_EVENTS_PATH);
      if (!fs.existsSync(dir)) {
        fs.mkdirSync(dir, { recursive: true });
      }
      fs.appendFileSync(SLA_EVENTS_PATH, JSON.stringify(event) + '\n');
    } catch (error) {
      console.error(`[SLAMonitor] Failed to log SLA event: ${error.message}`);
    }
  }

  /**
   * Log SLA breach to breaches file
   */
  logBreach(breach) {
    try {
      const dir = path.dirname(SLA_BREACHES_PATH);
      if (!fs.existsSync(dir)) {
        fs.mkdirSync(dir, { recursive: true });
      }
      fs.appendFileSync(SLA_BREACHES_PATH, JSON.stringify(breach) + '\n');
    } catch (error) {
      console.error(`[SLAMonitor] Failed to log breach: ${error.message}`);
    }
  }

  /**
   * Get recent SLA breaches
   */
  getRecentBreaches(limit = 20) {
    try {
      if (!fs.existsSync(SLA_BREACHES_PATH)) {
        return [];
      }

      const content = fs.readFileSync(SLA_BREACHES_PATH, 'utf-8');
      const lines = content.trim().split('\n').filter(line => line);

      const breaches = lines
        .map(line => {
          try {
            return JSON.parse(line);
          } catch {
            return null;
          }
        })
        .filter(breach => breach !== null)
        .slice(-limit)
        .reverse();

      return breaches;
    } catch (error) {
      console.error(`[SLAMonitor] Failed to read breaches: ${error.message}`);
      return [];
    }
  }

  /**
   * Get recent SLA events
   */
  getRecentEvents(limit = 50, eventType = null) {
    try {
      if (!fs.existsSync(SLA_EVENTS_PATH)) {
        return [];
      }

      const content = fs.readFileSync(SLA_EVENTS_PATH, 'utf-8');
      const lines = content.trim().split('\n').filter(line => line);

      let events = lines
        .map(line => {
          try {
            return JSON.parse(line);
          } catch {
            return null;
          }
        })
        .filter(event => event !== null);

      // Filter by event type if specified
      if (eventType) {
        events = events.filter(e => e.event_type === eventType);
      }

      return events.slice(-limit).reverse();
    } catch (error) {
      console.error(`[SLAMonitor] Failed to read events: ${error.message}`);
      return [];
    }
  }

  /**
   * Format duration in human-readable format
   */
  formatDuration(ms) {
    if (ms < 1000) return `${ms}ms`;
    if (ms < 60000) return `${(ms / 1000).toFixed(1)}s`;
    if (ms < 3600000) return `${(ms / 60000).toFixed(1)}m`;
    return `${(ms / 3600000).toFixed(1)}h`;
  }

  /**
   * Check if task is being monitored
   */
  isMonitoring(taskId) {
    return this.activeTimers.has(taskId);
  }

  /**
   * Get timer info for a specific task
   */
  getTimerInfo(taskId) {
    return this.activeTimers.get(taskId) || null;
  }

  /**
   * Extend timeout for a task (e.g., when making progress)
   */
  extendTimeout(taskId, additionalMs) {
    const timerInfo = this.activeTimers.get(taskId);

    if (!timerInfo || timerInfo.status !== 'active') {
      return false;
    }

    // Clear existing timers
    if (timerInfo.timeout_timer) clearTimeout(timerInfo.timeout_timer);

    // Update timeout
    timerInfo.timeout_ms += additionalMs;
    timerInfo.warning_ms = Math.round(timerInfo.timeout_ms * timerInfo.warning_threshold);
    timerInfo.critical_ms = Math.round(timerInfo.timeout_ms * timerInfo.critical_threshold);

    // Calculate new remaining times
    const elapsed = Date.now() - timerInfo.start_time;
    const newTimeoutRemaining = timerInfo.timeout_ms - elapsed;

    // Set new timeout timer
    if (newTimeoutRemaining > 0) {
      timerInfo.timeout_timer = setTimeout(() => {
        this.onTimeout({ id: taskId, type: timerInfo.task_type, priority: timerInfo.priority }, timerInfo);
      }, newTimeoutRemaining);
    }

    console.log(`[SLAMonitor] Extended timeout for task ${taskId} by ${this.formatDuration(additionalMs)}. New timeout: ${this.formatDuration(timerInfo.timeout_ms)}`);

    return true;
  }

  /**
   * Stop monitoring all tasks (cleanup)
   */
  stopAll() {
    for (const [taskId, timerInfo] of this.activeTimers) {
      if (timerInfo.warning_timer) clearTimeout(timerInfo.warning_timer);
      if (timerInfo.critical_timer) clearTimeout(timerInfo.critical_timer);
      if (timerInfo.timeout_timer) clearTimeout(timerInfo.timeout_timer);
    }

    this.activeTimers.clear();
    this.notificationHistory.clear();

    console.log('[SLAMonitor] All timers stopped');
  }

  /**
   * Get current policy configuration
   */
  getPolicy() {
    return this.policy;
  }
}

// Singleton instance
let slaMonitorInstance = null;

/**
 * Get or create SLA monitor instance
 */
function getSLAMonitor(options = {}) {
  if (!slaMonitorInstance) {
    slaMonitorInstance = new SLAMonitor(options);
  }
  return slaMonitorInstance;
}

/**
 * Create new SLA monitor instance (for testing)
 */
function createSLAMonitor(options = {}) {
  return new SLAMonitor(options);
}

module.exports = {
  SLAMonitor,
  getSLAMonitor,
  createSLAMonitor
};
