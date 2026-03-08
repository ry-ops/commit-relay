"""
Execution Monitor - Real-time task execution tracking and monitoring.

Provides APIs to monitor task execution, wait for completion, and track
execution metrics for commit-relay tasks.
"""

import time
from typing import Optional, Dict, Callable, List
from datetime import datetime, timedelta
from .task_manager import TaskStatus


class ExecutionMonitor:
    """
    Monitor task execution in real-time.

    The ExecutionMonitor provides functionality to track task execution status,
    wait for task completion, and monitor multiple tasks in parallel. It polls
    the task queue to detect status changes.

    Example:
        >>> from commit_relay import TaskManager, ExecutionMonitor
        >>> manager = TaskManager()
        >>> monitor = ExecutionMonitor(manager)
        >>>
        >>> # Wait for task completion
        >>> task_id = 'task-025'
        >>> result = monitor.wait_for_completion(task_id, timeout=300)
        >>> print(f"Task completed with status: {result['status']}")

        >>> # Monitor with callback
        >>> def on_status_change(task):
        ...     print(f"Status changed to: {task['status']}")
        >>>
        >>> monitor.monitor_task(task_id, on_status_change=on_status_change)

    Attributes:
        task_manager: TaskManager instance for accessing task data
    """

    def __init__(self, task_manager):
        """
        Initialize ExecutionMonitor.

        Args:
            task_manager: TaskManager instance to use for task access
        """
        self.task_manager = task_manager

    def wait_for_completion(
        self,
        task_id: str,
        timeout: int = 600,
        poll_interval: int = 5
    ) -> Dict:
        """
        Wait for a task to complete.

        Polls the task queue at regular intervals until the task reaches a
        terminal state (completed or failed) or the timeout is reached.

        Args:
            task_id: Task ID to monitor
            timeout: Maximum wait time in seconds (default: 600)
            poll_interval: Polling interval in seconds (default: 5)

        Returns:
            Final task state dictionary

        Raises:
            TimeoutError: If task doesn't complete within timeout
            ValueError: If task is not found

        Example:
            >>> result = monitor.wait_for_completion('task-025', timeout=300)
            >>> if result['status'] == 'completed':
            ...     print("Task completed successfully!")
        """
        start_time = time.time()
        last_status = None

        while True:
            task = self.task_manager.get_task(task_id)

            if task is None:
                raise ValueError(f"Task {task_id} not found")

            # Print status changes
            if task['status'] != last_status:
                timestamp = datetime.now().strftime('%H:%M:%S')
                print(f"[{timestamp}] Task {task_id}: {task['status']}")
                last_status = task['status']

            # Check if completed
            if task['status'] in ['completed', 'failed']:
                return task

            # Check timeout
            elapsed = time.time() - start_time
            if elapsed > timeout:
                raise TimeoutError(
                    f"Task {task_id} did not complete within {timeout}s "
                    f"(current status: {task['status']})"
                )

            time.sleep(poll_interval)

    def monitor_task(
        self,
        task_id: str,
        on_status_change: Optional[Callable] = None,
        on_completion: Optional[Callable] = None,
        timeout: int = 600,
        poll_interval: int = 5
    ):
        """
        Monitor a task with callbacks for status changes and completion.

        Args:
            task_id: Task ID to monitor
            on_status_change: Callback function called when status changes.
                             Receives task dict as argument.
            on_completion: Callback function called when task completes.
                          Receives final task dict as argument.
            timeout: Maximum monitoring time in seconds (default: 600)
            poll_interval: Polling interval in seconds (default: 5)

        Raises:
            TimeoutError: If monitoring timeout is reached
            ValueError: If task is not found

        Example:
            >>> def on_change(task):
            ...     print(f"Status: {task['status']}")
            >>>
            >>> def on_done(task):
            ...     print(f"Completed: {task['id']}")
            >>>
            >>> monitor.monitor_task(
            ...     'task-025',
            ...     on_status_change=on_change,
            ...     on_completion=on_done
            ... )
        """
        start_time = time.time()
        last_status = None

        while True:
            task = self.task_manager.get_task(task_id)

            if task is None:
                raise ValueError(f"Task {task_id} not found")

            # Status change callback
            if task['status'] != last_status and on_status_change:
                on_status_change(task)
                last_status = task['status']

            # Completion callback
            if task['status'] in ['completed', 'failed']:
                if on_completion:
                    on_completion(task)
                return

            # Timeout check
            if time.time() - start_time > timeout:
                raise TimeoutError(
                    f"Task {task_id} monitoring timeout after {timeout}s"
                )

            time.sleep(poll_interval)

    def get_execution_metrics(self, task_id: str) -> Dict:
        """
        Get execution metrics for a task.

        Calculates various metrics including duration, age, and status
        information for the specified task.

        Args:
            task_id: Task ID to get metrics for

        Returns:
            Dictionary containing:
                - task_id: Task identifier
                - status: Current task status
                - assigned_to: Worker assigned to task (if any)
                - created_at: Task creation timestamp
                - age_minutes: Minutes since task creation
                - completed_at: Completion timestamp (if completed)
                - duration_minutes: Execution duration (if completed)

        Example:
            >>> metrics = monitor.get_execution_metrics('task-025')
            >>> print(f"Duration: {metrics.get('duration_minutes', 'N/A')} minutes")
            >>> print(f"Status: {metrics['status']}")
        """
        task = self.task_manager.get_task(task_id)

        if not task:
            return {}

        created_at = datetime.fromisoformat(task['created_at'].replace('Z', '+00:00'))

        metrics = {
            'task_id': task_id,
            'status': task['status'],
            'assigned_to': task.get('assigned_to'),
            'created_at': task['created_at'],
            'age_minutes': (datetime.now(created_at.tzinfo) - created_at).total_seconds() / 60
        }

        if task.get('completed_at'):
            completed_at = datetime.fromisoformat(
                task['completed_at'].replace('Z', '+00:00')
            )
            duration = (completed_at - created_at).total_seconds() / 60
            metrics['completed_at'] = task['completed_at']
            metrics['duration_minutes'] = duration

        return metrics

    def monitor_multiple_tasks(
        self,
        task_ids: List[str],
        timeout: int = 600,
        poll_interval: int = 5
    ) -> Dict[str, Dict]:
        """
        Monitor multiple tasks in parallel.

        Polls all specified tasks simultaneously and returns when all tasks
        reach a terminal state or timeout is reached.

        Args:
            task_ids: List of task IDs to monitor
            timeout: Maximum wait time in seconds (default: 600)
            poll_interval: Polling interval in seconds (default: 5)

        Returns:
            Dictionary mapping task_id to final task state

        Raises:
            TimeoutError: If any tasks don't complete within timeout

        Example:
            >>> task_ids = ['task-025', 'task-026', 'task-027']
            >>> results = monitor.monitor_multiple_tasks(task_ids, timeout=300)
            >>>
            >>> for task_id, task in results.items():
            ...     print(f"{task_id}: {task['status']}")
        """
        results = {}
        start_time = time.time()
        pending = set(task_ids)

        while pending:
            for task_id in list(pending):
                task = self.task_manager.get_task(task_id)

                if task and task['status'] in ['completed', 'failed']:
                    results[task_id] = task
                    pending.remove(task_id)
                    timestamp = datetime.now().strftime('%H:%M:%S')
                    print(f"[{timestamp}] Task {task_id}: {task['status']}")

            if time.time() - start_time > timeout:
                pending_list = ', '.join(pending)
                raise TimeoutError(
                    f"Monitoring timeout after {timeout}s. "
                    f"Pending tasks: {pending_list}"
                )

            if pending:
                time.sleep(poll_interval)

        return results

    def get_task_progress_summary(self, task_ids: List[str]) -> Dict:
        """
        Get progress summary for multiple tasks.

        Args:
            task_ids: List of task IDs to summarize

        Returns:
            Dictionary with counts by status and list of tasks

        Example:
            >>> summary = monitor.get_task_progress_summary(['task-025', 'task-026'])
            >>> print(f"Completed: {summary['completed_count']}")
            >>> print(f"Pending: {summary['pending_count']}")
        """
        tasks = []
        status_counts = {
            'pending': 0,
            'in-progress': 0,
            'completed': 0,
            'failed': 0
        }

        for task_id in task_ids:
            task = self.task_manager.get_task(task_id)
            if task:
                tasks.append(task)
                status = task['status']
                if status in status_counts:
                    status_counts[status] += 1

        return {
            'total': len(tasks),
            'pending_count': status_counts['pending'],
            'in_progress_count': status_counts['in-progress'],
            'completed_count': status_counts['completed'],
            'failed_count': status_counts['failed'],
            'tasks': tasks
        }
