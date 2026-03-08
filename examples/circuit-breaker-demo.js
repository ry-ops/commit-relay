#!/usr/bin/env node

/**
 * Circuit Breaker Demo
 *
 * Demonstrates the circuit breaker pattern with simulated failures and recovery.
 * This example shows:
 * 1. Normal operation (CLOSED state)
 * 2. Failure accumulation
 * 3. Circuit opening (OPEN state)
 * 4. Fast failure rejection
 * 5. Recovery testing (HALF_OPEN state)
 * 6. Successful recovery (back to CLOSED)
 */

const { CircuitBreaker, CircuitState } = require('../lib/circuit-breaker');

// Utility functions
function delay(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

function log(message, state = null) {
  const timestamp = new Date().toISOString();
  const stateStr = state ? ` [${state}]` : '';
  console.log(`${timestamp}${stateStr} - ${message}`);
}

// Simulate a flaky service that fails initially then recovers
class FlakyService {
  constructor() {
    this.callCount = 0;
    this.failureMode = true; // Start in failure mode
    this.failureCount = 0;
  }

  async call(data) {
    this.callCount++;

    // Simulate network delay
    await delay(10);

    if (this.failureMode && this.failureCount < 5) {
      this.failureCount++;
      throw new Error(`Service unavailable (failure ${this.failureCount}/5)`);
    }

    // After 5 failures, start succeeding
    this.failureMode = false;
    return {
      success: true,
      message: 'Service call succeeded',
      data,
      callNumber: this.callCount
    };
  }

  recover() {
    this.failureMode = false;
    this.failureCount = 0;
    log('Service recovered!', 'INFO');
  }
}

async function runDemo() {
  console.log('\n=== Circuit Breaker Pattern Demo ===\n');

  // Create flaky service
  const service = new FlakyService();

  // Create circuit breaker
  const breaker = new CircuitBreaker(
    (data) => service.call(data),
    {
      name: 'demo-service',
      failureThreshold: 5,
      failureWindow: 60000,
      openTimeout: 2000,    // Short timeout for demo
      successThreshold: 3
    }
  );

  log('Circuit breaker initialized', breaker.getState());
  console.log('');

  // Phase 1: Normal operation (1 call)
  console.log('--- Phase 1: Normal Operation (CLOSED) ---');
  try {
    const result = await breaker.execute({ test: 'data' });
    log(`Call failed as expected: ${result.message}`, breaker.getState());
  } catch (error) {
    log(`Call 1 failed: ${error.message}`, breaker.getState());
  }
  console.log('');

  // Phase 2: Accumulate failures
  console.log('--- Phase 2: Accumulating Failures ---');
  for (let i = 2; i <= 5; i++) {
    try {
      await breaker.execute({ test: 'data' });
    } catch (error) {
      log(`Call ${i} failed: ${error.message}`, breaker.getState());
    }
    await delay(100);
  }
  console.log('');

  // Phase 3: Circuit is now OPEN
  console.log('--- Phase 3: Circuit OPEN (Fast Failure) ---');
  log('Circuit breaker opened after threshold reached', breaker.getState());

  // Try calling - should be rejected immediately
  for (let i = 1; i <= 3; i++) {
    const startTime = Date.now();
    try {
      await breaker.execute({ test: 'data' });
    } catch (error) {
      const elapsed = Date.now() - startTime;
      log(`Call ${i} rejected (${elapsed}ms): ${error.message}`, breaker.getState());
    }
    await delay(100);
  }

  const metrics1 = breaker.getMetrics();
  log(`Rejected calls: ${metrics1.totalRejected}`, breaker.getState());
  console.log('');

  // Phase 4: Wait for timeout
  console.log('--- Phase 4: Waiting for Recovery Timeout ---');
  log('Waiting 2 seconds for circuit to enter HALF_OPEN...', breaker.getState());
  await delay(2100);

  // Service recovers after we've been waiting
  service.recover();

  console.log('--- Phase 5: Testing Recovery (HALF_OPEN) ---');
  // First call transitions to HALF_OPEN and succeeds
  try {
    const result = await breaker.execute({ test: 'data' });
    log(`Test call 1 succeeded: ${result.message}`, breaker.getState());
  } catch (error) {
    log(`Test call 1 failed: ${error.message}`, breaker.getState());
  }
  await delay(100);

  // Need 3 successes to close
  for (let i = 2; i <= 3; i++) {
    try {
      const result = await breaker.execute({ test: 'data' });
      log(`Test call ${i} succeeded: ${result.message}`, breaker.getState());
    } catch (error) {
      log(`Test call ${i} failed: ${error.message}`, breaker.getState());
    }
    await delay(100);
  }
  console.log('');

  // Phase 6: Back to normal
  console.log('--- Phase 6: Recovery Complete (CLOSED) ---');
  log('Circuit breaker closed, normal operation resumed', breaker.getState());

  // Make a few more successful calls
  for (let i = 1; i <= 3; i++) {
    try {
      const result = await breaker.execute({ test: 'data' });
      log(`Normal call ${i} succeeded`, breaker.getState());
    } catch (error) {
      log(`Normal call ${i} failed: ${error.message}`, breaker.getState());
    }
    await delay(100);
  }
  console.log('');

  // Show final metrics
  console.log('--- Final Metrics ---');
  const metrics = breaker.getMetrics();
  console.log(JSON.stringify({
    state: metrics.state,
    totalCalls: metrics.totalCalls,
    totalSuccesses: metrics.totalSuccesses,
    totalFailures: metrics.totalFailures,
    totalRejected: metrics.totalRejected,
    successRate: `${(metrics.totalSuccesses / metrics.totalCalls * 100).toFixed(2)}%`,
    stateTransitions: metrics.stateTransitions.map(t =>
      `${t.from} -> ${t.to} (${t.reason})`
    )
  }, null, 2));

  console.log('\n=== Demo Complete ===\n');
}

// Run demo
if (require.main === module) {
  runDemo().catch(error => {
    console.error('Demo failed:', error);
    process.exit(1);
  });
}

module.exports = { runDemo };
