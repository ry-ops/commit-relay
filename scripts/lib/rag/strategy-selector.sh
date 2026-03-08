#!/usr/bin/env bash
# scripts/lib/rag/strategy-selector.sh
# Adaptive Strategy Selection for RAG Context
# Phase 3 Enhancement #18: Extract successful strategies from similar past tasks
#
# Integrates with:
# - lib/rag/context-manager.js for vector-based strategy retrieval
# - coordination/patterns/ for failure patterns
# - coordination/knowledge-base/ for learned patterns
#
# Usage:
#   source scripts/lib/rag/strategy-selector.sh
#   select_strategy "Implement user authentication feature" "development"
#   inject_strategy_into_prompt "$strategy" "$prompt"

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"

# Paths
readonly PATTERNS_DIR="$COMMIT_RELAY_HOME/coordination/patterns"
readonly KNOWLEDGE_BASE="$COMMIT_RELAY_HOME/coordination/knowledge-base"
readonly LEARNED_PATTERNS="$KNOWLEDGE_BASE/learned-patterns/patterns-latest.json"
readonly STRATEGY_HISTORY="$KNOWLEDGE_BASE/strategy-history"
readonly CONTEXT_MANAGER_JS="$COMMIT_RELAY_HOME/lib/rag/context-manager.js"

# Source logging
source "$COMMIT_RELAY_HOME/scripts/lib/logging.sh" 2>/dev/null || {
    log_info() { echo "[INFO] $1"; }
    log_warn() { echo "[WARN] $1"; }
    log_error() { echo "[ERROR] $1"; }
}

# Ensure directories exist
mkdir -p "$STRATEGY_HISTORY"

##############################################################################
# is_context_manager_available: Check if context-manager.js is available
##############################################################################
is_context_manager_available() {
    if [ ! -f "$CONTEXT_MANAGER_JS" ]; then
        return 1
    fi

    # Check if node is available
    if ! command -v node &> /dev/null; then
        return 1
    fi

    return 0
}

##############################################################################
# select_strategy: Main strategy selection function
# Args:
#   $1: task_description
#   $2: task_type (development|security|inventory|cicd)
#   $3: max_strategies (optional, default 3)
# Returns: JSON with strategy recommendations
##############################################################################
select_strategy() {
    local task_description="$1"
    local task_type="${2:-development}"
    local max_strategies="${3:-3}"

    log_info "[Strategy] Selecting strategies for: ${task_description:0:50}..."

    local strategies='{
        "selected_at": "'"$(date -Iseconds 2>/dev/null || date +%Y-%m-%dT%H:%M:%S%z)"'",
        "task_type": "'"$task_type"'",
        "strategies": [],
        "fallback_used": false,
        "confidence": 0
    }'

    # Try context manager first (vector-based)
    if is_context_manager_available; then
        local cm_result
        cm_result=$(get_strategies_from_context_manager "$task_description" "$task_type" "$max_strategies" 2>/dev/null || echo "")

        if [ -n "$cm_result" ] && [ "$cm_result" != "[]" ]; then
            local strategy_count
            strategy_count=$(echo "$cm_result" | jq 'length' 2>/dev/null || echo "0")

            if [ "$strategy_count" -gt 0 ]; then
                strategies=$(echo "$strategies" | jq \
                    --argjson strats "$cm_result" \
                    '.strategies = $strats | .source = "context_manager"')
                log_info "[Strategy] Found $strategy_count strategies from context manager"
            fi
        fi
    fi

    # Check if we need fallback
    local current_count
    current_count=$(echo "$strategies" | jq '.strategies | length')

    if [ "$current_count" -lt "$max_strategies" ]; then
        # Try pattern-based fallback
        local pattern_strats
        pattern_strats=$(get_strategies_from_patterns "$task_description" "$task_type" "$((max_strategies - current_count))")

        if [ -n "$pattern_strats" ] && [ "$pattern_strats" != "[]" ]; then
            strategies=$(echo "$strategies" | jq \
                --argjson new_strats "$pattern_strats" \
                '.strategies += $new_strats | .fallback_used = true')
            log_info "[Strategy] Added $(echo "$pattern_strats" | jq 'length') strategies from patterns"
        fi
    fi

    # Check again if we need more strategies
    current_count=$(echo "$strategies" | jq '.strategies | length')

    if [ "$current_count" -lt "$max_strategies" ]; then
        # Use learned patterns as final fallback
        local learned_strats
        learned_strats=$(get_strategies_from_learned "$task_type" "$((max_strategies - current_count))")

        if [ -n "$learned_strats" ] && [ "$learned_strats" != "[]" ]; then
            strategies=$(echo "$strategies" | jq \
                --argjson new_strats "$learned_strats" \
                '.strategies += $new_strats | .fallback_used = true')
            log_info "[Strategy] Added $(echo "$learned_strats" | jq 'length') strategies from learned patterns"
        fi
    fi

    # Calculate confidence based on strategies found
    current_count=$(echo "$strategies" | jq '.strategies | length')
    local confidence=0

    if [ "$current_count" -gt 0 ]; then
        # Calculate average similarity/score from strategies
        local avg_score
        avg_score=$(echo "$strategies" | jq '[.strategies[].similarity // .strategies[].score // 0.5] | add / length * 100' 2>/dev/null || echo "50")
        confidence=$(printf "%.0f" "$avg_score" 2>/dev/null || echo "50")
    fi

    strategies=$(echo "$strategies" | jq \
        --argjson conf "$confidence" \
        '.confidence = $conf')

    echo "$strategies"
}

##############################################################################
# get_strategies_from_context_manager: Use Node.js context manager
##############################################################################
get_strategies_from_context_manager() {
    local task_description="$1"
    local task_type="$2"
    local max_results="$3"

    # Escape the task description for JavaScript
    local escaped_desc
    escaped_desc=$(echo "$task_description" | sed 's/"/\\"/g' | sed "s/'/\\\\'/g")

    node -e "
        const ContextManager = require('$CONTEXT_MANAGER_JS');
        const cm = new ContextManager();

        (async () => {
            await cm.initialize();
            const recommendations = await cm.generateStrategyRecommendations('$escaped_desc', '$task_type');

            // Extract and format strategies
            const strategies = recommendations.strategies.slice(0, $max_results).map(s => ({
                approach: s.approach || 'See task details',
                worker_type: s.worker_type,
                similarity: s.similarity,
                task_id: s.task_id,
                lessons_learned: s.lessons_learned,
                source: 'vector_db'
            }));

            console.log(JSON.stringify(strategies));
        })().catch(err => {
            console.error(err);
            console.log('[]');
        });
    " 2>/dev/null
}

##############################################################################
# get_strategies_from_patterns: Extract strategies from failure patterns
##############################################################################
get_strategies_from_patterns() {
    local task_description="$1"
    local task_type="$2"
    local max_results="$3"

    local patterns_file="$PATTERNS_DIR/failure-patterns.jsonl"

    if [ ! -f "$patterns_file" ]; then
        echo "[]"
        return
    fi

    local task_lower
    task_lower=$(echo "$task_description" | tr '[:upper:]' '[:lower:]')

    # Find relevant patterns based on task description
    local strategies="[]"

    while IFS= read -r line; do
        if [ -z "$line" ]; then
            continue
        fi

        local pattern_id
        pattern_id=$(echo "$line" | jq -r '.pattern_id // ""')
        local category
        category=$(echo "$line" | jq -r '.category // ""')
        local signature
        signature=$(echo "$line" | jq -r '.signature.error_pattern // ""')
        local auto_fix
        auto_fix=$(echo "$line" | jq -r '.auto_fix_action // ""')

        # Check for relevance
        local is_relevant=false

        # Check if pattern matches task type
        case "$task_type" in
            development)
                if [[ "$category" =~ (code|logic|dependency) ]]; then
                    is_relevant=true
                fi
                ;;
            security)
                if [[ "$category" =~ (security|auth|vulnerability) ]]; then
                    is_relevant=true
                fi
                ;;
            *)
                # Check if pattern keywords match task
                if echo "$task_lower" | grep -qi "$(echo "$category" | tr '[:upper:]' '[:lower:]')"; then
                    is_relevant=true
                fi
                ;;
        esac

        if [ "$is_relevant" = true ] && [ -n "$auto_fix" ]; then
            local strategy
            strategy=$(jq -n \
                --arg approach "Avoid pattern: $signature" \
                --arg fix "$auto_fix" \
                --arg pattern_id "$pattern_id" \
                '{
                    approach: ($approach + ". Apply fix: " + $fix),
                    pattern_id: $pattern_id,
                    similarity: 0.6,
                    source: "failure_patterns"
                }')

            strategies=$(echo "$strategies" | jq \
                --argjson strat "$strategy" \
                '. += [$strat]')

            # Check limit
            local count
            count=$(echo "$strategies" | jq 'length')
            if [ "$count" -ge "$max_results" ]; then
                break
            fi
        fi
    done < "$patterns_file"

    echo "$strategies"
}

##############################################################################
# get_strategies_from_learned: Extract strategies from learned patterns
##############################################################################
get_strategies_from_learned() {
    local task_type="$1"
    local max_results="$2"

    if [ ! -f "$LEARNED_PATTERNS" ]; then
        echo "[]"
        return
    fi

    # Get routing patterns for the task type
    local strategies="[]"

    local routing_patterns
    routing_patterns=$(jq -r '.routing_patterns // []' "$LEARNED_PATTERNS" 2>/dev/null || echo "[]")

    while IFS= read -r line; do
        if [ -z "$line" ] || [ "$line" = "null" ]; then
            continue
        fi

        local worker_type
        worker_type=$(echo "$line" | jq -r '.preferred_worker_type // ""')
        local count
        count=$(echo "$line" | jq -r '.count // 0')
        local avg_score
        avg_score=$(echo "$line" | jq -r '.avg_score // 0')

        # Check if this worker type is relevant for task type
        local is_relevant=false

        case "$task_type" in
            development)
                if [[ "$worker_type" =~ (feature-implementer|bug-fixer|refactorer|optimizer) ]]; then
                    is_relevant=true
                fi
                ;;
            security)
                if [[ "$worker_type" =~ (security-scanner|vulnerability-fixer) ]]; then
                    is_relevant=true
                fi
                ;;
            inventory)
                if [[ "$worker_type" =~ (cataloger|documenter) ]]; then
                    is_relevant=true
                fi
                ;;
            *)
                is_relevant=true
                ;;
        esac

        if [ "$is_relevant" = true ] && [ "$count" -gt 0 ]; then
            local similarity
            similarity=$(echo "scale=2; $avg_score / 100" | bc 2>/dev/null || echo "0.5")

            local strategy
            strategy=$(jq -n \
                --arg approach "Use $worker_type worker (historically $avg_score% success rate with $count tasks)" \
                --arg worker_type "$worker_type" \
                --argjson similarity "$similarity" \
                --argjson count "$count" \
                '{
                    approach: $approach,
                    worker_type: $worker_type,
                    similarity: $similarity,
                    usage_count: $count,
                    source: "learned_patterns"
                }')

            strategies=$(echo "$strategies" | jq \
                --argjson strat "$strategy" \
                '. += [$strat]')

            # Check limit
            local strat_count
            strat_count=$(echo "$strategies" | jq 'length')
            if [ "$strat_count" -ge "$max_results" ]; then
                break
            fi
        fi
    done < <(echo "$routing_patterns" | jq -c '.[]' 2>/dev/null)

    echo "$strategies"
}

##############################################################################
# format_strategy_for_prompt: Format strategies as prompt guidance
# Args:
#   $1: strategies JSON
# Returns: Formatted markdown string
##############################################################################
format_strategy_for_prompt() {
    local strategies="$1"

    local strategy_count
    strategy_count=$(echo "$strategies" | jq '.strategies | length')

    if [ "$strategy_count" -eq 0 ]; then
        echo ""
        return
    fi

    local output="## Recommended Strategies from Similar Tasks\n\n"

    local confidence
    confidence=$(echo "$strategies" | jq -r '.confidence // 0')
    output+="**Overall Confidence:** ${confidence}%\n\n"

    local i=0
    while [ $i -lt "$strategy_count" ] && [ $i -lt 3 ]; do
        local strategy
        strategy=$(echo "$strategies" | jq ".strategies[$i]")

        local approach
        approach=$(echo "$strategy" | jq -r '.approach // "See details"')
        local similarity
        similarity=$(echo "$strategy" | jq -r '.similarity // 0' | awk '{printf "%.0f", $1 * 100}')
        local worker_type
        worker_type=$(echo "$strategy" | jq -r '.worker_type // ""')
        local lessons
        lessons=$(echo "$strategy" | jq -r '.lessons_learned // ""')
        local source
        source=$(echo "$strategy" | jq -r '.source // "unknown"')

        output+="### Strategy $((i + 1)) (Similarity: ${similarity}%)\n"
        output+="**Approach:** $approach\n"

        if [ -n "$worker_type" ] && [ "$worker_type" != "null" ]; then
            output+="**Worker Type:** $worker_type\n"
        fi

        if [ -n "$lessons" ] && [ "$lessons" != "null" ]; then
            output+="**Lessons Learned:** $lessons\n"
        fi

        output+="*Source: $source*\n\n"

        ((i++))
    done

    echo -e "$output"
}

##############################################################################
# inject_strategy_into_prompt: Add strategy guidance to worker prompt
# Args:
#   $1: strategy_json
#   $2: prompt_content
# Returns: Enhanced prompt with strategy guidance
##############################################################################
inject_strategy_into_prompt() {
    local strategy_json="$1"
    local prompt_content="$2"

    local guidance
    guidance=$(format_strategy_for_prompt "$strategy_json")

    if [ -z "$guidance" ]; then
        echo "$prompt_content"
        return
    fi

    # Find insertion point (after initial context, before task details)
    # Look for common markers
    local injection_point=""

    if echo "$prompt_content" | grep -q "## Task"; then
        injection_point="## Task"
    elif echo "$prompt_content" | grep -q "## Context"; then
        injection_point="## Context"
    elif echo "$prompt_content" | grep -q "## Instructions"; then
        injection_point="## Instructions"
    fi

    if [ -n "$injection_point" ]; then
        # Insert before the marker
        echo "$prompt_content" | awk -v marker="$injection_point" -v guidance="$guidance" '
            $0 ~ marker {
                print guidance
                print ""
            }
            {print}
        '
    else
        # Prepend to prompt
        echo -e "$guidance\n\n$prompt_content"
    fi
}

##############################################################################
# record_strategy_outcome: Record strategy usage outcome for learning
# Args:
#   $1: task_id
#   $2: strategy_json
#   $3: outcome (success|failure)
#   $4: notes (optional)
##############################################################################
record_strategy_outcome() {
    local task_id="$1"
    local strategy_json="$2"
    local outcome="$3"
    local notes="${4:-}"

    local timestamp
    timestamp=$(date -Iseconds 2>/dev/null || date +%Y-%m-%dT%H:%M:%S%z)

    local outcome_file="$STRATEGY_HISTORY/outcomes-$(date +%Y%m%d).jsonl"

    local outcome_record
    outcome_record=$(jq -n \
        --arg task_id "$task_id" \
        --argjson strategy "$strategy_json" \
        --arg outcome "$outcome" \
        --arg notes "$notes" \
        --arg ts "$timestamp" \
        '{
            task_id: $task_id,
            strategy_used: $strategy,
            outcome: $outcome,
            notes: $notes,
            recorded_at: $ts
        }')

    echo "$outcome_record" >> "$outcome_file"

    log_info "[Strategy] Recorded outcome for task $task_id: $outcome"
}

##############################################################################
# Export functions
##############################################################################
export -f is_context_manager_available
export -f select_strategy
export -f get_strategies_from_context_manager
export -f get_strategies_from_patterns
export -f get_strategies_from_learned
export -f format_strategy_for_prompt
export -f inject_strategy_into_prompt
export -f record_strategy_outcome

##############################################################################
# CLI Interface
##############################################################################
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    case "${1:-help}" in
        select)
            if [ $# -lt 2 ]; then
                echo "Usage: $0 select <task_description> [task_type] [max_strategies]"
                exit 1
            fi
            select_strategy "$2" "${3:-development}" "${4:-3}"
            ;;
        format)
            if [ $# -lt 2 ]; then
                echo "Usage: $0 format <strategy_json>"
                exit 1
            fi
            format_strategy_for_prompt "$2"
            ;;
        inject)
            if [ $# -lt 3 ]; then
                echo "Usage: $0 inject <strategy_json> <prompt_file>"
                exit 1
            fi
            prompt_content=$(cat "$3")
            inject_strategy_into_prompt "$2" "$prompt_content"
            ;;
        record)
            if [ $# -lt 4 ]; then
                echo "Usage: $0 record <task_id> <strategy_json> <outcome> [notes]"
                exit 1
            fi
            record_strategy_outcome "$2" "$3" "$4" "${5:-}"
            ;;
        help|*)
            echo "Adaptive Strategy Selection for RAG Context"
            echo ""
            echo "Usage: $0 <command> [args]"
            echo ""
            echo "Commands:"
            echo "  select <desc> [type] [max]        Select strategies for task"
            echo "  format <strategy_json>            Format strategies for prompt"
            echo "  inject <strat_json> <prompt_file> Inject strategies into prompt"
            echo "  record <task_id> <strat> <outcome> Record strategy outcome"
            echo ""
            echo "Example:"
            echo "  $0 select 'Implement JWT authentication' development 3"
            ;;
    esac
fi
