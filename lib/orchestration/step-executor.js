/**
 * Step Executor for Workflow Engine
 *
 * Handles execution of individual workflow steps including:
 * - Variable interpolation
 * - Master/worker delegation
 * - Action execution
 * - Output collection
 */

const { spawn } = require('child_process');
const fs = require('fs').promises;
const path = require('path');

class StepExecutor {
  constructor(options = {}) {
    this.coordDir = options.coordDir || path.join(__dirname, '../../coordination');
    this.scriptsDir = options.scriptsDir || path.join(__dirname, '../../scripts');
    this.timeout = options.timeout || 300000; // 5 minutes default

    // Action handlers registry
    this.actionHandlers = {
      // Built-in actions
      'shell': this._executeShell.bind(this),
      'bash': this._executeShell.bind(this),
      'script': this._executeScript.bind(this),
      'file_write': this._executeFileWrite.bind(this),
      'file_read': this._executeFileRead.bind(this),
      'http_request': this._executeHttpRequest.bind(this),
      'handoff': this._executeHandoff.bind(this),
      'delegate': this._executeDelegate.bind(this),
      'parallel': this._executeParallel.bind(this),
      'wait': this._executeWait.bind(this),
      'condition': this._executeCondition.bind(this),
      'aggregate': this._executeAggregate.bind(this)
    };
  }

  /**
   * Execute a single workflow step
   * @param {Object} step - Step definition
   * @param {Object} context - Execution context
   * @returns {Object} Step execution result
   */
  async executeStep(step, context) {
    const startTime = Date.now();

    const result = {
      step_id: step.id,
      started_at: new Date().toISOString(),
      outputs: {}
    };

    try {
      // Resolve inputs with variable interpolation
      const resolvedInputs = this.resolveAllInputs(step.inputs || {}, context);

      // Get action handler
      const action = step.action || 'delegate';
      const handler = this.actionHandlers[action];

      if (!handler) {
        throw new Error(`Unknown action type: ${action}`);
      }

      // Execute the action
      const actionResult = await handler(step, resolvedInputs, context);

      // Collect outputs
      result.outputs = this._collectStepOutputs(step, actionResult, context);
      result.status = 'completed';
      result.completed_at = new Date().toISOString();
      result.duration_ms = Date.now() - startTime;

    } catch (error) {
      result.status = 'failed';
      result.error = error.message;
      result.failed_at = new Date().toISOString();
      result.duration_ms = Date.now() - startTime;
      throw error;
    }

    return result;
  }

  /**
   * Resolve all inputs with variable interpolation
   * @param {Object} inputs - Input object
   * @param {Object} context - Execution context
   * @returns {Object} Resolved inputs
   */
  resolveAllInputs(inputs, context) {
    const resolved = {};

    for (const [key, value] of Object.entries(inputs)) {
      resolved[key] = this.resolveInputs(value, context);
    }

    return resolved;
  }

  /**
   * Resolve variable interpolation in a value
   * Supports {{ steps.X.outputs.Y }} syntax
   * @param {*} value - Value to resolve
   * @param {Object} context - Execution context
   * @returns {*} Resolved value
   */
  resolveInputs(value, context) {
    if (typeof value === 'string') {
      // Replace {{ expression }} patterns
      return value.replace(
        /\{\{\s*([^}]+)\s*\}\}/g,
        (match, expr) => {
          const resolved = this._resolveExpression(expr.trim(), context);
          return resolved !== undefined ? String(resolved) : match;
        }
      );
    }

    if (Array.isArray(value)) {
      return value.map(item => this.resolveInputs(item, context));
    }

    if (typeof value === 'object' && value !== null) {
      const resolved = {};
      for (const [k, v] of Object.entries(value)) {
        resolved[k] = this.resolveInputs(v, context);
      }
      return resolved;
    }

    return value;
  }

  /**
   * Resolve a dot-notation expression
   * @param {string} expr - Expression like 'steps.clone.outputs.path'
   * @param {Object} context - Context object
   * @returns {*} Resolved value
   */
  _resolveExpression(expr, context) {
    const parts = expr.split('.');
    let value = context;

    for (const part of parts) {
      if (value === undefined || value === null) {
        return undefined;
      }
      value = value[part];
    }

    return value;
  }

  /**
   * Collect outputs from step execution
   * @param {Object} step - Step definition
   * @param {Object} actionResult - Action execution result
   * @param {Object} context - Execution context
   * @returns {Object} Collected outputs
   */
  _collectStepOutputs(step, actionResult, context) {
    const outputs = {};

    if (step.outputs) {
      for (const [key, source] of Object.entries(step.outputs)) {
        if (typeof source === 'string' && source.startsWith('$result.')) {
          // Reference action result
          const resultPath = source.substring(8);
          outputs[key] = this._getNestedValue(actionResult, resultPath);
        } else {
          outputs[key] = this.resolveInputs(source, context);
        }
      }
    }

    // Include default outputs from action
    if (actionResult) {
      if (actionResult.stdout !== undefined) outputs.stdout = actionResult.stdout;
      if (actionResult.stderr !== undefined) outputs.stderr = actionResult.stderr;
      if (actionResult.exitCode !== undefined) outputs.exitCode = actionResult.exitCode;
      if (actionResult.data !== undefined) outputs.data = actionResult.data;
      if (actionResult.path !== undefined) outputs.path = actionResult.path;
    }

    return outputs;
  }

  /**
   * Get nested value from object
   * @param {Object} obj - Source object
   * @param {string} path - Dot-notation path
   * @returns {*} Nested value
   */
  _getNestedValue(obj, path) {
    return path.split('.').reduce((o, p) => o?.[p], obj);
  }

  // ========== Action Handlers ==========

  /**
   * Execute shell/bash command
   */
  async _executeShell(step, inputs, context) {
    const command = inputs.command || inputs.script;
    const cwd = inputs.cwd || process.cwd();
    const env = { ...process.env, ...(inputs.env || {}) };

    return new Promise((resolve, reject) => {
      const proc = spawn('bash', ['-c', command], {
        cwd,
        env,
        timeout: inputs.timeout || this.timeout
      });

      let stdout = '';
      let stderr = '';

      proc.stdout.on('data', (data) => {
        stdout += data.toString();
      });

      proc.stderr.on('data', (data) => {
        stderr += data.toString();
      });

      proc.on('close', (code) => {
        if (code !== 0 && !inputs.allowFailure) {
          reject(new Error(`Command failed with code ${code}: ${stderr || stdout}`));
        } else {
          resolve({
            stdout: stdout.trim(),
            stderr: stderr.trim(),
            exitCode: code
          });
        }
      });

      proc.on('error', reject);
    });
  }

  /**
   * Execute script file
   */
  async _executeScript(step, inputs, context) {
    const scriptPath = inputs.path || inputs.script;
    const fullPath = path.isAbsolute(scriptPath)
      ? scriptPath
      : path.join(this.scriptsDir, scriptPath);

    const args = inputs.args || [];
    const cwd = inputs.cwd || path.dirname(fullPath);
    const env = { ...process.env, ...(inputs.env || {}) };

    return new Promise((resolve, reject) => {
      const proc = spawn(fullPath, args, {
        cwd,
        env,
        timeout: inputs.timeout || this.timeout
      });

      let stdout = '';
      let stderr = '';

      proc.stdout.on('data', (data) => {
        stdout += data.toString();
      });

      proc.stderr.on('data', (data) => {
        stderr += data.toString();
      });

      proc.on('close', (code) => {
        if (code !== 0 && !inputs.allowFailure) {
          reject(new Error(`Script failed with code ${code}: ${stderr || stdout}`));
        } else {
          resolve({
            stdout: stdout.trim(),
            stderr: stderr.trim(),
            exitCode: code
          });
        }
      });

      proc.on('error', reject);
    });
  }

  /**
   * Write content to file
   */
  async _executeFileWrite(step, inputs, context) {
    const filePath = inputs.path;
    const content = inputs.content;
    const append = inputs.append || false;

    // Ensure directory exists
    await fs.mkdir(path.dirname(filePath), { recursive: true });

    if (append) {
      await fs.appendFile(filePath, content);
    } else {
      await fs.writeFile(filePath, content);
    }

    return { path: filePath, written: true };
  }

  /**
   * Read content from file
   */
  async _executeFileRead(step, inputs, context) {
    const filePath = inputs.path;
    const encoding = inputs.encoding || 'utf-8';

    const content = await fs.readFile(filePath, encoding);

    // Parse JSON if requested
    if (inputs.json) {
      return { data: JSON.parse(content), path: filePath };
    }

    return { data: content, path: filePath };
  }

  /**
   * Execute HTTP request
   */
  async _executeHttpRequest(step, inputs, context) {
    const url = inputs.url;
    const method = (inputs.method || 'GET').toUpperCase();
    const headers = inputs.headers || {};
    const body = inputs.body;
    const timeout = inputs.timeout || 30000;

    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), timeout);

    try {
      const options = {
        method,
        headers,
        signal: controller.signal
      };

      if (body && method !== 'GET') {
        options.body = typeof body === 'string' ? body : JSON.stringify(body);
        if (!headers['Content-Type']) {
          options.headers['Content-Type'] = 'application/json';
        }
      }

      const response = await fetch(url, options);
      const responseText = await response.text();

      let data;
      try {
        data = JSON.parse(responseText);
      } catch {
        data = responseText;
      }

      return {
        status: response.status,
        statusText: response.statusText,
        headers: Object.fromEntries(response.headers),
        data
      };

    } finally {
      clearTimeout(timeoutId);
    }
  }

  /**
   * Create a handoff to another master
   */
  async _executeHandoff(step, inputs, context) {
    const handoff = {
      handoff_id: `handoff-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`,
      from_master: inputs.from || 'workflow-engine',
      to_master: inputs.to || step.master,
      task_id: inputs.task_id || context.inputs?.task_id,
      handoff_type: inputs.type || 'task_assignment',
      priority: inputs.priority || 'normal',
      payload: inputs.payload || {},
      created_at: new Date().toISOString(),
      status: 'pending_pickup'
    };

    // Write handoff file
    const handoffDir = path.join(this.coordDir, 'masters', inputs.from || 'workflow', 'handoffs');
    await fs.mkdir(handoffDir, { recursive: true });

    const handoffPath = path.join(handoffDir, `${handoff.handoff_id}.json`);
    await fs.writeFile(handoffPath, JSON.stringify(handoff, null, 2));

    return {
      handoff_id: handoff.handoff_id,
      path: handoffPath,
      to_master: handoff.to_master
    };
  }

  /**
   * Delegate work to a specific master
   */
  async _executeDelegate(step, inputs, context) {
    const master = step.master;
    const action = step.action || 'process';

    // Create delegation request
    const delegation = {
      delegation_id: `deleg-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`,
      master,
      action,
      inputs,
      context: {
        workflow_id: context.inputs?.workflow_id,
        step_id: step.id
      },
      created_at: new Date().toISOString()
    };

    // For now, simulate delegation by executing a master script
    const masterScript = path.join(this.scriptsDir, `run-${master}-master.sh`);

    if (await this._fileExists(masterScript)) {
      return this._executeScript(step, {
        path: masterScript,
        args: [action, JSON.stringify(inputs)],
        env: {
          DELEGATION_ID: delegation.delegation_id,
          WORKFLOW_STEP: step.id
        }
      }, context);
    }

    // Return delegation info if no script found
    return {
      delegation_id: delegation.delegation_id,
      master,
      status: 'delegated',
      note: 'Master script not found - delegation recorded'
    };
  }

  /**
   * Execute substeps in parallel
   */
  async _executeParallel(step, inputs, context) {
    const substeps = inputs.steps || [];
    const maxConcurrency = inputs.max_concurrency || substeps.length;

    const results = [];
    const running = [];

    for (const substep of substeps) {
      if (running.length >= maxConcurrency) {
        const completed = await Promise.race(running);
        running.splice(running.indexOf(completed), 1);
      }

      const promise = this.executeStep(substep, context)
        .then(result => {
          results.push({ id: substep.id, result });
          return promise;
        })
        .catch(error => {
          results.push({ id: substep.id, error: error.message });
          return promise;
        });

      running.push(promise);
    }

    await Promise.all(running);

    return { results };
  }

  /**
   * Wait/delay execution
   */
  async _executeWait(step, inputs, context) {
    const ms = inputs.duration_ms || inputs.seconds * 1000 || 1000;
    await new Promise(resolve => setTimeout(resolve, ms));
    return { waited_ms: ms };
  }

  /**
   * Conditional execution
   */
  async _executeCondition(step, inputs, context) {
    const condition = inputs.condition;
    const thenStep = inputs.then;
    const elseStep = inputs.else;

    // Evaluate condition
    const result = this._evaluateCondition(condition, context);

    if (result && thenStep) {
      return this.executeStep(thenStep, context);
    } else if (!result && elseStep) {
      return this.executeStep(elseStep, context);
    }

    return { condition_result: result };
  }

  /**
   * Aggregate results from multiple steps
   */
  async _executeAggregate(step, inputs, context) {
    const stepIds = inputs.steps || [];
    const aggregated = {};

    for (const stepId of stepIds) {
      const stepOutput = context.steps?.[stepId]?.outputs;
      if (stepOutput) {
        aggregated[stepId] = stepOutput;
      }
    }

    return { aggregated };
  }

  /**
   * Evaluate a condition expression
   */
  _evaluateCondition(condition, context) {
    try {
      const resolved = condition.replace(
        /\{\{\s*([^}]+)\s*\}\}/g,
        (match, expr) => {
          const value = this._resolveExpression(expr.trim(), context);
          return JSON.stringify(value);
        }
      );

      // eslint-disable-next-line no-new-func
      return new Function('context', `return ${resolved}`)(context);
    } catch (error) {
      console.warn(`Condition evaluation failed: ${condition} - ${error.message}`);
      return false;
    }
  }

  /**
   * Check if file exists
   */
  async _fileExists(filePath) {
    try {
      await fs.access(filePath);
      return true;
    } catch {
      return false;
    }
  }
}

module.exports = StepExecutor;
