/**
 * Prompts API Routes
 *
 * Provides endpoints for managing prompt registry and versioning
 */

const express = require('express');
const router = express.Router();
const fs = require('fs').promises;
const path = require('path');

// Paths to the prompts registry
// Primary: coordination/prompts for centralized storage
// Fallback: llm-mesh/prompts for legacy support
const COORD_DIR = process.env.COMMIT_RELAY_HOME
  ? path.join(process.env.COMMIT_RELAY_HOME, 'coordination')
  : path.join(__dirname, '../../coordination');

const PRIMARY_REGISTRY_PATH = path.join(COORD_DIR, 'prompts/registry.json');
const FALLBACK_REGISTRY_PATH = path.join(__dirname, '../../llm-mesh/prompts/registry.json');

// Use primary path if it exists, otherwise fallback
const REGISTRY_PATH = require('fs').existsSync(PRIMARY_REGISTRY_PATH)
  ? PRIMARY_REGISTRY_PATH
  : FALLBACK_REGISTRY_PATH;

/**
 * Load the prompts registry from disk
 */
async function loadRegistry() {
  try {
    const data = await fs.readFile(REGISTRY_PATH, 'utf-8');
    return JSON.parse(data);
  } catch (error) {
    console.error('Error loading prompts registry:', error);
    throw new Error('Failed to load prompts registry');
  }
}

/**
 * Save the prompts registry to disk
 */
async function saveRegistry(registry) {
  try {
    registry.last_updated = new Date().toISOString();
    await fs.writeFile(REGISTRY_PATH, JSON.stringify(registry, null, 2));
    return true;
  } catch (error) {
    console.error('Error saving prompts registry:', error);
    throw new Error('Failed to save prompts registry');
  }
}

/**
 * GET /api/v1/prompts
 * List all prompts with summary information
 */
router.get('/', async (req, res) => {
  try {
    const registry = await loadRegistry();

    // Apply filters if provided
    let prompts = registry.prompts;

    // Filter by category
    if (req.query.category) {
      prompts = prompts.filter(p => p.category === req.query.category);
    }

    // Filter by tag
    if (req.query.tag) {
      prompts = prompts.filter(p => p.tags.includes(req.query.tag));
    }

    // Search by name or description
    if (req.query.search) {
      const search = req.query.search.toLowerCase();
      prompts = prompts.filter(p =>
        p.name.toLowerCase().includes(search) ||
        p.description.toLowerCase().includes(search)
      );
    }

    // Map to summary format
    const summaries = prompts.map(prompt => {
      const activeVersion = prompt.versions.find(v => v.active);
      return {
        id: prompt.id,
        name: prompt.name,
        description: prompt.description,
        category: prompt.category,
        current_version: activeVersion ? activeVersion.version : null,
        version_count: prompt.versions.length,
        metrics: prompt.metrics,
        tags: prompt.tags
      };
    });

    res.json({
      success: true,
      data: {
        prompts: summaries,
        categories: registry.categories,
        total: summaries.length
      }
    });
  } catch (error) {
    res.status(500).json({
      success: false,
      error: error.message
    });
  }
});

/**
 * GET /api/v1/prompts/:id
 * Get detailed information about a specific prompt including content
 */
router.get('/:id', async (req, res) => {
  try {
    const registry = await loadRegistry();
    const prompt = registry.prompts.find(p => p.id === req.params.id);

    if (!prompt) {
      return res.status(404).json({
        success: false,
        error: 'Prompt not found'
      });
    }

    // Get active version
    const activeVersion = prompt.versions.find(v => v.active);

    // Try to load prompt content from file
    let content = null;
    if (activeVersion && activeVersion.file_path) {
      try {
        const contentPath = path.join(__dirname, '../..', activeVersion.file_path);
        content = await fs.readFile(contentPath, 'utf-8');
      } catch (err) {
        // Content file may not exist in demo
        content = `# ${prompt.name}\n\n${prompt.description}\n\n[Content would be loaded from: ${activeVersion.file_path}]`;
      }
    }

    res.json({
      success: true,
      data: {
        id: prompt.id,
        name: prompt.name,
        description: prompt.description,
        category: prompt.category,
        tags: prompt.tags,
        current_version: activeVersion ? activeVersion.version : null,
        version_count: prompt.versions.length,
        metrics: prompt.metrics,
        content: content,
        active_version: activeVersion
      }
    });
  } catch (error) {
    res.status(500).json({
      success: false,
      error: error.message
    });
  }
});

/**
 * GET /api/v1/prompts/:id/versions
 * Get version history for a specific prompt
 */
router.get('/:id/versions', async (req, res) => {
  try {
    const registry = await loadRegistry();
    const prompt = registry.prompts.find(p => p.id === req.params.id);

    if (!prompt) {
      return res.status(404).json({
        success: false,
        error: 'Prompt not found'
      });
    }

    // Sort versions by created_at descending
    const versions = [...prompt.versions].sort((a, b) =>
      new Date(b.created_at).getTime() - new Date(a.created_at).getTime()
    );

    res.json({
      success: true,
      data: {
        prompt_id: prompt.id,
        prompt_name: prompt.name,
        versions: versions,
        total: versions.length
      }
    });
  } catch (error) {
    res.status(500).json({
      success: false,
      error: error.message
    });
  }
});

/**
 * POST /api/v1/prompts/:id/activate
 * Activate a specific version of a prompt
 */
router.post('/:id/activate', async (req, res) => {
  try {
    const { version } = req.body;

    if (!version) {
      return res.status(400).json({
        success: false,
        error: 'Version is required'
      });
    }

    const registry = await loadRegistry();
    const promptIndex = registry.prompts.findIndex(p => p.id === req.params.id);

    if (promptIndex === -1) {
      return res.status(404).json({
        success: false,
        error: 'Prompt not found'
      });
    }

    const prompt = registry.prompts[promptIndex];
    const versionExists = prompt.versions.some(v => v.version === version);

    if (!versionExists) {
      return res.status(404).json({
        success: false,
        error: `Version ${version} not found`
      });
    }

    // Deactivate all versions and activate the requested one
    prompt.versions = prompt.versions.map(v => ({
      ...v,
      active: v.version === version
    }));

    registry.prompts[promptIndex] = prompt;
    await saveRegistry(registry);

    const activatedVersion = prompt.versions.find(v => v.version === version);

    res.json({
      success: true,
      data: {
        prompt_id: prompt.id,
        activated_version: version,
        message: `Successfully activated version ${version} for ${prompt.name}`,
        version_details: activatedVersion
      }
    });
  } catch (error) {
    res.status(500).json({
      success: false,
      error: error.message
    });
  }
});

/**
 * GET /api/v1/prompts/:id/metrics
 * Get performance metrics for a specific prompt
 */
router.get('/:id/metrics', async (req, res) => {
  try {
    const registry = await loadRegistry();
    const prompt = registry.prompts.find(p => p.id === req.params.id);

    if (!prompt) {
      return res.status(404).json({
        success: false,
        error: 'Prompt not found'
      });
    }

    // Generate time series data (simulated for now)
    const now = new Date();
    const timeSeriesData = [];
    for (let i = 23; i >= 0; i--) {
      const timestamp = new Date(now.getTime() - i * 3600000);
      timeSeriesData.push({
        timestamp: timestamp.toISOString(),
        uses: Math.floor(Math.random() * 100) + 10,
        avg_confidence: (0.75 + Math.random() * 0.2).toFixed(3),
        avg_latency_ms: Math.floor(Math.random() * 500) + prompt.metrics.avg_latency_ms * 0.8
      });
    }

    // Calculate version comparison
    const versionMetrics = prompt.versions.map(v => ({
      version: v.version,
      active: v.active,
      created_at: v.created_at,
      // Simulated metrics per version
      uses: Math.floor(prompt.metrics.total_uses / prompt.versions.length),
      accuracy: (prompt.metrics.accuracy - Math.random() * 0.05).toFixed(3)
    }));

    res.json({
      success: true,
      data: {
        prompt_id: prompt.id,
        prompt_name: prompt.name,
        summary: prompt.metrics,
        time_series: timeSeriesData,
        by_version: versionMetrics,
        recommendations: generateRecommendations(prompt)
      }
    });
  } catch (error) {
    res.status(500).json({
      success: false,
      error: error.message
    });
  }
});

/**
 * Generate recommendations based on prompt performance
 */
function generateRecommendations(prompt) {
  const recommendations = [];

  if (prompt.metrics.accuracy < 0.85) {
    recommendations.push({
      type: 'warning',
      message: 'Accuracy is below 85%. Consider reviewing and updating the prompt.'
    });
  }

  if (prompt.metrics.avg_latency_ms > 2000) {
    recommendations.push({
      type: 'info',
      message: 'High latency detected. Consider optimizing prompt length or structure.'
    });
  }

  if (prompt.metrics.avg_confidence < 0.8) {
    recommendations.push({
      type: 'warning',
      message: 'Low average confidence. Prompt may need more specific instructions.'
    });
  }

  if (prompt.versions.length > 5) {
    recommendations.push({
      type: 'info',
      message: 'Many versions exist. Consider archiving old versions.'
    });
  }

  if (recommendations.length === 0) {
    recommendations.push({
      type: 'success',
      message: 'Prompt is performing well. No action needed.'
    });
  }

  return recommendations;
}

/**
 * GET /api/v1/prompts/stats/summary
 * Get overall statistics for all prompts
 */
router.get('/stats/summary', async (req, res) => {
  try {
    const registry = await loadRegistry();

    const totalUses = registry.prompts.reduce((sum, p) => sum + p.metrics.total_uses, 0);
    const avgAccuracy = registry.prompts.reduce((sum, p) => sum + p.metrics.accuracy, 0) / registry.prompts.length;
    const avgConfidence = registry.prompts.reduce((sum, p) => sum + p.metrics.avg_confidence, 0) / registry.prompts.length;
    const avgLatency = registry.prompts.reduce((sum, p) => sum + p.metrics.avg_latency_ms, 0) / registry.prompts.length;

    // Category breakdown
    const byCategory = {};
    registry.prompts.forEach(prompt => {
      if (!byCategory[prompt.category]) {
        byCategory[prompt.category] = { count: 0, uses: 0 };
      }
      byCategory[prompt.category].count++;
      byCategory[prompt.category].uses += prompt.metrics.total_uses;
    });

    res.json({
      success: true,
      data: {
        total_prompts: registry.prompts.length,
        total_versions: registry.prompts.reduce((sum, p) => sum + p.versions.length, 0),
        total_uses: totalUses,
        avg_accuracy: avgAccuracy.toFixed(3),
        avg_confidence: avgConfidence.toFixed(3),
        avg_latency_ms: Math.round(avgLatency),
        by_category: byCategory,
        last_updated: registry.last_updated
      }
    });
  } catch (error) {
    res.status(500).json({
      success: false,
      error: error.message
    });
  }
});

module.exports = router;
