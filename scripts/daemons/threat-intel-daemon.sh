#!/usr/bin/env bash
#
# Threat Intelligence Daemon
# Part of Phase 2 Security Enhancements
#
# Fetches threat intelligence from NVD (National Vulnerability Database)
# and other feeds, stores in coordination/security/threat-intel/
#
# Usage:
#   ./scripts/daemons/threat-intel-daemon.sh start
#   ./scripts/daemons/threat-intel-daemon.sh stop
#   ./scripts/daemons/threat-intel-daemon.sh status
#   ./scripts/daemons/threat-intel-daemon.sh query <keyword>
#

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Configuration
readonly DAEMON_NAME="threat-intel"
readonly PID_FILE="${PID_FILE:-/tmp/commit-relay-threat-intel.pid}"
readonly LOG_FILE="${LOG_FILE:-coordination/security/threat-intel/daemon.log}"

# Directories
readonly THREAT_INTEL_DIR="${THREAT_INTEL_DIR:-coordination/security/threat-intel}"
readonly CVE_CACHE_DIR="${CVE_CACHE_DIR:-$THREAT_INTEL_DIR/cve-cache}"
readonly ADVISORY_DIR="${ADVISORY_DIR:-$THREAT_INTEL_DIR/advisories}"

# NVD API Configuration
readonly NVD_API_BASE="https://services.nvd.nist.gov/rest/json/cves/2.0"
readonly NVD_API_KEY="${NVD_API_KEY:-}"  # Optional API key for higher rate limits

# Update intervals
readonly FULL_SYNC_INTERVAL="${FULL_SYNC_INTERVAL:-86400}"     # 24 hours
readonly RECENT_CHECK_INTERVAL="${RECENT_CHECK_INTERVAL:-3600}" # 1 hour
readonly CRITICAL_CHECK_INTERVAL="${CRITICAL_CHECK_INTERVAL:-900}" # 15 minutes for critical vulns

# Keywords to monitor (relevant to commit-relay stack)
readonly MONITORED_KEYWORDS=(
    "bash"
    "jq"
    "curl"
    "nodejs"
    "npm"
    "git"
    "docker"
    "kubernetes"
)

#
# Log message
#
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

#
# Check if daemon is already running
#
check_running() {
    if [[ -f "$PID_FILE" ]]; then
        local pid=$(cat "$PID_FILE")
        if ps -p "$pid" > /dev/null 2>&1; then
            return 0
        else
            rm -f "$PID_FILE"
        fi
    fi
    return 1
}

#
# Initialize daemon
#
initialize() {
    log "INFO" "Initializing threat intelligence daemon..."

    # Create directories
    mkdir -p "$THREAT_INTEL_DIR" "$CVE_CACHE_DIR" "$ADVISORY_DIR"
    mkdir -p "$(dirname "$LOG_FILE")"

    # Check if already running
    if check_running; then
        log "ERROR" "Daemon already running (PID: $(cat "$PID_FILE"))"
        exit 1
    fi

    # Write PID file
    echo $$ > "$PID_FILE"

    # Initialize state file
    local state_file="$THREAT_INTEL_DIR/state.json"
    if [[ ! -f "$state_file" ]]; then
        jq -n \
            --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '{
                last_full_sync: null,
                last_recent_check: null,
                total_cves_cached: 0,
                critical_cves: 0,
                high_cves: 0,
                last_updated: $ts
            }' > "$state_file"
    fi

    log "INFO" "Initialization complete"
}

#
# Fetch CVEs from NVD API
#
fetch_nvd_cves() {
    local keyword="$1"
    local days_back="${2:-7}"

    local pub_start_date=$(date -v-${days_back}d +%Y-%m-%dT00:00:00.000 2>/dev/null || \
                          date -d "${days_back} days ago" +%Y-%m-%dT00:00:00.000)
    local pub_end_date=$(date +%Y-%m-%dT23:59:59.999)

    local url="${NVD_API_BASE}?keywordSearch=${keyword}&pubStartDate=${pub_start_date}&pubEndDate=${pub_end_date}"

    # Add API key header if available
    local headers=""
    if [[ -n "$NVD_API_KEY" ]]; then
        headers="-H 'apiKey: $NVD_API_KEY'"
    fi

    log "INFO" "Fetching CVEs for keyword: $keyword (last $days_back days)"

    # Rate limiting: NVD allows 5 requests/30s without key, 50/30s with key
    sleep 6

    local response
    response=$(curl -s -S --max-time 60 "$url" $headers 2>&1) || {
        log "ERROR" "Failed to fetch CVEs for $keyword: $response"
        echo "{}"
        return 1
    }

    # Check for API errors
    if echo "$response" | jq -e '.error' >/dev/null 2>&1; then
        local error_msg=$(echo "$response" | jq -r '.message // "Unknown error"')
        log "ERROR" "NVD API error: $error_msg"
        echo "{}"
        return 1
    fi

    echo "$response"
}

#
# Process and cache CVE data
#
process_cve_data() {
    local cve_response="$1"
    local keyword="$2"

    local total_results=$(echo "$cve_response" | jq -r '.totalResults // 0')

    if [[ "$total_results" -eq 0 ]]; then
        log "INFO" "No new CVEs found for: $keyword"
        return 0
    fi

    log "INFO" "Processing $total_results CVEs for: $keyword"

    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local critical_count=0
    local high_count=0

    # Process each CVE
    echo "$cve_response" | jq -c '.vulnerabilities[]' | while read -r vuln; do
        local cve_id=$(echo "$vuln" | jq -r '.cve.id')
        local published=$(echo "$vuln" | jq -r '.cve.published')
        local description=$(echo "$vuln" | jq -r '.cve.descriptions[0].value // "No description"')

        # Extract CVSS score (try v3.1, then v3.0, then v2.0)
        local cvss_score=$(echo "$vuln" | jq -r '
            .cve.metrics.cvssMetricV31[0].cvssData.baseScore //
            .cve.metrics.cvssMetricV30[0].cvssData.baseScore //
            .cve.metrics.cvssMetricV2[0].cvssData.baseScore //
            0
        ')

        local severity="unknown"
        if [[ $(echo "$cvss_score >= 9.0" | bc -l 2>/dev/null) -eq 1 ]]; then
            severity="critical"
        elif [[ $(echo "$cvss_score >= 7.0" | bc -l 2>/dev/null) -eq 1 ]]; then
            severity="high"
        elif [[ $(echo "$cvss_score >= 4.0" | bc -l 2>/dev/null) -eq 1 ]]; then
            severity="medium"
        elif [[ $(echo "$cvss_score > 0" | bc -l 2>/dev/null) -eq 1 ]]; then
            severity="low"
        fi

        # Extract affected products
        local affected_products=$(echo "$vuln" | jq -c '[.cve.configurations[].nodes[].cpeMatch[]?.criteria // empty] | unique | .[:5]')

        # Create cache entry
        local cache_file="$CVE_CACHE_DIR/${cve_id}.json"

        jq -n \
            --arg cve_id "$cve_id" \
            --arg published "$published" \
            --arg description "$description" \
            --arg cvss_score "$cvss_score" \
            --arg severity "$severity" \
            --arg keyword "$keyword" \
            --arg cached_at "$timestamp" \
            --argjson affected "$affected_products" \
            '{
                cve_id: $cve_id,
                published: $published,
                description: $description,
                cvss_score: ($cvss_score | tonumber),
                severity: $severity,
                search_keyword: $keyword,
                affected_products: $affected,
                cached_at: $cached_at,
                status: "new"
            }' > "$cache_file"

        # Create advisory for critical/high severity
        if [[ "$severity" == "critical" || "$severity" == "high" ]]; then
            create_advisory "$cve_id" "$severity" "$description" "$cvss_score"
        fi
    done

    log "INFO" "Processed $total_results CVEs for: $keyword"
}

#
# Create security advisory for critical/high CVEs
#
create_advisory() {
    local cve_id="$1"
    local severity="$2"
    local description="$3"
    local cvss_score="$4"

    local advisory_id="ADV-$(date +%Y%m%d)-${cve_id}"
    local advisory_file="$ADVISORY_DIR/${advisory_id}.json"
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Don't create duplicate advisories
    if [[ -f "$advisory_file" ]]; then
        return 0
    fi

    jq -n \
        --arg id "$advisory_id" \
        --arg cve "$cve_id" \
        --arg sev "$severity" \
        --arg desc "$description" \
        --arg cvss "$cvss_score" \
        --arg ts "$timestamp" \
        '{
            advisory_id: $id,
            cve_id: $cve,
            severity: $sev,
            cvss_score: ($cvss | tonumber),
            description: $desc,
            created_at: $ts,
            status: "new",
            recommended_actions: [
                "Review affected systems and dependencies",
                "Check if vulnerable versions are in use",
                "Apply patches or updates if available",
                "Implement compensating controls if patch unavailable"
            ],
            sla_deadline: (
                if $sev == "critical" then
                    "24h"
                else
                    "72h"
                end
            )
        }' > "$advisory_file"

    log "WARN" "Created advisory: $advisory_id ($severity) - $cve_id"

    # Emit event for monitoring
    emit_threat_event "$cve_id" "$severity" "$cvss_score"
}

#
# Emit threat intelligence event
#
emit_threat_event() {
    local cve_id="$1"
    local severity="$2"
    local cvss_score="$3"

    local event_file="$PROJECT_ROOT/coordination/dashboard-events.jsonl"
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    if [[ -w "$event_file" ]]; then
        jq -nc \
            --arg id "evt-threat-$(date +%s)" \
            --arg ts "$timestamp" \
            --arg cve "$cve_id" \
            --arg sev "$severity" \
            --arg cvss "$cvss_score" \
            '{
                id: $id,
                timestamp: $ts,
                type: "threat_intelligence",
                severity: $sev,
                data: {
                    cve_id: $cve,
                    cvss_score: ($cvss | tonumber),
                    action_required: ($sev == "critical" or $sev == "high")
                },
                source: "threat-intel-daemon"
            }' >> "$event_file"
    fi
}

#
# Sync all monitored keywords
#
sync_all_keywords() {
    local days_back="${1:-7}"

    log "INFO" "Starting full sync for ${#MONITORED_KEYWORDS[@]} keywords..."

    for keyword in "${MONITORED_KEYWORDS[@]}"; do
        local response=$(fetch_nvd_cves "$keyword" "$days_back")
        if [[ -n "$response" && "$response" != "{}" ]]; then
            process_cve_data "$response" "$keyword"
        fi
    done

    # Update state
    local state_file="$THREAT_INTEL_DIR/state.json"
    local total_cves=$(find "$CVE_CACHE_DIR" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
    local critical_cves=$(grep -l '"severity": "critical"' "$CVE_CACHE_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')
    local high_cves=$(grep -l '"severity": "high"' "$CVE_CACHE_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')

    jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       --arg total "$total_cves" \
       --arg critical "$critical_cves" \
       --arg high "$high_cves" \
       '.last_full_sync = $ts |
        .total_cves_cached = ($total | tonumber) |
        .critical_cves = ($critical | tonumber) |
        .high_cves = ($high | tonumber) |
        .last_updated = $ts' \
       "$state_file" > "${state_file}.tmp" && mv "${state_file}.tmp" "$state_file"

    log "INFO" "Full sync complete: $total_cves CVEs cached ($critical_cves critical, $high_cves high)"
}

#
# Check for recent critical vulnerabilities
#
check_critical_vulns() {
    log "INFO" "Checking for recent critical vulnerabilities..."

    # Fetch CVEs from last 24 hours with high severity
    for keyword in "${MONITORED_KEYWORDS[@]}"; do
        local response=$(fetch_nvd_cves "$keyword" 1)

        if [[ -n "$response" && "$response" != "{}" ]]; then
            # Check for critical/high severity
            local critical_count=$(echo "$response" | jq '[.vulnerabilities[].cve.metrics |
                (.cvssMetricV31[0].cvssData.baseScore // .cvssMetricV30[0].cvssData.baseScore // 0) |
                select(. >= 9.0)] | length')

            if [[ "$critical_count" -gt 0 ]]; then
                log "WARN" "Found $critical_count critical CVEs for: $keyword"
                process_cve_data "$response" "$keyword"
            fi
        fi
    done

    # Update state
    local state_file="$THREAT_INTEL_DIR/state.json"
    jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.last_recent_check = $ts | .last_updated = $ts' \
       "$state_file" > "${state_file}.tmp" && mv "${state_file}.tmp" "$state_file"
}

#
# Query threat intelligence database
#
query_threat_intel() {
    local query="$1"
    local severity_filter="${2:-}"

    log "INFO" "Querying threat intelligence for: $query"

    local results='[]'

    # Search in CVE cache
    for cache_file in "$CVE_CACHE_DIR"/*.json; do
        if [[ ! -f "$cache_file" ]]; then
            continue
        fi

        local matches=$(jq --arg q "$query" --arg sev "$severity_filter" '
            select(
                (.cve_id | ascii_downcase | contains($q | ascii_downcase)) or
                (.description | ascii_downcase | contains($q | ascii_downcase)) or
                (.search_keyword | ascii_downcase | contains($q | ascii_downcase))
            ) |
            if $sev != "" then
                select(.severity == $sev)
            else
                .
            end
        ' "$cache_file" 2>/dev/null)

        if [[ -n "$matches" ]]; then
            results=$(echo "$results" | jq --argjson m "$matches" '. + [$m]')
        fi
    done

    # Sort by CVSS score descending
    echo "$results" | jq 'sort_by(.cvss_score) | reverse'
}

#
# Get statistics
#
get_stats() {
    local state_file="$THREAT_INTEL_DIR/state.json"

    if [[ ! -f "$state_file" ]]; then
        echo "{}"
        return
    fi

    # Add live counts
    local total_cves=$(find "$CVE_CACHE_DIR" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
    local advisories=$(find "$ADVISORY_DIR" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')

    jq --arg total "$total_cves" --arg adv "$advisories" \
       '. + {current_cve_count: ($total | tonumber), active_advisories: ($adv | tonumber)}' \
       "$state_file"
}

#
# Cleanup on exit
#
cleanup() {
    log "INFO" "Shutting down threat intelligence daemon..."
    rm -f "$PID_FILE"
    log "INFO" "Daemon stopped"
}

#
# Main daemon loop
#
main() {
    trap cleanup EXIT INT TERM

    initialize

    local last_full_sync=0
    local last_recent_check=0
    local last_critical_check=0

    # Perform initial full sync
    sync_all_keywords 30

    log "INFO" "Starting monitoring loop..."

    while true; do
        local now=$(date +%s)

        # Check for critical vulnerabilities (every 15 minutes)
        if [[ $((now - last_critical_check)) -ge $CRITICAL_CHECK_INTERVAL ]]; then
            check_critical_vulns
            last_critical_check=$now
        fi

        # Check recent vulnerabilities (every hour)
        if [[ $((now - last_recent_check)) -ge $RECENT_CHECK_INTERVAL ]]; then
            sync_all_keywords 1
            last_recent_check=$now
        fi

        # Full sync (every 24 hours)
        if [[ $((now - last_full_sync)) -ge $FULL_SYNC_INTERVAL ]]; then
            sync_all_keywords 7
            last_full_sync=$now
        fi

        sleep 60
    done
}

#
# CLI commands
#
case "${1:-start}" in
    start)
        main
        ;;
    stop)
        if [[ -f "$PID_FILE" ]]; then
            local pid=$(cat "$PID_FILE")
            log "INFO" "Stopping daemon (PID: $pid)"
            kill "$pid" 2>/dev/null || true
            rm -f "$PID_FILE"
        else
            log "INFO" "Daemon not running"
        fi
        ;;
    status)
        if check_running; then
            log "INFO" "Daemon is running (PID: $(cat "$PID_FILE"))"
            get_stats | jq .
        else
            log "INFO" "Daemon is not running"
        fi
        ;;
    stats)
        get_stats | jq .
        ;;
    sync)
        days="${2:-7}"
        sync_all_keywords "$days"
        ;;
    query)
        query="${2:-}"
        severity="${3:-}"
        if [[ -z "$query" ]]; then
            echo "Usage: $0 query <keyword> [severity]"
            exit 1
        fi
        query_threat_intel "$query" "$severity" | jq .
        ;;
    advisories)
        find "$ADVISORY_DIR" -name "*.json" -exec cat {} \; | jq -s 'sort_by(.created_at) | reverse'
        ;;
    *)
        echo "Threat Intelligence Daemon"
        echo ""
        echo "Usage: $0 {start|stop|status|stats|sync|query|advisories}"
        echo ""
        echo "Commands:"
        echo "  start                    Start the daemon"
        echo "  stop                     Stop the daemon"
        echo "  status                   Check daemon status and show stats"
        echo "  stats                    Show threat intelligence statistics"
        echo "  sync [days]              Manually sync CVEs (default: 7 days)"
        echo "  query <keyword> [sev]    Query threat database"
        echo "  advisories               List all security advisories"
        exit 1
        ;;
esac
