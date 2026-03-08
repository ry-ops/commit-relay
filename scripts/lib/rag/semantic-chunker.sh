#!/bin/bash
# scripts/lib/rag/semantic-chunker.sh
# Semantic Chunker - Phase 3 Item 36
# Replaces fixed-size chunking with semantic boundary detection
#
# Features:
#   - Paragraph boundary detection
#   - Section/heading detection
#   - Code block handling
#   - Overlap management for context
#   - Metadata extraction per chunk
#
# Usage:
#   source "$COMMIT_RELAY_HOME/scripts/lib/rag/semantic-chunker.sh"
#   chunks=$(chunk_document "$file_path")
#   chunks=$(chunk_text "$text" "markdown")

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"

# Chunker configuration
CHUNKER_CONFIG="${COMMIT_RELAY_HOME}/coordination/config/semantic-chunker.json"
CHUNKING_HISTORY="${COMMIT_RELAY_HOME}/coordination/metrics/chunking-history.jsonl"

# Create directories
mkdir -p "$(dirname "$CHUNKER_CONFIG")"
mkdir -p "$(dirname "$CHUNKING_HISTORY")"

# ============================================================================
# Logging
# ============================================================================

log_chunker() {
    local level="$1"
    shift
    echo "[$(date +%Y-%m-%dT%H:%M:%S%z)] [CHUNKER] [$level] $*" >&2
}

# ============================================================================
# Initialize Configuration
# ============================================================================

initialize_chunker_config() {
    if [ ! -f "$CHUNKER_CONFIG" ]; then
        cat > "$CHUNKER_CONFIG" <<'EOF'
{
  "version": "1.0.0",
  "chunk_sizes": {
    "min_chars": 200,
    "target_chars": 1000,
    "max_chars": 2000,
    "overlap_chars": 100
  },
  "boundary_detection": {
    "paragraph_break": true,
    "section_headers": true,
    "code_blocks": true,
    "list_items": false
  },
  "content_types": {
    "markdown": {
      "header_patterns": ["^#{1,6}\\s+", "^[=-]{3,}$"],
      "code_block_pattern": "^```",
      "list_pattern": "^[*-]\\s+|^\\d+\\.\\s+"
    },
    "code": {
      "function_patterns": ["^(function|def|func|fn|sub|method)\\s+", "^(public|private|protected)\\s+"],
      "class_pattern": "^(class|interface|struct|type)\\s+",
      "comment_pattern": "^(//|#|/\\*|'''|\"\"\"|<!--)"
    },
    "text": {
      "paragraph_pattern": "^\\s*$",
      "sentence_endings": ["\\.", "\\!", "\\?"]
    }
  },
  "metadata_extraction": {
    "enabled": true,
    "extract_headers": true,
    "extract_keywords": true,
    "max_keywords": 10
  }
}
EOF
        log_chunker "INFO" "Created default chunker config"
    fi
}

initialize_chunker_config

# ============================================================================
# Boundary Detection
# ============================================================================

# Detect if line is a section header (markdown)
is_markdown_header() {
    local line="$1"

    # Check for # headers
    if echo "$line" | grep -qE '^#{1,6}\s+'; then
        return 0
    fi

    # Check for underline headers (next line would be === or ---)
    return 1
}

# Detect if line starts a code block
is_code_block_boundary() {
    local line="$1"

    if echo "$line" | grep -qE '^```'; then
        return 0
    fi
    return 1
}

# Detect paragraph break
is_paragraph_break() {
    local line="$1"

    if [ -z "$(echo "$line" | tr -d '[:space:]')" ]; then
        return 0
    fi
    return 1
}

# Get header level (1-6 for markdown)
get_header_level() {
    local line="$1"

    local hashes=$(echo "$line" | grep -oE '^#+' | wc -c)
    echo $((hashes - 1))
}

# Extract header text
extract_header_text() {
    local line="$1"

    echo "$line" | sed 's/^#*\s*//'
}

# ============================================================================
# Keyword Extraction
# ============================================================================

# Extract keywords from text chunk
extract_keywords() {
    local text="$1"
    local max_keywords=$(jq -r '.metadata_extraction.max_keywords' "$CHUNKER_CONFIG")

    local text_lower=$(echo "$text" | tr '[:upper:]' '[:lower:]')

    # Remove common stop words and extract significant terms
    local stop_words="the a an is are was were be been being have has had do does did will would could should may might must shall to of in for on with at by from as"

    local keywords=""
    local word_counts="/tmp/word-counts-$$.txt"

    # Count word frequencies (excluding stop words)
    echo "$text_lower" | tr -cs '[:alpha:]' '\n' | grep -v '^$' | \
        grep -vwF "$stop_words" | \
        sort | uniq -c | sort -rn | head -"$max_keywords" | \
        awk '{print $2}' > "$word_counts"

    # Build keyword array
    keywords=$(cat "$word_counts" | jq -R -s 'split("\n") | map(select(length > 0))')

    rm -f "$word_counts"

    echo "$keywords"
}

# ============================================================================
# Core Chunking Functions
# ============================================================================

# Chunk markdown content
chunk_markdown() {
    local content="$1"
    local source="${2:-unknown}"

    local min_chars=$(jq -r '.chunk_sizes.min_chars' "$CHUNKER_CONFIG")
    local target_chars=$(jq -r '.chunk_sizes.target_chars' "$CHUNKER_CONFIG")
    local max_chars=$(jq -r '.chunk_sizes.max_chars' "$CHUNKER_CONFIG")
    local overlap_chars=$(jq -r '.chunk_sizes.overlap_chars' "$CHUNKER_CONFIG")

    local chunks="[]"
    local current_chunk=""
    local current_header=""
    local chunk_index=0
    local in_code_block="false"
    local line_number=0

    while IFS= read -r line || [ -n "$line" ]; do
        ((line_number++))

        # Track code blocks
        if is_code_block_boundary "$line"; then
            if [ "$in_code_block" = "false" ]; then
                in_code_block="true"
            else
                in_code_block="false"
            fi
        fi

        # Check for semantic boundaries (not inside code blocks)
        local is_boundary="false"

        if [ "$in_code_block" = "false" ]; then
            # Check for header
            if is_markdown_header "$line"; then
                is_boundary="true"
                current_header=$(extract_header_text "$line")
            # Check for paragraph break with sufficient content
            elif is_paragraph_break "$line" && [ ${#current_chunk} -ge "$min_chars" ]; then
                is_boundary="true"
            fi
        fi

        # If boundary reached and chunk is large enough, save it
        if [ "$is_boundary" = "true" ] && [ ${#current_chunk} -ge "$min_chars" ]; then
            # Create chunk
            local keywords='[]'
            local extract_kw=$(jq -r '.metadata_extraction.extract_keywords' "$CHUNKER_CONFIG")
            if [ "$extract_kw" = "true" ]; then
                keywords=$(extract_keywords "$current_chunk")
            fi

            local chunk_json=$(jq -nc \
                --argjson index "$chunk_index" \
                --arg content "$current_chunk" \
                --arg header "$current_header" \
                --arg source "$source" \
                --argjson char_count "${#current_chunk}" \
                --argjson line_start "$((line_number - $(echo "$current_chunk" | wc -l | tr -d ' ')))" \
                --argjson keywords "$keywords" \
                '{
                    chunk_index: $index,
                    content: $content,
                    metadata: {
                        header: $header,
                        source: $source,
                        char_count: $char_count,
                        line_start: $line_start,
                        keywords: $keywords
                    }
                }')

            chunks=$(echo "$chunks" | jq --argjson chunk "$chunk_json" '. + [$chunk]')

            # Start new chunk with overlap
            if [ "$overlap_chars" -gt 0 ] && [ ${#current_chunk} -gt "$overlap_chars" ]; then
                current_chunk="${current_chunk: -$overlap_chars}"
            else
                current_chunk=""
            fi

            ((chunk_index++))
        fi

        # Add line to current chunk
        if [ -n "$current_chunk" ]; then
            current_chunk="$current_chunk"$'\n'"$line"
        else
            current_chunk="$line"
        fi

        # Force break if max size exceeded
        if [ ${#current_chunk} -ge "$max_chars" ]; then
            local keywords='[]'
            local extract_kw=$(jq -r '.metadata_extraction.extract_keywords' "$CHUNKER_CONFIG")
            if [ "$extract_kw" = "true" ]; then
                keywords=$(extract_keywords "$current_chunk")
            fi

            local chunk_json=$(jq -nc \
                --argjson index "$chunk_index" \
                --arg content "$current_chunk" \
                --arg header "$current_header" \
                --arg source "$source" \
                --argjson char_count "${#current_chunk}" \
                --argjson keywords "$keywords" \
                '{
                    chunk_index: $index,
                    content: $content,
                    metadata: {
                        header: $header,
                        source: $source,
                        char_count: $char_count,
                        keywords: $keywords
                    }
                }')

            chunks=$(echo "$chunks" | jq --argjson chunk "$chunk_json" '. + [$chunk]')

            # Keep overlap
            if [ "$overlap_chars" -gt 0 ]; then
                current_chunk="${current_chunk: -$overlap_chars}"
            else
                current_chunk=""
            fi

            ((chunk_index++))
        fi
    done <<< "$content"

    # Save final chunk if not empty
    if [ ${#current_chunk} -ge "$min_chars" ]; then
        local keywords='[]'
        local extract_kw=$(jq -r '.metadata_extraction.extract_keywords' "$CHUNKER_CONFIG")
        if [ "$extract_kw" = "true" ]; then
            keywords=$(extract_keywords "$current_chunk")
        fi

        local chunk_json=$(jq -nc \
            --argjson index "$chunk_index" \
            --arg content "$current_chunk" \
            --arg header "$current_header" \
            --arg source "$source" \
            --argjson char_count "${#current_chunk}" \
            --argjson keywords "$keywords" \
            '{
                chunk_index: $index,
                content: $content,
                metadata: {
                    header: $header,
                    source: $source,
                    char_count: $char_count,
                    keywords: $keywords
                }
            }')

        chunks=$(echo "$chunks" | jq --argjson chunk "$chunk_json" '. + [$chunk]')
    fi

    echo "$chunks"
}

# Chunk code content
chunk_code() {
    local content="$1"
    local source="${2:-unknown}"
    local language="${3:-unknown}"

    local min_chars=$(jq -r '.chunk_sizes.min_chars' "$CHUNKER_CONFIG")
    local max_chars=$(jq -r '.chunk_sizes.max_chars' "$CHUNKER_CONFIG")

    local chunks="[]"
    local current_chunk=""
    local current_context=""
    local chunk_index=0

    # Get code patterns
    local function_patterns=$(jq -r '.content_types.code.function_patterns[]' "$CHUNKER_CONFIG")
    local class_pattern=$(jq -r '.content_types.code.class_pattern' "$CHUNKER_CONFIG")

    while IFS= read -r line || [ -n "$line" ]; do
        local is_boundary="false"

        # Check for function/method definition
        while IFS= read -r pattern; do
            if echo "$line" | grep -qE "$pattern"; then
                is_boundary="true"
                current_context=$(echo "$line" | sed 's/{.*//')
                break
            fi
        done <<< "$function_patterns"

        # Check for class definition
        if [ "$is_boundary" = "false" ] && echo "$line" | grep -qE "$class_pattern"; then
            is_boundary="true"
            current_context=$(echo "$line" | sed 's/{.*//')
        fi

        # Save chunk if boundary and sufficient size
        if [ "$is_boundary" = "true" ] && [ ${#current_chunk} -ge "$min_chars" ]; then
            local chunk_json=$(jq -nc \
                --argjson index "$chunk_index" \
                --arg content "$current_chunk" \
                --arg context "$current_context" \
                --arg source "$source" \
                --arg language "$language" \
                --argjson char_count "${#current_chunk}" \
                '{
                    chunk_index: $index,
                    content: $content,
                    metadata: {
                        context: $context,
                        source: $source,
                        language: $language,
                        char_count: $char_count
                    }
                }')

            chunks=$(echo "$chunks" | jq --argjson chunk "$chunk_json" '. + [$chunk]')
            current_chunk=""
            ((chunk_index++))
        fi

        # Add line
        if [ -n "$current_chunk" ]; then
            current_chunk="$current_chunk"$'\n'"$line"
        else
            current_chunk="$line"
        fi

        # Force break at max size
        if [ ${#current_chunk} -ge "$max_chars" ]; then
            local chunk_json=$(jq -nc \
                --argjson index "$chunk_index" \
                --arg content "$current_chunk" \
                --arg context "$current_context" \
                --arg source "$source" \
                --arg language "$language" \
                --argjson char_count "${#current_chunk}" \
                '{
                    chunk_index: $index,
                    content: $content,
                    metadata: {
                        context: $context,
                        source: $source,
                        language: $language,
                        char_count: $char_count
                    }
                }')

            chunks=$(echo "$chunks" | jq --argjson chunk "$chunk_json" '. + [$chunk]')
            current_chunk=""
            ((chunk_index++))
        fi
    done <<< "$content"

    # Final chunk
    if [ ${#current_chunk} -ge "$min_chars" ]; then
        local chunk_json=$(jq -nc \
            --argjson index "$chunk_index" \
            --arg content "$current_chunk" \
            --arg context "$current_context" \
            --arg source "$source" \
            --arg language "$language" \
            --argjson char_count "${#current_chunk}" \
            '{
                chunk_index: $index,
                content: $content,
                metadata: {
                    context: $context,
                    source: $source,
                    language: $language,
                    char_count: $char_count
                }
            }')

        chunks=$(echo "$chunks" | jq --argjson chunk "$chunk_json" '. + [$chunk]')
    fi

    echo "$chunks"
}

# ============================================================================
# Main API Functions
# ============================================================================

# Chunk text content
chunk_text() {
    local content="$1"
    local content_type="${2:-text}"
    local source="${3:-inline}"

    log_chunker "INFO" "Chunking content (type: $content_type, source: $source)"

    local chunks

    case "$content_type" in
        markdown|md)
            chunks=$(chunk_markdown "$content" "$source")
            ;;
        code|javascript|python|bash|sh)
            chunks=$(chunk_code "$content" "$source" "$content_type")
            ;;
        *)
            # Default to markdown-style chunking
            chunks=$(chunk_markdown "$content" "$source")
            ;;
    esac

    local chunk_count=$(echo "$chunks" | jq 'length')
    log_chunker "INFO" "Created $chunk_count chunks"

    # Record to history
    local history_entry=$(jq -nc \
        --arg source "$source" \
        --arg type "$content_type" \
        --argjson count "$chunk_count" \
        --argjson total_chars "${#content}" \
        --arg chunked_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            source: $source,
            content_type: $type,
            chunk_count: $count,
            total_chars: $total_chars,
            chunked_at: $chunked_at
        }')

    echo "$history_entry" >> "$CHUNKING_HISTORY"

    echo "$chunks"
}

# Chunk a document file
chunk_document() {
    local file_path="$1"
    local content_type="${2:-}"

    if [ ! -f "$file_path" ]; then
        log_chunker "ERROR" "File not found: $file_path"
        return 1
    fi

    # Auto-detect content type from extension if not provided
    if [ -z "$content_type" ]; then
        local ext="${file_path##*.}"
        case "$ext" in
            md) content_type="markdown" ;;
            js|ts) content_type="javascript" ;;
            py) content_type="python" ;;
            sh|bash) content_type="bash" ;;
            *) content_type="text" ;;
        esac
    fi

    local content
    content=$(cat "$file_path")

    chunk_text "$content" "$content_type" "$file_path"
}

# Get chunking metrics
get_chunking_metrics() {
    if [ ! -f "$CHUNKING_HISTORY" ]; then
        echo '{"total_documents":0,"total_chunks":0}'
        return
    fi

    local total_docs=$(wc -l < "$CHUNKING_HISTORY" | tr -d ' ')
    local total_chunks=$(jq -s '[.[].chunk_count] | add // 0' "$CHUNKING_HISTORY")

    jq -nc \
        --argjson docs "$total_docs" \
        --argjson chunks "$total_chunks" \
        '{
            total_documents: $docs,
            total_chunks: $chunks,
            avg_chunks_per_doc: (if $docs > 0 then ($chunks / $docs | floor) else 0 end)
        }'
}

# Export functions
export -f chunk_text 2>/dev/null || true
export -f chunk_document 2>/dev/null || true
export -f chunk_markdown 2>/dev/null || true
export -f chunk_code 2>/dev/null || true
export -f get_chunking_metrics 2>/dev/null || true

log_chunker "INFO" "Semantic chunker library loaded"
