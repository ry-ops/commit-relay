# Agent Quick Reference Guide

## Starting an Agent Session

Every agent session should follow this pattern:

```bash
# 1. Navigate to coordination repo
cd ~/commit-relay

# 2. Pull latest state
git pull origin main

# 3. Read coordination files (use Claude Code Read tool)
# - coordination/task-queue.json
# - coordination/handoffs.json
# - coordination/status.json

# 4. Read your agent prompt
# - agents/prompts/{your-agent-name}.md
```

## Agent Checklist

### At Start of Session

- [ ] Pull latest coordination state
- [ ] Read task queue for your assignments
- [ ] Check for pending handoffs to you
- [ ] Review system health status
- [ ] Update your last_checkin timestamp
- [ ] Log session start in your activity log

### During Work

- [ ] Keep activity log updated with progress
- [ ] Commit coordination changes frequently
- [ ] Create handoffs when needed
- [ ] Escalate blockers promptly
- [ ] Update task status as work progresses

### Before Ending Session

- [ ] Complete or properly hand off in-progress work
- [ ] Update all coordination files
- [ ] Log session end in activity log
- [ ] Commit and push all changes
- [ ] Update next_scheduled_checkin time

## Common Operations

### Accepting a Handoff

```bash
# 1. Read pending handoff details
cat coordination/handoffs.json | jq '.pending_handoffs[] | select(.to_agent == "your-agent")'

# 2. Update handoff status (use Edit tool)
# Set: "status": "accepted"
# Set: "accepted_at": current timestamp
# Set: "accepted_by": your agent name

# 3. Move from pending to completed
# Remove from pending_handoffs array
# Add to completed_handoffs array

# 4. Log in your activity log
# Document what you accepted and from whom

# 5. Commit
git add coordination/handoffs.json agents/logs/your-agent/
git commit -m "feat(your-agent): accepted handoff from other-agent"
git push origin main
```

### Creating a Handoff

```bash
# 1. Prepare handoff context
# - What you completed
# - What the next agent needs to know
# - What they should review or do

# 2. Create handoff entry in coordination/handoffs.json
# Use the handoff schema (see coordination-protocol.md)

# 3. Update task status to "handoff-pending"

# 4. Log in your activity log

# 5. Commit
git add coordination/handoffs.json coordination/task-queue.json agents/logs/
git commit -m "feat(your-agent): completed task-X, handoff to next-agent"
git push origin main
```

### Updating Task Status

```bash
# 1. Edit coordination/task-queue.json
# Find your task by ID
# Update "status" field

# 2. Update coordination/status.json
# Add/remove from your current_tasks array
# Increment completed_today if done

# 3. Log the status change

# 4. Commit
git add coordination/
git commit -m "chore(your-agent): updated task-X status to in-progress"
git push origin main
```

### Escalating to Coordinator

```bash
# 1. Update task status to "blocked"

# 2. Add to your blocked_tasks in status.json

# 3. Create new task in task-queue.json:
{
  "id": "escalation-XXX",
  "title": "Resolve blocker: {brief description}",
  "type": "coordination",
  "priority": "high",
  "status": "pending",
  "assigned_to": "coordinator-agent",
  "created_by": "your-agent",
  "context": {
    "description": "Detailed blocker description",
    "blocked_task": "task-XXX",
    "what_needed": "What's needed to unblock"
  }
}

# 4. Log escalation in activity log

# 5. Commit
git add coordination/
git commit -m "escalate(your-agent): blocked on task-X, need coordinator help"
git push origin main
```

## File Locations

### Your Agent Files
- **Prompt**: `agents/prompts/{your-agent-name}.md`
- **Config**: `agents/configs/agent-registry.json`
- **Logs**: `agents/logs/{your-agent-name}/YYYY-MM-DD.md`

### Coordination Files
- **Task Queue**: `coordination/task-queue.json`
- **Handoffs**: `coordination/handoffs.json`
- **Status**: `coordination/status.json`
- **History**: `coordination/history/YYYY-MM-DD.json`

### Documentation
- **Protocol**: `docs/coordination-protocol.md`
- **Architecture**: `docs/architecture.md` (TBD)
- **This Guide**: `docs/agent-guide.md`

## Activity Log Format

```markdown
# {Agent Name} - Activity Log
## Date: YYYY-MM-DD

### HH:MM - Session Start
**System Status**: {status summary}
**Assigned Tasks**: {list task IDs}
**Pending Handoffs**: {count or none}

### HH:MM - Started Task: task-XXX
**Task**: {brief description}
**Repository**: owner/repo-name
**Branch**: branch-name (if applicable)

**Actions**:
- {action 1}
- {action 2}

### HH:MM - {Event or Milestone}
**Status**: {relevant status}
**Details**: {what happened}

### HH:MM - Completed Task: task-XXX
**Status**: {completed | handoff-pending}
**Handoff To**: {agent name or N/A}
**Deliverables**: {what was produced}

**Notes**: {important information}

### HH:MM - Session End
**Completed Today**: X tasks
**In Progress**: X tasks
**Next Check-in**: {when}

---
```

## Quick Reference: JSON Schemas

### Task Object
```json
{
  "id": "task-XXX",
  "title": "Brief description",
  "type": "development|security|coordination|content",
  "priority": "critical|high|medium|low",
  "status": "pending|in-progress|blocked|handoff-pending|completed",
  "assigned_to": "agent-name",
  "created_at": "ISO-8601",
  "created_by": "agent-name",
  "repository": "owner/repo",
  "context": {},
  "handoff_plan": {}
}
```

### Handoff Object
```json
{
  "id": "handoff-XXX",
  "from_agent": "sender",
  "to_agent": "receiver",
  "task_id": "task-XXX",
  "status": "pending|accepted",
  "created_at": "ISO-8601",
  "context": {
    "summary": "What was done",
    "deliverables": {},
    "handoff_reason": "Why",
    "notes": "Special instructions"
  },
  "accepted_at": "ISO-8601 or null",
  "accepted_by": "agent-name or null"
}
```

### Agent Status Object
```json
{
  "agent-name": {
    "status": "active|inactive|error",
    "last_checkin": "ISO-8601",
    "current_tasks": ["task-1", "task-2"],
    "completed_today": 5,
    "blocked_tasks": [],
    "next_scheduled_checkin": "ISO-8601"
  }
}
```

## Troubleshooting

### Git Conflicts
```bash
# Pull with rebase to avoid merge commits
git pull --rebase origin main

# If conflict occurs
git status  # See what's conflicted
# Edit files to resolve
git add .
git rebase --continue
git push origin main
```

### Invalid JSON
```bash
# Validate before committing
jq '.' coordination/task-queue.json
jq '.' coordination/handoffs.json
jq '.' coordination/status.json

# If invalid, fix and re-validate
```

### Lost Changes
```bash
# View recent commits
git log --oneline -n 10

# Recover from specific commit
git checkout <commit-hash> -- coordination/

# View what changed
git diff HEAD~1 coordination/
```

## Tips for Effective Agent Operation

1. **Pull Frequently**: Always start with `git pull`
2. **Commit Often**: Small, atomic commits are better
3. **Document Everything**: Future you (or other agents) will thank you
4. **Clear Handoffs**: Give the next agent everything they need
5. **Update Status**: Keep status.json current
6. **Escalate Early**: Don't stay blocked, ask for help
7. **Review Before Push**: Double-check your JSON is valid
8. **Read Other Logs**: Learn from other agents' activities

## Getting Help

1. **Check Documentation**: Read coordination-protocol.md
2. **Review Examples**: Look at other agents' logs
3. **Ask Coordinator**: Create escalation task
4. **Human Escalation**: Coordinator will create GitHub issue

---

*Keep this guide handy during agent sessions!*
