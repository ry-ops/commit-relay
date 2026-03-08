/**
 * Worker Lifecycle Integration Test Suite
 *
 * Tests for complete worker lifecycle management:
 * - Worker spawning and initialization
 * - Task assignment and execution
 * - State transitions
 * - Handoff creation and processing
 * - Worker termination and cleanup
 * - Error handling and recovery
 */

const fs = require('fs').promises;
const path = require('path');

// Mock worker lifecycle manager
class WorkerLifecycleManager {
  constructor() {
    this.workers = new Map();
    this.tasks = new Map();
    this.nextWorkerId = 1;
    this.nextTaskId = 1;
  }

  async spawnWorker(type, master) {
    const workerId = `worker-${String(this.nextWorkerId++).padStart(3, '0')}`;
    const worker = {
      id: workerId,
      type,
      master,
      status: 'initializing',
      task_id: null,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString()
    };

    this.workers.set(workerId, worker);

    // Simulate initialization
    await new Promise(resolve => setTimeout(resolve, 50));
    worker.status = 'idle';
    worker.updated_at = new Date().toISOString();

    return worker;
  }

  async assignTask(workerId, taskId) {
    const worker = this.workers.get(workerId);
    const task = this.tasks.get(taskId);

    if (!worker) throw new Error(`Worker ${workerId} not found`);
    if (!task) throw new Error(`Task ${taskId} not found`);
    if (worker.status !== 'idle') throw new Error(`Worker ${workerId} is not idle`);
    if (task.status !== 'pending') throw new Error(`Task ${taskId} is not pending`);

    worker.task_id = taskId;
    worker.status = 'assigned';
    worker.updated_at = new Date().toISOString();

    task.worker_id = workerId;
    task.status = 'assigned';
    task.updated_at = new Date().toISOString();

    return { worker, task };
  }

  async startTask(workerId) {
    const worker = this.workers.get(workerId);
    if (!worker) throw new Error(`Worker ${workerId} not found`);
    if (worker.status !== 'assigned') throw new Error(`Worker ${workerId} is not assigned`);

    const task = this.tasks.get(worker.task_id);

    worker.status = 'running';
    worker.updated_at = new Date().toISOString();

    task.status = 'running';
    task.started_at = new Date().toISOString();
    task.updated_at = new Date().toISOString();

    return { worker, task };
  }

  async completeTask(workerId, result) {
    const worker = this.workers.get(workerId);
    if (!worker) throw new Error(`Worker ${workerId} not found`);

    const task = this.tasks.get(worker.task_id);

    task.status = result.success ? 'completed' : 'failed';
    task.result = result;
    task.completed_at = new Date().toISOString();
    task.updated_at = new Date().toISOString();

    worker.status = 'idle';
    worker.task_id = null;
    worker.updated_at = new Date().toISOString();

    return { worker, task };
  }

  async terminateWorker(workerId, reason = 'normal') {
    const worker = this.workers.get(workerId);
    if (!worker) throw new Error(`Worker ${workerId} not found`);

    // If worker has active task, fail it
    if (worker.task_id) {
      const task = this.tasks.get(worker.task_id);
      task.status = 'failed';
      task.result = { success: false, reason: `Worker terminated: ${reason}` };
      task.updated_at = new Date().toISOString();
    }

    worker.status = 'terminated';
    worker.terminated_at = new Date().toISOString();
    worker.termination_reason = reason;
    worker.updated_at = new Date().toISOString();

    return worker;
  }

  async createTask(description, master) {
    const taskId = `task-${String(this.nextTaskId++).padStart(3, '0')}`;
    const task = {
      id: taskId,
      description,
      master,
      status: 'pending',
      worker_id: null,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString()
    };

    this.tasks.set(taskId, task);
    return task;
  }

  getWorker(workerId) {
    return this.workers.get(workerId);
  }

  getTask(taskId) {
    return this.tasks.get(taskId);
  }

  getWorkersByStatus(status) {
    return Array.from(this.workers.values()).filter(w => w.status === status);
  }

  getTasksByStatus(status) {
    return Array.from(this.tasks.values()).filter(t => t.status === status);
  }

  getMetrics() {
    const workers = Array.from(this.workers.values());
    const tasks = Array.from(this.tasks.values());

    return {
      workers: {
        total: workers.length,
        idle: workers.filter(w => w.status === 'idle').length,
        running: workers.filter(w => w.status === 'running').length,
        terminated: workers.filter(w => w.status === 'terminated').length
      },
      tasks: {
        total: tasks.length,
        pending: tasks.filter(t => t.status === 'pending').length,
        running: tasks.filter(t => t.status === 'running').length,
        completed: tasks.filter(t => t.status === 'completed').length,
        failed: tasks.filter(t => t.status === 'failed').length
      }
    };
  }
}

describe('Worker Lifecycle Integration', () => {
  let manager;

  beforeEach(() => {
    manager = new WorkerLifecycleManager();
  });

  describe('Worker Spawning', () => {
    test('spawns worker successfully', async () => {
      const worker = await manager.spawnWorker('analysis-worker', 'development-master');

      expect(worker.id).toMatch(/^worker-\d{3}$/);
      expect(worker.type).toBe('analysis-worker');
      expect(worker.master).toBe('development-master');
      expect(worker.status).toBe('idle');
      expect(worker.created_at).toBeDefined();
    });

    test('assigns unique IDs to workers', async () => {
      const worker1 = await manager.spawnWorker('analysis-worker', 'development-master');
      const worker2 = await manager.spawnWorker('implementation-worker', 'development-master');

      expect(worker1.id).not.toBe(worker2.id);
    });

    test('initializes worker in idle state', async () => {
      const worker = await manager.spawnWorker('analysis-worker', 'development-master');

      expect(worker.status).toBe('idle');
      expect(worker.task_id).toBeNull();
    });

    test('spawns multiple workers of different types', async () => {
      const workers = await Promise.all([
        manager.spawnWorker('analysis-worker', 'development-master'),
        manager.spawnWorker('implementation-worker', 'development-master'),
        manager.spawnWorker('review-worker', 'development-master')
      ]);

      expect(workers).toHaveLength(3);
      expect(new Set(workers.map(w => w.type)).size).toBe(3);
    });
  });

  describe('Task Creation and Assignment', () => {
    test('creates task successfully', async () => {
      const task = await manager.createTask('Implement feature X', 'development-master');

      expect(task.id).toMatch(/^task-\d{3}$/);
      expect(task.description).toBe('Implement feature X');
      expect(task.status).toBe('pending');
      expect(task.worker_id).toBeNull();
    });

    test('assigns task to idle worker', async () => {
      const worker = await manager.spawnWorker('analysis-worker', 'development-master');
      const task = await manager.createTask('Analyze codebase', 'development-master');

      const result = await manager.assignTask(worker.id, task.id);

      expect(result.worker.task_id).toBe(task.id);
      expect(result.worker.status).toBe('assigned');
      expect(result.task.worker_id).toBe(worker.id);
      expect(result.task.status).toBe('assigned');
    });

    test('rejects assignment to non-idle worker', async () => {
      const worker = await manager.spawnWorker('analysis-worker', 'development-master');
      const task1 = await manager.createTask('Task 1', 'development-master');
      const task2 = await manager.createTask('Task 2', 'development-master');

      await manager.assignTask(worker.id, task1.id);

      await expect(
        manager.assignTask(worker.id, task2.id)
      ).rejects.toThrow('not idle');
    });

    test('rejects assignment of non-pending task', async () => {
      const worker = await manager.spawnWorker('analysis-worker', 'development-master');
      const task = await manager.createTask('Task 1', 'development-master');

      await manager.assignTask(worker.id, task.id);

      const worker2 = await manager.spawnWorker('analysis-worker', 'development-master');

      await expect(
        manager.assignTask(worker2.id, task.id)
      ).rejects.toThrow('not pending');
    });
  });

  describe('Task Execution', () => {
    test('starts assigned task', async () => {
      const worker = await manager.spawnWorker('analysis-worker', 'development-master');
      const task = await manager.createTask('Analyze codebase', 'development-master');

      await manager.assignTask(worker.id, task.id);
      const result = await manager.startTask(worker.id);

      expect(result.worker.status).toBe('running');
      expect(result.task.status).toBe('running');
      expect(result.task.started_at).toBeDefined();
    });

    test('rejects start on non-assigned worker', async () => {
      const worker = await manager.spawnWorker('analysis-worker', 'development-master');

      await expect(
        manager.startTask(worker.id)
      ).rejects.toThrow('not assigned');
    });

    test('completes task successfully', async () => {
      const worker = await manager.spawnWorker('analysis-worker', 'development-master');
      const task = await manager.createTask('Analyze codebase', 'development-master');

      await manager.assignTask(worker.id, task.id);
      await manager.startTask(worker.id);

      const result = await manager.completeTask(worker.id, {
        success: true,
        output: 'Analysis complete'
      });

      expect(result.worker.status).toBe('idle');
      expect(result.worker.task_id).toBeNull();
      expect(result.task.status).toBe('completed');
      expect(result.task.result.success).toBe(true);
      expect(result.task.completed_at).toBeDefined();
    });

    test('marks task as failed on error', async () => {
      const worker = await manager.spawnWorker('analysis-worker', 'development-master');
      const task = await manager.createTask('Analyze codebase', 'development-master');

      await manager.assignTask(worker.id, task.id);
      await manager.startTask(worker.id);

      const result = await manager.completeTask(worker.id, {
        success: false,
        error: 'Analysis failed'
      });

      expect(result.task.status).toBe('failed');
      expect(result.task.result.success).toBe(false);
    });
  });

  describe('Worker Termination', () => {
    test('terminates idle worker', async () => {
      const worker = await manager.spawnWorker('analysis-worker', 'development-master');

      const terminated = await manager.terminateWorker(worker.id, 'shutdown');

      expect(terminated.status).toBe('terminated');
      expect(terminated.termination_reason).toBe('shutdown');
      expect(terminated.terminated_at).toBeDefined();
    });

    test('terminates worker with active task', async () => {
      const worker = await manager.spawnWorker('analysis-worker', 'development-master');
      const task = await manager.createTask('Long running task', 'development-master');

      await manager.assignTask(worker.id, task.id);
      await manager.startTask(worker.id);

      const terminated = await manager.terminateWorker(worker.id, 'timeout');

      expect(terminated.status).toBe('terminated');

      const failedTask = manager.getTask(task.id);
      expect(failedTask.status).toBe('failed');
      expect(failedTask.result.reason).toContain('Worker terminated');
    });
  });

  describe('State Transitions', () => {
    test('complete lifecycle: spawn -> assign -> start -> complete -> idle', async () => {
      const worker = await manager.spawnWorker('analysis-worker', 'development-master');
      expect(worker.status).toBe('idle');

      const task = await manager.createTask('Test task', 'development-master');
      await manager.assignTask(worker.id, task.id);

      const assigned = manager.getWorker(worker.id);
      expect(assigned.status).toBe('assigned');

      await manager.startTask(worker.id);
      const running = manager.getWorker(worker.id);
      expect(running.status).toBe('running');

      await manager.completeTask(worker.id, { success: true });
      const completed = manager.getWorker(worker.id);
      expect(completed.status).toBe('idle');
      expect(completed.task_id).toBeNull();
    });

    test('worker can process multiple tasks sequentially', async () => {
      const worker = await manager.spawnWorker('analysis-worker', 'development-master');

      for (let i = 1; i <= 3; i++) {
        const task = await manager.createTask(`Task ${i}`, 'development-master');
        await manager.assignTask(worker.id, task.id);
        await manager.startTask(worker.id);
        await manager.completeTask(worker.id, { success: true });
      }

      const metrics = manager.getMetrics();
      expect(metrics.tasks.completed).toBe(3);
      expect(manager.getWorker(worker.id).status).toBe('idle');
    });
  });

  describe('Metrics and Monitoring', () => {
    test('tracks worker metrics', async () => {
      await manager.spawnWorker('analysis-worker', 'development-master');
      await manager.spawnWorker('implementation-worker', 'development-master');

      const worker3 = await manager.spawnWorker('review-worker', 'development-master');
      await manager.terminateWorker(worker3.id);

      const metrics = manager.getMetrics();

      expect(metrics.workers.total).toBe(3);
      expect(metrics.workers.idle).toBe(2);
      expect(metrics.workers.terminated).toBe(1);
    });

    test('tracks task metrics', async () => {
      const worker = await manager.spawnWorker('analysis-worker', 'development-master');

      const task1 = await manager.createTask('Task 1', 'development-master');
      const task2 = await manager.createTask('Task 2', 'development-master');
      const task3 = await manager.createTask('Task 3', 'development-master');

      await manager.assignTask(worker.id, task1.id);
      await manager.startTask(worker.id);
      await manager.completeTask(worker.id, { success: true });

      await manager.assignTask(worker.id, task2.id);
      await manager.startTask(worker.id);
      await manager.completeTask(worker.id, { success: false });

      const metrics = manager.getMetrics();

      expect(metrics.tasks.total).toBe(3);
      expect(metrics.tasks.pending).toBe(1);
      expect(metrics.tasks.completed).toBe(1);
      expect(metrics.tasks.failed).toBe(1);
    });

    test('queries workers by status', async () => {
      await manager.spawnWorker('worker-1', 'master');
      const worker2 = await manager.spawnWorker('worker-2', 'master');
      const task = await manager.createTask('Task', 'master');

      await manager.assignTask(worker2.id, task.id);
      await manager.startTask(worker2.id);

      const idle = manager.getWorkersByStatus('idle');
      const running = manager.getWorkersByStatus('running');

      expect(idle).toHaveLength(1);
      expect(running).toHaveLength(1);
    });

    test('queries tasks by status', async () => {
      const worker = await manager.spawnWorker('worker', 'master');

      await manager.createTask('Task 1', 'master');
      const task2 = await manager.createTask('Task 2', 'master');

      await manager.assignTask(worker.id, task2.id);
      await manager.startTask(worker.id);

      const pending = manager.getTasksByStatus('pending');
      const running = manager.getTasksByStatus('running');

      expect(pending).toHaveLength(1);
      expect(running).toHaveLength(1);
    });
  });

  describe('Error Handling', () => {
    test('handles invalid worker ID', async () => {
      await expect(
        manager.assignTask('invalid-worker', 'task-001')
      ).rejects.toThrow('not found');
    });

    test('handles invalid task ID', async () => {
      const worker = await manager.spawnWorker('worker', 'master');

      await expect(
        manager.assignTask(worker.id, 'invalid-task')
      ).rejects.toThrow('not found');
    });

    test('handles termination of non-existent worker', async () => {
      await expect(
        manager.terminateWorker('invalid-worker')
      ).rejects.toThrow('not found');
    });
  });
});
