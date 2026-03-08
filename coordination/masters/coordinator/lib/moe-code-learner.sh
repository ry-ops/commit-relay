#!/bin/bash
# coordination/masters/coordinator/lib/moe-code-learner.sh
# MoE Code Pattern Learner
# Analyzes code-runner findings to improve code quality routing and validation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/../../../.." && pwd)}"

FINDINGS_DIR="$COMMIT_RELAY_HOME/coordination/code-runner/findings"
LEARNING_DIR="$COMMIT_RELAY_HOME/coordination/masters/coordinator/knowledge-base/code-patterns"
ROUTING_KB="$COMMIT_RELAY_HOME/coordination/masters/coordinator/knowledge-base/routing-decisions.jsonl"

# Ensure directories exist
mkdir -p "$LEARNING_DIR"

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] MOE-LEARNER: $1"
}

log "Starting MoE code pattern learning cycle"

# Find all findings reports
REPORT_COUNT=0
PATTERN_COUNT=0

for report in "$FINDINGS_DIR"/report-*.json; do
    [ -f "$report" ] || continue

    REPORT_COUNT=$((REPORT_COUNT + 1))

    # Extract patterns from report
    commit=$(jq -r '.commit' "$report")
    issue_count=$(jq -r '.issue_count' "$report")

    log "Processing report: $(basename "$report") (commit: ${commit:0:8}, issues: $issue_count)"

    # Learn from each finding
    jq -c '.findings[]' "$report" 2>/dev/null | while read -r finding; do
        pattern_type=$(echo "$finding" | jq -r '.type')
        severity=$(echo "$finding" | jq -r '.severity')
        file=$(echo "$finding" | jq -r '.file')
        message=$(echo "$finding" | jq -r '.message')

        # Determine file type
        file_ext="${file##*.}"

        # Create learning entry
        cat >> "$LEARNING_DIR/learned-patterns.jsonl" << EOF
{"timestamp":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","commit":"$commit","pattern":"$pattern_type","severity":"$severity","file_type":"$file_ext","message":$(echo "$message" | jq -Rs .),"source":"code_runner"}
EOF

        PATTERN_COUNT=$((PATTERN_COUNT + 1))

        # Feed to MoE routing knowledge
        case "$pattern_type" in
            syntax_error)
                # Critical errors should be routed to development master
                echo "{\"event\":\"code_quality_learned\",\"pattern\":\"syntax_error\",\"file_type\":\"$file_ext\",\"routing_hint\":\"development\",\"severity\":\"$severity\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" >> "$ROUTING_KB"
                ;;
            security_risk)
                # Security issues should be routed to security master
                echo "{\"event\":\"code_quality_learned\",\"pattern\":\"security_risk\",\"file_type\":\"$file_ext\",\"routing_hint\":\"security\",\"severity\":\"$severity\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" >> "$ROUTING_KB"
                ;;
            best_practice)
                # Best practice issues go to development for improvement
                echo "{\"event\":\"code_quality_learned\",\"pattern\":\"best_practice\",\"file_type\":\"$file_ext\",\"routing_hint\":\"development\",\"severity\":\"$severity\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" >> "$ROUTING_KB"
                ;;
        esac
    done
done

# Generate insights report
if [ "$REPORT_COUNT" -gt 0 ]; then
    log "Generating MoE insights from $REPORT_COUNT reports, $PATTERN_COUNT patterns"

    # Analyze pattern trends
    INSIGHTS_FILE="$LEARNING_DIR/insights-$(date +%Y%m%d).json"

    cat > "$INSIGHTS_FILE" << EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "reports_analyzed": $REPORT_COUNT,
  "patterns_learned": $PATTERN_COUNT,
  "top_patterns": $(jq -s 'group_by(.pattern) | map({pattern: .[0].pattern, count: length}) | sort_by(.count) | reverse | .[0:5]' "$LEARNING_DIR/learned-patterns.jsonl" 2>/dev/null || echo '[]'),
  "file_type_distribution": $(jq -s 'group_by(.file_type) | map({file_type: .[0].file_type, count: length})' "$LEARNING_DIR/learned-patterns.jsonl" 2>/dev/null || echo '[]'),
  "severity_distribution": $(jq -s 'group_by(.severity) | map({severity: .[0].severity, count: length})' "$LEARNING_DIR/learned-patterns.jsonl" 2>/dev/null || echo '[]'),
  "recommendations": [
    "Use code-runner patterns to improve pre-commit validation",
    "Route security patterns to security master automatically",
    "Update worker templates with common best practices"
  ]
}
EOF

    log "Insights report generated: $INSIGHTS_FILE"

    # Update MoE routing confidence based on patterns
    syntax_errors=$(jq -s '[.[] | select(.pattern == "syntax_error")] | length' "$LEARNING_DIR/learned-patterns.jsonl" 2>/dev/null || echo 0)
    security_risks=$(jq -s '[.[] | select(.pattern == "security_risk")] | length' "$LEARNING_DIR/learned-patterns.jsonl" 2>/dev/null || echo 0)

    if [ "$syntax_errors" -gt 10 ]; then
        log "High syntax error rate detected ($syntax_errors) - recommending enhanced validation"
        echo "{\"event\":\"moe_recommendation\",\"type\":\"enhanced_validation\",\"reason\":\"high_syntax_error_rate\",\"count\":$syntax_errors,\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" >> "$ROUTING_KB"
    fi

    if [ "$security_risks" -gt 5 ]; then
        log "Security risks detected ($security_risks) - recommending security review"
        echo "{\"event\":\"moe_recommendation\",\"type\":\"security_review_required\",\"reason\":\"high_security_risk_rate\",\"count\":$security_risks,\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" >> "$ROUTING_KB"
    fi
fi

log "MoE learning cycle complete: $REPORT_COUNT reports, $PATTERN_COUNT patterns learned"

exit 0
