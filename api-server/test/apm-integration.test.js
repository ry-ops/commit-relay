/**
 * Elastic APM Integration Tests
 *
 * Tests the APM integration including initialization, custom events,
 * exception tracking, and instrumentation.
 */

const assert = require('assert');
const path = require('path');
const fs = require('fs');

console.log('\n=== Elastic APM Integration Tests ===\n');

// Test 1: APM Module Initialization
console.log('Test 1: APM Module Initialization');
try {
  // Save original env
  const originalEnv = process.env.ELASTIC_APM_ENABLED;

  // Test with APM disabled
  process.env.ELASTIC_APM_ENABLED = 'false';
  delete require.cache[require.resolve('../apm')];
  const apmDisabled = require('../apm');
  assert.strictEqual(apmDisabled, null, 'APM should be null when disabled');
  console.log('  ✅ APM correctly disabled when ELASTIC_APM_ENABLED=false');

  // Restore env
  process.env.ELASTIC_APM_ENABLED = originalEnv;
  delete require.cache[require.resolve('../apm')];

  console.log('✅ Test 1 passed\n');
} catch (error) {
  console.error('❌ Test 1 failed:', error.message);
  process.exit(1);
}

// Test 2: APM Events Module
console.log('Test 2: APM Events Module');
try {
  const apmEvents = require('../server/utils/apm-events');

  // Check all required functions are exported
  assert.strictEqual(typeof apmEvents.trackAgentEvent, 'function',
    'trackAgentEvent should be a function');
  assert.strictEqual(typeof apmEvents.trackToolUsage, 'function',
    'trackToolUsage should be a function');
  assert.strictEqual(typeof apmEvents.trackRelayCompletion, 'function',
    'trackRelayCompletion should be a function');
  assert.strictEqual(typeof apmEvents.withCustomSpan, 'function',
    'withCustomSpan should be a function');
  assert.strictEqual(typeof apmEvents.captureException, 'function',
    'captureException should be a function');
  assert.strictEqual(typeof apmEvents.setUser, 'function',
    'setUser should be a function');
  assert.strictEqual(typeof apmEvents.addLabels, 'function',
    'addLabels should be a function');
  assert.strictEqual(typeof apmEvents.getTransactionId, 'function',
    'getTransactionId should be a function');
  assert.strictEqual(typeof apmEvents.getTraceId, 'function',
    'getTraceId should be a function');

  console.log('  ✅ All APM event functions are exported');
  console.log('✅ Test 2 passed\n');
} catch (error) {
  console.error('❌ Test 2 failed:', error.message);
  process.exit(1);
}

// Test 3: Custom Event Tracking (with APM disabled)
console.log('Test 3: Custom Event Tracking (graceful degradation)');
try {
  const {
    trackAgentEvent,
    trackToolUsage,
    trackRelayCompletion,
    captureException
  } = require('../server/utils/apm-events');

  // These should not throw errors even when APM is disabled
  trackAgentEvent('test', {
    agentId: 'test-agent',
    agentType: 'test-worker',
    taskId: 'test-task'
  });

  trackToolUsage('test-tool', {
    operation: 'test-op',
    status: 'success'
  });

  trackRelayCompletion('test-task', {
    status: 'success',
    duration: 1000
  });

  captureException(new Error('Test error'), {
    operation: 'test'
  });

  console.log('  ✅ Custom events handle APM being disabled gracefully');
  console.log('✅ Test 3 passed\n');
} catch (error) {
  console.error('❌ Test 3 failed:', error.message);
  process.exit(1);
}

// Test 4: withCustomSpan (with APM disabled)
console.log('Test 4: withCustomSpan Execution');
try {
  const { withCustomSpan } = require('../server/utils/apm-events');

  // Test synchronous function
  let executedSync = false;
  const syncResult = 'sync-result';

  const resultSync = withCustomSpan('test-span', 'custom', () => {
    executedSync = true;
    return syncResult;
  });

  assert.strictEqual(executedSync, true, 'Sync function should execute');

  // Test async function
  (async () => {
    let executedAsync = false;
    const asyncResult = 'async-result';

    const resultAsync = await withCustomSpan('test-span-async', 'custom', async () => {
      executedAsync = true;
      return asyncResult;
    });

    assert.strictEqual(executedAsync, true, 'Async function should execute');
    assert.strictEqual(resultAsync, asyncResult, 'Async result should match');

    console.log('  ✅ withCustomSpan executes functions correctly');
    console.log('✅ Test 4 passed\n');

    // Test 5: File Structure
    console.log('Test 5: File Structure');
    try {
      const apmFilePath = path.join(__dirname, '../apm.js');
      const apmEventsPath = path.join(__dirname, '../server/utils/apm-events.js');
      const packagePath = path.join(__dirname, '../package.json');

      assert(fs.existsSync(apmFilePath), 'apm.js should exist');
      assert(fs.existsSync(apmEventsPath), 'apm-events.js should exist');
      assert(fs.existsSync(packagePath), 'package.json should exist');

      // Check package.json has elastic-apm-node
      const packageJson = JSON.parse(fs.readFileSync(packagePath, 'utf8'));
      assert(packageJson.dependencies['elastic-apm-node'],
        'elastic-apm-node should be in dependencies');

      console.log('  ✅ All APM files exist');
      console.log('  ✅ elastic-apm-node dependency is present');
      console.log('✅ Test 5 passed\n');

      // Test 6: Documentation
      console.log('Test 6: Documentation');
      try {
        const docsPath = path.join(__dirname, '../../docs/APM-INTEGRATION.md');
        const envExamplePath = path.join(__dirname, '../../.env.example');

        assert(fs.existsSync(docsPath), 'APM-INTEGRATION.md should exist');
        assert(fs.existsSync(envExamplePath), '.env.example should exist');

        // Check .env.example has APM config
        const envExample = fs.readFileSync(envExamplePath, 'utf8');
        assert(envExample.includes('ELASTIC_APM_ENABLED'),
          '.env.example should have ELASTIC_APM_ENABLED');
        assert(envExample.includes('ELASTIC_APM_SERVER_URL'),
          '.env.example should have ELASTIC_APM_SERVER_URL');
        assert(envExample.includes('ELASTIC_APM_SECRET_TOKEN'),
          '.env.example should have ELASTIC_APM_SECRET_TOKEN');

        console.log('  ✅ Documentation exists');
        console.log('  ✅ .env.example has APM configuration');
        console.log('✅ Test 6 passed\n');

        // All tests passed
        console.log('═══════════════════════════════════════');
        console.log('✅ All APM Integration Tests Passed!');
        console.log('═══════════════════════════════════════\n');
      } catch (error) {
        console.error('❌ Test 6 failed:', error.message);
        process.exit(1);
      }
    } catch (error) {
      console.error('❌ Test 5 failed:', error.message);
      process.exit(1);
    }
  })();
} catch (error) {
  console.error('❌ Test 4 failed:', error.message);
  process.exit(1);
}
