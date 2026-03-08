#!/bin/bash
# deploy-ml-router.sh
# Deploy ML-enhanced router for A/B testing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Configuration
AB_TEST_PERCENTAGE="${AB_TEST_PERCENTAGE:-0.1}"  # 10% traffic to ML by default
ENABLE_NEURAL="${ENABLE_NEURAL:-false}"          # Neural routing disabled until model trained
ENABLE_RAG="${ENABLE_RAG:-true}"                 # RAG enabled

# Paths
MODEL_PATH="${PROJECT_ROOT}/llm-mesh/models/routing/current"
VECTORSTORE_PATH="${PROJECT_ROOT}/llm-mesh/vectors/codebase-test"

echo "🚀 Deploying ML-Enhanced Router"
echo "================================"
echo "Configuration:"
echo "  - A/B Test %: ${AB_TEST_PERCENTAGE}"
echo "  - Neural Routing: ${ENABLE_NEURAL}"
echo "  - RAG: ${ENABLE_RAG}"
echo ""

# Create deployment config
DEPLOY_CONFIG="${PROJECT_ROOT}/llm-mesh/config/deployment.json"
mkdir -p "$(dirname "$DEPLOY_CONFIG")"

cat > "$DEPLOY_CONFIG" <<EOF
{
  "version": "1.0.0",
  "deployment_date": "$(date -Iseconds)",
  "configuration": {
    "ab_test_percentage": ${AB_TEST_PERCENTAGE},
    "enable_neural": ${ENABLE_NEURAL},
    "enable_rag": ${ENABLE_RAG},
    "model_path": "${MODEL_PATH}",
    "vectorstore_path": "${VECTORSTORE_PATH}"
  },
  "status": "deployed"
}
EOF

echo "✅ Deployment configuration saved to: $DEPLOY_CONFIG"

# Verify vector store exists
if [ "$ENABLE_RAG" = "true" ]; then
    if [ ! -d "$VECTORSTORE_PATH" ]; then
        echo "⚠️  Vector store not found at: $VECTORSTORE_PATH"
        echo "   Creating vector store from codebase..."

        cd "$PROJECT_ROOT"
        source python-sdk/.venv/bin/activate
        python3 llm-mesh/scripts/rag/create-vectorstore.py \
            --source . \
            --output "$VECTORSTORE_PATH" \
            --chunk-size 500

        echo "✅ Vector store created"
    else
        echo "✅ Vector store found: $VECTORSTORE_PATH"
    fi
fi

# Create monitoring script
MONITOR_SCRIPT="${PROJECT_ROOT}/llm-mesh/scripts/integration/monitor-ml-router.sh"

cat > "$MONITOR_SCRIPT" <<'EOF'
#!/bin/bash
# Monitor ML router performance

METRICS_FILE="${COMMIT_RELAY_HOME:-/Users/ryandahlberg/Projects/commit-relay}/coordination/metrics/ml-router-metrics.jsonl"

echo "📊 ML Router Metrics"
echo "===================="

if [ -f "$METRICS_FILE" ]; then
    total_routes=$(wc -l < "$METRICS_FILE")
    ml_routes=$(grep -c '"method":"ml"' "$METRICS_FILE" || echo 0)
    rule_routes=$(grep -c '"method":"rule-based"' "$METRICS_FILE" || echo 0)

    echo "Total routes: $total_routes"
    echo "ML routes: $ml_routes"
    echo "Rule-based routes: $rule_routes"

    if [ "$total_routes" -gt 0 ]; then
        ml_percentage=$(echo "scale=2; $ml_routes * 100 / $total_routes" | bc)
        echo "ML percentage: ${ml_percentage}%"
    fi
else
    echo "No metrics found yet"
fi
EOF

chmod +x "$MONITOR_SCRIPT"

echo "✅ Monitoring script created: $MONITOR_SCRIPT"
echo ""
echo "🎯 Deployment Summary"
echo "===================="
echo "1. Configuration saved"
echo "2. Vector store ready"
echo "3. Monitoring enabled"
echo ""
echo "Next steps:"
echo "  - Monitor: $MONITOR_SCRIPT"
echo "  - Adjust A/B %: export AB_TEST_PERCENTAGE=0.25 && $0"
echo "  - Full rollout: export AB_TEST_PERCENTAGE=1.0 && $0"
echo ""
echo "✅ Deployment complete!"
