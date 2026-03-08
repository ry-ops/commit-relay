/**
 * SLA API Routes
 *
 * Provides endpoints for monitoring SLA compliance,
 * viewing active timers, and checking breaches.
 *
 * @module api-server/routes/sla
 */

'use strict';

const express = require('express');
const router = express.Router();
const path = require('path');
const fs = require('fs').promises;

// Import SLA components
const slaMonitorPath = path.join(__dirname, '../../../lib/orchestration/sla-monitor');
const slaNotifierPath = path.join(__dirname, '../../../lib/orchestration/sla-notifier');

let slaMonitor;
let slaNotifier;

// Lazy load to avoid initialization issues
function loadComponents() {
  if (!slaMonitor) {
    try {
      const { getSLAMonitor } = require(slaMonitorPath);
      slaMonitor = getSLAMonitor();
    } catch (error) {
      console.warn('Could not load SLA monitor:', error.message);
    }
  }

  if (!slaNotifier) {
    try {
      const { getSLANotifier } = require(slaNotifierPath);
      slaNotifier = getSLANotifier();
    } catch (error) {
      console.warn('Could not load SLA notifier:', error.message);
    }
  }
}

// Paths
const COORD_DIR = process.env.COMMIT_RELAY_HOME
  ? path.join(process.env.COMMIT_RELAY_HOME, 'coordination')
  : path.join(__dirname, '../../../coordination');

const SLA_POLICY_PATH = path.join(COORD_DIR, 'config/sla-policy.json');
const SLA_EVENTS_PATH = path.join(COORD_DIR, 'metrics/sla-events.jsonl');
const SLA_BREACHES_PATH = path.join(COORD_DIR, 'metrics/sla-breaches.jsonl');

/**
 * GET /api/v1/sla/status
 * Get status of all active SLA timers
 */
router.get('/status', (req, res) => {
  loadComponents();

  try {
    if (!slaMonitor) {
      return res.status(503).json({
        error: 'SLA monitor not available',
        timestamp: new Date().toISOString()
      });
    }

    const activeTimers = slaMonitor.getActiveTimers();
    const metrics = slaMonitor.getMetrics();

    // Categorize timers by urgency
    const urgent = activeTimers.filter(t => t.critical_sent);
    const warning = activeTimers.filter(t => t.warning_sent && !t.critical_sent);
    const healthy = activeTimers.filter(t => !t.warning_sent && !t.critical_sent);

    res.json({
      status: urgent.length > 0 ? 'critical' : warning.length > 0 ? 'warning' : 'healthy',
      summary: {
        total_active: activeTimers.length,
        urgent: urgent.length,
        warning: warning.length,
        healthy: healthy.length
      },
      timers: activeTimers,
      metrics: {
        total_monitored: metrics.total_monitored,
        warnings_issued: metrics.warnings_issued,
        critical_alerts: metrics.critical_alerts,
        breaches: metrics.breaches,
        tasks_completed_in_sla: metrics.tasks_completed_in_sla,
        sla_compliance_rate: metrics.sla_compliance_rate,
        breach_rate: metrics.breach_rate
      },
      timestamp: new Date().toISOString()
    });
  } catch (error) {
    res.status(500).json({
      error: error.message,
      timestamp: new Date().toISOString()
    });
  }
});

/**
 * GET /api/v1/sla/breaches
 * Get recent SLA breaches
 */
router.get('/breaches', async (req, res) => {
  loadComponents();

  try {
    const limit = parseInt(req.query.limit) || 20;
    const taskType = req.query.task_type;
    const since = req.query.since; // ISO timestamp

    let breaches = [];

    // Read from file
    try {
      const content = await fs.readFile(SLA_BREACHES_PATH, 'utf-8');
      const lines = content.trim().split('\n').filter(line => line);

      breaches = lines.map(line => {
        try {
          return JSON.parse(line);
        } catch {
          return null;
        }
      }).filter(breach => breach !== null);
    } catch (error) {
      if (error.code !== 'ENOENT') {
        throw error;
      }
      // File doesn't exist yet
    }

    // Apply filters
    if (taskType) {
      breaches = breaches.filter(b => b.task_type === taskType);
    }

    if (since) {
      const sinceDate = new Date(since);
      breaches = breaches.filter(b => new Date(b.timestamp) >= sinceDate);
    }

    // Get latest breaches
    breaches = breaches.slice(-limit).reverse();

    // Calculate breach statistics
    const now = Date.now();
    const last24h = breaches.filter(b =>
      (now - new Date(b.timestamp).getTime()) < 24 * 60 * 60 * 1000
    ).length;
    const last7d = breaches.filter(b =>
      (now - new Date(b.timestamp).getTime()) < 7 * 24 * 60 * 60 * 1000
    ).length;

    // Group by task type
    const byTaskType = {};
    for (const breach of breaches) {
      const type = breach.task_type || 'unknown';
      byTaskType[type] = (byTaskType[type] || 0) + 1;
    }

    res.json({
      breaches,
      summary: {
        total: breaches.length,
        last_24h: last24h,
        last_7d: last7d,
        by_task_type: byTaskType
      },
      timestamp: new Date().toISOString()
    });
  } catch (error) {
    res.status(500).json({
      error: error.message,
      timestamp: new Date().toISOString()
    });
  }
});

/**
 * GET /api/v1/sla/events
 * Get recent SLA events (warnings, criticals, breaches)
 */
router.get('/events', async (req, res) => {
  loadComponents();

  try {
    const limit = parseInt(req.query.limit) || 50;
    const eventType = req.query.event_type; // sla_warning, sla_critical, sla_breach
    const taskId = req.query.task_id;

    let events = [];

    // Read from file
    try {
      const content = await fs.readFile(SLA_EVENTS_PATH, 'utf-8');
      const lines = content.trim().split('\n').filter(line => line);

      events = lines.map(line => {
        try {
          return JSON.parse(line);
        } catch {
          return null;
        }
      }).filter(event => event !== null);
    } catch (error) {
      if (error.code !== 'ENOENT') {
        throw error;
      }
    }

    // Apply filters
    if (eventType) {
      events = events.filter(e => e.event_type === eventType);
    }

    if (taskId) {
      events = events.filter(e => e.task_id === taskId);
    }

    // Get latest events
    events = events.slice(-limit).reverse();

    // Group by event type
    const byEventType = {
      sla_warning: events.filter(e => e.event_type === 'sla_warning').length,
      sla_critical: events.filter(e => e.event_type === 'sla_critical').length,
      sla_breach: events.filter(e => e.event_type === 'sla_breach').length
    };

    res.json({
      events,
      summary: {
        total: events.length,
        by_event_type: byEventType
      },
      timestamp: new Date().toISOString()
    });
  } catch (error) {
    res.status(500).json({
      error: error.message,
      timestamp: new Date().toISOString()
    });
  }
});

/**
 * GET /api/v1/sla/config
 * Get current SLA configuration
 */
router.get('/config', async (req, res) => {
  try {
    let policy = {};

    try {
      const content = await fs.readFile(SLA_POLICY_PATH, 'utf-8');
      policy = JSON.parse(content);
    } catch (error) {
      if (error.code !== 'ENOENT') {
        throw error;
      }
      // File doesn't exist - return empty config
      return res.status(404).json({
        error: 'SLA policy not configured',
        timestamp: new Date().toISOString()
      });
    }

    res.json({
      policy: {
        version: policy.version,
        enabled: policy.enabled,
        global_settings: policy.global_settings,
        task_type_timeouts: policy.task_type_timeouts,
        priority_modifiers: policy.priority_modifiers,
        escalation_channels: policy.escalation_channels
      },
      timestamp: new Date().toISOString()
    });
  } catch (error) {
    res.status(500).json({
      error: error.message,
      timestamp: new Date().toISOString()
    });
  }
});

/**
 * GET /api/v1/sla/timers/:taskId
 * Get SLA timer status for a specific task
 */
router.get('/timers/:taskId', (req, res) => {
  loadComponents();

  const { taskId } = req.params;

  try {
    if (!slaMonitor) {
      return res.status(503).json({
        error: 'SLA monitor not available',
        timestamp: new Date().toISOString()
      });
    }

    const timerInfo = slaMonitor.getTimerInfo(taskId);

    if (!timerInfo) {
      return res.status(404).json({
        error: `No active SLA timer for task '${taskId}'`,
        timestamp: new Date().toISOString()
      });
    }

    const now = Date.now();
    const elapsed = now - timerInfo.start_time;
    const remaining = timerInfo.timeout_ms - elapsed;
    const percentage = Math.round((elapsed / timerInfo.timeout_ms) * 100);

    res.json({
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
      start_time: new Date(timerInfo.start_time).toISOString(),
      expected_completion: new Date(timerInfo.start_time + timerInfo.timeout_ms).toISOString(),
      timestamp: new Date().toISOString()
    });
  } catch (error) {
    res.status(500).json({
      error: error.message,
      timestamp: new Date().toISOString()
    });
  }
});

/**
 * POST /api/v1/sla/timers/:taskId/extend
 * Extend timeout for a specific task
 */
router.post('/timers/:taskId/extend', (req, res) => {
  loadComponents();

  const { taskId } = req.params;
  const { additional_ms } = req.body;

  try {
    if (!slaMonitor) {
      return res.status(503).json({
        error: 'SLA monitor not available',
        timestamp: new Date().toISOString()
      });
    }

    if (!additional_ms || typeof additional_ms !== 'number' || additional_ms <= 0) {
      return res.status(400).json({
        error: 'additional_ms must be a positive number',
        timestamp: new Date().toISOString()
      });
    }

    const success = slaMonitor.extendTimeout(taskId, additional_ms);

    if (!success) {
      return res.status(404).json({
        error: `Cannot extend timeout - no active SLA timer for task '${taskId}'`,
        timestamp: new Date().toISOString()
      });
    }

    const timerInfo = slaMonitor.getTimerInfo(taskId);
    const now = Date.now();
    const elapsed = now - timerInfo.start_time;
    const remaining = timerInfo.timeout_ms - elapsed;

    res.json({
      success: true,
      task_id: taskId,
      extended_by_ms: additional_ms,
      new_timeout_ms: timerInfo.timeout_ms,
      remaining_ms: remaining,
      message: `Timeout extended by ${additional_ms}ms`,
      timestamp: new Date().toISOString()
    });
  } catch (error) {
    res.status(500).json({
      error: error.message,
      timestamp: new Date().toISOString()
    });
  }
});

/**
 * DELETE /api/v1/sla/timers/:taskId
 * Clear SLA timer for a specific task
 */
router.delete('/timers/:taskId', (req, res) => {
  loadComponents();

  const { taskId } = req.params;

  try {
    if (!slaMonitor) {
      return res.status(503).json({
        error: 'SLA monitor not available',
        timestamp: new Date().toISOString()
      });
    }

    const success = slaMonitor.clearTimer(taskId);

    if (!success) {
      return res.status(404).json({
        error: `No active SLA timer for task '${taskId}'`,
        timestamp: new Date().toISOString()
      });
    }

    res.json({
      success: true,
      task_id: taskId,
      message: `SLA timer cleared for task '${taskId}'`,
      timestamp: new Date().toISOString()
    });
  } catch (error) {
    res.status(500).json({
      error: error.message,
      timestamp: new Date().toISOString()
    });
  }
});

/**
 * GET /api/v1/sla/metrics
 * Get SLA monitoring metrics
 */
router.get('/metrics', (req, res) => {
  loadComponents();

  try {
    if (!slaMonitor) {
      return res.status(503).json({
        error: 'SLA monitor not available',
        timestamp: new Date().toISOString()
      });
    }

    const metrics = slaMonitor.getMetrics();

    res.json({
      metrics,
      timestamp: new Date().toISOString()
    });
  } catch (error) {
    res.status(500).json({
      error: error.message,
      timestamp: new Date().toISOString()
    });
  }
});

/**
 * POST /api/v1/sla/reload
 * Reload SLA policy configuration
 */
router.post('/reload', (req, res) => {
  loadComponents();

  try {
    if (!slaMonitor) {
      return res.status(503).json({
        error: 'SLA monitor not available',
        timestamp: new Date().toISOString()
      });
    }

    slaMonitor.reloadPolicy();

    if (slaNotifier) {
      slaNotifier.reloadPolicy();
    }

    res.json({
      success: true,
      message: 'SLA policy reloaded',
      timestamp: new Date().toISOString()
    });
  } catch (error) {
    res.status(500).json({
      error: error.message,
      timestamp: new Date().toISOString()
    });
  }
});

module.exports = router;
