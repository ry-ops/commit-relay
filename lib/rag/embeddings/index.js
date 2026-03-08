#!/usr/bin/env node
// lib/rag/embeddings/index.js
// Embeddings Factory and Provider Registry
// Part of RAG Enhancement: Real Embeddings Integration

const fs = require('fs').promises;
const path = require('path');

// Import all embedders
const BaseEmbedder = require('./base-embedder');
const OpenAIEmbedder = require('./openai-embedder');
const OllamaEmbedder = require('./ollama-embedder');
const MockEmbedder = require('./mock-embedder');

// Provider registry
const providers = {
  openai: OpenAIEmbedder,
  ollama: OllamaEmbedder,
  mock: MockEmbedder
};

/**
 * Create embedder based on configuration
 *
 * @param {Object|string} config - Configuration object or provider name
 * @returns {BaseEmbedder} - Configured embedder instance
 *
 * @example
 * // Using provider name
 * const embedder = createEmbedder('openai');
 *
 * @example
 * // Using configuration object
 * const embedder = createEmbedder({
 *   provider: 'openai',
 *   model: 'text-embedding-3-large',
 *   apiKey: 'sk-...'
 * });
 *
 * @example
 * // Auto-detect from environment
 * const embedder = createEmbedder(); // Uses EMBEDDER_PROVIDER or defaults
 */
function createEmbedder(config = {}) {
  // Handle string shorthand
  if (typeof config === 'string') {
    config = { provider: config };
  }

  // Auto-detect provider from environment
  const provider = config.provider ||
    process.env.EMBEDDER_PROVIDER ||
    autoDetectProvider();

  // Validate provider
  if (!providers[provider]) {
    const available = Object.keys(providers).join(', ');
    throw new Error(`Unknown embedder provider: ${provider}. Available: ${available}`);
  }

  // Create instance
  const EmbedderClass = providers[provider];
  return new EmbedderClass(config);
}

/**
 * Auto-detect best available provider
 * Priority: OpenAI (if key set) > Ollama (if running) > Mock
 */
function autoDetectProvider() {
  // Check for OpenAI API key
  if (process.env.OPENAI_API_KEY) {
    return 'openai';
  }

  // Check for Ollama host configuration
  if (process.env.OLLAMA_HOST) {
    return 'ollama';
  }

  // Default to mock for safety
  return 'mock';
}

/**
 * Create embedder from configuration file
 *
 * @param {string} configPath - Path to configuration JSON file
 * @returns {Promise<BaseEmbedder>} - Configured embedder instance
 */
async function createEmbedderFromConfig(configPath) {
  const defaultConfigPath = path.join(process.cwd(), 'config', 'embeddings.json');
  const actualPath = configPath || defaultConfigPath;

  try {
    const configContent = await fs.readFile(actualPath, 'utf8');
    const config = JSON.parse(configContent);

    // Get active provider config
    const activeProvider = config.active_provider || autoDetectProvider();
    const providerConfig = config.providers?.[activeProvider] || {};

    return createEmbedder({
      provider: activeProvider,
      ...providerConfig,
      ...config.global_settings
    });
  } catch (error) {
    if (error.code === 'ENOENT') {
      console.warn(`Config file not found: ${actualPath}. Using auto-detection.`);
      return createEmbedder();
    }
    throw error;
  }
}

/**
 * Get list of available providers
 */
function getAvailableProviders() {
  return Object.keys(providers);
}

/**
 * Register a custom provider
 *
 * @param {string} name - Provider name
 * @param {Class} EmbedderClass - Class extending BaseEmbedder
 */
function registerProvider(name, EmbedderClass) {
  if (!(EmbedderClass.prototype instanceof BaseEmbedder)) {
    throw new Error('Provider must extend BaseEmbedder');
  }
  providers[name] = EmbedderClass;
}

/**
 * Check if a provider is available and functional
 *
 * @param {string} provider - Provider name
 * @returns {Promise<Object>} - Availability status
 */
async function checkProviderAvailability(provider) {
  const result = {
    provider,
    available: false,
    reason: null
  };

  switch (provider) {
    case 'openai':
      if (process.env.OPENAI_API_KEY) {
        result.available = true;
      } else {
        result.reason = 'OPENAI_API_KEY environment variable not set';
      }
      break;

    case 'ollama':
      try {
        const embedder = new OllamaEmbedder();
        result.available = await embedder.isAvailable();
        if (!result.available) {
          result.reason = 'Ollama server not running';
        }
      } catch (error) {
        result.reason = error.message;
      }
      break;

    case 'mock':
      result.available = true;
      break;

    default:
      result.reason = `Unknown provider: ${provider}`;
  }

  return result;
}

/**
 * Get status of all providers
 *
 * @returns {Promise<Object[]>} - Status of all providers
 */
async function getAllProviderStatus() {
  const statuses = [];

  for (const provider of Object.keys(providers)) {
    const status = await checkProviderAvailability(provider);
    statuses.push(status);
  }

  return statuses;
}

// CLI interface
if (require.main === module) {
  const action = process.argv[2];

  (async () => {
    switch (action) {
      case 'list':
        console.log('Available providers:');
        for (const provider of getAvailableProviders()) {
          console.log(`  - ${provider}`);
        }
        break;

      case 'status':
        console.log('Provider availability:');
        const statuses = await getAllProviderStatus();
        for (const status of statuses) {
          const icon = status.available ? '✓' : '✗';
          console.log(`  ${icon} ${status.provider}${status.reason ? ` (${status.reason})` : ''}`);
        }
        break;

      case 'test':
        const provider = process.argv[3] || autoDetectProvider();
        console.log(`Testing provider: ${provider}`);

        try {
          const embedder = createEmbedder(provider);
          console.log(`  Model: ${embedder.getModel()}`);
          console.log(`  Dimensions: ${embedder.getDimensions()}`);

          const testText = 'This is a test embedding for the commit-relay RAG system.';
          console.log(`  Generating embedding for: "${testText.substring(0, 50)}..."`);

          const embedding = await embedder.embed(testText);
          console.log(`  Result: ${embedding.length} dimensions`);
          console.log(`  First 5 values: [${embedding.slice(0, 5).map(v => v.toFixed(4)).join(', ')}]`);
          console.log('  Test passed!');
        } catch (error) {
          console.error(`  Test failed: ${error.message}`);
          process.exit(1);
        }
        break;

      default:
        console.log('Usage: node index.js <action>');
        console.log('Actions:');
        console.log('  list              - List available providers');
        console.log('  status            - Check provider availability');
        console.log('  test [provider]   - Test a provider');
        break;
    }
  })();
}

// Exports
module.exports = {
  createEmbedder,
  createEmbedderFromConfig,
  getAvailableProviders,
  registerProvider,
  checkProviderAvailability,
  getAllProviderStatus,
  autoDetectProvider,

  // Export classes for direct use
  BaseEmbedder,
  OpenAIEmbedder,
  OllamaEmbedder,
  MockEmbedder
};
