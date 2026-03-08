/**
 * Budget Manager Middleware
 * Enforces token and cost budgets at task, session, and daily levels
 *
 * @module llm-mesh/gateway/middleware/budget-manager
 */

const fs = require('fs');
const path = require('path');
const { calculateCost, getTotalCosts } = require('./cost-tracker');

// Path to budget configuration
const BUDGET_CONFIG_PATH = path.join(
  __dirname,
  '..', '..', '..',
  'coordination', 'config', 'token-budgets.json'
);

// Path to budget usage tracking
const BUDGET_USAGE_PATH = path.join(
  __dirname,
  '..', '..', '..',
  'coordination', 'metrics', 'budget-usage.json'
);

/**
 * Custom error for budget exceeded
 */
class BudgetExceededError extends Error {
  constructor(message, details = {}) {
    super(message);
    this.name = 'BudgetExceededError';
    this.code = 'BUDGET_EXCEEDED';
    this.details = details;
  }
}

/**
 * Load budget configuration
 * @returns {Object} Budget configuration
 */
function loadBudgetConfig() {
  try {
    if (fs.existsSync(BUDGET_CONFIG_PATH)) {
      const content = fs.readFileSync(BUDGET_CONFIG_PATH, 'utf8');
      return JSON.parse(content);
    }
  } catch (error) {
    console.error('Failed to load budget config:', error.message);
  }

  // Return defaults if config doesn't exist
  return {
    defaults: {
      task: { tokens: 10000, cost: null },
      session: { tokens: 100000, cost: 1.0 },
      daily: { tokens: 1000000, cost: 10.0 }
    },
    thresholds: {
      warn: 0.8,
      critical: 0.95
    },
    task_overrides: {}
  };
}

/**
 * Load current budget usage
 * @returns {Object} Current usage data
 */
function loadUsage() {
  try {
    if (fs.existsSync(BUDGET_USAGE_PATH)) {
      const content = fs.readFileSync(BUDGET_USAGE_PATH, 'utf8');
      return JSON.parse(content);
    }
  } catch (error) {
    console.error('Failed to load budget usage:', error.message);
  }

  return {
    tasks: {},
    sessions: {},
    daily: {
      date: new Date().toISOString().split('T')[0],
      tokens: 0,
      cost: 0,
      calls: 0
    }
  };
}

/**
 * Save budget usage
 * @param {Object} usage - Usage data to save
 */
function saveUsage(usage) {
  try {
    const usageDir = path.dirname(BUDGET_USAGE_PATH);
    if (!fs.existsSync(usageDir)) {
      fs.mkdirSync(usageDir, { recursive: true });
    }

    fs.writeFileSync(
      BUDGET_USAGE_PATH,
      JSON.stringify(usage, null, 2),
      'utf8'
    );
  } catch (error) {
    console.error('Failed to save budget usage:', error.message);
  }
}

/**
 * Get budget for a specific task type
 * @param {string} taskId - The task ID
 * @param {string} taskType - The task type
 * @returns {Object} Budget limits
 */
function getTaskBudget(taskId, taskType = 'default') {
  const config = loadBudgetConfig();

  // Check for task-specific override
  if (taskId && config.task_overrides?.[taskId]) {
    return {
      ...config.defaults.task,
      ...config.task_overrides[taskId]
    };
  }

  // Check for task-type override
  if (taskType && config.task_overrides?.[taskType]) {
    return {
      ...config.defaults.task,
      ...config.task_overrides[taskType]
    };
  }

  return config.defaults.task;
}

/**
 * Check if a budget allows the estimated usage
 * @param {string} taskId - The task ID
 * @param {number} estimatedTokens - Estimated tokens to use
 * @param {Object} options - Additional options
 * @param {string} options.sessionId - Session ID
 * @param {string} options.model - Model to use (for cost estimation)
 * @param {string} options.taskType - Task type
 * @returns {Object} Budget check result
 */
function checkBudget(taskId, estimatedTokens, options = {}) {
  const { sessionId = 'default', model = 'gpt-3.5-turbo', taskType = 'default' } = options;

  const config = loadBudgetConfig();
  const usage = loadUsage();
  const today = new Date().toISOString().split('T')[0];

  // Reset daily usage if new day
  if (usage.daily.date !== today) {
    usage.daily = {
      date: today,
      tokens: 0,
      cost: 0,
      calls: 0
    };
  }

  // Estimate cost
  const estimatedCost = calculateCost(model, estimatedTokens, estimatedTokens * 0.5);

  const result = {
    allowed: true,
    warnings: [],
    errors: [],
    budgets: {
      task: { limit: 0, used: 0, remaining: 0, percent: 0 },
      session: { limit: 0, used: 0, remaining: 0, percent: 0 },
      daily: { limit: 0, used: 0, remaining: 0, percent: 0 }
    },
    estimatedTokens,
    estimatedCost
  };

  // Check task budget
  const taskBudget = getTaskBudget(taskId, taskType);
  const taskUsage = usage.tasks[taskId] || { tokens: 0, cost: 0 };
  const taskRemaining = taskBudget.tokens - taskUsage.tokens;

  result.budgets.task = {
    limit: taskBudget.tokens,
    used: taskUsage.tokens,
    remaining: taskRemaining,
    percent: taskBudget.tokens > 0 ? (taskUsage.tokens / taskBudget.tokens) : 0
  };

  if (estimatedTokens > taskRemaining) {
    result.allowed = false;
    result.errors.push({
      level: 'task',
      message: `Task budget exceeded: ${taskUsage.tokens}/${taskBudget.tokens} tokens used, need ${estimatedTokens}`
    });
  } else if ((taskUsage.tokens + estimatedTokens) / taskBudget.tokens >= config.thresholds.critical) {
    result.warnings.push({
      level: 'task',
      threshold: 'critical',
      message: `Task budget critical: ${((taskUsage.tokens + estimatedTokens) / taskBudget.tokens * 100).toFixed(1)}% used`
    });
  } else if ((taskUsage.tokens + estimatedTokens) / taskBudget.tokens >= config.thresholds.warn) {
    result.warnings.push({
      level: 'task',
      threshold: 'warn',
      message: `Task budget warning: ${((taskUsage.tokens + estimatedTokens) / taskBudget.tokens * 100).toFixed(1)}% used`
    });
  }

  // Check session budget
  const sessionBudget = config.defaults.session;
  const sessionUsage = usage.sessions[sessionId] || { tokens: 0, cost: 0 };
  const sessionRemaining = sessionBudget.tokens - sessionUsage.tokens;

  result.budgets.session = {
    limit: sessionBudget.tokens,
    used: sessionUsage.tokens,
    remaining: sessionRemaining,
    percent: sessionBudget.tokens > 0 ? (sessionUsage.tokens / sessionBudget.tokens) : 0
  };

  if (estimatedTokens > sessionRemaining) {
    result.allowed = false;
    result.errors.push({
      level: 'session',
      message: `Session budget exceeded: ${sessionUsage.tokens}/${sessionBudget.tokens} tokens used`
    });
  } else if ((sessionUsage.tokens + estimatedTokens) / sessionBudget.tokens >= config.thresholds.critical) {
    result.warnings.push({
      level: 'session',
      threshold: 'critical',
      message: `Session budget critical: ${((sessionUsage.tokens + estimatedTokens) / sessionBudget.tokens * 100).toFixed(1)}% used`
    });
  }

  // Check daily budget
  const dailyBudget = config.defaults.daily;
  const dailyRemaining = dailyBudget.tokens - usage.daily.tokens;

  result.budgets.daily = {
    limit: dailyBudget.tokens,
    used: usage.daily.tokens,
    remaining: dailyRemaining,
    percent: dailyBudget.tokens > 0 ? (usage.daily.tokens / dailyBudget.tokens) : 0
  };

  if (estimatedTokens > dailyRemaining) {
    result.allowed = false;
    result.errors.push({
      level: 'daily',
      message: `Daily budget exceeded: ${usage.daily.tokens}/${dailyBudget.tokens} tokens used`
    });
  } else if ((usage.daily.tokens + estimatedTokens) / dailyBudget.tokens >= config.thresholds.critical) {
    result.warnings.push({
      level: 'daily',
      threshold: 'critical',
      message: `Daily budget critical: ${((usage.daily.tokens + estimatedTokens) / dailyBudget.tokens * 100).toFixed(1)}% used`
    });
  }

  // Check cost budgets if defined
  if (dailyBudget.cost && usage.daily.cost + estimatedCost > dailyBudget.cost) {
    result.allowed = false;
    result.errors.push({
      level: 'daily_cost',
      message: `Daily cost budget exceeded: $${usage.daily.cost.toFixed(4)}/$${dailyBudget.cost.toFixed(2)} used`
    });
  }

  return result;
}

/**
 * Record usage against budgets
 * @param {string} taskId - The task ID
 * @param {number} tokens - Tokens used
 * @param {number} cost - Cost incurred
 * @param {Object} options - Additional options
 * @param {string} options.sessionId - Session ID
 * @returns {Object} Updated usage
 */
function recordUsage(taskId, tokens, cost, options = {}) {
  const { sessionId = 'default' } = options;

  const usage = loadUsage();
  const today = new Date().toISOString().split('T')[0];

  // Reset daily if new day
  if (usage.daily.date !== today) {
    usage.daily = {
      date: today,
      tokens: 0,
      cost: 0,
      calls: 0
    };
  }

  // Update task usage
  if (!usage.tasks[taskId]) {
    usage.tasks[taskId] = { tokens: 0, cost: 0, calls: 0, created: new Date().toISOString() };
  }
  usage.tasks[taskId].tokens += tokens;
  usage.tasks[taskId].cost += cost;
  usage.tasks[taskId].calls++;
  usage.tasks[taskId].lastUsed = new Date().toISOString();

  // Update session usage
  if (!usage.sessions[sessionId]) {
    usage.sessions[sessionId] = { tokens: 0, cost: 0, calls: 0, created: new Date().toISOString() };
  }
  usage.sessions[sessionId].tokens += tokens;
  usage.sessions[sessionId].cost += cost;
  usage.sessions[sessionId].calls++;
  usage.sessions[sessionId].lastUsed = new Date().toISOString();

  // Update daily usage
  usage.daily.tokens += tokens;
  usage.daily.cost += cost;
  usage.daily.calls++;

  // Save updated usage
  saveUsage(usage);

  return {
    task: usage.tasks[taskId],
    session: usage.sessions[sessionId],
    daily: usage.daily
  };
}

/**
 * Get usage summary
 * @param {Object} options - Query options
 * @param {string} options.taskId - Specific task ID
 * @param {string} options.sessionId - Specific session ID
 * @returns {Object} Usage summary
 */
function getUsageSummary(options = {}) {
  const { taskId, sessionId } = options;
  const usage = loadUsage();
  const config = loadBudgetConfig();

  const summary = {
    daily: {
      ...usage.daily,
      budget: config.defaults.daily,
      percentUsed: (usage.daily.tokens / config.defaults.daily.tokens * 100).toFixed(1)
    },
    totalTasks: Object.keys(usage.tasks).length,
    totalSessions: Object.keys(usage.sessions).length
  };

  if (taskId && usage.tasks[taskId]) {
    const taskBudget = getTaskBudget(taskId);
    summary.task = {
      ...usage.tasks[taskId],
      budget: taskBudget,
      percentUsed: (usage.tasks[taskId].tokens / taskBudget.tokens * 100).toFixed(1)
    };
  }

  if (sessionId && usage.sessions[sessionId]) {
    summary.session = {
      ...usage.sessions[sessionId],
      budget: config.defaults.session,
      percentUsed: (usage.sessions[sessionId].tokens / config.defaults.session.tokens * 100).toFixed(1)
    };
  }

  return summary;
}

/**
 * Reset task budget usage
 * @param {string} taskId - The task ID to reset
 */
function resetTaskBudget(taskId) {
  const usage = loadUsage();

  if (usage.tasks[taskId]) {
    delete usage.tasks[taskId];
    saveUsage(usage);
  }
}

/**
 * Reset session budget usage
 * @param {string} sessionId - The session ID to reset
 */
function resetSessionBudget(sessionId) {
  const usage = loadUsage();

  if (usage.sessions[sessionId]) {
    delete usage.sessions[sessionId];
    saveUsage(usage);
  }
}

/**
 * Clean up old task and session data
 * @param {number} maxAgeDays - Maximum age in days (default: 7)
 */
function cleanupOldUsage(maxAgeDays = 7) {
  const usage = loadUsage();
  const cutoff = new Date();
  cutoff.setDate(cutoff.getDate() - maxAgeDays);

  let cleaned = 0;

  // Clean old tasks
  for (const [taskId, task] of Object.entries(usage.tasks)) {
    if (new Date(task.lastUsed || task.created) < cutoff) {
      delete usage.tasks[taskId];
      cleaned++;
    }
  }

  // Clean old sessions
  for (const [sessionId, session] of Object.entries(usage.sessions)) {
    if (new Date(session.lastUsed || session.created) < cutoff) {
      delete usage.sessions[sessionId];
      cleaned++;
    }
  }

  if (cleaned > 0) {
    saveUsage(usage);
  }

  return cleaned;
}

/**
 * Middleware function for Express/Connect
 * @param {Object} options - Middleware options
 * @returns {Function} Middleware function
 */
function budgetMiddleware(options = {}) {
  return async (req, res, next) => {
    const taskId = req.body?.taskId || req.query?.taskId || 'anonymous';
    const sessionId = req.sessionId || req.body?.sessionId || 'default';
    const estimatedTokens = req.body?.estimatedTokens || 1000;
    const model = req.body?.model || 'gpt-3.5-turbo';

    const result = checkBudget(taskId, estimatedTokens, { sessionId, model });

    if (!result.allowed) {
      const error = new BudgetExceededError(
        result.errors.map(e => e.message).join('; '),
        result
      );
      return next(error);
    }

    // Attach budget info to request
    req.budgetCheck = result;
    next();
  };
}

// Export functions and classes
module.exports = {
  BudgetExceededError,
  checkBudget,
  recordUsage,
  getUsageSummary,
  getTaskBudget,
  resetTaskBudget,
  resetSessionBudget,
  cleanupOldUsage,
  budgetMiddleware,
  loadBudgetConfig,
  BUDGET_CONFIG_PATH,
  BUDGET_USAGE_PATH
};
