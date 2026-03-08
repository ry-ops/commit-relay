#!/usr/bin/env node
// lib/rag/connectors/ingestion-scheduler.js
// Scheduled connector execution and batch processing
// Part of RAG Knowledge Ingestion System

const fs = require('fs');
const path = require('path');
const { createConnector } = require('./index');

/**
 * IngestionScheduler - Schedule and manage connector runs
 *
 * Features:
 * - Cron-like scheduling
 * - Queue and batch processing
 * - Progress tracking
 * - Error handling and retry
 * - Event logging
 */
class IngestionScheduler {
  constructor(options = {}) {
    this.configPath = options.configPath ||
      path.join(process.cwd(), 'coordination/config/connectors.json');
    this.logPath = options.logPath ||
      path.join(process.cwd(), 'coordination/metrics/ingestion-history.jsonl');
    this.statePath = options.statePath ||
      path.join(process.cwd(), 'coordination/memory/ingestion-state.json');

    // Queue management
    this.queue = [];
    this.processing = false;
    this.concurrency = options.concurrency || 1;
    this.activeJobs = 0;

    // Connectors
    this.connectors = new Map();

    // Timers
    this.timers = new Map();

    // Progress tracking
    this.progress = new Map();

    // Event callbacks
    this.onJobStart = options.onJobStart || (() => {});
    this.onJobComplete = options.onJobComplete || (() => {});
    this.onJobError = options.onJobError || (() => {});
    this.onProgress = options.onProgress || (() => {});
  }

  /**
   * Load configuration from file
   * @returns {Object} - Configuration
   */
  loadConfig() {
    if (!fs.existsSync(this.configPath)) {
      return { connectors: [], schedules: [] };
    }

    const content = fs.readFileSync(this.configPath, 'utf-8');
    return JSON.parse(content);
  }

  /**
   * Save state to file
   */
  saveState() {
    const state = {
      lastUpdate: new Date().toISOString(),
      connectors: Array.from(this.connectors.keys()),
      queue: this.queue.map(job => ({
        id: job.id,
        connector: job.connectorName,
        status: job.status
      })),
      progress: Object.fromEntries(this.progress)
    };

    const dir = path.dirname(this.statePath);
    if (!fs.existsSync(dir)) {
      fs.mkdirSync(dir, { recursive: true });
    }

    fs.writeFileSync(this.statePath, JSON.stringify(state, null, 2));
  }

  /**
   * Log ingestion event
   * @param {Object} event - Event data
   */
  logEvent(event) {
    const entry = {
      timestamp: new Date().toISOString(),
      ...event
    };

    const dir = path.dirname(this.logPath);
    if (!fs.existsSync(dir)) {
      fs.mkdirSync(dir, { recursive: true });
    }

    fs.appendFileSync(this.logPath, JSON.stringify(entry) + '\n');
  }

  /**
   * Initialize scheduler with connectors
   * @returns {Promise<void>}
   */
  async initialize() {
    const config = this.loadConfig();

    // Create connectors
    for (const connectorConfig of config.connectors || []) {
      if (connectorConfig.enabled === false) continue;

      try {
        const connector = createConnector(
          connectorConfig.type,
          connectorConfig
        );

        const name = connectorConfig.name ||
          `${connectorConfig.type}-${this.connectors.size + 1}`;

        this.connectors.set(name, {
          connector,
          config: connectorConfig,
          schedule: connectorConfig.schedule,
          lastRun: null,
          nextRun: null
        });

        console.log(`Initialized connector: ${name}`);
      } catch (error) {
        console.error(`Failed to initialize connector:`, error.message);
      }
    }

    this.saveState();
  }

  /**
   * Start scheduled jobs
   */
  startSchedules() {
    for (const [name, info] of this.connectors) {
      if (info.schedule) {
        const interval = this.parseSchedule(info.schedule);
        if (interval > 0) {
          const timer = setInterval(() => {
            this.queueJob(name);
          }, interval);

          this.timers.set(name, timer);

          // Calculate next run
          info.nextRun = new Date(Date.now() + interval).toISOString();

          console.log(`Scheduled ${name}: every ${interval / 1000}s`);
        }
      }
    }

    // Start processing queue
    this.processQueue();
  }

  /**
   * Stop all schedules
   */
  stopSchedules() {
    for (const [name, timer] of this.timers) {
      clearInterval(timer);
      console.log(`Stopped schedule: ${name}`);
    }
    this.timers.clear();
  }

  /**
   * Parse schedule string to milliseconds
   * @param {string} schedule - Schedule string (cron or interval)
   * @returns {number} - Interval in milliseconds
   */
  parseSchedule(schedule) {
    // Support simple interval formats
    if (typeof schedule === 'number') {
      return schedule;
    }

    // Parse interval strings like "1h", "30m", "1d"
    const match = schedule.match(/^(\d+)([smhd])$/);
    if (match) {
      const value = parseInt(match[1], 10);
      const unit = match[2];

      switch (unit) {
        case 's': return value * 1000;
        case 'm': return value * 60 * 1000;
        case 'h': return value * 60 * 60 * 1000;
        case 'd': return value * 24 * 60 * 60 * 1000;
      }
    }

    // Parse cron expression (simplified)
    if (schedule.includes(' ') || schedule.startsWith('*/')) {
      return this.parseCronToInterval(schedule);
    }

    return 0;
  }

  /**
   * Parse simplified cron to interval
   * @param {string} cron - Cron expression
   * @returns {number} - Interval in milliseconds
   */
  parseCronToInterval(cron) {
    // Very simplified cron parsing
    // */5 * * * * = every 5 minutes
    const match = cron.match(/^\*\/(\d+)/);
    if (match) {
      const minutes = parseInt(match[1], 10);
      return minutes * 60 * 1000;
    }

    // 0 * * * * = every hour
    if (cron === '0 * * * *') {
      return 60 * 60 * 1000;
    }

    // 0 0 * * * = every day
    if (cron === '0 0 * * *') {
      return 24 * 60 * 60 * 1000;
    }

    // Default to 1 hour
    return 60 * 60 * 1000;
  }

  /**
   * Queue a job for processing
   * @param {string} connectorName - Connector name
   * @param {Object} options - Job options
   * @returns {string} - Job ID
   */
  queueJob(connectorName, options = {}) {
    const jobId = `job-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`;

    const job = {
      id: jobId,
      connectorName,
      options,
      status: 'queued',
      queuedAt: new Date().toISOString(),
      attempts: 0,
      maxAttempts: options.maxAttempts || 3
    };

    this.queue.push(job);
    this.progress.set(jobId, {
      status: 'queued',
      progress: 0,
      total: 0,
      processed: 0
    });

    this.logEvent({
      event: 'job_queued',
      jobId,
      connector: connectorName
    });

    this.saveState();
    this.processQueue();

    return jobId;
  }

  /**
   * Process the job queue
   */
  async processQueue() {
    if (this.processing) return;
    if (this.queue.length === 0) return;
    if (this.activeJobs >= this.concurrency) return;

    this.processing = true;

    while (this.queue.length > 0 && this.activeJobs < this.concurrency) {
      const job = this.queue.shift();
      this.activeJobs++;

      // Process job asynchronously
      this.executeJob(job)
        .catch(error => {
          console.error(`Job ${job.id} error:`, error.message);
        })
        .finally(() => {
          this.activeJobs--;
          this.processQueue();
        });
    }

    this.processing = false;
  }

  /**
   * Execute a job
   * @param {Object} job - Job to execute
   */
  async executeJob(job) {
    const connectorInfo = this.connectors.get(job.connectorName);
    if (!connectorInfo) {
      throw new Error(`Connector not found: ${job.connectorName}`);
    }

    job.status = 'running';
    job.startedAt = new Date().toISOString();
    job.attempts++;

    this.progress.set(job.id, {
      status: 'running',
      progress: 0,
      total: 0,
      processed: 0
    });

    this.onJobStart(job);
    this.logEvent({
      event: 'job_started',
      jobId: job.id,
      connector: job.connectorName,
      attempt: job.attempts
    });

    try {
      const { connector, config } = connectorInfo;

      // Connect if needed
      if (!connector.isConnected()) {
        await connector.connect();
      }

      // Fetch data
      const fetchOptions = { ...config.fetchOptions, ...job.options };
      const rawData = await connector.fetch(fetchOptions);

      // Update progress
      const progress = this.progress.get(job.id);
      progress.status = 'transforming';
      this.onProgress(job.id, progress);

      // Transform data
      const documents = connector.transform(rawData);

      // Complete
      job.status = 'completed';
      job.completedAt = new Date().toISOString();
      job.result = {
        documentCount: documents.length,
        duration: Date.now() - new Date(job.startedAt).getTime()
      };

      progress.status = 'completed';
      progress.progress = 100;
      progress.processed = documents.length;
      progress.total = documents.length;

      // Update connector info
      connectorInfo.lastRun = job.completedAt;

      this.onJobComplete(job, documents);
      this.logEvent({
        event: 'job_completed',
        jobId: job.id,
        connector: job.connectorName,
        documentCount: documents.length,
        duration: job.result.duration
      });

      this.saveState();
      return documents;

    } catch (error) {
      job.status = 'failed';
      job.error = error.message;
      job.failedAt = new Date().toISOString();

      this.progress.get(job.id).status = 'failed';

      this.onJobError(job, error);
      this.logEvent({
        event: 'job_failed',
        jobId: job.id,
        connector: job.connectorName,
        error: error.message,
        attempt: job.attempts
      });

      // Retry if attempts remaining
      if (job.attempts < job.maxAttempts) {
        job.status = 'queued';
        job.error = null;
        this.queue.push(job);
        console.log(`Retrying job ${job.id}, attempt ${job.attempts + 1}`);
      }

      this.saveState();
      throw error;
    }
  }

  /**
   * Run all connectors immediately
   * @returns {Promise<Object>} - Results by connector
   */
  async runAll() {
    const results = {};

    for (const [name] of this.connectors) {
      const jobId = this.queueJob(name);
      results[name] = { jobId };
    }

    return results;
  }

  /**
   * Run a specific connector immediately
   * @param {string} name - Connector name
   * @param {Object} options - Fetch options
   * @returns {Promise<Array>} - Documents
   */
  async runConnector(name, options = {}) {
    const connectorInfo = this.connectors.get(name);
    if (!connectorInfo) {
      throw new Error(`Connector not found: ${name}`);
    }

    const jobId = this.queueJob(name, options);

    // Wait for job to complete
    return new Promise((resolve, reject) => {
      const checkInterval = setInterval(() => {
        const progress = this.progress.get(jobId);
        if (progress.status === 'completed') {
          clearInterval(checkInterval);
          resolve(progress);
        } else if (progress.status === 'failed') {
          clearInterval(checkInterval);
          reject(new Error('Job failed'));
        }
      }, 100);
    });
  }

  /**
   * Get job progress
   * @param {string} jobId - Job ID
   * @returns {Object|null} - Progress info
   */
  getProgress(jobId) {
    return this.progress.get(jobId) || null;
  }

  /**
   * Get all connector statuses
   * @returns {Object}
   */
  getStatus() {
    const status = {
      connectors: {},
      queue: this.queue.length,
      activeJobs: this.activeJobs
    };

    for (const [name, info] of this.connectors) {
      status.connectors[name] = {
        type: info.connector.type,
        connected: info.connector.isConnected(),
        lastRun: info.lastRun,
        nextRun: info.nextRun,
        schedule: info.schedule,
        stats: info.connector.getStats()
      };
    }

    return status;
  }

  /**
   * Health check all connectors
   * @returns {Promise<Object>}
   */
  async healthCheck() {
    const results = {};

    for (const [name, info] of this.connectors) {
      try {
        results[name] = await info.connector.healthCheck();
      } catch (error) {
        results[name] = {
          healthy: false,
          error: error.message
        };
      }
    }

    return results;
  }

  /**
   * Cancel a queued job
   * @param {string} jobId - Job ID
   * @returns {boolean} - Success
   */
  cancelJob(jobId) {
    const index = this.queue.findIndex(job => job.id === jobId);
    if (index >= 0) {
      this.queue.splice(index, 1);
      this.progress.set(jobId, { status: 'cancelled' });
      this.logEvent({
        event: 'job_cancelled',
        jobId
      });
      return true;
    }
    return false;
  }

  /**
   * Clear all queued jobs
   * @returns {number} - Number of jobs cleared
   */
  clearQueue() {
    const count = this.queue.length;
    for (const job of this.queue) {
      this.progress.set(job.id, { status: 'cancelled' });
    }
    this.queue = [];
    this.saveState();
    return count;
  }

  /**
   * Get ingestion history
   * @param {number} limit - Number of entries
   * @returns {Array<Object>}
   */
  getHistory(limit = 100) {
    if (!fs.existsSync(this.logPath)) {
      return [];
    }

    const content = fs.readFileSync(this.logPath, 'utf-8');
    const lines = content.trim().split('\n').filter(Boolean);

    return lines
      .slice(-limit)
      .map(line => {
        try {
          return JSON.parse(line);
        } catch {
          return null;
        }
      })
      .filter(Boolean)
      .reverse();
  }
}

module.exports = IngestionScheduler;

// CLI support
if (require.main === module) {
  const scheduler = new IngestionScheduler();

  const command = process.argv[2];

  switch (command) {
    case 'init':
      scheduler.initialize().then(() => {
        console.log('Scheduler initialized');
        console.log('Status:', JSON.stringify(scheduler.getStatus(), null, 2));
      });
      break;

    case 'run':
      const connectorName = process.argv[3];
      scheduler.initialize().then(async () => {
        if (connectorName) {
          await scheduler.runConnector(connectorName);
        } else {
          await scheduler.runAll();
        }
        console.log('Jobs queued');
      });
      break;

    case 'status':
      scheduler.initialize().then(() => {
        console.log(JSON.stringify(scheduler.getStatus(), null, 2));
      });
      break;

    case 'health':
      scheduler.initialize().then(async () => {
        const health = await scheduler.healthCheck();
        console.log(JSON.stringify(health, null, 2));
      });
      break;

    default:
      console.log('Usage: node ingestion-scheduler.js <command>');
      console.log('Commands:');
      console.log('  init     - Initialize scheduler');
      console.log('  run      - Run all connectors');
      console.log('  run <name> - Run specific connector');
      console.log('  status   - Show status');
      console.log('  health   - Check health');
  }
}
