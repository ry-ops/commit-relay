/**
 * Tool Filter Module
 *
 * Pre-expansion tool selection system that filters available tools based on
 * worker type assignments. Implements semantic clustering approach from GitHub
 * research showing 400ms latency improvement with tool reduction.
 *
 * Features:
 * - Worker-specific tool filtering
 * - Essential vs optional cluster handling
 * - Tool access validation
 * - Performance metrics tracking
 */

const fs = require('fs').promises;
const path = require('path');

class ToolFilter {
  constructor(options = {}) {
    this.configPath = options.configPath || path.join(
      __dirname,
      'tool-clusters.json'
    );
    this.config = null;
    this.silent = options.silent || false;
    this.metrics = {
      total_filters: 0,
      avg_tools_before: 0,
      avg_tools_after: 0,
      reduction_percent: 0
    };
  }

  /**
   * Initialize tool filter by loading configuration
   */
  async initialize() {
    try {
      const data = await fs.readFile(this.configPath, 'utf8');
      this.config = JSON.parse(data);
      if (!this.silent) {
        console.log('[ToolFilter] Configuration loaded');
        console.log(`[ToolFilter] ${Object.keys(this.config.clusters).length} clusters defined`);
        console.log(`[ToolFilter] ${Object.keys(this.config.worker_tool_assignments).length} worker types configured`);
      }
    } catch (error) {
      throw new Error(`Failed to load tool filter config: ${error.message}`);
    }
  }

  /**
   * Get filtered tool set for a worker type
   *
   * @param {string} workerType - Worker type (e.g., 'implementation-worker')
   * @param {Array<string>} allTools - All available tools
   * @returns {Object} - Filtered tools with metadata
   */
  async getToolsForWorker(workerType, allTools = null) {
    if (!this.config) {
      throw new Error('ToolFilter not initialized. Call initialize() first.');
    }

    // Get worker assignment
    const assignment = this.config.worker_tool_assignments[workerType];
    if (!assignment) {
      console.warn(`[ToolFilter] No assignment found for ${workerType}, using all tools`);
      return {
        worker_type: workerType,
        essential_tools: allTools || [],
        optional_tools: [],
        total_tools: allTools ? allTools.length : 0,
        filtered: false
      };
    }

    // Collect essential tools
    const essentialTools = new Set();
    for (const clusterName of assignment.essential_clusters || []) {
      const cluster = this.config.clusters[clusterName];
      if (cluster) {
        cluster.tools.forEach(tool => essentialTools.add(tool));
      }
    }

    // Collect optional tools
    const optionalTools = new Set();
    for (const clusterName of assignment.optional_clusters || []) {
      const cluster = this.config.clusters[clusterName];
      if (cluster) {
        cluster.tools.forEach(tool => {
          if (!essentialTools.has(tool)) {
            optionalTools.add(tool);
          }
        });
      }
    }

    // Update metrics
    this.metrics.total_filters++;
    const toolsBefore = allTools ? allTools.length : 19; // Default before count
    const toolsAfter = essentialTools.size + optionalTools.size;

    this.metrics.avg_tools_before =
      ((this.metrics.avg_tools_before * (this.metrics.total_filters - 1)) + toolsBefore) /
      this.metrics.total_filters;
    this.metrics.avg_tools_after =
      ((this.metrics.avg_tools_after * (this.metrics.total_filters - 1)) + toolsAfter) /
      this.metrics.total_filters;
    this.metrics.reduction_percent =
      ((this.metrics.avg_tools_before - this.metrics.avg_tools_after) /
       this.metrics.avg_tools_before * 100).toFixed(1);

    return {
      worker_type: workerType,
      essential_tools: Array.from(essentialTools),
      optional_tools: Array.from(optionalTools),
      total_tools: essentialTools.size + optionalTools.size,
      essential_clusters: assignment.essential_clusters,
      optional_clusters: assignment.optional_clusters,
      rationale: assignment.rationale,
      filtered: true
    };
  }

  /**
   * Check if a tool is allowed for a worker type
   *
   * @param {string} workerType - Worker type
   * @param {string} toolName - Tool name to check
   * @returns {Promise<Object>} - Access result
   */
  async checkToolAccess(workerType, toolName) {
    const toolSet = await this.getToolsForWorker(workerType);

    const isEssential = toolSet.essential_tools.includes(toolName);
    const isOptional = toolSet.optional_tools.includes(toolName);
    const allowed = isEssential || isOptional;

    return {
      allowed,
      access_level: isEssential ? 'essential' : isOptional ? 'optional' : 'restricted',
      worker_type: workerType,
      tool_name: toolName
    };
  }

  /**
   * Get tool cluster information
   *
   * @param {string} clusterName - Cluster name
   * @returns {Object|null} - Cluster info or null
   */
  getCluster(clusterName) {
    if (!this.config) return null;
    return this.config.clusters[clusterName] || null;
  }

  /**
   * Get all clusters for a tool
   *
   * @param {string} toolName - Tool name
   * @returns {Array<string>} - Cluster names containing this tool
   */
  getClustersForTool(toolName) {
    if (!this.config) return [];

    const clusters = [];
    for (const [clusterName, cluster] of Object.entries(this.config.clusters)) {
      if (cluster.tools.includes(toolName)) {
        clusters.push(clusterName);
      }
    }
    return clusters;
  }

  /**
   * Get performance metrics
   *
   * @returns {Object} - Metrics
   */
  getMetrics() {
    return {
      ...this.metrics,
      avg_tools_before: this.metrics.avg_tools_before.toFixed(1),
      avg_tools_after: this.metrics.avg_tools_after.toFixed(1)
    };
  }

  /**
   * Generate tool assignment summary for all workers
   *
   * @returns {Promise<Object>} - Summary report
   */
  async generateSummary() {
    if (!this.config) {
      throw new Error('ToolFilter not initialized');
    }

    const summary = {
      total_clusters: Object.keys(this.config.clusters).length,
      total_worker_types: Object.keys(this.config.worker_tool_assignments).length,
      worker_assignments: {}
    };

    for (const workerType of Object.keys(this.config.worker_tool_assignments)) {
      const toolSet = await this.getToolsForWorker(workerType);
      summary.worker_assignments[workerType] = {
        total_tools: toolSet.total_tools,
        essential_tools: toolSet.essential_tools.length,
        optional_tools: toolSet.optional_tools.length,
        essential_clusters: toolSet.essential_clusters,
        optional_clusters: toolSet.optional_clusters,
        rationale: toolSet.rationale
      };
    }

    summary.optimization_metrics = this.config.optimization_metrics;
    summary.current_metrics = this.getMetrics();

    return summary;
  }

  /**
   * Validate tool cluster configuration
   *
   * @returns {Object} - Validation result
   */
  validateConfig() {
    const errors = [];
    const warnings = [];

    if (!this.config) {
      errors.push('Configuration not loaded');
      return { valid: false, errors, warnings };
    }

    // Check all clusters exist
    for (const [workerType, assignment] of Object.entries(this.config.worker_tool_assignments)) {
      for (const clusterName of [...(assignment.essential_clusters || []), ...(assignment.optional_clusters || [])]) {
        if (!this.config.clusters[clusterName]) {
          errors.push(`Worker ${workerType} references undefined cluster: ${clusterName}`);
        }
      }
    }

    // Check for empty tool sets
    for (const [workerType, assignment] of Object.entries(this.config.worker_tool_assignments)) {
      if (!assignment.essential_clusters || assignment.essential_clusters.length === 0) {
        warnings.push(`Worker ${workerType} has no essential clusters defined`);
      }
    }

    // Check for duplicate tools in clusters
    const seenTools = new Map();
    for (const [clusterName, cluster] of Object.entries(this.config.clusters)) {
      for (const tool of cluster.tools) {
        if (seenTools.has(tool)) {
          warnings.push(`Tool ${tool} appears in multiple clusters: ${seenTools.get(tool)}, ${clusterName}`);
        }
        seenTools.set(tool, clusterName);
      }
    }

    return {
      valid: errors.length === 0,
      errors,
      warnings
    };
  }
}

module.exports = { ToolFilter };
