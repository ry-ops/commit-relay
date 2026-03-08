#!/usr/bin/env python3
"""
Task Health Monitoring Demo

This example demonstrates comprehensive task health monitoring capabilities,
including detection of stalled tasks, unassigned pending tasks, and system-wide
health assessment.

Usage:
    python examples/health_monitoring_demo.py
"""

from commit_relay import (
    CommitRelayClient,
    TaskManager,
    TaskHealthMonitor,
    TaskStatus
)


def print_separator(title=None):
    """Print a visual separator with optional title."""
    if title:
        print(f"\n{'=' * 60}")
        print(f"{title.center(60)}")
        print('=' * 60)
    else:
        print('=' * 60)


def print_health_report(report):
    """Pretty print a health report."""
    print(f"\nTask Summary:")
    summary = report.get('summary', {})
    print(f"  Total Tasks: {summary.get('total_tasks', 0)}")
    print(f"  Pending: {summary.get('pending', 0)}")
    print(f"  In Progress: {summary.get('in_progress', 0)}")
    print(f"  Completed: {summary.get('completed', 0)}")
    print(f"  Failed: {summary.get('failed', 0)}")

    # Issues section
    issues = report.get('issues', {})

    stalled = issues.get('stalled_tasks', [])
    if stalled:
        print(f"\n⚠️  Stalled Tasks ({len(stalled)}):")
        for task in stalled:
            print(f"  - {task['task_id']}: {task['title']}")
            print(f"    Age: {task['age_minutes']:.1f} minutes")
            print(f"    Assigned to: {task.get('assigned_to', 'N/A')}")
    else:
        print(f"\n✅ No stalled tasks detected")

    unassigned = issues.get('unassigned_pending', [])
    if unassigned:
        print(f"\n⚠️  Unassigned Pending Tasks ({len(unassigned)}):")
        for task in unassigned:
            print(f"  - {task['task_id']}: {task['title']}")
            print(f"    Priority: {task['priority']}")
            print(f"    Age: {task['age_minutes']:.1f} minutes")
    else:
        print(f"\n✅ All pending tasks are assigned")

    old_pending = issues.get('old_pending', [])
    if old_pending:
        print(f"\n⚠️  Old Pending Tasks ({len(old_pending)}):")
        for task in old_pending:
            print(f"  - {task['task_id']}: waiting {task['age_minutes']:.1f} minutes")
            print(f"    Priority: {task['priority']}")

    # Recommendations
    recommendations = report.get('recommendations', [])
    if recommendations:
        print(f"\n💡 Recommendations:")
        for rec in recommendations:
            print(f"  - {rec}")
    else:
        print(f"\n✅ No recommendations - system is healthy")

    # Overall health
    overall = report.get('overall_health', 'UNKNOWN')
    health_emoji = {
        'HEALTHY': '✅',
        'WARNING': '⚠️',
        'CRITICAL': '🚨',
        'UNKNOWN': '❓'
    }
    emoji = health_emoji.get(overall, '❓')
    print(f"\n{emoji} Overall Health: {overall}")


def main():
    """Run health monitoring demonstration."""
    print_separator("TASK HEALTH MONITORING")

    # Initialize
    try:
        client = CommitRelayClient(base_url='http://localhost:3000')
        manager = TaskManager(auto_commit=False)
        health = TaskHealthMonitor(manager, client)
    except Exception as e:
        print(f"\nError: Failed to initialize: {e}")
        print("\nNote: This demo reads from the commit-relay task queue.")
        return

    # Get health report
    print("\n1. Generating comprehensive health report...")
    try:
        report = health.get_health_report()
        print_health_report(report)
    except Exception as e:
        print(f"   Error: {e}")
        return

    # Check specific task health (if any tasks exist)
    print_separator("INDIVIDUAL TASK HEALTH")

    all_tasks = manager.get_all_tasks()
    if all_tasks:
        # Check first few tasks
        print("\nChecking individual task health...")
        for task in all_tasks[:3]:  # Check first 3 tasks
            task_id = task['id']
            print(f"\n  Task: {task_id}")

            try:
                task_health = health.get_task_health_status(task_id)

                print(f"    Status: {task_health.get('status', 'unknown')}")
                print(f"    Age: {task_health.get('age_minutes', 0):.1f} minutes")
                print(f"    Healthy: {task_health.get('is_healthy', 'unknown')}")

                warnings = task_health.get('warnings', [])
                if warnings:
                    print(f"    Warnings:")
                    for warning in warnings:
                        print(f"      - {warning}")

                recs = task_health.get('recommendations', [])
                if recs:
                    print(f"    Recommendations:")
                    for rec in recs:
                        print(f"      - {rec}")

            except Exception as e:
                print(f"    Error: {e}")
    else:
        print("\n  No tasks found in queue")

    # Get task statistics
    print_separator("TASK STATISTICS")

    try:
        stats = health.get_task_statistics()

        print(f"\nOverall Statistics:")
        print(f"  Total Tasks: {stats.get('total_tasks', 0)}")
        print(f"  Completed Tasks: {stats.get('completed_tasks', 0)}")

        avg_duration = stats.get('avg_duration_minutes', 0)
        min_duration = stats.get('min_duration_minutes', 0)
        max_duration = stats.get('max_duration_minutes', 0)

        print(f"\nExecution Times:")
        print(f"  Average Duration: {avg_duration:.2f} minutes")
        print(f"  Min Duration: {min_duration:.2f} minutes")
        print(f"  Max Duration: {max_duration:.2f} minutes")

        task_types = stats.get('task_types', {})
        if task_types:
            print(f"\nTask Types:")
            for task_type, count in task_types.items():
                print(f"  {task_type}: {count}")

        priorities = stats.get('task_priorities', {})
        if priorities:
            print(f"\nTask Priorities:")
            for priority, count in priorities.items():
                print(f"  {priority}: {count}")

    except Exception as e:
        print(f"Error getting statistics: {e}")

    # Summary
    print_separator("SUMMARY")

    print("\nThis demo demonstrated:")
    print("  ✅ Comprehensive health report generation")
    print("  ✅ Stalled task detection")
    print("  ✅ Unassigned pending task detection")
    print("  ✅ Individual task health checking")
    print("  ✅ Task statistics and analytics")
    print("  ✅ Health recommendations")

    print("\nHealth Monitoring Use Cases:")
    print("  - Detect stalled or stuck tasks")
    print("  - Identify worker capacity issues")
    print("  - Monitor task execution times")
    print("  - Track system health trends")
    print("  - Automated alerting on issues")

    print("\nFor more examples, see:")
    print("  - examples/complete_workflow.py")
    print("  - examples/event_streaming_demo.py")


if __name__ == '__main__':
    main()
