#!/usr/bin/env node
// lib/rag/stores/weaviate-store.js
// Weaviate Vector Store Adapter
// Part of Production Vector Store Integration

const BaseStore = require('./base-store');

/**
 * WeaviateStore - Vector store adapter for Weaviate
 *
 * Weaviate is an open-source vector database that stores both objects and vectors.
 *
 * Configuration:
 * - host: Weaviate server host (default: localhost)
 * - port: Weaviate server port (default: 8080)
 * - scheme: Connection scheme (default: http)
 * - apiKey: API key for authentication (optional)
 * - headers: Additional headers (optional)
 */
class WeaviateStore extends BaseStore {
  constructor(config = {}) {
    super(config);

    this.name = 'weaviate';
    this.host = config.host || process.env.WEAVIATE_HOST || 'localhost';
    this.port = config.port || process.env.WEAVIATE_PORT || 8080;
    this.scheme = config.scheme || process.env.WEAVIATE_SCHEME || 'http';
    this.apiKey = config.apiKey || process.env.WEAVIATE_API_KEY;
    this.headers = config.headers || {};

    this.client = null;
  }

  /**
   * Connect to Weaviate server
   */
  async connect() {
    try {
      const weaviate = require('weaviate-ts-client').default;

      const clientConfig = {
        scheme: this.scheme,
        host: `${this.host}:${this.port}`
      };

      // Add API key authentication if provided
      if (this.apiKey) {
        clientConfig.apiKey = new (require('weaviate-ts-client').ApiKey)(this.apiKey);
      }

      // Add custom headers if provided
      if (Object.keys(this.headers).length > 0) {
        clientConfig.headers = this.headers;
      }

      this.client = weaviate.client(clientConfig);

      // Test connection
      const meta = await this.client.misc.metaGetter().do();
      console.log(`Connected to Weaviate v${meta.version}`);

      this.connected = true;
      return true;
    } catch (error) {
      console.error('Failed to connect to Weaviate:', error.message);
      this.connected = false;
      throw error;
    }
  }

  /**
   * Disconnect from Weaviate
   */
  async disconnect() {
    this.client = null;
    this.connected = false;
  }

  /**
   * Convert collection name to Weaviate class name (PascalCase)
   */
  toClassName(name) {
    return name.charAt(0).toUpperCase() + name.slice(1).replace(/[-_](\w)/g, (_, c) => c.toUpperCase());
  }

  /**
   * Convert Weaviate class name back to collection name
   */
  fromClassName(className) {
    return className.charAt(0).toLowerCase() + className.slice(1).replace(/([A-Z])/g, '_$1').toLowerCase();
  }

  /**
   * Create a new collection (Weaviate class)
   */
  async createCollection(name, config = {}) {
    const className = this.toClassName(name);
    const dimension = config.dimension || this.defaultDimension;
    const distance = config.distance || 'cosine';

    // Build properties schema
    const properties = [
      {
        name: 'content',
        dataType: ['text'],
        description: 'Document content'
      },
      {
        name: 'metadata',
        dataType: ['text'],
        description: 'JSON metadata'
      },
      {
        name: 'createdAt',
        dataType: ['date'],
        description: 'Creation timestamp'
      }
    ];

    // Add custom schema properties
    if (config.schema) {
      for (const [propName, propConfig] of Object.entries(config.schema)) {
        const dataType = this.mapDataType(propConfig.type || 'string');
        properties.push({
          name: propName,
          dataType: [dataType],
          description: propConfig.description || ''
        });
      }
    }

    // Map distance metric to Weaviate format
    const distanceMetric = {
      cosine: 'cosine',
      euclidean: 'l2-squared',
      dot: 'dot'
    }[distance] || 'cosine';

    const classObj = {
      class: className,
      description: config.description || `Collection: ${name}`,
      vectorizer: 'none', // We provide our own vectors
      vectorIndexConfig: {
        distance: distanceMetric
      },
      properties
    };

    try {
      await this.client.schema.classCreator().withClass(classObj).do();
      console.log(`Created Weaviate class: ${className}`);
      return true;
    } catch (error) {
      if (error.message.includes('already exists')) {
        console.log(`Weaviate class already exists: ${className}`);
        return true;
      }
      throw error;
    }
  }

  /**
   * Map generic data types to Weaviate data types
   */
  mapDataType(type) {
    const typeMap = {
      string: 'text',
      text: 'text',
      number: 'number',
      int: 'int',
      integer: 'int',
      float: 'number',
      boolean: 'boolean',
      bool: 'boolean',
      date: 'date',
      array: 'text[]',
      object: 'text' // Store as JSON string
    };
    return typeMap[type.toLowerCase()] || 'text';
  }

  /**
   * Delete a collection
   */
  async deleteCollection(name) {
    const className = this.toClassName(name);
    try {
      await this.client.schema.classDeleter().withClassName(className).do();
      console.log(`Deleted Weaviate class: ${className}`);
      return true;
    } catch (error) {
      if (error.message.includes('not found')) {
        return false;
      }
      throw error;
    }
  }

  /**
   * Check if collection exists
   */
  async collectionExists(name) {
    const className = this.toClassName(name);
    try {
      await this.client.schema.classGetter().withClassName(className).do();
      return true;
    } catch (error) {
      if (error.message.includes('not found')) {
        return false;
      }
      throw error;
    }
  }

  /**
   * List all collections
   */
  async listCollections() {
    const schema = await this.client.schema.getter().do();
    return schema.classes.map(c => this.fromClassName(c.class));
  }

  /**
   * Get collection info
   */
  async getCollectionInfo(name) {
    const className = this.toClassName(name);
    const classInfo = await this.client.schema.classGetter().withClassName(className).do();

    // Get count using aggregate
    const aggregate = await this.client.graphql
      .aggregate()
      .withClassName(className)
      .withFields('meta { count }')
      .do();

    const count = aggregate.data?.Aggregate?.[className]?.[0]?.meta?.count || 0;

    return {
      name,
      className,
      description: classInfo.description,
      vectorIndexConfig: classInfo.vectorIndexConfig,
      properties: classInfo.properties,
      count
    };
  }

  /**
   * Insert documents
   */
  async insert(collection, documents) {
    const className = this.toClassName(collection);
    const ids = [];

    // Process in batches for better performance
    const batchSize = 100;
    for (let i = 0; i < documents.length; i += batchSize) {
      const batch = documents.slice(i, i + batchSize);

      let batcher = this.client.batch.objectsBatcher();

      for (const doc of batch) {
        const id = doc.id || this.generateId();
        ids.push(id);

        const obj = {
          class: className,
          id,
          vector: doc.vector,
          properties: {
            content: doc.content || '',
            metadata: JSON.stringify(doc.metadata || {}),
            createdAt: new Date().toISOString(),
            ...this.flattenMetadata(doc.metadata)
          }
        };

        batcher = batcher.withObject(obj);
      }

      await batcher.do();
    }

    return ids;
  }

  /**
   * Flatten metadata for indexed properties
   */
  flattenMetadata(metadata) {
    if (!metadata) return {};

    const flattened = {};
    for (const [key, value] of Object.entries(metadata)) {
      if (typeof value !== 'object') {
        flattened[key] = value;
      }
    }
    return flattened;
  }

  /**
   * Update documents
   */
  async update(collection, documents) {
    const className = this.toClassName(collection);
    const ids = [];

    for (const doc of documents) {
      if (!doc.id) {
        throw new Error('Document ID required for update');
      }

      await this.client.data
        .updater()
        .withClassName(className)
        .withId(doc.id)
        .withProperties({
          content: doc.content || '',
          metadata: JSON.stringify(doc.metadata || {}),
          ...this.flattenMetadata(doc.metadata)
        })
        .withVector(doc.vector)
        .do();

      ids.push(doc.id);
    }

    return ids;
  }

  /**
   * Upsert documents
   */
  async upsert(collection, documents) {
    // Weaviate handles upserts automatically with the same ID
    return await this.insert(collection, documents);
  }

  /**
   * Search for similar vectors
   */
  async search(collection, vector, options = {}) {
    const className = this.toClassName(collection);
    const limit = options.limit || 10;
    const minScore = options.minScore || 0;

    let query = this.client.graphql
      .get()
      .withClassName(className)
      .withFields('content metadata createdAt _additional { id distance certainty }')
      .withNearVector({ vector, certainty: minScore || 0.0 })
      .withLimit(limit);

    // Apply filters
    if (options.filter) {
      const where = this.buildWhereFilter(options.filter);
      query = query.withWhere(where);
    }

    const result = await query.do();
    const objects = result.data?.Get?.[className] || [];

    return objects.map(obj => ({
      id: obj._additional.id,
      content: obj.content,
      metadata: JSON.parse(obj.metadata || '{}'),
      score: obj._additional.certainty || (1 - obj._additional.distance),
      distance: obj._additional.distance
    }));
  }

  /**
   * Build Weaviate where filter from generic filter
   */
  buildWhereFilter(filter) {
    if (filter.operator && filter.operands) {
      // Compound filter
      return {
        operator: filter.operator,
        operands: filter.operands.map(op => this.buildWhereFilter(op))
      };
    }

    // Simple filter
    const path = filter.path || [filter.field];
    const operator = this.mapOperator(filter.operator || 'Equal');

    return {
      path,
      operator,
      [this.getValueType(filter.value)]: filter.value
    };
  }

  /**
   * Map filter operator to Weaviate operator
   */
  mapOperator(op) {
    const opMap = {
      '=': 'Equal',
      '==': 'Equal',
      '!=': 'NotEqual',
      '>': 'GreaterThan',
      '>=': 'GreaterThanEqual',
      '<': 'LessThan',
      '<=': 'LessThanEqual',
      'like': 'Like',
      'contains': 'ContainsAny'
    };
    return opMap[op.toLowerCase()] || op;
  }

  /**
   * Get value type key for Weaviate filter
   */
  getValueType(value) {
    if (typeof value === 'string') return 'valueText';
    if (typeof value === 'number') {
      return Number.isInteger(value) ? 'valueInt' : 'valueNumber';
    }
    if (typeof value === 'boolean') return 'valueBoolean';
    if (value instanceof Date) return 'valueDate';
    return 'valueText';
  }

  /**
   * Get documents by IDs
   */
  async getById(collection, ids) {
    const className = this.toClassName(collection);
    const results = [];

    for (const id of ids) {
      try {
        const obj = await this.client.data
          .getterById()
          .withClassName(className)
          .withId(id)
          .withVector()
          .do();

        if (obj) {
          results.push({
            id: obj.id,
            content: obj.properties.content,
            metadata: JSON.parse(obj.properties.metadata || '{}'),
            vector: obj.vector,
            createdAt: obj.properties.createdAt
          });
        }
      } catch (error) {
        // Skip not found errors
        if (!error.message.includes('not found')) {
          throw error;
        }
      }
    }

    return results;
  }

  /**
   * Delete documents by IDs
   */
  async delete(collection, ids) {
    const className = this.toClassName(collection);
    let deleted = 0;

    for (const id of ids) {
      try {
        await this.client.data
          .deleter()
          .withClassName(className)
          .withId(id)
          .do();
        deleted++;
      } catch (error) {
        if (!error.message.includes('not found')) {
          throw error;
        }
      }
    }

    return deleted;
  }

  /**
   * Delete documents by filter
   */
  async deleteByFilter(collection, filter) {
    const className = this.toClassName(collection);
    const where = this.buildWhereFilter(filter);

    const result = await this.client.batch
      .objectsBatchDeleter()
      .withClassName(className)
      .withWhere(where)
      .do();

    return result.results?.successful || 0;
  }

  /**
   * Get all documents from collection
   */
  async getAll(collection, options = {}) {
    const className = this.toClassName(collection);
    const limit = options.limit || 100;
    const offset = options.offset || 0;

    let query = this.client.graphql
      .get()
      .withClassName(className)
      .withFields('content metadata createdAt _additional { id vector }')
      .withLimit(limit)
      .withOffset(offset);

    if (options.filter) {
      const where = this.buildWhereFilter(options.filter);
      query = query.withWhere(where);
    }

    const result = await query.do();
    const objects = result.data?.Get?.[className] || [];

    return objects.map(obj => ({
      id: obj._additional.id,
      content: obj.content,
      metadata: JSON.parse(obj.metadata || '{}'),
      vector: options.includeVectors ? obj._additional.vector : undefined,
      createdAt: obj.createdAt
    }));
  }

  /**
   * Count documents in collection
   */
  async count(collection, filter = null) {
    const className = this.toClassName(collection);

    let query = this.client.graphql
      .aggregate()
      .withClassName(className)
      .withFields('meta { count }');

    if (filter) {
      const where = this.buildWhereFilter(filter);
      query = query.withWhere(where);
    }

    const result = await query.do();
    return result.data?.Aggregate?.[className]?.[0]?.meta?.count || 0;
  }

  /**
   * Clear all documents from collection
   */
  async clear(collection) {
    // Delete and recreate the collection
    const info = await this.getCollectionInfo(collection);
    await this.deleteCollection(collection);
    await this.createCollection(collection, {
      dimension: info.vectorIndexConfig?.dimension || this.defaultDimension,
      description: info.description
    });
    return true;
  }

  /**
   * Health check
   */
  async healthCheck() {
    try {
      const meta = await this.client.misc.metaGetter().do();
      const ready = await this.client.misc.readyChecker().do();

      return {
        healthy: ready,
        version: meta.version,
        modules: meta.modules
      };
    } catch (error) {
      return {
        healthy: false,
        error: error.message
      };
    }
  }
}

module.exports = WeaviateStore;
