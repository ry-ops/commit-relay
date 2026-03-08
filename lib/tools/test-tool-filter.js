#!/usr/bin/env node

/**
 * CLI Tool for Testing Tool Filter
 *
 * Usage:
 *   node test-tool-filter.js implementation-worker
 *   node test-tool-filter.js --summary
 *   node test-tool-filter.js --validate
 *   node test-tool-filter.js --check implementation-worker Read
 */

const { ToolFilter } = require('./tool-filter');

async function main() {
  const args = process.argv.slice(2);

  if (args.length === 0 || args[0] === '--help' || args[0] === '-h') {
    printUsage();
    process.exit(0);
  }

  const filter = new ToolFilter();
  await filter.initialize();

  // Handle different commands
  if (args[0] === '--summary' || args[0] === '-s') {
    await showSummary(filter);
  } else if (args[0] === '--validate' || args[0] === '-v') {
    await validateConfig(filter);
  } else if (args[0] === '--check' || args[0] === '-c') {
    await checkAccess(filter, args[1], args[2]);
  } else if (args[0] === '--metrics' || args[0] === '-m') {
    await showMetrics(filter);
  } else {
    // Show tools for specific worker
    await showWorkerTools(filter, args[0]);
  }
}

async function showWorkerTools(filter, workerType) {
  console.log(`=== Tool Assignment for ${workerType} ===\n`);

  try {
    const toolSet = await filter.getToolsForWorker(workerType);

    if (!toolSet.filtered) {
      console.log('⚠️  No specific assignment found. Using all tools.\n');
      return;
    }

    console.log(`Rationale: ${toolSet.rationale}\n`);

    console.log('Essential Clusters:');
    toolSet.essential_clusters.forEach(cluster => {
      const clusterInfo = filter.getCluster(cluster);
      console.log(`  • ${cluster}`);
      console.log(`    ${clusterInfo.description}`);
      console.log(`    Tools: ${clusterInfo.tools.join(', ')}`);
    });

    console.log('\nEssential Tools:');
    toolSet.essential_tools.forEach(tool => {
      console.log(`  ✓ ${tool}`);
    });

    if (toolSet.optional_tools.length > 0) {
      console.log('\nOptional Clusters:');
      toolSet.optional_clusters.forEach(cluster => {
        const clusterInfo = filter.getCluster(cluster);
        console.log(`  • ${cluster}`);
        console.log(`    ${clusterInfo.description}`);
        console.log(`    Tools: ${clusterInfo.tools.join(', ')}`);
      });

      console.log('\nOptional Tools:');
      toolSet.optional_tools.forEach(tool => {
        console.log(`  ~ ${tool}`);
      });
    }

    console.log(`\nTotal Tools: ${toolSet.total_tools} (Essential: ${toolSet.essential_tools.length}, Optional: ${toolSet.optional_tools.length})`);

    // Show reduction
    const allToolsCount = 19; // Average before clustering
    const reduction = ((allToolsCount - toolSet.total_tools) / allToolsCount * 100).toFixed(1);
    console.log(`Tool Reduction: ${reduction}% (${allToolsCount} → ${toolSet.total_tools})`);
  } catch (error) {
    console.error(`Error: ${error.message}`);
    process.exit(1);
  }
}

async function showSummary(filter) {
  console.log('=== Tool Filter Summary ===\n');

  try {
    const summary = await filter.generateSummary();

    console.log(`Total Clusters: ${summary.total_clusters}`);
    console.log(`Total Worker Types: ${summary.total_worker_types}\n`);

    console.log('Worker Assignments:\n');
    for (const [workerType, assignment] of Object.entries(summary.worker_assignments)) {
      console.log(`${workerType}:`);
      console.log(`  Total Tools: ${assignment.total_tools}`);
      console.log(`  Essential: ${assignment.essential_tools} tools from ${assignment.essential_clusters.length} clusters`);
      console.log(`  Optional: ${assignment.optional_tools} tools from ${assignment.optional_clusters.length} clusters`);
      console.log(`  Rationale: ${assignment.rationale}`);
      console.log('');
    }

    console.log('Optimization Metrics:');
    const opt = summary.optimization_metrics;
    console.log(`  Before clustering: ${opt.tool_reduction.before} tools per worker`);
    console.log(`  After clustering: ${opt.tool_reduction.after_clustering} tools per worker (avg)`);
    console.log(`  Reduction: ${opt.reduction_percent}%`);
    console.log(`  Expected latency improvement: ${opt.expected_latency_improvement}`);
    console.log(`  Token usage reduction: ${opt.token_usage_reduction}`);

    if (summary.current_metrics.total_filters > 0) {
      console.log('\nCurrent Session Metrics:');
      console.log(`  Total filters applied: ${summary.current_metrics.total_filters}`);
      console.log(`  Avg tools before: ${summary.current_metrics.avg_tools_before}`);
      console.log(`  Avg tools after: ${summary.current_metrics.avg_tools_after}`);
      console.log(`  Reduction: ${summary.current_metrics.reduction_percent}%`);
    }
  } catch (error) {
    console.error(`Error: ${error.message}`);
    process.exit(1);
  }
}

async function validateConfig(filter) {
  console.log('=== Validating Tool Filter Configuration ===\n');

  const validation = filter.validateConfig();

  if (validation.valid) {
    console.log('✓ Configuration is valid\n');
  } else {
    console.log('✗ Configuration has errors\n');
  }

  if (validation.errors.length > 0) {
    console.log('Errors:');
    validation.errors.forEach(error => {
      console.log(`  ✗ ${error}`);
    });
    console.log('');
  }

  if (validation.warnings.length > 0) {
    console.log('Warnings:');
    validation.warnings.forEach(warning => {
      console.log(`  ⚠️  ${warning}`);
    });
    console.log('');
  }

  if (validation.valid && validation.warnings.length === 0) {
    console.log('No issues found.');
  }

  process.exit(validation.valid ? 0 : 1);
}

async function checkAccess(filter, workerType, toolName) {
  if (!workerType || !toolName) {
    console.error('Error: Both worker type and tool name required');
    console.error('Usage: node test-tool-filter.js --check implementation-worker Read');
    process.exit(1);
  }

  console.log(`=== Tool Access Check ===\n`);
  console.log(`Worker: ${workerType}`);
  console.log(`Tool: ${toolName}\n`);

  try {
    const access = await filter.checkToolAccess(workerType, toolName);

    if (access.allowed) {
      console.log(`✓ Access GRANTED`);
      console.log(`  Level: ${access.access_level}`);
    } else {
      console.log(`✗ Access DENIED`);
      console.log(`  Level: ${access.access_level}`);
    }

    // Show which clusters contain this tool
    const clusters = filter.getClustersForTool(toolName);
    if (clusters.length > 0) {
      console.log(`\nTool belongs to clusters:`);
      clusters.forEach(cluster => {
        const clusterInfo = filter.getCluster(cluster);
        console.log(`  • ${cluster}: ${clusterInfo.description}`);
      });
    } else {
      console.log(`\n⚠️  Tool not found in any cluster`);
    }
  } catch (error) {
    console.error(`Error: ${error.message}`);
    process.exit(1);
  }
}

async function showMetrics(filter) {
  console.log('=== Tool Filter Metrics ===\n');

  const metrics = filter.getMetrics();

  if (metrics.total_filters === 0) {
    console.log('No filters applied yet in this session.');
    return;
  }

  console.log(`Total filters applied: ${metrics.total_filters}`);
  console.log(`Average tools before filtering: ${metrics.avg_tools_before}`);
  console.log(`Average tools after filtering: ${metrics.avg_tools_after}`);
  console.log(`Average reduction: ${metrics.reduction_percent}%`);
}

function printUsage() {
  console.log(`
Tool Filter Testing Tool

Usage:
  node test-tool-filter.js <worker-type>
      Show tool assignment for a specific worker type

  node test-tool-filter.js --summary
      Show summary of all worker assignments and metrics

  node test-tool-filter.js --validate
      Validate tool filter configuration

  node test-tool-filter.js --check <worker-type> <tool-name>
      Check if a specific tool is allowed for a worker

  node test-tool-filter.js --metrics
      Show current session metrics

Examples:
  node test-tool-filter.js implementation-worker
  node test-tool-filter.js --summary
  node test-tool-filter.js --validate
  node test-tool-filter.js --check implementation-worker Read
  `.trim());
}

// Run main
main().catch(error => {
  console.error('Fatal error:', error.message);
  console.error(error.stack);
  process.exit(1);
});
