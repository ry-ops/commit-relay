#!/usr/bin/env bash
# Production deployment automation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Configuration
ENVIRONMENT="${1:-production}"
VERSION="${2:-latest}"
BLUE_GREEN="${BLUE_GREEN:-true}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

# Pre-deployment checks
pre_deployment_checks() {
  log_info "Running pre-deployment checks..."
  
  # Check git status
  if [ -n "$(git status --porcelain)" ]; then
    log_error "Uncommitted changes detected. Commit or stash before deploying."
    exit 1
  fi
  
  # Check tests
  log_info "Running test suite..."
  npm run test || {
    log_error "Tests failed. Fix before deploying."
    exit 1
  }
  
  # Check security
  log_info "Running security scan..."
  npm audit --audit-level=high || {
    log_warn "Security vulnerabilities detected. Review before deploying."
  }
  
  # Check env vars
  required_vars=("GITHUB_TOKEN" "ELASTIC_APM_SECRET_TOKEN")
  for var in "${required_vars[@]}"; do
    if [ -z "${!var:-}" ]; then
      log_error "Required environment variable $var not set"
      exit 1
    fi
  done
  
  log_info "✅ Pre-deployment checks passed"
}

# Build application
build_application() {
  log_info "Building application..."
  
  # Install dependencies
  npm ci --production
  
  # Build assets (if applicable)
  if [ -f "package.json" ] && grep -q '"build"' package.json; then
    npm run build
  fi
  
  # Create version file
  cat > version.json << EOF
{
  "version": "$VERSION",
  "commit": "$(git rev-parse HEAD)",
  "branch": "$(git branch --show-current)",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "environment": "$ENVIRONMENT"
}
EOF
  
  log_info "✅ Build complete"
}

# Blue-green deployment
deploy_blue_green() {
  log_info "Deploying using blue-green strategy..."
  
  # Determine current color
  CURRENT_COLOR=$(cat .deployment/current-color 2>/dev/null || echo "green")
  NEW_COLOR=$([ "$CURRENT_COLOR" = "blue" ] && echo "green" || echo "blue")
  
  log_info "Current: $CURRENT_COLOR, Deploying to: $NEW_COLOR"
  
  # Deploy to new environment
  deploy_to_environment "$NEW_COLOR"
  
  # Health check
  if health_check "$NEW_COLOR"; then
    # Switch traffic
    switch_traffic "$NEW_COLOR"
    echo "$NEW_COLOR" > .deployment/current-color
    log_info "✅ Traffic switched to $NEW_COLOR"
  else
    log_error "Health check failed for $NEW_COLOR environment"
    exit 1
  fi
}

# Deploy to specific environment
deploy_to_environment() {
  local color="$1"
  local port=$((color == "blue" ? 5001 : 5002))
  
  log_info "Deploying to $color environment (port $port)..."
  
  # Stop existing process
  pm2 delete "api-server-$color" 2>/dev/null || true
  
  # Start new process
  PORT=$port pm2 start api-server/server/index.js \
    --name "api-server-$color" \
    --env "$ENVIRONMENT"
  
  # Wait for startup
  sleep 5
}

# Health check
health_check() {
  local color="$1"
  local port=$((color == "blue" ? 5001 : 5002))
  local max_attempts=30
  
  log_info "Running health check on $color environment..."
  
  for i in $(seq 1 $max_attempts); do
    if curl -sf "http://localhost:$port/api/health" > /dev/null; then
      log_info "✅ Health check passed (attempt $i/$max_attempts)"
      return 0
    fi
    sleep 2
  done
  
  log_error "Health check failed after $max_attempts attempts"
  return 1
}

# Switch traffic
switch_traffic() {
  local new_color="$1"
  local new_port=$((new_color == "blue" ? 5001 : 5002))
  
  log_info "Switching nginx traffic to $new_color..."
  
  # Update nginx upstream
  sed -i '' "s/server localhost:[0-9]*/server localhost:$new_port/" /etc/nginx/sites-available/commit-relay
  nginx -t && nginx -s reload
}

# Rollback
rollback() {
  log_warn "Rolling back deployment..."
  
  local current_color=$(cat .deployment/current-color)
  local previous_color=$([ "$current_color" = "blue" ] && echo "green" || echo "blue")
  
  switch_traffic "$previous_color"
  echo "$previous_color" > .deployment/current-color
  
  log_info "✅ Rolled back to $previous_color"
}

# Post-deployment tasks
post_deployment() {
  log_info "Running post-deployment tasks..."
  
  # Warm up cache
  curl -s http://localhost/api/achievements/progress > /dev/null
  
  # Trigger deployment event
  node << 'EOFDEPLOY'
const apm = require('elastic-apm-node');
apm.captureError(new Error('Deployment completed'), {
  custom: {
    event: 'deployment',
    environment: process.env.ENVIRONMENT,
    version: process.env.VERSION
  }
});
EOFDEPLOY
  
  # Send notification
  if [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
    curl -X POST "$SLACK_WEBHOOK_URL" \
      -d "{\"text\":\"🚀 Deployment to $ENVIRONMENT completed (version $VERSION)\"}"
  fi
  
  log_info "✅ Post-deployment tasks complete"
}

# Main deployment flow
main() {
  log_info "Starting deployment to $ENVIRONMENT..."
  
  pre_deployment_checks
  build_application
  
  if [ "$BLUE_GREEN" = "true" ]; then
    deploy_blue_green
  else
    deploy_to_environment "main"
    health_check "main" || rollback
  fi
  
  post_deployment
  
  log_info "🎉 Deployment complete!"
}

# Trap errors and rollback
trap 'log_error "Deployment failed. Rolling back..."; rollback' ERR

main "$@"
