# API Versioning Strategy

## Overview

Semantic versioning strategy for commit-relay API ensuring backward compatibility and smooth migrations.

**Current Version**: v1  
**Versioning Scheme**: URL-based (`/api/v1/`, `/api/v2/`)

---

## Versioning Principles

1. **Backward Compatibility**: Never break existing clients
2. **Deprecation Period**: 90 days minimum before removal
3. **Clear Migration Path**: Documented upgrade guides
4. **Semantic Versioning**: Major.Minor.Patch (1.0.0)

---

## Version Scheme

### URL-Based Versioning

```
/api/v1/achievements/progress    # Version 1
/api/v2/achievements/progress    # Version 2 (future)
```

**Rationale**: 
- Clear and explicit
- Easy to route
- Cacheable
- No header parsing needed

### Header-Based Alternative

```http
GET /api/achievements/progress
Accept: application/vnd.commit-relay.v1+json
```

---

## Breaking vs Non-Breaking Changes

### Non-Breaking (Minor/Patch)

✅ **Safe Changes**:
- Adding new endpoints
- Adding optional parameters
- Adding new fields to responses
- Deprecating fields (with warnings)
- Performance improvements
- Bug fixes

**Example**:
```javascript
// v1.0.0
{
  "achievement_id": "pull_shark",
  "count": 16
}

// v1.1.0 (backward compatible)
{
  "achievement_id": "pull_shark",
  "count": 16,
  "tier": "silver"  // New field added
}
```

### Breaking (Major)

❌ **Breaking Changes**:
- Removing endpoints
- Removing or renaming fields
- Changing field types
- Changing error response format
- Changing authentication method

**Example**:
```javascript
// v1
{
  "count": 16,
  "tier": "silver"
}

// v2 (BREAKING)
{
  "metrics": {
    "total_prs": 16,
    "current_tier": "silver"
  }
}
```

---

## Implementation

### Route Configuration

```javascript
// api-server/routes/v1/achievements.js
const express = require('express');
const router = express.Router();

router.get('/progress', async (req, res) => {
  const tracker = new AchievementTracker({
    githubToken: process.env.GITHUB_TOKEN,
    username: req.query.username || process.env.GITHUB_USERNAME
  });
  
  const progress = await tracker.getAllProgress();
  
  res.json({
    version: '1.0.0',
    data: progress
  });
});

module.exports = router;

// api-server/server.js
app.use('/api/v1/achievements', require('./routes/v1/achievements'));
// app.use('/api/v2/achievements', require('./routes/v2/achievements')); // Future
```

### Deprecation Warnings

```javascript
// middleware/deprecation.js
function deprecationWarning(version, message) {
  return (req, res, next) => {
    res.setHeader('Deprecation', 'true');
    res.setHeader('Sunset', 'Sat, 1 Mar 2025 23:59:59 GMT');
    res.setHeader('Link', '</api/v2>; rel="successor-version"');
    
    console.warn(`[DEPRECATION] v${version}: ${message}`);
    next();
  };
}

// Usage
router.get('/old-endpoint', 
  deprecationWarning('1', 'Use /api/v2/new-endpoint instead'),
  handler
);
```

---

## Version Lifecycle

### Stage 1: Development (Alpha)

```
POST /api/v2-alpha/achievements/execute
X-API-Version: 2.0.0-alpha.1
```

- Internal testing only
- Frequent breaking changes allowed
- No backward compatibility guarantees

### Stage 2: Beta

```
POST /api/v2-beta/achievements/execute
X-API-Version: 2.0.0-beta.1
```

- External testing with partners
- Feature complete
- Minimal breaking changes

### Stage 3: Stable

```
POST /api/v2/achievements/execute
X-API-Version: 2.0.0
```

- Production ready
- Backward compatibility enforced
- Only non-breaking changes

### Stage 4: Deprecated

```
POST /api/v1/achievements/execute
Deprecation: true
Sunset: Sat, 1 Mar 2025 23:59:59 GMT
```

- 90-day notice period
- Migration guide published
- Warning headers added

### Stage 5: Sunset

- Endpoint removed
- Returns 410 Gone
- Redirects to new version

---

## Migration Guide Template

```markdown
# Migration Guide: v1 → v2

## Breaking Changes

### 1. Achievement Progress Response

**v1**:
\`\`\`json
{
  "achievement_id": "pull_shark",
  "count": 16,
  "tier": "silver"
}
\`\`\`

**v2**:
\`\`\`json
{
  "achievement": {
    "id": "pull_shark",
    "metrics": {
      "total": 16
    },
    "tier": {
      "current": "silver",
      "next": "gold"
    }
  }
}
\`\`\`

**Migration**:
\`\`\`javascript
// v1
const tier = response.tier;

// v2
const tier = response.achievement.tier.current;
\`\`\`

## Timeline

- **2025-12-01**: v2 beta release
- **2026-01-01**: v2 stable release
- **2026-02-01**: v1 deprecation notice
- **2026-05-01**: v1 sunset
```

---

## Version Detection

### Client-Side

```javascript
class CommitRelayClient {
  constructor(apiVersion = '1') {
    this.baseURL = `https://api.commit-relay.io/api/v${apiVersion}`;
    this.version = apiVersion;
  }
  
  async getAchievements() {
    const response = await fetch(`${this.baseURL}/achievements/progress`);
    
    // Check for deprecation
    if (response.headers.get('Deprecation')) {
      console.warn('API version deprecated:', response.headers.get('Sunset'));
    }
    
    return response.json();
  }
}
```

### Server-Side

```javascript
function detectClientVersion(req) {
  // URL-based
  if (req.path.startsWith('/api/v2')) return '2.0.0';
  if (req.path.startsWith('/api/v1')) return '1.0.0';
  
  // Header-based
  const acceptHeader = req.headers['accept'];
  const versionMatch = acceptHeader?.match(/vnd\.commit-relay\.v(\d+)/);
  if (versionMatch) return `${versionMatch[1]}.0.0`;
  
  // Default to latest
  return '1.0.0';
}
```

---

## Changelog

### v1.0.0 (2025-11-25)
- Initial release
- Achievement tracking endpoints
- MoE task routing API
- Worker management endpoints

### v1.1.0 (Planned: 2025-12-15)
- Add bulk achievement updates
- Add webhook support
- Add pagination for large responses

### v2.0.0 (Planned: 2026-01-01)
- GraphQL API support
- Real-time WebSocket subscriptions
- Enhanced error responses
- Nested resource structure

---

## Testing Version Compatibility

```javascript
describe('API Version Compatibility', () => {
  test('v1 endpoints remain unchanged', async () => {
    const v1Response = await fetch('/api/v1/achievements/progress');
    const v1Data = await v1Response.json();
    
    expect(v1Data).toMatchSnapshot();
  });
  
  test('deprecated endpoints include sunset header', async () => {
    const response = await fetch('/api/v1/deprecated-endpoint');
    
    expect(response.headers.get('Deprecation')).toBe('true');
    expect(response.headers.get('Sunset')).toBeDefined();
  });
});
```

---

**Current Version**: v1.0.0  
**Next Release**: v1.1.0 (2025-12-15)  
**Deprecation Policy**: 90 days minimum
