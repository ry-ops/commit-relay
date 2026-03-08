#!/usr/bin/env python3
"""
Example: Batch Task Creation

Demonstrates how to create multiple tasks in batch operations,
useful for automating repetitive task creation workflows.
"""

import sys
import json
from pathlib import Path
from commit_relay import TaskManager, TaskPriority, TaskBuilder


def batch_security_scans():
    """Create security scan tasks for multiple repositories."""

    print("=" * 70)
    print("Batch Security Scans")
    print("=" * 70)
    print()

    manager = TaskManager()

    # Repositories to scan
    repositories = [
        'ry-ops/mcp-server-unifi',
        'ry-ops/n8n-mcp-server',
        'ry-ops/commit-relay',
        'ry-ops/another-repo',
        'ry-ops/test-repo'
    ]

    print(f"Creating security scans for {len(repositories)} repositories...")
    print()

    task_ids = []
    for i, repo in enumerate(repositories, 1):
        print(f"[{i}/{len(repositories)}] Creating scan for {repo}...")

        task_id = manager.create_security_scan(
            repository=repo,
            priority=TaskPriority.HIGH,
            scan_types=['dependencies', 'secrets'],
            description=f'Automated weekly security scan - {repo}'
        )

        task_ids.append({
            'repository': repo,
            'task_id': task_id
        })

        print(f"           Created: {task_id}")
        print()

    # Summary
    print("=" * 70)
    print("Batch Creation Summary")
    print("=" * 70)
    print()
    print(f"Successfully created {len(task_ids)} security scan tasks:")
    print()

    for item in task_ids:
        print(f"  {item['task_id']}: {item['repository']}")

    print()
    print("All tasks are pending and will be picked up by the worker daemon.")
    print()

    return task_ids


def batch_from_json_file(json_file_path):
    """Create tasks from a JSON configuration file."""

    print("=" * 70)
    print("Batch Task Creation from JSON")
    print("=" * 70)
    print()

    manager = TaskManager()

    # Load JSON file
    print(f"Loading tasks from: {json_file_path}")
    with open(json_file_path, 'r') as f:
        config = json.load(f)

    tasks_config = config.get('tasks', [])
    print(f"Found {len(tasks_config)} tasks to create")
    print()

    task_ids = []

    for i, task_config in enumerate(tasks_config, 1):
        task_type = task_config.get('type')
        print(f"[{i}/{len(tasks_config)}] Creating {task_type} task...")

        try:
            # Build task using TaskBuilder for flexibility
            builder = TaskBuilder(manager)

            # Set task type
            if task_type == 'security-scan':
                builder.security_scan()
            elif task_type == 'security-fix':
                builder.security_fix()
            elif task_type == 'development':
                builder.development()
            elif task_type == 'catalog':
                builder.catalog()
            else:
                print(f"  Skipping unknown task type: {task_type}")
                continue

            # Set common fields
            builder.repository(task_config['repository'])

            if 'branch' in task_config:
                builder.branch(task_config['branch'])

            if 'priority' in task_config:
                priority_map = {
                    'critical': TaskPriority.CRITICAL,
                    'high': TaskPriority.HIGH,
                    'medium': TaskPriority.MEDIUM,
                    'low': TaskPriority.LOW
                }
                builder.priority(priority_map.get(task_config['priority'], TaskPriority.HIGH))

            if 'description' in task_config:
                builder.description(task_config['description'])

            # Set task-specific fields
            if task_type == 'security-scan' and 'scan_types' in task_config:
                builder.scan_types(task_config['scan_types'])

            if task_type == 'development' and 'requirements' in task_config:
                builder.requirements(task_config['requirements'])

            if task_type == 'catalog' and 'catalog_depth' in task_config:
                builder.catalog_depth(task_config['catalog_depth'])

            # Create task
            task_id = builder.create()
            task_ids.append(task_id)

            print(f"           Created: {task_id}")
            print()

        except Exception as e:
            print(f"  Error creating task: {e}")
            continue

    # Summary
    print("=" * 70)
    print("Batch Creation Summary")
    print("=" * 70)
    print()
    print(f"Successfully created {len(task_ids)} tasks from JSON file:")
    print()

    for task_id in task_ids:
        print(f"  {task_id}")

    print()

    return task_ids


def create_weekly_maintenance_tasks():
    """Create a set of weekly maintenance tasks."""

    print("=" * 70)
    print("Weekly Maintenance Tasks")
    print("=" * 70)
    print()

    manager = TaskManager()

    repositories = [
        'ry-ops/mcp-server-unifi',
        'ry-ops/n8n-mcp-server',
        'ry-ops/commit-relay'
    ]

    print(f"Creating weekly maintenance tasks for {len(repositories)} repositories...")
    print()

    task_ids = []

    for repo in repositories:
        print(f"Repository: {repo}")

        # 1. Security scan
        scan_id = manager.create_security_scan(
            repository=repo,
            priority=TaskPriority.HIGH,
            scan_types=['dependencies', 'static-analysis', 'secrets'],
            description=f'Weekly security scan - {repo}'
        )
        task_ids.append(scan_id)
        print(f"  Security scan: {scan_id}")

        # 2. Catalog update
        catalog_id = manager.create_catalog_task(
            repository=repo,
            catalog_depth='quick',
            priority=TaskPriority.LOW,
            description=f'Weekly catalog update - {repo}'
        )
        task_ids.append(catalog_id)
        print(f"  Catalog update: {catalog_id}")

        print()

    # Summary
    print("=" * 70)
    print("Weekly Maintenance Summary")
    print("=" * 70)
    print()
    print(f"Created {len(task_ids)} maintenance tasks:")
    print(f"  - {len(repositories)} security scans")
    print(f"  - {len(repositories)} catalog updates")
    print()

    return task_ids


def create_sample_json_config():
    """Create a sample JSON configuration file for batch task creation."""

    config = {
        "description": "Sample batch task configuration",
        "tasks": [
            {
                "type": "security-scan",
                "repository": "ry-ops/mcp-server-unifi",
                "priority": "high",
                "scan_types": ["dependencies", "secrets"],
                "description": "Security scan from JSON config"
            },
            {
                "type": "development",
                "repository": "ry-ops/commit-relay",
                "branch": "feature/new-feature",
                "priority": "medium",
                "requirements": [
                    "Implement new feature",
                    "Add tests",
                    "Update documentation"
                ],
                "description": "Development task from JSON config"
            },
            {
                "type": "catalog",
                "repository": "ry-ops/new-repo",
                "priority": "low",
                "catalog_depth": "deep",
                "description": "Catalog task from JSON config"
            }
        ]
    }

    config_path = Path('/tmp/commit-relay-batch-tasks.json')
    with open(config_path, 'w') as f:
        json.dump(config, f, indent=2)

    print(f"Sample configuration created at: {config_path}")
    print()
    print("Configuration contents:")
    print(json.dumps(config, indent=2))
    print()

    return config_path


def main():
    """Run batch task creation demonstrations."""

    print("=" * 70)
    print("Commit-Relay: Batch Task Creation Demo")
    print("=" * 70)
    print()
    print("This demo shows different batch task creation patterns:")
    print("  1. Batch security scans for multiple repositories")
    print("  2. Create tasks from JSON configuration file")
    print("  3. Weekly maintenance task automation")
    print("  4. Create sample JSON configuration")
    print()

    # Choose which demo to run
    print("Select batch operation:")
    print("  1. Batch Security Scans")
    print("  2. Create Tasks from JSON File")
    print("  3. Weekly Maintenance Tasks")
    print("  4. Create Sample JSON Config (no task creation)")
    print()

    choice = input("Enter choice (1-4): ").strip()
    print()

    if choice == '1':
        batch_security_scans()

    elif choice == '2':
        # First create sample config
        print("Creating sample JSON configuration...")
        config_path = create_sample_json_config()

        print("Now creating tasks from this configuration...")
        print()
        batch_from_json_file(config_path)

    elif choice == '3':
        create_weekly_maintenance_tasks()

    elif choice == '4':
        create_sample_json_config()

    else:
        print("Invalid choice. Running batch security scans...")
        batch_security_scans()


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        print("\n\nInterrupted by user")
        sys.exit(1)
    except Exception as e:
        print(f"\nError: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc()
        sys.exit(1)
