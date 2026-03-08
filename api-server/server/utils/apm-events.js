/**
 * Elastic APM Custom Event Tracking Utilities
 *
 * This module provides helper functions for tracking custom events,
 * spans, and labels in Elastic APM for commit-relay operations.
 */

const apm = require('../../apm');

/**
 * Track an agent lifecycle event
 * @param {string} eventType - Type of event (spawned, completed, failed, etc.)
 * @param {object} agentData - Agent information
 * @param {string} agentData.agentId - Agent/worker ID
 * @param {string} agentData.agentType - Type of agent (master, worker, etc.)
 * @param {string} agentData.taskId - Associated task ID
 * @param {object} [agentData.metadata] - Additional metadata
 */
function trackAgentEvent(eventType, agentData) {
  if (!apm) return;

  try {
    // Set custom context for the current transaction
    apm.setCustomContext({
      agent_event: {
        type: eventType,
        agent_id: agentData.agentId,
        agent_type: agentData.agentType,
        task_id: agentData.taskId,
        metadata: agentData.metadata || {}
      }
    });

    // Add labels for filtering in Kibana
    apm.addLabels({
      'agent.event.type': eventType,
      'agent.id': agentData.agentId,
      'agent.type': agentData.agentType,
      'task.id': agentData.taskId
    });

    console.log(`[APM] Tracked agent event: ${eventType} for ${agentData.agentId}`);
  } catch (error) {
    console.error('[APM] Failed to track agent event:', error.message);
  }
}

/**
 * Track a tool or API invocation
 * @param {string} toolName - Name of the tool/API
 * @param {object} invocationData - Invocation details
 * @param {string} invocationData.operation - Operation being performed
 * @param {number} [invocationData.duration] - Duration in milliseconds
 * @param {string} [invocationData.status] - Status (success, error)
 * @param {object} [invocationData.metadata] - Additional metadata
 */
function trackToolUsage(toolName, invocationData) {
  if (!apm) return;

  try {
    // Create a custom span for the tool usage
    const span = apm.startSpan(`tool.${toolName}`, 'external');

    if (span) {
      span.addLabels({
        'tool.name': toolName,
        'tool.operation': invocationData.operation,
        'tool.status': invocationData.status || 'unknown'
      });

      // Set custom context
      apm.setCustomContext({
        tool_usage: {
          name: toolName,
          operation: invocationData.operation,
          duration: invocationData.duration,
          status: invocationData.status,
          metadata: invocationData.metadata || {}
        }
      });

      if (invocationData.duration && span.end) {
        span.end(invocationData.duration);
      } else if (span.end) {
        span.end();
      }
    }

    console.log(`[APM] Tracked tool usage: ${toolName}.${invocationData.operation}`);
  } catch (error) {
    console.error('[APM] Failed to track tool usage:', error.message);
  }
}

/**
 * Track a relay task completion
 * @param {string} taskId - Task ID
 * @param {object} completionData - Completion details
 * @param {string} completionData.status - Completion status (success, failure)
 * @param {number} completionData.duration - Duration in milliseconds
 * @param {string} [completionData.master] - Master that handled the task
 * @param {number} [completionData.workersUsed] - Number of workers used
 * @param {object} [completionData.metrics] - Task metrics
 */
function trackRelayCompletion(taskId, completionData) {
  if (!apm) return;

  try {
    // Create a custom transaction for task completion
    const transaction = apm.startTransaction(`task.${taskId}`, 'task-completion');

    if (transaction) {
      // Add labels
      transaction.addLabels({
        'task.id': taskId,
        'task.status': completionData.status,
        'task.master': completionData.master || 'unknown',
        'task.workers_used': completionData.workersUsed || 0
      });

      // Set custom context
      transaction.setCustomContext({
        task_completion: {
          task_id: taskId,
          status: completionData.status,
          duration: completionData.duration,
          master: completionData.master,
          workers_used: completionData.workersUsed,
          metrics: completionData.metrics || {}
        }
      });

      // Set result based on status
      transaction.result = completionData.status === 'success' ? 'success' : 'failure';

      // End transaction
      transaction.end();
    }

    console.log(`[APM] Tracked relay completion: ${taskId} (${completionData.status})`);
  } catch (error) {
    console.error('[APM] Failed to track relay completion:', error.message);
  }
}

/**
 * Create a custom span for an operation
 * @param {string} name - Span name
 * @param {string} type - Span type (e.g., 'db', 'external', 'custom')
 * @param {Function} fn - Function to execute within the span
 * @returns {Promise<any>} Result of the function
 */
async function withCustomSpan(name, type, fn) {
  if (!apm) {
    // If APM is not enabled, just execute the function
    return await fn();
  }

  const span = apm.startSpan(name, type);

  try {
    const result = await fn();

    if (span) {
      span.setOutcome('success');
      span.end();
    }

    return result;
  } catch (error) {
    if (span) {
      span.setOutcome('failure');
      span.end();
    }

    throw error;
  }
}

/**
 * Capture an exception with additional context
 * @param {Error} error - Error object
 * @param {object} [context] - Additional context
 * @param {string} [context.user] - User identifier
 * @param {string} [context.operation] - Operation being performed
 * @param {object} [context.metadata] - Additional metadata
 */
function captureException(error, context = {}) {
  if (!apm) {
    console.error('[APM] Exception (APM disabled):', error);
    return;
  }

  try {
    // Set custom context before capturing
    if (context.metadata) {
      apm.setCustomContext(context.metadata);
    }

    // Add labels
    if (context.operation) {
      apm.addLabels({
        'error.operation': context.operation
      });
    }

    // Capture the exception
    apm.captureError(error);

    console.log(`[APM] Captured exception: ${error.message}`);
  } catch (captureError) {
    console.error('[APM] Failed to capture exception:', captureError.message);
  }
}

/**
 * Set user context for the current transaction
 * @param {object} user - User information
 * @param {string} user.id - User ID
 * @param {string} [user.username] - Username
 * @param {string} [user.email] - User email
 */
function setUser(user) {
  if (!apm) return;

  try {
    apm.setUserContext({
      id: user.id,
      username: user.username,
      email: user.email
    });

    console.log(`[APM] Set user context: ${user.id}`);
  } catch (error) {
    console.error('[APM] Failed to set user context:', error.message);
  }
}

/**
 * Add custom labels to the current transaction
 * @param {object} labels - Key-value pairs of labels
 */
function addLabels(labels) {
  if (!apm) return;

  try {
    apm.addLabels(labels);
  } catch (error) {
    console.error('[APM] Failed to add labels:', error.message);
  }
}

/**
 * Get the current transaction ID (for log correlation)
 * @returns {string|null} Transaction ID or null
 */
function getTransactionId() {
  if (!apm) return null;

  try {
    const transaction = apm.currentTransaction;
    return transaction ? transaction.id : null;
  } catch (error) {
    return null;
  }
}

/**
 * Get the current trace ID (for log correlation)
 * @returns {string|null} Trace ID or null
 */
function getTraceId() {
  if (!apm) return null;

  try {
    const transaction = apm.currentTransaction;
    return transaction ? transaction.traceId : null;
  } catch (error) {
    return null;
  }
}

/**
 * Track LLM API calls (Anthropic, OpenAI, etc.)
 * @param {Object} callData - LLM call data
 * @param {string} callData.provider - LLM provider (e.g., 'anthropic', 'openai')
 * @param {string} callData.model - Model name (e.g., 'claude-3-opus')
 * @param {number} callData.duration - Call duration in milliseconds
 * @param {Object} callData.tokens - Token usage data
 * @param {number} callData.tokens.input - Input tokens
 * @param {number} callData.tokens.output - Output tokens
 * @param {number} callData.tokens.total - Total tokens
 * @param {string} callData.status - Call status ('success', 'error', 'timeout')
 * @param {string} callData.operation - Operation type (e.g., 'messages.create', 'chat.completion')
 * @param {Object} callData.metadata - Additional metadata
 */
function trackLLMCall(callData) {
  if (!apm) return;

  try {
    // Create custom span for LLM call
    const span = apm.startSpan(`llm.${callData.provider}.${callData.operation}`, 'external.http');

    if (span) {
      span.addLabels({
        'llm.provider': callData.provider,
        'llm.model': callData.model,
        'llm.operation': callData.operation,
        'llm.status': callData.status,
        'llm.tokens.input': callData.tokens?.input || 0,
        'llm.tokens.output': callData.tokens?.output || 0,
        'llm.tokens.total': callData.tokens?.total || 0,
        'llm.duration_ms': callData.duration || 0
      });

      // Add cost estimate (approximate for Anthropic)
      const inputCost = (callData.tokens?.input || 0) * 0.000015; // $15 per 1M tokens
      const outputCost = (callData.tokens?.output || 0) * 0.000075; // $75 per 1M tokens
      const totalCost = inputCost + outputCost;

      span.addLabels({
        'llm.cost.input_usd': inputCost.toFixed(6),
        'llm.cost.output_usd': outputCost.toFixed(6),
        'llm.cost.total_usd': totalCost.toFixed(6)
      });

      span.end();
    }

    // Add transaction-level labels
    addLabels({
      'llm.provider': callData.provider,
      'llm.model': callData.model,
      'llm.tokens.total': callData.tokens?.total || 0,
      'llm.status': callData.status
    });

    // Set custom context
    apm.setCustomContext({
      llm_call: {
        provider: callData.provider,
        model: callData.model,
        operation: callData.operation,
        tokens: callData.tokens,
        duration: callData.duration,
        status: callData.status,
        metadata: callData.metadata || {}
      }
    });
  } catch (error) {
    console.error('[APM] Failed to track LLM call:', error.message);
  }
}

/**
 * Track worker spawn operations
 * @param {Object} spawnData - Worker spawn data
 * @param {string} spawnData.workerId - Worker ID
 * @param {string} spawnData.workerType - Worker type (e.g., 'implementation', 'analysis')
 * @param {string} spawnData.taskId - Associated task ID
 * @param {string} spawnData.master - Parent master (e.g., 'development-master')
 * @param {number} spawnData.spawnDuration - Time to spawn in milliseconds
 * @param {string} spawnData.status - Spawn status ('success', 'failed')
 * @param {Object} spawnData.metadata - Additional metadata
 */
function trackWorkerSpawn(spawnData) {
  if (!apm) return;

  try {
    // Create custom span for worker spawn
    const span = apm.startSpan(`worker.spawn.${spawnData.workerType}`, 'process.spawn');

    if (span) {
      span.addLabels({
        'worker.id': spawnData.workerId,
        'worker.type': spawnData.workerType,
        'worker.task_id': spawnData.taskId,
        'worker.master': spawnData.master,
        'worker.spawn_duration_ms': spawnData.spawnDuration || 0,
        'worker.status': spawnData.status
      });

      span.end();
    }

    // Add transaction-level labels
    addLabels({
      'worker.spawn.type': spawnData.workerType,
      'worker.spawn.status': spawnData.status,
      'worker.spawn.duration_ms': spawnData.spawnDuration || 0
    });

    // Track as agent event
    trackAgentEvent('spawned', {
      agentId: spawnData.workerId,
      agentType: spawnData.workerType,
      taskId: spawnData.taskId,
      metadata: {
        master: spawnData.master,
        spawnDuration: spawnData.spawnDuration,
        ...spawnData.metadata
      }
    });
  } catch (error) {
    console.error('[APM] Failed to track worker spawn:', error.message);
  }
}

module.exports = {
  trackAgentEvent,
  trackToolUsage,
  trackRelayCompletion,
  trackLLMCall,
  trackWorkerSpawn,
  withCustomSpan,
  captureException,
  setUser,
  addLabels,
  getTransactionId,
  getTraceId
};
