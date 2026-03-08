#!/bin/bash
# scripts/hooks/pre-commit-secrets-scan.sh
# Pre-commit hook to scan for secrets and PII in staged files
#
# Installation:
#   ln -sf ../../scripts/hooks/pre-commit-secrets-scan.sh .git/hooks/pre-commit
# Or run:
#   ./scripts/hooks/pre-commit-secrets-scan.sh --install

set -eo pipefail

# Get commit-relay home
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# Handle --install flag
if [[ "${1:-}" == "--install" ]]; then
    HOOK_PATH="$COMMIT_RELAY_HOME/.git/hooks/pre-commit"
    ln -sf "../../scripts/hooks/pre-commit-secrets-scan.sh" "$HOOK_PATH"
    chmod +x "$HOOK_PATH"
    echo "Pre-commit secrets scan hook installed successfully"
    exit 0
fi

# Source PII scanner
PII_SCANNER="$COMMIT_RELAY_HOME/coordination/governance/lib/pii-scanner.sh"
if [[ ! -f "$PII_SCANNER" ]]; then
    echo "Warning: PII scanner not found at $PII_SCANNER"
    exit 0
fi

source "$PII_SCANNER"

# Get list of staged files (excluding deleted files)
STAGED_FILES=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null || true)

if [[ -z "$STAGED_FILES" ]]; then
    exit 0
fi

# Track if any secrets found
SECRETS_FOUND=false
BLOCKED_FILES=()

echo "Running pre-commit secrets scan..."

# Scan each staged file
while IFS= read -r file; do
    # Skip binary files and certain file types
    if [[ "$file" =~ \.(png|jpg|jpeg|gif|ico|pdf|zip|tar|gz|bin|exe)$ ]]; then
        continue
    fi

    # Skip node_modules and other common directories
    if [[ "$file" =~ ^(node_modules|\.git|vendor|dist|build)/ ]]; then
        continue
    fi

    # Skip the PII scanner itself and test files
    if [[ "$file" =~ pii-scanner\.sh$ ]] || [[ "$file" =~ test.*pii ]]; then
        continue
    fi

    # Get staged content of file
    CONTENT=$(git show ":$file" 2>/dev/null || true)

    if [[ -z "$CONTENT" ]]; then
        continue
    fi

    # Scan for PII/secrets
    RESULT=$(scan_for_pii "$CONTENT" "pre-commit:$file")

    # Check risk level
    RISK_LEVEL=$(echo "$RESULT" | jq -r '.risk_level // "none"')
    HAS_PII=$(echo "$RESULT" | jq -r '.has_pii // false')

    if [[ "$RISK_LEVEL" == "critical" ]] || [[ "$RISK_LEVEL" == "high" ]]; then
        SECRETS_FOUND=true
        BLOCKED_FILES+=("$file")

        echo ""
        echo "BLOCKED: $file"
        echo "Risk Level: $RISK_LEVEL"
        echo "Findings:"
        echo "$RESULT" | jq -r '.findings[] | "  - \(.type) (\(.confidence) confidence)"'
    fi
done <<< "$STAGED_FILES"

# Block commit if secrets found
if [[ "$SECRETS_FOUND" == "true" ]]; then
    echo ""
    echo "=========================================="
    echo "COMMIT BLOCKED: Secrets/PII detected"
    echo "=========================================="
    echo ""
    echo "The following files contain sensitive data:"
    for f in "${BLOCKED_FILES[@]}"; do
        echo "  - $f"
    done
    echo ""
    echo "Please remove the sensitive data before committing."
    echo "If this is a false positive, you can bypass with:"
    echo "  git commit --no-verify"
    echo ""
    exit 1
fi

echo "Pre-commit secrets scan passed"
exit 0
