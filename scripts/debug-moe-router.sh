#!/bin/bash
# Debug MoE Router keyword matching

TASK="Phase 1 validation of v5.0 Hybrid RAG+CAG: Scan commit-relay repository to validate CAG performance claims"
TASK_LOWER=$(echo "$TASK" | tr '[:upper:]' '[:lower:]')

echo "Task description: $TASK"
echo ""
echo "Task lowercase: $TASK_LOWER"
echo ""

echo "Testing security activation keywords:"
for kw in vulnerability security CVE audit scan exploit patch secure harden compliance secrets; do
    if echo "$TASK_LOWER" | grep -qw "$kw"; then
        echo "  ✓ '$kw' - MATCH"
    else
        echo "  ✗ '$kw' - NO MATCH"
    fi
done

echo ""
echo "Testing security confidence boosters:"
for kw in attack threat malicious injection dependency "npm audit" OWASP "security scan"; do
    if echo "$TASK_LOWER" | grep -qw "$kw"; then
        echo "  ✓ '$kw' - MATCH"
    else
        echo "  ✗ '$kw' - NO MATCH"
    fi
done

echo ""
echo "Testing development activation keywords:"
for kw in implement add create build develop fix bug refactor optimize improve enhance update; do
    if echo "$TASK_LOWER" | grep -qw "$kw"; then
        echo "  ✓ '$kw' - MATCH"
    else
        echo "  ✗ '$kw' - NO MATCH"
    fi
done
