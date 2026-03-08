#!/usr/bin/env node
// lib/rag/freshness/index.js
// Knowledge Freshness Management Module
// Main entry point for freshness scoring and re-indexing

const path = require('path');
const fs = require('fs').promises;

const { FreshnessScorer, calculateFreshness, createScorer, DEFAULT_TTLS } = require('./scorer');
const { ReindexManager, createReindexManager } = require('./reindexer');

/**
 * FreshnessManager - High-level manager for document freshness
 *
 * Combines scoring and re-indexing into a unified interface:
 *   - Automated freshness monitoring
 *   - Policy-based TTL management
 *   - Source connector integration
 *   - Metrics and reporting
 */
class FreshnessManager {
  constructor(vectorStore, config = {}) {
    this.vectorStore = vectorStore;
    this.config = {
      policyPath: config.policyPath || null,
      metricsPath: config.metricsPath || null,
      autoSchedule: config.autoSchedule !== false,
      ...config
    };

    // Initialize components
    this.scorer = new FreshnessScorer(config.scorer || {});
    this.reindexer = new ReindexManager(vectorStore, {
      freshnessThreshold: config.freshnessThreshold || 0.3,
      scorer: config.scorer || {},
      ...config.reindexer
    });

    this.initialized = false;
    this.policy = null;
  }

  /**
   * Initialize freshness manager
   * @returns {Promise<boolean>} - Success status
   */
  async initialize() {
    try {
      // Load policy if path provided
      if (this.config.policyPath) {
        await this.loadPolicy(this.config.policyPath);
      }

      // Auto-schedule re-indexing if enabled
      if (this.config.autoSchedule && this.policy?.schedule) {
        const intervalMs = this._parseInterval(this.policy.schedule.interval || '24h');
        this.reindexer.scheduleReindexing({
          intervalMs,
          maxDocumentsPerRun: this.policy.schedule.max_documents_per_run || 100
        });
      }

      this.initialized = true;
      return true;

    } catch (error) {
      console.error(`Failed to initialize FreshnessManager: ${error.message}`);
      return false;
    }
  }

  /**
   * Load freshness policy from file
   * @param {string} policyPath - Path to policy JSON file
   * @returns {Promise<Object>} - Loaded policy
   */
  async loadPolicy(policyPath) {
    try {
      const content = await fs.readFile(policyPath, 'utf-8');
      this.policy = JSON.parse(content);

      // Apply TTLs to scorer
      if (this.policy.ttl_per_collection) {
        for (const [collection, ttl] of Object.entries(this.policy.ttl_per_collection)) {
          const ttlDays = this._parseTTL(ttl);
          this.scorer.setTTL(collection, ttlDays);
        }
      }

      // Apply freshness threshold
      if (this.policy.freshness_threshold) {
        this.reindexer.config.freshnessThreshold = this.policy.freshness_threshold;
      }

      // Apply decay function
      if (this.policy.decay_function) {
        this.scorer.decayFunction = this.policy.decay_function;
      }

      return this.policy;

    } catch (error) {
      console.error(`Failed to load policy: ${error.message}`);
      throw error;
    }
  }

  /**
   * Get freshness score for a document
   * @param {Object} doc - Document to score
   * @returns {Object} - Freshness assessment
   */
  calculateFreshness(doc) {
    return this.scorer.calculateFreshness(doc);
  }

  /**
   * Find all stale documents
   * @param {Object} options - Query options
   * @returns {Promise<Array<Object>>} - Stale documents
   */
  async findStaleDocuments(options = {}) {
    return this.reindexer.findStaleDocuments(
      options.threshold || this.policy?.freshness_threshold,
      options
    );
  }

  /**
   * Reindex a specific document
   * @param {Object} doc - Document to reindex
   * @returns {Promise<Object>} - Reindex result
   */
  async reindexDocument(doc) {
    return this.reindexer.reindexDocument(doc);
  }

  /**
   * Run a full freshness check and reindex cycle
   * @param {Object} options - Cycle options
   * @returns {Promise<Object>} - Cycle results
   */
  async runFreshnessCycle(options = {}) {
    const startTime = Date.now();
    const threshold = options.threshold || this.policy?.freshness_threshold || 0.3;
    const maxDocuments = options.maxDocuments || 100;

    const result = {
      started_at: new Date(startTime).toISOString(),
      threshold,
      max_documents: maxDocuments
    };

    try {
      // Find stale documents
      const staleDocs = await this.findStaleDocuments({
        threshold,
        limit: maxDocuments
      });

      result.stale_documents_found = staleDocs.length;

      if (staleDocs.length === 0) {
        result.status = 'no_stale_documents';
        result.completed_at = new Date().toISOString();
        result.duration_ms = Date.now() - startTime;
        return result;
      }

      // Reindex stale documents
      const reindexResults = await this.reindexer.reindexBatch(staleDocs);

      result.reindex_results = {
        successful: reindexResults.successful,
        failed: reindexResults.failed,
        skipped: reindexResults.skipped
      };
      result.status = 'completed';
      result.completed_at = new Date().toISOString();
      result.duration_ms = Date.now() - startTime;

      // Save metrics if path configured
      if (this.config.metricsPath) {
        await this._appendMetrics(result);
      }

      return result;

    } catch (error) {
      result.status = 'error';
      result.error = error.message;
      result.completed_at = new Date().toISOString();
      result.duration_ms = Date.now() - startTime;
      return result;
    }
  }

  /**
   * Get overall freshness statistics
   * @returns {Promise<Object>} - Freshness stats
   */
  async getStatistics() {
    const store = this.vectorStore.getStore();
    const collections = await store.listCollections();

    const allDocs = [];

    // Gather all documents
    for (const collection of collections) {
      const docs = await store.getAll(collection);
      for (const doc of docs) {
        allDocs.push({
          ...doc,
          metadata: {
            ...doc.metadata,
            collection
          }
        });
      }
    }

    // Get scoring statistics
    const scoringStats = this.scorer.getStatistics(allDocs);

    // Get reindexing statistics
    const reindexStats = this.reindexer.getStatistics();

    return {
      scoring: scoringStats,
      reindexing: reindexStats,
      policy: this.policy ? {
        freshness_threshold: this.policy.freshness_threshold,
        ttl_per_collection: this.policy.ttl_per_collection
      } : null
    };
  }

  /**
   * Register a source connector
   * @param {string} sourceType - Source type
   * @param {Object} connector - Connector instance
   */
  registerSourceConnector(sourceType, connector) {
    this.reindexer.registerSourceConnector(sourceType, connector);
  }

  /**
   * Schedule periodic freshness management
   * @param {Object} schedule - Schedule configuration
   * @returns {Object} - Schedule info
   */
  scheduleReindexing(schedule = {}) {
    return this.reindexer.scheduleReindexing(schedule);
  }

  /**
   * Stop scheduled reindexing
   */
  stopScheduledReindexing() {
    return this.reindexer.stopScheduledReindexing();
  }

  /**
   * Get TTL configuration
   * @returns {Object} - TTL per collection
   */
  getTTLs() {
    return this.scorer.getAllTTLs();
  }

  /**
   * Set TTL for a collection
   * @param {string} collection - Collection name
   * @param {string|number} ttl - TTL (e.g., '7d' or 7)
   */
  setTTL(collection, ttl) {
    const ttlDays = this._parseTTL(ttl);
    this.scorer.setTTL(collection, ttlDays);
  }

  /**
   * Parse TTL string to days
   * @param {string|number} ttl - TTL value
   * @returns {number} - TTL in days
   */
  _parseTTL(ttl) {
    if (typeof ttl === 'number') {
      return ttl;
    }

    const match = ttl.match(/^(\d+)([dhm])$/);
    if (match) {
      const value = parseInt(match[1], 10);
      const unit = match[2];
      switch (unit) {
        case 'd': return value;
        case 'h': return value / 24;
        case 'm': return value / (24 * 60);
      }
    }

    return parseInt(ttl, 10) || 14;
  }

  /**
   * Parse interval string to milliseconds
   * @param {string} interval - Interval string
   * @returns {number} - Milliseconds
   */
  _parseInterval(interval) {
    const match = interval.match(/^(\d+)([dhms])$/);
    if (match) {
      const value = parseInt(match[1], 10);
      const unit = match[2];
      switch (unit) {
        case 'd': return value * 86400000;
        case 'h': return value * 3600000;
        case 'm': return value * 60000;
        case 's': return value * 1000;
      }
    }

    return parseInt(interval, 10) || 86400000;
  }

  /**
   * Append metrics to metrics file
   * @param {Object} metrics - Metrics to append
   */
  async _appendMetrics(metrics) {
    try {
      const line = JSON.stringify({
        timestamp: new Date().toISOString(),
        ...metrics
      }) + '\n';

      await fs.appendFile(this.config.metricsPath, line);
    } catch (error) {
      console.error(`Failed to write metrics: ${error.message}`);
    }
  }
}

/**
 * Create a freshness manager with configuration
 * @param {Object} vectorStore - Vector store instance
 * @param {Object} config - Configuration options
 * @returns {FreshnessManager}
 */
function createFreshnessManager(vectorStore, config = {}) {
  return new FreshnessManager(vectorStore, config);
}

// Export all components
module.exports = {
  // Main manager
  FreshnessManager,
  createFreshnessManager,

  // Scorer components
  FreshnessScorer,
  calculateFreshness,
  createScorer,
  DEFAULT_TTLS,

  // Reindexer components
  ReindexManager,
  createReindexManager
};

// CLI interface
if (require.main === module) {
  const args = process.argv.slice(2);
  const action = args[0];

  console.log('Knowledge Freshness Management System\n');

  switch (action) {
    case 'info':
      console.log('Components:');
      console.log('  - FreshnessScorer: Calculate document freshness scores');
      console.log('  - ReindexManager: Find and refresh stale documents');
      console.log('  - FreshnessManager: Unified management interface\n');

      console.log('Default TTLs (days):');
      console.log(JSON.stringify(DEFAULT_TTLS, null, 2));
      break;

    case 'help':
    default:
      console.log('Usage: node index.js <action>\n');
      console.log('Actions:');
      console.log('  info    - Show component information');
      console.log('  help    - Show this help message\n');
      console.log('For detailed operations, use individual modules:');
      console.log('  node scorer.js demo      - Show scoring demo');
      console.log('  node reindexer.js find-stale  - Find stale documents');
      break;
  }
}
