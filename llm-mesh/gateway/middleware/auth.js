// Authentication Middleware
// Verifies agent identity tokens

module.exports = (registry, policyEnforcer) => {
  return (req, res, next) => {
    // Public endpoints
    if (req.path === '/health' || req.path === '/') {
      return next();
    }

    // Extract token from header
    const token = req.headers['x-agent-token'] || req.headers.authorization?.replace('Bearer ', '');

    if (!token) {
      return res.status(401).json({ error: 'No authentication token provided' });
    }

    // Verify token (simplified - integrate with identity system)
    try {
      // TODO: Integrate with lib/governance/identity/agent-identity.js
      // For now, accept any token in development
      req.agentId = req.headers['x-agent-id'] || 'anonymous';
      req.agentToken = token;
      next();
    } catch (error) {
      res.status(401).json({ error: 'Invalid token', details: error.message });
    }
  };
};
