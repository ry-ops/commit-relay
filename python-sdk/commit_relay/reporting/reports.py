"""
Report generation for commit-relay metrics.

Creates text and markdown reports summarizing system status and metrics.
"""

from typing import Optional, Dict, Any
from datetime import datetime


class ReportGenerator:
    """
    Generate comprehensive reports.

    Creates text and markdown reports summarizing metrics, health status,
    and system performance.

    Example:
        >>> from commit_relay.reporting import ReportGenerator
        >>> generator = ReportGenerator(client)
        >>> report = generator.generate_daily_summary()
        >>> print(report)
        >>> generator.export_to_markdown('/tmp/report.md', hours=24)
    """

    def __init__(self, client):
        """
        Initialize ReportGenerator.

        Args:
            client: CommitRelayClient instance
        """
        self.client = client

    def generate_daily_summary(self, hours: int = 24) -> str:
        """
        Generate daily summary report.

        Args:
            hours: Hours to cover in report

        Returns:
            Formatted text report

        Example:
            >>> report = generator.generate_daily_summary()
            >>> print(report)
        """
        from ..monitoring import HealthChecker
        from ..analytics import MetricsAggregator

        try:
            metrics = self.client.metrics.get_current()
            workers = self.client.workers.list()
            health_checker = HealthChecker(self.client)
            health_checks = health_checker.run_all_checks()
            aggregator = MetricsAggregator(self.client)
            summary_stats = aggregator.get_comprehensive_summary(hours=hours)

            report = f"""
{'='*70}
COMMIT-RELAY DAILY SUMMARY REPORT
{'='*70}
Generated: {datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S UTC')}
Time Period: Last {hours} hours

{'='*70}
CURRENT SYSTEM STATUS
{'='*70}
Active Workers:      {metrics.get('active_workers', 0)}
Total Workers:       {len(workers)}
Tasks Pending:       {metrics.get('tasks_pending', 0)}
Tasks In Progress:   {metrics.get('tasks_in_progress', 0)}
Tasks Completed:     {metrics.get('tasks_completed', 0)}
Tasks Failed:        {metrics.get('tasks_failed', 0)}
Success Rate:        {metrics.get('success_rate', 0):.1f}%

{'='*70}
PERIOD STATISTICS ({hours}h)
{'='*70}
Worker Stats:
  - Avg Active:      {summary_stats['worker_stats'].get('avg_active_workers', 0):.1f}
  - Max Active:      {summary_stats['worker_stats'].get('max_active_workers', 0)}
  - Min Active:      {summary_stats['worker_stats'].get('min_active_workers', 0)}

Task Stats:
  - Total Completed: {summary_stats['task_stats'].get('total_tasks_completed', 0)}
  - Total Failed:    {summary_stats['task_stats'].get('total_tasks_failed', 0)}
  - Avg Success:     {summary_stats['task_stats'].get('avg_success_rate', 0):.1f}%

{'='*70}
HEALTH CHECK RESULTS
{'='*70}
"""
            # Add health checks
            status_symbols = {
                'healthy': '✓',
                'warning': '!',
                'critical': '✗',
                'unknown': '?',
            }

            for check in health_checks:
                symbol = status_symbols.get(check['status'], '?')
                report += f"[{symbol}] {check['check']:20s}: {check['message']}\n"

            report += f"\n{'='*70}\n"
            report += "END OF REPORT\n"
            report += f"{'='*70}\n"

            return report

        except Exception as e:
            return f"Error generating report: {str(e)}"

    def generate_markdown_report(self, hours: int = 24) -> str:
        """
        Generate markdown-formatted report.

        Args:
            hours: Hours to cover

        Returns:
            Markdown formatted report
        """
        from ..monitoring import HealthChecker
        from ..analytics import MetricsAggregator

        try:
            metrics = self.client.metrics.get_current()
            health_checker = HealthChecker(self.client)
            health = health_checker.get_overall_health()
            aggregator = MetricsAggregator(self.client)
            summary = aggregator.get_comprehensive_summary(hours=hours)

            report = f"""# Commit-Relay Summary Report

**Generated:** {datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S UTC')}
**Period:** Last {hours} hours

## System Overview

| Metric | Value |
|--------|-------|
| Active Workers | {metrics.get('active_workers', 0)} |
| Tasks Pending | {metrics.get('tasks_pending', 0)} |
| Tasks In Progress | {metrics.get('tasks_in_progress', 0)} |
| Success Rate | {metrics.get('success_rate', 0):.1f}% |

## Health Status

**Overall Status:** {health['overall_status'].upper()}

| Check | Status | Message |
|-------|--------|---------|
"""
            for check in health['checks']:
                status_emoji = {'healthy': '✅', 'warning': '⚠️', 'critical': '🚨', 'unknown': '❓'}.get(check['status'], '❓')
                report += f"| {check['check']} | {status_emoji} {check['status']} | {check['message']} |\n"

            report += f"""
## Period Statistics ({hours}h)

### Worker Metrics
- **Average Active:** {summary['worker_stats'].get('avg_active_workers', 0):.1f}
- **Peak Active:** {summary['worker_stats'].get('max_active_workers', 0)}
- **Minimum Active:** {summary['worker_stats'].get('min_active_workers', 0)}

### Task Metrics
- **Total Completed:** {summary['task_stats'].get('total_tasks_completed', 0)}
- **Total Failed:** {summary['task_stats'].get('total_tasks_failed', 0)}
- **Average Success Rate:** {summary['task_stats'].get('avg_success_rate', 0):.1f}%

---
*Report generated by commit-relay-client SDK*
"""
            return report

        except Exception as e:
            return f"# Error\n\nFailed to generate report: {str(e)}"

    def export_to_markdown(
        self,
        filepath: str,
        hours: int = 24
    ):
        """
        Export report to markdown file.

        Args:
            filepath: Path to save markdown file
            hours: Hours to cover

        Example:
            >>> generator.export_to_markdown('/tmp/report.md', hours=24)
        """
        report = self.generate_markdown_report(hours=hours)

        with open(filepath, 'w') as f:
            f.write(report)

        print(f"Report exported to: {filepath}")

    def export_to_text(
        self,
        filepath: str,
        hours: int = 24
    ):
        """
        Export report to text file.

        Args:
            filepath: Path to save text file
            hours: Hours to cover
        """
        report = self.generate_daily_summary(hours=hours)

        with open(filepath, 'w') as f:
            f.write(report)

        print(f"Report exported to: {filepath}")

    def generate_worker_report(self) -> str:
        """
        Generate detailed worker report.

        Returns:
            Formatted worker report
        """
        workers = self.client.workers.list()
        stats = self.client.workers.get_stats()

        report = f"""
{'='*70}
WORKER POOL REPORT
{'='*70}
Generated: {datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S UTC')}

Total Workers: {stats['total']}
Active Workers: {stats['active']}

Workers by Type:
"""
        for worker_type, count in stats['by_type'].items():
            report += f"  - {worker_type}: {count}\n"

        report += "\nWorkers by Master:\n"
        for master, count in stats['by_master'].items():
            report += f"  - {master}: {count}\n"

        report += "\nWorkers by Status:\n"
        for status, count in stats['by_status'].items():
            report += f"  - {status}: {count}\n"

        report += f"\n{'='*70}\n"

        return report

    def generate_executive_summary(self, hours: int = 24) -> str:
        """
        Generate executive-level summary.

        Args:
            hours: Hours to analyze

        Returns:
            Executive summary report
        """
        from ..analytics import MetricsAggregator, TrendAnalyzer

        try:
            aggregator = MetricsAggregator(self.client)
            summary = aggregator.get_comprehensive_summary(hours=hours)
            df = self.client.metrics.to_dataframe(hours=hours)

            # Detect trends
            success_trend = None
            worker_trend = None

            if not df.empty:
                if 'success_rate' in df.columns:
                    success_trend = TrendAnalyzer.detect_trend(df['success_rate'])
                if 'active_workers' in df.columns:
                    worker_trend = TrendAnalyzer.detect_trend(df['active_workers'])

            report = f"""
EXECUTIVE SUMMARY - COMMIT-RELAY SYSTEM
{datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S UTC')}

KEY METRICS (Last {hours}h):
- Task Success Rate: {summary['task_stats'].get('avg_success_rate', 0):.1f}%
- Tasks Completed: {summary['task_stats'].get('total_tasks_completed', 0)}
- Average Active Workers: {summary['worker_stats'].get('avg_active_workers', 0):.1f}
"""

            if success_trend and 'direction' in success_trend:
                report += f"\nSUCCESS RATE TREND: {success_trend['direction'].upper()}"
                if success_trend.get('significant'):
                    report += f" (confidence: {success_trend.get('confidence', 0):.1%})"

            if worker_trend and 'direction' in worker_trend:
                report += f"\nWORKER ACTIVITY TREND: {worker_trend['direction'].upper()}"

            return report

        except Exception as e:
            return f"Executive Summary Error: {str(e)}"
