# Integrations Guide

This guide covers GitHub integrations for automated repository discovery and CI/CD pipeline integration.

## Overview

The integrations module provides:
1. **GitHub Discovery** - Automatically discover and onboard repositories
2. **CI/CD Integration** - Integrate with GitHub Actions and other CI/CD platforms

## GitHub Repository Discovery

### Prerequisites

```bash
pip install PyGithub
export GITHUB_TOKEN="your_github_token"
```

### Basic Usage

```python
import os
from github import Github
from commit_relay import TaskManager, GitHubDiscoveryService

# Initialize
gh = Github(os.environ['GITHUB_TOKEN'])
manager = TaskManager()
discovery = GitHubDiscoveryService(gh, manager)

# Discover repositories in organization
repos = discovery.discover_organization_repos('ry-ops')

# Onboard a repository
for repo in repos:
    task_ids = discovery.onboard_repository(repo)
    print(f"Onboarded {repo['full_name']}: {task_ids}")
```

### Batch Onboarding

Onboard all repositories in an organization at once:

```python
# Discover and onboard all repos
results = discovery.batch_onboard('ry-ops')

print(f"Onboarded: {results['onboarded']}/{results['total_repos']}")
print(f"Tasks created: {results['tasks_created']}")

# Details per repository
for repo in results['repositories']:
    print(f"{repo['full_name']}: {repo['tasks']}")
```

### Repository Filtering

Control which repositories to discover:

```python
repos = discovery.discover_organization_repos(
    org_name='ry-ops',
    exclude_archived=True,   # Skip archived repos
    exclude_forks=True       # Skip forked repos
)
```

### Repository Health Scores

Calculate health scores for repositories:

```python
for repo in repos:
    health = discovery.get_repository_health_score(repo)
    print(f"{repo['name']}: Grade {health['grade']} ({health['score']}/100)")

    # Show factors affecting score
    for factor in health['factors']:
        print(f"  - {factor}")
```

#### Health Score Factors

- **Activity** (-20): Inactive for > 90 days
- **License** (-10): No license specified
- **Description** (-5): No description
- **Engagement** (-5): Low stars (< 5)

**Grade Scale:**
- A: 90-100
- B: 80-89
- C: 70-79
- D: 60-69
- F: < 60

### Onboarding Options

Control what happens during onboarding:

```python
task_ids = discovery.onboard_repository(
    repo_info,
    run_security_scan=True,   # Create security scan task
    run_catalog=True          # Create catalog task
)
```

### Repository Information Extracted

For each repository, the following data is collected:

```python
{
    'full_name': 'ry-ops/test-repo',
    'name': 'test-repo',
    'description': 'A test repository',
    'language': 'Python',
    'stars': 42,
    'forks': 5,
    'is_private': False,
    'default_branch': 'main',
    'created_at': '2024-01-01T00:00:00Z',
    'updated_at': '2024-11-07T00:00:00Z',
    'topics': ['automation', 'python'],
    'has_issues': True,
    'has_wiki': True,
    'license': 'MIT'
}
```

## CI/CD Integration

### GitHub Actions Integration

#### Setup

1. Add commit-relay client to your project
2. Create GitHub Actions workflow
3. Use `GitHubActionsTrigger` to create tasks

#### Security Scan Workflow

Create `.github/workflows/security-scan.yml`:

```yaml
name: Security Scan
on: [push, pull_request]

jobs:
  security:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Set up Python
        uses: actions/setup-python@v4
        with:
          python-version: '3.9'

      - name: Install commit-relay
        run: pip install commit-relay-client

      - name: Run Security Scan
        run: python scripts/security-scan.py
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

#### Python Script (scripts/security-scan.py)

```python
#!/usr/bin/env python3
from commit_relay import TaskManager, GitHubActionsTrigger
import sys

manager = TaskManager()
trigger = GitHubActionsTrigger(manager)

# Run security scan and wait
success = trigger.run_security_scan_and_wait(
    timeout=600,
    fail_on_vulnerabilities=True
)

if not success:
    sys.exit(1)
```

### Environment Variables

The trigger automatically reads GitHub Actions environment variables:

- `GITHUB_REPOSITORY` - Repository name (e.g., 'ry-ops/test-repo')
- `GITHUB_REF` - Branch/PR reference
- `GITHUB_EVENT_NAME` - Event type (push, pull_request, etc.)
- `GITHUB_SHA` - Commit SHA
- `GITHUB_WORKFLOW` - Workflow name

### PR Review Workflow

Automatically create review tasks for pull requests:

```python
from commit_relay import TaskManager, GitHubActionsTrigger

manager = TaskManager()
trigger = GitHubActionsTrigger(manager)

# Create PR review task
pr_number = 123
task_id = trigger.create_pr_review_task(pr_number)

print(f"Created PR review task: {task_id}")
```

### Reporting Results

Use `GitHubActionsReporter` to report results back:

```python
from commit_relay import GitHubActionsReporter

reporter = GitHubActionsReporter()

# Set output variables
reporter.set_output('task_id', task_id)
reporter.set_output('status', 'completed')

# Add to step summary
reporter.add_summary('## Security Scan Results\n\nNo vulnerabilities found')

# Or create formatted task summary
reporter.create_task_summary(task)
```

### Complete CI/CD Example

```python
#!/usr/bin/env python3
"""
Complete CI/CD Integration Example
"""

from commit_relay import (
    TaskManager,
    GitHubActionsTrigger,
    GitHubActionsReporter
)
import sys

def main():
    # Initialize
    manager = TaskManager()
    trigger = GitHubActionsTrigger(manager)
    reporter = GitHubActionsReporter()

    print(f"Running on: {trigger.repository}")
    print(f"Branch: {trigger._get_branch()}")
    print(f"Event: {trigger.event_name}")

    # Run security scan
    task_id = manager.create_security_scan(
        repository=trigger.repository,
        branch=trigger._get_branch(),
        description=f"CI/CD scan - {trigger.workflow}",
        priority='critical'
    )

    # Wait for completion
    from commit_relay import ExecutionMonitor
    monitor = ExecutionMonitor(manager)

    try:
        task = monitor.wait_for_completion(task_id, timeout=600)

        # Report results
        reporter.set_output('task_id', task_id)
        reporter.set_output('status', task['status'])
        reporter.create_task_summary(task)

        # Check for vulnerabilities
        if task['status'] == 'completed':
            vulnerabilities = task.get('results', {}).get('vulnerabilities', 0)
            if vulnerabilities > 0:
                print(f"❌ {vulnerabilities} vulnerabilities found")
                sys.exit(1)
            else:
                print("✅ No vulnerabilities found")
                sys.exit(0)
        else:
            print("❌ Scan failed")
            sys.exit(1)

    except Exception as e:
        print(f"❌ Error: {e}")
        sys.exit(1)

if __name__ == '__main__':
    main()
```

## Advanced Usage

### Custom Organization Scanner

Create a scheduled job to continuously discover new repositories:

```python
#!/usr/bin/env python3
"""
Continuous Repository Discovery
"""

import time
import json
from pathlib import Path
from github import Github
from commit_relay import TaskManager, GitHubDiscoveryService

def load_tracked_repos():
    """Load list of already-tracked repositories."""
    path = Path('tracked_repos.json')
    if path.exists():
        return set(json.loads(path.read_text()))
    return set()

def save_tracked_repos(repos):
    """Save list of tracked repositories."""
    Path('tracked_repos.json').write_text(json.dumps(list(repos)))

def main():
    gh = Github(os.environ['GITHUB_TOKEN'])
    manager = TaskManager()
    discovery = GitHubDiscoveryService(gh, manager)

    tracked = load_tracked_repos()

    # Discover all repos
    all_repos = discovery.discover_organization_repos('ry-ops')

    # Find new repos
    new_repos = [
        repo for repo in all_repos
        if repo['full_name'] not in tracked
    ]

    if new_repos:
        print(f"Found {len(new_repos)} new repositories")

        for repo in new_repos:
            print(f"\nOnboarding {repo['full_name']}...")
            discovery.onboard_repository(repo)
            tracked.add(repo['full_name'])

        save_tracked_repos(tracked)
    else:
        print("No new repositories found")

if __name__ == '__main__':
    main()
```

### Multi-Organization Discovery

Scan multiple organizations:

```python
organizations = ['ry-ops', 'other-org', 'third-org']

for org in organizations:
    print(f"\nScanning {org}...")
    results = discovery.batch_onboard(org)
    print(f"  Onboarded: {results['onboarded']} repos")
    print(f"  Tasks created: {results['tasks_created']}")
```

### Conditional Onboarding

Only onboard repositories meeting certain criteria:

```python
repos = discovery.discover_organization_repos('ry-ops')

for repo in repos:
    health = discovery.get_repository_health_score(repo)

    # Only onboard healthy repositories
    if health['score'] >= 70:
        print(f"Onboarding {repo['name']} (Grade: {health['grade']})")
        discovery.onboard_repository(repo)
    else:
        print(f"Skipping {repo['name']} (Grade: {health['grade']})")
```

## Best Practices

### GitHub Token Permissions

Required scopes:
- `repo` - Full repository access
- `read:org` - Read organization data
- `workflow` - Update workflow files

### Rate Limiting

GitHub API has rate limits (5000 requests/hour for authenticated users):

```python
# Check rate limit
rate_limit = gh.get_rate_limit()
print(f"Remaining: {rate_limit.core.remaining}/{rate_limit.core.limit}")
```

### Error Handling

```python
from github import GithubException

try:
    repos = discovery.discover_organization_repos('ry-ops')
except GithubException as e:
    if e.status == 404:
        print("Organization not found")
    elif e.status == 403:
        print("Rate limit exceeded or permission denied")
    else:
        print(f"GitHub error: {e}")
```

### Onboarding Strategy

1. **Initial bulk onboard**: Onboard all existing repos
2. **Continuous discovery**: Scheduled job to find new repos
3. **Selective onboarding**: Use health scores to prioritize
4. **Manual review**: Review critical repos before onboarding

## Troubleshooting

### Token Issues

```
Error: Bad credentials
```

**Solution**: Check GITHUB_TOKEN environment variable

### Organization Access

```
Error: Organization not found (404)
```

**Solution**: Ensure token has access to organization

### Rate Limiting

```
Error: API rate limit exceeded
```

**Solution**: Wait or use authenticated requests (higher limit)

## Examples

See example scripts:
- `/Users/ryandahlberg/commit-relay/python-sdk/examples/repository_discovery_demo.py`
- `/Users/ryandahlberg/commit-relay/python-sdk/examples/cicd_integration_demo.py`

## API Reference

See inline documentation in:
- `/Users/ryandahlberg/commit-relay/python-sdk/commit_relay/integrations/github_discovery.py`
- `/Users/ryandahlberg/commit-relay/python-sdk/commit_relay/integrations/github_actions.py`
