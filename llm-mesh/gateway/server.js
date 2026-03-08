#!/usr/bin/env node
// llm-mesh/gateway/server.js
// Commit-Relay Agent Gateway Server
// Centralized control plane for all agent interactions

const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const rateLimit = require('express-rate-limit');
const fs = require('fs').promises;
const path = require('path');

// Services
const AgentRegistry = require('./services/agent-registry');
const PolicyEnforcer = require('./services/policy-enforcer');

// Routes
const routingRouter = require('./routes/routing');
const agentsRouter = require('./routes/agents');
const tasksRouter = require('./routes/tasks');
const healthRouter = require('./routes/health');

// Middleware
const authMiddleware = require('./middleware/auth');
const loggingMiddleware = require('./middleware/logging');

class AgentGateway {
  constructor(config = {}) {
    this.config = {
      port: config.port || process.env.GATEWAY_PORT || 3001,
      host: config.host || '0.0.0.0',
      logLevel: config.logLevel || 'info',
      rateLimit: {
        windowMs: 60 * 1000, // 1 minute
        max: 100, // 100 requests per minute per IP
      },
      cors: {
        origin: '*', // Configure based on deployment
        credentials: true,
      },
      ...config
    };

    this.app = express();
    this.registry = new AgentRegistry();
    this.policyEnforcer = new PolicyEnforcer();
  }

  /**
   * Initialize gateway services
   */
  async initialize() {
    console.log('Initializing Agent Gateway...');

    // Initialize services
    await this.registry.initialize();
    await this.policyEnforcer.initialize();

    // Configure Express middleware
    this.app.use(helmet()); // Security headers
    this.app.use(cors(this.config.cors)); // CORS
    this.app.use(express.json({ limit: '10mb' })); // JSON body parser
    this.app.use(express.urlencoded({ extended: true }));

    // Rate limiting
    const limiter = rateLimit(this.config.rateLimit);
    this.app.use(limiter);

    // Custom middleware
    this.app.use(loggingMiddleware);
    this.app.use(authMiddleware(this.registry, this.policyEnforcer));

    // Attach services to req
    this.app.use((req, res, next) => {
      req.registry = this.registry;
      req.policyEnforcer = this.policyEnforcer;
      next();
    });

    // Mount routes
    this.app.use('/health', healthRouter);
    this.app.use('/api/v1/routing', routingRouter);
    this.app.use('/api/v1/agents', agentsRouter);
    this.app.use('/api/v1/tasks', tasksRouter);

    // Root endpoint
    this.app.get('/', (req, res) => {
      res.json({
        service: 'commit-relay-gateway',
        version: '1.0.0',
        status: 'operational',
        endpoints: {
          health: '/health',
          routing: '/api/v1/routing',
          agents: '/api/v1/agents',
          tasks: '/api/v1/tasks'
        }
      });
    });

    // Error handler
    this.app.use((err, req, res, next) => {
      console.error('Gateway error:', err);
      res.status(err.status || 500).json({
        error: {
          message: err.message || 'Internal server error',
          code: err.code || 'INTERNAL_ERROR',
          ...(process.env.NODE_ENV === 'development' && { stack: err.stack })
        }
      });
    });

    console.log('✓ Gateway initialized');
  }

  /**
   * Start gateway server
   */
  async start() {
    await this.initialize();

    return new Promise((resolve, reject) => {
      this.server = this.app.listen(this.config.port, this.config.host, (err) => {
        if (err) {
          console.error('Failed to start gateway:', err);
          reject(err);
        } else {
          console.log(`✓ Agent Gateway listening on ${this.config.host}:${this.config.port}`);
          console.log(`  Health check: http://${this.config.host}:${this.config.port}/health`);
          console.log(`  API: http://${this.config.host}:${this.config.port}/api/v1`);
          resolve(this.server);
        }
      });
    });
  }

  /**
   * Graceful shutdown
   */
  async stop() {
    console.log('Shutting down gateway...');

    if (this.server) {
      return new Promise((resolve) => {
        this.server.close(() => {
          console.log('✓ Gateway stopped');
          resolve();
        });
      });
    }
  }
}

// CLI interface
if (require.main === module) {
  const gateway = new AgentGateway();

  // Graceful shutdown
  process.on('SIGTERM', async () => {
    await gateway.stop();
    process.exit(0);
  });

  process.on('SIGINT', async () => {
    await gateway.stop();
    process.exit(0);
  });

  gateway.start().catch((err) => {
    console.error('Failed to start gateway:', err);
    process.exit(1);
  });
}

module.exports = AgentGateway;
