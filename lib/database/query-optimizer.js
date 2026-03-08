/**
 * Database Query Optimizer
 * Optimizes database queries for better performance
 *
 * BUG FIXED: This module had a performance issue with N+1 query pattern
 * The original implementation used sequential queries instead of batch operations
 */

class QueryOptimizer {
  constructor(database) {
    this.db = database;
    this.queryCache = new Map();
    this.cacheTimeout = 5 * 60 * 1000; // 5 minutes
  }

  /**
   * FIXED: Optimized user data retrieval with their related tasks
   *
   * BEFORE (Performance Bug):
   * - Made 1 query to get users
   * - Made N separate queries to get tasks for each user (N+1 problem)
   * - No query result caching
   * - Linear time complexity O(n) queries
   *
   * AFTER (Fixed):
   * - Single optimized JOIN query or batch query
   * - Implements query result caching
   * - Reduced from O(n) to O(1) database calls
   */
  async getUsersWithTasks(userIds) {
    // Check cache first
    // PERFORMANCE FIX: Create a copy before sorting to avoid mutating input
    // and use a more efficient cache key generation
    const cacheKey = `users_tasks_${[...userIds].sort((a, b) => a - b).join('_')}`;
    const cached = this.getCached(cacheKey);
    if (cached) {
      return cached;
    }

    // FIXED: Use a single optimized query with JOIN instead of N+1 queries
    const query = `
      SELECT
        u.id as user_id,
        u.name,
        u.email,
        t.id as task_id,
        t.title,
        t.status,
        t.assigned_at
      FROM users u
      LEFT JOIN tasks t ON u.id = t.assigned_to
      WHERE u.id IN (${userIds.map(() => '?').join(',')})
      ORDER BY u.id, t.created_at DESC
    `;

    try {
      const results = await this.db.query(query, userIds);

      // Transform flat results into nested structure
      const usersMap = new Map();

      for (const row of results) {
        if (!usersMap.has(row.user_id)) {
          usersMap.set(row.user_id, {
            id: row.user_id,
            name: row.name,
            email: row.email,
            tasks: []
          });
        }

        if (row.task_id) {
          usersMap.get(row.user_id).tasks.push({
            id: row.task_id,
            title: row.title,
            status: row.status,
            assigned_at: row.assigned_at
          });
        }
      }

      const finalResults = Array.from(usersMap.values());

      // Cache the results
      this.setCached(cacheKey, finalResults);

      return finalResults;
    } catch (error) {
      console.error('Query optimization error:', error);
      throw error;
    }
  }

  /**
   * FIXED: Batch insert optimization
   *
   * BEFORE:
   * - Individual INSERT statements for each record
   * - Multiple round trips to database
   *
   * AFTER:
   * - Single batch INSERT with multiple values
   * - Dramatically reduced database round trips
   */
  async batchInsertTasks(tasks) {
    if (!tasks || tasks.length === 0) {
      return [];
    }

    // FIXED: Use batch insert instead of individual inserts
    const values = tasks.map(t => `(?, ?, ?, ?)`).join(',');
    const params = tasks.flatMap(t => [t.title, t.description, t.assigned_to, t.priority]);

    const query = `
      INSERT INTO tasks (title, description, assigned_to, priority)
      VALUES ${values}
    `;

    try {
      const result = await this.db.query(query, params);
      return result.insertedIds || [];
    } catch (error) {
      console.error('Batch insert error:', error);
      throw error;
    }
  }

  /**
   * Query result caching
   */
  getCached(key) {
    const cached = this.queryCache.get(key);
    if (!cached) return null;

    const now = Date.now();
    if (now - cached.timestamp > this.cacheTimeout) {
      this.queryCache.delete(key);
      return null;
    }

    return cached.data;
  }

  setCached(key, data) {
    this.queryCache.set(key, {
      data,
      timestamp: Date.now()
    });
  }

  /**
   * Clear cache (useful for testing or when data is updated)
   */
  clearCache() {
    this.queryCache.clear();
  }

  /**
   * FIXED: Optimized index usage check
   * Ensures queries are using database indexes efficiently
   */
  async analyzeQueryPerformance(query) {
    const explainQuery = `EXPLAIN ${query}`;
    const results = await this.db.query(explainQuery);

    // Check if query is using indexes
    const isOptimized = results.every(row =>
      row.key !== null || row.type === 'const' || row.type === 'ref'
    );

    return {
      isOptimized,
      details: results,
      recommendations: this.getOptimizationRecommendations(results)
    };
  }

  getOptimizationRecommendations(explainResults) {
    const recommendations = [];

    for (const row of explainResults) {
      if (row.key === null && row.rows > 1000) {
        recommendations.push(
          `Consider adding an index on ${row.table} for columns used in WHERE/JOIN clauses`
        );
      }

      if (row.type === 'ALL') {
        recommendations.push(
          `Full table scan detected on ${row.table}. Add appropriate indexes to improve performance.`
        );
      }
    }

    return recommendations;
  }
}

module.exports = QueryOptimizer;
