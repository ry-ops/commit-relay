#!/usr/bin/env python3
"""
Daily report generation for commit-relay.

Generates comprehensive daily reports including:
- System metrics summary
- Health status
- Visualizations
- Data exports
"""

import os
from datetime import datetime
from commit_relay import (
    CommitRelayClient,
    ReportGenerator,
    DashboardVisualizer,
    DataExporter
)


def main():
    print("="*70)
    print("COMMIT-RELAY SDK - DAILY REPORT GENERATION")
    print("="*70)
    print()

    # Initialize client
    client = CommitRelayClient(base_url='http://localhost:3000')

    # Create output directory
    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
    output_dir = f'/tmp/commit_relay_report_{timestamp}'
    os.makedirs(output_dir, exist_ok=True)
    print(f"Output directory: {output_dir}\n")

    # Initialize report generator
    generator = ReportGenerator(client)

    # 1. Generate text summary
    print("1. Generating daily summary report...")
    summary = generator.generate_daily_summary(hours=24)
    print(summary)

    summary_path = os.path.join(output_dir, 'daily_summary.txt')
    generator.export_to_text(summary_path, hours=24)
    print(f"✓ Saved to: {summary_path}\n")

    # 2. Generate markdown report
    print("2. Generating markdown report...")
    markdown_path = os.path.join(output_dir, 'report.md')
    generator.export_to_markdown(markdown_path, hours=24)
    print(f"✓ Saved to: {markdown_path}\n")

    # 3. Generate worker report
    print("3. Generating worker report...")
    worker_report = generator.generate_worker_report()
    print(worker_report)

    worker_path = os.path.join(output_dir, 'worker_report.txt')
    with open(worker_path, 'w') as f:
        f.write(worker_report)
    print(f"✓ Saved to: {worker_path}\n")

    # 4. Generate executive summary
    print("4. Generating executive summary...")
    exec_summary = generator.generate_executive_summary(hours=24)
    print(exec_summary)

    exec_path = os.path.join(output_dir, 'executive_summary.txt')
    with open(exec_path, 'w') as f:
        f.write(exec_summary)
    print(f"✓ Saved to: {exec_path}\n")

    # 5. Generate visualizations
    print("5. Generating visualizations...")
    visualizer = DashboardVisualizer(client)

    try:
        # Dashboard
        dashboard_path = os.path.join(output_dir, 'dashboard.png')
        visualizer.create_dashboard(hours=24, save_path=dashboard_path)

        # Worker activity
        workers_path = os.path.join(output_dir, 'worker_activity.png')
        visualizer.plot_worker_activity(hours=24, save_path=workers_path)

        # Success rate
        success_path = os.path.join(output_dir, 'success_rate.png')
        visualizer.plot_success_rate(hours=24, save_path=success_path)

        # Task throughput
        throughput_path = os.path.join(output_dir, 'task_throughput.png')
        visualizer.plot_task_throughput(hours=24, save_path=throughput_path)

        # Worker distribution
        distribution_path = os.path.join(output_dir, 'worker_distribution.png')
        visualizer.plot_worker_type_distribution(save_path=distribution_path)

        print("✓ All visualizations generated\n")

    except ImportError:
        print("⚠ matplotlib/seaborn not available - skipping visualizations\n")
    except Exception as e:
        print(f"⚠ Error generating visualizations: {e}\n")

    # 6. Export data
    print("6. Exporting data...")
    exporter = DataExporter(client)

    # Export to CSV files
    metrics_csv = os.path.join(output_dir, 'metrics.csv')
    exporter.export_metrics_to_csv(metrics_csv, hours=24)

    workers_csv = os.path.join(output_dir, 'workers.csv')
    exporter.export_workers_to_csv(workers_csv)

    tasks_csv = os.path.join(output_dir, 'tasks.csv')
    exporter.export_tasks_to_csv(tasks_csv)

    # Export to JSON
    json_path = os.path.join(output_dir, 'full_export.json')
    exporter.export_to_json(json_path, metrics_hours=24)

    # Export to Excel (if available)
    try:
        excel_path = os.path.join(output_dir, 'commit_relay_data.xlsx')
        exporter.export_to_excel(excel_path, hours=24)
    except ImportError:
        print("⚠ pandas/openpyxl not available - skipping Excel export")
    except Exception as e:
        print(f"⚠ Excel export error: {e}")

    print("✓ Data exports completed\n")

    # 7. Generate index file
    print("7. Generating index file...")
    index_path = os.path.join(output_dir, 'INDEX.md')
    with open(index_path, 'w') as f:
        f.write(f"""# Commit-Relay Daily Report

**Generated:** {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}

## Reports

- [Daily Summary](daily_summary.txt) - Comprehensive text summary
- [Markdown Report](report.md) - Formatted markdown report
- [Worker Report](worker_report.txt) - Worker pool analysis
- [Executive Summary](executive_summary.txt) - High-level overview

## Visualizations

- [Dashboard](dashboard.png) - Comprehensive 4-panel dashboard
- [Worker Activity](worker_activity.png) - Worker activity over time
- [Success Rate](success_rate.png) - Task success rate trends
- [Task Throughput](task_throughput.png) - Tasks completed over time
- [Worker Distribution](worker_distribution.png) - Workers by type

## Data Exports

- [Metrics CSV](metrics.csv) - Time-series metrics data
- [Workers CSV](workers.csv) - Worker pool data
- [Tasks CSV](tasks.csv) - Task execution data
- [Full Export JSON](full_export.json) - Complete data dump
- [Excel Workbook](commit_relay_data.xlsx) - Multi-sheet Excel file

## Usage

View reports in any text editor or markdown viewer. Open PNG files to view visualizations.
Import CSV/Excel files into spreadsheet software for further analysis.
""")

    print(f"✓ Saved to: {index_path}\n")

    # Summary
    print("="*70)
    print("DAILY REPORT GENERATION COMPLETED")
    print("="*70)
    print(f"\nAll files saved to: {output_dir}")
    print("\nGenerated files:")
    for filename in sorted(os.listdir(output_dir)):
        filepath = os.path.join(output_dir, filename)
        size = os.path.getsize(filepath)
        print(f"  - {filename:30s} ({size:,} bytes)")

    print(f"\nTo view the report:")
    print(f"  cat {index_path}")
    print(f"  open {output_dir}")


if __name__ == '__main__':
    try:
        main()
    except Exception as e:
        print(f"\nError: {e}")
        import traceback
        traceback.print_exc()
