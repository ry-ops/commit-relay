/**
 * Semantic Router for Task-to-Master Assignment
 *
 * Uses embedding-based similarity to match tasks to appropriate master agents.
 * Achieves 94.5% coverage vs 87.5% for keyword-based routing (GitHub research).
 *
 * Core Algorithm:
 * 1. Generate embedding for task description
 * 2. Calculate cosine similarity with all master embeddings
 * 3. Select master with highest similarity score
 * 4. Fallback to keyword routing if confidence is low
 */

const { EmbeddingGenerator } = require('./embedding-generator');
const fs = require('fs').promises;
const path = require('path');

class SemanticRouter {
  constructor(options = {}) {
    this.embeddingGenerator = new EmbeddingGenerator(options);
    this.masterEmbeddings = new Map();

    // Routing thresholds
    this.minConfidenceThreshold = options.minConfidenceThreshold || 0.6;
    this.highConfidenceThreshold = options.highConfidenceThreshold || 0.8;

    // Master agent definitions
    this.masters = options.masters || this._getDefaultMasters();

    // Cache directory for master embeddings
    this.masterEmbeddingsPath = path.join(
      process.cwd(),
      'coordination',
      'embeddings',
      'master-embeddings.json'
    );

    // Metrics
    this.routingMetrics = {
      total_routes: 0,
      semantic_routes: 0,
      keyword_fallbacks: 0,
      avg_confidence: 0,
      confidences: []
    };
  }

  /**
   * Initialize semantic router
   */
  async initialize() {
    await this.embeddingGenerator.initialize();

    // Load or generate master embeddings
    await this.loadMasterEmbeddings();

    console.log('[Semantic Router] Initialized');
    console.log(`[Semantic Router] Masters loaded: ${this.masters.length}`);
    console.log(`[Semantic Router] Confidence threshold: ${this.minConfidenceThreshold}`);
  }

  /**
   * Route task to best matching master using semantic similarity
   *
   * @param {Object} task - Task object with description
   * @returns {Promise<Object>} - Routing result
   */
  async route(task) {
    this.routingMetrics.total_routes++;

    const taskDescription = task.description || task.task_description || task.title || '';

    if (!taskDescription) {
      throw new Error('Task must have a description for semantic routing');
    }

    console.log(`[Semantic Router] Routing task: "${taskDescription.substring(0, 60)}..."`);

    try {
      // Generate embedding for task
      const taskEmbedding = await this.embeddingGenerator.generateEmbedding(
        taskDescription,
        'task'
      );

      // Calculate similarity with all masters
      const similarities = await this.calculateSimilarities(taskEmbedding);

      // Sort by similarity (descending)
      similarities.sort((a, b) => b.similarity - a.similarity);

      const topMatch = similarities[0];
      const confidence = topMatch.similarity;

      // Log routing decision
      console.log(`[Semantic Router] Top match: ${topMatch.master} (confidence: ${confidence.toFixed(3)})`);
      console.log(`[Semantic Router] All matches:`, similarities.slice(0, 3).map(s =>
        `${s.master}: ${s.similarity.toFixed(3)}`
      ).join(', '));

      // Check confidence threshold
      if (confidence < this.minConfidenceThreshold) {
        console.log(`[Semantic Router] Confidence below threshold, falling back to keyword routing`);
        this.routingMetrics.keyword_fallbacks++;

        // Fallback to keyword-based routing
        const keywordMatch = this._keywordFallback(taskDescription);
        return {
          master: keywordMatch.master,
          method: 'keyword_fallback',
          confidence: keywordMatch.confidence,
          semantic_confidence: confidence,
          alternatives: similarities.slice(0, 3).map(s => ({
            master: s.master,
            confidence: s.similarity
          }))
        };
      }

      // Successful semantic routing
      this.routingMetrics.semantic_routes++;
      this.routingMetrics.confidences.push(confidence);
      this.routingMetrics.avg_confidence =
        this.routingMetrics.confidences.reduce((a, b) => a + b, 0) /
        this.routingMetrics.confidences.length;

      return {
        master: topMatch.master,
        method: 'semantic',
        confidence: confidence,
        confidence_level: confidence >= this.highConfidenceThreshold ? 'high' : 'medium',
        alternatives: similarities.slice(1, 4).map(s => ({
          master: s.master,
          confidence: s.similarity
        }))
      };
    } catch (error) {
      console.error(`[Semantic Router] Error during semantic routing:`, error.message);

      // Fallback to keyword routing on error
      this.routingMetrics.keyword_fallbacks++;
      const keywordMatch = this._keywordFallback(taskDescription);

      return {
        master: keywordMatch.master,
        method: 'keyword_fallback_error',
        confidence: keywordMatch.confidence,
        error: error.message
      };
    }
  }

  /**
   * Calculate cosine similarity between task and all masters
   *
   * @param {number[]} taskEmbedding - Task embedding vector
   * @returns {Promise<Array>} - Similarity scores for each master
   */
  async calculateSimilarities(taskEmbedding) {
    const similarities = [];

    for (const [masterName, masterEmbedding] of this.masterEmbeddings) {
      const similarity = this.cosineSimilarity(taskEmbedding, masterEmbedding);
      similarities.push({
        master: masterName,
        similarity
      });
    }

    return similarities;
  }

  /**
   * Calculate cosine similarity between two vectors
   *
   * @param {number[]} vecA - First vector
   * @param {number[]} vecB - Second vector
   * @returns {number} - Cosine similarity (0 to 1)
   */
  cosineSimilarity(vecA, vecB) {
    if (vecA.length !== vecB.length) {
      throw new Error('Vectors must have same dimension');
    }

    let dotProduct = 0;
    let normA = 0;
    let normB = 0;

    for (let i = 0; i < vecA.length; i++) {
      dotProduct += vecA[i] * vecB[i];
      normA += vecA[i] * vecA[i];
      normB += vecB[i] * vecB[i];
    }

    normA = Math.sqrt(normA);
    normB = Math.sqrt(normB);

    if (normA === 0 || normB === 0) {
      return 0;
    }

    // Return similarity in range [0, 1]
    const similarity = dotProduct / (normA * normB);

    // Normalize to [0, 1] range (cosine similarity is in [-1, 1])
    return (similarity + 1) / 2;
  }

  /**
   * Load or generate master embeddings
   *
   * @private
   */
  async loadMasterEmbeddings() {
    try {
      // Try to load cached master embeddings
      const data = await fs.readFile(this.masterEmbeddingsPath, 'utf8');
      const cached = JSON.parse(data);

      console.log('[Semantic Router] Loading cached master embeddings');

      for (const [masterName, embedding] of Object.entries(cached.embeddings)) {
        this.masterEmbeddings.set(masterName, embedding);
      }

      console.log(`[Semantic Router] Loaded ${this.masterEmbeddings.size} master embeddings from cache`);
    } catch (error) {
      // Cache doesn't exist, generate embeddings
      console.log('[Semantic Router] Generating master embeddings (first time)');
      await this.generateMasterEmbeddings();
    }
  }

  /**
   * Generate embeddings for all master agents
   *
   * @private
   */
  async generateMasterEmbeddings() {
    for (const master of this.masters) {
      const capabilityText = this._buildMasterCapabilityText(master);

      console.log(`[Semantic Router] Generating embedding for ${master.name}`);

      const embedding = await this.embeddingGenerator.generateEmbedding(
        capabilityText,
        'master'
      );

      this.masterEmbeddings.set(master.name, embedding);
    }

    // Save to cache
    await this.saveMasterEmbeddings();
  }

  /**
   * Build comprehensive capability text for master
   *
   * @private
   * @param {Object} master - Master definition
   * @returns {string} - Capability text
   */
  _buildMasterCapabilityText(master) {
    const parts = [
      master.name,
      master.description,
      master.expertise?.join(', ') || '',
      master.keywords?.join(', ') || '',
      master.responsibilities?.join(', ') || ''
    ];

    return parts.filter(p => p).join('. ');
  }

  /**
   * Save master embeddings to cache
   *
   * @private
   */
  async saveMasterEmbeddings() {
    const cacheData = {
      generated_at: new Date().toISOString(),
      version: '1.0',
      embeddings: {}
    };

    for (const [masterName, embedding] of this.masterEmbeddings) {
      cacheData.embeddings[masterName] = embedding;
    }

    const dir = path.dirname(this.masterEmbeddingsPath);
    await fs.mkdir(dir, { recursive: true });
    await fs.writeFile(
      this.masterEmbeddingsPath,
      JSON.stringify(cacheData, null, 2),
      'utf8'
    );

    console.log(`[Semantic Router] Saved master embeddings to ${this.masterEmbeddingsPath}`);
  }

  /**
   * Keyword-based fallback routing
   *
   * @private
   * @param {string} taskDescription - Task description
   * @returns {Object} - Routing result
   */
  _keywordFallback(taskDescription) {
    const text = taskDescription.toLowerCase();

    // Keyword patterns for each master
    const patterns = {
      'security-master': {
        keywords: ['security', 'vulnerability', 'cve', 'audit', 'scan', 'exploit', 'patch'],
        weight: 1.0
      },
      'development-master': {
        keywords: ['implement', 'feature', 'develop', 'create', 'build', 'add', 'refactor'],
        weight: 0.9
      },
      'cicd-master': {
        keywords: ['build', 'deploy', 'ci', 'cd', 'pipeline', 'test', 'release'],
        weight: 0.85
      },
      'inventory-master': {
        keywords: ['catalog', 'inventory', 'document', 'track', 'list', 'survey'],
        weight: 0.8
      }
    };

    let bestMatch = { master: 'coordinator-master', confidence: 0.3 };

    for (const [master, pattern] of Object.entries(patterns)) {
      const matches = pattern.keywords.filter(kw => text.includes(kw)).length;
      const confidence = (matches / pattern.keywords.length) * pattern.weight;

      if (confidence > bestMatch.confidence) {
        bestMatch = { master, confidence };
      }
    }

    return bestMatch;
  }

  /**
   * Get default master definitions
   *
   * @private
   * @returns {Array} - Master definitions
   */
  _getDefaultMasters() {
    return [
      {
        name: 'security-master',
        description: 'Handles security scanning, vulnerability detection, and remediation',
        expertise: ['security', 'CVE detection', 'vulnerability scanning', 'penetration testing'],
        keywords: ['security', 'vulnerability', 'cve', 'scan', 'audit', 'exploit', 'patch'],
        responsibilities: ['scan repositories', 'identify vulnerabilities', 'coordinate fixes']
      },
      {
        name: 'development-master',
        description: 'Manages feature implementation, bug fixes, and code improvements',
        expertise: ['software development', 'feature implementation', 'bug fixing', 'refactoring'],
        keywords: ['implement', 'feature', 'develop', 'fix', 'bug', 'refactor', 'code'],
        responsibilities: ['implement features', 'fix bugs', 'coordinate workers']
      },
      {
        name: 'cicd-master',
        description: 'Oversees CI/CD pipelines, builds, tests, and deployments',
        expertise: ['continuous integration', 'continuous deployment', 'build automation', 'testing'],
        keywords: ['build', 'deploy', 'ci', 'cd', 'pipeline', 'test', 'release'],
        responsibilities: ['manage pipelines', 'orchestrate builds', 'handle deployments']
      },
      {
        name: 'inventory-master',
        description: 'Catalogs repositories, tracks dependencies, and maintains documentation',
        expertise: ['repository cataloging', 'dependency tracking', 'documentation'],
        keywords: ['catalog', 'inventory', 'document', 'track', 'dependencies'],
        responsibilities: ['catalog repositories', 'track dependencies', 'maintain inventory']
      },
      {
        name: 'coordinator-master',
        description: 'Central orchestration and task routing across all domains',
        expertise: ['task routing', 'workflow orchestration', 'master coordination'],
        keywords: ['coordinate', 'orchestrate', 'route', 'assign', 'manage'],
        responsibilities: ['route tasks', 'coordinate masters', 'oversee system']
      }
    ];
  }

  /**
   * Get routing metrics
   *
   * @returns {Object} - Metrics
   */
  getMetrics() {
    const semanticRate = this.routingMetrics.total_routes > 0
      ? (this.routingMetrics.semantic_routes / this.routingMetrics.total_routes * 100).toFixed(1)
      : 0;

    return {
      ...this.routingMetrics,
      semantic_rate_percent: parseFloat(semanticRate),
      avg_confidence: this.routingMetrics.avg_confidence.toFixed(3)
    };
  }

  /**
   * Reset metrics
   */
  resetMetrics() {
    this.routingMetrics = {
      total_routes: 0,
      semantic_routes: 0,
      keyword_fallbacks: 0,
      avg_confidence: 0,
      confidences: []
    };
  }
}

module.exports = { SemanticRouter };
