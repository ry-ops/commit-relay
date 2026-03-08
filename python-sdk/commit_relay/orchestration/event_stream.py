"""
Event Stream - Real-time event monitoring and streaming.

Provides APIs to monitor and stream task-related events from the commit-relay
event log, enabling real-time visibility into system operations.
"""

import json
from typing import Callable, Optional, List, Dict
from pathlib import Path
import time
import os


class EventStream:
    """
    Monitor and stream task-related events.

    The EventStream provides functionality to read events from the dashboard
    event log, filter events by task or type, and watch for new events in
    real-time.

    Example:
        >>> from commit_relay import EventStream
        >>> stream = EventStream()
        >>>
        >>> # Get recent events
        >>> events = stream.get_recent_events(limit=10)
        >>> for event in events:
        ...     print(f"{event['type']}: {event['timestamp']}")
        >>>
        >>> # Watch for task events
        >>> def on_event(event):
        ...     print(f"New event: {event['type']}")
        >>>
        >>> stream.watch_task_events('task-025', on_event=on_event, timeout=60)

    Attributes:
        commit_relay_home: Path to commit-relay repository
        events_file: Path to dashboard-events.jsonl file
    """

    def __init__(
        self,
        commit_relay_home: str = '/Users/ryandahlberg/commit-relay'
    ):
        """
        Initialize EventStream.

        Args:
            commit_relay_home: Path to commit-relay repository root
        """
        self.commit_relay_home = Path(os.path.expanduser(commit_relay_home))
        self.events_file = self.commit_relay_home / 'coordination' / 'dashboard-events.jsonl'

    def get_recent_events(self, limit: int = 100) -> List[Dict]:
        """
        Get recent events from event log.

        Reads the most recent events from the dashboard-events.jsonl file.
        Events are returned in chronological order.

        Args:
            limit: Maximum number of events to return (default: 100)

        Returns:
            List of event dictionaries, each containing:
                - id: Event identifier
                - type: Event type
                - timestamp: Event timestamp
                - data: Event-specific data

        Example:
            >>> events = stream.get_recent_events(limit=20)
            >>> print(f"Found {len(events)} recent events")
            >>> for event in events[-5:]:  # Last 5 events
            ...     print(f"{event['timestamp']}: {event['type']}")
        """
        events = []

        if not self.events_file.exists():
            return events

        try:
            with open(self.events_file, 'r') as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        event = json.loads(line)
                        events.append(event)
                    except json.JSONDecodeError:
                        # Skip malformed lines
                        continue
        except IOError as e:
            print(f"Warning: Could not read events file: {e}")
            return []

        # Return most recent events
        return events[-limit:] if len(events) > limit else events

    def get_task_events(self, task_id: str, limit: int = 1000) -> List[Dict]:
        """
        Get all events related to a specific task.

        Searches through the event log for events that reference the specified
        task ID in their data field.

        Args:
            task_id: Task ID to filter events for
            limit: Maximum number of events to search (default: 1000)

        Returns:
            List of task-related event dictionaries

        Example:
            >>> task_events = stream.get_task_events('task-025')
            >>> print(f"Found {len(task_events)} events for task-025")
            >>> for event in task_events:
            ...     print(f"  {event['type']}: {event.get('data', '')}")
        """
        all_events = self.get_recent_events(limit=limit)

        task_events = []
        for event in all_events:
            # Check if task_id appears in event data
            event_data = event.get('data', '')

            if isinstance(event_data, str):
                if task_id in event_data:
                    task_events.append(event)
            elif isinstance(event_data, dict):
                # Check if task_id is in data dict
                if event_data.get('task_id') == task_id:
                    task_events.append(event)
                # Check if task_id appears in any string values
                elif any(task_id in str(v) for v in event_data.values()):
                    task_events.append(event)

        return task_events

    def get_events_by_type(
        self,
        event_type: str,
        limit: int = 100
    ) -> List[Dict]:
        """
        Get events filtered by event type.

        Args:
            event_type: Event type to filter for (e.g., 'task_created',
                       'worker_spawned', 'task_completed')
            limit: Maximum number of events to search (default: 100)

        Returns:
            List of matching event dictionaries

        Example:
            >>> task_created = stream.get_events_by_type('task_created', limit=50)
            >>> print(f"Found {len(task_created)} task creation events")
        """
        all_events = self.get_recent_events(limit=limit)

        return [
            event for event in all_events
            if event.get('type') == event_type
        ]

    def watch_task_events(
        self,
        task_id: str,
        on_event: Callable,
        timeout: int = 600,
        poll_interval: int = 2
    ):
        """
        Watch for events related to a task in real-time.

        Continuously polls the event log for new events related to the
        specified task and calls the callback function for each new event.

        Args:
            task_id: Task ID to watch
            on_event: Callback function called for each new event.
                     Receives event dict as argument.
            timeout: Maximum watch time in seconds (default: 600)
            poll_interval: Polling interval in seconds (default: 2)

        Example:
            >>> def handle_event(event):
            ...     print(f"Task event: {event['type']}")
            ...     if event['type'] == 'task_completed':
            ...         print("Task finished!")
            >>>
            >>> stream.watch_task_events(
            ...     'task-025',
            ...     on_event=handle_event,
            ...     timeout=300
            ... )
        """
        start_time = time.time()
        seen_events = set()

        while True:
            events = self.get_task_events(task_id)

            for event in events:
                event_id = event.get('id', '')
                if event_id and event_id not in seen_events:
                    seen_events.add(event_id)
                    on_event(event)

            if time.time() - start_time > timeout:
                break

            time.sleep(poll_interval)

    def watch_all_events(
        self,
        on_event: Callable,
        event_types: Optional[List[str]] = None,
        timeout: int = 600,
        poll_interval: int = 2
    ):
        """
        Watch all events (optionally filtered by type).

        Continuously polls the event log for new events and calls the callback
        function for each new event. Can be filtered to specific event types.

        Args:
            on_event: Callback function called for each new event
            event_types: Optional list of event types to filter.
                        If None, all events are reported.
            timeout: Maximum watch time in seconds (default: 600)
            poll_interval: Polling interval in seconds (default: 2)

        Example:
            >>> def handle_event(event):
            ...     print(f"Event: {event['type']} at {event['timestamp']}")
            >>>
            >>> # Watch all events
            >>> stream.watch_all_events(on_event=handle_event, timeout=120)
            >>>
            >>> # Watch only specific event types
            >>> stream.watch_all_events(
            ...     on_event=handle_event,
            ...     event_types=['task_created', 'task_completed'],
            ...     timeout=120
            ... )
        """
        start_time = time.time()
        seen_events = set()

        while True:
            events = self.get_recent_events()

            for event in events:
                event_id = event.get('id', '')
                event_type = event.get('type', '')

                if event_id in seen_events:
                    continue

                # Filter by event types if specified
                if event_types and event_type not in event_types:
                    continue

                seen_events.add(event_id)
                on_event(event)

            if time.time() - start_time > timeout:
                break

            time.sleep(poll_interval)

    def get_event_summary(self, hours: int = 24) -> Dict:
        """
        Get summary of events from the last N hours.

        Args:
            hours: Number of hours to look back (default: 24)

        Returns:
            Dictionary with event statistics and summaries

        Example:
            >>> summary = stream.get_event_summary(hours=12)
            >>> print(f"Total events: {summary['total_events']}")
            >>> for event_type, count in summary['by_type'].items():
            ...     print(f"  {event_type}: {count}")
        """
        from datetime import datetime, timedelta

        all_events = self.get_recent_events(limit=5000)
        cutoff_time = datetime.utcnow() - timedelta(hours=hours)

        recent_events = []
        for event in all_events:
            timestamp = event.get('timestamp', '')
            if timestamp:
                try:
                    event_time = datetime.fromisoformat(
                        timestamp.replace('Z', '+00:00')
                    )
                    if event_time.replace(tzinfo=None) >= cutoff_time:
                        recent_events.append(event)
                except (ValueError, AttributeError):
                    continue

        # Count by type
        event_types = {}
        for event in recent_events:
            event_type = event.get('type', 'unknown')
            event_types[event_type] = event_types.get(event_type, 0) + 1

        return {
            'total_events': len(recent_events),
            'time_range_hours': hours,
            'by_type': event_types,
            'most_common_type': max(event_types, key=event_types.get) if event_types else None
        }

    def tail_events(
        self,
        on_event: Callable,
        follow: bool = True,
        poll_interval: int = 1
    ):
        """
        Tail the event log like 'tail -f'.

        Continuously follows the event log and reports new events as they
        are written. Similar to Unix 'tail -f' command.

        Args:
            on_event: Callback function for each new event
            follow: If True, continuously watch for new events.
                   If False, show existing events and exit.
            poll_interval: Polling interval in seconds (default: 1)

        Example:
            >>> def print_event(event):
            ...     print(f"[{event['timestamp']}] {event['type']}")
            >>>
            >>> # Follow events indefinitely
            >>> stream.tail_events(on_event=print_event)
        """
        seen_events = set()

        # First, get existing events
        events = self.get_recent_events(limit=10)
        for event in events:
            event_id = event.get('id', '')
            if event_id:
                seen_events.add(event_id)
                on_event(event)

        if not follow:
            return

        # Then watch for new events
        while True:
            events = self.get_recent_events(limit=50)

            for event in events:
                event_id = event.get('id', '')
                if event_id and event_id not in seen_events:
                    seen_events.add(event_id)
                    on_event(event)

            time.sleep(poll_interval)
