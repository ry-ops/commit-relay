#!/usr/bin/env python3
"""
Generate Test Dashboard Data
Creates fresh test data for dashboard verification with today's timestamps.
"""

import json
from datetime import datetime, timezone, timedelta
from pathlib import Path

# Paths
BASE_DIR = Path("/Users/ryandahlberg/commit-relay")
EVENTS_FILE = BASE_DIR / "coordination" / "dashboard-events.jsonl"
TASK_QUEUE_FILE = BASE_DIR / "coordination" / "task-queue.json"
HEALTH_ALERTS_FILE = BASE_DIR / "coordination" / "health-alerts.json"

def now_iso():
    """Get current timestamp in ISO format."""
    return datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')

def minutes_ago(minutes):
    """Get timestamp N minutes ago."""
    dt = datetime.now(timezone.utc) - timedelta(minutes=minutes)
    return dt.isoformat().replace('+00:00', 'Z')

def create_test_events():
    """Create test dashboard events for today."""
    events = [
        {
            "id": f"evt-{int(datetime.now(timezone.utc).timestamp())}-1",
            "timestamp": minutes_ago(60),
            "type": "system_started",
            "data": json.dumps({"message": "Dashboard test system initialized", "version": "3.0"}),
            "source": "system"
        },
        {
            "id": f"evt-{int(datetime.now(timezone.utc).timestamp())}-2",
            "timestamp": minutes_ago(50),
            "type": "task_created",
            "data": json.dumps({"task_id": "test-task-001", "title": "Test Feature Implementation", "type": "feature"}),
            "source": "coordinator"
        },
        {
            "id": f"evt-{int(datetime.now(timezone.utc).timestamp())}-3",
            "timestamp": minutes_ago(45),
            "type": "worker_spawned",
            "data": json.dumps({"worker_id": "test-dev-worker-001", "task_id": "test-task-001", "type": "feature-implementer"}),
            "source": "development-master"
        },
        {
            "id": f"evt-{int(datetime.now(timezone.utc).timestamp())}-4",
            "timestamp": minutes_ago(30),
            "type": "task_started",
            "data": json.dumps({"task_id": "test-task-001", "worker_id": "test-dev-worker-001"}),
            "source": "worker"
        },
        {
            "id": f"evt-{int(datetime.now(timezone.utc).timestamp())}-5",
            "timestamp": minutes_ago(10),
            "type": "task_completed",
            "data": json.dumps({"task_id": "test-task-001", "worker_id": "test-dev-worker-001", "success": True}),
            "source": "worker"
        },
        {
            "id": f"evt-{int(datetime.now(timezone.utc).timestamp())}-6",
            "timestamp": minutes_ago(5),
            "type": "metrics_snapshot",
            "data": json.dumps({"workers": {"active": 0, "completed": 1, "failed": 0}, "success_rate": 100}),
            "source": "metrics-daemon"
        },
    ]

    # Write events
    with open(EVENTS_FILE, 'w') as f:
        for event in events:
            f.write(json.dumps(event) + '\n')

    print(f"✓ Created {len(events)} test events in dashboard-events.jsonl")
    return events

def create_test_tasks():
    """Create test task queue with today's data."""
    task_queue = {
        "tasks": [
            {
                "id": "test-task-001",
                "title": "Test Feature Implementation",
                "type": "feature",
                "priority": "high",
                "status": "completed",
                "created_at": minutes_ago(50),
                "assigned_at": minutes_ago(45),
                "assigned_to": "development-master",
                "started_at": minutes_ago(30),
                "completed_at": minutes_ago(10),
                "context": {
                    "description": "Test task for dashboard verification"
                }
            },
            {
                "id": "test-task-002",
                "title": "Security Scan - Test Repository",
                "type": "security_scan",
                "priority": "medium",
                "status": "pending",
                "created_at": minutes_ago(15),
                "context": {
                    "repository": "test/repo",
                    "scan_types": ["dependencies", "static-analysis"]
                }
            }
        ],
        "metadata": {
            "last_updated": now_iso(),
            "total_tasks": 2,
            "pending_tasks": 1,
            "in_progress_tasks": 0,
            "completed_tasks": 1
        }
    }

    # Write task queue
    with open(TASK_QUEUE_FILE, 'w') as f:
        json.dump(task_queue, f, indent=2)

    print(f"✓ Created {len(task_queue['tasks'])} test tasks in task-queue.json")
    return task_queue

def create_test_health_alerts():
    """Create test health alerts structure (empty for clean start)."""
    health_data = {
        "sla_config": {
            "critical": 15,
            "high": 30,
            "medium": 60,
            "low": 120
        },
        "alerts": []
    }

    # Write health alerts
    with open(HEALTH_ALERTS_FILE, 'w') as f:
        json.dump(health_data, f, indent=2)

    print(f"✓ Created clean health alerts structure")
    return health_data

def main():
    """Generate all test data."""
    print("Generating Test Dashboard Data...")
    print(f"Timestamp: {now_iso()}\n")

    events = create_test_events()
    tasks = create_test_tasks()
    health = create_test_health_alerts()

    print("\n" + "="*60)
    print("Test Data Generation Complete!")
    print("="*60)
    print(f"\nEvents: {len(events)} total")
    print(f"Tasks: {len(tasks['tasks'])} total")
    print(f"Health Alerts: {len(health['alerts'])} active")
    print(f"\nAll data uses timestamps from today: {datetime.now(timezone.utc).date()}")
    print("\nRestart the dashboard server to see the updated data.")

if __name__ == '__main__':
    main()
