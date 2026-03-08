/**
 * Optimized Lineage Query Test Suite
 *
 * Tests for optimized lineage query engine:
 * - LRU cache functionality
 * - Index-based lookups
 * - Query performance
 * - Streaming reads
 * - Statistics
 */

const { OptimizedLineageQuery } = require('../../lib/governance/lineage-optimized');
const fs = require('fs').promises;
const path = require('path');

describe('OptimizedLineageQuery', () => {
  let query;
  const testLogPath = path.join(__dirname, 'fixtures', 'test-lineage.jsonl');
  const testIndexPath = path.join(__dirname, 'fixtures', 'lineage-index.json');

  beforeEach(async () => {
    // Setup test directory
    await fs.mkdir(path.dirname(testLogPath), { recursive: true });

    // Create sample lineage log
    const sampleRecords = [
      { id: 'lineage-1', source: 'entity-A', target: 'entity-B', actor: 'coordinator', timestamp: '2025-11-15T14:00:00Z', type: 'transform' },
      { id: 'lineage-2', source: 'entity-B', target: 'entity-C', actor: 'worker-001', timestamp: '2025-11-15T14:05:00Z', type: 'write' },
      { id: 'lineage-3', source: 'entity-A', target: 'entity-D', actor: 'coordinator', timestamp: '2025-11-15T14:10:00Z', type: 'transform' },
      { id: 'lineage-4', source: 'entity-D', target: 'entity-E', actor: 'worker-002', timestamp: '2025-11-15T14:15:00Z', type: 'write' }
    ];

    await fs.writeFile(testLogPath, sampleRecords.map(r => JSON.stringify(r)).join('\n'));

    // Create sample index
    const sampleIndex = {
      entities: {
        'entity-A': { operations: 2, last_access: '2025-11-15T14:10:00Z' },
        'entity-B': { operations: 2, last_access: '2025-11-15T14:05:00Z' },
        'entity-C': { operations: 1, last_access: '2025-11-15T14:05:00Z' },
        'entity-D': { operations: 2, last_access: '2025-11-15T14:15:00Z' },
        'entity-E': { operations: 1, last_access: '2025-11-15T14:15:00Z' }
      },
      actors: {
        'coordinator': { operations: 2, last_operation: '2025-11-15T14:10:00Z' },
        'worker-001': { operations: 1, last_operation: '2025-11-15T14:05:00Z' },
        'worker-002': { operations: 1, last_operation: '2025-11-15T14:15:00Z' }
      },
      sessions: {},
      last_updated: '2025-11-15T14:15:00Z'
    };

    await fs.writeFile(testIndexPath, JSON.stringify(sampleIndex, null, 2));

    // Override paths for testing
    process.env.COMMIT_RELAY_HOME = path.dirname(path.dirname(testLogPath));

    query = new OptimizedLineageQuery({ cacheSize: 10, indexTTL: 60000 });
  });

  afterEach(async () => {
    // Cleanup
    try {
      await fs.rm(path.dirname(testLogPath), { recursive: true, force: true });
    } catch (error) {
      // Ignore
    }
  });

  describe('LRU Cache', () => {
    test('caches query results', async () => {
      const entity = 'entity-A';

      // First query (not cached)
      const startTime1 = Date.now();
      const result1 = await query.queryByEntity(entity, { limit: 10 });
      const duration1 = Date.now() - startTime1;

      // Second query (should be cached)
      const startTime2 = Date.now();
      const result2 = await query.queryByEntity(entity, { limit: 10 });
      const duration2 = Date.now() - startTime2;

      expect(result1.length).toBe(result2.length);
      expect(duration2).toBeLessThan(duration1); // Cached should be faster
    });

    test('cache respects size limit', () => {
      const cache = query.cache;
      const maxSize = cache.maxSize;

      // Add more entries than max size
      for (let i = 0; i < maxSize + 5; i++) {
        cache.set(`key-${i}`, { data: `value-${i}` });
      }

      expect(cache.cache.size).toBeLessThanOrEqual(maxSize);
    });

    test('cache evicts oldest entries', () => {
      const cache = query.cache;

      cache.set('key-1', 'value-1');
      cache.set('key-2', 'value-2');

      // Access key-1 to make it more recent
      cache.get('key-1');

      // Fill cache to trigger eviction
      for (let i = 3; i <= cache.maxSize + 1; i++) {
        cache.set(`key-${i}`, `value-${i}`);
      }

      // key-1 should still be there (recently accessed)
      // key-2 should be evicted (oldest)
      expect(cache.get('key-1')).toBe('value-1');
      expect(cache.get('key-2')).toBeNull();
    });
  });

  describe('Index Loading', () => {
    test('loads index from disk', async () => {
      const index = await query.loadIndex();

      expect(index).toBeDefined();
      expect(index.entities).toBeDefined();
      expect(Object.keys(index.entities).length).toBeGreaterThan(0);
    });

    test('caches loaded index', async () => {
      await query.loadIndex();
      const loadTime1 = query.indexLoadTime;

      // Load again immediately
      await query.loadIndex();
      const loadTime2 = query.indexLoadTime;

      expect(loadTime2).toBe(loadTime1); // Should use cached version
    });

    test('refreshes index after TTL', async () => {
      // Load index
      await query.loadIndex();
      const loadTime1 = query.indexLoadTime;

      // Simulate TTL expiration
      query.indexLoadTime = Date.now() - (query.indexTTL + 1000);

      // Load again
      await query.loadIndex();
      const loadTime2 = query.indexLoadTime;

      expect(loadTime2).toBeGreaterThan(loadTime1);
    });
  });

  describe('Query Performance', () => {
    test('entity query completes quickly', async () => {
      const startTime = Date.now();
      const results = await query.queryByEntity('entity-A', { limit: 10 });
      const duration = Date.now() - startTime;

      expect(duration).toBeLessThan(200); // Target: <200ms
      expect(results.length).toBeGreaterThan(0);
    });

    test('actor query completes quickly', async () => {
      const startTime = Date.now();
      const results = await query.queryByActor('coordinator', { limit: 10 });
      const duration = Date.now() - startTime;

      expect(duration).toBeLessThan(200);
      expect(results.length).toBeGreaterThan(0);
    });

    test('time range query completes quickly', async () => {
      const startTime = Date.now();
      const results = await query.queryByTimeRange(
        '2025-11-15T14:00:00Z',
        '2025-11-15T14:20:00Z',
        { limit: 10 }
      );
      const duration = Date.now() - startTime;

      expect(duration).toBeLessThan(200);
      expect(results.length).toBeGreaterThan(0);
    });
  });

  describe('Query Results', () => {
    test('returns correct entity matches', async () => {
      const results = await query.queryByEntity('entity-A', { limit: 10 });

      expect(results.length).toBe(2); // entity-A appears in 2 records
      expect(results.every(r => r.source === 'entity-A' || r.target === 'entity-A')).toBe(true);
    });

    test('returns correct actor matches', async () => {
      const results = await query.queryByActor('coordinator', { limit: 10 });

      expect(results.length).toBe(2); // coordinator has 2 operations
      expect(results.every(r => r.actor === 'coordinator')).toBe(true);
    });

    test('filters by time range correctly', async () => {
      const results = await query.queryByTimeRange(
        '2025-11-15T14:00:00Z',
        '2025-11-15T14:10:00Z',
        { limit: 10 }
      );

      expect(results.length).toBe(3); // 3 records in this range
      results.forEach(r => {
        const timestamp = new Date(r.timestamp).getTime();
        expect(timestamp).toBeGreaterThanOrEqual(new Date('2025-11-15T14:00:00Z').getTime());
        expect(timestamp).toBeLessThanOrEqual(new Date('2025-11-15T14:10:00Z').getTime());
      });
    });
  });

  describe('Query Options', () => {
    test('respects limit option', async () => {
      const results = await query.queryByEntity('entity-A', { limit: 1 });
      expect(results.length).toBe(1);
    });

    test('applies offset correctly', async () => {
      const allResults = await query.queryByEntity('entity-A', { limit: 10 });
      const offsetResults = await query.queryByEntity('entity-A', { limit: 10, offset: 1 });

      expect(offsetResults.length).toBe(allResults.length - 1);
      expect(offsetResults[0].id).toBe(allResults[1].id);
    });

    test('sorts by field', async () => {
      const results = await query.queryByTimeRange(
        '2025-11-15T14:00:00Z',
        '2025-11-15T14:20:00Z',
        { sortBy: 'timestamp', sortOrder: 'desc', limit: 10 }
      );

      for (let i = 1; i < results.length; i++) {
        const prev = new Date(results[i-1].timestamp).getTime();
        const curr = new Date(results[i].timestamp).getTime();
        expect(prev).toBeGreaterThanOrEqual(curr);
      }
    });
  });

  describe('Statistics', () => {
    test('returns query statistics', async () => {
      const stats = await query.getQueryStats();

      expect(stats.total_entities).toBeGreaterThan(0);
      expect(stats.total_actors).toBeGreaterThan(0);
      expect(stats.cache_size).toBeDefined();
      expect(stats.cache_max_size).toBe(10); // From constructor
    });
  });

  describe('Cache Management', () => {
    test('clearCache removes all entries', async () => {
      // Add some cached queries
      await query.queryByEntity('entity-A');
      await query.queryByEntity('entity-B');

      expect(query.cache.cache.size).toBeGreaterThan(0);

      query.clearCache();

      expect(query.cache.cache.size).toBe(0);
    });

    test('refreshIndex clears cache', async () => {
      // Add some cached queries
      await query.queryByEntity('entity-A');
      expect(query.cache.cache.size).toBeGreaterThan(0);

      await query.refreshIndex();

      expect(query.cache.cache.size).toBe(0);
    });
  });

  describe('Error Handling', () => {
    test('handles missing index gracefully', async () => {
      // Delete index file
      await fs.unlink(testIndexPath).catch(() => {});

      const results = await query.queryByEntity('entity-A');

      // Should still work, just with empty index
      expect(Array.isArray(results)).toBe(true);
    });

    test('handles missing log file gracefully', async () => {
      // Delete log file
      await fs.unlink(testLogPath).catch(() => {});

      const results = await query.queryByEntity('entity-A');

      expect(results).toEqual([]);
    });

    test('handles malformed JSON in log', async () => {
      // Write some malformed JSON
      await fs.writeFile(testLogPath, '{ invalid json }\n{"id": "valid"}');

      const results = await query.queryByEntity('any-entity');

      // Should skip malformed lines and return valid ones
      expect(Array.isArray(results)).toBe(true);
    });
  });
});
