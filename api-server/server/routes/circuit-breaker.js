/**
 * Circuit Breaker API Routes
 *
 * Provides endpoints for monitoring and managing circuit breakers:
 * - GET /api/circuit-breakers/metrics - Get all metrics
 * - GET /api/circuit-breakers/health - Get health status
 * - POST /api/circuit-breakers/:name/reset - Force reset a breaker
 */

const express = require('express');
const router = express.Router();
const { getCircuitBreakerManager } = require('../../../lib/circuit-breaker-integrations');

/**
 * GET /api/circuit-breakers/metrics
 * Get metrics for all circuit breakers
 */
router.get('/metrics', async (req, res) => {
  try {
    const manager = getCircuitBreakerManager();
    const metrics = manager.getAllMetrics();

    res.json({
      success: true,
      data: metrics
    });
  } catch (error) {
    console.error('Error fetching circuit breaker metrics:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to fetch circuit breaker metrics',
      message: error.message
    });
  }
});

/**
 * GET /api/circuit-breakers/health
 * Get health status of all circuit breakers
 */
router.get('/health', async (req, res) => {
  try {
    const manager = getCircuitBreakerManager();
    const health = manager.getHealthStatus();

    const statusCode = health.healthy ? 200 : 503;

    res.status(statusCode).json({
      success: true,
      data: health
    });
  } catch (error) {
    console.error('Error checking circuit breaker health:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to check circuit breaker health',
      message: error.message
    });
  }
});

/**
 * POST /api/circuit-breakers/export
 * Export metrics to file
 */
router.post('/export', async (req, res) => {
  try {
    const manager = getCircuitBreakerManager();
    const filePath = await manager.exportMetrics();

    res.json({
      success: true,
      message: 'Metrics exported successfully',
      data: {
        filePath
      }
    });
  } catch (error) {
    console.error('Error exporting circuit breaker metrics:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to export metrics',
      message: error.message
    });
  }
});

/**
 * GET /api/circuit-breakers/:breaker/state
 * Get state of a specific circuit breaker
 */
router.get('/:breaker/state', (req, res) => {
  try {
    const manager = getCircuitBreakerManager();
    const breakerName = req.params.breaker;

    let breaker;
    switch (breakerName) {
      case 'dashboard-file-read':
        breaker = manager.dashboardApi.fileReadBreaker;
        break;
      case 'dashboard-file-write':
        breaker = manager.dashboardApi.fileWriteBreaker;
        break;
      case 'dashboard-external-api':
        breaker = manager.dashboardApi.externalApiBreaker;
        break;
      case 'github':
        breaker = manager.githubApi.breaker;
        break;
      case 'worker-spawn':
        breaker = manager.workerSpawn.breaker;
        break;
      default:
        return res.status(404).json({
          success: false,
          error: 'Circuit breaker not found',
          available: [
            'dashboard-file-read',
            'dashboard-file-write',
            'dashboard-external-api',
            'github',
            'worker-spawn'
          ]
        });
    }

    res.json({
      success: true,
      data: {
        name: breakerName,
        state: breaker.getState(),
        metrics: breaker.getMetrics()
      }
    });
  } catch (error) {
    console.error('Error getting circuit breaker state:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to get circuit breaker state',
      message: error.message
    });
  }
});

/**
 * POST /api/circuit-breakers/:breaker/reset
 * Force reset a circuit breaker (requires confirmation)
 */
router.post('/:breaker/reset', (req, res) => {
  try {
    const manager = getCircuitBreakerManager();
    const breakerName = req.params.breaker;

    let breaker;
    switch (breakerName) {
      case 'dashboard-file-read':
        breaker = manager.dashboardApi.fileReadBreaker;
        break;
      case 'dashboard-file-write':
        breaker = manager.dashboardApi.fileWriteBreaker;
        break;
      case 'dashboard-external-api':
        breaker = manager.dashboardApi.externalApiBreaker;
        break;
      case 'github':
        breaker = manager.githubApi.breaker;
        break;
      case 'worker-spawn':
        breaker = manager.workerSpawn.breaker;
        break;
      default:
        return res.status(404).json({
          success: false,
          error: 'Circuit breaker not found'
        });
    }

    const oldState = breaker.getState();
    breaker.forceClose();
    const newState = breaker.getState();

    res.json({
      success: true,
      message: `Circuit breaker ${breakerName} reset successfully`,
      data: {
        name: breakerName,
        oldState,
        newState,
        metrics: breaker.getMetrics()
      }
    });
  } catch (error) {
    console.error('Error resetting circuit breaker:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to reset circuit breaker',
      message: error.message
    });
  }
});

module.exports = router;
