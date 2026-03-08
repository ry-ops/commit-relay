#!/bin/bash
# scripts/lib/prompt-versioning.sh
# Prompt Versioning and A/B Testing - Phase 4 Item 25
#
# Purpose:
# - Version control for prompts
# - A/B testing support
# - Track outcomes per prompt version
# - Support version selection
#
# Usage:
#   source scripts/lib/prompt-versioning.sh
#   prompt=$(get_prompt "worker-implementation" "active")
#   record_prompt_outcome "$prompt_id" "$version" "success"

set -eo pipefail

# Prevent re-sourcing
if [ -n "${PROMPT_VERSIONING_LOADED:-}" ]; then
    return 0
fi
PROMPT_VERSIONING_LOADED=1

# Load dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# Versioning directories
PROMPTS_DIR="$COMMIT_RELAY_HOME/coordination/prompts"
VERSIONS_DIR="$PROMPTS_DIR/versions"
OUTCOMES_DIR="$PROMPTS_DIR/outcomes"
AB_TESTS_DIR="$PROMPTS_DIR/ab-tests"
PROMPT_REGISTRY="$PROMPTS_DIR/registry.json"

# Ensure directories exist
mkdir -p "$VERSIONS_DIR" "$OUTCOMES_DIR" "$AB_TESTS_DIR"

##############################################################################
# create_prompt_version: Create a new version of a prompt
#
# Arguments:
#   $1 - Prompt ID (e.g., "worker-implementation")
#   $2 - Version (e.g., "1.0.0")
#   $3 - Prompt content (can be file path or string)
#   $4 - Description (optional)
#
# Returns:
#   Version ID
##############################################################################
create_prompt_version() {
    local prompt_id="$1"
    local version="$2"
    local content="$3"
    local description="${4:-}"

    local version_id="${prompt_id}-v${version}"
    local version_file="$VERSIONS_DIR/${version_id}.json"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Check if content is a file path
    local prompt_content
    if [ -f "$content" ]; then
        prompt_content=$(cat "$content" | jq -Rs '.')
    else
        prompt_content=$(echo "$content" | jq -Rs '.')
    fi

    # Calculate content hash
    local content_hash=$(echo "$prompt_content" | sha256sum | cut -d' ' -f1)

    # Create version record
    cat > "$version_file" <<EOF
{
  "version_id": "$version_id",
  "prompt_id": "$prompt_id",
  "version": "$version",
  "created_at": "$timestamp",
  "description": "$description",
  "content_hash": "$content_hash",
  "content": $prompt_content,
  "status": "draft",
  "metrics": {
    "uses": 0,
    "successes": 0,
    "failures": 0,
    "avg_tokens": 0,
    "avg_time_seconds": 0
  },
  "ab_test": null,
  "metadata": {
    "author": "${USER:-unknown}",
    "changelog": []
  }
}
EOF

    # Update registry
    update_prompt_registry "$prompt_id" "$version_id" "$version"

    echo "$version_id"
}

##############################################################################
# update_prompt_registry: Update the central prompt registry
##############################################################################
update_prompt_registry() {
    local prompt_id="$1"
    local version_id="$2"
    local version="$3"

    # Initialize registry if needed
    if [ ! -f "$PROMPT_REGISTRY" ]; then
        echo '{"prompts":{}}' > "$PROMPT_REGISTRY"
    fi

    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Update registry
    local updated=$(jq \
        --arg pid "$prompt_id" \
        --arg vid "$version_id" \
        --arg ver "$version" \
        --arg ts "$timestamp" \
        '.prompts[$pid] = (.prompts[$pid] // {}) |
         .prompts[$pid].versions = (.prompts[$pid].versions // []) + [$vid] |
         .prompts[$pid].latest = $vid |
         .prompts[$pid].updated_at = $ts' \
        "$PROMPT_REGISTRY")

    echo "$updated" > "$PROMPT_REGISTRY"
}

##############################################################################
# activate_prompt_version: Activate a prompt version for use
##############################################################################
activate_prompt_version() {
    local version_id="$1"

    local version_file="$VERSIONS_DIR/${version_id}.json"

    if [ ! -f "$version_file" ]; then
        echo "ERROR: Version not found: $version_id" >&2
        return 1
    fi

    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Update status
    local updated=$(jq --arg ts "$timestamp" \
        '.status = "active" | .activated_at = $ts' \
        "$version_file")

    echo "$updated" > "$version_file"

    # Update registry
    local prompt_id=$(echo "$updated" | jq -r '.prompt_id')
    jq --arg pid "$prompt_id" --arg vid "$version_id" \
        '.prompts[$pid].active = $vid' \
        "$PROMPT_REGISTRY" > "${PROMPT_REGISTRY}.tmp" && \
        mv "${PROMPT_REGISTRY}.tmp" "$PROMPT_REGISTRY"

    echo "Activated $version_id"
}

##############################################################################
# get_prompt: Get prompt content by ID and version
#
# Arguments:
#   $1 - Prompt ID
#   $2 - Version (optional, defaults to "active")
#
# Returns:
#   Prompt content
##############################################################################
get_prompt() {
    local prompt_id="$1"
    local version="${2:-active}"

    local version_id

    if [ "$version" = "active" ] || [ "$version" = "latest" ]; then
        # Get from registry
        version_id=$(jq -r --arg pid "$prompt_id" \
            '.prompts[$pid].'"$version"' // empty' \
            "$PROMPT_REGISTRY" 2>/dev/null)

        if [ -z "$version_id" ]; then
            echo "ERROR: No $version version for prompt: $prompt_id" >&2
            return 1
        fi
    else
        version_id="${prompt_id}-v${version}"
    fi

    local version_file="$VERSIONS_DIR/${version_id}.json"

    if [ ! -f "$version_file" ]; then
        echo "ERROR: Version file not found: $version_file" >&2
        return 1
    fi

    # Return content
    jq -r '.content' "$version_file"
}

##############################################################################
# create_ab_test: Create an A/B test for prompts
#
# Arguments:
#   $1 - Test name
#   $2 - Control version ID
#   $3 - Treatment version ID
#   $4 - Traffic split (0-100 for treatment)
##############################################################################
create_ab_test() {
    local test_name="$1"
    local control_id="$2"
    local treatment_id="$3"
    local traffic_split="${4:-50}"

    local test_id="ab-$(date +%s)-$(openssl rand -hex 3 2>/dev/null || echo $RANDOM)"
    local test_file="$AB_TESTS_DIR/${test_id}.json"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    cat > "$test_file" <<EOF
{
  "test_id": "$test_id",
  "name": "$test_name",
  "created_at": "$timestamp",
  "status": "running",
  "control": {
    "version_id": "$control_id",
    "traffic_percent": $((100 - traffic_split))
  },
  "treatment": {
    "version_id": "$treatment_id",
    "traffic_percent": $traffic_split
  },
  "results": {
    "control": {
      "uses": 0,
      "successes": 0,
      "failures": 0,
      "avg_tokens": 0
    },
    "treatment": {
      "uses": 0,
      "successes": 0,
      "failures": 0,
      "avg_tokens": 0
    }
  },
  "significance": {
    "p_value": null,
    "winner": null,
    "confidence": null
  }
}
EOF

    echo "$test_id"
}

##############################################################################
# select_ab_variant: Select variant for A/B test
#
# Arguments:
#   $1 - Test ID
#
# Returns:
#   Selected version ID
##############################################################################
select_ab_variant() {
    local test_id="$1"

    local test_file="$AB_TESTS_DIR/${test_id}.json"

    if [ ! -f "$test_file" ]; then
        echo "ERROR: Test not found: $test_id" >&2
        return 1
    fi

    local traffic_split=$(jq -r '.treatment.traffic_percent' "$test_file")
    local random_num=$((RANDOM % 100))

    if [ "$random_num" -lt "$traffic_split" ]; then
        jq -r '.treatment.version_id' "$test_file"
    else
        jq -r '.control.version_id' "$test_file"
    fi
}

##############################################################################
# record_prompt_outcome: Record outcome for a prompt usage
#
# Arguments:
#   $1 - Prompt ID
#   $2 - Version ID
#   $3 - Outcome (success/failure)
#   $4 - Tokens used
#   $5 - Time in seconds
#   $6 - AB test ID (optional)
##############################################################################
record_prompt_outcome() {
    local prompt_id="$1"
    local version_id="$2"
    local outcome="$3"
    local tokens_used="${4:-0}"
    local time_seconds="${5:-0}"
    local ab_test_id="${6:-}"

    local outcome_id="out-$(date +%s)-$(openssl rand -hex 3 2>/dev/null || echo $RANDOM)"
    local outcome_file="$OUTCOMES_DIR/${outcome_id}.json"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Record outcome
    cat > "$outcome_file" <<EOF
{
  "outcome_id": "$outcome_id",
  "prompt_id": "$prompt_id",
  "version_id": "$version_id",
  "timestamp": "$timestamp",
  "outcome": "$outcome",
  "tokens_used": $tokens_used,
  "time_seconds": $time_seconds,
  "ab_test_id": $([ -n "$ab_test_id" ] && echo "\"$ab_test_id\"" || echo "null")
}
EOF

    # Update version metrics
    update_version_metrics "$version_id" "$outcome" "$tokens_used" "$time_seconds"

    # Update A/B test if applicable
    if [ -n "$ab_test_id" ]; then
        update_ab_test_results "$ab_test_id" "$version_id" "$outcome" "$tokens_used"
    fi

    echo "$outcome_id"
}

##############################################################################
# update_version_metrics: Update metrics for a prompt version
##############################################################################
update_version_metrics() {
    local version_id="$1"
    local outcome="$2"
    local tokens="$3"
    local time="$4"

    local version_file="$VERSIONS_DIR/${version_id}.json"

    if [ ! -f "$version_file" ]; then
        return 1
    fi

    # Calculate new metrics
    local updated=$(jq \
        --arg outcome "$outcome" \
        --argjson tokens "$tokens" \
        --argjson time "$time" \
        '.metrics.uses += 1 |
         if $outcome == "success" then .metrics.successes += 1 else .metrics.failures += 1 end |
         .metrics.avg_tokens = ((.metrics.avg_tokens * (.metrics.uses - 1) + $tokens) / .metrics.uses) |
         .metrics.avg_time_seconds = ((.metrics.avg_time_seconds * (.metrics.uses - 1) + $time) / .metrics.uses)' \
        "$version_file")

    echo "$updated" > "$version_file"
}

##############################################################################
# update_ab_test_results: Update A/B test results
##############################################################################
update_ab_test_results() {
    local test_id="$1"
    local version_id="$2"
    local outcome="$3"
    local tokens="$4"

    local test_file="$AB_TESTS_DIR/${test_id}.json"

    if [ ! -f "$test_file" ]; then
        return 1
    fi

    # Determine which variant
    local control_id=$(jq -r '.control.version_id' "$test_file")
    local variant="treatment"
    if [ "$version_id" = "$control_id" ]; then
        variant="control"
    fi

    # Update results
    local updated=$(jq \
        --arg variant "$variant" \
        --arg outcome "$outcome" \
        --argjson tokens "$tokens" \
        '.results[$variant].uses += 1 |
         if $outcome == "success" then .results[$variant].successes += 1 else .results[$variant].failures += 1 end |
         .results[$variant].avg_tokens = ((.results[$variant].avg_tokens * (.results[$variant].uses - 1) + $tokens) / .results[$variant].uses)' \
        "$test_file")

    echo "$updated" > "$test_file"

    # Check significance
    check_ab_significance "$test_id"
}

##############################################################################
# check_ab_significance: Check if A/B test has significant results
##############################################################################
check_ab_significance() {
    local test_id="$1"

    local test_file="$AB_TESTS_DIR/${test_id}.json"

    local control_uses=$(jq -r '.results.control.uses' "$test_file")
    local treatment_uses=$(jq -r '.results.treatment.uses' "$test_file")

    # Need minimum samples
    if [ "$control_uses" -lt 30 ] || [ "$treatment_uses" -lt 30 ]; then
        return
    fi

    local control_rate=$(jq -r '.results.control.successes / .results.control.uses' "$test_file")
    local treatment_rate=$(jq -r '.results.treatment.successes / .results.treatment.uses' "$test_file")

    # Simplified significance check
    local diff=$(echo "$treatment_rate - $control_rate" | bc)

    local winner="none"
    local confidence="low"

    if [ "$(echo "$diff > 0.1" | bc)" -eq 1 ]; then
        winner="treatment"
        confidence="high"
    elif [ "$(echo "$diff < -0.1" | bc)" -eq 1 ]; then
        winner="control"
        confidence="high"
    elif [ "$(echo "$diff > 0.05 || $diff < -0.05" | bc)" -eq 1 ]; then
        if [ "$(echo "$diff > 0" | bc)" -eq 1 ]; then
            winner="treatment"
        else
            winner="control"
        fi
        confidence="medium"
    fi

    # Update significance
    jq --arg winner "$winner" --arg conf "$confidence" \
        '.significance.winner = $winner | .significance.confidence = $conf' \
        "$test_file" > "${test_file}.tmp" && mv "${test_file}.tmp" "$test_file"
}

##############################################################################
# get_prompt_stats: Get statistics for a prompt
##############################################################################
get_prompt_stats() {
    local prompt_id="$1"

    # Get all versions for this prompt
    local versions=$(ls "$VERSIONS_DIR/${prompt_id}-v"*.json 2>/dev/null)

    if [ -z "$versions" ]; then
        echo '{"error":"No versions found"}'
        return 1
    fi

    local stats="[]"
    for version_file in $versions; do
        local version_stats=$(jq '{
            version_id: .version_id,
            version: .version,
            status: .status,
            metrics: .metrics,
            success_rate: (if .metrics.uses > 0 then .metrics.successes / .metrics.uses else 0 end)
        }' "$version_file")
        stats=$(echo "$stats" | jq --argjson vs "$version_stats" '. + [$vs]')
    done

    echo "$stats" | jq '{
        prompt_id: "'$prompt_id'",
        versions: .,
        best_version: (. | max_by(.success_rate) | .version_id),
        total_uses: ([.[].metrics.uses] | add)
    }'
}

##############################################################################
# conclude_ab_test: Conclude an A/B test and declare winner
##############################################################################
conclude_ab_test() {
    local test_id="$1"

    local test_file="$AB_TESTS_DIR/${test_id}.json"

    if [ ! -f "$test_file" ]; then
        echo "ERROR: Test not found: $test_id" >&2
        return 1
    fi

    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local winner=$(jq -r '.significance.winner' "$test_file")

    # Update test status
    local updated=$(jq --arg ts "$timestamp" \
        '.status = "concluded" | .concluded_at = $ts' \
        "$test_file")

    echo "$updated" > "$test_file"

    # Activate winner if there is one
    if [ "$winner" != "none" ] && [ "$winner" != "null" ]; then
        local winner_id
        if [ "$winner" = "treatment" ]; then
            winner_id=$(jq -r '.treatment.version_id' "$test_file")
        else
            winner_id=$(jq -r '.control.version_id' "$test_file")
        fi
        activate_prompt_version "$winner_id"
        echo "Winner: $winner_id"
    else
        echo "No clear winner"
    fi
}

##############################################################################
# list_prompts: List all registered prompts
##############################################################################
list_prompts() {
    if [ ! -f "$PROMPT_REGISTRY" ]; then
        echo '{"prompts":[]}'
        return
    fi

    jq '.prompts | to_entries | map({
        prompt_id: .key,
        versions: (.value.versions | length),
        active: .value.active,
        latest: .value.latest
    })' "$PROMPT_REGISTRY"
}

# Export functions
export -f create_prompt_version
export -f activate_prompt_version
export -f get_prompt
export -f create_ab_test
export -f select_ab_variant
export -f record_prompt_outcome
export -f get_prompt_stats
export -f conclude_ab_test
export -f list_prompts

# Log that library is loaded
if [ "${COMMIT_RELAY_LOG_LEVEL:-1}" -le 0 ] 2>/dev/null; then
    echo "[PROMPT-VERSION] Prompt versioning library loaded" >&2
fi
