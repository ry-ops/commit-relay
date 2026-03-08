# Commit-Relay SDK Architecture

This document describes the architecture and design decisions behind the commit-relay Python SDK.

## Overview

The SDK is designed as a layered architecture with clear separation of concerns:

```
┌─────────────────────────────────────────────────────────┐
│                  User Applications                       │
└─────────────────────────────────────────────────────────┘
                          │
┌─────────────────────────────────────────────────────────┐
│              Public API (commit_relay)                   │
│  CommitRelayClient, Analytics, Monitoring, Reporting    │
└─────────────────────────────────────────────────────────┘
                          │
┌─────────────────────────────────────────────────────────┐
│                  Resource Clients                        │
│    Workers, Tasks, Metrics, Health, Events, etc.        │
└─────────────────────────────────────────────────────────┘
                          │
┌─────────────────────────────────────────────────────────┐
│                   Core HTTP Client                       │
│         Request/Response Handling, Error Mgmt           │
└─────────────────────────────────────────────────────────┘
                          │
┌─────────────────────────────────────────────────────────┐
│              Commit-Relay Dashboard API                 │
│                  (HTTP REST API)                         │
└─────────────────────────────────────────────────────────┘
```

## Core Components

### 1. Client Layer (commit_relay/client.py)

**Responsibilities:**
- HTTP request/response management
- Connection pooling via requests.Session
- Error handling and exception mapping
- URL construction and parameter handling

**Design Decisions:**
- Uses `requests` library for HTTP (industry standard, well-tested)
- Lazy initialization of resource clients to avoid circular imports
- Property-based access to resource clients for clean API
- Context manager support for proper cleanup

**Key Features:**
- Automatic retry logic (future enhancement)
- Timeout configuration
- SSL verification control
- Session persistence for performance

### 2. Resource Clients (commit_relay/resources/)

Each resource client is a specialized interface to a subset of API endpoints:

```
resources/
├── workers.py      # Worker management
├── tasks.py        # Task operations
├── metrics.py      # Metrics data
├── health.py       # Health status
├── events.py       # System events
├── daemons.py      # Daemon control
└── git_ops.py      # Git operations
```

**Design Pattern:** Resource-oriented architecture
- Each resource type gets its own client class
- Consistent method naming (list, get, get_by_X, to_dataframe, export_to_X)
- Encapsulates API endpoint knowledge
- Handles response parsing and normalization

**Benefits:**
- Easy to understand and navigate
- Clear separation of concerns
- Easy to extend with new resources
- Consistent API across all resources

### 3. Analytics Module (commit_relay/analytics/)

Provides data analysis capabilities on top of raw API data.

#### MetricsAggregator
- Aggregates metrics over time periods
- Calculates summary statistics
- Provides comparison between periods
- Handles both pandas and non-pandas environments

#### TrendAnalyzer
- Statistical trend detection using linear regression
- Moving averages (simple and exponential)
- Volatility analysis
- Outlier detection (IQR and Z-score methods)
- Seasonality detection

#### MetricsForecaster
- Linear regression forecasting
- Simple exponential smoothing
- Capacity breach prediction
- Confidence interval calculation

**Design Decisions:**
- Graceful degradation when scipy/numpy not available
- Static methods for stateless operations
- Fallback implementations for environments without pandas
- Focus on interpretability over complex models

### 4. Monitoring Module (commit_relay/monitoring/)

Provides health monitoring and alerting.

#### HealthChecker
- Configurable health check thresholds
- Multiple check types (workers, success rate, backlog, etc.)
- Overall health aggregation
- Formatted report generation

#### AnomalyDetector
- Z-score method for statistical anomalies
- IQR method for distribution-based anomalies
- Multi-method combination for higher confidence
- Batch detection across multiple metrics

#### AlertManager
- Alert generation from health checks
- Alert generation from anomaly detection
- Pluggable alert handlers
- Alert filtering and retrieval

**Design Pattern:** Strategy pattern for alert handlers
- Allows custom handling logic
- Easy to add new alert destinations (email, Slack, etc.)
- Separation of detection and notification

### 5. Reporting Module (commit_relay/reporting/)

Generates reports and visualizations.

#### ReportGenerator
- Text and markdown report generation
- Multiple report types (daily, executive, worker-specific)
- File export capabilities
- Template-based approach for consistency

#### DashboardVisualizer
- matplotlib/seaborn based visualizations
- Multiple chart types (line, bar, multi-panel)
- Consistent styling via seaborn
- High-quality PNG export

#### DataExporter
- Multi-format export (CSV, JSON, Excel)
- Batch export capabilities
- Directory-based organization
- Comprehensive data dumps

**Design Decisions:**
- Optional matplotlib dependency (graceful degradation)
- Consistent color schemes across all visualizations
- High DPI (300) for publication-quality outputs
- Flexible save/display options

## Exception Hierarchy

```
CommitRelayError (base)
├── APIError
│   ├── ResourceNotFoundError (404)
│   ├── AuthenticationError (401)
│   └── RateLimitError (429)
├── ConnectionError
└── ValidationError
```

**Benefits:**
- Easy to catch all SDK errors (CommitRelayError)
- Specific handling for common scenarios
- Preserves HTTP status codes
- Clear error messages

## Data Flow

### Typical Request Flow

```
User Code
    │
    ├─> client.metrics.get_current()
    │       │
    │       ├─> client.get('/api/metrics')
    │       │       │
    │       │       ├─> _request('GET', '/api/metrics')
    │       │       │       │
    │       │       │       ├─> session.request(...)
    │       │       │       │       │
    │       │       │       │       └─> Dashboard API
    │       │       │       │
    │       │       │       ├─> Handle errors
    │       │       │       └─> Parse JSON
    │       │       │
    │       │       └─> Return dict
    │       │
    │       └─> Return metrics
    │
    └─> metrics = {...}
```

### Analytics Data Flow

```
Raw API Data
    │
    ├─> to_dataframe()
    │       │
    │       └─> pandas.DataFrame
    │               │
    │               ├─> MetricsAggregator.get_stats()
    │               ├─> TrendAnalyzer.detect_trend()
    │               ├─> AnomalyDetector.detect_anomalies()
    │               └─> DashboardVisualizer.plot()
    │
    └─> Insights, Reports, Visualizations
```

## Design Principles

### 1. Progressive Enhancement
- Core functionality works without optional dependencies
- Enhanced features available when dependencies installed
- Graceful degradation with helpful error messages

### 2. Consistency
- Consistent method naming across all resource clients
- Consistent parameter ordering
- Consistent return types

### 3. Type Safety
- Full type hints throughout codebase
- Enables IDE autocomplete and type checking
- Self-documenting code

### 4. Documentation
- Comprehensive docstrings for all public methods
- Examples in docstrings
- Clear parameter descriptions
- Return type documentation

### 5. Error Handling
- Never silently fail
- Provide actionable error messages
- Preserve error context (status codes, response data)
- Use exceptions for exceptional conditions

### 6. Performance
- Connection pooling via requests.Session
- Lazy initialization where appropriate
- Efficient data structures
- Optional caching (future enhancement)

## Extension Points

### Adding New Resource Clients

1. Create new file in `commit_relay/resources/`
2. Implement resource class with standard methods
3. Add to `resources/__init__.py`
4. Add property to `CommitRelayClient`

### Adding New Analytics

1. Create method in appropriate analytics class
2. Follow static method pattern for stateless operations
3. Provide fallback for missing dependencies
4. Add comprehensive docstring with examples

### Adding Alert Handlers

```python
def my_alert_handler(alert: Alert):
    # Custom handling logic
    send_to_slack(alert.message)

manager = AlertManager()
manager.add_handler(my_alert_handler)
```

### Adding Visualization Types

1. Add method to `DashboardVisualizer`
2. Use consistent styling (seaborn)
3. Support save_path parameter
4. Handle matplotlib import gracefully

## Testing Strategy

### Unit Tests
- Test each resource client independently
- Mock HTTP responses
- Test error conditions
- Test data transformations

### Integration Tests
- Test against live or mock API
- Test complete workflows
- Test error recovery

### Example Tests
- Ensure all examples run without errors
- Validate example outputs

## Performance Considerations

### Connection Pooling
- Single `requests.Session` per client
- Connection reuse across requests
- Configurable timeout

### Data Transfer
- JSON parsing efficiency
- DataFrame construction optimization
- Batch operations where possible

### Memory Usage
- Streaming for large datasets (future)
- Pagination support (future)
- Efficient data structures

## Future Enhancements

### Planned Features
1. Async client support (asyncio/aiohttp)
2. Caching layer for frequently accessed data
3. GraphQL support (if API adds it)
4. Real-time streaming (websockets)
5. Advanced forecasting (ARIMA, Prophet)
6. Interactive dashboards (Plotly, Dash)
7. CLI tool wrapper
8. Configuration file support

### API Versioning
- Currently supports single API version
- Future: version negotiation
- Backwards compatibility guarantees

## Dependencies Rationale

| Package | Purpose | Why Chosen |
|---------|---------|-----------|
| requests | HTTP client | Industry standard, reliable, well-documented |
| pandas | Data analysis | De facto standard for Python data analysis |
| numpy | Numerical computing | Required by pandas, efficient operations |
| scipy | Statistical functions | Reliable statistical methods |
| matplotlib | Plotting | Most widely used plotting library |
| seaborn | Statistical viz | Beautiful defaults, built on matplotlib |

## Security Considerations

- SSL verification enabled by default
- No credentials stored in code
- Future: API key support
- Future: OAuth support
- Input validation on all user-provided data

## Conclusion

The SDK architecture is designed for:
- **Ease of use**: Simple, pythonic API
- **Extensibility**: Easy to add new features
- **Reliability**: Comprehensive error handling
- **Performance**: Efficient data handling
- **Maintainability**: Clear structure and documentation

The modular design allows each component to evolve independently while maintaining a stable public API.
