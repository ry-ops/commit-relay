/**
 * API Version 1 Router - Phase 3 Item 31
 * Provides versioned API endpoints with backward compatibility
 */

const express = require('express');
const router = express.Router();

/**
 * API Version 1 wrapper
 *
 * This module provides the /api/v1/ prefix for all API endpoints.
 * It maintains backward compatibility with existing /api/ routes
 * while enabling future API versioning.
 *
 * Usage in index.js:
 *   const apiV1Router = require('./routes/api-v1');
 *   app.use('/api/v1', apiV1Router);
 *
 *   // Backward compatibility - redirect old routes to v1
 *   app.use('/api', (req, res, next) => {
 *     if (!req.path.startsWith('/v1') && !req.path.startsWith('/docs')) {
 *       req.url = `/v1${req.url}`;
 *     }
 *     next();
 *   });
 */

// Version metadata
const API_VERSION = '1.0.0';
const API_VERSION_DEPRECATED = false;
const API_VERSION_SUNSET = null;

/**
 * Version information middleware
 * Adds version headers to all responses
 */
router.use((req, res, next) => {
  res.setHeader('X-API-Version', API_VERSION);

  if (API_VERSION_DEPRECATED) {
    res.setHeader('Deprecation', 'true');
    if (API_VERSION_SUNSET) {
      res.setHeader('Sunset', API_VERSION_SUNSET);
    }
  }

  next();
});

/**
 * GET /api/v1/version
 * Returns API version information
 */
router.get('/version', (req, res) => {
  res.json({
    version: API_VERSION,
    deprecated: API_VERSION_DEPRECATED,
    sunset: API_VERSION_SUNSET,
    supported_versions: ['v1'],
    latest_version: 'v1',
    documentation: '/api/docs/ui'
  });
});

/**
 * Health check for versioned API
 * GET /api/v1/health
 */
router.get('/health', (req, res) => {
  res.json({
    status: 'healthy',
    version: API_VERSION,
    timestamp: new Date().toISOString()
  });
});

/**
 * Export configuration for the main server to use
 * The actual route handlers are in index.js
 * This router provides the versioning wrapper
 */

// Forward all other requests to main handlers
// These will be set up in index.js to connect to existing endpoints
router.all('/*', (req, res, next) => {
  // Mark request as coming through versioned API
  req.apiVersion = 'v1';
  next('route');
});

// Export version info for other modules
router.API_VERSION = API_VERSION;
router.API_VERSION_DEPRECATED = API_VERSION_DEPRECATED;
router.API_VERSION_SUNSET = API_VERSION_SUNSET;

module.exports = router;
