/**
 * Input Validation Middleware
 * Validates and sanitizes user input to prevent injection attacks
 */

const { body, param, validationResult } = require('express-validator');
const path = require('path');

/**
 * Middleware to check validation results
 */
const validate = (req, res, next) => {
  const errors = validationResult(req);
  if (!errors.isEmpty()) {
    return res.status(400).json({
      error: 'Validation failed',
      details: errors.array()
    });
  }
  next();
};

/**
 * Validate PID is a positive integer
 */
const validatePid = (pid) => {
  const parsedPid = parseInt(pid, 10);
  if (isNaN(parsedPid) || parsedPid <= 0 || parsedPid > 2147483647) {
    throw new Error('Invalid process ID');
  }
  return parsedPid;
};

/**
 * Validate file path is within allowed directory
 * Prevents path traversal attacks
 */
const validatePath = (userPath, baseDir) => {
  // Remove any null bytes
  const sanitized = userPath.replace(/\0/g, '');

  // Resolve to absolute path
  const resolved = path.resolve(baseDir, sanitized);
  const base = path.resolve(baseDir);

  // Ensure resolved path starts with base directory
  if (!resolved.startsWith(base + path.sep) && resolved !== base) {
    throw new Error('Invalid path: outside allowed directory');
  }

  return resolved;
};

/**
 * Sanitize worker ID - only alphanumeric, hyphens, underscores
 */
const sanitizeWorkerId = (workerId) => {
  const sanitized = workerId.replace(/[^a-zA-Z0-9\-_]/g, '');
  if (sanitized !== workerId) {
    throw new Error('Invalid worker ID format');
  }
  if (sanitized.length === 0 || sanitized.length > 100) {
    throw new Error('Worker ID length must be 1-100 characters');
  }
  return sanitized;
};

/**
 * Sanitize alert ID
 */
const sanitizeAlertId = (alertId) => {
  const sanitized = alertId.replace(/[^a-zA-Z0-9\-_]/g, '');
  if (sanitized !== alertId || sanitized.length === 0 || sanitized.length > 100) {
    throw new Error('Invalid alert ID format');
  }
  return sanitized;
};

/**
 * Validation rules for DDQD test endpoint
 */
const ddqdValidationRules = [
  body('duration')
    .isInt({ min: 1, max: 1440 })
    .withMessage('Duration must be between 1 and 1440 minutes'),
  body('maxWorkers')
    .optional()
    .isInt({ min: 1, max: 100 })
    .withMessage('Max workers must be between 1 and 100'),
  body('version')
    .isIn(['v4', 'v5'])
    .withMessage('Version must be v4 or v5'),
  body('verbose')
    .optional()
    .isBoolean()
    .withMessage('Verbose must be a boolean')
];

/**
 * Validation rules for daemon control
 */
const daemonControlValidationRules = [
  body('action')
    .isIn(['start', 'stop', 'restart'])
    .withMessage('Action must be start, stop, or restart')
];

/**
 * Validation rules for alert resolution
 */
const alertResolutionValidationRules = [
  param('id')
    .isLength({ min: 1, max: 100 })
    .matches(/^[a-zA-Z0-9\-_]+$/)
    .withMessage('Invalid alert ID format'),
  body('resolution_note')
    .optional()
    .isString()
    .isLength({ max: 1000 })
    .withMessage('Resolution note must be a string (max 1000 chars)')
];

/**
 * Validation rules for worker restart
 */
const workerRestartValidationRules = [
  param('id')
    .isLength({ min: 1, max: 100 })
    .matches(/^[a-zA-Z0-9\-_]+$/)
    .withMessage('Invalid alert ID format')
];

module.exports = {
  validate,
  validatePid,
  validatePath,
  sanitizeWorkerId,
  sanitizeAlertId,
  ddqdValidationRules,
  daemonControlValidationRules,
  alertResolutionValidationRules,
  workerRestartValidationRules
};
