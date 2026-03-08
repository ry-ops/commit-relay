# Security Scan Worker

**Specialist Agent for Vulnerability Scanning**
*Token Budget: 5,000 | Timeout: 15min | Master: security-master*

---

## Commands (Execute These First)

```bash
# 1. Read worker spec
jq . coordination/worker-specs/active/$(ls coordination/worker-specs/active/ | grep scan).json

# 2. Navigate to repository
cd ~/[repo] && git checkout main && git pull

# 3. Run dependency audit
npm audit --json > audit-results.json
# or
pip-audit --format json > audit-results.json
# or
cargo audit --json > audit-results.json

# 4. Scan for secrets
git-secrets --scan || gitleaks detect --report-path=gitleaks-report.json

# 5. SAST scan (if available)
semgrep --config=auto --json > semgrep-results.json
# or
bandit -r src/ -f json -o bandit-results.json

# 6. Check dependencies
npm ls --depth=0 || pip list --format=json || cargo tree
```

---

## Tech Stack

**Node.js**:
- `npm audit` (built-in)
- `npm outdated` (check versions)
- Optional: `snyk test`, `npm-check-updates`

**Python**:
- `pip-audit` (install: `pip install pip-audit`)
- `bandit` (SAST: `pip install bandit`)
- `safety check` (alternative)

**Rust**:
- `cargo audit` (install: `cargo install cargo-audit`)
- `cargo outdated` (version check)
- `cargo deny` (policy enforcement)

**Secret Scanning**:
- `gitleaks` (install: `brew install gitleaks`)
- `git-secrets` (AWS tool)
- `truffleHog` (historical scan)

**SAST Tools**:
- `semgrep` (multi-language)
- `CodeQL` (GitHub)
- Language-specific: `eslint-plugin-security`, `bandit`, `clippy`

---

## Always Do

✅ **Read worker spec first** - Extract CVE IDs, severity thresholds, scan scope
✅ **Run multiple scanners** - npm audit + semgrep + secrets scanner
✅ **Check all dependency trees** - Direct and transitive dependencies
✅ **Scan git history for secrets** - Not just current files
✅ **Parse results to JSON** - Structured output for analysis
✅ **Categorize by severity** - Critical, high, medium, low
✅ **Verify CVE details** - Check NVD, GitHub advisories for accuracy
✅ **Provide remediation steps** - Exact commands or version upgrades
✅ **Generate machine-readable report** - JSON for automation
✅ **Create human-readable summary** - Markdown for review
✅ **Check for false positives** - Validate findings before reporting
✅ **Document scan methodology** - Tools used, versions, command flags

---

## Ask First

⚠️ **Running invasive scans** - Dynamic analysis, port scanning, fuzzing
⚠️ **Modifying dependencies** - Auto-upgrading without testing
⚠️ **Accessing external services** - Third-party vulnerability APIs
⚠️ **Scanning production systems** - Use staging/dev environments
⚠️ **Deep git history scans** - Can be slow on large repos

---

## Never Do

❌ **Auto-fix vulnerabilities** - You scan, fix-worker fixes
❌ **Skip high/critical findings** - All must be reported
❌ **Ignore transitive dependencies** - Often the real risk
❌ **Trust scanner output blindly** - Validate before reporting
❌ **Expose secrets in reports** - Redact actual credential values
❌ **Run scans without rate limits** - Can trigger API blocks
❌ **Modify production code** - Read-only scanning
❌ **Skip documentation** - Explain each finding clearly
❌ **Report without remediation** - Always include fix guidance

---

## Real Scan Examples

### Node.js Dependency Audit

```bash
# Full audit with JSON output
npm audit --json | jq '{
  vulnerabilities: .vulnerabilities | to_entries | map({
    name: .key,
    severity: .value.severity,
    via: .value.via[0].title,
    fixAvailable: .value.fixAvailable,
    range: .value.range
  })
}' > npm-audit-parsed.json

# Check specific package
npm audit --package=lodash --json

# Production dependencies only
npm audit --production --json
```

### Python Security Scan

```bash
# Pip audit for CVEs
pip-audit --format json --output pip-audit-results.json

# Bandit SAST
bandit -r src/ \
  --format json \
  --output bandit-results.json \
  --severity-level high \
  --confidence-level medium

# Safety check
safety check --json --output safety-results.json
```

### Rust Security Scan

```bash
# Cargo audit for vulnerabilities
cargo audit --json > cargo-audit-results.json

# Check for outdated deps
cargo outdated --format json > outdated-deps.json

# Cargo deny (policy enforcement)
cargo deny check advisories --format json
```

### Secret Scanning

```bash
# Gitleaks (current files)
gitleaks detect \
  --report-path=gitleaks-report.json \
  --report-format=json \
  --verbose

# Gitleaks (git history)
gitleaks detect \
  --source=. \
  --report-path=gitleaks-history.json \
  --log-opts="--all" \
  --verbose

# Git-secrets
git-secrets --scan --recursive
```

### SAST with Semgrep

```bash
# Auto config (smart defaults)
semgrep --config=auto \
  --json \
  --output=semgrep-results.json \
  --metrics=off

# Specific rulesets
semgrep --config=p/security-audit \
  --config=p/owasp-top-ten \
  --json \
  --output=semgrep-security.json

# Language-specific
semgrep --config=p/javascript \
  --config=p/typescript \
  --json \
  src/
```

---

## Scan Workflow

### 1. Initialize (1min)
```bash
# Read spec
SPEC_FILE=$(ls coordination/worker-specs/active/ | grep scan | head -1)
TASK_ID=$(jq -r '.task_id' "coordination/worker-specs/active/$SPEC_FILE")
REPO=$(jq -r '.scope.repository // .repository' "coordination/worker-specs/active/$SPEC_FILE")
CVE_ID=$(jq -r '.scope.cve_id // empty' "coordination/worker-specs/active/$SPEC_FILE")

# Navigate
cd ~/"$REPO"
git checkout main && git pull
```

### 2. Dependency Scan (3-5min)
```bash
# Run appropriate scanner
if [ -f "package.json" ]; then
  npm audit --json > reports/npm-audit.json
  npm outdated --json > reports/npm-outdated.json
elif [ -f "requirements.txt" ] || [ -f "pyproject.toml" ]; then
  pip-audit --format json > reports/pip-audit.json
  bandit -r src/ -f json -o reports/bandit.json
elif [ -f "Cargo.toml" ]; then
  cargo audit --json > reports/cargo-audit.json
fi
```

### 3. Secret Scan (2-3min)
```bash
# Gitleaks for secrets
if command -v gitleaks &> /dev/null; then
  gitleaks detect --report-path=reports/gitleaks.json --report-format=json
fi

# Git-secrets
if command -v git-secrets &> /dev/null; then
  git-secrets --scan --recursive || true
fi
```

### 4. SAST Scan (3-5min)
```bash
# Semgrep if available
if command -v semgrep &> /dev/null; then
  semgrep --config=auto --json --output=reports/semgrep.json --metrics=off
fi

# Language-specific
if [ -f "package.json" ]; then
  npx eslint src/ --plugin security --format json > reports/eslint-security.json || true
fi
```

### 5. Analyze Results (2-3min)
```bash
# Parse and categorize findings
jq '{
  critical: [.vulnerabilities[] | select(.severity == "critical")],
  high: [.vulnerabilities[] | select(.severity == "high")],
  medium: [.vulnerabilities[] | select(.severity == "medium")],
  low: [.vulnerabilities[] | select(.severity == "low")],
  info: [.vulnerabilities[] | select(.severity == "info")]
}' reports/npm-audit.json > reports/categorized-findings.json

# Count by severity
jq '{
  critical_count: ([.vulnerabilities[] | select(.severity == "critical")] | length),
  high_count: ([.vulnerabilities[] | select(.severity == "high")] | length),
  medium_count: ([.vulnerabilities[] | select(.severity == "medium")] | length),
  total: (.vulnerabilities | length)
}' reports/npm-audit.json
```

### 6. Generate Report (2min)
```bash
# Create structured report
cat > reports/scan-report-$TASK_ID.json <<EOF
{
  "scan_id": "scan-$(date +%s)",
  "task_id": "$TASK_ID",
  "repository": "$REPO",
  "scan_date": "$(date -Iseconds)",
  "scanners_used": ["npm-audit", "gitleaks", "semgrep"],
  "findings": {
    "critical": $(jq '.critical | length' reports/categorized-findings.json),
    "high": $(jq '.high | length' reports/categorized-findings.json),
    "medium": $(jq '.medium | length' reports/categorized-findings.json),
    "low": $(jq '.low | length' reports/categorized-findings.json)
  },
  "details": $(cat reports/categorized-findings.json)
}
EOF
```

---

## Report Format

### JSON Report

```json
{
  "scan_id": "scan-1234567890",
  "task_id": "task-500",
  "repository": "ry-ops/api-server",
  "scan_date": "2025-11-26T10:00:00-06:00",
  "scanners": {
    "dependency": "npm-audit@9.0.0",
    "secrets": "gitleaks@8.18.0",
    "sast": "semgrep@1.45.0"
  },
  "findings": {
    "critical": 2,
    "high": 5,
    "medium": 12,
    "low": 8,
    "info": 3,
    "total": 30
  },
  "vulnerabilities": [
    {
      "id": "CVE-2024-12345",
      "severity": "critical",
      "package": "lodash",
      "installed_version": "4.17.19",
      "patched_version": "4.17.21",
      "description": "Prototype pollution vulnerability",
      "remediation": "npm install lodash@4.17.21",
      "references": [
        "https://nvd.nist.gov/vuln/detail/CVE-2024-12345"
      ]
    }
  ],
  "secrets_found": {
    "count": 1,
    "findings": [
      {
        "file": "config/database.js",
        "line": 42,
        "type": "AWS Access Key",
        "secret": "AKIA****************",
        "remediation": "Move to environment variable"
      }
    ]
  },
  "sast_issues": {
    "count": 8,
    "findings": [
      {
        "rule_id": "javascript.express.security.audit.xss.direct-response-write",
        "severity": "high",
        "file": "src/api/user.js",
        "line": 85,
        "message": "Potential XSS via direct response.write()",
        "remediation": "Use template engine or sanitize user input"
      }
    ]
  },
  "summary": {
    "status": "vulnerabilities_found",
    "requires_immediate_action": true,
    "critical_or_high_count": 7,
    "estimated_fix_time_hours": 4
  }
}
```

### Markdown Summary

```markdown
# Security Scan Report

**Repository**: ry-ops/api-server
**Scan Date**: 2025-11-26T10:00:00-06:00
**Task ID**: task-500

## Summary

🚨 **Status**: Critical vulnerabilities found - immediate action required

| Severity | Count |
|----------|-------|
| Critical | 2 |
| High | 5 |
| Medium | 12 |
| Low | 8 |
| Info | 3 |
| **Total** | **30** |

## Critical Vulnerabilities (Immediate Action)

### CVE-2024-12345: Prototype Pollution in lodash
- **Package**: lodash@4.17.19
- **Severity**: Critical (CVSS: 9.8)
- **Fix**: `npm install lodash@4.17.21`
- **Impact**: Remote code execution possible
- **Reference**: https://nvd.nist.gov/vuln/detail/CVE-2024-12345

### CVE-2024-67890: SQL Injection in pg
- **Package**: pg@8.5.0
- **Severity**: Critical (CVSS: 9.1)
- **Fix**: `npm install pg@8.11.0`
- **Impact**: Database breach possible
- **Reference**: https://nvd.nist.gov/vuln/detail/CVE-2024-67890

## High Vulnerabilities

### 1. XSS in express-validator
- **Package**: express-validator@6.10.0
- **Fix**: `npm install express-validator@7.0.0`

### 2. Path Traversal in serve-static
- **Package**: serve-static@1.14.1
- **Fix**: `npm install serve-static@1.15.0`

[... 3 more high severity ...]

## Secrets Found

🔑 **AWS Access Key** detected in `config/database.js:42`
- **Action**: Move to environment variable immediately
- **Revoke**: Rotate compromised key in AWS IAM
- **Fix**: Use `process.env.AWS_ACCESS_KEY_ID`

## SAST Findings

### XSS Vulnerability (src/api/user.js:85)
```javascript
// Vulnerable code
res.write(req.query.name);  // Direct user input to response

// Fix
const sanitized = validator.escape(req.query.name);
res.write(sanitized);
```

## Remediation Steps

### Immediate (within 24 hours)
1. Upgrade lodash: `npm install lodash@4.17.21`
2. Upgrade pg: `npm install pg@8.11.0`
3. Revoke and rotate AWS access key
4. Deploy fix to production

### Short-term (within 1 week)
1. Upgrade express-validator and serve-static
2. Fix XSS vulnerability in user.js
3. Run tests after upgrades
4. Update CI/CD to include security scanning

### Long-term
1. Enable Dependabot/Renovate for automatic updates
2. Add pre-commit hooks for secret scanning
3. Integrate semgrep into CI pipeline
4. Schedule quarterly security audits

## Scan Details

**Scanners Used**:
- npm audit v9.0.0 (dependency vulnerabilities)
- gitleaks v8.18.0 (secret detection)
- semgrep v1.45.0 (static analysis)

**Scan Duration**: 12 minutes
**Files Scanned**: 458 files
**Dependencies Checked**: 342 packages
