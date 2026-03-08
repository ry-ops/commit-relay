"""
Event Emitter - Single Source of Truth
All events are written to coordination/dashboard-events.jsonl
"""

import json
import time
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, Any, Optional


class EventEmitter:
    """
    Universal event emitter for commit-relay.

    Single Source of Truth: /coordination/dashboard-events.jsonl
    All events (task, worker, git, system, etc.) must be emitted through this class.
    """

    def __init__(self, commit_relay_home: str = '/Users/ryandahlberg/commit-relay'):
        self.commit_relay_home = Path(commit_relay_home)
        self.events_file = self.commit_relay_home / 'coordination' / 'dashboard-events.jsonl'

        # Ensure events file exists
        self.events_file.parent.mkdir(parents=True, exist_ok=True)
        if not self.events_file.exists():
            self.events_file.touch()

    def emit(self,
             event_type: str,
             data: Dict[str, Any],
             source: str = 'python_sdk') -> str:
        """
        Emit an event to the single source of truth.

        Args:
            event_type: Type of event (e.g., 'task_created', 'worker_spawned')
            data: Event data as dictionary
            source: Source of the event (default: 'python_sdk')

        Returns:
            Event ID

        Example:
            >>> emitter = EventEmitter()
            >>> emitter.emit('task_created', {'task_id': 'task-001', 'title': 'Test Task'}, 'coordinator')
        """
        # Generate event ID and timestamp
        event_id = f"evt-{int(time.time())}-{os.getpid()}"
        timestamp = datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')

        # Create event
        event = {
            'id': event_id,
            'timestamp': timestamp,
            'type': event_type,
            'data': json.dumps(data) if isinstance(data, dict) else str(data),
            'source': source
        }

        # Write to events file (atomic append)
        with open(self.events_file, 'a') as f:
            f.write(json.dumps(event) + '\n')

        return event_id

    # Convenience methods for common events

    def task_created(self, task_id: str, title: str, task_type: str,
                     priority: str = 'medium', **kwargs) -> str:
        """Emit task_created event."""
        data = {
            'task_id': task_id,
            'title': title,
            'task_type': task_type,
            'priority': priority,
            **kwargs
        }
        return self.emit('task_created', data, source='task_manager')

    def task_assigned(self, task_id: str, assigned_to: str, **kwargs) -> str:
        """Emit task_assigned event."""
        data = {
            'task_id': task_id,
            'assigned_to': assigned_to,
            **kwargs
        }
        return self.emit('task_assigned', data, source='coordinator')

    def task_started(self, task_id: str, worker_id: str, **kwargs) -> str:
        """Emit task_started event."""
        data = {
            'task_id': task_id,
            'worker_id': worker_id,
            **kwargs
        }
        return self.emit('task_started', data, source='worker')

    def task_completed(self, task_id: str, worker_id: str, success: bool = True, **kwargs) -> str:
        """Emit task_completed event."""
        data = {
            'task_id': task_id,
            'worker_id': worker_id,
            'success': success,
            **kwargs
        }
        return self.emit('task_completed', data, source='worker')

    def task_failed(self, task_id: str, worker_id: str, error: str, **kwargs) -> str:
        """Emit task_failed event."""
        data = {
            'task_id': task_id,
            'worker_id': worker_id,
            'error': error,
            **kwargs
        }
        return self.emit('task_failed', data, source='worker')

    def worker_spawned(self, worker_id: str, task_id: str, worker_type: str, **kwargs) -> str:
        """Emit worker_spawned event."""
        data = {
            'worker_id': worker_id,
            'task_id': task_id,
            'worker_type': worker_type,
            **kwargs
        }
        return self.emit('worker_spawned', data, source='master')

    def worker_completed(self, worker_id: str, task_id: str, **kwargs) -> str:
        """Emit worker_completed event."""
        data = {
            'worker_id': worker_id,
            'task_id': task_id,
            **kwargs
        }
        return self.emit('worker_completed', data, source='worker')

    def git_push_success(self, worker_id: str, commit_hash: str, **kwargs) -> str:
        """Emit git_push_success event."""
        data = {
            'worker_id': worker_id,
            'commit_hash': commit_hash,
            **kwargs
        }
        return self.emit('git_push_success', data, source='worker')

    def git_push_failed(self, worker_id: str, error: str, **kwargs) -> str:
        """Emit git_push_failed event."""
        data = {
            'worker_id': worker_id,
            'error': error,
            **kwargs
        }
        return self.emit('git_push_failed', data, source='worker')

    def system_started(self, component: str, version: str = '3.0', **kwargs) -> str:
        """Emit system_started event."""
        data = {
            'component': component,
            'version': version,
            **kwargs
        }
        return self.emit('system_started', data, source='system')

    def health_alert_created(self, alert_id: str, severity: str, message: str, **kwargs) -> str:
        """Emit health_alert_created event."""
        data = {
            'alert_id': alert_id,
            'severity': severity,
            'message': message,
            **kwargs
        }
        return self.emit('health_alert_created', data, source='health_monitor')

    def metrics_snapshot(self, metrics: Dict[str, Any]) -> str:
        """Emit metrics_snapshot event."""
        return self.emit('metrics_snapshot', metrics, source='metrics_daemon')
