"""
Commit-Relay Python SDK

A comprehensive SDK for interacting with the commit-relay automation system,
providing API access, analytics, monitoring, and reporting capabilities.

Quick Start:
    >>> from commit_relay import CommitRelayClient
    >>> client = CommitRelayClient(base_url='http://localhost:3000')
    >>> metrics = client.metrics.get_current()
    >>> print(f"Active workers: {metrics['active_workers']}")

For more examples, see the examples/ directory.
"""

__version__ = '0.1.0'
__author__ = 'Commit-Relay Team'

from .client import CommitRelayClient
from .exceptions import (
    CommitRelayError,
    APIError,
    ConnectionError,
    ValidationError,
    ResourceNotFoundError,
    AuthenticationError,
    RateLimitError,
)

# Make commonly used classes easily accessible
from .analytics import MetricsAggregator, TrendAnalyzer, MetricsForecaster
from .monitoring import HealthChecker, HealthStatus, AnomalyDetector, AlertManager, AlertLevel
from .reporting import DashboardVisualizer, ReportGenerator, DataExporter

# Orchestration imports
from .orchestration import (
    TaskManager,
    TaskType,
    TaskPriority,
    TaskStatus,
    TaskBuilder,
    WorkflowOrchestrator,
    ExecutionMonitor,
    TaskHealthMonitor,
    EventStream,
    TaskLifecycleManager,
)

# ML imports
from .ml import (
    TaskFailurePredictor,
    MetricsAnomalyDetector,
    SmartTaskPrioritizer
)

# Integration imports
from .integrations import (
    GitHubDiscoveryService,
    GitHubActionsTrigger,
    GitHubActionsReporter
)

__all__ = [
    # Core
    'CommitRelayClient',
    '__version__',

    # Exceptions
    'CommitRelayError',
    'APIError',
    'ConnectionError',
    'ValidationError',
    'ResourceNotFoundError',
    'AuthenticationError',
    'RateLimitError',

    # Analytics
    'MetricsAggregator',
    'TrendAnalyzer',
    'MetricsForecaster',

    # Monitoring
    'HealthChecker',
    'HealthStatus',
    'AnomalyDetector',
    'AlertManager',
    'AlertLevel',

    # Reporting
    'DashboardVisualizer',
    'ReportGenerator',
    'DataExporter',

    # Orchestration
    'TaskManager',
    'TaskType',
    'TaskPriority',
    'TaskStatus',
    'TaskBuilder',
    'WorkflowOrchestrator',
    'ExecutionMonitor',
    'TaskHealthMonitor',
    'EventStream',
    'TaskLifecycleManager',

    # ML
    'TaskFailurePredictor',
    'MetricsAnomalyDetector',
    'SmartTaskPrioritizer',

    # Integrations
    'GitHubDiscoveryService',
    'GitHubActionsTrigger',
    'GitHubActionsReporter',
]
