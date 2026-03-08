#!/bin/bash
# scripts/lib/few-shot-injector.sh
# Few-shot example injector for agent prompts
#
# Retrieves successful task examples from the knowledge base
# and formats them for injection into master agent prompts.
#
# Usage:
#   source scripts/lib/few-shot-injector.sh
#   examples=$(get_few_shot_examples "development" 3)
#   echo "$examples"

set -euo pipefail

# Configuration
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
KB_DIR="${COMMIT_RELAY_HOME}/coordination/knowledge-base"
TRAINING_EXAMPLES="${KB_DIR}/training-examples/positive-examples.jsonl"

##############################################################################
# get_few_shot_examples: Get formatted few-shot examples for a master agent
# Args:
#   $1: master_type (development|security|inventory|cicd|coordinator)
#   $2: num_examples (default: 3)
# Returns: Markdown-formatted examples
##############################################################################
get_few_shot_examples() {
    local master_type="${1:-development}"
    local num_examples="${2:-3}"

    # Check if examples file exists
    if [[ ! -f "$TRAINING_EXAMPLES" ]]; then
        echo "<!-- No few-shot examples available -->"
        return 0
    fi

    # Filter examples for this master type and get top N by success score
    local examples=$(jq -r --arg master "$master_type" --argjson num "$num_examples" '
        select(.master == $master and .outcome == "success") |
        {
            task_type: .task_type,
            description: .description,
            approach: .approach,
            result: .result,
            tokens_used: .tokens_used
        }
    ' "$TRAINING_EXAMPLES" 2>/dev/null | head -n $((num_examples * 6)) | jq -s ".[:$num_examples]")

    # Check if we got any examples
    local count=$(echo "$examples" | jq 'length')
    if [[ "$count" == "0" ]] || [[ -z "$examples" ]]; then
        echo "<!-- No few-shot examples available for $master_type -->"
        return 0
    fi

    # Format as markdown
    echo "## Few-Shot Examples"
    echo ""
    echo "The following are examples of successful task completions:"
    echo ""

    local i=0
    while IFS= read -r example; do
        ((i++))
        local task_type=$(echo "$example" | jq -r '.task_type // "unknown"')
        local description=$(echo "$example" | jq -r '.description // "No description"')
        local approach=$(echo "$example" | jq -r '.approach // "Standard approach"')
        local result=$(echo "$example" | jq -r '.result // "Completed successfully"')
        local tokens=$(echo "$example" | jq -r '.tokens_used // "N/A"')

        echo "### Example $i: $task_type"
        echo ""
        echo "**Task**: $description"
        echo ""
        echo "**Approach**: $approach"
        echo ""
        echo "**Result**: $result"
        echo ""
        echo "**Tokens Used**: $tokens"
        echo ""
        echo "---"
        echo ""
    done < <(echo "$examples" | jq -c '.[]')
}

##############################################################################
# inject_examples_into_prompt: Inject examples into an agent prompt file
# Args:
#   $1: prompt_file - Path to the agent prompt .md file
#   $2: master_type - Type of master agent
#   $3: num_examples - Number of examples to inject (default: 3)
# Note: Looks for <!-- FEW_SHOT_EXAMPLES --> placeholder in the file
##############################################################################
inject_examples_into_prompt() {
    local prompt_file="$1"
    local master_type="$2"
    local num_examples="${3:-3}"

    if [[ ! -f "$prompt_file" ]]; then
        echo "Error: Prompt file not found: $prompt_file" >&2
        return 1
    fi

    # Get examples
    local examples=$(get_few_shot_examples "$master_type" "$num_examples")

    # Check if placeholder exists
    if grep -q "<!-- FEW_SHOT_EXAMPLES -->" "$prompt_file"; then
        # Replace placeholder with examples
        local temp_file=$(mktemp)
        awk -v examples="$examples" '
            /<!-- FEW_SHOT_EXAMPLES -->/ {
                print examples
                next
            }
            { print }
        ' "$prompt_file" > "$temp_file"
        mv "$temp_file" "$prompt_file"
        echo "Injected $num_examples examples into $prompt_file"
    else
        # Append examples to end of file
        echo "" >> "$prompt_file"
        echo "$examples" >> "$prompt_file"
        echo "Appended $num_examples examples to $prompt_file"
    fi
}

##############################################################################
# get_example_context: Get few-shot context for a specific task
# Args:
#   $1: task_description
#   $2: master_type
# Returns: JSON context with relevant examples
##############################################################################
get_example_context() {
    local task_description="$1"
    local master_type="$2"

    if [[ ! -f "$TRAINING_EXAMPLES" ]]; then
        echo '{"examples": []}'
        return 0
    fi

    # Get examples for this master type
    local examples=$(jq -c --arg master "$master_type" '
        select(.master == $master and .outcome == "success") |
        {
            task_type: .task_type,
            description: .description,
            approach: .approach,
            key_decisions: .key_decisions,
            tokens_used: .tokens_used
        }
    ' "$TRAINING_EXAMPLES" 2>/dev/null | head -5 | jq -s '.')

    echo "{\"examples\": $examples}"
}

##############################################################################
# Main execution (if run directly)
##############################################################################
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ $# -lt 1 ]]; then
        echo "Usage: $0 <master_type> [num_examples]"
        echo "       $0 --inject <prompt_file> <master_type> [num_examples]"
        echo ""
        echo "Examples:"
        echo "  $0 development 3"
        echo "  $0 --inject .claude/agents/development-master.md development 3"
        exit 1
    fi

    if [[ "$1" == "--inject" ]]; then
        inject_examples_into_prompt "$2" "$3" "${4:-3}"
    else
        get_few_shot_examples "$1" "${2:-3}"
    fi
fi
