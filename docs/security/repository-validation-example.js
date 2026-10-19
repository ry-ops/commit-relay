/**
 * Repository Validation Security Example
 * 
 * This example demonstrates how the repository validation security control
 * prevents authenticated callers from executing untrusted code in workflows.
 */

// SCENARIO: Authenticated user attempts to execute conditional-deploy workflow

// ============================================================================
// CONFIGURATION (in .env file)
// ============================================================================
// TRUSTED_REPOSITORY_PATTERNS=https://github.com/my-org/*,https://gitlab.com/trusted-group/*

// ============================================================================
// EXAMPLE 1: Trusted Repository - ALLOWED
// ============================================================================
const trustedRequest = {
  method: 'POST',
  url: '/api/v1/workflows/conditional-deploy/execute',
  headers: {
    'X-API-Key': 'valid-api-key',
    'Content-Type': 'application/json'
  },
  body: {
    inputs: {
      repository_url: 'https://github.com/my-org/my-app',
      branch: 'main',
      deploy_env: 'staging'
    }
  }
};

// RESPONSE: 200 OK
// {
//   "success": true,
//   "data": {
//     "execution_id": "exec-conditional-deploy-1234567890-abc123",
//     "status": "running",
//     ...
//   }
// }

// ============================================================================
// EXAMPLE 2: Untrusted Repository - BLOCKED
// ============================================================================
const untrustedRequest = {
  method: 'POST',
  url: '/api/v1/workflows/conditional-deploy/execute',
  headers: {
    'X-API-Key': 'valid-api-key',
    'Content-Type': 'application/json'
  },
  body: {
    inputs: {
      repository_url: 'https://github.com/attacker/malicious-repo',
      branch: 'main',
      deploy_env: 'staging'
    }
  }
};

// RESPONSE: 403 Forbidden
// {
//   "success": false,
//   "error": "Untrusted repository source",
//   "message": "Untrusted repository URLs detected in workflow inputs: repository_url",
//   "details": [
//     {
//       "field": "repository_url",
//       "value": "https://github.com/attacker/malicious-repo",
//       "reason": "Repository URL is not from a trusted source. Only repositories matching TRUSTED_REPOSITORY_PATTERNS are allowed."
//     }
//   ],
//   "help": "Only repositories matching TRUSTED_REPOSITORY_PATTERNS environment variable are allowed. Contact your administrator to add trusted repositories."
// }

// ============================================================================
// EXAMPLE 3: Check Configured Patterns (Admin)
// ============================================================================
const checkPatternsRequest = {
  method: 'GET',
  url: '/api/v1/workflows/security/repository-patterns',
  headers: {
    'X-API-Key': 'valid-api-key'
  }
};

// RESPONSE: 200 OK
// {
//   "success": true,
//   "data": {
//     "patterns": [
//       "^https://github\\.com/my-org/.*$",
//       "^https://gitlab\\.com/trusted-group/.*$"
//     ],
//     "count": 2,
//     "configured": true,
//     "warning": null
//   }
// }

// ============================================================================
// SECURITY IMPACT
// ============================================================================
// 
// BEFORE FIX:
// - Authenticated caller could supply any repository URL
// - Workflow would clone and execute code from that repository
// - npm ci, npm test, npm run build would execute attacker-controlled code
// - Commands run in coordinator trust zone with full privileges
// - Result: Authenticated arbitrary code execution
//
// AFTER FIX:
// - Repository URL validated against TRUSTED_REPOSITORY_PATTERNS
// - Only allowlisted repositories can be executed
// - Untrusted repositories rejected with 403 Forbidden
// - Execution blocked before any cloning or code execution
// - Result: Trust boundary enforced at entry point

// ============================================================================
// DEPLOYMENT CHECKLIST
// ============================================================================
// 
// 1. Set TRUSTED_REPOSITORY_PATTERNS in .env:
//    TRUSTED_REPOSITORY_PATTERNS=https://github.com/your-org/*
//
// 2. Restart API server to load new configuration
//
// 3. Verify configuration:
//    curl -H "X-API-Key: $API_KEY" http://localhost:5001/api/v1/workflows/security/repository-patterns
//
// 4. Test with trusted repository (should succeed):
//    curl -X POST -H "X-API-Key: $API_KEY" -H "Content-Type: application/json" \
//      -d '{"inputs":{"repository_url":"https://github.com/your-org/your-repo","branch":"main"}}' \
//      http://localhost:5001/api/v1/workflows/conditional-deploy/execute
//
// 5. Test with untrusted repository (should fail with 403):
//    curl -X POST -H "X-API-Key: $API_KEY" -H "Content-Type: application/json" \
//      -d '{"inputs":{"repository_url":"https://github.com/attacker/evil-repo","branch":"main"}}' \
//      http://localhost:5001/api/v1/workflows/conditional-deploy/execute

module.exports = {
  trustedRequest,
  untrustedRequest,
  checkPatternsRequest
};
