/**
 * Repository Validator
 * 
 * SECURITY MITIGATION: Prevents authenticated arbitrary code execution in coordinator trust zone
 * 
 * VULNERABILITY CONTEXT:
 * The conditional-deploy workflow and similar workflows accept caller-selected repository URLs
 * and branches as inputs, then clone that source and execute repository-controlled code through:
 * - npm ci / pip install (package lifecycle hooks)
 * - npm test / pytest (test scripts)
 * - npm run build (build scripts)
 * 
 * These operations run in an unsandboxed bash shell with the coordinator's working directory,
 * inherited process environment, and service account privileges. Without repository validation,
 * an authenticated caller can supply a malicious repository URL and execute arbitrary commands
 * in the coordinator trust zone.
 * 
 * MITIGATION STRATEGY:
 * This validator implements a repository allowlist that restricts workflow execution to only
 * repositories matching configured trusted patterns. The validation occurs at the workflow
 * execution entry point (POST /api/v1/workflows/:name/execute) before any repository cloning
 * or code execution begins.
 * 
 * CONFIGURATION:
 * Set TRUSTED_REPOSITORY_PATTERNS environment variable with comma-separated patterns:
 *   TRUSTED_REPOSITORY_PATTERNS=https://github.com/your-org/*,https://gitlab.com/trusted-group/*
 * 
 * Supports wildcards (*) for flexible matching while maintaining security boundaries.
 * 
 * DEFENSE IN DEPTH:
 * This is the primary control for this trust boundary issue. Additional recommended controls:
 * - Container/VM isolation for workflow execution (not currently implemented)
 * - Privilege reduction for executor processes (not currently implemented)
 * - Network policies to restrict outbound access (not currently implemented)
 * - Filesystem restrictions/chroot (not currently implemented)
 * 
 * @module repository-validator
 * @security-control Repository Authorization
 */

const { URL } = require('url');

class RepositoryValidator {
  constructor() {
    // Load trusted repository patterns from environment
    this.trustedPatterns = this._loadTrustedPatterns();
  }

  /**
   * Load trusted repository patterns from environment variable
   * @returns {Array<RegExp>} Array of regex patterns for trusted repositories
   * @private
   */
  _loadTrustedPatterns() {
    const patternsEnv = process.env.TRUSTED_REPOSITORY_PATTERNS;
    
    if (!patternsEnv) {
      console.warn('⚠️  WARNING: TRUSTED_REPOSITORY_PATTERNS not configured. Repository validation will deny all external repositories.');
      return [];
    }

    try {
      // Parse comma-separated patterns
      const patterns = patternsEnv.split(',').map(p => p.trim()).filter(p => p.length > 0);
      
      // Convert to regex patterns
      const regexPatterns = patterns.map(pattern => {
        // Escape special regex characters except * which we'll convert to .*
        const escaped = pattern
          .replace(/[.+?^${}()|[\]\\]/g, '\\$&')
          .replace(/\*/g, '.*');
        
        return new RegExp(`^${escaped}$`, 'i');
      });

      console.log(`✅ Loaded ${regexPatterns.length} trusted repository patterns`);
      return regexPatterns;
    } catch (error) {
      console.error('❌ Error parsing TRUSTED_REPOSITORY_PATTERNS:', error.message);
      return [];
    }
  }

  /**
   * Validate that a repository URL is from a trusted source
   * @param {string} repositoryUrl - Repository URL to validate
   * @returns {Object} Validation result with { valid: boolean, reason?: string }
   */
  validateRepository(repositoryUrl) {
    if (!repositoryUrl || typeof repositoryUrl !== 'string') {
      return {
        valid: false,
        reason: 'Repository URL is required and must be a string'
      };
    }

    // Normalize the URL
    const normalizedUrl = this._normalizeRepositoryUrl(repositoryUrl);
    
    if (!normalizedUrl) {
      return {
        valid: false,
        reason: 'Invalid repository URL format'
      };
    }

    // Check if URL matches any trusted pattern
    const isTrusted = this.trustedPatterns.some(pattern => pattern.test(normalizedUrl));

    if (!isTrusted) {
      return {
        valid: false,
        reason: 'Repository URL is not from a trusted source. Only repositories matching TRUSTED_REPOSITORY_PATTERNS are allowed.'
      };
    }

    return { valid: true };
  }

  /**
   * Normalize repository URL for consistent validation
   * Handles various Git URL formats (HTTPS, SSH, git://)
   * @param {string} url - Repository URL
   * @returns {string|null} Normalized URL or null if invalid
   * @private
   */
  _normalizeRepositoryUrl(url) {
    try {
      // Handle SSH URLs (git@github.com:user/repo.git)
      if (url.startsWith('git@')) {
        const match = url.match(/^git@([^:]+):(.+)$/);
        if (match) {
          return `https://${match[1]}/${match[2].replace(/\.git$/, '')}`;
        }
        return null;
      }

      // Handle git:// protocol
      if (url.startsWith('git://')) {
        return url.replace(/^git:\/\//, 'https://').replace(/\.git$/, '');
      }

      // Handle HTTPS URLs
      if (url.startsWith('https://') || url.startsWith('http://')) {
        const parsed = new URL(url);
        // Reconstruct as https with normalized path
        return `https://${parsed.hostname}${parsed.pathname.replace(/\.git$/, '')}`;
      }

      return null;
    } catch (error) {
      return null;
    }
  }

  /**
   * Validate workflow inputs for repository URLs
   * Checks common input field names that might contain repository URLs
   * @param {Object} inputs - Workflow inputs object
   * @returns {Object} Validation result with { valid: boolean, invalidFields?: Array, reason?: string }
   */
  validateWorkflowInputs(inputs) {
    if (!inputs || typeof inputs !== 'object') {
      return { valid: true }; // No inputs to validate
    }

    // Common field names that might contain repository URLs
    const repositoryFields = [
      'repository_url',
      'repository',
      'repo_url',
      'repo',
      'git_url',
      'source_repository',
      'source_repo'
    ];

    const invalidFields = [];

    for (const field of repositoryFields) {
      if (inputs[field]) {
        const result = this.validateRepository(inputs[field]);
        if (!result.valid) {
          invalidFields.push({
            field,
            value: inputs[field],
            reason: result.reason
          });
        }
      }
    }

    if (invalidFields.length > 0) {
      return {
        valid: false,
        invalidFields,
        reason: `Untrusted repository URLs detected in workflow inputs: ${invalidFields.map(f => f.field).join(', ')}`
      };
    }

    return { valid: true };
  }

  /**
   * Get list of trusted patterns (for debugging/admin purposes)
   * @returns {Array<string>} Array of pattern strings
   */
  getTrustedPatterns() {
    return this.trustedPatterns.map(p => p.source);
  }
}

// Export singleton instance
module.exports = new RepositoryValidator();
