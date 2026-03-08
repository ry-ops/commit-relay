#!/bin/bash
# Repair existing dashboard-events.jsonl file
# This script fixes common JSON errors in the event log

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"

EVENTS_FILE="$COMMIT_RELAY_HOME/coordination/dashboard-events.jsonl"
BACKUP_FILE="$EVENTS_FILE.backup.$(date +%s)"

echo "Repairing dashboard-events.jsonl..."
echo "Creating backup: $BACKUP_FILE"

# Create backup
cp "$EVENTS_FILE" "$BACKUP_FILE"

# Use Node.js validator for more reliable repair
node <<'NODEJS_SCRIPT'
const fs = require('fs');
const path = require('path');
const validator = require(path.join(process.env.COMMIT_RELAY_HOME, 'dashboard/server/utils/json-validator.js'));

const eventsFile = path.join(process.env.COMMIT_RELAY_HOME, 'coordination/dashboard-events.jsonl');

// Read file
const content = fs.readFileSync(eventsFile, 'utf-8');
const lines = content.split('\n');

const repairedLines = [];
let repairedCount = 0;
let skippedCount = 0;

lines.forEach((line, index) => {
  const lineNum = index + 1;

  // Skip empty lines
  if (!line.trim()) {
    return;
  }

  // Try to repair line
  const result = validator.validateAndRepairJSON(line, true);
  if (result.success) {
    repairedLines.push(result.data);
    if (result.data !== line) {
      repairedCount++;
      console.log(`Line ${lineNum}: Repaired`);
    }
  } else {
    console.error(`Line ${lineNum}: Cannot repair - skipping`);
    skippedCount++;
  }
});

// Write repaired content
fs.writeFileSync(eventsFile, repairedLines.join('\n') + '\n', 'utf-8');

console.log(`\nRepair completed:`);
console.log(`  Total lines: ${lines.length}`);
console.log(`  Repaired: ${repairedCount}`);
console.log(`  Skipped: ${skippedCount}`);
console.log(`  Valid lines: ${repairedLines.length}`);

process.exit(skippedCount > 0 ? 1 : 0);
NODEJS_SCRIPT

if [ $? -eq 0 ]; then
    echo ""
    echo "Success! All lines repaired."
    echo "Backup saved to: $BACKUP_FILE"
else
    echo ""
    echo "Warning: Some lines could not be repaired and were skipped."
    echo "Backup saved to: $BACKUP_FILE"
fi
