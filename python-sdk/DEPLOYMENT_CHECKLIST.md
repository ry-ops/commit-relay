# Deployment Checklist: Strategic Python Modules

Use this checklist to deploy the ML, Discovery, and CI/CD modules to production.

## Pre-Deployment

### 1. Environment Setup

- [ ] Python 3.9+ installed
- [ ] commit-relay backend running
- [ ] GitHub personal access token created (for discovery features)
- [ ] GitHub Actions configured (for CI/CD features)

### 2. Install Dependencies

```bash
cd /Users/ryandahlberg/commit-relay/python-sdk
pip install -r requirements.txt
```

**Verify:**
```bash
python -c "import pandas, numpy, requests; print('Core dependencies OK')"
python -c "from github import Github; print('PyGithub OK')"
```

### 3. Environment Variables

**For GitHub Discovery:**
```bash
export GITHUB_TOKEN="your_github_personal_access_token"
```

**Verify:**
```bash
python -c "import os; assert os.environ.get('GITHUB_TOKEN'), 'Token not set'"
```

### 4. Install SDK

```bash
pip install -e /Users/ryandahlberg/commit-relay/python-sdk
```

**Verify:**
```bash
python -c "from commit_relay import TaskFailurePredictor, GitHubDiscoveryService; print('Modules OK')"
```

## Testing

### 1. ML Module Tests

```bash
cd /Users/ryandahlberg/commit-relay/python-sdk/examples

# Test ML insights (requires historical task data)
python ml_insights_demo.py
```

**Expected output:**
- Model training completes
- Failure predictions generated
- Anomaly detection runs
- Task prioritization works

### 2. Discovery Module Tests

```bash
# Test repository discovery (requires GITHUB_TOKEN)
python repository_discovery_demo.py
```

**Expected output:**
- Repositories discovered
- Health scores calculated
- Onboarding workflow displayed

### 3. CI/CD Module Tests

```bash
# Test CI/CD integration
python cicd_integration_demo.py
```

**Expected output:**
- Environment variables parsed
- Task creation simulated
- Result reporting demonstrated

## Deployment Steps

### 1. ML Module Deployment

#### A. Train Initial Model

```python
from commit_relay import TaskFailurePredictor, CommitRelayClient, TaskManager

client = CommitRelayClient()
manager = TaskManager()

predictor = TaskFailurePredictor(client, manager)
success = predictor.train(min_samples=20)

if success:
    print("Model trained and saved")
else:
    print("Insufficient data - will train later")
```

- [ ] Initial model training completed
- [ ] Model file created: `/Users/ryandahlberg/commit-relay/python-sdk/models/task_failure_model.pkl`

#### B. Set Up Anomaly Monitoring

```python
from commit_relay import MetricsAnomalyDetector, CommitRelayClient

detector = MetricsAnomalyDetector(CommitRelayClient())

# Test anomaly detection
anomalies = detector.detect_all_metrics(hours=24)
print(f"Checked {len(anomalies)} metrics")
```

- [ ] Anomaly detection tested
- [ ] Metrics accessible
- [ ] No errors

#### C. Configure Task Prioritization

```python
from commit_relay import SmartTaskPrioritizer

prioritizer = SmartTaskPrioritizer(client, manager, predictor)
ranked = prioritizer.prioritize_pending_tasks()

print(f"Prioritized {len(ranked)} tasks")
```

- [ ] Prioritization working
- [ ] Pending tasks retrieved
- [ ] Scoring algorithm functioning

### 2. Discovery Module Deployment

#### A. Test Organization Access

```python
import os
from github import Github

gh = Github(os.environ['GITHUB_TOKEN'])

# Test organization access
org = gh.get_organization('your-org-name')
print(f"Organization: {org.name}")
print(f"Repos: {org.public_repos}")
```

- [ ] GitHub token working
- [ ] Organization accessible
- [ ] API calls successful

#### B. Initial Repository Scan

```python
from commit_relay import GitHubDiscoveryService

discovery = GitHubDiscoveryService(gh, manager)

# Discover repositories
repos = discovery.discover_organization_repos('your-org-name')
print(f"Found {len(repos)} repositories")

# Calculate health scores
for repo in repos[:5]:
    health = discovery.get_repository_health_score(repo)
    print(f"{repo['name']}: Grade {health['grade']}")
```

- [ ] Repository discovery working
- [ ] Health scores calculated
- [ ] No API errors

#### C. Onboard Test Repository

```python
# Onboard one test repository
if repos:
    test_repo = repos[0]
    task_ids = discovery.onboard_repository(test_repo)
    print(f"Created tasks: {task_ids}")
```

- [ ] Test repository onboarded
- [ ] Catalog task created
- [ ] Security scan task created
- [ ] Tasks visible in dashboard

### 3. CI/CD Module Deployment

#### A. Add Workflow Files

```bash
# Copy workflow templates to your repositories
cp /Users/ryandahlberg/commit-relay/python-sdk/.github/workflows/security-scan.yml \
   /path/to/your/repo/.github/workflows/

cp /Users/ryandahlberg/commit-relay/python-sdk/.github/workflows/pr-review.yml \
   /path/to/your/repo/.github/workflows/
```

- [ ] Workflow files copied
- [ ] Files committed to repository
- [ ] GitHub Actions enabled

#### B. Configure Repository Secrets

In GitHub repository settings, add:
- `GITHUB_TOKEN` - Automatically provided by GitHub Actions

- [ ] Secrets configured
- [ ] Workflow permissions set

#### C. Test Workflow Execution

Trigger workflow by:
- Pushing to main/develop branch
- Creating a pull request

Monitor:
- [ ] Workflow triggered
- [ ] Security scan task created
- [ ] Task completed successfully
- [ ] Results reported

## Post-Deployment Validation

### 1. ML Module Validation

```python
# Validate model exists and loads
from commit_relay import TaskFailurePredictor

predictor = TaskFailurePredictor(client, manager)
loaded = predictor.load_model()
print(f"Model loaded: {loaded}")

if loaded:
    # Test prediction
    prob = predictor.predict_failure({
        'type': 'security-scan',
        'priority': 'high'
    })
    print(f"Prediction working: {prob:.2%}")
```

- [ ] Model loads successfully
- [ ] Predictions working
- [ ] Risk levels calculated

### 2. Discovery Module Validation

```python
# Validate discovery is working
repos = discovery.discover_organization_repos('your-org')
print(f"Discovery found {len(repos)} repos")

# Check task creation
if repos:
    counts = {
        'catalog': 0,
        'security': 0
    }
    for repo in repos:
        # Would create tasks in production
        counts['catalog'] += 1
        counts['security'] += 1
    print(f"Would create {sum(counts.values())} tasks")
```

- [ ] Discovery functional
- [ ] API access working
- [ ] Task creation ready

### 3. CI/CD Module Validation

Check GitHub Actions workflow runs:

- [ ] Workflows appear in Actions tab
- [ ] Runs complete successfully
- [ ] Tasks created in commit-relay
- [ ] Results reported correctly

## Monitoring Setup

### 1. ML Model Monitoring

Set up periodic retraining:

```python
# Retrain weekly
from apscheduler.schedulers.blocking import BlockingScheduler

scheduler = BlockingScheduler()

@scheduler.scheduled_job('cron', day_of_week='sun', hour=2)
def retrain_model():
    predictor = TaskFailurePredictor(client, manager)
    predictor.train()
    print("Model retrained")

scheduler.start()
```

- [ ] Retraining scheduled
- [ ] Model updates automated

### 2. Anomaly Detection Monitoring

Set up continuous anomaly checking:

```python
# Check every 5 minutes
import time

while True:
    anomalies = detector.detect_all_metrics()
    for metric, result in anomalies.items():
        if result.get('is_anomalous'):
            # Send alert
            print(f"ALERT: {result['message']}")
    time.sleep(300)
```

- [ ] Anomaly monitoring active
- [ ] Alerts configured

### 3. Discovery Automation

Set up periodic repository scanning:

```python
# Scan daily
@scheduler.scheduled_job('cron', hour=3)
def scan_repositories():
    repos = discovery.discover_organization_repos('your-org')
    # Process new repos
    print(f"Found {len(repos)} repos")
```

- [ ] Scanning scheduled
- [ ] New repos detected

## Rollback Plan

If issues arise:

### 1. Disable ML Features

```python
# Stop using predictor
# Fall back to manual prioritization
```

### 2. Disable Discovery

```python
# Stop scheduled scans
# Manual repository onboarding
```

### 3. Disable CI/CD Integration

```bash
# Disable workflows in GitHub
# Remove or comment out workflow files
```

## Success Criteria

### ML Module
- [ ] Model trains successfully
- [ ] Predictions are accurate (validate manually)
- [ ] Anomaly detection finds real issues
- [ ] Task prioritization is logical

### Discovery Module
- [ ] All repositories discovered
- [ ] Health scores reasonable
- [ ] Tasks created successfully
- [ ] No API errors or rate limits

### CI/CD Module
- [ ] Workflows run on triggers
- [ ] Tasks created correctly
- [ ] Results reported accurately
- [ ] Build failures work correctly

## Troubleshooting

### Issue: Model training fails
**Solution:** Check historical task data exists (need 20+ tasks)

### Issue: GitHub API errors
**Solution:** Verify token permissions and rate limits

### Issue: Workflow fails
**Solution:** Check GitHub Actions logs, verify secrets

### Issue: Tasks not created
**Solution:** Verify commit-relay backend accessible

## Documentation References

- [Quick Start Guide](QUICK_START_STRATEGIC_MODULES.md)
- [ML Insights Guide](ML_INSIGHTS_GUIDE.md)
- [Integrations Guide](INTEGRATIONS_GUIDE.md)
- [Architecture Guide](ARCHITECTURE_STRATEGIC_MODULES.md)
- [Implementation Report](IMPLEMENTATION_REPORT_STRATEGIC_MODULES.md)

## Sign-Off

- [ ] All tests passed
- [ ] Validation successful
- [ ] Monitoring configured
- [ ] Documentation reviewed
- [ ] Team trained

**Deployed by:** ___________________
**Date:** ___________________
**Verified by:** ___________________
**Date:** ___________________

---

**Status:** Ready for Production Deployment
