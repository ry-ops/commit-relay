# Troubleshooting Guide

## Common Issues and Solutions

Quick reference for diagnosing and fixing common commit-relay issues.

---

## GitHub API Issues

### Issue: Rate Limit Exceeded

**Symptoms**:
```
Error: GitHub API rate limit exceeded
Status: 429
```

**Diagnosis**:
```bash
# Check current rate limit
curl -H "Authorization: Bearer $GITHUB_TOKEN" \
  https://api.github.com/rate_limit | jq '.rate'
```

**Solutions**:

1. **Wait for reset**:
```bash
# Check reset time
RESET_TIME=$(curl -s -H "Authorization: Bearer $GITHUB_TOKEN" \
  https://api.github.com/rate_limit | jq -r '.rate.reset')
echo "Resets at: $(date -r $RESET_TIME)"
```

2. **Enable request caching**:
```javascript
// Add caching to reduce API calls
const NodeCache = require('node-cache');
const cache = new NodeCache({ stdTTL: 300 });
```

3. **Use GraphQL instead of REST**:
```javascript
// Replace multiple REST calls with single GraphQL query
const query = `{ user(login: "${username}") { repositories { totalCount } } }`;
```

---

### Issue: Invalid GitHub Token

**Symptoms**:
```
Error: Bad credentials
Status: 401
```

**Diagnosis**:
```bash
# Test token
gh auth status

# Or manually
curl -H "Authorization: Bearer $GITHUB_TOKEN" \
  https://api.github.com/user
```

**Solutions**:

1. **Regenerate token** at https://github.com/settings/tokens
2. **Update environment variable**:
```bash
export GITHUB_TOKEN="ghp_NEW_TOKEN"
echo "GITHUB_TOKEN=ghp_NEW_TOKEN" >> .env
```

3. **Verify scopes**:
   - ✅ `repo` - Full repository access
   - ✅ `workflow` - GitHub Actions
   - ✅ `read:org` - Organization membership

---

## Worker Issues

### Issue: Worker Zombie (Not Responding)

**Symptoms**:
```bash
$ cat coordination/pm-state.json | jq '.workers[] | select(.state == "zombie")'
```

**Diagnosis**:
```bash
# Check worker heartbeat
./scripts/lib/zombie-cleanup.sh --list

# Check worker process
ps aux | grep worker
```

**Solutions**:

1. **Manual cleanup**:
```bash
./scripts/lib/zombie-cleanup.sh --cleanup worker-001
```

2. **Automatic cleanup** (enabled by default):
```bash
# Zombie detection runs every 5 minutes
# Check daemon status
pm2 list | grep zombie-cleanup
```

3. **Investigate root cause**:
```bash
# Check worker logs
tail -100 agents/workers/worker-001/worker.log
```

---

### Issue: Worker Spawn Failure

**Symptoms**:
```
Error: Failed to spawn worker
Worker type: scan-worker
```

**Diagnosis**:
```bash
# Check governance
node lib/governance/access-control.js check \
  --actor "achievement-master" \
  --action "spawn_worker" \
  --resource "scan-worker"

# Check worker pool
cat coordination/worker-pool.json | jq '.active_count'
```

**Solutions**:

1. **Check permissions**:
```bash
# Verify governance allows spawn
cat coordination/config/governance-policy.json | \
  jq '.permissions.achievement_master'
```

2. **Check pool capacity**:
```bash
# Max workers: 20 (default)
# If at capacity, wait for worker to complete
```

3. **Bypass governance** (development only):
```bash
GOVERNANCE_BYPASS=true ./scripts/spawn-worker.sh --type scan-worker
```

---

## API Server Issues

### Issue: Server Won't Start

**Symptoms**:
```
Error: listen EADDRINUSE: address already in use :::5001
```

**Diagnosis**:
```bash
# Check what's using port 5001
lsof -i :5001

# Or
netstat -an | grep 5001
```

**Solutions**:

1. **Kill existing process**:
```bash
lsof -ti :5001 | xargs kill -9
```

2. **Use different port**:
```bash
PORT=5002 npm start
```

3. **PM2 restart**:
```bash
pm2 restart api-server
```

---

### Issue: Slow API Responses

**Symptoms**:
```
Response time: 5000ms (expected < 200ms)
```

**Diagnosis**:
```bash
# Check Elastic APM
# Look for slow transactions

# Profile with autocannon
autocannon -c 10 -d 30 http://localhost:5001/api/achievements/progress
```

**Solutions**:

1. **Enable caching**:
```javascript
const cache = new NodeCache({ stdTTL: 300 });
```

2. **Check database queries**:
```bash
# Look for missing indexes
# Check EXPLAIN output
```

3. **Reduce API calls**:
```javascript
// Batch requests
// Use GraphQL
```

---

## Database Issues

### Issue: Connection Pool Exhausted

**Symptoms**:
```
Error: Knex: Timeout acquiring a connection
```

**Diagnosis**:
```bash
# Check active connections
cat coordination/metrics/database-metrics.json | \
  jq '.pool.active_connections'
```

**Solutions**:

1. **Increase pool size**:
```javascript
const pool = new Pool({ max: 30, min: 10 });
```

2. **Find connection leaks**:
```bash
# Look for queries without .finally() to release connection
```

3. **Restart pool**:
```bash
pm2 restart api-server
```

---

## Achievement Tracking Issues

### Issue: Achievement Not Unlocking

**Symptoms**:
```
Expected: pull_shark unlocked
Actual: pull_shark still locked
```

**Diagnosis**:
```bash
# Check PR count
gh pr list --state merged --author ry-ops | wc -l

# Check achievement API
curl http://localhost:5001/api/achievements/progress | \
  jq '.achievements.pull_shark'
```

**Solutions**:

1. **GitHub's achievement system is delayed** (24-48 hours)
   - Wait 24 hours
   - Check https://github.com/ry-ops?tab=achievements

2. **Verify requirements met**:
```bash
# Pull Shark Silver: 16+ merged PRs
gh api /search/issues?q=author:ry-ops+type:pr+is:merged | \
  jq '.total_count'
```

3. **Check co-authored commits** (for Pair Extraordinaire):
```bash
git log --all --grep="Co-Authored-By" --oneline | wc -l
```

---

## MoE Routing Issues

### Issue: Low Routing Confidence

**Symptoms**:
```json
{
  "assigned_master": "coordinator-master",
  "confidence": 0.35
}
```

**Diagnosis**:
```bash
# Check routing patterns
cat coordination/knowledge-base/learned-patterns/patterns-latest.json | \
  jq '.patterns | length'

# Check routing history
tail -50 coordination/masters/coordinator/knowledge-base/routing-decisions.jsonl
```

**Solutions**:

1. **More training data needed**:
```bash
# System needs ~100 routing decisions to learn patterns
# Continue using system normally
```

2. **Update patterns manually**:
```bash
# Edit patterns file to boost specific patterns
```

3. **Check pattern coverage**:
```bash
./llm-mesh/moe-learning/moe-learn.sh status
```

---

## Deployment Issues

### Issue: Blue-Green Deployment Fails

**Symptoms**:
```
Error: Health check failed for blue environment
```

**Diagnosis**:
```bash
# Check health endpoint
curl http://localhost:5001/api/health
curl http://localhost:5002/api/health

# Check PM2 status
pm2 list
```

**Solutions**:

1. **Manual rollback**:
```bash
./scripts/deployment/deploy.sh --rollback
```

2. **Check logs**:
```bash
pm2 logs api-server-blue
```

3. **Verify environment variables**:
```bash
pm2 env 0  # Check env vars for process
```

---

## Elastic APM Issues

### Issue: No Data in APM

**Symptoms**:
```
Elastic APM dashboard shows no transactions
```

**Diagnosis**:
```bash
# Check APM agent status
curl http://localhost:5001/api/health | jq '.apm'

# Check APM configuration
echo $ELASTIC_APM_SECRET_TOKEN
```

**Solutions**:

1. **Verify APM token**:
```bash
# Test connection
curl -X POST "https://YOUR_APM_URL/intake/v2/events" \
  -H "Authorization: Bearer $ELASTIC_APM_SECRET_TOKEN"
```

2. **Restart with APM debugging**:
```bash
ELASTIC_APM_LOG_LEVEL=trace npm start
```

3. **Check firewall**:
```bash
# Ensure outbound HTTPS to *.elastic-cloud.com allowed
```

---

## Getting Help

### Debug Checklist

- [ ] Check logs: `pm2 logs`
- [ ] Check metrics: `coordination/metrics/`
- [ ] Check system health: `coordination/system-health-check.json`
- [ ] Check GitHub API status: https://www.githubstatus.com
- [ ] Check Elastic Cloud status: https://status.elastic.co

### Log Locations

```bash
logs/error.jsonl          # Error logs
logs/combined.jsonl       # All logs
logs/workers.jsonl        # Worker logs
coordination/events/      # System events
pm2 logs                  # PM2 managed processes
```

### Support Channels

- **Documentation**: https://github.com/ry-ops/commit-relay/wiki
- **Issues**: https://github.com/ry-ops/commit-relay/issues
- **Discussions**: https://github.com/ry-ops/commit-relay/discussions

---

**Last Updated**: 2025-11-25  
**Issues Documented**: 15+
