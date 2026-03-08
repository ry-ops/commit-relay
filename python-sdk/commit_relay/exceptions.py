"""
Custom exceptions for the Commit-Relay Python SDK.

This module defines the exception hierarchy used throughout the SDK for
handling various error conditions when interacting with the commit-relay
dashboard API.
"""


class CommitRelayError(Exception):
    """
    Base exception for all commit-relay SDK errors.

    All custom exceptions in this SDK inherit from this base class,
    making it easy to catch any SDK-related error.
    """
    pass


class APIError(CommitRelayError):
    """
    Raised when an API request fails.

    This includes HTTP errors, invalid responses, or server-side errors
    returned by the commit-relay dashboard API.

    Attributes:
        status_code (int): HTTP status code if available
        response_data (dict): Response data from the API if available
    """

    def __init__(self, message: str, status_code: int = None, response_data: dict = None):
        super().__init__(message)
        self.status_code = status_code
        self.response_data = response_data


class ConnectionError(CommitRelayError):
    """
    Raised when unable to connect to the dashboard API.

    This includes network errors, timeouts, and connection refused errors.
    """
    pass


class ValidationError(CommitRelayError):
    """
    Raised when invalid parameters or data are provided.

    This is used for client-side validation before making API requests.
    """
    pass


class ResourceNotFoundError(APIError):
    """
    Raised when a requested resource is not found (404).
    """

    def __init__(self, resource_type: str, resource_id: str):
        message = f"{resource_type} with ID '{resource_id}' not found"
        super().__init__(message, status_code=404)
        self.resource_type = resource_type
        self.resource_id = resource_id


class AuthenticationError(APIError):
    """
    Raised when authentication fails (401).

    Note: Currently the dashboard API does not require authentication,
    but this is included for future extensibility.
    """

    def __init__(self, message: str = "Authentication failed"):
        super().__init__(message, status_code=401)


class RateLimitError(APIError):
    """
    Raised when rate limit is exceeded (429).

    Attributes:
        retry_after (int): Seconds to wait before retrying, if provided by API
    """

    def __init__(self, message: str = "Rate limit exceeded", retry_after: int = None):
        super().__init__(message, status_code=429)
        self.retry_after = retry_after
