#!/usr/bin/env node
// lib/rag/search/index.js
// Search Module Exports and Factory Functions
// Part of Hybrid Search Implementation for commit-relay RAG

const fs = require('fs').promises;
const path = require('path');

// Import search components
const KeywordSearch = require('./keyword-search');
const HybridSearch = require('./hybrid-search');
const {
  reciprocalRankFusion,
  weightedScoreFusion,
  convexCombinationFusion,
  combMNZ,
  interleave
} = require('./fusion');

/**
 * Create a hybrid search instance with vector store and embedder
 * @param {Object} vectorStore - Vector store instance
 * @param {Object} embedder - Embedder instance
 * @param {Object} options - Configuration options
 * @returns {HybridSearch} - Configured hybrid search instance
 */
function createHybridSearch(vectorStore, embedder, options = {}) {
  return new HybridSearch(vectorStore, embedder, options);
}

/**
 * Create hybrid search from configuration file
 * @param {Object} vectorStore - Vector store instance
 * @param {Object} embedder - Embedder instance
 * @param {string} configPath - Path to search configuration file
 * @returns {Promise<HybridSearch>} - Configured hybrid search instance
 */
async function createHybridSearchFromConfig(vectorStore, embedder, configPath = null) {
  let config = {};

  // Try to load configuration
  const searchConfigPath = configPath || path.join(process.cwd(), 'config', 'search.json');

  try {
    const configContent = await fs.readFile(searchConfigPath, 'utf8');
    config = JSON.parse(configContent);
  } catch (error) {
    // Use defaults if config not found
    console.log(`Search config not found at ${searchConfigPath}, using defaults`);
  }

  // Extract hybrid search options from config
  const options = {
    alpha: config.alpha || 0.7,
    fusionMethod: config.fusionMethod || 'alpha',
    rrfK: config.rrfK || 60,
    defaultLimit: config.defaultLimit || 10,
    minSimilarity: config.minSimilarity || 0.5,
    minKeywordScore: config.minKeywordScore || 0.1,
    autoIndex: config.autoIndex !== undefined ? config.autoIndex : true,
    keywordOptions: {
      fields: config.keywordFields || ['content', 'title', 'tags'],
      storeFields: config.storeFields || ['content', 'title', 'tags', 'metadata'],
      boost: config.keywordBoost || { title: 2, tags: 1.5, content: 1 },
      fuzzy: config.fuzzy !== undefined ? config.fuzzy : 0.2,
      prefix: config.prefix !== undefined ? config.prefix : true
    }
  };

  return new HybridSearch(vectorStore, embedder, options);
}

/**
 * Create a standalone keyword search instance
 * @param {Object} options - Configuration options
 * @returns {KeywordSearch} - Keyword search instance
 */
function createKeywordSearch(options = {}) {
  return new KeywordSearch(options);
}

/**
 * Load search configuration from file
 * @param {string} configPath - Path to configuration file
 * @returns {Promise<Object>} - Configuration object
 */
async function loadSearchConfig(configPath = null) {
  const searchConfigPath = configPath || path.join(process.cwd(), 'config', 'search.json');

  try {
    const configContent = await fs.readFile(searchConfigPath, 'utf8');
    return JSON.parse(configContent);
  } catch (error) {
    // Return default configuration
    return getDefaultConfig();
  }
}

/**
 * Get default search configuration
 * @returns {Object} - Default configuration
 */
function getDefaultConfig() {
  return {
    // Hybrid search alpha (0 = keyword only, 1 = semantic only)
    alpha: 0.7,

    // Fusion method: 'alpha', 'rrf', or 'weighted'
    fusionMethod: 'alpha',

    // RRF constant (higher = more weight to lower-ranked items)
    rrfK: 60,

    // Default result limit
    defaultLimit: 10,

    // Minimum semantic similarity threshold
    minSimilarity: 0.5,

    // Minimum keyword score threshold
    minKeywordScore: 0.1,

    // Auto-index documents when added
    autoIndex: true,

    // Keyword search fields
    keywordFields: ['content', 'title', 'tags'],

    // Fields to store in keyword index
    storeFields: ['content', 'title', 'tags', 'metadata'],

    // Field boost values for keyword search
    keywordBoost: {
      title: 2,
      tags: 1.5,
      content: 1
    },

    // Fuzzy matching threshold (0 = exact, 1 = very fuzzy)
    fuzzy: 0.2,

    // Enable prefix matching
    prefix: true,

    // Collection-specific overrides
    collections: {
      code: {
        alpha: 0.6,  // Slightly favor keywords for code
        minSimilarity: 0.55
      },
      documentation: {
        alpha: 0.75,  // Favor semantic for docs
        minSimilarity: 0.6
      },
      decisions: {
        alpha: 0.7,
        minSimilarity: 0.65
      },
      patterns: {
        alpha: 0.65,
        minSimilarity: 0.6
      },
      tasks: {
        alpha: 0.7,
        minSimilarity: 0.6
      }
    }
  };
}

// Export all components
module.exports = {
  // Main classes
  HybridSearch,
  KeywordSearch,

  // Factory functions
  createHybridSearch,
  createHybridSearchFromConfig,
  createKeywordSearch,

  // Fusion algorithms
  reciprocalRankFusion,
  weightedScoreFusion,
  convexCombinationFusion,
  combMNZ,
  interleave,

  // Configuration utilities
  loadSearchConfig,
  getDefaultConfig
};
