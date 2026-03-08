# Error Handling Patterns

## Overview

Standardized error handling patterns for commit-relay ensuring consistent error responses, proper error propagation, and effective debugging.

**Principles**: Fail fast, fail informative, fail recoverable

---

## Custom Error Classes

### Base Error Class

```javascript
class CommitRelayError extends Error {
  constructor(message, options = {}) {
    super(message);
    this.name = this.constructor.name;
    this.code = options.code;
    this.statusCode = options.statusCode || 500;
    this.context = options.context || {};
    this.isOperational = true; // vs programmer errors
    
    Error.captureStackTrace(this, this.constructor);
  }
  
  toJSON() {
    return {
      name: this.name,
      message: this.message,
      code: this.code,
      statusCode: this.statusCode,
      context: this.context
    };
  }
}
```

### Domain-Specific Errors

```javascript
// API Errors
class APIError extends CommitRelayError {
  constructor(message, statusCode = 500, context = {}) {
    super(message, { statusCode, code: 'API_ERROR', context });
  }
}

class NotFoundError extends APIError {
  constructor(resource, identifier) {
    super(`${resource} not found: ${identifier}`, 404, { resource, identifier });
    this.code = 'NOT_FOUND';
  }
}

class ValidationError extends APIError {
  constructor(fields) {
    super('Validation failed', 400, { fields });
    this.code = 'VALIDATION_ERROR';
  }
}

// GitHub API Errors
class GitHubAPIError extends CommitRelayError {
  constructor(message, statusCode, context = {}) {
    super(message, { statusCode, code: 'GITHUB_API_ERROR', context });
  }
}

class RateLimitError extends GitHubAPIError {
  constructor(resetTime) {
    super('GitHub API rate limit exceeded', 429, { resetTime });
    this.code = 'RATE_LIMIT_EXCEEDED';
  }
}

// Worker Errors
class WorkerError extends CommitRelayError {
  constructor(message, workerId, context = {}) {
    super(message, { code: 'WORKER_ERROR', context: { workerId, ...context } });
  }
}

class WorkerTimeoutError extends WorkerError {
  constructor(workerId, timeout) {
    super(`Worker timeout after ${timeout}ms`, workerId, { timeout });
    this.code = 'WORKER_TIMEOUT';
  }
}

// Task Errors
class TaskError extends CommitRelayError {
  constructor(message, taskId, context = {}) {
    super(message, { code: 'TASK_ERROR', context: { taskId, ...context } });
  }
}
```

---

## Error Handling Strategies

### 1. Try-Catch with Specific Handling

```javascript
async function fetchAchievementProgress(username) {
  try {
    const response = await githubAPI.request(`/search/issues`, {
      q: `author:${username}+type:pr+is:merged`
    });
    
    return response.data;
    
  } catch (error) {
    // Handle specific error types
    if (error.status === 404) {
      throw new NotFoundError('User', username);
    }
    
    if (error.status === 403) {
      const resetTime = error.response.headers['x-ratelimit-reset'];
      throw new RateLimitError(new Date(resetTime * 1000));
    }
    
    if (error.status === 401) {
      throw new APIError('Invalid GitHub token', 401);
    }
    
    // Wrap unknown errors
    throw new GitHubAPIError(
      `GitHub API request failed: ${error.message}`,
      error.status || 500,
      { endpoint: '/search/issues', username }
    );
  }
}
```

### 2. Async Error Boundaries

```javascript
// Express middleware for async route handlers
function asyncHandler(fn) {
  return (req, res, next) => {
    Promise.resolve(fn(req, res, next)).catch(next);
  };
}

// Usage
app.get('/api/achievements/:username', asyncHandler(async (req, res) => {
  const { username } = req.params;
  const progress = await fetchAchievementProgress(username);
  res.json(progress);
}));
```

### 3. Graceful Degradation

```javascript
async function getAchievementData(username) {
  let primarySource, fallbackSource;
  
  try {
    // Try primary data source (GitHub API)
    primarySource = await fetchFromGitHub(username);
    return { data: primarySource, source: 'github' };
    
  } catch (error) {
    logger.warn('Primary source failed, trying fallback', { error: error.message });
    
    try {
      // Fallback to cached data
      fallbackSource = await fetchFromCache(username);
      return { data: fallbackSource, source: 'cache', stale: true };
      
    } catch (fallbackError) {
      // Both sources failed
      throw new APIError(
        'Failed to fetch achievement data from all sources',
        503,
        {
          primaryError: error.message,
          fallbackError: fallbackError.message
        }
      );
    }
  }
}
```

### 4. Retry with Exponential Backoff

```javascript
async function retryWithBackoff(fn, maxRetries = 3, baseDelay = 1000) {
  for (let attempt = 1; attempt <= maxRetries; attempt++) {
    try {
      return await fn();
    } catch (error) {
      const isLastAttempt = attempt === maxRetries;
      const isRetriable = error.statusCode >= 500 || error.code === 'RATE_LIMIT_EXCEEDED';
      
      if (isLastAttempt || !isRetriable) {
        throw error;
      }
      
      const delay = baseDelay * Math.pow(2, attempt - 1);
      logger.info(`Retry attempt ${attempt}/${maxRetries} after ${delay}ms`, {
        error: error.message
      });
      
      await sleep(delay);
    }
  }
}

// Usage
const data = await retryWithBackoff(
  () => fetchAchievementProgress(username),
  3,  // max 3 retries
  2000  // start with 2s delay
);
```

---

## Centralized Error Handler

### Express Error Middleware

```javascript
// error-handler.js
function errorHandler(err, req, res, next) {
  // Log error
  logger.error('Request failed', {
    error: err.message,
    stack: err.stack,
    request_id: req.id,
    path: req.path,
    method: req.method,
    user: req.user?.username
  });
  
  // Don't leak error details in production
  const isDevelopment = process.env.NODE_ENV === 'development';
  
  // Determine status code
  const statusCode = err.statusCode || 500;
  
  // Send error response
  res.status(statusCode).json({
    error: {
      message: err.message,
      code: err.code,
      status: statusCode,
      ...(isDevelopment && { stack: err.stack }),
      ...(err.context && { context: err.context })
    }
  });
  
  // Report to APM
  if (err.statusCode >= 500) {
    apm.captureError(err);
  }
}

// Register as last middleware
app.use(errorHandler);
```

---

## Error Recovery Patterns

### Circuit Breaker

```javascript
class CircuitBreaker {
  constructor(fn, options = {}) {
    this.fn = fn;
    this.failureThreshold = options.failureThreshold || 5;
    this.resetTimeout = options.resetTimeout || 60000;
    this.state = 'CLOSED';
    this.failures = 0;
    this.nextAttempt = Date.now();
  }
  
  async execute(...args) {
    if (this.state === 'OPEN') {
      if (Date.now() < this.nextAttempt) {
        throw new Error('Circuit breaker is OPEN');
      }
      this.state = 'HALF_OPEN';
    }
    
    try {
      const result = await this.fn(...args);
      this.onSuccess();
      return result;
    } catch (error) {
      this.onFailure();
      throw error;
    }
  }
  
  onSuccess() {
    this.failures = 0;
    this.state = 'CLOSED';
  }
  
  onFailure() {
    this.failures++;
    if (this.failures >= this.failureThreshold) {
      this.state = 'OPEN';
      this.nextAttempt = Date.now() + this.resetTimeout;
      logger.warn('Circuit breaker opened', {
        failures: this.failures,
        resetAt: new Date(this.nextAttempt)
      });
    }
  }
}

// Usage
const githubAPICircuitBreaker = new CircuitBreaker(
  fetchFromGitHub,
  { failureThreshold: 5, resetTimeout: 60000 }
);

const data = await githubAPICircuitBreaker.execute(username);
```

---

## Validation Errors

### Input Validation

```javascript
const Joi = require('joi');

const achievementSchema = Joi.object({
  username: Joi.string().alphanum().min(1).max(39).required(),
  achievement_id: Joi.string().valid('pull_shark', 'quickdraw', 'yolo').required(),
  limit: Joi.number().integer().min(1).max(100).default(10)
});

function validateInput(schema, data) {
  const { error, value } = schema.validate(data, { abortEarly: false });
  
  if (error) {
    const fields = error.details.map(d => ({
      field: d.path.join('.'),
      message: d.message
    }));
    
    throw new ValidationError(fields);
  }
  
  return value;
}

// Usage
app.post('/api/achievements', (req, res) => {
  const validated = validateInput(achievementSchema, req.body);
  // ... process request
});
```

---

## Error Monitoring

### Elastic APM Integration

```javascript
const apm = require('elastic-apm-node');

function reportError(error, context = {}) {
  apm.captureError(error, {
    custom: context,
    user: context.user,
    labels: {
      error_code: error.code,
      severity: error.statusCode >= 500 ? 'high' : 'medium'
    }
  });
}
```

### Error Aggregation

```javascript
// Count errors by type
const errorCounts = new Map();

function trackError(error) {
  const key = error.code || 'UNKNOWN';
  errorCounts.set(key, (errorCounts.get(key) || 0) + 1);
  
  // Alert if threshold exceeded
  if (errorCounts.get(key) > 10) {
    alertOps(`High error rate: ${key} occurred ${errorCounts.get(key)} times`);
  }
}
```

---

## Best Practices

1. **Always use custom error classes** - Don't throw raw strings
2. **Include context** - Add relevant debugging information
3. **Log before throwing** - Ensure errors are tracked
4. **Handle errors at boundaries** - API routes, worker entry points
5. **Never swallow errors silently** - Always log or rethrow
6. **Use error codes** - Enable programmatic error handling
7. **Sanitize error messages** - Don't leak sensitive data
8. **Test error paths** - Include error cases in tests

---

**Last Updated**: 2025-11-25  
**Error Classes**: 10+  
**Patterns Documented**: 8
