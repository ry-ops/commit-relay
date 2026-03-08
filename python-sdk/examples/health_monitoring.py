#!/usr/bin/env python3
"""
Health monitoring demonstration for commit-relay SDK.

Showcases health checking and anomaly detection:
- Comprehensive system health checks
- Anomaly detection across metrics
- Alert generation and handling
"""

from commit_relay import CommitRelayClient, HealthChecker, AnomalyDetector, AlertManager, AlertLevel


def main():
    print("="*70)
    print("COMMIT-RELAY SDK - HEALTH MONITORING DEMO")
    print("="*70)
    print()

    # Initialize client and health checker
    client = CommitRelayClient(base_url='http://localhost:3000')
    checker = HealthChecker(client)

    # Run individual health checks
    print("1. INDIVIDUAL HEALTH CHECKS")
    print("-"*70)

    # Worker pool check
    worker_check = checker.check_worker_pool(min_workers=1, warning_threshold=3)
    print(f"Worker Pool: [{worker_check['status']}]")
    print(f"  - {worker_check['message']}")
    print(f"  - Active: {worker_check.get('active_workers', 0)}")

    # Success rate check
    success_check = checker.check_success_rate(warning_threshold=75.0, critical_threshold=50.0)
    print(f"\nSuccess Rate: [{success_check['status']}]")
    print(f"  - {success_check['message']}")
    print(f"  - Value: {success_check.get('value', 0):.1f}%")

    # Task backlog check
    backlog_check = checker.check_task_backlog(warning_threshold=10, critical_threshold=20)
    print(f"\nTask Backlog: [{backlog_check['status']}]")
    print(f"  - {backlog_check['message']}")
    print(f"  - Pending: {backlog_check.get('pending_tasks', 0)}")

    # API connectivity check
    api_check = checker.check_api_connectivity()
    print(f"\nAPI Connectivity: [{api_check['status']}]")
    print(f"  - {api_check['message']}")

    # Run all health checks
    print("\n2. COMPREHENSIVE HEALTH CHECK")
    print("-"*70)
    health = checker.get_overall_health()

    print(f"Overall Status: {health['overall_status'].upper()}")
    print(f"Total Checks: {health['total_checks']}")
    print(f"  - Healthy: {health['healthy_count']}")
    print(f"  - Warnings: {health['warning_count']}")
    print(f"  - Critical: {health['critical_count']}")
    print(f"  - Unknown: {health['unknown_count']}")

    print("\nDetailed Results:")
    status_symbols = {
        'healthy': '✓',
        'warning': '!',
        'critical': '✗',
        'unknown': '?',
    }
    for check in health['checks']:
        symbol = status_symbols.get(check['status'], '?')
        print(f"  [{symbol}] {check['check']:20s}: {check['message']}")

    # Anomaly detection
    print("\n3. ANOMALY DETECTION")
    print("-"*70)

    detector = AnomalyDetector()

    # Detect anomalies in success rate
    print("Success Rate Anomalies (24h):")
    try:
        anomalies = detector.detect_anomalies(
            client,
            'success_rate',
            hours=24,
            method='both'
        )

        if 'error' in anomalies:
            print(f"  Error: {anomalies['error']}")
        else:
            count = anomalies['anomalies_count']
            pct = anomalies['anomaly_percentage']
            total = anomalies['total_points']

            print(f"  - Total Points: {total}")
            print(f"  - Anomalies: {count} ({pct:.1f}%)")

            if count > 0:
                print(f"  - Anomaly Values: {anomalies.get('anomaly_values', [])[:5]}")
                if 'anomaly_stats' in anomalies:
                    stats = anomalies['anomaly_stats']
                    print(f"  - Range: {stats['min']:.1f} - {stats['max']:.1f}")

    except Exception as e:
        print(f"  Error: {e}")

    # Detect across all metrics
    print("\nAll Metrics Anomaly Scan:")
    try:
        all_anomalies = detector.detect_all_metrics_anomalies(client, hours=24)

        for metric, data in all_anomalies.items():
            if 'error' in data:
                continue

            count = data['anomalies_count']
            pct = data['anomaly_percentage']
            status = '✓' if count == 0 else '!' if pct < 10 else '✗'
            print(f"  [{status}] {metric:20s}: {count:3d} anomalies ({pct:5.1f}%)")

    except Exception as e:
        print(f"  Error: {e}")

    # Alert management
    print("\n4. ALERT MANAGEMENT")
    print("-"*70)

    # Create alert manager with console handler
    alert_manager = AlertManager()

    # Add custom handler
    def custom_handler(alert):
        if alert.level == AlertLevel.CRITICAL:
            print(f"  CRITICAL ALERT: {alert.message}")

    alert_manager.add_handler(custom_handler)

    # Generate alerts from health checks
    alerts = alert_manager.generate_alerts_from_health(health)
    print(f"Generated {len(alerts)} alerts from health checks")

    if alerts:
        for alert in alerts:
            level_symbol = {
                'info': 'ℹ',
                'warning': '⚠',
                'critical': '⚠',
            }.get(alert.level.value, '?')
            print(f"  [{level_symbol}] {alert.level.value.upper()}: {alert.message}")

    # Generate alerts from anomalies
    print("\nGenerating alerts from anomaly detection...")
    try:
        anomaly_alerts = alert_manager.generate_alerts_from_anomalies(
            all_anomalies,
            threshold_percentage=5.0
        )
        print(f"Generated {len(anomaly_alerts)} anomaly alerts")

        for alert in anomaly_alerts:
            print(f"  - {alert.message}")

    except Exception as e:
        print(f"  Error: {e}")

    # Get all alerts
    print(f"\nTotal alerts in system: {len(alert_manager.get_alerts())}")

    # Print formatted health report
    print("\n5. FORMATTED HEALTH REPORT")
    print("-"*70)
    checker.print_health_report()

    # Generate anomaly report
    print("\n6. ANOMALY DETECTION REPORT")
    print("-"*70)
    try:
        report = detector.get_anomaly_report(client, hours=24)
        print(report)
    except Exception as e:
        print(f"Error generating anomaly report: {e}")

    print("\n" + "="*70)
    print("HEALTH MONITORING DEMO COMPLETED")
    print("="*70)


if __name__ == '__main__':
    try:
        main()
    except Exception as e:
        print(f"\nError: {e}")
        import traceback
        traceback.print_exc()
