/**
 * API Documentation Routes - Phase 3 Item 32
 * Serves OpenAPI specification and documentation
 */

const express = require('express');
const router = express.Router();
const path = require('path');
const fs = require('fs');

// Load OpenAPI spec
const openApiPath = path.join(__dirname, '..', 'openapi.json');
let openApiSpec = null;

try {
  openApiSpec = JSON.parse(fs.readFileSync(openApiPath, 'utf8'));
} catch (err) {
  console.error('Failed to load OpenAPI spec:', err.message);
}

/**
 * GET /api/docs
 * Returns the OpenAPI specification
 */
router.get('/', (req, res) => {
  if (!openApiSpec) {
    return res.status(500).json({
      error: 'OpenAPI specification not available'
    });
  }
  res.json(openApiSpec);
});

/**
 * GET /api/docs/openapi.json
 * Returns raw OpenAPI JSON
 */
router.get('/openapi.json', (req, res) => {
  if (!openApiSpec) {
    return res.status(500).json({
      error: 'OpenAPI specification not available'
    });
  }
  res.setHeader('Content-Type', 'application/json');
  res.json(openApiSpec);
});

/**
 * GET /api/docs/openapi.yaml
 * Returns OpenAPI in YAML format
 */
router.get('/openapi.yaml', (req, res) => {
  if (!openApiSpec) {
    return res.status(500).json({
      error: 'OpenAPI specification not available'
    });
  }

  // Simple JSON to YAML conversion
  const yaml = jsonToYaml(openApiSpec);
  res.setHeader('Content-Type', 'text/yaml');
  res.send(yaml);
});

/**
 * GET /api/docs/ui
 * Returns Swagger UI HTML page
 */
router.get('/ui', (req, res) => {
  const swaggerUiHtml = `
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Commit-Relay API Documentation</title>
  <link rel="stylesheet" type="text/css" href="https://unpkg.com/swagger-ui-dist@5.9.0/swagger-ui.css">
  <style>
    body {
      margin: 0;
      padding: 0;
    }
    .swagger-ui .topbar {
      background-color: #1a1a2e;
    }
    .swagger-ui .info .title {
      color: #333;
    }
  </style>
</head>
<body>
  <div id="swagger-ui"></div>
  <script src="https://unpkg.com/swagger-ui-dist@5.9.0/swagger-ui-bundle.js"></script>
  <script src="https://unpkg.com/swagger-ui-dist@5.9.0/swagger-ui-standalone-preset.js"></script>
  <script>
    window.onload = function() {
      const ui = SwaggerUIBundle({
        url: "/api/docs/openapi.json",
        dom_id: '#swagger-ui',
        deepLinking: true,
        presets: [
          SwaggerUIBundle.presets.apis,
          SwaggerUIStandalonePreset
        ],
        plugins: [
          SwaggerUIBundle.plugins.DownloadUrl
        ],
        layout: "StandaloneLayout"
      });
      window.ui = ui;
    };
  </script>
</body>
</html>
  `;
  res.setHeader('Content-Type', 'text/html');
  res.send(swaggerUiHtml);
});

/**
 * GET /api/docs/endpoints
 * Returns a simplified list of all endpoints
 */
router.get('/endpoints', (req, res) => {
  if (!openApiSpec) {
    return res.status(500).json({
      error: 'OpenAPI specification not available'
    });
  }

  const endpoints = [];

  for (const [path, methods] of Object.entries(openApiSpec.paths)) {
    for (const [method, details] of Object.entries(methods)) {
      endpoints.push({
        method: method.toUpperCase(),
        path: `/api/v1${path}`,
        summary: details.summary,
        tags: details.tags || [],
        operationId: details.operationId
      });
    }
  }

  res.json({
    total: endpoints.length,
    endpoints: endpoints.sort((a, b) => a.path.localeCompare(b.path))
  });
});

/**
 * Simple JSON to YAML converter
 */
function jsonToYaml(obj, indent = 0) {
  const spaces = '  '.repeat(indent);
  let yaml = '';

  if (Array.isArray(obj)) {
    for (const item of obj) {
      if (typeof item === 'object' && item !== null) {
        yaml += `${spaces}-\n${jsonToYaml(item, indent + 1)}`;
      } else {
        yaml += `${spaces}- ${formatYamlValue(item)}\n`;
      }
    }
  } else if (typeof obj === 'object' && obj !== null) {
    for (const [key, value] of Object.entries(obj)) {
      if (typeof value === 'object' && value !== null) {
        if (Array.isArray(value) && value.length === 0) {
          yaml += `${spaces}${key}: []\n`;
        } else if (Object.keys(value).length === 0) {
          yaml += `${spaces}${key}: {}\n`;
        } else {
          yaml += `${spaces}${key}:\n${jsonToYaml(value, indent + 1)}`;
        }
      } else {
        yaml += `${spaces}${key}: ${formatYamlValue(value)}\n`;
      }
    }
  }

  return yaml;
}

function formatYamlValue(value) {
  if (value === null) return 'null';
  if (typeof value === 'boolean') return value.toString();
  if (typeof value === 'number') return value.toString();
  if (typeof value === 'string') {
    // Quote strings with special characters
    if (value.includes(':') || value.includes('#') || value.includes('\n') ||
        value.startsWith(' ') || value.endsWith(' ')) {
      return `"${value.replace(/"/g, '\\"')}"`;
    }
    return value || '""';
  }
  return String(value);
}

module.exports = router;
