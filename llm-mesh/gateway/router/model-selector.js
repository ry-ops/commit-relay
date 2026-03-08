/**
 * Model Selector
 *
 * Combines complexity scoring, sensitivity detection, and cost constraints
 * to select the optimal model for each task.
 *
 * @module llm-mesh/gateway/router/model-selector
 */

'use strict';

const path = require('path');
const fs = require('fs');

const { scoreComplexity, getComplexityTier } = require('./complexity-scorer');
const { detectSensitivity, getAllowedTiers, requiresLocalProcessing } = require('./sensitivity-detector');
const modelTiers = require('./model-tiers.json');

/**
 * @typedef {Object} ModelSelection
 * @property {string} model - Selected model ID
 * @property {string} provider - Provider name
 * @property {string} tier - Selected tier
 * @property {string} reasoning - Explanation for selection
 * @property {Object} analysis - Detailed analysis breakdown
 */

/**
 * @typedef {Object} SelectionOptions
 * @property {number} [maxCostPer1kTokens] - Maximum cost per 1000 tokens
 * @property {number} [totalBudget] - Total budget constraint
 * @property {boolean} [preferLocal] - Prefer local models
 * @property {string} [preferredProvider] - Preferred provider
 * @property {string[]} [excludeModels] - Models to exclude
 * @property {number} [maxResponseTimeMs] - Maximum acceptable response time
 */

// Load pricing information
let pricingData = {};
try {
  pricingData = require('../catalog/pricing.json');
} catch (error) {
  console.warn('Could not load pricing data:', error.message);
}

/**
 * Get model cost per 1000 tokens
 * @param {string} modelId - Model identifier
 * @param {string} provider - Provider name
 * @returns {number} Cost per 1000 tokens
 */
function getModelCost(modelId, provider) {
  try {
    const providerPricing = pricingData.providers?.[provider]?.models?.[modelId];
    if (providerPricing) {
      // Average of input and output cost per million, converted to per 1k
      const avgCostPerMillion = (providerPricing.input_cost_per_million + providerPricing.output_cost_per_million) / 2;
      return avgCostPerMillion / 1000;
    }
  } catch (error) {
    // Ignore and return default
  }

  // Fallback costs by tier
  const tierCosts = {
    free: 0,
    economical: 0.001,
    balanced: 0.01,
    premium: 0.05
  };

  // Find model in tiers
  for (const tier of Object.values(modelTiers.tiers)) {
    for (const model of tier.models) {
      if (model.id === modelId) {
        return tierCosts[model.cost_tier] || 0.01;
      }
    }
  }

  return 0.01; // Default cost
}

/**
 * Check if model meets constraints
 * @param {Object} model - Model configuration
 * @param {SelectionOptions} options - Selection options
 * @param {number} estimatedTokens - Estimated token count
 * @returns {Object} Constraint check result
 */
function checkModelConstraints(model, options, estimatedTokens) {
  const issues = [];

  // Cost constraint
  if (options.maxCostPer1kTokens) {
    const modelCost = getModelCost(model.id, model.provider);
    if (modelCost > options.maxCostPer1kTokens) {
      issues.push(`Cost ${modelCost.toFixed(4)}/1k exceeds max ${options.maxCostPer1kTokens.toFixed(4)}/1k`);
    }
  }

  // Total budget constraint
  if (options.totalBudget && estimatedTokens > 0) {
    const modelCost = getModelCost(model.id, model.provider);
    const estimatedCost = (modelCost * estimatedTokens) / 1000;
    if (estimatedCost > options.totalBudget) {
      issues.push(`Estimated cost $${estimatedCost.toFixed(4)} exceeds budget $${options.totalBudget.toFixed(4)}`);
    }
  }

  // Response time constraint
  if (options.maxResponseTimeMs && model.avg_response_time_ms > options.maxResponseTimeMs) {
    issues.push(`Response time ${model.avg_response_time_ms}ms exceeds max ${options.maxResponseTimeMs}ms`);
  }

  // Excluded models
  if (options.excludeModels && options.excludeModels.includes(model.id)) {
    issues.push('Model is in exclusion list');
  }

  // Provider preference
  if (options.preferredProvider && model.provider !== options.preferredProvider) {
    // Not a hard constraint, just a preference
  }

  return {
    passes: issues.length === 0,
    issues
  };
}

/**
 * Select optimal model for a task
 * @param {Object} task - Task object
 * @param {string} task.description - Task description
 * @param {string} [task.type] - Task type
 * @param {string} [task.code] - Associated code
 * @param {Object} [task.context] - Additional context
 * @param {SelectionOptions} [options] - Selection options
 * @returns {ModelSelection} Model selection result
 */
function selectModel(task, options = {}) {
  // Step 1: Score complexity
  const complexityResult = scoreComplexity(task);
  const complexityTier = getComplexityTier(complexityResult.score);

  // Step 2: Detect sensitivity
  const sensitivityResult = detectSensitivity(task);
  const allowedTiersForSensitivity = getAllowedTiers(sensitivityResult.level);

  // Step 3: Determine target tier
  let targetTier;
  let tierReason;

  // If sensitivity requires local, force local tier
  if (requiresLocalProcessing(sensitivityResult.level)) {
    targetTier = 'local';
    tierReason = 'High sensitivity requires local processing';
  }
  // If local is preferred (and allowed)
  else if (options.preferLocal && allowedTiersForSensitivity.includes('local')) {
    targetTier = 'local';
    tierReason = 'Local processing preferred by options';
  }
  // Otherwise use complexity-based tier if allowed by sensitivity
  else if (allowedTiersForSensitivity.includes(complexityTier)) {
    targetTier = complexityTier;
    tierReason = `Complexity score ${complexityResult.score} maps to ${complexityTier} tier`;
  }
  // Fall back to highest allowed tier
  else {
    // Sort by capability (powerful > balanced > fast > local for general use)
    const tierOrder = ['powerful', 'balanced', 'fast', 'local'];
    targetTier = tierOrder.find(t => allowedTiersForSensitivity.includes(t)) || 'local';
    tierReason = `Selected ${targetTier} as best allowed tier for sensitivity level ${sensitivityResult.level}`;
  }

  // Step 4: Get tier configuration
  const tierConfig = modelTiers.tiers[targetTier];
  if (!tierConfig) {
    throw new Error(`Unknown tier: ${targetTier}`);
  }

  // Step 5: Filter and sort models
  const eligibleModels = [];

  for (const model of tierConfig.models) {
    const constraintCheck = checkModelConstraints(model, options, complexityResult.tokenEstimate);

    if (constraintCheck.passes) {
      eligibleModels.push({
        ...model,
        cost: getModelCost(model.id, model.provider)
      });
    }
  }

  // Step 6: Select best model
  let selectedModel;
  let selectionReason;

  if (eligibleModels.length > 0) {
    // Sort by priority (lower is better), then by cost (lower is better)
    eligibleModels.sort((a, b) => {
      if (a.priority !== b.priority) {
        return a.priority - b.priority;
      }
      return a.cost - b.cost;
    });

    // Apply provider preference if specified
    if (options.preferredProvider) {
      const preferredModel = eligibleModels.find(m => m.provider === options.preferredProvider);
      if (preferredModel) {
        selectedModel = preferredModel;
        selectionReason = `Selected ${preferredModel.id} (preferred provider: ${options.preferredProvider})`;
      }
    }

    if (!selectedModel) {
      selectedModel = eligibleModels[0];
      selectionReason = `Selected ${selectedModel.id} as highest priority eligible model`;
    }
  }

  // Step 7: Try fallback tiers if no eligible model
  if (!selectedModel) {
    const fallbackChain = modelTiers.fallback_chains[targetTier] || [];

    for (const fallbackTier of fallbackChain) {
      if (!allowedTiersForSensitivity.includes(fallbackTier)) {
        continue;
      }

      const fallbackTierConfig = modelTiers.tiers[fallbackTier];
      if (!fallbackTierConfig) continue;

      for (const model of fallbackTierConfig.models) {
        const constraintCheck = checkModelConstraints(model, options, complexityResult.tokenEstimate);
        if (constraintCheck.passes) {
          selectedModel = {
            ...model,
            cost: getModelCost(model.id, model.provider)
          };
          selectionReason = `Selected ${model.id} from fallback tier ${fallbackTier}`;
          targetTier = fallbackTier;
          break;
        }
      }

      if (selectedModel) break;
    }
  }

  // Step 8: Final fallback
  if (!selectedModel) {
    // Use default selection
    const defaultTier = sensitivityResult.level === 'high'
      ? 'local'
      : modelTiers.default_selections.when_budget_exceeded;

    const defaultTierConfig = modelTiers.tiers[defaultTier];
    if (defaultTierConfig && defaultTierConfig.models.length > 0) {
      selectedModel = {
        ...defaultTierConfig.models[0],
        cost: getModelCost(defaultTierConfig.models[0].id, defaultTierConfig.models[0].provider)
      };
      targetTier = defaultTier;
      selectionReason = `Selected ${selectedModel.id} as default fallback (constraints could not be met)`;
    } else {
      throw new Error('No suitable model found for task');
    }
  }

  // Build comprehensive reasoning
  const reasoningParts = [
    tierReason,
    selectionReason
  ];

  if (sensitivityResult.level !== 'none') {
    reasoningParts.push(`Sensitivity: ${sensitivityResult.level}`);
  }

  if (options.maxCostPer1kTokens) {
    reasoningParts.push(`Cost constraint: $${options.maxCostPer1kTokens.toFixed(4)}/1k tokens`);
  }

  return {
    model: selectedModel.id,
    provider: selectedModel.provider,
    tier: targetTier,
    reasoning: reasoningParts.join('. '),
    analysis: {
      complexity: {
        score: complexityResult.score,
        tier: complexityTier,
        tokenEstimate: complexityResult.tokenEstimate,
        reasoning: complexityResult.reasoning
      },
      sensitivity: {
        level: sensitivityResult.level,
        score: sensitivityResult.score,
        reasoning: sensitivityResult.reasoning
      },
      cost: {
        perKTokens: selectedModel.cost,
        estimatedTotal: (selectedModel.cost * complexityResult.tokenEstimate) / 1000
      },
      model: {
        id: selectedModel.id,
        provider: selectedModel.provider,
        contextWindow: selectedModel.context_window,
        avgResponseTimeMs: selectedModel.avg_response_time_ms
      }
    }
  };
}

/**
 * Batch select models for multiple tasks
 * @param {Array<Object>} tasks - Array of task objects
 * @param {SelectionOptions} [options] - Selection options
 * @returns {Array<ModelSelection>} Array of model selections
 */
function batchSelectModels(tasks, options = {}) {
  if (!Array.isArray(tasks)) {
    throw new Error('Tasks must be an array');
  }

  return tasks.map(task => ({
    task,
    selection: selectModel(task, options)
  }));
}

/**
 * Get recommended models for a complexity/sensitivity combination
 * @param {number} complexityScore - Complexity score (1-10)
 * @param {string} sensitivityLevel - Sensitivity level
 * @returns {Array<Object>} Recommended models
 */
function getRecommendedModels(complexityScore, sensitivityLevel) {
  const complexityTier = getComplexityTier(complexityScore);
  const allowedTiers = getAllowedTiers(sensitivityLevel);

  const recommendations = [];

  // Start with complexity-appropriate tier
  const tiersToCheck = [complexityTier, ...modelTiers.fallback_chains[complexityTier] || []];

  for (const tierName of tiersToCheck) {
    if (!allowedTiers.includes(tierName)) continue;

    const tier = modelTiers.tiers[tierName];
    if (!tier) continue;

    for (const model of tier.models) {
      recommendations.push({
        model: model.id,
        provider: model.provider,
        tier: tierName,
        priority: model.priority,
        cost: getModelCost(model.id, model.provider)
      });
    }
  }

  return recommendations.slice(0, 5); // Return top 5
}

/**
 * Log model selection decision for analytics
 * @param {ModelSelection} selection - Model selection result
 * @param {Object} task - Original task
 */
function logSelectionDecision(selection, task) {
  const logEntry = {
    timestamp: new Date().toISOString(),
    model: selection.model,
    provider: selection.provider,
    tier: selection.tier,
    complexity_score: selection.analysis.complexity.score,
    sensitivity_level: selection.analysis.sensitivity.level,
    token_estimate: selection.analysis.complexity.tokenEstimate,
    estimated_cost: selection.analysis.cost.estimatedTotal,
    task_type: task.type || 'unknown',
    reasoning: selection.reasoning
  };

  // Log to metrics file
  const metricsPath = path.join(__dirname, '../../../coordination/metrics/model-selection.jsonl');

  try {
    const logLine = JSON.stringify(logEntry) + '\n';
    fs.appendFileSync(metricsPath, logLine);
  } catch (error) {
    // Ensure directory exists
    try {
      const dir = path.dirname(metricsPath);
      if (!fs.existsSync(dir)) {
        fs.mkdirSync(dir, { recursive: true });
      }
      const logLine = JSON.stringify(logEntry) + '\n';
      fs.appendFileSync(metricsPath, logLine);
    } catch (innerError) {
      console.error('Failed to log model selection:', innerError.message);
    }
  }

  return logEntry;
}

module.exports = {
  selectModel,
  batchSelectModels,
  getRecommendedModels,
  getModelCost,
  checkModelConstraints,
  logSelectionDecision
};
