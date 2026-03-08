#!/bin/bash

###############################################################################
# Worker Heartbeat Library
#
# Purpose: Provides heartbeat functionality for workers to prove they're alive
# Usage: Source this file in worker scripts and call start_heartbeat
###############################################################################

# Configuration
HEARTBEAT_INTERVAL=120  # 2 minutes in seconds
HEARTBEAT_PID_FILE=""
WORKER_SPEC_FILE=""

###############################################################################
# Start heartbeat background process
###############################################################################

start_heartbeat() {
    local worker_id="$1"
    local spec_file="$2"

    if [ -z "$worker_id" ] || [ -z "$spec_file" ]; then
        echo "[HEARTBEAT] Error: worker_id and spec_file required"
        return 1
    fi

    WORKER_SPEC_FILE="$spec_file"
    HEARTBEAT_PID_FILE="/tmp/heartbeat-${worker_id}.pid"

    echo "[HEARTBEAT] Starting heartbeat for $worker_id (every ${HEARTBEAT_INTERVAL}s)"

    # Launch background heartbeat process
    (
        while true; do
            # Update heartbeat timestamp in worker spec
            if [ -f "$WORKER_SPEC_FILE" ]; then
                local current_time=$(date +%Y-%m-%dT%H:%M:%S%z)

                # Update last_heartbeat field
                jq --arg time "$current_time" \
                   '.execution.last_heartbeat = $time' \
                   "$WORKER_SPEC_FILE" > "${WORKER_SPEC_FILE}.tmp" 2>/dev/null

                if [ -f "${WORKER_SPEC_FILE}.tmp" ]; then
                    mv "${WORKER_SPEC_FILE}.tmp" "$WORKER_SPEC_FILE"
                fi
            fi

            sleep $HEARTBEAT_INTERVAL
        done
    ) &

    # Save background process PID
    local heartbeat_pid=$!
    echo $heartbeat_pid > "$HEARTBEAT_PID_FILE"

    echo "[HEARTBEAT] Heartbeat process started (PID: $heartbeat_pid)"
}

###############################################################################
# Stop heartbeat (call on worker exit)
###############################################################################

stop_heartbeat() {
    if [ -f "$HEARTBEAT_PID_FILE" ]; then
        local heartbeat_pid=$(cat "$HEARTBEAT_PID_FILE")

        if ps -p "$heartbeat_pid" > /dev/null 2>&1; then
            kill "$heartbeat_pid" 2>/dev/null || true
            echo "[HEARTBEAT] Stopped heartbeat process"
        fi

        rm -f "$HEARTBEAT_PID_FILE"
    fi
}

###############################################################################
# Update progress message (optional - for detailed progress tracking)
###############################################################################

update_progress() {
    local progress_message="$1"

    if [ -f "$WORKER_SPEC_FILE" ]; then
        local current_time=$(date +%Y-%m-%dT%H:%M:%S%z)

        jq --arg time "$current_time" \
           --arg msg "$progress_message" \
           '.execution.last_heartbeat = $time | .execution.progress_message = $msg' \
           "$WORKER_SPEC_FILE" > "${WORKER_SPEC_FILE}.tmp" 2>/dev/null

        if [ -f "${WORKER_SPEC_FILE}.tmp" ]; then
            mv "${WORKER_SPEC_FILE}.tmp" "$WORKER_SPEC_FILE"
        fi
    fi
}

###############################################################################
# Ensure heartbeat is stopped on script exit
###############################################################################

trap stop_heartbeat EXIT SIGINT SIGTERM
