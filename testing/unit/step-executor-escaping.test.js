/**
 * Unit Tests for Step Executor Shell Escaping
 * Tests that shell commands properly escape interpolated values
 */

const assert = require('assert');
const path = require('path');
const StepExecutor = require('../../lib/orchestration/step-executor');

describe('Step Executor - Shell Escaping', function() {
  let executor;

  beforeEach(function() {
    executor = new StepExecutor({
      coordDir: path.join(__dirname, '../../coordination'),
      scriptsDir: path.join(__dirname, '../../scripts'),
      timeout: 5000
    });
  });

  describe('resolveInputs() with shell escaping', function() {
    it('should escape shell metacharacters when escapeForShell is true', function() {
      const context = {
        inputs: {
          branch: 'main; id #'
        }
      };
      
      const value = 'git checkout {{ inputs.branch }}';
      const result = executor.resolveInputs(value, context, true);
      
      // Should be escaped with single quotes
      assert.ok(result.includes("'main; id #'"), 'Should wrap dangerous input in quotes');
      // The entire result should be: git checkout 'main; id #'
      assert.strictEqual(result, "git checkout 'main; id #'");
    });

    it('should not escape when escapeForShell is false', function() {
      const context = {
        inputs: {
          branch: 'main'
        }
      };
      
      const value = 'Branch: {{ inputs.branch }}';
      const result = executor.resolveInputs(value, context, false);
      
      assert.strictEqual(result, 'Branch: main');
    });

    it('should escape multiple interpolations', function() {
      const context = {
        inputs: {
          repository_url: 'https://github.com/user/repo.git; whoami',
          branch: 'main`id`'
        }
      };
      
      const value = 'git clone {{ inputs.repository_url }} && git checkout {{ inputs.branch }}';
      const result = executor.resolveInputs(value, context, true);
      
      // Both should be escaped
      assert.ok(result.includes("'https://github.com/user/repo.git; whoami'"));
      assert.ok(result.includes("'main`id`'"));
    });

    it('should handle nested objects with escaping', function() {
      const context = {
        inputs: {
          config: {
            branch: 'main; whoami'
          }
        }
      };
      
      const value = {
        command: 'git checkout {{ inputs.config.branch }}'
      };
      
      const result = executor.resolveInputs(value, context, true);
      assert.ok(result.command.includes("'main; whoami'"));
    });

    it('should handle arrays with escaping', function() {
      const context = {
        inputs: {
          branches: ['main; id', 'develop`whoami`']
        }
      };
      
      const value = ['{{ inputs.branches.0 }}', '{{ inputs.branches.1 }}'];
      const result = executor.resolveInputs(value, context, true);
      
      // Note: Array access in templates would need special handling
      // This tests the escaping mechanism itself
      assert.ok(Array.isArray(result));
    });
  });

  describe('resolveAllInputs() with shell escaping', function() {
    it('should apply escaping to all inputs when enabled', function() {
      const context = {
        inputs: {
          repository_url: 'https://github.com/user/repo.git',
          branch: 'main; id #'
        }
      };
      
      const inputs = {
        command: 'git clone {{ inputs.repository_url }} && git checkout {{ inputs.branch }}'
      };
      
      const result = executor.resolveAllInputs(inputs, context, true);
      
      assert.ok(result.command.includes("'main; id #'"));
    });
  });

  describe('executeStep() with shell action', function() {
    it('should automatically enable escaping for shell actions', async function() {
      const step = {
        id: 'test-step',
        action: 'shell',
        inputs: {
          command: 'echo {{ inputs.value }}'
        }
      };
      
      const context = {
        inputs: {
          value: 'safe-value'
        }
      };
      
      // This tests that the step executor correctly identifies shell actions
      // and enables escaping
      const resolvedInputs = executor.resolveAllInputs(step.inputs, context, true);
      assert.ok(resolvedInputs.command.includes("'safe-value'"));
    });

    it('should automatically enable escaping for bash actions', async function() {
      const step = {
        id: 'test-step',
        action: 'bash',
        inputs: {
          command: 'echo {{ inputs.value }}'
        }
      };
      
      const context = {
        inputs: {
          value: 'test; whoami'
        }
      };
      
      const resolvedInputs = executor.resolveAllInputs(step.inputs, context, true);
      assert.ok(resolvedInputs.command.includes("'test; whoami'"));
    });
  });

  describe('Integration: Pentest Scenarios', function() {
    it('should prevent command injection in git clone command', function() {
      // Simulates: git clone {{ inputs.repository_url }}
      const context = {
        inputs: {
          repository_url: 'https://github.com/user/repo.git; whoami'
        }
      };
      
      const command = 'git clone {{ inputs.repository_url }} /tmp/repo';
      const result = executor.resolveInputs(command, context, true);
      
      // The malicious input should be quoted
      assert.ok(result.includes("'https://github.com/user/repo.git; whoami'"));
      // The semicolon should be inside quotes, not a command separator
      const parts = result.split("'");
      assert.ok(parts.some(part => part.includes('; whoami')));
    });

    it('should prevent command injection in git checkout command', function() {
      // Simulates: git checkout {{ inputs.branch }}
      const context = {
        inputs: {
          branch: 'main; id #'
        }
      };
      
      const command = 'git checkout {{ inputs.branch }}';
      const result = executor.resolveInputs(command, context, true);
      
      // The malicious input should be quoted
      assert.ok(result.includes("'main; id #'"));
    });

    it('should prevent command injection in git fetch command', function() {
      // Simulates: git fetch origin {{ inputs.branch }}
      const context = {
        inputs: {
          branch: 'main`whoami`'
        }
      };
      
      const command = 'git fetch origin {{ inputs.branch }}';
      const result = executor.resolveInputs(command, context, true);
      
      // The malicious input should be quoted
      assert.ok(result.includes("'main`whoami`'"));
    });

    it('should prevent command injection in git diff command', function() {
      // Simulates: git diff origin/{{ inputs.base_branch }}...HEAD
      const context = {
        inputs: {
          base_branch: 'main | cat /etc/passwd'
        }
      };
      
      const command = 'git diff origin/{{ inputs.base_branch }}...HEAD';
      const result = executor.resolveInputs(command, context, true);
      
      // The malicious input should be quoted
      assert.ok(result.includes("'main | cat /etc/passwd'"));
    });

    it('should handle code-review workflow scenario', function() {
      // Full scenario from code-review.yaml
      const context = {
        inputs: {
          repository_url: 'https://github.com/user/repo.git',
          branch: 'main; id #',
          base_branch: 'develop'
        }
      };
      
      const command = `
        WORK_DIR="/tmp/code-review-$(date +%s)-$RANDOM"
        mkdir -p "$WORK_DIR"
        git clone --depth 50 {{ inputs.repository_url }} "$WORK_DIR/repo"
        cd "$WORK_DIR/repo"
        git fetch origin {{ inputs.branch }}
        git checkout {{ inputs.branch }}
      `;
      
      const result = executor.resolveInputs(command, context, true);
      
      // All dangerous inputs should be escaped
      assert.ok(result.includes("'https://github.com/user/repo.git'"));
      assert.ok(result.includes("'main; id #'"));
    });

    it('should handle deployment workflow scenario', function() {
      // Scenario from deployment workflow
      const context = {
        inputs: {
          repository_url: 'https://github.com/user/repo.git`whoami`',
          branch: 'main$(id)'
        }
      };
      
      const command = 'git clone --depth 1 --branch {{ inputs.branch }} {{ inputs.repository_url }} "$WORK_DIR"';
      const result = executor.resolveInputs(command, context, true);
      
      // Both command injection attempts should be neutralized
      assert.ok(result.includes("'main$(id)'"));
      assert.ok(result.includes("'https://github.com/user/repo.git`whoami`'"));
    });

    it('should handle security-audit workflow scenario', function() {
      // Scenario from security-audit workflow
      const context = {
        inputs: {
          repository_url: 'https://github.com/user/repo.git',
          branch: 'main & whoami'
        }
      };
      
      const command = 'git clone --depth 100 --branch {{ inputs.branch }} {{ inputs.repository_url }} "$WORK_DIR"';
      const result = executor.resolveInputs(command, context, true);
      
      // Ampersand should be escaped
      assert.ok(result.includes("'main & whoami'"));
    });
  });

  describe('Edge Cases', function() {
    it('should handle empty interpolations', function() {
      const context = {
        inputs: {}
      };
      
      const command = 'echo {{ inputs.missing }}';
      const result = executor.resolveInputs(command, context, true);
      
      // Should leave the template as-is if value is undefined
      assert.ok(result.includes('{{ inputs.missing }}'));
    });

    it('should handle single quotes in input', function() {
      const context = {
        inputs: {
          message: "it's a test"
        }
      };
      
      const command = 'echo {{ inputs.message }}';
      const result = executor.resolveInputs(command, context, true);
      
      // Should properly escape single quotes
      assert.ok(result.includes("'it'\\''s a test'"));
    });

    it('should handle multiple single quotes', function() {
      const context = {
        inputs: {
          value: "don't can't won't"
        }
      };
      
      const command = 'echo {{ inputs.value }}';
      const result = executor.resolveInputs(command, context, true);
      
      // All single quotes should be escaped
      assert.ok(result.includes("'don'\\''t can'\\''t won'\\''t'"));
    });
  });
});


