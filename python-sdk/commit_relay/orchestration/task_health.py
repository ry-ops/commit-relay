"""
Task Health Monitor - Task-specific health checks and diagnostics.

Provides APIs to monitor task health, detect stalled tasks, identify issues,
and generate health reports for the commit-relay system.
"""

from typing import Dict, List, Optional
from datetime import datetime, timedelta
from .task_manager import TaskStatus


class TaskHealthMonitor:
    """
    Monitor health of tasks and detect issues.

    The TaskHealthMonitor analyzes task states to identify problems like
    stalled tasks, unassigned pending tasks, and other health issues. It
    provides recommendations for resolving identified issues.

    Example:
        >>> from commit_relay import CommitRelayClient, TaskManager, TaskHealthMonitor
        >>> client = CommitRelayClient()
        >>> manager = TaskManager()
        >>> health = TaskHealthMonitor(manager, client)
        >>>
        >>> # Check for stalled tasks
        >>> stalled = health.find_stalled_tasks(threshold_minutes=60)
        >>> if stalled:
        ...     print(f"Found {len(stalled)} stalled tasks!")
        >>>
        >>> # Get comprehensive health report
        >>> report = health.get_health_report()
        >>> for rec in report['recommendations']:
        ...     print(f"Recommendation: {rec}")

    Attributes:
        task_manager: TaskManager instance for accessing task data
        client: CommitRelayClient instance for system-level checks
    """

    def __init__(self, task_manager, client):
        """
        Initialize TaskHealthMonitor.

        Args:
            task_manager: TaskManager instance to use
            client: CommitRelayClient instance for API access
        """
        self.task_manager = task_manager
        self.client = client

    def find_stalled_tasks(
        self,
        threshold_minutes: int = 60
    ) -> List[Dict]:
        """
        Find tasks that have been in-progress for too long.

        A task is considered stalled if it has been in the 'in-progress' state
        for longer than the specified threshold without completion.

        Args:
            threshold_minutes: Time threshold in minutes for considering
                              a task stalled (default: 60)

        Returns:
            List of stalled task summaries, each containing:
                - task_id: Task identifier
                - title: Task title
                - age_minutes: Minutes since task creation
                - assigned_to: Worker handling the task

        Example:
            >>> stalled = health.find_stalled_tasks(threshold_minutes=45)
            >>> for task in stalled:
            ...     print(f"{task['task_id']}: {task['age_minutes']:.1f} minutes")
        """
        in_progress = self.task_manager.get_in_progress_tasks()
        stalled = []

        for task in in_progress:
            created_at = datetime.fromisoformat(
                task['created_at'].replace('Z', '+00:00')
            )
            age = datetime.now(created_at.tzinfo) - created_at

            if age > timedelta(minutes=threshold_minutes):
                stalled.append({
                    'task_id': task['id'],
                    'title': task['title'],
                    'age_minutes': age.total_seconds() / 60,
                    'assigned_to': task.get('assigned_to'),
                    'type': task.get('type', 'unknown')
                })

        return stalled

    def find_pending_tasks_without_worker(self) -> List[Dict]:
        """
        Find pending tasks that haven't been assigned to a worker.

        These tasks are waiting to be picked up by the worker daemon. A large
        number of unassigned pending tasks may indicate worker daemon issues.

        Returns:
            List of unassigned pending task summaries, each containing:
                - task_id: Task identifier
                - title: Task title
                - priority: Task priority level
                - age_minutes: Minutes since task creation

        Example:
            >>> unassigned = health.find_pending_tasks_without_worker()
            >>> if len(unassigned) > 5:
            ...     print("Worker daemon may not be running!")
        """
        pending = self.task_manager.get_pending_tasks()

        return [{
            'task_id': task['id'],
            'title': task['title'],
            'priority': task['priority'],
            'age_minutes': self._get_age_minutes(task['created_at']),
            'type': task.get('type', 'unknown')
        } for task in pending if not task.get('assigned_to')]

    def find_old_pending_tasks(
        self,
        threshold_minutes: int = 30
    ) -> List[Dict]:
        """
        Find pending tasks that have been waiting too long.

        Args:
            threshold_minutes: Time threshold in minutes (default: 30)

        Returns:
            List of old pending task summaries

        Example:
            >>> old_pending = health.find_old_pending_tasks(threshold_minutes=15)
            >>> for task in old_pending:
            ...     print(f"{task['task_id']}: waiting {task['age_minutes']:.1f}m")
        """
        pending = self.task_manager.get_pending_tasks()
        old_tasks = []

        for task in pending:
            age_minutes = self._get_age_minutes(task['created_at'])
            if age_minutes > threshold_minutes:
                old_tasks.append({
                    'task_id': task['id'],
                    'title': task['title'],
                    'priority': task['priority'],
                    'age_minutes': age_minutes,
                    'assigned_to': task.get('assigned_to')
                })

        return old_tasks

    def get_task_health_status(self, task_id: str) -> Dict:
        """
        Get health status for a specific task.

        Analyzes the task state and returns a health assessment with warnings
        and recommendations for addressing any identified issues.

        Args:
            task_id: Task ID to check

        Returns:
            Health status dictionary containing:
                - task_id: Task identifier
                - status: Current task status
                - age_minutes: Minutes since task creation
                - warnings: List of warning messages
                - recommendations: List of recommended actions
                - is_healthy: Boolean indicating overall health

        Example:
            >>> health_status = health.get_task_health_status('task-025')
            >>> if not health_status['is_healthy']:
            ...     print("Issues found:")
            ...     for warning in health_status['warnings']:
            ...         print(f"  - {warning}")
        """
        task = self.task_manager.get_task(task_id)

        if not task:
            return {
                'status': 'not_found',
                'is_healthy': False,
                'warnings': ['Task not found'],
                'recommendations': ['Verify task ID is correct']
            }

        age_minutes = self._get_age_minutes(task['created_at'])

        health = {
            'task_id': task_id,
            'status': task['status'],
            'age_minutes': age_minutes,
            'warnings': [],
            'recommendations': [],
            'assigned_to': task.get('assigned_to')
        }

        # Check for issues based on status and age
        if task['status'] == 'pending':
            if not task.get('assigned_to') and age_minutes > 30:
                health['warnings'].append(
                    f"Task pending for {age_minutes:.1f} minutes without worker assignment"
                )
                health['recommendations'].append(
                    "Check worker daemon status with: systemctl status commit-relay-worker"
                )
            elif task.get('assigned_to') and age_minutes > 15:
                health['warnings'].append(
                    f"Task assigned but still pending for {age_minutes:.1f} minutes"
                )
                health['recommendations'].append(
                    f"Check worker {task['assigned_to']} logs for issues"
                )

        if task['status'] == 'in-progress':
            if age_minutes > 60:
                health['warnings'].append(
                    f"Task in-progress for {age_minutes:.1f} minutes (potential stall)"
                )
                health['recommendations'].append(
                    f"Review worker logs: {task.get('assigned_to', 'unknown')}"
                )
            elif age_minutes > 90:
                health['warnings'].append(
                    f"Task critically stalled: {age_minutes:.1f} minutes"
                )
                health['recommendations'].append(
                    "Consider restarting worker or marking task as failed"
                )

        if task['status'] == 'failed':
            health['warnings'].append("Task failed")
            health['recommendations'].append(
                "Review task results and failure reason"
            )
            health['recommendations'].append(
                "Consider retrying task or investigating root cause"
            )

        if task['status'] == 'completed':
            # Completed tasks are healthy
            pass

        health['is_healthy'] = len(health['warnings']) == 0

        return health

    def get_health_report(self) -> Dict:
        """
        Generate comprehensive health report for all tasks.

        Analyzes the entire task queue and generates a complete health report
        with summary statistics, identified issues, and recommendations.

        Returns:
            Health report dictionary containing:
                - timestamp: Report generation timestamp
                - summary: Task count statistics by status
                - issues: Identified problems (stalled, unassigned, etc.)
                - recommendations: List of recommended actions
                - overall_health: Overall system health assessment

        Example:
            >>> report = health.get_health_report()
            >>> print(f"Total tasks: {report['summary']['total_tasks']}")
            >>> print(f"Overall health: {report['overall_health']}")
            >>>
            >>> if report['recommendations']:
            ...     print("\\nRecommendations:")
            ...     for rec in report['recommendations']:
            ...         print(f"  - {rec}")
        """
        all_tasks = self.task_manager.get_all_tasks()

        report = {
            'timestamp': datetime.utcnow().isoformat() + 'Z',
            'summary': {
                'total_tasks': len(all_tasks),
                'pending': len([t for t in all_tasks if t['status'] == 'pending']),
                'in_progress': len([t for t in all_tasks if t['status'] == 'in-progress']),
                'completed': len([t for t in all_tasks if t['status'] == 'completed']),
                'failed': len([t for t in all_tasks if t['status'] == 'failed'])
            },
            'issues': {
                'stalled_tasks': self.find_stalled_tasks(),
                'unassigned_pending': self.find_pending_tasks_without_worker(),
                'old_pending': self.find_old_pending_tasks()
            },
            'recommendations': []
        }

        # Generate recommendations based on issues
        if report['issues']['stalled_tasks']:
            count = len(report['issues']['stalled_tasks'])
            report['recommendations'].append(
                f"{count} stalled task(s) detected - check worker health and logs"
            )

        if report['issues']['unassigned_pending']:
            count = len(report['issues']['unassigned_pending'])
            report['recommendations'].append(
                f"{count} pending task(s) without workers - verify daemon is running"
            )

        if report['issues']['old_pending']:
            count = len(report['issues']['old_pending'])
            report['recommendations'].append(
                f"{count} task(s) have been pending for a long time - check worker capacity"
            )

        if report['summary']['failed'] > 0:
            report['recommendations'].append(
                f"{report['summary']['failed']} failed task(s) - review and consider retry"
            )

        # Calculate overall health score
        total_issues = (
            len(report['issues']['stalled_tasks']) +
            len(report['issues']['unassigned_pending']) +
            len(report['issues']['old_pending']) +
            report['summary']['failed']
        )

        if total_issues == 0:
            report['overall_health'] = 'HEALTHY'
        elif total_issues <= 2:
            report['overall_health'] = 'WARNING'
        else:
            report['overall_health'] = 'CRITICAL'

        return report

    def get_task_statistics(self) -> Dict:
        """
        Get statistical analysis of tasks.

        Returns:
            Dictionary with task statistics including averages and distributions

        Example:
            >>> stats = health.get_task_statistics()
            >>> print(f"Average duration: {stats['avg_duration_minutes']:.1f}m")
        """
        all_tasks = self.task_manager.get_all_tasks()
        completed_tasks = [t for t in all_tasks if t['status'] == 'completed']

        # Calculate duration statistics for completed tasks
        durations = []
        for task in completed_tasks:
            if task.get('completed_at'):
                created = datetime.fromisoformat(task['created_at'].replace('Z', '+00:00'))
                completed = datetime.fromisoformat(task['completed_at'].replace('Z', '+00:00'))
                duration = (completed - created).total_seconds() / 60
                durations.append(duration)

        stats = {
            'total_tasks': len(all_tasks),
            'completed_tasks': len(completed_tasks),
            'avg_duration_minutes': sum(durations) / len(durations) if durations else 0,
            'min_duration_minutes': min(durations) if durations else 0,
            'max_duration_minutes': max(durations) if durations else 0,
            'task_types': {},
            'task_priorities': {}
        }

        # Count by type
        for task in all_tasks:
            task_type = task.get('type', 'unknown')
            stats['task_types'][task_type] = stats['task_types'].get(task_type, 0) + 1

        # Count by priority
        for task in all_tasks:
            priority = task.get('priority', 'unknown')
            stats['task_priorities'][priority] = stats['task_priorities'].get(priority, 0) + 1

        return stats

    def _get_age_minutes(self, created_at_str: str) -> float:
        """
        Calculate task age in minutes.

        Args:
            created_at_str: ISO format timestamp string

        Returns:
            Age in minutes as float
        """
        created_at = datetime.fromisoformat(created_at_str.replace('Z', '+00:00'))
        return (datetime.now(created_at.tzinfo) - created_at).total_seconds() / 60
