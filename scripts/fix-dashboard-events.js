#!/usr/bin/env node

const fs = require('fs');
const path = require('path');

const inputFile = path.join(__dirname, '..', 'coordination', 'dashboard-events.jsonl');
const outputFile = path.join(__dirname, '..', 'coordination', 'dashboard-events-fixed.jsonl');

console.log('Fixing dashboard-events.jsonl format...');

try {
  const content = fs.readFileSync(inputFile, 'utf-8');

  // Split into potential JSON objects by looking for pattern: }\n{
  const chunks = content.split(/}\s*\n\s*{/);

  const events = [];
  let errorCount = 0;
  let incompleteCount = 0;

  chunks.forEach((chunk, index) => {
    // Add back the braces we split on (except first and last)
    let jsonStr = chunk;
    if (index > 0) jsonStr = '{' + jsonStr;
    if (index < chunks.length - 1) jsonStr = jsonStr + '}';

    // Clean up any remaining issues
    jsonStr = jsonStr.trim();

    // Skip empty chunks
    if (!jsonStr || jsonStr.length < 10) {
      return;
    }

    try {
      const event = JSON.parse(jsonStr);

      // Validate required fields
      if (!event.id || !event.timestamp || !event.type) {
        console.log(`Skipping incomplete event at chunk ${index}: missing required fields`);
        incompleteCount++;
        return;
      }

      events.push(event);
    } catch (e) {
      // Try to detect if it's just an incomplete entry at the end
      if (index === chunks.length - 1 && !jsonStr.includes('"id"')) {
        console.log('Skipping incomplete last entry');
        incompleteCount++;
      } else {
        console.error(`Error parsing chunk ${index}:`, e.message);
        console.log('First 100 chars:', jsonStr.substring(0, 100));
        errorCount++;
      }
    }
  });

  // Write as proper JSONL (one JSON object per line)
  const jsonlContent = events.map(event => JSON.stringify(event)).join('\n');
  fs.writeFileSync(outputFile, jsonlContent + '\n');

  console.log(`Successfully converted ${events.length} events to JSONL format`);
  console.log(`Skipped ${incompleteCount} incomplete entries`);
  console.log(`Encountered ${errorCount} parsing errors`);
  console.log(`Output written to: dashboard-events-fixed.jsonl`);

  // Show sample of converted data
  console.log('\nSample of converted events:');
  events.slice(-3).forEach(event => {
    console.log(`  - ${event.id}: ${event.type} at ${event.timestamp}`);
  });

} catch (error) {
  console.error('Fatal error:', error);
  process.exit(1);
}