# Root Cause Analysis: Worker Launcher Script Bug

**Task ID**: task-1762961220
**Investigation Date**: 2025-11-12T15:40:00Z
**Investigated By**: development-master
**Priority**: CRITICAL
**Status**: RESOLVED - Fix Identified

---

## Executive Summary

All 6 governance workers launched 70+ minutes ago failed immediately due to a critical bug in the worker launcher script (`claude-worker-launcher-v2.sh`). The script failed to properly substitute task context placeholders, resulting in workers receiving empty task IDs and unsubstituted placeholder text.

**Impact**: 100% failure rate (6/6 workers) for governance task execution
**Root Cause**: Incorrect template placeholder replacement logic
**Fix Complexity**: LOW - Single line fix + validation additions

---

## Affected Workers

| Worker ID | Worker Type | Task ID | Failure Time |
|-----------|-------------|---------|--------------|
| dev-worker-04B8F99C | implementation-worker | (empty) | 2025-11-12T13:54:14Z |
| dev-worker-72AB3732 | implementation-worker | (empty) | ~2025-11-12T13:55:00Z |
| dev-worker-899AB82C | implementation-worker | (empty) | ~2025-11-12T13:55:00Z |
| dev-worker-21C2A367 | implementation-worker | (empty) | ~2025-11-12T13:55:00Z |
| sec-worker-DC77FC1A | security-worker | (empty) | ~2025-11-12T13:55:00Z |
| sec-worker-48C1327F | security-worker | (empty) | ~2025-11-12T13:55:00Z |

---

## Symptoms Observed

### From Worker Logs (`dev-worker-04B8F99C/logs/stdout.log`):

```
[2025-11-12T13:54:14Z] Worker execution starting...
[2025-11-12T13:54:14Z] Working directory: .
[2025-11-12T13:54:14Z] Prompt file: prompt.md
```

Worker detected:
- Empty task ID (line 3 of prompt: "executing task .")
- Unsubstituted placeholder (line 24: "TASK_CONTEXT_PLACEHOLDER")
- Worker exited with code 0 (successful exit but no work done)

### From Worker Prompt (`dev-worker-04B8F99C/prompt.md`):

```markdown
You are an AI worker (ID: dev-worker-04B8F99C) executing task .
                                                              ^
                                                              Empty task_id

**Task**: Task
              ^
              Empty task_title

## Task Context

TASK_CONTEXT_PLACEHOLDER    <--- UNSUBSTITUTED PLACEHOLDER
```

At end of file:
```
{}    <--- Task context appended instead of replaced
```

---

## Root Cause Analysis

### Bug Location

**File**: `/Users/ryandahlberg/commit-relay/scripts/claude-worker-launcher-v2.sh`
**Lines**: 148-152 (template placeholder replacement section)

### The Critical Bug - Line 152

```bash
# Lines 148-151: These work correctly
sed -i '' "s/WORKER_ID_PLACEHOLDER/$WORKER_ID/g" "$WORKER_DIR/prompt.md"
sed -i '' "s/TASK_ID_PLACEHOLDER/$TASK_ID/g" "$WORKER_DIR/prompt.md"
sed -i '' "s/TASK_TITLE_PLACEHOLDER/$TASK_TITLE/g" "$WORKER_DIR/prompt.md"
sed -i '' "s/WORKER_TYPE_PLACEHOLDER/$WORKER_TYPE/g" "$WORKER_DIR/prompt.md"

# Line 152: THE BUG - Appends instead of replaces
echo "$TASK_CONTEXT" >> "$WORKER_DIR/prompt.md"
#      ^^^^^^^^^^^^^^^
#      Should be: sed -i '' "s/TASK_CONTEXT_PLACEHOLDER/$TASK_CONTEXT/g"
```

**What Happened:**
- The script uses `sed` to replace 4 placeholders (WORKER_ID, TASK_ID, TASK_TITLE, WORKER_TYPE)
- But for TASK_CONTEXT, it uses `echo >> ` which **appends** content to the file
- Result: TASK_CONTEXT_PLACEHOLDER remains in the file, and the actual context is appended at the end

### Secondary Issue - Empty Task ID

The workers also show empty task IDs (showing as "."). This indicates:

1. **Script invocation issue**: The launcher was called without proper `TASK_ID` argument
2. **Variable extraction failure**: The task_id wasn't properly extracted from worker specs

**Evidence from line 9-10 of launcher:**
```bash
TASK_ID="$2"  # Second positional argument
```

If $2 is empty, then `TASK_ID=""`, and when sed tries to replace:
```bash
sed -i '' "s/TASK_ID_PLACEHOLDER//g"
```
This results in "executing task ." (just the period remains).

### Tertiary Issue - Task File Not Found

Lines 74-85 of the launcher attempt to load task details:

```bash
TASK_FILE="$PROJECT_ROOT/coordination/tasks/task-$TASK_ID.json"

if [[ -f "$TASK_FILE" ]]; then
    TASK_TITLE=$(jq -r '.title // "Unknown task"' "$TASK_FILE")
    TASK_CONTEXT=$(jq -r '.context // {}' "$TASK_FILE")
    log "Task: $TASK_TITLE"
else
    TASK_TITLE="Task $TASK_ID"
    TASK_CONTEXT="{}"
    log "Task file not found, using defaults"
fi
```

When TASK_ID is empty:
- Task file path becomes: `coordination/tasks/task-.json`
- File doesn't exist
- Defaults are used: `TASK_TITLE="Task "` and `TASK_CONTEXT="{}"`

---

## Failure Chain

```
1. Worker daemon spawns worker
   └─> Calls launcher with empty or missing TASK_ID argument
       └─> $TASK_ID = "" (empty)
           └─> Task file not found (coordination/tasks/task-.json doesn't exist)
               └─> Script uses defaults: TASK_TITLE="Task ", TASK_CONTEXT="{}"
                   └─> sed replacements execute:
                       ├─> WORKER_ID_PLACEHOLDER → dev-worker-04B8F99C ✓
                       ├─> TASK_ID_PLACEHOLDER → "" (empty) ✗
                       ├─> TASK_TITLE_PLACEHOLDER → "Task " ✗
                       └─> WORKER_TYPE_PLACEHOLDER → implementation-worker ✓
                   └─> Line 152 executes: echo "{}" >> prompt.md
                       └─> TASK_CONTEXT_PLACEHOLDER remains unsubstituted ✗
                           └─> Worker receives malformed prompt
                               └─> Worker recognizes issue and exits immediately
```

---

## Required Fixes

### Fix #1: Replace Line 152 (CRITICAL)

**Current (BROKEN):**
```bash
echo "$TASK_CONTEXT" >> "$WORKER_DIR/prompt.md"
```

**Fixed:**
```bash
sed -i '' "s|TASK_CONTEXT_PLACEHOLDER|$TASK_CONTEXT|g" "$WORKER_DIR/prompt.md"
```

**Notes:**
- Use `|` as delimiter instead of `/` because JSON contains forward slashes
- Use `-i ''` for in-place editing on macOS
- Ensure $TASK_CONTEXT is properly escaped if it contains special characters

### Fix #2: Add Input Validation (HIGH PRIORITY)

Add validation at the start of the script (after line 20):

```bash
# Validate required arguments
if [[ -z "$WORKER_ID" ]]; then
    log "ERROR: WORKER_ID (argument 1) is required"
    exit 1
fi

if [[ -z "$TASK_ID" ]]; then
    log "ERROR: TASK_ID (argument 2) is required"
    exit 1
fi

log "Validated arguments: WORKER_ID=$WORKER_ID, TASK_ID=$TASK_ID, WORKER_TYPE=$WORKER_TYPE"
```

### Fix #3: Add Post-Generation Validation (GOVERNANCE)

Add validation after line 152 to check for unsubstituted placeholders:

```bash
# Validate that all placeholders were substituted
UNSUBSTITUTED=$(grep -c "PLACEHOLDER" "$WORKER_DIR/prompt.md" || true)

if [[ $UNSUBSTITUTED -gt 0 ]]; then
    log "ERROR: Found $UNSUBSTITUTED unsubstituted placeholders in prompt.md"
    log "Prompt generation failed validation"

    # Log the problematic content
    grep "PLACEHOLDER" "$WORKER_DIR/prompt.md" >> "$PROJECT_ROOT/agents/logs/system/launcher.log"

    # Create failure status
    echo "{\"status\": \"failed\", \"error\": \"placeholder_substitution_failed\", \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" > "$WORKER_DIR/status.json"

    exit 1
fi

log "✅ All placeholders substituted successfully"
```

### Fix #4: Escape Special Characters in JSON

For proper JSON handling in sed replacement:

```bash
# Escape special characters in TASK_CONTEXT for sed
TASK_CONTEXT_ESCAPED=$(echo "$TASK_CONTEXT" | sed 's/[\/&]/\\&/g')
sed -i '' "s|TASK_CONTEXT_PLACEHOLDER|$TASK_CONTEXT_ESCAPED|g" "$WORKER_DIR/prompt.md"
```

---

## Prevention Measures for Future Scripts

### Governance Best Practices

1. **Always validate inputs at script start**
   - Check required arguments are non-empty
   - Log validation results
   - Exit early if validation fails

2. **Use consistent placeholder replacement strategy**
   - If using sed for some placeholders, use sed for ALL
   - Never mix `sed` and `echo >>` for template substitution
   - Use consistent delimiters

3. **Add post-generation validation**
   - Check for unsubstituted placeholders before use
   - Grep for "_PLACEHOLDER" patterns
   - Fail fast if validation fails

4. **Improve error logging**
   - Log argument values at script start
   - Log each substitution step
   - Log validation results

5. **Add unit tests for scripts**
   - Test with empty arguments
   - Test with missing files
   - Test placeholder substitution
   - Test special character handling

### Shell Script Template Pattern

```bash
#!/bin/bash

# 1. VALIDATE INPUTS
if [[ -z "$REQUIRED_ARG" ]]; then
    echo "ERROR: REQUIRED_ARG is missing"
    exit 1
fi

# 2. GENERATE CONTENT FROM TEMPLATE
cat > output.txt << 'EOF'
Template content with PLACEHOLDER_1 and PLACEHOLDER_2
EOF

# 3. SUBSTITUTE ALL PLACEHOLDERS USING SED
sed -i '' "s/PLACEHOLDER_1/$VALUE_1/g" output.txt
sed -i '' "s/PLACEHOLDER_2/$VALUE_2/g" output.txt

# 4. VALIDATE OUTPUT
if grep -q "PLACEHOLDER" output.txt; then
    echo "ERROR: Unsubstituted placeholders found"
    exit 1
fi

# 5. PROCEED WITH EXECUTION
```

---

## Testing Recommendations

### Test Case 1: Valid Arguments
```bash
./scripts/claude-worker-launcher-v2.sh "test-worker-001" "task-123" "implementation-worker"
```
Expected: Worker launches with all placeholders substituted

### Test Case 2: Missing Task ID
```bash
./scripts/claude-worker-launcher-v2.sh "test-worker-002" "" "implementation-worker"
```
Expected: Script exits with validation error before generating prompt

### Test Case 3: Non-existent Task File
```bash
./scripts/claude-worker-launcher-v2.sh "test-worker-003" "nonexistent-task" "implementation-worker"
```
Expected: Script uses defaults but successfully substitutes placeholders

### Test Case 4: Complex Task Context (Special Characters)
```bash
# Create task file with special characters in context
cat > coordination/tasks/task-test-special.json << 'EOF'
{
  "title": "Test task with / and & characters",
  "context": {
    "path": "/usr/local/bin",
    "command": "echo 'test & validate'"
  }
}
EOF

./scripts/claude-worker-launcher-v2.sh "test-worker-004" "test-special" "implementation-worker"
```
Expected: All special characters properly escaped and substituted

---

## Impact Assessment

### Severity: CRITICAL

**Reasoning:**
- 100% failure rate for affected worker launches
- Governance workers unable to execute assigned tasks
- System unable to self-heal due to governance failure
- Cascading impact on task queue and coordination

### Affected Systems:
- Worker daemon (launches workers with this script)
- Task orchestrator (depends on workers completing tasks)
- Governance system (relies on workers for self-checks)
- MoE routing (workers unable to execute routed tasks)

### Business Impact:
- Governance tasks not executed
- System health checks not performed
- Development tasks blocked
- Security scans not running
- User trust impacted by failed automation

---

## Resolution Steps

1. **Immediate**: Apply Fix #1 (replace line 152 with sed command)
2. **Short-term**: Apply Fix #2 (input validation)
3. **Medium-term**: Apply Fix #3 (post-generation validation)
4. **Long-term**: Implement governance testing framework for scripts

---

## Learning for MoE System

**Pattern**: Script template substitution failure
**Category**: Code Quality / Testing Gap
**Severity**: Critical

**Key Learnings:**
1. Template placeholder substitution must be consistent (all sed or all echo, not mixed)
2. Input validation prevents cascading failures
3. Post-generation validation catches substitution errors early
4. Scripts must be tested with edge cases (empty args, missing files, special chars)
5. Governance scripts require extra scrutiny and validation

**Prevention Measures:**
- Add script linting to CI/CD pipeline
- Require validation checks in all template-generating scripts
- Create unit test framework for bash scripts
- Document template substitution best practices
- Add MoE review step for all system scripts before deployment

---

## Appendix A: Fixed Script Snippet

```bash
# Lines 148-156 (FIXED VERSION)
log "Performing template placeholder substitution..."

# Substitute all placeholders using sed for consistency
sed -i '' "s/WORKER_ID_PLACEHOLDER/$WORKER_ID/g" "$WORKER_DIR/prompt.md"
sed -i '' "s/TASK_ID_PLACEHOLDER/$TASK_ID/g" "$WORKER_DIR/prompt.md"
sed -i '' "s/TASK_TITLE_PLACEHOLDER/$TASK_TITLE/g" "$WORKER_DIR/prompt.md"
sed -i '' "s/WORKER_TYPE_PLACEHOLDER/$WORKER_TYPE/g" "$WORKER_DIR/prompt.md"

# Escape special characters in TASK_CONTEXT for sed
TASK_CONTEXT_ESCAPED=$(echo "$TASK_CONTEXT" | sed 's/[\/&]/\\&/g')
sed -i '' "s|TASK_CONTEXT_PLACEHOLDER|$TASK_CONTEXT_ESCAPED|g" "$WORKER_DIR/prompt.md"

# Validate that all placeholders were substituted
UNSUBSTITUTED=$(grep -c "PLACEHOLDER" "$WORKER_DIR/prompt.md" || true)

if [[ $UNSUBSTITUTED -gt 0 ]]; then
    log "ERROR: Found $UNSUBSTITUTED unsubstituted placeholders in prompt.md"
    grep "PLACEHOLDER" "$WORKER_DIR/prompt.md" >> "$PROJECT_ROOT/agents/logs/system/launcher.log"
    echo "{\"status\": \"failed\", \"error\": \"placeholder_substitution_failed\", \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" > "$WORKER_DIR/status.json"
    exit 1
fi

log "✅ All placeholders substituted successfully"
```

---

## Sign-off

**Analysis Completed By**: Development Master (MoE-routed)
**Date**: 2025-11-12T15:40:00Z
**Status**: Root cause identified, fix documented
**Next Steps**: Apply fixes, test, create MoE learning entry

---

**References:**
- Launcher script: `/Users/ryandahlberg/commit-relay/scripts/claude-worker-launcher-v2.sh`
- Failed worker logs: `/Users/ryandahlberg/commit-relay/agents/workers/dev-worker-04B8F99C/`
- Worker prompt: `/Users/ryandahlberg/commit-relay/agents/workers/dev-worker-04B8F99C/prompt.md`
- Task handoff: `/Users/ryandahlberg/commit-relay/coordination/masters/coordinator/handoffs/to-development-task-1762961220.json`
