#!/bin/bash
# scripts/lib/risk-scorer.sh
# Risk Scorer Library - Phase 3 Item 29
# Scores tasks by risk and allocates resources accordingly
#
# Features:
#   - Multi-factor risk scoring
#   - Historical failure rate analysis
#   - Resource adjustment based on risk
#   - Risk-based prioritization
#
# Usage:
#   source "$COMMIT_RELAY_HOME/scripts/lib/risk-scorer.sh"
#   risk=$(score_task_risk --task-description "..." --worker-type "implementation-worker")

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# Risk configuration
RISK_CONFIG_FILE="${COMMIT_RELAY_HOME}/coordination/config/risk-scoring-policy.json"

# Historical data
RISK_HISTORY_FILE="${COMMIT_RELAY_HOME}/coordination/metrics/risk-scoring-history.jsonl"
TASK_OUTCOMES_FILE="${COMMIT_RELAY_HOME}/coordination/metrics/task-outcomes.jsonl"

# Create directories
mkdir -p "$(dirname "$RISK_HISTORY_FILE")"
mkdir -p "$(dirname "$RISK_CONFIG_FILE")"

# ============================================================================
# Logging
# ============================================================================

log_risk() {
    local level="$1"
    shift
    echo "[$(date +%Y-%m-%dT%H:%M:%S%z)] [RISK] [$level] $*" >&2
}

# ============================================================================
# Initialize Configuration
# ============================================================================

initialize_risk_config() {
    if [ ! -f "$RISK_CONFIG_FILE" ]; then
        cat > "$RISK_CONFIG_FILE" <<'EOF'
{
  "version": "1.0.0",
  "risk_factors": {
    "complexity": {
      "weight": 0.25,
      "thresholds": {
        "simple": 10,
        "moderate": 30,
        "complex": 60,
        "very_complex": 90
      }
    },
    "historical_failure_rate": {
      "weight": 0.30,
      "base_score_multiplier": 100
    },
    "resource_intensity": {
      "weight": 0.15,
      "token_threshold_high": 20000,
      "timeout_threshold_high": 60
    },
    "scope_breadth": {
      "weight": 0.15,
      "file_count_thresholds": {
        "low": 3,
        "medium": 7,
        "high": 15
      }
    },
    "dependency_count": {
      "weight": 0.15,
      "thresholds": {
        "low": 2,
        "medium": 5,
        "high": 10
      }
    }
  },
  "risk_keywords": {
    "high": [
      "security", "authentication", "authorization", "encryption",
      "database migration", "schema change", "production", "critical",
      "payment", "financial", "pii", "sensitive", "destructive"
    ],
    "medium": [
      "api", "integration", "performance", "optimization",
      "refactor", "async", "concurrent", "distributed"
    ],
    "low": [
      "documentation", "comment", "typo", "formatting",
      "readme", "style", "lint"
    ]
  },
  "risk_levels": {
    "low": {"min": 0, "max": 25},
    "medium": {"min": 26, "max": 50},
    "high": {"min": 51, "max": 75},
    "critical": {"min": 76, "max": 100}
  },
  "resource_adjustments": {
    "low": {
      "token_multiplier": 1.0,
      "timeout_multiplier": 1.0,
      "priority_boost": 0
    },
    "medium": {
      "token_multiplier": 1.2,
      "timeout_multiplier": 1.2,
      "priority_boost": 1
    },
    "high": {
      "token_multiplier": 1.5,
      "timeout_multiplier": 1.5,
      "priority_boost": 2
    },
    "critical": {
      "token_multiplier": 2.0,
      "timeout_multiplier": 2.0,
      "priority_boost": 3
    }
  }
}
EOF
        log_risk "INFO" "Created default risk scoring config"
    fi
}

initialize_risk_config

# ============================================================================
# Risk Factor Calculations
# ============================================================================

# Calculate complexity risk score
calculate_complexity_risk() {
    local description="$1"
    local description_lower=$(echo "$description" | tr '[:upper:]' '[:lower:]')

    local score=0

    # Load high risk keywords
    local high_keywords=$(jq -r '.risk_keywords.high[]' "$RISK_CONFIG_FILE")
    local medium_keywords=$(jq -r '.risk_keywords.medium[]' "$RISK_CONFIG_FILE")
    local low_keywords=$(jq -r '.risk_keywords.low[]' "$RISK_CONFIG_FILE")

    # Check for high risk keywords
    while IFS= read -r keyword; do
        if echo "$description_lower" | grep -qi "$keyword"; then
            score=$((score + 15))
        fi
    done <<< "$high_keywords"

    # Check for medium risk keywords
    while IFS= read -r keyword; do
        if echo "$description_lower" | grep -qi "$keyword"; then
            score=$((score + 8))
        fi
    done <<< "$medium_keywords"

    # Check for low risk keywords (reduce score)
    while IFS= read -r keyword; do
        if echo "$description_lower" | grep -qi "$keyword"; then
            score=$((score - 5))
        fi
    done <<< "$low_keywords"

    # Word count factor
    local word_count=$(echo "$description" | wc -w | tr -d ' ')
    if [ "$word_count" -gt 100 ]; then
        score=$((score + 10))
    elif [ "$word_count" -gt 50 ]; then
        score=$((score + 5))
    fi

    # Normalize to 0-100
    if [ "$score" -lt 0 ]; then
        score=0
    elif [ "$score" -gt 100 ]; then
        score=100
    fi

    echo "$score"
}

# Calculate historical failure rate risk
calculate_historical_risk() {
    local worker_type="$1"
    local task_type="${2:-}"

    local score=0

    if [ ! -f "$TASK_OUTCOMES_FILE" ]; then
        echo "25"  # Default medium-low risk when no history
        return
    fi

    # Get recent outcomes for this worker type
    local recent_outcomes=""
    if [ -n "$task_type" ]; then
        recent_outcomes=$(grep "\"worker_type\":\"$worker_type\"" "$TASK_OUTCOMES_FILE" | \
                        grep "\"task_type\":\"$task_type\"" | \
                        tail -20)
    else
        recent_outcomes=$(grep "\"worker_type\":\"$worker_type\"" "$TASK_OUTCOMES_FILE" | \
                        tail -20)
    fi

    if [ -z "$recent_outcomes" ]; then
        echo "25"
        return
    fi

    # Calculate failure rate
    local total=$(echo "$recent_outcomes" | wc -l | tr -d ' ')
    local failures=$(echo "$recent_outcomes" | grep '"status":"failed"' | wc -l | tr -d ' ')

    if [ "$total" -gt 0 ]; then
        local failure_rate=$(echo "scale=2; $failures / $total" | bc)
        local multiplier=$(jq -r '.risk_factors.historical_failure_rate.base_score_multiplier' "$RISK_CONFIG_FILE")
        score=$(echo "$failure_rate * $multiplier" | bc)
        score=${score%.*}
    fi

    echo "$score"
}

# Calculate resource intensity risk
calculate_resource_risk() {
    local token_budget="$1"
    local timeout_minutes="$2"

    local score=0

    local token_threshold=$(jq -r '.risk_factors.resource_intensity.token_threshold_high' "$RISK_CONFIG_FILE")
    local timeout_threshold=$(jq -r '.risk_factors.resource_intensity.timeout_threshold_high' "$RISK_CONFIG_FILE")

    # Token budget factor
    if [ "$token_budget" -ge "$token_threshold" ]; then
        score=$((score + 50))
    elif [ "$token_budget" -ge $((token_threshold / 2)) ]; then
        score=$((score + 25))
    fi

    # Timeout factor
    if [ "$timeout_minutes" -ge "$timeout_threshold" ]; then
        score=$((score + 50))
    elif [ "$timeout_minutes" -ge $((timeout_threshold / 2)) ]; then
        score=$((score + 25))
    fi

    # Cap at 100
    if [ "$score" -gt 100 ]; then
        score=100
    fi

    echo "$score"
}

# Calculate scope risk
calculate_scope_risk() {
    local file_count="$1"

    local low_threshold=$(jq -r '.risk_factors.scope_breadth.file_count_thresholds.low' "$RISK_CONFIG_FILE")
    local medium_threshold=$(jq -r '.risk_factors.scope_breadth.file_count_thresholds.medium' "$RISK_CONFIG_FILE")
    local high_threshold=$(jq -r '.risk_factors.scope_breadth.file_count_thresholds.high' "$RISK_CONFIG_FILE")

    local score=0

    if [ "$file_count" -ge "$high_threshold" ]; then
        score=90
    elif [ "$file_count" -ge "$medium_threshold" ]; then
        score=60
    elif [ "$file_count" -ge "$low_threshold" ]; then
        score=30
    else
        score=10
    fi

    echo "$score"
}

# Calculate dependency risk
calculate_dependency_risk() {
    local dependencies="$1"  # Comma-separated list or count

    local count
    if [[ "$dependencies" =~ ^[0-9]+$ ]]; then
        count="$dependencies"
    else
        count=$(echo "$dependencies" | tr ',' '\n' | grep -c . || echo "0")
    fi

    local low_threshold=$(jq -r '.risk_factors.dependency_count.thresholds.low' "$RISK_CONFIG_FILE")
    local medium_threshold=$(jq -r '.risk_factors.dependency_count.thresholds.medium' "$RISK_CONFIG_FILE")
    local high_threshold=$(jq -r '.risk_factors.dependency_count.thresholds.high' "$RISK_CONFIG_FILE")

    local score=0

    if [ "$count" -ge "$high_threshold" ]; then
        score=90
    elif [ "$count" -ge "$medium_threshold" ]; then
        score=60
    elif [ "$count" -ge "$low_threshold" ]; then
        score=30
    else
        score=10
    fi

    echo "$score"
}

# ============================================================================
# Main Risk Scoring Function
# ============================================================================

score_task_risk() {
    local task_description=""
    local worker_type="implementation-worker"
    local task_type=""
    local token_budget="10000"
    local timeout_minutes="30"
    local file_count="1"
    local dependencies="0"
    local task_id=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --task-description)
                task_description="$2"
                shift 2
                ;;
            --worker-type)
                worker_type="$2"
                shift 2
                ;;
            --task-type)
                task_type="$2"
                shift 2
                ;;
            --token-budget)
                token_budget="$2"
                shift 2
                ;;
            --timeout-minutes)
                timeout_minutes="$2"
                shift 2
                ;;
            --file-count)
                file_count="$2"
                shift 2
                ;;
            --dependencies)
                dependencies="$2"
                shift 2
                ;;
            --task-id)
                task_id="$2"
                shift 2
                ;;
            *)
                echo "ERROR: Unknown option: $1" >&2
                return 1
                ;;
        esac
    done

    if [ -z "$task_description" ]; then
        echo "ERROR: --task-description is required" >&2
        return 1
    fi

    # Calculate individual risk scores
    local complexity_score=$(calculate_complexity_risk "$task_description")
    local historical_score=$(calculate_historical_risk "$worker_type" "$task_type")
    local resource_score=$(calculate_resource_risk "$token_budget" "$timeout_minutes")
    local scope_score=$(calculate_scope_risk "$file_count")
    local dependency_score=$(calculate_dependency_risk "$dependencies")

    # Get weights
    local complexity_weight=$(jq -r '.risk_factors.complexity.weight' "$RISK_CONFIG_FILE")
    local historical_weight=$(jq -r '.risk_factors.historical_failure_rate.weight' "$RISK_CONFIG_FILE")
    local resource_weight=$(jq -r '.risk_factors.resource_intensity.weight' "$RISK_CONFIG_FILE")
    local scope_weight=$(jq -r '.risk_factors.scope_breadth.weight' "$RISK_CONFIG_FILE")
    local dependency_weight=$(jq -r '.risk_factors.dependency_count.weight' "$RISK_CONFIG_FILE")

    # Calculate weighted total
    local total_score=$(echo "scale=2; \
        $complexity_score * $complexity_weight + \
        $historical_score * $historical_weight + \
        $resource_score * $resource_weight + \
        $scope_score * $scope_weight + \
        $dependency_score * $dependency_weight" | bc)

    local total_int=${total_score%.*}

    # Determine risk level
    local risk_level="medium"
    local low_max=$(jq -r '.risk_levels.low.max' "$RISK_CONFIG_FILE")
    local medium_max=$(jq -r '.risk_levels.medium.max' "$RISK_CONFIG_FILE")
    local high_max=$(jq -r '.risk_levels.high.max' "$RISK_CONFIG_FILE")

    if [ "$total_int" -le "$low_max" ]; then
        risk_level="low"
    elif [ "$total_int" -le "$medium_max" ]; then
        risk_level="medium"
    elif [ "$total_int" -le "$high_max" ]; then
        risk_level="high"
    else
        risk_level="critical"
    fi

    # Get resource adjustments
    local token_mult=$(jq -r --arg level "$risk_level" '.resource_adjustments[$level].token_multiplier' "$RISK_CONFIG_FILE")
    local timeout_mult=$(jq -r --arg level "$risk_level" '.resource_adjustments[$level].timeout_multiplier' "$RISK_CONFIG_FILE")
    local priority_boost=$(jq -r --arg level "$risk_level" '.resource_adjustments[$level].priority_boost' "$RISK_CONFIG_FILE")

    # Calculate adjusted resources
    local adjusted_tokens=$(echo "$token_budget * $token_mult" | bc)
    local adjusted_timeout=$(echo "$timeout_minutes * $timeout_mult" | bc)
    adjusted_tokens=${adjusted_tokens%.*}
    adjusted_timeout=${adjusted_timeout%.*}

    # Build result
    local result=$(jq -nc \
        --arg task_id "${task_id:-unspecified}" \
        --argjson total_score "$total_int" \
        --arg risk_level "$risk_level" \
        --argjson complexity_score "$complexity_score" \
        --argjson historical_score "$historical_score" \
        --argjson resource_score "$resource_score" \
        --argjson scope_score "$scope_score" \
        --argjson dependency_score "$dependency_score" \
        --argjson original_tokens "$token_budget" \
        --argjson adjusted_tokens "$adjusted_tokens" \
        --argjson original_timeout "$timeout_minutes" \
        --argjson adjusted_timeout "$adjusted_timeout" \
        --argjson priority_boost "$priority_boost" \
        --arg scored_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            task_id: $task_id,
            risk_score: $total_score,
            risk_level: $risk_level,
            factor_scores: {
                complexity: $complexity_score,
                historical: $historical_score,
                resource_intensity: $resource_score,
                scope: $scope_score,
                dependencies: $dependency_score
            },
            resource_adjustments: {
                original_token_budget: $original_tokens,
                adjusted_token_budget: $adjusted_tokens,
                original_timeout: $original_timeout,
                adjusted_timeout: $adjusted_timeout,
                priority_boost: $priority_boost
            },
            scored_at: $scored_at
        }')

    # Record to history
    echo "$result" >> "$RISK_HISTORY_FILE"

    log_risk "INFO" "Scored task: $task_id -> $risk_level ($total_int)"

    echo "$result"
}

# ============================================================================
# Risk Analysis
# ============================================================================

# Get risk summary for recent tasks
get_risk_summary() {
    local hours="${1:-24}"

    if [ ! -f "$RISK_HISTORY_FILE" ]; then
        echo '{"total":0,"by_level":{}}'
        return
    fi

    local cutoff=$(date -v-${hours}H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -d "$hours hours ago" +%Y-%m-%dT%H:%M:%SZ)

    # Count by risk level
    local total=$(wc -l < "$RISK_HISTORY_FILE" | tr -d ' ')
    local low=$(grep '"risk_level":"low"' "$RISK_HISTORY_FILE" | wc -l | tr -d ' ')
    local medium=$(grep '"risk_level":"medium"' "$RISK_HISTORY_FILE" | wc -l | tr -d ' ')
    local high=$(grep '"risk_level":"high"' "$RISK_HISTORY_FILE" | wc -l | tr -d ' ')
    local critical=$(grep '"risk_level":"critical"' "$RISK_HISTORY_FILE" | wc -l | tr -d ' ')

    jq -nc \
        --argjson total "$total" \
        --argjson low "$low" \
        --argjson medium "$medium" \
        --argjson high "$high" \
        --argjson critical "$critical" \
        '{
            total_scored: $total,
            by_level: {
                low: $low,
                medium: $medium,
                high: $high,
                critical: $critical
            }
        }'
}

# Record task outcome for learning
record_task_outcome() {
    local task_id="$1"
    local worker_type="$2"
    local task_type="$3"
    local status="$4"  # completed, failed
    local risk_score="${5:-0}"

    local outcome=$(jq -nc \
        --arg task_id "$task_id" \
        --arg worker_type "$worker_type" \
        --arg task_type "$task_type" \
        --arg status "$status" \
        --argjson risk_score "$risk_score" \
        --arg recorded_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            task_id: $task_id,
            worker_type: $worker_type,
            task_type: $task_type,
            status: $status,
            risk_score: $risk_score,
            recorded_at: $recorded_at
        }')

    echo "$outcome" >> "$TASK_OUTCOMES_FILE"
    log_risk "INFO" "Recorded outcome: $task_id -> $status"
}

# Export functions
export -f score_task_risk 2>/dev/null || true
export -f calculate_complexity_risk 2>/dev/null || true
export -f calculate_historical_risk 2>/dev/null || true
export -f get_risk_summary 2>/dev/null || true
export -f record_task_outcome 2>/dev/null || true

log_risk "INFO" "Risk scorer library loaded"
