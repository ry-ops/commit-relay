#!/usr/bin/env bash
#
# RAG Retriever
# Part of Q2: RAG Pipeline for Library
#
# Provides retrieval functions for the RAG pipeline:
# - Keyword-based search
# - Metadata filtering
# - Chunk retrieval
# - Relevance ranking
#
# Usage:
#   source scripts/lib/rag/retriever.sh
#   search_documents "authentication security"
#   retrieve_relevant_chunks "how to implement JWT" 5
#   search_by_metadata '{"extension":"pdf"}'

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"

# Directories
readonly EMBEDDINGS_DIR="$COMMIT_RELAY_HOME/coordination/knowledge-base/embeddings"
readonly CHUNKS_DIR="$EMBEDDINGS_DIR/chunks"
readonly METADATA_DIR="$EMBEDDINGS_DIR/metadata"
readonly INDEX_DIR="$EMBEDDINGS_DIR/indices"

# Source document processor for shared functions
source "$SCRIPT_DIR/document-processor.sh" 2>/dev/null || true

# Source logging
source "$COMMIT_RELAY_HOME/scripts/lib/logging.sh" 2>/dev/null || {
    log_info() { echo "[INFO] $1"; }
    log_warn() { echo "[WARN] $1"; }
    log_error() { echo "[ERROR] $1"; }
}

#------------------------------------------------------------------------------
# Text Processing
#------------------------------------------------------------------------------

# Tokenize and normalize query
normalize_query() {
    local query="$1"

    echo "$query" | \
        tr '[:upper:]' '[:lower:]' | \
        tr -cs '[:alpha:]' ' ' | \
        tr -s ' ' | \
        xargs
}

# Extract keywords from query
extract_query_keywords() {
    local query="$1"

    # Stop words to filter out
    local stop_words="a an the is are was were be been being have has had do does did will would could should may might must shall can"

    local normalized=$(normalize_query "$query")
    local keywords=""

    for word in $normalized; do
        # Skip stop words and short words
        if [ ${#word} -lt 3 ]; then
            continue
        fi

        local is_stop=false
        for stop in $stop_words; do
            if [ "$word" = "$stop" ]; then
                is_stop=true
                break
            fi
        done

        if [ "$is_stop" = "false" ]; then
            keywords="$keywords $word"
        fi
    done

    echo "$keywords" | xargs
}

#------------------------------------------------------------------------------
# Document Search
#------------------------------------------------------------------------------

# Search documents by keywords
search_documents() {
    local query="$1"
    local max_results="${2:-10}"

    local keywords=$(extract_query_keywords "$query")

    if [ -z "$keywords" ]; then
        log_warn "[RAG] No valid keywords in query"
        echo '[]'
        return 1
    fi

    log_info "[RAG] Searching for keywords: $keywords"

    # Score each document
    local results="[]"
    local master_index="$INDEX_DIR/master-index.jsonl"

    if [ ! -f "$master_index" ]; then
        echo '[]'
        return 0
    fi

    # Get all document IDs
    local doc_ids=$(cat "$master_index" | jq -r '.doc_id')

    for doc_id in $doc_ids; do
        local keyword_file="$INDEX_DIR/${doc_id}-keywords.json"

        if [ ! -f "$keyword_file" ]; then
            continue
        fi

        # Calculate score based on keyword matches
        local score=0
        local matched_keywords=""

        for keyword in $keywords; do
            local count=$(jq -r --arg kw "$keyword" '.keywords[] | select(.word == $kw) | .count // 0' "$keyword_file" 2>/dev/null || echo "0")

            if [ -n "$count" ] && [ "$count" != "null" ] && [ "$count" -gt 0 ]; then
                score=$((score + count))
                matched_keywords="$matched_keywords $keyword"
            fi
        done

        if [ $score -gt 0 ]; then
            local metadata=$(cat "$METADATA_DIR/${doc_id}.json" 2>/dev/null || echo '{}')

            local result=$(echo "$metadata" | jq \
                --argjson score "$score" \
                --arg matched "$matched_keywords" \
                '. + {score: $score, matched_keywords: ($matched | ltrimstr(" ") | split(" "))}')

            results=$(echo "$results" | jq --argjson r "$result" '. + [$r]')
        fi
    done

    # Sort by score and limit results
    echo "$results" | jq --argjson max "$max_results" 'sort_by(-.score) | .[:$max]'
}

# Search by metadata filters
search_by_metadata() {
    local filters="$1"
    local max_results="${2:-10}"

    local master_index="$INDEX_DIR/master-index.jsonl"

    if [ ! -f "$master_index" ]; then
        echo '[]'
        return 0
    fi

    # Build jq filter from JSON filters
    local jq_filter="."

    # Extension filter
    local ext=$(echo "$filters" | jq -r '.extension // empty')
    if [ -n "$ext" ]; then
        jq_filter="$jq_filter | select(.extension == \"$ext\")"
    fi

    # Author filter
    local author=$(echo "$filters" | jq -r '.author // empty')
    if [ -n "$author" ]; then
        jq_filter="$jq_filter | select(.author | contains(\"$author\"))"
    fi

    # Title filter
    local title=$(echo "$filters" | jq -r '.title // empty')
    if [ -n "$title" ]; then
        jq_filter="$jq_filter | select(.title | contains(\"$title\"))"
    fi

    # Date range filter
    local after=$(echo "$filters" | jq -r '.after // empty')
    if [ -n "$after" ]; then
        jq_filter="$jq_filter | select(.processed_at >= \"$after\")"
    fi

    local before=$(echo "$filters" | jq -r '.before // empty')
    if [ -n "$before" ]; then
        jq_filter="$jq_filter | select(.processed_at <= \"$before\")"
    fi

    cat "$master_index" | jq -s "map($jq_filter) | .[:$max_results]"
}

#------------------------------------------------------------------------------
# Chunk Retrieval
#------------------------------------------------------------------------------

# Retrieve relevant chunks for a query
retrieve_relevant_chunks() {
    local query="$1"
    local max_chunks="${2:-5}"
    local max_docs="${3:-3}"

    log_info "[RAG] Retrieving chunks for: $query"

    # First, find relevant documents
    local relevant_docs=$(search_documents "$query" "$max_docs")
    local doc_count=$(echo "$relevant_docs" | jq 'length')

    if [ "$doc_count" -eq 0 ]; then
        log_info "[RAG] No relevant documents found"
        echo '[]'
        return 0
    fi

    local keywords=$(extract_query_keywords "$query")
    local all_chunks="[]"

    # Get chunks from each relevant document
    echo "$relevant_docs" | jq -r '.[].doc_id' | while read -r doc_id; do
        local chunks_file="$CHUNKS_DIR/${doc_id}-chunks.jsonl"

        if [ ! -f "$chunks_file" ]; then
            continue
        fi

        # Score each chunk
        cat "$chunks_file" | while read -r chunk_json; do
            local content=$(echo "$chunk_json" | jq -r '.content' | tr '[:upper:]' '[:lower:]')
            local score=0

            for keyword in $keywords; do
                local matches=$(echo "$content" | grep -o "$keyword" | wc -l | tr -d ' ')
                score=$((score + matches))
            done

            if [ $score -gt 0 ]; then
                echo "$chunk_json" | jq --argjson s "$score" '. + {relevance_score: $s}'
            fi
        done
    done | jq -s "sort_by(-.relevance_score) | .[:$max_chunks]"
}

# Get chunks by document ID
get_chunks_by_doc() {
    local doc_id="$1"
    local start_index="${2:-0}"
    local count="${3:-10}"

    local chunks_file="$CHUNKS_DIR/${doc_id}-chunks.jsonl"

    if [ ! -f "$chunks_file" ]; then
        echo '[]'
        return 1
    fi

    cat "$chunks_file" | jq -s --argjson start "$start_index" --argjson count "$count" \
        '.[$start:($start + $count)]'
}

# Get specific chunk by ID
get_chunk() {
    local chunk_id="$1"

    # Extract doc_id from chunk_id (format: doc-xxx-chunk-n)
    local doc_id=$(echo "$chunk_id" | sed 's/-chunk-[0-9]*$//')
    local chunks_file="$CHUNKS_DIR/${doc_id}-chunks.jsonl"

    if [ ! -f "$chunks_file" ]; then
        echo '{"error": "Chunk not found"}'
        return 1
    fi

    cat "$chunks_file" | jq -s --arg id "$chunk_id" '.[] | select(.chunk_id == $id)'
}

#------------------------------------------------------------------------------
# Context Building
#------------------------------------------------------------------------------

# Build context from retrieved chunks
build_context() {
    local query="$1"
    local max_tokens="${2:-2000}"

    local chunks=$(retrieve_relevant_chunks "$query" 10)
    local chunk_count=$(echo "$chunks" | jq 'length')

    if [ "$chunk_count" -eq 0 ]; then
        echo '{"context": "", "sources": []}'
        return 0
    fi

    local context=""
    local sources="[]"
    local token_count=0

    # Approximate tokens as words / 0.75
    for i in $(seq 0 $((chunk_count - 1))); do
        local chunk=$(echo "$chunks" | jq ".[$i]")
        local content=$(echo "$chunk" | jq -r '.content')
        local chunk_id=$(echo "$chunk" | jq -r '.chunk_id')
        local doc_id=$(echo "$chunk" | jq -r '.doc_id')

        local word_count=$(echo "$content" | wc -w | tr -d ' ')
        local approx_tokens=$((word_count * 4 / 3))

        if [ $((token_count + approx_tokens)) -gt $max_tokens ]; then
            break
        fi

        context="$context\n\n---\n\n$content"
        token_count=$((token_count + approx_tokens))

        # Add to sources
        local source=$(jq -n \
            --arg chunk_id "$chunk_id" \
            --arg doc_id "$doc_id" \
            '{chunk_id: $chunk_id, doc_id: $doc_id}')

        sources=$(echo "$sources" | jq --argjson s "$source" '. + [$s]')
    done

    jq -n \
        --arg context "$context" \
        --argjson sources "$sources" \
        --argjson token_estimate "$token_count" \
        '{
            context: $context,
            sources: $sources,
            token_estimate: $token_estimate
        }'
}

#------------------------------------------------------------------------------
# Similarity Functions (Simple Implementation)
#------------------------------------------------------------------------------

# Calculate Jaccard similarity between two texts
calculate_similarity() {
    local text1="$1"
    local text2="$2"

    local words1=$(echo "$text1" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alpha:]' '\n' | sort -u)
    local words2=$(echo "$text2" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alpha:]' '\n' | sort -u)

    local intersection=$(echo "$words1" | grep -Fx -f <(echo "$words2") | wc -l | tr -d ' ')
    local union1=$(echo "$words1" | wc -l | tr -d ' ')
    local union2=$(echo "$words2" | wc -l | tr -d ' ')
    local union=$((union1 + union2 - intersection))

    if [ $union -eq 0 ]; then
        echo "0"
        return
    fi

    echo "scale=4; $intersection / $union" | bc
}

#------------------------------------------------------------------------------
# Enhancement #19: Semantic Search using Vector Similarity
#------------------------------------------------------------------------------

# Path to vector store JavaScript module
readonly VECTOR_STORE_JS="$COMMIT_RELAY_HOME/lib/rag/vector-store.js"

# Check if vector search is available
is_vector_search_available() {
    if [ ! -f "$VECTOR_STORE_JS" ]; then
        return 1
    fi

    # Check if node is available
    if ! command -v node &> /dev/null; then
        return 1
    fi

    # Check if vector DB index exists
    local index_file="$COMMIT_RELAY_HOME/coordination/vector-db/index.json"
    if [ ! -f "$index_file" ]; then
        return 1
    fi

    return 0
}

# Semantic search using vector similarity (Enhancement #19)
search_semantic() {
    local query="$1"
    local max_results="${2:-5}"
    local collection="${3:-all}"
    local min_similarity="${4:-0.6}"

    # Check if vector search is available
    if ! is_vector_search_available; then
        log_warn "[RAG] Vector search unavailable, falling back to keyword search"
        search_documents "$query" "$max_results"
        return $?
    fi

    log_info "[RAG] Performing semantic search for: $query"

    # Call vector store through Node.js
    local result
    result=$(node -e "
        const VectorStore = require('$VECTOR_STORE_JS');
        const vectorStore = new VectorStore();

        (async () => {
            await vectorStore.initialize();

            const options = {
                limit: $max_results,
                min_similarity: $min_similarity
            };

            if ('$collection' !== 'all') {
                options.collection = '$collection';
            }

            const results = await vectorStore.search(\`$query\`, options);

            // Format results for bash consumption
            const formatted = results.map(r => ({
                id: r.id,
                collection: r.collection,
                similarity: r.similarity,
                content: r.content.substring(0, 200),
                metadata: r.metadata
            }));

            console.log(JSON.stringify(formatted));
        })();
    " 2>/dev/null)

    if [ -z "$result" ] || [ "$result" = "[]" ]; then
        log_info "[RAG] No semantic matches found, falling back to keyword search"
        search_documents "$query" "$max_results"
        return $?
    fi

    echo "$result"
}

# Hybrid search: combine semantic and keyword results
search_hybrid() {
    local query="$1"
    local max_results="${2:-10}"

    log_info "[RAG] Performing hybrid search for: $query"

    local semantic_results="[]"
    local keyword_results="[]"

    # Get semantic results (if available)
    if is_vector_search_available; then
        semantic_results=$(search_semantic "$query" "$max_results" "all" "0.5" 2>/dev/null || echo "[]")
    fi

    # Get keyword results
    keyword_results=$(search_documents "$query" "$max_results" 2>/dev/null || echo "[]")

    # Combine and deduplicate results
    # Semantic results get higher weight (1.5x)
    local combined=$(echo "$semantic_results" | jq -c '.[] | . + {source: "semantic", weight: 1.5}' 2>/dev/null || true)
    combined="$combined"$'\n'$(echo "$keyword_results" | jq -c '.[] | . + {source: "keyword", weight: 1.0}' 2>/dev/null || true)

    # Merge, deduplicate, and sort by weighted score
    echo "$combined" | jq -s '
        # Combine all results
        . |

        # Calculate weighted score
        map(
            if .similarity then
                . + {final_score: (.similarity * .weight)}
            elif .score then
                . + {final_score: ((.score / 100) * .weight)}
            else
                . + {final_score: .weight}
            end
        ) |

        # Sort by final score descending
        sort_by(-.final_score) |

        # Limit results
        .[:'"$max_results"']
    ' 2>/dev/null || echo "$keyword_results"
}

# Search with automatic fallback
search_smart() {
    local query="$1"
    local max_results="${2:-5}"

    # Try semantic search first
    if is_vector_search_available; then
        local semantic=$(search_semantic "$query" "$max_results" "all" "0.65")
        local count=$(echo "$semantic" | jq 'length' 2>/dev/null || echo "0")

        if [ "$count" -gt 0 ]; then
            log_info "[RAG] Using semantic search results ($count matches)"
            echo "$semantic"
            return 0
        fi
    fi

    # Fall back to keyword search
    log_info "[RAG] Using keyword search fallback"
    search_documents "$query" "$max_results"
}

# Compute query embedding (wrapper for Node.js vector store)
compute_query_embedding() {
    local query="$1"

    if ! is_vector_search_available; then
        echo '{"error": "Vector search not available"}'
        return 1
    fi

    # Generate embedding using vector store
    node -e "
        const VectorStore = require('$VECTOR_STORE_JS');
        const vectorStore = new VectorStore();

        (async () => {
            await vectorStore.initialize();
            const embedding = await vectorStore._generateEmbedding(\`$query\`);
            console.log(JSON.stringify({
                query: \`$query\`,
                dimension: embedding.length,
                embedding: embedding.slice(0, 10).concat(['...truncated...']),
                generated_at: new Date().toISOString()
            }));
        })();
    " 2>/dev/null
}

# Get similarity between two queries
compute_query_similarity() {
    local query1="$1"
    local query2="$2"

    if ! is_vector_search_available; then
        # Fall back to Jaccard similarity
        calculate_similarity "$query1" "$query2"
        return
    fi

    # Use cosine similarity from vector store
    node -e "
        const VectorStore = require('$VECTOR_STORE_JS');
        const vectorStore = new VectorStore();

        (async () => {
            await vectorStore.initialize();
            const emb1 = await vectorStore._generateEmbedding(\`$query1\`);
            const emb2 = await vectorStore._generateEmbedding(\`$query2\`);
            const similarity = vectorStore._cosineSimilarity(emb1, emb2);
            console.log(similarity.toFixed(4));
        })();
    " 2>/dev/null
}

# Find similar documents
find_similar_documents() {
    local doc_id="$1"
    local max_results="${2:-5}"

    local source_keywords="$INDEX_DIR/${doc_id}-keywords.json"

    if [ ! -f "$source_keywords" ]; then
        echo '[]'
        return 1
    fi

    local source_words=$(jq -r '.keywords[].word' "$source_keywords" | tr '\n' ' ')
    local results="[]"

    # Compare with all other documents
    for keyword_file in "$INDEX_DIR"/*-keywords.json; do
        [ -f "$keyword_file" ] || continue

        local other_id=$(basename "$keyword_file" -keywords.json)

        # Skip self
        if [ "$other_id" = "$doc_id" ]; then
            continue
        fi

        local other_words=$(jq -r '.keywords[].word' "$keyword_file" | tr '\n' ' ')
        local similarity=$(calculate_similarity "$source_words" "$other_words")

        if [ "$(echo "$similarity > 0.1" | bc -l)" -eq 1 ]; then
            local metadata=$(cat "$METADATA_DIR/${other_id}.json" 2>/dev/null || echo '{}')
            local result=$(echo "$metadata" | jq --arg sim "$similarity" '. + {similarity: ($sim | tonumber)}')
            results=$(echo "$results" | jq --argjson r "$result" '. + [$r]')
        fi
    done

    echo "$results" | jq --argjson max "$max_results" 'sort_by(-.similarity) | .[:$max]'
}

#------------------------------------------------------------------------------
# Export Functions
#------------------------------------------------------------------------------

export -f normalize_query
export -f extract_query_keywords
export -f search_documents
export -f search_by_metadata
export -f retrieve_relevant_chunks
export -f get_chunks_by_doc
export -f get_chunk
export -f build_context
export -f calculate_similarity
export -f find_similar_documents

# Enhancement #19: Semantic search exports
export -f is_vector_search_available
export -f search_semantic
export -f search_hybrid
export -f search_smart
export -f compute_query_embedding
export -f compute_query_similarity

#------------------------------------------------------------------------------
# CLI Interface
#------------------------------------------------------------------------------

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    case "${1:-help}" in
        search)
            search_documents "$2" "${3:-10}"
            ;;
        filter)
            search_by_metadata "$2" "${3:-10}"
            ;;
        chunks)
            if [ -n "${3:-}" ]; then
                get_chunks_by_doc "$2" "${3:-0}" "${4:-10}"
            else
                retrieve_relevant_chunks "$2" "${3:-5}"
            fi
            ;;
        context)
            build_context "$2" "${3:-2000}"
            ;;
        similar)
            find_similar_documents "$2" "${3:-5}"
            ;;
        # Enhancement #19: Semantic search commands
        semantic)
            search_semantic "$2" "${3:-5}" "${4:-all}" "${5:-0.6}"
            ;;
        hybrid)
            search_hybrid "$2" "${3:-10}"
            ;;
        smart)
            search_smart "$2" "${3:-5}"
            ;;
        embedding)
            compute_query_embedding "$2"
            ;;
        similarity)
            compute_query_similarity "$2" "$3"
            ;;
        check-vector)
            if is_vector_search_available; then
                echo "Vector search is available"
                echo "Vector store: $VECTOR_STORE_JS"
                exit 0
            else
                echo "Vector search is NOT available"
                echo "Missing: $VECTOR_STORE_JS or vector DB index"
                exit 1
            fi
            ;;
        help|*)
            echo "RAG Retriever"
            echo ""
            echo "Usage: retriever.sh <command> [args]"
            echo ""
            echo "Commands:"
            echo "  search <query> [max]              Search documents by keywords"
            echo "  filter <json> [max]               Filter by metadata"
            echo "  chunks <query> [max]              Retrieve relevant chunks"
            echo "  context <query> [tokens]          Build context from chunks"
            echo "  similar <doc_id> [max]            Find similar documents"
            echo ""
            echo "Semantic Search (Enhancement #19):"
            echo "  semantic <query> [max] [coll] [min]  Vector similarity search"
            echo "  hybrid <query> [max]                 Combine semantic + keyword"
            echo "  smart <query> [max]                  Auto-fallback search"
            echo "  embedding <query>                    Compute query embedding"
            echo "  similarity <query1> <query2>         Compute similarity score"
            echo "  check-vector                         Check vector search availability"
            ;;
    esac
fi
