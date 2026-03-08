/**
 * Ollama Local Provider
 *
 * Adapter for local Ollama models (llama3, codellama).
 * Uses HTTP calls to the Ollama API running on localhost.
 *
 * @module llm-mesh/gateway/providers/ollama
 */

'use strict';

const BaseProvider = require('./base-provider');

/**
 * Default Ollama models and their configurations
 * @constant
 */
const MODEL_CONFIGS = {
  'llama3': {
    contextWindow: 8192,
    maxOutputTokens: 4096
  },
  'llama3:8b': {
    contextWindow: 8192,
    maxOutputTokens: 4096
  },
  'llama3:70b': {
    contextWindow: 8192,
    maxOutputTokens: 4096
  },
  'codellama': {
    contextWindow: 16384,
    maxOutputTokens: 4096
  },
  'codellama:7b': {
    contextWindow: 16384,
    maxOutputTokens: 4096
  },
  'codellama:13b': {
    contextWindow: 16384,
    maxOutputTokens: 4096
  },
  'codellama:34b': {
    contextWindow: 16384,
    maxOutputTokens: 4096
  },
  'mistral': {
    contextWindow: 8192,
    maxOutputTokens: 4096
  },
  'mixtral': {
    contextWindow: 32768,
    maxOutputTokens: 4096
  },
  'phi3': {
    contextWindow: 4096,
    maxOutputTokens: 4096
  },
  'nomic-embed-text': {
    contextWindow: 8192,
    maxOutputTokens: 0,
    dimensions: 768
  }
};

/**
 * Ollama local provider implementation
 * @extends BaseProvider
 */
class OllamaProvider extends BaseProvider {
  /**
   * Create an Ollama provider instance
   * @param {Object} config - Provider configuration
   * @param {string} [config.baseUrl='http://localhost:11434'] - Ollama API base URL
   * @param {string} [config.defaultModel='llama3'] - Default model to use
   * @param {string} [config.embeddingModel='nomic-embed-text'] - Default embedding model
   */
  constructor(config = {}) {
    super({
      name: 'ollama',
      baseUrl: config.baseUrl || process.env.OLLAMA_HOST || 'http://localhost:11434',
      defaultModel: config.defaultModel || 'llama3',
      ...config
    });

    this.embeddingModel = config.embeddingModel || 'nomic-embed-text';
    this.timeout = config.timeout || 120000; // Longer timeout for local inference
  }

  /**
   * Initialize the Ollama provider
   * Checks if Ollama is running and accessible
   * @returns {Promise<void>}
   */
  async initialize() {
    if (this.initialized) return;

    try {
      const response = await this.fetchWithTimeout(`${this.baseUrl}/api/tags`, {
        method: 'GET'
      });

      if (!response.ok) {
        throw new Error(`Ollama API returned status ${response.status}`);
      }

      this.initialized = true;
      this.log('info', 'Ollama provider initialized successfully', { baseUrl: this.baseUrl });
    } catch (error) {
      if (error.code === 'ECONNREFUSED') {
        throw new Error(`Ollama is not running at ${this.baseUrl}. Start Ollama with 'ollama serve'.`);
      }
      throw this.formatError(error, 'initialization');
    }
  }

  /**
   * Fetch with timeout support
   * @private
   * @param {string} url - URL to fetch
   * @param {Object} options - Fetch options
   * @returns {Promise<Response>}
   */
  async fetchWithTimeout(url, options = {}) {
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), this.timeout);

    try {
      const response = await fetch(url, {
        ...options,
        signal: controller.signal
      });
      return response;
    } finally {
      clearTimeout(timeoutId);
    }
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
    const model = options.model || this.defaultModel;

    try {
      const requestBody = {
        model,
        messages: messages.map(m => ({
          role: m.role,
          content: m.content
        })),
        stream: false,
        options: {}
      };

      // Add optional parameters
      if (options.maxTokens) {
        requestBody.options.num_predict = options.maxTokens;
      }
      if (options.temperature !== undefined) {
        requestBody.options.temperature = options.temperature;
      }
      if (options.stopSequences) {
        requestBody.options.stop = options.stopSequences;
      }

      this.log('debug', 'Sending completion request to Ollama', { model, messageCount: messages.length });

      const response = await this.fetchWithTimeout(`${this.baseUrl}/api/chat`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(requestBody)
      });

      if (!response.ok) {
        const errorText = await response.text();
        throw new Error(`Ollama API error: ${response.status} - ${errorText}`);
      }

      const data = await response.json();
      const latencyMs = Date.now() - startTime;

      // Ollama provides token counts in eval_count and prompt_eval_count
      const inputTokens = data.prompt_eval_count || 0;
      const outputTokens = data.eval_count || 0;

      this.recordSuccess(inputTokens, outputTokens, latencyMs);

      this.log('info', 'Completion successful', {
        model,
        inputTokens,
        outputTokens,
        latencyMs
      });

      return {
        content: data.message.content,
        model: data.model,
        usage: {
          inputTokens,
          outputTokens
        },
        stopReason: data.done_reason || 'stop',
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
    const model = options.model || this.defaultModel;

    try {
      const requestBody = {
        model,
        messages: messages.map(m => ({
          role: m.role,
          content: m.content
        })),
        stream: true,
        options: {}
      };

      if (options.maxTokens) {
        requestBody.options.num_predict = options.maxTokens;
      }
      if (options.temperature !== undefined) {
        requestBody.options.temperature = options.temperature;
      }

      this.log('debug', 'Starting streaming completion from Ollama', { model });

      const response = await this.fetchWithTimeout(`${this.baseUrl}/api/chat`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(requestBody)
      });

      if (!response.ok) {
        const errorText = await response.text();
        throw new Error(`Ollama API error: ${response.status} - ${errorText}`);
      }

      const reader = response.body.getReader();
      const decoder = new TextDecoder();
      let totalInputTokens = 0;
      let totalOutputTokens = 0;

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;

        const chunk = decoder.decode(value);
        const lines = chunk.split('\n').filter(line => line.trim());

        for (const line of lines) {
          try {
            const data = JSON.parse(line);
            if (data.message?.content) {
              yield data.message.content;
            }
            if (data.prompt_eval_count) {
              totalInputTokens = data.prompt_eval_count;
            }
            if (data.eval_count) {
              totalOutputTokens = data.eval_count;
            }
          } catch {
            // Skip malformed JSON lines
          }
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
   * @returns {Promise<Object>} Embedding response
   */
  async embed(text, options = {}) {
    if (!this.initialized) await this.initialize();

    const startTime = Date.now();
    const model = options.model || this.embeddingModel;

    try {
      this.log('debug', 'Generating embedding with Ollama', { model, textLength: text.length });

      const response = await this.fetchWithTimeout(`${this.baseUrl}/api/embeddings`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          model,
          prompt: text
        })
      });

      if (!response.ok) {
        const errorText = await response.text();
        throw new Error(`Ollama API error: ${response.status} - ${errorText}`);
      }

      const data = await response.json();
      const latencyMs = Date.now() - startTime;

      // Estimate input tokens based on text length
      const estimatedTokens = Math.ceil(text.length / 4);
      this.recordSuccess(estimatedTokens, 0, latencyMs);

      this.log('info', 'Embedding generated successfully', {
        model,
        dimensions: data.embedding.length,
        latencyMs
      });

      return {
        embedding: data.embedding,
        model,
        dimensions: data.embedding.length,
        provider: this.name
      };
    } catch (error) {
      this.recordFailure();
      this.log('error', 'Embedding failed', { error: error.message, model });
      throw this.formatError(error, 'embedding');
    }
  }

  /**
   * Count tokens in text
   * Uses approximation for local models
   * @param {string} text - Text to count tokens for
   * @returns {Promise<number>} Approximate token count
   */
  async getTokenCount(text) {
    // Ollama doesn't have a direct token counting API
    // Use approximation based on character count
    return Math.ceil(text.length / 4);
  }

  /**
   * Get cost per 1000 tokens for a model
   * Local models have no API cost
   * @param {string} [model] - Model to get cost for
   * @returns {{input: number, output: number}} Cost per 1000 tokens in USD (always 0 for local)
   */
  getCostPerToken(model) {
    // Local inference has no API cost
    return { input: 0, output: 0 };
  }

  /**
   * List available Ollama models
   * @returns {Promise<string[]>} List of installed model names
   */
  async listModels() {
    if (!this.initialized) await this.initialize();

    try {
      const response = await this.fetchWithTimeout(`${this.baseUrl}/api/tags`, {
        method: 'GET'
      });

      if (!response.ok) {
        throw new Error(`Failed to list models: ${response.status}`);
      }

      const data = await response.json();
      return data.models.map(m => m.name);
    } catch (error) {
      this.log('error', 'Failed to list models', { error: error.message });
      throw this.formatError(error, 'list models');
    }
  }

  /**
   * Pull a model from Ollama registry
   * @param {string} model - Model name to pull
   * @returns {Promise<void>}
   */
  async pullModel(model) {
    if (!this.initialized) await this.initialize();

    try {
      this.log('info', 'Pulling model from Ollama registry', { model });

      const response = await fetch(`${this.baseUrl}/api/pull`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name: model })
      });

      if (!response.ok) {
        const errorText = await response.text();
        throw new Error(`Failed to pull model: ${errorText}`);
      }

      // Stream the progress
      const reader = response.body.getReader();
      const decoder = new TextDecoder();

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;

        const chunk = decoder.decode(value);
        const lines = chunk.split('\n').filter(line => line.trim());

        for (const line of lines) {
          try {
            const data = JSON.parse(line);
            if (data.status) {
              this.log('debug', 'Pull progress', { model, status: data.status });
            }
          } catch {
            // Skip malformed JSON
          }
        }
      }

      this.log('info', 'Model pulled successfully', { model });
    } catch (error) {
      this.log('error', 'Failed to pull model', { error: error.message, model });
      throw this.formatError(error, 'pull model');
    }
  }

  /**
   * Get information about a specific model
   * @param {string} model - Model identifier
   * @returns {Object|null} Model information
   */
  getModelInfo(model) {
    const config = MODEL_CONFIGS[model];

    if (!config) {
      // Return generic config for unknown models
      return {
        id: model,
        provider: 'ollama',
        pricing: { input: 0, output: 0 },
        contextWindow: 4096,
        maxOutputTokens: 4096,
        tier: 'local'
      };
    }

    return {
      id: model,
      provider: 'ollama',
      pricing: { input: 0, output: 0 },
      ...config,
      tier: 'local'
    };
  }

  /**
   * Check if a specific model is installed
   * @param {string} model - Model name to check
   * @returns {Promise<boolean>}
   */
  async isModelInstalled(model) {
    try {
      const models = await this.listModels();
      return models.some(m => m === model || m.startsWith(`${model}:`));
    } catch {
      return false;
    }
  }
}

module.exports = OllamaProvider;
