/**
 * Token Counter Middleware
 * Uses tiktoken for accurate token counting with support for different models
 *
 * @module llm-mesh/gateway/middleware/token-counter
 */

const { encoding_for_model, get_encoding } = require('tiktoken');

// Model to tokenizer mapping
const MODEL_ENCODINGS = {
  // OpenAI models use cl100k_base
  'gpt-4-turbo': 'cl100k_base',
  'gpt-4o': 'cl100k_base',
  'gpt-4': 'cl100k_base',
  'gpt-3.5-turbo': 'cl100k_base',

  // Claude models - use cl100k_base as approximation
  // Note: Claude uses a different tokenizer, this is an approximation
  'claude-3-haiku': 'cl100k_base',
  'claude-3-sonnet': 'cl100k_base',
  'claude-3-opus': 'cl100k_base',
  'claude-sonnet-4': 'cl100k_base',
  'claude-opus-4': 'cl100k_base',
  'claude-haiku': 'cl100k_base',

  // Default
  'default': 'cl100k_base'
};

// Claude tokenizer adjustment factor (Claude tends to tokenize ~10% more efficiently)
const CLAUDE_ADJUSTMENT = 0.9;

// Cache for encoders to avoid repeated initialization
const encoderCache = new Map();

/**
 * Get the appropriate encoder for a model
 * @param {string} model - The model name
 * @returns {Object} The tiktoken encoder
 */
function getEncoder(model) {
  const encodingName = MODEL_ENCODINGS[model] || MODEL_ENCODINGS['default'];

  if (!encoderCache.has(encodingName)) {
    try {
      encoderCache.set(encodingName, get_encoding(encodingName));
    } catch (error) {
      console.error(`Failed to load encoding ${encodingName}, falling back to cl100k_base`);
      encoderCache.set(encodingName, get_encoding('cl100k_base'));
    }
  }

  return encoderCache.get(encodingName);
}

/**
 * Check if model is a Claude model
 * @param {string} model - The model name
 * @returns {boolean}
 */
function isClaudeModel(model) {
  return model.toLowerCase().includes('claude');
}

/**
 * Count tokens in a text string
 * @param {string} text - The text to count tokens for
 * @param {string} model - The model to use for tokenization (default: 'gpt-3.5-turbo')
 * @returns {number} The number of tokens
 */
function countTokens(text, model = 'gpt-3.5-turbo') {
  if (!text || typeof text !== 'string') {
    return 0;
  }

  try {
    const encoder = getEncoder(model);
    const tokens = encoder.encode(text);
    let count = tokens.length;

    // Apply Claude adjustment if needed
    if (isClaudeModel(model)) {
      count = Math.ceil(count * CLAUDE_ADJUSTMENT);
    }

    return count;
  } catch (error) {
    // Fallback: rough estimate of 4 characters per token
    console.error(`Token counting error for model ${model}:`, error.message);
    const estimate = Math.ceil(text.length / 4);
    return isClaudeModel(model) ? Math.ceil(estimate * CLAUDE_ADJUSTMENT) : estimate;
  }
}

/**
 * Count tokens in a messages array (chat format)
 * @param {Array} messages - Array of message objects with role and content
 * @param {string} model - The model to use for tokenization
 * @returns {number} The total number of tokens
 */
function countMessages(messages, model = 'gpt-3.5-turbo') {
  if (!messages || !Array.isArray(messages)) {
    return 0;
  }

  let totalTokens = 0;

  // Per-message overhead tokens
  // OpenAI: each message has ~4 overhead tokens
  // Claude: similar overhead
  const perMessageOverhead = 4;

  // Reply priming tokens
  const replyPrimingTokens = 3;

  for (const message of messages) {
    // Count role tokens
    if (message.role) {
      totalTokens += countTokens(message.role, model);
    }

    // Count content tokens
    if (message.content) {
      if (typeof message.content === 'string') {
        totalTokens += countTokens(message.content, model);
      } else if (Array.isArray(message.content)) {
        // Handle multi-part content (e.g., with images)
        for (const part of message.content) {
          if (part.type === 'text' && part.text) {
            totalTokens += countTokens(part.text, model);
          }
          // Note: Image tokens require special handling
          // Claude: ~1600 tokens per image
          // GPT-4V: varies based on resolution
          if (part.type === 'image') {
            totalTokens += 1600; // Conservative estimate
          }
        }
      }
    }

    // Count name tokens if present
    if (message.name) {
      totalTokens += countTokens(message.name, model);
      totalTokens += 1; // Additional token for name field
    }

    // Add per-message overhead
    totalTokens += perMessageOverhead;
  }

  // Add reply priming tokens
  totalTokens += replyPrimingTokens;

  return totalTokens;
}

/**
 * Estimate output tokens based on task type and model
 * @param {string} taskType - The type of task
 * @param {string} model - The model to use
 * @returns {number} Estimated output tokens
 */
function estimateOutputTokens(taskType, model = 'gpt-3.5-turbo') {
  const estimates = {
    'routing-analysis': 500,
    'pattern-extraction': 1000,
    'improvement-generation': 2000,
    'security-analysis': 1500,
    'code-review': 2000,
    'general': 1000,
    'default': 1000
  };

  return estimates[taskType] || estimates['default'];
}

/**
 * Truncate text to fit within a token budget
 * @param {string} text - The text to truncate
 * @param {number} maxTokens - Maximum number of tokens allowed
 * @param {string} model - The model to use for tokenization
 * @returns {string} Truncated text
 */
function truncateToTokens(text, maxTokens, model = 'gpt-3.5-turbo') {
  if (!text || typeof text !== 'string') {
    return '';
  }

  const currentTokens = countTokens(text, model);

  if (currentTokens <= maxTokens) {
    return text;
  }

  // Binary search to find the right truncation point
  let low = 0;
  let high = text.length;
  let result = '';

  while (low < high) {
    const mid = Math.floor((low + high + 1) / 2);
    const truncated = text.substring(0, mid);
    const tokens = countTokens(truncated, model);

    if (tokens <= maxTokens) {
      result = truncated;
      low = mid;
    } else {
      high = mid - 1;
    }
  }

  // Add ellipsis if truncated
  if (result.length < text.length) {
    result = result.trim() + '...';
  }

  return result;
}

/**
 * Get token statistics for text
 * @param {string} text - The text to analyze
 * @param {string} model - The model to use for tokenization
 * @returns {Object} Token statistics
 */
function getTokenStats(text, model = 'gpt-3.5-turbo') {
  const tokens = countTokens(text, model);
  const characters = text ? text.length : 0;
  const words = text ? text.split(/\s+/).filter(w => w.length > 0).length : 0;

  return {
    tokens,
    characters,
    words,
    avgCharsPerToken: tokens > 0 ? (characters / tokens).toFixed(2) : 0,
    avgWordsPerToken: tokens > 0 ? (words / tokens).toFixed(2) : 0,
    model,
    isClaudeAdjusted: isClaudeModel(model)
  };
}

/**
 * Clean up encoder resources
 */
function cleanup() {
  for (const encoder of encoderCache.values()) {
    try {
      encoder.free();
    } catch (error) {
      // Ignore cleanup errors
    }
  }
  encoderCache.clear();
}

// Export functions
module.exports = {
  countTokens,
  countMessages,
  estimateOutputTokens,
  truncateToTokens,
  getTokenStats,
  cleanup,
  MODEL_ENCODINGS,
  CLAUDE_ADJUSTMENT
};
