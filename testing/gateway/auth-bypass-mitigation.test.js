// Authentication Bypass Mitigation Tests
// Tests to verify that the authentication bypass vulnerability is mitigated
// Pentest Finding: Gateway authentication bypass lets callers forge agent identities

const request = require('supertest');
const express = require('express');
const jwt = require('jsonwebtoken');
const crypto = require('crypto');
const fs = require('fs').promises;
const path = require('path');

// Import the components under test
const authMiddleware = require('../../llm-mesh/gateway/middleware/auth');
const agentsRouter = require('../../llm-mesh/gateway/routes/agents');
const tasksRouter = require('../../llm-mesh/gateway/routes/tasks');
const routingRouter = require('../../llm-mesh/gateway/routes/routing');

// Mock services
class MockRegistry {
  constructor() {
    this.agents = new Map();
  }

  async register(agentId, config) {
    this.agents.set(agentId, { agent_id: agentId, ...config });
    return this.agents.get(agentId);
  }

  async unregister(agentId) {
    return this.agents.delete(agentId);
  }

  async heartbeat(agentId) {
    return this.agents.has(agentId);
  }

  getAgent(agentId) {
    return this.agents.get(agentId);
  }

  listAgents() {
    return Array.from(this.agents.values());
  }
}

class MockPolicyEnforcer {
  checkRateLimit() {
    return { allowed: true };
  }

  checkCircuitBreaker() {
    return { open: false };
  }

  validateRequest() {
    return { valid: true };
  }
}

// Helper to generate test keys
async function generateTestKeys() {
  const { publicKey, privateKey } = crypto.generateKeyPairSync('rsa', {
    modulusLength: 2048,
    publicKeyEncoding: { type: 'spki', format: 'pem' },
    privateKeyEncoding: { type: 'pkcs8', format: 'pem' }
  });
  return { publicKey, privateKey };
}

// Helper to create a valid JWT token
function createValidToken(privateKey, payload) {
  return jwt.sign(payload, privateKey, {
    algorithm: 'RS256',
    issuer: 'commit-relay-identity-system',
    audience: 'commit-relay-agents'
  });
}

describe('Authentication Bypass Mitigation Tests', () => {
  let app;
  let registry;
  let policyEnforcer;
  let testKeys;
  let validMasterToken;
  let validWorkerToken;

  beforeAll(async () => {
    // Generate test keys
    testKeys = await generateTestKeys();

    // Create test directories
    await fs.mkdir('secrets', { recursive: true });
    await fs.mkdir('coordination/governance/identities', { recursive: true });
    await fs.mkdir('coordination/tasks', { recursive: true });

    // Write test keys
    await fs.writeFile('secrets/identity-signing-key.pem', testKeys.privateKey);
    await fs.writeFile('secrets/identity-verify-key.pem', testKeys.publicKey);

    // Create identities registry
    const identitiesRegistry = {
      version: '1.0.0',
      created_at: new Date().toISOString(),
      identities: {
        'test-master': {
          spiffe_id: 'spiffe://commit-relay/masters/test-master',
          role: 'master',
          trust_level: 100,
          capabilities: ['*'],
          status: 'active'
        },
        'test-worker': {
          spiffe_id: 'spiffe://commit-relay/workers/test-worker',
          role: 'worker',
          trust_level: 50,
          capabilities: ['tasks:read', 'workers:read'],
          status: 'active'
        }
      },
      revoked: []
    };
    await fs.writeFile(
      'coordination/governance/identities/active-identities.json',
      JSON.stringify(identitiesRegistry, null, 2)
    );

    // Create valid tokens
    const masterPayload = {
      sub: 'spiffe://commit-relay/masters/test-master',
      agent_id: 'test-master',
      role: 'master',
      trust_level: 100,
      capabilities: ['*'],
      iat: Math.floor(Date.now() / 1000),
      exp: Math.floor(Date.now() / 1000) + 3600
    };
    validMasterToken = createValidToken(testKeys.privateKey, masterPayload);

    const workerPayload = {
      sub: 'spiffe://commit-relay/workers/test-worker',
      agent_id: 'test-worker',
      role: 'worker',
      trust_level: 50,
      capabilities: ['tasks:read', 'workers:read'],
      iat: Math.floor(Date.now() / 1000),
      exp: Math.floor(Date.now() / 1000) + 3600
    };
    validWorkerToken = createValidToken(testKeys.privateKey, workerPayload);
  });

  beforeEach(() => {
    // Create fresh app for each test
    app = express();
    registry = new MockRegistry();
    policyEnforcer = new MockPolicyEnforcer();

    app.use(express.json());
    app.use(authMiddleware(registry, policyEnforcer));
    app.use((req, res, next) => {
      req.registry = registry;
      req.policyEnforcer = policyEnforcer;
      next();
    });
    app.use('/api/v1/agents', agentsRouter);
    app.use('/api/v1/tasks', tasksRouter);
    app.use('/api/v1/routing', routingRouter);
  });

  afterAll(async () => {
    // Cleanup test files
    try {
      await fs.unlink('secrets/identity-signing-key.pem');
      await fs.unlink('secrets/identity-verify-key.pem');
      await fs.unlink('coordination/governance/identities/active-identities.json');
    } catch (error) {
      // Ignore cleanup errors
    }
  });

  describe('Step 1: Token Verification - Reject Missing Tokens', () => {
    test('should reject requests with no token', async () => {
      const response = await request(app)
        .get('/api/v1/agents')
        .expect(401);

      expect(response.body).toHaveProperty('error');
      expect(response.body.error).toBe('No authentication token provided');
    });

    test('should reject requests with empty token', async () => {
      const response = await request(app)
        .get('/api/v1/agents')
        .set('X-Agent-Token', '')
        .expect(401);

      expect(response.body).toHaveProperty('error');
      expect(response.body.error).toBe('No authentication token provided');
    });
  });

  describe('Step 1: Token Verification - Reject Invalid Tokens', () => {
    test('should reject arbitrary non-empty token (exploit scenario)', async () => {
      const response = await request(app)
        .get('/api/v1/agents')
        .set('X-Agent-Token', 'arbitrary-fake-token')
        .set('X-Agent-ID', 'malicious-agent')
        .expect(401);

      expect(response.body).toHaveProperty('error');
      expect(response.body.error).toBe('Authentication failed');
      expect(response.body.details).toContain('Invalid identity token');
    });

    test('should reject token with invalid signature', async () => {
      const fakeKeys = await generateTestKeys();
      const fakeToken = createValidToken(fakeKeys.privateKey, {
        sub: 'spiffe://commit-relay/masters/fake-master',
        agent_id: 'fake-master',
        role: 'master',
        capabilities: ['*'],
        iat: Math.floor(Date.now() / 1000),
        exp: Math.floor(Date.now() / 1000) + 3600
      });

      const response = await request(app)
        .get('/api/v1/agents')
        .set('X-Agent-Token', fakeToken)
        .expect(401);

      expect(response.body.error).toBe('Authentication failed');
    });

    test('should reject expired token', async () => {
      const expiredPayload = {
        sub: 'spiffe://commit-relay/masters/test-master',
        agent_id: 'test-master',
        role: 'master',
        capabilities: ['*'],
        iat: Math.floor(Date.now() / 1000) - 7200,
        exp: Math.floor(Date.now() / 1000) - 3600
      };
      const expiredToken = createValidToken(testKeys.privateKey, expiredPayload);

      const response = await request(app)
        .get('/api/v1/agents')
        .set('X-Agent-Token', expiredToken)
        .expect(401);

      expect(response.body.error).toBe('Authentication failed');
      expect(response.body.details).toContain('expired');
    });

    test('should reject token with wrong issuer', async () => {
      const wrongIssuerToken = jwt.sign(
        {
          sub: 'spiffe://commit-relay/masters/test-master',
          agent_id: 'test-master',
          role: 'master',
          capabilities: ['*']
        },
        testKeys.privateKey,
        {
          algorithm: 'RS256',
          issuer: 'wrong-issuer',
          audience: 'commit-relay-agents'
        }
      );

      const response = await request(app)
        .get('/api/v1/agents')
        .set('X-Agent-Token', wrongIssuerToken)
        .expect(401);

      expect(response.body.error).toBe('Authentication failed');
    });

    test('should reject token with wrong audience', async () => {
      const wrongAudienceToken = jwt.sign(
        {
          sub: 'spiffe://commit-relay/masters/test-master',
          agent_id: 'test-master',
          role: 'master',
          capabilities: ['*']
        },
        testKeys.privateKey,
        {
          algorithm: 'RS256',
          issuer: 'commit-relay-identity-system',
          audience: 'wrong-audience'
        }
      );

      const response = await request(app)
        .get('/api/v1/agents')
        .set('X-Agent-Token', wrongAudienceToken)
        .expect(401);

      expect(response.body.error).toBe('Authentication failed');
    });
  });

  describe('Step 1: Identity Extraction - Use Token Claims, Not Headers', () => {
    test('should ignore X-Agent-ID header and use token claims', async () => {
      const response = await request(app)
        .get('/api/v1/agents')
        .set('X-Agent-Token', validMasterToken)
        .set('X-Agent-ID', 'spoofed-agent-id')
        .expect(200);

      // The middleware should have set req.agentId from token, not header
      // We can verify this by checking that the request succeeded with master privileges
      expect(response.body).toHaveProperty('agents');
    });

    test('should extract agent identity from verified token payload', async () => {
      // Register an agent to verify identity extraction
      const response = await request(app)
        .post('/api/v1/agents/register')
        .set('X-Agent-Token', validMasterToken)
        .send({
          agent_id: 'new-agent',
          role: 'worker',
          capabilities: ['tasks:read']
        })
        .expect(200);

      expect(response.body.success).toBe(true);
      expect(response.body.agent.agent_id).toBe('new-agent');
    });
  });

  describe('Step 3: Agent Registration - Enforce Role-Based Authorization', () => {
    test('should allow master agents to register new agents', async () => {
      const response = await request(app)
        .post('/api/v1/agents/register')
        .set('X-Agent-Token', validMasterToken)
        .send({
          agent_id: 'authorized-new-agent',
          role: 'worker',
          capabilities: ['tasks:read']
        })
        .expect(200);

      expect(response.body.success).toBe(true);
      expect(response.body.agent.agent_id).toBe('authorized-new-agent');
    });

    test('should reject non-master agents from registering new agents', async () => {
      const response = await request(app)
        .post('/api/v1/agents/register')
        .set('X-Agent-Token', validWorkerToken)
        .send({
          agent_id: 'unauthorized-new-agent',
          role: 'worker',
          capabilities: ['tasks:read']
        })
        .expect(403);

      expect(response.body.error).toBe('Forbidden');
      expect(response.body.details).toContain('Only master agents can register');
    });

    test('should prevent forged registration with fake token (exploit scenario)', async () => {
      const response = await request(app)
        .post('/api/v1/agents/register')
        .set('X-Agent-Token', 'fake-token')
        .set('X-Agent-ID', 'malicious-master')
        .send({
          agent_id: 'malicious-agent',
          role: 'master',
          capabilities: ['*']
        })
        .expect(401);

      expect(response.body.error).toBe('Authentication failed');
    });
  });

  describe('Step 3: Agent Deletion - Enforce Ownership Authorization', () => {
    test('should allow master agents to delete any agent', async () => {
      // First register an agent
      await registry.register('agent-to-delete', { role: 'worker' });

      const response = await request(app)
        .delete('/api/v1/agents/agent-to-delete')
        .set('X-Agent-Token', validMasterToken)
        .expect(200);

      expect(response.body.success).toBe(true);
    });

    test('should allow agents to delete themselves', async () => {
      // Register the worker agent
      await registry.register('test-worker', { role: 'worker' });

      const response = await request(app)
        .delete('/api/v1/agents/test-worker')
        .set('X-Agent-Token', validWorkerToken)
        .expect(200);

      expect(response.body.success).toBe(true);
    });

    test('should reject non-master agents from deleting other agents', async () => {
      await registry.register('other-agent', { role: 'worker' });

      const response = await request(app)
        .delete('/api/v1/agents/other-agent')
        .set('X-Agent-Token', validWorkerToken)
        .expect(403);

      expect(response.body.error).toBe('Forbidden');
      expect(response.body.details).toContain('Insufficient privileges');
    });

    test('should prevent arbitrary deletion with spoofed identity (exploit scenario)', async () => {
      await registry.register('victim-agent', { role: 'master' });

      const response = await request(app)
        .delete('/api/v1/agents/victim-agent')
        .set('X-Agent-Token', 'fake-token')
        .set('X-Agent-ID', 'victim-agent')
        .expect(401);

      expect(response.body.error).toBe('Authentication failed');
    });
  });

  describe('Step 3: Heartbeat - Enforce Self-Only Authorization', () => {
    test('should allow agents to send heartbeat for themselves', async () => {
      await registry.register('test-worker', { role: 'worker' });

      const response = await request(app)
        .post('/api/v1/agents/test-worker/heartbeat')
        .set('X-Agent-Token', validWorkerToken)
        .expect(200);

      expect(response.body.success).toBe(true);
    });

    test('should reject agents from sending heartbeat for other agents', async () => {
      await registry.register('other-agent', { role: 'worker' });

      const response = await request(app)
        .post('/api/v1/agents/other-agent/heartbeat')
        .set('X-Agent-Token', validWorkerToken)
        .expect(403);

      expect(response.body.error).toBe('Forbidden');
      expect(response.body.details).toContain('Cannot send heartbeat for another agent');
    });
  });

  describe('Step 4: Task Operations - Enforce Capability-Based Authorization', () => {
    test('should allow agents with tasks:read capability to read tasks', async () => {
      // Create a test task file
      const taskId = 'test-task-read';
      const taskPath = path.join('coordination/tasks', `${taskId}.json`);
      await fs.writeFile(taskPath, JSON.stringify({
        task_id: taskId,
        status: 'pending'
      }));

      const response = await request(app)
        .get(`/api/v1/tasks/${taskId}`)
        .set('X-Agent-Token', validWorkerToken)
        .expect(200);

      expect(response.body.task_id).toBe(taskId);

      // Cleanup
      await fs.unlink(taskPath);
    });

    test('should reject agents without tasks:read capability from reading tasks', async () => {
      // Create a token without tasks:read capability
      const noReadPayload = {
        sub: 'spiffe://commit-relay/workers/no-read-worker',
        agent_id: 'no-read-worker',
        role: 'worker',
        trust_level: 50,
        capabilities: ['workers:spawn'],
        iat: Math.floor(Date.now() / 1000),
        exp: Math.floor(Date.now() / 1000) + 3600
      };
      const noReadToken = createValidToken(testKeys.privateKey, noReadPayload);

      const response = await request(app)
        .get('/api/v1/tasks/some-task')
        .set('X-Agent-Token', noReadToken)
        .expect(403);

      expect(response.body.error).toBe('Forbidden');
      expect(response.body.details).toContain('Insufficient privileges to read tasks');
    });

    test('should require both tasks:write capability and master role to create tasks', async () => {
      const response = await request(app)
        .post('/api/v1/tasks')
        .set('X-Agent-Token', validMasterToken)
        .send({
          task_id: 'new-task',
          description: 'Test task'
        })
        .expect(200);

      expect(response.body.success).toBe(true);
      expect(response.body.task.created_by).toBe('test-master');
      expect(response.body.task.created_by_spiffe).toBe('spiffe://commit-relay/masters/test-master');

      // Cleanup
      const taskPath = path.join('coordination/tasks', 'new-task.json');
      await fs.unlink(taskPath);
    });

    test('should reject non-master agents from creating tasks', async () => {
      const response = await request(app)
        .post('/api/v1/tasks')
        .set('X-Agent-Token', validWorkerToken)
        .send({
          task_id: 'unauthorized-task',
          description: 'Test task'
        })
        .expect(403);

      expect(response.body.error).toBe('Forbidden');
      // The error message could be either about missing capability or master role
      expect(response.body.details).toMatch(/Insufficient privileges|Only master agents/);
    });

    test('should prevent task creation with spoofed identity (exploit scenario)', async () => {
      const response = await request(app)
        .post('/api/v1/tasks')
        .set('X-Agent-Token', 'fake-token')
        .set('X-Agent-ID', 'malicious-master')
        .send({
          task_id: 'malicious-task',
          description: 'Malicious task'
        })
        .expect(401);

      expect(response.body.error).toBe('Authentication failed');
    });
  });

  describe('Step 4: Task Creation - Record Verified Identity', () => {
    test('should record verified agent identity in created tasks', async () => {
      const response = await request(app)
        .post('/api/v1/tasks')
        .set('X-Agent-Token', validMasterToken)
        .send({
          task_id: 'identity-test-task',
          description: 'Test identity recording'
        })
        .expect(200);

      expect(response.body.task.created_by).toBe('test-master');
      expect(response.body.task.created_by_spiffe).toBe('spiffe://commit-relay/masters/test-master');

      // Cleanup
      const taskPath = path.join('coordination/tasks', 'identity-test-task.json');
      await fs.unlink(taskPath);
    });

    test('should not allow spoofing created_by field', async () => {
      const response = await request(app)
        .post('/api/v1/tasks')
        .set('X-Agent-Token', validMasterToken)
        .send({
          task_id: 'spoof-test-task',
          description: 'Test',
          created_by: 'spoofed-agent',
          created_by_spiffe: 'spiffe://commit-relay/masters/spoofed-agent'
        })
        .expect(200);

      // The server should override with verified identity
      expect(response.body.task.created_by).toBe('test-master');
      expect(response.body.task.created_by_spiffe).toBe('spiffe://commit-relay/masters/test-master');

      // Cleanup
      const taskPath = path.join('coordination/tasks', 'spoof-test-task.json');
      await fs.unlink(taskPath);
    });
  });

  describe('Step 5: Revoked Token Handling', () => {
    test('should reject revoked tokens', async () => {
      // Add agent to revoked list
      const identitiesPath = 'coordination/governance/identities/active-identities.json';
      const registry = JSON.parse(await fs.readFile(identitiesPath, 'utf8'));
      registry.identities['test-master'].status = 'revoked';
      registry.revoked.push({
        agent_id: 'test-master',
        spiffe_id: 'spiffe://commit-relay/masters/test-master',
        revoked_at: new Date().toISOString(),
        reason: 'test'
      });
      await fs.writeFile(identitiesPath, JSON.stringify(registry, null, 2));

      const response = await request(app)
        .get('/api/v1/agents')
        .set('X-Agent-Token', validMasterToken)
        .expect(401);

      expect(response.body.error).toBe('Authentication failed');
      expect(response.body.details).toContain('revoked');

      // Restore for other tests
      registry.identities['test-master'].status = 'active';
      registry.revoked = [];
      await fs.writeFile(identitiesPath, JSON.stringify(registry, null, 2));
    });
  });

  describe('Agent List/Get - Enforce Capability-Based Authorization', () => {
    test('should allow agents with workers:read capability to list agents', async () => {
      const response = await request(app)
        .get('/api/v1/agents')
        .set('X-Agent-Token', validWorkerToken)
        .expect(200);

      expect(response.body).toHaveProperty('agents');
      expect(response.body).toHaveProperty('count');
    });

    test('should allow agents with workers:read capability to get agent details', async () => {
      await registry.register('test-agent', { role: 'worker' });

      const response = await request(app)
        .get('/api/v1/agents/test-agent')
        .set('X-Agent-Token', validWorkerToken)
        .expect(200);

      expect(response.body.agent_id).toBe('test-agent');
    });

    test('should reject agents without workers:read capability from listing agents', async () => {
      const noReadPayload = {
        sub: 'spiffe://commit-relay/workers/no-read-worker',
        agent_id: 'no-read-worker',
        role: 'worker',
        trust_level: 50,
        capabilities: ['tasks:write'],
        iat: Math.floor(Date.now() / 1000),
        exp: Math.floor(Date.now() / 1000) + 3600
      };
      const noReadToken = createValidToken(testKeys.privateKey, noReadPayload);

      const response = await request(app)
        .get('/api/v1/agents')
        .set('X-Agent-Token', noReadToken)
        .expect(403);

      expect(response.body.error).toBe('Forbidden');
      expect(response.body.details).toContain('Insufficient privileges to list agents');
    });
  });

  describe('Routing - Enforce Capability-Based Authorization', () => {
    test('should require tasks:route capability for routing operations', async () => {
      // Create a token with tasks:route capability
      const routePayload = {
        sub: 'spiffe://commit-relay/masters/test-master',
        agent_id: 'test-master',
        role: 'master',
        trust_level: 100,
        capabilities: ['tasks:route'],
        iat: Math.floor(Date.now() / 1000),
        exp: Math.floor(Date.now() / 1000) + 3600
      };
      const routeToken = createValidToken(testKeys.privateKey, routePayload);

      const response = await request(app)
        .post('/api/v1/routing')
        .set('X-Agent-Token', routeToken)
        .send({
          task_id: 'route-test',
          description: 'Test routing'
        });

      // Should not be rejected for authorization (may fail for other reasons like missing router)
      // The key is that it doesn't return 403 Forbidden
      expect(response.status).not.toBe(403);
    });

    test('should reject agents without tasks:route capability from routing', async () => {
      const response = await request(app)
        .post('/api/v1/routing')
        .set('X-Agent-Token', validWorkerToken)
        .send({
          task_id: 'route-test',
          description: 'Test routing'
        })
        .expect(403);

      expect(response.body.error).toBe('Forbidden');
      expect(response.body.details).toContain('Insufficient privileges to route tasks');
    });
  });

  describe('Public Endpoints - Allow Without Authentication', () => {
    test('should allow access to health endpoint without token', async () => {
      const response = await request(app)
        .get('/health')
        .expect(404); // 404 because health route is not mounted in this test setup

      // The auth middleware should have passed through
    });
  });
});
