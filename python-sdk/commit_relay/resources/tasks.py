"""
Tasks resource client for commit-relay API.

Provides access to task-related endpoints including listing tasks,
getting task details, and analyzing task execution metrics.
"""

from typing import List, Dict, Any, Optional


class Tasks:
    """
    Client for task-related API endpoints.

    Handles all operations related to commit-relay tasks, including
    listing tasks, filtering by status, and analyzing task outcomes.

    Example:
        >>> client = CommitRelayClient()
        >>> tasks = client.tasks.list()
        >>> pending = client.tasks.get_by_status('pending')
        >>> stats = client.tasks.get_stats()
    """

    def __init__(self, client):
        """
        Initialize Tasks client.

        Args:
            client: Parent CommitRelayClient instance
        """
        self.client = client

    def list(self, limit: Optional[int] = None) -> List[Dict[str, Any]]:
        """
        Get all tasks.

        Args:
            limit: Maximum number of tasks to return (optional)

        Returns:
            List of task dictionaries

        Example:
            >>> tasks = client.tasks.list(limit=10)
        """
        params = {}
        if limit is not None:
            params['limit'] = limit

        result = self.client.get('/api/tasks', params=params)

        # Handle both direct list and wrapped response
        if isinstance(result, list):
            return result
        elif isinstance(result, dict) and 'tasks' in result:
            return result['tasks']
        return []

    def get(self, task_id: str) -> Dict[str, Any]:
        """
        Get details for a specific task.

        Args:
            task_id: Unique identifier for the task

        Returns:
            Task details dictionary

        Raises:
            ResourceNotFoundError: If task not found
        """
        return self.client.get(f'/api/tasks/{task_id}')

    def get_by_status(self, status: str) -> List[Dict[str, Any]]:
        """
        Get tasks filtered by status.

        Args:
            status: Task status ('pending', 'in_progress', 'completed', 'failed')

        Returns:
            List of tasks with the specified status

        Example:
            >>> pending_tasks = client.tasks.get_by_status('pending')
            >>> failed_tasks = client.tasks.get_by_status('failed')
        """
        all_tasks = self.list()
        return [t for t in all_tasks if t.get('status') == status]

    def get_pending(self) -> List[Dict[str, Any]]:
        """Get all pending tasks."""
        return self.get_by_status('pending')

    def get_in_progress(self) -> List[Dict[str, Any]]:
        """Get all tasks currently in progress."""
        return self.get_by_status('in_progress')

    def get_completed(self) -> List[Dict[str, Any]]:
        """Get all completed tasks."""
        return self.get_by_status('completed')

    def get_failed(self) -> List[Dict[str, Any]]:
        """Get all failed tasks."""
        return self.get_by_status('failed')

    def get_by_master(self, master_name: str) -> List[Dict[str, Any]]:
        """
        Get tasks assigned to a specific master.

        Args:
            master_name: Master name (e.g., 'development', 'security')

        Returns:
            List of tasks assigned to the specified master
        """
        all_tasks = self.list()
        return [t for t in all_tasks if t.get('assigned_to') == master_name]

    def get_stats(self) -> Dict[str, Any]:
        """
        Get task execution statistics.

        Returns:
            Dictionary containing task statistics including:
            - total: Total number of tasks
            - by_status: Task counts grouped by status
            - by_master: Task counts grouped by assigned master
            - success_rate: Percentage of completed vs failed tasks

        Example:
            >>> stats = client.tasks.get_stats()
            >>> print(f"Success rate: {stats['success_rate']:.1f}%")
        """
        tasks = self.list()

        stats = {
            'total': len(tasks),
            'by_status': {},
            'by_master': {},
            'success_rate': 0.0
        }

        for task in tasks:
            # Count by status
            status = task.get('status', 'unknown')
            stats['by_status'][status] = stats['by_status'].get(status, 0) + 1

            # Count by master
            master = task.get('assigned_to', 'unknown')
            stats['by_master'][master] = stats['by_master'].get(master, 0) + 1

        # Calculate success rate
        completed = stats['by_status'].get('completed', 0)
        failed = stats['by_status'].get('failed', 0)
        total_finished = completed + failed

        if total_finished > 0:
            stats['success_rate'] = (completed / total_finished) * 100

        return stats

    def get_recent(self, count: int = 10) -> List[Dict[str, Any]]:
        """
        Get most recent tasks.

        Args:
            count: Number of recent tasks to return

        Returns:
            List of most recent tasks

        Example:
            >>> recent = client.tasks.get_recent(count=5)
        """
        tasks = self.list()

        # Sort by created_at if available, otherwise return first N
        if tasks and 'created_at' in tasks[0]:
            tasks.sort(key=lambda x: x.get('created_at', ''), reverse=True)

        return tasks[:count]

    def to_dataframe(self, status: Optional[str] = None):
        """
        Export tasks to pandas DataFrame.

        Args:
            status: Optional status filter

        Returns:
            pandas.DataFrame containing task data

        Raises:
            ImportError: If pandas is not installed

        Example:
            >>> df = client.tasks.to_dataframe()
            >>> df_failed = client.tasks.to_dataframe(status='failed')
        """
        try:
            import pandas as pd
        except ImportError:
            raise ImportError(
                "pandas is required for this method. "
                "Install it with: pip install pandas"
            )

        if status:
            tasks = self.get_by_status(status)
        else:
            tasks = self.list()

        if not tasks:
            return pd.DataFrame()

        df = pd.DataFrame(tasks)

        # Convert timestamp columns to datetime if present
        timestamp_cols = ['created_at', 'updated_at', 'completed_at']
        for col in timestamp_cols:
            if col in df.columns:
                df[col] = pd.to_datetime(df[col], errors='coerce')

        return df

    def export_to_csv(self, filepath: str, status: Optional[str] = None) -> None:
        """
        Export tasks to CSV file.

        Args:
            filepath: Path to save CSV file
            status: Optional status filter

        Example:
            >>> client.tasks.export_to_csv('/tmp/tasks.csv')
            >>> client.tasks.export_to_csv('/tmp/failed_tasks.csv', status='failed')
        """
        df = self.to_dataframe(status=status)
        df.to_csv(filepath, index=False)

    def export_to_json(self, filepath: str, status: Optional[str] = None) -> None:
        """
        Export tasks to JSON file.

        Args:
            filepath: Path to save JSON file
            status: Optional status filter
        """
        import json

        if status:
            tasks = self.get_by_status(status)
        else:
            tasks = self.list()

        with open(filepath, 'w') as f:
            json.dump(tasks, f, indent=2)
