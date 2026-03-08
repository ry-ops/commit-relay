#!/usr/bin/env bash
#
# Data Lineage Tracking Library
# Part of Phase 3: Observability and Data Features
#
# Tracks data provenance through trace attributes, enabling:
#   - Source tracking (where data came from)
#   - Transformation history (how data was modified)
#   - Output tracking (where data went)
#   - Lineage graph generation for visualization
#
# Usage:
#   source scripts/lib/data-lineage.sh
#
#   # Register a data source
#   register_data_source "task-queue" "coordination/task-queue.json" "file"
#
#   # Track data flow through operations
#   track_data_input "task-queue" "task-123"
#   track_transformation "filter_pending" "Filtered to pending tasks only"
#   track_data_output "worker-spec" "coordination/worker-specs/worker-001.json"
#
#   # Query lineage
#   get_lineage_for_output "coordination/worker-specs/worker-001.json"
#

set -euo pipefail

# Configuration
readonly DATA_LINEAGE_DIR="${DATA_LINEAGE_DIR:-coordination/observability/lineage}"
readonly LINEAGE_GRAPH_DIR="${DATA_LINEAGE_DIR}/graphs"
readonly LINEAGE_EVENTS_FILE="${DATA_LINEAGE_DIR}/lineage-events.jsonl"
readonly LINEAGE_SOURCES_FILE="${DATA_LINEAGE_DIR}/data-sources.json"
readonly LINEAGE_INDEX_DIR="${DATA_LINEAGE_DIR}/indices"
ENABLE_LINEAGE_TRACKING="${ENABLE_LINEAGE_TRACKING:-true}"

# Initialize directories
mkdir -p "$DATA_LINEAGE_DIR" "$LINEAGE_GRAPH_DIR" "$LINEAGE_INDEX_DIR" 2>/dev/null || true

# Current lineage context (stack-based for nested operations)
LINEAGE_STACK=()
CURRENT_LINEAGE_ID="${CURRENT_LINEAGE_ID:-}"
CURRENT_INPUTS=()
CURRENT_TRANSFORMATIONS=()

#
# Internal: Get last element of stack
#
_get_stack_last() {
    local stack_size=${#LINEAGE_STACK[@]}
    if [[ $stack_size -gt 0 ]]; then
        echo "${LINEAGE_STACK[$((stack_size - 1))]}"
    else
        echo ""
    fi
}

#
# Internal: Pop last element from stack
#
_pop_stack() {
    local stack_size=${#LINEAGE_STACK[@]}
    if [[ $stack_size -gt 0 ]]; then
        unset 'LINEAGE_STACK[$((stack_size - 1))]'
    fi
}

#
# Generate lineage ID
#
_generate_lineage_id() {
    local timestamp=$(date +%s%N | cut -b1-13)
    local random=$(openssl rand -hex 4)
    echo "lineage-${timestamp}-${random}"
}

#
# Get current timestamp in ISO format
#
_get_iso_timestamp() {
    date -Iseconds 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S%z"
}

#
# Register a data source in the system
#
# Args:
#   $1 - source_id: Unique identifier for this source
#   $2 - location: File path, URL, or resource identifier
#   $3 - source_type: Type of source (file, api, database, queue, etc.)
#   $4 - metadata: Optional JSON metadata
#
register_data_source() {
    local source_id="$1"
    local location="$2"
    local source_type="${3:-file}"
    local metadata="${4:-{}}"

    if [[ "$ENABLE_LINEAGE_TRACKING" != "true" ]]; then
        return 0
    fi

    local timestamp=$(_get_iso_timestamp)

    # Validate metadata JSON
    if ! echo "$metadata" | jq empty 2>/dev/null; then
        metadata="{}"
    fi

    # Create source entry
    local source_entry
    source_entry=$(jq -n \
        --arg id "$source_id" \
        --arg location "$location" \
        --arg type "$source_type" \
        --arg timestamp "$timestamp" \
        --argjson metadata "$metadata" \
        '{
            source_id: $id,
            location: $location,
            source_type: $type,
            registered_at: $timestamp,
            metadata: $metadata
        }')

    # Initialize sources file if needed
    if [[ ! -f "$LINEAGE_SOURCES_FILE" ]]; then
        echo '{"sources": []}' > "$LINEAGE_SOURCES_FILE"
    fi

    # Add or update source
    local temp_file="${LINEAGE_SOURCES_FILE}.tmp"
    jq --argjson entry "$source_entry" \
        '.sources = [.sources[] | select(.source_id != $entry.source_id)] + [$entry]' \
        "$LINEAGE_SOURCES_FILE" > "$temp_file" && mv "$temp_file" "$LINEAGE_SOURCES_FILE"

    # Index by source type
    echo "$source_id" >> "$LINEAGE_INDEX_DIR/by-type-${source_type}.index"
}

#
# Start a lineage tracking context
#
# Args:
#   $1 - operation_name: Name of the operation being tracked
#   $2 - trace_id: Optional trace ID to link with distributed tracing
#
start_lineage_tracking() {
    local operation_name="${1:-unnamed_operation}"
    local trace_id="${2:-${TRACE_ID:-}}"

    if [[ "$ENABLE_LINEAGE_TRACKING" != "true" ]]; then
        return 0
    fi

    # Generate lineage ID
    local lineage_id=$(_generate_lineage_id)
    local timestamp=$(_get_iso_timestamp)

    # Push current context to stack
    if [[ -n "$CURRENT_LINEAGE_ID" ]]; then
        LINEAGE_STACK+=("$CURRENT_LINEAGE_ID")
    fi

    # Initialize new context
    export CURRENT_LINEAGE_ID="$lineage_id"
    CURRENT_INPUTS=()
    CURRENT_TRANSFORMATIONS=()

    # Create lineage record
    local lineage_start
    lineage_start=$(jq -nc \
        --arg lineage_id "$lineage_id" \
        --arg operation "$operation_name" \
        --arg timestamp "$timestamp" \
        --arg trace_id "$trace_id" \
        --arg parent_lineage "$(_get_stack_last)" \
        '{
            event_type: "lineage_start",
            lineage_id: $lineage_id,
            operation_name: $operation,
            timestamp: $timestamp,
            trace_id: $trace_id,
            parent_lineage_id: (if $parent_lineage == "" then null else $parent_lineage end)
        }')

    echo "$lineage_start" >> "$LINEAGE_EVENTS_FILE"

    echo "$lineage_id"
}

#
# Track a data input to current operation
#
# Args:
#   $1 - source_id: ID of the registered data source
#   $2 - record_id: Optional specific record identifier
#   $3 - attributes: Optional JSON attributes
#
track_data_input() {
    local source_id="$1"
    local record_id="${2:-}"
    local attributes="${3:-{}}"

    if [[ "$ENABLE_LINEAGE_TRACKING" != "true" || -z "$CURRENT_LINEAGE_ID" ]]; then
        return 0
    fi

    local timestamp=$(_get_iso_timestamp)

    # Validate attributes JSON
    if ! echo "$attributes" | jq empty 2>/dev/null; then
        attributes="{}"
    fi

    # Record input event
    local input_event
    input_event=$(jq -nc \
        --arg lineage_id "$CURRENT_LINEAGE_ID" \
        --arg source_id "$source_id" \
        --arg record_id "$record_id" \
        --arg timestamp "$timestamp" \
        --argjson attributes "$attributes" \
        '{
            event_type: "data_input",
            lineage_id: $lineage_id,
            source_id: $source_id,
            record_id: (if $record_id == "" then null else $record_id end),
            timestamp: $timestamp,
            attributes: $attributes
        }')

    echo "$input_event" >> "$LINEAGE_EVENTS_FILE"

    # Track in current context
    CURRENT_INPUTS+=("$source_id:$record_id")

    # Index by source
    echo "$CURRENT_LINEAGE_ID" >> "$LINEAGE_INDEX_DIR/by-source-${source_id}.index"
}

#
# Track a data transformation
#
# Args:
#   $1 - transformation_name: Name of the transformation
#   $2 - description: Description of what changed
#   $3 - attributes: Optional JSON with transformation details
#
track_transformation() {
    local transformation_name="$1"
    local description="${2:-}"
    local attributes="${3:-{}}"

    if [[ "$ENABLE_LINEAGE_TRACKING" != "true" || -z "$CURRENT_LINEAGE_ID" ]]; then
        return 0
    fi

    local timestamp=$(_get_iso_timestamp)
    local transform_id="transform-$(openssl rand -hex 4)"

    # Validate attributes JSON
    if ! echo "$attributes" | jq empty 2>/dev/null; then
        attributes="{}"
    fi

    # Record transformation event
    local transform_event
    transform_event=$(jq -nc \
        --arg lineage_id "$CURRENT_LINEAGE_ID" \
        --arg transform_id "$transform_id" \
        --arg name "$transformation_name" \
        --arg description "$description" \
        --arg timestamp "$timestamp" \
        --argjson attributes "$attributes" \
        '{
            event_type: "transformation",
            lineage_id: $lineage_id,
            transform_id: $transform_id,
            transformation_name: $name,
            description: $description,
            timestamp: $timestamp,
            attributes: $attributes
        }')

    echo "$transform_event" >> "$LINEAGE_EVENTS_FILE"

    # Track in current context
    CURRENT_TRANSFORMATIONS+=("$transform_id:$transformation_name")
}

#
# Track a data output
#
# Args:
#   $1 - output_id: Identifier for the output
#   $2 - location: Output location (file path, URL, etc.)
#   $3 - attributes: Optional JSON attributes
#
track_data_output() {
    local output_id="$1"
    local location="${2:-}"
    local attributes="${3:-{}}"

    if [[ "$ENABLE_LINEAGE_TRACKING" != "true" || -z "$CURRENT_LINEAGE_ID" ]]; then
        return 0
    fi

    local timestamp=$(_get_iso_timestamp)

    # Validate attributes JSON
    if ! echo "$attributes" | jq empty 2>/dev/null; then
        attributes="{}"
    fi

    # Record output event
    local output_event
    output_event=$(jq -nc \
        --arg lineage_id "$CURRENT_LINEAGE_ID" \
        --arg output_id "$output_id" \
        --arg location "$location" \
        --arg timestamp "$timestamp" \
        --argjson attributes "$attributes" \
        '{
            event_type: "data_output",
            lineage_id: $lineage_id,
            output_id: $output_id,
            location: $location,
            timestamp: $timestamp,
            attributes: $attributes
        }')

    echo "$output_event" >> "$LINEAGE_EVENTS_FILE"

    # Index by output
    echo "$CURRENT_LINEAGE_ID" >> "$LINEAGE_INDEX_DIR/by-output-${output_id}.index"

    # Index by location (normalized)
    local location_hash
    location_hash=$(echo -n "$location" | md5sum 2>/dev/null | cut -d' ' -f1 || echo -n "$location" | md5)
    echo "$CURRENT_LINEAGE_ID:$output_id" >> "$LINEAGE_INDEX_DIR/by-location-${location_hash}.index"
}

#
# End lineage tracking context
#
# Args:
#   $1 - status: Outcome status (success, error, partial)
#   $2 - summary: Optional summary of the operation
#
end_lineage_tracking() {
    local status="${1:-success}"
    local summary="${2:-}"

    if [[ "$ENABLE_LINEAGE_TRACKING" != "true" || -z "$CURRENT_LINEAGE_ID" ]]; then
        return 0
    fi

    local timestamp=$(_get_iso_timestamp)

    # Serialize inputs and transformations
    local inputs_json
    inputs_json=$(printf '%s\n' "${CURRENT_INPUTS[@]:-}" | jq -R . | jq -s .)

    local transforms_json
    transforms_json=$(printf '%s\n' "${CURRENT_TRANSFORMATIONS[@]:-}" | jq -R . | jq -s .)

    # Record end event
    local end_event
    end_event=$(jq -nc \
        --arg lineage_id "$CURRENT_LINEAGE_ID" \
        --arg status "$status" \
        --arg summary "$summary" \
        --arg timestamp "$timestamp" \
        --argjson inputs "$inputs_json" \
        --argjson transformations "$transforms_json" \
        '{
            event_type: "lineage_end",
            lineage_id: $lineage_id,
            status: $status,
            summary: $summary,
            timestamp: $timestamp,
            inputs_count: ($inputs | length),
            transformations_count: ($transformations | length)
        }')

    echo "$end_event" >> "$LINEAGE_EVENTS_FILE"

    # Pop from stack
    if [[ ${#LINEAGE_STACK[@]} -gt 0 ]]; then
        export CURRENT_LINEAGE_ID="$(_get_stack_last)"
        _pop_stack
    else
        export CURRENT_LINEAGE_ID=""
    fi

    # Reset tracking arrays
    CURRENT_INPUTS=()
    CURRENT_TRANSFORMATIONS=()
}

#
# Add lineage attributes to a span
# Integrates with trace.sh
#
# Args:
#   $1 - span_attributes: Existing span attributes JSON
#
# Returns:
#   Enhanced attributes with lineage information
#
add_lineage_to_span() {
    local span_attributes="${1:-{}}"

    if [[ -z "$CURRENT_LINEAGE_ID" ]]; then
        echo "$span_attributes"
        return
    fi

    # Serialize current context
    local inputs_json
    inputs_json=$(printf '%s\n' "${CURRENT_INPUTS[@]:-}" | jq -R . | jq -s . 2>/dev/null || echo '[]')

    local transforms_json
    transforms_json=$(printf '%s\n' "${CURRENT_TRANSFORMATIONS[@]:-}" | jq -R . | jq -s . 2>/dev/null || echo '[]')

    # Add lineage attributes
    echo "$span_attributes" | jq \
        --arg lineage_id "$CURRENT_LINEAGE_ID" \
        --argjson inputs "$inputs_json" \
        --argjson transformations "$transforms_json" \
        '. + {
            "lineage.id": $lineage_id,
            "lineage.inputs": $inputs,
            "lineage.transformations": $transformations
        }'
}

#
# Query lineage for a specific output
#
# Args:
#   $1 - output_location: File path or output identifier
#
# Returns:
#   JSON array of lineage events that produced this output
#
get_lineage_for_output() {
    local output_location="$1"

    # Hash location for index lookup
    local location_hash
    location_hash=$(echo -n "$output_location" | md5sum 2>/dev/null | cut -d' ' -f1 || echo -n "$output_location" | md5)

    local index_file="$LINEAGE_INDEX_DIR/by-location-${location_hash}.index"

    if [[ ! -f "$index_file" ]]; then
        echo "[]"
        return 1
    fi

    # Get lineage IDs for this output
    local lineage_ids
    lineage_ids=$(cut -d: -f1 "$index_file" | sort -u)

    # Collect all events for these lineages
    local all_events="[]"
    for lineage_id in $lineage_ids; do
        local events
        events=$(grep "\"lineage_id\":\"$lineage_id\"" "$LINEAGE_EVENTS_FILE" 2>/dev/null | jq -s .)
        all_events=$(echo "$all_events" | jq --argjson events "$events" '. + $events')
    done

    echo "$all_events"
}

#
# Query upstream sources for an output
# "What produced this?"
#
# Args:
#   $1 - output_location: File path or output identifier
#
# Returns:
#   JSON array of source information
#
get_upstream_sources() {
    local output_location="$1"

    local lineage_events
    lineage_events=$(get_lineage_for_output "$output_location")

    # Extract input events
    echo "$lineage_events" | jq '[.[] | select(.event_type == "data_input") | {
        source_id: .source_id,
        record_id: .record_id,
        timestamp: .timestamp
    }] | unique_by(.source_id + .record_id)'
}

#
# Query downstream outputs from a source
# "What did this produce?"
#
# Args:
#   $1 - source_id: Source identifier
#
# Returns:
#   JSON array of output information
#
get_downstream_outputs() {
    local source_id="$1"

    local index_file="$LINEAGE_INDEX_DIR/by-source-${source_id}.index"

    if [[ ! -f "$index_file" ]]; then
        echo "[]"
        return 1
    fi

    # Get all lineage IDs that used this source
    local lineage_ids
    lineage_ids=$(sort -u "$index_file")

    # Collect output events
    local all_outputs="[]"
    for lineage_id in $lineage_ids; do
        local outputs
        outputs=$(grep "\"lineage_id\":\"$lineage_id\"" "$LINEAGE_EVENTS_FILE" 2>/dev/null | \
            jq -s '[.[] | select(.event_type == "data_output")]')
        all_outputs=$(echo "$all_outputs" | jq --argjson outputs "$outputs" '. + $outputs')
    done

    echo "$all_outputs" | jq 'unique_by(.output_id + .location)'
}

#
# Generate lineage graph data for visualization
#
# Args:
#   $1 - lineage_id: Specific lineage ID or "all" for full graph
#
# Returns:
#   JSON graph structure (nodes and edges)
#
generate_lineage_graph() {
    local lineage_id="${1:-all}"

    local events
    if [[ "$lineage_id" == "all" ]]; then
        events=$(cat "$LINEAGE_EVENTS_FILE" 2>/dev/null | jq -s .)
    else
        events=$(grep "\"lineage_id\":\"$lineage_id\"" "$LINEAGE_EVENTS_FILE" 2>/dev/null | jq -s .)
    fi

    # Generate graph structure
    local graph
    graph=$(echo "$events" | jq '
        # Extract nodes
        (
            ([.[] | select(.event_type == "data_input")] | map({
                id: "source-\(.source_id)",
                type: "source",
                label: .source_id,
                attributes: {record_id: .record_id}
            })) +
            ([.[] | select(.event_type == "transformation")] | map({
                id: "transform-\(.transform_id)",
                type: "transformation",
                label: .transformation_name,
                attributes: {description: .description}
            })) +
            ([.[] | select(.event_type == "data_output")] | map({
                id: "output-\(.output_id)",
                type: "output",
                label: .output_id,
                attributes: {location: .location}
            }))
        ) | unique_by(.id) as $nodes |

        # Extract edges (simplified: sources -> transforms -> outputs)
        (
            # Source to lineage operation
            ([.[] | select(.event_type == "data_input")] | map({
                from: "source-\(.source_id)",
                to: "operation-\(.lineage_id)",
                type: "input"
            })) +
            # Operation to output
            ([.[] | select(.event_type == "data_output")] | map({
                from: "operation-\(.lineage_id)",
                to: "output-\(.output_id)",
                type: "output"
            }))
        ) | unique as $edges |

        {
            nodes: $nodes,
            edges: $edges,
            generated_at: now | todate
        }
    ')

    echo "$graph"
}

#
# Export lineage graph to DOT format for Graphviz
#
# Args:
#   $1 - lineage_id: Specific lineage ID or "all"
#   $2 - output_file: Optional output file path
#
export_lineage_to_dot() {
    local lineage_id="${1:-all}"
    local output_file="${2:-$LINEAGE_GRAPH_DIR/lineage-${lineage_id}.dot}"

    local graph
    graph=$(generate_lineage_graph "$lineage_id")

    # Generate DOT format
    {
        echo "digraph LineageGraph {"
        echo "  rankdir=LR;"
        echo "  node [shape=box];"
        echo ""

        # Nodes with styling
        echo "$graph" | jq -r '.nodes[] |
            if .type == "source" then
                "  \"\(.id)\" [label=\"\(.label)\" style=filled fillcolor=lightblue];"
            elif .type == "transformation" then
                "  \"\(.id)\" [label=\"\(.label)\" style=filled fillcolor=lightyellow shape=ellipse];"
            else
                "  \"\(.id)\" [label=\"\(.label)\" style=filled fillcolor=lightgreen];"
            end'

        echo ""

        # Edges
        echo "$graph" | jq -r '.edges[] | "  \"\(.from)\" -> \"\(.to)\";"'

        echo "}"
    } > "$output_file"

    echo "$output_file"
}

#
# Get lineage statistics
#
get_lineage_stats() {
    if [[ ! -f "$LINEAGE_EVENTS_FILE" ]]; then
        jq -n '{
            total_lineages: 0,
            total_inputs: 0,
            total_transformations: 0,
            total_outputs: 0,
            sources: 0
        }'
        return
    fi

    cat "$LINEAGE_EVENTS_FILE" | jq -s '{
        total_lineages: ([.[] | select(.event_type == "lineage_start")] | length),
        total_inputs: ([.[] | select(.event_type == "data_input")] | length),
        total_transformations: ([.[] | select(.event_type == "transformation")] | length),
        total_outputs: ([.[] | select(.event_type == "data_output")] | length),
        unique_sources: ([.[] | select(.event_type == "data_input") | .source_id] | unique | length)
    }'
}

#
# Cleanup old lineage data
#
cleanup_lineage_data() {
    local retention_days="${1:-30}"

    # Archive old events
    local archive_date=$(date -d "-${retention_days} days" +%Y-%m-%d 2>/dev/null || date -v-${retention_days}d +%Y-%m-%d)

    # Move old events to archive
    if [[ -f "$LINEAGE_EVENTS_FILE" ]]; then
        local archive_file="${DATA_LINEAGE_DIR}/archive/lineage-events-${archive_date}.jsonl"
        mkdir -p "$(dirname "$archive_file")"

        # Filter events older than retention
        # Note: This is a simplified cleanup
        mv "$LINEAGE_EVENTS_FILE" "$archive_file"
        touch "$LINEAGE_EVENTS_FILE"
    fi

    # Cleanup old indices
    find "$LINEAGE_INDEX_DIR" -name "*.index" -mtime +$retention_days -delete 2>/dev/null || true
}

# Export functions
export -f register_data_source
export -f start_lineage_tracking
export -f track_data_input
export -f track_transformation
export -f track_data_output
export -f end_lineage_tracking
export -f add_lineage_to_span
export -f get_lineage_for_output
export -f get_upstream_sources
export -f get_downstream_outputs
export -f generate_lineage_graph
export -f export_lineage_to_dot
export -f get_lineage_stats
export -f cleanup_lineage_data
