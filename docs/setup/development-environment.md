# Development Environment Setup

Complete guide for setting up your commit-relay development environment.

## Quick Start

1. Clone and install:
```bash
git clone https://github.com/ry-ops/commit-relay.git
cd commit-relay
npm install
```

2. Configure environment:
```bash
cp .env.example .env
# Edit .env with your credentials
```

3. Start development:
```bash
npm run dev
```

## Prerequisites

- Node.js 18+
- npm 9+
- Git 2.40+
- GitHub account with PAT

## GitHub Configuration

Generate token at: https://github.com/settings/tokens/new

Required scopes:
- repo (full access)
- workflow (GitHub Actions)  
- read:org (organization access)

Add to .env:
```bash
GITHUB_TOKEN=ghp_YOUR_TOKEN
GITHUB_USERNAME=your-username
```

## IDE Setup

### VS Code

Recommended extensions:
- ESLint
- Prettier
- REST Client

### Launch Configuration

Use F5 to debug API server with breakpoints.

## Development Workflow

```bash
# Create feature branch
git checkout -b feat/your-feature

# Make changes and test
npm test

# Commit
git commit -m "feat: description"

# Push and create PR
git push origin feat/your-feature
gh pr create
```

## Testing

```bash
# All tests
npm test

# Unit tests
npm run test:unit

# With coverage
npm run test:coverage
```

## Troubleshooting

Port in use:
```bash
lsof -i :5001 | xargs kill -9
```

Clean install:
```bash
rm -rf node_modules package-lock.json
npm install
```

Last Updated: 2025-11-25
