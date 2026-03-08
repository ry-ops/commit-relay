# Architecture: Strategic Modules

Visual architecture and design overview of the ML, Discovery, and CI/CD modules.

## Module Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     Commit-Relay Python SDK                      │
├─────────────────────────────────────────────────────────────────┤
│                                                                   │
│  ┌───────────────────┐  ┌───────────────────┐  ┌─────────────┐ │
│  │   ML Module       │  │  Integrations     │  │  Core SDK   │ │
│  │                   │  │                   │  │             │ │
│  │ ┌───────────────┐ │  │ ┌───────────────┐ │  │ • Client    │ │
│  │ │ Task Failure  │ │  │ │ GitHub        │ │  │ • Resources │ │
│  │ │ Predictor     │ │  │ │ Discovery     │ │  │ • Analytics │ │
│  │ └───────────────┘ │  │ └───────────────┘ │  │ • Reporting │ │
│  │                   │  │                   │  │             │ │
│  │ ┌───────────────┐ │  │ ┌───────────────┐ │  └─────────────┘ │
│  │ │ Metrics       │ │  │ │ GitHub        │ │                   │
│  │ │ Anomaly       │ │  │ │ Actions       │ │                   │
│  │ │ Detector      │ │  │ │ Trigger       │ │                   │
│  │ └───────────────┘ │  │ └───────────────┘ │                   │
│  │                   │  │                   │                   │
│  │ ┌───────────────┐ │  │ ┌───────────────┐ │                   │
│  │ │ Smart Task    │ │  │ │ GitHub        │ │                   │
│  │ │ Prioritizer   │ │  │ │ Actions       │ │                   │
│  │ │               │ │  │ │ Reporter      │ │                   │
│  │ └───────────────┘ │  │ └───────────────┘ │                   │
│  └───────────────────┘  └───────────────────┘                   │
│                                                                   │
└─────────────────────────────────────────────────────────────────┘
```

## Data Flow

### ML Insights Flow

```
Historical Tasks
    │
    ├──> TaskFailurePredictor
    │       │
    │       ├──> Feature Engineering
    │       │       • Priority encoding
    │       │       • Type scoring
    │       │       • Time features
    │       │
    │       ├──> Training
    │       │       • Failure rate calculation
    │       │       • Feature importance
    │       │
    │       └──> Prediction
    │               • New task → Probability
    │               • Risk level classification
    │
    ├──> MetricsAnomalyDetector
    │       │
    │       ├──> Statistical Analysis
    │       │       • Mean/std calculation
    │       │       • Z-score computation
    │       │
    │       └──> Anomaly Detection
    │               • Threshold comparison
    │               • Alert generation
    │
    └──> SmartTaskPrioritizer
            │
            ├──> Multi-Factor Scoring
            │       • Priority weight (30%)
            │       • Failure risk (20%)
            │       • Task age (20%)
            │       • Type urgency (30%)
            │
            └──> Ranked Task List
                    • Sorted by score
                    • Top tasks first
```

### Repository Discovery Flow

```
GitHub Organization
    │
    ├──> GitHubDiscoveryService.discover_organization_repos()
    │       │
    │       ├──> API Query
    │       │       • Get all repos
    │       │       • Filter archived/forks
    │       │
    │       ├──> Data Extraction
    │       │       • Metadata
    │       │       • Metrics
    │       │       • Configuration
    │       │
    │       └──> Repository List
    │
    ├──> Health Score Calculation
    │       │
    │       ├──> Activity check
    │       ├──> License check
    │       ├──> Description check
    │       └──> Engagement check
    │               │
    │               └──> Grade (A-F)
    │
    └──> Onboarding
            │
            ├──> Create Catalog Task
            │       • Repository inventory
            │
            ├──> Create Security Scan Task
            │       • Vulnerability baseline
            │
            └──> Task IDs
                    • Tracking reference
```

### CI/CD Integration Flow

```
GitHub Actions Event
    │
    ├──> Environment Variables
    │       • GITHUB_REPOSITORY
    │       • GITHUB_REF
    │       • GITHUB_EVENT_NAME
    │       • GITHUB_SHA
    │
    ├──> GitHubActionsTrigger
    │       │
    │       ├──> Create Task
    │       │       • Security scan
    │       │       • PR review
    │       │
    │       ├──> Wait for Completion
    │       │       • Poll status
    │       │       • Timeout handling
    │       │
    │       └──> Result
    │               • Success/failure
    │               • Vulnerability count
    │
    └──> GitHubActionsReporter
            │
            ├──> Set Outputs
            │       • task_id
            │       • status
            │
            ├──> Add Summary
            │       • Markdown report
            │
            └──> Build Status
                    • Pass/fail
```

## Component Interactions

### ML Module Interactions

```
┌─────────────────────┐
│ TaskManager         │
│ • get_all_tasks()   │
│ • get_pending()     │
└──────────┬──────────┘
           │
           ├──> TaskFailurePredictor
           │    • Train on historical
           │    • Predict for new
           │
           └──> SmartTaskPrioritizer
                • Get pending tasks
                • Rank by score

┌─────────────────────┐
│ CommitRelayClient   │
│ • metrics API       │
└──────────┬──────────┘
           │
           └──> MetricsAnomalyDetector
                • Fetch metrics
                • Detect anomalies
```

### Integration Module Interactions

```
┌─────────────────────┐        ┌─────────────────────┐
│ PyGithub            │        │ TaskManager         │
│ • Organization API  │        │ • create_catalog()  │
│ • Repository API    │        │ • create_security() │
└──────────┬──────────┘        └──────────┬──────────┘
           │                              │
           └──────────┬───────────────────┘
                      │
                      ├──> GitHubDiscoveryService
                      │    • Discover repos
                      │    • Create tasks

┌─────────────────────┐
│ GitHub Actions Env  │
│ • GITHUB_*          │
└──────────┬──────────┘
           │
           ├──> GitHubActionsTrigger
           │    • Parse environment
           │    • Create tasks
           │    • Wait for results
           │
           └──> GitHubActionsReporter
                • Set outputs
                • Write summaries
```

## Deployment Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         Production Environment                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                   │
│  ┌─────────────────┐         ┌─────────────────┐               │
│  │ Commit-Relay    │         │ Python SDK      │               │
│  │ Backend         │◄────────┤ Client          │               │
│  │ • API Server    │ HTTP    │ • ML Module     │               │
│  │ • Task Queue    │         │ • Integrations  │               │
│  └────────┬────────┘         └────────┬────────┘               │
│           │                           │                          │
│  ┌────────▼────────┐         ┌────────▼────────┐               │
│  │ Worker Agents   │         │ GitHub API      │               │
│  │ • Dev workers   │         │ • Repos         │               │
│  │ • Sec workers   │         │ • Organizations │               │
│  │ • Inv workers   │         │ • Actions       │               │
│  └─────────────────┘         └─────────────────┘               │
│                                                                   │
│  ┌─────────────────────────────────────────────────────┐        │
│  │ GitHub Actions Runners                              │        │
│  │                                                       │        │
│  │  ┌───────────────┐  ┌───────────────┐              │        │
│  │  │ Security Scan │  │ PR Review     │              │        │
│  │  │ Workflow      │  │ Workflow      │              │        │
│  │  └───────────────┘  └───────────────┘              │        │
│  └─────────────────────────────────────────────────────┘        │
│                                                                   │
└─────────────────────────────────────────────────────────────────┘
```

## State Management

### ML Model Persistence

```
Training:
  Tasks → Features → Model → Disk (pickle)

Loading:
  Disk → Model → Memory

Prediction:
  New Task → Features → Model → Probability
```

**Storage:**
```
/Users/ryandahlberg/commit-relay/python-sdk/models/
└── task_failure_model.pkl
```

### Repository Tracking

```
Discovery:
  GitHub API → Repository List → Onboarding

Tracking:
  tracked_repos.json (optional)
  └── Set of onboarded repositories

Continuous:
  Poll → Filter new → Onboard → Update tracking
```

## Security Architecture

### Token Management

```
Environment Variables
    │
    ├──> GITHUB_TOKEN
    │    • Repository access
    │    • Organization read
    │    • Actions write
    │
    └──> GitHub Actions Secrets
         • Automatic injection
         • No exposure in logs
```

### Data Flow Security

```
Public Data:
  • Repository metadata
  • Metrics (aggregated)
  • Task statuses

Sensitive Data:
  • GitHub tokens (env vars only)
  • API credentials
  • Internal task details

Access Control:
  • Token-based authentication
  • Scoped permissions
  • Rate limiting
```

## Performance Characteristics

### ML Module

| Operation | Time | Memory | Notes |
|-----------|------|--------|-------|
| Training | <1s for 1k tasks | ~10 MB | One-time/periodic |
| Prediction | <1ms per task | ~100 KB | Real-time capable |
| Anomaly Detection | ~100ms | ~5 MB | Per metric check |
| Prioritization | ~50ms | ~2 MB | For 100 tasks |

### Discovery Service

| Operation | Time | Memory | Notes |
|-----------|------|--------|-------|
| Org Discovery | ~1s per repo | ~1 MB per repo | API limited |
| Onboarding | ~500ms | ~100 KB | Task creation |
| Health Scoring | ~10ms | ~10 KB | Computation only |

### CI/CD Integration

| Operation | Time | Memory | Notes |
|-----------|------|--------|-------|
| Task Creation | ~200ms | ~100 KB | API call |
| Status Poll | ~100ms | ~50 KB | Per check |
| Result Reporting | ~50ms | ~10 KB | GitHub API |

## Scalability Considerations

### Horizontal Scaling

```
Multiple SDK Instances
    │
    ├──> Shared ML Models
    │    • Model replication
    │    • Periodic retraining
    │
    ├──> Independent Discovery
    │    • Organization partitioning
    │    • Rate limit awareness
    │
    └──> Parallel CI/CD
         • Concurrent workflows
         • Task queue balancing
```

### Vertical Scaling

- **ML Training:** More tasks = better predictions
- **Discovery:** More repos = wider coverage
- **CI/CD:** More workers = faster execution

## Error Handling

```
┌─────────────────┐
│ API Call        │
└────────┬────────┘
         │
    Success?
         ├──No──> Retry Logic
         │         • Exponential backoff
         │         • Max attempts
         │         └──> Error logging
         │
         └──Yes──> Process Result
                   • Validate data
                   • Handle edge cases
                   └──> Return success
```

## Monitoring Integration

```
ML Module
    ├──> Prediction accuracy tracking
    ├──> Model drift detection
    └──> Feature importance logs

Discovery Service
    ├──> Repository count metrics
    ├──> Onboarding success rate
    └──> Health score distribution

CI/CD Integration
    ├──> Task success rate
    ├──> Execution time tracking
    └──> Build failure analysis
```

## Extension Points

### Custom ML Features

```python
class CustomPredictor(TaskFailurePredictor):
    def _prepare_features(self, tasks):
        df = super()._prepare_features(tasks)
        # Add custom features
        df['custom_score'] = self._calculate_custom()
        return df
```

### Additional Integrations

```python
class GitLabDiscoveryService(BaseDiscoveryService):
    """GitLab repository discovery"""
    pass

class JenkinsTrigger(BaseCITrigger):
    """Jenkins CI/CD integration"""
    pass
```

### Custom Workflows

```yaml
# GitHub Actions - Custom workflow
name: Custom Analysis
on: [push]
jobs:
  analyze:
    steps:
      - name: Custom ML Analysis
        run: |
          python custom_ml_analysis.py
```

## Design Principles

1. **Modularity:** Clear separation of concerns
2. **Extensibility:** Easy to add new features
3. **Simplicity:** Minimal dependencies
4. **Compatibility:** Works with existing SDK
5. **Performance:** Optimized for real-time use
6. **Security:** Token safety, data privacy
7. **Documentation:** Comprehensive guides

## Technology Stack

```
Languages:
  • Python 3.9+

Core Dependencies:
  • pandas (data processing)
  • numpy (numerical operations)
  • requests (HTTP client)

Integration Dependencies:
  • PyGithub (GitHub API)

Optional Dependencies:
  • matplotlib (visualization)
  • seaborn (plotting)
```

## Future Architecture

### Planned Enhancements

```
┌─────────────────────────────────────────────────────────────────┐
│                         Future Architecture                      │
├─────────────────────────────────────────────────────────────────┤
│                                                                   │
│  Current Modules          Planned Additions                      │
│                                                                   │
│  • ML Module      ───┐    • Advanced ML Models                  │
│  • Integrations   ───┼───>• Multi-Platform Support              │
│  • CI/CD          ───┘    • Real-time Learning                  │
│                           • Distributed Training                 │
│                                                                   │
└─────────────────────────────────────────────────────────────────┘
```

## Summary

The strategic modules architecture provides:

- **Intelligent Automation:** ML-powered insights
- **Seamless Integration:** GitHub and CI/CD support
- **Scalable Design:** Handles growth efficiently
- **Extensible Framework:** Easy to enhance
- **Production Ready:** Tested and documented

All components follow best practices for enterprise Python development and integrate seamlessly with the existing commit-relay ecosystem.
