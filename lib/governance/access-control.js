#!/usr/bin/env node
// lib/governance/access-control.js
// Unified Role-Based Access Control (RBAC) System
// Part of Phase 6.2: Single-Permission Model
//
// Responsibilities:
// - Manage unified role hierarchy
// - Permission checking and enforcement
// - Role assignment and inheritance
// - Access policy evaluation

const fs = require('fs').promises;
const path = require('path');
const crypto = require('crypto');

class AccessControl {
  constructor() {
    this.policiesPath = 'coordination/governance/access-policies.json';
    this.accessLogPath = 'coordination/governance/access-log.jsonl';
    
    // Unified principal role system
    // Consolidates 120+ granular roles into 2 primary roles
    this.principalRoles = {
      'system': {
        description: 'System-level autonomous operations',
        inherits: [],
        permissions: [
          'system:read',
          'system:write',
          'system:execute',
          'coordinator:manage',
          'masters:coordinate',
          'workers:spawn',
          'workers:manage',
          'worker-specs:read',
          'worker-specs:write',
          'tasks:create',
          'tasks:route',
          'tasks:monitor',
          'tasks:read',
          'tasks:write',
          'task-queue:read',
          'task-queue:write',
          'coordination:read',
          'coordination:write',
          'daemons:start',
          'daemons:stop',
          'daemons:restart',
          'self-healing:detect',
          'self-healing:auto-fix',
          'governance:audit',
          'governance:read',
          'governance:write',
          'catalog:discover',
          'catalog:register',
          'catalog:read',
          'catalog:write'
        ],
        namespaces: ['*'] // Access to all namespaces
      },
      'user': {
        description: 'Human user with read/monitor permissions',
        inherits: [],
        permissions: [
          'dashboard:read',
          'tasks:read',
          'workers:read',
          'catalog:read',
          'reports:read'
        ],
        namespaces: ['dashboard', 'coordinator', 'development', 'security', 'inventory', 'cicd']
      }
    };

    // Namespace-level access policies
    this.namespaceAccess = {
      'coordinator': { min_role: 'system', sensitivity: 'internal' },
      'development': { min_role: 'system', sensitivity: 'internal' },
      'security': { min_role: 'system', sensitivity: 'confidential' },
      'inventory': { min_role: 'system', sensitivity: 'internal' },
      'cicd': { min_role: 'system', sensitivity: 'internal' },
      'dashboard': { min_role: 'user', sensitivity: 'internal' },
      'governance': { min_role: 'system', sensitivity: 'confidential' },
      'self-healing': { min_role: 'system', sensitivity: 'internal' }
    };

    this.policies = null;
  }

  /**
   * Initialize access control system
   */
  async initialize() {
    try {
      // Create governance directory
      await fs.mkdir(path.dirname(this.policiesPath), { recursive: true });

      // Load or create access policies
      try {
        const policiesContent = await fs.readFile(this.policiesPath, 'utf8');
        this.policies = JSON.parse(policiesContent);
      } catch (error) {
        // Initialize default policies
        this.policies = {
          version: '1.0.0',
          created_at: new Date().toISOString(),
          principal_roles: this.principalRoles,
          namespace_access: this.namespaceAccess,
          role_assignments: {
            'commit-relay-system': 'system',
            'default-user': 'user'
          }
        };

        await this._savePolicies();
      }

      console.log('Access Control initialized');
      return true;
    } catch (error) {
      console.error('Failed to initialize Access Control:', error.message);
      return false;
    }
  }

  /**
   * Check permission (compatibility method for CLI)
   * Returns detailed permission check result
   */
  async checkPermission(principal, asset, operation) {
    const startTime = Date.now();

    // Map old API to new API
    const actor = principal;
    const namespace = asset;
    const permission = `${asset}:${operation}`;

    const allowed = await this.hasPermission(actor, permission, namespace);
    const latency_ms = Date.now() - startTime;

    let reason = 'granted';
    if (!allowed) {
      const role = await this.getActorRole(actor);
      if (!role) {
        reason = 'no_role_assigned';
      } else if (!this.policies.principal_roles[role]) {
        reason = 'invalid_role';
      } else {
        reason = 'permission_denied';
      }
    }

    return {
      allowed,
      reason,
      latency_ms,
      cached: false
    };
  }

  /**
   * Check if actor has permission for action
   */
  async hasPermission(actor, permission, namespace = null) {
    const role = await this.getActorRole(actor);

    if (!role) {
      await this._logAccess(actor, permission, namespace, false, 'no_role_assigned');
      return false;
    }

    const roleConfig = this.policies.principal_roles[role];

    if (!roleConfig) {
      await this._logAccess(actor, permission, namespace, false, 'invalid_role');
      return false;
    }

    // Check permission
    const hasPermission = 
      roleConfig.permissions.includes(permission) ||
      roleConfig.permissions.includes('system:*') ||
      roleConfig.permissions.some(p => {
        const prefix = p.split(':')[0];
        return permission.startsWith(prefix + ':') && p.endsWith(':*');
      });

    if (!hasPermission) {
      await this._logAccess(actor, permission, namespace, false, 'permission_denied');
      return false;
    }

    // Check namespace access if specified
    if (namespace) {
      const hasNamespaceAccess = 
        roleConfig.namespaces.includes('*') ||
        roleConfig.namespaces.includes(namespace);

      if (!hasNamespaceAccess) {
        await this._logAccess(actor, permission, namespace, false, 'namespace_denied');
        return false;
      }

      // Check namespace sensitivity level
      const nsConfig = this.policies.namespace_access[namespace];
      if (nsConfig) {
        const roleLevel = this._getRoleLevel(role);
        const minLevel = this._getRoleLevel(nsConfig.min_role);

        if (roleLevel < minLevel) {
          await this._logAccess(actor, permission, namespace, false, 'insufficient_role_level');
          return false;
        }
      }
    }

    await this._logAccess(actor, permission, namespace, true);
    return true;
  }

  /**
   * Get actor's assigned role
   */
  async getActorRole(actor) {
    return this.policies.role_assignments[actor] || null;
  }

  /**
   * Assign role to actor
   */
  async assignRole(actor, role) {
    if (!this.policies.principal_roles[role]) {
      throw new Error(`Invalid role: ${role}`);
    }

    this.policies.role_assignments[actor] = role;
    await this._savePolicies();

    console.log(`Assigned role '${role}' to actor '${actor}'`);
    return true;
  }

  /**
   * Get all permissions for a role
   */
  async getRolePermissions(role) {
    const roleConfig = this.policies.principal_roles[role];

    if (!roleConfig) {
      throw new Error(`Role not found: ${role}`);
    }

    const permissions = [...roleConfig.permissions];

    // Include inherited permissions
    for (const inheritedRole of roleConfig.inherits || []) {
      const inheritedPerms = await this.getRolePermissions(inheritedRole);
      permissions.push(...inheritedPerms);
    }

    // Remove duplicates
    return [...new Set(permissions)];
  }

  /**
   * Check namespace access
   */
  async canAccessNamespace(actor, namespace, accessType = 'read') {
    const role = await this.getActorRole(actor);

    if (!role) {
      return false;
    }

    const roleConfig = this.policies.principal_roles[role];
    const nsConfig = this.policies.namespace_access[namespace];

    // Check if role has access to namespace
    const hasNamespaceAccess = 
      roleConfig.namespaces.includes('*') ||
      roleConfig.namespaces.includes(namespace);

    if (!hasNamespaceAccess) {
      return false;
    }

    // Check minimum role level for namespace
    if (nsConfig) {
      const roleLevel = this._getRoleLevel(role);
      const minLevel = this._getRoleLevel(nsConfig.min_role);

      if (roleLevel < minLevel) {
        return false;
      }
    }

    // Check specific permission for access type
    const permission = `${namespace}:${accessType}`;
    const generalPermission = `catalog:${accessType}`;

    return await this.hasPermission(actor, permission, namespace) ||
           await this.hasPermission(actor, generalPermission, namespace);
  }

  /**
   * Get access audit log
   */
  async getAccessLog(filters = {}) {
    try {
      const logContent = await fs.readFile(this.accessLogPath, 'utf8');
      const lines = logContent.trim().split('\n');

      let logs = lines.map(line => JSON.parse(line));

      // Apply filters
      if (filters.actor) {
        logs = logs.filter(log => log.actor === filters.actor);
      }

      if (filters.namespace) {
        logs = logs.filter(log => log.namespace === filters.namespace);
      }

      if (filters.permitted !== undefined) {
        logs = logs.filter(log => log.permitted === filters.permitted);
      }

      if (filters.start_time) {
        logs = logs.filter(log => new Date(log.timestamp) >= new Date(filters.start_time));
      }

      if (filters.end_time) {
        logs = logs.filter(log => new Date(log.timestamp) <= new Date(filters.end_time));
      }

      // Sort by timestamp (newest first)
      logs.sort((a, b) => new Date(b.timestamp) - new Date(a.timestamp));

      // Apply limit
      if (filters.limit) {
        logs = logs.slice(0, filters.limit);
      }

      return logs;
    } catch (error) {
      return [];
    }
  }

  /**
   * Generate access report
   */
  async generateAccessReport(timeRange = {}) {
    const start = timeRange.start || new Date(Date.now() - 7*24*60*60*1000).toISOString();
    const end = timeRange.end || new Date().toISOString();

    const logs = await this.getAccessLog({ start_time: start, end_time: end });

    const report = {
      report_id: crypto.randomUUID(),
      generated_at: new Date().toISOString(),
      time_range: { start, end },
      total_access_attempts: logs.length,
      permitted_accesses: logs.filter(l => l.permitted).length,
      denied_accesses: logs.filter(l => !l.permitted).length,
      access_by_actor: {},
      access_by_namespace: {},
      denied_reasons: {},
      top_denied_permissions: []
    };

    // Aggregate by actor
    for (const log of logs) {
      if (!report.access_by_actor[log.actor]) {
        report.access_by_actor[log.actor] = { total: 0, permitted: 0, denied: 0 };
      }

      report.access_by_actor[log.actor].total++;

      if (log.permitted) {
        report.access_by_actor[log.actor].permitted++;
      } else {
        report.access_by_actor[log.actor].denied++;
      }
    }

    // Aggregate by namespace
    for (const log of logs) {
      if (log.namespace) {
        if (!report.access_by_namespace[log.namespace]) {
          report.access_by_namespace[log.namespace] = { total: 0, permitted: 0, denied: 0 };
        }

        report.access_by_namespace[log.namespace].total++;

        if (log.permitted) {
          report.access_by_namespace[log.namespace].permitted++;
        } else {
          report.access_by_namespace[log.namespace].denied++;
        }
      }
    }

    // Aggregate denied reasons
    for (const log of logs) {
      if (!log.permitted && log.reason) {
        report.denied_reasons[log.reason] = (report.denied_reasons[log.reason] || 0) + 1;
      }
    }

    // Top denied permissions
    const deniedPerms = {};
    for (const log of logs) {
      if (!log.permitted) {
        deniedPerms[log.permission] = (deniedPerms[log.permission] || 0) + 1;
      }
    }

    report.top_denied_permissions = Object.entries(deniedPerms)
      .sort((a, b) => b[1] - a[1])
      .slice(0, 10)
      .map(([permission, count]) => ({ permission, count }));

    return report;
  }

  /**
   * Get role hierarchy level (for comparison)
   */
  _getRoleLevel(role) {
    const levels = {
      'system': 100,
      'user': 10
    };

    return levels[role] || 0;
  }

  /**
   * Save policies to file
   */
  async _savePolicies() {
    this.policies.updated_at = new Date().toISOString();
    await fs.writeFile(this.policiesPath, JSON.stringify(this.policies, null, 2));
  }

  /**
   * Log access attempt
   */
  async _logAccess(actor, permission, namespace, permitted, reason = null) {
    const logEntry = {
      event_id: crypto.randomUUID(),
      timestamp: new Date().toISOString(),
      actor: actor,
      permission: permission,
      namespace: namespace,
      permitted: permitted,
      reason: reason
    };

    const logLine = JSON.stringify(logEntry) + '\n';
    await fs.appendFile(this.accessLogPath, logLine);
  }
}

// CLI interface
if (require.main === module) {
  const action = process.argv[2];
  const accessControl = new AccessControl();

  (async () => {
    await accessControl.initialize();

    switch (action) {
      case 'check':
        const actor = process.argv[3];
        const permission = process.argv[4];
        const namespace = process.argv[5] || null;
        
        const hasPermission = await accessControl.hasPermission(actor, permission, namespace);
        console.log(`\nPermission Check:`);
        console.log(`  Actor: ${actor}`);
        console.log(`  Permission: ${permission}`);
        console.log(`  Namespace: ${namespace || 'N/A'}`);
        console.log(`  Result: ${hasPermission ? 'GRANTED' : 'DENIED'}`);
        break;

      case 'assign':
        const assignActor = process.argv[3];
        const role = process.argv[4];

        await accessControl.assignRole(assignActor, role);
        console.log(`Role '${role}' assigned to '${assignActor}'`);
        break;

      case 'permissions':
        const queryRole = process.argv[3];
        const permissions = await accessControl.getRolePermissions(queryRole);
        console.log(`\nPermissions for role '${queryRole}':`);
        permissions.forEach(p => console.log(`  - ${p}`));
        break;

      case 'audit':
        const auditActor = process.argv[3];
        const limit = parseInt(process.argv[4]) || 100;

        const logs = await accessControl.getAccessLog({ actor: auditActor, limit });
        console.log(`\nAccess Log for '${auditActor}' (last ${limit}):`);
        console.log(JSON.stringify(logs, null, 2));
        break;

      case 'report':
        const report = await accessControl.generateAccessReport();
        console.log('\nAccess Control Report:');
        console.log(JSON.stringify(report, null, 2));
        break;

      default:
        console.log('Usage: node access-control.js <action>');
        console.log('Actions:');
        console.log('  check <actor> <permission> [namespace]  - Check permission');
        console.log('  assign <actor> <role>                   - Assign role to actor');
        console.log('  permissions <role>                      - List role permissions');
        console.log('  audit <actor> [limit]                   - View access log');
        console.log('  report                                  - Generate access report');
        break;
    }
  })();
}

module.exports = AccessControl;
