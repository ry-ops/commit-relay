#!/usr/bin/env node
// lib/governance/quality-validator.js
// Data Quality Validation and Monitoring
// Part of Phase 6: Governance Upgrade
//
// Responsibilities:
// - Validate data structure and integrity
// - Detect schema violations
// - Monitor data quality metrics
// - Generate quality reports

const fs = require('fs').promises;
const path = require('path');
const crypto = require('crypto');

class QualityValidator {
  constructor() {
    this.qualityReportsPath = 'coordination/governance/quality-reports.jsonl';
    
    // Expected schemas for key data assets
    this.schemas = {
      'task-queue': {
        required_fields: ['task_id', 'description', 'status', 'priority', 'created_at'],
        valid_statuses: ['queued', 'routed', 'in_progress', 'completed', 'failed', 'cancelled'],
        valid_priorities: ['critical', 'high', 'medium', 'low']
      },
      'worker-spec': {
        required_fields: ['worker_id', 'worker_type', 'status', 'created_at', 'task_id'],
        valid_statuses: ['spawned', 'idle', 'running', 'completed', 'failed', 'zombie']
      },
      'token-budget': {
        required_fields: ['total', 'available', 'allocated', 'reserved'],
        validation: (data) => {
          return data.total === (data.available + data.allocated + data.reserved);
        }
      }
    };
  }

  /**
   * Initialize quality validator
   */
  async initialize() {
    try {
      await fs.mkdir(path.dirname(this.qualityReportsPath), { recursive: true });
      console.log('Quality Validator initialized');
      return true;
    } catch (error) {
      console.error('Failed to initialize Quality Validator:', error.message);
      return false;
    }
  }

  /**
   * Validate JSON file structure
   */
  async validateFile(filePath, schemaType = null) {
    try {
      const content = await fs.readFile(filePath, 'utf8');
      let data;

      try {
        data = JSON.parse(content);
      } catch (parseError) {
        return {
          file_path: filePath,
          valid: false,
          issues: [{
            type: 'parse_error',
            severity: 'critical',
            message: 'Invalid JSON syntax',
            details: parseError.message
          }]
        };
      }

      const issues = [];

      // Detect schema type if not provided
      if (!schemaType) {
        schemaType = this._detectSchemaType(filePath);
      }

      // Apply schema validation if available
      if (schemaType && this.schemas[schemaType]) {
        const schemaIssues = this._validateSchema(data, this.schemas[schemaType], schemaType);
        issues.push(...schemaIssues);
      }

      // General quality checks
      const generalIssues = this._performGeneralChecks(data, filePath);
      issues.push(...generalIssues);

      const result = {
        validation_id: crypto.randomUUID(),
        file_path: filePath,
        validated_at: new Date().toISOString(),
        schema_type: schemaType,
        valid: issues.filter(i => i.severity === 'critical' || i.severity === 'high').length === 0,
        issues: issues,
        quality_score: this._calculateQualityScore(issues)
      };

      // Log validation result
      await this._logQualityReport(result);

      return result;
    } catch (error) {
      return {
        file_path: filePath,
        valid: false,
        issues: [{
          type: 'validation_error',
          severity: 'critical',
          message: 'Failed to validate file',
          details: error.message
        }]
      };
    }
  }

  /**
   * Validate JSONL file (line-delimited JSON)
   */
  async validateJSONL(filePath) {
    try {
      const content = await fs.readFile(filePath, 'utf8');
      const lines = content.trim().split('\n');

      const issues = [];
      let validLines = 0;

      for (let i = 0; i < lines.length; i++) {
        const lineNum = i + 1;

        if (!lines[i].trim()) {
          continue; // Skip empty lines
        }

        try {
          JSON.parse(lines[i]);
          validLines++;
        } catch (parseError) {
          issues.push({
            type: 'parse_error',
            severity: 'high',
            message: `Invalid JSON on line ${lineNum}`,
            details: parseError.message,
            line: lineNum
          });
        }
      }

      const result = {
        validation_id: crypto.randomUUID(),
        file_path: filePath,
        validated_at: new Date().toISOString(),
        format: 'jsonl',
        total_lines: lines.filter(l => l.trim()).length,
        valid_lines: validLines,
        invalid_lines: lines.filter(l => l.trim()).length - validLines,
        valid: issues.filter(i => i.severity === 'critical' || i.severity === 'high').length === 0,
        issues: issues
      };

      await this._logQualityReport(result);

      return result;
    } catch (error) {
      return {
        file_path: filePath,
        valid: false,
        issues: [{
          type: 'validation_error',
          severity: 'critical',
          message: 'Failed to validate JSONL file',
          details: error.message
        }]
      };
    }
  }

  /**
   * Perform comprehensive quality audit
   */
  async auditDirectory(dirPath) {
    const results = {
      audit_id: crypto.randomUUID(),
      audited_at: new Date().toISOString(),
      directory: dirPath,
      files_audited: 0,
      files_passed: 0,
      files_failed: 0,
      total_issues: 0,
      critical_issues: 0,
      high_issues: 0,
      medium_issues: 0,
      low_issues: 0,
      average_quality_score: 0,
      file_results: []
    };

    async function auditRecursive(dir) {
      const entries = await fs.readdir(dir, { withFileTypes: true });

      for (const entry of entries) {
        const fullPath = path.join(dir, entry.name);

        if (entry.isDirectory()) {
          if (entry.name !== 'node_modules' && entry.name !== '.git') {
            await auditRecursive(fullPath);
          }
        } else if (entry.isFile()) {
          const ext = path.extname(entry.name);

          let validationResult;
          if (ext === '.json') {
            validationResult = await this.validateFile(fullPath);
          } else if (ext === '.jsonl') {
            validationResult = await this.validateJSONL(fullPath);
          } else {
            continue; // Skip non-JSON files
          }

          results.files_audited++;
          results.file_results.push(validationResult);

          if (validationResult.valid) {
            results.files_passed++;
          } else {
            results.files_failed++;
          }

          // Count issues by severity
          for (const issue of validationResult.issues || []) {
            results.total_issues++;
            
            if (issue.severity === 'critical') results.critical_issues++;
            else if (issue.severity === 'high') results.high_issues++;
            else if (issue.severity === 'medium') results.medium_issues++;
            else if (issue.severity === 'low') results.low_issues++;
          }
        }
      }
    }

    await auditRecursive(dirPath);

    // Calculate average quality score
    if (results.files_audited > 0) {
      const totalScore = results.file_results.reduce((sum, r) => sum + (r.quality_score || 0), 0);
      results.average_quality_score = Math.round(totalScore / results.files_audited);
    }

    return results;
  }

  /**
   * Detect schema type from file path
   */
  _detectSchemaType(filePath) {
    const basename = path.basename(filePath, path.extname(filePath));

    if (basename === 'task-queue') return 'task-queue';
    if (basename === 'token-budget') return 'token-budget';
    if (basename.startsWith('worker-')) return 'worker-spec';

    return null;
  }

  /**
   * Validate data against schema
   */
  _validateSchema(data, schema, schemaType) {
    const issues = [];

    // Check required fields
    if (schema.required_fields) {
      for (const field of schema.required_fields) {
        if (schemaType === 'task-queue' && Array.isArray(data.tasks)) {
          // For task queue, check tasks array
          for (let i = 0; i < data.tasks.length; i++) {
            if (!(field in data.tasks[i])) {
              issues.push({
                type: 'missing_field',
                severity: 'high',
                message: `Missing required field: ${field}`,
                location: `tasks[${i}]`,
                field: field
              });
            }
          }
        } else if (!(field in data)) {
          issues.push({
            type: 'missing_field',
            severity: 'high',
            message: `Missing required field: ${field}`,
            field: field
          });
        }
      }
    }

    // Check valid enum values
    if (schema.valid_statuses && data.status) {
      if (!schema.valid_statuses.includes(data.status)) {
        issues.push({
          type: 'invalid_value',
          severity: 'medium',
          message: `Invalid status: ${data.status}`,
          field: 'status',
          expected: schema.valid_statuses
        });
      }
    }

    if (schema.valid_priorities && data.priority) {
      if (!schema.valid_priorities.includes(data.priority)) {
        issues.push({
          type: 'invalid_value',
          severity: 'medium',
          message: `Invalid priority: ${data.priority}`,
          field: 'priority',
          expected: schema.valid_priorities
        });
      }
    }

    // Custom validation function
    if (schema.validation && !schema.validation(data)) {
      issues.push({
        type: 'validation_failed',
        severity: 'high',
        message: 'Custom validation failed',
        details: 'Data integrity check failed'
      });
    }

    return issues;
  }

  /**
   * Perform general quality checks
   */
  _performGeneralChecks(data, filePath) {
    const issues = [];

    // Check for extremely large files
    const jsonString = JSON.stringify(data);
    if (jsonString.length > 10 * 1024 * 1024) { // 10MB
      issues.push({
        type: 'size_warning',
        severity: 'low',
        message: 'File size exceeds 10MB',
        details: `Size: ${Math.round(jsonString.length / 1024 / 1024)}MB`
      });
    }

    // Check for potential data quality issues
    if (Array.isArray(data.tasks)) {
      // Check for duplicate task IDs
      const taskIds = data.tasks.map(t => t.task_id);
      const duplicates = taskIds.filter((id, index) => taskIds.indexOf(id) !== index);
      
      if (duplicates.length > 0) {
        issues.push({
          type: 'duplicate_data',
          severity: 'high',
          message: 'Duplicate task IDs detected',
          details: duplicates.join(', ')
        });
      }
    }

    // Check timestamp validity
    const timestampFields = ['created_at', 'updated_at', 'completed_at'];
    for (const field of timestampFields) {
      if (data[field]) {
        const timestamp = new Date(data[field]);
        if (isNaN(timestamp.getTime())) {
          issues.push({
            type: 'invalid_timestamp',
            severity: 'medium',
            message: `Invalid timestamp in field: ${field}`,
            field: field
          });
        }
      }
    }

    return issues;
  }

  /**
   * Calculate quality score (0-100)
   */
  _calculateQualityScore(issues) {
    let score = 100;

    for (const issue of issues) {
      if (issue.severity === 'critical') score -= 25;
      else if (issue.severity === 'high') score -= 15;
      else if (issue.severity === 'medium') score -= 5;
      else if (issue.severity === 'low') score -= 2;
    }

    return Math.max(0, score);
  }

  /**
   * Log quality report
   */
  async _logQualityReport(report) {
    const logEntry = JSON.stringify(report) + '\n';
    await fs.appendFile(this.qualityReportsPath, logEntry);
  }
}

// CLI interface
if (require.main === module) {
  const action = process.argv[2];
  const qualityValidator = new QualityValidator();

  (async () => {
    await qualityValidator.initialize();

    switch (action) {
      case 'validate':
        const filePath = process.argv[3];
        const result = await qualityValidator.validateFile(filePath);
        console.log('\nValidation Result:');
        console.log(JSON.stringify(result, null, 2));
        break;

      case 'audit':
        const dirPath = process.argv[3] || 'coordination';
        const auditResult = await qualityValidator.auditDirectory(dirPath);
        console.log('\nQuality Audit:');
        console.log(JSON.stringify(auditResult, null, 2));
        break;

      default:
        console.log('Usage: node quality-validator.js <action>');
        console.log('Actions:');
        console.log('  validate <path>  - Validate single file');
        console.log('  audit [path]     - Audit directory (default: coordination)');
        break;
    }
  })();
}

module.exports = QualityValidator;
