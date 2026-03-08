"""
Resource clients for commit-relay API endpoints.

This package contains specialized clients for different API resource types,
providing a clean and organized interface to the dashboard API.
"""

from .workers import Workers
from .tasks import Tasks
from .metrics import Metrics
from .health import Health
from .events import Events
from .daemons import Daemons
from .git_ops import GitOps

__all__ = [
    'Workers',
    'Tasks',
    'Metrics',
    'Health',
    'Events',
    'Daemons',
    'GitOps',
]
