// Task Management Routes

const express = require('express');
const router = express.Router();
const fs = require('fs').promises;
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
    // Check wildcard patterns (e.g., "tasks:*" matches "tasks:write")
    if (cap.endsWith(':*')) {
      const prefix = cap.slice(0, -1);
      return required.startsWith(prefix);
    }
    return false;
  });
}

// Get task
router.get('/:taskId', async (req, res) => {
  try {
    // Authorization: Require tasks:read capability
    if (!hasCapability(req.agentCapabilities, 'tasks:read')) {
      return res.status(403).json({ 
        error: 'Forbidden', 
        details: 'Insufficient privileges to read tasks' 
      });
    }

    const taskPath = path.join(__dirname, '../../../coordination/tasks', `${req.params.taskId}.json`);
    const data = await fs.readFile(taskPath, 'utf8');
    res.json(JSON.parse(data));
  } catch (error) {
    if (error.code === 'ENOENT') {
      res.status(404).json({ error: 'Task not found' });
    } else {
      res.status(500).json({ error: error.message });
    }
  }
});

// Create task
router.post('/', async (req, res) => {
  try {
    // Authorization: Require tasks:write capability and master role for coordination writes
    if (!hasCapability(req.agentCapabilities, 'tasks:write')) {
      return res.status(403).json({ 
        error: 'Forbidden', 
        details: 'Insufficient privileges to create tasks' 
      });
    }

    // Additional check: Only master agents can write coordination tasks
    if (req.agentRole !== 'master') {
      return res.status(403).json({ 
        error: 'Forbidden', 
        details: 'Only master agents can create coordination tasks' 
      });
    }

    const task = {
      task_id: req.body.task_id || `task-${Date.now()}`,
      ...req.body,
      created_at: new Date().toISOString(),
      created_by: req.agentId,
      created_by_spiffe: req.agentSpiffeId,
      status: 'pending'
    };

    const taskPath = path.join(__dirname, '../../../coordination/tasks', `${task.task_id}.json`);
    await fs.writeFile(taskPath, JSON.stringify(task, null, 2));

    res.json({ success: true, task });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

module.exports = router;
