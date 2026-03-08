/**
 * Security API Routes
 *
 * Provides REST endpoints for the security dashboard:
 * - GET /api/v1/security/portfolio/summary - Aggregated vulnerability data
 * - GET /api/v1/security/repositories - List repositories with security metadata
 * - GET /api/v1/security/repositories/:repoId/vulnerabilities - Vulnerabilities for specific repo
 * - GET /api/v1/security/vulnerabilities - Paginated list of all vulnerabilities
 * - POST /api/v1/security/scan - Trigger security scan via MoE router
 * - GET /api/v1/security/scan-history - Historical scan results
 *
 * @module api-server/routes/security
 */

'use strict';

const express = require('express');
const router = express.Router();
const path = require('path');
const fs = require('fs').promises;
const { execFile } = require('child_process');
const { promisify } = require('util');
const { sanitizeFilename, safeJoin, isPathWithinDirectory } = require('../lib/path-validator');

const execFileAsync = promisify(execFile);

// Paths
const COMMIT_RELAY_HOME = process.env.COMMIT_RELAY_HOME || path.join(__dirname, '../../..');
const COORDINATION_DIR = path.join(COMMIT_RELAY_HOME, 'coordination');
const AGENTS_DIR = path.join(COMMIT_RELAY_HOME, 'agents/workers');
const VULNERABILITY_SUMMARY_PATH = path.join(COORDINATION_DIR, 'metrics/vulnerability-summary.json');
const SCAN_HISTORY_PATH = path.join(COORDINATION_DIR, 'metrics/security-scan-history.jsonl');
const REMEDIATIONS_PATH = path.join(COORDINATION_DIR, 'metrics/security-remediations.jsonl');
const SPAWN_WORKER_SCRIPT = path.join(COMMIT_RELAY_HOME, 'scripts/spawn-worker.sh');
const SECURITY_PR_GENERATOR_SCRIPT = path.join(COMMIT_RELAY_HOME, 'scripts/security-pr-generator.sh');
const EVENTS_PATH = path.join(COORDINATION_DIR, 'events/security-events.jsonl');
const PORTFOLIO_PATH = path.join(COORDINATION_DIR, 'portfolio/repositories.json');
const REPOS_CLONE_DIR = path.join(COMMIT_RELAY_HOME, 'repos');

/**
 * Helper: Read JSON file safely
 * @param {string} filePath - Path to JSON file
 * @returns {Promise<Object|null>} Parsed JSON or null
 */
async function readJsonFile(filePath) {
  try {
    // Validate the file path is within coordination directory
    if (!isPathWithinDirectory(filePath, COORDINATION_DIR)) {
      console.warn(`Attempted path traversal blocked: ${filePath}`);
      return null;
    }

    const content = await fs.readFile(filePath, 'utf-8');
    return JSON.parse(content);
  } catch (error) {
    if (error.code === 'ENOENT') {
      return null;
    }
    throw error;
  }
}

/**
 * Helper: Read JSONL file and return array of entries
 * @param {string} filePath - Path to JSONL file
 * @returns {Promise<Array>} Array of parsed entries
 */
async function readJsonlFile(filePath) {
  try {
    const content = await fs.readFile(filePath, 'utf-8');
    const lines = content.trim().split('\n').filter(line => line);
    return lines.map(line => {
      try {
        return JSON.parse(line);
      } catch {
        return null;
      }
    }).filter(entry => entry !== null);
  } catch (error) {
    if (error.code === 'ENOENT') {
      return [];
    }
    throw error;
  }
}

/**
 * Helper: Get all scan worker directories
 * @returns {Promise<Array<string>>} Array of worker directory paths
 */
async function getScanWorkerDirs() {
  try {
    const entries = await fs.readdir(AGENTS_DIR, { withFileTypes: true });
    return entries
      .filter(entry => entry.isDirectory() && entry.name.startsWith('worker-scan-'))
      .map(entry => path.join(AGENTS_DIR, entry.name));
  } catch (error) {
    if (error.code === 'ENOENT') {
      return [];
    }
    throw error;
  }
}

/**
 * Helper: Generate unique task ID
 * @returns {string} Unique task ID
 */
function generateTaskId() {
  const timestamp = Date.now();
  const random = Math.random().toString(36).substring(2, 10);
  return `security-scan-${timestamp}-${random}`;
}

/**
 * GET /api/v1/security/portfolio/summary
 * Aggregates vulnerability data across all scanned repositories
 */
router.get('/portfolio/summary', async (req, res) => {
  try {
    // Try to read from pre-aggregated summary file
    let summary = await readJsonFile(VULNERABILITY_SUMMARY_PATH);

    if (summary) {
      return res.json({
        success: true,
        data: summary,
        timestamp: new Date().toISOString()
      });
    }

    // Fallback: aggregate from scan worker results
    const workerDirs = await getScanWorkerDirs();
    const aggregated = {
      total_repositories: workerDirs.length,
      repositories_scanned: 0,
      total_vulnerabilities: 0,
      vulnerability_counts: {
        critical: 0,
        high: 0,
        medium: 0,
        low: 0,
        total: 0
      },
      compliance_score_avg: 0,
      last_scan_time: null,
      trend: {
        direction: 'stable',
        value: 0,
        percentage: 0
      },
      scan_coverage_percentage: 0,
      avg_time_to_fix: 0,
      risk_distribution: {
        high: 0,
        medium: 0,
        low: 0
      }
    };

    let complianceScores = [];
    let latestScanTime = null;

    for (const workerDir of workerDirs) {
      const reportPath = path.join(workerDir, 'security-audit-report.json');
      const report = await readJsonFile(reportPath);

      if (report && report.executive_summary) {
        aggregated.repositories_scanned++;

        const exec = report.executive_summary;
        aggregated.vulnerability_counts.critical += exec.critical_vulnerabilities || 0;
        aggregated.vulnerability_counts.high += exec.high_vulnerabilities || 0;
        aggregated.vulnerability_counts.medium += exec.medium_vulnerabilities || 0;
        aggregated.vulnerability_counts.low += exec.low_vulnerabilities || 0;

        if (exec.compliance_score) {
          complianceScores.push(exec.compliance_score);
        }

        // Track risk level
        const riskLevel = (report.risk_level || 'unknown').toLowerCase();
        if (aggregated.risk_distribution[riskLevel] !== undefined) {
          aggregated.risk_distribution[riskLevel]++;
        }

        // Track latest scan time
        if (report.generated_at) {
          const scanTime = new Date(report.generated_at);
          if (!latestScanTime || scanTime > latestScanTime) {
            latestScanTime = scanTime;
          }
        }
      }
    }

    // Calculate totals and averages
    aggregated.vulnerability_counts.total =
      aggregated.vulnerability_counts.critical +
      aggregated.vulnerability_counts.high +
      aggregated.vulnerability_counts.medium +
      aggregated.vulnerability_counts.low;

    aggregated.total_vulnerabilities = aggregated.vulnerability_counts.total;

    // Calculate scan coverage
    if (aggregated.total_repositories > 0) {
      aggregated.scan_coverage_percentage =
        Math.round((aggregated.repositories_scanned / aggregated.total_repositories) * 100);
    }

    if (complianceScores.length > 0) {
      aggregated.compliance_score_avg =
        Math.round(complianceScores.reduce((a, b) => a + b, 0) / complianceScores.length);
    }

    aggregated.last_scan_time = latestScanTime ? latestScanTime.toISOString() : null;

    res.json({
      success: true,
      data: aggregated,
      timestamp: new Date().toISOString()
    });
  } catch (error) {
    console.error('Error getting portfolio summary:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to get portfolio summary',
      message: error.message,
      timestamp: new Date().toISOString()
    });
  }
});

/**
 * GET /api/v1/security/portfolio/repos
 * List all GitHub repositories in the portfolio
 */
router.get('/portfolio/repos', async (req, res) => {
  try {
    let portfolio = await readJsonFile(PORTFOLIO_PATH);
    if (!portfolio) {
      portfolio = { repositories: [], settings: {} };
    }

    res.json({
      success: true,
      data: {
        repositories: portfolio.repositories,
        settings: portfolio.settings,
        total: portfolio.repositories.length
      },
      timestamp: new Date().toISOString()
    });
  } catch (error) {
    console.error('Error getting portfolio repos:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to get portfolio repos',
      message: error.message,
      timestamp: new Date().toISOString()
    });
  }
});

/**
 * POST /api/v1/security/portfolio/repos
 * Add a GitHub repository to the portfolio
 */
router.post('/portfolio/repos', async (req, res) => {
  try {
    const { url, name, branch = 'main', auto_scan = true } = req.body;

    if (!url) {
      return res.status(400).json({
        success: false,
        error: 'Missing required field',
        message: 'url is required',
        timestamp: new Date().toISOString()
      });
    }

    // Parse GitHub URL
    const githubMatch = url.match(/github\.com[\/:]([^\/]+)\/([^\/\.]+)/);
    if (!githubMatch) {
      return res.status(400).json({
        success: false,
        error: 'Invalid URL',
        message: 'URL must be a valid GitHub repository URL',
        timestamp: new Date().toISOString()
      });
    }

    const owner = githubMatch[1];
    const repoName = name || githubMatch[2];

    // Read current portfolio
    let portfolio = await readJsonFile(PORTFOLIO_PATH);
    if (!portfolio) {
      portfolio = { repositories: [], settings: {}, updated_at: null };
    }

    // Check if already exists
    const existingIndex = portfolio.repositories.findIndex(r => r.url === url);
    if (existingIndex >= 0) {
      return res.status(409).json({
        success: false,
        error: 'Repository already exists',
        message: `Repository ${url} is already in the portfolio`,
        timestamp: new Date().toISOString()
      });
    }

    // Create repo entry
    const repoEntry = {
      id: `${owner}-${repoName}-${Date.now()}`,
      url,
      owner,
      name: repoName,
      branch,
      auto_scan,
      added_at: new Date().toISOString(),
      last_scan: null,
      status: 'pending',
      vulnerability_counts: {
        critical: 0,
        high: 0,
        medium: 0,
        low: 0,
        total: 0
      }
    };

    portfolio.repositories.push(repoEntry);
    portfolio.updated_at = new Date().toISOString();

    // Save portfolio
    await fs.writeFile(PORTFOLIO_PATH, JSON.stringify(portfolio, null, 2));

    // Optionally trigger initial scan
    if (auto_scan && portfolio.settings?.scan_on_add !== false) {
      const taskId = generateTaskId();

      try {
        // Ensure repos directory exists
        await fs.mkdir(REPOS_CLONE_DIR, { recursive: true });

        // Clone the repository
        const clonePath = path.join(REPOS_CLONE_DIR, repoEntry.id);
        await execFileAsync('git', ['clone', '--depth', '1', '--branch', branch, url, clonePath], {
          timeout: 60000
        });

        // Spawn scan worker
        await execFileAsync(SPAWN_WORKER_SCRIPT, [
          '--type', 'scan-worker',
          '--task-id', taskId,
          '--master', 'security-master',
          '--priority', 'normal'
        ], {
          env: {
            ...process.env,
            GOVERNANCE_BYPASS: 'true',
            SCAN_TARGET: clonePath,
            REPO_ID: repoEntry.id
          },
          timeout: 30000
        });

        repoEntry.status = 'scanning';
        repoEntry.current_task_id = taskId;
        await fs.writeFile(PORTFOLIO_PATH, JSON.stringify(portfolio, null, 2));
      } catch (err) {
        console.warn('Could not initiate scan:', err.message);
        repoEntry.status = 'clone_failed';
        repoEntry.error = err.message;
        await fs.writeFile(PORTFOLIO_PATH, JSON.stringify(portfolio, null, 2));
      }
    }

    res.status(201).json({
      success: true,
      data: repoEntry,
      timestamp: new Date().toISOString()
    });
  } catch (error) {
    console.error('Error adding repo to portfolio:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to add repository',
      message: error.message,
      timestamp: new Date().toISOString()
    });
  }
});

/**
 * DELETE /api/v1/security/portfolio/repos/:id
 * Remove a repository from the portfolio
 */
router.delete('/portfolio/repos/:id', async (req, res) => {
  try {
    const { id } = req.params;

    let portfolio = await readJsonFile(PORTFOLIO_PATH);
    if (!portfolio) {
      return res.status(404).json({
        success: false,
        error: 'Repository not found',
        timestamp: new Date().toISOString()
      });
    }

    const index = portfolio.repositories.findIndex(r => r.id === id);
    if (index < 0) {
      return res.status(404).json({
        success: false,
        error: 'Repository not found',
        message: `No repository with id ${id}`,
        timestamp: new Date().toISOString()
      });
    }

    const removed = portfolio.repositories.splice(index, 1)[0];
    portfolio.updated_at = new Date().toISOString();

    await fs.writeFile(PORTFOLIO_PATH, JSON.stringify(portfolio, null, 2));

    // Clean up cloned repo
    const clonePath = path.join(REPOS_CLONE_DIR, id);
    try {
      await fs.rm(clonePath, { recursive: true, force: true });
    } catch (err) {
      // Ignore if doesn't exist
    }

    res.json({
      success: true,
      data: { removed },
      timestamp: new Date().toISOString()
    });
  } catch (error) {
    console.error('Error removing repo from portfolio:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to remove repository',
      message: error.message,
      timestamp: new Date().toISOString()
    });
  }
});

/**
 * POST /api/v1/security/portfolio/repos/:id/scan
 * Trigger a scan for a specific repository
 */
router.post('/portfolio/repos/:id/scan', async (req, res) => {
  try {
    const { id } = req.params;

    let portfolio = await readJsonFile(PORTFOLIO_PATH);
    if (!portfolio) {
      return res.status(404).json({
        success: false,
        error: 'Repository not found',
        timestamp: new Date().toISOString()
      });
    }

    const repo = portfolio.repositories.find(r => r.id === id);
    if (!repo) {
      return res.status(404).json({
        success: false,
        error: 'Repository not found',
        message: `No repository with id ${id}`,
        timestamp: new Date().toISOString()
      });
    }

    const taskId = generateTaskId();
    const clonePath = path.join(REPOS_CLONE_DIR, id);

    // Update or clone repo
    try {
      await fs.access(clonePath);
      // Pull latest
      await execFileAsync('git', ['-C', clonePath, 'pull', '--ff-only'], { timeout: 60000 });
    } catch {
      // Clone fresh
      await fs.mkdir(REPOS_CLONE_DIR, { recursive: true });
      await execFileAsync('git', ['clone', '--depth', '1', '--branch', repo.branch, repo.url, clonePath], {
        timeout: 60000
      });
    }

    // Spawn scan worker
    await execFileAsync(SPAWN_WORKER_SCRIPT, [
      '--type', 'scan-worker',
      '--task-id', taskId,
      '--master', 'security-master',
      '--priority', 'high'
    ], {
      env: {
        ...process.env,
        GOVERNANCE_BYPASS: 'true',
        SCAN_TARGET: clonePath,
        REPO_ID: id
      },
      timeout: 30000
    });

    repo.status = 'scanning';
    repo.current_task_id = taskId;
    portfolio.updated_at = new Date().toISOString();
    await fs.writeFile(PORTFOLIO_PATH, JSON.stringify(portfolio, null, 2));

    res.status(202).json({
      success: true,
      data: {
        task_id: taskId,
        repository: repo.name,
        status: 'scanning'
      },
      timestamp: new Date().toISOString()
    });
  } catch (error) {
    console.error('Error scanning repository:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to scan repository',
      message: error.message,
      timestamp: new Date().toISOString()
    });
  }
});

/**
 * GET /api/v1/security/repositories
 * Lists all repositories with security metadata
 */
router.get('/repositories', async (req, res) => {
  try {
    const workerDirs = await getScanWorkerDirs();
    const repositories = [];

    for (const workerDir of workerDirs) {
      const reportPath = path.join(workerDir, 'security-audit-report.json');
      const report = await readJsonFile(reportPath);

      if (report) {
        const workerId = path.basename(workerDir);
        const exec = report.executive_summary || {};

        repositories.push({
          repository_id: workerId,
          worker_id: workerId,
          task_id: report.task_id,
          audit_scope: report.audit_scope,
          overall_status: report.overall_status,
          risk_level: report.risk_level,
          vulnerability_counts: {
            critical: exec.critical_vulnerabilities || 0,
            high: exec.high_vulnerabilities || 0,
            medium: exec.medium_vulnerabilities || 0,
            low: exec.low_vulnerabilities || 0,
            informational: exec.informational || 0,
            total: (exec.critical_vulnerabilities || 0) +
                   (exec.high_vulnerabilities || 0) +
                   (exec.medium_vulnerabilities || 0) +
                   (exec.low_vulnerabilities || 0)
          },
          compliance_score: exec.compliance_score || null,
          files_scanned: exec.total_files_scanned || 0,
          last_scan_date: report.generated_at,
          scan_metadata: report.scan_metadata
        });
      }
    }

    // Sort by last scan date, most recent first
    repositories.sort((a, b) => {
      if (!a.last_scan_date) return 1;
      if (!b.last_scan_date) return -1;
      return new Date(b.last_scan_date) - new Date(a.last_scan_date);
    });

    res.json({
      success: true,
      data: {
        repositories,
        total: repositories.length
      },
      timestamp: new Date().toISOString()
    });
  } catch (error) {
    console.error('Error listing repositories:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to list repositories',
      message: error.message,
      timestamp: new Date().toISOString()
    });
  }
});

/**
 * GET /api/v1/security/repositories/:repoId/vulnerabilities
 * Returns vulnerabilities for specific repository
 */
router.get('/repositories/:repoId/vulnerabilities', async (req, res) => {
  try {
    const { repoId } = req.params;
    const { severity, status } = req.query;

    // Find the worker directory
    const workerDir = path.join(AGENTS_DIR, repoId);
    const reportPath = path.join(workerDir, 'security-audit-report.json');

    const report = await readJsonFile(reportPath);

    if (!report) {
      return res.status(404).json({
        success: false,
        error: 'Repository not found',
        message: `No security report found for repository '${repoId}'`,
        timestamp: new Date().toISOString()
      });
    }

    let vulnerabilities = report.code_security_findings || [];

    // Apply severity filter
    if (severity) {
      const severities = severity.toUpperCase().split(',');
      vulnerabilities = vulnerabilities.filter(v =>
        severities.includes(v.severity.toUpperCase())
      );
    }

    // Apply status filter (if findings have status)
    if (status) {
      const statuses = status.toLowerCase().split(',');
      vulnerabilities = vulnerabilities.filter(v =>
        statuses.includes((v.status || 'open').toLowerCase())
      );
    }

    // Group by severity for summary
    const bySeverity = {
      critical: vulnerabilities.filter(v => v.severity === 'CRITICAL').length,
      high: vulnerabilities.filter(v => v.severity === 'HIGH').length,
      medium: vulnerabilities.filter(v => v.severity === 'MEDIUM').length,
      low: vulnerabilities.filter(v => v.severity === 'LOW').length
    };

    res.json({
      success: true,
      data: {
        repository_id: repoId,
        vulnerabilities,
        summary: {
          total: vulnerabilities.length,
          by_severity: bySeverity
        },
        recommendations: report.recommendations,
        compliance_checks: report.compliance_checks,
        positive_findings: report.positive_findings
      },
      timestamp: new Date().toISOString()
    });
  } catch (error) {
    console.error('Error getting repository vulnerabilities:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to get repository vulnerabilities',
      message: error.message,
      timestamp: new Date().toISOString()
    });
  }
});

/**
 * GET /api/v1/security/vulnerabilities
 * Paginated list of all vulnerabilities across all repositories
 */
router.get('/vulnerabilities', async (req, res) => {
  try {
    const {
      severity,
      status,
      cve,
      repository,
      limit = 50,
      offset = 0
    } = req.query;

    const limitNum = parseInt(limit);
    const offsetNum = parseInt(offset);

    const workerDirs = await getScanWorkerDirs();
    let allVulnerabilities = [];

    for (const workerDir of workerDirs) {
      const workerId = path.basename(workerDir);

      // Filter by repository if specified
      if (repository && workerId !== repository) {
        continue;
      }

      const reportPath = path.join(workerDir, 'security-audit-report.json');
      const report = await readJsonFile(reportPath);

      if (report && report.code_security_findings) {
        const findings = report.code_security_findings.map(finding => ({
          ...finding,
          repository_id: workerId,
          task_id: report.task_id,
          scan_date: report.generated_at
        }));

        allVulnerabilities.push(...findings);
      }
    }

    // Apply filters
    if (severity) {
      const severities = severity.toUpperCase().split(',');
      allVulnerabilities = allVulnerabilities.filter(v =>
        severities.includes(v.severity.toUpperCase())
      );
    }

    if (status) {
      const statuses = status.toLowerCase().split(',');
      allVulnerabilities = allVulnerabilities.filter(v =>
        statuses.includes((v.status || 'open').toLowerCase())
      );
    }

    if (cve) {
      const cvePattern = cve.toUpperCase();
      allVulnerabilities = allVulnerabilities.filter(v =>
        v.cwe_id && v.cwe_id.toUpperCase().includes(cvePattern)
      );
    }

    // Sort by severity (critical first) then by scan date
    const severityOrder = { CRITICAL: 0, HIGH: 1, MEDIUM: 2, LOW: 3, INFORMATIONAL: 4 };
    allVulnerabilities.sort((a, b) => {
      const severityDiff = (severityOrder[a.severity] || 5) - (severityOrder[b.severity] || 5);
      if (severityDiff !== 0) return severityDiff;
      return new Date(b.scan_date || 0) - new Date(a.scan_date || 0);
    });

    // Apply pagination
    const total = allVulnerabilities.length;
    const paginated = allVulnerabilities.slice(offsetNum, offsetNum + limitNum);

    // Summary statistics
    const summary = {
      total,
      by_severity: {
        critical: allVulnerabilities.filter(v => v.severity === 'CRITICAL').length,
        high: allVulnerabilities.filter(v => v.severity === 'HIGH').length,
        medium: allVulnerabilities.filter(v => v.severity === 'MEDIUM').length,
        low: allVulnerabilities.filter(v => v.severity === 'LOW').length
      },
      by_category: {}
    };

    // Group by category
    for (const vuln of allVulnerabilities) {
      const category = vuln.category || 'Unknown';
      summary.by_category[category] = (summary.by_category[category] || 0) + 1;
    }

    res.json({
      success: true,
      data: {
        vulnerabilities: paginated,
        pagination: {
          total,
          limit: limitNum,
          offset: offsetNum,
          has_more: offsetNum + limitNum < total
        },
        summary
      },
      timestamp: new Date().toISOString()
    });
  } catch (error) {
    console.error('Error getting vulnerabilities:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to get vulnerabilities',
      message: error.message,
      timestamp: new Date().toISOString()
    });
  }
});

/**
 * POST /api/v1/security/scan
 * Triggers security scan via MoE router
 */
router.post('/scan', async (req, res) => {
  try {
    const { repository_url, scan_type = 'full' } = req.body;

    // Validate request
    if (!repository_url) {
      return res.status(400).json({
        success: false,
        error: 'Missing required field',
        message: 'repository_url is required',
        timestamp: new Date().toISOString()
      });
    }

    const validScanTypes = ['full', 'dependencies', 'secrets'];
    if (!validScanTypes.includes(scan_type)) {
      return res.status(400).json({
        success: false,
        error: 'Invalid scan type',
        message: `scan_type must be one of: ${validScanTypes.join(', ')}`,
        timestamp: new Date().toISOString()
      });
    }

    // Generate task ID
    const taskId = generateTaskId();

    // Prepare worker specification
    const workerSpec = {
      task_id: taskId,
      worker_type: 'scan',
      task_type: 'security_scan',
      parameters: {
        repository_url,
        scan_type,
        patterns_to_check: [
          'SQL injection',
          'XSS',
          'Command injection',
          'Hardcoded secrets',
          'Insecure cryptography',
          'Missing authentication',
          'Information disclosure'
        ]
      },
      priority: scan_type === 'full' ? 'high' : 'normal',
      requested_at: new Date().toISOString()
    };

    // Write worker spec to coordination directory
    const specPath = path.join(COORDINATION_DIR, 'pending-tasks', `${taskId}.json`);

    // Ensure pending-tasks directory exists
    const pendingDir = path.join(COORDINATION_DIR, 'pending-tasks');
    try {
      await fs.mkdir(pendingDir, { recursive: true });
    } catch (err) {
      // Directory may already exist
    }

    await fs.writeFile(specPath, JSON.stringify(workerSpec, null, 2));

    // Attempt to spawn worker using spawn-worker.sh
    let spawnResult = null;
    try {
      const { stdout, stderr } = await execFileAsync(
        SPAWN_WORKER_SCRIPT,
        ['scan', taskId],
        {
          cwd: COMMIT_RELAY_HOME,
          timeout: 30000,
          env: {
            ...process.env,
            COMMIT_RELAY_HOME
          }
        }
      );

      spawnResult = {
        stdout: stdout.trim(),
        stderr: stderr.trim(),
        spawned: true
      };
    } catch (spawnError) {
      // Log error but don't fail - task is still queued
      console.warn('Worker spawn warning:', spawnError.message);
      spawnResult = {
        spawned: false,
        error: spawnError.message,
        note: 'Task queued but worker spawn failed - will be picked up by orchestrator'
      };
    }

    // Log scan initiation to history
    const historyEntry = {
      task_id: taskId,
      repository_url,
      scan_type,
      status: 'initiated',
      initiated_at: new Date().toISOString(),
      spawn_result: spawnResult
    };

    try {
      await fs.appendFile(
        SCAN_HISTORY_PATH,
        JSON.stringify(historyEntry) + '\n'
      );
    } catch (err) {
      console.warn('Could not write to scan history:', err.message);
    }

    res.status(202).json({
      success: true,
      data: {
        task_id: taskId,
        status: 'initiated',
        scan_type,
        repository_url,
        message: 'Security scan initiated',
        spawn_result: spawnResult
      },
      timestamp: new Date().toISOString()
    });
  } catch (error) {
    console.error('Error initiating security scan:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to initiate security scan',
      message: error.message,
      timestamp: new Date().toISOString()
    });
  }
});

/**
 * POST /api/v1/security/scan/all
 * Triggers security scan for all repositories (currently scans commit-relay)
 */
router.post('/scan/all', async (req, res) => {
  try {
    // Generate task ID
    const taskId = generateTaskId();

    // For now, scan the commit-relay repository itself
    const repositoryPath = COMMIT_RELAY_HOME;

    // Spawn a scan worker
    try {
      await execFileAsync(SPAWN_WORKER_SCRIPT, [
        '--type', 'scan-worker',
        '--task-id', taskId,
        '--master', 'security-master',
        '--priority', 'high'
      ], {
        env: {
          ...process.env,
          GOVERNANCE_BYPASS: 'true',
          SCAN_TARGET: repositoryPath
        },
        timeout: 30000
      });
    } catch (err) {
      console.warn('Could not spawn scan worker:', err.message);
    }

    // Log scan initiation to history
    const historyEntry = {
      task_id: taskId,
      scan_type: 'full',
      repository_url: repositoryPath,
      status: 'initiated',
      initiated_at: new Date().toISOString()
    };

    try {
      await fs.appendFile(
        SCAN_HISTORY_PATH,
        JSON.stringify(historyEntry) + '\n'
      );
    } catch (err) {
      console.warn('Could not write to scan history:', err.message);
    }

    res.status(202).json({
      success: true,
      data: {
        task_id: taskId,
        status: 'initiated',
        message: 'Security scan initiated for all repositories'
      },
      timestamp: new Date().toISOString()
    });
  } catch (error) {
    console.error('Error initiating scan all:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to initiate scan',
      message: error.message,
      timestamp: new Date().toISOString()
    });
  }
});

/**
 * GET /api/v1/security/scan-history
 * Historical scan results
 */
router.get('/scan-history', async (req, res) => {
  try {
    const {
      repository,
      scan_type,
      since,
      limit = 50
    } = req.query;

    const limitNum = parseInt(limit);

    let entries = await readJsonlFile(SCAN_HISTORY_PATH);

    // Apply filters
    if (repository) {
      entries = entries.filter(e =>
        e.repository_url && e.repository_url.includes(repository)
      );
    }

    if (scan_type) {
      entries = entries.filter(e => e.scan_type === scan_type);
    }

    if (since) {
      const sinceDate = new Date(since);
      entries = entries.filter(e => {
        const entryDate = new Date(e.initiated_at || e.timestamp);
        return entryDate >= sinceDate;
      });
    }

    // Sort by date (most recent first) and limit
    entries.sort((a, b) => {
      const dateA = new Date(a.initiated_at || a.timestamp || 0);
      const dateB = new Date(b.initiated_at || b.timestamp || 0);
      return dateB - dateA;
    });

    entries = entries.slice(0, limitNum);

    // Summary statistics
    const now = Date.now();
    const last24h = entries.filter(e => {
      const entryTime = new Date(e.initiated_at || e.timestamp || 0).getTime();
      return (now - entryTime) < 24 * 60 * 60 * 1000;
    }).length;

    const byScanType = {};
    const byStatus = {};
    for (const entry of entries) {
      const type = entry.scan_type || 'unknown';
      const status = entry.status || 'unknown';
      byScanType[type] = (byScanType[type] || 0) + 1;
      byStatus[status] = (byStatus[status] || 0) + 1;
    }

    res.json({
      success: true,
      data: {
        history: entries,
        summary: {
          total: entries.length,
          last_24h: last24h,
          by_scan_type: byScanType,
          by_status: byStatus
        }
      },
      timestamp: new Date().toISOString()
    });
  } catch (error) {
    console.error('Error getting scan history:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to get scan history',
      message: error.message,
      timestamp: new Date().toISOString()
    });
  }
});

/**
 * GET /api/v1/security/compliance
 * Get compliance status across all repositories
 */
router.get('/compliance', async (req, res) => {
  try {
    const workerDirs = await getScanWorkerDirs();
    const complianceData = {
      owasp_top_10: {
        passed: 0,
        partial: 0,
        failed: 0,
        not_checked: 0
      },
      overall_compliance_rate: 0,
      repositories_checked: 0,
      checks_by_category: {}
    };

    let totalChecks = 0;
    let passedChecks = 0;

    for (const workerDir of workerDirs) {
      const reportPath = path.join(workerDir, 'security-audit-report.json');
      const report = await readJsonFile(reportPath);

      if (report && report.compliance_checks && report.compliance_checks.owasp_top_10_2021) {
        complianceData.repositories_checked++;

        const owaspChecks = report.compliance_checks.owasp_top_10_2021;

        for (const [checkName, checkData] of Object.entries(owaspChecks)) {
          const status = (checkData.status || 'not_checked').toUpperCase();

          // Initialize category if needed
          if (!complianceData.checks_by_category[checkName]) {
            complianceData.checks_by_category[checkName] = {
              passed: 0,
              partial: 0,
              failed: 0,
              total: 0
            };
          }

          complianceData.checks_by_category[checkName].total++;
          totalChecks++;

          if (status === 'PASSED') {
            complianceData.owasp_top_10.passed++;
            complianceData.checks_by_category[checkName].passed++;
            passedChecks++;
          } else if (status === 'PARTIAL') {
            complianceData.owasp_top_10.partial++;
            complianceData.checks_by_category[checkName].partial++;
            passedChecks += 0.5; // Partial credit
          } else if (status === 'FAILED') {
            complianceData.owasp_top_10.failed++;
            complianceData.checks_by_category[checkName].failed++;
          } else {
            complianceData.owasp_top_10.not_checked++;
          }
        }
      }
    }

    if (totalChecks > 0) {
      complianceData.overall_compliance_rate = Math.round((passedChecks / totalChecks) * 100);
    }

    res.json({
      success: true,
      data: complianceData,
      timestamp: new Date().toISOString()
    });
  } catch (error) {
    console.error('Error getting compliance data:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to get compliance data',
      message: error.message,
      timestamp: new Date().toISOString()
    });
  }
});

/**
 * GET /api/v1/security/trends
 * Get security trends over time
 */
router.get('/trends', async (req, res) => {
  try {
    const { days = 30 } = req.query;
    const daysNum = parseInt(days);

    const history = await readJsonlFile(SCAN_HISTORY_PATH);
    const cutoffDate = new Date();
    cutoffDate.setDate(cutoffDate.getDate() - daysNum);

    // Filter to requested time range
    const recentHistory = history.filter(entry => {
      const entryDate = new Date(entry.initiated_at || entry.timestamp || 0);
      return entryDate >= cutoffDate;
    });

    // Group by day
    const dailyStats = {};
    for (const entry of recentHistory) {
      const date = new Date(entry.initiated_at || entry.timestamp);
      const dayKey = date.toISOString().split('T')[0];

      if (!dailyStats[dayKey]) {
        dailyStats[dayKey] = {
          date: dayKey,
          scans: 0,
          vulnerabilities_found: 0,
          critical: 0,
          high: 0,
          medium: 0,
          low: 0
        };
      }

      dailyStats[dayKey].scans++;

      // If entry has vulnerability counts
      if (entry.vulnerabilities) {
        dailyStats[dayKey].vulnerabilities_found += entry.vulnerabilities.total || 0;
        dailyStats[dayKey].critical += entry.vulnerabilities.critical || 0;
        dailyStats[dayKey].high += entry.vulnerabilities.high || 0;
        dailyStats[dayKey].medium += entry.vulnerabilities.medium || 0;
        dailyStats[dayKey].low += entry.vulnerabilities.low || 0;
      }
    }

    // Convert to sorted array
    const trends = Object.values(dailyStats).sort((a, b) =>
      a.date.localeCompare(b.date)
    );

    res.json({
      success: true,
      data: {
        trends,
        period_days: daysNum,
        total_scans: recentHistory.length
      },
      timestamp: new Date().toISOString()
    });
  } catch (error) {
    console.error('Error getting security trends:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to get security trends',
      message: error.message,
      timestamp: new Date().toISOString()
    });
  }
});

/**
 * Helper: Write JSONL entry to file
 * @param {string} filePath - Path to JSONL file
 * @param {Object} entry - Entry to append
 */
async function writeJsonlEntry(filePath, entry) {
  const dir = path.dirname(filePath);
  await fs.mkdir(dir, { recursive: true });
  await fs.appendFile(filePath, JSON.stringify(entry) + '\n');
}

/**
 * Helper: Update entry in JSONL file by ID
 * @param {string} filePath - Path to JSONL file
 * @param {string} id - ID of entry to update
 * @param {Object} updates - Fields to update
 * @returns {Promise<Object|null>} Updated entry or null if not found
 */
async function updateJsonlEntry(filePath, id, updates) {
  const entries = await readJsonlFile(filePath);
  let updatedEntry = null;

  const updatedEntries = entries.map(entry => {
    if (entry.id === id) {
      updatedEntry = { ...entry, ...updates };
      return updatedEntry;
    }
    return entry;
  });

  if (updatedEntry) {
    const content = updatedEntries.map(e => JSON.stringify(e)).join('\n') + '\n';
    await fs.writeFile(filePath, content);
  }

  return updatedEntry;
}

/**
 * Helper: Log security event
 * @param {string} eventType - Type of event
 * @param {Object} data - Event data
 */
async function logSecurityEvent(eventType, data) {
  const event = {
    id: `evt-${Date.now()}-${Math.random().toString(36).substring(2, 8)}`,
    type: eventType,
    timestamp: new Date().toISOString(),
    ...data
  };

  try {
    await writeJsonlEntry(EVENTS_PATH, event);
  } catch (error) {
    console.warn('Could not log security event:', error.message);
  }
}

/**
 * GET /api/v1/security/remediations
 * List remediation records with filtering and pagination
 */
router.get('/remediations', async (req, res) => {
  try {
    const {
      status,
      repository,
      limit = 50,
      offset = 0
    } = req.query;

    const limitNum = parseInt(limit);
    const offsetNum = parseInt(offset);

    let remediations = await readJsonlFile(REMEDIATIONS_PATH);

    // Apply filters
    if (status) {
      const statuses = status.toLowerCase().split(',');
      remediations = remediations.filter(r =>
        statuses.includes((r.status || 'pending').toLowerCase())
      );
    }

    if (repository) {
      remediations = remediations.filter(r =>
        r.repository && r.repository.toLowerCase().includes(repository.toLowerCase())
      );
    }

    // Sort by created_at (most recent first)
    remediations.sort((a, b) => {
      const dateA = new Date(a.created_at || 0);
      const dateB = new Date(b.created_at || 0);
      return dateB - dateA;
    });

    // Apply pagination
    const total = remediations.length;
    const paginated = remediations.slice(offsetNum, offsetNum + limitNum);

    // Summary statistics
    const summary = {
      total,
      by_status: {
        pending: remediations.filter(r => r.status === 'pending').length,
        approved: remediations.filter(r => r.status === 'approved').length,
        rejected: remediations.filter(r => r.status === 'rejected').length,
        completed: remediations.filter(r => r.status === 'completed').length
      },
      by_fix_type: {}
    };

    // Group by fix type
    for (const rem of remediations) {
      const fixType = rem.fix_type || 'unknown';
      summary.by_fix_type[fixType] = (summary.by_fix_type[fixType] || 0) + 1;
    }

    res.json({
      success: true,
      data: {
        remediations: paginated,
        pagination: {
          total,
          limit: limitNum,
          offset: offsetNum,
          has_more: offsetNum + limitNum < total
        },
        summary
      },
      timestamp: new Date().toISOString()
    });
  } catch (error) {
    console.error('Error getting remediations:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to get remediations',
      message: error.message,
      timestamp: new Date().toISOString()
    });
  }
});

/**
 * GET /api/v1/security/remediations/:id
 * Get single remediation with full details
 */
router.get('/remediations/:id', async (req, res) => {
  try {
    const { id } = req.params;

    const remediations = await readJsonlFile(REMEDIATIONS_PATH);
    const remediation = remediations.find(r => r.id === id);

    if (!remediation) {
      return res.status(404).json({
        success: false,
        error: 'Remediation not found',
        message: `No remediation found with ID '${id}'`,
        timestamp: new Date().toISOString()
      });
    }

    res.json({
      success: true,
      data: remediation,
      timestamp: new Date().toISOString()
    });
  } catch (error) {
    console.error('Error getting remediation:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to get remediation',
      message: error.message,
      timestamp: new Date().toISOString()
    });
  }
});

/**
 * POST /api/v1/security/remediations/:id/approve
 * Approve and trigger remediation fix
 */
router.post('/remediations/:id/approve', async (req, res) => {
  try {
    const { id } = req.params;

    const remediations = await readJsonlFile(REMEDIATIONS_PATH);
    const remediation = remediations.find(r => r.id === id);

    if (!remediation) {
      return res.status(404).json({
        success: false,
        error: 'Remediation not found',
        message: `No remediation found with ID '${id}'`,
        timestamp: new Date().toISOString()
      });
    }

    if (remediation.status === 'approved' || remediation.status === 'completed') {
      return res.status(400).json({
        success: false,
        error: 'Invalid state transition',
        message: `Remediation is already ${remediation.status}`,
        timestamp: new Date().toISOString()
      });
    }

    // Update status to approved
    const updatedRemediation = await updateJsonlEntry(REMEDIATIONS_PATH, id, {
      status: 'approved',
      approved_at: new Date().toISOString(),
      approved_by: req.body.approved_by || 'api'
    });

    // Log approval event
    await logSecurityEvent('remediation_approved', {
      remediation_id: id,
      vulnerability_id: remediation.vulnerability_id,
      fix_type: remediation.fix_type,
      repository: remediation.repository
    });

    // Trigger the fix using security-pr-generator.sh or auto-fix
    let fixResult = null;
    try {
      const { stdout, stderr } = await execFileAsync(
        SECURITY_PR_GENERATOR_SCRIPT,
        [id],
        {
          cwd: COMMIT_RELAY_HOME,
          timeout: 120000,
          env: {
            ...process.env,
            COMMIT_RELAY_HOME,
            REMEDIATION_ID: id
          }
        }
      );

      fixResult = {
        success: true,
        stdout: stdout.trim(),
        stderr: stderr.trim()
      };

      // Update status to completed if fix succeeded
      await updateJsonlEntry(REMEDIATIONS_PATH, id, {
        status: 'completed',
        completed_at: new Date().toISOString(),
        fix_result: fixResult
      });

      await logSecurityEvent('remediation_completed', {
        remediation_id: id,
        fix_result: fixResult
      });
    } catch (fixError) {
      console.warn('Fix execution warning:', fixError.message);
      fixResult = {
        success: false,
        error: fixError.message,
        note: 'Remediation approved but fix execution failed'
      };

      // Update with error
      await updateJsonlEntry(REMEDIATIONS_PATH, id, {
        fix_result: fixResult,
        fix_error: fixError.message
      });

      await logSecurityEvent('remediation_fix_failed', {
        remediation_id: id,
        error: fixError.message
      });
    }

    res.json({
      success: true,
      data: {
        id,
        status: fixResult && fixResult.success ? 'completed' : 'approved',
        approved_at: updatedRemediation.approved_at,
        fix_result: fixResult,
        message: fixResult && fixResult.success
          ? 'Remediation approved and fix applied successfully'
          : 'Remediation approved but fix execution needs attention'
      },
      timestamp: new Date().toISOString()
    });
  } catch (error) {
    console.error('Error approving remediation:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to approve remediation',
      message: error.message,
      timestamp: new Date().toISOString()
    });
  }
});

/**
 * POST /api/v1/security/remediations/:id/reject
 * Reject remediation with reason
 */
router.post('/remediations/:id/reject', async (req, res) => {
  try {
    const { id } = req.params;
    const { reason } = req.body;

    if (!reason) {
      return res.status(400).json({
        success: false,
        error: 'Missing required field',
        message: 'reason is required for rejection',
        timestamp: new Date().toISOString()
      });
    }

    const remediations = await readJsonlFile(REMEDIATIONS_PATH);
    const remediation = remediations.find(r => r.id === id);

    if (!remediation) {
      return res.status(404).json({
        success: false,
        error: 'Remediation not found',
        message: `No remediation found with ID '${id}'`,
        timestamp: new Date().toISOString()
      });
    }

    if (remediation.status === 'rejected') {
      return res.status(400).json({
        success: false,
        error: 'Invalid state transition',
        message: 'Remediation is already rejected',
        timestamp: new Date().toISOString()
      });
    }

    // Update status to rejected
    const updatedRemediation = await updateJsonlEntry(REMEDIATIONS_PATH, id, {
      status: 'rejected',
      rejected_at: new Date().toISOString(),
      rejection_reason: reason,
      rejected_by: req.body.rejected_by || 'api'
    });

    // Log rejection event
    await logSecurityEvent('remediation_rejected', {
      remediation_id: id,
      vulnerability_id: remediation.vulnerability_id,
      reason,
      repository: remediation.repository
    });

    res.json({
      success: true,
      data: {
        id,
        status: 'rejected',
        rejected_at: updatedRemediation.rejected_at,
        rejection_reason: reason,
        message: 'Remediation rejected successfully'
      },
      timestamp: new Date().toISOString()
    });
  } catch (error) {
    console.error('Error rejecting remediation:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to reject remediation',
      message: error.message,
      timestamp: new Date().toISOString()
    });
  }
});

/**
 * GET /api/v1/security/remediations/:id/pr
 * Get PR details for a remediation
 */
router.get('/remediations/:id/pr', async (req, res) => {
  try {
    const { id } = req.params;

    const remediations = await readJsonlFile(REMEDIATIONS_PATH);
    const remediation = remediations.find(r => r.id === id);

    if (!remediation) {
      return res.status(404).json({
        success: false,
        error: 'Remediation not found',
        message: `No remediation found with ID '${id}'`,
        timestamp: new Date().toISOString()
      });
    }

    if (!remediation.pr_url) {
      return res.status(404).json({
        success: false,
        error: 'No PR found',
        message: `No pull request has been created for remediation '${id}'`,
        timestamp: new Date().toISOString()
      });
    }

    // Extract owner/repo/pr_number from PR URL
    const prUrlMatch = remediation.pr_url.match(/github\.com\/([^/]+)\/([^/]+)\/pull\/(\d+)/);

    let prDetails = {
      url: remediation.pr_url,
      status: remediation.pr_status || 'unknown',
      created_at: remediation.pr_created_at,
      merged_at: remediation.pr_merged_at
    };

    // Try to fetch additional PR details from GitHub if possible
    if (prUrlMatch) {
      const [, owner, repo, prNumber] = prUrlMatch;

      try {
        const { stdout } = await execFileAsync(
          'gh',
          ['pr', 'view', prNumber, '--repo', `${owner}/${repo}`, '--json',
           'state,title,body,reviews,statusCheckRollup,mergeable,additions,deletions,changedFiles'],
          {
            cwd: COMMIT_RELAY_HOME,
            timeout: 30000
          }
        );

        const ghData = JSON.parse(stdout);
        prDetails = {
          ...prDetails,
          title: ghData.title,
          body: ghData.body,
          state: ghData.state,
          mergeable: ghData.mergeable,
          additions: ghData.additions,
          deletions: ghData.deletions,
          changed_files: ghData.changedFiles,
          reviews: ghData.reviews,
          checks: ghData.statusCheckRollup
        };
      } catch (ghError) {
        console.warn('Could not fetch GitHub PR details:', ghError.message);
        prDetails.github_fetch_error = ghError.message;
      }
    }

    res.json({
      success: true,
      data: {
        remediation_id: id,
        pr: prDetails
      },
      timestamp: new Date().toISOString()
    });
  } catch (error) {
    console.error('Error getting PR details:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to get PR details',
      message: error.message,
      timestamp: new Date().toISOString()
    });
  }
});

/**
 * POST /api/v1/security/remediations/bulk-approve
 * Approve multiple remediations
 */
router.post('/remediations/bulk-approve', async (req, res) => {
  try {
    const { ids } = req.body;

    if (!ids || !Array.isArray(ids) || ids.length === 0) {
      return res.status(400).json({
        success: false,
        error: 'Missing required field',
        message: 'ids array is required',
        timestamp: new Date().toISOString()
      });
    }

    const remediations = await readJsonlFile(REMEDIATIONS_PATH);
    const results = [];

    for (const id of ids) {
      const remediation = remediations.find(r => r.id === id);

      if (!remediation) {
        results.push({
          id,
          success: false,
          error: 'Remediation not found'
        });
        continue;
      }

      if (remediation.status === 'approved' || remediation.status === 'completed') {
        results.push({
          id,
          success: false,
          error: `Remediation is already ${remediation.status}`
        });
        continue;
      }

      try {
        // Update status to approved
        await updateJsonlEntry(REMEDIATIONS_PATH, id, {
          status: 'approved',
          approved_at: new Date().toISOString(),
          approved_by: req.body.approved_by || 'api-bulk'
        });

        // Log approval event
        await logSecurityEvent('remediation_approved', {
          remediation_id: id,
          vulnerability_id: remediation.vulnerability_id,
          fix_type: remediation.fix_type,
          repository: remediation.repository,
          bulk_operation: true
        });

        results.push({
          id,
          success: true,
          status: 'approved'
        });
      } catch (updateError) {
        results.push({
          id,
          success: false,
          error: updateError.message
        });
      }
    }

    const successCount = results.filter(r => r.success).length;
    const failureCount = results.filter(r => !r.success).length;

    res.json({
      success: true,
      data: {
        results,
        summary: {
          total: ids.length,
          succeeded: successCount,
          failed: failureCount
        },
        message: `Approved ${successCount} of ${ids.length} remediations`
      },
      timestamp: new Date().toISOString()
    });
  } catch (error) {
    console.error('Error in bulk approve:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to bulk approve remediations',
      message: error.message,
      timestamp: new Date().toISOString()
    });
  }
});

/**
 * POST /api/v1/security/remediations/bulk-reject
 * Reject multiple remediations
 */
router.post('/remediations/bulk-reject', async (req, res) => {
  try {
    const { ids, reason } = req.body;

    if (!ids || !Array.isArray(ids) || ids.length === 0) {
      return res.status(400).json({
        success: false,
        error: 'Missing required field',
        message: 'ids array is required',
        timestamp: new Date().toISOString()
      });
    }

    if (!reason) {
      return res.status(400).json({
        success: false,
        error: 'Missing required field',
        message: 'reason is required for bulk rejection',
        timestamp: new Date().toISOString()
      });
    }

    const remediations = await readJsonlFile(REMEDIATIONS_PATH);
    const results = [];

    for (const id of ids) {
      const remediation = remediations.find(r => r.id === id);

      if (!remediation) {
        results.push({
          id,
          success: false,
          error: 'Remediation not found'
        });
        continue;
      }

      if (remediation.status === 'rejected') {
        results.push({
          id,
          success: false,
          error: 'Remediation is already rejected'
        });
        continue;
      }

      try {
        // Update status to rejected
        await updateJsonlEntry(REMEDIATIONS_PATH, id, {
          status: 'rejected',
          rejected_at: new Date().toISOString(),
          rejection_reason: reason,
          rejected_by: req.body.rejected_by || 'api-bulk'
        });

        // Log rejection event
        await logSecurityEvent('remediation_rejected', {
          remediation_id: id,
          vulnerability_id: remediation.vulnerability_id,
          reason,
          repository: remediation.repository,
          bulk_operation: true
        });

        results.push({
          id,
          success: true,
          status: 'rejected'
        });
      } catch (updateError) {
        results.push({
          id,
          success: false,
          error: updateError.message
        });
      }
    }

    const successCount = results.filter(r => r.success).length;
    const failureCount = results.filter(r => !r.success).length;

    res.json({
      success: true,
      data: {
        results,
        summary: {
          total: ids.length,
          succeeded: successCount,
          failed: failureCount
        },
        message: `Rejected ${successCount} of ${ids.length} remediations`
      },
      timestamp: new Date().toISOString()
    });
  } catch (error) {
    console.error('Error in bulk reject:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to bulk reject remediations',
      message: error.message,
      timestamp: new Date().toISOString()
    });
  }
});

module.exports = router;
