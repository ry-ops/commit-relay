"""
Git Operations resource client for commit-relay API.

Provides access to git-related operations and repository information.
"""

from typing import Dict, Any, List, Optional


class GitOps:
    """
    Client for git operations API endpoints.

    Example:
        >>> client = CommitRelayClient()
        >>> status = client.git_ops.get_status()
        >>> branches = client.git_ops.list_branches()
        >>> commits = client.git_ops.get_recent_commits(count=10)
    """

    def __init__(self, client):
        """
        Initialize GitOps client.

        Args:
            client: Parent CommitRelayClient instance
        """
        self.client = client

    def get_status(self) -> Dict[str, Any]:
        """
        Get git repository status.

        Returns:
            Git status information including branch, staged files, etc.
        """
        return self.client.get('/api/git/status')

    def list_branches(self) -> List[str]:
        """
        List all git branches.

        Returns:
            List of branch names
        """
        result = self.client.get('/api/git/branches')

        if isinstance(result, list):
            return result
        elif isinstance(result, dict) and 'branches' in result:
            return result['branches']
        return []

    def get_current_branch(self) -> str:
        """
        Get current git branch name.

        Returns:
            Current branch name
        """
        status = self.get_status()
        return status.get('branch', 'unknown')

    def get_recent_commits(self, count: int = 10, branch: Optional[str] = None) -> List[Dict[str, Any]]:
        """
        Get recent commits.

        Args:
            count: Number of commits to retrieve
            branch: Optional branch name (default: current branch)

        Returns:
            List of commit information dictionaries
        """
        params = {'count': count}
        if branch:
            params['branch'] = branch

        result = self.client.get('/api/git/commits', params=params)

        if isinstance(result, list):
            return result
        elif isinstance(result, dict) and 'commits' in result:
            return result['commits']
        return []

    def get_diff(self, commit1: str = None, commit2: str = None) -> str:
        """
        Get git diff.

        Args:
            commit1: First commit (optional)
            commit2: Second commit (optional)

        Returns:
            Diff output as string
        """
        params = {}
        if commit1:
            params['commit1'] = commit1
        if commit2:
            params['commit2'] = commit2

        result = self.client.get('/api/git/diff', params=params)

        if isinstance(result, dict) and 'diff' in result:
            return result['diff']
        return str(result)

    def get_uncommitted_changes(self) -> List[str]:
        """
        Get list of uncommitted changes.

        Returns:
            List of modified files
        """
        status = self.get_status()
        return status.get('uncommitted_changes', [])

    def to_dataframe(self, count: int = 100, branch: Optional[str] = None):
        """
        Export commit history to pandas DataFrame.

        Args:
            count: Number of commits to export
            branch: Optional branch name

        Returns:
            pandas.DataFrame with commit history
        """
        try:
            import pandas as pd
        except ImportError:
            raise ImportError("pandas required. Install with: pip install pandas")

        commits = self.get_recent_commits(count=count, branch=branch)

        if not commits:
            return pd.DataFrame()

        df = pd.DataFrame(commits)

        if 'date' in df.columns:
            df['date'] = pd.to_datetime(df['date'], errors='coerce')

        return df
