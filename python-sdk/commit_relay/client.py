"""
Core client for the Commit-Relay Python SDK.

This module provides the main CommitRelayClient class, which serves as the
entry point for interacting with the commit-relay dashboard API.
"""

from typing import Optional, Dict, Any, Union
import requests
from urllib.parse import urljoin

from .exceptions import (
    APIError,
    ConnectionError,
    ResourceNotFoundError,
    RateLimitError,
    AuthenticationError
)


class CommitRelayClient:
    """
    Main client for interacting with the Commit-Relay Dashboard API.

    This client provides a high-level interface to all commit-relay API endpoints,
    organized into resource-specific sub-clients for better code organization.

    Example:
        Basic usage:

        >>> from commit_relay import CommitRelayClient
        >>> client = CommitRelayClient(base_url='http://localhost:3000')
        >>> workers = client.workers.list()
        >>> metrics = client.metrics.get_current()

        With custom timeout:

        >>> client = CommitRelayClient(
        ...     base_url='http://localhost:3000',
        ...     timeout=60
        ... )

    Attributes:
        base_url (str): Base URL of the commit-relay dashboard API
        timeout (int): Request timeout in seconds
        session (requests.Session): Persistent HTTP session
        workers: Workers resource client
        tasks: Tasks resource client
        metrics: Metrics resource client
        health: Health resource client
        events: Events resource client
        daemons: Daemon control resource client
        git_ops: Git operations resource client
    """

    def __init__(
        self,
        base_url: str = 'http://localhost:3000',
        timeout: int = 30,
        verify_ssl: bool = True
    ):
        """
        Initialize the Commit-Relay API client.

        Args:
            base_url: Base URL of the dashboard API (default: http://localhost:3000)
            timeout: Request timeout in seconds (default: 30)
            verify_ssl: Whether to verify SSL certificates (default: True)
        """
        self.base_url = base_url.rstrip('/')
        self.timeout = timeout
        self.verify_ssl = verify_ssl
        self.session = requests.Session()
        self.session.verify = verify_ssl

        # Lazy load resource clients to avoid circular imports
        self._workers = None
        self._tasks = None
        self._metrics = None
        self._health = None
        self._events = None
        self._daemons = None
        self._git_ops = None

    @property
    def workers(self):
        """Get the Workers resource client."""
        if self._workers is None:
            from .resources.workers import Workers
            self._workers = Workers(self)
        return self._workers

    @property
    def tasks(self):
        """Get the Tasks resource client."""
        if self._tasks is None:
            from .resources.tasks import Tasks
            self._tasks = Tasks(self)
        return self._tasks

    @property
    def metrics(self):
        """Get the Metrics resource client."""
        if self._metrics is None:
            from .resources.metrics import Metrics
            self._metrics = Metrics(self)
        return self._metrics

    @property
    def health(self):
        """Get the Health resource client."""
        if self._health is None:
            from .resources.health import Health
            self._health = Health(self)
        return self._health

    @property
    def events(self):
        """Get the Events resource client."""
        if self._events is None:
            from .resources.events import Events
            self._events = Events(self)
        return self._events

    @property
    def daemons(self):
        """Get the Daemons resource client."""
        if self._daemons is None:
            from .resources.daemons import Daemons
            self._daemons = Daemons(self)
        return self._daemons

    @property
    def git_ops(self):
        """Get the GitOps resource client."""
        if self._git_ops is None:
            from .resources.git_ops import GitOps
            self._git_ops = GitOps(self)
        return self._git_ops

    def _build_url(self, path: str) -> str:
        """
        Build full URL from path.

        Args:
            path: API endpoint path (e.g., '/api/workers')

        Returns:
            Full URL string
        """
        if not path.startswith('/'):
            path = '/' + path
        return urljoin(self.base_url, path)

    def _request(
        self,
        method: str,
        path: str,
        **kwargs
    ) -> Union[Dict[str, Any], list, None]:
        """
        Make HTTP request with error handling.

        Args:
            method: HTTP method (GET, POST, PUT, DELETE, etc.)
            path: API endpoint path
            **kwargs: Additional arguments to pass to requests

        Returns:
            Response data (dict, list, or None)

        Raises:
            ConnectionError: If unable to connect to the API
            APIError: If the API returns an error response
            ResourceNotFoundError: If the resource is not found (404)
            RateLimitError: If rate limit is exceeded (429)
            AuthenticationError: If authentication fails (401)
        """
        url = self._build_url(path)

        # Set default timeout if not provided
        if 'timeout' not in kwargs:
            kwargs['timeout'] = self.timeout

        try:
            response = self.session.request(method, url, **kwargs)

            # Handle specific status codes
            if response.status_code == 401:
                raise AuthenticationError()
            elif response.status_code == 404:
                raise ResourceNotFoundError(
                    resource_type=path.split('/')[-2] if '/' in path else 'Resource',
                    resource_id=path.split('/')[-1] if '/' in path else 'unknown'
                )
            elif response.status_code == 429:
                retry_after = response.headers.get('Retry-After')
                raise RateLimitError(
                    retry_after=int(retry_after) if retry_after else None
                )

            # Raise for other HTTP errors
            response.raise_for_status()

            # Handle empty responses
            if response.status_code == 204 or not response.content:
                return None

            # Parse JSON response
            try:
                return response.json()
            except ValueError:
                # If response is not JSON, return text
                return {'data': response.text}

        except requests.exceptions.Timeout as e:
            raise ConnectionError(f"Request timeout after {self.timeout}s: {url}") from e
        except requests.exceptions.ConnectionError as e:
            raise ConnectionError(f"Failed to connect to API: {url}") from e
        except requests.exceptions.RequestException as e:
            # Check if we already raised a custom exception
            if isinstance(e, (AuthenticationError, ResourceNotFoundError, RateLimitError)):
                raise

            # Otherwise wrap in APIError
            status_code = e.response.status_code if hasattr(e, 'response') and e.response else None
            response_data = None

            if hasattr(e, 'response') and e.response is not None:
                try:
                    response_data = e.response.json()
                except ValueError:
                    response_data = {'text': e.response.text}

            raise APIError(
                f"API request failed: {str(e)}",
                status_code=status_code,
                response_data=response_data
            ) from e

    def get(self, path: str, **kwargs) -> Union[Dict[str, Any], list, None]:
        """
        Make GET request.

        Args:
            path: API endpoint path
            **kwargs: Additional arguments (params, headers, etc.)

        Returns:
            Response data
        """
        return self._request('GET', path, **kwargs)

    def post(self, path: str, **kwargs) -> Union[Dict[str, Any], list, None]:
        """
        Make POST request.

        Args:
            path: API endpoint path
            **kwargs: Additional arguments (json, data, headers, etc.)

        Returns:
            Response data
        """
        return self._request('POST', path, **kwargs)

    def put(self, path: str, **kwargs) -> Union[Dict[str, Any], list, None]:
        """
        Make PUT request.

        Args:
            path: API endpoint path
            **kwargs: Additional arguments (json, data, headers, etc.)

        Returns:
            Response data
        """
        return self._request('PUT', path, **kwargs)

    def delete(self, path: str, **kwargs) -> Union[Dict[str, Any], list, None]:
        """
        Make DELETE request.

        Args:
            path: API endpoint path
            **kwargs: Additional arguments (headers, etc.)

        Returns:
            Response data
        """
        return self._request('DELETE', path, **kwargs)

    def ping(self) -> bool:
        """
        Test connectivity to the dashboard API.

        Returns:
            True if API is reachable, False otherwise
        """
        try:
            self.get('/api/health')
            return True
        except (ConnectionError, APIError):
            return False

    def close(self):
        """Close the HTTP session."""
        self.session.close()

    def __enter__(self):
        """Context manager entry."""
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        """Context manager exit."""
        self.close()
        return False
