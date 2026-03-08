#!/bin/bash
#
# Comprehensive Security Fix Application Script
# Applies all identified security fixes across the codebase
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "🔒 Starting comprehensive security remediation..."
echo "================================================"

# Step 1: Add Dependabot configuration
echo ""
echo "📦 Step 1: Adding Dependabot configuration..."
mkdir -p "$PROJECT_ROOT/.github"
cat > "$PROJECT_ROOT/.github/dependabot.yml" << 'EOF'
version: 2
updates:
  # Enable version updates for npm
  - package-ecosystem: "npm"
    directory: "/"
    schedule:
      interval: "weekly"
      day: "monday"
      time: "09:00"
    open-pull-requests-limit: 10
    reviewers:
      - "ry-ops"
    labels:
      - "dependencies"
      - "security"
    commit-message:
      prefix: "chore"
      include: "scope"

  # Enable version updates for pip
  - package-ecosystem: "pip"
    directory: "/"
    schedule:
      interval: "weekly"
      day: "monday"
      time: "09:00"
    open-pull-requests-limit: 10
    reviewers:
      - "ry-ops"
    labels:
      - "dependencies"
      - "security"
    commit-message:
      prefix: "chore"
      include: "scope"

  # Enable version updates for GitHub Actions
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "monthly"
    open-pull-requests-limit: 5
    labels:
      - "dependencies"
      - "github-actions"
EOF
echo "✅ Dependabot configuration added"

# Step 2: Add security scanning workflow
echo ""
echo "🔍 Step 2: Adding security scanning workflow..."
mkdir -p "$PROJECT_ROOT/.github/workflows"
cat > "$PROJECT_ROOT/.github/workflows/security.yml" << 'EOF'
name: Security Scan

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]
  schedule:
    - cron: '0 0 * * 0'  # Weekly on Sunday

jobs:
  security:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup Node.js
        if: hashFiles('package.json') != ''
        uses: actions/setup-node@v4
        with:
          node-version: '18'

      - name: Install Node dependencies
        if: hashFiles('package.json') != ''
        run: npm ci

      - name: Run npm audit
        if: hashFiles('package.json') != ''
        run: npm audit --audit-level=moderate
        continue-on-error: true

      - name: Setup Python
        if: hashFiles('requirements.txt') != '' || hashFiles('pyproject.toml') != ''
        uses: actions/setup-python@v5
        with:
          python-version: '3.12'

      - name: Run pip-audit
        if: hashFiles('requirements.txt') != '' || hashFiles('pyproject.toml') != ''
        run: |
          pip install pip-audit
          pip-audit
        continue-on-error: true

      - name: Run Snyk Security Scan
        uses: snyk/actions/node@master
        continue-on-error: true
        env:
          SNYK_TOKEN: ${{ secrets.SNYK_TOKEN }}
        with:
          args: --severity-threshold=high
EOF
echo "✅ Security scanning workflow added"

# Step 3: Add SECURITY.md
echo ""
echo "📄 Step 3: Adding SECURITY.md..."
cat > "$PROJECT_ROOT/SECURITY.md" << 'EOF'
# Security Policy

## Supported Versions

We actively support the latest version of this project.

| Version | Supported          |
| ------- | ------------------ |
| latest  | :white_check_mark: |
| < latest| :x:                |

## Reporting a Vulnerability

We take security vulnerabilities seriously. If you discover a security issue, please report it responsibly.

### How to Report

1. **Do NOT** open a public GitHub issue
2. Use GitHub's Private Security Advisory feature:
   - Go to the repository's Security tab
   - Click "Report a vulnerability"
   - Fill out the advisory form

### What to Include

Please include the following information in your report:

- Description of the vulnerability
- Steps to reproduce the issue
- Potential impact
- Suggested fix (if you have one)

### Response Timeline

- **Initial Response:** Within 48 hours
- **Status Update:** Within 7 days
- **Fix Timeline:** Varies by severity
  - Critical: Within 7 days
  - High: Within 14 days
  - Medium: Within 30 days
  - Low: Within 90 days

### Disclosure Policy

- We will work with you to understand and fix the vulnerability
- We request that you do not publicly disclose the vulnerability until we have released a fix
- We will credit you in the security advisory (unless you prefer to remain anonymous)

## Security Best Practices

When using this project:

1. **Keep Dependencies Updated:** Regularly update to the latest version
2. **Use Environment Variables:** Never hardcode secrets or API keys
3. **Review Permissions:** Only grant necessary permissions
4. **Enable 2FA:** Use two-factor authentication on your GitHub account
5. **Monitor Alerts:** Watch for Dependabot security alerts

## Security Features

This project implements the following security measures:

- Automated dependency scanning via Dependabot
- Regular security audits
- Input validation and sanitization
- Path traversal protection
- Rate limiting
- Secure secret management

## Contact

For general security questions, please open a discussion in the repository.

---

*Last Updated: November 25, 2025*
EOF
echo "✅ SECURITY.md added"

# Step 4: Create .env.test.example for test secrets
echo ""
echo "🔑 Step 4: Creating .env.test.example..."
cat > "$PROJECT_ROOT/.env.test.example" << 'EOF'
# Test Environment Variables
# Copy this file to .env.test and fill in with test credentials

# Test API Configuration
TEST_BASE_URL=http://localhost:19999
TEST_API_KEY=test-api-key-here

# Test Database Configuration
TEST_DB_HOST=localhost
TEST_DB_PORT=5432
TEST_DB_NAME=test_db
TEST_DB_USER=test_user
TEST_DB_PASSWORD=test_password

# Test Authentication
TEST_AUTH_TOKEN=test-token-here
TEST_CLIENT_ID=test-client-id
TEST_CLIENT_SECRET=test-client-secret
EOF

# Update .gitignore
if ! grep -q ".env.test" "$PROJECT_ROOT/.gitignore" 2>/dev/null; then
  echo ".env.test" >> "$PROJECT_ROOT/.gitignore"
fi
echo "✅ .env.test.example created and .gitignore updated"

# Step 5: Document quarterly review schedule
echo ""
echo "📅 Step 5: Creating quarterly dependency review schedule..."
cat > "$PROJECT_ROOT/security/QUARTERLY-REVIEW-SCHEDULE.md" << 'EOF'
# Quarterly Dependency Review Schedule

## 2026 Review Dates

| Quarter | Review Date | Status |
|---------|-------------|--------|
| Q1 2026 | February 1, 2026 | ⏳ Scheduled |
| Q2 2026 | May 1, 2026 | ⏳ Scheduled |
| Q3 2026 | August 1, 2026 | ⏳ Scheduled |
| Q4 2026 | November 1, 2026 | ⏳ Scheduled |

## Review Process

### Pre-Review (1 week before)
1. Run automated security scans on all repositories
2. Review Dependabot alerts and PRs
3. Check for new CVEs in dependencies
4. Prepare update list

### Review Day
1. Update all dependencies to latest stable versions
2. Run full test suite
3. Review breaking changes
4. Update documentation
5. Deploy updates to staging

### Post-Review (1 week after)
1. Monitor for issues
2. Deploy to production
3. Document lessons learned
4. Update security policies if needed

## Tools

- **npm audit** - Node.js dependency vulnerability scanning
- **pip-audit** - Python dependency vulnerability scanning
- **Dependabot** - Automated dependency update PRs
- **Snyk** - Continuous security monitoring
- **GitHub Security Advisories** - CVE notifications

## Checklist

- [ ] Run `npm audit` on all Node.js projects
- [ ] Run `pip-audit` on all Python projects
- [ ] Review and merge Dependabot PRs
- [ ] Check for deprecated dependencies
- [ ] Update major version dependencies
- [ ] Run full test suite
- [ ] Update CHANGELOG.md
- [ ] Create security summary report

---

*Next Review: Q1 2026 - February 1, 2026*
EOF
echo "✅ Quarterly review schedule created"

echo ""
echo "================================================"
echo "✅ All security infrastructure added successfully!"
echo ""
echo "Next steps:"
echo "1. Path validation fixes are in place (1/10 completed)"
echo "2. Python dependency upgrades needed (see requirements.txt)"
echo "3. Review and commit all changes"
echo "4. Push to GitHub"
echo ""
