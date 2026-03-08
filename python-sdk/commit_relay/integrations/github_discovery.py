"""
Automated GitHub repository discovery and onboarding.
"""

from typing import List, Dict, Optional
import os
from datetime import datetime


class GitHubDiscoveryService:
    """
    Discover and onboard GitHub repositories automatically.

    Example:
        # Requires: pip install PyGithub
        from github import Github

        gh = Github(os.environ['GITHUB_TOKEN'])
        discovery = GitHubDiscoveryService(gh, manager)

        # Discover new repos
        new_repos = discovery.discover_organization_repos('ry-ops')

        # Onboard them
        for repo in new_repos:
            discovery.onboard_repository(repo)
    """

    def __init__(self, github_client, task_manager):
        """
        Args:
            github_client: PyGithub Github instance
            task_manager: commit_relay TaskManager instance
        """
        self.gh = github_client
        self.manager = task_manager
        self.catalog_file = '/Users/ryandahlberg/commit-relay/data/repository-catalog.json'

    def discover_organization_repos(self, org_name: str,
                                   exclude_archived: bool = True,
                                   exclude_forks: bool = True) -> List[Dict]:
        """
        Discover all repositories in a GitHub organization.

        Args:
            org_name: GitHub organization name
            exclude_archived: Skip archived repos
            exclude_forks: Skip forked repos

        Returns:
            List of repository info dicts
        """
        print(f"Discovering repositories in {org_name}...")

        org = self.gh.get_organization(org_name)
        repos = []

        for repo in org.get_repos():
            # Apply filters
            if exclude_archived and repo.archived:
                continue
            if exclude_forks and repo.fork:
                continue

            repo_info = {
                'full_name': repo.full_name,
                'name': repo.name,
                'description': repo.description or '',
                'language': repo.language,
                'stars': repo.stargazers_count,
                'forks': repo.forks_count,
                'is_private': repo.private,
                'default_branch': repo.default_branch,
                'created_at': repo.created_at.isoformat(),
                'updated_at': repo.updated_at.isoformat(),
                'topics': repo.get_topics(),
                'has_issues': repo.has_issues,
                'has_wiki': repo.has_wiki,
                'license': repo.license.name if repo.license else None
            }

            repos.append(repo_info)

        print(f"Found {len(repos)} repositories")
        return repos

    def onboard_repository(self, repo_info: Dict,
                          run_security_scan: bool = True,
                          run_catalog: bool = True) -> Dict[str, str]:
        """
        Onboard a repository into commit-relay.

        Args:
            repo_info: Repository information dict
            run_security_scan: Create initial security scan task
            run_catalog: Create catalog task

        Returns:
            Dict mapping task type to task_id
        """
        full_name = repo_info['full_name']
        print(f"\nOnboarding {full_name}...")

        task_ids = {}

        # Create catalog task
        if run_catalog:
            catalog_id = self.manager.create_catalog_task(
                repository=full_name,
                description=f"Initial catalog: {repo_info['name']}",
                priority='medium'
            )
            task_ids['catalog'] = catalog_id
            print(f"  ✓ Catalog task: {catalog_id}")

        # Create security scan task
        if run_security_scan:
            scan_id = self.manager.create_security_scan(
                repository=full_name,
                branch=repo_info.get('default_branch', 'main'),
                description=f"Initial security baseline: {repo_info['name']}",
                priority='high'
            )
            task_ids['security_scan'] = scan_id
            print(f"  ✓ Security scan task: {scan_id}")

        print(f"  ✓ Onboarding complete")

        return task_ids

    def batch_onboard(self, org_name: str) -> Dict:
        """
        Discover and onboard all repositories in an organization.

        Returns:
            Summary of onboarding results
        """
        repos = self.discover_organization_repos(org_name)

        results = {
            'total_repos': len(repos),
            'onboarded': 0,
            'tasks_created': 0,
            'repositories': []
        }

        for repo in repos:
            task_ids = self.onboard_repository(repo)

            results['onboarded'] += 1
            results['tasks_created'] += len(task_ids)
            results['repositories'].append({
                'full_name': repo['full_name'],
                'tasks': task_ids
            })

        print(f"\n✅ Batch onboarding complete")
        print(f"   Repositories: {results['onboarded']}/{results['total_repos']}")
        print(f"   Tasks created: {results['tasks_created']}")

        return results

    def get_repository_health_score(self, repo_info: Dict) -> Dict:
        """
        Calculate health score for a repository.

        Returns:
            Health score and breakdown
        """
        score = 100
        factors = []

        # Recent activity (within 30 days)
        updated = datetime.fromisoformat(repo_info['updated_at'].replace('Z', ''))
        days_since_update = (datetime.now(updated.tzinfo) - updated).days
        if days_since_update > 90:
            score -= 20
            factors.append(f"Inactive for {days_since_update} days (-20)")

        # Has license
        if not repo_info.get('license'):
            score -= 10
            factors.append("No license (-10)")

        # Has description
        if not repo_info.get('description'):
            score -= 5
            factors.append("No description (-5)")

        # Popular repo (high engagement)
        stars = repo_info.get('stars', 0)
        if stars < 5:
            score -= 5
            factors.append("Low engagement (-5)")

        return {
            'score': max(score, 0),
            'grade': self._score_to_grade(score),
            'factors': factors
        }

    def _score_to_grade(self, score: int) -> str:
        """Convert numeric score to letter grade."""
        if score >= 90:
            return 'A'
        elif score >= 80:
            return 'B'
        elif score >= 70:
            return 'C'
        elif score >= 60:
            return 'D'
        else:
            return 'F'
