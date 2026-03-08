#!/usr/bin/env node

/**
 * Catalog CLI
 *
 * Command-line interface for the Unified Catalog Manager
 * Provides asset discovery, search, lineage, and tagging operations
 */

const CatalogManager = require('./catalog-manager');

const commands = {
  discover: 'Run full asset discovery and register all assets',
  search: 'Search assets using natural language (e.g., "Find tasks assigned to security master")',
  lineage: 'Get lineage for an asset ID',
  tag: 'Tag an asset with metadata',
  stats: 'Show catalog statistics',
  help: 'Show this help message'
};

async function main() {
  const args = process.argv.slice(2);
  const command = args[0];

  if (!command || command === 'help') {
    console.log('\nUnified Catalog Manager CLI\n');
    console.log('Usage: node catalog-cli.js <command> [args]\n');
    console.log('Commands:');
    for (const [cmd, desc] of Object.entries(commands)) {
      console.log(`  ${cmd.padEnd(15)} ${desc}`);
    }
    console.log('\nExamples:');
    console.log('  node catalog-cli.js discover');
    console.log('  node catalog-cli.js search "Find all tasks assigned to security master"');
    console.log('  node catalog-cli.js lineage coordination.tasks.task_queue');
    console.log('  node catalog-cli.js tag coordination.tasks.task_queue \'{"sensitivity": "internal"}\'');
    console.log('  node catalog-cli.js stats\n');
    return;
  }

  const catalog = new CatalogManager();

  try {
    switch (command) {
      case 'discover':
        console.log('Starting asset discovery...\n');
        const results = await catalog.discoverAssets();
        console.log('\nDiscovery Results:');
        console.log(`  Total discovered: ${results.discovered}`);
        console.log(`  Successfully registered: ${results.registered}`);
        console.log(`  Data assets: ${results.assets_by_type.data}`);
        console.log(`  AI assets: ${results.assets_by_type.ai}`);
        console.log(`  Model assets: ${results.assets_by_type.model}`);
        if (results.errors.length > 0) {
          console.log(`\n  Errors: ${results.errors.length}`);
          results.errors.forEach(err => {
            console.log(`    - ${err.asset}: ${err.error}`);
          });
        }
        break;

      case 'search':
        const query = args.slice(1).join(' ');
        if (!query) {
          console.error('Error: Search query required');
          console.log('Example: node catalog-cli.js search "Find all PII assets"');
          process.exit(1);
        }
        console.log(`Searching: "${query}"\n`);
        const searchResults = await catalog.searchAssets(query);
        if (searchResults.length === 0) {
          console.log('No matching assets found.');
        } else {
          console.log(`Found ${searchResults.length} matching assets:\n`);
          searchResults.forEach((asset, i) => {
            console.log(`${i + 1}. ${asset.asset_name || asset.asset_id}`);
            console.log(`   ID: ${asset.asset_id}`);
            console.log(`   Type: ${asset.asset_type}`);
            console.log(`   Namespace: ${asset.namespace}`);
            if (asset.sensitivity) console.log(`   Sensitivity: ${asset.sensitivity}`);
            if (asset.owner) console.log(`   Owner: ${asset.owner}`);
            if (asset.tags) console.log(`   Tags: ${asset.tags.join(', ')}`);
            console.log('');
          });
        }
        break;

      case 'lineage':
        const assetId = args[1];
        if (!assetId) {
          console.error('Error: Asset ID required');
          console.log('Example: node catalog-cli.js lineage coordination.tasks.task_queue');
          process.exit(1);
        }
        console.log(`Getting lineage for: ${assetId}\n`);
        const lineage = await catalog.getAssetLineage(assetId);
        console.log('Upstream dependencies:');
        if (lineage.upstream.length === 0) {
          console.log('  None');
        } else {
          lineage.upstream.forEach(l => {
            console.log(`  - ${l.source_asset} -> ${l.target_asset} (${l.transformation})`);
          });
        }
        console.log('\nDownstream dependencies:');
        if (lineage.downstream.length === 0) {
          console.log('  None');
        } else {
          lineage.downstream.forEach(l => {
            console.log(`  - ${l.source_asset} -> ${l.target_asset} (${l.transformation})`);
          });
        }
        console.log('\nAI usage:');
        if (lineage.ai_usage.length === 0) {
          console.log('  None');
        } else {
          lineage.ai_usage.forEach(l => {
            console.log(`  - ${l.agent_id} performed ${l.operation}`);
          });
        }
        console.log('\nDecision lineage:');
        if (lineage.decisions.length === 0) {
          console.log('  None');
        } else {
          lineage.decisions.forEach(l => {
            console.log(`  - ${l.decision_id} (confidence: ${l.confidence})`);
          });
        }
        break;

      case 'tag':
        const tagAssetId = args[1];
        const tagData = args[2];
        if (!tagAssetId || !tagData) {
          console.error('Error: Asset ID and tag data required');
          console.log('Example: node catalog-cli.js tag coordination.tasks.task_queue \'{"sensitivity": "internal"}\'');
          process.exit(1);
        }
        const tags = JSON.parse(tagData);
        console.log(`Tagging asset: ${tagAssetId}\n`);
        const taggedAsset = await catalog.tagAsset(tagAssetId, tags);
        console.log('Asset tagged successfully:');
        console.log(`  Sensitivity: ${taggedAsset.sensitivity || 'not set'}`);
        console.log(`  Owner: ${taggedAsset.owner || 'not set'}`);
        console.log(`  Tags: ${taggedAsset.tags?.join(', ') || 'none'}`);
        break;

      case 'stats':
        console.log('Catalog Statistics:\n');
        const stats = await catalog.getStatistics();
        console.log(`  Total assets: ${stats.total_assets}`);
        console.log(`  Data assets: ${stats.data_assets}`);
        console.log(`  AI assets: ${stats.ai_assets}`);
        console.log(`  Model assets: ${stats.model_assets}`);
        console.log(`  Last discovery: ${stats.last_discovery || 'never'}`);
        console.log(`  Last updated: ${stats.last_updated}`);
        break;

      default:
        console.error(`Unknown command: ${command}`);
        console.log('Run "node catalog-cli.js help" for usage information');
        process.exit(1);
    }
  } catch (error) {
    console.error('\nError:', error.message);
    process.exit(1);
  }
}

main();
