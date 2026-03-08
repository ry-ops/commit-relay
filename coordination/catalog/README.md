# Unified Data & AI Catalog

Enterprise-grade unified catalog for commit-relay implementing Databricks-proven governance patterns.

## Overview

The Unified Catalog provides centralized governance for all data and AI assets in the commit-relay system. It implements a three-level namespace structure (catalog.schema.asset) and supports:

- Automated asset discovery
- Natural language search
- Complete lineage tracking (data, AI, decision)
- Asset tagging and sensitivity classification
- Master agent and worker tracking as first-class AI assets

## Architecture

```
coordination/catalog/
├── metastore.json              # Central catalog registry
├── schemas/                    # Asset schema definitions
│   └── asset-schema.json
├── lineage/                    # Lineage tracking
│   ├── data-lineage.jsonl
│   ├── ai-lineage.jsonl
│   └── decision-lineage.jsonl
└── indexes/                    # Fast lookup indexes
    ├── by-type.json
    ├── by-owner.json
    ├── by-sensitivity.json
    └── by-namespace.json
```

## Namespace Structure

The catalog uses a three-level namespace: `catalog.schema.asset`

### Namespaces

1. **coordination** - Coordination layer data assets
   - `coordination.tasks.*` - Task management data
   - `coordination.handoffs.*` - Master handoff coordination
   - `coordination.routing.*` - MoE routing decisions
   - `coordination.memory.*` - Working and long-term memory
   - `coordination.history.*` - Historical snapshots

2. **masters** - Master agent AI assets
   - `masters.coordinator.*` - Coordinator master agent
   - `masters.development.*` - Development master agent
   - `masters.security.*` - Security master agent
   - `masters.cicd.*` - CI/CD master agent
   - `masters.inventory.*` - Inventory master agent
   - `masters.testing.*` - Testing master agent
   - `masters.monitoring.*` - Monitoring master agent

3. **workers** - Worker agent AI assets
   - `workers.specs.*` - Worker specifications
   - `workers.execution.*` - Worker execution data

4. **moe** - Mixture of Experts routing system
   - `moe.routing.*` - Routing engine and rules
   - `moe.experts.*` - Expert specialization definitions

5. **prompts** - AI prompt templates
   - `prompts.agent_definitions.*` - Agent prompt definitions
   - `prompts.templates.*` - Reusable templates

## Asset Types

### Data Assets
Files, databases, configurations, and structured data.

Required fields: `asset_id`, `asset_name`, `asset_type`, `namespace`, `path`, `format`

Example:
```json
{
  "asset_id": "coordination.tasks.task_queue",
  "asset_name": "Task Queue",
  "asset_type": "data",
  "namespace": "coordination.tasks",
  "path": "/coordination/task-queue.json",
  "format": "json",
  "sensitivity": "internal",
  "owner": "system"
}
```

### AI Assets
Agents, models, and AI capabilities.

Required fields: `asset_id`, `asset_name`, `asset_type`, `namespace`, `agent_type`, `capabilities`

Example:
```json
{
  "asset_id": "masters.coordinator.agent",
  "asset_name": "Coordinator Master Agent",
  "asset_type": "ai",
  "namespace": "masters.coordinator",
  "agent_type": "master",
  "capabilities": ["routing", "task_decomposition", "handoff_orchestration"],
  "prompt_path": "/.claude/agents/coordinator-master.md"
}
```

### Model Assets
Routing models, decision models, and ML models.

Required fields: `asset_id`, `asset_name`, `asset_type`, `namespace`, `model_type`, `version`

Example:
```json
{
  "asset_id": "moe.routing.decision_model",
  "asset_name": "MoE Routing Decision Model",
  "asset_type": "model",
  "namespace": "moe.routing",
  "model_type": "routing_classifier",
  "version": "1.0.0",
  "confidence_threshold": 0.7
}
```

## Sensitivity Levels

All assets are classified by sensitivity:

- **public** - Safe for public access
- **internal** - Internal use only
- **confidential** - Restricted access
- **pii** - Contains personally identifiable information

## Usage

### CLI Interface

The catalog provides a command-line interface for all operations:

```bash
# Run asset discovery
node lib/governance/catalog-cli.js discover

# Search assets with natural language
node lib/governance/catalog-cli.js search "Find all tasks assigned to security master"
node lib/governance/catalog-cli.js search "Show routing decisions with confidence < 0.7"
node lib/governance/catalog-cli.js search "List all PII-containing assets"

# Get asset lineage
node lib/governance/catalog-cli.js lineage coordination.tasks.task_queue

# Tag assets
node lib/governance/catalog-cli.js tag coordination.tasks.task_queue '{"sensitivity": "internal"}'

# View statistics
node lib/governance/catalog-cli.js stats
```

### Programmatic API

```javascript
const CatalogManager = require('./lib/governance/catalog-manager');

const catalog = new CatalogManager();

// Discover all assets
const results = await catalog.discoverAssets();

// Register a new asset
await catalog.registerAsset({
  asset_name: "My Data Asset",
  asset_type: "data",
  namespace: "coordination.tasks",
  path: "/path/to/asset.json",
  format: "json",
  sensitivity: "internal",
  owner: "development-master"
});

// Search assets
const results = await catalog.searchAssets("Find all tasks assigned to security master");

// Get lineage
const lineage = await catalog.getAssetLineage("coordination.tasks.task_queue");

// Tag assets
await catalog.tagAsset("coordination.tasks.task_queue", {
  sensitivity: "internal",
  owner: "coordinator-master",
  tags: ["high-priority", "production"]
});

// Record lineage
await catalog.recordDataLineage(
  "coordination.tasks.task_queue",
  "coordination.tasks.completed_tasks",
  "task_completion_flow"
);

await catalog.recordAILineage(
  "coordinator-master",
  "coordination.tasks.task_queue",
  "read_and_route"
);

await catalog.recordDecisionLineage(
  "routing-decision-123",
  "coordination.routing.task_input",
  "coordination.routing.master_assignment",
  0.95
);
```

## Natural Language Search Examples

The catalog supports natural language queries:

```bash
# Find assets by master
"Find all tasks assigned to security master"
"Show assets owned by development master"

# Find by sensitivity
"List all PII-containing assets"
"Show confidential data assets"

# Find by confidence
"Show routing decisions with confidence < 0.7"
"Find high-confidence routing decisions"

# Find by type
"List all master agent assets"
"Show all worker specifications"

# Combined queries
"Find confidential assets assigned to security master"
"Show low-confidence routing decisions for development tasks"
```

## Lineage Tracking

### Data Lineage
Tracks data flow and transformations between assets.

```json
{
  "lineage_id": "uuid",
  "source_asset": "coordination.tasks.task_queue",
  "target_asset": "coordination.tasks.completed_tasks",
  "transformation": "task_completion_flow",
  "timestamp": "2025-11-11T16:52:00Z"
}
```

### AI Lineage
Tracks which AI agents used which data assets.

```json
{
  "lineage_id": "uuid",
  "agent_id": "coordinator-master",
  "data_asset": "coordination.tasks.task_queue",
  "operation": "read_and_route",
  "timestamp": "2025-11-11T16:52:00Z"
}
```

### Decision Lineage
Tracks routing and decision history.

```json
{
  "lineage_id": "uuid",
  "decision_id": "routing-decision-123",
  "input_data": "coordination.routing.task_input",
  "decision_output": "coordination.routing.master_assignment",
  "confidence": 0.95,
  "timestamp": "2025-11-11T16:52:00Z"
}
```

## Automated Discovery

The catalog automatically discovers and registers:

1. **Coordination Data Assets**
   - Task queues and PM state
   - Workforce streams
   - Dashboard events
   - Memory (working and long-term)
   - Orchestrator state

2. **Master Agent AI Assets**
   - Agent state files
   - Knowledge bases
   - Implementation patterns
   - Routing decisions

3. **Worker Specifications**
   - Worker specs (active, completed, failed)
   - Worker templates
   - Execution logs

4. **Agent Prompts**
   - Master agent prompt definitions
   - Worker agent prompts
   - Skill prompts

## Integration with Governance Phases

This Phase 1 implementation provides the foundation for future governance phases:

- **Phase 2: Access Control & RBAC** - Asset-level permissions
- **Phase 3: Quality Metrics & Monitoring** - Data quality tracking
- **Phase 4: Compliance & Audit** - Regulatory compliance
- **Phase 5: Federation & Scale** - Multi-catalog federation

## Inspired By

This implementation follows Databricks-proven governance patterns:

- **Amgen**: Reduced 120 roles to 1-2 using unified catalog
- **Rivian**: 50x user growth with centralized governance
- **Industry**: 98% of CIOs say unified data+AI governance is critical

## Success Metrics

- 100% of coordination files registered in catalog
- All 7 master agents tracked as AI assets
- Search returns relevant assets in < 2 seconds
- Asset discovery runs automatically
- Lineage tracked for all operations

## Next Steps

1. Enable automatic discovery on system startup
2. Integrate lineage tracking into master handoffs
3. Add real-time catalog updates
4. Implement catalog webhooks for events
5. Build catalog dashboard visualization
