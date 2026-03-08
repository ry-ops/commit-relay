#!/bin/bash
# coordination/governance/lib/pii-scanner.sh
# PII Detection Scanner for Commit-Relay
#
# Purpose:
# - Detect Personally Identifiable Information (PII) in content
# - Classify findings by confidence level (high/medium/low)
# - Calculate risk level and recommend actions
# - Support redaction for safe logging
#
# Usage:
#   source coordination/governance/lib/pii-scanner.sh
#   scan_for_pii "$content" "worker-prompt"
#   redact_pii "$content"

set -eo pipefail

# Prevent re-sourcing
if [ -n "${PII_SCANNER_LOADED:-}" ]; then
    return 0
fi
PII_SCANNER_LOADED=1

# PII Detection Patterns (regex)

# High-confidence patterns
PATTERN_EMAIL='[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}'
PATTERN_SSN='[0-9]{3}-[0-9]{2}-[0-9]{4}'
PATTERN_CREDIT_CARD='[0-9]{4}[\s-]?[0-9]{4}[\s-]?[0-9]{4}[\s-]?[0-9]{4}'

# API Keys and Secrets (check these BEFORE phone to avoid false matches)
PATTERN_API_KEY_GENERIC='(sk|pk|api)[-_][a-zA-Z0-9_]{20,}'
PATTERN_AWS_KEY='AKIA[0-9A-Z]{16}'
PATTERN_GITHUB_TOKEN='gh[pousr]_[A-Za-z0-9]{32,}'
# Phone: Must have structure (parentheses OR separators), not just digits
PATTERN_PHONE='\([0-9]{3}\) [0-9]{3}-[0-9]{4}|[0-9]{3}[-\s.][0-9]{3}[-\s.][0-9]{4}|\+?1[\s-][0-9]{3}[\s-][0-9]{3}[\s-][0-9]{4}'
PATTERN_SLACK_TOKEN='xox[baprs]-[0-9]{10,13}-[0-9]{10,13}-[a-zA-Z0-9]{24,}'
PATTERN_PRIVATE_KEY='-----BEGIN (RSA |DSA |EC |OPENSSH )?PRIVATE KEY-----'

# Medium-confidence patterns
PATTERN_IP='[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'
PATTERN_USERNAME='(username|user|login)[:=]\s*[a-zA-Z0-9_-]+'

# Scan for PII in content
# Returns: JSON with findings
scan_for_pii() {
    local content="$1"
    local context="${2:-unknown}"

    # Findings array
    local findings=()
    local has_pii=false
    local risk_level="none"
    local high_count=0
    local medium_count=0

    # Check for high-confidence PII

    # Email addresses
    if echo "$content" | grep -qE "$PATTERN_EMAIL"; then
        findings+=('{"type":"email","confidence":"high","pattern":"email_address"}')
        has_pii=true
        high_count=$((high_count + 1))
    fi

    # SSN
    if echo "$content" | grep -qE "$PATTERN_SSN"; then
        findings+=('{"type":"ssn","confidence":"high","pattern":"social_security"}')
        has_pii=true
        high_count=$((high_count + 1))
    fi

    # Credit Card
    if echo "$content" | grep -qE "$PATTERN_CREDIT_CARD"; then
        findings+=('{"type":"credit_card","confidence":"high","pattern":"credit_card"}')
        has_pii=true
        high_count=$((high_count + 1))
    fi

    # API Keys (check BEFORE phone to avoid false matches)
    if echo "$content" | grep -qE "$PATTERN_API_KEY_GENERIC"; then
        findings+=('{"type":"api_key","confidence":"high","pattern":"api_key"}')
        has_pii=true
        high_count=$((high_count + 1))
    fi

    # AWS Keys
    if echo "$content" | grep -qE "$PATTERN_AWS_KEY"; then
        findings+=('{"type":"aws_key","confidence":"high","pattern":"aws_access_key"}')
        has_pii=true
        high_count=$((high_count + 1))
    fi

    # GitHub Tokens
    if echo "$content" | grep -qE "$PATTERN_GITHUB_TOKEN"; then
        findings+=('{"type":"github_token","confidence":"high","pattern":"github_token"}')
        has_pii=true
        high_count=$((high_count + 1))
    fi

    # Phone Number (check AFTER API keys)
    if echo "$content" | grep -qE "$PATTERN_PHONE"; then
        findings+=('{"type":"phone","confidence":"high","pattern":"phone_number"}')
        has_pii=true
        high_count=$((high_count + 1))
    fi

    # Slack Tokens
    if echo "$content" | grep -qE "$PATTERN_SLACK_TOKEN"; then
        findings+=('{"type":"slack_token","confidence":"high","pattern":"slack_token"}')
        has_pii=true
        high_count=$((high_count + 1))
    fi

    # Private Keys
    if echo "$content" | grep -qF "BEGIN PRIVATE KEY"; then
        findings+=('{"type":"private_key","confidence":"high","pattern":"private_key"}')
        has_pii=true
        high_count=$((high_count + 1))
    fi

    # Check for medium-confidence PII

    # IP Addresses
    if echo "$content" | grep -qE "$PATTERN_IP"; then
        findings+=('{"type":"ip_address","confidence":"medium","pattern":"ip_address"}')
        has_pii=true
        medium_count=$((medium_count + 1))
    fi

    # Username patterns
    if echo "$content" | grep -qiE "$PATTERN_USERNAME"; then
        findings+=('{"type":"username","confidence":"medium","pattern":"username"}')
        has_pii=true
        medium_count=$((medium_count + 1))
    fi

    # Calculate risk level
    if [ $high_count -gt 0 ]; then
        if [ $high_count -ge 3 ]; then
            risk_level="critical"
        else
            risk_level="high"
        fi
    elif [ $medium_count -gt 0 ]; then
        if [ $medium_count -ge 5 ]; then
            risk_level="high"
        else
            risk_level="medium"
        fi
    else
        risk_level="low"
    fi

    # Build findings array for JSON
    local findings_json="["
    local first=true
    for finding in "${findings[@]}"; do
        if [ "$first" = true ]; then
            first=false
        else
            findings_json+=","
        fi
        findings_json+="$finding"
    done
    findings_json+="]"

    # Build result JSON
    local result=$(cat <<EOF
{
  "has_pii": $has_pii,
  "context": "$context",
  "findings_count": {
    "high_confidence": $high_count,
    "medium_confidence": $medium_count,
    "total": $((high_count + medium_count))
  },
  "findings": $findings_json,
  "risk_level": "$risk_level",
  "action_required": $(if [ "$risk_level" = "critical" ] || [ "$risk_level" = "high" ]; then echo "true"; else echo "false"; fi),
  "scanned_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
)

    echo "$result"
}

# Redact PII from content
# Returns: Content with PII redacted
redact_pii() {
    local content="$1"
    local redacted="$content"

    # Redact email addresses
    redacted=$(echo "$redacted" | sed -E "s/$PATTERN_EMAIL/[EMAIL-REDACTED]/g")

    # Redact SSN
    redacted=$(echo "$redacted" | sed -E "s/$PATTERN_SSN/[SSN-REDACTED]/g")

    # Redact credit cards
    redacted=$(echo "$redacted" | sed -E "s/$PATTERN_CREDIT_CARD/[CARD-REDACTED]/g")

    # Redact phone numbers
    redacted=$(echo "$redacted" | sed -E "s/$PATTERN_PHONE/[PHONE-REDACTED]/g")

    # Redact API keys
    redacted=$(echo "$redacted" | sed -E "s/$PATTERN_API_KEY_GENERIC/[API-KEY-REDACTED]/g")

    # Redact AWS keys
    redacted=$(echo "$redacted" | sed -E "s/$PATTERN_AWS_KEY/[AWS-KEY-REDACTED]/g")

    # Redact GitHub tokens
    redacted=$(echo "$redacted" | sed -E "s/$PATTERN_GITHUB_TOKEN/[GITHUB-TOKEN-REDACTED]/g")

    # Redact Slack tokens
    redacted=$(echo "$redacted" | sed -E "s/$PATTERN_SLACK_TOKEN/[SLACK-TOKEN-REDACTED]/g")

    # Redact IP addresses (be careful - might redact version numbers)
    # Only redact if looks like real IP (not 1.2.3.4 from docs)

    echo "$redacted"
}

# Check if content is safe (no high-risk PII)
# Returns: 0 if safe, 1 if unsafe
is_content_safe() {
    local content="$1"
    local result=$(scan_for_pii "$content")

    local risk_level=$(echo "$result" | jq -r '.risk_level')

    if [ "$risk_level" = "critical" ] || [ "$risk_level" = "high" ]; then
        return 1
    else
        return 0
    fi
}

# Log PII finding to governance log
log_pii_finding() {
    local scan_result="$1"
    local source="${2:-unknown}"

    # Extract key info
    local has_pii=$(echo "$scan_result" | jq -r '.has_pii')
    local risk_level=$(echo "$scan_result" | jq -r '.risk_level')
    local findings_count=$(echo "$scan_result" | jq -r '.findings_count.total')

    if [ "$has_pii" = "true" ]; then
        # Log to governance log
        local log_entry=$(cat <<EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "event_type": "pii_detected",
  "source": "$source",
  "risk_level": "$risk_level",
  "findings_count": $findings_count,
  "principal": "${COMMIT_RELAY_PRINCIPAL:-system}",
  "scan_result": $scan_result
}
EOF
)

        # Append to PII log
        local pii_log="${COMMIT_RELAY_HOME:-/Users/ryandahlberg/commit-relay}/coordination/governance/pii-incidents.jsonl"
        mkdir -p "$(dirname "$pii_log")"
        echo "$log_entry" >> "$pii_log"
    fi
}

# Scan file for PII
scan_file_for_pii() {
    local file_path="$1"

    if [ ! -f "$file_path" ]; then
        echo '{"error": "file_not_found", "has_pii": false}'
        return 1
    fi

    local content=$(cat "$file_path")
    local result=$(scan_for_pii "$content" "file:$file_path")

    # Log if PII found
    log_pii_finding "$result" "$file_path"

    echo "$result"
}

# Export functions
export -f scan_for_pii 2>/dev/null || true
export -f redact_pii 2>/dev/null || true
export -f is_content_safe 2>/dev/null || true
export -f log_pii_finding 2>/dev/null || true
export -f scan_file_for_pii 2>/dev/null || true

# Log that PII scanner is loaded
if [ "${COMMIT_RELAY_LOG_LEVEL:-1}" -le 0 ] 2>/dev/null; then
    echo "[GOVERNANCE] PII scanner loaded" >&2
fi
