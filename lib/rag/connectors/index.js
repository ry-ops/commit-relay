#!/usr/bin/env node
// lib/rag/connectors/index.js
// Connector factory and registry
// Part of RAG Knowledge Ingestion System

const BaseConnector = require('./base-connector');
const GitHubConnector = require('./github-connector');
const ConfluenceConnector = require('./confluence-connector');
const SlackConnector = require('./slack-connector');

/**
 * Available connector types registry
 */
const CONNECTOR_TYPES = {
  github: {
    class: GitHubConnector,
    description: 'GitHub repository connector',
    requiredConfig: ['owner', 'repo'],
    optionalConfig: ['token', 'branch', 'includePatterns', 'excludePatterns']
  },
  confluence: {
    class: ConfluenceConnector,
    description: 'Confluence wiki connector',
    requiredConfig: ['baseUrl', 'username', 'apiToken'],
    optionalConfig: ['spaceKeys', 'includeLabels', 'excludeLabels']
  },
  slack: {
    class: SlackConnector,
    description: 'Slack messaging connector',
    requiredConfig: ['token'],
    optionalConfig: ['channels', 'excludeChannels', 'messageLimit']
  }
};

/**
 * Create a connector instance
 * @param {string} type - Connector type (github, confluence, slack)
 * @param {Object} config - Connector configuration
 * @returns {BaseConnector} - Connector instance
 */
function createConnector(type, config = {}) {
  const connectorInfo = CONNECTOR_TYPES[type];

  if (!connectorInfo) {
    const available = Object.keys(CONNECTOR_TYPES).join(', ');
    throw new Error(`Unknown connector type: ${type}. Available: ${available}`);
  }

  const ConnectorClass = connectorInfo.class;
  return new ConnectorClass(config);
}

/**
 * List available connector types
 * @returns {Array<Object>} - Connector type information
 */
function listConnectors() {
  return Object.entries(CONNECTOR_TYPES).map(([type, info]) => ({
    type,
    description: info.description,
    requiredConfig: info.requiredConfig,
    optionalConfig: info.optionalConfig
  }));
}

/**
 * Get connector type information
 * @param {string} type - Connector type
 * @returns {Object|null} - Connector info or null
 */
function getConnectorInfo(type) {
  const info = CONNECTOR_TYPES[type];
  if (!info) return null;

  return {
    type,
    description: info.description,
    requiredConfig: info.requiredConfig,
    optionalConfig: info.optionalConfig
  };
}

/**
 * Validate connector configuration
 * @param {string} type - Connector type
 * @param {Object} config - Configuration to validate
 * @returns {Object} - Validation result
 */
function validateConnectorConfig(type, config) {
  const info = CONNECTOR_TYPES[type];

  if (!info) {
    return {
      valid: false,
      errors: [`Unknown connector type: ${type}`],
      warnings: []
    };
  }

  const errors = [];
  const warnings = [];

  // Check required config
  for (const key of info.requiredConfig) {
    if (!config[key] && !process.env[key.toUpperCase()]) {
      errors.push(`Missing required configuration: ${key}`);
    }
  }

  // Check for unknown config keys
  const knownKeys = [...info.requiredConfig, ...info.optionalConfig, 'name', 'batchSize', 'timeout', 'rateLimitDelay', 'maxRetries'];
  for (const key of Object.keys(config)) {
    if (!knownKeys.includes(key)) {
      warnings.push(`Unknown configuration key: ${key}`);
    }
  }

  return {
    valid: errors.length === 0,
    errors,
    warnings
  };
}

/**
 * Create multiple connectors from configuration array
 * @param {Array<Object>} configs - Array of connector configs
 * @returns {Map<string, BaseConnector>} - Map of connector instances
 */
function createConnectors(configs) {
  const connectors = new Map();

  for (const config of configs) {
    if (!config.type) {
      console.error('Connector config missing type:', config);
      continue;
    }

    const name = config.name || `${config.type}-${connectors.size + 1}`;

    try {
      const connector = createConnector(config.type, { ...config, name });
      connectors.set(name, connector);
    } catch (error) {
      console.error(`Failed to create connector ${name}:`, error.message);
    }
  }

  return connectors;
}

/**
 * Run health checks on all connectors
 * @param {Map<string, BaseConnector>} connectors - Connector map
 * @returns {Promise<Object>} - Health check results
 */
async function healthCheckAll(connectors) {
  const results = {};

  for (const [name, connector] of connectors) {
    try {
      results[name] = await connector.healthCheck();
    } catch (error) {
      results[name] = {
        healthy: false,
        connector: name,
        error: error.message,
        checkedAt: new Date().toISOString()
      };
    }
  }

  return results;
}

/**
 * Get statistics for all connectors
 * @param {Map<string, BaseConnector>} connectors - Connector map
 * @returns {Object} - Combined statistics
 */
function getConnectorStats(connectors) {
  const stats = {};

  for (const [name, connector] of connectors) {
    stats[name] = connector.getStats();
  }

  return stats;
}

module.exports = {
  // Factory functions
  createConnector,
  createConnectors,

  // Registry
  listConnectors,
  getConnectorInfo,
  validateConnectorConfig,

  // Utilities
  healthCheckAll,
  getConnectorStats,

  // Classes (for direct use)
  BaseConnector,
  GitHubConnector,
  ConfluenceConnector,
  SlackConnector
};
