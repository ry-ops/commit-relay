# ADR 001: Use Mixture of Experts (MoE) Architecture

**Status**: Accepted  
**Date**: 2025-11-01  
**Deciders**: System Architects  
**Technical Story**: Multi-repository management system

## Context

commit-relay needs to manage multiple repositories efficiently with specialized expertise for different types of tasks (development, security, CI/CD, inventory management). A single monolithic approach would lack the specialization needed for optimal task execution.

## Decision

We will use a Mixture of Experts (MoE) architecture with specialized master agents:

- **Coordinator Master**: Routes tasks to appropriate specialist masters
- **Development Master**: Handles feature development and bug fixes
- **Security Master**: Manages security scans and vulnerability remediation
- **CI/CD Master**: Orchestrates builds, tests, and deployments
- **Inventory Master**: Catalogs and documents repositories
- **Dashboard Master**: Provides real-time monitoring

## Rationale

### Advantages

1. **Specialization**: Each master has focused expertise
2. **Scalability**: Masters can scale independently
3. **Maintainability**: Clear separation of concerns
4. **Performance**: Parallel task execution
5. **Learning**: Pattern-based routing improves over time

### Example Routing Logic

```javascript
function routeTask(task) {
  if (task.description.match(/security|cve|vulnerability/i)) {
    return 'security-master';
  }
  if (task.description.match(/deploy|build|test|ci/i)) {
    return 'cicd-master';
  }
  if (task.description.match(/fix|bug|feature|implement/i)) {
    return 'development-master';
  }
  return 'coordinator-master'; // Default fallback
}
```

## Consequences

### Positive

- Clear task ownership
- Better resource utilization
- Improved success rates through specialization
- Easier to add new masters

### Negative

- Increased system complexity
- Routing overhead
- Potential routing errors
- Need for coordinator logic

### Mitigation

- Confidence scoring for routing decisions
- Fallback to coordinator for uncertain tasks
- Continuous learning from routing outcomes
- Monitoring and alerting on routing confidence

## Implementation

- **Routing Logic**: `coordination/masters/coordinator/lib/moe-router.sh`
- **Master Specs**: `coordination/masters/{master-name}/`
- **Task Queue**: `coordination/tasks/pending/`
- **Decision Log**: `coordination/masters/coordinator/knowledge-base/routing-decisions.jsonl`

## Alternatives Considered

### 1. Monolithic Agent

**Pros**: Simpler architecture  
**Cons**: Lacks specialization, harder to scale

### 2. Rule-Based Task Assignment

**Pros**: Predictable routing  
**Cons**: Inflexible, no learning capability

### 3. Manual Task Assignment

**Pros**: Full control  
**Cons**: Not scalable, requires human intervention

## Related Decisions

- ADR 002: Pattern-Based Learning for Routing
- ADR 003: Worker Pool Management

## References

- [Mixture of Experts Paper](https://arxiv.org/abs/1701.06538)
- [MoE Implementation Guide](https://github.com/ry-ops/commit-relay/wiki/MoE-Architecture)
