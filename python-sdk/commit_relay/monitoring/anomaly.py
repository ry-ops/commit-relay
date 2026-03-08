"""
Anomaly detection for commit-relay metrics.

Detects anomalies using statistical methods including Z-score and IQR.
"""

from typing import Dict, Any, List, Tuple
import warnings


class AnomalyDetector:
    """
    Detect anomalies in metrics using statistical methods.

    Example:
        >>> from commit_relay.monitoring import AnomalyDetector
        >>> detector = AnomalyDetector()
        >>> anomalies = detector.detect_anomalies(client, 'success_rate', hours=24)
        >>> print(f"Found {anomalies['anomalies_count']} anomalies")
    """

    @staticmethod
    def zscore_detection(series, threshold: float = 3.0):
        """
        Detect anomalies using Z-score method.

        Args:
            series: pandas.Series or list of values
            threshold: Z-score threshold (default: 3.0)

        Returns:
            pandas.Series or list of boolean values indicating anomalies
        """
        try:
            import pandas as pd
            import numpy as np

            if not isinstance(series, pd.Series):
                series = pd.Series(series)

            mean = series.mean()
            std = series.std()

            if std == 0:
                return pd.Series([False] * len(series))

            z_scores = np.abs((series - mean) / std)
            return z_scores > threshold

        except ImportError:
            warnings.warn("pandas/numpy required for Z-score detection")
            return [False] * len(list(series))

    @staticmethod
    def iqr_detection(series, multiplier: float = 1.5):
        """
        Detect anomalies using IQR (Interquartile Range) method.

        Args:
            series: pandas.Series or list of values
            multiplier: IQR multiplier for bounds (default: 1.5)

        Returns:
            pandas.Series or list of boolean values indicating anomalies
        """
        try:
            import pandas as pd

            if not isinstance(series, pd.Series):
                series = pd.Series(series)

            Q1 = series.quantile(0.25)
            Q3 = series.quantile(0.75)
            IQR = Q3 - Q1

            lower_bound = Q1 - multiplier * IQR
            upper_bound = Q3 + multiplier * IQR

            return (series < lower_bound) | (series > upper_bound)

        except ImportError:
            warnings.warn("pandas required for IQR detection")
            return [False] * len(list(series))

    def detect_anomalies(
        self,
        client,
        metric_name: str,
        hours: int = 24,
        method: str = 'both',
        threshold: float = 3.0
    ) -> Dict[str, Any]:
        """
        Detect anomalies in a specific metric.

        Args:
            client: CommitRelayClient instance
            metric_name: Name of metric to analyze
            hours: Hours of history to analyze
            method: Detection method ('zscore', 'iqr', or 'both')
            threshold: Threshold for Z-score method

        Returns:
            Dictionary with anomaly detection results

        Example:
            >>> anomalies = detector.detect_anomalies(
            ...     client,
            ...     'success_rate',
            ...     hours=24,
            ...     method='both'
            ... )
        """
        try:
            import pandas as pd

            df = client.metrics.to_dataframe(hours=hours)

            if df.empty or metric_name not in df.columns:
                return {
                    'error': f"Metric '{metric_name}' not found or no data available",
                    'total_points': 0,
                    'anomalies_count': 0,
                }

            series = df[metric_name]

            if method == 'zscore':
                anomalies = self.zscore_detection(series, threshold=threshold)
            elif method == 'iqr':
                anomalies = self.iqr_detection(series)
            else:  # both
                zscore_anomalies = self.zscore_detection(series, threshold=threshold)
                iqr_anomalies = self.iqr_detection(series)
                # Anomaly if detected by both methods
                anomalies = zscore_anomalies & iqr_anomalies

            anomaly_count = anomalies.sum() if hasattr(anomalies, 'sum') else sum(anomalies)
            total_points = len(series)

            result = {
                'metric': metric_name,
                'method': method,
                'total_points': total_points,
                'anomalies_count': int(anomaly_count),
                'anomaly_percentage': (anomaly_count / total_points * 100) if total_points > 0 else 0,
            }

            if 'timestamp' in df.columns:
                result['anomaly_timestamps'] = df[anomalies]['timestamp'].tolist()

            # Get anomaly values
            result['anomaly_values'] = series[anomalies].tolist()

            # Statistics
            if anomaly_count > 0:
                result['anomaly_stats'] = {
                    'min': float(series[anomalies].min()),
                    'max': float(series[anomalies].max()),
                    'mean': float(series[anomalies].mean()),
                }

            return result

        except ImportError:
            return {
                'error': 'pandas required for anomaly detection',
                'total_points': 0,
                'anomalies_count': 0,
            }
        except Exception as e:
            return {
                'error': str(e),
                'total_points': 0,
                'anomalies_count': 0,
            }

    def detect_all_metrics_anomalies(
        self,
        client,
        hours: int = 24,
        metrics: List[str] = None
    ) -> Dict[str, Dict[str, Any]]:
        """
        Detect anomalies across multiple metrics.

        Args:
            client: CommitRelayClient instance
            hours: Hours of history
            metrics: List of metrics to check (None = all)

        Returns:
            Dictionary mapping metric names to anomaly results
        """
        if metrics is None:
            metrics = [
                'active_workers',
                'success_rate',
                'tasks_completed',
                'tasks_failed',
                'tasks_in_progress',
            ]

        results = {}
        for metric in metrics:
            results[metric] = self.detect_anomalies(
                client,
                metric,
                hours=hours,
                method='both'
            )

        return results

    def get_anomaly_report(
        self,
        client,
        hours: int = 24
    ) -> str:
        """
        Generate text report of anomalies.

        Args:
            client: CommitRelayClient instance
            hours: Hours to analyze

        Returns:
            Formatted text report
        """
        results = self.detect_all_metrics_anomalies(client, hours=hours)

        report = f"\n{'='*60}\n"
        report += f"ANOMALY DETECTION REPORT ({hours}h)\n"
        report += f"{'='*60}\n\n"

        total_anomalies = 0
        for metric, data in results.items():
            if 'error' in data:
                continue

            count = data['anomalies_count']
            total_anomalies += count
            pct = data['anomaly_percentage']

            status = '✓' if count == 0 else '!'
            report += f"[{status}] {metric:20s}: {count:3d} anomalies ({pct:5.1f}%)\n"

        report += f"\n{'='*60}\n"
        report += f"Total anomalies detected: {total_anomalies}\n"

        return report
