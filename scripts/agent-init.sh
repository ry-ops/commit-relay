#!/bin/bash
# Initialize a new agent in the commit-relay system

set -e

if [ -z "$1" ]; then
  echo "Usage: ./agent-init.sh <agent-name>"
  echo "Example: ./agent-init.sh pr-management-agent"
  exit 1
fi

AGENT_NAME=$1
DATE=$(date +"%Y-%m-%dT%H:%M:%S%z")

cd ~/commit-relay

echo "Initializing new agent: $AGENT_NAME"

# Create log directory
mkdir -p "agents/logs/$AGENT_NAME"
echo "✅ Created log directory"

# Create initial log file
cat > "agents/logs/$AGENT_NAME/$(date +%Y-%m-%d).md" <<EOF
# $AGENT_NAME - Activity Log
## Date: $(date +%Y-%m-%d)

### $(date +%H:%M) - Agent Initialized
**Status**: Created and ready for first check-in

Agent $AGENT_NAME has been initialized and is ready to join the commit-relay system.

---
EOF
echo "✅ Created initial log file"

# Update agent registry
# Note: This requires manual editing of agents/configs/agent-registry.json
# to move the agent from planned_agents to active agents

echo "✅ Agent $AGENT_NAME initialized"
echo ""
echo "Next steps:"
echo "1. Review agent prompt at agents/prompts/$AGENT_NAME.md"
echo "2. Update agents/configs/agent-registry.json (move from planned to active)"
echo "3. Update coordination/status.json to include agent"
echo "4. Start Claude Code session with agent prompt"
echo ""
