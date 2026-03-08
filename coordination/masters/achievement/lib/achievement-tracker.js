#!/usr/bin/env node

/**
 * GitHub Achievement Tracker
 *
 * Tracks real-time achievement progress via GitHub API
 * Calculates current tier, progress to next tier, and opportunity scores
 */

const fs = require('fs').promises;
const path = require('path');

class AchievementTracker {
  constructor(options = {}) {
    this.githubToken = options.githubToken || process.env.GITHUB_TOKEN;
    this.username = options.username || process.env.GITHUB_USERNAME;
    this.apiBase = 'https://api.github.com';
    this.definitionsPath = path.join(__dirname, '../config/achievement-definitions.json');
    this.progressPath = path.join(__dirname, '../knowledge-base/progress.json');
    this.metricsPath = path.join(__dirname, '../metrics/tracking-history.jsonl');

    if (!this.githubToken) {
      console.warn('[Achievement Tracker] No GitHub token found. Set GITHUB_TOKEN environment variable.');
    }
  }

  /**
   * Load achievement definitions
   */
  async loadDefinitions() {
    try {
      const content = await fs.readFile(this.definitionsPath, 'utf-8');
      return JSON.parse(content);
    } catch (error) {
      console.error('[Achievement Tracker] Failed to load definitions:', error.message);
      throw error;
    }
  }

  /**
   * Make authenticated GitHub API request
   */
  async githubRequest(endpoint, options = {}) {
    const url = `${this.apiBase}${endpoint}`;
    const headers = {
      'Accept': 'application/vnd.github.v3+json',
      'User-Agent': 'commit-relay-achievement-tracker',
      ...(this.githubToken && { 'Authorization': `Bearer ${this.githubToken}` }),
      ...options.headers
    };

    try {
      const response = await fetch(url, {
        ...options,
        headers
      });

      if (!response.ok) {
        const errorText = await response.text();
        throw new Error(`GitHub API error (${response.status}): ${errorText}`);
      }

      return await response.json();
    } catch (error) {
      console.error(`[Achievement Tracker] API request failed for ${endpoint}:`, error.message);
      throw error;
    }
  }

  /**
   * Track Pair Extraordinaire progress
   * Count co-authored commits in merged PRs
   */
  async trackPairExtraordinaire() {
    try {
      // Search for merged PRs with co-authors
      const query = `author:${this.username}+type:pr+is:merged`;
      const searchResults = await this.githubRequest(`/search/issues?q=${encodeURIComponent(query)}&per_page=100`);

      let coauthoredCount = 0;

      // For each PR, check commits for co-authors
      for (const pr of searchResults.items || []) {
        const [owner, repo] = pr.repository_url.split('/').slice(-2);
        const commits = await this.githubRequest(`/repos/${owner}/${repo}/pulls/${pr.number}/commits`);

        // Check for Co-authored-by in commit messages
        const hasCoauthor = commits.some(commit => {
          const message = commit.commit.message || '';
          return message.includes('Co-authored-by:') || message.includes('Co-Authored-By:');
        });

        if (hasCoauthor) {
          coauthoredCount++;
        }
      }

      return {
        achievement_id: 'pair_extraordinaire',
        count: coauthoredCount,
        current_tier: this.calculateTier('pair_extraordinaire', coauthoredCount),
        progress: this.calculateProgress('pair_extraordinaire', coauthoredCount)
      };
    } catch (error) {
      console.error('[Achievement Tracker] Error tracking Pair Extraordinaire:', error.message);
      return { achievement_id: 'pair_extraordinaire', count: 0, error: error.message };
    }
  }

  /**
   * Track Pull Shark progress
   * Count merged PRs
   */
  async trackPullShark() {
    try {
      const query = `author:${this.username}+type:pr+is:merged`;
      const searchResults = await this.githubRequest(`/search/issues?q=${encodeURIComponent(query)}&per_page=100`);

      const mergedCount = searchResults.total_count || 0;

      return {
        achievement_id: 'pull_shark',
        count: mergedCount,
        current_tier: this.calculateTier('pull_shark', mergedCount),
        progress: this.calculateProgress('pull_shark', mergedCount)
      };
    } catch (error) {
      console.error('[Achievement Tracker] Error tracking Pull Shark:', error.message);
      return { achievement_id: 'pull_shark', count: 0, error: error.message };
    }
  }

  /**
   * Track Starstruck progress
   * Find repos with most stars
   */
  async trackStarstruck() {
    try {
      const repos = await this.githubRequest(`/users/${this.username}/repos?per_page=100&sort=stars`);

      const maxStars = repos.length > 0 ? Math.max(...repos.map(r => r.stargazers_count)) : 0;
      const topRepo = repos.find(r => r.stargazers_count === maxStars);

      return {
        achievement_id: 'starstruck',
        count: maxStars,
        current_tier: this.calculateTier('starstruck', maxStars),
        progress: this.calculateProgress('starstruck', maxStars),
        top_repo: topRepo ? {
          name: topRepo.full_name,
          stars: topRepo.stargazers_count,
          url: topRepo.html_url
        } : null
      };
    } catch (error) {
      console.error('[Achievement Tracker] Error tracking Starstruck:', error.message);
      return { achievement_id: 'starstruck', count: 0, error: error.message };
    }
  }

  /**
   * Track Galaxy Brain progress
   * Count accepted answers in discussions (requires GraphQL)
   */
  async trackGalaxyBrain() {
    try {
      // Note: This requires GraphQL API for discussions
      // For now, return placeholder
      return {
        achievement_id: 'galaxy_brain',
        count: 0,
        current_tier: 'none',
        progress: {
          current: 0,
          next_tier: 'bronze',
          next_requirement: 2,
          percentage: 0
        },
        note: 'Requires GraphQL API implementation for discussions'
      };
    } catch (error) {
      console.error('[Achievement Tracker] Error tracking Galaxy Brain:', error.message);
      return { achievement_id: 'galaxy_brain', count: 0, error: error.message };
    }
  }

  /**
   * Track Quickdraw (issues/PRs closed < 5 min)
   */
  async trackQuickdraw() {
    try {
      const issues = await this.githubRequest(`/search/issues?q=author:${this.username}+is:closed&per_page=100`);

      let quickdrawCount = 0;

      for (const issue of issues.items || []) {
        const created = new Date(issue.created_at);
        const closed = new Date(issue.closed_at);
        const diffMinutes = (closed - created) / 1000 / 60;

        if (diffMinutes <= 5) {
          quickdrawCount++;
        }
      }

      return {
        achievement_id: 'quickdraw',
        count: quickdrawCount,
        unlocked: quickdrawCount >= 1,
        fastest_close: quickdrawCount > 0 ? 'Data available' : 'N/A'
      };
    } catch (error) {
      console.error('[Achievement Tracker] Error tracking Quickdraw:', error.message);
      return { achievement_id: 'quickdraw', count: 0, error: error.message };
    }
  }

  /**
   * Calculate current tier for an achievement
   */
  calculateTier(achievementId, count) {
    const definitions = require(this.definitionsPath);
    const achievement = definitions.achievements[achievementId];

    if (!achievement || !achievement.tiers) {
      return 'unknown';
    }

    // Find highest tier achieved
    let currentTier = 'none';
    for (const tier of achievement.tiers.reverse()) {
      if (count >= tier.requirement) {
        currentTier = tier.name;
        break;
      }
    }

    return currentTier;
  }

  /**
   * Calculate progress to next tier
   */
  calculateProgress(achievementId, count) {
    const definitions = require(this.definitionsPath);
    const achievement = definitions.achievements[achievementId];

    if (!achievement || !achievement.tiers) {
      return { current: 0, next_tier: 'unknown', next_requirement: 0, percentage: 0 };
    }

    // Find next tier
    const sortedTiers = [...achievement.tiers].sort((a, b) => a.requirement - b.requirement);
    let nextTier = null;

    for (const tier of sortedTiers) {
      if (count < tier.requirement) {
        nextTier = tier;
        break;
      }
    }

    if (!nextTier) {
      // Max tier achieved
      const maxTier = sortedTiers[sortedTiers.length - 1];
      return {
        current: count,
        next_tier: 'max',
        next_requirement: maxTier.requirement,
        percentage: 100,
        completed: true
      };
    }

    // Calculate percentage to next tier
    const previousTier = sortedTiers.find(t => t.requirement <= count);
    const baseCount = previousTier ? previousTier.requirement : 0;
    const range = nextTier.requirement - baseCount;
    const progress = count - baseCount;
    const percentage = Math.min(100, Math.floor((progress / range) * 100));

    return {
      current: count,
      next_tier: nextTier.name,
      next_requirement: nextTier.requirement,
      needed: nextTier.requirement - count,
      percentage: percentage
    };
  }

  /**
   * Get all achievement progress
   */
  async getAllProgress() {
    console.log('[Achievement Tracker] Fetching all achievement progress...');

    const results = {
      username: this.username,
      timestamp: new Date().toISOString(),
      achievements: {}
    };

    try {
      // Track each achievement
      results.achievements.pair_extraordinaire = await this.trackPairExtraordinaire();
      results.achievements.pull_shark = await this.trackPullShark();
      results.achievements.starstruck = await this.trackStarstruck();
      results.achievements.galaxy_brain = await this.trackGalaxyBrain();
      results.achievements.quickdraw = await this.trackQuickdraw();

      // Calculate summary
      results.summary = {
        total_achievements: Object.keys(results.achievements).length,
        unlocked: Object.values(results.achievements).filter(a => a.unlocked || a.count > 0).length,
        in_progress: Object.values(results.achievements).filter(a => a.count > 0 && !a.unlocked).length
      };

      // Save progress
      await this.saveProgress(results);

      // Log metric
      await this.logMetric(results);

      return results;
    } catch (error) {
      console.error('[Achievement Tracker] Error fetching progress:', error.message);
      results.error = error.message;
      return results;
    }
  }

  /**
   * Save progress to knowledge base
   */
  async saveProgress(progress) {
    try {
      await fs.mkdir(path.dirname(this.progressPath), { recursive: true });
      await fs.writeFile(this.progressPath, JSON.stringify(progress, null, 2));
      console.log('[Achievement Tracker] Progress saved to knowledge base');
    } catch (error) {
      console.error('[Achievement Tracker] Failed to save progress:', error.message);
    }
  }

  /**
   * Log tracking event to metrics
   */
  async logMetric(progress) {
    try {
      await fs.mkdir(path.dirname(this.metricsPath), { recursive: true });

      const metric = {
        timestamp: new Date().toISOString(),
        event: 'achievement_tracking',
        username: this.username,
        summary: progress.summary,
        achievements: Object.entries(progress.achievements).map(([id, data]) => ({
          id,
          count: data.count,
          tier: data.current_tier || (data.unlocked ? 'unlocked' : 'none')
        }))
      };

      await fs.appendFile(this.metricsPath, JSON.stringify(metric) + '\n');
    } catch (error) {
      console.error('[Achievement Tracker] Failed to log metric:', error.message);
    }
  }

  /**
   * Get opportunity score for each achievement
   * Higher score = easier to unlock / more ROI
   */
  async getOpportunityScores() {
    const progress = await this.getAllProgress();
    const definitions = await this.loadDefinitions();
    const opportunities = [];

    for (const [achievementId, achievementData] of Object.entries(progress.achievements)) {
      const definition = definitions.achievements[achievementId];

      if (!definition || !definition.earnable || !definition.automation.enabled) {
        continue;
      }

      // Calculate opportunity score (0-100)
      let score = 0;

      // Priority from definition (0-40 points)
      const priorityScores = { high: 40, medium: 25, low: 10, none: 0 };
      score += priorityScores[definition.automation_priority] || 0;

      // Proximity to next tier (0-30 points)
      if (achievementData.progress) {
        score += achievementData.progress.percentage * 0.3;
      }

      // Automation ease (0-30 points)
      const automationScores = {
        'coauthor_commits': 30,    // Already implemented
        'instant_fix': 28,         // Easy to automate
        'self_merge': 28,          // Easy to automate
        'feature_branch_workflow': 20, // Moderate effort
        'discussion_response': 15   // Complex
      };
      score += automationScores[definition.automation.strategy] || 0;

      opportunities.push({
        achievement_id: achievementId,
        name: definition.name,
        icon: definition.icon,
        current_count: achievementData.count || 0,
        current_tier: achievementData.current_tier || 'none',
        next_tier: achievementData.progress?.next_tier,
        progress_percentage: achievementData.progress?.percentage || 0,
        opportunity_score: Math.round(score),
        automation_strategy: definition.automation.strategy,
        automation_enabled: definition.automation.enabled,
        priority: definition.automation_priority
      });
    }

    // Sort by opportunity score
    opportunities.sort((a, b) => b.opportunity_score - a.opportunity_score);

    return {
      timestamp: new Date().toISOString(),
      username: this.username,
      opportunities: opportunities,
      top_3: opportunities.slice(0, 3)
    };
  }
}

// CLI usage
if (require.main === module) {
  const tracker = new AchievementTracker();

  tracker.getAllProgress()
    .then(progress => {
      console.log('\n=== Achievement Progress ===\n');
      console.log(JSON.stringify(progress, null, 2));

      return tracker.getOpportunityScores();
    })
    .then(opportunities => {
      console.log('\n=== Top Opportunities ===\n');
      opportunities.top_3.forEach((opp, i) => {
        console.log(`${i + 1}. ${opp.icon} ${opp.name}`);
        console.log(`   Score: ${opp.opportunity_score}/100`);
        console.log(`   Current: ${opp.current_tier} (${opp.current_count})`);
        console.log(`   Strategy: ${opp.automation_strategy}\n`);
      });
    })
    .catch(error => {
      console.error('Error:', error.message);
      process.exit(1);
    });
}

module.exports = AchievementTracker;
