# Testing Strategy

## Overview

Comprehensive testing strategy for commit-relay ensuring reliability, maintainability, and confidence in deployments.

**Testing Pyramid**: Unit (70%) → Integration (20%) → E2E (10%)

---

## Unit Testing

### Framework: Jest

**Configuration** (`jest.config.js`):
```javascript
module.exports = {
  testEnvironment: 'node',
  coverageThreshold: {
    global: {
      branches: 80,
      functions: 80,
      lines: 80,
      statements: 80
    }
  },
  collectCoverageFrom: [
    'lib/**/*.js',
    'coordination/masters/**/*.js',
    '!**/node_modules/**'
  ],
  testMatch: [
    '**/__tests__/**/*.test.js',
    '**/testing/unit/**/*.test.js'
  ]
};
```

### Example: Achievement Tracker Unit Tests

```javascript
// __tests__/achievement-tracker.test.js
const AchievementTracker = require('../lib/achievement-tracker');

describe('AchievementTracker', () => {
  let tracker;
  
  beforeEach(() => {
    tracker = new AchievementTracker({
      githubToken: 'test_token',
      username: 'test_user'
    });
  });
  
  describe('calculateTier', () => {
    it('should return bronze tier for 2 PRs', () => {
      const tier = tracker.calculateTier('pull_shark', 2);
      expect(tier).toBe('bronze');
    });
    
    it('should return silver tier for 16 PRs', () => {
      const tier = tracker.calculateTier('pull_shark', 16);
      expect(tier).toBe('silver');
    });
    
    it('should return gold tier for 128 PRs', () => {
      const tier = tracker.calculateTier('pull_shark', 128);
      expect(tier).toBe('gold');
    });
  });
  
  describe('getOpportunityScores', () => {
    it('should score high-priority achievements higher', async () => {
      const scores = await tracker.getOpportunityScores();
      const quickdraw = scores.top_3.find(s => s.id === 'quickdraw');
      expect(quickdraw.opportunity_score).toBeGreaterThan(50);
    });
  });
});
```

### Mocking GitHub API

```javascript
// __mocks__/github-api.js
class MockGitHubAPI {
  constructor() {
    this.calls = [];
  }
  
  async githubRequest(endpoint) {
    this.calls.push(endpoint);
    
    if (endpoint.includes('/search/issues')) {
      return { total_count: 16, items: [] };
    }
    
    if (endpoint.includes('/repos')) {
      return { stargazers_count: 2 };
    }
    
    throw new Error(`Unmocked endpoint: ${endpoint}`);
  }
}

module.exports = MockGitHubAPI;
```

---

## Integration Testing

### Framework: Bash + JSON validation

**Location**: `testing/integration/`

### Example: MoE Routing Integration Test

```bash
#!/usr/bin/env bash
# testing/integration/moe-router.test.sh

source "$(dirname "$0")/../../scripts/lib/test-helpers.sh"

test_moe_routing() {
  describe "MoE Task Routing"
  
  # Create test task
  local task_id="test-routing-$(date +%s)"
  local task_file="coordination/tasks/pending/${task_id}.json"
  
  jq -n \
    --arg id "$task_id" \
    --arg desc "Fix bug in user authentication" \
    '{
      task_id: $id,
      description: $desc,
      priority: "high",
      type: "bug_fix"
    }' > "$task_file"
  
  # Route task
  local result=$(GOVERNANCE_BYPASS=true \
    coordination/masters/coordinator/lib/moe-router.sh "$task_id" "Fix authentication bug")
  
  # Verify routing decision
  assert_file_exists "coordination/masters/coordinator/knowledge-base/routing-decisions.jsonl"
  
  local assigned_master=$(jq -r 'select(.task_id == "'$task_id'") | .assigned_master' \
    coordination/masters/coordinator/knowledge-base/routing-decisions.jsonl | tail -1)
  
  assert_equals "development-master" "$assigned_master"
  
  # Verify confidence score
  local confidence=$(jq -r 'select(.task_id == "'$task_id'") | .confidence' \
    coordination/masters/coordinator/knowledge-base/routing-decisions.jsonl | tail -1)
  
  assert_greater_than "$confidence" 0.5
  
  # Cleanup
  rm -f "$task_file"
}

test_moe_routing
```

### Test Helpers

```bash
# scripts/lib/test-helpers.sh

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

assert_equals() {
  local expected="$1"
  local actual="$2"
  TESTS_RUN=$((TESTS_RUN + 1))
  
  if [ "$expected" == "$actual" ]; then
    echo -e "${GREEN}✓${NC} Assert equals: $expected"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}✗${NC} Expected: $expected, Got: $actual"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

assert_file_exists() {
  local file="$1"
  TESTS_RUN=$((TESTS_RUN + 1))
  
  if [ -f "$file" ]; then
    echo -e "${GREEN}✓${NC} File exists: $file"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}✗${NC} File not found: $file"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

print_test_summary() {
  echo ""
  echo "Tests run: $TESTS_RUN"
  echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"
  echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"
  
  if [ $TESTS_FAILED -gt 0 ]; then
    exit 1
  fi
}
```

---

## End-to-End Testing

### Framework: Playwright for API testing

```javascript
// testing/e2e/achievement-api.test.js
const { test, expect } = require('@playwright/test');

test.describe('Achievement API E2E', () => {
  test('should track achievement progress', async ({ request }) => {
    const response = await request.get('http://localhost:5001/api/achievements/progress');
    expect(response.ok()).toBeTruthy();
    
    const data = await response.json();
    expect(data.summary).toBeDefined();
    expect(data.summary.total_achievements).toBeGreaterThan(0);
  });
  
  test('should return opportunity scores', async ({ request }) => {
    const response = await request.get('http://localhost:5001/api/achievements/opportunities');
    expect(response.ok()).toBeTruthy();
    
    const data = await response.json();
    expect(data.top_3).toHaveLength(3);
    expect(data.top_3[0].opportunity_score).toBeGreaterThan(0);
  });
  
  test('should handle workflow execution', async ({ request }) => {
    const response = await request.post('http://localhost:5001/api/achievements/execute/quickdraw', {
      data: { feature_name: 'test-feature' }
    });
    
    expect(response.ok()).toBeTruthy();
    const data = await response.json();
    expect(data.success).toBe(true);
  });
});
```

---

## Performance Testing

### Load Testing with Autocannon

```bash
# testing/performance/load-test.sh
#!/usr/bin/env bash

echo "🔥 Load Testing Achievement API..."

autocannon \
  --connections 100 \
  --duration 60 \
  --warmup [ -c 10 -d 5 ] \
  --json \
  --output results/load-test-$(date +%s).json \
  http://localhost:5001/api/achievements/progress

# Analyze results
node testing/performance/analyze-results.js results/load-test-*.json
```

### Performance Benchmarks

```javascript
// testing/performance/benchmarks.js
const Benchmark = require('benchmark');
const suite = new Benchmark.Suite;

suite
  .add('Achievement Tracker#calculateTier', () => {
    tracker.calculateTier('pull_shark', 16);
  })
  .add('Achievement Tracker#calculateProgress', () => {
    tracker.calculateProgress('pull_shark', 16);
  })
  .add('MoE Router#routeTask', async () => {
    await moeRouter.route({ type: 'bug_fix', priority: 'high' });
  })
  .on('cycle', (event) => {
    console.log(String(event.target));
  })
  .on('complete', function() {
    console.log('Fastest is ' + this.filter('fastest').map('name'));
  })
  .run({ async: true });
```

---

## Test Coverage

### Required Coverage Thresholds

| Component | Coverage | Threshold |
|-----------|----------|-----------|
| Achievement Tracker | 95% | 90% |
| MoE Router | 90% | 85% |
| Strategy Planner | 85% | 80% |
| API Endpoints | 80% | 75% |
| Worker Scripts | 70% | 65% |

### Coverage Report

```bash
# Generate coverage report
npm run test:coverage

# View HTML report
open coverage/lcov-report/index.html

# Upload to Codecov
bash <(curl -s https://codecov.io/bash)
```

---

## CI/CD Integration

### GitHub Actions Test Workflow

```yaml
# .github/workflows/test.yml
name: Test Suite

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Setup Node.js
        uses: actions/setup-node@v3
        with:
          node-version: '18'
      
      - name: Install dependencies
        run: npm ci
      
      - name: Run unit tests
        run: npm run test:unit
      
      - name: Run integration tests
        run: npm run test:integration
      
      - name: Generate coverage
        run: npm run test:coverage
      
      - name: Upload coverage
        uses: codecov/codecov-action@v3
```

---

## Test Data Management

### Fixtures

```javascript
// testing/fixtures/achievements.js
module.exports = {
  pullShark: {
    achievement_id: 'pull_shark',
    count: 16,
    current_tier: 'silver',
    progress: {
      current: 16,
      next_tier: 'gold',
      next_requirement: 128,
      percentage: 12.5
    }
  },
  
  quickdraw: {
    achievement_id: 'quickdraw',
    count: 1,
    unlocked: true
  }
};
```

---

## Running Tests

```bash
# All tests
npm test

# Unit tests only
npm run test:unit

# Integration tests only
npm run test:integration

# E2E tests only
npm run test:e2e

# Performance tests
npm run test:performance

# Watch mode
npm run test:watch

# Coverage
npm run test:coverage
```

---

**Last Updated**: 2025-11-25  
**Coverage Target**: 80%  
**Test Count**: 150+ tests
