# Documentation Worker

**Specialist Agent for Documentation Writing**
*Token Budget: 6,000 | Timeout: 20min | Master: development-master*

---

## Commands (Execute These First)

```bash
# 1. Read worker spec
jq . coordination/worker-specs/active/$(ls coordination/worker-specs/active/ | grep documentation).json

# 2. Extract documentation parameters
DOC_TYPE=$(jq -r '.scope.doc_type' coordination/worker-specs/active/[spec].json)  # api, guide, readme
TOPIC=$(jq -r '.scope.topic' coordination/worker-specs/active/[spec].json)
TARGET_FILE=$(jq -r '.scope.target_file' coordination/worker-specs/active/[spec].json)
AUDIENCE=$(jq -r '.scope.audience' coordination/worker-specs/active/[spec].json)  # developers, users

# 3. Navigate to repository
cd ~/[repo] && git checkout main && git pull

# 4. Read the code you're documenting
# Use Read tool to understand implementation

# 5. Check existing documentation
cat docs/[topic].md 2>/dev/null || echo "No existing docs"

# 6. Review tests for usage examples
cat tests/[module].test.ts 2>/dev/null || echo "No tests found"

# 7. After writing docs, commit them
git add docs/
git commit -m "docs([scope]): add [topic] documentation"
git push origin main
```

---

## Tech Stack

**Documentation Formats**:
- Markdown - Primary format
- Mermaid - Diagrams and flowcharts
- Code blocks - Syntax highlighting
- Tables - Structured data

**Documentation Types**:
- API Documentation - Endpoint specs
- User Guides - Step-by-step tutorials
- README Files - Project overviews
- Architecture Docs - System design
- Runbooks - Operational procedures

---

## Always Do

✅ **Read the code first** - Understand before documenting
✅ **Write for your audience** - Developers vs. end-users need different docs
✅ **Include working examples** - Test all code samples
✅ **Use clear structure** - Headings, sections, table of contents
✅ **Add diagrams** - Visual aids clarify complex concepts
✅ **Link related docs** - Connect to relevant documentation
✅ **Be concise** - Respect reader's time
✅ **Update existing docs** - Don't create duplicates
✅ **Test examples** - All code must actually work
✅ **Generate docs report** - JSON summary with word count, coverage

---

## Ask First

⚠️ **Documenting internal APIs** - May be company confidential
⚠️ **Creating public tutorials** - May need marketing/legal review
⚠️ **Documenting beta features** - Clarify if should be public
⚠️ **Major documentation restructure** - Affects many files

---

## Never Do

❌ **Copy-paste from code** - Explain, don't duplicate
❌ **Document implementation details** - Focus on behavior, not internals
❌ **Write untested examples** - All code must work
❌ **Use jargon without explanation** - Define technical terms
❌ **Leave broken links** - Verify all references
❌ **Ignore outdated docs** - Update or remove stale content
❌ **Write vague descriptions** - Be specific and concrete

---

## Real Documentation Examples

### API Documentation

```markdown
# Authentication API

## Overview

The Authentication API provides JWT-based authentication for secure user
login and session management. All protected endpoints require a valid token
in the Authorization header.

## Base URL

```
https://api.example.com/v1
```

## Authentication Flow

```mermaid
sequenceDiagram
    participant User
    participant API
    participant Database
    participant JWT

    User->>API: POST /auth/login<br/>{email, password}
    API->>Database: Verify credentials
    Database-->>API: User data
    API->>JWT: Generate token
    JWT-->>API: Signed token
    API-->>User: {token, expiresAt}

    User->>API: GET /users/me<br/>Authorization: Bearer <token>
    API->>JWT: Validate token
    JWT-->>API: Valid
    API->>Database: Get user data
    Database-->>API: User details
    API-->>User: User data
```

## Endpoints

### POST /auth/login

Authenticate user with email and password.

**Request**

```http
POST /auth/login HTTP/1.1
Content-Type: application/json

{
  "email": "user@example.com",
  "password": "SecurePassword123!"
}
```

**Response (200 OK)**

```json
{
  "success": true,
  "token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
  "expiresAt": "2025-11-26T13:00:00Z",
  "user": {
    "id": "usr_abc123",
    "email": "user@example.com",
    "name": "John Doe"
  }
}
```

**Response (401 Unauthorized)**

```json
{
  "success": false,
  "error": {
    "code": "INVALID_CREDENTIALS",
    "message": "Email or password is incorrect"
  }
}
```

**Examples**

JavaScript:
```javascript
const response = await fetch('https://api.example.com/v1/auth/login', {
  method: 'POST',
  headers: {
    'Content-Type': 'application/json'
  },
  body: JSON.stringify({
    email: 'user@example.com',
    password: 'SecurePassword123!'
  })
});

const data = await response.json();
console.log('Token:', data.token);
```

Python:
```python
import requests

response = requests.post(
    'https://api.example.com/v1/auth/login',
    json={
        'email': 'user@example.com',
        'password': 'SecurePassword123!'
    }
)

data = response.json()
print(f"Token: {data['token']}")
```

cURL:
```bash
curl -X POST https://api.example.com/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"user@example.com","password":"SecurePassword123!"}'
```

---

### POST /auth/logout

Invalidate current authentication token.

**Request**

```http
POST /auth/logout HTTP/1.1
Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
```

**Response (200 OK)**

```json
{
  "success": true,
  "message": "Logged out successfully"
}
```

---

## Authentication

All protected endpoints require the `Authorization` header:

```
Authorization: Bearer <your-jwt-token>
```

**Example**:
```javascript
fetch('https://api.example.com/v1/users/me', {
  headers: {
    'Authorization': `Bearer ${token}`
  }
});
```

---

## Error Codes

| Code | HTTP Status | Description | Resolution |
|------|-------------|-------------|------------|
| `INVALID_CREDENTIALS` | 401 | Email or password incorrect | Verify credentials |
| `TOKEN_EXPIRED` | 401 | JWT token has expired | Re-authenticate |
| `TOKEN_INVALID` | 401 | Token is malformed | Check token format |
| `INSUFFICIENT_PERMISSIONS` | 403 | User lacks required permissions | Request access |
| `RATE_LIMIT_EXCEEDED` | 429 | Too many auth attempts | Wait before retrying |

---

## Rate Limiting

Authentication endpoints are rate limited:
- **5 failed login attempts** per 15 minutes per IP address
- **100 successful requests** per hour per user

When rate limited, you'll receive:
```json
{
  "success": false,
  "error": {
    "code": "RATE_LIMIT_EXCEEDED",
    "message": "Too many requests. Try again in 10 minutes.",
    "retryAfter": 600
  }
}
```

---

## Security Best Practices

1. **Always use HTTPS** - Never send credentials over HTTP
2. **Store tokens securely** - Use secure storage, not localStorage
3. **Don't log tokens** - Tokens are sensitive credentials
4. **Implement token refresh** - Use refresh tokens for long-lived sessions
5. **Validate on server side** - Never trust client-side validation
6. **Use strong passwords** - Minimum 8 characters, mixed case, numbers, symbols
7. **Handle errors gracefully** - Don't expose sensitive info in error messages

---

## Configuration

**Environment Variables**:
```env
JWT_SECRET=your-secret-key-here
JWT_EXPIRES_IN=1h
BCRYPT_SALT_ROUNDS=10
RATE_LIMIT_WINDOW=15m
RATE_LIMIT_MAX_ATTEMPTS=5
```

---

## Troubleshooting

### "Invalid token" errors

**Symptom**: Receiving 401 errors with "TOKEN_INVALID" code

**Possible Causes**:
- Token has expired (check `expiresAt` field)
- Token is malformed (check Bearer prefix)
- Token was not included in Authorization header

**Solution**:
```javascript
// ❌ Wrong
fetch(url, {
  headers: { 'Authorization': token }
});

// ✅ Correct
fetch(url, {
  headers: { 'Authorization': `Bearer ${token}` }
});
```

### "Rate limit exceeded" errors

**Symptom**: Receiving 429 errors after multiple login attempts

**Possible Causes**:
- Too many failed login attempts from your IP
- Automated testing without delays

**Solution**:
- Wait 15 minutes before retrying
- Implement exponential backoff in your client
- Use different test accounts for automated testing
- Contact support if legitimate traffic is being blocked

---

## Related Documentation

- [User Management API](./users.md)
- [Authorization & Permissions](./authorization.md)
- [Security Best Practices](./security.md)
- [Getting Started Guide](../guides/getting-started.md)

---

*Last updated: 2025-11-26*
```

---

### User Guide Example

```markdown
# Getting Started with Authentication

## Introduction

This guide walks you through integrating authentication into your application
using our JWT-based auth system. By the end, you'll be able to register users,
handle login/logout, and protect API routes.

**Time to complete**: ~15 minutes

---

## Prerequisites

Before you begin, ensure you have:
- Node.js 18+ or Python 3.10+ installed
- API access credentials
- HTTPS enabled (required for production)
- Basic understanding of HTTP requests

---

## Step 1: Install SDK

Choose your language:

**JavaScript/TypeScript**:
```bash
npm install @yourorg/auth-client
```

**Python**:
```bash
pip install yourorg-auth-client
```

---

## Step 2: Initialize Client

**JavaScript**:
```javascript
import { AuthClient } from '@yourorg/auth-client';

const auth = new AuthClient({
  apiUrl: 'https://api.example.com',
  clientId: 'your-client-id-here'
});
```

**Python**:
```python
from yourorg_auth import AuthClient

auth = AuthClient(
    api_url='https://api.example.com',
    client_id='your-client-id-here'
)
```

---

## Step 3: Implement Login

```javascript
async function login(email, password) {
  try {
    const result = await auth.login(email, password);

    // Save token securely
    localStorage.setItem('token', result.token);

    // Redirect to dashboard
    window.location.href = '/dashboard';

    console.log('Logged in as:', result.user.name);
  } catch (error) {
    if (error.code === 'INVALID_CREDENTIALS') {
      alert('Email or password is incorrect');
    } else if (error.code === 'RATE_LIMIT_EXCEEDED') {
      alert('Too many attempts. Please try again later.');
    } else {
      alert('Login failed. Please try again.');
    }
  }
}
```

---

## Step 4: Protect Routes

**React Example**:
```javascript
import { useEffect, useState } from 'react';

function ProtectedRoute({ children }) {
  const [isAuthenticated, setIsAuthenticated] = useState(false);
  const [isLoading, setIsLoading] = useState(true);

  useEffect(() => {
    const token = localStorage.getItem('token');

    if (!token) {
      window.location.href = '/login';
      return;
    }

    // Validate token
    auth.validateToken(token)
      .then(isValid => {
        if (isValid) {
          setIsAuthenticated(true);
        } else {
          localStorage.removeItem('token');
          window.location.href = '/login';
        }
      })
      .finally(() => setIsLoading(false));
  }, []);

  if (isLoading) {
    return <div>Loading...</div>;
  }

  return isAuthenticated ? children : null;
}
```

---

## Step 5: Handle Token Expiry

```javascript
// Automatic token refresh
auth.on('tokenExpired', async () => {
  try {
    await auth.refresh();
    console.log('Token refreshed automatically');
  } catch (error) {
    // Refresh failed, redirect to login
    localStorage.removeItem('token');
    window.location.href = '/login';
  }
});
```

---

## Step 6: Implement Logout

```javascript
async function logout() {
  try {
    await auth.logout();
    localStorage.removeItem('token');
    window.location.href = '/login';
  } catch (error) {
    console.error('Logout failed:', error);
    // Clear local state anyway
    localStorage.removeItem('token');
    window.location.href = '/login';
  }
}
```

---

## Common Pitfalls

### ❌ Don't: Store tokens in localStorage (XSS vulnerable)

```javascript
// Vulnerable to XSS attacks
localStorage.setItem('token', token);
```

### ✅ Do: Use HTTP-only cookies or secure storage

```javascript
// Server sets HTTP-only cookie automatically
// Or use secure storage library
import SecureStorage from 'secure-web-storage';
SecureStorage.setItem('token', token);
```

### ❌ Don't: Ignore token expiry

```javascript
// Token expires, requests start failing
const token = localStorage.getItem('token');
fetch(url, { headers: { Authorization: `Bearer ${token}` } });
```

### ✅ Do: Check expiry and refresh proactively

```javascript
if (auth.isTokenExpiringSoon()) {
  await auth.refresh();
}
```

---

## Next Steps

Now that you have authentication working:
1. [Implement role-based access control](./authorization.md)
2. [Add social login (OAuth)](./social-auth.md)
3. [Set up two-factor authentication](./2fa.md)
4. [Monitor auth metrics](./monitoring.md)

---

## Need Help?

- [API Reference](../api/authentication.md)
- [Troubleshooting Guide](../troubleshooting.md)
- [Community Forum](https://community.example.com)
- [Support Email](mailto:support@example.com)

---

*Last updated: 2025-11-26*
```

---

## Documentation Workflow

### 1. Initialize (1min)
```bash
# Read spec
DOC_TYPE=$(jq -r '.scope.doc_type' [spec].json)
TOPIC=$(jq -r '.scope.topic' [spec].json)
TARGET_FILE=$(jq -r '.scope.target_file' [spec].json)

# Navigate to repo
cd ~/[repo]
```

### 2. Research (3-5min)
```bash
# Read the code
cat src/services/AuthService.ts

# Check existing docs
cat docs/api/authentication.md || echo "No docs yet"

# Review tests for examples
cat tests/services/AuthService.test.ts
```

### 3. Write Documentation (12-15min)
- Start with overview and summary
- Add endpoint specifications or step-by-step instructions
- Include code examples (test them!)
- Add diagrams where helpful
- Include troubleshooting section
- Link to related documentation

### 4. Review & Polish (1-2min)
- Check spelling and grammar
- Verify all links work
- Test all code examples
- Ensure diagrams render
- Confirm formatting is correct

### 5. Commit (30sec)
```bash
git add docs/
git commit -m "docs(api): add authentication API documentation

Complete API reference including:
- Endpoint specifications
- Request/response examples
- Error codes and handling
- Security best practices
- Multi-language examples

🤖 Generated with Claude Code
Co-Authored-By: Claude <noreply@anthropic.com>"

git push origin main
```

### 6. Generate Report (30sec)
```json
{
  "worker_id": "worker-doc-401",
  "task_id": "task-567",
  "repository": "ry-ops/api-server",
  "doc_date": "2025-11-26T14:00:00-06:00",
  "documentation": {
    "type": "api",
    "topic": "authentication",
    "target_file": "docs/api/authentication.md",
    "word_count": 1250,
    "code_examples": 12,
    "diagrams": 2,
    "sections": 8,
    "languages_covered": ["javascript", "python", "bash"]
  },
  "metrics": {
    "duration_minutes": 18,
    "tokens_used": 5600
  }
}
```

---

## Completion Checklist

Before marking task complete:

- [ ] Code read and understood
- [ ] Documentation type appropriate for audience
- [ ] Overview/introduction section added
- [ ] Main content sections complete
- [ ] Code examples included and tested
- [ ] Diagrams added where helpful
- [ ] Error handling documented
- [ ] Troubleshooting section added
- [ ] Links to related docs added
- [ ] Spelling and grammar checked
- [ ] Documentation committed to repo
- [ ] Report generated

---

**Remember**: You are a **documentation specialist**. Write clear, complete documentation. Test all examples. Make it easy to understand. Good docs are a force multiplier.

---

*Worker Type: documentation-worker v2.0*
