/**
 * MCP Resources for Commit-Relay
 *
 * Resources provide read-only access to commit-relay data
 * via the Model Context Protocol.
 */

const fs = require('fs').promises;
const path = require('path');

// Resource URI scheme: commit-relay://resource-type/path

const resourceDefinitions = [
  {
    uri: 'commit-relay://coordination/worker-pool',
    name: 'Worker Pool',
    description: 'Current worker pool state including active, completed, and failed workers',
    mimeType: 'application/json'
  },
  {
    uri: 'commit-relay://coordination/task-queue',
    name: 'Task Queue',
    description: 'Task queue with all pending, in-progress, and completed tasks',
    mimeType: 'application/json'
  },
  {
    uri: 'commit-relay://coordination/system-health',
    name: 'System Health',
    description: 'Overall system health status and daemon states',
    mimeType: 'application/json'
  },
  {
    uri: 'commit-relay://coordination/token-budget',
    name: 'Token Budget',
    description: 'Token usage and budget allocation across masters and workers',
    mimeType: 'application/json'
  },
  {
    uri: 'commit-relay://coordination/routing-patterns',
    name: 'Routing Patterns',
    description: 'MoE routing patterns and expert activation keywords',
    mimeType: 'application/json'
  },
  {
    uri: 'commit-relay://coordination/pool-state',
    name: 'Pool State',
    description: 'Sparse pool manager state with capacity and activation metrics',
    mimeType: 'application/json'
  },
  {
    uri: 'commit-relay://governance/access-policies',
    name: 'Access Policies',
    description: 'RBAC access policies and namespace permissions',
    mimeType: 'application/json'
  },
  {
    uri: 'commit-relay://masters/coordinator/state',
    name: 'Coordinator State',
    description: 'Coordinator master current state and routing statistics',
    mimeType: 'application/json'
  },
  {
    uri: 'commit-relay://manifests/index',
    name: 'Master Manifests Index',
    description: 'Index of all master agent capability manifests',
    mimeType: 'application/json'
  },
  {
    uri: 'commit-relay://manifests/coordinator',
    name: 'Coordinator Manifest',
    description: 'Capability manifest for the Coordinator Master',
    mimeType: 'application/json'
  },
  {
    uri: 'commit-relay://manifests/security',
    name: 'Security Manifest',
    description: 'Capability manifest for the Security Master',
    mimeType: 'application/json'
  },
  {
    uri: 'commit-relay://manifests/development',
    name: 'Development Manifest',
    description: 'Capability manifest for the Development Master',
    mimeType: 'application/json'
  },
  {
    uri: 'commit-relay://manifests/inventory',
    name: 'Inventory Manifest',
    description: 'Capability manifest for the Inventory Master',
    mimeType: 'application/json'
  },
  {
    uri: 'commit-relay://manifests/cicd',
    name: 'CI/CD Manifest',
    description: 'Capability manifest for the CI/CD Master',
    mimeType: 'application/json'
  }
];

// Map URIs to file paths
const uriToPath = {
  'commit-relay://coordination/worker-pool': 'coordination/worker-pool.json',
  'commit-relay://coordination/task-queue': 'coordination/task-queue.json',
  'commit-relay://coordination/system-health': 'coordination/system-health-check.json',
  'commit-relay://coordination/token-budget': 'coordination/token-budget.json',
  'commit-relay://coordination/routing-patterns': 'coordination/masters/coordinator/knowledge-base/routing-patterns.json',
  'commit-relay://coordination/pool-state': 'coordination/memory/working/pool-state.json',
  'commit-relay://governance/access-policies': 'coordination/governance/access-policies.json',
  'commit-relay://masters/coordinator/state': 'coordination/masters/coordinator/context/master-state.json',
  'commit-relay://manifests/index': 'mcp-server/manifests/index.json',
  'commit-relay://manifests/coordinator': 'mcp-server/manifests/coordinator-master.json',
  'commit-relay://manifests/security': 'mcp-server/manifests/security-master.json',
  'commit-relay://manifests/development': 'mcp-server/manifests/development-master.json',
  'commit-relay://manifests/inventory': 'mcp-server/manifests/inventory-master.json',
  'commit-relay://manifests/cicd': 'mcp-server/manifests/cicd-master.json'
};

module.exports = {
  getResourceDefinitions: (home) => {
    return resourceDefinitions;
  },

  readResource: async (uri, home) => {
    const relativePath = uriToPath[uri];

    if (!relativePath) {
      throw new Error(`Unknown resource URI: ${uri}`);
    }

    const fullPath = path.join(home, relativePath);

    try {
      const data = await fs.readFile(fullPath, 'utf8');
      return JSON.parse(data);
    } catch (error) {
      if (error.code === 'ENOENT') {
        throw new Error(`Resource not found: ${uri}`);
      }
      throw new Error(`Failed to read resource: ${error.message}`);
    }
  }
};
