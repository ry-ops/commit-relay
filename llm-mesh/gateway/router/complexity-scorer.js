/**
 * Complexity Scorer
 *
 * Analyzes tasks to determine complexity scores for model selection.
 * Combines token estimation, task type multipliers, and keyword analysis.
 *
 * @module llm-mesh/gateway/router/complexity-scorer
 */

'use strict';

/**
 * Task type complexity multipliers
 * Higher values indicate more complex tasks requiring more powerful models
 */
const TASK_TYPE_MULTIPLIERS = {
  // High complexity - require powerful models
  security_audit: 2.5,
  architecture_review: 2.4,
  vulnerability_assessment: 2.3,
  code_refactoring: 2.0,
  performance_optimization: 1.9,

  // Medium-high complexity
  feature_implementation: 1.7,
  bug_fix: 1.5,
  integration: 1.6,
  api_design: 1.8,

  // Medium complexity
  code_review: 1.4,
  documentation: 1.2,
  testing: 1.3,
  debugging: 1.5,

  // Lower complexity
  simple_query: 0.8,
  formatting: 0.6,
  translation: 0.7,
  summarization: 0.9,
  classification: 0.8,

  // Default
  default: 1.0
};

/**
 * Complexity indicator keywords
 * Presence of these keywords adjusts the base complexity score
 */
const COMPLEXITY_KEYWORDS = {
  high: {
    keywords: [
      'security', 'vulnerability', 'exploit', 'cve', 'critical',
      'architecture', 'design', 'system', 'infrastructure',
      'performance', 'optimization', 'scalability', 'concurrency',
      'distributed', 'microservices', 'migration', 'refactor',
      'compliance', 'audit', 'enterprise', 'production',
      'cryptography', 'encryption', 'authentication', 'authorization',
      'database', 'schema', 'transaction', 'consistency'
    ],
    boost: 1.5
  },
  medium: {
    keywords: [
      'implement', 'feature', 'integration', 'api', 'endpoint',
      'module', 'component', 'service', 'handler', 'controller',
      'testing', 'validation', 'error', 'exception', 'debug',
      'cache', 'queue', 'async', 'parallel', 'workflow',
      'configuration', 'deployment', 'monitoring', 'logging'
    ],
    boost: 1.2
  },
  low: {
    keywords: [
      'simple', 'basic', 'quick', 'minor', 'small',
      'format', 'style', 'lint', 'rename', 'typo',
      'comment', 'readme', 'docs', 'example', 'sample'
    ],
    boost: 0.8
  }
};

/**
 * Negative complexity indicators that reduce score
 */
const SIMPLICITY_INDICATORS = [
  'trivial', 'straightforward', 'simple fix', 'quick change',
  'one-liner', 'typo fix', 'cosmetic', 'minor update'
];

/**
 * Estimate token count from text
 * @param {string} text - Input text
 * @returns {number} Estimated token count
 */
function estimateTokens(text) {
  if (!text) return 0;

  // Rough estimation: ~4 characters per token for English
  // Adjust for code which tends to have more tokens
  const baseEstimate = Math.ceil(text.length / 4);

  // Code detection boost (code has more tokens per character)
  const codePatterns = /[{}\[\]();=><\/\\|&^%$#@!~`]/g;
  const codeMatches = (text.match(codePatterns) || []).length;
  const codeBoost = 1 + (codeMatches / text.length) * 0.5;

  return Math.ceil(baseEstimate * codeBoost);
}

/**
 * Analyze keywords in task description
 * @param {string} description - Task description
 * @returns {Object} Keyword analysis result
 */
function analyzeKeywords(description) {
  if (!description) {
    return { score: 1.0, matches: { high: [], medium: [], low: [] } };
  }

  const descLower = description.toLowerCase();
  const matches = { high: [], medium: [], low: [] };
  let score = 1.0;

  // Check high complexity keywords
  for (const keyword of COMPLEXITY_KEYWORDS.high.keywords) {
    if (descLower.includes(keyword)) {
      matches.high.push(keyword);
    }
  }

  // Check medium complexity keywords
  for (const keyword of COMPLEXITY_KEYWORDS.medium.keywords) {
    if (descLower.includes(keyword)) {
      matches.medium.push(keyword);
    }
  }

  // Check low complexity keywords
  for (const keyword of COMPLEXITY_KEYWORDS.low.keywords) {
    if (descLower.includes(keyword)) {
      matches.low.push(keyword);
    }
  }

  // Calculate keyword-based score adjustment
  if (matches.high.length > 0) {
    score *= COMPLEXITY_KEYWORDS.high.boost;
    // Additional boost for multiple high-complexity indicators
    if (matches.high.length >= 3) {
      score *= 1.2;
    }
  }

  if (matches.medium.length > 0 && matches.high.length === 0) {
    score *= COMPLEXITY_KEYWORDS.medium.boost;
  }

  if (matches.low.length > 0 && matches.high.length === 0 && matches.medium.length === 0) {
    score *= COMPLEXITY_KEYWORDS.low.boost;
  }

  // Check for simplicity indicators
  for (const indicator of SIMPLICITY_INDICATORS) {
    if (descLower.includes(indicator)) {
      score *= 0.8;
      break;
    }
  }

  return { score, matches };
}

/**
 * Get task type multiplier
 * @param {string} taskType - Task type identifier
 * @returns {number} Complexity multiplier
 */
function getTaskTypeMultiplier(taskType) {
  if (!taskType) return TASK_TYPE_MULTIPLIERS.default;

  // Normalize task type (convert to snake_case)
  const normalizedType = taskType
    .toLowerCase()
    .replace(/-/g, '_')
    .replace(/\s+/g, '_');

  return TASK_TYPE_MULTIPLIERS[normalizedType] || TASK_TYPE_MULTIPLIERS.default;
}

/**
 * Score task complexity on a scale of 1-10
 * @param {Object} task - Task object
 * @param {string} task.description - Task description
 * @param {string} [task.type] - Task type
 * @param {string} [task.code] - Associated code content
 * @param {Object} [task.context] - Additional context
 * @returns {Object} Complexity scoring result
 */
function scoreComplexity(task) {
  if (!task) {
    return {
      score: 5,
      tokenEstimate: 0,
      factors: {
        taskType: 1.0,
        keywords: { score: 1.0, matches: { high: [], medium: [], low: [] } },
        tokenSize: 1.0
      },
      reasoning: 'No task provided, using default complexity'
    };
  }

  const description = task.description || '';
  const code = task.code || '';
  const taskType = task.type || '';

  // Factor 1: Task type multiplier
  const taskTypeMultiplier = getTaskTypeMultiplier(taskType);

  // Factor 2: Keyword analysis
  const keywordAnalysis = analyzeKeywords(description);

  // Factor 3: Token estimation and size factor
  const descTokens = estimateTokens(description);
  const codeTokens = estimateTokens(code);
  const totalTokens = descTokens + codeTokens;

  // Size factor: larger tasks tend to be more complex
  let tokenSizeFactor = 1.0;
  if (totalTokens > 10000) {
    tokenSizeFactor = 1.8;
  } else if (totalTokens > 5000) {
    tokenSizeFactor = 1.5;
  } else if (totalTokens > 2000) {
    tokenSizeFactor = 1.3;
  } else if (totalTokens > 1000) {
    tokenSizeFactor = 1.1;
  } else if (totalTokens < 200) {
    tokenSizeFactor = 0.9;
  }

  // Calculate base complexity score
  let baseScore = 5; // Start at middle

  // Apply multipliers
  baseScore *= taskTypeMultiplier;
  baseScore *= keywordAnalysis.score;
  baseScore *= tokenSizeFactor;

  // Normalize to 1-10 scale
  let finalScore = Math.round(Math.max(1, Math.min(10, baseScore)));

  // Generate reasoning
  const reasons = [];

  if (taskTypeMultiplier > 1.5) {
    reasons.push(`High complexity task type (${taskType})`);
  } else if (taskTypeMultiplier < 1.0) {
    reasons.push(`Low complexity task type (${taskType})`);
  }

  if (keywordAnalysis.matches.high.length > 0) {
    reasons.push(`High complexity keywords: ${keywordAnalysis.matches.high.slice(0, 3).join(', ')}`);
  }

  if (totalTokens > 5000) {
    reasons.push(`Large token count (${totalTokens} estimated)`);
  } else if (totalTokens < 200) {
    reasons.push(`Small token count (${totalTokens} estimated)`);
  }

  if (reasons.length === 0) {
    reasons.push('Standard complexity based on analysis');
  }

  return {
    score: finalScore,
    tokenEstimate: totalTokens,
    factors: {
      taskType: taskTypeMultiplier,
      keywords: keywordAnalysis,
      tokenSize: tokenSizeFactor
    },
    reasoning: reasons.join('; ')
  };
}

/**
 * Get complexity tier from score
 * @param {number} score - Complexity score (1-10)
 * @returns {string} Complexity tier
 */
function getComplexityTier(score) {
  if (score >= 8) return 'powerful';
  if (score >= 5) return 'balanced';
  if (score >= 3) return 'fast';
  return 'fast';
}

/**
 * Batch score multiple tasks
 * @param {Array<Object>} tasks - Array of task objects
 * @returns {Array<Object>} Array of scoring results
 */
function batchScoreComplexity(tasks) {
  if (!Array.isArray(tasks)) {
    throw new Error('Tasks must be an array');
  }

  return tasks.map(task => ({
    task,
    ...scoreComplexity(task)
  }));
}

module.exports = {
  scoreComplexity,
  getComplexityTier,
  estimateTokens,
  analyzeKeywords,
  getTaskTypeMultiplier,
  batchScoreComplexity,
  TASK_TYPE_MULTIPLIERS,
  COMPLEXITY_KEYWORDS
};
