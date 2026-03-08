#!/bin/bash
# scripts/lib/prompt-manager.sh
# Prompt Manager Library - Phase 3 Item 25
# Prompt versioning and A/B testing with outcome tracking
#
# Features:
#   - Version prompts with metadata
#   - Track success rates per version
#   - A/B testing with traffic splitting
#   - Automatic promotion of winning variants
#
# Usage:
#   source "$COMMIT_RELAY_HOME/scripts/lib/prompt-manager.sh"
#   prompt=$(get_prompt "implementation-worker" --ab-test)
#   record_prompt_outcome "$version_id" "success"

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# Prompt storage
PROMPT_VERSIONS_DIR="${COMMIT_RELAY_HOME}/coordination/prompt-versions"
PROMPT_REGISTRY_FILE="${PROMPT_VERSIONS_DIR}/registry.json"
PROMPT_OUTCOMES_FILE="${PROMPT_VERSIONS_DIR}/outcomes.jsonl"
PROMPT_AB_CONFIG_FILE="${PROMPT_VERSIONS_DIR}/ab-tests.json"

# Create directories
mkdir -p "$PROMPT_VERSIONS_DIR"

# ============================================================================
# Logging
# ============================================================================

log_prompt() {
    local level="$1"
    shift
    echo "[$(date +%Y-%m-%dT%H:%M:%S%z)] [PROMPT-MGR] [$level] $*" >&2
}

# ============================================================================
# Initialize Registry
# ============================================================================

initialize_prompt_registry() {
    if [ ! -f "$PROMPT_REGISTRY_FILE" ]; then
        cat > "$PROMPT_REGISTRY_FILE" <<'EOF'
{
  "version": "1.0.0",
  "prompts": {},
  "last_updated": ""
}
EOF
        log_prompt "INFO" "Created prompt registry"
    fi

    if [ ! -f "$PROMPT_AB_CONFIG_FILE" ]; then
        cat > "$PROMPT_AB_CONFIG_FILE" <<'EOF'
{
  "active_tests": {},
  "completed_tests": [],
  "settings": {
    "min_samples_for_significance": 30,
    "confidence_threshold": 0.95,
    "auto_promote": true
  }
}
EOF
        log_prompt "INFO" "Created A/B test config"
    fi
}

initialize_prompt_registry

# ============================================================================
# Version Management
# ============================================================================

# Register a new prompt version
register_prompt_version() {
    local prompt_type="$1"
    local version_id="$2"
    local prompt_content="$3"
    local description="${4:-}"
    local is_control="${5:-false}"

    # Save prompt content
    local prompt_file="${PROMPT_VERSIONS_DIR}/${prompt_type}/${version_id}.md"
    mkdir -p "$(dirname "$prompt_file")"
    echo "$prompt_content" > "$prompt_file"

    # Update registry
    local temp_file="${PROMPT_REGISTRY_FILE}.tmp"
    jq --arg type "$prompt_type" \
       --arg version "$version_id" \
       --arg description "$description" \
       --arg file "$prompt_file" \
       --arg is_control "$is_control" \
       --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       '.prompts[$type] = (.prompts[$type] // []) + [{
           version_id: $version,
           description: $description,
           file_path: $file,
           is_control: ($is_control == "true"),
           created_at: $created_at,
           status: "active",
           metrics: {
               total_uses: 0,
               successes: 0,
               failures: 0,
               success_rate: 0
           }
       }] | .last_updated = $created_at' "$PROMPT_REGISTRY_FILE" > "$temp_file"
    mv "$temp_file" "$PROMPT_REGISTRY_FILE"

    log_prompt "INFO" "Registered prompt version: $prompt_type/$version_id"
    echo "$version_id"
}

# Get all versions for a prompt type
get_prompt_versions() {
    local prompt_type="$1"

    jq --arg type "$prompt_type" '.prompts[$type] // []' "$PROMPT_REGISTRY_FILE"
}

# Get the current production version
get_production_version() {
    local prompt_type="$1"

    # Check for explicitly marked production version, otherwise get highest success rate
    local production=$(jq -r --arg type "$prompt_type" '
        .prompts[$type] // [] |
        map(select(.status == "production")) |
        .[0].version_id // ""
    ' "$PROMPT_REGISTRY_FILE")

    if [ -z "$production" ] || [ "$production" = "null" ]; then
        # Fall back to control version or best performing
        production=$(jq -r --arg type "$prompt_type" '
            .prompts[$type] // [] |
            map(select(.status == "active")) |
            sort_by(.metrics.success_rate) |
            reverse |
            .[0].version_id // ""
        ' "$PROMPT_REGISTRY_FILE")
    fi

    echo "$production"
}

# ============================================================================
# A/B Testing
# ============================================================================

# Start an A/B test
start_ab_test() {
    local prompt_type="$1"
    local control_version="$2"
    local variant_version="$3"
    local traffic_split="${4:-50}"  # Percentage to variant
    local test_name="${5:-}"

    local test_id="ab-$(date +%s)-$(head -c 4 /dev/urandom | xxd -p)"

    if [ -z "$test_name" ]; then
        test_name="${prompt_type}-test-${test_id}"
    fi

    # Add to active tests
    local temp_file="${PROMPT_AB_CONFIG_FILE}.tmp"
    jq --arg test_id "$test_id" \
       --arg name "$test_name" \
       --arg type "$prompt_type" \
       --arg control "$control_version" \
       --arg variant "$variant_version" \
       --argjson split "$traffic_split" \
       --arg started_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       '.active_tests[$test_id] = {
           name: $name,
           prompt_type: $type,
           control_version: $control,
           variant_version: $variant,
           traffic_split_percent: $split,
           started_at: $started_at,
           status: "running",
           results: {
               control: {uses: 0, successes: 0},
               variant: {uses: 0, successes: 0}
           }
       }' "$PROMPT_AB_CONFIG_FILE" > "$temp_file"
    mv "$temp_file" "$PROMPT_AB_CONFIG_FILE"

    log_prompt "INFO" "Started A/B test: $test_id ($control_version vs $variant_version)"
    echo "$test_id"
}

# Select version for A/B test
select_ab_version() {
    local prompt_type="$1"

    # Check for active test
    local active_test=$(jq -r --arg type "$prompt_type" '
        .active_tests | to_entries[] |
        select(.value.prompt_type == $type and .value.status == "running") |
        .key
    ' "$PROMPT_AB_CONFIG_FILE" | head -1)

    if [ -z "$active_test" ] || [ "$active_test" = "null" ]; then
        # No active test, return production version
        get_production_version "$prompt_type"
        return
    fi

    # Get test config
    local test_config=$(jq --arg id "$active_test" '.active_tests[$id]' "$PROMPT_AB_CONFIG_FILE")
    local traffic_split=$(echo "$test_config" | jq -r '.traffic_split_percent')
    local control=$(echo "$test_config" | jq -r '.control_version')
    local variant=$(echo "$test_config" | jq -r '.variant_version')

    # Random selection based on traffic split
    local random=$((RANDOM % 100))
    local selected_version
    local selection_group

    if [ "$random" -lt "$traffic_split" ]; then
        selected_version="$variant"
        selection_group="variant"
    else
        selected_version="$control"
        selection_group="control"
    fi

    # Record selection
    local temp_file="${PROMPT_AB_CONFIG_FILE}.tmp"
    jq --arg id "$active_test" \
       --arg group "$selection_group" \
       '.active_tests[$id].results[$group].uses += 1' "$PROMPT_AB_CONFIG_FILE" > "$temp_file"
    mv "$temp_file" "$PROMPT_AB_CONFIG_FILE"

    # Return version and test info
    jq -nc \
        --arg version "$selected_version" \
        --arg test_id "$active_test" \
        --arg group "$selection_group" \
        '{
            version_id: $version,
            ab_test_id: $test_id,
            test_group: $group
        }'
}

# Analyze A/B test results
analyze_ab_test() {
    local test_id="$1"

    local test_config=$(jq --arg id "$test_id" '.active_tests[$id]' "$PROMPT_AB_CONFIG_FILE")

    if [ -z "$test_config" ] || [ "$test_config" = "null" ]; then
        echo "ERROR: Test not found: $test_id" >&2
        return 1
    fi

    local control_uses=$(echo "$test_config" | jq -r '.results.control.uses')
    local control_successes=$(echo "$test_config" | jq -r '.results.control.successes')
    local variant_uses=$(echo "$test_config" | jq -r '.results.variant.uses')
    local variant_successes=$(echo "$test_config" | jq -r '.results.variant.successes')

    # Calculate success rates
    local control_rate=0
    local variant_rate=0

    if [ "$control_uses" -gt 0 ]; then
        control_rate=$(echo "scale=4; $control_successes / $control_uses" | bc)
    fi

    if [ "$variant_uses" -gt 0 ]; then
        variant_rate=$(echo "scale=4; $variant_successes / $variant_uses" | bc)
    fi

    # Calculate improvement
    local improvement=0
    if (( $(echo "$control_rate > 0" | bc -l) )); then
        improvement=$(echo "scale=4; ($variant_rate - $control_rate) / $control_rate * 100" | bc)
    fi

    # Determine winner (simplified - should use proper statistical test)
    local min_samples=$(jq -r '.settings.min_samples_for_significance' "$PROMPT_AB_CONFIG_FILE")
    local winner="inconclusive"
    local significant="false"

    if [ "$control_uses" -ge "$min_samples" ] && [ "$variant_uses" -ge "$min_samples" ]; then
        significant="true"
        if (( $(echo "$variant_rate > $control_rate" | bc -l) )); then
            winner="variant"
        elif (( $(echo "$control_rate > $variant_rate" | bc -l) )); then
            winner="control"
        else
            winner="tie"
        fi
    fi

    jq -nc \
        --arg test_id "$test_id" \
        --argjson control_uses "$control_uses" \
        --argjson control_successes "$control_successes" \
        --arg control_rate "$control_rate" \
        --argjson variant_uses "$variant_uses" \
        --argjson variant_successes "$variant_successes" \
        --arg variant_rate "$variant_rate" \
        --arg improvement "$improvement" \
        --arg winner "$winner" \
        --arg significant "$significant" \
        '{
            test_id: $test_id,
            control: {
                uses: $control_uses,
                successes: $control_successes,
                success_rate: ($control_rate | tonumber)
            },
            variant: {
                uses: $variant_uses,
                successes: $variant_successes,
                success_rate: ($variant_rate | tonumber)
            },
            improvement_percent: ($improvement | tonumber),
            winner: $winner,
            statistically_significant: ($significant == "true")
        }'
}

# End A/B test
end_ab_test() {
    local test_id="$1"
    local promote_winner="${2:-true}"

    local analysis=$(analyze_ab_test "$test_id")
    local winner=$(echo "$analysis" | jq -r '.winner')
    local test_config=$(jq --arg id "$test_id" '.active_tests[$id]' "$PROMPT_AB_CONFIG_FILE")
    local prompt_type=$(echo "$test_config" | jq -r '.prompt_type')

    # Move to completed
    local temp_file="${PROMPT_AB_CONFIG_FILE}.tmp"
    jq --arg id "$test_id" \
       --arg ended_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       --argjson analysis "$analysis" \
       '
        .active_tests[$id].status = "completed" |
        .active_tests[$id].ended_at = $ended_at |
        .active_tests[$id].analysis = $analysis |
        .completed_tests += [.active_tests[$id]] |
        del(.active_tests[$id])
       ' "$PROMPT_AB_CONFIG_FILE" > "$temp_file"
    mv "$temp_file" "$PROMPT_AB_CONFIG_FILE"

    # Promote winner if enabled
    if [ "$promote_winner" = "true" ] && [ "$winner" != "inconclusive" ] && [ "$winner" != "tie" ]; then
        local winning_version
        if [ "$winner" = "variant" ]; then
            winning_version=$(echo "$test_config" | jq -r '.variant_version')
        else
            winning_version=$(echo "$test_config" | jq -r '.control_version')
        fi

        # Update registry to mark as production
        local reg_temp="${PROMPT_REGISTRY_FILE}.tmp"
        jq --arg type "$prompt_type" \
           --arg version "$winning_version" \
           '.prompts[$type] = [.prompts[$type][] |
               if .version_id == $version then .status = "production"
               elif .status == "production" then .status = "active"
               else . end
           ]' "$PROMPT_REGISTRY_FILE" > "$reg_temp"
        mv "$reg_temp" "$PROMPT_REGISTRY_FILE"

        log_prompt "INFO" "Promoted $winning_version to production"
    fi

    log_prompt "INFO" "Ended A/B test: $test_id (winner: $winner)"
    echo "$analysis"
}

# ============================================================================
# Prompt Retrieval
# ============================================================================

# Get prompt with optional A/B testing
get_prompt() {
    local prompt_type="$1"
    local ab_test="${2:-false}"

    local version_info
    local version_id

    if [ "$ab_test" = "--ab-test" ] || [ "$ab_test" = "true" ]; then
        version_info=$(select_ab_version "$prompt_type")
        version_id=$(echo "$version_info" | jq -r '.version_id')
    else
        version_id=$(get_production_version "$prompt_type")
        version_info=$(jq -nc --arg v "$version_id" '{version_id: $v}')
    fi

    if [ -z "$version_id" ] || [ "$version_id" = "null" ]; then
        # Fall back to template file
        local template_file="${COMMIT_RELAY_HOME}/agents/prompts/workers/${prompt_type}.md"
        if [ -f "$template_file" ]; then
            cat "$template_file"
        else
            echo "ERROR: No prompt found for type: $prompt_type" >&2
            return 1
        fi
        return
    fi

    # Get prompt file path
    local prompt_file=$(jq -r --arg type "$prompt_type" --arg version "$version_id" '
        .prompts[$type][] | select(.version_id == $version) | .file_path
    ' "$PROMPT_REGISTRY_FILE")

    if [ -f "$prompt_file" ]; then
        # Update usage count
        local temp_file="${PROMPT_REGISTRY_FILE}.tmp"
        jq --arg type "$prompt_type" \
           --arg version "$version_id" \
           '.prompts[$type] = [.prompts[$type][] |
               if .version_id == $version then .metrics.total_uses += 1
               else . end
           ]' "$PROMPT_REGISTRY_FILE" > "$temp_file"
        mv "$temp_file" "$PROMPT_REGISTRY_FILE"

        # Output prompt with version metadata as comment
        echo "<!-- Prompt Version: $version_id -->"
        cat "$prompt_file"
    else
        echo "ERROR: Prompt file not found: $prompt_file" >&2
        return 1
    fi
}

# ============================================================================
# Outcome Recording
# ============================================================================

# Record outcome for a prompt version
record_prompt_outcome() {
    local version_id="$1"
    local outcome="$2"  # success, failure
    local prompt_type="${3:-}"
    local ab_test_id="${4:-}"
    local test_group="${5:-}"

    # Record to outcomes log
    local outcome_record=$(jq -nc \
        --arg version "$version_id" \
        --arg outcome "$outcome" \
        --arg type "$prompt_type" \
        --arg test_id "$ab_test_id" \
        --arg group "$test_group" \
        --arg recorded_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            version_id: $version,
            outcome: $outcome,
            prompt_type: $type,
            ab_test_id: (if $test_id == "" then null else $test_id end),
            test_group: (if $group == "" then null else $group end),
            recorded_at: $recorded_at
        }')

    echo "$outcome_record" >> "$PROMPT_OUTCOMES_FILE"

    # Update registry metrics
    if [ -n "$prompt_type" ]; then
        local temp_file="${PROMPT_REGISTRY_FILE}.tmp"
        if [ "$outcome" = "success" ]; then
            jq --arg type "$prompt_type" \
               --arg version "$version_id" \
               '.prompts[$type] = [.prompts[$type][] |
                   if .version_id == $version then
                       .metrics.successes += 1 |
                       .metrics.success_rate = (if .metrics.total_uses > 0 then .metrics.successes / .metrics.total_uses else 0 end)
                   else . end
               ]' "$PROMPT_REGISTRY_FILE" > "$temp_file"
        else
            jq --arg type "$prompt_type" \
               --arg version "$version_id" \
               '.prompts[$type] = [.prompts[$type][] |
                   if .version_id == $version then
                       .metrics.failures += 1 |
                       .metrics.success_rate = (if .metrics.total_uses > 0 then .metrics.successes / .metrics.total_uses else 0 end)
                   else . end
               ]' "$PROMPT_REGISTRY_FILE" > "$temp_file"
        fi
        mv "$temp_file" "$PROMPT_REGISTRY_FILE"
    fi

    # Update A/B test results
    if [ -n "$ab_test_id" ] && [ -n "$test_group" ] && [ "$outcome" = "success" ]; then
        local ab_temp="${PROMPT_AB_CONFIG_FILE}.tmp"
        jq --arg id "$ab_test_id" \
           --arg group "$test_group" \
           '.active_tests[$id].results[$group].successes += 1' "$PROMPT_AB_CONFIG_FILE" > "$ab_temp"
        mv "$ab_temp" "$PROMPT_AB_CONFIG_FILE"
    fi

    log_prompt "INFO" "Recorded outcome: $version_id -> $outcome"
}

# Get metrics for a prompt version
get_prompt_metrics() {
    local prompt_type="$1"
    local version_id="${2:-}"

    if [ -n "$version_id" ]; then
        jq --arg type "$prompt_type" \
           --arg version "$version_id" \
           '.prompts[$type][] | select(.version_id == $version) | .metrics' "$PROMPT_REGISTRY_FILE"
    else
        jq --arg type "$prompt_type" \
           '.prompts[$type] | map({version_id, metrics})' "$PROMPT_REGISTRY_FILE"
    fi
}

# Export functions
export -f register_prompt_version 2>/dev/null || true
export -f get_prompt_versions 2>/dev/null || true
export -f get_production_version 2>/dev/null || true
export -f get_prompt 2>/dev/null || true
export -f start_ab_test 2>/dev/null || true
export -f select_ab_version 2>/dev/null || true
export -f analyze_ab_test 2>/dev/null || true
export -f end_ab_test 2>/dev/null || true
export -f record_prompt_outcome 2>/dev/null || true
export -f get_prompt_metrics 2>/dev/null || true

log_prompt "INFO" "Prompt manager library loaded"
