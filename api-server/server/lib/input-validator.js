/**
 * Input Validation Utility for Workflow Inputs
 * Prevents command injection by validating and sanitizing workflow inputs
 */

/**
 * Escape a string for safe use in shell commands
 * Uses single-quote escaping which is the safest method for arbitrary strings
 * @param {string} str - The string to escape
 * @returns {string} - Shell-escaped string
 */
function escapeShellArg(str) {
  if (str === null || str === undefined) {
    return "''";
  }
  
  // Convert to string
  const s = String(str);
  
  // Replace each single quote with '\'' (end quote, escaped quote, start quote)
  // Then wrap the whole thing in single quotes
  return "'" + s.replace(/'/g, "'\\''") + "'";
}

/**
 * Validate that a string is safe for use in shell commands
 * Checks for common shell metacharacters that could enable command injection
 * @param {string} str - The string to validate
 * @returns {boolean} - True if safe, false if contains dangerous characters
 */
function isShellSafe(str) {
  if (typeof str !== 'string') {
    return false;
  }
  
  // Check for shell metacharacters and control characters
  // This includes: ; & | ` $ ( ) < > \n \r \t and other dangerous patterns
  const dangerousPattern = /[;&|`$()<>\n\r\t\\!{}[\]*?~^]/;
  
  return !dangerousPattern.test(str);
}

/**
 * Validate a Git URL
 * Allows common Git URL formats while preventing command injection
 * @param {string} url - The URL to validate
 * @returns {boolean} - True if valid Git URL format
 */
function isValidGitUrl(url) {
  if (typeof url !== 'string' || url.length === 0) {
    return false;
  }
  
  // Allow HTTPS, SSH, and git:// protocols
  // Must not contain shell metacharacters
  const gitUrlPattern = /^(https?:\/\/|git@|git:\/\/)[a-zA-Z0-9._\-@:\/]+\.git$/;
  
  // Also check it doesn't contain dangerous characters
  if (!isShellSafe(url)) {
    return false;
  }
  
  return gitUrlPattern.test(url) || 
         /^https?:\/\/[a-zA-Z0-9._\-@:\/]+$/.test(url) ||
         /^git@[a-zA-Z0-9._\-]+:[a-zA-Z0-9._\-\/]+$/.test(url);
}

/**
 * Validate a Git branch or tag name
 * Follows Git's branch naming rules and prevents command injection
 * @param {string} branch - The branch name to validate
 * @returns {boolean} - True if valid branch name
 */
function isValidGitRef(branch) {
  if (typeof branch !== 'string' || branch.length === 0) {
    return false;
  }
  
  // Git branch names can contain alphanumeric, hyphens, underscores, slashes, and dots
  // But cannot start with a dot or hyphen, and cannot contain certain patterns
  const validPattern = /^[a-zA-Z0-9][a-zA-Z0-9._\/-]*$/;
  
  // Check for invalid patterns
  const invalidPatterns = [
    /\.\./,           // No double dots
    /\/\//,           // No double slashes
    /^\/|\/$/,        // No leading/trailing slashes
    /@\{/,            // No @{ sequence
    /[\x00-\x1f\x7f]/, // No control characters
    /[;&|`$()<>\\!{}[\]*?~^]/ // No shell metacharacters
  ];
  
  if (!validPattern.test(branch)) {
    return false;
  }
  
  for (const pattern of invalidPatterns) {
    if (pattern.test(branch)) {
      return false;
    }
  }
  
  return true;
}

/**
 * Validate workflow inputs based on their expected types and usage
 * @param {Object} inputs - The inputs object to validate
 * @param {Object} inputSchema - The workflow's input schema definition
 * @returns {Object} - { valid: boolean, errors: string[] }
 */
function validateWorkflowInputs(inputs, inputSchema) {
  const errors = [];
  
  if (!inputs || typeof inputs !== 'object') {
    return { valid: false, errors: ['Inputs must be an object'] };
  }
  
  if (!inputSchema || typeof inputSchema !== 'object') {
    // If no schema, apply basic validation to all string inputs
    for (const [key, value] of Object.entries(inputs)) {
      if (typeof value === 'string' && !isShellSafe(value)) {
        errors.push(`Input '${key}' contains potentially dangerous characters`);
      }
    }
    return { valid: errors.length === 0, errors };
  }
  
  // Validate each input according to its schema
  for (const [key, config] of Object.entries(inputSchema)) {
    const value = inputs[key];
    
    // Skip if not provided and not required
    if (value === undefined || value === null) {
      continue;
    }
    
    // Type-specific validation
    if (config.type === 'string') {
      if (typeof value !== 'string') {
        errors.push(`Input '${key}' must be a string`);
        continue;
      }
      
      // Special validation for known dangerous fields
      if (key === 'repository_url' || key.includes('repo') || key.includes('url')) {
        if (!isValidGitUrl(value)) {
          errors.push(`Input '${key}' is not a valid Git URL or contains dangerous characters`);
        }
      } else if (key === 'branch' || key === 'base_branch' || key.includes('branch') || key === 'tag') {
        if (!isValidGitRef(value)) {
          errors.push(`Input '${key}' is not a valid Git reference or contains dangerous characters`);
        }
      } else {
        // For other string inputs, check for shell metacharacters
        if (!isShellSafe(value)) {
          errors.push(`Input '${key}' contains potentially dangerous characters`);
        }
      }
      
      // Check enum constraints
      if (config.enum && !config.enum.includes(value)) {
        errors.push(`Input '${key}' must be one of: ${config.enum.join(', ')}`);
      }
    } else if (config.type === 'number') {
      if (typeof value !== 'number' || isNaN(value)) {
        errors.push(`Input '${key}' must be a number`);
      }
    } else if (config.type === 'boolean') {
      if (typeof value !== 'boolean') {
        errors.push(`Input '${key}' must be a boolean`);
      }
    }
  }
  
  return { valid: errors.length === 0, errors };
}

module.exports = {
  escapeShellArg,
  isShellSafe,
  isValidGitUrl,
  isValidGitRef,
  validateWorkflowInputs
};
