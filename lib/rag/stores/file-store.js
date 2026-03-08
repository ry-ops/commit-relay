#!/usr/bin/env node
// lib/rag/stores/file-store.js
// File-based Vector Store Adapter
// Part of Production Vector Store Integration
//
// This is a file-based implementation suitable for development
// and as a fallback when production vector databases are not available.

const fs = require('fs').promises;
const path = require('path');
const BaseStore = require('./base-store');

/**
 * FileStore - File-based vector store adapter
 *
 * Stores vectors and metadata in JSON files on disk.
 * Suitable for development, testing, and small-scale deployments.
 *
 * Configuration:
 * - basePath: Base directory for storage (default: coordination/vector-db)
 */
class FileStore extends BaseStore {
  constructor(config = {}) {
    super(config);

    this.name = 'file';
    this.basePath = config.basePath || process.env.VECTOR_DB_PATH || 'coordination/vector-db';
    this.indexPath = path.join(this.basePath, 'index.json');
    this.embeddingsPath = path.join(this.basePath, 'embeddings');

    // In-memory index for fast lookup
    this.index = {
      version: '2.0.0',
      created_at: null,
      last_updated: null,
      collections: {}
    };
  }

  /**
   * Connect (initialize file system)
   */
  async connect() {
    try {
      await fs.mkdir(this.basePath, { recursive: true });
      await fs.mkdir(this.embeddingsPath, { recursive: true });

      // Load existing index
      try {
        const indexContent = await fs.readFile(this.indexPath, 'utf8');
        this.index = JSON.parse(indexContent);
      } catch (error) {
        // Initialize new index
        this.index.created_at = new Date().toISOString();
        this.index.last_updated = new Date().toISOString();
        await this._saveIndex();
      }

      console.log(`FileStore initialized at ${this.basePath}`);
      this.connected = true;
      return true;
    } catch (error) {
      console.error('Failed to initialize FileStore:', error.message);
      this.connected = false;
      throw error;
    }
  }

  /**
   * Disconnect (save state)
   */
  async disconnect() {
    await this._saveIndex();
    this.connected = false;
  }

  /**
   * Create a new collection
   */
  async createCollection(name, config = {}) {
    if (this.index.collections[name]) {
      console.log(`Collection already exists: ${name}`);
      return true;
    }

    const dimension = config.dimension || this.defaultDimension;

    this.index.collections[name] = {
      name,
      dimension,
      description: config.description || '',
      distance: config.distance || 'cosine',
      schema: config.schema || {},
      count: 0,
      vectors: [],
      created_at: new Date().toISOString()
    };

    // Create collection directory
    const collectionPath = path.join(this.embeddingsPath, name);
    await fs.mkdir(collectionPath, { recursive: true });

    await this._saveIndex();
    console.log(`Created collection: ${name}`);
    return true;
  }

  /**
   * Delete a collection
   */
  async deleteCollection(name) {
    if (!this.index.collections[name]) {
      return false;
    }

    // Remove all vector files
    const collectionPath = path.join(this.embeddingsPath, name);
    try {
      const files = await fs.readdir(collectionPath);
      for (const file of files) {
        await fs.unlink(path.join(collectionPath, file));
      }
      await fs.rmdir(collectionPath);
    } catch (error) {
      // Directory may not exist
    }

    // Remove from index
    delete this.index.collections[name];
    await this._saveIndex();

    console.log(`Deleted collection: ${name}`);
    return true;
  }

  /**
   * Check if collection exists
   */
  async collectionExists(name) {
    return !!this.index.collections[name];
  }

  /**
   * List all collections
   */
  async listCollections() {
    return Object.keys(this.index.collections);
  }

  /**
   * Get collection info
   */
  async getCollectionInfo(name) {
    const collection = this.index.collections[name];
    if (!collection) {
      throw new Error(`Collection not found: ${name}`);
    }

    return {
      name: collection.name,
      dimension: collection.dimension,
      description: collection.description,
      distance: collection.distance,
      count: collection.count,
      created_at: collection.created_at
    };
  }

  /**
   * Insert documents
   */
  async insert(collection, documents) {
    if (!this.index.collections[collection]) {
      throw new Error(`Collection not found: ${collection}`);
    }

    const ids = [];

    for (const doc of documents) {
      const id = doc.id || this.generateId();
      ids.push(id);

      const vector = {
        id,
        collection,
        content: doc.content || '',
        metadata: doc.metadata || {},
        vector: doc.vector,
        created_at: new Date().toISOString()
      };

      // Save vector to disk
      await this._saveVector(collection, vector);

      // Update index
      this.index.collections[collection].vectors.push({
        id,
        metadata: doc.metadata || {},
        created_at: vector.created_at
      });
      this.index.collections[collection].count++;
    }

    this.index.last_updated = new Date().toISOString();
    await this._saveIndex();

    return ids;
  }

  /**
   * Update documents
   */
  async update(collection, documents) {
    if (!this.index.collections[collection]) {
      throw new Error(`Collection not found: ${collection}`);
    }

    const ids = [];

    for (const doc of documents) {
      if (!doc.id) {
        throw new Error('Document ID required for update');
      }

      const vector = {
        id: doc.id,
        collection,
        content: doc.content || '',
        metadata: doc.metadata || {},
        vector: doc.vector,
        created_at: new Date().toISOString()
      };

      // Save vector to disk
      await this._saveVector(collection, vector);

      // Update index metadata
      const indexEntry = this.index.collections[collection].vectors.find(v => v.id === doc.id);
      if (indexEntry) {
        indexEntry.metadata = doc.metadata || {};
        indexEntry.updated_at = vector.created_at;
      }

      ids.push(doc.id);
    }

    this.index.last_updated = new Date().toISOString();
    await this._saveIndex();

    return ids;
  }

  /**
   * Upsert documents
   */
  async upsert(collection, documents) {
    if (!this.index.collections[collection]) {
      throw new Error(`Collection not found: ${collection}`);
    }

    const ids = [];

    for (const doc of documents) {
      const id = doc.id || this.generateId();

      // Check if exists
      const exists = this.index.collections[collection].vectors.some(v => v.id === id);

      if (exists) {
        await this.update(collection, [{ ...doc, id }]);
      } else {
        await this.insert(collection, [{ ...doc, id }]);
      }

      ids.push(id);
    }

    return ids;
  }

  /**
   * Search for similar vectors
   */
  async search(collection, vector, options = {}) {
    if (!this.index.collections[collection]) {
      throw new Error(`Collection not found: ${collection}`);
    }

    const limit = options.limit || 10;
    const minScore = options.minScore || 0;

    const results = [];
    const collectionVectors = this.index.collections[collection].vectors;

    for (const vectorMeta of collectionVectors) {
      // Apply metadata filter if provided
      if (options.filter && !this._matchesFilter(vectorMeta.metadata, options.filter)) {
        continue;
      }

      // Load vector from disk
      const storedVector = await this._loadVector(collection, vectorMeta.id);

      // Calculate similarity
      const score = this.cosineSimilarity(vector, storedVector.vector);

      if (score >= minScore) {
        results.push({
          id: storedVector.id,
          content: storedVector.content,
          metadata: storedVector.metadata,
          score,
          vector: options.includeVectors ? storedVector.vector : undefined
        });
      }
    }

    // Sort by similarity (highest first)
    results.sort((a, b) => b.score - a.score);

    return results.slice(0, limit);
  }

  /**
   * Check if metadata matches filter
   */
  _matchesFilter(metadata, filter) {
    if (!filter) return true;

    // Handle simple key-value filters
    for (const [key, value] of Object.entries(filter)) {
      if (typeof value === 'object') {
        // Complex filter
        if (value.$eq !== undefined && metadata[key] !== value.$eq) return false;
        if (value.$ne !== undefined && metadata[key] === value.$ne) return false;
        if (value.$gt !== undefined && metadata[key] <= value.$gt) return false;
        if (value.$gte !== undefined && metadata[key] < value.$gte) return false;
        if (value.$lt !== undefined && metadata[key] >= value.$lt) return false;
        if (value.$lte !== undefined && metadata[key] > value.$lte) return false;
        if (value.$in !== undefined && !value.$in.includes(metadata[key])) return false;
      } else {
        // Simple equality
        if (metadata[key] !== value) return false;
      }
    }

    return true;
  }

  /**
   * Get documents by IDs
   */
  async getById(collection, ids) {
    if (!this.index.collections[collection]) {
      throw new Error(`Collection not found: ${collection}`);
    }

    const results = [];

    for (const id of ids) {
      try {
        const vector = await this._loadVector(collection, id);
        results.push({
          id: vector.id,
          content: vector.content,
          metadata: vector.metadata,
          vector: vector.vector,
          createdAt: vector.created_at
        });
      } catch (error) {
        // Skip not found
      }
    }

    return results;
  }

  /**
   * Delete documents by IDs
   */
  async delete(collection, ids) {
    if (!this.index.collections[collection]) {
      throw new Error(`Collection not found: ${collection}`);
    }

    let deleted = 0;

    for (const id of ids) {
      // Remove file
      const vectorPath = path.join(this.embeddingsPath, collection, `${id}.json`);
      try {
        await fs.unlink(vectorPath);
        deleted++;

        // Remove from index
        this.index.collections[collection].vectors =
          this.index.collections[collection].vectors.filter(v => v.id !== id);
        this.index.collections[collection].count--;
      } catch (error) {
        // File not found
      }
    }

    if (deleted > 0) {
      this.index.last_updated = new Date().toISOString();
      await this._saveIndex();
    }

    return deleted;
  }

  /**
   * Delete documents by filter
   */
  async deleteByFilter(collection, filter) {
    if (!this.index.collections[collection]) {
      throw new Error(`Collection not found: ${collection}`);
    }

    const toDelete = [];

    for (const vectorMeta of this.index.collections[collection].vectors) {
      if (this._matchesFilter(vectorMeta.metadata, filter)) {
        toDelete.push(vectorMeta.id);
      }
    }

    return await this.delete(collection, toDelete);
  }

  /**
   * Get all documents from collection
   */
  async getAll(collection, options = {}) {
    if (!this.index.collections[collection]) {
      throw new Error(`Collection not found: ${collection}`);
    }

    const limit = options.limit || 100;
    const offset = options.offset || 0;

    let vectors = this.index.collections[collection].vectors;

    // Apply filter
    if (options.filter) {
      vectors = vectors.filter(v => this._matchesFilter(v.metadata, options.filter));
    }

    // Apply pagination
    vectors = vectors.slice(offset, offset + limit);

    // Load full vectors
    const results = [];
    for (const vectorMeta of vectors) {
      try {
        const vector = await this._loadVector(collection, vectorMeta.id);
        results.push({
          id: vector.id,
          content: vector.content,
          metadata: vector.metadata,
          vector: options.includeVectors ? vector.vector : undefined,
          createdAt: vector.created_at
        });
      } catch (error) {
        // Skip errors
      }
    }

    return results;
  }

  /**
   * Count documents in collection
   */
  async count(collection, filter = null) {
    if (!this.index.collections[collection]) {
      throw new Error(`Collection not found: ${collection}`);
    }

    if (!filter) {
      return this.index.collections[collection].count;
    }

    let count = 0;
    for (const vectorMeta of this.index.collections[collection].vectors) {
      if (this._matchesFilter(vectorMeta.metadata, filter)) {
        count++;
      }
    }
    return count;
  }

  /**
   * Clear all documents from collection
   */
  async clear(collection) {
    if (!this.index.collections[collection]) {
      throw new Error(`Collection not found: ${collection}`);
    }

    // Remove all vector files
    const collectionPath = path.join(this.embeddingsPath, collection);
    try {
      const files = await fs.readdir(collectionPath);
      for (const file of files) {
        await fs.unlink(path.join(collectionPath, file));
      }
    } catch (error) {
      // Directory may not exist
    }

    // Reset collection index
    this.index.collections[collection].vectors = [];
    this.index.collections[collection].count = 0;
    this.index.last_updated = new Date().toISOString();

    await this._saveIndex();
    return true;
  }

  /**
   * Health check
   */
  async healthCheck() {
    try {
      // Check if base directory is writable
      const testFile = path.join(this.basePath, '.health-check');
      await fs.writeFile(testFile, Date.now().toString());
      await fs.unlink(testFile);

      return {
        healthy: true,
        basePath: this.basePath,
        collections: Object.keys(this.index.collections).length
      };
    } catch (error) {
      return {
        healthy: false,
        error: error.message
      };
    }
  }

  /**
   * Save vector to disk
   */
  async _saveVector(collection, vector) {
    const collectionPath = path.join(this.embeddingsPath, collection);
    await fs.mkdir(collectionPath, { recursive: true });

    const vectorPath = path.join(collectionPath, `${vector.id}.json`);
    await fs.writeFile(vectorPath, JSON.stringify(vector, null, 2));
  }

  /**
   * Load vector from disk
   */
  async _loadVector(collection, vectorId) {
    const vectorPath = path.join(this.embeddingsPath, collection, `${vectorId}.json`);
    const content = await fs.readFile(vectorPath, 'utf8');
    return JSON.parse(content);
  }

  /**
   * Save index to disk
   */
  async _saveIndex() {
    await fs.writeFile(this.indexPath, JSON.stringify(this.index, null, 2));
  }
}

module.exports = FileStore;
