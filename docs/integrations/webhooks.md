# Webhook Integration Guide

## Overview

Webhook support for real-time event notifications from commit-relay.

## Supported Events

- `achievement.unlocked` - Achievement unlocked
- `task.completed` - Task completed
- `worker.spawned` - Worker spawned
- `deployment.completed` - Deployment finished
- `alert.triggered` - Alert fired

## Configuration

Add webhook URL to .env:

```bash
WEBHOOK_URL=https://your-service.com/webhooks
WEBHOOK_SECRET=your_secret_key
```

## Webhook Payload

```json
{
  "event": "achievement.unlocked",
  "timestamp": "2025-11-25T21:00:00Z",
  "data": {
    "achievement": "pull_shark",
    "tier": "silver",
    "user": "ry-ops"
  },
  "signature": "sha256=..."
}
```

## Signature Verification

```javascript
const crypto = require('crypto');

function verifySignature(payload, signature, secret) {
  const hmac = crypto.createHmac('sha256', secret);
  const digest = 'sha256=' + hmac.update(payload).digest('hex');
  return crypto.timingSafeEqual(
    Buffer.from(signature),
    Buffer.from(digest)
  );
}
```

## Example Implementations

### Slack Integration

```javascript
async function sendToSlack(event) {
  await fetch(process.env.SLACK_WEBHOOK, {
    method: 'POST',
    body: JSON.stringify({
      text: `🎉 Achievement unlocked: ${event.data.achievement}`
    })
  });
}
```

### Discord Integration

```javascript
async function sendToDiscord(event) {
  await fetch(process.env.DISCORD_WEBHOOK, {
    method: 'POST',
    body: JSON.stringify({
      content: `Achievement: ${event.data.achievement}`,
      embeds: [{
        title: 'Pull Shark Silver',
        color: 0x00ff00
      }]
    })
  });
}
```

Last Updated: 2025-11-25
