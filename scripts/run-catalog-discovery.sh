#!/bin/bash

# Run Catalog Discovery
# Automatically discover and register all data and AI assets

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CATALOG_CLI="$PROJECT_ROOT/lib/governance/catalog-cli.js"

echo "=========================================="
echo "Unified Catalog - Asset Discovery"
echo "=========================================="
echo ""

# Check if Node.js is available
if ! command -v node &> /dev/null; then
    echo "Error: Node.js is required but not installed."
    exit 1
fi

# Run discovery
echo "Running automated asset discovery..."
echo ""

node "$CATALOG_CLI" discover

echo ""
echo "=========================================="
echo "Discovery Complete"
echo "=========================================="
echo ""

# Show statistics
node "$CATALOG_CLI" stats

echo ""
echo "To search assets:"
echo "  node $CATALOG_CLI search \"your query here\""
echo ""
echo "To view lineage:"
echo "  node $CATALOG_CLI lineage <asset_id>"
echo ""
