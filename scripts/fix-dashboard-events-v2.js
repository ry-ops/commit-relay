#!/usr/bin/env node

const fs = require('fs');
const path = require('path');

const inputFile = path.join(__dirname, '..', 'coordination', 'dashboard-events.jsonl');
const outputFile = path.join(__dirname, '..', 'coordination', 'dashboard-events-clean.jsonl');

console.log('Fixing dashboard-events.jsonl format (v2)...');

try {
  const content = fs.readFileSync(inputFile, 'utf-8');
  const lines = content.split('\n');

  const events = [];
  let currentEvent = null;
  let inEvent = false;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();

    // Skip empty lines
    if (!line) continue;

    // Start of a new event
    if (line === '{') {
      currentEvent = {};
      inEvent = true;
      continue;
    }

    // End of event
    if (line === '}' && inEvent) {
      if (currentEvent && currentEvent.id && currentEvent.timestamp && currentEvent.type) {
        events.push(currentEvent);
      }
      currentEvent = null;
      inEvent = false;
      continue;
    }

    // Parse event properties
    if (inEvent && currentEvent) {
      // Handle id field
      if (line.startsWith('"id":')) {
        const match = line.match(/"id":\s*"([^"]+)"/);
        if (match) currentEvent.id = match[1];
      }
      // Handle timestamp field
      else if (line.startsWith('"timestamp":')) {
        const match = line.match(/"timestamp":\s*"([^"]+)"/);
        if (match) currentEvent.timestamp = match[1];
      }
      // Handle type field
      else if (line.startsWith('"type":')) {
        const match = line.match(/"type":\s*"([^"]+)"/);
        if (match) currentEvent.type = match[1];
      }
      // Handle data field (with malformed extra brace)
      else if (line.startsWith('"data":')) {
        // Extract JSON object from data field, handling the extra }
        const dataStr = line.substring(line.indexOf('{'));
        // Remove trailing comma and extra }
        const cleanDataStr = dataStr.replace(/}}[,]?$/, '}');
        try {
          currentEvent.data = JSON.parse(cleanDataStr);
        } catch (e) {
          // If parsing fails, store as string
          currentEvent.data = cleanDataStr;
        }
      }
      // Handle source field (sometimes appears outside the object)
      else if (line.startsWith('"source":')) {
        const match = line.match(/"source":\s*"([^"]+)"/);
        if (match) currentEvent.source = match[1];
      }
    }
  }

  console.log(`Parsed ${events.length} events`);

  // Write as proper JSONL (one JSON object per line)
  const jsonlContent = events.map(event => JSON.stringify(event)).join('\n');
  fs.writeFileSync(outputFile, jsonlContent + '\n');

  console.log(`Successfully converted ${events.length} events to JSONL format`);
  console.log(`Output written to: dashboard-events-clean.jsonl`);

  // Show sample of converted data
  console.log('\nSample of converted events:');
  events.slice(0, 3).forEach(event => {
    console.log(`  - ${event.id}: ${event.type} at ${event.timestamp}`);
  });

  // Backup original and replace with clean version
  console.log('\nBacking up original file...');
  fs.copyFileSync(inputFile, inputFile + '.backup');
  fs.copyFileSync(outputFile, inputFile);
  console.log('Original file backed up and replaced with clean version');

} catch (error) {
  console.error('Fatal error:', error);
  process.exit(1);
}