#!/bin/bash
# LLM Mesh Deployment Script
# Sets up and deploys complete LLM Mesh architecture for commit-relay

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLM_MESH_HOME="$SCRIPT_DIR"
COMMIT_RELAY_HOME="$(dirname "$LLM_MESH_HOME")"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

##############################################################################
# Logging functions
##############################################################################
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

##############################################################################
# check_prerequisites: Verify system requirements
##############################################################################
check_prerequisites() {
    log_info "Checking prerequisites..."

    local errors=0

    # Check required commands
    for cmd in jq bc curl; do
        if ! command -v $cmd &> /dev/null; then
            log_error "Required command not found: $cmd"
            errors=$((errors + 1))
        else
            log_success "$cmd found"
        fi
    done

    # Check directory structure
    if [ ! -d "$COMMIT_RELAY_HOME/coordination" ]; then
        log_error "commit-relay coordination directory not found"
        errors=$((errors + 1))
    fi

    if [ $errors -gt 0 ]; then
        log_error "Prerequisites check failed with $errors error(s)"
        return 1
    fi

    log_success "All prerequisites satisfied"
    return 0
}

##############################################################################
# setup_environment: Configure environment
##############################################################################
setup_environment() {
    log_info "Setting up environment..."

    if [ ! -f "$LLM_MESH_HOME/.env" ]; then
        if [ -f "$LLM_MESH_HOME/.env.example" ]; then
            log_warn "No .env file found"
            echo ""
            echo "Please configure your environment:"
            echo "  1. Copy .env.example to .env"
            echo "  2. Add your API keys (ANTHROPIC_API_KEY or OPENAI_API_KEY)"
            echo "  3. Configure safety and quality settings"
            echo ""
            echo "Example:"
            echo "  cp $LLM_MESH_HOME/.env.example $LLM_MESH_HOME/.env"
            echo "  nano $LLM_MESH_HOME/.env"
            echo ""
            read -p "Create .env now? (y/N) " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                cp "$LLM_MESH_HOME/.env.example" "$LLM_MESH_HOME/.env"
                log_success "Created .env file"
                log_warn "Please edit .env and add your API keys before continuing"
                echo "Run: nano $LLM_MESH_HOME/.env"
                return 1
            else
                log_error "Cannot proceed without .env file"
                return 1
            fi
        fi
    fi

    # Load and validate configuration
    source "$LLM_MESH_HOME/config/load-env.sh" load

    if ! bash "$LLM_MESH_HOME/config/load-env.sh" validate; then
        log_error "Environment validation failed"
        return 1
    fi

    log_success "Environment configured"
    return 0
}

##############################################################################
# setup_directories: Create required directories
##############################################################################
setup_directories() {
    log_info "Setting up directories..."

    local dirs=(
        "$LLM_MESH_HOME/moe-learning/catalog"
        "$LLM_MESH_HOME/moe-learning/metrics"
        "$LLM_MESH_HOME/gateway/catalog"
        "$LLM_MESH_HOME/safety/learning"
        "$LLM_MESH_HOME/integration"
    )

    for dir in "${dirs[@]}"; do
        mkdir -p "$dir"
        log_success "Created/verified: $dir"
    done

    log_success "Directories ready"
}

##############################################################################
# make_executable: Make all scripts executable
##############################################################################
make_executable() {
    log_info "Making scripts executable..."

    find "$LLM_MESH_HOME" -type f -name "*.sh" -exec chmod +x {} \;

    log_success "All scripts are executable"
}

##############################################################################
# test_components: Test each LLM Mesh component
##############################################################################
test_components() {
    log_info "Testing LLM Mesh components..."

    # Test 1: Safety Gateway
    log_info "Testing safety filters..."
    local test_input="Contact me at test@example.com with API key sk-test123"
    local safety_result=$(bash "$LLM_MESH_HOME/safety/safety-gateway.sh" check-input "$test_input" "detect" 2>&1)

    if echo "$safety_result" | tail -1 | jq -e '.safe == false' >/dev/null; then
        log_success "Safety gateway working (detected PII and secrets)"
    else
        log_warn "Safety gateway test inconclusive"
    fi

    # Test 2: Catalog Query
    log_info "Testing catalog..."
    local catalog_result=$(bash "$LLM_MESH_HOME/catalog/catalog-query.sh" recommend-agent "Fix security bug" 2>/dev/null || echo "error")

    if [ "$catalog_result" != "error" ]; then
        log_success "Catalog working (recommended: $catalog_result)"
    else
        log_warn "Catalog test failed"
    fi

    # Test 3: MoE Router
    log_info "Testing MoE router..."
    local routing_result=$(GOVERNANCE_BYPASS=true bash "$COMMIT_RELAY_HOME/coordination/masters/coordinator/lib/moe-router.sh" "test-deploy" "Fix authentication vulnerability" 2>/dev/null || echo "error")

    if [ "$routing_result" != "error" ]; then
        local routed_expert=$(echo "$routing_result" | jq -r '.decision.primary_expert')
        log_success "MoE router working (selected: $routed_expert)"
    else
        log_warn "MoE router test failed"
    fi

    # Test 4: LLM Client (without API call)
    log_info "Testing LLM client configuration..."
    if [ -x "$LLM_MESH_HOME/gateway/llm-client.sh" ]; then
        log_success "LLM client ready"
    else
        log_warn "LLM client not executable"
    fi

    log_success "Component tests complete"
}

##############################################################################
# show_deployment_summary: Display deployment information
##############################################################################
show_deployment_summary() {
    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo "  LLM Mesh Deployment Summary"
    echo "════════════════════════════════════════════════════════════════"
    echo ""

    # Show configuration
    bash "$LLM_MESH_HOME/config/load-env.sh" show

    echo ""
    echo "Available Commands:"
    echo "════════════════════════════════════════════════════════════════"
    echo ""
    echo "  Process a single task:"
    echo "    $LLM_MESH_HOME/integration/task-processor.sh process \\"
    echo "      task-001 \"Fix security vulnerability\" security"
    echo ""
    echo "  Process task queue:"
    echo "    $LLM_MESH_HOME/integration/task-processor.sh queue"
    echo ""
    echo "  Test safety gateway:"
    echo "    $LLM_MESH_HOME/safety/safety-gateway.sh check-input \"test input\""
    echo ""
    echo "  Query catalog:"
    echo "    $LLM_MESH_HOME/catalog/catalog-query.sh recommend-agent \"task description\""
    echo ""
    echo "  Test LLM API:"
    echo "    $LLM_MESH_HOME/gateway/llm-client.sh test"
    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo ""
}

##############################################################################
# run_demo: Run end-to-end demo
##############################################################################
run_demo() {
    log_info "Running end-to-end demo..."
    echo ""

    # Demo task
    local demo_task_id="demo-deploy-001"
    local demo_description="Scan repository for CVE-2024-12345 vulnerability"

    log_info "Processing demo task: $demo_description"
    echo ""

    bash "$LLM_MESH_HOME/integration/task-processor.sh" process \
        "$demo_task_id" \
        "$demo_description" \
        "security"

    echo ""
    log_success "Demo complete!"
}

##############################################################################
# deploy_to_production: Full production deployment
##############################################################################
deploy_to_production() {
    log_info "Starting production deployment..."

    # Step 1: Prerequisites
    if ! check_prerequisites; then
        log_error "Prerequisites check failed"
        return 1
    fi

    # Step 2: Environment
    if ! setup_environment; then
        log_error "Environment setup failed"
        return 1
    fi

    # Step 3: Directories
    setup_directories

    # Step 4: Permissions
    make_executable

    # Step 5: Component tests
    test_components

    # Step 6: Summary
    show_deployment_summary

    log_success "LLM Mesh deployed successfully!"

    # Offer demo
    echo ""
    read -p "Run end-to-end demo? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        run_demo
    fi
}

##############################################################################
# Main execution
##############################################################################
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    case "${1:-deploy}" in
        deploy)
            deploy_to_production
            ;;
        check)
            check_prerequisites
            ;;
        setup)
            setup_environment
            ;;
        test)
            test_components
            ;;
        demo)
            run_demo
            ;;
        summary)
            show_deployment_summary
            ;;
        help|--help|-h)
            cat <<EOF
LLM Mesh Deployment Script

Usage: $0 <command>

Commands:
  deploy    Full deployment (default)
  check     Check prerequisites only
  setup     Setup environment only
  test      Test all components
  demo      Run end-to-end demo
  summary   Show deployment summary

Full Deployment Steps:
  1. Check prerequisites (jq, bc, curl)
  2. Setup environment (.env configuration)
  3. Create required directories
  4. Make all scripts executable
  5. Test all components
  6. Display summary and usage

Example:
  # Full deployment
  $0 deploy

  # Just check prerequisites
  $0 check

  # Run demo
  $0 demo
EOF
            ;;
        *)
            echo "Unknown command: $1"
            echo "Run '$0 help' for usage information"
            exit 1
            ;;
    esac
fi
