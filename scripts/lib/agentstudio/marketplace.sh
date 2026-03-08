#!/usr/bin/env bash
#
# Agent Marketplace Library
# Part of Q2 Week 27: Agent Marketplace & Sharing
#
# Manages agent discovery, ratings, reviews, and distribution
#

set -euo pipefail

if [[ -z "${MARKETPLACE_LOADED:-}" ]]; then
    readonly MARKETPLACE_LOADED=true
fi

# Directory setup
MARKETPLACE_DIR="${MARKETPLACE_DIR:-coordination/agentstudio/marketplace}"
EXPORT_DIR="${EXPORT_DIR:-coordination/agentstudio/exports}"

#
# Initialize marketplace
#
init_marketplace() {
    mkdir -p "$MARKETPLACE_DIR"/{listings,packages,reviews,indices}
    mkdir -p "$EXPORT_DIR"
}

#
# Get timestamp in milliseconds
#
get_timestamp_ms() {
    local ts=$(date +%s%3N 2>/dev/null)
    if [[ "$ts" =~ N$ ]]; then
        echo $(($(date +%s) * 1000))
    else
        echo "$ts"
    fi
}

#
# Generate listing ID
#
generate_listing_id() {
    local name="$1"
    local slug=$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')
    local hash=$(echo "${name}-$(date +%s)" | shasum -a 256 | cut -c1-8)
    echo "mkt-${slug}-${hash}"
}

#
# Publish agent to marketplace
#
publish_agent() {
    local agent_id="$1"
    local name="$2"
    local version="$3"
    local description="$4"
    local category="${5:-utility}"

    init_marketplace

    local listing_id=$(generate_listing_id "$name")
    local timestamp=$(get_timestamp_ms)

    # Create listing
    local listing_file="$MARKETPLACE_DIR/listings/${listing_id}.json"

    cat > "$listing_file" <<EOF
{
  "listing_id": "$listing_id",
  "agent_id": "$agent_id",
  "name": "$name",
  "version": "$version",
  "status": "published",
  "visibility": "public",
  "metadata": {
    "short_description": "$description",
    "long_description": "$description",
    "category": "$category",
    "tags": [],
    "license": "MIT"
  },
  "author": {
    "name": "$(whoami)",
    "verified": false
  },
  "pricing": {
    "model": "free"
  },
  "requirements": {
    "dependencies": [],
    "capabilities": []
  },
  "ratings": {
    "average": 0,
    "count": 0,
    "distribution": {"5": 0, "4": 0, "3": 0, "2": 0, "1": 0}
  },
  "reviews": [],
  "statistics": {
    "downloads": 0,
    "installs": 0,
    "active_users": 0,
    "weekly_downloads": 0,
    "monthly_downloads": 0,
    "trending_score": 0
  },
  "changelog": [
    {
      "version": "$version",
      "date": $timestamp,
      "changes": ["Initial release"]
    }
  ],
  "created_at": $timestamp,
  "updated_at": $timestamp,
  "published_at": $timestamp
}
EOF

    # Update indices
    update_marketplace_indices "$listing_id" "$category"

    echo "$listing_id"
}

#
# Update marketplace indices
#
update_marketplace_indices() {
    local listing_id="$1"
    local category="$2"

    # Update category index
    local category_index="$MARKETPLACE_DIR/indices/by-category.json"
    if [[ ! -f "$category_index" ]]; then
        echo "{}" > "$category_index"
    fi

    local current=$(cat "$category_index")
    local updated=$(echo "$current" | jq --arg cat "$category" --arg id "$listing_id" \
        '.[$cat] = ((.[$cat] // []) + [$id] | unique)')
    echo "$updated" > "$category_index"

    # Update all listings index
    local all_index="$MARKETPLACE_DIR/indices/all.json"
    if [[ ! -f "$all_index" ]]; then
        echo "[]" > "$all_index"
    fi

    local all_current=$(cat "$all_index")
    local all_updated=$(echo "$all_current" | jq --arg id "$listing_id" '. + [$id] | unique')
    echo "$all_updated" > "$all_index"
}

#
# Get listing by ID
#
get_listing() {
    local listing_id="$1"

    local listing_file="$MARKETPLACE_DIR/listings/${listing_id}.json"
    if [[ -f "$listing_file" ]]; then
        cat "$listing_file"
    else
        echo "{\"error\": \"Listing not found: $listing_id\"}"
        return 1
    fi
}

#
# Search marketplace
#
search_marketplace() {
    local query="$1"
    local category="${2:-}"
    local limit="${3:-20}"

    init_marketplace

    local results="[]"
    local count=0

    # Get all listings
    for listing_file in "$MARKETPLACE_DIR/listings"/*.json; do
        if [[ -f "$listing_file" && $count -lt $limit ]]; then
            local listing=$(cat "$listing_file")
            local status=$(echo "$listing" | jq -r '.status')

            # Only show published listings
            if [[ "$status" != "published" && "$status" != "featured" ]]; then
                continue
            fi

            # Filter by category if specified
            if [[ -n "$category" ]]; then
                local listing_cat=$(echo "$listing" | jq -r '.metadata.category')
                if [[ "$listing_cat" != "$category" ]]; then
                    continue
                fi
            fi

            # Search in name and description
            local name=$(echo "$listing" | jq -r '.name')
            local desc=$(echo "$listing" | jq -r '.metadata.short_description')

            if [[ -z "$query" || "$name" == *"$query"* || "$desc" == *"$query"* ]]; then
                results=$(echo "$results" | jq --argjson l "$listing" '. + [$l]')
                count=$((count + 1))
            fi
        fi
    done

    # Sort by downloads
    echo "$results" | jq 'sort_by(.statistics.downloads) | reverse'
}

#
# List by category
#
list_by_category() {
    local category="$1"
    local limit="${2:-20}"

    search_marketplace "" "$category" "$limit"
}

#
# Get featured listings
#
get_featured() {
    local limit="${1:-10}"

    init_marketplace

    local results="[]"
    local count=0

    for listing_file in "$MARKETPLACE_DIR/listings"/*.json; do
        if [[ -f "$listing_file" && $count -lt $limit ]]; then
            local listing=$(cat "$listing_file")
            local status=$(echo "$listing" | jq -r '.status')

            if [[ "$status" == "featured" ]]; then
                results=$(echo "$results" | jq --argjson l "$listing" '. + [$l]')
                count=$((count + 1))
            fi
        fi
    done

    echo "$results"
}

#
# Get trending listings
#
get_trending() {
    local limit="${1:-10}"

    init_marketplace

    local results="[]"

    for listing_file in "$MARKETPLACE_DIR/listings"/*.json; do
        if [[ -f "$listing_file" ]]; then
            local listing=$(cat "$listing_file")
            local status=$(echo "$listing" | jq -r '.status')

            if [[ "$status" == "published" || "$status" == "featured" ]]; then
                results=$(echo "$results" | jq --argjson l "$listing" '. + [$l]')
            fi
        fi
    done

    # Sort by trending score
    echo "$results" | jq "sort_by(.statistics.trending_score) | reverse | .[:$limit]"
}

#
# Add review
#
add_review() {
    local listing_id="$1"
    local rating="$2"
    local title="$3"
    local content="$4"
    local user="${5:-$(whoami)}"

    local listing_file="$MARKETPLACE_DIR/listings/${listing_id}.json"
    if [[ ! -f "$listing_file" ]]; then
        echo "Error: Listing not found" >&2
        return 1
    fi

    local timestamp=$(get_timestamp_ms)
    local review_id="rev-${timestamp}"

    # Add review to listing
    local listing=$(cat "$listing_file")
    local updated=$(echo "$listing" | jq \
        --arg rid "$review_id" \
        --arg user "$user" \
        --argjson rating "$rating" \
        --arg title "$title" \
        --arg content "$content" \
        --argjson ts "$timestamp" \
        '.reviews += [{
          "review_id": $rid,
          "user": $user,
          "rating": $rating,
          "title": $title,
          "content": $content,
          "helpful_count": 0,
          "verified_purchase": false,
          "created_at": $ts
        }]')

    # Update ratings
    local reviews=$(echo "$updated" | jq '.reviews')
    local count=$(echo "$reviews" | jq 'length')
    local sum=$(echo "$reviews" | jq '[.[].rating] | add')
    local average=$(echo "scale=2; $sum / $count" | bc)

    # Update distribution
    updated=$(echo "$updated" | jq \
        --argjson avg "$average" \
        --argjson cnt "$count" \
        --argjson r "$rating" \
        --argjson ts "$timestamp" \
        '.ratings.average = $avg |
         .ratings.count = $cnt |
         .ratings.distribution[($r | tostring)] += 1 |
         .updated_at = $ts')

    echo "$updated" > "$listing_file"
    echo "$review_id"
}

#
# Get reviews for listing
#
get_reviews() {
    local listing_id="$1"
    local limit="${2:-10}"

    local listing=$(get_listing "$listing_id")
    if [[ "$listing" =~ "error" ]]; then
        echo "[]"
        return 1
    fi

    echo "$listing" | jq ".reviews | sort_by(.created_at) | reverse | .[:$limit]"
}

#
# Export agent package
#
export_agent() {
    local agent_id="$1"
    local output_dir="${2:-$EXPORT_DIR}"

    init_marketplace

    local timestamp=$(date +%Y%m%d-%H%M%S)
    local export_name="${agent_id}-${timestamp}"
    local export_path="$output_dir/${export_name}"

    mkdir -p "$export_path"

    # Find agent files
    local agent_file=$(find coordination/agentstudio/registry -name "${agent_id}.json" 2>/dev/null | head -1)

    if [[ -z "$agent_file" ]]; then
        echo "Error: Agent not found: $agent_id" >&2
        return 1
    fi

    # Copy agent registration
    cp "$agent_file" "$export_path/agent.json"

    # Find and copy related files
    local agent_class=$(jq -r '.agent_class' "$agent_file")
    local agent_name=$(jq -r '.name' "$agent_file")

    # Look for script files
    local script_locations=(
        "coordination/masters/$agent_name"
        "coordination/workers/$agent_name"
        "scripts/daemons/${agent_name}-daemon.sh"
        "llm-mesh/agents/$agent_name"
    )

    for loc in "${script_locations[@]}"; do
        if [[ -e "$loc" ]]; then
            if [[ -d "$loc" ]]; then
                cp -r "$loc" "$export_path/files/"
            else
                mkdir -p "$export_path/files"
                cp "$loc" "$export_path/files/"
            fi
        fi
    done

    # Create manifest
    cat > "$export_path/manifest.json" <<EOF
{
  "export_id": "$export_name",
  "agent_id": "$agent_id",
  "agent_class": "$agent_class",
  "exported_at": $(get_timestamp_ms),
  "exported_by": "$(whoami)",
  "version": "1.0.0",
  "files": $(find "$export_path" -type f -name "*.json" -o -name "*.sh" | jq -R -s 'split("\n") | map(select(length > 0))')
}
EOF

    # Create archive
    local archive_path="$output_dir/${export_name}.tar.gz"
    tar -czf "$archive_path" -C "$output_dir" "$export_name"

    # Calculate checksum
    local checksum=$(shasum -a 256 "$archive_path" | cut -d' ' -f1)

    # Clean up directory
    rm -rf "$export_path"

    echo "{\"path\": \"$archive_path\", \"checksum\": \"$checksum\", \"size\": $(stat -f%z "$archive_path" 2>/dev/null || stat -c%s "$archive_path" 2>/dev/null)}"
}

#
# Import agent package
#
import_agent() {
    local package_path="$1"
    local target_dir="${2:-coordination/agentstudio/imports}"

    init_marketplace

    if [[ ! -f "$package_path" ]]; then
        echo "Error: Package not found: $package_path" >&2
        return 1
    fi

    mkdir -p "$target_dir"

    # Extract package
    local extract_dir="$target_dir/$(basename "$package_path" .tar.gz)"
    mkdir -p "$extract_dir"
    tar -xzf "$package_path" -C "$target_dir"

    # Read manifest
    local manifest_file=$(find "$extract_dir" -name "manifest.json" | head -1)
    if [[ -z "$manifest_file" ]]; then
        echo "Error: Invalid package - no manifest found" >&2
        return 1
    fi

    local manifest=$(cat "$manifest_file")
    local agent_id=$(echo "$manifest" | jq -r '.agent_id')

    echo "{\"agent_id\": \"$agent_id\", \"imported_to\": \"$extract_dir\", \"manifest\": $manifest}"
}

#
# Update download count
#
record_download() {
    local listing_id="$1"

    local listing_file="$MARKETPLACE_DIR/listings/${listing_id}.json"
    if [[ ! -f "$listing_file" ]]; then
        return 1
    fi

    local timestamp=$(get_timestamp_ms)
    local updated=$(cat "$listing_file" | jq \
        --argjson ts "$timestamp" \
        '.statistics.downloads += 1 |
         .statistics.weekly_downloads += 1 |
         .statistics.monthly_downloads += 1 |
         .updated_at = $ts')

    echo "$updated" > "$listing_file"
}

#
# Install from marketplace
#
install_from_marketplace() {
    local listing_id="$1"

    local listing=$(get_listing "$listing_id")
    if [[ "$listing" =~ "error" ]]; then
        return 1
    fi

    local agent_id=$(echo "$listing" | jq -r '.agent_id')

    # Record install
    local listing_file="$MARKETPLACE_DIR/listings/${listing_id}.json"
    local timestamp=$(get_timestamp_ms)
    local updated=$(cat "$listing_file" | jq \
        --argjson ts "$timestamp" \
        '.statistics.installs += 1 |
         .statistics.active_users += 1 |
         .updated_at = $ts')

    echo "$updated" > "$listing_file"

    echo "{\"listing_id\": \"$listing_id\", \"agent_id\": \"$agent_id\", \"status\": \"installed\"}"
}

#
# Get marketplace statistics
#
get_marketplace_stats() {
    init_marketplace

    local total_listings=0
    local total_downloads=0
    local total_installs=0
    local categories=()

    for listing_file in "$MARKETPLACE_DIR/listings"/*.json; do
        if [[ -f "$listing_file" ]]; then
            local listing=$(cat "$listing_file")
            total_listings=$((total_listings + 1))
            total_downloads=$((total_downloads + $(echo "$listing" | jq -r '.statistics.downloads')))
            total_installs=$((total_installs + $(echo "$listing" | jq -r '.statistics.installs')))
        fi
    done

    cat <<EOF
{
  "total_listings": $total_listings,
  "total_downloads": $total_downloads,
  "total_installs": $total_installs,
  "categories": ["orchestration", "development", "security", "testing", "monitoring", "learning", "utility", "integration"]
}
EOF
}

# Export functions
export -f init_marketplace
export -f generate_listing_id
export -f publish_agent
export -f get_listing
export -f search_marketplace
export -f list_by_category
export -f get_featured
export -f get_trending
export -f add_review
export -f get_reviews
export -f export_agent
export -f import_agent
export -f record_download
export -f install_from_marketplace
export -f get_marketplace_stats
