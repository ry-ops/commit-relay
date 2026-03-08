/**
 * Elastic APM Initialization Module
 *
 * This module initializes the Elastic APM agent for the commit-relay API server.
 * It must be loaded before any other modules to ensure full instrumentation.
 *
 * Configuration is done via environment variables:
 * - ELASTIC_APM_ENABLED: Enable/disable APM (default: false)
 * - ELASTIC_APM_SERVICE_NAME: Service name in APM (default: commit-relay)
 * - ELASTIC_APM_SERVER_URL: APM Server URL
 * - ELASTIC_APM_SECRET_TOKEN: Authentication token for APM Server
 * - ELASTIC_APM_ENVIRONMENT: Environment name (e.g., production, staging, development)
 * - ELASTIC_APM_LOG_LEVEL: Agent log level (default: info)
 * - ELASTIC_APM_CAPTURE_BODY: Capture request/response bodies (default: errors)
 * - ELASTIC_APM_TRANSACTION_SAMPLE_RATE: Sample rate for transactions (default: 1.0)
 */

// Load environment variables first
require('dotenv').config();

// Check if APM is enabled
const isEnabled = process.env.ELASTIC_APM_ENABLED === 'true';

if (!isEnabled) {
  console.log('[APM] Elastic APM is disabled (ELASTIC_APM_ENABLED=false)');
  module.exports = null;
} else {
  // Validate required configuration
  const serviceName = process.env.ELASTIC_APM_SERVICE_NAME || 'commit-relay';
  const serverUrl = process.env.ELASTIC_APM_SERVER_URL;
  const secretToken = process.env.ELASTIC_APM_SECRET_TOKEN;
  const apiKey = process.env.ELASTIC_APM_API_KEY;
  const environment = process.env.ELASTIC_APM_ENVIRONMENT || process.env.NODE_ENV || 'development';

  if (!serverUrl) {
    console.warn('[APM] Elastic APM is enabled but ELASTIC_APM_SERVER_URL is not set. APM will not work.');
    module.exports = null;
  } else if (!secretToken && !apiKey) {
    console.warn('[APM] Elastic APM is enabled but neither ELASTIC_APM_SECRET_TOKEN nor ELASTIC_APM_API_KEY is set. APM will not work.');
    module.exports = null;
  } else {
    try {
      // Initialize APM agent with either API Key (for Serverless) or Secret Token (for traditional)
      const apmConfig = {
        // Service identification
        serviceName: serviceName,
        serverUrl: serverUrl,
        environment: environment,

        // Authentication (API Key for Serverless, Secret Token for traditional)
        ...(apiKey ? { apiKey: apiKey } : { secretToken: secretToken }),

        // Logging configuration
        logLevel: process.env.ELASTIC_APM_LOG_LEVEL || 'info',

        // Capture configuration
        captureBody: process.env.ELASTIC_APM_CAPTURE_BODY || 'errors',
        captureHeaders: true,
        captureErrorLogStackTraces: 'always',

        // Sampling configuration
        transactionSampleRate: parseFloat(process.env.ELASTIC_APM_TRANSACTION_SAMPLE_RATE || '1.0'),

        // Framework-specific options
        captureExceptions: true,
        captureSpanStackTraces: true,

        // Performance options
        metricsInterval: '30s',
        centralConfig: false,

        // Custom context
        globalLabels: {
          'service.type': 'api-server',
          'deployment.environment': environment
        }
      };

      const apm = require('elastic-apm-node').start(apmConfig);

      console.log(`[APM] Elastic APM initialized successfully`);
      console.log(`[APM]   Service: ${serviceName}`);
      console.log(`[APM]   Environment: ${environment}`);
      console.log(`[APM]   Server: ${serverUrl}`);
      console.log(`[APM]   Auth: ${apiKey ? 'API Key (Serverless)' : 'Secret Token'}`);
      console.log(`[APM]   Sample Rate: ${process.env.ELASTIC_APM_TRANSACTION_SAMPLE_RATE || '1.0'}`);

      // Export APM instance for use in application
      module.exports = apm;
    } catch (error) {
      console.error('[APM] Failed to initialize Elastic APM:', error.message);
      console.error('[APM] Application will continue without APM');
      module.exports = null;
    }
  }
}
