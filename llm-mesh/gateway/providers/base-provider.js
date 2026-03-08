/**
 * Base Provider Abstract Class
 *
 * Defines the interface that all LLM providers must implement.
 * This ensures consistent API across different model providers.
 *
 * @module llm-mesh/gateway/providers/base-provider
 */

'use strict';

/**
 * @typedef {Object} Message
 * @property {string} role - The role of the message sender ('user', 'assistant', 'system')
 * @property {string} content - The content of the message
 */

/**
 * @typedef {Object} CompletionOptions
 * @property {string} [model] - Override the default model
 * @property {number} [maxTokens] - Maximum tokens to generate
 * @property {number} [temperature] - Sampling temperature (0-1)
 * @property {boolean} [stream] - Enable streaming response
 * @property {string[]} [stopSequences] - Stop sequences
 * @property {Object} [metadata] - Additional provider-specific options
 */

/**
 * @typedef {Object} CompletionResponse
 * @property {string} content - The generated text content
 * @property {string} model - The model used for generation
 * @property {Object} usage - Token usage information
 * @property {number} usage.inputTokens - Number of input tokens
 * @property {number} usage.outputTokens - Number of output tokens
 * @property {string} stopReason - Reason for stopping generation
 * @property {string} provider - Provider name
 */

/**
 * @typedef {Object} EmbeddingResponse
 * @property {number[]} embedding - The embedding vector
 * @property {string} model - The model used for embedding
 * @property {number} dimensions - Dimensions of the embedding
 * @property {string} provider - Provider name
 */

/**
 * Abstract base class for LLM providers
 * @abstract
 */
class BaseProvider {
  /**
   * Create a new provider instance
   * @param {Object} config - Provider configuration
   * @param {string} config.name - Provider name
   * @param {string} [config.apiKey] - API key for authentication
   * @param {string} [config.baseUrl] - Base URL for API calls
   * @param {string} [config.defaultModel] - Default model to use
   * @param {Object} [config.options] - Additional provider options
   */
  constructor(config) {
    if (new.target === BaseProvider) {
      throw new Error('BaseProvider is abstract and cannot be instantiated directly');
    }

    this.name = config.name;
    this.apiKey = config.apiKey;
    this.baseUrl = config.baseUrl;
    this.defaultModel = config.defaultModel;
    this.options = config.options || {};
    this.initialized = false;

    // Metrics tracking
    this.metrics = {
      totalRequests: 0,
      successfulRequests: 0,
      failedRequests: 0,
      totalInputTokens: 0,
      totalOutputTokens: 0,
      totalLatencyMs: 0
    };
  }

  /**
   * Initialize the provider (load SDK, validate config, etc.)
   * @abstract
   * @returns {Promise<void>}
   */
  async initialize() {
    throw new Error('Method initialize() must be implemented by subclass');
  }

  /**
   * Generate a completion from messages
   * @abstract
   * @param {Message[]} messages - Array of messages for the conversation
   * @param {CompletionOptions} [options] - Completion options
   * @returns {Promise<CompletionResponse>}
   */
  async complete(messages, options = {}) {
    throw new Error('Method complete() must be implemented by subclass');
  }

  /**
   * Generate a streaming completion from messages
   * @abstract
   * @param {Message[]} messages - Array of messages for the conversation
   * @param {CompletionOptions} [options] - Completion options
   * @returns {AsyncGenerator<string>} Yields text chunks as they arrive
   */
  async *completeStream(messages, options = {}) {
    throw new Error('Method completeStream() must be implemented by subclass');
  }

  /**
   * Generate embeddings for text
   * @abstract
   * @param {string} text - Text to embed
   * @param {Object} [options] - Embedding options
   * @returns {Promise<EmbeddingResponse>}
   */
  async embed(text, options = {}) {
    throw new Error('Method embed() must be implemented by subclass');
  }

  /**
   * Count tokens in text
   * @abstract
   * @param {string} text - Text to count tokens for
   * @returns {Promise<number>} Token count
   */
  async getTokenCount(text) {
    throw new Error('Method getTokenCount() must be implemented by subclass');
  }

  /**
   * Get cost per 1000 tokens for input/output
   * @abstract
   * @param {string} [model] - Model to get cost for (uses default if not specified)
   * @returns {{input: number, output: number}} Cost per 1000 tokens in USD
   */
  getCostPerToken(model) {
    throw new Error('Method getCostPerToken() must be implemented by subclass');
  }

  /**
   * Check if provider is available and configured
   * @returns {Promise<boolean>}
   */
  async isAvailable() {
    try {
      if (!this.initialized) {
        await this.initialize();
      }
      return true;
    } catch (error) {
      return false;
    }
  }

  /**
   * Get provider metrics
   * @returns {Object} Provider metrics
   */
  getMetrics() {
    const avgLatency = this.metrics.totalRequests > 0
      ? this.metrics.totalLatencyMs / this.metrics.totalRequests
      : 0;

    return {
      ...this.metrics,
      avgLatencyMs: Math.round(avgLatency),
      successRate: this.metrics.totalRequests > 0
        ? (this.metrics.successfulRequests / this.metrics.totalRequests * 100).toFixed(2) + '%'
        : 'N/A'
    };
  }

  /**
   * Record a successful request
   * @protected
   * @param {number} inputTokens - Input tokens used
   * @param {number} outputTokens - Output tokens generated
   * @param {number} latencyMs - Request latency in milliseconds
   */
  recordSuccess(inputTokens, outputTokens, latencyMs) {
    this.metrics.totalRequests++;
    this.metrics.successfulRequests++;
    this.metrics.totalInputTokens += inputTokens;
    this.metrics.totalOutputTokens += outputTokens;
    this.metrics.totalLatencyMs += latencyMs;
  }

  /**
   * Record a failed request
   * @protected
   */
  recordFailure() {
    this.metrics.totalRequests++;
    this.metrics.failedRequests++;
  }

  /**
   * Format error for consistent error handling
   * @protected
   * @param {Error} error - Original error
   * @param {string} operation - Operation that failed
   * @returns {Error} Formatted error
   */
  formatError(error, operation) {
    const formattedError = new Error(
      `[${this.name}] ${operation} failed: ${error.message}`
    );
    formattedError.provider = this.name;
    formattedError.operation = operation;
    formattedError.originalError = error;
    formattedError.statusCode = error.status || error.statusCode;
    return formattedError;
  }

  /**
   * Log provider activity
   * @protected
   * @param {string} level - Log level ('info', 'warn', 'error', 'debug')
   * @param {string} message - Log message
   * @param {Object} [data] - Additional data to log
   */
  log(level, message, data = {}) {
    const timestamp = new Date().toISOString();
    const logEntry = {
      timestamp,
      provider: this.name,
      level,
      message,
      ...data
    };

    // In production, this would integrate with a proper logging system
    if (level === 'error') {
      console.error(JSON.stringify(logEntry));
    } else if (level === 'warn') {
      console.warn(JSON.stringify(logEntry));
    } else if (process.env.DEBUG || level === 'info') {
      console.log(JSON.stringify(logEntry));
    }
  }

  /**
   * List available models for this provider
   * @abstract
   * @returns {Promise<string[]>} List of model identifiers
   */
  async listModels() {
    throw new Error('Method listModels() must be implemented by subclass');
  }

  /**
   * Get information about a specific model
   * @param {string} model - Model identifier
   * @returns {Object|null} Model information or null if not found
   */
  getModelInfo(model) {
    // Subclasses should override with specific model info
    return null;
  }
}

module.exports = BaseProvider;
