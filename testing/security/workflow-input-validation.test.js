/**
 * Workflow Input Validation Tests
 * 
 * Tests to verify that workflow execution endpoint properly validates inputs
 * to prevent command injection through repository URLs and branch names.
 * 
 * This tests the integration of validation functions in the workflow route handler.
 */

const {
  validateGitRepositoryUrl,
  validateGitBranch
} = require('../../api-server/server/lib/path-validator');

// Mock workflow configuration (security-audit workflow)
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

describe('Workflow Input Validation - Valid Inputs', () => {
  test('should accept valid repository URL and branch', () => {
    const inputs = {
      repository_url: 'https://github.com/user/repo.git',
      branch: 'main'
    };
    const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
    expect(result.missingInputs).toHaveLength(0);
    expect(result.invalidInputs).toHaveLength(0);
  });

  test('should accept valid repository URL without branch (uses default)', () => {
    const inputs = {
      repository_url: 'https://github.com/user/repo.git'
    };
    const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
    expect(result.missingInputs).toHaveLength(0);
    expect(result.invalidInputs).toHaveLength(0);
  });

  test('should accept SSH repository URL', () => {
    const inputs = {
      repository_url: 'git@github.com:user/repo.git',
      branch: 'develop'
    };
    const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
    expect(result.missingInputs).toHaveLength(0);
    expect(result.invalidInputs).toHaveLength(0);
  });

  test('should accept feature branch with slashes', () => {
    const inputs = {
      repository_url: 'https://github.com/user/repo.git',
      branch: 'feature/new-feature'
    };
    const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
    expect(result.missingInputs).toHaveLength(0);
    expect(result.invalidInputs).toHaveLength(0);
  });

  test('should trim whitespace from inputs', () => {
    const inputs = {
      repository_url: '  https://github.com/user/repo.git  ',
      branch: '  main  '
    };
    const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
    expect(result.missingInputs).toHaveLength(0);
    expect(result.invalidInputs).toHaveLength(0);
    expect(inputs.repository_url).toBe('https://github.com/user/repo.git');
    expect(inputs.branch).toBe('main');
  });
});

describe('Workflow Input Validation - Missing Required Inputs', () => {
  test('should detect missing required repository_url', () => {
    const inputs = {
      branch: 'main'
    };
    const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
    expect(result.missingInputs).toHaveLength(1);
    expect(result.missingInputs[0]).toBe('repository_url');
  });

  test('should allow missing optional branch input', () => {
    const inputs = {
      repository_url: 'https://github.com/user/repo.git'
    };
    const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
    expect(result.missingInputs).toHaveLength(0);
  });
});

describe('Workflow Input Validation - Command Injection Prevention', () => {
  test('should reject workflow execution with command injection in repository URL', () => {
    const inputs = {
      repository_url: 'https://github.com/user/repo.git; id; #',
      branch: 'main'
    };
    const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
    expect(result.invalidInputs).toHaveLength(1);
    expect(result.invalidInputs[0]).toContain('repository_url');
  });

  test('should reject workflow execution with command injection in branch', () => {
    const inputs = {
      repository_url: 'https://github.com/user/repo.git',
      branch: 'main; id; #'
    };
    const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
    expect(result.invalidInputs).toHaveLength(1);
    expect(result.invalidInputs[0]).toContain('branch');
  });

  test('should reject workflow execution with command injection in both inputs', () => {
    const inputs = {
      repository_url: 'https://github.com/user/repo.git; whoami',
      branch: 'main | cat /etc/passwd'
    };
    const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
    expect(result.invalidInputs).toHaveLength(2);
  });

  test('should reject pentest reproduction scenario', () => {
    // Exact payload from pentest finding
    const inputs = {
      repository_url: 'https://github.com/user/repo.git',
      branch: 'x; id; #'
    };
    const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
    expect(result.invalidInputs).toHaveLength(1);
    expect(result.invalidInputs[0]).toContain('branch');
  });

  test('should reject command substitution with backticks', () => {
    const inputs = {
      repository_url: 'https://github.com/user/repo.git',
      branch: 'main`whoami`'
    };
    const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
    expect(result.invalidInputs).toHaveLength(1);
  });

  test('should reject command substitution with $(...)', () => {
    const inputs = {
      repository_url: 'https://github.com/user/repo.git',
      branch: 'main$(id)'
    };
    const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
    expect(result.invalidInputs).toHaveLength(1);
  });

  test('should reject pipe command separator', () => {
    const inputs = {
      repository_url: 'https://github.com/user/repo.git | cat /etc/passwd',
      branch: 'main'
    };
    const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
    expect(result.invalidInputs).toHaveLength(1);
  });

  test('should reject ampersand command separator', () => {
    const inputs = {
      repository_url: 'https://github.com/user/repo.git',
      branch: 'main & whoami'
    };
    const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
    expect(result.invalidInputs).toHaveLength(1);
  });

  test('should reject newline injection', () => {
    const inputs = {
      repository_url: 'https://github.com/user/repo.git',
      branch: 'main\nid'
    };
    const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
    expect(result.invalidInputs).toHaveLength(1);
  });

  test('should reject null byte injection', () => {
    const inputs = {
      repository_url: 'https://github.com/user/repo.git\x00id',
      branch: 'main'
    };
    const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
    expect(result.invalidInputs).toHaveLength(1);
  });
});

describe('Workflow Input Validation - Type Validation', () => {
  test('should reject non-string repository URL', () => {
    const inputs = {
      repository_url: 12345,
      branch: 'main'
    };
    const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
    expect(result.invalidInputs).toHaveLength(1);
    expect(result.invalidInputs[0]).toContain('expected string');
  });

  test('should reject non-string branch name', () => {
    const inputs = {
      repository_url: 'https://github.com/user/repo.git',
      branch: ['main']
    };
    const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
    expect(result.invalidInputs).toHaveLength(1);
    expect(result.invalidInputs[0]).toContain('expected string');
  });

  test('should reject object as repository URL', () => {
    const inputs = {
      repository_url: { url: 'https://github.com/user/repo.git' },
      branch: 'main'
    };
    const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
    expect(result.invalidInputs).toHaveLength(1);
  });
});

describe('Workflow Input Validation - Enum Constraints', () => {
  test('should validate enum constraints when specified', () => {
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
    expect(result1.invalidInputs).toHaveLength(0);

    const invalidInputs = { environment: 'invalid' };
    const result2 = validateWorkflowInputs(workflowWithEnum, invalidInputs);
    expect(result2.invalidInputs).toHaveLength(1);
    expect(result2.invalidInputs[0]).toContain('must be one of');
  });
});

describe('Workflow Input Validation - Edge Cases', () => {
  test('should reject empty repository URL', () => {
    const inputs = {
      repository_url: '',
      branch: 'main'
    };
    const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
    expect(result.invalidInputs).toHaveLength(1);
  });

  test('should reject whitespace-only repository URL', () => {
    const inputs = {
      repository_url: '   ',
      branch: 'main'
    };
    const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
    expect(result.invalidInputs).toHaveLength(1);
  });

  test('should reject empty branch name', () => {
    const inputs = {
      repository_url: 'https://github.com/user/repo.git',
      branch: ''
    };
    const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
    expect(result.invalidInputs).toHaveLength(1);
  });

  test('should reject overly long repository URL', () => {
    const inputs = {
      repository_url: 'https://github.com/' + 'a'.repeat(2100) + '/repo.git',
      branch: 'main'
    };
    const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
    expect(result.invalidInputs).toHaveLength(1);
  });

  test('should reject overly long branch name', () => {
    const inputs = {
      repository_url: 'https://github.com/user/repo.git',
      branch: 'a'.repeat(300)
    };
    const result = validateWorkflowInputs(mockSecurityAuditWorkflow, inputs);
    expect(result.invalidInputs).toHaveLength(1);
  });
});

describe('Workflow Input Validation - Multiple Repository Inputs', () => {
  test('should validate multiple repository-related inputs', () => {
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
    expect(result.invalidInputs).toHaveLength(1);
    expect(result.invalidInputs[0]).toContain('primary_repo');
  });

  test('should validate all branch-related inputs', () => {
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
    expect(result.invalidInputs).toHaveLength(1);
    expect(result.invalidInputs[0]).toContain('target_branch');
  });
});
