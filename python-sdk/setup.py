"""
Setup script for commit-relay-client Python SDK.
"""

from setuptools import setup, find_packages
import os

# Read long description from README
readme_path = os.path.join(os.path.dirname(__file__), 'README.md')
if os.path.exists(readme_path):
    with open(readme_path, 'r', encoding='utf-8') as f:
        long_description = f.read()
else:
    long_description = 'Python SDK for Commit-Relay automation system'

setup(
    name='commit-relay-client',
    version='0.1.0',
    description='Python SDK for Commit-Relay automation system with analytics, monitoring, and reporting',
    long_description=long_description,
    long_description_content_type='text/markdown',
    author='Commit-Relay Team',
    author_email='noreply@commit-relay.local',
    url='https://github.com/yourusername/commit-relay',
    packages=find_packages(exclude=['tests', 'tests.*', 'examples', 'examples.*']),
    install_requires=[
        'requests>=2.28.0',
        'pandas>=1.5.0',
        'numpy>=1.23.0',
        'scipy>=1.9.0',
        'matplotlib>=3.6.0',
        'seaborn>=0.12.0',
    ],
    extras_require={
        'dev': [
            'pytest>=7.0',
            'pytest-cov>=4.0',
            'black>=22.0',
            'mypy>=0.991',
            'flake8>=5.0',
        ],
        'excel': [
            'openpyxl>=3.0.0',
        ],
        'jupyter': [
            'jupyter>=1.0.0',
            'ipykernel>=6.0.0',
        ],
    },
    python_requires='>=3.8',
    classifiers=[
        'Development Status :: 3 - Alpha',
        'Intended Audience :: Developers',
        'Topic :: Software Development :: Libraries :: Python Modules',
        'Programming Language :: Python :: 3',
        'Programming Language :: Python :: 3.8',
        'Programming Language :: Python :: 3.9',
        'Programming Language :: Python :: 3.10',
        'Programming Language :: Python :: 3.11',
        'Programming Language :: Python :: 3.12',
    ],
    keywords='commit-relay automation api-client analytics monitoring',
    project_urls={
        'Source': 'https://github.com/yourusername/commit-relay',
        'Documentation': 'https://github.com/yourusername/commit-relay/tree/main/python-sdk',
    },
)
