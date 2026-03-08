#!/usr/bin/env node
// lib/rag/freshness/reindexer.js
// Re-indexing Manager for Stale Documents
// Finds and refreshes documents that have become stale

const path = require('path');
const fs = require('fs').promises;
const { FreshnessScorer } = require('./scorer');

/**
 * ReindexManager - Manages document re-indexing for freshness
 *
 * Responsible for:
 *   - Finding stale documents below freshness threshold
 *   - Refreshing documents from their sources
 *   - Scheduling periodic re-indexing
 *   - Tracking re-indexing history and metrics
 */
class ReindexManager {
  constructor(vectorStore, config = {}) {
    this.vectorStore = vectorStore;
    this.scorer = new FreshnessScorer(config.scorer || {});
    this.config = {
      freshnessThreshold: config.freshnessThreshold || 0.3,
      batchSize: config.batchSize || 50,
      reindexCooldownMs: config.reindexCooldownMs || 3600000, // 1 hour
      maxConcurrentRefreshes: config.maxConcurrentRefreshes || 5,
      retryAttempts: config.retryAttempts || 3,
      retryDelayMs: config.retryDelayMs || 5000,
      ...config
    };

    // Source connectors for refreshing documents
    this.sourceConnectors = new Map();

    // Re-indexing state
    this.reindexHistory = [];
    this.lastReindexByDoc = new Map();
    this.isRunning = false;

    // Scheduled task handle
    this.scheduledTask = null;
  }

  /**
   * Register a source connector for document refresh
   * @param {string} sourceType - Source type (e.g., 'github', 'confluence', 'file')
   * @param {Object} connector - Connector with refresh capability
   */
  registerSourceConnector(sourceType, connector) {
    this.sourceConnectors.set(sourceType, connector);
  }

  /**
   * Find documents below freshness threshold
   * @param {number} threshold - Freshness threshold (0-1), default from config
   * @param {Object} options - Query options
   * @param {string} options.collection - Specific collection to check
   * @param {number} options.limit - Maximum documents to return
   * @returns {Promise<Array<Object>>} - Stale documents with freshness info
   */
  async findStaleDocuments(threshold = null, options = {}) {
    const freshnessThreshold = threshold || this.config.freshnessThreshold;
    const collection = options.collection || null;
    const limit = options.limit || 100;

    const staleDocuments = [];

    // Get collections to check
    const store = this.vectorStore.getStore();
    const collections = collection
      ? [collection]
      : await store.listCollections();

    for (const collectionName of collections) {
      try {
        // Get all documents from collection
        const documents = await store.getAll(collectionName, {
          limit: this.config.batchSize
        });

        // Calculate freshness for each document
        for (const doc of documents) {
          // Ensure document has required fields for scoring
          const docForScoring = {
            id: doc.id,
            created_at: doc.metadata?.created_at || doc.created_at,
            updated_at: doc.metadata?.updated_at || doc.updated_at,
            ttl_days: doc.metadata?.ttl_days,
            metadata: {
              collection: collectionName,
              ...doc.metadata
            }
          };

          const freshness = this.scorer.calculateFreshness(docForScoring);

          if (freshness.score < freshnessThreshold) {
            staleDocuments.push({
              ...doc,
              collection: collectionName,
              freshness
            });
          }
        }
      } catch (error) {
        console.error(`Error checking collection ${collectionName}: ${error.message}`);
      }
    }

    // Sort by freshness score (lowest first - most stale)
    staleDocuments.sort((a, b) => a.freshness.score - b.freshness.score);

    // Apply limit
    return staleDocuments.slice(0, limit);
  }

  /**
   * Refresh a single document from its source
   * @param {Object} doc - Document to refresh
   * @returns {Promise<Object>} - Refresh result
   */
  async reindexDocument(doc) {
    const startTime = Date.now();
    const docId = doc.id;
    const collection = doc.collection || doc.metadata?.collection;

    // Check cooldown
    const lastReindex = this.lastReindexByDoc.get(docId);
    if (lastReindex && (startTime - lastReindex) < this.config.reindexCooldownMs) {
      return {
        success: false,
        id: docId,
        reason: 'cooldown_active',
        next_allowed: new Date(lastReindex + this.config.reindexCooldownMs).toISOString()
      };
    }

    const result = {
      id: docId,
      collection,
      started_at: new Date(startTime).toISOString(),
      success: false,
      attempts: 0
    };

    try {
      // Determine source type
      const sourceType = doc.metadata?.source_type || doc.metadata?.source || 'unknown';
      const sourcePath = doc.metadata?.source_path || doc.metadata?.file_path;

      // Get appropriate connector
      const connector = this.sourceConnectors.get(sourceType);

      let newContent = null;
      let newMetadata = {};

      if (connector && typeof connector.refresh === 'function') {
        // Use connector to fetch fresh content
        for (let attempt = 1; attempt <= this.config.retryAttempts; attempt++) {
          result.attempts = attempt;
          try {
            const refreshed = await connector.refresh(sourcePath, doc.metadata);
            newContent = refreshed.content;
            newMetadata = refreshed.metadata || {};
            break;
          } catch (error) {
            if (attempt === this.config.retryAttempts) {
              throw error;
            }
            await this._sleep(this.config.retryDelayMs * attempt);
          }
        }
      } else if (sourceType === 'file' && sourcePath) {
        // Default file source handling
        try {
          newContent = await fs.readFile(sourcePath, 'utf-8');
          const stats = await fs.stat(sourcePath);
          newMetadata = {
            file_modified: stats.mtime.toISOString()
          };
        } catch (error) {
          result.error = `File read failed: ${error.message}`;
          return result;
        }
      } else {
        // Cannot refresh - no source connector or path
        result.reason = 'no_refresh_source';
        result.error = `No connector for source type: ${sourceType}`;
        return result;
      }

      if (!newContent) {
        result.reason = 'empty_content';
        result.error = 'Refresh returned empty content';
        return result;
      }

      // Update document in vector store
      const now = new Date().toISOString();
      const store = this.vectorStore.getStore();

      // Generate new embedding
      const embedding = await this.vectorStore._generateEmbedding(newContent);

      // Upsert with updated timestamps
      await store.upsert(collection, [{
        id: docId,
        vector: embedding,
        content: newContent,
        metadata: {
          ...doc.metadata,
          ...newMetadata,
          updated_at: now,
          last_reindexed_at: now,
          reindex_count: (doc.metadata?.reindex_count || 0) + 1
        }
      }]);

      result.success = true;
      result.completed_at = now;
      result.duration_ms = Date.now() - startTime;

      // Update tracking
      this.lastReindexByDoc.set(docId, Date.now());
      this.reindexHistory.push({
        ...result,
        timestamp: now
      });

      // Keep history bounded
      if (this.reindexHistory.length > 1000) {
        this.reindexHistory = this.reindexHistory.slice(-500);
      }

      return result;

    } catch (error) {
      result.error = error.message;
      result.completed_at = new Date().toISOString();
      result.duration_ms = Date.now() - startTime;

      this.reindexHistory.push({
        ...result,
        timestamp: result.completed_at
      });

      return result;
    }
  }

  /**
   * Batch reindex multiple documents
   * @param {Array<Object>} docs - Documents to reindex
   * @param {Object} options - Reindex options
   * @returns {Promise<Object>} - Batch results
   */
  async reindexBatch(docs, options = {}) {
    const maxConcurrent = options.maxConcurrent || this.config.maxConcurrentRefreshes;
    const results = {
      total: docs.length,
      successful: 0,
      failed: 0,
      skipped: 0,
      documents: []
    };

    // Process in batches
    for (let i = 0; i < docs.length; i += maxConcurrent) {
      const batch = docs.slice(i, i + maxConcurrent);
      const batchResults = await Promise.all(
        batch.map(doc => this.reindexDocument(doc))
      );

      for (const result of batchResults) {
        results.documents.push(result);
        if (result.success) {
          results.successful++;
        } else if (result.reason === 'cooldown_active') {
          results.skipped++;
        } else {
          results.failed++;
        }
      }
    }

    return results;
  }

  /**
   * Schedule periodic re-indexing
   * @param {Object} schedule - Schedule configuration
   * @param {number} schedule.intervalMs - Interval between runs (default: 24h)
   * @param {number} schedule.maxDocumentsPerRun - Max documents per run
   * @returns {Object} - Schedule info
   */
  scheduleReindexing(schedule = {}) {
    const intervalMs = schedule.intervalMs || 86400000; // 24 hours default
    const maxDocuments = schedule.maxDocumentsPerRun || 100;

    // Clear existing schedule
    if (this.scheduledTask) {
      clearInterval(this.scheduledTask);
    }

    // Run immediately, then on interval
    const runReindex = async () => {
      if (this.isRunning) {
        console.log('Re-indexing already in progress, skipping scheduled run');
        return;
      }

      this.isRunning = true;
      console.log(`[${new Date().toISOString()}] Starting scheduled re-indexing...`);

      try {
        const staleDocs = await this.findStaleDocuments(null, { limit: maxDocuments });
        console.log(`Found ${staleDocs.length} stale documents`);

        if (staleDocs.length > 0) {
          const results = await this.reindexBatch(staleDocs);
          console.log(`Re-indexing complete: ${results.successful} successful, ${results.failed} failed, ${results.skipped} skipped`);
        }
      } catch (error) {
        console.error(`Scheduled re-indexing failed: ${error.message}`);
      } finally {
        this.isRunning = false;
      }
    };

    // Schedule
    this.scheduledTask = setInterval(runReindex, intervalMs);

    // Run immediately
    runReindex();

    return {
      scheduled: true,
      interval_ms: intervalMs,
      max_documents_per_run: maxDocuments,
      next_run: new Date(Date.now() + intervalMs).toISOString()
    };
  }

  /**
   * Stop scheduled re-indexing
   */
  stopScheduledReindexing() {
    if (this.scheduledTask) {
      clearInterval(this.scheduledTask);
      this.scheduledTask = null;
      return true;
    }
    return false;
  }

  /**
   * Get re-indexing history
   * @param {Object} options - Query options
   * @returns {Array<Object>} - Recent re-indexing history
   */
  getHistory(options = {}) {
    const limit = options.limit || 100;
    const successOnly = options.successOnly || false;

    let history = [...this.reindexHistory];

    if (successOnly) {
      history = history.filter(h => h.success);
    }

    // Most recent first
    history.sort((a, b) => new Date(b.timestamp) - new Date(a.timestamp));

    return history.slice(0, limit);
  }

  /**
   * Get re-indexing statistics
   * @returns {Object} - Re-indexing stats
   */
  getStatistics() {
    const history = this.reindexHistory;
    const last24h = Date.now() - 86400000;

    const recentHistory = history.filter(h => new Date(h.timestamp).getTime() > last24h);

    return {
      total_reindexes: history.length,
      successful: history.filter(h => h.success).length,
      failed: history.filter(h => !h.success && h.error).length,
      skipped: history.filter(h => h.reason === 'cooldown_active').length,
      last_24h: {
        total: recentHistory.length,
        successful: recentHistory.filter(h => h.success).length,
        failed: recentHistory.filter(h => !h.success).length
      },
      is_running: this.isRunning,
      scheduled: this.scheduledTask !== null,
      config: {
        freshness_threshold: this.config.freshnessThreshold,
        cooldown_ms: this.config.reindexCooldownMs,
        max_concurrent: this.config.maxConcurrentRefreshes
      }
    };
  }

  /**
   * Clear re-indexing history
   */
  clearHistory() {
    this.reindexHistory = [];
    this.lastReindexByDoc.clear();
  }

  /**
   * Helper: Sleep for specified duration
   */
  async _sleep(ms) {
    return new Promise(resolve => setTimeout(resolve, ms));
  }
}

// Export class
module.exports = {
  ReindexManager,

  /**
   * Create reindex manager with configuration
   * @param {Object} vectorStore - Vector store instance
   * @param {Object} config - Manager configuration
   * @returns {ReindexManager}
   */
  createReindexManager(vectorStore, config = {}) {
    return new ReindexManager(vectorStore, config);
  }
};

// CLI interface
if (require.main === module) {
  const args = process.argv.slice(2);
  const action = args[0];

  (async () => {
    // Create mock vector store for testing
    const mockVectorStore = {
      getStore: () => ({
        listCollections: async () => ['code', 'documentation', 'patterns'],
        getAll: async (collection) => {
          // Return sample documents of various ages
          const now = Date.now();
          return [
            {
              id: `${collection}-fresh`,
              content: 'Fresh content',
              metadata: {
                collection,
                updated_at: new Date(now - 2 * 24 * 60 * 60 * 1000).toISOString(),
                source_type: 'file'
              }
            },
            {
              id: `${collection}-aging`,
              content: 'Aging content',
              metadata: {
                collection,
                updated_at: new Date(now - 10 * 24 * 60 * 60 * 1000).toISOString(),
                source_type: 'file'
              }
            },
            {
              id: `${collection}-stale`,
              content: 'Stale content',
              metadata: {
                collection,
                updated_at: new Date(now - 30 * 24 * 60 * 60 * 1000).toISOString(),
                source_type: 'file'
              }
            }
          ];
        }
      }),
      _generateEmbedding: async () => new Array(1536).fill(0)
    };

    const manager = new ReindexManager(mockVectorStore);

    switch (action) {
      case 'find-stale':
        const threshold = parseFloat(args[1]) || 0.3;
        console.log(`Finding stale documents (threshold: ${threshold})...\n`);

        const staleDocs = await manager.findStaleDocuments(threshold);
        console.log(`Found ${staleDocs.length} stale documents:\n`);

        for (const doc of staleDocs) {
          console.log(`  ${doc.id}:`);
          console.log(`    Collection: ${doc.collection}`);
          console.log(`    Score: ${doc.freshness.score.toFixed(3)} (${doc.freshness.status})`);
          console.log(`    Age: ${doc.freshness.age_days} days`);
          console.log('');
        }
        break;

      case 'stats':
        console.log('Re-indexing Statistics:');
        console.log(JSON.stringify(manager.getStatistics(), null, 2));
        break;

      default:
        console.log('Usage: node reindexer.js <action>');
        console.log('Actions:');
        console.log('  find-stale [threshold]  - Find stale documents');
        console.log('  stats                   - Show re-indexing stats');
        break;
    }
  })();
}
