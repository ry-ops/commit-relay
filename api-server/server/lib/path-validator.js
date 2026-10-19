/**
 * Path Validation Utility
 * Prevents path traversal attacks by validating file paths
 */

const path = require('path');

/**
 * Sanitize and validate a filename to prevent path traversal
 * @param {string} filename - The filename to validate
 * @param {string[]} allowedExtensions - Optional array of allowed extensions
 * @returns {string|null} - Sanitized filename or null if invalid
 */
function sanitizeFilename(filename, allowedExtensions = []) {
  if (!filename || typeof filename !== 'string') {
    return null;
  }

  // Remove any path separators and null bytes
  const sanitized = filename
    .replace(/\.\./g, '')  // Remove ..
    .replace(/[/\\]/g, '') // Remove path separators
    .replace(/\0/g, '')    // Remove null bytes
    .replace(/^\.+/, '')   // Remove leading dots
    .trim();

  // Check if filename is empty after sanitization
  if (!sanitized || sanitized.length === 0) {
    return null;
  }

  // Check for allowed extensions if specified
  if (allowedExtensions.length > 0) {
    const ext = path.extname(sanitized);
    if (!allowedExtensions.includes(ext)) {
      return null;
    }
  }

  return sanitized;
}

/**
 * Validate that a resolved path is within an allowed directory
 * @param {string} filePath - The file path to validate
 * @param {string} allowedDir - The allowed base directory
 * @returns {boolean} - True if path is safe, false otherwise
 */
function isPathWithinDirectory(filePath, allowedDir) {
  const resolvedPath = path.resolve(filePath);
  const resolvedAllowedDir = path.resolve(allowedDir);

  // Check if resolved path starts with allowed directory
  return resolvedPath.startsWith(resolvedAllowedDir + path.sep) ||
         resolvedPath === resolvedAllowedDir;
}

/**
 * Safely join paths and validate the result
 * @param {string} baseDir - The base directory
 * @param {string} userPath - The user-provided path component
 * @returns {string|null} - Safe path or null if invalid
 */
function safeJoin(baseDir, userPath) {
  // Sanitize the user-provided path component
  const sanitized = sanitizeFilename(userPath);
  if (!sanitized) {
    return null;
  }

  // Join and resolve the path
  const joinedPath = path.join(baseDir, sanitized);

  // Validate it's within the base directory
  if (!isPathWithinDirectory(joinedPath, baseDir)) {
    return null;
  }

  return joinedPath;
}

/**
 * Validate an ID parameter (alphanumeric, hyphens, underscores only)
 * @param {string} id - The ID to validate
 * @returns {string|null} - Validated ID or null if invalid
 */
function validateId(id) {
  if (!id || typeof id !== 'string') {
    return null;
  }

  // Allow only alphanumeric, hyphens, and underscores
  if (!/^[a-zA-Z0-9_-]+$/.test(id)) {
    return null;
  }

  // Limit length to prevent DoS
  if (id.length > 255) {
    return null;
  }

  return id;
}

/**
 * Validate a date string (YYYY-MM-DD format)
 * @param {string} dateStr - The date string to validate
 * @returns {string|null} - Validated date string or null if invalid
 */
function validateDateString(dateStr) {
  if (!dateStr || typeof dateStr !== 'string') {
    return null;
  }

  // Validate YYYY-MM-DD format
  if (!/^\d{4}-\d{2}-\d{2}$/.test(dateStr)) {
    return null;
  }

  // Validate it's a real date
  const date = new Date(dateStr);
  if (isNaN(date.getTime())) {
    return null;
  }

  return dateStr;
}

/**
 * Validate a Git repository URL
 * Allows HTTPS and SSH URLs with standard Git hosting patterns
 * Rejects shell metacharacters that could enable command injection
 * @param {string} url - The repository URL to validate
 * @returns {string|null} - Validated URL or null if invalid
 */
function validateGitRepositoryUrl(url) {
  if (!url || typeof url !== 'string') {
    return null;
  }

  // Trim whitespace
  const trimmed = url.trim();

  // Reject empty strings
  if (trimmed.length === 0) {
    return null;
  }

  // Reject URLs that are too long (prevent DoS)
  if (trimmed.length > 2048) {
    return null;
  }

  // Reject shell metacharacters that could enable command injection
  // This includes: ; & | ` $ ( ) < > \n \r \t and other control characters
  if (/[;&|`$()<>\n\r\t\x00-\x1F\x7F]/.test(trimmed)) {
    return null;
  }

  // Validate against common Git URL patterns
  // HTTPS: https://github.com/user/repo.git or https://github.com/user/repo
  // SSH: git@github.com:user/repo.git
  // Also support other common Git hosting services
  const httpsPattern = /^https:\/\/[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*\/[a-zA-Z0-9._\/-]+\.git$/;
  const httpsPatternNoGit = /^https:\/\/[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*\/[a-zA-Z0-9._\/-]+$/;
  const sshPattern = /^git@[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*:[a-zA-Z0-9._\/-]+\.git$/;

  if (!httpsPattern.test(trimmed) && !httpsPatternNoGit.test(trimmed) && !sshPattern.test(trimmed)) {
    return null;
  }

  return trimmed;
}

/**
 * Validate a Git branch name
 * Follows Git branch naming rules and rejects shell metacharacters
 * @param {string} branch - The branch name to validate
 * @returns {string|null} - Validated branch name or null if invalid
 */
function validateGitBranch(branch) {
  if (!branch || typeof branch !== 'string') {
    return null;
  }

  // Trim whitespace
  const trimmed = branch.trim();

  // Reject empty strings
  if (trimmed.length === 0) {
    return null;
  }

  // Reject branches that are too long
  if (trimmed.length > 255) {
    return null;
  }

  // Reject shell metacharacters that could enable command injection
  if (/[;&|`$()<>\n\r\t\x00-\x1F\x7F]/.test(trimmed)) {
    return null;
  }

  // Git branch naming rules:
  // - Cannot start with a dot or hyphen
  // - Cannot contain: .. ~^ : ? * [ \ (space) @{ (consecutive)
  // - Cannot end with .lock or /
  // - Cannot be empty
  // Allow: alphanumeric, forward slash, hyphen, underscore, dot (not at start/end)
  if (/^[.-]/.test(trimmed)) {
    return null;
  }

  if (/\.lock$|[\/]$/.test(trimmed)) {
    return null;
  }

  if (/\.\.|\~|\^|:|\?|\*|\[|\\|\s|@\{/.test(trimmed)) {
    return null;
  }

  // Only allow safe characters: alphanumeric, /, -, _, .
  if (!/^[a-zA-Z0-9\/._-]+$/.test(trimmed)) {
    return null;
  }

  return trimmed;
}

module.exports = {
  sanitizeFilename,
  isPathWithinDirectory,
  safeJoin,
  validateId,
  validateDateString,
  validateGitRepositoryUrl,
  validateGitBranch
};
