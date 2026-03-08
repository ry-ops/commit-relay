#!/usr/bin/env node
// lib/governance/ai-monitor.js
// AI-Powered Monitoring & Quality Assurance
// Part of Phase 6.4: Governance Upgrade
//
// Responsibilities:
// - AI decision monitoring
// - Model drift detection
// - Quality degradation alerting
// - Automated quality remediation

const fs = require('fs').promises;
const path = require('path');
const crypto = require('crypto');

class AIMonitor {
  constructor() {
    this.metricsPath = 'coordination/governance/ai-metrics.jsonl';
    this.alertsPath = 'coordination/governance/ai-alerts.jsonl';
    this.baselinePath = 'coordination/governance/ai-baseline.json';
    
    // Quality thresholds
    this.thresholds = {
      min_confidence: 0.7,           // Minimum AI decision confidence
      max_error_rate: 0.05,          // Maximum 5% error rate
      min_success_rate: 0.95,        // Minimum 95% success rate
      max_drift: 0.15,               // Maximum 15% drift from baseline
      min_quality_score: 85          // Minimum quality score (0-100)
    };

    this.baseline = null;
  }

  /**
   * Initialize AI monitor
   */
  async initialize() {
    try {
      await fs.mkdir(path.dirname(this.metricsPath), { recursive: true });

      // Load or create baseline
      try {
        const baselineContent = await fs.readFile(this.baselinePath, 'utf8');
        this.baseline = JSON.parse(baselineContent);
      } catch (error) {
        // Initialize baseline
        this.baseline = {
          created_at: new Date().toISOString(),
          version: '1.0.0',
          metrics: {
            avg_confidence: 0.85,
            avg_success_rate: 0.97,
            avg_quality_score: 92,
            avg_response_time: 5000,
            total_decisions: 0
          }
        };

        await this._saveBaseline();
      }

      console.log('AI Monitor initialized');
      return true;
    } catch (error) {
      console.error('Failed to initialize AI Monitor:', error.message);
      return false;
    }
  }

  /**
   * Record AI decision metrics
   */
  async recordDecision(decision) {
    const metric = {
      metric_id: crypto.randomUUID(),
      timestamp: new Date().toISOString(),
      agent: decision.agent,
      decision_type: decision.type,
      confidence: decision.confidence || null,
      success: decision.success !== false,
      quality_score: decision.quality_score || null,
      response_time: decision.response_time || null,
      metadata: decision.metadata || {}
    };

    // Log metric
    await this._logMetric(metric);

    // Check for quality issues
    await this._checkQuality(metric);

    return metric.metric_id;
  }

  /**
   * Detect model drift
   */
  async detectDrift(agent = null, timeWindow = 24*60*60*1000) {
    const metrics = await this._getRecentMetrics(agent, timeWindow);

    if (metrics.length === 0) {
      return {
        drift_detected: false,
        message: 'Insufficient data for drift detection'
      };
    }

    // Calculate current performance
    const current = {
      avg_confidence: metrics.reduce((sum, m) => sum + (m.confidence || 0), 0) / metrics.length,
      success_rate: metrics.filter(m => m.success).length / metrics.length,
      avg_quality_score: metrics.reduce((sum, m) => sum + (m.quality_score || 0), 0) / metrics.length
    };

    // Compare to baseline
    const confidenceDrift = Math.abs(current.avg_confidence - this.baseline.metrics.avg_confidence);
    const successDrift = Math.abs(current.success_rate - this.baseline.metrics.avg_success_rate);
    const qualityDrift = Math.abs(current.avg_quality_score - this.baseline.metrics.avg_quality_score) / 100;

    const maxDrift = Math.max(confidenceDrift, successDrift, qualityDrift);

    const drift = {
      drift_detected: maxDrift > this.thresholds.max_drift,
      drift_score: maxDrift,
      current_metrics: current,
      baseline_metrics: this.baseline.metrics,
      drifts: {
        confidence: confidenceDrift,
        success_rate: successDrift,
        quality_score: qualityDrift
      },
      analyzed_at: new Date().toISOString(),
      sample_size: metrics.length
    };

    // Alert if drift detected
    if (drift.drift_detected) {
      await this._createAlert({
        type: 'model_drift',
        severity: 'high',
        agent: agent || 'all',
        message: `Model drift detected: \${Math.round(maxDrift * 100)}% deviation from baseline`,
        details: drift
      });
    }

    return drift;
  }

  /**
   * Monitor AI decision quality
   */
  async monitorQuality(agent = null, timeWindow = 3600000) {
    const metrics = await this._getRecentMetrics(agent, timeWindow);

    const qualityReport = {
      report_id: crypto.randomUUID(),
      generated_at: new Date().toISOString(),
      agent: agent || 'all',
      time_window: timeWindow,
      total_decisions: metrics.length,
      quality_metrics: {
        avg_confidence: 0,
        success_rate: 0,
        avg_quality_score: 0,
        error_rate: 0,
        avg_response_time: 0
      },
      issues: []
    };

    if (metrics.length === 0) {
      return qualityReport;
    }

    // Calculate metrics
    qualityReport.quality_metrics = {
      avg_confidence: metrics.reduce((sum, m) => sum + (m.confidence || 0), 0) / metrics.length,
      success_rate: metrics.filter(m => m.success).length / metrics.length,
      avg_quality_score: metrics.reduce((sum, m) => sum + (m.quality_score || 0), 0) / metrics.length,
      error_rate: metrics.filter(m => !m.success).length / metrics.length,
      avg_response_time: metrics.reduce((sum, m) => sum + (m.response_time || 0), 0) / metrics.length
    };

    // Check for issues
    if (qualityReport.quality_metrics.avg_confidence < this.thresholds.min_confidence) {
      qualityReport.issues.push({
        type: 'low_confidence',
        severity: 'medium',
        message: `Average confidence (\${Math.round(qualityReport.quality_metrics.avg_confidence * 100)}%) below threshold`
      });
    }

    if (qualityReport.quality_metrics.error_rate > this.thresholds.max_error_rate) {
      qualityReport.issues.push({
        type: 'high_error_rate',
        severity: 'high',
        message: `Error rate (\${Math.round(qualityReport.quality_metrics.error_rate * 100)}%) exceeds threshold`
      });
    }

    if (qualityReport.quality_metrics.success_rate < this.thresholds.min_success_rate) {
      qualityReport.issues.push({
        type: 'low_success_rate',
        severity: 'high',
        message: `Success rate (\${Math.round(qualityReport.quality_metrics.success_rate * 100)}%) below threshold`
      });
    }

    if (qualityReport.quality_metrics.avg_quality_score < this.thresholds.min_quality_score) {
      qualityReport.issues.push({
        type: 'low_quality_score',
        severity: 'medium',
        message: `Quality score (\${Math.round(qualityReport.quality_metrics.avg_quality_score)}) below threshold`
      });
    }

    // Create alerts for issues
    for (const issue of qualityReport.issues) {
      await this._createAlert({
        type: issue.type,
        severity: issue.severity,
        agent: agent || 'all',
        message: issue.message,
        details: qualityReport.quality_metrics
      });
    }

    return qualityReport;
  }

  /**
   * Get AI performance metrics
   */
  async getPerformanceMetrics(agent = null, timeRange = {}) {
    const start = timeRange.start || new Date(Date.now() - 7*24*60*60*1000).toISOString();
    const end = timeRange.end || new Date().toISOString();

    const metrics = await this._getMetricsInRange(agent, start, end);

    const performance = {
      report_id: crypto.randomUUID(),
      generated_at: new Date().toISOString(),
      time_range: { start, end },
      agent: agent || 'all',
      total_decisions: metrics.length,
      metrics: {
        avg_confidence: 0,
        min_confidence: 1,
        max_confidence: 0,
        success_rate: 0,
        avg_quality_score: 0,
        avg_response_time: 0
      },
      performance_by_day: {},
      decision_types: {}
    };

    if (metrics.length === 0) {
      return performance;
    }

    // Calculate overall metrics
    let totalConfidence = 0;
    let totalQuality = 0;
    let totalResponseTime = 0;
    let successCount = 0;

    for (const metric of metrics) {
      // Confidence
      if (metric.confidence !== null) {
        totalConfidence += metric.confidence;
        performance.metrics.min_confidence = Math.min(performance.metrics.min_confidence, metric.confidence);
        performance.metrics.max_confidence = Math.max(performance.metrics.max_confidence, metric.confidence);
      }

      // Quality
      if (metric.quality_score !== null) {
        totalQuality += metric.quality_score;
      }

      // Response time
      if (metric.response_time !== null) {
        totalResponseTime += metric.response_time;
      }

      // Success
      if (metric.success) {
        successCount++;
      }

      // By decision type
      if (!performance.decision_types[metric.decision_type]) {
        performance.decision_types[metric.decision_type] = { count: 0, success: 0 };
      }
      performance.decision_types[metric.decision_type].count++;
      if (metric.success) {
        performance.decision_types[metric.decision_type].success++;
      }
    }

    performance.metrics.avg_confidence = totalConfidence / metrics.length;
    performance.metrics.success_rate = successCount / metrics.length;
    performance.metrics.avg_quality_score = totalQuality / metrics.length;
    performance.metrics.avg_response_time = totalResponseTime / metrics.length;

    return performance;
  }

  /**
   * Get active alerts
   */
  async getAlerts(filters = {}) {
    try {
      const content = await fs.readFile(this.alertsPath, 'utf8');
      const lines = content.trim().split('\n');

      let alerts = lines.map(line => JSON.parse(line));

      // Apply filters
      if (filters.type) {
        alerts = alerts.filter(a => a.type === filters.type);
      }

      if (filters.severity) {
        alerts = alerts.filter(a => a.severity === filters.severity);
      }

      if (filters.agent) {
        alerts = alerts.filter(a => a.agent === filters.agent);
      }

      // Sort by created time (newest first)
      alerts.sort((a, b) => new Date(b.created_at) - new Date(a.created_at));

      return alerts;
    } catch (error) {
      return [];
    }
  }

  /**
   * Update baseline metrics
   */
  async updateBaseline(metrics) {
    this.baseline.metrics = { ...this.baseline.metrics, ...metrics };
    this.baseline.updated_at = new Date().toISOString();

    await this._saveBaseline();

    console.log('Baseline metrics updated');
  }

  /**
   * Check quality for single decision
   */
  async _checkQuality(metric) {
    const issues = [];

    // Check confidence
    if (metric.confidence !== null && metric.confidence < this.thresholds.min_confidence) {
      issues.push({
        type: 'low_confidence',
        severity: 'medium',
        message: `Decision confidence (\${Math.round(metric.confidence * 100)}%) below threshold`
      });
    }

    // Check quality score
    if (metric.quality_score !== null && metric.quality_score < this.thresholds.min_quality_score) {
      issues.push({
        type: 'low_quality',
        severity: 'medium',
        message: `Decision quality score (\${metric.quality_score}) below threshold`
      });
    }

    // Check success
    if (!metric.success) {
      issues.push({
        type: 'decision_failure',
        severity: 'high',
        message: 'AI decision failed'
      });
    }

    // Create alerts for issues
    for (const issue of issues) {
      await this._createAlert({
        type: issue.type,
        severity: issue.severity,
        agent: metric.agent,
        message: issue.message,
        details: metric
      });
    }
  }

  /**
   * Get recent metrics within time window
   */
  async _getRecentMetrics(agent, timeWindow) {
    const cutoff = new Date(Date.now() - timeWindow).toISOString();
    return await this._getMetricsInRange(agent, cutoff, new Date().toISOString());
  }

  /**
   * Get metrics within date range
   */
  async _getMetricsInRange(agent, start, end) {
    try {
      const content = await fs.readFile(this.metricsPath, 'utf8');
      const lines = content.trim().split('\n');

      let metrics = lines.map(line => JSON.parse(line));

      // Filter by agent
      if (agent) {
        metrics = metrics.filter(m => m.agent === agent);
      }

      // Filter by date range
      metrics = metrics.filter(m => 
        m.timestamp >= start && m.timestamp <= end
      );

      return metrics;
    } catch (error) {
      return [];
    }
  }

  /**
   * Log metric to file
   */
  async _logMetric(metric) {
    const logLine = JSON.stringify(metric) + '\n';
    await fs.appendFile(this.metricsPath, logLine);
  }

  /**
   * Create alert
   */
  async _createAlert(alert) {
    const fullAlert = {
      alert_id: crypto.randomUUID(),
      created_at: new Date().toISOString(),
      ...alert
    };

    const logLine = JSON.stringify(fullAlert) + '\n';
    await fs.appendFile(this.alertsPath, logLine);

    console.log(`AI Alert: \${alert.type} - \${alert.message}`);
  }

  /**
   * Save baseline to file
   */
  async _saveBaseline() {
    await fs.writeFile(this.baselinePath, JSON.stringify(this.baseline, null, 2));
  }
}

// CLI interface
if (require.main === module) {
  const action = process.argv[2];
  const aiMonitor = new AIMonitor();

  (async () => {
    await aiMonitor.initialize();

    switch (action) {
      case 'drift':
        const agent = process.argv[3] || null;
        const drift = await aiMonitor.detectDrift(agent);
        console.log('\nModel Drift Analysis:');
        console.log(JSON.stringify(drift, null, 2));
        break;

      case 'quality':
        const qualityAgent = process.argv[3] || null;
        const quality = await aiMonitor.monitorQuality(qualityAgent);
        console.log('\nQuality Report:');
        console.log(JSON.stringify(quality, null, 2));
        break;

      case 'performance':
        const perfAgent = process.argv[3] || null;
        const performance = await aiMonitor.getPerformanceMetrics(perfAgent);
        console.log('\nPerformance Metrics:');
        console.log(JSON.stringify(performance, null, 2));
        break;

      case 'alerts':
        const severity = process.argv[3] || null;
        const alerts = await aiMonitor.getAlerts({ severity });
        console.log(`\nAI Alerts${severity ? ` (${severity})` : ''}:`);
        console.log(JSON.stringify(alerts, null, 2));
        break;

      default:
        console.log('Usage: node ai-monitor.js <action>');
        console.log('Actions:');
        console.log('  drift [agent]          - Detect model drift');
        console.log('  quality [agent]        - Monitor quality');
        console.log('  performance [agent]    - Get performance metrics');
        console.log('  alerts [severity]      - View alerts');
        break;
    }
  })();
}

module.exports = AIMonitor;
