#!/usr/bin/env node
// lib/rag/embeddings/base-embedder.js
// Abstract base class for embedding providers
// Part of RAG Enhancement: Real Embeddings Integration

/**
 * BaseEmbedder - Abstract interface for embedding providers
 *
 * All embedding providers must extend this class and implement:
 * - embed(text) - Generate embedding for single text
 * - embedBatch(texts) - Generate embeddings for multiple texts
 * - getDimensions() - Return embedding dimension size
 */
class BaseEmbedder {
  constructor(config = {}) {
    if (new.target === BaseEmbedder) {
      throw new Error('BaseEmbedder is an abstract class and cannot be instantiated directly');
    }

    this.config = config;
    this.name = 'base';
    this.model = null;
    this.dimensions = null;
    this.maxBatchSize = config.maxBatchSize || 100;
    this.rateLimitDelay = config.rateLimitDelay || 100; // ms between batches
  }

  /**
   * Generate embedding for a single text
   * @param {string} text - Text to embed
   * @returns {Promise<number[]>} - Embedding vector
   */
  async embed(text) {
    throw new Error('embed() must be implemented by subclass');
  }

  /**
   * Generate embeddings for multiple texts (with batching)
   * @param {string[]} texts - Array of texts to embed
   * @returns {Promise<number[][]>} - Array of embedding vectors
   */
  async embedBatch(texts) {
    throw new Error('embedBatch() must be implemented by subclass');
  }

  /**
   * Get the dimension size of embeddings
   * @returns {number} - Embedding dimension
   */
  getDimensions() {
    if (this.dimensions === null) {
      throw new Error('getDimensions() must be implemented by subclass');
    }
    return this.dimensions;
  }

  /**
   * Get embedder name/identifier
   * @returns {string} - Provider name
   */
  getName() {
    return this.name;
  }

  /**
   * Get model identifier
   * @returns {string} - Model name
   */
  getModel() {
    return this.model;
  }

  /**
   * Validate text input
   * @param {string} text - Text to validate
   * @returns {string} - Validated/cleaned text
   */
  validateText(text) {
    if (!text || typeof text !== 'string') {
      throw new Error('Text must be a non-empty string');
    }

    // Trim and normalize whitespace
    const cleaned = text.trim().replace(/\s+/g, ' ');

    if (cleaned.length === 0) {
      throw new Error('Text cannot be empty after trimming');
    }

    return cleaned;
  }

  /**
   * Validate embedding vector
   * @param {number[]} embedding - Embedding to validate
   * @returns {boolean} - Whether embedding is valid
   */
  validateEmbedding(embedding) {
    if (!Array.isArray(embedding)) {
      return false;
    }

    if (embedding.length !== this.dimensions) {
      return false;
    }

    // Check all values are numbers
    return embedding.every(v => typeof v === 'number' && !isNaN(v));
  }

  /**
   * Normalize embedding vector (L2 normalization)
   * @param {number[]} embedding - Embedding to normalize
   * @returns {number[]} - Normalized embedding
   */
  normalize(embedding) {
    const norm = Math.sqrt(embedding.reduce((sum, val) => sum + val * val, 0));
    if (norm === 0) return embedding;
    return embedding.map(val => val / norm);
  }

  /**
   * Sleep utility for rate limiting
   * @param {number} ms - Milliseconds to sleep
   */
  async sleep(ms) {
    return new Promise(resolve => setTimeout(resolve, ms));
  }

  /**
   * Process texts in batches
   * @param {string[]} texts - Texts to process
   * @param {Function} batchProcessor - Function to process each batch
   * @returns {Promise<number[][]>} - All embeddings
   */
  async processBatches(texts, batchProcessor) {
    const embeddings = [];

    for (let i = 0; i < texts.length; i += this.maxBatchSize) {
      const batch = texts.slice(i, i + this.maxBatchSize);
      const batchEmbeddings = await batchProcessor(batch);
      embeddings.push(...batchEmbeddings);

      // Rate limiting between batches
      if (i + this.maxBatchSize < texts.length) {
        await this.sleep(this.rateLimitDelay);
      }
    }

    return embeddings;
  }

  /**
   * Get embedder statistics/info
   * @returns {Object} - Embedder info
   */
  getInfo() {
    return {
      name: this.name,
      model: this.model,
      dimensions: this.dimensions,
      maxBatchSize: this.maxBatchSize,
      rateLimitDelay: this.rateLimitDelay
    };
  }
}

module.exports = BaseEmbedder;
