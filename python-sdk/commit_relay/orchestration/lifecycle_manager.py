"""
Task Lifecycle Manager - Unified interface for complete task lifecycle management.

Provides a high-level API that combines task creation, execution monitoring,
health checking, and event streaming into a single unified interface.
"""

from typing import Dict, Optional, Callable, List
from .task_manager import TaskManager, TaskType, TaskPriority
from .execution_monitor import ExecutionMonitor
from .task_health import TaskHealthMonitor
from .event_stream import EventStream


class TaskLifecycleManager:
    """
    Unified interface for complete task lifecycle management.

    The TaskLifecycleManager provides a high-level API that orchestrates all
    aspects of task management: creation, monitoring, health checking, and
    event streaming. This is the recommended entry point for most task
    lifecycle operations.

    Example:
        >>> from commit_relay import CommitRelayClient, TaskLifecycleManager
        >>> client = CommitRelayClient()
        >>> lifecycle = TaskLifecycleManager(client)
        >>>
        >>> # Create and monitor task in one call
        >>> result = lifecycle.create_and_monitor(
        ...     task_type='security-scan',
        ...     repository='ry-ops/my-repo',
        ...     wait_for_completion=True
        ... )
        >>>
        >>> print(f"Task {result['task_id']}: {result['final_status']}")
        >>> print(f"Duration: {result['metrics'].get('duration_minutes', 'N/A')} minutes")

    Attributes:
        client: CommitRelayClient instance for API access
        task_manager: TaskManager for task operations
        execution_monitor: ExecutionMonitor for execution tracking
        health_monitor: TaskHealthMonitor for health checks
        event_stream: EventStream for event monitoring
    """

    def __init__(
        self,
        client,
        commit_relay_home: str = '/Users/ryandahlberg/commit-relay',
        auto_commit: bool = True
    ):
        """
        Initialize TaskLifecycleManager.

        Args:
            client: CommitRelayClient instance
            commit_relay_home: Path to commit-relay repository root
            auto_commit: Whether to automatically commit task changes to git
        """
        self.client = client
        self.task_manager = TaskManager(
            commit_relay_home=commit_relay_home,
            auto_commit=auto_commit
        )
        self.execution_monitor = ExecutionMonitor(self.task_manager)
        self.health_monitor = TaskHealthMonitor(self.task_manager, client)
        self.event_stream = EventStream(commit_relay_home=commit_relay_home)

    def create_and_monitor(
        self,
        task_type: str,
        repository: str,
        wait_for_completion: bool = True,
        on_status_change: Optional[Callable] = None,
        on_event: Optional[Callable] = None,
        timeout: int = 600,
        **kwargs
    ) -> Dict:
        """
        Create a task and monitor its execution.

        This is a convenience method that combines task creation with execution
        monitoring. It creates the task, optionally waits for completion, and
        collects metrics and events.

        Args:
            task_type: Type of task ('security-scan', 'development', 'catalog')
            repository: Repository in format 'owner/repo'
            wait_for_completion: Whether to wait for task to complete
            on_status_change: Callback for task status changes
            on_event: Callback for task events
            timeout: Maximum wait time in seconds (default: 600)
            **kwargs: Additional task-specific parameters passed to task creation

        Returns:
            Dictionary containing:
                - task_id: Created task identifier
                - final_status: Final task status (if wait_for_completion=True)
                - task: Final task state (if wait_for_completion=True)
                - metrics: Execution metrics
                - events: Task events
                - error: Error message (if any)

        Example:
            >>> # Security scan with monitoring
            >>> result = lifecycle.create_and_monitor(
            ...     task_type='security-scan',
            ...     repository='ry-ops/my-repo',
            ...     priority=TaskPriority.HIGH,
            ...     scan_types=['dependencies', 'secrets']
            ... )
            >>>
            >>> # Development task without waiting
            >>> result = lifecycle.create_and_monitor(
            ...     task_type='development',
            ...     repository='ry-ops/my-app',
            ...     requirements=['Add authentication', 'Add logging'],
            ...     wait_for_completion=False
            ... )
        """
        # Create task based on type
        try:
            if task_type == 'security-scan':
                task_id = self.task_manager.create_security_scan(
                    repository=repository,
                    **kwargs
                )
            elif task_type == 'development':
                task_id = self.task_manager.create_development_task(
                    repository=repository,
                    **kwargs
                )
            elif task_type == 'catalog':
                task_id = self.task_manager.create_catalog_task(
                    repository=repository,
                    **kwargs
                )
            else:
                raise ValueError(f"Unknown task type: {task_type}")

            print(f"Created task: {task_id}")

        except Exception as e:
            return {
                'task_id': None,
                'final_status': 'error',
                'error': str(e)
            }

        result = {
            'task_id': task_id,
            'final_status': None,
            'events': [],
            'metrics': {}
        }

        if not wait_for_completion:
            return result

        # Monitor execution
        try:
            # Get task events
            if on_event:
                events = self.event_stream.get_task_events(task_id)
                result['events'] = events

            # Wait for completion
            final_task = self.execution_monitor.wait_for_completion(
                task_id, timeout=timeout
            )

            result['final_status'] = final_task['status']
            result['task'] = final_task
            result['metrics'] = self.execution_monitor.get_execution_metrics(task_id)

            # Get final events
            result['events'] = self.event_stream.get_task_events(task_id)

        except TimeoutError as e:
            result['final_status'] = 'timeout'
            result['error'] = str(e)
            result['metrics'] = self.execution_monitor.get_execution_metrics(task_id)
        except Exception as e:
            result['final_status'] = 'error'
            result['error'] = str(e)

        return result

    def get_comprehensive_status(self, task_id: str) -> Dict:
        """
        Get comprehensive status for a task.

        Retrieves complete information about a task including its current state,
        health status, execution metrics, and related events.

        Args:
            task_id: Task ID to get status for

        Returns:
            Dictionary containing:
                - task: Current task state
                - health: Health status and warnings
                - metrics: Execution metrics
                - events: Related events

        Example:
            >>> status = lifecycle.get_comprehensive_status('task-025')
            >>>
            >>> print(f"Status: {status['task']['status']}")
            >>> print(f"Healthy: {status['health']['is_healthy']}")
            >>>
            >>> if not status['health']['is_healthy']:
            ...     for warning in status['health']['warnings']:
            ...         print(f"  Warning: {warning}")
        """
        task = self.task_manager.get_task(task_id)

        if not task:
            return {'error': 'Task not found'}

        return {
            'task': task,
            'health': self.health_monitor.get_task_health_status(task_id),
            'metrics': self.execution_monitor.get_execution_metrics(task_id),
            'events': self.event_stream.get_task_events(task_id)
        }

    def monitor_workflow(
        self,
        task_ids: List[str],
        timeout: int = 600
    ) -> Dict:
        """
        Monitor multiple tasks as a workflow.

        Tracks a group of related tasks as they execute, providing aggregated
        status and metrics.

        Args:
            task_ids: List of task IDs to monitor
            timeout: Maximum wait time in seconds

        Returns:
            Dictionary with workflow results and summary

        Example:
            >>> # Create multiple related tasks
            >>> task1 = lifecycle.task_manager.create_security_scan('owner/repo1')
            >>> task2 = lifecycle.task_manager.create_security_scan('owner/repo2')
            >>>
            >>> # Monitor as workflow
            >>> results = lifecycle.monitor_workflow([task1, task2], timeout=900)
            >>> print(f"Completed: {results['summary']['completed_count']}")
        """
        try:
            results = self.execution_monitor.monitor_multiple_tasks(
                task_ids, timeout=timeout
            )

            # Get summary
            summary = self.execution_monitor.get_task_progress_summary(task_ids)

            return {
                'status': 'completed',
                'results': results,
                'summary': summary
            }

        except TimeoutError as e:
            summary = self.execution_monitor.get_task_progress_summary(task_ids)
            return {
                'status': 'timeout',
                'error': str(e),
                'summary': summary
            }

    def get_system_health_summary(self) -> Dict:
        """
        Get overall system health summary.

        Provides a comprehensive view of the entire task system health,
        including statistics, issues, and recommendations.

        Returns:
            Dictionary with system-wide health information

        Example:
            >>> health = lifecycle.get_system_health_summary()
            >>> print(f"Overall: {health['overall_health']}")
            >>> print(f"Total tasks: {health['summary']['total_tasks']}")
            >>>
            >>> if health['recommendations']:
            ...     print("\\nRecommendations:")
            ...     for rec in health['recommendations']:
            ...         print(f"  - {rec}")
        """
        health_report = self.health_monitor.get_health_report()
        statistics = self.health_monitor.get_task_statistics()
        event_summary = self.event_stream.get_event_summary(hours=24)

        return {
            **health_report,
            'statistics': statistics,
            'event_summary': event_summary
        }

    def create_security_scan_workflow(
        self,
        repositories: List[str],
        scan_types: List[str] = None,
        priority: TaskPriority = TaskPriority.HIGH,
        wait_for_completion: bool = True,
        timeout: int = 1200
    ) -> Dict:
        """
        Create and monitor security scans for multiple repositories.

        Convenience method for running security scans across multiple
        repositories as a coordinated workflow.

        Args:
            repositories: List of repositories in 'owner/repo' format
            scan_types: Types of scans to perform
            priority: Task priority
            wait_for_completion: Whether to wait for all scans
            timeout: Maximum wait time for all scans

        Returns:
            Workflow results dictionary

        Example:
            >>> repos = ['ry-ops/repo1', 'ry-ops/repo2', 'ry-ops/repo3']
            >>> results = lifecycle.create_security_scan_workflow(
            ...     repositories=repos,
            ...     scan_types=['dependencies', 'secrets'],
            ...     timeout=1800
            ... )
            >>>
            >>> for task_id, task in results['results'].items():
            ...     print(f"{task_id}: {task['status']}")
        """
        if scan_types is None:
            scan_types = ['dependencies', 'static-analysis', 'secrets']

        # Create all scan tasks
        task_ids = []
        print(f"Creating security scans for {len(repositories)} repositories...")

        for repo in repositories:
            try:
                task_id = self.task_manager.create_security_scan(
                    repository=repo,
                    scan_types=scan_types,
                    priority=priority
                )
                task_ids.append(task_id)
                print(f"  Created {task_id} for {repo}")
            except Exception as e:
                print(f"  Error creating scan for {repo}: {e}")

        if not wait_for_completion:
            return {
                'task_ids': task_ids,
                'status': 'created'
            }

        # Monitor all tasks
        print(f"\nMonitoring {len(task_ids)} security scans...")
        return self.monitor_workflow(task_ids, timeout=timeout)

    def retry_failed_task(
        self,
        task_id: str,
        wait_for_completion: bool = True,
        timeout: int = 600
    ) -> Dict:
        """
        Retry a failed task.

        Creates a new task with the same configuration as the failed task
        and optionally monitors its execution.

        Args:
            task_id: ID of failed task to retry
            wait_for_completion: Whether to wait for retry completion
            timeout: Maximum wait time

        Returns:
            Result dictionary with new task information

        Example:
            >>> # Check for failed tasks
            >>> failed = lifecycle.task_manager.get_tasks_by_status(TaskStatus.FAILED)
            >>> if failed:
            ...     result = lifecycle.retry_failed_task(failed[0]['id'])
            ...     print(f"Retry task: {result['task_id']}")
        """
        original_task = self.task_manager.get_task(task_id)

        if not original_task:
            return {'error': f'Task {task_id} not found'}

        if original_task['status'] != 'failed':
            return {'error': f'Task {task_id} is not failed (status: {original_task["status"]})'}

        # Extract original task configuration
        task_type = original_task.get('type')
        context = original_task.get('context', {})

        # Create retry task
        print(f"Retrying task {task_id}...")
        try:
            if task_type == 'security-scan':
                new_task_id = self.task_manager.create_security_scan(
                    repository=context.get('repository'),
                    branch=context.get('branch', 'main'),
                    scan_types=context.get('scan_types'),
                    priority=TaskPriority.HIGH,
                    description=f"Retry of {task_id}: {context.get('description', '')}"
                )
            elif task_type == 'development':
                new_task_id = self.task_manager.create_development_task(
                    repository=context.get('repository'),
                    requirements=context.get('requirements', []),
                    branch=context.get('branch', 'main'),
                    priority=TaskPriority.HIGH,
                    description=f"Retry of {task_id}: {context.get('description', '')}"
                )
            else:
                return {'error': f'Unsupported task type for retry: {task_type}'}

            result = {
                'original_task_id': task_id,
                'task_id': new_task_id,
                'status': 'created'
            }

            if wait_for_completion:
                final_task = self.execution_monitor.wait_for_completion(
                    new_task_id, timeout=timeout
                )
                result['final_status'] = final_task['status']
                result['task'] = final_task

            return result

        except Exception as e:
            return {'error': f'Failed to retry task: {e}'}
