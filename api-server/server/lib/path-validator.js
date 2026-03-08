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

module.exports = {
  sanitizeFilename,
  isPathWithinDirectory,
  safeJoin,
  validateId,
  validateDateString
};
