#!/bin/bash
# scripts/install-agents.sh
# Install commit-relay agents to make them available in Claude Code

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PROJECT_AGENTS_DIR="$COMMIT_RELAY_HOME/.claude/agents"
USER_AGENTS_DIR="$HOME/.claude/agents"

echo "╔════════════════════════════════════════════════════╗"
echo "║  Commit-Relay Agent Installation                   ║"
echo "╚════════════════════════════════════════════════════╝"
echo ""

# Ensure user agents directory exists
mkdir -p "$USER_AGENTS_DIR"
echo "✅ User agents directory: $USER_AGENTS_DIR"

# Verify project agents exist
if [ ! -d "$PROJECT_AGENTS_DIR" ]; then
    echo "❌ ERROR: Project agents directory not found: $PROJECT_AGENTS_DIR"
    exit 1
fi

echo "✅ Project agents directory: $PROJECT_AGENTS_DIR"
echo ""

# Count agents
AGENT_COUNT=$(find "$PROJECT_AGENTS_DIR" -name "*.md" -type f | wc -l | tr -d ' ')
echo "Found $AGENT_COUNT agents to install:"
echo ""

# List and validate each agent
for agent_file in "$PROJECT_AGENTS_DIR"/*.md; do
    if [ -f "$agent_file" ]; then
        agent_name=$(basename "$agent_file" .md)

        # Validate YAML frontmatter
        if ! grep -q "^---$" "$agent_file"; then
            echo "  ❌ $agent_name - Missing YAML frontmatter"
            continue
        fi

        if ! grep -q "^name:" "$agent_file"; then
            echo "  ❌ $agent_name - Missing 'name' field"
            continue
        fi

        if ! grep -q "^description:" "$agent_file"; then
            echo "  ❌ $agent_name - Missing 'description' field"
            continue
        fi

        echo "  ✅ $agent_name"
    fi
done

echo ""
echo "╔════════════════════════════════════════════════════╗"
echo "║  Installation Complete                             ║"
echo "╚════════════════════════════════════════════════════╝"
echo ""
echo "📍 Project agents location: $PROJECT_AGENTS_DIR"
echo "📍 Working directory: $COMMIT_RELAY_HOME"
echo ""
echo "🔍 To view agents in Claude Code:"
echo "   1. Ensure you're in the commit-relay directory"
echo "   2. Run: /agents"
echo ""
echo "💡 Agents are automatically discovered from .claude/agents/"
echo "   No additional installation steps needed!"
echo ""
echo "📝 Available agents:"
for agent_file in "$PROJECT_AGENTS_DIR"/*.md; do
    if [ -f "$agent_file" ]; then
        agent_name=$(basename "$agent_file" .md)
        description=$(grep "^description:" "$agent_file" | cut -d':' -f2- | sed 's/^ *//')
        echo "   • $agent_name"
        echo "     $description" | fold -s -w 60 | sed 's/^/     /'
        echo ""
    fi
done
