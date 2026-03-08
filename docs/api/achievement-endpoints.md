# Achievement API Endpoints

## Overview

The Achievement Master provides 6 REST API endpoints for tracking and automating GitHub achievements.

## Endpoints

### GET /api/achievements/progress
Returns real-time achievement progress from GitHub API.

### GET /api/achievements/opportunities
Returns opportunity scores (0-100) for each achievement.

### GET /api/achievements/plan
Returns strategic plan with generated tasks.

### GET /api/achievements/definitions
Returns achievement metadata and tier information.

### GET /api/achievements/metrics
Returns historical tracking metrics.

### POST /api/achievements/execute/:workflow
Executes achievement automation workflow.

## Usage Examples

```bash
# Get current progress
curl http://localhost:5001/api/achievements/progress

# Get top opportunities
curl http://localhost:5001/api/achievements/opportunities

# Execute quickdraw workflow
curl -X POST http://localhost:5001/api/achievements/execute/quickdraw
```

---

Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
