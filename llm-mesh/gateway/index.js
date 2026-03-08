/**
 * LLM Gateway
 *
 * Unified gateway for multi-provider LLM access. Provides a consistent
 * API across Anthropic, OpenAI, and Ollama with intelligent routing,
 * middleware support, and fallback capabilities.
 *
 * @module llm-mesh/gateway
 */

'use strict';

const AnthropicProvider = require('./providers/anthropic');
const OpenAIProvider = require('./providers/openai');
const OllamaProvider = require('./providers/ollama');
const ModelRouter = require('./router/model-router');
const { circuitBreakerManager, createProviderBreaker } = require('./middleware/circuit-breaker');
const { FailoverChain } = require('./middleware/failover');
const { healthCheckManager } = require('./middleware/health-check');

/**
 * @typedef {Object} GatewayConfig
 * @property {Object} [providers] - Provider-specific configurations
 * @property {Object} [providers.anthropic] - Anthropic configuration
 * @property {Object} [providers.openai] - OpenAI configuration
 * @property {Object} [providers.ollama] - Ollama configuration
 * @property {Array<Function>} [middleware] - Middleware functions
 * @property {Object} [routing] - Routing configuration
 * @property {Object} [defaults] - Default options for requests
 */

/**
 * @typedef {Object} CompletionRequest
 * @property {Array<{role: string, content: string}>} messages - Conversation messages
 * @property {Object} [options] - Completion options
 * @property {string} [options.model] - Specific model to use
 * @property {string} [options.provider] - Specific provider to use
 * @property {string} [options.taskType] - Task type for routing (simple, standard, complex, coding)
 * @property {number} [options.maxTokens] - Maximum tokens to generate
 * @property {number} [options.temperature] - Sampling temperature
 * @property {boolean} [options.stream] - Enable streaming
 */

/**
 * LLM Gateway class
 */
class LLMGateway {
  /**
   * Create a new LLM Gateway instance
   * @param {GatewayConfig} config - Gateway configuration
   */
  constructor(config = {}) {
    this.config = config;
    this.providers = {};
    this.middleware = config.middleware || [];
    this.router = null;
    this.failoverChain = null;
    this.initialized = false;

    // Circuit breaker configuration
    this.circuitBreakerEnabled = config.circuitBreaker?.enabled !== false;
    this.healthCheckEnabled = config.healthCheck?.enabled !== false;

    // Metrics
    this.metrics = {
      totalRequests: 0,
      successfulRequests: 0,
      failedRequests: 0,
      totalCost: 0,
      requestsByProvider: {}
    };
  }

  /**
   * Initialize the gateway and all providers
   * @returns {Promise<void>}
   */
  async initialize() {
    if (this.initialized) return;

    this.log('info', 'Initializing LLM Gateway');

    // Initialize providers
    const providerConfigs = this.config.providers || {};

    // Anthropic
    if (providerConfigs.anthropic?.enabled !== false) {
      try {
        this.providers.anthropic = new AnthropicProvider(providerConfigs.anthropic || {});
        await this.providers.anthropic.initialize();
        this.log('info', 'Anthropic provider initialized');
      } catch (error) {
        this.log('warn', 'Anthropic provider initialization failed', { error: error.message });
      }
    }

    // OpenAI
    if (providerConfigs.openai?.enabled !== false) {
      try {
        this.providers.openai = new OpenAIProvider(providerConfigs.openai || {});
        await this.providers.openai.initialize();
        this.log('info', 'OpenAI provider initialized');
      } catch (error) {
        this.log('warn', 'OpenAI provider initialization failed', { error: error.message });
      }
    }

    // Ollama
    if (providerConfigs.ollama?.enabled !== false) {
      try {
        this.providers.ollama = new OllamaProvider(providerConfigs.ollama || {});
        await this.providers.ollama.initialize();
        this.log('info', 'Ollama provider initialized');
      } catch (error) {
        this.log('warn', 'Ollama provider initialization failed', { error: error.message });
      }
    }

    if (Object.keys(this.providers).length === 0) {
      throw new Error('No LLM providers could be initialized');
    }

    // Initialize router
    this.router = new ModelRouter({
      providers: this.providers,
      routingConfig: this.config.routing
    });

    // Initialize circuit breakers for each provider
    if (this.circuitBreakerEnabled) {
      for (const [name, provider] of Object.entries(this.providers)) {
        const breakerOptions = this.config.circuitBreaker?.providers?.[name] || {};
        createProviderBreaker(
          name,
          provider.complete.bind(provider),
          breakerOptions
        );
        this.log('info', `Circuit breaker initialized for ${name}`);
      }
    }

    // Initialize failover chain
    const providerPriority = this.config.failover?.priority ||
      Object.keys(this.providers);

    this.failoverChain = new FailoverChain({
      providers: this.providers,
      priority: providerPriority,
      maxRetries: this.config.failover?.maxRetries || 1,
      retryDelay: this.config.failover?.retryDelay || 1000
    });

    // Register providers with health check manager
    if (this.healthCheckEnabled) {
      for (const [name, provider] of Object.entries(this.providers)) {
        const healthCheckOptions = this.config.healthCheck?.providers?.[name] || {};
        healthCheckManager.registerProvider(name, provider, healthCheckOptions);
      }
      // Start health monitoring
      healthCheckManager.start();
      this.log('info', 'Health monitoring started');
    }

    this.initialized = true;
    this.log('info', 'LLM Gateway initialized successfully', {
      providers: Object.keys(this.providers),
      circuitBreakerEnabled: this.circuitBreakerEnabled,
      healthCheckEnabled: this.healthCheckEnabled
    });
  }

  /**
   * Generate a completion
   * @param {Array<{role: string, content: string}>} messages - Conversation messages
   * @param {Object} [options] - Completion options
   * @returns {Promise<Object>} Completion response
   */
  async complete(messages, options = {}) {
    if (!this.initialized) await this.initialize();

    const startTime = Date.now();
    this.metrics.totalRequests++;

    // Apply middleware
    let processedRequest = { messages, options };
    for (const mw of this.middleware) {
      if (mw.before) {
        processedRequest = await mw.before(processedRequest);
      }
    }

    try {
      // Route request
      const routingOptions = {
        taskType: options.taskType,
        maxCost: options.maxCost,
        preferredProvider: options.provider,
        preferredModel: options.model,
        requiresStreaming: options.stream,
        contextLength: this.estimateContextLength(messages),
        capabilities: options.capabilities
      };

      const routingDecision = await this.router.route(routingOptions);

      this.log('debug', 'Request routed', routingDecision);

      let response;

      // Use failover chain if circuit breakers are enabled
      if (this.circuitBreakerEnabled && this.failoverChain) {
        // Execute through failover chain with circuit breaker protection
        response = await this.failoverChain.execute(
          processedRequest.messages,
          {
            ...processedRequest.options,
            model: routingDecision.model,
            provider: routingDecision.provider
          }
        );
      } else {
        // Original fallback logic without circuit breakers
        let lastError;
        const attempts = [routingDecision, ...routingDecision.fallbacks];

        for (const attempt of attempts) {
          const attemptProvider = this.providers[attempt.provider];
          if (!attemptProvider) continue;

          try {
            response = await attemptProvider.complete(
              processedRequest.messages,
              { ...processedRequest.options, model: attempt.model }
            );
            break;
          } catch (error) {
            lastError = error;
            this.log('warn', 'Provider failed, trying fallback', {
              provider: attempt.provider,
              error: error.message
            });
          }
        }

        if (!response) {
          throw lastError || new Error('All providers failed');
        }
      }

      // Get the actual provider used for cost calculation
      const actualProvider = response.provider || routingDecision.provider;
      const provider = this.providers[actualProvider];

      // Calculate cost
      const pricing = provider.getCostPerToken(response.model);
      const cost = (response.usage.inputTokens * pricing.input / 1000) +
                   (response.usage.outputTokens * pricing.output / 1000);

      response.cost = cost;
      response.routingDecision = routingDecision;

      // Update metrics
      this.metrics.successfulRequests++;
      this.metrics.totalCost += cost;
      this.metrics.requestsByProvider[routingDecision.provider] =
        (this.metrics.requestsByProvider[routingDecision.provider] || 0) + 1;

      // Apply post-middleware
      for (const mw of this.middleware) {
        if (mw.after) {
          response = await mw.after(response);
        }
      }

      const latencyMs = Date.now() - startTime;
      this.log('info', 'Completion successful', {
        provider: response.provider,
        model: response.model,
        cost: cost.toFixed(6),
        latencyMs
      });

      return response;
    } catch (error) {
      this.metrics.failedRequests++;
      this.log('error', 'Completion failed', { error: error.message });
      throw error;
    }
  }

  /**
   * Generate a streaming completion
   * @param {Array<{role: string, content: string}>} messages - Conversation messages
   * @param {Object} [options] - Completion options
   * @yields {string} Text chunks
   */
  async *completeStream(messages, options = {}) {
    if (!this.initialized) await this.initialize();

    this.metrics.totalRequests++;

    try {
      // Route request
      const routingOptions = {
        taskType: options.taskType,
        maxCost: options.maxCost,
        preferredProvider: options.provider,
        preferredModel: options.model,
        requiresStreaming: true,
        contextLength: this.estimateContextLength(messages),
        capabilities: options.capabilities
      };

      const routingDecision = await this.router.route(routingOptions);
      const provider = this.providers[routingDecision.provider];

      this.log('debug', 'Streaming request routed', routingDecision);

      // Stream from provider
      yield* provider.completeStream(messages, {
        ...options,
        model: routingDecision.model
      });

      this.metrics.successfulRequests++;
      this.metrics.requestsByProvider[routingDecision.provider] =
        (this.metrics.requestsByProvider[routingDecision.provider] || 0) + 1;

    } catch (error) {
      this.metrics.failedRequests++;
      this.log('error', 'Streaming completion failed', { error: error.message });
      throw error;
    }
  }

  /**
   * Generate embeddings
   * @param {string} text - Text to embed
   * @param {Object} [options] - Embedding options
   * @returns {Promise<Object>} Embedding response
   */
  async embed(text, options = {}) {
    if (!this.initialized) await this.initialize();

    this.metrics.totalRequests++;

    try {
      // Route to embedding provider
      const routingOptions = {
        taskType: 'embedding',
        requiresEmbedding: true,
        preferredProvider: options.provider,
        preferredModel: options.model
      };

      const routingDecision = await this.router.route(routingOptions);

      // Find a provider that supports embeddings
      let provider = this.providers[routingDecision.provider];
      let model = routingDecision.model;

      // Anthropic doesn't support embeddings, fall back to OpenAI or Ollama
      if (routingDecision.provider === 'anthropic') {
        if (this.providers.openai) {
          provider = this.providers.openai;
          model = 'text-embedding-3-small';
        } else if (this.providers.ollama) {
          provider = this.providers.ollama;
          model = 'nomic-embed-text';
        } else {
          throw new Error('No embedding provider available');
        }
      }

      const response = await provider.embed(text, { ...options, model });

      this.metrics.successfulRequests++;
      this.log('info', 'Embedding generated', {
        provider: response.provider,
        dimensions: response.dimensions
      });

      return response;
    } catch (error) {
      this.metrics.failedRequests++;
      this.log('error', 'Embedding failed', { error: error.message });
      throw error;
    }
  }

  /**
   * Add middleware to the gateway
   * @param {Object} middleware - Middleware object with before/after functions
   */
  use(middleware) {
    this.middleware.push(middleware);
  }

  /**
   * Get a specific provider instance
   * @param {string} name - Provider name
   * @returns {Object|null} Provider instance
   */
  getProvider(name) {
    return this.providers[name] || null;
  }

  /**
   * List available providers
   * @returns {string[]} Provider names
   */
  listProviders() {
    return Object.keys(this.providers);
  }

  /**
   * List all available models
   * @returns {Promise<Object>} Models by provider
   */
  async listModels() {
    const models = {};

    for (const [name, provider] of Object.entries(this.providers)) {
      try {
        models[name] = await provider.listModels();
      } catch (error) {
        models[name] = [];
      }
    }

    return models;
  }

  /**
   * Get gateway metrics
   * @returns {Object} Gateway metrics
   */
  getMetrics() {
    const providerMetrics = {};

    for (const [name, provider] of Object.entries(this.providers)) {
      providerMetrics[name] = provider.getMetrics();
    }

    return {
      gateway: {
        ...this.metrics,
        successRate: this.metrics.totalRequests > 0
          ? (this.metrics.successfulRequests / this.metrics.totalRequests * 100).toFixed(2) + '%'
          : 'N/A',
        avgCostPerRequest: this.metrics.successfulRequests > 0
          ? (this.metrics.totalCost / this.metrics.successfulRequests).toFixed(6)
          : 0
      },
      providers: providerMetrics,
      routing: this.router ? this.router.getStats() : {}
    };
  }

  /**
   * Estimate context length from messages
   * @private
   * @param {Array<{role: string, content: string}>} messages - Messages
   * @returns {number} Estimated token count
   */
  estimateContextLength(messages) {
    let totalChars = 0;
    for (const msg of messages) {
      totalChars += msg.content.length;
    }
    // Approximate 4 chars per token
    return Math.ceil(totalChars / 4);
  }

  /**
   * Log gateway activity
   * @private
   * @param {string} level - Log level
   * @param {string} message - Log message
   * @param {Object} [data] - Additional data
   */
  log(level, message, data = {}) {
    const logEntry = {
      timestamp: new Date().toISOString(),
      component: 'LLMGateway',
      level,
      message,
      ...data
    };

    if (level === 'error') {
      console.error(JSON.stringify(logEntry));
    } else if (level === 'warn') {
      console.warn(JSON.stringify(logEntry));
    } else if (process.env.DEBUG || level === 'info') {
      console.log(JSON.stringify(logEntry));
    }
  }

  /**
   * Shutdown the gateway
   */
  async shutdown() {
    this.log('info', 'Shutting down LLM Gateway');

    // Stop health monitoring
    if (this.healthCheckEnabled) {
      healthCheckManager.stop();
    }

    // Shutdown circuit breakers
    if (this.circuitBreakerEnabled) {
      circuitBreakerManager.shutdown();
    }

    this.initialized = false;
    this.providers = {};
    this.router = null;
    this.failoverChain = null;
  }

  /**
   * Get circuit breaker states for all providers
   * @returns {Object}
   */
  getCircuitStates() {
    if (!this.circuitBreakerEnabled) {
      return { enabled: false };
    }
    return circuitBreakerManager.getAllStates();
  }

  /**
   * Get health check status for all providers
   * @returns {Object}
   */
  getHealthStatus() {
    if (!this.healthCheckEnabled) {
      return { enabled: false };
    }
    return healthCheckManager.getAllStatus();
  }

  /**
   * Get failover chain metrics
   * @returns {Object}
   */
  getFailoverMetrics() {
    if (!this.failoverChain) {
      return { enabled: false };
    }
    return this.failoverChain.getMetrics();
  }
}

/**
 * Create a configured LLM Gateway instance
 * @param {GatewayConfig} config - Gateway configuration
 * @returns {LLMGateway} Gateway instance
 */
function createGateway(config = {}) {
  return new LLMGateway(config);
}

// Export classes and factory
module.exports = {
  createGateway,
  LLMGateway,
  AnthropicProvider,
  OpenAIProvider,
  OllamaProvider,
  ModelRouter,
  // Circuit breaker components
  circuitBreakerManager,
  createProviderBreaker,
  FailoverChain,
  healthCheckManager
};
