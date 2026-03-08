"""
Metrics resource client for commit-relay API.

Provides access to metrics endpoints including current metrics snapshot,
historical metrics, and time-series data export capabilities.
"""

from typing import List, Dict, Any, Optional
from datetime import datetime, timedelta


class Metrics:
    """
    Client for metrics-related API endpoints.

    Handles all operations related to system metrics, including current
    snapshots, historical data, and time-series analysis.

    Example:
        >>> client = CommitRelayClient()
        >>> current = client.metrics.get_current()
        >>> history = client.metrics.get_history(hours=24)
        >>> df = client.metrics.to_dataframe(hours=24)
    """

    def __init__(self, client):
        """
        Initialize Metrics client.

        Args:
            client: Parent CommitRelayClient instance
        """
        self.client = client

    def get_current(self) -> Dict[str, Any]:
        """
        Get current metrics snapshot.

        Returns the most recent metrics including active workers, tasks,
        success rates, and other system metrics.

        Returns:
            Dictionary containing current metrics

        Example:
            >>> metrics = client.metrics.get_current()
            >>> print(f"Active workers: {metrics['active_workers']}")
            >>> print(f"Success rate: {metrics['success_rate']}%")
        """
        return self.client.get('/api/metrics')

    def get_history(
        self,
        hours: int = 24,
        start_time: Optional[str] = None,
        end_time: Optional[str] = None
    ) -> List[Dict[str, Any]]:
        """
        Get historical metrics data.

        Args:
            hours: Number of hours of history to retrieve (default: 24)
            start_time: Optional start time (ISO format)
            end_time: Optional end time (ISO format)

        Returns:
            List of metrics snapshots over the specified time period

        Example:
            >>> # Get last 24 hours
            >>> history = client.metrics.get_history(hours=24)
            >>> # Get specific time range
            >>> history = client.metrics.get_history(
            ...     start_time='2025-01-01T00:00:00Z',
            ...     end_time='2025-01-02T00:00:00Z'
            ... )
        """
        params = {}

        if start_time and end_time:
            params['start_time'] = start_time
            params['end_time'] = end_time
        else:
            params['hours'] = hours

        result = self.client.get('/api/metrics/history', params=params)

        # Handle both direct list and wrapped response
        if isinstance(result, list):
            return result
        elif isinstance(result, dict) and 'metrics' in result:
            return result['metrics']
        return []

    def get_worker_metrics(self) -> Dict[str, Any]:
        """
        Get worker-specific metrics.

        Returns:
            Dictionary containing worker pool metrics
        """
        current = self.get_current()
        return {
            'active_workers': current.get('active_workers', 0),
            'total_workers': current.get('total_workers', 0),
            'worker_utilization': current.get('worker_utilization', 0)
        }

    def get_task_metrics(self) -> Dict[str, Any]:
        """
        Get task-specific metrics.

        Returns:
            Dictionary containing task execution metrics
        """
        current = self.get_current()
        return {
            'tasks_pending': current.get('tasks_pending', 0),
            'tasks_in_progress': current.get('tasks_in_progress', 0),
            'tasks_completed': current.get('tasks_completed', 0),
            'tasks_failed': current.get('tasks_failed', 0),
            'success_rate': current.get('success_rate', 0)
        }

    def get_performance_metrics(self) -> Dict[str, Any]:
        """
        Get performance-related metrics.

        Returns:
            Dictionary containing performance metrics
        """
        current = self.get_current()
        return {
            'avg_task_duration': current.get('avg_task_duration', 0),
            'throughput': current.get('throughput', 0),
            'token_usage': current.get('token_usage', {})
        }

    def to_dataframe(
        self,
        hours: int = 24,
        start_time: Optional[str] = None,
        end_time: Optional[str] = None
    ):
        """
        Export metrics to pandas DataFrame.

        Args:
            hours: Number of hours of history (default: 24)
            start_time: Optional start time (ISO format)
            end_time: Optional end time (ISO format)

        Returns:
            pandas.DataFrame containing metrics time-series data

        Raises:
            ImportError: If pandas is not installed

        Example:
            >>> df = client.metrics.to_dataframe(hours=24)
            >>> print(df[['timestamp', 'active_workers', 'success_rate']].head())
            >>> # Time-based filtering
            >>> df = df[df['timestamp'] > '2025-01-01']
        """
        try:
            import pandas as pd
        except ImportError:
            raise ImportError(
                "pandas is required for this method. "
                "Install it with: pip install pandas"
            )

        data = self.get_history(hours=hours, start_time=start_time, end_time=end_time)

        if not data:
            return pd.DataFrame()

        df = pd.DataFrame(data)

        # Convert timestamp to datetime
        if 'timestamp' in df.columns:
            df['timestamp'] = pd.to_datetime(df['timestamp'], errors='coerce')
            df = df.sort_values('timestamp')

        return df

    def get_summary_stats(self, hours: int = 24) -> Dict[str, Any]:
        """
        Get summary statistics over a time period.

        Args:
            hours: Number of hours to analyze

        Returns:
            Dictionary containing summary statistics

        Example:
            >>> stats = client.metrics.get_summary_stats(hours=24)
            >>> print(f"Avg active workers: {stats['avg_active_workers']:.1f}")
        """
        try:
            df = self.to_dataframe(hours=hours)
        except ImportError:
            # Fallback if pandas not available
            return self._get_summary_stats_fallback(hours)

        if df.empty:
            return {}

        stats = {
            'time_period_hours': hours,
            'data_points': len(df),
        }

        # Worker stats
        if 'active_workers' in df.columns:
            stats['avg_active_workers'] = float(df['active_workers'].mean())
            stats['max_active_workers'] = int(df['active_workers'].max())
            stats['min_active_workers'] = int(df['active_workers'].min())

        # Task stats
        if 'tasks_completed' in df.columns:
            stats['total_tasks_completed'] = int(df['tasks_completed'].sum())

        if 'tasks_failed' in df.columns:
            stats['total_tasks_failed'] = int(df['tasks_failed'].sum())

        # Success rate
        if 'success_rate' in df.columns:
            stats['avg_success_rate'] = float(df['success_rate'].mean())
            stats['min_success_rate'] = float(df['success_rate'].min())

        return stats

    def _get_summary_stats_fallback(self, hours: int) -> Dict[str, Any]:
        """Fallback method for summary stats without pandas."""
        data = self.get_history(hours=hours)

        if not data:
            return {}

        stats = {
            'time_period_hours': hours,
            'data_points': len(data),
        }

        # Calculate simple averages
        active_workers = [d.get('active_workers', 0) for d in data]
        if active_workers:
            stats['avg_active_workers'] = sum(active_workers) / len(active_workers)
            stats['max_active_workers'] = max(active_workers)
            stats['min_active_workers'] = min(active_workers)

        return stats

    def export_to_csv(
        self,
        filepath: str,
        hours: int = 24,
        start_time: Optional[str] = None,
        end_time: Optional[str] = None
    ) -> None:
        """
        Export metrics to CSV file.

        Args:
            filepath: Path to save CSV file
            hours: Number of hours of history
            start_time: Optional start time (ISO format)
            end_time: Optional end time (ISO format)

        Example:
            >>> client.metrics.export_to_csv('/tmp/metrics.csv', hours=24)
        """
        df = self.to_dataframe(hours=hours, start_time=start_time, end_time=end_time)
        df.to_csv(filepath, index=False)

    def export_to_json(
        self,
        filepath: str,
        hours: int = 24,
        start_time: Optional[str] = None,
        end_time: Optional[str] = None
    ) -> None:
        """
        Export metrics to JSON file.

        Args:
            filepath: Path to save JSON file
            hours: Number of hours of history
            start_time: Optional start time
            end_time: Optional end time
        """
        import json

        data = self.get_history(hours=hours, start_time=start_time, end_time=end_time)

        with open(filepath, 'w') as f:
            json.dump(data, f, indent=2)
