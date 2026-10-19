// Task Routing Routes

const express = require('express');
const router = express.Router();
const { spawn } = require('child_process');
const path = require('path');

// Helper function to check capabilities
function hasCapability(agentCapabilities, required) {
  if (!agentCapabilities || agentCapabilities.length === 0) {
    return false;
  }
  
  // Check for wildcard or exact match
  return agentCapabilities.some(cap => {
    if (cap === '*') return true;
    if (cap === required) return true;
    // Check wildcard patterns (e.g., "tasks:*" matches "tasks:route")
    if (cap.endsWith(':*')) {
      const prefix = cap.slice(0, -1);
      return required.startsWith(prefix);
    }
    return false;
  });
}

// Route task
router.post('/', async (req, res) => {
  try {
    // Authorization: Require tasks:route capability
    if (!hasCapability(req.agentCapabilities, 'tasks:route')) {
      return res.status(403).json({ 
        error: 'Forbidden', 
        details: 'Insufficient privileges to route tasks' 
      });
    }

    const { task_id, description, context } = req.body;

    // Validate
    const validation = req.policyEnforcer.validateRequest(req.body, ['task_id', 'description']);
    if (!validation.valid) {
      return res.status(400).json({ error: validation.error });
    }

    // Check rate limit (now using verified agent ID)
    const rateCheck = req.policyEnforcer.checkRateLimit(req.agentId);
    if (!rateCheck.allowed) {
      return res.status(429).json({ error: rateCheck.reason });
    }

    // Check circuit breaker (now using verified agent ID)
    const circuitCheck = req.policyEnforcer.checkCircuitBreaker(req.agentId);
    if (circuitCheck.open) {
      return res.status(503).json({ error: circuitCheck.reason });
    }

    // Call MoE router
    const routerPath = path.join(__dirname, '../../../coordination/masters/coordinator/lib/moe-router.sh');
    const routing = await callMoERouter(task_id, description);

    if (routing.success) {
      req.policyEnforcer.recordSuccess(req.agentId);
      res.json({
        success: true,
        routing: routing.result,
        timestamp: new Date().toISOString()
      });
    } else {
      req.policyEnforcer.recordFailure(req.agentId);
      res.status(500).json({ error: 'Routing failed', details: routing.error });
    }
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

function callMoERouter(taskId, description) {
  return new Promise((resolve) => {
    // Simplified routing response for now
    // TODO: Actually call moe-router.sh
    resolve({
      success: true,
      result: {
        primary_expert: 'development',
        primary_confidence: 0.85,
        strategy: 'single-expert'
      }
    });
  });
}

module.exports = router;
