# Achievement API Integration Guide

## Quick Start

### 1. Install Dependencies

```bash
npm install @anthropic-ai/sdk
```

### 2. Configure Environment

```bash
export GITHUB_TOKEN="your_github_token"
export GITHUB_USERNAME="your_username"
```

### 3. Track Progress

```javascript
const response = await fetch('http://localhost:5001/api/achievements/progress');
const data = await response.json();

console.log(`Unlocked: ${data.summary.unlocked}/8 achievements`);
```

## Advanced Usage

### Get Opportunity Scores

```javascript
const opportunities = await fetch('http://localhost:5001/api/achievements/opportunities');
const scores = await opportunities.json();

scores.top_3.forEach(opp => {
  console.log(`${opp.icon} ${opp.name}: ${opp.opportunity_score}/100`);
});
```

### Execute Workflows

```javascript
await fetch('http://localhost:5001/api/achievements/execute/quickdraw', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ feature_name: 'my-feature' })
});
```

## MoE Integration

Achievement Master routes tasks through commit-relay's MoE system:
- Development Master: Feature PRs, code enhancements
- CI/CD Master: Workflow automation, deployments
- Security Master: Token management, best practices

## Monitoring

View real-time metrics in Elastic APM:
- Achievement progress gauge
- Opportunity score trends
- Workflow execution timeline

---

Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
