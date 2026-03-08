#!/bin/bash
# MoE-Inspired Router for Commit-Relay
# Implements Mixture of Experts routing logic with confidence scoring

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KB_DIR="$SCRIPT_DIR/../knowledge-base"
ROUTING_PATTERNS="$KB_DIR/routing-patterns.json"
ROUTING_LOG="$KB_DIR/routing-decisions.jsonl"
ROUTING_LOG_BACKUP="$SCRIPT_DIR/../logs/routing-decisions.jsonl"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/../../../.." && pwd)}"

# Model selection configuration
MODEL_TIERS_CONFIG="$COMMIT_RELAY_HOME/llm-mesh/gateway/router/model-tiers.json"
MODEL_SELECTION_LOG="$COMMIT_RELAY_HOME/coordination/metrics/model-selection.jsonl"

# Learned patterns for adaptive routing (Phase 2 Enhancement #16)
LEARNED_PATTERNS="$COMMIT_RELAY_HOME/coordination/knowledge-base/learned-patterns/patterns-latest.json"
LEARNED_WEIGHTS_ENABLED="${LEARNED_WEIGHTS_ENABLED:-true}"

# Phase 3 Enhancement #16: Model versions directory for utility weights
MODEL_VERSIONS_DIR="$COMMIT_RELAY_HOME/coordination/knowledge-base/model-versions"
UTILITY_WEIGHTS_ENABLED="${UTILITY_WEIGHTS_ENABLED:-true}"

# Governance bypass mode (for bootstrapping governance system itself)
GOVERNANCE_BYPASS="${GOVERNANCE_BYPASS:-false}"

# Phase 5.2 Enhancement: Semantic routing with embeddings (94.5% coverage vs 87.5% keywords)
SEMANTIC_ROUTING_ENABLED="${SEMANTIC_ROUTING_ENABLED:-true}"
SEMANTIC_CONFIDENCE_THRESHOLD="${SEMANTIC_CONFIDENCE_THRESHOLD:-0.6}"
SEMANTIC_ROUTER_CLI="$COMMIT_RELAY_HOME/lib/routing/semantic-router-cli.js"

# Load access control (skip if in bypass mode or file doesn't exist)
if [ "$GOVERNANCE_BYPASS" != "true" ] && [ -f "$COMMIT_RELAY_HOME/scripts/lib/access-check.sh" ]; then
    source "$COMMIT_RELAY_HOME/scripts/lib/access-check.sh"
else
    # Stub function for bypass mode or when access-check doesn't exist
    check_permission() {
        return 0  # Always allow in bypass mode
    }
fi

# Ensure log directory exists
mkdir -p "$(dirname "$ROUTING_LOG")"

# Load thresholds from patterns file
SINGLE_EXPERT_THRESHOLD=$(jq -r '.thresholds.single_expert' "$ROUTING_PATTERNS")
MULTI_EXPERT_THRESHOLD=$(jq -r '.thresholds.multi_expert' "$ROUTING_PATTERNS")
MINIMUM_ACTIVATION=$(jq -r '.thresholds.minimum_activation' "$ROUTING_PATTERNS")

##############################################################################
# load_learned_weights: Load learned keyword weights from patterns
# Enhancement #16: MoE routing with learned preferences
# Returns: Sets global LEARNED_KEYWORD_WEIGHTS associative array
##############################################################################
declare -A LEARNED_KEYWORD_WEIGHTS
declare -A LEARNED_EXPERT_PREFERENCES
declare -A UTILITY_WEIGHTS

##############################################################################
# load_utility_weights: Load utility weights from model versions
# Phase 3 Enhancement #16: Load versioned utility weights for expert scoring
# Returns: Sets global UTILITY_WEIGHTS associative array
##############################################################################
load_utility_weights() {
    UTILITY_WEIGHTS=()

    if [ "$UTILITY_WEIGHTS_ENABLED" != "true" ]; then
        return 0
    fi

    # Find the latest utility weights file
    local latest_weights=""
    if [ -d "$MODEL_VERSIONS_DIR" ]; then
        latest_weights=$(ls -t "$MODEL_VERSIONS_DIR"/utility-weights-*.json 2>/dev/null | head -1)
    fi

    if [ -z "$latest_weights" ] || [ ! -f "$latest_weights" ]; then
        return 0
    fi

    # Load expert utility weights
    local expert_weights
    expert_weights=$(jq -r '.expert_weights // {}' "$latest_weights" 2>/dev/null)

    if [ -n "$expert_weights" ] && [ "$expert_weights" != "{}" ]; then
        # Parse expert weights: {"development": 1.2, "security": 1.1, "inventory": 1.0}
        while IFS='=' read -r expert weight; do
            if [ -n "$expert" ] && [ -n "$weight" ]; then
                UTILITY_WEIGHTS["$expert"]="$weight"
            fi
        done < <(echo "$expert_weights" | jq -r 'to_entries[] | "\(.key)=\(.value)"' 2>/dev/null)
    fi

    # Load keyword utility weights for scoring adjustments
    local keyword_weights
    keyword_weights=$(jq -r '.keyword_weights // {}' "$latest_weights" 2>/dev/null)

    if [ -n "$keyword_weights" ] && [ "$keyword_weights" != "{}" ]; then
        while IFS='=' read -r keyword weight; do
            if [ -n "$keyword" ] && [ -n "$weight" ]; then
                UTILITY_WEIGHTS["kw_$keyword"]="$weight"
            fi
        done < <(echo "$keyword_weights" | jq -r 'to_entries[] | "\(.key)=\(.value)"' 2>/dev/null)
    fi

    # Load confidence calibration factors
    local calibration
    calibration=$(jq -r '.confidence_calibration // {}' "$latest_weights" 2>/dev/null)

    if [ -n "$calibration" ] && [ "$calibration" != "{}" ]; then
        while IFS='=' read -r expert factor; do
            if [ -n "$expert" ] && [ -n "$factor" ]; then
                UTILITY_WEIGHTS["cal_$expert"]="$factor"
            fi
        done < <(echo "$calibration" | jq -r 'to_entries[] | "\(.key)=\(.value)"' 2>/dev/null)
    fi
}

##############################################################################
# apply_utility_weights: Apply utility weights to expert score
# Phase 3 Enhancement #16: Adjust scores based on learned utility weights
# Args:
#   $1: expert_name
#   $2: base_score
#   $3: task_description
# Returns: Adjusted score with utility weights applied
##############################################################################
apply_utility_weights() {
    local expert="$1"
    local base_score="$2"
    local task_description="$3"

    if [ "$UTILITY_WEIGHTS_ENABLED" != "true" ]; then
        echo "$base_score"
        return
    fi

    local adjusted_score=$base_score
    local task_lower=$(echo "$task_description" | tr '[:upper:]' '[:lower:]')

    # Apply expert-level utility weight (multiplicative)
    local expert_weight="${UTILITY_WEIGHTS[$expert]:-1.0}"
    if [ "$expert_weight" != "1.0" ]; then
        adjusted_score=$(echo "scale=0; $adjusted_score * $expert_weight" | bc 2>/dev/null || echo "$adjusted_score")
    fi

    # Apply keyword-specific utility weights
    local keyword_adjustment=0
    for word in $task_lower; do
        local kw_weight="${UTILITY_WEIGHTS[kw_$word]:-0}"
        if [ "$kw_weight" != "0" ]; then
            keyword_adjustment=$(echo "scale=2; $keyword_adjustment + $kw_weight" | bc 2>/dev/null || echo "0")
        fi
    done

    # Apply keyword adjustment (capped at +/- 10)
    if [ "$(echo "$keyword_adjustment > 10" | bc -l 2>/dev/null || echo 0)" -eq 1 ]; then
        keyword_adjustment=10
    elif [ "$(echo "$keyword_adjustment < -10" | bc -l 2>/dev/null || echo 0)" -eq 1 ]; then
        keyword_adjustment=-10
    fi
    adjusted_score=$(echo "scale=0; $adjusted_score + $keyword_adjustment" | bc 2>/dev/null || echo "$adjusted_score")

    # Apply confidence calibration factor
    local cal_factor="${UTILITY_WEIGHTS[cal_$expert]:-1.0}"
    if [ "$cal_factor" != "1.0" ]; then
        adjusted_score=$(echo "scale=0; $adjusted_score * $cal_factor" | bc 2>/dev/null || echo "$adjusted_score")
    fi

    # Clamp to 0-100
    adjusted_score=$(printf "%.0f" "$adjusted_score" 2>/dev/null || echo "$adjusted_score")
    if [ "$adjusted_score" -lt 0 ] 2>/dev/null; then
        adjusted_score=0
    fi
    if [ "$adjusted_score" -gt 100 ] 2>/dev/null; then
        adjusted_score=100
    fi

    echo "$adjusted_score"
}

load_learned_weights() {
    # Initialize empty arrays
    LEARNED_KEYWORD_WEIGHTS=()
    LEARNED_EXPERT_PREFERENCES=()

    # Check if learned patterns exist
    if [ ! -f "$LEARNED_PATTERNS" ]; then
        return 0
    fi

    # Load routing patterns with preferred worker types
    local routing_count=$(jq -r '.routing_patterns | length' "$LEARNED_PATTERNS" 2>/dev/null || echo "0")

    if [ "$routing_count" -gt 0 ]; then
        # Extract worker type preferences and scores
        while IFS='|' read -r worker_type count avg_score; do
            if [ -n "$worker_type" ] && [ "$worker_type" != "null" ]; then
                # Map worker types to experts
                local expert=""
                case "$worker_type" in
                    feature-implementer|bug-fixer|refactorer|optimizer)
                        expert="development"
                        ;;
                    security-scanner|vulnerability-fixer)
                        expert="security"
                        ;;
                    cataloger|documenter)
                        expert="inventory"
                        ;;
                    builder|deployer|tester)
                        expert="cicd"
                        ;;
                esac

                if [ -n "$expert" ]; then
                    # Store preference with weight based on success rate
                    local weight=$(echo "scale=2; $avg_score / 100 * $count" | bc 2>/dev/null || echo "1")
                    LEARNED_EXPERT_PREFERENCES["$expert"]="${LEARNED_EXPERT_PREFERENCES[$expert]:-0}"
                    LEARNED_EXPERT_PREFERENCES["$expert"]=$(echo "${LEARNED_EXPERT_PREFERENCES[$expert]} + $weight" | bc 2>/dev/null || echo "$weight")
                fi
            fi
        done < <(jq -r '.routing_patterns[] | "\(.preferred_worker_type)|\(.count)|\(.avg_score)"' "$LEARNED_PATTERNS" 2>/dev/null)
    fi

    # Load successful patterns for keyword weighting
    local success_count=$(jq -r '.successful_patterns | length' "$LEARNED_PATTERNS" 2>/dev/null || echo "0")

    if [ "$success_count" -gt 0 ]; then
        # Extract keywords from successful patterns
        while IFS='|' read -r pattern_id keywords; do
            if [ -n "$keywords" ] && [ "$keywords" != "null" ]; then
                for kw in $keywords; do
                    kw_lower=$(echo "$kw" | tr '[:upper:]' '[:lower:]')
                    LEARNED_KEYWORD_WEIGHTS["$kw_lower"]="${LEARNED_KEYWORD_WEIGHTS[$kw_lower]:-0}"
                    LEARNED_KEYWORD_WEIGHTS["$kw_lower"]=$((${LEARNED_KEYWORD_WEIGHTS[$kw_lower]} + 5))
                done
            fi
        done < <(jq -r '.successful_patterns[]? | "\(.pattern_id)|\(.keywords // [] | join(" "))"' "$LEARNED_PATTERNS" 2>/dev/null)
    fi

    # Load failed patterns as negative weights
    local fail_count=$(jq -r '.failed_patterns | length' "$LEARNED_PATTERNS" 2>/dev/null || echo "0")

    if [ "$fail_count" -gt 0 ]; then
        while IFS='|' read -r pattern_id keywords; do
            if [ -n "$keywords" ] && [ "$keywords" != "null" ]; then
                for kw in $keywords; do
                    kw_lower=$(echo "$kw" | tr '[:upper:]' '[:lower:]')
                    LEARNED_KEYWORD_WEIGHTS["$kw_lower"]="${LEARNED_KEYWORD_WEIGHTS[$kw_lower]:-0}"
                    LEARNED_KEYWORD_WEIGHTS["$kw_lower"]=$((${LEARNED_KEYWORD_WEIGHTS[$kw_lower]} - 3))
                done
            fi
        done < <(jq -r '.failed_patterns[]? | "\(.pattern_id)|\(.keywords // [] | join(" "))"' "$LEARNED_PATTERNS" 2>/dev/null)
    fi
}

##############################################################################
# apply_learned_boost: Apply learned weights to expert score
# Args:
#   $1: expert_name
#   $2: base_score
#   $3: task_description
# Returns: Adjusted score
##############################################################################
apply_learned_boost() {
    local expert="$1"
    local base_score="$2"
    local task_description="$3"

    # If learning is disabled, return base score
    if [ "$LEARNED_WEIGHTS_ENABLED" != "true" ]; then
        echo "$base_score"
        return
    fi

    local adjusted_score=$base_score
    local task_lower=$(echo "$task_description" | tr '[:upper:]' '[:lower:]')

    # Apply expert preference boost
    local expert_pref="${LEARNED_EXPERT_PREFERENCES[$expert]:-0}"
    if [ "$expert_pref" != "0" ]; then
        # Add preference boost (capped at 10 points)
        local pref_boost=$(echo "scale=0; $expert_pref * 2" | bc 2>/dev/null || echo "0")
        if [ "$pref_boost" -gt 10 ]; then
            pref_boost=10
        fi
        adjusted_score=$((adjusted_score + pref_boost))
    fi

    # Apply keyword-specific boosts from learned patterns
    local keyword_boost=0
    for word in $task_lower; do
        local weight="${LEARNED_KEYWORD_WEIGHTS[$word]:-0}"
        if [ "$weight" != "0" ]; then
            keyword_boost=$((keyword_boost + weight))
        fi
    done

    # Cap keyword boost at +/-15 points
    if [ $keyword_boost -gt 15 ]; then
        keyword_boost=15
    elif [ $keyword_boost -lt -15 ]; then
        keyword_boost=-15
    fi

    adjusted_score=$((adjusted_score + keyword_boost))

    # Clamp to 0-100
    if [ $adjusted_score -lt 0 ]; then
        adjusted_score=0
    fi
    if [ $adjusted_score -gt 100 ]; then
        adjusted_score=100
    fi

    echo $adjusted_score
}

# Load learned weights and utility weights at startup
load_learned_weights
load_utility_weights

##############################################################################
# get_model_recommendation: Get LLM model recommendation based on task
# Args:
#   $1: task_description
#   $2: complexity_score (optional, 1-10)
#   $3: sensitivity_level (optional, none|low|medium|high)
# Returns: JSON with model recommendation
##############################################################################
get_model_recommendation() {
    local task_description="$1"
    local complexity_score="${2:-5}"
    local sensitivity_level="${3:-none}"

    # Determine tier based on complexity
    local tier="balanced"
    if [ "$complexity_score" -ge 8 ]; then
        tier="powerful"
    elif [ "$complexity_score" -le 4 ]; then
        tier="fast"
    fi

    # Override for high sensitivity
    if [ "$sensitivity_level" = "high" ]; then
        tier="local"
    elif [ "$sensitivity_level" = "medium" ] && [ "$tier" = "fast" ]; then
        tier="balanced"
    fi

    # Get recommended model from tier
    local model=""
    local provider=""

    if [ -f "$MODEL_TIERS_CONFIG" ]; then
        model=$(jq -r ".tiers.${tier}.models[0].id // \"\"" "$MODEL_TIERS_CONFIG" 2>/dev/null)
        provider=$(jq -r ".tiers.${tier}.models[0].provider // \"\"" "$MODEL_TIERS_CONFIG" 2>/dev/null)
    fi

    # Fallback defaults
    if [ -z "$model" ]; then
        case "$tier" in
            fast)
                model="claude-haiku"
                provider="anthropic"
                ;;
            balanced)
                model="claude-sonnet-4"
                provider="anthropic"
                ;;
            powerful)
                model="claude-opus-4"
                provider="anthropic"
                ;;
            local)
                model="llama2-70b"
                provider="ollama"
                ;;
        esac
    fi

    # Generate reasoning
    local reasoning="Selected ${model} from ${tier} tier"
    if [ "$sensitivity_level" = "high" ]; then
        reasoning="${reasoning} (forced local for high sensitivity)"
    elif [ "$complexity_score" -ge 8 ]; then
        reasoning="${reasoning} (high complexity score: ${complexity_score})"
    elif [ "$complexity_score" -le 4 ]; then
        reasoning="${reasoning} (low complexity score: ${complexity_score})"
    fi

    jq -n \
        --arg model "$model" \
        --arg provider "$provider" \
        --arg tier "$tier" \
        --argjson complexity "$complexity_score" \
        --arg sensitivity "$sensitivity_level" \
        --arg reasoning "$reasoning" \
        '{
            model: $model,
            provider: $provider,
            tier: $tier,
            complexity_score: $complexity,
            sensitivity_level: $sensitivity,
            reasoning: $reasoning
        }'
}

##############################################################################
# score_task_complexity: Score task complexity for model selection
# Args:
#   $1: task_description
# Returns: complexity score (1-10)
##############################################################################
score_task_complexity() {
    local task_description="$1"
    local task_lower=$(echo "$task_description" | tr '[:upper:]' '[:lower:]')

    local score=5  # Base score

    # High complexity indicators
    local high_keywords="security vulnerability exploit cve audit architecture performance optimization distributed migration refactor compliance encryption"
    for kw in $high_keywords; do
        if echo "$task_lower" | grep -qi "$kw"; then
            score=$((score + 1))
        fi
    done

    # Low complexity indicators
    local low_keywords="simple basic quick minor typo format style comment"
    for kw in $low_keywords; do
        if echo "$task_lower" | grep -qi "$kw"; then
            score=$((score - 1))
        fi
    done

    # Clamp to 1-10
    if [ $score -lt 1 ]; then
        score=1
    fi
    if [ $score -gt 10 ]; then
        score=10
    fi

    echo $score
}

##############################################################################
# detect_task_sensitivity: Detect sensitivity level of task
# Args:
#   $1: task_description
# Returns: sensitivity level (none|low|medium|high)
##############################################################################
detect_task_sensitivity() {
    local task_description="$1"
    local task_lower=$(echo "$task_description" | tr '[:upper:]' '[:lower:]')

    local level="none"

    # High sensitivity patterns
    if echo "$task_lower" | grep -qiE "password|credential|secret|private.key|api.key|token|ssn|credit.card"; then
        level="high"
    # Medium sensitivity patterns
    elif echo "$task_lower" | grep -qiE "internal|staging|user.data|customer|employee"; then
        level="medium"
    # Low sensitivity patterns
    elif echo "$task_lower" | grep -qiE "email|phone|address|config"; then
        level="low"
    fi

    echo "$level"
}

##############################################################################
# log_model_selection: Log model selection decision
# Args:
#   $1: task_id
#   $2: model
#   $3: provider
#   $4: tier
#   $5: complexity_score
#   $6: sensitivity_level
#   $7: reasoning
##############################################################################
log_model_selection() {
    local task_id="$1"
    local model="$2"
    local provider="$3"
    local tier="$4"
    local complexity_score="$5"
    local sensitivity_level="$6"
    local reasoning="$7"
    local timestamp=$(date +"%Y-%m-%dT%H:%M:%S%z")

    mkdir -p "$(dirname "$MODEL_SELECTION_LOG")"

    local log_entry=$(jq -n \
        --arg timestamp "$timestamp" \
        --arg task_id "$task_id" \
        --arg model "$model" \
        --arg provider "$provider" \
        --arg tier "$tier" \
        --argjson complexity "$complexity_score" \
        --arg sensitivity "$sensitivity_level" \
        --arg reasoning "$reasoning" \
        '{
            timestamp: $timestamp,
            task_id: $task_id,
            model: $model,
            provider: $provider,
            tier: $tier,
            complexity_score: $complexity,
            sensitivity_level: $sensitivity,
            reasoning: $reasoning
        }')

    echo "$log_entry" >> "$MODEL_SELECTION_LOG"
}

##############################################################################
# calculate_expert_score: Score a task description against an expert's patterns
# Args:
#   $1: task_description
#   $2: expert_name (development|security|inventory)
# Returns: confidence score (0-100)
##############################################################################
calculate_expert_score() {
    local task_description="$1"
    local expert="$2"

    # Convert to lowercase for matching
    local task_lower=$(echo "$task_description" | tr '[:upper:]' '[:lower:]')

    # Initialize scores
    local keyword_score=0
    local keyword_total=0
    local booster_score=0
    local booster_total=0
    local negative_score=0
    local negative_total=0

    # Score activation keywords
    while IFS= read -r keyword; do
        # v5.1: Use grep -i (case-insensitive) without -w for partial matches
        # Allows "CVE" to match "CVE-2024-1234" and "fix bug" to match "fixing bugs"
        if echo "$task_lower" | grep -qi "$keyword"; then
            ((keyword_score++))
        fi
        ((keyword_total++))
    done < <(jq -r ".experts.$expert.activation_keywords[]" "$ROUTING_PATTERNS")

    # Score confidence boosters (higher weight)
    while IFS= read -r booster; do
        if echo "$task_lower" | grep -qi "$booster"; then
            ((booster_score++))
        fi
        ((booster_total++))
    done < <(jq -r ".experts.$expert.confidence_boosters[]" "$ROUTING_PATTERNS")

    # Score negative indicators (subtract from confidence)
    while IFS= read -r negative; do
        if echo "$task_lower" | grep -qi "$negative"; then
            ((negative_score++))
        fi
        ((negative_total++))
    done < <(jq -r ".experts.$expert.negative_indicators[]" "$ROUTING_PATTERNS")

    # Calculate weighted confidence score
    # v5.1 Fix: Use additive scoring instead of percentage-based
    # Each matched keyword adds confidence points
    # Formula: (keyword_matches * 25) + (booster_matches * 12) - (negative_matches * 30)
    # Target: 2-3 activation keywords + 1-2 boosters = 80+ confidence

    local keyword_points=$((keyword_score * 25))
    local booster_points=$((booster_score * 12))
    local negative_points=$((negative_score * 30))

    # Calculate final confidence (0-100)
    local final_confidence=$((keyword_points + booster_points - negative_points))

    # Clamp to 0-100
    if [ $final_confidence -lt 0 ]; then
        final_confidence=0
    fi
    if [ $final_confidence -gt 100 ]; then
        final_confidence=100
    fi

    echo $final_confidence
}

##############################################################################
# get_matched_keywords: Get list of keywords that matched for an expert
# Args:
#   $1: task_description
#   $2: expert_name
# Returns: comma-separated list of matched keywords
##############################################################################
get_matched_keywords() {
    local task_description="$1"
    local expert="$2"
    local task_lower=$(echo "$task_description" | tr '[:upper:]' '[:lower:]')
    local matched=()

    # Check activation keywords
    while IFS= read -r keyword; do
        if echo "$task_lower" | grep -qi "$keyword"; then
            matched+=("$keyword")
        fi
    done < <(jq -r ".experts.$expert.activation_keywords[]" "$ROUTING_PATTERNS")

    # Check confidence boosters
    while IFS= read -r booster; do
        if echo "$task_lower" | grep -qi "$booster"; then
            matched+=("$booster")
        fi
    done < <(jq -r ".experts.$expert.confidence_boosters[]" "$ROUTING_PATTERNS")

    # Return comma-separated list (limit to first 5)
    local result=""
    local count=0
    for kw in "${matched[@]}"; do
        if [ $count -ge 5 ]; then
            break
        fi
        if [ -n "$result" ]; then
            result="$result, $kw"
        else
            result="$kw"
        fi
        ((count++))
    done

    echo "$result"
}

##############################################################################
# generate_routing_explanation: Generate human-readable explanation
# Args:
#   $1: task_description
#   $2: primary_expert
#   $3: primary_confidence (decimal 0-1)
#   $4: strategy
#   $5: type_routed (optional, "true" if type-based routing)
# Returns: Human-readable explanation string
##############################################################################
generate_routing_explanation() {
    local task_description="$1"
    local primary_expert="$2"
    local primary_confidence="$3"
    local strategy="$4"
    local type_routed="${5:-false}"

    local confidence_pct=$(echo "scale=0; $primary_confidence * 100" | bc)
    local matched_keywords=$(get_matched_keywords "$task_description" "$primary_expert")

    local explanation=""

    if [ "$type_routed" = "true" ]; then
        explanation="Routed to $primary_expert (${confidence_pct}% confidence) via task type classification."
    elif [ -n "$matched_keywords" ]; then
        explanation="Routed to $primary_expert (${confidence_pct}% confidence) based on keywords: $matched_keywords."
    else
        explanation="Routed to $primary_expert (${confidence_pct}% confidence) as best available match."
    fi

    if [ "$strategy" = "multi_expert_parallel" ]; then
        explanation="$explanation Multiple experts activated for parallel processing."
    elif [ "$strategy" = "single_expert_low_confidence" ]; then
        explanation="$explanation Low confidence routing - consider manual review."
    fi

    echo "$explanation"
}

##############################################################################
# try_semantic_routing: Attempt semantic routing using embedding-based matching
# Phase 5.2 Enhancement: +7% accuracy improvement (94.5% vs 87.5%)
# Args:
#   $1: task_id
#   $2: task_description
# Returns: JSON with routing result or empty string if failed/disabled
##############################################################################
try_semantic_routing() {
    local task_id="$1"
    local task_description="$2"

    # Check if semantic routing is enabled
    if [ "$SEMANTIC_ROUTING_ENABLED" != "true" ]; then
        return 0
    fi

    # Check if semantic router CLI exists
    if [ ! -f "$SEMANTIC_ROUTER_CLI" ]; then
        return 0
    fi

    # Call semantic router CLI
    local semantic_result=""
    if semantic_result=$(node "$SEMANTIC_ROUTER_CLI" --task-id "$task_id" "$task_description" 2>/dev/null); then
        # Parse confidence from result
        local confidence=$(echo "$semantic_result" | jq -r '.confidence // 0' 2>/dev/null)
        local method=$(echo "$semantic_result" | jq -r '.method // "unknown"' 2>/dev/null)

        # Only use semantic result if confidence meets threshold and method is semantic
        if [ "$method" = "semantic" ] && (( $(echo "$confidence >= $SEMANTIC_CONFIDENCE_THRESHOLD" | bc -l 2>/dev/null || echo 0) )); then
            echo "$semantic_result"
            return 0
        fi
    fi

    # Return empty string if semantic routing failed or confidence too low
    echo ""
    return 0
}

##############################################################################
# route_task_moe: Perform MoE-style routing with sparse activation
# Args:
#   $1: task_id
#   $2: task_description (format: "type: title description")
# Outputs: JSON routing decision
##############################################################################
route_task_moe() {
    local task_id="$1"
    local task_description="$2"
    local timestamp=$(date +"%Y-%m-%dT%H:%M:%S%z")

    # Permission check: Can coordinator read routing patterns?
    check_permission "coordinator-master" "routing-patterns" "read" || {
        echo '{"error": "Permission denied to access routing patterns"}' >&2
        return 1
    }

    # Phase 5.2: Try semantic routing first (94.5% accuracy vs 87.5% for keywords)
    local semantic_result=$(try_semantic_routing "$task_id" "$task_description")
    local using_semantic="false"
    local dev_score=0
    local sec_score=0
    local inv_score=0

    if [ -n "$semantic_result" ]; then
        # Semantic routing succeeded with high confidence
        local expert=$(echo "$semantic_result" | jq -r '.expert')
        local confidence=$(echo "$semantic_result" | jq -r '.confidence')

        # Convert to integer score for compatibility with rest of function
        local sem_score=$(echo "scale=0; $confidence * 100" | bc 2>/dev/null || echo "60")

        # Map to appropriate *_score variable
        case "$expert" in
            development)
                dev_score=$sem_score
                using_semantic="true"
                ;;
            security)
                sec_score=$sem_score
                using_semantic="true"
                ;;
            inventory)
                inv_score=$sem_score
                using_semantic="true"
                ;;
        esac
    fi

    # If semantic routing didn't succeed, use keyword-based routing

    # v5.0 CAG Enhancement: Extract task type for direct routing
    local task_type=""
    if [[ "$task_description" =~ ^([a-z0-9-]+): ]]; then
        task_type="${BASH_REMATCH[1]}"
    fi

    # v5.0 CAG Enhancement: Type-based routing (high confidence)
    local type_routed_expert=""
    local type_confidence=0

    if [ -n "$task_type" ]; then
        # Normalize task type for matching (handle CVE-YYYY-NNNN format)
        local normalized_type="$task_type"
        if [[ "$task_type" =~ ^cve- ]]; then
            normalized_type="cve"
        elif [[ "$task_type" =~ ^vulnerability- ]]; then
            normalized_type="vulnerability"
        fi

        case "$normalized_type" in
            security-scan|security-audit|security-fix|cve|vulnerability|security)
                type_routed_expert="security"
                type_confidence=95
                ;;
            feature|bug-fix|refactor|optimization|development)
                type_routed_expert="development"
                type_confidence=95
                ;;
            inventory|catalog|discovery|documentation)
                type_routed_expert="inventory"
                type_confidence=95
                ;;
            build|deploy|test|ci-cd|release)
                type_routed_expert="cicd"
                type_confidence=95
                ;;
        esac
    fi

    # Only run keyword-based scoring if semantic routing didn't provide a result
    if [ "$using_semantic" != "true" ]; then
        # Calculate confidence scores for all experts (keyword-based)
        dev_score=$(calculate_expert_score "$task_description" "development")
        sec_score=$(calculate_expert_score "$task_description" "security")
        inv_score=$(calculate_expert_score "$task_description" "inventory")

        # v5.0 CAG: Boost scores with type-based routing
        if [ "$type_routed_expert" = "development" ]; then
            dev_score=$((dev_score > type_confidence ? dev_score : type_confidence))
        elif [ "$type_routed_expert" = "security" ]; then
            sec_score=$((sec_score > type_confidence ? sec_score : type_confidence))
        elif [ "$type_routed_expert" = "inventory" ]; then
            inv_score=$((inv_score > type_confidence ? inv_score : type_confidence))
        fi

        # Enhancement #16: Apply learned preference weights
        if [ "$LEARNED_WEIGHTS_ENABLED" = "true" ]; then
            dev_score=$(apply_learned_boost "development" "$dev_score" "$task_description")
            sec_score=$(apply_learned_boost "security" "$sec_score" "$task_description")
            inv_score=$(apply_learned_boost "inventory" "$inv_score" "$task_description")
        fi

        # Phase 3 Enhancement #16: Apply utility weights from model versions
        if [ "$UTILITY_WEIGHTS_ENABLED" = "true" ]; then
            dev_score=$(apply_utility_weights "development" "$dev_score" "$task_description")
            sec_score=$(apply_utility_weights "security" "$sec_score" "$task_description")
            inv_score=$(apply_utility_weights "inventory" "$inv_score" "$task_description")
        fi
    fi

    # Convert to decimal for jq (0.0 - 1.0 scale)
    local dev_conf=$(echo "scale=2; $dev_score / 100" | bc)
    local sec_conf=$(echo "scale=2; $sec_score / 100" | bc)
    local inv_conf=$(echo "scale=2; $inv_score / 100" | bc)

    # Determine activation strategy (sparse activation)
    local activated_experts=()
    local primary_expert=""
    local primary_confidence=0

    # Find highest scoring expert
    if (( $(echo "$dev_conf >= $sec_conf && $dev_conf >= $inv_conf" | bc -l) )); then
        primary_expert="development"
        primary_confidence=$dev_conf
    elif (( $(echo "$sec_conf >= $dev_conf && $sec_conf >= $inv_conf" | bc -l) )); then
        primary_expert="security"
        primary_confidence=$sec_conf
    else
        primary_expert="inventory"
        primary_confidence=$inv_conf
    fi

    # Sparse activation: only activate experts above minimum threshold
    if (( $(echo "$dev_conf >= $MINIMUM_ACTIVATION" | bc -l) )); then
        activated_experts+=("development:$dev_conf")
    fi

    if (( $(echo "$sec_conf >= $MINIMUM_ACTIVATION" | bc -l) )); then
        activated_experts+=("security:$sec_conf")
    fi

    if (( $(echo "$inv_conf >= $MINIMUM_ACTIVATION" | bc -l) )); then
        activated_experts+=("inventory:$inv_conf")
    fi

    # Determine routing strategy
    local strategy=""
    local parallel_experts=()

    # v4.0 Enhancement: Calculate margin between primary and secondary experts
    local second_highest=0
    for expert_conf in "${activated_experts[@]}"; do
        local conf="${expert_conf#*:}"
        if [ "$conf" != "$primary_confidence" ] && (( $(echo "$conf > $second_highest" | bc -l) )); then
            second_highest=$conf
        fi
    done
    local margin=$(echo "scale=2; $primary_confidence - $second_highest" | bc)

    # v4.0 Enhancement: Route to single expert if:
    # 1. Primary confidence >= threshold, OR
    # 2. Primary has significant margin (>=0.20) over others, OR
    # 3. Only one expert activated
    if (( $(echo "$primary_confidence >= $SINGLE_EXPERT_THRESHOLD" | bc -l) )); then
        strategy="single_expert"
    elif (( $(echo "$margin >= 0.20" | bc -l) )); then
        # Primary has strong lead over others - route to single expert
        strategy="single_expert"
    elif [ ${#activated_experts[@]} -gt 1 ]; then
        strategy="multi_expert_parallel"
        # Add secondary experts for parallel activation
        for expert_conf in "${activated_experts[@]}"; do
            local expert="${expert_conf%:*}"
            if [ "$expert" != "$primary_expert" ]; then
                parallel_experts+=("$expert")
            fi
        done
    else
        strategy="single_expert_low_confidence"
    fi

    # Build routing decision JSON
    local parallel_json="[]"
    if [ ${#parallel_experts[@]} -gt 0 ]; then
        parallel_json="$(printf '%s\n' "${parallel_experts[@]}" | jq -R . | jq -s .)"
    fi

    # Generate human-readable explanation
    local type_routed="false"
    if [ -n "$type_routed_expert" ] && [ "$type_routed_expert" = "$primary_expert" ]; then
        type_routed="true"
    fi
    local explanation=$(generate_routing_explanation "$task_description" "$primary_expert" "$primary_confidence" "$strategy" "$type_routed")

    # Phase 5.2: Enhance explanation with semantic routing info
    if [ "$using_semantic" = "true" ]; then
        explanation="$explanation (Phase 5.2: Semantic routing via embeddings, +7% accuracy)"
    fi

    # Generate model recommendation based on task analysis
    local complexity=$(score_task_complexity "$task_description")
    local sensitivity=$(detect_task_sensitivity "$task_description")
    local model_rec=$(get_model_recommendation "$task_description" "$complexity" "$sensitivity")

    # Determine routing method
    local routing_method="keyword"
    if [ "$using_semantic" = "true" ]; then
        routing_method="semantic"
    fi

    local routing_decision=$(jq -n \
        --arg task_id "$task_id" \
        --arg timestamp "$timestamp" \
        --arg primary "$primary_expert" \
        --argjson primary_conf "$primary_confidence" \
        --arg strategy "$strategy" \
        --argjson dev_conf "$dev_conf" \
        --argjson sec_conf "$sec_conf" \
        --argjson inv_conf "$inv_conf" \
        --argjson parallel "$parallel_json" \
        --arg explanation "$explanation" \
        --arg routing_method "$routing_method" \
        --argjson model_recommendation "$model_rec" \
        '{
            task_id: $task_id,
            timestamp: $timestamp,
            routing_strategy: "mixture_of_experts",
            routing_method: $routing_method,
            decision: {
                primary_expert: $primary,
                primary_confidence: $primary_conf,
                strategy: $strategy,
                parallel_experts: $parallel,
                scores: {
                    development: $dev_conf,
                    security: $sec_conf,
                    inventory: $inv_conf
                },
                explanation: $explanation,
                model_recommendation: $model_recommendation
            }
        }')

    # Log model selection decision
    local rec_model=$(echo "$model_rec" | jq -r '.model')
    local rec_provider=$(echo "$model_rec" | jq -r '.provider')
    local rec_tier=$(echo "$model_rec" | jq -r '.tier')
    local rec_reasoning=$(echo "$model_rec" | jq -r '.reasoning')
    log_model_selection "$task_id" "$rec_model" "$rec_provider" "$rec_tier" "$complexity" "$sensitivity" "$rec_reasoning"

    # Log routing decision (with immediate flush)
    # v5.1: Output compact single-line JSON (proper JSONL format)
    echo "$routing_decision" | jq -c '.' >> "$ROUTING_LOG"

    # Force immediate flush to disk (prevents buffering issues during tests)
    sync "$ROUTING_LOG" 2>/dev/null || true

    # Emit event for real-time dashboard updates
    local events_file="$SCRIPT_DIR/../../dashboard-events.jsonl"
    if [ -w "$(dirname "$events_file")" ] || [ -w "$events_file" ]; then
        local event_json=$(jq -n \
            --arg timestamp "$(date +%Y-%m-%dT%H:%M:%S%z)" \
            --arg task_id "$task_id" \
            --arg primary "$primary_expert" \
            --argjson confidence "$primary_confidence" \
            --arg strategy "$strategy" \
            '{
                timestamp: $timestamp,
                type: "moe_routing_decision",
                data: {
                    task_id: $task_id,
                    expert: $primary,
                    confidence: $confidence,
                    strategy: $strategy
                }
            }')
        echo "$event_json" >> "$events_file" 2>/dev/null || true
    fi

    # Output decision
    echo "$routing_decision"
}

##############################################################################
# get_activated_experts: Extract list of experts to activate
# Args:
#   $1: routing_decision JSON
# Outputs: Space-separated list of expert names
##############################################################################
get_activated_experts() {
    local routing_decision="$1"

    local primary=$(echo "$routing_decision" | jq -r '.decision.primary_expert')
    local parallel=$(echo "$routing_decision" | jq -r '.decision.parallel_experts[]' 2>/dev/null || echo "")

    local experts="$primary"
    if [ -n "$parallel" ] && [ "$parallel" != "null" ]; then
        experts="$experts $parallel"
    fi

    echo "$experts"
}

##############################################################################
# record_routing_feedback: Record routing outcome for learning feedback loop
# Enhancement #16: Connect learning to router
# Args:
#   $1: task_id
#   $2: routed_expert
#   $3: outcome (success|failure)
#   $4: score (0-100)
#   $5: keywords matched (comma-separated)
##############################################################################
record_routing_feedback() {
    local task_id="$1"
    local routed_expert="$2"
    local outcome="$3"
    local score="${4:-0}"
    local keywords="${5:-}"

    local feedback_dir="$COMMIT_RELAY_HOME/coordination/knowledge-base/feedback-reports"
    mkdir -p "$feedback_dir"

    local timestamp=$(date +"%Y-%m-%dT%H:%M:%S%z")
    local feedback_file="$feedback_dir/routing-feedback-$(date +%Y%m%d).jsonl"

    # Record feedback for learning system
    local feedback_json=$(jq -n \
        --arg task_id "$task_id" \
        --arg expert "$routed_expert" \
        --arg outcome "$outcome" \
        --argjson score "$score" \
        --arg keywords "$keywords" \
        --arg ts "$timestamp" \
        '{
            task_id: $task_id,
            expert: $expert,
            outcome: $outcome,
            score: $score,
            keywords: ($keywords | split(",")),
            timestamp: $ts,
            feedback_type: "routing_outcome"
        }')

    echo "$feedback_json" >> "$feedback_file"

    # Emit event for learning system
    local events_file="$SCRIPT_DIR/../../dashboard-events.jsonl"
    if [ -w "$(dirname "$events_file")" ] || [ -w "$events_file" ]; then
        local event_json=$(jq -n \
            --arg timestamp "$timestamp" \
            --arg task_id "$task_id" \
            --arg expert "$routed_expert" \
            --arg outcome "$outcome" \
            '{
                timestamp: $timestamp,
                type: "routing_feedback",
                data: {
                    task_id: $task_id,
                    expert: $expert,
                    outcome: $outcome
                }
            }')
        echo "$event_json" >> "$events_file" 2>/dev/null || true
    fi
}

##############################################################################
# reload_learned_weights: Reload learned weights (call after learning updates)
##############################################################################
reload_learned_weights() {
    load_learned_weights
    load_utility_weights
}

##############################################################################
# reload_utility_weights: Reload utility weights from model versions
##############################################################################
reload_utility_weights() {
    load_utility_weights
}

##############################################################################
# Main execution (if run directly)
##############################################################################
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    if [ $# -lt 2 ]; then
        echo "Usage: $0 <task_id> <task_description>"
        echo "Example: $0 task-123 'Fix security vulnerability in authentication module'"
        exit 1
    fi

    task_id="$1"
    task_description="$2"

    routing_decision=$(route_task_moe "$task_id" "$task_description")

    # Output compact JSON for machine consumption
    echo "$routing_decision"

    # If running interactively, show pretty output to stderr
    if [ -t 1 ]; then
        echo "$routing_decision" | jq '.' >&2
        echo "" >&2
        echo "Activated experts:" >&2
        get_activated_experts "$routing_decision" >&2
    fi
fi
