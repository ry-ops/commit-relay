/**
 * A/B Testing Framework for Routing Comparison
 *
 * Compares semantic routing vs keyword routing performance to validate
 * the 94.5% vs 87.5% coverage improvement from GitHub research.
 *
 * Features:
 * - Side-by-side routing comparison
 * - Agreement rate tracking
 * - Confidence distribution analysis
 * - Performance metrics collection
 */

const { SemanticRouter } = require('./semantic-router');
const fs = require('fs').promises;
const path = require('path');

class ABTestRouter {
  constructor(options = {}) {
    this.semanticRouter = new SemanticRouter(options);

    // A/B test configuration
    this.testEnabled = options.testEnabled !== false;
    this.sampleRate = options.sampleRate || 0.1; // Test 10% of requests by default

    // Test results
    this.testResults = [];
    this.resultsPath = path.join(
      process.cwd(),
      'coordination',
      'embeddings',
      'ab-test-results.jsonl'
    );

    // Metrics
    this.metrics = {
      total_tests: 0,
      agreements: 0,
      disagreements: 0,
      semantic_higher_confidence: 0,
      keyword_higher_confidence: 0,
      avg_semantic_confidence: 0,
      avg_keyword_confidence: 0
    };
  }

  /**
   * Initialize A/B test router
   */
  async initialize() {
    await this.semanticRouter.initialize();

    // Create results directory
    const dir = path.dirname(this.resultsPath);
    await fs.mkdir(dir, { recursive: true });

    console.log('[AB Test] A/B testing framework initialized');
    console.log(`[AB Test] Test enabled: ${this.testEnabled}`);
    console.log(`[AB Test] Sample rate: ${this.sampleRate * 100}%`);
  }

  /**
   * Route task with A/B testing
   *
   * @param {Object} task - Task object
   * @returns {Promise<Object>} - Routing result with A/B test data
   */
  async route(task) {
    // Always use semantic routing for actual result
    const semanticResult = await this.semanticRouter.route(task);

    // Run A/B test on sample of requests
    if (this.testEnabled && Math.random() < this.sampleRate) {
      await this.runABTest(task, semanticResult);
    }

    return semanticResult;
  }

  /**
   * Run A/B test comparing semantic and keyword routing
   *
   * @private
   * @param {Object} task - Task object
   * @param {Object} semanticResult - Result from semantic routing
   */
  async runABTest(task, semanticResult) {
    try {
      // Get keyword routing result
      const keywordResult = this.semanticRouter._keywordFallback(
        task.description || task.task_description || task.title || ''
      );

      // Compare results
      const comparison = {
        task_id: task.id || task.task_id || 'unknown',
        task_description: (task.description || task.task_description || task.title || '').substring(0, 100),
        timestamp: new Date().toISOString(),
        semantic: {
          master: semanticResult.master,
          confidence: semanticResult.confidence,
          method: semanticResult.method
        },
        keyword: {
          master: keywordResult.master,
          confidence: keywordResult.confidence,
          method: 'keyword'
        },
        agreement: semanticResult.master === keywordResult.master,
        confidence_diff: semanticResult.confidence - keywordResult.confidence
      };

      // Update metrics
      this.metrics.total_tests++;
      if (comparison.agreement) {
        this.metrics.agreements++;
      } else {
        this.metrics.disagreements++;
      }

      if (semanticResult.confidence > keywordResult.confidence) {
        this.metrics.semantic_higher_confidence++;
      } else if (keywordResult.confidence > semanticResult.confidence) {
        this.metrics.keyword_higher_confidence++;
      }

      // Calculate average confidences
      this.metrics.avg_semantic_confidence =
        ((this.metrics.avg_semantic_confidence * (this.metrics.total_tests - 1)) + semanticResult.confidence) /
        this.metrics.total_tests;
      this.metrics.avg_keyword_confidence =
        ((this.metrics.avg_keyword_confidence * (this.metrics.total_tests - 1)) + keywordResult.confidence) /
        this.metrics.total_tests;

      // Store result
      this.testResults.push(comparison);
      await this.saveTestResult(comparison);

      console.log(`[AB Test] Semantic: ${semanticResult.master} (${semanticResult.confidence.toFixed(2)}) | ` +
        `Keyword: ${keywordResult.master} (${keywordResult.confidence.toFixed(2)}) | ` +
        `Agreement: ${comparison.agreement ? 'YES' : 'NO'}`);
    } catch (error) {
      console.error(`[AB Test] Error during A/B test:`, error.message);
    }
  }

  /**
   * Save test result to JSONL file
   *
   * @private
   * @param {Object} result - Test result
   */
  async saveTestResult(result) {
    try {
      const line = JSON.stringify(result) + '\n';
      await fs.appendFile(this.resultsPath, line, 'utf8');
    } catch (error) {
      console.error(`[AB Test] Error saving test result:`, error.message);
    }
  }

  /**
   * Get A/B test metrics
   *
   * @returns {Object} - Metrics
   */
  getMetrics() {
    if (this.metrics.total_tests === 0) {
      return {
        ...this.metrics,
        agreement_rate: 0,
        semantic_win_rate: 0,
        keyword_win_rate: 0
      };
    }

    return {
      ...this.metrics,
      agreement_rate: (this.metrics.agreements / this.metrics.total_tests * 100).toFixed(1) + '%',
      semantic_win_rate: (this.metrics.semantic_higher_confidence / this.metrics.total_tests * 100).toFixed(1) + '%',
      keyword_win_rate: (this.metrics.keyword_higher_confidence / this.metrics.total_tests * 100).toFixed(1) + '%',
      avg_semantic_confidence: this.metrics.avg_semantic_confidence.toFixed(3),
      avg_keyword_confidence: this.metrics.avg_keyword_confidence.toFixed(3)
    };
  }

  /**
   * Generate A/B test report
   *
   * @returns {Promise<Object>} - Detailed report
   */
  async generateReport() {
    // Load all test results
    try {
      const data = await fs.readFile(this.resultsPath, 'utf8');
      const allResults = data.trim().split('\n').map(line => JSON.parse(line));

      // Calculate statistics
      const stats = {
        total_tests: allResults.length,
        agreement_count: allResults.filter(r => r.agreement).length,
        disagreement_count: allResults.filter(r => !r.agreement).length,
        semantic_higher: allResults.filter(r => r.confidence_diff > 0).length,
        keyword_higher: allResults.filter(r => r.confidence_diff < 0).length,
        equal_confidence: allResults.filter(r => r.confidence_diff === 0).length,
        avg_confidence_diff: allResults.reduce((sum, r) => sum + r.confidence_diff, 0) / allResults.length
      };

      stats.agreement_rate = (stats.agreement_count / stats.total_tests * 100).toFixed(1);
      stats.semantic_win_rate = (stats.semantic_higher / stats.total_tests * 100).toFixed(1);

      // Confidence distribution
      const semanticConfidences = allResults.map(r => r.semantic.confidence);
      const keywordConfidences = allResults.map(r => r.keyword.confidence);

      stats.semantic_confidence = {
        avg: (semanticConfidences.reduce((a, b) => a + b, 0) / semanticConfidences.length).toFixed(3),
        min: Math.min(...semanticConfidences).toFixed(3),
        max: Math.max(...semanticConfidences).toFixed(3)
      };

      stats.keyword_confidence = {
        avg: (keywordConfidences.reduce((a, b) => a + b, 0) / keywordConfidences.length).toFixed(3),
        min: Math.min(...keywordConfidences).toFixed(3),
        max: Math.max(...keywordConfidences).toFixed(3)
      };

      // Disagreement analysis
      const disagreements = allResults.filter(r => !r.agreement);
      stats.disagreement_examples = disagreements.slice(0, 5).map(r => ({
        task: r.task_description,
        semantic_choice: r.semantic.master,
        keyword_choice: r.keyword.master,
        semantic_confidence: r.semantic.confidence.toFixed(3),
        keyword_confidence: r.keyword.confidence.toFixed(3)
      }));

      return stats;
    } catch (error) {
      return {
        error: `Unable to generate report: ${error.message}`,
        ...this.getMetrics()
      };
    }
  }

  /**
   * Reset A/B test metrics and results
   */
  async reset() {
    this.metrics = {
      total_tests: 0,
      agreements: 0,
      disagreements: 0,
      semantic_higher_confidence: 0,
      keyword_higher_confidence: 0,
      avg_semantic_confidence: 0,
      avg_keyword_confidence: 0
    };

    this.testResults = [];

    try {
      await fs.unlink(this.resultsPath);
      console.log('[AB Test] A/B test data reset');
    } catch (error) {
      // File may not exist
    }
  }
}

module.exports = { ABTestRouter };
