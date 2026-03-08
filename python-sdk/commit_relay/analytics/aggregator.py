"""
Metrics aggregation for commit-relay analytics.

Provides tools for aggregating and summarizing metrics data over various
time periods and dimensions.
"""

from typing import Dict, Any, Optional, List
from datetime import datetime, timedelta


class MetricsAggregator:
    """
    Aggregate and analyze metrics data.

    Provides various aggregation methods for analyzing commit-relay metrics
    over time, including worker statistics, task throughput, and success rates.

    Example:
        >>> from commit_relay import CommitRelayClient
        >>> from commit_relay.analytics import MetricsAggregator
        >>> client = CommitRelayClient()
        >>> aggregator = MetricsAggregator(client)
        >>> stats = aggregator.get_worker_stats(hours=24)
        >>> print(f"Avg workers: {stats['avg_active_workers']:.1f}")
    """

    def __init__(self, client):
        """
        Initialize MetricsAggregator.

        Args:
            client: CommitRelayClient instance
        """
        self.client = client

    def get_worker_stats(self, hours: int = 24) -> Dict[str, Any]:
        """
        Calculate worker statistics over time period.

        Args:
            hours: Number of hours to analyze

        Returns:
            Dictionary containing worker statistics:
            - avg_active_workers: Average number of active workers
            - max_active_workers: Peak number of active workers
            - min_active_workers: Minimum number of active workers
            - total_workers: Total unique workers seen
            - utilization_rate: Worker utilization percentage

        Example:
            >>> stats = aggregator.get_worker_stats(hours=24)
            >>> print(f"Peak workers: {stats['max_active_workers']}")
        """
        try:
            df = self.client.metrics.to_dataframe(hours=hours)

            if df.empty:
                return self._empty_worker_stats()

            stats = {
                'avg_active_workers': float(df['active_workers'].mean()) if 'active_workers' in df.columns else 0,
                'max_active_workers': int(df['active_workers'].max()) if 'active_workers' in df.columns else 0,
                'min_active_workers': int(df['active_workers'].min()) if 'active_workers' in df.columns else 0,
                'std_active_workers': float(df['active_workers'].std()) if 'active_workers' in df.columns else 0,
            }

            # Add total workers if available
            if 'total_workers' in df.columns:
                stats['total_workers'] = int(df['total_workers'].max())

            # Calculate utilization if we have both metrics
            if 'active_workers' in df.columns and 'total_workers' in df.columns:
                utilization = (df['active_workers'] / df['total_workers'].replace(0, 1)) * 100
                stats['avg_utilization_rate'] = float(utilization.mean())

            return stats

        except ImportError:
            return self._get_worker_stats_fallback(hours)

    def _empty_worker_stats(self) -> Dict[str, Any]:
        """Return empty worker stats."""
        return {
            'avg_active_workers': 0,
            'max_active_workers': 0,
            'min_active_workers': 0,
            'std_active_workers': 0,
        }

    def _get_worker_stats_fallback(self, hours: int) -> Dict[str, Any]:
        """Fallback worker stats calculation without pandas."""
        data = self.client.metrics.get_history(hours=hours)

        if not data:
            return self._empty_worker_stats()

        active_workers = [d.get('active_workers', 0) for d in data]

        return {
            'avg_active_workers': sum(active_workers) / len(active_workers),
            'max_active_workers': max(active_workers),
            'min_active_workers': min(active_workers),
        }

    def get_task_stats(self, hours: int = 24) -> Dict[str, Any]:
        """
        Calculate task execution statistics.

        Args:
            hours: Number of hours to analyze

        Returns:
            Dictionary containing task statistics
        """
        try:
            df = self.client.metrics.to_dataframe(hours=hours)

            if df.empty:
                return {}

            stats = {}

            if 'tasks_completed' in df.columns:
                stats['total_tasks_completed'] = int(df['tasks_completed'].sum())
                stats['avg_tasks_per_hour'] = float(df['tasks_completed'].mean())

            if 'tasks_failed' in df.columns:
                stats['total_tasks_failed'] = int(df['tasks_failed'].sum())

            if 'success_rate' in df.columns:
                stats['avg_success_rate'] = float(df['success_rate'].mean())
                stats['min_success_rate'] = float(df['success_rate'].min())
                stats['max_success_rate'] = float(df['success_rate'].max())

            if 'tasks_in_progress' in df.columns:
                stats['avg_tasks_in_progress'] = float(df['tasks_in_progress'].mean())

            return stats

        except ImportError:
            return self._get_task_stats_fallback(hours)

    def _get_task_stats_fallback(self, hours: int) -> Dict[str, Any]:
        """Fallback task stats calculation without pandas."""
        data = self.client.metrics.get_history(hours=hours)

        if not data:
            return {}

        completed = sum(d.get('tasks_completed', 0) for d in data)
        failed = sum(d.get('tasks_failed', 0) for d in data)
        success_rates = [d.get('success_rate', 0) for d in data if 'success_rate' in d]

        stats = {
            'total_tasks_completed': completed,
            'total_tasks_failed': failed,
        }

        if success_rates:
            stats['avg_success_rate'] = sum(success_rates) / len(success_rates)

        return stats

    def get_hourly_throughput(self, hours: int = 24):
        """
        Calculate tasks completed per hour.

        Args:
            hours: Number of hours to analyze

        Returns:
            pandas.Series with hourly task counts (if pandas available)
            or dict mapping hour to task count

        Example:
            >>> throughput = aggregator.get_hourly_throughput(hours=24)
            >>> print(throughput)
        """
        try:
            import pandas as pd

            df = self.client.metrics.to_dataframe(hours=hours)

            if df.empty or 'tasks_completed' not in df.columns:
                return pd.Series()

            df.set_index('timestamp', inplace=True)
            return df.resample('1H')['tasks_completed'].sum()

        except ImportError:
            return self._get_hourly_throughput_fallback(hours)

    def _get_hourly_throughput_fallback(self, hours: int) -> Dict[str, int]:
        """Fallback hourly throughput without pandas."""
        data = self.client.metrics.get_history(hours=hours)

        hourly = {}
        for entry in data:
            timestamp = entry.get('timestamp', '')
            if timestamp:
                # Extract hour from timestamp
                hour = timestamp[:13]  # YYYY-MM-DDTHH
                hourly[hour] = hourly.get(hour, 0) + entry.get('tasks_completed', 0)

        return hourly

    def get_success_rate_trend(self, hours: int = 24):
        """
        Analyze success rate trends over time.

        Args:
            hours: Number of hours to analyze

        Returns:
            pandas.Series with hourly success rates or dict
        """
        try:
            import pandas as pd

            df = self.client.metrics.to_dataframe(hours=hours)

            if df.empty or 'success_rate' not in df.columns:
                return pd.Series()

            df.set_index('timestamp', inplace=True)
            return df.resample('1H')['success_rate'].mean()

        except ImportError:
            return self._get_success_rate_trend_fallback(hours)

    def _get_success_rate_trend_fallback(self, hours: int) -> Dict[str, float]:
        """Fallback success rate trend without pandas."""
        data = self.client.metrics.get_history(hours=hours)

        hourly_rates = {}
        hourly_counts = {}

        for entry in data:
            timestamp = entry.get('timestamp', '')
            if timestamp and 'success_rate' in entry:
                hour = timestamp[:13]
                hourly_rates[hour] = hourly_rates.get(hour, 0) + entry['success_rate']
                hourly_counts[hour] = hourly_counts.get(hour, 0) + 1

        # Calculate averages
        return {hour: hourly_rates[hour] / hourly_counts[hour] for hour in hourly_rates}

    def get_comprehensive_summary(self, hours: int = 24) -> Dict[str, Any]:
        """
        Get comprehensive summary of all metrics.

        Args:
            hours: Number of hours to analyze

        Returns:
            Dictionary with all aggregated statistics

        Example:
            >>> summary = aggregator.get_comprehensive_summary(hours=24)
            >>> print(f"Workers: {summary['worker_stats']}")
            >>> print(f"Tasks: {summary['task_stats']}")
        """
        return {
            'time_period_hours': hours,
            'worker_stats': self.get_worker_stats(hours=hours),
            'task_stats': self.get_task_stats(hours=hours),
            'generated_at': datetime.utcnow().isoformat() + 'Z',
        }

    def compare_periods(
        self,
        current_hours: int = 24,
        previous_hours: int = 24
    ) -> Dict[str, Any]:
        """
        Compare metrics between two time periods.

        Args:
            current_hours: Hours for current period
            previous_hours: Hours for previous period

        Returns:
            Dictionary with comparison statistics

        Example:
            >>> comparison = aggregator.compare_periods(current_hours=24, previous_hours=24)
            >>> print(f"Worker change: {comparison['worker_change_pct']:.1f}%")
        """
        current = self.get_comprehensive_summary(hours=current_hours)
        # For previous period, we'd need to adjust the time range
        # This is a simplified version
        previous = self.get_comprehensive_summary(hours=previous_hours)

        comparison = {
            'current_period': current,
            'previous_period': previous,
            'changes': {},
        }

        # Calculate percentage changes
        curr_workers = current['worker_stats'].get('avg_active_workers', 0)
        prev_workers = previous['worker_stats'].get('avg_active_workers', 0)

        if prev_workers > 0:
            comparison['changes']['worker_change_pct'] = (
                (curr_workers - prev_workers) / prev_workers * 100
            )

        curr_success = current['task_stats'].get('avg_success_rate', 0)
        prev_success = previous['task_stats'].get('avg_success_rate', 0)

        if prev_success > 0:
            comparison['changes']['success_rate_change_pct'] = (
                (curr_success - prev_success) / prev_success * 100
            )

        return comparison
