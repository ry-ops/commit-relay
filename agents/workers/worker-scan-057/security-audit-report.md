# Security Audit Report

**Task ID:** moe-test-ddqd-v5-1763690307-f45f4c85
**Worker ID:** worker-scan-057
**Audit Date:** 2025-11-20
**Scope:** commit-relay production systems

---

## 1. Executive Summary

This security audit identified **2 CRITICAL**, **4 HIGH**, **3 MEDIUM**, and **5 LOW** priority security issues across the commit-relay codebase. The most severe findings involve exposed API keys in committed files and insecure command execution patterns.

### Overall Security Posture: **NEEDS IMMEDIATE ATTENTION**

The codebase has good security practices in many areas (rate limiting, helmet headers, input validation framework), but critical credential exposures require immediate remediation.

---

## 2. Critical Issues (CVSS >= 9.0)

### CRITICAL-001: Exposed Anthropic API Key in Configuration File
**Severity:** CRITICAL (CVSS 9.8)
**Location:** `/Users/ryandahlberg/Projects/commit-relay/.claude/settings.local.json` (lines 45-46)
**Location:** `/Users/ryandahlberg/Projects/commit-relay/llm-mesh/.env` (line 8)

**Description:**
Hardcoded Anthropic API key exposed in committed files:
```
[REDACTED]
```

**Risk:**
- Unauthorized API usage leading to financial loss
- Potential data exfiltration through API calls
- Key may be compromised if repository is public or accessed by unauthorized parties

**Remediation:**
1. **IMMEDIATE**: Rotate the exposed API key via Anthropic Console
2. Remove hardcoded key from settings.local.json
3. Remove hardcoded key from llm-mesh/.env
4. Add `llm-mesh/.env` to .gitignore (currently only `.env` and `.env.local` are ignored)
5. Ensure `.claude/settings.local.json` is not committed (add to .gitignore)
6. Use environment variables or a secrets manager

---

### CRITICAL-002: Insecure Command Execution with User Input
**Severity:** CRITICAL (CVSS 9.1)
**Location:** `/Users/ryandahlberg/Projects/commit-relay/dashboard/server/index.js`

**Vulnerable Code Patterns:**
- Line 2643: `execSync(\`${eventScript} task_created ${taskId} "Repair task created from health alert ${alert.id}"\``
- Line 2655-2656: `const routeCmd = \`TASK_DESC="${taskDesc}" ${moeRouter} "${taskId}" "${taskDesc}"\``

**Description:**
Alert messages and task descriptions are interpolated directly into shell commands without proper sanitization. The `taskDesc` includes `alert.message` which could be crafted to inject shell commands.

**Risk:**
- Remote code execution through crafted alert messages
- Complete system compromise

**Remediation:**
1. Use the existing `safeExec()` utility from `/dashboard/server/utils/security.js` instead of `execSync()`
2. Pass all user-derived data as separate arguments to spawn(), not in command strings
3. Implement strict input validation for alert messages

---

## 3. High Priority Issues (CVSS 7.0-8.9)

### HIGH-001: Development Mode Bypasses Authentication
**Severity:** HIGH (CVSS 7.5)
**Location:** `/Users/ryandahlberg/Projects/commit-relay/dashboard/server/middleware/auth.js` (lines 20-23)

**Description:**
In development mode without API_KEY set, all authentication is bypassed with only a console warning:
```javascript
if (!expectedKey && process.env.NODE_ENV === 'development') {
    console.warn('WARNING: No API_KEY set. API is unprotected!');
    return next();
}
```

**Risk:**
- If production system accidentally runs in development mode, all APIs are exposed
- Any system state change can occur without authentication

**Remediation:**
1. Remove development bypass or make it opt-in with explicit flag
2. Never allow unauthenticated access even in development
3. Use different authentication methods for dev (e.g., local token file)

---

### HIGH-002: Excessive execSync Usage Without Shell Safety
**Severity:** HIGH (CVSS 7.2)
**Location:** Multiple locations in `/Users/ryandahlberg/Projects/commit-relay/dashboard/server/index.js`

**Count:** 40+ instances of `execSync()` calls

**Description:**
Many endpoints use `execSync()` with string interpolation for process names, though process names are hardcoded. However, some patterns like:
- Line 1827: `pgrep -f "${processName}"`
- Line 4075: `ls ${handsoffsPattern} 2>/dev/null`

While processName values are currently hardcoded, this pattern is risky if expanded.

**Remediation:**
1. Migrate all execSync calls to use the `safeExec()` utility
2. Use spawn() with explicit argument arrays
3. Avoid shell=true whenever possible

---

### HIGH-003: Missing Rate Limiting on Service Control Endpoints
**Severity:** HIGH (CVSS 7.1)
**Location:** `/Users/ryandahlberg/Projects/commit-relay/dashboard/server/middleware/rateLimiter.js` (lines 17-34)

**Description:**
The `controlLimiter` for service management has been intentionally disabled:
```javascript
const controlLimiter = rateLimit({
    // ...
    skip: (req) => {
        // Always skip - services must NEVER be throttled by their own API
        return true;
    },
});
```

**Risk:**
- Denial of service through rapid service restart requests
- Resource exhaustion attacks
- Abuse of daemon control endpoints

**Remediation:**
1. Implement reasonable rate limits even for service control (e.g., 10 requests per minute)
2. Add IP-based rate limiting for unauthenticated health checks
3. Consider separate rate limits for start/stop vs. status operations

---

### HIGH-004: .env Files Not Fully Gitignored
**Severity:** HIGH (CVSS 7.0)
**Location:** `/Users/ryandahlberg/Projects/commit-relay/.gitignore`

**Description:**
The .gitignore only ignores `.env` and `.env.local`, but:
- `dashboard/.env` and `llm-mesh/.env` exist (potentially committed)
- `.env.example` files contain placeholder secrets that could be committed

**Observed .env files:**
- `/dashboard/.env` (properly configured)
- `/dashboard/.env.example`
- `/llm-mesh/.env` (CONTAINS REAL API KEY)
- `/llm-mesh/.env.example`

**Remediation:**
1. Update .gitignore to: `**/.env*` with `!**/.env.example`
2. Remove real secrets from any .env files in git history
3. Use git filter-branch or BFG to clean history

---

## 4. Medium Priority Issues (CVSS 4.0-6.9)

### MEDIUM-001: Permissive CORS Configuration in Tests
**Severity:** MEDIUM (CVSS 5.3)
**Location:** `/Users/ryandahlberg/Projects/commit-relay/testing/dashboard/server.test.js` (line 28)

**Description:**
Test file sets `Access-Control-Allow-Origin: *` which could leak into production if test configs are reused.

**Remediation:**
1. Ensure test CORS configs are isolated from production
2. Production CORS is correctly configured in dashboard server with specific origins

---

### MEDIUM-002: Incomplete Input Validation on Query Parameters
**Severity:** MEDIUM (CVSS 5.3)
**Location:** Multiple endpoints in `/dashboard/server/index.js`

**Description:**
Many query parameters are used without validation:
- Line 675: `req.query.period || 'all_time'`
- Line 1232-1235: `parseInt(req.query.limit)`, `req.query.since`
- Line 4550: `req.query.file || 'dashboard-events'`

While some have defaults, no explicit type checking or sanitization occurs.

**Remediation:**
1. Add express-validator rules for all query parameters
2. Implement allowlists for string parameters (like file names)
3. Use the existing validation middleware consistently

---

### MEDIUM-003: No HTTPS Enforcement
**Severity:** MEDIUM (CVSS 4.3)
**Location:** Dashboard server configuration

**Description:**
No HTTPS redirect or HSTS enforcement detected. Server runs on HTTP by default.

**Remediation:**
1. Add HTTPS redirect middleware for production
2. Configure Helmet HSTS settings
3. Use SSL termination at load balancer

---

## 5. Low Priority Issues

### LOW-001: Console Logging in Production Code
**Severity:** LOW (CVSS 3.1)
**Description:** Extensive console.log/warn/error usage may leak information.
**Remediation:** Implement structured logging with log levels.

### LOW-002: Missing Content-Security-Policy Configuration
**Severity:** LOW (CVSS 3.1)
**Description:** Helmet is configured but CSP is not explicitly set.
**Remediation:** Add explicit CSP headers appropriate for dashboard.

### LOW-003: No Request ID Tracking
**Severity:** LOW (CVSS 2.6)
**Description:** No correlation ID for request tracing.
**Remediation:** Add request ID middleware for debugging and audit trails.

### LOW-004: Dependencies Could Be More Current
**Severity:** LOW (CVSS 2.4)
**Description:** While no vulnerabilities found, some packages could be updated.
**Remediation:** Regular dependency updates (monthly review).

### LOW-005: Error Messages May Leak Internal Paths
**Severity:** LOW (CVSS 2.4)
**Description:** Some error handlers return full error messages including file paths.
**Remediation:** Use the `sanitizeError()` utility consistently in production.

---

## 6. Compliance Status

### Security Controls Assessment

| Control | Status | Notes |
|---------|--------|-------|
| Authentication | PARTIAL | Good timing-safe comparison, but dev bypass exists |
| Authorization | MISSING | No role-based access control implemented |
| Input Validation | PARTIAL | Framework exists but inconsistently applied |
| Rate Limiting | PARTIAL | Configured but disabled for critical endpoints |
| Security Headers | GOOD | Helmet properly configured |
| CORS | GOOD | Properly restricted in production config |
| Encryption | NEEDS WORK | No HTTPS enforcement |
| Secrets Management | CRITICAL | Hardcoded secrets in committed files |
| Dependency Security | GOOD | No known vulnerabilities (npm audit clean) |
| Error Handling | GOOD | Proper error sanitization utilities exist |

### npm audit Results

**Root package:** 0 vulnerabilities (311 dependencies)
**Dashboard package:** 0 vulnerabilities (109 dependencies)

---

## 7. Recommendations

### Immediate Actions (24-48 hours)

1. **ROTATE THE EXPOSED API KEY IMMEDIATELY**
   - Go to Anthropic Console
   - Generate new API key
   - Update all legitimate uses
   - Delete old key

2. **Remove hardcoded secrets from:**
   - `.claude/settings.local.json`
   - `llm-mesh/.env`
   - Add these paths to .gitignore

3. **Audit git history** for any previously committed secrets using:
   ```bash
   git log --all --full-history -- "**/.env*"
   git log --all --full-history -S "sk-ant-api"
   ```

### Short-term Actions (1-2 weeks)

4. **Replace execSync with safeExec** in all dashboard server endpoints
5. **Remove development authentication bypass** or add explicit opt-in flag
6. **Implement rate limiting** on service control endpoints
7. **Add input validation** for all query parameters

### Medium-term Actions (1 month)

8. **Implement role-based access control** for different API operations
9. **Add HTTPS enforcement** and HSTS headers
10. **Implement structured logging** with proper log levels
11. **Add request correlation IDs** for audit trails

### Long-term Improvements

12. **Secret scanning in CI/CD** (use gitleaks, trufflehog, or similar)
13. **Regular penetration testing** schedule
14. **Security documentation** and runbooks
15. **Incident response procedures** for credential exposure

---

## 8. Summary of Findings

| Severity | Count | Status |
|----------|-------|--------|
| CRITICAL | 2 | Requires immediate attention |
| HIGH | 4 | Address within 1 week |
| MEDIUM | 3 | Address within 1 month |
| LOW | 5 | Address as part of regular maintenance |
| **TOTAL** | **14** | |

### Key Metrics

- **Time to Remediate Critical Issues:** <4 hours recommended
- **Estimated Effort:** 8-16 developer hours for critical/high issues
- **Re-audit Recommended:** After critical issues resolved

---

## Appendix A: Files Reviewed

- `/dashboard/server/index.js` - Main server (6000+ lines)
- `/dashboard/server/middleware/auth.js` - Authentication
- `/dashboard/server/middleware/validators.js` - Input validation
- `/dashboard/server/middleware/rateLimiter.js` - Rate limiting
- `/dashboard/server/utils/security.js` - Security utilities
- `/dashboard/server/routes/users.js` - User management
- `/dashboard/package.json` - Dependencies
- `/package.json` - Root dependencies
- `/.gitignore` - Git ignore rules
- `/.env` files - Environment configuration
- `/.claude/settings.local.json` - Claude settings

---

## Appendix B: Tools Used

- Static analysis: Pattern matching with grep
- Dependency scanning: npm audit
- Configuration review: Manual inspection
- Code review: Manual inspection of authentication, authorization, and input handling

---

**Report Generated:** 2025-11-20T20:XX:XX-0600
**Auditor:** Security Scan Worker (worker-scan-057)
**Next Audit Due:** 2025-12-20
