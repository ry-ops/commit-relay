// Authentication Middleware
// Verifies agent identity tokens

const AgentIdentity = require('../../../lib/governance/identity/agent-identity');

// Initialize identity system singleton
let identitySystem = null;
const getIdentitySystem = async () => {
  if (!identitySystem) {
    identitySystem = new AgentIdentity();
    await identitySystem.initialize();
  }
  return identitySystem;
};

module.exports = (registry, policyEnforcer) => {
  return async (req, res, next) => {
    // Public endpoints
    if (req.path === '/health' || req.path === '/') {
      return next();
    }

    // Extract token from header
    const token = req.headers['x-agent-token'] || req.headers.authorization?.replace('Bearer ', '');

    if (!token) {
      return res.status(401).json({ error: 'No authentication token provided' });
    }

    // Verify token cryptographically using AgentIdentity
    try {
      const identity = await getIdentitySystem();
      const decoded = await identity.verifyToken(token);
      
      // Extract verified identity from token payload (not from headers)
      req.agentId = decoded.agent_id;
      req.agentRole = decoded.role;
      req.agentCapabilities = decoded.capabilities || [];
      req.agentTrustLevel = decoded.trust_level;
      req.agentSpiffeId = decoded.sub;
      req.agentToken = token;
      
      next();
    } catch (error) {
      res.status(401).json({ 
        error: 'Authentication failed', 
        details: error.message 
      });
    }
  };
};
