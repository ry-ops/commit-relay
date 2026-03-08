"""
Events resource client for commit-relay API.

Provides access to system events and event stream endpoints.
"""

from typing import List, Dict, Any, Optional


class Events:
    """
    Client for events-related API endpoints.

    Example:
        >>> client = CommitRelayClient()
        >>> events = client.events.list(limit=100)
        >>> recent = client.events.get_recent(count=10)
    """

    def __init__(self, client):
        """
        Initialize Events client.

        Args:
            client: Parent CommitRelayClient instance
        """
        self.client = client

    def list(self, limit: Optional[int] = None) -> List[Dict[str, Any]]:
        """
        Get all events.

        Args:
            limit: Maximum number of events to return

        Returns:
            List of event dictionaries
        """
        params = {}
        if limit is not None:
            params['limit'] = limit

        result = self.client.get('/api/events', params=params)

        if isinstance(result, list):
            return result
        elif isinstance(result, dict) and 'events' in result:
            return result['events']
        return []

    def get(self, event_id: str) -> Dict[str, Any]:
        """
        Get specific event by ID.

        Args:
            event_id: Event identifier

        Returns:
            Event details
        """
        return self.client.get(f'/api/events/{event_id}')

    def get_recent(self, count: int = 10) -> List[Dict[str, Any]]:
        """
        Get most recent events.

        Args:
            count: Number of recent events to return

        Returns:
            List of recent events
        """
        return self.list(limit=count)

    def get_by_type(self, event_type: str) -> List[Dict[str, Any]]:
        """
        Filter events by type.

        Args:
            event_type: Event type to filter by

        Returns:
            List of matching events
        """
        all_events = self.list()
        return [e for e in all_events if e.get('type') == event_type]

    def to_dataframe(self, limit: Optional[int] = None):
        """
        Export events to pandas DataFrame.

        Args:
            limit: Maximum number of events

        Returns:
            pandas.DataFrame
        """
        try:
            import pandas as pd
        except ImportError:
            raise ImportError("pandas required. Install with: pip install pandas")

        events = self.list(limit=limit)
        if not events:
            return pd.DataFrame()

        df = pd.DataFrame(events)

        if 'timestamp' in df.columns:
            df['timestamp'] = pd.to_datetime(df['timestamp'], errors='coerce')

        return df
