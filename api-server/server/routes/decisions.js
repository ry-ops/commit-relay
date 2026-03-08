/**
 * Decision History API Routes
 * Provides endpoints for browsing and analyzing routing decisions
 */

const express = require('express');
const router = express.Router();
const fs = require('fs').promises;
const fsSync = require('fs');
const path = require('path');

// Base paths
const COMMIT_RELAY_HOME = process.env.COMMIT_RELAY_HOME || path.join(__dirname, '../../..');
const COORD_DIR = path.join(COMMIT_RELAY_HOME, 'coordination');
const DECISIONS_FILE = path.join(COORD_DIR, 'masters/coordinator/knowledge-base/routing-decisions.jsonl');

/**
 * Read JSON file safely
 */
async function readJSON(filePath) {
  try {
    const content = await fs.readFile(filePath, 'utf-8');
    return JSON.parse(content);
  } catch (error) {
    return null;
  }
}

/**
 * Parse JSONL file and return array of decisions
 */
async function parseDecisions() {
  const decisions = [];

  if (!fsSync.existsSync(DECISIONS_FILE)) {
    return decisions;
  }

  try {
    const content = await fs.readFile(DECISIONS_FILE, 'utf-8');
    const lines = content.trim().split('\n').filter(l => l.trim());

    for (let i = 0; i < lines.length; i++) {
      try {
        const line = lines[i].trim();
        if (!line) continue;

        const entry = JSON.parse(line);

        // Only include entries with decision data (not learner entries)
        if (entry.task_id && (entry.decision || entry.routed_to)) {
          decisions.push({
            id: `decision-${i}`,
            task_id: entry.task_id,
            timestamp: entry.timestamp,
            routing_strategy: entry.routing_strategy || 'rule_based',
            master: entry.decision?.primary_expert || entry.routed_to || 'unknown',
            confidence: entry.decision?.primary_confidence || entry.confidence || 0,
            strategy: entry.decision?.strategy || 'unknown',
            scores: entry.decision?.scores || {},
            parallel_experts: entry.decision?.parallel_experts || [],
            rule_used: entry.rule_used || null,
            reasoning: generateReasoning(entry),
            raw: entry
          });
        }
      } catch (parseErr) {
        // Skip malformed lines
        console.warn(`Skipping malformed decision line ${i}:`, parseErr.message);
      }
    }
  } catch (err) {
    console.error('Error reading decisions file:', err.message);
  }

  // Sort by timestamp descending (most recent first)
  decisions.sort((a, b) => {
    const dateA = new Date(a.timestamp || 0);
    const dateB = new Date(b.timestamp || 0);
    return dateB - dateA;
  });

  return decisions;
}

/**
 * Generate reasoning text from decision data
 */
function generateReasoning(entry) {
  const parts = [];

  if (entry.decision) {
    const d = entry.decision;
    parts.push(`Selected ${d.primary_expert} with ${(d.primary_confidence * 100).toFixed(0)}% confidence.`);

    if (d.strategy) {
      parts.push(`Strategy: ${d.strategy.replace(/_/g, ' ')}.`);
    }

    if (d.scores && Object.keys(d.scores).length > 0) {
      const scoreText = Object.entries(d.scores)
        .filter(([_, score]) => score > 0)
        .map(([expert, score]) => `${expert}: ${(score * 100).toFixed(0)}%`)
        .join(', ');
      if (scoreText) {
        parts.push(`Expert scores: ${scoreText}.`);
      }
    }

    if (d.parallel_experts && d.parallel_experts.length > 0) {
      parts.push(`Parallel experts: ${d.parallel_experts.join(', ')}.`);
    }
  } else if (entry.routed_to) {
    parts.push(`Routed to ${entry.routed_to} using rule: ${entry.rule_used || 'default'}.`);
  }

  return parts.join(' ') || 'No reasoning available';
}

/**
 * GET /api/decisions
 * List routing decisions with filtering
 */
router.get('/', async (req, res) => {
  try {
    const {
      master,
      task_type,
      start_date,
      end_date,
      min_confidence,
      max_confidence,
      strategy,
      limit = 100,
      offset = 0,
      sort_by = 'timestamp',
      sort_order = 'desc'
    } = req.query;

    let decisions = await parseDecisions();

    // Apply filters
    if (master) {
      decisions = decisions.filter(d =>
        d.master.toLowerCase().includes(master.toLowerCase())
      );
    }

    if (task_type) {
      decisions = decisions.filter(d =>
        d.task_id.toLowerCase().includes(task_type.toLowerCase())
      );
    }

    if (start_date) {
      const startTime = new Date(start_date).getTime();
      decisions = decisions.filter(d =>
        new Date(d.timestamp).getTime() >= startTime
      );
    }

    if (end_date) {
      const endTime = new Date(end_date).getTime();
      decisions = decisions.filter(d =>
        new Date(d.timestamp).getTime() <= endTime
      );
    }

    if (min_confidence) {
      const minConf = parseFloat(min_confidence);
      decisions = decisions.filter(d => d.confidence >= minConf);
    }

    if (max_confidence) {
      const maxConf = parseFloat(max_confidence);
      decisions = decisions.filter(d => d.confidence <= maxConf);
    }

    if (strategy) {
      decisions = decisions.filter(d =>
        d.strategy.toLowerCase().includes(strategy.toLowerCase())
      );
    }

    // Get total count before pagination
    const total = decisions.length;

    // Apply sorting
    decisions.sort((a, b) => {
      let comparison = 0;
      switch (sort_by) {
        case 'confidence':
          comparison = a.confidence - b.confidence;
          break;
        case 'master':
          comparison = a.master.localeCompare(b.master);
          break;
        case 'timestamp':
        default:
          comparison = new Date(a.timestamp) - new Date(b.timestamp);
      }
      return sort_order === 'asc' ? comparison : -comparison;
    });

    // Apply pagination
    const startIndex = parseInt(offset);
    const endIndex = startIndex + parseInt(limit);
    const paginatedDecisions = decisions.slice(startIndex, endIndex);

    // Remove raw data from list response to reduce payload
    const cleanedDecisions = paginatedDecisions.map(d => ({
      id: d.id,
      task_id: d.task_id,
      timestamp: d.timestamp,
      master: d.master,
      confidence: d.confidence,
      strategy: d.strategy,
      reasoning: d.reasoning
    }));

    res.json({
      success: true,
      data: {
        decisions: cleanedDecisions,
        pagination: {
          total,
          limit: parseInt(limit),
          offset: startIndex,
          has_more: endIndex < total
        }
      }
    });
  } catch (error) {
    console.error('Error getting decisions:', error);
    res.status(500).json({
      success: false,
      error: error.message
    });
  }
});

/**
 * GET /api/decisions/stats
 * Get decision statistics
 */
router.get('/stats', async (req, res) => {
  try {
    const { start_date, end_date } = req.query;

    let decisions = await parseDecisions();

    // Apply date filters
    if (start_date) {
      const startTime = new Date(start_date).getTime();
      decisions = decisions.filter(d =>
        new Date(d.timestamp).getTime() >= startTime
      );
    }

    if (end_date) {
      const endTime = new Date(end_date).getTime();
      decisions = decisions.filter(d =>
        new Date(d.timestamp).getTime() <= endTime
      );
    }

    // Calculate statistics
    const stats = {
      total_decisions: decisions.length,
      by_master: {},
      by_strategy: {},
      confidence_distribution: {
        'low': 0,      // 0-50%
        'medium': 0,   // 50-75%
        'high': 0,     // 75-90%
        'very_high': 0 // 90-100%
      },
      avg_confidence: 0,
      recent_activity: {
        last_hour: 0,
        last_day: 0,
        last_week: 0
      }
    };

    const now = Date.now();
    const hourAgo = now - 60 * 60 * 1000;
    const dayAgo = now - 24 * 60 * 60 * 1000;
    const weekAgo = now - 7 * 24 * 60 * 60 * 1000;

    let totalConfidence = 0;

    for (const decision of decisions) {
      // Count by master
      if (!stats.by_master[decision.master]) {
        stats.by_master[decision.master] = {
          count: 0,
          total_confidence: 0,
          high_confidence_count: 0
        };
      }
      stats.by_master[decision.master].count++;
      stats.by_master[decision.master].total_confidence += decision.confidence;
      if (decision.confidence >= 0.75) {
        stats.by_master[decision.master].high_confidence_count++;
      }

      // Count by strategy
      if (!stats.by_strategy[decision.strategy]) {
        stats.by_strategy[decision.strategy] = 0;
      }
      stats.by_strategy[decision.strategy]++;

      // Confidence distribution
      if (decision.confidence < 0.5) {
        stats.confidence_distribution.low++;
      } else if (decision.confidence < 0.75) {
        stats.confidence_distribution.medium++;
      } else if (decision.confidence < 0.9) {
        stats.confidence_distribution.high++;
      } else {
        stats.confidence_distribution.very_high++;
      }

      totalConfidence += decision.confidence;

      // Recent activity
      const decisionTime = new Date(decision.timestamp).getTime();
      if (decisionTime >= hourAgo) stats.recent_activity.last_hour++;
      if (decisionTime >= dayAgo) stats.recent_activity.last_day++;
      if (decisionTime >= weekAgo) stats.recent_activity.last_week++;
    }

    // Calculate averages
    stats.avg_confidence = decisions.length > 0
      ? totalConfidence / decisions.length
      : 0;

    // Add average confidence to each master
    for (const master in stats.by_master) {
      const masterStats = stats.by_master[master];
      masterStats.avg_confidence = masterStats.count > 0
        ? masterStats.total_confidence / masterStats.count
        : 0;
      masterStats.high_confidence_rate = masterStats.count > 0
        ? masterStats.high_confidence_count / masterStats.count
        : 0;
      delete masterStats.total_confidence;
    }

    // Convert to arrays for easier consumption
    const masterStats = Object.entries(stats.by_master)
      .map(([name, data]) => ({
        name,
        count: data.count,
        avg_confidence: Math.round(data.avg_confidence * 1000) / 1000,
        high_confidence_rate: Math.round(data.high_confidence_rate * 1000) / 1000,
        high_confidence_count: data.high_confidence_count
      }))
      .sort((a, b) => b.count - a.count);

    const strategyStats = Object.entries(stats.by_strategy)
      .map(([name, count]) => ({ name, count }))
      .sort((a, b) => b.count - a.count);

    res.json({
      success: true,
      data: {
        summary: {
          total_decisions: stats.total_decisions,
          avg_confidence: Math.round(stats.avg_confidence * 1000) / 1000,
          high_confidence_rate: stats.total_decisions > 0
            ? Math.round((stats.confidence_distribution.high + stats.confidence_distribution.very_high) / stats.total_decisions * 1000) / 1000
            : 0
        },
        by_master: masterStats,
        by_strategy: strategyStats,
        confidence_distribution: stats.confidence_distribution,
        recent_activity: stats.recent_activity,
        generated_at: new Date().toISOString()
      }
    });
  } catch (error) {
    console.error('Error getting decision stats:', error);
    res.status(500).json({
      success: false,
      error: error.message
    });
  }
});

/**
 * GET /api/decisions/:id
 * Get single decision details
 */
router.get('/:id', async (req, res) => {
  try {
    const { id } = req.params;
    const decisions = await parseDecisions();

    const decision = decisions.find(d => d.id === id);

    if (!decision) {
      return res.status(404).json({
        success: false,
        error: 'Decision not found'
      });
    }

    // Get alternative candidates from scores
    const alternatives = Object.entries(decision.scores || {})
      .filter(([expert]) => expert !== decision.master)
      .map(([expert, score]) => ({
        expert,
        confidence: score,
        difference: decision.confidence - score
      }))
      .sort((a, b) => b.confidence - a.confidence);

    // Extract matched keywords from task_id
    const matchedKeywords = [];
    const taskIdLower = decision.task_id.toLowerCase();

    const keywordPatterns = {
      security: ['security', 'scan', 'audit', 'vulnerability', 'auth'],
      development: ['dev', 'impl', 'feature', 'code', 'test'],
      inventory: ['doc', 'inventory', 'catalog', 'list'],
      cicd: ['ci', 'cd', 'deploy', 'build', 'pipeline']
    };

    for (const [category, keywords] of Object.entries(keywordPatterns)) {
      for (const keyword of keywords) {
        if (taskIdLower.includes(keyword)) {
          matchedKeywords.push({ keyword, category });
        }
      }
    }

    res.json({
      success: true,
      data: {
        id: decision.id,
        task_id: decision.task_id,
        timestamp: decision.timestamp,
        routing_strategy: decision.routing_strategy,
        selected_master: {
          name: decision.master,
          confidence: decision.confidence,
          strategy: decision.strategy
        },
        reasoning: decision.reasoning,
        alternatives,
        matched_keywords: matchedKeywords,
        parallel_experts: decision.parallel_experts,
        rule_used: decision.rule_used,
        all_scores: decision.scores,
        raw_decision: decision.raw
      }
    });
  } catch (error) {
    console.error('Error getting decision details:', error);
    res.status(500).json({
      success: false,
      error: error.message
    });
  }
});

module.exports = router;
