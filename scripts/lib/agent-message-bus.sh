#!/bin/bash
# scripts/lib/agent-message-bus.sh
# Agent Message Bus for Multi-Agent Coordination
# Week 7: Q1 Implementation - Multi-Agent Coordination
#
# Purpose: Enable inter-agent communication and collaboration
# Implements message passing, pub/sub, and collaboration patterns
#
# Functions:
# - message_bus_init(): Initialize message infrastructure
# - send_message(): Post message to another agent
# - receive_messages(): Check for incoming messages
# - subscribe_topic(): Subscribe to event topics
# - request_collaboration(): Request help from another agent

set -euo pipefail

# Get script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# Load dependencies
source "$COMMIT_RELAY_HOME/scripts/lib/logging.sh" 2>/dev/null || {
    log_info() { echo "[INFO] $1"; }
    log_warn() { echo "[WARN] $1"; }
    log_error() { echo "[ERROR] $1"; }
}

# Configuration
MESSAGE_BUS_DIR="$COMMIT_RELAY_HOME/coordination/message-bus"
QUEUES_DIR="$MESSAGE_BUS_DIR/queues"
TOPICS_DIR="$MESSAGE_BUS_DIR/topics"
SUBSCRIPTIONS_DIR="$MESSAGE_BUS_DIR/subscriptions"
MESSAGE_LOG="$MESSAGE_BUS_DIR/message-log.jsonl"

#------------------------------------------------------------------------------
# message_bus_init()
# Initialize message bus infrastructure
#
# Args:
#   $1 - agent_id: ID of the agent initializing
#
# Returns:
#   0 on success
#------------------------------------------------------------------------------
message_bus_init() {
    local agent_id="$1"

    log_info "[MessageBus] Initializing for agent: $agent_id"

    # Create directories
    mkdir -p "$QUEUES_DIR" "$TOPICS_DIR" "$SUBSCRIPTIONS_DIR"

    # Create agent's message queue
    local queue_dir="$QUEUES_DIR/$agent_id"
    mkdir -p "$queue_dir/inbox" "$queue_dir/sent" "$queue_dir/read"

    # Create agent metadata
    local metadata=$(jq -n \
        --arg agent_id "$agent_id" \
        --arg initialized_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '{
            agent_id: $agent_id,
            queue_path: "coordination/message-bus/queues/" + $agent_id,
            initialized_at: $initialized_at,
            status: "active"
        }')

    echo "$metadata" > "$queue_dir/metadata.json"

    log_info "[MessageBus] Initialized for: $agent_id"

    return 0
}

#------------------------------------------------------------------------------
# send_message()
# Send message to another agent
#
# Args:
#   $1 - from_agent_id
#   $2 - to_agent_id
#   $3 - message_type: request, response, notification, query, handoff
#   $4 - message_body: JSON string
#
# Returns:
#   Message ID
#------------------------------------------------------------------------------
send_message() {
    local from_agent="$1"
    local to_agent="$2"
    local msg_type="$3"
    local msg_body="$4"

    local message_id="msg-$(date +%s)-$(uuidgen | cut -d- -f1)"

    log_info "[MessageBus] Sending $msg_type from $from_agent to $to_agent (ID: $message_id)"

    # Create message
    local message=$(jq -n \
        --arg msg_id "$message_id" \
        --arg from "$from_agent" \
        --arg to "$to_agent" \
        --arg type "$msg_type" \
        --argjson body "$msg_body" \
        --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '{
            message_id: $msg_id,
            from: $from,
            to: $to,
            type: $type,
            body: $body,
            timestamp: $timestamp,
            status: "sent"
        }')

    # Deliver to recipient's inbox
    local recipient_queue="$QUEUES_DIR/$to_agent/inbox"

    if [ ! -d "$recipient_queue" ]; then
        log_warn "[MessageBus] Recipient queue not found, initializing: $to_agent"
        message_bus_init "$to_agent"
    fi

    echo "$message" > "$recipient_queue/$message_id.json"

    # Log message in sender's sent folder
    echo "$message" > "$QUEUES_DIR/$from_agent/sent/$message_id.json"

    # Log to message log
    echo "$message" >> "$MESSAGE_LOG"

    log_info "[MessageBus] Message delivered: $message_id"

    echo "$message_id"
}

#------------------------------------------------------------------------------
# receive_messages()
# Check for and retrieve messages for an agent
#
# Args:
#   $1 - agent_id
#   $2 - message_type_filter (optional): only return specific type
#
# Returns:
#   JSON array of messages
#------------------------------------------------------------------------------
receive_messages() {
    local agent_id="$1"
    local type_filter="${2:-}"

    local inbox="$QUEUES_DIR/$agent_id/inbox"

    if [ ! -d "$inbox" ]; then
        echo "[]"
        return
    fi

    # Get all messages
    local messages=()
    for msg_file in "$inbox"/*.json; do
        if [ -f "$msg_file" ]; then
            local msg=$(cat "$msg_file")

            # Apply type filter if specified
            if [ -n "$type_filter" ]; then
                local msg_type=$(echo "$msg" | jq -r '.type')
                if [ "$msg_type" != "$type_filter" ]; then
                    continue
                fi
            fi

            messages+=("$msg")

            # Move to read folder
            local msg_id=$(basename "$msg_file")
            mv "$msg_file" "$QUEUES_DIR/$agent_id/read/"
        fi
    done

    # Convert to JSON array
    if [ ${#messages[@]} -eq 0 ]; then
        echo "[]"
    else
        printf '%s\n' "${messages[@]}" | jq -s '.'
    fi
}

#------------------------------------------------------------------------------
# subscribe_topic()
# Subscribe an agent to a topic
#
# Args:
#   $1 - agent_id
#   $2 - topic: Topic name
#
# Returns:
#   0 on success
#------------------------------------------------------------------------------
subscribe_topic() {
    local agent_id="$1"
    local topic="$2"

    log_info "[MessageBus] Agent $agent_id subscribing to topic: $topic"

    # Create topic if doesn't exist
    local topic_dir="$TOPICS_DIR/$topic"
    mkdir -p "$topic_dir"

    # Add subscription
    local subscription_file="$SUBSCRIPTIONS_DIR/$agent_id.json"

    if [ ! -f "$subscription_file" ]; then
        jq -n --arg agent "$agent_id" '{agent_id: $agent, topics: []}' > "$subscription_file"
    fi

    # Add topic to subscriptions
    local updated=$(cat "$subscription_file" | jq --arg topic "$topic" '.topics += [$topic] | .topics |= unique')
    echo "$updated" > "$subscription_file"

    log_info "[MessageBus] Subscription added: $agent_id → $topic"

    return 0
}

#------------------------------------------------------------------------------
# publish_to_topic()
# Publish message to a topic (broadcast to subscribers)
#
# Args:
#   $1 - from_agent_id
#   $2 - topic
#   $3 - message_body: JSON string
#
# Returns:
#   Number of subscribers notified
#------------------------------------------------------------------------------
publish_to_topic() {
    local from_agent="$1"
    local topic="$2"
    local msg_body="$3"

    log_info "[MessageBus] Publishing to topic: $topic from $from_agent"

    # Find subscribers
    local subscribers=()
    for sub_file in "$SUBSCRIPTIONS_DIR"/*.json; do
        if [ -f "$sub_file" ]; then
            local topics=$(cat "$sub_file" | jq -r '.topics[]')
            if echo "$topics" | grep -q "^$topic$"; then
                local subscriber=$(cat "$sub_file" | jq -r '.agent_id')
                subscribers+=("$subscriber")
            fi
        fi
    done

    # Publish to each subscriber
    local count=0
    for subscriber in "${subscribers[@]}"; do
        send_message "$from_agent" "$subscriber" "notification" "$msg_body" >/dev/null
        count=$((count + 1))
    done

    log_info "[MessageBus] Published to $count subscribers"

    echo "$count"
}

#------------------------------------------------------------------------------
# request_collaboration()
# Request collaboration from another agent
#
# Args:
#   $1 - from_agent_id
#   $2 - to_agent_id
#   $3 - task_description: What help is needed
#   $4 - context: JSON with task context
#
# Returns:
#   Collaboration request ID
#------------------------------------------------------------------------------
request_collaboration() {
    local from_agent="$1"
    local to_agent="$2"
    local task_desc="$3"
    local context="$4"

    log_info "[MessageBus] Collaboration request: $from_agent → $to_agent"

    local request_body=$(jq -n \
        --arg task "$task_desc" \
        --argjson ctx "$context" \
        '{
            collaboration_type: "task_assistance",
            task_description: $task,
            context: $ctx,
            expects_response: true
        }')

    local request_id=$(send_message "$from_agent" "$to_agent" "request" "$request_body")

    log_info "[MessageBus] Collaboration request sent: $request_id"

    echo "$request_id"
}

#------------------------------------------------------------------------------
# handoff_task()
# Hand off a task to another agent
#
# Args:
#   $1 - from_agent_id
#   $2 - to_agent_id
#   $3 - task_spec: JSON task specification
#   $4 - handoff_reason: Why task is being handed off
#
# Returns:
#   Handoff message ID
#------------------------------------------------------------------------------
handoff_task() {
    local from_agent="$1"
    local to_agent="$2"
    local task_spec="$3"
    local reason="$4"

    log_info "[MessageBus] Task handoff: $from_agent → $to_agent (reason: $reason)"

    local handoff_body=$(jq -n \
        --argjson task "$task_spec" \
        --arg reason "$reason" \
        '{
            handoff_type: "task_transfer",
            task_spec: $task,
            handoff_reason: $reason,
            expects_acknowledgment: true
        }')

    local handoff_id=$(send_message "$from_agent" "$to_agent" "handoff" "$handoff_body")

    log_info "[MessageBus] Task handed off: $handoff_id"

    echo "$handoff_id"
}

#------------------------------------------------------------------------------
# send_response()
# Send response to a previous request
#
# Args:
#   $1 - from_agent_id
#   $2 - to_agent_id
#   $3 - in_response_to: Original message ID
#   $4 - response_body: JSON response data
#
# Returns:
#   Response message ID
#------------------------------------------------------------------------------
send_response() {
    local from_agent="$1"
    local to_agent="$2"
    local original_msg_id="$3"
    local response_body="$4"

    local response=$(echo "$response_body" | jq --arg orig "$original_msg_id" '. + {in_response_to: $orig}')

    local response_id=$(send_message "$from_agent" "$to_agent" "response" "$response")

    log_info "[MessageBus] Response sent: $response_id (to: $original_msg_id)"

    echo "$response_id"
}

#------------------------------------------------------------------------------
# wait_for_response()
# Wait for a response to a specific message
#
# Args:
#   $1 - agent_id: Agent waiting for response
#   $2 - message_id: ID of message expecting response
#   $3 - timeout_seconds: How long to wait (default: 60)
#
# Returns:
#   Response message JSON or empty if timeout
#------------------------------------------------------------------------------
wait_for_response() {
    local agent_id="$1"
    local message_id="$2"
    local timeout="${3:-60}"

    log_info "[MessageBus] Waiting for response to: $message_id (timeout: ${timeout}s)"

    local start_time=$(date +%s)
    local end_time=$((start_time + timeout))

    while [ $(date +%s) -lt $end_time ]; do
        # Check for response
        local messages=$(receive_messages "$agent_id" "response")
        local response=$(echo "$messages" | jq -r --arg msg_id "$message_id" '.[] | select(.body.in_response_to == $msg_id)')

        if [ -n "$response" ] && [ "$response" != "null" ]; then
            log_info "[MessageBus] Response received for: $message_id"
            echo "$response"
            return 0
        fi

        sleep 1
    done

    log_warn "[MessageBus] Timeout waiting for response to: $message_id"
    echo "{}"
}

#------------------------------------------------------------------------------
# get_message_stats()
# Get message bus statistics
#
# Args:
#   $1 - agent_id (optional): Stats for specific agent
#
# Returns:
#   JSON stats
#------------------------------------------------------------------------------
get_message_stats() {
    local agent_id="${1:-}"

    if [ -n "$agent_id" ]; then
        # Agent-specific stats
        local inbox_count=$(ls "$QUEUES_DIR/$agent_id/inbox" 2>/dev/null | wc -l | tr -d ' ')
        local sent_count=$(ls "$QUEUES_DIR/$agent_id/sent" 2>/dev/null | wc -l | tr -d ' ')
        local read_count=$(ls "$QUEUES_DIR/$agent_id/read" 2>/dev/null | wc -l | tr -d ' ')

        jq -n \
            --arg agent "$agent_id" \
            --argjson inbox "$inbox_count" \
            --argjson sent "$sent_count" \
            --argjson read "$read_count" \
            '{
                agent_id: $agent,
                inbox_count: $inbox,
                sent_count: $sent,
                read_count: $read
            }'
    else
        # Global stats
        local total_messages=$(wc -l < "$MESSAGE_LOG" 2>/dev/null | tr -d ' ' || echo "0")
        local active_agents=$(ls "$QUEUES_DIR" 2>/dev/null | wc -l | tr -d ' ' || echo "0")

        jq -n \
            --argjson total "$total_messages" \
            --argjson agents "$active_agents" \
            '{
                total_messages: $total,
                active_agents: $agents
            }'
    fi
}

#------------------------------------------------------------------------------
# Main execution (if called directly)
#------------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    case "${1:-help}" in
        init)
            message_bus_init "$2"
            ;;
        send)
            if [ $# -lt 5 ]; then
                echo "Usage: agent-message-bus.sh send <from> <to> <type> <body_json>"
                exit 1
            fi
            send_message "$2" "$3" "$4" "$5"
            ;;
        receive)
            receive_messages "$2" "${3:-}" | jq .
            ;;
        subscribe)
            subscribe_topic "$2" "$3"
            ;;
        publish)
            publish_to_topic "$2" "$3" "$4"
            ;;
        stats)
            get_message_stats "${2:-}" | jq .
            ;;
        *)
            echo "Usage: agent-message-bus.sh {init|send|receive|subscribe|publish|stats}"
            echo ""
            echo "Commands:"
            echo "  init <agent_id>                    - Initialize message bus for agent"
            echo "  send <from> <to> <type> <body>     - Send message"
            echo "  receive <agent_id> [type]          - Receive messages"
            echo "  subscribe <agent_id> <topic>       - Subscribe to topic"
            echo "  publish <from> <topic> <body>      - Publish to topic"
            echo "  stats [agent_id]                   - Get statistics"
            exit 1
            ;;
    esac
fi
