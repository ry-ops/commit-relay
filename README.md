<p align="center">
  <img src="./docs/relay.svg" width="100%" alt="A task enters Commit-Relay; the Coordinator hands it to the MoE router, whose keywords pick the Security master; it spawns scan, fix and test workers, and a pull request comes out. Marked archived.">
</p>

# Commit-Relay

**Multi-agent AI system for autonomous GitHub repository management. Archived, and kept for reference.**

[![Status](https://img.shields.io/badge/Status-Archived-lightgrey)](https://github.com/ry-ops/commit-relay)
[![Architecture](https://img.shields.io/badge/Architecture-Master--Worker-blue)](./docs/master-worker-architecture.md)
[![License](https://img.shields.io/badge/License-MIT-yellow)](./LICENSE)

> [!IMPORTANT]
> **Archived.** Commit-Relay is no longer developed or run anywhere, and the code is kept as-is for reference. Its dependencies are **not maintained and have known vulnerabilities**, so read it, borrow ideas from it, but don't deploy it.

---

## What is Commit-Relay?

Commit-Relay was an autonomous multi-agent platform that managed the entire GitHub repository lifecycle — from task routing to code implementation, security scanning, testing, and deployment — with zero manual intervention.

Agents communicated through structured coordination files rather than direct API calls, creating a fully auditable, transparent orchestration system. A central Coordinator routed incoming tasks to specialized master agents using a Mixture of Experts (MoE) router, which then spawned lightweight workers to execute in parallel.

---

## Current state

| | |
|---|---|
| **Status** | Archived: no development, no running deployment |
| **Last functional change** | March 2026 (animated architecture docs); later commits are dependency and security housekeeping |
| **Dependencies** | Unmaintained, with known vulnerabilities. Not safe to deploy as-is. |
| **What's useful today** | The architecture: file-based agent coordination, MoE task routing, self-healing workers, and the multi-provider LLM gateway |
| **Size** | About 2,300 files: coordination state and agent outputs, 200+ scripts, an Express API server, a Python SDK and an MCP server |

---

## Architecture

<p align="center">
  <img src="./docs/architecture-overview.svg" alt="Commit-Relay Architecture Overview" width="100%">
</p>

### Core Components

| Component | Description |
|-----------|-------------|
| **Master Agents** | Five core masters (Coordinator, Development, Security, Inventory, CI/CD), plus Achievement and Aggregator |
| **7 Worker Types** | Implementation, Fix, Test, Scan, Security Fix, Documentation, Analysis |
| **8+ Autonomous Daemons** | Coordinator, Worker Manager, Process Monitor, Heartbeat, Zombie Cleanup, Worker Restart, Failure Detection, Auto-Fix |
| **LLM Mesh Gateway** | Multi-provider support (Anthropic, OpenAI, Ollama) with circuit breakers, cost tracking, and automatic failover |
| **MoE Router v4.0** | Keyword activation with learned weights and semantic routing. The project's docs describe 350+ activation keywords. |
| **RAG System** | FAISS vector store with 5 collections (code, docs, decisions, patterns, tasks) using sentence-transformers |
| **API Server** | Express.js with 100+ REST endpoints, WebSocket streaming, rate limiting and authentication |
| **MCP Server** | Model Context Protocol interface exposing system capabilities as tools |
| **Python SDK** | Full client library with task orchestration, analytics, health monitoring, and reporting |
| **Observability** | Elastic APM, LangSmith tracing, 27 event types, distributed tracing, anomaly detection |

<p align="center">
  <img src="./docs/system-components.svg" alt="Commit-Relay System Components" width="100%">
</p>

---

## Key Capabilities

### Intelligent Task Routing
- Mixture of Experts router with 350+ keywords and continuous learning
- PyTorch neural routing with training pipeline
- Semantic routing via embeddings (94.5% coverage)
- Margin-based confidence with automatic fallback

### Self-Healing System
- 12+ automated remediation strategies
- Heartbeat monitoring with 2-minute intervals
- Zombie worker detection and cleanup
- Exponential backoff restart logic
- ML-based failure pattern recognition

### LLM Mesh (Multi-Provider Gateway)
- Anthropic Claude (primary), OpenAI, and Ollama support
- Cost-aware model selection (simple tasks -> haiku, complex -> opus)
- Circuit breaker middleware with provider health monitoring
- Automatic failover chains with retries
- Token usage and cost analytics

### Enterprise Governance
- PII scanning (emails, phone numbers, SSNs, API keys)
- RBAC with permission inheritance across 7 namespaces
- SOC2, GDPR, HIPAA compliance policy checking
- Data quality monitoring with schema validation
- Complete audit trail via file-based coordination

### Observability Stack
- Elastic Cloud APM with custom spans and business metrics
- LangSmith for LLM performance tracking
- 27 event types with real-time streaming
- Distributed tracing with waterfall visualization
- 50+ system metrics with aggregation

### RAG-Enhanced Context
- Pluggable vector store (Weaviate, Qdrant, file-based)
- Connectors for GitHub, Confluence, Slack
- Hybrid search (BM25 + semantic with Reciprocal Rank Fusion)
- 5 specialized collections with metadata schemas

---

## Project Structure

```
commit-relay/
├── agents/              # Agent configs, prompts, logs, worker outputs
├── api-server/          # Express.js API server (100+ endpoints)
├── config/              # System configuration
├── coordination/        # File-based coordination (task queue, worker pool, handoffs)
│   ├── masters/         # Master agent configurations and libraries
│   ├── governance/      # Governance policies and audit logs
│   ├── catalog/         # Data and AI catalog
│   └── observability/   # Event streams and metrics
├── docs/                # 60+ documentation files and the diagrams on this page
├── examples/            # Usage examples
├── lib/                 # Shared libraries
│   ├── cache/           # Adaptive LRU cache
│   ├── governance/      # PII scanner, access control, compliance
│   ├── orchestration/   # Workflow engine, SLA monitor, rate limiter
│   └── rag/             # Vector store, embeddings, connectors
├── llm-mesh/            # Multi-provider LLM gateway
├── mcp-server/          # Model Context Protocol server
├── python-sdk/          # Python client library
├── scripts/             # 200+ operational scripts
├── security/            # Security scanning and CVE tracking
└── testing/             # Test suites and test utilities
```

---

## Tech Stack

| Category | Technologies |
|----------|-------------|
| **Runtime** | Node.js 18+, Python 3.8+, Bash |
| **AI/ML** | Anthropic Claude, OpenAI, Ollama, PyTorch, sentence-transformers, FAISS |
| **API** | Express.js 5, WebSocket, JSON-RPC 2.0 (MCP) |
| **Observability** | Elastic APM, LangSmith, OpenTelemetry |
| **Security** | Helmet, express-rate-limit, JWT, PII scanning |
| **Data** | FAISS, Weaviate, Qdrant, MiniSearch |
| **Deployment** | Docker, systemd/launchd |

---

## License

[MIT](./LICENSE)

<!-- org-footer -->
---

<p align="center"><sub>Part of <a href="https://github.com/ry-ops">ry-ops</a> · building the pipes between infrastructure, automation, and observability · built by <a href="https://github.com/ry-ops">ry-ops</a></sub></p>
