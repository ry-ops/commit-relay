"""
Forecasting module for commit-relay metrics.

Provides simple forecasting capabilities for predicting future metric values.
"""

from typing import Dict, Any, Optional, List
import warnings


class MetricsForecaster:
    """
    Forecast future metric values.

    Provides simple forecasting methods including linear extrapolation
    and moving average based predictions.

    Example:
        >>> from commit_relay.analytics import MetricsForecaster
        >>> forecaster = MetricsForecaster()
        >>> df = client.metrics.to_dataframe(hours=24)
        >>> forecast = forecaster.forecast_linear(df['active_workers'], periods=6)
    """

    @staticmethod
    def forecast_linear(series, periods: int = 5) -> Dict[str, Any]:
        """
        Forecast using linear regression.

        Args:
            series: pandas.Series or list of historical values
            periods: Number of periods to forecast ahead

        Returns:
            Dictionary containing forecasted values and trend information

        Example:
            >>> forecast = MetricsForecaster.forecast_linear(df['active_workers'], periods=6)
            >>> print(f"Next value: {forecast['forecast'][0]:.1f}")
        """
        try:
            import numpy as np
            from scipy import stats

            if hasattr(series, 'values'):
                y = series.values
            else:
                y = np.array(list(series))

            # Remove NaN
            y = y[~np.isnan(y)]

            if len(y) < 3:
                return {
                    'forecast': [y[-1]] * periods if len(y) > 0 else [0] * periods,
                    'error': 'Insufficient data for linear forecast'
                }

            x = np.arange(len(y))
            slope, intercept, r_value, p_value, std_err = stats.linregress(x, y)

            # Generate forecast
            future_x = np.arange(len(y), len(y) + periods)
            forecast = slope * future_x + intercept

            return {
                'forecast': forecast.tolist(),
                'slope': float(slope),
                'intercept': float(intercept),
                'r_squared': float(r_value ** 2),
                'confidence': float(1 - p_value),
            }

        except ImportError:
            return {
                'forecast': [],
                'error': 'scipy required. Install with: pip install scipy'
            }

    @staticmethod
    def forecast_moving_average(series, periods: int = 5, window: int = 5):
        """
        Forecast using moving average.

        Args:
            series: pandas.Series or list of historical values
            periods: Number of periods to forecast
            window: Window size for moving average

        Returns:
            List of forecasted values
        """
        try:
            import pandas as pd

            if not isinstance(series, pd.Series):
                series = pd.Series(series)

            # Calculate moving average of last window
            ma = series.tail(window).mean()

            # Simple forecast: extend with MA value
            return [ma] * periods

        except ImportError:
            # Fallback
            if hasattr(series, 'tolist'):
                values = series.tolist()
            else:
                values = list(series)

            if len(values) < window:
                window = len(values)

            if window == 0:
                return [0] * periods

            ma = sum(values[-window:]) / window
            return [ma] * periods

    @staticmethod
    def forecast_simple_exponential_smoothing(
        series,
        periods: int = 5,
        alpha: float = 0.3
    ):
        """
        Forecast using simple exponential smoothing.

        Args:
            series: pandas.Series or list of historical values
            periods: Number of periods to forecast
            alpha: Smoothing parameter (0 < alpha < 1)

        Returns:
            List of forecasted values
        """
        if hasattr(series, 'tolist'):
            values = [v for v in series.tolist() if v is not None]
        else:
            values = [v for v in series if v is not None]

        if not values:
            return [0] * periods

        # Calculate smoothed value
        smoothed = values[0]
        for value in values[1:]:
            smoothed = alpha * value + (1 - alpha) * smoothed

        # Forecast is constant at smoothed value
        return [smoothed] * periods

    @staticmethod
    def predict_capacity_breach(
        series,
        capacity_limit: float,
        periods_ahead: int = 12
    ) -> Optional[int]:
        """
        Predict when a metric will breach a capacity limit.

        Args:
            series: Historical values
            capacity_limit: Capacity threshold
            periods_ahead: How far to look ahead

        Returns:
            Number of periods until breach, or None if no breach predicted

        Example:
            >>> periods = MetricsForecaster.predict_capacity_breach(
            ...     df['active_workers'],
            ...     capacity_limit=10,
            ...     periods_ahead=24
            ... )
            >>> if periods:
            ...     print(f"Capacity breach in {periods} hours")
        """
        forecast_result = MetricsForecaster.forecast_linear(series, periods=periods_ahead)

        if 'error' in forecast_result:
            return None

        forecast = forecast_result['forecast']

        for i, value in enumerate(forecast):
            if value >= capacity_limit:
                return i + 1  # Return 1-indexed period

        return None

    @staticmethod
    def calculate_confidence_interval(
        series,
        confidence: float = 0.95
    ) -> Dict[str, float]:
        """
        Calculate confidence interval for forecasts.

        Args:
            series: Historical values
            confidence: Confidence level (default: 0.95)

        Returns:
            Dictionary with upper and lower bounds
        """
        try:
            import numpy as np
            from scipy import stats

            if hasattr(series, 'values'):
                values = series.values
            else:
                values = np.array(list(series))

            values = values[~np.isnan(values)]

            if len(values) == 0:
                return {'lower': 0, 'upper': 0}

            mean = np.mean(values)
            std_err = stats.sem(values)
            interval = std_err * stats.t.ppf((1 + confidence) / 2, len(values) - 1)

            return {
                'mean': float(mean),
                'lower': float(mean - interval),
                'upper': float(mean + interval),
                'confidence': confidence,
            }

        except ImportError:
            warnings.warn("scipy required for confidence intervals")
            return {'lower': 0, 'upper': 0}
