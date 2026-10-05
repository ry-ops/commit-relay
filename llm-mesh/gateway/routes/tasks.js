// Task Management Routes

const express = require('express');
const router = express.Router();
const fs = require('fs').promises;
const path = require('path');

// Base directory for task storage
const TASKS_BASE_DIR = path.resolve(__dirname, '../../../coordination/tasks');

/**
 * Validates that a task ID is safe and doesn't contain path traversal sequences
 * @param {string} taskId - The task ID to validate
 * @returns {boolean} - True if valid, false otherwise
 */
function isValidTaskId(taskId) {
  if (!taskId || typeof taskId !== 'string') {
    return false;
  }
  
  // Reject path traversal sequences and path separators
  if (taskId.includes('..') || taskId.includes('/') || taskId.includes('\\')) {
    return false;
  }
  
  // Reject null bytes and other control characters
  if (/[\x00-\x1f\x7f]/.test(taskId)) {
    return false;
  }
  
  // Only allow alphanumeric, hyphens, underscores, and dots (for extensions)
  if (!/^[a-zA-Z0-9_-]+$/.test(taskId)) {
    return false;
  }
  
  // Reasonable length limit
  if (taskId.length > 255) {
    return false;
  }
  
  return true;
}

/**
 * Validates that a resolved path is contained within the base directory
 * @param {string} resolvedPath - The resolved absolute path to validate
 * @param {string} baseDir - The base directory that should contain the path
 * @returns {boolean} - True if contained, false otherwise
 */
function isPathContained(resolvedPath, baseDir) {
  const normalizedPath = path.resolve(resolvedPath);
  const normalizedBase = path.resolve(baseDir);
  
  // Check if the resolved path starts with the base directory
  return normalizedPath.startsWith(normalizedBase + path.sep) || 
         normalizedPath === normalizedBase;
}

/**
 * Checks if the agent has the required capability
 * @param {object} req - Express request object
 * @param {string} capability - Required capability (e.g., 'tasks:read', 'tasks:write')
 * @returns {boolean} - True if authorized, false otherwise
 */
function hasCapability(req, capability) {
  // If policyEnforcer is available, use it for capability checks
  if (req.policyEnforcer && typeof req.policyEnforcer.checkCapability === 'function') {
    return req.policyEnforcer.checkCapability(req.agentId, capability);
  }
  
  // Fallback: require authenticated agent for write operations
  // Read operations are allowed for any authenticated agent
  if (capability === 'tasks:write') {
    // Only allow write if agentId is set and not 'anonymous'
    return req.agentId && req.agentId !== 'anonymous';
  }
  
  return true; // Allow read for authenticated users
}

// Get task
router.get('/:taskId', async (req, res) => {
  try {
    // Validate task ID format
    if (!isValidTaskId(req.params.taskId)) {
      return res.status(400).json({ 
        error: 'Invalid task ID format',
        details: 'Task ID must contain only alphanumeric characters, hyphens, and underscores'
      });
    }
    
    // Check capability
    if (!hasCapability(req, 'tasks:read')) {
      return res.status(403).json({ 
        error: 'Insufficient permissions',
        details: 'Agent does not have tasks:read capability'
      });
    }
    
    // Construct and validate path
    const taskPath = path.join(TASKS_BASE_DIR, `${req.params.taskId}.json`);
    const resolvedPath = path.resolve(taskPath);
    
    // Verify path containment
    if (!isPathContained(resolvedPath, TASKS_BASE_DIR)) {
      return res.status(400).json({ 
        error: 'Invalid task path',
        details: 'Task path must be within the tasks directory'
      });
    }
    
    const data = await fs.readFile(resolvedPath, 'utf8');
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
    // Check capability first
    if (!hasCapability(req, 'tasks:write')) {
      return res.status(403).json({ 
        error: 'Insufficient permissions',
        details: 'Agent does not have tasks:write capability'
      });
    }
    
    // Generate or validate task_id
    const taskId = req.body.task_id || `task-${Date.now()}`;
    
    // Validate task ID format
    if (!isValidTaskId(taskId)) {
      return res.status(400).json({ 
        error: 'Invalid task ID format',
        details: 'Task ID must contain only alphanumeric characters, hyphens, and underscores'
      });
    }
    
    const task = {
      task_id: taskId,
      ...req.body,
      created_at: new Date().toISOString(),
      created_by: req.agentId,
      status: 'pending'
    };

    // Construct and validate path
    const taskPath = path.join(TASKS_BASE_DIR, `${task.task_id}.json`);
    const resolvedPath = path.resolve(taskPath);
    
    // Verify path containment
    if (!isPathContained(resolvedPath, TASKS_BASE_DIR)) {
      return res.status(400).json({ 
        error: 'Invalid task path',
        details: 'Task path must be within the tasks directory'
      });
    }
    
    await fs.writeFile(resolvedPath, JSON.stringify(task, null, 2));

    res.json({ success: true, task });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

module.exports = router;
