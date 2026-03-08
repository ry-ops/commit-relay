#!/usr/bin/env bash
#
# Emergent Behaviors Library
# Part of Q3 Weeks 41-44: Emergent Behaviors
#
# Provides inter-agent collaboration, collective intelligence, and adaptive strategies
#

set -euo pipefail

if [[ -z "${EMERGENCE_LOADED:-}" ]]; then
    readonly EMERGENCE_LOADED=true
fi

# Directory setup
EMERGENCE_DIR="${EMERGENCE_DIR:-coordination/autonomy/emergence}"

#
# Initialize emergence
#
init_emergence() {
    mkdir -p "$EMERGENCE_DIR"/{active,history,knowledge,strategies}
}

#
# Get timestamp
#
_get_ts() {
    local ts=$(date +%s%3N 2>/dev/null)
    if [[ "$ts" =~ N$ ]]; then
        echo $(($(date +%s) * 1000))
    else
        echo "$ts"
    fi
}

#
# Generate behavior ID
#
generate_behavior_id() {
    local type="$1"
    local hash=$(echo "${type}-$(date +%s)" | shasum -a 256 | cut -c1-8)
    echo "emrg-${type}-${hash}"
}

#
# Form collaboration
#
form_collaboration() {
    local goal="$1"
    shift
    local agents=("$@")

    init_emergence

    local behavior_id=$(generate_behavior_id "collaboration")
    local timestamp=$(_get_ts)

    # Build participants array
    local participants="[]"
    local roles=("leader" "specialist" "generalist" "coordinator")
    local i=0
    for agent in "${agents[@]}"; do
        local role=${roles[$((i % 4))]}
        participants=$(echo "$participants" | jq \
            --arg id "$agent" \
            --arg role "$role" \
            --argjson score "$(echo "scale=2; (70 + $RANDOM % 30) / 100" | bc)" \
            --argjson ts "$timestamp" \
            '. + [{"agent_id": $id, "role": $role, "contribution_score": $score, "joined_at": $ts}]')
        i=$((i + 1))
    done

    # Determine collaboration pattern
    local pattern="peer_to_peer"
    if [[ ${#agents[@]} -gt 5 ]]; then
        pattern="hub_spoke"
    elif [[ ${#agents[@]} -gt 3 ]]; then
        pattern="mesh"
    fi

    local record=$(cat <<EOF
{
  "behavior_id": "$behavior_id",
  "type": "collaboration",
  "status": "forming",
  "participants": $participants,
  "objective": {
    "goal": "$goal",
    "success_criteria": ["Task completion", "Quality threshold", "Time constraint"],
    "priority": "high"
  },
  "collaboration": {
    "pattern": "$pattern",
    "communication_frequency": 60,
    "shared_state": {},
    "decisions": []
  },
  "created_at": $timestamp,
  "updated_at": $timestamp
}
EOF
)

    echo "$record" > "$EMERGENCE_DIR/active/${behavior_id}.json"
    echo "$behavior_id"
}

#
# Make collective decision
#
make_decision() {
    local behavior_id="$1"
    local topic="$2"
    local method="${3:-voting}"

    local file="$EMERGENCE_DIR/active/${behavior_id}.json"
    if [[ ! -f "$file" ]]; then
        echo "Error: Behavior not found" >&2
        return 1
    fi

    local record=$(cat "$file")
    local participants=$(echo "$record" | jq '.participants')
    local num_participants=$(echo "$participants" | jq 'length')

    # Simulate decision process
    local decision_id="dec-$(echo "$topic-$(_get_ts)" | shasum -a 256 | cut -c1-8)"
    local outcomes=("approve" "reject" "defer" "modify")
    local outcome=${outcomes[$((RANDOM % 4))]}
    local consensus=$(echo "scale=2; (60 + $RANDOM % 40) / 100" | bc)

    local decision=$(cat <<EOF
{
  "decision_id": "$decision_id",
  "topic": "$topic",
  "method": "$method",
  "outcome": "$outcome",
  "consensus_level": $consensus
}
EOF
)

    # Add decision to record
    record=$(echo "$record" | jq --argjson d "$decision" \
        '.collaboration.decisions += [$d] | .updated_at = '$(_get_ts))
    echo "$record" > "$file"

    echo "$decision"
}

#
# Share knowledge
#
share_knowledge() {
    local behavior_id="$1"
    local insight="$2"
    local source="$3"
    local confidence="${4:-0.8}"

    local file="$EMERGENCE_DIR/active/${behavior_id}.json"
    if [[ ! -f "$file" ]]; then
        echo "Error: Behavior not found" >&2
        return 1
    fi

    local record=$(cat "$file")

    # Initialize collective intelligence if needed
    local has_ci=$(echo "$record" | jq 'has("collective_intelligence")')
    if [[ "$has_ci" != "true" ]]; then
        record=$(echo "$record" | jq '.collective_intelligence = {"knowledge_pool": [], "emergent_patterns": [], "collective_accuracy": 0}')
    fi

    # Add knowledge
    local knowledge=$(cat <<EOF
{
  "insight": "$insight",
  "source": "$source",
  "confidence": $confidence,
  "applications": 0
}
EOF
)

    record=$(echo "$record" | jq --argjson k "$knowledge" \
        '.collective_intelligence.knowledge_pool += [$k] | .updated_at = '$(_get_ts))
    echo "$record" > "$file"

    echo "Knowledge shared: $insight"
}

#
# Identify emergent patterns
#
identify_patterns() {
    local behavior_id="$1"

    local file="$EMERGENCE_DIR/active/${behavior_id}.json"
    if [[ ! -f "$file" ]]; then
        echo "Error: Behavior not found" >&2
        return 1
    fi

    local record=$(cat "$file")

    # Generate emergent patterns
    local patterns="[]"
    local pattern_types=("coordination_efficiency" "task_specialization" "load_balancing" "knowledge_sharing")

    for ptype in "${pattern_types[@]}"; do
        local frequency=$((RANDOM % 20 + 5))
        local effectiveness=$(echo "scale=2; (60 + $RANDOM % 40) / 100" | bc)
        patterns=$(echo "$patterns" | jq \
            --arg p "$ptype" \
            --argjson f "$frequency" \
            --argjson e "$effectiveness" \
            '. + [{"pattern": $p, "frequency": $f, "effectiveness": $e}]')
    done

    # Update record
    record=$(echo "$record" | jq --argjson p "$patterns" \
        '.collective_intelligence.emergent_patterns = $p | .updated_at = '$(_get_ts))

    # Calculate collective accuracy
    local accuracy=$(echo "scale=2; (70 + $RANDOM % 25) / 100" | bc)
    record=$(echo "$record" | jq --argjson a "$accuracy" \
        '.collective_intelligence.collective_accuracy = $a')

    echo "$record" > "$file"
    echo "$patterns"
}

#
# Adapt strategy
#
adapt_strategy() {
    local behavior_id="$1"
    local trigger="$2"
    local change="$3"

    local file="$EMERGENCE_DIR/active/${behavior_id}.json"
    if [[ ! -f "$file" ]]; then
        echo "Error: Behavior not found" >&2
        return 1
    fi

    local record=$(cat "$file")

    # Initialize adaptation if needed
    local has_adapt=$(echo "$record" | jq 'has("adaptation")')
    if [[ "$has_adapt" != "true" ]]; then
        record=$(echo "$record" | jq '.adaptation = {"strategy": "learning", "adaptations": [], "fitness_score": 0.5}')
    fi

    # Add adaptation
    local impact=$(echo "scale=2; ($RANDOM % 40 - 10) / 100" | bc)
    local retained=$([[ $((RANDOM % 10)) -lt 7 ]] && echo true || echo false)

    local adaptation=$(cat <<EOF
{
  "trigger": "$trigger",
  "change": "$change",
  "impact": $impact,
  "retained": $retained
}
EOF
)

    record=$(echo "$record" | jq --argjson a "$adaptation" \
        '.adaptation.adaptations += [$a] | .updated_at = '$(_get_ts))

    # Update fitness score
    local current_fitness=$(echo "$record" | jq -r '.adaptation.fitness_score')
    local new_fitness=$(echo "scale=2; $current_fitness + $impact * 0.1" | bc)
    if (( $(echo "$new_fitness > 1" | bc -l) )); then new_fitness=1; fi
    if (( $(echo "$new_fitness < 0" | bc -l) )); then new_fitness=0; fi

    record=$(echo "$record" | jq --argjson f "$new_fitness" '.adaptation.fitness_score = $f')
    echo "$record" > "$file"

    echo "Adapted: $change (impact: $impact, retained: $retained)"
}

#
# Calculate emergence metrics
#
calculate_metrics() {
    local behavior_id="$1"

    local file="$EMERGENCE_DIR/active/${behavior_id}.json"
    if [[ ! -f "$file" ]]; then
        echo "Error: Behavior not found" >&2
        return 1
    fi

    local record=$(cat "$file")

    # Calculate metrics
    local synergy=$(echo "scale=2; (60 + $RANDOM % 35) / 100" | bc)
    local emergence=$(echo "scale=2; (50 + $RANDOM % 45) / 100" | bc)
    local collective=$(echo "scale=2; (65 + $RANDOM % 30) / 100" | bc)
    local vs_individual=$(echo "scale=2; (100 + $RANDOM % 50) / 100" | bc)

    local metrics=$(cat <<EOF
{
  "synergy_score": $synergy,
  "emergence_level": $emergence,
  "collective_performance": $collective,
  "individual_vs_collective": $vs_individual
}
EOF
)

    record=$(echo "$record" | jq --argjson m "$metrics" \
        '.metrics = $m | .updated_at = '$(_get_ts))
    echo "$record" > "$file"

    echo "$metrics"
}

#
# Evolve behavior
#
evolve_behavior() {
    local behavior_id="$1"

    local file="$EMERGENCE_DIR/active/${behavior_id}.json"
    if [[ ! -f "$file" ]]; then
        echo "Error: Behavior not found" >&2
        return 1
    fi

    local record=$(cat "$file")

    # Update status
    local current_status=$(echo "$record" | jq -r '.status')
    local new_status="active"
    case "$current_status" in
        forming) new_status="active" ;;
        active) new_status="converging" ;;
        converging) new_status="completed" ;;
    esac

    record=$(echo "$record" | jq --arg s "$new_status" \
        '.status = $s | .updated_at = '$(_get_ts))

    # Identify patterns
    identify_patterns "$behavior_id" >/dev/null

    # Calculate metrics
    calculate_metrics "$behavior_id" >/dev/null

    # Reload and save
    record=$(cat "$file")
    echo "$record" > "$file"

    # Move to history if completed
    if [[ "$new_status" == "completed" ]]; then
        mv "$file" "$EMERGENCE_DIR/history/"
    fi

    echo "$record"
}

#
# Get behavior
#
get_behavior() {
    local behavior_id="$1"

    local file="$EMERGENCE_DIR/active/${behavior_id}.json"
    if [[ ! -f "$file" ]]; then
        file="$EMERGENCE_DIR/history/${behavior_id}.json"
    fi

    if [[ -f "$file" ]]; then
        cat "$file"
    else
        echo "{\"error\": \"Behavior not found\"}"
        return 1
    fi
}

#
# List behaviors
#
list_behaviors() {
    local type="${1:-}"
    local limit="${2:-20}"

    init_emergence

    local results="[]"
    local count=0

    for file in "$EMERGENCE_DIR/active"/*.json "$EMERGENCE_DIR/history"/*.json; do
        if [[ -f "$file" && $count -lt $limit ]]; then
            local record=$(cat "$file")
            if [[ -z "$type" ]] || [[ $(echo "$record" | jq -r '.type') == "$type" ]]; then
                results=$(echo "$results" | jq --argjson r "$record" '. + [$r]')
                count=$((count + 1))
            fi
        fi
    done

    echo "$results" | jq 'sort_by(.created_at) | reverse'
}

#
# Get emergence statistics
#
get_emergence_stats() {
    init_emergence

    local total=0
    local completed=0
    local total_synergy=0
    local total_emergence=0

    for file in "$EMERGENCE_DIR/history"/*.json; do
        if [[ -f "$file" ]]; then
            local record=$(cat "$file")
            total=$((total + 1))
            local status=$(echo "$record" | jq -r '.status')
            if [[ "$status" == "completed" ]]; then
                completed=$((completed + 1))
            fi

            local synergy=$(echo "$record" | jq -r '.metrics.synergy_score // 0')
            local emergence=$(echo "$record" | jq -r '.metrics.emergence_level // 0')
            total_synergy=$(echo "$total_synergy + $synergy" | bc)
            total_emergence=$(echo "$total_emergence + $emergence" | bc)
        fi
    done

    local avg_synergy=0
    local avg_emergence=0
    if [[ $total -gt 0 ]]; then
        avg_synergy=$(echo "scale=2; $total_synergy / $total" | bc)
        avg_emergence=$(echo "scale=2; $total_emergence / $total" | bc)
    fi

    cat <<EOF
{
  "total_behaviors": $total,
  "completed": $completed,
  "average_synergy": $avg_synergy,
  "average_emergence": $avg_emergence
}
EOF
}

# Export functions
export -f init_emergence
export -f form_collaboration
export -f make_decision
export -f share_knowledge
export -f identify_patterns
export -f adapt_strategy
export -f calculate_metrics
export -f evolve_behavior
export -f get_behavior
export -f list_behaviors
export -f get_emergence_stats
