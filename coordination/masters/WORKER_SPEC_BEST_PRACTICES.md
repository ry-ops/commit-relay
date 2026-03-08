# Worker Spec Generation Best Practices

## Critical: Prevent Malformed JSON

**Problem**: Master agents have been generating worker specs with missing values, causing worker daemon failures.

**Bad Pattern**:
```json
{
  "context": {
    "skills_required": ,   ← INVALID! Missing value
  },
  "resources": {
    "token_allocation": ,  ← INVALID! Missing value
  }
}
```

## Required: Always Use Default Values

**When creating worker specs, ALWAYS initialize all fields with default values BEFORE constructing JSON.**

### Good Pattern 1: Initialize Variables First

```bash
# Initialize with defaults
SKILLS_REQUIRED="${SKILLS_REQUIRED:-[]}"
TOKEN_ALLOCATION="${TOKEN_ALLOCATION:-50000}"
EXPERTISE_AREA="${EXPERTISE_AREA:-\"\"}"

# Then construct JSON
worker_spec=$(cat <<EOF
{
  "worker_id": "$WORKER_ID",
  "context": {
    "expertise_area": $EXPERTISE_AREA,
    "skills_required": $SKILLS_REQUIRED
  },
  "resources": {
    "token_allocation": $TOKEN_ALLOCATION
  }
}
EOF
)
```

###Good Pattern 2: Use jq with Explicit Defaults

```bash
worker_spec=$(jq -n \
  --arg worker_id "$WORKER_ID" \
  --argjson skills_required "${SKILLS_REQUIRED:-[]}" \
  --argjson token_allocation "${TOKEN_ALLOCATION:-50000}" \
  '{
    worker_id: $worker_id,
    context: {
      skills_required: $skills_required
    },
    resources: {
      token_allocation: $token_allocation
    }
  }')
```

### Good Pattern 3: Use Validation Wrapper

**ALWAYS use the validation wrapper when writing worker specs:**

```bash
# Instead of writing directly:
echo "$worker_spec" > "coordination/worker-specs/active/$WORKER_ID.json"

# Use the validation wrapper:
./scripts/validate-and-write-worker-spec.sh \
  "$worker_spec" \
  "coordination/worker-specs/active/$WORKER_ID.json"
```

## Required Worker Spec Fields

Every worker spec MUST include:

```json
{
  "worker_id": "string (required)",
  "worker_type": "string (required)",
  "task_id": "string (required)",
  "context": {
    "skills_required": [],  ← MUST be array, not null
    "expertise_area": ""    ← MUST be string (can be empty)
  },
  "resources": {
    "token_allocation": 50000  ← MUST be number, not null
  },
  "status": "pending"  ← MUST be one of: pending|running|completed|failed
}
```

## Validation Checklist

Before writing any worker spec to disk:

1. ✓ All required fields are present
2. ✓ `skills_required` is an array (use `[]` if empty)
3. ✓ `token_allocation` is a number (default: 50000)
4. ✓ `expertise_area` is a string (use `""` if empty)
5. ✓ `status` is a valid enum value
6. ✓ No fields have missing values (`, ,` pattern)
7. ✓ JSON is syntactically valid (test with `jq empty`)

## Testing Your Worker Spec

```bash
# Test for malformed JSON
if ! jq empty "$worker_spec_file" 2>/dev/null; then
  echo "ERROR: Malformed JSON in worker spec"
  exit 1
fi

# Test for schema compliance
if ! ./scripts/lib/json-validator.sh validate-worker-spec "$worker_spec_file"; then
  echo "ERROR: Worker spec does not meet schema requirements"
  exit 1
fi
```

## Incident History

- **2025-11-11**: 10 worker specs generated with `"skills_required": ,` and `"token_allocation": ,`
- **Impact**: 100% worker spawn failure rate, complete system paralysis
- **Root Cause**: Uninitialized variables in JSON generation
- **Resolution**: Manual repair with sed, but root cause persists

## Action Items

1. **CRITICAL**: Always initialize variables before JSON construction
2. **HIGH**: Use validation wrapper for all worker spec writes
3. **MEDIUM**: Test worker specs with jq before writing to disk

---

**Last Updated**: 2025-11-11
**Owned By**: All Master Agents
**Compliance Level**: MANDATORY
