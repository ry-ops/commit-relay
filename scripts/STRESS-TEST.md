# DDQD Stress Test

**"God Mode" System Validation for Commit-Relay v4.0**

## Overview

DDQD (inspired by Doom's invincibility cheat code) is a comprehensive stress test that validates all v4.0 orchestration features under heavy load. It runs for a configurable duration (default: 60 minutes) or until token budget is 95% exhausted.

## What It Tests

- ✅ **Task Orchestrator Daemon**: Complex multi-master task coordination
- ✅ **Zombie Killer Daemon**: Detection and eradication of stale/hung workers
- ✅ **Heartbeat Protocol**: Worker health monitoring (2-minute ping intervals)
- ✅ **Workforce Streams**: Multi-stream parallel task execution
- ✅ **Token Budget Management**: Budget tracking and exhaustion handling
- ✅ **Worker Spawning**: High parallelism with up to 15 concurrent workers
- ✅ **Dashboard Metrics**: Real-time metrics accuracy validation
- ✅ **Historical Data Collection**: Metrics snapshot daemon integration

## Quick Start

### Run with Interactive Prompt

```bash
./scripts/ddqd
```

You'll be asked how long to run the test (in minutes). Default is 60 minutes.

### Run with Environment Variable

```bash
TEST_DURATION=30 ./scripts/ddqd
```

### Run Directly

```bash
./scripts/stress-test-ddqd.sh
```

## Test Phases

The stress test runs through 5 progressive phases:

### Phase 1: Normal Load (0-15 min)
- Gradual worker spawning
- 5 simple tasks created sequentially
- 30-second intervals between tasks
- Validates basic task execution flow

### Phase 2: High Parallelism (15-30 min)
- Spawns up to 15 workers simultaneously
- Tests maximum concurrent worker capacity
- Validates workforce stream load balancing
- Stress tests token budget tracking

### Phase 3: Zombie Scenarios (30-40 min)
- Creates intentional zombie workers:
  - **Timeout Zombies**: Workers with no heartbeat (>15 min runtime)
  - **Stale Zombies**: Workers with stale heartbeat (>5 min since last ping)
- Creates 3 zombies of each type
- Waits 2 minutes for zombie-killer-daemon detection
- Validates automatic cleanup

### Phase 4: Orchestration Stress (40-55 min)
- Creates complex multi-master tasks requiring coordination
- Tests Task Orchestrator daemon under load
- Spawns security scan, inventory, and CI/CD tasks
- Validates MoE (Mixture of Experts) routing

### Phase 5: Recovery Validation (55-60 min)
- System health check
- Verifies all zombies have been eradicated
- Validates no resource leaks
- Confirms system stability after stress

## Monitoring

### Real-time Metrics

During the test, you'll see live metrics every 30-60 seconds:

```
[METRICS] Active Workers: 12 | Tasks: 45 | Zombies Killed: 6 | Tokens: 42.3% | Time: 1823s
```

### Dashboard Monitoring

Open the dashboard during the test to watch real-time updates:

```bash
# In another terminal
cd /Users/ryandahlberg/commit-relay/dashboard
npm start
```

Then visit: http://localhost:3000

Watch these dashboard sections:
- **Overview**: Live worker count, task completion, zombie kills
- **Analytics**: Real-time charts and trends
- **Workforce**: Worker pool status and stream distribution

### Log Files

All test activity is logged to:

```
agents/logs/stress-test/ddqd-<timestamp>.log
```

View in real-time:

```bash
tail -f agents/logs/stress-test/ddqd-*.log
```

## Output & Reports

### Metrics JSON

Periodic metrics snapshots are saved to:

```
coordination/stress-test/ddqd-<timestamp>-metrics.json
```

Each snapshot contains:
- Worker counts (active, completed, failed)
- Task counts (pending, completed)
- Zombie statistics (created, killed)
- Token usage percentage
- Elapsed time

### Final Report

After test completion, a comprehensive report is generated:

```
coordination/stress-test/ddqd-<timestamp>-report.txt
```

The report includes:
- Test duration and timestamps
- System validation checklist (all components tested)
- Final metrics summary
- Worker statistics
- Token budget usage
- Result status (SUCCESS/FAILURE)

Example report:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  DDQD STRESS TEST - FINAL REPORT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Test ID: ddqd-1730837245
Duration: 60 minutes (3600 seconds)
Started: 2025-11-05 14:00:45
Completed: 2025-11-05 15:00:45

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  SYSTEM VALIDATION
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

✓ Task Orchestrator Daemon: TESTED
✓ Zombie Killer Daemon: TESTED
✓ Heartbeat Protocol: TESTED
✓ Workforce Streams: TESTED
✓ Token Budget Management: TESTED
✓ Multi-Master Coordination: TESTED

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  FINAL METRICS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Total Workers Spawned: 67
Workers Completed: 58
Workers Failed: 9
Zombies Detected & Killed: 6

Token Budget Used: 143500 / 305000 (47.0%)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  RESULT: SUCCESS ✓
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

All v4.0 orchestration systems validated successfully.
System is operating at god-mode efficiency.
```

## Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `TEST_DURATION` | Test duration in minutes | 60 |
| `MAX_WORKERS` | Maximum concurrent workers | 15 |

Example:

```bash
TEST_DURATION=30 MAX_WORKERS=10 ./scripts/ddqd
```

### Stopping the Test

To stop the test early:

```bash
# Find the process
pgrep -f stress-test-ddqd

# Kill it (will trigger cleanup and report generation)
pkill -f stress-test-ddqd
```

The test will automatically generate the final report even if interrupted.

## What Happens During the Test

### Tasks Created

The test creates diverse tasks to stress different masters:

1. **Simple Tasks**: Basic feature implementation (development-master)
2. **Complex Tasks**: Multi-master coordination requiring orchestrator
3. **Security Tasks**: Vulnerability scans (security-master)
4. **Inventory Tasks**: Repository cataloging (inventory-master)

All tasks are tagged with `"stress_test": true` and include the test ID for easy identification.

### Zombies Created

Intentional zombie workers are created to validate detection:

1. **Timeout Zombies**: Worker specs with `started_at` 20 minutes in the past, no recent heartbeat
2. **Stale Zombies**: Worker specs with `last_heartbeat` 8 minutes in the past

These should be detected and killed by the zombie-killer-daemon within 2 minutes.

### Automatic Checks

Every phase includes automatic checks for:

- **Token Budget**: Test ends if >95% tokens consumed
- **Time Duration**: Test ends when configured duration reached
- **Zombie Cleanup**: Validates all zombies are eradicated

## Integration with Existing Systems

The stress test integrates seamlessly with:

- **Worker Daemon**: Uses existing worker spawning infrastructure
- **Zombie Killer**: Relies on production zombie detection
- **Heartbeat Protocol**: Tests real worker health monitoring
- **Dashboard**: All metrics visible in real-time UI
- **Historical Data**: Snapshots collected by metrics daemon
- **Task Queue**: Uses production task queue system

## Cleanup

After the test:

1. **Zombie workers** are automatically cleaned up by zombie-killer-daemon
2. **Completed workers** are moved to worker pool history
3. **Stress test tasks** remain in task queue (tagged with `stress_test: true`)
4. **Logs and reports** are preserved in `agents/logs/stress-test/`

To clean up test artifacts:

```bash
# Remove stress test tasks from queue
jq 'del(.tasks[] | select(.stress_test == true))' coordination/task-queue.json > /tmp/queue.json
mv /tmp/queue.json coordination/task-queue.json

# Remove stress test workers from pool
jq '.completed_workers = [.completed_workers[] | select(.stress_test != true)]' coordination/worker-pool.json > /tmp/pool.json
mv /tmp/pool.json coordination/worker-pool.json
```

## Troubleshooting

### Test Won't Start

**Error**: `DDQD stress test is already running!`

**Solution**: Kill the existing test first:
```bash
pkill -f stress-test-ddqd
```

### No Zombies Detected

**Cause**: Zombie-killer-daemon may not be running

**Solution**: Start the daemon:
```bash
./scripts/start-commit-relay.sh
```

### Dashboard Not Updating

**Cause**: Dashboard server not running

**Solution**: Start the dashboard:
```bash
cd dashboard && npm start
```

### Token Budget Exhausted Early

**Cause**: High token usage from complex tasks

**Solution**: Reduce test duration or max workers:
```bash
TEST_DURATION=30 MAX_WORKERS=8 ./scripts/ddqd
```

## Best Practices

1. **Monitor Dashboard**: Keep dashboard open during test to watch real-time metrics
2. **Check Daemons**: Ensure all daemons are running before starting test
3. **Clean State**: Start with a clean coordination directory for accurate results
4. **Resource Limits**: Don't run other heavy processes during the test
5. **Review Reports**: Always review the final report after completion

## Example Session

```bash
# Start all daemons
./scripts/start-commit-relay.sh

# Start dashboard (in another terminal)
cd dashboard && npm start

# Open dashboard in browser
open http://localhost:3000

# Run stress test
./scripts/ddqd
# Enter desired duration when prompted (e.g., 30)

# Monitor in real-time
tail -f agents/logs/stress-test/ddqd-*.log

# After completion, review report
cat coordination/stress-test/ddqd-*-report.txt
```

## Success Criteria

The test is successful if:

- ✅ All 5 phases complete without errors
- ✅ Zombies are detected and killed within 2 minutes
- ✅ Token budget management prevents overuse
- ✅ Workers spawn and complete successfully
- ✅ Dashboard metrics remain accurate throughout
- ✅ No system crashes or resource leaks
- ✅ Final report shows "RESULT: SUCCESS ✓"

## Reference

- Main Script: `scripts/stress-test-ddqd.sh`
- Wrapper Command: `scripts/ddqd`
- Log Directory: `agents/logs/stress-test/`
- Report Directory: `coordination/stress-test/`
- Test Tasks: Tagged with `"stress_test": true` in task queue

---

**Remember**: DDQD is not just a stress test—it's a comprehensive validation of the entire v4.0 orchestration architecture. Run it regularly to ensure system health and god-mode reliability! 🚀
