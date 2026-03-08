#!/usr/bin/env node
// lib/governance/identity/capability-policy.js
// Capability-Based Access Control for Agent Identities

const fs = require('fs').promises;
const path = require('path');

/**
 * Capability Policy Engine
 *
 * Implements fine-grained, capability-based access control where:
 * - Each agent has explicit capabilities (e.g., "tasks:read", "workers:spawn")
 * - Wildcards supported (e.g., "security:*" grants all security capabilities)
 * - Least-privilege by default (deny unless explicitly granted)
 */

class CapabilityPolicy {
  constructor() {
    this.policiesPath = 'coordination/governance/capability-policies.json';

    // Standard capability categories
    this.capabilities = {
      // Task management
      'tasks:read': 'Read task specifications and status',
      'tasks:write': 'Create and modify tasks',
      'tasks:route': 'Route tasks to experts',
      'tasks:cancel': 'Cancel tasks',

      // Worker management
      'workers:spawn': 'Spawn new worker agents',
      'workers:read': 'Read worker status and specs',
      'workers:manage': 'Manage worker lifecycle',
      'workers:terminate': 'Terminate workers',

      // Coordination
      'coordination:read': 'Read coordination state',
      'coordination:write': 'Write coordination state',
      'coordination:lock': 'Acquire coordination locks',

      // Security operations
      'security:scan': 'Perform security scans',
      'security:audit': 'Perform security audits',
      'security:remediate': 'Remediate security issues',

      // Development operations
      'development:implement': 'Implement features and fixes',
      'development:test': 'Run tests',
      'development:deploy': 'Deploy code',

      // CI/CD operations
      'cicd:build': 'Trigger builds',
      'cicd:deploy': 'Deploy artifacts',
      'cicd:monitor': 'Access monitoring',

      // Inventory operations
      'inventory:catalog': 'Catalog repositories',
      'inventory:document': 'Generate documentation',
      'inventory:analyze': 'Analyze dependencies',

      // Governance
      'governance:read': 'Read governance policies',
      'governance:write': 'Write governance policies',
      'governance:audit': 'Audit system activity',

      // System operations
      'system:read': 'Read system state',
      'system:write': 'Write system state',
      'system:execute': 'Execute system commands',
      'system:admin': 'System administration'
    };
  }

  /**
   * Initialize capability policies
   */
  async initialize() {
    try {
      await fs.mkdir(path.dirname(this.policiesPath), { recursive: true });

      try {
        await fs.access(this.policiesPath);
      } catch {
        await this.createDefaultPolicies();
      }

      return true;
    } catch (error) {
      console.error('Failed to initialize capability policies:', error.message);
      throw error;
    }
  }

  /**
   * Create default capability policies
   */
  async createDefaultPolicies() {
    const policies = {
      version: '1.0.0',
      updated_at: new Date().toISOString(),
      description: 'Capability-based access control policies for agent identities',

      // Role-based capability mappings
      role_capabilities: {
        master: {
          description: 'Master agents have broad capabilities within their domain',
          capabilities: [
            'tasks:*',
            'workers:*',
            'coordination:read',
            'coordination:write',
            'governance:read'
          ]
        },
        worker: {
          description: 'Workers have limited task-specific capabilities',
          capabilities: [
            'tasks:read',
            'coordination:read',
            'governance:read'
          ]
        },
        daemon: {
          description: 'Daemons have monitoring and maintenance capabilities',
          capabilities: [
            'coordination:read',
            'coordination:write',
            'workers:read',
            'tasks:read',
            'governance:audit'
          ]
        }
      },

      // Expert-specific capability expansions
      expert_capabilities: {
        'development-master': [
          'development:*',
          'workers:spawn',
          'tasks:route',
          'cicd:build',
          'cicd:deploy'
        ],
        'security-master': [
          'security:*',
          'workers:spawn',
          'tasks:route',
          'governance:audit',
          'system:read'
        ],
        'inventory-master': [
          'inventory:*',
          'workers:spawn',
          'tasks:route',
          'governance:read'
        ],
        'cicd-master': [
          'cicd:*',
          'workers:spawn',
          'tasks:route',
          'development:deploy'
        ],
        'coordinator-master': [
          '*'  // Coordinator has full access
        ]
      },

      // Resource-specific access rules
      resource_policies: {
        'coordination/tasks': {
          read: ['master', 'worker', 'daemon'],
          write: ['master'],
          delete: ['master', 'coordinator-master']
        },
        'coordination/worker-specs': {
          read: ['master', 'daemon'],
          write: ['master'],
          delete: ['master']
        },
        'coordination/governance': {
          read: ['master', 'daemon'],
          write: ['master'],
          delete: ['coordinator-master']
        },
        'secrets': {
          read: ['coordinator-master'],
          write: ['coordinator-master'],
          delete: []  // Never allow secret deletion
        }
      },

      // Trust level requirements for sensitive operations
      trust_requirements: {
        'workers:spawn': 75,
        'governance:write': 90,
        'system:admin': 100,
        'secrets:read': 100
      }
    };

    await fs.writeFile(this.policiesPath, JSON.stringify(policies, null, 2));
    console.log('✓ Capability policies created');
  }

  /**
   * Check if agent has required capability
   *
   * @param {Array<string>} agentCapabilities - Agent's capability list
   * @param {string} requiredCapability - Required capability (e.g., "tasks:read")
   * @param {number} trustLevel - Agent's trust level
   * @returns {Promise<boolean>} True if authorized
   */
  async hasCapability(agentCapabilities, requiredCapability, trustLevel = 50) {
    try {
      const policies = JSON.parse(await fs.readFile(this.policiesPath, 'utf8'));

      // Check trust level requirements
      const requiredTrust = policies.trust_requirements[requiredCapability];
      if (requiredTrust && trustLevel < requiredTrust) {
        return false;
      }

      // Check if agent has wildcard capability
      if (agentCapabilities.includes('*')) {
        return true;
      }

      // Check exact match
      if (agentCapabilities.includes(requiredCapability)) {
        return true;
      }

      // Check wildcard matches (e.g., "tasks:*" matches "tasks:read")
      const [category, action] = requiredCapability.split(':');
      if (agentCapabilities.includes(`${category}:*`)) {
        return true;
      }

      return false;
    } catch (error) {
      console.error('Capability check failed:', error.message);
      return false;
    }
  }

  /**
   * Check resource access
   */
  async canAccessResource(agentRole, resourcePath, operation) {
    try {
      const policies = JSON.parse(await fs.readFile(this.policiesPath, 'utf8'));

      // Find matching resource policy
      for (const [resource, policy] of Object.entries(policies.resource_policies)) {
        if (resourcePath.startsWith(resource)) {
          const allowedRoles = policy[operation] || [];
          return allowedRoles.includes(agentRole) || allowedRoles.includes('*');
        }
      }

      // Default: allow read for coordination files, deny write
      if (operation === 'read') {
        return true;
      }

      return false;
    } catch (error) {
      console.error('Resource access check failed:', error.message);
      return false;
    }
  }

  /**
   * Get capabilities for role and expert
   */
  async getCapabilitiesForAgent(role, expertType) {
    try {
      const policies = JSON.parse(await fs.readFile(this.policiesPath, 'utf8'));

      let capabilities = [];

      // Add role-based capabilities
      if (policies.role_capabilities[role]) {
        capabilities = capabilities.concat(policies.role_capabilities[role].capabilities);
      }

      // Add expert-specific capabilities
      if (expertType && policies.expert_capabilities[expertType]) {
        capabilities = capabilities.concat(policies.expert_capabilities[expertType]);
      }

      // Remove duplicates
      return [...new Set(capabilities)];
    } catch (error) {
      console.error('Failed to get capabilities:', error.message);
      return [];
    }
  }

  /**
   * Expand wildcard capabilities to full list
   */
  expandCapabilities(capabilities) {
    const expanded = new Set();

    for (const cap of capabilities) {
      if (cap === '*') {
        // Full wildcard: add all capabilities
        return Object.keys(this.capabilities);
      } else if (cap.endsWith(':*')) {
        // Category wildcard: add all in category
        const category = cap.replace(':*', '');
        Object.keys(this.capabilities)
          .filter(c => c.startsWith(`${category}:`))
          .forEach(c => expanded.add(c));
      } else {
        expanded.add(cap);
      }
    }

    return Array.from(expanded);
  }
}

// CLI interface
async function main() {
  const policy = new CapabilityPolicy();

  const command = process.argv[2];
  const args = process.argv.slice(3);

  try {
    switch (command) {
      case 'init':
        await policy.initialize();
        console.log('✓ Capability policies initialized');
        break;

      case 'check':
        if (args.length < 3) {
          console.error('Usage: capability-policy.js check <capabilities> <required> <trust_level>');
          process.exit(1);
        }
        const capabilities = args[0].split(',');
        const required = args[1];
        const trustLevel = parseInt(args[2]);
        const hasAccess = await policy.hasCapability(capabilities, required, trustLevel);
        console.log(hasAccess ? 'ALLOWED' : 'DENIED');
        process.exit(hasAccess ? 0 : 1);
        break;

      case 'resource':
        if (args.length < 3) {
          console.error('Usage: capability-policy.js resource <role> <path> <operation>');
          process.exit(1);
        }
        const canAccess = await policy.canAccessResource(args[0], args[1], args[2]);
        console.log(canAccess ? 'ALLOWED' : 'DENIED');
        process.exit(canAccess ? 0 : 1);
        break;

      case 'get':
        if (args.length < 2) {
          console.error('Usage: capability-policy.js get <role> <expert_type>');
          process.exit(1);
        }
        const caps = await policy.getCapabilitiesForAgent(args[0], args[1]);
        console.log(JSON.stringify(caps, null, 2));
        break;

      case 'expand':
        if (args.length < 1) {
          console.error('Usage: capability-policy.js expand <capability1,capability2,...>');
          process.exit(1);
        }
        const expanded = policy.expandCapabilities(args[0].split(','));
        console.log(JSON.stringify(expanded, null, 2));
        break;

      default:
        console.log('Capability Policy Engine');
        console.log('');
        console.log('Commands:');
        console.log('  init                                      Initialize policies');
        console.log('  check <caps> <required> <trust>          Check capability');
        console.log('  resource <role> <path> <operation>       Check resource access');
        console.log('  get <role> <expert>                      Get agent capabilities');
        console.log('  expand <cap1,cap2,...>                   Expand wildcards');
        break;
    }
  } catch (error) {
    console.error('Error:', error.message);
    process.exit(1);
  }
}

if (require.main === module) {
  main();
}

module.exports = CapabilityPolicy;
