#!/usr/bin/env python3
"""
Example: Multi-task Workflow Orchestration

Demonstrates how to orchestrate complex workflows with multiple tasks
that have dependencies on each other.
"""

import sys
from commit_relay import (
    CommitRelayClient,
    TaskManager,
    TaskPriority,
    WorkflowOrchestrator
)


def security_scan_fix_verify_workflow():
    """
    Example workflow: Scan -> Fix -> Verify

    1. Run initial security scan
    2. Apply fixes for discovered vulnerabilities
    3. Run verification scan to ensure fixes worked
    """
    print("=" * 70)
    print("Workflow: Security Scan -> Fix -> Verify")
    print("=" * 70)
    print()

    # Initialize clients
    client = CommitRelayClient()
    manager = TaskManager()

    # Create orchestrator
    orchestrator = WorkflowOrchestrator(client, manager)

    # Define workflow
    print("Building workflow with 3 tasks...")
    print()

    workflow = (orchestrator
        # Task 1: Initial security scan
        .add_task('initial_scan', lambda: manager.create_security_scan(
            repository='ry-ops/test-repo',
            priority=TaskPriority.HIGH,
            scan_types=['dependencies', 'secrets'],
            description='Initial security scan'
        ))

        # Task 2: Apply security fixes (depends on scan)
        .add_task('apply_fixes', lambda: manager.create_security_fix(
            repository='ry-ops/test-repo',
            vulnerabilities=[],  # Would be populated from scan results
            priority=TaskPriority.CRITICAL,
            description='Apply security fixes'
        ), depends_on=['initial_scan'])

        # Task 3: Verification scan (depends on fixes)
        .add_task('verify_fixes', lambda: manager.create_security_scan(
            repository='ry-ops/test-repo',
            priority=TaskPriority.HIGH,
            scan_types=['dependencies', 'secrets'],
            description='Verify security fixes applied'
        ), depends_on=['apply_fixes'])
    )

    print("Workflow structure:")
    print("  initial_scan")
    print("      |")
    print("      v")
    print("  apply_fixes")
    print("      |")
    print("      v")
    print("  verify_fixes")
    print()

    # Execute workflow
    print("Executing workflow...")
    print("(This will poll for task completion every 10 seconds)")
    print()

    task_ids = workflow.execute(
        poll_interval=10,
        timeout_minutes=60,
        fail_fast=True
    )

    print()
    print("Workflow completed successfully!")
    print()
    print("Task IDs:")
    for name, task_id in task_ids.items():
        print(f"  {name}: {task_id}")
    print()


def parallel_repository_scans():
    """
    Example workflow: Scan multiple repositories in parallel

    All scans are independent and can run simultaneously.
    """
    print("=" * 70)
    print("Workflow: Parallel Repository Scans")
    print("=" * 70)
    print()

    # Initialize clients
    client = CommitRelayClient()
    manager = TaskManager()

    # Create orchestrator
    orchestrator = WorkflowOrchestrator(client, manager)

    # Repositories to scan
    repos = [
        'ry-ops/mcp-server-unifi',
        'ry-ops/n8n-mcp-server',
        'ry-ops/commit-relay'
    ]

    print(f"Building workflow to scan {len(repos)} repositories in parallel...")
    print()

    # Add scan task for each repository (no dependencies)
    for repo in repos:
        repo_name = repo.split('/')[1]
        orchestrator.add_task(
            f'scan_{repo_name}',
            lambda r=repo: manager.create_security_scan(
                repository=r,
                priority=TaskPriority.HIGH,
                description=f'Security scan: {r}'
            )
        )

    print("Workflow structure:")
    print("  scan_mcp-server-unifi")
    print("  scan_n8n-mcp-server     (all run in parallel)")
    print("  scan_commit-relay")
    print()

    # Execute workflow
    print("Executing workflow...")
    print()

    task_ids = orchestrator.execute(
        poll_interval=10,
        timeout_minutes=60
    )

    print()
    print("All scans completed!")
    print()
    print("Results:")
    for name, task_id in task_ids.items():
        print(f"  {name}: {task_id}")
    print()


def complex_feature_workflow():
    """
    Example workflow: Complex feature implementation

    1. Create feature branch
    2. Implement core functionality (in parallel with tests)
    3. Run tests
    4. Run security scan
    5. Generate documentation
    6. Create pull request
    """
    print("=" * 70)
    print("Workflow: Complex Feature Implementation")
    print("=" * 70)
    print()

    # Initialize clients
    client = CommitRelayClient()
    manager = TaskManager()

    # Create orchestrator
    orchestrator = WorkflowOrchestrator(client, manager)

    print("Building complex feature workflow...")
    print()

    workflow = (orchestrator
        # Task 1: Implement core feature
        .add_task('implement_core', lambda: manager.create_development_task(
            repository='ry-ops/my-app',
            requirements=['Implement OAuth2 authentication'],
            priority=TaskPriority.HIGH,
            description='Implement OAuth2 core functionality'
        ))

        # Task 2: Write tests (parallel with implementation)
        .add_task('write_tests', lambda: manager.create_development_task(
            repository='ry-ops/my-app',
            requirements=['Write OAuth2 integration tests'],
            priority=TaskPriority.HIGH,
            description='Write OAuth2 tests'
        ))

        # Task 3: Security scan (after implementation)
        .add_task('security_scan', lambda: manager.create_security_scan(
            repository='ry-ops/my-app',
            priority=TaskPriority.HIGH,
            description='Security scan OAuth2 implementation'
        ), depends_on=['implement_core'])

        # Task 4: Generate docs (after implementation)
        .add_task('generate_docs', lambda: manager.create_development_task(
            repository='ry-ops/my-app',
            requirements=['Generate OAuth2 API documentation'],
            priority=TaskPriority.MEDIUM,
            description='Generate OAuth2 documentation'
        ), depends_on=['implement_core'])
    )

    print("Workflow structure:")
    print("  implement_core  write_tests")
    print("      |   |")
    print("      v   v")
    print("  security_scan")
    print("      |")
    print("      v")
    print("  generate_docs")
    print()

    # Execute workflow
    print("Executing workflow...")
    print()

    task_ids = workflow.execute(
        poll_interval=15,
        timeout_minutes=120
    )

    print()
    print("Feature implementation workflow completed!")
    print()


def main():
    """Run workflow demonstrations."""

    print("=" * 70)
    print("Commit-Relay: Workflow Orchestration Demo")
    print("=" * 70)
    print()
    print("This demo shows three workflow patterns:")
    print("  1. Sequential workflow with dependencies")
    print("  2. Parallel workflow (independent tasks)")
    print("  3. Complex workflow with mixed dependencies")
    print()

    # Choose which demo to run
    print("Select workflow to demonstrate:")
    print("  1. Security Scan -> Fix -> Verify (sequential)")
    print("  2. Parallel Repository Scans")
    print("  3. Complex Feature Implementation")
    print("  4. Run all workflows")
    print()

    choice = input("Enter choice (1-4): ").strip()

    if choice == '1':
        security_scan_fix_verify_workflow()
    elif choice == '2':
        parallel_repository_scans()
    elif choice == '3':
        complex_feature_workflow()
    elif choice == '4':
        print()
        security_scan_fix_verify_workflow()
        print("\n\n")
        parallel_repository_scans()
        print("\n\n")
        complex_feature_workflow()
    else:
        print("Invalid choice. Running default workflow...")
        security_scan_fix_verify_workflow()


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        print("\n\nInterrupted by user")
        sys.exit(1)
    except Exception as e:
        print(f"\nError: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc()
        sys.exit(1)
