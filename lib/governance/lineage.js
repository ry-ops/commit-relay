#!/usr/bin/env node

/**
 * Data Lineage & Audit Trail System
 * Phase 3 of Governance Upgrade
 *
 * Provides comprehensive tracking of all operations, transformations,
 * and data flows through the commit-relay system.
 */

const fs = require('fs').promises;
const path = require('path');
const crypto = require('crypto');

const PROJECT_ROOT = process.env.COMMIT_RELAY_HOME || path.join(__dirname, '../..');
const LINEAGE_LOG = path.join(PROJECT_ROOT, 'coordination/governance/lineage-log.jsonl');
const AUDIT_LOG = path.join(PROJECT_ROOT, 'coordination/governance/audit-trail.jsonl');
const LINEAGE_INDEX = path.join(PROJECT_ROOT, 'coordination/governance/lineage-index.json');

/**
 * LineageTracker - Core class for tracking data operations
 */
class LineageTracker {
  constructor() {
    this.sessionId = this.generateSessionId();
    this.operationBuffer = [];
    this.bufferSize = 100;
  }

  /**
   * Generate unique session ID
   */
  generateSessionId() {
    return `session-${Date.now()}-${crypto.randomBytes(4).toString('hex')}`;
  }

  /**
   * Record a data operation with full lineage
   *
   * @param {Object} operation - Operation details
   * @param {string} operation.type - Operation type (read, write, transform, delete)
   * @param {string} operation.source - Source entity/file
   * @param {string} operation.target - Target entity/file (for transforms/writes)
   * @param {string} operation.actor - Principal performing operation
   * @param {Object} operation.metadata - Additional metadata
   */
  async recordOperation(operation) {
    const lineageRecord = {
      id: this.generateLineageId(),
      session_id: this.sessionId,
      timestamp: new Date().toISOString(),
      type: operation.type,
      source: operation.source || null,
      target: operation.target || null,
      actor: operation.actor,
      transformation: operation.transformation || null,
      metadata: {
        ...operation.metadata,
        git_commit: await this.getCurrentGitCommit(),
        hostname: require('os').hostname(),
        process_id: process.pid
      },
      lineage_path: this.buildLineagePath(operation),
      checksum: null // Computed after serialization
    };

    // Compute checksum for integrity
    const recordCopy = { ...lineageRecord };
    delete recordCopy.checksum;
    lineageRecord.checksum = crypto
      .createHash('sha256')
      .update(JSON.stringify(recordCopy))
      .digest('hex').slice(0, 16);

    // Buffer for batch writes
    this.operationBuffer.push(lineageRecord);

    if (this.operationBuffer.length >= this.bufferSize) {
      await this.flush();
    }

    return lineageRecord;
  }

  /**
   * Build lineage path showing data flow
   */
  buildLineagePath(operation) {
    const path = [];

    if (operation.source) {
      path.push({
        entity: operation.source,
        role: 'source',
        timestamp: new Date().toISOString()
      });
    }

    if (operation.transformation) {
      path.push({
        entity: operation.transformation,
        role: 'transformation',
        timestamp: new Date().toISOString()
      });
    }

    if (operation.target) {
      path.push({
        entity: operation.target,
        role: 'target',
        timestamp: new Date().toISOString()
      });
    }

    return path;
  }

  /**
   * Generate unique lineage ID
   */
  generateLineageId() {
    return `lineage-${Date.now()}-${crypto.randomBytes(6).toString('hex')}`;
  }

  /**
   * Get current git commit for versioning
   */
  async getCurrentGitCommit() {
    try {
      const { execSync } = require('child_process');
      return execSync('git rev-parse HEAD', { cwd: PROJECT_ROOT })
        .toString()
        .trim()
        .slice(0, 8);
    } catch (error) {
      return 'unknown';
    }
  }

  /**
   * Flush buffered operations to disk
   */
  async flush() {
    if (this.operationBuffer.length === 0) return;

    try {
      await fs.mkdir(path.dirname(LINEAGE_LOG), { recursive: true });

      // Append to JSONL log
      const lines = this.operationBuffer
        .map(record => JSON.stringify(record))
        .join('\n') + '\n';

      await fs.appendFile(LINEAGE_LOG, lines);

      // Update index for fast queries
      await this.updateIndex(this.operationBuffer);

      this.operationBuffer = [];
    } catch (error) {
      console.error('Failed to flush lineage records:', error.message);
      throw error;
    }
  }

  /**
   * Update lineage index for fast queries
   */
  async updateIndex(records) {
    let index = { entities: {}, actors: {}, sessions: {}, last_updated: null };

    try {
      const indexData = await fs.readFile(LINEAGE_INDEX, 'utf8');
      index = JSON.parse(indexData);
    } catch (error) {
      // Index doesn't exist yet, use empty
    }

    // Index by entity, actor, and session
    for (const record of records) {
      // Index source entity
      if (record.source) {
        if (!index.entities[record.source]) {
          index.entities[record.source] = { operations: 0, last_access: null };
        }
        index.entities[record.source].operations++;
        index.entities[record.source].last_access = record.timestamp;
      }

      // Index target entity
      if (record.target) {
        if (!index.entities[record.target]) {
          index.entities[record.target] = { operations: 0, last_access: null };
        }
        index.entities[record.target].operations++;
        index.entities[record.target].last_access = record.timestamp;
      }

      // Index actor
      if (!index.actors[record.actor]) {
        index.actors[record.actor] = { operations: 0, last_operation: null };
      }
      index.actors[record.actor].operations++;
      index.actors[record.actor].last_operation = record.timestamp;

      // Index session
      if (!index.sessions[record.session_id]) {
        index.sessions[record.session_id] = { operations: 0, started: record.timestamp };
      }
      index.sessions[record.session_id].operations++;
    }

    index.last_updated = new Date().toISOString();

    await fs.writeFile(LINEAGE_INDEX, JSON.stringify(index, null, 2));
  }
}

/**
 * AuditLogger - Comprehensive audit trail logging
 */
class AuditLogger {
  constructor() {
    this.auditBuffer = [];
    this.bufferSize = 50;
  }

  /**
   * Log an audit event
   *
   * @param {Object} event - Audit event
   * @param {string} event.action - Action performed
   * @param {string} event.actor - Principal performing action
   * @param {string} event.resource - Resource affected
   * @param {string} event.outcome - success/failure
   * @param {Object} event.context - Additional context
   */
  async logAudit(event) {
    const auditRecord = {
      id: this.generateAuditId(),
      timestamp: new Date().toISOString(),
      action: event.action,
      actor: event.actor,
      resource: event.resource,
      outcome: event.outcome,
      severity: this.determineSeverity(event),
      context: {
        ...event.context,
        ip_address: event.context?.ip_address || 'localhost',
        user_agent: event.context?.user_agent || 'commit-relay-system',
        session_id: event.context?.session_id || null
      },
      compliance_tags: this.generateComplianceTags(event),
      retention_until: this.calculateRetention(event)
    };

    this.auditBuffer.push(auditRecord);

    if (this.auditBuffer.length >= this.bufferSize) {
      await this.flushAudit();
    }

    return auditRecord;
  }

  /**
   * Generate unique audit ID
   */
  generateAuditId() {
    return `audit-${Date.now()}-${crypto.randomBytes(6).toString('hex')}`;
  }

  /**
   * Determine severity level based on action
   */
  determineSeverity(event) {
    const highSeverityActions = ['delete', 'admin', 'permission_change', 'security'];
    const mediumSeverityActions = ['write', 'update', 'create'];

    if (event.outcome === 'failure') return 'high';
    if (highSeverityActions.some(action => event.action.includes(action))) return 'high';
    if (mediumSeverityActions.some(action => event.action.includes(action))) return 'medium';
    return 'low';
  }

  /**
   * Generate compliance tags for filtering
   */
  generateComplianceTags(event) {
    const tags = [];

    if (event.resource?.includes('governance')) tags.push('governance');
    if (event.action.includes('access') || event.action.includes('permission')) {
      tags.push('access_control', 'soc2');
    }
    if (event.action.includes('data') || event.action.includes('read')) {
      tags.push('data_access', 'gdpr');
    }
    if (event.outcome === 'failure') tags.push('security_incident');

    return tags;
  }

  /**
   * Calculate retention period (7 years for compliance)
   */
  calculateRetention(event) {
    const retentionYears = event.action.includes('security') ||
                           event.action.includes('financial') ? 7 : 3;
    const retentionDate = new Date();
    retentionDate.setFullYear(retentionDate.getFullYear() + retentionYears);
    return retentionDate.toISOString();
  }

  /**
   * Flush audit buffer to disk
   */
  async flushAudit() {
    if (this.auditBuffer.length === 0) return;

    try {
      await fs.mkdir(path.dirname(AUDIT_LOG), { recursive: true });

      const lines = this.auditBuffer
        .map(record => JSON.stringify(record))
        .join('\n') + '\n';

      await fs.appendFile(AUDIT_LOG, lines);
      this.auditBuffer = [];
    } catch (error) {
      console.error('Failed to flush audit records:', error.message);
      throw error;
    }
  }
}

/**
 * LineageQuery - Query interface for lineage data
 */
class LineageQuery {
  /**
   * Query lineage by entity
   *
   * @param {string} entity - Entity to query
   * @param {Object} options - Query options
   * @returns {Array} Lineage records
   */
  async queryByEntity(entity, options = {}) {
    const startTime = Date.now();
    const records = await this.readLineageLog();

    const results = records.filter(record =>
      record.source === entity || record.target === entity
    );

    const queryTime = Date.now() - startTime;
    if (queryTime > 500) {
      console.warn(`Query exceeded 500ms target: ${queryTime}ms`);
    }

    return this.applyOptions(results, options);
  }

  /**
   * Query lineage by actor
   */
  async queryByActor(actor, options = {}) {
    const records = await this.readLineageLog();
    const results = records.filter(record => record.actor === actor);
    return this.applyOptions(results, options);
  }

  /**
   * Query lineage by session
   */
  async queryBySession(sessionId, options = {}) {
    const records = await this.readLineageLog();
    const results = records.filter(record => record.session_id === sessionId);
    return this.applyOptions(results, options);
  }

  /**
   * Query lineage by time range
   */
  async queryByTimeRange(startTime, endTime, options = {}) {
    const records = await this.readLineageLog();
    const results = records.filter(record => {
      const recordTime = new Date(record.timestamp).getTime();
      return recordTime >= new Date(startTime).getTime() &&
             recordTime <= new Date(endTime).getTime();
    });
    return this.applyOptions(results, options);
  }

  /**
   * Build lineage graph for an entity
   */
  async buildLineageGraph(entity, depth = 3) {
    const visited = new Set();
    const graph = { nodes: [], edges: [] };

    await this.traverseLineage(entity, depth, visited, graph);

    return graph;
  }

  /**
   * Traverse lineage recursively
   */
  async traverseLineage(entity, depth, visited, graph) {
    if (depth === 0 || visited.has(entity)) return;

    visited.add(entity);
    graph.nodes.push({ id: entity, type: 'entity' });

    const records = await this.queryByEntity(entity, { limit: 100 });

    for (const record of records) {
      if (record.source && record.target) {
        graph.edges.push({
          from: record.source,
          to: record.target,
          type: record.type,
          transformation: record.transformation,
          timestamp: record.timestamp
        });

        // Recurse on connected entities
        if (record.target !== entity) {
          await this.traverseLineage(record.target, depth - 1, visited, graph);
        }
      }
    }
  }

  /**
   * Read lineage log file
   */
  async readLineageLog() {
    try {
      const data = await fs.readFile(LINEAGE_LOG, 'utf8');
      return data.split('\n')
        .filter(line => line.trim())
        .map(line => JSON.parse(line));
    } catch (error) {
      if (error.code === 'ENOENT') return [];
      throw error;
    }
  }

  /**
   * Apply query options (limit, offset, sort)
   */
  applyOptions(results, options) {
    let processed = [...results];

    // Sort
    if (options.sort) {
      const [field, direction] = options.sort.split(':');
      processed.sort((a, b) => {
        const aVal = a[field];
        const bVal = b[field];
        const comparison = aVal < bVal ? -1 : aVal > bVal ? 1 : 0;
        return direction === 'desc' ? -comparison : comparison;
      });
    }

    // Offset
    if (options.offset) {
      processed = processed.slice(options.offset);
    }

    // Limit
    if (options.limit) {
      processed = processed.slice(0, options.limit);
    }

    return processed;
  }
}

/**
 * AuditQuery - Query interface for audit trail
 */
class AuditQuery {
  /**
   * Query audit events by criteria
   */
  async query(criteria = {}) {
    const records = await this.readAuditLog();

    let results = records;

    if (criteria.actor) {
      results = results.filter(r => r.actor === criteria.actor);
    }

    if (criteria.action) {
      results = results.filter(r => r.action.includes(criteria.action));
    }

    if (criteria.resource) {
      results = results.filter(r => r.resource.includes(criteria.resource));
    }

    if (criteria.outcome) {
      results = results.filter(r => r.outcome === criteria.outcome);
    }

    if (criteria.severity) {
      results = results.filter(r => r.severity === criteria.severity);
    }

    if (criteria.compliance_tag) {
      results = results.filter(r =>
        r.compliance_tags.includes(criteria.compliance_tag)
      );
    }

    if (criteria.start_time) {
      results = results.filter(r =>
        new Date(r.timestamp) >= new Date(criteria.start_time)
      );
    }

    if (criteria.end_time) {
      results = results.filter(r =>
        new Date(r.timestamp) <= new Date(criteria.end_time)
      );
    }

    return results;
  }

  /**
   * Generate compliance report
   */
  async generateComplianceReport(period = '30d') {
    const startTime = Date.now();
    const records = await this.readAuditLog();

    // Calculate period
    const now = new Date();
    const daysAgo = parseInt(period.replace('d', ''));
    const periodStart = new Date(now - daysAgo * 24 * 60 * 60 * 1000);

    const relevantRecords = records.filter(r =>
      new Date(r.timestamp) >= periodStart
    );

    const report = {
      period: `${period} (${periodStart.toISOString()} to ${now.toISOString()})`,
      generated_at: now.toISOString(),
      total_events: relevantRecords.length,
      summary: {
        by_severity: this.groupBy(relevantRecords, 'severity'),
        by_outcome: this.groupBy(relevantRecords, 'outcome'),
        by_actor: this.groupBy(relevantRecords, 'actor'),
        by_compliance_tag: this.groupByArray(relevantRecords, 'compliance_tags')
      },
      security_incidents: relevantRecords.filter(r =>
        r.compliance_tags.includes('security_incident')
      ).length,
      failed_access_attempts: relevantRecords.filter(r =>
        r.action.includes('access') && r.outcome === 'failure'
      ).length,
      data_access_events: relevantRecords.filter(r =>
        r.compliance_tags.includes('data_access')
      ).length,
      gdpr_events: relevantRecords.filter(r =>
        r.compliance_tags.includes('gdpr')
      ).length,
      soc2_events: relevantRecords.filter(r =>
        r.compliance_tags.includes('soc2')
      ).length,
      generation_time_ms: Date.now() - startTime
    };

    if (report.generation_time_ms > 2000) {
      console.warn(`Report generation exceeded 2s target: ${report.generation_time_ms}ms`);
    }

    return report;
  }

  /**
   * Read audit log file
   */
  async readAuditLog() {
    try {
      const data = await fs.readFile(AUDIT_LOG, 'utf8');
      return data.split('\n')
        .filter(line => line.trim())
        .map(line => JSON.parse(line));
    } catch (error) {
      if (error.code === 'ENOENT') return [];
      throw error;
    }
  }

  /**
   * Group records by field
   */
  groupBy(records, field) {
    const grouped = {};
    for (const record of records) {
      const key = record[field];
      grouped[key] = (grouped[key] || 0) + 1;
    }
    return grouped;
  }

  /**
   * Group records by array field
   */
  groupByArray(records, field) {
    const grouped = {};
    for (const record of records) {
      const values = record[field] || [];
      for (const value of values) {
        grouped[value] = (grouped[value] || 0) + 1;
      }
    }
    return grouped;
  }
}

// Export classes
module.exports = {
  LineageTracker,
  AuditLogger,
  LineageQuery,
  AuditQuery
};

// CLI interface
if (require.main === module) {
  const command = process.argv[2];

  if (command === 'query-lineage') {
    const entity = process.argv[3];
    const query = new LineageQuery();
    query.queryByEntity(entity).then(results => {
      console.log(JSON.stringify(results, null, 2));
    });
  } else if (command === 'query-audit') {
    const criteria = JSON.parse(process.argv[3] || '{}');
    const query = new AuditQuery();
    query.query(criteria).then(results => {
      console.log(JSON.stringify(results, null, 2));
    });
  } else if (command === 'compliance-report') {
    const period = process.argv[3] || '30d';
    const query = new AuditQuery();
    query.generateComplianceReport(period).then(report => {
      console.log(JSON.stringify(report, null, 2));
    });
  } else if (command === 'lineage-graph') {
    const entity = process.argv[3];
    const depth = parseInt(process.argv[4] || '3');
    const query = new LineageQuery();
    query.buildLineageGraph(entity, depth).then(graph => {
      console.log(JSON.stringify(graph, null, 2));
    });
  } else {
    console.log('Usage:');
    console.log('  node lineage.js query-lineage <entity>');
    console.log('  node lineage.js query-audit \'{"actor": "..."}\'');
    console.log('  node lineage.js compliance-report [period]');
    console.log('  node lineage.js lineage-graph <entity> [depth]');
  }
}
