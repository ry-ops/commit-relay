#!/usr/bin/env node
// lib/rag/stores/index.js
// Vector Store Factory and Provider Registry
// Part of Production Vector Store Integration

const fs = require('fs').promises;
const path = require('path');

// Import all store adapters
const BaseStore = require('./base-store');
const WeaviateStore = require('./weaviate-store');
const QdrantStore = require('./qdrant-store');
const FileStore = require('./file-store');

// Provider registry
const providers = {
  weaviate: WeaviateStore,
  qdrant: QdrantStore,
  file: FileStore
};

/**
 * Create vector store based on configuration
 *
 * @param {Object|string} config - Configuration object or provider name
 * @returns {BaseStore} - Configured store instance
 *
 * @example
 * // Using provider name
 * const store = createStore('qdrant');
 *
 * @example
 * // Using configuration object
 * const store = createStore({
 *   provider: 'weaviate',
 *   host: 'localhost',
 *   port: 8080
 * });
 *
 * @example
 * // Auto-detect from environment
 * const store = createStore(); // Uses VECTOR_STORE_PROVIDER or defaults to file
 */
function createStore(config = {}) {
  // Handle string shorthand
  if (typeof config === 'string') {
    config = { provider: config };
  }

  // Auto-detect provider from environment
  const provider = config.provider ||
    process.env.VECTOR_STORE_PROVIDER ||
    autoDetectProvider();

  // Validate provider
  if (!providers[provider]) {
    const available = Object.keys(providers).join(', ');
    throw new Error(`Unknown vector store provider: ${provider}. Available: ${available}`);
  }

  // Create instance
  const StoreClass = providers[provider];
  return new StoreClass(config);
}

/**
 * Auto-detect best available provider
 * Priority: Weaviate > Qdrant > File
 */
function autoDetectProvider() {
  // Check for Weaviate configuration
  if (process.env.WEAVIATE_HOST) {
    return 'weaviate';
  }

  // Check for Qdrant configuration
  if (process.env.QDRANT_HOST) {
    return 'qdrant';
  }

  // Default to file-based store
  return 'file';
}

/**
 * Create store from configuration file
 *
 * @param {string} configPath - Path to configuration JSON file
 * @returns {Promise<BaseStore>} - Configured store instance
 */
async function createStoreFromConfig(configPath) {
  const defaultConfigPath = path.join(process.cwd(), 'config', 'vector-store.json');
  const actualPath = configPath || defaultConfigPath;

  try {
    const configContent = await fs.readFile(actualPath, 'utf8');
    const config = JSON.parse(configContent);

    // Get active provider config
    const activeProvider = config.active_provider || autoDetectProvider();
    const providerConfig = config.providers?.[activeProvider] || {};

    return createStore({
      provider: activeProvider,
      ...providerConfig,
      ...config.global_settings
    });
  } catch (error) {
    if (error.code === 'ENOENT') {
      console.warn(`Config file not found: ${actualPath}. Using auto-detection.`);
      return createStore();
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
 * @param {Class} StoreClass - Class extending BaseStore
 */
function registerProvider(name, StoreClass) {
  if (!(StoreClass.prototype instanceof BaseStore)) {
    throw new Error('Provider must extend BaseStore');
  }
  providers[name] = StoreClass;
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
    case 'weaviate':
      if (process.env.WEAVIATE_HOST) {
        try {
          const store = new WeaviateStore();
          await store.connect();
          const health = await store.healthCheck();
          result.available = health.healthy;
          if (!health.healthy) {
            result.reason = health.error || 'Health check failed';
          }
          await store.disconnect();
        } catch (error) {
          result.reason = error.message;
        }
      } else {
        result.reason = 'WEAVIATE_HOST environment variable not set';
      }
      break;

    case 'qdrant':
      if (process.env.QDRANT_HOST) {
        try {
          const store = new QdrantStore();
          await store.connect();
          const health = await store.healthCheck();
          result.available = health.healthy;
          if (!health.healthy) {
            result.reason = health.error || 'Health check failed';
          }
          await store.disconnect();
        } catch (error) {
          result.reason = error.message;
        }
      } else {
        result.reason = 'QDRANT_HOST environment variable not set';
      }
      break;

    case 'file':
      try {
        const store = new FileStore();
        await store.connect();
        const health = await store.healthCheck();
        result.available = health.healthy;
        if (!health.healthy) {
          result.reason = health.error || 'Health check failed';
        }
        await store.disconnect();
      } catch (error) {
        result.reason = error.message;
      }
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
        console.log('Available vector store providers:');
        for (const provider of getAvailableProviders()) {
          console.log(`  - ${provider}`);
        }
        break;

      case 'status':
        console.log('Provider availability:');
        const statuses = await getAllProviderStatus();
        for (const status of statuses) {
          const icon = status.available ? '[OK]' : '[X]';
          console.log(`  ${icon} ${status.provider}${status.reason ? ` (${status.reason})` : ''}`);
        }
        break;

      case 'test':
        const provider = process.argv[3] || autoDetectProvider();
        console.log(`Testing provider: ${provider}`);

        try {
          const store = createStore(provider);
          console.log(`  Type: ${store.getName()}`);

          await store.connect();
          console.log('  Connected: true');

          const health = await store.healthCheck();
          console.log(`  Healthy: ${health.healthy}`);

          const collections = await store.listCollections();
          console.log(`  Collections: ${collections.length}`);

          await store.disconnect();
          console.log('  Test passed!');
        } catch (error) {
          console.error(`  Test failed: ${error.message}`);
          process.exit(1);
        }
        break;

      case 'info':
        try {
          const store = await createStoreFromConfig();
          await store.connect();

          const info = await store.getInfo();
          console.log('Store Info:');
          console.log(JSON.stringify(info, null, 2));

          const collections = await store.listCollections();
          console.log('\nCollections:');
          for (const coll of collections) {
            const collInfo = await store.getCollectionInfo(coll);
            console.log(`  - ${coll}: ${collInfo.count || collInfo.pointsCount || 0} documents`);
          }

          await store.disconnect();
        } catch (error) {
          console.error(`Failed: ${error.message}`);
          process.exit(1);
        }
        break;

      default:
        console.log('Usage: node index.js <action>');
        console.log('Actions:');
        console.log('  list              - List available providers');
        console.log('  status            - Check provider availability');
        console.log('  test [provider]   - Test a provider');
        console.log('  info              - Show store info from config');
        break;
    }
  })();
}

// Exports
module.exports = {
  createStore,
  createStoreFromConfig,
  getAvailableProviders,
  registerProvider,
  checkProviderAvailability,
  getAllProviderStatus,
  autoDetectProvider,

  // Export classes for direct use
  BaseStore,
  WeaviateStore,
  QdrantStore,
  FileStore
};
