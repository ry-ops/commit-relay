# Release Process

## Release Types

### Patch Release (1.0.x)
- Bug fixes only
- No new features
- Backwards compatible
- Release frequency: As needed

### Minor Release (1.x.0)
- New features
- Enhancements
- Backwards compatible
- Release frequency: Monthly

### Major Release (x.0.0)
- Breaking changes
- Major new features
- API changes
- Release frequency: Quarterly

## Release Checklist

### Pre-Release (1 week before)

- [ ] Create release branch: `release/v1.2.0`
- [ ] Update version in package.json
- [ ] Update CHANGELOG.md
- [ ] Run full test suite
- [ ] Run security scan
- [ ] Update documentation
- [ ] Freeze feature development

### Testing (3 days before)

- [ ] Deploy to staging environment
- [ ] Run smoke tests
- [ ] Performance testing
- [ ] Security audit
- [ ] User acceptance testing
- [ ] Load testing

### Release Day

- [ ] Final PR review
- [ ] Merge to main
- [ ] Tag release: `git tag v1.2.0`
- [ ] Build production artifacts
- [ ] Deploy to production
- [ ] Verify deployment
- [ ] Update status page
- [ ] Announce release

### Post-Release

- [ ] Monitor error rates
- [ ] Check performance metrics
- [ ] Customer feedback
- [ ] Document issues
- [ ] Plan hotfixes if needed

## Versioning

Follow Semantic Versioning (semver.org):

```
MAJOR.MINOR.PATCH

1.2.3
│ │ └─ Patch: Bug fixes
│ └─── Minor: New features (backwards compatible)
└───── Major: Breaking changes
```

## Release Commands

```bash
# Create release branch
git checkout -b release/v1.2.0

# Update version
npm version minor

# Generate changelog
npm run changelog

# Build and test
npm run build
npm test

# Tag and push
git tag v1.2.0
git push origin v1.2.0

# Deploy
./scripts/deployment/deploy.sh production v1.2.0
```

## Changelog Format

```markdown
# v1.2.0 (2025-11-25)

## Features
- Add achievement tracking system
- Implement MoE routing

## Bug Fixes
- Fix worker zombie detection
- Resolve rate limiting issues

## Performance
- Improve API response time by 50%
- Optimize database queries

## Breaking Changes
- Remove deprecated /api/v0 endpoints
```

## Hotfix Process

For critical production bugs:

1. Create hotfix branch from main: `hotfix/v1.2.1`
2. Fix the issue
3. Test thoroughly
4. Merge to main and release
5. Cherry-pick to active release branches

Last Updated: 2025-11-25
