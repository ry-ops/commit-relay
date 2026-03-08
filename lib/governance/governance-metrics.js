#!/usr/bin/env node
// lib/governance/governance-metrics.js
// Governance Metrics & Continuous Improvement
// Part of Phase 6.5: Governance Upgrade
//
// Responsibilities:
// - Collect comprehensive governance metrics
// - Track improvement trends
// - Generate governance dashboards
// - Provide actionable insights

const fs = require('fs').promises;
const path = require('path');
const crypto = require('crypto');

class GovernanceMetrics {
  constructor() {
    this.metricsPath = 'coordination/governance/metrics-snapshots.jsonl';
    this.trendsPath = 'coordination/governance/trends.json';
    this.dashboardPath = 'coordination/governance/dashboard.json';
  }

  /**
   * Initialize governance metrics
   */
  async initialize() {
    try {
      await fs.mkdir(path.dirname(this.metricsPath), { recursive: true });
      console.log('Governance Metrics initialized');
      return true;
    } catch (error) {
      console.error('Failed to initialize Governance Metrics:', error.message);
      return false;
    }
  }

  /**
   * Collect comprehensive metrics snapshot
   */
  async collectMetrics(components = {}) {
    const {
      catalogManager,
      lineageTracker,
      piiScanner,
      qualityValidator,
      accessControl,
      complianceEngine,
      aiMonitor
    } = components;

    const snapshot = {
      snapshot_id: crypto.randomUUID(),
      timestamp: new Date().toISOString(),
      metrics: {}
    };

    // Catalog metrics
    if (catalogManager) {
      const catalogReport = await catalogManager.generateReport();
      snapshot.metrics.catalog = {
        total_assets: catalogReport.summary.total_data_assets + 
                     catalogReport.summary.total_ai_assets + 
                     catalogReport.summary.total_model_assets,
        data_assets: catalogReport.summary.total_data_assets,
        ai_assets: catalogReport.summary.total_ai_assets,
        model_assets: catalogReport.summary.total_model_assets,
        namespaces: catalogReport.summary.total_namespaces
      };
    }

    // Lineage metrics
    if (lineageTracker) {
      const lineageReport = await lineageTracker.generateComplianceReport();
      snapshot.metrics.lineage = {
        total_events: lineageReport.metrics.total_access_events + 
                     lineageReport.metrics.total_transformations + 
                     lineageReport.metrics.total_ai_decisions,
        access_events: lineageReport.metrics.total_access_events,
        transformations: lineageReport.metrics.total_transformations,
        ai_decisions: lineageReport.metrics.total_ai_decisions,
        unauthorized_attempts: lineageReport.metrics.unauthorized_attempts
      };
    }

    // PII scanning metrics
    if (piiScanner) {
      const piiReport = await piiScanner.generateRemediationReport();
      snapshot.metrics.pii = {
        total_scans: piiReport.total_scans,
        files_with_pii: piiReport.files_with_pii,
        high_risk_files: piiReport.high_risk_files.length,
        findings_by_type: piiReport.findings_by_type
      };
    }

    // Quality metrics
    if (qualityValidator) {
      const qualityAudit = await qualityValidator.auditDirectory('coordination');
      snapshot.metrics.quality = {
        files_audited: qualityAudit.files_audited,
        files_passed: qualityAudit.files_passed,
        files_failed: qualityAudit.files_failed,
        average_quality_score: qualityAudit.average_quality_score,
        total_issues: qualityAudit.total_issues,
        critical_issues: qualityAudit.critical_issues
      };
    }

    // Access control metrics
    if (accessControl) {
      const accessReport = await accessControl.generateAccessReport();
      snapshot.metrics.access = {
        total_access_attempts: accessReport.total_access_attempts,
        permitted_accesses: accessReport.permitted_accesses,
        denied_accesses: accessReport.denied_accesses,
        access_success_rate: accessReport.total_access_attempts > 0
          ? (accessReport.permitted_accesses / accessReport.total_access_attempts)
          : 1.0
      };
    }

    // Compliance metrics
    if (complianceEngine) {
      const complianceReport = await complianceEngine.generateComplianceReport();
      snapshot.metrics.compliance = {
        compliance_score: complianceReport.executive_summary.compliance_score,
        total_policies: complianceReport.executive_summary.total_policies,
        policies_passed: complianceReport.executive_summary.policies_passed,
        policies_failed: complianceReport.executive_summary.policies_failed,
        critical_violations: complianceReport.executive_summary.critical_violations,
        high_violations: complianceReport.executive_summary.high_violations
      };
    }

    // AI monitoring metrics
    if (aiMonitor) {
      const aiPerformance = await aiMonitor.getPerformanceMetrics();
      snapshot.metrics.ai_monitoring = {
        total_decisions: aiPerformance.total_decisions,
        avg_confidence: aiPerformance.metrics.avg_confidence,
        success_rate: aiPerformance.metrics.success_rate,
        avg_quality_score: aiPerformance.metrics.avg_quality_score,
        avg_response_time: aiPerformance.metrics.avg_response_time
      };
    }

    // Calculate overall governance score
    snapshot.metrics.governance_score = await this._calculateGovernanceScore(snapshot.metrics);

    // Save snapshot
    await this._saveSnapshot(snapshot);

    return snapshot;
  }

  /**
   * Analyze trends over time
   */
  async analyzeTrends(days = 30) {
    const cutoff = new Date(Date.now() - days * 24 * 60 * 60 * 1000).toISOString();
    const snapshots = await this._getSnapshotsSince(cutoff);

    if (snapshots.length === 0) {
      return {
        message: 'Insufficient data for trend analysis',
        data_points: 0
      };
    }

    const trends = {
      analysis_id: crypto.randomUUID(),
      generated_at: new Date().toISOString(),
      time_range: {
        start: snapshots[snapshots.length - 1].timestamp,
        end: snapshots[0].timestamp
      },
      data_points: snapshots.length,
      trends: {}
    };

    // Analyze governance score trend
    trends.trends.governance_score = this._analyzeTrend(
      snapshots.map(s => s.metrics.governance_score)
    );

    // Analyze compliance score trend
    if (snapshots.some(s => s.metrics.compliance)) {
      trends.trends.compliance_score = this._analyzeTrend(
        snapshots
          .filter(s => s.metrics.compliance)
          .map(s => s.metrics.compliance.compliance_score)
      );
    }

    // Analyze quality trend
    if (snapshots.some(s => s.metrics.quality)) {
      trends.trends.quality_score = this._analyzeTrend(
        snapshots
          .filter(s => s.metrics.quality)
          .map(s => s.metrics.quality.average_quality_score)
      );
    }

    // Analyze PII exposure trend
    if (snapshots.some(s => s.metrics.pii)) {
      trends.trends.pii_exposure = this._analyzeTrend(
        snapshots
          .filter(s => s.metrics.pii)
          .map(s => s.metrics.pii.high_risk_files),
        'lower_is_better'
      );
    }

    // Analyze AI performance trend
    if (snapshots.some(s => s.metrics.ai_monitoring)) {
      trends.trends.ai_success_rate = this._analyzeTrend(
        snapshots
          .filter(s => s.metrics.ai_monitoring)
          .map(s => s.metrics.ai_monitoring.success_rate)
      );
    }

    // Save trends
    await this._saveTrends(trends);

    return trends;
  }

  /**
   * Generate governance dashboard
   */
  async generateDashboard(components = {}) {
    // Collect latest metrics
    const latestSnapshot = await this.collectMetrics(components);

    // Analyze trends
    const trends = await this.analyzeTrends(30);

    const dashboard = {
      dashboard_id: crypto.randomUUID(),
      generated_at: new Date().toISOString(),
      current_metrics: latestSnapshot.metrics,
      governance_score: latestSnapshot.metrics.governance_score,
      trends: trends.trends || {},
      insights: await this._generateInsights(latestSnapshot, trends),
      recommendations: await this._generateRecommendations(latestSnapshot, trends),
      health_indicators: await this._calculateHealthIndicators(latestSnapshot.metrics)
    };

    // Save dashboard
    await this._saveDashboard(dashboard);

    return dashboard;
  }

  /**
   * Get improvement recommendations
   */
  async getImprovementRecommendations(components = {}) {
    const snapshot = await this.collectMetrics(components);
    const trends = await this.analyzeTrends(30);

    return await this._generateRecommendations(snapshot, trends);
  }

  /**
   * Calculate overall governance score (0-100)
   */
  async _calculateGovernanceScore(metrics) {
    let score = 0;
    let weights = 0;

    // Compliance score (weight: 30%)
    if (metrics.compliance) {
      score += metrics.compliance.compliance_score * 0.3;
      weights += 0.3;
    }

    // Quality score (weight: 25%)
    if (metrics.quality) {
      score += metrics.quality.average_quality_score * 0.25;
      weights += 0.25;
    }

    // Access control (weight: 15%)
    if (metrics.access) {
      score += metrics.access.access_success_rate * 100 * 0.15;
      weights += 0.15;
    }

    // AI monitoring (weight: 15%)
    if (metrics.ai_monitoring) {
      score += metrics.ai_monitoring.success_rate * 100 * 0.15;
      weights += 0.15;
    }

    // PII protection (weight: 10%)
    if (metrics.pii) {
      const piiScore = metrics.pii.total_scans > 0
        ? ((metrics.pii.total_scans - metrics.pii.files_with_pii) / metrics.pii.total_scans) * 100
        : 100;
      score += piiScore * 0.1;
      weights += 0.1;
    }

    // Lineage tracking (weight: 5%)
    if (metrics.lineage) {
      const lineageScore = metrics.lineage.total_events > 0
        ? ((metrics.lineage.total_events - metrics.lineage.unauthorized_attempts) / metrics.lineage.total_events) * 100
        : 100;
      score += lineageScore * 0.05;
      weights += 0.05;
    }

    return weights > 0 ? Math.round(score / weights) : 0;
  }

  /**
   * Analyze trend for a metric
   */
  _analyzeTrend(values, direction = 'higher_is_better') {
    if (values.length < 2) {
      return { trend: 'insufficient_data', change: 0 };
    }

    const first = values[values.length - 1];
    const last = values[0];
    const change = last - first;
    const percentChange = first !== 0 ? (change / first) * 100 : 0;

    let trend;
    if (Math.abs(percentChange) < 2) {
      trend = 'stable';
    } else if (direction === 'higher_is_better') {
      trend = change > 0 ? 'improving' : 'declining';
    } else {
      trend = change < 0 ? 'improving' : 'declining';
    }

    return {
      trend: trend,
      change: percentChange,
      first_value: first,
      last_value: last,
      data_points: values.length
    };
  }

  /**
   * Generate insights from metrics and trends
   */
  async _generateInsights(snapshot, trends) {
    const insights = [];

    // Governance score insights
    if (snapshot.metrics.governance_score >= 90) {
      insights.push({
        type: 'positive',
        category: 'governance',
        message: `Excellent governance score: \${snapshot.metrics.governance_score}%`,
        priority: 'low'
      });
    } else if (snapshot.metrics.governance_score < 70) {
      insights.push({
        type: 'warning',
        category: 'governance',
        message: `Governance score below target: \${snapshot.metrics.governance_score}%`,
        priority: 'high'
      });
    }

    // Compliance insights
    if (snapshot.metrics.compliance) {
      if (snapshot.metrics.compliance.critical_violations > 0) {
        insights.push({
          type: 'critical',
          category: 'compliance',
          message: `\${snapshot.metrics.compliance.critical_violations} critical compliance violations detected`,
          priority: 'critical'
        });
      }
    }

    // PII insights
    if (snapshot.metrics.pii && snapshot.metrics.pii.high_risk_files > 0) {
      insights.push({
        type: 'warning',
        category: 'pii',
        message: `\${snapshot.metrics.pii.high_risk_files} high-risk files with PII detected`,
        priority: 'high'
      });
    }

    // Trend insights
    if (trends.trends && trends.trends.governance_score) {
      if (trends.trends.governance_score.trend === 'improving') {
        insights.push({
          type: 'positive',
          category: 'trend',
          message: `Governance score improving: +\${Math.round(trends.trends.governance_score.change)}% over \${trends.data_points} days`,
          priority: 'low'
        });
      } else if (trends.trends.governance_score.trend === 'declining') {
        insights.push({
          type: 'warning',
          category: 'trend',
          message: `Governance score declining: \${Math.round(trends.trends.governance_score.change)}% over \${trends.data_points} days`,
          priority: 'medium'
        });
      }
    }

    return insights;
  }

  /**
   * Generate actionable recommendations
   */
  async _generateRecommendations(snapshot, trends) {
    const recommendations = [];

    // Compliance recommendations
    if (snapshot.metrics.compliance) {
      if (snapshot.metrics.compliance.compliance_score < 95) {
        recommendations.push({
          priority: 'high',
          category: 'compliance',
          action: 'Improve compliance score to meet 95% target',
          details: `Current: \${snapshot.metrics.compliance.compliance_score}%`,
          estimated_effort: 'medium'
        });
      }
    }

    // Quality recommendations
    if (snapshot.metrics.quality) {
      if (snapshot.metrics.quality.critical_issues > 0) {
        recommendations.push({
          priority: 'critical',
          category: 'quality',
          action: 'Address critical data quality issues',
          details: `\${snapshot.metrics.quality.critical_issues} critical issues detected`,
          estimated_effort: 'high'
        });
      }
    }

    // PII recommendations
    if (snapshot.metrics.pii && snapshot.metrics.pii.files_with_pii > 0) {
      recommendations.push({
        priority: 'high',
        category: 'pii',
        action: 'Remediate PII exposure in data files',
        details: `\${snapshot.metrics.pii.files_with_pii} files contain PII`,
        estimated_effort: 'medium'
      });
    }

    // Trend-based recommendations
    if (trends.trends) {
      if (trends.trends.governance_score && trends.trends.governance_score.trend === 'declining') {
        recommendations.push({
          priority: 'medium',
          category: 'continuous_improvement',
          action: 'Investigate governance score decline',
          details: `Score declining by \${Math.round(trends.trends.governance_score.change)}% over past \${trends.data_points} days`,
          estimated_effort: 'low'
        });
      }
    }

    // Always recommend periodic review
    recommendations.push({
      priority: 'low',
      category: 'maintenance',
      action: 'Schedule quarterly governance review',
      details: 'Maintain continuous governance monitoring',
      estimated_effort: 'low'
    });

    return recommendations;
  }

  /**
   * Calculate health indicators
   */
  async _calculateHealthIndicators(metrics) {
    const indicators = {
      overall: 'healthy',
      components: {}
    };

    // Compliance health
    if (metrics.compliance) {
      indicators.components.compliance = 
        metrics.compliance.compliance_score >= 95 ? 'healthy' :
        metrics.compliance.compliance_score >= 85 ? 'warning' : 'critical';
    }

    // Quality health
    if (metrics.quality) {
      indicators.components.quality = 
        metrics.quality.average_quality_score >= 90 ? 'healthy' :
        metrics.quality.average_quality_score >= 75 ? 'warning' : 'critical';
    }

    // PII health
    if (metrics.pii) {
      indicators.components.pii = 
        metrics.pii.high_risk_files === 0 ? 'healthy' :
        metrics.pii.high_risk_files <= 5 ? 'warning' : 'critical';
    }

    // AI health
    if (metrics.ai_monitoring) {
      indicators.components.ai = 
        metrics.ai_monitoring.success_rate >= 0.95 ? 'healthy' :
        metrics.ai_monitoring.success_rate >= 0.85 ? 'warning' : 'critical';
    }

    // Overall health (worst component)
    const componentHealthValues = Object.values(indicators.components);
    if (componentHealthValues.includes('critical')) {
      indicators.overall = 'critical';
    } else if (componentHealthValues.includes('warning')) {
      indicators.overall = 'warning';
    }

    return indicators;
  }

  /**
   * Get snapshots since date
   */
  async _getSnapshotsSince(sinceDate) {
    try {
      const content = await fs.readFile(this.metricsPath, 'utf8');
      const lines = content.trim().split('\n');

      let snapshots = lines.map(line => JSON.parse(line));

      // Filter by date
      snapshots = snapshots.filter(s => s.timestamp >= sinceDate);

      // Sort by timestamp (newest first)
      snapshots.sort((a, b) => new Date(b.timestamp) - new Date(a.timestamp));

      return snapshots;
    } catch (error) {
      return [];
    }
  }

  /**
   * Save snapshot to file
   */
  async _saveSnapshot(snapshot) {
    const logLine = JSON.stringify(snapshot) + '\n';
    await fs.appendFile(this.metricsPath, logLine);
  }

  /**
   * Save trends to file
   */
  async _saveTrends(trends) {
    await fs.writeFile(this.trendsPath, JSON.stringify(trends, null, 2));
  }

  /**
   * Save dashboard to file
   */
  async _saveDashboard(dashboard) {
    await fs.writeFile(this.dashboardPath, JSON.stringify(dashboard, null, 2));
  }
}

// CLI interface
if (require.main === module) {
  const action = process.argv[2];
  const governanceMetrics = new GovernanceMetrics();

  (async () => {
    await governanceMetrics.initialize();

    switch (action) {
      case 'collect':
        const snapshot = await governanceMetrics.collectMetrics({});
        console.log('\nMetrics Snapshot:');
        console.log(JSON.stringify(snapshot, null, 2));
        break;

      case 'trends':
        const days = parseInt(process.argv[3]) || 30;
        const trends = await governanceMetrics.analyzeTrends(days);
        console.log(`\nTrends (last \${days} days):`);
        console.log(JSON.stringify(trends, null, 2));
        break;

      case 'dashboard':
        const dashboard = await governanceMetrics.generateDashboard({});
        console.log('\nGovernance Dashboard:');
        console.log(JSON.stringify(dashboard, null, 2));
        break;

      case 'recommendations':
        const recs = await governanceMetrics.getImprovementRecommendations({});
        console.log('\nImprovement Recommendations:');
        console.log(JSON.stringify(recs, null, 2));
        break;

      default:
        console.log('Usage: node governance-metrics.js <action>');
        console.log('Actions:');
        console.log('  collect               - Collect metrics snapshot');
        console.log('  trends [days]         - Analyze trends');
        console.log('  dashboard             - Generate dashboard');
        console.log('  recommendations       - Get recommendations');
        break;
    }
  })();
}

module.exports = GovernanceMetrics;
