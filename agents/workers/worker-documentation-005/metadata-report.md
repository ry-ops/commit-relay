# Commit-Relay Repository Metadata Catalog

**Generated**: 2025-11-20
**Worker**: worker-documentation-005
**Task**: moe-test-ddqd-v5-1763691538-97cf9288

---

## Repository Overview

**Name**: commit-relay
**Version**: 1.0.0
**Description**: AI-powered commit automation system with master-worker architecture
**Author**: ry-ops
**License**: MIT

---

## Project Structure

### Root Directories

| Directory | Purpose |
|-----------|---------|
| `agents/` | Agent prompts, workers, configs, and execution logs |
| `coordination/` | Central coordination hub for tasks, workers, metrics, governance |
| `dashboard/` | Real-time metrics dashboard with Express.js API |
| `docs/` | 74+ documentation files covering architecture, APIs, guides |
| `lib/` | Core libraries: governance, circuit-breakers, validators |
| `llm-mesh/` | LLM gateway and MoE learning systems |
| `python-sdk/` | Python client SDK with analytics and reporting |
| `scripts/` | 110+ automation scripts for daemons, workers, tasks |
| `testing/` | Jest test suites with coverage configuration |

---

## Dependencies

### Main Package (Node.js)

**Production Dependencies:**
| Package | Version | Purpose |
|---------|---------|---------|
| ajv | ^8.17.1 | JSON Schema validation |
| ajv-formats | ^3.0.1 | Additional format validators |

**Development Dependencies:**
| Package | Version | Purpose |
|---------|---------|---------|
| @types/jest | ^29.5.11 | TypeScript Jest type definitions |
| jest | ^29.7.0 | Testing framework |
| supertest | ^7.1.4 | HTTP testing library |

### Dashboard Package (Node.js)

**Production Dependencies:**
| Package | Version | Purpose |
|---------|---------|---------|
| chokidar | ^3.5.3 | File watching for live updates |
| cors | ^2.8.5 | Cross-origin resource sharing |
| dotenv | ^17.2.3 | Environment variable management |
| express | ^4.18.2 | Web application framework |
| express-rate-limit | ^8.2.1 | API rate limiting |
| express-validator | ^7.3.0 | Request validation middleware |
| helmet | ^8.1.0 | Security headers |
| ws | ^8.14.2 | WebSocket support |

**Development Dependencies:**
| Package | Version | Purpose |
|---------|---------|---------|
| nodemon | ^3.0.1 | Development auto-restart |

### Python SDK

**Core Dependencies:**
| Package | Version | Purpose |
|---------|---------|---------|
| requests | >=2.28.0 | HTTP client |
| pandas | >=1.5.0 | Data analysis |
| numpy | >=1.23.0 | Numerical computing |
| scipy | >=1.9.0 | Scientific computing |
| matplotlib | >=3.6.0 | Visualization |
| seaborn | >=0.12.0 | Statistical visualization |

**Optional Dependencies:**
- `openpyxl>=3.0.0` - Excel export
- `jupyter>=1.0.0` - Jupyter notebooks
- `PyGithub>=1.59.0` - GitHub integration

**Development Dependencies:**
- pytest, pytest-cov, black, mypy, flake8

---

## Core Modules

### lib/governance/

| Module | Lines | Purpose |
|--------|-------|---------|
| access-control.js | 15,473 | Role-based access control and permissions |
| ai-monitor.js | 15,111 | AI behavior monitoring and safety |
| catalog-manager.js | 15,749 | Asset and dependency cataloging |
| compliance-engine.js | 12,541 | Compliance policy enforcement |
| compliance.js | 11,962 | Compliance rules and validators |
| governance-metrics.js | 19,314 | Metrics collection and reporting |
| lineage-tracker.js | 12,358 | Data lineage tracking |
| lineage.js | 18,640 | Full lineage implementation |
| pii-scanner.js | 12,816 | PII detection and masking |
| quality-validator.js | 12,888 | Data quality validation |
| monitoring.js | 15,514 | System monitoring utilities |
| data-filter.js | 8,890 | Data filtering and sanitization |
| access-cli.js | 10,998 | CLI for access management |
| catalog-cli.js | 6,559 | CLI for catalog operations |

### lib/ (Other)

| Module | Lines | Purpose |
|--------|-------|---------|
| circuit-breaker.js | 10,195 | Circuit breaker pattern |
| circuit-breaker-integrations.js | 12,815 | Service integrations |
| safe-json.js | 12,618 | Safe JSON parsing |
| schema-validator.js | 16,236 | JSON schema validation |
| database/ | - | Database utilities |
| rag/ | - | RAG context management |
| cache/ | - | Caching utilities |
| events/ | - | Event handling |
| hardening/ | - | Security hardening |

---

## Configuration Files

### System Configuration

**coordination/config/system.json** - Central system configuration:
- Logging: Structured JSONL format, 30-day retention, dashboard broadcasting
- Observability: Event buffering (10K), query API, dashboard streaming
- Governance: PII detection, audit trails, role-based access
- Services: 30s heartbeats, 180s health checks, 20 max workers/master
- Workers: 45-min timeout, 10K token budget, auto-retry (3 max)
- Masters: Token budgets (50K-100K), priorities, auto-restart
- Learning: MoE enabled, pattern detection, auto runbooks

### Policy Files

| File | Purpose |
|------|---------|
| auto-fix-policy.json | Automated fix execution policies |
| auto-fix-registry.json | Registry of auto-fix handlers |
| failure-pattern-detection-policy.json | Failure categorization rules |
| worker-restart-policy.json | Worker restart conditions |
| zombie-cleanup-policy.json | Zombie worker cleanup rules |
| terminal-settings.json | Terminal configuration |

### Test Configuration

**jest.config.js**:
- Test environment: Node
- Coverage directory: /coverage
- Coverage thresholds: 60-70% minimum
- Test match: `**/testing/**/*.test.js`
- Timeout: 10000ms

---

## Master Agent Architecture

### Configured Masters

| Master | Token Budget | Priority | Threshold |
|--------|-------------|----------|-----------|
| coordinator | 50,000 | critical | 5 min |
| development | 100,000 | high | 10 min |
| security | 75,000 | critical | 5 min |
| inventory | 50,000 | medium | 15 min |
| cicd | 75,000 | high | 10 min |

---

## Key Documentation

### Architecture Documents
- CORE-PRINCIPLES.md - Core system principles (40KB)
- README.md - Main project documentation (71KB)
- GOVERNANCE-ARCHITECTURE.md - Governance framework (15KB)
- IMPLEMENTATION-STATUS.md - Current implementation status (16KB)

### Week Reports
- WEEK1-12 completion reports tracking development progress
- Q1 roadmap status and final summaries

### Technical Documentation (docs/)
- master-worker-architecture.md - Master-worker design
- automation-architecture.md - Automation framework
- governance-framework.md - Governance details
- CICD_MASTER.md - CI/CD master agent
- event-architecture.md - Event system
- heartbeat-system-design.md - Heartbeat protocol

---

## Dashboard API

**Base URL**: http://localhost:3000/api/

### Available Endpoints

| Endpoint | Method | Purpose |
|----------|--------|---------|
| /health | GET | Service health check |
| /metrics | GET | System metrics |
| /events | GET | Event stream |
| /tasks | GET/POST | Task management |
| /workers | GET | Worker status |
| /workers/:id/heartbeat | POST | Worker heartbeat |

---

## Scripts Inventory

### Categories (110+ scripts)

**Daemon Management:**
- coordinator-daemon.sh
- daemon-control.sh
- daemon-supervisor.sh

**Worker Management:**
- claude-worker-launcher-v2.sh
- cleanup-zombie-workers.sh
- aggregate-worker-results.sh

**Task Management:**
- create-task.sh
- create-task-enhanced.sh
- ddqd (Dynamic task queuing)

**Agent Tools:**
- agent-catalog
- agent-marketplace
- agent-performance
- agent-version
- agent-wizard

**Dashboard Tools:**
- dashboard-alerts
- dashboard-analytics
- dashboard-feed
- dashboard-viz

**Utilities:**
- auto-optimizer
- emergence
- Various shell libraries in scripts/lib/

---

## Coordination Structure

### Key Directories

| Path | Purpose |
|------|---------|
| coordination/masters/ | Master agent states and handoffs |
| coordination/worker-specs/ | Worker specifications (active/completed/failed/archived) |
| coordination/tasks/ | Task queue and pending tasks |
| coordination/governance/ | Access control, audit logs |
| coordination/metrics/ | System metrics and history |
| coordination/health-* | Health monitoring files |
| coordination/events/ | Event streams by type |
| coordination/memory/ | Working and long-term memory |
| coordination/catalog/ | Asset catalogs |

### Event Types Tracked
- Auto-fix events
- Failure pattern events
- Heartbeat events
- Learning events
- Zombie cleanup events
- Dashboard events

---

## Summary Statistics

| Category | Count |
|----------|-------|
| Root directories | 15 |
| Documentation files | 74+ |
| Scripts | 110+ |
| Governance modules | 14 |
| Configuration files | 10+ |
| Master agents | 5 |

### Language Breakdown
- JavaScript/Node.js: Primary (dashboard, lib, scripts)
- Python: SDK and analytics
- Shell/Bash: Automation scripts
- Markdown: Documentation

---

## Health & Monitoring

### SLA Thresholds
- Critical: 15 min
- High: 30 min
- Medium: 60 min
- Low: 120 min

### Auto-Recovery Features
- Auto-restart failed daemons (30s delay)
- Backup spawn on critical
- Max 3 retries with 2x backoff
- Zombie detection at 15+ minutes
- Token budget enforcement

---

*Report generated by worker-documentation-005 for commit-relay inventory cataloging task.*
