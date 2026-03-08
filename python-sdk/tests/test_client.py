"""
Tests for commit_relay client module.
"""

import pytest
from commit_relay import CommitRelayClient, CommitRelayError, APIError, ConnectionError


class TestCommitRelayClient:
    """Tests for CommitRelayClient class."""

    def test_client_initialization(self):
        """Test client can be initialized."""
        client = CommitRelayClient(base_url='http://localhost:3000')
        assert client.base_url == 'http://localhost:3000'
        assert client.timeout == 30

    def test_client_custom_timeout(self):
        """Test client can be initialized with custom timeout."""
        client = CommitRelayClient(timeout=60)
        assert client.timeout == 60

    def test_client_context_manager(self):
        """Test client can be used as context manager."""
        with CommitRelayClient() as client:
            assert client is not None

    def test_url_building(self):
        """Test URL building."""
        client = CommitRelayClient(base_url='http://localhost:3000')
        url = client._build_url('/api/metrics')
        assert url == 'http://localhost:3000/api/metrics'

    def test_url_building_without_leading_slash(self):
        """Test URL building without leading slash."""
        client = CommitRelayClient(base_url='http://localhost:3000')
        url = client._build_url('api/metrics')
        assert url == 'http://localhost:3000/api/metrics'

    def test_resource_clients_lazy_initialization(self):
        """Test resource clients are lazily initialized."""
        client = CommitRelayClient()
        assert client._workers is None
        assert client._tasks is None

        # Access workers should initialize it
        workers = client.workers
        assert client._workers is not None
        assert workers == client.workers  # Should return same instance


class TestExceptionHandling:
    """Tests for exception handling."""

    def test_base_exception(self):
        """Test base exception can be raised."""
        with pytest.raises(CommitRelayError):
            raise CommitRelayError("Test error")

    def test_api_error_with_status_code(self):
        """Test APIError with status code."""
        error = APIError("API failed", status_code=500)
        assert error.status_code == 500
        assert "API failed" in str(error)

    def test_connection_error(self):
        """Test ConnectionError."""
        with pytest.raises(ConnectionError):
            raise ConnectionError("Connection failed")


class TestResourceClients:
    """Tests for resource client interfaces."""

    def test_workers_client_exists(self):
        """Test workers client is accessible."""
        client = CommitRelayClient()
        assert hasattr(client, 'workers')
        assert client.workers is not None

    def test_tasks_client_exists(self):
        """Test tasks client is accessible."""
        client = CommitRelayClient()
        assert hasattr(client, 'tasks')
        assert client.tasks is not None

    def test_metrics_client_exists(self):
        """Test metrics client is accessible."""
        client = CommitRelayClient()
        assert hasattr(client, 'metrics')
        assert client.metrics is not None

    def test_health_client_exists(self):
        """Test health client is accessible."""
        client = CommitRelayClient()
        assert hasattr(client, 'health')
        assert client.health is not None


if __name__ == '__main__':
    pytest.main([__file__, '-v'])
