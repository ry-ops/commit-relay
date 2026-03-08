#!/usr/bin/env node

/**
 * Simple Circuit Breaker Tests (No Framework Required)
 *
 * Basic tests that verify core functionality without requiring Mocha or Jest
 */

const { CircuitBreaker, CircuitState, createCircuitBreaker } = require('../lib/circuit-breaker');

// Test utilities
let testsPassed = 0;
let testsFailed = 0;

function assert(condition, message) {
  if (!condition) {
    throw new Error(`Assertion failed: ${message}`);
  }
}

function assertEqual(actual, expected, message) {
  if (actual !== expected) {
    throw new Error(`${message}: expected ${expected}, got ${actual}`);
  }
}

async function runTest(name, testFn) {
  process.stdout.write(`  ${name} ... `);
  try {
    await testFn();
    console.log('✓ PASS');
    testsPassed++;
  } catch (error) {
    console.log('✗ FAIL');
    console.log(`    Error: ${error.message}`);
    testsFailed++;
  }
}

function delay(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

// Mock action creators
function createMockAction(options = {}) {
  const { failCount = 0, delay = 0 } = options;
  let callCount = 0;

  return async () => {
    callCount++;

    if (delay > 0) {
      await new Promise(resolve => setTimeout(resolve, delay));
    }

    if (callCount <= failCount) {
      throw new Error('Mock failure');
    }

    return { success: true, callCount };
  };
}

// Test Suite
async function runAllTests() {
  console.log('\n=== Circuit Breaker Simple Tests ===\n');

  // Test 1: Initialization
  await runTest('Should initialize with CLOSED state', async () => {
    const action = createMockAction();
    const breaker = new CircuitBreaker(action);
    assertEqual(breaker.getState(), CircuitState.CLOSED, 'Initial state');
  });

  // Test 2: Successful execution
  await runTest('Should execute action successfully', async () => {
    const action = createMockAction();
    const breaker = new CircuitBreaker(action);
    const result = await breaker.execute();
    assert(result.success, 'Action should succeed');
  });

  // Test 3: Record failure
  await runTest('Should record failures', async () => {
    const action = createMockAction({ failCount: 1 });
    const breaker = new CircuitBreaker(action, { failureThreshold: 10 });

    try {
      await breaker.execute();
    } catch (error) {
      // Expected
    }

    const metrics = breaker.getMetrics();
    assertEqual(metrics.totalFailures, 1, 'Failure count');
  });

  // Test 4: Transition to OPEN
  await runTest('Should transition to OPEN after threshold', async () => {
    const action = createMockAction({ failCount: 10 });
    const breaker = new CircuitBreaker(action, {
      failureThreshold: 5,
      failureWindow: 60000
    });

    for (let i = 0; i < 5; i++) {
      try {
        await breaker.execute();
      } catch (error) {
        // Expected
      }
    }

    assertEqual(breaker.getState(), CircuitState.OPEN, 'State after failures');
  });

  // Test 5: Reject when OPEN
  await runTest('Should reject calls when OPEN', async () => {
    const action = createMockAction({ failCount: 10 });
    const breaker = new CircuitBreaker(action, {
      failureThreshold: 3,
      openTimeout: 5000
    });

    // Open the circuit
    for (let i = 0; i < 3; i++) {
      try {
        await breaker.execute();
      } catch (error) {
        // Expected
      }
    }

    // Try to call while OPEN
    try {
      await breaker.execute();
      throw new Error('Should have thrown CIRCUIT_OPEN error');
    } catch (error) {
      assertEqual(error.code, 'CIRCUIT_OPEN', 'Error code');
    }
  });

  // Test 6: Transition to HALF_OPEN
  await runTest('Should transition to HALF_OPEN after timeout', async () => {
    const action = createMockAction({ failCount: 3 }); // Will succeed after 3 failures
    const breaker = new CircuitBreaker(action, {
      failureThreshold: 3,
      openTimeout: 100,
      successThreshold: 2
    });

    // Open the circuit
    for (let i = 0; i < 3; i++) {
      try {
        await breaker.execute();
      } catch (error) {
        // Expected
      }
    }

    // Wait for timeout
    await delay(150);

    // Next call should transition to HALF_OPEN and succeed
    await breaker.execute();

    // Should be in HALF_OPEN or CLOSED (depending on success threshold)
    const state = breaker.getState();
    assert(
      state === CircuitState.HALF_OPEN || state === CircuitState.CLOSED,
      `State should be HALF_OPEN or CLOSED, got ${state}`
    );
  });

  // Test 7: Recover to CLOSED
  await runTest('Should recover to CLOSED after successes', async () => {
    const action = createMockAction({ failCount: 3 });
    const breaker = new CircuitBreaker(action, {
      failureThreshold: 3,
      openTimeout: 100,
      successThreshold: 2
    });

    // Open the circuit
    for (let i = 0; i < 3; i++) {
      try {
        await breaker.execute();
      } catch (error) {
        // Expected
      }
    }

    // Wait for timeout
    await delay(150);

    // Execute successful calls
    await breaker.execute();
    await breaker.execute();

    assertEqual(breaker.getState(), CircuitState.CLOSED, 'State after recovery');
  });

  // Test 8: Track metrics
  await runTest('Should track call metrics', async () => {
    const action = createMockAction({ failCount: 2 });
    const breaker = new CircuitBreaker(action, { failureThreshold: 10 });

    // 2 failures
    try { await breaker.execute(); } catch {}
    try { await breaker.execute(); } catch {}

    // 3 successes
    await breaker.execute();
    await breaker.execute();
    await breaker.execute();

    const metrics = breaker.getMetrics();
    assertEqual(metrics.totalCalls, 5, 'Total calls');
    assertEqual(metrics.totalSuccesses, 3, 'Successes');
    assertEqual(metrics.totalFailures, 2, 'Failures');
  });

  // Test 9: Force close
  await runTest('Should allow force close', async () => {
    const action = createMockAction({ failCount: 10 });
    const breaker = new CircuitBreaker(action, { failureThreshold: 1 });

    // Open circuit
    try {
      await breaker.execute();
    } catch {}

    assertEqual(breaker.getState(), CircuitState.OPEN, 'State before force close');

    breaker.forceClose();
    assertEqual(breaker.getState(), CircuitState.CLOSED, 'State after force close');
  });

  // Test 10: Create with helper
  await runTest('Should create breaker with createCircuitBreaker', async () => {
    const action = createMockAction();
    const breaker = createCircuitBreaker(action, { name: 'test' });

    assert(breaker instanceof CircuitBreaker, 'Instance type');
    assertEqual(breaker.config.name, 'test', 'Config name');
  });

  // Test 11: State transitions
  await runTest('Should track state transitions', async () => {
    const action = createMockAction({ failCount: 3 });
    const breaker = new CircuitBreaker(action, {
      failureThreshold: 3,
      openTimeout: 100,
      successThreshold: 2
    });

    // Open circuit
    for (let i = 0; i < 3; i++) {
      try { await breaker.execute(); } catch {}
    }

    // Wait and recover
    await delay(150);
    await breaker.execute();
    await breaker.execute();

    const metrics = breaker.getMetrics();
    assert(metrics.stateTransitions.length >= 2, 'Should have transitions');

    const hasOpenTransition = metrics.stateTransitions.some(
      t => t.from === 'CLOSED' && t.to === 'OPEN'
    );
    assert(hasOpenTransition, 'Should have CLOSED->OPEN transition');
  });

  // Test 12: Failure window
  await runTest('Should respect failure time window', async () => {
    const action = createMockAction({ failCount: 10 });
    const breaker = new CircuitBreaker(action, {
      failureThreshold: 5,
      failureWindow: 200
    });

    // 3 failures
    for (let i = 0; i < 3; i++) {
      try { await breaker.execute(); } catch {}
    }

    // Wait for window to expire
    await delay(250);

    // This failure should be outside the window
    try { await breaker.execute(); } catch {}

    // Should still be CLOSED because old failures expired
    assertEqual(breaker.getState(), CircuitState.CLOSED, 'State after window expiry');
  });

  // Print results
  console.log('\n=== Test Results ===');
  console.log(`Passed: ${testsPassed}`);
  console.log(`Failed: ${testsFailed}`);
  console.log(`Total:  ${testsPassed + testsFailed}\n`);

  return testsFailed === 0;
}

// Run tests if executed directly
if (require.main === module) {
  runAllTests()
    .then(success => {
      process.exit(success ? 0 : 1);
    })
    .catch(error => {
      console.error('Test suite failed:', error);
      process.exit(1);
    });
}

module.exports = { runAllTests };
