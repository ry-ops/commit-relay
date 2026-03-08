#!/usr/bin/env node
// lib/rag/embeddings/ollama-embedder.js
// Ollama Local Embeddings Provider
// Part of RAG Enhancement: Real Embeddings Integration

const BaseEmbedder = require('./base-embedder');

/**
 * OllamaEmbedder - Local Ollama embeddings adapter
 *
 * Supports local embedding models:
 * - nomic-embed-text (768 dimensions, default)
 * - mxbai-embed-large (1024 dimensions)
 * - all-minilm (384 dimensions)
 *
 * Ideal for:
 * - Air-gapped environments
 * - Privacy-sensitive applications
 * - Development/testing without API costs
 */
class OllamaEmbedder extends BaseEmbedder {
  constructor(config = {}) {
    super(config);

    this.name = 'ollama';
    this.model = config.model || 'nomic-embed-text';

    // Set dimensions based on model (may be updated on first call)
    this.dimensions = this._getModelDimensions(this.model);

    // Server configuration
    this.baseURL = config.baseURL || process.env.OLLAMA_HOST || 'http://localhost:11434';
    this.maxBatchSize = config.maxBatchSize || 10; // Ollama processes sequentially
    this.rateLimitDelay = config.rateLimitDelay || 50;
    this.timeout = config.timeout || 60000; // 60 second timeout
    this.maxRetries = config.maxRetries || 3;
    this.retryDelay = config.retryDelay || 1000;
  }

  /**
   * Get default dimension size for known models
   */
  _getModelDimensions(model) {
    const modelDimensions = {
      'nomic-embed-text': 768,
      'mxbai-embed-large': 1024,
      'all-minilm': 384,
      'snowflake-arctic-embed': 1024
    };

    return modelDimensions[model] || 768;
  }

  /**
   * Make HTTP request to Ollama API
   */
  async _fetch(endpoint, body) {
    const url = `${this.baseURL}${endpoint}`;

    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), this.timeout);

    try {
      const response = await fetch(url, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json'
        },
        body: JSON.stringify(body),
        signal: controller.signal
      });

      clearTimeout(timeoutId);

      if (!response.ok) {
        const errorText = await response.text();
        throw new Error(`Ollama API error ${response.status}: ${errorText}`);
      }

      return await response.json();
    } catch (error) {
      clearTimeout(timeoutId);

      if (error.name === 'AbortError') {
        throw new Error(`Ollama request timed out after ${this.timeout}ms`);
      }

      if (error.cause?.code === 'ECONNREFUSED') {
        throw new Error(`Cannot connect to Ollama at ${this.baseURL}. Is Ollama running?`);
      }

      throw error;
    }
  }

  /**
   * Check if Ollama server is available
   */
  async isAvailable() {
    try {
      const response = await fetch(`${this.baseURL}/api/tags`, {
        method: 'GET',
        signal: AbortSignal.timeout(5000)
      });
      return response.ok;
    } catch {
      return false;
    }
  }

  /**
   * Check if model is available locally
   */
  async isModelAvailable() {
    try {
      const response = await fetch(`${this.baseURL}/api/tags`, {
        method: 'GET',
        signal: AbortSignal.timeout(5000)
      });

      if (!response.ok) return false;

      const data = await response.json();
      const models = data.models || [];

      return models.some(m => m.name === this.model || m.name.startsWith(`${this.model}:`));
    } catch {
      return false;
    }
  }

  /**
   * Pull model if not available
   */
  async pullModel() {
    console.log(`Pulling model ${this.model}...`);

    try {
      const response = await fetch(`${this.baseURL}/api/pull`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({ name: this.model })
      });

      if (!response.ok) {
        throw new Error(`Failed to pull model: ${response.status}`);
      }

      // Stream the response to track progress
      const reader = response.body.getReader();
      const decoder = new TextDecoder();

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;

        const text = decoder.decode(value);
        const lines = text.split('\n').filter(l => l.trim());

        for (const line of lines) {
          try {
            const data = JSON.parse(line);
            if (data.status) {
              console.log(`  ${data.status}`);
            }
          } catch {
            // Ignore parsing errors
          }
        }
      }

      console.log(`Model ${this.model} pulled successfully`);
      return true;
    } catch (error) {
      console.error(`Failed to pull model: ${error.message}`);
      return false;
    }
  }

  /**
   * Generate embedding for single text
   */
  async embed(text) {
    const validatedText = this.validateText(text);

    let lastError;
    for (let attempt = 1; attempt <= this.maxRetries; attempt++) {
      try {
        const response = await this._fetch('/api/embeddings', {
          model: this.model,
          prompt: validatedText
        });

        const embedding = response.embedding;

        if (!embedding || !Array.isArray(embedding)) {
          throw new Error('Invalid response: missing embedding array');
        }

        // Update dimensions from actual response
        this.dimensions = embedding.length;

        return embedding;
      } catch (error) {
        lastError = error;

        // Check if model needs to be pulled
        if (error.message.includes('model') && error.message.includes('not found')) {
          console.warn(`Model ${this.model} not found. Attempting to pull...`);
          const pulled = await this.pullModel();
          if (pulled) {
            continue; // Retry after pulling
          }
        }

        // Retry on connection errors
        if (error.message.includes('ECONNREFUSED') || error.message.includes('timed out')) {
          if (attempt < this.maxRetries) {
            await this.sleep(this.retryDelay * attempt);
            continue;
          }
        }

        // Don't retry other errors
        break;
      }
    }

    throw new Error(`Failed to generate embedding: ${lastError.message}`);
  }

  /**
   * Generate embeddings for multiple texts
   * Note: Ollama doesn't support batch embeddings, so we process sequentially
   */
  async embedBatch(texts) {
    if (!Array.isArray(texts) || texts.length === 0) {
      throw new Error('Texts must be a non-empty array');
    }

    // Validate all texts first
    const validatedTexts = texts.map(text => this.validateText(text));

    // Process in batches (sequential within each batch for Ollama)
    return await this.processBatches(validatedTexts, async (batch) => {
      const embeddings = [];

      for (const text of batch) {
        const embedding = await this.embed(text);
        embeddings.push(embedding);
      }

      return embeddings;
    });
  }

  /**
   * Get embedder info
   */
  getInfo() {
    return {
      ...super.getInfo(),
      baseURL: this.baseURL,
      timeout: this.timeout
    };
  }
}

module.exports = OllamaEmbedder;
