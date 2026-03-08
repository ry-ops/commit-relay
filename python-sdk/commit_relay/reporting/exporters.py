"""
Data export utilities for commit-relay metrics.

Provides export to various formats including CSV, JSON, and Excel.
"""

from typing import Optional, List, Dict, Any
import json


class DataExporter:
    """
    Export commit-relay data to various formats.

    Example:
        >>> from commit_relay.reporting import DataExporter
        >>> exporter = DataExporter(client)
        >>> exporter.export_all_to_directory('/tmp/exports')
    """

    def __init__(self, client):
        """
        Initialize DataExporter.

        Args:
            client: CommitRelayClient instance
        """
        self.client = client

    def export_metrics_to_csv(
        self,
        filepath: str,
        hours: int = 24
    ):
        """
        Export metrics to CSV file.

        Args:
            filepath: Path to save CSV
            hours: Hours of history
        """
        self.client.metrics.export_to_csv(filepath, hours=hours)

    def export_workers_to_csv(self, filepath: str):
        """Export workers to CSV."""
        self.client.workers.export_to_csv(filepath)

    def export_tasks_to_csv(
        self,
        filepath: str,
        status: Optional[str] = None
    ):
        """Export tasks to CSV."""
        self.client.tasks.export_to_csv(filepath, status=status)

    def export_to_json(
        self,
        filepath: str,
        include_workers: bool = True,
        include_tasks: bool = True,
        include_metrics: bool = True,
        metrics_hours: int = 24
    ):
        """
        Export comprehensive data to JSON.

        Args:
            filepath: Path to save JSON file
            include_workers: Include worker data
            include_tasks: Include task data
            include_metrics: Include metrics data
            metrics_hours: Hours of metrics history

        Example:
            >>> exporter.export_to_json('/tmp/full_export.json')
        """
        data = {
            'export_timestamp': None,
        }

        from datetime import datetime
        data['export_timestamp'] = datetime.utcnow().isoformat() + 'Z'

        if include_workers:
            data['workers'] = self.client.workers.list()

        if include_tasks:
            data['tasks'] = self.client.tasks.list()

        if include_metrics:
            data['metrics'] = {
                'current': self.client.metrics.get_current(),
                'history': self.client.metrics.get_history(hours=metrics_hours)
            }

        with open(filepath, 'w') as f:
            json.dump(data, f, indent=2)

        print(f"Data exported to: {filepath}")

    def export_all_to_directory(
        self,
        directory: str,
        hours: int = 24
    ):
        """
        Export all data to a directory.

        Creates separate files for workers, tasks, metrics, etc.

        Args:
            directory: Directory path to save exports
            hours: Hours of metrics history

        Example:
            >>> exporter.export_all_to_directory('/tmp/commit_relay_export')
        """
        import os

        # Create directory if it doesn't exist
        os.makedirs(directory, exist_ok=True)

        # Export workers
        workers_path = os.path.join(directory, 'workers.csv')
        self.export_workers_to_csv(workers_path)
        print(f"Exported workers to: {workers_path}")

        # Export tasks
        tasks_path = os.path.join(directory, 'tasks.csv')
        self.export_tasks_to_csv(tasks_path)
        print(f"Exported tasks to: {tasks_path}")

        # Export metrics
        metrics_path = os.path.join(directory, 'metrics.csv')
        self.export_metrics_to_csv(metrics_path, hours=hours)
        print(f"Exported metrics to: {metrics_path}")

        # Export comprehensive JSON
        json_path = os.path.join(directory, 'full_export.json')
        self.export_to_json(json_path, metrics_hours=hours)

        print(f"\nAll exports completed in: {directory}")

    def export_to_excel(
        self,
        filepath: str,
        hours: int = 24
    ):
        """
        Export data to Excel file with multiple sheets.

        Args:
            filepath: Path to save Excel file
            hours: Hours of metrics history

        Example:
            >>> exporter.export_to_excel('/tmp/commit_relay.xlsx')
        """
        try:
            import pandas as pd

            with pd.ExcelWriter(filepath, engine='openpyxl') as writer:
                # Workers sheet
                workers_df = self.client.workers.to_dataframe()
                if not workers_df.empty:
                    workers_df.to_excel(writer, sheet_name='Workers', index=False)

                # Tasks sheet
                tasks_df = self.client.tasks.to_dataframe()
                if not tasks_df.empty:
                    tasks_df.to_excel(writer, sheet_name='Tasks', index=False)

                # Metrics sheet
                metrics_df = self.client.metrics.to_dataframe(hours=hours)
                if not metrics_df.empty:
                    metrics_df.to_excel(writer, sheet_name='Metrics', index=False)

            print(f"Excel export completed: {filepath}")

        except ImportError:
            print("Error: pandas and openpyxl required for Excel export")
            print("Install with: pip install pandas openpyxl")
