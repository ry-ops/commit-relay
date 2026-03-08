#!/usr/bin/env node
// lib/rag/embeddings/openai-embedder.js
// OpenAI Embeddings Provider
// Part of RAG Enhancement: Real Embeddings Integration

const BaseEmbedder = require('./base-embedder');

/**
 * OpenAIEmbedder - OpenAI embeddings API adapter
 *
 * Supports:
 * - text-embedding-3-small (1536 dimensions, default)
 * - text-embedding-3-large (3072 dimensions)
 * - text-embedding-ada-002 (1536 dimensions, legacy)
 */
class OpenAIEmbedder extends BaseEmbedder {
  constructor(config = {}) {
    super(config);

    this.name = 'openai';
    this.model = config.model || 'text-embedding-3-small';

    // Set dimensions based on model
    this.dimensions = this._getModelDimensions(this.model);

    // API configuration
    this.apiKey = config.apiKey || process.env.OPENAI_API_KEY;
    this.baseURL = config.baseURL || 'https://api.openai.com/v1';
    this.maxBatchSize = config.maxBatchSize || 100; // OpenAI supports up to 2048
    this.rateLimitDelay = config.rateLimitDelay || 200;
    this.maxRetries = config.maxRetries || 3;
    this.retryDelay = config.retryDelay || 1000;

    // Optional: reduce dimensions for text-embedding-3 models
    this.reducedDimensions = config.reducedDimensions || null;

    // OpenAI client (lazy loaded)
    this.client = null;
  }

  /**
   * Get dimension size for model
   */
  _getModelDimensions(model) {
    const modelDimensions = {
      'text-embedding-3-small': 1536,
      'text-embedding-3-large': 3072,
      'text-embedding-ada-002': 1536
    };

    return modelDimensions[model] || 1536;
  }

  /**
   * Initialize OpenAI client
   */
  async _initClient() {
    if (this.client) return;

    if (!this.apiKey) {
      throw new Error('OpenAI API key not provided. Set OPENAI_API_KEY environment variable or pass apiKey in config.');
    }

    try {
      // Dynamic import for openai package
      const OpenAI = require('openai');
      this.client = new OpenAI({
        apiKey: this.apiKey,
        baseURL: this.baseURL
      });
    } catch (error) {
      if (error.code === 'MODULE_NOT_FOUND') {
        throw new Error('OpenAI package not installed. Run: npm install openai');
      }
      throw error;
    }
  }

  /**
   * Generate embedding for single text
   */
  async embed(text) {
    await this._initClient();

    const validatedText = this.validateText(text);

    const params = {
      model: this.model,
      input: validatedText
    };

    // Add dimensions parameter for text-embedding-3 models if reduction requested
    if (this.reducedDimensions && this.model.startsWith('text-embedding-3')) {
      params.dimensions = this.reducedDimensions;
    }

    let lastError;
    for (let attempt = 1; attempt <= this.maxRetries; attempt++) {
      try {
        const response = await this.client.embeddings.create(params);

        const embedding = response.data[0].embedding;

        // Update actual dimensions if reduced
        if (this.reducedDimensions) {
          this.dimensions = embedding.length;
        }

        return embedding;
      } catch (error) {
        lastError = error;

        // Handle rate limiting
        if (error.status === 429) {
          const waitTime = this.retryDelay * Math.pow(2, attempt - 1);
          console.warn(`Rate limited. Waiting ${waitTime}ms before retry ${attempt}/${this.maxRetries}`);
          await this.sleep(waitTime);
          continue;
        }

        // Handle token limit errors
        if (error.code === 'context_length_exceeded') {
          throw new Error(`Text too long for embedding: ${validatedText.length} characters`);
        }

        // Don't retry other errors
        break;
      }
    }

    throw new Error(`Failed to generate embedding after ${this.maxRetries} attempts: ${lastError.message}`);
  }

  /**
   * Generate embeddings for multiple texts
   */
  async embedBatch(texts) {
    await this._initClient();

    if (!Array.isArray(texts) || texts.length === 0) {
      throw new Error('Texts must be a non-empty array');
    }

    // Validate all texts
    const validatedTexts = texts.map(text => this.validateText(text));

    // Process in batches
    return await this.processBatches(validatedTexts, async (batch) => {
      const params = {
        model: this.model,
        input: batch
      };

      // Add dimensions parameter for text-embedding-3 models if reduction requested
      if (this.reducedDimensions && this.model.startsWith('text-embedding-3')) {
        params.dimensions = this.reducedDimensions;
      }

      let lastError;
      for (let attempt = 1; attempt <= this.maxRetries; attempt++) {
        try {
          const response = await this.client.embeddings.create(params);

          // Sort by index to maintain order
          const sortedData = response.data.sort((a, b) => a.index - b.index);
          const embeddings = sortedData.map(item => item.embedding);

          // Update actual dimensions if reduced
          if (this.reducedDimensions && embeddings.length > 0) {
            this.dimensions = embeddings[0].length;
          }

          return embeddings;
        } catch (error) {
          lastError = error;

          // Handle rate limiting
          if (error.status === 429) {
            const waitTime = this.retryDelay * Math.pow(2, attempt - 1);
            console.warn(`Rate limited. Waiting ${waitTime}ms before retry ${attempt}/${this.maxRetries}`);
            await this.sleep(waitTime);
            continue;
          }

          // Don't retry other errors
          break;
        }
      }

      throw new Error(`Failed to generate batch embeddings: ${lastError.message}`);
    });
  }

  /**
   * Get usage statistics from last request
   */
  getUsageStats() {
    // This would track usage if needed
    return {
      model: this.model,
      dimensions: this.dimensions,
      reducedDimensions: this.reducedDimensions
    };
  }

  /**
   * Get embedder info
   */
  getInfo() {
    return {
      ...super.getInfo(),
      apiKey: this.apiKey ? '***' + this.apiKey.slice(-4) : 'not set',
      baseURL: this.baseURL,
      reducedDimensions: this.reducedDimensions
    };
  }
}

module.exports = OpenAIEmbedder;
