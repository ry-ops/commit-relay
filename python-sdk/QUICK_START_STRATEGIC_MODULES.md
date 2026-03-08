# Quick Start: Strategic Modules

Fast reference for using ML, Discovery, and CI/CD integration modules.

## Installation

```bash
pip install -r requirements.txt
export GITHUB_TOKEN="your_token"  # For GitHub features
```

## ML-Powered Insights

### Predict Task Failure

```python
from commit_relay import TaskFailurePredictor, CommitRelayClient, TaskManager

client = CommitRelayClient()
manager = TaskManager()

predictor = TaskFailurePredictor(client, manager)
predictor.train()  # Train once

prob = predictor.predict_failure({
    'type': 'security-scan',
    'priority': 'high'
})
print(f"Failure risk: {prob:.1%} ({predictor.get_risk_level(prob)})")
```

### Detect Anomalies

```python
from commit_relay import MetricsAnomalyDetector, CommitRelayClient

detector = MetricsAnomalyDetector(CommitRelayClient())
anomalies = detector.detect_all_metrics(hours=24)

for metric, result in anomalies.items():
    if result.get('is_anomalous'):
        print(f"🚨 {result['message']}")
```

### Smart Prioritization

```python
from commit_relay import SmartTaskPrioritizer, CommitRelayClient, TaskManager, TaskFailurePredictor

client = CommitRelayClient()
manager = TaskManager()
predictor = TaskFailurePredictor(client, manager)
predictor.train()

prioritizer = SmartTaskPrioritizer(client, manager, predictor)
ranked = prioritizer.prioritize_pending_tasks()

for task in ranked[:5]:
    print(f"{task['id']}: Score {task['priority_score']:.2f}")
```

## Repository Discovery

### Discover & Onboard Repositories

```python
import os
from github import Github
from commit_relay import GitHubDiscoveryService, TaskManager

gh = Github(os.environ['GITHUB_TOKEN'])
manager = TaskManager()
discovery = GitHubDiscoveryService(gh, manager)

# Discover repositories
repos = discovery.discover_organization_repos('ry-ops')

# Onboard a repository
for repo in repos:
    tasks = discovery.onboard_repository(repo)
    print(f"Onboarded {repo['full_name']}: {tasks}")
```

### Batch Onboarding

```python
results = discovery.batch_onboard('ry-ops')
print(f"Onboarded {results['onboarded']} repos")
print(f"Created {results['tasks_created']} tasks")
```

### Health Scores

```python
for repo in repos:
    health = discovery.get_repository_health_score(repo)
    print(f"{repo['name']}: Grade {health['grade']}")
```

## CI/CD Integration

### GitHub Actions Security Scan

**Python script (scripts/security-scan.py):**

```python
#!/usr/bin/env python3
from commit_relay import TaskManager, GitHubActionsTrigger
import sys

manager = TaskManager()
trigger = GitHubActionsTrigger(manager)

success = trigger.run_security_scan_and_wait(
    timeout=600,
    fail_on_vulnerabilities=True
)

sys.exit(0 if success else 1)
```

**Workflow (.github/workflows/security-scan.yml):**

```yaml
name: Security Scan
on: [push, pull_request]

jobs:
  security:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Run Security Scan
        run: python scripts/security-scan.py
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

### PR Review Automation

```python
from commit_relay import GitHubActionsTrigger, TaskManager

trigger = GitHubActionsTrigger(TaskManager())
task_id = trigger.create_pr_review_task(pr_number=123)
print(f"Created review task: {task_id}")
```

### Report Results

```python
from commit_relay import GitHubActionsReporter

reporter = GitHubActionsReporter()
reporter.set_output('task_id', task_id)
reporter.add_summary('## Results\n\nScan completed successfully')
```

## Examples

Run the demo scripts:

```bash
cd python-sdk/examples

# ML insights
python ml_insights_demo.py

# Repository discovery (requires GITHUB_TOKEN)
python repository_discovery_demo.py

# CI/CD integration
python cicd_integration_demo.py
```

## Documentation

Full guides:
- [ML Insights Guide](ML_INSIGHTS_GUIDE.md)
- [Integrations Guide](INTEGRATIONS_GUIDE.md)
- [Implementation Report](IMPLEMENTATION_REPORT_STRATEGIC_MODULES.md)

## Common Patterns

### Automated Task Management

```python
# Train predictor
predictor = TaskFailurePredictor(client, manager)
predictor.train()

# Monitor metrics
detector = MetricsAnomalyDetector(client)
anomalies = detector.detect_all_metrics()

# Prioritize and execute
prioritizer = SmartTaskPrioritizer(client, manager, predictor)
tasks = prioritizer.prioritize_pending_tasks()

for task in tasks[:10]:  # Top 10
    if task['failure_risk'] < 0.3:  # Low risk only
        # Execute task
        pass
```

### Continuous Repository Discovery

```python
import time
from pathlib import Path

tracked = set()

while True:
    repos = discovery.discover_organization_repos('ry-ops')
    new_repos = [r for r in repos if r['full_name'] not in tracked]

    for repo in new_repos:
        discovery.onboard_repository(repo)
        tracked.add(repo['full_name'])

    time.sleep(3600)  # Check hourly
```

### CI/CD Security Gate

```python
# In GitHub Actions
trigger = GitHubActionsTrigger(manager)
reporter = GitHubActionsReporter()

success = trigger.run_security_scan_and_wait(timeout=600)

reporter.set_output('scan_status', 'pass' if success else 'fail')

if not success:
    sys.exit(1)
```

## Troubleshooting

### ML Module

**Issue:** "Only X tasks available, need 20 for reliable training"
**Solution:** Wait for more historical data or use `min_samples=X` parameter

### Discovery

**Issue:** "Bad credentials"
**Solution:** Check `GITHUB_TOKEN` environment variable

**Issue:** "API rate limit exceeded"
**Solution:** Wait or use authenticated requests (higher limit)

### CI/CD

**Issue:** Task timeout
**Solution:** Increase `timeout` parameter in `run_security_scan_and_wait()`

## API Quick Reference

### ML Classes

- `TaskFailurePredictor(client, manager)` - Predict task failures
- `MetricsAnomalyDetector(client)` - Detect metric anomalies
- `SmartTaskPrioritizer(client, manager, predictor)` - Prioritize tasks

### Integration Classes

- `GitHubDiscoveryService(github_client, task_manager)` - Discover repos
- `GitHubActionsTrigger(task_manager)` - Trigger from CI/CD
- `GitHubActionsReporter()` - Report to GitHub Actions

### Key Methods

```python
# Predictor
.train(min_samples=20)
.predict_failure(task_data) -> float
.get_risk_level(probability) -> str

# Detector
.detect_all_metrics(hours=24) -> dict
.detect_metric_anomaly(metric_name, hours=24) -> dict

# Prioritizer
.prioritize_pending_tasks() -> List[Dict]

# Discovery
.discover_organization_repos(org_name) -> List[Dict]
.onboard_repository(repo_info) -> Dict[str, str]
.batch_onboard(org_name) -> Dict
.get_repository_health_score(repo_info) -> Dict

# CI/CD Trigger
.run_security_scan_and_wait(timeout=600) -> bool
.create_pr_review_task(pr_number) -> str

# Reporter
.set_output(name, value)
.add_summary(markdown)
.create_task_summary(task)
```

## Support

- Full documentation: [ML_INSIGHTS_GUIDE.md](ML_INSIGHTS_GUIDE.md)
- Integration guide: [INTEGRATIONS_GUIDE.md](INTEGRATIONS_GUIDE.md)
- Examples: `examples/` directory
- Implementation details: [IMPLEMENTATION_REPORT_STRATEGIC_MODULES.md](IMPLEMENTATION_REPORT_STRATEGIC_MODULES.md)
