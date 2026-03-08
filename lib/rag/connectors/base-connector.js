#!/usr/bin/env node
// lib/rag/connectors/base-connector.js
// Abstract base class for repository connectors
// Part of RAG Knowledge Ingestion System

/**
 * BaseConnector - Abstract interface for data source connectors
 *
 * All connectors must extend this class and implement:
 * - connect() - Establish connection to data source
 * - fetch(options) - Fetch data from the source
 * - transform(data) - Transform data to standard format
 * - healthCheck() - Check connector health
 */
class BaseConnector {
  constructor(config = {}) {
    if (new.target === BaseConnector) {
      throw new Error('BaseConnector is an abstract class and cannot be instantiated directly');
    }

    this.config = config;
    this.name = 'base';
    this.type = null;
    this.connected = false;
    this.lastFetch = null;
    this.fetchCount = 0;
    this.errorCount = 0;

    // Rate limiting configuration
    this.rateLimitDelay = config.rateLimitDelay || 1000; // ms between requests
    this.maxRetries = config.maxRetries || 3;
    this.retryDelay = config.retryDelay || 5000; // ms before retry

    // Batch processing configuration
    this.batchSize = config.batchSize || 100;
    this.timeout = config.timeout || 30000; // 30 seconds default
  }

  /**
   * Connect to the data source
   * @returns {Promise<boolean>} - Connection success
   */
  async connect() {
    throw new Error('connect() must be implemented by subclass');
  }

  /**
   * Disconnect from the data source
   * @returns {Promise<void>}
   */
  async disconnect() {
    this.connected = false;
  }

  /**
   * Check if connected to the source
   * @returns {boolean}
   */
  isConnected() {
    return this.connected;
  }

  /**
   * Fetch data from the source
   * @param {Object} options - Fetch options (connector-specific)
   * @returns {Promise<Array<Object>>} - Raw data from source
   */
  async fetch(options = {}) {
    throw new Error('fetch() must be implemented by subclass');
  }

  /**
   * Transform raw data to standard document format
   * @param {Object|Array} data - Raw data from fetch
   * @returns {Array<Object>} - Transformed documents
   */
  transform(data) {
    throw new Error('transform() must be implemented by subclass');
  }

  /**
   * Check connector health and availability
   * @returns {Promise<Object>} - Health status
   */
  async healthCheck() {
    throw new Error('healthCheck() must be implemented by subclass');
  }

  /**
   * Fetch and transform data in one operation
   * @param {Object} options - Fetch options
   * @returns {Promise<Array<Object>>} - Transformed documents
   */
  async fetchAndTransform(options = {}) {
    const raw = await this.fetch(options);
    return this.transform(raw);
  }

  /**
   * Get connector name
   * @returns {string}
   */
  getName() {
    return this.name;
  }

  /**
   * Get connector type
   * @returns {string}
   */
  getType() {
    return this.type;
  }

  /**
   * Get connector statistics
   * @returns {Object}
   */
  getStats() {
    return {
      name: this.name,
      type: this.type,
      connected: this.connected,
      lastFetch: this.lastFetch,
      fetchCount: this.fetchCount,
      errorCount: this.errorCount,
      successRate: this.fetchCount > 0
        ? ((this.fetchCount - this.errorCount) / this.fetchCount * 100).toFixed(2) + '%'
        : 'N/A'
    };
  }

  /**
   * Get connector info/configuration (redacted)
   * @returns {Object}
   */
  getInfo() {
    return {
      name: this.name,
      type: this.type,
      connected: this.connected,
      config: {
        batchSize: this.batchSize,
        timeout: this.timeout,
        rateLimitDelay: this.rateLimitDelay,
        maxRetries: this.maxRetries,
        // Redact sensitive info
        apiKey: this.config.apiKey ? '***' : undefined,
        token: this.config.token ? '***' : undefined
      }
    };
  }

  /**
   * Sleep utility for rate limiting
   * @param {number} ms - Milliseconds to sleep
   */
  async sleep(ms) {
    return new Promise(resolve => setTimeout(resolve, ms));
  }

  /**
   * Retry operation with exponential backoff
   * @param {Function} operation - Async operation to retry
   * @param {number} retries - Number of retries remaining
   * @returns {Promise<*>} - Operation result
   */
  async retryWithBackoff(operation, retries = this.maxRetries) {
    try {
      return await operation();
    } catch (error) {
      if (retries <= 0) {
        throw error;
      }

      const delay = this.retryDelay * Math.pow(2, this.maxRetries - retries);
      await this.sleep(delay);
      return this.retryWithBackoff(operation, retries - 1);
    }
  }

  /**
   * Process items in batches
   * @param {Array} items - Items to process
   * @param {Function} processor - Async processor function
   * @returns {Promise<Array>} - Processed results
   */
  async processBatches(items, processor) {
    const results = [];

    for (let i = 0; i < items.length; i += this.batchSize) {
      const batch = items.slice(i, i + this.batchSize);
      const batchResults = await processor(batch);
      results.push(...batchResults);

      // Rate limiting between batches
      if (i + this.batchSize < items.length) {
        await this.sleep(this.rateLimitDelay);
      }
    }

    return results;
  }

  /**
   * Generate document ID
   * @param {string} source - Source identifier
   * @param {string} id - Original ID
   * @returns {string}
   */
  generateDocumentId(source, id) {
    return `${this.type}:${source}:${id}`;
  }

  /**
   * Create standard document format
   * @param {Object} options - Document options
   * @returns {Object} - Standard document
   */
  createDocument(options) {
    const {
      id,
      content,
      title,
      url,
      metadata = {},
      source,
      type
    } = options;

    return {
      id: this.generateDocumentId(source || this.name, id),
      content: content,
      title: title || '',
      url: url || '',
      metadata: {
        ...metadata,
        connector: this.type,
        source: source || this.name,
        contentType: type || 'text',
        fetchedAt: new Date().toISOString()
      }
    };
  }

  /**
   * Validate configuration
   * @param {Array<string>} required - Required config keys
   * @throws {Error} - If required config is missing
   */
  validateConfig(required = []) {
    const missing = required.filter(key => !this.config[key]);
    if (missing.length > 0) {
      throw new Error(`Missing required configuration: ${missing.join(', ')}`);
    }
  }

  /**
   * Log connector activity
   * @param {string} level - Log level (info, warn, error)
   * @param {string} message - Log message
   * @param {Object} data - Additional data
   */
  log(level, message, data = {}) {
    const entry = {
      timestamp: new Date().toISOString(),
      connector: this.name,
      type: this.type,
      level,
      message,
      ...data
    };

    if (level === 'error') {
      console.error(JSON.stringify(entry));
    } else {
      console.log(JSON.stringify(entry));
    }
  }

  /**
   * Update fetch statistics
   * @param {boolean} success - Whether fetch was successful
   */
  updateStats(success) {
    this.fetchCount++;
    if (!success) {
      this.errorCount++;
    }
    this.lastFetch = new Date().toISOString();
  }

  /**
   * Truncate text to maximum length
   * @param {string} text - Text to truncate
   * @param {number} maxLength - Maximum length
   * @returns {string}
   */
  truncate(text, maxLength = 10000) {
    if (!text || text.length <= maxLength) {
      return text;
    }
    return text.substring(0, maxLength) + '... [truncated]';
  }

  /**
   * Strip HTML tags from text
   * @param {string} html - HTML content
   * @returns {string} - Plain text
   */
  stripHtml(html) {
    if (!html) return '';
    return html
      .replace(/<script\b[^<]*(?:(?!<\/script>)<[^<]*)*<\/script>/gi, '')
      .replace(/<style\b[^<]*(?:(?!<\/style>)<[^<]*)*<\/style>/gi, '')
      .replace(/<[^>]+>/g, ' ')
      .replace(/\s+/g, ' ')
      .trim();
  }

  /**
   * Parse JSON safely
   * @param {string} str - JSON string
   * @param {*} defaultValue - Default value on error
   * @returns {*}
   */
  safeJsonParse(str, defaultValue = null) {
    try {
      return JSON.parse(str);
    } catch {
      return defaultValue;
    }
  }
}

module.exports = BaseConnector;
