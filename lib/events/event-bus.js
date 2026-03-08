#!/usr/bin/env node
// lib/events/event-bus.js
// Event-Driven Automation System
// Part of Enhancement Phase: Event-Driven Automation
//
// Responsibilities:
// - Publish/Subscribe event bus
// - Event routing and filtering
// - Event persistence and replay
// - Automated event-driven workflows

const fs = require('fs').promises;
const path = require('path');
const crypto = require('crypto');
const { EventEmitter } = require('events');

class EventBus extends EventEmitter {
  constructor() {
    super();
    this.setMaxListeners(100); // Support many subscribers
    
    this.eventsPath = 'coordination/events/streams';
    this.subscriptionsPath = 'coordination/events/subscriptions.json';
    
    // Event types
    this.eventTypes = {
      // Task events
      'task.created': { description: 'New task created', priority: 'normal' },
      'task.routed': { description: 'Task routed to master', priority: 'normal' },
      'task.started': { description: 'Task execution started', priority: 'normal' },
      'task.completed': { description: 'Task completed successfully', priority: 'high' },
      'task.failed': { description: 'Task failed', priority: 'high' },
      
      // Worker events
      'worker.spawned': { description: 'Worker spawned', priority: 'normal' },
      'worker.started': { description: 'Worker started execution', priority: 'normal' },
      'worker.completed': { description: 'Worker completed', priority: 'normal' },
      'worker.failed': { description: 'Worker failed', priority: 'high' },
      'worker.zombie': { description: 'Worker became zombie', priority: 'critical' },
      
      // System events
      'system.health.degraded': { description: 'System health degraded', priority: 'critical' },
      'system.budget.low': { description: 'Token budget low', priority: 'high' },
      'system.budget.exhausted': { description: 'Token budget exhausted', priority: 'critical' },
      
      // Governance events
      'governance.violation': { description: 'Compliance violation', priority: 'critical' },
      'governance.pii.detected': { description: 'PII detected', priority: 'high' },
      'governance.quality.degraded': { description: 'Data quality degraded', priority: 'high' },
      
      // AI events
      'ai.drift.detected': { description: 'Model drift detected', priority: 'high' },
      'ai.confidence.low': { description: 'Low AI confidence', priority: 'medium' },
      'ai.decision.made': { description: 'AI decision made', priority: 'normal' },
      
      // Pattern events
      'pattern.detected': { description: 'Failure pattern detected', priority: 'high' },
      'pattern.auto_fixed': { description: 'Pattern auto-fixed', priority: 'normal' }
    };

    this.subscriptions = new Map();
  }

  /**
   * Initialize event bus
   */
  async initialize() {
    try {
      await fs.mkdir(this.eventsPath, { recursive: true });

      // Load subscriptions
      try {
        const subsContent = await fs.readFile(this.subscriptionsPath, 'utf8');
        const subs = JSON.parse(subsContent);
        
        for (const [eventType, handlers] of Object.entries(subs)) {
          this.subscriptions.set(eventType, handlers);
        }
      } catch (error) {
        // No existing subscriptions
      }

      console.log('Event Bus initialized');
      console.log(`Registered event types: ${Object.keys(this.eventTypes).length}`);
      
      return true;
    } catch (error) {
      console.error('Failed to initialize Event Bus:', error.message);
      return false;
    }
  }

  /**
   * Publish event
   */
  async publish(eventType, payload = {}) {
    if (!this.eventTypes[eventType]) {
      console.warn(`Unknown event type: ${eventType}`);
    }

    const event = {
      event_id: crypto.randomUUID(),
      event_type: eventType,
      timestamp: new Date().toISOString(),
      priority: this.eventTypes[eventType]?.priority || 'normal',
      payload: payload,
      source: payload.source || 'system'
    };

    // Persist event
    await this._persistEvent(event);

    // Emit to in-memory subscribers
    this.emit(eventType, event);
    this.emit('*', event); // Wildcard subscribers

    console.log(`Published event: ${eventType} (${event.event_id})`);

    return event.event_id;
  }

  /**
   * Subscribe to event type
   */
  subscribe(eventType, handler, options = {}) {
    const subscriptionId = crypto.randomUUID();

    const subscription = {
      id: subscriptionId,
      event_type: eventType,
      handler: handler.name || 'anonymous',
      filter: options.filter || null,
      priority: options.priority || 'normal',
      created_at: new Date().toISOString()
    };

    // Store subscription metadata
    if (!this.subscriptions.has(eventType)) {
      this.subscriptions.set(eventType, []);
    }
    this.subscriptions.get(eventType).push(subscription);

    // Register event listener
    const listener = async (event) => {
      // Apply filter if specified
      if (subscription.filter && !subscription.filter(event)) {
        return;
      }

      try {
        await handler(event);
      } catch (error) {
        console.error(`Subscription handler error (${subscriptionId}):`, error.message);
      }
    };

    this.on(eventType, listener);

    console.log(`Subscribed to ${eventType} (${subscriptionId})`);

    return subscriptionId;
  }

  /**
   * Unsubscribe from event
   */
  unsubscribe(subscriptionId) {
    for (const [eventType, subs] of this.subscriptions.entries()) {
      const index = subs.findIndex(s => s.id === subscriptionId);
      if (index !== -1) {
        subs.splice(index, 1);
        console.log(`Unsubscribed: ${subscriptionId}`);
        return true;
      }
    }

    return false;
  }

  /**
   * Get event history
   */
  async getEventHistory(filters = {}) {
    const events = [];
    const eventType = filters.event_type;
    const startTime = filters.start_time;
    const endTime = filters.end_time || new Date().toISOString();
    const limit = filters.limit || 100;

    // Read event streams
    const streamFile = eventType 
      ? path.join(this.eventsPath, `${eventType}.jsonl`)
      : path.join(this.eventsPath, 'all-events.jsonl');

    try {
      const content = await fs.readFile(streamFile, 'utf8');
      const lines = content.trim().split('\n');

      for (const line of lines) {
        const event = JSON.parse(line);

        // Apply filters
        if (startTime && event.timestamp < startTime) continue;
        if (endTime && event.timestamp > endTime) continue;

        events.push(event);
      }
    } catch (error) {
      // No events yet
    }

    // Sort by timestamp (newest first)
    events.sort((a, b) => new Date(b.timestamp) - new Date(a.timestamp));

    return events.slice(0, limit);
  }

  /**
   * Replay events from history
   */
  async replayEvents(filters = {}) {
    const events = await this.getEventHistory(filters);

    for (const event of events.reverse()) {
      // Emit without persisting again
      this.emit(event.event_type, event);
      this.emit('*', event);
    }

    console.log(`Replayed ${events.length} events`);

    return events.length;
  }

  /**
   * Create automated workflow
   */
  createWorkflow(name, triggers, actions) {
    const workflowId = crypto.randomUUID();

    const workflow = {
      id: workflowId,
      name: name,
      triggers: triggers,
      actions: actions,
      created_at: new Date().toISOString()
    };

    // Subscribe to trigger events
    for (const trigger of triggers) {
      this.subscribe(trigger.event_type, async (event) => {
        // Check trigger conditions
        if (trigger.condition && !trigger.condition(event)) {
          return;
        }

        console.log(`Workflow '${name}' triggered by ${event.event_type}`);

        // Execute actions
        for (const action of actions) {
          try {
            await action(event);
          } catch (error) {
            console.error(`Workflow action failed:`, error.message);
          }
        }
      }, { filter: trigger.filter });
    }

    console.log(`Created workflow: ${name} (${workflowId})`);

    return workflowId;
  }

  /**
   * Get event statistics
   */
  async getStatistics(timeWindow = 3600000) {
    const cutoff = new Date(Date.now() - timeWindow).toISOString();
    const events = await this.getEventHistory({ start_time: cutoff, limit: 10000 });

    const stats = {
      total_events: events.length,
      by_type: {},
      by_priority: {},
      by_source: {},
      time_window: timeWindow
    };

    for (const event of events) {
      // By type
      stats.by_type[event.event_type] = (stats.by_type[event.event_type] || 0) + 1;

      // By priority
      stats.by_priority[event.priority] = (stats.by_priority[event.priority] || 0) + 1;

      // By source
      stats.by_source[event.source] = (stats.by_source[event.source] || 0) + 1;
    }

    return stats;
  }

  /**
   * Persist event to stream
   */
  async _persistEvent(event) {
    // Write to event-specific stream
    const eventStream = path.join(this.eventsPath, `${event.event_type}.jsonl`);
    const eventLine = JSON.stringify(event) + '\n';
    await fs.appendFile(eventStream, eventLine);

    // Write to all-events stream
    const allEventsStream = path.join(this.eventsPath, 'all-events.jsonl');
    await fs.appendFile(allEventsStream, eventLine);
  }

  /**
   * Save subscriptions to file
   */
  async _saveSubscriptions() {
    const subs = {};
    for (const [eventType, handlers] of this.subscriptions.entries()) {
      subs[eventType] = handlers;
    }

    await fs.writeFile(this.subscriptionsPath, JSON.stringify(subs, null, 2));
  }
}

// CLI interface
if (require.main === module) {
  const action = process.argv[2];
  const eventBus = new EventBus();

  (async () => {
    await eventBus.initialize();

    switch (action) {
      case 'publish':
        const eventType = process.argv[3];
        const payload = process.argv[4] ? JSON.parse(process.argv[4]) : {};
        const eventId = await eventBus.publish(eventType, payload);
        console.log(`Published event: ${eventId}`);
        break;

      case 'history':
        const histEventType = process.argv[3] || null;
        const limit = parseInt(process.argv[4]) || 50;
        const history = await eventBus.getEventHistory({ 
          event_type: histEventType,
          limit: limit 
        });
        console.log('\nEvent History:');
        console.log(JSON.stringify(history, null, 2));
        break;

      case 'stats':
        const stats = await eventBus.getStatistics();
        console.log('\nEvent Statistics:');
        console.log(JSON.stringify(stats, null, 2));
        break;

      case 'replay':
        const replayType = process.argv[3] || null;
        const replayed = await eventBus.replayEvents({ event_type: replayType });
        console.log(`\nReplayed ${replayed} events`);
        break;

      default:
        console.log('Usage: node event-bus.js <action>');
        console.log('Actions:');
        console.log('  publish <type> [payload]  - Publish event');
        console.log('  history [type] [limit]    - View event history');
        console.log('  stats                     - Event statistics');
        console.log('  replay [type]             - Replay events');
        break;
    }
  })();
}

module.exports = EventBus;
