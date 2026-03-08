#!/usr/bin/env bash
#
# Trace Visualizer - Waterfall View Generator
# Part of Q2 Week 17-18: Distributed Tracing
#
# Generates ASCII waterfall diagrams of distributed traces
#

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/tracer.sh"

#
# Build span tree from flat list
#
build_span_tree() {
    local trace_json="$1"

    # Extract and sort spans by start time
    echo "$trace_json" | jq -r '.spans | sort_by(.start_time)'
}

#
# Calculate span depth (nesting level)
#
calculate_span_depth() {
    local span_id="$1"
    local spans="$2"

    local depth=0
    local current_id="$span_id"

    while true; do
        local parent_id=$(echo "$spans" | jq -r ".[] | select(.span_id == \"$current_id\") | .parent_span_id")

        if [[ "$parent_id" == "null" || -z "$parent_id" ]]; then
            break
        fi

        depth=$((depth + 1))
        current_id="$parent_id"

        # Safety: max depth 20
        if [[ $depth -gt 20 ]]; then
            break
        fi
    done

    echo "$depth"
}

#
# Format duration for display
#
format_duration() {
    local duration_ms="$1"

    if [[ $duration_ms -lt 1000 ]]; then
        echo "${duration_ms}ms"
    elif [[ $duration_ms -lt 60000 ]]; then
        local seconds=$(echo "scale=2; $duration_ms / 1000" | bc)
        echo "${seconds}s"
    else
        local minutes=$((duration_ms / 60000))
        local seconds=$(((duration_ms % 60000) / 1000))
        echo "${minutes}m${seconds}s"
    fi
}

#
# Generate waterfall view (ASCII)
#
trace_waterfall() {
    local trace_id="$1"
    local width="${2:-80}"  # Terminal width

    local trace=$(trace_get "$trace_id")

    if [[ "$trace" == "{}" ]]; then
        echo "Error: Trace $trace_id not found" >&2
        return 1
    fi

    # Header
    echo "========================================"
    echo "Trace: $trace_id"
    echo "Status: $(echo "$trace" | jq -r '.status')"
    echo "Duration: $(format_duration $(echo "$trace" | jq -r '.duration_ms'))"
    echo "Spans: $(echo "$trace" | jq -r '.span_count')"
    echo "========================================"
    echo ""

    # Get trace timeline
    local trace_start=$(echo "$trace" | jq -r '.start_time')
    local trace_end=$(echo "$trace" | jq -r '.end_time // .start_time')
    local trace_duration=$((trace_end - trace_start))

    # Build span tree
    local spans=$(echo "$trace" | jq -c '.spans')

    # Sort spans by start time
    local sorted_spans=$(echo "$spans" | jq -c 'sort_by(.start_time)')

    # Calculate available width for timeline
    local timeline_width=$((width - 50))  # Reserve space for labels

    # Print each span
    echo "$sorted_spans" | jq -c '.[]' | while read -r span; do
        local span_id=$(echo "$span" | jq -r '.span_id')
        local span_name=$(echo "$span" | jq -r '.name')
        local span_start=$(echo "$span" | jq -r '.start_time')
        local span_duration=$(echo "$span" | jq -r '.duration_ms // 0')
        local span_status=$(echo "$span" | jq -r '.status')
        local parent_span_id=$(echo "$span" | jq -r '.parent_span_id // "null"')

        # Calculate depth
        local depth=$(calculate_span_depth "$span_id" "$sorted_spans")

        # Calculate position in timeline
        local offset_ms=$((span_start - trace_start))
        local offset_pos=0
        if [[ $trace_duration -gt 0 ]]; then
            offset_pos=$((offset_ms * timeline_width / trace_duration))
        fi

        local bar_length=$((span_duration * timeline_width / trace_duration))
        [[ $bar_length -lt 1 ]] && bar_length=1

        # Create indentation for depth
        local indent=""
        for ((i=0; i<depth; i++)); do
            indent="│  $indent"
        done

        # Status symbol
        local status_symbol="●"
        case "$span_status" in
            "ok") status_symbol="✓" ;;
            "error") status_symbol="✗" ;;
            "timeout") status_symbol="⏱" ;;
        esac

        # Span label
        local label="${indent}└─ ${status_symbol} ${span_name}"
        local label_padded=$(printf "%-45s" "$label")

        # Timeline bar
        local timeline=""
        for ((i=0; i<offset_pos; i++)); do
            timeline+=" "
        done

        local bar_char="█"
        [[ "$span_status" == "error" ]] && bar_char="▓"
        for ((i=0; i<bar_length; i++)); do
            timeline+="$bar_char"
        done

        # Duration label
        local duration_label="$(format_duration $span_duration)"

        # Print span row
        echo "${label_padded} ${timeline} ${duration_label}"
    done

    echo ""

    # Legend
    echo "Legend: ✓ OK  ✗ Error  ⏱ Timeout"
    echo "Timeline: 0ms$(printf '%*s' $((timeline_width-10)) '')$(format_duration $trace_duration)"
}

#
# Generate flame graph data (for external visualization)
#
trace_flamegraph() {
    local trace_id="$1"

    local trace=$(trace_get "$trace_id")

    if [[ "$trace" == "{}" ]]; then
        echo "Error: Trace $trace_id not found" >&2
        return 1
    fi

    echo "# Flame graph data for trace $trace_id"
    echo "# Format: stack;duration"

    # Build call stacks
    local spans=$(echo "$trace" | jq -c '.spans | sort_by(.start_time)')

    echo "$spans" | jq -r '.[] | "\(.name) \(.duration_ms)"' | while read -r name duration; do
        echo "$name $duration"
    done
}

#
# Compare two traces
#
trace_compare() {
    local trace_id1="$1"
    local trace_id2="$2"

    local trace1=$(trace_get "$trace_id1")
    local trace2=$(trace_get "$trace_id2")

    if [[ "$trace1" == "{}" || "$trace2" == "{}" ]]; then
        echo "Error: One or both traces not found" >&2
        return 1
    fi

    echo "========================================"
    echo "Trace Comparison"
    echo "========================================"
    echo ""

    echo "Trace 1: $trace_id1"
    echo "  Duration: $(format_duration $(echo "$trace1" | jq -r '.duration_ms'))"
    echo "  Spans: $(echo "$trace1" | jq -r '.span_count')"
    echo "  Errors: $(echo "$trace1" | jq -r '.error_count')"
    echo "  Status: $(echo "$trace1" | jq -r '.status')"
    echo ""

    echo "Trace 2: $trace_id2"
    echo "  Duration: $(format_duration $(echo "$trace2" | jq -r '.duration_ms'))"
    echo "  Spans: $(echo "$trace2" | jq -r '.span_count')"
    echo "  Errors: $(echo "$trace2" | jq -r '.error_count')"
    echo "  Status: $(echo "$trace2" | jq -r '.status')"
    echo ""

    # Duration comparison
    local duration1=$(echo "$trace1" | jq -r '.duration_ms')
    local duration2=$(echo "$trace2" | jq -r '.duration_ms')
    local duration_diff=$((duration2 - duration1))
    local duration_pct=0

    if [[ $duration1 -gt 0 ]]; then
        duration_pct=$(echo "scale=2; ($duration_diff * 100) / $duration1" | bc)
    fi

    echo "Duration Difference:"
    if [[ $duration_diff -gt 0 ]]; then
        echo "  Trace 2 is $(format_duration $duration_diff) slower (+${duration_pct}%)"
    elif [[ $duration_diff -lt 0 ]]; then
        duration_diff=$((duration_diff * -1))
        duration_pct=$(echo "$duration_pct" | tr -d '-')
        echo "  Trace 2 is $(format_duration $duration_diff) faster (-${duration_pct}%)"
    else
        echo "  Same duration"
    fi
}

#
# Find slow spans in a trace
#
trace_slow_spans() {
    local trace_id="$1"
    local threshold_ms="${2:-1000}"  # Default: 1 second

    local trace=$(trace_get "$trace_id")

    if [[ "$trace" == "{}" ]]; then
        echo "Error: Trace $trace_id not found" >&2
        return 1
    fi

    echo "Slow Spans (>${threshold_ms}ms) in Trace $trace_id"
    echo "========================================"

    echo "$trace" | jq -r --arg threshold "$threshold_ms" '
        .spans |
        map(select(.duration_ms > ($threshold | tonumber))) |
        sort_by(-.duration_ms) |
        .[] |
        "  \(.duration_ms)ms - \(.name) (\(.status))"
    '
}

#
# Critical path analysis
#
trace_critical_path() {
    local trace_id="$1"

    local trace=$(trace_get "$trace_id")

    if [[ "$trace" == "{}" ]]; then
        echo "Error: Trace $trace_id not found" >&2
        return 1
    fi

    echo "Critical Path for Trace $trace_id"
    echo "========================================"

    # Find the longest sequential path
    # For now, show top 10 longest spans
    echo "$trace" | jq -r '
        .spans |
        sort_by(-.duration_ms) |
        .[0:10] |
        .[] |
        "  \(.duration_ms)ms - \(.name)"
    '
}

#
# Export trace to JSON
#
trace_export() {
    local trace_id="$1"
    local output_file="${2:-/dev/stdout}"

    local trace=$(trace_get "$trace_id")

    if [[ "$trace" == "{}" ]]; then
        echo "Error: Trace $trace_id not found" >&2
        return 1
    fi

    echo "$trace" | jq '.' > "$output_file"

    if [[ "$output_file" != "/dev/stdout" ]]; then
        echo "Trace exported to: $output_file"
    fi
}

# Export functions
export -f trace_waterfall
export -f trace_flamegraph
export -f trace_compare
export -f trace_slow_spans
export -f trace_critical_path
export -f trace_export

# Main CLI
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    command="${1:-help}"
    shift || true

    case "$command" in
        "waterfall")
            trace_waterfall "$@"
            ;;
        "flame")
            trace_flamegraph "$@"
            ;;
        "compare")
            trace_compare "$@"
            ;;
        "slow")
            trace_slow_spans "$@"
            ;;
        "critical")
            trace_critical_path "$@"
            ;;
        "export")
            trace_export "$@"
            ;;
        "help"|"-h"|"--help")
            echo "Trace Visualizer"
            echo ""
            echo "Usage: $0 <command> [args...]"
            echo ""
            echo "Commands:"
            echo "  waterfall <trace_id> [width]   Show waterfall diagram"
            echo "  flame <trace_id>                Generate flame graph data"
            echo "  compare <trace1> <trace2>       Compare two traces"
            echo "  slow <trace_id> [threshold_ms]  Find slow spans"
            echo "  critical <trace_id>             Show critical path"
            echo "  export <trace_id> [file]        Export trace to JSON"
            echo "  help                            Show this help"
            ;;
        *)
            echo "Unknown command: $command" >&2
            echo "Run '$0 help' for usage" >&2
            exit 1
            ;;
    esac
fi
