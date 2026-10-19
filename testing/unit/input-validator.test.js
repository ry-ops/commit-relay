/**
 * Unit Tests for Input Validator
 * Tests command injection mitigation through input validation and shell escaping
 */

const assert = require('assert');
const {
  escapeShellArg,
  isShellSafe,
  isValidGitUrl,
  isValidGitRef,
  validateWorkflowInputs
} = require('../../api-server/server/lib/input-validator');

describe('Input Validator - Command Injection Mitigation', function() {
  
  describe('escapeShellArg()', function() {
    it('should wrap simple strings in single quotes', function() {
      const result = escapeShellArg('hello');
      assert.strictEqual(result, "'hello'");
    });

    it('should escape single quotes in strings', function() {
      const result = escapeShellArg("it's");
      assert.strictEqual(result, "'it'\\''s'");
    });

    it('should neutralize command injection with semicolon', function() {
      const malicious = 'main; id #';
      const result = escapeShellArg(malicious);
      assert.strictEqual(result, "'main; id #'");
      // Verify the semicolon is now inside quotes and won't execute
      assert.ok(result.includes(';'));
      assert.ok(result.startsWith("'"));
      assert.ok(result.endsWith("'"));
    });

    it('should neutralize command injection with pipe', function() {
      const malicious = 'main | cat /etc/passwd';
      const result = escapeShellArg(malicious);
      assert.strictEqual(result, "'main | cat /etc/passwd'");
    });

    it('should neutralize command injection with backticks', function() {
      const malicious = 'main`whoami`';
      const result = escapeShellArg(malicious);
      assert.strictEqual(result, "'main`whoami`'");
    });

    it('should neutralize command injection with dollar sign command substitution', function() {
      const malicious = 'main$(whoami)';
      const result = escapeShellArg(malicious);
      assert.strictEqual(result, "'main$(whoami)'");
    });

    it('should handle null and undefined', function() {
      assert.strictEqual(escapeShellArg(null), "''");
      assert.strictEqual(escapeShellArg(undefined), "''");
    });

    it('should handle empty string', function() {
      assert.strictEqual(escapeShellArg(''), "''");
    });

    it('should handle strings with newlines', function() {
      const result = escapeShellArg('line1\nline2');
      assert.strictEqual(result, "'line1\nline2'");
    });
  });

  describe('isShellSafe()', function() {
    it('should accept safe alphanumeric strings', function() {
      assert.strictEqual(isShellSafe('main'), true);
      assert.strictEqual(isShellSafe('feature-branch'), true);
      assert.strictEqual(isShellSafe('v1.0.0'), true);
    });

    it('should reject strings with semicolons (command separator)', function() {
      assert.strictEqual(isShellSafe('main; id #'), false);
      assert.strictEqual(isShellSafe('test;whoami'), false);
    });

    it('should reject strings with pipes', function() {
      assert.strictEqual(isShellSafe('main | cat /etc/passwd'), false);
      assert.strictEqual(isShellSafe('test|whoami'), false);
    });

    it('should reject strings with backticks', function() {
      assert.strictEqual(isShellSafe('main`whoami`'), false);
      assert.strictEqual(isShellSafe('`id`'), false);
    });

    it('should reject strings with dollar signs', function() {
      assert.strictEqual(isShellSafe('main$(whoami)'), false);
      assert.strictEqual(isShellSafe('$PATH'), false);
    });

    it('should reject strings with ampersands', function() {
      assert.strictEqual(isShellSafe('main & whoami'), false);
      assert.strictEqual(isShellSafe('test&&id'), false);
    });

    it('should reject strings with redirects', function() {
      assert.strictEqual(isShellSafe('main > /tmp/file'), false);
      assert.strictEqual(isShellSafe('test < input'), false);
    });

    it('should reject strings with parentheses', function() {
      assert.strictEqual(isShellSafe('(whoami)'), false);
    });

    it('should reject strings with newlines', function() {
      assert.strictEqual(isShellSafe('main\nwhoami'), false);
    });

    it('should reject non-string types', function() {
      assert.strictEqual(isShellSafe(123), false);
      assert.strictEqual(isShellSafe(null), false);
      assert.strictEqual(isShellSafe(undefined), false);
      assert.strictEqual(isShellSafe({}), false);
    });
  });

  describe('isValidGitUrl()', function() {
    it('should accept valid HTTPS Git URLs', function() {
      assert.strictEqual(isValidGitUrl('https://github.com/user/repo.git'), true);
      assert.strictEqual(isValidGitUrl('https://gitlab.com/user/repo.git'), true);
    });

    it('should accept valid SSH Git URLs', function() {
      assert.strictEqual(isValidGitUrl('git@github.com:user/repo.git'), true);
      assert.strictEqual(isValidGitUrl('git@gitlab.com:user/repo.git'), true);
    });

    it('should accept valid git:// URLs', function() {
      assert.strictEqual(isValidGitUrl('git://github.com/user/repo.git'), true);
    });

    it('should reject URLs with command injection attempts', function() {
      assert.strictEqual(isValidGitUrl('https://github.com/user/repo.git; whoami'), false);
      assert.strictEqual(isValidGitUrl('git@github.com:user/repo.git`id`'), false);
      assert.strictEqual(isValidGitUrl('https://github.com/user/repo.git | cat /etc/passwd'), false);
    });

    it('should reject URLs with shell metacharacters', function() {
      assert.strictEqual(isValidGitUrl('https://github.com/user/repo.git$(whoami)'), false);
      assert.strictEqual(isValidGitUrl('git@github.com:user/repo.git&whoami'), false);
    });

    it('should reject empty or non-string URLs', function() {
      assert.strictEqual(isValidGitUrl(''), false);
      assert.strictEqual(isValidGitUrl(null), false);
      assert.strictEqual(isValidGitUrl(undefined), false);
      assert.strictEqual(isValidGitUrl(123), false);
    });

    it('should reject malformed URLs', function() {
      assert.strictEqual(isValidGitUrl('not-a-url'), false);
      assert.strictEqual(isValidGitUrl('ftp://example.com/repo.git'), false);
    });
  });

  describe('isValidGitRef()', function() {
    it('should accept valid branch names', function() {
      assert.strictEqual(isValidGitRef('main'), true);
      assert.strictEqual(isValidGitRef('develop'), true);
      assert.strictEqual(isValidGitRef('feature-branch'), true);
      assert.strictEqual(isValidGitRef('feature/new-feature'), true);
    });

    it('should accept valid tag names', function() {
      assert.strictEqual(isValidGitRef('v1.0.0'), true);
      assert.strictEqual(isValidGitRef('release-2.0'), true);
    });

    it('should reject refs with command injection attempts', function() {
      assert.strictEqual(isValidGitRef('main; id #'), false);
      assert.strictEqual(isValidGitRef('main`whoami`'), false);
      assert.strictEqual(isValidGitRef('main$(whoami)'), false);
    });

    it('should reject refs with shell metacharacters', function() {
      assert.strictEqual(isValidGitRef('main | cat /etc/passwd'), false);
      assert.strictEqual(isValidGitRef('main & whoami'), false);
      assert.strictEqual(isValidGitRef('main>file'), false);
    });

    it('should reject refs with double dots', function() {
      assert.strictEqual(isValidGitRef('main..develop'), false);
    });

    it('should reject refs with double slashes', function() {
      assert.strictEqual(isValidGitRef('feature//branch'), false);
    });

    it('should reject refs with leading or trailing slashes', function() {
      assert.strictEqual(isValidGitRef('/main'), false);
      assert.strictEqual(isValidGitRef('main/'), false);
    });

    it('should reject refs starting with dot or hyphen', function() {
      assert.strictEqual(isValidGitRef('.hidden'), false);
      assert.strictEqual(isValidGitRef('-branch'), false);
    });

    it('should reject empty or non-string refs', function() {
      assert.strictEqual(isValidGitRef(''), false);
      assert.strictEqual(isValidGitRef(null), false);
      assert.strictEqual(isValidGitRef(undefined), false);
      assert.strictEqual(isValidGitRef(123), false);
    });

    it('should reject refs with control characters', function() {
      assert.strictEqual(isValidGitRef('main\nwhoami'), false);
      assert.strictEqual(isValidGitRef('main\rwhoami'), false);
      assert.strictEqual(isValidGitRef('main\twhoami'), false);
    });
  });

  describe('validateWorkflowInputs()', function() {
    it('should validate safe repository_url and branch inputs', function() {
      const inputs = {
        repository_url: 'https://github.com/user/repo.git',
        branch: 'main'
      };
      const schema = {
        repository_url: { type: 'string', required: true },
        branch: { type: 'string', required: true }
      };
      
      const result = validateWorkflowInputs(inputs, schema);
      assert.strictEqual(result.valid, true);
      assert.strictEqual(result.errors.length, 0);
    });

    it('should reject repository_url with command injection', function() {
      const inputs = {
        repository_url: 'https://github.com/user/repo.git; whoami',
        branch: 'main'
      };
      const schema = {
        repository_url: { type: 'string', required: true },
        branch: { type: 'string', required: true }
      };
      
      const result = validateWorkflowInputs(inputs, schema);
      assert.strictEqual(result.valid, false);
      assert.ok(result.errors.length > 0);
      assert.ok(result.errors[0].includes('repository_url'));
    });

    it('should reject branch with command injection (semicolon attack)', function() {
      const inputs = {
        repository_url: 'https://github.com/user/repo.git',
        branch: 'main; id #'
      };
      const schema = {
        repository_url: { type: 'string', required: true },
        branch: { type: 'string', required: true }
      };
      
      const result = validateWorkflowInputs(inputs, schema);
      assert.strictEqual(result.valid, false);
      assert.ok(result.errors.length > 0);
      assert.ok(result.errors[0].includes('branch'));
    });

    it('should reject branch with command injection (backtick attack)', function() {
      const inputs = {
        repository_url: 'https://github.com/user/repo.git',
        branch: 'main`whoami`'
      };
      const schema = {
        repository_url: { type: 'string', required: true },
        branch: { type: 'string', required: true }
      };
      
      const result = validateWorkflowInputs(inputs, schema);
      assert.strictEqual(result.valid, false);
      assert.ok(result.errors.length > 0);
      assert.ok(result.errors[0].includes('branch'));
    });

    it('should reject base_branch with command injection', function() {
      const inputs = {
        repository_url: 'https://github.com/user/repo.git',
        branch: 'feature',
        base_branch: 'main | cat /etc/passwd'
      };
      const schema = {
        repository_url: { type: 'string', required: true },
        branch: { type: 'string', required: true },
        base_branch: { type: 'string', required: false }
      };
      
      const result = validateWorkflowInputs(inputs, schema);
      assert.strictEqual(result.valid, false);
      assert.ok(result.errors.length > 0);
      assert.ok(result.errors[0].includes('base_branch'));
    });

    it('should validate enum constraints', function() {
      const inputs = {
        environment: 'invalid'
      };
      const schema = {
        environment: { type: 'string', enum: ['dev', 'staging', 'prod'] }
      };
      
      const result = validateWorkflowInputs(inputs, schema);
      assert.strictEqual(result.valid, false);
      assert.ok(result.errors[0].includes('must be one of'));
    });

    it('should validate type constraints', function() {
      const inputs = {
        count: 'not-a-number'
      };
      const schema = {
        count: { type: 'number' }
      };
      
      const result = validateWorkflowInputs(inputs, schema);
      assert.strictEqual(result.valid, false);
      assert.ok(result.errors[0].includes('must be a number'));
    });

    it('should validate boolean type', function() {
      const inputs = {
        enabled: 'yes'
      };
      const schema = {
        enabled: { type: 'boolean' }
      };
      
      const result = validateWorkflowInputs(inputs, schema);
      assert.strictEqual(result.valid, false);
      assert.ok(result.errors[0].includes('must be a boolean'));
    });

    it('should apply basic validation when no schema provided', function() {
      const inputs = {
        safe_value: 'hello',
        dangerous_value: 'test; whoami'
      };
      
      const result = validateWorkflowInputs(inputs, null);
      assert.strictEqual(result.valid, false);
      assert.ok(result.errors.length > 0);
      assert.ok(result.errors[0].includes('dangerous_value'));
    });

    it('should reject non-object inputs', function() {
      const result = validateWorkflowInputs('not-an-object', {});
      assert.strictEqual(result.valid, false);
      assert.ok(result.errors[0].includes('must be an object'));
    });

    it('should skip validation for undefined optional inputs', function() {
      const inputs = {
        repository_url: 'https://github.com/user/repo.git'
      };
      const schema = {
        repository_url: { type: 'string', required: true },
        branch: { type: 'string', required: false }
      };
      
      const result = validateWorkflowInputs(inputs, schema);
      assert.strictEqual(result.valid, true);
    });
  });

  describe('Integration: Pentest Reproduction Scenarios', function() {
    it('should block code-review workflow with malicious branch input', function() {
      // Simulates the pentest finding: branch value "main; id #"
      const inputs = {
        repository_url: 'https://github.com/user/repo.git',
        branch: 'main; id #',
        base_branch: 'main'
      };
      const schema = {
        repository_url: { type: 'string', required: true },
        branch: { type: 'string', required: true },
        base_branch: { type: 'string', required: false }
      };
      
      const result = validateWorkflowInputs(inputs, schema);
      assert.strictEqual(result.valid, false, 'Should reject malicious branch input');
      assert.ok(result.errors.some(e => e.includes('branch')), 'Error should mention branch');
    });

    it('should block deployment workflow with malicious repository_url', function() {
      // Simulates command injection through repository URL
      const inputs = {
        repository_url: 'https://github.com/user/repo.git`whoami`',
        branch: 'main'
      };
      const schema = {
        repository_url: { type: 'string', required: true },
        branch: { type: 'string', required: true }
      };
      
      const result = validateWorkflowInputs(inputs, schema);
      assert.strictEqual(result.valid, false, 'Should reject malicious repository_url');
      assert.ok(result.errors.some(e => e.includes('repository_url')), 'Error should mention repository_url');
    });

    it('should block security-audit workflow with malicious branch', function() {
      // Simulates the pentest finding for security-audit workflow
      const inputs = {
        repository_url: 'https://github.com/user/repo.git',
        branch: 'main | cat /etc/passwd',
        scan_depth: 'full'
      };
      const schema = {
        repository_url: { type: 'string', required: true },
        branch: { type: 'string', required: true },
        scan_depth: { type: 'string', required: false }
      };
      
      const result = validateWorkflowInputs(inputs, schema);
      assert.strictEqual(result.valid, false, 'Should reject malicious branch input');
      assert.ok(result.errors.some(e => e.includes('branch')), 'Error should mention branch');
    });

    it('should allow legitimate branch names with special characters', function() {
      const inputs = {
        repository_url: 'https://github.com/user/repo.git',
        branch: 'feature/JIRA-123_fix-bug',
        base_branch: 'develop'
      };
      const schema = {
        repository_url: { type: 'string', required: true },
        branch: { type: 'string', required: true },
        base_branch: { type: 'string', required: false }
      };
      
      const result = validateWorkflowInputs(inputs, schema);
      assert.strictEqual(result.valid, true, 'Should accept legitimate branch names');
      assert.strictEqual(result.errors.length, 0);
    });
  });
});
