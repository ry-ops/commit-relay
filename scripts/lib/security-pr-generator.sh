#!/bin/bash
# scripts/lib/security-pr-generator.sh
# Security PR Generator Library
# Creates pull requests for security fixes including dependency updates and vulnerability remediations
#
# Features:
#   - Create security-focused PRs with proper branching
#   - Generate detailed PR descriptions with CVE info
#   - Apply dependency updates across package managers
#   - Request security team reviews
#   - Track remediation attempts
#
# Usage:
#   source "$COMMIT_RELAY_HOME/scripts/lib/security-pr-generator.sh"
#   create_security_pr "/path/to/repo" "dependency_update" '{"cve":"CVE-2021-23337",...}'
#
# CLI Usage:
#   ./security-pr-generator.sh --repo /path/to/repo --type dependency_update \
#     --package lodash --from 4.17.19 --to 4.17.21 --cve CVE-2021-23337 --severity high

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# Metrics and logging
REMEDIATION_LOG="${COMMIT_RELAY_HOME}/coordination/metrics/security-remediation.jsonl"
SECURITY_EVENTS="${COMMIT_RELAY_HOME}/coordination/events/security-events.jsonl"

# Ensure directories exist
mkdir -p "$(dirname "$REMEDIATION_LOG")"
mkdir -p "$(dirname "$SECURITY_EVENTS")"

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# ============================================================================
# Logging
# ============================================================================

log_security() {
    local level="$1"
    shift
    echo -e "[$(date +%Y-%m-%dT%H:%M:%S%z)] [SECURITY-PR] [$level] $*" >&2
}

# ============================================================================
# create_commit_message: Generate security-focused commit message
# Args: package, version, cve_id, severity
# Returns: Commit message string
# ============================================================================

create_commit_message() {
    local package="$1"
    local version="$2"
    local cve_id="${3:-}"
    local severity="${4:-unknown}"
    local fix_type="${5:-dependency_update}"

    local title=""
    local body=""

    case "$fix_type" in
        "dependency_update")
            if [ -n "$cve_id" ]; then
                title="fix(security): Update $package to $version ($cve_id)"
            else
                title="fix(security): Update $package to $version"
            fi
            body="Severity: $severity"
            if [ -n "$cve_id" ]; then
                body="$body
CVE: https://nvd.nist.gov/vuln/detail/$cve_id"
            fi
            ;;
        "secret_rotation")
            title="fix(security): Rotate exposed $package credential"
            body="Secret type: $package
Action: Credential rotation and removal from codebase"
            ;;
        "code_fix")
            title="fix(security): Remediate $package vulnerability"
            body="Severity: $severity
Type: Code-level security fix"
            if [ -n "$cve_id" ]; then
                body="$body
CVE: https://nvd.nist.gov/vuln/detail/$cve_id"
            fi
            ;;
        *)
            title="fix(security): Security remediation for $package"
            body="Severity: $severity"
            ;;
    esac

    cat <<EOF
$title

$body

Autonomous: commit-relay security automation

Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
}

# ============================================================================
# generate_pr_description: Build comprehensive PR body
# Args: JSON with vulnerability info
# Returns: PR description markdown
# ============================================================================

generate_pr_description() {
    local vuln_info="$1"

    local cve_id=$(echo "$vuln_info" | jq -r '.cve // ""')
    local severity=$(echo "$vuln_info" | jq -r '.severity // "unknown"')
    local package=$(echo "$vuln_info" | jq -r '.package // ""')
    local from_version=$(echo "$vuln_info" | jq -r '.from_version // ""')
    local to_version=$(echo "$vuln_info" | jq -r '.to_version // ""')
    local affected_files=$(echo "$vuln_info" | jq -r '.affected_files // []')
    local fix_type=$(echo "$vuln_info" | jq -r '.fix_type // "dependency_update"')

    # Build severity badge
    local severity_emoji=""
    case "$severity" in
        "critical") severity_emoji="[CRITICAL]" ;;
        "high") severity_emoji="[HIGH]" ;;
        "medium") severity_emoji="[MEDIUM]" ;;
        "low") severity_emoji="[LOW]" ;;
        *) severity_emoji="[$severity]" ;;
    esac

    # Start building the description
    cat <<EOF
## Summary

This PR addresses a security vulnerability identified in the codebase.

**Severity**: $severity_emoji
EOF

    if [ -n "$cve_id" ]; then
        cat <<EOF
**CVE**: [$cve_id](https://nvd.nist.gov/vuln/detail/$cve_id)
EOF
    fi

    case "$fix_type" in
        "dependency_update")
            cat <<EOF

### Dependency Update

| Package | From | To |
|---------|------|-----|
| $package | $from_version | $to_version |
EOF
            ;;
        "secret_rotation")
            cat <<EOF

### Secret Rotation

- **Secret Type**: $package
- **Action**: Removed hardcoded credential and configured for environment variable injection
EOF
            ;;
        "code_fix")
            cat <<EOF

### Code Remediation

- **Issue**: $package
- **Fix**: Applied security patch to address vulnerability
EOF
            ;;
    esac

    # Add affected files if available
    if [ "$affected_files" != "[]" ] && [ -n "$affected_files" ]; then
        cat <<EOF

### Affected Files

EOF
        echo "$affected_files" | jq -r '.[]' | while read -r file; do
            echo "- \`$file\`"
        done
    fi

    # Add testing recommendations
    cat <<EOF

## Test Plan

- [ ] Verify the application builds successfully
- [ ] Run existing test suite to ensure no regressions
- [ ] Verify the security fix addresses the vulnerability
EOF

    case "$fix_type" in
        "dependency_update")
            cat <<EOF
- [ ] Confirm dependency version matches expected: \`$package@$to_version\`
- [ ] Test functionality that relies on \`$package\`
EOF
            ;;
        "secret_rotation")
            cat <<EOF
- [ ] Verify old credential has been revoked
- [ ] Confirm new credential is properly configured in environment
- [ ] Test authentication/authorization workflows
EOF
            ;;
    esac

    cat <<EOF

## Security Review

This PR requires review from the security team due to its security-sensitive nature.

EOF

    if [ -n "$cve_id" ]; then
        cat <<EOF
### References

- [NVD: $cve_id](https://nvd.nist.gov/vuln/detail/$cve_id)
- [MITRE: $cve_id](https://cve.mitre.org/cgi-bin/cvename.cgi?name=$cve_id)
EOF
    fi

    cat <<EOF

---

Generated with [Claude Code](https://claude.com/claude-code)
EOF
}

# ============================================================================
# apply_dependency_update: Update package versions in manifests
# Args: repo_path, package, from_version, to_version
# Returns: 0 on success, 1 on failure
# ============================================================================

apply_dependency_update() {
    local repo_path="$1"
    local package="$2"
    local from_version="$3"
    local to_version="$4"

    log_security "INFO" "Applying dependency update: $package $from_version -> $to_version"

    local updated=false
    local affected_files=()

    # Check for package.json (npm/yarn)
    if [ -f "$repo_path/package.json" ]; then
        log_security "INFO" "Updating package.json"

        # Update package.json using jq
        local temp_pkg=$(mktemp)
        jq --arg pkg "$package" --arg ver "$to_version" '
            if .dependencies[$pkg] then
                .dependencies[$pkg] = $ver
            elif .devDependencies[$pkg] then
                .devDependencies[$pkg] = $ver
            else
                .
            end
        ' "$repo_path/package.json" > "$temp_pkg"
        mv "$temp_pkg" "$repo_path/package.json"

        affected_files+=("package.json")

        # Run npm install to update lockfile
        if [ -f "$repo_path/package-lock.json" ]; then
            log_security "INFO" "Running npm install to update lockfile"
            (cd "$repo_path" && npm install --package-lock-only 2>&1) || {
                log_security "WARN" "npm install failed, lockfile may be out of sync"
            }
            affected_files+=("package-lock.json")
        elif [ -f "$repo_path/yarn.lock" ]; then
            log_security "INFO" "Running yarn install to update lockfile"
            (cd "$repo_path" && yarn install 2>&1) || {
                log_security "WARN" "yarn install failed, lockfile may be out of sync"
            }
            affected_files+=("yarn.lock")
        fi

        updated=true
    fi

    # Check for requirements.txt (Python)
    if [ -f "$repo_path/requirements.txt" ]; then
        log_security "INFO" "Updating requirements.txt"

        # Update version in requirements.txt
        sed -i.bak "s/^${package}==.*/${package}==${to_version}/" "$repo_path/requirements.txt"
        sed -i.bak "s/^${package}>=.*/${package}>=${to_version}/" "$repo_path/requirements.txt"
        rm -f "$repo_path/requirements.txt.bak"

        affected_files+=("requirements.txt")
        updated=true
    fi

    # Check for Cargo.toml (Rust)
    if [ -f "$repo_path/Cargo.toml" ]; then
        log_security "INFO" "Updating Cargo.toml"

        # Update version in Cargo.toml (simplified approach)
        sed -i.bak "s/${package} = \"${from_version}\"/${package} = \"${to_version}\"/" "$repo_path/Cargo.toml"
        sed -i.bak "s/${package} = { version = \"${from_version}\"/${package} = { version = \"${to_version}\"/" "$repo_path/Cargo.toml"
        rm -f "$repo_path/Cargo.toml.bak"

        affected_files+=("Cargo.toml")

        # Update Cargo.lock
        if [ -f "$repo_path/Cargo.lock" ]; then
            log_security "INFO" "Running cargo update to update lockfile"
            (cd "$repo_path" && cargo update -p "$package" 2>&1) || {
                log_security "WARN" "cargo update failed"
            }
            affected_files+=("Cargo.lock")
        fi

        updated=true
    fi

    if [ "$updated" = "false" ]; then
        log_security "ERROR" "No supported package manifest found"
        return 1
    fi

    # Verify build still works (optional quick check)
    log_security "INFO" "Verifying build"
    if [ -f "$repo_path/package.json" ]; then
        if (cd "$repo_path" && npm run build --if-present 2>&1); then
            log_security "INFO" "Build verification passed"
        else
            log_security "WARN" "Build verification failed - PR will need manual review"
        fi
    fi

    # Return affected files as JSON array
    printf '%s\n' "${affected_files[@]}" | jq -R . | jq -s .
}

# ============================================================================
# request_security_review: Add reviewers and labels
# Args: pr_url, severity
# Returns: 0 on success, 1 on failure
# ============================================================================

request_security_review() {
    local pr_url="$1"
    local severity="$2"

    log_security "INFO" "Requesting security review for PR: $pr_url"

    # Extract PR number from URL
    local pr_number=$(echo "$pr_url" | grep -o '[0-9]*$')

    if [ -z "$pr_number" ]; then
        log_security "ERROR" "Could not extract PR number from URL"
        return 1
    fi

    # Add security label
    if gh pr edit "$pr_number" --add-label "security" 2>/dev/null; then
        log_security "INFO" "Added 'security' label"
    fi

    # Add severity-based labels
    case "$severity" in
        "critical")
            gh pr edit "$pr_number" --add-label "priority:critical" 2>/dev/null || true
            gh pr edit "$pr_number" --add-label "urgent" 2>/dev/null || true
            ;;
        "high")
            gh pr edit "$pr_number" --add-label "priority:high" 2>/dev/null || true
            ;;
        "medium")
            gh pr edit "$pr_number" --add-label "priority:medium" 2>/dev/null || true
            ;;
        "low")
            gh pr edit "$pr_number" --add-label "priority:low" 2>/dev/null || true
            ;;
    esac

    # Request review from security team (if configured)
    # This is often organization-specific
    if gh pr edit "$pr_number" --add-reviewer "security-team" 2>/dev/null; then
        log_security "INFO" "Requested review from security team"
    else
        log_security "WARN" "Could not request security team review (team may not exist)"
    fi

    return 0
}

# ============================================================================
# log_remediation: Track remediation attempts
# Args: pr_url, vulnerability_info, status
# Returns: void
# ============================================================================

log_remediation() {
    local pr_url="$1"
    local vuln_info="$2"
    local status="$3"

    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    local cve_id=$(echo "$vuln_info" | jq -r '.cve // ""')
    local package=$(echo "$vuln_info" | jq -r '.package // ""')
    local severity=$(echo "$vuln_info" | jq -r '.severity // "unknown"')
    local fix_type=$(echo "$vuln_info" | jq -r '.fix_type // "dependency_update"')

    local log_entry=$(jq -nc \
        --arg pr_url "$pr_url" \
        --arg cve_id "$cve_id" \
        --arg package "$package" \
        --arg severity "$severity" \
        --arg fix_type "$fix_type" \
        --arg status "$status" \
        --arg created_at "$timestamp" \
        '{
            pr_url: $pr_url,
            vulnerability: {
                cve: $cve_id,
                package: $package,
                severity: $severity
            },
            fix_type: $fix_type,
            status: $status,
            created_at: $created_at
        }')

    echo "$log_entry" >> "$REMEDIATION_LOG"
    log_security "INFO" "Logged remediation: $status for $package"

    # Also emit an event
    local event=$(jq -nc \
        --arg event_type "security_remediation_$status" \
        --arg timestamp "$timestamp" \
        --argjson data "$log_entry" \
        '{
            event_type: $event_type,
            timestamp: $timestamp,
            data: $data
        }')

    echo "$event" >> "$SECURITY_EVENTS"
}

# ============================================================================
# create_security_pr: Main PR creation function
# Args: repo_path, fix_type, vulnerability_info (JSON)
# Returns: PR URL on success, empty on failure
# ============================================================================

create_security_pr() {
    local repo_path="$1"
    local fix_type="$2"
    local vuln_info="$3"

    log_security "INFO" "Creating security PR in $repo_path"

    # Check if gh CLI is available
    if ! command -v gh &> /dev/null; then
        log_security "ERROR" "gh CLI not installed"
        echo ""
        return 1
    fi

    # Check if repo exists
    if [ ! -d "$repo_path/.git" ]; then
        log_security "ERROR" "Not a git repository: $repo_path"
        echo ""
        return 1
    fi

    # Extract info from vulnerability JSON
    local cve_id=$(echo "$vuln_info" | jq -r '.cve // ""')
    local package=$(echo "$vuln_info" | jq -r '.package // ""')
    local from_version=$(echo "$vuln_info" | jq -r '.from_version // ""')
    local to_version=$(echo "$vuln_info" | jq -r '.to_version // ""')
    local severity=$(echo "$vuln_info" | jq -r '.severity // "unknown"')

    # Determine branch name
    local branch_name=""
    if [ -n "$cve_id" ]; then
        branch_name="security-fix/${cve_id}"
    elif [ -n "$package" ] && [ -n "$to_version" ]; then
        branch_name="security-fix/${package}-${to_version}"
    else
        branch_name="security-fix/$(date +%Y%m%d-%H%M%S)"
    fi

    log_security "INFO" "Creating branch: $branch_name"

    # Navigate to repo and create branch
    pushd "$repo_path" > /dev/null

    # Ensure we're on a clean state
    local current_branch=$(git rev-parse --abbrev-ref HEAD)
    local default_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")

    # Fetch latest and create branch from default
    git fetch origin "$default_branch" --quiet 2>/dev/null || true
    git checkout -b "$branch_name" "origin/$default_branch" 2>/dev/null || {
        git checkout -b "$branch_name" 2>/dev/null || {
            log_security "ERROR" "Failed to create branch: $branch_name"
            popd > /dev/null
            return 1
        }
    }

    # Apply the fix based on type
    local affected_files="[]"
    case "$fix_type" in
        "dependency_update")
            affected_files=$(apply_dependency_update "$repo_path" "$package" "$from_version" "$to_version")
            if [ $? -ne 0 ]; then
                log_security "ERROR" "Failed to apply dependency update"
                git checkout "$current_branch" 2>/dev/null || true
                git branch -D "$branch_name" 2>/dev/null || true
                popd > /dev/null
                log_remediation "" "$vuln_info" "failed"
                return 1
            fi
            ;;
        "secret_rotation")
            # For secret rotation, changes are typically done manually or by another tool
            # We just stage existing changes
            affected_files=$(git diff --name-only | jq -R . | jq -s .)
            ;;
        *)
            log_security "WARN" "Unknown fix type: $fix_type, staging all changes"
            affected_files=$(git diff --name-only | jq -R . | jq -s .)
            ;;
    esac

    # Update vuln_info with affected files
    vuln_info=$(echo "$vuln_info" | jq --argjson files "$affected_files" '. + {affected_files: $files}')

    # Stage changes
    git add -A 2>/dev/null || true

    # Check if there are changes to commit
    if git diff --cached --quiet; then
        log_security "WARN" "No changes to commit"
        git checkout "$current_branch" 2>/dev/null || true
        git branch -D "$branch_name" 2>/dev/null || true
        popd > /dev/null
        return 1
    fi

    # Create commit
    local commit_msg=$(create_commit_message "$package" "$to_version" "$cve_id" "$severity" "$fix_type")

    log_security "INFO" "Creating commit"
    git commit -m "$commit_msg" --quiet 2>/dev/null || {
        log_security "ERROR" "Failed to create commit"
        git checkout "$current_branch" 2>/dev/null || true
        git branch -D "$branch_name" 2>/dev/null || true
        popd > /dev/null
        log_remediation "" "$vuln_info" "failed"
        return 1
    }

    # Push branch
    log_security "INFO" "Pushing branch to remote"
    git push -u origin "$branch_name" --quiet 2>/dev/null || {
        log_security "ERROR" "Failed to push branch"
        git checkout "$current_branch" 2>/dev/null || true
        popd > /dev/null
        log_remediation "" "$vuln_info" "failed"
        return 1
    }

    # Generate PR description
    local pr_body=$(generate_pr_description "$vuln_info")

    # Create PR title
    local pr_title=""
    if [ -n "$cve_id" ]; then
        pr_title="[Security] Update $package to $to_version ($cve_id)"
    else
        pr_title="[Security] Update $package to $to_version"
    fi

    # Create PR using gh CLI
    log_security "INFO" "Creating pull request"
    local pr_url=$(gh pr create \
        --title "$pr_title" \
        --body "$pr_body" \
        --base "$default_branch" \
        --head "$branch_name" \
        2>&1)

    if [ $? -eq 0 ]; then
        log_security "INFO" "Pull request created: $pr_url"

        # Request security review
        request_security_review "$pr_url" "$severity"

        # Log successful remediation
        log_remediation "$pr_url" "$vuln_info" "created"

        # Return to original branch
        git checkout "$current_branch" 2>/dev/null || true
        popd > /dev/null

        echo "$pr_url"
        return 0
    else
        log_security "ERROR" "Failed to create PR: $pr_url"
        git checkout "$current_branch" 2>/dev/null || true
        popd > /dev/null
        log_remediation "" "$vuln_info" "failed"
        return 1
    fi
}

# ============================================================================
# get_remediation_stats: Get statistics on remediation attempts
# Returns: JSON with stats
# ============================================================================

get_remediation_stats() {
    if [ ! -f "$REMEDIATION_LOG" ]; then
        echo '{"total":0,"created":0,"failed":0,"success_rate":0}'
        return 0
    fi

    local total=$(wc -l < "$REMEDIATION_LOG" | tr -d ' ')
    local created=$(grep -c '"status":"created"' "$REMEDIATION_LOG" 2>/dev/null || echo "0")
    local failed=$(grep -c '"status":"failed"' "$REMEDIATION_LOG" 2>/dev/null || echo "0")

    local success_rate=0
    if [ "$total" -gt 0 ]; then
        success_rate=$(echo "scale=2; $created / $total * 100" | bc)
    fi

    jq -nc \
        --argjson total "$total" \
        --argjson created "$created" \
        --argjson failed "$failed" \
        --arg success_rate "$success_rate" \
        '{
            total: $total,
            created: $created,
            failed: $failed,
            success_rate: ($success_rate | tonumber)
        }'
}

# ============================================================================
# Export functions
# ============================================================================

export -f create_security_pr 2>/dev/null || true
export -f generate_pr_description 2>/dev/null || true
export -f apply_dependency_update 2>/dev/null || true
export -f create_commit_message 2>/dev/null || true
export -f request_security_review 2>/dev/null || true
export -f log_remediation 2>/dev/null || true
export -f get_remediation_stats 2>/dev/null || true

# ============================================================================
# CLI Interface
# ============================================================================

main() {
    local repo_path=""
    local fix_type=""
    local package=""
    local from_version=""
    local to_version=""
    local cve_id=""
    local severity="unknown"
    local secret_type=""
    local file=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --repo)
                repo_path="$2"
                shift 2
                ;;
            --type)
                fix_type="$2"
                shift 2
                ;;
            --package)
                package="$2"
                shift 2
                ;;
            --from)
                from_version="$2"
                shift 2
                ;;
            --to)
                to_version="$2"
                shift 2
                ;;
            --cve)
                cve_id="$2"
                shift 2
                ;;
            --severity)
                severity="$2"
                shift 2
                ;;
            --secret-type)
                secret_type="$2"
                shift 2
                ;;
            --file)
                file="$2"
                shift 2
                ;;
            --stats)
                get_remediation_stats
                exit 0
                ;;
            --help|-h)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --repo PATH           Repository path"
                echo "  --type TYPE           Fix type (dependency_update, secret_rotation, code_fix)"
                echo "  --package NAME        Package name"
                echo "  --from VERSION        Current version"
                echo "  --to VERSION          Target version"
                echo "  --cve CVE-ID          CVE identifier"
                echo "  --severity LEVEL      Severity (critical, high, medium, low)"
                echo "  --secret-type TYPE    Secret type for rotation"
                echo "  --file PATH           Affected file"
                echo "  --stats               Show remediation statistics"
                echo "  --help                Show this help"
                echo ""
                echo "Examples:"
                echo "  # Update npm dependency"
                echo "  $0 --repo /path/to/repo --type dependency_update \\"
                echo "     --package lodash --from 4.17.19 --to 4.17.21 \\"
                echo "     --cve CVE-2021-23337 --severity high"
                echo ""
                echo "  # Rotate exposed secret"
                echo "  $0 --repo /path/to/repo --type secret_rotation \\"
                echo "     --secret-type aws_access_key --file src/config.js"
                exit 0
                ;;
            *)
                echo "Unknown option: $1" >&2
                exit 1
                ;;
        esac
    done

    # Validate required arguments
    if [ -z "$repo_path" ]; then
        echo "Error: --repo is required" >&2
        exit 1
    fi

    if [ -z "$fix_type" ]; then
        echo "Error: --type is required" >&2
        exit 1
    fi

    # Build vulnerability info JSON
    local vuln_info=""
    case "$fix_type" in
        "dependency_update")
            if [ -z "$package" ] || [ -z "$to_version" ]; then
                echo "Error: --package and --to are required for dependency_update" >&2
                exit 1
            fi
            vuln_info=$(jq -nc \
                --arg package "$package" \
                --arg from_version "$from_version" \
                --arg to_version "$to_version" \
                --arg cve "$cve_id" \
                --arg severity "$severity" \
                --arg fix_type "$fix_type" \
                '{
                    package: $package,
                    from_version: $from_version,
                    to_version: $to_version,
                    cve: $cve,
                    severity: $severity,
                    fix_type: $fix_type
                }')
            ;;
        "secret_rotation")
            if [ -z "$secret_type" ]; then
                echo "Error: --secret-type is required for secret_rotation" >&2
                exit 1
            fi
            vuln_info=$(jq -nc \
                --arg package "$secret_type" \
                --arg file "$file" \
                --arg severity "$severity" \
                --arg fix_type "$fix_type" \
                '{
                    package: $package,
                    file: $file,
                    severity: $severity,
                    fix_type: $fix_type
                }')
            ;;
        *)
            vuln_info=$(jq -nc \
                --arg package "$package" \
                --arg cve "$cve_id" \
                --arg severity "$severity" \
                --arg fix_type "$fix_type" \
                '{
                    package: $package,
                    cve: $cve,
                    severity: $severity,
                    fix_type: $fix_type
                }')
            ;;
    esac

    # Create the security PR
    local pr_url=$(create_security_pr "$repo_path" "$fix_type" "$vuln_info")

    if [ -n "$pr_url" ]; then
        echo -e "${GREEN}Successfully created security PR: $pr_url${NC}"
        exit 0
    else
        echo -e "${RED}Failed to create security PR${NC}" >&2
        exit 1
    fi
}

# Run main if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

log_security "INFO" "Security PR generator library loaded"
