#!/usr/bin/env node
// lib/governance/pii-scanner.js
// PII Detection and Data Sensitivity Scanner
// Part of Phase 6: Governance Upgrade
//
// Responsibilities:
// - Scan data assets for PII
// - Classify data sensitivity
// - Generate remediation recommendations
// - Track PII exposure risks

const fs = require('fs').promises;
const path = require('path');
const crypto = require('crypto');

class PIIScanner {
  constructor() {
    this.scanResultsPath = 'coordination/governance/pii-scan-results.jsonl';
    
    // PII detection patterns
    this.patterns = {
      email: /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b/g,
      ssn: /\b\d{3}-\d{2}-\d{4}\b/g,
      phone: /\b\d{3}[-.]?\d{3}[-.]?\d{4}\b/g,
      credit_card: /\b\d{4}[-\s]?\d{4}[-\s]?\d{4}[-\s]?\d{4}\b/g,
      ip_address: /\b(?:\d{1,3}\.){3}\d{1,3}\b/g,
      api_key: /(?:api[_-]?key|apikey|api[_-]?secret)[\"']?\s*[:=]\s*[\"']?([a-zA-Z0-9_-]{20,})/gi,
      aws_key: /AKIA[0-9A-Z]{16}/g,
      github_token: /gh[pousr]_[A-Za-z0-9_]{36,}/g,
      slack_token: /xox[baprs]-[0-9a-zA-Z-]{10,}/g,
      jwt: /eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/g
    };
  }

  /**
   * Initialize PII scanner
   */
  async initialize() {
    try {
      await fs.mkdir(path.dirname(this.scanResultsPath), { recursive: true });
      console.log('PII Scanner initialized');
      return true;
    } catch (error) {
      console.error('Failed to initialize PII Scanner:', error.message);
      return false;
    }
  }

  /**
   * Scan a file for PII
   */
  async scanFile(filePath) {
    try {
      const content = await fs.readFile(filePath, 'utf8');
      const findings = [];

      // Check each PII pattern
      for (const [type, pattern] of Object.entries(this.patterns)) {
        const matches = content.matchAll(pattern);

        for (const match of matches) {
          findings.push({
            type: type,
            value: this._maskValue(match[0]),
            position: match.index,
            severity: this._getSeverity(type)
          });
        }
      }

      const result = {
        scan_id: crypto.randomUUID(),
        file_path: filePath,
        scanned_at: new Date().toISOString(),
        pii_found: findings.length > 0,
        findings: findings,
        risk_level: this._calculateRiskLevel(findings),
        recommendations: this._generateRecommendations(findings)
      };

      // Log scan result
      await this._logScanResult(result);

      return result;
    } catch (error) {
      console.error(`Failed to scan file \${filePath}:`, error.message);
      return {
        scan_id: crypto.randomUUID(),
        file_path: filePath,
        scanned_at: new Date().toISOString(),
        pii_found: false,
        error: error.message
      };
    }
  }

  /**
   * Scan directory recursively
   */
  async scanDirectory(dirPath, options = {}) {
    const results = [];
    const extensions = options.extensions || ['.json', '.jsonl', '.log', '.txt', '.md'];

    async function scanRecursive(dir) {
      const entries = await fs.readdir(dir, { withFileTypes: true });

      for (const entry of entries) {
        const fullPath = path.join(dir, entry.name);

        if (entry.isDirectory()) {
          // Skip certain directories
          if (entry.name === 'node_modules' || entry.name === '.git') {
            continue;
          }
          await scanRecursive(fullPath);
        } else if (entry.isFile()) {
          // Check file extension
          const ext = path.extname(entry.name);
          if (extensions.includes(ext)) {
            const result = await this.scanFile(fullPath);
            results.push(result);
          }
        }
      }
    }

    await scanRecursive(dirPath);

    const summary = {
      scan_id: crypto.randomUUID(),
      scanned_at: new Date().toISOString(),
      directory: dirPath,
      files_scanned: results.length,
      files_with_pii: results.filter(r => r.pii_found).length,
      total_findings: results.reduce((sum, r) => sum + (r.findings?.length || 0), 0),
      overall_risk: this._calculateOverallRisk(results),
      results: results
    };

    return summary;
  }

  /**
   * Classify data sensitivity
   */
  async classifyData(content, metadata = {}) {
    const classification = {
      sensitivity_level: 'public',
      reasons: [],
      compliance_tags: []
    };

    // Check for PII
    let hasPII = false;
    for (const [type, pattern] of Object.entries(this.patterns)) {
      if (pattern.test(content)) {
        hasPII = true;
        classification.reasons.push(`Contains \${type}`);
      }
    }

    if (hasPII) {
      classification.sensitivity_level = 'confidential';
      classification.compliance_tags.push('pii-present');
    }

    // Check for security-sensitive content
    const securityKeywords = ['password', 'secret', 'private_key', 'credentials', 'token'];
    for (const keyword of securityKeywords) {
      if (content.toLowerCase().includes(keyword)) {
        classification.sensitivity_level = 'confidential';
        classification.reasons.push(`Contains security keyword: \${keyword}`);
        classification.compliance_tags.push('security-sensitive');
        break;
      }
    }

    // Check for financial data
    const financialKeywords = ['credit', 'bank', 'account', 'payment', 'billing'];
    for (const keyword of financialKeywords) {
      if (content.toLowerCase().includes(keyword)) {
        classification.sensitivity_level = 'confidential';
        classification.reasons.push(`Contains financial keyword: \${keyword}`);
        classification.compliance_tags.push('financial-data');
        break;
      }
    }

    // If no sensitive data found
    if (classification.sensitivity_level === 'public' && metadata.namespace) {
      // Internal by default for system namespaces
      const internalNamespaces = ['coordinator', 'development', 'inventory', 'cicd', 'dashboard', 'self-healing'];
      if (internalNamespaces.includes(metadata.namespace)) {
        classification.sensitivity_level = 'internal';
        classification.reasons.push('Internal system data');
      }
    }

    return classification;
  }

  /**
   * Generate remediation report
   */
  async generateRemediationReport() {
    const scanResults = await this._loadScanResults();

    const report = {
      report_id: crypto.randomUUID(),
      generated_at: new Date().toISOString(),
      total_scans: scanResults.length,
      files_with_pii: scanResults.filter(r => r.pii_found).length,
      findings_by_type: {},
      high_risk_files: [],
      remediation_actions: []
    };

    // Aggregate findings
    for (const scan of scanResults) {
      if (!scan.findings) continue;

      for (const finding of scan.findings) {
        report.findings_by_type[finding.type] = 
          (report.findings_by_type[finding.type] || 0) + 1;
      }

      // Identify high-risk files
      if (scan.risk_level === 'high' || scan.risk_level === 'critical') {
        report.high_risk_files.push({
          file: scan.file_path,
          risk_level: scan.risk_level,
          findings: scan.findings.length
        });
      }
    }

    // Generate remediation actions
    for (const [type, count] of Object.entries(report.findings_by_type)) {
      report.remediation_actions.push({
        finding_type: type,
        occurrences: count,
        action: this._getRemediationAction(type),
        priority: this._getSeverity(type)
      });
    }

    return report;
  }

  /**
   * Mask sensitive value for logging
   */
  _maskValue(value) {
    if (value.length <= 4) {
      return '***';
    }
    return value.substring(0, 2) + '***' + value.substring(value.length - 2);
  }

  /**
   * Get severity for PII type
   */
  _getSeverity(type) {
    const severities = {
      ssn: 'critical',
      credit_card: 'critical',
      email: 'high',
      phone: 'high',
      api_key: 'critical',
      aws_key: 'critical',
      github_token: 'critical',
      slack_token: 'high',
      jwt: 'high',
      ip_address: 'medium'
    };

    return severities[type] || 'medium';
  }

  /**
   * Calculate risk level based on findings
   */
  _calculateRiskLevel(findings) {
    if (findings.length === 0) {
      return 'none';
    }

    const hasCritical = findings.some(f => f.severity === 'critical');
    const hasHigh = findings.some(f => f.severity === 'high');

    if (hasCritical || findings.length > 10) {
      return 'critical';
    } else if (hasHigh || findings.length > 5) {
      return 'high';
    } else if (findings.length > 2) {
      return 'medium';
    } else {
      return 'low';
    }
  }

  /**
   * Calculate overall risk from multiple scan results
   */
  _calculateOverallRisk(results) {
    const riskScores = {
      none: 0,
      low: 1,
      medium: 2,
      high: 3,
      critical: 4
    };

    let maxScore = 0;
    for (const result of results) {
      const score = riskScores[result.risk_level] || 0;
      maxScore = Math.max(maxScore, score);
    }

    const riskLevels = Object.keys(riskScores);
    return riskLevels.find(level => riskScores[level] === maxScore) || 'none';
  }

  /**
   * Generate recommendations based on findings
   */
  _generateRecommendations(findings) {
    const recommendations = [];

    const findingTypes = new Set(findings.map(f => f.type));

    if (findingTypes.has('api_key') || findingTypes.has('aws_key') || findingTypes.has('github_token')) {
      recommendations.push('Immediately rotate exposed credentials');
      recommendations.push('Move secrets to secure vault (e.g., AWS Secrets Manager)');
    }

    if (findingTypes.has('email') || findingTypes.has('phone')) {
      recommendations.push('Redact or hash PII in logs and data files');
      recommendations.push('Implement data masking for sensitive fields');
    }

    if (findingTypes.has('credit_card') || findingTypes.has('ssn')) {
      recommendations.push('Remove sensitive financial/identity data immediately');
      recommendations.push('Review data retention policies');
      recommendations.push('Ensure compliance with PCI-DSS / privacy regulations');
    }

    if (recommendations.length === 0) {
      recommendations.push('Monitor for future PII exposure');
    }

    return recommendations;
  }

  /**
   * Get remediation action for finding type
   */
  _getRemediationAction(type) {
    const actions = {
      email: 'Hash or redact email addresses',
      ssn: 'Remove SSN immediately - critical compliance violation',
      phone: 'Mask phone numbers in logs',
      credit_card: 'Remove credit card data - PCI-DSS violation',
      ip_address: 'Review IP address logging necessity',
      api_key: 'Rotate API key immediately',
      aws_key: 'Rotate AWS credentials immediately',
      github_token: 'Revoke and regenerate GitHub token',
      slack_token: 'Revoke Slack token',
      jwt: 'Review JWT exposure and rotation policy'
    };

    return actions[type] || 'Review and remediate as necessary';
  }

  /**
   * Log scan result to JSONL file
   */
  async _logScanResult(result) {
    const logEntry = JSON.stringify(result) + '\n';
    await fs.appendFile(this.scanResultsPath, logEntry);
  }

  /**
   * Load all scan results
   */
  async _loadScanResults() {
    try {
      const content = await fs.readFile(this.scanResultsPath, 'utf8');
      return content.trim().split('\n').map(line => JSON.parse(line));
    } catch (error) {
      return [];
    }
  }
}

// CLI interface
if (require.main === module) {
  const action = process.argv[2];
  const piiScanner = new PIIScanner();

  (async () => {
    await piiScanner.initialize();

    switch (action) {
      case 'scan-file':
        const filePath = process.argv[3];
        const fileResult = await piiScanner.scanFile(filePath);
        console.log('\nPII Scan Result:');
        console.log(JSON.stringify(fileResult, null, 2));
        break;

      case 'scan-dir':
        const dirPath = process.argv[3] || 'coordination';
        const dirResult = await piiScanner.scanDirectory(dirPath);
        console.log('\nDirectory Scan Summary:');
        console.log(JSON.stringify(dirResult, null, 2));
        break;

      case 'report':
        const report = await piiScanner.generateRemediationReport();
        console.log('\nPII Remediation Report:');
        console.log(JSON.stringify(report, null, 2));
        break;

      default:
        console.log('Usage: node pii-scanner.js <action>');
        console.log('Actions:');
        console.log('  scan-file <path>  - Scan single file for PII');
        console.log('  scan-dir [path]   - Scan directory (default: coordination)');
        console.log('  report            - Generate remediation report');
        break;
    }
  })();
}

module.exports = PIIScanner;
