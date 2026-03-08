# Achievement Master

Strategic GitHub achievement tracking and automation system for commit-relay.

## Overview

Achievement Master leverages commit-relay's MoE (Mixture of Experts) architecture to systematically unlock GitHub achievements through intelligent task routing and workflow automation.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Achievement Master                        │
├─────────────────────────────────────────────────────────────┤
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │  Tracker     │  │  Planner     │  │  Workflows   │      │
│  │  (API)       │→ │  (Strategy)  │→ │  (Automation)│      │
│  └──────────────┘  └──────────────┘  └──────────────┘      │
│         │                  │                  │              │
│         ▼                  ▼                  ▼              │
│  ┌─────────────────────────────────────────────────┐       │
│  │           MoE Coordinator Router                 │       │
│  └─────────────────────────────────────────────────┘       │
│         │            │              │                        │
│         ▼            ▼              ▼                        │
│  ┌──────────┐ ┌──────────┐  ┌──────────┐                  │
│  │Development│ │  CI/CD   │  │ Security │                  │
│  │  Master  │ │  Master  │  │  Master  │                  │
│  └──────────┘ └──────────┘  └──────────┘                  │
└─────────────────────────────────────────────────────────────┘
```

## Features

### 1. Real-time Tracking
- GitHub API integration for live achievement status
- Tier progression calculation (Bronze → Silver → Gold → Platinum)
- Opportunity scoring (0-100) based on automation ease and priority

### 2. Strategic Planning
- Gap analysis identifying missing achievements
- Task generation with MoE routing
- Automated workflow recommendations

### 3. Workflow Automation

**Quickdraw Workflow**:
```bash
bash coordination/masters/achievement/workflows/quickdraw-workflow.sh
# Creates issue → Auto-fix → Close < 5 minutes
```

**PR Automation Workflow**:
```bash
bash coordination/masters/achievement/workflows/pr-automation-workflow.sh feature-name
# Creates feature branch → PR → Auto-merge (YOLO mode)
```

## API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/achievements/progress` | GET | Real-time achievement status |
| `/api/achievements/opportunities` | GET | Opportunity scores (0-100) |
| `/api/achievements/plan` | GET | Strategic planning recommendations |
| `/api/achievements/definitions` | GET | Achievement metadata |
| `/api/achievements/metrics` | GET | Historical tracking data |
| `/api/achievements/execute/:workflow` | POST | Trigger automation workflows |

## Quick Start

### 1. Configure Environment

```bash
export GITHUB_TOKEN="ghp_****"
export GITHUB_USERNAME="your-username"
export GITHUB_REPO_OWNER="your-org"
export GITHUB_REPO_NAME="your-repo"
```

### 2. Track Progress

```bash
node coordination/masters/achievement/lib/achievement-tracker.js
```

### 3. Generate Strategic Plan

```bash
node coordination/masters/achievement/lib/strategy-planner.js
```

### 4. Execute Workflows

```bash
# Quickdraw achievement (instant)
bash coordination/masters/achievement/workflows/quickdraw-workflow.sh

# Pull Shark + YOLO (PR automation)
bash coordination/masters/achievement/workflows/pr-automation-workflow.sh my-feature
```

## Achievement Catalog

### Earnable (8)

| Achievement | Icon | Tiers | Strategy | Status |
|-------------|------|-------|----------|--------|
| Pair Extraordinaire | 👥 | Single | Co-authored commits | Active |
| Pull Shark | 🦈 | Bronze (2) → Platinum (1024) | PR automation | In Progress |
| Galaxy Brain | 🧠 | Bronze (2) → Platinum (1024) | Discussion answers | Planned |
| Starstruck | 🌟 | Bronze (16) → Platinum (4096) | Organic growth | In Progress |
| Quickdraw | ⚡ | Single | Issue automation | Unlocked |
| YOLO | 🎲 | Single | Merge without review | Unlocked |
| Public Sponsor | ❤️ | Single | GitHub Sponsors | Planned |
| Achievement Unlocked | 🔓 | Single | Unlock 1 achievement | Unlocked |

### In Testing (2)
- Heart On Your Sleeve (reactions)
- Open Sourcerer (merged PRs in multiple repos)

### Historical (2)
- Arctic Code Vault (2020 snapshot)
- Mars 2020 Helicopter (contributor)

## MoE Integration

Achievement Master routes tasks through specialized masters:

**Development Master**:
- Feature implementation PRs
- Code enhancements
- Documentation

**CI/CD Master**:
- GitHub Actions workflows
- Deployment automation
- Build pipelines

**Security Master**:
- Token management
- Security best practices
- Compliance monitoring

## Monitoring

### GitHub Actions
Automated tracking every 6 hours:

```yaml
# .github/workflows/achievement-tracker.yml
on:
  schedule:
    - cron: '0 */6 * * *'
```

### Elastic APM
Real-time metrics and custom labels:

```javascript
apm.setLabel('achievement.unlocked', unlockedCount);
apm.setLabel('achievement.top_score', topOpportunity.score);
```

### Kibana Dashboard
Visualizations:
- Achievement progress gauge
- Opportunity scores bar chart
- Workflow execution timeline

Import: `coordination/masters/achievement/dashboards/exports/achievement-dashboard.ndjson`

## Security

See `docs/security/achievement-automation-security.md` for:
- Token management and rotation
- API rate limiting
- Auto-merge safeguards
- Worker spawn access control
- Security event logging
- Incident response

## Metrics

Track automation history:
```bash
cat coordination/masters/achievement/metrics/pr-automation-history.jsonl
```

## Contributing

Achievement Master is part of commit-relay's autonomous system. All PRs use co-authored commits:

```bash
git commit -m "feat: Description

Co-Authored-By: Claude <noreply@anthropic.com>"
```

## License

MIT License - Part of commit-relay project

---

**Generated**: 2025-11-25  
**Version**: 1.0.0  
**Status**: Production
