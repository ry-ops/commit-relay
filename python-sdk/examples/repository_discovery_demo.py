#!/usr/bin/env python3
"""
Automated Repository Discovery Demo
"""

import os
from github import Github
from commit_relay import TaskManager, GitHubDiscoveryService

# Initialize
github_token = os.environ.get('GITHUB_TOKEN')
if not github_token:
    print("Error: GITHUB_TOKEN environment variable not set")
    exit(1)

gh = Github(github_token)
manager = TaskManager()
discovery = GitHubDiscoveryService(gh, manager)

print("=" * 60)
print("REPOSITORY DISCOVERY & ONBOARDING")
print("=" * 60)

org_name = 'ry-ops'

# 1. Discover repositories
print(f"\n1. Discovering repositories in {org_name}...")
repos = discovery.discover_organization_repos(org_name)

print(f"\nFound {len(repos)} repositories:")
for repo in repos[:5]:
    print(f"  - {repo['full_name']} ({repo['language'] or 'N/A'})")

# 2. Calculate health scores
print(f"\n2. Repository Health Scores:")
for repo in repos[:5]:
    health = discovery.get_repository_health_score(repo)
    print(f"  {repo['name']}: Grade {health['grade']} ({health['score']}/100)")

# 3. Onboard a repository (example - commented out)
print(f"\n3. Onboarding Example (dry run):")
if repos:
    example_repo = repos[0]
    print(f"  Would onboard: {example_repo['full_name']}")
    print(f"  Tasks to create:")
    print(f"    - Catalog task")
    print(f"    - Security scan task")

    # Uncomment to actually onboard:
    # task_ids = discovery.onboard_repository(example_repo)
    # print(f"  Tasks created: {task_ids}")

print("\n" + "=" * 60)
