#!/usr/bin/env node
// lib/rag/freshness/scorer.js
// Knowledge Freshness Scoring System
// Calculates freshness scores for RAG documents based on age vs TTL

const path = require('path');
const fs = require('fs').promises;

// Default TTLs per collection (in days)
const DEFAULT_TTLS = {
  code: 7,
  documentation: 30,
  patterns: 14,
  decisions: 30,
  tasks: 7,
  default: 14
};

/**
 * FreshnessScorer - Calculates document freshness scores
 *
 * Freshness is calculated as:
 *   score = 1 - (age / ttl)
 *   clamped to [0, 1]
 *
 * Where:
 *   - age = current_time - document_updated_at
 *   - ttl = time-to-live for the collection
 */
class FreshnessScorer {
  constructor(config = {}) {
    this.ttls = { ...DEFAULT_TTLS, ...config.ttls };
    this.decayFunction = config.decayFunction || 'linear';
    this.gracePeriodDays = config.gracePeriodDays || 0;
  }

  /**
   * Calculate freshness score for a document
   * @param {Object} doc - Document with timestamps and metadata
   * @param {string} doc.id - Document ID
   * @param {string} doc.created_at - Creation timestamp (ISO 8601)
   * @param {string} doc.updated_at - Last update timestamp (ISO 8601)
   * @param {number} doc.ttl_days - Custom TTL for document (optional)
   * @param {Object} doc.metadata - Document metadata
   * @param {string} doc.metadata.collection - Collection name
   * @returns {Object} - Freshness assessment
   */
  calculateFreshness(doc) {
    const now = Date.now();

    // Get timestamps
    const updatedAt = doc.updated_at
      ? new Date(doc.updated_at).getTime()
      : (doc.created_at ? new Date(doc.created_at).getTime() : now);

    const createdAt = doc.created_at
      ? new Date(doc.created_at).getTime()
      : updatedAt;

    // Get TTL for this document
    const collection = doc.metadata?.collection || 'default';
    const ttlDays = doc.ttl_days || this.ttls[collection] || this.ttls.default;
    const ttlMs = ttlDays * 24 * 60 * 60 * 1000;

    // Calculate age
    const ageMs = now - updatedAt;
    const ageDays = ageMs / (24 * 60 * 60 * 1000);

    // Apply grace period
    const effectiveAgeMs = Math.max(0, ageMs - (this.gracePeriodDays * 24 * 60 * 60 * 1000));

    // Calculate freshness score based on decay function
    let score;
    switch (this.decayFunction) {
      case 'exponential':
        // Faster initial decay, slower at the end
        score = Math.exp(-2 * effectiveAgeMs / ttlMs);
        break;

      case 'logarithmic':
        // Slower initial decay, faster at the end
        const logDecay = 1 - Math.log(1 + effectiveAgeMs / ttlMs) / Math.log(2);
        score = Math.max(0, logDecay);
        break;

      case 'step':
        // Binary: fresh or stale
        score = effectiveAgeMs <= ttlMs ? 1 : 0;
        break;

      case 'linear':
      default:
        // Linear decay from 1 to 0
        score = 1 - (effectiveAgeMs / ttlMs);
        break;
    }

    // Clamp score to [0, 1]
    score = Math.max(0, Math.min(1, score));

    // Determine freshness status
    let status;
    if (score >= 0.7) {
      status = 'fresh';
    } else if (score >= 0.4) {
      status = 'aging';
    } else if (score > 0) {
      status = 'stale';
    } else {
      status = 'expired';
    }

    return {
      id: doc.id,
      score: Math.round(score * 1000) / 1000, // Round to 3 decimal places
      status,
      age_days: Math.round(ageDays * 10) / 10,
      ttl_days: ttlDays,
      time_remaining_days: Math.max(0, Math.round((ttlMs - ageMs) / (24 * 60 * 60 * 1000) * 10) / 10),
      created_at: new Date(createdAt).toISOString(),
      updated_at: new Date(updatedAt).toISOString(),
      collection,
      needs_refresh: score < 0.3
    };
  }

  /**
   * Calculate freshness scores for multiple documents
   * @param {Array<Object>} docs - Array of documents
   * @returns {Array<Object>} - Array of freshness assessments
   */
  calculateBatch(docs) {
    return docs.map(doc => this.calculateFreshness(doc));
  }

  /**
   * Get collection TTL
   * @param {string} collection - Collection name
   * @returns {number} - TTL in days
   */
  getTTL(collection) {
    return this.ttls[collection] || this.ttls.default;
  }

  /**
   * Set collection TTL
   * @param {string} collection - Collection name
   * @param {number} ttlDays - TTL in days
   */
  setTTL(collection, ttlDays) {
    this.ttls[collection] = ttlDays;
  }

  /**
   * Get all TTLs
   * @returns {Object} - TTL configuration
   */
  getAllTTLs() {
    return { ...this.ttls };
  }

  /**
   * Load TTLs from policy file
   * @param {string} policyPath - Path to freshness policy JSON
   */
  async loadPolicyFromFile(policyPath) {
    try {
      const content = await fs.readFile(policyPath, 'utf-8');
      const policy = JSON.parse(content);

      if (policy.ttl_per_collection) {
        // Parse TTL strings like "7d" into numbers
        for (const [collection, ttl] of Object.entries(policy.ttl_per_collection)) {
          if (typeof ttl === 'string') {
            const match = ttl.match(/^(\d+)([dhm])$/);
            if (match) {
              const value = parseInt(match[1], 10);
              const unit = match[2];
              switch (unit) {
                case 'd':
                  this.ttls[collection] = value;
                  break;
                case 'h':
                  this.ttls[collection] = value / 24;
                  break;
                case 'm':
                  this.ttls[collection] = value / (24 * 60);
                  break;
              }
            }
          } else if (typeof ttl === 'number') {
            this.ttls[collection] = ttl;
          }
        }
      }

      if (policy.decay_function) {
        this.decayFunction = policy.decay_function;
      }

      if (policy.grace_period_days) {
        this.gracePeriodDays = policy.grace_period_days;
      }

      return true;
    } catch (error) {
      console.error(`Failed to load freshness policy: ${error.message}`);
      return false;
    }
  }

  /**
   * Get statistics about document freshness
   * @param {Array<Object>} docs - Array of documents
   * @returns {Object} - Freshness statistics
   */
  getStatistics(docs) {
    const assessments = this.calculateBatch(docs);

    const stats = {
      total: assessments.length,
      by_status: {
        fresh: 0,
        aging: 0,
        stale: 0,
        expired: 0
      },
      average_score: 0,
      median_score: 0,
      needs_refresh: 0,
      by_collection: {}
    };

    if (assessments.length === 0) {
      return stats;
    }

    // Calculate statistics
    let totalScore = 0;
    const scores = [];

    for (const assessment of assessments) {
      totalScore += assessment.score;
      scores.push(assessment.score);
      stats.by_status[assessment.status]++;

      if (assessment.needs_refresh) {
        stats.needs_refresh++;
      }

      // By collection
      if (!stats.by_collection[assessment.collection]) {
        stats.by_collection[assessment.collection] = {
          count: 0,
          total_score: 0,
          needs_refresh: 0
        };
      }
      stats.by_collection[assessment.collection].count++;
      stats.by_collection[assessment.collection].total_score += assessment.score;
      if (assessment.needs_refresh) {
        stats.by_collection[assessment.collection].needs_refresh++;
      }
    }

    // Calculate averages
    stats.average_score = Math.round((totalScore / assessments.length) * 1000) / 1000;

    // Calculate median
    scores.sort((a, b) => a - b);
    const mid = Math.floor(scores.length / 2);
    stats.median_score = scores.length % 2 === 0
      ? (scores[mid - 1] + scores[mid]) / 2
      : scores[mid];
    stats.median_score = Math.round(stats.median_score * 1000) / 1000;

    // Calculate per-collection averages
    for (const [collection, data] of Object.entries(stats.by_collection)) {
      data.average_score = Math.round((data.total_score / data.count) * 1000) / 1000;
      delete data.total_score;
    }

    return stats;
  }

  /**
   * Create scorer instance from policy file
   * @param {string} policyPath - Path to freshness policy JSON
   * @returns {Promise<FreshnessScorer>} - Configured scorer
   */
  static async fromPolicy(policyPath) {
    const scorer = new FreshnessScorer();
    await scorer.loadPolicyFromFile(policyPath);
    return scorer;
  }
}

// Export class and helper functions
module.exports = {
  FreshnessScorer,
  DEFAULT_TTLS,

  /**
   * Calculate freshness for a single document
   * @param {Object} doc - Document
   * @param {Object} config - Optional scorer config
   * @returns {Object} - Freshness assessment
   */
  calculateFreshness(doc, config = {}) {
    const scorer = new FreshnessScorer(config);
    return scorer.calculateFreshness(doc);
  },

  /**
   * Create scorer with custom TTLs
   * @param {Object} ttls - TTL configuration
   * @returns {FreshnessScorer}
   */
  createScorer(ttls = {}) {
    return new FreshnessScorer({ ttls });
  }
};

// CLI interface
if (require.main === module) {
  const args = process.argv.slice(2);
  const action = args[0];

  (async () => {
    const scorer = new FreshnessScorer();

    switch (action) {
      case 'ttls':
        console.log('Default TTLs (days):');
        console.log(JSON.stringify(scorer.getAllTTLs(), null, 2));
        break;

      case 'score':
        // Test scoring with a sample document
        const testDoc = {
          id: 'test-doc-1',
          created_at: new Date(Date.now() - 5 * 24 * 60 * 60 * 1000).toISOString(),
          updated_at: new Date(Date.now() - 3 * 24 * 60 * 60 * 1000).toISOString(),
          metadata: { collection: args[1] || 'code' }
        };

        console.log('Test Document:');
        console.log(JSON.stringify(testDoc, null, 2));
        console.log('\nFreshness Assessment:');
        console.log(JSON.stringify(scorer.calculateFreshness(testDoc), null, 2));
        break;

      case 'demo':
        // Demo with various document ages
        const collections = ['code', 'documentation', 'patterns'];
        const ages = [1, 5, 10, 20, 40];

        console.log('Freshness Scoring Demo:\n');

        for (const collection of collections) {
          console.log(`Collection: ${collection} (TTL: ${scorer.getTTL(collection)}d)`);
          console.log('-'.repeat(50));

          for (const age of ages) {
            const doc = {
              id: `demo-${collection}-${age}d`,
              updated_at: new Date(Date.now() - age * 24 * 60 * 60 * 1000).toISOString(),
              metadata: { collection }
            };

            const result = scorer.calculateFreshness(doc);
            console.log(`  Age: ${age}d -> Score: ${result.score.toFixed(3)} (${result.status})`);
          }
          console.log('');
        }
        break;

      default:
        console.log('Usage: node scorer.js <action>');
        console.log('Actions:');
        console.log('  ttls                    - Show default TTLs');
        console.log('  score [collection]      - Score a test document');
        console.log('  demo                    - Show scoring demo');
        break;
    }
  })();
}
