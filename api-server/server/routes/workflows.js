/**
 * Workflow API Routes
 *
 * Provides REST endpoints for managing and executing workflows:
 * - GET /api/v1/workflows - List all workflows
 * - GET /api/v1/workflows/executions - List all executions across workflows
 * - GET /api/v1/workflows/executions/:id - Get execution details
 * - GET /api/v1/workflows/:name - Get workflow definition
 * - POST /api/v1/workflows/:name/execute - Trigger execution
 * - GET /api/v1/workflows/:name/executions - List executions for a workflow
 */

const express = require('express');
const router = express.Router();
const path = require('path');
const { sanitizeFilename, validateId } = require('../lib/path-validator');

// Import workflow engine
const WorkflowEngine = require('../../../lib/orchestration/workflow-engine');

// Initialize workflow engine
const workflowEngine = new WorkflowEngine({
  workflowsDir: path.join(__dirname, '../../../coordination/workflows'),
  executionsDir: path.join(__dirname, '../../../coordination/workflow-executions')
});

// Load all workflows on startup
(async () => {
  try {
    const loaded = await workflowEngine.loadAllWorkflows();
    console.log(`Loaded ${loaded.length} workflows: ${loaded.join(', ')}`);
  } catch (error) {
    console.error('Error loading workflows:', error.message);
  }
})();

/**
 * GET /api/v1/workflows
 * List all available workflows
 */
router.get('/', async (req, res) => {
  try {
    // Reload workflows to pick up any new ones
    await workflowEngine.loadAllWorkflows();

    const workflows = workflowEngine.listWorkflows();

    res.json({
      success: true,
      data: {
        workflows,
        count: workflows.length
      }
    });
  } catch (error) {
    console.error('Error listing workflows:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to list workflows',
      message: error.message
    });
  }
});

/**
 * GET /api/v1/workflows/executions
 * List all workflow executions across all workflows
 */
router.get('/executions', async (req, res) => {
  try {
    const { workflow_name, limit = 50, offset = 0, status } = req.query;

    const result = await workflowEngine.listAllExecutions({
      workflow_name,
      limit: parseInt(limit, 10),
      offset: parseInt(offset, 10),
      status
    });

    res.json({
      success: true,
      data: {
        executions: result.executions,
        total: result.total
      }
    });
  } catch (error) {
    console.error('Error listing all executions:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to list executions',
      message: error.message
    });
  }
});

/**
 * GET /api/v1/workflows/executions/:id
 * Get execution details by ID
 */
router.get('/executions/:id', async (req, res) => {
  try {
    const { id } = req.params;

    // Validate execution ID format
    const sanitizedId = validateId(id);
    if (!sanitizedId) {
      return res.status(400).json({
        success: false,
        error: 'Invalid execution ID format'
      });
    }

    const execution = await workflowEngine.getExecution(sanitizedId);

    if (!execution) {
      return res.status(404).json({
        success: false,
        error: 'Execution not found',
        message: `Execution '${id}' does not exist`
      });
    }

    // Extract workflow name from execution ID if not present
    if (!execution.workflow_name) {
      const parts = execution.id.split('-');
      execution.workflow_name = parts.length > 2 ? parts[1] : 'unknown';
    }

    res.json({
      success: true,
      data: {
        execution: {
          id: execution.id,
          workflow_name: execution.workflow_name,
          status: execution.status,
          steps: execution.steps || [],
          started_at: execution.started_at,
          completed_at: execution.completed_at,
          duration_ms: execution.completed_at
            ? new Date(execution.completed_at) - new Date(execution.started_at)
            : null,
          trigger: execution.trigger || 'manual'
        }
      }
    });
  } catch (error) {
    console.error(`Error getting execution ${req.params.id}:`, error);
    res.status(500).json({
      success: false,
      error: 'Failed to get execution',
      message: error.message
    });
  }
});

/**
 * DELETE /api/v1/workflows/executions/:id
 * Cancel a running execution (if supported)
 */
router.delete('/executions/:id', async (req, res) => {
  try {
    const { id } = req.params;

    // Validate execution ID format
    const sanitizedId = validateId(id);
    if (!sanitizedId) {
      return res.status(400).json({
        success: false,
        error: 'Invalid execution ID format'
      });
    }

    const execution = await workflowEngine.getExecution(sanitizedId);

    if (!execution) {
      return res.status(404).json({
        success: false,
        error: 'Execution not found',
        message: `Execution '${id}' does not exist`
      });
    }

    if (execution.status !== 'running') {
      return res.status(400).json({
        success: false,
        error: 'Cannot cancel',
        message: `Execution is not running (status: ${execution.status})`
      });
    }

    // Mark as cancelled (actual cancellation would require more infrastructure)
    execution.status = 'cancelled';
    execution.cancelled_at = new Date().toISOString();

    res.json({
      success: true,
      data: {
        execution_id: id,
        status: 'cancelled',
        message: 'Execution cancellation requested'
      }
    });
  } catch (error) {
    console.error(`Error cancelling execution ${req.params.id}:`, error);
    res.status(500).json({
      success: false,
      error: 'Failed to cancel execution',
      message: error.message
    });
  }
});

/**
 * GET /api/v1/workflows/stats
 * Get workflow execution statistics
 */
router.get('/stats', async (req, res) => {
  try {
    const workflows = workflowEngine.listWorkflows();
    const stats = {
      total_workflows: workflows.length,
      workflows: {}
    };

    for (const workflow of workflows) {
      const executions = await workflowEngine.listExecutions(workflow.name, { limit: 100 });

      const completed = executions.executions.filter(e => e.status === 'completed');
      const failed = executions.executions.filter(e => e.status === 'failed');

      const avgDuration = completed.length > 0
        ? completed.reduce((sum, e) => sum + (e.duration_ms || 0), 0) / completed.length
        : 0;

      stats.workflows[workflow.name] = {
        total_executions: executions.total,
        completed: completed.length,
        failed: failed.length,
        success_rate: executions.total > 0
          ? ((completed.length / executions.total) * 100).toFixed(1) + '%'
          : 'N/A',
        avg_duration_ms: Math.round(avgDuration)
      };
    }

    res.json({
      success: true,
      data: stats
    });
  } catch (error) {
    console.error('Error getting workflow stats:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to get statistics',
      message: error.message
    });
  }
});

/**
 * GET /api/v1/workflows/:name
 * Get workflow definition by name
 */
router.get('/:name', async (req, res) => {
  try {
    const { name } = req.params;

    // Validate workflow name to prevent path traversal
    const sanitizedName = sanitizeFilename(name, []);
    if (!sanitizedName || sanitizedName !== name) {
      return res.status(400).json({
        success: false,
        error: 'Invalid workflow name format'
      });
    }

    // Try to load if not cached
    if (!workflowEngine.getWorkflow(sanitizedName)) {
      try {
        await workflowEngine.loadWorkflow(`${sanitizedName}.yaml`);
      } catch (loadError) {
        return res.status(404).json({
          success: false,
          error: 'Workflow not found',
          message: `Workflow '${sanitizedName}' does not exist`
        });
      }
    }

    const workflow = workflowEngine.getWorkflow(sanitizedName);

    if (!workflow) {
      return res.status(404).json({
        success: false,
        error: 'Workflow not found',
        message: `Workflow '${sanitizedName}' does not exist`
      });
    }

    // Build DAG for visualization
    const dag = workflowEngine.buildDAG(workflow.steps);
    const executionOrder = workflowEngine.topologicalSort(dag);

    res.json({
      success: true,
      data: {
        workflow,
        execution_order: executionOrder,
        step_count: workflow.steps.length
      }
    });
  } catch (error) {
    console.error(`Error getting workflow ${req.params.name}:`, error);
    res.status(500).json({
      success: false,
      error: 'Failed to get workflow',
      message: error.message
    });
  }
});

/**
 * POST /api/v1/workflows/:name/execute
 * Execute a workflow
 */
router.post('/:name/execute', async (req, res) => {
  try {
    const { name } = req.params;
    const { inputs = {}, options = {} } = req.body;

    // Validate workflow name to prevent path traversal
    const sanitizedName = sanitizeFilename(name, []);
    if (!sanitizedName || sanitizedName !== name) {
      return res.status(400).json({
        success: false,
        error: 'Invalid workflow name format'
      });
    }

    // Verify workflow exists
    if (!workflowEngine.getWorkflow(sanitizedName)) {
      try {
        await workflowEngine.loadWorkflow(`${sanitizedName}.yaml`);
      } catch (loadError) {
        return res.status(404).json({
          success: false,
          error: 'Workflow not found',
          message: `Workflow '${sanitizedName}' does not exist`
        });
      }
    }

    // Validate required inputs
    const workflow = workflowEngine.getWorkflow(sanitizedName);
    if (workflow.inputs) {
      const missingInputs = [];
      for (const [key, config] of Object.entries(workflow.inputs)) {
        if (config.required && inputs[key] === undefined) {
          missingInputs.push(key);
        }
      }

      if (missingInputs.length > 0) {
        return res.status(400).json({
          success: false,
          error: 'Missing required inputs',
          message: `Required inputs not provided: ${missingInputs.join(', ')}`
        });
      }
    }

    // Check for async execution
    if (options.async) {
      // Start execution asynchronously
      const executionId = `exec-${sanitizedName}-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`;

      // Return immediately with execution ID
      res.status(202).json({
        success: true,
        data: {
          execution_id: executionId,
          status: 'started',
          message: 'Workflow execution started',
          poll_url: `/api/v1/workflows/executions/${executionId}`
        }
      });

      // Execute in background
      workflowEngine.execute(sanitizedName, inputs, options).catch(error => {
        console.error(`Background workflow execution failed: ${error.message}`);
      });

    } else {
      // Synchronous execution
      const execution = await workflowEngine.execute(sanitizedName, inputs, options);

      res.json({
        success: true,
        data: {
          execution_id: execution.id,
          status: execution.status,
          outputs: execution.outputs,
          started_at: execution.started_at,
          completed_at: execution.completed_at,
          duration_ms: execution.completed_at
            ? new Date(execution.completed_at) - new Date(execution.started_at)
            : null,
          steps: execution.steps,
          error: execution.error
        }
      });
    }
  } catch (error) {
    console.error(`Error executing workflow ${req.params.name}:`, error);
    res.status(500).json({
      success: false,
      error: 'Workflow execution failed',
      message: error.message
    });
  }
});

/**
 * GET /api/v1/workflows/:name/executions
 * List executions for a workflow
 */
router.get('/:name/executions', async (req, res) => {
  try {
    const { name } = req.params;
    const { limit = 50, offset = 0, status } = req.query;

    // Validate workflow name to prevent path traversal
    const sanitizedName = sanitizeFilename(name, []);
    if (!sanitizedName || sanitizedName !== name) {
      return res.status(400).json({
        success: false,
        error: 'Invalid workflow name format'
      });
    }

    const result = await workflowEngine.listExecutions(sanitizedName, {
      limit: parseInt(limit, 10),
      offset: parseInt(offset, 10)
    });

    // Filter by status if provided
    let executions = result.executions;
    if (status) {
      executions = executions.filter(e => e.status === status);
    }

    res.json({
      success: true,
      data: {
        workflow_name: sanitizedName,
        executions,
        pagination: {
          total: result.total,
          limit: result.limit,
          offset: result.offset,
          has_more: result.offset + result.limit < result.total
        }
      }
    });
  } catch (error) {
    console.error(`Error listing executions for ${req.params.name}:`, error);
    res.status(500).json({
      success: false,
      error: 'Failed to list executions',
      message: error.message
    });
  }
});

/**
 * POST /api/v1/workflows/:name/validate
 * Validate a workflow definition
 */
router.post('/:name/validate', async (req, res) => {
  try {
    const { name } = req.params;

    // Validate workflow name to prevent path traversal
    const sanitizedName = sanitizeFilename(name, []);
    if (!sanitizedName || sanitizedName !== name) {
      return res.status(400).json({
        success: false,
        error: 'Invalid workflow name format'
      });
    }

    // Load and validate workflow
    const workflow = await workflowEngine.loadWorkflow(`${sanitizedName}.yaml`);

    // Build DAG to validate dependencies
    const dag = workflowEngine.buildDAG(workflow.steps);
    const executionOrder = workflowEngine.topologicalSort(dag);

    // Find parallel execution groups
    const parallelGroups = [];
    const visited = new Set();

    for (const stepId of executionOrder) {
      if (visited.has(stepId)) continue;

      const ready = workflowEngine.getReadySteps(dag, visited, new Set());
      if (ready.length > 1) {
        parallelGroups.push(ready);
      }

      for (const id of ready) {
        visited.add(id);
      }
    }

    res.json({
      success: true,
      data: {
        valid: true,
        workflow_name: workflow.name,
        version: workflow.version,
        step_count: workflow.steps.length,
        execution_order: executionOrder,
        parallel_groups: parallelGroups,
        has_failure_handler: !!workflow.on_failure
      }
    });
  } catch (error) {
    console.error(`Error validating workflow ${req.params.name}:`, error);
    res.status(400).json({
      success: false,
      error: 'Workflow validation failed',
      message: error.message
    });
  }
});

module.exports = router;
