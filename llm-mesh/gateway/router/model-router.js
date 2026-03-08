/**
 * Model Router
 *
 * Routes LLM requests to optimal models based on task complexity,
 * cost constraints, and provider availability. Implements fallback
 * chains for resilience.
 *
 * @module llm-mesh/gateway/router/model-router
 */

'use strict';

const path = require('path');

// Import new model selection components
const { selectModel, logSelectionDecision } = require('./model-selector');
const { scoreComplexity } = require('./complexity-scorer');
const { detectSensitivity } = require('./sensitivity-detector');

/**
 * @typedef {Object} RoutingDecision
 * @property {string} provider - Selected provider name
 * @property {string} model - Selected model identifier
 * @property {string} reason - Reason for the selection
 * @property {Array<{provider: string, model: string}>} fallbacks - Fallback options
 */

/**
 * @typedef {Object} RoutingOptions
 * @property {string} [taskType] - Type of task (simple, standard, complex, coding, embedding)
 * @property {number} [maxCost] - Maximum cost per 1k tokens
 * @property {string} [preferredProvider] - Preferred provider
 * @property {string} [preferredModel] - Preferred specific model
 * @property {boolean} [requiresStreaming] - Whether streaming is required
 * @property {boolean} [requiresEmbedding] - Whether embedding is required
 * @property {number} [contextLength] - Expected context length
 * @property {string[]} [capabilities] - Required capabilities
 * @property {Object} [task] - Task object for intelligent selection
 * @property {string} [task.description] - Task description
 * @property {string} [task.type] - Task type
 * @property {string} [task.code] - Associated code
 * @property {number} [maxCostPer1kTokens] - Maximum cost per 1000 tokens
 * @property {boolean} [preferLocal] - Prefer local models for privacy
 */

/**
 * Model router for intelligent request routing
 */
class ModelRouter {
  /**
   * Create a model router instance
   * @param {Object} config - Router configuration
   * @param {Object} config.providers - Provider instances map
   * @param {Object} [config.routingConfig] - Routing configuration
   */
  constructor(config = {}) {
    this.providers = config.providers || {};
    this.routingConfig = config.routingConfig || this.loadDefaultConfig();
    this.routingHistory = [];
    this.maxHistorySize = 1000;
  }

  /**
   * Load default routing configuration
   * @private
   * @returns {Object} Default routing config
   */
  loadDefaultConfig() {
    try {
      return require('../config/providers.json').routing;
    } catch (error) {
      // Fallback configuration
      return {
        defaultProvider: 'anthropic',
        fallbackChain: ['anthropic', 'openai', 'ollama'],
        taskRouting: {
          simple: { preferredModels: ['claude-3-haiku-20240307', 'gpt-3.5-turbo'], maxCostPer1k: 0.001 },
          standard: { preferredModels: ['claude-3-5-sonnet-20241022', 'gpt-4-turbo'], maxCostPer1k: 0.02 },
          complex: { preferredModels: ['claude-3-opus-20240229', 'gpt-4-turbo'], maxCostPer1k: 0.1 },
          coding: { preferredModels: ['claude-sonnet-4-20250514', 'gpt-4-turbo'], maxCostPer1k: 0.05 },
          embedding: { preferredModels: ['text-embedding-3-small', 'nomic-embed-text'], maxCostPer1k: 0.001 }
        }
      };
    }
  }

  /**
   * Route a request to the optimal model
   * @param {RoutingOptions} options - Routing options
   * @returns {Promise<RoutingDecision>} Routing decision
   */
  async route(options = {}) {
    const startTime = Date.now();

    try {
      // If specific model requested, validate and return
      if (options.preferredModel) {
        const decision = await this.routeToSpecificModel(options);
        this.recordRouting(decision, options, Date.now() - startTime);
        return decision;
      }

      // Use intelligent task-based selection if task object is provided
      if (options.task) {
        const decision = await this.routeByTaskAnalysis(options);
        this.recordRouting(decision, options, Date.now() - startTime);
        return decision;
      }

      // Route based on task type
      const taskType = options.taskType || this.inferTaskType(options);
      const decision = await this.routeByTaskType(taskType, options);

      this.recordRouting(decision, options, Date.now() - startTime);
      return decision;
    } catch (error) {
      this.log('error', 'Routing failed', { error: error.message, options });
      throw error;
    }
  }

  /**
   * Route using intelligent task analysis
   * @private
   * @param {RoutingOptions} options - Routing options
   * @returns {Promise<RoutingDecision>}
   */
  async routeByTaskAnalysis(options) {
    const task = options.task;

    // Use the model selector for intelligent routing
    const selectionOptions = {
      maxCostPer1kTokens: options.maxCost || options.maxCostPer1kTokens,
      preferLocal: options.preferLocal,
      preferredProvider: options.preferredProvider,
      excludeModels: options.excludeModels,
      maxResponseTimeMs: options.maxResponseTimeMs
    };

    const selection = selectModel(task, selectionOptions);

    // Log the selection decision for analytics
    logSelectionDecision(selection, task);

    // Check if provider is available
    const providerInstance = this.providers[selection.provider];
    if (providerInstance) {
      const isAvailable = await providerInstance.isAvailable();
      if (!isAvailable) {
        this.log('warn', 'Selected provider unavailable, using fallback', {
          provider: selection.provider,
          model: selection.model
        });
        return this.routeWithFallback(options);
      }
    }

    return {
      provider: selection.provider,
      model: selection.model,
      reason: selection.reasoning,
      fallbacks: this.getFallbacks(selection.provider, selection.model),
      analysis: selection.analysis
    };
  }

  /**
   * Get complexity score for a task
   * @param {Object} task - Task object
   * @returns {Object} Complexity scoring result
   */
  getComplexityScore(task) {
    return scoreComplexity(task);
  }

  /**
   * Get sensitivity detection for a task
   * @param {Object} task - Task object
   * @returns {Object} Sensitivity detection result
   */
  getSensitivityLevel(task) {
    return detectSensitivity(task);
  }

  /**
   * Route to a specific requested model
   * @private
   * @param {RoutingOptions} options - Routing options
   * @returns {Promise<RoutingDecision>}
   */
  async routeToSpecificModel(options) {
    const model = options.preferredModel;
    const provider = options.preferredProvider || this.findProviderForModel(model);

    if (!provider) {
      throw new Error(`No provider found for model: ${model}`);
    }

    // Check if provider is available
    const providerInstance = this.providers[provider];
    if (!providerInstance) {
      throw new Error(`Provider not configured: ${provider}`);
    }

    const isAvailable = await providerInstance.isAvailable();
    if (!isAvailable) {
      // Try fallback
      return this.routeWithFallback(options);
    }

    return {
      provider,
      model,
      reason: 'Specific model requested',
      fallbacks: this.getFallbacks(provider, model)
    };
  }

  /**
   * Route based on task type
   * @private
   * @param {string} taskType - Task type
   * @param {RoutingOptions} options - Routing options
   * @returns {Promise<RoutingDecision>}
   */
  async routeByTaskType(taskType, options) {
    const taskConfig = this.routingConfig.taskRouting[taskType];
    if (!taskConfig) {
      return this.routeToDefault(options);
    }

    // Filter models by cost constraint
    const maxCost = options.maxCost || taskConfig.maxCostPer1k;
    const eligibleModels = taskConfig.preferredModels.filter(model => {
      const provider = this.findProviderForModel(model);
      if (!provider || !this.providers[provider]) return false;

      const pricing = this.providers[provider].getCostPerToken(model);
      const avgCost = (pricing.input + pricing.output) / 2;
      return avgCost <= maxCost;
    });

    if (eligibleModels.length === 0) {
      return this.routeToDefault(options);
    }

    // Try models in order of preference
    for (const model of eligibleModels) {
      const provider = this.findProviderForModel(model);
      const providerInstance = this.providers[provider];

      if (providerInstance && await providerInstance.isAvailable()) {
        // Check capabilities if specified
        if (options.capabilities) {
          const modelInfo = providerInstance.getModelInfo(model);
          if (modelInfo && !this.hasCapabilities(modelInfo, options.capabilities)) {
            continue;
          }
        }

        // Check context length requirement
        if (options.contextLength) {
          const modelInfo = providerInstance.getModelInfo(model);
          if (modelInfo && modelInfo.contextWindow < options.contextLength) {
            continue;
          }
        }

        return {
          provider,
          model,
          reason: `Best match for ${taskType} task`,
          fallbacks: this.getFallbacks(provider, model)
        };
      }
    }

    // All preferred models unavailable, use fallback
    return this.routeWithFallback(options);
  }

  /**
   * Route with fallback chain
   * @private
   * @param {RoutingOptions} options - Routing options
   * @returns {Promise<RoutingDecision>}
   */
  async routeWithFallback(options) {
    const fallbackChain = this.routingConfig.fallbackChain;

    for (const providerName of fallbackChain) {
      const providerInstance = this.providers[providerName];
      if (!providerInstance) continue;

      const isAvailable = await providerInstance.isAvailable();
      if (isAvailable) {
        const model = providerInstance.defaultModel;
        return {
          provider: providerName,
          model,
          reason: 'Fallback selection (primary options unavailable)',
          fallbacks: this.getFallbacks(providerName, model)
        };
      }
    }

    throw new Error('No providers available');
  }

  /**
   * Route to default provider
   * @private
   * @param {RoutingOptions} options - Routing options
   * @returns {Promise<RoutingDecision>}
   */
  async routeToDefault(options) {
    const defaultProvider = this.routingConfig.defaultProvider;
    const providerInstance = this.providers[defaultProvider];

    if (providerInstance && await providerInstance.isAvailable()) {
      const model = providerInstance.defaultModel;
      return {
        provider: defaultProvider,
        model,
        reason: 'Default provider selection',
        fallbacks: this.getFallbacks(defaultProvider, model)
      };
    }

    return this.routeWithFallback(options);
  }

  /**
   * Find which provider has a given model
   * @private
   * @param {string} model - Model identifier
   * @returns {string|null} Provider name or null
   */
  findProviderForModel(model) {
    // Check Anthropic models
    if (model.includes('claude')) {
      return 'anthropic';
    }

    // Check OpenAI models
    if (model.includes('gpt') || model.includes('text-embedding')) {
      return 'openai';
    }

    // Check Ollama models
    if (model.includes('llama') || model.includes('mistral') ||
        model.includes('mixtral') || model.includes('codellama') ||
        model.includes('nomic')) {
      return 'ollama';
    }

    // Try to find by checking providers
    for (const [name, provider] of Object.entries(this.providers)) {
      const modelInfo = provider.getModelInfo(model);
      if (modelInfo) {
        return name;
      }
    }

    return null;
  }

  /**
   * Get fallback options for a selection
   * @private
   * @param {string} currentProvider - Current provider
   * @param {string} currentModel - Current model
   * @returns {Array<{provider: string, model: string}>}
   */
  getFallbacks(currentProvider, currentModel) {
    const fallbacks = [];
    const fallbackChain = this.routingConfig.fallbackChain;

    for (const providerName of fallbackChain) {
      if (providerName === currentProvider) continue;

      const providerInstance = this.providers[providerName];
      if (providerInstance) {
        fallbacks.push({
          provider: providerName,
          model: providerInstance.defaultModel
        });
      }
    }

    return fallbacks;
  }

  /**
   * Infer task type from options
   * @private
   * @param {RoutingOptions} options - Routing options
   * @returns {string} Inferred task type
   */
  inferTaskType(options) {
    if (options.requiresEmbedding) {
      return 'embedding';
    }

    if (options.capabilities) {
      if (options.capabilities.includes('coding')) {
        return 'coding';
      }
      if (options.capabilities.includes('reasoning')) {
        return 'complex';
      }
    }

    // Default to standard
    return 'standard';
  }

  /**
   * Check if model has required capabilities
   * @private
   * @param {Object} modelInfo - Model information
   * @param {string[]} requiredCapabilities - Required capabilities
   * @returns {boolean}
   */
  hasCapabilities(modelInfo, requiredCapabilities) {
    if (!modelInfo.capabilities) return false;
    return requiredCapabilities.every(cap => modelInfo.capabilities.includes(cap));
  }

  /**
   * Record routing decision for analytics
   * @private
   * @param {RoutingDecision} decision - Routing decision
   * @param {RoutingOptions} options - Original options
   * @param {number} latencyMs - Routing latency
   */
  recordRouting(decision, options, latencyMs) {
    const record = {
      timestamp: new Date().toISOString(),
      decision,
      options,
      latencyMs
    };

    this.routingHistory.push(record);

    // Trim history if too large
    if (this.routingHistory.length > this.maxHistorySize) {
      this.routingHistory = this.routingHistory.slice(-this.maxHistorySize / 2);
    }

    this.log('debug', 'Routing decision made', record);
  }

  /**
   * Get routing statistics
   * @returns {Object} Routing statistics
   */
  getStats() {
    if (this.routingHistory.length === 0) {
      return {
        totalRoutings: 0,
        providerDistribution: {},
        avgLatencyMs: 0,
        fallbackRate: 0
      };
    }

    const providerCounts = {};
    let totalLatency = 0;
    let fallbackCount = 0;

    for (const record of this.routingHistory) {
      const provider = record.decision.provider;
      providerCounts[provider] = (providerCounts[provider] || 0) + 1;
      totalLatency += record.latencyMs;
      if (record.decision.reason.includes('Fallback')) {
        fallbackCount++;
      }
    }

    return {
      totalRoutings: this.routingHistory.length,
      providerDistribution: providerCounts,
      avgLatencyMs: Math.round(totalLatency / this.routingHistory.length),
      fallbackRate: (fallbackCount / this.routingHistory.length * 100).toFixed(2) + '%'
    };
  }

  /**
   * Clear routing history
   */
  clearHistory() {
    this.routingHistory = [];
  }

  /**
   * Update routing configuration
   * @param {Object} newConfig - New routing configuration
   */
  updateConfig(newConfig) {
    this.routingConfig = { ...this.routingConfig, ...newConfig };
    this.log('info', 'Routing configuration updated');
  }

  /**
   * Log router activity
   * @private
   * @param {string} level - Log level
   * @param {string} message - Log message
   * @param {Object} [data] - Additional data
   */
  log(level, message, data = {}) {
    const logEntry = {
      timestamp: new Date().toISOString(),
      component: 'ModelRouter',
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
}

module.exports = ModelRouter;
