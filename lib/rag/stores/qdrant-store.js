#!/usr/bin/env node
// lib/rag/stores/qdrant-store.js
// Qdrant Vector Store Adapter
// Part of Production Vector Store Integration

const BaseStore = require('./base-store');

/**
 * QdrantStore - Vector store adapter for Qdrant
 *
 * Qdrant is a vector similarity search engine with extended filtering support.
 *
 * Configuration:
 * - host: Qdrant server host (default: localhost)
 * - port: Qdrant server port (default: 6333)
 * - apiKey: API key for authentication (optional)
 * - https: Use HTTPS (default: false)
 */
class QdrantStore extends BaseStore {
  constructor(config = {}) {
    super(config);

    this.name = 'qdrant';
    this.host = config.host || process.env.QDRANT_HOST || 'localhost';
    this.port = config.port || process.env.QDRANT_PORT || 6333;
    this.apiKey = config.apiKey || process.env.QDRANT_API_KEY;
    this.https = config.https || process.env.QDRANT_HTTPS === 'true';

    this.client = null;
  }

  /**
   * Connect to Qdrant server
   */
  async connect() {
    try {
      const { QdrantClient } = require('@qdrant/js-client-rest');

      const clientConfig = {
        url: `${this.https ? 'https' : 'http'}://${this.host}:${this.port}`
      };

      // Add API key if provided
      if (this.apiKey) {
        clientConfig.apiKey = this.apiKey;
      }

      this.client = new QdrantClient(clientConfig);

      // Test connection
      const info = await this.client.getCollections();
      console.log(`Connected to Qdrant (${info.collections.length} collections)`);

      this.connected = true;
      return true;
    } catch (error) {
      console.error('Failed to connect to Qdrant:', error.message);
      this.connected = false;
      throw error;
    }
  }

  /**
   * Disconnect from Qdrant
   */
  async disconnect() {
    this.client = null;
    this.connected = false;
  }

  /**
   * Create a new collection
   */
  async createCollection(name, config = {}) {
    const dimension = config.dimension || this.defaultDimension;
    const distance = config.distance || 'cosine';

    // Map distance metric to Qdrant format
    const distanceMap = {
      cosine: 'Cosine',
      euclidean: 'Euclid',
      dot: 'Dot'
    };

    try {
      await this.client.createCollection(name, {
        vectors: {
          size: dimension,
          distance: distanceMap[distance] || 'Cosine'
        },
        // Optimized indexing parameters
        optimizers_config: {
          default_segment_number: 2,
          memmap_threshold: 20000
        },
        // Enable payload indexing for filtered searches
        on_disk_payload: true
      });

      // Create payload indexes for common fields
      await this.createPayloadIndexes(name, config.schema);

      console.log(`Created Qdrant collection: ${name}`);
      return true;
    } catch (error) {
      if (error.message.includes('already exists')) {
        console.log(`Qdrant collection already exists: ${name}`);
        return true;
      }
      throw error;
    }
  }

  /**
   * Create payload indexes for efficient filtering
   */
  async createPayloadIndexes(collection, schema = {}) {
    // Default indexes
    const defaultIndexes = [
      { field: 'content', type: 'text' },
      { field: 'createdAt', type: 'datetime' }
    ];

    // Add schema indexes
    const schemaIndexes = Object.entries(schema || {}).map(([field, config]) => ({
      field,
      type: config.type || 'keyword'
    }));

    const allIndexes = [...defaultIndexes, ...schemaIndexes];

    for (const { field, type } of allIndexes) {
      try {
        const schemaType = this.mapPayloadType(type);
        await this.client.createPayloadIndex(collection, {
          field_name: field,
          field_schema: schemaType
        });
      } catch (error) {
        // Ignore if index already exists
        if (!error.message.includes('already exists')) {
          console.warn(`Failed to create index for ${field}:`, error.message);
        }
      }
    }
  }

  /**
   * Map generic types to Qdrant payload schema types
   */
  mapPayloadType(type) {
    const typeMap = {
      string: 'keyword',
      keyword: 'keyword',
      text: 'text',
      number: 'float',
      integer: 'integer',
      int: 'integer',
      float: 'float',
      boolean: 'bool',
      bool: 'bool',
      date: 'datetime',
      datetime: 'datetime',
      geo: 'geo'
    };
    return typeMap[type.toLowerCase()] || 'keyword';
  }

  /**
   * Delete a collection
   */
  async deleteCollection(name) {
    try {
      await this.client.deleteCollection(name);
      console.log(`Deleted Qdrant collection: ${name}`);
      return true;
    } catch (error) {
      if (error.message.includes('not found') || error.message.includes("doesn't exist")) {
        return false;
      }
      throw error;
    }
  }

  /**
   * Check if collection exists
   */
  async collectionExists(name) {
    try {
      await this.client.getCollection(name);
      return true;
    } catch (error) {
      if (error.message.includes('not found') || error.message.includes("doesn't exist")) {
        return false;
      }
      throw error;
    }
  }

  /**
   * List all collections
   */
  async listCollections() {
    const result = await this.client.getCollections();
    return result.collections.map(c => c.name);
  }

  /**
   * Get collection info
   */
  async getCollectionInfo(name) {
    const info = await this.client.getCollection(name);
    return {
      name,
      status: info.status,
      vectorsCount: info.vectors_count,
      pointsCount: info.points_count,
      segmentsCount: info.segments_count,
      config: info.config,
      payloadSchema: info.payload_schema
    };
  }

  /**
   * Insert documents (points in Qdrant terminology)
   */
  async insert(collection, documents) {
    const points = documents.map(doc => {
      const id = doc.id || this.generateId();
      return {
        id,
        vector: doc.vector,
        payload: {
          content: doc.content || '',
          ...doc.metadata,
          createdAt: new Date().toISOString()
        }
      };
    });

    // Insert in batches
    const batchSize = 100;
    const ids = [];

    for (let i = 0; i < points.length; i += batchSize) {
      const batch = points.slice(i, i + batchSize);
      await this.client.upsert(collection, {
        wait: true,
        points: batch
      });
      ids.push(...batch.map(p => p.id));
    }

    return ids;
  }

  /**
   * Update documents
   */
  async update(collection, documents) {
    // Qdrant uses upsert for both insert and update
    return await this.insert(collection, documents);
  }

  /**
   * Upsert documents
   */
  async upsert(collection, documents) {
    return await this.insert(collection, documents);
  }

  /**
   * Search for similar vectors
   */
  async search(collection, vector, options = {}) {
    const limit = options.limit || 10;
    const minScore = options.minScore || 0;

    const searchParams = {
      vector,
      limit,
      with_payload: true,
      with_vector: options.includeVectors || false,
      score_threshold: minScore
    };

    // Apply filters
    if (options.filter) {
      searchParams.filter = this.buildFilter(options.filter);
    }

    const results = await this.client.search(collection, searchParams);

    return results.map(result => ({
      id: result.id,
      content: result.payload.content,
      metadata: this.extractMetadata(result.payload),
      score: result.score,
      vector: result.vector
    }));
  }

  /**
   * Extract metadata from payload (excluding internal fields)
   */
  extractMetadata(payload) {
    const { content, createdAt, ...metadata } = payload;
    return metadata;
  }

  /**
   * Build Qdrant filter from generic filter
   */
  buildFilter(filter) {
    if (!filter) return undefined;

    // Handle compound filters (AND/OR)
    if (filter.must || filter.should || filter.must_not) {
      return filter;
    }

    if (filter.operator === 'AND' && filter.conditions) {
      return {
        must: filter.conditions.map(c => this.buildCondition(c))
      };
    }

    if (filter.operator === 'OR' && filter.conditions) {
      return {
        should: filter.conditions.map(c => this.buildCondition(c))
      };
    }

    // Single condition
    return {
      must: [this.buildCondition(filter)]
    };
  }

  /**
   * Build a single filter condition
   */
  buildCondition(condition) {
    const field = condition.field || condition.key;
    const value = condition.value;
    const op = condition.operator || '=';

    switch (op) {
      case '=':
      case '==':
        return { key: field, match: { value } };

      case '!=':
        return {
          must_not: [{ key: field, match: { value } }]
        };

      case '>':
        return { key: field, range: { gt: value } };

      case '>=':
        return { key: field, range: { gte: value } };

      case '<':
        return { key: field, range: { lt: value } };

      case '<=':
        return { key: field, range: { lte: value } };

      case 'in':
        return { key: field, match: { any: value } };

      case 'contains':
        return { key: field, match: { text: value } };

      default:
        return { key: field, match: { value } };
    }
  }

  /**
   * Get documents by IDs
   */
  async getById(collection, ids) {
    const results = await this.client.retrieve(collection, {
      ids,
      with_payload: true,
      with_vector: true
    });

    return results.map(point => ({
      id: point.id,
      content: point.payload.content,
      metadata: this.extractMetadata(point.payload),
      vector: point.vector,
      createdAt: point.payload.createdAt
    }));
  }

  /**
   * Delete documents by IDs
   */
  async delete(collection, ids) {
    const result = await this.client.delete(collection, {
      wait: true,
      points: ids
    });

    return result.status === 'completed' ? ids.length : 0;
  }

  /**
   * Delete documents by filter
   */
  async deleteByFilter(collection, filter) {
    const qdrantFilter = this.buildFilter(filter);

    const result = await this.client.delete(collection, {
      wait: true,
      filter: qdrantFilter
    });

    return result.status === 'completed' ? 1 : 0; // Qdrant doesn't return count
  }

  /**
   * Get all documents from collection
   */
  async getAll(collection, options = {}) {
    const limit = options.limit || 100;
    const offset = options.offset || 0;

    const scrollParams = {
      limit,
      offset,
      with_payload: true,
      with_vector: options.includeVectors || false
    };

    if (options.filter) {
      scrollParams.filter = this.buildFilter(options.filter);
    }

    const result = await this.client.scroll(collection, scrollParams);

    return result.points.map(point => ({
      id: point.id,
      content: point.payload.content,
      metadata: this.extractMetadata(point.payload),
      vector: point.vector,
      createdAt: point.payload.createdAt
    }));
  }

  /**
   * Count documents in collection
   */
  async count(collection, filter = null) {
    if (filter) {
      const qdrantFilter = this.buildFilter(filter);
      const result = await this.client.count(collection, {
        filter: qdrantFilter,
        exact: true
      });
      return result.count;
    }

    const info = await this.client.getCollection(collection);
    return info.points_count;
  }

  /**
   * Clear all documents from collection
   */
  async clear(collection) {
    // Get collection config before clearing
    const info = await this.client.getCollection(collection);
    const vectorConfig = info.config.params.vectors;

    // Delete and recreate
    await this.deleteCollection(collection);
    await this.createCollection(collection, {
      dimension: vectorConfig.size,
      distance: vectorConfig.distance.toLowerCase()
    });

    return true;
  }

  /**
   * Health check
   */
  async healthCheck() {
    try {
      // Qdrant doesn't have a dedicated health endpoint
      // but we can check collections as a health indicator
      const collections = await this.client.getCollections();

      return {
        healthy: true,
        collections: collections.collections.length
      };
    } catch (error) {
      return {
        healthy: false,
        error: error.message
      };
    }
  }
}

module.exports = QdrantStore;
