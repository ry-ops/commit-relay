#!/usr/bin/env node
// lib/governance/lineage-tracker.js
// Automated Data Lineage & Audit Trail Tracker
// Part of Phase 6: Governance Upgrade
//
// Responsibilities:
// - Track data transformations and lineage
// - Record AI decision provenance
// - Maintain audit trails
// - Enable compliance reporting

const fs = require('fs').promises;
const path = require('path');
const crypto = require('crypto');

class LineageTracker {
  constructor(lineagePath = 'coordination/catalog/lineage') {
    this.lineagePath = lineagePath;
    this.auditLogPath = 'coordination/governance/access-log.jsonl';
  }

  /**
   * Initialize lineage tracker
   */
  async initialize() {
    try {
      await fs.mkdir(this.lineagePath, { recursive: true });
      await fs.mkdir(path.dirname(this.auditLogPath), { recursive: true });

      console.log('Lineage Tracker initialized');
      return true;
    } catch (error) {
      console.error('Failed to initialize Lineage Tracker:', error.message);
      return false;
    }
  }

  /**
   * Record data transformation event
   */
  async recordTransformation(transformation) {
    const event = {
      event_id: crypto.randomUUID(),
      event_type: 'data_transformation',
      timestamp: new Date().toISOString(),
      source_asset: transformation.source,
      target_asset: transformation.target,
      transformation_type: transformation.type,
      actor: transformation.actor,
      metadata: {
        operation: transformation.operation,
        changes: transformation.changes || {},
        reason: transformation.reason || ''
      }
    };

    // Record lineage for source asset
    await this._appendLineageEvent(transformation.source, event);

    // Record lineage for target asset
    await this._appendLineageEvent(transformation.target, event);

    // Log to audit trail
    await this._appendAuditLog(event);

    console.log(`Recorded transformation: \${transformation.source} -> \${transformation.target}`);

    return event.event_id;
  }

  /**
   * Record AI decision event
   */
  async recordAIDecision(decision) {
    const event = {
      event_id: crypto.randomUUID(),
      event_type: 'ai_decision',
      timestamp: new Date().toISOString(),
      ai_agent: decision.agent,
      decision_type: decision.type,
      input_assets: decision.inputs || [],
      output_assets: decision.outputs || [],
      confidence_score: decision.confidence || null,
      metadata: {
        reasoning: decision.reasoning || '',
        alternatives_considered: decision.alternatives || [],
        context: decision.context || {}
      }
    };

    // Record lineage for input assets
    for (const input of decision.inputs || []) {
      await this._appendLineageEvent(input, event);
    }

    // Record lineage for output assets
    for (const output of decision.outputs || []) {
      await this._appendLineageEvent(output, event);
    }

    // Log to audit trail
    await this._appendAuditLog(event);

    console.log(`Recorded AI decision by \${decision.agent}: \${decision.type}`);

    return event.event_id;
  }

  /**
   * Record access event
   */
  async recordAccess(access) {
    const event = {
      event_id: crypto.randomUUID(),
      event_type: 'asset_access',
      timestamp: new Date().toISOString(),
      actor: access.actor,
      asset_id: access.asset,
      access_type: access.type, // read, write, delete
      namespace: access.namespace,
      permitted: access.permitted !== false,
      metadata: {
        purpose: access.purpose || '',
        ip_address: access.ip || null,
        user_agent: access.user_agent || null
      }
    };

    // Record lineage for accessed asset
    await this._appendLineageEvent(access.asset, event);

    // Log to audit trail
    await this._appendAuditLog(event);

    console.log(`Recorded access: \${access.actor} \${access.type} \${access.asset}`);

    return event.event_id;
  }

  /**
   * Get complete lineage for an asset
   */
  async getAssetLineage(assetId) {
    const lineageFilePath = path.join(this.lineagePath, `\${assetId}.json`);

    try {
      const lineageContent = await fs.readFile(lineageFilePath, 'utf8');
      const lineage = JSON.parse(lineageContent);

      // Sort events by timestamp
      lineage.lineage_events.sort((a, b) => 
        new Date(a.timestamp) - new Date(b.timestamp)
      );

      return lineage;
    } catch (error) {
      // No lineage recorded yet
      return {
        asset_id: assetId,
        lineage_events: [],
        created_at: new Date().toISOString()
      };
    }
  }

  /**
   * Get lineage graph (upstream and downstream dependencies)
   */
  async getLineageGraph(assetId, depth = 3) {
    const graph = {
      root: assetId,
      upstream: [],   // Assets this depends on
      downstream: [], // Assets that depend on this
      depth: depth
    };

    const visited = new Set();
    
    // Build upstream dependencies
    await this._buildUpstream(assetId, graph.upstream, visited, depth);

    // Build downstream dependencies
    visited.clear();
    await this._buildDownstream(assetId, graph.downstream, visited, depth);

    return graph;
  }

  /**
   * Query audit log
   */
  async queryAuditLog(query) {
    const events = [];

    try {
      const auditContent = await fs.readFile(this.auditLogPath, 'utf8');
      const lines = auditContent.trim().split('\n');

      for (const line of lines) {
        const event = JSON.parse(line);

        // Apply filters
        let matches = true;

        if (query.event_type && event.event_type !== query.event_type) {
          matches = false;
        }

        if (query.actor && event.actor !== query.actor) {
          matches = false;
        }

        if (query.asset_id && event.asset_id !== query.asset_id) {
          matches = false;
        }

        if (query.start_time && new Date(event.timestamp) < new Date(query.start_time)) {
          matches = false;
        }

        if (query.end_time && new Date(event.timestamp) > new Date(query.end_time)) {
          matches = false;
        }

        if (matches) {
          events.push(event);
        }
      }
    } catch (error) {
      // Audit log doesn't exist yet
      return events;
    }

    // Sort by timestamp (newest first)
    events.sort((a, b) => new Date(b.timestamp) - new Date(a.timestamp));

    // Apply limit if specified
    if (query.limit) {
      return events.slice(0, query.limit);
    }

    return events;
  }

  /**
   * Generate compliance report
   */
  async generateComplianceReport(options = {}) {
    const report = {
      report_id: crypto.randomUUID(),
      generated_at: new Date().toISOString(),
      time_range: {
        start: options.start_time || new Date(Date.now() - 30*24*60*60*1000).toISOString(),
        end: options.end_time || new Date().toISOString()
      },
      metrics: {
        total_access_events: 0,
        total_transformations: 0,
        total_ai_decisions: 0,
        unauthorized_attempts: 0
      },
      access_by_actor: {},
      access_by_namespace: {},
      ai_decisions_by_agent: {},
      transformations_by_type: {}
    };

    const events = await this.queryAuditLog({
      start_time: report.time_range.start,
      end_time: report.time_range.end
    });

    for (const event of events) {
      // Count event types
      if (event.event_type === 'asset_access') {
        report.metrics.total_access_events++;

        if (!event.permitted) {
          report.metrics.unauthorized_attempts++;
        }

        // Count by actor
        report.access_by_actor[event.actor] = (report.access_by_actor[event.actor] || 0) + 1;

        // Count by namespace
        if (event.namespace) {
          report.access_by_namespace[event.namespace] = 
            (report.access_by_namespace[event.namespace] || 0) + 1;
        }
      } else if (event.event_type === 'data_transformation') {
        report.metrics.total_transformations++;

        const type = event.transformation_type || 'unknown';
        report.transformations_by_type[type] = (report.transformations_by_type[type] || 0) + 1;
      } else if (event.event_type === 'ai_decision') {
        report.metrics.total_ai_decisions++;

        report.ai_decisions_by_agent[event.ai_agent] = 
          (report.ai_decisions_by_agent[event.ai_agent] || 0) + 1;
      }
    }

    return report;
  }

  /**
   * Append lineage event to asset's lineage file
   */
  async _appendLineageEvent(assetId, event) {
    const lineage = await this.getAssetLineage(assetId);

    lineage.lineage_events.push(event);
    lineage.updated_at = new Date().toISOString();

    const lineageFilePath = path.join(this.lineagePath, `\${assetId}.json`);
    await fs.writeFile(lineageFilePath, JSON.stringify(lineage, null, 2));
  }

  /**
   * Append event to audit log
   */
  async _appendAuditLog(event) {
    const logEntry = JSON.stringify(event) + '\n';
    await fs.appendFile(this.auditLogPath, logEntry);
  }

  /**
   * Build upstream dependency graph
   */
  async _buildUpstream(assetId, upstream, visited, depth) {
    if (depth === 0 || visited.has(assetId)) {
      return;
    }

    visited.add(assetId);
    const lineage = await this.getAssetLineage(assetId);

    for (const event of lineage.lineage_events) {
      if (event.event_type === 'data_transformation' && event.target_asset === assetId) {
        const source = event.source_asset;
        
        if (!upstream.find(u => u.asset_id === source)) {
          upstream.push({
            asset_id: source,
            relationship: 'source',
            event_id: event.event_id
          });

          await this._buildUpstream(source, upstream, visited, depth - 1);
        }
      }
    }
  }

  /**
   * Build downstream dependency graph
   */
  async _buildDownstream(assetId, downstream, visited, depth) {
    if (depth === 0 || visited.has(assetId)) {
      return;
    }

    visited.add(assetId);
    const lineage = await this.getAssetLineage(assetId);

    for (const event of lineage.lineage_events) {
      if (event.event_type === 'data_transformation' && event.source_asset === assetId) {
        const target = event.target_asset;
        
        if (!downstream.find(d => d.asset_id === target)) {
          downstream.push({
            asset_id: target,
            relationship: 'derived',
            event_id: event.event_id
          });

          await this._buildDownstream(target, downstream, visited, depth - 1);
        }
      }
    }
  }
}

// CLI interface
if (require.main === module) {
  const action = process.argv[2];
  const lineageTracker = new LineageTracker();

  (async () => {
    await lineageTracker.initialize();

    switch (action) {
      case 'lineage':
        const assetId = process.argv[3];
        const lineage = await lineageTracker.getAssetLineage(assetId);
        console.log('\nAsset Lineage:');
        console.log(JSON.stringify(lineage, null, 2));
        break;

      case 'graph':
        const graphAssetId = process.argv[3];
        const depth = parseInt(process.argv[4]) || 3;
        const graph = await lineageTracker.getLineageGraph(graphAssetId, depth);
        console.log('\nLineage Graph:');
        console.log(JSON.stringify(graph, null, 2));
        break;

      case 'audit':
        const query = {
          event_type: process.argv[3],
          actor: process.argv[4],
          limit: parseInt(process.argv[5]) || 100
        };
        const events = await lineageTracker.queryAuditLog(query);
        console.log(`\nAudit Log (\${events.length} events):`);
        console.log(JSON.stringify(events, null, 2));
        break;

      case 'report':
        const report = await lineageTracker.generateComplianceReport();
        console.log('\nCompliance Report:');
        console.log(JSON.stringify(report, null, 2));
        break;

      default:
        console.log('Usage: node lineage-tracker.js <action>');
        console.log('Actions:');
        console.log('  lineage <asset-id>           - Get asset lineage');
        console.log('  graph <asset-id> [depth]     - Get lineage graph');
        console.log('  audit [type] [actor] [limit] - Query audit log');
        console.log('  report                       - Generate compliance report');
        break;
    }
  })();
}

module.exports = LineageTracker;
