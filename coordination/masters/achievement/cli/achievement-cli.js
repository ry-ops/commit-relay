#!/usr/bin/env node

const { program } = require('commander');
const chalk = require('chalk');
const ora = require('ora');
const Table = require('cli-table3');
const path = require('path');

// Import achievement modules
const AchievementTracker = require('../lib/achievement-tracker');
const StrategyPlanner = require('../lib/strategy-planner');

program
  .name('achievement-cli')
  .description('GitHub Achievement tracking and automation CLI')
  .version('1.0.0');

program
  .command('status')
  .description('View current achievement progress')
  .option('-d, --detailed', 'Show detailed progress for each achievement')
  .action(async (options) => {
    const spinner = ora('Fetching achievement progress...').start();
    
    try {
      const tracker = new AchievementTracker({
        githubToken: process.env.GITHUB_TOKEN,
        username: process.env.GITHUB_USERNAME || 'ry-ops'
      });
      
      const progress = await tracker.getAllProgress();
      spinner.succeed('Achievement data loaded');
      
      console.log(chalk.bold.cyan('\n🏆 Achievement Progress\n'));
      
      // Summary table
      const summaryTable = new Table({
        head: [chalk.bold('Metric'), chalk.bold('Value')],
        colWidths: [30, 20]
      });
      
      summaryTable.push(
        ['Total Achievements', progress.summary?.total_achievements || 0],
        [chalk.green('Unlocked'), progress.summary?.unlocked || 0],
        [chalk.yellow('In Progress'), progress.summary?.in_progress || 0]
      );
      
      console.log(summaryTable.toString());
      
      if (options.detailed) {
        console.log(chalk.bold.cyan('\n📊 Detailed Progress\n'));
        
        Object.values(progress.achievements || {}).forEach(achievement => {
          if (achievement.unlocked) {
            console.log(chalk.green(`✅ ${achievement.icon} ${achievement.name}`));
          } else if (achievement.progress) {
            const pct = achievement.progress.percentage || 0;
            console.log(chalk.yellow(`⏳ ${achievement.icon} ${achievement.name}: ${pct}% complete`));
          }
        });
      }
      
    } catch (error) {
      spinner.fail('Failed to fetch achievement data');
      console.error(chalk.red(error.message));
      process.exit(1);
    }
  });

program
  .command('opportunities')
  .description('View top achievement opportunities')
  .option('-l, --limit <number>', 'Number of opportunities to show', '5')
  .action(async (options) => {
    const spinner = ora('Analyzing opportunities...').start();
    
    try {
      const tracker = new AchievementTracker({
        githubToken: process.env.GITHUB_TOKEN,
        username: process.env.GITHUB_USERNAME || 'ry-ops'
      });
      
      const opportunities = await tracker.getOpportunityScores();
      spinner.succeed('Opportunities calculated');
      
      console.log(chalk.bold.cyan('\n💡 Top Opportunities\n'));
      
      const table = new Table({
        head: [
          chalk.bold('Rank'),
          chalk.bold('Achievement'),
          chalk.bold('Score'),
          chalk.bold('Strategy')
        ],
        colWidths: [8, 30, 12, 30]
      });
      
      opportunities.top_3.slice(0, parseInt(options.limit)).forEach((opp, idx) => {
        const scoreColor = opp.opportunity_score > 70 ? chalk.green : 
                          opp.opportunity_score > 50 ? chalk.yellow : 
                          chalk.red;
        
        table.push([
          `#${idx + 1}`,
          `${opp.icon} ${opp.name}`,
          scoreColor(`${opp.opportunity_score}/100`),
          opp.strategy
        ]);
      });
      
      console.log(table.toString());
      
    } catch (error) {
      spinner.fail('Failed to analyze opportunities');
      console.error(chalk.red(error.message));
      process.exit(1);
    }
  });

program
  .command('plan')
  .description('Generate strategic achievement plan')
  .action(async () => {
    const spinner = ora('Generating strategic plan...').start();
    
    try {
      const planner = new StrategyPlanner({
        githubToken: process.env.GITHUB_TOKEN,
        username: process.env.GITHUB_USERNAME || 'ry-ops'
      });
      
      const plan = await planner.generatePlan();
      spinner.succeed('Strategic plan generated');
      
      console.log(chalk.bold.cyan('\n📋 Strategic Plan\n'));
      console.log(chalk.bold('Recommended Actions:'));
      plan.recommended_actions.forEach((action, idx) => {
        console.log(chalk.yellow(`${idx + 1}. ${action}`));
      });
      
      if (plan.task_queue && plan.task_queue.length > 0) {
        console.log(chalk.bold.green(`\n✅ ${plan.task_queue.length} tasks created and routed to MoE masters\n`));
      }
      
    } catch (error) {
      spinner.fail('Failed to generate plan');
      console.error(chalk.red(error.message));
      process.exit(1);
    }
  });

program
  .command('execute <workflow>')
  .description('Execute achievement workflow')
  .argument('<workflow>', 'Workflow to execute (quickdraw or pr-automation)')
  .option('-f, --feature <name>', 'Feature name for PR workflow')
  .action(async (workflow, options) => {
    const validWorkflows = ['quickdraw', 'pr-automation'];
    
    if (!validWorkflows.includes(workflow)) {
      console.error(chalk.red(`Invalid workflow: ${workflow}`));
      console.log(chalk.yellow(`Valid workflows: ${validWorkflows.join(', ')}`));
      process.exit(1);
    }
    
    const spinner = ora(`Executing ${workflow} workflow...`).start();
    
    try {
      const { exec } = require('child_process');
      const scriptPath = path.join(__dirname, '..', 'workflows', `${workflow}-workflow.sh`);
      const featureName = options.feature || `auto-${Date.now()}`;
      
      exec(`bash ${scriptPath} ${featureName}`, (error, stdout, stderr) => {
        if (error) {
          spinner.fail(`Workflow execution failed`);
          console.error(chalk.red(stderr));
          process.exit(1);
        }
        
        spinner.succeed(`${workflow} workflow completed`);
        console.log(chalk.green(stdout));
      });
      
    } catch (error) {
      spinner.fail('Workflow execution failed');
      console.error(chalk.red(error.message));
      process.exit(1);
    }
  });

program.parse(process.argv);
