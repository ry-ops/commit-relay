const rateLimit = require('express-rate-limit');

// GitHub API rate limiting
const githubApiLimiter = rateLimit({
  windowMs: 60 * 60 * 1000, // 1 hour
  max: 4500, // 90% of GitHub's 5000/hour limit
  message: 'GitHub API rate limit exceeded. Try again in an hour.',
  standardHeaders: true,
  legacyHeaders: false,
  handler: (req, res) => {
    res.status(429).json({
      error: 'rate_limit_exceeded',
      message: 'GitHub API rate limit exceeded',
      retry_after: req.rateLimit.resetTime,
      documentation: 'https://docs.github.com/en/rest/overview/resources-in-the-rest-api#rate-limiting'
    });
  }
});

// Achievement API rate limiting
const achievementApiLimiter = rateLimit({
  windowMs: 15 * 60 * 1000, // 15 minutes
  max: 100, // 100 requests per 15 minutes
  message: 'Too many requests. Please try again later.',
  keyGenerator: (req) => {
    return req.headers['x-api-key'] || req.ip;
  }
});

// Worker spawn rate limiting
const workerSpawnLimiter = rateLimit({
  windowMs: 60 * 60 * 1000, // 1 hour
  max: 20, // Max 20 worker spawns per hour
  skipSuccessfulRequests: false,
  handler: (req, res) => {
    res.status(429).json({
      error: 'spawn_limit_exceeded',
      message: 'Worker spawn rate limit exceeded',
      max_workers_per_hour: 20,
      retry_after: req.rateLimit.resetTime
    });
  }
});

// Adaptive rate limiter with backoff
class AdaptiveRateLimiter {
  constructor(config) {
    this.config = config;
    this.requestCounts = new Map();
    this.backoffMultiplier = 1.0;
  }

  async checkLimit(identifier, metadata = {}) {
    const now = Date.now();
    const windowStart = now - this.config.windowMs;
    
    // Get request history
    if (!this.requestCounts.has(identifier)) {
      this.requestCounts.set(identifier, []);
    }
    
    const requests = this.requestCounts.get(identifier);
    const recentRequests = requests.filter(ts => ts > windowStart);
    
    // Calculate adaptive limit
    const adaptiveMax = Math.floor(this.config.max / this.backoffMultiplier);
    
    if (recentRequests.length >= adaptiveMax) {
      // Increase backoff on limit hits
      this.backoffMultiplier = Math.min(this.backoffMultiplier * 1.5, 10);
      
      return {
        allowed: false,
        retryAfter: windowStart + this.config.windowMs - now,
        limit: adaptiveMax,
        remaining: 0,
        backoffMultiplier: this.backoffMultiplier
      };
    }
    
    // Decrease backoff on successful requests
    this.backoffMultiplier = Math.max(this.backoffMultiplier * 0.95, 1.0);
    
    // Record request
    recentRequests.push(now);
    this.requestCounts.set(identifier, recentRequests);
    
    return {
      allowed: true,
      limit: adaptiveMax,
      remaining: adaptiveMax - recentRequests.length - 1,
      backoffMultiplier: this.backoffMultiplier
    };
  }

  reset(identifier) {
    this.requestCounts.delete(identifier);
    this.backoffMultiplier = 1.0;
  }
}

module.exports = {
  githubApiLimiter,
  achievementApiLimiter,
  workerSpawnLimiter,
  AdaptiveRateLimiter
};
