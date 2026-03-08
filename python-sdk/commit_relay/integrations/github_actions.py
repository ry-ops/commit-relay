"""
GitHub Actions CI/CD pipeline integration.
"""

import os
import sys
from typing import Dict, Optional


class GitHubActionsTrigger:
    """
    Trigger commit-relay tasks from GitHub Actions.

    Example GitHub Action workflow:

    ```yaml
    name: Security Scan
    on: [push, pull_request]

    jobs:
      security:
        runs-on: ubuntu-latest
        steps:
          - uses: actions/checkout@v2
          - name: Run Security Scan
            run: |
              pip install commit-relay-client
              python .github/scripts/security-scan.py
            env:
              GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
    ```

    Usage in Python:
        trigger = GitHubActionsTrigger(manager)

        # From GitHub Actions environment
        success = trigger.run_security_scan_and_wait()

        if not success:
            sys.exit(1)  # Fail the build
    """

    def __init__(self, task_manager):
        self.manager = task_manager

        # GitHub Actions environment variables
        self.repository = os.environ.get('GITHUB_REPOSITORY', '')
        self.ref = os.environ.get('GITHUB_REF', '')
        self.event_name = os.environ.get('GITHUB_EVENT_NAME', '')
        self.sha = os.environ.get('GITHUB_SHA', '')
        self.workflow = os.environ.get('GITHUB_WORKFLOW', '')

    def run_security_scan_and_wait(self,
                                   timeout: int = 600,
                                   fail_on_vulnerabilities: bool = True) -> bool:
        """
        Run security scan and wait for completion.

        Args:
            timeout: Maximum wait time in seconds
            fail_on_vulnerabilities: Fail if vulnerabilities found

        Returns:
            True if scan passed, False otherwise
        """
        from ..orchestration.execution_monitor import ExecutionMonitor

        print("🔒 Running security scan...")
        print(f"   Repository: {self.repository}")
        print(f"   Branch: {self._get_branch()}")
        print(f"   Event: {self.event_name}")

        # Create security scan task
        task_id = self.manager.create_security_scan(
            repository=self.repository,
            branch=self._get_branch(),
            description=f"CI/CD scan - {self.workflow}",
            priority='critical'
        )

        print(f"   Task ID: {task_id}")

        # Monitor execution
        monitor = ExecutionMonitor(self.manager)

        try:
            final_task = monitor.wait_for_completion(task_id, timeout=timeout)

            if final_task['status'] == 'completed':
                results = final_task.get('results', {})
                vulnerabilities = results.get('vulnerabilities', 0)

                print(f"\n✅ Security scan completed")
                print(f"   Vulnerabilities: {vulnerabilities}")
                print(f"   Risk Level: {results.get('risk_level', 'UNKNOWN')}")

                if fail_on_vulnerabilities and vulnerabilities > 0:
                    print(f"\n❌ Build failed: {vulnerabilities} vulnerabilities found")
                    return False

                return True
            else:
                print(f"\n❌ Security scan failed")
                return False

        except Exception as e:
            print(f"\n❌ Error: {e}")
            return False

    def create_pr_review_task(self, pr_number: int) -> str:
        """
        Create development task for PR review.

        Args:
            pr_number: Pull request number

        Returns:
            task_id
        """
        task_id = self.manager.create_development_task(
            repository=self.repository,
            branch=self._get_branch(),
            requirements=[f"Review PR #{pr_number}"],
            description=f"Review PR #{pr_number} - {self.workflow}",
            priority='high'
        )

        print(f"📝 Created PR review task: {task_id}")
        return task_id

    def _get_branch(self) -> str:
        """Extract branch name from GITHUB_REF."""
        ref = self.ref
        if ref.startswith('refs/heads/'):
            return ref.replace('refs/heads/', '')
        elif ref.startswith('refs/pull/'):
            return 'pr-' + ref.split('/')[2]
        else:
            return 'main'


class GitHubActionsReporter:
    """
    Report commit-relay results back to GitHub Actions.

    Example:
        reporter = GitHubActionsReporter()
        reporter.set_output('task_id', task_id)
        reporter.add_summary('## Security Scan Results\\n\\nNo vulnerabilities found')
    """

    def __init__(self):
        self.github_output = os.environ.get('GITHUB_OUTPUT', '')
        self.github_step_summary = os.environ.get('GITHUB_STEP_SUMMARY', '')

    def set_output(self, name: str, value: str):
        """Set GitHub Actions output variable."""
        if self.github_output:
            with open(self.github_output, 'a') as f:
                f.write(f"{name}={value}\n")

    def add_summary(self, markdown: str):
        """Add to GitHub Actions step summary."""
        if self.github_step_summary:
            with open(self.github_step_summary, 'a') as f:
                f.write(markdown + '\n')

    def create_task_summary(self, task: Dict):
        """Create formatted summary for a task."""
        summary = f"""
## Commit-Relay Task: {task['id']}

**Status:** {task['status']}
**Type:** {task['type']}
**Priority:** {task['priority']}
**Repository:** {task.get('context', {}).get('repository', 'N/A')}

"""
        if task.get('results'):
            summary += "\n### Results\n\n"
            for key, value in task['results'].items():
                summary += f"- **{key}:** {value}\n"

        self.add_summary(summary)
