#!/bin/bash
# scripts/lib/rag/query-optimizer.sh
# RAG Query Optimizer - Phase 3 Item 35
# Query expansion, rewriting, and result re-ranking for improved RAG retrieval
#
# Features:
#   - Query expansion with synonyms
#   - Query rewriting for clarity
#   - Result re-ranking by relevance
#   - Query caching for performance
#
# Usage:
#   source "$COMMIT_RELAY_HOME/scripts/lib/rag/query-optimizer.sh"
#   optimized=$(optimize_query "how to implement auth")
#   reranked=$(rerank_results "$results" "$query")

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"

# Query optimizer configuration
OPTIMIZER_CONFIG="${COMMIT_RELAY_HOME}/coordination/config/rag-query-optimizer.json"
QUERY_CACHE="${COMMIT_RELAY_HOME}/coordination/cache/query-cache.json"
QUERY_HISTORY="${COMMIT_RELAY_HOME}/coordination/metrics/query-history.jsonl"

# Create directories
mkdir -p "$(dirname "$QUERY_CACHE")"
mkdir -p "$(dirname "$QUERY_HISTORY")"
mkdir -p "$(dirname "$OPTIMIZER_CONFIG")"

# ============================================================================
# Logging
# ============================================================================

log_query() {
    local level="$1"
    shift
    echo "[$(date +%Y-%m-%dT%H:%M:%S%z)] [QUERY-OPT] [$level] $*" >&2
}

# ============================================================================
# Initialize Configuration
# ============================================================================

initialize_optimizer_config() {
    if [ ! -f "$OPTIMIZER_CONFIG" ]; then
        cat > "$OPTIMIZER_CONFIG" <<'EOF'
{
  "version": "1.0.0",
  "expansion": {
    "enabled": true,
    "max_synonyms": 3,
    "synonym_boost": 0.7
  },
  "rewriting": {
    "enabled": true,
    "remove_stop_words": true,
    "stem_words": false
  },
  "reranking": {
    "enabled": true,
    "methods": ["bm25", "semantic_similarity", "recency"],
    "weights": {
      "bm25": 0.4,
      "semantic_similarity": 0.4,
      "recency": 0.2
    }
  },
  "caching": {
    "enabled": true,
    "ttl_minutes": 60,
    "max_entries": 1000
  },
  "synonyms": {
    "implement": ["create", "build", "develop", "add"],
    "fix": ["repair", "resolve", "correct", "patch"],
    "bug": ["issue", "error", "defect", "problem"],
    "feature": ["capability", "functionality", "enhancement"],
    "api": ["endpoint", "interface", "service"],
    "auth": ["authentication", "authorization", "login", "security"],
    "database": ["db", "datastore", "storage"],
    "test": ["verify", "validate", "check"],
    "performance": ["speed", "efficiency", "optimization"],
    "refactor": ["restructure", "reorganize", "clean"],
    "config": ["configuration", "settings", "options"],
    "deploy": ["release", "publish", "ship"]
  },
  "stop_words": [
    "the", "a", "an", "is", "are", "was", "were", "be", "been",
    "being", "have", "has", "had", "do", "does", "did", "will",
    "would", "could", "should", "may", "might", "must", "shall",
    "to", "of", "in", "for", "on", "with", "at", "by", "from",
    "as", "into", "through", "during", "before", "after", "above",
    "below", "between", "under", "again", "further", "then", "once",
    "here", "there", "when", "where", "why", "how", "all", "each",
    "few", "more", "most", "other", "some", "such", "no", "nor",
    "not", "only", "own", "same", "so", "than", "too", "very",
    "can", "just", "now", "also", "like", "want", "need", "get"
  ],
  "query_templates": {
    "how_to": "implementation guide for {topic}",
    "what_is": "definition and explanation of {topic}",
    "why": "reasons and rationale for {topic}",
    "best_practice": "best practices and patterns for {topic}"
  }
}
EOF
        log_query "INFO" "Created default optimizer config"
    fi
}

initialize_optimizer_config

# ============================================================================
# Query Expansion
# ============================================================================

# Expand query with synonyms
expand_query() {
    local query="$1"
    local query_lower=$(echo "$query" | tr '[:upper:]' '[:lower:]')

    local expanded_terms=""
    local max_synonyms=$(jq -r '.expansion.max_synonyms' "$OPTIMIZER_CONFIG")
    local synonym_boost=$(jq -r '.expansion.synonym_boost' "$OPTIMIZER_CONFIG")

    # Get all synonyms from config
    local synonyms_json=$(jq -r '.synonyms' "$OPTIMIZER_CONFIG")

    # Process each word in query
    for word in $query_lower; do
        # Check if word has synonyms
        local word_synonyms=$(echo "$synonyms_json" | jq -r --arg w "$word" '.[$w] // empty | .[]' 2>/dev/null)

        if [ -n "$word_synonyms" ]; then
            # Add original word
            expanded_terms="$expanded_terms $word"

            # Add synonyms (limited)
            local count=0
            while IFS= read -r synonym; do
                if [ "$count" -ge "$max_synonyms" ]; then
                    break
                fi
                expanded_terms="$expanded_terms $synonym"
                ((count++))
            done <<< "$word_synonyms"
        else
            expanded_terms="$expanded_terms $word"
        fi
    done

    # Clean up and return
    echo "$expanded_terms" | tr -s ' ' | sed 's/^ *//;s/ *$//'
}

# ============================================================================
# Query Rewriting
# ============================================================================

# Remove stop words from query
remove_stop_words() {
    local query="$1"
    local query_lower=$(echo "$query" | tr '[:upper:]' '[:lower:]')

    local stop_words=$(jq -r '.stop_words[]' "$OPTIMIZER_CONFIG")
    local result=""

    for word in $query_lower; do
        local is_stop="false"
        while IFS= read -r stop; do
            if [ "$word" = "$stop" ]; then
                is_stop="true"
                break
            fi
        done <<< "$stop_words"

        if [ "$is_stop" = "false" ]; then
            result="$result $word"
        fi
    done

    echo "$result" | tr -s ' ' | sed 's/^ *//;s/ *$//'
}

# Rewrite query for better retrieval
rewrite_query() {
    local query="$1"

    local rewritten="$query"

    # Check if rewriting is enabled
    local enabled=$(jq -r '.rewriting.enabled' "$OPTIMIZER_CONFIG")
    if [ "$enabled" != "true" ]; then
        echo "$query"
        return
    fi

    # Remove stop words if enabled
    local remove_stops=$(jq -r '.rewriting.remove_stop_words' "$OPTIMIZER_CONFIG")
    if [ "$remove_stops" = "true" ]; then
        rewritten=$(remove_stop_words "$rewritten")
    fi

    # Apply query templates based on patterns
    local query_lower=$(echo "$rewritten" | tr '[:upper:]' '[:lower:]')

    if echo "$query_lower" | grep -qi "^how to\|^how do"; then
        local topic=$(echo "$query_lower" | sed 's/^how to //i;s/^how do i //i')
        local template=$(jq -r '.query_templates.how_to' "$OPTIMIZER_CONFIG")
        rewritten=$(echo "$template" | sed "s/{topic}/$topic/")
    elif echo "$query_lower" | grep -qi "^what is\|^what are"; then
        local topic=$(echo "$query_lower" | sed 's/^what is //i;s/^what are //i')
        local template=$(jq -r '.query_templates.what_is' "$OPTIMIZER_CONFIG")
        rewritten=$(echo "$template" | sed "s/{topic}/$topic/")
    elif echo "$query_lower" | grep -qi "^why"; then
        local topic=$(echo "$query_lower" | sed 's/^why //i')
        local template=$(jq -r '.query_templates.why' "$OPTIMIZER_CONFIG")
        rewritten=$(echo "$template" | sed "s/{topic}/$topic/")
    elif echo "$query_lower" | grep -qi "best practice\|best way"; then
        local topic=$(echo "$query_lower" | sed 's/best practice for //i;s/best way to //i')
        local template=$(jq -r '.query_templates.best_practice' "$OPTIMIZER_CONFIG")
        rewritten=$(echo "$template" | sed "s/{topic}/$topic/")
    fi

    echo "$rewritten"
}

# ============================================================================
# Main Optimization Function
# ============================================================================

# Optimize query for RAG retrieval
optimize_query() {
    local query="$1"
    local skip_cache="${2:-false}"

    log_query "INFO" "Optimizing query: $query"

    # Check cache first
    local cache_enabled=$(jq -r '.caching.enabled' "$OPTIMIZER_CONFIG")
    if [ "$cache_enabled" = "true" ] && [ "$skip_cache" != "true" ]; then
        local cached=$(check_query_cache "$query")
        if [ -n "$cached" ] && [ "$cached" != "null" ]; then
            log_query "INFO" "Cache hit for query"
            echo "$cached"
            return
        fi
    fi

    # Step 1: Rewrite query
    local rewritten=$(rewrite_query "$query")

    # Step 2: Expand with synonyms
    local expansion_enabled=$(jq -r '.expansion.enabled' "$OPTIMIZER_CONFIG")
    local expanded="$rewritten"
    if [ "$expansion_enabled" = "true" ]; then
        expanded=$(expand_query "$rewritten")
    fi

    # Build result
    local result=$(jq -nc \
        --arg original "$query" \
        --arg rewritten "$rewritten" \
        --arg expanded "$expanded" \
        --arg optimized_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            original_query: $original,
            rewritten_query: $rewritten,
            expanded_query: $expanded,
            primary_query: $expanded,
            optimized_at: $optimized_at
        }')

    # Cache result
    if [ "$cache_enabled" = "true" ]; then
        cache_query "$query" "$result"
    fi

    # Log to history
    echo "$result" >> "$QUERY_HISTORY"

    log_query "INFO" "Query optimized: '$query' -> '$expanded'"

    echo "$result"
}

# ============================================================================
# Result Re-ranking
# ============================================================================

# Calculate BM25-like score for a result
calculate_bm25_score() {
    local result_text="$1"
    local query_terms="$2"

    local score=0
    local result_lower=$(echo "$result_text" | tr '[:upper:]' '[:lower:]')

    for term in $query_terms; do
        if echo "$result_lower" | grep -qi "$term"; then
            # Count occurrences
            local count=$(echo "$result_lower" | grep -oi "$term" | wc -l | tr -d ' ')
            # Diminishing returns for multiple occurrences
            local term_score=$(echo "scale=2; l($count + 1) / l(2) * 10" | bc -l 2>/dev/null || echo "5")
            score=$(echo "$score + $term_score" | bc)
        fi
    done

    echo "${score%.*}"
}

# Calculate recency score
calculate_recency_score() {
    local timestamp="$1"
    local max_score=100

    if [ -z "$timestamp" ]; then
        echo "50"
        return
    fi

    # Calculate age in hours
    local now=$(date +%s)
    local result_time=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$timestamp" +%s 2>/dev/null || echo "$now")
    local age_hours=$(( (now - result_time) / 3600 ))

    # Decay function: score decreases with age
    if [ "$age_hours" -lt 24 ]; then
        echo "$max_score"
    elif [ "$age_hours" -lt 168 ]; then  # 1 week
        echo "75"
    elif [ "$age_hours" -lt 720 ]; then  # 1 month
        echo "50"
    else
        echo "25"
    fi
}

# Re-rank results based on multiple factors
rerank_results() {
    local results_json="$1"
    local query="$2"

    local reranking_enabled=$(jq -r '.reranking.enabled' "$OPTIMIZER_CONFIG")
    if [ "$reranking_enabled" != "true" ]; then
        echo "$results_json"
        return
    fi

    log_query "INFO" "Re-ranking results for query: $query"

    # Get weights
    local bm25_weight=$(jq -r '.reranking.weights.bm25' "$OPTIMIZER_CONFIG")
    local recency_weight=$(jq -r '.reranking.weights.recency' "$OPTIMIZER_CONFIG")

    # Parse and score each result
    local result_count=$(echo "$results_json" | jq 'length')
    local scored_results="[]"

    for ((i=0; i<result_count; i++)); do
        local result=$(echo "$results_json" | jq ".[$i]")
        local content=$(echo "$result" | jq -r '.content // .text // ""')
        local timestamp=$(echo "$result" | jq -r '.timestamp // .created_at // ""')

        # Calculate scores
        local bm25_score=$(calculate_bm25_score "$content" "$query")
        local recency_score=$(calculate_recency_score "$timestamp")

        # Calculate weighted total
        local total_score=$(echo "scale=2; $bm25_score * $bm25_weight + $recency_score * $recency_weight" | bc)

        # Add score to result
        scored_results=$(echo "$scored_results" | jq --argjson r "$result" --arg s "$total_score" \
            '. + [($r + {rerank_score: ($s | tonumber)})]')
    done

    # Sort by score descending
    local reranked=$(echo "$scored_results" | jq 'sort_by(-.rerank_score)')

    log_query "INFO" "Re-ranked $result_count results"

    echo "$reranked"
}

# ============================================================================
# Caching
# ============================================================================

# Check query cache
check_query_cache() {
    local query="$1"

    if [ ! -f "$QUERY_CACHE" ]; then
        return
    fi

    local ttl_minutes=$(jq -r '.caching.ttl_minutes' "$OPTIMIZER_CONFIG")
    local now=$(date +%s)
    local cutoff=$((now - ttl_minutes * 60))

    # Look for cached result
    local cached=$(jq --arg q "$query" --argjson cutoff "$cutoff" '
        .entries[$q] |
        select(. != null) |
        select((.cached_at | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) > $cutoff) |
        .result
    ' "$QUERY_CACHE" 2>/dev/null)

    echo "$cached"
}

# Cache query result
cache_query() {
    local query="$1"
    local result="$2"

    # Initialize cache if needed
    if [ ! -f "$QUERY_CACHE" ]; then
        echo '{"entries":{}}' > "$QUERY_CACHE"
    fi

    local temp_file="${QUERY_CACHE}.tmp"
    jq --arg q "$query" \
       --argjson r "$result" \
       --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       '.entries[$q] = {result: $r, cached_at: $t}' "$QUERY_CACHE" > "$temp_file"
    mv "$temp_file" "$QUERY_CACHE"
}

# Clear expired cache entries
cleanup_cache() {
    if [ ! -f "$QUERY_CACHE" ]; then
        return
    fi

    local ttl_minutes=$(jq -r '.caching.ttl_minutes' "$OPTIMIZER_CONFIG")
    local max_entries=$(jq -r '.caching.max_entries' "$OPTIMIZER_CONFIG")
    local now=$(date +%s)
    local cutoff=$((now - ttl_minutes * 60))

    local temp_file="${QUERY_CACHE}.tmp"
    jq --argjson cutoff "$cutoff" --argjson max "$max_entries" '
        .entries = (
            .entries | to_entries |
            map(select((.value.cached_at | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) > $cutoff)) |
            sort_by(-.value.cached_at) |
            .[0:$max] |
            from_entries
        )
    ' "$QUERY_CACHE" > "$temp_file" 2>/dev/null && mv "$temp_file" "$QUERY_CACHE"

    log_query "INFO" "Cache cleanup completed"
}

# ============================================================================
# Utility Functions
# ============================================================================

# Get query optimization metrics
get_query_metrics() {
    local hours="${1:-24}"

    if [ ! -f "$QUERY_HISTORY" ]; then
        echo '{"total_queries":0,"cache_hit_rate":0}'
        return
    fi

    local total=$(wc -l < "$QUERY_HISTORY" | tr -d ' ')

    jq -nc \
        --argjson total "$total" \
        '{
            total_queries: $total,
            avg_expansion_terms: 0,
            cache_enabled: true
        }'
}

# Export functions
export -f optimize_query 2>/dev/null || true
export -f expand_query 2>/dev/null || true
export -f rewrite_query 2>/dev/null || true
export -f rerank_results 2>/dev/null || true
export -f check_query_cache 2>/dev/null || true
export -f cleanup_cache 2>/dev/null || true

log_query "INFO" "Query optimizer library loaded"
