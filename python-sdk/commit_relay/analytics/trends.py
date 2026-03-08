"""
Trend analysis for commit-relay metrics.

Provides statistical methods for detecting and analyzing trends in
time-series metrics data.
"""

from typing import Dict, Any, Optional, Tuple
import warnings


class TrendAnalyzer:
    """
    Detect trends and patterns in metrics.

    Provides statistical methods for trend detection, moving averages,
    and pattern recognition in time-series data.

    Example:
        >>> from commit_relay.analytics import TrendAnalyzer
        >>> analyzer = TrendAnalyzer()
        >>> df = client.metrics.to_dataframe(hours=24)
        >>> trend = analyzer.detect_trend(df['success_rate'])
        >>> print(f"Trend: {trend['direction']}")
    """

    @staticmethod
    def detect_trend(series, confidence_threshold: float = 0.05) -> Dict[str, Any]:
        """
        Detect if metric is trending up, down, or stable.

        Uses linear regression to determine trend direction and strength.

        Args:
            series: pandas.Series or list of values
            confidence_threshold: P-value threshold for significance (default: 0.05)

        Returns:
            Dictionary containing:
            - direction: 'increasing', 'decreasing', or 'stable'
            - slope: Rate of change
            - r_squared: Coefficient of determination
            - confidence: Statistical confidence (1 - p_value)
            - significant: Whether trend is statistically significant

        Example:
            >>> trend = TrendAnalyzer.detect_trend(df['success_rate'])
            >>> if trend['significant']:
            ...     print(f"Success rate is {trend['direction']}")
        """
        try:
            import numpy as np
            from scipy import stats

            # Convert to numpy array
            if hasattr(series, 'values'):
                y = series.values
            else:
                y = np.array(list(series))

            # Remove NaN values
            y = y[~np.isnan(y)]

            if len(y) < 3:
                return {
                    'direction': 'unknown',
                    'slope': 0,
                    'r_squared': 0,
                    'confidence': 0,
                    'significant': False,
                    'error': 'Insufficient data points'
                }

            x = np.arange(len(y))
            slope, intercept, r_value, p_value, std_err = stats.linregress(x, y)

            # Determine direction
            is_significant = p_value < confidence_threshold

            if not is_significant:
                direction = 'stable'
            elif slope > 0:
                direction = 'increasing'
            else:
                direction = 'decreasing'

            return {
                'direction': direction,
                'slope': float(slope),
                'intercept': float(intercept),
                'r_squared': float(r_value ** 2),
                'p_value': float(p_value),
                'confidence': float(1 - p_value),
                'std_err': float(std_err),
                'significant': is_significant,
            }

        except ImportError:
            return {
                'direction': 'unknown',
                'error': 'scipy required for trend detection. Install with: pip install scipy'
            }

    @staticmethod
    def moving_average(series, window: int = 5, center: bool = False):
        """
        Calculate moving average.

        Args:
            series: pandas.Series or list of values
            window: Window size for moving average
            center: Whether to center the window

        Returns:
            pandas.Series with moving average values

        Example:
            >>> ma = TrendAnalyzer.moving_average(df['active_workers'], window=5)
            >>> df['ma_workers'] = ma
        """
        try:
            import pandas as pd

            if not isinstance(series, pd.Series):
                series = pd.Series(series)

            return series.rolling(window=window, center=center).mean()

        except ImportError:
            # Fallback implementation
            return TrendAnalyzer._moving_average_fallback(series, window)

    @staticmethod
    def _moving_average_fallback(series, window: int):
        """Fallback moving average without pandas."""
        if hasattr(series, 'tolist'):
            values = series.tolist()
        else:
            values = list(series)

        result = []
        for i in range(len(values)):
            if i < window - 1:
                result.append(None)
            else:
                window_values = values[i - window + 1:i + 1]
                result.append(sum(window_values) / len(window_values))

        return result

    @staticmethod
    def exponential_moving_average(series, span: int = 5):
        """
        Calculate exponential moving average (EMA).

        Args:
            series: pandas.Series or list of values
            span: Span for EMA calculation

        Returns:
            pandas.Series with EMA values

        Example:
            >>> ema = TrendAnalyzer.exponential_moving_average(df['success_rate'], span=5)
        """
        try:
            import pandas as pd

            if not isinstance(series, pd.Series):
                series = pd.Series(series)

            return series.ewm(span=span, adjust=False).mean()

        except ImportError:
            warnings.warn("pandas required for EMA. Falling back to simple moving average.")
            return TrendAnalyzer.moving_average(series, window=span)

    @staticmethod
    def detect_seasonality(series, period: int = 24) -> Dict[str, Any]:
        """
        Detect seasonal patterns in time series.

        Args:
            series: pandas.Series with datetime index
            period: Expected seasonal period (e.g., 24 for daily pattern in hourly data)

        Returns:
            Dictionary with seasonality information

        Example:
            >>> seasonality = TrendAnalyzer.detect_seasonality(df['active_workers'], period=24)
        """
        try:
            import numpy as np
            from scipy import stats

            if hasattr(series, 'values'):
                values = series.values
            else:
                values = np.array(list(series))

            if len(values) < period * 2:
                return {
                    'has_seasonality': False,
                    'error': f'Insufficient data. Need at least {period * 2} points.'
                }

            # Simple autocorrelation check at seasonal lag
            n = len(values)
            lag_values = values[:-period]
            current_values = values[period:]

            correlation, p_value = stats.pearsonr(lag_values, current_values)

            return {
                'has_seasonality': p_value < 0.05 and correlation > 0.5,
                'correlation': float(correlation),
                'p_value': float(p_value),
                'period': period,
            }

        except ImportError:
            return {
                'has_seasonality': False,
                'error': 'scipy required. Install with: pip install scipy'
            }

    @staticmethod
    def detect_volatility(series) -> Dict[str, Any]:
        """
        Measure volatility in time series.

        Args:
            series: pandas.Series or list of values

        Returns:
            Dictionary with volatility metrics

        Example:
            >>> volatility = TrendAnalyzer.detect_volatility(df['success_rate'])
            >>> print(f"Coefficient of variation: {volatility['cv']:.2f}")
        """
        try:
            import numpy as np

            if hasattr(series, 'values'):
                values = series.values
            else:
                values = np.array(list(series))

            values = values[~np.isnan(values)]

            if len(values) == 0:
                return {'error': 'No valid data points'}

            mean = np.mean(values)
            std = np.std(values)
            cv = (std / mean) if mean != 0 else float('inf')

            return {
                'mean': float(mean),
                'std': float(std),
                'variance': float(np.var(values)),
                'coefficient_of_variation': float(cv),
                'min': float(np.min(values)),
                'max': float(np.max(values)),
                'range': float(np.max(values) - np.min(values)),
            }

        except ImportError:
            # Fallback implementation
            return TrendAnalyzer._detect_volatility_fallback(series)

    @staticmethod
    def _detect_volatility_fallback(series):
        """Fallback volatility calculation without numpy."""
        if hasattr(series, 'tolist'):
            values = [v for v in series.tolist() if v is not None]
        else:
            values = [v for v in series if v is not None]

        if not values:
            return {'error': 'No valid data points'}

        mean = sum(values) / len(values)
        variance = sum((x - mean) ** 2 for x in values) / len(values)
        std = variance ** 0.5
        cv = (std / mean) if mean != 0 else float('inf')

        return {
            'mean': mean,
            'std': std,
            'variance': variance,
            'coefficient_of_variation': cv,
            'min': min(values),
            'max': max(values),
            'range': max(values) - min(values),
        }

    @staticmethod
    def find_outliers(series, method: str = 'iqr', threshold: float = 1.5):
        """
        Find outliers in time series.

        Args:
            series: pandas.Series or list of values
            method: 'iqr' or 'zscore'
            threshold: Threshold for outlier detection

        Returns:
            pandas.Series or list of boolean values indicating outliers

        Example:
            >>> outliers = TrendAnalyzer.find_outliers(df['active_workers'])
            >>> df[outliers]  # View outlier points
        """
        try:
            import numpy as np
            import pandas as pd

            if not isinstance(series, pd.Series):
                series = pd.Series(series)

            if method == 'iqr':
                Q1 = series.quantile(0.25)
                Q3 = series.quantile(0.75)
                IQR = Q3 - Q1
                lower_bound = Q1 - threshold * IQR
                upper_bound = Q3 + threshold * IQR
                return (series < lower_bound) | (series > upper_bound)

            elif method == 'zscore':
                mean = series.mean()
                std = series.std()
                z_scores = np.abs((series - mean) / std)
                return z_scores > threshold

            else:
                raise ValueError(f"Unknown method: {method}")

        except ImportError:
            return TrendAnalyzer._find_outliers_fallback(series, method, threshold)

    @staticmethod
    def _find_outliers_fallback(series, method: str, threshold: float):
        """Fallback outlier detection without pandas."""
        if hasattr(series, 'tolist'):
            values = series.tolist()
        else:
            values = list(series)

        if method == 'iqr':
            sorted_vals = sorted(v for v in values if v is not None)
            n = len(sorted_vals)
            Q1 = sorted_vals[n // 4]
            Q3 = sorted_vals[3 * n // 4]
            IQR = Q3 - Q1
            lower = Q1 - threshold * IQR
            upper = Q3 + threshold * IQR
            return [v is not None and (v < lower or v > upper) for v in values]

        return [False] * len(values)
