/**
 * Circuit Breaker Tests
 *
 * Comprehensive test suite for the circuit breaker implementation
 * Tests cover:
 * - State transitions (CLOSED -> OPEN -> HALF_OPEN -> CLOSED)
 * - Failure threshold detection
 * - Success recovery
 * - Metrics tracking
 * - Edge cases and error handling
 */

const assert = require('assert');
const { CircuitBreaker, CircuitState, createCircuitBreaker } = require('../lib/circuit-breaker');

// Test helpers
function delay(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

// Mock functions
function createMockAction(options = {}) {
  const { failCount = 0, delay = 0, failOnce = false } = options;
  let callCount = 0;

  return async () => {
    callCount++;

    if (delay > 0) {
      await new Promise(resolve => setTimeout(resolve, delay));
    }

    if (failOnce && callCount === 1) {
      throw new Error('Mock failure');
    }

    if (callCount <= failCount) {
      throw new Error('Mock failure');
    }

    return { success: true, callCount };
  };
}

// Test suite
describe('Circuit Breaker', function() {
  this.timeout(10000); // Increase timeout for async tests

  describe('Initialization', function() {
    it('should initialize with CLOSED state', function() {
      const action = createMockAction();
      const breaker = new CircuitBreaker(action);

      assert.strictEqual(breaker.getState(), CircuitState.CLOSED);
    });

    it('should throw error if action is not a function', function() {
      assert.throws(() => {
        new CircuitBreaker('not a function');
      }, /must be a function/);
    });

    it('should accept custom configuration', function() {
      const action = createMockAction();
      const config = {
        failureThreshold: 10,
        failureWindow: 120000,
        name: 'custom-breaker'
      };
      const breaker = new CircuitBreaker(action, config);

      const metrics = breaker.getMetrics();
      assert.strictEqual(metrics.config.failureThreshold, 10);
      assert.strictEqual(metrics.config.failureWindow, 120000);
      assert.strictEqual(metrics.config.name, 'custom-breaker');
    });
  });

  describe('State Transitions', function() {
    it('should transition from CLOSED to OPEN after failure threshold', async function() {
      const action = createMockAction({ failCount: 10 });
      const breaker = new CircuitBreaker(action, {
        failureThreshold: 5,
        failureWindow: 60000
      });

      assert.strictEqual(breaker.getState(), CircuitState.CLOSED);

      // Trigger failures
      for (let i = 0; i < 5; i++) {
        try {
          await breaker.execute();
        } catch (error) {
          // Expected to fail
        }
      }

      assert.strictEqual(breaker.getState(), CircuitState.OPEN);
    });

    it('should transition from OPEN to HALF_OPEN after timeout', async function() {
      const action = createMockAction({ failCount: 10 });
      const breaker = new CircuitBreaker(action, {
        failureThreshold: 3,
        openTimeout: 100, // Short timeout for testing
        failureWindow: 60000
      });

      // Trigger failures to open circuit
      for (let i = 0; i < 3; i++) {
        try {
          await breaker.execute();
        } catch (error) {
          // Expected to fail
        }
      }

      assert.strictEqual(breaker.getState(), CircuitState.OPEN);

      // Wait for timeout
      await delay(150);

      // Next call should transition to HALF_OPEN
      try {
        await breaker.execute();
      } catch (error) {
        // May fail, but state should change
      }

      assert.strictEqual(breaker.getState(), CircuitState.HALF_OPEN);
    });

    it('should transition from HALF_OPEN to CLOSED after success threshold', async function() {
      const action = createMockAction({ failCount: 3 }); // Fail first 3, then succeed
      const breaker = new CircuitBreaker(action, {
        failureThreshold: 3,
        openTimeout: 100,
        successThreshold: 3,
        failureWindow: 60000
      });

      // Trigger failures to open circuit
      for (let i = 0; i < 3; i++) {
        try {
          await breaker.execute();
        } catch (error) {
          // Expected to fail
        }
      }

      assert.strictEqual(breaker.getState(), CircuitState.OPEN);

      // Wait for timeout
      await delay(150);

      // Execute successful calls
      for (let i = 0; i < 3; i++) {
        const result = await breaker.execute();
        assert.ok(result.success);
      }

      assert.strictEqual(breaker.getState(), CircuitState.CLOSED);
    });

    it('should transition from HALF_OPEN back to OPEN on failure', async function() {
      const action = createMockAction({ failCount: 10 });
      const breaker = new CircuitBreaker(action, {
        failureThreshold: 3,
        openTimeout: 100,
        failureWindow: 60000
      });

      // Open circuit
      for (let i = 0; i < 3; i++) {
        try {
          await breaker.execute();
        } catch (error) {
          // Expected to fail
        }
      }

      assert.strictEqual(breaker.getState(), CircuitState.OPEN);

      // Wait for timeout to transition to HALF_OPEN
      await delay(150);

      // Fail in HALF_OPEN state
      try {
        await breaker.execute();
      } catch (error) {
        // Expected to fail
      }

      assert.strictEqual(breaker.getState(), CircuitState.OPEN);
    });
  });

  describe('Failure Handling', function() {
    it('should reject calls immediately when OPEN', async function() {
      const action = createMockAction({ failCount: 10 });
      const breaker = new CircuitBreaker(action, {
        failureThreshold: 3,
        openTimeout: 1000,
        failureWindow: 60000
      });

      // Open circuit
      for (let i = 0; i < 3; i++) {
        try {
          await breaker.execute();
        } catch (error) {
          // Expected to fail
        }
      }

      assert.strictEqual(breaker.getState(), CircuitState.OPEN);

      // Next call should be rejected immediately
      const startTime = Date.now();
      try {
        await breaker.execute();
        assert.fail('Should have thrown error');
      } catch (error) {
        assert.strictEqual(error.code, 'CIRCUIT_OPEN');
        const elapsed = Date.now() - startTime;
        assert.ok(elapsed < 50, 'Should reject immediately, not wait for action');
      }
    });

    it('should track failures within time window', async function() {
      const action = createMockAction({ failCount: 10 });
      const breaker = new CircuitBreaker(action, {
        failureThreshold: 5,
        failureWindow: 200,
        failureWindow: 60000
      });

      // Trigger 3 failures
      for (let i = 0; i < 3; i++) {
        try {
          await breaker.execute();
        } catch (error) {
          // Expected to fail
        }
      }

      // Wait for window to expire
      await delay(250);

      // These failures should be outside the window
      try {
        await breaker.execute();
      } catch (error) {
        // Expected to fail
      }

      // Should still be CLOSED because old failures expired
      assert.strictEqual(breaker.getState(), CircuitState.CLOSED);
    });
  });

  describe('Metrics', function() {
    it('should track total calls', async function() {
      const action = createMockAction();
      const breaker = new CircuitBreaker(action);

      await breaker.execute();
      await breaker.execute();
      await breaker.execute();

      const metrics = breaker.getMetrics();
      assert.strictEqual(metrics.totalCalls, 3);
    });

    it('should track successes and failures', async function() {
      const action = createMockAction({ failCount: 2 });
      const breaker = new CircuitBreaker(action, {
        failureThreshold: 10
      });

      // 2 failures
      try { await breaker.execute(); } catch {}
      try { await breaker.execute(); } catch {}

      // 3 successes
      await breaker.execute();
      await breaker.execute();
      await breaker.execute();

      const metrics = breaker.getMetrics();
      assert.strictEqual(metrics.totalSuccesses, 3);
      assert.strictEqual(metrics.totalFailures, 2);
      assert.strictEqual(metrics.totalCalls, 5);
    });

    it('should track rejected calls when OPEN', async function() {
      const action = createMockAction({ failCount: 10 });
      const breaker = new CircuitBreaker(action, {
        failureThreshold: 3,
        openTimeout: 5000,
        failureWindow: 60000
      });

      // Open circuit
      for (let i = 0; i < 3; i++) {
        try { await breaker.execute(); } catch {}
      }

      // Try to call while OPEN
      try { await breaker.execute(); } catch {}
      try { await breaker.execute(); } catch {}

      const metrics = breaker.getMetrics();
      assert.strictEqual(metrics.totalRejected, 2);
    });

    it('should track state transitions', async function() {
      const action = createMockAction({ failCount: 3 });
      const breaker = new CircuitBreaker(action, {
        failureThreshold: 3,
        openTimeout: 100,
        successThreshold: 2,
        failureWindow: 60000
      });

      // Trigger CLOSED -> OPEN
      for (let i = 0; i < 3; i++) {
        try { await breaker.execute(); } catch {}
      }

      // Wait for OPEN -> HALF_OPEN
      await delay(150);
      try { await breaker.execute(); } catch {}

      // Trigger HALF_OPEN -> CLOSED
      await breaker.execute();
      await breaker.execute();

      const metrics = breaker.getMetrics();
      assert.ok(metrics.stateTransitions.length >= 3);

      const transitions = metrics.stateTransitions.map(t => `${t.from}->${t.to}`);
      assert.ok(transitions.includes('CLOSED->OPEN'));
      assert.ok(transitions.includes('OPEN->HALF_OPEN'));
      assert.ok(transitions.includes('HALF_OPEN->CLOSED'));
    });
  });

  describe('Manual Control', function() {
    it('should allow force close', function() {
      const action = createMockAction({ failCount: 10 });
      const breaker = new CircuitBreaker(action, {
        failureThreshold: 1
      });

      // Open circuit
      try {
        breaker.execute();
      } catch {}

      breaker.forceClose();
      assert.strictEqual(breaker.getState(), CircuitState.CLOSED);
    });

    it('should allow force open', function() {
      const action = createMockAction();
      const breaker = new CircuitBreaker(action);

      assert.strictEqual(breaker.getState(), CircuitState.CLOSED);

      breaker.forceOpen();
      assert.strictEqual(breaker.getState(), CircuitState.OPEN);
    });

    it('should reset metrics', async function() {
      const action = createMockAction();
      const breaker = new CircuitBreaker(action);

      await breaker.execute();
      await breaker.execute();

      let metrics = breaker.getMetrics();
      assert.strictEqual(metrics.totalCalls, 2);

      breaker.resetMetrics();

      metrics = breaker.getMetrics();
      assert.strictEqual(metrics.totalCalls, 0);
      assert.strictEqual(metrics.totalSuccesses, 0);
      assert.strictEqual(metrics.totalFailures, 0);
    });
  });

  describe('Helper Functions', function() {
    it('should create circuit breaker with createCircuitBreaker', function() {
      const action = createMockAction();
      const breaker = createCircuitBreaker(action, { name: 'test' });

      assert.ok(breaker instanceof CircuitBreaker);
      assert.strictEqual(breaker.config.name, 'test');
    });
  });

  describe('Error Handling', function() {
    it('should propagate errors from action', async function() {
      const action = async () => {
        const error = new Error('Custom error');
        error.code = 'CUSTOM_CODE';
        throw error;
      };
      const breaker = new CircuitBreaker(action, {
        failureThreshold: 10
      });

      try {
        await breaker.execute();
        assert.fail('Should have thrown error');
      } catch (error) {
        assert.strictEqual(error.message, 'Custom error');
        assert.strictEqual(error.code, 'CUSTOM_CODE');
      }
    });

    it('should record error details in metrics', async function() {
      const action = async () => {
        const error = new Error('Test error');
        error.code = 'TEST_CODE';
        throw error;
      };
      const breaker = new CircuitBreaker(action, {
        failureThreshold: 10
      });

      try {
        await breaker.execute();
      } catch {}

      const metrics = breaker.getMetrics();
      assert.ok(metrics.lastFailure);
      assert.strictEqual(metrics.lastFailure.error, 'Test error');
      assert.strictEqual(metrics.lastFailure.code, 'TEST_CODE');
    });
  });
});

// Run tests if executed directly
if (require.main === module) {
  console.log('Running Circuit Breaker Tests...\n');

  const Mocha = require('mocha');
  const mocha = new Mocha();

  mocha.suite.emit('pre-require', global, null, mocha);

  // Run the tests
  describe('Circuit Breaker', function() {
    // Re-export tests for mocha
    require('./circuit-breaker.test.js');
  });

  mocha.run(failures => {
    process.exitCode = failures ? 1 : 0;
  });
}

module.exports = {
  createMockAction
};
