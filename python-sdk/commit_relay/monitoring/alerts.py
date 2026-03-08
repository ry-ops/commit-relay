"""
Alert management for commit-relay monitoring.

Provides alerting based on health checks and anomaly detection.
"""

from typing import List, Dict, Any, Optional, Callable
from enum import Enum
from datetime import datetime


class AlertLevel(Enum):
    """Alert severity levels."""
    INFO = 'info'
    WARNING = 'warning'
    CRITICAL = 'critical'


class Alert:
    """Represents a single alert."""

    def __init__(
        self,
        level: AlertLevel,
        message: str,
        source: str,
        metadata: Optional[Dict[str, Any]] = None
    ):
        self.level = level
        self.message = message
        self.source = source
        self.metadata = metadata or {}
        self.timestamp = datetime.utcnow()

    def to_dict(self) -> Dict[str, Any]:
        """Convert alert to dictionary."""
        return {
            'level': self.level.value,
            'message': self.message,
            'source': self.source,
            'metadata': self.metadata,
            'timestamp': self.timestamp.isoformat() + 'Z',
        }


class AlertManager:
    """
    Manage alerts based on monitoring results.

    Example:
        >>> from commit_relay.monitoring import AlertManager, HealthChecker
        >>> manager = AlertManager()
        >>> checker = HealthChecker(client)
        >>> health = checker.get_overall_health()
        >>> alerts = manager.generate_alerts_from_health(health)
    """

    def __init__(self):
        """Initialize AlertManager."""
        self.alerts: List[Alert] = []
        self.handlers: List[Callable] = []

    def add_handler(self, handler: Callable[[Alert], None]):
        """
        Add alert handler function.

        Args:
            handler: Function that takes Alert as argument
        """
        self.handlers.append(handler)

    def trigger_alert(
        self,
        level: AlertLevel,
        message: str,
        source: str,
        metadata: Optional[Dict[str, Any]] = None
    ):
        """
        Trigger a new alert.

        Args:
            level: Alert severity level
            message: Alert message
            source: Source of the alert
            metadata: Additional metadata
        """
        alert = Alert(level, message, source, metadata)
        self.alerts.append(alert)

        # Call handlers
        for handler in self.handlers:
            try:
                handler(alert)
            except Exception as e:
                print(f"Alert handler error: {e}")

    def generate_alerts_from_health(
        self,
        health_result: Dict[str, Any]
    ) -> List[Alert]:
        """
        Generate alerts from health check results.

        Args:
            health_result: Result from HealthChecker.get_overall_health()

        Returns:
            List of generated alerts
        """
        alerts = []

        for check in health_result.get('checks', []):
            status = check.get('status')

            if status == 'critical':
                alert = Alert(
                    level=AlertLevel.CRITICAL,
                    message=check['message'],
                    source=f"health_check:{check['check']}",
                    metadata=check
                )
                alerts.append(alert)
                self.alerts.append(alert)

            elif status == 'warning':
                alert = Alert(
                    level=AlertLevel.WARNING,
                    message=check['message'],
                    source=f"health_check:{check['check']}",
                    metadata=check
                )
                alerts.append(alert)
                self.alerts.append(alert)

        # Trigger handlers
        for alert in alerts:
            for handler in self.handlers:
                try:
                    handler(alert)
                except Exception:
                    pass

        return alerts

    def generate_alerts_from_anomalies(
        self,
        anomaly_results: Dict[str, Dict[str, Any]],
        threshold_percentage: float = 5.0
    ) -> List[Alert]:
        """
        Generate alerts from anomaly detection results.

        Args:
            anomaly_results: Results from AnomalyDetector
            threshold_percentage: Alert if anomaly percentage exceeds this

        Returns:
            List of generated alerts
        """
        alerts = []

        for metric, data in anomaly_results.items():
            if 'error' in data:
                continue

            pct = data.get('anomaly_percentage', 0)

            if pct >= threshold_percentage:
                level = AlertLevel.CRITICAL if pct >= 10.0 else AlertLevel.WARNING
                alert = Alert(
                    level=level,
                    message=f"Anomalies detected in {metric}: {pct:.1f}%",
                    source=f"anomaly_detection:{metric}",
                    metadata=data
                )
                alerts.append(alert)
                self.alerts.append(alert)

        return alerts

    def get_alerts(
        self,
        level: Optional[AlertLevel] = None,
        source: Optional[str] = None,
        limit: Optional[int] = None
    ) -> List[Alert]:
        """
        Get alerts with optional filtering.

        Args:
            level: Filter by alert level
            source: Filter by source
            limit: Maximum number of alerts to return

        Returns:
            List of alerts
        """
        filtered = self.alerts

        if level:
            filtered = [a for a in filtered if a.level == level]

        if source:
            filtered = [a for a in filtered if a.source.startswith(source)]

        if limit:
            filtered = filtered[-limit:]

        return filtered

    def clear_alerts(self):
        """Clear all stored alerts."""
        self.alerts = []

    def print_alerts(self, level: Optional[AlertLevel] = None):
        """
        Print alerts to console.

        Args:
            level: Optional filter by level
        """
        alerts = self.get_alerts(level=level)

        if not alerts:
            print("No alerts")
            return

        print(f"\n{'='*60}")
        print(f"ALERTS ({len(alerts)} total)")
        print(f"{'='*60}\n")

        for alert in alerts:
            symbol = {
                AlertLevel.INFO: 'ℹ',
                AlertLevel.WARNING: '⚠',
                AlertLevel.CRITICAL: '⚠',
            }.get(alert.level, '?')

            print(f"[{symbol}] {alert.level.value.upper():10s} | {alert.message}")
            print(f"    Source: {alert.source}")
            print(f"    Time: {alert.timestamp.isoformat()}")
            print()


# Example alert handlers

def console_alert_handler(alert: Alert):
    """Simple console alert handler."""
    print(f"[ALERT] {alert.level.value.upper()}: {alert.message}")


def file_alert_handler(filepath: str):
    """Create file alert handler."""
    def handler(alert: Alert):
        with open(filepath, 'a') as f:
            import json
            f.write(json.dumps(alert.to_dict()) + '\n')
    return handler
