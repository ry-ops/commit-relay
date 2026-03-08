#!/bin/bash

# Dashboard Status Check Script
# Comprehensive check of all dashboard components

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Dashboard System Status Check"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check daemon processes
echo "🔧 DAEMON STATUS:"
echo "━━━━━━━━━━━━━━━━━━━━━"

check_process() {
    local name=$1
    local process=$2
    if pgrep -f "$process" > /dev/null 2>&1; then
        PID=$(pgrep -f "$process" | head -1)
        echo "✅ $name: Running (PID: $PID)"
    else
        echo "❌ $name: Stopped"
    fi
}

check_process "Worker Daemon" "worker-daemon.sh"
check_process "Health Monitor" "health-monitor-daemon.sh"
check_process "Metrics Snapshot" "metrics-snapshot-daemon.sh"
check_process "Task Orchestrator" "task-orchestrator-daemon.sh"
check_process "PM Daemon" "pm-daemon.sh"
check_process "Dashboard Server" "node.*dashboard/server"

echo ""
echo "📊 DASHBOARD ENDPOINTS:"
echo "━━━━━━━━━━━━━━━━━━━━━"

# Test endpoints
test_endpoint() {
    local name=$1
    local url=$2
    if curl -s "$url" > /dev/null 2>&1; then
        echo "✅ $name: Responsive"
    else
        echo "❌ $name: Not responding"
    fi
}

test_endpoint "Health" "http://localhost:3000/api/health"
test_endpoint "Events" "http://localhost:3000/api/events?limit=1"
test_endpoint "Tasks" "http://localhost:3000/api/tasks"
test_endpoint "Git Status" "http://localhost:3000/api/git-status"
test_endpoint "Activity Feed" "http://localhost:3000/api/activity-feed?hours=1"
test_endpoint "Health Alerts" "http://localhost:3000/api/health-alerts"
test_endpoint "MoE Intelligence" "http://localhost:3000/api/moe-intelligence?range=1h"
test_endpoint "All Daemons" "http://localhost:3000/api/daemons/all"

echo ""
echo "📁 DATA FILES:"
echo "━━━━━━━━━━━━━━━━━━━━━"

check_file() {
    local name=$1
    local file=$2
    if [[ -f "$file" ]]; then
        SIZE=$(wc -l < "$file" 2>/dev/null || echo "0")
        echo "✅ $name: $SIZE lines"
    else
        echo "❌ $name: Missing"
    fi
}

check_file "Dashboard Events" "/Users/ryandahlberg/Projects/commit-relay/coordination/dashboard-events.jsonl"
check_file "Task Queue" "/Users/ryandahlberg/Projects/commit-relay/coordination/task-queue.json"
check_file "Worker Pool" "/Users/ryandahlberg/Projects/commit-relay/coordination/worker-pool.json"
check_file "Health Alerts" "/Users/ryandahlberg/Projects/commit-relay/coordination/health-alerts.json"
check_file "Event Buffer" "/Users/ryandahlberg/Projects/commit-relay/coordination/event-buffer.json"

echo ""
echo "📈 SYSTEM METRICS:"
echo "━━━━━━━━━━━━━━━━━━━━━"

# Get task counts
if [[ -f "/Users/ryandahlberg/Projects/commit-relay/coordination/task-queue.json" ]]; then
    PENDING=$(jq '[.tasks[] | select(.status == "pending")] | length' /Users/ryandahlberg/Projects/commit-relay/coordination/task-queue.json 2>/dev/null || echo "0")
    ASSIGNED=$(jq '[.tasks[] | select(.status == "assigned")] | length' /Users/ryandahlberg/Projects/commit-relay/coordination/task-queue.json 2>/dev/null || echo "0")
    SPAWNED=$(jq '[.tasks[] | select(.status == "worker_spawned")] | length' /Users/ryandahlberg/Projects/commit-relay/coordination/task-queue.json 2>/dev/null || echo "0")
    COMPLETED=$(jq '[.tasks[] | select(.status == "completed")] | length' /Users/ryandahlberg/Projects/commit-relay/coordination/task-queue.json 2>/dev/null || echo "0")

    echo "Tasks:"
    echo "  Pending: $PENDING"
    echo "  Assigned: $ASSIGNED"
    echo "  Worker Spawned: $SPAWNED"
    echo "  Completed: $COMPLETED"
fi

# Get worker count
if [[ -f "/Users/ryandahlberg/Projects/commit-relay/coordination/worker-pool.json" ]]; then
    WORKERS=$(jq '.active_workers | length' /Users/ryandahlberg/Projects/commit-relay/coordination/worker-pool.json 2>/dev/null || echo "0")
    echo "Active Workers: $WORKERS"
fi

# Get git status
echo ""
echo "🔄 Git Status:"
BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
CHANGES=$(git status --porcelain | wc -l | xargs)
echo "  Branch: $BRANCH"
echo "  Uncommitted Changes: $CHANGES"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Status Check Complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"