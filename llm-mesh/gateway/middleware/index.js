/**
 * LLM Gateway Middleware
 * Exports all middleware modules for token counting, cost tracking, and budget management
 *
 * @module llm-mesh/gateway/middleware
 */

const tokenCounter = require('./token-counter');
const costTracker = require('./cost-tracker');
const budgetManager = require('./budget-manager');
const circuitBreaker = require('./circuit-breaker');
const failover = require('./failover');
const healthCheck = require('./health-check');

module.exports = {
  // Token counting
  countTokens: tokenCounter.countTokens,
  countMessages: tokenCounter.countMessages,
  estimateOutputTokens: tokenCounter.estimateOutputTokens,
  truncateToTokens: tokenCounter.truncateToTokens,
  getTokenStats: tokenCounter.getTokenStats,
  cleanupTokenizer: tokenCounter.cleanup,

  // Cost tracking
  calculateCost: costTracker.calculateCost,
  getCostBreakdown: costTracker.getCostBreakdown,
  recordCost: costTracker.recordCost,
  getTotalCosts: costTracker.getTotalCosts,
  estimateCost: costTracker.estimateCost,
  getDailySummary: costTracker.getDailySummary,
  PRICING: costTracker.PRICING,

  // Budget management
  BudgetExceededError: budgetManager.BudgetExceededError,
  checkBudget: budgetManager.checkBudget,
  recordUsage: budgetManager.recordUsage,
  getUsageSummary: budgetManager.getUsageSummary,
  getTaskBudget: budgetManager.getTaskBudget,
  resetTaskBudget: budgetManager.resetTaskBudget,
  resetSessionBudget: budgetManager.resetSessionBudget,
  cleanupOldUsage: budgetManager.cleanupOldUsage,
  budgetMiddleware: budgetManager.budgetMiddleware,

  // Circuit breaker
  CircuitBreakerManager: circuitBreaker.CircuitBreakerManager,
  circuitBreakerManager: circuitBreaker.circuitBreakerManager,
  createProviderBreaker: circuitBreaker.createProviderBreaker,
  circuitBreakerMiddleware: circuitBreaker.circuitBreakerMiddleware,

  // Failover
  FailoverChain: failover.FailoverChain,
  failoverMiddleware: failover.failoverMiddleware,

  // Health check
  HealthCheckManager: healthCheck.HealthCheckManager,
  healthCheckManager: healthCheck.healthCheckManager,
  healthCheck: healthCheck.healthCheck,
  healthCheckMiddleware: healthCheck.healthCheckMiddleware,

  // Full module exports
  tokenCounter,
  costTracker,
  budgetManager,
  circuitBreaker,
  failover,
  healthCheck
};
