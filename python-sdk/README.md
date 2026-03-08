# Commit-Relay Python SDK

A comprehensive Python SDK for the commit-relay automation system, providing advanced analytics, health monitoring, and reporting capabilities.

## Features

- **Complete API Client**: Access all 22 dashboard API endpoints with a clean, pythonic interface
- **Task Orchestration**: Programmatic task creation and multi-task workflow management
- **Advanced Analytics**: Metrics aggregation, trend detection, and forecasting
- **Health Monitoring**: Comprehensive health checks and anomaly detection
- **Automated Reporting**: Generate text, markdown, and visual reports
- **Data Export**: Export to CSV, JSON, Excel, and pandas DataFrames
- **Type Hints**: Full type annotations for better IDE support
- **Error Handling**: Comprehensive exception hierarchy

## Installation

### From Source

```bash
cd python-sdk
pip install -e .
```

### With All Optional Dependencies

```bash
pip install -e ".[excel,jupyter,dev]"
```

### Minimal Installation

```bash
pip install -r requirements.txt
```

## Quick Start

```python
from commit_relay import CommitRelayClient

# Initialize client
client = CommitRelayClient(base_url='http://localhost:3000')

# Get current metrics
metrics = client.metrics.get_current()
print(f"Active Workers: {metrics['active_workers']}")
print(f"Success Rate: {metrics['success_rate']}%")

# List workers
workers = client.workers.list()
for worker in workers:
    print(f"{worker['worker_id']}: {worker['status']}")

# Export to DataFrame
df = client.metrics.to_dataframe(hours=24)
print(df.head())
```

## Usage Examples

### Task Creation and Orchestration

#### Creating Tasks Programmatically

```python
from commit_relay import TaskManager, TaskPriority

# Initialize task manager
manager = TaskManager()

# Create security scan task
task_id = manager.create_security_scan(
    repository='owner/repo',
    priority=TaskPriority.HIGH,
    scan_types=['dependencies', 'secrets'],
    description='Weekly security scan'
)
print(f"Created task: {task_id}")

# Create development task
task_id = manager.create_development_task(
    repository='owner/repo',
    requirements=['Add feature X', 'Fix bug Y'],
    priority=TaskPriority.MEDIUM,
    description='Feature implementation'
)
```

#### Fluent API with TaskBuilder

```python
from commit_relay import TaskBuilder, TaskPriority

# Use fluent API for expressive task creation
task_id = (TaskBuilder(manager)
           .security_scan()
           .repository('owner/repo')
           .priority(TaskPriority.CRITICAL)
           .scan_types(['dependencies', 'secrets'])
           .description('Critical security audit')
           .create())
```

#### Workflow Orchestration

```python
from commit_relay import WorkflowOrchestrator, CommitRelayClient

client = CommitRelayClient()
orchestrator = WorkflowOrchestrator(client, manager)

# Create workflow with dependencies: scan -> fix -> verify
workflow = (orchestrator
    .add_task('scan', lambda: manager.create_security_scan(
        repository='owner/repo',
        description='Initial scan'
    ))
    .add_task('fix', lambda: manager.create_security_fix(
        repository='owner/repo',
        vulnerabilities=[],
        description='Apply fixes'
    ), depends_on=['scan'])
    .add_task('verify', lambda: manager.create_security_scan(
        repository='owner/repo',
        description='Verify fixes'
    ), depends_on=['fix'])
)

# Execute workflow
task_ids = workflow.execute(poll_interval=10)
print(f"Workflow completed: {task_ids}")
```

#### Batch Task Creation

```python
# Create multiple security scans
repositories = [
    'owner/repo1',
    'owner/repo2',
    'owner/repo3'
]

task_ids = []
for repo in repositories:
    task_id = manager.create_security_scan(
        repository=repo,
        priority=TaskPriority.HIGH,
        description=f'Batch scan: {repo}'
    )
    task_ids.append(task_id)

print(f"Created {len(task_ids)} tasks")
```

### Analytics

```python
from commit_relay import CommitRelayClient, MetricsAggregator, TrendAnalyzer

client = CommitRelayClient()
aggregator = MetricsAggregator(client)

# Get comprehensive statistics
stats = aggregator.get_comprehensive_summary(hours=24)
print(f"Avg Workers: {stats['worker_stats']['avg_active_workers']}")

# Detect trends
df = client.metrics.to_dataframe(hours=24)
trend = TrendAnalyzer.detect_trend(df['success_rate'])
print(f"Trend: {trend['direction']}, Confidence: {trend['confidence']:.1%}")
```

### Health Monitoring

```python
from commit_relay import HealthChecker, AnomalyDetector

# Health checks
checker = HealthChecker(client)
health = checker.get_overall_health()
print(f"Status: {health['overall_status']}")

# Print formatted report
checker.print_health_report()

# Anomaly detection
detector = AnomalyDetector()
anomalies = detector.detect_anomalies(client, 'success_rate', hours=24)
print(f"Found {anomalies['anomalies_count']} anomalies")
```

### Report Generation

```python
from commit_relay import ReportGenerator, DashboardVisualizer

# Generate text report
generator = ReportGenerator(client)
report = generator.generate_daily_summary()
print(report)

# Export to markdown
generator.export_to_markdown('/tmp/report.md', hours=24)

# Create visualizations
viz = DashboardVisualizer(client)
viz.create_dashboard(hours=24, save_path='/tmp/dashboard.png')
```

### Data Export

```python
from commit_relay import DataExporter

exporter = DataExporter(client)

# Export everything
exporter.export_all_to_directory('/tmp/exports')

# Export to Excel
exporter.export_to_excel('/tmp/data.xlsx', hours=24)

# Export to JSON
exporter.export_to_json('/tmp/data.json', metrics_hours=24)
```

## API Reference

### Client Classes

#### `CommitRelayClient(base_url='http://localhost:3000', timeout=30)`

Main client for API access. Provides resource-specific sub-clients:

- `client.workers` - Worker management
- `client.tasks` - Task operations
- `client.metrics` - Metrics data
- `client.health` - Health status
- `client.events` - System events
- `client.daemons` - Daemon control
- `client.git_ops` - Git operations

### Resource Clients

#### Workers

```python
client.workers.list()                    # Get all workers
client.workers.get(worker_id)           # Get specific worker
client.workers.get_active()             # Get active workers only
client.workers.get_stats()              # Get worker statistics
client.workers.to_dataframe()           # Export to DataFrame
client.workers.export_to_csv(path)      # Export to CSV
```

#### Tasks

```python
client.tasks.list(limit=None)           # Get all tasks
client.tasks.get(task_id)               # Get specific task
client.tasks.get_by_status(status)      # Filter by status
client.tasks.get_stats()                # Get task statistics
client.tasks.to_dataframe(status=None)  # Export to DataFrame
```

#### Metrics

```python
client.metrics.get_current()                        # Current snapshot
client.metrics.get_history(hours=24)                # Historical data
client.metrics.to_dataframe(hours=24)               # Export to DataFrame
client.metrics.get_summary_stats(hours=24)          # Summary statistics
client.metrics.export_to_csv(path, hours=24)        # Export to CSV
```

### Analytics

#### MetricsAggregator

```python
aggregator = MetricsAggregator(client)
aggregator.get_worker_stats(hours=24)               # Worker statistics
aggregator.get_task_stats(hours=24)                 # Task statistics
aggregator.get_hourly_throughput(hours=24)          # Hourly task counts
aggregator.get_comprehensive_summary(hours=24)       # Full summary
```

#### TrendAnalyzer

```python
TrendAnalyzer.detect_trend(series)                  # Detect trend direction
TrendAnalyzer.moving_average(series, window=5)      # Moving average
TrendAnalyzer.detect_volatility(series)             # Volatility metrics
TrendAnalyzer.find_outliers(series, method='iqr')   # Outlier detection
```

#### MetricsForecaster

```python
MetricsForecaster.forecast_linear(series, periods=5)                # Linear forecast
MetricsForecaster.predict_capacity_breach(series, limit, periods)   # Capacity prediction
```

### Monitoring

#### HealthChecker

```python
checker = HealthChecker(client)
checker.check_worker_pool()                         # Check worker pool
checker.check_success_rate()                        # Check success rate
checker.run_all_checks()                            # Run all checks
checker.get_overall_health()                        # Overall status
checker.print_health_report()                       # Print formatted report
```

#### AnomalyDetector

```python
detector = AnomalyDetector()
detector.detect_anomalies(client, metric, hours=24) # Detect anomalies
detector.detect_all_metrics_anomalies(client)       # Scan all metrics
detector.get_anomaly_report(client, hours=24)       # Generate report
```

#### AlertManager

```python
manager = AlertManager()
manager.add_handler(handler_func)                   # Add alert handler
manager.generate_alerts_from_health(health)         # Generate from health checks
manager.generate_alerts_from_anomalies(anomalies)   # Generate from anomalies
```

### Orchestration

#### TaskManager

```python
manager = TaskManager(commit_relay_home='/path/to/commit-relay', auto_commit=True)

# Create tasks
manager.create_security_scan(repository, branch='main', scan_types=None, priority=HIGH)
manager.create_security_fix(repository, vulnerabilities, branch='main', priority=CRITICAL)
manager.create_development_task(repository, requirements, branch='main', priority=MEDIUM)
manager.create_catalog_task(repository, catalog_depth='deep', priority=LOW)

# Query tasks
manager.get_task(task_id)                       # Get specific task
manager.get_pending_tasks()                     # Get pending tasks
manager.get_tasks_by_status(status)             # Filter by status
manager.get_tasks_by_type(task_type)            # Filter by type

# Update tasks
manager.update_task_status(task_id, status)     # Update status
manager.delete_task(task_id)                    # Delete task
```

#### TaskBuilder

```python
builder = TaskBuilder(manager)

# Fluent API for task creation
task_id = (builder
    .security_scan()                            # Set task type
    .repository('owner/repo')                   # Set repository
    .branch('main')                             # Set branch
    .priority(TaskPriority.HIGH)                # Set priority
    .scan_types(['dependencies', 'secrets'])    # Set scan types
    .description('Security audit')              # Set description
    .create())                                  # Create task

# Builder can be reused after reset
builder.reset()
```

#### WorkflowOrchestrator

```python
orchestrator = WorkflowOrchestrator(client, manager)

# Add tasks with dependencies
orchestrator.add_task('task1', lambda: manager.create_task(...))
orchestrator.add_task('task2', lambda: manager.create_task(...), depends_on=['task1'])
orchestrator.add_task('task3', lambda: manager.create_task(...), depends_on=['task1', 'task2'])

# Execute workflow
task_ids = orchestrator.execute(
    poll_interval=10,       # Poll every 10 seconds
    max_retries=3,          # Retry failed tasks up to 3 times
    timeout_minutes=120,    # Timeout after 2 hours
    fail_fast=True          # Stop on first failure
)

# Reset for reuse
orchestrator.reset()
```

### Reporting

#### ReportGenerator

```python
generator = ReportGenerator(client)
generator.generate_daily_summary(hours=24)          # Daily text report
generator.generate_markdown_report(hours=24)        # Markdown report
generator.export_to_markdown(path, hours=24)        # Save to file
generator.generate_executive_summary(hours=24)      # Executive summary
```

#### DashboardVisualizer

```python
viz = DashboardVisualizer(client)
viz.plot_worker_activity(hours=24, save_path=path)          # Worker activity plot
viz.plot_success_rate(hours=24, save_path=path)             # Success rate plot
viz.create_dashboard(hours=24, save_path=path)              # Full dashboard
viz.plot_worker_type_distribution(save_path=path)           # Worker distribution
```

## Examples

The `examples/` directory contains fully working scripts:

**Orchestration:**
- `task_creation.py` - Programmatic task creation examples
- `workflow_demo.py` - Multi-task workflow orchestration
- `batch_tasks.py` - Batch task creation patterns

**Analytics & Monitoring:**
- `basic_usage.py` - Basic SDK operations and data access
- `analytics_demo.py` - Analytics and trend analysis
- `health_monitoring.py` - Health checks and anomaly detection
- `daily_report.py` - Complete daily report generation

Run examples:

```bash
cd examples

# Orchestration examples
python task_creation.py
python workflow_demo.py
python batch_tasks.py

# Analytics examples
python basic_usage.py
python analytics_demo.py
python health_monitoring.py
python daily_report.py
```

## Error Handling

The SDK provides a comprehensive exception hierarchy:

```python
from commit_relay import CommitRelayError, APIError, ConnectionError

try:
    metrics = client.metrics.get_current()
except ConnectionError as e:
    print(f"Connection failed: {e}")
except APIError as e:
    print(f"API error: {e}, Status: {e.status_code}")
except CommitRelayError as e:
    print(f"SDK error: {e}")
```

## Testing

Run the test suite:

```bash
cd python-sdk
pytest tests/ -v
pytest tests/ --cov=commit_relay --cov-report=html
```

## Development

### Setup Development Environment

```bash
pip install -e ".[dev]"
```

### Code Formatting

```bash
black commit_relay/
```

### Type Checking

```bash
mypy commit_relay/
```

### Linting

```bash
flake8 commit_relay/
```

## Requirements

### Minimum Requirements

- Python >= 3.8
- requests >= 2.28.0
- pandas >= 1.5.0
- numpy >= 1.23.0
- scipy >= 1.9.0

### Optional Requirements

- matplotlib >= 3.6.0 (for visualizations)
- seaborn >= 0.12.0 (for visualizations)
- openpyxl >= 3.0.0 (for Excel export)
- jupyter >= 1.0.0 (for notebooks)

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for detailed design documentation.

## License

MIT License - See LICENSE file for details

## Contributing

Contributions are welcome! Please see CONTRIBUTING.md for guidelines.

## Support

For issues and questions:
- GitHub Issues: https://github.com/yourusername/commit-relay/issues
- Documentation: https://github.com/yourusername/commit-relay/tree/main/python-sdk

## Changelog

### Version 0.1.0 (2025-01-07)

- Initial release
- Complete API client for all 22 endpoints
- Analytics module with aggregation, trends, and forecasting
- Health monitoring with anomaly detection
- Reporting with visualizations and exports
- Comprehensive documentation and examples
