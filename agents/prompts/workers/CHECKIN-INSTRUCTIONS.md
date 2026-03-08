# Worker Check-In Instructions

**For**: All Worker Agent Templates
**Purpose**: Enable PM monitoring and progress tracking
**Updated**: 2025-11-06
**Version**: 1.0

---

## Overview

The Project Manager (PM) daemon monitors all active workers to ensure tasks complete successfully. Workers must check in periodically to report progress and status. This document explains how to integrate check-ins into worker prompts.

---

## Quick Start

### 1. Source the Check-In Helper

Add this at the beginning of your worker prompt (in the initialization section):

```bash
# Enable worker check-ins for PM monitoring
source $COMMIT_RELAY_HOME/scripts/worker-checkin.sh
```

### 2. Add Check-In Calls

Add check-in calls at key points in your workflow:

```bash
# At task start (REQUIRED)
checkin_start

# During execution (RECOMMENDED every 5-10 minutes)
worker_checkin "in_progress" 25 \
  --current-step "Implementing feature X" \
  --next-step "Writing tests"

# At completion (REQUIRED)
checkin_complete "PR #123 created, tests passing"

# On failure (REQUIRED if task fails)
checkin_failed "Test suite failed with 3 errors" 60
```

---

## Check-In Points by Worker Type

### Implementation Worker

```markdown
## Workflow

### 1. Initialize (2-3 minutes)

# Read worker spec and set up environment
cd ~/commit-relay
SPEC_FILE=coordination/worker-specs/active/$(echo $WORKER_ID).json

# REQUIRED: Check in to confirm task received
source $COMMIT_RELAY_HOME/scripts/worker-checkin.sh
checkin_start

### 2. Design & Plan (3-5 minutes)

# Plan implementation approach
...

# RECOMMENDED: Check in after planning
worker_checkin "in_progress" 15 \
  --current-step "Completed design, ready to implement" \
  --next-step "Writing core implementation"

### 3. Implement Component (25-35 minutes)

# Build the feature
...

# RECOMMENDED: Check in every 10 minutes during implementation
worker_checkin "in_progress" 40 \
  --current-step "Implementing feature logic" \
  --next-step "Writing tests"

# ... more implementation ...

worker_checkin "in_progress" 70 \
  --current-step "Implementation complete, starting tests" \
  --next-step "Running test suite"

### 4. Test & Validate (5-10 minutes)

# Run tests
...

# RECOMMENDED: Check in after tests
worker_checkin "in_progress" 85 \
  --current-step "Tests passing, preparing deliverables" \
  --next-step "Creating PR and final documentation"

### 5. Deliver (2-3 minutes)

# Create PR, update docs
...

# REQUIRED: Final check-in on completion
checkin_complete "PR #123 created, tests passing (15/15), docs updated"
```

### Analysis Worker

```markdown
## Workflow

### 1. Setup (5 minutes)

# Set up analysis environment
...

# REQUIRED: Initial check-in
checkin_start

### 2. Data Collection (10 minutes)

# Gather data for analysis
...

# RECOMMENDED: Check in after data collection
worker_checkin "in_progress" 25 \
  --current-step "Data collection complete" \
  --next-step "Performing analysis"

### 3. Analysis (20 minutes)

# Perform detailed analysis
...

# RECOMMENDED: Check in during analysis
worker_checkin "in_progress" 60 \
  --current-step "Analysis 60% complete" \
  --next-step "Generating report"

### 4. Report Generation (10 minutes)

# Generate analysis report
...

# RECOMMENDED: Check in after report
worker_checkin "in_progress" 90 \
  --current-step "Report generated" \
  --next-step "Final validation"

### 5. Delivery (5 minutes)

# Deliver analysis results
...

# REQUIRED: Completion check-in
checkin_complete "Analysis report saved to reports/analysis-001.md"
```

### Test Worker

```markdown
## Workflow

### 1. Setup (5 minutes)

# Set up test environment
...

# REQUIRED: Initial check-in
checkin_start

### 2. Test Execution (30-40 minutes)

# Run test suite
...

# RECOMMENDED: Check in periodically during tests
worker_checkin "in_progress" 40 \
  --current-step "Running integration tests (20/50 complete)" \
  --next-step "Continuing test execution"

worker_checkin "in_progress" 80 \
  --current-step "Tests complete, analyzing results" \
  --next-step "Generating test report"

### 3. Completion

# REQUIRED: Report results
if [ $TEST_FAILURES -eq 0 ]; then
    checkin_complete "All tests passed (${TEST_COUNT} tests)"
else
    checkin_failed "${TEST_FAILURES} tests failed out of ${TEST_COUNT}" 90
fi
```

---

## Check-In Function Reference

### Basic Functions

#### checkin_start
Start check-in - call once at task beginning
```bash
checkin_start
```

#### quick_checkin
Simple progress update (minimal overhead)
```bash
quick_checkin 25  # 25% complete
quick_checkin 50  # 50% complete
```

#### worker_checkin
Full check-in with context
```bash
worker_checkin "in_progress" 45 \
  --current-step "What you're doing now" \
  --next-step "What you'll do next" \
  --time-remaining "15 minutes"
```

#### checkin_complete
Task completion check-in
```bash
checkin_complete "PR #123 created, tests passing, docs updated"
```

#### checkin_failed
Task failure check-in
```bash
checkin_failed "Test suite failed with 3 errors" 60
# Arguments: <reason> <progress_at_failure>
```

#### checkin_blocked
Report blocker
```bash
checkin_blocked "Cannot access database schema file" 40
# Arguments: <blocker_description> <current_progress>
```

### Advanced Options

All check-in functions support these options:

```bash
worker_checkin "in_progress" 50 \
  --current-step "What I'm doing"           # Current activity
  --next-step "What's next"                 # Next planned step
  --time-remaining "20 minutes"             # Time estimate
  --token-usage 3500                        # Tokens consumed
  --issue "Minor deprecation warning"       # Non-blocking issue
  --request "req-12345"                     # Active request ID
  --deliverables "PR #123, docs"            # Final outputs (completion)
  --failure-reason "Tests failed"           # Why failed (failure)
```

---

## Check-In Frequency Guidelines

### Required Check-Ins

1. **Task Start**: Within 5 minutes of worker launch
   ```bash
   checkin_start
   ```

2. **Task Completion**: When task finishes successfully
   ```bash
   checkin_complete "deliverables description"
   ```

3. **Task Failure**: When task fails
   ```bash
   checkin_failed "failure reason" progress_pct
   ```

### Recommended Check-Ins

- **Every 5-10 minutes** during normal execution
- **At phase transitions** (planning → implementation → testing)
- **Before major operations** (running large test suite, creating PR)
- **When requesting help** (need clarification, time extension)

### Optional Check-Ins

- **At milestones** (50% complete, 75% complete)
- **When encountering issues** (non-blocking problems)
- **Progress updates** for long-running tasks

---

## Best Practices

### DO ✓

- **Check in early**: First check-in within 5 minutes
- **Be consistent**: Check in at regular intervals
- **Provide context**: Use --current-step and --next-step
- **Update progress**: Increment progress percentage realistically
- **Report failures**: Always check in on failure with reason
- **Natural breakpoints**: Check in between major activities

### DON'T ✗

- **Over-check-in**: More than once per minute (wastes resources)
- **Forget to check in**: PM will escalate after 20 minutes
- **Lie about progress**: Be honest about completion percentage
- **Skip error handling**: Check-in failures should not crash worker
- **Block on check-ins**: Check-ins should be fire-and-forget

### Error Handling

Always handle check-in errors gracefully:

```bash
# Good: Don't fail if check-in fails
worker_checkin "in_progress" 50 || true

# Good: Log error but continue
worker_checkin "in_progress" 50 || {
    echo "WARNING: Check-in failed, continuing anyway"
}

# Bad: Don't crash on check-in failure
worker_checkin "in_progress" 50  # Could crash if WORKER_ID not set
```

---

## Troubleshooting

### Check-In Not Working

**Problem**: Worker checks in but PM doesn't detect

**Solutions**:
1. Verify WORKER_ID environment variable is set:
   ```bash
   echo $WORKER_ID  # Should be like "dev-worker-ABC12345"
   ```

2. Check file is created:
   ```bash
   ls -la coordination/worker-checkins/${WORKER_ID}-*.json
   ```

3. Verify JSON is valid:
   ```bash
   cat coordination/worker-checkins/${WORKER_ID}-*.json | jq
   ```

4. Check PM daemon is running:
   ```bash
   ps aux | grep pm-daemon
   cat /tmp/pm-daemon.pid
   ```

### PM Reports Worker as Stalled

**Problem**: PM escalates worker even though it's working

**Solutions**:
1. Increase check-in frequency (check in more often)
2. Verify check-ins are being created (see above)
3. Ensure progress percentage is increasing over time
4. Check system time is correct (check-ins use UTC timestamps)

### Check-In Performance Issues

**Problem**: Check-ins slow down worker execution

**Solutions**:
1. Use `quick_checkin` instead of full `worker_checkin`
2. Reduce check-in frequency (every 10 min instead of 5 min)
3. Remove optional fields (--current-step, --next-step)
4. Check disk space (full disk slows file writes)

---

## Migration Guide

### Updating Existing Worker Prompts

1. **Add source statement** at top of initialization section:
   ```bash
   source $COMMIT_RELAY_HOME/scripts/worker-checkin.sh
   ```

2. **Add start check-in** after reading worker spec:
   ```bash
   checkin_start
   ```

3. **Identify natural breakpoints** in your workflow

4. **Add check-ins** at breakpoints:
   ```bash
   worker_checkin "in_progress" <progress> \
     --current-step "Brief description"
   ```

5. **Add completion check-in** at end of successful path:
   ```bash
   checkin_complete "Brief summary of deliverables"
   ```

6. **Add failure check-in** in error handling:
   ```bash
   checkin_failed "Brief failure reason" <progress>
   ```

### Example: Before and After

**Before** (no check-ins):
```markdown
### 1. Initialize

cd ~/commit-relay
SPEC_FILE=coordination/worker-specs/active/$(echo $WORKER_ID).json

### 2. Implement

# Build feature
...

### 3. Test

# Run tests
...

### 4. Deliver

# Create PR
...
```

**After** (with check-ins):
```markdown
### 1. Initialize

cd ~/commit-relay
SPEC_FILE=coordination/worker-specs/active/$(echo $WORKER_ID).json

# ADDED: Enable check-ins
source $COMMIT_RELAY_HOME/scripts/worker-checkin.sh
checkin_start

### 2. Implement

# Build feature
...

# ADDED: Check in after implementation
worker_checkin "in_progress" 50 \
  --current-step "Implementation complete" \
  --next-step "Running tests"

### 3. Test

# Run tests
...

# ADDED: Check in after tests
worker_checkin "in_progress" 85 \
  --current-step "Tests passing" \
  --next-step "Creating PR"

### 4. Deliver

# Create PR
...

# ADDED: Completion check-in
checkin_complete "PR #123 created, tests passing"
```

---

## Examples by Scenario

### Successful Task

```bash
# Start
checkin_start

# Progress updates
worker_checkin "in_progress" 25 --current-step "Planning complete"
worker_checkin "in_progress" 50 --current-step "Implementation complete"
worker_checkin "in_progress" 75 --current-step "Tests complete"

# Completion
checkin_complete "PR #123 created, all tests passing"
```

### Task with Issues

```bash
# Start
checkin_start

# Progress with non-blocking issue
worker_checkin "in_progress" 30 \
  --current-step "Implementing feature" \
  --issue "Deprecation warning in dependency (not blocking)"

# Progress continues
worker_checkin "in_progress" 60 --current-step "Writing tests"

# Completion (issue didn't block)
checkin_complete "PR #123 created, tests passing (1 deprecation warning)"
```

### Task Needs More Time

```bash
# Start
checkin_start

# Making progress
worker_checkin "in_progress" 40 --current-step "Implementation"

# Realize need more time
# (In separate script, create request file via pm-requests/)

# Check in with request reference
worker_checkin "in_progress" 60 \
  --current-step "Implementation taking longer, requested extension" \
  --request "req-1234567890"

# Continue after approval
worker_checkin "in_progress" 80 --current-step "Tests running"

# Complete
checkin_complete "PR #123 created (took 90 minutes total)"
```

### Task Fails

```bash
# Start
checkin_start

# Progress
worker_checkin "in_progress" 30 --current-step "Implementation"
worker_checkin "in_progress" 60 --current-step "Running tests"

# Tests fail
checkin_failed "Test suite failed: 3/15 tests failing in authentication module" 70
```

### Task Blocked

```bash
# Start
checkin_start

# Progress normally
worker_checkin "in_progress" 20 --current-step "Setup complete"

# Encounter blocker
checkin_blocked "Cannot access required database schema documentation" 25

# PM escalates to master, master provides resource

# Resume after unblocked
worker_checkin "in_progress" 40 --current-step "Received schema, implementing queries"

# Complete
checkin_complete "PR #123 created"
```

---

## FAQ

**Q: What if I forget to check in?**
A: PM will detect after 15 minutes (late) and 20 minutes (stalled), then escalate to your master.

**Q: How often should I check in?**
A: Minimum: at start and end. Recommended: every 5-10 minutes. Maximum: no more than once per minute.

**Q: Do check-ins slow down my execution?**
A: No. Check-ins take < 100ms and run in background. Negligible overhead.

**Q: What if check-in fails?**
A: Handle gracefully with `|| true`. Worker should continue even if check-in fails.

**Q: Can I check in too much?**
A: Yes. More than once per minute wastes resources. Stick to 5-10 minute intervals.

**Q: What if WORKER_ID is not set?**
A: Check-in will fail with error. Always source scripts after WORKER_ID is available.

**Q: Do I need to clean up check-in files?**
A: No. PM daemon processes and deletes them automatically.

**Q: What happens if PM daemon is not running?**
A: Check-in files accumulate harmlessly. When PM starts, it processes them retroactively.

---

## Support

**Issues**: Report check-in problems to PM maintainers
**Questions**: See docs/PM-IMPLEMENTATION-PLAN.md for details
**Updates**: Check this document for latest check-in best practices

---

**Document Version**: 1.0
**Last Updated**: 2025-11-06
**Next Review**: After Phase 2 completion (Day 7)
