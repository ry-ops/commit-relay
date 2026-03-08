# Commit-Relay Quick Start Guide

Get productive with Commit-Relay in **under 30 minutes**!

---

## What is Commit-Relay?

Commit-Relay is an autonomous AI-powered software development system featuring:

- **Mixture-of-Experts (MoE) Routing**: Intelligent task distribution to specialized agents
- **Master-Worker Architecture**: Coordinated autonomous agents for development tasks
- **Self-Healing Capabilities**: Automatic failure detection and recovery
- **Comprehensive Governance**: PII detection, quality monitoring, compliance tracking

---

## Quick Start Timeline

| Time | Step | What You'll Do |
|------|------|----------------|
| 0-5min | Prerequisites & Setup | Install dependencies, clone repo |
| 5-15min | System Initialization | Configure environment, start daemons |
| 15-25min | First Task | Create and execute your first AI task |
| 25-30min | Explore & Monitor | Use dashboards, understand system |

**Total Time**: ~30 minutes

---

## Prerequisites (5 minutes)

### System Requirements

- **OS**: macOS or Linux
- **Shell**: Bash 4.0+
- **Memory**: 8GB+ recommended
- **Disk**: 2GB free space

### Required Tools

```bash
# 1. Check bash version (need 4.0+)
bash --version

# 2. Install jq (JSON processor)
# macOS:
brew install jq

# Linux (Ubuntu/Debian):
sudo apt-get install jq

# 3. Install Node.js (for dashboard - optional)
# macOS:
brew install node

# Linux:
sudo apt-get install nodejs npm

# 4. Verify git is installed
git --version
```

### Clone Repository

```bash
# Clone the repository
git clone https://github.com/ry-ops/commit-relay.git
cd commit-relay

# Set environment variable (add to ~/.bashrc or ~/.zshrc)
export COMMIT_RELAY_HOME=$(pwd)
echo "export COMMIT_RELAY_HOME=$(pwd)" >> ~/.bashrc  # or ~/.zshrc
```

---

## System Initialization (10 minutes)

### Step 1: Configure Environment

```bash
# 1. Create necessary directories
mkdir -p coordination/{masters,worker-specs/{active,zombie,failed,templates},tasks,patterns,auto-fix}
mkdir -p agents/logs/{system,workers}

# 2. Initialize token budget
cat > coordination/token-budget.json <<EOF
{
  "total": 100000,
  "used": 0,
  "available": 100000,
  "last_updated": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

# 3. Initialize task queue
cat > coordination/task-queue.json <<EOF
{
  "tasks": [],
  "last_updated": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

# 4. Set up configuration (if not exists)
# Configuration files are already in the repo
ls coordination/config/
# You should see: system.json, worker-restart-policy.json, zombie-cleanup-policy.json, etc.
```

### Step 2: Start System Daemons

```bash
# Option 1: Interactive Wizard (Recommended)
./scripts/wizards/daemon-control.sh
# Select option 6: "Start all daemons"
# Wait for all 9 daemons to start

# Option 2: Automated Startup Script
./scripts/start-commit-relay.sh

# Verify all daemons are running
# Should see 9/9 daemons healthy
```

**Expected Daemons (9 total)**:

1. ✓ Worker Daemon - Spawns new workers
2. ✓ PM Daemon - Worker health monitoring
3. ✓ Heartbeat Monitor - Worker heartbeat tracking
4. ✓ Metrics Snapshot - Historical metrics collection
5. ✓ Coordinator Daemon - Task routing
6. ✓ Integration Validator - Pipeline validation
7. ✓ Pattern Detection - Failure analysis
8. ✓ Worker Restart - Auto-recovery
9. ✓ Auto-Fix - Automatic remediation

### Step 3: Verify System Health

```bash
# Launch real-time dashboard
./scripts/dashboards/system-live.sh

# You should see:
# - Daemons: 9/9 healthy
# - Workers: 0 active (none spawned yet)
# - Token Budget: 100,000/100,000 available (100%)
# - Tasks: 0 queued, 0 in progress

# Press Ctrl+C to exit dashboard
```

✅ **Checkpoint**: All 9 daemons running, system dashboard shows healthy status

---

## Your First Task (10 minutes)

### Step 4: Create a Task Using the Wizard

Let's create a simple task to test the system:

```bash
# Launch worker creation wizard
./scripts/wizards/create-worker.sh
```

**Follow the wizard prompts**:

1. **Step 1: Token Budget Check**
   - Should show 100,000 tokens available
   - Press Enter to continue

2. **Step 2: Select Master Agent**
   - Choose: `1` (development-master)

3. **Step 3: Select Worker Type**
   - Choose: `3` (analysis-worker)
   - This creates a research/investigation worker

4. **Step 4: Enter Task ID**
   - Enter: `task-quickstart-001`

5. **Step 5: Set Priority**
   - Choose: `3` (medium)

6. **Step 6: Repository (Optional)**
   - Enter: `ry-ops/commit-relay` (or press Enter to skip)

7. **Step 7: Review Specification**
   - Review the worker spec summary
   - Verify all details are correct

8. **Step 8: Spawn Worker**
   - Enter: `y` (yes) to spawn the worker immediately

**Expected Output**:

```
✓ Worker spawned successfully!

ℹ Check worker status with:
  /path/to/commit-relay/scripts/worker-status.sh

ℹ View worker logs in:
  /path/to/commit-relay/agents/logs/workers/

ℹ Monitor system with dashboard:
  /path/to/commit-relay/scripts/dashboards/system-live.sh
```

### Step 5: Monitor Worker Execution

```bash
# Method 1: Real-time Dashboard
./scripts/dashboards/system-live.sh

# You should now see:
# - Workers: 1 active
# - Token Budget: ~50,000 available (50,000 allocated to worker)
# - Active Workers section shows: worker-analysis-001

# Method 2: View Worker Logs
ls agents/logs/workers/$(date +%Y-%m-%d)/

# View specific worker log
tail -f agents/logs/workers/$(date +%Y-%m-%d)/worker-analysis-001/worker.log

# Method 3: Check Worker Spec
cat coordination/worker-specs/active/worker-analysis-001.json | jq .
```

### Step 6: Wait for Worker Completion

Analysis workers typically complete in 10-15 minutes. While waiting:

```bash
# Watch the dashboard (auto-refreshes every 5s)
./scripts/dashboards/system-live.sh

# Monitor heartbeats (worker health tracking)
tail -f agents/logs/system/heartbeat-monitor-daemon.log

# You should see heartbeat emissions every 30 seconds:
# [timestamp] INFO: Worker worker-analysis-001 heartbeat received (health: 100)
```

**What's happening?**:
- Worker is executing its analysis task
- Heartbeat monitor checks worker health every 30s
- Token budget shows allocated tokens
- Worker logs show progress

✅ **Checkpoint**: Worker spawned successfully, heartbeats being emitted, logs show activity

---

## Explore the System (5 minutes)

### Step 7: Use the Dashboards

Commit-Relay provides several monitoring tools:

#### Real-Time System Dashboard

```bash
./scripts/dashboards/system-live.sh

# Shows:
# - System overview (workers, tasks, daemons, patterns)
# - Token budget with progress bar
# - Active workers with health scores
# - Recent events stream
# - Health alerts
```

#### Daemon Control Center

```bash
./scripts/wizards/daemon-control.sh

# Interactive menu:
# 1. View daemon status
# 2. Start daemon(s)
# 3. Stop daemon(s)
# 4. Restart daemon(s)
# 5. View daemon logs
# 6. Start all daemons
# 7. Stop all daemons
# 8. Health check
```

### Step 8: Understand the Architecture

```
┌─────────────────┐
│  Task Queue     │  ← Tasks waiting to be processed
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Coordinator    │  ← Routes tasks using MoE algorithm
│  Daemon         │     (Mixture of Experts)
└────────┬────────┘
         │
         ├──────────┬──────────┬──────────┬──────────┐
         ▼          ▼          ▼          ▼          ▼
    ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐
    │Develop │ │Security│ │Inventor│ │  CICD  │ │Coordin │
    │ Master │ │ Master │ │ Master │ │ Master │ │ Master │
    └────┬───┘ └────┬───┘ └────┬───┘ └────┬───┘ └────┬───┘
         │          │          │          │          │
         ▼          ▼          ▼          ▼          ▼
    ┌────────────────────────────────────────────────┐
    │            Worker Pool                         │
    │  (scan, fix, analysis, implementation, etc.)   │
    └────────────────────────────────────────────────┘
                      │
                      ▼
              ┌───────────────┐
              │ Self-Healing  │  ← Automatic failure recovery
              │   System      │     (heartbeat, restart, auto-fix)
              └───────────────┘
```

**Key Components**:

- **Masters**: Specialized agents (development, security, inventory, cicd, coordinator)
- **Workers**: Temporary agents spawned to complete specific tasks
- **MoE Router**: Intelligent task routing based on task description
- **Self-Healing**: Automatic failure detection and recovery (Phase 4)
- **Governance**: PII detection, quality monitoring, compliance (Phase 3)

---

## Common Commands Cheat Sheet

### Worker Management

```bash
# Create new worker (interactive)
./scripts/wizards/create-worker.sh

# List active workers
ls coordination/worker-specs/active/

# Check worker status
cat coordination/worker-specs/active/worker-<ID>.json | jq .

# View worker logs
tail -f agents/logs/workers/<date>/worker-<ID>/worker.log

# Cleanup zombie worker (manual)
./scripts/cleanup-zombie-workers.sh worker-<ID>
```

### Daemon Management

```bash
# Interactive daemon control
./scripts/wizards/daemon-control.sh

# Check all daemon status (manual)
for pidfile in /tmp/commit-relay-*.pid; do
    [ -f "$pidfile" ] && ps -p $(cat "$pidfile") && echo "✓ $(basename $pidfile)" || echo "✗ $(basename $pidfile)"
done

# Restart specific daemon
scripts/daemons/<daemon-name>.sh &

# View daemon logs
tail -f agents/logs/system/<daemon-name>.log
```

### System Monitoring

```bash
# Real-time dashboard
./scripts/dashboards/system-live.sh

# Check token budget
cat coordination/token-budget.json | jq .

# Check task queue
cat coordination/task-queue.json | jq .

# View recent events
tail -20 coordination/dashboard-events.jsonl | jq .

# Check health alerts
cat coordination/health-alerts.json | jq '.alerts[-10:]'
```

### Debugging

```bash
# Search for errors in all logs
grep -r "error" agents/logs/system/

# Check failure patterns
cat coordination/patterns/failure-patterns.jsonl | jq .

# View auto-fix history
cat coordination/auto-fix/fix-history.jsonl | jq .

# Check circuit breaker status
grep "circuit_breaker" coordination/dashboard-events.jsonl
```

---

## Next Steps

Congratulations! You're now productive with Commit-Relay. Here's what to explore next:

### 1. Learn More About the System

- Read [DEVELOPER-GUIDE.md](./DEVELOPER-GUIDE.md) for comprehensive documentation
- Review [IMPLEMENTATION-STATUS.md](./IMPLEMENTATION-STATUS.md) for system capabilities
- Study [Phase 4 Self-Healing Design](./heartbeat-system-design.md)

### 2. Operational Runbooks

Master common operational tasks:

- [Daily Operations Checklist](./runbooks/daily-operations.md) - Daily maintenance
- [Worker Failure Runbook](./runbooks/worker-failure.md) - Handling worker issues
- [Daemon Failure Runbook](./runbooks/daemon-failure.md) - Daemon recovery
- [Self-Healing System](./runbooks/self-healing-system.md) - Understanding auto-recovery

### 3. Advanced Features

Explore advanced capabilities:

- **MoE Routing**: Understand how tasks are intelligently routed
- **Failure Pattern Detection**: Learn how the system learns from failures
- **Auto-Fix Framework**: Configure automatic remediation for common issues
- **Governance**: Set up PII detection and quality monitoring

### 4. Development

Start contributing:

- Create custom worker types
- Add new master agents
- Extend MoE routing patterns
- Build custom dashboards
- Write integration tests

---

## Troubleshooting

### Common Issues

#### Daemon Won't Start

```bash
# Check daemon logs
tail -50 agents/logs/system/<daemon-name>.log

# Check for missing dependencies
which jq  # Should show path to jq

# Check permissions
ls -la scripts/daemons/
chmod +x scripts/daemons/*.sh

# See: Daemon Failure Runbook
```

#### Worker Not Spawning

```bash
# Check token budget
cat coordination/token-budget.json | jq .

# Verify worker daemon is running
ps aux | grep worker-daemon

# Check worker daemon logs
tail -50 agents/logs/system/worker-daemon.log

# See: Worker Failure Runbook
```

#### Dashboard Not Showing Data

```bash
# Verify daemons are running
./scripts/wizards/daemon-control.sh

# Check event file exists
ls -la coordination/dashboard-events.jsonl

# Restart metrics daemon
./scripts/wizards/daemon-control.sh
# Select option 4 (restart) → Metrics Snapshot
```

---

## Getting Help

### Documentation

- [QUICK-START.md](./QUICK-START.md) - This guide
- [DEVELOPER-GUIDE.md](./DEVELOPER-GUIDE.md) - Comprehensive developer docs
- [CHEATSHEET.md](./CHEATSHEET.md) - Quick command reference
- [IMPLEMENTATION-STATUS.md](./IMPLEMENTATION-STATUS.md) - System status and roadmap

### Runbooks

- [Worker Failure](./runbooks/worker-failure.md)
- [Daemon Failure](./runbooks/daemon-failure.md)
- [Daily Operations](./runbooks/daily-operations.md)
- [Emergency Recovery](./runbooks/emergency-recovery.md)

### Community

- GitHub Issues: [Report bugs and request features](https://github.com/ry-ops/commit-relay/issues)
- Discussions: [Ask questions and share ideas](https://github.com/ry-ops/commit-relay/discussions)

---

## Success Checklist

After completing this quick start, you should be able to:

- [ ] Start and stop all 9 system daemons
- [ ] Create and spawn workers using the wizard
- [ ] Monitor system health using the dashboard
- [ ] View worker logs and track progress
- [ ] Understand the basic architecture
- [ ] Use common commands for worker/daemon management
- [ ] Know where to find documentation and runbooks

**Time to Productive**: ⏱️ ~30 minutes ✓

---

## What's Next?

Now that you're up and running, consider:

1. **Run Daily Operations**: Follow [Daily Operations Checklist](./runbooks/daily-operations.md)
2. **Explore Advanced Features**: Read about self-healing, MoE routing, governance
3. **Customize Configuration**: Adjust policies, timeouts, and limits for your use case
4. **Contribute**: Help improve Commit-Relay with code, docs, or feedback

---

**Welcome to Commit-Relay!** 🚀

You're now ready to leverage autonomous AI-powered software development.

---

## Revision History

| Date | Version | Author | Changes |
|------|---------|--------|---------|
| 2025-11-18 | 1.0 | Phase 5 Team | Initial quick start guide |

---

**Last Updated**: 2025-11-18
**Next Review**: 2025-12-18
