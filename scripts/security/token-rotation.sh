#!/usr/bin/env bash
# Token rotation automation script

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Configuration
TOKEN_AGE_DAYS="${TOKEN_AGE_DAYS:-90}"
ROTATION_LOG="$PROJECT_ROOT/coordination/governance/token-rotation-log.jsonl"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_event() {
  local event_type="$1"
  local message="$2"
  local metadata="${3:-{}}"
  
  local entry=$(jq -n \
    --arg type "$event_type" \
    --arg msg "$message" \
    --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --argjson meta "$metadata" \
    '{timestamp: $ts, event_type: $type, message: $msg, metadata: $meta}')
  
  echo "$entry" >> "$ROTATION_LOG"
}

check_token_age() {
  local token_name="$1"
  local creation_date="$2"
  
  local now_epoch=$(date +%s)
  local created_epoch=$(date -j -f "%Y-%m-%d" "$creation_date" +%s 2>/dev/null || echo "$now_epoch")
  local age_days=$(( (now_epoch - created_epoch) / 86400 ))
  
  echo "$age_days"
}

rotate_github_token() {
  echo -e "${YELLOW}🔄 Rotating GitHub Personal Access Token...${NC}"
  
  # Check current token age
  local token_created="${GITHUB_TOKEN_CREATED:-2024-01-01}"
  local age=$(check_token_age "GITHUB_TOKEN" "$token_created")
  
  if [ "$age" -lt "$TOKEN_AGE_DAYS" ]; then
    echo -e "${GREEN}✅ Token is only $age days old. Rotation not required (threshold: $TOKEN_AGE_DAYS days)${NC}"
    log_event "token_check" "Token age within limits" "{\"age_days\": $age, \"threshold\": $TOKEN_AGE_DAYS}"
    return 0
  fi
  
  echo -e "${RED}⚠️  Token is $age days old. Rotation required!${NC}"
  
  # Generate rotation instructions
  cat << EOF

📋 GitHub Token Rotation Instructions:

1. Generate new token:
   https://github.com/settings/tokens/new

   Required scopes:
   ✓ repo (Full repository access)
   ✓ workflow (GitHub Actions)
   ✓ read:org (Organization membership)

2. Update environment variable:
   export GITHUB_TOKEN="ghp_NEW_TOKEN_HERE"

3. Update .env file:
   echo "GITHUB_TOKEN=ghp_NEW_TOKEN_HERE" >> .env
   echo "GITHUB_TOKEN_CREATED=$(date +%Y-%m-%d)" >> .env

4. Test new token:
   gh auth status

5. Revoke old token:
   https://github.com/settings/tokens

6. Confirm rotation:
   ./scripts/security/token-rotation.sh --confirm

EOF

  log_event "token_rotation_required" "GitHub token rotation needed" "{\"age_days\": $age}"
  
  return 1
}

rotate_elastic_apm_token() {
  echo -e "${YELLOW}🔄 Rotating Elastic APM API Key...${NC}"
  
  cat << EOF

📋 Elastic APM Token Rotation Instructions:

1. Generate new API key in Elastic Cloud:
   https://cloud.elastic.co/home

   Navigate to: Security → API Keys → Create API Key

2. Update environment:
   export ELASTIC_APM_SECRET_TOKEN="NEW_TOKEN_HERE"

3. Update api-server configuration:
   Edit api-server/apm.js with new token

4. Restart API server:
   pm2 restart api-server

5. Verify connection:
   curl http://localhost:5001/api/health

EOF

  log_event "apm_token_rotation" "Elastic APM token rotation initiated"
}

generate_rotation_report() {
  echo -e "${GREEN}📊 Token Rotation Report${NC}"
  echo ""
  
  # Analyze rotation log
  if [ -f "$ROTATION_LOG" ]; then
    local total_rotations=$(jq -s 'map(select(.event_type == "token_rotation_required")) | length' "$ROTATION_LOG")
    local last_rotation=$(jq -s 'map(select(.event_type == "token_rotation_confirmed")) | last | .timestamp' "$ROTATION_LOG")
    
    echo "Total rotation events: $total_rotations"
    echo "Last confirmed rotation: ${last_rotation:-Never}"
    echo ""
    
    echo "Recent events:"
    jq -s 'map(select(.timestamp > (now - 2592000 | strftime("%Y-%m-%dT%H:%M:%SZ")))) | .[] | "\(.timestamp) - \(.event_type): \(.message)"' "$ROTATION_LOG" -r | tail -10
  else
    echo "No rotation history found"
  fi
}

main() {
  local command="${1:-check}"
  
  case "$command" in
    check)
      rotate_github_token || true
      ;;
    confirm)
      log_event "token_rotation_confirmed" "Token rotation completed by admin"
      echo -e "${GREEN}✅ Token rotation confirmed and logged${NC}"
      ;;
    report)
      generate_rotation_report
      ;;
    apm)
      rotate_elastic_apm_token
      ;;
    *)
      echo "Usage: $0 {check|confirm|report|apm}"
      exit 1
      ;;
  esac
}

main "$@"
