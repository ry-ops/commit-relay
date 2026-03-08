/**
 * APM Instrumentation Usage Examples
 *
 * This file demonstrates how to use the custom APM instrumentation
 * functions throughout the commit-relay codebase.
 */

const {
  trackLLMCall,
  trackWorkerSpawn,
  trackAgentEvent,
  withCustomSpan,
  addLabels
} = require('../utils/apm-events');

// ============================================================================
// Example 1: Track LLM API Call (Anthropic Claude)
// ============================================================================

async function exampleTrackLLMCall() {
  const startTime = Date.now();

  try {
    // Make actual LLM API call (pseudo-code)
    const response = await anthropic.messages.create({
      model: 'claude-3-opus-20240229',
      max_tokens: 1024,
      messages: [{ role: 'user', content: 'Analyze this code...' }]
    });

    const duration = Date.now() - startTime;

    // Track the LLM call in APM
    trackLLMCall({
      provider: 'anthropic',
      model: 'claude-3-opus-20240229',
      operation: 'messages.create',
      duration: duration,
      tokens: {
        input: response.usage.input_tokens,
        output: response.usage.output_tokens,
        total: response.usage.input_tokens + response.usage.output_tokens
      },
      status: 'success',
      metadata: {
        task_id: 'task-123',
        worker_id: 'worker-456'
      }
    });

    return response;

  } catch (error) {
    const duration = Date.now() - startTime;

    // Track failed LLM call
    trackLLMCall({
      provider: 'anthropic',
      model: 'claude-3-opus-20240229',
      operation: 'messages.create',
      duration: duration,
      tokens: { input: 0, output: 0, total: 0 },
      status: 'error',
      metadata: {
        error: error.message
      }
    });

    throw error;
  }
}

// ============================================================================
// Example 2: Track Worker Spawn
// ============================================================================

async function exampleTrackWorkerSpawn() {
  const startTime = Date.now();

  try {
    // Spawn worker process (pseudo-code)
    const worker = await spawnWorker({
      type: 'implementation-worker',
      taskId: 'task-789',
      master: 'development-master'
    });

    const spawnDuration = Date.now() - startTime;

    // Track successful spawn
    trackWorkerSpawn({
      workerId: worker.id,
      workerType: 'implementation-worker',
      taskId: 'task-789',
      master: 'development-master',
      spawnDuration: spawnDuration,
      status: 'success',
      metadata: {
        pid: worker.pid,
        command: worker.command
      }
    });

    return worker;

  } catch (error) {
    const spawnDuration = Date.now() - startTime;

    // Track failed spawn
    trackWorkerSpawn({
      workerId: 'unknown',
      workerType: 'implementation-worker',
      taskId: 'task-789',
      master: 'development-master',
      spawnDuration: spawnDuration,
      status: 'failed',
      metadata: {
        error: error.message
      }
    });

    throw error;
  }
}

// ============================================================================
// Example 3: Track Custom Business Operation with Span
// ============================================================================

async function exampleCustomSpan() {
  // Wrap expensive operation in custom span
  const result = await withCustomSpan('analyze-codebase', 'business.operation', async () => {
    // Perform analysis
    const files = await scanDirectory('./src');
    const analysis = await analyzeFiles(files);

    // Add metrics as labels
    addLabels({
      'analysis.files_scanned': files.length,
      'analysis.issues_found': analysis.issues.length,
      'analysis.complexity_score': analysis.complexityScore
    });

    return analysis;
  });

  return result;
}

// ============================================================================
// Example 4: Instrument API Endpoint (Complete Example)
// ============================================================================

function exampleAPIEndpointInstrumentation(app) {
  app.post('/api/code-analysis', async (req, res) => {
    const { withCustomSpan, addLabels, trackLLMCall } = require('../utils/apm-events');

    try {
      // Step 1: Parse and validate input (custom span)
      const input = await withCustomSpan('parse-input', 'validation', async () => {
        return validateCodeAnalysisRequest(req.body);
      });

      // Step 2: Analyze code (custom span)
      const analysis = await withCustomSpan('static-analysis', 'analysis', async () => {
        return performStaticAnalysis(input.code);
      });

      // Step 3: Get AI insights (track LLM call)
      const startTime = Date.now();
      const aiInsights = await anthropic.messages.create({
        model: 'claude-3-sonnet-20240229',
        max_tokens: 2000,
        messages: [{
          role: 'user',
          content: `Analyze this code:\n\n${input.code}\n\nStatic analysis found: ${JSON.stringify(analysis)}`
        }]
      });

      trackLLMCall({
        provider: 'anthropic',
        model: 'claude-3-sonnet-20240229',
        operation: 'messages.create',
        duration: Date.now() - startTime,
        tokens: {
          input: aiInsights.usage.input_tokens,
          output: aiInsights.usage.output_tokens,
          total: aiInsights.usage.input_tokens + aiInsights.usage.output_tokens
        },
        status: 'success',
        metadata: {
          endpoint: '/api/code-analysis',
          code_length: input.code.length
        }
      });

      // Step 4: Add transaction-level labels
      addLabels({
        'code_analysis.lines': input.code.split('\n').length,
        'code_analysis.issues': analysis.issues.length,
        'code_analysis.language': input.language
      });

      // Return response
      res.json({
        staticAnalysis: analysis,
        aiInsights: aiInsights.content[0].text
      });

    } catch (error) {
      console.error('Code analysis error:', error);
      res.status(500).json({ error: 'Analysis failed' });
    }
  });
}

// ============================================================================
// Example 5: Worker Lifecycle Tracking
// ============================================================================

class WorkerWithAPM {
  constructor(workerId, workerType, taskId, master) {
    this.workerId = workerId;
    this.workerType = workerType;
    this.taskId = taskId;
    this.master = master;
    this.startTime = Date.now();
  }

  async spawn() {
    const spawnStart = Date.now();

    try {
      // Spawn worker process
      this.process = await this.executeSpawn();

      // Track spawn
      trackWorkerSpawn({
        workerId: this.workerId,
        workerType: this.workerType,
        taskId: this.taskId,
        master: this.master,
        spawnDuration: Date.now() - spawnStart,
        status: 'success'
      });

      return this;
    } catch (error) {
      trackWorkerSpawn({
        workerId: this.workerId,
        workerType: this.workerType,
        taskId: this.taskId,
        master: this.master,
        spawnDuration: Date.now() - spawnStart,
        status: 'failed',
        metadata: { error: error.message }
      });

      throw error;
    }
  }

  async complete(result) {
    trackAgentEvent('completed', {
      agentId: this.workerId,
      agentType: this.workerType,
      taskId: this.taskId,
      metadata: {
        duration: Date.now() - this.startTime,
        result: result
      }
    });
  }

  async fail(error) {
    trackAgentEvent('failed', {
      agentId: this.workerId,
      agentType: this.workerType,
      taskId: this.taskId,
      metadata: {
        duration: Date.now() - this.startTime,
        error: error.message
      }
    });
  }

  async executeSpawn() {
    // Implementation here
  }
}

// ============================================================================
// Example 6: Batch LLM Calls with Tracking
// ============================================================================

async function exampleBatchLLMCalls(tasks) {
  const results = [];

  for (const task of tasks) {
    const startTime = Date.now();

    try {
      const response = await anthropic.messages.create({
        model: 'claude-3-haiku-20240307', // Use faster model for batch
        max_tokens: 500,
        messages: [{ role: 'user', content: task.prompt }]
      });

      trackLLMCall({
        provider: 'anthropic',
        model: 'claude-3-haiku-20240307',
        operation: 'messages.create',
        duration: Date.now() - startTime,
        tokens: {
          input: response.usage.input_tokens,
          output: response.usage.output_tokens,
          total: response.usage.input_tokens + response.usage.output_tokens
        },
        status: 'success',
        metadata: {
          task_id: task.id,
          batch_index: tasks.indexOf(task),
          batch_size: tasks.length
        }
      });

      results.push({ task: task.id, result: response });

    } catch (error) {
      trackLLMCall({
        provider: 'anthropic',
        model: 'claude-3-haiku-20240307',
        operation: 'messages.create',
        duration: Date.now() - startTime,
        tokens: { input: 0, output: 0, total: 0 },
        status: 'error',
        metadata: {
          task_id: task.id,
          error: error.message
        }
      });

      results.push({ task: task.id, error: error.message });
    }
  }

  // Add batch-level metrics
  addLabels({
    'batch.total_tasks': tasks.length,
    'batch.successful': results.filter(r => !r.error).length,
    'batch.failed': results.filter(r => r.error).length
  });

  return results;
}

// ============================================================================
// Export Examples
// ============================================================================

module.exports = {
  exampleTrackLLMCall,
  exampleTrackWorkerSpawn,
  exampleCustomSpan,
  exampleAPIEndpointInstrumentation,
  WorkerWithAPM,
  exampleBatchLLMCalls
};
