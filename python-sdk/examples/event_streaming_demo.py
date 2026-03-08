#!/usr/bin/env python3
"""
Real-time Event Streaming Demo

This example demonstrates event streaming and monitoring capabilities,
including reading recent events, filtering by task or type, and watching
for events in real-time.

Usage:
    python examples/event_streaming_demo.py
"""

from commit_relay import EventStream, TaskManager
import time


def print_separator(title=None):
    """Print a visual separator with optional title."""
    if title:
        print(f"\n{'=' * 60}")
        print(f"{title.center(60)}")
        print('=' * 60)
    else:
        print('=' * 60)


def print_event(event):
    """Pretty print an event."""
    event_type = event.get('type', 'unknown')
    timestamp = event.get('timestamp', 'N/A')
    event_id = event.get('id', 'N/A')

    print(f"  [{timestamp}] {event_type}")
    print(f"    ID: {event_id}")

    data = event.get('data', {})
    if isinstance(data, dict):
        for key, value in data.items():
            # Truncate long values
            value_str = str(value)
            if len(value_str) > 60:
                value_str = value_str[:57] + '...'
            print(f"    {key}: {value_str}")
    elif isinstance(data, str) and data:
        # Truncate long strings
        if len(data) > 60:
            data = data[:57] + '...'
        print(f"    data: {data}")


def main():
    """Run event streaming demonstration."""
    print_separator("EVENT STREAMING DEMO")

    # Initialize
    try:
        stream = EventStream()
        manager = TaskManager(auto_commit=False)
    except Exception as e:
        print(f"\nError: Failed to initialize: {e}")
        print("\nNote: This demo reads from the commit-relay event log.")
        return

    # Section 1: Recent Events
    print("\n1. Recent Events (last 10):")

    try:
        events = stream.get_recent_events(limit=10)

        if events:
            print(f"   Found {len(events)} events")
            for event in events:
                event_type = event.get('type', 'unknown')
                timestamp = event.get('timestamp', 'N/A')
                print(f"     [{timestamp}] {event_type}")
        else:
            print("   No events found in event log")

    except Exception as e:
        print(f"   Error: {e}")

    # Section 2: Task-Specific Events
    print_separator("TASK-SPECIFIC EVENTS")

    all_tasks = manager.get_all_tasks()
    if all_tasks:
        # Get events for first task
        task = all_tasks[0]
        task_id = task['id']

        print(f"\nEvents for {task_id}:")
        print(f"  Task: {task.get('title', 'N/A')}")
        print(f"  Status: {task.get('status', 'unknown')}")

        try:
            task_events = stream.get_task_events(task_id)

            if task_events:
                print(f"\n  Found {len(task_events)} events:")
                for event in task_events[:5]:  # Show first 5
                    print_event(event)

                if len(task_events) > 5:
                    print(f"\n  ... and {len(task_events) - 5} more events")
            else:
                print(f"\n  No events found for this task")

        except Exception as e:
            print(f"  Error: {e}")
    else:
        print("\n  No tasks found in queue")

    # Section 3: Events by Type
    print_separator("EVENTS BY TYPE")

    print("\nSearching for specific event types...")

    event_types_to_check = [
        'task_created',
        'task_completed',
        'worker_spawned',
        'health_check'
    ]

    for event_type in event_types_to_check:
        try:
            events = stream.get_events_by_type(event_type, limit=100)
            print(f"  {event_type}: {len(events)} events")
        except Exception as e:
            print(f"  {event_type}: Error - {e}")

    # Section 4: Event Summary
    print_separator("EVENT SUMMARY")

    print("\nLast 24 Hours:")
    try:
        summary = stream.get_event_summary(hours=24)

        print(f"  Total Events: {summary.get('total_events', 0)}")
        print(f"  Time Range: {summary.get('time_range_hours', 0)} hours")

        most_common = summary.get('most_common_type')
        if most_common:
            print(f"  Most Common: {most_common}")

        by_type = summary.get('by_type', {})
        if by_type:
            print(f"\n  Events by Type:")
            # Sort by count descending
            sorted_types = sorted(
                by_type.items(),
                key=lambda x: x[1],
                reverse=True
            )
            for event_type, count in sorted_types[:10]:  # Top 10
                print(f"    {event_type}: {count}")

    except Exception as e:
        print(f"  Error: {e}")

    # Section 5: Real-time Event Watching (optional demo)
    print_separator("REAL-TIME EVENT WATCHING")

    print("\nDemo: Watch for new events (10 seconds)...")
    print("(In production, you would typically run this continuously)")

    event_count = [0]  # Use list to allow modification in closure

    def handle_event(event):
        """Callback for new events."""
        event_count[0] += 1
        event_type = event.get('type', 'unknown')
        timestamp = event.get('timestamp', 'N/A')
        print(f"  New event: [{timestamp}] {event_type}")

    try:
        # Watch for 10 seconds
        print("\n  Watching...")
        stream.watch_all_events(
            on_event=handle_event,
            timeout=10,
            poll_interval=2
        )

        if event_count[0] == 0:
            print("  No new events during watch period")
        else:
            print(f"\n  Detected {event_count[0]} new events")

    except Exception as e:
        print(f"  Error: {e}")

    # Section 6: Tail Events Demo
    print_separator("EVENT TAIL DEMO")

    print("\nTail last 5 events (like 'tail' command):")

    try:
        tail_count = [0]

        def print_tail_event(event):
            """Callback for tail."""
            tail_count[0] += 1
            if tail_count[0] <= 5:  # Limit output
                event_type = event.get('type', 'unknown')
                timestamp = event.get('timestamp', 'N/A')
                print(f"  [{timestamp}] {event_type}")

        # Get recent events without following
        stream.tail_events(
            on_event=print_tail_event,
            follow=False
        )

        if tail_count[0] == 0:
            print("  No events in log")

    except Exception as e:
        print(f"  Error: {e}")

    # Summary
    print_separator("SUMMARY")

    print("\nThis demo demonstrated:")
    print("  ✅ Reading recent events")
    print("  ✅ Filtering events by task")
    print("  ✅ Filtering events by type")
    print("  ✅ Event summary statistics")
    print("  ✅ Real-time event watching")
    print("  ✅ Tailing event log")

    print("\nEvent Streaming Use Cases:")
    print("  - Real-time monitoring dashboards")
    print("  - Task progress tracking")
    print("  - Debugging and troubleshooting")
    print("  - Audit logging")
    print("  - Integration with external systems")
    print("  - Automated alerting and notifications")

    print("\nTo continuously watch events, use:")
    print("  stream.watch_all_events(on_event=handler, timeout=None)")

    print("\nFor more examples, see:")
    print("  - examples/complete_workflow.py")
    print("  - examples/health_monitoring_demo.py")


if __name__ == '__main__':
    main()
