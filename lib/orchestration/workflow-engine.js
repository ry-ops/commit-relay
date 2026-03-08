/**
 * Declarative DAG Workflow Engine for Commit-Relay
 *
 * Provides execution of YAML-defined workflows with:
 * - Dependency graph resolution
 * - Parallel execution of independent steps
 * - Variable interpolation
 * - Conditional execution
 * - Failure handling
 */

const fs = require('fs').promises;
const fsSync = require('fs');
const path = require('path');
const yaml = require('js-yaml');
const Ajv = require('ajv');
const StepExecutor = require('./step-executor');
const ConditionEvaluator = require('./condition-evaluator');

class WorkflowEngine {
  constructor(options = {}) {
    this.workflowsDir = options.workflowsDir || path.join(__dirname, '../../coordination/workflows');
    this.executionsDir = options.executionsDir || path.join(__dirname, '../../coordination/workflow-executions');
    this.schemaPath = options.schemaPath || path.join(__dirname, 'workflow-schema.json');

    this.workflows = new Map();
    this.executions = new Map();
    this.stepExecutor = new StepExecutor(options);
    this.conditionEvaluator = new ConditionEvaluator({ debug: options.debug });

    // Initialize AJV for schema validation
    this.ajv = new Ajv({ allErrors: true, strict: false });
    this.validator = null;

    // Ensure directories exist
    this._ensureDirectories();
  }

  /**
   * Ensure required directories exist
   */
  async _ensureDirectories() {
    const dirs = [this.workflowsDir, this.executionsDir];
    for (const dir of dirs) {
      if (!fsSync.existsSync(dir)) {
        await fs.mkdir(dir, { recursive: true });
      }
    }
  }

  /**
   * Initialize the schema validator
   */
  async _initValidator() {
    if (this.validator) return;

    try {
      const schemaContent = await fs.readFile(this.schemaPath, 'utf-8');
      const schema = JSON.parse(schemaContent);
      this.validator = this.ajv.compile(schema);
    } catch (error) {
      console.warn(`Warning: Could not load workflow schema: ${error.message}`);
      // Create a permissive validator if schema not found
      this.validator = () => true;
    }
  }

  /**
   * Load a workflow definition from YAML file
   * @param {string} workflowPath - Path to the workflow YAML file
   * @returns {Object} Parsed workflow definition
   */
  async loadWorkflow(workflowPath) {
    await this._initValidator();

    const fullPath = path.isAbsolute(workflowPath)
      ? workflowPath
      : path.join(this.workflowsDir, workflowPath);

    const content = await fs.readFile(fullPath, 'utf-8');
    const workflow = yaml.load(content);

    // Validate against schema
    if (!this.validator(workflow)) {
      const errors = this.validator.errors || [];
      throw new Error(`Workflow validation failed: ${JSON.stringify(errors, null, 2)}`);
    }

    // Cache the workflow
    this.workflows.set(workflow.name, {
      definition: workflow,
      path: fullPath,
      loadedAt: new Date().toISOString()
    });

    return workflow;
  }

  /**
   * Load all workflows from the workflows directory
   * @returns {Array} List of loaded workflow names
   */
  async loadAllWorkflows() {
    const files = await fs.readdir(this.workflowsDir);
    const yamlFiles = files.filter(f => f.endsWith('.yaml') || f.endsWith('.yml'));

    const loaded = [];
    for (const file of yamlFiles) {
      try {
        const workflow = await this.loadWorkflow(file);
        loaded.push(workflow.name);
      } catch (error) {
        console.error(`Error loading workflow ${file}: ${error.message}`);
      }
    }

    return loaded;
  }

  /**
   * Build a dependency graph (DAG) from workflow steps
   * @param {Array} steps - Workflow step definitions
   * @returns {Object} DAG representation with nodes and edges
   */
  buildDAG(steps) {
    const dag = {
      nodes: new Map(),
      edges: new Map(),  // node -> dependencies
      reverseEdges: new Map()  // node -> dependents
    };

    // Initialize nodes
    for (const step of steps) {
      dag.nodes.set(step.id, step);
      dag.edges.set(step.id, []);
      dag.reverseEdges.set(step.id, []);
    }

    // Build edges from depends_on
    for (const step of steps) {
      const dependencies = step.depends_on || [];
      for (const dep of dependencies) {
        if (!dag.nodes.has(dep)) {
          throw new Error(`Step '${step.id}' depends on unknown step '${dep}'`);
        }
        dag.edges.get(step.id).push(dep);
        dag.reverseEdges.get(dep).push(step.id);
      }
    }

    // Detect cycles
    this._detectCycles(dag);

    return dag;
  }

  /**
   * Detect cycles in the DAG using DFS
   * @param {Object} dag - The DAG to check
   * @throws {Error} If a cycle is detected
   */
  _detectCycles(dag) {
    const visited = new Set();
    const recursionStack = new Set();

    const dfs = (nodeId, path = []) => {
      if (recursionStack.has(nodeId)) {
        const cycle = [...path, nodeId].join(' -> ');
        throw new Error(`Cycle detected in workflow: ${cycle}`);
      }

      if (visited.has(nodeId)) return;

      visited.add(nodeId);
      recursionStack.add(nodeId);

      for (const dep of dag.edges.get(nodeId)) {
        dfs(dep, [...path, nodeId]);
      }

      recursionStack.delete(nodeId);
    };

    for (const nodeId of dag.nodes.keys()) {
      dfs(nodeId);
    }
  }

  /**
   * Perform topological sort on the DAG
   * @param {Object} dag - The DAG to sort
   * @returns {Array} Ordered list of step IDs
   */
  topologicalSort(dag) {
    const result = [];
    const visited = new Set();
    const temp = new Set();

    const visit = (nodeId) => {
      if (visited.has(nodeId)) return;
      if (temp.has(nodeId)) {
        throw new Error(`Cycle detected at node: ${nodeId}`);
      }

      temp.add(nodeId);

      // Visit dependencies first
      for (const dep of dag.edges.get(nodeId)) {
        visit(dep);
      }

      temp.delete(nodeId);
      visited.add(nodeId);
      result.push(nodeId);
    };

    for (const nodeId of dag.nodes.keys()) {
      visit(nodeId);
    }

    return result;
  }

  /**
   * Get steps that can be executed in parallel (no pending dependencies)
   * @param {Object} dag - The workflow DAG
   * @param {Set} completed - Set of completed step IDs
   * @param {Set} running - Set of currently running step IDs
   * @returns {Array} Step IDs ready for execution
   */
  getReadySteps(dag, completed, running) {
    const ready = [];

    for (const [stepId, dependencies] of dag.edges) {
      if (completed.has(stepId) || running.has(stepId)) {
        continue;
      }

      const allDepsCompleted = dependencies.every(dep => completed.has(dep));
      if (allDepsCompleted) {
        ready.push(stepId);
      }
    }

    return ready;
  }

  /**
   * Execute a workflow
   * @param {string} workflowName - Name of the workflow to execute
   * @param {Object} inputs - Input parameters for the workflow
   * @param {Object} options - Execution options
   * @returns {Object} Execution result
   */
  async execute(workflowName, inputs = {}, options = {}) {
    // Load workflow if not cached
    if (!this.workflows.has(workflowName)) {
      const workflowFile = `${workflowName}.yaml`;
      await this.loadWorkflow(workflowFile);
    }

    const workflowData = this.workflows.get(workflowName);
    if (!workflowData) {
      throw new Error(`Workflow '${workflowName}' not found`);
    }

    const workflow = workflowData.definition;

    // Create execution context
    const executionId = `exec-${workflowName}-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`;
    const execution = {
      id: executionId,
      workflow_name: workflowName,
      workflow_version: workflow.version,
      status: 'running',
      inputs,
      started_at: new Date().toISOString(),
      steps: {},
      outputs: {},
      context: {
        inputs,
        steps: {},
        env: process.env
      }
    };

    this.executions.set(executionId, execution);

    try {
      // Build DAG from steps
      const dag = this.buildDAG(workflow.steps);

      // Execute steps with parallel support
      await this._executeDAG(execution, workflow, dag, options);

      // Mark execution as completed
      execution.status = 'completed';
      execution.completed_at = new Date().toISOString();

      // Collect outputs from final steps
      this._collectOutputs(execution, workflow);

    } catch (error) {
      execution.status = 'failed';
      execution.error = error.message;
      execution.failed_at = new Date().toISOString();

      // Execute on_failure handler if defined
      if (workflow.on_failure) {
        await this._handleFailure(execution, workflow, error);
      }
    }

    // Persist execution record
    await this._saveExecution(execution);

    return execution;
  }

  /**
   * Execute DAG with parallel support
   * @param {Object} execution - Execution context
   * @param {Object} workflow - Workflow definition
   * @param {Object} dag - Workflow DAG
   * @param {Object} options - Execution options
   */
  async _executeDAG(execution, workflow, dag, options) {
    const completed = new Set();
    const failed = new Set();
    const maxParallel = options.maxParallel || 5;

    while (completed.size + failed.size < dag.nodes.size) {
      // Get steps ready for execution
      const readySteps = this.getReadySteps(dag, completed, new Set());

      if (readySteps.length === 0) {
        if (failed.size > 0) {
          throw new Error(`Workflow failed with ${failed.size} step(s) failing`);
        }
        break;
      }

      // Execute ready steps in parallel (up to maxParallel)
      const batch = readySteps.slice(0, maxParallel);
      const promises = batch.map(async (stepId) => {
        const step = dag.nodes.get(stepId);

        // Check condition
        if (step.condition) {
          const shouldRun = this.conditionEvaluator.evaluate(step.condition, execution.context);
          if (!shouldRun) {
            // Resolve the condition for display (show actual values)
            const resolvedCondition = this.conditionEvaluator.resolveVariables(
              step.condition,
              execution.context
            );
            execution.steps[stepId] = {
              status: 'skipped',
              reason: 'Condition not met',
              condition: step.condition,
              resolved_condition: resolvedCondition,
              skipped_at: new Date().toISOString()
            };
            // Update context with skipped status
            execution.context.steps[stepId] = {
              status: 'skipped',
              outputs: {}
            };
            return { stepId, status: 'skipped' };
          }
        }

        // Execute step
        try {
          const result = await this.stepExecutor.executeStep(step, execution.context);

          execution.steps[stepId] = {
            status: 'completed',
            outputs: result.outputs || {},
            started_at: result.started_at,
            completed_at: result.completed_at,
            duration_ms: result.duration_ms
          };

          // Update context with step outputs
          execution.context.steps[stepId] = {
            outputs: result.outputs || {}
          };

          return { stepId, status: 'completed' };

        } catch (error) {
          execution.steps[stepId] = {
            status: 'failed',
            error: error.message,
            failed_at: new Date().toISOString()
          };

          // Check if step has continue_on_failure
          if (step.continue_on_failure) {
            return { stepId, status: 'completed' };
          }

          return { stepId, status: 'failed', error };
        }
      });

      // Wait for batch to complete
      const results = await Promise.all(promises);

      // Process results
      for (const result of results) {
        if (result.status === 'completed' || result.status === 'skipped') {
          completed.add(result.stepId);
        } else {
          failed.add(result.stepId);
        }
      }

      // If any step failed, abort (unless continue_on_failure)
      if (failed.size > 0 && !options.continueOnFailure) {
        const failedStep = Array.from(failed)[0];
        const stepResult = execution.steps[failedStep];
        throw new Error(`Step '${failedStep}' failed: ${stepResult.error}`);
      }
    }
  }

  /**
   * Evaluate a condition expression
   * @param {string} condition - Condition expression
   * @param {Object} context - Execution context
   * @returns {boolean} Whether condition is met
   */
  _evaluateCondition(condition, context) {
    return this.conditionEvaluator.evaluate(condition, context);
  }

  /**
   * Resolve a dot-notation expression against context
   * @param {string} expr - Expression like 'steps.clone.outputs.path'
   * @param {Object} context - Context object
   * @returns {*} Resolved value
   */
  _resolveExpression(expr, context) {
    // Delegate to condition evaluator's variable resolution
    return this.conditionEvaluator._resolveVariablePath(expr, context);
  }

  /**
   * Validate a condition expression
   * @param {string} condition - Condition to validate
   * @returns {Object} Validation result
   */
  validateCondition(condition) {
    return this.conditionEvaluator.validate(condition);
  }

  /**
   * Extract variable dependencies from a condition
   * @param {string} condition - Condition expression
   * @returns {Array} Array of variable paths
   */
  getConditionDependencies(condition) {
    return this.conditionEvaluator.extractVariables(condition);
  }

  /**
   * Collect workflow outputs from completed steps
   * @param {Object} execution - Execution context
   * @param {Object} workflow - Workflow definition
   */
  _collectOutputs(execution, workflow) {
    if (!workflow.outputs) return;

    for (const [key, expr] of Object.entries(workflow.outputs)) {
      try {
        execution.outputs[key] = this.stepExecutor.resolveInputs(expr, execution.context);
      } catch (error) {
        console.warn(`Failed to collect output '${key}': ${error.message}`);
      }
    }
  }

  /**
   * Handle workflow failure
   * @param {Object} execution - Execution context
   * @param {Object} workflow - Workflow definition
   * @param {Error} error - The failure error
   */
  async _handleFailure(execution, workflow, error) {
    try {
      const failureHandler = workflow.on_failure;

      if (failureHandler.notify) {
        // Send notification (implement based on your notification system)
        console.log(`Workflow failure notification: ${execution.workflow_name} - ${error.message}`);
      }

      if (failureHandler.steps) {
        // Execute failure handler steps
        const dag = this.buildDAG(failureHandler.steps);
        await this._executeDAG(execution, { ...workflow, steps: failureHandler.steps }, dag, {});
      }

    } catch (handlerError) {
      console.error(`Failure handler error: ${handlerError.message}`);
    }
  }

  /**
   * Save execution record to disk
   * @param {Object} execution - Execution to save
   */
  async _saveExecution(execution) {
    const filePath = path.join(
      this.executionsDir,
      `${execution.id}.json`
    );

    await fs.writeFile(filePath, JSON.stringify(execution, null, 2));
  }

  /**
   * Get execution by ID
   * @param {string} executionId - Execution ID
   * @returns {Object} Execution record
   */
  async getExecution(executionId) {
    // Check cache first
    if (this.executions.has(executionId)) {
      return this.executions.get(executionId);
    }

    // Load from disk
    const filePath = path.join(this.executionsDir, `${executionId}.json`);
    try {
      const content = await fs.readFile(filePath, 'utf-8');
      return JSON.parse(content);
    } catch (error) {
      return null;
    }
  }

  /**
   * List executions for a workflow
   * @param {string} workflowName - Workflow name
   * @param {Object} options - Query options
   * @returns {Array} List of executions
   */
  async listExecutions(workflowName, options = {}) {
    const files = await fs.readdir(this.executionsDir);
    const executions = [];

    const prefix = `exec-${workflowName}-`;
    const matchingFiles = files.filter(f => f.startsWith(prefix) && f.endsWith('.json'));

    // Sort by timestamp (newest first)
    matchingFiles.sort().reverse();

    // Apply pagination
    const limit = options.limit || 50;
    const offset = options.offset || 0;
    const paginatedFiles = matchingFiles.slice(offset, offset + limit);

    for (const file of paginatedFiles) {
      try {
        const content = await fs.readFile(path.join(this.executionsDir, file), 'utf-8');
        const execution = JSON.parse(content);
        executions.push({
          id: execution.id,
          status: execution.status,
          started_at: execution.started_at,
          completed_at: execution.completed_at,
          duration_ms: execution.completed_at
            ? new Date(execution.completed_at) - new Date(execution.started_at)
            : null
        });
      } catch (error) {
        console.warn(`Error reading execution ${file}: ${error.message}`);
      }
    }

    return {
      executions,
      total: matchingFiles.length,
      limit,
      offset
    };
  }

  /**
   * List all executions across all workflows
   * @param {Object} options - Query options (limit, offset, status, workflow_name)
   * @returns {Object} List of executions with pagination
   */
  async listAllExecutions(options = {}) {
    const files = await fs.readdir(this.executionsDir);
    let executions = [];

    // Filter for execution JSON files
    let matchingFiles = files.filter(f => f.startsWith('exec-') && f.endsWith('.json'));

    // Filter by workflow name if provided
    if (options.workflow_name) {
      const prefix = `exec-${options.workflow_name}-`;
      matchingFiles = matchingFiles.filter(f => f.startsWith(prefix));
    }

    // Sort by timestamp (newest first)
    matchingFiles.sort().reverse();

    // Load all matching files first (for status filtering)
    const allExecutions = [];
    for (const file of matchingFiles) {
      try {
        const content = await fs.readFile(path.join(this.executionsDir, file), 'utf-8');
        const execution = JSON.parse(content);

        // Extract workflow name from execution ID (exec-{workflow_name}-{timestamp}-{id})
        const parts = execution.id.split('-');
        const workflowName = parts.length > 2 ? parts[1] : 'unknown';

        allExecutions.push({
          id: execution.id,
          workflow_name: execution.workflow_name || workflowName,
          status: execution.status,
          steps: execution.steps || [],
          started_at: execution.started_at,
          completed_at: execution.completed_at,
          duration_ms: execution.completed_at
            ? new Date(execution.completed_at) - new Date(execution.started_at)
            : null,
          trigger: execution.trigger || 'manual'
        });
      } catch (error) {
        console.warn(`Error reading execution ${file}: ${error.message}`);
      }
    }

    // Filter by status if provided
    if (options.status) {
      executions = allExecutions.filter(e => e.status === options.status);
    } else {
      executions = allExecutions;
    }

    // Apply pagination
    const limit = options.limit || 50;
    const offset = options.offset || 0;
    const total = executions.length;
    executions = executions.slice(offset, offset + limit);

    return {
      executions,
      total,
      limit,
      offset
    };
  }

  /**
   * Get workflow definition
   * @param {string} workflowName - Workflow name
   * @returns {Object} Workflow definition
   */
  getWorkflow(workflowName) {
    const workflowData = this.workflows.get(workflowName);
    return workflowData ? workflowData.definition : null;
  }

  /**
   * List all loaded workflows
   * @returns {Array} List of workflow metadata
   */
  listWorkflows() {
    const workflows = [];

    for (const [name, data] of this.workflows) {
      workflows.push({
        name,
        version: data.definition.version,
        description: data.definition.description,
        triggers: data.definition.triggers,
        path: data.path,
        loadedAt: data.loadedAt
      });
    }

    return workflows;
  }
}

module.exports = WorkflowEngine;
