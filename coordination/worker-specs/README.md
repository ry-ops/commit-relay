# Worker Specifications

This directory contains worker specification files that define the scope and context for ephemeral worker agents.

## Directory Structure

```
worker-specs/
├── README.md (this file)
├── schema.json (JSON schema for worker specs)
├── active/ (specifications for currently running workers)
└── archive/ (completed worker specifications by date)
    └── YYYY-MM-DD/
```

## Worker Specification Schema

Each worker specification file follows this format:

```json
{
  "worker_id": "worker-{type}-{number}",
  "worker_type": "scan-worker|fix-worker|implementation-worker|analysis-worker|test-worker|review-worker|pr-worker|documentation-worker",
  "created_by": "master-agent-name",
  "created_at": "ISO-8601 timestamp",
  "task_id": "related-task-id",
  "status": "pending|running|completed|failed|timeout",

  "scope": {
    "repository": "owner/repo-name",
    "branch": "main",
    "files": ["path/to/file1", "path/to/file2"],
    "description": "Detailed scope description"
  },

  "context": {
    "parent_task": "Parent task description",
    "priority": "critical|high|medium|low",
    "deadline": "ISO-8601 timestamp or null",
    "related_workers": ["worker-id-1", "worker-id-2"],
    "dependencies": ["prerequisite descriptions"]
  },

  "resources": {
    "token_budget": 8000,
    "timeout_minutes": 15,
    "max_retries": 1
  },

  "deliverables": [
    "scan_results.json",
    "vulnerability_list.md",
    "artifact descriptions"
  ],

  "prompt_template": "agents/prompts/workers/{type}-worker.md",

  "execution": {
    "started_at": "ISO-8601 timestamp or null",
    "completed_at": "ISO-8601 timestamp or null",
    "tokens_used": 0,
    "duration_minutes": 0,
    "session_id": "claude-session-id or null"
  },

  "results": {
    "status": "success|failure|partial",
    "output_location": "agents/logs/workers/YYYY-MM-DD/worker-id/",
    "summary": "Brief summary of results",
    "artifacts": ["file1.json", "file2.md"]
  }
}
```

## Worker Types

### scan-worker
**Purpose**: Security scanning of repositories
**Token Budget**: 8,000
**Timeout**: 15 minutes
**Deliverables**: scan_results.json, vulnerability_list.md, dependency_report.md

### fix-worker
**Purpose**: Apply specific fixes (dependency updates, patches)
**Token Budget**: 5,000
**Timeout**: 20 minutes
**Deliverables**: commit_hash, test_results.md, changes_summary.md

### implementation-worker
**Purpose**: Implement specific feature components
**Token Budget**: 10,000
**Timeout**: 45 minutes
**Deliverables**: code_files, tests, documentation

### analysis-worker
**Purpose**: Research, investigation, code exploration
**Token Budget**: 5,000
**Timeout**: 15 minutes
**Deliverables**: research_report.md, findings.json

### test-worker
**Purpose**: Add tests for specific modules
**Token Budget**: 6,000
**Timeout**: 20 minutes
**Deliverables**: test_files, coverage_report.md

### review-worker
**Purpose**: Code review of PRs or commits
**Token Budget**: 5,000
**Timeout**: 15 minutes
**Deliverables**: review_comments.md, approval_status.json

### pr-worker
**Purpose**: Create pull requests
**Token Budget**: 4,000
**Timeout**: 10 minutes
**Deliverables**: pr_url, pr_number, checks_status.json

### documentation-worker
**Purpose**: Write/update documentation
**Token Budget**: 6,000
**Timeout**: 20 minutes
**Deliverables**: documentation_files, updated_files.md

## Creating a Worker Specification

Use the helper script:

```bash
./scripts/create-worker-spec.sh \
  --type scan-worker \
  --task task-010 \
  --repo ry-ops/n8n-mcp-server \
  --master security-master
```

Or manually create a JSON file in `coordination/worker-specs/active/`.

## Lifecycle

1. **Created**: Master creates spec file in `active/`
2. **Spawned**: Spawning script launches worker with spec
3. **Running**: Worker updates status periodically
4. **Completed**: Worker writes results and marks completed
5. **Archived**: Spec moved to `archive/YYYY-MM-DD/`

## Monitoring

Check active workers:
```bash
ls -la coordination/worker-specs/active/
```

View worker status:
```bash
jq '.active_workers' coordination/worker-pool.json
```

Check worker logs:
```bash
ls -la agents/logs/workers/$(date +%Y-%m-%d)/
```
