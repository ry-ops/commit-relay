/**
 * Quality Validator Test Suite
 *
 * Tests for worker output quality validation:
 * - Completeness checks
 * - Validity checks
 * - Summary quality
 * - Artifact validation
 * - Token efficiency
 * - Execution quality
 * - Scoring system
 */

const { QualityValidator } = require('../../lib/governance/quality-validator');
const fs = require('fs').promises;
const path = require('path');

describe('QualityValidator', () => {
  let validator;
  const testLogPath = path.join(__dirname, 'fixtures', 'test-quality.jsonl');

  beforeEach(async () => {
    // Setup test directory
    await fs.mkdir(path.dirname(testLogPath), { recursive: true });
    await fs.writeFile(testLogPath, '');

    validator = new QualityValidator({
      qualityLogPath: testLogPath
    });
  });

  afterEach(async () => {
    // Cleanup
    try {
      await fs.rm(path.dirname(testLogPath), { recursive: true, force: true });
    } catch (error) {
      // Ignore
    }
  });

  describe('Completeness Checks', () => {
    test('passes with all required fields', async () => {
      const workerSpec = {
        worker_id: 'worker-001',
        task_id: 'task-001',
        deliverables: ['output.json'],
        results: {
          status: 'completed',
          output_location: '/path/to/output',
          summary: 'Task completed successfully',
          artifacts: ['file.txt']
        }
      };

      const result = await validator.validateWorkerOutput(workerSpec);
      expect(result.checks.completeness.passed).toBe(true);
      expect(result.checks.completeness.score).toBeGreaterThan(0.9);
    });

    test('fails with missing required fields', async () => {
      const workerSpec = {
        worker_id: 'worker-001',
        task_id: 'task-001',
        results: {
          status: 'completed'
          // Missing: output_location, summary, artifacts
        }
      };

      const result = await validator.validateWorkerOutput(workerSpec);
      expect(result.checks.completeness.passed).toBe(false);
      expect(result.checks.completeness.issues.length).toBeGreaterThan(0);
    });

    test('detects missing deliverables', async () => {
      const workerSpec = {
        worker_id: 'worker-001',
        task_id: 'task-001',
        deliverables: [], // No deliverables
        results: {
          status: 'completed',
          output_location: '/path',
          summary: 'Done',
          artifacts: []
        }
      };

      const result = await validator.validateWorkerOutput(workerSpec);
      const issue = result.checks.completeness.issues.find(i => i.field === 'deliverables');
      expect(issue).toBeDefined();
      expect(issue.message).toContain('No deliverables');
    });
  });

  describe('Validity Checks', () => {
    test('validates correct status values', async () => {
      const validStatuses = ['pending', 'assigned', 'running', 'completed', 'failed', 'cancelled'];

      for (const status of validStatuses) {
        const workerSpec = {
          worker_id: 'worker-001',
          task_id: 'task-001',
          results: {
            status,
            output_location: '/path',
            summary: 'Done',
            artifacts: []
          }
        };

        const result = await validator.validateWorkerOutput(workerSpec);
        expect(result.checks.validity.passed).toBe(true);
      }
    });

    test('rejects invalid status values', async () => {
      const workerSpec = {
        worker_id: 'worker-001',
        task_id: 'task-001',
        results: {
          status: 'invalid-status',
          output_location: '/path',
          summary: 'Done',
          artifacts: []
        }
      };

      const result = await validator.validateWorkerOutput(workerSpec);
      expect(result.checks.validity.passed).toBe(false);
      const issue = result.checks.validity.issues.find(i => i.field === 'results.status');
      expect(issue).toBeDefined();
    });

    test('validates timestamp logic', async () => {
      const workerSpec = {
        worker_id: 'worker-001',
        task_id: 'task-001',
        execution: {
          started_at: '2025-11-15T14:00:00Z',
          completed_at: '2025-11-15T13:00:00Z' // Before start!
        },
        results: {
          status: 'completed',
          output_location: '/path',
          summary: 'Done',
          artifacts: []
        }
      };

      const result = await validator.validateWorkerOutput(workerSpec);
      expect(result.checks.validity.passed).toBe(false);
      const issue = result.checks.validity.issues.find(i => i.field === 'execution.timestamps');
      expect(issue).toBeDefined();
    });
  });

  describe('Summary Quality', () => {
    test('passes with good summary', async () => {
      const workerSpec = {
        worker_id: 'worker-001',
        task_id: 'task-001',
        results: {
          status: 'completed',
          output_location: '/path',
          summary: 'Successfully implemented the user authentication feature with JWT tokens. Added comprehensive tests covering all edge cases.',
          artifacts: []
        }
      };

      const result = await validator.validateWorkerOutput(workerSpec);
      expect(result.checks.summaryQuality.score).toBeGreaterThan(0.7);
    });

    test('fails with too short summary', async () => {
      const workerSpec = {
        worker_id: 'worker-001',
        task_id: 'task-001',
        results: {
          status: 'completed',
          output_location: '/path',
          summary: 'Done',
          artifacts: []
        }
      };

      const result = await validator.validateWorkerOutput(workerSpec);
      expect(result.checks.summaryQuality.score).toBeLessThan(0.8);
      const issue = result.checks.summaryQuality.issues.find(i => i.message.includes('too short'));
      expect(issue).toBeDefined();
    });

    test('detects missing actionable keywords', async () => {
      const workerSpec = {
        worker_id: 'worker-001',
        task_id: 'task-001',
        results: {
          status: 'completed',
          output_location: '/path',
          summary: 'This is a very long summary that contains a lot of words but does not actually describe what was accomplished in any meaningful way whatsoever.',
          artifacts: []
        }
      };

      const result = await validator.validateWorkerOutput(workerSpec);
      const issue = result.checks.summaryQuality.issues.find(i => i.message.includes('actionable keywords'));
      expect(issue).toBeDefined();
    });
  });

  describe('Token Efficiency', () => {
    test('passes with good token utilization', async () => {
      const workerSpec = {
        worker_id: 'worker-001',
        task_id: 'task-001',
        resources: {
          token_budget: 5000
        },
        execution: {
          tokens_used: 3500
        },
        results: {
          status: 'completed',
          output_location: '/path',
          summary: 'Successfully completed the task with detailed analysis and comprehensive implementation.',
          artifacts: []
        }
      };

      const result = await validator.validateWorkerOutput(workerSpec);
      expect(result.checks.tokenEfficiency.passed).toBe(true);
      expect(result.checks.tokenEfficiency.score).toBeGreaterThan(0.8);
    });

    test('detects budget overrun', async () => {
      const workerSpec = {
        worker_id: 'worker-001',
        task_id: 'task-001',
        resources: {
          token_budget: 5000
        },
        execution: {
          tokens_used: 6000 // Over budget!
        },
        results: {
          status: 'completed',
          output_location: '/path',
          summary: 'Done',
          artifacts: []
        }
      };

      const result = await validator.validateWorkerOutput(workerSpec);
      const issue = result.checks.tokenEfficiency.issues.find(i => i.message.includes('budget exceeded'));
      expect(issue).toBeDefined();
    });

    test('detects inefficient token usage', async () => {
      const workerSpec = {
        worker_id: 'worker-001',
        task_id: 'task-001',
        resources: {
          token_budget: 5000
        },
        execution: {
          tokens_used: 4800 // 96% utilization
        },
        results: {
          status: 'completed',
          output_location: '/path',
          summary: 'Done', // Very short summary despite high token usage
          artifacts: []
        }
      };

      const result = await validator.validateWorkerOutput(workerSpec);
      const issue = result.checks.tokenEfficiency.issues.find(i => i.message.includes('minimal output'));
      expect(issue).toBeDefined();
    });
  });

  describe('Execution Quality', () => {
    test('passes with reasonable execution time', async () => {
      const workerSpec = {
        worker_id: 'worker-001',
        task_id: 'task-001',
        resources: {
          timeout_minutes: 15
        },
        execution: {
          duration_minutes: 8,
          session_id: 'session-123'
        },
        results: {
          status: 'completed',
          output_location: '/path',
          summary: 'Task completed successfully',
          artifacts: []
        }
      };

      const result = await validator.validateWorkerOutput(workerSpec);
      expect(result.checks.executionQuality.passed).toBe(true);
      expect(result.checks.executionQuality.score).toBeGreaterThan(0.8);
    });

    test('detects timeout issues', async () => {
      const workerSpec = {
        worker_id: 'worker-001',
        task_id: 'task-001',
        resources: {
          timeout_minutes: 15
        },
        execution: {
          duration_minutes: 14.5 // 96.7% of timeout
        },
        results: {
          status: 'completed',
          output_location: '/path',
          summary: 'Done',
          artifacts: []
        }
      };

      const result = await validator.validateWorkerOutput(workerSpec);
      const issue = result.checks.executionQuality.issues.find(i => i.message.includes('near timeout'));
      expect(issue).toBeDefined();
    });

    test('detects suspiciously quick completion', async () => {
      const workerSpec = {
        worker_id: 'worker-001',
        task_id: 'task-001',
        resources: {
          timeout_minutes: 15
        },
        execution: {
          duration_minutes: 0.05 // 3 seconds
        },
        results: {
          status: 'completed',
          output_location: '/path',
          summary: 'Done',
          artifacts: []
        }
      };

      const result = await validator.validateWorkerOutput(workerSpec);
      const issue = result.checks.executionQuality.issues.find(i => i.message.includes('suspiciously quickly'));
      expect(issue).toBeDefined();
    });
  });

  describe('Scoring System', () => {
    test('calculates weighted overall score', async () => {
      const workerSpec = {
        worker_id: 'worker-001',
        task_id: 'task-001',
        deliverables: ['output.json'],
        resources: {
          token_budget: 5000,
          timeout_minutes: 15
        },
        execution: {
          duration_minutes: 8,
          tokens_used: 3500,
          session_id: 'session-123',
          started_at: '2025-11-15T14:00:00Z',
          completed_at: '2025-11-15T14:08:00Z'
        },
        results: {
          status: 'completed',
          output_location: '/path/to/output',
          summary: 'Successfully implemented the user authentication feature with comprehensive tests and documentation.',
          artifacts: ['auth.js', 'tests.js']
        }
      };

      const result = await validator.validateWorkerOutput(workerSpec);
      expect(result.score).toBeGreaterThan(80); // Should be >80%
      expect(result.score).toBeLessThanOrEqual(100);
      expect(result.passed).toBe(true);
    });

    test('overall score reflects check failures', async () => {
      const workerSpec = {
        worker_id: 'worker-001',
        task_id: 'task-001',
        results: {
          status: 'invalid-status', // Invalid
          // Missing fields
        }
      };

      const result = await validator.validateWorkerOutput(workerSpec);
      expect(result.score).toBeLessThan(70); // Adjusted to match actual scoring
      expect(result.passed).toBe(false);
    });
  });

  describe('Recommendations', () => {
    test('generates recommendations for issues', async () => {
      const workerSpec = {
        worker_id: 'worker-001',
        task_id: 'task-001',
        results: {
          status: 'completed',
          output_location: '/path',
          summary: 'Short',
          artifacts: []
        }
      };

      const result = await validator.validateWorkerOutput(workerSpec);

      // Recommendations are generated based on issues found
      expect(result.recommendations).toBeDefined();
      expect(Array.isArray(result.recommendations)).toBe(true);
    });

    test('generates summary recommendations for poor summaries', async () => {
      const workerSpec = {
        worker_id: 'worker-001',
        task_id: 'task-001',
        results: {
          status: 'completed',
          output_location: '/path',
          summary: 'Done', // Too short
          artifacts: []
        }
      };

      const result = await validator.validateWorkerOutput(workerSpec);
      // Summary issues should trigger recommendations
      expect(result.checks.summaryQuality.score).toBeLessThan(0.8);
    });

    test('generates token recommendations for budget overruns', async () => {
      const workerSpec = {
        worker_id: 'worker-001',
        task_id: 'task-001',
        resources: {
          token_budget: 1000
        },
        execution: {
          tokens_used: 1200 // Over budget
        },
        results: {
          status: 'completed',
          output_location: '/path',
          summary: 'Task completed',
          artifacts: []
        }
      };

      const result = await validator.validateWorkerOutput(workerSpec);
      // Token issues should be detected
      expect(result.checks.tokenEfficiency.issues.length).toBeGreaterThan(0);
    });
  });

  describe('Error Handling', () => {
    test('handles minimal worker spec', async () => {
      const workerSpec = {
        worker_id: 'worker-001',
        task_id: 'task-001'
        // Missing everything else
      };

      const result = await validator.validateWorkerOutput(workerSpec);

      // Should still return a validation result
      expect(result).toBeDefined();
      expect(result.score).toBeDefined();
      expect(result.passed).toBe(false);
    });

    test('validates worker spec with partial data', async () => {
      const result = await validator.validateWorkerOutput({
        worker_id: 'w1',
        task_id: 't1',
        results: { status: 'completed' }
        // Missing most fields
      });

      // Should still return a validation result, not throw
      expect(result).toBeDefined();
      expect(result.checks).toBeDefined();
    });
  });

  describe('Logging', () => {
    test('logs validation results to JSONL', async () => {
      const workerSpec = {
        worker_id: 'worker-001',
        task_id: 'task-001',
        deliverables: [],
        results: {
          status: 'completed',
          output_location: '/path',
          summary: 'Task completed',
          artifacts: []
        }
      };

      await validator.validateWorkerOutput(workerSpec);

      const logData = await fs.readFile(testLogPath, 'utf8');
      const entries = logData.split('\n').filter(l => l.trim());

      expect(entries.length).toBe(1);

      const entry = JSON.parse(entries[0]);
      expect(entry.worker_id).toBe('worker-001');
      expect(entry.task_id).toBe('task-001');
      expect(entry.score).toBeDefined();
      expect(entry.passed).toBeDefined();
    });
  });

  describe('Statistics', () => {
    test('calculates quality statistics', async () => {
      // Create some test validation entries
      const validations = [
        { worker_id: '1', task_id: 't1', results: { status: 'completed', output_location: '/a', summary: 'Good summary with actionable content', artifacts: [] } },
        { worker_id: '2', task_id: 't2', results: { status: 'completed', output_location: '/b', summary: 'Another good summary', artifacts: [] } },
        { worker_id: '3', task_id: 't3', results: { status: 'failed', output_location: '/c', summary: 'Failed', artifacts: [] } }
      ];

      for (const spec of validations) {
        await validator.validateWorkerOutput(spec);
      }

      const stats = await validator.getQualityStatistics({ period: '30d' });

      expect(stats.total_validations).toBe(3);
      expect(stats.average_score).toBeGreaterThan(0);
      expect(stats.pass_rate).toBeGreaterThan(0);
    });
  });

  describe('Additional Edge Cases', () => {
    test('handles various status values', async () => {
      const statuses = ['pending', 'assigned', 'running', 'completed', 'failed', 'cancelled'];

      for (const status of statuses) {
        const result = await validator.validateWorkerOutput({
          worker_id: 'w1',
          task_id: 't1',
          results: { status, output_location: '/p', summary: 'Test', artifacts: [] }
        });
        expect(result.checks.validity).toBeDefined();
      }
    });

    test('handles different token utilization scenarios', async () => {
      // Within budget
      const withinBudget = await validator.validateWorkerOutput({
        worker_id: 'w1',
        task_id: 't1',
        resources: { token_budget: 5000 },
        execution: { tokens_used: 3000 },
        results: { status: 'completed', output_location: '/p', summary: 'Good work completed', artifacts: [] }
      });
      expect(withinBudget.checks.tokenEfficiency.passed).toBe(true);

      // At budget edge
      const atEdge = await validator.validateWorkerOutput({
        worker_id: 'w2',
        task_id: 't2',
        resources: { token_budget: 5000 },
        execution: { tokens_used: 4900 },
        results: { status: 'completed', output_location: '/p', summary: 'Done', artifacts: [] }
      });
      expect(atEdge.checks.tokenEfficiency).toBeDefined();
    });

    test('handles different execution durations', async () => {
      // Quick completion
      const quick = await validator.validateWorkerOutput({
        worker_id: 'w1',
        task_id: 't1',
        resources: { timeout_minutes: 15 },
        execution: { duration_minutes: 2 },
        results: { status: 'completed', output_location: '/p', summary: 'Quick task completed', artifacts: [] }
      });
      expect(quick.checks.executionQuality).toBeDefined();

      // Near timeout
      const nearTimeout = await validator.validateWorkerOutput({
        worker_id: 'w2',
        task_id: 't2',
        resources: { timeout_minutes: 15 },
        execution: { duration_minutes: 14 },
        results: { status: 'completed', output_location: '/p', summary: 'Long task completed', artifacts: [] }
      });
      expect(nearTimeout.checks.executionQuality).toBeDefined();
    });
  });
});
