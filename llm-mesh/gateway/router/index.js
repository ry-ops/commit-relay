/**
 * Router Module Index
 *
 * Exports all router components for the LLM gateway.
 *
 * @module llm-mesh/gateway/router
 */

'use strict';

const ModelRouter = require('./model-router');
const { selectModel, batchSelectModels, getRecommendedModels, logSelectionDecision } = require('./model-selector');
const { scoreComplexity, getComplexityTier, estimateTokens, analyzeKeywords } = require('./complexity-scorer');
const { detectSensitivity, getAllowedTiers, requiresLocalProcessing, sanitizeContent } = require('./sensitivity-detector');
const modelTiers = require('./model-tiers.json');

module.exports = {
  // Main router class
  ModelRouter,

  // Model selection
  selectModel,
  batchSelectModels,
  getRecommendedModels,
  logSelectionDecision,

  // Complexity scoring
  scoreComplexity,
  getComplexityTier,
  estimateTokens,
  analyzeKeywords,

  // Sensitivity detection
  detectSensitivity,
  getAllowedTiers,
  requiresLocalProcessing,
  sanitizeContent,

  // Configuration
  modelTiers
};
