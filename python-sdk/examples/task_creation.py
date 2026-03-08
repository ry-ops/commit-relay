#!/usr/bin/env python3
"""
Example: Programmatic Task Creation

Demonstrates how to create tasks programmatically using the TaskManager API.
Shows various task types and configuration options.
"""

import sys
from commit_relay import TaskManager, TaskPriority, TaskBuilder

def main():
    """Demonstrate task creation with TaskManager."""

    print("=" * 70)
    print("Commit-Relay: Programmatic Task Creation Demo")
    print("=" * 70)
    print()

    # Initialize task manager
    print("Initializing TaskManager...")
    manager = TaskManager(
        commit_relay_home='/Users/ryandahlberg/commit-relay',
        auto_commit=True
    )
    print("TaskManager initialized.")
    print()

    # Example 1: Create security scan task (direct method)
    print("-" * 70)
    print("Example 1: Security Scan Task (Direct Method)")
    print("-" * 70)
    print()

    print("Creating security scan task for ry-ops/mcp-server-unifi...")
    task_id_1 = manager.create_security_scan(
        repository='ry-ops/mcp-server-unifi',
        branch='main',
        scan_types=['dependencies', 'secrets'],
        priority=TaskPriority.HIGH,
        description='Weekly security audit - MCP Server UniFi'
    )
    print(f"Created task: {task_id_1}")
    print()

    # Example 2: Create development task (direct method)
    print("-" * 70)
    print("Example 2: Development Task (Direct Method)")
    print("-" * 70)
    print()

    print("Creating development task...")
    task_id_2 = manager.create_development_task(
        repository='ry-ops/commit-relay',
        branch='main',
        requirements=[
            'Add task scheduling system',
            'Implement recurring task support',
            'Add cron-like syntax for schedules'
        ],
        priority=TaskPriority.MEDIUM,
        description='Implement task scheduling feature'
    )
    print(f"Created task: {task_id_2}")
    print()

    # Example 3: Create task using fluent API (TaskBuilder)
    print("-" * 70)
    print("Example 3: Security Scan with Fluent API (TaskBuilder)")
    print("-" * 70)
    print()

    print("Creating task using fluent API...")
    task_id_3 = (TaskBuilder(manager)
                 .security_scan()
                 .repository('ry-ops/n8n-mcp-server')
                 .branch('main')
                 .priority(TaskPriority.CRITICAL)
                 .scan_types(['dependencies', 'static-analysis', 'secrets'])
                 .description('Critical security audit - n8n MCP Server')
                 .create())
    print(f"Created task: {task_id_3}")
    print()

    # Example 4: Create catalog task
    print("-" * 70)
    print("Example 4: Catalog Task")
    print("-" * 70)
    print()

    print("Creating catalog task...")
    task_id_4 = manager.create_catalog_task(
        repository='ry-ops/new-repo',
        catalog_depth='deep',
        priority=TaskPriority.LOW,
        description='Deep catalog of new repository'
    )
    print(f"Created task: {task_id_4}")
    print()

    # Query pending tasks
    print("-" * 70)
    print("Querying Pending Tasks")
    print("-" * 70)
    print()

    pending_tasks = manager.get_pending_tasks()
    print(f"Found {len(pending_tasks)} pending tasks:")
    print()

    for task in pending_tasks[-4:]:  # Show last 4 pending tasks
        print(f"  Task: {task['id']}")
        print(f"  Type: {task['type']}")
        print(f"  Title: {task['title']}")
        print(f"  Priority: {task['priority']}")
        print(f"  Repository: {task['context'].get('repository', 'N/A')}")
        print()

    # Summary
    print("=" * 70)
    print("Task Creation Summary")
    print("=" * 70)
    print()
    print(f"Created {4} tasks:")
    print(f"  1. {task_id_1} - Security scan (direct method)")
    print(f"  2. {task_id_2} - Development task (direct method)")
    print(f"  3. {task_id_3} - Security scan (fluent API)")
    print(f"  4. {task_id_4} - Catalog task")
    print()
    print("Next steps:")
    print("  - Worker daemon will pick up tasks within 30 seconds")
    print("  - Monitor progress at: http://localhost:3000")
    print("  - Check logs: tail -f agents/logs/system/worker-daemon.log")
    print()


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        print("\nInterrupted by user")
        sys.exit(1)
    except Exception as e:
        print(f"\nError: {e}", file=sys.stderr)
        sys.exit(1)
