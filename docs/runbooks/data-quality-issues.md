# Runbook: Data Quality Issues

Diagnosis and resolution for malformed JSON, schema violations, and data corruption.

---

## Symptoms

- JSON parse errors
- Missing required fields
- Type mismatches
- Schema validation failures
- Inconsistent data
- Corrupt files
- Encoding issues

---

## Root Causes

1. **Write Failures**: Incomplete writes due to crashes
2. **Concurrent Access**: Race conditions on files
3. **Invalid Input**: Workers producing bad data
4. **Encoding Issues**: Character set problems
5. **Disk Errors**: Hardware failures
6. **Script Bugs**: Incorrect data generation

---

## Diagnosis Steps

### 1. Validate JSON Files

```bash
# Check all JSON files in coordination
for file in $COMMIT_RELAY_HOME/coordination/*.json; do
    if ! jq empty "$file" 2>/dev/null; then
        echo "[INVALID] $file"
    fi
done

# Check nested directories
find $COMMIT_RELAY_HOME/coordination -name "*.json" -exec sh -c '
    for f; do
        jq empty "$f" 2>/dev/null || echo "[INVALID] $f"
    done
' _ {} +
```

### 2. Check JSONL Files

```bash
# Validate JSONL (one JSON object per line)
FILE="$COMMIT_RELAY_HOME/coordination/dashboard-events.jsonl"
LINE=0
while IFS= read -r line; do
    ((LINE++))
    echo "$line" | jq empty 2>/dev/null || echo "Line $LINE invalid"
done < "$FILE"
```

### 3. Find Empty Files

```bash
# Find empty JSON files
find $COMMIT_RELAY_HOME/coordination -name "*.json" -empty -print

# Find files with only whitespace
find $COMMIT_RELAY_HOME/coordination -name "*.json" -exec sh -c '
    for f; do
        if [[ ! -s "$f" ]] || ! grep -q "[^[:space:]]" "$f"; then
            echo "[EMPTY] $f"
        fi
    done
' _ {} +
```

### 4. Check Required Fields

```bash
# Verify worker specs have required fields
for spec in $COMMIT_RELAY_HOME/coordination/worker-specs/active/worker-*.json; do
    if [[ -f "$spec" ]]; then
        ERRORS=""
        [[ $(jq -r '.worker_id // "null"' "$spec") == "null" ]] && ERRORS+="worker_id "
        [[ $(jq -r '.worker_type // "null"' "$spec") == "null" ]] && ERRORS+="worker_type "
        [[ $(jq -r '.status // "null"' "$spec") == "null" ]] && ERRORS+="status "

        if [[ -n "$ERRORS" ]]; then
            echo "[MISSING] $(basename $spec): $ERRORS"
        fi
    fi
done
```

### 5. Check Data Types

```bash
# Verify field types
for spec in $COMMIT_RELAY_HOME/coordination/worker-specs/active/worker-*.json; do
    if [[ -f "$spec" ]]; then
        # Check token_budget is object
        if [[ $(jq -r '.token_budget | type' "$spec") != "object" ]]; then
            echo "[TYPE ERROR] $(basename $spec): token_budget not object"
        fi

        # Check priority is string
        if [[ $(jq -r '.priority | type' "$spec") != "string" ]]; then
            echo "[TYPE ERROR] $(basename $spec): priority not string"
        fi
    fi
done
```

### 6. Find Encoding Issues

```bash
# Check for non-UTF8 characters
for file in $COMMIT_RELAY_HOME/coordination/*.json; do
    if file "$file" | grep -v "UTF-8\|ASCII"; then
        echo "[ENCODING] $file"
    fi
done

# Find files with unusual characters
grep -l $'\x00' $COMMIT_RELAY_HOME/coordination/*.json
```

---

## Resolution Steps

### Fix Malformed JSON

#### Identify Error Location

```bash
FILE="$COMMIT_RELAY_HOME/coordination/task-queue.json"

# Show error details
jq . "$FILE" 2>&1

# Common errors:
# - Trailing comma
# - Missing quotes
# - Unescaped characters
```

#### Manual Fix

```bash
# Edit file to fix syntax
# Backup first
cp "$FILE" "${FILE}.backup"

# Common fixes:
# - Remove trailing commas
# - Add missing brackets
# - Escape special characters
```

#### Restore from Backup

```bash
# If backup exists
cp "${FILE}.backup" "$FILE"

# Or from git
git checkout -- "$FILE"
```

### Fix Empty Files

```bash
# Initialize empty JSON file with default structure
FILE="$COMMIT_RELAY_HOME/coordination/task-queue.json"

if [[ ! -s "$FILE" ]] || ! jq empty "$FILE" 2>/dev/null; then
    echo '{"tasks": []}' > "$FILE"
    echo "Initialized: $FILE"
fi

# Initialize worker spec
SPEC="$COMMIT_RELAY_HOME/coordination/worker-specs/active/worker-001.json"
if [[ ! -s "$SPEC" ]]; then
    rm -f "$SPEC"  # Remove invalid file
fi
```

### Fix Missing Fields

```bash
# Add missing required fields to worker specs
for spec in $COMMIT_RELAY_HOME/coordination/worker-specs/active/worker-*.json; do
    if [[ -f "$spec" ]]; then
        # Add status if missing
        if [[ $(jq -r '.status // "null"' "$spec") == "null" ]]; then
            jq '.status = "unknown"' "$spec" > /tmp/spec.json && mv /tmp/spec.json "$spec"
        fi

        # Add token_budget if missing
        if [[ $(jq -r '.token_budget // "null"' "$spec") == "null" ]]; then
            jq '.token_budget = {"allocated": 50000, "used": 0}' "$spec" > /tmp/spec.json && mv /tmp/spec.json "$spec"
        fi
    fi
done
```

### Fix Type Mismatches

```bash
# Convert string numbers to integers
jq '.token_budget.allocated = (.token_budget.allocated | tonumber)' "$spec" > /tmp/spec.json && \
mv /tmp/spec.json "$spec"

# Convert null to empty string
jq '.description = (.description // "")' "$spec" > /tmp/spec.json && \
mv /tmp/spec.json "$spec"
```

### Fix JSONL Files

```bash
# Remove invalid lines from JSONL
FILE="$COMMIT_RELAY_HOME/coordination/dashboard-events.jsonl"
TEMP=$(mktemp)

while IFS= read -r line; do
    if echo "$line" | jq empty 2>/dev/null; then
        echo "$line"
    fi
done < "$FILE" > "$TEMP"

mv "$TEMP" "$FILE"
echo "Cleaned invalid lines from $FILE"
```

### Fix Encoding

```bash
# Convert to UTF-8
FILE="$COMMIT_RELAY_HOME/coordination/task-queue.json"
iconv -f ISO-8859-1 -t UTF-8 "$FILE" > "${FILE}.utf8"
mv "${FILE}.utf8" "$FILE"
```

---

## Prevention

### Add Validation to Write Operations

```bash
# Before writing JSON, validate it
write_json() {
    local file="$1"
    local content="$2"

    # Validate
    if echo "$content" | jq empty 2>/dev/null; then
        echo "$content" > "$file"
        return 0
    else
        echo "Invalid JSON, not writing" >&2
        return 1
    fi
}
```

### Use Atomic Writes

```bash
# Write to temp then move
write_atomic() {
    local file="$1"
    local content="$2"
    local temp="${file}.tmp.$$"

    echo "$content" > "$temp"
    if jq empty "$temp" 2>/dev/null; then
        mv "$temp" "$file"
    else
        rm -f "$temp"
        return 1
    fi
}
```

### Regular Validation

```bash
# Add to crontab
0 * * * * $COMMIT_RELAY_HOME/scripts/validate-data.sh >> /tmp/validation.log

# validate-data.sh:
#!/bin/bash
for file in $COMMIT_RELAY_HOME/coordination/*.json; do
    if ! jq empty "$file" 2>/dev/null; then
        echo "$(date): Invalid JSON: $file"
        ./scripts/emit-event.sh --type "data_quality_alert" --message "Invalid: $file"
    fi
done
```

### Schema Validation

```bash
# Use JSON Schema validation (requires ajv-cli)
# npm install -g ajv-cli

# Create schema
cat > $COMMIT_RELAY_HOME/coordination/schemas/worker-spec.json << 'EOF'
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["worker_id", "worker_type", "status"],
  "properties": {
    "worker_id": {"type": "string"},
    "worker_type": {"type": "string"},
    "status": {"type": "string", "enum": ["pending", "running", "idle", "completed", "failed", "zombie"]}
  }
}
EOF

# Validate
ajv validate -s schemas/worker-spec.json -d worker-specs/active/worker-001.json
```

---

## Data Quality Checks

### Comprehensive Validation Script

```bash
#!/bin/bash
# scripts/validate-data.sh

echo "=== Data Quality Check ==="
echo "Date: $(date)"
echo ""

ERRORS=0

# Check JSON files
echo "Checking JSON files..."
for file in $(find $COMMIT_RELAY_HOME/coordination -name "*.json"); do
    if ! jq empty "$file" 2>/dev/null; then
        echo "  [FAIL] $file"
        ((ERRORS++))
    fi
done

# Check JSONL files
echo "Checking JSONL files..."
for file in $(find $COMMIT_RELAY_HOME/coordination -name "*.jsonl"); do
    LINE=0
    while IFS= read -r line; do
        ((LINE++))
        if ! echo "$line" | jq empty 2>/dev/null; then
            echo "  [FAIL] $file:$LINE"
            ((ERRORS++))
        fi
    done < "$file"
done

# Check required fields
echo "Checking worker specs..."
for spec in $COMMIT_RELAY_HOME/coordination/worker-specs/*/worker-*.json; do
    if [[ -f "$spec" ]]; then
        if [[ $(jq -r '.worker_id // "null"' "$spec") == "null" ]]; then
            echo "  [FAIL] $spec: missing worker_id"
            ((ERRORS++))
        fi
    fi
done

echo ""
echo "Total errors: $ERRORS"
exit $ERRORS
```

---

## Verification

After fixes:

```bash
# 1. Re-validate all files
./scripts/validate-data.sh

# 2. Test system operations
cat $COMMIT_RELAY_HOME/coordination/task-queue.json | jq '.tasks | length'

# 3. Create test task
./scripts/create-task.sh --description "Data quality test" --priority low

# 4. Check logs for errors
grep -i "json\|parse\|invalid" $COMMIT_RELAY_HOME/agents/logs/system/*.log | tail -10
```

---

## Related Runbooks

- [Governance Operations](./governance-operations.md)
- [Observability Debugging](./observability-debugging.md)
- [Emergency Recovery](./emergency-recovery.md)

---

**Last Updated**: 2025-11-21
