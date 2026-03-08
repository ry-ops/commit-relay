#!/usr/bin/env node
// lib/rag/vector-store.js
// Vector Database for RAG (Retrieval-Augmented Generation)
// Part of Enhancement Phase: Vector Database Integration
//
// This module now uses the pluggable store abstraction for
// production vector database support (Weaviate, Qdrant, File-based)

const path = require('path');
const crypto = require('crypto');

// Import embeddings factory
const { createEmbedder, createEmbedderFromConfig } = require('./embeddings');

// Import store factory
const { createStore, createStoreFromConfig } = require('./stores');

class VectorStore {
  constructor(embedder = null, store = null) {
    // Embedder instance (will be initialized if not provided)
    this.embedder = embedder;

    // Store instance (will be initialized if not provided)
    this.store = store;

    // Collection configurations
    this.collectionConfigs = {
      'code': {
        dimension: 1536,
        description: 'Code snippets and implementations',
        distance: 'cosine',
        schema: {
          file_path: { type: 'keyword' },
          file_type: { type: 'keyword' },
          language: { type: 'keyword' }
        }
      },
      'documentation': {
        dimension: 1536,
        description: 'Documentation and runbooks',
        distance: 'cosine',
        schema: {
          doc_type: { type: 'keyword' },
          source: { type: 'keyword' }
        }
      },
      'decisions': {
        dimension: 1536,
        description: 'AI decision history and reasoning',
        distance: 'cosine',
        schema: {
          decision_id: { type: 'keyword' },
          agent: { type: 'keyword' },
          confidence: { type: 'float' },
          outcome: { type: 'keyword' }
        }
      },
      'patterns': {
        dimension: 1536,
        description: 'Failure patterns and solutions',
        distance: 'cosine',
        schema: {
          pattern_id: { type: 'keyword' },
          category: { type: 'keyword' },
          severity: { type: 'keyword' }
        }
      },
      'tasks': {
        dimension: 1536,
        description: 'Task descriptions and outcomes',
        distance: 'cosine',
        schema: {
          task_id: { type: 'keyword' },
          status: { type: 'keyword' },
          worker_type: { type: 'keyword' }
        }
      }
    };
  }

  /**
   * Initialize vector store
   */
  async initialize() {
    try {
      // Initialize embedder if not provided
      if (!this.embedder) {
        try {
          this.embedder = await createEmbedderFromConfig();
        } catch (configError) {
          // Fall back to auto-detect
          this.embedder = createEmbedder();
        }
      }

      // Update collection dimensions based on embedder
      const dimension = this.embedder.getDimensions();
      for (const key of Object.keys(this.collectionConfigs)) {
        this.collectionConfigs[key].dimension = dimension;
      }

      // Initialize store if not provided
      if (!this.store) {
        try {
          this.store = await createStoreFromConfig();
        } catch (configError) {
          // Fall back to auto-detect
          this.store = createStore();
        }
      }

      // Connect to store
      await this.store.connect();

      // Initialize collections
      for (const [name, config] of Object.entries(this.collectionConfigs)) {
        const exists = await this.store.collectionExists(name);
        if (!exists) {
          await this.store.createCollection(name, config);
        }
      }

      const embedderInfo = this.embedder.getInfo();
      const storeInfo = await this.store.getInfo();

      console.log('Vector Store initialized');
      console.log(`Store: ${storeInfo.name}`);
      console.log(`Embedder: ${embedderInfo.name} (${embedderInfo.model})`);
      console.log(`Dimensions: ${embedderInfo.dimensions}`);

      const collections = await this.store.listCollections();
      console.log(`Collections: ${collections.join(', ')}`);

      return true;
    } catch (error) {
      console.error('Failed to initialize Vector Store:', error.message);
      return false;
    }
  }

  /**
   * Get the current embedder
   */
  getEmbedder() {
    return this.embedder;
  }

  /**
   * Set a new embedder
   */
  setEmbedder(embedder) {
    this.embedder = embedder;

    // Update collection dimensions
    const dimension = embedder.getDimensions();
    for (const key of Object.keys(this.collectionConfigs)) {
      this.collectionConfigs[key].dimension = dimension;
    }
  }

  /**
   * Get the current store
   */
  getStore() {
    return this.store;
  }

  /**
   * Set a new store
   */
  setStore(store) {
    this.store = store;
  }

  /**
   * Store vector embedding
   */
  async storeVector(collection, document) {
    const exists = await this.store.collectionExists(collection);
    if (!exists) {
      throw new Error(`Collection not found: ${collection}`);
    }

    // Generate embedding
    const embedding = await this._generateEmbedding(document.content);

    const vectorId = document.id || crypto.randomUUID();

    // Insert into store
    const [insertedId] = await this.store.insert(collection, [{
      id: vectorId,
      vector: embedding,
      content: document.content,
      metadata: document.metadata || {}
    }]);

    console.log(`Stored vector ${insertedId} in collection '${collection}'`);

    return insertedId;
  }

  /**
   * Semantic search across vectors
   */
  async search(query, options = {}) {
    const collection = options.collection || null;
    const limit = options.limit || 10;
    const minSimilarity = options.min_similarity || 0.7;

    // Generate query embedding
    const queryEmbedding = await this._generateEmbedding(query);

    const results = [];

    // Search in specified collection or all collections
    const collectionsToSearch = collection
      ? [collection]
      : await this.store.listCollections();

    for (const collectionName of collectionsToSearch) {
      const searchResults = await this.store.search(collectionName, queryEmbedding, {
        limit,
        minScore: minSimilarity,
        filter: options.filter
      });

      results.push(...searchResults.map(r => ({
        id: r.id,
        collection: collectionName,
        content: r.content,
        metadata: r.metadata,
        similarity: r.score
      })));
    }

    // Sort by similarity (highest first)
    results.sort((a, b) => b.similarity - a.similarity);

    // Apply limit
    return results.slice(0, limit);
  }

  /**
   * Get context for AI decision
   */
  async getContext(query, contextType = 'all', options = {}) {
    const limit = options.limit || 5;

    const context = {
      query: query,
      context_type: contextType,
      retrieved_at: new Date().toISOString(),
      sources: []
    };

    // Search relevant collections based on context type
    let collections = [];
    if (contextType === 'code') {
      collections = ['code'];
    } else if (contextType === 'documentation') {
      collections = ['documentation'];
    } else if (contextType === 'decisions') {
      collections = ['decisions', 'patterns'];
    } else {
      collections = await this.store.listCollections();
    }

    for (const collection of collections) {
      const results = await this.search(query, {
        collection,
        limit: Math.ceil(limit / collections.length),
        min_similarity: 0.6
      });

      context.sources.push(...results.map(r => ({
        collection: r.collection,
        content: r.content,
        similarity: r.similarity,
        metadata: r.metadata
      })));
    }

    // Sort all sources by similarity
    context.sources.sort((a, b) => b.similarity - a.similarity);

    // Apply overall limit
    context.sources = context.sources.slice(0, limit);

    return context;
  }

  /**
   * Index code repository
   */
  async indexCodeRepository(repoPath, patterns = ['**/*.js', '**/*.sh', '**/*.md']) {
    const indexed = {
      repository: repoPath,
      indexed_at: new Date().toISOString(),
      files_indexed: 0,
      vectors_created: 0
    };

    // Simplified implementation - in production would use glob patterns
    const files = [
      { path: 'lib/governance/catalog-manager.js', type: 'code' },
      { path: 'docs/runbooks/worker-failure.md', type: 'documentation' },
      { path: 'scripts/wizards/create-worker.sh', type: 'code' }
    ];

    for (const file of files) {
      try {
        const content = `Sample content from ${file.path}`;

        const collection = file.type === 'code' ? 'code' : 'documentation';

        await this.storeVector(collection, {
          content: content,
          metadata: {
            file_path: file.path,
            file_type: file.type,
            indexed_at: new Date().toISOString()
          }
        });

        indexed.files_indexed++;
        indexed.vectors_created++;
      } catch (error) {
        console.error(`Failed to index ${file.path}:`, error.message);
      }
    }

    return indexed;
  }

  /**
   * Index AI decisions for learning
   */
  async indexDecision(decision) {
    return await this.storeVector('decisions', {
      content: `${decision.type}: ${decision.description}\nReasoning: ${decision.reasoning || 'N/A'}`,
      metadata: {
        decision_id: decision.id,
        agent: decision.agent,
        confidence: decision.confidence,
        outcome: decision.outcome,
        timestamp: decision.timestamp
      }
    });
  }

  /**
   * Index failure pattern
   */
  async indexPattern(pattern) {
    return await this.storeVector('patterns', {
      content: `${pattern.category}/${pattern.type}: ${pattern.signature.error_pattern || 'N/A'}\nSolution: ${pattern.auto_fix_action || 'Manual intervention'}`,
      metadata: {
        pattern_id: pattern.pattern_id,
        category: pattern.category,
        severity: pattern.severity,
        frequency: pattern.frequency.total_occurrences
      }
    });
  }

  /**
   * Get collection statistics
   */
  async getStatistics() {
    const collections = await this.store.listCollections();
    const stats = {
      total_vectors: 0,
      store: this.store.getName(),
      collections: {}
    };

    for (const name of collections) {
      try {
        const info = await this.store.getCollectionInfo(name);
        const count = info.count || info.pointsCount || info.vectorsCount || 0;

        stats.collections[name] = {
          count,
          dimension: info.dimension || this.collectionConfigs[name]?.dimension || 1536,
          description: info.description || this.collectionConfigs[name]?.description || ''
        };

        stats.total_vectors += count;
      } catch (error) {
        // Collection may not exist
        stats.collections[name] = { count: 0, error: error.message };
      }
    }

    return stats;
  }

  /**
   * Delete vector by ID
   */
  async deleteVector(collection, vectorId) {
    const deleted = await this.store.delete(collection, [vectorId]);
    return deleted > 0;
  }

  /**
   * Clear collection
   */
  async clearCollection(collection) {
    return await this.store.clear(collection);
  }

  /**
   * Generate embedding from text
   * Uses the configured embedder (OpenAI, Ollama, or Mock)
   */
  async _generateEmbedding(text) {
    if (!this.embedder) {
      throw new Error('Embedder not initialized. Call initialize() first.');
    }

    return await this.embedder.embed(text);
  }

  /**
   * Generate embeddings for multiple texts (batch)
   */
  async _generateEmbeddings(texts) {
    if (!this.embedder) {
      throw new Error('Embedder not initialized. Call initialize() first.');
    }

    return await this.embedder.embedBatch(texts);
  }

  /**
   * Close connections
   */
  async close() {
    if (this.store) {
      await this.store.disconnect();
    }
  }
}

// CLI interface
if (require.main === module) {
  const action = process.argv[2];
  const vectorStore = new VectorStore();

  (async () => {
    await vectorStore.initialize();

    switch (action) {
      case 'search':
        const query = process.argv[3];
        const results = await vectorStore.search(query);
        console.log('\nSearch Results:');
        console.log(JSON.stringify(results, null, 2));
        break;

      case 'context':
        const contextQuery = process.argv[3];
        const contextType = process.argv[4] || 'all';
        const context = await vectorStore.getContext(contextQuery, contextType);
        console.log('\nContext Retrieved:');
        console.log(JSON.stringify(context, null, 2));
        break;

      case 'index-repo':
        const repoPath = process.argv[3] || '.';
        const indexResult = await vectorStore.indexCodeRepository(repoPath);
        console.log('\nRepository Indexing:');
        console.log(JSON.stringify(indexResult, null, 2));
        break;

      case 'stats':
        const stats = await vectorStore.getStatistics();
        console.log('\nVector Store Statistics:');
        console.log(JSON.stringify(stats, null, 2));
        break;

      default:
        console.log('Usage: node vector-store.js <action>');
        console.log('Actions:');
        console.log('  search <query>              - Search vectors');
        console.log('  context <query> [type]      - Get context for query');
        console.log('  index-repo [path]           - Index code repository');
        console.log('  stats                       - Show statistics');
        break;
    }

    await vectorStore.close();
  })();
}

module.exports = VectorStore;
