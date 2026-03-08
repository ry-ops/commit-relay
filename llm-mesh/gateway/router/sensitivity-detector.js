/**
 * Sensitivity Detector
 *
 * Detects sensitive data patterns in tasks to route appropriately.
 * Routes high-sensitivity tasks to local models for privacy protection.
 *
 * @module llm-mesh/gateway/router/sensitivity-detector
 */

'use strict';

/**
 * Sensitivity patterns for detection
 * Each category has patterns and a weight that contributes to sensitivity score
 */
const SENSITIVITY_PATTERNS = {
  credentials: {
    weight: 10,
    patterns: [
      // API keys and tokens
      /api[_-]?key\s*[=:]\s*['"]?[a-zA-Z0-9_-]{20,}/i,
      /secret[_-]?key\s*[=:]\s*['"]?[a-zA-Z0-9_-]{20,}/i,
      /access[_-]?token\s*[=:]\s*['"]?[a-zA-Z0-9_-]{20,}/i,
      /auth[_-]?token\s*[=:]\s*['"]?[a-zA-Z0-9_-]{20,}/i,
      /bearer\s+[a-zA-Z0-9_-]{20,}/i,

      // AWS credentials
      /AKIA[0-9A-Z]{16}/,
      /aws[_-]?secret[_-]?access[_-]?key\s*[=:]/i,
      /aws[_-]?access[_-]?key[_-]?id\s*[=:]/i,

      // Database credentials
      /password\s*[=:]\s*['"][^'"]{6,}/i,
      /passwd\s*[=:]\s*['"][^'"]{6,}/i,
      /db[_-]?password\s*[=:]/i,
      /database[_-]?url\s*[=:]/i,
      /connection[_-]?string\s*[=:]/i,

      // Private keys
      /-----BEGIN\s+(RSA\s+)?PRIVATE\s+KEY-----/,
      /-----BEGIN\s+OPENSSH\s+PRIVATE\s+KEY-----/,
      /-----BEGIN\s+EC\s+PRIVATE\s+KEY-----/,
      /-----BEGIN\s+PGP\s+PRIVATE\s+KEY\s+BLOCK-----/,

      // OAuth and JWT
      /client[_-]?secret\s*[=:]/i,
      /oauth[_-]?token\s*[=:]/i,
      /refresh[_-]?token\s*[=:]/i
    ]
  },

  pii: {
    weight: 8,
    patterns: [
      // Social Security Number (US)
      /\b\d{3}[-\s]?\d{2}[-\s]?\d{4}\b/,
      /ssn\s*[=:]\s*['"]?\d{3}/i,
      /social[_-]?security/i,

      // Credit card numbers
      /\b(?:4[0-9]{12}(?:[0-9]{3})?|5[1-5][0-9]{14}|3[47][0-9]{13}|6(?:011|5[0-9]{2})[0-9]{12})\b/,
      /credit[_-]?card/i,
      /card[_-]?number\s*[=:]/i,

      // Bank account
      /bank[_-]?account/i,
      /routing[_-]?number/i,
      /iban\s*[=:]/i,

      // Personal identifiers
      /driver[_-]?license/i,
      /passport[_-]?number/i,
      /national[_-]?id/i,
      /tax[_-]?id/i,

      // Medical information
      /medical[_-]?record/i,
      /health[_-]?insurance/i,
      /patient[_-]?id/i,
      /diagnosis\s*[=:]/i
    ]
  },

  secrets: {
    weight: 9,
    patterns: [
      // Encryption keys
      /encryption[_-]?key\s*[=:]/i,
      /decryption[_-]?key\s*[=:]/i,
      /signing[_-]?key\s*[=:]/i,
      /master[_-]?key\s*[=:]/i,

      // Certificates
      /-----BEGIN\s+CERTIFICATE-----/,
      /ssl[_-]?cert/i,
      /tls[_-]?cert/i,

      // Environment secrets
      /\.env\s+file/i,
      /environment\s+secret/i,
      /production\s+secret/i,

      // GitHub tokens
      /gh[pou]_[A-Za-z0-9_]{36,}/,
      /github[_-]?token\s*[=:]/i,

      // Other service tokens
      /slack[_-]?token/i,
      /stripe[_-]?key/i,
      /sendgrid[_-]?key/i,
      /twilio[_-]?(?:sid|token)/i,
      /firebase[_-]?key/i
    ]
  },

  contact_info: {
    weight: 5,
    patterns: [
      // Email addresses
      /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b/,

      // Phone numbers
      /\b(?:\+?1[-.\s]?)?\(?[2-9][0-9]{2}\)?[-.\s]?[0-9]{3}[-.\s]?[0-9]{4}\b/,
      /phone[_-]?number\s*[=:]/i,
      /mobile[_-]?number\s*[=:]/i,

      // Physical addresses
      /street[_-]?address\s*[=:]/i,
      /postal[_-]?code\s*[=:]/i,
      /zip[_-]?code\s*[=:]/i,
      /home[_-]?address/i
    ]
  },

  internal_systems: {
    weight: 6,
    patterns: [
      // Internal URLs
      /internal[_-]?(?:url|endpoint|api)/i,
      /staging[_-]?(?:url|server)/i,
      /\.internal\./i,
      /\.local\./i,
      /localhost:\d{4,}/,

      // Internal paths
      /\/home\/[a-zA-Z0-9_]+\//,
      /\/Users\/[a-zA-Z0-9_]+\//,
      /C:\\Users\\[a-zA-Z0-9_]+\\/,

      // Infrastructure
      /vpc[_-]?id/i,
      /subnet[_-]?id/i,
      /security[_-]?group[_-]?id/i,
      /instance[_-]?id/i
    ]
  }
};

/**
 * Keywords that indicate sensitive context
 */
const SENSITIVE_CONTEXT_KEYWORDS = {
  high: [
    'production credentials', 'prod secrets', 'customer data',
    'financial records', 'medical data', 'hipaa', 'pci', 'gdpr',
    'private keys', 'master password', 'root access'
  ],
  medium: [
    'user passwords', 'employee data', 'internal api',
    'staging credentials', 'test accounts', 'development keys'
  ],
  low: [
    'public api', 'demo account', 'sample data', 'mock credentials'
  ]
};

/**
 * Detect sensitivity level of task content
 * @param {Object} task - Task object
 * @param {string} task.description - Task description
 * @param {string} [task.code] - Associated code content
 * @param {Object} [task.context] - Additional context
 * @returns {Object} Sensitivity detection result
 */
function detectSensitivity(task) {
  if (!task) {
    return {
      level: 'none',
      score: 0,
      detections: [],
      reasoning: 'No task provided'
    };
  }

  const content = [
    task.description || '',
    task.code || '',
    JSON.stringify(task.context || {})
  ].join('\n');

  const detections = [];
  let totalScore = 0;

  // Check each category of patterns
  for (const [category, config] of Object.entries(SENSITIVITY_PATTERNS)) {
    const categoryDetections = [];

    for (const pattern of config.patterns) {
      const matches = content.match(pattern);
      if (matches) {
        categoryDetections.push({
          pattern: pattern.toString().slice(0, 50) + '...',
          matches: matches.slice(0, 3) // Limit to first 3 matches
        });
      }
    }

    if (categoryDetections.length > 0) {
      const categoryScore = config.weight * Math.min(categoryDetections.length, 5);
      totalScore += categoryScore;

      detections.push({
        category,
        weight: config.weight,
        detectionCount: categoryDetections.length,
        score: categoryScore,
        samples: categoryDetections.slice(0, 2) // Limit samples
      });
    }
  }

  // Check context keywords
  const contentLower = content.toLowerCase();

  for (const keyword of SENSITIVE_CONTEXT_KEYWORDS.high) {
    if (contentLower.includes(keyword)) {
      totalScore += 15;
      detections.push({
        category: 'context_keyword_high',
        keyword,
        score: 15
      });
    }
  }

  for (const keyword of SENSITIVE_CONTEXT_KEYWORDS.medium) {
    if (contentLower.includes(keyword)) {
      totalScore += 8;
      detections.push({
        category: 'context_keyword_medium',
        keyword,
        score: 8
      });
    }
  }

  // Determine sensitivity level
  let level;
  if (totalScore >= 25) {
    level = 'high';
  } else if (totalScore >= 15) {
    level = 'medium';
  } else if (totalScore >= 5) {
    level = 'low';
  } else {
    level = 'none';
  }

  // Generate reasoning
  const reasons = [];
  if (detections.length === 0) {
    reasons.push('No sensitive patterns detected');
  } else {
    const categories = [...new Set(detections.map(d => d.category))];
    reasons.push(`Detected sensitive content in: ${categories.join(', ')}`);

    if (level === 'high') {
      reasons.push('Recommend local model processing only');
    } else if (level === 'medium') {
      reasons.push('Consider local model for enhanced privacy');
    }
  }

  return {
    level,
    score: totalScore,
    detections: detections.map(d => ({
      category: d.category,
      score: d.score,
      detectionCount: d.detectionCount || 1
    })),
    reasoning: reasons.join('; ')
  };
}

/**
 * Check if content requires local processing
 * @param {string} level - Sensitivity level
 * @returns {boolean} True if local processing is required
 */
function requiresLocalProcessing(level) {
  return level === 'high';
}

/**
 * Get allowed tiers for sensitivity level
 * @param {string} level - Sensitivity level
 * @returns {string[]} Array of allowed tier names
 */
function getAllowedTiers(level) {
  switch (level) {
    case 'high':
      return ['local'];
    case 'medium':
      return ['balanced', 'powerful', 'local'];
    case 'low':
      return ['fast', 'balanced', 'powerful', 'local'];
    default:
      return ['fast', 'balanced', 'powerful', 'local'];
  }
}

/**
 * Sanitize content for external processing
 * @param {string} content - Content to sanitize
 * @returns {Object} Sanitized content and metadata
 */
function sanitizeContent(content) {
  if (!content) {
    return { sanitized: '', redactionCount: 0 };
  }

  let sanitized = content;
  let redactionCount = 0;

  // Redact patterns from all categories
  for (const [category, config] of Object.entries(SENSITIVITY_PATTERNS)) {
    for (const pattern of config.patterns) {
      const matches = sanitized.match(new RegExp(pattern, 'gi'));
      if (matches) {
        redactionCount += matches.length;
        sanitized = sanitized.replace(new RegExp(pattern, 'gi'), `[REDACTED_${category.toUpperCase()}]`);
      }
    }
  }

  return {
    sanitized,
    redactionCount,
    wasModified: redactionCount > 0
  };
}

/**
 * Batch detect sensitivity for multiple tasks
 * @param {Array<Object>} tasks - Array of task objects
 * @returns {Array<Object>} Array of detection results
 */
function batchDetectSensitivity(tasks) {
  if (!Array.isArray(tasks)) {
    throw new Error('Tasks must be an array');
  }

  return tasks.map(task => ({
    task,
    ...detectSensitivity(task)
  }));
}

module.exports = {
  detectSensitivity,
  requiresLocalProcessing,
  getAllowedTiers,
  sanitizeContent,
  batchDetectSensitivity,
  SENSITIVITY_PATTERNS,
  SENSITIVE_CONTEXT_KEYWORDS
};
