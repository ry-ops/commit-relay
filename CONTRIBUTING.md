# Contributing to commit-relay

Thank you for your interest in contributing to commit-relay! This document provides guidelines and instructions for contributing.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Development Workflow](#development-workflow)
- [Pull Request Process](#pull-request-process)
- [Coding Standards](#coding-standards)
- [Testing Requirements](#testing-requirements)
- [Documentation](#documentation)

---

## Code of Conduct

### Our Pledge

We are committed to providing a welcoming and inclusive environment for all contributors.

### Our Standards

**Positive Behavior**:
- Using welcoming and inclusive language
- Being respectful of differing viewpoints
- Gracefully accepting constructive criticism
- Focusing on what is best for the community

**Unacceptable Behavior**:
- Harassment or discriminatory language
- Trolling or insulting comments
- Publishing others' private information
- Other conduct that could reasonably be considered inappropriate

---

## Getting Started

### Prerequisites

- Node.js 18+ 
- npm 9+
- Git
- GitHub account

### Fork and Clone

```bash
# Fork the repository on GitHub
# Then clone your fork
git clone https://github.com/YOUR_USERNAME/commit-relay.git
cd commit-relay

# Add upstream remote
git remote add upstream https://github.com/ry-ops/commit-relay.git
```

### Install Dependencies

```bash
npm install
```

### Environment Setup

```bash
# Copy example environment file
cp .env.example .env

# Add required credentials
export GITHUB_TOKEN="your_token_here"
export ELASTIC_APM_SECRET_TOKEN="your_apm_token"
```

### Verify Installation

```bash
# Run tests
npm test

# Start development server
npm run dev
```

---

## Development Workflow

### 1. Create a Branch

```bash
# Update main branch
git checkout main
git pull upstream main

# Create feature branch
git checkout -b feat/your-feature-name
```

### Branch Naming Conventions

- `feat/` - New features
- `fix/` - Bug fixes
- `docs/` - Documentation changes
- `refactor/` - Code refactoring
- `test/` - Test additions or updates
- `chore/` - Maintenance tasks

### 2. Make Changes

- Write clean, readable code
- Follow existing code style
- Add tests for new functionality
- Update documentation as needed

### 3. Test Your Changes

```bash
# Run unit tests
npm run test:unit

# Run integration tests
npm run test:integration

# Check code coverage
npm run test:coverage

# Lint code
npm run lint
```

### 4. Commit Your Changes

```bash
# Stage changes
git add .

# Commit with conventional commit message
git commit -m "feat: add achievement progress CLI

- Add interactive CLI for tracking achievements
- Include opportunity scoring command
- Add workflow execution from CLI

Co-Authored-By: YourName <your.email@example.com>"
```

### Commit Message Format

```
<type>(<scope>): <subject>

<body>

<footer>
```

**Types**:
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation
- `style`: Formatting
- `refactor`: Code restructuring
- `test`: Adding tests
- `chore`: Maintenance

**Example**:
```
feat(achievement): add GitHub GraphQL support

- Replace REST API calls with GraphQL queries
- Reduce API calls from 15 to 1
- Improve response time by 80%

Closes #123
```

---

## Pull Request Process

### 1. Push to Your Fork

```bash
git push origin feat/your-feature-name
```

### 2. Create Pull Request

1. Go to https://github.com/ry-ops/commit-relay
2. Click "New Pull Request"
3. Select your fork and branch
4. Fill out the PR template

### PR Template

```markdown
## Summary
Brief description of changes

## Changes
- Bullet list of changes
- Each change on new line

## Testing
How were changes tested?

## Screenshots (if applicable)
Add screenshots for UI changes

## Checklist
- [ ] Tests added/updated
- [ ] Documentation updated
- [ ] Code follows style guidelines
- [ ] Self-review completed
- [ ] No breaking changes (or documented)
```

### 3. Code Review

- Address reviewer feedback
- Push updates to same branch
- Request re-review when ready

### 4. Merge

Once approved:
- Squash commits (if needed)
- Maintainer will merge PR
- Delete branch after merge

---

## Coding Standards

### JavaScript Style

```javascript
// Use const by default
const apiKey = process.env.API_KEY;

// Use let for reassignment
let counter = 0;

// Avoid var
// ❌ var data = {};

// Use arrow functions
const calculateScore = (count) => count * 10;

// Use template literals
const message = `Score: ${score}`;

// Use async/await over promises
async function fetchData() {
  const response = await api.get('/data');
  return response.data;
}
```

### File Organization

```
├── lib/                    # Core library code
│   ├── achievement-tracker.js
│   └── strategy-planner.js
├── scripts/                # Utility scripts
│   ├── deployment/
│   └── security/
├── coordination/           # MoE coordination
│   ├── masters/
│   └── tasks/
├── tests/                  # Test files
│   ├── unit/
│   └── integration/
└── docs/                   # Documentation
```

### Error Handling

```javascript
// Use try-catch for async operations
async function processTask(task) {
  try {
    const result = await executeTask(task);
    return result;
  } catch (error) {
    logger.error(`Task failed: ${error.message}`);
    throw new TaskExecutionError('Task processing failed', { cause: error });
  }
}

// Create custom error classes
class TaskExecutionError extends Error {
  constructor(message, options) {
    super(message, options);
    this.name = 'TaskExecutionError';
  }
}
```

---

## Testing Requirements

### Test Coverage Thresholds

- **Lines**: 80%
- **Functions**: 80%
- **Branches**: 75%
- **Statements**: 80%

### Writing Tests

```javascript
describe('AchievementTracker', () => {
  let tracker;
  
  beforeEach(() => {
    tracker = new AchievementTracker({
      githubToken: 'test_token',
      username: 'test_user'
    });
  });
  
  test('calculates tier correctly', () => {
    expect(tracker.calculateTier('pull_shark', 16)).toBe('silver');
  });
  
  test('handles API errors gracefully', async () => {
    // Mock API failure
    jest.spyOn(tracker, 'githubRequest').mockRejectedValue(new Error('API Error'));
    
    await expect(tracker.getAllProgress()).rejects.toThrow('API Error');
  });
});
```

---

## Documentation

### Code Comments

```javascript
/**
 * Calculates achievement tier based on count
 * 
 * @param {string} achievementId - Achievement identifier
 * @param {number} count - Current achievement count
 * @returns {string} Tier name (bronze, silver, gold, platinum)
 * 
 * @example
 * calculateTier('pull_shark', 16) // Returns 'silver'
 */
function calculateTier(achievementId, count) {
  // Implementation
}
```

### README Updates

Update README.md when:
- Adding new features
- Changing API endpoints
- Modifying configuration
- Adding dependencies

---

## Getting Help

- **Documentation**: https://github.com/ry-ops/commit-relay/wiki
- **Issues**: https://github.com/ry-ops/commit-relay/issues
- **Discussions**: https://github.com/ry-ops/commit-relay/discussions

---

## Recognition

Contributors will be recognized in:
- README.md contributors section
- Release notes
- GitHub contributors page

Thank you for contributing to commit-relay! 🚀
