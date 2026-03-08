#!/bin/bash
# Start Agent Gateway Server

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATEWAY_DIR="$SCRIPT_DIR/../llm-mesh/gateway"

echo "Starting Commit-Relay Agent Gateway..."

# Check Node.js
if ! command -v node &> /dev/null; then
    echo "Error: Node.js not found"
    exit 1
fi

# Set defaults
export GATEWAY_PORT="${GATEWAY_PORT:-3001}"
export NODE_ENV="${NODE_ENV:-development}"

cd "$GATEWAY_DIR"
exec node server.js
