/**
 * Workflow Input Validation Tests
 * 
 * Tests to verify that workflow execution endpoint properly validates inputs
 * to prevent command injection through repository URLs and branch names.
 * 
 * This tests the integration of validation functions in the workflow route handler.
 */

const assert = require('assert');

console.log('═══════════════════════════════════════════════════════════');
console.log('Workflow Input Validation Tests');
console.log('Testing workflow route input validation logic');
console.log('═══════════════════════════════════════════════════════════\n');

// Track test results
const testResults = [];
let totalTests = 0;
let passedTests = 0;

function runTest(name, testFn) {
  totalTests++;
  const startTime = Date.now();
  try {
    testFn();
    passedTests++;
    const duration = Date.now() - startTime;
    testResults.push({ name, passed: true, duration });
    console.log(`✅ ${name} (${duration}ms)`);
  } catch (error) {
    const duration = Date.now() - startTime;
    testResults.push({ name, passed: false, duration, error: error.message });
    console.error(`❌ ${name} (${duration}ms)`);
    console.error(`   Error: ${error.message}`);
  }
}

// ============================================================================
// Mock Workflow Configuration
// ============================================================================

// Simulate the security-audit workflow configuration
const mockSecurityAuditWorkflow = {
  name: 'security-audit',
  inputs: {
    repository_url: {
      type: 'string',
      description: 'Git repository URL to audit',
      required: true
    },
    branch: {
      type: 'string',
      description: 'Branch to audit',
      default: 'main',
      required: false
    },
    scan_depth: {
      type: 'string',
      description: 'Scan depth',
      default: '100',
      required: false
    }
  }
};

// ============================================================================
// Validation Logic (extracted from workflows.js route)
// ============================================================================

const {
  validateGitRepositoryUrl,
  validateGitBranch
} = require('../server/lib/path-validator');

/**
 * Simulate the validation logic from the workflow route
 * This is the actual security mitigation code
 */
function validateWorkflowInputs(workflow, inputs) {
  const missingInputs = [];
  const invalidInputs = [];

  for (const [key, config] of Object.entries(workflow.inputs)) {
    // Check required inputs
    if (config.required && inputs[key] === undefined) {
      missingInputs.push(key);
    }

    // Validate input types and constraints
    if (inputs[key] !== undefined) {
      const value = inputs[key];

      // Type validation
      if (config.type === 'string' && typeof value !== 'string') {
        invalidInputs.push(`${key} (expected string, got ${typeof value})`);
        continue;
      }

      // Security validation for Git-related inputs
      if (key === 'repository_url' || key === 'repository' || key.includes('repo')) {
        const validated = validateGitRepositoryUrl(value);
        if (validated === null) {
          invalidInputs.push(`${key} (invalid or unsafe repository URL format)`);
        } else {
          inputs[key] = validated;
        }
      } else if (key === 'branch' || key.includes('branch')) {
        const validated = validateGitBranch(value);
        if (validated === null) {
          invalidInputs.push(`${key} (invalid or unsafe branch name format)`);
        } else {
          inputs[key] = validated;
        }
      }

      // Validate enum constraints
      if (config.enum && Array.isArray(config.enum)) {
        if (!config.enum.includes(value)) {
          invalidInputs.push(`${key} (must be one of: ${config.enum.join(', ')})`);
        }
      }
    }
  }

  return { missingInputs, invalidInputs };
}

// ============================================================================
// Test Suite 1: Valid Workflow Inputs
// ============================================================================

console.log('Test Suite 1: Valid Workflow Inputs\n');

runTest('should accept valid repository URL and branch', () => {
  const inputs = {
    repository_url: 'https://github.com/user/repo.git',
    branch: 'main'
  };
  const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
  assert.strictEqual(result.missingInputs.length, 0, 'Should have no missing inputs');
  assert.strictEqual(result.invalidInputs.length, 0, 'Should have no invalid inputs');
});

runTest('should accept valid repository URL without branch (uses default)', () => {
  const inputs = {
    repository_url: 'https://github.com/user/repo.git'
  };
  const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
  assert.strictEqual(result.missingInputs.length, 0, 'Should have no missing inputs');
  assert.strictEqual(result.invalidInputs.length, 0, 'Should have no invalid inputs');
});

runTest('should accept SSH repository URL', () => {
  const inputs = {
    repository_url: 'git@github.com:user/repo.git',
    branch: 'develop'
  };
  const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
  assert.strictEqual(result.missingInputs.length, 0, 'Should have no missing inputs');
  assert.strictEqual(result.invalidInputs.length, 0, 'Should have no invalid inputs');
});

runTest('should accept feature branch with slashes', () => {
  const inputs = {
    repository_url: 'https://github.com/user/repo.git',
    branch: 'feature/new-feature'
  };
  const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
  assert.strictEqual(result.missingInputs.length, 0, 'Should have no missing inputs');
  assert.strictEqual(result.invalidInputs.length, 0, 'Should have no invalid inputs');
});

runTest('should trim whitespace from inputs', () => {
  const inputs = {
    repository_url: '  https://github.com/user/repo.git  ',
    branch: '  main  '
  };
  const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
  assert.strictEqual(result.missingInputs.length, 0, 'Should have no missing inputs');
  assert.strictEqual(result.invalidInputs.length, 0, 'Should have no invalid inputs');
  assert.strictEqual(inputs.repository_url, 'https://github.com/user/repo.git', 'URL should be trimmed');
  assert.strictEqual(inputs.branch, 'main', 'Branch should be trimmed');
});

// ============================================================================
// Test Suite 2: Missing Required Inputs
// ============================================================================

console.log('\nTest Suite 2: Missing Required Inputs\n');

runTest('should detect missing required repository_url', () => {
  const inputs = {
    branch: 'main'
  };
  const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
  assert.strictEqual(result.missingInputs.length, 1, 'Should have one missing input');
  assert.strictEqual(result.missingInputs[0], 'repository_url', 'Should identify repository_url as missing');
});

runTest('should allow missing optional branch input', () => {
  const inputs = {
    repository_url: 'https://github.com/user/repo.git'
  };
  const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
  assert.strictEqual(result.missingInputs.length, 0, 'Should have no missing inputs (branch is optional)');
});

// ============================================================================
// Test Suite 3: Command Injection Prevention in Workflow Context
// ============================================================================

console.log('\nTest Suite 3: Command Injection Prevention in Workflow Context\n');

runTest('should reject workflow execution with command injection in repository URL', () => {
  const inputs = {
    repository_url: 'https://github.com/user/repo.git; id; #',
    branch: 'main'
  };
  const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
  assert.strictEqual(result.invalidInputs.length, 1, 'Should have one invalid input');
  assert.ok(result.invalidInputs[0].includes('repository_url'), 'Should identify repository_url as invalid');
});

runTest('should reject workflow execution with command injection in branch', () => {
  const inputs = {
    repository_url: 'https://github.com/user/repo.git',
    branch: 'main; id; #'
  };
  const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
  assert.strictEqual(result.invalidInputs.length, 1, 'Should have one invalid input');
  assert.ok(result.invalidInputs[0].includes('branch'), 'Should identify branch as invalid');
});

runTest('should reject workflow execution with command injection in both inputs', () => {
  const inputs = {
    repository_url: 'https://github.com/user/repo.git; whoami',
    branch: 'main | cat /etc/passwd'
  };
  const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
  assert.strictEqual(result.invalidInputs.length, 2, 'Should have two invalid inputs');
});

runTest('should reject pentest reproduction scenario', () => {
  // Exact payload from pentest finding
  const inputs = {
    repository_url: 'https://github.com/user/repo.git',
    branch: 'x; id; #'
  };
  const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
  assert.strictEqual(result.invalidInputs.length, 1, 'Should reject pentest payload');
  assert.ok(result.invalidInputs[0].includes('branch'), 'Should identify branch as invalid');
});

runTest('should reject command substitution with backticks', () => {
  const inputs = {
    repository_url: 'https://github.com/user/repo.git',
    branch: 'main`whoami`'
  };
  const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
  assert.strictEqual(result.invalidInputs.length, 1, 'Should reject backtick substitution');
});

runTest('should reject command substitution with $(...)', () => {
  const inputs = {
    repository_url: 'https://github.com/user/repo.git',
    branch: 'main$(id)'
  };
  const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
  assert.strictEqual(result.invalidInputs.length, 1, 'Should reject $() substitution');
});

runTest('should reject pipe command separator', () => {
  const inputs = {
    repository_url: 'https://github.com/user/repo.git | cat /etc/passwd',
    branch: 'main'
  };
  const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
  assert.strictEqual(result.invalidInputs.length, 1, 'Should reject pipe separator');
});

runTest('should reject ampersand command separator', () => {
  const inputs = {
    repository_url: 'https://github.com/user/repo.git',
    branch: 'main & whoami'
  };
  const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
  assert.strictEqual(result.invalidInputs.length, 1, 'Should reject ampersand separator');
});

runTest('should reject newline injection', () => {
  const inputs = {
    repository_url: 'https://github.com/user/repo.git',
    branch: 'main\nid'
  };
  const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
  assert.strictEqual(result.invalidInputs.length, 1, 'Should reject newline injection');
});

runTest('should reject null byte injection', () => {
  const inputs = {
    repository_url: 'https://github.com/user/repo.git\x00id',
    branch: 'main'
  };
  const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
  assert.strictEqual(result.invalidInputs.length, 1, 'Should reject null byte injection');
});

// ============================================================================
// Test Suite 4: Type Validation
// ============================================================================

console.log('\nTest Suite 4: Type Validation\n');

runTest('should reject non-string repository URL', () => {
  const inputs = {
    repository_url: 12345,
    branch: 'main'
  };
  const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
  assert.strictEqual(result.invalidInputs.length, 1, 'Should have one invalid input');
  assert.ok(result.invalidInputs[0].includes('expected string'), 'Should indicate type mismatch');
});

runTest('should reject non-string branch name', () => {
  const inputs = {
    repository_url: 'https://github.com/user/repo.git',
    branch: ['main']
  };
  const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
  assert.strictEqual(result.invalidInputs.length, 1, 'Should have one invalid input');
  assert.ok(result.invalidInputs[0].includes('expected string'), 'Should indicate type mismatch');
});

runTest('should reject object as repository URL', () => {
  const inputs = {
    repository_url: { url: 'https://github.com/user/repo.git' },
    branch: 'main'
  };
  const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
  assert.strictEqual(result.invalidInputs.length, 1, 'Should have one invalid input');
});

// ============================================================================
// Test Suite 5: Enum Validation
// ============================================================================

console.log('\nTest Suite 5: Enum Validation\n');

runTest('should validate enum constraints when specified', () => {
  const workflowWithEnum = {
    name: 'test-workflow',
    inputs: {
      environment: {
        type: 'string',
        required: true,
        enum: ['dev', 'staging', 'production']
      }
    }
  };

  const validInputs = { environment: 'dev' };
  const result1 = validateWorkflowInputs(workflowWithEnum, validInputs);
  assert.strictEqual(result1.invalidInputs.length, 0, 'Should accept valid enum value');

  const invalidInputs = { environment: 'invalid' };
  const result2 = validateWorkflowInputs(workflowWithEnum, invalidInputs);
  assert.strictEqual(result2.invalidInputs.length, 1, 'Should reject invalid enum value');
  assert.ok(result2.invalidInputs[0].includes('must be one of'), 'Should indicate enum constraint');
});

// ============================================================================
// Test Suite 6: Edge Cases and Security Boundaries
// ============================================================================

console.log('\nTest Suite 6: Edge Cases and Security Boundaries\n');

runTest('should reject empty repository URL', () => {
  const inputs = {
    repository_url: '',
    branch: 'main'
  };
  const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
  assert.strictEqual(result.invalidInputs.length, 1, 'Should reject empty URL');
});

runTest('should reject whitespace-only repository URL', () => {
  const inputs = {
    repository_url: '   ',
    branch: 'main'
  };
  const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
  assert.strictEqual(result.invalidInputs.length, 1, 'Should reject whitespace-only URL');
});

runTest('should reject empty branch name', () => {
  const inputs = {
    repository_url: 'https://github.com/user/repo.git',
    branch: ''
  };
  const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
  assert.strictEqual(result.invalidInputs.length, 1, 'Should reject empty branch');
});

runTest('should reject overly long repository URL', () => {
  const inputs = {
    repository_url: 'https://github.com/' + 'a'.repeat(2100) + '/repo.git',
    branch: 'main'
  };
  const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
  assert.strictEqual(result.invalidInputs.length, 1, 'Should reject overly long URL');
});

runTest('should reject overly long branch name', () => {
  const inputs = {
    repository_url: 'https://github.com/user/repo.git',
    branch: 'a'.repeat(300)
  };
  const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
  assert.strictEqual(result.invalidInputs.length, 1, 'Should reject overly long branch');
});

// ============================================================================
// Test Suite 7: Multiple Input Validation
// ============================================================================

console.log('\nTest Suite 7: Multiple Input Validation\n');

runTest('should validate multiple repository-related inputs', () => {
  const workflowWithMultipleRepos = {
    name: 'multi-repo-workflow',
    inputs: {
      primary_repo: {
        type: 'string',
        required: true
      },
      secondary_repo: {
        type: 'string',
        required: false
      },
      branch: {
        type: 'string',
        required: true
      }
    }
  };

  const inputs = {
    primary_repo: 'https://github.com/user/repo1.git; id',
    secondary_repo: 'https://github.com/user/repo2.git',
    branch: 'main'
  };

  const result = validateWorkflowInputs(workflowWithMultipleRepos, inputs);
  assert.strictEqual(result.invalidInputs.length, 1, 'Should detect injection in primary_repo');
  assert.ok(result.invalidInputs[0].includes('primary_repo'), 'Should identify primary_repo as invalid');
});

runTest('should validate all branch-related inputs', () => {
  const workflowWithMultipleBranches = {
    name: 'multi-branch-workflow',
    inputs: {
      repository_url: {
        type: 'string',
        required: true
      },
      source_branch: {
        type: 'string',
        required: true
      },
      target_branch: {
        type: 'string',
        required: true
      }
    }
  };

  const inputs = {
    repository_url: 'https://github.com/user/repo.git',
    source_branch: 'feature/test',
    target_branch: 'main; id; #'
  };

  const result = validateWorkflowInputs(workflowWithMultipleBranches, inputs);
  assert.strictEqual(result.invalidInputs.length, 1, 'Should detect injection in target_branch');
  assert.ok(result.invalidInputs[0].includes('target_branch'), 'Should identify target_branch as invalid');
});

// ============================================================================
// Summary
// ============================================================================

console.log('\n═══════════════════════════════════════════════════════════');
console.log('Test Summary');
console.log('═══════════════════════════════════════════════════════════');
console.log(`Total Tests: ${totalTests}`);
console.log(`Passed: ${passedTests}`);
console.log(`Failed: ${totalTests - passedTests}`);
console.log(`Success Rate: ${((passedTests / totalTests) * 100).toFixed(2)}%`);
console.log('═══════════════════════════════════════════════════════════\n');

// Export results for programmatic access
if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    testResults,
    totalTests,
    passedTests,
    success: passedTests === totalTests
  };
}

// Exit with appropriate code
process.exit(passedTests === totalTests ? 0 : 1);
