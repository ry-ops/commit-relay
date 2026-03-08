# LLM Mesh Catalog - Central Registry

## Overview

The LLM Mesh Catalog provides a central registry and discovery system for all objects in the commit-relay ecosystem: agents, tools, prompts, and LLM services.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     Discovery API                               │
│              (catalog-query.sh + REST API)                      │
└────────┬────────────┬────────────┬────────────┬─────────────────┘
         │            │            │            │
         ↓            ↓            ↓            ↓
    ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐
    │ Agents  │  │  Tools  │  │ Prompts │  │  LLM    │
    │ Registry│  │ Catalog │  │ Library │  │Services │
    └─────────┘  └─────────┘  └─────────┘  └─────────┘
         │            │            │            │
         ↓            ↓            ↓            ↓
    ┌────────────────────────────────────────────────┐
    │         MoE Learning & Analytics               │
    │  • Usage tracking                              │
    │  • Performance metrics                         │
    │  • Optimal combinations                        │
    │  • Resource allocation                         │
    └────────────────────────────────────────────────┘
```

## Directory Structure

```
llm-mesh/catalog/
├── README.md                      # This file
├── agents/
│   ├── coordinator-master.json    # Coordinator agent
│   ├── development-master.json    # Development agent
│   ├── security-master.json       # Security agent
│   ├── cicd-master.json           # CI/CD agent
│   ├── inventory-master.json      # Inventory agent
│   └── dashboard-agent.json       # Dashboard agent
├── tools/
│   ├── git-operations.json        # Git tool catalog
│   ├── file-operations.json       # File manipulation tools
│   ├── test-runner.json           # Testing tools
│   ├── deployment.json            # Deployment tools
│   └── analysis.json              # Code analysis tools
├── prompts/
│   ├── routing/                   # Routing prompts
│   ├── analysis/                  # Analysis prompts
│   ├── generation/                # Code generation prompts
│   └── evaluation/                # Quality evaluation prompts
├── llm-services/
│   ├── anthropic.json             # Anthropic service config
│   ├── openai.json                # OpenAI service config
│   └── local.json                 # Local model config
├── usage-tracking/
│   ├── agent-usage.jsonl          # Agent usage logs
│   ├── tool-usage.jsonl           # Tool usage logs
│   └── combination-success.jsonl  # Successful combinations
└── schemas/
    ├── agent-schema.json          # Agent definition schema
    ├── tool-schema.json           # Tool definition schema
    └── prompt-schema.json         # Prompt definition schema
```

## Key Features

### 1. Agent Registry
Complete catalog of all master agents with:
- Capabilities and specializations
- Input/output schemas
- Performance metrics
- Collaboration patterns
- Resource requirements

### 2. Tool Catalog
Comprehensive tool inventory with:
- Tool capabilities
- Usage patterns
- Success rates by context
- Cost/performance data
- Required permissions

### 3. Prompt Library
Versioned, reusable prompts:
- Categorized by purpose
- Model-specific optimizations
- Performance tracking
- A/B testing results

### 4. Discovery API
Query the catalog:
- Find agents by capability
- Find tools for tasks
- Find prompts for use cases
- Get recommendations based on history

### 5. MoE Learning Integration
Learn optimal combinations:
- Which agent + tool combinations work best
- Which prompts perform best for which models
- Resource allocation optimization
- Cost-effective selections

## Agent Registry Schema

Each agent is cataloged with complete metadata:

```json
{
  "agent_id": "development-master",
  "display_name": "Development Master",
  "version": "3.0.0",
  "type": "specialist",
  "specialization": "code_development",
  "capabilities": [
    "feature_implementation",
    "bug_fixes",
    "code_refactoring",
    "performance_optimization",
    "api_development",
    "testing"
  ],
  "tools": [
    "git-operations",
    "file-operations",
    "test-runner",
    "code-analysis"
  ],
  "prompts": [
    "code-generation-v1",
    "bug-fix-analysis-v1",
    "refactoring-suggestions-v1"
  ],
  "performance": {
    "success_rate": 0.92,
    "avg_task_duration": 1800,
    "complexity_range": ["simple", "moderate", "complex"]
  },
  "collaboration": {
    "works_well_with": ["security-master", "cicd-master"],
    "common_workflows": [
      {
        "workflow": "feature_with_security_review",
        "partners": ["security-master"],
        "success_rate": 0.95
      }
    ]
  }
}
```

## Tool Catalog Schema

Each tool is cataloged with usage patterns:

```json
{
  "tool_id": "git-operations",
  "display_name": "Git Operations",
  "category": "version_control",
  "operations": [
    {
      "operation": "commit",
      "description": "Create git commit",
      "parameters": ["message", "files"],
      "success_rate": 0.98
    },
    {
      "operation": "push",
      "description": "Push to remote",
      "parameters": ["remote", "branch"],
      "success_rate": 0.95
    }
  ],
  "used_by_agents": ["development-master", "cicd-master"],
  "performance": {
    "avg_duration_ms": 500,
    "success_rate": 0.97
  },
  "optimal_contexts": [
    "code_completion",
    "feature_implementation",
    "bug_fixes"
  ]
}
```

## Usage

### Query Agents by Capability

```bash
# Find agents that can implement features
./catalog-query.sh agents --capability "feature_implementation"
# Returns: [development-master, cicd-master]

# Find agents for security tasks
./catalog-query.sh agents --specialization "security"
# Returns: [security-master]

# Find best agent for a task
./catalog-query.sh recommend-agent --task "Fix authentication bug"
# Returns: development-master (confidence: 0.85)
```

### Query Tools

```bash
# Find tools for testing
./catalog-query.sh tools --category "testing"
# Returns: [test-runner, integration-tester]

# Find tools used by specific agent
./catalog-query.sh tools --agent "development-master"
# Returns: [git-operations, file-operations, test-runner, code-analysis]

# Get tool performance data
./catalog-query.sh tool-performance "git-operations"
# Returns: {success_rate: 0.97, avg_duration: 500ms}
```

### Query Prompts

```bash
# Find prompts for routing analysis
./catalog-query.sh prompts --category "routing"
# Returns: [analyze-routing-quality-v1, extract-task-features-v1]

# Find prompts optimized for specific model
./catalog-query.sh prompts --model "claude-sonnet-4"
# Returns: [all Sonnet-optimized prompts]

# Get prompt performance
./catalog-query.sh prompt-performance "analyze-routing-quality-v1"
# Returns: {avg_quality: 0.94, cost: $0.016, recommended_model: "claude-sonnet-4"}
```

### Recommendations

```bash
# Get recommended agent-tool combination for task
./catalog-query.sh recommend --task "Implement user authentication"
# Returns:
# {
#   "agent": "development-master",
#   "tools": ["git-operations", "test-runner", "security-scanner"],
#   "prompts": ["code-generation-v1", "security-check-v1"],
#   "confidence": 0.92,
#   "estimated_duration": 1800
# }
```

## MoE Learning for Catalog

The catalog learns optimal combinations:

### 1. Track Usage
```jsonl
{
  "timestamp": "2025-11-15T14:00:00-0600",
  "agent": "development-master",
  "tools_used": ["git-operations", "test-runner"],
  "task_type": "bug_fix",
  "success": true,
  "quality_score": 0.90,
  "duration": 1200
}
```

### 2. Analyze Patterns
- Which agent-tool combinations succeed most?
- Which tools are underutilized but effective?
- Which prompts perform best for which tasks?

### 3. Learn Recommendations
- Build knowledge of optimal combinations
- Identify collaboration patterns
- Optimize resource allocation

### 4. Apply Learnings
- Recommend proven combinations
- Suggest alternative tools
- Optimize agent selection

## Integration with Phases 1 & 2

### With Phase 1 (MoE Learning)
- Catalog provides agent capabilities for routing decisions
- Learning system updates agent performance metrics
- Collaboration patterns inform multi-expert activation

### With Phase 2 (LLM Gateway)
- Catalog stores LLM service configurations
- Gateway uses catalog for model selection
- Performance data flows back to catalog

### Complete Integration
```
Task arrives
  ↓
Phase 1: Route to agent (using catalog)
  ↓
Phase 3: Select tools (using catalog)
  ↓
Phase 2: Select LLM model (using catalog)
  ↓
Execute task
  ↓
Track outcome (update catalog)
  ↓
Learn improvements (all phases)
```

## Dashboard Integration

Catalog powers dashboard views:

### Agent View
- All agents with status
- Current tasks
- Performance metrics
- Collaboration graph

### Tool View
- Tool usage statistics
- Success rates
- Performance trends
- Underutilized tools

### Prompt View
- Prompt library
- Performance by model
- A/B test results
- Version history

## Analytics & Insights

The catalog enables rich analytics:

### Agent Analytics
- Most active agents
- Success rates by agent
- Task duration distributions
- Collaboration effectiveness

### Tool Analytics
- Most/least used tools
- Tool success rates
- Performance trends
- Cost analysis

### Combination Analytics
- Best agent-tool pairings
- Successful workflows
- Anti-patterns (what doesn't work)
- Optimization opportunities

## Example: Complete Task Flow

```
1. Task: "Fix security vulnerability in authentication"

2. Catalog Query: recommend-agent
   → Result: security-master (primary), development-master (secondary)

3. Catalog Query: tools for security-master
   → Result: [security-scanner, vulnerability-db, code-patcher]

4. Catalog Query: prompts for vulnerability analysis
   → Result: [vulnerability-analysis-v2, fix-generation-v1]

5. Gateway: Select model for vulnerability analysis
   → Result: claude-sonnet-4 ($0.016/call, 94% quality)

6. Execute:
   - security-master scans with security-scanner
   - Finds CVE-2024-12345
   - Uses vulnerability-analysis-v2 prompt
   - Generates fix with claude-sonnet-4
   - development-master implements fix
   - test-runner validates

7. Track Outcome:
   - Success: true
   - Quality: 0.95
   - Duration: 2400s
   - Cost: $0.048

8. Learn:
   - security-master + development-master collaboration: effective
   - security-scanner tool: high success rate
   - vulnerability-analysis-v2 prompt: excellent quality
   - claude-sonnet-4: optimal for this task type

9. Update Catalog:
   - Increment success counters
   - Update average quality scores
   - Strengthen recommended combinations
```

## Next Steps

1. Build agent registry (6 agents)
2. Create tool catalog
3. Expand prompt library
4. Implement discovery API
5. Add MoE learning for combinations
6. Integrate with dashboard
7. Generate analytics

This completes the LLM Mesh architecture!
