/**
 * Queue Management API Routes
 *
 * Provides REST endpoints for queue management and monitoring:
 * - GET /api/v1/queue/status - Queue depth, active tasks
 * - GET /api/v1/queue/metrics - Throughput, wait times
 * - POST /api/v1/queue/pause - Pause processing
 * - POST /api/v1/queue/resume - Resume processing
 * - GET /api/v1/queue/rate-limiter/status - Rate limiter status
 * - GET /api/v1/queue/rate-limiter/metrics - Rate limiter metrics
 */

const express = require('express');
const router = express.Router();
const path = require('path');
const fs = require('fs').promises;

// Import orchestration components
const {
  QueueManager,
  RateLimiter,
  createQueueManager,
  createRateLimiter,
  BackpressureError,
  RateLimitError
} = require('../../../lib/orchestration');

// Singleton instances
let queueManager = null;
let rateLimiter = null;

/**
 * Initialize queue manager and rate limiter
 */
function getQueueManager() {
  if (!queueManager) {
    queueManager = createQueueManager();
  }
  return queueManager;
}

function getRateLimiter() {
  if (!rateLimiter) {
    rateLimiter = createRateLimiter();
  }
  return rateLimiter;
}

// Paths
const COMMIT_RELAY_HOME = process.env.COMMIT_RELAY_HOME || path.join(__dirname, '../../..');
const QUEUE_METRICS_PATH = path.join(COMMIT_RELAY_HOME, 'coordination/metrics/queue-metrics.jsonl');
const RATE_LIMIT_METRICS_PATH = path.join(COMMIT_RELAY_HOME, 'coordination/metrics/rate-limit-metrics.jsonl');

/**
 * GET /api/v1/queue/status
 * Get current queue status
 */
router.get('/status', async (req, res) => {
  try {
    const qm = getQueueManager();
    const rl = getRateLimiter();

    const status = {
      queue: qm.getStatus(),
      rate_limiter: rl.getStatus(),
      timestamp: new Date().toISOString()
    };

    res.json({
      success: true,
      data: status
    });
  } catch (error) {
    console.error('Error getting queue status:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to get queue status',
      message: error.message
    });
  }
});

/**
 * GET /api/v1/queue/metrics
 * Get queue metrics (throughput, wait times, etc.)
 */
router.get('/metrics', async (req, res) => {
  try {
    const qm = getQueueManager();
    const rl = getRateLimiter();

    const metrics = {
      queue: qm.getMetrics(),
      rate_limiter: rl.getMetrics(),
      timestamp: new Date().toISOString()
    };

    res.json({
      success: true,
      data: metrics
    });
  } catch (error) {
    console.error('Error getting queue metrics:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to get queue metrics',
      message: error.message
    });
  }
});

/**
 * GET /api/v1/queue/metrics/history
 * Get historical queue metrics
 */
router.get('/metrics/history', async (req, res) => {
  try {
    const limit = parseInt(req.query.limit) || 100;
    const offset = parseInt(req.query.offset) || 0;

    let entries = [];

    try {
      const content = await fs.readFile(QUEUE_METRICS_PATH, 'utf-8');
      const lines = content.trim().split('\n').filter(line => line);
      entries = lines.slice(-limit - offset, lines.length - offset || undefined)
        .map(line => {
          try {
            return JSON.parse(line);
          } catch {
            return null;
          }
        })
        .filter(entry => entry !== null);
    } catch (error) {
      if (error.code !== 'ENOENT') {
        throw error;
      }
    }

    res.json({
      success: true,
      data: {
        entries,
        count: entries.length,
        total: entries.length
      }
    });
  } catch (error) {
    console.error('Error getting queue metrics history:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to get queue metrics history',
      message: error.message
    });
  }
});

/**
 * POST /api/v1/queue/pause
 * Pause queue processing
 */
router.post('/pause', async (req, res) => {
  try {
    const qm = getQueueManager();
    qm.pause();

    res.json({
      success: true,
      message: 'Queue processing paused',
      data: {
        paused: true,
        timestamp: new Date().toISOString()
      }
    });
  } catch (error) {
    console.error('Error pausing queue:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to pause queue',
      message: error.message
    });
  }
});

/**
 * POST /api/v1/queue/resume
 * Resume queue processing
 */
router.post('/resume', async (req, res) => {
  try {
    const qm = getQueueManager();
    qm.resume();

    res.json({
      success: true,
      message: 'Queue processing resumed',
      data: {
        paused: false,
        timestamp: new Date().toISOString()
      }
    });
  } catch (error) {
    console.error('Error resuming queue:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to resume queue',
      message: error.message
    });
  }
});

/**
 * POST /api/v1/queue/enqueue
 * Enqueue a task (for testing/manual submission)
 */
router.post('/enqueue', async (req, res) => {
  try {
    const qm = getQueueManager();
    const task = req.body;

    if (!task || !task.id) {
      return res.status(400).json({
        success: false,
        error: 'Invalid task',
        message: 'Task must have an id'
      });
    }

    const result = qm.enqueue(task);

    res.json({
      success: true,
      message: 'Task enqueued',
      data: result
    });
  } catch (error) {
    if (error instanceof BackpressureError) {
      return res.status(503).json({
        success: false,
        error: 'Queue full - backpressure active',
        code: 'BACKPRESSURE',
        message: error.message,
        details: error.details,
        retry_after_ms: error.details.retry_after_ms || 1000
      });
    }

    console.error('Error enqueuing task:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to enqueue task',
      message: error.message
    });
  }
});

/**
 * DELETE /api/v1/queue/task/:id
 * Remove a task from queue
 */
router.delete('/task/:id', async (req, res) => {
  try {
    const qm = getQueueManager();
    const taskId = req.params.id;

    const removed = qm.remove(taskId);

    if (removed) {
      res.json({
        success: true,
        message: 'Task removed from queue',
        data: { task_id: taskId }
      });
    } else {
      res.status(404).json({
        success: false,
        error: 'Task not found',
        message: `Task ${taskId} not found in queue`
      });
    }
  } catch (error) {
    console.error('Error removing task:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to remove task',
      message: error.message
    });
  }
});

/**
 * GET /api/v1/queue/task/:id
 * Get task status
 */
router.get('/task/:id', async (req, res) => {
  try {
    const qm = getQueueManager();
    const taskId = req.params.id;

    const taskInfo = qm.getTask(taskId);

    if (taskInfo) {
      res.json({
        success: true,
        data: taskInfo
      });
    } else {
      res.status(404).json({
        success: false,
        error: 'Task not found',
        message: `Task ${taskId} not found in queue`
      });
    }
  } catch (error) {
    console.error('Error getting task:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to get task',
      message: error.message
    });
  }
});

/**
 * POST /api/v1/queue/clear
 * Clear all tasks from queue
 */
router.post('/clear', async (req, res) => {
  try {
    const qm = getQueueManager();
    const cleared = qm.clear();

    res.json({
      success: true,
      message: 'Queue cleared',
      data: {
        cleared_count: cleared,
        timestamp: new Date().toISOString()
      }
    });
  } catch (error) {
    console.error('Error clearing queue:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to clear queue',
      message: error.message
    });
  }
});

/**
 * GET /api/v1/queue/rate-limiter/status
 * Get rate limiter status
 */
router.get('/rate-limiter/status', async (req, res) => {
  try {
    const rl = getRateLimiter();

    res.json({
      success: true,
      data: rl.getStatus()
    });
  } catch (error) {
    console.error('Error getting rate limiter status:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to get rate limiter status',
      message: error.message
    });
  }
});

/**
 * GET /api/v1/queue/rate-limiter/metrics
 * Get rate limiter metrics
 */
router.get('/rate-limiter/metrics', async (req, res) => {
  try {
    const rl = getRateLimiter();

    res.json({
      success: true,
      data: rl.getMetrics()
    });
  } catch (error) {
    console.error('Error getting rate limiter metrics:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to get rate limiter metrics',
      message: error.message
    });
  }
});

/**
 * GET /api/v1/queue/rate-limiter/metrics/history
 * Get historical rate limiter metrics
 */
router.get('/rate-limiter/metrics/history', async (req, res) => {
  try {
    const limit = parseInt(req.query.limit) || 100;
    const offset = parseInt(req.query.offset) || 0;

    let entries = [];

    try {
      const content = await fs.readFile(RATE_LIMIT_METRICS_PATH, 'utf-8');
      const lines = content.trim().split('\n').filter(line => line);
      entries = lines.slice(-limit - offset, lines.length - offset || undefined)
        .map(line => {
          try {
            return JSON.parse(line);
          } catch {
            return null;
          }
        })
        .filter(entry => entry !== null);
    } catch (error) {
      if (error.code !== 'ENOENT') {
        throw error;
      }
    }

    res.json({
      success: true,
      data: {
        entries,
        count: entries.length
      }
    });
  } catch (error) {
    console.error('Error getting rate limiter metrics history:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to get rate limiter metrics history',
      message: error.message
    });
  }
});

/**
 * POST /api/v1/queue/rate-limiter/check
 * Check if request would be rate limited
 */
router.post('/rate-limiter/check', async (req, res) => {
  try {
    const rl = getRateLimiter();
    const { master } = req.body;

    if (!master) {
      return res.status(400).json({
        success: false,
        error: 'Invalid request',
        message: 'Master identifier is required'
      });
    }

    const result = rl.checkLimit(master);

    res.json({
      success: true,
      data: result
    });
  } catch (error) {
    console.error('Error checking rate limit:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to check rate limit',
      message: error.message
    });
  }
});

/**
 * POST /api/v1/queue/rate-limiter/reset
 * Reset rate limiter state
 */
router.post('/rate-limiter/reset', async (req, res) => {
  try {
    const rl = getRateLimiter();
    rl.reset();

    res.json({
      success: true,
      message: 'Rate limiter reset',
      data: {
        timestamp: new Date().toISOString()
      }
    });
  } catch (error) {
    console.error('Error resetting rate limiter:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to reset rate limiter',
      message: error.message
    });
  }
});

/**
 * GET /api/v1/queue/config
 * Get queue and rate limiter configuration
 */
router.get('/config', async (req, res) => {
  try {
    const configPath = path.join(COMMIT_RELAY_HOME, 'coordination/config/queue-policy.json');

    try {
      const content = await fs.readFile(configPath, 'utf-8');
      const config = JSON.parse(content);

      res.json({
        success: true,
        data: config
      });
    } catch (error) {
      if (error.code === 'ENOENT') {
        return res.status(404).json({
          success: false,
          error: 'Config not found',
          message: 'Queue policy configuration file not found'
        });
      }
      throw error;
    }
  } catch (error) {
    console.error('Error getting queue config:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to get queue config',
      message: error.message
    });
  }
});

// Export singleton accessors for use by other modules
module.exports = router;
module.exports.getQueueManager = getQueueManager;
module.exports.getRateLimiter = getRateLimiter;
