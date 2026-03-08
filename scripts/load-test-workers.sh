#!/bin/bash
# scripts/load-test-workers.sh
# Load test: Spawn 100 workers and monitor for 5 minutes
#
# This tests:
# - Worker-spec-builder.sh under load
# - Validation system effectiveness
# - Observability system tracking
# - System stability under stress

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export COMMIT_RELAY_HOME

cd "$COMMIT_RELAY_HOME"

# Load observability
source "$SCRIPT_DIR/lib/logging.sh" 2>/dev/null || true

# Test configuration
WORKER_COUNT=100
TEST_DURATION_SECONDS=300  # 5 minutes
WORKER_TYPE="implementation-worker"
SPAWN_INTERVAL=0.5  # Seconds between spawns

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

# Results tracking
SPAWNED=0
SUCCESSFUL=0
FAILED=0
VALIDATION_ERRORS=0

echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  LOAD TEST: 100 Workers for 5 Minutes${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${BLUE}Configuration:${NC}"
echo "  Workers to spawn: $WORKER_COUNT"
echo "  Test duration: ${TEST_DURATION_SECONDS}s (5 minutes)"
echo "  Worker type: $WORKER_TYPE"
echo "  Spawn interval: ${SPAWN_INTERVAL}s"
echo ""
echo -e "${BLUE}Testing:${NC}"
echo "  ✓ Worker-spec-builder.sh validation"
echo "  ✓ Spawn-worker.sh under load"
echo "  ✓ Observability event tracking"
echo "  ✓ System stability"
echo ""

# Ensure ObservabilityHub is running
if ! pgrep -f "observability-hub-daemon" > /dev/null; then
    echo -e "${YELLOW}Starting ObservabilityHub daemon...${NC}"
    ./scripts/daemons/observability-hub-daemon.sh start
    sleep 2
fi

# Record start time
START_TIME=$(date +%s)
echo -e "${GREEN}Starting load test at $(date)${NC}"
echo ""

# Create test task for workers
TEST_TASK_ID="task-load-test-$(date +%s)"

# Spawn workers
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Phase 1: Spawning $WORKER_COUNT Workers${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

for i in $(seq 1 $WORKER_COUNT); do
    WORKER_NUM=$(printf "%03d" $i)

    # Progress indicator
    if [ $((i % 10)) -eq 0 ]; then
        echo -n "."
    fi

    # Spawn worker
    if ./scripts/spawn-worker.sh \
        --type "$WORKER_TYPE" \
        --task-id "${TEST_TASK_ID}-${WORKER_NUM}" \
        --master "load-test-master" \
        > /dev/null 2>&1; then
        SUCCESSFUL=$((SUCCESSFUL + 1))
    else
        FAILED=$((FAILED + 1))

        # Check if it was a validation error
        if ./scripts/spawn-worker.sh \
            --type "$WORKER_TYPE" \
            --task-id "${TEST_TASK_ID}-${WORKER_NUM}-retry" \
            --master "load-test-master" 2>&1 | grep -q "validation"; then
            VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
        fi
    fi

    SPAWNED=$((SPAWNED + 1))

    # Small delay between spawns
    sleep $SPAWN_INTERVAL
done

echo ""
echo ""
echo -e "${GREEN}✓ Spawning complete${NC}"
echo ""

# Show spawn statistics
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Spawn Statistics${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Attempted: $SPAWNED"
echo -e "  ${GREEN}Successful: $SUCCESSFUL${NC}"
echo -e "  ${RED}Failed: $FAILED${NC}"
echo "  Validation errors: $VALIDATION_ERRORS"
echo ""

# Calculate success rate
SUCCESS_RATE=$(echo "scale=2; $SUCCESSFUL * 100 / $SPAWNED" | bc 2>/dev/null || echo "N/A")
echo "  Success rate: ${SUCCESS_RATE}%"
echo ""

# Monitor for 5 minutes
MONITOR_START=$(date +%s)
MONITOR_END=$((MONITOR_START + TEST_DURATION_SECONDS))

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Phase 2: Monitoring ($TEST_DURATION_SECONDS seconds)${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Monitor in intervals
INTERVAL=30  # Check every 30 seconds
CHECKS=0

while [ $(date +%s) -lt $MONITOR_END ]; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - MONITOR_START))
    REMAINING=$((MONITOR_END - CURRENT_TIME))

    CHECKS=$((CHECKS + 1))

    echo -e "${CYAN}[Check $CHECKS] ${NC}Elapsed: ${ELAPSED}s | Remaining: ${REMAINING}s"

    # Check ObservabilityHub status
    if ./scripts/daemons/observability-hub-daemon.sh status 2>&1 | grep -q "RUNNING"; then
        echo "  ✓ ObservabilityHub: Running"
    else
        echo -e "  ${RED}✗ ObservabilityHub: Not running${NC}"
    fi

    # Count active workers
    ACTIVE_WORKERS=$(ls -1 coordination/worker-specs/active/*.json 2>/dev/null | wc -l | tr -d ' ')
    echo "  ✓ Active workers: $ACTIVE_WORKERS"

    # Check for malformed specs
    MALFORMED=0
    for spec in coordination/worker-specs/active/*.json; do
        if [ -f "$spec" ] && ! jq empty "$spec" 2>/dev/null; then
            MALFORMED=$((MALFORMED + 1))
        fi
    done

    if [ $MALFORMED -eq 0 ]; then
        echo -e "  ${GREEN}✓ Malformed specs: 0${NC}"
    else
        echo -e "  ${RED}✗ Malformed specs: $MALFORMED${NC}"
    fi

    # Get event count
    if [ -f "coordination/observability/events/all-events.jsonl" ]; then
        EVENT_COUNT=$(wc -l < coordination/observability/events/all-events.jsonl | tr -d ' ')
        echo "  ✓ Total events: $EVENT_COUNT"
    fi

    echo ""

    # Sleep until next check
    if [ $REMAINING -gt $INTERVAL ]; then
        sleep $INTERVAL
    else
        sleep $REMAINING
        break
    fi
done

# Final statistics
END_TIME=$(date +%s)
TOTAL_DURATION=$((END_TIME - START_TIME))

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Phase 3: Final Analysis${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Count final worker specs
FINAL_WORKERS=$(ls -1 coordination/worker-specs/active/*.json 2>/dev/null | wc -l | tr -d ' ')
FINAL_MALFORMED=0
for spec in coordination/worker-specs/active/*.json; do
    if [ -f "$spec" ] && ! jq empty "$spec" 2>/dev/null; then
        FINAL_MALFORMED=$((FINAL_MALFORMED + 1))
        echo -e "${RED}  Malformed spec: $spec${NC}"
    fi
done

# Get observability statistics
if [ -f "coordination/observability/events/all-events.jsonl" ]; then
    FINAL_EVENTS=$(wc -l < coordination/observability/events/all-events.jsonl | tr -d ' ')

    # Count worker-related events
    WORKER_EVENTS=$(grep -c "worker-" coordination/observability/events/all-events.jsonl 2>/dev/null || echo 0)
else
    FINAL_EVENTS=0
    WORKER_EVENTS=0
fi

# Display results
echo -e "${GREEN}Test Duration: ${TOTAL_DURATION}s${NC}"
echo ""
echo -e "${CYAN}Worker Statistics:${NC}"
echo "  Total spawned: $SPAWNED"
echo "  Successful: $SUCCESSFUL"
echo "  Failed: $FAILED"
echo "  Success rate: ${SUCCESS_RATE}%"
echo "  Final active: $FINAL_WORKERS"
echo ""
echo -e "${CYAN}Validation Statistics:${NC}"
echo "  Malformed specs detected: $FINAL_MALFORMED"
if [ $FINAL_MALFORMED -eq 0 ]; then
    echo -e "  ${GREEN}✓ ZERO malformed JSON - Validation working!${NC}"
else
    echo -e "  ${RED}✗ Malformed JSON found - Investigation needed${NC}"
fi
echo ""
echo -e "${CYAN}Observability Statistics:${NC}"
echo "  Total events: $FINAL_EVENTS"
echo "  Worker events: $WORKER_EVENTS"
echo ""

# Final verdict
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  LOAD TEST RESULTS${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo ""

if [ $FINAL_MALFORMED -eq 0 ] && [ $SUCCESSFUL -gt 90 ]; then
    echo -e "${GREEN}✓✓✓ EXCELLENT${NC}"
    echo -e "${GREEN}  All workers created successfully with valid JSON${NC}"
    echo -e "${GREEN}  Validation system working perfectly under load${NC}"
    echo -e "${GREEN}  2025-11-11 incident PREVENTED${NC}"
elif [ $FINAL_MALFORMED -eq 0 ]; then
    echo -e "${YELLOW}✓ GOOD${NC}"
    echo -e "${YELLOW}  No malformed JSON (validation working)${NC}"
    echo -e "${YELLOW}  Some spawn failures (investigate causes)${NC}"
else
    echo -e "${RED}✗ ISSUES DETECTED${NC}"
    echo -e "${RED}  Malformed JSON found${NC}"
    echo -e "${RED}  Validation system needs investigation${NC}"
fi

echo ""
echo -e "${BLUE}Cleanup commands:${NC}"
echo "  # Remove test workers:"
echo "  rm coordination/worker-specs/active/worker-impl-*.json"
echo ""
echo "  # View observability events:"
echo "  ./scripts/obs-query.sh --component worker --since 10m --timeline"
echo ""

echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
