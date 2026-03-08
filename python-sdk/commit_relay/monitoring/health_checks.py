"""
Health monitoring for commit-relay system.

Provides comprehensive health checks for workers, tasks, and system metrics.
"""

from typing import List, Dict, Any
from enum import Enum


class HealthStatus(Enum):
    """Health status levels."""
    HEALTHY = 'healthy'
    WARNING = 'warning'
    CRITICAL = 'critical'
    UNKNOWN = 'unknown'


class HealthChecker:
    """
    Perform health checks on commit-relay system.

    Monitors various aspects of the system including worker pool health,
    task success rates, and system responsiveness.

    Example:
        >>> from commit_relay import CommitRelayClient
        >>> from commit_relay.monitoring import HealthChecker
        >>> client = CommitRelayClient()
        >>> checker = HealthChecker(client)
        >>> results = checker.run_all_checks()
        >>> for check in results:
        ...     print(f"{check['check']}: {check['status']}")
    """

    def __init__(self, client):
        """
        Initialize HealthChecker.

        Args:
            client: CommitRelayClient instance
        """
        self.client = client

    def check_worker_pool(
        self,
        min_workers: int = 1,
        warning_threshold: int = 3
    ) -> Dict[str, Any]:
        """
        Check if worker pool is healthy.

        Args:
            min_workers: Minimum acceptable number of workers
            warning_threshold: Warn if below this many workers

        Returns:
            Dictionary containing check results

        Example:
            >>> result = checker.check_worker_pool(min_workers=1, warning_threshold=3)
            >>> print(f"Status: {result['status']}")
        """
        try:
            workers = self.client.workers.list()
            active_count = len([w for w in workers if w.get('status') == 'active'])

            if active_count < min_workers:
                status = HealthStatus.CRITICAL
                message = f"Critical: Only {active_count} active workers (minimum: {min_workers})"
            elif active_count < warning_threshold:
                status = HealthStatus.WARNING
                message = f"Warning: Low worker count ({active_count} < {warning_threshold})"
            else:
                status = HealthStatus.HEALTHY
                message = f"Healthy: {active_count} workers active"

            return {
                'check': 'worker_pool',
                'status': status.value,
                'message': message,
                'active_workers': active_count,
                'total_workers': len(workers),
                'passed': status in [HealthStatus.HEALTHY, HealthStatus.WARNING],
            }

        except Exception as e:
            return {
                'check': 'worker_pool',
                'status': HealthStatus.UNKNOWN.value,
                'message': f"Error checking workers: {str(e)}",
                'passed': False,
                'error': str(e),
            }

    def check_success_rate(
        self,
        warning_threshold: float = 75.0,
        critical_threshold: float = 50.0
    ) -> Dict[str, Any]:
        """
        Check if task success rate is acceptable.

        Args:
            warning_threshold: Warn if success rate below this percentage
            critical_threshold: Critical if below this percentage

        Returns:
            Dictionary containing check results
        """
        try:
            metrics = self.client.metrics.get_current()
            success_rate = metrics.get('success_rate', 0)

            if success_rate < critical_threshold:
                status = HealthStatus.CRITICAL
                message = f"Critical: Success rate {success_rate}% (threshold: {critical_threshold}%)"
            elif success_rate < warning_threshold:
                status = HealthStatus.WARNING
                message = f"Warning: Success rate {success_rate}% (threshold: {warning_threshold}%)"
            else:
                status = HealthStatus.HEALTHY
                message = f"Healthy: Success rate {success_rate}%"

            return {
                'check': 'success_rate',
                'status': status.value,
                'message': message,
                'value': success_rate,
                'warning_threshold': warning_threshold,
                'critical_threshold': critical_threshold,
                'passed': status in [HealthStatus.HEALTHY, HealthStatus.WARNING],
            }

        except Exception as e:
            return {
                'check': 'success_rate',
                'status': HealthStatus.UNKNOWN.value,
                'message': f"Error checking success rate: {str(e)}",
                'passed': False,
                'error': str(e),
            }

    def check_task_backlog(
        self,
        warning_threshold: int = 10,
        critical_threshold: int = 20
    ) -> Dict[str, Any]:
        """
        Check for task backlog buildup.

        Args:
            warning_threshold: Warn if pending tasks exceed this
            critical_threshold: Critical if pending tasks exceed this

        Returns:
            Dictionary containing check results
        """
        try:
            metrics = self.client.metrics.get_current()
            pending_tasks = metrics.get('tasks_pending', 0)

            if pending_tasks >= critical_threshold:
                status = HealthStatus.CRITICAL
                message = f"Critical: {pending_tasks} pending tasks (threshold: {critical_threshold})"
            elif pending_tasks >= warning_threshold:
                status = HealthStatus.WARNING
                message = f"Warning: {pending_tasks} pending tasks (threshold: {warning_threshold})"
            else:
                status = HealthStatus.HEALTHY
                message = f"Healthy: {pending_tasks} pending tasks"

            return {
                'check': 'task_backlog',
                'status': status.value,
                'message': message,
                'pending_tasks': pending_tasks,
                'warning_threshold': warning_threshold,
                'critical_threshold': critical_threshold,
                'passed': status in [HealthStatus.HEALTHY, HealthStatus.WARNING],
            }

        except Exception as e:
            return {
                'check': 'task_backlog',
                'status': HealthStatus.UNKNOWN.value,
                'message': f"Error checking task backlog: {str(e)}",
                'passed': False,
                'error': str(e),
            }

    def check_api_connectivity(self) -> Dict[str, Any]:
        """
        Check API connectivity and responsiveness.

        Returns:
            Dictionary containing check results
        """
        try:
            is_reachable = self.client.ping()

            if is_reachable:
                status = HealthStatus.HEALTHY
                message = "API is reachable and responsive"
            else:
                status = HealthStatus.CRITICAL
                message = "API is not responding"

            return {
                'check': 'api_connectivity',
                'status': status.value,
                'message': message,
                'passed': is_reachable,
            }

        except Exception as e:
            return {
                'check': 'api_connectivity',
                'status': HealthStatus.CRITICAL.value,
                'message': f"API connectivity error: {str(e)}",
                'passed': False,
                'error': str(e),
            }

    def check_failed_tasks(
        self,
        hours: int = 1,
        warning_threshold: int = 5,
        critical_threshold: int = 10
    ) -> Dict[str, Any]:
        """
        Check for recent failed tasks.

        Args:
            hours: Time period to check
            warning_threshold: Warn if failures exceed this
            critical_threshold: Critical if failures exceed this

        Returns:
            Dictionary containing check results
        """
        try:
            # Get recent metrics
            history = self.client.metrics.get_history(hours=hours)

            if not history:
                return {
                    'check': 'failed_tasks',
                    'status': HealthStatus.UNKNOWN.value,
                    'message': 'No metrics data available',
                    'passed': False,
                }

            # Sum up failed tasks
            total_failed = sum(m.get('tasks_failed', 0) for m in history)

            if total_failed >= critical_threshold:
                status = HealthStatus.CRITICAL
                message = f"Critical: {total_failed} failed tasks in last {hours}h"
            elif total_failed >= warning_threshold:
                status = HealthStatus.WARNING
                message = f"Warning: {total_failed} failed tasks in last {hours}h"
            else:
                status = HealthStatus.HEALTHY
                message = f"Healthy: {total_failed} failed tasks in last {hours}h"

            return {
                'check': 'failed_tasks',
                'status': status.value,
                'message': message,
                'failed_tasks': total_failed,
                'time_period_hours': hours,
                'warning_threshold': warning_threshold,
                'critical_threshold': critical_threshold,
                'passed': status in [HealthStatus.HEALTHY, HealthStatus.WARNING],
            }

        except Exception as e:
            return {
                'check': 'failed_tasks',
                'status': HealthStatus.UNKNOWN.value,
                'message': f"Error checking failed tasks: {str(e)}",
                'passed': False,
                'error': str(e),
            }

    def run_all_checks(self, verbose: bool = False) -> List[Dict[str, Any]]:
        """
        Run all health checks.

        Args:
            verbose: Include detailed information in results

        Returns:
            List of check results

        Example:
            >>> results = checker.run_all_checks()
            >>> critical = [r for r in results if r['status'] == 'critical']
            >>> if critical:
            ...     print(f"Found {len(critical)} critical issues!")
        """
        checks = [
            self.check_api_connectivity(),
            self.check_worker_pool(),
            self.check_success_rate(),
            self.check_task_backlog(),
            self.check_failed_tasks(),
        ]

        return checks

    def get_overall_health(self) -> Dict[str, Any]:
        """
        Get overall system health summary.

        Returns:
            Dictionary with overall health status and summary

        Example:
            >>> health = checker.get_overall_health()
            >>> print(f"Overall: {health['overall_status']}")
            >>> print(f"Critical issues: {health['critical_count']}")
        """
        checks = self.run_all_checks()

        status_counts = {
            'healthy': 0,
            'warning': 0,
            'critical': 0,
            'unknown': 0,
        }

        for check in checks:
            status = check.get('status', 'unknown')
            status_counts[status] = status_counts.get(status, 0) + 1

        # Determine overall status
        if status_counts['critical'] > 0:
            overall_status = HealthStatus.CRITICAL
        elif status_counts['warning'] > 0:
            overall_status = HealthStatus.WARNING
        elif status_counts['unknown'] > 0:
            overall_status = HealthStatus.UNKNOWN
        else:
            overall_status = HealthStatus.HEALTHY

        return {
            'overall_status': overall_status.value,
            'total_checks': len(checks),
            'healthy_count': status_counts['healthy'],
            'warning_count': status_counts['warning'],
            'critical_count': status_counts['critical'],
            'unknown_count': status_counts['unknown'],
            'checks': checks,
            'is_healthy': overall_status == HealthStatus.HEALTHY,
        }

    def print_health_report(self):
        """
        Print formatted health report to console.

        Example:
            >>> checker.print_health_report()
            Health Check Results
            ====================
            [✓] api_connectivity: API is reachable
            [✓] worker_pool: 5 workers active
            [!] success_rate: Success rate 72%
        """
        health = self.get_overall_health()

        status_symbols = {
            'healthy': '✓',
            'warning': '!',
            'critical': '✗',
            'unknown': '?',
        }

        print("\n" + "="*60)
        print("COMMIT-RELAY HEALTH CHECK REPORT")
        print("="*60)
        print(f"Overall Status: {health['overall_status'].upper()}")
        print(f"Total Checks: {health['total_checks']}")
        print(f"  Healthy: {health['healthy_count']}")
        print(f"  Warnings: {health['warning_count']}")
        print(f"  Critical: {health['critical_count']}")
        print(f"  Unknown: {health['unknown_count']}")
        print("="*60)
        print()

        for check in health['checks']:
            symbol = status_symbols.get(check['status'], '?')
            print(f"[{symbol}] {check['check']:20s}: {check['message']}")

        print()
