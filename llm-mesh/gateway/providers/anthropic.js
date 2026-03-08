/**
 * Anthropic Claude Provider
 *
 * Adapter for Anthropic's Claude models (claude-3-haiku, claude-sonnet-4).
 * Implements the BaseProvider interface with streaming support.
 *
 * @module llm-mesh/gateway/providers/anthropic
 */

'use strict';

const BaseProvider = require('./base-provider');

/**
 * Model pricing per 1000 tokens (USD)
 * @constant
 */
const MODEL_PRICING = {
  'claude-3-haiku-20240307': { input: 0.00025, output: 0.00125 },
  'claude-3-5-haiku-20241022': { input: 0.001, output: 0.005 },
  'claude-sonnet-4-20250514': { input: 0.003, output: 0.015 },
  'claude-3-5-sonnet-20241022': { input: 0.003, output: 0.015 },
  'claude-3-opus-20240229': { input: 0.015, output: 0.075 }
};

/**
 * Model aliases for easier reference
 * @constant
 */
const MODEL_ALIASES = {
  'claude-3-haiku': 'claude-3-haiku-20240307',
  'claude-haiku': 'claude-3-5-haiku-20241022',
  'claude-sonnet-4': 'claude-sonnet-4-20250514',
  'claude-sonnet': 'claude-3-5-sonnet-20241022',
  'claude-opus': 'claude-3-opus-20240229'
};

/**
 * Anthropic Claude provider implementation
 * @extends BaseProvider
 */
class AnthropicProvider extends BaseProvider {
  /**
   * Create an Anthropic provider instance
   * @param {Object} config - Provider configuration
   * @param {string} [config.apiKey] - Anthropic API key (defaults to ANTHROPIC_API_KEY env var)
   * @param {string} [config.defaultModel='claude-3-haiku-20240307'] - Default model to use
   */
  constructor(config = {}) {
    super({
      name: 'anthropic',
      apiKey: config.apiKey || process.env.ANTHROPIC_API_KEY,
      defaultModel: config.defaultModel || 'claude-3-haiku-20240307',
      ...config
    });

    this.client = null;
    this.maxRetries = config.maxRetries || 3;
    this.timeout = config.timeout || 60000;
  }

  /**
   * Initialize the Anthropic SDK
   * @returns {Promise<void>}
   */
  async initialize() {
    if (this.initialized) return;

    if (!this.apiKey) {
      throw new Error('Anthropic API key is required. Set ANTHROPIC_API_KEY environment variable.');
    }

    try {
      const Anthropic = require('@anthropic-ai/sdk');
      this.client = new Anthropic({
        apiKey: this.apiKey,
        maxRetries: this.maxRetries,
        timeout: this.timeout
      });
      this.initialized = true;
      this.log('info', 'Anthropic provider initialized successfully');
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
      // Separate system message from other messages
      const systemMessages = messages.filter(m => m.role === 'system');
      const conversationMessages = messages.filter(m => m.role !== 'system');

      const requestParams = {
        model,
        max_tokens: options.maxTokens || 4096,
        messages: conversationMessages.map(m => ({
          role: m.role,
          content: m.content
        }))
      };

      // Add system prompt if present
      if (systemMessages.length > 0) {
        requestParams.system = systemMessages.map(m => m.content).join('\n\n');
      }

      // Add optional parameters
      if (options.temperature !== undefined) {
        requestParams.temperature = options.temperature;
      }
      if (options.stopSequences) {
        requestParams.stop_sequences = options.stopSequences;
      }
      if (options.metadata) {
        requestParams.metadata = options.metadata;
      }

      this.log('debug', 'Sending completion request', { model, messageCount: messages.length });

      const response = await this.client.messages.create(requestParams);

      const latencyMs = Date.now() - startTime;
      this.recordSuccess(
        response.usage.input_tokens,
        response.usage.output_tokens,
        latencyMs
      );

      this.log('info', 'Completion successful', {
        model,
        inputTokens: response.usage.input_tokens,
        outputTokens: response.usage.output_tokens,
        latencyMs
      });

      return {
        content: response.content[0].text,
        model: response.model,
        usage: {
          inputTokens: response.usage.input_tokens,
          outputTokens: response.usage.output_tokens
        },
        stopReason: response.stop_reason,
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
      // Separate system message from other messages
      const systemMessages = messages.filter(m => m.role === 'system');
      const conversationMessages = messages.filter(m => m.role !== 'system');

      const requestParams = {
        model,
        max_tokens: options.maxTokens || 4096,
        messages: conversationMessages.map(m => ({
          role: m.role,
          content: m.content
        })),
        stream: true
      };

      if (systemMessages.length > 0) {
        requestParams.system = systemMessages.map(m => m.content).join('\n\n');
      }

      if (options.temperature !== undefined) {
        requestParams.temperature = options.temperature;
      }
      if (options.stopSequences) {
        requestParams.stop_sequences = options.stopSequences;
      }

      this.log('debug', 'Starting streaming completion', { model });

      const stream = await this.client.messages.stream(requestParams);

      let totalInputTokens = 0;
      let totalOutputTokens = 0;

      for await (const event of stream) {
        if (event.type === 'content_block_delta' && event.delta.type === 'text_delta') {
          yield event.delta.text;
        } else if (event.type === 'message_delta' && event.usage) {
          totalOutputTokens = event.usage.output_tokens;
        } else if (event.type === 'message_start' && event.message.usage) {
          totalInputTokens = event.message.usage.input_tokens;
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
   * Note: Anthropic doesn't natively support embeddings, this throws an error
   * @param {string} text - Text to embed
   * @returns {Promise<Object>}
   */
  async embed(text) {
    throw new Error('Anthropic does not support embeddings. Use OpenAI or another provider.');
  }

  /**
   * Count tokens in text
   * Uses approximate counting based on character length
   * @param {string} text - Text to count tokens for
   * @returns {Promise<number>} Approximate token count
   */
  async getTokenCount(text) {
    // Claude uses roughly 4 characters per token on average
    // This is an approximation - for exact counts, use the API
    return Math.ceil(text.length / 4);
  }

  /**
   * Get cost per 1000 tokens for a model
   * @param {string} [model] - Model to get cost for
   * @returns {{input: number, output: number}} Cost per 1000 tokens in USD
   */
  getCostPerToken(model) {
    const resolvedModel = this.resolveModel(model || this.defaultModel);
    return MODEL_PRICING[resolvedModel] || MODEL_PRICING['claude-3-haiku-20240307'];
  }

  /**
   * List available Anthropic models
   * @returns {Promise<string[]>} List of model identifiers
   */
  async listModels() {
    return Object.keys(MODEL_PRICING);
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
      provider: 'anthropic',
      pricing,
      contextWindow: 200000, // Claude models support 200K context
      maxOutputTokens: 4096
    };

    // Model-specific adjustments
    if (resolvedModel.includes('opus')) {
      modelInfo.maxOutputTokens = 4096;
      modelInfo.tier = 'premium';
    } else if (resolvedModel.includes('sonnet')) {
      modelInfo.maxOutputTokens = 8192;
      modelInfo.tier = 'standard';
    } else if (resolvedModel.includes('haiku')) {
      modelInfo.maxOutputTokens = 4096;
      modelInfo.tier = 'fast';
    }

    return modelInfo;
  }
}

module.exports = AnthropicProvider;
