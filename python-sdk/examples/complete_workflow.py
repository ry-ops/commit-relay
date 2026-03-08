#!/usr/bin/env python3
"""
Complete Task Lifecycle Demo - Create, Monitor, Track Events

This example demonstrates the complete task lifecycle from creation through
monitoring, health checking, and event tracking. It uses the high-level
TaskLifecycleManager API for simplified task management.

Usage:
    python examples/complete_workflow.py
"""

from commit_relay import (
    CommitRelayClient,
    TaskLifecycleManager,
    TaskPriority
)
import sys


def print_separator(title=None):
    """Print a visual separator with optional title."""
    if title:
        print(f"\n{'=' * 60}")
        print(f"{title.center(60)}")
        print('=' * 60)
    else:
        print('=' * 60)


def main():
    """Run complete workflow demonstration."""
    print_separator("COMPLETE TASK LIFECYCLE DEMONSTRATION")

    # Initialize
    try:
        client = CommitRelayClient(base_url='http://localhost:3000')
        lifecycle = TaskLifecycleManager(client, auto_commit=False)
    except Exception as e:
        print(f"\nError: Failed to initialize: {e}")
        print("\nNote: This demo requires commit-relay to be set up.")
        print("      Set auto_commit=False to skip git operations.")
        sys.exit(1)

    # Step 1: Create and monitor task
    print("\n1. Creating security scan task...")
    print("   Repository: ry-ops/mcp-server-unifi")
    print("   Priority: HIGH")
    print("   Wait for completion: YES (5 minute timeout)")

    try:
        result = lifecycle.create_and_monitor(
            task_type='security-scan',
            repository='ry-ops/mcp-server-unifi',
            priority=TaskPriority.HIGH,
            wait_for_completion=True,
            timeout=300  # 5 minutes
        )
    except Exception as e:
        print(f"\n   Error during task creation: {e}")
        sys.exit(1)

    # Step 2: Show task results
    print(f"\n2. Task Results:")
    print(f"   Task ID: {result['task_id']}")
    print(f"   Final Status: {result['final_status']}")

    if result.get('error'):
        print(f"   Error: {result['error']}")

    # Step 3: Display execution metrics
    if result.get('metrics'):
        print(f"\n3. Execution Metrics:")
        metrics = result['metrics']
        for key, value in metrics.items():
            if key == 'age_minutes' or key == 'duration_minutes':
                print(f"   {key}: {value:.2f} minutes")
            else:
                print(f"   {key}: {value}")

    # Step 4: Show events
    if result.get('events'):
        print(f"\n4. Events ({len(result['events'])} total):")
        # Show first 5 events
        for event in result['events'][:5]:
            event_type = event.get('type', 'unknown')
            timestamp = event.get('timestamp', 'N/A')
            print(f"   - {event_type}: {timestamp}")

        if len(result['events']) > 5:
            print(f"   ... and {len(result['events']) - 5} more events")

    # Step 5: Get comprehensive status
    print(f"\n5. Comprehensive Status:")
    try:
        status = lifecycle.get_comprehensive_status(result['task_id'])

        if status.get('health'):
            health = status['health']
            print(f"   Healthy: {health.get('is_healthy', 'unknown')}")

            if health.get('warnings'):
                print(f"   Warnings:")
                for warning in health['warnings']:
                    print(f"     - {warning}")

            if health.get('recommendations'):
                print(f"   Recommendations:")
                for rec in health['recommendations']:
                    print(f"     - {rec}")

    except Exception as e:
        print(f"   Error getting comprehensive status: {e}")

    # Step 6: Get system health summary
    print(f"\n6. System Health Summary:")
    try:
        system_health = lifecycle.get_system_health_summary()

        print(f"   Overall Health: {system_health.get('overall_health', 'unknown')}")

        if system_health.get('summary'):
            summary = system_health['summary']
            print(f"   Total Tasks: {summary.get('total_tasks', 0)}")
            print(f"   Pending: {summary.get('pending', 0)}")
            print(f"   In Progress: {summary.get('in_progress', 0)}")
            print(f"   Completed: {summary.get('completed', 0)}")
            print(f"   Failed: {summary.get('failed', 0)}")

        if system_health.get('recommendations'):
            print(f"\n   System Recommendations:")
            for rec in system_health['recommendations'][:3]:  # Show top 3
                print(f"     - {rec}")

    except Exception as e:
        print(f"   Error getting system health: {e}")

    print_separator("WORKFLOW COMPLETE")

    # Print summary
    print(f"\nSummary:")
    print(f"  Task ID: {result['task_id']}")
    print(f"  Status: {result['final_status']}")

    if result.get('metrics', {}).get('duration_minutes'):
        duration = result['metrics']['duration_minutes']
        print(f"  Duration: {duration:.2f} minutes")

    print(f"\nThis demo showed:")
    print(f"  - Task creation with TaskLifecycleManager")
    print(f"  - Real-time execution monitoring")
    print(f"  - Execution metrics collection")
    print(f"  - Event tracking")
    print(f"  - Health status checking")
    print(f"  - System-wide health monitoring")

    print(f"\nFor more examples, see:")
    print(f"  - examples/health_monitoring_demo.py")
    print(f"  - examples/event_streaming_demo.py")


if __name__ == '__main__':
    main()
