/**
 * Cost Tracker Middleware
 * Tracks and calculates costs for LLM API calls
 *
 * @module llm-mesh/gateway/middleware/cost-tracker
 */

const fs = require('fs');
const path = require('path');

// Pricing table (per million tokens)
const PRICING = {
  // Claude models
  'claude-3-haiku': {
    input: 0.25,    // $0.25 per 1M input tokens
    output: 1.25,   // $1.25 per 1M output tokens
    provider: 'anthropic'
  },
  'claude-haiku': {
    input: 0.25,
    output: 1.25,
    provider: 'anthropic'
  },
  'claude-3-sonnet': {
    input: 3.0,
    output: 15.0,
    provider: 'anthropic'
  },
  'claude-sonnet-4': {
    input: 3.0,     // $3.0 per 1M input tokens
    output: 15.0,   // $15.0 per 1M output tokens
    provider: 'anthropic'
  },
  'claude-3-opus': {
    input: 15.0,
    output: 75.0,
    provider: 'anthropic'
  },
  'claude-opus-4': {
    input: 15.0,
    output: 75.0,
    provider: 'anthropic'
  },

  // OpenAI models
  'gpt-4-turbo': {
    input: 10.0,    // $10.0 per 1M input tokens
    output: 30.0,   // $30.0 per 1M output tokens
    provider: 'openai'
  },
  'gpt-4o': {
    input: 5.0,
    output: 15.0,
    provider: 'openai'
  },
  'gpt-4': {
    input: 30.0,
    output: 60.0,
    provider: 'openai'
  },
  'gpt-3.5-turbo': {
    input: 0.5,     // $0.5 per 1M input tokens
    output: 1.5,    // $1.5 per 1M output tokens
    provider: 'openai'
  },

  // Local models (free)
  'llama2': {
    input: 0,
    output: 0,
    provider: 'local'
  },
  'codellama': {
    input: 0,
    output: 0,
    provider: 'local'
  },
  'mistral': {
    input: 0,
    output: 0,
    provider: 'local'
  }
};

// Default pricing for unknown models
const DEFAULT_PRICING = {
  input: 1.0,
  output: 3.0,
  provider: 'unknown'
};

// Path to cost log file
const COST_LOG_PATH = path.join(
  __dirname,
  '..', '..', '..',
  'coordination', 'metrics', 'llm-costs.jsonl'
);

/**
 * Get pricing for a model
 * @param {string} model - The model name
 * @returns {Object} Pricing information
 */
function getPricing(model) {
  // Normalize model name
  const normalizedModel = model.toLowerCase().replace(/-\d{8}$/, '');

  // Check for exact match
  if (PRICING[model]) {
    return PRICING[model];
  }

  // Check normalized version
  if (PRICING[normalizedModel]) {
    return PRICING[normalizedModel];
  }

  // Try to match partial name
  for (const [key, value] of Object.entries(PRICING)) {
    if (model.includes(key) || key.includes(model)) {
      return value;
    }
  }

  console.warn(`Unknown model: ${model}, using default pricing`);
  return DEFAULT_PRICING;
}

/**
 * Calculate cost for an API call
 * @param {string} model - The model used
 * @param {number} inputTokens - Number of input tokens
 * @param {number} outputTokens - Number of output tokens
 * @returns {number} Cost in dollars
 */
function calculateCost(model, inputTokens, outputTokens) {
  const pricing = getPricing(model);

  // Convert from per-million to per-token
  const inputCost = (inputTokens / 1000000) * pricing.input;
  const outputCost = (outputTokens / 1000000) * pricing.output;

  return parseFloat((inputCost + outputCost).toFixed(6));
}

/**
 * Get cost breakdown for an API call
 * @param {string} model - The model used
 * @param {number} inputTokens - Number of input tokens
 * @param {number} outputTokens - Number of output tokens
 * @returns {Object} Detailed cost breakdown
 */
function getCostBreakdown(model, inputTokens, outputTokens) {
  const pricing = getPricing(model);

  const inputCost = (inputTokens / 1000000) * pricing.input;
  const outputCost = (outputTokens / 1000000) * pricing.output;
  const totalCost = inputCost + outputCost;

  return {
    model,
    provider: pricing.provider,
    tokens: {
      input: inputTokens,
      output: outputTokens,
      total: inputTokens + outputTokens
    },
    rates: {
      input: pricing.input,
      output: pricing.output
    },
    costs: {
      input: parseFloat(inputCost.toFixed(6)),
      output: parseFloat(outputCost.toFixed(6)),
      total: parseFloat(totalCost.toFixed(6))
    }
  };
}

/**
 * Log cost entry to JSONL file
 * @param {Object} entry - Cost entry to log
 */
function logCost(entry) {
  const logEntry = {
    timestamp: new Date().toISOString(),
    ...entry
  };

  try {
    // Ensure directory exists
    const logDir = path.dirname(COST_LOG_PATH);
    if (!fs.existsSync(logDir)) {
      fs.mkdirSync(logDir, { recursive: true });
    }

    // Append to log file
    fs.appendFileSync(
      COST_LOG_PATH,
      JSON.stringify(logEntry) + '\n',
      'utf8'
    );
  } catch (error) {
    console.error('Failed to log cost entry:', error.message);
  }
}

/**
 * Record a completed API call with cost tracking
 * @param {Object} options - Call details
 * @param {string} options.model - The model used
 * @param {number} options.inputTokens - Number of input tokens
 * @param {number} options.outputTokens - Number of output tokens
 * @param {string} options.taskId - Optional task ID
 * @param {string} options.taskType - Type of task
 * @param {number} options.latencyMs - Response latency in milliseconds
 * @param {boolean} options.success - Whether the call succeeded
 * @returns {Object} Cost breakdown
 */
function recordCost(options) {
  const {
    model,
    inputTokens,
    outputTokens,
    taskId = null,
    taskType = 'unknown',
    latencyMs = 0,
    success = true
  } = options;

  const breakdown = getCostBreakdown(model, inputTokens, outputTokens);

  const entry = {
    task_id: taskId,
    task_type: taskType,
    model: breakdown.model,
    provider: breakdown.provider,
    tokens: breakdown.tokens,
    cost: breakdown.costs.total,
    cost_breakdown: breakdown.costs,
    latency_ms: latencyMs,
    success
  };

  logCost(entry);

  return breakdown;
}

/**
 * Get total costs from log file
 * @param {Object} options - Query options
 * @param {Date} options.since - Start date
 * @param {Date} options.until - End date
 * @param {string} options.taskId - Filter by task ID
 * @param {string} options.model - Filter by model
 * @returns {Object} Aggregated costs
 */
function getTotalCosts(options = {}) {
  const { since, until, taskId, model } = options;

  if (!fs.existsSync(COST_LOG_PATH)) {
    return {
      totalCost: 0,
      totalTokens: 0,
      callCount: 0,
      byModel: {},
      byProvider: {}
    };
  }

  const content = fs.readFileSync(COST_LOG_PATH, 'utf8');
  const lines = content.trim().split('\n').filter(line => line && !line.startsWith('#'));

  let totalCost = 0;
  let totalTokens = 0;
  let callCount = 0;
  const byModel = {};
  const byProvider = {};

  for (const line of lines) {
    try {
      const entry = JSON.parse(line);

      // Apply filters
      if (since && new Date(entry.timestamp) < since) continue;
      if (until && new Date(entry.timestamp) > until) continue;
      if (taskId && entry.task_id !== taskId) continue;
      if (model && entry.model !== model) continue;

      // Aggregate
      totalCost += entry.cost || 0;
      totalTokens += (entry.tokens?.total || 0);
      callCount++;

      // By model
      if (!byModel[entry.model]) {
        byModel[entry.model] = { cost: 0, tokens: 0, calls: 0 };
      }
      byModel[entry.model].cost += entry.cost || 0;
      byModel[entry.model].tokens += entry.tokens?.total || 0;
      byModel[entry.model].calls++;

      // By provider
      if (!byProvider[entry.provider]) {
        byProvider[entry.provider] = { cost: 0, tokens: 0, calls: 0 };
      }
      byProvider[entry.provider].cost += entry.cost || 0;
      byProvider[entry.provider].tokens += entry.tokens?.total || 0;
      byProvider[entry.provider].calls++;

    } catch (error) {
      // Skip invalid lines
    }
  }

  return {
    totalCost: parseFloat(totalCost.toFixed(6)),
    totalTokens,
    callCount,
    byModel,
    byProvider
  };
}

/**
 * Estimate cost for a planned API call
 * @param {string} model - The model to use
 * @param {number} estimatedInputTokens - Estimated input tokens
 * @param {number} estimatedOutputTokens - Estimated output tokens
 * @returns {Object} Cost estimate
 */
function estimateCost(model, estimatedInputTokens, estimatedOutputTokens) {
  const breakdown = getCostBreakdown(model, estimatedInputTokens, estimatedOutputTokens);

  return {
    model,
    estimatedCost: breakdown.costs.total,
    costBreakdown: breakdown.costs,
    tokens: breakdown.tokens,
    note: 'This is an estimate. Actual costs may vary.'
  };
}

/**
 * Get daily cost summary
 * @param {Date} date - The date to summarize (default: today)
 * @returns {Object} Daily cost summary
 */
function getDailySummary(date = new Date()) {
  const startOfDay = new Date(date);
  startOfDay.setHours(0, 0, 0, 0);

  const endOfDay = new Date(date);
  endOfDay.setHours(23, 59, 59, 999);

  return getTotalCosts({ since: startOfDay, until: endOfDay });
}

// Export functions and pricing table
module.exports = {
  calculateCost,
  getCostBreakdown,
  recordCost,
  getTotalCosts,
  estimateCost,
  getDailySummary,
  getPricing,
  logCost,
  PRICING,
  COST_LOG_PATH
};
