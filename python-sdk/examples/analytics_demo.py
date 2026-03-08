#!/usr/bin/env python3
"""
Analytics demonstration for commit-relay SDK.

Showcases advanced analytics capabilities including:
- Metrics aggregation and statistics
- Trend detection and analysis
- Forecasting future values
- Time-series analysis
"""

from commit_relay import CommitRelayClient, MetricsAggregator, TrendAnalyzer, MetricsForecaster


def main():
    print("="*70)
    print("COMMIT-RELAY SDK - ANALYTICS DEMO")
    print("="*70)
    print()

    # Initialize client and aggregator
    client = CommitRelayClient(base_url='http://localhost:3000')
    aggregator = MetricsAggregator(client)

    # Get comprehensive summary
    print("1. COMPREHENSIVE METRICS SUMMARY (24h)")
    print("-"*70)
    summary = aggregator.get_comprehensive_summary(hours=24)

    print("Worker Statistics:")
    worker_stats = summary['worker_stats']
    print(f"  - Average Active: {worker_stats.get('avg_active_workers', 0):.2f}")
    print(f"  - Maximum Active: {worker_stats.get('max_active_workers', 0)}")
    print(f"  - Minimum Active: {worker_stats.get('min_active_workers', 0)}")
    if 'std_active_workers' in worker_stats:
        print(f"  - Std Deviation: {worker_stats['std_active_workers']:.2f}")

    print("\nTask Statistics:")
    task_stats = summary['task_stats']
    print(f"  - Total Completed: {task_stats.get('total_tasks_completed', 0)}")
    print(f"  - Total Failed: {task_stats.get('total_tasks_failed', 0)}")
    print(f"  - Avg Success Rate: {task_stats.get('avg_success_rate', 0):.1f}%")
    if 'avg_tasks_per_hour' in task_stats:
        print(f"  - Avg per Hour: {task_stats['avg_tasks_per_hour']:.1f}")

    # Analyze hourly throughput
    print("\n2. HOURLY TASK THROUGHPUT")
    print("-"*70)
    try:
        throughput = aggregator.get_hourly_throughput(hours=24)
        if hasattr(throughput, 'sum'):
            print(f"  Total throughput: {throughput.sum()} tasks")
            print(f"  Average per hour: {throughput.mean():.1f} tasks")
            if hasattr(throughput, 'head'):
                print(f"\n  Recent hours:")
                print(throughput.tail(5))
        else:
            print(f"  Hourly data points: {len(throughput)}")
    except Exception as e:
        print(f"  Could not calculate throughput: {e}")

    # Trend detection
    print("\n3. TREND ANALYSIS")
    print("-"*70)
    try:
        df = client.metrics.to_dataframe(hours=24)

        if not df.empty and 'success_rate' in df.columns:
            success_trend = TrendAnalyzer.detect_trend(df['success_rate'])
            print("Success Rate Trend:")
            print(f"  - Direction: {success_trend.get('direction', 'unknown').upper()}")
            print(f"  - Slope: {success_trend.get('slope', 0):.4f}")
            print(f"  - R-squared: {success_trend.get('r_squared', 0):.4f}")
            if success_trend.get('significant'):
                print(f"  - Confidence: {success_trend.get('confidence', 0):.1%}")
                print(f"  - ✓ Trend is statistically significant")
            else:
                print(f"  - Trend is not statistically significant")

        if not df.empty and 'active_workers' in df.columns:
            worker_trend = TrendAnalyzer.detect_trend(df['active_workers'])
            print("\nWorker Activity Trend:")
            print(f"  - Direction: {worker_trend.get('direction', 'unknown').upper()}")
            print(f"  - Slope: {worker_trend.get('slope', 0):.4f}")

    except ImportError:
        print("  pandas/scipy required for trend analysis")
    except Exception as e:
        print(f"  Error: {e}")

    # Volatility analysis
    print("\n4. VOLATILITY ANALYSIS")
    print("-"*70)
    try:
        df = client.metrics.to_dataframe(hours=24)

        if not df.empty and 'success_rate' in df.columns:
            volatility = TrendAnalyzer.detect_volatility(df['success_rate'])
            print("Success Rate Volatility:")
            print(f"  - Mean: {volatility.get('mean', 0):.2f}%")
            print(f"  - Std Dev: {volatility.get('std', 0):.2f}")
            print(f"  - Range: {volatility.get('range', 0):.2f}")
            cv = volatility.get('coefficient_of_variation', 0)
            print(f"  - CV: {cv:.2f}")
            if cv < 0.1:
                print(f"  - ✓ Low volatility (stable)")
            elif cv < 0.3:
                print(f"  - Moderate volatility")
            else:
                print(f"  - ⚠ High volatility")

    except Exception as e:
        print(f"  Error: {e}")

    # Forecasting
    print("\n5. FORECASTING (Next 6 periods)")
    print("-"*70)
    try:
        df = client.metrics.to_dataframe(hours=24)

        if not df.empty and 'active_workers' in df.columns:
            forecast = MetricsForecaster.forecast_linear(df['active_workers'], periods=6)
            if 'forecast' in forecast and not forecast.get('error'):
                print("Worker Activity Forecast:")
                print(f"  - Method: Linear regression")
                print(f"  - R-squared: {forecast.get('r_squared', 0):.4f}")
                print(f"  - Predicted values: {[f'{v:.1f}' for v in forecast['forecast']]}")

                # Check capacity breach
                capacity_limit = 10
                breach = MetricsForecaster.predict_capacity_breach(
                    df['active_workers'],
                    capacity_limit=capacity_limit,
                    periods_ahead=24
                )
                if breach:
                    print(f"\n  ⚠ Warning: Worker capacity ({capacity_limit}) may be breached in {breach} periods")
                else:
                    print(f"\n  ✓ No capacity breach predicted")

    except Exception as e:
        print(f"  Error: {e}")

    # Period comparison
    print("\n6. PERIOD COMPARISON")
    print("-"*70)
    try:
        comparison = aggregator.compare_periods(current_hours=24, previous_hours=24)
        if 'changes' in comparison:
            changes = comparison['changes']
            if 'worker_change_pct' in changes:
                worker_change = changes['worker_change_pct']
                symbol = '↑' if worker_change > 0 else '↓' if worker_change < 0 else '→'
                print(f"  Worker Activity: {symbol} {worker_change:+.1f}%")

            if 'success_rate_change_pct' in changes:
                success_change = changes['success_rate_change_pct']
                symbol = '↑' if success_change > 0 else '↓' if success_change < 0 else '→'
                print(f"  Success Rate: {symbol} {success_change:+.1f}%")

    except Exception as e:
        print(f"  Error: {e}")

    print("\n" + "="*70)
    print("ANALYTICS DEMO COMPLETED")
    print("="*70)


if __name__ == '__main__':
    try:
        main()
    except Exception as e:
        print(f"\nError: {e}")
        import traceback
        traceback.print_exc()
