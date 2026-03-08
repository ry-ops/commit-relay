#!/usr/bin/env node
// lib/rag/stores/base-store.js
// Abstract Vector Store Interface
// Part of Production Vector Store Integration

/**
 * BaseStore - Abstract interface for vector store providers
 *
 * All vector store providers must extend this class and implement:
 * - createCollection(name, config) - Create a new collection
 * - insert(collection, documents) - Insert documents with embeddings
 * - search(collection, vector, options) - Search for similar vectors
 * - delete(collection, ids) - Delete documents by ID
 * - getAll(collection, options) - Get all documents from collection
 * - listCollections() - List all collections
 */
class BaseStore {
  constructor(config = {}) {
    if (new.target === BaseStore) {
      throw new Error('BaseStore is an abstract class and cannot be instantiated directly');
    }

    this.config = config;
    this.name = 'base';
    this.connected = false;
    this.defaultDimension = config.defaultDimension || 1536;
  }

  /**
   * Connect to the vector store
   * @returns {Promise<boolean>} - Connection success
   */
  async connect() {
    throw new Error('connect() must be implemented by subclass');
  }

  /**
   * Disconnect from the vector store
   * @returns {Promise<void>}
   */
  async disconnect() {
    throw new Error('disconnect() must be implemented by subclass');
  }

  /**
   * Check if connected to the store
   * @returns {boolean}
   */
  isConnected() {
    return this.connected;
  }

  /**
   * Create a new collection/index
   * @param {string} name - Collection name
   * @param {Object} config - Collection configuration
   * @param {number} config.dimension - Vector dimension
   * @param {string} config.distance - Distance metric (cosine, euclidean, dot)
   * @param {Object} config.schema - Schema for metadata fields
   * @returns {Promise<boolean>} - Creation success
   */
  async createCollection(name, config = {}) {
    throw new Error('createCollection() must be implemented by subclass');
  }

  /**
   * Delete a collection
   * @param {string} name - Collection name
   * @returns {Promise<boolean>} - Deletion success
   */
  async deleteCollection(name) {
    throw new Error('deleteCollection() must be implemented by subclass');
  }

  /**
   * Check if collection exists
   * @param {string} name - Collection name
   * @returns {Promise<boolean>}
   */
  async collectionExists(name) {
    throw new Error('collectionExists() must be implemented by subclass');
  }

  /**
   * List all collections
   * @returns {Promise<string[]>} - Array of collection names
   */
  async listCollections() {
    throw new Error('listCollections() must be implemented by subclass');
  }

  /**
   * Get collection info/stats
   * @param {string} name - Collection name
   * @returns {Promise<Object>} - Collection statistics
   */
  async getCollectionInfo(name) {
    throw new Error('getCollectionInfo() must be implemented by subclass');
  }

  /**
   * Insert documents with embeddings
   * @param {string} collection - Collection name
   * @param {Array<Object>} documents - Documents to insert
   * @param {string} documents[].id - Document ID (optional, will be generated if not provided)
   * @param {number[]} documents[].vector - Embedding vector
   * @param {string} documents[].content - Document content
   * @param {Object} documents[].metadata - Additional metadata
   * @returns {Promise<string[]>} - Array of inserted document IDs
   */
  async insert(collection, documents) {
    throw new Error('insert() must be implemented by subclass');
  }

  /**
   * Update existing documents
   * @param {string} collection - Collection name
   * @param {Array<Object>} documents - Documents to update
   * @returns {Promise<string[]>} - Array of updated document IDs
   */
  async update(collection, documents) {
    throw new Error('update() must be implemented by subclass');
  }

  /**
   * Upsert documents (insert or update)
   * @param {string} collection - Collection name
   * @param {Array<Object>} documents - Documents to upsert
   * @returns {Promise<string[]>} - Array of upserted document IDs
   */
  async upsert(collection, documents) {
    throw new Error('upsert() must be implemented by subclass');
  }

  /**
   * Search for similar vectors
   * @param {string} collection - Collection name
   * @param {number[]} vector - Query vector
   * @param {Object} options - Search options
   * @param {number} options.limit - Maximum results to return
   * @param {Object} options.filter - Metadata filters
   * @param {number} options.minScore - Minimum similarity score
   * @param {boolean} options.includeVectors - Include vectors in results
   * @returns {Promise<Array<Object>>} - Search results with scores
   */
  async search(collection, vector, options = {}) {
    throw new Error('search() must be implemented by subclass');
  }

  /**
   * Get documents by IDs
   * @param {string} collection - Collection name
   * @param {string[]} ids - Document IDs
   * @returns {Promise<Array<Object>>} - Documents
   */
  async getById(collection, ids) {
    throw new Error('getById() must be implemented by subclass');
  }

  /**
   * Delete documents by IDs
   * @param {string} collection - Collection name
   * @param {string[]} ids - Document IDs to delete
   * @returns {Promise<number>} - Number of deleted documents
   */
  async delete(collection, ids) {
    throw new Error('delete() must be implemented by subclass');
  }

  /**
   * Delete documents matching filter
   * @param {string} collection - Collection name
   * @param {Object} filter - Filter criteria
   * @returns {Promise<number>} - Number of deleted documents
   */
  async deleteByFilter(collection, filter) {
    throw new Error('deleteByFilter() must be implemented by subclass');
  }

  /**
   * Get all documents from collection
   * @param {string} collection - Collection name
   * @param {Object} options - Query options
   * @param {number} options.limit - Maximum results
   * @param {number} options.offset - Pagination offset
   * @param {Object} options.filter - Metadata filters
   * @returns {Promise<Array<Object>>} - Documents
   */
  async getAll(collection, options = {}) {
    throw new Error('getAll() must be implemented by subclass');
  }

  /**
   * Count documents in collection
   * @param {string} collection - Collection name
   * @param {Object} filter - Optional filter
   * @returns {Promise<number>} - Document count
   */
  async count(collection, filter = null) {
    throw new Error('count() must be implemented by subclass');
  }

  /**
   * Clear all documents from collection
   * @param {string} collection - Collection name
   * @returns {Promise<boolean>} - Success
   */
  async clear(collection) {
    throw new Error('clear() must be implemented by subclass');
  }

  /**
   * Get store provider name
   * @returns {string}
   */
  getName() {
    return this.name;
  }

  /**
   * Get store info/stats
   * @returns {Promise<Object>}
   */
  async getInfo() {
    return {
      name: this.name,
      connected: this.connected,
      defaultDimension: this.defaultDimension,
      config: {
        ...this.config,
        // Redact sensitive info
        apiKey: this.config.apiKey ? '***' : undefined
      }
    };
  }

  /**
   * Check store health/availability
   * @returns {Promise<Object>} - Health status
   */
  async healthCheck() {
    throw new Error('healthCheck() must be implemented by subclass');
  }

  /**
   * Generate UUID for document ID
   * @returns {string}
   */
  generateId() {
    return require('crypto').randomUUID();
  }

  /**
   * Validate document structure
   * @param {Object} document - Document to validate
   * @returns {boolean}
   */
  validateDocument(document) {
    if (!document || typeof document !== 'object') {
      return false;
    }

    if (!Array.isArray(document.vector)) {
      return false;
    }

    if (document.vector.length === 0) {
      return false;
    }

    // Check all vector values are numbers
    return document.vector.every(v => typeof v === 'number' && !isNaN(v));
  }

  /**
   * Normalize filter for provider-specific format
   * Default implementation returns filter as-is
   * @param {Object} filter - Generic filter
   * @returns {Object} - Provider-specific filter
   */
  normalizeFilter(filter) {
    return filter;
  }

  /**
   * Calculate cosine similarity between two vectors
   * @param {number[]} vec1 - First vector
   * @param {number[]} vec2 - Second vector
   * @returns {number} - Similarity score (0-1)
   */
  cosineSimilarity(vec1, vec2) {
    if (vec1.length !== vec2.length) {
      throw new Error('Vectors must have same dimensions');
    }

    let dotProduct = 0;
    let norm1 = 0;
    let norm2 = 0;

    for (let i = 0; i < vec1.length; i++) {
      dotProduct += vec1[i] * vec2[i];
      norm1 += vec1[i] * vec1[i];
      norm2 += vec2[i] * vec2[i];
    }

    const magnitude = Math.sqrt(norm1) * Math.sqrt(norm2);
    if (magnitude === 0) return 0;

    return dotProduct / magnitude;
  }
}

module.exports = BaseStore;
