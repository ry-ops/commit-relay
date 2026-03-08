# Installation Guide

## Quick Install

### Install from source

```bash
cd /Users/ryandahlberg/commit-relay/python-sdk
pip install -e .
```

### Install with all optional dependencies

```bash
pip install -e ".[excel,jupyter,dev]"
```

## Dependencies

### Required Dependencies

These are automatically installed:

- `requests>=2.28.0` - HTTP client
- `pandas>=1.5.0` - Data analysis
- `numpy>=1.23.0` - Numerical computing
- `scipy>=1.9.0` - Scientific computing
- `matplotlib>=3.6.0` - Plotting
- `seaborn>=0.12.0` - Statistical visualizations

### Optional Dependencies

#### Excel Export
```bash
pip install openpyxl>=3.0.0
```

#### Jupyter Notebooks
```bash
pip install jupyter>=1.0.0 ipykernel>=6.0.0
```

#### Development Tools
```bash
pip install pytest>=7.0 pytest-cov>=4.0 black>=22.0 mypy>=0.991 flake8>=5.0
```

## Verification

Test the installation:

```bash
cd examples
export PYTHONPATH=/Users/ryandahlberg/commit-relay/python-sdk
python3 basic_usage.py
```

Or with Python:

```python
from commit_relay import CommitRelayClient
client = CommitRelayClient(base_url='http://localhost:3000')
print(client.ping())  # Should print True
```

## Troubleshooting

### ModuleNotFoundError

If you get `ModuleNotFoundError: No module named 'commit_relay'`, either:

1. Install the package: `pip install -e .`
2. Or set PYTHONPATH: `export PYTHONPATH=/Users/ryandahlberg/commit-relay/python-sdk`

### pandas not available

If you see "pandas not available", install it:
```bash
pip install pandas numpy
```

### matplotlib not available

If visualizations don't work, install:
```bash
pip install matplotlib seaborn
```

## Python Version

Requires Python 3.8 or higher.

Check your version:
```bash
python3 --version
```

## Dashboard Requirements

The SDK requires a running commit-relay dashboard:

1. Dashboard must be running on http://localhost:3000 (or configured URL)
2. Dashboard API must be accessible
3. Test connectivity: `curl http://localhost:3000/api/health`

## Next Steps

After installation:

1. Read [README.md](README.md) for usage examples
2. Try the example scripts in `examples/`
3. Open Jupyter notebooks in `examples/notebooks/`
4. Review API documentation
