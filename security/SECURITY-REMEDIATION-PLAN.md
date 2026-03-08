# Security Vulnerability Remediation Plan

**Date:** November 25, 2025
**Orchestrated By:** commit-relay security-master + development-master (MoE routing)

---

## Overview

This document tracks the remediation of security vulnerabilities discovered across the ry-ops repository portfolio.

## Critical Fixes Required

### 1. commit-relay - Path Traversal Vulnerabilities (HIGH)

**Status:** 🟡 In Progress
**Priority:** CRITICAL
**CVE:** CWE-23 (Path Traversal)

#### Affected Files:
1. ✅ `api-server/server/index.js:5223` - **FIXED**
2. ⏳ `api-server/server/routes/security.js:44`
3. ⏳ `api-server/server/routes/traces.js:26,58,68`
4. ⏳ `api-server/server/routes/user-management.js:62`
5. ⏳ `api-server/server/routes/workflows.js:74,128,259,294`

####Fix Strategy:
- ✅ Created `lib/path-validator.js` utility module
- ✅ Added path validation to `/api/logs/tail` endpoint
- ⏳ Apply same pattern to remaining 9 vulnerable endpoints

---

### 2. commit-relay - Python Dependency Upgrades (HIGH/MEDIUM)

**Status:** ⏳ Pending
**Priority:** HIGH

#### Critical Upgrades:
| Package | Current | Target | Severity | CVEs |
|---------|---------|--------|----------|------|
| pillow | 9.5.0 | 10.2.0 | CRITICAL | CVE-2023-4863, CVE-2023-50447 |
| setuptools | 40.5.0 | 78.1.1 | HIGH | CVE-2024-6345, CVE-2025-47273 |
| jupyter-server | 1.24.0 | 2.14.1 | HIGH | CVE-2024-35178 |
| anyio | 3.7.1 | 4.4.0 | HIGH | Race Condition |
| fonttools | 4.38.0 | 4.43.0 | HIGH | CVE-2023-45139 (XXE) |

#### Medium Priority:
| Package | Current | Target | CVEs |
|---------|---------|--------|------|
| tornado | 6.2 | 6.4.1 | 7 vulnerabilities |
| requests | 2.31.0 | 2.32.4 | CVE-2024-35195, CVE-2024-47081 |
| urllib3 | 2.0.7 | 2.5.0 | CVE-2024-37891, CVE-2025-50181 |
| zipp | 3.15.0 | 3.19.1 | CVE-2024-5569 |
| jupyter-core | 4.12.0 | 5.8.0 | CVE-2025-30167 |

**Fix Command:**
```bash
# Upgrade all dependencies
pip install --upgrade pillow==10.2.0 setuptools==78.1.1 tornado==6.4.1 \
  anyio==4.4.0 requests==2.32.4 jupyter-server==2.14.1 fonttools==4.43.0 \
  urllib3==2.5.0 zipp==3.19.1 jupyter-core==5.8.0

# Update requirements.txt
pip freeze > requirements.txt
```

---

### 3. MCP Servers - Hardcoded Test Secrets (MEDIUM)

**Status:** ⏳ Pending
**Priority:** MEDIUM

#### Affected Repositories:
1. ry-ops/netdata-mcp-server (`tests/test_server.py`)
2. ry-ops/pulseway-rmm-a2a-mcp-server (`tests/test_server.py`)
3. ry-ops/grafana-a2a-mcp-server (`tests/test_server.py`)
4. ry-ops/talos-a2a-mcp-server (`tests/test_server.py`)

#### Issue:
```python
# Current (hardcoded):
client = NetdataClient(base_url="http://test:19999", api_key="test-key")

# Should be:
client = NetdataClient(base_url=os.getenv("TEST_BASE_URL"), api_key=os.getenv("TEST_API_KEY"))
```

#### Fix Strategy:
1. Create `.env.test` file with test credentials
2. Update test files to use environment variables
3. Add `.env.test.example` to repository
4. Update `.gitignore` to exclude `.env.test`

---

### 4. Docker Base Image Vulnerabilities (LOW)

**Status:** ⏳ Pending
**Priority:** LOW (Debian marks as "Unimportant")

#### Affected:
- ry-ops/talos-a2a-mcp-server
- ry-ops/resumate

#### Issues:
- tar CVE-2005-2541 (CVSS 9.8 - Low/Unimportant)
- glibc CVE-2019-1010022 (CVSS 9.8 - Low/Unimportant)

**Note:** Both vulnerabilities rated as "Unimportant" by Debian security team.
No remediation path available. These are old CVEs in base system packages
that are not exploitable in container context.

**Action:** Document and accept risk (false positives in Snyk).

---

## Proactive Security Enhancements

### 5. Dependabot Configuration

**Status:** ⏳ Pending
**Priority:** MEDIUM

Create `.github/dependabot.yml` for all 18 repositories:

```yaml
version: 2
updates:
  # Node.js dependencies
  - package-ecosystem: "npm"
    directory: "/"
    schedule:
      interval: "weekly"
    open-pull-requests-limit: 10

  # Python dependencies
  - package-ecosystem: "pip"
    directory: "/"
    schedule:
      interval: "weekly"
    open-pull-requests-limit: 10
```

---

### 6. CI/CD Security Scanning

**Status:** ⏳ Pending
**Priority:** MEDIUM

Add to `.github/workflows/security.yml`:

```yaml
name: Security Scan

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]
  schedule:
    - cron: '0 0 * * 0'  # Weekly

jobs:
  security:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Run npm audit
        if: hashFiles('package.json') != ''
        run: npm audit --audit-level=moderate
        continue-on-error: true

      - name: Run pip-audit
        if: hashFiles('requirements.txt') != '' || hashFiles('pyproject.toml') != ''
        run: |
          pip install pip-audit
          pip-audit
        continue-on-error: true
```

---

### 7. SECURITY.md Files

**Status:** ⏳ Pending
**Priority:** MEDIUM

Template for all repositories:

```markdown
# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| latest  | :white_check_mark: |

## Reporting a Vulnerability

Please report security vulnerabilities to:
- Email: [security contact]
- GitHub Security Advisories: [repo]/security/advisories/new

Expected response time: 48 hours
```

---

### 8. Quarterly Dependency Review Schedule

**Status:** ⏳ Pending
**Priority:** LOW

**Schedule:**
- Q1 2026: February 1
- Q2 2026: May 1
- Q3 2026: August 1
- Q4 2026: November 1

**Review Process:**
1. Run `npm audit` / `pip-audit` on all repositories
2. Review Dependabot PRs
3. Update all dependencies to latest stable versions
4. Test thoroughly
5. Deploy updates

---

## Implementation Progress

### Phase 1: Critical Fixes (Week 1)
- [x] Create path validation utility
- [x] Fix 1/10 Path Traversal vulnerabilities
- [ ] Fix remaining 9 Path Traversal vulnerabilities
- [ ] Upgrade Python dependencies
- [ ] Test all fixes
- [ ] Create PR and merge

### Phase 2: Test Security (Week 1)
- [ ] Fix hardcoded secrets in 4 MCP server test suites
- [ ] Create `.env.test` templates
- [ ] Update documentation

### Phase 3: Automation (Week 2)
- [ ] Enable Dependabot on all 18 repositories
- [ ] Add security scanning to CI/CD pipelines
- [ ] Add SECURITY.md files

### Phase 4: Documentation (Week 2)
- [ ] Create quarterly review schedule
- [ ] Document security best practices
- [ ] Update README files with security badges

---

## Pull Requests

### Created:
- None yet

### Planned:
1. `fix/path-traversal-vulnerabilities` - Fix all Path Traversal issues
2. `fix/upgrade-python-dependencies` - Upgrade vulnerable Python packages
3. `fix/remove-hardcoded-test-secrets` - Use environment variables in tests
4. `feat/add-dependabot` - Enable automated dependency updates
5. `feat/add-security-scanning` - Add CI/CD security workflows
6. `feat/add-security-policy` - Add SECURITY.md to all repos

---

## Risk Assessment

| Issue | Severity | Exploitability | Impact | Risk Score |
|-------|----------|----------------|--------|------------|
| Path Traversal | HIGH | Medium | High | 🔴 8/10 |
| Pillow CVE-2023-4863 | CRITICAL | High | Critical | 🔴 9/10 |
| Setuptools CVE-2024-6345 | HIGH | Low | High | 🟡 7/10 |
| Test Secrets | MEDIUM | Low | Low | 🟢 4/10 |
| Docker CVEs | LOW | None | None | 🟢 1/10 |

---

**Last Updated:** 2025-11-25 19:30:00 CST
**Next Review:** 2025-11-26 (Daily until critical fixes complete)
