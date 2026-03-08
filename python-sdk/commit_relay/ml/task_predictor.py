"""
ML-powered task failure prediction and intelligent prioritization.
"""

import pandas as pd
import numpy as np
from typing import Dict, List, Optional
from datetime import datetime, timedelta
import pickle
from pathlib import Path


class TaskFailurePredictor:
    """
    Predict task failure probability using historical data.

    Example:
        predictor = TaskFailurePredictor(client, manager)
        predictor.train()

        # Predict for new task
        prob = predictor.predict_failure({
            'type': 'security-scan',
            'repository': 'ry-ops/test-repo',
            'priority': 'high'
        })
        print(f"Failure probability: {prob:.1%}")
    """

    def __init__(self, client, manager):
        self.client = client
        self.manager = manager
        self.model = None
        self.feature_columns = ['priority_score', 'type_score', 'hour_of_day', 'day_of_week']
        self.model_path = Path('/Users/ryandahlberg/commit-relay/python-sdk/models/task_failure_model.pkl')

    def _prepare_features(self, tasks: List[Dict]) -> pd.DataFrame:
        """Prepare features for ML model."""
        data = []

        for task in tasks:
            # Extract features
            features = {
                'task_id': task['id'],
                'priority_score': self._encode_priority(task.get('priority', 'medium')),
                'type_score': self._encode_type(task.get('type', 'development')),
                'hour_of_day': self._extract_hour(task.get('created_at')),
                'day_of_week': self._extract_day(task.get('created_at')),
                'failed': 1 if task.get('status') == 'failed' else 0
            }
            data.append(features)

        return pd.DataFrame(data)

    def _encode_priority(self, priority: str) -> int:
        """Encode priority as numeric score."""
        priority_map = {'low': 1, 'medium': 2, 'high': 3, 'critical': 4}
        return priority_map.get(priority.lower(), 2)

    def _encode_type(self, task_type: str) -> int:
        """Encode task type as numeric score."""
        type_map = {
            'catalog': 1,
            'development': 2,
            'security-scan': 3,
            'security-fix': 4
        }
        return type_map.get(task_type.lower(), 2)

    def _extract_hour(self, timestamp: Optional[str]) -> int:
        """Extract hour from timestamp."""
        if not timestamp:
            return 12
        try:
            dt = datetime.fromisoformat(timestamp.replace('Z', '+00:00'))
            return dt.hour
        except:
            return 12

    def _extract_day(self, timestamp: Optional[str]) -> int:
        """Extract day of week from timestamp."""
        if not timestamp:
            return 3
        try:
            dt = datetime.fromisoformat(timestamp.replace('Z', '+00:00'))
            return dt.weekday()
        except:
            return 3

    def train(self, min_samples: int = 20):
        """
        Train failure prediction model using historical data.

        Args:
            min_samples: Minimum samples needed for training
        """
        # Get all tasks
        tasks = self.manager.get_all_tasks()

        if len(tasks) < min_samples:
            print(f"Warning: Only {len(tasks)} tasks available, need {min_samples} for reliable training")
            return False

        # Prepare data
        df = self._prepare_features(tasks)

        # Simple logistic regression (no sklearn dependency)
        # Use failure rate by feature combinations
        self.model = {
            'priority_failure_rate': df.groupby('priority_score')['failed'].mean().to_dict(),
            'type_failure_rate': df.groupby('type_score')['failed'].mean().to_dict(),
            'hour_failure_rate': df.groupby('hour_of_day')['failed'].mean().to_dict(),
            'overall_failure_rate': df['failed'].mean()
        }

        # Save model
        self.model_path.parent.mkdir(parents=True, exist_ok=True)
        with open(self.model_path, 'wb') as f:
            pickle.dump(self.model, f)

        print(f"Model trained on {len(tasks)} tasks")
        print(f"Overall failure rate: {self.model['overall_failure_rate']:.1%}")

        return True

    def load_model(self):
        """Load trained model from disk."""
        if self.model_path.exists():
            with open(self.model_path, 'rb') as f:
                self.model = pickle.load(f)
            return True
        return False

    def predict_failure(self, task_data: Dict) -> float:
        """
        Predict failure probability for a task.

        Args:
            task_data: Dict with 'type', 'priority', 'created_at' (optional)

        Returns:
            Failure probability (0-1)
        """
        if not self.model:
            if not self.load_model():
                return 0.5  # Default 50% if no model

        # Extract features
        priority_score = self._encode_priority(task_data.get('priority', 'medium'))
        type_score = self._encode_type(task_data.get('type', 'development'))
        hour = self._extract_hour(task_data.get('created_at'))

        # Get failure rates for each feature
        priority_rate = self.model['priority_failure_rate'].get(priority_score,
                                                                self.model['overall_failure_rate'])
        type_rate = self.model['type_failure_rate'].get(type_score,
                                                        self.model['overall_failure_rate'])
        hour_rate = self.model['hour_failure_rate'].get(hour,
                                                        self.model['overall_failure_rate'])

        # Weighted average
        prob = (priority_rate * 0.4 + type_rate * 0.4 + hour_rate * 0.2)

        return prob

    def get_risk_level(self, probability: float) -> str:
        """Convert probability to risk level."""
        if probability < 0.2:
            return 'LOW'
        elif probability < 0.4:
            return 'MEDIUM'
        elif probability < 0.6:
            return 'HIGH'
        else:
            return 'CRITICAL'


class MetricsAnomalyDetector:
    """
    Detect anomalies in metrics using statistical methods.

    Example:
        detector = MetricsAnomalyDetector(client)
        anomalies = detector.detect_all_metrics()

        for metric, results in anomalies.items():
            if results['is_anomalous']:
                print(f"Anomaly in {metric}: {results['message']}")
    """

    def __init__(self, client):
        self.client = client

    def detect_metric_anomaly(self,
                            metric_name: str,
                            hours: int = 24,
                            zscore_threshold: float = 3.0) -> Dict:
        """
        Detect anomalies in a specific metric.

        Args:
            metric_name: Name of metric to check
            hours: Hours of history to analyze
            zscore_threshold: Z-score threshold for anomaly

        Returns:
            Dict with anomaly detection results
        """
        # Get historical data
        df = self.client.metrics.to_dataframe(hours=hours)

        if metric_name not in df.columns:
            return {'error': f'Metric {metric_name} not found'}

        series = df[metric_name]

        # Calculate statistics
        mean = series.mean()
        std = series.std()
        current = series.iloc[-1] if len(series) > 0 else 0

        # Z-score
        if std > 0:
            zscore = abs((current - mean) / std)
            is_anomalous = zscore > zscore_threshold
        else:
            zscore = 0
            is_anomalous = False

        # Direction
        if current > mean + std:
            direction = 'high'
        elif current < mean - std:
            direction = 'low'
        else:
            direction = 'normal'

        return {
            'metric': metric_name,
            'current_value': current,
            'mean': mean,
            'std': std,
            'zscore': zscore,
            'is_anomalous': is_anomalous,
            'direction': direction,
            'message': self._generate_anomaly_message(metric_name, current, mean, direction, is_anomalous)
        }

    def detect_all_metrics(self, hours: int = 24) -> Dict[str, Dict]:
        """Detect anomalies across all key metrics."""
        metrics_to_check = ['active_workers', 'success_rate', 'tasks_completed', 'tasks_in_progress']

        results = {}
        for metric in metrics_to_check:
            try:
                results[metric] = self.detect_metric_anomaly(metric, hours=hours)
            except Exception as e:
                results[metric] = {'error': str(e)}

        return results

    def _generate_anomaly_message(self, metric: str, current: float, mean: float,
                                  direction: str, is_anomalous: bool) -> str:
        """Generate human-readable anomaly message."""
        if not is_anomalous:
            return f"{metric} is within normal range"

        if direction == 'high':
            return f"{metric} is unusually HIGH: {current:.1f} (normal: {mean:.1f})"
        elif direction == 'low':
            return f"{metric} is unusually LOW: {current:.1f} (normal: {mean:.1f})"
        else:
            return f"{metric} is normal"


class SmartTaskPrioritizer:
    """
    Intelligently prioritize tasks based on multiple factors.

    Example:
        prioritizer = SmartTaskPrioritizer(client, manager, predictor)
        ranked = prioritizer.prioritize_pending_tasks()

        for task in ranked[:5]:  # Top 5
            print(f"{task['id']}: Priority Score {task['priority_score']:.2f}")
    """

    def __init__(self, client, manager, predictor):
        self.client = client
        self.manager = manager
        self.predictor = predictor

    def prioritize_pending_tasks(self) -> List[Dict]:
        """
        Rank pending tasks by intelligent priority score.

        Returns:
            List of tasks sorted by priority score (highest first)
        """
        pending = self.manager.get_pending_tasks()

        scored_tasks = []
        for task in pending:
            score = self._calculate_priority_score(task)
            task_with_score = task.copy()
            task_with_score['priority_score'] = score
            task_with_score['failure_risk'] = self.predictor.predict_failure(task)
            scored_tasks.append(task_with_score)

        # Sort by priority score (descending)
        scored_tasks.sort(key=lambda x: x['priority_score'], reverse=True)

        return scored_tasks

    def _calculate_priority_score(self, task: Dict) -> float:
        """
        Calculate intelligent priority score.

        Factors:
        - Base priority (30%)
        - Failure risk (20%)
        - Task age (20%)
        - Task type urgency (30%)
        """
        # Base priority
        priority_map = {'critical': 4, 'high': 3, 'medium': 2, 'low': 1}
        base_score = priority_map.get(task.get('priority', 'medium').lower(), 2) * 0.3

        # Failure risk (lower risk = higher score)
        failure_prob = self.predictor.predict_failure(task)
        risk_score = (1 - failure_prob) * 0.2

        # Task age (older = higher score)
        age_minutes = self._get_age_minutes(task.get('created_at', ''))
        age_score = min(age_minutes / 1440, 1.0) * 0.2  # Cap at 1 day

        # Task type urgency
        type_urgency = {
            'security-fix': 1.0,
            'security-scan': 0.8,
            'development': 0.5,
            'catalog': 0.3
        }
        type_score = type_urgency.get(task.get('type', 'development'), 0.5) * 0.3

        total_score = base_score + risk_score + age_score + type_score

        return total_score

    def _get_age_minutes(self, created_at: str) -> float:
        """Calculate task age in minutes."""
        if not created_at:
            return 0
        try:
            created = datetime.fromisoformat(created_at.replace('Z', '+00:00'))
            return (datetime.now(created.tzinfo) - created).total_seconds() / 60
        except:
            return 0
