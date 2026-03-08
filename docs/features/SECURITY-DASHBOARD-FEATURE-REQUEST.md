# Feature Request: Security Dashboard Enhancement

## Overview

Enhance commit-relay's existing security infrastructure with a unified dashboard UI and improved scanning capabilities. This builds upon the existing Security Master, scan workers, and GitHub connector rather than creating parallel systems.

## Architecture Alignment

This feature leverages commit-relay's existing architecture:
- **Backend**: Node.js/Express API server
- **Storage**: JSON coordination files (no database required)
- **Routing**: MoE coordinator for task distribution
- **Workers**: Existing scan-worker type via spawn-worker.sh
- **Connectors**: Existing GitHub connector in `lib/rag/connectors/`

## Phase 1: Security Dashboard UI

### Objective
Create a React dashboard component that visualizes existing security scan data from coordination files.

### Components to Create

**1. SecurityDashboard.tsx**
```
eui-dashboard/src/components/dashboard/security/SecurityDashboard.tsx
```

Main dashboard with:
- Portfolio-wide vulnerability summary (critical/high/medium/low counts)
- Repository health grid with color-coded status
- Recent scan activity timeline
- Quick actions for triggering scans

**2. VulnerabilityTable.tsx**
```
eui-dashboard/src/components/dashboard/security/VulnerabilityTable.tsx
```

Sortable, filterable table showing:
- CVE ID, severity, affected package
- Repository and file location
- Discovered date, remediation status
- Links to CVE databases

**3. RepositorySecurityCard.tsx**
```
eui-dashboard/src/components/dashboard/security/RepositorySecurityCard.tsx
```

Individual repository security summary:
- Dependency count and outdated packages
- Last scan timestamp
- Vulnerability breakdown by severity
- One-click rescan button

### API Endpoints

Add to existing `api-server/server/routes/`:

```javascript
// api-server/server/routes/security.js

// GET /api/v1/security/portfolio/summary
// Aggregates vulnerability data across all scanned repositories

// GET /api/v1/security/repositories
// Lists all repositories with security metadata

// GET /api/v1/security/repositories/:repoId/vulnerabilities
// Returns vulnerabilities for a specific repository

// GET /api/v1/security/vulnerabilities
// Query params: severity, status, cve, repository
// Paginated list of all vulnerabilities

// POST /api/v1/security/scan
// Body: { repository_url, scan_type: "full" | "dependencies" | "secrets" }
// Triggers scan via MoE router to Security Master
```

### Data Sources

Read from existing coordination files:
- `coordination/metrics/security-scan-history.jsonl` - Scan results
- `agents/workers/worker-scan-*/security-audit-report.json` - Worker outputs
- `coordination/health-reports.jsonl` - Repository health data

### Integration Points

1. **Trigger scans via existing infrastructure**:
```javascript
// Use existing spawn-worker.sh
const { spawn } = require('child_process');
spawn('./scripts/spawn-worker.sh', [
  '--type', 'scan-worker',
  '--task-id', taskId,
  '--master', 'security-master',
  '--priority', 'high'
]);
```

2. **Route through MoE coordinator**:
```javascript
// Tasks route through coordination/masters/coordinator/lib/moe-router.sh
const taskDescription = `security: Scan ${repoUrl} for vulnerabilities`;
```

---

## Phase 2: Enhanced Scanning Capabilities

### Objective
Extend existing scan workers with additional detection capabilities.

### Enhancements to Existing Files

**1. Enhance scan worker template**
```
agents/workers/worker-scan-template/CLAUDE.md
```

Add scanning instructions for:
- SAST (Static Application Security Testing) patterns
- Secret detection (API keys, tokens, passwords)
- License compliance checking
- Dependency confusion risks

**2. Create vulnerability aggregator**
```
scripts/lib/vulnerability-aggregator.sh
```

Shell script that:
- Collects results from all scan worker directories
- Deduplicates CVEs across repositories
- Generates portfolio-wide summary
- Writes to `coordination/metrics/vulnerability-summary.json`

**3. Add scheduled scanning daemon**
```
scripts/daemons/security-scan-daemon.sh
```

Background daemon that:
- Reads scan policy from `coordination/config/security-scan-policy.json`
- Triggers scans based on schedule (daily, weekly, on-push)
- Respects rate limits and resource constraints
- Logs activity to `coordination/metrics/security-scan-daemon.jsonl`

### Configuration File

```json
// coordination/config/security-scan-policy.json
{
  "version": "1.0.0",
  "enabled": true,
  "default_schedule": "daily",
  "scan_types": {
    "dependencies": {
      "enabled": true,
      "tools": ["npm-audit", "pip-audit", "cargo-audit"]
    },
    "secrets": {
      "enabled": true,
      "patterns_file": "coordination/config/secret-patterns.json"
    },
    "sast": {
      "enabled": false,
      "languages": ["javascript", "python"]
    }
  },
  "severity_thresholds": {
    "block_deploy": "critical",
    "alert": "high"
  },
  "repositories": {
    "include": ["*"],
    "exclude": ["*-archive", "*-deprecated"]
  }
}
```

### API Endpoints (Phase 2)

```javascript
// GET /api/v1/security/scan-policy
// Returns current scan configuration

// PUT /api/v1/security/scan-policy
// Updates scan configuration

// GET /api/v1/security/scan-history
// Query params: repository, scan_type, since, limit
// Returns historical scan results

// GET /api/v1/security/secrets
// Lists detected secrets (redacted) with locations
```

---

## Phase 3: Automated Remediation

### Objective
Enable automated vulnerability fixes through existing auto-fix infrastructure.

### Integration with Auto-Fix System

Leverage existing `scripts/lib/auto-fix.sh` and `scripts/daemons/auto-fix-daemon.sh`:

**1. Add security fix handlers**
```
coordination/config/auto-fix-registry.json
```

Add security-specific fix patterns:
```json
{
  "security_dependency_update": {
    "pattern": "outdated_dependency",
    "handler": "update_dependency",
    "auto_approve": false,
    "requires_review": true
  },
  "security_secret_rotation": {
    "pattern": "exposed_secret",
    "handler": "rotate_secret",
    "auto_approve": false,
    "escalate_to": "security-master"
  }
}
```

**2. Create PR generation for fixes**
```
scripts/lib/security-pr-generator.sh
```

Shell script that:
- Creates branch for security fix
- Applies dependency updates
- Generates PR description with CVE details
- Requests review from security team

### Dashboard Additions

**RemediationPanel.tsx**
```
eui-dashboard/src/components/dashboard/security/RemediationPanel.tsx
```

Shows:
- Pending security fixes awaiting approval
- Auto-fix success/failure history
- One-click approve/reject for fixes
- PR links for manual review

### API Endpoints (Phase 3)

```javascript
// GET /api/v1/security/remediations
// Lists pending and completed remediations

// POST /api/v1/security/remediations/:id/approve
// Approves a pending remediation

// POST /api/v1/security/remediations/:id/reject
// Rejects a pending remediation with reason

// GET /api/v1/security/remediations/:id/pr
// Returns PR details for a remediation
```

---

## File Structure Summary

```
commit-relay/
├── api-server/server/routes/
│   └── security.js                    # New API routes
├── eui-dashboard/src/components/dashboard/security/
│   ├── SecurityDashboard.tsx          # Main dashboard
│   ├── VulnerabilityTable.tsx         # Vulnerability list
│   ├── RepositorySecurityCard.tsx     # Repo summary card
│   └── RemediationPanel.tsx           # Fix approval panel
├── scripts/
│   ├── lib/
│   │   ├── vulnerability-aggregator.sh
│   │   └── security-pr-generator.sh
│   └── daemons/
│       └── security-scan-daemon.sh
├── coordination/
│   ├── config/
│   │   ├── security-scan-policy.json
│   │   └── secret-patterns.json
│   └── metrics/
│       ├── vulnerability-summary.json
│       └── security-scan-daemon.jsonl
└── docs/features/
    └── SECURITY-DASHBOARD-FEATURE-REQUEST.md
```

---

## Testing Strategy

### Unit Tests
```
testing/unit/
├── security-api.test.sh           # API endpoint tests
├── vulnerability-aggregator.test.sh
└── security-scan-daemon.test.sh
```

### Integration Tests
```
testing/integration/
├── security-dashboard-e2e.test.sh # Full workflow test
└── security-remediation-e2e.test.sh
```

### Test Scenarios

1. **Scan Trigger Flow**
   - Submit scan request via API
   - Verify task routes to Security Master
   - Confirm worker spawns with correct parameters
   - Check results appear in coordination files

2. **Vulnerability Aggregation**
   - Create mock scan results in worker directories
   - Run aggregator script
   - Verify summary JSON contains correct counts

3. **Dashboard Data Flow**
   - Seed coordination files with test data
   - Query API endpoints
   - Verify response format matches dashboard expectations

---

## Success Metrics

- Dashboard renders security data within 2 seconds
- Scan requests route correctly through MoE 100% of time
- Vulnerability aggregation completes in < 30 seconds for 50 repos
- Zero false positives in secret detection
- Remediation approval flow completes in < 5 clicks

---

## Implementation Priority

| Phase | Effort | Value | Priority |
|-------|--------|-------|----------|
| Phase 1: Dashboard UI | Medium | High | P0 |
| Phase 2: Enhanced Scanning | High | High | P1 |
| Phase 3: Auto-Remediation | High | Medium | P2 |

---

## Dependencies

### Existing Infrastructure (No Changes Needed)
- Security Master (`coordination/masters/security-master/`)
- Scan workers (`agents/workers/worker-scan-*/`)
- GitHub connector (`lib/rag/connectors/github-connector.js`)
- MoE router (`coordination/masters/coordinator/lib/moe-router.sh`)
- Auto-fix system (`scripts/lib/auto-fix.sh`)
- Spawn worker script (`scripts/spawn-worker.sh`)

### New Dependencies
- None - uses existing EUI components and shell tooling

---

## Notes

This restructured approach:
1. **Avoids duplication** - Uses existing Security Master and scan workers
2. **Maintains consistency** - Follows commit-relay's Node.js/JSON architecture
3. **Enables incremental delivery** - Each phase is independently valuable
4. **Leverages MoE routing** - Scans route through coordinator like other tasks
5. **Integrates with existing systems** - Dashboard, auto-fix, daemons all connected
