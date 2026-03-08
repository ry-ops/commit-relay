/**
 * Circuit Breaker Integrations
 *
 * Pre-configured circuit breakers for common operations in commit-relay:
 * - Dashboard server API calls
 * - GitHub API interactions
 * - Worker spawn operations
 *
 * These integrations provide:
 * - Automatic retry logic for transient failures
 * - Rate limit handling with exponential backoff
 * - Metrics and logging
 * - Graceful degradation
 */

const { createApiCircuitBreaker, createRateLimitBreaker } = require('./circuit-breaker');
const { spawn } = require('child_process');
const fs = require('fs').promises;
const path = require('path');

// Directory for circuit breaker logs
const COMMIT_RELAY_HOME = process.env.COMMIT_RELAY_HOME || path.join(__dirname, '..');
const BREAKER_LOG_DIR = path.join(COMMIT_RELAY_HOME, 'coordination', 'circuit-breakers');

// Ensure log directory exists
async function ensureLogDirectory() {
  try {
    await fs.mkdir(BREAKER_LOG_DIR, { recursive: true });
  } catch (error) {
    console.error(`Failed to create circuit breaker log directory: ${error.message}`);
  }
}

ensureLogDirectory();

/**
 * Dashboard Server API Circuit Breaker
 *
 * Protects dashboard server API calls from cascading failures
 */
class DashboardApiBreaker {
  constructor() {
    // Create breaker for file read operations
    this.fileReadBreaker = createApiCircuitBreaker(
      async (filePath) => {
        const content = await fs.readFile(filePath, 'utf-8');
        return JSON.parse(content);
      },
      {
        name: 'dashboard-file-read',
        failureThreshold: 5,
        failureWindow: 60000,
        openTimeout: 30000,
        successThreshold: 3
      }
    );
    this.fileReadBreaker.setLogFile(path.join(BREAKER_LOG_DIR, 'dashboard-file-read.jsonl'));

    // Create breaker for file write operations
    this.fileWriteBreaker = createApiCircuitBreaker(
      async (filePath, data) => {
        const jsonString = typeof data === 'string' ? data : JSON.stringify(data, null, 2);
        await fs.writeFile(filePath, jsonString, 'utf-8');
        return true;
      },
      {
        name: 'dashboard-file-write',
        failureThreshold: 5,
        failureWindow: 60000,
        openTimeout: 30000,
        successThreshold: 3
      }
    );
    this.fileWriteBreaker.setLogFile(path.join(BREAKER_LOG_DIR, 'dashboard-file-write.jsonl'));

    // Create breaker for external API calls
    this.externalApiBreaker = createRateLimitBreaker(
      async (url, options = {}) => {
        const fetch = require('node-fetch');
        const response = await fetch(url, options);

        if (response.status === 429) {
          const error = new Error('Rate limit exceeded');
          error.code = 'RATE_LIMIT';
          error.retryAfter = response.headers.get('Retry-After') || 60;
          throw error;
        }

        if (!response.ok) {
          const error = new Error(`HTTP ${response.status}: ${response.statusText}`);
          error.code = 'HTTP_ERROR';
          error.status = response.status;
          throw error;
        }

        return response;
      },
      {
        name: 'dashboard-external-api',
        failureThreshold: 3,
        failureWindow: 60000,
        openTimeout: 45000,
        successThreshold: 2
      }
    );
    this.externalApiBreaker.setLogFile(path.join(BREAKER_LOG_DIR, 'dashboard-external-api.jsonl'));
  }

  /**
   * Read JSON file with circuit breaker protection
   */
  async readJSON(filePath) {
    return this.fileReadBreaker.execute(filePath);
  }

  /**
   * Write JSON file with circuit breaker protection
   */
  async writeJSON(filePath, data) {
    return this.fileWriteBreaker.execute(filePath, data);
  }

  /**
   * Make external API call with circuit breaker protection
   */
  async fetchApi(url, options = {}) {
    return this.externalApiBreaker.execute(url, options);
  }

  /**
   * Get all metrics
   */
  getMetrics() {
    return {
      fileRead: this.fileReadBreaker.getMetrics(),
      fileWrite: this.fileWriteBreaker.getMetrics(),
      externalApi: this.externalApiBreaker.getMetrics()
    };
  }
}

/**
 * GitHub API Circuit Breaker
 *
 * Protects GitHub API interactions with rate limit awareness
 */
class GitHubApiBreaker {
  constructor() {
    this.breaker = createRateLimitBreaker(
      async (command, args = []) => {
        return new Promise((resolve, reject) => {
          const proc = spawn('gh', [command, ...args], {
            cwd: COMMIT_RELAY_HOME,
            stdio: 'pipe'
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
            if (code === 0) {
              resolve(stdout.trim());
            } else {
              // Check for rate limit error
              if (stderr.includes('rate limit') || stderr.includes('API rate limit')) {
                const error = new Error('GitHub API rate limit exceeded');
                error.code = 'GITHUB_RATE_LIMIT';
                reject(error);
              } else {
                const error = new Error(`GitHub CLI failed: ${stderr}`);
                error.code = 'GITHUB_ERROR';
                reject(error);
              }
            }
          });

          proc.on('error', (error) => {
            reject(error);
          });
        });
      },
      {
        name: 'github-api',
        failureThreshold: 3,
        failureWindow: 60000,
        openTimeout: 60000,  // GitHub rate limits can take longer
        successThreshold: 2
      }
    );
    this.breaker.setLogFile(path.join(BREAKER_LOG_DIR, 'github-api.jsonl'));
  }

  /**
   * Execute GitHub CLI command with circuit breaker protection
   */
  async execute(command, args = []) {
    return this.breaker.execute(command, args);
  }

  /**
   * Get metrics
   */
  getMetrics() {
    return this.breaker.getMetrics();
  }

  /**
   * Common GitHub operations with circuit breaker
   */
  async createPR(title, body, options = {}) {
    const args = ['pr', 'create', '--title', title, '--body', body];
    if (options.base) args.push('--base', options.base);
    if (options.head) args.push('--head', options.head);
    if (options.draft) args.push('--draft');
    return this.execute('pr', args.slice(1));
  }

  async createIssue(title, body, options = {}) {
    const args = ['issue', 'create', '--title', title, '--body', body];
    if (options.assignee) args.push('--assignee', options.assignee);
    if (options.label) args.push('--label', options.label);
    return this.execute('issue', args.slice(1));
  }

  async getIssue(number) {
    return this.execute('issue', ['view', number, '--json', 'title,body,state,labels']);
  }

  async listPRs(options = {}) {
    const args = ['pr', 'list', '--json', 'number,title,state,createdAt'];
    if (options.state) args.push('--state', options.state);
    if (options.limit) args.push('--limit', String(options.limit));
    return this.execute('pr', args.slice(1));
  }
}

/**
 * Worker Spawn Circuit Breaker
 *
 * Protects worker spawning operations from resource exhaustion
 */
class WorkerSpawnBreaker {
  constructor() {
    this.breaker = createApiCircuitBreaker(
      async (workerType, taskId, masterAgent, options = {}) => {
        const scriptPath = path.join(COMMIT_RELAY_HOME, 'scripts', 'spawn-worker.sh');

        const args = [
          '--type', workerType,
          '--task-id', taskId,
          '--master', masterAgent
        ];

        if (options.repo) args.push('--repo', options.repo);
        if (options.budget) args.push('--budget', String(options.budget));
        if (options.priority) args.push('--priority', options.priority);

        return new Promise((resolve, reject) => {
          const proc = spawn(scriptPath, args, {
            cwd: COMMIT_RELAY_HOME,
            stdio: 'pipe'
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
            if (code === 0) {
              // Extract worker ID from output
              const workerIdMatch = stdout.match(/Worker ID:\s+(\S+)/);
              resolve({
                workerId: workerIdMatch ? workerIdMatch[1] : null,
                output: stdout
              });
            } else {
              // Check for token budget exhaustion
              if (stderr.includes('token budget') || stderr.includes('insufficient tokens')) {
                const error = new Error('Token budget exhausted');
                error.code = 'TOKEN_BUDGET_EXHAUSTED';
                reject(error);
              } else {
                const error = new Error(`Worker spawn failed: ${stderr}`);
                error.code = 'SPAWN_ERROR';
                reject(error);
              }
            }
          });

          proc.on('error', (error) => {
            reject(error);
          });
        });
      },
      {
        name: 'worker-spawn',
        failureThreshold: 5,
        failureWindow: 60000,
        openTimeout: 30000,
        successThreshold: 3
      }
    );
    this.breaker.setLogFile(path.join(BREAKER_LOG_DIR, 'worker-spawn.jsonl'));
  }

  /**
   * Spawn worker with circuit breaker protection
   */
  async spawn(workerType, taskId, masterAgent, options = {}) {
    return this.breaker.execute(workerType, taskId, masterAgent, options);
  }

  /**
   * Get metrics
   */
  getMetrics() {
    return this.breaker.getMetrics();
  }
}

/**
 * Circuit Breaker Manager
 *
 * Centralized management of all circuit breakers
 */
class CircuitBreakerManager {
  constructor() {
    this.dashboardApi = new DashboardApiBreaker();
    this.githubApi = new GitHubApiBreaker();
    this.workerSpawn = new WorkerSpawnBreaker();
  }

  /**
   * Get all circuit breaker metrics
   */
  getAllMetrics() {
    return {
      dashboard: this.dashboardApi.getMetrics(),
      github: this.githubApi.getMetrics(),
      workerSpawn: this.workerSpawn.getMetrics(),
      timestamp: new Date().toISOString()
    };
  }

  /**
   * Export metrics to file
   */
  async exportMetrics(filePath = null) {
    const metricsPath = filePath || path.join(BREAKER_LOG_DIR, 'metrics-snapshot.json');
    const metrics = this.getAllMetrics();

    await fs.writeFile(
      metricsPath,
      JSON.stringify(metrics, null, 2),
      'utf-8'
    );

    return metricsPath;
  }

  /**
   * Get health status
   */
  getHealthStatus() {
    const metrics = this.getAllMetrics();

    const status = {
      healthy: true,
      timestamp: metrics.timestamp,
      breakers: {}
    };

    // Check dashboard breakers
    for (const [name, breaker] of Object.entries(metrics.dashboard)) {
      const isOpen = breaker.state === 'OPEN';
      status.breakers[`dashboard-${name}`] = {
        state: breaker.state,
        healthy: !isOpen,
        metrics: {
          totalCalls: breaker.totalCalls,
          successRate: breaker.totalCalls > 0
            ? (breaker.totalSuccesses / breaker.totalCalls * 100).toFixed(2) + '%'
            : 'N/A'
        }
      };
      if (isOpen) status.healthy = false;
    }

    // Check GitHub breaker
    const githubOpen = metrics.github.state === 'OPEN';
    status.breakers.github = {
      state: metrics.github.state,
      healthy: !githubOpen,
      metrics: {
        totalCalls: metrics.github.totalCalls,
        successRate: metrics.github.totalCalls > 0
          ? (metrics.github.totalSuccesses / metrics.github.totalCalls * 100).toFixed(2) + '%'
          : 'N/A'
      }
    };
    if (githubOpen) status.healthy = false;

    // Check worker spawn breaker
    const workerSpawnOpen = metrics.workerSpawn.state === 'OPEN';
    status.breakers.workerSpawn = {
      state: metrics.workerSpawn.state,
      healthy: !workerSpawnOpen,
      metrics: {
        totalCalls: metrics.workerSpawn.totalCalls,
        successRate: metrics.workerSpawn.totalCalls > 0
          ? (metrics.workerSpawn.totalSuccesses / metrics.workerSpawn.totalCalls * 100).toFixed(2) + '%'
          : 'N/A'
      }
    };
    if (workerSpawnOpen) status.healthy = false;

    return status;
  }
}

// Singleton instance
let managerInstance = null;

/**
 * Get or create the circuit breaker manager instance
 */
function getCircuitBreakerManager() {
  if (!managerInstance) {
    managerInstance = new CircuitBreakerManager();
  }
  return managerInstance;
}

module.exports = {
  DashboardApiBreaker,
  GitHubApiBreaker,
  WorkerSpawnBreaker,
  CircuitBreakerManager,
  getCircuitBreakerManager
};
