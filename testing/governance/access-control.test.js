/**
 * Access Control Test Suite
 *
 * Tests for Phase 2 governance system:
 * - Role-based permissions
 * - Asset-level access control
 * - PII/sensitive data protection
 * - Performance (<5ms latency target)
 * - Audit logging
 */

const AccessControl = require('../../lib/governance/access-control');
const DataFilter = require('../../lib/governance/data-filter');
const fs = require('fs').promises;
const path = require('path');

// Test configuration
const TEST_ROLES_PATH = path.join(__dirname, 'fixtures', 'test-roles.json');
const TEST_CATALOG_PATH = path.join(__dirname, 'fixtures', 'test-catalog');
const TEST_AUDIT_LOG = path.join(__dirname, 'fixtures', 'test-audit.jsonl');

describe('AccessControl', () => {
  let accessControl;

  beforeEach(async () => {
    // Setup test fixtures
    await setupTestFixtures();

    accessControl = new AccessControl({
      rolesPath: TEST_ROLES_PATH,
      auditLogPath: TEST_AUDIT_LOG,
      catalogPath: TEST_CATALOG_PATH
    });

    await accessControl.initialize();
  });

  afterEach(async () => {
    // Cleanup test fixtures
    await cleanupTestFixtures();
  });

  describe('Role-Based Permissions', () => {
    test('system-admin has full access', async () => {
      const result = await accessControl.checkPermission(
        'system',
        'any-asset',
        'admin'
      );

      expect(result.allowed).toBe(true);
      expect(result.role_id).toBe('system-admin');
      expect(result.latency_ms).toBeLessThan(5);
    });

    test('agent-operator has read/write/execute permissions', async () => {
      const readResult = await accessControl.checkPermission(
        'coordinator-master',
        'task-queue',
        'read'
      );
      expect(readResult.allowed).toBe(true);

      const writeResult = await accessControl.checkPermission(
        'coordinator-master',
        'task-queue',
        'write'
      );
      expect(writeResult.allowed).toBe(true);

      const executeResult = await accessControl.checkPermission(
        'coordinator-master',
        'worker-specs',
        'execute'
      );
      expect(executeResult.allowed).toBe(true);
    });

    test('agent-operator cannot perform admin operations', async () => {
      const result = await accessControl.checkPermission(
        'coordinator-master',
        'global_policies',
        'admin'
      );

      expect(result.allowed).toBe(false);
      expect(result.reason).toContain('does not have admin permission');
    });

    test('observer has read-only access', async () => {
      const readResult = await accessControl.checkPermission(
        'monitoring-observer',
        'task-queue',
        'read'
      );
      expect(readResult.allowed).toBe(true);

      const writeResult = await accessControl.checkPermission(
        'monitoring-observer',
        'task-queue',
        'write'
      );
      expect(writeResult.allowed).toBe(false);
    });
  });

  describe('Asset-Level Restrictions', () => {
    test('agent-operator cannot modify metastore', async () => {
      const result = await accessControl.checkPermission(
        'coordinator-master',
        'metastore',
        'write'
      );

      expect(result.allowed).toBe(false);
      expect(result.reason).toContain('cannot modify metastore');
    });

    test('agent-operator cannot modify global policies', async () => {
      const result = await accessControl.checkPermission(
        'development-master',
        'global_policies',
        'write'
      );

      expect(result.allowed).toBe(false);
      expect(result.reason).toContain('cannot modify global_policies');
    });

    test('agent-operator can modify tasks', async () => {
      const result = await accessControl.checkPermission(
        'coordinator-master',
        'task-queue',
        'write'
      );

      expect(result.allowed).toBe(true);
    });

    test('agent-operator can modify worker specs', async () => {
      const result = await accessControl.checkPermission(
        'development-master',
        'worker-specs',
        'write'
      );

      expect(result.allowed).toBe(true);
    });
  });

  describe('PII and Sensitive Data Protection', () => {
    test('observer cannot access PII data', async () => {
      const result = await accessControl.validatePIIAccess(
        'monitoring-observer',
        'user-credentials'
      );

      expect(result.allowed).toBe(false);
      expect(result.reason).toContain('cannot access PII data');
    });

    test('agent-operator requires approval for sensitive data', async () => {
      const result = await accessControl.validatePIIAccess(
        'coordinator-master',
        'sensitive-asset'
      );

      expect(result.allowed).toBe(false);
      expect(result.requires_approval).toBe(true);
    });

    test('system-admin can access PII data', async () => {
      const result = await accessControl.validatePIIAccess(
        'system',
        'user-credentials'
      );

      expect(result.allowed).toBe(true);
    });
  });

  describe('Performance', () => {
    test('permission check completes in <5ms', async () => {
      const results = [];

      for (let i = 0; i < 100; i++) {
        const result = await accessControl.checkPermission(
          'coordinator-master',
          'task-queue',
          'read'
        );
        results.push(result.latency_ms);
      }

      const avgLatency = results.reduce((a, b) => a + b, 0) / results.length;
      expect(avgLatency).toBeLessThan(5);
    });

    test('cache improves performance', async () => {
      // First call (uncached)
      const firstResult = await accessControl.checkPermission(
        'coordinator-master',
        'task-queue',
        'read'
      );

      // Second call (should be cached)
      const secondResult = await accessControl.checkPermission(
        'coordinator-master',
        'task-queue',
        'read'
      );

      expect(secondResult.cached).toBe(true);
      expect(secondResult.latency_ms).toBeLessThan(firstResult.latency_ms);
    });

    test('cache hit rate improves with repeated access', async () => {
      // Make 20 calls to same permission
      for (let i = 0; i < 20; i++) {
        await accessControl.checkPermission(
          'coordinator-master',
          'task-queue',
          'read'
        );
      }

      const stats = accessControl.getStatistics();
      expect(stats.cache_hit_rate).toBeGreaterThan(0.5); // >50% cache hits
    });
  });

  describe('Audit Logging', () => {
    test('all access decisions are logged', async () => {
      await accessControl.checkPermission(
        'coordinator-master',
        'task-queue',
        'read'
      );

      await accessControl.checkPermission(
        'development-master',
        'metastore',
        'write'
      );

      const logData = await fs.readFile(TEST_AUDIT_LOG, 'utf8');
      const entries = logData.split('\n').filter(line => line.trim());

      expect(entries.length).toBeGreaterThanOrEqual(2);

      const firstEntry = JSON.parse(entries[0]);
      expect(firstEntry.principal).toBe('coordinator-master');
      expect(firstEntry.asset).toBe('task-queue');
      expect(firstEntry.operation).toBe('read');
      expect(firstEntry.allowed).toBe(true);

      const secondEntry = JSON.parse(entries[1]);
      expect(secondEntry.principal).toBe('development-master');
      expect(secondEntry.asset).toBe('metastore');
      expect(secondEntry.operation).toBe('write');
      expect(secondEntry.allowed).toBe(false);
    });

    test('denied access triggers alerts', async () => {
      const result = await accessControl.checkPermission(
        'coordinator-master',
        'metastore',
        'admin'
      );

      expect(result.allowed).toBe(false);

      const logData = await fs.readFile(TEST_AUDIT_LOG, 'utf8');
      const entries = logData.split('\n').filter(line => line.trim());
      const lastEntry = JSON.parse(entries[entries.length - 1]);

      expect(lastEntry.allowed).toBe(false);
      expect(lastEntry.reason).toBeTruthy();
    });
  });

  describe('Role Management', () => {
    test('can assign role to principal', async () => {
      await accessControl.assignRole('test-worker', 'observer');

      const role = accessControl.getPrincipalRole('test-worker');
      expect(role.role_id).toBe('observer');
    });

    test('assigning role clears cache', async () => {
      // Make cached check
      await accessControl.checkPermission('test-worker', 'task-queue', 'read');

      // Change role
      await accessControl.assignRole('test-worker', 'observer');

      // Check again - should not be cached
      const result = await accessControl.checkPermission(
        'test-worker',
        'task-queue',
        'write'
      );

      expect(result.cached).toBeFalsy();
    });

    test('cannot assign non-existent role', async () => {
      await expect(
        accessControl.assignRole('test-worker', 'invalid-role')
      ).rejects.toThrow('Role not found');
    });
  });

  describe('Statistics', () => {
    test('tracks permission check statistics', async () => {
      await accessControl.checkPermission('coordinator-master', 'task-queue', 'read');
      await accessControl.checkPermission('coordinator-master', 'task-queue', 'read');
      await accessControl.checkPermission('coordinator-master', 'metastore', 'admin');

      const stats = accessControl.getStatistics();

      expect(stats.checks).toBe(3);
      expect(stats.allowed).toBe(2);
      expect(stats.denied).toBe(1);
      expect(stats.avg_latency_ms).toBeGreaterThan(0);
    });
  });
});

describe('DataFilter', () => {
  let dataFilter;

  beforeEach(async () => {
    await setupTestFixtures();

    dataFilter = new DataFilter({
      rolesPath: TEST_ROLES_PATH,
      auditLogPath: TEST_AUDIT_LOG,
      catalogPath: TEST_CATALOG_PATH
    });

    await dataFilter.initialize();
  });

  afterEach(async () => {
    await cleanupTestFixtures();
  });

  describe('Field Filtering', () => {
    test('filters sensitive fields for agent-operator', async () => {
      const data = {
        id: 'task-001',
        title: 'Test Task',
        password: 'secret123',
        api_key: 'key-abc',
        status: 'pending'
      };

      const filtered = await dataFilter.filterSensitiveFields(
        data,
        'coordinator-master'
      );

      expect(filtered.id).toBe('task-001');
      expect(filtered.title).toBe('Test Task');
      expect(filtered.status).toBe('pending');
      expect(filtered.password).not.toBe('secret123');
      expect(filtered.api_key).not.toBe('key-abc');
    });

    test('system-admin sees all fields', async () => {
      const data = {
        id: 'task-001',
        password: 'secret123',
        api_key: 'key-abc'
      };

      const filtered = await dataFilter.filterSensitiveFields(data, 'system');

      expect(filtered.password).toBe('secret123');
      expect(filtered.api_key).toBe('key-abc');
    });
  });

  describe('PII Detection', () => {
    test('detects email as PII', () => {
      expect(dataFilter.detectPII('email', 'user@example.com')).toBe(true);
    });

    test('detects phone number as PII', () => {
      expect(dataFilter.detectPII('phone', '+1-555-123-4567')).toBe(true);
    });

    test('detects SSN as PII', () => {
      expect(dataFilter.detectPII('ssn', '123-45-6789')).toBe(true);
    });

    test('normal fields are not PII', () => {
      expect(dataFilter.detectPII('title', 'Test Task')).toBe(false);
      expect(dataFilter.detectPII('status', 'pending')).toBe(false);
    });
  });

  describe('PII Masking', () => {
    test('partial masking shows first and last characters', () => {
      const masked = dataFilter.maskPII('secret123', 'partial');
      expect(masked).toMatch(/^se\*+23$/);
    });

    test('full masking redacts everything', () => {
      const masked = dataFilter.maskPII('secret123', 'full');
      expect(masked).toBe('[REDACTED]');
    });

    test('hash masking creates consistent hash', () => {
      const hash1 = dataFilter.maskPII('secret123', 'hash');
      const hash2 = dataFilter.maskPII('secret123', 'hash');
      expect(hash1).toBe(hash2);
      expect(hash1).toHaveLength(8);
    });
  });

  describe('Row Filtering', () => {
    test('filters rows based on sensitivity', async () => {
      const rows = [
        { id: 1, name: 'Task 1', sensitivity: 'internal' },
        { id: 2, name: 'Task 2', sensitivity: 'pii' },
        { id: 3, name: 'Task 3', sensitivity: 'internal' }
      ];

      const filtered = await dataFilter.filterRows(
        rows,
        'monitoring-observer',
        { max_sensitivity: 'internal' }
      );

      expect(filtered).toHaveLength(2);
      expect(filtered.find(r => r.id === 2)).toBeUndefined();
    });

    test('system-admin sees all rows', async () => {
      const rows = [
        { id: 1, sensitivity: 'internal' },
        { id: 2, sensitivity: 'pii' },
        { id: 3, sensitivity: 'confidential' }
      ];

      const filtered = await dataFilter.filterRows(rows, 'system');

      expect(filtered).toHaveLength(3);
    });
  });
});

// Test Fixtures Setup/Teardown

async function setupTestFixtures() {
  const fixturesDir = path.join(__dirname, 'fixtures');
  await fs.mkdir(fixturesDir, { recursive: true });

  // Create test roles
  const testRoles = {
    roles: [
      {
        role_id: 'system-admin',
        permissions: ['read', 'write', 'execute', 'admin'],
        scope: 'global',
        can_modify: ['all_assets'],
        restrictions: {}
      },
      {
        role_id: 'agent-operator',
        permissions: ['read', 'write', 'execute'],
        scope: 'namespace',
        can_modify: ['tasks', 'worker_specs', 'events'],
        restrictions: {
          cannot_modify: ['metastore', 'global_policies'],
          requires_approval_for: ['sensitive_data_access']
        }
      },
      {
        role_id: 'observer',
        permissions: ['read'],
        scope: 'global',
        can_modify: [],
        restrictions: {
          cannot_read: ['pii_data']
        }
      }
    ],
    role_assignments: {
      'coordinator-master': 'agent-operator',
      'development-master': 'agent-operator',
      'system': 'system-admin',
      'monitoring-observer': 'observer'
    }
  };

  await fs.writeFile(TEST_ROLES_PATH, JSON.stringify(testRoles, null, 2));

  // Create empty audit log
  await fs.writeFile(TEST_AUDIT_LOG, '');

  // Create test catalog directory
  await fs.mkdir(TEST_CATALOG_PATH, { recursive: true });
}

async function cleanupTestFixtures() {
  const fixturesDir = path.join(__dirname, 'fixtures');
  try {
    await fs.rm(fixturesDir, { recursive: true, force: true });
  } catch (error) {
    // Ignore cleanup errors
  }
}

// Export for CI/CD
module.exports = {
  AccessControl,
  DataFilter
};
