#!/bin/bash
# agents/code-runner/code-runner.sh
# Autonomous Code Quality Agent
# Runs on every commit to analyze code and feed learnings to MoE system

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
FINDINGS_DIR="$COMMIT_RELAY_HOME/coordination/code-runner/findings"
LEARNING_DIR="$COMMIT_RELAY_HOME/coordination/masters/coordinator/knowledge-base/code-patterns"

# Ensure directories exist
mkdir -p "$FINDINGS_DIR"
mkdir -p "$LEARNING_DIR"

# Get commit information
COMMIT_HASH="${1:-HEAD}"
COMMIT_MSG=$(git log -1 --pretty=%B "$COMMIT_HASH" 2>/dev/null || echo "Unknown commit")

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] CODE-RUNNER: $1"
}

log "Starting code analysis for commit: ${COMMIT_HASH:0:8}"

# Initialize findings report
REPORT_FILE="$FINDINGS_DIR/report-$(date +%s)-${COMMIT_HASH:0:8}.json"
FINDINGS=()
ISSUE_COUNT=0
FILES_ANALYZED=0

# Get list of changed files in this commit
CHANGED_FILES=$(git diff-tree --no-commit-id --name-only -r "$COMMIT_HASH" 2>/dev/null || echo "")

if [ -z "$CHANGED_FILES" ]; then
    log "No files changed in commit, skipping analysis"
    exit 0
fi

log "Analyzing $(echo "$CHANGED_FILES" | wc -l | tr -d ' ') changed files"

# Function to analyze shell scripts
analyze_shell_script() {
    local file="$1"
    local findings=()

    # Syntax check
    if ! bash -n "$file" 2>&1 | grep -q "syntax error"; then
        log "  ✓ $file: Syntax OK" >&2
    else
        local error=$(bash -n "$file" 2>&1)
        findings+=("{\"type\":\"syntax_error\",\"severity\":\"high\",\"file\":\"$file\",\"message\":\"$error\"}")
        ISSUE_COUNT=$((ISSUE_COUNT + 1))
        log "  ✗ $file: Syntax error found" >&2
    fi

    # Check for common issues
    if grep -q "rm -rf /" "$file" 2>/dev/null; then
        findings+=("{\"type\":\"dangerous_command\",\"severity\":\"critical\",\"file\":\"$file\",\"message\":\"Dangerous rm -rf / command detected\"}")
        ISSUE_COUNT=$((ISSUE_COUNT + 1))
    fi

    if grep -q "eval" "$file" 2>/dev/null && ! grep -q "# eval: safe" "$file"; then
        findings+=("{\"type\":\"security_risk\",\"severity\":\"medium\",\"file\":\"$file\",\"message\":\"Unsafe eval usage detected\"}")
        ISSUE_COUNT=$((ISSUE_COUNT + 1))
    fi

    # Check for set -euo pipefail
    if ! grep -q "set -euo pipefail" "$file" 2>/dev/null && ! grep -q "set -e" "$file"; then
        findings+=("{\"type\":\"best_practice\",\"severity\":\"low\",\"file\":\"$file\",\"message\":\"Missing error handling: set -euo pipefail\"}")
    fi

    # Check for proper quoting
    if grep -E '\$[A-Za-z_][A-Za-z0-9_]*[^"]' "$file" 2>/dev/null | grep -v "^#" | head -1 >/dev/null; then
        findings+=("{\"type\":\"best_practice\",\"severity\":\"low\",\"file\":\"$file\",\"message\":\"Unquoted variables detected (potential word splitting)\"}")
    fi

    # Return findings
    printf '%s\n' "${findings[@]}"
}

# Function to analyze JavaScript/Node files
analyze_javascript() {
    local file="$1"
    local findings=()

    # Syntax check
    if node --check "$file" 2>&1 | grep -q "SyntaxError"; then
        local error=$(node --check "$file" 2>&1 | head -1)
        findings+=("{\"type\":\"syntax_error\",\"severity\":\"high\",\"file\":\"$file\",\"message\":\"$error\"}")
        ISSUE_COUNT=$((ISSUE_COUNT + 1))
        log "  ✗ $file: Syntax error found" >&2
    else
        log "  ✓ $file: Syntax OK" >&2
    fi

    # Check for console.log in production code
    if grep -q "console.log" "$file" 2>/dev/null && ! echo "$file" | grep -q "test"; then
        findings+=("{\"type\":\"code_quality\",\"severity\":\"low\",\"file\":\"$file\",\"message\":\"console.log detected in production code\"}")
    fi

    # Check for eval usage
    if grep -q "eval(" "$file" 2>/dev/null; then
        findings+=("{\"type\":\"security_risk\",\"severity\":\"high\",\"file\":\"$file\",\"message\":\"eval() usage detected - security risk\"}")
        ISSUE_COUNT=$((ISSUE_COUNT + 1))
    fi

    # Check for == instead of ===
    if grep -E "==([^=]|$)" "$file" 2>/dev/null | grep -v "^//" | head -1 >/dev/null; then
        findings+=("{\"type\":\"best_practice\",\"severity\":\"low\",\"file\":\"$file\",\"message\":\"Use === instead of == for comparison\"}")
    fi

    printf '%s\n' "${findings[@]}"
}

# Function to analyze Python files
analyze_python() {
    local file="$1"
    local findings=()

    # Syntax check
    if python3 -m py_compile "$file" 2>&1 | grep -q "SyntaxError"; then
        local error=$(python3 -m py_compile "$file" 2>&1 | head -1)
        findings+=("{\"type\":\"syntax_error\",\"severity\":\"high\",\"file\":\"$file\",\"message\":\"$error\"}")
        ISSUE_COUNT=$((ISSUE_COUNT + 1))
        log "  ✗ $file: Syntax error found" >&2
    else
        log "  ✓ $file: Syntax OK" >&2
    fi

    # Check for eval/exec usage
    if grep -q "eval\|exec" "$file" 2>/dev/null && ! grep -q "# safe" "$file"; then
        findings+=("{\"type\":\"security_risk\",\"severity\":\"high\",\"file\":\"$file\",\"message\":\"eval/exec usage detected\"}")
        ISSUE_COUNT=$((ISSUE_COUNT + 1))
    fi

    printf '%s\n' "${findings[@]}"
}

# Analyze each changed file
while IFS= read -r file; do
    # Skip deleted files
    [ -f "$file" ] || continue

    FILES_ANALYZED=$((FILES_ANALYZED + 1))

    # Determine file type and analyze
    case "$file" in
        *.sh)
            log "Analyzing shell script: $file"
            file_findings=$(analyze_shell_script "$file")
            [ -n "$file_findings" ] && FINDINGS+=("$file_findings")
            ;;
        *.js)
            log "Analyzing JavaScript: $file"
            file_findings=$(analyze_javascript "$file")
            [ -n "$file_findings" ] && FINDINGS+=("$file_findings")
            ;;
        *.py)
            log "Analyzing Python: $file"
            file_findings=$(analyze_python "$file")
            [ -n "$file_findings" ] && FINDINGS+=("$file_findings")
            ;;
        *.json)
            log "Validating JSON: $file"
            if ! jq empty "$file" 2>/dev/null; then
                FINDINGS+=("{\"type\":\"syntax_error\",\"severity\":\"high\",\"file\":\"$file\",\"message\":\"Invalid JSON\"}")
                ISSUE_COUNT=$((ISSUE_COUNT + 1))
                log "  ✗ $file: Invalid JSON" >&2
            else
                log "  ✓ $file: Valid JSON" >&2
            fi
            ;;
        *)
            log "Skipping unsupported file type: $file"
            ;;
    esac
done <<< "$CHANGED_FILES"

# Generate findings report
# Write findings to temp file for jq to process
TMP_FINDINGS=$(mktemp)
if [ "${#FINDINGS[@]}" -gt 0 ]; then
    printf '%s\n' "${FINDINGS[@]}" > "$TMP_FINDINGS"
else
    echo "[]" > "$TMP_FINDINGS"
fi

# Use jq to build complete JSON report
jq -n \
  --arg commit "$COMMIT_HASH" \
  --arg commit_msg "$COMMIT_MSG" \
  --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson files "$FILES_ANALYZED" \
  --argjson issues "$ISSUE_COUNT" \
  --slurpfile findings_raw "$TMP_FINDINGS" \
  '
  # Parse findings or use empty array
  ($findings_raw[0] // [] | if type == "array" then . else [.] end) as $findings_array |
  ($findings_array | map(select(.severity == "critical")) | length) as $critical |
  ($findings_array | map(select(.severity == "high")) | length) as $high |
  ($findings_array | map(select(.severity == "medium")) | length) as $medium |
  ($findings_array | map(select(.severity == "low")) | length) as $low |
  {
    commit: $commit,
    commit_message: $commit_msg,
    timestamp: $timestamp,
    files_analyzed: $files,
    issue_count: $issues,
    findings: $findings_array,
    summary: {
      critical: $critical,
      high: $high,
      medium: $medium,
      low: $low
    }
  }
  ' > "$REPORT_FILE"

rm "$TMP_FINDINGS"

log "Analysis complete. Report: $REPORT_FILE"
log "Summary: $FILES_ANALYZED files analyzed, $ISSUE_COUNT issues found"

# If issues found, create task for coordinator
if [ "$ISSUE_COUNT" -gt 0 ]; then
    log "Creating improvement task for coordinator"

    TASK_ID="task-code-quality-$(date +%s)"
    PRIORITY="medium"

    # Escalate priority if critical issues found
    critical_count=$(jq -r '.summary.critical' "$REPORT_FILE")
    high_count=$(jq -r '.summary.high' "$REPORT_FILE")

    if [ "$critical_count" -gt 0 ]; then
        PRIORITY="critical"
    elif [ "$high_count" -gt 0 ]; then
        PRIORITY="high"
    fi

    # Create task in task queue
    jq --arg tid "$TASK_ID" \
       --arg title "Code Quality: Fix $ISSUE_COUNT issues in commit ${COMMIT_HASH:0:8}" \
       --arg desc "Code-runner detected $ISSUE_COUNT code quality issues. Critical: $critical_count, High: $high_count. See report: $REPORT_FILE" \
       --arg priority "$PRIORITY" \
       --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       '.tasks += [{
           "id": $tid,
           "title": $title,
           "description": $desc,
           "priority": $priority,
           "type": "code_quality",
           "status": "pending",
           "created_at": $ts,
           "updated_at": $ts,
           "created_by": "code-runner",
           "context": {
               "commit": "'$COMMIT_HASH'",
               "report": "'$REPORT_FILE'",
               "issue_count": '$ISSUE_COUNT'
           }
       }]' "$COMMIT_RELAY_HOME/coordination/task-queue.json" > /tmp/task-queue-code-runner.json && \
    mv /tmp/task-queue-code-runner.json "$COMMIT_RELAY_HOME/coordination/task-queue.json"

    log "Created task: $TASK_ID (priority: $PRIORITY)"
fi

# Feed learnings to MoE system
log "Feeding learnings to MoE system"

LEARNING_FILE="$LEARNING_DIR/patterns-$(date +%Y%m%d).jsonl"

# Extract patterns for MoE learning
jq -c '.findings[] | {
    pattern_type: .type,
    severity: .severity,
    file_type: (.file | split(".") | .[-1]),
    message: .message,
    timestamp: now | todate
}' "$REPORT_FILE" >> "$LEARNING_FILE" 2>/dev/null || true

# Update MoE routing knowledge with code patterns
if [ -f "$COMMIT_RELAY_HOME/coordination/masters/coordinator/knowledge-base/routing-decisions.jsonl" ]; then
    echo "{\"event\":\"code_analysis\",\"commit\":\"$COMMIT_HASH\",\"issues\":$ISSUE_COUNT,\"files\":$FILES_ANALYZED,\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"insight\":\"code_runner_pattern_detection\"}" >> \
        "$COMMIT_RELAY_HOME/coordination/masters/coordinator/knowledge-base/routing-decisions.jsonl"
fi

# Trigger MoE learning from findings
MOE_LEARNER="$COMMIT_RELAY_HOME/coordination/masters/coordinator/lib/moe-code-learner.sh"
if [ -x "$MOE_LEARNER" ] && [ "$ISSUE_COUNT" -gt 0 ]; then
    log "Triggering MoE learning cycle"
    "$MOE_LEARNER" >> "$COMMIT_RELAY_HOME/agents/logs/system/code-runner.log" 2>&1 || \
        log "Warning: MoE learner execution failed (non-critical)"
fi

log "Code-runner analysis complete"

# Exit with status based on severity
if [ "$ISSUE_COUNT" -gt 0 ]; then
    critical_count=$(jq -r '.summary.critical' "$REPORT_FILE")
    high_count=$(jq -r '.summary.high' "$REPORT_FILE")

    if [ "$critical_count" -gt 0 ]; then
        log "CRITICAL issues found - review required"
        exit 1
    elif [ "$high_count" -gt 0 ]; then
        log "HIGH severity issues found - review recommended"
        exit 0  # Don't block commit
    fi
fi

log "No critical issues found"
exit 0
