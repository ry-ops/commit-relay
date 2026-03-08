"""
Health resource client for commit-relay API.

Provides access to system health endpoints and health check utilities.
"""

from typing import Dict, Any, List


class Health:
    """
    Client for health-related API endpoints.

    Example:
        >>> client = CommitRelayClient()
        >>> status = client.health.get_status()
        >>> is_healthy = client.health.is_healthy()
    """

    def __init__(self, client):
        """
        Initialize Health client.

        Args:
            client: Parent CommitRelayClient instance
        """
        self.client = client

    def get_status(self) -> Dict[str, Any]:
        """
        Get overall system health status.

        Returns:
            Dictionary containing health status information
        """
        return self.client.get('/api/health')

    def is_healthy(self) -> bool:
        """
        Check if system is healthy.

        Returns:
            True if system is healthy, False otherwise
        """
        try:
            status = self.get_status()
            return status.get('status') == 'healthy'
        except Exception:
            return False

    def get_component_health(self) -> Dict[str, Any]:
        """
        Get health status of individual components.

        Returns:
            Dictionary with component-level health information
        """
        status = self.get_status()
        return status.get('components', {})

    def ping(self) -> bool:
        """
        Simple ping to check API availability.

        Returns:
            True if API responds, False otherwise
        """
        return self.client.ping()
