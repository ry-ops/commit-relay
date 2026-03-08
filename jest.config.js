module.exports = {
  testEnvironment: 'node',
  collectCoverage: true,
  coverageDirectory: 'coverage',
  coverageReporters: ['text', 'lcov', 'html', 'json-summary'],
  collectCoverageFrom: [
    'lib/governance/compliance.js',
    'lib/governance/quality-validator.js',
    '!**/node_modules/**',
    '!**/testing/**',
    '!**/*.test.js',
    '!**/*-cli.js'
  ],
  coverageThreshold: {
    global: {
      branches: 60,
      functions: 70,
      lines: 70,
      statements: 70
    }
  },
  testMatch: [
    '**/testing/**/*.test.js'
  ],
  testPathIgnorePatterns: [
    '/node_modules/',
    '/dashboard/node_modules/'
  ],
  verbose: true,
  testTimeout: 10000
};
