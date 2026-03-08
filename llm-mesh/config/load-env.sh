#!/bin/bash
# Environment Configuration Loader
# Loads and validates LLM Mesh configuration

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLM_MESH_HOME="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${LLM_MESH_HOME}/.env"
ENV_EXAMPLE="${LLM_MESH_HOME}/.env.example"

##############################################################################
# load_env: Load environment variables from .env file
##############################################################################
load_env() {
    if [ -f "$ENV_FILE" ]; then
        # Load .env file
        set -a
        source "$ENV_FILE"
        set +a
        echo "✓ Environment loaded from $ENV_FILE" >&2
    else
        echo "⚠ No .env file found at $ENV_FILE" >&2
        echo "  Copy .env.example to .env and configure your API keys" >&2
        return 1
    fi
}

##############################################################################
# validate_config: Validate required configuration
##############################################################################
validate_config() {
    local errors=0

    echo "Validating LLM Mesh configuration..." >&2

    # Check primary provider API key
    case "${LLM_PRIMARY_PROVIDER:-anthropic}" in
        anthropic)
            if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
                echo "✗ ANTHROPIC_API_KEY is required when using Anthropic as primary provider" >&2
                errors=$((errors + 1))
            else
                echo "✓ Anthropic API key configured" >&2
            fi
            ;;
        openai)
            if [ -z "${OPENAI_API_KEY:-}" ]; then
                echo "✗ OPENAI_API_KEY is required when using OpenAI as primary provider" >&2
                errors=$((errors + 1))
            else
                echo "✓ OpenAI API key configured" >&2
            fi
            ;;
        local)
            if [ -z "${OLLAMA_ENDPOINT:-}" ]; then
                echo "✗ OLLAMA_ENDPOINT is required when using local models" >&2
                errors=$((errors + 1))
            else
                echo "✓ Local model endpoint configured: ${OLLAMA_ENDPOINT}" >&2
            fi
            ;;
    esac

    # Check fallback provider
    if [ -n "${LLM_FALLBACK_PROVIDER:-}" ]; then
        case "$LLM_FALLBACK_PROVIDER" in
            anthropic)
                [ -n "${ANTHROPIC_API_KEY:-}" ] && echo "✓ Fallback provider (Anthropic) configured" >&2
                ;;
            openai)
                [ -n "${OPENAI_API_KEY:-}" ] && echo "✓ Fallback provider (OpenAI) configured" >&2
                ;;
        esac
    fi

    # Validate numeric values
    if [ -n "${LLM_MAX_COST_PER_TASK:-}" ]; then
        if ! echo "${LLM_MAX_COST_PER_TASK}" | grep -qE '^[0-9]+\.?[0-9]*$'; then
            echo "✗ LLM_MAX_COST_PER_TASK must be a number" >&2
            errors=$((errors + 1))
        fi
    fi

    if [ -n "${SAFETY_MIN_QUALITY_SCORE:-}" ]; then
        if ! echo "${SAFETY_MIN_QUALITY_SCORE}" | grep -qE '^0?\.[0-9]+$|^1\.0$'; then
            echo "✗ SAFETY_MIN_QUALITY_SCORE must be between 0.0 and 1.0" >&2
            errors=$((errors + 1))
        fi
    fi

    if [ $errors -eq 0 ]; then
        echo "✓ Configuration validated successfully" >&2
        return 0
    else
        echo "✗ Configuration validation failed with $errors error(s)" >&2
        return 1
    fi
}

##############################################################################
# get_config: Get a configuration value with default
##############################################################################
get_config() {
    local key="$1"
    local default="${2:-}"

    # Try environment variable first
    local value="${!key:-}"

    # Use default if not set
    if [ -z "$value" ]; then
        value="$default"
    fi

    echo "$value"
}

##############################################################################
# show_config: Display current configuration
##############################################################################
show_config() {
    cat <<EOF
LLM Mesh Configuration
=====================

LLM Providers:
  Primary Provider: $(get_config LLM_PRIMARY_PROVIDER anthropic)
  Fallback Provider: $(get_config LLM_FALLBACK_PROVIDER none)
  Max Cost Per Task: \$$(get_config LLM_MAX_COST_PER_TASK 0.50)
  Default Quality: $(get_config LLM_DEFAULT_QUALITY balanced)

API Keys:
  Anthropic: $([ -n "${ANTHROPIC_API_KEY:-}" ] && echo "✓ Configured" || echo "✗ Not set")
  OpenAI: $([ -n "${OPENAI_API_KEY:-}" ] && echo "✓ Configured" || echo "✗ Not set")

Safety & Quality:
  PII Filter: $(get_config SAFETY_ENABLE_PII_FILTER true)
  Injection Filter: $(get_config SAFETY_ENABLE_INJECTION_FILTER true)
  Secrets Filter: $(get_config SAFETY_ENABLE_SECRETS_FILTER true)
  Min Quality Score: $(get_config SAFETY_MIN_QUALITY_SCORE 0.7)
  Default Action: $(get_config SAFETY_DEFAULT_ACTION block)

MoE Learning:
  Learning Enabled: $(get_config MOE_ENABLE_LEARNING true)
  Min Confidence: $(get_config MOE_MIN_CONFIDENCE 0.3)
  Batch Size: $(get_config MOE_LEARNING_BATCH_SIZE 10)

Performance:
  Tracking Enabled: $(get_config PERF_ENABLE_TRACKING true)
  Log Level: $(get_config LOG_LEVEL info)
  Retention Days: $(get_config METRICS_RETENTION_DAYS 30)

EOF
}

##############################################################################
# Main execution
##############################################################################
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    case "${1:-load}" in
        load)
            load_env
            ;;
        validate)
            load_env && validate_config
            ;;
        show)
            load_env
            show_config
            ;;
        get)
            load_env
            get_config "$2" "${3:-}"
            ;;
        help|--help|-h)
            cat <<EOF
Environment Configuration Loader

Usage: $0 <command> [args]

Commands:
  load        Load environment from .env file
  validate    Load and validate configuration
  show        Display current configuration
  get <key>   Get specific configuration value

Examples:
  $0 load
  $0 validate
  $0 show
  $0 get ANTHROPIC_API_KEY
EOF
            ;;
        *)
            echo "Unknown command: $1"
            echo "Run '$0 help' for usage information"
            exit 1
            ;;
    esac
fi
