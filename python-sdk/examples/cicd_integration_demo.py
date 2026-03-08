#!/usr/bin/env python3
"""
CI/CD Integration Demo

This shows how to use commit-relay from GitHub Actions or other CI/CD.
"""

import os
import sys
from commit_relay import TaskManager, GitHubActionsTrigger, GitHubActionsReporter

manager = TaskManager()

print("=" * 60)
print("CI/CD INTEGRATION DEMO")
print("=" * 60)

# Simulate GitHub Actions environment
os.environ['GITHUB_REPOSITORY'] = 'ry-ops/test-repo'
os.environ['GITHUB_REF'] = 'refs/heads/main'
os.environ['GITHUB_EVENT_NAME'] = 'push'
os.environ['GITHUB_WORKFLOW'] = 'Security Scan'

# 1. Initialize trigger
print("\n1. Initializing CI/CD Trigger...")
trigger = GitHubActionsTrigger(manager)
reporter = GitHubActionsReporter()

print(f"   Repository: {trigger.repository}")
print(f"   Branch: {trigger._get_branch()}")
print(f"   Event: {trigger.event_name}")

# 2. Run security scan (dry run)
print("\n2. Security Scan Workflow:")
print("   Would create security scan task and wait for completion")
print("   If vulnerabilities found, would fail the build")

# In real CI/CD:
# success = trigger.run_security_scan_and_wait(timeout=600)
# if not success:
#     sys.exit(1)

# 3. Report results
print("\n3. Reporting Results:")
print("   Would set GitHub Actions outputs:")
print("     - task_id")
print("     - status")
print("     - vulnerabilities_found")

print("\n" + "=" * 60)
print("See examples/ directory for full GitHub Actions workflow YAML")
print("=" * 60)
