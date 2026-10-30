/**
 * Task Routes Security Test Suite
 * 
 * Tests for path traversal vulnerability mitigation in task management routes.
 * Verifies that the security fixes prevent:
 * - Path traversal attacks using ../
 * - Directory escape attempts
 * - Unauthorized file access outside tasks directory
 * - Malicious task_id values
 */

const request = require('supertest');
const express = require('express');
const fs = require('fs').promises;
const path = require('path');
const tasksRouter = require('./tasks');

// Mock the coordination/tasks directory
const MOCK_TASKS_DIR = path.join(__dirname, '../../../coordination/tasks');
const MOCK_COORDINATION_DIR = path.join(__dirname, '../../../coordination');

describe('Task Routes - Path Traversal Security', () => {
  let app;

  beforeAll(async () => {
    // Ensure test directories exist
    await fs.mkdir(MOCK_TASKS_DIR, { recursive: true });
    await fs.mkdir(MOCK_COORDINATION_DIR, { recursive: true });
  });

  beforeEach(() => {
    // Create a fresh Express app for each test
    app = express();
    app.use(express.json());
    
    // Mock authentication middleware - simulates authenticated user
    app.use((req, res, next) => {
      req.agentId = 'test-agent';
      req.agentToken = 'test-token';
      req.policyEnforcer = null; // Use fallback authorization
      next();
    });
    
    app.use('/api/v1/tasks', tasksRouter);
  });

  afterEach(async () => {
    // Clean up test files
    try {
      const files = await fs.readdir(MOCK_TASKS_DIR);
      for (const file of files) {
        if (file.endsWith('.json')) {
          await fs.unlink(path.join(MOCK_TASKS_DIR, file));
        }
      }
    } catch (error) {
      // Directory might not exist, ignore
    }
  });

  describe('POST / - Create Task with Path Traversal Prevention', () => {
    test('should reject task_id with ../ path traversal', async () => {
      const response = await request(app)
        .post('/api/v1/tasks')
        .send({
          task_id: '../task-queue',
          description: 'Malicious task'
        });

      expect(response.status).toBe(400);
      expect(response.body.error).toBe('Invalid task ID format');
      expect(response.body.details).toContain('alphanumeric');
    });

    test('should reject task_id with absolute path traversal', async () => {
      const response = await request(app)
        .post('/api/v1/tasks')
        .send({
          task_id: '../../coordination/task-queue',
          description: 'Malicious task'
        });

      expect(response.status).toBe(400);
      expect(response.body.error).toBe('Invalid task ID format');
    });

    test('should reject task_id with forward slash', async () => {
      const response = await request(app)
        .post('/api/v1/tasks')
        .send({
          task_id: 'subdir/task',
          description: 'Malicious task'
        });

      expect(response.status).toBe(400);
      expect(response.body.error).toBe('Invalid task ID format');
    });

    test('should reject task_id with backslash', async () => {
      const response = await request(app)
        .post('/api/v1/tasks')
        .send({
          task_id: 'subdir\\task',
          description: 'Malicious task'
        });

      expect(response.status).toBe(400);
      expect(response.body.error).toBe('Invalid task ID format');
    });

    test('should reject task_id with null bytes', async () => {
      const response = await request(app)
        .post('/api/v1/tasks')
        .send({
          task_id: 'task\x00malicious',
          description: 'Malicious task'
        });

      expect(response.status).toBe(400);
      expect(response.body.error).toBe('Invalid task ID format');
    });

    test('should reject task_id with control characters', async () => {
      const response = await request(app)
        .post('/api/v1/tasks')
        .send({
          task_id: 'task\n\rmalicious',
          description: 'Malicious task'
        });

      expect(response.status).toBe(400);
      expect(response.body.error).toBe('Invalid task ID format');
    });

    test('should reject task_id with special characters', async () => {
      const response = await request(app)
        .post('/api/v1/tasks')
        .send({
          task_id: 'task@#$%',
          description: 'Malicious task'
        });

      expect(response.status).toBe(400);
      expect(response.body.error).toBe('Invalid task ID format');
    });

    test('should reject task_id exceeding length limit', async () => {
      const longTaskId = 'a'.repeat(256);
      const response = await request(app)
        .post('/api/v1/tasks')
        .send({
          task_id: longTaskId,
          description: 'Task with long ID'
        });

      expect(response.status).toBe(400);
      expect(response.body.error).toBe('Invalid task ID format');
    });

    test('should accept valid task_id with alphanumeric and hyphens', async () => {
      const response = await request(app)
        .post('/api/v1/tasks')
        .send({
          task_id: 'task-123-abc',
          description: 'Valid task'
        });

      expect(response.status).toBe(200);
      expect(response.body.success).toBe(true);
      expect(response.body.task.task_id).toBe('task-123-abc');
    });

    test('should accept valid task_id with underscores', async () => {
      const response = await request(app)
        .post('/api/v1/tasks')
        .send({
          task_id: 'task_123_abc',
          description: 'Valid task'
        });

      expect(response.status).toBe(200);
      expect(response.body.success).toBe(true);
      expect(response.body.task.task_id).toBe('task_123_abc');
    });

    test('should generate safe task_id when not provided', async () => {
      const response = await request(app)
        .post('/api/v1/tasks')
        .send({
          description: 'Task without ID'
        });

      expect(response.status).toBe(200);
      expect(response.body.success).toBe(true);
      expect(response.body.task.task_id).toMatch(/^task-\d+$/);
    });

    test('should reject anonymous agent writes', async () => {
      // Create app with anonymous agent
      const anonApp = express();
      anonApp.use(express.json());
      anonApp.use((req, res, next) => {
        req.agentId = 'anonymous';
        req.agentToken = 'test-token';
        req.policyEnforcer = null;
        next();
      });
      anonApp.use('/api/v1/tasks', tasksRouter);

      const response = await request(anonApp)
        .post('/api/v1/tasks')
        .send({
          task_id: 'task-123',
          description: 'Task from anonymous'
        });

      expect(response.status).toBe(403);
      expect(response.body.error).toBe('Insufficient permissions');
    });

    test('should write task file only within tasks directory', async () => {
      const response = await request(app)
        .post('/api/v1/tasks')
        .send({
          task_id: 'safe-task-001',
          description: 'Safe task'
        });

      expect(response.status).toBe(200);

      // Verify file was created in correct location
      const taskPath = path.join(MOCK_TASKS_DIR, 'safe-task-001.json');
      const fileExists = await fs.access(taskPath).then(() => true).catch(() => false);
      expect(fileExists).toBe(true);

      // Verify file content
      const content = await fs.readFile(taskPath, 'utf8');
      const task = JSON.parse(content);
      expect(task.task_id).toBe('safe-task-001');
      expect(task.description).toBe('Safe task');
    });
  });

  describe('GET /:taskId - Read Task with Path Traversal Prevention', () => {
    beforeEach(async () => {
      // Create a test task file
      const testTask = {
        task_id: 'test-task-001',
        description: 'Test task',
        status: 'pending',
        created_at: new Date().toISOString(),
        created_by: 'test-agent'
      };
      await fs.writeFile(
        path.join(MOCK_TASKS_DIR, 'test-task-001.json'),
        JSON.stringify(testTask, null, 2)
      );
    });

    test('should reject taskId with ../ path traversal', async () => {
      const response = await request(app)
        .get('/api/v1/tasks/../task-queue');

      expect(response.status).toBe(400);
      expect(response.body.error).toBe('Invalid task ID format');
    });

    test('should reject taskId with multiple ../ sequences', async () => {
      const response = await request(app)
        .get('/api/v1/tasks/../../coordination/task-queue');

      expect(response.status).toBe(400);
      expect(response.body.error).toBe('Invalid task ID format');
    });

    test('should reject taskId with forward slash', async () => {
      const response = await request(app)
        .get('/api/v1/tasks/subdir/task');

      expect(response.status).toBe(400);
      expect(response.body.error).toBe('Invalid task ID format');
    });

    test('should reject taskId with backslash', async () => {
      const response = await request(app)
        .get('/api/v1/tasks/subdir\\task');

      expect(response.status).toBe(400);
      expect(response.body.error).toBe('Invalid task ID format');
    });

    test('should reject taskId with null bytes', async () => {
      const response = await request(app)
        .get('/api/v1/tasks/task\x00malicious');

      expect(response.status).toBe(400);
      expect(response.body.error).toBe('Invalid task ID format');
    });

    test('should reject taskId with special characters', async () => {
      const response = await request(app)
        .get('/api/v1/tasks/task@#$%');

      expect(response.status).toBe(400);
      expect(response.body.error).toBe('Invalid task ID format');
    });

    test('should successfully read valid task', async () => {
      const response = await request(app)
        .get('/api/v1/tasks/test-task-001');

      expect(response.status).toBe(200);
      expect(response.body.task_id).toBe('test-task-001');
      expect(response.body.description).toBe('Test task');
    });

    test('should return 404 for non-existent valid task', async () => {
      const response = await request(app)
        .get('/api/v1/tasks/nonexistent-task');

      expect(response.status).toBe(404);
      expect(response.body.error).toBe('Task not found');
    });

    test('should read task file only from tasks directory', async () => {
      const response = await request(app)
        .get('/api/v1/tasks/test-task-001');

      expect(response.status).toBe(200);
      
      // Verify the response came from the correct file
      const expectedPath = path.join(MOCK_TASKS_DIR, 'test-task-001.json');
      const fileContent = await fs.readFile(expectedPath, 'utf8');
      const fileTask = JSON.parse(fileContent);
      
      expect(response.body.task_id).toBe(fileTask.task_id);
      expect(response.body.description).toBe(fileTask.description);
    });
  });

  describe('Path Containment Validation', () => {
    test('should prevent writing outside tasks directory via path normalization', async () => {
      // Even if validation is bypassed, path containment should catch it
      const response = await request(app)
        .post('/api/v1/tasks')
        .send({
          task_id: 'legitimate-looking-task',
          description: 'Test'
        });

      expect(response.status).toBe(200);

      // Verify no files were created outside tasks directory
      const coordinationFiles = await fs.readdir(MOCK_COORDINATION_DIR);
      const taskFiles = coordinationFiles.filter(f => 
        f.endsWith('.json') && !f.includes('tasks')
      );
      
      // Should not have created any JSON files in coordination root
      expect(taskFiles.length).toBe(0);
    });

    test('should prevent reading outside tasks directory', async () => {
      // Create a file outside tasks directory
      const outsideFile = path.join(MOCK_COORDINATION_DIR, 'secret-config.json');
      await fs.writeFile(outsideFile, JSON.stringify({ secret: 'data' }));

      // Try to read it via path traversal (should be blocked by validation)
      const response = await request(app)
        .get('/api/v1/tasks/../secret-config');

      expect(response.status).toBe(400);
      expect(response.body.error).toBe('Invalid task ID format');

      // Clean up
      await fs.unlink(outsideFile);
    });
  });

  describe('Authorization Checks', () => {
    test('should enforce capability checks when policyEnforcer is available', async () => {
      const appWithPolicy = express();
      appWithPolicy.use(express.json());
      
      // Mock policyEnforcer that denies write capability
      appWithPolicy.use((req, res, next) => {
        req.agentId = 'restricted-agent';
        req.agentToken = 'test-token';
        req.policyEnforcer = {
          checkCapability: (agentId, capability) => {
            if (capability === 'tasks:write') {
              return false;
            }
            return true;
          }
        };
        next();
      });
      
      appWithPolicy.use('/api/v1/tasks', tasksRouter);

      const response = await request(appWithPolicy)
        .post('/api/v1/tasks')
        .send({
          task_id: 'task-123',
          description: 'Task'
        });

      expect(response.status).toBe(403);
      expect(response.body.error).toBe('Insufficient permissions');
    });

    test('should allow read with proper capability', async () => {
      // Create test task first
      await request(app)
        .post('/api/v1/tasks')
        .send({
          task_id: 'readable-task',
          description: 'Test'
        });

      const appWithPolicy = express();
      appWithPolicy.use(express.json());
      
      appWithPolicy.use((req, res, next) => {
        req.agentId = 'reader-agent';
        req.agentToken = 'test-token';
        req.policyEnforcer = {
          checkCapability: (agentId, capability) => {
            return capability === 'tasks:read';
          }
        };
        next();
      });
      
      appWithPolicy.use('/api/v1/tasks', tasksRouter);

      const response = await request(appWithPolicy)
        .get('/api/v1/tasks/readable-task');

      expect(response.status).toBe(200);
      expect(response.body.task_id).toBe('readable-task');
    });
  });

  describe('Edge Cases and Boundary Conditions', () => {
    test('should handle empty task_id', async () => {
      const response = await request(app)
        .post('/api/v1/tasks')
        .send({
          task_id: '',
          description: 'Task'
        });

      expect(response.status).toBe(400);
      expect(response.body.error).toBe('Invalid task ID format');
    });

    test('should handle null task_id', async () => {
      const response = await request(app)
        .post('/api/v1/tasks')
        .send({
          task_id: null,
          description: 'Task'
        });

      // Should generate a valid task_id
      expect(response.status).toBe(200);
      expect(response.body.task.task_id).toMatch(/^task-\d+$/);
    });

    test('should handle task_id at maximum valid length', async () => {
      const maxLengthId = 'a'.repeat(255);
      const response = await request(app)
        .post('/api/v1/tasks')
        .send({
          task_id: maxLengthId,
          description: 'Task'
        });

      expect(response.status).toBe(200);
      expect(response.body.task.task_id).toBe(maxLengthId);
    });

    test('should handle task_id with mixed case', async () => {
      const response = await request(app)
        .post('/api/v1/tasks')
        .send({
          task_id: 'Task-ABC-123',
          description: 'Task'
        });

      expect(response.status).toBe(200);
      expect(response.body.task.task_id).toBe('Task-ABC-123');
    });

    test('should preserve task data integrity', async () => {
      const taskData = {
        task_id: 'integrity-test',
        description: 'Test task',
        priority: 'high',
        metadata: {
          key: 'value'
        }
      };

      const response = await request(app)
        .post('/api/v1/tasks')
        .send(taskData);

      expect(response.status).toBe(200);
      expect(response.body.task.task_id).toBe('integrity-test');
      expect(response.body.task.description).toBe('Test task');
      expect(response.body.task.priority).toBe('high');
      expect(response.body.task.metadata).toEqual({ key: 'value' });
      expect(response.body.task.status).toBe('pending');
      expect(response.body.task.created_by).toBe('test-agent');
      expect(response.body.task.created_at).toBeDefined();
    });
  });
});
