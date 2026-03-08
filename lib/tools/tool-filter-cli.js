#!/usr/bin/env node

/**
 * Tool Filter CLI
 *
 * Command-line interface for tool filtering that can be called from bash scripts.
 * Outputs compact JSON for easy parsing in shell scripts.
 *
 * Usage:
 *   node tool-filter-cli.js get-tools implementation-worker
 *   node tool-filter-cli.js check-access implementation-worker Read
 */

const { ToolFilter } = require('./tool-filter');

async function main() {
  const args = process.argv.slice(2);

  if (args.length === 0 || args[0] === '--help' || args[0] === '-h') {
    printUsage();
    process.exit(0);
  }

  const command = args[0];

  try {
    const filter = new ToolFilter({ silent: true });
    await filter.initialize();

    switch (command) {
      case 'get-tools':
        await getTools(filter, args[1]);
        break;
      case 'check-access':
        await checkAccess(filter, args[1], args[2]);
        break;
      case 'summary':
        await getSummary(filter);
        break;
      default:
        console.error(JSON.stringify({ error: `Unknown command: ${command}` }));
        process.exit(1);
    }
  } catch (error) {
    console.error(JSON.stringify({
      error: error.message,
      stack: error.stack
    }));
    process.exit(1);
  }
}

async function getTools(filter, workerType) {
  if (!workerType) {
    console.error(JSON.stringify({ error: 'Worker type required' }));
    process.exit(1);
  }

  const toolSet = await filter.getToolsForWorker(workerType);

  // Output compact JSON for bash parsing
  const output = {
    worker_type: toolSet.worker_type,
    essential_tools: toolSet.essential_tools,
    optional_tools: toolSet.optional_tools,
    total_tools: toolSet.total_tools,
    essential_clusters: toolSet.essential_clusters || [],
    optional_clusters: toolSet.optional_clusters || [],
    filtered: toolSet.filtered,
    rationale: toolSet.rationale || ''
  };

  console.log(JSON.stringify(output));
  process.exit(0);
}

async function checkAccess(filter, workerType, toolName) {
  if (!workerType || !toolName) {
    console.error(JSON.stringify({ error: 'Worker type and tool name required' }));
    process.exit(1);
  }

  const access = await filter.checkToolAccess(workerType, toolName);

  console.log(JSON.stringify(access));
  process.exit(access.allowed ? 0 : 1);
}

async function getSummary(filter) {
  const summary = await filter.generateSummary();

  console.log(JSON.stringify(summary));
  process.exit(0);
}

function printUsage() {
  console.log(`
Tool Filter CLI

Usage:
  node tool-filter-cli.js get-tools <worker-type>
      Get tool assignment for a worker type

  node tool-filter-cli.js check-access <worker-type> <tool-name>
      Check if a tool is allowed for a worker

  node tool-filter-cli.js summary
      Get summary of all tool assignments

Options:
  --help, -h         Show this help message

Output:
  Compact JSON output for bash parsing

Examples:
  node tool-filter-cli.js get-tools implementation-worker
  node tool-filter-cli.js check-access implementation-worker Read
  node tool-filter-cli.js summary

Exit Codes:
  0  Success
  1  Error or access denied
  `.trim());
}

// Run main
main().catch(error => {
  console.error(JSON.stringify({
    error: error.message,
    stack: error.stack
  }));
  process.exit(1);
});
