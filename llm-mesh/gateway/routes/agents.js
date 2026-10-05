// Agent Registry Routes

const express = require('express');
const router = express.Router();

// Helper function to check capabilities
function hasCapability(agentCapabilities, required) {
  if (!agentCapabilities || agentCapabilities.length === 0) {
    return false;
  }
  
  // Check for wildcard or exact match
  return agentCapabilities.some(cap => {
    if (cap === '*') return true;
    if (cap === required) return true;
    // Check wildcard patterns (e.g., "workers:*" matches "workers:spawn")
    if (cap.endsWith(':*')) {
      const prefix = cap.slice(0, -1);
      return required.startsWith(prefix);
    }
    return false;
  });
}

// Register agent
router.post('/register', async (req, res) => {
  try {
    // Authorization: Only master agents can register new agents
    if (req.agentRole !== 'master') {
      return res.status(403).json({ 
        error: 'Forbidden', 
        details: 'Only master agents can register new agents' 
      });
    }

    const { agent_id, role, capabilities, metadata } = req.body;

    if (!agent_id || !role) {
      return res.status(400).json({ error: 'agent_id and role required' });
    }

    const agent = await req.registry.register(agent_id, {
      role,
      capabilities: capabilities || [],
      metadata: metadata || {}
    });

    res.json({ success: true, agent });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// Unregister agent
router.delete('/:agentId', async (req, res) => {
  try {
    // Authorization: Only master agents can unregister agents
    // Additionally, agents can only unregister themselves unless they're masters
    if (req.agentRole !== 'master' && req.agentId !== req.params.agentId) {
      return res.status(403).json({ 
        error: 'Forbidden', 
        details: 'Insufficient privileges to unregister this agent' 
      });
    }

    const removed = await req.registry.unregister(req.params.agentId);
    res.json({ success: removed });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// Heartbeat
router.post('/:agentId/heartbeat', async (req, res) => {
  try {
    // Authorization: Agents can only send heartbeats for themselves
    if (req.agentId !== req.params.agentId) {
      return res.status(403).json({ 
        error: 'Forbidden', 
        details: 'Cannot send heartbeat for another agent' 
      });
    }

    const success = await req.registry.heartbeat(req.params.agentId);
    res.json({ success });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// Get agent
router.get('/:agentId', (req, res) => {
  try {
    // Authorization: Require workers:read or coordination:read capability
    if (!hasCapability(req.agentCapabilities, 'workers:read') && 
        !hasCapability(req.agentCapabilities, 'coordination:read')) {
      return res.status(403).json({ 
        error: 'Forbidden', 
        details: 'Insufficient privileges to read agent information' 
      });
    }

    const agent = req.registry.getAgent(req.params.agentId);
    if (agent) {
      res.json(agent);
    } else {
      res.status(404).json({ error: 'Agent not found' });
    }
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// List agents
router.get('/', (req, res) => {
  try {
    // Authorization: Require workers:read or coordination:read capability
    if (!hasCapability(req.agentCapabilities, 'workers:read') && 
        !hasCapability(req.agentCapabilities, 'coordination:read')) {
      return res.status(403).json({ 
        error: 'Forbidden', 
        details: 'Insufficient privileges to list agents' 
      });
    }

    const agents = req.registry.listAgents(req.query);
    res.json({ agents, count: agents.length });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

module.exports = router;
