#!/usr/bin/env node
// lib/governance/catalog-manager.js
// Unified Data & AI Catalog Manager
// Part of Phase 6: Governance Upgrade
//
// Responsibilities:
// - Asset discovery and registration
// - Metadata extraction and tagging
// - Sensitivity classification
// - Search and query interface
// - Lineage tracking integration

const fs = require('fs').promises;
const path = require('path');
const crypto = require('crypto');

class CatalogManager {
  constructor(catalogPath = 'coordination/catalog') {
    this.catalogPath = catalogPath;
    this.metastorePath = path.join(catalogPath, 'metastore.json');
    this.namespacesPath = path.join(catalogPath, 'namespaces');
    this.lineagePath = path.join(catalogPath, 'lineage');
  }

  /**
   * Initialize catalog manager
   */
  async initialize() {
    try {
      // Load metastore
      const metastoreContent = await fs.readFile(this.metastorePath, 'utf8');
      this.metastore = JSON.parse(metastoreContent);

      console.log(`Catalog Manager initialized: \${this.metastore.catalog_name} v\${this.metastore.version}`);
      return true;
    } catch (error) {
      console.error('Failed to initialize Catalog Manager:', error.message);
      return false;
    }
  }

  /**
   * Discover all assets in the system
   */
  async discoverAssets() {
    console.log('Starting asset discovery...');

    const discoveredAssets = {
      data_assets: [],
      ai_assets: [],
      model_assets: []
    };

    // Scan coordination directory
    const coordinationPath = 'coordination';

    // Discover data assets
    const dataAssets = await this._scanDataAssets(coordinationPath);
    discoveredAssets.data_assets = dataAssets;

    // Discover AI assets
    const aiAssets = await this._scanAIAssets();
    discoveredAssets.ai_assets = aiAssets;

    // Discover model assets (currently none, but framework ready)
    discoveredAssets.model_assets = [];

    console.log(`Discovery complete: \${dataAssets.length} data assets, \${aiAssets.length} AI assets`);

    return discoveredAssets;
  }

  /**
   * Scan for data assets (JSON, JSONL files)
   */
  async _scanDataAssets(basePath) {
    const dataAssets = [];

    const scanPatterns = [
      { pattern: 'task-queue.json', namespace: 'coordinator', type: 'task-queue', sensitivity: 'internal' },
      { pattern: 'token-budget.json', namespace: 'coordinator', type: 'budget-tracking', sensitivity: 'internal' },
      { pattern: 'worker-pool.json', namespace: 'coordinator', type: 'worker-management', sensitivity: 'internal' },
      { pattern: 'routing-decisions.jsonl', namespace: 'coordinator', type: 'routing-history', sensitivity: 'internal' },
      { pattern: 'dashboard-events.jsonl', namespace: 'dashboard', type: 'event-stream', sensitivity: 'internal' },
      { pattern: 'metrics-snapshots.jsonl', namespace: 'dashboard', type: 'metrics', sensitivity: 'internal' },
      { pattern: 'health-reports.jsonl', namespace: 'dashboard', type: 'health-monitoring', sensitivity: 'internal' },
      { pattern: 'governance/access-log.jsonl', namespace: 'governance', type: 'audit-trail', sensitivity: 'confidential' },
      { pattern: 'governance/pii-scan-results.jsonl', namespace: 'governance', type: 'pii-detection', sensitivity: 'confidential' },
      { pattern: 'patterns/failure-patterns.jsonl', namespace: 'self-healing', type: 'pattern-detection', sensitivity: 'internal' },
      { pattern: 'patterns/auto-fix-history.jsonl', namespace: 'self-healing', type: 'auto-fix-log', sensitivity: 'internal' }
    ];

    for (const { pattern, namespace, type, sensitivity } of scanPatterns) {
      const assetPath = path.join(basePath, pattern);

      try {
        const stats = await fs.stat(assetPath);

        const asset = {
          asset_id: this._generateAssetId(assetPath),
          asset_name: path.basename(assetPath),
          asset_type: type,
          namespace: namespace,
          file_path: assetPath,
          file_size: stats.size,
          last_modified: stats.mtime.toISOString(),
          sensitivity_level: sensitivity,
          discovered_at: new Date().toISOString(),
          metadata: {
            format: pattern.endsWith('.jsonl') ? 'jsonl' : 'json',
            extension: path.extname(assetPath)
          }
        };

        dataAssets.push(asset);
      } catch (error) {
        // File doesn't exist yet, skip
        continue;
      }
    }

    return dataAssets;
  }

  /**
   * Scan for AI assets (agent prompts, master agents, workers)
   */
  async _scanAIAssets() {
    const aiAssets = [];

    // Master agents
    const masters = [
      { name: 'coordinator-master', namespace: 'coordinator', type: 'master-agent', prompt: 'coordination/masters/coordinator/prompt.md' },
      { name: 'development-master', namespace: 'development', type: 'master-agent', prompt: 'coordination/masters/development/prompt.md' },
      { name: 'security-master', namespace: 'security', type: 'master-agent', prompt: 'coordination/masters/security/prompt.md' },
      { name: 'inventory-master', namespace: 'inventory', type: 'master-agent', prompt: 'coordination/masters/inventory/prompt.md' },
      { name: 'cicd-master', namespace: 'cicd', type: 'master-agent', prompt: 'coordination/masters/cicd/prompt.md' },
      { name: 'dashboard-agent', namespace: 'dashboard', type: 'observability-agent', prompt: 'coordination/masters/dashboard/prompt.md' }
    ];

    for (const master of masters) {
      try {
        const stats = await fs.stat(master.prompt);

        const asset = {
          asset_id: this._generateAssetId(master.name),
          asset_name: master.name,
          asset_type: master.type,
          namespace: master.namespace,
          prompt_path: master.prompt,
          prompt_size: stats.size,
          last_modified: stats.mtime.toISOString(),
          sensitivity_level: 'internal',
          discovered_at: new Date().toISOString(),
          metadata: {
            agent_role: this._extractAgentRole(master.namespace),
            capabilities: this._extractCapabilities(master.namespace)
          }
        };

        aiAssets.push(asset);
      } catch (error) {
        // Prompt doesn't exist, skip
        continue;
      }
    }

    // Worker templates
    const workerTypes = [
      { name: 'implementation-worker', namespace: 'development', type: 'worker-agent' },
      { name: 'fix-worker', namespace: 'development', type: 'worker-agent' },
      { name: 'test-worker', namespace: 'development', type: 'worker-agent' },
      { name: 'scan-worker', namespace: 'security', type: 'worker-agent' },
      { name: 'security-fix-worker', namespace: 'security', type: 'worker-agent' },
      { name: 'documentation-worker', namespace: 'inventory', type: 'worker-agent' },
      { name: 'analysis-worker', namespace: 'inventory', type: 'worker-agent' }
    ];

    for (const worker of workerTypes) {
      const asset = {
        asset_id: this._generateAssetId(worker.name),
        asset_name: worker.name,
        asset_type: worker.type,
        namespace: worker.namespace,
        sensitivity_level: 'internal',
        discovered_at: new Date().toISOString(),
        metadata: {
          worker_category: worker.namespace,
          spawnable: true
        }
      };

      aiAssets.push(asset);
    }

    return aiAssets;
  }

  /**
   * Register an asset in the catalog
   */
  async registerAsset(asset) {
    const namespace = this.metastore.namespaces.find(ns => ns.name === asset.namespace);

    if (!namespace) {
      throw new Error(`Namespace not found: \${asset.namespace}`);
    }

    // Determine asset category
    let assetCategory;
    if (asset.asset_type.includes('agent') || asset.asset_type.includes('worker')) {
      assetCategory = 'ai_assets';
    } else if (asset.asset_type.includes('model')) {
      assetCategory = 'model_assets';
    } else {
      assetCategory = 'data_assets';
    }

    // Add to namespace if not already present
    if (!namespace.assets[assetCategory].includes(asset.asset_name)) {
      namespace.assets[assetCategory].push(asset.asset_name);
    }

    // Save asset details to namespace directory
    const namespacePath = path.join(this.namespacesPath, asset.namespace);
    await fs.mkdir(namespacePath, { recursive: true });

    const assetFilePath = path.join(namespacePath, `\${asset.asset_id}.json`);
    await fs.writeFile(assetFilePath, JSON.stringify(asset, null, 2));

    console.log(`Registered asset: \${asset.asset_name} in \${asset.namespace}`);

    return asset.asset_id;
  }

  /**
   * Update metastore statistics
   */
  async updateStatistics() {
    const stats = {
      total_namespaces: this.metastore.namespaces.length,
      total_data_assets: 0,
      total_ai_assets: 0,
      total_model_assets: 0,
      last_scan: new Date().toISOString()
    };

    for (const namespace of this.metastore.namespaces) {
      stats.total_data_assets += namespace.assets.data_assets.length;
      stats.total_ai_assets += namespace.assets.ai_assets.length;
      stats.total_model_assets += namespace.assets.model_assets.length;
    }

    this.metastore.catalog_stats = stats;
    this.metastore.last_updated = new Date().toISOString();

    await fs.writeFile(this.metastorePath, JSON.stringify(this.metastore, null, 2));

    console.log(`Catalog statistics updated: \${stats.total_data_assets} data, \${stats.total_ai_assets} AI, \${stats.total_model_assets} model assets`);
  }

  /**
   * Search assets by criteria
   */
  async searchAssets(criteria) {
    const results = [];

    for (const namespace of this.metastore.namespaces) {
      // Filter by namespace if specified
      if (criteria.namespace && namespace.name !== criteria.namespace) {
        continue;
      }

      // Filter by sensitivity level if specified
      if (criteria.sensitivity && namespace.sensitivity_level !== criteria.sensitivity) {
        continue;
      }

      // Filter by asset type
      let assetsToSearch = [];
      if (criteria.asset_category === 'data' || !criteria.asset_category) {
        assetsToSearch.push(...namespace.assets.data_assets);
      }
      if (criteria.asset_category === 'ai' || !criteria.asset_category) {
        assetsToSearch.push(...namespace.assets.ai_assets);
      }
      if (criteria.asset_category === 'model' || !criteria.asset_category) {
        assetsToSearch.push(...namespace.assets.model_assets);
      }

      results.push({
        namespace: namespace.name,
        assets: assetsToSearch
      });
    }

    return results;
  }

  /**
   * Get asset lineage
   */
  async getAssetLineage(assetId) {
    const lineageFilePath = path.join(this.lineagePath, `\${assetId}.json`);

    try {
      const lineageContent = await fs.readFile(lineageFilePath, 'utf8');
      return JSON.parse(lineageContent);
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
   * Record lineage event
   */
  async recordLineageEvent(assetId, event) {
    const lineage = await this.getAssetLineage(assetId);

    lineage.lineage_events.push({
      event_id: crypto.randomUUID(),
      event_type: event.type,
      timestamp: new Date().toISOString(),
      actor: event.actor,
      action: event.action,
      metadata: event.metadata || {}
    });

    lineage.updated_at = new Date().toISOString();

    const lineageFilePath = path.join(this.lineagePath, `\${assetId}.json`);
    await fs.mkdir(this.lineagePath, { recursive: true });
    await fs.writeFile(lineageFilePath, JSON.stringify(lineage, null, 2));

    console.log(`Recorded lineage event for \${assetId}: \${event.type}`);
  }

  /**
   * Generate asset ID from path or name
   */
  _generateAssetId(input) {
    return 'asset-' + crypto.createHash('md5').update(input).digest('hex').substring(0, 12);
  }

  /**
   * Extract agent role from namespace
   */
  _extractAgentRole(namespace) {
    const roles = {
      coordinator: 'Task routing and master coordination',
      development: 'Feature implementation and bug fixes',
      security: 'Security scanning and vulnerability remediation',
      inventory: 'Repository cataloging and dependency tracking',
      cicd: 'Build automation and deployment workflows',
      dashboard: 'System monitoring and observability'
    };

    return roles[namespace] || 'Unknown role';
  }

  /**
   * Extract capabilities from namespace
   */
  _extractCapabilities(namespace) {
    const capabilities = {
      coordinator: ['task-routing', 'moe-routing', 'handoff-management'],
      development: ['code-implementation', 'bug-fixing', 'testing'],
      security: ['vulnerability-scanning', 'cve-remediation', 'security-analysis'],
      inventory: ['repository-cataloging', 'dependency-analysis', 'documentation'],
      cicd: ['build-automation', 'deployment', 'release-management'],
      dashboard: ['metrics-collection', 'health-monitoring', 'event-tracking']
    };

    return capabilities[namespace] || [];
  }

  /**
   * Generate catalog report
   */
  async generateReport() {
    const report = {
      catalog_name: this.metastore.catalog_name,
      report_generated_at: new Date().toISOString(),
      summary: this.metastore.catalog_stats,
      namespaces: []
    };

    for (const namespace of this.metastore.namespaces) {
      report.namespaces.push({
        name: namespace.name,
        type: namespace.type,
        owner: namespace.owner,
        sensitivity_level: namespace.sensitivity_level,
        asset_counts: {
          data: namespace.assets.data_assets.length,
          ai: namespace.assets.ai_assets.length,
          model: namespace.assets.model_assets.length
        },
        assets: namespace.assets,
        access_policies: namespace.access_policies,
        compliance_tags: namespace.compliance_tags
      });
    }

    return report;
  }
}

// CLI interface
if (require.main === module) {
  const action = process.argv[2];
  const catalogManager = new CatalogManager();

  (async () => {
    await catalogManager.initialize();

    switch (action) {
      case 'discover':
        const discovered = await catalogManager.discoverAssets();
        console.log('\nDiscovered Assets:');
        console.log(JSON.stringify(discovered, null, 2));
        break;

      case 'register':
        const assets = await catalogManager.discoverAssets();
        for (const asset of [...assets.data_assets, ...assets.ai_assets]) {
          await catalogManager.registerAsset(asset);
        }
        await catalogManager.updateStatistics();
        console.log('\nAll assets registered successfully');
        break;

      case 'report':
        const report = await catalogManager.generateReport();
        console.log('\nCatalog Report:');
        console.log(JSON.stringify(report, null, 2));
        break;

      case 'search':
        const criteria = {
          namespace: process.argv[3],
          sensitivity: process.argv[4],
          asset_category: process.argv[5]
        };
        const results = await catalogManager.searchAssets(criteria);
        console.log('\nSearch Results:');
        console.log(JSON.stringify(results, null, 2));
        break;

      default:
        console.log('Usage: node catalog-manager.js <action>');
        console.log('Actions:');
        console.log('  discover           - Discover all assets');
        console.log('  register           - Register discovered assets');
        console.log('  report             - Generate catalog report');
        console.log('  search <ns> <sens> - Search assets');
        break;
    }
  })();
}

module.exports = CatalogManager;
