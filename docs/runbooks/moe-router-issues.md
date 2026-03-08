# Runbook: MoE Router Issues

Diagnosis and resolution for misrouting and null assignments in the Mixture of Experts router.

---

## Symptoms

- Tasks assigned to wrong worker types
- Tasks stuck with no worker assignment
- Router returns null or undefined worker type
- Low confidence scores in routing decisions
- Pattern matching failures
- Tasks failing consistently after routing

---

## Root Causes

1. **Incomplete Routing Rules**: No rule matches the task
2. **Conflicting Rules**: Multiple rules match with different outcomes
3. **Stale Pattern Data**: Learned patterns are outdated
4. **Missing Worker Types**: Routed to non-existent worker type
5. **Configuration Corruption**: Invalid JSON in config files
6. **Confidence Threshold**: Score too low for assignment
7. **Feature Extraction Failure**: Cannot extract task features

---

## Diagnosis Steps

### 1. Check Router Configuration

```bash
# View router config
cat $COMMIT_RELAY_HOME/coordination/moe/router-config.json | jq .

# Validate JSON
jq empty $COMMIT_RELAY_HOME/coordination/moe/router-config.json && echo "Valid JSON" || echo "Invalid JSON"

# List all routing rules
jq '.rules[] | {pattern, worker_type, priority}' $COMMIT_RELAY_HOME/coordination/moe/router-config.json
```

### 2. Review Routing Decisions

```bash
# Recent routing decisions
tail -20 $COMMIT_RELAY_HOME/coordination/masters/coordinator/knowledge-base/routing-decisions.jsonl | jq .

# Low confidence decisions
tail -100 $COMMIT_RELAY_HOME/coordination/masters/coordinator/knowledge-base/routing-decisions.jsonl | \
    jq 'select(.confidence < 0.7)'

# Null assignments
grep 'null\|"worker_type":""' $COMMIT_RELAY_HOME/coordination/masters/coordinator/knowledge-base/routing-decisions.jsonl
```

### 3. Check Router Health

```bash
# Router health status
cat $COMMIT_RELAY_HOME/coordination/routing-health.json | jq .

# Recent router events
grep -i "router\|moe" $COMMIT_RELAY_HOME/coordination/dashboard-events.jsonl | tail -20 | jq .
```

### 4. Analyze Task Patterns

```bash
# Get task that failed routing
TASK_ID="task-001"
cat $COMMIT_RELAY_HOME/coordination/task-queue.json | jq ".tasks[] | select(.task_id == \"$TASK_ID\")"

# Check task description against patterns
DESCRIPTION=$(cat $COMMIT_RELAY_HOME/coordination/task-queue.json | \
    jq -r ".tasks[] | select(.task_id == \"$TASK_ID\") | .description")
echo "Task: $DESCRIPTION"

# Find matching rules
jq --arg desc "$DESCRIPTION" '.rules[] | select(.pattern as $p | $desc | test($p; "i"))' \
   $COMMIT_RELAY_HOME/coordination/moe/router-config.json
```

### 5. Verify Worker Type Registry

```bash
# List available worker types
cat $COMMIT_RELAY_HOME/coordination/config/worker-types.json | jq 'keys'

# Check specific type exists
WORKER_TYPE="implementation-worker"
jq --arg t "$WORKER_TYPE" '.worker_types[$t] // "NOT FOUND"' \
   $COMMIT_RELAY_HOME/coordination/config/worker-types.json
```

---

## Resolution Steps

### Immediate Actions

#### 1. Add Missing Routing Rule

```bash
# Add new rule for unmatched pattern
jq '.rules += [{
  "pattern": "your-pattern-here",
  "worker_type": "implementation-worker",
  "priority": "medium",
  "confidence": 0.8
}]' $COMMIT_RELAY_HOME/coordination/moe/router-config.json > /tmp/router.json && \
mv /tmp/router.json $COMMIT_RELAY_HOME/coordination/moe/router-config.json
```

#### 2. Add Default/Fallback Rule

```bash
# Ensure there's a catch-all rule
jq '.rules += [{
  "pattern": ".*",
  "worker_type": "analysis-worker",
  "priority": "low",
  "confidence": 0.5,
  "is_default": true
}]' $COMMIT_RELAY_HOME/coordination/moe/router-config.json > /tmp/router.json && \
mv /tmp/router.json $COMMIT_RELAY_HOME/coordination/moe/router-config.json
```

#### 3. Fix Conflicting Rules

```bash
# List potentially conflicting rules
jq -r '.rules | sort_by(.pattern) | .[] | "\(.pattern) -> \(.worker_type)"' \
   $COMMIT_RELAY_HOME/coordination/moe/router-config.json

# Update rule priority to resolve conflict
PATTERN="security.*scan"
jq --arg p "$PATTERN" '(.rules[] | select(.pattern == $p) | .priority) = "high"' \
   $COMMIT_RELAY_HOME/coordination/moe/router-config.json > /tmp/router.json && \
mv /tmp/router.json $COMMIT_RELAY_HOME/coordination/moe/router-config.json
```

#### 4. Manually Route Task

```bash
# Force assignment for stuck task
TASK_ID="task-001"
WORKER_TYPE="implementation-worker"

jq --arg t "$TASK_ID" --arg w "$WORKER_TYPE" \
   '(.tasks[] | select(.task_id == $t) | .routing) = {
     "worker_type": $w,
     "confidence": 1.0,
     "manual_override": true
   }' $COMMIT_RELAY_HOME/coordination/task-queue.json > /tmp/queue.json && \
mv /tmp/queue.json $COMMIT_RELAY_HOME/coordination/task-queue.json
```

#### 5. Reset Router State

```bash
# Clear stale routing decisions (keep last 100)
tail -100 $COMMIT_RELAY_HOME/coordination/masters/coordinator/knowledge-base/routing-decisions.jsonl > \
    /tmp/decisions.jsonl && \
mv /tmp/decisions.jsonl $COMMIT_RELAY_HOME/coordination/masters/coordinator/knowledge-base/routing-decisions.jsonl

# Reset routing health
cat > $COMMIT_RELAY_HOME/coordination/routing-health.json << 'EOF'
{
  "status": "healthy",
  "last_check": null,
  "errors": [],
  "reset_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
```

### Long-term Solutions

#### 1. Improve Pattern Matching

```bash
# Add more specific patterns with higher confidence
jq '.rules = [
  {"pattern": "implement.*feature", "worker_type": "implementation-worker", "confidence": 0.95},
  {"pattern": "fix.*bug", "worker_type": "fix-worker", "confidence": 0.95},
  {"pattern": "scan.*security", "worker_type": "scan-worker", "confidence": 0.95},
  {"pattern": "write.*test", "worker_type": "test-worker", "confidence": 0.95},
  {"pattern": "review.*code", "worker_type": "review-worker", "confidence": 0.95},
  {"pattern": "document", "worker_type": "documentation-worker", "confidence": 0.90},
  {"pattern": "analyze", "worker_type": "analysis-worker", "confidence": 0.85},
  {"pattern": ".*", "worker_type": "analysis-worker", "confidence": 0.5, "is_default": true}
]' $COMMIT_RELAY_HOME/coordination/moe/router-config.json > /tmp/router.json && \
mv /tmp/router.json $COMMIT_RELAY_HOME/coordination/moe/router-config.json
```

#### 2. Enable Learning from Outcomes

Track successful and failed routings to improve patterns:

```bash
# Log routing outcome
log_routing_outcome() {
    local task_id="$1"
    local worker_type="$2"
    local success="$3"

    cat >> $COMMIT_RELAY_HOME/coordination/moe/routing-outcomes.jsonl << EOF
{"task_id":"$task_id","worker_type":"$worker_type","success":$success,"timestamp":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOF
}
```

#### 3. Set Confidence Thresholds

```bash
# Configure minimum confidence for routing
jq '.settings.min_confidence = 0.6 | .settings.fallback_on_low_confidence = true' \
   $COMMIT_RELAY_HOME/coordination/moe/router-config.json > /tmp/router.json && \
mv /tmp/router.json $COMMIT_RELAY_HOME/coordination/moe/router-config.json
```

#### 4. Register Missing Worker Types

```bash
# Add new worker type
NEW_TYPE="custom-worker"
jq --arg t "$NEW_TYPE" '.worker_types[$t] = {
  "description": "Custom worker for specific tasks",
  "default_budget": 50000,
  "default_duration": 20,
  "skills": ["analysis", "implementation"]
}' $COMMIT_RELAY_HOME/coordination/config/worker-types.json > /tmp/types.json && \
mv /tmp/types.json $COMMIT_RELAY_HOME/coordination/config/worker-types.json
```

---

## Prevention

### Validate Configuration on Startup

```bash
# Add to startup script
validate_router_config() {
    local config="$COMMIT_RELAY_HOME/coordination/moe/router-config.json"

    # Check JSON valid
    jq empty "$config" || return 1

    # Check has rules
    local rules=$(jq '.rules | length' "$config")
    (( rules > 0 )) || return 1

    # Check has default rule
    jq -e '.rules[] | select(.is_default == true)' "$config" > /dev/null || \
        echo "Warning: No default routing rule"

    return 0
}
```

### Monitor Routing Quality

```bash
# Track routing success rate
SUCCESS=$(grep '"success":true' $COMMIT_RELAY_HOME/coordination/moe/routing-outcomes.jsonl | wc -l)
TOTAL=$(wc -l < $COMMIT_RELAY_HOME/coordination/moe/routing-outcomes.jsonl)
RATE=$((SUCCESS * 100 / TOTAL))

if (( RATE < 80 )); then
    echo "Warning: Routing success rate is ${RATE}%"
fi
```

### Regular Pattern Review

Review and update routing patterns weekly based on task outcomes.

---

## Verification

After fixes:

```bash
# 1. Validate configuration
jq empty $COMMIT_RELAY_HOME/coordination/moe/router-config.json && echo "Config valid"

# 2. Test routing
./scripts/debug-moe-router.sh --task "implement new feature"

# 3. Create test task and verify routing
./scripts/create-task.sh --description "Test routing" --priority low

# 4. Check routing decision was made
tail -1 $COMMIT_RELAY_HOME/coordination/masters/coordinator/knowledge-base/routing-decisions.jsonl | jq .

# 5. Verify worker spawned with correct type
ls $COMMIT_RELAY_HOME/coordination/worker-specs/active/ | head -5
```

---

## Escalation

If routing continues to fail:

1. Review all routing rules for completeness
2. Check coordinator daemon logs for errors
3. Verify worker types are registered
4. Analyze failed routing decisions for patterns
5. Consider resetting to known-good configuration

---

## Related Runbooks

- [Worker Failure](./worker-failure.md)
- [Task Queue Management](./task-queue-management.md)
- [Performance Troubleshooting](./performance-troubleshooting.md)

---

**Last Updated**: 2025-11-21
