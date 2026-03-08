# Tool Clustering and Optimization

**Semantic tool organization for improved worker performance**

Based on GitHub research: **Reducing tools from 40 to 13 improved latency by 400ms**.

---

## Overview

The tool clustering system organizes available tools into semantic groups and assigns optimized tool sets to each worker type. This reduces prompt complexity, improves response time, and helps workers focus on their specialized tasks.

## Key Concepts

### 1. Pre-Expansion Selection

Tools are filtered **before** the worker agent starts, not during execution. This reduces:
- Initial prompt size
- Token usage
- Decision paralysis from too many options

### 2. Semantic Clustering

Tools are grouped by semantic similarity:
- **file_operations**: Read, Write, Edit, Glob
- **code_search**: Grep, Glob
- **version_control**: Git commands
- **code_execution**: Bash for running tests/builds
- **web_access**: WebFetch, WebSearch
- **github_operations**: gh CLI commands
- **task_management**: TodoWrite
- **user_interaction**: AskUserQuestion

### 3. Worker-Specific Assignments

Each worker type receives an optimized tool set:
- **Essential clusters**: Always available, emphasized in prompts
- **Optional clusters**: Available but not emphasized
- **Restricted clusters**: Require approval

---

## Tool Assignments

### implementation-worker
**Essential**: file_operations, code_search, version_control, code_execution
**Optional**: web_access, task_management
**Total tools**: ~9 (vs 19 without clustering)

**Rationale**: Needs full file access, code search, git operations, and test execution. Web access helpful for API documentation lookup.

---

### fix-worker
**Essential**: file_operations, code_search, version_control, code_execution
**Optional**: task_management
**Total tools**: ~8

**Rationale**: Similar to implementation but more focused. Rarely needs web access since fixing existing code.

---

### test-worker
**Essential**: file_operations, code_search, code_execution
**Optional**: version_control, web_access
**Total tools**: ~7

**Rationale**: Primarily needs to write test files and run them. Git less critical since working on existing branch.

---

### scan-worker
**Essential**: code_search, code_execution, version_control
**Optional**: file_operations, web_access
**Total tools**: ~7

**Rationale**: Searches code and runs scanners. Minimal file modification needed.

---

### analysis-worker
**Essential**: code_search, file_operations, web_access
**Optional**: code_execution, version_control
**Total tools**: ~7

**Rationale**: Research-focused. Needs search and web access more than code execution.

---

### review-worker
**Essential**: code_search, file_operations, version_control, code_execution
**Optional**: github_operations
**Total tools**: ~9

**Rationale**: Reviews code, checks diffs, runs tests. GitHub helpful for adding PR comments.

---

### pr-worker
**Essential**: version_control, github_operations
**Optional**: file_operations, code_search
**Total tools**: ~6

**Rationale**: Primarily git and GitHub operations. Minimal code access needed.

---

### documentation-worker
**Essential**: file_operations, code_search, version_control
**Optional**: web_access, code_execution
**Total tools**: ~8

**Rationale**: Writes docs based on code. Web access for finding example documentation.

---

### catalog-worker
**Essential**: code_search, version_control, code_execution
**Optional**: file_operations, github_operations
**Total tools**: ~8

**Rationale**: Analyzes repositories. Needs git, search, and execution for dependency analysis.

---

## Performance Impact

### Tool Reduction
- **Before clustering**: 19 tools per worker
- **After clustering**: 6-9 tools per worker (avg 7.8)
- **Reduction**: ~58%

### Expected Improvements
- **Latency**: -400ms per GitHub research
- **Token usage**: -15-20% from simpler tool descriptions
- **Worker focus**: Better with fewer, more relevant tools
- **Prompt clarity**: Reduced cognitive load

### Actual Measurements
*To be measured after implementation*

---

## Implementation

### 1. Tool Cluster Definition

Tools are defined in `lib/tools/tool-clusters.json`:

```json
{
  "clusters": {
    "file_operations": {
      "tools": ["Read", "Write", "Edit", "Glob"],
      "essential": true
    }
  }
}
```

### 2. Worker Assignment

Each worker type has assigned clusters:

```json
{
  "worker_tool_assignments": {
    "implementation-worker": {
      "essential_clusters": ["file_operations", "code_search"],
      "optional_clusters": ["web_access"]
    }
  }
}
```

### 3. Pre-Expansion Selection

When spawning a worker:
1. Load worker type from spec
2. Look up assigned clusters
3. Filter tools to essential + optional
4. Pass reduced tool set to worker

### 4. Access Control

Tools not in assigned clusters are:
- Not included in system prompt
- Not accessible to worker
- Result in error if attempted

---

## Access Levels

### Essential
- **Description**: Core tools for worker's primary function
- **Preload**: Yes, included in initial prompt
- **Emphasis**: Highlighted in tool descriptions
- **Example**: file_operations for implementation-worker

### Optional
- **Description**: Helpful but not critical tools
- **Preload**: No, lazy-loaded if needed
- **Emphasis**: Available but not emphasized
- **Example**: web_access for test-worker

### Restricted
- **Description**: Sensitive or rarely-used tools
- **Preload**: No
- **Require approval**: Yes, from master agent
- **Example**: Force push commands

---

## Configuration

Tool assignments can be customized per deployment:

```json
{
  "custom_assignments": {
    "implementation-worker": {
      "add_clusters": ["custom_cluster"],
      "remove_clusters": ["web_access"]
    }
  }
}
```

---

## Maintenance

### Adding New Tools
1. Identify semantic cluster for new tool
2. Add to cluster definition in tool-clusters.json
3. Update worker assignments if needed
4. Test with affected workers

### Adding New Worker Types
1. Analyze worker's primary tasks
2. Identify required tool clusters
3. Add assignment to tool-clusters.json
4. Document rationale

### Reviewing Assignments
- Quarterly review of tool usage metrics
- Adjust assignments based on actual usage
- Remove tools that are never used
- Add tools that are frequently requested

---

## Metrics to Track

### Usage Metrics
- **Tool calls per worker type**: Which tools are actually used
- **Request patterns**: Which optional tools are requested
- **Error rates**: Tools attempted but not available

### Performance Metrics
- **Average latency**: Before vs after clustering
- **Token usage**: Prompt size reduction
- **Worker success rate**: Task completion with reduced tools

### Coverage Metrics
- **Essential coverage**: % of tasks completed with essential tools only
- **Optional utility**: How often optional tools are needed
- **Missing tools**: Requests for tools not in assignment

---

## Future Enhancements

- [ ] Dynamic tool assignment based on task complexity
- [ ] ML-based tool recommendation per task type
- [ ] Automatic cluster optimization from usage data
- [ ] Tool dependency resolution
- [ ] Cross-worker tool sharing patterns

---

## References

- GitHub Research: "How we're making GitHub Copilot smarter with fewer tools"
  - Tool reduction: 40 → 13 tools
  - Latency improvement: -400ms
  - Pre-expansion selection approach
  - Source: https://github.blog/ai-and-ml/github-copilot/how-were-making-github-copilot-smarter-with-fewer-tools/

---

*Last updated: 2025-11-26*
