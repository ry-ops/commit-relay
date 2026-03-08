#!/usr/bin/env python3
"""
ML-Powered Insights Demo
"""

from commit_relay import (
    CommitRelayClient,
    TaskManager,
    TaskFailurePredictor,
    MetricsAnomalyDetector,
    SmartTaskPrioritizer
)

client = CommitRelayClient()
manager = TaskManager()

print("=" * 60)
print("ML-POWERED INSIGHTS DEMO")
print("=" * 60)

# 1. Train failure prediction model
print("\n1. Training Task Failure Prediction Model...")
predictor = TaskFailurePredictor(client, manager)
predictor.train()

# 2. Predict failure for new task
print("\n2. Predicting Failure Probability...")
test_task = {
    'type': 'security-scan',
    'repository': 'ry-ops/test-repo',
    'priority': 'high'
}

prob = predictor.predict_failure(test_task)
risk = predictor.get_risk_level(prob)
print(f"   Failure Probability: {prob:.1%}")
print(f"   Risk Level: {risk}")

# 3. Detect metric anomalies
print("\n3. Detecting Metric Anomalies...")
detector = MetricsAnomalyDetector(client)
anomalies = detector.detect_all_metrics(hours=24)

for metric, result in anomalies.items():
    if result.get('is_anomalous'):
        print(f"   🚨 {result['message']}")
    else:
        print(f"   ✓ {metric}: {result.get('message', 'OK')}")

# 4. Smart task prioritization
print("\n4. Intelligent Task Prioritization...")
prioritizer = SmartTaskPrioritizer(client, manager, predictor)
ranked = prioritizer.prioritize_pending_tasks()

print(f"   Found {len(ranked)} pending tasks")
for i, task in enumerate(ranked[:5], 1):
    print(f"   {i}. {task['id']}: Score {task['priority_score']:.2f} "
          f"(Failure Risk: {task['failure_risk']:.1%})")

print("\n" + "=" * 60)
