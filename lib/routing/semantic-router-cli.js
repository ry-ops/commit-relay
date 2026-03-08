#!/usr/bin/env node

/**
 * Semantic Router CLI
 *
 * Command-line interface for semantic routing that can be called from bash scripts.
 * Outputs compact JSON for easy parsing in shell scripts.
 *
 * Usage:
 *   node semantic-router-cli.js "Fix authentication bug"
 *   node semantic-router-cli.js --task-id task-123 --description "Implement JWT"
 */

const { SemanticRouter } = require('./semantic-router');

async function main() {
  const args = process.argv.slice(2);

  if (args.length === 0 || args[0] === '--help' || args[0] === '-h') {
    printUsage();
    process.exit(0);
  }

  // Parse arguments
  let taskId = `semantic-${Date.now()}`;
  let taskDescription = '';

  if (args[0] === '--task-id') {
    if (args.length < 2) {
      console.error('Error: --task-id requires a value');
      process.exit(1);
    }
    taskId = args[1];

    if (args[2] === '--description' || args[2] === '-d') {
      if (args.length < 4) {
        console.error('Error: --description requires a value');
        process.exit(1);
      }
      taskDescription = args.slice(3).join(' ');
    } else {
      taskDescription = args.slice(2).join(' ');
    }
  } else if (args[0] === '--description' || args[0] === '-d') {
    if (args.length < 2) {
      console.error('Error: --description requires a value');
      process.exit(1);
    }
    taskDescription = args.slice(1).join(' ');
  } else {
    // Simple case: all args are the task description
    taskDescription = args.join(' ');
  }

  if (!taskDescription.trim()) {
    console.error('Error: Task description required');
    printUsage();
    process.exit(1);
  }

  try {
    const router = new SemanticRouter();
    await router.initialize();

    const task = {
      id: taskId,
      description: taskDescription
    };

    const result = await router.route(task);

    // Map master agents to expert names for compatibility with moe-router.sh
    const masterToExpert = {
      'security-master': 'security',
      'development-master': 'development',
      'inventory-master': 'inventory',
      'cicd-master': 'cicd',
      'coordinator-master': 'coordinator'
    };

    const expert = masterToExpert[result.master] || result.master.replace('-master', '');

    // Output compact JSON that bash can parse
    const output = {
      task_id: taskId,
      master: result.master,
      expert: expert,
      confidence: result.confidence,
      method: result.method,
      confidence_level: result.confidence_level
    };

    // Include alternatives if present
    if (result.alternatives && result.alternatives.length > 0) {
      output.alternatives = result.alternatives.slice(0, 3).map(alt => ({
        master: alt.master,
        expert: masterToExpert[alt.master] || alt.master.replace('-master', ''),
        confidence: alt.confidence
      }));
    }

    // Output as single-line JSON for easy bash parsing
    console.log(JSON.stringify(output));

    // Exit with success
    process.exit(0);
  } catch (error) {
    // Output error as JSON
    console.error(JSON.stringify({
      error: error.message,
      stack: error.stack
    }));
    process.exit(1);
  }
}

function printUsage() {
  console.log(`
Semantic Router CLI

Usage:
  node semantic-router-cli.js <task-description>
      Route a task using semantic routing

  node semantic-router-cli.js --task-id <id> <task-description>
      Route a task with specific task ID

  node semantic-router-cli.js --task-id <id> --description <description>
      Route a task with explicit flags

Options:
  --task-id, -t      Task ID (default: auto-generated)
  --description, -d  Task description
  --help, -h         Show this help message

Output:
  Compact JSON with routing decision:
  {
    "task_id": "task-123",
    "master": "security-master",
    "expert": "security",
    "confidence": 0.85,
    "method": "semantic",
    "confidence_level": "high"
  }

Examples:
  node semantic-router-cli.js "Fix authentication bug"
  node semantic-router-cli.js --task-id task-123 "Implement JWT authentication"
  node semantic-router-cli.js --task-id task-456 --description "Scan for CVE-2024-12345"

Exit Codes:
  0  Success
  1  Error (invalid arguments or routing failure)
  `.trim());
}

// Run main
main().catch(error => {
  console.error(JSON.stringify({
    error: error.message,
    stack: error.stack
  }));
  process.exit(1);
});
