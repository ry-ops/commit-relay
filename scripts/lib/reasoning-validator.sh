#!/bin/bash
# scripts/lib/reasoning-validator.sh
# Reasoning Trace Validator - Phase 3 Item 38
# Validates logical consistency of reasoning traces before adding to training set
#
# Features:
#   - Check reasoning steps for consistency
#   - Detect logical fallacies
#   - Filter low-quality traces
#   - Quality scoring for training data
#
# Usage:
#   source "$COMMIT_RELAY_HOME/scripts/lib/reasoning-validator.sh"
#   result=$(validate_reasoning_trace "$trace_json")
#   quality=$(score_reasoning_quality "$trace_json")

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# Validator configuration
VALIDATOR_CONFIG="${COMMIT_RELAY_HOME}/coordination/config/reasoning-validator.json"
VALIDATION_HISTORY="${COMMIT_RELAY_HOME}/coordination/metrics/reasoning-validation-history.jsonl"
TRAINING_DATA="${COMMIT_RELAY_HOME}/coordination/knowledge-base/training-data/validated-traces.jsonl"

# Create directories
mkdir -p "$(dirname "$VALIDATOR_CONFIG")"
mkdir -p "$(dirname "$VALIDATION_HISTORY")"
mkdir -p "$(dirname "$TRAINING_DATA")"

# ============================================================================
# Logging
# ============================================================================

log_validator() {
    local level="$1"
    shift
    echo "[$(date +%Y-%m-%dT%H:%M:%S%z)] [REASONING] [$level] $*" >&2
}

# ============================================================================
# Initialize Configuration
# ============================================================================

initialize_validator_config() {
    if [ ! -f "$VALIDATOR_CONFIG" ]; then
        cat > "$VALIDATOR_CONFIG" <<'EOF'
{
  "version": "1.0.0",
  "quality_thresholds": {
    "min_score_for_training": 70,
    "excellent": 90,
    "good": 70,
    "acceptable": 50,
    "poor": 30
  },
  "validation_checks": {
    "step_coherence": {
      "enabled": true,
      "weight": 0.25,
      "min_steps": 2,
      "max_steps": 20
    },
    "logical_consistency": {
      "enabled": true,
      "weight": 0.30
    },
    "evidence_support": {
      "enabled": true,
      "weight": 0.20
    },
    "conclusion_validity": {
      "enabled": true,
      "weight": 0.15
    },
    "format_quality": {
      "enabled": true,
      "weight": 0.10
    }
  },
  "logical_fallacies": [
    "circular_reasoning",
    "false_dichotomy",
    "hasty_generalization",
    "appeal_to_authority",
    "non_sequitur",
    "straw_man",
    "ad_hominem",
    "slippery_slope"
  ],
  "quality_indicators": {
    "positive": [
      "therefore", "because", "evidence", "data shows", "based on",
      "consequently", "as a result", "this indicates", "specifically",
      "for example", "in conclusion", "to summarize"
    ],
    "negative": [
      "obviously", "clearly", "everyone knows", "always", "never",
      "definitely", "impossible", "must be", "no other way",
      "i think", "i feel", "probably", "maybe"
    ]
  },
  "required_elements": {
    "problem_statement": true,
    "reasoning_steps": true,
    "conclusion": true,
    "evidence": false
  }
}
EOF
        log_validator "INFO" "Created default validator config"
    fi
}

initialize_validator_config

# ============================================================================
# Validation Checks
# ============================================================================

# Check step coherence
check_step_coherence() {
    local trace_json="$1"

    local score=100
    local issues=()

    # Get steps
    local steps=$(echo "$trace_json" | jq -r '.reasoning_steps // .steps // []')
    local step_count=$(echo "$steps" | jq 'length')

    local min_steps=$(jq -r '.validation_checks.step_coherence.min_steps' "$VALIDATOR_CONFIG")
    local max_steps=$(jq -r '.validation_checks.step_coherence.max_steps' "$VALIDATOR_CONFIG")

    # Check step count
    if [ "$step_count" -lt "$min_steps" ]; then
        score=$((score - 30))
        issues+=("Too few reasoning steps: $step_count < $min_steps")
    elif [ "$step_count" -gt "$max_steps" ]; then
        score=$((score - 20))
        issues+=("Too many steps: $step_count > $max_steps")
    fi

    # Check for empty steps
    local empty_steps=$(echo "$steps" | jq '[.[] | select(length == 0 or . == "")] | length')
    if [ "$empty_steps" -gt 0 ]; then
        score=$((score - 15 * empty_steps))
        issues+=("$empty_steps empty steps found")
    fi

    # Check step progression (each step should build on previous)
    # Simplified: check for connecting words
    local connected=0
    for ((i=1; i<step_count; i++)); do
        local step=$(echo "$steps" | jq -r ".[$i]" | tr '[:upper:]' '[:lower:]')
        if echo "$step" | grep -qE "^(therefore|thus|so|hence|because|since|as|this|that|the|it|which)"; then
            ((connected++))
        fi
    done

    if [ "$step_count" -gt 1 ]; then
        local connection_rate=$(echo "scale=2; $connected / ($step_count - 1) * 100" | bc)
        if (( $(echo "$connection_rate < 50" | bc -l) )); then
            score=$((score - 15))
            issues+=("Low step connection rate: ${connection_rate}%")
        fi
    fi

    # Ensure non-negative
    if [ "$score" -lt 0 ]; then
        score=0
    fi

    local issues_json=$(printf '%s\n' "${issues[@]}" 2>/dev/null | jq -R -s 'split("\n") | map(select(length > 0))' || echo '[]')

    jq -nc \
        --argjson score "$score" \
        --argjson issues "$issues_json" \
        '{score: $score, issues: $issues}'
}

# Check logical consistency
check_logical_consistency() {
    local trace_json="$1"

    local score=100
    local issues=()

    local content=$(echo "$trace_json" | jq -r '
        (.problem_statement // "") + " " +
        ((.reasoning_steps // .steps // []) | join(" ")) + " " +
        (.conclusion // "")
    ' | tr '[:upper:]' '[:lower:]')

    # Check for contradictions (simplified heuristic)
    local contradiction_pairs=(
        "increase|decrease"
        "always|never"
        "all|none"
        "must|cannot"
        "true|false"
        "yes|no"
        "enable|disable"
    )

    for pair in "${contradiction_pairs[@]}"; do
        local word1=$(echo "$pair" | cut -d'|' -f1)
        local word2=$(echo "$pair" | cut -d'|' -f2)

        if echo "$content" | grep -q "$word1" && echo "$content" | grep -q "$word2"; then
            # Check if they're in same context (within 50 chars)
            if echo "$content" | grep -qE "${word1}.{0,50}${word2}|${word2}.{0,50}${word1}"; then
                score=$((score - 20))
                issues+=("Potential contradiction: $word1 vs $word2")
            fi
        fi
    done

    # Check for circular reasoning
    local problem=$(echo "$trace_json" | jq -r '.problem_statement // ""' | tr '[:upper:]' '[:lower:]')
    local conclusion=$(echo "$trace_json" | jq -r '.conclusion // ""' | tr '[:upper:]' '[:lower:]')

    if [ -n "$problem" ] && [ -n "$conclusion" ]; then
        # Calculate simple similarity
        local common_words=0
        for word in $problem; do
            if [ ${#word} -gt 4 ] && echo "$conclusion" | grep -qi "$word"; then
                ((common_words++))
            fi
        done

        local problem_words=$(echo "$problem" | wc -w | tr -d ' ')
        if [ "$problem_words" -gt 0 ]; then
            local overlap=$(echo "scale=2; $common_words / $problem_words * 100" | bc)
            if (( $(echo "$overlap > 80" | bc -l) )); then
                score=$((score - 25))
                issues+=("High overlap between problem and conclusion: ${overlap}% (possible circular reasoning)")
            fi
        fi
    fi

    # Ensure non-negative
    if [ "$score" -lt 0 ]; then
        score=0
    fi

    local issues_json=$(printf '%s\n' "${issues[@]}" 2>/dev/null | jq -R -s 'split("\n") | map(select(length > 0))' || echo '[]')

    jq -nc \
        --argjson score "$score" \
        --argjson issues "$issues_json" \
        '{score: $score, issues: $issues}'
}

# Check evidence support
check_evidence_support() {
    local trace_json="$1"

    local score=100
    local issues=()

    local content=$(echo "$trace_json" | jq -r '
        ((.reasoning_steps // .steps // []) | join(" ")) + " " +
        (.evidence // "")
    ' | tr '[:upper:]' '[:lower:]')

    # Check for evidence indicators
    local positive_keywords=$(jq -r '.quality_indicators.positive[]' "$VALIDATOR_CONFIG")
    local evidence_count=0

    while IFS= read -r keyword; do
        if echo "$content" | grep -qi "$keyword"; then
            ((evidence_count++))
        fi
    done <<< "$positive_keywords"

    if [ "$evidence_count" -lt 2 ]; then
        score=$((score - 30))
        issues+=("Insufficient evidence indicators: $evidence_count")
    elif [ "$evidence_count" -lt 4 ]; then
        score=$((score - 15))
        issues+=("Limited evidence indicators: $evidence_count")
    fi

    # Check for weak language
    local negative_keywords=$(jq -r '.quality_indicators.negative[]' "$VALIDATOR_CONFIG")
    local weak_count=0

    while IFS= read -r keyword; do
        if echo "$content" | grep -qi "$keyword"; then
            ((weak_count++))
        fi
    done <<< "$negative_keywords"

    if [ "$weak_count" -gt 3 ]; then
        score=$((score - 20))
        issues+=("Multiple weak/vague indicators: $weak_count")
    elif [ "$weak_count" -gt 1 ]; then
        score=$((score - 10))
        issues+=("Some weak language: $weak_count indicators")
    fi

    # Ensure non-negative
    if [ "$score" -lt 0 ]; then
        score=0
    fi

    local issues_json=$(printf '%s\n' "${issues[@]}" 2>/dev/null | jq -R -s 'split("\n") | map(select(length > 0))' || echo '[]')

    jq -nc \
        --argjson score "$score" \
        --argjson issues "$issues_json" \
        '{score: $score, issues: $issues}'
}

# Check conclusion validity
check_conclusion_validity() {
    local trace_json="$1"

    local score=100
    local issues=()

    local conclusion=$(echo "$trace_json" | jq -r '.conclusion // ""')

    if [ -z "$conclusion" ]; then
        score=0
        issues+=("No conclusion provided")
    else
        local word_count=$(echo "$conclusion" | wc -w | tr -d ' ')

        # Conclusion should be substantial
        if [ "$word_count" -lt 5 ]; then
            score=$((score - 40))
            issues+=("Conclusion too short: $word_count words")
        elif [ "$word_count" -lt 10 ]; then
            score=$((score - 20))
            issues+=("Conclusion could be more detailed: $word_count words")
        fi

        # Check for actionable/clear conclusion
        local conclusion_lower=$(echo "$conclusion" | tr '[:upper:]' '[:lower:]')
        if ! echo "$conclusion_lower" | grep -qE "(should|recommend|conclude|result|therefore|implement|use|apply)"; then
            score=$((score - 15))
            issues+=("Conclusion lacks clear action or recommendation")
        fi
    fi

    # Ensure non-negative
    if [ "$score" -lt 0 ]; then
        score=0
    fi

    local issues_json=$(printf '%s\n' "${issues[@]}" 2>/dev/null | jq -R -s 'split("\n") | map(select(length > 0))' || echo '[]')

    jq -nc \
        --argjson score "$score" \
        --argjson issues "$issues_json" \
        '{score: $score, issues: $issues}'
}

# Check format quality
check_format_quality() {
    local trace_json="$1"

    local score=100
    local issues=()

    # Check required elements
    local has_problem=$(echo "$trace_json" | jq 'has("problem_statement")')
    local has_steps=$(echo "$trace_json" | jq 'has("reasoning_steps") or has("steps")')
    local has_conclusion=$(echo "$trace_json" | jq 'has("conclusion")')

    local required_problem=$(jq -r '.required_elements.problem_statement' "$VALIDATOR_CONFIG")
    local required_steps=$(jq -r '.required_elements.reasoning_steps' "$VALIDATOR_CONFIG")
    local required_conclusion=$(jq -r '.required_elements.conclusion' "$VALIDATOR_CONFIG")

    if [ "$required_problem" = "true" ] && [ "$has_problem" = "false" ]; then
        score=$((score - 30))
        issues+=("Missing required element: problem_statement")
    fi

    if [ "$required_steps" = "true" ] && [ "$has_steps" = "false" ]; then
        score=$((score - 30))
        issues+=("Missing required element: reasoning_steps")
    fi

    if [ "$required_conclusion" = "true" ] && [ "$has_conclusion" = "false" ]; then
        score=$((score - 30))
        issues+=("Missing required element: conclusion")
    fi

    # Ensure non-negative
    if [ "$score" -lt 0 ]; then
        score=0
    fi

    local issues_json=$(printf '%s\n' "${issues[@]}" 2>/dev/null | jq -R -s 'split("\n") | map(select(length > 0))' || echo '[]')

    jq -nc \
        --argjson score "$score" \
        --argjson issues "$issues_json" \
        '{score: $score, issues: $issues}'
}

# ============================================================================
# Main Validation Function
# ============================================================================

# Validate reasoning trace
validate_reasoning_trace() {
    local trace_json="$1"
    local trace_id="${2:-$(date +%s)}"

    log_validator "INFO" "Validating reasoning trace: $trace_id"

    # Validate JSON
    if ! echo "$trace_json" | jq empty 2>/dev/null; then
        log_validator "ERROR" "Invalid JSON in trace"
        echo '{"valid":false,"error":"Invalid JSON"}'
        return 1
    fi

    # Run all checks
    local coherence_result=$(check_step_coherence "$trace_json")
    local consistency_result=$(check_logical_consistency "$trace_json")
    local evidence_result=$(check_evidence_support "$trace_json")
    local conclusion_result=$(check_conclusion_validity "$trace_json")
    local format_result=$(check_format_quality "$trace_json")

    # Get scores
    local coherence_score=$(echo "$coherence_result" | jq -r '.score')
    local consistency_score=$(echo "$consistency_result" | jq -r '.score')
    local evidence_score=$(echo "$evidence_result" | jq -r '.score')
    local conclusion_score=$(echo "$conclusion_result" | jq -r '.score')
    local format_score=$(echo "$format_result" | jq -r '.score')

    # Get weights
    local coherence_weight=$(jq -r '.validation_checks.step_coherence.weight' "$VALIDATOR_CONFIG")
    local consistency_weight=$(jq -r '.validation_checks.logical_consistency.weight' "$VALIDATOR_CONFIG")
    local evidence_weight=$(jq -r '.validation_checks.evidence_support.weight' "$VALIDATOR_CONFIG")
    local conclusion_weight=$(jq -r '.validation_checks.conclusion_validity.weight' "$VALIDATOR_CONFIG")
    local format_weight=$(jq -r '.validation_checks.format_quality.weight' "$VALIDATOR_CONFIG")

    # Calculate weighted total
    local total_score=$(echo "scale=2; \
        $coherence_score * $coherence_weight + \
        $consistency_score * $consistency_weight + \
        $evidence_score * $evidence_weight + \
        $conclusion_score * $conclusion_weight + \
        $format_score * $format_weight" | bc)

    local total_int=${total_score%.*}

    # Determine quality level
    local quality_level="poor"
    local excellent=$(jq -r '.quality_thresholds.excellent' "$VALIDATOR_CONFIG")
    local good=$(jq -r '.quality_thresholds.good' "$VALIDATOR_CONFIG")
    local acceptable=$(jq -r '.quality_thresholds.acceptable' "$VALIDATOR_CONFIG")

    if [ "$total_int" -ge "$excellent" ]; then
        quality_level="excellent"
    elif [ "$total_int" -ge "$good" ]; then
        quality_level="good"
    elif [ "$total_int" -ge "$acceptable" ]; then
        quality_level="acceptable"
    fi

    # Check if valid for training
    local min_training=$(jq -r '.quality_thresholds.min_score_for_training' "$VALIDATOR_CONFIG")
    local valid_for_training="false"
    if [ "$total_int" -ge "$min_training" ]; then
        valid_for_training="true"
    fi

    # Collect all issues
    local all_issues=$(jq -nc \
        --argjson c "$(echo "$coherence_result" | jq '.issues')" \
        --argjson l "$(echo "$consistency_result" | jq '.issues')" \
        --argjson e "$(echo "$evidence_result" | jq '.issues')" \
        --argjson o "$(echo "$conclusion_result" | jq '.issues')" \
        --argjson f "$(echo "$format_result" | jq '.issues')" \
        '$c + $l + $e + $o + $f')

    # Build result
    local result=$(jq -nc \
        --arg trace_id "$trace_id" \
        --argjson total_score "$total_int" \
        --arg quality_level "$quality_level" \
        --arg valid_for_training "$valid_for_training" \
        --argjson coherence "$coherence_score" \
        --argjson consistency "$consistency_score" \
        --argjson evidence "$evidence_score" \
        --argjson conclusion "$conclusion_score" \
        --argjson format "$format_score" \
        --argjson issues "$all_issues" \
        --arg validated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            trace_id: $trace_id,
            total_score: $total_score,
            quality_level: $quality_level,
            valid_for_training: ($valid_for_training == "true"),
            component_scores: {
                step_coherence: $coherence,
                logical_consistency: $consistency,
                evidence_support: $evidence,
                conclusion_validity: $conclusion,
                format_quality: $format
            },
            issues: $issues,
            validated_at: $validated_at
        }')

    # Record to history
    echo "$result" >> "$VALIDATION_HISTORY"

    log_validator "INFO" "Validation complete: score=$total_int, quality=$quality_level, training=$valid_for_training"

    echo "$result"
}

# Score reasoning quality (simplified API)
score_reasoning_quality() {
    local trace_json="$1"

    local result=$(validate_reasoning_trace "$trace_json")
    echo "$result" | jq -r '.total_score'
}

# ============================================================================
# Training Data Management
# ============================================================================

# Add trace to training set if valid
add_to_training_set() {
    local trace_json="$1"
    local trace_id="${2:-$(date +%s)}"

    local validation=$(validate_reasoning_trace "$trace_json" "$trace_id")
    local valid=$(echo "$validation" | jq -r '.valid_for_training')

    if [ "$valid" = "true" ]; then
        # Add trace with validation metadata
        local training_entry=$(jq -nc \
            --argjson trace "$trace_json" \
            --argjson validation "$validation" \
            '{
                trace: $trace,
                validation: $validation
            }')

        echo "$training_entry" >> "$TRAINING_DATA"
        log_validator "INFO" "Added trace to training set: $trace_id"
        return 0
    else
        log_validator "WARN" "Trace rejected for training: $trace_id"
        return 1
    fi
}

# Get training data metrics
get_training_metrics() {
    if [ ! -f "$TRAINING_DATA" ]; then
        echo '{"total_traces":0}'
        return
    fi

    local total=$(wc -l < "$TRAINING_DATA" | tr -d ' ')
    local avg_score=$(jq -s '[.[].validation.total_score] | add / length | floor' "$TRAINING_DATA" 2>/dev/null || echo "0")

    jq -nc \
        --argjson total "$total" \
        --argjson avg_score "$avg_score" \
        '{
            total_traces: $total,
            average_score: $avg_score
        }'
}

# Export functions
export -f validate_reasoning_trace 2>/dev/null || true
export -f score_reasoning_quality 2>/dev/null || true
export -f add_to_training_set 2>/dev/null || true
export -f get_training_metrics 2>/dev/null || true
export -f check_step_coherence 2>/dev/null || true
export -f check_logical_consistency 2>/dev/null || true

log_validator "INFO" "Reasoning validator library loaded"
