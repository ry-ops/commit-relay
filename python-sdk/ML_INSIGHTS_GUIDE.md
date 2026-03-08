# ML-Powered Insights Guide

This guide covers the machine learning capabilities in the commit-relay Python SDK.

## Overview

The ML module provides three main capabilities:
1. **Task Failure Prediction** - Predict which tasks are likely to fail
2. **Anomaly Detection** - Detect unusual patterns in metrics
3. **Smart Task Prioritization** - Intelligently prioritize pending tasks

## Installation

```bash
pip install -e /path/to/commit-relay/python-sdk
```

## Task Failure Prediction

### Basic Usage

```python
from commit_relay import CommitRelayClient, TaskManager, TaskFailurePredictor

client = CommitRelayClient()
manager = TaskManager()

# Initialize predictor
predictor = TaskFailurePredictor(client, manager)

# Train model on historical data
predictor.train(min_samples=20)

# Predict failure probability for new task
task_data = {
    'type': 'security-scan',
    'repository': 'ry-ops/test-repo',
    'priority': 'high'
}

probability = predictor.predict_failure(task_data)
risk_level = predictor.get_risk_level(probability)

print(f"Failure Probability: {probability:.1%}")
print(f"Risk Level: {risk_level}")
```

### How It Works

The predictor uses historical task data to learn patterns:

1. **Feature Engineering**: Extracts features from tasks
   - Priority level (low, medium, high, critical)
   - Task type (catalog, development, security-scan, security-fix)
   - Time of day (hour)
   - Day of week

2. **Training**: Calculates failure rates for each feature combination
   - No external ML libraries required
   - Simple, interpretable model
   - Fast training and prediction

3. **Prediction**: Weighted average of feature-specific failure rates
   - Priority: 40% weight
   - Task type: 40% weight
   - Time of day: 20% weight

### Risk Levels

- **LOW** (< 20%): Safe to execute
- **MEDIUM** (20-40%): Monitor closely
- **HIGH** (40-60%): Consider mitigation
- **CRITICAL** (> 60%): High risk, review before executing

### Model Persistence

Models are automatically saved to disk:

```python
# Save location
/Users/ryandahlberg/commit-relay/python-sdk/models/task_failure_model.pkl

# Load existing model
predictor.load_model()
```

## Anomaly Detection

### Basic Usage

```python
from commit_relay import CommitRelayClient, MetricsAnomalyDetector

client = CommitRelayClient()
detector = MetricsAnomalyDetector(client)

# Detect anomalies in all metrics
anomalies = detector.detect_all_metrics(hours=24)

for metric, result in anomalies.items():
    if result.get('is_anomalous'):
        print(f"🚨 {result['message']}")
    else:
        print(f"✓ {metric}: Normal")
```

### Single Metric Detection

```python
# Detect anomaly in specific metric
result = detector.detect_metric_anomaly(
    metric_name='active_workers',
    hours=24,
    zscore_threshold=3.0
)

print(f"Current: {result['current_value']:.1f}")
print(f"Mean: {result['mean']:.1f}")
print(f"Z-Score: {result['zscore']:.2f}")
print(f"Anomalous: {result['is_anomalous']}")
```

### How It Works

Statistical anomaly detection using Z-scores:

1. Collects historical data (default: 24 hours)
2. Calculates mean and standard deviation
3. Computes Z-score for current value
4. Flags anomaly if Z-score exceeds threshold (default: 3.0)

### Metrics Monitored

- `active_workers` - Number of active workers
- `success_rate` - Task success rate
- `tasks_completed` - Completed tasks count
- `tasks_in_progress` - In-progress tasks count

## Smart Task Prioritization

### Basic Usage

```python
from commit_relay import (
    CommitRelayClient,
    TaskManager,
    TaskFailurePredictor,
    SmartTaskPrioritizer
)

client = CommitRelayClient()
manager = TaskManager()
predictor = TaskFailurePredictor(client, manager)
predictor.train()

# Initialize prioritizer
prioritizer = SmartTaskPrioritizer(client, manager, predictor)

# Get ranked pending tasks
ranked_tasks = prioritizer.prioritize_pending_tasks()

# Show top 5
for i, task in enumerate(ranked_tasks[:5], 1):
    print(f"{i}. {task['id']}")
    print(f"   Priority Score: {task['priority_score']:.2f}")
    print(f"   Failure Risk: {task['failure_risk']:.1%}")
```

### Priority Scoring

Intelligent scoring based on multiple factors:

1. **Base Priority (30%)**: Task's assigned priority
   - Critical: 4 points
   - High: 3 points
   - Medium: 2 points
   - Low: 1 point

2. **Failure Risk (20%)**: Lower risk = higher score
   - Uses predictor to estimate failure probability
   - Inverse relationship (low risk preferred)

3. **Task Age (20%)**: Older tasks prioritized
   - Linear scaling up to 1 day
   - Prevents task starvation

4. **Task Type Urgency (30%)**: Type-based urgency
   - security-fix: 1.0
   - security-scan: 0.8
   - development: 0.5
   - catalog: 0.3

### Example Output

```
1. task-security-fix-001: Score 0.92 (Failure Risk: 15%)
2. task-security-scan-023: Score 0.85 (Failure Risk: 22%)
3. task-development-045: Score 0.68 (Failure Risk: 35%)
4. task-catalog-012: Score 0.42 (Failure Risk: 18%)
```

## Complete Example

```python
#!/usr/bin/env python3
"""
ML Insights Pipeline
"""

from commit_relay import (
    CommitRelayClient,
    TaskManager,
    TaskFailurePredictor,
    MetricsAnomalyDetector,
    SmartTaskPrioritizer
)

def main():
    # Initialize
    client = CommitRelayClient()
    manager = TaskManager()

    # 1. Train failure predictor
    print("Training failure prediction model...")
    predictor = TaskFailurePredictor(client, manager)
    predictor.train()

    # 2. Detect anomalies
    print("\nDetecting metric anomalies...")
    detector = MetricsAnomalyDetector(client)
    anomalies = detector.detect_all_metrics()

    for metric, result in anomalies.items():
        if result.get('is_anomalous'):
            print(f"  🚨 {result['message']}")

    # 3. Prioritize tasks
    print("\nPrioritizing pending tasks...")
    prioritizer = SmartTaskPrioritizer(client, manager, predictor)
    ranked = prioritizer.prioritize_pending_tasks()

    print(f"Found {len(ranked)} pending tasks")
    for i, task in enumerate(ranked[:5], 1):
        print(f"  {i}. {task['id']}: "
              f"Score {task['priority_score']:.2f}, "
              f"Risk {task['failure_risk']:.1%}")

if __name__ == '__main__':
    main()
```

## Best Practices

### Training Frequency

- **Initial training**: When system has 20+ historical tasks
- **Retraining**: Daily or weekly for continuous improvement
- **Validation**: Compare predictions with actual outcomes

### Anomaly Detection

- **Baseline period**: Use 24-48 hours for baseline
- **Threshold tuning**: Adjust Z-score threshold based on environment
  - Stricter (2.0): More sensitive, more false positives
  - Looser (4.0): Less sensitive, fewer false positives
  - Default (3.0): Balanced

### Task Prioritization

- **Automation**: Use in task scheduling system
- **Manual override**: Allow operators to override when needed
- **Monitoring**: Track prioritization effectiveness

## Troubleshooting

### Insufficient Training Data

```
Warning: Only 5 tasks available, need 20 for reliable training
```

**Solution**: Wait for more historical data or lower `min_samples` parameter

### Model Not Loading

```python
# Check if model exists
if not predictor.load_model():
    print("Training new model...")
    predictor.train()
```

### No Anomalies Detected

This is normal if system is operating smoothly. Anomalies should be rare.

## Advanced Topics

### Custom Feature Engineering

Extend `TaskFailurePredictor` with custom features:

```python
class CustomPredictor(TaskFailurePredictor):
    def _prepare_features(self, tasks):
        df = super()._prepare_features(tasks)
        # Add custom features
        df['repo_score'] = df['task_id'].apply(self._get_repo_score)
        return df
```

### Integration with Monitoring

```python
# Continuous monitoring
import time

while True:
    anomalies = detector.detect_all_metrics()
    for metric, result in anomalies.items():
        if result.get('is_anomalous'):
            # Trigger alert
            alert_system.send_alert(result['message'])
    time.sleep(300)  # Check every 5 minutes
```

## API Reference

See inline documentation in:
- `/Users/ryandahlberg/commit-relay/python-sdk/commit_relay/ml/task_predictor.py`
