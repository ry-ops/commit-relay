#!/usr/bin/env node
// lib/rag/search/hybrid-search.js
// Hybrid Search combining Keyword and Semantic Search
// Part of Hybrid Search Implementation for commit-relay RAG

const KeywordSearch = require('./keyword-search');
const { reciprocalRankFusion, convexCombinationFusion } = require('./fusion');

class HybridSearch {
  /**
   * Create a hybrid search instance
   * @param {Object} vectorStore - Vector store for semantic search
   * @param {Object} embedder - Embedder for generating query embeddings
   * @param {Object} options - Configuration options
   */
  constructor(vectorStore, embedder, options = {}) {
    this.vectorStore = vectorStore;
    this.embedder = embedder;

    // Keyword search instance
    this.keywordSearch = new KeywordSearch(options.keywordOptions || {});

    // Default configuration
    this.config = {
      // Alpha: 0 = keyword only, 1 = semantic only
      alpha: options.alpha !== undefined ? options.alpha : 0.7,
      // Fusion method: 'rrf', 'weighted', 'alpha'
      fusionMethod: options.fusionMethod || 'alpha',
      // RRF constant
      rrfK: options.rrfK || 60,
      // Default result limit
      defaultLimit: options.defaultLimit || 10,
      // Minimum similarity threshold for semantic
      minSimilarity: options.minSimilarity || 0.5,
      // Minimum score for keyword
      minKeywordScore: options.minKeywordScore || 0.1,
      // Enable auto-indexing of new documents
      autoIndex: options.autoIndex !== undefined ? options.autoIndex : true
    };

    // Index synchronization state
    this.syncState = new Map();
  }

  /**
   * Index a document for both keyword and semantic search
   * @param {string} collection - Collection name
   * @param {Object} document - Document to index
   * @returns {string} - Document ID
   */
  async indexDocument(collection, document) {
    // Index in keyword search
    const docId = this.keywordSearch.addDocument(collection, document);

    // Semantic indexing happens through vectorStore.storeVector
    // which is typically called separately

    return docId;
  }

  /**
   * Index multiple documents
   * @param {string} collection - Collection name
   * @param {Array} documents - Documents to index
   * @returns {number} - Number of documents indexed
   */
  async indexDocuments(collection, documents) {
    return this.keywordSearch.addDocuments(collection, documents);
  }

  /**
   * Synchronize keyword index with vector store
   * Load existing vectors into keyword search
   * @param {string} collection - Collection name
   */
  async syncIndex(collection) {
    // This would need to be implemented based on the vector store's
    // ability to list all documents. For now, we rely on auto-indexing.
    console.log(`Sync requested for collection: ${collection}`);
    this.syncState.set(collection, new Date().toISOString());
  }

  /**
   * Perform hybrid search combining keyword and semantic results
   * @param {string} collection - Collection name
   * @param {string} query - Search query
   * @param {Object} options - Search options
   * @returns {Array} - Fused search results
   */
  async search(collection, query, options = {}) {
    const limit = options.limit || this.config.defaultLimit;
    const alpha = options.alpha !== undefined ? options.alpha : this.config.alpha;
    const fusionMethod = options.fusionMethod || this.config.fusionMethod;

    // Run keyword and semantic searches in parallel
    const [keywordResults, semanticResults] = await Promise.all([
      this._keywordSearch(collection, query, {
        limit: limit * 2, // Get more results for better fusion
        minScore: options.minKeywordScore || this.config.minKeywordScore,
        filter: options.filter
      }),
      this._semanticSearch(collection, query, {
        limit: limit * 2,
        minSimilarity: options.minSimilarity || this.config.minSimilarity,
        filter: options.filter
      })
    ]);

    // Check for empty results
    if (keywordResults.length === 0 && semanticResults.length === 0) {
      return [];
    }

    // If only one type has results, return those
    if (keywordResults.length === 0) {
      return semanticResults.slice(0, limit).map(r => ({
        ...r,
        searchType: 'semantic',
        fusedScore: r.similarity
      }));
    }

    if (semanticResults.length === 0) {
      return keywordResults.slice(0, limit).map(r => ({
        ...r,
        searchType: 'keyword',
        fusedScore: r.score
      }));
    }

    // Fuse results based on method
    let fusedResults;
    switch (fusionMethod) {
      case 'rrf':
        fusedResults = reciprocalRankFusion(
          [semanticResults, keywordResults],
          options.rrfK || this.config.rrfK
        );
        break;

      case 'weighted':
        // Use convex combination for weighted fusion
        fusedResults = convexCombinationFusion(
          semanticResults,
          keywordResults,
          alpha
        );
        break;

      case 'alpha':
      default:
        fusedResults = this._alphaFusion(
          semanticResults,
          keywordResults,
          alpha
        );
        break;
    }

    // Apply limit and format results
    return fusedResults.slice(0, limit).map(r => ({
      id: r.id,
      content: r.content,
      metadata: r.metadata,
      similarity: r.fusedScore, // Normalized combined score
      fusedScore: r.fusedScore,
      semanticScore: r.semanticScore,
      keywordScore: r.keywordScore,
      searchType: 'hybrid'
    }));
  }

  /**
   * Search across multiple collections
   * @param {Array} collections - Collection names
   * @param {string} query - Search query
   * @param {Object} options - Search options
   * @returns {Array} - Combined results
   */
  async searchMultiple(collections, query, options = {}) {
    const limit = options.limit || this.config.defaultLimit;
    const allResults = [];

    for (const collection of collections) {
      const results = await this.search(collection, query, {
        ...options,
        limit: limit * 2
      });

      allResults.push(...results.map(r => ({
        ...r,
        collection
      })));
    }

    // Sort by fused score and apply global limit
    allResults.sort((a, b) => b.fusedScore - a.fusedScore);
    return allResults.slice(0, limit);
  }

  /**
   * Perform keyword search
   * @private
   */
  async _keywordSearch(collection, query, options) {
    try {
      return this.keywordSearch.search(collection, query, options);
    } catch (error) {
      console.error(`Keyword search failed: ${error.message}`);
      return [];
    }
  }

  /**
   * Perform semantic search using vector store
   * @private
   */
  async _semanticSearch(collection, query, options) {
    try {
      const results = await this.vectorStore.search(query, {
        collection,
        limit: options.limit,
        min_similarity: options.minSimilarity,
        filter: options.filter
      });

      // Normalize result format
      return results.map(r => ({
        id: r.id,
        content: r.content,
        metadata: r.metadata,
        similarity: r.similarity,
        score: r.similarity
      }));
    } catch (error) {
      console.error(`Semantic search failed: ${error.message}`);
      return [];
    }
  }

  /**
   * Alpha fusion combining semantic and keyword scores
   * @private
   */
  _alphaFusion(semanticResults, keywordResults, alpha) {
    // Build maps for efficient lookup
    const semanticMap = new Map();
    const keywordMap = new Map();

    for (const r of semanticResults) {
      semanticMap.set(r.id, r);
    }

    for (const r of keywordResults) {
      keywordMap.set(r.id, r);
    }

    // Get all unique document IDs
    const allIds = new Set([
      ...semanticResults.map(r => r.id),
      ...keywordResults.map(r => r.id)
    ]);

    // Calculate fused scores
    const fusedResults = [];
    for (const id of allIds) {
      const semanticDoc = semanticMap.get(id);
      const keywordDoc = keywordMap.get(id);

      const semanticScore = semanticDoc ? (semanticDoc.similarity || 0) : 0;
      const keywordScore = keywordDoc ? (keywordDoc.score || 0) : 0;

      // Convex combination
      const fusedScore = alpha * semanticScore + (1 - alpha) * keywordScore;

      // Use document data from whichever source has it
      const docData = semanticDoc || keywordDoc;

      fusedResults.push({
        ...docData,
        id,
        fusedScore,
        semanticScore,
        keywordScore
      });
    }

    // Sort by fused score
    fusedResults.sort((a, b) => b.fusedScore - a.fusedScore);

    return fusedResults;
  }

  /**
   * Get current configuration
   * @returns {Object} - Configuration
   */
  getConfig() {
    return { ...this.config };
  }

  /**
   * Update configuration
   * @param {Object} newConfig - New configuration values
   */
  setConfig(newConfig) {
    Object.assign(this.config, newConfig);
  }

  /**
   * Get search statistics
   * @returns {Object} - Statistics
   */
  getStats() {
    const keywordStats = this.keywordSearch.getStats();
    return {
      keywordIndex: keywordStats,
      config: this.config,
      syncState: Object.fromEntries(this.syncState)
    };
  }

  /**
   * Clear keyword index for a collection
   * @param {string} collection - Collection name
   */
  clearKeywordIndex(collection) {
    this.keywordSearch.clearCollection(collection);
  }

  /**
   * Export keyword index for persistence
   * @param {string} collection - Collection name
   * @returns {string} - Serialized index
   */
  exportKeywordIndex(collection) {
    return this.keywordSearch.exportIndex(collection);
  }

  /**
   * Import keyword index from serialized data
   * @param {string} collection - Collection name
   * @param {string} data - Serialized index data
   */
  importKeywordIndex(collection, data) {
    this.keywordSearch.importIndex(collection, data);
  }
}

module.exports = HybridSearch;
