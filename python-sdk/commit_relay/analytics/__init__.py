"""
Analytics module for commit-relay SDK.

Provides data aggregation, trend analysis, and forecasting capabilities
for commit-relay metrics.
"""

from .aggregator import MetricsAggregator
from .trends import TrendAnalyzer
from .forecasting import MetricsForecaster

__all__ = [
    'MetricsAggregator',
    'TrendAnalyzer',
    'MetricsForecaster',
]
