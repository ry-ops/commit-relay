/**
 * OpenAI GPT Provider
 *
 * Adapter for OpenAI's GPT models (gpt-4-turbo, gpt-3.5-turbo).
 * Implements the BaseProvider interface with embedding support.
 *
 * @module llm-mesh/gateway/providers/openai
 */

'use strict';

const BaseProvider = require('./base-provider');

/**
 * Model pricing per 1000 tokens (USD)
 * @constant
 */
const MODEL_PRICING = {
  'gpt-4-turbo': { input: 0.01, output: 0.03 },
  'gpt-4-turbo-preview': { input: 0.01, output: 0.03 },
  'gpt-4-0125-preview': { input: 0.01, output: 0.03 },
  'gpt-4': { input: 0.03, output: 0.06 },
  'gpt-4-32k': { input: 0.06, output: 0.12 },
  'gpt-3.5-turbo': { input: 0.0005, output: 0.0015 },
  'gpt-3.5-turbo-0125': { input: 0.0005, output: 0.0015 },
  'gpt-3.5-turbo-16k': { input: 0.003, output: 0.004 },
  'text-embedding-3-small': { input: 0.00002, output: 0 },
  'text-embedding-3-large': { input: 0.00013, output: 0 },
  'text-embedding-ada-002': { input: 0.0001, output: 0 }
};

/**
 * Model aliases for easier reference
 * @constant
 */
const MODEL_ALIASES = {
  'gpt4': 'gpt-4-turbo',
  'gpt4-turbo': 'gpt-4-turbo',
  'gpt35': 'gpt-3.5-turbo',
  'gpt3': 'gpt-3.5-turbo'
};

/**
 * OpenAI GPT provider implementation
 * @extends BaseProvider
 */
class OpenAIProvider extends BaseProvider {
  /**
   * Create an OpenAI provider instance
   * @param {Object} config - Provider configuration
   * @param {string} [config.apiKey] - OpenAI API key (defaults to OPENAI_API_KEY env var)
   * @param {string} [config.defaultModel='gpt-3.5-turbo'] - Default model to use
   * @param {string} [config.organization] - OpenAI organization ID
   */
  constructor(config = {}) {
    super({
      name: 'openai',
      apiKey: config.apiKey || process.env.OPENAI_API_KEY,
      defaultModel: config.defaultModel || 'gpt-3.5-turbo',
      ...config
    });

    this.client = null;
    this.organization = config.organization || process.env.OPENAI_ORG_ID;
    this.embeddingModel = config.embeddingModel || 'text-embedding-3-small';
    this.maxRetries = config.maxRetries || 3;
    this.timeout = config.timeout || 60000;
  }

  /**
   * Initialize the OpenAI SDK
   * @returns {Promise<void>}
   */
  async initialize() {
    if (this.initialized) return;

    if (!this.apiKey) {
      throw new Error('OpenAI API key is required. Set OPENAI_API_KEY environment variable.');
    }

    try {
      const OpenAI = require('openai');
      this.client = new OpenAI({
        apiKey: this.apiKey,
        organization: this.organization,
        maxRetries: this.maxRetries,
        timeout: this.timeout
      });
      this.initialized = true;
      this.log('info', 'OpenAI provider initialized successfully');
    } catch (error) {
      throw this.formatError(error, 'initialization');
    }
  }

  /**
   * Resolve model alias to full model name
   * @private
   * @param {string} model - Model name or alias
   * @returns {string} Full model name
   */
  resolveModel(model) {
    return MODEL_ALIASES[model] || model;
  }

  /**
   * Generate a completion from messages
   * @param {Array<{role: string, content: string}>} messages - Conversation messages
   * @param {Object} [options] - Completion options
   * @returns {Promise<Object>} Completion response
   */
  async complete(messages, options = {}) {
    if (!this.initialized) await this.initialize();

    const startTime = Date.now();
    const model = this.resolveModel(options.model || this.defaultModel);

    try {
      const requestParams = {
        model,
        messages: messages.map(m => ({
          role: m.role,
          content: m.content
        }))
      };

      // Add optional parameters
      if (options.maxTokens) {
        requestParams.max_tokens = options.maxTokens;
      }
      if (options.temperature !== undefined) {
        requestParams.temperature = options.temperature;
      }
      if (options.stopSequences) {
        requestParams.stop = options.stopSequences;
      }
      if (options.metadata?.responseFormat) {
        requestParams.response_format = options.metadata.responseFormat;
      }
      if (options.metadata?.seed !== undefined) {
        requestParams.seed = options.metadata.seed;
      }

      this.log('debug', 'Sending completion request', { model, messageCount: messages.length });

      const response = await this.client.chat.completions.create(requestParams);

      const latencyMs = Date.now() - startTime;
      const usage = response.usage || { prompt_tokens: 0, completion_tokens: 0 };

      this.recordSuccess(
        usage.prompt_tokens,
        usage.completion_tokens,
        latencyMs
      );

      this.log('info', 'Completion successful', {
        model,
        inputTokens: usage.prompt_tokens,
        outputTokens: usage.completion_tokens,
        latencyMs
      });

      return {
        content: response.choices[0].message.content,
        model: response.model,
        usage: {
          inputTokens: usage.prompt_tokens,
          outputTokens: usage.completion_tokens
        },
        stopReason: response.choices[0].finish_reason,
        provider: this.name
      };
    } catch (error) {
      this.recordFailure();
      this.log('error', 'Completion failed', { error: error.message, model });
      throw this.formatError(error, 'completion');
    }
  }

  /**
   * Generate a streaming completion
   * @param {Array<{role: string, content: string}>} messages - Conversation messages
   * @param {Object} [options] - Completion options
   * @yields {string} Text chunks as they arrive
   */
  async *completeStream(messages, options = {}) {
    if (!this.initialized) await this.initialize();

    const startTime = Date.now();
    const model = this.resolveModel(options.model || this.defaultModel);

    try {
      const requestParams = {
        model,
        messages: messages.map(m => ({
          role: m.role,
          content: m.content
        })),
        stream: true,
        stream_options: { include_usage: true }
      };

      if (options.maxTokens) {
        requestParams.max_tokens = options.maxTokens;
      }
      if (options.temperature !== undefined) {
        requestParams.temperature = options.temperature;
      }
      if (options.stopSequences) {
        requestParams.stop = options.stopSequences;
      }

      this.log('debug', 'Starting streaming completion', { model });

      const stream = await this.client.chat.completions.create(requestParams);

      let totalInputTokens = 0;
      let totalOutputTokens = 0;

      for await (const chunk of stream) {
        if (chunk.choices[0]?.delta?.content) {
          yield chunk.choices[0].delta.content;
        }
        if (chunk.usage) {
          totalInputTokens = chunk.usage.prompt_tokens;
          totalOutputTokens = chunk.usage.completion_tokens;
        }
      }

      const latencyMs = Date.now() - startTime;
      this.recordSuccess(totalInputTokens, totalOutputTokens, latencyMs);

      this.log('info', 'Streaming completion successful', {
        model,
        inputTokens: totalInputTokens,
        outputTokens: totalOutputTokens,
        latencyMs
      });
    } catch (error) {
      this.recordFailure();
      this.log('error', 'Streaming completion failed', { error: error.message, model });
      throw this.formatError(error, 'streaming completion');
    }
  }

  /**
   * Generate embeddings for text
   * @param {string} text - Text to embed
   * @param {Object} [options] - Embedding options
   * @param {string} [options.model] - Embedding model to use
   * @returns {Promise<Object>} Embedding response
   */
  async embed(text, options = {}) {
    if (!this.initialized) await this.initialize();

    const startTime = Date.now();
    const model = options.model || this.embeddingModel;

    try {
      this.log('debug', 'Generating embedding', { model, textLength: text.length });

      const response = await this.client.embeddings.create({
        model,
        input: text,
        encoding_format: 'float'
      });

      const latencyMs = Date.now() - startTime;
      const usage = response.usage || { prompt_tokens: 0 };

      this.recordSuccess(usage.prompt_tokens, 0, latencyMs);

      this.log('info', 'Embedding generated successfully', {
        model,
        dimensions: response.data[0].embedding.length,
        latencyMs
      });

      return {
        embedding: response.data[0].embedding,
        model: response.model,
        dimensions: response.data[0].embedding.length,
        provider: this.name
      };
    } catch (error) {
      this.recordFailure();
      this.log('error', 'Embedding failed', { error: error.message, model });
      throw this.formatError(error, 'embedding');
    }
  }

  /**
   * Count tokens in text using tiktoken
   * @param {string} text - Text to count tokens for
   * @returns {Promise<number>} Token count
   */
  async getTokenCount(text) {
    try {
      const { encoding_for_model } = require('tiktoken');
      const model = this.resolveModel(this.defaultModel);

      // Get the appropriate encoder
      let encoder;
      try {
        encoder = encoding_for_model(model);
      } catch {
        // Fall back to cl100k_base for newer models
        const { get_encoding } = require('tiktoken');
        encoder = get_encoding('cl100k_base');
      }

      const tokens = encoder.encode(text);
      const count = tokens.length;
      encoder.free();

      return count;
    } catch (error) {
      // Fallback to approximation if tiktoken not available
      this.log('warn', 'Tiktoken not available, using approximation', { error: error.message });
      return Math.ceil(text.length / 4);
    }
  }

  /**
   * Get cost per 1000 tokens for a model
   * @param {string} [model] - Model to get cost for
   * @returns {{input: number, output: number}} Cost per 1000 tokens in USD
   */
  getCostPerToken(model) {
    const resolvedModel = this.resolveModel(model || this.defaultModel);
    return MODEL_PRICING[resolvedModel] || MODEL_PRICING['gpt-3.5-turbo'];
  }

  /**
   * List available OpenAI models
   * @returns {Promise<string[]>} List of model identifiers
   */
  async listModels() {
    return Object.keys(MODEL_PRICING).filter(m => !m.includes('embedding'));
  }

  /**
   * List available embedding models
   * @returns {string[]} List of embedding model identifiers
   */
  listEmbeddingModels() {
    return Object.keys(MODEL_PRICING).filter(m => m.includes('embedding'));
  }

  /**
   * Get information about a specific model
   * @param {string} model - Model identifier
   * @returns {Object|null} Model information
   */
  getModelInfo(model) {
    const resolvedModel = this.resolveModel(model);
    const pricing = MODEL_PRICING[resolvedModel];

    if (!pricing) return null;

    const modelInfo = {
      id: resolvedModel,
      provider: 'openai',
      pricing,
      contextWindow: 4096,
      maxOutputTokens: 4096
    };

    // Model-specific adjustments
    if (resolvedModel.includes('gpt-4-turbo')) {
      modelInfo.contextWindow = 128000;
      modelInfo.maxOutputTokens = 4096;
      modelInfo.tier = 'premium';
    } else if (resolvedModel.includes('gpt-4-32k')) {
      modelInfo.contextWindow = 32768;
      modelInfo.maxOutputTokens = 8192;
      modelInfo.tier = 'premium';
    } else if (resolvedModel.includes('gpt-4')) {
      modelInfo.contextWindow = 8192;
      modelInfo.maxOutputTokens = 8192;
      modelInfo.tier = 'standard';
    } else if (resolvedModel.includes('16k')) {
      modelInfo.contextWindow = 16384;
      modelInfo.maxOutputTokens = 4096;
      modelInfo.tier = 'fast';
    } else if (resolvedModel.includes('gpt-3.5')) {
      modelInfo.contextWindow = 4096;
      modelInfo.maxOutputTokens = 4096;
      modelInfo.tier = 'fast';
    } else if (resolvedModel.includes('embedding')) {
      modelInfo.contextWindow = 8191;
      modelInfo.maxOutputTokens = 0;
      modelInfo.tier = 'embedding';
      if (resolvedModel.includes('3-large')) {
        modelInfo.dimensions = 3072;
      } else if (resolvedModel.includes('3-small')) {
        modelInfo.dimensions = 1536;
      } else {
        modelInfo.dimensions = 1536;
      }
    }

    return modelInfo;
  }
}

module.exports = OpenAIProvider;
