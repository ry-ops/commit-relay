#!/usr/bin/env node

/**
 * CLI Tool for Testing Semantic Router
 *
 * Usage:
 *   node test-semantic-router.js "Fix authentication bug"
 *   node test-semantic-router.js --ab-test "Implement JWT authentication"
 *   node test-semantic-router.js --report
 *   node test-semantic-router.js --batch tests/routing-tests.json
 */

const { SemanticRouter } = require('../../lib/routing/semantic-router');
const { ABTestRouter } = require('../../lib/routing/ab-test-router');
const fs = require('fs').promises;

async function main() {
  const args = process.argv.slice(2);

  if (args.length === 0 || args[0] === '--help' || args[0] === '-h') {
    printUsage();
    process.exit(0);
  }

  // Handle different commands
  if (args[0] === '--report' || args[0] === '-r') {
    await generateReport();
  } else if (args[0] === '--batch' || args[0] === '-b') {
    await runBatchTest(args[1]);
  } else if (args[0] === '--ab-test' || args[0] === '--ab') {
    await runABTest(args.slice(1).join(' '));
  } else if (args[0] === '--stats') {
    await showStats();
  } else {
    // Single task routing
    await routeTask(args.join(' '));
  }
}

async function routeTask(taskDescription) {
  console.log('=== Semantic Routing Test ===\n');
  console.log(`Task: "${taskDescription}"\n`);

  const router = new SemanticRouter();
  await router.initialize();

  const task = { description: taskDescription };
  const result = await router.route(task);

  console.log('Routing Result:');
  console.log(`  Master: ${result.master}`);
  console.log(`  Method: ${result.method}`);
  console.log(`  Confidence: ${result.confidence.toFixed(3)} (${result.confidence_level || 'N/A'})`);

  if (result.alternatives && result.alternatives.length > 0) {
    console.log('\nAlternatives:');
    result.alternatives.forEach((alt, i) => {
      console.log(`  ${i + 1}. ${alt.master}: ${alt.confidence.toFixed(3)}`);
    });
  }

  if (result.method.includes('fallback')) {
    console.log('\n⚠️  Fell back to keyword routing');
    if (result.semantic_confidence) {
      console.log(`   Semantic confidence was too low: ${result.semantic_confidence.toFixed(3)}`);
    }
  }

  console.log('\nMetrics:');
  const metrics = router.getMetrics();
  console.log(`  Total routes: ${metrics.total_routes}`);
  console.log(`  Semantic routes: ${metrics.semantic_routes}`);
  console.log(`  Keyword fallbacks: ${metrics.keyword_fallbacks}`);
  console.log(`  Avg confidence: ${metrics.avg_confidence}`);
  console.log(`  Semantic rate: ${metrics.semantic_rate_percent}%`);
}

async function runABTest(taskDescription) {
  console.log('=== A/B Test: Semantic vs Keyword Routing ===\n');
  console.log(`Task: "${taskDescription}"\n`);

  const router = new ABTestRouter({ testEnabled: true, sampleRate: 1.0 });
  await router.initialize();

  const task = { description: taskDescription };
  await router.route(task);

  console.log('\nA/B Test Results:');
  const metrics = router.getMetrics();
  console.log(`  Total tests: ${metrics.total_tests}`);
  console.log(`  Agreements: ${metrics.agreements}`);
  console.log(`  Disagreements: ${metrics.disagreements}`);
  console.log(`  Agreement rate: ${metrics.agreement_rate}`);
  console.log(`  Semantic win rate: ${metrics.semantic_win_rate}`);
  console.log(`  Avg semantic confidence: ${metrics.avg_semantic_confidence}`);
  console.log(`  Avg keyword confidence: ${metrics.avg_keyword_confidence}`);
}

async function runBatchTest(filePath) {
  if (!filePath) {
    console.error('Error: Batch file path required');
    console.error('Usage: node test-semantic-router.js --batch tests/routing-tests.json');
    process.exit(1);
  }

  console.log('=== Batch Routing Test ===\n');
  console.log(`Loading tasks from: ${filePath}\n`);

  try {
    const data = await fs.readFile(filePath, 'utf8');
    const tasks = JSON.parse(data);

    if (!Array.isArray(tasks)) {
      throw new Error('Batch file must contain an array of tasks');
    }

    const router = new SemanticRouter();
    await router.initialize();

    console.log(`Testing ${tasks.length} tasks...\n`);

    const results = [];
    for (let i = 0; i < tasks.length; i++) {
      const task = tasks[i];
      console.log(`[${i + 1}/${tasks.length}] "${task.description.substring(0, 50)}..."`);

      const result = await router.route(task);
      results.push({
        task: task.description,
        master: result.master,
        confidence: result.confidence,
        method: result.method
      });

      console.log(`  → ${result.master} (${result.confidence.toFixed(3)})`);
    }

    // Summary
    console.log('\n=== Summary ===');
    const metrics = router.getMetrics();
    console.log(`Total tasks: ${tasks.length}`);
    console.log(`Semantic routes: ${metrics.semantic_routes} (${metrics.semantic_rate_percent}%)`);
    console.log(`Keyword fallbacks: ${metrics.keyword_fallbacks}`);
    console.log(`Avg confidence: ${metrics.avg_confidence}`);

    // Master distribution
    const masterCounts = {};
    results.forEach(r => {
      masterCounts[r.master] = (masterCounts[r.master] || 0) + 1;
    });

    console.log('\nMaster distribution:');
    Object.entries(masterCounts)
      .sort((a, b) => b[1] - a[1])
      .forEach(([master, count]) => {
        console.log(`  ${master}: ${count} (${(count / tasks.length * 100).toFixed(1)}%)`);
      });
  } catch (error) {
    console.error(`Error running batch test: ${error.message}`);
    process.exit(1);
  }
}

async function generateReport() {
  console.log('=== A/B Test Report ===\n');

  const router = new ABTestRouter();
  await router.initialize();

  const report = await router.generateReport();

  if (report.error) {
    console.log(`Error: ${report.error}`);
    console.log('\nCurrent metrics:');
    console.log(JSON.stringify(report, null, 2));
    return;
  }

  console.log(`Total A/B tests: ${report.total_tests}`);
  console.log(`Agreement rate: ${report.agreement_rate}%`);
  console.log(`Semantic win rate: ${report.semantic_win_rate}%`);
  console.log('\nSemantic routing confidence:');
  console.log(`  Average: ${report.semantic_confidence.avg}`);
  console.log(`  Range: ${report.semantic_confidence.min} - ${report.semantic_confidence.max}`);
  console.log('\nKeyword routing confidence:');
  console.log(`  Average: ${report.keyword_confidence.avg}`);
  console.log(`  Range: ${report.keyword_confidence.min} - ${report.keyword_confidence.max}`);

  if (report.disagreement_examples && report.disagreement_examples.length > 0) {
    console.log('\nDisagreement examples:');
    report.disagreement_examples.forEach((ex, i) => {
      console.log(`\n${i + 1}. "${ex.task}"`);
      console.log(`   Semantic: ${ex.semantic_choice} (${ex.semantic_confidence})`);
      console.log(`   Keyword:  ${ex.keyword_choice} (${ex.keyword_confidence})`);
    });
  }
}

async function showStats() {
  console.log('=== Routing Statistics ===\n');

  const semanticRouter = new SemanticRouter();
  await semanticRouter.initialize();

  // Get embedding cache stats
  const cacheStats = await semanticRouter.embeddingGenerator.getCacheStats();

  console.log('Embedding Cache:');
  console.log(`  Total entries: ${cacheStats.total_entries}`);
  console.log(`  Cache size: ${cacheStats.cache_size_mb} MB`);

  if (cacheStats.by_type) {
    console.log('  By type:');
    Object.entries(cacheStats.by_type).forEach(([type, count]) => {
      console.log(`    ${type}: ${count}`);
    });
  }

  if (cacheStats.oldest_entry) {
    const oldestDate = new Date(cacheStats.oldest_entry);
    const newestDate = new Date(cacheStats.newest_entry);
    console.log(`  Oldest entry: ${oldestDate.toLocaleString()}`);
    console.log(`  Newest entry: ${newestDate.toLocaleString()}`);
  }

  // Get router metrics
  const routerMetrics = semanticRouter.getMetrics();
  console.log('\nRouter Metrics:');
  console.log(`  Total routes: ${routerMetrics.total_routes}`);
  console.log(`  Semantic routes: ${routerMetrics.semantic_routes}`);
  console.log(`  Keyword fallbacks: ${routerMetrics.keyword_fallbacks}`);
  console.log(`  Semantic rate: ${routerMetrics.semantic_rate_percent}%`);
}

function printUsage() {
  console.log(`
Semantic Router Testing Tool

Usage:
  node test-semantic-router.js <task-description>
      Route a single task using semantic routing

  node test-semantic-router.js --ab-test <task-description>
      Run A/B test comparing semantic and keyword routing

  node test-semantic-router.js --batch <file.json>
      Test multiple tasks from a JSON file

  node test-semantic-router.js --report
      Generate A/B test report from collected data

  node test-semantic-router.js --stats
      Show embedding cache and routing statistics

Examples:
  node test-semantic-router.js "Fix authentication bug"
  node test-semantic-router.js --ab-test "Implement JWT authentication"
  node test-semantic-router.js --batch tests/routing-tests.json
  node test-semantic-router.js --report
  `.trim());
}

// Run main
main().catch(error => {
  console.error('Fatal error:', error.message);
  console.error(error.stack);
  process.exit(1);
});
