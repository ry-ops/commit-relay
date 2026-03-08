"""
Daemons resource client for commit-relay API.

Provides control over daemon processes including starting, stopping,
and monitoring daemon status.
"""

from typing import Dict, Any, List


class Daemons:
    """
    Client for daemon control API endpoints.

    Example:
        >>> client = CommitRelayClient()
        >>> status = client.daemons.get_status()
        >>> client.daemons.start('worker-daemon')
        >>> client.daemons.stop('worker-daemon')
    """

    def __init__(self, client):
        """
        Initialize Daemons client.

        Args:
            client: Parent CommitRelayClient instance
        """
        self.client = client

    def get_status(self, daemon_name: str = None) -> Dict[str, Any]:
        """
        Get daemon status.

        Args:
            daemon_name: Optional specific daemon name

        Returns:
            Daemon status information
        """
        if daemon_name:
            return self.client.get(f'/api/daemons/{daemon_name}/status')
        else:
            return self.client.get('/api/daemons/status')

    def list(self) -> List[Dict[str, Any]]:
        """
        List all daemons.

        Returns:
            List of daemon information
        """
        result = self.client.get('/api/daemons')

        if isinstance(result, list):
            return result
        elif isinstance(result, dict) and 'daemons' in result:
            return result['daemons']
        return []

    def start(self, daemon_name: str) -> Dict[str, Any]:
        """
        Start a daemon.

        Args:
            daemon_name: Name of daemon to start

        Returns:
            Result of start operation
        """
        return self.client.post(f'/api/daemons/{daemon_name}/start')

    def stop(self, daemon_name: str) -> Dict[str, Any]:
        """
        Stop a daemon.

        Args:
            daemon_name: Name of daemon to stop

        Returns:
            Result of stop operation
        """
        return self.client.post(f'/api/daemons/{daemon_name}/stop')

    def restart(self, daemon_name: str) -> Dict[str, Any]:
        """
        Restart a daemon.

        Args:
            daemon_name: Name of daemon to restart

        Returns:
            Result of restart operation
        """
        return self.client.post(f'/api/daemons/{daemon_name}/restart')

    def is_running(self, daemon_name: str) -> bool:
        """
        Check if daemon is running.

        Args:
            daemon_name: Name of daemon to check

        Returns:
            True if running, False otherwise
        """
        try:
            status = self.get_status(daemon_name)
            return status.get('status') == 'running'
        except Exception:
            return False
