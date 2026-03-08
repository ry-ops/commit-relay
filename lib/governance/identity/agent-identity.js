#!/usr/bin/env node
// lib/governance/identity/agent-identity.js
// Agent Identity Management System
// Implements SPIFFE-like identity framework for agents as first-class principals

const fs = require('fs').promises;
const path = require('path');
const crypto = require('crypto');
const jwt = require('jsonwebtoken');

/**
 * Agent Identity Format: spiffe://commit-relay/{domain}/{agent-id}
 *
 * Examples:
 *   spiffe://commit-relay/masters/coordinator-master
 *   spiffe://commit-relay/masters/development-master
 *   spiffe://commit-relay/workers/worker-implementation-042
 *   spiffe://commit-relay/daemons/heartbeat-monitor
 */

class AgentIdentity {
  constructor() {
    this.identitiesPath = 'coordination/governance/identities/active-identities.json';
    this.signingKeyPath = 'secrets/identity-signing-key.pem';
    this.verifyKeyPath = 'secrets/identity-verify-key.pem';
    this.tokenTTL = 3600; // 1 hour default

    // Trust levels
    this.trustLevels = {
      SYSTEM: 100,      // Full system access (coordinator, masters)
      TRUSTED: 75,      // Elevated privileges (workers with proven track record)
      STANDARD: 50,     // Normal worker privileges
      RESTRICTED: 25,   // Limited trial worker
      UNTRUSTED: 0      // No privileges (blocked)
    };
  }

  /**
   * Initialize identity system (generate keys if needed)
   */
  async initialize() {
    try {
      // Ensure directories exist
      await fs.mkdir(path.dirname(this.identitiesPath), { recursive: true });
      await fs.mkdir(path.dirname(this.signingKeyPath), { recursive: true });

      // Check if keys exist
      try {
        await fs.access(this.signingKeyPath);
        console.log('Identity signing keys exist');
      } catch {
        // Generate RSA key pair for JWT signing
        console.log('Generating identity signing keys...');
        const { publicKey, privateKey } = crypto.generateKeyPairSync('rsa', {
          modulusLength: 2048,
          publicKeyEncoding: { type: 'spki', format: 'pem' },
          privateKeyEncoding: { type: 'pkcs8', format: 'pem' }
        });

        await fs.writeFile(this.signingKeyPath, privateKey, { mode: 0o600 });
        await fs.writeFile(this.verifyKeyPath, publicKey, { mode: 0o644 });
        console.log('✓ Identity keys generated');
      }

      // Load or create identities registry
      try {
        await fs.access(this.identitiesPath);
      } catch {
        await this.createIdentitiesRegistry();
      }

      return true;
    } catch (error) {
      console.error('Failed to initialize identity system:', error.message);
      throw error;
    }
  }

  /**
   * Create initial identities registry
   */
  async createIdentitiesRegistry() {
    const registry = {
      version: '1.0.0',
      created_at: new Date().toISOString(),
      identities: {
        // Pre-register system agents
        'coordinator-master': {
          spiffe_id: 'spiffe://commit-relay/masters/coordinator-master',
          role: 'master',
          trust_level: this.trustLevels.SYSTEM,
          capabilities: ['*'],  // Full access
          created_at: new Date().toISOString(),
          status: 'active'
        },
        'development-master': {
          spiffe_id: 'spiffe://commit-relay/masters/development-master',
          role: 'master',
          trust_level: this.trustLevels.SYSTEM,
          capabilities: ['development:*', 'workers:spawn', 'tasks:*'],
          created_at: new Date().toISOString(),
          status: 'active'
        },
        'security-master': {
          spiffe_id: 'spiffe://commit-relay/masters/security-master',
          role: 'master',
          trust_level: this.trustLevels.SYSTEM,
          capabilities: ['security:*', 'workers:spawn', 'tasks:*', 'audit:read'],
          created_at: new Date().toISOString(),
          status: 'active'
        },
        'inventory-master': {
          spiffe_id: 'spiffe://commit-relay/masters/inventory-master',
          role: 'master',
          trust_level: this.trustLevels.SYSTEM,
          capabilities: ['inventory:*', 'catalog:*', 'workers:spawn', 'tasks:*'],
          created_at: new Date().toISOString(),
          status: 'active'
        },
        'cicd-master': {
          spiffe_id: 'spiffe://commit-relay/masters/cicd-master',
          role: 'master',
          trust_level: this.trustLevels.SYSTEM,
          capabilities: ['cicd:*', 'workers:spawn', 'tasks:*', 'deployment:*'],
          created_at: new Date().toISOString(),
          status: 'active'
        }
      },
      revoked: [],
      statistics: {
        total_issued: 5,
        total_active: 5,
        total_revoked: 0
      }
    };

    await fs.writeFile(this.identitiesPath, JSON.stringify(registry, null, 2));
    console.log('✓ Identity registry created');
  }

  /**
   * Generate SPIFFE ID for an agent
   */
  generateSpiffeId(domain, agentId) {
    return `spiffe://commit-relay/${domain}/${agentId}`;
  }

  /**
   * Issue identity token for an agent
   *
   * @param {string} agentId - Agent identifier (e.g., 'worker-implementation-042')
   * @param {string} role - Agent role ('worker', 'master', 'daemon')
   * @param {Array<string>} capabilities - List of capabilities
   * @param {number} trustLevel - Trust level (0-100)
   * @param {object} metadata - Additional metadata
   * @returns {Promise<object>} Token and identity info
   */
  async issueToken(agentId, role, capabilities, trustLevel, metadata = {}) {
    try {
      // Generate SPIFFE ID
      const domain = role === 'master' ? 'masters' : role === 'daemon' ? 'daemons' : 'workers';
      const spiffeId = this.generateSpiffeId(domain, agentId);

      // Load signing key
      const signingKey = await fs.readFile(this.signingKeyPath, 'utf8');

      // Create token payload
      const payload = {
        sub: spiffeId,           // Subject (SPIFFE ID)
        agent_id: agentId,
        role: role,
        trust_level: trustLevel,
        capabilities: capabilities,
        metadata: metadata,
        iat: Math.floor(Date.now() / 1000),
        exp: Math.floor(Date.now() / 1000) + this.tokenTTL
      };

      // Sign JWT
      const token = jwt.sign(payload, signingKey, {
        algorithm: 'RS256',
        issuer: 'commit-relay-identity-system',
        audience: 'commit-relay-agents'
      });

      // Register identity
      await this.registerIdentity(agentId, spiffeId, role, capabilities, trustLevel, metadata);

      return {
        token: token,
        spiffe_id: spiffeId,
        expires_at: new Date((payload.exp) * 1000).toISOString(),
        trust_level: trustLevel,
        capabilities: capabilities
      };
    } catch (error) {
      console.error(`Failed to issue token for ${agentId}:`, error.message);
      throw error;
    }
  }

  /**
   * Verify and decode identity token
   *
   * @param {string} token - JWT token
   * @returns {Promise<object>} Decoded and verified token payload
   */
  async verifyToken(token) {
    try {
      // Load verification key
      const verifyKey = await fs.readFile(this.verifyKeyPath, 'utf8');

      // Verify and decode
      const decoded = jwt.verify(token, verifyKey, {
        algorithms: ['RS256'],
        issuer: 'commit-relay-identity-system',
        audience: 'commit-relay-agents'
      });

      // Check if identity is revoked
      const isRevoked = await this.isRevoked(decoded.agent_id);
      if (isRevoked) {
        throw new Error('Identity has been revoked');
      }

      return decoded;
    } catch (error) {
      if (error.name === 'TokenExpiredError') {
        throw new Error('Identity token expired');
      } else if (error.name === 'JsonWebTokenError') {
        throw new Error('Invalid identity token');
      }
      throw error;
    }
  }

  /**
   * Register identity in registry
   */
  async registerIdentity(agentId, spiffeId, role, capabilities, trustLevel, metadata) {
    try {
      const registry = JSON.parse(await fs.readFile(this.identitiesPath, 'utf8'));

      registry.identities[agentId] = {
        spiffe_id: spiffeId,
        role: role,
        trust_level: trustLevel,
        capabilities: capabilities,
        metadata: metadata,
        created_at: new Date().toISOString(),
        last_seen: new Date().toISOString(),
        status: 'active'
      };

      registry.statistics.total_issued++;
      registry.statistics.total_active++;

      await fs.writeFile(this.identitiesPath, JSON.stringify(registry, null, 2));
      return true;
    } catch (error) {
      console.error(`Failed to register identity for ${agentId}:`, error.message);
      throw error;
    }
  }

  /**
   * Revoke agent identity
   */
  async revokeIdentity(agentId, reason = 'unspecified') {
    try {
      const registry = JSON.parse(await fs.readFile(this.identitiesPath, 'utf8'));

      if (!registry.identities[agentId]) {
        throw new Error(`Identity not found: ${agentId}`);
      }

      const identity = registry.identities[agentId];
      identity.status = 'revoked';
      identity.revoked_at = new Date().toISOString();
      identity.revoke_reason = reason;

      registry.revoked.push({
        agent_id: agentId,
        spiffe_id: identity.spiffe_id,
        revoked_at: identity.revoked_at,
        reason: reason
      });

      registry.statistics.total_active--;
      registry.statistics.total_revoked++;

      await fs.writeFile(this.identitiesPath, JSON.stringify(registry, null, 2));
      console.log(`✓ Revoked identity: ${agentId} (${reason})`);
      return true;
    } catch (error) {
      console.error(`Failed to revoke identity for ${agentId}:`, error.message);
      throw error;
    }
  }

  /**
   * Check if identity is revoked
   */
  async isRevoked(agentId) {
    try {
      const registry = JSON.parse(await fs.readFile(this.identitiesPath, 'utf8'));
      const identity = registry.identities[agentId];
      return identity && identity.status === 'revoked';
    } catch {
      return false;
    }
  }

  /**
   * Get identity information
   */
  async getIdentity(agentId) {
    try {
      const registry = JSON.parse(await fs.readFile(this.identitiesPath, 'utf8'));
      return registry.identities[agentId] || null;
    } catch {
      return null;
    }
  }

  /**
   * List all active identities
   */
  async listIdentities(filter = {}) {
    try {
      const registry = JSON.parse(await fs.readFile(this.identitiesPath, 'utf8'));
      let identities = Object.entries(registry.identities);

      // Apply filters
      if (filter.role) {
        identities = identities.filter(([_, identity]) => identity.role === filter.role);
      }
      if (filter.status) {
        identities = identities.filter(([_, identity]) => identity.status === filter.status);
      }
      if (filter.min_trust_level !== undefined) {
        identities = identities.filter(([_, identity]) =>
          identity.trust_level >= filter.min_trust_level
        );
      }

      return Object.fromEntries(identities);
    } catch {
      return {};
    }
  }

  /**
   * Update agent's last seen timestamp
   */
  async updateLastSeen(agentId) {
    try {
      const registry = JSON.parse(await fs.readFile(this.identitiesPath, 'utf8'));

      if (registry.identities[agentId]) {
        registry.identities[agentId].last_seen = new Date().toISOString();
        await fs.writeFile(this.identitiesPath, JSON.stringify(registry, null, 2));
      }
    } catch (error) {
      // Non-critical, just log
      console.warn(`Failed to update last seen for ${agentId}`);
    }
  }

  /**
   * Calculate trust level based on performance
   */
  calculateTrustLevel(metrics) {
    let trustLevel = this.trustLevels.STANDARD; // Start at 50

    // Increase trust based on success rate
    if (metrics.success_rate >= 0.95) trustLevel += 20;
    else if (metrics.success_rate >= 0.90) trustLevel += 15;
    else if (metrics.success_rate >= 0.80) trustLevel += 10;
    else if (metrics.success_rate < 0.50) trustLevel -= 25;

    // Increase trust based on task count (experience)
    if (metrics.tasks_completed >= 100) trustLevel += 10;
    else if (metrics.tasks_completed >= 50) trustLevel += 5;

    // Decrease trust for failures
    if (metrics.recent_failures > 5) trustLevel -= 15;
    else if (metrics.recent_failures > 3) trustLevel -= 10;

    // Clamp to valid range
    return Math.max(0, Math.min(100, trustLevel));
  }
}

// CLI interface
async function main() {
  const identity = new AgentIdentity();

  const command = process.argv[2];
  const args = process.argv.slice(3);

  try {
    switch (command) {
      case 'init':
        await identity.initialize();
        console.log('✓ Identity system initialized');
        break;

      case 'issue':
        if (args.length < 4) {
          console.error('Usage: agent-identity.js issue <agent_id> <role> <trust_level> <capabilities...>');
          process.exit(1);
        }
        const [agentId, role, trustLevel, ...capabilities] = args;
        const result = await identity.issueToken(
          agentId,
          role,
          capabilities,
          parseInt(trustLevel)
        );
        console.log(JSON.stringify(result, null, 2));
        break;

      case 'verify':
        if (args.length < 1) {
          console.error('Usage: agent-identity.js verify <token>');
          process.exit(1);
        }
        const decoded = await identity.verifyToken(args[0]);
        console.log(JSON.stringify(decoded, null, 2));
        break;

      case 'revoke':
        if (args.length < 1) {
          console.error('Usage: agent-identity.js revoke <agent_id> [reason]');
          process.exit(1);
        }
        await identity.revokeIdentity(args[0], args[1] || 'manual revocation');
        break;

      case 'get':
        if (args.length < 1) {
          console.error('Usage: agent-identity.js get <agent_id>');
          process.exit(1);
        }
        const info = await identity.getIdentity(args[0]);
        console.log(JSON.stringify(info, null, 2));
        break;

      case 'list':
        const filter = {};
        for (let i = 0; i < args.length; i += 2) {
          const key = args[i].replace(/^--/, '');
          const value = args[i + 1];
          filter[key] = value;
        }
        const identities = await identity.listIdentities(filter);
        console.log(JSON.stringify(identities, null, 2));
        break;

      default:
        console.log('Agent Identity Management System');
        console.log('');
        console.log('Commands:');
        console.log('  init                                  Initialize identity system');
        console.log('  issue <id> <role> <trust> <caps...>  Issue identity token');
        console.log('  verify <token>                        Verify identity token');
        console.log('  revoke <id> [reason]                  Revoke identity');
        console.log('  get <id>                              Get identity info');
        console.log('  list [--role worker] [--status active] List identities');
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

module.exports = AgentIdentity;
