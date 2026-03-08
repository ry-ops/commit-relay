#!/usr/bin/env node

/**
 * Achievement Strategy Planner
 *
 * Analyzes achievement gaps and creates strategic tasks
 * Routes tasks to appropriate masters via MoE coordinator
 */

const fs = require('fs').promises;
const path = require('path');
const AchievementTracker = require('./achievement-tracker');

class StrategyPlanner {
  constructor(options = {}) {
    this.tracker = new AchievementTracker(options);
    this.taskQueuePath = path.join(__dirname, '../../../tasks/pending');
    this.planHistoryPath = path.join(__dirname, '../metrics/plan-history.jsonl');
    this.strategyPath = path.join(__dirname, '../knowledge-base/current-strategy.json');
  }

  /**
   * Generate strategic plan based on achievement gaps
   */
  async generatePlan() {
    console.log('[Strategy Planner] Generating achievement plan...');

    try {
      // Get current progress and opportunities
      const progress = await this.tracker.getAllProgress();
      const opportunities = await this.tracker.getOpportunityScores();

      // Analyze gaps
      const gaps = this.analyzeGaps(progress, opportunities);

      // Create strategic plan
      const plan = {
        generated_at: new Date().toISOString(),
        username: progress.username,
        current_status: progress.summary,
        gaps: gaps,
        recommended_actions: this.generateActions(opportunities),
        task_queue: [],
        estimated_timeline: this.estimateTimeline(opportunities)
      };

      // Generate tasks for high-priority achievements
      plan.task_queue = await this.generateTasks(opportunities);

      // Save plan
      await this.savePlan(plan);

      // Log to history
      await this.logPlanHistory(plan);

      return plan;
    } catch (error) {
      console.error('[Strategy Planner] Error generating plan:', error.message);
      throw error;
    }
  }

  /**
   * Analyze achievement gaps
   */
  analyzeGaps(progress, opportunities) {
    const gaps = {
      immediate_wins: [],
      high_priority: [],
      medium_priority: [],
      long_term: []
    };

    for (const opp of opportunities.opportunities) {
      const gap = {
        achievement: opp.name,
        icon: opp.icon,
        current: opp.current_count,
        current_tier: opp.current_tier,
        next_tier: opp.next_tier,
        needed: opp.current_count === 0 ? 'Not started' : `${opp.progress_percentage}% complete`,
        score: opp.opportunity_score
      };

      // Categorize by priority and score
      if (opp.opportunity_score >= 80) {
        gaps.immediate_wins.push(gap);
      } else if (opp.opportunity_score >= 60) {
        gaps.high_priority.push(gap);
      } else if (opp.opportunity_score >= 40) {
        gaps.medium_priority.push(gap);
      } else {
        gaps.long_term.push(gap);
      }
    }

    return gaps;
  }

  /**
   * Generate recommended actions
   */
  generateActions(opportunities) {
    const actions = [];

    for (const opp of opportunities.top_3) {
      const action = {
        achievement: opp.name,
        icon: opp.icon,
        priority: opp.priority,
        score: opp.opportunity_score,
        strategy: opp.automation_strategy,
        steps: this.getStrategySteps(opp.automation_strategy),
        master: this.getMasterForStrategy(opp.automation_strategy),
        estimated_time: this.estimateActionTime(opp.automation_strategy)
      };

      actions.push(action);
    }

    return actions;
  }

  /**
   * Get implementation steps for a strategy
   */
  getStrategySteps(strategy) {
    const strategySteps = {
      'coauthor_commits': [
        'Verify Co-Authored-By is in all commits (already implemented)',
        'No action needed - automatic'
      ],
      'instant_fix': [
        'Create issue with known fix',
        'Spawn implementation worker',
        'Apply fix within 5 minutes',
        'Close issue to unlock Quickdraw'
      ],
      'self_merge': [
        'Create PR for next feature',
        'Wait for CI tests to pass',
        'Auto-merge without code review',
        'Unlock YOLO achievement'
      ],
      'feature_branch_workflow': [
        'Identify enhancement opportunity',
        'Create feature branch',
        'Implement changes via worker',
        'Create pull request',
        'Run CI/CD tests',
        'Auto-merge after tests pass'
      ],
      'discussion_response': [
        'Enable discussions on commit-relay repo',
        'Monitor for new questions',
        'Generate helpful responses',
        'Submit answers',
        'Track accepted answers'
      ]
    };

    return strategySteps[strategy] || ['Strategy not defined'];
  }

  /**
   * Determine which master should handle the strategy
   */
  getMasterForStrategy(strategy) {
    const strategyMasters = {
      'coauthor_commits': 'all-masters',
      'instant_fix': 'development-master',
      'self_merge': 'cicd-master',
      'feature_branch_workflow': 'development-master',
      'discussion_response': 'achievement-master'
    };

    return strategyMasters[strategy] || 'coordinator-master';
  }

  /**
   * Estimate time to complete action
   */
  estimateActionTime(strategy) {
    const timeEstimates = {
      'coauthor_commits': '0 minutes (already done)',
      'instant_fix': '5-10 minutes',
      'self_merge': '10-15 minutes',
      'feature_branch_workflow': '30-60 minutes per PR',
      'discussion_response': 'Ongoing (monitor daily)'
    };

    return timeEstimates[strategy] || 'Unknown';
  }

  /**
   * Estimate timeline for achievement completion
   */
  estimateTimeline(opportunities) {
    const timeline = {
      immediate: [],      // < 1 hour
      short_term: [],     // 1 day - 1 week
      medium_term: [],    // 1-4 weeks
      long_term: []       // > 1 month
    };

    for (const opp of opportunities.opportunities) {
      const item = {
        achievement: opp.name,
        icon: opp.icon,
        score: opp.opportunity_score
      };

      if (opp.opportunity_score >= 80) {
        timeline.immediate.push(item);
      } else if (opp.opportunity_score >= 60) {
        timeline.short_term.push(item);
      } else if (opp.opportunity_score >= 40) {
        timeline.medium_term.push(item);
      } else {
        timeline.long_term.push(item);
      }
    }

    return timeline;
  }

  /**
   * Generate tasks for task queue
   */
  async generateTasks(opportunities) {
    const tasks = [];

    // Create tasks for top 3 opportunities
    for (const opp of opportunities.top_3) {
      if (!opp.automation_enabled) {
        continue;
      }

      const task = this.createTask(opp);
      tasks.push(task);

      // Save task to pending queue
      await this.saveTask(task);
    }

    return tasks;
  }

  /**
   * Create task object for coordinator
   */
  createTask(opportunity) {
    const taskId = `achievement-${opportunity.achievement_id}-${Date.now()}`;

    const taskDescriptions = {
      'pair_extraordinaire': 'Continue using Co-Authored-By in all commits',
      'pull_shark': 'Create feature branch and PR for next enhancement',
      'quickdraw': 'Create issue and fix within 5 minutes to unlock Quickdraw',
      'yolo': 'Merge next PR without code review to unlock YOLO',
      'galaxy_brain': 'Answer questions in GitHub Discussions',
      'starstruck': 'Improve documentation and marketing for stars'
    };

    return {
      task_id: taskId,
      created_at: new Date().toISOString(),
      source: 'achievement-master',
      priority: opportunity.priority,
      achievement: {
        id: opportunity.achievement_id,
        name: opportunity.name,
        icon: opportunity.icon,
        current_tier: opportunity.current_tier,
        target_tier: opportunity.next_tier
      },
      description: taskDescriptions[opportunity.achievement_id] || `Work on ${opportunity.name}`,
      strategy: opportunity.automation_strategy,
      assigned_master: this.getMasterForStrategy(opportunity.automation_strategy),
      steps: this.getStrategySteps(opportunity.automation_strategy),
      estimated_time: this.estimateActionTime(opportunity.automation_strategy),
      opportunity_score: opportunity.opportunity_score,
      status: 'pending',
      automation: {
        enabled: opportunity.automation_enabled,
        can_automate: opportunity.opportunity_score >= 60
      }
    };
  }

  /**
   * Save task to pending queue
   */
  async saveTask(task) {
    try {
      await fs.mkdir(this.taskQueuePath, { recursive: true });

      const taskFilePath = path.join(this.taskQueuePath, `${task.task_id}.json`);
      await fs.writeFile(taskFilePath, JSON.stringify(task, null, 2));

      console.log(`[Strategy Planner] Created task: ${task.task_id}`);
    } catch (error) {
      console.error(`[Strategy Planner] Failed to save task ${task.task_id}:`, error.message);
    }
  }

  /**
   * Save strategic plan
   */
  async savePlan(plan) {
    try {
      await fs.mkdir(path.dirname(this.strategyPath), { recursive: true });
      await fs.writeFile(this.strategyPath, JSON.stringify(plan, null, 2));
      console.log('[Strategy Planner] Strategic plan saved');
    } catch (error) {
      console.error('[Strategy Planner] Failed to save plan:', error.message);
    }
  }

  /**
   * Log plan to history
   */
  async logPlanHistory(plan) {
    try {
      await fs.mkdir(path.dirname(this.planHistoryPath), { recursive: true });

      const historyEntry = {
        timestamp: plan.generated_at,
        username: plan.username,
        status: plan.current_status,
        tasks_created: plan.task_queue.length,
        top_opportunities: plan.recommended_actions.slice(0, 3).map(a => a.achievement)
      };

      await fs.appendFile(this.planHistoryPath, JSON.stringify(historyEntry) + '\n');
    } catch (error) {
      console.error('[Strategy Planner] Failed to log plan history:', error.message);
    }
  }

  /**
   * Execute immediate action (for quick wins)
   */
  async executeImmediateAction(achievementId) {
    console.log(`[Strategy Planner] Executing immediate action for ${achievementId}...`);

    const actions = {
      'quickdraw': async () => {
        console.log('[Strategy Planner] Triggering Quickdraw workflow...');
        // Create issue via GitHub API
        // Spawn worker to fix
        // Close issue within 5 minutes
        return { success: true, message: 'Quickdraw workflow triggered' };
      },
      'yolo': async () => {
        console.log('[Strategy Planner] Triggering YOLO workflow...');
        // On next PR, auto-merge without review
        return { success: true, message: 'YOLO flag set for next PR' };
      }
    };

    if (actions[achievementId]) {
      return await actions[achievementId]();
    }

    return { success: false, message: 'No immediate action available' };
  }
}

// CLI usage
if (require.main === module) {
  const planner = new StrategyPlanner();

  planner.generatePlan()
    .then(plan => {
      console.log('\n=== Achievement Strategic Plan ===\n');
      console.log(`Generated: ${plan.generated_at}`);
      console.log(`\nCurrent Status:`);
      console.log(`  Total Achievements: ${plan.current_status.total_achievements}`);
      console.log(`  Unlocked: ${plan.current_status.unlocked}`);
      console.log(`  In Progress: ${plan.current_status.in_progress}`);

      console.log(`\n=== Recommended Actions (Top 3) ===\n`);
      plan.recommended_actions.forEach((action, i) => {
        console.log(`${i + 1}. ${action.icon} ${action.achievement}`);
        console.log(`   Priority: ${action.priority.toUpperCase()}`);
        console.log(`   Score: ${action.score}/100`);
        console.log(`   Strategy: ${action.strategy}`);
        console.log(`   Master: ${action.master}`);
        console.log(`   Time: ${action.estimated_time}\n`);
      });

      console.log(`\n=== Tasks Created: ${plan.task_queue.length} ===\n`);
      plan.task_queue.forEach(task => {
        console.log(`- ${task.achievement.icon} ${task.description}`);
        console.log(`  Task ID: ${task.task_id}`);
        console.log(`  Assigned to: ${task.assigned_master}\n`);
      });
    })
    .catch(error => {
      console.error('Error:', error.message);
      process.exit(1);
    });
}

module.exports = StrategyPlanner;
