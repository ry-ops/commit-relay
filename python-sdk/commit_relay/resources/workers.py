"""
Workers resource client for commit-relay API.

Provides access to worker-related endpoints including listing workers,
getting worker details, and analyzing worker pool status.
"""

from typing import List, Dict, Any, Optional


class Workers:
    """
    Client for worker-related API endpoints.

    Handles all operations related to commit-relay workers, including
    listing active workers, getting worker details, and exporting data.

    Example:
        >>> client = CommitRelayClient()
        >>> workers = client.workers.list()
        >>> active_count = client.workers.get_active_count()
        >>> df = client.workers.to_dataframe()
    """

    def __init__(self, client):
        """
        Initialize Workers client.

        Args:
            client: Parent CommitRelayClient instance
        """
        self.client = client

    def list(self) -> List[Dict[str, Any]]:
        """
        Get all workers.

        Returns a list of all workers currently registered in the system,
        including both active and inactive workers.

        Returns:
            List of worker dictionaries containing worker metadata

        Example:
            >>> workers = client.workers.list()
            >>> for worker in workers:
            ...     print(f"{worker['worker_id']}: {worker['status']}")
        """
        result = self.client.get('/api/workers')
        # Handle both direct list and wrapped response
        if isinstance(result, list):
            return result
        elif isinstance(result, dict) and 'workers' in result:
            return result['workers']
        return []

    def get(self, worker_id: str) -> Dict[str, Any]:
        """
        Get details for a specific worker.

        Args:
            worker_id: Unique identifier for the worker

        Returns:
            Worker details dictionary

        Raises:
            ResourceNotFoundError: If worker not found
        """
        return self.client.get(f'/api/workers/{worker_id}')

    def get_active(self) -> List[Dict[str, Any]]:
        """
        Get only active workers.

        Returns:
            List of active worker dictionaries
        """
        all_workers = self.list()
        return [w for w in all_workers if w.get('status') == 'active']

    def get_active_count(self) -> int:
        """
        Get count of active workers.

        Returns:
            Number of workers currently in active status

        Example:
            >>> count = client.workers.get_active_count()
            >>> print(f"Active workers: {count}")
        """
        return len(self.get_active())

    def get_by_type(self, worker_type: str) -> List[Dict[str, Any]]:
        """
        Get workers filtered by type.

        Args:
            worker_type: Worker type to filter by (e.g., 'feature-implementer')

        Returns:
            List of workers matching the specified type
        """
        all_workers = self.list()
        return [w for w in all_workers if w.get('worker_type') == worker_type]

    def get_by_master(self, master_name: str) -> List[Dict[str, Any]]:
        """
        Get workers filtered by parent master.

        Args:
            master_name: Parent master name (e.g., 'development', 'security')

        Returns:
            List of workers spawned by the specified master
        """
        all_workers = self.list()
        return [w for w in all_workers if w.get('parent_master') == master_name]

    def get_stats(self) -> Dict[str, Any]:
        """
        Get worker pool statistics.

        Returns:
            Dictionary containing worker pool statistics including:
            - total: Total number of workers
            - active: Number of active workers
            - by_type: Worker counts grouped by type
            - by_master: Worker counts grouped by parent master
            - by_status: Worker counts grouped by status

        Example:
            >>> stats = client.workers.get_stats()
            >>> print(f"Total: {stats['total']}, Active: {stats['active']}")
        """
        workers = self.list()

        stats = {
            'total': len(workers),
            'active': len([w for w in workers if w.get('status') == 'active']),
            'by_type': {},
            'by_master': {},
            'by_status': {}
        }

        for worker in workers:
            # Count by type
            worker_type = worker.get('worker_type', 'unknown')
            stats['by_type'][worker_type] = stats['by_type'].get(worker_type, 0) + 1

            # Count by master
            master = worker.get('parent_master', 'unknown')
            stats['by_master'][master] = stats['by_master'].get(master, 0) + 1

            # Count by status
            status = worker.get('status', 'unknown')
            stats['by_status'][status] = stats['by_status'].get(status, 0) + 1

        return stats

    def to_dataframe(self):
        """
        Export workers to pandas DataFrame.

        Returns:
            pandas.DataFrame containing all worker data

        Raises:
            ImportError: If pandas is not installed

        Example:
            >>> df = client.workers.to_dataframe()
            >>> print(df[['worker_id', 'status', 'worker_type']].head())
        """
        try:
            import pandas as pd
        except ImportError:
            raise ImportError(
                "pandas is required for this method. "
                "Install it with: pip install pandas"
            )

        workers = self.list()
        if not workers:
            return pd.DataFrame()

        return pd.DataFrame(workers)

    def export_to_csv(self, filepath: str) -> None:
        """
        Export workers to CSV file.

        Args:
            filepath: Path to save CSV file

        Example:
            >>> client.workers.export_to_csv('/tmp/workers.csv')
        """
        df = self.to_dataframe()
        df.to_csv(filepath, index=False)

    def export_to_json(self, filepath: str) -> None:
        """
        Export workers to JSON file.

        Args:
            filepath: Path to save JSON file

        Example:
            >>> client.workers.export_to_json('/tmp/workers.json')
        """
        import json

        workers = self.list()
        with open(filepath, 'w') as f:
            json.dump(workers, f, indent=2)
