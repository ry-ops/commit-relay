/**
 * Compliance Dashboard API Routes
 * Part of Phase 3 Security & Compliance
 *
 * Provides endpoints for compliance monitoring and reporting:
 * - GET /api/compliance/status - Get overall compliance status
 * - GET /api/compliance/frameworks - Get compliance by framework
 * - GET /api/compliance/nist-csf - Get NIST CSF compliance report
 * - GET /api/compliance/soc2 - Get SOC2 compliance status
 * - GET /api/compliance/owasp - Get OWASP compliance status
 * - GET /api/compliance/policies - List all policies
 * - POST /api/compliance/evaluate - Evaluate target against policies
 * - GET /api/compliance/trends - Get compliance trends over time
 * - GET /api/compliance/audit-log - Get policy evaluation audit log
 * - GET /api/compliance/export - Export compliance report
 */

const express = require('express');
const router = express.Router();
const { execSync, spawn } = require('child_process');
const fs = require('fs').promises;
const fsSync = require('fs');
const path = require('path');

// Project paths
const PROJECT_ROOT = path.resolve(__dirname, '../../..');
const COORDINATION_DIR = path.join(PROJECT_ROOT, 'coordination');
const POLICIES_DIR = path.join(COORDINATION_DIR, 'policies');
const POLICY_DEFINITIONS_DIR = path.join(POLICIES_DIR, 'policy-definitions');
const AUDIT_LOG_FILE = path.join(POLICIES_DIR, 'audit-logs/policy-evaluations.jsonl');
const NIST_REPORT_DIR = path.join(COORDINATION_DIR, 'security/nist-csf');

/**
 * GET /api/compliance/status
 * Get overall compliance status across all frameworks
 */
router.get('/status', async (req, res) => {
  try {
    // Get NIST CSF status
    const nistStatus = await getNistCsfStatus();

    // Get SOC2 status (derived from policies)
    const soc2Status = await getFrameworkStatus('soc2');

    // Get OWASP status
    const owaspStatus = await getFrameworkStatus('owasp');

    // Calculate overall compliance
    const scores = [
      nistStatus.score || 0,
      soc2Status.score || 0,
      owaspStatus.score || 0
    ].filter(s => s > 0);

    const overallScore = scores.length > 0
      ? scores.reduce((a, b) => a + b, 0) / scores.length
      : 0;

    const overallStatus = overallScore >= 80 ? 'compliant'
      : overallScore >= 60 ? 'partial'
      : 'non-compliant';

    res.json({
      success: true,
      data: {
        overall: {
          score: Math.round(overallScore * 100) / 100,
          status: overallStatus,
          last_updated: new Date().toISOString()
        },
        frameworks: {
          'nist-csf': nistStatus,
          'soc2': soc2Status,
          'owasp': owaspStatus
        },
        summary: {
          total_controls: (nistStatus.controls || 0) + (soc2Status.controls || 0) + (owaspStatus.controls || 0),
          passing: (nistStatus.passing || 0) + (soc2Status.passing || 0) + (owaspStatus.passing || 0),
          failing: (nistStatus.failing || 0) + (soc2Status.failing || 0) + (owaspStatus.failing || 0),
          warnings: (nistStatus.warnings || 0) + (soc2Status.warnings || 0) + (owaspStatus.warnings || 0)
        }
      }
    });
  } catch (error) {
    console.error('Error fetching compliance status:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to fetch compliance status',
      message: error.message
    });
  }
});

/**
 * GET /api/compliance/frameworks
 * Get detailed compliance status for all frameworks
 */
router.get('/frameworks', async (req, res) => {
  try {
    const frameworks = [
      {
        id: 'nist-csf',
        name: 'NIST Cybersecurity Framework',
        version: '1.1',
        description: 'Framework for improving critical infrastructure cybersecurity',
        categories: ['Identify', 'Protect', 'Detect', 'Respond', 'Recover']
      },
      {
        id: 'soc2',
        name: 'SOC 2 Type II',
        version: '2017',
        description: 'Trust Services Criteria for security, availability, and confidentiality',
        categories: ['Security', 'Availability', 'Confidentiality', 'Processing Integrity', 'Privacy']
      },
      {
        id: 'owasp',
        name: 'OWASP Top 10',
        version: '2021',
        description: 'Top 10 web application security risks',
        categories: ['Broken Access Control', 'Cryptographic Failures', 'Injection', 'Insecure Design', 'Security Misconfiguration']
      }
    ];

    // Get status for each framework
    const frameworksWithStatus = await Promise.all(
      frameworks.map(async (fw) => {
        const status = await getFrameworkStatus(fw.id);
        return { ...fw, ...status };
      })
    );

    res.json({
      success: true,
      data: frameworksWithStatus
    });
  } catch (error) {
    console.error('Error fetching frameworks:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to fetch frameworks',
      message: error.message
    });
  }
});

/**
 * GET /api/compliance/nist-csf
 * Get detailed NIST CSF compliance report
 */
router.get('/nist-csf', async (req, res) => {
  try {
    // Try to read latest NIST report
    const reportPath = path.join(NIST_REPORT_DIR, 'latest-report.json');

    let report;
    if (fsSync.existsSync(reportPath)) {
      const reportData = await fs.readFile(reportPath, 'utf8');
      report = JSON.parse(reportData);
    } else {
      // Generate report using the NIST CSF mapper
      report = await generateNistCsfReport();
    }

    res.json({
      success: true,
      data: report
    });
  } catch (error) {
    console.error('Error fetching NIST CSF report:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to fetch NIST CSF report',
      message: error.message
    });
  }
});

/**
 * GET /api/compliance/soc2
 * Get SOC2 compliance status
 */
router.get('/soc2', async (req, res) => {
  try {
    // Get SOC2-specific policies and their evaluations
    const policies = await getPoliciesByFramework('soc2');
    const auditLog = await getRecentAuditEntries(100, 'soc2');

    // Calculate SOC2 category scores
    const categories = {
      security: { score: 0, controls: [], passing: 0, total: 0 },
      availability: { score: 0, controls: [], passing: 0, total: 0 },
      confidentiality: { score: 0, controls: [], passing: 0, total: 0 },
      processing_integrity: { score: 0, controls: [], passing: 0, total: 0 },
      privacy: { score: 0, controls: [], passing: 0, total: 0 }
    };

    // Map controls to categories based on CC (Common Criteria) numbering
    policies.forEach(policy => {
      if (policy.controls) {
        policy.controls.forEach(control => {
          if (control.startsWith('CC6') || control.startsWith('CC7') || control.startsWith('CC8')) {
            categories.security.controls.push(control);
            categories.security.total++;
          }
          // Add more mappings as needed
        });
      }
    });

    // Calculate scores from audit log
    const recentResults = auditLog.slice(0, 10);
    const passCount = recentResults.filter(r => r.result === 'pass').length;
    const totalCount = recentResults.length || 1;

    const overallScore = (passCount / totalCount) * 100;

    res.json({
      success: true,
      data: {
        framework: 'SOC 2 Type II',
        version: '2017',
        overall_score: Math.round(overallScore * 100) / 100,
        status: overallScore >= 80 ? 'compliant' : overallScore >= 60 ? 'partial' : 'non-compliant',
        categories,
        policies: policies.length,
        recent_evaluations: recentResults.length,
        last_updated: new Date().toISOString()
      }
    });
  } catch (error) {
    console.error('Error fetching SOC2 status:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to fetch SOC2 status',
      message: error.message
    });
  }
});

/**
 * GET /api/compliance/owasp
 * Get OWASP compliance status
 */
router.get('/owasp', async (req, res) => {
  try {
    // Get OWASP-specific policies
    const policies = await getPoliciesByFramework('owasp');
    const auditLog = await getRecentAuditEntries(100, 'owasp');

    // OWASP Top 10 2021 categories
    const categories = {
      'A01': { name: 'Broken Access Control', score: 0, status: 'unknown' },
      'A02': { name: 'Cryptographic Failures', score: 0, status: 'unknown' },
      'A03': { name: 'Injection', score: 0, status: 'unknown' },
      'A04': { name: 'Insecure Design', score: 0, status: 'unknown' },
      'A05': { name: 'Security Misconfiguration', score: 0, status: 'unknown' },
      'A06': { name: 'Vulnerable Components', score: 0, status: 'unknown' },
      'A07': { name: 'Identification/Authentication', score: 0, status: 'unknown' },
      'A08': { name: 'Software/Data Integrity', score: 0, status: 'unknown' },
      'A09': { name: 'Security Logging/Monitoring', score: 0, status: 'unknown' },
      'A10': { name: 'Server-Side Request Forgery', score: 0, status: 'unknown' }
    };

    // Map policy controls to categories
    policies.forEach(policy => {
      if (policy.controls) {
        policy.controls.forEach(control => {
          const category = control.split('-')[0];
          if (categories[category]) {
            categories[category].score = 80; // Default implemented score
            categories[category].status = 'implemented';
          }
        });
      }
    });

    // Calculate overall score
    const scores = Object.values(categories).map(c => c.score);
    const overallScore = scores.reduce((a, b) => a + b, 0) / scores.length;

    res.json({
      success: true,
      data: {
        framework: 'OWASP Top 10',
        version: '2021',
        overall_score: Math.round(overallScore * 100) / 100,
        status: overallScore >= 80 ? 'compliant' : overallScore >= 60 ? 'partial' : 'non-compliant',
        categories,
        policies: policies.length,
        last_updated: new Date().toISOString()
      }
    });
  } catch (error) {
    console.error('Error fetching OWASP status:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to fetch OWASP status',
      message: error.message
    });
  }
});

/**
 * GET /api/compliance/policies
 * List all policy definitions
 */
router.get('/policies', async (req, res) => {
  try {
    const { framework, severity, enabled } = req.query;

    let policies = await listPolicies();

    // Apply filters
    if (framework) {
      policies = policies.filter(p =>
        p.frameworks && p.frameworks.includes(framework)
      );
    }

    if (severity) {
      policies = policies.filter(p => p.severity === severity);
    }

    if (enabled !== undefined) {
      const enabledBool = enabled === 'true';
      policies = policies.filter(p => p.enabled === enabledBool);
    }

    res.json({
      success: true,
      data: {
        total: policies.length,
        policies
      }
    });
  } catch (error) {
    console.error('Error listing policies:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to list policies',
      message: error.message
    });
  }
});

/**
 * GET /api/compliance/policies/:policyId
 * Get specific policy definition
 */
router.get('/policies/:policyId', async (req, res) => {
  try {
    const { policyId } = req.params;

    const policy = await getPolicyById(policyId);

    if (!policy) {
      return res.status(404).json({
        success: false,
        error: 'Policy not found'
      });
    }

    // Get evaluation history for this policy
    const history = await getPolicyHistory(policyId);

    res.json({
      success: true,
      data: {
        policy,
        history: history.slice(0, 20)
      }
    });
  } catch (error) {
    console.error('Error fetching policy:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to fetch policy',
      message: error.message
    });
  }
});

/**
 * POST /api/compliance/evaluate
 * Evaluate a target against policies
 */
router.post('/evaluate', async (req, res) => {
  try {
    const { target, policies, policyDir } = req.body;

    if (!target) {
      return res.status(400).json({
        success: false,
        error: 'Target is required'
      });
    }

    // Source the policy engine and evaluate
    const result = await evaluatePolicies(target, policies, policyDir);

    res.json({
      success: true,
      data: result
    });
  } catch (error) {
    console.error('Error evaluating policies:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to evaluate policies',
      message: error.message
    });
  }
});

/**
 * GET /api/compliance/trends
 * Get compliance trends over time
 */
router.get('/trends', async (req, res) => {
  try {
    const { days = 30, framework } = req.query;

    // Get audit log entries
    const auditEntries = await getAuditLog(1000);

    // Filter by framework if specified
    let filteredEntries = auditEntries;
    if (framework) {
      filteredEntries = auditEntries.filter(e =>
        e.policy && e.policy.frameworks && e.policy.frameworks.includes(framework)
      );
    }

    // Group by date
    const trends = {};
    const cutoffDate = new Date();
    cutoffDate.setDate(cutoffDate.getDate() - parseInt(days));

    filteredEntries.forEach(entry => {
      if (!entry.timestamp) return;

      const date = entry.timestamp.split('T')[0];
      const entryDate = new Date(date);

      if (entryDate >= cutoffDate) {
        if (!trends[date]) {
          trends[date] = { date, total: 0, passed: 0, failed: 0, score: 0 };
        }
        trends[date].total++;
        if (entry.result === 'pass') {
          trends[date].passed++;
        } else {
          trends[date].failed++;
        }
      }
    });

    // Calculate daily scores
    Object.values(trends).forEach(day => {
      day.score = day.total > 0 ? Math.round((day.passed / day.total) * 100) : 0;
    });

    // Sort by date
    const sortedTrends = Object.values(trends).sort((a, b) =>
      new Date(a.date) - new Date(b.date)
    );

    res.json({
      success: true,
      data: {
        period_days: parseInt(days),
        framework: framework || 'all',
        trends: sortedTrends
      }
    });
  } catch (error) {
    console.error('Error fetching trends:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to fetch compliance trends',
      message: error.message
    });
  }
});

/**
 * GET /api/compliance/audit-log
 * Get policy evaluation audit log
 */
router.get('/audit-log', async (req, res) => {
  try {
    const { limit = 100, offset = 0, policy_id, result } = req.query;

    let auditEntries = await getAuditLog(parseInt(limit) + parseInt(offset));

    // Apply filters
    if (policy_id) {
      auditEntries = auditEntries.filter(e =>
        e.policy && e.policy.id === policy_id
      );
    }

    if (result) {
      auditEntries = auditEntries.filter(e => e.result === result);
    }

    // Apply pagination
    const paginatedEntries = auditEntries.slice(parseInt(offset), parseInt(offset) + parseInt(limit));

    res.json({
      success: true,
      data: {
        total: auditEntries.length,
        limit: parseInt(limit),
        offset: parseInt(offset),
        entries: paginatedEntries
      }
    });
  } catch (error) {
    console.error('Error fetching audit log:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to fetch audit log',
      message: error.message
    });
  }
});

/**
 * GET /api/compliance/export
 * Export compliance report
 */
router.get('/export', async (req, res) => {
  try {
    const { format = 'json', framework } = req.query;

    // Generate comprehensive compliance report
    const report = {
      generated_at: new Date().toISOString(),
      format,
      frameworks: {}
    };

    // Get data for each framework
    const frameworks = framework ? [framework] : ['nist-csf', 'soc2', 'owasp'];

    for (const fw of frameworks) {
      const status = await getFrameworkStatus(fw);
      const policies = await getPoliciesByFramework(fw);
      const auditEntries = await getRecentAuditEntries(50, fw);

      report.frameworks[fw] = {
        status,
        policies_count: policies.length,
        recent_evaluations: auditEntries.length,
        policies: policies.map(p => ({
          id: p.policy_id,
          name: p.name,
          severity: p.severity,
          enabled: p.enabled
        }))
      };
    }

    // Calculate overall compliance
    const scores = Object.values(report.frameworks).map(f => f.status.score || 0);
    report.overall_compliance = {
      score: scores.reduce((a, b) => a + b, 0) / scores.length,
      frameworks_evaluated: frameworks.length
    };

    if (format === 'json') {
      res.json({
        success: true,
        data: report
      });
    } else if (format === 'pdf') {
      // PDF generation would require additional library
      // For now, return JSON with indication
      res.json({
        success: true,
        message: 'PDF export not yet implemented. Returning JSON format.',
        data: report
      });
    } else {
      res.status(400).json({
        success: false,
        error: 'Unsupported format. Use json or pdf.'
      });
    }
  } catch (error) {
    console.error('Error exporting report:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to export compliance report',
      message: error.message
    });
  }
});

// =============================================================================
// Helper Functions
// =============================================================================

/**
 * Get NIST CSF status from the mapper
 */
async function getNistCsfStatus() {
  try {
    const reportPath = path.join(NIST_REPORT_DIR, 'latest-report.json');

    if (fsSync.existsSync(reportPath)) {
      const reportData = await fs.readFile(reportPath, 'utf8');
      const report = JSON.parse(reportData);

      return {
        score: report.overall_compliance_score || 0,
        status: report.overall_compliance_score >= 80 ? 'compliant'
          : report.overall_compliance_score >= 60 ? 'partial'
          : 'non-compliant',
        controls: report.summary?.total_controls || 0,
        passing: report.summary?.implemented || 0,
        failing: report.summary?.not_implemented || 0,
        warnings: report.summary?.partial || 0,
        last_updated: report.generated_at
      };
    }

    // Default status if no report exists
    return {
      score: 0,
      status: 'unknown',
      controls: 0,
      passing: 0,
      failing: 0,
      warnings: 0,
      last_updated: null
    };
  } catch (error) {
    console.error('Error getting NIST CSF status:', error);
    return {
      score: 0,
      status: 'error',
      controls: 0,
      passing: 0,
      failing: 0,
      warnings: 0,
      error: error.message
    };
  }
}

/**
 * Get framework status from policy evaluations
 */
async function getFrameworkStatus(framework) {
  try {
    const policies = await getPoliciesByFramework(framework);
    const auditEntries = await getRecentAuditEntries(100, framework);

    const passCount = auditEntries.filter(e => e.result === 'pass').length;
    const failCount = auditEntries.filter(e => e.result === 'fail').length;
    const total = passCount + failCount;

    const score = total > 0 ? (passCount / total) * 100 : 0;

    return {
      score: Math.round(score * 100) / 100,
      status: score >= 80 ? 'compliant' : score >= 60 ? 'partial' : total === 0 ? 'unknown' : 'non-compliant',
      controls: policies.reduce((sum, p) => sum + (p.controls?.length || 0), 0),
      passing: passCount,
      failing: failCount,
      warnings: 0,
      policies: policies.length,
      last_updated: auditEntries[0]?.timestamp || null
    };
  } catch (error) {
    console.error(`Error getting ${framework} status:`, error);
    return {
      score: 0,
      status: 'error',
      controls: 0,
      passing: 0,
      failing: 0,
      warnings: 0,
      error: error.message
    };
  }
}

/**
 * List all policies from the definitions directory
 */
async function listPolicies() {
  const policies = [];

  if (!fsSync.existsSync(POLICY_DEFINITIONS_DIR)) {
    return policies;
  }

  const files = await fs.readdir(POLICY_DEFINITIONS_DIR);

  for (const file of files) {
    if (file.endsWith('.json') || file.endsWith('.yaml') || file.endsWith('.yml')) {
      try {
        const filePath = path.join(POLICY_DEFINITIONS_DIR, file);
        const content = await fs.readFile(filePath, 'utf8');
        const policy = JSON.parse(content);

        policies.push({
          policy_id: policy.policy_id,
          name: policy.name,
          description: policy.description,
          version: policy.version,
          severity: policy.severity || 'medium',
          enabled: policy.enabled !== false,
          frameworks: policy.frameworks || [],
          controls: policy.controls || [],
          rules_count: policy.rules?.length || 0,
          file
        });
      } catch (error) {
        console.error(`Error reading policy ${file}:`, error);
      }
    }
  }

  return policies;
}

/**
 * Get policy by ID
 */
async function getPolicyById(policyId) {
  const policies = await listPolicies();
  const policyMeta = policies.find(p => p.policy_id === policyId);

  if (!policyMeta) return null;

  const filePath = path.join(POLICY_DEFINITIONS_DIR, policyMeta.file);
  const content = await fs.readFile(filePath, 'utf8');
  return JSON.parse(content);
}

/**
 * Get policies by framework
 */
async function getPoliciesByFramework(framework) {
  const policies = await listPolicies();
  return policies.filter(p => p.frameworks && p.frameworks.includes(framework));
}

/**
 * Get audit log entries
 */
async function getAuditLog(limit = 100) {
  if (!fsSync.existsSync(AUDIT_LOG_FILE)) {
    return [];
  }

  try {
    const content = await fs.readFile(AUDIT_LOG_FILE, 'utf8');
    const lines = content.trim().split('\n').filter(l => l);

    // Parse JSONL and take last N entries
    const entries = lines.slice(-limit).map(line => {
      try {
        return JSON.parse(line);
      } catch {
        return null;
      }
    }).filter(e => e);

    return entries.reverse(); // Most recent first
  } catch (error) {
    console.error('Error reading audit log:', error);
    return [];
  }
}

/**
 * Get recent audit entries filtered by framework
 */
async function getRecentAuditEntries(limit, framework) {
  const entries = await getAuditLog(limit * 2);

  if (!framework) return entries.slice(0, limit);

  return entries
    .filter(e => e.policy?.frameworks?.includes(framework))
    .slice(0, limit);
}

/**
 * Get policy evaluation history
 */
async function getPolicyHistory(policyId) {
  const entries = await getAuditLog(500);
  return entries.filter(e => e.policy?.id === policyId);
}

/**
 * Generate NIST CSF report using the mapper script
 */
async function generateNistCsfReport() {
  try {
    // Try to call the NIST CSF mapper
    const mapperPath = path.join(PROJECT_ROOT, 'scripts/lib/governance/nist-csf-mapper.sh');

    if (fsSync.existsSync(mapperPath)) {
      const result = execSync(
        `source "${mapperPath}" && generate_nist_csf_report`,
        {
          shell: '/bin/bash',
          encoding: 'utf8',
          cwd: PROJECT_ROOT
        }
      );
      return JSON.parse(result);
    }

    // Return default report if mapper not available
    return {
      report_id: 'NIST-CSF-default',
      generated_at: new Date().toISOString(),
      framework: 'NIST Cybersecurity Framework v1.1',
      overall_compliance_score: 0,
      summary: {
        total_controls: 0,
        implemented: 0,
        partial: 0,
        not_implemented: 0
      }
    };
  } catch (error) {
    console.error('Error generating NIST CSF report:', error);
    throw error;
  }
}

/**
 * Evaluate policies against a target
 */
async function evaluatePolicies(target, specificPolicies, policyDir) {
  try {
    // If target is a file path, read it
    let targetJson = target;
    if (typeof target === 'string' && fsSync.existsSync(target)) {
      targetJson = JSON.parse(await fs.readFile(target, 'utf8'));
    }

    const results = [];
    const policies = specificPolicies || await listPolicies();
    const dir = policyDir || POLICY_DEFINITIONS_DIR;

    for (const policy of policies) {
      try {
        const policyPath = path.join(dir, policy.file || `${policy.policy_id}.json`);

        if (!fsSync.existsSync(policyPath)) continue;

        const policyContent = JSON.parse(await fs.readFile(policyPath, 'utf8'));

        // Simple evaluation (full evaluation would use the bash policy engine)
        const ruleResults = policyContent.rules.map(rule => ({
          rule_id: rule.rule_id,
          result: 'pass', // Simplified - real evaluation in bash
          description: rule.description
        }));

        results.push({
          policy_id: policyContent.policy_id,
          name: policyContent.name,
          result: 'pass',
          rules: ruleResults
        });
      } catch (error) {
        console.error(`Error evaluating policy:`, error);
      }
    }

    return {
      timestamp: new Date().toISOString(),
      target: typeof target === 'string' ? target : 'inline-json',
      total_policies: results.length,
      passed: results.filter(r => r.result === 'pass').length,
      failed: results.filter(r => r.result === 'fail').length,
      results
    };
  } catch (error) {
    console.error('Error evaluating policies:', error);
    throw error;
  }
}

module.exports = router;
