# Unified Catalog - Quick Start Guide

## Installation & Setup

The catalog is ready to use immediately - no installation required!

## Running Asset Discovery

Discover and register all assets in the system:

```bash
# Full discovery with script
./scripts/run-catalog-discovery.sh

# Or use CLI directly
node lib/governance/catalog-cli.js discover
```

## Natural Language Search

Search for assets using plain English:

```bash
# Find master agents
node lib/governance/catalog-cli.js search "Find all master agent assets"

# Find routing data
node lib/governance/catalog-cli.js search "routing decisions"

# Find by owner
node lib/governance/catalog-cli.js search "Find assets owned by development master"

# Find by type
node lib/governance/catalog-cli.js search "Show all worker specifications"
```

## Viewing Asset Lineage

Track data flow and AI usage:

```bash
# Get lineage for an asset
node lib/governance/catalog-cli.js lineage coordination.tasks.task_queue

# This shows:
# - Upstream dependencies (where data comes from)
# - Downstream dependencies (where data flows to)
# - AI usage (which agents accessed the asset)
# - Decision lineage (routing decisions involving this asset)
```

## Tagging Assets

Add metadata and sensitivity classifications:

```bash
# Tag with sensitivity level
node lib/governance/catalog-cli.js tag coordination.tasks.task_queue '{"sensitivity": "confidential"}'

# Tag with owner
node lib/governance/catalog-cli.js tag coordination.tasks.task_queue '{"owner": "coordinator-master"}'

# Tag with custom tags
node lib/governance/catalog-cli.js tag coordination.tasks.task_queue '{"tags": ["high-priority", "production"]}'

# Tag with compliance information
node lib/governance/catalog-cli.js tag coordination.tasks.task_queue '{"compliance_tags": ["GDPR", "SOC2"]}'
```

## Viewing Statistics

Get catalog overview:

```bash
node lib/governance/catalog-cli.js stats
```

Output:
```
Catalog Statistics:
  Total assets: 74
  Data assets: 69
  AI assets: 5
  Model assets: 0
  Last discovery: 2025-11-11T16:59:46.914Z
  Last updated: 2025-11-11T16:59:46.913Z
```

## Programmatic Usage

Use the catalog in your code:

```javascript
const CatalogManager = require('./lib/governance/catalog-manager');

async function example() {
  const catalog = new CatalogManager();

  // Run discovery
  const results = await catalog.discoverAssets();
  console.log(`Registered ${results.registered} assets`);

  // Search assets
  const masterAgents = await catalog.searchAssets("master agent");
  console.log(`Found ${masterAgents.length} master agents`);

  // Get lineage
  const lineage = await catalog.getAssetLineage("coordination.tasks.task_queue");
  console.log(`Upstream: ${lineage.upstream.length} dependencies`);
  console.log(`AI usage: ${lineage.ai_usage.length} operations`);

  // Tag asset
  await catalog.tagAsset("coordination.tasks.task_queue", {
    sensitivity: "internal",
    owner: "coordinator-master",
    tags: ["critical", "production"]
  });

  // Record lineage
  await catalog.recordDataLineage(
    "coordination.tasks.task_queue",
    "coordination.tasks.completed_tasks",
    "task_completion"
  );

  await catalog.recordAILineage(
    "coordinator-master",
    "coordination.tasks.task_queue",
    "read_and_route"
  );

  // Get stats
  const stats = await catalog.getStatistics();
  console.log(`Total assets: ${stats.total_assets}`);
}

example();
```

## Current Catalog Contents

### Data Assets (69)
- Coordination data (tasks, handoffs, routing)
- Master knowledge bases
- Worker specifications
- Memory and history

### AI Assets (5)
- Coordinator Master Agent
- Development Master Agent
- Security Master Agent
- CI/CD Master Agent
- Inventory Master Agent

### Namespaces

1. **coordination** - System coordination data
   - tasks, handoffs, routing, memory, history

2. **masters** - Master agent assets
   - coordinator, development, security, cicd, inventory

3. **workers** - Worker specifications
   - specs, execution data

4. **moe** - Mixture of Experts routing
   - routing, experts

5. **prompts** - AI prompts
   - agent_definitions, templates

## Search Examples

```bash
# By master
node lib/governance/catalog-cli.js search "Find all tasks assigned to security master"

# By type
node lib/governance/catalog-cli.js search "List all master agent assets"

# By namespace
node lib/governance/catalog-cli.js search "Show coordination routing assets"

# By tag
node lib/governance/catalog-cli.js search "Find knowledge base assets"

# Complex queries
node lib/governance/catalog-cli.js search "Show internal assets owned by coordinator"
```

## Best Practices

1. **Run discovery regularly**
   - After adding new files
   - After master state changes
   - Daily for fresh catalog

2. **Tag assets appropriately**
   - Set sensitivity levels
   - Assign owners
   - Add compliance tags

3. **Track lineage**
   - Record data transformations
   - Log AI operations
   - Document routing decisions

4. **Use search effectively**
   - Natural language works best
   - Be specific for better results
   - Combine filters when needed

## Next Steps

This Phase 1 implementation provides the foundation. Future phases will add:

- **Phase 2**: Access Control & RBAC
- **Phase 3**: Quality Metrics & Monitoring
- **Phase 4**: Compliance & Audit
- **Phase 5**: Federation & Scale

## Support

For questions or issues:
- See `/coordination/catalog/README.md` for detailed documentation
- Check asset schemas in `/coordination/catalog/schemas/`
- Review catalog manager code in `/lib/governance/catalog-manager.js`
