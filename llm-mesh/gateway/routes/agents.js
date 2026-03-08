// Agent Registry Routes

const express = require('express');
const router = express.Router();

// Register agent
router.post('/register', async (req, res) => {
  try {
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
    const removed = await req.registry.unregister(req.params.agentId);
    res.json({ success: removed });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// Heartbeat
router.post('/:agentId/heartbeat', async (req, res) => {
  try {
    const success = await req.registry.heartbeat(req.params.agentId);
    res.json({ success });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// Get agent
router.get('/:agentId', (req, res) => {
  const agent = req.registry.getAgent(req.params.agentId);
  if (agent) {
    res.json(agent);
  } else {
    res.status(404).json({ error: 'Agent not found' });
  }
});

// List agents
router.get('/', (req, res) => {
  const agents = req.registry.listAgents(req.query);
  res.json({ agents, count: agents.length });
});

module.exports = router;
