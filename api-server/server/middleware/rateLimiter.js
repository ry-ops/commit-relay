/**
 * Rate Limiting Middleware
 * Protects API from abuse and DoS attacks
 */

const rateLimit = require('express-rate-limit');

// General API rate limiter - COMPLETELY DISABLED for commit-relay internal use
const apiLimiter = rateLimit({
  windowMs: parseInt(process.env.RATE_LIMIT_WINDOW_MS) || 15 * 60 * 1000,
  max: 999999, // Effectively unlimited
  skip: () => true  // ALWAYS SKIP - No rate limiting for internal APIs
});

// Strict rate limiter for control endpoints (daemon control, server restart, etc.)
// DISABLED for service management - services must never be throttled
const controlLimiter = rateLimit({
  windowMs: 60 * 1000, // 1 minute
  max: parseInt(process.env.CONTROL_RATE_LIMIT_MAX) || 100000, // Effectively unlimited
  message: {
    error: 'Too many control requests',
    message: 'You are making too many control requests. Please wait before trying again.',
    retryAfter: 'Check Retry-After header'
  },
  standardHeaders: true,
  legacyHeaders: false,
  // COMPLETELY DISABLE rate limiting for all service/daemon management
  skip: (req) => {
    // Always skip - services must NEVER be throttled by their own API
    return true;
  }
});

// Expensive operations limiter - DISABLED for development
const expensiveLimiter = rateLimit({
  windowMs: 5 * 60 * 1000,
  max: 999999, // Effectively unlimited
  skip: () => true  // ALWAYS SKIP
});

// Lenient rate limiter for GET requests - COMPLETELY DISABLED
const getLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: 999999, // Effectively unlimited
  skip: () => true  // ALWAYS SKIP - No rate limiting
});

module.exports = {
  apiLimiter,
  controlLimiter,
  expensiveLimiter,
  getLimiter
};
