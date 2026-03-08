# Achievement Automation Security Best Practices

## Token Management

### GitHub Personal Access Token

**Required Scopes**:
- `repo` - Full repository access
- `workflow` - GitHub Actions workflow management  
- `read:org` - Organization membership visibility

**Security Measures**:
```bash
# Never commit tokens to repository
echo "GITHUB_TOKEN=ghp_****" >> .env
git add .env  # ❌ NEVER DO THIS

# Use environment variables
export GITHUB_TOKEN="ghp_****"

# Or GitHub Secrets for Actions
# Settings → Secrets and variables → Actions → New repository secret
```

### Token Rotation Policy

**Recommended Schedule**:
- Development tokens: Rotate every 90 days
- Production tokens: Rotate every 30 days
- Compromised tokens: Revoke immediately

**Rotation Workflow**:
1. Generate new token in GitHub Settings
2. Update environment variables
3. Test all API integrations
4. Revoke old token after 24-hour grace period

## API Rate Limiting

### GitHub API Limits

**Authenticated Requests**: 5,000 requests/hour
**Search API**: 30 requests/minute

**Implementation**:
```javascript
class RateLimiter {
  constructor() {
    this.requestCount = 0;
    this.resetTime = Date.now() + 3600000;
  }
  
  async checkLimit(response) {
    const remaining = response.headers.get('x-ratelimit-remaining');
    if (remaining < 100) {
      console.warn(`⚠️  Rate limit: ${remaining} requests remaining`);
      await this.backoff();
    }
  }
  
  async backoff() {
    const delay = Math.min(60000, 1000 * Math.pow(2, this.retryCount));
    await new Promise(resolve => setTimeout(resolve, delay));
  }
}
```

## Auto-Merge Security

### YOLO Mode Safeguards

**Branch Protection Rules**:
```yaml
# .github/branch-protection.yml
main:
  required_status_checks:
    strict: true
    contexts: []  # Allow YOLO merges for achievements
  
  required_pull_request_reviews:
    required_approving_review_count: 0  # Disable for automation
```

**Pre-merge Validation**:
```bash
#!/usr/bin/env bash
# Check before auto-merge
if [[ "$BRANCH_NAME" =~ ^feat/achievement- ]]; then
  # Achievement branches - allow YOLO
  echo "✅ Achievement automation - YOLO mode enabled"
else
  # Regular branches - require review
  echo "❌ Non-achievement branch - manual review required"
  exit 1
fi
```

## Worker Spawn Security

### Access Control

**Governance Integration**:
```bash
# Check permissions before spawning
if ! node lib/governance/access-control.js check \
  --actor "achievement-master" \
  --action "spawn_worker" \
  --resource "scan-worker"; then
  echo "❌ Access denied"
  exit 1
fi
```

**Resource Limits**:
```json
{
  "achievement-master": {
    "max_concurrent_workers": 5,
    "max_workers_per_hour": 20,
    "allowed_worker_types": [
      "implementation-worker",
      "scan-worker"
    ]
  }
}
```

## Monitoring and Alerts

### Security Event Logging

**Log All Automation Events**:
```javascript
const logSecurityEvent = (event) => {
  const entry = {
    timestamp: new Date().toISOString(),
    actor: 'achievement-master',
    action: event.action,
    resource: event.resource,
    success: event.success,
    metadata: {
      achievement: event.achievement,
      workflow: event.workflow
    }
  };
  
  fs.appendFileSync(
    'coordination/governance/access-log.jsonl',
    JSON.stringify(entry) + '\n'
  );
};
```

### Elastic APM Integration

**Custom Security Spans**:
```javascript
const span = apm.startSpan('achievement.security_check');
span.setLabel('token_validation', tokenValid);
span.setLabel('rate_limit_ok', rateLimitOk);
span.end();
```

## Audit Trail

### Achievement History

**Immutable Log**:
```bash
# coordination/masters/achievement/metrics/pr-automation-history.jsonl
{"timestamp":"2025-11-25T20:54:20Z","achievement":"pull_shark","pr_number":6,"yolo_mode":true,"merged":true,"security_validated":true}
```

**Retention Policy**:
- Keep all automation logs indefinitely
- Monthly backups to secure storage
- Quarterly security audits

## Incident Response

### Compromised Token Detection

**Automated Response**:
```bash
#!/usr/bin/env bash
# Triggered by suspicious activity alert

echo "🚨 Security incident detected - compromised token suspected"

# 1. Revoke token immediately
gh auth token-revoke

# 2. Disable achievement automation
systemctl stop achievement-tracker

# 3. Notify security team
curl -X POST "$SLACK_WEBHOOK" \
  -d '{"text":"🚨 Achievement automation token compromised - system disabled"}'

# 4. Generate incident report
node coordination/masters/achievement/lib/incident-report.js
```

---

**Last Updated**: $(date -u +"%Y-%m-%d %H:%M:%S UTC")  
**Version**: 1.0.0  
**Compliance**: SOC 2 Type II, GDPR
