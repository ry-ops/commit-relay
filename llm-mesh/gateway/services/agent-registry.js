// Agent Registry Service
// Tracks all active agents, their capabilities, and current load

const fs = require('fs').promises;
const path = require('path');

class AgentRegistry {
  constructor() {
    this.registryPath = 'coordination/gateway/agent-registry.json';
    this.agents = new Map();
    this.heartbeatInterval = 30000; // 30 seconds
  }

  async initialize() {
    await fs.mkdir(path.dirname(this.registryPath), { recursive: true });

    try {
      const data = await fs.readFile(this.registryPath, 'utf8');
      const registry = JSON.parse(data);
      this.agents = new Map(Object.entries(registry.agents || {}));
    } catch {
      // Create new registry
      await this.save();
    }

    // Start heartbeat cleanup
    this.startHeartbeatMonitor();
    return true;
  }

  async register(agentId, metadata) {
    const agent = {
      agent_id: agentId,
      ...metadata,
      registered_at: new Date().toISOString(),
      last_heartbeat: new Date().toISOString(),
      status: 'active',
      current_load: 0
    };

    this.agents.set(agentId, agent);
    await this.save();
    return agent;
  }

  async unregister(agentId) {
    const removed = this.agents.delete(agentId);
    if (removed) {
      await this.save();
    }
    return removed;
  }

  async heartbeat(agentId) {
    const agent = this.agents.get(agentId);
    if (agent) {
      agent.last_heartbeat = new Date().toISOString();
      agent.status = 'active';
      await this.save();
      return true;
    }
    return false;
  }

  getAgent(agentId) {
    return this.agents.get(agentId);
  }

  listAgents(filter = {}) {
    let agents = Array.from(this.agents.values());

    if (filter.role) {
      agents = agents.filter(a => a.role === filter.role);
    }
    if (filter.status) {
      agents = agents.filter(a => a.status === filter.status);
    }

    return agents;
  }

  startHeartbeatMonitor() {
    setInterval(() => {
      const now = Date.now();
      for (const [agentId, agent] of this.agents.entries()) {
        const lastSeen = new Date(agent.last_heartbeat).getTime();
        if (now - lastSeen > 60000) { // 1 minute timeout
          agent.status = 'stale';
        }
        if (now - lastSeen > 300000) { // 5 minutes - remove
          this.agents.delete(agentId);
        }
      }
      this.save().catch(() => {});
    }, this.heartbeatInterval);
  }

  async save() {
    const registry = {
      updated_at: new Date().toISOString(),
      agents: Object.fromEntries(this.agents)
    };
    await fs.writeFile(this.registryPath, JSON.stringify(registry, null, 2));
  }
}

module.exports = AgentRegistry;
