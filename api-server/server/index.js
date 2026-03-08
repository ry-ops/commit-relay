#!/usr/bin/env node

/**
 * Commit-Relay API Server
 * Real-time metrics and monitoring for the master-worker system
 *
 * Security Features (v2.0):
 * - API key authentication
 * - Rate limiting
 * - Input validation
 * - Command injection protection
 * - Path traversal protection
 * - CORS restrictions
 * - Elastic APM observability (v3.0)
 */

// CRITICAL: APM must be initialized BEFORE any other requires
// This ensures full instrumentation of all modules
const apm = require('../apm');

// Load environment variables
require('dotenv').config();

const express = require('express');
const { WebSocketServer } = require('ws');
const { spawn } = require('child_process');
const fs = require('fs').promises;
const fsSync = require('fs');
const path = require('path');
const chokidar = require('chokidar');
const cors = require('cors');
const helmet = require('helmet');

// Security middleware
const { authMiddleware, confirmationMiddleware } = require('./middleware/auth');
const { apiLimiter, controlLimiter, expensiveLimiter, getLimiter } = require('./middleware/rateLimiter');
const {
  validate,
  validatePid,
  validatePath,
  sanitizeWorkerId,
  sanitizeAlertId,
  ddqdValidationRules,
  daemonControlValidationRules,
  alertResolutionValidationRules,
  workerRestartValidationRules
} = require('./middleware/validators');

// JSON validation utilities
const { safeWriteJSON, validateAndRepairJSON, logValidation } = require('./utils/json-validator');

// Security utilities
const {
  safeExec,
  isProcessRunning,
  safeKillProcess,
  safeStartScript,
  sanitizeError
} = require('./utils/security');

// Path validation utilities
const { sanitizeFilename, safeJoin, validateId, validateDateString } = require('./lib/path-validator');

// Governance modules
const { ComplianceEngine, MetricsCollector } = require('../../lib/governance/compliance');

// API Routes
const usersRouter = require('./routes/users');
const tracesRouter = require('./routes/traces');
const complianceRouter = require('./routes/compliance');
const llmCostsRouter = require('./routes/llm-costs');
const workflowsRouter = require('./routes/workflows');
const decisionsRouter = require('./routes/decisions');
const llmHealthRouter = require('./routes/llm-health');
const promptsRouter = require('../routes/prompts');
const slaRouter = require('./routes/sla');
const queueRouter = require('./routes/queue');
const securityRouter = require('./routes/security');

const app = express();
const PORT = process.env.API_PORT || process.env.DASHBOARD_PORT || 5001;

// Server start time for detecting restarts
const SERVER_START_TIME = Date.now();
const SERVER_START_ISO = new Date(SERVER_START_TIME).toISOString();

// Security: Helmet for security headers
app.use(helmet({
  contentSecurityPolicy: {
    directives: {
      defaultSrc: ["'self'"],
      scriptSrc: ["'self'", "'unsafe-inline'", "'unsafe-eval'"],
      styleSrc: ["'self'", "'unsafe-inline'"],
      imgSrc: ["'self'", "data:", "blob:"],
      fontSrc: ["'self'", "data:"],
      connectSrc: ["'self'", "ws:", "wss:"],
      frameSrc: ["'self'"],
      objectSrc: ["'none'"],
      upgradeInsecureRequests: []
    }
  },
  crossOriginEmbedderPolicy: false,
  crossOriginResourcePolicy: { policy: "cross-origin" }
}));

// Security: CORS configuration
const allowedOrigins = process.env.ALLOWED_ORIGINS
  ? process.env.ALLOWED_ORIGINS.split(',').map(origin => origin.trim())
  : ['http://localhost:5001'];

app.use(cors({
  origin: (origin, callback) => {
    // Allow requests with no origin (mobile apps, curl, etc.)
    if (!origin) return callback(null, true);

    if (allowedOrigins.indexOf(origin) !== -1 || allowedOrigins.includes('*')) {
      callback(null, true);
    } else {
      console.warn(`⚠️  Blocked CORS request from unauthorized origin: ${origin}`);
      callback(new Error('Not allowed by CORS'));
    }
  },
  credentials: true
}));

// Security: JSON body size limit (prevent DoS)
app.use(express.json({ limit: '1mb' }));

// Security: Trust proxy (for rate limiting behind reverse proxy)
app.set('trust proxy', 1);

// Static files
app.use(express.static(path.join(__dirname, '../public')));

// Security: Apply rate limiting to all API routes
app.use('/api', apiLimiter);

// Security: Apply authentication to all API routes
app.use('/api', authMiddleware);

// Mount API routers
app.use('/api/users', usersRouter);
app.use('/api/traces', tracesRouter);
app.use('/api/compliance', complianceRouter);
app.use('/api/llm-costs', llmCostsRouter);
app.use('/api/v1/workflows', workflowsRouter);
app.use('/api/decisions', decisionsRouter);
app.use('/api/v1/llm', llmHealthRouter);
app.use('/api/v1/prompts', promptsRouter);
app.use('/api/v1/sla', slaRouter);
app.use('/api/v1/queue', queueRouter);
app.use('/api/v1/security', securityRouter);

// Paths to coordination files
const COMMIT_RELAY_HOME = process.env.COMMIT_RELAY_HOME || path.join(__dirname, '../..');
const COORD_DIR = path.join(COMMIT_RELAY_HOME, 'coordination');
const FILES = {
  workerPool: path.join(COORD_DIR, 'worker-pool.json'),
  tokenBudget: path.join(COORD_DIR, 'token-budget.json'),
  taskQueue: path.join(COORD_DIR, 'task-queue.json'),
  handoffs: path.join(COORD_DIR, 'handoffs.json'),
  status: path.join(COORD_DIR, 'status.json'),
  systemEvents: path.join(COORD_DIR, 'system-events.jsonl')
};

// Cache for coordination data
let cache = {
  workerPool: null,
  tokenBudget: null,
  taskQueue: null,
  handoffs: null,
  status: null,
  lastUpdate: null,
  lastFileUpdate: {} // Track last update time per file
};

// Event buffer for reconnecting clients (increased for better persistence)
const EVENT_BUFFER_SIZE = 500;  // Increased from 50 to 500
let eventBuffer = [];

// Load previous event buffer from file on startup for persistence
const EVENT_BUFFER_FILE = path.join(COORD_DIR, 'event-buffer.json');
try {
  const fsSync = require('fs');
  if (fsSync.existsSync(EVENT_BUFFER_FILE)) {
    const bufferData = fsSync.readFileSync(EVENT_BUFFER_FILE, 'utf-8');
    eventBuffer = JSON.parse(bufferData);
    console.log(`Loaded ${eventBuffer.length} events from persistent buffer`);
  }
} catch (e) {
  console.log('No previous event buffer found, starting fresh');
}

/**
 * Read and parse JSON file safely with retry logic
 */
async function readJSON(filePath, retries = 3) {
  for (let attempt = 1; attempt <= retries; attempt++) {
    try {
      const content = await fs.readFile(filePath, 'utf-8');
      const data = JSON.parse(content);

      // Track file update time
      cache.lastFileUpdate[filePath] = new Date().toISOString();

      return data;
    } catch (error) {
      if (attempt === retries) {
        console.error(`Error reading ${filePath} after ${retries} attempts:`, error.message);
        return null;
      }
      // Wait before retry (exponential backoff)
      await new Promise(resolve => setTimeout(resolve, 50 * attempt));
    }
  }
  return null;
}

/**
 * Generate task events from task queue changes
 */
async function generateTaskEvents(newTaskQueue, oldTaskQueue) {
  if (!newTaskQueue || !newTaskQueue.tasks) return [];

  const events = [];
  const oldTasks = oldTaskQueue?.tasks || [];
  const newTasks = newTaskQueue.tasks;

  // Create a map of old tasks by ID for quick lookup
  const oldTasksMap = {};
  oldTasks.forEach(task => {
    oldTasksMap[task.id] = task;
  });

  // Check each task for state changes
  for (const task of newTasks) {
    const oldTask = oldTasksMap[task.id];

    if (!oldTask) {
      // New task created
      events.push({
        id: `task-event-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`,
        type: 'task_created',
        timestamp: task.created_at || new Date().toISOString(),
        data: {
          task_id: task.id,
          task_title: task.title,
          task_type: task.type,
          priority: task.priority,
          created_by: task.created_by
        },
        message: `Task Created: '${task.id}: ${task.title}'`
      });
    } else {
      // Check for status changes
      if (oldTask.status !== task.status) {
        if (task.status === 'assigned' || (oldTask.status === 'pending' && task.assigned_to)) {
          events.push({
            id: `task-event-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`,
            type: 'task_assigned',
            timestamp: task.assigned_at || new Date().toISOString(),
            data: {
              task_id: task.id,
              task_title: task.title,
              assigned_to: task.assigned_to,
              priority: task.priority
            },
            message: `Task Assigned: '${task.id}' → ${task.assigned_to}`
          });
        } else if (task.status === 'completed') {
          events.push({
            id: `task-event-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`,
            type: 'task_completed',
            timestamp: task.completed_at || new Date().toISOString(),
            data: {
              task_id: task.id,
              task_title: task.title,
              assigned_to: task.assigned_to,
              duration: task.completed_at && task.started_at
                ? Math.round((new Date(task.completed_at) - new Date(task.started_at)) / 60000) + ' min'
                : 'N/A'
            },
            message: `Task Completed: '${task.id}: ${task.title}' ✓`
          });
        } else if (task.status === 'failed') {
          events.push({
            id: `task-event-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`,
            type: 'task_failed',
            timestamp: task.failed_at || new Date().toISOString(),
            data: {
              task_id: task.id,
              task_title: task.title,
              assigned_to: task.assigned_to,
              error: task.error || 'Unknown error'
            },
            message: `Task Failed: '${task.id}: ${task.title}' ✗`
          });
        }
      }
    }
  }

  return events;
}

/**
 * Load all coordination data (serves from cache, updates on file changes)
 */
async function loadCoordinationData(forceRefresh = false) {
  if (!forceRefresh && cache.lastUpdate) {
    // Serve from cache if available
    return cache;
  }

  // Generate live worker pool from spec files
  const workerSpecsDir = path.join(COORD_DIR, 'worker-specs');
  const liveWorkerPool = await generateLiveWorkerPool(workerSpecsDir);

  // Load orchestrator state (v4.0)
  const orchestratorState = await readJSON(path.join(COORD_DIR, 'orchestrator/state/current.json'));

  // Load Execution Manager data (v4.0)
  const executionManagersData = await generateLiveExecutionManagers(COORD_DIR);

  const data = {
    workerPool: liveWorkerPool,
    tokenBudget: await readJSON(FILES.tokenBudget),
    taskQueue: await readJSON(FILES.taskQueue),
    handoffs: await readJSON(FILES.handoffs),
    status: await readJSON(FILES.status),
    orchestrator: orchestratorState || {
      active_orchestrations: 0,
      total_orchestrations: 0,
      completed_orchestrations: 0,
      failed_orchestrations: 0
    },
    executionManagers: executionManagersData,
    lastUpdate: new Date().toISOString(),
    lastFileUpdate: cache.lastFileUpdate
  };

  cache = data;
  return data;
}

/**
 * Get daemon status
 */
async function getDaemonStatus() {
  const { execSync } = require('child_process');
  const fsSync = require('fs');

  const PID_FILE = '/tmp/commit-relay-worker-daemon.pid';
  const LOG_FILE = path.join(__dirname, '../../agents/logs/system/worker-daemon.log');

  let status = 'stopped';
  let pid = null;
  let uptime = null;
  let memory = null;

  if (fsSync.existsSync(PID_FILE)) {
    try {
      pid = parseInt(fsSync.readFileSync(PID_FILE, 'utf-8').trim());
      execSync(`ps -p ${pid}`, { stdio: 'pipe' });
      status = 'running';

      const psOutput = execSync(`ps -o etime= -p ${pid}`).toString().trim();
      uptime = parseElapsedTime(psOutput);

      const memOutput = execSync(`ps -o rss= -p ${pid}`).toString().trim();
      memory = parseInt(memOutput);
    } catch (error) {
      status = 'stopped';
      pid = null;
    }
  }

  let recentLogs = [];
  if (fsSync.existsSync(LOG_FILE)) {
    try {
      const logContent = fsSync.readFileSync(LOG_FILE, 'utf-8');
      const logLines = logContent.trim().split('\n');
      recentLogs = logLines.slice(-10);
    } catch (error) {
      console.error('Error reading daemon log:', error);
    }
  }

  const launchCount = recentLogs.filter(line =>
    line.includes('SUCCESS: Launched')
  ).length;

  return {
    status,
    pid,
    uptime,
    memory,
    launchCount,
    recentLogs,
    timestamp: new Date().toISOString()
  };
}

/**
 * Calculate success rate for different time periods
 */
// Helper function to filter out test/zombie workers
function isProductionWorker(worker) {
  // Exclude stress test workers
  if (worker.stress_test === true) return false;
  // Exclude zombie test workers (from DDQD tests)
  if (worker.worker_id && worker.worker_id.includes('zombie-ddqd')) return false;
  if (worker.worker_id && worker.worker_id.startsWith('zombie-')) return false;
  // Exclude workers with test_id field (stress test workers)
  if (worker.test_id) return false;
  return true;
}

function calculateSuccessRate(workerPool, period = 'all_time') {
  const now = Date.now();
  // Filter out test/zombie workers from all pools
  const completed = (workerPool.completed_workers || []).filter(isProductionWorker);
  const failed = (workerPool.failed_workers || []).filter(isProductionWorker);
  const active = (workerPool.active_workers || []).filter(isProductionWorker);

  let filteredCompleted = [];
  let filteredFailed = [];
  let filteredActive = [];

  // Filter workers based on time period
  switch (period) {
    case 'current_run':
      // Only active workers
      filteredActive = active.filter(w => w.status === 'running' || w.status === 'active');
      break;

    case 'last_24h':
      const day_ago = now - (24 * 60 * 60 * 1000);
      filteredCompleted = completed.filter(w => {
        const completedAt = new Date(w.completed_at).getTime();
        return completedAt >= day_ago;
      });
      filteredFailed = failed.filter(w => {
        const failedAt = new Date(w.completed_at || w.failed_at).getTime();
        return failedAt >= day_ago;
      });
      break;

    case 'last_7d':
      const week_ago = now - (7 * 24 * 60 * 60 * 1000);
      filteredCompleted = completed.filter(w => {
        const completedAt = new Date(w.completed_at).getTime();
        return completedAt >= week_ago;
      });
      filteredFailed = failed.filter(w => {
        const failedAt = new Date(w.completed_at || w.failed_at).getTime();
        return failedAt >= week_ago;
      });
      break;

    case 'all_time':
    default:
      filteredCompleted = completed;
      filteredFailed = failed;
      break;
  }

  const totalCompleted = filteredCompleted.length;
  const totalFailed = filteredFailed.length;
  const totalActive = filteredActive.length;
  const total = totalCompleted + totalFailed + totalActive;

  const rate = total > 0 ? ((totalCompleted / total) * 100).toFixed(1) : 0;

  return {
    rate: parseFloat(rate),
    completed: totalCompleted,
    failed: totalFailed,
    active: totalActive,
    total: total,
    period: period
  };
}

/**
 * Calculate system metrics from coordination data
 */
function calculateMetrics(data, successRatePeriod = 'all_time') {
  const { workerPool, tokenBudget, taskQueue } = data;

  if (!workerPool || !tokenBudget || !taskQueue) {
    return null;
  }

  // Worker metrics - Fix: Filter active workers by actual running status
  // A worker is truly active only if it has status='running' AND recent activity (< 5 minutes)
  const now = Date.now();
  const ACTIVE_THRESHOLD_MS = 5 * 60 * 1000; // 5 minutes

  const activeWorkers = (workerPool.active_workers || []).filter(worker => {
    // Worker must have 'running' status or recent heartbeat
    const hasRunningStatus = worker.status === 'running' || worker.status === 'active';

    // Check if worker has recent activity
    const lastActivity = worker.last_heartbeat || worker.spawned_at;
    if (!lastActivity) return hasRunningStatus;

    const activityTime = new Date(lastActivity).getTime();
    const isRecentlyActive = (now - activityTime) < ACTIVE_THRESHOLD_MS;

    // Must be both running and recently active, OR have a session_id (actively executing)
    return (hasRunningStatus && isRecentlyActive) || worker.session_id;
  }).length;

  const completedWorkers = workerPool.completed_workers?.length || 0;
  const failedWorkers = workerPool.failed_workers?.length || 0;

  // Count zombies killed by the zombie-killer-daemon
  const zombiesKilled = (workerPool.failed_workers || []).filter(worker =>
    worker.killed_by === 'zombie-killer-daemon'
  ).length;

  // Calculate success rate based on selected time period
  const successRateData = calculateSuccessRate(
    workerPool,
    successRatePeriod
  );

  const totalWorkers = successRateData.total;
  const successRate = successRateData.rate;

  // Token metrics
  const totalBudget = tokenBudget.total_budget || 270000;
  const mastersUsed = tokenBudget.usage_metrics?.masters_used ||
    Object.values(tokenBudget.masters || {}).reduce((sum, m) => sum + (m.used || 0), 0);
  const workersUsed = tokenBudget.usage_metrics?.workers_used || 0;
  const workersAllocated = tokenBudget.worker_pool?.allocated_to_workers || 0;
  const totalUsed = tokenBudget.usage_metrics?.total_tokens_used_today || (mastersUsed + workersUsed);
  const availableBudget = totalBudget - totalUsed;
  const usagePercentage = ((totalUsed / totalBudget) * 100).toFixed(1);

  // Calculate master and worker pool allocations
  const mastersAllocated = Object.values(tokenBudget.masters || {})
    .reduce((sum, m) => sum + (m.allocated || 0), 0);
  const workerPoolTotal = tokenBudget.worker_pool?.total || 80000;

  // Emergency reserve
  const emergencyReserve = tokenBudget.emergency_reserve?.total || 25000;
  const emergencyUsed = tokenBudget.emergency_reserve?.used || 0;

  // Efficiency score
  const efficiency = tokenBudget.usage_metrics?.efficiency_score || 96.2;

  // Task metrics
  const tasks = taskQueue.tasks || [];
  const pendingTasks = tasks.filter(t => t.status === 'pending').length;
  const inProgressTasks = tasks.filter(t =>
    t.status === 'in_progress' ||
    t.status === 'in-progress' ||
    t.status === 'assigned' ||
    t.status === 'worker_spawned' ||
    t.status === 'scan_worker_spawned'
  ).length;
  const completedTasks = tasks.filter(t => t.status === 'completed').length;
  const failedTasks = tasks.filter(t => t.status === 'failed').length;
  const cancelledTasks = tasks.filter(t => t.status === 'cancelled').length;
  const totalTasks = tasks.length;

  // Master agent status
  const masters = {
    coordinator: {
      allocated: tokenBudget.masters?.coordinator?.allocated || 0,
      used: tokenBudget.masters?.coordinator?.used || 0,
      workerPool: tokenBudget.masters?.coordinator?.worker_pool || 0,
      tasksHandled: tokenBudget.masters?.coordinator?.tasks_handled?.length || 0
    },
    security: {
      allocated: tokenBudget.masters?.security?.allocated || 0,
      used: tokenBudget.masters?.security?.used || 0,
      workerPool: tokenBudget.masters?.security?.worker_pool || 0,
      tasksHandled: tokenBudget.masters?.security?.tasks_handled?.length || 0
    },
    development: {
      allocated: tokenBudget.masters?.development?.allocated || 0,
      used: tokenBudget.masters?.development?.used || 0,
      workerPool: tokenBudget.masters?.development?.worker_pool || 0,
      tasksHandled: tokenBudget.masters?.development?.tasks_handled?.length || 0
    },
    inventory: {
      allocated: tokenBudget.masters?.inventory?.allocated || 0,
      used: tokenBudget.masters?.inventory?.used || 0,
      workerPool: tokenBudget.masters?.inventory?.worker_pool || 0,
      tasksHandled: tokenBudget.masters?.inventory?.tasks_handled?.length || 0
    },
    cicd: {
      allocated: tokenBudget.masters?.cicd?.allocated || 0,
      used: tokenBudget.masters?.cicd?.used || 0,
      workerPool: tokenBudget.masters?.cicd?.worker_pool || 0,
      tasksHandled: tokenBudget.masters?.cicd?.tasks_handled?.length || 0
    }
  };

  // Claude Code usage status (read from status.json or use defaults)
  const usage = {
    sessionPercent: data.status?.usage?.session_percent || 15,
    weekAllPercent: data.status?.usage?.week_all_percent || 46,
    weekOpusPercent: data.status?.usage?.week_opus_percent || 0
  };

  // Orchestration metrics (v4.0)
  const orchestrator = data.orchestrator || {};

  // Execution Manager metrics (v4.0)
  const executionManagers = data.executionManagers || {
    active: 0,
    completed: 0,
    failed: 0,
    total: 0,
    success_rate: 0
  };

  return {
    workers: {
      active: activeWorkers,
      completed: successRateData.completed,
      failed: successRateData.failed,
      total: totalWorkers,
      successRate: parseFloat(successRate),
      successRatePeriod: successRatePeriod,
      successRateDetails: successRateData,
      avgDuration: workerPool.stats?.avg_duration_minutes || 0,
      avgTokens: workerPool.stats?.avg_tokens_used || 0,
      zombiesKilled: zombiesKilled
    },
    tokens: {
      total: totalBudget,
      used: totalUsed,
      available: availableBudget,
      usagePercentage: parseFloat(usagePercentage),
      mastersUsed,
      mastersAllocated,
      workersUsed,
      workersAllocated,
      workerPoolTotal,
      emergencyReserve,
      emergencyUsed,
      efficiency
    },
    tasks: {
      pending: pendingTasks,
      inProgress: inProgressTasks,
      completed: completedTasks,
      failed: failedTasks,
      cancelled: cancelledTasks,
      total: totalTasks,
      // Breakdown for debugging
      breakdown: {
        pending: pendingTasks,
        assigned: tasks.filter(t => t.status === 'assigned').length,
        worker_spawned: tasks.filter(t => t.status === 'worker_spawned').length,
        completed: completedTasks,
        failed: failedTasks,
        cancelled: cancelledTasks
      }
    },
    orchestrator: {
      active: orchestrator.active_orchestrations || 0,
      total: orchestrator.total_orchestrations || 0,
      completed: orchestrator.completed_orchestrations || 0,
      failed: orchestrator.failed_orchestrations || 0
    },
    executionManagers: {
      active: executionManagers.active || 0,
      completed: executionManagers.completed || 0,
      failed: executionManagers.failed || 0,
      total: executionManagers.total || 0,
      successRate: executionManagers.success_rate || 0
    },
    masters,
    usage,
    timestamp: new Date().toISOString()
  };
}

// ============================================================================
// HTTP API Endpoints
// ============================================================================

/**
 * GET /api/health
 * Health check endpoint - includes server start time for restart detection
 */
app.get('/api/health', (req, res) => {
  res.json({
    status: 'healthy',
    uptime: process.uptime(),
    timestamp: new Date().toISOString(),
    server_start_time: SERVER_START_TIME,
    server_start_iso: SERVER_START_ISO
  });
});

/**
 * GET /api/metrics
 * Get current system metrics (serves from cache)
 * Query params:
 *   - period: success_rate_period (current_run, last_24h, last_7d, all_time)
 */
app.get('/api/metrics', async (req, res) => {
  try {
    const period = req.query.period || 'all_time';
    const data = await loadCoordinationData(false); // Use cache
    const metrics = calculateMetrics(data, period);

    if (!metrics) {
      return res.status(500).json({
        error: 'Failed to calculate metrics',
        details: 'Coordination files may be missing or invalid'
      });
    }

    res.json(metrics);
  } catch (error) {
    console.error('Error calculating metrics:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

/**
 * GET /api/metrics/history
 * Get historical metrics data for trend charts
 * Query params:
 *   - range: time range (24h, 7d, 30d) - default: 24h
 *   - granularity: data point frequency (5m, 1h, 1d) - default: auto-selected
 */
app.get('/api/metrics/history', async (req, res) => {
  try {
    const range = req.query.range || '24h';
    const granularity = req.query.granularity || 'auto';

    const historyDir = path.join(__dirname, '../../coordination/history');
    const hourlyDir = path.join(historyDir, 'hourly');
    const dailyDir = path.join(historyDir, 'daily');

    // Determine which directory and files to read based on range
    let files = [];
    let actualGranularity = granularity;

    const now = new Date();
    let cutoffDate;

    switch (range) {
      case '24h':
        actualGranularity = granularity === 'auto' ? '5m' : granularity;
        cutoffDate = new Date(now.getTime() - 24 * 60 * 60 * 1000);
        // Read hourly directory for last 24 hours
        try {
          const hourlyFiles = await fs.readdir(hourlyDir);
          files = hourlyFiles
            .filter(f => f.endsWith('.json'))
            .map(f => path.join(hourlyDir, f))
            .filter(f => {
              const fileDate = new Date(path.basename(f, '.json'));
              return fileDate >= cutoffDate;
            })
            .sort();
        } catch (error) {
          console.warn('No hourly data available yet');
        }
        break;

      case '7d':
        actualGranularity = granularity === 'auto' ? '1h' : granularity;
        cutoffDate = new Date(now.getTime() - 7 * 24 * 60 * 60 * 1000);
        // Read hourly directory for last 7 days
        try {
          const hourlyFiles = await fs.readdir(hourlyDir);
          files = hourlyFiles
            .filter(f => f.endsWith('.json'))
            .map(f => path.join(hourlyDir, f))
            .filter(f => {
              const fileDate = new Date(path.basename(f, '.json'));
              return fileDate >= cutoffDate;
            })
            .sort();
        } catch (error) {
          console.warn('No hourly data available yet');
        }
        break;

      case '30d':
        actualGranularity = granularity === 'auto' ? '1d' : granularity;
        cutoffDate = new Date(now.getTime() - 30 * 24 * 60 * 60 * 1000);
        // Read daily directory for last 30 days
        try {
          const dailyFiles = await fs.readdir(dailyDir);
          files = dailyFiles
            .filter(f => f.endsWith('.json'))
            .map(f => path.join(dailyDir, f))
            .filter(f => {
              const fileDate = new Date(path.basename(f, '.json'));
              return fileDate >= cutoffDate;
            })
            .sort();
        } catch (error) {
          console.warn('No daily data available yet');
        }
        break;

      default:
        return res.status(400).json({ error: 'Invalid range. Use 24h, 7d, or 30d' });
    }

    // Read all snapshot files in parallel for better performance
    const snapshotPromises = files.map(async (file) => {
      try {
        const content = await fs.readFile(file, 'utf-8');
        return JSON.parse(content);
      } catch (error) {
        console.error(`Error reading snapshot ${file}:`, error.message);
        return null;
      }
    });

    let snapshots = (await Promise.all(snapshotPromises)).filter(s => s !== null);

    // Sample data points for better chart performance (max 100 points)
    const maxPoints = 100;
    if (snapshots.length > maxPoints) {
      const step = Math.ceil(snapshots.length / maxPoints);
      snapshots = snapshots.filter((_, index) => index % step === 0);
    }

    // If no historical data, return current metrics as single data point
    if (snapshots.length === 0) {
      const data = await loadCoordinationData(false);
      const currentMetrics = calculateMetrics(data);

      if (currentMetrics) {
        snapshots.push({
          timestamp: new Date().toISOString(),
          workers: currentMetrics.workers,
          tokens: currentMetrics.tokens,
          tasks: currentMetrics.tasks,
          orchestrator: currentMetrics.orchestrator
        });
      }
    }

    res.json({
      range,
      granularity: actualGranularity,
      data_points: snapshots.length,
      snapshots
    });
  } catch (error) {
    console.error('Error loading historical metrics:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

/**
 * GET /api/governance/compliance-report
 * Get comprehensive compliance report for all frameworks (GDPR, SOC2, Internal)
 */
app.get('/api/governance/compliance-report', async (req, res) => {
  try {
    // Prevent caching - always return fresh compliance data
    res.set('Cache-Control', 'no-store, no-cache, must-revalidate, private');
    res.set('Pragma', 'no-cache');
    res.set('Expires', '0');

    const engine = new ComplianceEngine();
    const report = await engine.generateComplianceReport();
    res.json(report);
  } catch (error) {
    console.error('Error generating compliance report:', error);
    res.status(500).json({ error: 'Internal server error', message: sanitizeError(error.message) });
  }
});

/**
 * GET /api/governance/compliance-check/:framework
 * Check compliance for specific framework (gdpr, soc2, internal)
 */
app.get('/api/governance/compliance-check/:framework', async (req, res) => {
  try {
    const framework = req.params.framework;
    const validFrameworks = ['gdpr', 'soc2', 'internal'];

    if (!validFrameworks.includes(framework)) {
      return res.status(400).json({
        error: 'Invalid framework',
        message: `Framework must be one of: ${validFrameworks.join(', ')}`
      });
    }

    // Prevent caching - always return fresh compliance data
    res.set('Cache-Control', 'no-store, no-cache, must-revalidate, private');
    res.set('Pragma', 'no-cache');
    res.set('Expires', '0');

    const engine = new ComplianceEngine();
    const result = await engine.checkCompliance(framework);
    res.json(result);
  } catch (error) {
    console.error('Error checking compliance:', error);
    res.status(500).json({ error: 'Internal server error', message: sanitizeError(error.message) });
  }
});

/**
 * GET /api/governance/metrics
 * Get detailed governance metrics (KPIs, trends, quality scores)
 */
app.get('/api/governance/metrics', async (req, res) => {
  try {
    // Prevent caching - always return fresh metrics
    res.set('Cache-Control', 'no-store, no-cache, must-revalidate, private');
    res.set('Pragma', 'no-cache');
    res.set('Expires', '0');

    const collector = new MetricsCollector();
    const metrics = await collector.collectMetrics();
    res.json(metrics);
  } catch (error) {
    console.error('Error collecting governance metrics:', error);
    res.status(500).json({ error: 'Internal server error', message: sanitizeError(error.message) });
  }
});

/**
 * GET /api/governance/trends
 * Get trend analysis for governance metrics
 * Query params:
 *   - period: time period (7d, 30d, 90d) - default: 30d
 */
app.get('/api/governance/trends', async (req, res) => {
  try {
    const period = req.query.period || '30d';
    const validPeriods = ['7d', '30d', '90d'];

    if (!validPeriods.includes(period)) {
      return res.status(400).json({
        error: 'Invalid period',
        message: `Period must be one of: ${validPeriods.join(', ')}`
      });
    }

    // Prevent caching - always return fresh trend data
    res.set('Cache-Control', 'no-store, no-cache, must-revalidate, private');
    res.set('Pragma', 'no-cache');
    res.set('Expires', '0');

    const collector = new MetricsCollector();
    const trends = await collector.analyzeTrends(period);
    res.json(trends);
  } catch (error) {
    console.error('Error analyzing governance trends:', error);
    res.status(500).json({ error: 'Internal server error', message: sanitizeError(error.message) });
  }
});

/**
 * GET /api/streams
 * Get workforce streams data and metrics
 */
app.get('/api/streams', async (req, res) => {
  try {
    const streamsPath = path.join(__dirname, '../../coordination/workforce-streams.json');
    const streams = await readJSON(streamsPath);

    if (!streams) {
      return res.status(404).json({
        error: 'Workforce streams not configured',
        details: 'workforce-streams.json not found'
      });
    }

    res.json(streams);
  } catch (error) {
    console.error('Error loading workforce streams:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

/**
 * GET /api/coordination/raw
 * Get raw coordination data (for debugging)
 */
app.get('/api/coordination/raw', async (req, res) => {
  try {
    const data = await loadCoordinationData();
    res.json(data);
  } catch (error) {
    console.error('Error loading coordination data:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

/**
 * GET /api/workers
 * Get detailed worker information
 */
app.get('/api/workers', async (req, res) => {
  const { withCustomSpan, addLabels } = require('./utils/apm-events');

  try {
    // Read live worker specs from all directories (active, completed, failed)
    const workerSpecsDir = path.join(COORD_DIR, 'worker-specs');

    const liveWorkerPool = await withCustomSpan('worker-pool-query', 'db.read', async () => {
      return await generateLiveWorkerPool(workerSpecsDir);
    });

    // Add custom labels for APM tracking
    addLabels({
      'worker.active_count': liveWorkerPool.stats.total_active,
      'worker.completed_count': liveWorkerPool.stats.total_completed,
      'worker.failed_count': liveWorkerPool.stats.total_failed,
      'worker.total_count': liveWorkerPool.stats.total_active + liveWorkerPool.stats.total_completed + liveWorkerPool.stats.total_failed
    });

    res.json(liveWorkerPool);
  } catch (error) {
    console.error('Error reading worker pool:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

/**
 * Generate live worker pool data from worker spec files
 */
async function generateLiveWorkerPool(specsDir) {
  const active_workers = [];
  const completed_workers = [];
  const failed_workers = [];

  // Read from multiple directories
  const directories = [
    { path: path.join(specsDir, 'active'), type: 'active' },
    { path: path.join(specsDir, 'completed'), type: 'completed' },
    { path: path.join(specsDir, 'failed'), type: 'failed' }
  ];

  for (const dir of directories) {
    try {
      const files = await fs.readdir(dir.path);
      const jsonFiles = files.filter(f => f.endsWith('.json'));

      for (const file of jsonFiles) {
        try {
          const content = await fs.readFile(path.join(dir.path, file), 'utf-8');
          const spec = JSON.parse(content);

          const worker = {
            worker_id: spec.worker_id,
            type: spec.worker_type,
            task_id: spec.task_id,
            spawned_at: spec.created_at,
            status: spec.status,
            parent_master: spec.parent_master
          };

          if (spec.execution) {
            worker.started_at = spec.execution.started_at;
            worker.completed_at = spec.execution.completed_at;
            worker.tokens_used = spec.execution.tokens_used;
            worker.killed_by = spec.execution.killed_by; // For zombie tracking
          }

          // Categorize by status
          if (spec.status === 'pending' || spec.status === 'running') {
            active_workers.push(worker);
          } else if (spec.status === 'completed' || spec.status === 'success') {
            completed_workers.push(worker);
          } else if (spec.status === 'failed') {
            failed_workers.push(worker);
          }
        } catch (err) {
          console.error(`Error reading worker spec ${file}:`, err);
        }
      }
    } catch (err) {
      // Directory might not exist, that's ok
      if (err.code !== 'ENOENT') {
        console.error(`Error reading directory ${dir.path}:`, err);
      }
    }
  }

  return {
    version: '2.0-live',
    updated_at: new Date().toISOString(),
    active_workers,
    completed_workers,
    failed_workers,
    stats: {
      total_active: active_workers.length,
      total_completed: completed_workers.length,
      total_failed: failed_workers.length
    }
  };
}

/**
 * Generate live Execution Manager data from EM state files (v4.0)
 */
async function generateLiveExecutionManagers(coordDir) {
  const active_ems = [];
  const completed_ems = [];
  const failed_ems = [];

  const emActiveDir = path.join(coordDir, 'execution-managers/active');
  const emCompletedDir = path.join(coordDir, 'execution-managers/completed');

  // Read active EMs
  try {
    const files = await fs.readdir(emActiveDir);
    const jsonFiles = files.filter(f => f.endsWith('.json'));

    for (const file of jsonFiles) {
      try {
        const content = await fs.readFile(path.join(emActiveDir, file), 'utf-8');
        const em = JSON.parse(content);
        active_ems.push(em);
      } catch (err) {
        console.error(`Error reading EM file ${file}:`, err);
      }
    }
  } catch (err) {
    if (err.code !== 'ENOENT') {
      console.error(`Error reading active EMs directory:`, err);
    }
  }

  // Read completed EMs (both successful and failed)
  try {
    const files = await fs.readdir(emCompletedDir);
    const jsonFiles = files.filter(f => f.endsWith('.json'));

    for (const file of jsonFiles) {
      try {
        const content = await fs.readFile(path.join(emCompletedDir, file), 'utf-8');
        const em = JSON.parse(content);

        if (em.status === 'failed') {
          failed_ems.push(em);
        } else {
          completed_ems.push(em);
        }
      } catch (err) {
        console.error(`Error reading EM file ${file}:`, err);
      }
    }
  } catch (err) {
    if (err.code !== 'ENOENT') {
      console.error(`Error reading completed EMs directory:`, err);
    }
  }

  const total = active_ems.length + completed_ems.length + failed_ems.length;
  const success_rate = (completed_ems.length + failed_ems.length) > 0
    ? ((completed_ems.length / (completed_ems.length + failed_ems.length)) * 100).toFixed(1)
    : 0;

  return {
    active: active_ems.length,
    completed: completed_ems.length,
    failed: failed_ems.length,
    total: total,
    success_rate: parseFloat(success_rate),
    active_ems,
    completed_ems,
    failed_ems
  };
}

/**
 * GET /api/execution-managers
 * Get detailed Execution Manager information (v4.0)
 */
app.get('/api/execution-managers', async (req, res) => {
  try {
    const emData = await generateLiveExecutionManagers(COORD_DIR);
    res.json(emData);
  } catch (error) {
    console.error('Error reading execution managers:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

/**
 * GET /api/tasks
 * Get task queue information
 */
app.get('/api/tasks', async (req, res) => {
  const { withCustomSpan, addLabels } = require('./utils/apm-events');

  try {
    const taskQueue = await withCustomSpan('task-queue-query', 'db.read', async () => {
      return await readJSON(FILES.taskQueue);
    });

    if (!taskQueue) {
      return res.status(500).json({ error: 'Failed to read task queue' });
    }

    // Add custom labels for task metrics
    const taskCounts = {
      pending: (taskQueue.pending || []).length,
      active: (taskQueue.active || []).length,
      completed: (taskQueue.completed || []).length
    };

    addLabels({
      'task.pending_count': taskCounts.pending,
      'task.active_count': taskCounts.active,
      'task.completed_count': taskCounts.completed,
      'task.total_count': taskCounts.pending + taskCounts.active + taskCounts.completed
    });

    res.json(taskQueue);
  } catch (error) {
    console.error('Error reading task queue:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

/**
 * Normalize event format to consistent schema
 */
function normalizeEvent(event) {
  // Ensure the event has a consistent schema
  const normalized = {
    id: event.id || `evt-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`,
    type: event.type || event.event_type || event.event || 'unknown',
    timestamp: event.timestamp || new Date().toISOString(),
    data: event.data || {},
    message: event.message || ''
  };

  // If data is a string, try to parse it as JSON
  if (typeof normalized.data === 'string') {
    try {
      normalized.data = JSON.parse(normalized.data);
    } catch (e) {
      // Keep as string if not valid JSON
      normalized.data = { message: normalized.data };
    }
  }

  // Extract common fields from root level to data if not already present
  if (event.task_id && !normalized.data.task_id) {
    normalized.data.task_id = event.task_id;
  }
  if (event.task_title && !normalized.data.task_title) {
    normalized.data.task_title = event.task_title;
  }
  if (event.assigned_to && !normalized.data.assigned_to) {
    normalized.data.assigned_to = event.assigned_to;
  }
  if (event.worker_id && !normalized.data.worker_id) {
    normalized.data.worker_id = event.worker_id;
  }

  // Generate message if not present
  if (!normalized.message) {
    normalized.message = `${normalized.type.replace(/_/g, ' ')}`;
    if (normalized.data.task_id) {
      normalized.message += `: ${normalized.data.task_id}`;
    }
    if (normalized.data.task_title) {
      normalized.message += ` - ${normalized.data.task_title}`;
    }
  }

  return normalized;
}

/**
 * GET /api/events
 * Get recent system events (merged with task events)
 * Query params:
 *   - limit: number of events to return (default: 50)
 *   - session: 'current' to get only current session events (since server start)
 */
app.get('/api/events', async (req, res) => {
  try {
    const limit = parseInt(req.query.limit) || 100;  // Increased default from 50 to 100
    const offset = parseInt(req.query.offset) || 0;
    const since = req.query.since;  // ISO date string for filtering
    const sessionOnly = req.query.session === 'current';
    const fsSync = require('fs');

    let events = [];

    // SINGLE SOURCE OF TRUTH: system-events.jsonl
    // All events (task, git, worker, system, etc.) should be written to this file
    if (fsSync.existsSync(FILES.systemEvents)) {
      const content = fsSync.readFileSync(FILES.systemEvents, 'utf-8');

      // Handle both JSONL (one JSON per line) and pretty-printed multi-line JSON
      // Try to detect format by checking if first line is a complete JSON object
      const firstLine = content.split('\n')[0];
      let isJsonl = false;
      try {
        if (firstLine && firstLine.trim().startsWith('{') && firstLine.trim().endsWith('}')) {
          JSON.parse(firstLine);
          isJsonl = true;
        }
      } catch (e) {
        // Not JSONL format
      }

      if (isJsonl) {
        // Original JSONL parsing
        const lines = content.trim().split('\n').filter(line => line);
        events = lines.map(line => {
          try {
            const parsed = JSON.parse(line);
            // Skip empty objects or objects without required fields
            if (!parsed || Object.keys(parsed).length === 0) {
              return null;
            }
            // Must have at least timestamp or type to be a valid event
            if (!parsed.timestamp && !parsed.type) {
              return null;
            }
            return normalizeEvent(parsed);
          } catch (e) {
            console.error('Error parsing event line:', e.message);
            return null;
          }
        }).filter(e => e !== null);
      } else {
        // Parse multi-line JSON format
        // Split by pattern: }\n{ to find object boundaries
        const chunks = content.split(/}\s*\n\s*{/);
        events = [];

        chunks.forEach((chunk, index) => {
          let jsonStr = chunk.trim();

          // Add back the braces we split on (except first and last)
          if (index > 0) jsonStr = '{' + jsonStr;
          if (index < chunks.length - 1) jsonStr = jsonStr + '}';

          // Skip empty or incomplete chunks
          if (!jsonStr || jsonStr.length < 10 || !jsonStr.includes('"id"')) {
            return;
          }

          try {
            const event = JSON.parse(jsonStr);
            // Validate required fields
            if (event.id && event.timestamp && event.type) {
              events.push(normalizeEvent(event));
            }
          } catch (e) {
            // Skip malformed entries silently to avoid console spam
            if (index === chunks.length - 1 && !jsonStr.includes('"id"')) {
              // Last chunk is often incomplete, ignore it
              return;
            }
            console.error(`Error parsing event chunk ${index}:`, e.message.substring(0, 100));
          }
        });
      }
    }

    // If session=current, only show events from event buffer (events since server started)
    if (sessionOnly) {
      events = eventBuffer.slice();
    }

    // Filter by timestamp if 'since' parameter provided
    if (since) {
      const sinceDate = new Date(since);
      events = events.filter(event => {
        const eventDate = new Date(event.timestamp);
        return eventDate >= sinceDate;
      });
    }

    // Sort by timestamp (most recent first)
    const sortedEvents = events.sort((a, b) => new Date(b.timestamp) - new Date(a.timestamp));

    // Apply pagination
    const totalEvents = sortedEvents.length;
    const paginatedEvents = sortedEvents.slice(offset, offset + limit);

    res.json({
      events: paginatedEvents,
      total: totalEvents,
      page: {
        offset: offset,
        limit: limit,
        hasMore: (offset + limit) < totalEvents
      }
    });
  } catch (error) {
    console.error('Error reading events:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

/**
 * GET /api/activity-feed
 * Get activity feed for last 24 hours, grouped by hour
 */
app.get('/api/activity-feed', async (req, res) => {
  try {
    const fsSync = require('fs');
    const hours = parseInt(req.query.hours) || 24;

    // Calculate time range
    const now = new Date();
    const since = new Date(now.getTime() - (hours * 60 * 60 * 1000));

    let allEvents = [];

    // Read events file
    if (fsSync.existsSync(FILES.systemEvents)) {
      const content = fsSync.readFileSync(FILES.systemEvents, 'utf-8');
      const lines = content.trim().split('\n').filter(line => line);

      // Parse each line as JSON
      for (const line of lines) {
        try {
          const event = JSON.parse(line);
          const eventDate = new Date(event.timestamp);

          // Filter by time range
          if (eventDate >= since && eventDate <= now) {
            allEvents.push(event);
          }
        } catch (e) {
          // Skip malformed lines
          continue;
        }
      }
    }

    // Sort by timestamp (newest first)
    allEvents.sort((a, b) => new Date(b.timestamp) - new Date(a.timestamp));

    // Group events by hour for timeline display
    const hourlyGroups = {};
    const eventTypeStats = {};

    allEvents.forEach(event => {
      // Group by hour
      const eventDate = new Date(event.timestamp);
      const hourKey = new Date(
        eventDate.getFullYear(),
        eventDate.getMonth(),
        eventDate.getDate(),
        eventDate.getHours()
      ).toISOString();

      if (!hourlyGroups[hourKey]) {
        hourlyGroups[hourKey] = {
          hour: hourKey,
          count: 0,
          events: []
        };
      }

      hourlyGroups[hourKey].count++;
      if (hourlyGroups[hourKey].events.length < 10) { // Limit events per hour for display
        hourlyGroups[hourKey].events.push({
          id: event.id,
          type: event.type,
          timestamp: event.timestamp,
          message: event.message || event.data?.message || ''
        });
      }

      // Track event type statistics
      if (!eventTypeStats[event.type]) {
        eventTypeStats[event.type] = 0;
      }
      eventTypeStats[event.type]++;
    });

    // Convert hourly groups to array and sort
    const timeline = Object.values(hourlyGroups).sort((a, b) =>
      new Date(b.hour) - new Date(a.hour)
    );

    res.json({
      period: {
        hours: hours,
        from: since.toISOString(),
        to: now.toISOString()
      },
      summary: {
        totalEvents: allEvents.length,
        uniqueHours: timeline.length,
        eventTypes: Object.keys(eventTypeStats).length
      },
      statistics: eventTypeStats,
      timeline: timeline,
      recentEvents: allEvents.slice(0, 20) // Last 20 events for quick view
    });
  } catch (error) {
    console.error('Error generating activity feed:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

/**
 * GET /api/git-operations
 * Get git operations log
 * Query params:
 *   - limit: number of operations to return (default: 50)
 *   - worker_id: filter by specific worker
 *   - status: filter by status (success/failed)
 */
app.get('/api/git-operations', async (req, res) => {
  try {
    const limit = parseInt(req.query.limit) || 50;
    const workerFilter = req.query.worker_id;
    const statusFilter = req.query.status;
    const fsSync = require('fs');

    let gitOperations = [];

    // Read git-operations.jsonl
    const gitOpsPath = path.join(COORD_DIR, 'git-operations.jsonl');
    if (fsSync.existsSync(gitOpsPath)) {
      const content = fsSync.readFileSync(gitOpsPath, 'utf-8');
      gitOperations = content
        .split('\n')
        .filter(line => line.trim())
        .map(line => JSON.parse(line));
    }

    // Apply filters
    let filteredOps = gitOperations;

    if (workerFilter) {
      filteredOps = filteredOps.filter(op => op.worker_id === workerFilter);
    }

    if (statusFilter) {
      filteredOps = filteredOps.filter(op => op.status === statusFilter);
    }

    // Sort by timestamp (most recent first) and limit
    filteredOps = filteredOps
      .sort((a, b) => new Date(b.timestamp) - new Date(a.timestamp))
      .slice(0, limit);

    res.json({
      operations: filteredOps,
      total: filteredOps.length,
      filters: { worker_id: workerFilter, status: statusFilter }
    });
  } catch (error) {
    console.error('Error reading git operations:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

/**
 * GET /api/git-status
 * Get current git repository status and last operations
 */
app.get('/api/git-status', async (req, res) => {
  try {
    const fsSync = require('fs');
    const { execSync } = require('child_process');

    let gitStatus = {
      online: true,
      lastPR: null,
      lastPush: null,
      lastSync: null,
      currentBranch: 'unknown',
      ahead: 0,
      behind: 0
    };

    // Try to get current git status
    try {
      gitStatus.currentBranch = execSync('git rev-parse --abbrev-ref HEAD', { encoding: 'utf-8' }).trim();

      // Get ahead/behind counts
      const status = execSync('git status --porcelain -b', { encoding: 'utf-8' });
      const branchLine = status.split('\n')[0];
      const aheadMatch = branchLine.match(/ahead (\d+)/);
      const behindMatch = branchLine.match(/behind (\d+)/);

      if (aheadMatch) gitStatus.ahead = parseInt(aheadMatch[1]);
      if (behindMatch) gitStatus.behind = parseInt(behindMatch[1]);
    } catch (e) {
      gitStatus.online = false;
    }

    // Read git operations to find last PR, push, etc.
    const gitOpsPath = path.join(COORD_DIR, 'git-operations.jsonl');
    if (fsSync.existsSync(gitOpsPath)) {
      const content = fsSync.readFileSync(gitOpsPath, 'utf-8');
      const operations = content
        .split('\n')
        .filter(line => line.trim())
        .map(line => {
          try {
            return JSON.parse(line);
          } catch (e) {
            return null;
          }
        })
        .filter(op => op !== null);

      // Find last PR creation
      const prOps = operations.filter(op => op.operation === 'pr_create' || op.operation === 'pr_created');
      if (prOps.length > 0) {
        const lastPR = prOps[prOps.length - 1];
        gitStatus.lastPR = {
          timestamp: lastPR.timestamp,
          pr_number: lastPR.pr_number,
          title: lastPR.pr_title || lastPR.title,
          branch: lastPR.branch
        };
      }

      // Find last push
      const pushOps = operations.filter(op =>
        op.operation === 'push' ||
        op.operation === 'manual_commit_push' ||
        op.operation === 'auto_commit_push'
      );
      if (pushOps.length > 0) {
        const lastPush = pushOps[pushOps.length - 1];
        gitStatus.lastPush = {
          timestamp: lastPush.timestamp,
          branch: lastPush.branch,
          commits: lastPush.commits_count || 1,
          worker_id: lastPush.worker_id
        };
      }

      // Last sync is the most recent of PR or push
      const allSyncOps = [...prOps, ...pushOps].sort((a, b) =>
        new Date(b.timestamp) - new Date(a.timestamp)
      );
      if (allSyncOps.length > 0) {
        gitStatus.lastSync = {
          timestamp: allSyncOps[0].timestamp,
          operation: allSyncOps[0].operation
        };
      }
    }

    res.json(gitStatus);
  } catch (error) {
    console.error('Error getting git status:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

/**
 * GET /api/health-alerts
 * Get current health alerts with visual status indicators
 */
app.get('/api/health-alerts',
  getLimiter,
  async (req, res) => {
  try {
    // Read health alerts file
    const alertsFile = path.join(__dirname, '../../coordination/health-alerts.json');

    if (!fsSync.existsSync(alertsFile)) {
      return res.json({
        alerts: [],
        summary: {
          critical: 0,
          high: 0,
          medium: 0,
          low: 0,
          total: 0
        },
        healthStatus: 'healthy'
      });
    }

    const alertsData = JSON.parse(fsSync.readFileSync(alertsFile, 'utf-8'));
    const alerts = alertsData.alerts || [];

    // Count alerts by severity
    const summary = {
      critical: alerts.filter(a => a.severity === 'critical').length,
      high: alerts.filter(a => a.severity === 'high').length,
      medium: alerts.filter(a => a.severity === 'medium').length,
      low: alerts.filter(a => a.severity === 'low').length,
      total: alerts.length
    };

    // Determine overall health status
    let healthStatus = 'healthy'; // green
    let statusColor = '#10b981';

    if (summary.critical > 0) {
      healthStatus = 'critical'; // red
      statusColor = '#ef4444';
    } else if (summary.high > 0) {
      healthStatus = 'warning'; // yellow/orange
      statusColor = '#f59e0b';
    } else if (summary.medium > 0) {
      healthStatus = 'caution'; // yellow
      statusColor = '#eab308';
    }

    // Add visual indicators to each alert
    const enrichedAlerts = alerts.map(alert => ({
      ...alert,
      color: alert.severity === 'critical' ? '#ef4444' :
             alert.severity === 'high' ? '#f59e0b' :
             alert.severity === 'medium' ? '#eab308' :
             '#3b82f6',
      icon: alert.severity === 'critical' ? '🔴' :
            alert.severity === 'high' ? '🟠' :
            alert.severity === 'medium' ? '🟡' :
            '🔵',
      isNew: (Date.now() - new Date(alert.created_at).getTime()) < 300000 // New if < 5 minutes
    }));

    res.json({
      alerts: enrichedAlerts,
      summary,
      healthStatus,
      statusColor,
      lastChecked: new Date().toISOString()
    });

  } catch (error) {
    console.error('Error reading health alerts:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

/**
 * GET /api/moe-intelligence
 * Get MoE routing decisions and pattern analysis for visualizations
 */
app.get('/api/moe-intelligence',
  getLimiter,
  async (req, res) => {
  try {
    const timeRange = req.query.range || '30d'; // 1h, 6h, 24h, 7d, 30d - default to 30d to show historical data

    // Read routing decisions
    const decisionsFile = path.join(__dirname, '../../coordination/masters/coordinator/knowledge-base/routing-decisions.jsonl');
    const patternsFile = path.join(__dirname, '../../coordination/memory/long-term/task-patterns.json');

    let routingDecisions = [];
    if (fsSync.existsSync(decisionsFile)) {
      const content = fsSync.readFileSync(decisionsFile, 'utf-8');
      routingDecisions = content
        .trim()
        .split('\n')
        .filter(line => line)
        .map(line => {
          try {
            const parsed = JSON.parse(line);
            // Normalize both old and new formats
            if (parsed.decision) {
              // New MoE format with decision object
              return {
                task_id: parsed.task_id,
                timestamp: parsed.timestamp,
                routed_to: parsed.decision.primary_expert,
                confidence: parsed.decision.primary_confidence,
                strategy: parsed.decision.strategy,
                rule_used: parsed.routing_strategy || 'mixture_of_experts',
                scores: parsed.decision.scores
              };
            } else if (parsed.routed_to && parsed.timestamp) {
              // Old format with routed_to
              return {
                task_id: parsed.task_id,
                timestamp: parsed.timestamp,
                routed_to: parsed.routed_to,
                confidence: parsed.confidence || 0.5,
                strategy: parsed.strategy || 'single_expert',
                rule_used: parsed.rule_used || 'rule_based'
              };
            } else if (parsed.learned_at) {
              // Learner pattern format - skip these for routing decisions
              return null;
            }
            return null;
          } catch (e) {
            // Skip malformed JSON lines
            return null;
          }
        })
        .filter(item => item !== null);
    }

    // Filter by time range
    const now = Date.now();
    const rangeMs = {
      '1h': 3600000,
      '6h': 21600000,
      '24h': 86400000,
      '7d': 604800000,
      '30d': 2592000000
    }[timeRange] || 2592000000;

    const filteredDecisions = routingDecisions.filter(d => {
      if (!d.timestamp) return false;
      const timestamp = new Date(d.timestamp).getTime();
      return (now - timestamp) <= rangeMs;
    });

    // Calculate routing flow (for Sankey diagram)
    const routingFlow = {};
    filteredDecisions.forEach(d => {
      const key = `${d.rule_used}->${d.routed_to}`;
      routingFlow[key] = (routingFlow[key] || 0) + 1;
    });

    // Calculate confidence distribution
    const confidenceBuckets = {
      '0-25': 0,
      '26-50': 0,
      '51-75': 0,
      '76-90': 0,
      '91-100': 0
    };

    filteredDecisions.forEach(d => {
      const conf = parseFloat(d.confidence || 0) * 100;
      if (conf <= 25) confidenceBuckets['0-25']++;
      else if (conf <= 50) confidenceBuckets['26-50']++;
      else if (conf <= 75) confidenceBuckets['51-75']++;
      else if (conf <= 90) confidenceBuckets['76-90']++;
      else confidenceBuckets['91-100']++;
    });

    // Calculate success rates by master type
    const masterStats = {};
    filteredDecisions.forEach(d => {
      const expert = d.routed_to;
      if (!expert) return;
      if (!masterStats[expert]) {
        masterStats[expert] = {
          total: 0,
          highConfidence: 0,
          strategies: {}
        };
      }
      masterStats[expert].total++;
      if (parseFloat(d.confidence || 0) > 0.8) {
        masterStats[expert].highConfidence++;
      }
      const strategy = d.strategy || 'unknown';
      masterStats[expert].strategies[strategy] =
        (masterStats[expert].strategies[strategy] || 0) + 1;
    });

    // Read task patterns if available
    let taskPatterns = null;
    if (fsSync.existsSync(patternsFile)) {
      taskPatterns = JSON.parse(fsSync.readFileSync(patternsFile, 'utf-8'));
    }

    // Create hourly heat map data
    const hourlyActivity = {};
    filteredDecisions.forEach(d => {
      const hour = new Date(d.timestamp).getHours();
      const master = d.routed_to;
      if (!hourlyActivity[hour]) hourlyActivity[hour] = {};
      hourlyActivity[hour][master] = (hourlyActivity[hour][master] || 0) + 1;
    });

    const responseData = {
      summary: {
        totalDecisions: filteredDecisions.length,
        timeRange,
        avgConfidence: filteredDecisions.length > 0
          ? (filteredDecisions.reduce((sum, d) => sum + parseFloat(d.confidence || 0), 0) / filteredDecisions.length).toFixed(3)
          : 0,
        mostUsedMaster: Object.entries(masterStats)
          .sort((a, b) => b[1].total - a[1].total)[0]?.[0] || 'none',
        uniqueStrategies: [...new Set(filteredDecisions.map(d => d.strategy).filter(s => s))]
      },
      routingFlow,
      confidenceDistribution: confidenceBuckets,
      masterStatistics: masterStats,
      hourlyHeatMap: hourlyActivity,
      taskPatterns: taskPatterns?.patterns || null,
      recentDecisions: filteredDecisions.slice(-10).reverse().map(d => ({
        task_id: d.task_id,
        timestamp: d.timestamp,
        routed_to: d.routed_to,
        confidence: d.confidence,
        strategy: d.strategy,
        decision: {
          primary_expert: d.routed_to,
          primary_confidence: d.confidence,
          strategy: d.strategy
        },
        scores: d.scores
      }))
    };

    // Add APM labels for MoE routing metrics
    const { addLabels } = require('./utils/apm-events');
    addLabels({
      'moe.total_decisions': filteredDecisions.length,
      'moe.avg_confidence': parseFloat(responseData.summary.avgConfidence),
      'moe.most_used_master': responseData.summary.mostUsedMaster,
      'moe.unique_strategies': responseData.summary.uniqueStrategies.length,
      'moe.time_range': timeRange
    });

    res.json(responseData);

  } catch (error) {
    console.error('Error reading MoE intelligence data:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

/**
 * GET /api/moe-learning
 * Get MoE learning state, routing intelligence, and learning metrics
 */
app.get('/api/moe-learning',
  getLimiter,
  async (req, res) => {
  try {
    const learningStateFile = path.join(__dirname, '../../coordination/moe-learning/learning-state.json');
    const routingIntelFile = path.join(__dirname, '../../coordination/memory/long-term/routing-intelligence.json');
    const taskPatternsFile = path.join(__dirname, '../../coordination/memory/long-term/task-patterns.json');
    const learningMetricsFile = path.join(__dirname, '../../coordination/metrics/learning-monitor-metrics.json');
    const learningEventsFile = path.join(__dirname, '../../coordination/events/learning-events.jsonl');

    // Read learning state
    let learningState = null;
    if (fsSync.existsSync(learningStateFile)) {
      learningState = JSON.parse(fsSync.readFileSync(learningStateFile, 'utf-8'));
    }

    // Read routing intelligence
    let routingIntelligence = null;
    if (fsSync.existsSync(routingIntelFile)) {
      routingIntelligence = JSON.parse(fsSync.readFileSync(routingIntelFile, 'utf-8'));
    }

    // Read task patterns
    let taskPatterns = null;
    if (fsSync.existsSync(taskPatternsFile)) {
      taskPatterns = JSON.parse(fsSync.readFileSync(taskPatternsFile, 'utf-8'));
    }

    // Read learning metrics
    let learningMetrics = null;
    if (fsSync.existsSync(learningMetricsFile)) {
      learningMetrics = JSON.parse(fsSync.readFileSync(learningMetricsFile, 'utf-8'));
    }

    // Read recent learning events
    let recentEvents = [];
    if (fsSync.existsSync(learningEventsFile)) {
      const content = fsSync.readFileSync(learningEventsFile, 'utf-8');
      recentEvents = content
        .trim()
        .split('\n')
        .filter(line => line)
        .slice(-20)
        .map(line => {
          try {
            return JSON.parse(line);
          } catch {
            return null;
          }
        })
        .filter(e => e)
        .reverse();
    }

    res.json({
      learningState,
      routingIntelligence: routingIntelligence ? {
        version: routingIntelligence.version,
        lastUpdated: routingIntelligence.created_at,
        agentRouting: routingIntelligence.agent_routing_intelligence,
        workflowIntelligence: routingIntelligence.workflow_intelligence,
        operationalPatterns: routingIntelligence.operational_patterns,
        confidenceCalibration: routingIntelligence.confidence_calibration,
        recommendations: routingIntelligence.recommendations
      } : null,
      taskPatterns: taskPatterns?.patterns || null,
      learningMetrics,
      recentEvents
    });

  } catch (error) {
    console.error('Error reading MoE learning data:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

/**
 * GET /api/ddqd-testing
 * Get DDQD test history and current test status
 */
app.get('/api/ddqd-testing',
  getLimiter,
  async (req, res) => {
  try {
    const ddqdHistoryFile = path.join(__dirname, '../../coordination/ddqd-history.json');
    const activeTestsFile = path.join(__dirname, '../../coordination/ddqd-active-tests.json');

    // Read DDQD history
    let ddqdHistory = { tests: [] };
    if (fsSync.existsSync(ddqdHistoryFile)) {
      ddqdHistory = JSON.parse(fsSync.readFileSync(ddqdHistoryFile, 'utf-8'));
    }

    // Read active tests if any
    let activeTests = [];
    if (fsSync.existsSync(activeTestsFile)) {
      activeTests = JSON.parse(fsSync.readFileSync(activeTestsFile, 'utf-8'));
    }

    // Calculate summary statistics
    const tests = ddqdHistory.tests || [];
    const completedTests = tests.filter(t => t.status === 'completed');
    const avgAccuracy = completedTests.length > 0
      ? completedTests.reduce((sum, t) => sum + (t.routingAccuracy || 0), 0) / completedTests.length
      : 0;

    res.json({
      summary: {
        totalTests: tests.length,
        completedTests: completedTests.length,
        avgRoutingAccuracy: avgAccuracy.toFixed(2),
        latestTest: tests[tests.length - 1] || null
      },
      tests: tests.slice(-20).reverse(), // Last 20 tests
      activeTests
    });

  } catch (error) {
    console.error('Error reading DDQD testing data:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

/**
 * GET /api/daemon/status
 * Get worker daemon status (for backward compatibility)
 */
app.get('/api/daemon/status', async (req, res) => {
  try {
    const daemonStatus = await getDaemonStatus();
    res.json(daemonStatus);
  } catch (error) {
    console.error('Error getting daemon status:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

/**
 * GET /api/daemons/all
 * Get status of all system daemons
 */
app.get('/api/daemons/all',
  getLimiter,
  async (req, res) => {
  try {
    const { execSync } = require('child_process');

    // Check each daemon process
    const checkDaemon = (name, processName) => {
      try {
        const result = execSync(`pgrep -f "${processName}" | head -1`, { encoding: 'utf8' }).trim();
        if (result) {
          const pid = parseInt(result);
          // Get process info
          const psInfo = execSync(`ps -p ${pid} -o pid,etime,rss | tail -1`, { encoding: 'utf8' }).trim();
          const [, uptime, memory] = psInfo.split(/\s+/);

          return {
            status: 'running',
            pid: pid,
            uptime: uptime || 'unknown',
            memory: parseInt(memory) || 0
          };
        }
      } catch (e) {
        // Process not found
      }
      return {
        status: 'stopped',
        pid: null,
        uptime: '0',
        memory: 0
      };
    };

    const daemons = {
      'worker-daemon': checkDaemon('worker-daemon', 'worker-daemon.sh'),
      'health-monitor': checkDaemon('health-monitor', 'health-monitor-daemon.sh'),
      'metrics-snapshot': checkDaemon('metrics-snapshot', 'metrics-snapshot-daemon.sh'),
      'coordinator-daemon': checkDaemon('coordinator', 'coordinator-daemon.sh'),
      'integration-validator': checkDaemon('integration-validator', 'integration-validator-daemon.sh'),
      'pm-daemon': checkDaemon('pm-daemon', 'pm-daemon.sh'),
      'heartbeat-monitor': checkDaemon('heartbeat-monitor', 'heartbeat-monitor-daemon.sh'),
      'worker-restart': checkDaemon('worker-restart', 'worker-restart-daemon.sh'),
      'failure-pattern': checkDaemon('failure-pattern', 'failure-pattern-daemon.sh'),
      'auto-fix': checkDaemon('auto-fix', 'auto-fix-daemon.sh'),
      'moe-learning': checkDaemon('moe-learning', 'moe-learning-daemon.sh'),
      'learning-monitor': checkDaemon('learning-monitor', 'learning-task-monitor-daemon.sh'),
      'daemon-supervisor': checkDaemon('daemon-supervisor', 'daemon-supervisor.sh'),
      'zombie-cleanup': checkDaemon('zombie-cleanup', 'zombie-killer-daemon.sh'),
      'handoff-processor': checkDaemon('handoff-processor', 'handoff-processor-daemon.sh'),
      'threat-intel': checkDaemon('threat-intel', 'threat-intel-daemon.sh'),
      'backup': checkDaemon('backup', 'backup-daemon.sh'),
      'api-server': {
        status: 'running',
        pid: process.pid,
        uptime: process.uptime() + 's',
        memory: process.memoryUsage().rss
      }
    };

    // Count running/stopped
    const summary = {
      total: Object.keys(daemons).length,
      running: Object.values(daemons).filter(d => d.status === 'running').length,
      stopped: Object.values(daemons).filter(d => d.status === 'stopped').length
    };

    res.json({
      daemons,
      summary,
      timestamp: new Date().toISOString()
    });

  } catch (error) {
    console.error('Error checking daemon statuses:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

/**
 * POST /api/health-monitor/start
 * Start health monitor daemon
 */
app.post('/api/health-monitor/start', async (req, res) => {
  try {
    const scriptPath = path.join(__dirname, '../../scripts/health-monitor-daemon.sh');

    // Check if already running (pgrep returns 1 when no match, which throws)
    try {
      const isRunning = await safeExec('pgrep', ['-f', 'health-monitor-daemon.sh']);
      if (isRunning.stdout.trim()) {
        return res.json({ status: 'already_running', message: 'Health monitor is already running' });
      }
    } catch (e) {
      // pgrep returns exit code 1 when no processes match - this is expected
    }

    // Start the daemon
    const { spawn } = require('child_process');
    spawn('bash', [scriptPath], {
      detached: true,
      stdio: 'ignore'
    }).unref();

    setTimeout(() => {
      res.json({ status: 'started', message: 'Health monitor daemon started successfully' });
    }, 1000);
  } catch (error) {
    console.error('Error starting health monitor:', error);
    res.status(500).json({ error: 'Failed to start health monitor' });
  }
});

/**
 * POST /api/health-monitor/stop
 * Stop health monitor daemon
 */
app.post('/api/health-monitor/stop', async (req, res) => {
  try {
    await safeExec('pkill', ['-f', 'health-monitor-daemon.sh']);
    res.json({ status: 'stopped', message: 'Health monitor daemon stopped' });
  } catch (error) {
    res.json({ status: 'not_running', message: 'Health monitor was not running' });
  }
});

/**
 * POST /api/metrics-snapshot/start
 * Start metrics snapshot daemon
 */
app.post('/api/metrics-snapshot/start', async (req, res) => {
  try {
    const scriptPath = path.join(__dirname, '../../scripts/metrics-snapshot-daemon.sh');

    // Check if already running (pgrep returns 1 when no match, which throws)
    try {
      const isRunning = await safeExec('pgrep', ['-f', 'metrics-snapshot-daemon.sh']);
      if (isRunning.stdout.trim()) {
        return res.json({ status: 'already_running', message: 'Metrics snapshot is already running' });
      }
    } catch (e) {
      // pgrep returns exit code 1 when no processes match - this is expected
    }

    // Start the daemon
    const { spawn } = require('child_process');
    spawn('bash', [scriptPath], {
      detached: true,
      stdio: 'ignore'
    }).unref();

    setTimeout(() => {
      res.json({ status: 'started', message: 'Metrics snapshot daemon started successfully' });
    }, 1000);
  } catch (error) {
    console.error('Error starting metrics snapshot:', error);
    res.status(500).json({ error: 'Failed to start metrics snapshot' });
  }
});

/**
 * POST /api/metrics-snapshot/stop
 * Stop metrics snapshot daemon
 */
app.post('/api/metrics-snapshot/stop', async (req, res) => {
  try {
    await safeExec('pkill', ['-f', 'metrics-snapshot-daemon.sh']);
    res.json({ status: 'stopped', message: 'Metrics snapshot daemon stopped' });
  } catch (error) {
    res.json({ status: 'not_running', message: 'Metrics snapshot was not running' });
  }
});

/**
 * POST /api/heartbeat-monitor/start
 * Start heartbeat monitor daemon
 */
app.post('/api/heartbeat-monitor/start', async (req, res) => {
  try {
    const scriptPath = path.join(__dirname, '../../scripts/daemons/heartbeat-monitor-daemon.sh');

    // Check if already running (pgrep returns 1 when no match, which throws)
    try {
      const isRunning = await safeExec('pgrep', ['-f', 'heartbeat-monitor-daemon.sh']);
      if (isRunning.stdout.trim()) {
        return res.json({ status: 'already_running', message: 'Heartbeat monitor is already running' });
      }
    } catch (e) {
      // pgrep returns exit code 1 when no processes match - this is expected
    }

    // Start the daemon
    const { spawn } = require('child_process');
    spawn('bash', [scriptPath], {
      detached: true,
      stdio: 'ignore'
    }).unref();

    setTimeout(() => {
      res.json({ status: 'started', message: 'Heartbeat monitor daemon started successfully' });
    }, 1000);
  } catch (error) {
    console.error('Error starting heartbeat monitor:', error);
    res.status(500).json({ error: 'Failed to start heartbeat monitor' });
  }
});

/**
 * POST /api/heartbeat-monitor/stop
 * Stop heartbeat monitor daemon
 */
app.post('/api/heartbeat-monitor/stop', async (req, res) => {
  try {
    await safeExec('pkill', ['-f', 'heartbeat-monitor-daemon.sh']);
    res.json({ status: 'stopped', message: 'Heartbeat monitor daemon stopped' });
  } catch (error) {
    res.json({ status: 'not_running', message: 'Heartbeat monitor was not running' });
  }
});

/**
 * POST /api/learning-monitor/start
 * Start learning task monitor daemon
 */
app.post('/api/learning-monitor/start', async (req, res) => {
  try {
    const scriptPath = path.join(__dirname, '../../scripts/daemons/learning-task-monitor-daemon.sh');

    // Check if already running (pgrep returns 1 when no match, which throws)
    try {
      const isRunning = await safeExec('pgrep', ['-f', 'learning-task-monitor-daemon.sh']);
      if (isRunning.stdout.trim()) {
        return res.json({ status: 'already_running', message: 'Learning monitor is already running' });
      }
    } catch (e) {
      // pgrep returns exit code 1 when no processes match - this is expected
    }

    // Start the daemon
    const { spawn } = require('child_process');
    spawn('bash', [scriptPath], {
      detached: true,
      stdio: 'ignore'
    }).unref();

    setTimeout(() => {
      res.json({ status: 'started', message: 'Learning monitor daemon started successfully' });
    }, 1000);
  } catch (error) {
    console.error('Error starting learning monitor:', error);
    res.status(500).json({ error: 'Failed to start learning monitor' });
  }
});

/**
 * POST /api/learning-monitor/stop
 * Stop learning task monitor daemon
 */
app.post('/api/learning-monitor/stop', async (req, res) => {
  try {
    await safeExec('pkill', ['-f', 'learning-task-monitor-daemon.sh']);
    res.json({ status: 'stopped', message: 'Learning monitor daemon stopped' });
  } catch (error) {
    res.json({ status: 'not_running', message: 'Learning monitor was not running' });
  }
});

/**
 * POST /api/daemon-supervisor/start
 * Start daemon supervisor
 */
app.post('/api/daemon-supervisor/start', async (req, res) => {
  try {
    const scriptPath = path.join(__dirname, '../../scripts/daemon-supervisor.sh');

    // Check if already running (pgrep returns 1 when no match, which throws)
    try {
      const isRunning = await safeExec('pgrep', ['-f', 'daemon-supervisor.sh']);
      if (isRunning.stdout.trim()) {
        return res.json({ status: 'already_running', message: 'Daemon supervisor is already running' });
      }
    } catch (e) {
      // pgrep returns exit code 1 when no processes match - this is expected
    }

    // Start the daemon
    const { spawn } = require('child_process');
    spawn('bash', [scriptPath], {
      detached: true,
      stdio: 'ignore'
    }).unref();

    setTimeout(() => {
      res.json({ status: 'started', message: 'Daemon supervisor started successfully' });
    }, 1000);
  } catch (error) {
    console.error('Error starting daemon supervisor:', error);
    res.status(500).json({ error: 'Failed to start daemon supervisor' });
  }
});

/**
 * POST /api/daemon-supervisor/stop
 * Stop daemon supervisor
 */
app.post('/api/daemon-supervisor/stop', async (req, res) => {
  try {
    await safeExec('pkill', ['-f', 'daemon-supervisor.sh']);
    res.json({ status: 'stopped', message: 'Daemon supervisor stopped' });
  } catch (error) {
    res.json({ status: 'not_running', message: 'Daemon supervisor was not running' });
  }
});

/**
 * POST /api/zombie-cleanup/start
 * Start zombie cleanup daemon
 */
app.post('/api/zombie-cleanup/start', async (req, res) => {
  try {
    const scriptPath = path.join(__dirname, '../../scripts/zombie-killer-daemon.sh');

    // Check if already running (pgrep returns 1 when no match, which throws)
    try {
      const isRunning = await safeExec('pgrep', ['-f', 'zombie-killer-daemon.sh']);
      if (isRunning.stdout.trim()) {
        return res.json({ status: 'already_running', message: 'Zombie cleanup is already running' });
      }
    } catch (e) {
      // pgrep returns exit code 1 when no processes match - this is expected
    }

    // Start the daemon
    const { spawn } = require('child_process');
    spawn('bash', [scriptPath], {
      detached: true,
      stdio: 'ignore'
    }).unref();

    setTimeout(() => {
      res.json({ status: 'started', message: 'Zombie cleanup daemon started successfully' });
    }, 1000);
  } catch (error) {
    console.error('Error starting zombie cleanup:', error);
    res.status(500).json({ error: 'Failed to start zombie cleanup' });
  }
});

/**
 * POST /api/zombie-cleanup/stop
 * Stop zombie cleanup daemon
 */
app.post('/api/zombie-cleanup/stop', async (req, res) => {
  try {
    await safeExec('pkill', ['-f', 'zombie-killer-daemon.sh']);
    res.json({ status: 'stopped', message: 'Zombie cleanup daemon stopped' });
  } catch (error) {
    res.json({ status: 'not_running', message: 'Zombie cleanup was not running' });
  }
});

/**
 * POST /api/handoff-processor/start
 * Start handoff processor daemon (CRITICAL for task execution)
 */
app.post('/api/handoff-processor/start', async (req, res) => {
  try {
    const scriptPath = path.join(__dirname, '../../scripts/handoff-processor-daemon.sh');

    // Check if already running (pgrep returns 1 when no match, which throws)
    try {
      const isRunning = await safeExec('pgrep', ['-f', 'handoff-processor-daemon.sh']);
      if (isRunning.stdout.trim()) {
        return res.json({ status: 'already_running', message: 'Handoff processor is already running' });
      }
    } catch (e) {
      // pgrep returns exit code 1 when no processes match - this is expected
    }

    // Start the daemon
    const { spawn } = require('child_process');
    spawn('bash', [scriptPath], {
      detached: true,
      stdio: 'ignore'
    }).unref();

    setTimeout(() => {
      res.json({ status: 'started', message: 'Handoff processor daemon started successfully' });
    }, 1000);
  } catch (error) {
    console.error('Error starting handoff processor:', error);
    res.status(500).json({ error: 'Failed to start handoff processor' });
  }
});

/**
 * POST /api/handoff-processor/stop
 * Stop handoff processor daemon
 */
app.post('/api/handoff-processor/stop', async (req, res) => {
  try {
    await safeExec('pkill', ['-f', 'handoff-processor-daemon.sh']);
    res.json({ status: 'stopped', message: 'Handoff processor daemon stopped' });
  } catch (error) {
    res.json({ status: 'not_running', message: 'Handoff processor was not running' });
  }
});

/**
 * POST /api/threat-intel/start
 * Start threat intel daemon
 */
app.post('/api/threat-intel/start', async (req, res) => {
  try {
    const scriptPath = path.join(__dirname, '../../scripts/daemons/threat-intel-daemon.sh');

    // Check if already running
    try {
      const isRunning = await safeExec('pgrep', ['-f', 'threat-intel-daemon.sh']);
      if (isRunning.stdout.trim()) {
        return res.json({ status: 'already_running', message: 'Threat intel daemon is already running' });
      }
    } catch (e) {
      // pgrep returns exit code 1 when no processes match - this is expected
    }

    // Start the daemon
    const { spawn } = require('child_process');
    spawn('bash', [scriptPath], {
      detached: true,
      stdio: 'ignore'
    }).unref();

    setTimeout(() => {
      res.json({ status: 'started', message: 'Threat intel daemon started successfully' });
    }, 1000);
  } catch (error) {
    console.error('Error starting threat intel daemon:', error);
    res.status(500).json({ error: 'Failed to start threat intel daemon' });
  }
});

/**
 * POST /api/threat-intel/stop
 * Stop threat intel daemon
 */
app.post('/api/threat-intel/stop', async (req, res) => {
  try {
    await safeExec('pkill', ['-f', 'threat-intel-daemon.sh']);
    res.json({ status: 'stopped', message: 'Threat intel daemon stopped' });
  } catch (error) {
    res.json({ status: 'not_running', message: 'Threat intel daemon was not running' });
  }
});

/**
 * POST /api/backup/start
 * Start backup daemon
 */
app.post('/api/backup/start', async (req, res) => {
  try {
    const scriptPath = path.join(__dirname, '../../scripts/daemons/backup-daemon.sh');

    // Check if already running
    try {
      const isRunning = await safeExec('pgrep', ['-f', 'backup-daemon.sh']);
      if (isRunning.stdout.trim()) {
        return res.json({ status: 'already_running', message: 'Backup daemon is already running' });
      }
    } catch (e) {
      // pgrep returns exit code 1 when no processes match - this is expected
    }

    // Start the daemon
    const { spawn } = require('child_process');
    spawn('bash', [scriptPath], {
      detached: true,
      stdio: 'ignore'
    }).unref();

    setTimeout(() => {
      res.json({ status: 'started', message: 'Backup daemon started successfully' });
    }, 1000);
  } catch (error) {
    console.error('Error starting backup daemon:', error);
    res.status(500).json({ error: 'Failed to start backup daemon' });
  }
});

/**
 * POST /api/backup/stop
 * Stop backup daemon
 */
app.post('/api/backup/stop', async (req, res) => {
  try {
    await safeExec('pkill', ['-f', 'backup-daemon.sh']);
    res.json({ status: 'stopped', message: 'Backup daemon stopped' });
  } catch (error) {
    res.json({ status: 'not_running', message: 'Backup daemon was not running' });
  }
});

/**
 * POST /api/worker-restart/start
 * Start worker-restart daemon
 */
app.post('/api/worker-restart/start', async (req, res) => {
  try {
    const scriptPath = path.join(__dirname, '../../scripts/daemons/worker-restart-daemon.sh');

    // Check if already running
    try {
      const isRunning = await safeExec('pgrep', ['-f', 'worker-restart-daemon.sh']);
      if (isRunning.stdout.trim()) {
        return res.json({ status: 'already_running', message: 'Worker-restart daemon is already running' });
      }
    } catch (e) {
      // pgrep returns exit code 1 when no processes match - this is expected
    }

    // Start the daemon
    const { spawn } = require('child_process');
    spawn('bash', [scriptPath], {
      detached: true,
      stdio: 'ignore'
    }).unref();

    setTimeout(() => {
      res.json({ status: 'started', message: 'Worker-restart daemon started successfully' });
    }, 1000);
  } catch (error) {
    console.error('Error starting worker-restart daemon:', error);
    res.status(500).json({ error: 'Failed to start worker-restart daemon' });
  }
});

/**
 * POST /api/worker-restart/stop
 * Stop worker-restart daemon
 */
app.post('/api/worker-restart/stop', async (req, res) => {
  try {
    await safeExec('pkill', ['-f', 'worker-restart-daemon.sh']);
    res.json({ status: 'stopped', message: 'Worker-restart daemon stopped' });
  } catch (error) {
    res.json({ status: 'not_running', message: 'Worker-restart daemon was not running' });
  }
});

/**
 * POST /api/auto-fix/start
 * Start auto-fix daemon
 */
app.post('/api/auto-fix/start', async (req, res) => {
  try {
    const scriptPath = path.join(__dirname, '../../scripts/daemons/auto-fix-daemon.sh');

    // Check if already running
    try {
      const isRunning = await safeExec('pgrep', ['-f', 'auto-fix-daemon.sh']);
      if (isRunning.stdout.trim()) {
        return res.json({ status: 'already_running', message: 'Auto-fix daemon is already running' });
      }
    } catch (e) {
      // pgrep returns exit code 1 when no processes match - this is expected
    }

    // Start the daemon
    const { spawn } = require('child_process');
    spawn('bash', [scriptPath], {
      detached: true,
      stdio: 'ignore'
    }).unref();

    setTimeout(() => {
      res.json({ status: 'started', message: 'Auto-fix daemon started successfully' });
    }, 1000);
  } catch (error) {
    console.error('Error starting auto-fix daemon:', error);
    res.status(500).json({ error: 'Failed to start auto-fix daemon' });
  }
});

/**
 * POST /api/auto-fix/stop
 * Stop auto-fix daemon
 */
app.post('/api/auto-fix/stop', async (req, res) => {
  try {
    await safeExec('pkill', ['-f', 'auto-fix-daemon.sh']);
    res.json({ status: 'stopped', message: 'Auto-fix daemon stopped' });
  } catch (error) {
    res.json({ status: 'not_running', message: 'Auto-fix daemon was not running' });
  }
});

/**
 * POST /api/failure-pattern/start
 * Start failure-pattern daemon
 */
app.post('/api/failure-pattern/start', async (req, res) => {
  try {
    const scriptPath = path.join(__dirname, '../../scripts/daemons/failure-pattern-daemon.sh');

    // Check if already running
    try {
      const isRunning = await safeExec('pgrep', ['-f', 'failure-pattern-daemon.sh']);
      if (isRunning.stdout.trim()) {
        return res.json({ status: 'already_running', message: 'Failure-pattern daemon is already running' });
      }
    } catch (e) {
      // pgrep returns exit code 1 when no processes match - this is expected
    }

    // Start the daemon
    const { spawn } = require('child_process');
    spawn('bash', [scriptPath], {
      detached: true,
      stdio: 'ignore'
    }).unref();

    setTimeout(() => {
      res.json({ status: 'started', message: 'Failure-pattern daemon started successfully' });
    }, 1000);
  } catch (error) {
    console.error('Error starting failure-pattern daemon:', error);
    res.status(500).json({ error: 'Failed to start failure-pattern daemon' });
  }
});

/**
 * POST /api/failure-pattern/stop
 * Stop failure-pattern daemon
 */
app.post('/api/failure-pattern/stop', async (req, res) => {
  try {
    await safeExec('pkill', ['-f', 'failure-pattern-daemon.sh']);
    res.json({ status: 'stopped', message: 'Failure-pattern daemon stopped' });
  } catch (error) {
    res.json({ status: 'not_running', message: 'Failure-pattern daemon was not running' });
  }
});

/**
 * POST /api/moe-learning/start
 * Start MoE learning daemon
 */
app.post('/api/moe-learning/start', async (req, res) => {
  try {
    const scriptPath = path.join(__dirname, '../../scripts/daemons/moe-learning-daemon.sh');

    // Check if already running
    try {
      const isRunning = await safeExec('pgrep', ['-f', 'moe-learning-daemon.sh']);
      if (isRunning.stdout.trim()) {
        return res.json({ status: 'already_running', message: 'MoE learning daemon is already running' });
      }
    } catch (e) {
      // pgrep returns exit code 1 when no processes match - this is expected
    }

    // Start the daemon
    const { spawn } = require('child_process');
    spawn('bash', [scriptPath], {
      detached: true,
      stdio: 'ignore'
    }).unref();

    setTimeout(() => {
      res.json({ status: 'started', message: 'MoE learning daemon started successfully' });
    }, 1000);
  } catch (error) {
    console.error('Error starting MoE learning daemon:', error);
    res.status(500).json({ error: 'Failed to start MoE learning daemon' });
  }
});

/**
 * POST /api/moe-learning/stop
 * Stop MoE learning daemon
 */
app.post('/api/moe-learning/stop', async (req, res) => {
  try {
    await safeExec('pkill', ['-f', 'moe-learning-daemon.sh']);
    res.json({ status: 'stopped', message: 'MoE learning daemon stopped' });
  } catch (error) {
    res.json({ status: 'not_running', message: 'MoE learning daemon was not running' });
  }
});

/**
 * GET /api/pm-daemon/status
 * Get PM daemon status from pm-state.json
 */
app.get('/api/pm-daemon/status', async (req, res) => {
  try {
    const pmStatePath = path.join(__dirname, '../../coordination/pm-state.json');
    const pmState = await readJSON(pmStatePath);

    if (!pmState || !pmState.pm_daemon) {
      return res.json({
        status: 'stopped',
        pid: null,
        uptime_seconds: 0,
        loops_completed: 0,
        last_loop: null
      });
    }

    const pmDaemon = pmState.pm_daemon;
    const status = pmDaemon.pid ? 'running' : 'stopped';

    res.json({
      status,
      pid: pmDaemon.pid || null,
      uptime_seconds: pmDaemon.uptime_seconds || 0,
      loops_completed: pmDaemon.loops_completed || 0,
      last_loop: pmDaemon.last_loop || null,
      started_at: pmDaemon.started_at || null
    });
  } catch (error) {
    console.error('Error getting PM daemon status:', error);
    res.json({
      status: 'stopped',
      pid: null,
      uptime_seconds: 0,
      loops_completed: 0,
      last_loop: null
    });
  }
});

/**
 * GET /api/health-alerts
 * Get all health alerts from health-alerts.json
 */
app.get('/api/health-alerts', async (req, res) => {
  try {
    const healthAlertsPath = path.join(__dirname, '../../coordination/health-alerts.json');
    const healthAlertsData = await readJSON(healthAlertsPath);

    if (!healthAlertsData || !healthAlertsData.alerts) {
      return res.json({ alerts: [], sla_config: {} });
    }

    res.json({
      alerts: healthAlertsData.alerts || [],
      sla_config: healthAlertsData.sla_config || {}
    });
  } catch (error) {
    console.error('Error reading health alerts:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

/**
 * POST /api/health-alerts/:id/resolve
 * Mark a health alert as resolved
 */
app.post('/api/health-alerts/:id/resolve', async (req, res) => {
  try {
    const { id } = req.params;
    const { resolution_note } = req.body;

    const healthAlertsPath = path.join(__dirname, '../../coordination/health-alerts.json');
    const healthAlertsData = await readJSON(healthAlertsPath);

    if (!healthAlertsData || !healthAlertsData.alerts) {
      return res.status(404).json({ error: 'Health alerts file not found' });
    }

    const alertIndex = healthAlertsData.alerts.findIndex(a => a.id === id);
    if (alertIndex === -1) {
      return res.status(404).json({ error: 'Alert not found' });
    }

    // Update alert
    healthAlertsData.alerts[alertIndex].status = 'resolved';
    healthAlertsData.alerts[alertIndex].resolved_at = new Date().toISOString();

    if (!healthAlertsData.alerts[alertIndex].resolution_notes) {
      healthAlertsData.alerts[alertIndex].resolution_notes = [];
    }

    if (resolution_note) {
      healthAlertsData.alerts[alertIndex].resolution_notes.push(resolution_note);
    }

    // Write back to file
    await fs.writeFile(healthAlertsPath, JSON.stringify(healthAlertsData, null, 2), 'utf-8');

    // Emit system event
    const alert = healthAlertsData.alerts[alertIndex];
    emitSystemEvent('health_alert_resolved', {
      alert_id: alert.id,
      alert_type: alert.type,
      severity: alert.severity,
      message: `Health alert resolved: ${alert.message}`
    });

    res.json({
      success: true,
      alert: healthAlertsData.alerts[alertIndex],
      message: 'Alert marked as resolved'
    });
  } catch (error) {
    console.error('Error resolving alert:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

/**
 * POST /api/health-alerts/:id/restart-worker
 * Restart worker associated with an alert
 * Security: Input validation, path validation, safe command execution, rate limiting
 */
app.post('/api/health-alerts/:id/restart-worker',
  controlLimiter,
  workerRestartValidationRules,
  validate,
  async (req, res) => {
    try {
      const { id } = req.params;

      // Sanitize alert ID
      const safeAlertId = sanitizeAlertId(id);

      const healthAlertsPath = path.join(__dirname, '../../coordination/health-alerts.json');
      const healthAlertsData = await readJSON(healthAlertsPath);

      if (!healthAlertsData || !healthAlertsData.alerts) {
        return res.status(404).json({ error: 'Health alerts file not found' });
      }

      const alert = healthAlertsData.alerts.find(a => a.id === safeAlertId);
      if (!alert) {
        return res.status(404).json({ error: 'Alert not found' });
      }

      if (!alert.worker_id) {
        return res.status(400).json({ error: 'Alert does not have an associated worker' });
      }

      // Sanitize worker ID
      const workerId = sanitizeWorkerId(alert.worker_id);

      const workerSpecsDir = path.join(__dirname, '../../coordination/worker-specs');
      const stuckDir = path.join(workerSpecsDir, 'stuck');
      const failedDir = path.join(workerSpecsDir, 'failed');
      const activeDir = path.join(workerSpecsDir, 'active');

      // Find worker spec in stuck or failed directories
      let workerSpecPath = null;
      let sourceDir = null;

      // Use basename to prevent path traversal
      const safeWorkerFilename = path.basename(`${workerId}.json`);
      const stuckPath = path.join(stuckDir, safeWorkerFilename);
      const failedPath = path.join(failedDir, safeWorkerFilename);

      if (await fs.access(stuckPath).then(() => true).catch(() => false)) {
        workerSpecPath = stuckPath;
        sourceDir = 'stuck';
      } else if (await fs.access(failedPath).then(() => true).catch(() => false)) {
        workerSpecPath = failedPath;
        sourceDir = 'failed';
      } else {
        return res.status(404).json({ error: 'Worker spec not found in stuck/ or failed/ directories' });
      }

      // Read worker spec
      const workerSpec = await readJSON(workerSpecPath);
      if (!workerSpec) {
        return res.status(500).json({ error: 'Failed to read worker spec' });
      }

      // Reset worker spec status
      workerSpec.status = 'pending';
      workerSpec.execution = {
        ...workerSpec.execution,
        restarted_at: new Date().toISOString(),
        restarted_from: sourceDir,
        restart_reason: `Restarted from health alert ${safeAlertId}`
      };

      // Move to active directory with safe path
      const activePath = path.join(activeDir, safeWorkerFilename);
      await fs.writeFile(activePath, JSON.stringify(workerSpec, null, 2), 'utf-8');

      // Remove from stuck/failed directory
      await fs.unlink(workerSpecPath);

      // Add note to alert
      const alertIndex = healthAlertsData.alerts.findIndex(a => a.id === safeAlertId);
      if (!healthAlertsData.alerts[alertIndex].investigation_notes) {
        healthAlertsData.alerts[alertIndex].investigation_notes = [];
      }
      healthAlertsData.alerts[alertIndex].investigation_notes.push(
        `${new Date().toISOString()} - Worker ${workerId} restarted from ${sourceDir}/ directory`
      );

      await fs.writeFile(healthAlertsPath, JSON.stringify(healthAlertsData, null, 2), 'utf-8');

      // Emit system event
      emitSystemEvent('worker_restarted', {
        worker_id: workerId,
        alert_id: safeAlertId,
        alert_type: alert?.type || 'unknown',
        source_dir: sourceDir,
        message: `Worker ${workerId} restarted from health alert`
      });

      // Attempt to spawn the worker using safe execution
      // Note: Worker daemon will pick this up automatically, so spawning here is optional
      try {
        const spawnScript = path.join(__dirname, '../../agents/workers/autonomous-worker.sh');
        // Validate script path is within expected directory
        const baseDir = path.join(__dirname, '../..');
        const validatedScript = validatePath(spawnScript, baseDir);

        // Use safe execution with validated path
        safeExec('bash', [validatedScript, activePath], {
          cwd: baseDir,
          detached: true,
          stdio: 'ignore'
        }).catch(err => {
          console.warn('Worker spawn failed, daemon will retry:', err.message);
        });
      } catch (spawnError) {
        console.warn('Error spawning worker, daemon will retry:', spawnError.message);
        // Don't fail the request - worker spec is moved, spawn will be attempted by daemon
      }

      res.json({
        success: true,
        message: `Worker ${workerId} restarted from ${sourceDir}/ directory`,
        worker_id: workerId
      });
    } catch (error) {
      console.error('Error restarting worker:', error);
      const safeError = sanitizeError(error, process.env.NODE_ENV === 'development');
      res.status(500).json({ error: 'Failed to restart worker', ...safeError });
    }
  }
);

/**
 * POST /api/health-alerts/:id/note
 * Add investigation note to alert
 */
app.post('/api/health-alerts/:id/note', async (req, res) => {
  try {
    const { id } = req.params;
    const { note } = req.body;

    if (!note || !note.trim()) {
      return res.status(400).json({ error: 'Note is required' });
    }

    const healthAlertsPath = path.join(__dirname, '../../coordination/health-alerts.json');
    const healthAlertsData = await readJSON(healthAlertsPath);

    if (!healthAlertsData || !healthAlertsData.alerts) {
      return res.status(404).json({ error: 'Health alerts file not found' });
    }

    const alertIndex = healthAlertsData.alerts.findIndex(a => a.id === id);
    if (alertIndex === -1) {
      return res.status(404).json({ error: 'Alert not found' });
    }

    // Add note with timestamp
    if (!healthAlertsData.alerts[alertIndex].investigation_notes) {
      healthAlertsData.alerts[alertIndex].investigation_notes = [];
    }

    const timestampedNote = `${new Date().toISOString()} - ${note}`;
    healthAlertsData.alerts[alertIndex].investigation_notes.push(timestampedNote);

    // Write back to file
    await fs.writeFile(healthAlertsPath, JSON.stringify(healthAlertsData, null, 2), 'utf-8');

    // Emit system event
    const alert = healthAlertsData.alerts[alertIndex];
    emitSystemEvent('health_alert_note_added', {
      alert_id: alert.id,
      alert_type: alert.type,
      severity: alert.severity,
      note: note,
      message: `Note added to ${alert.type} alert`
    });

    res.json({
      success: true,
      alert: healthAlertsData.alerts[alertIndex],
      message: 'Note added successfully'
    });
  } catch (error) {
    console.error('Error adding note to alert:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

/**
 * DELETE /api/health-alerts/:id
 * Delete a health alert
 */
app.delete('/api/health-alerts/:id', async (req, res) => {
  try {
    const { id } = req.params;

    const healthAlertsPath = path.join(__dirname, '../../coordination/health-alerts.json');
    const healthAlertsData = await readJSON(healthAlertsPath);

    if (!healthAlertsData || !healthAlertsData.alerts) {
      return res.status(404).json({ error: 'Health alerts file not found' });
    }

    const alertIndex = healthAlertsData.alerts.findIndex(a => a.id === id);
    if (alertIndex === -1) {
      return res.status(404).json({ error: 'Alert not found' });
    }

    // Remove alert
    const removedAlert = healthAlertsData.alerts.splice(alertIndex, 1)[0];

    // Write back to file
    await fs.writeFile(healthAlertsPath, JSON.stringify(healthAlertsData, null, 2), 'utf-8');

    // Emit system event
    emitSystemEvent('health_alert_deleted', {
      alert_id: removedAlert.id,
      alert_type: removedAlert.type,
      severity: removedAlert.severity,
      message: `Health alert deleted: ${removedAlert.message}`
    });

    res.json({
      success: true,
      message: 'Alert deleted successfully',
      deleted_alert: removedAlert
    });
  } catch (error) {
    console.error('Error deleting alert:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

/**
 * POST /api/health-alerts/:id/repair
 * Create automated repair task for health alert via commit-relay
 */
app.post('/api/health-alerts/:id/repair', async (req, res) => {
  const { id } = req.params;
  const { execSync } = require('child_process');

  try {
    const healthAlertsPath = path.join(COMMIT_RELAY_HOME, 'coordination', 'health-alerts.json');
    const healthAlertsContent = await fs.readFile(healthAlertsPath, 'utf-8');
    const healthAlertsData = JSON.parse(healthAlertsContent);

    if (!healthAlertsData || !healthAlertsData.alerts) {
      return res.status(404).json({ error: 'Health alerts file not found' });
    }

    const alert = healthAlertsData.alerts.find(a => a.id === id);
    if (!alert) {
      return res.status(404).json({ error: 'Alert not found' });
    }

    // Create repair task
    const taskId = `task-repair-${Date.now()}`;
    const taskTitle = `REPAIR: ${alert.type.replace(/_/g, ' ')} - ${alert.message}`;

    const repairTask = {
      id: taskId,
      title: taskTitle,
      type: 'development',
      priority: alert.severity === 'critical' ? 'critical' : 'high',
      status: 'pending',
      created_at: new Date().toISOString(),
      created_by: 'health-alert-repair-system',
      context: {
        repository: 'ry-ops/commit-relay',
        branch: 'main',
        description: `Automated repair task from health alert: ${alert.message}`,
        alert: {
          id: alert.id,
          type: alert.type,
          severity: alert.severity,
          message: alert.message,
          created_at: alert.created_at,
          worker_id: alert.worker_id
        },
        repair_actions: [
          `Investigate ${alert.type} issue`,
          'Diagnose root cause',
          'Implement fix or workaround',
          'Verify resolution',
          'Update health monitoring if needed',
          'Document findings and solution'
        ],
        requirements: []
      }
    };

    // Emit task created event
    try {
      const eventScript = path.join(COMMIT_RELAY_HOME, 'scripts', 'emit-event.sh');
      execSync(`${eventScript} task_created ${taskId} "Repair task created from health alert ${alert.id}"`, {
        cwd: COMMIT_RELAY_HOME,
        stdio: 'pipe'
      });
    } catch (emitError) {
      console.warn('Failed to emit task_created event:', emitError.message);
    }

    // Route task through MoE coordinator
    try {
      const moeRouter = path.join(COMMIT_RELAY_HOME, 'coordination', 'masters', 'coordinator', 'lib', 'moe-router.sh');
      const taskDesc = `${taskTitle}. ${alert.message}`;
      const routeCmd = `TASK_DESC="${taskDesc}" ${moeRouter} "${taskId}" "${taskDesc}"`;
      const routeOutput = execSync(routeCmd, {
        cwd: COMMIT_RELAY_HOME,
        stdio: 'pipe',
        encoding: 'utf-8'
      });

      console.log(`Task ${taskId} routed through MoE:`, routeOutput);
    } catch (routeError) {
      console.error('Failed to route task through MoE:', routeError.message);
      // Continue anyway - task will be picked up by worker daemon
    }

    // Update alert status to indicate repair initiated
    alert.status = 'repair_initiated';
    if (!alert.investigation_notes) {
      alert.investigation_notes = [];
    }
    alert.investigation_notes.push({
      timestamp: new Date().toISOString(),
      note: `Automated repair task created: ${taskId}`,
      task_id: taskId
    });

    await fs.writeFile(healthAlertsPath, JSON.stringify(healthAlertsData, null, 2), 'utf-8');

    // Emit system event
    emitSystemEvent('health_alert_repair_initiated', {
      alert_id: alert.id,
      alert_type: alert.type,
      severity: alert.severity,
      task_id: taskId,
      message: `Automated repair initiated for: ${alert.message}`
    });

    res.json({
      success: true,
      message: 'Repair task created and routed to commit-relay',
      task_id: taskId,
      alert_id: alert.id,
      task: repairTask
    });
  } catch (error) {
    console.error('Error creating repair task:', error);
    res.status(500).json({
      error: 'Failed to create repair task',
      details: error.message
    });
  }
});

/**
 * Parse elapsed time string (format: [[DD-]HH:]MM:SS) to seconds
 */
function parseElapsedTime(timeStr) {
  const parts = timeStr.trim().split(/[-:]/);
  let seconds = 0;

  if (parts.length === 4) {
    // DD-HH:MM:SS
    seconds = parseInt(parts[0]) * 86400 + parseInt(parts[1]) * 3600 +
              parseInt(parts[2]) * 60 + parseInt(parts[3]);
  } else if (parts.length === 3) {
    // HH:MM:SS
    seconds = parseInt(parts[0]) * 3600 + parseInt(parts[1]) * 60 + parseInt(parts[2]);
  } else if (parts.length === 2) {
    // MM:SS
    seconds = parseInt(parts[0]) * 60 + parseInt(parts[1]);
  }

  return seconds;
}

/**
 * Helper function to get last commit info from git
 */
function getLastCommitInfo() {
  const { execSync } = require('child_process');
  try {
    const output = execSync('git log -1 --format="%s|%ar"', {
      cwd: path.join(__dirname, '../../'),
      encoding: 'utf-8'
    }).toString().trim();
    const [message, timeAgo] = output.split('|');
    return { message: message || 'No commits', timeAgo: timeAgo || 'Never' };
  } catch (e) {
    return { message: 'No commits', timeAgo: 'Never' };
  }
}

/**
 * Helper function to get last repo sync time
 */
function getLastRepoSync() {
  const fsSync = require('fs');
  const fetchHeadPath = path.join(__dirname, '../../.git/FETCH_HEAD');

  if (fsSync.existsSync(fetchHeadPath)) {
    const stats = fsSync.statSync(fetchHeadPath);
    const now = Date.now();
    const diff = now - stats.mtimeMs;

    // Convert to human readable
    const minutes = Math.floor(diff / 60000);
    const hours = Math.floor(minutes / 60);
    const days = Math.floor(hours / 24);

    if (days > 0) return `${days} day${days > 1 ? 's' : ''} ago`;
    if (hours > 0) return `${hours} hour${hours > 1 ? 's' : ''} ago`;
    if (minutes > 0) return `${minutes} minute${minutes > 1 ? 's' : ''} ago`;
    return 'Just now';
  }
  return 'Never';
}

/**
 * GET /api/git-info
 * Get git information (last commit and last repo sync)
 */
app.get('/api/git-info', async (req, res) => {
  try {
    const lastCommit = getLastCommitInfo();
    const lastSync = getLastRepoSync();
    res.json({ lastCommit, lastSync });
  } catch (error) {
    console.error('Error getting git info:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

/**
 * GET /api/server/status
 * Get API server status
 */
app.get('/api/server/status', (req, res) => {
  res.json({
    status: 'running',
    pid: process.pid,
    port: PORT,
    uptime: process.uptime()
  });
});

/**
 * POST /api/server/control
 * Control API server (restart only - can't stop itself)
 */
app.post('/api/server/control', async (req, res) => {
  const { action } = req.body;

  if (action === 'restart') {
    try {
      const { spawn } = require('child_process');
      const serverScript = path.join(__dirname, 'index.js');

      // Send success response first
      res.json({
        success: true,
        message: 'API server restarting...',
        note: 'Please refresh the page in 2-3 seconds'
      });

      // Spawn new server process
      setTimeout(() => {
        spawn('node', [serverScript], {
          detached: true,
          stdio: 'ignore',
          cwd: path.dirname(serverScript)
        }).unref();

        // Exit current process after allowing response to be sent
        setTimeout(() => {
          process.exit(0);
        }, 500);
      }, 1000);
    } catch (error) {
      console.error('Error restarting API server:', error);
      res.status(500).json({
        success: false,
        message: 'Failed to restart server',
        error: error.message
      });
    }
  } else {
    res.status(400).json({
      success: false,
      message: 'Invalid action. Only "restart" is supported.'
    });
  }
});

/**
 * GET /api/event-log/info
 * Get information about the event log file
 */
app.get('/api/event-log/info', (req, res) => {
  try {
    const fsSync = require('fs');
    const eventLogPath = FILES.systemEvents;

    if (!fsSync.existsSync(eventLogPath)) {
      return res.json({
        created_date: 'N/A',
        event_count: 0,
        file_size: '0 B'
      });
    }

    const stats = fsSync.statSync(eventLogPath);
    const content = fsSync.readFileSync(eventLogPath, 'utf-8');
    const lines = content.trim().split('\n').filter(line => line);
    const eventCount = lines.length;

    // Format file size
    const formatBytes = (bytes) => {
      if (bytes === 0) return '0 B';
      const k = 1024;
      const sizes = ['B', 'KB', 'MB', 'GB'];
      const i = Math.floor(Math.log(bytes) / Math.log(k));
      return Math.round(bytes / Math.pow(k, i) * 100) / 100 + ' ' + sizes[i];
    };

    res.json({
      created_date: stats.birthtime.toISOString().split('T')[0], // YYYY-MM-DD format
      event_count: eventCount,
      file_size: formatBytes(stats.size)
    });
  } catch (error) {
    console.error('Error getting event log info:', error);
    res.status(500).json({ error: 'Failed to get event log information' });
  }
});

/**
 * POST /api/event-log/purge
 * Purge event log by archiving current events and creating new empty log
 */
app.post('/api/event-log/purge', (req, res) => {
  try {
    const fsSync = require('fs');
    const eventLogPath = FILES.systemEvents;
    const archiveDir = path.join(COMMIT_RELAY_HOME, 'coordination', 'system-events-archive');

    // Create archive directory if it doesn't exist
    if (!fsSync.existsSync(archiveDir)) {
      fsSync.mkdirSync(archiveDir, { recursive: true });
    }

    // Count events before purging
    let eventCount = 0;
    if (fsSync.existsSync(eventLogPath)) {
      const content = fsSync.readFileSync(eventLogPath, 'utf-8');
      const lines = content.trim().split('\n').filter(line => line);
      eventCount = lines.length;
    }

    // Create archive file with timestamp
    const timestamp = new Date().toISOString().replace(/[:.]/g, '-').split('T')[0];
    const archiveFile = path.join(archiveDir, `system-events-${timestamp}.jsonl`);

    // Copy current log to archive
    if (fsSync.existsSync(eventLogPath) && eventCount > 0) {
      fsSync.copyFileSync(eventLogPath, archiveFile);
    }

    // Create new empty event log
    fsSync.writeFileSync(eventLogPath, '', 'utf-8');

    res.json({
      success: true,
      message: 'Event log purged successfully',
      archived_count: eventCount,
      archive_file: archiveFile
    });
  } catch (error) {
    console.error('Error purging event log:', error);
    res.status(500).json({
      success: false,
      message: 'Failed to purge event log',
      error: error.message
    });
  }
});

/**
 * POST /api/moe/clear-routing-decisions
 * Clear routing decisions by backing up and resetting the file
 */
app.post('/api/moe/clear-routing-decisions', (req, res) => {
  try {
    const fsSync = require('fs');
    const routingDecisionsPath = path.join(COMMIT_RELAY_HOME, 'coordination', 'masters', 'coordinator', 'knowledge-base', 'routing-decisions.jsonl');
    const backupDir = path.join(COMMIT_RELAY_HOME, 'coordination', 'masters', 'coordinator', 'knowledge-base', 'backups');

    // Create backup directory if it doesn't exist
    if (!fsSync.existsSync(backupDir)) {
      fsSync.mkdirSync(backupDir, { recursive: true });
    }

    // Count decisions before clearing
    let decisionCount = 0;
    if (fsSync.existsSync(routingDecisionsPath)) {
      const content = fsSync.readFileSync(routingDecisionsPath, 'utf-8');
      const lines = content.trim().split('\n').filter(line => line);
      decisionCount = lines.length;
    }

    // Create backup file with timestamp
    const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
    const backupFile = path.join(backupDir, `routing-decisions-${timestamp}.jsonl`);

    // Copy current file to backup
    if (fsSync.existsSync(routingDecisionsPath) && decisionCount > 0) {
      fsSync.copyFileSync(routingDecisionsPath, backupFile);
    }

    // Create new empty routing decisions file
    fsSync.writeFileSync(routingDecisionsPath, '', 'utf-8');

    // Also reset moe-metrics.json if it exists (but not stress-test metrics)
    const moeMetricsPath = path.join(COMMIT_RELAY_HOME, 'coordination', 'masters', 'coordinator', 'knowledge-base', 'moe-metrics.json');
    if (fsSync.existsSync(moeMetricsPath)) {
      const metricsBackup = path.join(backupDir, `moe-metrics-${timestamp}.json`);
      fsSync.copyFileSync(moeMetricsPath, metricsBackup);
      // Reset to empty metrics object
      const emptyMetrics = {
        total_decisions: 0,
        avg_confidence: 0,
        decisions_by_master: {},
        last_reset: new Date().toISOString()
      };
      fsSync.writeFileSync(moeMetricsPath, JSON.stringify(emptyMetrics, null, 2), 'utf-8');
    }

    res.json({
      success: true,
      message: 'Routing decisions cleared successfully',
      cleared_count: decisionCount,
      backup_file: backupFile
    });
  } catch (error) {
    console.error('Error clearing routing decisions:', error);
    res.status(500).json({
      success: false,
      message: 'Failed to clear routing decisions',
      error: error.message
    });
  }
});

/**
 * GET /api/terminal-settings
 * Get current terminal window settings
 */
app.get('/api/terminal-settings', async (req, res) => {
  try {
    const settingsPath = path.join(COMMIT_RELAY_HOME, 'coordination', 'config', 'terminal-settings.json');

    // Default settings if file doesn't exist
    const defaultSettings = {
      terminal_windows_enabled: true,
      headless_mode: false,
      auto_close_duration_minutes: 0,
      last_updated: new Date().toISOString(),
      updated_by: "system"
    };

    if (!fsSync.existsSync(settingsPath)) {
      return res.json(defaultSettings);
    }

    const settings = JSON.parse(await fs.readFile(settingsPath, 'utf-8'));
    res.json(settings);
  } catch (error) {
    console.error('Error reading terminal settings:', error);
    res.status(500).json({ error: 'Failed to read terminal settings' });
  }
});

/**
 * POST /api/terminal-settings
 * Update terminal window settings
 * Body: { terminal_windows_enabled, headless_mode, auto_close_duration_minutes }
 */
app.post('/api/terminal-settings', async (req, res) => {
  try {
    const settingsPath = path.join(COMMIT_RELAY_HOME, 'coordination', 'config', 'terminal-settings.json');
    const { terminal_windows_enabled, headless_mode, auto_close_duration_minutes } = req.body;

    // Validation
    if (typeof terminal_windows_enabled !== 'boolean' && terminal_windows_enabled !== undefined) {
      return res.status(400).json({ error: 'terminal_windows_enabled must be boolean' });
    }
    if (typeof headless_mode !== 'boolean' && headless_mode !== undefined) {
      return res.status(400).json({ error: 'headless_mode must be boolean' });
    }
    if (auto_close_duration_minutes !== undefined &&
        (typeof auto_close_duration_minutes !== 'number' || auto_close_duration_minutes < 0)) {
      return res.status(400).json({ error: 'auto_close_duration_minutes must be non-negative number' });
    }

    // Read current settings
    let settings = {
      terminal_windows_enabled: true,
      headless_mode: false,
      auto_close_duration_minutes: 0
    };

    if (fsSync.existsSync(settingsPath)) {
      settings = JSON.parse(await fs.readFile(settingsPath, 'utf-8'));
    }

    // Update with new values
    if (terminal_windows_enabled !== undefined) settings.terminal_windows_enabled = terminal_windows_enabled;
    if (headless_mode !== undefined) settings.headless_mode = headless_mode;
    if (auto_close_duration_minutes !== undefined) settings.auto_close_duration_minutes = auto_close_duration_minutes;

    // Add metadata
    settings.last_updated = new Date().toISOString();
    settings.updated_by = req.headers['x-user'] || 'api-server';

    // Write updated settings
    await fs.writeFile(settingsPath, JSON.stringify(settings, null, 2), 'utf-8');

    res.json({
      success: true,
      settings: settings
    });
  } catch (error) {
    console.error('Error updating terminal settings:', error);
    res.status(500).json({ error: 'Failed to update terminal settings' });
  }
});

/**
 * Start/Stop Worker Daemon
 * Security: Input validation, safe command execution, rate limiting
 */
app.post('/api/daemon/control',
  controlLimiter,
  daemonControlValidationRules,
  validate,
  async (req, res) => {
    const { action } = req.body;

    try {
      const scriptPath = path.join(__dirname, '../../scripts/worker-daemon.sh');
      const PID_FILE = '/tmp/commit-relay-worker-daemon.pid';

      if (action === 'start') {
        // Check if already running using safe PID validation
        if (fsSync.existsSync(PID_FILE)) {
          try {
            const pidContent = fsSync.readFileSync(PID_FILE, 'utf-8').trim();
            const pid = validatePid(pidContent);

            if (isProcessRunning(pid)) {
              return res.json({
                success: false,
                message: 'Worker daemon is already running',
                pid
              });
            }

            // PID file exists but process is dead, clean it up
            fsSync.unlinkSync(PID_FILE);
          } catch (err) {
            // Invalid PID file, clean it up
            fsSync.unlinkSync(PID_FILE);
          }
        }

        // Start the daemon using safe execution
        await safeStartScript(scriptPath, [], path.join(__dirname, '../..'));

        // Give it a moment to start
        await new Promise(resolve => setTimeout(resolve, 1000));

        // Read the new PID
        if (fsSync.existsSync(PID_FILE)) {
          try {
            const pidContent = fsSync.readFileSync(PID_FILE, 'utf-8').trim();
            const pid = validatePid(pidContent);
            res.json({ success: true, message: 'Worker daemon started', pid });
          } catch (err) {
            res.json({ success: false, message: 'Worker daemon may have failed to start' });
          }
        } else {
          res.json({ success: false, message: 'Worker daemon may have failed to start' });
        }
      } else if (action === 'stop') {
        // Stop the daemon using safe script execution
        await safeExec('bash', [scriptPath, 'stop'], { cwd: path.join(__dirname, '../..') });
        res.json({ success: true, message: 'Worker daemon stopped' });
      } else if (action === 'restart') {
        // Restart using safe script execution
        await safeExec('bash', [scriptPath, 'restart'], { cwd: path.join(__dirname, '../..') });
        res.json({ success: true, message: 'Worker daemon restarted' });
      }
    } catch (error) {
      console.error('Error controlling worker daemon:', error);
      const safeError = sanitizeError(error, process.env.NODE_ENV === 'development');
      res.status(500).json({ success: false, ...safeError });
    }
  }
);

/**
 * Start/Stop PM Daemon
 * Security: Input validation, safe command execution, rate limiting
 */
app.post('/api/pm-daemon/control',
  controlLimiter,
  daemonControlValidationRules,
  validate,
  async (req, res) => {
    const { action } = req.body;

    try {
      const scriptPath = path.join(__dirname, '../../scripts/pm-daemon.sh');
      const PID_FILE = '/tmp/commit-relay-pm-daemon.pid';

      if (action === 'start') {
        // Check if already running using safe PID validation
        if (fsSync.existsSync(PID_FILE)) {
          try {
            const pidContent = fsSync.readFileSync(PID_FILE, 'utf-8').trim();
            const pid = validatePid(pidContent);

            if (isProcessRunning(pid)) {
              return res.json({
                success: false,
                message: 'PM daemon is already running',
                pid
              });
            }

            // PID file exists but process is dead, clean it up
            fsSync.unlinkSync(PID_FILE);
          } catch (err) {
            // Invalid PID file, clean it up
            fsSync.unlinkSync(PID_FILE);
          }
        }

        // Start the daemon using safe execution
        await safeStartScript(scriptPath, [], path.join(__dirname, '../..'));

        // Give it a moment to start
        await new Promise(resolve => setTimeout(resolve, 1000));

        // Read the new PID
        if (fsSync.existsSync(PID_FILE)) {
          try {
            const pidContent = fsSync.readFileSync(PID_FILE, 'utf-8').trim();
            const pid = validatePid(pidContent);
            res.json({ success: true, message: 'PM daemon started', pid });
          } catch (err) {
            res.json({ success: false, message: 'PM daemon may have failed to start' });
          }
        } else {
          res.json({ success: false, message: 'PM daemon may have failed to start' });
        }
      } else if (action === 'stop') {
        // Stop the daemon using safe PID handling
        if (fsSync.existsSync(PID_FILE)) {
          try {
            const pidContent = fsSync.readFileSync(PID_FILE, 'utf-8').trim();
            const pid = validatePid(pidContent);

            if (safeKillProcess(pid)) {
              fsSync.unlinkSync(PID_FILE);
              res.json({ success: true, message: 'PM daemon stopped' });
            } else {
              res.json({ success: false, message: 'Failed to stop PM daemon' });
            }
          } catch (err) {
            res.json({ success: false, message: 'Failed to stop PM daemon: Invalid PID' });
          }
        } else {
          res.json({ success: false, message: 'PM daemon is not running' });
        }
      } else if (action === 'restart') {
        // Restart using safe script execution
        await safeExec('bash', [scriptPath, 'restart'], { cwd: path.join(__dirname, '../..') });
        res.json({ success: true, message: 'PM daemon restarted' });
      }
    } catch (error) {
      console.error('Error controlling PM daemon:', error);
      const safeError = sanitizeError(error, process.env.NODE_ENV === 'development');
      res.status(500).json({ success: false, ...safeError });
    }
  }
);

/**
 * GET /api/health-daemon/status
 * Get health monitor daemon status
 */
app.get('/api/health-daemon/status', async (req, res) => {
  const { execSync } = require('child_process');
  const fsSync = require('fs');
  const PID_FILE = '/tmp/commit-relay-health-monitor.pid';

  try {
    if (!fsSync.existsSync(PID_FILE)) {
      return res.json({ status: 'stopped', pid: null });
    }

    const pid = parseInt(fsSync.readFileSync(PID_FILE, 'utf-8').trim());

    try {
      execSync(`ps -p ${pid}`, { stdio: 'pipe' });

      // Get uptime
      const psOutput = execSync(`ps -o etime= -p ${pid}`).toString().trim();
      const uptime = parseElapsedTime(psOutput);

      res.json({ status: 'running', pid, uptime_seconds: uptime });
    } catch (e) {
      // Process not running, clean up stale PID
      fsSync.unlinkSync(PID_FILE);
      res.json({ status: 'stopped', pid: null });
    }
  } catch (error) {
    console.error('Error getting health daemon status:', error);
    res.json({ status: 'stopped', pid: null });
  }
});

/**
 * POST /api/health-daemon/control
 * Start/Stop Health Monitor Daemon
 */
app.post('/api/health-daemon/control', async (req, res) => {
  const { execSync } = require('child_process');
  const { action } = req.body;

  try {
    const scriptPath = path.join(__dirname, '../../scripts/health-monitor-daemon.sh');
    const PID_FILE = '/tmp/commit-relay-health-monitor.pid';
    const fsSync = require('fs');

    if (action === 'start') {
      if (fsSync.existsSync(PID_FILE)) {
        const pid = parseInt(fsSync.readFileSync(PID_FILE, 'utf-8').trim());
        try {
          execSync(`ps -p ${pid}`, { stdio: 'pipe' });
          return res.json({ success: false, message: 'Health monitor daemon is already running', pid });
        } catch (e) {
          fsSync.unlinkSync(PID_FILE);
        }
      }

      execSync(`bash ${scriptPath} > /tmp/health-monitor-start.log 2>&1 &`);
      await new Promise(resolve => setTimeout(resolve, 1000));

      if (fsSync.existsSync(PID_FILE)) {
        const pid = parseInt(fsSync.readFileSync(PID_FILE, 'utf-8').trim());
        res.json({ success: true, message: 'Health monitor daemon started', pid });
      } else {
        res.json({ success: false, message: 'Health monitor daemon may have failed to start' });
      }
    } else if (action === 'stop') {
      if (fsSync.existsSync(PID_FILE)) {
        const pid = parseInt(fsSync.readFileSync(PID_FILE, 'utf-8').trim());
        try {
          execSync(`kill ${pid}`, { stdio: 'pipe' });
          fsSync.unlinkSync(PID_FILE);
          res.json({ success: true, message: 'Health monitor daemon stopped' });
        } catch (e) {
          res.json({ success: false, message: 'Failed to stop health monitor daemon' });
        }
      } else {
        res.json({ success: false, message: 'Health monitor daemon is not running' });
      }
    } else {
      res.status(400).json({ success: false, message: 'Invalid action. Use "start" or "stop"' });
    }
  } catch (error) {
    console.error('Error controlling health monitor daemon:', error);
    res.status(500).json({ success: false, message: error.message });
  }
});

/**
 * GET /api/metrics-daemon/status
 * Get metrics snapshot daemon status
 */
app.get('/api/metrics-daemon/status', async (req, res) => {
  const { execSync } = require('child_process');
  const fsSync = require('fs');
  const PID_FILE = '/tmp/commit-relay-metrics-snapshot.pid';

  try {
    if (!fsSync.existsSync(PID_FILE)) {
      return res.json({ status: 'stopped', pid: null });
    }

    const pid = parseInt(fsSync.readFileSync(PID_FILE, 'utf-8').trim());

    try {
      execSync(`ps -p ${pid}`, { stdio: 'pipe' });

      // Get uptime
      const psOutput = execSync(`ps -o etime= -p ${pid}`).toString().trim();
      const uptime = parseElapsedTime(psOutput);

      res.json({ status: 'running', pid, uptime_seconds: uptime });
    } catch (e) {
      // Process not running, clean up stale PID
      fsSync.unlinkSync(PID_FILE);
      res.json({ status: 'stopped', pid: null });
    }
  } catch (error) {
    console.error('Error getting metrics daemon status:', error);
    res.json({ status: 'stopped', pid: null });
  }
});

/**
 * POST /api/metrics-daemon/control
 * Start/Stop Metrics Snapshot Daemon
 */
app.post('/api/metrics-daemon/control', async (req, res) => {
  const { execSync } = require('child_process');
  const { action } = req.body;

  try {
    const scriptPath = path.join(__dirname, '../../scripts/metrics-snapshot-daemon.sh');
    const PID_FILE = '/tmp/commit-relay-metrics-snapshot.pid';
    const fsSync = require('fs');

    if (action === 'start') {
      if (fsSync.existsSync(PID_FILE)) {
        const pid = parseInt(fsSync.readFileSync(PID_FILE, 'utf-8').trim());
        try {
          execSync(`ps -p ${pid}`, { stdio: 'pipe' });
          return res.json({ success: false, message: 'Metrics snapshot daemon is already running', pid });
        } catch (e) {
          fsSync.unlinkSync(PID_FILE);
        }
      }

      execSync(`bash ${scriptPath} > /tmp/metrics-snapshot-start.log 2>&1 &`);
      await new Promise(resolve => setTimeout(resolve, 1000));

      if (fsSync.existsSync(PID_FILE)) {
        const pid = parseInt(fsSync.readFileSync(PID_FILE, 'utf-8').trim());
        res.json({ success: true, message: 'Metrics snapshot daemon started', pid });
      } else {
        res.json({ success: false, message: 'Metrics snapshot daemon may have failed to start' });
      }
    } else if (action === 'stop') {
      if (fsSync.existsSync(PID_FILE)) {
        const pid = parseInt(fsSync.readFileSync(PID_FILE, 'utf-8').trim());
        try {
          execSync(`kill ${pid}`, { stdio: 'pipe' });
          fsSync.unlinkSync(PID_FILE);
          res.json({ success: true, message: 'Metrics snapshot daemon stopped' });
        } catch (e) {
          res.json({ success: false, message: 'Failed to stop metrics snapshot daemon' });
        }
      } else {
        res.json({ success: false, message: 'Metrics snapshot daemon is not running' });
      }
    } else {
      res.status(400).json({ success: false, message: 'Invalid action. Use "start" or "stop"' });
    }
  } catch (error) {
    console.error('Error controlling metrics snapshot daemon:', error);
    res.status(500).json({ success: false, message: error.message });
  }
});

/**
 * POST /api/coordinator-daemon/control
 * Control the coordinator daemon (start/stop)
 */
app.post('/api/coordinator-daemon/control', async (req, res) => {
  const { execSync, spawn } = require('child_process');
  const { action } = req.body;

  try {
    const scriptPath = path.join(__dirname, '../../scripts/coordinator-daemon.sh');
    const PID_FILE = '/tmp/commit-relay-coordinator.pid';
    const fsSync = require('fs');

    if (action === 'start') {
      if (fsSync.existsSync(PID_FILE)) {
        const pid = parseInt(fsSync.readFileSync(PID_FILE, 'utf-8').trim());
        try {
          execSync(`ps -p ${pid}`, { stdio: 'pipe' });
          return res.json({ success: false, message: 'Coordinator daemon is already running', pid });
        } catch (e) {
          fsSync.unlinkSync(PID_FILE);
        }
      }

      // Use spawn to start daemon in background
      const logFile = fsSync.openSync('/tmp/coordinator-start.log', 'w');
      const daemon = spawn('bash', [scriptPath], {
        detached: true,
        stdio: ['ignore', logFile, logFile]
      });
      daemon.unref();

      await new Promise(resolve => setTimeout(resolve, 1000));

      if (fsSync.existsSync(PID_FILE)) {
        const pid = parseInt(fsSync.readFileSync(PID_FILE, 'utf-8').trim());
        res.json({ success: true, message: 'Coordinator daemon started', pid });
      } else {
        res.json({ success: false, message: 'Coordinator daemon may have failed to start' });
      }
    } else if (action === 'stop') {
      if (fsSync.existsSync(PID_FILE)) {
        const pid = parseInt(fsSync.readFileSync(PID_FILE, 'utf-8').trim());
        try {
          execSync(`kill ${pid}`, { stdio: 'pipe' });
          fsSync.unlinkSync(PID_FILE);
          res.json({ success: true, message: 'Coordinator daemon stopped' });
        } catch (e) {
          res.json({ success: false, message: 'Failed to stop coordinator daemon' });
        }
      } else {
        res.json({ success: false, message: 'Coordinator daemon is not running' });
      }
    } else {
      res.status(400).json({ success: false, message: 'Invalid action. Use "start" or "stop"' });
    }
  } catch (error) {
    console.error('Error controlling coordinator daemon:', error);
    res.status(500).json({ success: false, message: error.message });
  }
});

/**
 * GET /api/coordinator-daemon/status
 * Get coordinator daemon status
 */
app.get('/api/coordinator-daemon/status', (req, res) => {
  const { execSync } = require('child_process');
  const fsSync = require('fs');
  const PID_FILE = '/tmp/commit-relay-coordinator.pid';
  const STATE_FILE = path.join(COMMIT_RELAY_HOME, 'coordination', 'orchestrator', 'state', 'current.json');

  try {
    if (fsSync.existsSync(PID_FILE)) {
      const pid = parseInt(fsSync.readFileSync(PID_FILE, 'utf-8').trim());

      try {
        execSync(`ps -p ${pid}`, { stdio: 'pipe' });

        let uptimeSeconds = 0;
        if (fsSync.existsSync(STATE_FILE)) {
          try {
            const state = JSON.parse(fsSync.readFileSync(STATE_FILE, 'utf-8'));
            if (state.started_at) {
              uptimeSeconds = Math.floor((Date.now() - new Date(state.started_at).getTime()) / 1000);
            }
          } catch (e) {
            console.error('Error reading coordinator state:', e);
          }
        }

        res.json({
          status: 'running',
          pid: pid,
          uptime_seconds: uptimeSeconds
        });
      } catch (e) {
        fsSync.unlinkSync(PID_FILE);
        res.json({ status: 'stopped', pid: null });
      }
    } else {
      res.json({ status: 'stopped', pid: null });
    }
  } catch (error) {
    console.error('Error checking coordinator daemon status:', error);
    res.json({ status: 'stopped', pid: null });
  }
});

/**
 * POST /api/integration-validator/control
 * Control the integration validator (start/stop)
 */
app.post('/api/integration-validator/control', async (req, res) => {
  const { execSync, spawn } = require('child_process');
  const { action } = req.body;

  try {
    const scriptPath = path.join(__dirname, '../../scripts/integration-validator-daemon.sh');
    const PID_FILE = '/tmp/commit-relay-integration-validator.pid';
    const fsSync = require('fs');

    if (action === 'start') {
      if (fsSync.existsSync(PID_FILE)) {
        const pid = parseInt(fsSync.readFileSync(PID_FILE, 'utf-8').trim());
        try {
          execSync(`ps -p ${pid}`, { stdio: 'pipe' });
          return res.json({ success: false, message: 'Integration validator is already running', pid });
        } catch (e) {
          fsSync.unlinkSync(PID_FILE);
        }
      }

      // Use spawn to start daemon in background
      const logFile = fsSync.openSync('/tmp/integration-validator-start.log', 'w');
      const daemon = spawn('bash', [scriptPath], {
        detached: true,
        stdio: ['ignore', logFile, logFile]
      });
      daemon.unref();

      await new Promise(resolve => setTimeout(resolve, 1000));

      if (fsSync.existsSync(PID_FILE)) {
        const pid = parseInt(fsSync.readFileSync(PID_FILE, 'utf-8').trim());
        res.json({ success: true, message: 'Integration validator started', pid });
      } else {
        res.json({ success: false, message: 'Integration validator may have failed to start' });
      }
    } else if (action === 'stop') {
      if (fsSync.existsSync(PID_FILE)) {
        const pid = parseInt(fsSync.readFileSync(PID_FILE, 'utf-8').trim());
        try {
          execSync(`kill ${pid}`, { stdio: 'pipe' });
          fsSync.unlinkSync(PID_FILE);
          res.json({ success: true, message: 'Integration validator stopped' });
        } catch (e) {
          res.json({ success: false, message: 'Failed to stop integration validator' });
        }
      } else {
        res.json({ success: false, message: 'Integration validator is not running' });
      }
    } else {
      res.status(400).json({ success: false, message: 'Invalid action. Use "start" or "stop"' });
    }
  } catch (error) {
    console.error('Error controlling integration validator:', error);
    res.status(500).json({ success: false, message: error.message });
  }
});

/**
 * GET /api/integration-validator/status
 * Get integration validator status
 */
app.get('/api/integration-validator/status', (req, res) => {
  const { execSync } = require('child_process');
  const fsSync = require('fs');
  const PID_FILE = '/tmp/commit-relay-integration-validator.pid';

  try {
    if (fsSync.existsSync(PID_FILE)) {
      const pid = parseInt(fsSync.readFileSync(PID_FILE, 'utf-8').trim());

      try {
        execSync(`ps -p ${pid}`, { stdio: 'pipe' });
        res.json({
          status: 'running',
          pid: pid,
          uptime_seconds: 0 // TODO: Track uptime when daemon is implemented
        });
      } catch (e) {
        fsSync.unlinkSync(PID_FILE);
        res.json({ status: 'stopped', pid: null });
      }
    } else {
      res.json({ status: 'stopped', pid: null });
    }
  } catch (error) {
    console.error('Error checking integration validator status:', error);
    res.json({ status: 'stopped', pid: null });
  }
});

/**
 * POST /api/moe/learning/activate
 * Activate the MoE Learning Mastery task
 */
app.post('/api/moe/learning/activate', async (req, res) => {
  const { execSync } = require('child_process');
  const fsSync = require('fs');

  try {
    // SAFEGUARD: Check if critical daemons are running before creating tasks
    let handoffProcessorRunning = false;
    let workerDaemonRunning = false;
    try {
      execSync('pgrep -f "handoff-processor-daemon.sh"', { stdio: 'pipe' });
      handoffProcessorRunning = true;
    } catch (e) {}
    try {
      execSync('pgrep -f "worker-daemon.sh"', { stdio: 'pipe' });
      workerDaemonRunning = true;
    } catch (e) {}

    if (!handoffProcessorRunning || !workerDaemonRunning) {
      const missingDaemons = [];
      if (!handoffProcessorRunning) missingDaemons.push('handoff-processor');
      if (!workerDaemonRunning) missingDaemons.push('worker-daemon');

      return res.status(503).json({
        success: false,
        message: `Cannot activate task: Critical daemons not running (${missingDaemons.join(', ')}). Tasks will get stuck without these daemons. Please start them first.`,
        missing_daemons: missingDaemons,
        suggestion: 'Start the daemon supervisor to auto-start critical daemons'
      });
    }

    const taskFile = path.join(COMMIT_RELAY_HOME, 'coordination', 'tasks', 'task-moe-learning-mastery.json');
    const taskQueueFile = path.join(COMMIT_RELAY_HOME, 'coordination', 'task-queue.json');

    // Check if task file exists
    if (!fsSync.existsSync(taskFile)) {
      return res.status(404).json({
        success: false,
        message: 'Learning task file not found'
      });
    }

    // Read the task
    const task = JSON.parse(fsSync.readFileSync(taskFile, 'utf-8'));

    // Update task with current timestamp and ensure it's pending
    task.created_at = new Date().toISOString();
    task.status = 'pending';
    task.id = `task-moe-learning-${Date.now()}`;

    // Read current task queue
    let taskQueue = { tasks: [] };
    if (fsSync.existsSync(taskQueueFile)) {
      try {
        taskQueue = JSON.parse(fsSync.readFileSync(taskQueueFile, 'utf-8'));
      } catch (e) {
        console.error('Error reading task queue:', e);
      }
    }

    // Check if a learning task is already pending or in progress
    const existingLearningTask = taskQueue.tasks?.find(t =>
      t.title && t.title.includes('MoE Learning System') &&
      (t.status === 'pending' || t.status === 'in_progress' || t.status === 'assigned')
    );

    if (existingLearningTask) {
      return res.json({
        success: false,
        message: 'A learning task is already active',
        task_id: existingLearningTask.id,
        status: existingLearningTask.status
      });
    }

    // Add task to queue
    if (!taskQueue.tasks) {
      taskQueue.tasks = [];
    }
    taskQueue.tasks.push(task);

    // Write updated queue
    fsSync.writeFileSync(taskQueueFile, JSON.stringify(taskQueue, null, 2));

    // Also save the updated task file
    fsSync.writeFileSync(taskFile, JSON.stringify(task, null, 2));

    console.log(`MoE Learning task activated: ${task.id}`);

    res.json({
      success: true,
      message: 'MoE Learning task activated successfully',
      task_id: task.id,
      estimated_duration: '2.5-3.5 hours'
    });

  } catch (error) {
    console.error('Error activating MoE learning task:', error);
    res.status(500).json({
      success: false,
      message: error.message
    });
  }
});

/**
 * GET /api/moe/learning/deliverables
 * Get status of learning deliverable files
 */
app.get('/api/moe/learning/deliverables', async (req, res) => {
  const fsSync = require('fs');

  try {
    const deliverables = [
      {
        name: 'Enhanced Task Patterns',
        file: 'coordination/memory/long-term/task-patterns.json',
        type: 'json',
        description: 'Enhanced patterns with architectural understanding and agent specialization insights'
      },
      {
        name: 'Routing Intelligence Model',
        file: 'coordination/memory/long-term/routing-intelligence.json',
        type: 'json',
        description: 'Advanced routing decision model based on architecture and historical patterns'
      },
      {
        name: 'Agent Capability Matrix',
        file: 'coordination/memory/long-term/agent-capabilities.json',
        type: 'json',
        description: 'Detailed matrix of each agent\'s strengths, patterns, and optimal use cases'
      },
      {
        name: 'Security Pattern Library',
        file: 'coordination/memory/long-term/security-patterns.json',
        type: 'json',
        description: 'Library of security patterns, vulnerabilities, and remediation strategies'
      },
      {
        name: 'Development Standards Guide',
        file: 'coordination/memory/long-term/development-standards.json',
        type: 'json',
        description: 'Codified development standards, patterns, and best practices'
      },
      {
        name: 'Operational Insights',
        file: 'coordination/memory/long-term/operational-insights.json',
        type: 'json',
        description: 'Real-time behavioral patterns, performance baselines, and optimization opportunities'
      },
      {
        name: 'Learning Summary Report',
        file: 'coordination/moe-learning-mastery-report.md',
        type: 'markdown',
        description: 'Comprehensive report documenting learned knowledge, insights, and recommendations'
      }
    ];

    const deliverableStatus = deliverables.map(d => {
      const filePath = path.join(COMMIT_RELAY_HOME, d.file);
      const exists = fsSync.existsSync(filePath);

      let status = 'pending';
      let size = 0;
      let modified = null;

      if (exists) {
        const stats = fsSync.statSync(filePath);
        size = stats.size;
        modified = stats.mtime;

        // Check if file was modified in the last 24 hours (likely from recent learning)
        const dayAgo = Date.now() - (24 * 60 * 60 * 1000);
        status = stats.mtimeMs > dayAgo ? 'recent' : 'exists';
      }

      return {
        ...d,
        status,
        exists,
        size,
        modified,
        path: d.file
      };
    });

    res.json({ deliverables: deliverableStatus });
  } catch (error) {
    console.error('Error checking learning deliverables:', error);
    res.status(500).json({ error: error.message });
  }
});

/**
 * GET /api/moe/learning/deliverables/:filename
 * Get content of a specific deliverable file
 */
app.get('/api/moe/learning/deliverables/:filename', async (req, res) => {
  const fsSync = require('fs');
  const { filename } = req.params;

  try {
    // Map of allowed files for security
    const allowedFiles = {
      'task-patterns.json': 'coordination/memory/long-term/task-patterns.json',
      'routing-intelligence.json': 'coordination/memory/long-term/routing-intelligence.json',
      'agent-capabilities.json': 'coordination/memory/long-term/agent-capabilities.json',
      'security-patterns.json': 'coordination/memory/long-term/security-patterns.json',
      'development-standards.json': 'coordination/memory/long-term/development-standards.json',
      'operational-insights.json': 'coordination/memory/long-term/operational-insights.json',
      'moe-learning-mastery-report.md': 'coordination/moe-learning-mastery-report.md'
    };

    if (!allowedFiles[filename]) {
      return res.status(404).json({ error: 'File not found or not allowed' });
    }

    const filePath = path.join(COMMIT_RELAY_HOME, allowedFiles[filename]);

    if (!fsSync.existsSync(filePath)) {
      return res.status(404).json({ error: 'File does not exist yet' });
    }

    const content = fsSync.readFileSync(filePath, 'utf-8');
    const stats = fsSync.statSync(filePath);

    res.json({
      filename,
      content,
      size: stats.size,
      modified: stats.mtime,
      type: filename.endsWith('.json') ? 'json' : 'markdown'
    });
  } catch (error) {
    console.error('Error reading deliverable file:', error);
    res.status(500).json({ error: error.message });
  }
});

// ============================================================================
// MoE Intelligence API Endpoints
// ============================================================================

/**
 * GET /api/moe/routing
 * Get MoE routing decisions from coordinator logs
 */
app.get('/api/moe/routing', async (req, res) => {
  try {
    const fsSync = require('fs');
    const { exec } = require('child_process');
    const { promisify } = require('util');
    const execAsync = promisify(exec);

    const routingLogPath = path.join(COMMIT_RELAY_HOME, 'coordination', 'masters', 'coordinator', 'logs', 'routing-decisions.jsonl');

    if (!fsSync.existsSync(routingLogPath)) {
      return res.json({ decisions: [] });
    }

    // Use jq to parse multi-line JSON objects and convert to array
    // This handles both JSONL (single-line) and pretty-printed multi-line JSON
    const { stdout } = await execAsync(`jq -s '.' "${routingLogPath}"`);
    const allDecisions = JSON.parse(stdout);

    // Get last 100 decisions, most recent first
    const decisions = allDecisions.slice(-100).reverse();

    res.json({ decisions });
  } catch (error) {
    console.error('Error fetching MoE routing decisions:', error);
    res.status(500).json({ error: 'Failed to fetch routing decisions', details: error.message });
  }
});

/**
 * GET /api/moe/pool
 * Get MoE worker pool state and metrics
 */
app.get('/api/moe/pool', async (req, res) => {
  try {
    const fsSync = require('fs');
    const poolStatePath = path.join(COMMIT_RELAY_HOME, 'coordination', 'memory', 'working', 'pool-state.json');

    if (!fsSync.existsSync(poolStatePath)) {
      return res.json({
        active_workers: 0,
        max_capacity: 64,
        activation_rate: 0,
        target_workers: 0,
        utilization: 0,
        moe_analogy: {
          active_params: 'No data'
        }
      });
    }

    const poolData = JSON.parse(fsSync.readFileSync(poolStatePath, 'utf-8'));

    // Extract pool metrics
    const metrics = poolData.pool_metrics || {};

    res.json({
      active_workers: metrics.active_workers || 0,
      max_capacity: metrics.max_capacity || 64,
      activation_rate: metrics.activation_rate || 0,
      target_workers: metrics.target_workers || 0,
      utilization: metrics.utilization || 0,
      moe_analogy: poolData.moe_analogy || { active_params: 'No data' }
    });
  } catch (error) {
    console.error('Error fetching MoE pool state:', error);
    res.status(500).json({ error: 'Failed to fetch pool state' });
  }
});

/**
 * GET /api/moe/learning
 * Get MoE learning system metrics and insights
 */
app.get('/api/moe/learning', async (req, res) => {
  try {
    const fsSync = require('fs');
    const successMetricsPath = path.join(COMMIT_RELAY_HOME, 'coordination', 'memory', 'long-term', 'success-metrics.json');
    const taskPatternsPath = path.join(COMMIT_RELAY_HOME, 'coordination', 'memory', 'long-term', 'task-patterns.json');

    let metrics = {
      total_tasks: 0,
      success_rate: 0,
      avg_time: 0,
      learned_keywords: 0,
      experts: {
        development: { tasks: 0, success_rate: 0, avg_time: 0 },
        security: { tasks: 0, success_rate: 0, avg_time: 0 },
        inventory: { tasks: 0, success_rate: 0, avg_time: 0 }
      }
    };

    let insights = [];

    // Load success metrics
    if (fsSync.existsSync(successMetricsPath)) {
      const successData = JSON.parse(fsSync.readFileSync(successMetricsPath, 'utf-8'));

      metrics.total_tasks = successData.overall_metrics?.total_tasks_processed || 0;
      metrics.success_rate = successData.overall_metrics?.success_rate || 0;
      metrics.avg_time = successData.overall_metrics?.average_completion_time_minutes || 0;

      // Extract expert-specific metrics
      const expertPerf = successData.expert_performance || {};
      ['development', 'security', 'inventory'].forEach(expert => {
        if (expertPerf[expert]) {
          metrics.experts[expert] = {
            tasks: expertPerf[expert].tasks_completed || 0,
            success_rate: expertPerf[expert].success_rate || 0,
            avg_time: expertPerf[expert].average_time_minutes || 0
          };
        }
      });
    }

    // Load task patterns for learned keywords
    if (fsSync.existsSync(taskPatternsPath)) {
      const patternsData = JSON.parse(fsSync.readFileSync(taskPatternsPath, 'utf-8'));
      const allKeywords = new Set();

      Object.values(patternsData.expert_patterns || {}).forEach(expertData => {
        Object.keys(expertData.keywords || {}).forEach(keyword => allKeywords.add(keyword));
      });

      metrics.learned_keywords = allKeywords.size;

      // Generate insights based on patterns
      if (metrics.total_tasks > 0) {
        insights.push({
          id: 'insight-1',
          message: `System has learned ${metrics.learned_keywords} keywords from ${metrics.total_tasks} tasks`,
          timestamp: new Date().toISOString()
        });

        if (metrics.success_rate > 90) {
          insights.push({
            id: 'insight-2',
            message: `Excellent routing accuracy: ${metrics.success_rate.toFixed(1)}% success rate`,
            timestamp: new Date().toISOString()
          });
        }
      }
    }

    res.json({ metrics, insights });
  } catch (error) {
    console.error('Error fetching MoE learning metrics:', error);
    res.status(500).json({ error: 'Failed to fetch learning metrics' });
  }
});

/**
 * GET /api/learning-monitor/status
 * Get learning task monitor daemon status and active tasks
 */
app.get('/api/learning-monitor/status', async (req, res) => {
  try {
    const fsSync = require('fs');
    const { execSync } = require('child_process');

    // Check if daemon is running
    const pidFile = path.join(COMMIT_RELAY_HOME, 'coordination', 'pids', 'learning-monitor.pid');
    let isRunning = false;
    let pid = null;

    if (fsSync.existsSync(pidFile)) {
      pid = fsSync.readFileSync(pidFile, 'utf-8').trim();
      try {
        process.kill(parseInt(pid), 0);
        isRunning = true;
      } catch (e) {
        isRunning = false;
      }
    }

    // Get metrics
    const metricsFile = path.join(COMMIT_RELAY_HOME, 'coordination', 'metrics', 'learning-monitor-metrics.json');
    let metrics = {
      total_checks: 0,
      total_completed: 0,
      total_killed: 0
    };

    if (fsSync.existsSync(metricsFile)) {
      metrics = JSON.parse(fsSync.readFileSync(metricsFile, 'utf-8'));
    }

    // Find active learning tasks
    const activeTasks = [];
    const handsoffsPattern = path.join(COMMIT_RELAY_HOME, 'coordination', 'masters', '*', 'handoffs', 'task-moe-learning-*.json');

    try {
      const handoffFiles = execSync(`ls ${handsoffsPattern} 2>/dev/null || true`, { encoding: 'utf-8' }).trim().split('\n').filter(f => f);

      for (const file of handoffFiles) {
        if (fsSync.existsSync(file)) {
          const task = JSON.parse(fsSync.readFileSync(file, 'utf-8'));
          const taskId = task.task_id || task.handoff_id;

          // Count deliverables
          const delivDir = path.join(COMMIT_RELAY_HOME, 'coordination', 'moe-learning', 'deliverables', taskId);
          let deliverableCount = 0;
          if (fsSync.existsSync(delivDir)) {
            deliverableCount = fsSync.readdirSync(delivDir).length;
          }

          activeTasks.push({
            id: taskId,
            status: task.status,
            created_at: task.created_at,
            assigned_to: task.assigned_to,
            deliverables: deliverableCount
          });
        }
      }
    } catch (e) {
      // No handoffs found
    }

    res.json({
      daemon: {
        running: isRunning,
        pid: isRunning ? parseInt(pid) : null
      },
      metrics,
      active_tasks: activeTasks,
      config: {
        check_interval_seconds: parseInt(process.env.LEARNING_MONITOR_INTERVAL || '30'),
        stall_threshold_minutes: parseInt(process.env.LEARNING_STALL_THRESHOLD || '15')
      }
    });
  } catch (error) {
    console.error('Error getting learning monitor status:', error);
    res.status(500).json({ error: 'Failed to get learning monitor status' });
  }
});

/**
 * GET /api/learning-monitor/events
 * Get recent learning monitor events
 */
app.get('/api/learning-monitor/events', async (req, res) => {
  try {
    const fsSync = require('fs');
    const eventsFile = path.join(COMMIT_RELAY_HOME, 'coordination', 'events', 'learning-events.jsonl');
    const limit = parseInt(req.query.limit) || 50;

    if (!fsSync.existsSync(eventsFile)) {
      return res.json({ events: [] });
    }

    const content = fsSync.readFileSync(eventsFile, 'utf-8');
    const lines = content.trim().split('\n').filter(l => l);
    const events = lines.slice(-limit).map(line => {
      try {
        return JSON.parse(line);
      } catch (e) {
        return null;
      }
    }).filter(e => e).reverse();

    res.json({ events });
  } catch (error) {
    console.error('Error getting learning events:', error);
    res.status(500).json({ error: 'Failed to get learning events' });
  }
});

/**
 * POST /api/learning-monitor/control
 * Start or stop the learning monitor daemon
 */
app.post('/api/learning-monitor/control', async (req, res) => {
  try {
    const { action } = req.body;
    const { execSync } = require('child_process');
    const fsSync = require('fs');

    const daemonScript = path.join(COMMIT_RELAY_HOME, 'scripts', 'learning-task-monitor-daemon.sh');
    const pidFile = path.join(COMMIT_RELAY_HOME, 'coordination', 'pids', 'learning-monitor.pid');
    const logFile = path.join(COMMIT_RELAY_HOME, 'agents', 'logs', 'system', 'learning-task-monitor.log');

    if (action === 'start') {
      // Check if already running
      if (fsSync.existsSync(pidFile)) {
        const pid = fsSync.readFileSync(pidFile, 'utf-8').trim();
        try {
          process.kill(parseInt(pid), 0);
          return res.json({ success: false, message: 'Daemon already running', pid: parseInt(pid) });
        } catch (e) {
          // PID file exists but process not running, clean up
          fsSync.unlinkSync(pidFile);
        }
      }

      // Start daemon
      execSync(`nohup ${daemonScript} >> ${logFile} 2>&1 &`, {
        shell: '/bin/bash',
        cwd: COMMIT_RELAY_HOME
      });

      // Wait for PID file
      await new Promise(resolve => setTimeout(resolve, 1000));

      let pid = null;
      if (fsSync.existsSync(pidFile)) {
        pid = parseInt(fsSync.readFileSync(pidFile, 'utf-8').trim());
      }

      res.json({ success: true, message: 'Daemon started', pid });

    } else if (action === 'stop') {
      if (!fsSync.existsSync(pidFile)) {
        return res.json({ success: false, message: 'Daemon not running' });
      }

      const pid = fsSync.readFileSync(pidFile, 'utf-8').trim();
      try {
        process.kill(parseInt(pid), 'SIGTERM');
        fsSync.unlinkSync(pidFile);
        res.json({ success: true, message: 'Daemon stopped', pid: parseInt(pid) });
      } catch (e) {
        fsSync.unlinkSync(pidFile);
        res.json({ success: true, message: 'Daemon was not running, cleaned up PID file' });
      }

    } else {
      res.status(400).json({ error: 'Invalid action. Use "start" or "stop"' });
    }
  } catch (error) {
    console.error('Error controlling learning monitor:', error);
    res.status(500).json({ error: 'Failed to control learning monitor' });
  }
});

/**
 * GET /api/moe/accuracy
 * Calculate routing accuracy from routing decisions
 */
app.get('/api/moe/accuracy', async (req, res) => {
  try {
    const fsSync = require('fs');

    const routingLogPath = path.join(COMMIT_RELAY_HOME, 'coordination', 'masters', 'coordinator', 'knowledge-base', 'routing-decisions.jsonl');

    if (!fsSync.existsSync(routingLogPath)) {
      return res.json({
        accuracy: 0,
        total_decisions: 0,
        correct_routes: 0,
        last_24h: { accuracy: 0, decisions: 0 },
        accuracy_over_time: []
      });
    }

    // Parse routing decisions
    const content = fsSync.readFileSync(routingLogPath, 'utf-8');
    const allDecisions = content
      .trim()
      .split('\n')
      .filter(line => line)
      .map(line => {
        try {
          const parsed = JSON.parse(line);
          // Normalize both formats
          if (parsed.decision) {
            return {
              timestamp: parsed.timestamp,
              confidence: parsed.decision.primary_confidence,
              expert: parsed.decision.primary_expert
            };
          } else if (parsed.routed_to && parsed.timestamp) {
            return {
              timestamp: parsed.timestamp,
              confidence: parsed.confidence || 0.5,
              expert: parsed.routed_to
            };
          }
          return null;
        } catch {
          return null;
        }
      })
      .filter(d => d !== null);

    // Calculate overall accuracy (last 100 decisions)
    const recentDecisions = allDecisions.slice(-100);
    const totalDecisions = recentDecisions.length;

    // Calculate last 24 hours
    const now = new Date();
    const last24h = recentDecisions.filter(d => {
      const decisionTime = new Date(d.timestamp);
      return (now - decisionTime) < 24 * 60 * 60 * 1000;
    });

    // Calculate confidence-based accuracy (high confidence = correct routing)
    const highConfidenceCount = recentDecisions.filter(d => d.confidence >= 0.7).length;

    const accuracy = totalDecisions > 0 ? (highConfidenceCount / totalDecisions) * 100 : 0;
    const accuracy24h = last24h.length > 0 ?
      (last24h.filter(d => d.confidence >= 0.7).length / last24h.length) * 100 : 0;

    // Generate accuracy over time data for visualization
    const accuracyOverTime = [];
    const groupedByDay = {};
    recentDecisions.forEach(d => {
      const day = new Date(d.timestamp).toLocaleDateString('en-US', { weekday: 'short' });
      if (!groupedByDay[day]) {
        groupedByDay[day] = { total: 0, highConf: 0 };
      }
      groupedByDay[day].total++;
      if (d.confidence >= 0.7) groupedByDay[day].highConf++;
    });
    Object.entries(groupedByDay).forEach(([time, data]) => {
      accuracyOverTime.push({
        time,
        accuracy: data.total > 0 ? (data.highConf / data.total) * 100 : 0
      });
    });

    res.json({
      accuracy: accuracy.toFixed(2),
      total_decisions: totalDecisions,
      correct_routes: highConfidenceCount,
      last_24h: {
        accuracy: accuracy24h.toFixed(2),
        decisions: last24h.length
      },
      avg_confidence: recentDecisions.length > 0 ?
        (recentDecisions.reduce((sum, d) => sum + (d.confidence || 0), 0) / recentDecisions.length).toFixed(2) : 0,
      accuracy_over_time: accuracyOverTime
    });
  } catch (error) {
    console.error('Error calculating MoE accuracy:', error);
    res.status(500).json({ error: 'Failed to calculate accuracy', details: error.message });
  }
});

/**
 * GET /api/moe/confidence-distribution
 * Get distribution of confidence scores across routing decisions
 */
app.get('/api/moe/confidence-distribution', async (req, res) => {
  try {
    const fsSync = require('fs');

    const routingLogPath = path.join(COMMIT_RELAY_HOME, 'coordination', 'masters', 'coordinator', 'knowledge-base', 'routing-decisions.jsonl');

    if (!fsSync.existsSync(routingLogPath)) {
      return res.json({
        distribution: [],
        ranges: [
          { range: '0-25%', count: 0 },
          { range: '26-50%', count: 0 },
          { range: '51-75%', count: 0 },
          { range: '76-90%', count: 0 },
          { range: '91-100%', count: 0 }
        ]
      });
    }

    // Parse routing decisions
    const content = fsSync.readFileSync(routingLogPath, 'utf-8');
    const allDecisions = content
      .trim()
      .split('\n')
      .filter(line => line)
      .map(line => {
        try {
          const parsed = JSON.parse(line);
          if (parsed.decision) {
            return parsed.decision.primary_confidence;
          } else if (parsed.confidence !== undefined) {
            return parsed.confidence;
          }
          return null;
        } catch {
          return null;
        }
      })
      .filter(d => d !== null);

    const recentDecisions = allDecisions.slice(-100);

    // Categorize by confidence score into buckets for bar chart
    const buckets = {
      '0-25': 0,
      '26-50': 0,
      '51-75': 0,
      '76-90': 0,
      '91-100': 0
    };

    recentDecisions.forEach(conf => {
      const pct = conf * 100;
      if (pct <= 25) buckets['0-25']++;
      else if (pct <= 50) buckets['26-50']++;
      else if (pct <= 75) buckets['51-75']++;
      else if (pct <= 90) buckets['76-90']++;
      else buckets['91-100']++;
    });

    const distribution = [
      { range: '0-25%', count: buckets['0-25'] },
      { range: '26-50%', count: buckets['26-50'] },
      { range: '51-75%', count: buckets['51-75'] },
      { range: '76-90%', count: buckets['76-90'] },
      { range: '91-100%', count: buckets['91-100'] }
    ];

    res.json({ distribution, total: recentDecisions.length });
  } catch (error) {
    console.error('Error calculating confidence distribution:', error);
    res.status(500).json({ error: 'Failed to calculate distribution', details: error.message });
  }
});

/**
 * GET /api/moe/pool-utilization
 * Get worker pool utilization by master over time
 */
app.get('/api/moe/pool-utilization', async (req, res) => {
  try {
    const fsSync = require('fs');

    // Read routing decisions to calculate expert utilization
    const routingLogPath = path.join(COMMIT_RELAY_HOME, 'coordination', 'masters', 'coordinator', 'knowledge-base', 'routing-decisions.jsonl');

    let expertCounts = {
      development: 0,
      security: 0,
      inventory: 0,
      cicd: 0
    };

    if (fsSync.existsSync(routingLogPath)) {
      const content = fsSync.readFileSync(routingLogPath, 'utf-8');
      const decisions = content
        .trim()
        .split('\n')
        .filter(line => line)
        .map(line => {
          try {
            const parsed = JSON.parse(line);
            if (parsed.decision) {
              return parsed.decision.primary_expert;
            } else if (parsed.routed_to) {
              return parsed.routed_to;
            }
            return null;
          } catch {
            return null;
          }
        })
        .filter(d => d !== null);

      decisions.forEach(expert => {
        if (expertCounts.hasOwnProperty(expert)) {
          expertCounts[expert]++;
        }
      });
    }

    // Read worker pool for current state
    const workerPoolPath = path.join(COMMIT_RELAY_HOME, 'coordination', 'worker-pool.json');
    let poolData = { active_workers: [] };

    if (fsSync.existsSync(workerPoolPath)) {
      poolData = JSON.parse(fsSync.readFileSync(workerPoolPath, 'utf-8'));
    }

    // Count current workers by master
    const currentUtilization = {
      development: 0,
      security: 0,
      inventory: 0,
      cicd: 0,
      total: 0
    };

    poolData.active_workers.forEach(worker => {
      const spawnedBy = worker.spawned_by || 'unknown';
      if (currentUtilization.hasOwnProperty(spawnedBy)) {
        currentUtilization[spawnedBy]++;
      }
      currentUtilization.total++;
    });

    // Calculate utilization percentages for pie chart
    const totalRouted = Object.values(expertCounts).reduce((sum, c) => sum + c, 0);
    const utilization = Object.entries(expertCounts)
      .filter(([_, count]) => count > 0)
      .map(([expert, count]) => ({
        expert,
        usage: totalRouted > 0 ? Math.round((count / totalRouted) * 100) : 0,
        count
      }));

    // Calculate sparse activation percentage
    const maxCapacity = 64;
    const sparseActivation = currentUtilization.total > 0 ?
      ((currentUtilization.total / maxCapacity) * 100).toFixed(1) : 0;

    // Read worker spec files for detailed status
    const workerSpecsDir = path.join(COMMIT_RELAY_HOME, 'coordination', 'worker-specs', 'active');
    let activeCount = 0;
    let runningCount = 0;
    let pendingCount = 0;

    if (fsSync.existsSync(workerSpecsDir)) {
      const files = fsSync.readdirSync(workerSpecsDir).filter(f => f.endsWith('.json'));
      activeCount = files.length;

      files.forEach(file => {
        const filePath = path.join(workerSpecsDir, file);
        const spec = JSON.parse(fsSync.readFileSync(filePath, 'utf-8'));
        if (spec.status === 'running') runningCount++;
        else if (spec.status === 'pending') pendingCount++;
      });
    }

    res.json({
      utilization,
      sparse_activation: sparseActivation,
      max_capacity: maxCapacity,
      pool_health: {
        active: activeCount,
        running: runningCount,
        pending: pendingCount,
        status: activeCount < 10 ? 'healthy' : activeCount < 15 ? 'warning' : 'critical'
      }
    });
  } catch (error) {
    console.error('Error calculating pool utilization:', error);
    res.status(500).json({ error: 'Failed to calculate utilization', details: error.message });
  }
});

/**
 * POST /api/pm/state
 * PM Daemon reports its current state
 */
app.post('/api/pm/state', async (req, res) => {
  try {
    const fsSync = require('fs');
    const pmStatePath = path.join(COMMIT_RELAY_HOME, 'coordination', 'pm-state.json');

    // Write state to file
    fsSync.writeFileSync(pmStatePath, JSON.stringify(req.body, null, 2));

    // Emit event via WebSocket for real-time updates
    if (wss) {
      wss.clients.forEach(client => {
        if (client.readyState === 1) { // WebSocket.OPEN
          client.send(JSON.stringify({
            type: 'pm_state_update',
            data: req.body,
            timestamp: new Date().toISOString()
          }));
        }
      });
    }

    res.json({ success: true, message: 'PM state updated' });
  } catch (error) {
    console.error('Error updating PM state:', error);
    res.status(500).json({ error: 'Failed to update PM state', details: error.message });
  }
});

/**
 * POST /api/health/report
 * Health Monitor Daemon reports health check results
 */
app.post('/api/health/report', async (req, res) => {
  try {
    const { component, status, details } = req.body;
    const fsSync = require('fs');
    const healthLogPath = path.join(COMMIT_RELAY_HOME, 'coordination', 'health-reports.jsonl');

    const report = {
      component,
      status,
      details,
      timestamp: new Date().toISOString()
    };

    // Append to JSONL log
    fsSync.appendFileSync(healthLogPath, JSON.stringify(report) + '\n');

    // Emit event via WebSocket
    if (wss) {
      wss.clients.forEach(client => {
        if (client.readyState === 1) {
          client.send(JSON.stringify({
            type: 'health_report',
            data: report
          }));
        }
      });
    }

    res.json({ success: true, message: 'Health report recorded' });
  } catch (error) {
    console.error('Error recording health report:', error);
    res.status(500).json({ error: 'Failed to record health report', details: error.message });
  }
});

/**
 * POST /api/metrics/report
 * Metrics Snapshot Daemon reports metrics snapshot
 */
app.post('/api/metrics/report', async (req, res) => {
  try {
    const fsSync = require('fs');
    const metricsLogPath = path.join(COMMIT_RELAY_HOME, 'coordination', 'metrics-snapshots.jsonl');

    const snapshot = {
      ...req.body,
      timestamp: req.body.timestamp || new Date().toISOString()
    };

    // Append to JSONL log
    fsSync.appendFileSync(metricsLogPath, JSON.stringify(snapshot) + '\n');

    // Emit event via WebSocket
    if (wss) {
      wss.clients.forEach(client => {
        if (client.readyState === 1) {
          client.send(JSON.stringify({
            type: 'metrics_snapshot',
            data: snapshot
          }));
        }
      });
    }

    res.json({ success: true, message: 'Metrics snapshot recorded' });
  } catch (error) {
    console.error('Error recording metrics snapshot:', error);
    res.status(500).json({ error: 'Failed to record metrics snapshot', details: error.message });
  }
});

// ============================================================================
// Server-Sent Events (SSE) for ELK-Style Log Streaming
// ============================================================================

// Track SSE clients
const sseClients = new Map();

/**
 * SSE endpoint for real-time log streaming (ELK-style)
 * Streams JSONL log files with auto-tail functionality
 */
app.get('/api/logs/stream', (req, res) => {
  const logFile = req.query.file || 'system-events';
  const clientId = Date.now() + Math.random();

  // Set headers for SSE
  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    'Connection': 'keep-alive',
    'X-Accel-Buffering': 'no' // Disable nginx buffering
  });

  // Send initial connection message
  res.write(`data: ${JSON.stringify({ type: 'connected', clientId })}\n\n`);

  // Store client
  sseClients.set(clientId, { res, logFile, connectedAt: new Date() });
  console.log(`SSE client ${clientId} connected for ${logFile}`);

  // Send heartbeat every 30 seconds to keep connection alive
  const heartbeat = setInterval(() => {
    res.write(': heartbeat\n\n');
  }, 30000);

  // Clean up on disconnect
  req.on('close', () => {
    clearInterval(heartbeat);
    sseClients.delete(clientId);
    console.log(`SSE client ${clientId} disconnected`);
  });
});

/**
 * Broadcast log event to SSE clients
 */
function broadcastLogEvent(logFile, event) {
  sseClients.forEach((client, clientId) => {
    if (client.logFile === logFile) {
      try {
        client.res.write(`data: ${JSON.stringify(event)}\n\n`);
      } catch (error) {
        console.error(`Failed to send to SSE client ${clientId}:`, error);
        sseClients.delete(clientId);
      }
    }
  });
}

/**
 * Get available log files for streaming
 */
app.get('/api/logs/available', (req, res) => {
  const coordDir = path.join(COMMIT_RELAY_HOME, 'coordination');
  const logFiles = [
    { name: 'system-events', path: 'system-events.jsonl', description: 'System events and activity' },
    { name: 'health-reports', path: 'health-reports.jsonl', description: 'System health check reports' },
    { name: 'pm-activity', path: 'pm-activity.jsonl', description: 'Process manager activity log' },
    { name: 'git-operations', path: 'git-operations.jsonl', description: 'Git push/pull operations' },
    { name: 'metrics-snapshots', path: 'metrics-snapshots.jsonl', description: 'System metrics snapshots' }
  ].filter(log => {
    try {
      return fsSync.existsSync(path.join(coordDir, log.path));
    } catch {
      return false;
    }
  });

  res.json({ logs: logFiles, count: logFiles.length });
});

/**
 * Tail a log file (get last N lines)
 */
app.get('/api/logs/tail', async (req, res) => {
  try {
    const logFile = req.query.file || 'system-events';
    const lines = parseInt(req.query.lines) || 100;

    // Validate and sanitize the log file name
    const sanitizedLogFile = sanitizeFilename(logFile, ['.jsonl']);
    if (!sanitizedLogFile) {
      return res.status(400).json({ error: 'Invalid log file name' });
    }

    // Remove extension if provided (we'll add it)
    const baseLogFile = sanitizedLogFile.replace('.jsonl', '');
    const coordDir = path.join(COMMIT_RELAY_HOME, 'coordination');
    const logPath = safeJoin(coordDir, `${baseLogFile}.jsonl`);

    if (!logPath || !fsSync.existsSync(logPath)) {
      return res.status(404).json({ error: 'Log file not found' });
    }

    const content = await fs.readFile(logPath, 'utf-8');
    const allLines = content.trim().split('\n').filter(line => line);
    const tailLines = allLines.slice(-lines);

    const events = tailLines.map(line => {
      try {
        return JSON.parse(line);
      } catch {
        return { raw: line, parseError: true };
      }
    });

    res.json({
      file: logFile,
      totalLines: allLines.length,
      returnedLines: events.length,
      events
    });
  } catch (error) {
    console.error('Error tailing log file:', error);
    res.status(500).json({ error: error.message });
  }
});

// ============================================================================
// User Management API Endpoints
// ============================================================================

/**
 * GET /api/users
 * Get all users with optional filtering and pagination
 * Query params:
 *   - role: filter by role (admin, developer, viewer)
 *   - status: filter by status (active, inactive)
 *   - limit: number of users to return (default: all)
 *   - offset: pagination offset (default: 0)
 */
app.get('/api/users', async (req, res) => {
  try {
    const { role, status, limit, offset } = req.query;

    const usersPath = path.join(__dirname, '../../coordination/users.json');
    const usersData = await readJSON(usersPath);

    if (!usersData || !usersData.users) {
      return res.status(500).json({
        error: 'Users data not found or invalid',
        users: [],
        total: 0
      });
    }

    let filteredUsers = [...usersData.users];

    // Apply filters
    if (role) {
      filteredUsers = filteredUsers.filter(u => u.role === role);
    }
    if (status) {
      filteredUsers = filteredUsers.filter(u => u.status === status);
    }

    // Apply pagination
    const total = filteredUsers.length;
    const offsetNum = parseInt(offset) || 0;
    const limitNum = parseInt(limit) || total;

    const paginatedUsers = filteredUsers.slice(offsetNum, offsetNum + limitNum);

    res.json({
      users: paginatedUsers,
      total: total,
      limit: limitNum,
      offset: offsetNum,
      filters: { role, status }
    });
  } catch (error) {
    console.error('Error fetching users:', error);
    res.status(500).json({
      error: 'Internal server error',
      details: sanitizeError(error)
    });
  }
});

/**
 * GET /api/users/:id
 * Get a specific user by ID
 */
app.get('/api/users/:id', async (req, res) => {
  try {
    const { id } = req.params;

    const usersPath = path.join(__dirname, '../../coordination/users.json');
    const usersData = await readJSON(usersPath);

    if (!usersData || !usersData.users) {
      return res.status(404).json({ error: 'Users data not found' });
    }

    const user = usersData.users.find(u => u.id === id);

    if (!user) {
      return res.status(404).json({ error: 'User not found' });
    }

    res.json(user);
  } catch (error) {
    console.error('Error fetching user:', error);
    res.status(500).json({
      error: 'Internal server error',
      details: sanitizeError(error)
    });
  }
});

/**
 * POST /api/users
 * Create a new user
 * Body: { username, email, role, status }
 */
app.post('/api/users', async (req, res) => {
  try {
    const { username, email, role, status } = req.body;

    // Validation
    if (!username || !email) {
      return res.status(400).json({
        error: 'Missing required fields',
        required: ['username', 'email']
      });
    }

    // Validate email format
    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
    if (!emailRegex.test(email)) {
      return res.status(400).json({ error: 'Invalid email format' });
    }

    // Validate role
    const validRoles = ['admin', 'developer', 'viewer'];
    const userRole = role || 'viewer';
    if (!validRoles.includes(userRole)) {
      return res.status(400).json({
        error: 'Invalid role',
        validRoles
      });
    }

    const usersPath = path.join(__dirname, '../../coordination/users.json');
    const usersData = await readJSON(usersPath);

    if (!usersData) {
      return res.status(500).json({ error: 'Failed to load users data' });
    }

    // Ensure users array exists
    if (!usersData.users) {
      usersData.users = [];
    }

    // Check for duplicate username or email
    const existingUser = usersData.users.find(
      u => u.username === username || u.email === email
    );

    if (existingUser) {
      return res.status(409).json({
        error: 'User already exists',
        conflict: existingUser.username === username ? 'username' : 'email'
      });
    }

    // Create new user
    const newUser = {
      id: `user-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`,
      username,
      email,
      role: userRole,
      status: status || 'active',
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
      last_login: null,
      metadata: {
        created_by: 'api',
        source: 'user-management-api'
      }
    };

    usersData.users.push(newUser);
    usersData.updated_at = new Date().toISOString();

    // Write back to file
    await safeWriteJSON(usersPath, usersData);

    // Emit system event
    emitSystemEvent('user_created', {
      user_id: newUser.id,
      username: newUser.username,
      role: newUser.role,
      message: `New user created: ${username}`
    });

    res.status(201).json({
      success: true,
      user: newUser,
      message: 'User created successfully'
    });
  } catch (error) {
    console.error('Error creating user:', error);
    res.status(500).json({
      error: 'Internal server error',
      details: sanitizeError(error)
    });
  }
});

/**
 * PUT /api/users/:id
 * Update an existing user
 * Body: { username, email, role, status }
 */
app.put('/api/users/:id', async (req, res) => {
  try {
    const { id } = req.params;
    const { username, email, role, status } = req.body;

    const usersPath = path.join(__dirname, '../../coordination/users.json');
    const usersData = await readJSON(usersPath);

    if (!usersData || !usersData.users) {
      return res.status(404).json({ error: 'Users data not found' });
    }

    const userIndex = usersData.users.findIndex(u => u.id === id);

    if (userIndex === -1) {
      return res.status(404).json({ error: 'User not found' });
    }

    const user = usersData.users[userIndex];

    // Validate role if provided
    if (role) {
      const validRoles = ['admin', 'developer', 'viewer'];
      if (!validRoles.includes(role)) {
        return res.status(400).json({
          error: 'Invalid role',
          validRoles
        });
      }
    }

    // Validate email if provided
    if (email) {
      const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
      if (!emailRegex.test(email)) {
        return res.status(400).json({ error: 'Invalid email format' });
      }

      // Check for duplicate email
      const duplicateEmail = usersData.users.find(
        u => u.id !== id && u.email === email
      );
      if (duplicateEmail) {
        return res.status(409).json({ error: 'Email already in use' });
      }
    }

    // Check for duplicate username
    if (username && username !== user.username) {
      const duplicateUsername = usersData.users.find(
        u => u.id !== id && u.username === username
      );
      if (duplicateUsername) {
        return res.status(409).json({ error: 'Username already in use' });
      }
    }

    // Update user fields
    const updatedUser = {
      ...user,
      username: username || user.username,
      email: email || user.email,
      role: role || user.role,
      status: status || user.status,
      updated_at: new Date().toISOString()
    };

    usersData.users[userIndex] = updatedUser;
    usersData.updated_at = new Date().toISOString();

    // Write back to file
    await safeWriteJSON(usersPath, usersData);

    // Emit system event
    emitSystemEvent('user_updated', {
      user_id: updatedUser.id,
      username: updatedUser.username,
      role: updatedUser.role,
      status: updatedUser.status,
      message: `User updated: ${updatedUser.username}`
    });

    res.json({
      success: true,
      user: updatedUser,
      message: 'User updated successfully'
    });
  } catch (error) {
    console.error('Error updating user:', error);
    res.status(500).json({
      error: 'Internal server error',
      details: sanitizeError(error)
    });
  }
});

/**
 * DELETE /api/users/:id
 * Delete a user
 */
app.delete('/api/users/:id', async (req, res) => {
  try {
    const { id } = req.params;

    const usersPath = path.join(__dirname, '../../coordination/users.json');
    const usersData = await readJSON(usersPath);

    if (!usersData || !usersData.users) {
      return res.status(404).json({ error: 'Users data not found' });
    }

    const userIndex = usersData.users.findIndex(u => u.id === id);

    if (userIndex === -1) {
      return res.status(404).json({ error: 'User not found' });
    }

    const deletedUser = usersData.users.splice(userIndex, 1)[0];
    usersData.updated_at = new Date().toISOString();

    // Write back to file
    await safeWriteJSON(usersPath, usersData);

    // Emit system event
    emitSystemEvent('user_deleted', {
      user_id: deletedUser.id,
      username: deletedUser.username,
      message: `User deleted: ${deletedUser.username}`
    });

    res.json({
      success: true,
      user: deletedUser,
      message: 'User deleted successfully'
    });
  } catch (error) {
    console.error('Error deleting user:', error);
    res.status(500).json({
      error: 'Internal server error',
      details: sanitizeError(error)
    });
  }
});

/**
 * POST /api/users/:id/login
 * Record user login activity
 */
app.post('/api/users/:id/login', async (req, res) => {
  try {
    const { id } = req.params;

    const usersPath = path.join(__dirname, '../../coordination/users.json');
    const usersData = await readJSON(usersPath);

    if (!usersData || !usersData.users) {
      return res.status(404).json({ error: 'Users data not found' });
    }

    const userIndex = usersData.users.findIndex(u => u.id === id);

    if (userIndex === -1) {
      return res.status(404).json({ error: 'User not found' });
    }

    const user = usersData.users[userIndex];

    if (user.status !== 'active') {
      return res.status(403).json({
        error: 'User account is not active',
        status: user.status
      });
    }

    // Update last login
    user.last_login = new Date().toISOString();
    user.updated_at = new Date().toISOString();

    usersData.updated_at = new Date().toISOString();

    // Write back to file
    await safeWriteJSON(usersPath, usersData);

    // Emit system event
    emitSystemEvent('user_login', {
      user_id: user.id,
      username: user.username,
      timestamp: user.last_login,
      message: `User logged in: ${user.username}`
    });

    res.json({
      success: true,
      user: {
        id: user.id,
        username: user.username,
        role: user.role,
        last_login: user.last_login
      },
      message: 'Login recorded successfully'
    });
  } catch (error) {
    console.error('Error recording login:', error);
    res.status(500).json({
      error: 'Internal server error',
      details: sanitizeError(error)
    });
  }
});

// ============================================================================
// Phase 8: Advanced Optimization APIs
// ============================================================================

// Scheduler
app.get('/api/optimizer/scheduler/stats', async (req, res) => {
  try {
    const { execSync } = require('child_process');
    const result = execSync(`${COMMIT_RELAY_HOME}/scripts/optimizer-scheduler stats`, {
      encoding: 'utf-8',
      timeout: 10000
    });
    res.json(JSON.parse(result));
  } catch (error) {
    res.json({ queued: 0, assigned: 0, completed: 0 });
  }
});

app.get('/api/optimizer/scheduler/balance', async (req, res) => {
  try {
    const { execSync } = require('child_process');
    const result = execSync(`${COMMIT_RELAY_HOME}/scripts/optimizer-scheduler balance`, {
      encoding: 'utf-8',
      timeout: 10000
    });
    res.json(JSON.parse(result));
  } catch (error) {
    res.json({ load_distribution: [], recommended_master: 'coordinator' });
  }
});

// Token Optimizer
app.get('/api/optimizer/tokens/stats', async (req, res) => {
  try {
    const { execSync } = require('child_process');
    const result = execSync(`${COMMIT_RELAY_HOME}/scripts/optimizer-tokens stats`, {
      encoding: 'utf-8',
      timeout: 10000
    });
    res.json(JSON.parse(result));
  } catch (error) {
    res.json({ allocation: {}, efficiency: {}, forecast: {} });
  }
});

app.get('/api/optimizer/tokens/forecast', async (req, res) => {
  try {
    const { execSync } = require('child_process');
    const result = execSync(`${COMMIT_RELAY_HOME}/scripts/optimizer-tokens forecast`, {
      encoding: 'utf-8',
      timeout: 10000
    });
    res.json(JSON.parse(result));
  } catch (error) {
    res.json({ exhaustion_risk: 'unknown', hours_until_exhaustion: 0 });
  }
});

// Worker Pool
app.get('/api/optimizer/pool/stats', async (req, res) => {
  try {
    const { execSync } = require('child_process');
    const result = execSync(`${COMMIT_RELAY_HOME}/scripts/optimizer-pool stats`, {
      encoding: 'utf-8',
      timeout: 10000
    });
    res.json(JSON.parse(result));
  } catch (error) {
    res.json({ status: { warm: 0, active: 0, cold: 0 }, efficiency: {} });
  }
});

// Profiler
app.get('/api/optimizer/profile/stats', async (req, res) => {
  try {
    const { execSync } = require('child_process');
    const result = execSync(`${COMMIT_RELAY_HOME}/scripts/optimizer-profile stats`, {
      encoding: 'utf-8',
      timeout: 10000
    });
    res.json(JSON.parse(result));
  } catch (error) {
    res.json({ benchmark_count: 0, bottlenecks: [], recommendations: 0 });
  }
});

app.get('/api/optimizer/profile/bottlenecks', async (req, res) => {
  try {
    const { execSync } = require('child_process');
    const result = execSync(`${COMMIT_RELAY_HOME}/scripts/optimizer-profile bottlenecks`, {
      encoding: 'utf-8',
      timeout: 10000
    });
    res.json(JSON.parse(result));
  } catch (error) {
    res.json([]);
  }
});

app.get('/api/optimizer/profile/recommendations', async (req, res) => {
  try {
    const { execSync } = require('child_process');
    const result = execSync(`${COMMIT_RELAY_HOME}/scripts/optimizer-profile tune`, {
      encoding: 'utf-8',
      timeout: 10000
    });
    res.json(JSON.parse(result));
  } catch (error) {
    res.json({ recommendations: [] });
  }
});

// ============================================================================
// Agentstudio API Endpoints
// ============================================================================

/**
 * GET /api/agentstudio/agents
 * List all agents from the registry
 */
app.get('/api/agentstudio/agents',
  getLimiter,
  async (req, res) => {
  try {
    const registryPath = path.join(COMMIT_RELAY_HOME, 'coordination/agentstudio/registry/agents.json');

    if (!fsSync.existsSync(registryPath)) {
      return res.json({
        agents: [],
        total: 0,
        message: 'Agent registry not found'
      });
    }

    const registry = JSON.parse(fsSync.readFileSync(registryPath, 'utf-8'));
    const agents = registry.agents || {};

    // Convert to array and add computed fields
    const agentList = Object.values(agents).map(agent => ({
      ...agent,
      health_status: agent.status === 'active' ? 'healthy' :
                     agent.status === 'idle' ? 'standby' : 'offline',
      capabilities_count: (agent.capabilities || []).length,
      integrations_count: (agent.integrations || []).length
    }));

    // Filter by type if specified
    const { type, status, category } = req.query;
    let filteredAgents = agentList;

    if (type) {
      filteredAgents = filteredAgents.filter(a => a.type === type);
    }
    if (status) {
      filteredAgents = filteredAgents.filter(a => a.status === status);
    }
    if (category) {
      filteredAgents = filteredAgents.filter(a => a.category === category);
    }

    res.json({
      agents: filteredAgents,
      total: filteredAgents.length,
      registry_updated: registry.updated_at,
      categories: registry.categories || [],
      agent_types: registry.agent_types || {}
    });

  } catch (error) {
    console.error('Error fetching agents:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

/**
 * GET /api/agentstudio/agents/:id
 * Get agent details by ID
 */
app.get('/api/agentstudio/agents/:id',
  getLimiter,
  async (req, res) => {
  try {
    const { id } = req.params;
    const registryPath = path.join(COMMIT_RELAY_HOME, 'coordination/agentstudio/registry/agents.json');

    if (!fsSync.existsSync(registryPath)) {
      return res.status(404).json({ error: 'Agent registry not found' });
    }

    const registry = JSON.parse(fsSync.readFileSync(registryPath, 'utf-8'));
    const agent = registry.agents[id];

    if (!agent) {
      return res.status(404).json({ error: `Agent not found: ${id}` });
    }

    // Get additional runtime info
    let runtimeInfo = {
      is_running: false,
      last_activity: null,
      current_tasks: 0
    };

    // Check for active workers/tasks for this agent
    const activeDir = path.join(COMMIT_RELAY_HOME, 'coordination/worker-specs/active');
    if (fsSync.existsSync(activeDir)) {
      const activeFiles = fsSync.readdirSync(activeDir);
      runtimeInfo.current_tasks = activeFiles.filter(f =>
        f.includes(id.replace('-master', ''))
      ).length;
    }

    // Check handoffs
    const handoffsDir = path.join(COMMIT_RELAY_HOME, `coordination/masters/${id.replace('-master', '')}/handoffs`);
    let pendingHandoffs = 0;
    if (fsSync.existsSync(handoffsDir)) {
      const handoffFiles = fsSync.readdirSync(handoffsDir);
      pendingHandoffs = handoffFiles.filter(f => f.endsWith('.json')).length;
    }

    res.json({
      ...agent,
      runtime: {
        ...runtimeInfo,
        pending_handoffs: pendingHandoffs
      },
      health_status: agent.status === 'active' ? 'healthy' :
                     agent.status === 'idle' ? 'standby' : 'offline'
    });

  } catch (error) {
    console.error('Error fetching agent details:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

/**
 * POST /api/agentstudio/agents
 * Create a new agent from template
 */
app.post('/api/agentstudio/agents',
  controlLimiter,
  async (req, res) => {
  try {
    const { id, name, type, category, template, config, capabilities } = req.body;

    // Validate required fields
    if (!id || !name || !type) {
      return res.status(400).json({
        error: 'Missing required fields: id, name, type'
      });
    }

    // Validate ID format (alphanumeric and dashes only)
    if (!/^[a-zA-Z0-9-]+$/.test(id)) {
      return res.status(400).json({
        error: 'Invalid agent ID format. Use only alphanumeric characters and dashes.'
      });
    }

    const registryPath = path.join(COMMIT_RELAY_HOME, 'coordination/agentstudio/registry/agents.json');

    if (!fsSync.existsSync(registryPath)) {
      return res.status(500).json({ error: 'Agent registry not found' });
    }

    const registry = JSON.parse(fsSync.readFileSync(registryPath, 'utf-8'));

    // Check if agent already exists
    if (registry.agents[id]) {
      return res.status(409).json({
        error: `Agent already exists: ${id}`
      });
    }

    // Load template if specified
    let baseAgent = {};
    if (template) {
      const templatePath = path.join(COMMIT_RELAY_HOME, `coordination/agentstudio/templates/${template}.json`);
      if (fsSync.existsSync(templatePath)) {
        baseAgent = JSON.parse(fsSync.readFileSync(templatePath, 'utf-8'));
      }
    }

    // Create new agent
    const timestamp = new Date().toISOString();
    const newAgent = {
      ...baseAgent,
      id,
      name,
      type,
      category: category || 'custom',
      description: req.body.description || `Custom agent: ${name}`,
      status: 'idle',
      version: '1.0.0',
      config: config || {
        context_dir: `coordination/agents/${id}/context`,
        knowledge_base: `coordination/agents/${id}/knowledge-base`
      },
      capabilities: capabilities || baseAgent.capabilities || [],
      integrations: req.body.integrations || [],
      metrics: {},
      created_at: timestamp,
      updated_at: timestamp
    };

    // Add to registry
    registry.agents[id] = newAgent;
    registry.updated_at = timestamp;

    // Write back to registry
    fsSync.writeFileSync(registryPath, JSON.stringify(registry, null, 2));

    // Create agent directories
    const agentDir = path.join(COMMIT_RELAY_HOME, `coordination/agents/${id}`);
    fsSync.mkdirSync(path.join(agentDir, 'context'), { recursive: true });
    fsSync.mkdirSync(path.join(agentDir, 'knowledge-base'), { recursive: true });

    // Emit event
    emitSystemEvent('agent_created', {
      agent_id: id,
      agent_name: name,
      agent_type: type,
      message: `New agent created: ${name}`
    });

    res.status(201).json({
      success: true,
      agent: newAgent,
      message: `Agent created successfully: ${id}`
    });

  } catch (error) {
    console.error('Error creating agent:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

/**
 * PATCH /api/agentstudio/agents/:id
 * Update an existing agent
 */
app.patch('/api/agentstudio/agents/:id',
  controlLimiter,
  async (req, res) => {
  try {
    const { id } = req.params;
    const updates = req.body;

    const registryPath = path.join(COMMIT_RELAY_HOME, 'coordination/agentstudio/registry/agents.json');

    if (!fsSync.existsSync(registryPath)) {
      return res.status(404).json({ error: 'Agent registry not found' });
    }

    const registry = JSON.parse(fsSync.readFileSync(registryPath, 'utf-8'));

    if (!registry.agents[id]) {
      return res.status(404).json({ error: `Agent not found: ${id}` });
    }

    // Update agent (don't allow changing id)
    delete updates.id;
    delete updates.created_at;

    const timestamp = new Date().toISOString();
    registry.agents[id] = {
      ...registry.agents[id],
      ...updates,
      updated_at: timestamp
    };
    registry.updated_at = timestamp;

    // Write back to registry
    fsSync.writeFileSync(registryPath, JSON.stringify(registry, null, 2));

    // Emit event if status changed
    if (updates.status) {
      emitSystemEvent('agent_status_changed', {
        agent_id: id,
        new_status: updates.status,
        message: `Agent ${id} status changed to ${updates.status}`
      });
    }

    res.json({
      success: true,
      agent: registry.agents[id],
      message: `Agent updated successfully: ${id}`
    });

  } catch (error) {
    console.error('Error updating agent:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

/**
 * GET /api/agentstudio/registry/summary
 * Get registry summary statistics
 */
app.get('/api/agentstudio/registry/summary',
  getLimiter,
  async (req, res) => {
  try {
    const registryPath = path.join(COMMIT_RELAY_HOME, 'coordination/agentstudio/registry/agents.json');

    if (!fsSync.existsSync(registryPath)) {
      return res.json({
        total_agents: 0,
        by_status: {},
        by_type: {},
        by_category: {}
      });
    }

    const registry = JSON.parse(fsSync.readFileSync(registryPath, 'utf-8'));
    const agents = Object.values(registry.agents || {});

    // Calculate statistics
    const byStatus = {};
    const byType = {};
    const byCategory = {};

    agents.forEach(agent => {
      // By status
      byStatus[agent.status] = (byStatus[agent.status] || 0) + 1;
      // By type
      byType[agent.type] = (byType[agent.type] || 0) + 1;
      // By category
      byCategory[agent.category] = (byCategory[agent.category] || 0) + 1;
    });

    res.json({
      total_agents: agents.length,
      by_status: byStatus,
      by_type: byType,
      by_category: byCategory,
      categories: registry.categories || [],
      agent_types: Object.keys(registry.agent_types || {}),
      last_updated: registry.updated_at
    });

  } catch (error) {
    console.error('Error fetching registry summary:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

/**
 * GET /api/agentstudio/templates
 * List available agent templates
 */
app.get('/api/agentstudio/templates',
  getLimiter,
  async (req, res) => {
  try {
    const templatesDir = path.join(COMMIT_RELAY_HOME, 'coordination/agentstudio/templates');

    if (!fsSync.existsSync(templatesDir)) {
      return res.json({ templates: [] });
    }

    const files = fsSync.readdirSync(templatesDir);
    const templates = [];

    for (const file of files) {
      if (file.endsWith('.json')) {
        try {
          const templatePath = path.join(templatesDir, file);
          const template = JSON.parse(fsSync.readFileSync(templatePath, 'utf-8'));
          templates.push({
            id: file.replace('.json', ''),
            name: template.name || file.replace('.json', ''),
            type: template.type,
            category: template.category,
            description: template.description,
            capabilities: template.capabilities || []
          });
        } catch (e) {
          // Skip invalid templates
        }
      }
    }

    res.json({ templates });

  } catch (error) {
    console.error('Error fetching templates:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// ============================================================================
// Security & CVE Monitoring Endpoints
// ============================================================================

/**
 * GET /api/security/scans
 * Get security scan history with CVE tracking and APM instrumentation
 */
app.get('/api/security/scans',
  getLimiter,
  async (req, res) => {
  const { withCustomSpan, addLabels } = require('./utils/apm-events');

  try {
    const timeRange = req.query.range || '30d'; // 1h, 6h, 24h, 7d, 30d
    const scanHistoryFile = path.join(__dirname, '../../coordination/metrics/security-scan-history.jsonl');

    // Read security scan history with custom span
    const scanHistory = await withCustomSpan('security-scan-history-read', 'db.read', async () => {
      if (!fsSync.existsSync(scanHistoryFile)) {
        return [];
      }

      const content = fsSync.readFileSync(scanHistoryFile, 'utf-8');
      return content
        .trim()
        .split('\n')
        .filter(line => line)
        .map(line => {
          try {
            return JSON.parse(line);
          } catch (e) {
            return null;
          }
        })
        .filter(item => item !== null);
    });

    // Filter by time range
    const now = Date.now();
    const rangeMs = {
      '1h': 3600000,
      '6h': 21600000,
      '24h': 86400000,
      '7d': 604800000,
      '30d': 2592000000
    }[timeRange] || 2592000000;

    const filteredScans = scanHistory.filter(scan => {
      if (!scan.initiated_at) return false;
      const timestamp = new Date(scan.initiated_at).getTime();
      return (now - timestamp) <= rangeMs;
    });

    // Calculate security metrics
    const completedScans = filteredScans.filter(s => s.status === 'completed');
    const latestScan = completedScans.length > 0 ? completedScans[completedScans.length - 1] : null;

    const totalFindings = {
      critical: 0,
      high: 0,
      medium: 0,
      low: 0,
      total: 0
    };

    let highestRiskLevel = 'LOW';
    const riskLevelPriority = { 'CRITICAL': 4, 'HIGH': 3, 'MEDIUM': 2, 'LOW': 1 };

    completedScans.forEach(scan => {
      if (scan.findings) {
        totalFindings.critical += scan.findings.critical || 0;
        totalFindings.high += scan.findings.high || 0;
        totalFindings.medium += scan.findings.medium || 0;
        totalFindings.low += scan.findings.low || 0;
        totalFindings.total += scan.findings.total || 0;

        if (scan.risk_level && riskLevelPriority[scan.risk_level] > riskLevelPriority[highestRiskLevel]) {
          highestRiskLevel = scan.risk_level;
        }
      }
    });

    // Calculate trend (comparing latest vs average)
    const avgCritical = completedScans.length > 0 ? totalFindings.critical / completedScans.length : 0;
    const trend = latestScan?.findings?.critical > avgCritical ? 'increasing' : 'decreasing';

    const responseData = {
      summary: {
        totalScans: filteredScans.length,
        completedScans: completedScans.length,
        timeRange,
        latestScan: latestScan ? {
          task_id: latestScan.task_id,
          completed_at: latestScan.completed_at,
          findings: latestScan.findings,
          risk_level: latestScan.risk_level
        } : null,
        highestRiskLevel,
        trend
      },
      aggregatedFindings: totalFindings,
      scanHistory: filteredScans.slice(-20).reverse(), // Last 20 scans
      vulnerabilityTrend: completedScans.map(scan => ({
        timestamp: scan.completed_at || scan.initiated_at,
        critical: scan.findings?.critical || 0,
        high: scan.findings?.high || 0,
        medium: scan.findings?.medium || 0,
        low: scan.findings?.low || 0,
        risk_level: scan.risk_level
      }))
    };

    // Add APM labels for security metrics
    addLabels({
      'security.total_scans': filteredScans.length,
      'security.critical_findings': latestScan?.findings?.critical || 0,
      'security.high_findings': latestScan?.findings?.high || 0,
      'security.medium_findings': latestScan?.findings?.medium || 0,
      'security.total_vulnerabilities': latestScan?.findings?.total || 0,
      'security.risk_level': highestRiskLevel,
      'security.trend': trend
    });

    res.json(responseData);

  } catch (error) {
    console.error('Error reading security scans:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

/**
 * GET /api/security/current
 * Get current security posture with real-time CVE status
 */
app.get('/api/security/current',
  getLimiter,
  async (req, res) => {
  const { addLabels } = require('./utils/apm-events');

  try {
    const scanHistoryFile = path.join(__dirname, '../../coordination/metrics/security-scan-history.jsonl');

    // Get latest completed scan
    let latestScan = null;
    if (fsSync.existsSync(scanHistoryFile)) {
      const content = fsSync.readFileSync(scanHistoryFile, 'utf-8');
      const scans = content
        .trim()
        .split('\n')
        .filter(line => line)
        .map(line => {
          try {
            return JSON.parse(line);
          } catch (e) {
            return null;
          }
        })
        .filter(item => item !== null && item.status === 'completed');

      latestScan = scans.length > 0 ? scans[scans.length - 1] : null;
    }

    const currentStatus = {
      lastScanned: latestScan?.completed_at || null,
      riskLevel: latestScan?.risk_level || 'UNKNOWN',
      findings: latestScan?.findings || { critical: 0, high: 0, medium: 0, low: 0, total: 0 },
      requiresAttention: (latestScan?.findings?.critical || 0) > 0 || (latestScan?.findings?.high || 0) > 0,
      healthScore: latestScan?.findings ? calculateSecurityScore(latestScan.findings) : 0
    };

    // Add APM labels
    addLabels({
      'security.current_risk': currentStatus.riskLevel,
      'security.health_score': currentStatus.healthScore,
      'security.requires_attention': currentStatus.requiresAttention ? 1 : 0
    });

    res.json(currentStatus);

  } catch (error) {
    console.error('Error reading current security status:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

/**
 * Calculate security health score (0-100)
 * Lower is worse, higher is better
 */
function calculateSecurityScore(findings) {
  const weights = {
    critical: -40,
    high: -15,
    medium: -5,
    low: -1
  };

  let score = 100;
  score += (findings.critical || 0) * weights.critical;
  score += (findings.high || 0) * weights.high;
  score += (findings.medium || 0) * weights.medium;
  score += (findings.low || 0) * weights.low;

  return Math.max(0, Math.min(100, score));
}

// ============================================================================
// Error Handler Middleware with APM Integration
// ============================================================================

const { captureException } = require('./utils/apm-events');

// Global error handler (must be last middleware)
app.use((err, req, res, next) => {
  // Capture exception in APM with context
  captureException(err, {
    operation: `${req.method} ${req.path}`,
    metadata: {
      request: {
        method: req.method,
        path: req.path,
        query: req.query,
        ip: req.ip
      }
    }
  });

  // Log error
  console.error('Error:', err);

  // Send error response
  const statusCode = err.statusCode || err.status || 500;
  res.status(statusCode).json({
    error: process.env.NODE_ENV === 'production'
      ? 'Internal server error'
      : err.message,
    ...(process.env.NODE_ENV !== 'production' && { stack: err.stack })
  });
});

// ============================================================================
// WebSocket Server for Real-time Updates
// ============================================================================

const server = app.listen(PORT, () => {
  console.log(`\n┌─────────────────────────────────────────────────────┐`);
  console.log(`│  Commit-Relay API Server                            │`);
  console.log(`├─────────────────────────────────────────────────────┤`);
  console.log(`│  HTTP Server:   http://localhost:${PORT}              │`);
  console.log(`│  WebSocket:     ws://localhost:${PORT}                │`);
  console.log(`│  SSE Streaming: /api/logs/stream                    │`);
  console.log(`└─────────────────────────────────────────────────────┘\n`);
});

const wss = new WebSocketServer({ server });

// Track connected WebSocket clients
const clients = new Set();

wss.on('connection', async (ws) => {
  console.log('WebSocket client connected');
  clients.add(ws);

  try {
    // Send initial data
    const data = await loadCoordinationData(false); // Use cache
    const metrics = calculateMetrics(data);
    ws.send(JSON.stringify({ type: 'initial', data: metrics }));

    // Send buffered events for reconnecting clients
    if (eventBuffer.length > 0) {
      ws.send(JSON.stringify({
        type: 'buffered_events',
        events: eventBuffer,
        count: eventBuffer.length
      }));
    }

    // Send initial daemon status
    const daemonStatus = await getDaemonStatus();
    ws.send(JSON.stringify({
      type: 'daemon_status',
      data: daemonStatus
    }));

    // Send initial PM daemon status
    const pmStatePath = path.join(__dirname, '../../coordination/pm-state.json');
    const pmState = await readJSON(pmStatePath);
    const pmDaemonStatus = pmState?.pm_daemon ? {
      status: pmState.pm_daemon.pid ? 'running' : 'stopped',
      pid: pmState.pm_daemon.pid || null,
      uptime_seconds: pmState.pm_daemon.uptime_seconds || 0,
      loops_completed: pmState.pm_daemon.loops_completed || 0,
      last_loop: pmState.pm_daemon.last_loop || null,
      started_at: pmState.pm_daemon.started_at || null
    } : {
      status: 'stopped',
      pid: null,
      uptime_seconds: 0,
      loops_completed: 0,
      last_loop: null
    };
    ws.send(JSON.stringify({
      type: 'pm_daemon_status',
      data: pmDaemonStatus
    }));
  } catch (error) {
    console.error('Error sending initial data:', error);
  }

  ws.on('close', () => {
    console.log('WebSocket client disconnected');
    clients.delete(ws);
  });

  ws.on('error', (error) => {
    console.error('WebSocket error:', error);
    clients.delete(ws);
  });
});

/**
 * Broadcast update to all connected WebSocket clients
 */
function broadcastUpdate(data) {
  const metrics = calculateMetrics(data);
  const message = JSON.stringify({
    type: 'update',
    data: metrics,
    timestamp: new Date().toISOString()
  });

  clients.forEach(client => {
    if (client.readyState === 1) { // OPEN
      client.send(message);
    }
  });
}

/**
 * Emit a system event to system-events.jsonl
 * Now includes automatic JSON validation and repair
 */
function emitSystemEvent(type, data) {
  try {
    const fsSync = require('fs');
    const event = {
      id: `evt-${Date.now()}-${process.pid}`,
      timestamp: new Date().toISOString(),
      type: type,
      data: data,
      source: 'api-server'
    };

    // Use safe write with validation and repair
    const result = safeWriteJSON(FILES.systemEvents, event, true);

    if (result.success) {
      console.log(`System event emitted: ${type}`);
    } else {
      console.error(`Failed to emit system event: ${type}`, result.error);
      logValidation('ERROR', `Event emission failed for type: ${type}`, { error: result.error, event });
    }
  } catch (error) {
    console.error('Error emitting system event:', error);
    logValidation('ERROR', 'Exception in emitSystemEvent', { error: error.message, type });
  }
}

/**
 * Broadcast daemon status to all connected WebSocket clients
 */
function broadcastDaemonStatus(daemonStatus) {
  const message = JSON.stringify({
    type: 'daemon_status',
    data: daemonStatus
  });

  clients.forEach(client => {
    if (client.readyState === 1) { // OPEN
      client.send(message);
    }
  });
}

/**
 * Debounce function to batch multiple updates
 */
function debounce(func, wait) {
  let timeout;
  return function executedFunction(...args) {
    const later = () => {
      clearTimeout(timeout);
      func(...args);
    };
    clearTimeout(timeout);
    timeout = setTimeout(later, wait);
  };
}

// ============================================================================
// File Watcher for Real-time Updates
// ============================================================================

// Watch coordination JSON files (excluding events file)
const coordFiles = Object.values(FILES).filter(f => !f.endsWith('.jsonl'));
const watcher = chokidar.watch(coordFiles, {
  persistent: true,
  ignoreInitial: true,
  awaitWriteFinish: {
    stabilityThreshold: 150, // Reduced from 500ms to 150ms
    pollInterval: 50 // Reduced from 100ms to 50ms
  }
});

// Debounced handler to batch multiple file changes within 1 second
const debouncedBroadcast = debounce(async (filePath) => {
  try {
    const oldData = { ...cache }; // Save old state before refresh
    const data = await loadCoordinationData(true); // Force refresh cache

    // Check if task queue changed - generate task events
    if (filePath === FILES.taskQueue && oldData.taskQueue && data.taskQueue) {
      const taskEvents = await generateTaskEvents(data.taskQueue, oldData.taskQueue);

      // Broadcast each task event
      for (const event of taskEvents) {
        console.log(`Task event: ${event.type} - ${event.data.task_id}`);
        broadcastEvent(event);
      }
    }

    broadcastUpdate(data);
  } catch (error) {
    console.error('Error processing file changes:', error);
  }
}, 1000);

watcher.on('change', async (filePath) => {
  console.log(`File changed: ${path.basename(filePath)}`);
  debouncedBroadcast(filePath);
});

// ============================================================================
// System Events Stream Watcher
// ============================================================================

/**
 * Broadcast event to all connected WebSocket clients
 */
function broadcastEvent(event) {
  // Add to event buffer (circular buffer)
  eventBuffer.push(event);
  if (eventBuffer.length > EVENT_BUFFER_SIZE) {
    eventBuffer.shift(); // Remove oldest event
  }

  // Persist buffer to file for recovery after restart
  saveEventBuffer();

  const message = JSON.stringify({
    type: 'event',
    event: event,
    timestamp: new Date().toISOString()
  });

  clients.forEach(client => {
    if (client.readyState === 1) { // OPEN
      client.send(message);
    }
  });
}

// Debounced save function to prevent excessive file writes
let saveTimeout = null;
function saveEventBuffer() {
  // Clear existing timeout
  if (saveTimeout) {
    clearTimeout(saveTimeout);
  }

  // Set new timeout - save after 1 second of no new events
  saveTimeout = setTimeout(() => {
    try {
      const bufferFile = path.join(__dirname, '../../coordination/event-buffer.json');
      fsSync.writeFileSync(bufferFile, JSON.stringify({
        events: eventBuffer,
        savedAt: new Date().toISOString(),
        bufferSize: EVENT_BUFFER_SIZE
      }, null, 2));
      console.log(`Event buffer saved (${eventBuffer.length} events)`);
    } catch (error) {
      console.error('Failed to save event buffer:', error);
    }
  }, 1000); // 1 second debounce
}

// ============================================================================
// ELK-Style Multi-Log File Watchers
// ============================================================================

/**
 * Watch a JSONL log file and broadcast new events to both WebSocket and SSE clients
 */
function createLogWatcher(logName, logPath, shouldBroadcastWebSocket = false) {
  const watcher = chokidar.watch(logPath, {
    persistent: true,
    ignoreInitial: true,
    awaitWriteFinish: {
      stabilityThreshold: 200,
      pollInterval: 50
    }
  });

  // Track last known line count to only broadcast new lines
  let lastLineCount = 0;

  watcher.on('change', async () => {
    try {
      if (!fsSync.existsSync(logPath)) return;

      const content = fsSync.readFileSync(logPath, 'utf-8');
      const lines = content.trim().split('\n').filter(line => line);

      // Get only new lines since last check
      const newLines = lines.slice(lastLineCount);
      lastLineCount = lines.length;

      if (newLines.length > 0) {
        newLines.forEach(line => {
          try {
            const event = JSON.parse(line);
            const normalizedEvent = logName === 'system-events' ? normalizeEvent(event) : event;

            // Broadcast to SSE clients (ELK-style streaming)
            broadcastLogEvent(logName, normalizedEvent);

            // For system-events, also broadcast to WebSocket (backward compatibility)
            if (shouldBroadcastWebSocket && logName === 'system-events') {
              broadcastEvent(normalizedEvent);
            }

            console.log(`${logName}: ${normalizedEvent.type || 'event'}`);
          } catch (parseError) {
            console.error(`Error parsing ${logName} line:`, parseError);
          }
        });
      }
    } catch (error) {
      console.error(`Error processing ${logName}:`, error);
    }
  });

  return watcher;
}

// Watch system-events.jsonl (main event stream)
const eventWatcher = createLogWatcher('system-events', FILES.systemEvents, true);

// Watch additional log files for ELK-style streaming
const logWatchers = [];

const additionalLogs = [
  { name: 'health-reports', path: path.join(COORD_DIR, 'health-reports.jsonl') },
  { name: 'pm-activity', path: path.join(COORD_DIR, 'pm-activity.jsonl') },
  { name: 'git-operations', path: path.join(COORD_DIR, 'git-operations.jsonl') },
  { name: 'metrics-snapshots', path: path.join(COORD_DIR, 'metrics-snapshots.jsonl') },
  { name: 'governance-audit', path: path.join(COORD_DIR, 'governance/audit-trail.jsonl') }
];

additionalLogs.forEach(log => {
  if (fsSync.existsSync(log.path)) {
    logWatchers.push(createLogWatcher(log.name, log.path, false));
    console.log(`Watching ${log.name} for SSE streaming`);
  }
});

// ============================================================================
// DDQD Testing API Endpoints
// ============================================================================

const ddqdTests = new Map(); // Store active DDQD tests
const DDQD_STATE_FILE = path.join(__dirname, '../../coordination/ddqd-active-tests.json');

// Save active DDQD tests to disk
function saveDDQDState() {
  try {
    const tests = Array.from(ddqdTests.entries()).map(([testId, test]) => ({
      testId,
      version: test.version,
      duration: test.duration,
      maxWorkers: test.maxWorkers,
      verbose: test.verbose,
      startTime: test.startTime,
      status: test.status,
      progress: test.progress,
      pid: test.process?.pid
    }));
    fsSync.writeFileSync(DDQD_STATE_FILE, JSON.stringify({ tests }, null, 2));
  } catch (error) {
    console.error('Error saving DDQD state:', error);
  }
}

// Load active DDQD tests from disk on startup
function loadDDQDState() {
  try {
    if (fsSync.existsSync(DDQD_STATE_FILE)) {
      const { tests } = JSON.parse(fsSync.readFileSync(DDQD_STATE_FILE, 'utf8'));
      const now = Date.now();

      tests.forEach(test => {
        const startTime = new Date(test.startTime).getTime();
        const maxDuration = test.duration * 60 * 1000 + 60000; // duration + 1 min grace

        // Only restore tests that should still be running
        if (now - startTime < maxDuration && test.status === 'running') {
          ddqdTests.set(test.testId, {
            ...test,
            output: [],
            process: null, // Can't restore process handle
            restoredFromDisk: true
          });
          console.log(`📦 Restored DDQD test: ${test.testId}`);
        }
      });

      // Clean up old state file
      if (tests.length === 0 || ddqdTests.size === 0) {
        fsSync.unlinkSync(DDQD_STATE_FILE);
      }
    }
  } catch (error) {
    console.error('Error loading DDQD state:', error);
  }
}

// Initialize DDQD state on server start
loadDDQDState();

// Run DDQD test
// Security: Input validation, rate limiting (expensive operation)
app.post('/api/ddqd/run',
  expensiveLimiter,
  confirmationMiddleware,
  ddqdValidationRules,
  validate,
  async (req, res) => {
    try {
      const { duration, maxWorkers, version, verbose } = req.body;

      const testId = `ddqd-${version}-${Date.now()}`;
      const startTime = new Date().toISOString();

      // Build command with validated inputs
      const scriptPath = path.join(__dirname, '../../scripts/ddqd');
      const baseDir = path.join(__dirname, '../..');

      // Validate script path
      const validatedScript = validatePath(scriptPath, baseDir);

      const env = {
        ...process.env,
        TEST_DURATION: String(parseInt(duration, 10)) // Ensure numeric
      };

      // Build args array safely
      const args = [];
      if (version === 'v5') args.push('--v5');
      if (verbose === true) args.push('--verbose');

      // Spawn DDQD process WITHOUT shell (prevents command injection)
      const ddqdProcess = spawn('bash', [validatedScript, ...args], {
        env,
        cwd: baseDir,
        shell: false,
        detached: false
      });

    const testData = {
      testId,
      version,
      duration,
      maxWorkers,
      verbose,
      startTime,
      status: 'running',
      progress: 0,
      output: [],
      process: ddqdProcess
    };

    // Capture output
    ddqdProcess.stdout.on('data', (data) => {
      testData.output.push(data.toString());
    });

    ddqdProcess.stderr.on('data', (data) => {
      testData.output.push(data.toString());
    });

    ddqdProcess.on('close', (code) => {
      testData.status = code === 0 ? 'completed' : 'failed';
      testData.progress = 100;
      testData.endTime = new Date().toISOString();
      testData.exitCode = code;

      // Extract routing accuracy from MoE metrics file
      let routingAccuracy = null;
      if (version === 'v5') {
        try {
          const moeMetricsPath = path.join(__dirname, `../../coordination/stress-test/${testId}-moe-metrics.json`);
          if (fsSync.existsSync(moeMetricsPath)) {
            const moeData = JSON.parse(fsSync.readFileSync(moeMetricsPath, 'utf8'));
            routingAccuracy = moeData.routing_accuracy || null;
          }
        } catch (err) {
          console.warn('Could not extract routing accuracy:', err.message);
        }
      }

      // Save to history
      const historyPath = path.join(__dirname, '../../coordination/ddqd-history.json');
      const history = fsSync.existsSync(historyPath) ? JSON.parse(fsSync.readFileSync(historyPath, 'utf8')) : { tests: [] };
      history.tests.unshift({
        testId,
        version,
        duration: Math.floor((new Date(testData.endTime) - new Date(testData.startTime)) / 1000),
        status: testData.status,
        routingAccuracy,
        timestamp: testData.endTime
      });
      history.tests = history.tests.slice(0, 50); // Keep last 50
      fsSync.writeFileSync(historyPath, JSON.stringify(history, null, 2));

      // Update state on disk
      saveDDQDState();

      // Clean up after 5 minutes
      setTimeout(() => {
        ddqdTests.delete(testId);
        saveDDQDState();
      }, 5 * 60 * 1000);
    });

    ddqdTests.set(testId, testData);
    saveDDQDState(); // Persist immediately

    res.json({ success: true, testId, message: 'DDQD test started' });
  } catch (error) {
    console.error('Error starting DDQD test:', error);
    res.status(500).json({ success: false, error: error.message });
  }
});

// Get DDQD test status
app.get('/api/ddqd/status/:testId', (req, res) => {
  try {
    const { testId } = req.params;
    const test = ddqdTests.get(testId);

    if (!test) {
      return res.status(404).json({ error: 'Test not found' });
    }

    // Calculate progress based on elapsed time
    if (test.status === 'running') {
      const elapsed = Date.now() - new Date(test.startTime).getTime();
      const totalDuration = test.duration * 60 * 1000;
      test.progress = Math.min(Math.floor((elapsed / totalDuration) * 100), 99);
      saveDDQDState(); // Update progress on disk
    }

    // Get output - either from memory or from log file for restored tests
    let recentOutput = '';
    if (test.output && test.output.length > 0) {
      // In-memory output from active process
      recentOutput = test.output.slice(-50).join('');
    } else if (test.restoredFromDisk) {
      // Read from log file for restored tests
      try {
        const logPath = path.join(__dirname, `../../agents/logs/stress-test/${testId}.log`);
        if (fsSync.existsSync(logPath)) {
          const logContent = fsSync.readFileSync(logPath, 'utf8');
          const lines = logContent.split('\n').filter(l => l.trim());
          recentOutput = lines.slice(-50).join('\n');
        }
      } catch (err) {
        console.warn('Could not read log file:', err.message);
      }
    }

    // Check if test should be marked as completed
    if (test.status === 'running' && test.restoredFromDisk) {
      const metricsPath = path.join(__dirname, `../../coordination/stress-test/${testId}-metrics.json`);
      const reportPath = path.join(__dirname, `../../coordination/stress-test/${testId}-report.txt`);
      if (fsSync.existsSync(reportPath) || fsSync.existsSync(metricsPath)) {
        // Test has completed, update status
        test.status = 'completed';
        test.progress = 100;
        saveDDQDState();
      }
    }

    res.json({
      testId: test.testId,
      status: test.status,
      progress: test.progress,
      output: recentOutput
    });
  } catch (error) {
    console.error('Error getting DDQD status:', error);
    res.status(500).json({ error: error.message });
  }
});

// Stop DDQD test
app.post('/api/ddqd/stop/:testId', (req, res) => {
  try {
    const { testId } = req.params;
    const test = ddqdTests.get(testId);

    if (!test) {
      return res.status(404).json({ success: false, error: 'Test not found' });
    }

    if (test.status === 'running' && test.process) {
      test.process.kill('SIGTERM');
      test.status = 'stopped';
      test.progress = test.progress;
      saveDDQDState();
    }

    res.json({ success: true, message: 'Test stopped' });
  } catch (error) {
    console.error('Error stopping DDQD test:', error);
    res.status(500).json({ success: false, error: error.message });
  }
});

// Get active DDQD tests
app.get('/api/ddqd/active', (req, res) => {
  try {
    const activeTests = Array.from(ddqdTests.values())
      .filter(test => test.status === 'running')
      .map(test => ({
        testId: test.testId,
        version: test.version,
        duration: test.duration,
        startTime: test.startTime,
        progress: test.progress
      }));
    res.json({ tests: activeTests });
  } catch (error) {
    console.error('Error getting active DDQD tests:', error);
    res.status(500).json({ error: error.message });
  }
});

// Get DDQD test history
app.get('/api/ddqd/history', (req, res) => {
  try {
    const historyPath = path.join(__dirname, '../../coordination/ddqd-history.json');

    if (!fsSync.existsSync(historyPath)) {
      return res.json({ tests: [] });
    }

    const history = JSON.parse(fsSync.readFileSync(historyPath, 'utf8'));
    res.json(history);
  } catch (error) {
    console.error('Error getting DDQD history:', error);
    res.status(500).json({ error: error.message });
  }
});

// Save DDQD schedule
app.post('/api/ddqd/schedule', (req, res) => {
  try {
    const { enabled, cronExpression, testConfig } = req.body;

    const schedulePath = path.join(__dirname, '../../coordination/ddqd-schedule.json');
    const schedule = {
      enabled,
      cronExpression,
      testConfig,
      updatedAt: new Date().toISOString()
    };

    // Calculate next run time (simplified - in production use cron-parser)
    let nextRun = null;
    if (enabled) {
      nextRun = new Date(Date.now() + 3600000).toISOString(); // Placeholder: +1 hour
    }
    schedule.nextRun = nextRun;

    fsSync.writeFileSync(schedulePath, JSON.stringify(schedule, null, 2));

    res.json({ success: true, message: 'Schedule saved' });
  } catch (error) {
    console.error('Error saving DDQD schedule:', error);
    res.status(500).json({ success: false, error: error.message });
  }
});

// Get DDQD schedule
app.get('/api/ddqd/schedule', (req, res) => {
  try {
    const schedulePath = path.join(__dirname, '../../coordination/ddqd-schedule.json');

    if (!fsSync.existsSync(schedulePath)) {
      return res.json({
        enabled: false,
        cronExpression: '0 2 * * *',
        nextRun: null
      });
    }

    const schedule = JSON.parse(fsSync.readFileSync(schedulePath, 'utf8'));
    res.json(schedule);
  } catch (error) {
    console.error('Error getting DDQD schedule:', error);
    res.status(500).json({ error: error.message });
  }
});

// ============================================================================
// User Management API Endpoints
// ============================================================================

// In-memory user store (in production, this would be a database)
const users = new Map();
let userIdCounter = 1;

// Helper function to validate user data
function validateUserData(userData) {
  const errors = [];

  if (!userData.username || typeof userData.username !== 'string' || userData.username.trim().length < 3) {
    errors.push('Username must be at least 3 characters');
  }

  if (!userData.email || typeof userData.email !== 'string' || !userData.email.match(/^[^\s@]+@[^\s@]+\.[^\s@]+$/)) {
    errors.push('Valid email is required');
  }

  if (userData.role && !['admin', 'developer', 'viewer'].includes(userData.role)) {
    errors.push('Role must be one of: admin, developer, viewer');
  }

  return errors;
}

// GET /api/users - List all users
app.get('/api/users', async (req, res) => {
  try {
    const { role, active, search, limit = 100, offset = 0 } = req.query;

    let userList = Array.from(users.values());

    // Filter by role
    if (role) {
      userList = userList.filter(u => u.role === role);
    }

    // Filter by active status
    if (active !== undefined) {
      const isActive = active === 'true';
      userList = userList.filter(u => u.active === isActive);
    }

    // Search by username or email
    if (search) {
      const searchLower = search.toLowerCase();
      userList = userList.filter(u =>
        u.username.toLowerCase().includes(searchLower) ||
        u.email.toLowerCase().includes(searchLower)
      );
    }

    // Pagination
    const total = userList.length;
    const limitNum = parseInt(limit);
    const offsetNum = parseInt(offset);
    userList = userList.slice(offsetNum, offsetNum + limitNum);

    res.json({
      success: true,
      data: userList,
      pagination: {
        total,
        limit: limitNum,
        offset: offsetNum,
        hasMore: offsetNum + limitNum < total
      }
    });
  } catch (error) {
    console.error('Error fetching users:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to fetch users',
      message: sanitizeError(error.message)
    });
  }
});

// GET /api/users/:id - Get a specific user
app.get('/api/users/:id', async (req, res) => {
  try {
    const userId = parseInt(req.params.id);

    if (isNaN(userId)) {
      return res.status(400).json({
        success: false,
        error: 'Invalid user ID'
      });
    }

    const user = users.get(userId);

    if (!user) {
      return res.status(404).json({
        success: false,
        error: 'User not found'
      });
    }

    res.json({
      success: true,
      data: user
    });
  } catch (error) {
    console.error('Error fetching user:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to fetch user',
      message: sanitizeError(error.message)
    });
  }
});

// POST /api/users - Create a new user
app.post('/api/users', async (req, res) => {
  try {
    const { username, email, role = 'viewer', active = true, metadata = {} } = req.body;

    // Validate user data
    const validationErrors = validateUserData({ username, email, role });
    if (validationErrors.length > 0) {
      return res.status(400).json({
        success: false,
        error: 'Validation failed',
        details: validationErrors
      });
    }

    // Check for duplicate username or email
    const existingUser = Array.from(users.values()).find(
      u => u.username === username || u.email === email
    );

    if (existingUser) {
      return res.status(409).json({
        success: false,
        error: 'User already exists with this username or email'
      });
    }

    // Create new user
    const newUser = {
      id: userIdCounter++,
      username: username.trim(),
      email: email.trim(),
      role,
      active,
      metadata,
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString()
    };

    users.set(newUser.id, newUser);

    console.log(`✅ Created user: ${newUser.username} (ID: ${newUser.id})`);

    res.status(201).json({
      success: true,
      data: newUser,
      message: 'User created successfully'
    });
  } catch (error) {
    console.error('Error creating user:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to create user',
      message: sanitizeError(error.message)
    });
  }
});

// PUT /api/users/:id - Update an existing user
app.put('/api/users/:id', async (req, res) => {
  try {
    const userId = parseInt(req.params.id);

    if (isNaN(userId)) {
      return res.status(400).json({
        success: false,
        error: 'Invalid user ID'
      });
    }

    const existingUser = users.get(userId);

    if (!existingUser) {
      return res.status(404).json({
        success: false,
        error: 'User not found'
      });
    }

    const { username, email, role, active, metadata } = req.body;

    // Build update object with only provided fields
    const updates = {};
    if (username !== undefined) updates.username = username;
    if (email !== undefined) updates.email = email;
    if (role !== undefined) updates.role = role;
    if (active !== undefined) updates.active = active;
    if (metadata !== undefined) updates.metadata = metadata;

    // Validate updates
    const validationErrors = validateUserData({
      username: updates.username || existingUser.username,
      email: updates.email || existingUser.email,
      role: updates.role || existingUser.role
    });

    if (validationErrors.length > 0) {
      return res.status(400).json({
        success: false,
        error: 'Validation failed',
        details: validationErrors
      });
    }

    // Check for duplicate username/email (excluding current user)
    if (updates.username || updates.email) {
      const duplicate = Array.from(users.values()).find(u =>
        u.id !== userId && (
          (updates.username && u.username === updates.username) ||
          (updates.email && u.email === updates.email)
        )
      );

      if (duplicate) {
        return res.status(409).json({
          success: false,
          error: 'Username or email already in use by another user'
        });
      }
    }

    // Update user
    const updatedUser = {
      ...existingUser,
      ...updates,
      updatedAt: new Date().toISOString()
    };

    users.set(userId, updatedUser);

    console.log(`✅ Updated user: ${updatedUser.username} (ID: ${userId})`);

    res.json({
      success: true,
      data: updatedUser,
      message: 'User updated successfully'
    });
  } catch (error) {
    console.error('Error updating user:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to update user',
      message: sanitizeError(error.message)
    });
  }
});

// PATCH /api/users/:id - Partially update a user
app.patch('/api/users/:id', async (req, res) => {
  try {
    const userId = parseInt(req.params.id);

    if (isNaN(userId)) {
      return res.status(400).json({
        success: false,
        error: 'Invalid user ID'
      });
    }

    const existingUser = users.get(userId);

    if (!existingUser) {
      return res.status(404).json({
        success: false,
        error: 'User not found'
      });
    }

    const { username, email, role, active, metadata } = req.body;

    // Build partial update
    const updates = {};
    if (username !== undefined) updates.username = username.trim();
    if (email !== undefined) updates.email = email.trim();
    if (role !== undefined) updates.role = role;
    if (active !== undefined) updates.active = active;
    if (metadata !== undefined) {
      // Merge metadata instead of replacing
      updates.metadata = { ...existingUser.metadata, ...metadata };
    }

    // Validate only if username/email/role are being updated
    if (username || email || role) {
      const validationErrors = validateUserData({
        username: updates.username || existingUser.username,
        email: updates.email || existingUser.email,
        role: updates.role || existingUser.role
      });

      if (validationErrors.length > 0) {
        return res.status(400).json({
          success: false,
          error: 'Validation failed',
          details: validationErrors
        });
      }
    }

    // Update user
    const updatedUser = {
      ...existingUser,
      ...updates,
      updatedAt: new Date().toISOString()
    };

    users.set(userId, updatedUser);

    console.log(`✅ Patched user: ${updatedUser.username} (ID: ${userId})`);

    res.json({
      success: true,
      data: updatedUser,
      message: 'User updated successfully'
    });
  } catch (error) {
    console.error('Error patching user:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to update user',
      message: sanitizeError(error.message)
    });
  }
});

// DELETE /api/users/:id - Delete a user
app.delete('/api/users/:id', async (req, res) => {
  try {
    const userId = parseInt(req.params.id);

    if (isNaN(userId)) {
      return res.status(400).json({
        success: false,
        error: 'Invalid user ID'
      });
    }

    const user = users.get(userId);

    if (!user) {
      return res.status(404).json({
        success: false,
        error: 'User not found'
      });
    }

    // Soft delete option via query parameter
    if (req.query.soft === 'true') {
      user.active = false;
      user.deletedAt = new Date().toISOString();
      user.updatedAt = new Date().toISOString();
      users.set(userId, user);

      console.log(`✅ Soft deleted user: ${user.username} (ID: ${userId})`);

      return res.json({
        success: true,
        data: user,
        message: 'User soft deleted successfully'
      });
    }

    // Hard delete
    users.delete(userId);

    console.log(`✅ Deleted user: ${user.username} (ID: ${userId})`);

    res.json({
      success: true,
      data: { id: userId },
      message: 'User deleted successfully'
    });
  } catch (error) {
    console.error('Error deleting user:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to delete user',
      message: sanitizeError(error.message)
    });
  }
});

// POST /api/users/bulk - Bulk create users
app.post('/api/users/bulk', async (req, res) => {
  try {
    const { users: userList } = req.body;

    if (!Array.isArray(userList) || userList.length === 0) {
      return res.status(400).json({
        success: false,
        error: 'Request body must contain an array of users'
      });
    }

    if (userList.length > 100) {
      return res.status(400).json({
        success: false,
        error: 'Maximum 100 users can be created at once'
      });
    }

    const results = {
      created: [],
      failed: []
    };

    for (const userData of userList) {
      try {
        const { username, email, role = 'viewer', active = true, metadata = {} } = userData;

        // Validate
        const validationErrors = validateUserData({ username, email, role });
        if (validationErrors.length > 0) {
          results.failed.push({
            username,
            email,
            errors: validationErrors
          });
          continue;
        }

        // Check duplicates
        const existing = Array.from(users.values()).find(
          u => u.username === username || u.email === email
        );

        if (existing) {
          results.failed.push({
            username,
            email,
            errors: ['User already exists']
          });
          continue;
        }

        // Create user
        const newUser = {
          id: userIdCounter++,
          username: username.trim(),
          email: email.trim(),
          role,
          active,
          metadata,
          createdAt: new Date().toISOString(),
          updatedAt: new Date().toISOString()
        };

        users.set(newUser.id, newUser);
        results.created.push(newUser);
      } catch (error) {
        results.failed.push({
          username: userData.username,
          email: userData.email,
          errors: [error.message]
        });
      }
    }

    console.log(`✅ Bulk created ${results.created.length} users, ${results.failed.length} failed`);

    res.status(results.created.length > 0 ? 201 : 400).json({
      success: results.created.length > 0,
      data: {
        created: results.created.length,
        failed: results.failed.length,
        users: results.created,
        errors: results.failed
      },
      message: `Created ${results.created.length} users, ${results.failed.length} failed`
    });
  } catch (error) {
    console.error('Error bulk creating users:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to bulk create users',
      message: sanitizeError(error.message)
    });
  }
});

// GET /api/users/stats - Get user statistics
app.get('/api/users/stats', async (req, res) => {
  try {
    const allUsers = Array.from(users.values());

    const stats = {
      total: allUsers.length,
      active: allUsers.filter(u => u.active).length,
      inactive: allUsers.filter(u => !u.active).length,
      byRole: {
        admin: allUsers.filter(u => u.role === 'admin').length,
        developer: allUsers.filter(u => u.role === 'developer').length,
        viewer: allUsers.filter(u => u.role === 'viewer').length
      },
      recentlyCreated: allUsers
        .sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt))
        .slice(0, 5)
        .map(u => ({ id: u.id, username: u.username, createdAt: u.createdAt }))
    };

    res.json({
      success: true,
      data: stats
    });
  } catch (error) {
    console.error('Error fetching user stats:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to fetch user statistics',
      message: sanitizeError(error.message)
    });
  }
});

// ============================================================================
// Achievement Master Endpoints
// ============================================================================

const AchievementTracker = require('../../coordination/masters/achievement/lib/achievement-tracker');
const StrategyPlanner = require('../../coordination/masters/achievement/lib/strategy-planner');

/**
 * GET /api/achievements/progress
 * Get current achievement progress from GitHub
 */
app.get('/api/achievements/progress',
  getLimiter,
  async (req, res) => {
  const { addLabels } = require('./utils/apm-events');

  try {
    const tracker = new AchievementTracker({
      githubToken: process.env.GITHUB_TOKEN,
      username: process.env.GITHUB_USERNAME || 'ry-ops'
    });

    const progress = await tracker.getAllProgress();

    // Add APM labels
    addLabels({
      'achievement.total': progress.summary?.total_achievements || 0,
      'achievement.unlocked': progress.summary?.unlocked || 0,
      'achievement.in_progress': progress.summary?.in_progress || 0
    });

    res.json(progress);
  } catch (error) {
    console.error('Error fetching achievement progress:', error);
    res.status(500).json({ error: 'Failed to fetch achievement progress' });
  }
});

/**
 * GET /api/achievements/opportunities
 * Get achievement opportunity scores
 */
app.get('/api/achievements/opportunities',
  getLimiter,
  async (req, res) => {
  const { addLabels } = require('./utils/apm-events');

  try {
    const tracker = new AchievementTracker({
      githubToken: process.env.GITHUB_TOKEN,
      username: process.env.GITHUB_USERNAME || 'ry-ops'
    });

    const opportunities = await tracker.getOpportunityScores();

    // Add APM labels for top opportunity
    if (opportunities.top_3 && opportunities.top_3.length > 0) {
      const topOpp = opportunities.top_3[0];
      addLabels({
        'achievement.top_opportunity': topOpp.name,
        'achievement.top_score': topOpp.opportunity_score,
        'achievement.top_strategy': topOpp.automation_strategy
      });
    }

    res.json(opportunities);
  } catch (error) {
    console.error('Error fetching achievement opportunities:', error);
    res.status(500).json({ error: 'Failed to fetch achievement opportunities' });
  }
});

/**
 * GET /api/achievements/plan
 * Get strategic achievement plan
 */
app.get('/api/achievements/plan',
  getLimiter,
  async (req, res) => {
  const { addLabels } = require('./utils/apm-events');

  try {
    const planner = new StrategyPlanner({
      githubToken: process.env.GITHUB_TOKEN,
      username: process.env.GITHUB_USERNAME || 'ry-ops'
    });

    const plan = await planner.generatePlan();

    // Add APM labels
    addLabels({
      'achievement.plan_tasks': plan.task_queue?.length || 0,
      'achievement.immediate_wins': plan.gaps?.immediate_wins?.length || 0,
      'achievement.high_priority': plan.gaps?.high_priority?.length || 0
    });

    res.json(plan);
  } catch (error) {
    console.error('Error generating achievement plan:', error);
    res.status(500).json({ error: 'Failed to generate achievement plan' });
  }
});

/**
 * GET /api/achievements/definitions
 * Get achievement definitions and metadata
 */
app.get('/api/achievements/definitions',
  getLimiter,
  async (req, res) => {
  try {
    const definitionsPath = path.join(__dirname, '../../coordination/masters/achievement/config/achievement-definitions.json');
    const definitions = await readJSON(definitionsPath);

    res.json(definitions);
  } catch (error) {
    console.error('Error reading achievement definitions:', error);
    res.status(500).json({ error: 'Failed to read achievement definitions' });
  }
});

/**
 * GET /api/achievements/metrics
 * Get achievement tracking metrics and history
 */
app.get('/api/achievements/metrics',
  getLimiter,
  async (req, res) => {
  try {
    const metricsPath = path.join(__dirname, '../../coordination/masters/achievement/metrics/tracking-history.jsonl');

    if (!fsSync.existsSync(metricsPath)) {
      return res.json({
        total_tracking_events: 0,
        metrics: [],
        latest: null
      });
    }

    const content = await fs.readFile(metricsPath, 'utf-8');
    const metrics = content.trim().split('\n')
      .filter(line => line)
      .map(line => JSON.parse(line));

    const latest = metrics.length > 0 ? metrics[metrics.length - 1] : null;

    res.json({
      total_tracking_events: metrics.length,
      metrics: metrics.slice(-50), // Last 50 events
      latest: latest
    });
  } catch (error) {
    console.error('Error reading achievement metrics:', error);
    res.status(500).json({ error: 'Failed to read achievement metrics' });
  }
});

/**
 * POST /api/achievements/execute/:workflow
 * Execute achievement automation workflow
 */
app.post('/api/achievements/execute/:workflow', async (req, res) => {
  const { workflow } = req.params;
  const { feature_name, skip_review } = req.body;

  try {
    const workflowScripts = {
      'quickdraw': '../../coordination/masters/achievement/workflows/quickdraw-workflow.sh',
      'pr-automation': '../../coordination/masters/achievement/workflows/pr-automation-workflow.sh'
    };

    const scriptPath = workflowScripts[workflow];

    if (!scriptPath) {
      return res.status(400).json({ error: 'Invalid workflow name' });
    }

    const fullPath = path.join(__dirname, scriptPath);

    if (!fsSync.existsSync(fullPath)) {
      return res.status(404).json({ error: 'Workflow script not found' });
    }

    // Execute workflow in background
    const { exec } = require('child_process');
    const cmd = `bash ${fullPath} ${feature_name || ''} ${skip_review !== false ? 'true' : 'false'}`;

    exec(cmd, (error, stdout, stderr) => {
      if (error) {
        console.error(`Workflow execution error: ${error}`);
      }
      console.log(`Workflow output: ${stdout}`);
      if (stderr) console.error(`Workflow stderr: ${stderr}`);
    });

    res.json({
      success: true,
      workflow: workflow,
      message: 'Workflow execution started in background',
      feature_name: feature_name || 'auto-generated'
    });
  } catch (error) {
    console.error('Error executing achievement workflow:', error);
    res.status(500).json({ error: 'Failed to execute achievement workflow' });
  }
});

// ============================================================================
// Daemon Status Polling (WebSocket Push)
// ============================================================================

// Poll daemon status every 10 seconds and push via WebSocket
setInterval(async () => {
  if (clients.size > 0) {
    try {
      const daemonStatus = await getDaemonStatus();
      broadcastDaemonStatus(daemonStatus);
    } catch (error) {
      console.error('Error polling daemon status:', error);
    }
  }
}, 10000);

// Poll PM daemon status every 10 seconds and push via WebSocket
setInterval(async () => {
  if (clients.size > 0) {
    try {
      const pmStatePath = path.join(__dirname, '../../coordination/pm-state.json');
      const pmState = await readJSON(pmStatePath);
      const pmDaemonStatus = pmState?.pm_daemon ? {
        status: pmState.pm_daemon.pid ? 'running' : 'stopped',
        pid: pmState.pm_daemon.pid || null,
        uptime_seconds: pmState.pm_daemon.uptime_seconds || 0,
        loops_completed: pmState.pm_daemon.loops_completed || 0,
        last_loop: pmState.pm_daemon.last_loop || null,
        started_at: pmState.pm_daemon.started_at || null
      } : {
        status: 'stopped',
        pid: null,
        uptime_seconds: 0,
        loops_completed: 0,
        last_loop: null
      };

      // Broadcast to all connected clients
      clients.forEach(client => {
        if (client.readyState === 1) { // WebSocket.OPEN
          client.send(JSON.stringify({
            type: 'pm_daemon_status',
            data: pmDaemonStatus
          }));
        }
      });
    } catch (error) {
      console.error('Error polling PM daemon status:', error);
    }
  }
}, 10000);

// ============================================================================
// Graceful Shutdown
// ============================================================================

process.on('SIGINT', () => {
  console.log('\nShutting down API server...');
  watcher.close();
  eventWatcher.close();
  logWatchers.forEach(w => w.close());
  server.close(() => {
    console.log('Server closed');
    process.exit(0);
  });
});

process.on('SIGTERM', () => {
  console.log('\nShutting down API server...');
  watcher.close();
  eventWatcher.close();
  logWatchers.forEach(w => w.close());
  server.close(() => {
    console.log('Server closed');
    process.exit(0);
  });
});
