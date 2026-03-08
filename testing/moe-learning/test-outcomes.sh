#!/bin/bash
# Create test outcomes for MoE learning validation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRACKER="$SCRIPT_DIR/evaluators/outcome-tracker.sh"

echo "Creating test outcomes..."

# Test 1: Security task - routed correctly, high quality
echo "1. Security CVE scan (perfect routing)"
bash "$TRACKER" task-test-001 completed 0.95

# Test 2: Development task - routed correctly, good quality
echo "2. Development API implementation (perfect routing)"
bash "$TRACKER" task-test-002 completed 0.90

# Test 3: Inventory task - routed correctly, good quality
echo "3. Inventory documentation (perfect routing)"
bash "$TRACKER" task-test-003 completed 0.85

# Test 4: Bug fix - routed to development but LOW confidence (should learn!)
echo "4. Bug fix (poor confidence - needs learning)"
bash "$TRACKER" task-test-004 completed 0.90

# Test 5: Comprehensive audit - LOW confidence, should have been multi-expert
echo "5. Comprehensive audit (should be multi-expert - needs learning)"
bash "$TRACKER" task-test-005 completed 0.70

echo ""
echo "Test outcomes created successfully!"
echo "Run './moe-learn.sh learn' to analyze and learn from these outcomes."
