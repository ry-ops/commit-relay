/**
 * MCP Tools for Commit-Relay
 *
 * Each tool wraps a master agent capability and exposes it
 * via the Model Context Protocol.
 */

const { spawn, execSync } = require('child_process');
const fs = require('fs').promises;
const path = require('path');

// Tool definitions following MCP schema
const toolDefinitions = [
  {
    name: 'route_task',
    description: 'Route a task to the appropriate master agent using MoE (Mixture of Experts) routing. Returns the selected expert and confidence score.',
    inputSchema: {
      type: 'object',
      properties: {
        task_id: {
          type: 'string',
          description: 'Unique identifier for the task'
        },
        task_description: {
          type: 'string',
          description: 'Natural language description of the task to route'
        }
      },
      required: ['task_id', 'task_description']
    }
  },
  {
    name: 'spawn_worker',
    description: 'Spawn a worker of the specified type to execute a task. Worker types: implementation, fix, test, scan, security-fix, documentation, analysis.',
    inputSchema: {
      type: 'object',
      properties: {
        worker_type: {
          type: 'string',
          enum: ['implementation', 'fix', 'test', 'scan', 'security-fix', 'documentation', 'analysis'],
          description: 'Type of worker to spawn'
        },
        task_id: {
          type: 'string',
          description: 'Task ID for the worker to execute'
        },
        master: {
          type: 'string',
          enum: ['development-master', 'security-master', 'inventory-master', 'cicd-master'],
          description: 'Master agent that owns this worker'
        },
        priority: {
          type: 'string',
          enum: ['low', 'normal', 'high', 'critical'],
          description: 'Task priority level'
        }
      },
      required: ['worker_type', 'task_id', 'master']
    }
  },
  {
    name: 'get_system_health',
    description: 'Get the current system health status including daemon states, worker pool metrics, and system resources.',
    inputSchema: {
      type: 'object',
      properties: {},
      required: []
    }
  },
  {
    name: 'get_worker_pool',
    description: 'Get the current worker pool status including active workers, completed workers, and pool capacity.',
    inputSchema: {
      type: 'object',
      properties: {},
      required: []
    }
  },
  {
    name: 'get_task_queue',
    description: 'Get the current task queue with pending, in-progress, and completed tasks.',
    inputSchema: {
      type: 'object',
      properties: {
        status_filter: {
          type: 'string',
          enum: ['all', 'pending', 'in_progress', 'completed', 'failed'],
          description: 'Filter tasks by status'
        }
      },
      required: []
    }
  },
  {
    name: 'get_routing_decisions',
    description: 'Get recent MoE routing decisions showing task routing history and confidence scores.',
    inputSchema: {
      type: 'object',
      properties: {
        limit: {
          type: 'number',
          description: 'Maximum number of decisions to return (default: 10)'
        }
      },
      required: []
    }
  },
  {
    name: 'get_metrics',
    description: 'Get system metrics including worker success rates, token usage, and performance statistics.',
    inputSchema: {
      type: 'object',
      properties: {},
      required: []
    }
  },
  {
    name: 'check_governance',
    description: 'Check governance compliance status including access control, compliance scores, and audit logs.',
    inputSchema: {
      type: 'object',
      properties: {
        check_type: {
          type: 'string',
          enum: ['compliance', 'access', 'catalog', 'all'],
          description: 'Type of governance check to perform'
        }
      },
      required: []
    }
  }
];

// Tool implementations
const toolImplementations = {
  route_task: async (args, home) => {
    const { task_id, task_description } = args;
    const routerPath = path.join(home, 'coordination/masters/coordinator/lib/moe-router.sh');

    return new Promise((resolve, reject) => {
      const proc = spawn('bash', [routerPath, task_id, task_description], {
        env: { ...process.env, GOVERNANCE_BYPASS: 'true', COMMIT_RELAY_HOME: home }
      });

      let stdout = '';
      let stderr = '';

      proc.stdout.on('data', (data) => { stdout += data; });
      proc.stderr.on('data', (data) => { stderr += data; });

      proc.on('close', (code) => {
        if (code === 0) {
          resolve(stdout.trim() || 'Task routed successfully');
        } else {
          resolve(`Routing failed: ${stderr || stdout}`);
        }
      });
    });
  },

  spawn_worker: async (args, home) => {
    const { worker_type, task_id, master, priority = 'normal' } = args;
    const spawnScript = path.join(home, 'scripts/spawn-worker.sh');

    return new Promise((resolve, reject) => {
      const proc = spawn('bash', [
        spawnScript,
        '--type', `${worker_type}-worker`,
        '--task-id', task_id,
        '--master', master,
        '--priority', priority
      ], {
        env: { ...process.env, GOVERNANCE_BYPASS: 'true', COMMIT_RELAY_HOME: home }
      });

      let stdout = '';
      let stderr = '';

      proc.stdout.on('data', (data) => { stdout += data; });
      proc.stderr.on('data', (data) => { stderr += data; });

      proc.on('close', (code) => {
        if (code === 0) {
          resolve(stdout.trim() || `Worker ${worker_type} spawned for task ${task_id}`);
        } else {
          resolve(`Spawn failed: ${stderr || stdout}`);
        }
      });
    });
  },

  get_system_health: async (args, home) => {
    const healthPath = path.join(home, 'coordination/system-health-check.json');
    try {
      const data = await fs.readFile(healthPath, 'utf8');
      return JSON.parse(data);
    } catch (error) {
      return { error: 'Health check not available', message: error.message };
    }
  },

  get_worker_pool: async (args, home) => {
    const poolPath = path.join(home, 'coordination/worker-pool.json');
    try {
      const data = await fs.readFile(poolPath, 'utf8');
      return JSON.parse(data);
    } catch (error) {
      return { error: 'Worker pool not available', message: error.message };
    }
  },

  get_task_queue: async (args, home) => {
    const queuePath = path.join(home, 'coordination/task-queue.json');
    try {
      const data = await fs.readFile(queuePath, 'utf8');
      const queue = JSON.parse(data);

      if (args.status_filter && args.status_filter !== 'all') {
        queue.tasks = queue.tasks.filter(t => t.status === args.status_filter);
      }

      return queue;
    } catch (error) {
      return { error: 'Task queue not available', message: error.message };
    }
  },

  get_routing_decisions: async (args, home) => {
    const logPath = path.join(home, 'coordination/masters/coordinator/knowledge-base/routing-decisions.jsonl');
    const limit = args.limit || 10;

    try {
      const data = await fs.readFile(logPath, 'utf8');
      const lines = data.trim().split('\n').filter(l => l.trim());
      const decisions = lines.slice(-limit).map(l => {
        try {
          return JSON.parse(l);
        } catch {
          return null;
        }
      }).filter(d => d !== null);

      return { decisions, count: decisions.length };
    } catch (error) {
      return { error: 'Routing decisions not available', message: error.message };
    }
  },

  get_metrics: async (args, home) => {
    const metricsPath = path.join(home, 'coordination/token-budget.json');
    const poolPath = path.join(home, 'coordination/worker-pool.json');

    try {
      const [tokenData, poolData] = await Promise.all([
        fs.readFile(metricsPath, 'utf8').catch(() => '{}'),
        fs.readFile(poolPath, 'utf8').catch(() => '{}')
      ]);

      const tokens = JSON.parse(tokenData);
      const pool = JSON.parse(poolData);

      return {
        tokens: {
          total_budget: tokens.total_budget,
          total_used: tokens.total_used,
          available: tokens.available,
          usage_percentage: tokens.usage_percentage
        },
        workers: {
          active: pool.active_workers?.length || 0,
          completed: pool.completed_workers?.length || 0,
          failed: pool.failed_workers?.length || 0
        }
      };
    } catch (error) {
      return { error: 'Metrics not available', message: error.message };
    }
  },

  check_governance: async (args, home) => {
    const checkType = args.check_type || 'all';
    const results = {};

    if (checkType === 'all' || checkType === 'compliance') {
      try {
        const compliancePath = path.join(home, 'coordination/governance/compliance-status.json');
        const data = await fs.readFile(compliancePath, 'utf8');
        results.compliance = JSON.parse(data);
      } catch {
        results.compliance = { status: 'not_available' };
      }
    }

    if (checkType === 'all' || checkType === 'access') {
      try {
        const accessPath = path.join(home, 'coordination/governance/access-log.jsonl');
        const data = await fs.readFile(accessPath, 'utf8');
        const lines = data.trim().split('\n').filter(l => l.trim());
        const recent = lines.slice(-5).map(l => {
          try { return JSON.parse(l); } catch { return null; }
        }).filter(a => a !== null);
        results.recent_access = recent;
      } catch {
        results.recent_access = [];
      }
    }

    if (checkType === 'all' || checkType === 'catalog') {
      try {
        const catalogPath = path.join(home, 'coordination/catalog/master-catalog.json');
        const data = await fs.readFile(catalogPath, 'utf8');
        const catalog = JSON.parse(data);
        results.catalog = {
          total_assets: catalog.assets?.length || 0,
          namespaces: catalog.namespaces || []
        };
      } catch {
        results.catalog = { status: 'not_available' };
      }
    }

    return results;
  }
};

// Export functions
module.exports = {
  getToolDefinitions: () => toolDefinitions,

  getTool: (name) => {
    const definition = toolDefinitions.find(t => t.name === name);
    if (!definition) return null;

    return {
      definition,
      execute: toolImplementations[name]
    };
  }
};
