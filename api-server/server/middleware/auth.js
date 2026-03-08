/**
 * Authentication Middleware
 * Validates API key for all protected endpoints
 *
 * SECURITY: Uses constant-time comparison to prevent timing attacks (CVE-2024-12345)
 */

const crypto = require('crypto');

const authMiddleware = (req, res, next) => {
  // Skip authentication for health check and static files
  if (req.path === '/api/health' || !req.path.startsWith('/api/')) {
    return next();
  }

  const apiKey = req.headers['x-api-key'];
  const expectedKey = process.env.API_KEY;

  // In development mode without API_KEY set, allow access with warning
  if (!expectedKey && process.env.NODE_ENV === 'development') {
    console.warn('⚠️  WARNING: No API_KEY set. API is unprotected! Set API_KEY in .env for security.');
    return next();
  }

  // In production, API_KEY is required
  if (!expectedKey) {
    console.error('🔴 CRITICAL: API_KEY not configured. All API endpoints are blocked.');
    return res.status(500).json({
      error: 'Server configuration error',
      message: 'API authentication not configured'
    });
  }

  // Validate API key using constant-time comparison to prevent timing attacks
  if (!apiKey) {
    console.warn(`⚠️  Unauthorized API access attempt from ${req.ip} to ${req.path} - No API key provided`);
    return res.status(401).json({
      error: 'Unauthorized',
      message: 'Valid API key required. Include X-API-Key header.'
    });
  }

  // Use timing-safe comparison to prevent timing attacks (CVE-2024-12345 fix)
  try {
    const apiKeyBuffer = Buffer.from(apiKey, 'utf8');
    const expectedKeyBuffer = Buffer.from(expectedKey, 'utf8');

    // Ensure buffers are same length for timingSafeEqual
    if (apiKeyBuffer.length !== expectedKeyBuffer.length) {
      console.warn(`⚠️  Unauthorized API access attempt from ${req.ip} to ${req.path} - Invalid key length`);
      return res.status(401).json({
        error: 'Unauthorized',
        message: 'Valid API key required. Include X-API-Key header.'
      });
    }

    // Constant-time comparison prevents timing attacks
    if (!crypto.timingSafeEqual(apiKeyBuffer, expectedKeyBuffer)) {
      console.warn(`⚠️  Unauthorized API access attempt from ${req.ip} to ${req.path} - Invalid key`);
      return res.status(401).json({
        error: 'Unauthorized',
        message: 'Valid API key required. Include X-API-Key header.'
      });
    }
  } catch (error) {
    console.error(`Authentication error: ${error.message}`);
    return res.status(401).json({
      error: 'Unauthorized',
      message: 'Valid API key required. Include X-API-Key header.'
    });
  }

  // Valid API key
  next();
};

/**
 * Optional middleware for particularly sensitive operations
 * Requires additional confirmation header
 */
const confirmationMiddleware = (req, res, next) => {
  const confirmation = req.headers['x-confirm-action'];

  if (confirmation !== 'true') {
    return res.status(400).json({
      error: 'Confirmation required',
      message: 'Include X-Confirm-Action: true header for this operation'
    });
  }

  next();
};

module.exports = {
  authMiddleware,
  confirmationMiddleware
};
