#!/bin/bash
# MoE Pattern Learner
# Analyzes routing outcomes using LLMs to extract patterns and learnings

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLM_MESH_HOME="$SCRIPT_DIR/../.."
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"

# Paths
OUTCOMES_CATALOG="$SCRIPT_DIR/../catalog/routing-decisions.jsonl"
LEARNED_PATTERNS="$SCRIPT_DIR/../catalog/learned-patterns.json"
PROMPTS_DIR="$SCRIPT_DIR/../prompts"
OUTCOME_TRACKER="$SCRIPT_DIR/outcome-tracker.sh"

# LLM Configuration (using Claude via API or local)
LLM_PROVIDER="${LLM_PROVIDER:-anthropic}"
LLM_MODEL="${LLM_MODEL:-claude-sonnet-4}"
LLM_API_KEY="${ANTHROPIC_API_KEY:-}"

# Ensure directories exist
mkdir -p "$(dirname "$LEARNED_PATTERNS")"

##############################################################################
# call_llm: Call LLM with a prompt and data
# Args:
#   $1: prompt_file (path to .md prompt)
#   $2: data (JSON string to analyze)
# Outputs: LLM response (JSON)
##############################################################################
call_llm() {
    local prompt_file="$1"
    local data="$2"

    if [ ! -f "$prompt_file" ]; then
        echo "Error: Prompt file not found: $prompt_file" >&2
        return 1
    fi

    # Read prompt
    local prompt_content=$(cat "$prompt_file")

    # Build full prompt with data
    local full_prompt=$(cat <<EOF
$prompt_content

---

# Data to Analyze

$data
EOF
)

    # Call LLM (this is a placeholder - replace with actual LLM API call)
    # For now, we'll use a mock response for development
    # In production, this would call Claude API, local model, or other LLM service

    if [ "$LLM_PROVIDER" = "anthropic" ] && [ -n "$LLM_API_KEY" ]; then
        # Call Anthropic API
        local response=$(curl -s https://api.anthropic.com/v1/messages \
            -H "Content-Type: application/json" \
            -H "x-api-key: $LLM_API_KEY" \
            -H "anthropic-version: 2023-06-01" \
            -d "{
                \"model\": \"$LLM_MODEL\",
                \"max_tokens\": 4096,
                \"messages\": [{
                    \"role\": \"user\",
                    \"content\": $(echo "$full_prompt" | jq -Rs .)
                }]
            }" | jq -r '.content[0].text')

        echo "$response"
    else
        # Mock response for development/testing
        echo "{
            \"routing_accuracy\": 0.5,
            \"confidence_calibration\": 0.5,
            \"ideal_expert\": \"development\",
            \"quality_score\": 0.5,
            \"learnings\": [\"Mock learning - configure LLM_PROVIDER and LLM_API_KEY for real analysis\"],
            \"patterns_discovered\": [],
            \"improvements_suggested\": [],
            \"routing_rule_updates\": []
        }"
    fi
}

##############################################################################
# analyze_outcome: Analyze a single routing outcome
# Args:
#   $1: outcome (JSON string)
# Outputs: Analysis results (JSON)
##############################################################################
analyze_outcome() {
    local outcome="$1"

    # Call LLM with analyze-routing-quality prompt
    local analysis=$(call_llm \
        "$PROMPTS_DIR/analyze-routing-quality.md" \
        "$outcome")

    # Update outcome with analysis
    local decision_id=$(echo "$outcome" | jq -r '.decision_id')
    local updated_outcome=$(echo "$outcome" | jq \
        --argjson analysis "$analysis" \
        '.outcome += $analysis | .learning.analyzed = true')

    echo "$updated_outcome"
}

##############################################################################
# learn_from_outcomes: Analyze all unanalyzed outcomes and update patterns
##############################################################################
learn_from_outcomes() {
    echo "Starting pattern learning from routing outcomes..." >&2

    # Get unanalyzed outcomes
    local unanalyzed=$(bash "$OUTCOME_TRACKER" get_unanalyzed_outcomes 2>/dev/null || \
        ([ -f "$OUTCOMES_CATALOG" ] && jq -s '[.[] | select(.learning.analyzed == false)]' "$OUTCOMES_CATALOG" || echo "[]"))

    local outcome_count=$(echo "$unanalyzed" | jq 'length')

    if [ "$outcome_count" -eq 0 ]; then
        echo "No unanalyzed outcomes found." >&2
        return 0
    fi

    echo "Found $outcome_count unanalyzed outcomes. Analyzing..." >&2

    # Initialize or load learned patterns
    if [ ! -f "$LEARNED_PATTERNS" ]; then
        initialize_learned_patterns
    fi

    # Analyze each outcome
    local analyzed_count=0
    echo "$unanalyzed" | jq -c '.[]' | while read -r outcome; do
        echo "Analyzing outcome $(echo "$outcome" | jq -r '.decision_id')..." >&2

        # Analyze with LLM
        local analyzed=$(analyze_outcome "$outcome")

        # Extract patterns and update learned patterns file
        update_learned_patterns "$analyzed"

        # Mark as analyzed in catalog
        local decision_id=$(echo "$analyzed" | jq -r '.decision_id')

        # Update catalog with analysis
        local temp_catalog=$(mktemp)
        if [ -f "$OUTCOMES_CATALOG" ]; then
            jq --argjson analyzed "$analyzed" \
                'if .decision_id == ($analyzed.decision_id) then $analyzed else . end' \
                "$OUTCOMES_CATALOG" > "$temp_catalog"
            mv "$temp_catalog" "$OUTCOMES_CATALOG"
        fi

        ((analyzed_count++))
        echo "Analyzed $analyzed_count / $outcome_count" >&2
    done

    echo "Pattern learning complete. Analyzed $analyzed_count outcomes." >&2

    # Generate improvement suggestions
    suggest_improvements
}

##############################################################################
# initialize_learned_patterns: Create initial learned patterns file
##############################################################################
initialize_learned_patterns() {
    cat > "$LEARNED_PATTERNS" <<'EOF'
{
  "version": "1.0.0",
  "last_updated": "",
  "learning_stats": {
    "total_decisions_analyzed": 0,
    "successful_routings": 0,
    "failed_routings": 0,
    "reassignments": 0,
    "average_routing_accuracy": 0,
    "average_confidence_calibration": 0,
    "learning_iterations": 0
  },
  "expert_patterns": {
    "development": {
      "success_indicators": [],
      "failure_indicators": [],
      "performance_metrics": {
        "total_tasks": 0,
        "success_rate": 0
      }
    },
    "security": {
      "success_indicators": [],
      "failure_indicators": [],
      "performance_metrics": {
        "total_tasks": 0,
        "success_rate": 0
      }
    },
    "inventory": {
      "success_indicators": [],
      "failure_indicators": [],
      "performance_metrics": {
        "total_tasks": 0,
        "success_rate": 0
      }
    }
  },
  "routing_improvements": [],
  "global_insights": []
}
EOF
}

##############################################################################
# update_learned_patterns: Update patterns file with new learnings
##############################################################################
update_learned_patterns() {
    local analyzed_outcome="$1"

    # Extract key data
    local expert=$(echo "$analyzed_outcome" | jq -r '.routing.primary_expert')
    local success=$(echo "$analyzed_outcome" | jq -r '.outcome.success')
    local patterns=$(echo "$analyzed_outcome" | jq -r '.patterns_discovered // []')

    # Update learned patterns (simplified - in production would be more sophisticated)
    local temp_patterns=$(mktemp)

    jq \
        --arg expert "$expert" \
        --argjson success "$success" \
        --argjson patterns "$patterns" \
        '
        .learning_stats.total_decisions_analyzed += 1 |
        .learning_stats.learning_iterations += 1 |
        .last_updated = (now | todate) |
        if $success then
            .learning_stats.successful_routings += 1
        else
            .learning_stats.failed_routings += 1
        end |
        .learning_stats.average_routing_accuracy = (
            .learning_stats.successful_routings / .learning_stats.total_decisions_analyzed
        )
        ' "$LEARNED_PATTERNS" > "$temp_patterns"

    mv "$temp_patterns" "$LEARNED_PATTERNS"
}

##############################################################################
# suggest_improvements: Generate routing improvement suggestions
##############################################################################
suggest_improvements() {
    echo "Generating routing improvement suggestions..." >&2

    # Gather data for analysis
    local learned_patterns=$(cat "$LEARNED_PATTERNS")
    local recent_outcomes=$(tail -20 "$OUTCOMES_CATALOG" 2>/dev/null | jq -s '.' || echo "[]")

    # Prepare data for LLM
    local improvement_data=$(jq -n \
        --argjson patterns "$learned_patterns" \
        --argjson outcomes "$recent_outcomes" \
        '{
            learned_patterns: $patterns,
            recent_outcomes: $outcomes
        }')

    # Call LLM with suggest-improvements prompt
    local suggestions=$(call_llm \
        "$PROMPTS_DIR/suggest-improvements.md" \
        "$improvement_data")

    # Append suggestions to learned patterns
    local temp_patterns=$(mktemp)
    jq \
        --argjson suggestions "$suggestions" \
        '.routing_improvements += [$suggestions]' \
        "$LEARNED_PATTERNS" > "$temp_patterns"

    mv "$temp_patterns" "$LEARNED_PATTERNS"

    echo "Improvement suggestions generated and saved." >&2
}

##############################################################################
# Main execution
##############################################################################
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    case "${1:-learn}" in
        learn)
            learn_from_outcomes
            ;;
        analyze)
            if [ $# -lt 2 ]; then
                echo "Usage: $0 analyze <outcome_json>"
                exit 1
            fi
            analyze_outcome "$2"
            ;;
        suggest)
            suggest_improvements
            ;;
        *)
            echo "Usage: $0 {learn|analyze|suggest}"
            exit 1
            ;;
    esac
fi
