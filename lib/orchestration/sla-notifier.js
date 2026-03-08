/**
 * SLA Notifier - Send notifications for SLA events
 *
 * Provides notification capabilities for SLA monitoring:
 * - Slack webhook notifications
 * - Dashboard event logging
 * - Email notifications (configurable)
 * - Rate limiting and deduplication
 *
 * Part of commit-relay orchestration system.
 */

const fs = require('fs');
const path = require('path');
const https = require('https');
const http = require('http');
const { URL } = require('url');

// Paths
const SLA_POLICY_PATH = path.join(__dirname, '../../coordination/config/sla-policy.json');
const SLA_EVENTS_PATH = path.join(__dirname, '../../coordination/metrics/sla-events.jsonl');
const DASHBOARD_EVENTS_PATH = path.join(__dirname, '../../coordination/dashboard-events.jsonl');

/**
 * SLANotifier class for sending SLA notifications
 */
class SLANotifier {
  constructor(options = {}) {
    this.policy = this.loadPolicy();
    this.notificationHistory = new Map(); // taskId -> { warning: timestamp, critical: timestamp, timeout: timestamp }
    this.cooldownMs = this.policy.rate_limiting?.notification_cooldown_ms || 60000;
    this.dedupWindowMs = this.policy.rate_limiting?.dedup_window_ms || 30000;
  }

  /**
   * Load SLA policy from configuration file
   */
  loadPolicy() {
    try {
      if (fs.existsSync(SLA_POLICY_PATH)) {
        const content = fs.readFileSync(SLA_POLICY_PATH, 'utf-8');
        return JSON.parse(content);
      }
    } catch (error) {
      console.error(`[SLANotifier] Failed to load SLA policy: ${error.message}`);
    }

    // Return default policy
    return {
      notification_config: {
        slack: { enabled: false },
        email: { enabled: false },
        dashboard: { enabled: true }
      },
      rate_limiting: {
        notification_cooldown_ms: 60000,
        dedup_window_ms: 30000
      }
    };
  }

  /**
   * Reload policy from file
   */
  reloadPolicy() {
    this.policy = this.loadPolicy();
    console.log('[SLANotifier] Policy reloaded');
  }

  /**
   * Check if notification should be sent (rate limiting)
   */
  shouldNotify(taskId, eventType) {
    const now = Date.now();
    const history = this.notificationHistory.get(taskId);

    if (!history) {
      this.notificationHistory.set(taskId, { [eventType]: now });
      return true;
    }

    const lastNotification = history[eventType];
    if (lastNotification && (now - lastNotification) < this.dedupWindowMs) {
      return false;
    }

    history[eventType] = now;
    return true;
  }

  /**
   * Send warning notification
   */
  async sendWarning(event) {
    if (!this.shouldNotify(event.task_id, 'warning')) {
      console.log(`[SLANotifier] Skipping duplicate warning for ${event.task_id}`);
      return;
    }

    const channels = this.getChannels(event.task_type, 'on_warning');

    for (const channel of channels) {
      try {
        switch (channel) {
          case 'slack':
            await this.sendSlackNotification(event, 'warning');
            break;
          case 'dashboard':
            await this.sendDashboardEvent(event, 'warning');
            break;
          case 'email':
            await this.sendEmailNotification(event, 'warning');
            break;
          case 'log':
            this.logNotification(event, 'warning');
            break;
        }
      } catch (error) {
        console.error(`[SLANotifier] Failed to send ${channel} notification: ${error.message}`);
      }
    }
  }

  /**
   * Send critical notification
   */
  async sendCritical(event) {
    if (!this.shouldNotify(event.task_id, 'critical')) {
      console.log(`[SLANotifier] Skipping duplicate critical alert for ${event.task_id}`);
      return;
    }

    const channels = this.getChannels(event.task_type, 'on_critical');

    for (const channel of channels) {
      try {
        switch (channel) {
          case 'slack':
            await this.sendSlackNotification(event, 'critical');
            break;
          case 'dashboard':
            await this.sendDashboardEvent(event, 'critical');
            break;
          case 'email':
            await this.sendEmailNotification(event, 'critical');
            break;
          case 'log':
            this.logNotification(event, 'critical');
            break;
        }
      } catch (error) {
        console.error(`[SLANotifier] Failed to send ${channel} notification: ${error.message}`);
      }
    }
  }

  /**
   * Send timeout notification
   */
  async sendTimeout(event) {
    if (!this.shouldNotify(event.task_id, 'timeout')) {
      console.log(`[SLANotifier] Skipping duplicate timeout notification for ${event.task_id}`);
      return;
    }

    const channels = this.getChannels(event.task_type, 'on_timeout');

    for (const channel of channels) {
      try {
        switch (channel) {
          case 'slack':
            await this.sendSlackNotification(event, 'timeout');
            break;
          case 'dashboard':
            await this.sendDashboardEvent(event, 'timeout');
            break;
          case 'email':
            await this.sendEmailNotification(event, 'timeout');
            break;
          case 'log':
            this.logNotification(event, 'timeout');
            break;
        }
      } catch (error) {
        console.error(`[SLANotifier] Failed to send ${channel} notification: ${error.message}`);
      }
    }
  }

  /**
   * Get notification channels for a task type and event
   */
  getChannels(taskType, eventKey) {
    const escalationConfig = this.policy.escalation_channels?.[taskType] ||
      this.policy.escalation_channels?.default || {};

    return escalationConfig[eventKey] || ['log'];
  }

  /**
   * Send Slack notification
   */
  async sendSlackNotification(event, severity) {
    const slackConfig = this.policy.notification_config?.slack;

    if (!slackConfig?.enabled) {
      return;
    }

    const webhookUrl = process.env[slackConfig.webhook_url_env || 'SLACK_WEBHOOK_URL'];
    if (!webhookUrl) {
      console.warn('[SLANotifier] Slack webhook URL not configured');
      return;
    }

    const template = slackConfig.templates?.[severity] || {};

    const message = {
      channel: slackConfig.channel || '#alerts',
      username: slackConfig.username || 'SLA Monitor',
      icon_emoji: slackConfig.icon_emoji || ':alarm_clock:',
      attachments: [{
        color: template.color || this.getSeverityColor(severity),
        title: this.formatTemplate(template.title || `SLA ${severity.toUpperCase()}`, event),
        text: this.formatTemplate(template.text || this.getDefaultText(severity), event),
        fields: [
          {
            title: 'Task ID',
            value: event.task_id,
            short: true
          },
          {
            title: 'Task Type',
            value: event.task_type,
            short: true
          },
          {
            title: 'Priority',
            value: event.priority,
            short: true
          },
          {
            title: 'Progress',
            value: `${event.percentage}%`,
            short: true
          }
        ],
        footer: 'Commit-Relay SLA Monitor',
        ts: Math.floor(Date.now() / 1000)
      }]
    };

    await this.httpPost(webhookUrl, message);
    console.log(`[SLANotifier] Slack notification sent for ${event.task_id} (${severity})`);
  }

  /**
   * Send dashboard event
   */
  async sendDashboardEvent(event, severity) {
    const dashboardConfig = this.policy.notification_config?.dashboard;

    if (!dashboardConfig?.enabled) {
      return;
    }

    const eventTypes = dashboardConfig.event_types || {};
    const priorityMapping = dashboardConfig.priority_mapping || {};

    const dashboardEvent = {
      id: `sla-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`,
      type: eventTypes[severity] || `sla_${severity}`,
      timestamp: event.timestamp || new Date().toISOString(),
      priority: priorityMapping[severity] || 'medium',
      data: {
        task_id: event.task_id,
        task_type: event.task_type,
        priority: event.priority,
        elapsed_ms: event.elapsed_ms,
        remaining_ms: event.remaining_ms,
        timeout_ms: event.timeout_ms,
        percentage: event.percentage
      },
      message: this.formatEventMessage(event, severity)
    };

    try {
      const dir = path.dirname(DASHBOARD_EVENTS_PATH);
      if (!fs.existsSync(dir)) {
        fs.mkdirSync(dir, { recursive: true });
      }
      fs.appendFileSync(DASHBOARD_EVENTS_PATH, JSON.stringify(dashboardEvent) + '\n');
      console.log(`[SLANotifier] Dashboard event logged for ${event.task_id} (${severity})`);
    } catch (error) {
      console.error(`[SLANotifier] Failed to log dashboard event: ${error.message}`);
    }
  }

  /**
   * Send email notification
   */
  async sendEmailNotification(event, severity) {
    const emailConfig = this.policy.notification_config?.email;

    if (!emailConfig?.enabled) {
      return;
    }

    // Email implementation would go here
    // For now, just log that email would be sent
    console.log(`[SLANotifier] Email notification would be sent for ${event.task_id} (${severity})`);

    // TODO: Implement SMTP sending when email is enabled
    // const transporter = nodemailer.createTransport({...});
    // await transporter.sendMail({...});
  }

  /**
   * Log notification
   */
  logNotification(event, severity) {
    const logEntry = {
      notification_type: 'sla_alert',
      severity,
      task_id: event.task_id,
      task_type: event.task_type,
      priority: event.priority,
      percentage: event.percentage,
      elapsed_ms: event.elapsed_ms,
      remaining_ms: event.remaining_ms,
      timeout_ms: event.timeout_ms,
      timestamp: new Date().toISOString()
    };

    try {
      const dir = path.dirname(SLA_EVENTS_PATH);
      if (!fs.existsSync(dir)) {
        fs.mkdirSync(dir, { recursive: true });
      }
      fs.appendFileSync(SLA_EVENTS_PATH, JSON.stringify(logEntry) + '\n');
    } catch (error) {
      console.error(`[SLANotifier] Failed to log notification: ${error.message}`);
    }
  }

  /**
   * Format template string with event data
   */
  formatTemplate(template, event) {
    if (!template) return '';

    return template
      .replace(/{task_id}/g, event.task_id || '')
      .replace(/{task_type}/g, event.task_type || '')
      .replace(/{percentage}/g, event.percentage || '')
      .replace(/{elapsed}/g, this.formatDuration(event.elapsed_ms))
      .replace(/{remaining}/g, this.formatDuration(event.remaining_ms))
      .replace(/{timeout_ms}/g, event.timeout_ms || '')
      .replace(/{priority}/g, event.priority || '');
  }

  /**
   * Get default text for notification
   */
  getDefaultText(severity) {
    switch (severity) {
      case 'warning':
        return 'Task {task_id} ({task_type}) has reached {percentage}% of its timeout. Elapsed: {elapsed}, Remaining: {remaining}';
      case 'critical':
        return 'Task {task_id} ({task_type}) has reached {percentage}% of its timeout. Immediate attention required.';
      case 'timeout':
        return 'Task {task_id} ({task_type}) has exceeded its SLA timeout. Task cancelled and escalated.';
      default:
        return 'SLA event for task {task_id}';
    }
  }

  /**
   * Get severity color for Slack
   */
  getSeverityColor(severity) {
    switch (severity) {
      case 'warning':
        return '#ffcc00';
      case 'critical':
        return '#ff6600';
      case 'timeout':
        return '#ff0000';
      default:
        return '#cccccc';
    }
  }

  /**
   * Format event message for dashboard
   */
  formatEventMessage(event, severity) {
    const elapsed = this.formatDuration(event.elapsed_ms);
    const remaining = this.formatDuration(event.remaining_ms);

    switch (severity) {
      case 'warning':
        return `SLA Warning: Task ${event.task_id} (${event.task_type}) at ${event.percentage}% of timeout. ${remaining} remaining.`;
      case 'critical':
        return `SLA Critical: Task ${event.task_id} (${event.task_type}) at ${event.percentage}% of timeout. Immediate attention required!`;
      case 'timeout':
        return `SLA Breach: Task ${event.task_id} (${event.task_type}) exceeded timeout. Task cancelled and escalated.`;
      default:
        return `SLA Event: Task ${event.task_id}`;
    }
  }

  /**
   * Format duration in human-readable format
   */
  formatDuration(ms) {
    if (!ms || ms < 0) return '0s';
    if (ms < 1000) return `${ms}ms`;
    if (ms < 60000) return `${(ms / 1000).toFixed(1)}s`;
    if (ms < 3600000) return `${(ms / 60000).toFixed(1)}m`;
    return `${(ms / 3600000).toFixed(1)}h`;
  }

  /**
   * HTTP POST helper for webhooks
   */
  httpPost(urlString, data) {
    return new Promise((resolve, reject) => {
      try {
        const url = new URL(urlString);
        const isHttps = url.protocol === 'https:';
        const client = isHttps ? https : http;

        const options = {
          hostname: url.hostname,
          port: url.port || (isHttps ? 443 : 80),
          path: url.pathname + url.search,
          method: 'POST',
          headers: {
            'Content-Type': 'application/json'
          }
        };

        const req = client.request(options, (res) => {
          let body = '';
          res.on('data', chunk => body += chunk);
          res.on('end', () => {
            if (res.statusCode >= 200 && res.statusCode < 300) {
              resolve({ statusCode: res.statusCode, body });
            } else {
              reject(new Error(`HTTP ${res.statusCode}: ${body}`));
            }
          });
        });

        req.on('error', reject);
        req.write(JSON.stringify(data));
        req.end();
      } catch (error) {
        reject(error);
      }
    });
  }

  /**
   * Clear notification history for a task
   */
  clearHistory(taskId) {
    this.notificationHistory.delete(taskId);
  }

  /**
   * Clear all notification history
   */
  clearAllHistory() {
    this.notificationHistory.clear();
  }
}

// Singleton instance
let slaNotifierInstance = null;

/**
 * Get or create SLA notifier instance
 */
function getSLANotifier(options = {}) {
  if (!slaNotifierInstance) {
    slaNotifierInstance = new SLANotifier(options);
  }
  return slaNotifierInstance;
}

/**
 * Create new SLA notifier instance (for testing)
 */
function createSLANotifier(options = {}) {
  return new SLANotifier(options);
}

module.exports = {
  SLANotifier,
  getSLANotifier,
  createSLANotifier
};
