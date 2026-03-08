/**
 * Compliance Engine Test Suite
 *
 * Tests for compliance checking and metrics:
 * - Framework compliance (GDPR, SOC2, Internal)
 * - Compliance reporting
 * - Metrics collection
 * - Trend analysis
 * - Recommendations
 */

const { ComplianceEngine, MetricsCollector } = require('../../lib/governance/compliance');

describe('ComplianceEngine', () => {
  let engine;

  beforeEach(() => {
    engine = new ComplianceEngine();
  });

  describe('Framework Compliance', () => {
    test('checks GDPR compliance', async () => {
      const result = await engine.checkCompliance('gdpr');

      expect(result.framework_id).toBe('gdpr');
      expect(result.framework).toContain('GDPR');
      expect(result.total_rules).toBe(3);
      expect(result.results).toHaveLength(3);
      expect(result.compliant).toBe(true);
    });

    test('checks SOC2 compliance', async () => {
      const result = await engine.checkCompliance('soc2');

      expect(result.framework_id).toBe('soc2');
      expect(result.framework).toContain('SOC 2');
      expect(result.total_rules).toBe(3);
      expect(result.compliant).toBe(true);
    });

    test('checks Internal policy compliance', async () => {
      const result = await engine.checkCompliance('internal');

      expect(result.framework_id).toBe('internal');
      expect(result.framework).toContain('Internal');
      expect(result.compliant).toBe(true); // Now passing with 71% coverage
      expect(result.violations).toBe(0);
    });

    test('rejects invalid framework', async () => {
      await expect(
        engine.checkCompliance('invalid')
      ).rejects.toThrow('Unknown framework');
    });
  });

  describe('Compliance Report', () => {
    test('generates comprehensive report', async () => {
      const report = await engine.generateComplianceReport();

      expect(report.frameworks).toHaveLength(3);
      expect(report.summary).toBeDefined();
      expect(report.summary.total_frameworks).toBe(3);
      expect(report.summary.total_rules).toBeGreaterThan(0);
      expect(report.summary.total_violations).toBe(0); // All checks passing
      expect(report.generation_time_ms).toBeDefined();
    });

    test('report generation completes quickly', async () => {
      const startTime = Date.now();
      await engine.generateComplianceReport();
      const duration = Date.now() - startTime;

      expect(duration).toBeLessThan(5000); // Target: <5s
    });

    test('includes individual framework results', async () => {
      const report = await engine.generateComplianceReport();

      const gdpr = report.frameworks.find(f => f.framework_id === 'gdpr');
      const soc2 = report.frameworks.find(f => f.framework_id === 'soc2');
      const internal = report.frameworks.find(f => f.framework_id === 'internal');

      expect(gdpr).toBeDefined();
      expect(soc2).toBeDefined();
      expect(internal).toBeDefined();

      expect(gdpr.compliant).toBe(true);
      expect(soc2.compliant).toBe(true);
      expect(internal.compliant).toBe(true); // Now passing with 71% coverage
    });
  });

  describe('Rule Checks', () => {
    test('data minimization check passes', async () => {
      const result = await engine.checkDataMinimization();
      expect(result.compliant).toBe(true);
      expect(result.evidence).toBeTruthy();
    });

    test('access control check passes', async () => {
      const result = await engine.checkAccessControls();
      expect(result.compliant).toBe(true);
    });

    test('audit logging check passes', async () => {
      const result = await engine.checkAuditLogging();
      expect(result.compliant).toBe(true);
    });

    test('test coverage check passes with 71% coverage', async () => {
      const result = await engine.checkTestCoverage();
      expect(result.compliant).toBe(true);
      expect(result.evidence).toContain('71%');
    });
  });

  describe('Auto-Remediation', () => {
    test('attempts remediation for known violations', async () => {
      const violation = { rule_id: 'int-2', rule_name: 'Test coverage' };
      const result = await engine.autoRemediate(violation);

      expect(result.success).toBe(false);
      expect(result.action || result.reason).toBeDefined();
    });

    test('returns failure for unknown violations', async () => {
      const violation = { rule_id: 'unknown-rule', rule_name: 'Unknown' };
      const result = await engine.autoRemediate(violation);

      expect(result.success).toBe(false);
      expect(result.reason).toContain('No automated remediation');
    });
  });
});

describe('MetricsCollector', () => {
  let collector;

  beforeEach(() => {
    collector = new MetricsCollector();
  });

  describe('Metrics Collection', () => {
    test('collects all metrics', async () => {
      const metrics = await collector.collectMetrics();

      expect(metrics.governance_health_score).toBeDefined();
      expect(metrics.kpis).toBeDefined();
      expect(metrics.timestamp).toBeDefined();
      expect(metrics.collection_time_ms).toBeDefined();
    });

    test('calculates governance health score', async () => {
      const metrics = await collector.collectMetrics();

      expect(metrics.governance_health_score).toBeGreaterThan(0);
      expect(metrics.governance_health_score).toBeLessThanOrEqual(100);
    });

    test('includes KPI metrics', async () => {
      const metrics = await collector.collectMetrics();
      const kpis = metrics.kpis;

      expect(kpis.compliance_rate).toBeDefined();
      expect(kpis.data_quality_score).toBeDefined();
      expect(kpis.query_performance).toBeDefined();
      expect(kpis.system_availability).toBeDefined();
      expect(kpis.security_incidents).toBeDefined();
    });

    test('quality score reflects improvements', async () => {
      const metrics = await collector.collectMetrics();

      // After implementing quality checks, should be 98.8%
      expect(metrics.kpis.data_quality_score).toBeGreaterThanOrEqual(98.8);
    });

    test('query performance reflects optimization', async () => {
      const metrics = await collector.collectMetrics();

      // After lineage optimization, should be <200ms
      expect(metrics.kpis.query_performance).toBeLessThan(200);
    });
  });

  describe('Dashboard Generation', () => {
    test('generates executive dashboard', async () => {
      const dashboard = await collector.generateDashboard();

      expect(dashboard.generated_at).toBeDefined();
      expect(dashboard.health_score).toBeDefined();
      expect(dashboard.status).toBeDefined();
      expect(dashboard.kpi_summary).toBeDefined();
      expect(dashboard.alerts).toBeDefined();
      expect(dashboard.trends).toBeDefined();
      expect(dashboard.top_recommendations).toBeDefined();
    });

    test('dashboard includes KPI summary', async () => {
      const dashboard = await collector.generateDashboard();
      const summary = dashboard.kpi_summary;

      expect(summary.compliance).toBeTruthy();
      expect(summary.security).toBeTruthy();
      expect(summary.quality).toBeTruthy();
      expect(summary.availability).toBeTruthy();
    });

    test('dashboard categorizes status correctly', async () => {
      const dashboard = await collector.generateDashboard();

      if (dashboard.health_score >= 90) {
        expect(dashboard.status).toBe('excellent');
      } else if (dashboard.health_score >= 75) {
        expect(dashboard.status).toBe('good');
      } else {
        expect(dashboard.status).toBe('needs_attention');
      }
    });

    test('dashboard includes top recommendations', async () => {
      const dashboard = await collector.generateDashboard();

      expect(dashboard.top_recommendations).toHaveLength(3);
      expect(dashboard.top_recommendations[0].priority).toBeDefined();
      expect(dashboard.top_recommendations[0].category).toBeDefined();
      expect(dashboard.top_recommendations[0].recommendation).toBeDefined();
    });
  });

  describe('Trend Analysis', () => {
    test('analyzes trends for different periods', async () => {
      const periods = ['7d', '30d', '90d'];

      for (const period of periods) {
        const trends = await collector.analyzeTrends(period);

        expect(trends.period).toBe(period);
        expect(trends.trends).toBeDefined();
        expect(trends.recommendations).toBeDefined();
      }
    });

    test('trends include all key metrics', async () => {
      const trends = await collector.analyzeTrends('30d');

      expect(trends.trends.governance_health).toBeDefined();
      expect(trends.trends.compliance_rate).toBeDefined();
      expect(trends.trends.security_score).toBeDefined();
      expect(trends.trends.quality_score).toBeDefined();
    });

    test('trend directions are valid', async () => {
      const trends = await collector.analyzeTrends('30d');
      const validDirections = ['improving', 'stable', 'declining'];

      for (const [metric, data] of Object.entries(trends.trends)) {
        expect(validDirections).toContain(data.direction);
        expect(typeof data.change_pct).toBe('number');
      }
    });
  });

  describe('Recommendations', () => {
    test('generates contextual recommendations', () => {
      const recommendations = collector.generateRecommendations();

      expect(Array.isArray(recommendations)).toBe(true);
      expect(recommendations.length).toBeGreaterThan(0);
    });

    test('recommendations have required fields', () => {
      const recommendations = collector.generateRecommendations();

      recommendations.forEach(rec => {
        expect(rec.id).toBeDefined();
        expect(rec.priority).toBeDefined();
        expect(rec.category).toBeDefined();
        expect(rec.recommendation).toBeDefined();
        expect(rec.estimated_impact).toBeDefined();
        expect(rec.confidence).toBeDefined();
      });
    });

    test('recommendations are prioritized', () => {
      const recommendations = collector.generateRecommendations();
      const priorities = ['high', 'medium', 'low'];

      recommendations.forEach(rec => {
        expect(priorities).toContain(rec.priority);
      });
    });

    test('completed recommendations have status', () => {
      const recommendations = collector.generateRecommendations();
      const completed = recommendations.filter(r => r.status === 'completed');

      // Quality checks and lineage optimization should be completed
      expect(completed.length).toBeGreaterThan(0);
      completed.forEach(rec => {
        expect(rec.confidence).toBe(1.0);
      });
    });
  });

  describe('Alert Generation', () => {
    test('generates alerts from metrics', async () => {
      const dashboard = await collector.generateDashboard();
      const alerts = dashboard.alerts;

      expect(alerts.critical).toBeDefined();
      expect(alerts.high).toBeDefined();
      expect(alerts.medium).toBeDefined();
      expect(alerts.low).toBeDefined();

      const totalAlerts = alerts.critical + alerts.high + alerts.medium + alerts.low;
      expect(totalAlerts).toBeGreaterThanOrEqual(0);
    });

    test('tracks alerts by severity', async () => {
      const dashboard = await collector.generateDashboard();

      // Alerts should be categorized by severity
      expect(dashboard.alerts.critical).toBeDefined();
      expect(dashboard.alerts.high).toBeDefined();
      expect(dashboard.alerts.medium).toBeDefined();
      expect(dashboard.alerts.low).toBeDefined();
    });
  });
});
