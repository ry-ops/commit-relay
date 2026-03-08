#!/bin/bash

# Ensure Services Script for MoE System
# This script checks and starts all required services before task execution

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Service Health Check & Recovery"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Service definitions
SERVICE_NAMES=(
    "worker-daemon"
    "health-monitor"
    "metrics-snapshot"
    "orchestrator"
    "coordinator"
    "development-master"
    "pm-daemon"
)

SERVICE_SCRIPTS=(
    "worker-daemon.sh"
    "health-monitor-daemon.sh"
    "metrics-snapshot-daemon.sh"
    "task-orchestrator-daemon.sh"
    "run-coordinator-master.sh"
    "run-development-master.sh"
    "pm-daemon.sh"
)

# Check if process is running
check_service() {
    local service=$1
    local script=$2

    if pgrep -f "$script" > /dev/null 2>&1; then
        echo -e "${GREEN}✅ $service is running${NC}"
        return 0
    else
        echo -e "${RED}❌ $service is NOT running${NC}"
        return 1
    fi
}

# Start a service
start_service() {
    local service=$1
    local script=$2

    echo -e "${YELLOW}Starting $service...${NC}"

    if [[ -f "$SCRIPT_DIR/$script" ]]; then
        cd "$PROJECT_ROOT"
        nohup "$SCRIPT_DIR/$script" > /dev/null 2>&1 &
        sleep 2

        if check_service "$service" "$script"; then
            echo -e "${GREEN}✅ Successfully started $service${NC}"
            return 0
        else
            echo -e "${RED}❌ Failed to start $service${NC}"
            return 1
        fi
    else
        echo -e "${RED}❌ Script not found: $script${NC}"
        return 1
    fi
}

# Track service status
SERVICES_OK=true
FAILED_SERVICES=()

# Check and start services
echo "Checking core services..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

for i in ${!SERVICE_NAMES[@]}; do
    service="${SERVICE_NAMES[$i]}"
    script="${SERVICE_SCRIPTS[$i]}"

    if ! check_service "$service" "$script"; then
        if start_service "$service" "$script"; then
            echo -e "${GREEN}✅ Recovered $service${NC}"
        else
            SERVICES_OK=false
            FAILED_SERVICES+=("$service")
        fi
    fi
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check dashboard server
echo "Checking dashboard server..."
if curl -s http://localhost:3000/api/health > /dev/null 2>&1; then
    echo -e "${GREEN}✅ Dashboard server is responsive${NC}"
else
    echo -e "${YELLOW}⚠️ Dashboard server not responding${NC}"
    echo "Starting dashboard server..."
    cd "$PROJECT_ROOT/dashboard"
    nohup npm start > /tmp/dashboard.log 2>&1 &
    sleep 3
    if curl -s http://localhost:3000/api/health > /dev/null 2>&1; then
        echo -e "${GREEN}✅ Dashboard server started${NC}"
    else
        echo -e "${RED}❌ Failed to start dashboard server${NC}"
        SERVICES_OK=false
        FAILED_SERVICES+=("dashboard")
    fi
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Service Status Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ "$SERVICES_OK" == true ]]; then
    echo -e "${GREEN}✅ All services are operational${NC}"

    # Update health status
    cat > "$PROJECT_ROOT/coordination/system-health.json" << EOF
{
    "status": "healthy",
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "services": {
        "worker-daemon": "running",
        "health-monitor": "running",
        "metrics-snapshot": "running",
        "orchestrator": "running",
        "coordinator": "running",
        "development-master": "running",
        "pm-daemon": "running",
        "dashboard": "running"
    },
    "last_check": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "check_by": "ensure-services"
}
EOF
    echo "System health status updated"
    exit 0
else
    echo -e "${RED}❌ Some services failed to start:${NC}"
    for service in "${FAILED_SERVICES[@]}"; do
        echo -e "${RED}   - $service${NC}"
    done

    # Update health status with failures
    cat > "$PROJECT_ROOT/coordination/system-health.json" << EOF
{
    "status": "degraded",
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "failed_services": $(printf '%s\n' "${FAILED_SERVICES[@]}" | jq -R . | jq -s .),
    "last_check": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "check_by": "ensure-services"
}
EOF
    exit 1
fi