#!/bin/bash
# LLM Client - Makes actual API calls to LLM providers
# Integrates with gateway for model selection and cost tracking

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATEWAY_HOME="$SCRIPT_DIR"
LLM_MESH_HOME="$(dirname "$GATEWAY_HOME")"
CONFIG_LOADER="$LLM_MESH_HOME/config/load-env.sh"
MODEL_ROUTER="$GATEWAY_HOME/model-router/select-model.sh"
COST_TRACKER="$GATEWAY_HOME/middleware/cost-tracking.sh"

# Make cost tracker executable
[ -f "$COST_TRACKER" ] && chmod +x "$COST_TRACKER"

# Load environment
source "$CONFIG_LOADER" load 2>/dev/null || true

##############################################################################
# call_anthropic: Make API call to Anthropic Claude
##############################################################################
call_anthropic() {
    local model="$1"
    local prompt="$2"
    local max_tokens="${3:-4096}"
    local temperature="${4:-0.7}"

    if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
        echo "Error: ANTHROPIC_API_KEY not set" >&2
        return 1
    fi

    # Map model names to Anthropic API model IDs
    local api_model=""
    case "$model" in
        claude-opus-4)
            api_model="claude-opus-4-20250514"
            ;;
        claude-sonnet-4)
            api_model="claude-sonnet-4-20250514"
            ;;
        claude-haiku)
            api_model="claude-3-5-haiku-20241022"
            ;;
        *)
            api_model="$model"  # Use as-is if already full name
            ;;
    esac

    local start_time=$(date +%s)
    local start_ms=$((start_time * 1000))

    local response=$(curl -s https://api.anthropic.com/v1/messages \
        -H "x-api-key: $ANTHROPIC_API_KEY" \
        -H "anthropic-version: 2023-06-01" \
        -H "content-type: application/json" \
        -d "{
            \"model\": \"$api_model\",
            \"max_tokens\": $max_tokens,
            \"temperature\": $temperature,
            \"messages\": [{
                \"role\": \"user\",
                \"content\": $(echo "$prompt" | jq -Rs .)
            }]
        }")

    local end_time=$(date +%s)
    local end_ms=$((end_time * 1000))
    local latency=$((end_ms - start_ms))

    # Check for errors
    if echo "$response" | jq -e '.error' >/dev/null 2>&1; then
        echo "Error from Anthropic API:" >&2
        echo "$response" | jq -r '.error.message' >&2
        return 1
    fi

    # Extract response
    local content=$(echo "$response" | jq -r '.content[0].text')
    local input_tokens=$(echo "$response" | jq -r '.usage.input_tokens')
    local output_tokens=$(echo "$response" | jq -r '.usage.output_tokens')

    # Calculate cost using cost tracker
    local cost=0
    if [ -f "$COST_TRACKER" ]; then
        cost=$(bash "$COST_TRACKER" cost "$model" "$input_tokens" "$output_tokens")
    else
        cost=$(bash "$MODEL_ROUTER" estimate "$model" "api-call" "$input_tokens" "$output_tokens")
    fi

    # Log cost to tracking system
    if [ -f "$COST_TRACKER" ]; then
        bash "$COST_TRACKER" log \
            "${TASK_ID:-anonymous}" \
            "${TASK_TYPE:-api-call}" \
            "$model" \
            "$input_tokens" \
            "$output_tokens" \
            "$latency" \
            "true" >/dev/null 2>&1 || true
    fi

    # Return structured response
    jq -n \
        --arg model "$api_model" \
        --arg content "$content" \
        --argjson input "$input_tokens" \
        --argjson output "$output_tokens" \
        --argjson cost "$cost" \
        --argjson latency "$latency" \
        '{
            provider: "anthropic",
            model: $model,
            content: $content,
            usage: {
                input_tokens: $input,
                output_tokens: $output,
                total_tokens: ($input + $output)
            },
            cost: $cost,
            latency_ms: $latency,
            success: true
        }'
}

##############################################################################
# call_openai: Make API call to OpenAI GPT
##############################################################################
call_openai() {
    local model="$1"
    local prompt="$2"
    local max_tokens="${3:-4096}"
    local temperature="${4:-0.7}"

    if [ -z "${OPENAI_API_KEY:-}" ]; then
        echo "Error: OPENAI_API_KEY not set" >&2
        return 1
    fi

    # Map model names to OpenAI API model IDs
    local api_model=""
    case "$model" in
        gpt-4-turbo)
            api_model="gpt-4-turbo-2024-04-09"
            ;;
        gpt-4o)
            api_model="gpt-4o"
            ;;
        gpt-3.5-turbo)
            api_model="gpt-3.5-turbo"
            ;;
        *)
            api_model="$model"
            ;;
    esac

    local start_time=$(date +%s)
    local start_ms=$((start_time * 1000))

    local response=$(curl -s https://api.openai.com/v1/chat/completions \
        -H "Authorization: Bearer $OPENAI_API_KEY" \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"$api_model\",
            \"max_tokens\": $max_tokens,
            \"temperature\": $temperature,
            \"messages\": [{
                \"role\": \"user\",
                \"content\": $(echo "$prompt" | jq -Rs .)
            }]
        }")

    local end_time=$(date +%s)
    local end_ms=$((end_time * 1000))
    local latency=$((end_ms - start_ms))

    # Check for errors
    if echo "$response" | jq -e '.error' >/dev/null 2>&1; then
        echo "Error from OpenAI API:" >&2
        echo "$response" | jq -r '.error.message' >&2
        return 1
    fi

    # Extract response
    local content=$(echo "$response" | jq -r '.choices[0].message.content')
    local input_tokens=$(echo "$response" | jq -r '.usage.prompt_tokens')
    local output_tokens=$(echo "$response" | jq -r '.usage.completion_tokens')

    # Calculate cost using cost tracker
    local cost=0
    if [ -f "$COST_TRACKER" ]; then
        cost=$(bash "$COST_TRACKER" cost "$model" "$input_tokens" "$output_tokens")
    else
        cost=$(bash "$MODEL_ROUTER" estimate "$model" "api-call" "$input_tokens" "$output_tokens")
    fi

    # Log cost to tracking system
    if [ -f "$COST_TRACKER" ]; then
        bash "$COST_TRACKER" log \
            "${TASK_ID:-anonymous}" \
            "${TASK_TYPE:-api-call}" \
            "$model" \
            "$input_tokens" \
            "$output_tokens" \
            "$latency" \
            "true" >/dev/null 2>&1 || true
    fi

    # Return structured response
    jq -n \
        --arg model "$api_model" \
        --arg content "$content" \
        --argjson input "$input_tokens" \
        --argjson output "$output_tokens" \
        --argjson cost "$cost" \
        --argjson latency "$latency" \
        '{
            provider: "openai",
            model: $model,
            content: $content,
            usage: {
                input_tokens: $input,
                output_tokens: $output,
                total_tokens: ($input + $output)
            },
            cost: $cost,
            latency_ms: $latency,
            success: true
        }'
}

##############################################################################
# call_local: Make API call to local model (Ollama)
##############################################################################
call_local() {
    local model="$1"
    local prompt="$2"
    local endpoint="${OLLAMA_ENDPOINT:-http://localhost:11434}"

    local start_time=$(date +%s)
    local start_ms=$((start_time * 1000))

    local response=$(curl -s "$endpoint/api/generate" \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"$model\",
            \"prompt\": $(echo "$prompt" | jq -Rs .),
            \"stream\": false
        }")

    local end_time=$(date +%s)
    local end_ms=$((end_time * 1000))
    local latency=$((end_ms - start_ms))

    # Check for errors
    if [ -z "$response" ]; then
        echo "Error: No response from local model endpoint" >&2
        return 1
    fi

    # Extract response
    local content=$(echo "$response" | jq -r '.response')

    # Return structured response (no cost for local)
    jq -n \
        --arg model "$model" \
        --arg content "$content" \
        --argjson latency "$latency" \
        '{
            provider: "local",
            model: $model,
            content: $content,
            usage: {
                input_tokens: 0,
                output_tokens: 0,
                total_tokens: 0
            },
            cost: 0,
            latency_ms: $latency,
            success: true
        }'
}

##############################################################################
# call_llm: Main entry point - selects model and makes call
##############################################################################
call_llm() {
    local task_type="$1"
    local prompt="$2"
    local max_tokens="${3:-4096}"
    local temperature="${4:-0.7}"
    local quality_req="${5:-balanced}"
    local task_id="${TASK_ID:-task-$(date +%s)}"

    # Export for nested calls
    export TASK_ID="$task_id"
    export TASK_TYPE="$task_type"

    # Select optimal model
    local selected_model=$(bash "$MODEL_ROUTER" select "$task_type" "999" "$quality_req")

    echo "Selected model: $selected_model for task type: $task_type" >&2

    # Estimate tokens and check budget
    if [ -f "$COST_TRACKER" ]; then
        local estimated_tokens=$(bash "$COST_TRACKER" estimate "$prompt" "$selected_model")
        local budget_check=$(bash "$COST_TRACKER" check "$task_id" "$estimated_tokens")

        if [[ "$budget_check" != "true" ]]; then
            echo "Budget check failed: $budget_check" >&2
            jq -n \
                --arg model "$selected_model" \
                --arg error "Budget exceeded: $budget_check" \
                '{
                    provider: "none",
                    model: $model,
                    content: "",
                    usage: {input_tokens: 0, output_tokens: 0, total_tokens: 0},
                    cost: 0,
                    latency_ms: 0,
                    success: false,
                    error: $error
                }'
            return 1
        fi
    fi

    # Determine provider
    local provider=$(jq -r \
        --arg model "$selected_model" \
        '.models[$model].provider // "anthropic"' \
        "$GATEWAY_HOME/catalog/models.json")

    # Make API call
    local response=""
    case "$provider" in
        anthropic)
            response=$(call_anthropic "$selected_model" "$prompt" "$max_tokens" "$temperature")
            ;;
        openai)
            response=$(call_openai "$selected_model" "$prompt" "$max_tokens" "$temperature")
            ;;
        local)
            response=$(call_local "$selected_model" "$prompt")
            ;;
        *)
            echo "Error: Unknown provider: $provider" >&2
            return 1
            ;;
    esac

    # Record performance
    local quality_score=0.8  # Default, should be evaluated
    local cost=$(echo "$response" | jq -r '.cost')
    local latency=$(echo "$response" | jq -r '.latency_ms')
    local total_tokens=$(echo "$response" | jq -r '.usage.total_tokens')

    bash "$MODEL_ROUTER" record "$selected_model" "$task_type" "$quality_score" "$cost" "$latency"

    # Record usage against budgets
    if [ -f "$COST_TRACKER" ]; then
        bash "$COST_TRACKER" record "$task_id" "$total_tokens" "$cost" >/dev/null 2>&1 || true
    fi

    # Return response
    echo "$response"
}

##############################################################################
# Main execution
##############################################################################
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    case "${1:-help}" in
        call)
            call_llm "${2:-routing-analysis}" "${3:-Hello}" "${4:-4096}" "${5:-0.7}" "${6:-balanced}"
            ;;
        anthropic)
            call_anthropic "$2" "$3" "${4:-4096}" "${5:-0.7}"
            ;;
        openai)
            call_openai "$2" "$3" "${4:-4096}" "${5:-0.7}"
            ;;
        local)
            call_local "$2" "$3"
            ;;
        test)
            # Test connection to APIs
            echo "Testing LLM API connections..."
            if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
                echo "Testing Anthropic..."
                call_anthropic "claude-haiku" "Say 'API test successful'" 100 0.7 || echo "Anthropic test failed"
            fi
            if [ -n "${OPENAI_API_KEY:-}" ]; then
                echo "Testing OpenAI..."
                call_openai "gpt-3.5-turbo" "Say 'API test successful'" 100 0.7 || echo "OpenAI test failed"
            fi
            ;;
        help|--help|-h)
            cat <<EOF
LLM Client - Makes API calls to LLM providers

Usage: $0 <command> [args]

Commands:
  call <task_type> <prompt> [max_tokens] [temperature] [quality]
      Make intelligent API call with model selection
      Example: $0 call routing-analysis "Analyze this task" 4096 0.7 balanced

  anthropic <model> <prompt> [max_tokens] [temperature]
      Direct call to Anthropic API
      Example: $0 anthropic claude-sonnet-4 "Hello world"

  openai <model> <prompt> [max_tokens] [temperature]
      Direct call to OpenAI API
      Example: $0 openai gpt-4-turbo "Hello world"

  local <model> <prompt>
      Call to local model via Ollama
      Example: $0 local llama2 "Hello world"

  test
      Test API connections

Task Types:
  - routing-analysis
  - pattern-extraction
  - improvement-generation
  - security-analysis
  - code-review
  - general

Quality Levels:
  - economical (fastest, cheapest)
  - balanced (good quality/cost ratio)
  - premium (highest quality)
EOF
            ;;
        *)
            echo "Unknown command: $1"
            echo "Run '$0 help' for usage information"
            exit 1
            ;;
    esac
fi
