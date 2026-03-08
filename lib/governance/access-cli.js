#!/usr/bin/env node

/**
 * Access Control CLI
 *
 * Command-line interface for managing roles, permissions, and access control.
 *
 * Commands:
 * - assign-role <principal> <role>  - Assign a role to a principal
 * - check <principal> <asset> <op>  - Check if principal can perform operation
 * - log [options]                   - View access log
 * - list-roles                      - List all roles
 * - list-assignments                - List role assignments
 * - stats                           - Show access control statistics
 * - clear-cache                     - Clear permission cache
 */

const AccessControl = require('./access-control');
const DataFilter = require('./data-filter');
const fs = require('fs').promises;
const path = require('path');

class AccessCLI {
  constructor() {
    this.accessControl = new AccessControl();
    this.dataFilter = new DataFilter();
  }

  async run(args) {
    const command = args[0];

    try {
      switch (command) {
        case 'assign-role':
          await this.assignRole(args[1], args[2]);
          break;

        case 'check':
          await this.checkPermission(args[1], args[2], args[3]);
          break;

        case 'log':
          await this.viewLog(args.slice(1));
          break;

        case 'list-roles':
          await this.listRoles();
          break;

        case 'list-assignments':
          await this.listAssignments();
          break;

        case 'stats':
          await this.showStats();
          break;

        case 'clear-cache':
          await this.clearCache();
          break;

        case 'help':
        default:
          this.showHelp();
          break;
      }
    } catch (error) {
      console.error(`Error: ${error.message}`);
      process.exit(1);
    }
  }

  /**
   * Assign a role to a principal
   */
  async assignRole(principal, roleId) {
    if (!principal || !roleId) {
      console.error('Usage: access-cli.js assign-role <principal> <role>');
      process.exit(1);
    }

    await this.accessControl.initialize();

    try {
      await this.accessControl.assignRole(principal, roleId);
      console.log(`✓ Role ${roleId} assigned to ${principal}`);
    } catch (error) {
      console.error(`✗ Failed to assign role: ${error.message}`);
      process.exit(1);
    }
  }

  /**
   * Check if principal has permission
   */
  async checkPermission(principal, asset, operation) {
    if (!principal || !asset || !operation) {
      console.error('Usage: access-cli.js check <principal> <asset> <operation>');
      process.exit(1);
    }

    await this.accessControl.initialize();

    const result = await this.accessControl.checkPermission(principal, asset, operation);

    console.log('\nPermission Check Result:');
    console.log('------------------------');
    console.log(`Principal: ${principal}`);
    console.log(`Asset: ${asset}`);
    console.log(`Operation: ${operation}`);
    console.log(`Allowed: ${result.allowed ? '✓ YES' : '✗ NO'}`);
    console.log(`Reason: ${result.reason}`);
    console.log(`Latency: ${result.latency_ms.toFixed(2)}ms`);
    if (result.cached) {
      console.log('(Result from cache)');
    }

    process.exit(result.allowed ? 0 : 1);
  }

  /**
   * View access log
   */
  async viewLog(args) {
    const options = this._parseLogOptions(args);

    const logPath = '/Users/ryandahlberg/Projects/commit-relay/coordination/governance/access-log.jsonl';

    try {
      const logData = await fs.readFile(logPath, 'utf8');
      const entries = logData
        .split('\n')
        .filter(line => line.trim())
        .map(line => JSON.parse(line));

      // Filter by options
      let filtered = entries;

      if (options.principal) {
        filtered = filtered.filter(e => e.principal === options.principal);
      }

      if (options.asset) {
        filtered = filtered.filter(e => e.asset.includes(options.asset));
      }

      if (options.denied) {
        filtered = filtered.filter(e => !e.allowed);
      }

      if (options.allowed) {
        filtered = filtered.filter(e => e.allowed);
      }

      if (options.timeRange) {
        const cutoff = new Date(Date.now() - this._parseTimeRange(options.timeRange));
        filtered = filtered.filter(e => new Date(e.timestamp) > cutoff);
      }

      // Show last N entries
      const limit = options.limit || 20;
      const display = filtered.slice(-limit);

      console.log(`\nAccess Log (showing ${display.length} of ${filtered.length} entries):`);
      console.log('='.repeat(80));

      for (const entry of display) {
        const status = entry.allowed ? '✓' : '✗';
        const time = new Date(entry.timestamp).toLocaleTimeString();
        console.log(`${status} ${time} | ${entry.principal} | ${entry.operation} | ${entry.asset}`);
        console.log(`   Reason: ${entry.reason}`);
        if (entry.latency_ms) {
          console.log(`   Latency: ${entry.latency_ms.toFixed(2)}ms`);
        }
        console.log('');
      }

      // Show summary
      const allowed = filtered.filter(e => e.allowed).length;
      const denied = filtered.filter(e => !e.allowed).length;
      console.log('Summary:');
      console.log(`  Allowed: ${allowed}`);
      console.log(`  Denied: ${denied}`);
      console.log(`  Total: ${filtered.length}`);

    } catch (error) {
      if (error.code === 'ENOENT') {
        console.log('No access log found yet.');
      } else {
        throw error;
      }
    }
  }

  /**
   * List all roles
   */
  async listRoles() {
    await this.accessControl.initialize();

    const roles = this.accessControl.roles.roles;

    console.log('\nDefined Roles:');
    console.log('='.repeat(80));

    for (const role of roles) {
      console.log(`\n${role.role_id} (Priority: ${role.priority})`);
      console.log(`  Description: ${role.description}`);
      console.log(`  Permissions: ${role.permissions.join(', ')}`);
      console.log(`  Scope: ${role.scope}`);
      if (role.can_modify && role.can_modify.length > 0) {
        console.log(`  Can Modify: ${role.can_modify.join(', ')}`);
      }
      if (role.restrictions) {
        if (role.restrictions.cannot_modify) {
          console.log(`  Cannot Modify: ${role.restrictions.cannot_modify.join(', ')}`);
        }
        if (role.restrictions.requires_approval_for) {
          console.log(`  Requires Approval: ${role.restrictions.requires_approval_for.join(', ')}`);
        }
      }
    }

    console.log('');
  }

  /**
   * List role assignments
   */
  async listAssignments() {
    await this.accessControl.initialize();

    const assignments = this.accessControl.roles.role_assignments;

    console.log('\nRole Assignments:');
    console.log('='.repeat(80));

    for (const [principal, roleId] of Object.entries(assignments)) {
      console.log(`${principal.padEnd(30)} → ${roleId}`);
    }

    console.log('');
  }

  /**
   * Show statistics
   */
  async showStats() {
    await this.accessControl.initialize();

    const stats = this.accessControl.getStatistics();

    console.log('\nAccess Control Statistics:');
    console.log('='.repeat(80));
    console.log(`Total Checks: ${stats.checks}`);
    console.log(`Allowed: ${stats.allowed} (${((stats.allowed / stats.checks) * 100).toFixed(1)}%)`);
    console.log(`Denied: ${stats.denied} (${((stats.denied / stats.checks) * 100).toFixed(1)}%)`);
    console.log(`Cache Hits: ${stats.cached} (${((stats.cache_hit_rate) * 100).toFixed(1)}%)`);
    console.log(`Cache Size: ${stats.cache_size} entries`);
    console.log(`Avg Latency: ${stats.avg_latency_ms.toFixed(2)}ms`);
    console.log('');
  }

  /**
   * Clear permission cache
   */
  async clearCache() {
    await this.accessControl.initialize();
    this.accessControl.clearCache();
    console.log('✓ Permission cache cleared');
  }

  /**
   * Show help
   */
  showHelp() {
    console.log(`
Access Control CLI - Manage roles and permissions

Usage: node access-cli.js <command> [options]

Commands:
  assign-role <principal> <role>     Assign a role to a principal
  check <principal> <asset> <op>     Check if principal can perform operation
  log [options]                      View access log
    --principal <name>               Filter by principal
    --asset <name>                   Filter by asset
    --time-range <duration>          Filter by time (e.g., 1h, 30m, 1d)
    --denied                         Show only denied requests
    --allowed                        Show only allowed requests
    --limit <n>                      Show last N entries (default: 20)
  list-roles                         List all roles and their permissions
  list-assignments                   List role assignments
  stats                              Show access control statistics
  clear-cache                        Clear permission cache
  help                               Show this help message

Examples:
  # Assign role to a principal
  node access-cli.js assign-role coordinator-master agent-operator

  # Check permission
  node access-cli.js check coordinator-master task-queue read

  # View recent denied access attempts
  node access-cli.js log --denied --time-range 1h

  # View logs for specific principal
  node access-cli.js log --principal coordinator-master --limit 50

  # Show statistics
  node access-cli.js stats
`);
  }

  // ==================== PRIVATE METHODS ====================

  /**
   * Parse log options from arguments
   */
  _parseLogOptions(args) {
    const options = {
      principal: null,
      asset: null,
      timeRange: null,
      denied: false,
      allowed: false,
      limit: 20
    };

    for (let i = 0; i < args.length; i++) {
      switch (args[i]) {
        case '--principal':
          options.principal = args[++i];
          break;
        case '--asset':
          options.asset = args[++i];
          break;
        case '--time-range':
          options.timeRange = args[++i];
          break;
        case '--denied':
          options.denied = true;
          break;
        case '--allowed':
          options.allowed = true;
          break;
        case '--limit':
          options.limit = parseInt(args[++i], 10);
          break;
      }
    }

    return options;
  }

  /**
   * Parse time range string to milliseconds
   */
  _parseTimeRange(range) {
    const match = range.match(/^(\d+)([smhd])$/);
    if (!match) {
      throw new Error('Invalid time range format. Use: 30s, 5m, 1h, 1d');
    }

    const value = parseInt(match[1], 10);
    const unit = match[2];

    switch (unit) {
      case 's': return value * 1000;
      case 'm': return value * 60 * 1000;
      case 'h': return value * 60 * 60 * 1000;
      case 'd': return value * 24 * 60 * 60 * 1000;
      default: throw new Error('Invalid time unit');
    }
  }
}

// Run CLI if called directly
if (require.main === module) {
  const cli = new AccessCLI();
  const args = process.argv.slice(2);
  cli.run(args);
}

module.exports = AccessCLI;
