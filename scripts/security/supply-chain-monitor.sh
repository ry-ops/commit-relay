#!/bin/bash
# Supply Chain Security Monitoring
# Phase 5 Item #62: Track dependency provenance, verify signatures

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

source "$COMMIT_RELAY_HOME/scripts/lib/logging.sh" 2>/dev/null || {
    log_info() { echo "[INFO] $1"; }
    log_warn() { echo "[WARN] $1"; }
    log_error() { echo "[ERROR] $1"; }
}

# Supply chain directory
SUPPLY_CHAIN_DIR="$COMMIT_RELAY_HOME/coordination/security/supply-chain"
mkdir -p "$SUPPLY_CHAIN_DIR"

# Scan dependencies
scan_dependencies() {
    local project_dir="${1:-$COMMIT_RELAY_HOME}"
    local output_file="$SUPPLY_CHAIN_DIR/deps-$(date +%Y%m%d-%H%M%S).json"

    log_info "Scanning dependencies in: $project_dir"

    local deps='{"npm": [], "pip": [], "system": []}'

    # NPM dependencies
    if [ -f "$project_dir/package.json" ]; then
        log_info "Scanning npm dependencies..."
        local npm_deps=$(jq -r '.dependencies // {} | keys[]' "$project_dir/package.json" 2>/dev/null || echo "")

        for dep in $npm_deps; do
            local version=$(jq -r ".dependencies[\"$dep\"]" "$project_dir/package.json")
            local dep_json=$(jq -n \
                --arg name "$dep" \
                --arg version "$version" \
                --arg source "npm" \
                '{name: $name, version: $version, source: $source}')
            deps=$(echo "$deps" | jq --argjson d "$dep_json" '.npm += [$d]')
        done
    fi

    # Check for package-lock.json integrity
    if [ -f "$project_dir/package-lock.json" ]; then
        local integrity_check="present"
        deps=$(echo "$deps" | jq --arg i "$integrity_check" '. + {npm_lockfile: $i}')
    fi

    # Python dependencies
    if [ -f "$project_dir/requirements.txt" ]; then
        log_info "Scanning pip dependencies..."
        while IFS= read -r line; do
            [[ "$line" =~ ^#.*$ ]] && continue
            [[ -z "$line" ]] && continue

            local name=$(echo "$line" | sed 's/[>=<].*$//')
            local version=$(echo "$line" | grep -oE '[0-9]+\.[0-9]+.*' || echo "any")

            local dep_json=$(jq -n \
                --arg name "$name" \
                --arg version "$version" \
                --arg source "pip" \
                '{name: $name, version: $version, source: $source}')
            deps=$(echo "$deps" | jq --argjson d "$dep_json" '.pip += [$d]')
        done < "$project_dir/requirements.txt"
    fi

    # Add metadata
    deps=$(echo "$deps" | jq \
        --arg scanned "$(date +%Y-%m-%dT%H:%M:%S%z)" \
        --arg project "$project_dir" \
        '. + {scanned_at: $scanned, project: $project}')

    echo "$deps" > "$output_file"
    log_info "Dependencies saved to: $output_file"

    echo "$deps"
}

# Check for known vulnerabilities
check_vulnerabilities() {
    local deps_file="${1:-$(ls -t "$SUPPLY_CHAIN_DIR"/deps-*.json 2>/dev/null | head -1)}"

    if [ -z "$deps_file" ] || [ ! -f "$deps_file" ]; then
        log_error "No dependency scan found. Run scan_dependencies first."
        return 1
    fi

    log_info "Checking vulnerabilities in: $deps_file"

    local vulns='[]'

    # Check npm dependencies against known vulnerable packages
    local vulnerable_packages=(
        "lodash:4.17.20:Prototype Pollution"
        "minimist:1.2.5:Prototype Pollution"
        "node-fetch:2.6.0:URL Redirect"
    )

    local npm_deps=$(jq -r '.npm[] | "\(.name):\(.version)"' "$deps_file")

    for dep in $npm_deps; do
        local dep_name="${dep%:*}"
        local dep_version="${dep#*:}"

        for vuln in "${vulnerable_packages[@]}"; do
            local vuln_name="${vuln%%:*}"
            local rest="${vuln#*:}"
            local vuln_version="${rest%%:*}"
            local vuln_desc="${rest#*:}"

            if [ "$dep_name" = "$vuln_name" ]; then
                local vuln_json=$(jq -n \
                    --arg pkg "$dep_name" \
                    --arg ver "$dep_version" \
                    --arg desc "$vuln_desc" \
                    --arg severity "medium" \
                    '{package: $pkg, version: $ver, vulnerability: $desc, severity: $severity}')
                vulns=$(echo "$vulns" | jq --argjson v "$vuln_json" '. + [$v]')
            fi
        done
    done

    local result=$(jq -n \
        --argjson vulns "$vulns" \
        --arg checked "$(date +%Y-%m-%dT%H:%M:%S%z)" \
        '{
            checked_at: $checked,
            vulnerabilities: $vulns,
            total: ($vulns | length),
            critical: ([($vulns // [])[] | select(.severity == "critical")] | length),
            high: ([($vulns // [])[] | select(.severity == "high")] | length),
            medium: ([($vulns // [])[] | select(.severity == "medium")] | length)
        }')

    local vuln_count=$(echo "$result" | jq '.total')
    if [ "$vuln_count" -gt 0 ]; then
        log_warn "Found $vuln_count potential vulnerabilities"
    else
        log_info "No known vulnerabilities found"
    fi

    echo "$result"
}

# Verify package integrity
verify_integrity() {
    local project_dir="${1:-$COMMIT_RELAY_HOME}"

    log_info "Verifying package integrity..."

    local results='{"checks": []}'

    # Check package-lock.json
    if [ -f "$project_dir/package-lock.json" ]; then
        if command -v npm &>/dev/null; then
            if npm ci --dry-run --prefix "$project_dir" &>/dev/null 2>&1; then
                local check=$(jq -n '{name: "npm-lockfile", status: "pass", message: "Lockfile valid"}')
            else
                local check=$(jq -n '{name: "npm-lockfile", status: "warn", message: "Lockfile may have issues"}')
            fi
            results=$(echo "$results" | jq --argjson c "$check" '.checks += [$c]')
        fi
    fi

    # Check for .npmrc with registry settings
    if [ -f "$project_dir/.npmrc" ]; then
        if grep -q "registry" "$project_dir/.npmrc"; then
            local check=$(jq -n '{name: "npm-registry", status: "info", message: "Custom registry configured"}')
        else
            local check=$(jq -n '{name: "npm-registry", status: "pass", message: "Using default registry"}')
        fi
        results=$(echo "$results" | jq --argjson c "$check" '.checks += [$c]')
    fi

    # Check git commit signatures (if available)
    if [ -d "$project_dir/.git" ]; then
        local signed_commits=$(git -C "$project_dir" log --format='%G?' -10 2>/dev/null | grep -c 'G' || echo "0")
        local check=$(jq -n \
            --argjson signed "$signed_commits" \
            '{name: "git-signatures", status: (if $signed > 0 then "pass" else "info" end), message: ($signed | tostring) + " signed commits in last 10"}')
        results=$(echo "$results" | jq --argjson c "$check" '.checks += [$c]')
    fi

    echo "$results" | jq '. + {verified_at: now | todate}'
}

# Generate SBOM (Software Bill of Materials)
generate_sbom() {
    local project_dir="${1:-$COMMIT_RELAY_HOME}"
    local output_file="$SUPPLY_CHAIN_DIR/sbom-$(date +%Y%m%d).json"

    log_info "Generating SBOM for: $project_dir"

    # Get dependencies
    local deps=$(scan_dependencies "$project_dir")

    # Build SBOM
    local sbom=$(jq -n \
        --arg name "commit-relay" \
        --arg version "1.0.0" \
        --arg generated "$(date +%Y-%m-%dT%H:%M:%S%z)" \
        --argjson deps "$deps" \
        '{
            sbom_version: "1.0",
            project: {
                name: $name,
                version: $version
            },
            generated_at: $generated,
            components: {
                npm: $deps.npm,
                pip: $deps.pip
            },
            total_components: (($deps.npm | length) + ($deps.pip | length))
        }')

    echo "$sbom" > "$output_file"
    log_info "SBOM saved to: $output_file"

    echo "$sbom"
}

# Export functions
export -f scan_dependencies
export -f check_vulnerabilities
export -f verify_integrity
export -f generate_sbom

# CLI
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    case "${1:-help}" in
        scan)
            scan_dependencies "${2:-$COMMIT_RELAY_HOME}"
            ;;
        vuln|vulnerabilities)
            check_vulnerabilities "${2:-}"
            ;;
        verify)
            verify_integrity "${2:-$COMMIT_RELAY_HOME}"
            ;;
        sbom)
            generate_sbom "${2:-$COMMIT_RELAY_HOME}"
            ;;
        *)
            echo "Supply Chain Security Monitor"
            echo "Usage: supply-chain-monitor.sh <command> [args]"
            echo ""
            echo "Commands:"
            echo "  scan [project_dir]     Scan dependencies"
            echo "  vuln [deps_file]       Check for vulnerabilities"
            echo "  verify [project_dir]   Verify package integrity"
            echo "  sbom [project_dir]     Generate SBOM"
            ;;
    esac
fi
