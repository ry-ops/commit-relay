#!/usr/bin/env bash
#
# RAG Document Processor
# Part of Q2: RAG Pipeline for Library
#
# Processes documents from the library directory for RAG retrieval:
# - PDF text extraction
# - Metadata extraction
# - Chunking for retrieval
# - Index generation
#
# Usage:
#   source scripts/lib/rag/document-processor.sh
#   process_document "library/unread/document.pdf"
#   process_library_directory
#   get_document_metadata "doc-id"

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"

# Directories
readonly LIBRARY_DIR="$COMMIT_RELAY_HOME/library"
readonly UNREAD_DIR="$LIBRARY_DIR/unread"
readonly PROCESSED_DIR="$LIBRARY_DIR/processed"
readonly EMBEDDINGS_DIR="$COMMIT_RELAY_HOME/coordination/knowledge-base/embeddings"
readonly CHUNKS_DIR="$EMBEDDINGS_DIR/chunks"
readonly METADATA_DIR="$EMBEDDINGS_DIR/metadata"
readonly INDEX_DIR="$EMBEDDINGS_DIR/indices"

# Processing configuration
readonly DEFAULT_CHUNK_SIZE=1000
readonly DEFAULT_CHUNK_OVERLAP=200
readonly SUPPORTED_EXTENSIONS=("pdf" "txt" "md" "json" "yaml" "yml")

# Ensure directories exist
mkdir -p "$UNREAD_DIR" "$PROCESSED_DIR" "$CHUNKS_DIR" "$METADATA_DIR" "$INDEX_DIR"

# Source logging
source "$COMMIT_RELAY_HOME/scripts/lib/logging.sh" 2>/dev/null || {
    log_info() { echo "[INFO] $1"; }
    log_warn() { echo "[WARN] $1"; }
    log_error() { echo "[ERROR] $1"; }
}

#------------------------------------------------------------------------------
# Document ID Generation
#------------------------------------------------------------------------------

generate_doc_id() {
    local file_path="$1"
    local file_name=$(basename "$file_path")
    local hash=$(echo "$file_path" | md5 -q 2>/dev/null || md5sum | cut -d' ' -f1)
    echo "doc-${hash:0:12}"
}

#------------------------------------------------------------------------------
# Text Extraction
#------------------------------------------------------------------------------

# Extract text from PDF
extract_pdf_text() {
    local file_path="$1"
    local output_file="$2"

    # Try pdftotext first (from poppler)
    if command -v pdftotext &> /dev/null; then
        pdftotext -layout "$file_path" "$output_file" 2>/dev/null
        return $?
    fi

    # Fallback: try pdf2txt.py (from pdfminer)
    if command -v pdf2txt.py &> /dev/null; then
        pdf2txt.py "$file_path" > "$output_file" 2>/dev/null
        return $?
    fi

    # Last resort: basic extraction message
    echo "PDF text extraction requires pdftotext or pdfminer" > "$output_file"
    log_warn "[RAG] PDF extraction tools not found, skipping: $file_path"
    return 1
}

# Extract text based on file type
extract_text() {
    local file_path="$1"
    local output_file="$2"

    local extension="${file_path##*.}"
    extension=$(echo "$extension" | tr '[:upper:]' '[:lower:]')

    case "$extension" in
        pdf)
            extract_pdf_text "$file_path" "$output_file"
            ;;
        txt|md)
            cp "$file_path" "$output_file"
            ;;
        json)
            # Extract string values from JSON
            jq -r '.. | strings' "$file_path" > "$output_file" 2>/dev/null || \
                cat "$file_path" > "$output_file"
            ;;
        yaml|yml)
            # Convert YAML to readable text
            cat "$file_path" > "$output_file"
            ;;
        *)
            log_warn "[RAG] Unsupported file type: $extension"
            return 1
            ;;
    esac
}

#------------------------------------------------------------------------------
# Metadata Extraction
#------------------------------------------------------------------------------

# Extract metadata from document
extract_metadata() {
    local file_path="$1"
    local doc_id="$2"

    local file_name=$(basename "$file_path")
    local extension="${file_path##*.}"
    local file_size=$(stat -f%z "$file_path" 2>/dev/null || stat --printf="%s" "$file_path" 2>/dev/null || echo "0")
    local mod_time=$(stat -f%m "$file_path" 2>/dev/null || stat --printf="%Y" "$file_path" 2>/dev/null || echo "0")

    # Try to extract PDF metadata
    local title=""
    local author=""
    local subject=""
    local keywords=""
    local page_count=0

    if [ "$extension" = "pdf" ] && command -v pdfinfo &> /dev/null; then
        local pdf_info=$(pdfinfo "$file_path" 2>/dev/null || echo "")

        title=$(echo "$pdf_info" | grep "^Title:" | cut -d: -f2- | xargs)
        author=$(echo "$pdf_info" | grep "^Author:" | cut -d: -f2- | xargs)
        subject=$(echo "$pdf_info" | grep "^Subject:" | cut -d: -f2- | xargs)
        keywords=$(echo "$pdf_info" | grep "^Keywords:" | cut -d: -f2- | xargs)
        page_count=$(echo "$pdf_info" | grep "^Pages:" | cut -d: -f2- | xargs)
    fi

    # Use filename as title if not found
    [ -z "$title" ] && title="${file_name%.*}"

    jq -n \
        --arg doc_id "$doc_id" \
        --arg file_name "$file_name" \
        --arg file_path "$file_path" \
        --arg extension "$extension" \
        --argjson file_size "$file_size" \
        --argjson mod_time "$mod_time" \
        --arg title "$title" \
        --arg author "$author" \
        --arg subject "$subject" \
        --arg keywords "$keywords" \
        --argjson page_count "${page_count:-0}" \
        --arg processed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            doc_id: $doc_id,
            file_name: $file_name,
            original_path: $file_path,
            extension: $extension,
            file_size: $file_size,
            modified_at: ($mod_time | todate),
            title: $title,
            author: $author,
            subject: $subject,
            keywords: $keywords,
            page_count: $page_count,
            processed_at: $processed_at,
            status: "processed"
        }'
}

#------------------------------------------------------------------------------
# Text Chunking
#------------------------------------------------------------------------------

# Chunk text into smaller pieces for retrieval
chunk_text() {
    local text_file="$1"
    local doc_id="$2"
    local chunk_size="${3:-$DEFAULT_CHUNK_SIZE}"
    local overlap="${4:-$DEFAULT_CHUNK_OVERLAP}"

    if [ ! -f "$text_file" ]; then
        log_error "[RAG] Text file not found: $text_file"
        return 1
    fi

    local text=$(cat "$text_file")
    local text_length=${#text}
    local chunk_index=0
    local position=0

    local chunks_file="$CHUNKS_DIR/${doc_id}-chunks.jsonl"
    > "$chunks_file"  # Clear file

    while [ $position -lt $text_length ]; do
        # Extract chunk
        local chunk="${text:$position:$chunk_size}"

        # Find a good break point (end of sentence or paragraph)
        local break_point=$chunk_size
        if [ $((position + chunk_size)) -lt $text_length ]; then
            # Look for sentence boundary
            local last_period=$(echo "$chunk" | grep -ob '\. ' | tail -1 | cut -d: -f1)
            local last_newline=$(echo "$chunk" | grep -ob $'\n' | tail -1 | cut -d: -f1)

            if [ -n "$last_period" ] && [ "$last_period" -gt $((chunk_size / 2)) ]; then
                break_point=$((last_period + 2))
            elif [ -n "$last_newline" ] && [ "$last_newline" -gt $((chunk_size / 2)) ]; then
                break_point=$((last_newline + 1))
            fi

            chunk="${text:$position:$break_point}"
        fi

        # Create chunk entry
        local chunk_json=$(jq -n \
            --arg doc_id "$doc_id" \
            --argjson chunk_index "$chunk_index" \
            --argjson start_pos "$position" \
            --argjson end_pos "$((position + ${#chunk}))" \
            --arg content "$chunk" \
            '{
                chunk_id: ($doc_id + "-chunk-" + ($chunk_index | tostring)),
                doc_id: $doc_id,
                chunk_index: $chunk_index,
                start_position: $start_pos,
                end_position: $end_pos,
                content: $content,
                content_length: ($content | length)
            }')

        echo "$chunk_json" >> "$chunks_file"

        # Move position with overlap
        position=$((position + break_point - overlap))
        chunk_index=$((chunk_index + 1))
    done

    log_info "[RAG] Created $chunk_index chunks for $doc_id"
    echo "$chunk_index"
}

#------------------------------------------------------------------------------
# Index Building
#------------------------------------------------------------------------------

# Build keyword index for a document
build_keyword_index() {
    local doc_id="$1"
    local text_file="$2"

    local index_file="$INDEX_DIR/${doc_id}-keywords.json"

    # Extract and count words
    local word_counts=$(cat "$text_file" | \
        tr '[:upper:]' '[:lower:]' | \
        tr -cs '[:alpha:]' '\n' | \
        grep -v '^$' | \
        sort | uniq -c | sort -rn | \
        head -100 | \
        awk '{print "{\"word\":\"" $2 "\",\"count\":" $1 "}"}' | \
        jq -s '.')

    jq -n \
        --arg doc_id "$doc_id" \
        --argjson keywords "$word_counts" \
        --arg indexed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            doc_id: $doc_id,
            keywords: $keywords,
            indexed_at: $indexed_at
        }' > "$index_file"
}

# Update master index
update_master_index() {
    local doc_id="$1"
    local metadata="$2"

    local master_index="$INDEX_DIR/master-index.jsonl"

    # Append to master index
    echo "$metadata" >> "$master_index"

    # Also update by-date index
    local date=$(echo "$metadata" | jq -r '.processed_at | split("T")[0]')
    echo "$doc_id" >> "$INDEX_DIR/by-date-${date}.index"

    # Update by-extension index
    local ext=$(echo "$metadata" | jq -r '.extension')
    echo "$doc_id" >> "$INDEX_DIR/by-ext-${ext}.index"
}

#------------------------------------------------------------------------------
# Main Processing Functions
#------------------------------------------------------------------------------

# Process a single document
process_document() {
    local file_path="$1"
    local chunk_size="${2:-$DEFAULT_CHUNK_SIZE}"

    if [ ! -f "$file_path" ]; then
        log_error "[RAG] File not found: $file_path"
        return 1
    fi

    local doc_id=$(generate_doc_id "$file_path")
    local file_name=$(basename "$file_path")

    log_info "[RAG] Processing document: $file_name (ID: $doc_id)"

    # Step 1: Extract text
    local text_file=$(mktemp)
    if ! extract_text "$file_path" "$text_file"; then
        log_error "[RAG] Failed to extract text from: $file_path"
        rm -f "$text_file"
        return 1
    fi

    # Check if text was extracted
    local text_size=$(stat -f%z "$text_file" 2>/dev/null || stat --printf="%s" "$text_file" 2>/dev/null || echo "0")
    if [ "$text_size" -eq 0 ]; then
        log_warn "[RAG] No text extracted from: $file_path"
        rm -f "$text_file"
        return 1
    fi

    # Step 2: Extract metadata
    local metadata=$(extract_metadata "$file_path" "$doc_id")
    echo "$metadata" > "$METADATA_DIR/${doc_id}.json"

    # Step 3: Chunk text
    local chunk_count=$(chunk_text "$text_file" "$doc_id" "$chunk_size")

    # Step 4: Build keyword index
    build_keyword_index "$doc_id" "$text_file"

    # Step 5: Update master index
    update_master_index "$doc_id" "$metadata"

    # Step 6: Move to processed
    local processed_path="$PROCESSED_DIR/$file_name"
    if [ "$file_path" != "$processed_path" ]; then
        mv "$file_path" "$processed_path" 2>/dev/null || true
    fi

    # Cleanup
    rm -f "$text_file"

    log_info "[RAG] Processed $file_name: $chunk_count chunks, ID: $doc_id"

    # Return metadata
    echo "$metadata"
}

# Process all documents in library
process_library_directory() {
    local directory="${1:-$UNREAD_DIR}"

    log_info "[RAG] Processing library directory: $directory"

    local processed=0
    local failed=0

    for file in "$directory"/*; do
        [ -f "$file" ] || continue

        local ext="${file##*.}"
        ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')

        # Check if extension is supported
        local supported=false
        for supported_ext in "${SUPPORTED_EXTENSIONS[@]}"; do
            if [ "$ext" = "$supported_ext" ]; then
                supported=true
                break
            fi
        done

        if [ "$supported" = "true" ]; then
            if process_document "$file"; then
                processed=$((processed + 1))
            else
                failed=$((failed + 1))
            fi
        fi
    done

    log_info "[RAG] Library processing complete: $processed processed, $failed failed"

    jq -n \
        --argjson processed "$processed" \
        --argjson failed "$failed" \
        '{
            processed: $processed,
            failed: $failed,
            total: ($processed + $failed)
        }'
}

#------------------------------------------------------------------------------
# Query Functions
#------------------------------------------------------------------------------

# Get document metadata
get_document_metadata() {
    local doc_id="$1"

    local metadata_file="$METADATA_DIR/${doc_id}.json"

    if [ -f "$metadata_file" ]; then
        cat "$metadata_file"
    else
        echo '{"error": "Document not found"}'
        return 1
    fi
}

# List all processed documents
list_documents() {
    local master_index="$INDEX_DIR/master-index.jsonl"

    if [ -f "$master_index" ]; then
        cat "$master_index" | jq -s '.'
    else
        echo '[]'
    fi
}

# Get document chunks
get_document_chunks() {
    local doc_id="$1"

    local chunks_file="$CHUNKS_DIR/${doc_id}-chunks.jsonl"

    if [ -f "$chunks_file" ]; then
        cat "$chunks_file" | jq -s '.'
    else
        echo '[]'
        return 1
    fi
}

# Get processing statistics
get_processing_stats() {
    local master_index="$INDEX_DIR/master-index.jsonl"

    if [ ! -f "$master_index" ]; then
        echo '{"total_documents": 0}'
        return 0
    fi

    cat "$master_index" | jq -s '{
        total_documents: length,
        by_extension: (group_by(.extension) | map({key: .[0].extension, value: length}) | from_entries),
        total_size: (map(.file_size) | add // 0),
        latest_processed: (max_by(.processed_at) | .processed_at)
    }'
}

#------------------------------------------------------------------------------
# Export Functions
#------------------------------------------------------------------------------

export -f generate_doc_id
export -f extract_text
export -f extract_metadata
export -f chunk_text
export -f build_keyword_index
export -f process_document
export -f process_library_directory
export -f get_document_metadata
export -f list_documents
export -f get_document_chunks
export -f get_processing_stats

#------------------------------------------------------------------------------
# CLI Interface
#------------------------------------------------------------------------------

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    case "${1:-help}" in
        process)
            if [ -n "${2:-}" ]; then
                process_document "$2" "${3:-}"
            else
                process_library_directory
            fi
            ;;
        metadata)
            get_document_metadata "$2"
            ;;
        list)
            list_documents
            ;;
        chunks)
            get_document_chunks "$2"
            ;;
        stats)
            get_processing_stats
            ;;
        help|*)
            echo "RAG Document Processor"
            echo ""
            echo "Usage: document-processor.sh <command> [args]"
            echo ""
            echo "Commands:"
            echo "  process [path] [size]  Process document or library directory"
            echo "  metadata <doc_id>      Get document metadata"
            echo "  list                   List all processed documents"
            echo "  chunks <doc_id>        Get document chunks"
            echo "  stats                  Get processing statistics"
            ;;
    esac
fi
