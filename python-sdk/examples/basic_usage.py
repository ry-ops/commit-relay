#!/usr/bin/env python3
"""
Basic usage examples for commit-relay SDK.

This script demonstrates fundamental SDK operations including:
- Connecting to the dashboard API
- Fetching current metrics
- Listing workers and tasks
- Exporting data to pandas DataFrames
"""

from commit_relay import CommitRelayClient


def main():
    print("="*70)
    print("COMMIT-RELAY SDK - BASIC USAGE EXAMPLES")
    print("="*70)
    print()

    # Initialize client
    print("1. Initializing client...")
    client = CommitRelayClient(base_url='http://localhost:3000')

    # Test connectivity
    print("2. Testing API connectivity...")
    if client.ping():
        print("   ✓ API is reachable")
    else:
        print("   ✗ API is not reachable")
        return

    # Get current metrics
    print("\n3. Fetching current metrics...")
    metrics = client.metrics.get_current()
    print(f"   Active Workers: {metrics.get('active_workers', 0)}")
    print(f"   Tasks Pending: {metrics.get('tasks_pending', 0)}")
    print(f"   Tasks In Progress: {metrics.get('tasks_in_progress', 0)}")
    print(f"   Success Rate: {metrics.get('success_rate', 0):.1f}%")

    # Get all workers
    print("\n4. Fetching workers...")
    workers = client.workers.list()
    print(f"   Total Workers: {len(workers)}")

    if workers:
        print("   Sample worker:")
        worker = workers[0]
        print(f"     - ID: {worker.get('worker_id', 'N/A')}")
        print(f"     - Type: {worker.get('worker_type', 'N/A')}")
        print(f"     - Status: {worker.get('status', 'N/A')}")

    # Get worker stats
    print("\n5. Getting worker statistics...")
    stats = client.workers.get_stats()
    print(f"   Total: {stats['total']}")
    print(f"   Active: {stats['active']}")
    print(f"   By Type: {stats['by_type']}")

    # Get tasks
    print("\n6. Fetching tasks...")
    tasks = client.tasks.list(limit=10)
    print(f"   Retrieved {len(tasks)} tasks")

    # Get task stats
    task_stats = client.tasks.get_stats()
    print(f"   Success Rate: {task_stats['success_rate']:.1f}%")
    print(f"   By Status: {task_stats['by_status']}")

    # Export to DataFrame (if pandas available)
    print("\n7. Exporting data to DataFrames...")
    try:
        metrics_df = client.metrics.to_dataframe(hours=24)
        print(f"   ✓ Metrics DataFrame: {len(metrics_df)} rows")
        print(f"   Columns: {list(metrics_df.columns)}")

        workers_df = client.workers.to_dataframe()
        print(f"   ✓ Workers DataFrame: {len(workers_df)} rows")

        tasks_df = client.tasks.to_dataframe()
        print(f"   ✓ Tasks DataFrame: {len(tasks_df)} rows")

    except ImportError:
        print("   ⚠ pandas not available - skipping DataFrame export")

    # Get metrics history
    print("\n8. Fetching metrics history...")
    history = client.metrics.get_history(hours=24)
    print(f"   Retrieved {len(history)} metric snapshots")

    # Get summary statistics
    print("\n9. Getting summary statistics...")
    summary = client.metrics.get_summary_stats(hours=24)
    if summary:
        print(f"   Avg Active Workers: {summary.get('avg_active_workers', 0):.1f}")
        print(f"   Max Active Workers: {summary.get('max_active_workers', 0)}")
        print(f"   Total Tasks Completed: {summary.get('total_tasks_completed', 0)}")

    print("\n" + "="*70)
    print("BASIC USAGE EXAMPLES COMPLETED")
    print("="*70)


if __name__ == '__main__':
    try:
        main()
    except Exception as e:
        print(f"\nError: {e}")
        import traceback
        traceback.print_exc()
