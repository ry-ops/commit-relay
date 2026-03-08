"""
Visualization tools for commit-relay metrics.

Creates charts and graphs for metrics analysis and reporting.
"""

from typing import Optional, List
import warnings


class DashboardVisualizer:
    """
    Create visualizations for metrics and analytics.

    Generates various charts including line plots, bar charts, and
    comprehensive dashboard views.

    Example:
        >>> from commit_relay.reporting import DashboardVisualizer
        >>> viz = DashboardVisualizer(client)
        >>> viz.plot_worker_activity(hours=24, save_path='/tmp/workers.png')
        >>> viz.create_dashboard(hours=24, save_path='/tmp/dashboard.png')
    """

    def __init__(self, client):
        """
        Initialize DashboardVisualizer.

        Args:
            client: CommitRelayClient instance
        """
        self.client = client

    def plot_worker_activity(
        self,
        hours: int = 24,
        save_path: Optional[str] = None,
        figsize: tuple = (12, 6)
    ):
        """
        Plot worker activity over time.

        Args:
            hours: Hours of history to plot
            save_path: Path to save figure (None = display)
            figsize: Figure size (width, height)

        Example:
            >>> viz.plot_worker_activity(hours=24, save_path='/tmp/workers.png')
        """
        try:
            import matplotlib.pyplot as plt
            import seaborn as sns

            sns.set_style('darkgrid')

            df = self.client.metrics.to_dataframe(hours=hours)

            if df.empty or 'active_workers' not in df.columns:
                print("No worker activity data available")
                return

            fig, ax = plt.subplots(figsize=figsize)
            ax.plot(df['timestamp'], df['active_workers'], marker='o', linewidth=2, color='#2E86AB')
            ax.set_xlabel('Time', fontsize=12)
            ax.set_ylabel('Active Workers', fontsize=12)
            ax.set_title(f'Worker Activity (Last {hours}h)', fontsize=14, fontweight='bold')
            ax.grid(True, alpha=0.3)
            plt.xticks(rotation=45)
            plt.tight_layout()

            if save_path:
                plt.savefig(save_path, dpi=300, bbox_inches='tight')
                print(f"Saved to {save_path}")
            else:
                plt.show()

            plt.close()

        except ImportError:
            warnings.warn("matplotlib and seaborn required. Install with: pip install matplotlib seaborn")

    def plot_success_rate(
        self,
        hours: int = 24,
        save_path: Optional[str] = None,
        threshold: float = 75.0,
        figsize: tuple = (12, 6)
    ):
        """
        Plot task success rate trends.

        Args:
            hours: Hours of history
            save_path: Path to save figure
            threshold: Threshold line to display
            figsize: Figure size
        """
        try:
            import matplotlib.pyplot as plt
            import seaborn as sns

            sns.set_style('darkgrid')

            df = self.client.metrics.to_dataframe(hours=hours)

            if df.empty or 'success_rate' not in df.columns:
                print("No success rate data available")
                return

            fig, ax = plt.subplots(figsize=figsize)
            ax.plot(df['timestamp'], df['success_rate'], color='#06A77D', marker='o', linewidth=2, label='Success Rate')
            ax.axhline(y=threshold, color='#D62246', linestyle='--', linewidth=2, label=f'Threshold ({threshold}%)')
            ax.set_xlabel('Time', fontsize=12)
            ax.set_ylabel('Success Rate (%)', fontsize=12)
            ax.set_title(f'Task Success Rate (Last {hours}h)', fontsize=14, fontweight='bold')
            ax.legend()
            ax.grid(True, alpha=0.3)
            ax.set_ylim(0, 105)
            plt.xticks(rotation=45)
            plt.tight_layout()

            if save_path:
                plt.savefig(save_path, dpi=300, bbox_inches='tight')
                print(f"Saved to {save_path}")
            else:
                plt.show()

            plt.close()

        except ImportError:
            warnings.warn("matplotlib and seaborn required")

    def plot_task_throughput(
        self,
        hours: int = 24,
        save_path: Optional[str] = None,
        figsize: tuple = (12, 6)
    ):
        """
        Plot task throughput (completed tasks).

        Args:
            hours: Hours of history
            save_path: Path to save figure
            figsize: Figure size
        """
        try:
            import matplotlib.pyplot as plt
            import seaborn as sns

            sns.set_style('darkgrid')

            df = self.client.metrics.to_dataframe(hours=hours)

            if df.empty or 'tasks_completed' not in df.columns:
                print("No task throughput data available")
                return

            fig, ax = plt.subplots(figsize=figsize)
            ax.bar(df['timestamp'], df['tasks_completed'], color='#F77F00', alpha=0.7, width=0.02)
            ax.set_xlabel('Time', fontsize=12)
            ax.set_ylabel('Tasks Completed', fontsize=12)
            ax.set_title(f'Task Throughput (Last {hours}h)', fontsize=14, fontweight='bold')
            ax.grid(True, alpha=0.3, axis='y')
            plt.xticks(rotation=45)
            plt.tight_layout()

            if save_path:
                plt.savefig(save_path, dpi=300, bbox_inches='tight')
                print(f"Saved to {save_path}")
            else:
                plt.show()

            plt.close()

        except ImportError:
            warnings.warn("matplotlib and seaborn required")

    def create_dashboard(
        self,
        hours: int = 24,
        save_path: Optional[str] = None,
        figsize: tuple = (16, 12)
    ):
        """
        Create comprehensive dashboard with multiple metrics.

        Args:
            hours: Hours of history
            save_path: Path to save figure
            figsize: Figure size

        Example:
            >>> viz.create_dashboard(hours=24, save_path='/tmp/dashboard.png')
        """
        try:
            import matplotlib.pyplot as plt
            import seaborn as sns

            sns.set_style('darkgrid')

            df = self.client.metrics.to_dataframe(hours=hours)

            if df.empty:
                print("No data available for dashboard")
                return

            fig, axes = plt.subplots(2, 2, figsize=figsize)
            fig.suptitle('Commit-Relay Dashboard Analytics', fontsize=18, fontweight='bold')

            # Worker activity
            if 'active_workers' in df.columns:
                axes[0, 0].plot(df['timestamp'], df['active_workers'], marker='o', color='#2E86AB', linewidth=2)
                axes[0, 0].set_title('Active Workers', fontsize=14)
                axes[0, 0].set_ylabel('Count')
                axes[0, 0].grid(True, alpha=0.3)

            # Success rate
            if 'success_rate' in df.columns:
                axes[0, 1].plot(df['timestamp'], df['success_rate'], marker='o', color='#06A77D', linewidth=2)
                axes[0, 1].axhline(y=75, color='#D62246', linestyle='--', alpha=0.7)
                axes[0, 1].set_title('Success Rate', fontsize=14)
                axes[0, 1].set_ylabel('Percentage (%)')
                axes[0, 1].set_ylim(0, 105)
                axes[0, 1].grid(True, alpha=0.3)

            # Tasks completed
            if 'tasks_completed' in df.columns:
                axes[1, 0].bar(df['timestamp'], df['tasks_completed'], color='#F77F00', alpha=0.7, width=0.02)
                axes[1, 0].set_title('Tasks Completed', fontsize=14)
                axes[1, 0].set_ylabel('Count')
                axes[1, 0].grid(True, alpha=0.3, axis='y')

            # Tasks in progress
            if 'tasks_in_progress' in df.columns:
                axes[1, 1].plot(df['timestamp'], df['tasks_in_progress'], marker='o', color='#9D4EDD', linewidth=2)
                axes[1, 1].set_title('Tasks In Progress', fontsize=14)
                axes[1, 1].set_ylabel('Count')
                axes[1, 1].grid(True, alpha=0.3)

            for ax in axes.flat:
                ax.tick_params(axis='x', rotation=45)

            plt.tight_layout()

            if save_path:
                plt.savefig(save_path, dpi=300, bbox_inches='tight')
                print(f"Dashboard saved to {save_path}")
            else:
                plt.show()

            plt.close()

        except ImportError:
            warnings.warn("matplotlib and seaborn required")

    def plot_worker_type_distribution(
        self,
        save_path: Optional[str] = None,
        figsize: tuple = (10, 6)
    ):
        """
        Plot distribution of workers by type.

        Args:
            save_path: Path to save figure
            figsize: Figure size
        """
        try:
            import matplotlib.pyplot as plt
            import seaborn as sns

            stats = self.client.workers.get_stats()
            by_type = stats.get('by_type', {})

            if not by_type:
                print("No worker type data available")
                return

            fig, ax = plt.subplots(figsize=figsize)
            types = list(by_type.keys())
            counts = list(by_type.values())

            ax.bar(types, counts, color='#577590', alpha=0.8)
            ax.set_xlabel('Worker Type', fontsize=12)
            ax.set_ylabel('Count', fontsize=12)
            ax.set_title('Worker Distribution by Type', fontsize=14, fontweight='bold')
            ax.grid(True, alpha=0.3, axis='y')
            plt.xticks(rotation=45, ha='right')
            plt.tight_layout()

            if save_path:
                plt.savefig(save_path, dpi=300, bbox_inches='tight')
                print(f"Saved to {save_path}")
            else:
                plt.show()

            plt.close()

        except ImportError:
            warnings.warn("matplotlib and seaborn required")

    def plot_trend_with_moving_average(
        self,
        metric: str,
        hours: int = 24,
        window: int = 5,
        save_path: Optional[str] = None,
        figsize: tuple = (12, 6)
    ):
        """
        Plot metric with moving average overlay.

        Args:
            metric: Metric name to plot
            hours: Hours of history
            window: Moving average window
            save_path: Path to save figure
            figsize: Figure size
        """
        try:
            import matplotlib.pyplot as plt
            import seaborn as sns
            from commit_relay.analytics import TrendAnalyzer

            df = self.client.metrics.to_dataframe(hours=hours)

            if df.empty or metric not in df.columns:
                print(f"Metric '{metric}' not available")
                return

            ma = TrendAnalyzer.moving_average(df[metric], window=window)

            fig, ax = plt.subplots(figsize=figsize)
            ax.plot(df['timestamp'], df[metric], marker='o', alpha=0.5, label='Actual', linewidth=1)
            ax.plot(df['timestamp'], ma, linewidth=3, label=f'MA ({window})', color='red')
            ax.set_xlabel('Time', fontsize=12)
            ax.set_ylabel(metric.replace('_', ' ').title(), fontsize=12)
            ax.set_title(f'{metric.replace("_", " ").title()} with Moving Average', fontsize=14, fontweight='bold')
            ax.legend()
            ax.grid(True, alpha=0.3)
            plt.xticks(rotation=45)
            plt.tight_layout()

            if save_path:
                plt.savefig(save_path, dpi=300, bbox_inches='tight')
                print(f"Saved to {save_path}")
            else:
                plt.show()

            plt.close()

        except ImportError:
            warnings.warn("matplotlib, seaborn, and analytics module required")
