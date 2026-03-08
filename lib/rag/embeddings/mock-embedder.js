#!/usr/bin/env node
// lib/rag/embeddings/mock-embedder.js
// Mock Embeddings Provider for Testing
// Part of RAG Enhancement: Real Embeddings Integration

const crypto = require('crypto');
const BaseEmbedder = require('./base-embedder');

/**
 * MockEmbedder - Hash-based mock embeddings for testing
 *
 * Features:
 * - Deterministic embeddings (same text = same embedding)
 * - Configurable dimensions
 * - Simulated latency for realistic testing
 * - Semantic similarity preservation (similar texts have similar embeddings)
 */
class MockEmbedder extends BaseEmbedder {
  constructor(config = {}) {
    super(config);

    this.name = 'mock';
    this.model = 'mock-hash-v1';
    this.dimensions = config.dimensions || 1536;
    this.maxBatchSize = config.maxBatchSize || 100;
    this.rateLimitDelay = config.rateLimitDelay || 10;

    // Simulated latency (ms)
    this.latency = config.latency || 0;

    // Seed for reproducible randomness
    this.seed = config.seed || 'commit-relay-rag';

    // Track calls for testing
    this.callCount = 0;
    this.batchCallCount = 0;
  }

  /**
   * Generate deterministic hash-based embedding
   * @param {string} text - Text to embed
   * @returns {Promise<number[]>} - Mock embedding vector
   */
  async embed(text) {
    const validatedText = this.validateText(text);

    // Simulate network latency
    if (this.latency > 0) {
      await this.sleep(this.latency);
    }

    this.callCount++;

    return this._generateHashEmbedding(validatedText);
  }

  /**
   * Generate embeddings for multiple texts
   * @param {string[]} texts - Array of texts to embed
   * @returns {Promise<number[][]>} - Array of mock embedding vectors
   */
  async embedBatch(texts) {
    if (!Array.isArray(texts) || texts.length === 0) {
      throw new Error('Texts must be a non-empty array');
    }

    // Validate all texts
    const validatedTexts = texts.map(text => this.validateText(text));

    this.batchCallCount++;

    // Process in batches
    return await this.processBatches(validatedTexts, async (batch) => {
      // Simulate latency per batch
      if (this.latency > 0) {
        await this.sleep(this.latency);
      }

      return batch.map(text => this._generateHashEmbedding(text));
    });
  }

  /**
   * Generate hash-based embedding vector
   * Creates deterministic but distributed vectors
   */
  _generateHashEmbedding(text) {
    const embedding = new Array(this.dimensions).fill(0);

    // Create primary hash
    const hash = crypto.createHash('sha256')
      .update(this.seed + text)
      .digest();

    // Generate embedding values using hash
    for (let i = 0; i < this.dimensions; i++) {
      // Use multiple bytes for better distribution
      const byteIndex = i % hash.length;
      const nextByteIndex = (i + 1) % hash.length;

      // Combine bytes for smoother values
      const value1 = hash[byteIndex] / 255;
      const value2 = hash[nextByteIndex] / 255;

      // Map to [-1, 1] range with some variation
      embedding[i] = ((value1 + value2) / 2) * 2 - 1;
    }

    // Add semantic similarity by incorporating word frequencies
    const words = text.toLowerCase().split(/\s+/);
    const uniqueWords = [...new Set(words)];

    for (let i = 0; i < uniqueWords.length; i++) {
      const word = uniqueWords[i];
      const wordHash = crypto.createHash('md5').update(word).digest();
      const position = wordHash[0] % this.dimensions;

      // Boost dimension based on word
      embedding[position] = (embedding[position] + (wordHash[1] / 255)) / 2;
    }

    // Normalize the embedding
    return this.normalize(embedding);
  }

  /**
   * Get call statistics for testing
   */
  getCallStats() {
    return {
      embedCalls: this.callCount,
      batchCalls: this.batchCallCount
    };
  }

  /**
   * Reset call counters
   */
  resetStats() {
    this.callCount = 0;
    this.batchCallCount = 0;
  }

  /**
   * Get embedder info
   */
  getInfo() {
    return {
      ...super.getInfo(),
      seed: this.seed,
      latency: this.latency,
      callStats: this.getCallStats()
    };
  }
}

module.exports = MockEmbedder;
