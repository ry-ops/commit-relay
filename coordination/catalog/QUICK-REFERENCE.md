# Unified Catalog - Quick Reference Card

## Most Common Operations

### Discovery
```bash
# Run full asset discovery
./scripts/run-catalog-discovery.sh
# OR
node lib/governance/catalog-cli.js discover
```

### Search
```bash
# Find master agents
node lib/governance/catalog-cli.js search "Find all master agent assets"

# Find routing data
node lib/governance/catalog-cli.js search "routing decisions"

# Find by owner
node lib/governance/catalog-cli.js search "assets owned by coordinator"
```

### Statistics
```bash
# Show catalog stats
node lib/governance/catalog-cli.js stats
```

### Lineage
```bash
# Get asset lineage
node lib/governance/catalog-cli.js lineage <asset_id>
```

### Tagging
```bash
# Tag with sensitivity
node lib/governance/catalog-cli.js tag <asset_id> '{"sensitivity": "confidential"}'

# Tag with owner
node lib/governance/catalog-cli.js tag <asset_id> '{"owner": "coordinator-master"}'
```

## Asset ID Format

All assets use three-level namespace:

```
namespace.schema.asset_name
```

Examples:
- `coordination.tasks.task_queue`
- `masters.coordinator.coordinator_master_agent`
- `workers.specs.worker_spec_dev_worker_123`

## Namespaces

| Namespace | Description | Example |
|-----------|-------------|---------|
| coordination | System coordination data | coordination.tasks.task_queue |
| masters | Master agent assets | masters.coordinator.agent |
| workers | Worker specifications | workers.specs.spec_001 |
| moe | Routing system | moe.routing.rules |
| prompts | AI prompts | prompts.agent_definitions.master |

## Sensitivity Levels

- **public** - Safe for public access
- **internal** - Internal use only
- **confidential** - Restricted access
- **pii** - Contains personally identifiable information

## Common Search Patterns

```bash
# By type
"Find all master agent assets"
"Show worker specifications"

# By owner
"assets owned by coordinator"
"Find security master assets"

# By namespace
"coordination routing assets"
"master knowledge bases"

# By tag
"knowledge base assets"
"routing decisions"
```

## Programmatic Usage

```javascript
const CatalogManager = require('./lib/governance/catalog-manager');

const catalog = new CatalogManager();

// Discovery
await catalog.discoverAssets();

// Search
const results = await catalog.searchAssets("master agent");

// Lineage
const lineage = await catalog.getAssetLineage("coordination.tasks.task_queue");

// Tagging
await catalog.tagAsset("asset_id", { sensitivity: "internal" });

// Record lineage
await catalog.recordDataLineage("source", "target", "transformation");
await catalog.recordAILineage("agent_id", "data_asset", "operation");
await catalog.recordDecisionLineage("decision_id", "input", "output", 0.95);
```

## File Locations

| File | Location |
|------|----------|
| Metastore | `/coordination/catalog/metastore.json` |
| Catalog Manager | `/lib/governance/catalog-manager.js` |
| CLI Tool | `/lib/governance/catalog-cli.js` |
| Discovery Script | `/scripts/run-catalog-discovery.sh` |
| Documentation | `/coordination/catalog/README.md` |
| Usage Guide | `/coordination/catalog/USAGE.md` |

## Help

```bash
# CLI help
node lib/governance/catalog-cli.js help

# Discovery script
./scripts/run-catalog-discovery.sh
```

## Current Statistics

- **Total Assets**: 74
- **Data Assets**: 69
- **AI Assets**: 5 master agents
- **Search Performance**: < 1 second
- **Discovery Time**: ~3 seconds

## Next Steps

See `/coordination/catalog/USAGE.md` for detailed examples and best practices.
