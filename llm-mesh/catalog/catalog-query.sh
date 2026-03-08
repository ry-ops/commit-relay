#!/bin/bash
# Catalog Discovery API - Query the LLM Mesh catalog

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_DIR="$SCRIPT_DIR/agents"
TOOLS_DIR="$SCRIPT_DIR/tools"

##############################################################################
# query_agents: Find agents by capability or specialization
##############################################################################
query_agents() {
    local filter_type="$1"
    local filter_value="$2"

    case "$filter_type" in
        --capability)
            find "$AGENTS_DIR" -name "*.json" -exec jq -r \
                --arg cap "$filter_value" \
                'select(.capabilities | index($cap)) | .agent_id' {} \;
            ;;
        --specialization)
            find "$AGENTS_DIR" -name "*.json" -exec jq -r \
                --arg spec "$filter_value" \
                'select(.specialization == $spec) | .agent_id' {} \;
            ;;
        --all)
            find "$AGENTS_DIR" -name "*.json" -exec jq -r '.agent_id' {} \;
            ;;
        *)
            echo "Unknown filter: $filter_type" >&2
            return 1
            ;;
    esac
}

##############################################################################
# query_tools: Find tools by category or agent
##############################################################################
query_tools() {
    local filter_type="$1"
    local filter_value="$2"

    case "$filter_type" in
        --category)
            find "$TOOLS_DIR" -name "*.json" -exec jq -r \
                --arg cat "$filter_value" \
                'select(.category == $cat) | .tool_id' {} \;
            ;;
        --agent)
            find "$TOOLS_DIR" -name "*.json" -exec jq -r \
                --arg agent "$filter_value" \
                'select(.used_by_agents | index($agent)) | .tool_id' {} \;
            ;;
        --all)
            find "$TOOLS_DIR" -name "*.json" -exec jq -r '.tool_id' {} \;
            ;;
        *)
            echo "Unknown filter: $filter_type" >&2
            return 1
            ;;
    esac
}

##############################################################################
# recommend_agent: Recommend best agent for a task
##############################################################################
recommend_agent() {
    local task_description="$1"

    # Simple keyword-based recommendation (in production, use LLM)
    local task_lower=$(echo "$task_description" | tr '[:upper:]' '[:lower:]')

    if echo "$task_lower" | grep -qi "security\|cve\|vulnerability"; then
        echo "security-master"
    elif echo "$task_lower" | grep -qi "implement\|feature\|bug\|code"; then
        echo "development-master"
    elif echo "$task_lower" | grep -qi "document\|catalog\|inventory"; then
        echo "inventory-master"
    elif echo "$task_lower" | grep -qi "build\|deploy\|test\|ci"; then
        echo "cicd-master"
    elif echo "$task_lower" | grep -qi "monitor\|dashboard\|metrics"; then
        echo "dashboard-agent"
    else
        echo "coordinator-master"
    fi
}

##############################################################################
# get_agent_info: Get detailed info about an agent
##############################################################################
get_agent_info() {
    local agent_id="$1"
    local agent_file="$AGENTS_DIR/$agent_id.json"

    if [ -f "$agent_file" ]; then
        cat "$agent_file" | jq '.'
    else
        echo "{\"error\": \"Agent not found: $agent_id\"}"
        return 1
    fi
}

##############################################################################
# get_tool_info: Get detailed info about a tool
##############################################################################
get_tool_info() {
    local tool_id="$1"
    local tool_file="$TOOLS_DIR/$tool_id.json"

    if [ -f "$tool_file" ]; then
        cat "$tool_file" | jq '.'
    else
        echo "{\"error\": \"Tool not found: $tool_id\"}"
        return 1
    fi
}

##############################################################################
# Main execution
##############################################################################
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    case "${1:-help}" in
        agents)
            query_agents "${2:---all}" "${3:-}"
            ;;
        tools)
            query_tools "${2:---all}" "${3:-}"
            ;;
        recommend-agent)
            recommend_agent "${2:-}"
            ;;
        agent-info)
            get_agent_info "$2"
            ;;
        tool-info)
            get_tool_info "$2"
            ;;
        help|--help|-h)
            cat <<EOF
Catalog Discovery API

Usage: $0 <command> [options]

Commands:
  agents [--capability|--specialization|--all] [value]
      Query agents by capability or specialization

  tools [--category|--agent|--all] [value]
      Query tools by category or agent

  recommend-agent <task_description>
      Get recommended agent for a task

  agent-info <agent_id>
      Get detailed information about an agent

  tool-info <tool_id>
      Get detailed information about a tool

Examples:
  $0 agents --capability "feature_implementation"
  $0 tools --category "testing"
  $0 recommend-agent "Fix security vulnerability"
  $0 agent-info development-master
EOF
            ;;
        *)
            echo "Unknown command: $1"
            echo "Run '$0 help' for usage information"
            exit 1
            ;;
    esac
fi
