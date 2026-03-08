#!/bin/bash
# Create Governance Test Tasks
# Generate test tasks with different risk levels to validate MoE routing and governance

set -euo pipefail

COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-/Users/ryandahlberg/commit-relay}"
TASK_QUEUE="${COMMIT_RELAY_HOME}/coordination/task-queue.json"
TEST_OUTPUT_DIR="${COMMIT_RELAY_HOME}/testing/governance/results"
TIMESTAMP=$(date +%s)

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

create_task() {
    local task_type="$1"
    local title="$2"
    local description="$3"
    local risk_level="$4"
    local priority="${5:-medium}"

    local task_id="governance-test-${risk_level}-${TIMESTAMP}-$(uuidgen | cut -d'-' -f1)"

    log_info "Creating ${risk_level} risk test task: ${task_id}" >&2

    cat <<EOF
{
  "id": "${task_id}",
  "title": "${title}",
  "description": "${task_type}: ${description}",
  "type": "${task_type}",
  "priority": "${priority}",
  "status": "pending",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "created_by": "governance-test-suite",
  "metadata": {
    "test_task": true,
    "governance_test": true,
    "risk_level": "${risk_level}",
    "test_suite": "governance-validation"
  },
  "context": {
    "repository": "ry-ops/commit-relay",
    "branch": "main",
    "test_scenario": true
  }
}
EOF
}

mkdir -p "${TEST_OUTPUT_DIR}"

echo "=========================================="
echo "  Creating Governance Test Tasks"
echo "=========================================="
echo ""

#######################################
# LOW RISK TASKS
#######################################

echo "--- Low Risk Tasks ---"

# Task 1: Documentation update
create_task "documentation" \
    "Update README with governance framework documentation" \
    "Add comprehensive documentation about the MoE governance system, risk assessment, and approval workflows" \
    "low" \
    "low" > "${TEST_OUTPUT_DIR}/task-low-001.json"
log_success "Created task-low-001: Documentation update"

# Task 2: Feature implementation
create_task "feature" \
    "Add user profile avatar upload feature" \
    "Implement a new feature allowing users to upload profile avatars with validation and storage" \
    "low" \
    "medium" > "${TEST_OUTPUT_DIR}/task-low-002.json"
log_success "Created task-low-002: Feature implementation"

# Task 3: Bug fix
create_task "bug-fix" \
    "Fix minor UI alignment issue in dashboard" \
    "Resolve CSS alignment problem affecting dashboard layout on mobile devices" \
    "low" \
    "low" > "${TEST_OUTPUT_DIR}/task-low-003.json"
log_success "Created task-low-003: Bug fix"

echo ""

#######################################
# MEDIUM RISK TASKS
#######################################

echo "--- Medium Risk Tasks ---"

# Task 4: Configuration change
create_task "config-update" \
    "Update database connection pooling settings" \
    "Modify database connection pool configuration to improve performance under load" \
    "medium" \
    "medium" > "${TEST_OUTPUT_DIR}/task-medium-001.json"
log_success "Created task-medium-001: Configuration change"

# Task 5: Refactoring
create_task "refactor" \
    "Refactor authentication middleware for better modularity" \
    "Restructure authentication middleware to improve code organization and testability" \
    "medium" \
    "medium" > "${TEST_OUTPUT_DIR}/task-medium-002.json"
log_success "Created task-medium-002: Refactoring"

# Task 6: Performance optimization
create_task "optimization" \
    "Optimize API response times for dashboard queries" \
    "Improve query performance and add caching to reduce API response latency" \
    "medium" \
    "high" > "${TEST_OUTPUT_DIR}/task-medium-003.json"
log_success "Created task-medium-003: Performance optimization"

echo ""

#######################################
# HIGH RISK TASKS
#######################################

echo "--- High Risk Tasks ---"

# Task 7: Security patch
create_task "security-fix" \
    "Apply security patch for authentication vulnerability" \
    "Patch a critical vulnerability in the authentication system that could allow unauthorized access" \
    "high" \
    "high" > "${TEST_OUTPUT_DIR}/task-high-001.json"
log_success "Created task-high-001: Security patch"

# Task 8: Production deployment
create_task "deploy" \
    "Deploy updated worker management system to production" \
    "Deploy significant changes to production environment including worker lifecycle updates" \
    "high" \
    "high" > "${TEST_OUTPUT_DIR}/task-high-002.json"
log_success "Created task-high-002: Production deployment"

# Task 9: Database migration
create_task "migration" \
    "Execute database schema migration for new features" \
    "Run database migration to update schema, modify existing tables and add new indexes" \
    "high" \
    "high" > "${TEST_OUTPUT_DIR}/task-high-003.json"
log_success "Created task-high-003: Database migration"

echo ""

#######################################
# CRITICAL RISK TASKS
#######################################

echo "--- Critical Risk Tasks ---"

# Task 10: CVE remediation
create_task "cve-2024-9999" \
    "Emergency patch for critical CVE-2024-9999 vulnerability" \
    "Deploy emergency security patch to production to address critical vulnerability allowing remote code execution" \
    "critical" \
    "critical" > "${TEST_OUTPUT_DIR}/task-critical-001.json"
log_success "Created task-critical-001: CVE remediation"

# Task 11: Data deletion
create_task "security-cleanup" \
    "Remove vulnerable code from production systems" \
    "Delete and replace critical security-vulnerable code across production infrastructure immediately" \
    "critical" \
    "critical" > "${TEST_OUTPUT_DIR}/task-critical-002.json"
log_success "Created task-critical-002: Security cleanup"

# Task 12: Emergency security audit
create_task "security-audit" \
    "Conduct emergency security audit of production systems" \
    "Perform comprehensive security vulnerability scan and audit across all production services and infrastructure" \
    "critical" \
    "critical" > "${TEST_OUTPUT_DIR}/task-critical-003.json"
log_success "Created task-critical-003: Emergency security audit"

echo ""
echo "=========================================="
echo "  Test Tasks Created"
echo "=========================================="
echo ""
echo "Low Risk Tasks:     3"
echo "Medium Risk Tasks:  3"
echo "High Risk Tasks:    3"
echo "Critical Risk Tasks: 3"
echo "Total:              12"
echo ""
echo "Task files saved to: ${TEST_OUTPUT_DIR}"
echo ""
echo "Next steps:"
echo "1. Run governance test framework: ./testing/governance/governance-test-framework.sh"
echo "2. Route tasks through MoE: ./testing/governance/route-test-tasks.sh"
echo "3. Validate governance controls: ./testing/governance/validate-governance.sh"
echo ""
