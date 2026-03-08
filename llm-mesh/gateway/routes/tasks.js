// Task Management Routes

const express = require('express');
const router = express.Router();
const fs = require('fs').promises;
const path = require('path');

// Get task
router.get('/:taskId', async (req, res) => {
  try {
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
    const task = {
      task_id: req.body.task_id || `task-${Date.now()}`,
      ...req.body,
      created_at: new Date().toISOString(),
      created_by: req.agentId,
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
