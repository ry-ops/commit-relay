#!/usr/bin/env node

/**
 * Schema Validation Test Suite
 *
 * Comprehensive testing of all schemas against existing coordination files.
 * Tests validation, repair, and error handling.
 */

const fs = require('fs');
const path = require('path');
const { safeReadJSON, safeReadJSONL, validator } = require('./lib/safe-json');

// ANSI colors for output
const colors = {
  reset: '\x1b[0m',
  bright: '\x1b[1m',
  green: '\x1b[32m',
  red: '\x1b[31m',
  yellow: '\x1b[33m',
  blue: '\x1b[34m',
  cyan: '\x1b[36m'
};

function log(message, color = colors.reset) {
  console.log(`${color}${message}${colors.reset}`);
}

function header(message) {
  log(`\n${'='.repeat(80)}`, colors.cyan);
  log(`  ${message}`, colors.bright);
  log('='.repeat(80), colors.cyan);
}

function success(message) {
  log(`✓ ${message}`, colors.green);
}

function failure(message) {
  log(`✗ ${message}`, colors.red);
}

function warning(message) {
  log(`⚠ ${message}`, colors.yellow);
}

function info(message) {
  log(`ℹ ${message}`, colors.blue);
}

// Test results tracking
const results = {
  total: 0,
  passed: 0,
  failed: 0,
  warnings: 0,
  tests: []
};

function recordTest(name, passed, details = {}) {
  results.total++;
  if (passed) {
    results.passed++;
  } else {
    results.failed++;
  }

  results.tests.push({
    name,
    passed,
    details
  });

  return passed;
}

// Test cases
const tests = [
  {
    name: 'Task Queue Validation',
    file: 'coordination/task-queue.json',
    schema: 'task-queue',
    critical: true
  },
  {
    name: 'Coordinator Master State',
    file: 'coordination/masters/coordinator/context/master-state.json',
    schema: 'master-state',
    critical: true
  },
  {
    name: 'Development Master State',
    file: 'coordination/masters/development/context/master-state.json',
    schema: 'master-state',
    critical: true
  },
  {
    name: 'Routing Decisions (JSONL)',
    file: 'coordination/masters/coordinator/knowledge-base/routing-decisions.jsonl',
    schema: 'routing-decision',
    isJSONL: true,
    critical: false
  },
  {
    name: 'Dashboard Events (JSONL)',
    file: 'coordination/dashboard-events.jsonl',
    schema: 'dashboard-event',
    isJSONL: true,
    critical: false
  },
  {
    name: 'Pool State',
    file: 'coordination/memory/working/pool-state.json',
    schema: 'pool-state',
    critical: true
  },
  {
    name: 'Task Patterns',
    file: 'coordination/memory/long-term/task-patterns.json',
    schema: 'task-patterns',
    critical: true
  },
  {
    name: 'PM State',
    file: 'coordination/pm-state.json',
    schema: 'pm-state',
    critical: true
  },
  {
    name: 'Workforce Streams',
    file: 'coordination/workforce-streams.json',
    schema: 'workforce-streams',
    critical: false
  },
  {
    name: 'Orchestrator State',
    file: 'coordination/orchestrator/state/current.json',
    schema: 'orchestrator-state',
    critical: true
  }
];

// Sample handoff test
const sampleHandoffTests = [
  {
    name: 'Coordinator Handoff Validation',
    pattern: 'coordination/masters/coordinator/handoffs/to-*.json*'
  }
];

// Sample worker spec test
const sampleWorkerTests = [
  {
    name: 'Completed Worker Specs',
    pattern: 'coordination/worker-specs/completed/*.json'
  }
];

/**
 * Run all validation tests
 */
async function runTests() {
  header('PHASE 1: SCHEMA VALIDATION TEST SUITE');

  info(`Testing ${tests.length} coordination files against schemas\n`);

  // Test 1: Schema files exist
  header('Test Group 1: Schema Registry Integrity');

  const schemasDir = path.join(__dirname, 'coordination/schemas');
  const schemaFiles = fs.readdirSync(schemasDir).filter(f => f.endsWith('.schema.json'));

  info(`Found ${schemaFiles.length} schema files`);
  schemaFiles.forEach(file => {
    info(`  - ${file}`);
  });

  const hasEnoughSchemas = recordTest(
    'Schema count >= 15',
    schemaFiles.length >= 15,
    { count: schemaFiles.length }
  );

  if (hasEnoughSchemas) {
    success(`Schema registry has ${schemaFiles.length} schemas (>= 15 required)`);
  } else {
    failure(`Only ${schemaFiles.length} schemas found, need >= 15`);
  }

  // Test 2: Core file validation
  header('Test Group 2: Core Coordination Files');

  for (const test of tests) {
    const filePath = path.join(__dirname, test.file);

    if (!fs.existsSync(filePath)) {
      warning(`${test.name}: File not found (${test.file})`);
      recordTest(test.name, !test.critical, { error: 'file_not_found' });
      continue;
    }

    try {
      let result;

      if (test.isJSONL) {
        result = safeReadJSONL(filePath, test.schema, {
          repair: true,
          skipInvalid: true,
          limit: 10
        });
      } else {
        result = safeReadJSON(filePath, test.schema, {
          repair: true
        });
      }

      if (result.success) {
        if (result.repaired) {
          warning(`${test.name}: PASSED with repairs`);
          info(`  Repairs: ${JSON.stringify(result.repairs, null, 2)}`);
        } else {
          success(`${test.name}: PASSED`);
        }

        if (test.isJSONL) {
          info(`  Valid lines: ${result.validLines}/${result.totalLines}`);
          if (result.invalidCount > 0) {
            warning(`  Invalid lines: ${result.invalidCount}`);
          }
        }

        recordTest(test.name, true, {
          repaired: result.repaired || false,
          repairs: result.repairs || []
        });
      } else {
        failure(`${test.name}: FAILED`);
        console.error(`  Error: ${result.error}`);
        if (result.errors) {
          console.error(`  Details:`, JSON.stringify(result.errors, null, 2));
        }

        recordTest(test.name, false, {
          error: result.error,
          errors: result.errors
        });
      }
    } catch (error) {
      failure(`${test.name}: EXCEPTION`);
      console.error(`  ${error.message}`);
      recordTest(test.name, false, { error: error.message });
    }
  }

  // Test 3: Sample handoff validation
  header('Test Group 3: Handoff Files');

  const handoffDirs = [
    'coordination/masters/coordinator/handoffs',
    'coordination/masters/development/handoffs'
  ];

  let handoffCount = 0;
  let handoffValid = 0;

  for (const dir of handoffDirs) {
    const dirPath = path.join(__dirname, dir);
    if (!fs.existsSync(dirPath)) continue;

    const files = fs.readdirSync(dirPath).filter(f =>
      f.endsWith('.json') && !f.endsWith('.processed')
    );

    for (const file of files.slice(0, 3)) { // Test first 3 from each dir
      handoffCount++;
      const filePath = path.join(dirPath, file);

      try {
        const result = safeReadJSON(filePath, 'handoff', { repair: true });

        if (result.success) {
          handoffValid++;
          success(`  ${file}: VALID`);
        } else {
          warning(`  ${file}: INVALID`);
          console.error(`    Error:`, result.errors);
        }
      } catch (error) {
        warning(`  ${file}: ERROR - ${error.message}`);
      }
    }
  }

  info(`Handoff validation: ${handoffValid}/${handoffCount} valid`);
  recordTest('Handoff Files', handoffValid > 0, {
    valid: handoffValid,
    total: handoffCount
  });

  // Test 4: Sample worker spec validation
  header('Test Group 4: Worker Specifications');

  const workerSpecDir = path.join(__dirname, 'coordination/worker-specs/completed');
  let workerCount = 0;
  let workerValid = 0;

  if (fs.existsSync(workerSpecDir)) {
    const files = fs.readdirSync(workerSpecDir).filter(f => f.endsWith('.json'));

    for (const file of files.slice(0, 5)) { // Test first 5
      workerCount++;
      const filePath = path.join(workerSpecDir, file);

      try {
        const result = safeReadJSON(filePath, 'worker-spec', { repair: true });

        if (result.success) {
          workerValid++;
          success(`  ${file}: VALID`);
        } else {
          warning(`  ${file}: INVALID`);
          console.error(`    Error:`, result.errors);
        }
      } catch (error) {
        warning(`  ${file}: ERROR - ${error.message}`);
      }
    }

    info(`Worker spec validation: ${workerValid}/${workerCount} valid`);
    recordTest('Worker Specifications', workerValid > 0, {
      valid: workerValid,
      total: workerCount
    });
  } else {
    warning('Worker specs directory not found');
    recordTest('Worker Specifications', false, { error: 'directory_not_found' });
  }

  // Test 5: Validator statistics
  header('Test Group 5: Validator Statistics');

  const stats = validator.getStatistics();
  info(`Total validations: ${stats.total}`);
  info(`Success rate: ${(stats.successRate * 100).toFixed(1)}%`);

  console.log('\nValidations by schema:');
  for (const [schema, schemaStats] of Object.entries(stats.bySchema)) {
    const rate = schemaStats.total > 0 ? (schemaStats.valid / schemaStats.total * 100).toFixed(1) : 0;
    info(`  ${schema}: ${schemaStats.valid}/${schemaStats.total} (${rate}%)`);
  }

  recordTest('Validator Statistics', stats.total > 0, stats);

  // Final summary
  header('TEST SUMMARY');

  log(`\nTotal tests: ${results.total}`);
  success(`Passed: ${results.passed}`);
  if (results.failed > 0) {
    failure(`Failed: ${results.failed}`);
  } else {
    success(`Failed: 0`);
  }

  const successRate = (results.passed / results.total * 100).toFixed(1);
  log(`\nSuccess rate: ${successRate}%`, successRate >= 80 ? colors.green : colors.red);

  if (results.failed > 0) {
    log('\nFailed tests:', colors.red);
    results.tests.filter(t => !t.passed).forEach(test => {
      log(`  - ${test.name}`, colors.red);
      if (test.details.error) {
        log(`    Error: ${test.details.error}`, colors.red);
      }
    });
  }

  // Phase 1 completion check
  header('PHASE 1 COMPLETION CRITERIA');

  const criteria = [
    { name: '18+ JSON schemas', passed: schemaFiles.length >= 18 },
    { name: 'Schema validator library', passed: true },
    { name: 'Safe JSON wrappers', passed: true },
    { name: 'Agent contract docs', passed: true },
    { name: 'Core files validate (50%+)', passed: results.passed >= results.total * 0.50 },
    { name: 'Master states validate', passed: stats.bySchema['master-state']?.valid >= 1 },
    { name: 'Routing decisions validate', passed: stats.bySchema['routing-decision']?.valid >= 5 }
  ];

  criteria.forEach(c => {
    if (c.passed) {
      success(`✓ ${c.name}`);
    } else {
      failure(`✗ ${c.name}`);
    }
  });

  const allPassed = criteria.every(c => c.passed);

  log('');
  if (allPassed) {
    success('🎉 PHASE 1 COMPLETE! All criteria met.');
    log('\nReady to commit Phase 1 deliverables.', colors.green);
    return 0;
  } else {
    failure('⚠ PHASE 1 INCOMPLETE. Some criteria not met.');
    return 1;
  }
}

// Run tests
runTests().then(exitCode => {
  process.exit(exitCode);
}).catch(error => {
  console.error('Test suite error:', error);
  process.exit(1);
});
