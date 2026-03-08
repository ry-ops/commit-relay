/**
 * LLM Health API Routes
 *
 * Provides endpoints for monitoring LLM provider health,
 * circuit breaker states, and manual intervention.
 *
 * @module api-server/routes/llm-health
 */

'use strict';

const express = require('express');
const router = express.Router();
const path = require('path');

// Import LLM mesh components
const llmMeshPath = path.join(__dirname, '../../../llm-mesh/gateway/middleware');

let circuitBreakerManager;
let healthCheckManager;

// Lazy load to avoid initialization issues
function loadComponents() {
  if (!circuitBreakerManager) {
    try {
      const { circuitBreakerManager: cbm } = require(`${llmMeshPath}/circuit-breaker`);
      circuitBreakerManager = cbm;
    } catch (error) {
      console.warn('Could not load circuit breaker manager:', error.message);
    }
  }

  if (!healthCheckManager) {
    try {
      const { healthCheckManager: hcm } = require(`${llmMeshPath}/health-check`);
      healthCheckManager = hcm;
    } catch (error) {
      console.warn('Could not load health check manager:', error.message);
    }
  }
}

/**
 * GET /api/v1/llm/health
 * Get overall LLM system health status
 */
router.get('/health', (req, res) => {
  loadComponents();

  try {
    const overallHealth = healthCheckManager
      ? healthCheckManager.getOverallHealth()
      : { status: 'unknown', message: 'Health check manager not initialized' };

    const circuitStates = circuitBreakerManager
      ? circuitBreakerManager.getAllStates()
      : {};

    // Determine overall system health
    let systemStatus = 'healthy';
    const circuitEntries = Object.values(circuitStates);

    if (circuitEntries.some(c => c.state === 'open')) {
      systemStatus = circuitEntries.every(c => c.state === 'open') ? 'unhealthy' : 'degraded';
    }

    res.json({
      status: systemStatus,
      timestamp: new Date().toISOString(),
      health: overallHealth,
      summary: {
        totalProviders: Object.keys(circuitStates).length,
        healthyProviders: circuitEntries.filter(c => c.state === 'closed').length,
        degradedProviders: circuitEntries.filter(c => c.state === 'halfOpen').length,
        unhealthyProviders: circuitEntries.filter(c => c.state === 'open').length
      }
    });
  } catch (error) {
    res.status(500).json({
      status: 'error',
      error: error.message,
      timestamp: new Date().toISOString()
    });
  }
});

/**
 * GET /api/v1/llm/providers
 * Get detailed status for all LLM providers
 */
router.get('/providers', (req, res) => {
  loadComponents();

  try {
    const providers = {};

    // Get circuit breaker states
    const circuitStates = circuitBreakerManager
      ? circuitBreakerManager.getAllStates()
      : {};

    // Get health check status
    const healthStatus = healthCheckManager
      ? healthCheckManager.getAllStatus()
      : {};

    // Combine data for each provider
    const allProviders = new Set([
      ...Object.keys(circuitStates),
      ...Object.keys(healthStatus)
    ]);

    for (const provider of allProviders) {
      const circuit = circuitStates[provider] || {};
      const health = healthStatus[provider] || {};

      providers[provider] = {
        name: provider,
        status: circuit.state === 'closed' ? 'available' :
                circuit.state === 'halfOpen' ? 'testing' : 'unavailable',
        circuit: {
          state: circuit.state || 'unknown',
          health: circuit.health || 'unknown'
        },
        health: {
          status: health.status || 'unknown',
          lastChecked: health.lastCheck || null,
          responseTime: health.responseTime || null,
          consecutiveFailures: health.consecutiveFailures || 0,
          consecutiveSuccesses: health.consecutiveSuccesses || 0
        },
        metrics: circuit.metrics || {}
      };
    }

    res.json({
      providers,
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
 * GET /api/v1/llm/providers/:provider
 * Get detailed status for a specific provider
 */
router.get('/providers/:provider', (req, res) => {
  loadComponents();

  const { provider } = req.params;

  try {
    const circuitStates = circuitBreakerManager
      ? circuitBreakerManager.getAllStates()
      : {};

    const healthStatus = healthCheckManager
      ? healthCheckManager.getAllStatus()
      : {};

    const circuit = circuitStates[provider];
    const health = healthStatus[provider];

    if (!circuit && !health) {
      return res.status(404).json({
        error: `Provider '${provider}' not found`,
        timestamp: new Date().toISOString()
      });
    }

    // Get health history
    const history = healthCheckManager
      ? healthCheckManager.getHistory(provider, 20)
      : [];

    // Get circuit breaker stats
    const stats = circuitBreakerManager
      ? circuitBreakerManager.getStats(provider)
      : null;

    res.json({
      provider,
      status: circuit?.state === 'closed' ? 'available' :
              circuit?.state === 'halfOpen' ? 'testing' : 'unavailable',
      circuit: {
        state: circuit?.state || 'unknown',
        health: circuit?.health || 'unknown',
        metrics: circuit?.metrics || {},
        stats: stats ? {
          successful: stats.successes || 0,
          failed: stats.failures || 0,
          timedOut: stats.timeouts || 0,
          rejected: stats.rejects || 0
        } : null
      },
      health: {
        status: health?.status || 'unknown',
        lastChecked: health?.lastCheck || null,
        responseTime: health?.responseTime || null,
        consecutiveFailures: health?.consecutiveFailures || 0,
        consecutiveSuccesses: health?.consecutiveSuccesses || 0,
        history
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
 * GET /api/v1/llm/circuit-breakers
 * Get all circuit breaker states
 */
router.get('/circuit-breakers', (req, res) => {
  loadComponents();

  try {
    const states = circuitBreakerManager
      ? circuitBreakerManager.getAllStates()
      : {};

    const breakers = {};
    for (const [provider, data] of Object.entries(states)) {
      breakers[provider] = {
        state: data.state,
        health: data.health,
        metrics: {
          totalRequests: data.metrics?.totalRequests || 0,
          successfulRequests: data.metrics?.successfulRequests || 0,
          failedRequests: data.metrics?.failedRequests || 0,
          timeouts: data.metrics?.timeouts || 0,
          rejectedRequests: data.metrics?.rejectedRequests || 0,
          avgResponseTime: data.metrics?.avgResponseTime || 0,
          lastFailure: data.metrics?.lastFailure,
          lastSuccess: data.metrics?.lastSuccess
        },
        stateChanges: (data.metrics?.stateChanges || []).slice(-10)
      };
    }

    res.json({
      breakers,
      summary: {
        closed: Object.values(breakers).filter(b => b.state === 'closed').length,
        halfOpen: Object.values(breakers).filter(b => b.state === 'halfOpen').length,
        open: Object.values(breakers).filter(b => b.state === 'open').length
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
 * POST /api/v1/llm/circuit-breakers/:provider/reset
 * Manually reset a circuit breaker
 */
router.post('/circuit-breakers/:provider/reset', (req, res) => {
  loadComponents();

  const { provider } = req.params;

  try {
    if (!circuitBreakerManager) {
      return res.status(503).json({
        error: 'Circuit breaker manager not available',
        timestamp: new Date().toISOString()
      });
    }

    const state = circuitBreakerManager.getState(provider);
    if (state === 'unknown') {
      return res.status(404).json({
        error: `Circuit breaker for '${provider}' not found`,
        timestamp: new Date().toISOString()
      });
    }

    const previousState = state;
    circuitBreakerManager.reset(provider);

    // Also mark as healthy in health check
    if (healthCheckManager) {
      healthCheckManager.markHealthy(provider);
    }

    res.json({
      success: true,
      provider,
      previousState,
      currentState: 'closed',
      message: `Circuit breaker for '${provider}' has been reset`,
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
 * POST /api/v1/llm/providers/:provider/health-check
 * Trigger an immediate health check for a provider
 */
router.post('/providers/:provider/health-check', async (req, res) => {
  loadComponents();

  const { provider } = req.params;

  try {
    if (!healthCheckManager) {
      return res.status(503).json({
        error: 'Health check manager not available',
        timestamp: new Date().toISOString()
      });
    }

    const result = await healthCheckManager.checkProvider(provider);

    res.json({
      provider,
      result,
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
 * POST /api/v1/llm/health-monitoring/start
 * Start health monitoring for all providers
 */
router.post('/health-monitoring/start', (req, res) => {
  loadComponents();

  try {
    if (!healthCheckManager) {
      return res.status(503).json({
        error: 'Health check manager not available',
        timestamp: new Date().toISOString()
      });
    }

    healthCheckManager.start();

    res.json({
      success: true,
      message: 'Health monitoring started',
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
 * POST /api/v1/llm/health-monitoring/stop
 * Stop health monitoring
 */
router.post('/health-monitoring/stop', (req, res) => {
  loadComponents();

  try {
    if (!healthCheckManager) {
      return res.status(503).json({
        error: 'Health check manager not available',
        timestamp: new Date().toISOString()
      });
    }

    healthCheckManager.stop();

    res.json({
      success: true,
      message: 'Health monitoring stopped',
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
 * GET /api/v1/llm/metrics
 * Get aggregated metrics for all LLM providers
 */
router.get('/metrics', (req, res) => {
  loadComponents();

  try {
    const circuitStates = circuitBreakerManager
      ? circuitBreakerManager.getAllStates()
      : {};

    let totalRequests = 0;
    let successfulRequests = 0;
    let failedRequests = 0;
    let totalResponseTime = 0;
    let responseTimeCount = 0;

    for (const data of Object.values(circuitStates)) {
      if (data.metrics) {
        totalRequests += data.metrics.totalRequests || 0;
        successfulRequests += data.metrics.successfulRequests || 0;
        failedRequests += data.metrics.failedRequests || 0;

        if (data.metrics.avgResponseTime > 0) {
          totalResponseTime += data.metrics.avgResponseTime;
          responseTimeCount++;
        }
      }
    }

    res.json({
      metrics: {
        totalRequests,
        successfulRequests,
        failedRequests,
        successRate: totalRequests > 0
          ? ((successfulRequests / totalRequests) * 100).toFixed(2) + '%'
          : 'N/A',
        avgResponseTime: responseTimeCount > 0
          ? Math.round(totalResponseTime / responseTimeCount)
          : 0
      },
      byProvider: Object.fromEntries(
        Object.entries(circuitStates).map(([provider, data]) => [
          provider,
          data.metrics || {}
        ])
      ),
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
